%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% One node's contender for one singleton, under chappe_cluster_singleton_sup.
%% Every renew_ms until it wins, it claims the lease `{chappe_cluster_singleton,
%% Name}' for itself. Once it holds it, it starts the child under a
%% supervisor linked to it and joins the child to the pg group
%% `{chappe_cluster_singleton, Name}' in the `chappe_cluster' scope. On
%% `lost', or when the child stops, it stops the child, gives the lease
%% back and contends again.
%%
%% Fenced side effects: fence/1 returns the lease's fence while this node
%% runs the child, for the child to carry on what it writes.
-module(chappe_cluster_singleton).
-behaviour(gen_server).

-export([start_link/2, fence/1, group/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    name :: term(),
    spec :: supervisor:child_spec(),
    lease :: undefined | map(),
    sup :: undefined | pid(),
    child :: undefined | {pid(), reference()}
}).

-type state() :: #state{}.

-spec start_link(term(), supervisor:child_spec()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, Spec) ->
    gen_server:start_link(?MODULE, {Name, Spec}, []).

%% The fence of the running singleton, from its contender.
-spec fence(pid()) -> {ok, chappe_cluster:fence()} | none.
fence(Contender) ->
    gen_server:call(Contender, fence).

-spec group(term()) -> {chappe_cluster_singleton, term()}.
group(Name) ->
    {chappe_cluster_singleton, Name}.

-spec init(term()) -> {ok, state()}.
init({Name, Spec}) ->
    process_flag(trap_exit, true),
    self() ! contend,
    {ok, #state{name = Name, spec = Spec}}.

handle_call(fence, _From, St = #state{lease = undefined}) ->
    {reply, none, St};
handle_call(fence, _From, St = #state{lease = Lease}) ->
    {reply, {ok, chappe_cluster:fence(Lease)}, St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info(contend, St = #state{lease = undefined, name = Name}) ->
    case chappe_cluster:claim(key(Name), #{}) of
        {ok, Lease} -> {noreply, run(Lease, St)};
        {error, _} -> {noreply, retry(St)}
    end;
handle_info(contend, St) ->
    {noreply, St};
handle_info(
    {chappe_cluster, #{seq := Seq}, lost}, St = #state{lease = #{seq := Seq}}
) ->
    {noreply, retry(stop_child(St#state{lease = undefined}))};
handle_info({chappe_cluster, _OldLease, lost}, St) ->
    {noreply, St};
handle_info({'DOWN', Ref, process, _, _}, St = #state{child = {_, Ref}}) ->
    {noreply, retry(give_back(stop_child(St#state{child = undefined})))};
handle_info({'EXIT', Sup, _}, St = #state{sup = Sup}) ->
    {noreply, retry(give_back(stop_child(St#state{sup = undefined})))};
handle_info({'EXIT', _, _}, St) ->
    {noreply, St};
handle_info(Msg, St) ->
    logger:notice("chappe_cluster_singleton: unexpected ~0p", [Msg]),
    {noreply, St}.

terminate(_Reason, St) ->
    _ = give_back(stop_child(St)),
    ok.

%% ---- internals ----

key(Name) ->
    {chappe_cluster_singleton, Name}.

run(Lease, St = #state{spec = Spec, name = Name}) ->
    case chappe_cluster_singleton_sup:start_child_sup(Spec) of
        {ok, Sup} ->
            case supervisor:which_children(Sup) of
                [{_, Pid, _, _}] when is_pid(Pid) ->
                    ok = pg:join(chappe_cluster, group(Name), Pid),
                    Ref = erlang:monitor(process, Pid),
                    St#state{lease = Lease, sup = Sup, child = {Pid, Ref}};
                _ ->
                    retry(
                        give_back(
                            stop_child(St#state{lease = Lease, sup = Sup})
                        )
                    )
            end;
        {error, Reason} ->
            logger:warning(
                "chappe_cluster_singleton ~0p: child failed to start: ~0p",
                [Name, Reason]
            ),
            retry(give_back(St#state{lease = Lease}))
    end.

stop_child(St = #state{sup = undefined, child = undefined}) ->
    St;
stop_child(St = #state{sup = Sup, child = Child}) ->
    case Child of
        {_, Ref} -> erlang:demonitor(Ref, [flush]);
        undefined -> ok
    end,
    case Sup of
        undefined ->
            ok;
        _ ->
            unlink(Sup),
            Mon = erlang:monitor(process, Sup),
            exit(Sup, shutdown),
            receive
                {'DOWN', Mon, process, Sup, _} -> ok
            after 5000 ->
                exit(Sup, kill),
                receive
                    {'DOWN', Mon, process, Sup, _} -> ok
                after 5000 -> ok
                end
            end,
            receive
                {'EXIT', Sup, _} -> ok
            after 0 -> ok
            end
    end,
    St#state{sup = undefined, child = undefined}.

give_back(St = #state{lease = undefined}) ->
    St;
give_back(St = #state{lease = Lease}) ->
    _ = chappe_cluster:release(Lease),
    St#state{lease = undefined}.

retry(St) ->
    erlang:send_after(chappe_cluster_config:get(renew_ms), self(), contend),
    St.
