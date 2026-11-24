%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Engine layer + inbound pipeline.
%%
%% fake group: chappe_sip_engine_fake drives the whole TU layer without C.
%% live group: real NIF engine, SIP over gen_udp.
-module(chappe_sip_pipeline_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    dispatch_to_handler/1,
    no_route_405/1,
    middleware_stops_chain/1,
    worker_cap_503/1,
    deadline_500/1,
    crash_500/1,
    duplicate_final/1,
    fake_health/1,
    unsupported_require_420/1,
    exit_after_final/1,
    middleware_locals/1,
    middleware_bad_next/1
]).
-export([log/2]).
-export([live_options_headers/1, live_message_dispatch/1]).

all() ->
    [{group, fake}, {group, live}].

groups() ->
    [
        {fake, [sequence], [
            dispatch_to_handler,
            no_route_405,
            middleware_stops_chain,
            worker_cap_503,
            deadline_500,
            crash_500,
            duplicate_final,
            fake_health,
            unsupported_require_420,
            exit_after_final,
            middleware_locals,
            middleware_bad_next
        ]},
        {live, [sequence], [live_options_headers, live_message_dispatch]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(fake, Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_engine_fake,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config;
init_per_group(live, Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_group(_, _Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(Case, Config) ->
    case lists:member(Case, element(3, lists:keyfind(fake, 1, groups()))) of
        true ->
            ok = chappe_sip_engine_fake:boot(),
            ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5999">>});
        false ->
            ok
    end,
    Config.

end_per_testcase(Case, _Config) ->
    _ = chappe_sip:stop(),
    ok = chappe_sip_engine:reset_routes(),
    case lists:member(Case, element(3, lists:keyfind(fake, 1, groups()))) of
        true -> chappe_sip_engine_fake:shutdown();
        false -> ok
    end,
    restore_limits(),
    ok.

restore_limits() ->
    application:unset_env(chappe_sip, max_request_workers),
    application:unset_env(chappe_sip, handler_deadline_ms).

%% ---- fake group ----

dispatch_to_handler(_Config) ->
    Test = self(),
    ok = chappe_sip:message(fun(Req, Res) ->
        Test ! {handled, chappe_sip_req:method(Req), chappe_sip_req:body(Req)},
        ok = chappe_sip_res:send(Res, 200, #{
            reason => <<"OK">>,
            headers => [{<<"X-Seen">>, <<"1">>}]
        })
    end),
    ok = chappe_sip_engine_fake:inject_request(
        101, message_raw(<<"hi there">>)
    ),
    receive
        {handled, <<"MESSAGE">>, <<"hi there">>} -> ok
    after 2000 -> ct:fail(handler_not_called)
    end,
    {ok, #{status := 200, headers := H}} = chappe_sip_engine_fake:await_response(
        101
    ),
    {_, _} = binary:match(H, <<"X-Seen: 1">>).

no_route_405(_Config) ->
    %% register two methods, then send an unhandled one (MESSAGE)
    ok = chappe_sip:invite(fun(_R, _S) -> ok end),
    ok = chappe_sip:options(fun(_R, _S) -> ok end),
    ok = chappe_sip_engine_fake:inject_request(102, message_raw(<<"x">>)),
    {ok, #{status := 405, headers := H}} = chappe_sip_engine_fake:await_response(
        102
    ),
    %% RFC 3261 21.4.5: a 405 MUST carry Allow listing the supported methods
    ?assertMatch({_, _}, binary:match(H, <<"Allow:">>)),
    ?assertMatch({_, _}, binary:match(H, <<"INVITE">>)),
    ?assertMatch({_, _}, binary:match(H, <<"OPTIONS">>)).

%% RFC 3261 8.2.2: an unsupported Require option-tag is a 420 Bad Extension
%% with an Unsupported header; the handler must not run.
unsupported_require_420(_Config) ->
    Test = self(),
    ok = chappe_sip:message(fun(_R, _S) -> Test ! handler_ran end),
    Raw = <<
        "MESSAGE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:5998;branch=z9hG4bKrq\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:a@b>;tag=rq\r\nTo: <sip:app@127.0.0.1>\r\n"
        "Call-ID: rq@ct\r\nCSeq: 1 MESSAGE\r\n"
        "Require: foo, 100rel\r\nContent-Length: 0\r\n\r\n"
    >>,
    ok = chappe_sip_engine_fake:inject_request(110, Raw),
    {ok, #{status := 420, headers := H}} = chappe_sip_engine_fake:await_response(
        110
    ),
    ?assertMatch({_, _}, binary:match(H, <<"Unsupported:">>)),
    ?assertMatch({_, _}, binary:match(H, <<"foo">>)),
    %% 100rel is supported, so it is not listed as unsupported
    ?assertEqual(nomatch, binary:match(H, <<"100rel">>)),
    receive
        handler_ran -> ct:fail(handler_ran_on_bad_require)
    after 300 -> ok
    end.

middleware_stops_chain(_Config) ->
    Test = self(),
    ok = chappe_sip:use(fun(_Req, Res, _Next) ->
        %% do not call Next: reject everything
        ok = chappe_sip_res:send(Res, 403, #{reason => <<"Forbidden">>})
    end),
    ok = chappe_sip:message(fun(_Req, _Res) ->
        Test ! handler_should_not_run
    end),
    ok = chappe_sip_engine_fake:inject_request(103, message_raw(<<"x">>)),
    {ok, #{status := 403}} = chappe_sip_engine_fake:await_response(103),
    receive
        handler_should_not_run -> ct:fail(chain_did_not_stop)
    after 300 -> ok
    end.

%% A middleware hands a request with locals on by returning {next, Req1};
%% one calling the old 0-arity Next() passes the request it got, locals
%% included; the handler reads them, and the call_ref the worker made.
middleware_locals(_Config) ->
    Test = self(),
    ok = chappe_sip:use(fun(Req, _Res, _Next) ->
        {next, chappe_sip_req:set_local(account, <<"acme">>, Req)}
    end),
    ok = chappe_sip:use(fun(Req, _Res, Next) ->
        Test ! {second_sees, chappe_sip_req:local(account, Req)},
        Next()
    end),
    ok = chappe_sip:message(fun(Req, Res) ->
        Test !
            {handler, chappe_sip_req:local(account, Req),
                chappe_sip_req:local(missing, Req, none),
                chappe_sip_req:locals(Req), chappe_sip_req:call_ref(Req)},
        ok = chappe_sip_res:send(Res, 200, #{})
    end),
    ok = chappe_sip_engine_fake:inject_request(120, message_raw(<<"l">>)),
    {ok, #{status := 200}} = chappe_sip_engine_fake:await_response(120),
    receive
        {second_sees, <<"acme">>} -> ok
    after 2000 -> ct:fail(no_second)
    end,
    receive
        {handler, <<"acme">>, none, #{account := <<"acme">>}, Ref} ->
            {match, _} = re:run(Ref, "^[0-9a-f]{24}$")
    after 2000 -> ct:fail(no_handler)
    end.

%% {next, X} with X no request is the middleware's bug: 500, no handler.
middleware_bad_next(_Config) ->
    Test = self(),
    ok = chappe_sip:use(fun(_Req, _Res, _Next) -> {next, not_a_request} end),
    ok = chappe_sip:message(fun(_Req, _Res) -> Test ! handler_ran end),
    ok = chappe_sip_engine_fake:inject_request(121, message_raw(<<"b">>)),
    {ok, #{status := 500}} = chappe_sip_engine_fake:await_response(121),
    receive
        handler_ran -> ct:fail(handler_ran)
    after 300 -> ok
    end.

worker_cap_503(_Config) ->
    application:set_env(chappe_sip, max_request_workers, 1),
    Test = self(),
    ok = chappe_sip:message(fun(_Req, Res) ->
        Test ! {worker_up, self()},
        receive
            release -> ok
        end,
        ok = chappe_sip_res:send(Res, 200, #{})
    end),
    ok = chappe_sip_engine_fake:inject_request(104, message_raw(<<"a">>)),
    Worker =
        receive
            {worker_up, W} -> W
        after 2000 -> ct:fail(no_worker)
        end,
    ok = chappe_sip_engine_fake:inject_request(105, message_raw(<<"b">>)),
    {ok, #{status := 503}} = chappe_sip_engine_fake:await_response(105),
    Worker ! release,
    {ok, #{status := 200}} = chappe_sip_engine_fake:await_response(104).

deadline_500(_Config) ->
    application:set_env(chappe_sip, handler_deadline_ms, 200),
    ok = chappe_sip:message(fun(_Req, _Res) ->
        timer:sleep(5000)
    end),
    ok = chappe_sip_engine_fake:inject_request(106, message_raw(<<"x">>)),
    {ok, #{status := 500}} = chappe_sip_engine_fake:await_response(106, 3000).

crash_500(_Config) ->
    ok = chappe_sip:message(fun(_Req, _Res) ->
        error(deliberate_crash)
    end),
    ok = chappe_sip_engine_fake:inject_request(107, message_raw(<<"x">>)),
    {ok, #{status := 500}} = chappe_sip_engine_fake:await_response(107).

%% A handler that ends its process (normal, {shutdown, _}) once it has
%% sent a final response is not a crash: nothing is logged and no second
%% response goes out.
exit_after_final(_Config) ->
    ok = logger:add_handler(
        exit_after_final,
        ?MODULE,
        #{level => error, config => #{pid => self()}}
    ),
    try
        lists:foreach(
            fun({TxnH, Reason}) ->
                ok = chappe_sip:message(fun(_Req, Res) ->
                    ok = chappe_sip_res:send(Res, 200, #{}),
                    exit(Reason)
                end),
                ok = chappe_sip_engine_fake:inject_request(
                    TxnH, message_raw(<<"x">>)
                ),
                {ok, #{status := 200}} =
                    chappe_sip_engine_fake:await_response(TxnH),
                timeout = chappe_sip_engine_fake:await_response(TxnH, 300)
            end,
            [{120, normal}, {121, {shutdown, done}}]
        ),
        receive
            {logged, Msg} -> ct:fail({logged, Msg})
        after 200 -> ok
        end
    after
        logger:remove_handler(exit_after_final)
    end.

%% logger handler of exit_after_final
log(#{msg := Msg}, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Msg},
    ok.

duplicate_final(_Config) ->
    Test = self(),
    ok = chappe_sip:message(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 200, #{}),
        Test ! {second_send, chappe_sip_res:send(Res, 486, #{})}
    end),
    ok = chappe_sip_engine_fake:inject_request(108, message_raw(<<"x">>)),
    {ok, #{status := 200}} = chappe_sip_engine_fake:await_response(108),
    receive
        {second_send, {error, already_final}} -> ok;
        {second_send, Other} -> ct:fail({unexpected, Other})
    after 2000 -> ct:fail(no_second_send_result)
    end.

fake_health(_Config) ->
    ok = chappe_sip_engine:check_health(2000).

%% ---- live group ----

live_options_headers(_Config) ->
    Port = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => contact(Port)}),
    ok = chappe_sip:options(fun(_Req, Res) ->
        ok = chappe_sip_res:send(
            Res,
            200,
            #{
                reason => <<"OK">>,
                headers => [{<<"Allow">>, <<"INVITE, ACK, BYE, OPTIONS">>}]
            }
        )
    end),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, LP} = inet:port(Sock),
    ok = gen_udp:send(
        Sock, {127, 0, 0, 1}, Port, wire_req(<<"OPTIONS">>, LP, <<>>)
    ),
    Resp = recv_udp(Sock),
    {_, _} = binary:match(Resp, <<"SIP/2.0 200">>),
    {_, _} = binary:match(Resp, <<"Allow: INVITE, ACK, BYE, OPTIONS">>),
    gen_udp:close(Sock).

live_message_dispatch(_Config) ->
    Port = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => contact(Port)}),
    Test = self(),
    ok = chappe_sip:message(fun(Req, Res) ->
        Test ! {msg_body, chappe_sip_req:body(Req)},
        ok = chappe_sip_res:send(Res, 202, #{reason => <<"Accepted">>})
    end),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, LP} = inet:port(Sock),
    ok = gen_udp:send(
        Sock,
        {127, 0, 0, 1},
        Port,
        wire_req(<<"MESSAGE">>, LP, <<"ping!">>)
    ),
    receive
        {msg_body, <<"ping!">>} -> ok
    after 3000 -> ct:fail(no_message_body)
    end,
    Resp = recv_udp(Sock),
    {_, _} = binary:match(Resp, <<"SIP/2.0 202">>),
    gen_udp:close(Sock).

%% ---- helpers ----

contact(Port) ->
    <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.

recv_udp(Sock) ->
    receive
        {udp, Sock, _, _, Bin} -> Bin
    after 3000 -> ct:fail(no_udp_response)
    end.

message_raw(Body) ->
    L = integer_to_binary(byte_size(Body)),
    <<
        "MESSAGE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:5998;branch=z9hG4bKm2fake\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:t@127.0.0.1>;tag=m2\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Call-ID: m2fake@127.0.0.1\r\n"
        "CSeq: 1 MESSAGE\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: ",
        L/binary,
        "\r\n\r\n",
        Body/binary
    >>.

wire_req(Method, LocalPort, Body) ->
    P = integer_to_binary(LocalPort),
    L = integer_to_binary(byte_size(Body)),
    CT =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: text/plain\r\n">>
        end,
    <<Method/binary,
        " sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKm2",
        P/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:ct@127.0.0.1>;tag=m2live\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Call-ID: m2live-", P/binary,
        "@127.0.0.1\r\n"
        "CSeq: 1 ", Method/binary, "\r\n", CT/binary, "Content-Length: ",
        L/binary, "\r\n\r\n", Body/binary>>.
