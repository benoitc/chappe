%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The node's store: it holds the storage config, answers the lookups of
%% chappe_audio_store for this node (its own callers' and other nodes',
%% which find it in the chappe_audio_store pg group of the `chappe_audio'
%% scope), and runs the sweep every sweep_interval, when its sweep_guard
%% says this node sweeps now.
-module(chappe_audio_store_srv).
-behaviour(gen_server).

-export([start_link/0, backend/0, adopted/3, writing/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(GROUP, chappe_audio_store).
%% the default sweep interval: hourly
-define(SWEEP, 3600000).

%% adoptions remembered once done, so asking again for one adopts nothing
-define(DONE_MAX, 1024).

-record(state, {
    backend :: module(),
    config :: map(),
    timer :: reference() | undefined,
    %% adoption jobs by source path: the job, its monitor, who to tell
    jobs = #{} :: #{binary() => {pid(), reference(), [pid()]}},
    %% the last outcomes, by source path, oldest first in done_order
    done = #{} :: #{binary() => {pid(), term()}},
    done_order = queue:new() :: queue:queue(binary()),
    %% the partial files of the live writers, by writer monitor
    live = #{} :: #{reference() => binary()}
}).

-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A live writer's partial file (chappe_audio_writer), spared by the
%% sweep until the writer goes.
-spec writing(pid(), file:filename_all() | undefined) -> ok.
writing(_Writer, undefined) ->
    ok;
writing(Writer, Part) ->
    gen_server:call(?MODULE, {writing, Writer, key(Part)}).

%% A job's outcome (chappe_audio_adopt).
-spec adopted(pid(), file:filename_all(), term()) -> ok.
adopted(Job, Path, Result) ->
    gen_server:call(?MODULE, {adopted, Job, key(Path), Result}).

key(Path) ->
    unicode:characters_to_binary(filename:absname(Path)).

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
handle_call({adopt, Path, Meta, Opts, Notify}, _From, S) ->
    adopt_job(key(Path), Path, Meta, Opts, Notify, S);
handle_call({adopted, Job, Key, Result}, _From, #state{jobs = J} = S) ->
    case maps:take(Key, J) of
        {{Job, Mon, Waiters}, J1} ->
            demonitor(Mon, [flush]),
            tell(Waiters, Job, Key, Result),
            {reply, ok, remember(Key, {Job, Result}, S#state{jobs = J1})};
        _ ->
            {reply, ok, S}
    end;
handle_call({find, Ref}, _From, #state{backend = B, config = C} = S) ->
    {reply, {ok, B:find(Ref, C)}, S};
handle_call({get, Id}, _From, #state{backend = B, config = C} = S) ->
    {reply, B:get(Id, C), S};
handle_call({read, Id, Range}, _From, #state{backend = B, config = C} = S) ->
    {reply, B:read(Id, Range, C), S};
handle_call({delete, Id}, _From, #state{backend = B, config = C} = S) ->
    {reply, B:delete(Id, C), S};
handle_call(sweep, _From, S) ->
    {reply, guarded_sweep(S), S};
handle_call({writing, Writer, Part}, _From, #state{live = L} = S) ->
    {reply, ok, S#state{live = L#{monitor(process, Writer) => Part}}};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Mon, process, _, _}, #state{live = L} = S) when
    is_map_key(Mon, L)
->
    {noreply, S#state{live = maps:remove(Mon, L)}};
handle_info({'DOWN', Mon, process, Job, Reason}, #state{jobs = J} = S) ->
    %% a job that died before its outcome
    case [K || K := {P, M, _} <- J, P =:= Job, M =:= Mon] of
        [Key] ->
            {_, _, Waiters} = maps:get(Key, J),
            Result = {error, {adopt_crashed, Reason}},
            tell(Waiters, Job, Key, Result),
            {noreply, S#state{jobs = maps:remove(Key, J)}};
        [] ->
            {noreply, S}
    end;
handle_info(
    {timeout, T, sweep}, #state{timer = T} = S
) ->
    _ = guarded_sweep(S),
    {noreply, arm(S)};
handle_info(_Info, S) ->
    {noreply, S}.

%% ---- internal ----

%% The sweep, when the guard says this node sweeps now. A shared folder
%% or a network backend passes a guard so one node sweeps (a cluster
%% singleton); a guard that fails counts as no.
guarded_sweep(#state{backend = B, config = C} = S) ->
    case sweeps(maps:get(sweep_guard, C, undefined)) of
        true -> B:sweep(sweep_config(S));
        false -> {ok, 0}
    end.

sweeps(undefined) ->
    true;
sweeps(Guard) ->
    try run_guard(Guard) of
        true -> true;
        _ -> false
    catch
        Class:Why ->
            logger:warning("chappe_audio_store: sweep_guard ~p: ~p", [
                Class, Why
            ]),
            false
    end.

run_guard({M, F, A}) -> apply(M, F, A);
run_guard(Fun) -> Fun().

%% The backend's config for a sweep, with the live writers' parts.
sweep_config(#state{config = C, live = L}) ->
    maps:remove(sweep_guard, C#{live => maps:from_keys(maps:values(L), true)}).

%% One job per source path: a second ask joins the running one, an ask
%% for one done gets its outcome again (the file is in the store).
adopt_job(Key, Path, Meta, Opts, Notify, #state{jobs = J, done = D} = S) ->
    case {J, D} of
        {#{Key := {Job, Mon, Waiters}}, _} ->
            {reply, {ok, Job}, S#state{
                jobs = J#{Key := {Job, Mon, add(Notify, Waiters)}}
            }};
        {_, #{Key := {Job, Result}}} ->
            tell(add(Notify, []), Job, Key, Result),
            {reply, {ok, Job}, S};
        _ ->
            case
                supervisor:start_child(chappe_audio_adopt_sup, [
                    Path, Meta, Opts
                ])
            of
                {ok, Job} ->
                    Mon = monitor(process, Job),
                    {reply, {ok, Job}, S#state{
                        jobs = J#{Key => {Job, Mon, add(Notify, [])}}
                    }};
                {error, _} = Err ->
                    {reply, Err, S}
            end
    end.

add(undefined, Ws) -> Ws;
add(Pid, Ws) -> [Pid | Ws].

tell(Waiters, Job, Key, Result) ->
    _ = [W ! {chappe_audio_store, Job, {adopted, Key, Result}} || W <- Waiters],
    ok.

remember(Key, Entry, #state{done = D, done_order = Q} = S) ->
    Q1 = queue:in(Key, Q),
    D1 = D#{Key => Entry},
    case queue:len(Q1) > ?DONE_MAX of
        true ->
            {{value, Old}, Q2} = queue:out(Q1),
            S#state{done = maps:remove(Old, D1), done_order = Q2};
        false ->
            S#state{done = D1, done_order = Q1}
    end.

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
opt_ok(sweep_guard, {M, F, A}) ->
    is_atom(M) andalso is_atom(F) andalso is_list(A);
opt_ok(sweep_guard, G) ->
    is_function(G, 0);
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
