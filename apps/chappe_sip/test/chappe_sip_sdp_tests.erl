%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_sip_sdp (what the stack reads out of SDP) and
%% chappe_sip_media:bypass/2 (direct or anchored media).
-module(chappe_sip_sdp_tests).

-include_lib("eunit/include/eunit.hrl").

sdp(Addr) -> sdp(Addr, <<"RTP/AVP">>, []).

sdp(Addr, Proto, Extra) ->
    Family =
        case binary:match(Addr, <<":">>) of
            nomatch -> <<"IP4">>;
            _ -> <<"IP6">>
        end,
    iolist_to_binary(
        [
            <<"v=0\r\no=- 1 2 IN ">>,
            Family,
            <<" ">>,
            Addr,
            <<"\r\ns=-\r\n">>,
            <<"c=IN ">>,
            Family,
            <<" ">>,
            Addr,
            <<"\r\nt=0 0\r\n">>,
            <<"m=audio 4000 ">>,
            Proto,
            <<" 0\r\n">>,
            [[L, <<"\r\n">>] || L <- Extra]
        ]
    ).

origin_test() ->
    ?assertEqual(
        <<"- 1 2 IN IP4 192.0.2.1">>,
        chappe_sip_sdp:origin(sdp(<<"192.0.2.1">>))
    ),
    ?assertEqual(undefined, chappe_sip_sdp:origin(<<"v=0\r\n">>)).

on_hold_test() ->
    ?assertNot(chappe_sip_sdp:on_hold(sdp(<<"192.0.2.1">>))),
    ?assert(
        chappe_sip_sdp:on_hold(
            sdp(<<"192.0.2.1">>, <<"RTP/AVP">>, [<<"a=sendonly">>])
        )
    ),
    ?assert(
        chappe_sip_sdp:on_hold(
            sdp(<<"192.0.2.1">>, <<"RTP/AVP">>, [<<"a=inactive">>])
        )
    ),
    ?assertNot(
        chappe_sip_sdp:on_hold(
            sdp(<<"192.0.2.1">>, <<"RTP/AVP">>, [<<"a=recvonly">>])
        )
    ),
    %% a session-level direction holds for the m-line
    Sess = <<
        "v=0\r\no=- 1 1 IN IP4 192.0.2.1\r\ns=-\r\na=sendonly\r\n"
        "c=IN IP4 192.0.2.1\r\nt=0 0\r\nm=audio 4000 RTP/AVP 0\r\n"
    >>,
    ?assert(chappe_sip_sdp:on_hold(Sess)),
    ?assertNot(chappe_sip_sdp:on_hold(<<>>)).

webrtc_test() ->
    ?assertNot(chappe_sip_sdp:webrtc(sdp(<<"192.0.2.1">>))),
    ?assert(
        chappe_sip_sdp:webrtc(sdp(<<"192.0.2.1">>, <<"UDP/TLS/RTP/SAVPF">>, []))
    ),
    ?assert(
        chappe_sip_sdp:webrtc(
            sdp(<<"192.0.2.1">>, <<"RTP/AVP">>, [<<"a=ice-ufrag:abcd">>])
        )
    ).

connection_test() ->
    ?assertEqual(
        {192, 0, 2, 1}, chappe_sip_sdp:connection(sdp(<<"192.0.2.1">>))
    ),
    ?assertEqual(
        {16#2001, 16#db8, 0, 0, 0, 0, 0, 1},
        chappe_sip_sdp:connection(sdp(<<"2001:db8::1">>))
    ),
    ?assertEqual(undefined, chappe_sip_sdp:connection(<<"v=0\r\n">>)).

bypass(A, B) -> bypass(A, B, #{}).
bypass(A, B, Opts) -> chappe_sip_media:bypass(#{a => A, b => B}, Opts).

bypass_public_direct_test() ->
    ?assertEqual(direct, bypass(sdp(<<"192.0.2.1">>), sdp(<<"198.51.100.7">>))),
    ?assertEqual(direct, bypass(sdp(<<"192.0.2.1">>), {198, 51, 100, 7})).

bypass_webrtc_anchors_test() ->
    W = sdp(<<"192.0.2.1">>, <<"UDP/TLS/RTP/SAVPF">>, [<<"a=ice-ufrag:x">>]),
    ?assertEqual(anchor, bypass(W, sdp(<<"198.51.100.7">>))),
    ?assertEqual(anchor, bypass(sdp(<<"198.51.100.7">>), W)).

bypass_family_mismatch_anchors_test() ->
    ?assertEqual(anchor, bypass(sdp(<<"192.0.2.1">>), sdp(<<"2001:db8::1">>))).

bypass_unknown_anchors_test() ->
    ?assertEqual(anchor, bypass(sdp(<<"192.0.2.1">>), #{})).

bypass_private_test() ->
    A = sdp(<<"10.1.0.5">>),
    B = sdp(<<"10.1.7.9">>),
    %% private without a network naming both: anchor
    ?assertEqual(anchor, bypass(A, B)),
    ?assertEqual(direct, bypass(A, B, #{networks => [<<"10.1.0.0/16">>]})),
    ?assertEqual(anchor, bypass(A, B, #{networks => [<<"10.1.0.0/24">>]})),
    %% one private, one public: anchor
    ?assertEqual(
        anchor,
        bypass(
            A,
            sdp(<<"198.51.100.7">>),
            #{networks => [<<"10.0.0.0/8">>]}
        )
    ),
    ?assertEqual(
        direct,
        bypass(
            sdp(<<"fd00::1">>),
            sdp(<<"fd00::2">>),
            #{networks => [<<"fd00::/8">>]}
        )
    ),
    %% a malformed network is ignored
    ?assertEqual(
        anchor, bypass(A, B, #{networks => [<<"10.1.0.0/99">>, <<"x">>]})
    ).

bypass_nat_anchors_test() ->
    %% c= says 192.168.1.5, the INVITE came from 203.0.113.9: a NAT
    A = #{sdp => sdp(<<"192.168.1.5">>), source => <<"203.0.113.9">>},
    ?assertEqual(anchor, bypass(A, sdp(<<"198.51.100.7">>))),
    Same = #{sdp => sdp(<<"203.0.113.9">>), source => {203, 0, 113, 9}},
    ?assertEqual(direct, bypass(Same, sdp(<<"198.51.100.7">>))).
