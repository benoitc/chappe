%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc chappe_mrf: a media resource function in the drachtio-fsmrf style.
%% chappe_mrf is the controller; FreeSWITCH, rtpengine and chappe_mix are
%% the media processors.
%%
%% connect_caller/3 answers an incoming INVITE by bridging it, anchored
%% in rtpengine, to a FreeSWITCH node picked by chappe_esl; the node's
%% dialplan hands the channel back over an outbound event socket, and you
%% get an endpoint to drive (play, collect digits, record, fork audio)
%% and the call's handle. create_endpoint/1 makes an endpoint with no
%% caller, to bridge one into later. bridge/2,3 moves a caller between
%% endpoints and SIP targets without the caller seeing a re-INVITE.
%% conference/2 runs a conference on chappe_mix (native) or on
%% FreeSWITCH mod_conference (fs); see chappe_mrf_conf.
%%
%% Each FreeSWITCH node needs a dialplan extension that hands the call to
%% this node: <action application="socket" data="Host:Port async full"/>
%% for the user the INVITE is sent to (`mrf' by default), where Port is
%% the listener of start/1 (or the `esl_port' app env). The listener binds
%% 127.0.0.1 unless esl_ip is given; with FreeSWITCH on another host, set
%% esl_ip and esl_allow. The INVITE carries
%% X-Chappe-Call; FreeSWITCH reports it as variable_sip_h_X-Chappe-Call,
%% which is how the socket finds its endpoint.
%%
%% The endpoint's owner gets {chappe_mrf, Ep, Event}: {dtmf, Digit},
%% {hangup, Cause}, {node_down, Node}, and what it asked for with the
%% events option of connect_caller/3 and create_endpoint/1:
%% {playback_start, File}, {playback_stop, File, Status} (done or break),
%% {custom, Subclass, Ev} (a CUSTOM event of the channel) and
%% {channel, Name, Ev} (any other event of the channel, by name). The
%% notify process of a call
%% (connect_caller's notify option, default the owner) gets the call's
%% {chappe_sip_b2b, Ref, Event}, and {chappe_sip_b2b, Ref, {done, Why}}
%% when it ends.
-module(chappe_mrf).

-export([
    start/1, listen/1, listen/2, listener_opts/1, stop_listener/0, install/0
]).
-export([connect_caller/3, create_endpoint/1, bridge/2, bridge/3]).
-export([play/2, play/3, play_info/3, play_collect/2, record/3]).
-export([record_session/2, record_session/3, record_session_stop/2]).
-export([send_dtmf/2, set/3, set/2]).
-export([api/2, execute/3, execute/4, fork_audio_start/3, fork_audio_stop/1]).
-export([export/3, var/2, vars/1, mute/2, unmute/2, say/3, speak/3]).
-export([detect_tones/2, stop_detect_tones/1, detect_fax/1, detect_fax/2]).
-export([stop_detect_fax/1]).
-export([fork_audio_pause/1, fork_audio_pause/2, fork_audio_resume/1]).
-export([fork_audio_resume/2, fork_audio_send_text/2, fork_audio_send_text/3]).
-export([modify/2, destroy/1, uuid/1, node/1, info/1]).
-export([conference/2, conferences/0, focus_subscribe/2, focus_refer/2]).
-export([inactive_sdp/0, loop_target/1]).

-export_type([endpoint/0]).

-type endpoint() :: chappe_mrf_endpoint:endpoint().

-define(LOOP_PREFIX, "mrf-mix-").
%% record options of chappe_mrf's, not FreeSWITCH's
-define(STORE_OPTS, [store, ref, parties]).

%% ---- setup ----

%% Run after chappe_sip:start/1. Opts: esl_port (the outbound socket
%% listener FreeSWITCH connects back to), esl_ip (the address it listens
%% on, 127.0.0.1 by default) and esl_allow (the networks FreeSWITCH
%% connects from, CIDR strings or binaries; unset, any peer that reaches
%% esl_ip). It also installs the INVITE middleware the native conference
%% backend relies on (install/0).
-spec start(#{
    esl_port => inet:port_number(),
    esl_ip => inet:ip_address(),
    esl_allow => [string() | binary()]
}) -> ok | {error, term()}.
start(Opts) ->
    ok = install(),
    case maps:find(esl_port, Opts) of
        {ok, Port} -> listen(Port, listener_opts(Opts));
        error -> ok
    end.

%% Listen for FreeSWITCH outbound sockets on Port.
-spec listen(inet:port_number()) -> ok | {error, term()}.
listen(Port) ->
    listen(Port, #{}).

%% The same with chappe_esl listener options (ip, allow, ...). A bad one
%% returns {error, {bad_option, Key}}.
-spec listen(inet:port_number(), chappe_esl:listener_opts()) ->
    ok | {error, term()}.
listen(Port, ListenerOpts) ->
    chappe_mrf_esl:listen(Port, ListenerOpts).

%% esl_ip and esl_allow as chappe_esl's ip and allow.
-spec listener_opts(map()) -> chappe_esl:listener_opts().
listener_opts(Opts) ->
    chappe_mrf_esl:listener_opts(Opts).

-spec stop_listener() -> ok | {error, term()}.
stop_listener() ->
    chappe_mrf_esl:stop_listener().

%% Take the loopback INVITEs that bring a call into a native conference
%% (see chappe_mrf_conf). Runs once per chappe_sip:start/1.
-spec install() -> ok.
install() ->
    chappe_sip:use(<<"INVITE">>, fun loop_middleware/3).

loop_middleware(Req, Res, Next) ->
    case loop_token(chappe_sip_req:uri(Req)) of
        {ok, Token} ->
            case chappe_mrf_registry:lookup({loop, Token}) of
                {ok, Conf} ->
                    chappe_mrf_conf:loop_invite(Conf, Token, Req, Res);
                error ->
                    chappe_sip_res:send(Res, 404)
            end;
        error ->
            Next()
    end.

loop_token(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{user := <<?LOOP_PREFIX, Token/binary>>}} when Token =/= <<>> ->
            {ok, Token};
        _ ->
            error
    end.

%% The URI of a loopback INVITE for Token: this node's own SIP address.
-spec loop_target(binary()) -> binary().
loop_target(Token) ->
    {ok, U} = chappe_sip_uri:parse(own_uri()),
    chappe_sip_uri:format(U#{user => <<?LOOP_PREFIX, Token/binary>>}).

own_uri() ->
    case chappe_sip_hdr:name_addr(chappe_sip_b2b:contact()) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> <<"sip:127.0.0.1">>
    end.

%% ---- calls ----

%% Bridge an incoming INVITE to a FreeSWITCH node and take its channel
%% as an endpoint. Run it from the INVITE's handler. Opts:
%%   owner    => pid(): gets the endpoint's events (default the caller)
%%   notify   => pid(): gets the call's events (default the owner)
%%   node     => Name: this chappe_esl node, no failover
%%   select   => chappe_esl:node_select/1 options for the first node;
%%               the other up nodes follow, in turn, on 408, 503 or a
%%               transport error
%%   targets  => [{Node, SipUri}]: the nodes to try, bypassing chappe_esl
%%   user     => the user of the INVITE to the node (default <<"mrf">>)
%%   attach_timeout => ms to wait for the outbound socket (10000)
%%   call_ref => binary(): the call's correlation ref (opaque). The
%%               INVITE to the node carries it as X-Chappe-Call (and the
%%               endpoint's own id as X-Chappe-Endpoint), the endpoint's
%%               chappe_esl_call gets it as ref, info/1 returns it. Without
%%               it X-Chappe-Call is the endpoint's random id, as before.
%%   events   => more events for the owner (see the module doc):
%%               playback_start, playback_stop, {custom, Subclass},
%%               {channel, EventName}
%%   relay    => options of chappe_sip_b2b:relay/2
%% and any chappe_sip_b2b:create_b2bua/4 option (media defaults to
%% anchor, b_headers get X-Chappe-Call). Returns the endpoint and the
%% call's handle; the call runs in its own process (relay_async/2), so
%% the caller is free to drive the endpoint. A REFER the call hands a
%% room (chappe_mrf_conf:b2b_event/2) is answered in the caller's dialog.
-spec connect_caller(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, endpoint(), chappe_sip_b2b:b2b()} | {error, term()}.
connect_caller(Req, Res, Opts) ->
    case check_opts(Opts) of
        ok ->
            connect(Req, Res, Opts);
        {error, _} = Bad ->
            _ = chappe_sip_res:send(Res, 500),
            Bad
    end.

%% connect_caller/3's own options, the rest go to create_b2bua/4
-define(MRF_ONLY_OPTS, [
    owner, node, select, targets, user, attach_timeout, relay, events
]).

connect(Req, Res, Opts) ->
    Owner = maps:get(owner, Opts, self()),
    case candidates(Opts) of
        [] ->
            _ = chappe_sip_res:send(Res, 503, #{
                reason => <<"Service Unavailable">>
            }),
            {error, no_node};
        Cands ->
            Id = chappe_mrf_lib:new_id(),
            CallRef = maps:get(call_ref, Opts, undefined),
            {ok, Ep} = chappe_mrf_endpoint:start(#{
                id => Id,
                owner => Owner,
                candidates => Cands,
                events => maps:get(events, Opts, []),
                call_ref => CallRef
            }),
            User = maps:get(user, Opts, <<"mrf">>),
            Uris = [with_user(U, User) || {_, U} <- Cands],
            Notify = maps:get(notify, Opts, Owner),
            B2bOpts = (maps:without(?MRF_ONLY_OPTS, Opts))#{
                media => maps:get(media, Opts, anchor),
                b_headers =>
                    chappe_mrf_esl:headers(Id, CallRef) ++
                    maps:get(b_headers, Opts, []),
                notify => Notify
            },
            case chappe_sip_b2b:create_b2bua(Req, Res, Uris, B2bOpts) of
                {ok, Legs} ->
                    {ok, B2b} = chappe_sip_b2b:relay_async(
                        Legs,
                        maps:merge(
                            #{notify => Notify}, maps:get(relay, Opts, #{})
                        )
                    ),
                    ok = chappe_mrf_conf_refer:keep_dialog(B2b, Legs),
                    Timeout = maps:get(attach_timeout, Opts, 10000),
                    case chappe_mrf_endpoint:await(Ep, Timeout) of
                        {ok, _Uuid} ->
                            {ok, Ep, B2b};
                        {error, _} = Err ->
                            _ = chappe_sip_b2b:hangup(B2b, #{}),
                            chappe_mrf_endpoint:destroy(Ep),
                            Err
                    end;
                {error, _} = Err ->
                    chappe_mrf_endpoint:destroy(Ep),
                    Err
            end
    end.

%% An endpoint with no caller: an INVITE from this node to a FreeSWITCH
%% node, its channel handed back over the outbound socket. Its SDP is an
%% inactive placeholder until bridge/2 brings a caller in. Opts: owner,
%% node, select, targets, user, events, call_ref (as for connect_caller/3),
%% sdp (the offer,
%% default inactive_sdp/0), headers, timeout (ms for the INVITE, 32000),
%% attach_timeout.
-spec create_endpoint(map()) -> {ok, endpoint()} | {error, term()}.
create_endpoint(Opts) ->
    Owner = maps:get(owner, Opts, self()),
    case check_opts(Opts) of
        ok ->
            case candidates(Opts) of
                [] -> {error, no_node};
                Cands -> try_endpoint(Cands, Owner, Opts, {error, no_node})
            end;
        {error, _} = Bad ->
            Bad
    end.

try_endpoint([], _Owner, _Opts, Last) ->
    Last;
try_endpoint([{Node, Uri} | Rest], Owner, Opts, _Last) ->
    Id = chappe_mrf_lib:new_id(),
    CallRef = maps:get(call_ref, Opts, undefined),
    {ok, Ep} = chappe_mrf_endpoint:start(#{
        id => Id,
        owner => Owner,
        candidates => [{Node, Uri}],
        events => maps:get(events, Opts, []),
        call_ref => CallRef
    }),
    UacOpts = #{
        local_sdp => maps:get(sdp, Opts, inactive_sdp()),
        headers =>
            chappe_mrf_esl:headers(Id, CallRef) ++ maps:get(headers, Opts, []),
        owner => Ep,
        timeout => maps:get(timeout, Opts, 32000)
    },
    case
        chappe_sip:create_uac(
            with_user(Uri, maps:get(user, Opts, <<"mrf">>)), UacOpts
        )
    of
        {ok, D} ->
            ok = chappe_mrf_endpoint:set_dialog(Ep, D),
            case
                chappe_mrf_endpoint:await(
                    Ep, maps:get(attach_timeout, Opts, 10000)
                )
            of
                {ok, _} ->
                    {ok, Ep};
                {error, _} = Err ->
                    chappe_mrf_endpoint:destroy(Ep),
                    Err
            end;
        {error, _} = Err ->
            chappe_mrf_endpoint:destroy(Ep),
            try_endpoint(Rest, Owner, Opts, Err)
    end.

%% An SDP offer that sends and expects nothing, for an endpoint not yet
%% bridged.
-spec inactive_sdp() -> binary().
inactive_sdp() ->
    <<
        "v=0\r\no=chappe-mrf 1 1 IN IP4 127.0.0.1\r\ns=-\r\n"
        "c=IN IP4 127.0.0.1\r\nt=0 0\r\n"
        "m=audio 9 RTP/AVP 0 8 101\r\n"
        "a=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n"
        "a=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-16\r\n"
        "a=inactive\r\n"
    >>.

-spec bridge(
    chappe_sip_b2b:b2b(),
    endpoint() | binary() | {parallel, [chappe_sip_b2b:dest()]}
) ->
    ok | {ok, #{winner := chappe_sip_b2b:winner()}} | {error, term()}.
bridge(B2b, Target) ->
    bridge(B2b, Target, #{}).

%% Move the caller of B2b (an anchored call) to Target: an endpoint of
%% create_endpoint/1, a SIP URI, or {parallel, Dests} to ring several
%% destinations at once. The caller sees no re-INVITE; the leg it had (an
%% endpoint's channel, a callee) gets a BYE. On a failure the caller stays
%% where it was. A fork returns {ok, #{winner := Winner}}, the destination
%% that answered. Opts are chappe_sip_b2b:replace_b/3's (anchor_params,
%% headers, from, timer_c, ...); from sets who the callee sees as calling,
%% and an endpoint's re-INVITE ignores it, keeping its dialog's identity.
-spec bridge(
    chappe_sip_b2b:b2b(),
    endpoint() | binary() | {parallel, [chappe_sip_b2b:dest()]},
    map()
) ->
    ok | {ok, #{winner := chappe_sip_b2b:winner()}} | {error, term()}.
bridge(B2b, {parallel, _} = Fork, Opts) ->
    chappe_sip_b2b:replace_b(B2b, Fork, Opts);
bridge(B2b, Uri, Opts) when is_binary(Uri) ->
    chappe_sip_b2b:replace_b(B2b, Uri, Opts);
bridge(B2b, Ep, Opts) when is_pid(Ep) ->
    case chappe_mrf_endpoint:handed(Ep) of
        {ok, D} ->
            case chappe_sip_b2b:replace_b(B2b, {dialog, D}, Opts) of
                ok ->
                    ok;
                {error, _} = Err ->
                    %% the endpoint keeps its dialog
                    _ = give_back(D, Ep),
                    _ = chappe_mrf_endpoint:set_dialog(Ep, D),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

give_back(D, Ep) ->
    try
        chappe_sip_dialog:set_owner(D, Ep)
    catch
        exit:_ -> ok
    end.

%% ---- endpoint commands ----

%% Play a file (or a list, one after the other) to the channel.
-spec play(endpoint(), iodata() | [binary()]) -> ok | {error, term()}.
play(Ep, Files) ->
    play(Ep, Files, #{}).

%% Opts: chappe_esl_call:playback_opts() (timeout, offset in samples,
%% limit_secs, ...). A file the node cannot find is {error, not_found},
%% one it cannot play {error, playback_error}; a list stops at the first
%% error.
-spec play(endpoint(), iodata() | [binary()], map()) -> ok | {error, term()}.
play(Ep, [F | _] = Files, Opts) when is_binary(F) ->
    lists:foldl(
        fun
            (File, ok) -> play(Ep, File, Opts);
            (_File, Err) -> Err
        end,
        ok,
        Files
    );
play(Ep, File, Opts) ->
    case play_info(Ep, File, Opts) of
        {ok, _} -> ok;
        Err -> Err
    end.

%% play/3 for one file, with how it went: #{ms, response}, the time it
%% played (FreeSWITCH's playback_ms, undefined when it did not say) and
%% the Application-Response (FILE PLAYED).
-spec play_info(endpoint(), iodata(), map()) ->
    {ok, #{ms := non_neg_integer() | undefined, response := binary()}}
    | {error, term()}.
play_info(Ep, File, Opts) ->
    with_call(Ep, fun(C) ->
        case chappe_esl_call:playback(C, File, Opts) of
            {ok, Ev} -> chappe_mrf_lib:playback_result(Ev);
            Err -> Err
        end
    end).

%% Play a prompt and collect digits: {ok, Digits}, <<>> when none came.
%% Opts: file (the prompt, required), min (1), max (1), tries (1),
%% timeout (5000 ms), terminators (<<"#">>), invalid_file, digit_timeout,
%% regexp. result => full returns #{digits, terminator, invalid} instead:
%% the terminator pressed and the last entry the regexp refused (<<>> for
%% none).
-spec play_collect(endpoint(), map()) ->
    {ok, binary() | chappe_esl_call:digits()} | {error, term()}.
play_collect(Ep, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:play_and_get_digits(C, Opts) end).

%% Record the caller to Path, a file the node writes. Opts: max_secs,
%% silence_thresh, silence_hits, timeout. store => default adopts the
%% finished file into the recording store (chappe_audio_store) under the
%% endpoint's call_ref (ref => Bin to choose another, parties => [...]
%% for its sidecar) and returns {ok, Id}; Path must then be in the folder
%% FreeSWITCH shares with this node (the shared_dir env).
-spec record(endpoint(), iodata(), map()) ->
    ok | {ok, binary()} | {error, term()}.
record(Ep, Path, Opts) ->
    with_call(Ep, fun(C) ->
        Fs = maps:without(?STORE_OPTS, Opts),
        case chappe_mrf_lib:done(chappe_esl_call:record(C, Path, Fs)) of
            ok -> chappe_mrf_store:recorded(Ep, Path, Opts);
            Err -> Err
        end
    end).

%% Record both directions of the channel to Path until
%% record_session_stop/2 or the hangup.
-spec record_session(endpoint(), iodata()) -> ok | {error, term()}.
record_session(Ep, Path) ->
    record_session(Ep, Path, #{}).

%% record_session/2 with store => default (and ref, parties) as for
%% record/3: the file is adopted into the store once FreeSWITCH has
%% closed it (its RECORD_STOP, after record_session_stop/2 or the
%% hangup), and the owner gets {recorded, Id}.
-spec record_session(endpoint(), iodata(), map()) -> ok | {error, term()}.
record_session(Ep, Path, Opts) ->
    with_call(Ep, fun(C) ->
        chappe_mrf_store:record_session(C, Ep, Path, Opts)
    end).

-spec record_session_stop(endpoint(), iodata()) -> ok | {error, term()}.
record_session_stop(Ep, Path) ->
    with_call(Ep, fun(C) ->
        chappe_mrf_store:record_session_stop(C, Ep, Path)
    end).

%% Say a number, a date, digits... in a language, with the node's mod_say
%% module and its sound files: chappe_esl_call:say/3 for the options
%% (language, type, method, gender).
-spec say(endpoint(), iodata(), map()) -> ok | {error, term()}.
say(Ep, Text, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:say(C, Text, Opts) end).

%% Speak text with the node's text to speech module. Opts: engine (as
%% <<"flite">>, or a vendor module) and voice, see chappe_esl_call:speak/3.
-spec speak(endpoint(), iodata(), map()) -> ok | {error, term()}.
speak(Ep, Text, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:speak(C, Text, Opts) end).

%% Listen for the tones of a mod_spandsp descriptor (Name, from the node's
%% spandsp.conf): the owner gets {chappe_mrf, Ep, {tone, ToneName}} each
%% time one is heard, until stop_detect_tones/1 or the hangup.
-spec detect_tones(endpoint(), iodata()) -> ok | {error, term()}.
detect_tones(Ep, Name) ->
    with_call(Ep, fun(C) -> chappe_esl_call:detect_tones(C, Name) end).

-spec stop_detect_tones(endpoint()) -> ok | {error, term()}.
stop_detect_tones(Ep) ->
    with_call(Ep, fun chappe_esl_call:stop_detect_tones/1).

%% Listen for a fax: the owner gets {chappe_mrf, Ep, {fax, detected}}.
%% detect_fax/2 takes tone (cng, a calling fax, the default; ced, an
%% answering one) and timeout (seconds, 0 for none).
-spec detect_fax(endpoint()) -> ok | {error, term()}.
detect_fax(Ep) ->
    detect_fax(Ep, #{}).

-spec detect_fax(endpoint(), map()) -> ok | {error, term()}.
detect_fax(Ep, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:detect_fax(C, Opts) end).

-spec stop_detect_fax(endpoint()) -> ok | {error, term()}.
stop_detect_fax(Ep) ->
    with_call(Ep, fun chappe_esl_call:stop_detect_fax/1).

-spec send_dtmf(endpoint(), iodata()) -> ok | {error, term()}.
send_dtmf(Ep, Digits) ->
    with_call(Ep, fun(C) -> chappe_esl_call:send_dtmf(C, Digits) end).

-spec set(endpoint(), iodata(), iodata()) -> ok | {error, term()}.
set(Ep, Var, Value) ->
    with_call(Ep, fun(C) -> chappe_esl_call:set(C, Var, Value) end).

%% Set several channel variables at once (multiset).
-spec set(endpoint(), #{iodata() => iodata()}) -> ok | {error, term()}.
set(Ep, Vars) ->
    with_call(Ep, fun(C) -> chappe_esl_call:multiset(C, Vars) end).

%% Set a variable on the channel and on any channel it gets bridged to.
-spec export(endpoint(), iodata(), iodata()) -> ok | {error, term()}.
export(Ep, Var, Value) ->
    with_call(Ep, fun(C) -> chappe_esl_call:export(C, Var, Value) end).

%% One channel variable (uuid_getvar): undefined when it is not set.
-spec var(endpoint(), iodata()) -> {ok, binary() | undefined} | {error, term()}.
var(Ep, Name) ->
    with_call(Ep, fun(C) -> chappe_esl_call:getvar(C, Name) end).

%% Every channel variable (uuid_dump), by name without variable_.
-spec vars(endpoint()) -> {ok, #{binary() => binary()}} | {error, term()}.
vars(Ep) ->
    with_call(Ep, fun chappe_esl_call:dump/1).

%% Mute the caller toward the node (read) or the node toward the caller
%% (write), with uuid_audio; unmute/2 undoes it.
-spec mute(endpoint(), read | write) -> ok | {error, term()}.
mute(Ep, Dir) ->
    with_call(Ep, fun(C) -> chappe_esl_call:mute(C, Dir) end).

-spec unmute(endpoint(), read | write) -> ok | {error, term()}.
unmute(Ep, Dir) ->
    with_call(Ep, fun(C) -> chappe_esl_call:unmute(C, Dir) end).

%% An api command on the endpoint's node (over its socket).
-spec api(endpoint(), iodata()) -> {ok, binary()} | {error, term()}.
api(Ep, Cmd) ->
    with_call(Ep, fun(C) -> chappe_esl_call:api(C, Cmd) end).

%% Run any dialplan application on the channel and wait for it.
-spec execute(endpoint(), iodata(), iodata()) ->
    {ok, chappe_esl_event:event()} | {error, term()}.
execute(Ep, App, Args) ->
    execute(Ep, App, Args, #{}).

%% Opts: chappe_esl_call:exec_opts(). With wait => false it returns
%% {ok, AppUuid} once the node took the command, and the owner gets
%% {chappe_mrf, Ep, {complete, App, Ev}} when it ends.
-spec execute(endpoint(), iodata(), iodata(), chappe_esl_call:exec_opts()) ->
    {ok, chappe_esl_event:event() | binary()} | {error, term()}.
execute(Ep, App, Args, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:exec(C, App, Args, Opts) end).

%% Stream the channel's audio to a WebSocket (mod_audio_fork). Opts:
%% mix (mono | mixed | stereo: stereo puts the caller on the left and
%% what the node sends on the right), rate, metadata, module
%% (audio_fork | audio_stream), bugname (mod_audio_fork: a name per fork,
%% to run several on one channel). A stereo fork of mod_audio_stream sends
%% only while both directions carry audio (FreeSWITCH's and the module's
%% behaviour): mono or mixed send whenever the caller does.
-spec fork_audio_start(endpoint(), iodata(), map()) -> ok | {error, term()}.
fork_audio_start(Ep, Url, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:audio_fork_start(C, Url, Opts) end).

-spec fork_audio_stop(endpoint()) -> ok | {error, term()}.
fork_audio_stop(Ep) ->
    with_call(Ep, fun chappe_esl_call:audio_fork_stop/1).

%% Pause, resume or send text on the endpoint's forks: all of them, or
%% those Sel names (module, bugname). {error, not_forking} when none runs.
-spec fork_audio_pause(endpoint()) -> ok | {error, term()}.
fork_audio_pause(Ep) ->
    fork_audio_pause(Ep, #{}).

-spec fork_audio_pause(endpoint(), chappe_esl_call:fork_select()) ->
    ok | {error, term()}.
fork_audio_pause(Ep, Sel) ->
    with_call(Ep, fun(C) -> chappe_esl_call:audio_fork_pause(C, Sel) end).

-spec fork_audio_resume(endpoint()) -> ok | {error, term()}.
fork_audio_resume(Ep) ->
    fork_audio_resume(Ep, #{}).

-spec fork_audio_resume(endpoint(), chappe_esl_call:fork_select()) ->
    ok | {error, term()}.
fork_audio_resume(Ep, Sel) ->
    with_call(Ep, fun(C) -> chappe_esl_call:audio_fork_resume(C, Sel) end).

%% Text to the fork's server, as a WebSocket text frame.
-spec fork_audio_send_text(endpoint(), iodata()) -> ok | {error, term()}.
fork_audio_send_text(Ep, Text) ->
    fork_audio_send_text(Ep, Text, #{}).

-spec fork_audio_send_text(
    endpoint(), iodata(), chappe_esl_call:fork_select()
) -> ok | {error, term()}.
fork_audio_send_text(Ep, Text, Sel) ->
    with_call(Ep, fun(C) ->
        chappe_esl_call:audio_fork_send_text(C, Text, Sel)
    end).

%% Put the channel on hold or take it off (uuid_hold), or send a new SDP
%% offer on the endpoint's own dialog (an endpoint of create_endpoint/1
%% not bridged): {ok, Answer}.
-spec modify(endpoint(), hold | unhold | binary()) ->
    ok | {ok, binary()} | {error, term()}.
modify(Ep, hold) ->
    hold(Ep, <<"uuid_hold ">>);
modify(Ep, unhold) ->
    hold(Ep, <<"uuid_hold off ">>);
modify(Ep, Sdp) when is_binary(Sdp) ->
    case chappe_mrf_endpoint:info(Ep) of
        #{dialog := D, bridged := false} when D =/= undefined ->
            try
                chappe_sip_dialog:modify(D, Sdp)
            catch
                exit:Why -> {error, Why}
            end;
        #{} ->
            {error, no_dialog};
        Err ->
            Err
    end.

hold(Ep, Cmd) ->
    case uuid(Ep) of
        {ok, Uuid} -> chappe_mrf_lib:done(api(Ep, [Cmd, Uuid]));
        Err -> Err
    end.

%% Hang the channel up and free the endpoint.
-spec destroy(endpoint()) -> ok.
destroy(Ep) ->
    chappe_mrf_endpoint:destroy(Ep).

-spec uuid(endpoint()) -> {ok, binary()} | {error, term()}.
uuid(Ep) ->
    case chappe_mrf_endpoint:info(Ep) of
        #{uuid := Uuid} when is_binary(Uuid) -> {ok, Uuid};
        #{} -> {error, not_connected};
        Err -> Err
    end.

%% The chappe_esl node the endpoint's channel is on.
-spec node(endpoint()) -> {ok, term()} | {error, term()}.
node(Ep) ->
    case chappe_mrf_endpoint:info(Ep) of
        #{node := Node} -> {ok, Node};
        Err -> Err
    end.

-spec info(endpoint()) -> map() | {error, term()}.
info(Ep) ->
    chappe_mrf_endpoint:info(Ep).

%% ---- conferences ----

%% Start (or find) the conference Name. See chappe_mrf_conf:start/2.
-spec conference(binary(), map()) ->
    {ok, chappe_mrf_conf:conf()} | {error, term()}.
conference(Name, Opts) ->
    chappe_mrf_conf:start(Name, Opts).

%% The conferences running: [{Name, Conf}].
-spec conferences() -> [{binary(), chappe_mrf_conf:conf()}].
conferences() ->
    lists:sort([
        {N, P}
     || {{conf, N}, P} <- chappe_mrf_registry:select({conf, '_'})
    ]).

%% A chappe_sip:refer/1 handler for REFERs to a conference's URI: the
%% room named by the Request-URI's user decides and carries it out
%% (chappe_mrf_conf_refer), 404 when there is none. Register it with
%% chappe_sip:refer(fun chappe_mrf:focus_refer/2).
-spec focus_refer(chappe_sip_req:req(), chappe_sip_res:res()) -> ok.
focus_refer(Req, Res) ->
    chappe_mrf_conf_refer:focus(Req, Res).

%% A SUBSCRIBE to the conference package for a conference of ours (the
%% user of the Request-URI names it): chappe_sip_focus serves it. Register
%% it with chappe_sip:event_package(<<"conference">>, fun
%% chappe_mrf:focus_subscribe/2).
-spec focus_subscribe(chappe_sip_req:req(), chappe_sip_res:res()) -> ok.
focus_subscribe(Req, Res) ->
    Name =
        case chappe_sip_uri:parse(chappe_sip_req:uri(Req)) of
            {ok, #{user := U}} -> U;
            _ -> undefined
        end,
    case chappe_mrf_registry:lookup({conf, Name}) of
        {ok, Conf} ->
            _ = chappe_mrf_conf:subscribe(Conf, Req, Res),
            ok;
        error ->
            _ = chappe_sip_res:send(Res, 404),
            ok
    end.

%% ---- internal ----

%% the options checked before anything starts
check_opts(#{call_ref := Ref}) when not is_binary(Ref); Ref =:= <<>> ->
    {error, {bad_option, call_ref}};
check_opts(#{call_ref := Ref} = Opts) ->
    %% it goes in a SIP header value
    case binary:match(Ref, [<<"\r">>, <<"\n">>, <<"\0">>]) of
        nomatch -> check_opts(maps:remove(call_ref, Opts));
        _ -> {error, {bad_option, call_ref}}
    end;
check_opts(Opts) ->
    chappe_mrf_endpoint:check_events(maps:get(events, Opts, [])).

with_call(Ep, Fun) ->
    case chappe_mrf_endpoint:call(Ep) of
        {ok, Call} -> Fun(Call);
        {error, _} = Err -> Err
    end.

with_user(Uri, User) ->
    {ok, U} = chappe_sip_uri:parse(Uri),
    chappe_sip_uri:format(U#{user => User}).

%% the nodes a call may go to, first choice first
candidates(#{targets := Targets}) ->
    Targets;
candidates(#{node := Node}) ->
    [{Node, U} || U <- [sip_uri(Node)], U =/= undefined];
candidates(Opts) ->
    First =
        case chappe_esl:node_select(maps:get(select, Opts, #{})) of
            {ok, N} -> [N];
            {error, _} -> []
        end,
    Up = [N || {N, up} <- chappe_esl:nodes(), not lists:member(N, First)],
    [{N, U} || N <- First ++ Up, U <- [sip_uri(N)], U =/= undefined].

sip_uri(Node) ->
    case chappe_esl:node_status(Node) of
        {ok, #{sip_uri := Uri}} when is_binary(Uri) -> Uri;
        _ -> undefined
    end.
