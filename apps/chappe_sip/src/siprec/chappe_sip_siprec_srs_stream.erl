%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc One recorded stream of the SIPREC recording server
%% (chappe_sip_siprec_srs): what a media section of an offer asks, the
%% receiver that takes it (chappe_audio_rtp) and its m-line in the answer.
%%
%% take/4 takes a stream of an offer: a receiver and its m-line, recvonly
%% or inactive as the offer asks (RFC 3264 6.1), or the m-line at port 0
%% (RFC 3264 6) when it is past max_streams, not G.711, in a profile or
%% with a key the server does not take. retake/4 answers a re-offer
%% stream by stream: a stream with a receiver keeps it, with the offer's
%% key (RFC 4568 7.1.4) and direction, and stops when the offer sets its
%% port to 0 (RFC 3264 8.2); a stream new to the session goes through
%% take/4.
-module(chappe_sip_siprec_srs_stream).

-export([offer/3, take/4, retake/4, secure/1, audio/1]).

-define(LAWS, [<<"0">>, <<"8">>]).

%% the stream at index I of an offer: a receiver, or port 0 past
%% max_streams or when it cannot be taken
take(I, Sec, {Remote, Dir}, #{opts := Opts} = Ctx) ->
    #{senders := Senders, call_ref := CallRef, sink := Sink, ip := Ip} = Ctx,
    stream(
        I =< maps:get(max_streams, Opts, 4),
        Sec,
        Senders,
        CallRef,
        Sink,
        Ip,
        Opts#{remote => Remote, index => I, dir => Dir}
    ).

%% what a media section of an offer asks of its answer: where its stream
%% comes from (its c= address, else the session's, and its port;
%% undefined when that is no IP literal or the app said to learn it) and
%% the direction to answer it with (RFC 3264 6.1: the SRS only receives,
%% so recvonly, or inactive when the offer does not send)
offer(Sess, Sec, Opts) ->
    case chappe_sip_sdp:parse(chappe_sip_sdp:join(Sess, [Sec])) of
        {Addr, [#{port := P, dir := Dir} = M]} ->
            {remote_of(maps:get(addr, M, Addr), P, Opts), answer_dir(Dir)};
        {_, _} ->
            {undefined, <<"recvonly">>}
    end.

answer_dir(sendonly) -> <<"recvonly">>;
answer_dir(sendrecv) -> <<"recvonly">>;
answer_dir(recvonly) -> <<"inactive">>;
answer_dir(inactive) -> <<"inactive">>.

remote_of(_Addr, _Port, #{rtp_source := learn}) -> undefined;
remote_of(Addr, Port, _Opts) -> remote(Addr, Port).

%% a media section of audio
audio([M | _]) ->
    case m_line(M) of
        {<<"audio">>, _, _, _} -> true;
        _ -> false
    end.

%% the answer to each stream of a re-offer ({Index, Section, offer/3}),
%% against the streams the session has: one per offered m-line (RFC 3264
%% 6). The offer has at least as many as the session (RFC 3264 8).
retake([{I, Sec, Offer} | Offers], [T | Ts], Media, Ctx) ->
    [kept(T, I, Sec, Offer, Media, Ctx) | retake(Offers, Ts, Media, Ctx)];
retake([{I, Sec, Offer} | Offers], [], Media, Ctx) ->
    [take(I, Sec, Offer, Ctx) | retake(Offers, [], Media, Ctx)];
retake([], _Taken, _Media, _Ctx) ->
    [].

kept({_, undefined}, I, Sec, Offer, _Media, Ctx) ->
    take(I, Sec, Offer, Ctx);
kept({_, #{pid := Pid}} = T, _I, [M | _], {_, Dir}, Media, _Ctx) ->
    case m_line(M) of
        {_, 0, _, _} ->
            _ = chappe_audio_rtp:stop(Pid),
            {rejected(M), undefined};
        _ ->
            {Lines, S} = rekey_one(T, Media),
            {chappe_sip_sdp:set_direction(Lines, Dir), S}
    end.

%% RFC 4568 7.1.4: a re-offer may change a stream's key; its receiver
%% takes the new one, and the answer echoes the new line's tag. A stream
%% whose re-offer has no line it can take keeps its key.
rekey_one({Lines, #{index := I, srtp := Hash, pid := Pid} = S} = T, Media) when
    is_binary(Hash), I =< length(Media)
->
    [_M | Rest] = lists:nth(I, Media),
    case chappe_sip_sdes:select(Rest) of
        {ok, C} ->
            case key_hash(C) of
                Hash ->
                    T;
                New ->
                    case srtp_ctx(C) of
                        {ok, Ctx} ->
                            ok = chappe_audio_rtp:rekey(Pid, Ctx),
                            {crypto_line(Lines, C), S#{srtp := New}};
                        error ->
                            T
                    end
            end;
        {error, _} ->
            T
    end;
rekey_one(T, _Media) ->
    T.

crypto_line(Lines, C) ->
    [
        case L of
            <<"a=crypto:", _/binary>> -> chappe_sip_sdes:answer(C);
            _ -> L
        end
     || L <- Lines
    ].

%% what tells a key from another without keeping it
key_hash(#{key := K, salt := S}) ->
    crypto:hash(sha256, [K, S]).

srtp_ctx(C) ->
    case
        chappe_audio_srtp:new(
            maps:with([suite, key, salt, mki, lifetime, window], C)
        )
    of
        {ok, Ctx} -> {ok, Ctx};
        {error, _} -> error
    end.

remote(Addr, Port) ->
    case chappe_sip_sdp:address(Addr) of
        {ok, {0, 0, 0, 0}} -> undefined;
        {ok, {0, 0, 0, 0, 0, 0, 0, 0}} -> undefined;
        {ok, Ip} -> {Ip, Port};
        error -> undefined
    end.

%% an m-line of a secure profile (RTP/SAVP, RTP/SAVPF, UDP/TLS/RTP/SAVP...)
secure([M | _]) ->
    case m_line(M) of
        {_, _, Proto, _} -> binary:match(Proto, <<"SAVP">>) =/= nomatch;
        undefined -> false
    end.

%% one recorded stream: a receiver and its recvonly (or inactive) m-line,
%% or port 0
stream(Room, [M | Rest], Senders, CallRef, Sink, Ip, Opts) ->
    Label = label(Rest),
    case {Room, m_line(M)} of
        {true, {<<"audio">>, Port, Proto, Fmts}} when Port =/= 0 ->
            case
                {profile(Proto, Rest, Opts), [
                    F
                 || F <- Fmts, lists:member(F, ?LAWS)
                ]}
            of
                {_, []} ->
                    {rejected(M), undefined};
                {error, _} ->
                    {rejected(M), undefined};
                {Profile, Laws} ->
                    receiver(
                        Label,
                        Laws,
                        Senders,
                        CallRef,
                        Sink,
                        Ip,
                        Opts,
                        M,
                        Profile
                    )
            end;
        _ ->
            {rejected(M), undefined}
    end.

%% RTP/AVP, or RTP/SAVP and RTP/SAVPF with an SDES key it takes (RFC 7866
%% 12.2, RFC 4568 7.1.2); every other profile is refused
profile(<<"RTP/AVP">> = P, _Lines, _Opts) ->
    {P, undefined};
profile(P, _Lines, #{keys_over_tls := true, tls_in := false}) when
    P =:= <<"RTP/SAVP">>; P =:= <<"RTP/SAVPF">>
->
    error;
profile(P, Lines, _Opts) when P =:= <<"RTP/SAVP">>; P =:= <<"RTP/SAVPF">> ->
    case chappe_sip_sdes:select(Lines) of
        {ok, C} ->
            case srtp_ctx(C) of
                {ok, Ctx} -> {P, {C, Ctx}};
                error -> error
            end;
        {error, _} ->
            error
    end;
profile(_P, _Lines, _Opts) ->
    error.

receiver(Label, Laws, Senders, CallRef, Sink0, Ip, Opts, M, {Proto, Srtp}) ->
    Parties = [
        Aor
     || #{participants := Ps} <- [
            maps:get(Label, Senders, #{participants => []})
        ],
        #{names := [#{aor := Aor} | _]} <- Ps
    ],
    Sink =
        case Sink0 of
            {store, Mod} ->
                {store, Mod, #{
                    call_ref => store_ref(CallRef),
                    source => siprec,
                    parties => Parties,
                    format => #{rate => 8000, channels => 1}
                }};
            {pid, _} = P ->
                P
        end,
    Args = #{
        owner => self(),
        ip => Ip,
        label => label_or(Label),
        sink => Sink,
        max_queue => maps:get(max_queue, Opts, 500),
        remote => maps:get(remote, Opts),
        srtp => srtp_of(Srtp),
        ports => maps:get(rtp_ports, Opts),
        %% the tag a sink process has always matched
        tag => chappe_sip_siprec_rtp
    },
    case chappe_audio:rtp_receiver(Args) of
        {ok, Pid} ->
            Port = chappe_audio_rtp:port(Pid),
            Lines =
                [
                    <<"m=audio ", (integer_to_binary(Port))/binary, " ",
                        Proto/binary, " ",
                        (iolist_to_binary(lists:join(<<" ">>, Laws)))/binary>>
                ] ++
                    [rtpmap(L) || L <- Laws] ++
                    [<<"a=", (maps:get(dir, Opts))/binary>>] ++
                    [<<"a=label:", Label/binary>> || Label =/= undefined] ++
                    crypto_answer(Srtp),
            {Lines, #{
                label => Label,
                pid => Pid,
                port => Port,
                parties => Parties,
                profile => Proto,
                index => maps:get(index, Opts),
                srtp => srtp_hash(Srtp)
            }};
        {error, _} ->
            {rejected(M), undefined}
    end.

srtp_of(undefined) -> undefined;
srtp_of({_C, Ctx}) -> Ctx.

srtp_hash(undefined) -> undefined;
srtp_hash({C, _Ctx}) -> key_hash(C).

crypto_answer(undefined) -> [];
crypto_answer({C, _Ctx}) -> [chappe_sip_sdes:answer(C)].

store_ref(undefined) -> chappe_sip_call:new_ref();
store_ref(R) -> R.

label_or(undefined) -> <<>>;
label_or(L) -> L.

rtpmap(<<"0">>) -> <<"a=rtpmap:0 PCMU/8000">>;
rtpmap(<<"8">>) -> <<"a=rtpmap:8 PCMA/8000">>.

label(Lines) ->
    case [L || <<"a=label:", L/binary>> <- Lines] of
        [L | _] -> L;
        [] -> undefined
    end.

m_line(<<"m=", Rest/binary>>) ->
    case chappe_sip_sdp:words(Rest) of
        [Kind, Port, Proto | Fmts] ->
            {Kind, chappe_sip_lib:to_int(Port, 0), Proto, Fmts};
        _ ->
            undefined
    end.

%% RFC 3264 6: a stream refused keeps its m-line, port 0
rejected(M) ->
    chappe_sip_sdp:refused([M]).
