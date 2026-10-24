%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Public facade: the srf-like API.
%%
%% Bring the stack up with start/1, register middleware with use/1,2 and
%% method handlers with handle/2 or the method shortcuts. Handlers run in
%% a per-request worker process (fun(Req, Res)); middleware is
%% fun(Req, Res, Next).
%%
%% Dialog creation (create_uas/create_uac/create_b2bua/proxy_request)
%% lands in M3..M6.
-module(chappe_sip).

-export([start/1, stop/0, ws_listen/1]).
-export([use/1, use/2, handle/2, handle/3]).
-export([
    create_uas/3,
    create_uac/2,
    create_b2bua/4,
    proxy_request/3,
    request/2
]).
-export([
    invite/1,
    options/1,
    message/1,
    info/1,
    notify/1,
    bye/1,
    subscribe/1,
    subscribe/2,
    publish/1,
    refer/1,
    update/1,
    register/1
]).
-export([registrar/1, location/1, location_flow/1, bindings/1]).
-export([
    find_dialog/3, find_replaced/1, replaces_response/1, replaces_response/2
]).
-export([accept_refer/3, accept_refer/4, send_refer/3]).
-export([event_package/2, subscribe_to/3, unsubscribe/1, publish_state/4]).
-export([
    peer_add/2,
    peer_remove/1,
    peers/0,
    peer_status/1,
    peer_select/2,
    peer_subscribe/1
]).

-export_type([replaced_info/0]).

%% What find_replaced/1 learned about the dialog a Replaces names.
-type replaced_info() :: #{
    state := early | confirmed | terminated,
    role := uas | uac,
    early_only := boolean()
}.

%% Opts: #{contact := binary() | [binary()], max_message_size => pos_integer(),
%%         tls => #{contact := binary() | [binary()], cert_dir => binary(),
%%                  passphrase => binary(), verify => peer | none,
%%                  verify_clients => boolean(), allow_insecure => boolean()},
%%         ws => #{port := inet:port_number()},
%%         wss => #{port := inet:port_number(), cert_dir => binary()},
%%         presence => map(),
%%         hep => #{host := inet:ip_address() | string() | binary(),
%%                  port := 1024..65535, version => 3,
%%                  capture_id => pos_integer()}}
%% presence serves the presence package once the stack is up
%% (chappe_sip_presence:serve/1 takes the map).
%% The tls contact binds a TLS listener on its own port (e.g.
%% <<"sips:0.0.0.0:5061;transport=tls">>); cert_dir holds agent.pem and
%% cafile.pem. verify (default peer) checks outbound server certificates;
%% none is accepted only with allow_insecure => true. wss serves SIP over
%% secure WebSocket with the agent.pem of its cert_dir (or certfile/keyfile).
%% contact (and tls contact) may list several URIs, one per listen address:
%% a request is answered, and record-routed, with the address it came to.
%% max_message_size defaults to the application setting. hep (or the
%% `hep' application setting) sends a HEPv3 copy of every SIP message sent
%% and received to a capture server (Homer); capture_id defaults to 200.
-spec start(#{contact := binary() | [binary()], _ => _}) ->
    ok | {error, already_started | term()}.
start(Opts) ->
    case start_hep(maps:get(hep, Opts, chappe_sip_config:get(hep))) of
        ok -> start_listeners(Opts);
        {error, _} = Err -> Err
    end.

%% WS capture is Erlang (chappe_sip_hep); the native transports are
%% captured by the engine from the same option
start_hep(undefined) ->
    chappe_sip_hep:configure(undefined);
start_hep(Hep) ->
    case chappe_sip_hep:validate(Hep) of
        {ok, Cfg} -> chappe_sip_hep:configure(Cfg);
        {error, _} = Err -> Err
    end.

start_listeners(Opts) ->
    %% an optional WS listener runs independently of the sofia engine; a bind
    %% failure must surface, not be swallowed
    case
        start_ws(maps:get(ws, Opts, undefined), maps:get(wss, Opts, undefined))
    of
        ok ->
            start_media(maps:get(media, Opts, undefined), Opts);
        {error, Reason} ->
            {error, {ws, Reason}}
    end.

%% the media control plane is optional and dormant unless configured; a
%% backend that fails to come up surfaces rather than being swallowed
start_media(MediaOpts, Opts) ->
    case chappe_sip_media:configure(MediaOpts) of
        ok ->
            case maps:is_key(contact, Opts) of
                true ->
                    start_presence(
                        chappe_sip_engine:start(
                            maps:without([ws, wss, media, presence], Opts)
                        ),
                        Opts
                    );
                false ->
                    ok
            end;
        {error, Reason} ->
            {error, {media, Reason}}
    end.

%% presence => Opts serves the presence package (chappe_sip_presence:serve/1)
start_presence(ok, #{presence := Opts}) -> chappe_sip_presence:serve(Opts);
start_presence(Result, _Opts) -> Result.

start_ws(undefined, undefined) -> ok;
start_ws(undefined, Wss) -> ws_listen(#{tls => Wss});
start_ws(Ws, undefined) -> ws_listen(Ws);
start_ws(Ws, Wss) -> ws_listen(Ws#{tls => Wss}).

%% Start (or replace) the SIP-over-WebSocket listener. Opts: #{port := P}
%% for plain WS, plus tls => #{port := P, cert_dir := Dir} for WSS.
-spec ws_listen(map()) -> ok | {error, term()}.
ws_listen(Opts) ->
    case chappe_sip_ws_sup:start_listener(Opts) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        Err -> Err
    end.

-spec stop() -> ok | {error, not_started | hung}.
stop() ->
    _ = chappe_sip_ws_sup:stop_listener(),
    _ = chappe_sip_hep:configure(undefined),
    chappe_sip_engine:stop().

-spec use(chappe_sip_middleware:mw()) -> ok.
use(Fun) ->
    chappe_sip_engine:use('*', Fun).

-spec use(binary(), chappe_sip_middleware:mw()) -> ok.
use(Method, Fun) ->
    chappe_sip_engine:use(Method, Fun).

-spec handle(binary(), fun(
    (chappe_sip_req:req(), chappe_sip_res:res()) -> any()
)) -> ok.
handle(Method, Fun) ->
    handle(Method, Fun, #{}).

%% handle/2 with route options:
%%   option_tags => [binary()]  option tags the handler supports on top of
%%       the supported_option_tags setting: a request may list them in
%%       Require without a 420, and so may the in-dialog requests of a
%%       dialog it creates (siprec for a recording server, RFC 7866 6.1.1)
%%   proxy => true  the handler proxies (proxy_request/3): Require is left
%%       to the far UAS and only Proxy-Require is checked (RFC 3261 16.3);
%%       a handler that also answers some requests itself checks Require
%% The ready-made registrar supports Path and outbound: register it with
%% handle(<<"REGISTER">>, registrar(...), #{option_tags => [<<"path">>,
%% <<"outbound">>]}) to take them in Require.
-spec handle(
    binary(),
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> any()),
    #{option_tags => [binary()], proxy => boolean()}
) -> ok.
handle(Method, Fun, Opts) ->
    chappe_sip_engine:handle(Method, Fun, Opts).

%% Answer an incoming dialog-forming request as a UAS. See chappe_sip_dialog.
-spec create_uas(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
create_uas(Req, Res, Opts) ->
    chappe_sip_dialog:create_uas(Req, Res, Opts).

%% Originate a UAC request. For INVITE, blocks until the final result:
%% {ok, Dialog} on 2xx, {error, #chappe_sip_error{}} on a non-2xx final.
%% Provisional responses are forwarded to a notify pid if one is given.
%% The body is `local_sdp' (sent as application/sdp) or, for anything else,
%% `body' with `content_type' (a SIPREC multipart/mixed, for instance).
%% The peer's answer is on the dialog: chappe_sip_dialog:remote_sdp/1.
%% When `timeout' (ms, default 32000) passes first, the INVITE is CANCELled
%% (and a 2xx that still comes is ACKed and BYEd) and you get
%% {error, timeout}.
-spec create_uac(binary(), map()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
create_uac(Uri, Opts) ->
    case chappe_sip_uac:start(Uri, Opts) of
        {ok, Ref} ->
            case chappe_sip_uac:await(Ref, maps:get(timeout, Opts, 32000)) of
                {error, timeout} ->
                    %% the INVITE is still out there: CANCEL it, and BYE a
                    %% 2xx that races in (RFC 3261 9.1, 15)
                    ok = chappe_sip_uac:abandon(Ref),
                    receive
                        {chappe_sip_uac, Ref, {ok, _Dialog}} -> ok
                    after 0 -> ok
                    end,
                    {error, timeout};
                Result ->
                    Result
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Send an out-of-dialog, non-dialog-forming request (OPTIONS, REGISTER,
%% MESSAGE, ...). Returns a ref; responses arrive as events, or use
%% chappe_sip_uac:await_response/2. Without a `method' option the URI's
%% method parameter names it (RFC 3261 19.1.5), else OPTIONS.
-spec request(binary(), map()) ->
    {ok, chappe_sip_uac:uac_ref()} | {error, term()}.
request(Uri, Opts) ->
    Default =
        case chappe_sip_uri:take_param(Uri, <<"method">>) of
            {M, _} when is_binary(M), M =/= <<>> -> M;
            _ -> <<"OPTIONS">>
        end,
    chappe_sip_uac:start(Uri, maps:merge(#{method => Default}, Opts)).

%% Bridge an incoming INVITE (A/UAS) to a new INVITE toward Uri (B/UAC).
%% Returns both dialogs; use chappe_sip_b2b:relay/1 to link their lifecycles.
-spec create_b2bua(chappe_sip_req:req(), chappe_sip_res:res(), binary(), map()) ->
    {ok, #{
        uas := chappe_sip_dialog:dialog(), uac := chappe_sip_dialog:dialog()
    }}
    | {error, term()}.
create_b2bua(Req, Res, Uri, Opts) ->
    chappe_sip_b2b:create_b2bua(Req, Res, Uri, Opts).

%% Proxy an incoming request to one or more targets (RFC 3261 16). A
%% target is a URI (or host[:port]), {ws, Flow} (a WS connection), or
%% {flow, Uri, Flow}: the contact Uri reached over the RFC 5626 flow of its
%% binding (location_flow/1). Opts:
%%   forking => sequential | parallel, record_route => boolean,
%%   timer_c => ms (Timer C per INVITE branch, default timer_c_ms).
%% Returns the aggregate result.
-spec proxy_request(chappe_sip_req:req(), Dest | [Dest], map()) ->
    {ok, map()} | {error, term()}
when
    Dest ::
        binary()
        | {ws, integer()}
        | {flow, binary(), chappe_sip_engine:flow()}.
proxy_request(Req, Dest, Opts) ->
    chappe_sip_proxy:proxy_request(Req, Dest, Opts).

-spec invite(fun()) -> ok.
invite(F) -> handle(<<"INVITE">>, F).

-spec options(fun()) -> ok.
options(F) -> handle(<<"OPTIONS">>, F).

-spec message(fun()) -> ok.
message(F) -> handle(<<"MESSAGE">>, F).

-spec info(fun()) -> ok.
info(F) -> handle(<<"INFO">>, F).

%% The NOTIFYs no subscription of ours (subscribe_to/3) and no REFER we
%% sent (send_refer/3) claims; without a handler they get 481.
-spec notify(fun()) -> ok.
notify(F) -> handle(<<"NOTIFY">>, F).

-spec bye(fun()) -> ok.
bye(F) -> handle(<<"BYE">>, F).

-spec subscribe(fun()) -> ok.
subscribe(F) -> handle(<<"SUBSCRIBE">>, F).

%% A SUBSCRIBE handler for these event packages only: any other package
%% (or a SUBSCRIBE without Event) is answered 489 with Allow-Events
%% listing them, and the handler never runs.
-spec subscribe([binary()], fun()) -> ok.
subscribe(Events, F) ->
    chappe_sip_engine:handle(<<"SUBSCRIBE">>, F, #{
        events => [string:lowercase(E) || E <- Events]
    }).

%% The SUBSCRIBE handler of one event package (RFC 6665): a SUBSCRIBE
%% whose Event names Package (case-insensitively) runs Handler, whatever
%% subscribe/1,2 registered, which stays the catch-all. The packages you
%% register are in Allow-Events (OPTIONS 200, the 489 to a package nobody
%% serves). chappe_sip_focus serves `conference' this way.
-spec event_package(binary(), fun(
    (chappe_sip_req:req(), chappe_sip_res:res()) -> any()
)) -> ok.
event_package(Package, Handler) ->
    chappe_sip_engine:handle(<<"SUBSCRIBE">>, Handler, #{package => Package}).

%% Subscribe to Event at Uri (RFC 6665 subscriber side): a process holds
%% the subscription, refreshes it, re-subscribes when the notifier asks,
%% and sends the owner (default the caller) {chappe_sip_subscription, Sub,
%% Event} for each NOTIFY and its end. See chappe_sip_subscriber.
-spec subscribe_to(binary(), binary(), map()) ->
    {ok, chappe_sip_subscriber:subscription()} | {error, term()}.
subscribe_to(Uri, Event, Opts) ->
    chappe_sip_subscriber:start(Uri, Event, Opts#{
        owner => maps:get(owner, Opts, self())
    }).

%% End a subscription subscribe_to/3 started (SUBSCRIBE with Expires: 0).
-spec unsubscribe(chappe_sip_subscriber:subscription()) -> ok.
unsubscribe(Sub) ->
    chappe_sip_subscriber:unsubscribe(Sub).

%% The PUBLISH handler: a fun, or the options of the event state
%% compositor (RFC 3903, see chappe_sip_esc:handler/1), which keeps the
%% state the PUBLISHes set.
-spec publish(fun() | map()) -> ok.
publish(F) when is_function(F, 2) -> handle(<<"PUBLISH">>, F);
publish(Opts) when is_map(Opts) ->
    handle(<<"PUBLISH">>, chappe_sip_esc:handler(Opts)).

%% Publish event state at Uri (RFC 3903, the client side): a process
%% sends the PUBLISH, keeps it refreshed, and republishes it in full if the
%% compositor forgot it (412). Body is the state (a PIDF for presence,
%% chappe_sip_pidf:render/1). See chappe_sip_publisher.
-spec publish_state(binary(), binary(), iodata(), map()) ->
    {ok, chappe_sip_publisher:publication()} | {error, term()}.
publish_state(Uri, Event, Body, Opts) ->
    chappe_sip_publisher:start(Uri, Event, Body, Opts#{
        owner => maps:get(owner, Opts, self())
    }).

-spec refer(fun()) -> ok.
refer(F) -> handle(<<"REFER">>, F).

%% Accept a REFER received outside any dialog (in a refer/1 handler): 200
%% (never 202, RFC 7647) and the implicit subscription, or the rejection
%% check/2 decides. Report the referenced request with
%% chappe_sip_refer:progress/2 and final/2. See chappe_sip_refer.
-spec accept_refer(chappe_sip_req:req(), chappe_sip_res:res(), map()) ->
    {ok, chappe_sip_refer:refer()} | {error, term()}.
accept_refer(Req, Res, Opts) ->
    chappe_sip_refer:accept(Req, Res, Opts).

%% Accept a REFER received in Dialog (the dialog's refer event).
-spec accept_refer(
    chappe_sip_dialog:dialog(),
    chappe_sip_req:req(),
    chappe_sip_res:res(),
    map()
) ->
    {ok, chappe_sip_refer:refer()} | {error, term()}.
accept_refer(Dialog, Req, Res, Opts) ->
    chappe_sip_refer:accept(Dialog, Req, Res, Opts).

%% Send a REFER in a dialog or outside one (to a URI) and wait for its
%% answer; the NOTIFYs then reach the owner as {refer_progress, Id, Code}
%% and {refer_done, Id, Code}. See chappe_sip_refer:send/3.
-spec send_refer(
    chappe_sip_dialog:dialog() | binary(), binary() | map(), map()
) ->
    {ok, reference(), map()} | {error, term()}.
send_refer(To, Target, Opts) ->
    chappe_sip_refer:send(To, Target, Opts).

-spec update(fun()) -> ok.
update(F) -> handle(<<"UPDATE">>, F).

-spec register(fun()) -> ok.
register(F) -> handle(<<"REGISTER">>, F).

%% A ready-made REGISTER handler backed by the location store: it records
%% the request's contacts and answers 200 echoing the live bindings (with
%% q, Date, the Path of RFC 3327, and Require: outbound and Flow-Timer for
%% an RFC 5626 flow). Opts:
%%   auth => #{realm := binary(),
%%             secret := fun((User) -> {ok, Pass} | {ha1, HA1} | error),
%%             domain => binary() | [binary()]}
%%         | fun((Req) -> ok | {reject, Status} | {reject, Status, Headers})
%%     Authentication before any binding is written. The map form runs
%%     built-in digest (challenges 401, verifies the response, and binds the
%%     authenticated user to the AOR: its user part, and its host one of
%%     domain, the realm by default). The fun form is a custom policy.
%%   allow_unauthenticated => true
%%     Required to run without auth (a closed test network): a registrar
%%     with neither raises error({registrar, auth_required}).
%%   domains => any | [binary()]  the domains bindings are kept for
%%     (default: the registrar_domains setting); another one gets 404.
%%   default_expires => pos_integer()
-spec registrar(map()) ->
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
registrar(Opts) ->
    chappe_sip_registrar:handler(Opts).

%% Live contact URIs for an AOR (a To/Contact value or a bare URI), the
%% highest q first.
-spec location(binary()) -> [binary()].
location(AorOrUri) ->
    chappe_sip_registry:lookup(AorOrUri).

%% The live bindings of an AOR, the highest q first, as maps with contact,
%% expires, q, flow, path (the RFC 3327 route set toward the contact: send
%% the request with one Route header per element, in order), instance and
%% reg_id (RFC 5626), callid and cseq.
-spec bindings(binary()) -> [map()].
bindings(AorOrUri) ->
    chappe_sip_registry:bindings(AorOrUri).

%% Resolve an AOR to its first binding's contact URI and transport flow.
%% A registered WS UA has a flow', and so has an RFC 5626 outbound binding
%% registered directly over TCP/TLS ({conn, Id}) or UDP ({udp, Ip, Port}, or
%% {udp, Ip, Port, Local} on a node listening on several addresses);
%% pass it to proxy_request/3 as {flow, Uri, Flow}', or to create_uac/
%% create_b2bua as #{flow => Flow}', to reach the UA over that flow.
-spec location_flow(binary()) ->
    {ok, binary(), chappe_sip_engine:flow() | undefined} | {error, not_found}.
location_flow(AorOrUri) ->
    case chappe_sip_registry:bindings(AorOrUri) of
        [B | _] -> {ok, maps:get(contact, B), maps:get(flow, B, undefined)};
        [] -> {error, not_found}
    end.

%% The live dialog with this identity, from our side: LocalTag is the tag we
%% put in the dialog, RemoteTag the peer's.
-spec find_dialog(binary(), binary(), binary()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, not_found}.
find_dialog(CallId, LocalTag, RemoteTag) ->
    case chappe_sip_dialog_index:lookup({CallId, LocalTag, RemoteTag}) of
        {ok, {Pid, Id, _State, _Role}} -> {ok, chappe_sip_dialog:make(Pid, Id)};
        not_found -> {error, not_found}
    end.

%% The dialog an incoming request's Replaces header names (RFC 3891 section
%% 3). As the recipient, the header's to-tag is our local tag and its
%% from-tag the peer's. The caller applies the response rules from the info:
%%   {error, bad_request}                       -> 400 (malformed, more than
%%                                                one Replaces, or not INVITE)
%%   {error, not_found}                         -> 481
%%   state := terminated                        -> 603
%%   state := confirmed, early_only := true     -> 486
%%   state := early, role := uas                -> 481 (not our early dialog)
%% {error, no_replaces} when the request carries none.
-spec find_replaced(chappe_sip_req:req()) ->
    {ok, chappe_sip_dialog:dialog(), replaced_info()}
    | {error, no_replaces | bad_request | not_found}.
find_replaced(Req) ->
    case chappe_sip_req:get_all(<<"replaces">>, Req) of
        [] ->
            {error, no_replaces};
        [Value] ->
            case chappe_sip_req:method(Req) of
                <<"INVITE">> -> match_replaces(chappe_sip_hdr:replaces(Value));
                _ -> {error, bad_request}
            end;
        _ ->
            {error, bad_request}
    end.

match_replaces({ok, #{call_id := C, to_tag := T, from_tag := F} = R}) ->
    case chappe_sip_dialog_index:lookup({C, T, F}) of
        {ok, {Pid, Id, State, Role}} ->
            Info = #{
                state => State,
                role => Role,
                early_only => maps:get(early_only, R)
            },
            {ok, chappe_sip_dialog:make(Pid, Id), Info};
        not_found ->
            {error, not_found}
    end;
match_replaces({error, _}) ->
    {error, bad_request}.

%% What to do with an incoming request's Replaces header (RFC 3891 section
%% 3), from find_replaced/1:
%%   {reject, 400}  more than one Replaces, a malformed one, one on a
%%                  request other than INVITE, or one alongside Join
%%   {reject, 481}  no such dialog, or an early dialog we did not originate
%%   {reject, 603}  the dialog is terminating (our BYE is in flight)
%%   {reject, 486}  a confirmed dialog and the early-only flag
%%   {reject, 403}  a match nobody authorized (see replaces_response/2)
%%   {accept, Dialog, Info}  answer the new INVITE, then end Dialog:
%%                  chappe_sip_dialog:destroy/1,2 sends a BYE for a
%%                  confirmed dialog and a CANCEL for our early one
%%   no_replaces    the request carries none
%% RFC 3891 section 8 accepts a replacement only from an authenticated and
%% authorized peer, so with no policy every match is refused with 403:
%% this is replaces_response(Req, #{}).
-spec replaces_response(chappe_sip_req:req()) ->
    {accept, chappe_sip_dialog:dialog(), replaced_info()}
    | {reject, 400 | 403 | 481 | 486 | 603}
    | no_replaces.
replaces_response(Req) ->
    replaces_response(Req, #{}).

%% replaces_response/1 with the authentication and authorization RFC 3891
%% sections 3 and 8 require before an active dialog is replaced. Opts:
%%   authorize => fun((Dialog, Req) -> boolean())
%%     called only when the match would be accepted; false gives
%%     {reject, 403} and leaves Dialog alone. A Referred-By naming the
%%     replaced party, or an authenticated identity equal to it, are the
%%     RFC's grounds for true.
%%   auth => #{realm := binary(),
%%             secret := fun((User) -> {ok, Pass} | {ha1, HA1} | error)}
%%     digest authentication (chappe_sip_digest:verify/1) of every
%%     well-formed Replaces before the dialog is looked at: no or wrong
%%     credentials give {reject, 401, [WWW-Authenticate]} to send as is,
%%     credentials for another URI {reject, 400}. Authenticated, the match
%%     is accepted unless authorize says false.
%% With neither, every match is refused with 403.
-spec replaces_response(chappe_sip_req:req(), #{
    authorize => fun(
        (chappe_sip_dialog:dialog(), chappe_sip_req:req()) -> boolean()
    ),
    auth => #{realm := binary(), secret := fun(), _ => _}
}) ->
    {accept, chappe_sip_dialog:dialog(), replaced_info()}
    | {reject, 400 | 403 | 481 | 486 | 603}
    | {reject, 401, [{binary(), binary()}]}
    | no_replaces.
replaces_response(Req, Opts) ->
    case match_response(Req) of
        no_replaces ->
            no_replaces;
        {reject, 400} = Bad ->
            Bad;
        Matched ->
            case replaces_auth(maps:get(auth, Opts, undefined), Req) of
                ok -> authorize_replaces(Matched, Opts, true, Req);
                none -> authorize_replaces(Matched, Opts, false, Req);
                Reject -> Reject
            end
    end.

match_response(Req) ->
    case {find_replaced(Req), chappe_sip_req:get(<<"join">>, Req)} of
        {{error, no_replaces}, _} ->
            no_replaces;
        {_, Join} when Join =/= undefined ->
            %% Join (RFC 3911) contradicts Replaces
            {reject, 400};
        {Found, undefined} ->
            replaces_status(Found)
    end.

%% a match is accepted when the app's authorize says so, or, without one,
%% when the peer authenticated
authorize_replaces({accept, Dialog, _Info} = Accept, Opts, Authed, Req) ->
    Default = fun(_, _) -> Authed end,
    case (maps:get(authorize, Opts, Default))(Dialog, Req) of
        true -> Accept;
        false -> {reject, 403}
    end;
authorize_replaces(Other, _Opts, _Authed, _Req) ->
    Other.

replaces_auth(undefined, _Req) ->
    none;
replaces_auth(#{realm := Realm, secret := PwFun}, Req) ->
    Args = #{
        method => chappe_sip_req:method(Req),
        realm => Realm,
        secret => PwFun,
        authorization => chappe_sip_req:get(<<"authorization">>, Req),
        request_uri => chappe_sip_req:uri(Req)
    },
    case chappe_sip_digest:verify(Args) of
        {ok, _User} ->
            ok;
        stale ->
            {reject, 401, [replaces_challenge(Realm, true)]};
        {error, uri_mismatch} ->
            %% RFC 7616 3.4: the digest names another resource
            {reject, 400};
        {error, _} ->
            {reject, 401, [replaces_challenge(Realm, false)]}
    end.

replaces_challenge(Realm, Stale) ->
    {<<"WWW-Authenticate">>, chappe_sip_digest:challenge(Realm, Stale)}.

replaces_status(Found) ->
    case Found of
        {error, bad_request} ->
            {reject, 400};
        {error, not_found} ->
            {reject, 481};
        {ok, _Dialog, #{state := terminated}} ->
            {reject, 603};
        {ok, _Dialog, #{state := confirmed, early_only := true}} ->
            {reject, 486};
        {ok, _Dialog, #{state := early, role := uas}} ->
            {reject, 481};
        {ok, Dialog, Info} ->
            {accept, Dialog, Info}
    end.

%% ---- peers (OPTIONS keepalive) ----

%% Monitor a SIP peer with OPTIONS. Opts: #{uri := binary(), group,
%% priority (lower wins, default 10), weight (default 1), interval_ms
%% (default 10000), timeout_ms (default 2000), up_after (default 1),
%% down_after (default 2), alive_codes (the statuses that count as an
%% answer; default any final but 408 and 503)}. See chappe_sip_peers.
-spec peer_add(chappe_sip_peers:name(), chappe_sip_peers:opts()) ->
    ok | {error, term()}.
peer_add(Name, Opts) ->
    chappe_sip_peers:add(Name, Opts).

-spec peer_remove(chappe_sip_peers:name()) -> ok | {error, not_found}.
peer_remove(Name) ->
    chappe_sip_peers:remove(Name).

%% Every peer with its state (unknown | up | down), last status and RTT.
-spec peers() -> [{chappe_sip_peers:name(), chappe_sip_peers:info()}].
peers() ->
    chappe_sip_peers:peers().

-spec peer_status(chappe_sip_peers:name()) ->
    {ok, chappe_sip_peers:info()} | {error, not_found}.
peer_status(Name) ->
    chappe_sip_peers:status(Name).

%% An up peer of Group: the best priority, the next in turn, or one at
%% random by weight.
-spec peer_select(term(), chappe_sip_peers:policy()) ->
    {ok, binary()} | {error, none_up}.
peer_select(Group, Policy) ->
    chappe_sip_peers:select(Group, Policy).

%% Pid gets {chappe_sip_peer, Name, up | down} on each change, and
%% {chappe_sip_qualify, Aor, Contact, unreachable} when the registrar's
%% keepalive drops a binding.
-spec peer_subscribe(pid()) -> ok.
peer_subscribe(Pid) ->
    chappe_sip_peers:subscribe(Pid).
