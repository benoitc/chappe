%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The wire side of chappe_esl_call: the sendmsg execute carrying an
%% Event-UUID, the wait for its CHANNEL_EXECUTE_COMPLETE from the controlling
%% process (chappe_esl_call:exec/5), uuid_break, the audio fork commands, and
%% the quoting of the arguments FreeSWITCH splits on spaces.
-module(chappe_esl_exec).

-export([exec/5, send/6, break/3, app_uuid/0, arg/1, channel_uuid/1]).
-export([fork_start_cmd/4, fork_stop_cmd/2]).

-define(EXEC_TIMEOUT, 60000).
-define(BREAK_TIMEOUT, 2000).
%% Longer arguments (or any with a line break) travel in the sendmsg body.
-define(MAX_HEADER_ARG, 1024).

%% See chappe_esl_call:exec/5.
-spec exec(pid(), binary() | undefined, iodata(), iodata(), map()) ->
    {ok, chappe_esl_event:event() | binary()} | {error, term()}.
exec(Conn, Uuid, App, Args, Opts) ->
    AppUuid = app_uuid(),
    Sent = send(Conn, Uuid, AppUuid, App, Args, Opts),
    case {Sent, maps:get(wait, Opts, true)} of
        {ok, true} ->
            Deadline = deadline(maps:get(timeout, Opts, ?EXEC_TIMEOUT)),
            case await_complete(Conn, Uuid, AppUuid, Deadline, false, []) of
                {timeout, Started} ->
                    raw_break(Conn, Uuid, Started),
                    {error, timeout};
                Result ->
                    Result
            end;
        {ok, false} ->
            {ok, AppUuid};
        {Error, _} ->
            Error
    end.

%% Send a sendmsg execute whose completion carries AppUuid.
-spec send(pid(), binary() | undefined, binary(), iodata(), iodata(), map()) ->
    ok | {error, term()}.
send(Conn, Uuid, AppUuid, App, Args0, Opts) ->
    Args = iolist_to_binary(Args0),
    Headers =
        [
            {<<"call-command">>, <<"execute">>},
            {<<"execute-app-name">>, App},
            {<<"Event-UUID">>, AppUuid}
        ] ++
            [{<<"event-lock">>, <<"true">>} || maps:get(lock, Opts, true)] ++
            [
                {<<"loops">>, integer_to_binary(N)}
             || N <- [maps:get(loops, Opts, 1)], N =/= 1
            ],
    case long_arg(Args) of
        false when Args =:= <<>> ->
            chappe_esl:sendmsg(Conn, Uuid, Headers);
        false ->
            chappe_esl:sendmsg(
                Conn, Uuid, Headers ++ [{<<"execute-app-arg">>, Args}]
            );
        true ->
            %% FreeSWITCH takes a text/plain body as the argument when the
            %% execute-app-arg header is missing
            Type = {<<"Content-Type">>, <<"text/plain">>},
            chappe_esl:sendmsg(Conn, Uuid, Headers ++ [Type], Args)
    end.

long_arg(Args) ->
    byte_size(Args) > ?MAX_HEADER_ARG orelse
        binary:match(Args, [<<"\n">>, <<"\r">>]) =/= nomatch.

await_complete(Conn, Uuid, AppUuid, Deadline, Started, Stash) ->
    receive
        {chappe_esl_event, Conn, Ev} = Msg ->
            case completes(Ev, Uuid, AppUuid) of
                done ->
                    requeue(Stash),
                    {ok, Ev};
                hangup ->
                    requeue([Msg | Stash]),
                    {error, hangup};
                started ->
                    await_complete(
                        Conn, Uuid, AppUuid, Deadline, true, [Msg | Stash]
                    );
                no ->
                    await_complete(
                        Conn, Uuid, AppUuid, Deadline, Started, [Msg | Stash]
                    )
            end;
        {Tag, Conn} = Msg when
            Tag =:= chappe_esl_closed; Tag =:= chappe_esl_disconnect
        ->
            requeue([Msg | Stash]),
            {error, closed}
    after remaining(Deadline) ->
        requeue(Stash),
        {timeout, Started}
    end.

completes(Ev, Uuid, AppUuid) ->
    case chappe_esl_event:name(Ev) of
        <<"CHANNEL_EXECUTE_COMPLETE">> ->
            case chappe_esl_event:header(<<"Application-UUID">>, Ev) of
                AppUuid -> done;
                _ -> no
            end;
        <<"CHANNEL_EXECUTE">> ->
            case chappe_esl_event:header(<<"Application-UUID">>, Ev) of
                AppUuid -> started;
                _ -> no
            end;
        <<"CHANNEL_HANGUP_COMPLETE">> when Uuid =:= undefined ->
            hangup;
        <<"CHANNEL_HANGUP_COMPLETE">> ->
            case chappe_esl_event:header(<<"Unique-ID">>, Ev) of
                Uuid -> hangup;
                _ -> no
            end;
        _ ->
            no
    end.

requeue(Stash) ->
    lists:foreach(fun(Msg) -> self() ! Msg end, lists:reverse(Stash)).

deadline(infinity) -> infinity;
deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

remaining(infinity) -> infinity;
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% A random (version 4) UUID, the form FreeSWITCH uses.
-spec app_uuid() -> binary().
app_uuid() ->
    <<A:32, B:16, _:4, C:12, _:2, D:14, E:48>> = rand:bytes(16),
    iolist_to_binary(
        io_lib:format(
            "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
            [A, B, C, 16#8000 bor D, E]
        )
    ).

%% Stop a timed out application: break it when it runs; when it is still
%% queued, flush the channel's queue so it never runs.
raw_break(Conn, undefined, Started) ->
    case chappe_esl_conn:channel(Conn) of
        undefined -> ok;
        Channel -> raw_break(Conn, channel_uuid(Channel), Started)
    end;
raw_break(Conn, Uuid, true) ->
    break(Conn, Uuid, current);
raw_break(Conn, Uuid, false) ->
    break(Conn, Uuid, all).

%% uuid_break: stop the media of the running application, or with `all'
%% also flush the applications queued behind it.
-spec break(pid(), binary(), current | all) -> ok.
break(Conn, Uuid, Scope) ->
    All =
        case Scope of
            current -> <<>>;
            all -> <<" all">>
        end,
    _ = chappe_esl:api(Conn, [<<"uuid_break ">>, Uuid, All], ?BREAK_TIMEOUT),
    ok.

%% One argument of an application or api command that FreeSWITCH splits on
%% spaces: backslashes and single quotes are escaped, and an argument with a
%% space (or an empty one) is single quoted.
-spec arg(iodata()) -> binary().
arg(Arg0) ->
    Arg = iolist_to_binary(Arg0),
    Escaped = binary:replace(
        binary:replace(Arg, <<"\\">>, <<"\\\\">>, [global]),
        <<"'">>,
        <<"\\'">>,
        [global]
    ),
    case
        Arg =:= <<>> orelse binary:match(Arg, [<<" ">>, <<"\t">>]) =/= nomatch
    of
        true -> <<"'", Escaped/binary, "'">>;
        false -> Escaped
    end.

%% uuid_<api> <uuid> start <url> <mix> <rate> [metadata]
-spec fork_start_cmd(
    chappe_esl_call:fork_module(), binary(), iodata(), map()
) -> iodata().
fork_start_cmd(Module, Uuid, Url, Opts) ->
    Mix = atom_to_binary(maps:get(mix, Opts, mono)),
    Rate = fork_rate(Module, maps:get(rate, Opts, 16000)),
    Meta =
        case maps:get(metadata, Opts, undefined) of
            undefined -> [];
            M -> [<<" ">>, fork_metadata(Module, arg(M))]
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

-spec fork_stop_cmd(chappe_esl_call:fork_module(), binary()) -> iodata().
fork_stop_cmd(Module, Uuid) ->
    [fork_api(Module), <<" ">>, Uuid, <<" stop">>].

fork_api(audio_fork) -> <<"uuid_audio_fork">>;
fork_api(audio_stream) -> <<"uuid_audio_stream">>.

%% mod_audio_stream names its two classic rates 8k and 16k (the only forms
%% its first releases parse); other rates and mod_audio_fork take the number.
fork_rate(audio_stream, 8000) -> <<"8k">>;
fork_rate(audio_stream, 16000) -> <<"16k">>;
fork_rate(_Module, Rate) when is_integer(Rate) -> integer_to_binary(Rate);
fork_rate(_Module, Rate) -> Rate.

%% mod_audio_fork reads the metadata after the bug name (its default,
%% audio_fork); mod_audio_stream reads it right after the rate.
fork_metadata(audio_fork, Meta) -> [<<"audio_fork ">>, Meta];
fork_metadata(audio_stream, Meta) -> Meta.

%% The uuid of an outbound connection's channel data.
-spec channel_uuid(chappe_esl_event:event()) -> binary() | undefined.
channel_uuid(Channel) ->
    case chappe_esl_event:header(<<"Unique-ID">>, Channel) of
        undefined -> chappe_esl_event:header(<<"Channel-Unique-ID">>, Channel);
        Uuid -> Uuid
    end.
