%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc RFC 3261 section 16 rules of chappe_sip_proxy that need no state:
%% the best response of a response context (16.7 steps 6 and 7), loop
%% detection (16.3 step 4, 16.6 step 8) and the Request-URI of a branch
%% (16.6 step 2, RFC 5630 5.3).
-module(chappe_sip_proxy_rules).

-export([best_response/1, loop_hash/1, looped/1, new_branch/1, own_hops/1]).
-export([retarget/2, is_own_address/1]).
-export([record_routes/1, rr_contact/2, next_hop/3]).

%% the reasons 4xx preferred by 16.7 step 6: they let the client retry
-define(RETRY_4XX, [401, 407, 415, 420, 484]).

%% RFC 3261 16.7 step 6: the best of the branches' finals, in arrival
%% order. A 6xx wins; otherwise the lowest class, and in 4xx a response the
%% client can act on (401, 407, 415, 420, 484). The 401/407 challenges of
%% every branch are gathered into the chosen one (16.7 step 7), the 3xx
%% Contacts are merged, and a 503 becomes a 500.
-spec best_response([{100..699, binary() | undefined}]) ->
    {100..699, binary() | undefined}.
best_response(Finals) ->
    {Status, Raw} = choose(Finals),
    case Status of
        503 ->
            {500, undefined};
        _ when Status =:= 401; Status =:= 407 ->
            {Status, merge_headers(Raw, Finals, [401, 407], auth_headers())};
        _ when Status >= 300, Status < 400 ->
            {Status,
                merge_headers(Raw, Finals, lists:seq(300, 399), [
                    <<"contact">>
                ])};
        _ ->
            {Status, Raw}
    end.

choose(Finals) ->
    case [F || {S, _} = F <- Finals, S >= 600] of
        [F6 | _] ->
            F6;
        [] ->
            Class = lists:min([S div 100 || {S, _} <- Finals]),
            InClass = [F || {S, _} = F <- Finals, S div 100 =:= Class],
            Preferred = [
                F
             || {S, _} = F <- InClass,
                Class =:= 4,
                lists:member(S, ?RETRY_4XX)
            ],
            hd(Preferred ++ InClass)
    end.

auth_headers() -> [<<"www-authenticate">>, <<"proxy-authenticate">>].

%% Copy the Names headers of every other final whose status is in Codes
%% into Raw, skipping values Raw already has.
merge_headers(undefined, _Finals, _Codes, _Names) ->
    undefined;
merge_headers(Raw, Finals, Codes, Names) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} ->
            Others = [
                O
             || {S, O} <- Finals,
                O =/= Raw,
                is_binary(O),
                lists:member(S, Codes)
            ],
            M1 = lists:foldl(
                fun(O, Acc) -> copy_headers(O, Names, Acc) end, M, Others
            ),
            iolist_to_binary(chappe_sip_msg:encode(M1));
        {error, _} ->
            Raw
    end.

copy_headers(Raw, Names, M) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, O} ->
            lists:foldl(
                fun(N, Acc) ->
                    add_missing(N, chappe_sip_msg:get_all(N, O), Acc)
                end,
                M,
                Names
            );
        {error, _} ->
            M
    end.

%% add the values of header N that M does not have yet
add_missing(N, Values, M) ->
    Have = chappe_sip_msg:get_all(N, M),
    lists:foldl(
        fun(V, A) -> chappe_sip_msg:add(hdr_name(N), V, A) end,
        M,
        [V || V <- Values, not lists:member(V, Have)]
    ).

hdr_name(<<"www-authenticate">>) -> <<"WWW-Authenticate">>;
hdr_name(<<"proxy-authenticate">>) -> <<"Proxy-Authenticate">>;
hdr_name(<<"contact">>) -> <<"Contact">>.

%% ---- loop detection (16.3 step 4, 16.6 step 8) ----

%% A hash of the fields a loop leaves unchanged and a spiral changes: the
%% Request-URI, the tags, Call-ID, CSeq number, Proxy-Require and
%% Proxy-Authorization of the request as received.
-spec loop_hash(chappe_sip_msg:msg()) -> binary().
loop_hash(Msg) ->
    CSeq =
        case chappe_sip_msg:cseq(Msg) of
            {ok, #{seq := N}} -> integer_to_binary(N);
            _ -> <<>>
        end,
    Fields = [
        nb(chappe_sip_msg:uri(Msg)),
        nb(chappe_sip_msg:from_tag(Msg)),
        nb(chappe_sip_msg:to_tag(Msg)),
        nb(chappe_sip_msg:call_id(Msg)),
        CSeq,
        lists:join(<<",">>, chappe_sip_msg:get_all(<<"proxy-require">>, Msg)),
        lists:join(
            <<",">>, chappe_sip_msg:get_all(<<"proxy-authorization">>, Msg)
        )
    ],
    Data = iolist_to_binary(lists:join(<<"|">>, Fields)),
    binary:encode_hex(binary:part(crypto:hash(sha256, Data), 0, 8), lowercase).

nb(undefined) -> <<>>;
nb(B) -> B.

%% the request carries a Via of ours whose branch holds this request's hash
looped(Msg) ->
    Hash = loop_hash(Msg),
    Own = own_addresses(),
    lists:any(
        fun(V) ->
            case chappe_sip_hdr:via(V) of
                {ok, #{host := H, params := #{<<"branch">> := Branch}} = Via} ->
                    lists:member({H, maps:get(port, Via, 5060)}, Own) andalso
                        branch_hash(Branch) =:= Hash;
                _ ->
                    false
            end
        end,
        vias(Msg)
    ).

%% How many times the request already went through this proxy: the Vias
%% of ours (our address, our branch) it carries. A spiral or a redirect
%% to one of our own URIs brings it back with one more.
-spec own_hops(chappe_sip_msg:msg()) -> non_neg_integer().
own_hops(Msg) ->
    Own = own_addresses(),
    length([
        V
     || V <- vias(Msg),
        {ok, #{host := H, params := #{<<"branch">> := B}} = Via} <- [
            chappe_sip_hdr:via(V)
        ],
        branch_hash(B) =/= undefined,
        lists:member({H, maps:get(port, Via, 5060)}, Own)
    ]).

vias(Msg) ->
    lists:append([
        chappe_sip_hdr:split_list(V)
     || V <- chappe_sip_msg:get_all(<<"via">>, Msg)
    ]).

branch_hash(<<"z9hG4bKcx", Hash:16/binary, _/binary>>) -> Hash;
branch_hash(_) -> undefined.

new_branch(Hash) ->
    Rand = binary:encode_hex(crypto:strong_rand_bytes(6), lowercase),
    <<"z9hG4bKcx", Hash/binary, ".", Rand/binary>>.

own_addresses() ->
    [
        A
     || C <- [
            chappe_sip_engine:contact(),
            chappe_sip_engine:tls_contact()
            | chappe_sip_binds:own_uris()
        ],
        {ok, A} <- [hostport(C)]
    ].

is_own_address(Uri) ->
    case hostport(Uri) of
        {ok, A} -> lists:member(A, own_addresses());
        error -> false
    end.

hostport(undefined) ->
    error;
hostport(Bin) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(Bin)) of
        {ok, #{host := H} = U} ->
            Default =
                case maps:get(scheme, U, sip) of
                    sips -> 5061;
                    _ -> 5060
                end,
            {ok, {H, maps:get(port, U, Default)}};
        _ ->
            error
    end.

%% A full URI is the new Request-URI; a bare host[:port] keeps the user
%% and parameters of the Request-URI and replaces its host and port. RFC
%% 5630 5.3: a SIPS request is only forwarded to a SIPS target, and a SIP
%% request to a SIPS target keeps a SIP Request-URI but goes over TLS (the
%% third element is that TLS next hop, or undefined). A SIPS target whose
%% transport parameter names UDP is refused (RFC 3261 19.1.1).
retarget({ws, _}, Msg) ->
    {ok, Msg, undefined};
retarget({route, Uri, _RouteSet}, Msg) ->
    retarget(Uri, Msg);
retarget({flow, Uri, _Flow}, Msg) ->
    %% a binding reached over its flow: the Request-URI is its contact
    retarget(Uri, Msg);
retarget(<<"sip:", _/binary>> = Uri, Msg) ->
    case chappe_sip_uri:is_sips(chappe_sip_msg:uri(Msg)) of
        true -> {error, sips_required};
        false -> {ok, chappe_sip_msg:set_uri(Uri, Msg), undefined}
    end;
retarget(<<"sips:", Rest/binary>> = Uri, Msg) ->
    case
        {
            chappe_sip_uri:is_sips_unreliable(Uri),
            chappe_sip_uri:is_sips(chappe_sip_msg:uri(Msg))
        }
    of
        {true, _} ->
            {error, sips_unreliable_transport};
        {false, true} ->
            {ok, chappe_sip_msg:set_uri(Uri, Msg), undefined};
        {false, false} ->
            {ok, chappe_sip_msg:set_uri(<<"sip:", Rest/binary>>, Msg), Uri}
    end;
retarget(HostPort, Msg) ->
    {ok, retarget_host(HostPort, Msg), undefined}.

retarget_host(HostPort, Msg) ->
    case
        {
            chappe_sip_uri:parse(chappe_sip_msg:uri(Msg)),
            chappe_sip_uri:parse(<<"sip:", HostPort/binary>>)
        }
    of
        {{ok, U}, {ok, #{host := H} = D}} ->
            U1 = maps:remove(port, U#{host := H}),
            U2 =
                case D of
                    #{port := Port} -> U1#{port => Port};
                    _ -> U1
                end,
            chappe_sip_msg:set_uri(chappe_sip_uri:format(U2), Msg);
        _ ->
            chappe_sip_msg:set_uri(<<"sip:", HostPort/binary>>, Msg)
    end.

is_loose(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{params := #{<<"lr">> := _}}} -> true;
        _ -> false
    end.

%% proxy_request/3 asked to stay in the path (record_route, or the old
%% remain_in_dialog)
-spec record_routes(map()) -> boolean().
record_routes(Opts) ->
    maps:get(record_route, Opts, maps:get(remain_in_dialog, Opts, false)).

%% 16.6 step 4 (and RFC 5630): the Record-Route is a SIPS URI, our TLS
%% address, when the forwarded request's Request-URI or top Route is a SIPS
%% URI, and a SIP URI otherwise, also for a request that came over TLS
-spec rr_contact(chappe_sip_msg:msg(), binary() | undefined) ->
    binary() | undefined.
rr_contact(Msg, Local) ->
    Top =
        case chappe_sip_route:routes(Msg) of
            [R | _] -> chappe_sip_hdr:name_addr_uri(R);
            [] -> undefined
        end,
    Secure =
        chappe_sip_uri:is_sips(chappe_sip_msg:uri(Msg)) orelse
            chappe_sip_uri:is_sips(Top),
    case Secure andalso chappe_sip_binds:contact_or_primary(Local, true) of
        Tls when is_binary(Tls) -> Tls;
        _ -> chappe_sip_binds:contact_or_primary(Local, false)
    end.

%% a WS target goes over its flow. Otherwise the top Route is the next hop
%% when there is one: a loose router (;lr) keeps the Request-URI, a strict
%% one takes it, the Request-URI going to the end of the Route set (16.6
%% step 6). With no Route the Request-URI is the next hop, or the SIPS
%% target a SIP request goes to over TLS.
-spec next_hop(term(), binary() | undefined, chappe_sip_msg:msg()) ->
    {term(), chappe_sip_msg:msg()}.
next_hop({ws, _} = D, _Via, Msg) ->
    {D, Msg};
next_hop({flow, _Uri, Flow}, _Via, Msg) ->
    %% RFC 5626 5.3: a binding's flow is the way to reach it
    {chappe_sip_flow:flow_route(Flow), Msg};
next_hop({route, _Uri, RouteSet}, Via, Msg) ->
    %% RFC 3261 16.6 step 6: a route set toward the target goes ahead of
    %% the Route headers the request still carries
    Msg1 = chappe_sip_route:set_routes(
        RouteSet ++ chappe_sip_route:routes(Msg), Msg
    ),
    next_hop(undefined, Via, Msg1);
next_hop(_Dest, Via, Msg) ->
    case chappe_sip_route:routes(Msg) of
        [] when is_binary(Via) ->
            {Via, Msg};
        [] ->
            {chappe_sip_msg:uri(Msg), Msg};
        [Top | Rest] ->
            TopUri = chappe_sip_hdr:name_addr_uri(Top),
            case is_loose(TopUri) of
                true ->
                    {TopUri, Msg};
                false ->
                    RUri = chappe_sip_msg:uri(Msg),
                    Msg1 = chappe_sip_route:set_routes(
                        Rest ++ [<<"<", RUri/binary, ">">>],
                        chappe_sip_msg:set_uri(TopUri, Msg)
                    ),
                    {TopUri, Msg1}
            end
    end.
