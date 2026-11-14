%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The default store: its layout and atomic writes, find/get/read/delete,
%% adoption, retention, its writers (owner death, crash, bound), streams
%% written to it, and lookups across nodes.
-module(chappe_audio_store_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [
        layout_and_atomic_write,
        unsafe_call_ref,
        read_ranges_and_delete,
        adopt_wav,
        adopt_other_and_keep,
        retention_and_stale_parts,
        writer_owner_death,
        writer_crash,
        writer_bound,
        stream_to_store,
        bad_arguments,
        not_started,
        find_across_nodes
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_audio),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_audio).

init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    ok = chappe_audio_store:configure(#{dir => Dir}),
    [{dir, Dir} | Config].

end_per_testcase(_Case, _Config) ->
    ok.

%% open/2 from another app on a node where chappe_audio is stopped: an
%% error to handle, not an exit in the caller.
not_started(_Config) ->
    ok = application:stop(chappe_audio),
    try
        ?assertEqual(
            {error, not_started},
            chappe_audio_store:open(#{call_ref => <<"c">>}, #{})
        )
    after
        {ok, _} = application:ensure_all_started(chappe_audio)
    end.

%% A recording is written under a .part name and is not listed until
%% close/2; then it is <dir>/YYYY/MM/DD/<call_ref>/<id>.wav with its JSON
%% next to it, and the WAVE header holds the sizes.
layout_and_atomic_write(Config) ->
    Dir = ?config(dir, Config),
    Ref = <<"call-42">>,
    {ok, Rec} = chappe_audio_store:open(
        #{
            call_ref => Ref,
            source => fork,
            parties => [<<"alice">>],
            format => #{rate => 16000, channels => 2}
        },
        #{}
    ),
    Pcm = binary:copy(<<1, 0, 2, 0>>, 16000),
    [ok = chappe_audio_store:write(Rec, Pcm) || _ <- lists:seq(1, 4)],
    wait(fun() -> filelib:wildcard("*/*/*/call-42/*.wav.part", Dir) =/= [] end),
    ?assertEqual([], chappe_audio_store:find(Ref)),
    {ok, Id} = chappe_audio_store:close(Rec, #{parties => [<<"bob">>]}),
    {{Y, M, D}, _} = calendar:universal_time(),
    Day = io_lib:format("~4..0B/~2..0B/~2..0B", [Y, M, D]),
    Wav = filename:join([Dir, Day, "call-42", <<Id/binary, ".wav">>]),
    ?assert(filelib:is_regular(Wav)),
    ?assertEqual([], filelib:wildcard("*/*/*/*/*.part", Dir)),
    [R] = chappe_audio_store:find(Ref),
    ?assertMatch(
        #{
            id := Id,
            call_ref := Ref,
            node := _,
            parties := [<<"alice">>, <<"bob">>],
            source := <<"fork">>,
            duration_ms := 4000,
            bytes := 256044,
            format := #{<<"rate">> := 16000, <<"channels">> := 2}
        },
        R
    ),
    ?assertEqual(filename:absname(Wav), filename:absname(maps:get(path, R))),
    {ok, Bin} = file:read_file(Wav),
    ?assertMatch(
        {ok, #{rate := 16000, channels := 2, data_bytes := 256000, data_offset := 44}},
        chappe_audio_wav:info(Bin)
    ),
    {ok, Json} = file:read_file(filename:join([Dir, Day, "call-42", <<Id/binary, ".json">>])),
    ?assertMatch(#{<<"call_ref">> := Ref, <<"start">> := _}, json:decode(Json)),
    ?assertEqual({ok, R}, chappe_audio_store:get(Id)).

%% A call_ref that is not a plain name never becomes a path: it is
%% stored under the hash of it, and found by itself, text or not.
unsafe_call_ref(Config) ->
    Dir = ?config(dir, Config),
    Refs = [<<"../../etc">>, <<"a/b">>, <<255, 0, 1>>, <<".hidden">>],
    Ids = [element(2, record(Ref, <<0, 0>>)) || Ref <- Refs],
    [
        ?assertMatch([#{id := Id, call_ref := Ref}], chappe_audio_store:find(Ref))
     || {Ref, Id} <- lists:zip(Refs, Ids)
    ],
    Folders = [lists:last(filename:split(F)) || F <- filelib:wildcard("*/*/*/*", Dir)],
    ?assert(lists:all(fun(F) -> lists:prefix("x-", F) end, Folders)),
    ?assertEqual([], filelib:wildcard("etc", filename:dirname(Dir))).

%% read/2 returns byte ranges of the file; delete/1 removes the
%% recording and its call's folder when it was the last one.
read_ranges_and_delete(Config) ->
    Dir = ?config(dir, Config),
    {ok, Id} = record(<<"r1">>, <<"abcdefgh">>),
    {ok, <<"RIFF">>} = chappe_audio_store:read(Id, {0, 4}),
    {ok, <<"abcd">>} = chappe_audio_store:read(Id, {44, 4}),
    {ok, <<"gh">>} = chappe_audio_store:read(Id, {50, 100}),
    eof = chappe_audio_store:read(Id, {1000, 4}),
    {error, badarg} = chappe_audio_store:read(Id, {-1, 4}),
    ok = chappe_audio_store:delete(Id),
    ?assertEqual({error, not_found}, chappe_audio_store:get(Id)),
    ?assertEqual({error, not_found}, chappe_audio_store:delete(Id)),
    ?assertEqual([], filelib:wildcard("*/*/*/r1", Dir)),
    ?assertEqual({error, not_found}, chappe_audio_store:get(<<"../x">>)),
    ?assertEqual({error, not_found}, chappe_audio_store:get(<<"20261399-00">>)).

%% adopt/3 moves a finished WAVE file in (FreeSWITCH writes a LIST chunk
%% before the data, and a header whose sizes may be unset), reads its
%% format and length from it, and lists it under the call_ref.
adopt_wav(Config) ->
    Src = filename:join(?config(priv_dir, Config), "fs-rec.wav"),
    Data = binary:copy(<<0, 1>>, 8000 * 3),
    List = <<"LIST", 4:32/little, "INFO">>,
    <<Riff:12/binary, Fmt:24/binary, _:8/binary>> = chappe_audio_wav:header(8000, 1, 0),
    ok = file:write_file(
        Src, [Riff, Fmt, List, <<"data", 16#FFFFFFFF:32/little>>, Data]
    ),
    {ok, Id} = chappe_audio_store:adopt(Src, <<"call-fs">>, #{
        source => freeswitch, parties => [<<"caller">>]
    }),
    ?assertNot(filelib:is_regular(Src)),
    [R] = chappe_audio_store:find(<<"call-fs">>),
    ?assertMatch(
        #{
            id := Id,
            source := <<"freeswitch">>,
            duration_ms := 3000,
            format := #{<<"rate">> := 8000, <<"encoding">> := <<"L16">>}
        },
        R
    ),
    ?assertMatch({ok, _}, file:read_file_info(maps:get(path, R))),
    ?assertEqual({error, enoent}, chappe_audio_store:adopt(Src, <<"call-fs">>, #{})).

%% Another file keeps its extension and the format the caller gives;
%% keep => true copies and leaves the source.
adopt_other_and_keep(Config) ->
    Src = filename:join(?config(priv_dir, Config), "rec.MP3"),
    ok = file:write_file(Src, <<"ID3 not a wave">>),
    {ok, Id} = chappe_audio_store:adopt(Src, <<"call-mp3">>, #{keep => true}),
    ?assert(filelib:is_regular(Src)),
    {ok, #{path := Path, duration_ms := 0}} = chappe_audio_store:get(Id),
    ?assertEqual(<<".mp3">>, filename:extension(Path)),
    {ok, <<"ID3 not a wave">>} = file:read_file(Path).

%% The sweep removes partial files older than an hour (not a fresh one)
%% and, with retention_days, the day folders older than that.
retention_and_stale_parts(Config) ->
    Dir = ?config(dir, Config),
    Src = filename:join(?config(priv_dir, Config), "old.wav"),
    ok = file:write_file(Src, chappe_audio_wav:header(8000, 1, 0)),
    Old = os:system_time(millisecond) - 10 * 86400000,
    {ok, OldId} = chappe_audio_store:adopt(Src, <<"old-call">>, #{start => Old}),
    {ok, NewId} = record(<<"new-call">>, <<0, 0>>),
    {ok, Writer} = chappe_audio_store:open(#{call_ref => <<"live">>}, #{}),
    Stale = filename:join(filename:dirname(maps:get(path, ok(chappe_audio_store:get(NewId)))), "dead.wav.part"),
    ok = file:write_file(Stale, <<"x">>),
    ok = file:change_time(Stale, calendar:system_time_to_local_time(os:system_time(second) - 7200, second)),
    {ok, 0} = chappe_audio_store:sweep(),
    ?assertNot(filelib:is_regular(Stale)),
    ?assertEqual(1, length(filelib:wildcard("*/*/*/live/*.part", Dir))),
    ?assertMatch({ok, _}, chappe_audio_store:get(OldId)),
    ok = chappe_audio_store:configure(#{dir => Dir, retention_days => 5}),
    {ok, 1} = chappe_audio_store:sweep(),
    ?assertEqual({error, not_found}, chappe_audio_store:get(OldId)),
    ?assertMatch({ok, _}, chappe_audio_store:get(NewId)),
    {ok, _} = chappe_audio_store:close(Writer, #{}).

%% The feeder dies: its writer finishes the recording with what it had,
%% which is then listed.
writer_owner_death(_Config) ->
    Test = self(),
    Feeder = spawn(fun() ->
        {ok, Rec} = chappe_audio_store:open(#{call_ref => <<"gone">>}, #{}),
        ok = chappe_audio_store:write(Rec, <<1, 0, 2, 0>>),
        Test ! {rec, Rec},
        receive
            stop -> ok
        end
    end),
    {rec, Rec} = recv(),
    W = chappe_audio_store:writer(Rec),
    Mon = monitor(process, W),
    exit(Feeder, kill),
    {'DOWN', Mon, process, W, normal} = recv(),
    [#{bytes := 48}] = chappe_audio_store:find(<<"gone">>).

%% The writer crashes: its owner hears it through its monitor and goes
%% on; nothing is listed and the partial file waits for the sweep.
writer_crash(Config) ->
    Dir = ?config(dir, Config),
    {ok, Rec} = chappe_audio_store:open(#{call_ref => <<"crash">>}, #{}),
    W = chappe_audio_store:writer(Rec),
    Mon = monitor(process, W),
    ok = chappe_audio_store:write(Rec, <<0, 0>>),
    exit(W, kill),
    {'DOWN', Mon, process, W, killed} = recv(),
    ?assertEqual([], chappe_audio_store:find(<<"crash">>)),
    ?assertEqual(1, length(filelib:wildcard("*/*/*/crash/*.part", Dir))),
    ?assertEqual({error, closed}, chappe_audio_store:close(Rec, #{})),
    ?assertEqual(dropped, chappe_audio_store:write(Rec, <<0, 0>>)),
    %% the store goes on
    {ok, _} = record(<<"after">>, <<0, 0>>).

%% A writer that cannot keep up (suspended here): past max_queue writes
%% waiting, write/2 drops and says so, and the queue stays bounded.
writer_bound(_Config) ->
    {ok, Rec} = chappe_audio_store:open(#{call_ref => <<"slow">>}, #{max_queue => 50}),
    W = chappe_audio_store:writer(Rec),
    ok = sys:suspend(W),
    Frame = binary:copy(<<0>>, 320),
    Results = [chappe_audio_store:write(Rec, Frame) || _ <- lists:seq(1, 5000)],
    {message_queue_len, Q} = process_info(W, message_queue_len),
    ct:pal("queued ~p, dropped ~p", [Q, length([d || dropped <- Results])]),
    ?assertEqual(50, Q),
    ?assertEqual(4950, length([d || dropped <- Results])),
    ok = sys:resume(W),
    {ok, _} = chappe_audio_store:close(Rec, #{}),
    [#{bytes := Bytes}] = chappe_audio_store:find(<<"slow">>),
    ?assertEqual(44 + 50 * 320, Bytes).

%% store => default: a fork's stream is written to the store under its
%% ref while its frames still reach the owner.
stream_to_store(_Config) ->
    {ok, L} = chappe_audio:listen(#{}),
    Ref = <<"fork-rec">>,
    {ok, S, Url} = chappe_audio:open(L, #{ref => Ref, store => default}),
    {ok, C} = chappe_audio_test_ws:connect(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    Frame = binary:copy(<<3, 0>>, 160),
    [ok = chappe_audio_test_ws:send(C, {binary, Frame}) || _ <- lists:seq(1, 10)],
    [{chappe_audio, S, {frame, Frame}} = recv() || _ <- lists:seq(1, 10)],
    ?assert(is_pid(maps:get(recording, chappe_audio:info(S)))),
    ok = chappe_audio:close(S),
    receive
        {chappe_audio, S, {closed, normal}} -> ok
    after 5000 -> ct:fail(not_closed)
    end,
    [#{source := <<"fork">>, bytes := Bytes, duration_ms := 200}] =
        chappe_audio_store:find(Ref),
    ?assertEqual(44 + 3200, Bytes),
    chappe_audio:stop_listener(L).

bad_arguments(Config) ->
    ?assertEqual({error, badarg}, chappe_audio_store:open(#{}, #{})),
    ?assertEqual({error, badarg}, chappe_audio_store:open(#{call_ref => <<>>}, #{})),
    ?assertEqual(
        {error, badarg},
        chappe_audio_store:open(#{call_ref => <<"x">>, parties => [{bad, tuple}]}, #{})
    ),
    ?assertEqual({error, badarg}, chappe_audio_store:open(#{call_ref => <<"x">>, nope => 1}, #{})),
    ?assertEqual({error, badarg}, chappe_audio_store:adopt("x", not_binary, #{})),
    ?assertEqual({error, {bad_option, backend}}, chappe_audio_store:configure(#{backend => no_such_mod})),
    ?assertEqual({error, {bad_option, retention_days}}, chappe_audio_store:configure(#{retention_days => 0})),
    ?assertEqual({error, {bad_option, store}}, chappe_audio:open(chappe_audio_listener, #{store => s3})),
    ?assertMatch(#{dir := _}, chappe_audio_store:config()),
    ?assertEqual(?config(dir, Config), maps:get(dir, chappe_audio_store:config())).

%% Each node keeps its recordings; find/1 from either node returns the
%% call's recordings of both, and get/1 and read/2 reach the one held
%% by the other node.
find_across_nodes(Config) ->
    ok = ensure_dist(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{
        name => peer:random_name(), args => Paths, connection => standard_io
    }),
    pong = net_adm:ping(Node),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [chappe_audio]),
    PeerDir = filename:join(?config(dir, Config), "peer"),
    ok = peer:call(Peer, chappe_audio_store, configure, [#{dir => PeerDir}]),
    Ref = <<"two-nodes">>,
    {ok, Here} = record(Ref, <<1, 0>>),
    {ok, There} = peer:call(Peer, ?MODULE, record, [Ref, <<2, 0>>]),
    wait(fun() -> length(pg:get_members(chappe_audio, chappe_audio_store)) =:= 2 end),
    Found = chappe_audio_store:find(Ref),
    ?assertEqual(lists:sort([Here, There]), lists:sort([I || #{id := I} <- Found])),
    ?assertEqual(lists:sort([node(), Node]), lists:sort([N || #{node := N} <- Found])),
    ?assertEqual(2, length(peer:call(Peer, chappe_audio_store, find, [Ref]))),
    {ok, #{node := Node}} = chappe_audio_store:get(There),
    {ok, <<2, 0>>} = chappe_audio_store:read(There, {44, 2}),
    peer:stop(Peer),
    wait(fun() -> length(pg:get_members(chappe_audio, chappe_audio_store)) =:= 1 end),
    ?assertMatch([#{id := Here}], chappe_audio_store:find(Ref)).

%% ---- helpers ----

record(Ref, Pcm) ->
    {ok, Rec} = chappe_audio_store:open(#{call_ref => Ref}, #{}),
    ok = chappe_audio_store:write(Rec, Pcm),
    chappe_audio_store:close(Rec, #{}).

ok({ok, X}) -> X.

recv() ->
    receive
        M -> M
    after 5000 -> ct:fail(timeout)
    end.

wait(F) ->
    wait(F, 100).

wait(_F, 0) ->
    ct:fail(wait_timeout);
wait(F, N) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait(F, N - 1)
    end.

ensure_dist() ->
    case node() of
        nonode@nohost ->
            {ok, _} = net_kernel:start(chappe_audio_ct, #{name_domain => shortnames}),
            ok;
        _ ->
            ok
    end.
