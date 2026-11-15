%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The event log of one lab node boot: one `{Time, Holder, Key, Kind,
%% Fence}.' line per event in `<log_dir>/<node>-<boot>.log', written as it
%% comes (no write buffer), so a docker kill loses at most the last lines.
-module(chappe_cluster_lab_log).
-behaviour(gen_server).

-export([start_link/2, log/4, sync/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link(map(), integer()) -> {ok, pid()}.
start_link(Opts, Boot) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Opts, Boot}, []).

%% @doc Log an event, stamped with this node's clock now.
-spec log(term(), term(), atom(), term()) -> ok.
log(Holder, Key, Kind, Fence) ->
    T = os:system_time(microsecond),
    gen_server:cast(?MODULE, {log, {T, Holder, Key, Kind, Fence}}).

-spec sync() -> ok.
sync() ->
    gen_server:call(?MODULE, sync).

-spec stats() -> #{atom() => non_neg_integer()}.
stats() ->
    gen_server:call(?MODULE, stats).

init({#{log_dir := Dir}, Boot}) ->
    [Name, _Host] = string:split(atom_to_list(node()), "@"),
    File = filename:join(Dir, Name ++ "-" ++ integer_to_list(Boot) ++ ".log"),
    ok = filelib:ensure_dir(File),
    {ok, Fd} = file:open(File, [append, raw, binary]),
    {ok, #{fd => Fd, stats => #{}}}.

handle_call(sync, _From, #{fd := Fd} = S) ->
    {reply, file:sync(Fd), S};
handle_call(stats, _From, #{stats := Stats} = S) ->
    {reply, Stats, S}.

handle_cast({log, {_, _, _, Kind, _} = Ev}, #{fd := Fd, stats := Stats} = S) ->
    ok = file:write(Fd, io_lib:format("~w.~n", [Ev])),
    Stats1 = maps:update_with(Kind, fun(N) -> N + 1 end, 1, Stats),
    {noreply, S#{stats => Stats1}}.

handle_info(_Msg, S) ->
    {noreply, S}.
