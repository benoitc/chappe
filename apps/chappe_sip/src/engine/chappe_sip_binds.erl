%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The listen addresses of the native stack.
%%
%% contact and tls.contact of chappe_sip:start/1 take one URI or a list.
%% Each listen address gets an ident, its host as a canonical address,
%% which the NIF binds with (TPTAG_IDENT) and reports in the meta of every
%% request it delivers (local). With more than one address:
%% - a request is answered (the 2xx Contact) and record-routed with the
%%   address it came to, and the dialog it forms sends from there;
%% - a request we originate leaves from the address its local option names,
%%   else the first one of the target's address family;
%% - a UDP flow a registration is learned on keeps its address.
%% With one address none of this applies and nothing changes.
%%
%% A contact may also be a map, for a host behind 1:1 NAT (a cloud VM
%% with a private address and a public one):
%% ```
%%   #{uri := <<"sip:10.0.0.5:5060">>, public => <<"203.0.113.7">>,
%%     local_nets => [<<"10.0.0.0/8">>]}
%% '''
%% The stack binds the uri's address and advertises the public one in its
%% Via and Contact. A peer inside one of local_nets gets the local address
%% in the Contact instead (for_peer/2).
%%
%% The addresses of the running stack sit in a persistent term, written at
%% start and stop only, so these calls do not go through the engine.
-module(chappe_sip_binds).

-export([options/1, publish/1, aliases/1, own_uris/0, own_hosts/0]).
-export([outbound_route/0, outbound_route_opt/1]).
-export([contacts/0, local/1, contact_at/1, tls_contact_at/1, pick_local/2]).
-export([contact_or_primary/2, send_ident/2, inherit/3, for_peer/2]).

-define(BINDS, {?MODULE, binds}).
-define(ALIASES, {?MODULE, aliases}).
-define(OUTBOUND, {?MODULE, outbound_route}).

%% Every listen address, plain then TLS, as bare URIs (no parameters).
-spec contacts() -> [binary()].
contacts() ->
    [U || #{uri := U} <- binds()].

%% The ident of the listen address a request arrived on (its meta), when
%% the stack listens on more than one address; undefined otherwise.
-spec local(map()) -> binary() | undefined.
local(Meta) ->
    case maps:get(local, Meta, undefined) of
        L when is_binary(L) ->
            case multi_homed() of
                true -> L;
                false -> undefined
            end;
        _ ->
            undefined
    end.

%% The SIP URI of the listen address with this ident, or undefined (no
%% such address, or a wildcard one).
-spec contact_at(binary() | undefined) -> binary() | undefined.
contact_at(Local) ->
    at(Local, false).

%% The same for the TLS listener on that address (a sips: URI).
-spec tls_contact_at(binary() | undefined) -> binary() | undefined.
tls_contact_at(Local) ->
    at(Local, true).

%% The address a request to Target leaves from when the stack listens on
%% several: the one named by Local (an address, as a binary, a string or a
%% tuple), else the first of the target's address family; undefined with a
%% single address, or when none fits (the stack then picks).
-spec pick_local(term(), binary() | undefined) -> binary() | undefined.
pick_local(Local, Target) ->
    case multi_homed() of
        false -> undefined;
        true -> pick_local_1(Local, Target)
    end.

pick_local_1(undefined, Target) ->
    case family(target_host(Target)) of
        undefined ->
            undefined;
        Fam ->
            case [I || #{ident := I} <- binds(), family(I) =:= Fam] of
                [I | _] -> I;
                [] -> undefined
            end
    end;
pick_local_1(Local, _Target) ->
    I = ident(Local),
    case lists:any(fun(#{ident := B}) -> B =:= I end, binds()) of
        true -> I;
        false -> undefined
    end.

%% The NIF options for every listen address: contact and tls.contact take
%% one URI (or contact map) or a list; the first stays `contact', the
%% others go in `contacts' with their idents (the address, normalized),
%% and every one gets an ident so a send can name it. A contact map with
%% public becomes sofia's maddr form; what for_peer/2 needs goes in `nat'
%% (the NIF ignores it). A contact naming sofia's ws or wss transport, or
%% every transport (*), is badarg: only the Erlang transport serves
%% WebSocket.
-spec options(map()) ->
    {ok, map()}
    | {error,
        badarg
        | {contact | tls, bad_contact | bad_public | bad_local_nets}}.
options(#{contact := C} = Opts) ->
    case binds_opts(C, fun chappe_sip_bind_uri:native/1) of
        {ok, First, Rest, Nat} ->
            case with_tls_binds(maps:get(tls, Opts, undefined)) of
                {ok, Tls, TlsNat} ->
                    Opts1 = with_nat(
                        Opts#{
                            contact := First,
                            ident => ident_of(First, Nat),
                            contacts => [{U, ident_of(U, Nat)} || U <- Rest]
                        },
                        Nat ++ TlsNat
                    ),
                    {ok,
                        case Tls of
                            undefined -> Opts1;
                            _ -> Opts1#{tls := Tls}
                        end};
                {error, _} = Err ->
                    Err
            end;
        {error, badarg} ->
            {error, badarg};
        {error, Why} ->
            {error, {contact, Why}}
    end;
options(Opts) ->
    {ok, Opts}.

with_tls_binds(#{contact := C} = Tls) ->
    case binds_opts(C, fun chappe_sip_bind_uri:tls/1) of
        {ok, First, Rest, Nat} ->
            {ok,
                Tls#{
                    contact := First,
                    ident => ident_of(First, Nat),
                    contacts => [{U, ident_of(U, Nat)} || U <- Rest]
                },
                Nat};
        {error, badarg} ->
            {error, badarg};
        {error, Why} ->
            {error, {tls, Why}}
    end;
with_tls_binds(Tls) ->
    {ok, Tls, []}.

with_nat(Opts, []) -> maps:remove(nat, Opts);
with_nat(Opts, Nat) -> Opts#{nat => Nat}.

%% the bind URIs of a contact option, each normalized, with an entry
%% {Uri, LocalIdent, LocalUri, Nets} for each contact map with public
binds_opts(C, Norm) ->
    case uri_list(C) of
        {ok, L} ->
            case
                lists:foldr(
                    fun(U, Acc) -> bind_opt(U, Norm, Acc) end, {[], []}, L
                )
            of
                {[First | Rest], Nat} -> {ok, First, Rest, Nat};
                {error, _} = Err -> Err
            end;
        error ->
            {error, bad_contact}
    end.

bind_opt(_U, _Norm, {error, _} = Err) ->
    Err;
bind_opt(U, Norm, {Us, Nat}) when is_binary(U) ->
    case Norm(U) of
        {ok, U1} -> {[U1 | Us], Nat};
        badarg -> {error, badarg}
    end;
bind_opt(#{uri := U} = M, Norm, {Us, Nat}) ->
    case Norm(U) of
        {ok, U1} ->
            case nat_bind(U1, M) of
                {ok, Uri, undefined} -> {[Uri | Us], Nat};
                {ok, Uri, Entry} -> {[Uri | Us], [Entry | Nat]};
                {error, _} = Err -> Err
            end;
        badarg ->
            {error, badarg}
    end.

%% one URI or a non-empty list of at most 9 (the NIF binds 8 more)
uri_list(C) when is_binary(C) ->
    {ok, [C]};
uri_list(#{uri := U} = C) when is_binary(U) ->
    {ok, [C]};
uri_list([_ | _] = L) when length(L) < 10 ->
    case lists:all(fun is_bind/1, L) of
        true -> {ok, L};
        false -> error
    end;
uri_list(_) ->
    error.

is_bind(B) when is_binary(B) -> true;
is_bind(#{uri := U}) when is_binary(U) -> true;
is_bind(_) -> false.

%% A contact map. With public, the URI sofia binds is the public host with
%% the local address as maddr: nta_agent_add_tport binds maddr and puts
%% the host in Via and Contact. local_nets needs public and a concrete
%% local address to hand out.
nat_bind(Uri, M) ->
    Public = maps:get(public, M, undefined),
    case
        {Public, chappe_sip_uri:parse(Uri), nets(maps:get(local_nets, M, []))}
    of
        {_, _, error} ->
            {error, bad_local_nets};
        {undefined, {ok, _}, {ok, []}} ->
            {ok, Uri, undefined};
        {_, {ok, #{host := Local, params := Params} = U}, {ok, Nets}} ->
            Wild = lists:member(ident(Local), [<<"0.0.0.0">>, <<"::">>]),
            case
                is_host(Public) andalso
                    not has_param(<<"maddr">>, Params) andalso
                    not (Wild andalso Nets =/= [])
            of
                true ->
                    Bound = public_uri(Uri, U, Public, Local),
                    {ok, Bound, {Bound, ident(Local), bare_uri(Uri), Nets}};
                false ->
                    {error, bad_public}
            end;
        _ ->
            {error, bad_contact}
    end.

%% sip:PUBLIC[:PORT];params;maddr=LOCAL, the parameters kept as written
%% (chappe_sip_uri:format would escape the comma of transport=udp,tcp)
public_uri(Uri, #{scheme := Scheme} = U, Public, Local) ->
    Port =
        case maps:get(port, U, undefined) of
            undefined -> <<>>;
            N -> <<":", (integer_to_binary(N))/binary>>
        end,
    Params =
        case binary:match(Uri, <<";">>) of
            {At, _} -> binary:part(Uri, At, byte_size(Uri) - At);
            nomatch -> <<>>
        end,
    <<
        (atom_to_binary(Scheme))/binary,
        ":",
        Public/binary,
        Port/binary,
        Params/binary,
        ";maddr=",
        Local/binary
    >>.

nets(L) when is_list(L) ->
    Parsed = [chappe_sip_net:cidr(C) || C <- L],
    case [N || {ok, N} <- Parsed] of
        Nets when length(Nets) =:= length(L) -> {ok, Nets};
        _ -> error
    end;
nets(_) ->
    error.

has_param(Name, Params) ->
    lists:any(
        fun(K) -> chappe_sip_lib:lower(K) =:= Name end, maps:keys(Params)
    ).

%% a host for a SIP URI: an IPv4 address, a bracketed IPv6 one or a name
is_host(<<"[", _/binary>> = H) when byte_size(H) > 2 ->
    binary:last(H) =:= $] andalso
        case chappe_sip_net:address(binary:part(H, 1, byte_size(H) - 2)) of
            {ok, Ip} -> tuple_size(Ip) =:= 8;
            error -> false
        end;
is_host(H) when is_binary(H), byte_size(H) > 0, byte_size(H) =< 253 ->
    lists:all(fun is_host_char/1, binary_to_list(H));
is_host(_) ->
    false.

is_host_char(C) when C >= $a, C =< $z -> true;
is_host_char(C) when C >= $A, C =< $Z -> true;
is_host_char(C) when C >= $0, C =< $9 -> true;
is_host_char(C) -> C =:= $. orelse C =:= $-.

%% the ident of a bind URI: the local address of a public one, else its
%% host
ident_of(Contact, Nat) ->
    case lists:keyfind(Contact, 1, Nat) of
        {_, Ident, _, _} -> Ident;
        false -> ident_of(Contact)
    end.

%% the ident of a contact: its host, an address in its canonical form
ident_of(Contact) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(Contact)) of
        {ok, #{host := H}} -> ident(H);
        _ -> <<"?">>
    end.

ident(Ip) when is_tuple(Ip) ->
    case inet:ntoa(Ip) of
        {error, _} -> <<"?">>;
        S -> list_to_binary(S)
    end;
ident(L) when is_list(L) ->
    ident(list_to_binary(L));
ident(<<"[", _/binary>> = H) ->
    ident(binary:part(H, 1, byte_size(H) - 2));
ident(H) when is_binary(H) ->
    case inet:parse_address(binary_to_list(H)) of
        {ok, Ip} -> ident(Ip);
        {error, _} -> string:lowercase(H)
    end;
ident(_) ->
    <<"?">>.

%% Record the listen addresses of the started stack (Opts are its NIF
%% options; #{} once stopped), for the calls above.
-spec publish(map()) -> ok.
publish(Opts) ->
    put_term(?BINDS, binds_of(Opts)),
    put_term(?ALIASES, maps:get(aliases, Opts, [])),
    put_term(?OUTBOUND, [
        R
     || R <- [maps:get(outbound_route, Opts, undefined)], R =/= undefined
    ]).

%% The route set preloaded on a request that names no proxy, flow or
%% route of its own (the outbound_route start option, RFC 3261 8.1.2): []
%% or the one Route value.
-spec outbound_route() -> [binary()].
outbound_route() ->
    persistent_term:get(?OUTBOUND, []).

%% outbound_route => Uri: a sip: or sips: URI with no NUL, as a loose
%% Route value (;lr added when missing)
-spec outbound_route_opt(term()) -> {ok, binary()} | error.
outbound_route_opt(U) when is_binary(U), byte_size(U) < 512 ->
    %% a bare URI keeps its parameters (transport=...); <...> is unwrapped
    Bare =
        case U of
            <<"<", _/binary>> -> chappe_sip_hdr:name_addr_uri(U);
            _ -> U
        end,
    case
        binary:match(U, <<0>>) =:= nomatch andalso chappe_sip_uri:parse(Bare)
    of
        {ok, #{scheme := S, params := P}} when S =:= sip; S =:= sips ->
            case has_param(<<"lr">>, P) of
                true -> {ok, <<"<", Bare/binary, ">">>};
                false -> {ok, <<"<", Bare/binary, ";lr>">>}
            end;
        _ ->
            error
    end;
outbound_route_opt(_) ->
    error.

put_term(Key, Value) ->
    case persistent_term:get(Key, []) of
        Value -> ok;
        _ -> persistent_term:put(Key, Value)
    end,
    ok.

%% aliases => [Name]: other names of this node (a DNS name, or a sip: or
%% sips: URI), at most 16, each a host with an optional port. A request
%% routed to one is routed to us.
-spec aliases(term()) -> ok | error.
aliases(L) when is_list(L), length(L) =< 16 ->
    case lists:all(fun is_alias/1, L) of
        true -> ok;
        false -> error
    end;
aliases(_) ->
    error.

is_alias(<<"sip:", _/binary>> = U) -> is_alias_uri(U);
is_alias(<<"sips:", _/binary>> = U) -> is_alias_uri(U);
is_alias(H) when is_binary(H) -> is_alias_uri(<<"sip:", H/binary>>);
is_alias(_) -> false.

is_alias_uri(U) ->
    case binary:match(U, [<<0>>, <<";">>, <<"@">>, <<"?">>]) of
        nomatch ->
            case chappe_sip_uri:parse(U) of
                {ok, #{host := H}} -> is_host(H);
                _ -> false
            end;
        _ ->
            false
    end.

%% Every URI that names this node: the listen addresses (public and
%% local), and the aliases, an alias with no port on the port of each
%% listen address.
-spec own_uris() -> [binary()].
own_uris() ->
    Binds = binds(),
    Uris = lists:append([[U | local_of(B)] || #{uri := U} = B <- Binds]),
    Ports = lists:usort([port_of(U) || U <- Uris]),
    Uris ++
        lists:append([
            alias_uris(A, Ports)
         || A <- persistent_term:get(?ALIASES, [])
        ]).

%% The hosts of own_uris/0, lowercased: the names and addresses of this
%% node.
-spec own_hosts() -> [binary()].
own_hosts() ->
    lists:usort([
        chappe_sip_lib:lower(H)
     || U <- own_uris(),
        {ok, #{host := H}} <- [chappe_sip_uri:parse(U)]
    ]).

local_of(#{local_uri := L}) -> [L];
local_of(_) -> [].

port_of(U) ->
    case chappe_sip_uri:parse(U) of
        {ok, #{port := P}} -> integer_to_binary(P);
        _ -> undefined
    end.

alias_uris(A, Ports) ->
    Uri =
        case A of
            <<"sip", _/binary>> -> A;
            _ -> <<"sip:", A/binary>>
        end,
    case port_of(Uri) of
        undefined ->
            [Uri] ++
                [<<Uri/binary, ":", P/binary>> || P <- Ports, P =/= undefined];
        _ ->
            [Uri]
    end.

binds_of(#{contact := _} = Opts) ->
    Plain = uris(Opts),
    Tls =
        case maps:get(tls, Opts, undefined) of
            #{contact := _} = TlsOpts -> uris(TlsOpts);
            _ -> []
        end,
    Nat = maps:get(nat, Opts, []),
    [bind(U, I, false, Nat) || {U, I} <- Plain] ++
        [bind(U, I, true, Nat) || {U, I} <- Tls];
binds_of(_) ->
    [].

%% {Uri, Ident} of contact, then of contacts
uris(#{contact := C} = Opts) ->
    [{C, maps:get(ident, Opts, ident_of(C))} | maps:get(contacts, Opts, [])].

bind(Uri, Ident, Tls, Nat) ->
    B = #{uri => bare_uri(Uri), ident => Ident, tls => Tls},
    case lists:keyfind(Uri, 1, Nat) of
        {_, _, Local, [_ | _] = Nets} -> B#{local_uri => Local, nets => Nets};
        _ -> B
    end.

%% The Contact URI a peer at Peer (an address) gets: a public listen
%% address becomes its local one for a peer inside its local_nets, so
%% traffic that never leaves the private network does not hairpin through
%% the NAT. Anything else comes back as it is.
-spec for_peer(binary(), binary() | inet:ip_address() | undefined) ->
    binary().
for_peer(Uri, Peer) when is_binary(Uri) ->
    case peer_ip(Peer) of
        {ok, Ip} ->
            Bare = bare_uri(Uri),
            case
                [
                    L
                 || #{uri := U, local_uri := L, nets := Nets} <- binds(),
                    U =:= Bare,
                    lists:any(fun(N) -> chappe_sip_net:in_net(Ip, N) end, Nets)
                ]
            of
                [L | _] -> binary:replace(Uri, Bare, L);
                [] -> Uri
            end;
        error ->
            Uri
    end;
for_peer(Uri, _Peer) ->
    Uri.

peer_ip(Ip) when is_tuple(Ip) ->
    {ok, Ip};
peer_ip(<<"[", _/binary>> = H) when byte_size(H) > 2 ->
    chappe_sip_net:address(binary:part(H, 1, byte_size(H) - 2));
peer_ip(H) when is_binary(H) ->
    chappe_sip_net:address(H);
peer_ip(_) ->
    error.

bare_uri(Uri) ->
    Bare = chappe_sip_hdr:name_addr_uri(Uri),
    case binary:split(Bare, <<";">>) of
        [B | _] -> B;
        _ -> Bare
    end.

binds() ->
    persistent_term:get(?BINDS, []).

multi_homed() ->
    case lists:usort([I || #{ident := I} <- binds()]) of
        [_, _ | _] -> true;
        _ -> false
    end.

%% The URI of the listen address the request came to, else the primary
%% one of that kind (the proxy's Record-Route).
-spec contact_or_primary(binary() | undefined, Tls :: boolean()) ->
    binary() | undefined.
contact_or_primary(Local, Tls) ->
    case {at(Local, Tls), Tls} of
        {undefined, true} -> chappe_sip_engine:tls_contact();
        {undefined, false} -> chappe_sip_engine:contact();
        {U, _} -> U
    end.

%% the URI of the listen address with this ident (TLS or not), not a
%% wildcard one
at(undefined, _Tls) ->
    undefined;
at(Local, Tls) ->
    case
        [
            U
         || #{ident := I, tls := T, uri := U} <- binds(),
            I =:= Local,
            T =:= Tls,
            not lists:member(I, [<<"0.0.0.0">>, <<"::">>, <<"*">>])
        ]
    of
        [U | _] -> U;
        [] -> undefined
    end.

target_host(undefined) ->
    undefined;
target_host(Target) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(Target)) of
        {ok, #{host := H}} -> ident(H);
        _ -> undefined
    end.

family(undefined) ->
    undefined;
family(Host) ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, Ip} when tuple_size(Ip) =:= 4 -> inet;
        {ok, _} -> inet6;
        {error, _} -> undefined
    end.

%% the ident a request is sent from: a UDP flow's own (the listen address
%% its binding was learned on), else the sender's
-spec send_ident(chappe_sip_engine:route(), binary() | undefined) ->
    binary() | undefined.
send_ident({udp, _, _, Local}, _Sender) -> Local;
send_ident({conn, _}, _Sender) -> undefined;
send_ident(_Route, Sender) -> Sender.

%% a dialog a UAC forms sends from the UAC's address
-spec inherit(pid(), pid(), #{pid() => binary()}) -> #{pid() => binary()}.
inherit(Caller, Pid, Locals) ->
    case Locals of
        #{Caller := L} -> Locals#{Pid => L};
        _ -> Locals
    end.
