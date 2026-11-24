%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Boundary fuzz of the C NIF (chappe_sip_nif) against a running engine.
%%
%% Seeded random arguments for every NIF, random op sequences on the
%% handles the engine hands out (with engine restarts), random start
%% options, and mutated SIP over UDP and TCP to the engine's listener. The
%% VM must not crash, and every call returns ok, {ok, Handle}, {error, _}
%% or raises badarg (stats/0 its counter map). The engine must still
%% answer a health round trip at the end of each case.
%%
%% Gated: runs only with FUZZ=1, meant for the ASan + UBSan build
%% (make fuzz, test/asan/run.sh fuzz). FUZZ_ITERS sets the iterations per
%% case (default 10000), FUZZ_SEED the seed (default random). The seed is
%% printed and set as the case comment; the same seed replays the same
%% inputs, though not the same thread interleavings.
-module(chappe_sip_nif_fuzz_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    nif_args/1,
    op_sequences/1,
    start_options/1,
    udp_datagrams/1,
    tcp_stream/1
]).

-define(NIF, chappe_sip_nif).
-define(LOCAL, {127, 0, 0, 1}).

all() ->
    [nif_args, op_sequences, udp_datagrams, tcp_stream, start_options].

init_per_suite(Config) ->
    case os:getenv("FUZZ") of
        "1" ->
            %% the engine is a singleton: nothing else may hold it
            _ = application:stop(chappe_sip),
            _ = application:load(chappe_sip),
            Seed = seed(),
            Iters = iters(),
            Corpus = corpus(Config),
            ct:pal(
                "nif fuzz: FUZZ_SEED=~b FUZZ_ITERS=~b, ~b corpus messages",
                [Seed, Iters, length(Corpus)]
            ),
            [{seed, Seed}, {iters, Iters}, {corpus, Corpus} | Config];
        _ ->
            {skip, "set FUZZ=1 (make fuzz)"}
    end.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Seed = erlang:phash2({?config(seed, Config), Case}),
    _ = rand:seed(exsss, {Seed, Seed bxor 16#5bd1e995, 16#1b873593}),
    ct:comment("FUZZ_SEED=~b", [?config(seed, Config)]),
    case Case of
        start_options ->
            Config;
        _ ->
            Port = chappe_sip_test_port:pick(),
            Sink = spawn_link(fun() -> sink_init(Seed) end),
            {ok, E} = start_engine(Port, Sink, 20),
            [{port, Port}, {sink, Sink}, {engine, E} | Config]
    end.

end_per_testcase(_Case, Config) ->
    %% lift any block a random block/2 call left on the test's address
    ok = ?NIF:block(<<"127.0.0.1">>, 0),
    case ?config(engine, Config) of
        undefined ->
            ok;
        _ ->
            %% op_sequences restarts the engine: the sink has the current one
            Sink = ?config(sink, Config),
            E = sink_engine(Sink),
            alive(E, Sink),
            ok = ?NIF:stop(E),
            unlink(Sink),
            exit(Sink, kill),
            ok
    end.

%% ---- cases ---------------------------------------------------------------

%% Every NIF with arguments of the right type most of the time, and any
%% term the rest of it.
nif_args(Config) ->
    Ctx = ctx(Config),
    Funs = funs(),
    repeat(?config(iters, Config), fun(_) ->
        {F, Kinds} = pick(Funs),
        Args = [arg(K, Ctx) || K <- Kinds],
        call(F, Args)
    end).

%% Ops on the handles the engine hands out and reports, mixed with stale
%% and made-up ones, with the engine stopped and started under them.
op_sequences(Config) ->
    Port = ?config(port, Config),
    Sink = ?config(sink, Config),
    put(engine, ?config(engine, Config)),
    repeat(?config(iters, Config), fun(_) ->
        E = get(engine),
        Ctx = (ctx(Config))#{engine => E},
        case rand:uniform(100) of
            N when N =< 2 ->
                ok = ?NIF:stop(E),
                {ok, E2} = start_engine(Port, Sink, 20),
                put(engine, E2);
            N when N =< 30 ->
                R = call(request, [E, local_route(), raw(Ctx)]),
                keep(R);
            N when N =< 40 ->
                R = call(leg_create, [E, bin(), addr(), addr()]),
                keep(R);
            N when N =< 45 ->
                call(send, [E, local_route(), raw(Ctx)]);
            N when N =< 50 ->
                call(health, [E]);
            _ ->
                {F, Kinds} = pick(handle_funs()),
                call(F, [E | [arg(K, Ctx) || K <- tl(Kinds)]])
        end
    end).

%% Random start options: mutated contacts, idents, binds, TLS maps, sizes
%% and capture URLs. A start that succeeds is stopped at once.
start_options(Config) ->
    Sink = spawn_link(fun() -> sink_init(1) end),
    repeat(max(1, ?config(iters, Config) div 10), fun(_) ->
        Opts = start_opts(),
        case call(start, [Opts, Sink]) of
            {ok, E} -> ok = ?NIF:stop(E);
            _ -> ok
        end
    end),
    unlink(Sink),
    exit(Sink, kill).

%% Mutated SIP datagrams to the UDP listener; the sink answers the requests
%% that parse.
udp_datagrams(Config) ->
    Port = ?config(port, Config),
    {ok, S} = gen_udp:open(0, [binary, {active, false}, {ip, ?LOCAL}]),
    Ctx = ctx(Config),
    repeat(?config(iters, Config), fun(I) ->
        ok = udp_send(S, Port, raw(Ctx)),
        _ = gen_udp:recv(S, 0, 0),
        I rem 500 =:= 0 andalso alive(engine(Config), ?config(sink, Config))
    end),
    gen_udp:close(S).

%% Mutated SIP over TCP, cut at random points, on fresh and reused
%% connections.
tcp_stream(Config) ->
    Port = ?config(port, Config),
    Ctx = ctx(Config),
    repeat(max(1, ?config(iters, Config) div 10), fun(_) ->
        case gen_tcp:connect(?LOCAL, Port, [binary, {active, false}], 2000) of
            {ok, S} ->
                lists:foreach(
                    fun(_) -> _ = send_chunks(S, raw(Ctx)) end,
                    lists:seq(1, rand:uniform(4))
                ),
                _ = gen_tcp:recv(S, 0, 10),
                gen_tcp:close(S);
            {error, _} ->
                ok
        end
    end).

%% ---- the call and its contract ------------------------------------------

call(F, Args) ->
    try apply(?NIF, F, Args) of
        R ->
            valid(F, R) orelse ct:fail({bad_return, F, Args, R}),
            R
    catch
        error:badarg ->
            badarg;
        C:Why:St ->
            ct:fail({raised, F, Args, C, Why, St})
    end.

valid(stats, #{} = M) -> lists:all(fun is_integer/1, maps:values(M));
valid(_, ok) -> true;
valid(_, {ok, H}) when is_integer(H) -> true;
valid(start, {ok, E}) when is_reference(E) -> true;
valid(_, {error, _}) -> true;
valid(_, _) -> false.

keep({ok, H}) when is_integer(H) ->
    put(handles, lists:sublist([H | handles()], 64));
keep(_) ->
    ok.

handles() ->
    case get(handles) of
        undefined -> [];
        L -> L
    end.

%% ---- NIFs and argument kinds --------------------------------------------

funs() ->
    [
        {respond, [engine, handle, status, bin, hdrs, body, bin]},
        {reliable_respond, [engine, handle, status, bin, hdrs, body, bin]},
        {request, [engine, route, raw]},
        {request, [engine, route, raw, bin]},
        {request, [engine, route, raw, bin, bin]},
        {proxy_mark, [engine, handle]},
        {send, [engine, route, raw]},
        {send, [engine, route, raw, bin]},
        {send_response, [engine, raw]},
        {relay, [engine, handle, status, raw]},
        {cancel, [engine, handle]},
        {cancel, [engine, handle, hdrs]},
        {txn_done, [engine, handle]},
        {leg_create, [engine, bin, addr, addr]},
        {leg_destroy, [engine, handle]},
        {health, [engine]},
        {discard, [engine, handle]},
        {block, [ip, ttl]},
        {stats, []},
        {stop, [junk]}
    ].

handle_funs() ->
    [FK || {_, [engine, handle | _]} = FK <- funs()].

%% stop/1 never gets the live engine: the other calls need it
arg(junk, Ctx) ->
    any(Ctx#{engine := make_ref()});
arg(K, Ctx) ->
    case rand:uniform(100) =< 85 of
        true -> typed(K, Ctx);
        false -> any(Ctx)
    end.

typed(engine, #{engine := E}) ->
    E;
typed(handle, Ctx) ->
    handle(Ctx);
typed(status, _) ->
    pick([
        100,
        180,
        183,
        200,
        202,
        302,
        404,
        487,
        500,
        603,
        699,
        99,
        0,
        700,
        1000,
        -1,
        65536 + 200
    ]);
typed(bin, _) ->
    bin();
typed(hdrs, _) ->
    hdrs();
typed(body, _) ->
    body();
typed(route, _) ->
    route();
typed(raw, Ctx) ->
    raw(Ctx);
typed(addr, _) ->
    addr();
typed(ip, _) ->
    pick([
        <<"10.9.8.7">>,
        <<"::2">>,
        <<"300.1.1.1">>,
        <<>>,
        <<"10.0.0.1", 0, "x">>,
        rand_bytes(20)
    ]);
typed(ttl, _) ->
    pick([0, 1, 50, 1 bsl 32, 1 bsl 64, -1]).

handle(#{sink := Sink}) ->
    Seen = sink_handles(Sink) ++ handles(),
    case {Seen, rand:uniform(10)} of
        {[_ | _], N} when N =< 7 -> pick(Seen);
        _ ->
            pick([
                0,
                1,
                2,
                1 bsl 31,
                1 bsl 32,
                1 bsl 63,
                1 bsl 64 - 1,
                rand:uniform(1000)
            ])
    end.

any(Ctx) ->
    case rand:uniform(14) of
        1 ->
            maps:get(engine, Ctx);
        2 ->
            make_ref();
        3 ->
            pick([
                0,
                1,
                -1,
                1 bsl 31,
                1 bsl 32,
                1 bsl 63,
                1 bsl 64,
                -(1 bsl 63),
                1 bsl 200
            ]);
        4 ->
            rand_bytes(rand:uniform(64));
        5 ->
            pick([undefined, ok, true, false, nil, '']);
        6 ->
            [bin(), 1];
        7 ->
            {bin(), 2};
        8 ->
            #{contact => bin()};
        9 ->
            self();
        10 ->
            1.5;
        11 ->
            <<>>;
        12 ->
            big_bin();
        13 ->
            list_to_binary(lists:duplicate(rand:uniform(8), 0));
        14 ->
            fun() -> ok end
    end.

bin() ->
    case rand:uniform(8) of
        1 -> <<>>;
        2 -> rand_bytes(rand:uniform(32));
        3 -> <<"z9hG4bK", (rand_bytes(8))/binary>>;
        4 -> <<"tag", 0, "x">>;
        5 -> big_bin();
        6 -> <<"udp1">>;
        _ -> printable(rand:uniform(40))
    end.

hdrs() ->
    Lines = [
        pick([
            <<"X-Fuzz: 1">>,
            <<"Contact: <sip:127.0.0.1>">>,
            <<"Require: 100rel">>,
            <<"Supported: timer">>,
            <<"Content-Type: application/sdp">>,
            <<"Via: bogus">>,
            <<"Content-Length: 99999">>,
            <<"CSeq: x">>,
            <<"Route: <sip:127.0.0.1;lr>">>,
            <<"X-Nul: a", 0, "b">>,
            <<":">>,
            <<"\r\n">>,
            printable(60),
            rand_bytes(30)
        ])
     || _ <- lists:seq(1, rand:uniform(6))
    ],
    mutate(iolist_to_binary(lists:join(<<"\r\n">>, Lines)), 1).

body() ->
    pick([
        <<>>,
        sdp(),
        mutate(sdp(), 3),
        rand_bytes(100),
        big_bin(),
        <<"v=0", 0, "\r\n">>
    ]).

route() ->
    case rand:uniform(6) of
        1 -> undefined;
        2 -> pick([1, 2, 1 bsl 32, 0]);
        _ -> local_route()
    end.

%% stays on the loopback so a fuzzed request never leaves the host
local_route() ->
    P = integer_to_binary(5000 + rand:uniform(1000)),
    R =
        <<"sip:127.0.0.1:", P/binary,
            (pick([
                <<>>,
                <<";lr">>,
                <<";transport=tcp">>,
                <<";transport=udp;lr">>
            ]))/binary>>,
    case rand:uniform(5) of
        1 -> <<R/binary, (pick([<<0>>, <<";">>, <<"%00">>, <<">">>]))/binary>>;
        _ -> R
    end.

addr() ->
    case rand:uniform(5) of
        1 ->
            rand_bytes(rand:uniform(80));
        2 ->
            big_bin();
        _ ->
            <<"<sip:", (printable(8))/binary, "@127.0.0.1>;tag=",
                (printable(6))/binary>>
    end.

big_bin() ->
    rand_bytes(pick([1024, 65536, 262144, 262145, 1048576]) - rand:uniform(2)).

rand_bytes(N) ->
    rand:bytes(N).

printable(N) ->
    <<<<(32 + rand:uniform(94))>> || _ <- lists:seq(1, N)>>.

pick(L) ->
    lists:nth(rand:uniform(length(L)), L).

%% ---- SIP inputs -----------------------------------------------------------

raw(#{corpus := Corpus}) ->
    Base =
        case rand:uniform(3) of
            1 when Corpus =/= [] -> pick(Corpus);
            _ -> template()
        end,
    mutate(Base, rand:uniform(5) - 1).

template() ->
    Branch = <<"z9hG4bK", (integer_to_binary(rand:uniform(1 bsl 40)))/binary>>,
    CallId = integer_to_binary(rand:uniform(1 bsl 40)),
    Via = <<"Via: SIP/2.0/UDP 127.0.0.1:5999;rport;branch=", Branch/binary>>,
    Common = [
        Via,
        <<"Max-Forwards: 70">>,
        <<"From: <sip:fuzz@127.0.0.1>;tag=f1">>,
        <<"To: <sip:uas@127.0.0.1>">>,
        <<"Call-ID: ", CallId/binary, "@127.0.0.1">>
    ],
    case rand:uniform(5) of
        1 ->
            msg(
                <<"OPTIONS sip:uas@127.0.0.1 SIP/2.0">>,
                Common ++ [<<"CSeq: 1 OPTIONS">>],
                <<>>
            );
        2 ->
            msg(
                <<"INVITE sip:uas@127.0.0.1 SIP/2.0">>,
                Common ++
                    [
                        <<"CSeq: 1 INVITE">>,
                        <<"Contact: <sip:fuzz@127.0.0.1:5999>">>,
                        <<"Supported: 100rel, timer">>,
                        <<"Session-Expires: 90">>,
                        <<"Content-Type: application/sdp">>
                    ],
                sdp()
            );
        3 ->
            msg(
                <<"SIP/2.0 200 OK">>,
                Common ++ [<<"CSeq: 1 INVITE">>],
                <<>>
            );
        4 ->
            msg(
                <<"ACK sip:uas@127.0.0.1 SIP/2.0">>,
                Common ++ [<<"CSeq: 1 ACK">>],
                <<>>
            );
        5 ->
            msg(
                <<"SUBSCRIBE sip:uas@127.0.0.1 SIP/2.0">>,
                Common ++
                    [
                        <<"CSeq: 1 SUBSCRIBE">>,
                        <<"Event: presence">>,
                        <<"Expires: 60">>
                    ],
                <<>>
            )
    end.

msg(Start, Hdrs, Body) ->
    Len = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
        [
            Start,
            <<"\r\n">>,
            [[H, <<"\r\n">>] || H <- Hdrs],
            <<"Content-Length: ", Len/binary, "\r\n\r\n">>,
            Body
        ]
    ).

sdp() ->
    <<
        "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\nm=audio 4000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
    >>.

mutate(B, 0) -> B;
mutate(B, N) -> mutate(mutate1(B), N - 1).

mutate1(<<>>) ->
    rand_bytes(rand:uniform(16));
mutate1(B) ->
    Sz = byte_size(B),
    P = rand:uniform(Sz) - 1,
    <<Pre:P/binary, Post/binary>> = B,
    case rand:uniform(11) of
        1 ->
            <<Pre/binary, (rand:uniform(256) - 1), (drop(Post, 1))/binary>>;
        2 ->
            <<Pre/binary, (rand_bytes(rand:uniform(8)))/binary, Post/binary>>;
        3 ->
            <<Pre/binary, (drop(Post, rand:uniform(16)))/binary>>;
        4 ->
            <<Pre/binary, 0, Post/binary>>;
        5 ->
            Pre;
        6 ->
            <<Pre/binary, (take(Post, 40))/binary, Post/binary>>;
        7 ->
            <<Pre/binary,
                (pick([
                    <<"\r\n">>,
                    <<"\r\n\r\n">>,
                    <<"\n">>,
                    <<"\r">>,
                    <<" ">>,
                    <<"\t">>,
                    <<",">>,
                    <<";">>,
                    <<"<">>,
                    <<"\"">>,
                    <<"%">>
                ]))/binary, Post/binary>>;
        8 ->
            <<Pre/binary, "Content-Length: ",
                (pick([
                    <<"0">>,
                    <<"-1">>,
                    <<"4294967296">>,
                    <<"99999999999999999999">>,
                    <<"1">>
                ]))/binary, "\r\n", Post/binary>>;
        9 ->
            <<Pre/binary,
                (binary:copy(take(Post, 8), rand:uniform(200)))/binary,
                Post/binary>>;
        10 ->
            <<Pre/binary,
                (pick([
                    <<"Via: SIP/2.0/UDP ">>,
                    <<"CSeq: ">>,
                    <<"Call-ID: ">>,
                    <<"To: ">>,
                    <<"From: ">>,
                    <<"Contact: ">>,
                    <<"Route: ">>,
                    <<"Record-Route: ">>,
                    <<"RSeq: ">>,
                    <<"RAck: ">>,
                    <<"Expires: ">>,
                    <<"Content-Encoding: gzip\r\n">>,
                    <<"Content-Type: multipart/mixed;boundary=x\r\n">>
                ]))/binary, Post/binary>>;
        11 ->
            <<Post/binary, Pre/binary>>
    end.

drop(B, N) when byte_size(B) =< N -> <<>>;
drop(B, N) -> binary:part(B, N, byte_size(B) - N).

take(B, N) -> binary:part(B, 0, min(N, byte_size(B))).

%% the RFC 4475 torture messages, next to this suite's beam
corpus(_Config) ->
    Dir = filename:join([
        filename:dirname(code:which(?MODULE)),
        "chappe_sip_rfc4475_SUITE_data",
        "rfc4475"
    ]),
    [
        B
     || F <- filelib:wildcard(filename:join(Dir, "*.dat")),
        {ok, B} <- [file:read_file(F)]
    ].

start_opts() ->
    P = integer_to_binary(chappe_sip_test_port:pick()),
    Contact = mutate(
        <<"sip:127.0.0.1:", P/binary,
            (pick([
                <<>>,
                <<";transport=udp">>,
                <<";transport=tcp">>,
                <<";maddr=127.0.0.1">>
            ]))/binary>>,
        rand:uniform(3) - 1
    ),
    Base = #{contact => Contact},
    Extra = [
        {ident, pick([bin(), <<"a">>, 7])},
        {contacts,
            pick([
                [],
                [{<<"sip:127.0.0.1:", P/binary, "1">>, <<"b">>}],
                [bin()],
                [{bin(), bin(), bin()}],
                bin()
            ])},
        {max_message_size,
            pick([
                0,
                1,
                512,
                1024,
                65536,
                1 bsl 32,
                1 bsl 33 + 7,
                1 bsl 64,
                -5,
                foo
            ])},
        {capture,
            pick([
                <<"udp:127.0.0.1:9;hep=3;capture_id=1">>,
                <<"udp:127.0.0.1:0;hep=99">>,
                <<"udp:">>,
                <<"udp:127.0.0.1:", 0, ";hep=3">>,
                <<"udp:127.0.0.1:70000;hep=3">>,
                bin()
            ])},
        {tls,
            pick([
                #{},
                #{contact => bin()},
                #{
                    contact => <<"sips:127.0.0.1:", P/binary, "2">>,
                    cert_dir => <<"/nonexistent">>,
                    verify => pick([none, peer, sometimes])
                },
                bin()
            ])}
    ],
    maps:from_list(
        [KV || KV <- Extra, rand:uniform(3) =:= 1] ++
            maps:to_list(Base)
    ).

%% ---- engine, sink and helpers --------------------------------------------

start_engine(Port, Sink, 0) ->
    ct:fail({engine_start_failed, Port, Sink});
start_engine(Port, Sink, N) ->
    Contact = <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>,
    case ?NIF:start(#{contact => Contact}, Sink) of
        {ok, E} ->
            Sink ! {engine, E},
            {ok, E};
        {error, _} ->
            timer:sleep(100),
            start_engine(Port, Sink, N - 1)
    end.

engine(Config) ->
    ?config(engine, Config).

ctx(Config) ->
    #{
        engine => ?config(engine, Config),
        sink => ?config(sink, Config),
        corpus => ?config(corpus, Config)
    }.

%% The engine's owner: answers the requests that reach it (so respond runs
%% on live transactions), remembers the handles it sees, relays health.
sink_init(Seed) ->
    _ = rand:seed(exsss, {Seed, 3, 7}),
    sink(undefined, [], undefined).

sink(E, Hs, Waiter) ->
    receive
        {engine, E2} ->
            sink(E2, [], Waiter);
        {engine_of, From} ->
            From ! {engine_of, self(), E},
            sink(E, Hs, Waiter);
        {handles, From} ->
            From ! {handles, self(), Hs},
            sink(E, Hs, Waiter);
        {health_wait, From} ->
            sink(E, Hs, From);
        {chappe_sip_engine, _, {health_ok, _}} when is_pid(Waiter) ->
            Waiter ! {health_ok, self()},
            sink(E, Hs, undefined);
        {chappe_sip_engine, _, {request, TxnH, _Leg, _Meta, _Raw}} ->
            case rand:uniform(4) > 1 andalso E =/= undefined of
                true ->
                    %% a handle a stop already released gives badarg
                    try
                        ?NIF:respond(
                            E,
                            TxnH,
                            pick([100, 180, 200, 404, 500]),
                            <<"Fuzz">>,
                            <<>>,
                            <<>>,
                            <<"t1">>
                        )
                    catch
                        error:badarg -> ok
                    end;
                false ->
                    ok
            end,
            sink(E, lists:sublist([TxnH | Hs], 64), Waiter);
        {chappe_sip_engine, _, Ev} when
            is_tuple(Ev),
            is_integer(element(2, Ev))
        ->
            sink(E, lists:sublist([element(2, Ev) | Hs], 64), Waiter);
        _ ->
            sink(E, Hs, Waiter)
    end.

sink_engine(Sink) ->
    Sink ! {engine_of, self()},
    receive
        {engine_of, Sink, E} -> E
    after 5000 -> ct:fail(sink_not_answering)
    end.

sink_handles(Sink) ->
    Sink ! {handles, self()},
    receive
        {handles, Sink, Hs} -> Hs
    after 2000 -> []
    end.

%% the stack thread still runs its loop
alive(E, Sink) ->
    Sink ! {health_wait, self()},
    ok = ?NIF:health(E),
    receive
        {health_ok, Sink} -> ok
    after 5000 -> ct:fail(engine_not_answering)
    end.

udp_send(S, Port, B) ->
    case gen_udp:send(S, ?LOCAL, Port, B) of
        ok -> ok;
        %% larger than a datagram, or the socket buffer is full
        {error, _} -> ok
    end.

send_chunks(_S, <<>>) ->
    ok;
send_chunks(S, B) ->
    N = min(byte_size(B), rand:uniform(512)),
    <<C:N/binary, Rest/binary>> = B,
    case gen_tcp:send(S, C) of
        ok -> send_chunks(S, Rest);
        {error, _} = Err -> Err
    end.

repeat(N, F) ->
    lists:foreach(F, lists:seq(1, N)).

seed() ->
    case os:getenv("FUZZ_SEED") of
        false -> erlang:phash2({os:system_time(), node(), self()});
        "" -> erlang:phash2({os:system_time(), node(), self()});
        S -> list_to_integer(S)
    end.

iters() ->
    case os:getenv("FUZZ_ITERS") of
        false -> 10000;
        "" -> 10000;
        S -> list_to_integer(S)
    end.
