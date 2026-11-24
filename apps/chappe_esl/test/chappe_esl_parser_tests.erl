%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_esl_parser_tests).

-include_lib("eunit/include/eunit.hrl").

%% Captured FreeSWITCH frames (real wire bytes, LF line endings).

auth_request() ->
    <<"Content-Type: auth/request\n\n">>.

reply_ok() ->
    <<"Content-Type: command/reply\nReply-Text: +OK accepted\n\n">>.

api_response() ->
    <<"Content-Type: api/response\nContent-Length: 5\n\nhello">>.

event_plain_body() ->
    <<
        "Event-Name: CHANNEL_ANSWER\n"
        "Unique-ID: 111\n"
        "variable_foo: bar%20baz\n\n"
    >>.

event_plain() ->
    Body = event_plain_body(),
    Len = integer_to_binary(byte_size(Body)),
    <<"Content-Length: ", Len/binary, "\n",
        "Content-Type: text/event-plain\n\n", Body/binary>>.

event_json_body() ->
    <<"{\"Event-Name\":\"HEARTBEAT\",\"Core-UUID\":\"abc\"}">>.

event_json() ->
    Body = event_json_body(),
    Len = integer_to_binary(byte_size(Body)),
    <<"Content-Type: text/event-json\n", "Content-Length: ", Len/binary, "\n\n",
        Body/binary>>.

%% Expected frames.

auth_request_frame() ->
    #{headers => #{<<"Content-Type">> => <<"auth/request">>}, body => <<>>}.

reply_ok_frame() ->
    #{
        headers => #{
            <<"Content-Type">> => <<"command/reply">>,
            <<"Reply-Text">> => <<"+OK accepted">>
        },
        body => <<>>
    }.

api_response_frame() ->
    #{
        headers => #{
            <<"Content-Type">> => <<"api/response">>,
            <<"Content-Length">> => <<"5">>
        },
        body => <<"hello">>
    }.

event_plain_frame() ->
    Body = event_plain_body(),
    #{
        headers => #{
            <<"Content-Length">> => integer_to_binary(byte_size(Body)),
            <<"Content-Type">> => <<"text/event-plain">>
        },
        body => Body
    }.

event_json_frame() ->
    Body = event_json_body(),
    #{
        headers => #{
            <<"Content-Type">> => <<"text/event-json">>,
            <<"Content-Length">> => integer_to_binary(byte_size(Body))
        },
        body => Body
    }.

%% Helpers.

feed_all(Chunks) ->
    P0 = chappe_esl_parser:new(),
    lists:foldl(
        fun(Chunk, {Acc, P}) ->
            {Fs, P1} = chappe_esl_parser:feed(Chunk, P),
            {Acc ++ Fs, P1}
        end,
        {[], P0},
        Chunks
    ).

one_byte_chunks(Bin) ->
    [<<B>> || <<B>> <= Bin].

%% Feed the whole binary in one shot.

%% req: ESL-01
single_no_body_test() ->
    {Frames, P} = feed_all([auth_request()]),
    ?assertEqual([auth_request_frame()], Frames),
    ?assertEqual(<<>>, chappe_esl_parser:buffer(P)).

reply_text_test() ->
    {Frames, _} = feed_all([reply_ok()]),
    ?assertEqual([reply_ok_frame()], Frames).

single_with_body_test() ->
    {Frames, P} = feed_all([api_response()]),
    ?assertEqual([api_response_frame()], Frames),
    ?assertEqual(<<>>, chappe_esl_parser:buffer(P)).

event_plain_test() ->
    {Frames, _} = feed_all([event_plain()]),
    ?assertEqual([event_plain_frame()], Frames).

event_json_test() ->
    {Frames, _} = feed_all([event_json()]),
    ?assertEqual([event_json_frame()], Frames).

%% Two frames back to back in a single feed, with and without bodies.

two_frames_no_body_test() ->
    Bin = <<(auth_request())/binary, (reply_ok())/binary>>,
    {Frames, P} = feed_all([Bin]),
    ?assertEqual([auth_request_frame(), reply_ok_frame()], Frames),
    ?assertEqual(<<>>, chappe_esl_parser:buffer(P)).

two_frames_with_body_test() ->
    Bin = <<(api_response())/binary, (event_plain())/binary>>,
    {Frames, _} = feed_all([Bin]),
    ?assertEqual([api_response_frame(), event_plain_frame()], Frames).

%% Partial header block then the rest.

partial_header_test() ->
    Bin = reply_ok(),
    Head = binary:part(Bin, 0, 10),
    Tail = binary:part(Bin, 10, byte_size(Bin) - 10),
    {Frames0, P0} = chappe_esl_parser:feed(Head, chappe_esl_parser:new()),
    ?assertEqual([], Frames0),
    {Frames1, _} = chappe_esl_parser:feed(Tail, P0),
    ?assertEqual([reply_ok_frame()], Frames1).

%% Partial body then the rest.

partial_body_test() ->
    Bin = api_response(),
    Cut = byte_size(Bin) - 2,
    Head = binary:part(Bin, 0, Cut),
    Tail = binary:part(Bin, Cut, 2),
    {Frames0, P0} = chappe_esl_parser:feed(Head, chappe_esl_parser:new()),
    ?assertEqual([], Frames0),
    {Frames1, _} = chappe_esl_parser:feed(Tail, P0),
    ?assertEqual([api_response_frame()], Frames1).

%% Feed one byte at a time: the stream must decode identically.

one_byte_at_a_time_test_() ->
    Cases = [
        {auth_request(), [auth_request_frame()]},
        {api_response(), [api_response_frame()]},
        {event_plain(), [event_plain_frame()]},
        {event_json(), [event_json_frame()]}
    ],
    [
        fun() ->
            {Frames, P} = feed_all(one_byte_chunks(Bin)),
            ?assertEqual(Expected, Frames),
            ?assertEqual(<<>>, chappe_esl_parser:buffer(P))
        end
     || {Bin, Expected} <- Cases
    ].

%% Split a back-to-back stream at every byte boundary: always the same frames.

%% req: ESL-02
every_boundary_test_() ->
    Stream = <<
        (auth_request())/binary,
        (api_response())/binary,
        (event_plain())/binary,
        (event_json())/binary
    >>,
    Expected = [
        auth_request_frame(),
        api_response_frame(),
        event_plain_frame(),
        event_json_frame()
    ],
    Size = byte_size(Stream),
    [
        fun() ->
            Head = binary:part(Stream, 0, K),
            Tail = binary:part(Stream, K, Size - K),
            {Frames, P} = feed_all([Head, Tail]),
            ?assertEqual(Expected, Frames),
            ?assertEqual(<<>>, chappe_esl_parser:buffer(P))
        end
     || K <- lists:seq(0, Size)
    ].

%% A malformed Content-Length is a protocol error: the frames before it are
%% kept, the parser reports the error and drops further input.
%% req: ESL-03
bad_content_length_test_() ->
    [
        fun() ->
            Bin = <<
                (reply_ok())/binary,
                "Content-Type: api/response\n",
                "Content-Length: ",
                CL/binary,
                "\n\nbody"
            >>,
            {Frames, P} = feed_all([Bin]),
            ?assertEqual([reply_ok_frame()], Frames),
            ?assertEqual(
                {bad_content_length, CL}, chappe_esl_parser:error(P)
            ),
            ?assertEqual(<<>>, chappe_esl_parser:buffer(P)),
            ?assertEqual({[], P}, chappe_esl_parser:feed(reply_ok(), P))
        end
     || CL <- [<<"x">>, <<"-5">>, <<>>, <<"12abc">>]
    ].

no_error_on_good_stream_test() ->
    {_, P} = feed_all([api_response()]),
    ?assertEqual(undefined, chappe_esl_parser:error(P)).

overflow_reports_error_test() ->
    {_, P} = chappe_esl_parser:feed(
        binary:copy(<<"a">>, 65), chappe_esl_parser:new(64)
    ),
    ?assertEqual(frame_too_large, chappe_esl_parser:error(P)).

%% An empty parser holds nothing.

empty_test() ->
    ?assertEqual(<<>>, chappe_esl_parser:buffer(chappe_esl_parser:new())).

%% A partial frame exceeding the cap flips the parser to overflowed and drops
%% the buffer, so a peer that never completes a frame cannot grow memory.

%% req: ESL-04
overflow_unterminated_header_test() ->
    P0 = chappe_esl_parser:new(64),
    {Frames, P1} = chappe_esl_parser:feed(binary:copy(<<"a">>, 65), P0),
    ?assertEqual([], Frames),
    ?assert(chappe_esl_parser:overflowed(P1)),
    ?assertEqual(<<>>, chappe_esl_parser:buffer(P1)).

overflow_huge_content_length_test() ->
    P0 = chappe_esl_parser:new(64),
    Bin = <<"Content-Length: 1000000000\n\nstarting-body">>,
    {Frames, P1} = chappe_esl_parser:feed(Bin, P0),
    ?assertEqual([], Frames),
    ?assert(chappe_esl_parser:overflowed(P1)).

%% Once overflowed, further input is dropped (no growth, no frames).

overflow_drops_further_input_test() ->
    P0 = chappe_esl_parser:new(64),
    {_, P1} = chappe_esl_parser:feed(binary:copy(<<"a">>, 65), P0),
    {Frames, P2} = chappe_esl_parser:feed(reply_ok(), P1),
    ?assertEqual([], Frames),
    ?assert(chappe_esl_parser:overflowed(P2)),
    ?assertEqual(<<>>, chappe_esl_parser:buffer(P2)).

%% A complete frame that fits under the cap still parses, and a fully consumed
%% stream leaves the parser un-overflowed.

no_overflow_when_under_cap_test() ->
    {Frames, P} = chappe_esl_parser:feed(
        reply_ok(), chappe_esl_parser:new(1024)
    ),
    ?assertEqual([reply_ok_frame()], Frames),
    ?assertNot(chappe_esl_parser:overflowed(P)).
