%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_sdes: the a=crypto lines (RFC 4568) a recording server
%% takes, skips and answers. The example keys are RFC 4568's own (6.1,
%% 4.5).
-module(chappe_sip_sdes_tests).

-include_lib("eunit/include/eunit.hrl").

-define(D, chappe_sip_sdes).

%% RFC 4568 6.1's first example, and its 30 octets
-define(K1, "d0RmdmcmVCspeEc3QGZiNWpVLFJhQX1cfHAwJSoj").
%% RFC 4568 6.1's second example
-define(K2, "YUJDZGVmZ2hpSktMbW9QUXJzVHVWd3l6MTIzNDU2").

line(L) -> <<"a=crypto:", L/binary>>.

inline_key_test() ->
    {ok, C} = ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1>>),
    <<K:16/binary, S:14/binary>> = base64:decode(<<?K1>>),
    ?assertMatch(#{tag := <<"1">>, suite := aes_cm_128_hmac_sha1_80, key := K, salt := S}, C),
    ?assertNot(maps:is_key(mki, C)),
    ?assertMatch({ok, #{suite := aes_cm_128_hmac_sha1_32}},
                 ?D:parse(<<"7 AES_CM_128_HMAC_SHA1_32 inline:" ?K1>>)),
    %% ABNF strings are case-insensitive
    ?assertMatch({ok, _}, ?D:parse(<<"1 aes_cm_128_hmac_sha1_80 INLINE:" ?K1>>)),
    %% padding characters are discarded (6.1)
    ?assertMatch({ok, #{key := K}}, ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 "==">>)).

%% RFC 4568 6.1: lifetime and MKI, in their examples
lifetime_and_mki_test() ->
    {ok, C1} = ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 "|2^20|1:4">>),
    ?assertMatch(#{lifetime := 1048576, mki := <<0, 0, 0, 1>>}, C1),
    {ok, C2} = ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K2 "|1066:4">>),
    ?assertMatch(#{mki := <<1066:32>>}, C2),
    ?assertNot(maps:is_key(lifetime, C2)),
    {ok, C3} = ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K2 "|4096">>),
    ?assertMatch(#{lifetime := 4096}, C3),
    [?assertEqual({error, invalid}, ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1, X/binary>>))
     || X <- [<<"|0">>, <<"|2^49">>, <<"|0100">>, <<"|1:0">>, <<"|1:129">>, <<"|256:1">>,
              <<"|1:">>, <<"|x">>, <<"|2^20|1:4|9">>, <<"|01:4">>]].

%% RFC 4568 6.1, 6.2.1: a key and salt of another length is invalid
bad_key_test() ->
    [?assertEqual({error, invalid}, ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:", K/binary>>))
     || K <- [base64:encode(<<0:(29 * 8)>>), base64:encode(<<0:(31 * 8)>>), <<"!!!!">>, <<>>]],
    ?assertEqual({error, invalid}, ?D:parse(<<"x AES_CM_128_HMAC_SHA1_80 inline:" ?K1>>)),
    ?assertEqual({error, invalid}, ?D:parse(<<"1234567890 AES_CM_128_HMAC_SHA1_80 inline:" ?K1>>)),
    ?assertEqual({error, invalid}, ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80">>)),
    ?assertEqual({error, invalid}, ?D:parse(<<"1 AES-CM inline:" ?K1>>)).

%% What is not supported is refused cleanly, never half taken.
unsupported_test() ->
    [?assertEqual({error, unsupported}, ?D:parse(L)) || L <- [
        <<"1 F8_128_HMAC_SHA1_80 inline:" ?K1>>,
        <<"1 AEAD_AES_128_GCM inline:" ?K1>>,
        <<"1 AES_256_CM_HMAC_SHA1_80 inline:" ?K1>>,
        %% several master keys
        <<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 "|2^20|1:4;inline:" ?K2 "|2^20|2:4">>,
        <<"1 AES_CM_128_HMAC_SHA1_80 url:http://example.com/key">>,
        <<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 " KDR=3">>,
        <<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 " UNENCRYPTED_SRTP">>,
        <<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 " UNENCRYPTED_SRTCP">>,
        <<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 " UNAUTHENTICATED_SRTP">>,
        <<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 " FEC_KEY=inline:" ?K2>>
    ]].

%% RFC 4568 6.3
session_params_test() ->
    P = fun(X) -> ?D:parse(<<"1 AES_CM_128_HMAC_SHA1_80 inline:" ?K1 " ", X/binary>>) end,
    ?assertMatch({ok, _}, P(<<"KDR=0">>)),
    ?assertMatch({ok, #{window := 256}}, P(<<"WSH=256">>)),
    ?assertMatch({ok, #{window := 1024}}, P(<<"WSH=100000">>)),
    ?assertEqual({error, invalid}, P(<<"WSH=32">>)),
    ?assertMatch({ok, _}, P(<<"FEC_ORDER=FEC_SRTP">>)),
    ?assertMatch({ok, _}, P(<<"-X_OPTIONAL=1 WSH=64">>)),
    %% an unknown mandatory parameter makes the line invalid (6.3.7)
    ?assertEqual({error, invalid}, P(<<"NEW_THING">>)),
    ?assertEqual({error, invalid}, P(<<"KDR=25">>)).

%% RFC 4568 5.1.2, 7.1.2: the first valid supported line; none, refused
select_test() ->
    Lines = [<<"m=audio 1000 RTP/SAVP 0">>,
             line(<<"1 AES_256_CM_HMAC_SHA1_80 inline:" ?K1>>),
             line(<<"2 AES_CM_128_HMAC_SHA1_80 inline:short">>),
             line(<<"3 AES_CM_128_HMAC_SHA1_32 inline:" ?K2>>),
             line(<<"4 AES_CM_128_HMAC_SHA1_80 inline:" ?K1>>),
             <<"a=sendonly">>],
    ?assertMatch({ok, #{tag := <<"3">>, suite := aes_cm_128_hmac_sha1_32}}, ?D:select(Lines)),
    ?assertEqual({error, no_crypto}, ?D:select([<<"m=audio 1000 RTP/SAVP 0">>])),
    ?assertEqual({error, unsupported}, ?D:select(lists:sublist(Lines, 3))).

%% RFC 4568 7.1.2: the answer echoes the tag and suite, with a key of its
%% own (never the offer's), that parses back
answer_test() ->
    {ok, C} = ?D:parse(<<"9 AES_CM_128_HMAC_SHA1_32 inline:" ?K1>>),
    <<"a=crypto:", V/binary>> = A = ?D:answer(C),
    ?assertMatch(<<"a=crypto:9 AES_CM_128_HMAC_SHA1_32 inline:", _/binary>>, A),
    {ok, Back} = ?D:parse(V),
    ?assertNotEqual(maps:get(key, C), maps:get(key, Back)),
    ?assertNotEqual(?D:answer(C), A).

%% Random bytes as an a=crypto value: an answer or an error, never a crash.
random_lines_test() ->
    Chars = <<"0123456789 AES_CM_128_HMAC_SHA1_80inline:|^;=-+/ab", ?K1>>,
    lists:foreach(
        fun(_) ->
            L = << <<(binary:at(Chars, rand:uniform(byte_size(Chars)) - 1))>>
                   || _ <- lists:seq(1, rand:uniform(90)) >>,
            ?assertMatch({_, _}, ?D:parse(L)),
            ?assertMatch({_, _}, ?D:parse(rand:bytes(rand:uniform(90))))
        end,
        lists:seq(1, 3000)
    ).
