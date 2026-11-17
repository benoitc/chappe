%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc How the location store's bindings are written, indexed and shown,
%% whatever the backend (chappe_sip_location): chappe_sip_registry holds
%% the registrar's rules, this module what every write and read does.
%%
%% - modify/3,5: read an AOR's bindings, apply a fun, write them back
%%   under the version read, reading again (through the leader) when
%%   another writer got in between.
%% - The flow index: the AORs that have a binding of this node on each
%%   flow, so a dropped flow purges them without reading the whole store.
%%   Its entries carry when they were made, so a read that began before a
%%   write never undoes it. The backend keeps its own held index on top
%%   (chappe_sip_location:held/5).
%% - purge_or_retry/2: drop the bindings of a flow that went, trying
%%   again every ?PURGE_RETRY_MS a purge the region could not take.
%% - live/2, to_map/2, by_q/1, send_flow/1: what a binding looks like to
%%   the registry and to its callers.
-module(chappe_sip_registry_store).

-include("chappe_sip_location.hrl").

-export([modify/3, modify/5, write/5, backoff/1, tries/0]).
-export([live/2, is_conn/1, held/4, held/5, gen/0, drop_after/2]).
-export([stamp_of/3, droppable/2, flow_aors/0, resync_apply/4]).
-export([purge_or_retry/2, retry_purge/1, clear_index/0]).
-export([to_map/2, by_q/1, send_flow/1, now_s/0]).

-define(FLOWS, chappe_sip_registry_flows).
%% a write that lost a compare-and-swap this many times in a row fails
-define(CAS_TRIES, 5).
%% a purge the region could not take is tried again this often, and at
%% most this many wait
-define(PURGE_RETRY_MS, 1000).
-define(MAX_PENDING, 10000).

%% the tries a compare-and-swap writer makes
-spec tries() -> pos_integer().
tries() ->
    ?CAS_TRIES.

%% 2, 5, 10, 20 ms before the tries after the first: under 40 ms in all.
%% None after the last try, which gives up at once.
-spec backoff(non_neg_integer()) -> ok.
backoff(1) ->
    ok;
backoff(N) ->
    timer:sleep((5 bsl (?CAS_TRIES - N)) div 2).

%% Apply Fun to an AOR's bindings and write the result, reading again when
%% another writer got in between.
-spec modify(module(), binary(), fun(([#binding{}]) -> [#binding{}])) ->
    ok | {error, term()}.
modify(Store, Aor, Fun) ->
    modify(Store, Aor, Fun, local, ?CAS_TRIES).

-spec modify(module(), binary(), fun(), local | consistent, non_neg_integer()) ->
    ok | {error, term()}.
modify(_Store, _Aor, _Fun, _Mode, 0) ->
    {error, conflict};
modify(Store, Aor, Fun, Mode, N) ->
    T0 = gen(),
    case chappe_sip_location:read(Store, Aor, Mode) of
        {ok, Bs, Version} ->
            case Fun(Bs) of
                Bs ->
                    %% nothing to write, but the index follows what the
                    %% store holds (another node may have changed it):
                    %% from a read through the leader only, never from a
                    %% replica that may lag
                    held(Store, Aor, Bs, drop_after(Mode, T0), T0);
                New ->
                    case write(Store, Aor, Version, New, T0) of
                        {error, conflict} ->
                            backoff(N),
                            modify(Store, Aor, Fun, consistent, N - 1);
                        Other ->
                            Other
                    end
            end;
        {error, _} = E ->
            E
    end.

%% Write an AOR's bindings at the version read, and index them; T0 is when
%% the read began.
-spec write(module(), binary(), non_neg_integer(), [#binding{}], integer()) ->
    ok | {error, conflict | no_quorum | too_large | full}.
write(Store, Aor, Version, Bs, T0) ->
    case chappe_sip_location:write(Store, Aor, Version, Bs) of
        ok -> held(Store, Aor, Bs, {before, T0});
        {error, _} = E -> E
    end.

%% the bindings not expired, and not bound to a connection or WS flow of
%% an earlier boot of this node (those flows are gone)
-spec live([#binding{}], integer()) -> [#binding{}].
live(Bs, Now) ->
    Boot = chappe_sip_flow:boot(),
    [B || B <- Bs, B#binding.expiry > Now, not stale_flow(B, Boot)].

stale_flow(#binding{node = N, boot = B, flow = F}, Boot) when
    N =:= node(), B =/= Boot
->
    is_conn(F) orelse is_integer(F);
stale_flow(_B, _Boot) ->
    false.

-spec is_conn(term()) -> boolean().
is_conn({conn, _}) -> true;
is_conn(_) -> false.

%% After a write or a read: index the flows of this node's bindings of
%% the AOR and, through the backend, that this node holds some. Drop is
%% {before, T0}: entries the bindings no longer have go, if made before
%% T0; keep: nothing goes (the read may lag).
%% After a write, entries are stamped now. After a read that began at T0,
%% with T0 (held/5): what the read saw was true at T0, not later, so an
%% entry it re-adds for a binding removed since does not outrank that
%% removal. An entry already stamped later keeps its stamp.
-spec held(module(), binary(), [#binding{}], {before, integer()} | keep) -> ok.
held(Store, Aor, Bs, Drop) ->
    held(Store, Aor, Bs, Drop, gen()).

-spec held(
    module(), binary(), [#binding{}], {before, integer()} | keep, integer()
) ->
    ok.
held(Store, Aor, Bs, Drop, Stamp) ->
    ok = index_flows(Aor, Bs, Drop, Stamp),
    chappe_sip_location:held(Store, Aor, Bs, Drop, Stamp).

%% the later of the stamp an entry has and Stamp
-spec stamp_of(ets:table(), term(), integer()) -> integer().
stamp_of(Tab, Key, Stamp) ->
    case ets:lookup(Tab, Key) of
        [{_, T}] when T > Stamp -> T;
        _ -> Stamp
    end.

index_flows(Aor, Bs, Drop, Stamp) ->
    Old = ets:select(?FLOWS, [{{{aor, Aor, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}]),
    New = lists:usort([
        F
     || #binding{node = N, flow = F} <- Bs,
        F =/= undefined,
        N =:= node() orelse N =:= undefined
    ]),
    _ = [
        ets:delete(?FLOWS, K)
     || {F, T} <- Old,
        not lists:member(F, New),
        droppable(T, Drop),
        K <- [{aor, Aor, F}, {flow, F, Aor}]
    ],
    true = ets:insert(
        ?FLOWS,
        [
            {K, stamp_of(?FLOWS, K, Stamp)}
         || F <- New, K <- [{aor, Aor, F}, {flow, F, Aor}]
        ]
    ),
    ok.

%% an index entry stamped T may go under Drop
-spec droppable(integer(), {before, integer()} | keep) -> boolean().
droppable(T, {before, T0}) -> T < T0;
droppable(_T, keep) -> false.

%% the AORs the flow index names
-spec flow_aors() -> [binary()].
flow_aors() ->
    ets:select(?FLOWS, [{{{aor, '$1', '_'}, '_'}, [], ['$1']}]).

%% index entries carry when they were made; a read that starts at T0 may
%% drop only entries made before it, since a write indexed after T0 may be
%% newer than what the read saw
-spec gen() -> integer().
gen() ->
    erlang:unique_integer([monotonic]).

%% what a read may drop from the index: one through the leader, what was
%% indexed before it began; one from a replica that may lag, nothing
-spec drop_after(local | consistent, integer()) -> {before, integer()} | keep.
drop_after(consistent, T0) -> {before, T0};
drop_after(local, _T0) -> keep.

%% an entry is dropped only on what the region holds, and only one made
%% before the read began (T0)
-spec resync_apply(module(), binary(), [#binding{}], integer()) -> ok.
resync_apply(Store, Aor, Bs, T0) ->
    held(Store, Aor, live(Bs, now_s()), {before, T0}, T0).

%% the flow index emptied (the store cleared)
-spec clear_index() -> ok.
clear_index() ->
    true = ets:delete_all_objects(?FLOWS),
    ok.

%% Drop the bindings of a flow that went ({flow, Flow}, or of every
%% connection: conns). Without a quorum the write cannot be made: the
%% purge is kept in S (a map: pending, retry) and tried again every
%% ?PURGE_RETRY_MS until the region takes it, so a dead flow does not
%% stay bound. At most ?MAX_PENDING purges wait; past that one is dropped,
%% logged, and its bindings expire on their own.
-spec purge_or_retry({flow, term()} | conns, map()) -> map().
purge_or_retry(What, S) ->
    case purge(keep(What)) of
        ok ->
            S;
        retry ->
            Pending = maps:get(pending, S, #{}),
            case map_size(Pending) < ?MAX_PENDING of
                true ->
                    arm_retry(S#{pending => Pending#{What => true}});
                false ->
                    logger:warning(
                        "chappe_sip_registry: purge of ~p dropped, too many waiting",
                        [What]
                    ),
                    S
            end
    end.

%% the retry timer fired: every purge waiting is tried again
-spec retry_purge(map()) -> map().
retry_purge(#{pending := Pending} = S0) ->
    S = S0#{pending := #{}, retry := undefined},
    maps:fold(fun(What, _, Acc) -> purge_or_retry(What, Acc) end, S, Pending).

%% what to keep, and the AORs to look at: the ones the flow index has
%% for that flow (or for any connection), not every AOR of the store
keep({flow, Flow}) ->
    {fun(#binding{flow = F}) -> F =/= Flow end, aors_on(Flow)};
keep(conns) ->
    {fun(#binding{flow = F}) -> not is_conn(F) end, aors_on({conn, '_'})}.

aors_on(Flow) ->
    lists:usort(ets:select(?FLOWS, [{{{flow, Flow, '$1'}, '_'}, [], ['$1']}])).

arm_retry(#{retry := TRef} = S) when TRef =/= undefined ->
    S;
arm_retry(S) ->
    S#{retry => erlang:send_after(?PURGE_RETRY_MS, self(), retry_purge)}.

%% Keep the bindings of this node that Keep accepts, deleting an AOR left
%% empty. Another node's bindings are its own to purge. retry when a write
%% could not be made for want of a quorum.
purge({Keep, Aors}) ->
    Store = chappe_sip_location:backend(),
    Mine = fun(#binding{node = N} = B) ->
        (N =/= node() andalso N =/= undefined) orelse Keep(B)
    end,
    %% through the leader: a lagging replica could miss the binding
    Results = [
        modify(
            Store,
            Aor,
            fun(Bs) -> lists:filter(Mine, Bs) end,
            consistent,
            ?CAS_TRIES
        )
     || Aor <- Aors
    ],
    case lists:member({error, no_quorum}, Results) of
        true -> retry;
        false -> ok
    end.

%% Where to send to a binding (a bindings/1 map): its flow, or, for a UDP
%% contact that is not where its REGISTER came from (a NAT in between),
%% that source; undefined: to the contact.
-spec send_flow(map()) -> chappe_sip_engine:flow() | undefined.
send_flow(#{flow := Flow}) when Flow =/= undefined ->
    Flow;
send_flow(#{contact := Contact} = B) ->
    Received = maps:get(received, B, undefined),
    case chappe_sip_flow:nated(Contact, Received) of
        true -> Received;
        false -> undefined
    end.

%% the bindings, the highest q first (a binding without q counts as 1.0;
%% equal q keep their registration order)
-spec by_q([map()]) -> [map()].
by_q(Maps) ->
    lists:sort(fun(A, B) -> q_value(A) >= q_value(B) end, Maps).

q_value(#{q := Q}) when is_binary(Q) ->
    try
        binary_to_float(Q)
    catch
        _:_ ->
            try
                float(binary_to_integer(Q))
            catch
                _:_ -> 1.0
            end
    end;
q_value(_) ->
    1.0.

%% A binding as the registry's callers see it, its expiry relative to Now.
-spec to_map(#binding{}, integer()) -> map().
to_map(
    #binding{
        contact = C,
        expiry = E,
        callid = Cid,
        cseq = Cs,
        q = Q,
        flow = F,
        path = P,
        instance = I,
        reg_id = R,
        params = Ps,
        received = Rcv,
        transport = Tr,
        node = N,
        edge = Edge
    },
    Now
) ->
    #{
        contact => C,
        expires => max(0, E - Now),
        callid => Cid,
        cseq => Cs,
        q => Q,
        flow => F,
        received => Rcv,
        transport => Tr,
        path => P,
        instance => I,
        reg_id => R,
        params => Ps,
        node => N,
        edge => Edge
    }.

-spec now_s() -> integer().
now_s() ->
    erlang:system_time(second).
