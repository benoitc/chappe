%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Record-Route construction and loose-routing helpers.
%%
%% A record-routing proxy inserts a Record-Route pointing at itself so the
%% endpoints route in-dialog requests (2xx ACK, BYE, re-INVITE) back through
%% it. This module builds that URI, recognises it when it comes back as the
%% top Route header (or, behind a strict router, as the Request-URI), and
%% pops it to find the next hop (RFC 3261 sections 16.4 to 16.6). No
%% per-dialog state is kept: the route set on the wire carries the target.
%%
%% Our Record-Route carries an authenticated "espx" parameter: an HMAC over
%% the route's host, port, flow tokens, Call-ID and expiry under a per-node
%% secret. A request is treated as ours (and loose-routed without
%% middleware) only if that MAC validates and the expiry has not passed, so
%% a crafted Route cannot turn the proxy into an open relay, the flow tokens
%% cannot be forged to target another WS leg, and a captured marker stops
%% working after record_route_ttl_s.
%%
%% Flow tokens: `ftok' names the WS flow the dialog-forming request came in
%% on (the upstream leg) and `ftokd' the WS flow it went out on (the
%% downstream leg). A WS-to-WS dialog carries both, so each side's in-dialog
%% requests route to the other.
-module(chappe_sip_route).

-export([record_route/3, is_self/3, pop_self/1, strip_via/1]).
-export([ensure_secret/0, check_secret/1]).
-export([routes/1, set_routes/2, uri_is_self/2, recover_strict/1]).
-export([next_flow/2, request_target/2, flow_route/1, secure_hop/2]).

-export_type([flows/0]).

%% {Upstream WS flow, Downstream WS flow}
-type flows() :: {integer() | undefined, integer() | undefined}.

-define(MARK, <<"espx">>).
-define(SECRET_KEY, {chappe_sip_route, flow_secret}).
-define(BOOT_KEY, {chappe_sip_route, boot}).

%% Build the Record-Route header value to prepend (angle-bracketed) from the
%% engine's bound contact, for the dialog identified by CallId. Strips
%% transport params to a clean routable URI:
%% <sip:host:port;lr;espx=<MAC>;exp=<T>[;ftok=<Up>][;ftokd=<Down>]>. The
%% scheme follows the contact, so a TLS contact gives a sips: route (RFC
%% 5630). A bare integer flow is the upstream leg.
-spec record_route(
    binary() | undefined, flows() | integer() | undefined, binary()
) -> binary().
record_route(Contact, Flow, CallId) when
    is_integer(Flow); Flow =:= undefined
->
    record_route(Contact, {Flow, undefined}, CallId);
record_route(Contact, {Up, Down}, CallId) ->
    {Base, Host, Port} = contact_hostport(Contact),
    Exp = erlang:system_time(second) + ttl(),
    Sig = sign(Host, Port, {Up, Down}, CallId, Exp),
    <<"<", Base/binary, ";lr;", ?MARK/binary, "=", Sig/binary, ";exp=",
        (integer_to_binary(Exp))/binary, (flow_param(<<"ftok">>, Up))/binary,
        (flow_param(<<"ftokd">>, Down))/binary, ">">>.

%% The Request-URI and Route headers of a request in a dialog (RFC 3261
%% 12.2.1.1). A loose router (;lr on the first route) leaves the remote
%% target in the Request-URI and the whole route set in Route. A strict
%% router takes the first route as the Request-URI; the rest of the route
%% set follows in Route, then the remote target.
-spec request_target(binary(), [binary()]) -> {binary(), [binary()]}.
request_target(Target, []) ->
    {Target, []};
request_target(Target, [First | Rest] = RouteSet) ->
    case route_uri(First) of
        {ok, #{params := #{<<"lr">> := _}}} ->
            {Target, RouteSet};
        {ok, _} ->
            {
                chappe_sip_hdr:name_addr_uri(First),
                Rest ++ [<<"<", Target/binary, ">">>]
            };
        error ->
            {Target, RouteSet}
    end.

%% The next hop of a request for Target: a sip: hop becomes sips: (and
%% loses a transport=udp) when Target is a SIPS URI, since nta picks the
%% transport from the hop's scheme and RFC 3261 8.1.2 resolves a SIPS
%% Request-URI as SIPS whatever URI it resolves.
-spec secure_hop(binary() | undefined, Hop) -> Hop when
    Hop :: chappe_sip_engine:route().
secure_hop(Target, Hop) when is_binary(Target), is_binary(Hop) ->
    case {scheme(Target), binary:split(Hop, <<":">>)} of
        {<<"sips">>, [S, Rest]} when byte_size(S) =:= 3 ->
            case string:lowercase(S) of
                <<"sip">> -> without_udp(<<"sips:", Rest/binary>>);
                _ -> Hop
            end;
        _ ->
            Hop
    end;
secure_hop(_Target, Hop) ->
    Hop.

scheme(Uri) ->
    string:lowercase(hd(binary:split(Uri, <<":">>))).

without_udp(Hop) ->
    case chappe_sip_uri:take_param(Hop, <<"transport">>) of
        {V, Without} when is_binary(V) ->
            case string:lowercase(V) of
                <<"udp">> -> Without;
                _ -> Hop
            end;
        _ ->
            Hop
    end.

flow_param(Name, Flow) when is_integer(Flow) ->
    <<";", Name/binary, "=", (integer_to_binary(Flow))/binary>>;
flow_param(_Name, _) ->
    <<>>.

%% Does this Route (or Record-Route) header value target us for the dialog
%% CallId? True only when it carries our marker with a MAC that validates
%% against the route's own host/port/flows/expiry and CallId under the node
%% secret, and the expiry has not passed.
-spec is_self(binary(), binary() | undefined, binary()) -> boolean().
is_self(RouteValue, _Contact, CallId) ->
    case route_uri(RouteValue) of
        {ok, U} -> valid_uri(U, CallId);
        error -> false
    end.

%% The same check for a bare URI (a Request-URI rewritten by a strict
%% router to our Record-Route value).
-spec uri_is_self(binary() | undefined, binary()) -> boolean().
uri_is_self(undefined, _CallId) ->
    false;
uri_is_self(Uri, CallId) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, U} -> valid_uri(U, CallId);
        _ -> false
    end.

valid_uri(#{params := P} = U, CallId) ->
    case maps:get(?MARK, P, undefined) of
        Sig when is_binary(Sig) -> valid_sig(Sig, U, P, CallId);
        % absent, or a bare marker with no MAC
        _ -> false
    end.

valid_sig(Sig, U, P, CallId) ->
    Host = maps:get(host, U, undefined),
    Port = maps:get(port, U, undefined),
    case expiry(P) of
        {ok, Exp} ->
            Exp >= erlang:system_time(second) andalso
                mac_equal(Sig, sign(Host, Port, flows(P), CallId, Exp));
        legacy ->
            %% a marker minted before expiries existed (no exp): accepted
            %% only within one TTL of this node's boot, so a stable shared
            %% secret does not keep them alive forever
            legacy_window() andalso
                mac_equal(
                    Sig,
                    legacy_sign(Host, Port, ftok_value(P, <<"ftok">>), CallId)
                );
        error ->
            false
    end.

%% hash_equals/2 raises on unequal lengths and Sig is attacker-controlled
mac_equal(Sig, Expected) ->
    byte_size(Sig) =:= byte_size(Expected) andalso
        crypto:hash_equals(Sig, Expected).

expiry(P) ->
    case maps:get(<<"exp">>, P, undefined) of
        undefined ->
            legacy;
        V when is_binary(V) ->
            try binary_to_integer(V) of
                Exp -> {ok, Exp}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

legacy_window() ->
    Boot = persistent_term:get(?BOOT_KEY, erlang:system_time(second)),
    erlang:system_time(second) < Boot + ttl().

ttl() ->
    case chappe_sip_config:get(record_route_ttl_s) of
        T when is_integer(T), T > 0 -> T;
        _ -> 86400
    end.

%% The Route values in order, comma-joined header lines split.
-spec routes(chappe_sip_msg:msg()) -> [binary()].
routes(Msg) ->
    lists:append([
        chappe_sip_hdr:split_list(V)
     || V <- chappe_sip_msg:get_all(<<"route">>, Msg)
    ]).

%% Replace the Route headers with these values, one header each, in order.
-spec set_routes([binary()], chappe_sip_msg:msg()) -> chappe_sip_msg:msg().
set_routes(Values, Msg) ->
    lists:foldr(
        fun(V, M) -> chappe_sip_msg:prepend(<<"Route">>, V, M) end,
        chappe_sip_msg:remove(<<"route">>, Msg),
        Values
    ).

%% Remove our own top Route and return the next hop: the URI of the new top
%% Route if one remains (multi-hop route set), else undefined so nta routes
%% by the Request-URI (the peer's Contact, single-proxy case). The flow
%% tokens are trusted here because is_self already validated the MAC. A
%% comma-joined Route line keeps its other values.
-spec pop_self(chappe_sip_msg:msg()) ->
    {binary() | undefined, flows(), chappe_sip_msg:msg()}.
pop_self(Msg) ->
    case routes(Msg) of
        [] ->
            {undefined, {undefined, undefined}, Msg};
        [Top | Rest] ->
            Flows =
                case route_uri(Top) of
                    {ok, #{params := P}} -> flows(P);
                    _ -> {undefined, undefined}
                end,
            {next_hop(Rest), Flows, set_routes(Rest, Msg)}
    end.

%% RFC 3261 16.4: a strict router upstream put our Record-Route URI in the
%% Request-URI. Restore the real target (the last Route value) as the
%% Request-URI, drop that Route, and return our flow tokens and next hop.
-spec recover_strict(chappe_sip_msg:msg()) ->
    {ok, binary() | undefined, flows(), chappe_sip_msg:msg()} | no.
recover_strict(Msg) ->
    Uri = chappe_sip_msg:uri(Msg),
    case uri_is_self(Uri, chappe_sip_msg:call_id(Msg)) andalso routes(Msg) of
        [_ | _] = Routes ->
            {ok, U} = chappe_sip_uri:parse(Uri),
            Target = chappe_sip_hdr:name_addr_uri(lists:last(Routes)),
            Rest = lists:droplast(Routes),
            Msg1 = set_routes(Rest, chappe_sip_msg:set_uri(Target, Msg)),
            {ok, next_hop(Rest), flows(maps:get(params, U, #{})), Msg1};
        _ ->
            no
    end.

next_hop([]) -> undefined;
next_hop([Next | _]) -> chappe_sip_hdr:name_addr_uri(Next).

%% Where an in-dialog request goes: Arrived is the WS flow it came in on
%% (undefined over UDP/TCP/TLS). From one WS leg it goes to the other one,
%% or by the next hop when that leg is not WS; from a non-WS transport it
%% goes to the WS leg the tokens name, if any.
-spec next_flow(integer() | undefined, flows()) ->
    {ws, integer()} | next_hop.
next_flow(Arrived, {Up, Down}) when is_integer(Arrived) ->
    case {Arrived =:= Up, Arrived =:= Down} of
        {true, _} when is_integer(Down) -> {ws, Down};
        {_, true} when is_integer(Up) -> {ws, Up};
        _ -> next_hop
    end;
next_flow(undefined, {Up, undefined}) when is_integer(Up) ->
    {ws, Up};
next_flow(undefined, {undefined, Down}) when is_integer(Down) ->
    {ws, Down};
next_flow(_Arrived, _Flows) ->
    next_hop.

flows(P) ->
    {ftok_value(P, <<"ftok">>), ftok_value(P, <<"ftokd">>)}.

ftok_value(P, Name) ->
    case maps:get(Name, P, undefined) of
        V when is_binary(V) ->
            try
                binary_to_integer(V)
            catch
                _:_ -> undefined
            end;
        _ ->
            undefined
    end.

%% Strip the proxy's own (top) Via before relaying a response upstream.
-spec strip_via(binary()) -> binary().
strip_via(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} ->
            iolist_to_binary(
                chappe_sip_msg:encode(chappe_sip_msg:drop_first(<<"via">>, Msg))
            );
        {error, _} ->
            Raw
    end.

%% ---- flow-token secret ----

%% Seed the per-node secret at boot so all workers share one value (avoids a
%% first-request race where two workers generate different secrets). A
%% configured secret shorter than 16 bytes is refused rather than replaced
%% by a random one, so a cluster does not silently lose its shared secret.
-spec ensure_secret() -> ok | {error, {flow_token_secret, too_short}}.
ensure_secret() ->
    case check_secret(chappe_sip_config:get(flow_token_secret)) of
        ok ->
            _ =
                persistent_term:get(?BOOT_KEY, undefined) =:= undefined andalso
                    persistent_term:put(?BOOT_KEY, erlang:system_time(second)),
            _ = secret(),
            ok;
        {error, _} = Err ->
            Err
    end.

%% A configured flow_token_secret must carry at least 16 bytes.
-spec check_secret(term()) -> ok | {error, {flow_token_secret, too_short}}.
check_secret(undefined) ->
    ok;
check_secret(Bin) when is_binary(Bin), byte_size(Bin) >= 16 ->
    ok;
check_secret(Str) when is_list(Str) ->
    try iolist_to_binary(Str) of
        Bin -> check_secret(Bin)
    catch
        _:_ -> {error, {flow_token_secret, too_short}}
    end;
check_secret(_) ->
    {error, {flow_token_secret, too_short}}.

secret() ->
    case persistent_term:get(?SECRET_KEY, undefined) of
        undefined ->
            S = configured_or_random(),
            persistent_term:put(?SECRET_KEY, S),
            persistent_term:get(?SECRET_KEY);
        S ->
            S
    end.

configured_or_random() ->
    case chappe_sip_config:get(flow_token_secret) of
        undefined -> crypto:strong_rand_bytes(32);
        Secret -> iolist_to_binary(Secret)
    end.

%% HMAC (truncated, hex) over the route's host, port, flows, Call-ID and
%% expiry.
sign(Host, Port, {Up, Down}, CallId, Exp) ->
    Data = <<
        "v2|",
        (nb(Host))/binary,
        "|",
        (ni(Port))/binary,
        "|",
        (ni(Up))/binary,
        "|",
        (ni(Down))/binary,
        "|",
        (nb(CallId))/binary,
        "|",
        (ni(Exp))/binary
    >>,
    mac(Data).

%% the pre-expiry marker: host, port, one flow and Call-ID
legacy_sign(Host, Port, Flow, CallId) ->
    mac(<<
        (nb(Host))/binary,
        "|",
        (ni(Port))/binary,
        "|",
        (ni(Flow))/binary,
        "|",
        (nb(CallId))/binary
    >>).

mac(Data) ->
    binary:encode_hex(crypto:macN(hmac, sha256, secret(), Data, 16), lowercase).

nb(undefined) -> <<>>;
nb(B) when is_binary(B) -> B.

ni(undefined) -> <<>>;
ni(I) when is_integer(I) -> integer_to_binary(I).

%% ---- internal ----

port_part(undefined) -> <<>>;
port_part(Port) -> <<":", (integer_to_binary(Port))/binary>>.

%% Routable base URI (scheme:host:port) and the host/port to MAC, from a
%% contact given as a name-addr or bare URI.
contact_hostport(undefined) ->
    {<<"sip:127.0.0.1">>, <<"127.0.0.1">>, undefined};
contact_hostport(Contact) ->
    case self_uri(Contact) of
        {ok, Scheme, Host, Port} ->
            SchemeB = atom_to_binary(Scheme, utf8),
            Base =
                <<SchemeB/binary, ":", Host/binary, (port_part(Port))/binary>>,
            {Base, Host, Port};
        error ->
            {Contact, Contact, undefined}
    end.

%% scheme/host/port of a contact given as a name-addr or bare URI.
self_uri(Bin) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(Bin)) of
        {ok, #{scheme := Scheme, host := Host} = M} ->
            {ok, Scheme, Host, maps:get(port, M, undefined)};
        _ ->
            error
    end.

%% parse a Route header value down to the URI map, or error.
route_uri(RouteValue) ->
    case chappe_sip_hdr:name_addr(RouteValue) of
        {ok, #{uri := Uri}} ->
            case chappe_sip_uri:parse(Uri) of
                {ok, U} -> {ok, U};
                _ -> error
            end;
        _ ->
            error
    end.

%% The engine route that sends over Flow: a WS connection, a TCP/TLS
%% connection of the native stack, or a UDP source address (RFC 5626 5.3).
-spec flow_route(chappe_sip_engine:flow()) -> chappe_sip_engine:route().
flow_route(Flow) when is_integer(Flow) -> {ws, Flow};
flow_route({conn, _} = Flow) -> Flow;
flow_route({udp, _, _} = Flow) -> Flow;
flow_route({udp, _, _, _} = Flow) -> Flow.
