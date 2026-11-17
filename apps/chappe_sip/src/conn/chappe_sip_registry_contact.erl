%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The Contacts of a REGISTER and how they update an AOR's bindings,
%% for chappe_sip_registry: RFC 3261 10.3 step 7 (each Contact with its
%% expiry, the floor, the CSeq check, 19.1.4 URI equality) and RFC 5626 6
%% (a binding per +sip.instance and reg-id, tied to its flow).
-module(chappe_sip_registry_contact).

-include("chappe_sip_location.hrl").

-export([contacts/5, below_min/1, update/5]).

-export_type([contact/0]).

%% a Contact of the REGISTER: its URI, requested expiry and identity
-record(contact, {
    uri :: binary(),
    expires :: integer(),
    q :: binary() | undefined,
    instance :: binary() | undefined,
    reg_id :: binary() | undefined,
    params :: map()
}).

-opaque contact() :: #contact{}.

%% The Contacts of the request, each with its requested expiry, and
%% whether an outbound flow was registered for a UA that supports it
%% (RFC 5626 6). Info carries the request's path and first_hop.
-spec contacts([map()], chappe_sip_msg:msg(), map(), map(), [binary()]) ->
    {ok, [contact()], boolean()} | {error, 400 | 439}.
contacts(Values, Msg, Opts, Info, Supported) ->
    case parse(Values, Msg, Opts) of
        {ok, Contacts} -> outbound(Contacts, Info, Supported);
        {error, _} = E -> E
    end.

%% step 7: each Contact with its requested expiry; a Contact that is not a
%% URI makes the REGISTER a 400 rather than being silently dropped
parse(Entries, Msg, Opts) ->
    HdrExpires = header_expires(Msg, Opts),
    case lists:all(fun parses/1, Entries) of
        false ->
            {error, 400};
        true ->
            {ok, [
                #contact{
                    uri = Uri,
                    expires = contact_expires(P, HdrExpires),
                    q = param(<<"q">>, P),
                    instance = param(<<"+sip.instance">>, P),
                    reg_id = param(<<"reg-id">>, P),
                    params = P
                }
             || #{uri := Uri, params := P} <- Entries
            ]}
    end.

param(K, P) ->
    case maps:get(K, P, undefined) of
        V when is_binary(V) -> V;
        _ -> undefined
    end.

parses(#{uri := Uri}) ->
    %% name_addr accepts a bare token as a URI; require an actual URI
    case chappe_sip_uri:parse(Uri) of
        {ok, _} -> true;
        _ -> false
    end.

header_expires(Msg, Opts) ->
    Default = maps:get(
        default_expires,
        Opts,
        chappe_sip_config:get(registrar_default_expires)
    ),
    case chappe_sip_msg:get(<<"expires">>, Msg) of
        undefined -> Default;
        V -> chappe_sip_lib:to_int(V, Default)
    end.

contact_expires(Params, HdrExpires) ->
    case maps:get(<<"expires">>, Params, undefined) of
        V when is_binary(V) -> chappe_sip_lib:to_int(V, HdrExpires);
        _ -> HdrExpires
    end.

%% RFC 5626 6. A reg-id counts only beside a +sip.instance and when we are
%% the first hop or the first Path URI carries "ob"; otherwise it is
%% ignored, or a 439 when the UA asked for outbound. A reg-id with more
%% than one Contact of non-zero expiry is a 400. The flag is true when a
%% flow was registered for a UA that lists outbound in Supported.
outbound(Contacts0, #{path := Path, first_hop := FirstHop}, Supported) ->
    ObOk = FirstHop orelse first_ob(Path),
    WantsOb = lists:member(<<"outbound">>, Supported),
    Contacts = [no_lone_reg_id(C) || C <- Contacts0],
    HasRegId = lists:any(
        fun(#contact{reg_id = R}) -> R =/= undefined end, Contacts
    ),
    NonZero = [C || #contact{expires = E} = C <- Contacts, E =/= 0],
    case {HasRegId, ObOk, NonZero} of
        {true, false, _} when WantsOb ->
            {error, 439};
        {Reg, Ok, _} when not Reg; not Ok ->
            {ok, [C#contact{reg_id = undefined} || C <- Contacts], false};
        {_, _, [_, _ | _]} ->
            {error, 400};
        _ ->
            {ok, Contacts, WantsOb}
    end.

no_lone_reg_id(#contact{instance = undefined} = C) ->
    C#contact{reg_id = undefined};
no_lone_reg_id(C) ->
    C.

first_ob([First | _]) ->
    case chappe_sip_hdr:name_addr(First) of
        {ok, #{uri := U}} ->
            case chappe_sip_uri:parse(U) of
                {ok, #{params := P}} -> maps:is_key(<<"ob">>, P);
                _ -> false
            end;
        _ ->
            false
    end;
first_ob([]) ->
    false.

%% RFC 3261 10.3 step 7: true if a contact asks for an expiry above zero,
%% under an hour and below the configured floor. A floor of 0 disables it.
-spec below_min([contact()]) -> boolean().
below_min(Contacts) ->
    case chappe_sip_config:get(registrar_min_expires) of
        Min when Min =< 0 ->
            false;
        Min ->
            lists:any(
                fun(#contact{expires = E}) ->
                    E > 0 andalso E < 3600 andalso E < Min
                end,
                Contacts
            )
    end.

%% Each contact in turn against the bindings Bs: the same binding is the
%% one with the same instance and reg-id for a flow, else the one whose
%% URI is equal (19.1.4). On another Call-ID it is replaced (or removed
%% with expiry 0); on the same Call-ID only when the CSeq is higher,
%% otherwise the whole request fails and nothing is written. Template is
%% the binding every new one starts from, ObFlow the flow an outbound
%% binding is tied to, Store the backend that stores the new bindings.
-spec update(
    [contact()], #binding{}, term(), [#binding{}], module()
) -> {ok, [#binding{}]} | {error, 400}.
update(Contacts, Template, ObFlow, Bs, Store) ->
    Max = chappe_sip_config:get(registrar_max_expires),
    update(Contacts, Template, Max, ObFlow, Store, Bs).

update([], _T, _Max, _ObFlow, _Store, Acc) ->
    {ok, Acc};
update([C | Rest], T, Max, ObFlow, Store, Acc) ->
    Match = [B || B <- Acc, same_binding(C, B)],
    Reordered = [
        B
     || #binding{callid = Cid, cseq = Prev} = B <- Match,
        Cid =:= T#binding.callid,
        T#binding.cseq =< Prev
    ],
    case {Reordered, clamp(C#contact.expires, Max)} of
        {[_ | _], _} ->
            {error, 400};
        {[], 0} ->
            update(Rest, T, Max, ObFlow, Store, Acc -- Match);
        {[], Exp} ->
            B = T#binding{
                contact = C#contact.uri,
                expiry = T#binding.expiry + Exp,
                q = C#contact.q,
                instance = C#contact.instance,
                reg_id = C#contact.reg_id,
                params = C#contact.params,
                flow = binding_flow(C, T, ObFlow)
            },
            New = chappe_sip_location:edge(Store, B),
            update(Rest, T, Max, ObFlow, Store, replace(Match, New, Acc))
    end.

clamp(N, _Max) when N =< 0 -> 0;
clamp(N, Max) when is_integer(Max), N > Max -> Max;
clamp(N, _Max) -> N.

%% an outbound binding (a reg-id kept by outbound/3) on a direct flow is
%% tied to that flow; a re-registration over another one moves it there
%% (RFC 5626 6)
binding_flow(#contact{reg_id = R}, _T, ObFlow) when
    R =/= undefined, ObFlow =/= undefined
->
    ObFlow;
binding_flow(_C, #binding{flow = F}, _ObFlow) ->
    F.

%% a refreshed binding keeps its place, so equal-q order stays stable
replace([], B, Acc) ->
    Acc ++ [B];
replace([Old | Dups], B, Acc) ->
    [
        case X of
            Old -> B;
            _ -> X
        end
     || X <- Acc -- Dups
    ].

same_binding(#contact{reg_id = R, instance = I}, #binding{
    reg_id = R, instance = I
}) when
    R =/= undefined
->
    true;
same_binding(#contact{reg_id = R}, _B) when R =/= undefined ->
    false;
same_binding(_C, #binding{reg_id = R}) when R =/= undefined ->
    false;
same_binding(#contact{uri = U}, #binding{contact = BU}) ->
    chappe_sip_uri:equal(U, BU).
