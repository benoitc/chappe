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
%% max_streams or when it cannot be taken; an offer on hold (c=0.0.0.0)
%% learns its source
take(I, Sec, {hold, Dir}, Ctx) ->
    take(I, Sec, {undefined, Dir}, Ctx);
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
%% undefined when that is no IP literal or the app said to learn it, hold
%% for c=0.0.0.0, RFC 3264 8.4) and
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

%% A stream with a receiver follows its re-offer (RFC 3264 8.2, 8.3):
%% port 0 stops it; the same audio profile keeps it, re-latched to a moved
%% source (8.3.1; an old-style hold, c=0.0.0.0, keeps its source, 8.4),
%% with the offer's G.711 formats, key and direction, unless no format it
%% takes is left (8.3.2: port 0, stopped), the offer's keys came over a
%% transport that is not secure (RFC 4568 8.3, judged on the request of
%% this offer) or an SDES stream has no key line it takes (RFC 4568 5.1.2,
%% 7.1.2: port 0, stopped); another media type or profile
%% (8.3.1, 8.3.3) stops it and takes the stream as a new one, under the
%% same rules (keys included).
kept({_, undefined}, I, Sec, Offer, _Media, Ctx) ->
    take(I, Sec, Offer, Ctx);
kept(
    {_, #{pid := Pid, profile := Proto}} = T,
    I,
    [M | _] = Sec,
    Offer,
    Media,
    #{opts := Opts} = Ctx
) ->
    case m_line(M) of
        {_, 0, _, _} ->
            stopped(Pid, M);
        {<<"audio">>, _, Proto, Fmts} ->
            case {laws(Fmts), sdes(Proto) andalso keys_refused(Opts)} of
                {[], _} -> stopped(Pid, M);
                {_, true} -> stopped(Pid, M);
                {Laws, false} -> followed(T, M, Laws, Offer, Media)
            end;
        _ ->
            _ = chappe_audio_rtp:stop(Pid),
            take(I, Sec, Offer, Ctx)
    end.

stopped(Pid, M) ->
    _ = chappe_audio_rtp:stop(Pid),
    {rejected(M), undefined}.

followed({_, #{pid := Pid}} = T, M, Laws, {Remote, Dir}, Media) ->
    case rekey_one(T, Media) of
        {ok, {Lines, S}} ->
            {
                chappe_sip_sdp:set_direction(formats(Lines, Laws), Dir),
                relatched(S, Remote)
            };
        refused ->
            stopped(Pid, M)
    end.

%% the stream's answer lines with the formats of the re-offer, in its
%% order (RFC 3264 6.1), the rest of the m-line and the other lines kept
formats([<<"m=", M/binary>> | Rest], Laws) ->
    [Kind, Port, Proto | _] = chappe_sip_sdp:words(M),
    [
        iolist_to_binary([
            <<"m=">>, lists:join(<<" ">>, [Kind, Port, Proto | Laws])
        ])
    ] ++
        [rtpmap(L) || L <- Laws] ++
        [L || L <- Rest, not is_rtpmap(L)].

is_rtpmap(<<"a=rtpmap:", _/binary>>) -> true;
is_rtpmap(_) -> false.

%% the formats of an m-line the server takes, in its order
laws(Fmts) ->
    [F || F <- Fmts, lists:member(F, ?LAWS)].

%% a profile keyed with SDES (RFC 7866 12.2)
sdes(<<"RTP/SAVP">>) -> true;
sdes(<<"RTP/SAVPF">>) -> true;
sdes(_) -> false.

%% RFC 4568 8.3: inline keys taken only over TLS or WSS, unless the app
%% said otherwise (keys_over_tls => false)
keys_refused(#{keys_over_tls := true, tls_in := false}) -> true;
keys_refused(_Opts) -> false.

%% the receiver takes the source the re-offer gives, when it moved; a
%% hold keeps the source it has
relatched(S, hold) ->
    S;
relatched(#{remote := Remote} = S, Remote) ->
    S;
relatched(#{pid := Pid} = S, Remote) ->
    ok = chappe_audio_rtp:remote(Pid, Remote),
    S#{remote := Remote}.

%% RFC 4568 7.1.4: a re-offer may change a stream's key; its receiver
%% takes the new one, and the answer echoes the new line's tag. A stream
%% whose re-offer has no line it can take is refused (5.1.2, 7.1.2).
rekey_one({Lines, #{index := I, srtp := Hash, pid := Pid} = S} = T, Media) when
    is_binary(Hash), I =< length(Media)
->
    [_M | Rest] = lists:nth(I, Media),
    case chappe_sip_sdes:select(Rest) of
        {ok, C} ->
            case key_hash(C) of
                Hash ->
                    {ok, T};
                New ->
                    case srtp_ctx(C) of
                        {ok, Ctx} ->
                            ok = chappe_audio_rtp:rekey(Pid, Ctx),
                            {ok, {crypto_line(Lines, C), S#{srtp := New}}};
                        error ->
                            refused
                    end
            end;
        {error, _} ->
            refused
    end;
rekey_one(T, _Media) ->
    {ok, T}.

crypto_line(Lines, C) ->
    [
        case L of
            <<"a=crypto:", _/binary>> -> chappe_sip_sdes:answer(C);
            _ -> L
        end
     || L <- Lines
    ].

%% what tells a key line from another without keeping its key: a new tag
%% with the same key is answered with that tag
key_hash(#{tag := Tag, key := K, salt := S}) ->
    crypto:hash(sha256, [Tag, 0, K, S]).

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
        {ok, {0, 0, 0, 0}} -> hold;
        {ok, {0, 0, 0, 0, 0, 0, 0, 0}} -> hold;
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
            case {profile(Proto, Rest, Opts), laws(Fmts)} of
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
profile(P, Lines, Opts) ->
    case sdes(P) andalso not keys_refused(Opts) of
        true -> sdes_profile(P, Lines);
        false -> error
    end.

sdes_profile(P, Lines) ->
    case chappe_sip_sdes:select(Lines) of
        {ok, C} ->
            case srtp_ctx(C) of
                {ok, Ctx} -> {P, {C, Ctx}};
                error -> error
            end;
        {error, _} ->
            error
    end.

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
                remote => maps:get(remote, Opts),
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
