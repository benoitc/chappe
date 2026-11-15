%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The NIF boundary: what the C shim refuses before it reaches sofia.
%%
%% sofia takes headers, bodies, routes and option values as C strings, so
%% an embedded NUL would cut them short; the shim refuses them (badarg).
%% Start options that are present but invalid fail the start instead of
%% being ignored, the message-size cap is bounded, and the stats count the
%% events the engine could not deliver.
%%
%% The suite drives chappe_sip_nif directly, without the application, so
%% each call reaches the shim unchanged.
-module(chappe_sip_nif_boundary_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    nul_in_reply_fields/1,
    nul_in_route/1,
    nul_in_cancel_headers/1,
    send_response_takes_responses/1,
    leg_fields_checked/1,
    max_message_size_bounds/1,
    invalid_capture/1,
    invalid_start_options/1,
    agent_options_bounds/1,
    stats_shape/1,
    events_dropped_counted/1,
    refused_starts_keep_the_vm/1,
    stop_with_internal_reply_queued/1
]).

%% the shim's bounds on max_message_size
-define(MIN_MSG, 1024).
-define(MAX_MSG, (64 * 1024 * 1024)).

all() ->
    [
        {group, live},
        max_message_size_bounds,
        invalid_capture,
        invalid_start_options,
        agent_options_bounds,
        stats_shape,
        events_dropped_counted,
        refused_starts_keep_the_vm,
        stop_with_internal_reply_queued
    ].

%% the cases that need a running engine, one per case
groups() ->
    [
        {live, [], [
            nul_in_reply_fields,
            nul_in_route,
            nul_in_cancel_headers,
            send_response_takes_responses,
            leg_fields_checked
        ]}
    ].

init_per_group(live, Config) ->
    Config.

end_per_group(live, _Config) ->
    ok.

init_per_testcase(Case, Config) ->
    case lists:member(Case, live_cases()) of
        true ->
            {ok, E} = chappe_sip_nif:start(#{contact => contact()}, self()),
            [{engine, E} | Config];
        false ->
            Config
    end.

end_per_testcase(_Case, Config) ->
    case proplists:get_value(engine, Config) of
        undefined -> ok;
        E -> ok = chappe_sip_nif:stop(E)
    end,
    flush(),
    ok.

live_cases() ->
    {live, _, Cases} = lists:keyfind(live, 1, groups()),
    Cases.

%% NUL in the reason, headers, body or to-tag of a response
nul_in_reply_fields(Config) ->
    E = ?config(engine, Config),
    Ok = <<"OK">>,
    Hdr = <<"X-A: a\r\n">>,
    Bad = <<"a", 0, "b">>,
    [
        ?assertError(badarg, F(E, 1, St, R, H, B, T))
     || F <- [fun chappe_sip_nif:respond/7, fun chappe_sip_nif:reliable_respond/7],
        St <- [180],
        {R, H, B, T} <- [
            {Bad, Hdr, <<>>, <<>>},
            {Ok, <<"X-A: a", 0, "b\r\n">>, <<>>, <<>>},
            {Ok, Hdr, Bad, <<>>},
            {Ok, Hdr, <<>>, Bad}
        ]
    ],
    %% a to-tag longer than the shim holds is refused, not cut short
    Long = binary:copy(<<"t">>, 200),
    ?assertError(
        badarg, chappe_sip_nif:respond(E, 1, 200, Ok, <<>>, <<>>, Long)
    ),
    %% the same call without the NUL is taken
    ok = chappe_sip_nif:respond(E, 1, 200, Ok, Hdr, <<>>, <<"tag1">>).

%% NUL in the outbound route of a request or a stateless send
nul_in_route(Config) ->
    E = ?config(engine, Config),
    Raw = options_msg(),
    Route = <<"sip:127.0.0.1", 0, ";lr">>,
    ?assertError(badarg, chappe_sip_nif:request(E, Route, Raw)),
    ?assertError(badarg, chappe_sip_nif:send(E, Route, Raw)),
    {ok, _} = chappe_sip_nif:request(E, <<"sip:127.0.0.1;lr">>, Raw).

nul_in_cancel_headers(Config) ->
    E = ?config(engine, Config),
    ?assertError(
        badarg,
        chappe_sip_nif:cancel(E, 1, <<"Reason: SIP;cause=", 0, "200\r\n">>)
    ),
    ok = chappe_sip_nif:cancel(E, 1, <<"Reason: SIP;cause=200\r\n">>).

%% the call-id, local and remote of a dialog leg: no NUL, a size cap
leg_fields_checked(Config) ->
    E = ?config(engine, Config),
    Cid = <<"cid@127.0.0.1">>,
    L = <<"<sip:a@127.0.0.1>;tag=a">>,
    R = <<"<sip:b@127.0.0.1>;tag=b">>,
    Nul = <<"x", 0, "y">>,
    Huge = binary:copy(<<"a">>, 70000),
    [
        ?assertError(badarg, chappe_sip_nif:leg_create(E, C, Lo, Re))
     || {C, Lo, Re} <- [
            {Nul, L, R},
            {Cid, Nul, R},
            {Cid, L, Nul},
            {Huge, L, R},
            {Cid, Huge, R},
            {Cid, L, Huge}
        ]
    ],
    {ok, H} = chappe_sip_nif:leg_create(E, Cid, L, R),
    receive
        {chappe_sip_engine, _, {op_ok, H}} -> ok
    after 3000 -> ct:fail(no_leg)
    end.

%% max_message_size outside 1 KiB to 64 MiB, or not an integer, fails the
%% start; the bounds themselves are taken
max_message_size_bounds(_Config) ->
    [
        refused(#{contact => contact(), max_message_size => V})
     || V <- [0, 1, ?MIN_MSG - 1, ?MAX_MSG + 1, -5, big, <<"4096">>]
    ],
    [
        started(#{contact => contact(), max_message_size => V})
     || V <- [?MIN_MSG, ?MAX_MSG]
    ],
    ok.

%% a HEP capture URL must name a port in 1..65535
invalid_capture(_Config) ->
    [
        refused(#{contact => contact(), capture => C})
     || C <- [
            <<"udp:127.0.0.1:0;hep=3">>,
            <<"udp:127.0.0.1:65536;hep=3">>,
            <<"udp:127.0.0.1:9x;hep=3">>,
            <<"udp:127.0.0.1:;hep=3">>,
            <<"udp:127.0.0.1:+90;hep=3">>,
            <<"udp:127.0.0.1:9060", 0, ";hep=3">>,
            42
        ]
    ],
    ok.

%% an option that is there but invalid fails the start
invalid_start_options(_Config) ->
    C = contact(),
    Tls = #{contact => <<"sips:127.0.0.1:1;transport=tls">>},
    [
        refused(O)
     || O <- [
            #{contact => <<"sip:127.0.0.1", 0, ":5060">>},
            #{contact => C, ident => 42},
            #{contact => C, ident => <<"a", 0, "b">>},
            #{contact => C, ident => binary:copy(<<"i">>, 200)},
            #{contact => C, tls => not_a_map},
            #{contact => C, tls => Tls#{cert_dir => "/etc"}},
            #{contact => C, tls => Tls#{cert_dir => <<"/e", 0, "tc">>}},
            #{contact => C, tls => Tls#{ciphers => binary:copy(<<"c">>, 400)}},
            #{contact => C, tls => Tls#{passphrase => 7}},
            #{contact => C, tls => Tls#{verify => sometimes}},
            #{contact => C, tls => Tls#{verify_clients => yes}}
        ]
    ],
    ok.

%% the agent settings: each out of its bounds, of the wrong type, or (T2)
%% below the T1 in effect fails the start; the bounds are taken
agent_options_bounds(_Config) ->
    C = contact(),
    Big = binary:copy(<<"p">>, 600),
    [
        refused(O#{contact => C})
     || O <- [
            #{sip_t1 => V}
         || V <- [0, 9, 60001, -1, big, <<"500">>, 1.5]
        ] ++
            [#{sip_t2 => V} || V <- [9, 600001, 400]] ++
            [#{sip_t4 => V} || V <- [0, 9, 600001]] ++
            [#{sip_t1 => 1000, sip_t2 => 999}] ++
            [#{udp_mtu => V} || V <- [0, 575, 65536]] ++
            [#{tcp_keepalive_ms => V} || V <- [0, 999, 3600001, true]] ++
            [
                #{outbound_proxy => V}
             || V <- [
                    <<>>,
                    <<"http://127.0.0.1">>,
                    <<"tel:+15551234">>,
                    <<"sip:127.0.0.1", 0, ":5060">>,
                    <<"sip:", Big/binary>>,
                    "sip:127.0.0.1",
                    42
                ]
            ]
    ],
    [
        started(O#{contact => contact()})
     || O <- [
            #{sip_t1 => 10, sip_t2 => 10, sip_t4 => 10},
            #{sip_t1 => 60000, sip_t2 => 600000, sip_t4 => 600000},
            #{sip_t2 => 500},
            #{udp_mtu => 576},
            #{udp_mtu => 65535},
            #{tcp_keepalive_ms => 1000},
            #{tcp_keepalive_ms => 3600000},
            #{outbound_proxy => <<"sip:127.0.0.1:5999;transport=udp">>},
            #{outbound_proxy => <<"SIPS:proxy.example.com">>}
        ]
    ],
    ok.

stats_shape(_Config) ->
    #{
        incoming := I,
        discarded := D,
        events_dropped := Dr,
        alloc_failed := A
    } = chappe_sip_nif:stats(),
    true = lists:all(fun(N) -> is_integer(N) andalso N >= 0 end, [I, D, Dr, A]).

%% an event the owner cannot take is counted: the started event goes to
%% an owner that is already dead
events_dropped_counted(_Config) ->
    #{events_dropped := D0} = chappe_sip_nif:stats(),
    {Dead, Ref} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Ref, process, Dead, _} -> ok
    end,
    {error, badarg} = chappe_sip_nif:start(#{contact => contact()}, Dead),
    #{events_dropped := D1} = chappe_sip_nif:stats(),
    ?assert(D1 > D0).

%% A start refused before its thread exists frees the engine without a
%% thread to join: the destructor used to compare the unset thread id and
%% abort the VM. Each refusal path, many times over; the node must live.
refused_starts_keep_the_vm(_Config) ->
    C = contact(),
    Bad = [
        #{},
        #{contact => 42},
        #{contact => <<>>},
        #{contact => C, contacts => [bad]},
        #{contact => C, contacts => [{<<"sip:127.0.0.1:1">>, <<"x">>}]},
        #{contact => C, max_message_size => 0}
    ],
    lists:foreach(
        fun(_) -> [{error, badarg} = chappe_sip_nif:start(O, self()) || O <- Bad] end,
        lists:seq(1, 100)
    ),
    %% the singleton is free again: a good start works
    started(#{contact => contact()}).

%% send_response/2 forwards a response statelessly; a request is refused.
%% sofia would send it as a stateless transaction and leak the message
%% when that fails, which the NIF fuzz suite found under LeakSanitizer.
send_response_takes_responses(Config) ->
    E = ?config(engine, Config),
    ok = chappe_sip_nif:send_response(E, options_msg()),
    receive
        {chappe_sip_engine, _, {op_failed, _, <<"not a response">>}} -> ok
    after 3000 -> ct:fail(request_forwarded)
    end.

%% helpers

refused(Opts) ->
    case chappe_sip_nif:start(Opts, self()) of
        {error, badarg} ->
            ok;
        {ok, E} ->
            ok = chappe_sip_nif:stop(E),
            flush(),
            ct:fail({accepted, Opts});
        Other ->
            ct:fail({unexpected, Opts, Other})
    end.

started(Opts) ->
    {ok, E} = chappe_sip_nif:start(Opts, self()),
    ok = chappe_sip_nif:stop(E),
    flush().

%% the transports chappe_sip_binds would restrict a plain contact to
contact() ->
    P = integer_to_binary(chappe_sip_test_port:pick()),
    <<"sip:127.0.0.1:", P/binary, ";transport=udp,tcp">>.

options_msg() ->
    <<
        "OPTIONS sip:nb@127.0.0.1:9 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:9;branch=z9hG4bKnifa1\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:ct@127.0.0.1>;tag=nb\r\n"
        "To: <sip:nb@127.0.0.1>\r\n"
        "Call-ID: nifa-boundary@127.0.0.1\r\n"
        "CSeq: 1 OPTIONS\r\n"
        "Content-Length: 0\r\n\r\n"
    >>.

flush() ->
    receive
        {chappe_sip_engine, _, _} -> flush()
    after 0 -> ok
    end.

%% A request nta cannot send is answered by nta itself, through a message it
%% posts to its own root. With the stop right behind, that message was still
%% queued when the root went away, and it and the root leaked. The leak shows
%% at VM exit under LeakSanitizer (test/asan/run.sh).
stop_with_internal_reply_queued(_Config) ->
    lists:foreach(
        fun(_) ->
            {ok, E} = chappe_sip_nif:start(#{contact => contact()}, self()),
            Route = <<"sip:127.0.0.1:5999;transport=sctp">>,
            [
                chappe_sip_nif:request(E, Route, unsendable_request(N))
             || N <- lists:seq(1, 20)
            ],
            ok = chappe_sip_nif:stop(E)
        end,
        lists:seq(1, 20)
    ).

unsendable_request(N) ->
    Id = integer_to_binary(N),
    <<"OPTIONS sip:uas@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:5999;rport;branch=z9hG4bK", Id/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:a@127.0.0.1>;tag=f1\r\n"
      "To: <sip:uas@127.0.0.1>\r\n"
      "Call-ID: ", Id/binary, "@127.0.0.1\r\n"
      "CSeq: 1 OPTIONS\r\n"
      "Content-Length: 0\r\n\r\n">>.
