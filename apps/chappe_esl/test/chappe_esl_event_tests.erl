%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_esl_event_tests).

-include_lib("eunit/include/eunit.hrl").

frame(Type, Headers, Body) ->
    #{
        headers => maps:put(<<"Content-Type">>, Type, Headers),
        body => Body
    }.

auth_request_test() ->
    F = frame(<<"auth/request">>, #{}, <<>>),
    ?assertMatch({auth_request, _}, chappe_esl_event:decode(F)).

command_reply_test() ->
    F = frame(
        <<"command/reply">>,
        #{<<"Reply-Text">> => <<"+OK accepted">>},
        <<>>
    ),
    ?assertEqual(
        {reply, <<"+OK accepted">>, #{
            <<"Content-Type">> => <<"command/reply">>,
            <<"Reply-Text">> => <<"+OK accepted">>
        }},
        chappe_esl_event:decode(F)
    ).

api_response_test() ->
    F = frame(
        <<"api/response">>, #{<<"Content-Length">> => <<"3">>}, <<"+OK">>
    ),
    ?assertEqual({api, <<"+OK">>}, chappe_esl_event:decode(F)).

event_plain_urldecode_test() ->
    Body = <<
        "Event-Name: CHANNEL_ANSWER\n"
        "Unique-ID: 111\n"
        "variable_sip_from: sip%3Aalice%40example.com\n"
        "variable_note: bar%20baz\n\n"
    >>,
    F = frame(<<"text/event-plain">>, #{}, Body),
    {event, Event} = chappe_esl_event:decode(F),
    ?assertEqual(<<"CHANNEL_ANSWER">>, chappe_esl_event:name(Event)),
    ?assertEqual(<<"111">>, chappe_esl_event:header(<<"Unique-ID">>, Event)),
    ?assertEqual(
        <<"sip:alice@example.com">>,
        chappe_esl_event:header(<<"variable_sip_from">>, Event)
    ),
    ?assertEqual(
        <<"bar baz">>,
        chappe_esl_event:header(<<"variable_note">>, Event)
    ),
    ?assertEqual(<<>>, chappe_esl_event:body(Event)).

event_plain_with_body_test() ->
    Inner = <<"Event-Name: DTMF\nContent-Length: 5\n\nhello">>,
    F = frame(<<"text/event-plain">>, #{}, Inner),
    {event, Event} = chappe_esl_event:decode(F),
    ?assertEqual(<<"DTMF">>, chappe_esl_event:name(Event)),
    ?assertEqual(<<"hello">>, chappe_esl_event:body(Event)).

event_json_test() ->
    Body = <<"{\"Event-Name\":\"HEARTBEAT\",\"Uptime-msec\":\"123\"}">>,
    F = frame(<<"text/event-json">>, #{}, Body),
    {event, Event} = chappe_esl_event:decode(F),
    ?assertEqual(<<"HEARTBEAT">>, chappe_esl_event:name(Event)),
    ?assertEqual(<<"123">>, chappe_esl_event:header(<<"Uptime-msec">>, Event)),
    ?assertEqual(<<>>, chappe_esl_event:body(Event)).

event_json_with_body_test() ->
    Body = <<"{\"Event-Name\":\"CHANNEL_DATA\",\"_body\":\"payload\"}">>,
    F = frame(<<"text/event-json">>, #{}, Body),
    {event, Event} = chappe_esl_event:decode(F),
    ?assertEqual(<<"payload">>, chappe_esl_event:body(Event)),
    ?assertEqual(undefined, chappe_esl_event:header(<<"_body">>, Event)).

event_json_bad_test() ->
    Body = <<"{not valid json">>,
    F = frame(<<"text/event-json">>, #{}, Body),
    {event, Event} = chappe_esl_event:decode(F),
    ?assertEqual(Body, chappe_esl_event:body(Event)),
    ?assertEqual(#{}, chappe_esl_event:headers(Event)).

event_xml_raw_test() ->
    Body = <<"<event><headers></headers></event>">>,
    F = frame(<<"text/event-xml">>, #{}, Body),
    {event, Event} = chappe_esl_event:decode(F),
    ?assertEqual(Body, chappe_esl_event:body(Event)).

disconnect_notice_test() ->
    F = frame(<<"text/disconnect-notice">>, #{}, <<"Disconnected\n">>),
    ?assertMatch({disconnect, _, <<"Disconnected\n">>}, chappe_esl_event:decode(F)).

log_data_test() ->
    F = frame(<<"log/data">>, #{<<"Log-Level">> => <<"7">>}, <<"line\n">>),
    ?assertMatch({log, _, <<"line\n">>}, chappe_esl_event:decode(F)).

unknown_type_test() ->
    F = frame(<<"text/rude-rejection">>, #{}, <<>>),
    ?assertMatch({unknown, _, <<>>}, chappe_esl_event:decode(F)).
