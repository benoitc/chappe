%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The event log of one lab node boot: one `{Time, Holder, Key, Kind,
%% Fence, Hlc}.' line per event in `<log_dir>/<host>-<boot>.log', written as it
%% comes (no write buffer), so a docker kill loses at most the last lines.
%%
%% Times are real time read from the monotonic clock, with the offset to the
%% wall clock taken when the log starts: the lab skews a node's wall clock
%% (libfaketime) while it runs, and the checker compares true times.
-module(chappe_cluster_lab_log).
-behaviour(gen_server).

-export([start_link/2, log/4, count/1, sync/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link(map(), integer()) -> {ok, pid()}.
start_link(Opts, Boot) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Opts, Boot}, []).

%% @doc Log an event, stamped with the real time now and with the node's
%% hybrid logical clock (chappe_cluster:now/0, `none' without it).
-spec log(term(), term(), atom(), term()) -> ok.
log(Holder, Key, Kind, Fence) ->
    Offset = persistent_term:get({?MODULE, offset}),
    T = erlang:monotonic_time(microsecond) + Offset,
    Ev = {T, Holder, Key, Kind, Fence, hlc()},
    gen_server:cast(?MODULE, {log, Ev}).

hlc() ->
    Mod = chappe_cluster_lab_node:backend(),
    case erlang:function_exported(Mod, now, 0) of
        true ->
            try
                Mod:now()
            catch
                _:_ -> none
            end;
        false ->
            none
    end.

%% @doc Count an answer that logs no event (a claim refused as owned).
-spec count(atom()) -> ok.
count(What) ->
    gen_server:cast(?MODULE, {count, What}).

-spec sync() -> ok.
sync() ->
    gen_server:call(?MODULE, sync).

-spec stats() -> #{atom() => non_neg_integer()}.
stats() ->
    gen_server:call(?MODULE, stats).

init({#{log_dir := Dir}, Boot}) ->
    [_Name, Host] = string:split(atom_to_list(node()), "@"),
    File = filename:join(Dir, Host ++ "-" ++ integer_to_list(Boot) ++ ".log"),
    ok = filelib:ensure_dir(File),
    Offset = os:system_time(microsecond) - erlang:monotonic_time(microsecond),
    ok = persistent_term:put({?MODULE, offset}, Offset),
    {ok, Fd} = file:open(File, [append, raw, binary]),
    {ok, #{fd => Fd, stats => #{}}}.

handle_call(sync, _From, #{fd := Fd} = S) ->
    {reply, file:sync(Fd), S};
handle_call(stats, _From, #{stats := Stats} = S) ->
    {reply, Stats, S}.

handle_cast({count, What}, #{stats := Stats} = S) ->
    {noreply, S#{
        stats => maps:update_with(What, fun(N) -> N + 1 end, 1, Stats)
    }};
handle_cast({log, {_, _, _, Kind, _, _} = Ev}, #{fd := Fd, stats := Stats} = S) ->
    ok = file:write(Fd, io_lib:format("~w.~n", [Ev])),
    Stats1 = maps:update_with(Kind, fun(N) -> N + 1 end, 1, Stats),
    {noreply, S#{stats => Stats1}}.

handle_info(_Msg, S) ->
    {noreply, S}.
