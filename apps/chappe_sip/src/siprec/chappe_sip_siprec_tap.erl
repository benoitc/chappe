%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The media side of a SIPREC recording (chappe_sip_siprec): one tap
%% per party of the call, an rtpengine subscription (chappe_sip_media:
%% subscribe/2) whose offered m-lines become the party's recorded streams,
%% answered with that party's part of the recording server's answer, and
%% removed on pause, on a party change and at the end. A chappe_mix room
%% has one tap: a sendonly leg of the room, which hears the whole mix
%% (chappe_sip_media:conference/3), pointed at the recording server. The functions take
%% and return the recording's state.
-module(chappe_sip_siprec_tap).

-export([open/1, close/1, close_one/2, answer/2, watch/1]).

%% the subscription flags of a transcoded tap (rtpengine needs them when
%% the receiver takes fewer codecs than the party sends)
-define(TRANSCODE_FLAGS, [allow_transcoding]).

%% Tap each party's media in rtpengine: its sections, each given a
%% stream id and a label on first sight.
-spec open(map()) -> {ok, map()} | {error, term()}.
open(#{streams := Ss} = St) ->
    open(Ss, St, []).

open([], St, Acc) ->
    {ok, St#{streams := lists:reverse(Acc)}};
open([#{tap := undefined} = S | Rest], St, Acc) ->
    case tap(S, St) of
        {ok, Tap, Sections} ->
            {S1, St1} = place(S#{tap := Tap}, Sections, St),
            open(Rest, St1, [S1 | Acc]);
        {error, _} = E ->
            close(St#{streams := lists:reverse(Acc) ++ [S | Rest]}),
            E
    end;
open([S | Rest], St, Acc) ->
    open(Rest, St, [S | Acc]).

tap(#{party := room}, #{source := {room, Room}, call_ref := Ref}) ->
    %% the room's mix, as a sendonly leg of the room the mixer offers
    case
        chappe_sip_media:session(#{call_id => <<"siprec-", Ref/binary>>}, #{
            capability => conference
        })
    of
        {ok, S} ->
            case
                chappe_sip_media:conference(S, Room, #{
                    direction => sendonly,
                    create => false,
                    observer => true,
                    name => <<"siprec">>
                })
            of
                {ok, Offer} ->
                    {Sess, Media} = chappe_sip_sdp:sections(Offer),
                    Conn = [L || <<"c=", _/binary>> = L <- Sess],
                    {ok, {mix, S}, [with_conn(M, Conn) || M <- Media]};
                {error, _} = E ->
                    chappe_sip_media:stop(S),
                    E
            end;
        {error, _} = E ->
            E
    end;
tap(#{party := Leg}, #{session := S, opts := Opts} = St) ->
    %% the call's media session holds the tap for this process, and
    %% removes it if the recording dies without closing it
    Sub = maps:merge(
        #{party => party(Leg), holder => self()},
        maps:merge(maps:with([codec, ptime], Opts), srtp(St))
    ),
    case chappe_sip_media:subscribe(S, Sub) of
        {ok, #{sdp := Sdp, to_tag := ToTag}} ->
            {Sess, Media} = chappe_sip_sdp:sections(Sdp),
            Conn = [L || <<"c=", _/binary>> = L <- Sess],
            case Media of
                [] -> {error, no_media};
                _ -> {ok, {sub, ToTag}, [with_conn(M, Conn) || M <- Media]}
            end;
        {error, _} = E ->
            E
    end.

%% RFC 7866 12: the RS at least as secure as the call. A call with an SRTP
%% leg is tapped as SRTP whatever the tapped party sends, with keys of the
%% tap's own (rtpengine re-encrypts, 12.2: a different key)
srtp(#{srtp := true}) -> #{transport_protocol => <<"RTP/SAVP">>};
srtp(_St) -> #{}.

party(a) -> caller;
party(b) -> callee.

%% a section keeps the session c= line it was offered under
with_conn([M | Rest] = Sec, Conn) ->
    case [L || <<"c=", _/binary>> = L <- Rest] of
        [] -> [M | Conn ++ Rest];
        _ -> Sec
    end.

%% the tapped sections of a party: the labels and stream ids it had, new
%% ones for a section it did not
place(#{media := Old} = S, Sections, #{next_label := N0} = St) ->
    {Media, N} = lists:mapfoldl(
        fun({I, Sec}, N1) ->
            case
                lists:keyfind(I, 1, [{J, M} || {J, M} <- lists:enumerate(Old)])
            of
                {I, M} ->
                    {M#{lines := Sec}, N1};
                false ->
                    {
                        #{
                            id => chappe_sip_siprec_meta:new_id(),
                            label => integer_to_binary(N1),
                            lines => Sec
                        },
                        N1 + 1
                    }
            end
        end,
        N0,
        lists:enumerate(Sections)
    ),
    {S#{media := Media}, St#{next_label := N}}.

%% A monitor on the mixer of a room's tap, undefined when there is none.
-spec watch(map()) -> reference() | undefined.
watch(#{streams := Ss}) ->
    case [chappe_sip_media:info(M) || #{tap := {mix, M}} <- Ss] of
        [#{conf := Conf} | _] -> erlang:monitor(process, Conf);
        _ -> undefined
    end.

%% every tap removed
-spec close(map()) -> map().
close(#{streams := Ss} = St) ->
    St#{streams := [close_one(S, St) || S <- Ss]}.

-spec close_one(map(), map()) -> map().
close_one(#{tap := {sub, ToTag}} = S, #{session := Sess}) ->
    %% the call's rtpengine session may be gone already, its taps with it
    try chappe_sip_media:unsubscribe(Sess, #{to_tag => ToTag}) of
        _ -> ok
    catch
        exit:_ -> ok
    end,
    S#{tap := undefined};
close_one(#{tap := {mix, M}} = S, _St) ->
    ok = chappe_sip_media:stop(M),
    S#{tap := undefined};
close_one(S, _St) ->
    S.

%% The recording server's answer (or offer) to the taps: each gets its
%% part (chappe_sip_siprec_body:answers/2).
-spec answer(binary(), map()) -> ok | {error, term()}.
answer(Answer, #{streams := Ss} = St) ->
    case chappe_sip_siprec_body:answers(Answer, Ss) of
        {ok, PerTap} -> answer_each(PerTap, St);
        {error, _} = E -> E
    end.

answer_each([], _St) ->
    ok;
answer_each([{Tap, Sdp} | Rest], St) ->
    case answer_tap(Tap, Sdp, St) of
        ok -> answer_each(Rest, St);
        {error, _} = E -> E
    end.

answer_tap(undefined, _Sdp, _St) ->
    ok;
answer_tap({mix, M}, Sdp, _St) ->
    chappe_sip_media:set_remote(M, Sdp);
answer_tap({sub, ToTag}, Sdp, #{session := S}) ->
    %% a tap is transcoded (to PCMU unless codec says otherwise), so the
    %% SRS may take fewer codecs than the party sends
    chappe_sip_media:subscribe_answer(S, #{
        to_tag => ToTag, sdp => Sdp, flags => ?TRANSCODE_FLAGS
    }).
