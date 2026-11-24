%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_rtpengine_stream_tests).

-include_lib("eunit/include/eunit.hrl").

frame(Cookie, Map) ->
    iolist_to_binary([Cookie, $\s, chappe_rtpengine_bencode:encode(Map)]).

two_frames() ->
    A = frame(<<"c1">>, #{
        <<"result">> => <<"ok">>,
        <<"sdp">> => <<"v=0\r\nm=audio 30000 RTP/AVP 0\r\n">>
    }),
    B = frame(<<"c2">>, #{<<"result">> => <<"pong">>}),
    <<A/binary, B/binary>>.

expected() ->
    [
        {<<"c1">>, #{
            <<"result">> => <<"ok">>,
            <<"sdp">> => <<"v=0\r\nm=audio 30000 RTP/AVP 0\r\n">>
        }},
        {<<"c2">>, #{<<"result">> => <<"pong">>}}
    ].

feed_all(Chunks) ->
    {Msgs, _} = lists:foldl(
        fun(Chunk, {Acc, S}) ->
            {ok, New, S1} = chappe_rtpengine_stream:feed(Chunk, S),
            {Acc ++ New, S1}
        end,
        {[], chappe_rtpengine_stream:new()},
        Chunks
    ),
    Msgs.

%% Two messages split at every byte position come out whole, in order.
%% req: RNG-02
split_at_every_boundary_test() ->
    Bin = two_frames(),
    lists:foreach(
        fun(At) ->
            <<H:At/binary, T/binary>> = Bin,
            ?assertEqual(expected(), feed_all([H, T]))
        end,
        lists:seq(0, byte_size(Bin))
    ).

%% req: RNG-02
byte_by_byte_test() ->
    Bin = two_frames(),
    ?assertEqual(expected(), feed_all([<<B>> || <<B>> <= Bin])).

%% req: RNG-02
cookie_cap_test() ->
    ?assertMatch(
        {error, cookie_too_long, []},
        chappe_rtpengine_stream:feed(
            binary:copy(<<"x">>, 300), chappe_rtpengine_stream:new()
        )
    ).

%% A value announcing more than 4 MiB fails before the bytes arrive.
%% req: RNG-02
announced_size_cap_test() ->
    ?assertMatch(
        {error, {too_large, _}, []},
        chappe_rtpengine_stream:feed(
            <<"c d3:sdp5000000:v=0">>, chappe_rtpengine_stream:new()
        )
    ).

%% req: RNG-02
buffered_size_cap_test() ->
    {ok, [], S} = chappe_rtpengine_stream:feed(
        <<"c d3:sdp4194000:">>, chappe_rtpengine_stream:new()
    ),
    ?assertMatch(
        {error, {too_large, _}, []},
        chappe_rtpengine_stream:feed(binary:copy(<<"x">>, 4194304), S)
    ).

%% Messages before corrupt bytes are still delivered.
%% req: RNG-02
corrupt_after_message_test() ->
    Good = frame(<<"c1">>, #{<<"result">> => <<"pong">>}),
    ?assertMatch(
        {error, invalid, [{<<"c1">>, #{<<"result">> := <<"pong">>}}]},
        chappe_rtpengine_stream:feed(
            <<Good/binary, "c2 x">>, chappe_rtpengine_stream:new()
        )
    ).

%% Random nested values, framed back to back and fed in random
%% fragments (one byte at a time included), decode exactly as the
%% stream fed in one chunk does.
%% req: RNG-02
random_fragments_match_one_chunk_test() ->
    rand:seed(exsss, {7, 11, 13}),
    lists:foreach(fun(_) -> random_round() end, lists:seq(1, 50)).

random_round() ->
    Values = [random_value(3) || _ <- lists:seq(1, 4)],
    Frames = lists:zip([integer_to_binary(I) || I <- lists:seq(1, 4)], Values),
    Bin = iolist_to_binary([
        [C, $\s, chappe_rtpengine_bencode:encode(V)]
     || {C, V} <- Frames
    ]),
    Expected = [{C, decoded(V)} || {C, V} <- Frames],
    ?assertEqual(Expected, feed_all([Bin])),
    ?assertEqual(Expected, feed_all([<<B>> || <<B>> <= Bin])),
    ?assertEqual(Expected, feed_all(random_split(Bin))).

%% A value with many small elements arriving in small fragments costs
%% work linear in its size: each byte is scanned once and the value is
%% decoded once, not re-parsed per fragment.
%% req: RNG-02
fragmented_cost_is_linear_test() ->
    R2000 = fragmented_cost(2000),
    R4000 = fragmented_cost(4000),
    ?assert(R4000 < 3 * R2000),
    %% about 12 bytes per element; a quadratic framer is far above this
    ?assert(R4000 < 4000 * 400).

%% Integers and string lengths are checked as they arrive.
%% req: RNG-02
bad_prefix_test() ->
    New = chappe_rtpengine_stream:new(),
    ?assertMatch(
        {error, _, []}, chappe_rtpengine_stream:feed(<<"c i01">>, New)
    ),
    ?assertMatch(
        {error, _, []}, chappe_rtpengine_stream:feed(<<"c i-0">>, New)
    ),
    ?assertMatch({error, _, []}, chappe_rtpengine_stream:feed(<<"c 01">>, New)),
    ?assertMatch({error, _, []}, chappe_rtpengine_stream:feed(<<"c 1x">>, New)),
    ?assertMatch(
        {error, _, []}, chappe_rtpengine_stream:feed(<<"c di1e">>, New)
    ),
    ?assertMatch({error, _, []}, chappe_rtpengine_stream:feed(<<"c e">>, New)).

%% req: RNG-02
too_deep_test() ->
    ?assertMatch(
        {error, too_deep, []},
        chappe_rtpengine_stream:feed(
            <<"c ", (binary:copy(<<"l">>, 65))/binary>>,
            chappe_rtpengine_stream:new()
        )
    ).

%% The cookie cap holds when the cookie arrives in fragments.
%% req: RNG-02
fragmented_cookie_cap_test() ->
    Chunks = split_every(binary:copy(<<"x">>, 300), 10),
    ?assertMatch({error, cookie_too_long}, feed_until_error(Chunks)).

feed_until_error(Chunks) ->
    lists:foldl(
        fun
            (Chunk, S) when element(1, S) =/= error ->
                case chappe_rtpengine_stream:feed(Chunk, S) of
                    {ok, [], S1} -> S1;
                    {error, Reason, []} -> {error, Reason}
                end;
            (_Chunk, Err) ->
                Err
        end,
        chappe_rtpengine_stream:new(),
        Chunks
    ).

fragmented_cost(N) ->
    Bin = frame(<<"cookie">>, [#{<<"k">> => I} || I <- lists:seq(1, N)]),
    Chunks = split_every(Bin, 4),
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        {reductions, R0} = erlang:process_info(self(), reductions),
        [{<<"cookie">>, L}] = feed_all(Chunks),
        {reductions, R1} = erlang:process_info(self(), reductions),
        N = length(L),
        Parent ! {self(), R1 - R0}
    end),
    receive
        {Pid, R} ->
            erlang:demonitor(Mon, [flush]),
            R;
        {'DOWN', Mon, process, Pid, Reason} ->
            error(Reason)
    end.

split_every(Bin, Size) when byte_size(Bin) =< Size -> [Bin];
split_every(Bin, Size) ->
    <<H:Size/binary, T/binary>> = Bin,
    [H | split_every(T, Size)].

random_split(<<>>) ->
    [];
random_split(Bin) ->
    N = min(byte_size(Bin), rand:uniform(7)),
    <<H:N/binary, T/binary>> = Bin,
    [H | random_split(T)].

random_value(0) ->
    random_leaf();
random_value(Depth) ->
    case rand:uniform(4) of
        1 ->
            [random_value(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        2 ->
            maps:from_list([
                {random_bin(), random_value(Depth - 1)}
             || _ <- lists:seq(1, rand:uniform(4) - 1)
            ]);
        _ ->
            random_leaf()
    end.

random_leaf() ->
    case rand:uniform(2) of
        1 -> rand:uniform(200001) - 100001;
        2 -> random_bin()
    end.

random_bin() ->
    list_to_binary([
        $a + rand:uniform(26) - 1
     || _ <- lists:seq(1, rand:uniform(12) - 1)
    ]).

decoded(V) ->
    {ok, D} = chappe_rtpengine_bencode:decode(
        chappe_rtpengine_bencode:encode_to_binary(V)
    ),
    D.
