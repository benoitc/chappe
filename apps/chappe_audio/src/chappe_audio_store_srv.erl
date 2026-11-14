%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The node's store: it holds the storage config, answers the lookups of
%% chappe_audio_store for this node (its own callers' and other nodes',
%% which find it in the chappe_audio_store pg group of the `chappe'
%% scope), and runs the sweep every sweep_interval.
-module(chappe_audio_store_srv).
-behaviour(gen_server).

-export([start_link/0, backend/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(GROUP, chappe_audio_store).
%% the default sweep interval: hourly
-define(SWEEP, 3600000).

-record(state, {
    backend :: module(),
    config :: map(),
    timer :: reference() | undefined
}).

-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The backend module and its config, for a writer starting.
-spec backend() -> {module(), map()}.
backend() ->
    gen_server:call(?MODULE, backend).

-spec init([]) -> {ok, state()} | {stop, term()}.
init([]) ->
    Config = application:get_env(chappe_audio, storage, #{}),
    case setup(Config) of
        {ok, S} ->
            ok = chappe_audio_pg:join(?GROUP, self()),
            {ok, arm(S)};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(backend, _From, #state{backend = B, config = C} = S) ->
    {reply, {B, C}, S};
handle_call(config, _From, #state{config = C} = S) ->
    {reply, C, S};
handle_call({configure, Config}, _From, S) ->
    case setup(Config) of
        {ok, S1} ->
            cancel(S#state.timer),
            {reply, ok, arm(S1)};
        {error, _} = Err ->
            {reply, Err, S}
    end;
handle_call({adopt, Path, Meta}, _From, #state{backend = B, config = C} = S) ->
    {reply, B:adopt(Path, Meta, C), S};
handle_call({find, Ref}, _From, #state{backend = B, config = C} = S) ->
    {reply, {ok, B:find(Ref, C)}, S};
handle_call({get, Id}, _From, #state{backend = B, config = C} = S) ->
    {reply, B:get(Id, C), S};
handle_call({read, Id, Range}, _From, #state{backend = B, config = C} = S) ->
    {reply, B:read(Id, Range, C), S};
handle_call({delete, Id}, _From, #state{backend = B, config = C} = S) ->
    {reply, B:delete(Id, C), S};
handle_call(sweep, _From, #state{backend = B, config = C} = S) ->
    {reply, B:sweep(C), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(
    {timeout, T, sweep}, #state{timer = T, backend = B, config = C} = S
) ->
    _ = B:sweep(C),
    {noreply, arm(S)};
handle_info(_Info, S) ->
    {noreply, S}.

%% ---- internal ----

%% The defaults, a known backend, and its own checks.
setup(Config0) ->
    Config = maps:merge(#{backend => file, dir => "recordings"}, Config0),
    case backend_mod(maps:get(backend, Config)) of
        {ok, Mod} ->
            case check(Config) of
                ok -> {ok, #state{backend = Mod, config = Config}};
                Err -> Err
            end;
        error ->
            {error, {bad_option, backend}}
    end.

backend_mod(file) ->
    {ok, chappe_audio_store_file};
backend_mod(Mod) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} -> {ok, Mod};
        _ -> error
    end;
backend_mod(_) ->
    error.

check(Config) ->
    Bad = [
        K
     || {K, V} <- maps:to_list(Config),
        not opt_ok(K, V)
    ],
    case Bad of
        [] -> ok;
        [K | _] -> {error, {bad_option, K}}
    end.

opt_ok(dir, D) ->
    is_list(D) orelse is_binary(D);
opt_ok(retention_days, D) ->
    D =:= undefined orelse (is_integer(D) andalso D > 0);
opt_ok(sweep_interval, I) ->
    is_integer(I) andalso I > 0;
opt_ok(_, _) ->
    true.

arm(#state{config = C} = S) ->
    T = erlang:start_timer(maps:get(sweep_interval, C, ?SWEEP), self(), sweep),
    S#state{timer = T}.

cancel(undefined) ->
    ok;
cancel(T) ->
    _ = erlang:cancel_timer(T),
    ok.
