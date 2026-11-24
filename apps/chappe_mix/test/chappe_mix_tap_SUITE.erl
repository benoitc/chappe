%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Taps: the decoded audio of a party or of the room, handed to a
%% process every tick, with tone senders on real UDP legs.
-module(chappe_mix_tap_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(LO, {127, 0, 0, 1}).

all() ->
    [
        party_and_room,
        muted_party_is_silent,
        refs,
        leg_leaves,
        receiver_death,
        conference_crash,
        untap_and_errors,
        flood_bound,
        from_peer_node,
        wideband_tap,
        cross_rate_move
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_mix),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_mix).

%% Two parties sending 440 Hz and 1100 Hz: a party's tap carries its own
%% tone and not the other's, the room's carries both; every message is
%% 20 ms of 8 kHz L16.
party_and_room(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {LA, A} = sender(Conf, 440),
    {_LB, B} = sender(Conf, 1100),
    {ok, TA} = chappe_mix:tap(Conf, LA, #{}),
    {ok, TR} = chappe_mix:tap(Conf, room, #{}),
    timer:sleep(300),
    flush_taps(),
    PcmA = collect(Conf, TA, 25),
    PcmR = collect(Conf, TR, 25),
    [{440, A440}, {1100, A1100}] = levels(PcmA),
    [{440, R440}, {1100, R1100}] = levels(PcmR),
    ct:pal("party: 440 ~.1f, 1100 ~.1f; room: 440 ~.1f, 1100 ~.1f", [
        A440, A1100, R440, R1100
    ]),
    ?assert(A440 > -30),
    ?assert(A1100 < A440 - 30),
    ?assert(R440 > -30 andalso R1100 > -30),
    ?assertMatch(
        [#{source := room, dropped := 0}, #{source := LA, dropped := 0}],
        lists:sort(
            fun(X, Y) -> maps:get(source, X) >= maps:get(source, Y) end,
            chappe_mix:taps(Conf)
        )
    ),
    [chappe_mix_test_tone:stop(P) || P <- [A, B]],
    ok = chappe_mix:stop(Conf).

%% A muted party sends, but the room takes nothing from it: its tap is
%% silence.
muted_party_is_silent(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {LA, A} = sender(Conf, 440),
    ok = chappe_mix:mute(Conf, LA, true),
    {ok, TA} = chappe_mix:tap(Conf, LA, #{}),
    timer:sleep(200),
    flush_taps(),
    Pcm = collect(Conf, TA, 10),
    ?assertEqual(binary:copy(<<0>>, byte_size(Pcm)), Pcm),
    chappe_mix_test_tone:stop(A),
    ok = chappe_mix:stop(Conf).

%% A tap's messages keep one shape; taps/1 gives its ref: its own, else
%% its leg's, else the room's.
refs(_Config) ->
    {ok, Conf} = chappe_mix:start(#{ref => <<"room-ref">>}),
    {ok, L1, _} = chappe_mix:add_leg(Conf, #{ref => <<"leg-ref">>}),
    {ok, L2, _} = chappe_mix:add_leg(Conf, #{}),
    {ok, T1} = chappe_mix:tap(Conf, L1, #{}),
    {ok, T2} = chappe_mix:tap(Conf, L2, #{}),
    {ok, T3} = chappe_mix:tap(Conf, room, #{ref => <<"own">>}),
    {chappe_mix, Conf, {tap, T1, <<_:2560>>}} = tap_msg(T1),
    {chappe_mix, Conf, {tap, T2, _}} = tap_msg(T2),
    {chappe_mix, Conf, {tap, T3, _}} = tap_msg(T3),
    Refs = maps:from_list([
        {T, R}
     || #{tap := T, ref := R} <- chappe_mix:taps(Conf)
    ]),
    ?assertEqual(
        #{T1 => <<"leg-ref">>, T2 => <<"room-ref">>, T3 => <<"own">>}, Refs
    ),
    ?assertEqual(<<"room-ref">>, chappe_mix:ref(Conf)),
    ok = chappe_mix:stop(Conf).

%% A party's tap ends with tap_closed when its leg leaves, and when it
%% moves to another conference; the conference stopping ends the rest.
leg_leaves(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {ok, Other} = chappe_mix:start(#{}),
    {ok, L1, _} = chappe_mix:add_leg(Conf, #{}),
    {ok, L2, _} = chappe_mix:add_leg(Conf, #{}),
    {ok, T1} = chappe_mix:tap(Conf, L1, #{}),
    {ok, T2} = chappe_mix:tap(Conf, L2, #{}),
    {ok, TR} = chappe_mix:tap(Conf, room, #{}),
    ok = chappe_mix:remove_leg(Conf, L1),
    closed(Conf, T1),
    {ok, _} = chappe_mix:move_leg(Conf, L2, Other),
    closed(Conf, T2),
    ok = chappe_mix:stop(Conf),
    closed(Conf, TR),
    ok = chappe_mix:stop(Other).

%% The receiver dies: the conference drops its tap and goes on.
receiver_death(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, _} = chappe_mix:tap(Conf, room, #{to => Pid}),
    [_] = chappe_mix:taps(Conf),
    exit(Pid, kill),
    wait(fun() -> chappe_mix:taps(Conf) =:= [] end),
    ?assert(is_process_alive(Conf)),
    ok = chappe_mix:stop(Conf).

%% The conference crashes: the receiver, which monitors it, sees it go,
%% and nothing more comes.
conference_crash(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {ok, T} = chappe_mix:tap(Conf, room, #{}),
    Mon = monitor(process, Conf),
    _ = tap_msg(T),
    exit(Conf, kill),
    receive
        {'DOWN', Mon, process, Conf, killed} -> ok
    after 2000 -> ct:fail(no_down)
    end,
    flush_taps(),
    receive
        {chappe_mix, Conf, _} = M -> ct:fail({after_crash, M})
    after 200 -> ok
    end.

untap_and_errors(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {ok, T} = chappe_mix:tap(Conf, room, #{}),
    ok = chappe_mix:untap(Conf, T),
    ?assertEqual({error, not_found}, chappe_mix:untap(Conf, T)),
    ?assertEqual([], chappe_mix:taps(Conf)),
    ?assertEqual({error, not_found}, chappe_mix:tap(Conf, 99, #{})),
    ?assertEqual({error, badarg}, chappe_mix:tap(Conf, nope, #{})),
    ?assertEqual({error, badarg}, chappe_mix:tap(Conf, room, #{to => x})),
    ?assertEqual(
        {error, badarg}, chappe_mix:tap(Conf, room, #{max_queue => 0})
    ),
    ?assertEqual({error, badarg}, chappe_mix:tap(Conf, room, #{ref => 1})),
    ok = chappe_mix:stop(Conf).

%% A receiver that never reads: past max_queue messages waiting at it,
%% frames are dropped and counted, its memory and the conference's stay
%% flat, and the clock keeps its ticks.
flood_bound(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {LA, A} = sender(Conf, 440),
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, _} = chappe_mix:tap(Conf, LA, #{to => Pid, max_queue => 20}),
    {ok, _} = chappe_mix:tap(Conf, room, #{to => Pid, max_queue => 20}),
    timer:sleep(1000),
    {memory, C1} = process_info(Conf, memory),
    {memory, P1} = process_info(Pid, memory),
    timer:sleep(2000),
    {memory, C2} = process_info(Conf, memory),
    {memory, P2} = process_info(Pid, memory),
    {message_queue_len, Q} = process_info(Pid, message_queue_len),
    Dropped = lists:sum([D || #{dropped := D} <- chappe_mix:taps(Conf)]),
    ct:pal("queue ~p, dropped ~p, conf ~p -> ~p, receiver ~p -> ~p", [
        Q, Dropped, C1, C2, P1, P2
    ]),
    ?assert(Q =< 21),
    %% 3 s of two taps is 300 frames; about 20 got through
    ?assert(Dropped > 200),
    ?assert(C2 < 2 * C1 + 65536),
    ?assert(P2 =< P1 + 4096),
    #{ticks := Ticks} = chappe_mix:stats(Conf),
    ?assert(Ticks > 140),
    chappe_mix_test_tone:stop(A),
    exit(Pid, kill),
    ok = chappe_mix:stop(Conf).

%% A receiver on another node: taps go across, and its node going takes
%% the tap away.
from_peer_node(_Config) ->
    ok = chappe_mix_test_dist:ensure(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{
        name => peer:random_name(), args => Paths, connection => standard_io
    }),
    pong = net_adm:ping(Node),
    {ok, Conf} = chappe_mix:start(#{}),
    Test = self(),
    Remote = erlang:spawn(Node, fun() -> fwd(Test) end),
    {ok, T} = chappe_mix:tap(Conf, room, #{to => Remote}),
    receive
        {fwd, {chappe_mix, Conf, {tap, T, <<_:2560>>}}} -> ok
    after 2000 -> ct:fail(no_remote_tap)
    end,
    peer:stop(Peer),
    wait(fun() -> chappe_mix:taps(Conf) =:= [] end),
    ok = chappe_mix:stop(Conf).

%% A 16 kHz room: a party sending 6000 Hz, above what 8 kHz can carry,
%% and one at 1000 Hz. Every tap message is 20 ms at 16 kHz, 640 bytes;
%% the party's tap carries its 6000 Hz and the room's carries both, so
%% the tap is wideband; taps/1 says the rate. A silent leg's tap is 640
%% bytes of zeros.
wideband_tap(_Config) ->
    {ok, Conf} = chappe_mix:start(#{rate => 16000}),
    {LA, A} = sender(Conf, 6000, #{law => l16, rate => 16000}),
    {_LB, B} = sender(Conf, 1000, #{law => l16, rate => 16000}),
    {ok, LQ, _} = chappe_mix:add_leg(Conf, #{}),
    {ok, TA} = chappe_mix:tap(Conf, LA, #{}),
    {ok, TR} = chappe_mix:tap(Conf, room, #{}),
    {ok, TQ} = chappe_mix:tap(Conf, LQ, #{}),
    timer:sleep(300),
    flush_taps(),
    PcmA = collect(Conf, TA, 25, 640),
    PcmR = collect(Conf, TR, 25, 640),
    PcmQ = collect(Conf, TQ, 5, 640),
    Lv = fun(Pcm) ->
        chappe_mix_test_tone:levels(
            [S || <<S:16/little-signed>> <= Pcm], [1000, 2000, 6000], 16000
        )
    end,
    [{1000, A1}, {2000, A2}, {6000, A6}] = Lv(PcmA),
    [{1000, R1}, {2000, R2}, {6000, R6}] = Lv(PcmR),
    ct:pal("party: 1000 ~.1f 2000 ~.1f 6000 ~.1f; room: ~.1f ~.1f ~.1f", [
        A1, A2, A6, R1, R2, R6
    ]),
    ?assert(A6 > -30),
    ?assert(A1 < A6 - 30),
    %% 6000 Hz folds onto 2000 Hz on a path through 8 kHz: nothing there
    ?assert(A2 < A6 - 40),
    ?assert(R6 > -30 andalso R1 > -30),
    ?assertEqual(<<0:(5 * 640 * 8)>>, PcmQ),
    ?assertEqual(
        [16000], lists:usort([R || #{rate := R} <- chappe_mix:taps(Conf)])
    ),
    ?assertMatch(#{rate := 16000}, chappe_mix:stats(Conf)),
    [chappe_mix_test_tone:stop(P) || P <- [A, B]],
    ok = chappe_mix:stop(Conf).

%% A leg moves only to a room of its rate: the far end speaks the
%% source's format, so a move across rates is refused and the leg stays
%% where it was, its tap still running; a move to a room of the same
%% rate goes.
cross_rate_move(_Config) ->
    {ok, R8} = chappe_mix:start(#{}),
    {ok, R16} = chappe_mix:start(#{rate => 16000}),
    {ok, R16b} = chappe_mix:start(#{rate => 16000}),
    {ok, L, _} = chappe_mix:add_leg(R16, #{}),
    {ok, T} = chappe_mix:tap(R16, L, #{}),
    ?assertEqual({error, refused}, chappe_mix:move_leg(R16, L, R8)),
    ?assertMatch([#{id := L, rate := 16000}], chappe_mix:legs(R16)),
    ?assertEqual([], chappe_mix:legs(R8)),
    flush_taps(),
    {chappe_mix, R16, {tap, T, <<_:(640 * 8)>>}} = tap_msg(T),
    {ok, L2} = chappe_mix:move_leg(R16, L, R16b),
    ?assertMatch([#{id := L2, rate := 16000}], chappe_mix:legs(R16b)),
    {ok, L8, _} = chappe_mix:add_leg(R8, #{}),
    ?assertEqual({error, refused}, chappe_mix:move_leg(R8, L8, R16)),
    ?assertMatch([_], chappe_mix:legs(R8)),
    [ok = chappe_mix:stop(C) || C <- [R8, R16, R16b]].

%% ---- helpers ----

sender(Conf, Freq) ->
    sender(Conf, Freq, #{}).

sender(Conf, Freq, Opts) ->
    {ok, Leg, #{port := P}} = chappe_mix:add_leg(Conf, #{}),
    {Pid, _} = chappe_mix_test_tone:endpoint(
        Opts#{freq => Freq, dst => {?LO, P}}
    ),
    {Leg, Pid}.

collect(Conf, T, N) ->
    collect(Conf, T, N, 320).

collect(_Conf, _T, 0, _Size) ->
    <<>>;
collect(Conf, T, N, Size) ->
    receive
        {chappe_mix, Conf, {tap, T, Pcm}} ->
            ?assertEqual(Size, byte_size(Pcm)),
            <<Pcm/binary, (collect(Conf, T, N - 1, Size))/binary>>
    after 2000 -> ct:fail(no_tap)
    end.

tap_msg(T) ->
    receive
        {chappe_mix, _, {tap, T, _}} = M -> M;
        {chappe_mix, _, {tap, T, _}, _} -> ct:fail(four_tuple)
    after 2000 -> ct:fail(no_tap)
    end.

closed(Conf, T) ->
    receive
        {chappe_mix, Conf, {tap_closed, T}} -> ok
    after 2000 -> ct:fail({not_closed, T})
    end,
    %% and nothing after it
    flush_taps(),
    receive
        {chappe_mix, Conf, {tap, T, _}} -> ct:fail({after_close, T})
    after 100 -> ok
    end.

flush_taps() ->
    receive
        {chappe_mix, _, {tap, _, _}} -> flush_taps();
        {chappe_mix, _, {tap, _, _}, _} -> flush_taps()
    after 0 -> ok
    end.

levels(Pcm) ->
    Samples = [S || <<S:16/little-signed>> <= Pcm],
    chappe_mix_test_tone:levels(Samples, [440, 1100]).

fwd(To) ->
    receive
        M ->
            To ! {fwd, M},
            fwd(To)
    end.

wait(F) -> wait(F, 100).

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
