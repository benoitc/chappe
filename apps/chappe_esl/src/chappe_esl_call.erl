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
-define(DIGITS_VAR, <<"chappe_digits">>).
%% mod_say's say types (switch_ivr_get_say_type_by_name).
-define(SAY_TYPES, [
    number,
    items,
    persons,
    messages,
    currency,
    time_measurement,
    current_date,
    current_time,
    current_date_time,
    short_date_time,
    telephone_number,
    telephone_extension,
    url,
    ip_address,
    email_address,
    postal_address,
    account_number,
    name_spelled,
    name_phonetic
]).

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
    case event_names(Events, [], []) of
        {ok, []} -> ok;
        {ok, Names} -> call(Call, {subscribe, Names});
        error -> {error, {bad_option, events}}
    end.

%% FreeSWITCH reads every word after CUSTOM as a subclass: CUSTOM goes last.
event_names([], Names, []) ->
    {ok, lists:reverse(Names)};
event_names([], Names, Subs) ->
    {ok, lists:reverse(Names) ++ [<<"CUSTOM">> | lists:reverse(Subs)]};
event_names([{custom, Sub} | T], Names, Subs) ->
    case event_word(Sub) of
        true -> event_names(T, Names, [Sub | Subs]);
        false -> error
    end;
event_names([Name | T], Names, Subs) when is_atom(Name) ->
    event_names([atom_to_binary(Name) | T], Names, Subs);
event_names([<<"CUSTOM">> | _], _Names, _Subs) ->
    error;
event_names([Name | T], Names, Subs) ->
    case event_word(Name) of
        true -> event_names(T, [Name | Names], Subs);
        false -> error
    end.

%% One word of an event command: no blank, no line break.
-spec event_word(term()) -> boolean().
event_word(W) when is_binary(W), W =/= <<>> ->
    binary:match(W, [<<" ">>, <<"\t">>, <<"\n">>, <<"\r">>]) =:= nomatch;
event_word(_) ->
    false.

%% Typed helpers

-spec answer(call()) -> ok | {error, term()}.
answer(Call) ->
    done(exec(Call, <<"answer">>, <<>>)).

%% Play a file; the completion event's Application-Response says how it
%% ended (FILE PLAYED, FILE NOT FOUND, PLAYBACK ERROR) and its
%% variable_playback_ms how long it played.
-spec playback(call(), iodata()) -> {ok, event()} | {error, term()}.
playback(Call, File) ->
    playback(Call, File, #{}).

%% Opts, besides exec_opts: offset (start this many samples into the file,
%% FreeSWITCH's File@@Samples), limit_secs (stop after this many seconds,
%% at least 2, through playback_timeout_sec; the playback then still ends
%% as FILE PLAYED). A bad value returns {error, {bad_option, Key}}.
-spec playback(call(), iodata(), playback_opts()) ->
    {ok, event()} | {error, term()}.
playback(Call, File, Opts) ->
    case chappe_esl_exec:expands(File) orelse playback_args(File, Opts) of
        true ->
            {error, {bad_option, file}};
        {ok, Arg, undefined} ->
            exec(Call, <<"playback">>, Arg, exec_opts(Opts));
        {ok, Arg, Secs} ->
            limited_playback(Call, Arg, Secs, exec_opts(Opts));
        {error, _} = Err ->
            Err
    end.

playback_args(File, Opts) ->
    case {maps:get(offset, Opts, 0), maps:get(limit_secs, Opts, undefined)} of
        {Off, _} when not is_integer(Off); Off < 0 ->
            {error, {bad_option, offset}};
        {_, Secs} when Secs =/= undefined, not is_integer(Secs) ->
            {error, {bad_option, limit_secs}};
        {_, Secs} when is_integer(Secs), Secs < 2 ->
            {error, {bad_option, limit_secs}};
        {0, Secs} ->
            {ok, File, Secs};
        {Off, Secs} ->
            {ok, [File, <<"@@">>, integer_to_binary(Off)], Secs}
    end.

%% FreeSWITCH reads the limit from the channel: set before, cleared after,
%% one application after the other (event-lock).
limited_playback(Call, Arg, Secs, Opts) ->
    Vars = [
        <<"playback_timeout_sec=">>,
        integer_to_binary(Secs),
        <<" playback_timeout_as_success=true">>
    ],
    case exec(Call, <<"multiset">>, Vars) of
        {ok, _} ->
            Result = exec(Call, <<"playback">>, Arg, Opts),
            _ = exec(Call, <<"unset">>, <<"playback_timeout_sec">>),
            Result;
        Error ->
            Error
    end.

%% Play a prompt and collect digits. Opts: file (required), min (1), max
%% (1), tries (1), timeout (5000 ms), terminators (<<"#">>), invalid_file
%% (silence_stream://250), regexp (<<"[0-9*#]+">>), digit_timeout (timeout),
%% var (chappe_digits), plus exec_opts. Returns the digits FreeSWITCH stored
%% in var, <<>> when none were entered. With result => full it returns
%% #{digits, terminator, invalid}: the terminator pressed (<<>> for none,
%% from read_terminator_used) and the last entry the regexp refused (<<>>
%% for none, from <var>_invalid).
-spec play_and_get_digits(call(), map()) ->
    {ok, binary() | digits()} | {error, term()}.
play_and_get_digits(Call, #{file := File} = Opts) ->
    Text = [
        File,
        maps:get(invalid_file, Opts, <<>>),
        maps:get(terminators, Opts, <<>>),
        maps:get(regexp, Opts, <<>>)
    ],
    case lists:any(fun chappe_esl_exec:expands/1, Text) of
        true -> {error, {bad_option, file}};
        false -> collect(Call, File, Opts)
    end.

collect(Call, File, Opts) ->
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
            V = fun(Name) ->
                to_bin(
                    chappe_esl_event:header(<<"variable_", Name/binary>>, Ev)
                )
            end,
            case maps:get(result, Opts, digits) of
                full ->
                    {ok, #{
                        digits => V(Var),
                        terminator => V(<<"read_terminator_used">>),
                        invalid => V(<<Var/binary, "_invalid">>)
                    }};
                _ ->
                    {ok, V(Var)}
            end;
        Error ->
            Error
    end.

%% Record the caller to Path. Opts: max_secs, silence_thresh, silence_hits
%% (record's optional arguments), plus exec_opts.
-spec record(call(), iodata(), map()) -> {ok, event()} | {error, term()}.
record(Call, Path, Opts) ->
    case chappe_esl_exec:expands(Path) of
        true -> {error, {bad_option, path}};
        false -> record_file(Call, Path, Opts)
    end.

record_file(Call, Path, Opts) ->
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
    case chappe_esl_exec:expands(Path) of
        true -> {error, {bad_option, path}};
        false -> call(Call, {record_session, to_bin(Path)})
    end.

-spec record_session_stop(call(), iodata()) -> ok | {error, term()}.
record_session_stop(Call, Path) ->
    call(Call, {record_session_stop, to_bin(Path)}).

%% Send DTMF digits to the far end (the send_dtmf application).
-spec send_dtmf(call(), iodata()) -> ok | {error, term()}.
send_dtmf(Call, Digits) ->
    case chappe_esl_exec:expands(Digits) of
        true -> {error, {bad_option, digits}};
        false -> done(exec(Call, <<"send_dtmf">>, Digits))
    end.

-spec set(call(), iodata(), iodata()) -> ok | {error, term()}.
set(Call, Var, Value) ->
    var_app(Call, <<"set">>, Var, Value).

%% set and export: neither the name nor the value may expand.
var_app(Call, App, Var, Value) ->
    case {chappe_esl_exec:expands(Var), chappe_esl_exec:expands(Value)} of
        {true, _} -> {error, {bad_option, var}};
        {_, true} -> {error, {bad_option, value}};
        _ -> done(exec(Call, App, [Var, $=, Value]))
    end.

%% Set a variable on the channel and on the channel it gets bridged to.
-spec export(call(), iodata(), iodata()) -> ok | {error, term()}.
export(Call, Var, Value) ->
    var_app(Call, <<"export">>, Var, Value).

%% Say Text with mod_say: a number, a date, digits, by language. Opts:
%% language (<<"en">>, the mod_say module that speaks it), type (number:
%% number | items | persons | messages | currency | time_measurement |
%% current_date | current_time | current_date_time | short_date_time |
%% telephone_number | telephone_extension | url | ip_address |
%% email_address | postal_address | account_number | name_spelled |
%% name_phonetic), method (pronounced: pronounced | iterated | counted),
%% gender (masculine | feminine | neuter), plus exec_opts. The module plays
%% sound files from the channel's sound_prefix; a missing one is skipped.
-spec say(call(), iodata(), map()) -> ok | {error, term()}.
say(Call, Text, Opts) ->
    case say_args(to_bin(Text), Opts) of
        {ok, Arg} -> done(exec(Call, <<"say">>, Arg, exec_opts(Opts)));
        {error, _} = Err -> Err
    end.

say_args(Text, Opts) ->
    Lang =
        case maps:get(language, Opts, <<"en">>) of
            L when is_atom(L) -> atom_to_binary(L);
            L -> L
        end,
    Type = maps:get(type, Opts, number),
    Method = maps:get(method, Opts, pronounced),
    Gender = maps:get(gender, Opts, undefined),
    check_say(Text, Lang, Type, Method, Gender).

check_say(Text, Lang, Type, Method, Gender) ->
    case
        {
            tts_word(Lang),
            lists:member(Type, ?SAY_TYPES),
            lists:member(Method, [pronounced, iterated, counted]),
            lists:member(Gender, [undefined, masculine, feminine, neuter]),
            Text =/= <<>> andalso one_line(Text)
        }
    of
        {false, _, _, _, _} ->
            {error, {bad_option, language}};
        {_, false, _, _, _} ->
            {error, {bad_option, type}};
        {_, _, false, _, _} ->
            {error, {bad_option, method}};
        {_, _, _, false, _} ->
            {error, {bad_option, gender}};
        {_, _, _, _, false} ->
            {error, {bad_option, text}};
        _ ->
            G = [[atom_to_binary(Gender), <<" ">>] || Gender =/= undefined],
            {ok, [
                Lang,
                <<" ">>,
                atom_to_binary(Type),
                <<" ">>,
                atom_to_binary(Method),
                <<" ">>,
                G,
                chappe_esl_exec:arg(Text)
            ]}
    end.

%% Speak Text with a text to speech module (the speak application). Opts:
%% engine (the module, as <<"flite">>) and voice (as <<"kal">>), both
%% defaulting to the channel's tts_engine and tts_voice, plus exec_opts.
%% An engine needs a voice. Text with a `|' needs both, which FreeSWITCH
%% would otherwise read as separators.
-spec speak(call(), iodata(), map()) -> ok | {error, term()}.
speak(Call, Text0, Opts) ->
    Text = to_bin(Text0),
    Engine = maps:get(engine, Opts, undefined),
    Voice = maps:get(voice, Opts, undefined),
    Pipe = binary:match(Text, <<"|">>) =/= nomatch,
    Valid = fun
        (undefined) -> true;
        (W) -> tts_word(W)
    end,
    case {Valid(Engine), Valid(Voice), Text =/= <<>> andalso one_line(Text)} of
        {false, _, _} ->
            {error, {bad_option, engine}};
        {_, false, _} ->
            {error, {bad_option, voice}};
        {_, _, false} ->
            {error, {bad_option, text}};
        _ when Engine =/= undefined, Voice =:= undefined ->
            {error, {bad_option, voice}};
        _ when Pipe, Engine =:= undefined ->
            {error, {bad_option, text}};
        _ ->
            Arg =
                case {Engine, Voice} of
                    {undefined, undefined} -> Text;
                    {undefined, V} -> [V, $|, Text];
                    {E, V} -> [E, $|, V, $|, Text]
                end,
            done(exec(Call, <<"speak">>, Arg, exec_opts(Opts)))
    end.

tts_word(W) when is_binary(W) ->
    event_word(W) andalso binary:match(W, [<<"|">>, <<"'">>]) =:= nomatch;
tts_word(_) ->
    false.

%% One line of text that FreeSWITCH takes as it is: no line break, nothing
%% it would expand (chappe_esl_exec:expands/1).
one_line(Text) ->
    binary:match(Text, [<<"\n">>, <<"\r">>]) =:= nomatch andalso
        not chappe_esl_exec:expands(Text).

%% Listen for the tones of a mod_spandsp tone descriptor (Name, from the
%% node's spandsp.conf): the owner gets {tone, ToneName} each time one is
%% heard, until stop_detect_tones/1 or the hangup.
-spec detect_tones(call(), iodata()) -> ok | {error, term()}.
detect_tones(Call, Name) ->
    case tts_word(to_bin(Name)) of
        true ->
            detector(
                Call, <<"spandsp_start_tone_detect">>, Name, <<"+OK started">>
            );
        false ->
            {error, {bad_option, name}}
    end.

-spec stop_detect_tones(call()) -> ok | {error, term()}.
stop_detect_tones(Call) ->
    done(exec(Call, <<"spandsp_stop_tone_detect">>, <<>>)).

%% Listen for a fax (mod_spandsp): the owner gets {fax, detected} once.
%% Opts: tone (cng, the calling fax, default; ced, the answering one),
%% timeout (seconds to listen, 0 for no limit, the default).
-spec detect_fax(call(), map()) -> ok | {error, term()}.
detect_fax(Call, Opts) ->
    case {maps:get(tone, Opts, cng), maps:get(timeout, Opts, 0)} of
        {Tone, _} when Tone =/= cng, Tone =/= ced ->
            {error, {bad_option, tone}};
        {_, Secs} when not is_integer(Secs); Secs < 0 ->
            {error, {bad_option, timeout}};
        {Tone, Secs} ->
            %% the application runs `set' when it hears the tone, and
            %% fires the DETECTED_TONE the owner hears
            Arg = [
                <<"set chappe_fax_detected=true ">>,
                integer_to_binary(Secs),
                <<" ">>,
                atom_to_binary(Tone)
            ],
            detector(Call, <<"spandsp_start_fax_detect">>, Arg, undefined)
    end.

-spec stop_detect_fax(call()) -> ok | {error, term()}.
stop_detect_fax(Call) ->
    done(exec(Call, <<"spandsp_stop_fax_detect">>, <<>>)).

detector(Call, App, Arg, Expect) ->
    case subscribe(Call, [<<"DETECTED_TONE">>]) of
        ok ->
            case {exec(Call, App, Arg), Expect} of
                {{ok, _}, undefined} ->
                    ok;
                {{ok, Ev}, _} ->
                    case
                        chappe_esl_event:header(<<"Application-Response">>, Ev)
                    of
                        Expect -> ok;
                        Other -> {error, to_bin(Other)}
                    end;
                {Error, _} ->
                    Error
            end;
        Error ->
            Error
    end.

%% Set several variables at once (multiset). Names are words without `=';
%% the values are split on a delimiter none of them contains. At most 256
%% variables, as multiset takes.
-spec multiset(call(), #{iodata() => iodata()}) -> ok | {error, term()}.
multiset(_Call, Vars) when map_size(Vars) =:= 0 ->
    ok;
multiset(Call, Vars) when is_map(Vars), map_size(Vars) =< 256 ->
    Pairs = [{to_bin(K), to_bin(V)} || K := V <- Vars],
    case lists:all(fun valid_var/1, Pairs) andalso delimiter(Pairs) of
        false ->
            {error, {bad_option, vars}};
        none ->
            {error, {bad_option, vars}};
        Delim ->
            Arg = [
                <<"^^">>,
                Delim,
                lists:join(Delim, [[K, $=, V] || {K, V} <- lists:sort(Pairs)])
            ],
            done(exec(Call, <<"multiset">>, Arg))
    end;
multiset(_Call, _Vars) ->
    {error, {bad_option, vars}}.

valid_var({K, V}) ->
    event_word(K) andalso binary:match(K, <<"=">>) =:= nomatch andalso
        one_line(V).

delimiter(Pairs) ->
    Used = iolist_to_binary([[K, V] || {K, V} <- Pairs]),
    case
        [
            D
         || D <- [<<"|">>, <<"~">>, <<"^">>, <<";">>, <<"#">>, <<"!">>],
            binary:match(Used, D) =:= nomatch
        ]
    of
        [D | _] -> D;
        [] -> none
    end.

%% A channel variable (uuid_getvar): undefined when it is not set.
-spec getvar(call(), iodata()) -> {ok, binary() | undefined} | {error, term()}.
getvar(Call, Var) ->
    case event_word(to_bin(Var)) of
        true ->
            case
                with_uuid(Call, fun(U) ->
                    api(Call, [<<"uuid_getvar ">>, U, $\s, Var])
                end)
            of
                {ok, <<"_undef_">>} -> {ok, undefined};
                {ok, Value} -> {ok, Value};
                Error -> Error
            end;
        false ->
            {error, {bad_option, var}}
    end.

%% Every variable of the channel (uuid_dump json), without the variable_
%% prefix FreeSWITCH puts on them.
-spec dump(call()) -> {ok, #{binary() => binary()}} | {error, term()}.
dump(Call) ->
    case
        with_uuid(Call, fun(U) ->
            api(Call, [<<"uuid_dump ">>, U, <<" json">>])
        end)
    of
        {ok, Json} ->
            try json:decode(Json) of
                #{} = M ->
                    {ok,
                        #{
                            K => to_bin(V)
                         || <<"variable_", K/binary>> := V <- M, is_binary(V)
                        }};
                _ ->
                    {error, {bad_reply, Json}}
            catch
                error:_ -> {error, {bad_reply, Json}}
            end;
        Error ->
            Error
    end.

%% Mute what the channel reads (the caller's audio) or writes (what the
%% caller hears), with uuid_audio; unmute/2 takes it back.
-spec mute(call(), read | write) -> ok | {error, term()}.
mute(Call, Dir) ->
    audio(Call, Dir, <<"1">>).

-spec unmute(call(), read | write) -> ok | {error, term()}.
unmute(Call, Dir) ->
    audio(Call, Dir, <<"0">>).

audio(Call, Dir, Level) when Dir =:= read; Dir =:= write ->
    with_uuid(Call, fun(U) ->
        ok(
            api(Call, [
                <<"uuid_audio ">>,
                U,
                <<" start ">>,
                atom_to_binary(Dir),
                <<" mute ">>,
                Level
            ])
        )
    end);
audio(_Call, _Dir, _Level) ->
    {error, {bad_option, direction}}.

with_uuid(Call, Fun) ->
    case call(Call, uuid) of
        Uuid when is_binary(Uuid) -> Fun(Uuid);
        Error -> Error
    end.

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
%% server as the first text frame), bugname (mod_audio_fork only: the name
%% of this fork's media bug, so one channel can run several forks; default
%% audio_fork). An unknown module returns {error, {bad_option, module}}, a
%% bugname on mod_audio_stream {error, {bad_option, bugname}}. A stereo
%% fork of mod_audio_stream sends only while both directions carry audio
%% (FreeSWITCH's and the module's behaviour): mono or mixed send whenever
%% the caller does.
-spec audio_fork_start(call(), iodata(), map()) -> ok | {error, term()}.
audio_fork_start(Call, Url, Opts) ->
    case fork_key(Opts) of
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
    Cmds =
        [chappe_esl_exec:fork_ctl_cmd(M, Uuid, B, stop) || {M, B} <- Forks] ++
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

fork_key(Opts) ->
    case {fork_module(Opts), maps:get(bugname, Opts, undefined)} of
        {error, _} -> {error, {bad_option, module}};
        {{ok, M}, undefined} -> {ok, {M, undefined}};
        {{ok, audio_stream}, _} -> {error, {bad_option, bugname}};
        {{ok, audio_fork}, Bug} -> fork_bug(to_bin(Bug))
    end.

%% A bug name is one word FreeSWITCH reads back as is.
fork_bug(Bug) ->
    case event_word(Bug) andalso binary:match(Bug, [<<"'">>, <<"\\">>]) of
        nomatch -> {ok, {audio_fork, Bug}};
        _ -> {error, {bad_option, bugname}}
    end.

fork_module(#{module := audio_fork}) -> {ok, audio_fork};
fork_module(#{module := audio_stream}) -> {ok, audio_stream};
fork_module(#{module := _}) -> error;
fork_module(#{}) -> {ok, audio_fork}.

%% Nothing tracked: send the mod_audio_fork stop, as before modules existed.
stop_keys([]) -> [{audio_fork, undefined}];
stop_keys(Forks) -> Forks.

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
