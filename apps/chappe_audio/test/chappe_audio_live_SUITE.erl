%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Opt-in suite: real FreeSWITCH forks (mod_audio_fork, mod_audio_stream)
%% into a chappe_audio listener. It runs when FS_HOST is set and
%% chappe_esl is on the code path (it drives FreeSWITCH with it, as a test
%% tool only), otherwise every case is skipped. `make interop-esl' runs it
%% against the ESL lab after chappe_esl_live_SUITE:
%%
%%   FS_HOST=127.0.0.1 FS_PORT=18021 AUDIO_PORT=18085 \
%%     rebar3 ct --dir apps/chappe_audio/test --suite chappe_audio_live_SUITE
%%
%% fs1 calls fs2's park extension with a 440 Hz tone playing on its side,
%% then forks that channel to the listener, which the lab reaches as
%% host.docker.internal:AUDIO_PORT.
-module(chappe_audio_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [fork_mono, fork_stereo, stream_module, wrong_token, fork_to_store].

init_per_suite(Config) ->
    case {os:getenv("FS_HOST"), code:ensure_loaded(chappe_esl)} of
        {false, _} ->
            {skip, "FS_HOST not set; live FreeSWITCH interop disabled"};
        {_, {error, _}} ->
            {skip, "chappe_esl not on the code path"};
        {Host, {module, _}} ->
            {ok, _} = application:ensure_all_started(chappe_esl),
            {ok, _} = application:ensure_all_started(chappe_audio),
            Port = list_to_integer(os:getenv("AUDIO_PORT", "18085")),
            Fs = #{
                host => Host,
                port => list_to_integer(os:getenv("FS_PORT", "18021")),
                password => list_to_binary(os:getenv("FS_PASSWORD", "ClueCon"))
            },
            [{fs, Fs}, {audio_port, Port} | Config]
    end.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Port = ?config(audio_port, Config),
    {ok, L} = chappe_audio:listen(#{
        ip => {0, 0, 0, 0},
        port => Port,
        url => <<"ws://host.docker.internal:", (integer_to_binary(Port))/binary>>
    }),
    {ok, Conn} = chappe_esl:connect(?config(fs, Config)),
    Uuid = call(Conn),
    [{listener, L}, {conn, Conn}, {uuid, Uuid} | Config].

end_per_testcase(_Case, Config) ->
    Conn = ?config(conn, Config),
    _ = chappe_esl:api(Conn, ["uuid_kill ", ?config(uuid, Config)]),
    chappe_esl:close(Conn),
    chappe_audio:stop_listener(?config(listener, Config)).

%% mod_audio_fork, mixed (both directions in one channel) at 8 kHz: the stream sees the connection with
%% the audio.drachtio.org subprotocol, the metadata first, then 20 ms
%% frames (320 bytes) carrying the tone; stop closes it.
fork_mono(Config) ->
    Ref = <<"live-mono">>,
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{ref => Ref}),
    fork(Config, [Url, " mixed 8000 audio_fork {\"call\":\"lab\"}"]),
    {connected, #{subprotocol := <<"audio.drachtio.org">>}} = event(S),
    ?assertEqual({text, <<"{\"call\":\"lab\"}">>}, event(S)),
    Frames = frames(S, 50),
    ct:pal("frame sizes ~p", [lists:usort([byte_size(F) || F <- Frames])]),
    ?assert(lists:all(fun(F) -> byte_size(F) rem 2 =:= 0 end, Frames)),
    Loud = loudest(Frames, 1),
    ct:pal("loudest frame ~p dBFS", [Loud]),
    ?assert(Loud > -40),
    stop(Config, "uuid_audio_fork"),
    closed = event_until_closed(S).

%% Stereo at 16 kHz: interleaved sample pairs, caller audio on the left
%% (what fs2 sends: silence) and the channel's own (the tone) on the
%% right.
fork_stereo(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{
        ref => <<"live-stereo">>, format => #{rate => 16000, channels => 2}
    }),
    fork(Config, [Url, " stereo 16000"]),
    {connected, _} = event(S),
    Frames = frames(S, 50),
    ?assert(lists:all(fun(F) -> byte_size(F) rem 4 =:= 0 end, Frames)),
    [L, R] = lists:foldl(
        fun(F, [A, B]) ->
            [X, Y] = chappe_audio:levels(F, 2),
            [max(A, X), max(B, Y)]
        end,
        [-200, -200],
        Frames
    ),
    ct:pal("stereo levels: left ~p, right ~p", [L, R]),
    ?assert(max(L, R) > -40),
    ?assertEqual(0, maps:get(bad_frames, chappe_audio:info(S))),
    stop(Config, "uuid_audio_fork"),
    closed = event_until_closed(S).

%% mod_audio_stream, which offers no subprotocol and puts the metadata
%% right after the rate.
stream_module(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{
        ref => <<"live-stream">>
    }),
    api(Config, ["uuid_audio_stream ", ?config(uuid, Config), " start ", Url,
        " mixed 8k {\"call\":\"lab\"}"]),
    {connected, #{subprotocol := undefined}} = event(S),
    ?assertEqual({text, <<"{\"call\":\"lab\"}">>}, event(S)),
    ?assert(loudest(frames(S, 50), 1) > -40),
    stop(Config, "uuid_audio_stream"),
    closed = event_until_closed(S).

%% A fork with the wrong token is refused at the handshake: the stream
%% keeps waiting for its own fork.
wrong_token(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{
        ref => <<"live-token">>
    }),
    [Base, _] = binary:split(Url, <<"?token=">>),
    fork(Config, [Base, "?token=nope mono 8000"]),
    timer:sleep(2000),
    ?assertMatch(#{phase := waiting, frames := 0}, chappe_audio:info(S)),
    chappe_audio:close(S).

%% store => default: the fork is written to the store under its ref,
%% found by it once the fork stops.
fork_to_store(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "recordings"),
    ok = chappe_audio_store:configure(#{dir => Dir}),
    Ref = <<"live-store">>,
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{
        ref => Ref, store => default
    }),
    fork(Config, [Url, " mixed 8000"]),
    {connected, _} = event(S),
    _ = frames(S, 50),
    stop(Config, "uuid_audio_fork"),
    closed = event_until_closed(S),
    [#{duration_ms := Ms, path := Path}] = chappe_audio_store:find(Ref),
    ct:pal("recorded ~p ms at ~s", [Ms, Path]),
    ?assert(Ms >= 900),
    {ok, Bin} = file:read_file(Path),
    {ok, #{rate := 8000, channels := 1}} = chappe_audio_wav:info(Bin).

%% ---- helpers ----

call(Conn) ->
    Uuid = uuid(),
    {ok, Reply} = chappe_esl:bgapi_await(
        Conn,
        [
            "originate {origination_uuid=",
            Uuid,
            "}sofia/esl/sip:park@fs2:5080 &endless_playback(tone_stream://%(1000,0,440))"
        ],
        15000
    ),
    <<"+OK", _/binary>> = Reply,
    Uuid.

fork(Config, Args) ->
    api(Config, ["uuid_audio_fork ", ?config(uuid, Config), " start ", Args]).

stop(Config, Api) ->
    api(Config, [Api, " ", ?config(uuid, Config), " stop"]).

api(Config, Cmd) ->
    {ok, Reply} = chappe_esl:api(?config(conn, Config), Cmd),
    ct:pal("~s: ~s", [iolist_to_binary(Cmd), Reply]),
    <<"+OK", _/binary>> = Reply,
    ok.

event(S) ->
    receive
        {chappe_audio, S, E} -> E
    after 10000 -> ct:fail(no_event)
    end.

frames(_S, 0) ->
    [];
frames(S, N) ->
    case event(S) of
        {frame, F} -> [F | frames(S, N - 1)];
        {text, _} -> frames(S, N)
    end.

event_until_closed(S) ->
    case event(S) of
        closed -> closed;
        _ -> event_until_closed(S)
    end.

loudest(Frames, Ch) ->
    lists:max([lv(hd(chappe_audio:levels(F, Ch))) || F <- Frames]).

lv('-inf') -> -200;
lv(X) -> X.

uuid() ->
    <<A:32, B:16, C:16, D:16, E:48>> = rand:bytes(16),
    iolist_to_binary(
        io_lib:format(
            "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E]
        )
    ).
