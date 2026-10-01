%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% DTMF listener behavior: per-call dispatch, digit mapping,
%% resilience to garbage, and forwarding through sessions.
-module(chappe_rtpengine_dtmf_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    digit_events_delivered/1,
    dispatch_is_per_call/1,
    unsubscribe_stops_delivery/1,
    malformed_datagram_ignored/1,
    session_forwards_dtmf_to_owner/1,
    bind_ip_and_allowed_sources/1
]).

all() ->
    [
        digit_events_delivered,
        dispatch_is_per_call,
        unsubscribe_stops_delivery,
        malformed_datagram_ignored,
        session_forwards_dtmf_to_owner,
        %% last: it moves the listener to other ports
        bind_ip_and_allowed_sources
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_rtpengine),
    {ok, Port} = chappe_rtpengine_dtmf:open(0),
    [{dtmf_port, Port} | Config].

end_per_suite(_Config) ->
    ok = chappe_rtpengine_dtmf:close(),
    ok = application:stop(chappe_rtpengine).

%% helpers

send_event(Config, CallId, Code) ->
    send_raw(
        Config,
        json:encode(#{
            callid => CallId,
            source_tag => <<"ft">>,
            type => <<"DTMF">>,
            event => Code,
            duration => 250,
            volume => 10,
            timestamp => 1700000000
        })
    ).

send_raw(Config, Payload) ->
    Port = ?config(dtmf_port, Config),
    {ok, Socket} = gen_udp:open(0, [binary]),
    ok = gen_udp:send(Socket, {127, 0, 0, 1}, Port, Payload),
    gen_udp:close(Socket).

expect_digit(CallId, Digit) ->
    receive
        {chappe_rtpengine_dtmf, CallId, Event} ->
            ?assertEqual(Digit, maps:get(digit, Event)),
            Event
    after 2000 -> error({no_dtmf_event, CallId, Digit})
    end.

expect_silence() ->
    receive
        {chappe_rtpengine_dtmf, _, _} = Msg -> error({unexpected, Msg})
    after 200 -> ok
    end.

%% cases

digit_events_delivered(Config) ->
    CallId = <<"dtmf-digits">>,
    ok = chappe_rtpengine_dtmf:subscribe(CallId),
    send_event(Config, CallId, 5),
    Event = expect_digit(CallId, $5),
    ?assertEqual(5, maps:get(code, Event)),
    ?assertEqual(250, maps:get(duration, Event)),
    ?assertEqual(<<"ft">>, maps:get(source_tag, Event)),
    send_event(Config, CallId, 10),
    _ = expect_digit(CallId, $*),
    send_event(Config, CallId, 11),
    _ = expect_digit(CallId, $#),
    ok = chappe_rtpengine_dtmf:unsubscribe(CallId),
    ok.

dispatch_is_per_call(Config) ->
    ok = chappe_rtpengine_dtmf:subscribe(<<"dtmf-mine">>),
    send_event(Config, <<"dtmf-other">>, 1),
    expect_silence(),
    send_event(Config, <<"dtmf-mine">>, 2),
    _ = expect_digit(<<"dtmf-mine">>, $2),
    ok = chappe_rtpengine_dtmf:unsubscribe(<<"dtmf-mine">>),
    ok.

unsubscribe_stops_delivery(Config) ->
    CallId = <<"dtmf-unsub">>,
    ok = chappe_rtpengine_dtmf:subscribe(CallId),
    send_event(Config, CallId, 3),
    _ = expect_digit(CallId, $3),
    ok = chappe_rtpengine_dtmf:unsubscribe(CallId),
    send_event(Config, CallId, 4),
    expect_silence(),
    ok.

malformed_datagram_ignored(Config) ->
    CallId = <<"dtmf-garbage">>,
    ok = chappe_rtpengine_dtmf:subscribe(CallId),
    send_raw(Config, <<"not json at all">>),
    send_raw(Config, <<"[1,2,3]">>),
    expect_silence(),
    %% the listener survives and keeps dispatching
    send_event(Config, CallId, 7),
    _ = expect_digit(CallId, $7),
    ok = chappe_rtpengine_dtmf:unsubscribe(CallId),
    ok.

%% The listener binds the address it is given, and datagrams from a
%% source outside allowed_sources are dropped.
bind_ip_and_allowed_sources(Config) ->
    {ok, Port} = chappe_rtpengine_dtmf:open(0, #{
        ip => {127, 0, 0, 1}, allowed_sources => [{127, 0, 0, 2}]
    }),
    Local = [{dtmf_port, Port} | Config],
    CallId = <<"dtmf-acl">>,
    ok = chappe_rtpengine_dtmf:subscribe(CallId),
    %% sent from 127.0.0.1: not allowed
    send_event(Local, CallId, 1),
    expect_silence(),
    {ok, Port2} = chappe_rtpengine_dtmf:open(0, #{
        ip => {127, 0, 0, 1}, allowed_sources => [{127, 0, 0, 1}]
    }),
    send_event([{dtmf_port, Port2} | Config], CallId, 2),
    _ = expect_digit(CallId, $2),
    ok = chappe_rtpengine_dtmf:unsubscribe(CallId),
    ok.

session_forwards_dtmf_to_owner(Config) ->
    {ok, Server, Port} = chappe_rtpengine_fake_server:start(),
    ok = chappe_rtpengine:add_node(dtmf_node, #{
        host => {127, 0, 0, 1}, port => Port
    }),
    CallId = <<"dtmf-session">>,
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, dtmf => true
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => <<"ft-d">>,
        sdp => <<"v=0\r\nm=audio 30000 RTP/AVP 0\r\n">>
    }),
    send_event(Config, CallId, 1),
    receive
        {chappe_rtpengine_session, Sess, {dtmf, Event}} ->
            ?assertEqual($1, maps:get(digit, Event))
    after 2000 -> error(no_session_dtmf)
    end,
    ok = chappe_rtpengine_session:stop(Sess),
    _ = chappe_rtpengine:remove_node(dtmf_node),
    chappe_rtpengine_fake_server:stop(Server),
    ok.
