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
%% The addresses of the running stack sit in a persistent term, written at
%% start and stop only, so these calls do not go through the engine.
-module(chappe_sip_binds).

-export([options/1, publish/1]).
-export([contacts/0, local/1, contact_at/1, tls_contact_at/1, pick_local/2]).
-export([contact_or_primary/2, send_ident/2, inherit/3]).

-define(BINDS, {?MODULE, binds}).

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
%% one URI or a list; the first stays `contact', the others go in
%% `contacts' with their idents (the address, normalized), and every one
%% gets an ident so a send can name it.
-spec options(map()) -> {ok, map()} | {error, {contact | tls, bad_contact}}.
options(#{contact := C} = Opts) ->
    case uri_list(C) of
        {ok, [First | Rest]} ->
            Plain = [normalize_one(U) || U <- [First | Rest]],
            case with_tls_binds(maps:get(tls, Opts, undefined)) of
                {ok, Tls} ->
                    [P1 | PRest] = Plain,
                    Opts1 = Opts#{
                        contact := P1,
                        ident => ident_of(P1),
                        contacts => [{U, ident_of(U)} || U <- PRest]
                    },
                    {ok,
                        case Tls of
                            undefined -> Opts1;
                            _ -> Opts1#{tls := Tls}
                        end};
                {error, _} = Err ->
                    Err
            end;
        error ->
            {error, {contact, bad_contact}}
    end;
options(Opts) ->
    {ok, Opts}.

with_tls_binds(#{contact := C} = Tls) ->
    case uri_list(C) of
        {ok, [First | Rest]} ->
            {ok, Tls#{
                contact := First,
                ident => ident_of(First),
                contacts => [{U, ident_of(U)} || U <- Rest]
            }};
        error ->
            {error, {tls, bad_contact}}
    end;
with_tls_binds(Tls) ->
    {ok, Tls}.

%% one URI or a non-empty list of at most 9 (the NIF binds 8 more)
uri_list(C) when is_binary(C) ->
    {ok, [C]};
uri_list([_ | _] = L) when length(L) < 10 ->
    case lists:all(fun is_binary/1, L) of
        true -> {ok, L};
        false -> error
    end;
uri_list(_) ->
    error.

%% An unrestricted sofia bind (transport=*) also opens a ws listener on
%% the TCP port and collides with the tcp transport (freeswitch fork
%% behavior). Default to udp,tcp unless the caller chose transports.
normalize_one(C) ->
    case binary:match(C, <<";transport=">>) of
        nomatch -> <<C/binary, ";transport=udp,tcp">>;
        _ -> C
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
    Binds = binds_of(Opts),
    case persistent_term:get(?BINDS, []) of
        Binds -> ok;
        _ -> persistent_term:put(?BINDS, Binds)
    end,
    ok.

binds_of(#{contact := _} = Opts) ->
    Plain = uris(Opts),
    Tls =
        case maps:get(tls, Opts, undefined) of
            #{contact := _} = TlsOpts -> uris(TlsOpts);
            _ -> []
        end,
    [bind(U, I, false) || {U, I} <- Plain] ++
        [bind(U, I, true) || {U, I} <- Tls];
binds_of(_) ->
    [].

%% {Uri, Ident} of contact, then of contacts
uris(#{contact := C} = Opts) ->
    [{C, maps:get(ident, Opts, ident_of(C))} | maps:get(contacts, Opts, [])].

bind(Uri, Ident, Tls) ->
    #{uri => bare_uri(Uri), ident => Ident, tls => Tls}.

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
