%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_rtpengine_bencode_tests).

-include_lib("eunit/include/eunit.hrl").

encode_integer_test() ->
    ?assertEqual(<<"i42e">>, chappe_rtpengine_bencode:encode_to_binary(42)),
    ?assertEqual(<<"i-7e">>, chappe_rtpengine_bencode:encode_to_binary(-7)),
    ?assertEqual(<<"i0e">>, chappe_rtpengine_bencode:encode_to_binary(0)).

encode_string_test() ->
    ?assertEqual(<<"4:ping">>, chappe_rtpengine_bencode:encode_to_binary(<<"ping">>)),
    ?assertEqual(<<"0:">>, chappe_rtpengine_bencode:encode_to_binary(<<>>)),
    %% atoms encode as strings
    ?assertEqual(<<"4:ping">>, chappe_rtpengine_bencode:encode_to_binary(ping)).

encode_list_test() ->
    ?assertEqual(
        <<"l4:spami3ee">>,
        chappe_rtpengine_bencode:encode_to_binary([<<"spam">>, 3])
    ),
    ?assertEqual(<<"le">>, chappe_rtpengine_bencode:encode_to_binary([])).

%% req: RNG-08
encode_dict_canonical_order_test() ->
    %% keys must be emitted in ascending raw byte order regardless of
    %% map internals
    ?assertEqual(
        <<"d1:a1:x1:bi1ee">>,
        chappe_rtpengine_bencode:encode_to_binary(#{<<"b">> => 1, <<"a">> => <<"x">>})
    ),
    %% "Z" (0x5A) sorts before "a" (0x61) bytewise
    ?assertEqual(
        <<"d1:Zi1e1:ai2ee">>,
        chappe_rtpengine_bencode:encode_to_binary(#{<<"a">> => 2, <<"Z">> => 1})
    ).

encode_nested_test() ->
    ?assertEqual(
        <<"d5:flagsl13:trust-addresse6:result2:oke">>,
        chappe_rtpengine_bencode:encode_to_binary(#{
            <<"result">> => <<"ok">>,
            <<"flags">> => [<<"trust-address">>]
        })
    ).

decode_ping_reply_test() ->
    ?assertEqual(
        {ok, #{<<"result">> => <<"pong">>}},
        chappe_rtpengine_bencode:decode(<<"d6:result4:ponge">>)
    ).

decode_wire_types_preserved_test() ->
    {ok, Reply} = chappe_rtpengine_bencode:decode(
        <<"d7:createdi1700000000e6:result2:ok3:sdp5:v=0\r\ne">>
    ),
    ?assertEqual(1700000000, maps:get(<<"created">>, Reply)),
    ?assertEqual(<<"v=0\r\n">>, maps:get(<<"sdp">>, Reply)).

decode_unsorted_dict_tolerated_test() ->
    ?assertEqual(
        {ok, #{<<"b">> => 1, <<"a">> => 2}},
        chappe_rtpengine_bencode:decode(<<"d1:bi1e1:ai2ee">>)
    ).

roundtrip_test() ->
    Term = #{
        <<"command">> => <<"offer">>,
        <<"call-id">> => <<"abc@host">>,
        <<"flags">> => [<<"trust-address">>, <<"SIP-source-address">>],
        <<"delete-delay">> => 30,
        <<"codec">> => #{<<"mask">> => [<<"all">>]}
    },
    ?assertEqual(
        {ok, Term},
        chappe_rtpengine_bencode:decode(chappe_rtpengine_bencode:encode_to_binary(Term))
    ).

%% Generative roundtrip: random nested terms limited to the canonical
%% wire types (integers, binaries, lists, binary-keyed maps) must
%% survive encode/decode unchanged. Fixed seed keeps it reproducible.
generative_roundtrip_test() ->
    _ = rand:seed(exsss, {1545, 997027, 42}),
    lists:foreach(
        fun(_) ->
            Term = gen_value(3),
            Encoded = chappe_rtpengine_bencode:encode_to_binary(Term),
            ?assertEqual({ok, Term}, chappe_rtpengine_bencode:decode(Encoded))
        end,
        lists:seq(1, 500)
    ).

gen_value(0) ->
    gen_leaf();
gen_value(Depth) ->
    case rand:uniform(4) of
        1 ->
            gen_leaf();
        2 ->
            gen_leaf();
        3 ->
            [gen_value(Depth - 1) || _ <- lists:seq(1, rand:uniform(4))];
        4 ->
            maps:from_list([
                {gen_binary(), gen_value(Depth - 1)}
             || _ <- lists:seq(1, rand:uniform(4))
            ])
    end.

gen_leaf() ->
    case rand:uniform(2) of
        1 -> rand:uniform(1 bsl 32) - (1 bsl 31);
        2 -> gen_binary()
    end.

%% arbitrary bytes, including delimiters (spaces, colons, e, digits)
gen_binary() ->
    rand:bytes(rand:uniform(13) - 1).

%% A real NG reply frame body (an offer reply shape) split at every
%% byte position: the head must be incomplete (or already a complete
%% value when the split lands past the document), never an error, and
%% the reassembled buffer must parse to exactly the expected value
%% with nothing left over.
stream_split_at_every_boundary_test() ->
    Frame = real_reply_frame(),
    {ok, Expected, <<>>} = chappe_rtpengine_bencode:decode_prefix(Frame),
    lists:foreach(
        fun(SplitAt) ->
            <<Head:SplitAt/binary, Tail/binary>> = Frame,
            case chappe_rtpengine_bencode:decode_prefix(Head) of
                incomplete ->
                    ok;
                {ok, Expected, <<>>} ->
                    ok;
                Other ->
                    error({unexpected_at_split, SplitAt, Other})
            end,
            ?assertEqual(
                {ok, Expected, <<>>},
                chappe_rtpengine_bencode:decode_prefix(<<Head/binary, Tail/binary>>)
            )
        end,
        lists:seq(0, byte_size(Frame))
    ).

%% Two frames back to back: the first parse leaves the second frame
%% intact as the rest, the second parse consumes it.
stream_two_frames_back_to_back_test() ->
    First = real_reply_frame(),
    Second = chappe_rtpengine_bencode:encode_to_binary(#{
        <<"result">> => <<"pong">>
    }),
    {ok, Value1, Rest1} = chappe_rtpengine_bencode:decode_prefix(
        <<First/binary, Second/binary>>
    ),
    {ok, Value1, <<>>} = chappe_rtpengine_bencode:decode_prefix(First),
    ?assertEqual(Second, Rest1),
    ?assertEqual(
        {ok, #{<<"result">> => <<"pong">>}, <<>>},
        chappe_rtpengine_bencode:decode_prefix(Rest1)
    ).

%% Growing a buffer byte by byte, as a TCP stream delivers it: every
%% prefix is incomplete until the document closes, and no input ever
%% makes the decoder throw.
stream_incremental_growth_test() ->
    Frame = real_reply_frame(),
    Full = byte_size(Frame),
    lists:foreach(
        fun(Len) ->
            <<Head:Len/binary, _/binary>> = Frame,
            ?assertEqual(incomplete, chappe_rtpengine_bencode:decode_prefix(Head))
        end,
        lists:seq(0, Full - 1)
    ),
    ?assertMatch({ok, _, <<>>}, chappe_rtpengine_bencode:decode_prefix(Frame)).

stream_malformed_head_test_() ->
    [
        ?_assertMatch({error, _}, chappe_rtpengine_bencode:decode_prefix(<<"x">>)),
        ?_assertMatch(
            {error, _}, chappe_rtpengine_bencode:decode_prefix(<<"d1:ai1ex">>)
        ),
        ?_assertMatch({error, _}, chappe_rtpengine_bencode:decode_prefix(<<"iXe">>)),
        ?_assertEqual(incomplete, chappe_rtpengine_bencode:decode_prefix(<<>>)),
        ?_assertEqual(incomplete, chappe_rtpengine_bencode:decode_prefix(<<"d">>)),
        %% truncated but valid prefixes stay incomplete, never error
        ?_assertEqual(
            incomplete, chappe_rtpengine_bencode:decode_prefix(<<"d1:ai1e">>)
        ),
        ?_assertEqual(incomplete, chappe_rtpengine_bencode:decode_prefix(<<"5:ab">>))
    ].

%% The body of a captured rtpengine offer reply, rebuilt canonically:
%% nested dict, list, integers and an SDP-like binary with \r\n and
%% digits that stress the length-prefix scanning.
real_reply_frame() ->
    chappe_rtpengine_bencode:encode_to_binary(#{
        <<"result">> => <<"ok">>,
        <<"sdp">> =>
            <<
                "v=0\r\no=- 1545997027 1 IN IP4 127.0.0.1\r\n"
                "s=call\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                "m=audio 30010 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
                "a=sendrecv\r\na=rtcp:30011\r\n"
            >>,
        <<"created">> => 1700000000,
        <<"from-tags">> => [<<"ft">>],
        <<"totals">> => #{
            <<"RTP">> => #{<<"packets">> => 12, <<"bytes">> => 2048}
        }
    }).

decode_error_test_() ->
    [
        ?_assertMatch({error, invalid}, chappe_rtpengine_bencode:decode(<<"x">>)),
        ?_assertMatch({error, unexpected_end}, chappe_rtpengine_bencode:decode(<<>>)),
        ?_assertMatch(
            {error, unterminated_integer}, chappe_rtpengine_bencode:decode(<<"i12">>)
        ),
        ?_assertMatch(
            {error, {bad_integer, _}}, chappe_rtpengine_bencode:decode(<<"iabce">>)
        ),
        ?_assertMatch(
            {error, truncated_string}, chappe_rtpengine_bencode:decode(<<"5:abc">>)
        ),
        ?_assertMatch(
            {error, unterminated_list}, chappe_rtpengine_bencode:decode(<<"li1e">>)
        ),
        ?_assertMatch(
            {error, unterminated_dict}, chappe_rtpengine_bencode:decode(<<"d">>)
        ),
        ?_assertMatch(
            {error, {bad_dict_key, 1}}, chappe_rtpengine_bencode:decode(<<"di1ei2ee">>)
        ),
        ?_assertMatch(
            {error, {trailing_bytes, 1}}, chappe_rtpengine_bencode:decode(<<"i1ee">>)
        )
    ].

%% Integers are canonical: no leading zeros, no negative zero, no plus
%% sign, at least one digit.
%% req: RNG-08
non_canonical_integer_rejected_test_() ->
    [
        ?_assertMatch({error, {bad_integer, _}}, chappe_rtpengine_bencode:decode(B))
     || B <- [<<"i03e">>, <<"i-0e">>, <<"i+1e">>, <<"i-e">>, <<"ie">>, <<"i-01e">>]
    ] ++
        [
            ?_assertEqual({ok, 0}, chappe_rtpengine_bencode:decode(<<"i0e">>)),
            ?_assertEqual({ok, -10}, chappe_rtpengine_bencode:decode(<<"i-10e">>)),
            %% an unfinished canonical integer is incomplete on a stream,
            %% a prefix that can never become canonical is an error
            ?_assertEqual(incomplete, chappe_rtpengine_bencode:decode_prefix(<<"i0">>)),
            ?_assertEqual(incomplete, chappe_rtpengine_bencode:decode_prefix(<<"i-">>)),
            ?_assertMatch({error, _}, chappe_rtpengine_bencode:decode_prefix(<<"i00">>)),
            ?_assertMatch({error, _}, chappe_rtpengine_bencode:decode_prefix(<<"i-0">>))
        ].

%% String length prefixes are canonical too.
%% req: RNG-08
non_canonical_length_rejected_test_() ->
    [
        ?_assertMatch(
            {error, {bad_length, _}}, chappe_rtpengine_bencode:decode(<<"05:hello">>)
        ),
        ?_assertMatch({error, _}, chappe_rtpengine_bencode:decode_prefix(<<"00">>)),
        ?_assertEqual({ok, <<>>}, chappe_rtpengine_bencode:decode(<<"0:">>)),
        ?_assertEqual({ok, <<"hello">>}, chappe_rtpengine_bencode:decode(<<"5:hello">>))
    ].

nested(0) -> <<"i1e">>;
nested(N) -> <<"l", (nested(N - 1))/binary, "e">>.

%% Nesting is bounded so a hostile reply cannot exhaust the stack.
%% req: RNG-09
nesting_depth_bounded_test() ->
    ?assertMatch({ok, _}, chappe_rtpengine_bencode:decode(nested(64))),
    ?assertEqual({error, too_deep}, chappe_rtpengine_bencode:decode(nested(65))),
    ?assertEqual(
        {error, too_deep}, chappe_rtpengine_bencode:decode_prefix(nested(65))
    ).

%% An atom key and a binary key that encode to the same bytes would
%% produce a dictionary with a duplicate key.
%% req: RNG-08
encode_duplicate_key_rejected_test() ->
    ?assertError(
        {duplicate_key, <<"a">>},
        chappe_rtpengine_bencode:encode(#{a => 1, <<"a">> => 2})
    ).

%% decode_stream/1 says how many more bytes a partial value needs at
%% least, so a stream reader does not rescan the buffer on every chunk.
%% req: RNG-02
stream_need_test_() ->
    [
        ?_assertEqual({more, 3}, chappe_rtpengine_bencode:decode_stream(<<"5:ab">>)),
        ?_assertEqual(
            {more, 7}, chappe_rtpengine_bencode:decode_stream(<<"d3:sdp10:abc">>)
        ),
        ?_assertEqual({more, 1}, chappe_rtpengine_bencode:decode_stream(<<"d">>)),
        ?_assertEqual({more, 1}, chappe_rtpengine_bencode:decode_stream(<<>>)),
        ?_assertEqual(
            {ok, 1, <<"rest">>},
            chappe_rtpengine_bencode:decode_stream(<<"i1erest">>)
        ),
        ?_assertMatch({error, _}, chappe_rtpengine_bencode:decode_stream(<<"x">>))
    ].
