%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_mrf: a media resource function in the drachtio-fsmrf style.
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
%% the listener of start/1 (or the `esl_port' app env). The INVITE carries
%% X-Chappe-Call; FreeSWITCH reports it as variable_sip_h_X-Chappe-Call,
%% which is how the socket finds its endpoint.
%%
%% The endpoint's owner gets {chappe_mrf, Ep, Event}: {dtmf, Digit},
%% {hangup, Cause}, {node_down, Node}. The notify process of a call
%% (connect_caller's notify option, default the owner) gets the call's
%% {chappe_sip_b2b, Ref, Event}, and {chappe_sip_b2b, Ref, {done, Why}}
%% when it ends.
%%
%% Out of scope: say and speak (text to speech needs FreeSWITCH modules
%% the lab does not load; run them with execute/3 where they exist).
-module(chappe_mrf).

-export([start/1, listen/1, stop_listener/0, install/0]).
-export([connect_caller/3, create_endpoint/1, bridge/2, bridge/3]).
-export([play/2, play/3, play_collect/2, record/3]).
-export([record_session/2, record_session_stop/2, send_dtmf/2, set/3]).
-export([api/2, execute/3, fork_audio_start/3, fork_audio_stop/1]).
-export([modify/2, destroy/1, uuid/1, node/1, info/1]).
-export([conference/2, conferences/0, focus_subscribe/2]).
-export([inactive_sdp/0, loop_target/1]).

-export_type([endpoint/0]).

-type endpoint() :: chappe_mrf_endpoint:endpoint().

-define(LISTENER, {?MODULE, listener}).
-define(LOOP_PREFIX, "mrf-mix-").

%% ---- setup ----

%% Run after chappe_sip:start/1. Opts: esl_port (the outbound socket
%% listener FreeSWITCH connects back to). It also installs the INVITE
%% middleware the native conference backend relies on (install/0).
-spec start(#{esl_port => inet:port_number()}) -> ok | {error, term()}.
start(Opts) ->
    ok = install(),
    case maps:find(esl_port, Opts) of
        {ok, Port} -> listen(Port);
        error -> ok
    end.

%% Listen for FreeSWITCH outbound sockets on Port.
-spec listen(inet:port_number()) -> ok | {error, term()}.
listen(Port) ->
    case chappe_esl:start_listener(Port, chappe_mrf_esl, []) of
        {ok, _} ->
            persistent_term:put(?LISTENER, Port),
            ok;
        {error, already_started} ->
            ok;
        {error, _} = Err ->
            Err
    end.

-spec stop_listener() -> ok | {error, term()}.
stop_listener() ->
    case persistent_term:get(?LISTENER, undefined) of
        undefined ->
            ok;
        Port ->
            _ = persistent_term:erase(?LISTENER),
            chappe_esl:stop_listener(Port)
    end.

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
%%   relay    => options of chappe_sip_b2b:relay/2
%% and any chappe_sip_b2b:create_b2bua/4 option (media defaults to
%% anchor, b_headers get X-Chappe-Call). Returns the endpoint and the
%% call's handle; the call runs in its own process (relay_async/2), so
%% the caller is free to drive the endpoint.
-spec connect_caller(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, endpoint(), chappe_sip_b2b:b2b()} | {error, term()}.
connect_caller(Req, Res, Opts) ->
    Owner = maps:get(owner, Opts, self()),
    case candidates(Opts) of
        [] ->
            _ = chappe_sip_res:send(Res, 503, #{
                reason => <<"Service Unavailable">>
            }),
            {error, no_node};
        Cands ->
            Id = chappe_mrf_lib:new_id(),
            {ok, Ep} = chappe_mrf_endpoint:start(#{
                id => Id, owner => Owner, candidates => Cands
            }),
            User = maps:get(user, Opts, <<"mrf">>),
            Uris = [with_user(U, User) || {_, U} <- Cands],
            Notify = maps:get(notify, Opts, Owner),
            B2bOpts = (maps:without(
                [owner, node, select, targets, user, attach_timeout, relay],
                Opts
            ))#{
                media => maps:get(media, Opts, anchor),
                b_headers => [
                    {chappe_mrf_esl:header(), Id}
                    | maps:get(b_headers, Opts, [])
                ],
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
%% node, select, targets, user (as for connect_caller/3), sdp (the offer,
%% default inactive_sdp/0), headers, timeout (ms for the INVITE, 32000),
%% attach_timeout.
-spec create_endpoint(map()) -> {ok, endpoint()} | {error, term()}.
create_endpoint(Opts) ->
    Owner = maps:get(owner, Opts, self()),
    case candidates(Opts) of
        [] -> {error, no_node};
        Cands -> try_endpoint(Cands, Owner, Opts, {error, no_node})
    end.

try_endpoint([], _Owner, _Opts, Last) ->
    Last;
try_endpoint([{Node, Uri} | Rest], Owner, Opts, _Last) ->
    Id = chappe_mrf_lib:new_id(),
    {ok, Ep} = chappe_mrf_endpoint:start(#{
        id => Id, owner => Owner, candidates => [{Node, Uri}]
    }),
    UacOpts = #{
        local_sdp => maps:get(sdp, Opts, inactive_sdp()),
        headers => [
            {chappe_mrf_esl:header(), Id} | maps:get(headers, Opts, [])
        ],
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

%% Opts: chappe_esl_call:exec_opts() (timeout, ...).
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
    with_call(Ep, fun(C) ->
        chappe_mrf_lib:done(chappe_esl_call:playback(C, File, Opts))
    end).

%% Play a prompt and collect digits: {ok, Digits}, <<>> when none came.
%% Opts: file (the prompt, required), min (1), max (1), tries (1),
%% timeout (5000 ms), terminators (<<"#">>), invalid_file, digit_timeout,
%% regexp.
-spec play_collect(endpoint(), map()) -> {ok, binary()} | {error, term()}.
play_collect(Ep, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:play_and_get_digits(C, Opts) end).

%% Record the caller to Path, a file the node writes. Opts: max_secs,
%% silence_thresh, silence_hits, timeout.
-spec record(endpoint(), iodata(), map()) -> ok | {error, term()}.
record(Ep, Path, Opts) ->
    with_call(Ep, fun(C) ->
        chappe_mrf_lib:done(chappe_esl_call:record(C, Path, Opts))
    end).

%% Record both directions of the channel to Path until
%% record_session_stop/2 or the hangup.
-spec record_session(endpoint(), iodata()) -> ok | {error, term()}.
record_session(Ep, Path) ->
    with_call(Ep, fun(C) -> chappe_esl_call:record_session(C, Path) end).

-spec record_session_stop(endpoint(), iodata()) -> ok | {error, term()}.
record_session_stop(Ep, Path) ->
    with_call(Ep, fun(C) -> chappe_esl_call:record_session_stop(C, Path) end).

-spec send_dtmf(endpoint(), iodata()) -> ok | {error, term()}.
send_dtmf(Ep, Digits) ->
    with_call(Ep, fun(C) -> chappe_esl_call:send_dtmf(C, Digits) end).

-spec set(endpoint(), iodata(), iodata()) -> ok | {error, term()}.
set(Ep, Var, Value) ->
    with_call(Ep, fun(C) -> chappe_esl_call:set(C, Var, Value) end).

%% An api command on the endpoint's node (over its socket).
-spec api(endpoint(), iodata()) -> {ok, binary()} | {error, term()}.
api(Ep, Cmd) ->
    with_call(Ep, fun(C) -> chappe_esl_call:api(C, Cmd) end).

%% Run any dialplan application on the channel and wait for it.
-spec execute(endpoint(), iodata(), iodata()) ->
    {ok, chappe_esl_event:event()} | {error, term()}.
execute(Ep, App, Args) ->
    with_call(Ep, fun(C) -> chappe_esl_call:exec(C, App, Args) end).

%% Stream the channel's audio to a WebSocket (mod_audio_fork). Opts:
%% mix (mono | mixed | stereo), rate, metadata.
-spec fork_audio_start(endpoint(), iodata(), map()) -> ok | {error, term()}.
fork_audio_start(Ep, Url, Opts) ->
    with_call(Ep, fun(C) -> chappe_esl_call:audio_fork_start(C, Url, Opts) end).

-spec fork_audio_stop(endpoint()) -> ok | {error, term()}.
fork_audio_stop(Ep) ->
    with_call(Ep, fun chappe_esl_call:audio_fork_stop/1).

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
