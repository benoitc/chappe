%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_srtp (RFC 3711, receive side) against the RFC's Appendix B
%% vectors, libsrtp's reference packets, a reference sender written apart
%% (chappe_sip_test_srtp) on random packets, and malformed, forged and
%% replayed packets.
-module(chappe_sip_srtp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S, chappe_sip_srtp).
-define(T, chappe_sip_test_srtp).

h(Hex) -> binary:decode_hex(Hex).

%% ---- RFC 3711 Appendix B (vectors copied from the RFC text) ----

%% B.2: the AES-CM keystream of session key 2B7E... and the shifted salt
%% F0F1...FCFD0000 at SSRC 0, index 0, over 65282 blocks.
b2_aes_cm_keystream_test() ->
    Key = h(<<"2B7E151628AED2A6ABF7158809CF4F3C">>),
    Salt = h(<<"F0F1F2F3F4F5F6F7F8F9FAFBFCFD">>),
    Ks = ?S:crypt(Key, Salt, 0, 0, <<0:(65282 * 128)>>),
    Block = fun(N) -> binary:part(Ks, N * 16, 16) end,
    ?assertEqual(h(<<"E03EAD0935C95E80E166B16DD92B4EB4">>), Block(0)),
    ?assertEqual(h(<<"D23513162B02D0F72A43A2FE4A5F97AB">>), Block(1)),
    ?assertEqual(h(<<"41E95B3BB0A2E8DD477901E4FCA894C0">>), Block(2)),
    ?assertEqual(h(<<"EC8CDF7398607CB0F2D21675EA9EA1E4">>), Block(16#FEFF)),
    ?assertEqual(h(<<"362B7C3C6773516318A077D7FC5073AE">>), Block(16#FF00)),
    ?assertEqual(h(<<"6A2CC3787889374FBEB4C81B17BA6C44">>), Block(16#FF01)).

%% B.3: the cipher key, cipher salt and (94 octets of) auth key of master
%% key E1F9... and master salt 0EC6...
b3_key_derivation_test() ->
    Mk = h(<<"E1F97A0D3E018BE0D64FA32C06DE4139">>),
    Ms = h(<<"0EC675AD498AFEEBB6960B3AABE6">>),
    ?assertEqual(h(<<"C61E7A93744F39EE10734AFE3FF7A087">>), ?S:derive(Mk, Ms, 0, 16)),
    ?assertEqual(h(<<"30CBBC08863D8C85D49DB34A9AE1">>), ?S:derive(Mk, Ms, 2, 14)),
    ?assertEqual(
        h(<<"CEBE321F6FF7716B6FD4AB49AF256A156D38BAA48F0A0ACF3C34E2359E6CDBCE"
            "E049646C43D9327AD175578EF72270986371C10C9A369AC2F94A8C5FBCDDDC25"
            "6D6E919A48B610EF17C2041E474035766B68642C59BBFC2F34DB60DBDFB2">>),
        ?S:derive(Mk, Ms, 1, 94)
    ),
    %% the reference sender derives the same keys
    #{rtp_enc := E, rtp_salt := Sa} = ?T:sender(<<Mk/binary, Ms/binary>>),
    ?assertEqual({?S:derive(Mk, Ms, 0, 16), ?S:derive(Mk, Ms, 2, 14)}, {E, Sa}).

%% ---- libsrtp's srtp_validate() reference packets (test/srtp_driver.c,
%% v2.6.0): the default policy, AES_CM_128_HMAC_SHA1_80, SSRC cafebabe ----

libsrtp_master() ->
    h(<<"E1F97A0D3E018BE0D64FA32C06DE41390EC675AD498AFEEBB6960B3AABE6">>).

ctx() -> ctx(#{}).

ctx(Opts) ->
    <<K:16/binary, S:14/binary>> = maps:get(master, Opts, libsrtp_master()),
    {ok, C} = ?S:new(maps:merge(
        #{suite => aes_cm_128_hmac_sha1_80, key => K, salt => S},
        maps:remove(master, Opts)
    )),
    C.

libsrtp_rtp_test() ->
    Plain = h(<<"800f1234decafbadcafebabeabababababababababababababababab">>),
    Cipher = h(<<"800f1234decafbadcafebabe4e55dc4ce79978d88ca4d215949d2402b78d6acc99ea179b8dbb">>),
    ?assertMatch({ok, Plain, _}, ?S:unprotect(Cipher, ctx())),
    ?assertEqual(Cipher, ?T:protect(Plain, 0, ?T:sender(libsrtp_master()))).

libsrtp_rtcp_test() ->
    Plain = h(<<"81c8000bcafebabeabababababababababababababababab">>),
    Cipher = h(<<"81c8000bcafebabe7128035be487b9bdbef89041f977a5a880000001993e08cd54d6c1230798">>),
    ?assertMatch({ok, Plain, _}, ?S:unprotect_rtcp(Cipher, ctx())),
    ?assertEqual(Cipher, ?T:protect_rtcp(Plain, 1, ?T:sender(libsrtp_master()))).

%% ---- property: what the reference sender protects decrypts back ----

rtp(Seq, Ssrc, Payload) ->
    <<2:2, 0:1, 0:1, 0:4, 0:1, 0:7, Seq:16, (Seq * 160):32, Ssrc:32, Payload/binary>>.

%% Random keys, suites, SSRCs, starting sequence numbers (near the wrap
%% too), header shapes and payload sizes, a few packets each in order:
%% each decrypts to the packet sent. 300 runs, seeded.
random_round_trip_test_() ->
    {timeout, 60, fun() ->
        Seed = erlang:phash2(erlang:monotonic_time()),
        _ = rand:seed(exsss, Seed),
        ?debugFmt("srtp property seed ~b", [Seed]),
        lists:foreach(fun(_) -> round_trip() end, lists:seq(1, 300))
    end}.

round_trip() ->
    Master = ?T:master(),
    {Suite, TagLen} = lists:nth(rand:uniform(2), [
        {aes_cm_128_hmac_sha1_80, 10}, {aes_cm_128_hmac_sha1_32, 4}
    ]),
    Mki = lists:nth(rand:uniform(3), [<<>>, <<1>>, <<0, 0, 4, 2>>]),
    Opts = #{master => Master, suite => Suite},
    C0 = ctx(case Mki of <<>> -> Opts; _ -> Opts#{mki => Mki} end),
    Snd = ?T:sender(Master, #{tag => TagLen, mki => Mki}),
    Ssrc = rand:uniform(16#FFFFFFFF),
    Start = lists:nth(rand:uniform(2), [rand:uniform(65536) - 1, 65530 + rand:uniform(5)]),
    lists:foldl(
        fun(N, C) ->
            Seq0 = Start + N,
            Rtp = random_rtp(Seq0 rem 65536, Ssrc),
            {ok, Got, C1} = ?S:unprotect(?T:protect(Rtp, Seq0 div 65536, Snd), C),
            ?assertEqual(Rtp, Got),
            C1
        end,
        C0,
        lists:seq(0, 4 + rand:uniform(8))
    ),
    %% and SRTCP, a few indices
    lists:foldl(
        fun(I, C) ->
            Rtcp = <<2:2, 0:1, 0:5, 201:8, 1:16, Ssrc:32, (rand:bytes(rand:uniform(40)))/binary>>,
            {ok, Rtcp, C1} = ?S:unprotect_rtcp(?T:protect_rtcp(Rtcp, I, Snd), C),
            C1
        end,
        C0,
        lists:seq(rand:uniform(1000), 1005)
    ).

random_rtp(Seq, Ssrc) ->
    CC = rand:uniform(3) - 1,
    Csrc = rand:bytes(CC * 4),
    {X, Ext} =
        case rand:uniform(2) of
            1 -> {0, <<>>};
            2 -> L = rand:uniform(3) - 1, {1, <<16#BEDE:16, L:16, (rand:bytes(L * 4))/binary>>}
        end,
    Payload = rand:bytes(rand:uniform(200) - 1),
    <<2:2, 0:1, X:1, CC:4, 0:1, 0:7, Seq:16, 1234:32, Ssrc:32, Csrc/binary, Ext/binary,
      Payload/binary>>.

%% ---- the rollover counter and index estimation (RFC 3711 3.3.1) ----

%% Across the wrap of SEQ, with a late packet from before it: each packet
%% decrypts with the ROC its sender used.
rollover_test() ->
    Snd = ?T:sender(libsrtp_master()),
    P = fun(Seq, Roc) -> ?T:protect(rtp(Seq, 7, <<Seq:16>>), Roc, Snd) end,
    C0 = ctx(),
    {ok, _, C1} = ?S:unprotect(P(65534, 0), C0),
    {ok, _, C2} = ?S:unprotect(P(1, 1), C1),
    %% late, from before the wrap: ROC - 1
    {ok, <<_:12/binary, 65535:16>>, C3} = ?S:unprotect(P(65535, 0), C2),
    {ok, _, C4} = ?S:unprotect(P(2, 1), C3),
    %% the second wrap, in steps under 2^15
    {ok, _, C5} = ?S:unprotect(P(30000, 1), C4),
    {ok, _, C6} = ?S:unprotect(P(60000, 1), C5),
    {ok, _, _} = ?S:unprotect(P(100, 2), C6),
    %% a packet protected with another ROC does not authenticate
    ?assertEqual({error, auth}, ?S:unprotect(P(3, 0), C4)).

%% ---- the replay window (RFC 3711 3.3.2) ----

replay_test() ->
    Snd = ?T:sender(libsrtp_master()),
    P = fun(Seq) -> ?T:protect(rtp(Seq, 7, <<"x">>), 0, Snd) end,
    {ok, _, C1} = ?S:unprotect(P(1000), ctx()),
    ?assertEqual({error, replay}, ?S:unprotect(P(1000), C1)),
    {ok, _, C2} = ?S:unprotect(P(1010), C1),
    %% out of order inside the window: taken once
    {ok, _, C3} = ?S:unprotect(P(1005), C2),
    ?assertEqual({error, replay}, ?S:unprotect(P(1005), C3)),
    ?assertEqual({error, replay}, ?S:unprotect(P(1010), C3)),
    ?assertEqual({error, replay}, ?S:unprotect(P(1000), C3)),
    %% the window is 128 packets: 1010 - 128 is behind it
    {ok, _, _} = ?S:unprotect(P(1010 - 127), C3),
    ?assertEqual({error, replay}, ?S:unprotect(P(1010 - 128), C3)),
    %% a jump keeps the packets it moves past in the window
    {ok, _, C4} = ?S:unprotect(P(1050), C3),
    ?assertEqual({error, replay}, ?S:unprotect(P(1010), C4)),
    ?assertEqual({error, replay}, ?S:unprotect(P(1005), C4)),
    {ok, _, _} = ?S:unprotect(P(1006), C4).

rtcp_replay_test() ->
    Snd = ?T:sender(libsrtp_master()),
    Rtcp = h(<<"81c8000bcafebabeabababababababababababababababab">>),
    P = fun(I) -> ?T:protect_rtcp(Rtcp, I, Snd) end,
    {ok, _, C1} = ?S:unprotect_rtcp(P(5), ctx()),
    ?assertEqual({error, replay}, ?S:unprotect_rtcp(P(5), C1)),
    {ok, _, C2} = ?S:unprotect_rtcp(P(9), C1),
    {ok, _, _} = ?S:unprotect_rtcp(P(7), C2),
    ?assertEqual({error, replay}, ?S:unprotect_rtcp(P(5), C2)).

%% ---- forged and malformed packets ----

%% Every bit of the authenticated portion and of the tag is covered: a
%% packet with any one bit flipped is refused, and the context is left as
%% it was (the genuine packet still goes through after).
forged_test() ->
    Snd = ?T:sender(libsrtp_master()),
    Good = ?T:protect(rtp(10, 7, <<"payload">>), 0, Snd),
    C = ctx(),
    lists:foreach(
        fun(Bit) ->
            <<A:Bit, B:1, R/bitstring>> = Good,
            Bad = <<A:Bit, (1 - B):1, R/bitstring>>,
            ?assertMatch({error, _}, ?S:unprotect(Bad, C))
        end,
        lists:seq(0, bit_size(Good) - 1)
    ),
    {ok, _, _} = ?S:unprotect(Good, C),
    %% a packet of another key
    Other = ?T:protect(rtp(10, 7, <<"payload">>), 0, ?T:sender(?T:master())),
    ?assertEqual({error, auth}, ?S:unprotect(Other, C)).

malformed_test() ->
    C = ctx(),
    Good = ?T:protect(rtp(10, 7, <<"payload">>), 0, ?T:sender(libsrtp_master())),
    [?assertEqual({error, malformed}, ?S:unprotect(B, C)) || B <- [
        <<>>,
        <<1, 2, 3>>,
        %% version 1
        <<1:2, 0:6, 0, 0:80>>,
        %% header with no room for the tag
        binary:part(rtp(1, 2, <<>>), 0, 12),
        <<(binary:part(rtp(1, 2, <<>>), 0, 12))/binary, 0:72>>,
        %% CSRC count past the end
        <<2:2, 0:2, 15:4, 0:8, 1:16, 0:32, 7:32, 0:80>>,
        %% extension length past the end
        <<2:2, 0:1, 1:1, 0:4, 0:8, 1:16, 0:32, 7:32, 16#BEDE:16, 200:16, 0:80>>,
        %% truncated
        binary:part(Good, 0, 21)
    ]],
    [?assertEqual({error, malformed}, ?S:unprotect_rtcp(B, C)) || B <- [
        <<>>, <<16#81, 16#c8, 0, 1>>, <<0:8, 16#c8, 0:(8 * 26)>>
    ]],
    %% SRTCP with E clear: not without UNENCRYPTED_SRTCP (RFC 4568 6.3.2)
    Rtcp = h(<<"81c8000bcafebabeabababababababababababababababab">>),
    #{rtcp_auth := A} = ?T:sender(libsrtp_master()),
    Body = <<Rtcp/binary, 0:1, 1:31>>,
    Clear = <<Body/binary, (binary:part(crypto:mac(hmac, sha, A, Body), 0, 10))/binary>>,
    ?assertEqual({error, malformed}, ?S:unprotect_rtcp(Clear, C)).

%% Random bytes never crash it, and never pass.
random_bytes_test() ->
    C = ctx(),
    lists:foreach(
        fun(_) ->
            B = rand:bytes(rand:uniform(80) - 1),
            ?assertMatch({error, _}, ?S:unprotect(B, C)),
            ?assertMatch({error, _}, ?S:unprotect_rtcp(B, C)),
            V2 = <<2:2, (rand:uniform(64) - 1):6, B/binary>>,
            ?assertMatch({error, _}, ?S:unprotect(V2, C))
        end,
        lists:seq(1, 2000)
    ).

%% ---- MKI, lifetime, SSRCs (RFC 4568 6.1, 6.4.1) ----

mki_test() ->
    Snd = ?T:sender(libsrtp_master(), #{mki => <<0, 1>>}),
    Pkt = ?T:protect(rtp(10, 7, <<"x">>), 0, Snd),
    {ok, _, _} = ?S:unprotect(Pkt, ctx(#{mki => <<0, 1>>})),
    ?assertEqual({error, mki}, ?S:unprotect(Pkt, ctx(#{mki => <<0, 2>>}))),
    ?assertMatch({error, _}, ?S:unprotect(Pkt, ctx())).

lifetime_test() ->
    Snd = ?T:sender(libsrtp_master()),
    C0 = ctx(#{lifetime => 2}),
    {ok, _, C1} = ?S:unprotect(?T:protect(rtp(1, 7, <<"x">>), 0, Snd), C0),
    {ok, _, C2} = ?S:unprotect(?T:protect(rtp(2, 7, <<"x">>), 0, Snd), C1),
    ?assertEqual({error, expired}, ?S:unprotect(?T:protect(rtp(3, 7, <<"x">>), 0, Snd), C2)).

%% Late binding: an SSRC gets a context only once its packet authenticates,
%% and a context holds max_ssrcs of them.
ssrcs_test() ->
    Snd = ?T:sender(libsrtp_master()),
    C0 = ctx(#{max_ssrcs => 2}),
    Forged = ?T:protect(rtp(1, 99, <<"x">>), 0, ?T:sender(?T:master())),
    ?assertEqual({error, auth}, ?S:unprotect(Forged, C0)),
    {ok, _, C1} = ?S:unprotect(?T:protect(rtp(1, 1, <<"x">>), 0, Snd), C0),
    {ok, _, C2} = ?S:unprotect(?T:protect(rtp(1, 2, <<"x">>), 0, Snd), C1),
    ?assertEqual({error, too_many_ssrcs}, ?S:unprotect(?T:protect(rtp(1, 3, <<"x">>), 0, Snd), C2)),
    {ok, _, _} = ?S:unprotect(?T:protect(rtp(2, 1, <<"x">>), 0, Snd), C2).

%% A new master key keeps the stream's index and replay list.
rekey_test() ->
    Old = libsrtp_master(),
    New = ?T:master(),
    {ok, _, C1} = ?S:unprotect(?T:protect(rtp(10, 7, <<"x">>), 0, ?T:sender(Old)), ctx()),
    C2 = ?S:rekey(C1, ctx(#{master => New})),
    {ok, _, C3} = ?S:unprotect(?T:protect(rtp(11, 7, <<"x">>), 0, ?T:sender(New)), C2),
    ?assertEqual({error, replay}, ?S:unprotect(?T:protect(rtp(11, 7, <<"x">>), 0, ?T:sender(New)), C3)),
    ?assertEqual({error, auth}, ?S:unprotect(?T:protect(rtp(12, 7, <<"x">>), 0, ?T:sender(Old)), C3)).

bad_options_test() ->
    <<K:16/binary, S:14/binary>> = libsrtp_master(),
    Base = #{suite => aes_cm_128_hmac_sha1_80, key => K, salt => S},
    [?assertEqual({error, badarg}, ?S:new(O)) || O <- [
        #{},
        Base#{suite => f8_128_hmac_sha1_80},
        Base#{key => <<K/binary, 0>>},
        Base#{salt => <<1>>},
        Base#{mki => <<>>},
        Base#{lifetime => 0},
        Base#{lifetime => 1 bsl 49},
        Base#{window => 63},
        Base#{window => 1 bsl 20},
        Base#{max_ssrcs => 0}
    ]].

%% ---- no key material out of the module ----

no_key_printed_test() ->
    Master = libsrtp_master(),
    <<K:16/binary, S:14/binary>> = Master,
    C = ctx(),
    Printed = iolist_to_binary(io_lib:format("~p ~w", [C, C])),
    Keys = maps:values(maps:remove(tag, maps:remove(mki, ?T:sender(Master)))),
    [?assertEqual(nomatch, binary:match(Printed, [hex(B), dec(B)])) || B <- [K, S | Keys]].

hex(B) -> binary:encode_hex(B, lowercase).

%% the way ~p and ~w print a binary: its first octets as integers
dec(<<A, B, C, _/binary>>) ->
    iolist_to_binary(io_lib:format("~b,~b,~b", [A, B, C])).

is_rtcp_test() ->
    ?assert(?S:is_rtcp(h(<<"81c8000bcafebabe">>))),
    ?assert(?S:is_rtcp(<<16#80, 223, 0, 0>>)),
    ?assertNot(?S:is_rtcp(rtp(1, 2, <<>>))),
    ?assertNot(?S:is_rtcp(<<16#80, 224>>)),
    ?assertNot(?S:is_rtcp(<<>>)).
