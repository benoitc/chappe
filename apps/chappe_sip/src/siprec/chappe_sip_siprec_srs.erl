%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc A SIPREC recording server (SRS, RFC 7866) in a handler: take a
%% recording session (RS) and write each of its streams to the recording
%% store, or hand its audio to a process.
%%
%% serve/3 runs in the INVITE handler, on a route that takes siprec
%% (chappe_sip:handle/3 with option_tags => [<<"siprec">>]). It checks the
%% INVITE is a recording session (RFC 7866 6.2: +sip.src in the Contact
%% and siprec in Require), reads its SDP and metadata
%% (chappe_sip_siprec_meta), starts one receiver per recorded stream
%% (chappe_sip_siprec_rtp, G.711) and answers 200 with every stream
%% recvonly and +sip.srs in its Contact. A stream it cannot take (not
%% PCMU or PCMA, past max_streams) is answered with port 0 (RFC 3264 6).
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
%% UPDATE of the recording client with the streams as they are, and hands
%% the metadata each carries (RFC 7866 9.2: the SRS keeps track of the
%% updates) to the notify process (Opts' notify, else the sink pid) as
%%   {chappe_sip_siprec_srs, Dialog, {metadata, Doc}}
%% and the end of the session as {chappe_sip_siprec_srs, Dialog, {stopped,
%% Why}}, Why the BYE request or the dialog's reason. Opts also take ip (the
%% address the receivers bind, default 127.0.0.1), advertise (the address
%% in the SDP, default ip), max_streams (default 4), max_queue (default
%% 500) and headers for the 200.
%%
%% {error, not_recording_session} leaves Res unanswered, for the app to
%% treat as an ordinary call or refuse; {error, _} on a body that does not
%% parse or a store that is not there answers 488 or 500.
-module(chappe_sip_siprec_srs).

-export([serve/3, run/1, is_recording_session/1, store/1]).

-define(LAWS, [<<"0">>, <<"8">>]).

-spec serve(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, #{
        dialog := chappe_sip_dialog:dialog(),
        call_ref := binary() | undefined,
        metadata := map(),
        streams := [map()]
    }}
    | {error, term()}.
serve(Req, Res, Opts) ->
    case is_recording_session(Req) of
        false -> {error, not_recording_session};
        true -> serve_1(Req, Res, Opts)
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
%% (chappe_audio_store). chappe_sip calls it through this one seam
%% (chappe_sip_siprec_rtp opens, writes and closes), so it does not depend
%% on the chappe_audio app and an app may give its own module.
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

answer(Req, Res, Sdp, Doc, Sink, Opts) ->
    CallRef = call_ref(Req, Doc),
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    Adv = advertise(Opts, Ip),
    Senders = maps:from_list([
        {L, S}
     || #{label := L} = S <- chappe_sip_siprec_meta:senders(Doc)
    ]),
    {Sess, Media} = chappe_sip_sdp:sections(Sdp),
    _ = Sess,
    Max = maps:get(max_streams, Opts, 4),
    Taken = lists:map(
        fun({I, Sec}) ->
            stream(I =< Max, Sec, Senders, CallRef, Sink, Ip, Opts)
        end,
        lists:enumerate(Media)
    ),
    Answer = chappe_sip_sdp:join(
        [
            <<"v=0">>,
            <<"o=chappe 1 1 IN IP4 ", Adv/binary>>,
            <<"s=-">>,
            <<"c=IN IP4 ", Adv/binary>>,
            <<"t=0 0">>
        ],
        [Lines || {Lines, _} <- Taken]
    ),
    Streams = [S || {_, S} <- Taken, S =/= undefined],
    case
        chappe_sip:create_uas(Req, Res, #{
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
                notify => notify(Opts),
                call_ref => CallRef,
                metadata => Doc,
                streams => Streams
            }};
        {error, _} = E ->
            _ = [chappe_sip_siprec_rtp:stop(P) || #{pid := P} <- Streams],
            E
    end.

notify(#{notify := Pid}) when is_pid(Pid) -> Pid;
notify(#{sink := Pid}) when is_pid(Pid) -> Pid;
notify(_Opts) -> undefined.

%% Carry the session in the calling process (the dialog's owner) until it
%% ends: each re-INVITE or UPDATE of the client is answered, its metadata
%% told. Returns {stopped, Why}.
-spec run(map()) -> {stopped, term()}.
run(#{dialog := D} = Srs) ->
    Mon = chappe_sip_dialog:monitor(D),
    Why = loop(D, Mon, Srs),
    erlang:demonitor(Mon, [flush]),
    tell({stopped, Why}, Srs),
    {stopped, Why}.

loop(D, Mon, Srs) ->
    receive
        {chappe_sip_dialog, D, modify, Req, Res} ->
            %% RFC 7866 7.2: the SRS answers with the streams it takes
            updated(Req, Srs),
            _ = chappe_sip_res:send(Res, 200, #{
                body => maps:get(answer, Srs),
                headers => [{<<"Content-Type">>, <<"application/sdp">>}]
            }),
            loop(D, Mon, Srs);
        {chappe_sip_dialog, D, update, Req, Res} ->
            updated(Req, Srs),
            _ = chappe_sip_res:send(Res, 200),
            loop(D, Mon, Srs);
        {chappe_sip_dialog, D, destroy, Why} ->
            Why;
        {'DOWN', Mon, process, _, Why} ->
            Why;
        {chappe_sip_dialog, D, _Event, _Req} ->
            loop(D, Mon, Srs)
    end.

%% the metadata of a re-INVITE or UPDATE, when it carries some
updated(Req, Srs) ->
    case read(Req) of
        {ok, _Sdp, #{} = Doc} when map_size(Doc) > 0 ->
            tell({metadata, Doc}, Srs);
        _ ->
            metadata_only(Req, Srs)
    end.

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

%% one recorded stream: a receiver and its recvonly m-line, or port 0
stream(Room, [M | Rest], Senders, CallRef, Sink, Ip, Opts) ->
    Label = label(Rest),
    case {Room, m_line(M)} of
        {true, {<<"audio">>, Port, Fmts}} when Port =/= 0 ->
            case [F || F <- Fmts, lists:member(F, ?LAWS)] of
                [] ->
                    {rejected(M), undefined};
                Laws ->
                    receiver(Label, Laws, Senders, CallRef, Sink, Ip, Opts, M)
            end;
        _ ->
            {rejected(M), undefined}
    end.

receiver(Label, Laws, Senders, CallRef, Sink0, Ip, Opts, M) ->
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
        max_queue => maps:get(max_queue, Opts, 500)
    },
    case chappe_sip_siprec_rtp:start(Args) of
        {ok, Pid} ->
            Port = chappe_sip_siprec_rtp:port(Pid),
            Lines =
                [
                    <<"m=audio ", (integer_to_binary(Port))/binary, " RTP/AVP ",
                        (iolist_to_binary(lists:join(<<" ">>, Laws)))/binary>>
                ] ++
                    [rtpmap(L) || L <- Laws] ++
                    [<<"a=recvonly">>] ++
                    [<<"a=label:", Label/binary>> || Label =/= undefined],
            {Lines, #{
                label => Label, pid => Pid, port => Port, parties => Parties
            }};
        {error, _} ->
            {rejected(M), undefined}
    end.

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
        [Kind, Port, _Proto | Fmts] ->
            {Kind, chappe_sip_lib:to_int(Port, 0), Fmts};
        _ ->
            undefined
    end.

%% RFC 3264 6: a stream refused keeps its m-line, port 0
rejected(M) ->
    case m_words(M) of
        [Kind, _Port | Rest] ->
            [iolist_to_binary(["m=", lists:join(" ", [Kind, <<"0">> | Rest])])];
        _ ->
            [<<"m=audio 0 RTP/AVP 0">>]
    end.

m_words(<<"m=", Rest/binary>>) -> chappe_sip_sdp:words(Rest).
