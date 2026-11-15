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
    case erlang:monotonic_time(millisecond) >= Until of
        true -> {noreply, next(release(S))};
        false -> {noreply, beat(S)}
    end;
handle_info(
    {chappe_cluster, Lease, lost}, #{lease := {Lease, Key, Fence, _}} = S
) ->
    #{holder := H} = S,
    chappe_cluster_lab_log:log(H, Key, lost, Fence),
    {noreply, next(S#{lease => none})};
handle_info(_Stale, S) ->
    %% a beat or a lost for a lease already gone
    {noreply, S}.

claim(#{keys := NKeys, holder := H, hold_ms := {Lo, Hi}} = S) ->
    Key = {lab, rand:uniform(NKeys)},
    try chappe_cluster:claim(Key, #{}) of
        {ok, Lease} ->
            Fence = chappe_cluster:fence(Lease),
            chappe_cluster_lab_log:log(H, Key, claim_ok, Fence),
            Hold = Lo + rand:uniform(Hi - Lo),
            Until = erlang:monotonic_time(millisecond) + Hold,
            beat(S#{lease => {Lease, Key, Fence, Until}});
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
    try chappe_cluster:release(Lease) of
        _ -> ok
    catch
        _:_ -> ok
    end,
    S#{lease => none}.

next(S) ->
    erlang:send_after(100 + rand:uniform(900), self(), tick),
    S.
