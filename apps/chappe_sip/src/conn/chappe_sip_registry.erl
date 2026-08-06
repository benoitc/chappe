%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Registrar location store.
%%
%% A persistent map from AOR to contact bindings, so a REGISTER handler is
%% a few lines and UAS/proxy apps can resolve an AOR to its current
%% contacts. It lives under chappe_sip_sup (above the stack supervisor) so its
%% ETS survives SIP engine restarts.
%%
%% Mutations (register/remove/sweep) are serialized through this
%% gen_server; lookups read the public ETS directly and filter expired
%% bindings at read time. Binding semantics follow RFC 3261 section 10.3:
%% per-contact or header Expires, expires=0 removes a contact,
%% Contact: * with Expires: 0 clears the AOR, and a lower CSeq on the
%% same Call-ID is rejected as a reorder.
-module(chappe_sip_registry).
-behaviour(gen_server).

-export([start_link/0]).
-export([
    register_contacts/2,
    lookup/1,
    bindings/1,
    remove/1,
    remove_flow/1,
    clear/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TAB, ?MODULE).
-define(SWEEP_INTERVAL_MS, 30000).

-record(binding, {
    contact :: binary(),
    % absolute epoch seconds
    expiry :: non_neg_integer(),
    callid :: binary() | undefined,
    cseq :: non_neg_integer(),
    q :: binary() | undefined,
    % transport flow (WS conn), undefined otherwise
    flow :: term()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Apply a REGISTER request to the store. Opts: #{flow => term(),
%% default_expires => pos_integer()}. Returns the AOR's live bindings for
%% the 200 response, or {error, Status} to reject.
-spec register_contacts(chappe_sip_req:req(), map()) ->
    {ok, [map()]} | {error, 100..699}.
register_contacts(Req, Opts) ->
    gen_server:call(?MODULE, {register, Req, Opts}).

%% Live contact URIs for an AOR (or a To/Contact header value / URI).
-spec lookup(binary()) -> [binary()].
lookup(AorOrUri) ->
    [maps:get(contact, B) || B <- bindings(AorOrUri)].

%% Live bindings for an AOR as maps #{contact, expires, callid, cseq, q, flow}.
-spec bindings(binary()) -> [map()].
bindings(AorOrUri) ->
    Aor = aor_key(AorOrUri),
    Now = now_s(),
    case ets:lookup(?TAB, Aor) of
        [{Aor, Bs}] -> [to_map(B, Now) || B <- Bs, B#binding.expiry > Now];
        [] -> []
    end.

%% Drop all bindings for an AOR.
-spec remove(binary()) -> ok.
remove(AorOrUri) ->
    gen_server:call(?MODULE, {remove, aor_key(AorOrUri)}).

%% Drop every binding learned on a transport flow. A WS UA is reachable only
%% over its flow (RFC 5626), so when the flow drops the binding is dead; the
%% WS transport calls this on disconnect. undefined (UDP) is a no-op.
-spec remove_flow(term()) -> ok.
remove_flow(undefined) ->
    ok;
remove_flow(Flow) ->
    gen_server:cast(?MODULE, {remove_flow, Flow}).

%% Drop the whole store (tests, reconfiguration).
-spec clear() -> ok.
clear() ->
    gen_server:call(?MODULE, clear).

%% gen_server

init([]) ->
    %% the table is owned by chappe_sip_registry_keeper (started first) so it
    %% survives a crash of this gen_server; create it only as a fallback
    _ =
        case ets:info(?TAB) of
            undefined ->
                ets:new(?TAB, [
                    named_table,
                    set,
                    public,
                    {read_concurrency, true}
                ]);
            _ ->
                ?TAB
        end,
    {ok, schedule_sweep(#{})}.

handle_call({register, Req, Opts}, _From, S) ->
    {reply, do_register(Req, Opts), S};
handle_call({remove, Aor}, _From, S) ->
    ets:delete(?TAB, Aor),
    {reply, ok, S};
handle_call(clear, _From, S) ->
    ets:delete_all_objects(?TAB),
    {reply, ok, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({remove_flow, Flow}, S) ->
    purge_flow(Flow),
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    sweep(now_s()),
    {noreply, schedule_sweep(S)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%% internal

do_register(Req, Opts) ->
    Msg = chappe_sip_req:msg(Req),
    Aor = aor_key(chappe_sip_msg:get(<<"to">>, Msg)),
    CallId = chappe_sip_msg:call_id(Msg),
    CSeq =
        case chappe_sip_msg:cseq(Msg) of
            {ok, #{seq := N}} -> N;
            _ -> 0
        end,
    HdrExpires = header_expires(Msg, Opts),
    Flow = maps:get(flow, Opts, undefined),
    Contacts = chappe_sip_msg:get_all(<<"contact">>, Msg),
    Now = now_s(),
    Existing = live(Aor, Now),
    case reorder(Existing, CallId, CSeq) of
        true ->
            {error, 400};
        false ->
            case Contacts of
                [] ->
                    %% a query: return current bindings unchanged
                    {ok, [to_map(B, Now) || B <- Existing]};
                [<<"*">>] when HdrExpires =:= 0 ->
                    ets:delete(?TAB, Aor),
                    {ok, []};
                [<<"*">>] ->
                    {error, 400};
                _ ->
                    apply_contacts(
                        Aor,
                        Contacts,
                        HdrExpires,
                        CallId,
                        CSeq,
                        Flow,
                        Existing,
                        Now
                    )
            end
    end.

apply_contacts(Aor, Contacts, HdrExpires, CallId, CSeq, Flow, Existing, Now) ->
    Max = chappe_sip_config:get(registrar_max_expires),
    NewAor = not ets:member(?TAB, Aor),
    %% RFC 3261 10.3 step 5: a malformed Contact makes the REGISTER a 400
    %% rather than silently dropping that contact and confirming the rest
    case lists:all(fun parses/1, Contacts) of
        false ->
            {error, 400};
        true ->
            case below_min(Contacts, HdrExpires) of
                % RFC 3261 10.3 step 7
                true ->
                    {error, 423};
                false ->
                    write_contacts(
                        Aor,
                        Contacts,
                        HdrExpires,
                        CallId,
                        CSeq,
                        Flow,
                        Existing,
                        Now,
                        Max,
                        NewAor
                    )
            end
    end.

write_contacts(
    Aor,
    Contacts,
    HdrExpires,
    CallId,
    CSeq,
    Flow,
    Existing,
    Now,
    Max,
    NewAor
) ->
    Updated =
        lists:foldl(
            fun(Raw, Acc) ->
                {ok, #{uri := Uri, params := P}} = chappe_sip_hdr:name_addr(
                    Raw
                ),
                Exp = clamp(contact_expires(P, HdrExpires), Max),
                Q = maps:get(<<"q">>, P, undefined),
                case Exp of
                    0 ->
                        lists:keydelete(Uri, #binding.contact, Acc);
                    _ ->
                        B = #binding{
                            contact = Uri,
                            expiry = Now + Exp,
                            callid = CallId,
                            cseq = CSeq,
                            q = Q,
                            flow = Flow
                        },
                        lists:keystore(Uri, #binding.contact, Acc, B)
                end
            end,
            Existing,
            Contacts
        ),
    commit(Aor, Updated, NewAor, Now).

%% RFC 3261 10.3 step 7: true if any contact requests a non-zero expiry below
%% the configured floor. A floor of 0 disables the check.
below_min(Contacts, HdrExpires) ->
    case chappe_sip_config:get(registrar_min_expires) of
        Min when Min =< 0 ->
            false;
        Min ->
            lists:any(
                fun(Raw) ->
                    case chappe_sip_hdr:name_addr(Raw) of
                        {ok, #{params := P}} ->
                            E = contact_expires(P, HdrExpires),
                            E > 0 andalso E < Min;
                        _ ->
                            false
                    end
                end,
                Contacts
            )
    end.

parses(Raw) ->
    case chappe_sip_hdr:name_addr(Raw) of
        {ok, #{uri := Uri}} ->
            %% name_addr accepts a bare token as a URI; require an actual URI
            case chappe_sip_uri:parse(Uri) of
                {ok, _} -> true;
                _ -> false
            end;
        _ ->
            false
    end.

%% Enforce the store bounds before writing: 403 when one AOR would hold too
%% many contacts, 503 when a new AOR would exceed the distinct-AOR cap.
commit(Aor, Updated, NewAor, Now) ->
    MaxPerAor = chappe_sip_config:get(registrar_max_bindings_per_aor),
    case length(Updated) > MaxPerAor of
        true ->
            {error, 403};
        false ->
            commit_1(Aor, Updated, NewAor, Now)
    end.

commit_1(Aor, Updated, NewAor, Now) ->
    MaxAors = chappe_sip_config:get(registrar_max_aors),
    NewAtCap =
        NewAor andalso Updated =/= [] andalso
            ets:info(?TAB, size) >= MaxAors,
    case NewAtCap of
        true ->
            {error, 503};
        false ->
            case Updated of
                [] -> ets:delete(?TAB, Aor);
                _ -> ets:insert(?TAB, {Aor, Updated})
            end,
            {ok, [to_map(B, Now) || B <- Updated]}
    end.

%% a REGISTER refresh with the same Call-ID but a non-greater CSeq is a
%% reorder and must be rejected (RFC 3261 10.3 step 6)
reorder(Existing, CallId, CSeq) when CallId =/= undefined ->
    lists:any(
        fun(#binding{callid = C, cseq = Prev}) ->
            C =:= CallId andalso CSeq =< Prev
        end,
        Existing
    );
reorder(_Existing, _CallId, _CSeq) ->
    false.

live(Aor, Now) ->
    case ets:lookup(?TAB, Aor) of
        [{Aor, Bs}] -> [B || B <- Bs, B#binding.expiry > Now];
        [] -> []
    end.

sweep(Now) ->
    %% collect changes first; do not mutate the table during the fold
    Changes =
        ets:foldl(
            fun({Aor, Bs}, Acc) ->
                case [B || B <- Bs, B#binding.expiry > Now] of
                    % unchanged
                    Bs -> Acc;
                    [] -> [{delete, Aor} | Acc];
                    Live -> [{update, Aor, Live} | Acc]
                end
            end,
            [],
            ?TAB
        ),
    lists:foreach(
        fun
            ({delete, Aor}) -> ets:delete(?TAB, Aor);
            ({update, Aor, Live}) -> ets:insert(?TAB, {Aor, Live})
        end,
        Changes
    ),
    ok.

%% Remove every binding whose flow matches, deleting an AOR left empty.
purge_flow(Flow) ->
    Changes =
        ets:foldl(
            fun({Aor, Bs}, Acc) ->
                case [B || B <- Bs, B#binding.flow =/= Flow] of
                    % unchanged
                    Bs -> Acc;
                    [] -> [{delete, Aor} | Acc];
                    Kept -> [{update, Aor, Kept} | Acc]
                end
            end,
            [],
            ?TAB
        ),
    lists:foreach(
        fun
            ({delete, Aor}) -> ets:delete(?TAB, Aor);
            ({update, Aor, Kept}) -> ets:insert(?TAB, {Aor, Kept})
        end,
        Changes
    ),
    ok.

schedule_sweep(S) ->
    TRef = erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    S#{sweep => TRef}.

header_expires(Msg, Opts) ->
    Default = maps:get(
        default_expires,
        Opts,
        chappe_sip_config:get(registrar_default_expires)
    ),
    case chappe_sip_msg:get(<<"expires">>, Msg) of
        undefined ->
            Default;
        V ->
            try
                binary_to_integer(V)
            catch
                _:_ -> Default
            end
    end.

contact_expires(Params, HdrExpires) ->
    case maps:get(<<"expires">>, Params, undefined) of
        undefined ->
            HdrExpires;
        V ->
            try
                binary_to_integer(V)
            catch
                _:_ -> HdrExpires
            end
    end.

clamp(N, _Max) when N =< 0 -> 0;
clamp(N, Max) when is_integer(Max), N > Max -> Max;
clamp(N, _Max) -> N.

to_map(
    #binding{
        contact = C,
        expiry = E,
        callid = Cid,
        cseq = Cs,
        q = Q,
        flow = F
    },
    Now
) ->
    #{
        contact => C,
        expires => max(0, E - Now),
        callid => Cid,
        cseq => Cs,
        q => Q,
        flow => F
    }.

%% AOR key: scheme:user@host (port and params dropped) from a To/Contact
%% header value or a bare URI.
aor_key(undefined) ->
    <<>>;
aor_key(Value) ->
    Uri =
        case chappe_sip_hdr:name_addr(Value) of
            {ok, #{uri := U}} -> U;
            _ -> Value
        end,
    case chappe_sip_uri:parse(Uri) of
        {ok, P} ->
            Scheme = atom_to_binary(maps:get(scheme, P, sip), utf8),
            Host = maps:get(host, P, <<>>),
            case maps:get(user, P, undefined) of
                undefined -> <<Scheme/binary, ":", Host/binary>>;
                User -> <<Scheme/binary, ":", User/binary, "@", Host/binary>>
            end;
        _ ->
            Uri
    end.

now_s() ->
    erlang:system_time(second).
