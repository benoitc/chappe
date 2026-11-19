%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc A SIPREC recording server (SRS, RFC 7866) in a handler: take a
%% recording session (RS) and write each of its streams to the recording
%% store, or hand its audio to a process.
%%
%% serve/3 runs in the INVITE handler, on a route that takes siprec
%% (chappe_sip:handle/3 with `option_tags => [<<"siprec">>]'). It checks the
%% INVITE is a recording session (RFC 7866 6.2: +sip.src in the Contact
%% and siprec in Require), reads its SDP and metadata
%% (chappe_sip_siprec_meta), starts one receiver per recorded stream
%% (chappe_audio_rtp, G.711) and answers 200 with every stream
%% recvonly and +sip.srs in its Contact. A stream it cannot take (not
%% PCMU or PCMA, past max_streams) is answered with port 0 (RFC 3264 6),
%% and an offer with no stream it can take is refused 488 with a Warning
%% (RFC 3261 20.43): 305 Incompatible media format when audio came in no
%% codec it takes (or found no port), 304 Media type not available when
%% no audio came, and serve/3 returns {error, no_streams}.
%%
%% Each receiver takes RTP from the recording client only: from the
%% address the client's SDP gives for its stream, latched to the first
%% source seen there (chappe_audio_rtp). rtp_source => learn latches
%% to the first source wherever it comes from, for a client behind a NAT
%% that writes its private address.
%%
%% SRTP (RFC 7866 12.2: an SRS MUST support RTP/SAVP and RTP/SAVPF with
%% SDES keys): a stream offered as RTP/SAVP or RTP/SAVPF with an a=crypto
%% line it can take (chappe_sip_sdes: AES_CM_128_HMAC_SHA1_80 or _32) is
%% answered in the same profile with an a=crypto line of its own (RFC 4568
%% 7.1.2), and its receiver authenticates and decrypts each packet
%% (chappe_audio_srtp) before it decodes it. A re-INVITE that changes a
%% stream's key gives its receiver the new one. A secure stream with no
%% line it can take (another suite, several keys, a key derivation rate,
%% UNENCRYPTED_SRTP..., DTLS-SRTP's UDP/TLS/RTP/SAVP) is answered with port
%% 0 (RFC 4568 7.1.2, RFC 3264 6), and an offer left with no stream that
%% had a secure one is refused 488 with a 302 Warning (RFC 3261 20.43).
%% The keys travel in the SDP, and RFC 4568 8.3 requires the SDP that
%% carries an inline key to be encrypted: by default a secure stream offered
%% over a transport that is not TLS (or WSS), whatever its Request-URI (a
%% sips: one reached over UDP is not encrypted), is rejected the same way
%% (port 0, RFC 4568 7.1.2: "its
%% configured policy prohibits", and 488 when no stream is left).
%% keys_over_tls => false takes such keys, for a recording client on a
%% network the app trusts.
%%
%% Each stream goes to its sink:
%%   store => default | module()   a recording of the store, opened with
%%       the call_ref of the metadata (the call_ref chappe's client puts
%%       there, else the INVITE's), source siprec, and the AORs of the
%%       stream's senders as parties. default is the siprec_store config,
%%       chappe_audio_store (the chappe_audio app) unless set otherwise:
%%       any module with open/2, write/2 and close/2 as chappe_audio_store
%%       has them.
%%   sink => pid()   gets {chappe_sip_siprec_rtp, Stream, {audio, Pcm}},
%%       16-bit linear PCM at 8 kHz, dropped while it has max_queue
%%       messages waiting
%% The streams belong to the calling process: they finish (and close their
%% store recordings) when it exits, so the handler then calls run/1, which
%% carries the session until it ends. run/1 answers each re-INVITE and
%% each UPDATE with an offer of the recording client (RFC 3311 5.2) with
%% one m-line per offered one (RFC 3264 6): a stream it has keeps its
%% receiver, with the offer's key and direction (inactive when the client
%% pauses, RFC 3264 6.1), and a stream the offer adds is taken as in the
%% INVITE, or port 0 past max_streams. It hands
%% the metadata each carries (RFC 7866 9.2: the SRS keeps track of the
%% updates) to the notify process (Opts' notify, else the sink pid) as
%%   {chappe_sip_siprec_srs, Dialog, {metadata, Doc}}
%% and the end of the session as {chappe_sip_siprec_srs, Dialog, {stopped,
%% Why}}, Why the BYE request or the dialog's reason. Opts also take ip (the
%% address the receivers bind, default 127.0.0.1), advertise (the address
%% in the SDP, default ip), rtp_ports ({Min, Max}: each stream binds a
%% free port in the range, for a server behind a NAT or a container that
%% publishes only those; a stream finding none is refused with port 0;
%% default the siprec_rtp_ports setting, undefined for any port; anything
%% else is {error, badarg}, answered 500), max_streams (default 4),
%% max_queue (default 500), rtp_source (negotiated, the default, or
%% learn), keys_over_tls (default true) and headers for the 200.
%%
%% {error, not_recording_session} leaves Res unanswered, for the app to
%% treat as an ordinary call or refuse; {error, _} on a body that does not
%% parse or a store that is not there answers 488 or 500, and {error,
%% no_streams} or {error, srtp} was answered 488.
%%
%% The receivers run under the chappe_audio application, an optional
%% dependency of chappe_sip: without it running, every stream is refused,
%% 488 as above, the session logs why once, and serve/3 returns {error,
%% no_audio}.
-module(chappe_sip_siprec_srs).

-include_lib("kernel/include/logger.hrl").

-export([serve/3, run/1, is_recording_session/1, store/1]).

-export_type([srs/0]).

%% The session serve/3 answered, for run/1: its dialog, the call_ref, the
%% metadata of the INVITE and the streams taken; the other keys are
%% run/1's (the answer, its version, the notify process, and what a
%% re-offer needs to take a new stream).
-type srs() :: #{
    dialog := chappe_sip_dialog:dialog(),
    call_ref := binary() | undefined,
    metadata := map(),
    streams := [map()],
    answer := binary(),
    taken := [{[binary()], map() | undefined}],
    advertise := binary(),
    version := pos_integer(),
    notify := pid() | undefined,
    ctx := map()
}.

-spec serve(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, srs()} | {error, term()}.
serve(Req, Res, Opts0) ->
    case rtp_ports(Opts0) of
        {ok, Ports} ->
            Opts = Opts0#{rtp_ports => Ports},
            case is_recording_session(Req) of
                false -> {error, not_recording_session};
                true -> serve_1(Req, Res, Opts)
            end;
        error ->
            _ = chappe_sip_res:send(Res, 500),
            {error, badarg}
    end.

%% the ports the receivers bind: Opts' rtp_ports, else the siprec_rtp_ports
%% setting; undefined is any port
rtp_ports(Opts) ->
    case maps:get(rtp_ports, Opts, chappe_sip_config:get(siprec_rtp_ports)) of
        undefined ->
            {ok, undefined};
        {Min, Max} = R when
            is_integer(Min), is_integer(Max), Min > 0, Min =< Max, Max < 65536
        ->
            {ok, R};
        _ ->
            error
    end.

%% RFC 7866 6.2: an INVITE is a recording session only with both the
%% +sip.src feature tag in its Contact and siprec in its Require.
-spec is_recording_session(chappe_sip_req:req()) -> boolean().
is_recording_session(Req) ->
    Require = [
        chappe_sip_lib:lower(chappe_sip_lib:trim(T))
     || V <- chappe_sip_req:get_all(<<"require">>, Req),
        T <- binary:split(V, <<",">>, [global])
    ],
    Contact =
        case chappe_sip_req:get(<<"contact">>, Req) of
            undefined -> #{};
            C -> contact_params(C)
        end,
    lists:member(<<"siprec">>, Require) andalso
        maps:is_key(<<"+sip.src">>, Contact).

contact_params(C) ->
    case chappe_sip_hdr:name_addr(C) of
        {ok, #{params := P}} -> P;
        _ -> #{}
    end.

%% The store a stream is written to: default is the siprec_store setting
%% (chappe_audio_store). The stream's receiver (chappe_audio_rtp) opens,
%% writes and closes it through this one seam, so an app may give its own
%% module.
-spec store(default | module()) -> module().
store(default) -> chappe_sip_config:get(siprec_store);
store(Mod) when is_atom(Mod) -> Mod.

serve_1(Req, Res, Opts) ->
    case read(Req) of
        {ok, Sdp, Doc} ->
            case sink(Opts) of
                {ok, Sink} ->
                    answer(Req, Res, Sdp, Doc, Sink, Opts);
                {error, _} = E ->
                    _ = chappe_sip_res:send(Res, 500),
                    E
            end;
        {error, _} = E ->
            _ = chappe_sip_res:send(Res, 488),
            E
    end.

read(Req) ->
    case
        chappe_sip_multipart:parse(
            chappe_sip_req:get(<<"content-type">>, Req),
            chappe_sip_req:body(Req)
        )
    of
        {ok, Parts} ->
            case chappe_sip_multipart:find(<<"application/sdp">>, Parts) of
                {ok, #{body := Sdp}} -> metadata(Sdp, Parts);
                error -> {error, no_sdp}
            end;
        {error, _} = E ->
            E
    end.

metadata(Sdp, Parts) ->
    case
        [
            B
         || #{content_type := CT, body := B} <- Parts,
            chappe_sip_siprec_meta:is_content_type(CT)
        ]
    of
        [] ->
            %% RFC 7866 9.1: metadata may follow later
            {ok, Sdp, #{}};
        [Xml | _] ->
            case chappe_sip_siprec_meta:parse(Xml) of
                {ok, #{} = Doc} -> {ok, Sdp, Doc};
                {ok, _} -> {error, not_recording_metadata};
                {error, _} = E -> E
            end
    end.

sink(#{store := Store}) ->
    Mod = store(Store),
    case is_atom(Mod) andalso code:ensure_loaded(Mod) of
        {module, Mod} -> {ok, {store, Mod}};
        _ -> {error, {no_store, Mod}}
    end;
sink(#{sink := Pid}) when is_pid(Pid) ->
    {ok, {pid, Pid}};
sink(_) ->
    {error, no_sink}.

answer(Req, Res, Sdp, Doc, Sink, Opts0) ->
    Opts = Opts0#{
        tls_in => is_tls(Req),
        keys_over_tls => maps:get(keys_over_tls, Opts0, true)
    },
    CallRef = call_ref(Req, Doc),
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    Adv = advertise(Opts, Ip),
    {_Sess, Media} = chappe_sip_sdp:sections(Sdp),
    %% the receivers' supervisor runs only with the chappe_audio application
    case whereis(chappe_audio_rtp_sup) of
        undefined ->
            ?LOG_WARNING(#{
                what => siprec_srs_chappe_audio_not_running, call_ref => CallRef
            }),
            _ = refuse(Res, Adv, Media),
            {error, no_audio};
        _ ->
            take(Req, Res, Sdp, Doc, Sink, Opts, {CallRef, Ip, Adv, Media})
    end.

take(Req, Res, Sdp, Doc, Sink, Opts, {CallRef, Ip, Adv, Media}) ->
    Ctx = #{
        senders => senders(Doc),
        call_ref => CallRef,
        sink => Sink,
        ip => Ip,
        opts => Opts
    },
    {Sess, _} = chappe_sip_sdp:sections(Sdp),
    Taken = [
        chappe_sip_siprec_srs_stream:take(I, Sec, Offer, Ctx)
     || {I, Sec} <- lists:enumerate(Media),
        Offer <- [chappe_sip_siprec_srs_stream:offer(Sess, Sec, Opts)]
    ],
    Streams = [S || {_, S} <- Taken, S =/= undefined],
    case Streams of
        [] -> refuse(Res, Adv, Media);
        _ -> answer_streams(Req, Res, Adv, Taken, Streams, Ctx, Doc)
    end.

senders(Doc) ->
    maps:from_list([
        {L, S}
     || #{label := L} = S <- chappe_sip_siprec_meta:senders(Doc)
    ]).

%% No stream it can take: 488 (RFC 3261 21.4.26), with the Warning that
%% says why (20.43): 302 when a stream was secure ({error, srtp}), 305 when
%% audio came in no codec it takes or found no port, 304 when no audio came
refuse(Res, Adv, Media) ->
    {Code, Text, Why} =
        case
            {
                lists:any(fun chappe_sip_siprec_srs_stream:secure/1, Media),
                lists:any(fun chappe_sip_siprec_srs_stream:audio/1, Media)
            }
        of
            {true, _} ->
                {<<"302">>, <<"Incompatible transport protocol">>, srtp};
            {false, true} ->
                {<<"305">>, <<"Incompatible media format">>, no_streams};
            {false, false} ->
                {<<"304">>, <<"Media type not available">>, no_streams}
        end,
    _ = chappe_sip_res:send(Res, 488, #{
        headers => [
            {<<"Warning">>, [Code, <<" ">>, Adv, <<" \"">>, Text, <<"\"">>]}
        ]
    }),
    {error, Why}.

%% the SDP of the streams taken, at version Ver of its o= line
answer_sdp(Adv, Ver, Taken) ->
    V = integer_to_binary(Ver),
    chappe_sip_sdp:join(
        [
            <<"v=0">>,
            <<"o=chappe 1 ", V/binary, " IN IP4 ", Adv/binary>>,
            <<"s=-">>,
            <<"c=IN IP4 ", Adv/binary>>,
            <<"t=0 0">>
        ],
        [Lines || {Lines, _} <- Taken]
    ).

answer_streams(Req, Res, Adv, Taken, Streams, Ctx, Doc) ->
    #{call_ref := CallRef, opts := Opts} = Ctx,
    Answer = answer_sdp(Adv, 1, Taken),
    case
        chappe_sip_dialog:create_uas(Req, Res, #{
            local_sdp => Answer,
            contact_params => <<";+sip.srs">>,
            headers => maps:get(headers, Opts, []),
            %% run/1 answers them, and reads their metadata
            handled_events => [modify, update]
        })
    of
        {ok, D} ->
            {ok, #{
                dialog => D,
                answer => Answer,
                taken => Taken,
                advertise => Adv,
                version => 1,
                notify => notify(Opts),
                call_ref => CallRef,
                metadata => Doc,
                streams => Streams,
                ctx => Ctx
            }};
        {error, _} = E ->
            _ = [chappe_audio_rtp:stop(P) || #{pid := P} <- Streams],
            E
    end.

notify(#{notify := Pid}) when is_pid(Pid) -> Pid;
notify(#{sink := Pid}) when is_pid(Pid) -> Pid;
notify(_Opts) -> undefined.

%% Carry the session in the calling process (the dialog's owner) until it
%% ends: each re-INVITE or UPDATE of the client is answered, its metadata
%% told. Returns {stopped, Why}.
-spec run(srs()) -> {stopped, term()}.
run(#{dialog := D} = Srs) ->
    Mon = chappe_sip_dialog:monitor(D),
    Why = loop(D, Mon, Srs),
    erlang:demonitor(Mon, [flush]),
    tell({stopped, Why}, Srs),
    {stopped, Why}.

loop(D, Mon, Srs) ->
    receive
        {chappe_sip_dialog, D, modify, Req, Res} ->
            Read = read(Req),
            updated(Req, Read, Srs),
            loop(D, Mon, reoffered(modify, Read, Res, Srs));
        {chappe_sip_dialog, D, update, Req, Res} ->
            Read = read(Req),
            updated(Req, Read, Srs),
            loop(D, Mon, reoffered(update, Read, Res, Srs));
        {chappe_sip_dialog, D, destroy, Why} ->
            Why;
        {'DOWN', Mon, process, _, Why} ->
            Why;
        {chappe_sip_dialog, D, _Event, _Req} ->
            loop(D, Mon, Srs)
    end.

%% A re-INVITE or an UPDATE of the client. With an offer, it is answered
%% in the 2xx (RFC 7866 7.2, RFC 3311 5.2); an offer with fewer m-lines
%% than the session has is refused 488 (RFC 3264 8) and the session is
%% left as it was. A re-INVITE with no offer gets the current SDP as the
%% SRS's offer, and an UPDATE with none (the metadata alone, RFC 7866 9.1)
%% an empty 200.
reoffered(_Event, {ok, Sdp, Doc}, Res, Srs) ->
    case reoffer(Sdp, Doc, Srs) of
        {ok, Srs1} ->
            send_answer(Res, Srs1),
            Srs1;
        error ->
            _ = chappe_sip_res:send(Res, 488),
            Srs
    end;
reoffered(modify, {error, _}, Res, Srs) ->
    send_answer(Res, Srs),
    Srs;
reoffered(update, {error, _}, Res, Srs) ->
    _ = chappe_sip_res:send(Res, 200),
    Srs.

send_answer(Res, #{answer := Answer}) ->
    _ = chappe_sip_res:send(Res, 200, #{
        body => Answer,
        headers => [{<<"Content-Type">>, <<"application/sdp">>}]
    }),
    ok.

%% RFC 3264 6 and 8: the answer to a re-offer has one m-line per offered
%% one. A stream taken before keeps its receiver: its key follows the
%% offer's (RFC 4568 7.1.4) and its direction the offer's (RFC 3264 6.1),
%% and it is stopped and answered port 0 when the offer sets its port to 0
%% (RFC 3264 8.2). A stream new to the session, or one refused before, is
%% taken as in the INVITE: a receiver, or port 0 past max_streams. An
%% answer that changes takes a new o= version (RFC 3264 8).
reoffer(Sdp, Doc, #{taken := Taken, ctx := Ctx0} = Srs) ->
    {Sess, Media} = chappe_sip_sdp:sections(Sdp),
    case length(Media) >= length(Taken) of
        true ->
            Ctx = Ctx0#{senders := senders_of(Doc, Ctx0)},
            #{opts := Opts} = Ctx,
            Offers = [
                {I, Sec, chappe_sip_siprec_srs_stream:offer(Sess, Sec, Opts)}
             || {I, Sec} <- lists:enumerate(Media)
            ],
            Taken1 = chappe_sip_siprec_srs_stream:retake(
                Offers, Taken, Media, Ctx
            ),
            Srs1 = Srs#{
                ctx := Ctx,
                streams := [S || {_, S} <- Taken1, S =/= undefined]
            },
            case Taken1 =:= Taken of
                true -> {ok, Srs1};
                false -> {ok, reanswer(Taken1, Srs1)}
            end;
        false ->
            error
    end.

%% the senders of a re-offer's metadata, else those the session had
senders_of(Doc, #{senders := Senders}) when map_size(Doc) =:= 0 -> Senders;
senders_of(Doc, _Ctx) -> senders(Doc).

reanswer(Taken, #{advertise := Adv, version := V} = Srs) ->
    Srs#{
        taken := Taken,
        version := V + 1,
        answer := answer_sdp(Adv, V + 1, Taken)
    }.

%% the RS came over TLS or WSS (RFC 4568 8.3). Only the transport it
%% came over says so: a sips: Request-URI reached over UDP is not
%% encrypted, and a transport the stack does not name counts as not
%% secure.
is_tls(Req) ->
    case maps:get(transport, chappe_sip_req:meta(Req), undefined) of
        T when is_binary(T) ->
            lists:member(chappe_sip_lib:lower(T), [<<"tls">>, <<"wss">>]);
        _ ->
            false
    end.

%% the metadata of a re-INVITE or UPDATE, when it carries some
updated(_Req, {ok, _Sdp, #{} = Doc}, Srs) when map_size(Doc) > 0 ->
    tell({metadata, Doc}, Srs);
updated(Req, _Read, Srs) ->
    metadata_only(Req, Srs).

%% an UPDATE may carry the metadata alone (RFC 7866 9.1)
metadata_only(Req, Srs) ->
    CT = chappe_sip_req:get(<<"content-type">>, Req),
    case
        CT =/= undefined andalso chappe_sip_siprec_meta:is_content_type(CT) andalso
            chappe_sip_siprec_meta:parse(chappe_sip_req:body(Req))
    of
        {ok, #{} = Doc} -> tell({metadata, Doc}, Srs);
        _ -> ok
    end.

tell(_Ev, #{notify := undefined}) ->
    ok;
tell(Ev, #{notify := Pid, dialog := D}) ->
    Pid ! {?MODULE, D, Ev},
    ok.

advertise(#{advertise := A}, _Ip) when is_binary(A) -> A;
advertise(_Opts, Ip) -> list_to_binary(inet:ntoa(Ip)).

%% the metadata's call_ref (chappe's extension), else the INVITE's
call_ref(Req, Doc) ->
    case [R || #{call_ref := R} <- maps:get(sessions, Doc, [])] of
        [R | _] -> R;
        [] -> chappe_sip_req:call_ref(Req)
    end.
