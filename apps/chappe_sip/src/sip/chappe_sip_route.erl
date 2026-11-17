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
%% Flow tokens (chappe_sip_flow): `ftok' names the flow the dialog-forming
%% request came in on (the upstream leg) and `ftokd' the flow it went out
%% on (the downstream leg). A WS-to-WS dialog carries both, so each side's
%% in-dialog requests route to the other. Edge routes, the secret and the
%% MAC are chappe_sip_flow's too.
-module(chappe_sip_route).

-export([record_route/3, record_route/4, is_self/3, pop_self/1, strip_via/1]).
-export([routes/1, set_routes/2, uri_is_self/2, recover_strict/1]).
-export([next_flow/2, request_target/2, secure_hop/2, redirect_targets/1]).
-export([route_uri/1, hostport/1]).

-export_type([flows/0]).

-ifdef(TEST).
-export([legacy_marker/4]).
-endif.

%% {Upstream flow, Downstream flow}: WS flows (integers), or the TCP/TLS
%% connection or UDP address a registration is reached over
-type flows() :: {
    chappe_sip_engine:flow() | undefined, chappe_sip_engine:flow() | undefined
}.

-define(MARK, <<"espx">>).

%% Build the Record-Route header value to prepend (angle-bracketed) from the
%% engine's bound contact, for the dialog identified by CallId. Strips
%% transport params to a clean routable URI:
%% <sip:host:port;lr;espx=<MAC>;exp=<T>[;ftok=<Up>][;ftokd=<Down>]>. The
%% scheme follows the contact, so a TLS contact gives a sips: route (RFC
%% 5630). A bare integer flow is the upstream leg.
-spec record_route(
    binary() | undefined, flows() | integer() | undefined, binary()
) -> binary().
record_route(Contact, Flow, CallId) ->
    record_route(Contact, Flow, CallId, #{}).

%% record_route/3 with options: `transport', a transport parameter for the
%% route (the side that reaches us over TCP or TLS).
-spec record_route(
    binary() | undefined,
    flows() | integer() | undefined,
    binary(),
    #{transport => binary()}
) -> binary().
record_route(Contact, Flow, CallId, Opts) when
    is_integer(Flow); Flow =:= undefined
->
    record_route(Contact, {Flow, undefined}, CallId, Opts);
record_route(Contact, {Up, Down}, CallId, Opts) ->
    {Base, Host, Port} = hostport(Contact),
    Exp = erlang:system_time(second) + ttl(),
    Sig = sign(Host, Port, {Up, Down}, CallId, Exp),
    <<"<", Base/binary, (transport_param(Opts))/binary, ";lr;", ?MARK/binary,
        "=", Sig/binary, ";exp=", (integer_to_binary(Exp))/binary,
        (flow_param(<<"ftok">>, Up))/binary,
        (flow_param(<<"ftokd">>, Down))/binary, ">">>.

transport_param(#{transport := T}) when is_binary(T) ->
    <<";transport=", T/binary>>;
transport_param(_) ->
    <<>>.

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

flow_param(_Name, undefined) ->
    <<>>;
flow_param(Name, Flow) ->
    <<";", Name/binary, "=", (chappe_sip_flow:token(Flow))/binary>>.

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

valid_uri(#{params := #{<<"edge">> := T}} = U, _CallId) when is_binary(T) ->
    chappe_sip_flow:valid_edge(U);
valid_uri(#{params := P} = U, CallId) ->
    case maps:get(?MARK, P, undefined) of
        Sig when is_binary(Sig) -> valid_sig(Sig, U, P, CallId);
        % absent, or a bare marker with no MAC
        _ -> false
    end.

valid_sig(Sig, U, P, CallId) ->
    Host = maps:get(host, U, undefined),
    Port = maps:get(port, U, undefined),
    case chappe_sip_flow:expiry(P) of
        {ok, Exp} ->
            Exp >= erlang:system_time(second) andalso
                chappe_sip_flow:mac_equal(
                    Sig, sign(Host, Port, flows(P), CallId, Exp)
                );
        legacy ->
            %% a marker minted before expiries existed (no exp): accepted
            %% only within one TTL of this node's boot, so a stable shared
            %% secret does not keep them alive forever, and only when it
            %% names no flow: its MAC carries no node or boot, so a WS id
            %% in it may be another node's, or one from before a restart
            no_flow(P) andalso legacy_window() andalso
                chappe_sip_flow:mac_equal(
                    Sig, legacy_sign(Host, Port, undefined, CallId)
                );
        error ->
            false
    end.

legacy_window() ->
    erlang:system_time(second) < chappe_sip_flow:booted_at() + ttl().

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
        [Top | Rest0] ->
            Flows =
                case route_uri(Top) of
                    {ok, #{params := P}} -> flows(P);
                    _ -> {undefined, undefined}
                end,
            %% RFC 5658 5: a double Record-Route of ours comes back as two
            %% Routes; the second is popped too, rather than spiralling
            Rest =
                case Rest0 of
                    [Next | Rest1] ->
                        case
                            is_self(
                                Next, undefined, chappe_sip_msg:call_id(Msg)
                            )
                        of
                            true -> Rest1;
                            false -> Rest0
                        end;
                    [] ->
                        Rest0
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

%% Where an in-dialog request goes: Arrived is the flow it came in on (a
%% WS flow, a connection or a UDP source; undefined when unknown). From
%% one leg it goes to the other one, or by the next hop when that leg has
%% no token; from elsewhere it goes to the leg the tokens name, when they
%% name one.
-spec next_flow(chappe_sip_engine:flow() | undefined, flows()) ->
    chappe_sip_engine:route() | next_hop.
next_flow(Arrived, {Up, Down}) when is_integer(Arrived) ->
    case {Arrived =:= Up, Arrived =:= Down} of
        {true, _} when Down =/= undefined -> chappe_sip_flow:flow_route(Down);
        {_, true} when Up =/= undefined -> chappe_sip_flow:flow_route(Up);
        _ -> next_hop
    end;
next_flow(Arrived, {Up, Down}) ->
    case
        {chappe_sip_flow:same(Arrived, Up), chappe_sip_flow:same(Arrived, Down)}
    of
        {true, _} when Down =/= undefined -> chappe_sip_flow:flow_route(Down);
        {_, true} when Up =/= undefined -> chappe_sip_flow:flow_route(Up);
        {false, false} -> named_flow(Up, Down);
        _ -> next_hop
    end.

named_flow(Up, undefined) when Up =/= undefined ->
    chappe_sip_flow:flow_route(Up);
named_flow(undefined, Down) when Down =/= undefined ->
    chappe_sip_flow:flow_route(Down);
named_flow(_Up, _Down) ->
    next_hop.

flows(P) ->
    chappe_sip_flow:tokens(P).

no_flow(P) ->
    not maps:is_key(<<"ftok">>, P) andalso not maps:is_key(<<"ftokd">>, P).

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

%% HMAC (truncated, hex) over the route's host, port, flows, Call-ID and
%% expiry.
sign(Host, Port, {Up, Down}, CallId, Exp) ->
    Fields = chappe_sip_flow:fields([Host, Port, Up, Down, CallId, Exp]),
    chappe_sip_flow:mac(<<"v2|", Fields/binary, (bound(Up, Down))/binary>>).

%% A connection or WS id names something only on the node and boot that
%% minted it: on another node sharing flow_token_secret, or after a
%% restart that reuses the id, it may be another device's connection. A
%% marker naming one carries both, so only its own node and boot accept
%% it. A UDP address names the same place from anywhere.
bound(Up, Down) ->
    case local_id(Up) orelse local_id(Down) of
        true -> chappe_sip_flow:here();
        false -> <<>>
    end.

local_id({conn, _}) -> true;
local_id(F) when is_integer(F) -> true;
local_id(_) -> false.

-ifdef(TEST).
%% A marker as releases before expiries minted it (tests).
legacy_marker(Host, Port, Flow, CallId) ->
    Sig = legacy_sign(Host, Port, Flow, CallId),
    Tok =
        case Flow of
            undefined -> <<>>;
            _ -> <<";ftok=", (integer_to_binary(Flow))/binary>>
        end,
    <<"<sip:", Host/binary, ":", (integer_to_binary(Port))/binary, ";lr;",
        ?MARK/binary, "=", Sig/binary, Tok/binary, ">">>.
-endif.

%% the pre-expiry marker: host, port, one flow and Call-ID
legacy_sign(Host, Port, Flow, CallId) ->
    chappe_sip_flow:mac(chappe_sip_flow:fields([Host, Port, Flow, CallId])).

%% ---- internal ----

port_part(undefined) -> <<>>;
port_part(Port) -> <<":", (integer_to_binary(Port))/binary>>.

%% Routable base URI (scheme:host:port) and the host/port to MAC, from a
%% contact given as a name-addr or bare URI.
-spec hostport(binary() | undefined) ->
    {binary(), binary(), inet:port_number() | undefined}.
hostport(undefined) ->
    {<<"sip:127.0.0.1">>, <<"127.0.0.1">>, undefined};
hostport(Contact) ->
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
-spec route_uri(binary()) -> {ok, map()} | error.
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

%% The targets a 3xx names, for a UAC or a proxy that recurses on it: its
%% sip/sips Contacts by q (1.0 when absent), header order on a tie, each
%% once, as {Uri, Contact value}. A URI's ?headers part is dropped: a
%% redirect may not add headers to our request (RFC 3261 19.1.5 makes
%% them optional); its method parameter is dropped too (8.1.3.4). A SIPS
%% URI naming UDP is no target (19.1.1).
-spec redirect_targets(chappe_sip_msg:msg()) -> [{binary(), binary()}].
redirect_targets(Msg) ->
    Contacts = [
        {C, V}
     || H <- chappe_sip_msg:get_all(<<"contact">>, Msg),
        V <- chappe_sip_hdr:split_list(H),
        {ok, C} <- [chappe_sip_hdr:name_addr(V)]
    ],
    Ranked = [
        {-q_value(maps:get(params, C, #{})), I, without_headers(Uri), V}
     || {I, {#{uri := Uri} = C, V}} <- lists:enumerate(Contacts),
        supported_target(Uri)
    ],
    dedup([{U, V} || {_, _, U, V} <- lists:sort(Ranked)]).

dedup([]) -> [];
dedup([{U, _} = H | T]) -> [H | dedup([X || {Y, _} = X <- T, Y =/= U])].

supported_target(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{scheme := S}} when S =:= sip; S =:= sips ->
            not chappe_sip_uri:is_sips_unreliable(Uri);
        _ ->
            false
    end.

without_headers(Uri) ->
    {_, U} = chappe_sip_uri:take_param(
        hd(binary:split(Uri, <<"?">>)), <<"method">>
    ),
    U.

q_value(#{<<"q">> := Q}) when is_binary(Q) ->
    try
        binary_to_float(Q)
    catch
        error:badarg ->
            try
                float(binary_to_integer(Q))
            catch
                error:badarg -> 0.0
            end
    end;
q_value(_) ->
    1.0.
