%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_audio_http_tests).

-include_lib("eunit/include/eunit.hrl").

%% the upgrade libwebsockets sends for mod_audio_fork, as captured
fork_request() ->
    <<
        "GET /audio/abc?token=T0k-_ HTTP/1.1\r\n"
        "Pragma: no-cache\r\nCache-Control: no-cache\r\n"
        "Host: 10.0.0.5\r\nOrigin: 10.0.0.5\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Protocol: audio.drachtio.org\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    >>.

parse_test() ->
    {ok, Req, <<"rest">>} = chappe_audio_http:parse(
        <<(fork_request())/binary, "rest">>
    ),
    ?assertMatch(
        #{
            method := <<"GET">>,
            path := <<"/audio/abc">>,
            query := <<"token=T0k-_">>
        },
        Req
    ),
    Headers = maps:get(headers, Req),
    ?assertEqual(<<"websocket">>, proplists:get_value(<<"upgrade">>, Headers)),
    ?assertEqual(
        <<"audio.drachtio.org">>,
        proplists:get_value(<<"sec-websocket-protocol">>, Headers)
    ),
    ?assertEqual(<<"T0k-_">>, chappe_audio_http:token(Req)).

%% split at every byte: more until the blank line, then the same request
split_test() ->
    Bin = fork_request(),
    {ok, Want, <<>>} = chappe_audio_http:parse(Bin),
    [
        ?assertEqual(more, chappe_audio_http:parse(binary:part(Bin, 0, N)))
     || N <- lists:seq(0, byte_size(Bin) - 1)
    ],
    ?assertEqual({ok, Want, <<>>}, chappe_audio_http:parse(Bin)).

%% 4.2.1: an absolute URI holding the resource name is a Request-URI too
absolute_uri_test() ->
    {ok, #{path := <<"/audio/x">>, query := <<"token=t">>}, <<>>} =
        chappe_audio_http:parse(
            <<"GET http://h:80/audio/x?token=t HTTP/1.1\r\n\r\n">>
        ).

bad_requests_test() ->
    [
        ?assertEqual({error, bad_request}, chappe_audio_http:parse(B))
     || B <- [
            <<"GET /x HTTP/1.0\r\n\r\n">>,
            <<"GET * HTTP/1.1\r\n\r\n">>,
            <<"garbage\r\n\r\n">>,
            <<"GET /x HTTP/1.1\r\nno colon here\r\n\r\n">>,
            <<0, 1, 2, 3, "\r\n\r\n">>
        ]
    ].

route_test() ->
    P = <<"/audio">>,
    ?assertEqual({ok, <<"abc">>}, chappe_audio_http:route(P, <<"/audio/abc">>)),
    ?assertEqual(error, chappe_audio_http:route(P, <<"/audio/">>)),
    ?assertEqual(error, chappe_audio_http:route(P, <<"/audio">>)),
    ?assertEqual(error, chappe_audio_http:route(P, <<"/audio/a/b">>)),
    ?assertEqual(error, chappe_audio_http:route(P, <<"/audioabc">>)),
    ?assertEqual(error, chappe_audio_http:route(P, <<"/other/abc">>)).

token_test() ->
    Req = fun(Q, H) -> #{query => Q, headers => H} end,
    ?assertEqual(
        <<"a b">>, chappe_audio_http:token(Req(<<"x=1&token=a%20b">>, []))
    ),
    ?assertEqual(
        <<"bt">>,
        chappe_audio_http:token(
            Req(<<>>, [{<<"authorization">>, <<"Bearer bt">>}])
        )
    ),
    Basic = <<"Basic ", (base64:encode(<<"user:pw:with:colons">>))/binary>>,
    ?assertEqual(
        <<"pw:with:colons">>,
        chappe_audio_http:token(Req(<<>>, [{<<"authorization">>, Basic}]))
    ),
    [
        ?assertEqual(undefined, chappe_audio_http:token(Req(Q, H)))
     || {Q, H} <- [
            {<<>>, []},
            {<<"token">>, []},
            {<<"%zz">>, []},
            {<<>>, [{<<"authorization">>, <<"Basic !!!">>}]},
            {<<>>, [{<<"authorization">>, <<"Digest x">>}]},
            {<<>>, [{<<"authorization">>, <<"Bearer">>}]}
        ]
    ].

refuse_test() ->
    R = iolist_to_binary(chappe_audio_http:refuse(401)),
    ?assertMatch(<<"HTTP/1.1 401 Unauthorized\r\n", _/binary>>, R),
    ?assertNotEqual(nomatch, binary:match(R, <<"connection: close">>)).

levels_test() ->
    Full = binary:copy(<<32767:16/little-signed, -32767:16/little-signed>>, 80),
    [Db] = chappe_audio_pcm:levels(Full, 1),
    ?assert(abs(Db) < 0.01),
    ?assertEqual(['-inf'], chappe_audio_pcm:levels(<<0:320>>, 1)),
    ?assertEqual(['-inf'], chappe_audio_pcm:levels(<<>>, 1)).
