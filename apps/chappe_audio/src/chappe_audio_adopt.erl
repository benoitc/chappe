%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc One adoption: the process that takes a finished file into the store,
%% under chappe_audio_adopt_sup (temporary), so that a move across file
%% systems (a copy, as long as it takes) never runs in the store's process
%% or in the caller's (an endpoint, a room).
%%
%% The store starts at most one job per source path and remembers the
%% outcome of the last ones (chappe_audio_store_srv), so asking twice for
%% the same file, as a hangup and a terminate both may, adopts it once.
%% With settle_ms, the job first waits for the file to stop growing for
%% that long (a writer that gives no signal when it closes); with keep
%% it copies and never removes the source.
%%
%% The outcome goes to each process that asked, as
%% {chappe_audio_store, Job, {adopted, Path, {ok, Id} | {error, Reason}}}.
-module(chappe_audio_adopt).

-export([start_link/3]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).
-behaviour(gen_server).

-record(state, {
    path :: file:filename_all(),
    meta :: map(),
    opts :: map()
}).

-type state() :: #state{}.

-define(POLL_MS, 200).
%% a settle never waits longer than this for a file that keeps growing
-define(SETTLE_MAX_MS, 60000).

-spec start_link(file:filename_all(), map(), map()) -> {ok, pid()}.
start_link(Path, Meta, Opts) ->
    gen_server:start_link(?MODULE, {Path, Meta, Opts}, []).

-spec init({file:filename_all(), map(), map()}) ->
    {ok, state(), {continue, run}}.
init({Path, Meta, Opts}) ->
    {ok, #state{path = Path, meta = Meta, opts = Opts}, {continue, run}}.

handle_continue(run, #state{path = Path, meta = Meta, opts = Opts} = S) ->
    ok = settle(Path, maps:get(settle_ms, Opts, 0)),
    {Backend, Config} = chappe_audio_store_srv:backend(),
    M =
        case maps:get(keep, Opts, false) of
            true -> Meta#{keep => true};
            false -> Meta
        end,
    Result =
        try
            Backend:adopt(Path, M, Config)
        catch
            Class:Reason -> {error, {Class, Reason}}
        end,
    ok = chappe_audio_store_srv:adopted(self(), Path, Result),
    {stop, normal, S}.

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% Wait until the size has held for Ms (0: no wait), at most a minute.
settle(_Path, 0) ->
    ok;
settle(Path, Ms) ->
    settle(Path, Ms, filelib:file_size(Path), 0, ?SETTLE_MAX_MS div ?POLL_MS).

settle(_Path, _Ms, _Last, _Held, 0) ->
    ok;
settle(_Path, Ms, _Last, Held, _N) when Held >= Ms ->
    ok;
settle(Path, Ms, Last, Held, N) ->
    timer:sleep(?POLL_MS),
    case filelib:file_size(Path) of
        Last -> settle(Path, Ms, Last, Held + ?POLL_MS, N - 1);
        Size -> settle(Path, Ms, Size, 0, N - 1)
    end.
