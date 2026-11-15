%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% One lab worker: claim a random key, hold it for a random time while
%% using its fence every beat, release it, and start again. It logs what it
%% believes: claim_ok when chappe_cluster grants the lease, fence_used and
%% renew while it holds it, lost when chappe_cluster says so, release just
%% before it gives the key back.
-module(chappe_cluster_lab_worker).
-behaviour(gen_server).

-export([start_link/3, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link(map(), integer(), pos_integer()) -> {ok, pid()}.
start_link(Opts, Boot, I) ->
    gen_server:start_link(?MODULE, {Opts, Boot, I}, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:call(Pid, stop, 30000).

init({Opts, Boot, I}) ->
    Holder = {node(), Boot, {I, erlang:unique_integer([positive])}},
    self() ! tick,
    {ok, Opts#{holder => Holder, lease => none, beats => 0}}.

handle_call(stop, _From, S) ->
    {stop, normal, ok, release(S)}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(tick, #{lease := none} = S) ->
    {noreply, claim(S)};
handle_info({beat, Lease}, #{lease := {Lease, _Key, _Fence, Until}} = S) ->
    case {held(Lease), erlang:monotonic_time(millisecond) >= Until} of
        {false, _} -> {noreply, lost(S)};
        {true, true} -> {noreply, next(release(S))};
        {true, false} -> {noreply, beat(S)}
    end;
handle_info({chappe_cluster, Lease, lost}, #{lease := {Lease, _, _, _}} = S) ->
    {noreply, lost(S)};
handle_info(_Stale, S) ->
    %% a beat or a lost for a lease already gone
    {noreply, S}.

lost(#{lease := {_Lease, Key, Fence, _}, holder := H} = S) ->
    chappe_cluster_lab_log:log(H, Key, lost, Fence),
    next(S#{lease => none}).

%% Before each side effect: a lost already in the mailbox wins, and so does
%% chappe_cluster:valid/1 when the app has it (a paused holder wakes up to
%% its beat and its lost at once).
held(Lease) ->
    receive
        {chappe_cluster, Lease, lost} -> false
    after 0 ->
        case erlang:function_exported(backend(), valid, 1) of
            true -> valid(Lease);
            false -> true
        end
    end.

valid(Lease) ->
    Mod = backend(),
    try Mod:valid(Lease) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

claim(#{keys := NKeys, holder := H, hold_ms := {Lo, Hi}} = S) ->
    Key = {lab, rand:uniform(NKeys)},
    Mod = backend(),
    try Mod:claim(Key, #{}) of
        {ok, Lease} ->
            Fence = Mod:fence(Lease),
            chappe_cluster_lab_log:log(H, Key, claim_ok, Fence),
            Hold = Lo + rand:uniform(Hi - Lo),
            Until = erlang:monotonic_time(millisecond) + Hold,
            beat(S#{lease => {Lease, Key, Fence, Until}});
        {error, {owned, _}} ->
            %% the region answered: the key is someone else's
            chappe_cluster_lab_log:count(owned),
            next(S);
        {error, _} ->
            next(S)
    catch
        _:_ -> next(S)
    end.

beat(#{lease := {Lease, Key, Fence, _}, holder := H, beat_ms := Beat} = S) ->
    #{beats := N} = S,
    Kind =
        case N rem 2 of
            0 -> fence_used;
            1 -> renew
        end,
    chappe_cluster_lab_log:log(H, Key, Kind, Fence),
    erlang:send_after(Beat, self(), {beat, Lease}),
    S#{beats => N + 1}.

release(#{lease := none} = S) ->
    S;
release(#{lease := {Lease, Key, Fence, _}, holder := H} = S) ->
    %% the belief ends here, before the cluster frees the key
    chappe_cluster_lab_log:log(H, Key, release, Fence),
    Mod = backend(),
    try Mod:release(Lease) of
        _ -> ok
    catch
        _:_ -> ok
    end,
    S#{lease => none}.

backend() ->
    chappe_cluster_lab_node:backend().

next(S) ->
    erlang:send_after(100 + rand:uniform(900), self(), tick),
    S.
