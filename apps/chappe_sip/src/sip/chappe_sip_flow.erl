%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Flows (RFC 5626): the connection or address a request came in on
%% and can be sent back over, the tokens that name one in a route, the
%% edge routes that send a request through the node holding a flow, and
%% the per-node secret and boot every route MAC is made under.
%%
%% A flow is a WS connection (an integer), a TCP/TLS connection of the
%% native stack ({conn, Id}) or a UDP source address ({udp, Ip, Port},
%% with the listen address it reached when there are several). As a token
%% in a URI parameter: a WS flow is its integer, a connection c<Id>, a UDP
%% address u<hex ip>-<port>[-<hex local>].
%%
%% Edge routes (RFC 5626 5.3): a registrar node that holds a binding's
%% flow hands out a Route naming itself and that flow (edge_route/4), so a
%% request from another node of a cluster goes through it. The route
%% carries `edge=<transport>' and a MAC over its host, port, flow,
%% transport and expiry (no Call-ID: it serves any new request), and
%% expires with the binding.
%%
%% The secret: flow_token_secret (at least 16 bytes), else a random one
%% per node, seeded at boot (ensure_secret/0). chappe_sip_route signs its
%% Record-Route markers with mac/1 under the same secret.
-module(chappe_sip_flow).

-export([received_flow/1, arrival_flow/1, nated/2, flow_route/1]).
-export([token/1, tokens/1, same/2]).
-export([edge_route/4, edge_flow/1, valid_edge/1]).
-export([ensure_secret/0, boot/0, booted_at/0, here/0]).
-export([mac/1, fields/1, mac_equal/2, expiry/1]).
-ifdef(TEST).
-export([check_secret/1, untoken/1]).
-endif.

-define(MARK, <<"espx">>).
%% the keys chappe_sip_route stored them under before they moved here, so a
%% node upgraded in place keeps its secret, its boot and the routes made
%% under them
-define(SECRET_KEY, {chappe_sip_route, flow_secret}).
-define(BOOT_KEY, {chappe_sip_route, boot}).
-define(BOOT_ID_KEY, {chappe_sip_route, boot_id}).

%% The flow a request arrived on, from its meta: its TCP/TLS connection,
%% or the address and port a UDP request came from (RFC 3581 received and
%% rport, RFC 5626 3.3), with the listen address it reached when there are
%% several, so what goes back leaves from that same socket.
-spec received_flow(map()) -> chappe_sip_engine:flow() | undefined.
received_flow(#{conn := Id}) when is_integer(Id) ->
    {conn, Id};
received_flow(
    #{transport := <<"udp">>, source_ip := Ip, source_port := Port} = Meta
) when
    Ip =/= <<>>, Port > 0
->
    case chappe_sip_binds:local(Meta) of
        undefined -> {udp, Ip, Port};
        Local -> {udp, Ip, Port, Local}
    end;
received_flow(_Meta) ->
    undefined.

%% The flow a request arrived on, from its meta: its WS flow, else its
%% TCP/TLS connection or UDP source (received_flow/1).
-spec arrival_flow(map()) -> chappe_sip_engine:flow() | undefined.
arrival_flow(#{flow := Flow}) when is_integer(Flow) ->
    Flow;
arrival_flow(Meta) ->
    received_flow(Meta).

%% A UDP Contact the UA cannot be reached at: its host and port are not the
%% address its request came from (a NAT in between, as Kamailio's
%% fix_nated_contact sees it). Requests to it go to that address instead.
-spec nated(binary() | undefined, term()) -> boolean().
nated(Contact, {udp, Ip, Port}) when is_binary(Contact) ->
    case chappe_sip_hdr:name_addr(Contact) of
        {ok, #{uri := Uri}} -> nated_uri(Uri, Ip, Port);
        _ -> nated_uri(Contact, Ip, Port)
    end;
nated(Contact, {udp, Ip, Port, _Local}) ->
    nated(Contact, {udp, Ip, Port});
nated(_Contact, _Flow) ->
    false.

nated_uri(Uri, Ip, Port) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{scheme := sip, host := Host} = U} ->
            Transport = maps:get(
                <<"transport">>, maps:get(params, U, #{}), <<"udp">>
            ),
            is_binary(Transport) andalso
                string:lowercase(Transport) =:= <<"udp">> andalso
                {strip_brackets(Host), maps:get(port, U, 5060)} =/= {Ip, Port};
        _ ->
            false
    end.

strip_brackets(<<"[", Rest/binary>>) ->
    binary:part(Rest, 0, byte_size(Rest) - 1);
strip_brackets(Host) ->
    Host.

%% The engine route that sends over Flow: a WS connection, a TCP/TLS
%% connection of the native stack, or a UDP source address (RFC 5626 5.3).
-spec flow_route(chappe_sip_engine:flow()) -> chappe_sip_engine:route().
flow_route(Flow) when is_integer(Flow) -> {ws, Flow};
flow_route({conn, _} = Flow) -> Flow;
flow_route({udp, _, _} = Flow) -> Flow;
flow_route({udp, _, _, _} = Flow) -> Flow.

%% A flow as a URI parameter value: a WS flow as its integer (the form
%% markers always had), a connection as c<Id>, a UDP address as
%% u<hex ip>-<port>, with -<hex local> when it names a listen address.
-spec token(chappe_sip_engine:flow()) -> binary().
token(Flow) when is_integer(Flow) ->
    integer_to_binary(Flow);
token({conn, Id}) ->
    <<"c", (integer_to_binary(Id))/binary>>;
token({udp, Ip, Port}) ->
    <<"u", (binary:encode_hex(Ip, lowercase))/binary, "-",
        (integer_to_binary(Port))/binary>>;
token({udp, Ip, Port, Local}) ->
    <<
        (token({udp, Ip, Port}))/binary,
        "-",
        (binary:encode_hex(Local, lowercase))/binary
    >>.

%% The flow a token names, or undefined.
-spec untoken(binary()) -> chappe_sip_engine:flow() | undefined.
untoken(<<"c", Id/binary>>) ->
    case to_int(Id) of
        N when is_integer(N), N > 0 -> {conn, N};
        _ -> undefined
    end;
untoken(<<"u", Rest/binary>>) ->
    %% the hex is the peer's to choose: any that does not decode names no
    %% flow
    try
        case binary:split(Rest, <<"-">>, [global]) of
            [Ip, Port] ->
                udp_flow(binary:decode_hex(Ip), to_int(Port), []);
            [Ip, Port, Local] ->
                udp_flow(binary:decode_hex(Ip), to_int(Port), [
                    binary:decode_hex(Local)
                ]);
            _ ->
                undefined
        end
    catch
        error:badarg -> undefined
    end;
untoken(V) ->
    to_int(V).

udp_flow(Ip, Port, Local) when
    is_integer(Port), Port > 0, Port < 65536, Ip =/= <<>>
->
    list_to_tuple([udp, Ip, Port | Local]);
udp_flow(_Ip, _Port, _Local) ->
    undefined.

to_int(V) ->
    try
        binary_to_integer(V)
    catch
        error:badarg -> undefined
    end.

%% The upstream (ftok) and downstream (ftokd) flows a route's parameters
%% name.
-spec tokens(map()) -> chappe_sip_route:flows().
tokens(P) ->
    {token_value(P, <<"ftok">>), token_value(P, <<"ftokd">>)}.

token_value(P, Name) ->
    case maps:get(Name, P, undefined) of
        V when is_binary(V) -> untoken(V);
        _ -> undefined
    end.

%% Two flows are the same; a UDP source matches a token with or without
%% its listen address.
-spec same(term(), term()) -> boolean().
same(undefined, _) -> false;
same(_, undefined) -> false;
same({udp, Ip, Port, _}, F) -> same({udp, Ip, Port}, F);
same(A, {udp, Ip, Port, _}) -> same(A, {udp, Ip, Port});
same(A, B) -> A =:= B.

%% The Route a registrar node hands out for a binding whose flow it holds
%% (RFC 5626 5.3): EdgeUri is this node's address, Flow the binding's flow,
%% Transport the one it came over (udp, tcp, tls, ws, wss), Exp the
%% binding's expiry (epoch seconds). A request that comes to us with it on
%% top is forwarded over Flow.
-spec edge_route(
    binary(), chappe_sip_engine:flow(), binary(), non_neg_integer()
) -> binary().
edge_route(EdgeUri, Flow, Transport, Exp) ->
    {Base, Host, Port} = chappe_sip_route:hostport(EdgeUri),
    Tok = token(Flow),
    Sig = edge_sign(Host, Port, Tok, Transport, Exp),
    <<"<", Base/binary, ";lr;", ?MARK/binary, "=", Sig/binary, ";exp=",
        (integer_to_binary(Exp))/binary, ";ftokd=", Tok/binary, ";edge=",
        Transport/binary, ">">>.

%% The flow and transport of a valid edge route on top of a request.
-spec edge_flow(chappe_sip_msg:msg()) ->
    {ok, chappe_sip_engine:flow(), binary()} | none.
edge_flow(Msg) ->
    case chappe_sip_route:routes(Msg) of
        [Top | _] -> edge_of(chappe_sip_route:route_uri(Top));
        [] -> none
    end.

edge_of({ok, #{params := #{<<"edge">> := T} = P} = U}) when is_binary(T) ->
    case {valid_edge(U), tokens(P)} of
        {true, {_, Flow}} when Flow =/= undefined -> {ok, Flow, T};
        _ -> none
    end;
edge_of(_) ->
    none.

%% An edge route's URI carries a MAC that validates and an expiry not
%% passed. It serves any new request: no Call-ID in its MAC.
-spec valid_edge(map()) -> boolean().
valid_edge(#{params := #{<<"edge">> := T, ?MARK := Sig} = P} = U) when
    is_binary(T), is_binary(Sig)
->
    case {expiry(P), maps:get(<<"ftokd">>, P, undefined)} of
        {{ok, Exp}, Tok} when is_binary(Tok) ->
            Host = maps:get(host, U, undefined),
            Port = maps:get(port, U, undefined),
            Exp >= erlang:system_time(second) andalso
                mac_equal(Sig, edge_sign(Host, Port, Tok, T, Exp));
        _ ->
            false
    end;
valid_edge(_U) ->
    false.

%% an edge route: host, port, flow token, transport and expiry, under its
%% own prefix so no Record-Route MAC can stand for one. A connection or WS
%% token also carries the boot: after a restart the same id may name
%% another device's connection. A UDP address stays valid.
edge_sign(Host, Port, <<"u", _/binary>> = Tok, Transport, Exp) ->
    edge_mac(Host, Port, Tok, Transport, Exp);
edge_sign(Host, Port, Tok, Transport, Exp) ->
    edge_mac(Host, Port, <<Tok/binary, (here())/binary>>, Transport, Exp).

edge_mac(Host, Port, Tok, Transport, Exp) ->
    mac(<<"e1|", (fields([Host, Port, Tok, Transport, Exp]))/binary>>).

%% The expiry of a route's parameters: {ok, Epoch}, legacy for a marker
%% minted before expiries existed, error when it does not parse.
-spec expiry(map()) -> {ok, integer()} | legacy | error.
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

%% ---- the secret, the boot and the MAC ----

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
            _ =
                persistent_term:get(?BOOT_ID_KEY, undefined) =:= undefined andalso
                    persistent_term:put(?BOOT_ID_KEY, new_boot_id()),
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

%% This VM's boot: a connection or WS flow id names something only within
%% one boot, so a route to one carries it.
-spec boot() -> binary().
boot() ->
    case persistent_term:get(?BOOT_ID_KEY, undefined) of
        undefined ->
            persistent_term:put(?BOOT_ID_KEY, new_boot_id()),
            persistent_term:get(?BOOT_ID_KEY);
        Id ->
            Id
    end.

new_boot_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

%% When this node seeded its secret (epoch seconds), else now.
-spec booted_at() -> integer().
booted_at() ->
    persistent_term:get(?BOOT_KEY, erlang:system_time(second)).

%% This node and boot, as a MAC carries them for a connection or WS id:
%% on another node sharing flow_token_secret, or after a restart that
%% reuses the id, it may be another device's connection.
-spec here() -> binary().
here() ->
    <<"|", (atom_to_binary(node()))/binary, "|", (boot())/binary>>.

%% The HMAC (truncated, hex) of Data under the node secret.
-spec mac(binary()) -> binary().
mac(Data) ->
    binary:encode_hex(crypto:macN(hmac, sha256, secret(), Data, 16), lowercase).

%% The fields of a MAC, joined by `|': undefined is empty, an integer its
%% decimal, a flow its token.
-spec fields([term()]) -> binary().
fields(Fields) ->
    iolist_to_binary(lists:join(<<"|">>, [field(F) || F <- Fields])).

field(undefined) -> <<>>;
field(B) when is_binary(B) -> B;
field(I) when is_integer(I) -> integer_to_binary(I);
field(Flow) -> token(Flow).

%% hash_equals/2 raises on unequal lengths and Sig is attacker-controlled
-spec mac_equal(binary(), binary()) -> boolean().
mac_equal(Sig, Expected) ->
    byte_size(Sig) =:= byte_size(Expected) andalso
        crypto:hash_equals(Sig, Expected).
