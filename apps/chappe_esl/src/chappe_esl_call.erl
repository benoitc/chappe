%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Typed call control over the event socket.
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
%%   {tone, Name}              a tone of detect_tones/2 was heard
%%   {fax, detected}           a fax tone of detect_fax/2 was heard
%%   {event, Event}            any other event of the channel
%%   linger                    the channel hung up; the final events still
%%                             follow and the socket stays open
%%   disconnect                FreeSWITCH sends nothing more on this connection
%%   closed                    the connection is gone; the process stops
%%
%% The call process never waits on the connection while the call runs: each
%% command that does (api, a fork command, the sendmsg of an exec, uuid_break)
%% runs in a helper process that exits with its result, and the caller is
%% answered when the helper ends. Timers, other callers and owner death are
%% handled meanwhile. FreeSWITCH itself runs a synchronous api on the thread
%% that sends this connection's events, so a slow api still holds them back on
%% the node: slow commands belong in bgapi.
%%
%% When the owner dies before the channel hangs up, the call process stops
%% the audio forks (each with its module's stop) and session recordings it
%% started, kills the channel with uuid_kill, and closes the connection.
-module(chappe_esl_call).
-behaviour(gen_server).

%% Raw execute on a connection.
-export([exec/5]).
%% Call process.
-export([start/1, start/2, stop/1, uuid/1, ref/1]).
-export([exec/3, exec/4, api/2, subscribe/2, event_word/1]).
%% Typed helpers.
-export([answer/1, playback/2, playback/3, play_and_get_digits/2]).
-export([record/3, record_session/2, record_session_stop/2]).
-export([send_dtmf/2, set/3, export/3, hangup/1, hangup/2]).
-export([multiset/2, getvar/2, dump/1, mute/2, unmute/2]).
-export([say/3, speak/3, detect_tones/2, stop_detect_tones/1]).
-export([detect_fax/2, stop_detect_fax/1]).
-export([conference/2, conference/3, audio_fork_start/3, audio_fork_stop/1]).
-export([audio_fork_stop/2, audio_fork_pause/2, audio_fork_resume/2]).
-export([audio_fork_send_text/3]).
%% gen_server.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([call/0, exec_opts/0, playback_opts/0, digits/0]).
-export_type([start_opts/0, msg/0, fork_module/0, fork_select/0]).

-define(EXEC_TIMEOUT, 60000).
-define(CLEANUP_TIMEOUT, 2000).

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
%% playback/3: exec_opts plus offset (samples) and limit_secs.
-type playback_opts() :: #{
    timeout => timeout(),
    wait => boolean(),
    lock => boolean(),
    loops => pos_integer(),
    offset => non_neg_integer(),
    limit_secs => pos_integer()
}.
%% play_and_get_digits/2 with result => full.
-type digits() :: #{
    digits := binary(), terminator := binary(), invalid := binary()
}.
%% owner: the process that gets the messages and whose death ends the call
%% (the caller). uuid: the channel, required on an inbound connection.
%% cleanup: on owner death, stop forks and recordings and kill the channel
%% (true). ref: an opaque binary (a call ref), returned by ref/1; the
%% messages to the owner keep their {chappe_esl_call, Call, Msg} shape.
-type start_opts() :: #{
    owner => pid(), uuid => binary(), cleanup => boolean(), ref => binary()
}.
%% audio_fork: mod_audio_fork (uuid_audio_fork); audio_stream:
%% mod_audio_stream (uuid_audio_stream).
-type fork_module() :: audio_fork | audio_stream.
%% A fork this call runs: its module and its bug name (undefined: the
%% module default).
-type fork() :: {fork_module(), binary() | undefined}.
%% Which forks a fork command names: by module, by bug name, or all.
-type fork_select() :: #{module => fork_module(), bugname => binary()}.
-type msg() ::
    {dtmf, binary()}
    | {hangup, binary()}
    | {complete, binary(), event()}
    | {tone, binary()}
    | {fax, detected}
    | {event, event()}
    | linger
    | disconnect
    | closed.

-record(state, {
    conn :: pid(),
    conn_mon :: reference(),
    uuid :: binary(),
    owner :: pid(),
    owner_mon :: reference(),
    cleanup :: boolean(),
    ref :: binary() | undefined,
    hungup = false :: boolean(),
    %% the fork modules started, oldest first
    forks = [] :: [fork()],
    recordings = [] :: [binary()],
    %% the application running now (its Application-UUID), and the timed
    %% out ones: broken when they run, their completion dropped
    running :: binary() | undefined,
    cancelled = #{} :: #{binary() => true},
    pending = #{} :: #{binary() => {waiter(), reference()}},
    %% the helpers running, by monitor
    jobs = #{} :: #{reference() => job()}
}).

-type state() :: #state{}.
%% {sync, From}: a helper that answers ok instead of the event.
-type waiter() :: gen_server:from() | {sync, gen_server:from()}.
%% What to do with a helper's result.
%% reply: hand it to the caller.
%% fork_start: also settle the fork; the boolean says one was already running.
%% exec_sent: the waiter is in `pending', only a failure concerns it.
%% exec_accepted: wait => false, the caller gets the uuid once accepted.
-type job() ::
    {reply, gen_server:from()}
    | {fork_start, gen_server:from(), fork(), boolean()}
    | {exec_sent, binary()}
    | {exec_accepted, gen_server:from(), binary()}
    | ignore.

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
start(_Conn, #{ref := Ref}) when not is_binary(Ref) ->
    {error, {bad_option, ref}};
start(Conn, Opts) ->
    Owner = maps:get(owner, Opts, self()),
    gen_server:start(?MODULE, {Conn, Owner, Opts}, []).

%% The ref given at start, undefined without one.
-spec ref(call()) -> binary() | undefined | {error, closed}.
ref(Call) ->
    call(Call, ref).

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

%% Add events of the channel to what the owner gets as {event, Event}:
%% event names (<<"PLAYBACK_START">>, 'DETECTED_TONE') and {custom,
%% Subclass} for a CUSTOM subclass. The call's own subscription (myevents,
%% or the Unique-ID filter on inbound) still limits them to this channel.
-spec subscribe(call(), [atom() | binary() | {custom, binary()}]) ->
    ok | {error, term()}.
subscribe(Call, Events) ->
    case chappe_esl_exec:event_names(Events) of
        {ok, []} -> ok;
        {ok, Names} -> call(Call, {subscribe, Names});
        error -> {error, {bad_option, events}}
    end.

%% One word of an event command: no blank, no line break.
-spec event_word(term()) -> boolean().
event_word(W) -> chappe_esl_exec:event_word(W).

%% Typed helpers: the verbs live in chappe_esl_verbs, which documents and
%% types their options and replies.

answer(Call) -> chappe_esl_verbs:answer(Call).

playback(Call, File) -> chappe_esl_verbs:playback(Call, File).

playback(Call, File, Opts) -> chappe_esl_verbs:playback(Call, File, Opts).

play_and_get_digits(Call, Opts) ->
    chappe_esl_verbs:play_and_get_digits(Call, Opts).

record(Call, Path, Opts) -> chappe_esl_verbs:record(Call, Path, Opts).

%% Start recording the whole session (both directions) to Path. The
%% recording runs until record_session_stop/2 or the hangup.
-spec record_session(call(), iodata()) -> ok | {error, term()}.
record_session(Call, Path) ->
    case chappe_esl_exec:expands(Path) of
        true -> {error, {bad_option, path}};
        false -> call(Call, {record_session, to_bin(Path)})
    end.

-spec record_session_stop(call(), iodata()) -> ok | {error, term()}.
record_session_stop(Call, Path) ->
    call(Call, {record_session_stop, to_bin(Path)}).

-spec send_dtmf(call(), iodata()) -> ok | {error, term()}.
send_dtmf(Call, Digits) -> chappe_esl_verbs:send_dtmf(Call, Digits).

set(Call, Var, Value) -> chappe_esl_verbs:set(Call, Var, Value).

export(Call, Var, Value) -> chappe_esl_verbs:export(Call, Var, Value).

say(Call, Text, Opts) -> chappe_esl_verbs:say(Call, Text, Opts).

speak(Call, Text, Opts) -> chappe_esl_verbs:speak(Call, Text, Opts).

detect_tones(Call, Name) -> chappe_esl_verbs:detect_tones(Call, Name).

stop_detect_tones(Call) -> chappe_esl_verbs:stop_detect_tones(Call).

detect_fax(Call, Opts) -> chappe_esl_verbs:detect_fax(Call, Opts).

stop_detect_fax(Call) -> chappe_esl_verbs:stop_detect_fax(Call).

multiset(Call, Vars) -> chappe_esl_verbs:multiset(Call, Vars).

getvar(Call, Var) -> chappe_esl_verbs:getvar(Call, Var).

dump(Call) -> chappe_esl_verbs:dump(Call).

mute(Call, Dir) -> chappe_esl_verbs:mute(Call, Dir).

unmute(Call, Dir) -> chappe_esl_verbs:unmute(Call, Dir).

hangup(Call) -> chappe_esl_verbs:hangup(Call).

hangup(Call, Cause) -> chappe_esl_verbs:hangup(Call, Cause).

conference(Call, Room) -> chappe_esl_verbs:conference(Call, Room).

conference(Call, Room, Opts) -> chappe_esl_verbs:conference(Call, Room, Opts).

%% Fork the channel audio to a websocket. Opts: module (audio_fork, the
%% default, for mod_audio_fork, or audio_stream for mod_audio_stream), mix
%% (mono | mixed | stereo, default mono), rate (16000), metadata (sent to the
%% server as the first text frame), bugname (mod_audio_fork only: the name
%% of this fork's media bug, so one channel can run several forks; default
%% audio_fork). An unknown module returns {error, {bad_option, module}}, a
%% bugname on mod_audio_stream {error, {bad_option, bugname}}. A stereo
%% fork of mod_audio_stream sends only while both directions carry audio
%% (FreeSWITCH's and the module's behaviour): mono or mixed send whenever
%% the caller does.
-spec audio_fork_start(call(), iodata(), map()) -> ok | {error, term()}.
audio_fork_start(Call, Url, Opts) ->
    case chappe_esl_exec:fork_key(Opts) of
        {ok, Key} -> call(Call, {fork_start, Key, Url, Opts});
        {error, _} = Err -> Err
    end.

%% Stop the forks this call started, each with its module's command
%% (uuid_audio_fork stop when none was started).
-spec audio_fork_stop(call()) -> ok | {error, term()}.
audio_fork_stop(Call) ->
    call(Call, fork_stop).

%% The fork commands on the forks this call started that Sel names
%% (module, bugname; an empty map names them all). Both modules take stop,
%% pause, resume and send_text; pause keeps the WebSocket open and stops
%% the audio, resume sends it again, and send_text sends Text to the
%% server as a text frame. No fork named: {error, not_forking}.
-spec audio_fork_stop(call(), fork_select()) -> ok | {error, term()}.
audio_fork_stop(Call, Sel) ->
    fork_ctl(Call, Sel, stop).

-spec audio_fork_pause(call(), fork_select()) -> ok | {error, term()}.
audio_fork_pause(Call, Sel) ->
    fork_ctl(Call, Sel, pause).

-spec audio_fork_resume(call(), fork_select()) -> ok | {error, term()}.
audio_fork_resume(Call, Sel) ->
    fork_ctl(Call, Sel, resume).

-spec audio_fork_send_text(call(), iodata(), fork_select()) ->
    ok | {error, term()}.
audio_fork_send_text(Call, Text, Sel) ->
    case binary:match(to_bin(Text), [<<"\n">>, <<"\r">>]) of
        nomatch -> fork_ctl(Call, Sel, {send_text, Text});
        _ -> {error, {bad_option, text}}
    end.

fork_ctl(Call, Sel, Verb) when is_map(Sel) ->
    call(Call, {fork_ctl, maps:with([module, bugname], Sel), Verb});
fork_ctl(_Call, _Sel, _Verb) ->
    {error, {bad_option, select}}.

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
                        cleanup = maps:get(cleanup, Opts, true),
                        ref = maps:get(ref, Opts, undefined)
                    }};
                {error, Reason} ->
                    {stop, {subscribe_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(ref, _From, #state{ref = Ref} = State) ->
    {reply, Ref, State};
handle_call(uuid, _From, #state{uuid = Uuid} = State) ->
    {reply, Uuid, State};
handle_call({exec, _App, _Args, _Opts}, _From, #state{hungup = true} = State) ->
    {reply, {error, hangup}, State};
handle_call({exec, App, Args, Opts}, From, State) ->
    start_exec(App, Args, Opts, From, State);
handle_call({subscribe, Names}, From, #state{conn = Conn} = State) ->
    {noreply,
        job(
            fun() -> chappe_esl:subscribe(Conn, Names) end, {reply, From}, State
        )};
handle_call({api, Cmd}, From, #state{conn = Conn} = State) ->
    {noreply,
        job(fun() -> chappe_esl:api(Conn, Cmd) end, {reply, From}, State)};
handle_call({record_session, Path}, From, #state{recordings = Recs} = State) ->
    %% tracked before it starts, so an owner dying meanwhile still stops it
    State1 = State#state{recordings = [Path | lists:delete(Path, Recs)]},
    sync_exec(<<"record_session">>, chappe_esl_exec:arg(Path), From, State1);
handle_call(
    {record_session_stop, Path}, From, #state{recordings = Recs} = State
) ->
    State1 = State#state{recordings = lists:delete(Path, Recs)},
    sync_exec(<<"stop_record_session">>, Path, From, State1);
handle_call({fork_start, {Module, _} = Key, Url, Opts}, From, State) ->
    #state{conn = Conn, uuid = Uuid, forks = Forks} = State,
    Cmd = chappe_esl_exec:fork_start_cmd(Module, Uuid, Url, Opts),
    Job = {fork_start, From, Key, lists:member(Key, Forks)},
    %% tracked before it starts, so an owner dying meanwhile still stops it
    State1 = State#state{forks = track_fork(Key, Forks)},
    {noreply, job(fun() -> ok(chappe_esl:api(Conn, Cmd)) end, Job, State1)};
handle_call(fork_stop, From, #state{forks = Forks} = State) ->
    {noreply, fork_cmds(stop_keys(Forks), stop, From, State#state{forks = []})};
handle_call({fork_ctl, Sel, Verb}, From, #state{forks = Forks} = State) ->
    case [F || F <- Forks, selected(Sel, F)] of
        [] ->
            {reply, {error, not_forking}, State};
        Targets when Verb =:= stop ->
            State1 = State#state{forks = Forks -- Targets},
            {noreply, fork_cmds(Targets, stop, From, State1)};
        Targets ->
            {noreply, fork_cmds(Targets, Verb, From, State)}
    end;
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
handle_info({'DOWN', Mon, process, _, Exit}, #state{jobs = Jobs} = State) ->
    case maps:take(Mon, Jobs) of
        {Job, Jobs1} ->
            State1 = State#state{jobs = Jobs1},
            {noreply, job_done(Job, job_result(Exit), State1)};
        error ->
            {noreply, State}
    end;
handle_info({chappe_esl_linger, Conn}, #state{conn = Conn} = State) ->
    {noreply, notify(State, linger)};
handle_info({chappe_esl_disconnect, Conn}, #state{conn = Conn} = State) ->
    {noreply, notify(State, disconnect)};
handle_info({chappe_esl_closed, Conn}, #state{conn = Conn} = State) ->
    closed(State);
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn = Conn, jobs = Jobs} = State) ->
    Done = fun(_Mon, Job, Acc) -> job_done(Job, {error, closed}, Acc) end,
    #state{pending = P} = maps:fold(Done, State, Jobs),
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

%% The helper's reply can come after the application's first events, so the
%% waiter is registered before the send.
start_exec(App, Args, Opts, From, #state{conn = Conn, uuid = Uuid} = State) ->
    AppUuid = chappe_esl_exec:app_uuid(),
    Send = fun() ->
        chappe_esl_exec:send(Conn, Uuid, AppUuid, App, Args, Opts)
    end,
    case maps:get(wait, Opts, true) of
        true ->
            Timeout = maps:get(timeout, Opts, ?EXEC_TIMEOUT),
            State1 = add_pending(AppUuid, From, Timeout, State),
            {noreply, job(Send, {exec_sent, AppUuid}, State1)};
        false ->
            {noreply, job(Send, {exec_accepted, From, AppUuid}, State)}
    end.

%% Run Fun in a helper. Its exit carries the result: exit/1 is not a crash,
%% nothing gets logged.
-dialyzer({nowarn_function, job/3}).
job(Fun, Job, #state{jobs = Jobs} = State) ->
    {_Pid, Mon} = spawn_monitor(fun() -> exit({?MODULE, Fun()}) end),
    State#state{jobs = Jobs#{Mon => Job}}.

job_result({?MODULE, Result}) -> Result;
job_result(_Abnormal) -> {error, closed}.

job_done({reply, From}, Result, State) ->
    gen_server:reply(From, Result),
    State;
job_done({fork_start, From, Module, Running}, Result, State) ->
    gen_server:reply(From, Result),
    fork_settled(Result, Module, Running, State);
job_done({exec_sent, _AppUuid}, ok, State) ->
    State;
job_done({exec_sent, _AppUuid}, {error, timeout}, State) ->
    %% the sendmsg is still queued behind a slow command and may run: the
    %% exec's own timeout rules, not the limit on this reply
    State;
job_done({exec_sent, AppUuid}, Error, #state{pending = P} = State) ->
    case maps:take(AppUuid, P) of
        {{Waiter, TRef}, P1} ->
            _ = erlang:cancel_timer(TRef),
            reply(Waiter, Error),
            State#state{pending = P1};
        error ->
            %% its timeout or the hangup already answered it
            State
    end;
job_done({exec_accepted, From, AppUuid}, ok, State) ->
    gen_server:reply(From, {ok, AppUuid}),
    State;
job_done({exec_accepted, From, _AppUuid}, Error, State) ->
    gen_server:reply(From, Error),
    State;
job_done(ignore, _Result, State) ->
    State.

%% A failed start only takes back the fork it added itself.
fork_settled(ok, Module, _Running, #state{forks = Forks} = State) ->
    State#state{forks = track_fork(Module, Forks)};
fork_settled(_Error, _Module, true, State) ->
    State;
fork_settled(_Error, Module, false, #state{forks = Forks} = State) ->
    State#state{forks = lists:delete(Module, Forks)}.

track_fork(Key, Forks) ->
    lists:delete(Key, Forks) ++ [Key].

%% One api command per fork, in a helper; the first error is the reply.
fork_cmds(Keys, Verb, From, #state{conn = Conn, uuid = Uuid} = State) ->
    Cmds = [chappe_esl_exec:fork_ctl_cmd(M, Uuid, B, Verb) || {M, B} <- Keys],
    Run = fun() ->
        first_error([ok(chappe_esl:api(Conn, Cmd)) || Cmd <- Cmds])
    end,
    job(Run, {reply, From}, State).

selected(Sel, {Module, Bug}) ->
    maps:get(module, Sel, Module) =:= Module andalso
        maps:get(bugname, Sel, Bug) =:= Bug.

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
event(<<"DETECTED_TONE">>, Ev, State) ->
    case
        {
            chappe_esl_event:header(<<"Detected-Tone">>, Ev),
            chappe_esl_event:header(<<"Detected-Fax-Tone">>, Ev)
        }
    of
        {Tone, _} when is_binary(Tone) -> notify(State, {tone, Tone});
        {_, <<"true">>} -> notify(State, {fax, detected});
        _ -> notify(State, {event, Ev})
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
    job(fun() -> chappe_esl_exec:break(Conn, Uuid, current) end, ignore, State);
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

%% The owner is gone: stop what this process started, then the channel. These
%% commands go out here, in order, behind what the helpers already sent; a
%% withheld reply costs each of them its CLEANUP_TIMEOUT at most.
cleanup(#state{cleanup = false}) ->
    ok;
cleanup(#state{hungup = true}) ->
    ok;
cleanup(#state{conn = Conn, uuid = Uuid, forks = Forks, recordings = Recs}) ->
    Cmds = chappe_esl_exec:cleanup_cmds(Uuid, Forks, lists:reverse(Recs)),
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

%% Nothing tracked: send the mod_audio_fork stop, as before modules existed.
stop_keys([]) -> [{audio_fork, undefined}];
stop_keys(Forks) -> Forks.

first_error(Replies) ->
    case [E || E <- Replies, E =/= ok] of
        [] -> ok;
        [Error | _] -> Error
    end.

done({ok, _}) -> ok;
done(Error) -> Error.

ok({ok, _}) -> ok;
ok(Error) -> Error.

to_bin(undefined) -> <<>>;
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(L) -> iolist_to_binary(L).
