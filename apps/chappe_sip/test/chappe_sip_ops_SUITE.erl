%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Operational limits and failure policies.
%%
%% The engine failure policy when the stack thread stops answering health
%% checks (degrade keeps the node, halt stops it, run on a peer node), the
%% dialog ceiling, and the message-size cap taken from the application
%% config when start/1 sets none.
-module(chappe_sip_ops_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    health_degrade/1,
    health_halt/1,
    max_dialogs/1,
    max_message_size_from_config/1,
    max_message_size_out_of_range/1
]).

-define(ENV, [
    engine_mod,
    engine_failure_action,
    health_interval_ms,
    health_miss_limit,
    max_dialogs,
    max_message_size
]).

all() ->
    [
        health_degrade,
        health_halt,
        max_dialogs,
        max_message_size_from_config,
        max_message_size_out_of_range
    ].

init_per_testcase(health_halt, Config) ->
    Config;
init_per_testcase(health_degrade, Config) ->
    ok = chappe_sip_engine_fake:boot(),
    set_env([
        {engine_mod, chappe_sip_engine_fake},
        {engine_failure_action, degrade},
        {health_interval_ms, 100},
        {health_miss_limit, 2}
    ]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config;
init_per_testcase(max_dialogs, Config) ->
    set_env([{engine_mod, chappe_sip_nif}, {max_dialogs, 1}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config;
init_per_testcase(max_message_size_from_config, Config) ->
    set_env([{engine_mod, chappe_sip_nif}, {max_message_size, 1500}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config;
init_per_testcase(max_message_size_out_of_range, Config) ->
    set_env([{engine_mod, chappe_sip_nif}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_testcase(health_halt, _Config) ->
    ok;
end_per_testcase(Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok = application:stop(chappe_sip),
    [application:unset_env(chappe_sip, K) || K <- ?ENV],
    _ = Case =:= health_degrade andalso chappe_sip_engine_fake:shutdown(),
    ok.

set_env(KVs) ->
    [application:set_env(chappe_sip, K, V) || {K, V} <- KVs],
    ok.

%% engine_failure_action => degrade: a stack that stops answering health
%% checks is declared hung and torn down; SIP is down, the node stays up.
health_degrade(_Config) ->
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5998">>}),
    ok = chappe_sip_engine:check_health(1000),
    ok = chappe_sip_engine_fake:set_health(false),
    ok = wait_until(
        fun() ->
            chappe_sip_engine:check_health(200) =:= {error, not_started}
        end,
        50
    ),
    ?assert(is_process_alive(whereis(chappe_sip_engine))).

%% engine_failure_action => halt (the default): the node stops, so
%% heart or systemd restarts it. Runs on a peer node.
health_halt(_Config) ->
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, _} = peer:start_link(#{connection => standard_io, args => Paths}),
    Ref = erlang:monitor(process, Peer),
    ok = peer:call(Peer, chappe_sip_engine_fake, boot, []),
    [
        ok = peer:call(Peer, application, set_env, [chappe_sip, K, V])
     || {K, V} <- [
            {engine_mod, chappe_sip_engine_fake},
            {engine_failure_action, halt},
            {health_interval_ms, 100},
            {health_miss_limit, 2}
        ]
    ],
    {ok, _} = peer:call(Peer, application, ensure_all_started, [chappe_sip]),
    ok = peer:call(
        Peer,
        chappe_sip,
        start,
        [#{contact => <<"sip:127.0.0.1:5997">>}]
    ),
    ok = peer:call(Peer, chappe_sip_engine_fake, set_health, [false]),
    receive
        {'DOWN', Ref, process, Peer, _} -> ok
    after 10000 -> ct:fail(peer_still_up)
    end.

%% The dialog ceiling: past max_dialogs, create_uas fails with max_dialogs.
max_dialogs(_Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()}),
        Test ! {uas, R},
        case R of
            {ok, _} ->
                receive
                    stop -> ok
                after 3000 -> ok
                end;
            {error, _} ->
                chappe_sip_res:send(Res, 503)
        end
    end),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, invite(Sock, <<"md1">>)),
    receive
        {uas, R1} -> ?assertMatch({ok, _}, R1)
    after 5000 -> ct:fail(no_first_uas)
    end,
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, invite(Sock, <<"md2">>)),
    receive
        {uas, R2} -> ?assertEqual({error, max_dialogs}, R2)
    after 5000 -> ct:fail(no_second_uas)
    end,
    gen_udp:close(Sock).

%% With no max_message_size in start/1 the configured one reaches the
%% engine: a response bigger than it is refused, not sent.
max_message_size_from_config(_Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Big = chappe_sip_res:send(Res, 200, #{
            body => binary:copy(<<"a">>, 3000)
        }),
        Test ! {big, Big},
        chappe_sip_res:send(Res, 200)
    end),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, options(Sock)),
    receive
        {big, R} -> ?assertEqual({error, too_large}, R)
    after 5000 -> ct:fail(no_handler)
    end,
    receive
        {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>> = B} ->
            ?assert(byte_size(B) < 1500)
    after 5000 -> ct:fail(no_200)
    end,
    gen_udp:close(Sock).

%% A size cap the engine cannot honour (under 1 KiB, over 64 MiB) fails
%% the start instead of being ignored or truncated.
max_message_size_out_of_range(_Config) ->
    Contact = fun() ->
        <<"sip:127.0.0.1:",
            (integer_to_binary(chappe_sip_test_port:pick()))/binary>>
    end,
    [
        ?assertEqual(
            {error, badarg},
            chappe_sip:start(#{
                contact => Contact(),
                max_message_size => Size
            })
        )
     || Size <- [0, 512, 64 * 1024 * 1024 + 1]
    ],
    ok = chappe_sip:start(#{contact => Contact(), max_message_size => 1024}).

%% ---- helpers ----

wait_until(_Fun, 0) ->
    {error, timeout};
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, N - 1)
    end.

sdp() ->
    <<
        "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
    >>.

port(Sock) ->
    {ok, P} = inet:port(Sock),
    integer_to_binary(P).

invite(Sock, FT) ->
    P = port(Sock),
    S = sdp(),
    <<
        "INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";rport;branch=z9hG4bK",
        FT/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:caller@127.0.0.1:",
        P/binary,
        ">;tag=",
        FT/binary,
        "\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Contact: <sip:caller@127.0.0.1:",
        P/binary,
        ">\r\n"
        "Call-ID: ops-",
        FT/binary,
        "@ct\r\nCSeq: 1 INVITE\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: ",
        (integer_to_binary(byte_size(S)))/binary,
        "\r\n\r\n",
        S/binary
    >>.

options(Sock) ->
    P = port(Sock),
    <<
        "OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";rport;branch=z9hG4bKops\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:p@127.0.0.1:",
        P/binary,
        ">;tag=o1\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Call-ID: ops-opt@ct\r\nCSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n"
    >>.
