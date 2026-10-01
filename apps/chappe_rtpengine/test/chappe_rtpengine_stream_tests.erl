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
