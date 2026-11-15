%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Forking proxy.
%%
%% A gen_udp caller sends an INVITE to the app; the app proxies it to one
%% or two gen_udp UAS peers.
-module(chappe_sip_proxy_forking_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([proxy_parallel_first_wins/1, proxy_serial_failover/1,
         proxy_single_200/1, proxy_parallel_6xx_cancels/1]).
-export([redirect_followed/1, redirect_not_followed_by_default/1,
         redirect_bounded/1, redirect_policy_and_seen/1, redirect_depth/1,
         redirect_parallel/1, provisional_timeout/1, final_timeout/1,
         bad_proxy_options/1]).
-export([accepted_supervised/1, accepted_crash/1, accepted_forks_bounded/1,
         accepted_window_follows_t1/1]).
-export([redirect_off_net_refused/1, redirect_reentry_bounded/1]).

all() ->
    [proxy_single_200, proxy_serial_failover, proxy_parallel_first_wins,
     proxy_parallel_6xx_cancels, redirect_followed,
     redirect_not_followed_by_default, redirect_bounded,
     redirect_policy_and_seen, redirect_depth, redirect_parallel,
     provisional_timeout, final_timeout, bad_proxy_options,
     accepted_supervised, accepted_crash, accepted_forks_bounded,
     accepted_window_follows_t1, redirect_off_net_refused,
     redirect_reentry_bounded].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    application:unset_env(chappe_sip, proxy_accepted_ms),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% single destination answers 200 -> relayed to caller
proxy_single_200(_Config) ->
    {EP, [D1]} = setup(1),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1)], #{}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, tag(),
                             [{<<"Contact">>, ctc(D1)}], sdp()))
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"pft">>)),
        R = recv_status(Sock, 200),
        {_, _} = binary:match(R, <<"v=0">>),
        Test ! caller_got_200
    end),
    ok = expect(caller_got_200),
    receive {proxy_done, {ok, #{final_status := 200}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% serial: dest1 486, fail over to dest2 200
proxy_serial_failover(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1), dest(D2)],
                               #{forking => sequential}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>)),
        Test ! d1_busy
    end),
    uas(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, tag(),
                             [{<<"Contact">>, ctc(D2)}], sdp())),
        Test ! d2_answered
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"psf">>)),
        _ = recv_status(Sock, 200),
        Test ! caller_got_200
    end),
    ok = expect(d1_busy),
    ok = expect(d2_answered),
    ok = expect(caller_got_200),
    receive {proxy_done, {ok, #{final_status := 200}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% parallel: both ring, dest1 answers 200 first, dest2 gets CANCELled
proxy_parallel_first_wins(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1), dest(D2)],
                               #{forking => parallel}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        timer:sleep(150),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, tag(),
                             [{<<"Contact">>, ctc(D1)}], sdp())),
        Test ! d1_answered
    end),
    uas(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {_Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(_Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! d2_cancelled
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"ppf">>)),
        _ = recv_status(Sock, 200),
        Test ! caller_got_200
    end),
    ok = expect(d1_answered),
    ok = expect(d2_cancelled),
    ok = expect(caller_got_200),
    receive {proxy_done, {ok, #{final_status := 200}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% F13: a 6xx from one branch is a global failure that cancels the other
%% branches and is relayed upstream once they answered the CANCEL (RFC 3261
%% 16.7 step 5).
%% req: R3261-P-020
proxy_parallel_6xx_cancels(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1), dest(D2)],
                               #{forking => parallel}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        timer:sleep(100),
        send(Sock, Src, resp(Inv, 603, <<"Decline">>, tag(), [], <<>>)),
        Test ! d1_declined
    end),
    uas(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {_Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(_Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>)),
        Test ! d2_cancelled
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"p6x">>)),
        _ = recv_status(Sock, 603),
        Test ! caller_got_603
    end),
    ok = expect(d1_declined),
    ok = expect(d2_cancelled),
    ok = expect(caller_got_603),
    receive {proxy_done, {ok, #{final_status := 603}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% ---- redirects (RFC 3261 16.7 step 4) and branch timeouts ----

%% follow_redirects: a 302 from the first target sends the request to its
%% Contact, which answers 200; the caller sees the 200, never the 302.
redirect_followed(_Config) ->
    {EP, [D1, D2]} = setup(2),
    proxy([dest(D1)], #{follow_redirects => true}),
    redirect(D1, [D2]),
    answer(D2, 200),
    call(EP, 200),
    ok = expect({invited, D2, ctc(D2)}),
    ok = expect_done(200).

%% Without follow_redirects the 302 goes back to the caller, as before.
redirect_not_followed_by_default(_Config) ->
    {EP, [D1, D2]} = setup(2),
    proxy([dest(D1)], #{}),
    redirect(D1, [D2]),
    silent(D2),
    call(EP, 302),
    ok = expect_done(302),
    receive {invited, D2, _} -> ct:fail(followed) after 300 -> ok end.

%% req: R3261-P-033
%% max_targets bounds what one transaction adds: of three Contacts two
%% are tried (and fail), the third stays in the 302 the caller gets.
redirect_bounded(_Config) ->
    {EP, [D1, D2, D3, D4]} = setup(4),
    proxy([dest(D1)], #{follow_redirects => #{max_targets => 2}}),
    redirect(D1, [D2, D3, D4]),
    answer(D2, 486),
    answer(D3, 486),
    silent(D4),
    R = call(EP, 302),
    ok = expect({invited, D2, ctc(D2)}),
    ok = expect({invited, D3, ctc(D3)}),
    ?assertNotEqual(nomatch, binary:match(R, ctc(D4))),
    ?assertEqual(nomatch, binary:match(R, ctc(D2))),
    ?assertEqual(nomatch, binary:match(R, ctc(D3))),
    ok = expect_done(302),
    receive {invited, D4, _} -> ct:fail(past_max_targets) after 300 -> ok end.

%% req: R3261-P-032
%% The allow policy refuses a target, and a Contact naming a target
%% already tried (a redirect back to itself) is not tried again; the 302
%% reaches the caller with both.
redirect_policy_and_seen(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Refused = ctc(D2),
    proxy([ctc(D1)], #{follow_redirects =>
                           #{allow => fun(U) -> U =/= Refused end}}),
    redirect(D1, [D1, D2]),
    silent(D2),
    R = call(EP, 302),
    ?assertNotEqual(nomatch, binary:match(R, ctc(D2))),
    ?assertNotEqual(nomatch, binary:match(R, ctc(D1))),
    ok = expect_done(302),
    receive {invited, D2, _} -> ct:fail(policy_ignored) after 300 -> ok end.

%% follow_redirects => true follows only the proxy's own domains: a callee
%% that 302s the caller to another network (a premium trunk) is not
%% followed, and its 302 reaches the caller.
redirect_off_net_refused(_Config) ->
    {EP, [D1]} = setup(1),
    Trunk = <<"sip:+19005550100@192.0.2.7:5060">>,
    proxy([dest(D1)], #{follow_redirects => true}),
    redirect_to(D1, [Trunk]),
    R = call(EP, 302),
    ?assertNotEqual(nomatch, binary:match(R, Trunk)),
    ok = expect_done(302).

%% A Contact naming the proxy itself brings the request back in, where
%% the proxy follows redirects again: each 302 names five new URIs of the
%% proxy. The request that came back follows none of them, so the target
%% is asked once by the call and once per Contact of its first 302, not
%% five times more per hop until Max-Forwards runs out.
redirect_reentry_bounded(_Config) ->
    {EP, [D1]} = setup(1),
    proxy([dest(D1)], #{follow_redirects => true}),
    Self = fun(N) -> <<"sip:u", (integer_to_binary(N))/binary, "@127.0.0.1:",
                       (integer_to_binary(EP))/binary>> end,
    Test = self(),
    uas(D1, fun(Sock) -> redirect_loop(Sock, Test, Self, 0) end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), tag())),
        receive {udp, Sock, _, _, <<"SIP/2.0 302", _/binary>> = F} -> Test ! {final, F}
        after 20000 -> ok
        end
    end),
    timer:sleep(6000),
    N = length(collect(redirected)),
    ct:log("the target got ~p INVITEs", [N]),
    ?assert(N =< 6),
    receive {final, _} -> ok after 6000 -> ct:fail(no_final) end.

%% max_depth 1: a target a 302 gave is tried, but a 302 from it is not
%% followed again.
redirect_depth(_Config) ->
    {EP, [D1, D2, D3]} = setup(3),
    proxy([dest(D1)], #{follow_redirects => #{max_depth => 1}}),
    redirect(D1, [D2]),
    redirect(D2, [D3]),
    silent(D3),
    R = call(EP, 302),
    ok = expect({invited, D2, ctc(D2)}),
    ?assertNotEqual(nomatch, binary:match(R, ctc(D3))),
    ok = expect_done(302),
    receive {invited, D3, _} -> ct:fail(past_max_depth) after 300 -> ok end.

%% Parallel forking: the redirect targets are sent at once, next to the
%% branches still ringing.
redirect_parallel(_Config) ->
    {EP, [D1, D2, D3]} = setup(3),
    proxy([dest(D1), dest(D2)],
          #{forking => parallel, follow_redirects => true}),
    redirect(D1, [D3]),
    answer(D2, 486),
    answer(D3, 200),
    call(EP, 200),
    ok = expect({invited, D3, ctc(D3)}),
    ok = expect_done(200).

%% provisional_timeout: a target that sends nothing, not even a 100, is
%% dropped without a CANCEL (RFC 3261 9.1) and the next one is tried well
%% before Timer C or Timer B.
provisional_timeout(_Config) ->
    {EP, [D1, D2]} = setup(2),
    proxy([dest(D1), dest(D2)], #{provisional_timeout => 300}),
    Test = self(),
    uas(D1, fun(Sock) ->
        {_Inv, _Src} = recv(Sock, <<"INVITE">>),
        receive
            {udp, Sock, _, _, <<"CANCEL", _/binary>>} -> Test ! d1_cancelled
        after 2000 -> ok
        end
    end),
    answer(D2, 200),
    T0 = erlang:monotonic_time(millisecond),
    call(EP, 200),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1500),
    ok = expect_done(200),
    receive d1_cancelled -> ct:fail(cancel_before_provisional)
    after 500 -> ok
    end.

%% final_timeout: a ringing target is CANCELled when no final comes in
%% time, though each 180 would restart Timer C, and the next is tried.
final_timeout(_Config) ->
    {EP, [D1, D2]} = setup(2),
    proxy([dest(D1), dest(D2)], #{final_timeout => 500}),
    Test = self(),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [],
                             <<>>)),
        Test ! d1_cancelled
    end),
    answer(D2, 200),
    call(EP, 200),
    ok = expect(d1_cancelled),
    ok = expect_done(200).

%% Options of the wrong shape are refused before anything is sent.
bad_proxy_options(_Config) ->
    {EP, [D1]} = setup(1),
    Test = self(),
    Bad = [#{provisional_timeout => 0}, #{final_timeout => infinity},
           #{follow_redirects => yes},
           #{follow_redirects => #{max_targets => 33}},
           #{follow_redirects => #{max_depth => 0}},
           #{follow_redirects => #{allow => fun(_, _) -> true end}},
           #{follow_redirects => #{other => 1}}],
    ok = chappe_sip:invite(fun(Req, _Res) ->
        Test ! {results, [chappe_sip:proxy_request(Req, [dest(D1)], O)
                          || O <- Bad]}
    end),
    silent(D1),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), tag())),
        _ = recv_status(Sock, 500)
    end),
    receive
        {results, Rs} ->
            ?assertEqual([{error, {badarg, provisional_timeout}},
                          {error, {badarg, final_timeout}}
                          | lists:duplicate(5, {error, {badarg, follow_redirects}})],
                         Rs)
    after 6000 -> ct:fail(no_results)
    end,
    receive {invited, D1, _} -> ct:fail(sent) after 300 -> ok end.

%% ---- the RFC 6026 Accepted state ----

%% After the 2xx the Accepted state runs as a child of
%% chappe_sip_proxy_sup, and ends when its window closes.
accepted_supervised(_Config) ->
    application:set_env(chappe_sip, proxy_accepted_ms, 800),
    {EP, [D1]} = setup(1),
    Before = accepted(),
    proxy([dest(D1)], #{}),
    answer(D1, 200),
    call(EP, 200),
    ok = expect_done(200),
    [Pid] = accepted() -- Before,
    ok = wait_gone(Pid, 30).

%% req: R6026-02
%% RFC 6026 7.2: Timer M is 64*T1 of the T1 the stack runs with: with T1
%% at 50 ms the Accepted state lasts 3.2 s, not 32.
accepted_window_follows_t1(_Config) ->
    {EP, [D1]} = setup(1, #{sip_timers => #{t1 => 50}}),
    Before = accepted(),
    proxy([dest(D1)], #{}),
    answer(D1, 200),
    call(EP, 200),
    ok = expect_done(200),
    [Pid] = accepted() -- Before,
    timer:sleep(2000),
    ?assert(lists:member(Pid, accepted())),
    ok = wait_gone(Pid, 30).

%% The Accepted process crashing leaves the answered call and the engine
%% alone, and is not restarted.
accepted_crash(_Config) ->
    {EP, [D1]} = setup(1),
    Before = accepted(),
    proxy([dest(D1)], #{}),
    answer(D1, 200),
    call(EP, 200),
    ok = expect_done(200),
    [Pid] = accepted() -- Before,
    Engine = whereis(chappe_sip_engine),
    exit(Pid, kill),
    ok = wait_gone(Pid, 20),
    ?assertEqual(Before, accepted()),
    ?assertEqual(Engine, whereis(chappe_sip_engine)),
    ?assertEqual(ok, chappe_sip_engine:check_health(2000)).

%% req: R3261-P-024
%% A target sending 2xx after 2xx with new To-tags gets each one through,
%% while the Accepted state remembers at most 64 tags.
accepted_forks_bounded(_Config) ->
    {EP, [D1]} = setup(1),
    Before = accepted(),
    proxy([dest(D1)], #{}),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        [send(Sock, Src, resp(Inv, 200, <<"OK">>, tag(),
                              [{<<"Contact">>, ctc(D1)}], sdp()))
         || _ <- lists:seq(1, 80)],
        timer:sleep(3000)
    end),
    Test = self(),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), tag())),
        Test ! {oks, length(lists:usort(tags_200(Sock, [])))}
    end),
    receive
        {oks, N} -> ?assertEqual(80, N)
    after 10000 -> ct:fail(no_count)
    end,
    [Pid] = accepted() -- Before,
    {state, _Txns, Seen} = sys:get_state(Pid),
    ?assertEqual(64, length(Seen)).

%% the To-tags of the 2xx the caller got (the first one is retransmitted
%% until an ACK that never comes)
tags_200(Sock, Acc) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>> = Bin} ->
            {ok, M} = chappe_sip_msg:parse(Bin),
            tags_200(Sock, [chappe_sip_msg:to_tag(M) | Acc]);
        {udp, Sock, _, _, _} ->
            tags_200(Sock, Acc)
    after 1500 -> Acc
    end.

accepted() ->
    [P || {_, P, _, _} <- supervisor:which_children(chappe_sip_proxy_sup)].

wait_gone(Pid, 0) ->
    ct:fail({still_running, Pid});
wait_gone(Pid, Tries) ->
    case lists:member(Pid, accepted()) of
        false -> ok;
        true -> timer:sleep(100), wait_gone(Pid, Tries - 1)
    end.

proxy(Dests, Opts) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        Test ! {proxy_done, chappe_sip:proxy_request(Req, Dests, Opts)}
    end).

expect_done(Status) ->
    receive {proxy_done, {ok, #{final_status := Status}}} -> ok
    after 8000 -> ct:fail({no_proxy_done, Status})
    end.

%% the caller: an INVITE to the app, and the final it gets (ACKed by the
%% proxy for a non-2xx; the 2xx ACK does not matter here)
call(EP, Status) ->
    Test = self(),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), tag())),
        Test ! {final, recv_status(Sock, Status)}
    end),
    receive {final, R} -> R after 8000 -> ct:fail({no_final, Status}) end.

%% a target that answers a 302 naming the Contacts of these ports
redirect(Port, To) ->
    Test = self(),
    uas(Port, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {invited, Port, ruri(Inv)},
        Contacts = iolist_to_binary(
            lists:join(<<", ">>, [[<<"<">>, ctc(P), <<">">>] || P <- To])),
        send(Sock, Src, resp(Inv, 302, <<"Moved Temporarily">>, tag(),
                             [{<<"Contact">>, Contacts}], <<>>)),
        _ = recv(Sock, <<"ACK">>)
    end).

%% a target that answers a 302 naming these URIs
redirect_to(Port, Uris) ->
    Test = self(),
    uas(Port, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {invited, Port, ruri(Inv)},
        Contacts = iolist_to_binary(
            lists:join(<<", ">>, [[<<"<">>, U, <<">">>] || U <- Uris])),
        send(Sock, Src, resp(Inv, 302, <<"Moved Temporarily">>, tag(),
                             [{<<"Contact">>, Contacts}], <<>>)),
        _ = recv(Sock, <<"ACK">>)
    end).

%% every INVITE answered 302 with five new URIs Self(N) of the proxy
redirect_loop(Sock, Test, Self, N) ->
    receive
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = Inv} ->
            Test ! {redirected, N},
            Contacts = iolist_to_binary(
                lists:join(<<", ">>, [[<<"<">>, Self(N * 5 + I), <<">">>]
                                      || I <- lists:seq(1, 5)])),
            send_to(Sock, Src, resp(Inv, 302, <<"Moved Temporarily">>, tag(),
                                    [{<<"Contact">>, Contacts}], <<>>)),
            redirect_loop(Sock, Test, Self, N + 1);
        {udp, Sock, _, _, _} ->
            redirect_loop(Sock, Test, Self, N)
    after 5000 -> ok
    end.

send_to(Sock, Port, Bin) -> gen_udp:send(Sock, {127,0,0,1}, Port, Bin).

collect(Tag) ->
    receive {Tag, V} -> [V | collect(Tag)] after 0 -> [] end.

answer(Port, Status) ->
    Test = self(),
    uas(Port, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {invited, Port, ruri(Inv)},
        {Hdrs, Body} =
            case Status of
                200 -> {[{<<"Contact">>, ctc(Port)}], sdp()};
                _ -> {[], <<>>}
            end,
        send(Sock, Src, resp(Inv, Status, <<"Final">>, tag(), Hdrs, Body)),
        timer:sleep(500)
    end).

silent(Port) ->
    Test = self(),
    uas(Port, fun(Sock) ->
        receive
            {udp, Sock, _, _, <<"INVITE ", _/binary>> = Inv} ->
                Test ! {invited, Port, ruri(Inv)}
        after 3000 -> ok
        end
    end).

ruri(Inv) ->
    [_, U | _] = binary:split(Inv, <<" ">>, [global]),
    U.

%% ---- peers ----

setup(N) ->
    setup(N, #{}).

setup(N, Opts) ->
    EP = pick(),
    ok = chappe_sip:start(Opts#{contact => <<"sip:127.0.0.1:",
                                        (integer_to_binary(EP))/binary>>}),
    {EP, [pick() || _ <- lists:seq(1, N)]}.

uas(Port, Fun) -> peer(Port, Fun).
caller(Fun) -> peer(0, Fun).

peer(Port, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(Port, [binary, {active, true},
                                         {ip, {127,0,0,1}}]),
        Parent ! {peer_ready, self()},
        Fun(Sock)
    end),
    receive {peer_ready, Pid} -> ok after 2000 -> ct:fail(peer_not_ready) end,
    Pid.

expect(Msg) ->
    receive Msg -> ok after 6000 -> ct:fail({expected, Msg}) end.

%% ---- SIP helpers ----

pick() -> chappe_sip_test_port:pick().
dest(P) -> <<"127.0.0.1:", (integer_to_binary(P))/binary>>.
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
callid() ->
    <<"m6-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, DstPort, Bin) -> gen_udp:send(Sock, {127,0,0,1}, DstPort, Bin).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when M =:= Method ->
            {Bin, Src};
        {udp, Sock, _, _, _} -> recv(Sock, Method)
    after 6000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                _ -> recv_status(Sock, Code)   % skip provisionals/others
            end
    after 6000 -> ct:fail({no_status, Code})
    end.

invite(Sock, Call, FT) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:callee@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:callee@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case chappe_sip_msg:to_tag(Msg) of
             undefined when Status > 100 -> <<To0/binary, ";tag=", ToTag/binary>>;
             _ -> To0
         end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
       ViaLines, <<"From: ">>, From, <<"\r\n">>, <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>, <<"CSeq: ">>, CSeq, <<"\r\n">>, Extra,
       <<"Content-Length: ">>, CL, <<"\r\n\r\n">>, Body]).
