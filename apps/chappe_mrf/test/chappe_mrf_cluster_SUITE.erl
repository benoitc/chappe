%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Native rooms across a chappe_cluster region: three peer nodes run
%% chappe_cluster and chappe_mrf with `cluster => chappe_cluster', each
%% with its own SIP stack and mixer. This node runs no cluster: it takes
%% the callers' INVITEs (chappe_mrf_fake's UA, a fake rtpengine) and
%% joins them to a room running on a peer, which answers through its own
%% mixer (the loopback INVITE crosses nodes).
-module(chappe_mrf_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("chappe_mrf/src/chappe_mrf_conf.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    one_room_from_two_nodes/1,
    owner_node_dies/1,
    owner_node_shuts_down/1,
    lost_lease_moves_members/1,
    fs_clean_stop_frees_name/1,
    draining_node_routes_away/1,
    transfer_deadline_restores_member/1,
    rehome_helper_is_owned/1,
    start_has_one_deadline/1,
    cluster_setting_checked_at_start/1,
    lost_stops_new_joins/1,
    room_crash_frees_name/1,
    no_quorum_starts_in_parallel/1,
    waiting_owner_answers_once_running/1,
    non_owner_start_claims_nothing/1,
    fs_join_checks_lease_first/1,
    no_cluster_unchanged/1
]).

-define(F, chappe_mrf_fake).
-define(C, chappe_mrf_test_cluster).

all() ->
    [
        one_room_from_two_nodes,
        owner_node_dies,
        owner_node_shuts_down,
        lost_lease_moves_members,
        fs_clean_stop_frees_name,
        draining_node_routes_away,
        transfer_deadline_restores_member,
        rehome_helper_is_owned,
        start_has_one_deadline,
        cluster_setting_checked_at_start,
        lost_stops_new_joins,
        room_crash_frees_name,
        no_quorum_starts_in_parallel,
        waiting_owner_answers_once_running,
        non_owner_start_claims_nothing,
        fs_join_checks_lease_first,
        no_cluster_unchanged
    ].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif, [{persistent, true}]),
    ok = ?C:ensure(),
    {ok, _} = application:ensure_all_started(chappe_mrf),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(chappe_mrf),
    _ = application:stop(chappe_esl),
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(Case, Config) ->
    EP = ?F:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>}),
    ok = chappe_mrf:start(#{}),
    Rtpe = ?F:rtpe_start(self()),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {invite, self()},
        receive
            {join, Conf} ->
                Test ! {join, chappe_mrf_conf:join(Conf, {call, Req, Res}, #{})},
                %% the request worker's job ends here; the call runs on
                receive stop -> ok end
        after 10000 -> ok
        end
    end),
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    Peers = [?C:peer("mrf" ++ integer_to_list(I)) || I <- [1, 2, 3]],
    Nodes = [N || {_, N} <- Peers],
    Mode = mode(Case),
    _ = Mode =:= chappe_cluster andalso
        [ok = ?C:start_cluster(N, Nodes, Dir, cluster_env(Case)) || N <- Nodes],
    _ = Mode =:= chappe_cluster andalso [ok = ?C:wait_live(N) || N <- Nodes],
    [ok = start_mrf(N, Mode) || N <- Nodes],
    [{ep, EP}, {rtpe, Rtpe}, {peers, Peers}, {nodes, Nodes} | Config].

end_per_testcase(_Case, Config) ->
    [?C:stop_peer(P) || {P, _} <- ?config(peers, Config)],
    ?F:rtpe_stop(?config(rtpe, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

mode(no_cluster_unchanged) -> none;
mode(_) -> chappe_cluster.

%% long leases: the node stays live (its claims wait) seconds after it
%% lost its quorum
cluster_env(rehome_helper_is_owned) ->
    #{lease_ms => 2000, renew_ms => 500, command_timeout => 500};
cluster_env(fs_clean_stop_frees_name) ->
    #{lease_ms => 9000, renew_ms => 3000, command_timeout => 5000};
cluster_env(no_quorum_starts_in_parallel) ->
    #{lease_ms => 9000, renew_ms => 3000, command_timeout => 5000};
cluster_env(_) ->
    #{}.

start_mrf(N, Mode) ->
    ok = erpc:call(N, application, load, [chappe_mrf]),
    ok = erpc:call(N, application, set_env, [chappe_mrf, cluster, Mode]),
    {ok, _} = erpc:call(N, application, ensure_all_started, [chappe_mrf]),
    Port = ?F:pick(),
    ok = erpc:call(N, chappe_sip, start, [#{contact => <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>}]),
    ok = erpc:call(N, chappe_mrf, start, [#{}]),
    %% INVITEs other than the loopback ones (which chappe_mrf's middleware
    %% takes first) are not served on the peers
    ok = erpc:call(N, chappe_sip, invite, [fun(_Req, Res) -> chappe_sip_res:send(Res, 404) end]),
    ok = erpc:call(N, chappe_sip_media, configure, [#{mix => #{ip => {127, 0, 0, 1}}}]).

%% ---- cases ----

%% start/2 of one name on three nodes at once: one room, whichever node
%% won the claim, and every node gets its pid.
one_room_from_two_nodes(Config) ->
    Nodes = ?config(nodes, Config),
    Test = self(),
    lists:foreach(
        fun(I) ->
            Name = <<"race", (integer_to_binary(I))/binary>>,
            _ = [spawn(fun() -> Test ! {started, N, erpc:call(N, chappe_mrf, conference, [Name, #{}])} end)
                 || N <- Nodes],
            Got = [receive {started, N, R} -> R after 10000 -> ct:fail({no_start, N}) end || N <- Nodes],
            ct:pal("~s: ~p", [Name, Got]),
            [{ok, Conf} | _] = Got,
            ?assertEqual([{ok, Conf}, {ok, Conf}, {ok, Conf}], Got),
            ?assertMatch({ok, #{pid := Conf}}, erpc:call(hd(Nodes), chappe_cluster, owner, [{chappe_mrf_conf, Name}, consistent]))
        end,
        lists:seq(1, 5)
    ).

%% The room runs on a peer, its member's call on this node. Stop the
%% owner node: the call stays up (no BYE), start/2 elsewhere waits for
%% the lease to run out, then opens the room on a live node, and a new
%% caller lands there.
owner_node_dies(Config) ->
    [{P1, N1} | _] = ?config(peers, Config),
    [_, N2, N3] = ?config(nodes, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"dies">>, #{notify => self()}]),
    ?assertEqual(N1, node(Conf)),
    ?assertEqual({ok, Conf}, erpc:call(N2, chappe_mrf, conference, [<<"dies">>, #{}])),
    {Ua, M} = join_call(Config, Conf),
    ?assertEqual(1, length(chappe_mrf_conf:members(Conf))),
    ok = ?C:stop_peer(P1),
    New = wait_room(N2, <<"dies">>, N1),
    ?assertNotEqual(N1, node(New)),
    ?assertEqual({ok, New}, erpc:call(N3, chappe_mrf, conference, [<<"dies">>, #{}])),
    no_ua_event(Ua, bye, 500),
    _ = M,
    {Ua2, M2} = join_call(Config, New),
    ?assertMatch([#{id := M2}], chappe_mrf_conf:members(New)),
    ?F:ua_bye(Ua2),
    ?F:ua_bye(Ua).

%% A clean stop of the owner node (init:stop/0, as `docker stop' does):
%% before its dialogs end, the room gives its lease back, a room of the
%% same name opens on a live node, and the member whose call runs here
%% (on this test node) moves there with no BYE.
owner_node_shuts_down(Config) ->
    [{_, N1}, {_, N2} | _] = ?config(peers, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"shuts">>, #{notify => self()}]),
    {Ua, _M} = join_call(Config, Conf),
    MRef = monitor(process, Conf),
    ok = erpc:call(N1, init, stop, []),
    receive
        {'DOWN', MRef, process, Conf, _} -> ok
    after 20000 -> ct:fail(room_still_up)
    end,
    New = wait_room(N2, <<"shuts">>, N1),
    %% the old room ends once the member's call left it; the new one
    %% counts the member once the join completes
    ok = wait_members(New, 1),
    no_ua_event(Ua, bye, 3000),
    ?F:ua_bye(Ua).

%% An fs room does not move (its members are FreeSWITCH channels driven
%% through this node's sockets), but a clean stop gives its name back at
%% once: the room opens on a live node well before lease_ms (9 s here).
fs_clean_stop_frees_name(Config) ->
    [{_, N1}, {_, N2} | _] = ?config(peers, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"fsstop">>, #{backend => fs, node => fs1}]),
    MRef = monitor(process, Conf),
    ok = erpc:call(N1, init, stop, []),
    receive
        {'DOWN', MRef, process, Conf, _} -> ok
    after 20000 -> ct:fail(room_still_up)
    end,
    T0 = erlang:monotonic_time(millisecond),
    {ok, New} = erpc:call(N2, chappe_mrf, conference, [<<"fsstop">>, #{backend => fs, node => fs1}]),
    ?assertEqual(N2, node(New)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 4000).

%% While a node drains (a clean stop under way), a new room never opens
%% there: start/2 opens it on a live node of the region.
draining_node_routes_away(Config) ->
    [N1 | _] = ?config(nodes, Config),
    ok = erpc:call(N1, chappe_mrf_conf_move, draining, [true]),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"drainnew">>, #{}]),
    ?assertNotEqual(N1, node(Conf)),
    ok = erpc:call(N1, chappe_mrf_conf_move, draining, [false]).

%% A move that cannot finish by its deadline is cut, and the member it
%% was moving is the room's again (not left marked as on its way out), so
%% the next try can move it.
transfer_deadline_restores_member(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"dl">>, #{}]),
    {Ua, M} = join_call(Config, Conf),
    {ok, To} = erpc:call(N2, chappe_mrf, conference, [<<"dlto">>, #{}]),
    %% the target's node takes no INVITE: the move's join hangs
    ok = erpc:call(N2, chappe_sip, stop, []),
    Deadline = erpc:call(N1, erlang, monotonic_time, [millisecond]) + 2000,
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, timeout},
                 erpc:call(N1, chappe_mrf_conf_move, transfer_all, [Conf, [M], To, Deadline], 20000)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 5000),
    #state{members = #{M := Mb}} = sys:get_state(Conf),
    ?assertNot(is_map_key(transfer, Mb)),
    ?F:ua_bye(Ua).

%% The helper that moves a lost room's members is the room's: it gives
%% up at rehome_ms, its crash leaves the room as it was, and it ends with
%% the room.
rehome_helper_is_owned(Config) ->
    [{_, N1}, {P2, _}, {P3, _}] = ?config(peers, Config),
    ok = erpc:call(N1, application, set_env, [chappe_mrf, rehome_ms, 4000]),
    Rooms = [begin
                 {ok, C} = erpc:call(N1, chappe_mrf, conference, [Name, #{notify => self()}]),
                 {Ua, M} = join_call(Config, C),
                 {C, Ua, M}
             end || Name <- [<<"own1">>, <<"own2">>, <<"own3">>]],
    ok = ?C:stop_peer(P2),
    ok = ?C:stop_peer(P3),
    [receive {chappe_mrf_conf, C, lost} -> ok after 10000 -> ct:fail({no_lost, C}) end
     || {C, _, _} <- Rooms],
    [{C1, _, M1}, {C2, _, _}, {C3, _, _}] = Rooms,
    [H1, H2, H3] = [helper_of(C) || {C, _, _} <- Rooms],
    %% its own crash: the room and its member stay
    exit(H1, kill),
    timer:sleep(300),
    ?assert(erpc:call(N1, erlang, is_process_alive, [C1])),
    ?assertMatch([#{id := M1}], chappe_mrf_conf:members(C1)),
    %% its room's death: it goes too
    R2 = monitor(process, H2),
    exit(C2, kill),
    receive {'DOWN', R2, process, H2, _} -> ok after 3000 -> ct:fail(helper_outlives_room) end,
    %% its bound: it gives up by rehome_ms
    R3 = monitor(process, H3),
    receive {'DOWN', R3, process, H3, _} -> ok after 8000 -> ct:fail(helper_unbounded) end,
    ?assert(erpc:call(N1, erlang, is_process_alive, [C3])),
    [?F:ua_bye(Ua) || {_, Ua, _} <- Rooms].

helper_of(Conf) ->
    helper_of(Conf, 50).

helper_of(Conf, 0) ->
    ct:fail({no_helper, Conf, links(Conf)});
helper_of(Conf, N) ->
    case [P || P <- links(Conf), is_pid(P), node(P) =:= node(Conf),
               erpc:call(node(Conf), erlang, process_info, [P, initial_call])
                   =:= {initial_call, {erlang, apply, 2}}] of
        [H | _] -> H;
        [] -> timer:sleep(100), helper_of(Conf, N - 1)
    end.

links(Conf) ->
    {links, L} = erpc:call(node(Conf), erlang, process_info, [Conf, links]),
    L.

%% start/2 has one deadline, start_timeout, for all its tries: an owner
%% that never runs costs the caller that long, not 35 s per try.
start_has_one_deadline(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    ok = erpc:call(N2, application, set_env, [chappe_mrf, start_timeout, 3000]),
    Holder = erpc:call(N1, erlang, spawn, [timer, sleep, [infinity]]),
    W = waiting(N1, <<"never">>, Holder),
    {ok, _} = erpc:call(N1, chappe_cluster, claim, [{chappe_mrf_conf, <<"never">>}, #{pid => W}]),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, timeout}, erpc:call(N2, chappe_mrf, conference, [<<"never">>, #{}], 60000)),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:pal("start gave up after ~b ms", [Took]),
    ?assert(Took < 5000).

%% The cluster setting is checked when chappe_mrf starts: a release
%% without chappe_cluster, or a value that is not one, is a clean start
%% error, not a crash on the first room.
cluster_setting_checked_at_start(_Config) ->
    {P1, N1} = ?C:peer("nocluster", [chappe_cluster]),
    try
        ok = erpc:call(N1, application, load, [chappe_mrf]),
        ok = erpc:call(N1, application, set_env, [chappe_mrf, cluster, chappe_cluster]),
        {error, E1} = erpc:call(N1, application, ensure_all_started, [chappe_mrf]),
        ?assertMatch({match, _}, re:run(io_lib:format("~p", [E1]), "chappe_cluster_not_installed")),
        ok = erpc:call(N1, application, set_env, [chappe_mrf, cluster, bogus]),
        {error, E2} = erpc:call(N1, application, ensure_all_started, [chappe_mrf]),
        ?assertMatch({match, _}, re:run(io_lib:format("~p", [E2]), "badarg, *bogus"))
    after
        ?C:stop_peer(P1)
    end.

%% The room's lease is lost while its node runs: its members move to the
%% room that owns the name next, with no BYE, and the old room ends.
lost_lease_moves_members(Config) ->
    [N1 | _] = ?config(nodes, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"rehome">>, #{}]),
    {Ua, _M} = join_call(Config, Conf),
    #state{lease = Lease} = sys:get_state(Conf),
    MRef = monitor(process, Conf),
    ok = erpc:call(N1, chappe_cluster, release, [Lease]),
    %% the next way in finds the lease gone
    ?assertEqual({error, lost}, gen_server:call(Conf, {join, check})),
    receive
        {'DOWN', MRef, process, Conf, _} -> ok
    after 30000 -> ct:fail(old_room_stays)
    end,
    {ok, New} = erpc:call(N1, chappe_mrf, conference, [<<"rehome">>, #{}]),
    ?assertNotEqual(Conf, New),
    ok = wait_members(New, 1),
    no_ua_event(Ua, bye, 1000),
    ?F:ua_bye(Ua).

%% The owner node loses its quorum: the room hears lost, tells its
%% notify process, refuses a new member, and the member in keeps its
%% call. That node opens no second room (no_quorum).
lost_stops_new_joins(Config) ->
    [{_, N1}, {P2, _}, {P3, _}] = ?config(peers, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"lost">>, #{notify => self()}]),
    {Ua, M} = join_call(Config, Conf),
    ok = ?C:stop_peer(P2),
    ok = ?C:stop_peer(P3),
    receive
        {chappe_mrf_conf, Conf, lost} -> ok
    after 10000 -> ct:fail(no_lost)
    end,
    ?assertMatch(#{lost := true}, chappe_mrf_conf:info(Conf)),
    ?assertMatch([#{id := M}], chappe_mrf_conf:members(Conf)),
    Ua2 = ?F:ua_call(?config(ep, Config), #{}),
    W = receive {invite, Pid} -> Pid after 10000 -> ct:fail(no_invite) end,
    W ! {join, Conf},
    ?assertEqual({error, lost}, receive {join, R} -> R after 10000 -> ct:fail(no_join) end),
    W ! stop,
    ?assertEqual({error, no_quorum}, erpc:call(N1, chappe_mrf, conference, [<<"lost">>, #{}])),
    no_ua_event(Ua, bye, 500),
    %% the last member leaves: the lost room ends
    MRef = monitor(process, Conf),
    ?F:ua_bye(Ua),
    receive
        {'DOWN', MRef, process, Conf, normal} -> ok
    after 10000 -> ct:fail(lost_room_stays)
    end,
    _ = Ua2.

%% The room process dies: its lease goes with it, and the next start/2
%% on another node opens the room at once (well before lease_ms).
room_crash_frees_name(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"crash">>, #{}]),
    exit(Conf, kill),
    T0 = erlang:monotonic_time(millisecond),
    New = wait_room(N2, <<"crash">>, none),
    ?assertNotEqual(Conf, New),
    ?assertEqual(N2, node(New)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1500).

%% The quorum is gone but the node does not know yet: each claim waits
%% its claim_timeout. Three rooms started at once wait side by side, not
%% one after the other: the claim runs in the caller, not in the conf
%% supervisor.
no_quorum_starts_in_parallel(Config) ->
    [{_, N1}, {P2, _}, {P3, _}] = ?config(peers, Config),
    ok = erpc:call(N1, application, set_env, [chappe_mrf, claim_timeout, 2000]),
    ok = ?C:stop_peer(P2),
    ok = ?C:stop_peer(P3),
    Test = self(),
    T0 = erlang:monotonic_time(millisecond),
    Names = [<<"par", (integer_to_binary(I))/binary>> || I <- [1, 2, 3]],
    _ = [spawn(fun() ->
                   R = erpc:call(N1, chappe_mrf, conference, [Name, #{}]),
                   Test ! {started, Name, R, erlang:monotonic_time(millisecond) - T0}
               end)
         || Name <- Names],
    Got = [receive {started, Name, R, Ms} -> {R, Ms} after 20000 -> ct:fail({no_start, Name}) end
           || Name <- Names],
    ct:pal("~p", [Got]),
    [?assertEqual({error, no_quorum}, R) || {R, _} <- Got],
    Slowest = lists:max([Ms || {_, Ms} <- Got]),
    ?assert(Slowest < 3500),
    %% the supervisor answers meanwhile: nothing queued behind a claim
    ?assertMatch([_ | _], erpc:call(N1, supervisor, which_children, [chappe_mrf_sup])).

%% A start that loses the claim to a room still waiting for its lease
%% gets that room once it runs, not one that answers {error, starting};
%% when the waiting room dies instead, the start opens the room itself.
waiting_owner_answers_once_running(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    Holder = erpc:call(N1, erlang, spawn, [timer, sleep, [infinity]]),
    W = waiting(N1, <<"wait1">>, Holder),
    {ok, Lease} = erpc:call(N1, chappe_cluster, claim, [{chappe_mrf_conf, <<"wait1">>}, #{pid => W}]),
    Test = self(),
    _ = spawn(fun() ->
                  R = erpc:call(N2, chappe_mrf, conference, [<<"wait1">>, #{}]),
                  Info = case R of {ok, C} -> chappe_mrf_conf:info(C); _ -> none end,
                  Test ! {started, R, Info}
              end),
    timer:sleep(500),
    ok = gen_server:call(W, {activate, Lease}),
    receive
        {started, {ok, W}, #{name := <<"wait1">>}} -> ok;
        {started, R1, I1} -> ct:fail({got, R1, I1})
    after 20000 -> ct:fail(no_start)
    end,
    W2 = waiting(N1, <<"wait2">>, Holder),
    {ok, _} = erpc:call(N1, chappe_cluster, claim, [{chappe_mrf_conf, <<"wait2">>}, #{pid => W2}]),
    _ = spawn(fun() ->
                  R = erpc:call(N2, chappe_mrf, conference, [<<"wait2">>, #{}]),
                  Test ! {started2, R}
              end),
    timer:sleep(500),
    exit(W2, kill),
    receive
        {started2, {ok, C2}} ->
            ?assertEqual(N2, node(C2)),
            ?assertMatch(#{name := <<"wait2">>}, chappe_mrf_conf:info(C2));
        {started2, R2} ->
            ct:fail({got2, R2})
    after 20000 -> ct:fail(no_start2)
    end.

%% A room another node runs is found in the local replica: starting it
%% from a node that does not own it writes nothing to the region.
non_owner_start_claims_nothing(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"owned">>, #{}]),
    ok = wait_owner(N2, <<"owned">>, Conf),
    MFA = {chappe_cluster, claim, 2},
    _ = erpc:call(N2, erlang, trace_pattern, [MFA, true, [call_count]]),
    [{ok, Conf} = erpc:call(N2, chappe_mrf, conference, [<<"owned">>, #{}]) || _ <- [1, 2, 3]],
    {call_count, Count} = erpc:call(N2, erlang, trace_info, [MFA, call_count]),
    _ = erpc:call(N2, erlang, trace_pattern, [MFA, false, [call_count]]),
    ?assertEqual(0, Count).

%% An fs room whose lease no longer holds refuses a joining call before
%% it bridges or answers the caller: the refusal is lost, not what
%% connecting to FreeSWITCH would have given.
fs_join_checks_lease_first(Config) ->
    [N1 | _] = ?config(nodes, Config),
    {ok, Conf} = erpc:call(N1, chappe_mrf, conference, [<<"fsroom">>, #{backend => fs, node => fs1}]),
    #state{lease = Lease} = sys:get_state(Conf),
    ok = erpc:call(N1, chappe_cluster, release, [Lease]),
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    W = receive {invite, Pid} -> Pid after 10000 -> ct:fail(no_invite) end,
    W ! {join, Conf},
    ?assertEqual({error, lost}, receive {join, R} -> R after 10000 -> ct:fail(no_join) end),
    no_ua_event(Ua, final, 500),
    W ! stop.

wait_members(Conf, N) ->
    wait_members(Conf, N, 50).

wait_members(Conf, N, 0) ->
    ct:fail({members, Conf, chappe_mrf_conf:members(Conf), expected, N});
wait_members(Conf, N, Tries) ->
    case length(chappe_mrf_conf:members(Conf)) of
        N -> ok;
        _ -> timer:sleep(100), wait_members(Conf, N, Tries - 1)
    end.

%% A room process started waiting for its lease, as start/2 does, with
%% Holder as its starter.
waiting(Node, Name, Holder) ->
    {ok, W} = erpc:call(Node, chappe_mrf_sup, start_conf,
                        [#{name => Name, opts => #{}, caller => Holder, wait => true}]),
    W.

wait_owner(Node, Name, Conf) ->
    wait_owner(Node, Name, Conf, 50).

wait_owner(_Node, Name, _Conf, 0) ->
    ct:fail({no_owner, Name});
wait_owner(Node, Name, Conf, N) ->
    case erpc:call(Node, chappe_cluster, owner, [{chappe_mrf_conf, Name}]) of
        {ok, #{pid := Conf}} -> ok;
        _ -> timer:sleep(100), wait_owner(Node, Name, Conf, N - 1)
    end.

%% cluster => none: each node opens its own room, as before.
no_cluster_unchanged(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    {ok, C1} = erpc:call(N1, chappe_mrf, conference, [<<"solo">>, #{}]),
    {ok, C2} = erpc:call(N2, chappe_mrf, conference, [<<"solo">>, #{}]),
    ?assertEqual(N1, node(C1)),
    ?assertEqual(N2, node(C2)),
    ?assertEqual({ok, C1}, erpc:call(N1, chappe_mrf, conference, [<<"solo">>, #{}])).

%% ---- helpers ----

%% A caller to this node, joined to Conf from the INVITE's worker.
join_call(Config, Conf) ->
    Ua = ?F:ua_call(?config(ep, Config), #{}),
    W = receive {invite, Pid} -> Pid after 10000 -> ct:fail(no_invite) end,
    W ! {join, Conf},
    {ok, 200} = receive {ua, Ua, {final, S, _}} -> {ok, S} after 10000 -> ct:fail(no_final) end,
    {ok, M} = receive {join, R} -> R after 10000 -> ct:fail(no_join) end,
    W ! stop,
    {Ua, M}.

%% The room start/2 on Node gives, once it is not on Gone's node.
wait_room(Node, Name, Gone) ->
    wait_room(Node, Name, Gone, 100).

wait_room(_Node, Name, _Gone, 0) ->
    ct:fail({no_room, Name});
wait_room(Node, Name, Gone, N) ->
    case erpc:call(Node, chappe_mrf, conference, [Name, #{}]) of
        {ok, C} when node(C) =/= Gone ->
            case erpc:call(node(C), erlang, is_process_alive, [C]) of
                true -> C;
                false -> timer:sleep(100), wait_room(Node, Name, Gone, N - 1)
            end;
        Other ->
            ct:pal("~s: ~p", [Name, Other]),
            timer:sleep(100),
            wait_room(Node, Name, Gone, N - 1)
    end.

no_ua_event(Ua, What, Ms) ->
    receive
        {ua, Ua, {What, Bin}} -> ct:fail({unexpected, What, Bin})
    after Ms -> ok
    end.
