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
-export([use/1, use/2, handle/2]).
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
    publish/1,
    refer/1,
    update/1,
    register/1
]).
-export([registrar/0, registrar/1, location/1, location_flow/1]).

%% Opts: #{contact := binary(), max_message_size => pos_integer(),
%%         tls => #{contact := binary(), cert_dir => binary(),
%%                  passphrase => binary(), verify => none | peer}}
%% The tls contact binds a TLS listener on its own port (e.g.
%% <<"sips:0.0.0.0:5061;transport=tls">>); cert_dir holds agent.pem and
%% cafile.pem.
-spec start(#{contact := binary(), _ => _}) ->
    ok | {error, already_started | term()}.
start(Opts) ->
    %% an optional WS listener runs independently of the sofia engine; a bind
    %% failure must surface, not be swallowed
    case start_ws(maps:get(ws, Opts, undefined)) of
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
                    chappe_sip_engine:start(maps:without([ws, media], Opts));
                false ->
                    ok
            end;
        {error, Reason} ->
            {error, {media, Reason}}
    end.

start_ws(undefined) -> ok;
start_ws(WsOpts) -> ws_listen(WsOpts).

%% Start (or replace) the SIP-over-WebSocket listener. Opts: #{port := P}.
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
    chappe_sip_engine:handle(Method, Fun, #{}).

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
-spec create_uac(binary(), map()) ->
    {ok, chappe_sip_dialog:dialog()} | {error, term()}.
create_uac(Uri, Opts) ->
    case chappe_sip_uac:start(Uri, Opts) of
        {ok, Ref} ->
            chappe_sip_uac:await(Ref, maps:get(timeout, Opts, 32000));
        {error, Reason} ->
            {error, Reason}
    end.

%% Send an out-of-dialog, non-dialog-forming request (OPTIONS, REGISTER,
%% MESSAGE, ...). Returns a ref; responses arrive as events, or use
%% chappe_sip_uac:await_response/2.
-spec request(binary(), map()) ->
    {ok, chappe_sip_uac:uac_ref()} | {error, term()}.
request(Uri, Opts) ->
    chappe_sip_uac:start(Uri, maps:merge(#{method => <<"OPTIONS">>}, Opts)).

%% Bridge an incoming INVITE (A/UAS) to a new INVITE toward Uri (B/UAC).
%% Returns both dialogs; use chappe_sip_b2b:relay/1 to link their lifecycles.
-spec create_b2bua(chappe_sip_req:req(), chappe_sip_res:res(), binary(), map()) ->
    {ok, #{
        uas := chappe_sip_dialog:dialog(), uac := chappe_sip_dialog:dialog()
    }}
    | {error, term()}.
create_b2bua(Req, Res, Uri, Opts) ->
    chappe_sip_b2b:create_b2bua(Req, Res, Uri, Opts).

%% Proxy an incoming request to one or more destinations. Opts:
%%   forking => sequential | parallel, record_route => boolean,
%%   provisional_timeout, final_timeout. Returns the aggregate result.
-spec proxy_request(chappe_sip_req:req(), binary() | [binary()], map()) ->
    {ok, map()} | {error, term()}.
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

-spec notify(fun()) -> ok.
notify(F) -> handle(<<"NOTIFY">>, F).

-spec bye(fun()) -> ok.
bye(F) -> handle(<<"BYE">>, F).

-spec subscribe(fun()) -> ok.
subscribe(F) -> handle(<<"SUBSCRIBE">>, F).

-spec publish(fun()) -> ok.
publish(F) -> handle(<<"PUBLISH">>, F).

-spec refer(fun()) -> ok.
refer(F) -> handle(<<"REFER">>, F).

-spec update(fun()) -> ok.
update(F) -> handle(<<"UPDATE">>, F).

-spec register(fun()) -> ok.
register(F) -> handle(<<"REGISTER">>, F).

%% A ready-made REGISTER handler backed by the location store: it records
%% the request's contacts and answers 200 echoing the live bindings.
%% Register it with chappe_sip:register(chappe_sip:registrar()).
-spec registrar() -> fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
registrar() ->
    registrar(#{}).

%% Opts:
%%   auth => #{realm := binary(),
%%             secret := fun((User) -> {ok, Pass} | {ha1, HA1} | error)}
%%         | fun((Req) -> ok | {reject, Status} | {reject, Status, Headers})
%%     Mandatory authentication before any binding is written. The map form
%%     runs built-in digest (challenges 401, verifies the response, and binds
%%     the authenticated user to the AOR user-part). The fun form is a custom
%%     policy. With no auth key the registrar accepts unauthenticated
%%     REGISTERs (fine for a closed test network, unsafe on the public edge).
-spec registrar(map()) ->
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
registrar(Opts0) ->
    fun(Req, Res) ->
        case registrar_auth(maps:get(auth, Opts0, undefined), Req) of
            ok ->
                do_register(maps:remove(auth, Opts0), Req, Res);
            {reject, Status} ->
                _ = chappe_sip_res:send(Res, Status),
                ok;
            {reject, Status, Headers} ->
                _ = chappe_sip_res:send(Res, Status, #{headers => Headers}),
                ok
        end
    end.

do_register(Opts0, Req, Res) ->
    %% a WS-originated REGISTER carries its flow in the request meta
    Opts =
        case maps:get(flow, chappe_sip_req:meta(Req), undefined) of
            undefined -> Opts0;
            Flow -> Opts0#{flow => Flow}
        end,
    case chappe_sip_registry:register_contacts(Req, Opts) of
        {ok, Bindings} ->
            _ = chappe_sip_res:send(
                Res,
                200,
                #{
                    reason => <<"OK">>,
                    headers => binding_headers(Bindings)
                }
            ),
            ok;
        {error, 423} ->
            %% RFC 3261 10.3 step 7: 423 MUST carry Min-Expires
            Min = chappe_sip_config:get(registrar_min_expires),
            _ = chappe_sip_res:send(
                Res,
                423,
                #{
                    reason => <<"Interval Too Brief">>,
                    headers => [{<<"Min-Expires">>, integer_to_binary(Min)}]
                }
            ),
            ok;
        {error, Status} ->
            _ = chappe_sip_res:send(Res, Status),
            ok
    end.

%% no auth configured: accept (documented as unsafe on a public edge)
registrar_auth(undefined, _Req) ->
    ok;
registrar_auth(Fun, Req) when is_function(Fun, 1) ->
    Fun(Req);
registrar_auth(#{realm := Realm, secret := PwFun}, Req) ->
    Args = #{
        method => chappe_sip_req:method(Req),
        realm => Realm,
        secret => PwFun,
        authorization => chappe_sip_req:get(<<"authorization">>, Req)
    },
    case chappe_sip_digest:verify(Args) of
        {ok, User} ->
            case aor_user(Req) of
                % identity matches the AOR
                User -> ok;
                % authenticated as someone else
                _ -> {reject, 403}
            end;
        stale ->
            {reject, 401, [www_authenticate(Realm, true)]};
        {error, _} ->
            {reject, 401, [www_authenticate(Realm, false)]}
    end.

www_authenticate(Realm, Stale) ->
    {<<"WWW-Authenticate">>, chappe_sip_digest:challenge(Realm, Stale)}.

%% user-part of the To AOR being registered
aor_user(Req) ->
    case chappe_sip_uri:parse(aor_uri(chappe_sip_req:get(<<"to">>, Req))) of
        {ok, #{user := U}} -> U;
        _ -> undefined
    end.

aor_uri(NameAddr) ->
    case chappe_sip_hdr:name_addr(NameAddr) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> NameAddr
    end.

%% Live contact URIs for an AOR (a To/Contact value or a bare URI).
-spec location(binary()) -> [binary()].
location(AorOrUri) ->
    chappe_sip_registry:lookup(AorOrUri).

%% Resolve an AOR to its first binding's contact URI and transport flow.
%% A registered WS UA has a flow'; pass it (and the URI) to create_uac/
%% create_b2bua as #{flow => Flow}' to originate over that WS connection.
-spec location_flow(binary()) ->
    {ok, binary(), term()} | {error, not_found}.
location_flow(AorOrUri) ->
    case chappe_sip_registry:bindings(AorOrUri) of
        [B | _] -> {ok, maps:get(contact, B), maps:get(flow, B, undefined)};
        [] -> {error, not_found}
    end.

binding_headers(Bindings) ->
    [
        {<<"Contact">>,
            <<"<", (maps:get(contact, B))/binary, ">;expires=",
                (integer_to_binary(maps:get(expires, B)))/binary>>}
     || B <- Bindings
    ].
