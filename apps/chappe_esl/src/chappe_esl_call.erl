%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Typed call control over the event socket.
%%
%% exec/5 runs a dialplan application on a channel and waits for its end: the
%% sendmsg carries an Event-UUID, which FreeSWITCH reports back as the
%% Application-UUID of the CHANNEL_EXECUTE_COMPLETE event, so a completion is
%% matched to its own request even when several are in flight. It is called
%% from the connection's controlling process, like bgapi_await.
%%
%% A call process owns one connection to one channel: an outbound (dialplan
%% socket) connection, or an inbound connection given the channel uuid. It
%% becomes the connection's controlling process, subscribes to the channel's
%% events (myevents on outbound, a Unique-ID filter and every event on
%% inbound), correlates completions with the requests waiting on them and
%% sends the rest to its owner as {chappe_esl_call, Call, Msg}:
%%
%%   {dtmf, Digit}             a DTMF event
%%   {hangup, Cause}           CHANNEL_HANGUP, with its Hangup-Cause
%%   {complete, App, Event}    a completion no request waits for (an app
%%                             started with wait => false, or the dialplan's;
%%                             a timed out request's completion is dropped)
%%   {event, Event}            any other event of the channel
%%   closed                    the connection is gone; the process stops
%%
%% When the owner dies before the channel hangs up, the call process stops
%% the audio forks (each with its module's stop) and session recordings it
%% started, kills the channel with uuid_kill, and closes the connection.
-module(chappe_esl_call).
-behaviour(gen_server).

%% Raw execute on a connection.
-export([exec/5]).
%% Call process.
-export([start/1, start/2, stop/1, uuid/1]).
-export([exec/3, exec/4, api/2]).
%% Typed helpers.
-export([answer/1, playback/2, playback/3, play_and_get_digits/2]).
-export([record/3, record_session/2, record_session_stop/2]).
-export([send_dtmf/2, set/3, export/3, hangup/1, hangup/2]).
-export([conference/2, conference/3, audio_fork_start/3, audio_fork_stop/1]).
%% gen_server.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([call/0, exec_opts/0, start_opts/0, msg/0, fork_module/0]).

-define(EXEC_TIMEOUT, 60000).
-define(CLEANUP_TIMEOUT, 2000).
-define(DIGITS_VAR, <<"chappe_digits">>).

-type call() :: pid().
-type event() :: chappe_esl_event:event().
%% timeout: how long to wait for the completion (60 s).
%% wait: false returns {ok, AppUuid} once FreeSWITCH accepted the command;
%% the completion then reaches the owner as {complete, App, Event}.
%% lock: event-lock, so applications run one after the other (true).
%% loops: how many times to run the application (1).
-type exec_opts() :: #{
    timeout => timeout(),
    wait => boolean(),
    lock => boolean(),
    loops => pos_integer()
}.
%% owner: the process that gets the messages and whose death ends the call
%% (the caller). uuid: the channel, required on an inbound connection.
%% cleanup: on owner death, stop forks and recordings and kill the channel
%% (true).
-type start_opts() :: #{owner => pid(), uuid => binary(), cleanup => boolean()}.
%% audio_fork: mod_audio_fork (uuid_audio_fork); audio_stream:
%% mod_audio_stream (uuid_audio_stream).
-type fork_module() :: audio_fork | audio_stream.
-type msg() ::
    {dtmf, binary()}
    | {hangup, binary()}
    | {complete, binary(), event()}
    | {event, event()}
    | closed.

-record(state, {
    conn :: pid(),
    conn_mon :: reference(),
    uuid :: binary(),
    owner :: pid(),
    owner_mon :: reference(),
    cleanup :: boolean(),
    hungup = false :: boolean(),
    %% the fork modules started, oldest first
    forks = [] :: [fork_module()],
    recordings = [] :: [binary()],
    %% the application running now (its Application-UUID), and the timed
    %% out ones: broken when they run, their completion dropped
    running :: binary() | undefined,
    cancelled = #{} :: #{binary() => true},
    pending = #{} :: #{binary() => {waiter(), reference()}}
}).

-type state() :: #state{}.
%% {sync, From}: a helper that answers ok instead of the event.
-type waiter() :: gen_server:from() | {sync, gen_server:from()}.

%% Raw execute

%% Execute App on the channel Uuid (undefined for the channel of an outbound
%% connection) and wait for its CHANNEL_EXECUTE_COMPLETE. Call it from the
%% connection's controlling process, with the channel's execute events
%% subscribed (myevents, or a Unique-ID filter and CHANNEL_EXECUTE_COMPLETE).
%% Other messages received meanwhile are put back in the mailbox. Errors:
%% timeout, hangup (the channel hung up first), closed, or the -ERR text of
%% the sendmsg reply. On timeout the application is stopped: uuid_break when
%% it runs, uuid_break <uuid> all (the whole queue) when it has not started.
%% With wait => false it returns {ok, AppUuid} at once.
-spec exec(
    chappe_esl:conn(), binary() | undefined, iodata(), iodata(), exec_opts()
) ->
    {ok, event() | binary()} | {error, term()}.
exec(Conn, Uuid, App, Args, Opts) ->
    chappe_esl_exec:exec(Conn, Uuid, App, Args, Opts).

%% Call process

-spec start(chappe_esl:conn()) -> {ok, call()} | {error, term()}.
start(Conn) ->
    start(Conn, #{}).

%% Take over a connection for one channel. On an outbound connection the
%% channel is the connected one; on an inbound connection pass its uuid.
-spec start(chappe_esl:conn(), start_opts()) -> {ok, call()} | {error, term()}.
start(Conn, Opts) ->
    Owner = maps:get(owner, Opts, self()),
    gen_server:start(?MODULE, {Conn, Owner, Opts}, []).

%% Stop the call process and close its connection. The channel is left
%% alone: no cleanup, no uuid_kill.
-spec stop(call()) -> ok.
stop(Call) ->
    try
        gen_server:stop(Call)
    catch
        exit:_ -> ok
    end.

-spec uuid(call()) -> binary().
uuid(Call) ->
    gen_server:call(Call, uuid).

-spec exec(call(), iodata(), iodata()) -> {ok, event()} | {error, term()}.
exec(Call, App, Args) ->
    exec(Call, App, Args, #{}).

%% Execute App on the call's channel and wait for its completion (see
%% exec/5 for the options and errors).
-spec exec(call(), iodata(), iodata(), exec_opts()) ->
    {ok, event() | binary()} | {error, term()}.
exec(Call, App, Args, Opts) ->
    call(Call, {exec, App, Args, Opts}).

%% Run an api command on the call's connection.
-spec api(call(), iodata()) -> {ok, binary()} | {error, term()}.
api(Call, Cmd) ->
    call(Call, {api, Cmd}).

%% Typed helpers

-spec answer(call()) -> ok | {error, term()}.
answer(Call) ->
    done(exec(Call, <<"answer">>, <<>>)).

%% Play a file; the completion event's Application-Response says how it
%% ended (FILE PLAYED, FILE NOT FOUND, ...).
-spec playback(call(), iodata()) -> {ok, event()} | {error, term()}.
playback(Call, File) ->
    playback(Call, File, #{}).

-spec playback(call(), iodata(), exec_opts()) ->
    {ok, event()} | {error, term()}.
playback(Call, File, Opts) ->
    exec(Call, <<"playback">>, File, Opts).

%% Play a prompt and collect digits. Opts: file (required), min (1), max
%% (1), tries (1), timeout (5000 ms), terminators (<<"#">>), invalid_file
%% (silence_stream://250), regexp (<<"[0-9*#]+">>), digit_timeout (timeout),
%% var (chappe_digits), plus exec_opts. Returns the digits FreeSWITCH stored
%% in var, <<>> when none were entered.
-spec play_and_get_digits(call(), map()) -> {ok, binary()} | {error, term()}.
play_and_get_digits(Call, #{file := File} = Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    Var = to_bin(maps:get(var, Opts, ?DIGITS_VAR)),
    Args = join([
        chappe_esl_exec:arg(A)
     || A <- [
            int(maps:get(min, Opts, 1)),
            int(maps:get(max, Opts, 1)),
            int(maps:get(tries, Opts, 1)),
            int(Timeout),
            maps:get(terminators, Opts, <<"#">>),
            File,
            maps:get(invalid_file, Opts, <<"silence_stream://250">>),
            Var,
            maps:get(regexp, Opts, <<"[0-9*#]+">>),
            int(maps:get(digit_timeout, Opts, Timeout))
        ]
    ]),
    ExecOpts = maps:with([lock, loops], Opts),
    case
        exec(Call, <<"play_and_get_digits">>, Args, ExecOpts#{
            timeout => infinity
        })
    of
        {ok, Ev} ->
            Digits = chappe_esl_event:header(<<"variable_", Var/binary>>, Ev),
            {ok, to_bin(Digits)};
        Error ->
            Error
    end.

%% Record the caller to Path. Opts: max_secs, silence_thresh, silence_hits
%% (record's optional arguments), plus exec_opts.
-spec record(call(), iodata(), map()) -> {ok, event()} | {error, term()}.
record(Call, Path, Opts) ->
    Limits = [
        int(V)
     || K <- [max_secs, silence_thresh, silence_hits],
        V <- [maps:get(K, Opts, undefined)],
        V =/= undefined
    ],
    exec(
        Call,
        <<"record">>,
        join([chappe_esl_exec:arg(Path) | Limits]),
        exec_opts(Opts)
    ).

%% Start recording the whole session (both directions) to Path. The
%% recording runs until record_session_stop/2 or the hangup.
-spec record_session(call(), iodata()) -> ok | {error, term()}.
record_session(Call, Path) ->
    call(Call, {record_session, to_bin(Path)}).

-spec record_session_stop(call(), iodata()) -> ok | {error, term()}.
record_session_stop(Call, Path) ->
    call(Call, {record_session_stop, to_bin(Path)}).

%% Send DTMF digits to the far end (the send_dtmf application).
-spec send_dtmf(call(), iodata()) -> ok | {error, term()}.
send_dtmf(Call, Digits) ->
    done(exec(Call, <<"send_dtmf">>, Digits)).

-spec set(call(), iodata(), iodata()) -> ok | {error, term()}.
set(Call, Var, Value) ->
    done(exec(Call, <<"set">>, [Var, $=, Value])).

%% Set a variable on the channel and on the channel it gets bridged to.
-spec export(call(), iodata(), iodata()) -> ok | {error, term()}.
export(Call, Var, Value) ->
    done(exec(Call, <<"export">>, [Var, $=, Value])).

-spec hangup(call()) -> ok | {error, term()}.
hangup(Call) ->
    hangup(Call, <<"NORMAL_CLEARING">>).

-spec hangup(call(), iodata()) -> ok | {error, term()}.
hangup(Call, Cause) ->
    case exec(Call, <<"hangup">>, Cause) of
        {error, hangup} -> ok;
        Other -> done(Other)
    end.

-spec conference(call(), iodata()) -> {ok, binary()} | {error, term()}.
conference(Call, Room) ->
    conference(Call, Room, #{}).

%% Join a mod_conference room: Room@Profile+flags{F1|F2}. Opts: profile
%% (default), flags (a list of mod_conference member flags, such as mute or
%% moderator), plus exec_opts. It does not wait by default: it returns
%% {ok, AppUuid}, and {complete, <<"conference">>, Event} reaches the owner
%% when the member leaves. With wait => true it returns at that point.
-spec conference(call(), iodata(), map()) ->
    {ok, binary() | event()} | {error, term()}.
conference(Call, Room, Opts) ->
    Profile = maps:get(profile, Opts, <<"default">>),
    Flags =
        case maps:get(flags, Opts, []) of
            [] -> [];
            Fs -> [<<"+flags{">>, lists:join($|, [to_bin(F) || F <- Fs]), $}]
        end,
    Spec = [Room, $@, Profile, Flags],
    exec(
        Call,
        <<"conference">>,
        Spec,
        exec_opts(maps:merge(#{wait => false}, Opts))
    ).

%% Fork the channel audio to a websocket. Opts: module (audio_fork, the
%% default, for mod_audio_fork, or audio_stream for mod_audio_stream), mix
%% (mono | mixed | stereo, default mono), rate (16000), metadata (sent to the
%% server as the first text frame). An unknown module returns
%% {error, {bad_option, module}}.
-spec audio_fork_start(call(), iodata(), map()) -> ok | {error, term()}.
audio_fork_start(Call, Url, Opts) ->
    case fork_module(Opts) of
        {ok, Module} -> call(Call, {fork_start, Module, Url, Opts});
        error -> {error, {bad_option, module}}
    end.

%% Stop the forks this call started, each with its module's command
%% (uuid_audio_fork stop when none was started).
-spec audio_fork_stop(call()) -> ok | {error, term()}.
audio_fork_stop(Call) ->
    call(Call, fork_stop).

%% gen_server

-spec init({pid(), pid(), start_opts()}) -> {ok, state()} | {stop, term()}.
init({Conn, Owner, Opts}) ->
    process_flag(trap_exit, true),
    ConnMon = monitor(process, Conn),
    case channel_uuid(Conn, Opts) of
        {ok, Mode, Uuid} ->
            ok = chappe_esl:set_controlling_process(Conn, self()),
            case subscribe(Mode, Conn, Uuid) of
                ok ->
                    {ok, #state{
                        conn = Conn,
                        conn_mon = ConnMon,
                        uuid = Uuid,
                        owner = Owner,
                        owner_mon = monitor(process, Owner),
                        cleanup = maps:get(cleanup, Opts, true)
                    }};
                {error, Reason} ->
                    {stop, {subscribe_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(uuid, _From, #state{uuid = Uuid} = State) ->
    {reply, Uuid, State};
handle_call({exec, _App, _Args, _Opts}, _From, #state{hungup = true} = State) ->
    {reply, {error, hangup}, State};
handle_call({exec, App, Args, Opts}, From, State) ->
    start_exec(App, Args, Opts, From, State);
handle_call({api, Cmd}, _From, #state{conn = Conn} = State) ->
    {reply, chappe_esl:api(Conn, Cmd), State};
handle_call({record_session, Path}, From, #state{recordings = Recs} = State) ->
    %% tracked before it starts, so an owner dying meanwhile still stops it
    State1 = State#state{recordings = [Path | lists:delete(Path, Recs)]},
    sync_exec(<<"record_session">>, chappe_esl_exec:arg(Path), From, State1);
handle_call(
    {record_session_stop, Path}, From, #state{recordings = Recs} = State
) ->
    State1 = State#state{recordings = lists:delete(Path, Recs)},
    sync_exec(<<"stop_record_session">>, Path, From, State1);
handle_call({fork_start, Module, Url, Opts}, _From, State) ->
    #state{conn = Conn, uuid = Uuid, forks = Forks} = State,
    case ok(chappe_esl:api(Conn, fork_start_cmd(Module, Uuid, Url, Opts))) of
        ok ->
            {reply, ok, State#state{
                forks = lists:delete(Module, Forks) ++ [Module]
            }};
        Error ->
            {reply, Error, State}
    end;
handle_call(fork_stop, _From, #state{forks = Forks} = State) ->
    #state{conn = Conn, uuid = Uuid} = State,
    Replies = [
        ok(chappe_esl:api(Conn, fork_stop_cmd(M, Uuid)))
     || M <- stop_modules(Forks)
    ],
    {reply, first_error(Replies), State#state{forks = []}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({chappe_esl_event, Conn, Ev}, #state{conn = Conn} = State) ->
    {noreply, event(chappe_esl_event:name(Ev), Ev, State)};
handle_info({timeout, TRef, {exec, AppUuid}}, #state{pending = P} = State) ->
    case maps:take(AppUuid, P) of
        {{From, TRef}, P1} ->
            reply(From, {error, timeout}),
            #state{cancelled = C} = State,
            State1 = State#state{pending = P1, cancelled = C#{AppUuid => true}},
            {noreply, break_if_running(AppUuid, State1)};
        _ ->
            {noreply, State}
    end;
handle_info({'DOWN', Mon, process, _, _}, #state{owner_mon = Mon} = State) ->
    _ = cleanup(State),
    {stop, normal, State};
handle_info({'DOWN', Mon, process, _, _}, #state{conn_mon = Mon} = State) ->
    closed(State);
handle_info({chappe_esl_closed, Conn}, #state{conn = Conn} = State) ->
    closed(State);
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn = Conn, pending = P}) ->
    fail_pending(P, {error, closed}),
    try
        chappe_esl:close(Conn)
    catch
        _:_ -> ok
    end.

%% internal: call process

call(Call, Request) ->
    try
        gen_server:call(Call, Request, infinity)
    catch
        exit:{_Reason, {gen_server, call, _}} -> {error, closed}
    end.

start_exec(App, Args, Opts, From, #state{conn = Conn, uuid = Uuid} = State) ->
    AppUuid = chappe_esl_exec:app_uuid(),
    case chappe_esl_exec:send(Conn, Uuid, AppUuid, App, Args, Opts) of
        ok ->
            case maps:get(wait, Opts, true) of
                true ->
                    Timeout = maps:get(timeout, Opts, ?EXEC_TIMEOUT),
                    {noreply, add_pending(AppUuid, From, Timeout, State)};
                false ->
                    {reply, {ok, AppUuid}, State}
            end;
        Error ->
            {reply, Error, State}
    end.

%% A helper whose own completion only says done or not.
sync_exec(_App, _Args, _From, #state{hungup = true} = State) ->
    {reply, {error, hangup}, State};
sync_exec(App, Args, From, State) ->
    start_exec(App, Args, #{}, {sync, From}, State).

add_pending(AppUuid, From, Timeout, #state{pending = P} = State) ->
    TRef =
        case Timeout of
            infinity -> make_ref();
            _ -> erlang:start_timer(Timeout, self(), {exec, AppUuid})
        end,
    State#state{pending = P#{AppUuid => {From, TRef}}}.

event(<<"CHANNEL_EXECUTE">>, Ev, State) ->
    AppUuid = chappe_esl_event:header(<<"Application-UUID">>, Ev),
    State1 = break_if_running(AppUuid, State#state{running = AppUuid}),
    notify(State1, {event, Ev});
event(<<"CHANNEL_EXECUTE_COMPLETE">>, Ev, State0) ->
    AppUuid = chappe_esl_event:header(<<"Application-UUID">>, Ev),
    #state{pending = P, cancelled = C} = State = not_running(AppUuid, State0),
    case {maps:take(AppUuid, P), maps:take(AppUuid, C)} of
        {{{From, TRef}, P1}, _} ->
            _ = erlang:cancel_timer(TRef),
            reply(From, {ok, Ev}),
            State#state{pending = P1};
        {error, {true, C1}} ->
            %% its request already returned {error, timeout}
            State#state{cancelled = C1};
        {error, error} ->
            App = to_bin(chappe_esl_event:header(<<"Application">>, Ev)),
            notify(State, {complete, App, Ev})
    end;
event(<<"DTMF">>, Ev, State) ->
    notify(
        State, {dtmf, to_bin(chappe_esl_event:header(<<"DTMF-Digit">>, Ev))}
    );
event(<<"CHANNEL_HANGUP">>, Ev, State) ->
    Cause = to_bin(chappe_esl_event:header(<<"Hangup-Cause">>, Ev)),
    notify(State#state{hungup = true}, {hangup, Cause});
event(<<"CHANNEL_HANGUP_COMPLETE">>, Ev, #state{pending = P} = State) ->
    %% applications queued behind the one that was running never complete
    fail_pending(P, {error, hangup}),
    notify(State#state{hungup = true, pending = #{}}, {event, Ev});
event(_Name, Ev, State) ->
    notify(State, {event, Ev}).

not_running(AppUuid, #state{running = AppUuid} = State) ->
    State#state{running = undefined};
not_running(_AppUuid, State) ->
    State.

%% A timed out application is stopped once it runs (uuid_break stops the
%% media it plays or records).
break_if_running(AppUuid, #state{running = AppUuid, cancelled = C} = State) when
    is_map_key(AppUuid, C)
->
    #state{conn = Conn, uuid = Uuid} = State,
    ok = chappe_esl_exec:break(Conn, Uuid, current),
    State;
break_if_running(_AppUuid, State) ->
    State.

%% A sync_exec waiter is answered ok or the error; an exec waiter gets the
%% completion event.
reply({sync, From}, Reply) ->
    gen_server:reply(From, done(Reply));
reply(From, Reply) ->
    gen_server:reply(From, Reply).

fail_pending(P, Reply) ->
    maps:foreach(
        fun(_AppUuid, {From, TRef}) ->
            _ = erlang:cancel_timer(TRef),
            reply(From, Reply)
        end,
        P
    ).

notify(#state{owner = Owner} = State, Msg) ->
    Owner ! {?MODULE, self(), Msg},
    State.

closed(#state{pending = P} = State) ->
    fail_pending(P, {error, closed}),
    _ = notify(State, closed),
    {stop, normal, State#state{pending = #{}}}.

%% The owner is gone: stop what this process started, then the channel.
cleanup(#state{cleanup = false}) ->
    ok;
cleanup(#state{hungup = true}) ->
    ok;
cleanup(#state{conn = Conn, uuid = Uuid, forks = Forks, recordings = Recs}) ->
    Cmds =
        [fork_stop_cmd(M, Uuid) || M <- Forks] ++
            [
                [
                    <<"uuid_record ">>,
                    Uuid,
                    <<" stop ">>,
                    chappe_esl_exec:arg(Path)
                ]
             || Path <- lists:reverse(Recs)
            ] ++
            [[<<"uuid_kill ">>, Uuid]],
    lists:foreach(
        fun(Cmd) -> _ = chappe_esl:api(Conn, Cmd, ?CLEANUP_TIMEOUT) end, Cmds
    ).

channel_uuid(Conn, Opts) ->
    case {chappe_esl_conn:channel(Conn), maps:get(uuid, Opts, undefined)} of
        {undefined, undefined} ->
            {error, {missing_option, uuid}};
        {undefined, Uuid} ->
            {ok, inbound, to_bin(Uuid)};
        {Channel, undefined} ->
            case chappe_esl_exec:channel_uuid(Channel) of
                undefined -> {error, no_channel_uuid};
                Uuid -> {ok, outbound, Uuid}
            end;
        {_Channel, Uuid} ->
            {ok, outbound, to_bin(Uuid)}
    end.

subscribe(outbound, Conn, _Uuid) ->
    chappe_esl:myevents(Conn, plain);
subscribe(inbound, Conn, Uuid) ->
    case chappe_esl:filter(Conn, [<<"Unique-ID ">>, Uuid]) of
        ok -> chappe_esl:subscribe(Conn, ['ALL']);
        Error -> Error
    end.

fork_module(#{module := audio_fork}) -> {ok, audio_fork};
fork_module(#{module := audio_stream}) -> {ok, audio_stream};
fork_module(#{module := _}) -> error;
fork_module(#{}) -> {ok, audio_fork}.

%% uuid_<api> <uuid> start <url> <mix> <rate> [metadata]
fork_start_cmd(Module, Uuid, Url, Opts) ->
    Mix = atom_to_binary(maps:get(mix, Opts, mono)),
    Rate = fork_rate(Module, maps:get(rate, Opts, 16000)),
    Meta =
        case maps:get(metadata, Opts, undefined) of
            undefined -> [];
            M -> [<<" ">>, fork_metadata(Module, chappe_esl_exec:arg(M))]
        end,
    [
        fork_api(Module),
        <<" ">>,
        Uuid,
        <<" start ">>,
        Url,
        <<" ">>,
        Mix,
        <<" ">>,
        Rate,
        Meta
    ].

fork_stop_cmd(Module, Uuid) ->
    [fork_api(Module), <<" ">>, Uuid, <<" stop">>].

fork_api(audio_fork) -> <<"uuid_audio_fork">>;
fork_api(audio_stream) -> <<"uuid_audio_stream">>.

%% mod_audio_stream names its two classic rates 8k and 16k (the only forms
%% its first releases parse); other rates and mod_audio_fork take the number.
fork_rate(audio_stream, 8000) -> <<"8k">>;
fork_rate(audio_stream, 16000) -> <<"16k">>;
fork_rate(_Module, Rate) -> int(Rate).

%% mod_audio_fork reads the metadata after the bug name (its default,
%% audio_fork); mod_audio_stream reads it right after the rate.
fork_metadata(audio_fork, Meta) -> [<<"audio_fork ">>, Meta];
fork_metadata(audio_stream, Meta) -> Meta.

%% Nothing tracked: send the mod_audio_fork stop, as before modules existed.
stop_modules([]) -> [audio_fork];
stop_modules(Forks) -> Forks.

first_error(Replies) ->
    case [E || E <- Replies, E =/= ok] of
        [] -> ok;
        [Error | _] -> Error
    end.

exec_opts(Opts) ->
    maps:with([timeout, wait, lock, loops], Opts).

done({ok, _}) -> ok;
done(Error) -> Error.

ok({ok, _}) -> ok;
ok(Error) -> Error.

join(Parts) ->
    lists:join(<<" ">>, Parts).

int(N) when is_integer(N) -> integer_to_binary(N);
int(Other) -> Other.

to_bin(undefined) -> <<>>;
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(L) -> iolist_to_binary(L).
