%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The typed verbs of a call process (chappe_esl_call): each checks its
%% arguments, refuses text FreeSWITCH would expand, builds the dialplan
%% application or api command, and runs it with chappe_esl_call:exec/4 or
%% chappe_esl_call:api/2. chappe_esl_call exports every verb as well, so
%% callers keep using it; the call process itself stays in chappe_esl_call.
-module(chappe_esl_verbs).

-export([answer/1, playback/2, playback/3, play_and_get_digits/2]).
-export([record/3, send_dtmf/2, set/3, export/3, hangup/1, hangup/2]).
-export([multiset/2, getvar/2, dump/1, mute/2, unmute/2]).
-export([say/3, speak/3, detect_tones/2, stop_detect_tones/1]).
-export([detect_fax/2, stop_detect_fax/1, conference/2, conference/3]).

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

-spec answer(chappe_esl_call:call()) -> ok | {error, term()}.
answer(Call) ->
    done(exec(Call, <<"answer">>, <<>>)).

%% Play a file; the completion event's Application-Response says how it
%% ended (FILE PLAYED, FILE NOT FOUND, PLAYBACK ERROR) and its
%% variable_playback_ms how long it played.
-spec playback(chappe_esl_call:call(), iodata()) ->
    {ok, chappe_esl_event:event()} | {error, term()}.
playback(Call, File) ->
    playback(Call, File, #{}).

%% Opts, besides exec_opts: offset (start this many samples into the file,
%% FreeSWITCH's File@@Samples), limit_secs (stop after this many seconds,
%% at least 2, through playback_timeout_sec; the playback then still ends
%% as FILE PLAYED). A bad value returns {error, {bad_option, Key}}.
-spec playback(
    chappe_esl_call:call(), iodata(), chappe_esl_call:playback_opts()
) ->
    {ok, chappe_esl_event:event()} | {error, term()}.
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
-spec play_and_get_digits(chappe_esl_call:call(), map()) ->
    {ok, binary() | chappe_esl_call:digits()} | {error, term()}.
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
-spec record(chappe_esl_call:call(), iodata(), map()) ->
    {ok, chappe_esl_event:event()} | {error, term()}.
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

%% Send DTMF digits to the far end (the send_dtmf application).
-spec send_dtmf(chappe_esl_call:call(), iodata()) -> ok | {error, term()}.
send_dtmf(Call, Digits) ->
    case chappe_esl_exec:expands(Digits) of
        true -> {error, {bad_option, digits}};
        false -> done(exec(Call, <<"send_dtmf">>, Digits))
    end.

-spec set(chappe_esl_call:call(), iodata(), iodata()) -> ok | {error, term()}.
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
-spec export(chappe_esl_call:call(), iodata(), iodata()) ->
    ok | {error, term()}.
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
-spec say(chappe_esl_call:call(), iodata(), map()) -> ok | {error, term()}.
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
-spec speak(chappe_esl_call:call(), iodata(), map()) -> ok | {error, term()}.
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
    chappe_esl_exec:event_word(W) andalso
        binary:match(W, [<<"|">>, <<"'">>]) =:= nomatch;
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
-spec detect_tones(chappe_esl_call:call(), iodata()) -> ok | {error, term()}.
detect_tones(Call, Name) ->
    case tts_word(to_bin(Name)) of
        true ->
            detector(
                Call, <<"spandsp_start_tone_detect">>, Name, <<"+OK started">>
            );
        false ->
            {error, {bad_option, name}}
    end.

-spec stop_detect_tones(chappe_esl_call:call()) -> ok | {error, term()}.
stop_detect_tones(Call) ->
    done(exec(Call, <<"spandsp_stop_tone_detect">>, <<>>)).

%% Listen for a fax (mod_spandsp): the owner gets {fax, detected} once.
%% Opts: tone (cng, the calling fax, default; ced, the answering one),
%% timeout (seconds to listen, 0 for no limit, the default).
-spec detect_fax(chappe_esl_call:call(), map()) -> ok | {error, term()}.
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

-spec stop_detect_fax(chappe_esl_call:call()) -> ok | {error, term()}.
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
-spec multiset(chappe_esl_call:call(), #{iodata() => iodata()}) ->
    ok | {error, term()}.
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
    chappe_esl_exec:event_word(K) andalso binary:match(K, <<"=">>) =:= nomatch andalso
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
-spec getvar(chappe_esl_call:call(), iodata()) ->
    {ok, binary() | undefined} | {error, term()}.
getvar(Call, Var) ->
    case chappe_esl_exec:event_word(to_bin(Var)) of
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
-spec dump(chappe_esl_call:call()) ->
    {ok, #{binary() => binary()}} | {error, term()}.
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
-spec mute(chappe_esl_call:call(), read | write) -> ok | {error, term()}.
mute(Call, Dir) ->
    audio(Call, Dir, <<"1">>).

-spec unmute(chappe_esl_call:call(), read | write) -> ok | {error, term()}.
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

-spec hangup(chappe_esl_call:call()) -> ok | {error, term()}.
hangup(Call) ->
    hangup(Call, <<"NORMAL_CLEARING">>).

-spec hangup(chappe_esl_call:call(), iodata()) -> ok | {error, term()}.
hangup(Call, Cause) ->
    case exec(Call, <<"hangup">>, Cause) of
        {error, hangup} -> ok;
        Other -> done(Other)
    end.

-spec conference(chappe_esl_call:call(), iodata()) ->
    {ok, binary()} | {error, term()}.
conference(Call, Room) ->
    conference(Call, Room, #{}).

%% Join a mod_conference room: Room@Profile+flags{F1|F2}. Opts: profile
%% (default), flags (a list of mod_conference member flags, such as mute or
%% moderator), plus exec_opts. It does not wait by default: it returns
%% {ok, AppUuid}, and {complete, <<"conference">>, Event} reaches the owner
%% when the member leaves. With wait => true it returns at that point.
-spec conference(chappe_esl_call:call(), iodata(), map()) ->
    {ok, binary() | chappe_esl_event:event()} | {error, term()}.
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

%% internal

exec(Call, App, Args) ->
    chappe_esl_call:exec(Call, App, Args).

exec(Call, App, Args, Opts) ->
    chappe_esl_call:exec(Call, App, Args, Opts).

api(Call, Cmd) ->
    chappe_esl_call:api(Call, Cmd).

subscribe(Call, Events) ->
    chappe_esl_call:subscribe(Call, Events).

%% The call's channel uuid; {error, closed} once the call process is gone.
with_uuid(Call, Fun) ->
    try chappe_esl_call:uuid(Call) of
        Uuid -> Fun(Uuid)
    catch
        exit:{_Reason, {gen_server, call, _}} -> {error, closed}
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
