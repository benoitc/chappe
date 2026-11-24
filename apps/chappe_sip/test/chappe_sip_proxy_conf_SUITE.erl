%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Proxy behaviour of RFC 3261 section 16 and RFC 6026.
%%
%% A gen_udp caller sends requests to the app, whose handler proxies them
%% to gen_udp peers. Each case checks one rule on the wire: the
%% Request-URI rewrite, a pre-existing Route, Timer C, CANCEL relay and the
%% CANCEL/2xx race, loop detection and spirals, the best response, and the
%% in-dialog Route handling (comma-joined values, strict routers, marker
%% expiry, CANCEL of a re-INVITE).
-module(chappe_sip_proxy_conf_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    ruri_rewritten/1,
    bare_host_keeps_user/1,
    preloaded_route/1,
    max_forwards_483/1,
    timer_c_after_ringing/1,
    timer_c_no_provisional/1,
    timer_c_restarted/1,
    cancel_relayed/1,
    cancel_crosses_2xx/1,
    loop_482/1,
    spiral_forwarded/1,
    best_challenges_merged/1,
    best_503_is_500/1,
    best_3xx_contacts_merged/1,
    best_4xx_retry_preferred/1,
    best_6xx_waits_for_branches/1,
    comma_route/1,
    strict_router_recovered/1,
    expired_marker_refused/1,
    reinvite_cancel_relayed/1,
    no_final_408/1,
    stray_response_dropped/1
]).

all() ->
    [
        ruri_rewritten,
        bare_host_keeps_user,
        preloaded_route,
        max_forwards_483,
        timer_c_after_ringing,
        timer_c_no_provisional,
        timer_c_restarted,
        cancel_relayed,
        cancel_crosses_2xx,
        loop_482,
        spiral_forwarded,
        best_challenges_merged,
        best_503_is_500,
        best_3xx_contacts_merged,
        best_4xx_retry_preferred,
        best_6xx_waits_for_branches,
        comma_route,
        strict_router_recovered,
        expired_marker_refused,
        reinvite_cancel_relayed,
        no_final_408,
        stray_response_dropped
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    application:unset_env(chappe_sip, record_route_ttl_s),
    ok.

%% ---- forwarding ----

%% 16.6 step 2: the Request-URI of the forwarded request is the target.
%% req: R3261-P-008
ruri_rewritten(_Config) ->
    {EP, [D1]} = setup(1),
    Target = <<"sip:bob@127.0.0.1:", (integer_to_binary(D1))/binary>>,
    proxy_app(fun(_Req) -> {[Target], #{}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {ruri, request_uri(Inv)},
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        _ = recv_status(Sock, 486)
    end),
    ?assertEqual(
        {ruri, Target},
        receive
            {ruri, _} = R -> R
        after 6000 -> none
        end
    ).

%% A target given as host:port keeps the user of the Request-URI.
%% req: R3261-P-008
bare_host_keeps_user(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {ruri, request_uri(Inv)},
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        _ = recv_status(Sock, 486)
    end),
    Expect = <<"sip:callee@127.0.0.1:", (integer_to_binary(D1))/binary>>,
    ?assertEqual(
        {ruri, Expect},
        receive
            {ruri, _} = R -> R
        after 6000 -> none
        end
    ).

%% 16.4 and 16.6 steps 6-7: our own Route is removed, the next Route is
%% the next hop, and the target only replaces the Request-URI.
%% req: R3261-P-001 R3261-P-010 R3261-P-011
preloaded_route(_Config) ->
    {EP, [D1, N]} = setup(2),
    Target = <<"sip:bob@127.0.0.1:", (integer_to_binary(D1))/binary>>,
    proxy_app(fun(_Req) -> {[Target], #{}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        receive
            {udp, Sock, _, _, <<"INVITE", _/binary>>} ->
                Test ! target_bypassed_route
        after 2000 -> ok
        end
    end),
    peer(N, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {next_hop, request_uri(Inv), hdr(<<"route">>, Inv)},
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    NextRoute = <<"<sip:127.0.0.1:", (integer_to_binary(N))/binary, ";lr>">>,
    SelfRoute = <<"<sip:127.0.0.1:", (integer_to_binary(EP))/binary, ";lr>">>,
    caller(fun(Sock) ->
        send(
            Sock,
            EP,
            req(
                <<"INVITE">>,
                <<"sip:callee@127.0.0.1">>,
                Sock,
                #{route => <<SelfRoute/binary, ", ", NextRoute/binary>>}
            )
        ),
        _ = recv_status(Sock, 486)
    end),
    receive
        {next_hop, RUri, Route} ->
            ?assertEqual(Target, RUri),
            ?assertEqual(NextRoute, Route)
    after 6000 -> ct:fail(next_hop_not_reached)
    end,
    receive
        target_bypassed_route -> ct:fail(target_bypassed_route)
    after 2100 -> ok
    end.

%% 16.3 step 3: a request with Max-Forwards 0 is answered 483.
%% req: R3261-P-002
max_forwards_483(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{}} end),
    Test = self(),
    caller(fun(Sock) ->
        send(
            Sock,
            EP,
            req(
                <<"INVITE">>,
                <<"sip:callee@127.0.0.1">>,
                Sock,
                #{max_forwards => 0}
            )
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({final, 483}).

%% ---- Timer C ----

%% 16.8: Timer C fires on a ringing branch: it is CANCELled and the caller
%% gets a 408, not the 487 the CANCEL produced.
%% req: R3261-P-017 R3261-P-019
timer_c_after_ringing(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{timer_c => 500}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, <<"rc">>, [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, <<"rc">>, [], <<>>)),
        send(
            Sock,
            Src,
            resp(Inv, 487, <<"Request Terminated">>, <<"rc">>, [], <<>>)
        ),
        Test ! callee_cancelled
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect(callee_cancelled),
    ok = expect({final, 408}).

%% 16.8: a branch that never answered at all is dropped when Timer C
%% fires and counts as a 408.
%% req: R3261-P-017 R3261-P-025
timer_c_no_provisional(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{timer_c => 500}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {_Inv, _Src} = recv(Sock, <<"INVITE">>),
        receive
            never -> ok
        after 4000 -> ok
        end
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({final, 408}).

%% 16.7 step 10: two parallel branches, neither of which gives a final
%% response before Timer C: the response context holds no final, so the
%% caller gets a 408.
%% req: R3261-P-030
no_final_408(_Config) ->
    {EP, [D1, D2]} = setup(2),
    proxy_app(fun(_Req) ->
        {[dest(D1), dest(D2)], #{forking => parallel, timer_c => 500}}
    end),
    Test = self(),
    Silent = fun(Sock) ->
        {_Inv, _Src} = recv(Sock, <<"INVITE">>),
        Test ! branch_reached,
        receive
            never -> ok
        after 4000 -> ok
        end
    end,
    peer(D1, Silent),
    peer(D2, Silent),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect(branch_reached),
    ok = expect(branch_reached),
    ok = expect({final, 408}).

%% RFC 6026 6: a response that matches no client transaction of ours (a
%% branch we never sent) is not forwarded, neither a 2xx nor a 1xx; the
%% caller only sees the final of its real branch.
%% req: R6026-05
stray_response_dropped(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Stray = re:replace(
            Inv,
            "branch=z9hG4bK[^;\r\n]*",
            "branch=z9hG4bKstray" ++ binary_to_list(tag()),
            [{return, binary}]
        ),
        send(Sock, Src, resp(Stray, 180, <<"Ringing">>, <<"st">>, [], <<>>)),
        send(
            Sock,
            Src,
            resp(
                Stray,
                200,
                <<"OK">>,
                <<"st">>,
                [{<<"Contact">>, ctc(D1)}],
                sdp()
            )
        ),
        timer:sleep(500),
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {seen, collect_statuses(Sock, 2500)}
    end),
    receive
        {seen, Seen} -> ?assertEqual([486], lists:usort(Seen) -- [100])
    after 6000 -> ct:fail(no_result)
    end.

%% 16.7 step 2: each provisional restarts Timer C, so a callee that keeps
%% ringing for three times the timer still connects.
%% req: R3261-P-017 R3261-P-018
timer_c_restarted(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{timer_c => 600}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        [
            begin
                send(
                    Sock, Src, resp(Inv, 180, <<"Ringing">>, <<"rr">>, [], <<>>)
                ),
                timer:sleep(300)
            end
         || _ <- lists:seq(1, 6)
        ],
        send(
            Sock,
            Src,
            resp(
                Inv,
                200,
                <<"OK">>,
                <<"rr">>,
                [{<<"Contact">>, ctc(D1)}],
                sdp()
            )
        )
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({final, 200}).

%% ---- CANCEL ----

%% 16.10: the caller's CANCEL goes to the ringing branch, and the caller
%% gets the 487 the callee sent (its To-tag), not one the proxy made up.
%% req: R3261-P-026 R3261-P-027
cancel_relayed(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, <<"cr">>, [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, <<"cr">>, [], <<>>)),
        send(
            Sock,
            Src,
            resp(Inv, 487, <<"Request Terminated">>, <<"cr">>, [], <<>>)
        ),
        Test ! callee_cancelled
    end),
    caller(fun(Sock) ->
        Br = branch(),
        Call = callid(),
        Opts = #{branch => Br, call => Call},
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, Opts)
        ),
        _ = recv_status(Sock, 180),
        send(
            Sock, EP, req(<<"CANCEL">>, <<"sip:callee@127.0.0.1">>, Sock, Opts)
        ),
        R = recv_final_of(Sock, <<"INVITE">>),
        Test ! {final, status(R), to_tag(R)}
    end),
    ok = expect(callee_cancelled),
    ok = expect({final, 487, <<"cr">>}).

%% 16.10 and 16.7 step 10: the callee answered 200 as the caller's CANCEL
%% reached it. The 2xx is relayed to the caller instead of the stack
%% having already answered the INVITE 487 upstream.
%% req: R3261-P-024 R3261-P-028
cancel_crosses_2xx(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, <<"x2">>, [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(
            Sock,
            Src,
            resp(
                Inv,
                200,
                <<"OK">>,
                <<"x2">>,
                [{<<"Contact">>, ctc(D1)}],
                sdp()
            )
        ),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, <<"x2">>, [], <<>>))
    end),
    caller(fun(Sock) ->
        Br = branch(),
        Opts = #{branch => Br, call => callid()},
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, Opts)
        ),
        _ = recv_status(Sock, 180),
        send(
            Sock, EP, req(<<"CANCEL">>, <<"sip:callee@127.0.0.1">>, Sock, Opts)
        ),
        Test ! {final, status(recv_final_of(Sock, <<"INVITE">>))}
    end),
    ok = expect({final, 200}).

%% ---- loops and spirals ----

%% 16.3 step 4: a request forwarded back to us unchanged carries our Via
%% with the same loop hash: 482 Loop Detected.
%% req: R3261-P-004
loop_482(_Config) ->
    {EP, []} = setup(0),
    proxy_app(fun(_Req) -> {[dest(EP)], #{}} end),
    Test = self(),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        R = recv_final(Sock),
        Test ! {final, status(R), reason(R)}
    end),
    ok = expect({final, 482, <<"Loop Detected">>}).

%% A spiral (back to us with a new Request-URI) is forwarded again, not
%% treated as a merged request or a loop.
%% req: R3261-P-003 R3261-P-005
spiral_forwarded(_Config) ->
    {EP, [D1]} = setup(1),
    Second = <<"sip:second@127.0.0.1:", (integer_to_binary(EP))/binary>>,
    Final = <<"sip:final@127.0.0.1:", (integer_to_binary(D1))/binary>>,
    proxy_app(fun(Req) ->
        case request_uri_user(Req) of
            <<"first">> -> {[Second], #{}};
            <<"second">> -> {[Final], #{}}
        end
    end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        Test ! {reached, request_uri(Inv)},
        send(
            Sock,
            Src,
            resp(
                Inv,
                200,
                <<"OK">>,
                tag(),
                [{<<"Contact">>, ctc(D1)}],
                sdp()
            )
        )
    end),
    caller(fun(Sock) ->
        send(Sock, EP, req(<<"INVITE">>, <<"sip:first@127.0.0.1">>, Sock, #{})),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({reached, Final}),
    ok = expect({final, 200}).

%% ---- best response ----

%% 16.7 step 7: the challenges of every 401 and 407 branch reach the
%% caller in the one response relayed.
%% req: R3261-P-022
best_challenges_merged(_Config) ->
    R = fork_finals(
        {401, <<"Unauthorized">>, [
            {<<"WWW-Authenticate">>, <<"Digest realm=\"a\", nonce=\"1\"">>}
        ]},
        {407, <<"Proxy Authentication Required">>, [
            {<<"Proxy-Authenticate">>, <<"Digest realm=\"b\", nonce=\"2\"">>}
        ]}
    ),
    ?assert(lists:member(status(R), [401, 407])),
    ?assertMatch({_, _}, binary:match(R, <<"realm=\"a\"">>)),
    ?assertMatch({_, _}, binary:match(R, <<"realm=\"b\"">>)).

%% 16.7 step 6: a 503 chosen as the best response goes upstream as 500.
%% req: R3261-P-021
best_503_is_500(_Config) ->
    {EP, [D1]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(D1)], #{}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(
            Sock,
            Src,
            resp(Inv, 503, <<"Service Unavailable">>, tag(), [], <<>>)
        )
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({final, 500}).

%% 3xx from two branches: the caller gets the Contacts of both.
%% req: R3261-P-020
best_3xx_contacts_merged(_Config) ->
    R = fork_finals(
        {301, <<"Moved Permanently">>, [
            {<<"Contact">>, <<"<sip:a@10.0.0.1>">>}
        ]},
        {302, <<"Moved Temporarily">>, [
            {<<"Contact">>, <<"<sip:b@10.0.0.2>">>}
        ]}
    ),
    ?assert(lists:member(status(R), [301, 302])),
    ?assertMatch({_, _}, binary:match(R, <<"sip:a@10.0.0.1">>)),
    ?assertMatch({_, _}, binary:match(R, <<"sip:b@10.0.0.2">>)).

%% 16.7 step 6: within 4xx a response the caller can act on (484) beats
%% one it cannot (404), whatever their order.
%% req: R3261-P-020 R3261-P-023
best_4xx_retry_preferred(_Config) ->
    R = fork_finals(
        {404, <<"Not Found">>, []},
        {484, <<"Address Incomplete">>, []}
    ),
    ?assertEqual(484, status(R)).

%% 16.7 step 5: a 6xx CANCELs the other branches and goes upstream once
%% they are done.
%% req: R3261-P-020
best_6xx_waits_for_branches(_Config) ->
    {EP, [D1, D2]} = setup(2),
    proxy_app(fun(_Req) -> {[dest(D1), dest(D2)], #{forking => parallel}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        timer:sleep(200),
        send(Sock, Src, resp(Inv, 603, <<"Decline">>, tag(), [], <<>>))
    end),
    peer(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, <<"d2">>, [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, <<"d2">>, [], <<>>)),
        timer:sleep(300),
        Test ! d2_487,
        send(
            Sock,
            Src,
            resp(Inv, 487, <<"Request Terminated">>, <<"d2">>, [], <<>>)
        )
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect(d2_487),
    ok = expect({final, 603}).

%% ---- in-dialog routing ----

%% A Route header line carrying two values: we pop only ours, the other
%% one is the next hop and stays in the request.
%% req: R3261-P-001 R3261-P-011
comma_route(_Config) ->
    {EP, [CP, N]} = setup(2),
    Test = self(),
    Call = callid(),
    RR = chappe_sip_route:record_route(
        chappe_sip_engine:contact(),
        undefined,
        Call
    ),
    NextRoute = <<"<sip:127.0.0.1:", (integer_to_binary(N))/binary, ";lr>">>,
    peer(CP, fun(Sock) ->
        receive
            {udp, Sock, _, _, <<"BYE", _/binary>>} -> Test ! skipped_next_hop
        after 2000 -> ok
        end
    end),
    peer(N, fun(Sock) ->
        {Bye, Src} = recv(Sock, <<"BYE">>),
        Test ! {next_hop, hdr(<<"route">>, Bye)},
        send(Sock, Src, resp(Bye, 200, <<"OK">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        send(
            Sock,
            EP,
            req(
                <<"BYE">>,
                ctc(CP),
                Sock,
                #{
                    call => Call,
                    to_tag => <<"tt">>,
                    route => <<RR/binary, ", ", NextRoute/binary>>
                }
            )
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({next_hop, NextRoute}),
    ok = expect({final, 200}),
    receive
        skipped_next_hop -> ct:fail(skipped_next_hop)
    after 2100 -> ok
    end.

%% 16.4: a strict router upstream put our Record-Route in the Request-URI
%% and the target in the last Route; the target is restored.
%% req: R3261-P-006
strict_router_recovered(_Config) ->
    {EP, [CP]} = setup(1),
    Test = self(),
    Call = callid(),
    RR = chappe_sip_route:record_route(
        chappe_sip_engine:contact(),
        undefined,
        Call
    ),
    {ok, #{uri := RRUri}} = chappe_sip_hdr:name_addr(RR),
    Target = ctc(CP),
    peer(CP, fun(Sock) ->
        {Bye, Src} = recv(Sock, <<"BYE">>),
        Test ! {target, request_uri(Bye), hdr(<<"route">>, Bye)},
        send(Sock, Src, resp(Bye, 200, <<"OK">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        send(
            Sock,
            EP,
            req(
                <<"BYE">>,
                RRUri,
                Sock,
                #{
                    call => Call,
                    to_tag => <<"tt">>,
                    route => <<"<", Target/binary, ">">>
                }
            )
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({target, Target, undefined}),
    ok = expect({final, 200}).

%% A Record-Route marker is signed with its expiry: past it, the Route is
%% not ours any more and the request is refused, not relayed.
%% req: R3261-P-001
expired_marker_refused(_Config) ->
    application:set_env(chappe_sip, record_route_ttl_s, 1),
    {EP, [CP]} = setup(1),
    Test = self(),
    Call = callid(),
    RR = chappe_sip_route:record_route(
        chappe_sip_engine:contact(),
        undefined,
        Call
    ),
    timer:sleep(2100),
    peer(CP, fun(Sock) ->
        receive
            {udp, Sock, _, _, <<"BYE", _/binary>>} -> Test ! relayed
        after 2000 -> ok
        end
    end),
    caller(fun(Sock) ->
        send(
            Sock,
            EP,
            req(
                <<"BYE">>,
                ctc(CP),
                Sock,
                #{call => Call, to_tag => <<"tt">>, route => RR}
            )
        ),
        Test ! {final, status(recv_final(Sock))}
    end),
    ok = expect({final, 481}),
    receive
        relayed -> ct:fail(expired_marker_relayed)
    after 2100 -> ok
    end.

%% 16.10: a CANCEL of a re-INVITE in transit through our record route
%% reaches the callee, and the caller gets the callee's 487.
%% req: R3261-P-026
reinvite_cancel_relayed(_Config) ->
    {EP, [CP]} = setup(1),
    proxy_app(fun(_Req) -> {[dest(CP)], #{record_route => true}} end),
    Test = self(),
    peer(CP, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        RR = hdr(<<"record-route">>, Inv),
        send(
            Sock,
            Src,
            resp(
                Inv,
                200,
                <<"OK">>,
                <<"ct">>,
                [
                    {<<"Contact">>, ctc(CP)},
                    {<<"Record-Route">>, RR}
                ],
                sdp()
            )
        ),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Re, RSrc} = recv(Sock, <<"INVITE">>),
        send(Sock, RSrc, resp(Re, 180, <<"Ringing">>, keep, [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        Test ! callee_got_cancel,
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, keep, [], <<>>)),
        send(
            Sock, RSrc, resp(Re, 487, <<"Request Terminated">>, keep, [], <<>>)
        )
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(
            Sock,
            EP,
            req(
                <<"INVITE">>,
                <<"sip:callee@127.0.0.1">>,
                Sock,
                #{call => Call}
            )
        ),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        RR = hdr(<<"record-route">>, R200),
        Callee = ctc(CP),
        Dlg = #{call => Call, to_tag => TT, route => RR},
        send(Sock, EP, req(<<"ACK">>, Callee, Sock, Dlg)),
        Br = branch(),
        Re = Dlg#{branch => Br, cseq => 2},
        send(Sock, EP, req(<<"INVITE">>, Callee, Sock, Re)),
        _ = recv_status(Sock, 180),
        send(Sock, EP, req(<<"CANCEL">>, Callee, Sock, Re)),
        Test ! {final, status(recv_final_of(Sock, <<"INVITE">>))}
    end),
    ok = expect(callee_got_cancel),
    ok = expect({final, 487}).

%% ---- helpers ----

%% two parallel branches answer A and B (B 150 ms later); the response the
%% caller gets
fork_finals({S1, R1, H1}, {S2, R2, H2}) ->
    {EP, [D1, D2]} = setup(2),
    proxy_app(fun(_Req) -> {[dest(D1), dest(D2)], #{forking => parallel}} end),
    Test = self(),
    peer(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, S1, R1, tag(), H1, <<>>))
    end),
    peer(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        timer:sleep(150),
        send(Sock, Src, resp(Inv, S2, R2, tag(), H2, <<>>))
    end),
    caller(fun(Sock) ->
        send(
            Sock, EP, req(<<"INVITE">>, <<"sip:callee@127.0.0.1">>, Sock, #{})
        ),
        Test ! {final_resp, recv_final(Sock)}
    end),
    receive
        {final_resp, R} -> R
    after 6000 -> ct:fail(no_final)
    end.

proxy_app(Route) ->
    ok = chappe_sip:invite(fun(Req, _Res) ->
        {Dests, Opts} = Route(Req),
        chappe_sip:proxy_request(Req, Dests, Opts)
    end).

setup(N) ->
    EP = pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    {EP, [pick() || _ <- lists:seq(1, N)]}.

caller(Fun) -> peer(0, Fun).

peer(Port, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(Port, [
            binary,
            {active, true},
            {ip, {127, 0, 0, 1}}
        ]),
        Parent ! {peer_ready, self()},
        Fun(Sock)
    end),
    receive
        {peer_ready, Pid} -> ok
    after 2000 -> ct:fail(peer_not_ready)
    end,
    Pid.

expect(Msg) ->
    receive
        Msg -> ok
    after 8000 -> ct:fail({expected, Msg})
    end.

pick() -> chappe_sip_test_port:pick().
dest(P) -> <<"127.0.0.1:", (integer_to_binary(P))/binary>>.
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
callid() ->
    <<"pc-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp() ->
    <<
        "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
    >>.
lport(Sock) ->
    {ok, P} = inet:port(Sock),
    P.
send(Sock, DstPort, Bin) -> gen_udp:send(Sock, {127, 0, 0, 1}, DstPort, Bin).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            {Bin, Src};
        {udp, Sock, _, _, _} ->
            recv(Sock, Method)
    after 6000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                _ -> recv_status(Sock, Code)
            end
    after 6000 -> ct:fail({no_status, Code})
    end.

%% the status of every response the socket gets for Ms milliseconds
collect_statuses(Sock, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    collect_statuses(Sock, Deadline, []).

collect_statuses(Sock, Deadline, Acc) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} ->
            collect_statuses(Sock, Deadline, [status(Bin) | Acc]);
        {udp, Sock, _, _, _} ->
            collect_statuses(Sock, Deadline, Acc)
    after Left -> lists:reverse(Acc)
    end.

%% the first final response
recv_final(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} -> recv_final(Sock);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} -> Bin;
        {udp, Sock, _, _, _} -> recv_final(Sock)
    after 6000 -> ct:fail(no_final)
    end.

%% the first final response to a Method request
recv_final_of(Sock, Method) ->
    R = recv_final(Sock),
    {ok, M} = chappe_sip_msg:parse(R),
    case chappe_sip_msg:cseq(M) of
        {ok, #{method := Method}} -> R;
        _ -> recv_final_of(Sock, Method)
    end.

status(<<"SIP/2.0 ", C:3/binary, _/binary>>) -> binary_to_integer(C).

reason(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:reason(M).

to_tag(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(M).

hdr(Name, Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(Name, M).

request_uri(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:uri(M).

request_uri_user(Req) ->
    {ok, #{user := U}} =
        chappe_sip_uri:parse(chappe_sip_msg:uri(chappe_sip_req:msg(Req))),
    U.

%% A request from the caller socket. Opts: call, branch, from_tag, to_tag,
%% cseq, route, max_forwards.
req(Method, RUri, Sock, Opts) ->
    P = integer_to_binary(lport(Sock)),
    Call = maps:get(call, Opts, callid()),
    Br = maps:get(branch, Opts, branch()),
    FT = maps:get(from_tag, Opts, <<"cf">>),
    CSeqN = integer_to_binary(maps:get(cseq, Opts, 1)),
    CSeqM =
        case Method of
            <<"ACK">> -> <<"ACK">>;
            <<"CANCEL">> -> <<"CANCEL">>;
            _ -> Method
        end,
    To =
        case maps:get(to_tag, Opts, undefined) of
            undefined -> <<"<sip:callee@127.0.0.1>">>;
            TT -> <<"<sip:callee@127.0.0.1>;tag=", TT/binary>>
        end,
    Route =
        case maps:get(route, Opts, undefined) of
            undefined -> <<>>;
            R -> <<"Route: ", R/binary, "\r\n">>
        end,
    MF = integer_to_binary(maps:get(max_forwards, Opts, 70)),
    Body =
        case Method of
            <<"INVITE">> -> sdp();
            _ -> <<>>
        end,
    CT =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    <<Method/binary, " ", RUri/binary,
        " SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", Br/binary,
        "\r\n"
        "Max-Forwards: ", MF/binary, "\r\n", Route/binary,
        "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary,
        "\r\n"
        "To: ", To/binary,
        "\r\n"
        "Contact: <sip:caller@127.0.0.1:", P/binary,
        ">\r\n"
        "Call-ID: ", Call/binary,
        "\r\n"
        "CSeq: ", CSeqN/binary, " ", CSeqM/binary, "\r\n", CT/binary,
        "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary,
        "\r\n\r\n", Body/binary>>.

%% A response echoing the request; adds ToTag unless the request has one
%% (`keep' leaves To as it is).
resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case {chappe_sip_msg:to_tag(Msg), ToTag} of
            {undefined, keep} ->
                To0;
            {undefined, _} when Status > 100 ->
                <<To0/binary, ";tag=", ToTag/binary>>;
            _ ->
                To0
        end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CL = integer_to_binary(byte_size(Body)),
    CTH =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    iolist_to_binary(
        [
            <<"SIP/2.0 ">>,
            integer_to_binary(Status),
            <<" ">>,
            Reason,
            <<"\r\n">>,
            ViaLines,
            <<"From: ">>,
            From,
            <<"\r\n">>,
            <<"To: ">>,
            To,
            <<"\r\n">>,
            <<"Call-ID: ">>,
            Call,
            <<"\r\n">>,
            <<"CSeq: ">>,
            CSeq,
            <<"\r\n">>,
            Extra,
            CTH,
            <<"Content-Length: ">>,
            CL,
            <<"\r\n\r\n">>,
            Body
        ]
    ).
