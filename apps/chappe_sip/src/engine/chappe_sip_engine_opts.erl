%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The options chappe_sip_engine starts the native stack with, and
%% the snapshot of them it keeps outside its process.
%%
%% start_opts/1 checks the options of chappe_sip:start/1 and flattens them
%% into what the NIF takes: TLS checked, the contact restricted, the agent
%% settings checked, the size cap and the HEP capture URL added. It has
%% no side effect; the engine publishes the options once the stack is up.
%% tls_uri/2 names the TLS listener from the options and the primary
%% contact.
%%
%% routes/3 registers a handler or a middleware and keeps it in the
%% snapshot. The snapshot (start options, routes, middleware, event
%% packages) lives
%% in the chappe_sip_engine_cfg ETS table owned by
%% chappe_sip_registry_keeper, so a restarted engine process re-establishes
%% the native stack and its handlers instead of leaving SIP down.
-module(chappe_sip_engine_opts).

-export([start_opts/1, tls_uri/2]).
-export([routes/3, cfg_put/2, cfg_get/2, cfg_del/1]).

-define(CFG_TAB, chappe_sip_engine_cfg).

%% The options the engine backend starts with, or the first check that
%% fails.
-spec start_opts(map()) -> {ok, map()} | {error, term()}.
start_opts(Opts) ->
    case validate_tls(maps:get(tls, Opts, undefined)) of
        ok ->
            case chappe_sip_binds:options(Opts) of
                {ok, Opts1} ->
                    case agent_opts(Opts1) of
                        {ok, Opts2} -> with_capture(with_max_size(Opts2));
                        {error, _} = Err -> Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% The agent settings, checked with the NIF's bounds and flattened into
%% its keys (sip_t1, sip_t2, sip_t4, outbound_proxy, tcp_keepalive_ms,
%% udp_mtu; tcp_keepalive_ms pings TCP connections only, not TLS ones).
%% aliases stay in Erlang: they are names of this node, known to
%% the proxy's own-address check (chappe_sip_binds:own_uris/0).
-spec agent_opts(map()) -> {ok, map()} | {error, {atom(), term()}}.
agent_opts(Opts) ->
    Checks = [
        {sip_timers, fun sip_timers/1},
        {outbound_proxy, fun outbound_proxy/1},
        {tcp_keepalive_ms, in_range(1000, 3600000)},
        {udp_mtu, in_range(576, 65535)},
        {aliases, fun chappe_sip_binds:aliases/1},
        {outbound_route, fun outbound_route/1}
    ],
    case
        maps:is_key(outbound_proxy, Opts) andalso
            maps:find(outbound_route, Opts)
    of
        {ok, R} -> {error, {outbound_route, {with_outbound_proxy, R}}};
        _ -> agent_opts(Opts, Checks)
    end.

agent_opts(Opts, Checks) ->
    lists:foldl(
        fun check/2, {ok, Opts}, [{K, flat(K, C)} || {K, C} <- Checks]
    ).

%% one check of the fold: an option left out passes, a bad one stops it
check({Key, Check}, {ok, Acc}) ->
    case maps:find(Key, Acc) of
        error ->
            {ok, Acc};
        {ok, V} ->
            case Check(V) of
                {ok, Flat} -> {ok, maps:merge(maps:remove(Key, Acc), Flat)};
                error -> {error, {Key, V}}
            end
    end;
check(_, Err) ->
    Err.

%% a check of one option, as the NIF keys it sets
flat(Key, Check) ->
    fun(V) ->
        case Check(V) of
            {ok, M} when is_map(M) -> {ok, M};
            ok -> {ok, #{Key => V}};
            error -> error
        end
    end.

in_range(Lo, Hi) ->
    fun
        (N) when is_integer(N), N >= Lo, N =< Hi -> ok;
        (_) -> error
    end.

%% RFC 3261 17.1.1.1: T1 (default 500 ms), T2 (4 s), T4 (5 s); T2 is the
%% cap on the retransmit interval, so never below T1
sip_timers(T) when is_map(T) ->
    Keys = [t1, t2, t4],
    T1 = maps:get(t1, T, 500),
    T2 = maps:get(t2, T, 4000),
    case
        maps:keys(maps:without(Keys, T)) =:= [] andalso
            ok =:= (in_range(10, 60000))(T1) andalso
            ok =:= (in_range(10, 600000))(T2) andalso
            ok =:= (in_range(10, 600000))(maps:get(t4, T, 5000)) andalso
            T2 >= T1
    of
        true ->
            {ok, #{nif_timer(K) => V || K := V <- T}};
        false ->
            error
    end;
sip_timers(_) ->
    error.

nif_timer(t1) -> sip_t1;
nif_timer(t2) -> sip_t2;
nif_timer(t4) -> sip_t4.

%% outbound_route: kept in Erlang as its Route value (chappe_sip_binds)
outbound_route(U) ->
    case chappe_sip_binds:outbound_route_opt(U) of
        {ok, R} -> {ok, #{outbound_route => R}};
        error -> error
    end.

%% a sip: or sips: URI with no NUL
outbound_proxy(P) when is_binary(P) ->
    case
        binary:match(P, <<0>>) =:= nomatch andalso
            byte_size(P) < 512 andalso chappe_sip_uri:parse(P)
    of
        {ok, #{scheme := S}} when S =:= sip; S =:= sips -> ok;
        _ -> error
    end;
outbound_proxy(_) ->
    error.

%% HEP capture of the native transports: sofia takes a capture URL
%% (TPTAG_CAPT), from the hep option or the application setting
with_capture(Opts) ->
    case maps:get(hep, Opts, chappe_sip_config:get(hep)) of
        undefined ->
            {ok, maps:remove(capture, Opts)};
        Hep ->
            case chappe_sip_hep:validate(Hep) of
                {ok, Cfg} ->
                    {ok, Opts#{capture => chappe_sip_hep:native_url(Cfg)}};
                {error, _} = Err ->
                    Err
            end
    end.

%% TLS verifies the server certificate of every outbound connection by
%% default (verify => peer, with the RFC 5922 subject check against the
%% target host). verify => none turns that off and is accepted only with
%% allow_insecure => true (tests). verify_clients => true also requires a
%% verified client certificate on inbound connections. An unrecognised
%% value fails the start rather than weakening verification silently.
-spec validate_tls(term()) -> ok | {error, {tls, term()}}.
validate_tls(undefined) ->
    ok;
validate_tls(Tls) when is_map(Tls) ->
    Insecure = maps:get(allow_insecure, Tls, false),
    case {maps:get(verify, Tls, peer), maps:get(verify_clients, Tls, false)} of
        {_, VC} when not is_boolean(VC) ->
            {error, {tls, {bad_verify_clients, VC}}};
        {peer, _} ->
            ok;
        {none, _} ->
            case Insecure of
                true -> ok;
                _ -> {error, {tls, insecure_verify_none}}
            end;
        {Other, _} ->
            {error, {tls, {bad_verify, Other}}}
    end;
validate_tls(_) ->
    {error, {tls, bad_options}}.

%% the configured message-size cap goes to the NIF unless start/1 set one
with_max_size(Opts) ->
    case maps:is_key(max_message_size, Opts) of
        true ->
            Opts;
        false ->
            Opts#{max_message_size => chappe_sip_config:get(max_message_size)}
    end.

%% The TLS listener URI (sips:host:port) of the running options, a
%% wildcard host replaced by the host of Contact, the primary contact.
-spec tls_uri(map(), binary() | undefined) -> binary() | undefined.
tls_uri(#{tls := #{contact := C}}, Contact) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(C)) of
        {ok, #{host := H} = U} ->
            Host =
                case lists:member(H, [<<"0.0.0.0">>, <<"[::]">>, <<"*">>]) of
                    true -> primary_host(Contact, H);
                    false -> H
                end,
            Port =
                case maps:get(port, U, undefined) of
                    undefined -> <<>>;
                    P -> <<":", (integer_to_binary(P))/binary>>
                end,
            <<"sips:", Host/binary, Port/binary>>;
        _ ->
            undefined
    end;
tls_uri(_Opts, _Contact) ->
    undefined.

primary_host(C, Default) when is_binary(C) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(C)) of
        {ok, #{host := H}} -> H;
        _ -> Default
    end;
primary_host(_C, Default) ->
    Default.

%% A route registration (chappe_sip_engine:use/2, handle/3,
%% reset_routes/0) on the method routes and the middleware, kept in the
%% snapshot. An event package's handler lives in the snapshot only.
-spec routes(term(), Routes, MW) -> {Routes, MW} when
    Routes :: #{binary() => fun()},
    MW :: [{binary() | '*', chappe_sip_middleware:mw()}].
routes({use, Method, Fun}, R, MW) ->
    MW1 = MW ++ [{Method, Fun}],
    cfg_put(middlewares, MW1),
    {R, MW1};
routes({handle, <<"SUBSCRIBE">>, Fun, #{package := Pkg0} = Opts}, R, MW) ->
    Pkg = string:lowercase(Pkg0),
    cfg_put(packages, (cfg_get(packages, #{}))#{Pkg => Fun}),
    cfg_put({route_opts, {package, Pkg}}, route_opts(Opts)),
    {R, MW};
routes({handle, Method, Fun, Opts}, R, MW) ->
    R1 = R#{Method => Fun},
    cfg_put(routes, R1),
    cfg_put({route_opts, Method}, route_opts(Opts)),
    Method =:= <<"SUBSCRIBE">> andalso
        cfg_put(events, maps:get(events, Opts, any)),
    {R1, MW};
routes(reset, R, _MW) ->
    _ = [cfg_del({route_opts, M}) || M <- maps:keys(R)],
    _ = [
        cfg_del({route_opts, {package, P}})
     || P <- maps:keys(cfg_get(packages, #{}))
    ],
    cfg_put(routes, #{}),
    cfg_del(events),
    cfg_del(packages),
    cfg_put(middlewares, []),
    {#{}, []}.

%% what a route registration keeps for its workers
route_opts(Opts) ->
    Tags = maps:get(option_tags, Opts, []),
    Role =
        case maps:get(proxy, Opts, false) of
            true -> proxy;
            false -> uas
        end,
    #{option_tags => Tags, role => Role}.

%% The snapshot: a no-op while the keeper's table is missing.

-spec cfg_put(term(), term()) -> ok.
cfg_put(Key, Val) ->
    case ets:info(?CFG_TAB) of
        undefined ->
            ok;
        _ ->
            ets:insert(?CFG_TAB, {Key, Val}),
            ok
    end.

-spec cfg_get(term(), term()) -> term().
cfg_get(Key, Default) ->
    case ets:info(?CFG_TAB) of
        undefined ->
            Default;
        _ ->
            case ets:lookup(?CFG_TAB, Key) of
                [{Key, V}] -> V;
                [] -> Default
            end
    end.

-spec cfg_del(term()) -> ok.
cfg_del(Key) ->
    case ets:info(?CFG_TAB) of
        undefined ->
            ok;
        _ ->
            ets:delete(?CFG_TAB, Key),
            ok
    end.
