%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The lab's singleton child, run by chappe_cluster:singleton/2 on one node
%% of the region. It logs its side effects on the key `{singleton, Name}':
%% claim_ok with the singleton's fence once it runs, fence_used every beat,
%% and, when it is stopped, more fence_used for stop_ms (longer than
%% renew_ms / 2, a child that is slow to stop) before its release. Before
%% each side effect it asks chappe_cluster:singleton_valid/1, when the app
%% exports it, and logs lost and stops acting on false. Two children running
%% at once show up in the checker as an overlap.
-module(chappe_cluster_lab_single).
-behaviour(gen_server).

-export([start_link/2, spec/2]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).
-export([handle_info/2, terminate/2]).

%% @doc The child spec to give chappe_cluster:singleton/2.
-spec spec(term(), map()) -> supervisor:child_spec().
spec(Name, #{stop_ms := Stop} = Opts) ->
    #{
        id => Name,
        start => {?MODULE, start_link, [Name, Opts]},
        %% the supervisor waits for the slow stop
        shutdown => Stop + 5000
    }.

-spec start_link(term(), map()) -> {ok, pid()}.
start_link(Name, Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

init({Name, Opts}) ->
    process_flag(trap_exit, true),
    Id = {singleton, erlang:unique_integer([positive])},
    Holder = {node(), os:system_time(millisecond), Id},
    S = Opts#{name => Name, holder => Holder, key => {singleton, Name}},
    {ok, S#{fence => none}, {continue, fence}}.

%% The contender answers once start_child returned, so the fence is asked
%% after init.
handle_continue(fence, #{name := Name, holder := H, key := K} = S) ->
    Backend = chappe_cluster_lab_node:backend(),
    case Backend:singleton_fence(Name) of
        {ok, Fence} ->
            chappe_cluster_lab_log:log(H, K, claim_ok, Fence),
            {noreply, beat(S#{fence => Fence})};
        none ->
            {stop, normal, S}
    end.

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(beat, #{fence := none} = S) ->
    {noreply, S};
handle_info(beat, S) ->
    {noreply, beat(S)};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, #{fence := none}) ->
    ok;
terminate(_Reason, #{fence := Fence, holder := H, key := K} = S) ->
    #{stop_ms := Stop} = S,
    Until = erlang:monotonic_time(millisecond) + Stop,
    case slow_stop(S, Until) of
        done -> chappe_cluster_lab_log:log(H, K, release, Fence);
        lost -> ok
    end.

%% A side effect, once chappe_cluster says the singleton still runs here.
beat(#{fence := Fence, holder := H, key := K, beat_ms := Beat} = S) ->
    case valid(S) of
        true ->
            chappe_cluster_lab_log:log(H, K, fence_used, Fence),
            erlang:send_after(Beat, self(), beat),
            S;
        false ->
            chappe_cluster_lab_log:log(H, K, lost, Fence),
            S#{fence => none}
    end.

%% Side effects while stopping, every 100 ms, each checked the same way.
slow_stop(#{fence := Fence, holder := H, key := K} = S, Until) ->
    case {erlang:monotonic_time(millisecond) < Until, valid(S)} of
        {false, _} ->
            done;
        {true, false} ->
            chappe_cluster_lab_log:log(H, K, lost, Fence),
            lost;
        {true, true} ->
            chappe_cluster_lab_log:log(H, K, fence_used, Fence),
            timer:sleep(100),
            slow_stop(S, Until)
    end.

%% chappe_cluster:singleton_valid/1 when the app has it.
valid(#{name := Name}) ->
    Mod = chappe_cluster_lab_node:backend(),
    case erlang:function_exported(Mod, singleton_valid, 1) of
        true ->
            try Mod:singleton_valid(Name) of
                true -> true;
                _ -> false
            catch
                _:_ -> false
            end;
        false ->
            true
    end.
