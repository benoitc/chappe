%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Record-Route construction and loose-routing helpers.
%%
%% A record-routing proxy inserts a Record-Route pointing at itself so the
%% endpoints route in-dialog requests (2xx ACK, BYE, re-INVITE) back through
%% it. This module builds that URI, recognises it when it comes back as the
%% top Route header, and pops it to find the next hop (RFC 3261 sections 16.4
%% to 16.6). No per-dialog state is kept: the route set on the wire carries
%% the target.
%%
%% Our Record-Route carries an authenticated "espx" parameter: an HMAC over
%% the route's host, port, flow token and Call-ID under a per-node secret. A
%% request is treated as ours (and loose-routed without middleware) only if
%% that MAC validates, so a crafted Route cannot turn the proxy into an open
%% relay, and the flow token cannot be forged to target another WS leg.
-module(chappe_sip_route).

-export([record_route/3, is_self/3, pop_self/1, strip_via/1, ensure_secret/0]).

-define(MARK, <<"espx">>).
-define(SECRET_KEY, {chappe_sip_route, flow_secret}).

%% Build the Record-Route header value to prepend (angle-bracketed) from the
%% engine's bound contact, for the dialog identified by CallId. Strips
%% transport params to a clean routable URI:
%% <sip:host:port;lr;espx=<MAC>[;ftok=<Flow>]>. With a WS-range Flow the flow
%% token names the WS leg so the peer's in-dialog requests route back over
%% that connection; the MAC binds the flow so it cannot be forged.
-spec record_route(binary() | undefined, integer() | undefined, binary()) ->
    binary().
record_route(Contact, Flow, CallId) ->
    {Base, Host, Port} = contact_hostport(Contact),
    Sig = sign(Host, Port, Flow, CallId),
    <<"<", Base/binary, ";lr;", ?MARK/binary, "=", Sig/binary,
        (ftok_param(Flow))/binary, ">">>.

ftok_param(Flow) when is_integer(Flow) ->
    <<";ftok=", (integer_to_binary(Flow))/binary>>;
ftok_param(_) ->
    <<>>.

%% Does this Route (or Record-Route) header value target us for the dialog
%% CallId? True only when it carries our marker with a MAC that validates
%% against the route's own host/port/ftok and CallId under the node secret.
-spec is_self(binary(), binary() | undefined, binary()) -> boolean().
is_self(RouteValue, _Contact, CallId) ->
    case route_uri(RouteValue) of
        {ok, #{params := P} = U} ->
            case maps:get(?MARK, P, undefined) of
                undefined -> false;
                % bare marker: no MAC, reject
                true -> false;
                Sig -> valid_sig(Sig, U, P, CallId)
            end;
        error ->
            false
    end.

valid_sig(Sig, U, P, CallId) when is_binary(Sig) ->
    Host = maps:get(host, U, undefined),
    Port = maps:get(port, U, undefined),
    Flow = ftok_value(P),
    Expected = sign(Host, Port, Flow, CallId),
    %% hash_equals/2 raises on unequal lengths and Sig is attacker-controlled
    byte_size(Sig) =:= byte_size(Expected) andalso
        crypto:hash_equals(Sig, Expected);
valid_sig(_Sig, _U, _P, _CallId) ->
    false.

%% Remove our own top Route and return the next hop: the URI of the new top
%% Route if one remains (multi-hop route set), else undefined so nta routes
%% by the Request-URI (the peer's Contact, single-proxy case). The flow token
%% is trusted here because is_self already validated the marker's MAC.
-spec pop_self(chappe_sip_msg:msg()) ->
    {binary() | undefined, integer() | undefined, chappe_sip_msg:msg()}.
pop_self(Msg) ->
    FTok = self_ftok(Msg),
    Msg1 = chappe_sip_msg:drop_first(<<"route">>, Msg),
    NextHop =
        case chappe_sip_msg:get(<<"route">>, Msg1) of
            undefined ->
                undefined;
            RVal ->
                case chappe_sip_hdr:name_addr(RVal) of
                    {ok, #{uri := Uri}} -> Uri;
                    _ -> undefined
                end
        end,
    {NextHop, FTok, Msg1}.

%% the ftok flow id in our own top Route, if any
self_ftok(Msg) ->
    case chappe_sip_msg:get(<<"route">>, Msg) of
        undefined ->
            undefined;
        RVal ->
            case route_uri(RVal) of
                {ok, #{params := P}} -> ftok_value(P);
                error -> undefined
            end
    end.

ftok_value(P) ->
    case maps:get(<<"ftok">>, P, undefined) of
        undefined ->
            undefined;
        V ->
            try
                binary_to_integer(V)
            catch
                _:_ -> undefined
            end
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
%% first-request race where two workers generate different secrets).
-spec ensure_secret() -> ok.
ensure_secret() ->
    _ = secret(),
    ok.

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
        Bin when is_binary(Bin), byte_size(Bin) >= 16 -> Bin;
        Str when is_list(Str), length(Str) >= 16 -> list_to_binary(Str);
        _ -> crypto:strong_rand_bytes(32)
    end.

%% HMAC (truncated, hex) over the route's host, port, flow and Call-ID.
sign(Host, Port, Flow, CallId) ->
    Data = <<
        (nb(Host))/binary,
        "|",
        (ni(Port))/binary,
        "|",
        (ni(Flow))/binary,
        "|",
        (nb(CallId))/binary
    >>,
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
    Uri =
        case chappe_sip_hdr:name_addr(Bin) of
            {ok, #{uri := U}} -> U;
            _ -> Bin
        end,
    case chappe_sip_uri:parse(Uri) of
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
