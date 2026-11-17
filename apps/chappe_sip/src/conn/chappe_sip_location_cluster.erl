%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The location store on a cluster: one value per AOR in the region's
%% KV (chappe_cluster), under `chappe_sip/aor/<AOR>'.
%%
%% - A read is the local replica: eventually consistent, which routing
%%   tolerates, and it answers while the region has no quorum. A writer
%%   whose compare-and-swap lost reads again through the leader, since the
%%   replica that misled it may still be behind.
%% - A write is a compare-and-swap on the version the read returned, so
%%   two nodes taking REGISTERs for one AOR at once never lose either:
%%   the loser reads again. It waits for the quorum at most
%%   registrar_cluster_timeout_ms.
%% - A value is the AOR's bindings as maps, so a node running a later
%%   release, with more fields, still reads them. Its size is bounded by
%%   chappe_cluster's max_value_bytes (`too_large'), and the AORs by its
%%   max_keys (`full').
%% - The sweep is a chappe_cluster singleton (chappe_sip_registry_sweep);
%%   each node keeps the index of the AORs it holds bindings of, and
%%   resyncs it against the region every registrar_sweep_ms.
%% - A binding another node holds is shown without its flow, behind the
%%   edge route to that node (RFC 5626 5.3).
-module(chappe_sip_location_cluster).
-behaviour(chappe_sip_location).

-include("chappe_sip_location.hrl").

-export([read/2, write/3, aors/0, clear/0]).
-export([write_mode/0, start/0, stop/0, periodic/2, held/4, mine/0]).
-export([view/2, edge/1]).
-export([resync/1, resync_reads/4]).

-define(PREFIX, <<"chappe_sip/aor/">>).
-define(HELD, chappe_sip_registry_held).
%% the resync pauses this long every this many reads
-define(RESYNC_BATCH, 50).
-define(RESYNC_PAUSE_MS, 20).
%% an edge route stays valid this long past its binding's expiry, for a
%% request already on its way
-define(EDGE_GRACE_S, 32).

read(Aor, local) ->
    result_of(chappe_cluster:get(key(Aor)));
read(Aor, consistent) ->
    result_of(chappe_cluster:get(key(Aor), consistent)).

result_of(Got) ->
    case Got of
        {ok, Maps, Version} when is_list(Maps) ->
            {ok, [from_map(M) || M <- Maps, is_map(M)], Version};
        not_found ->
            {ok, [], 0};
        {error, _} ->
            {error, no_quorum}
    end.

write(_Aor, 0, []) ->
    ok;
write(Aor, Version, []) ->
    result(
        chappe_cluster:delete(key(Aor), #{
            version => Version, timeout => timeout()
        })
    );
write(Aor, Version, Bs) ->
    result(
        chappe_cluster:cas(
            key(Aor), Version, [to_map(B) || B <- Bs], #{timeout => timeout()}
        )
    ).

%% Every AOR, a page of keys at a time.
aors() ->
    aors(#{}, []).

aors(Opts, Acc) ->
    N = byte_size(?PREFIX),
    case chappe_cluster:keys(?PREFIX, Opts) of
        {ok, Keys, Next} ->
            Aors = [Aor || <<_:N/binary, Aor/binary>> <- Keys],
            more(Next, [Aors | Acc]);
        {error, _} ->
            lists:append(lists:reverse(Acc))
    end.

more(done, Acc) -> lists:append(lists:reverse(Acc));
more({more, Cursor}, Acc) -> aors(#{cursor => Cursor}, Acc).

clear() ->
    lists:foreach(fun(Aor) -> chappe_cluster:delete(key(Aor)) end, aors()).

result(ok) -> ok;
result({ok, _Version}) -> ok;
result({error, {version, _}}) -> {error, conflict};
result({error, max_keys}) -> {error, full};
result({error, too_large}) -> {error, too_large};
result({error, _}) -> {error, no_quorum}.

key(Aor) ->
    <<?PREFIX/binary, Aor/binary>>.

timeout() ->
    chappe_sip_config:get(registrar_cluster_timeout_ms).

to_map(B) ->
    maps:from_list(
        lists:zip(record_info(fields, binding), tl(tuple_to_list(B)))
    ).

%% a field the writer did not know takes its default
from_map(M) ->
    Default = tl(tuple_to_list(#binding{contact = <<>>, expiry = 0, cseq = 0})),
    list_to_tuple([
        binding
        | [
            maps:get(F, M, D)
         || {F, D} <- lists:zip(record_info(fields, binding), Default)
        ]
    ]).

%% ---- how the registry runs on the region ----

write_mode() ->
    cas.

%% The sweep is one singleton for the region. chappe_sip_app starts
%% chappe_cluster before the registry (and refuses to start without it);
%% it is ensured again here, for a registry restarted after chappe_cluster
%% stopped. One that fails to start is logged, and the sweep is left to
%% the other nodes, rather than crash-looping the registry's supervisor.
start() ->
    case application:ensure_all_started(chappe_cluster) of
        {ok, _} ->
            case
                chappe_cluster:singleton(
                    chappe_sip_registry_sweep:name(),
                    chappe_sip_registry_sweep:child_spec()
                )
            of
                ok -> ok;
                {error, already_started} -> ok;
                {error, Why} -> no_sweep(Why)
            end;
        {error, Why} ->
            no_sweep(Why)
    end.

no_sweep(Why) ->
    logger:error(
        "chappe_sip_registry: cluster => chappe_cluster, but chappe_cluster "
        "did not start (~p): this node does not sweep the location store",
        [Why]
    ).

%% Stop contending for the sweep from this node (the app stops).
stop() ->
    try chappe_cluster:stop_singleton(chappe_sip_registry_sweep:name()) of
        _ -> ok
    catch
        %% chappe_cluster stopped first
        exit:_ -> ok
    end.

%% Other nodes change the AORs this node indexes: the sweep deletes an
%% expired binding, a device registers again through another node. Every
%% registrar_sweep_ms each indexed AOR is read again and its index entries
%% follow its live bindings, so the index holds only what this node still
%% has. It visits this node's own entries, not the region.
%%
%% The reads go through the leader, so they run in a helper, not in the
%% registry: a dropped flow is purged at once whatever the region does.
%% The helper reads the AORs one after another, a pause every
%% ?RESYNC_BATCH, stops at the first that finds no quorum, and sends each
%% read to the registry ({resync_read, ...}), where the index decision is
%% made (chappe_sip_registry_store:resync_apply/4). One pass at a time: a
%% tick that finds one still running starts none.
periodic(_Registry, Job) when is_reference(Job) ->
    Job;
periodic(Registry, undefined) ->
    Aors = indexed_aors(),
    {_Pid, Ref} = spawn_monitor(fun() ->
        resync_reads(?MODULE, Aors, Registry, 0)
    end),
    Ref.

indexed_aors() ->
    lists:usort(
        chappe_sip_registry_store:flow_aors() ++
            [A || {A, _} <- ets:tab2list(?HELD)]
    ).

%% the reads of a resync pass, from Store, sent to Owner
-spec resync_reads(module(), [binary()], pid(), non_neg_integer()) -> ok.
resync_reads(_Store, [], _Owner, _N) ->
    ok;
resync_reads(Store, [Aor | Rest], Owner, N) ->
    _ =
        N > 0 andalso N rem ?RESYNC_BATCH =:= 0 andalso
            timer:sleep(?RESYNC_PAUSE_MS),
    T0 = chappe_sip_registry_store:gen(),
    %% the pass ends with the registry that asked for it: a restarted
    %% registry starts its own
    case
        is_process_alive(Owner) andalso
            chappe_sip_location:read(Store, Aor, consistent)
    of
        false ->
            ok;
        {ok, Bs, _} ->
            Owner ! {resync_read, Aor, Bs, T0},
            resync_reads(Store, Rest, Owner, N + 1);
        {error, _} ->
            %% no quorum: the rest would wait as long; the next pass tries
            ok
    end.

%% a whole pass of Store's index in the caller
-spec resync(module()) -> ok.
resync(Store) ->
    lists:foreach(
        fun(Aor) ->
            T0 = chappe_sip_registry_store:gen(),
            case chappe_sip_location:read(Store, Aor, consistent) of
                {ok, Bs, _} ->
                    chappe_sip_registry_store:resync_apply(Store, Aor, Bs, T0);
                {error, _} ->
                    ok
            end
        end,
        indexed_aors()
    ).

%% The held index: the AORs this node took a binding of, so it keeps
%% alive and purges those without reading the region. An entry carries
%% when it was made, as the flow index's do: a read that began before it
%% does not remove it.
held(Aor, Bs, Drop, Stamp) ->
    _ =
        case
            {lists:any(fun(#binding{node = N}) -> N =:= node() end, Bs), Drop}
        of
            {true, _} ->
                ets:insert(
                    ?HELD,
                    {Aor, chappe_sip_registry_store:stamp_of(?HELD, Aor, Stamp)}
                );
            {false, {before, T0}} ->
                ets:select_delete(?HELD, [
                    {{Aor, '$1'}, [{'<', '$1', T0}], [true]}
                ]);
            {false, keep} ->
                true
        end,
    ok.

%% the ones this node wrote one for (an index, so a dropped connection
%% does not read the whole region)
mine() ->
    [Aor || {Aor, _} <- ets:tab2list(?HELD)].

%% How a binding looks from this node. Ours as stored. One another node
%% holds: no flow or received (they name that node's connections) and its
%% edge route ahead of its path; when that node is gone, a UDP one is
%% reached at its address, any other is left out.
view(#binding{node = N} = B, Now) when N =:= node(); N =:= undefined ->
    [chappe_sip_registry_store:to_map(B, Now)];
view(#binding{edge = undefined} = B, Now) ->
    [
        (chappe_sip_registry_store:to_map(B, Now))#{
            flow => undefined, received => undefined
        }
    ];
view(#binding{node = N, edge = Edge, path = Path} = B, Now) ->
    Up = [node() | nodes()],
    Map = chappe_sip_registry_store:to_map(B, Now),
    M = Map#{flow => undefined, received => undefined},
    case {lists:member(N, Up), chappe_sip_registry_store:send_flow(Map)} of
        {true, _} -> [M#{path => [Edge | Path]}];
        {false, {udp, Ip, Port}} -> [M#{flow => {udp, Ip, Port}}];
        {false, {udp, Ip, Port, _}} -> [M#{flow => {udp, Ip, Port}}];
        {false, _} -> []
    end.

%% A binding this node reaches over its own flow (an RFC 5626 flow, a WS
%% connection, a UDP source behind a NAT) gets the route other nodes reach
%% it through (RFC 5626 5.3). A binding behind a Path is reached through
%% that Path from anywhere; any other contact directly.
edge(#binding{path = [_ | _]} = B) ->
    B;
edge(B) ->
    B#binding{edge = edge_route(B)}.

edge_route(#binding{expiry = Exp} = B) ->
    case
        chappe_sip_registry_store:send_flow(
            chappe_sip_registry_store:to_map(B, 0)
        )
    of
        undefined ->
            undefined;
        Flow ->
            case chappe_sip_binds:contact_or_primary(local(Flow), false) of
                Uri when is_binary(Uri) ->
                    chappe_sip_flow:edge_route(
                        Uri, Flow, edge_transport(Flow, B), Exp + ?EDGE_GRACE_S
                    );
                _ ->
                    undefined
            end
    end.

local({udp, _, _, Local}) -> Local;
local(_Flow) -> undefined.

edge_transport(Flow, _B) when is_integer(Flow) -> <<"ws">>;
edge_transport(_Flow, #binding{transport = T}) when is_binary(T) -> T;
edge_transport(_Flow, _B) -> <<"udp">>.
