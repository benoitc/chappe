%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_esl_conn_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    connect_auth/1,
    api/1,
    bgapi/1,
    bgapi_await/1,
    subscribe_event/1,
    execute/1,
    change_controlling_process/1,
    disconnect_notice/1,
    stats/1,
    auth_failure/1,
    rude_rejection/1,
    filter/1,
    sendevent/1,
    json_event/1,
    xml_event/1,
    log_data/1,
    api_timeout/1,
    api_err/1,
    unknown_call/1,
    bad_content_length/1,
    frame_too_large/1,
    controlling_process_link/1
]).

all() ->
    [
        connect_auth,
        api,
        bgapi,
        bgapi_await,
        subscribe_event,
        execute,
        change_controlling_process,
        disconnect_notice,
        stats,
        auth_failure,
        rude_rejection,
        filter,
        sendevent,
        json_event,
        xml_event,
        log_data,
        api_timeout,
        api_err,
        unknown_call,
        bad_content_length,
        frame_too_large,
        controlling_process_link
    ].

fake_opts() ->
    #{
        api => #{
            <<"uptime">> => <<"7200000">>,
            <<"status">> => <<"UP 0 years, 0 days">>,
            <<"slow">> => {delay, 500, <<"late">>},
            <<"bogus">> => <<"-ERR bogus Command not found!\n">>
        }
    }.

%% Cases that exercise the handshake start their own fake.
init_per_testcase(Case, Config) when
    Case =:= auth_failure; Case =:= rude_rejection; Case =:= frame_too_large
->
    Config;
init_per_testcase(_Case, Config) ->
    {ok, Server, Port} = chappe_esl_fake_server:start(fake_opts()),
    {ok, Conn} = chappe_esl:connect(#{
        host => {127, 0, 0, 1},
        port => Port,
        password => <<"ClueCon">>
    }),
    [{server, Server}, {conn, Conn} | Config].

end_per_testcase(_Case, Config) ->
    flush_fake(),
    safe(fun() -> chappe_esl:close(?config(conn, Config)) end),
    safe(fun() -> chappe_esl_fake_server:stop(?config(server, Config)) end),
    ok.

safe(Fun) ->
    try
        Fun()
    catch
        _:_ -> ok
    end.

%% On auth/request the client sends `auth <password>' and is ready on +OK.
%% req: ESL-01 ESL-13
connect_auth(Config) ->
    Conn = ?config(conn, Config),
    ?assert(is_process_alive(Conn)),
    ?assertEqual(<<"auth ClueCon">>, fake_block(auth)).

%% req: ESL-02 ESL-05 ESL-06 ESL-15
api(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual({ok, <<"7200000">>}, chappe_esl:api(Conn, "uptime")),
    ?assertEqual({ok, <<"UP 0 years, 0 days">>}, chappe_esl:api(Conn, "status")).

%% req: ESL-17
bgapi(Config) ->
    Conn = ?config(conn, Config),
    ?assertMatch({ok, _JobId}, chappe_esl:bgapi(Conn, "reloadxml")).

%% req: ESL-17
bgapi_await(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual(
        {ok, <<"+OK">>}, chappe_esl:bgapi_await(Conn, "reloadxml", 5000)
    ).

%% req: ESL-07 ESL-20
subscribe_event(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    ?assertEqual(ok, chappe_esl:subscribe(Conn, [<<"CHANNEL_ANSWER">>])),
    ?assertEqual(<<"event plain CHANNEL_ANSWER">>, fake_block()),
    Frame = chappe_esl_fake_server:plain_event(<<"CHANNEL_ANSWER">>, [
        {<<"Unique-ID">>, <<"abc-123">>}
    ]),
    ok = chappe_esl_fake_server:inject(Server, Frame),
    receive
        {chappe_esl_event, Conn, Event} ->
            ?assertEqual(<<"CHANNEL_ANSWER">>, chappe_esl_event:name(Event)),
            ?assertEqual(
                <<"abc-123">>, chappe_esl_event:header(<<"Unique-ID">>, Event)
            )
    after 5000 ->
        ct:fail(no_event)
    end.

%% req: ESL-21
execute(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual(ok, chappe_esl:execute(Conn, "uuid-1", "playback", "tone.wav")).

change_controlling_process(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    Test = self(),
    Receiver = spawn(fun() ->
        receive
            {chappe_esl_event, Conn, Event} ->
                Test ! {got, chappe_esl_event:name(Event)}
        after 5000 -> Test ! timeout
        end
    end),
    ok = chappe_esl:set_controlling_process(Conn, Receiver),
    Frame = chappe_esl_fake_server:plain_event(<<"HEARTBEAT">>, []),
    ok = chappe_esl_fake_server:inject(Server, Frame),
    receive
        {got, Name} -> ?assertEqual(<<"HEARTBEAT">>, Name);
        timeout -> ct:fail(receiver_timeout)
    after 6000 ->
        ct:fail(no_forward)
    end.

%% A notice without Content-Disposition (or with `disconnect') keeps the
%% {chappe_esl_disconnect, Conn} shape.
%% req: ESL-11
disconnect_notice(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    ok = chappe_esl_fake_server:inject(Server, disconnect_frame()),
    receive
        {chappe_esl_disconnect, Conn} -> ok
    after 5000 ->
        ct:fail(no_disconnect)
    end.

stats(Config) ->
    Conn = ?config(conn, Config),
    {ok, _} = chappe_esl:api(Conn, "uptime"),
    S = chappe_esl:stats(Conn),
    ?assert(maps:get(commands, S) >= 1),
    ?assert(maps:get(replies, S) >= 1).

%% A -ERR answer to the password fails connect with the reply text.
%% req: ESL-14
auth_failure(_Config) ->
    {ok, Server, Port} = chappe_esl_fake_server:start(#{auth => reject}),
    try
        ?assertEqual(
            {error, {auth_failed, <<"-ERR invalid">>}},
            chappe_esl:connect(#{host => {127, 0, 0, 1}, port => Port})
        )
    after
        chappe_esl_fake_server:stop(Server)
    end.

%% A text/rude-rejection in place of auth/request (ACL denied) fails connect
%% with the rejection text rather than a bare `closed'.
%% req: ESL-12
rude_rejection(_Config) ->
    Text = <<"Access Denied, go away.\n">>,
    {ok, _Server, Port} = chappe_esl_fake_server:start(#{
        greeting => {rude, Text}
    }),
    ?assertEqual(
        {error, {rejected, <<"Access Denied, go away.">>}},
        chappe_esl:connect(#{host => {127, 0, 0, 1}, port => Port})
    ).

%% req: ESL-21
filter(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual(ok, chappe_esl:filter(Conn, "Event-Name CHANNEL_ANSWER")),
    ?assertEqual(<<"filter Event-Name CHANNEL_ANSWER">>, fake_block()).

%% req: ESL-21
sendevent(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual(
        ok,
        chappe_esl:sendevent(Conn, "NOTIFY", [
            {<<"profile">>, <<"internal">>},
            {<<"event-string">>, <<"check-sync">>}
        ])
    ),
    ?assertEqual(
        <<"sendevent NOTIFY\nprofile: internal\nevent-string: check-sync">>,
        fake_block()
    ).

%% req: ESL-08 ESL-20
json_event(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    ?assertEqual(ok, chappe_esl:events(Conn, json, ['CHANNEL_ANSWER'])),
    ?assertEqual(<<"event json CHANNEL_ANSWER">>, fake_block()),
    Json =
        <<"{\"Event-Name\":\"CHANNEL_ANSWER\",\"Unique-ID\":\"j-1\",",
            "\"_body\":\"hello\"}">>,
    ok = chappe_esl_fake_server:inject(
        Server, raw_frame(<<"text/event-json">>, Json)
    ),
    receive
        {chappe_esl_event, Conn, Event} ->
            ?assertEqual(<<"CHANNEL_ANSWER">>, chappe_esl_event:name(Event)),
            ?assertEqual(
                <<"j-1">>, chappe_esl_event:header(<<"Unique-ID">>, Event)
            ),
            ?assertEqual(<<"hello">>, chappe_esl_event:body(Event))
    after 5000 ->
        ct:fail(no_event)
    end.

%% req: ESL-09 ESL-20
xml_event(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    ?assertEqual(ok, chappe_esl:events(Conn, xml, ['HEARTBEAT'])),
    ?assertEqual(<<"event xml HEARTBEAT">>, fake_block()),
    Xml =
        <<"<event><headers><Event-Name>HEARTBEAT</Event-Name>",
            "</headers></event>">>,
    ok = chappe_esl_fake_server:inject(
        Server, raw_frame(<<"text/event-xml">>, Xml)
    ),
    receive
        {chappe_esl_event, Conn, Event} ->
            ?assertEqual(Xml, chappe_esl_event:body(Event))
    after 5000 ->
        ct:fail(no_event)
    end.

%% req: ESL-10
log_data(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    Line = <<"2026-10-01 [NOTICE] switch.c:1 hello\n">>,
    Len = integer_to_binary(byte_size(Line)),
    Frame =
        <<"Content-Type: log/data\nContent-Length: ", Len/binary,
            "\nLog-Level: 5\n\n", Line/binary>>,
    ok = chappe_esl_fake_server:inject(Server, Frame),
    receive
        {chappe_esl_log, Conn, Headers, Body} ->
            ?assertEqual(<<"5">>, maps:get(<<"Log-Level">>, Headers)),
            ?assertEqual(Line, Body)
    after 5000 ->
        ct:fail(no_log)
    end.

%% A timed out api returns {error, timeout} to the caller (no exit). The late
%% reply is still matched to its slot, so the next command gets its own reply.
%% req: ESL-05 ESL-16
api_timeout(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual({error, timeout}, chappe_esl:api(Conn, "slow", 100)),
    ?assertEqual({ok, <<"7200000">>}, chappe_esl:api(Conn, "uptime")),
    ?assert(is_process_alive(Conn)).

%% req: ESL-15
api_err(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual(
        {error, <<"-ERR bogus Command not found!">>},
        chappe_esl:api(Conn, "bogus")
    ).

unknown_call(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual({error, unknown_call}, gen_statem:call(Conn, bogus, 1000)).

%% A Content-Length that is not a non-negative integer closes the connection:
%% the owner is told and the connection process stops.
%% req: ESL-03
bad_content_length(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    Mon = monitor(process, Conn),
    ok = chappe_esl_fake_server:inject(
        Server, <<"Content-Type: api/response\nContent-Length: x\n\n">>
    ),
    receive
        {chappe_esl_closed, Conn} -> ok
    after 5000 ->
        ct:fail(no_closed)
    end,
    receive
        {'DOWN', Mon, process, Conn, _} -> ok
    after 5000 ->
        ct:fail(conn_alive)
    end.

%% A frame larger than max_frame_bytes closes the connection instead of
%% buffering toward it.
%% req: ESL-04
frame_too_large(_Config) ->
    ok = application:set_env(chappe_esl, max_frame_bytes, 256),
    {ok, Server, Port} = chappe_esl_fake_server:start(),
    try
        {ok, Conn} = chappe_esl:connect(#{host => {127, 0, 0, 1}, port => Port}),
        Mon = monitor(process, Conn),
        ok = chappe_esl_fake_server:inject(
            Server,
            <<"Content-Type: api/response\nContent-Length: 100000\n\n">>
        ),
        receive
            {chappe_esl_closed, Conn} -> ok
        after 5000 ->
            ct:fail(no_closed)
        end,
        receive
            {'DOWN', Mon, process, Conn, _} -> ok
        after 5000 ->
            ct:fail(conn_alive)
        end
    after
        application:unset_env(chappe_esl, max_frame_bytes),
        chappe_esl_fake_server:stop(Server)
    end.

%% set_controlling_process/2 moves the link: the old owner is unlinked, the
%% new one linked, so the new owner's exit takes the connection down.
controlling_process_link(Config) ->
    Conn = ?config(conn, Config),
    New = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    ok = chappe_esl:set_controlling_process(Conn, New),
    {links, Links} = process_info(Conn, links),
    ?assert(lists:member(New, Links)),
    ?assertNot(lists:member(self(), Links)),
    Mon = monitor(process, Conn),
    exit(New, kill),
    receive
        {'DOWN', Mon, process, Conn, _} -> ok
    after 5000 ->
        ct:fail(conn_alive)
    end.

%% helpers

disconnect_frame() ->
    raw_frame(<<"text/disconnect-notice">>, <<"Disconnected, goodbye.\n">>).

raw_frame(Type, Body) ->
    Len = integer_to_binary(byte_size(Body)),
    <<"Content-Type: ", Type/binary, "\nContent-Length: ", Len/binary, "\n\n",
        Body/binary>>.

%% Next command block the fake received, skipping the auth line.
fake_block() ->
    receive
        {fake_server, _, <<"auth ", _/binary>>} -> fake_block();
        {fake_server, _, Block} -> Block
    after 5000 ->
        ct:fail(no_fake_block)
    end.

fake_block(auth) ->
    receive
        {fake_server, _, <<"auth ", _/binary>> = Block} -> Block
    after 5000 ->
        ct:fail(no_auth_block)
    end.

flush_fake() ->
    receive
        {fake_server, _, _} -> flush_fake()
    after 0 ->
        ok
    end.
