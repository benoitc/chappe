%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The sending side of SRTP and SRTCP (RFC 3711), for tests only: chappe
%% never sends SRTP. Written apart from chappe_sip_srtp on purpose (AES in
%% ECB mode block by block, the HMAC truncated by hand), so a test that
%% decrypts what this encrypts checks two readings of the RFC against each
%% other; the RFC 3711 Appendix B vectors anchor both.
-module(chappe_sip_test_srtp).

-export([sender/1, sender/2, protect/3, protect_rtcp/3, master/0, inline/1]).

%% A random master key and salt, 30 octets, as an a=crypto line carries.
master() -> crypto:strong_rand_bytes(30).

%% the inline key of an a=crypto line
inline(Master) -> base64:encode(Master).

%% A sender of AES_CM_128_HMAC_SHA1_80 (or _32 with tag => 4) keyed by
%% Master (16 octets of key, 14 of salt).
sender(Master) -> sender(Master, #{}).

sender(<<Key:16/binary, Salt:14/binary>>, Opts) ->
    #{
        tag => maps:get(tag, Opts, 10),
        mki => maps:get(mki, Opts, <<>>),
        rtp_enc => prf(Key, Salt, 0, 16),
        rtp_auth => prf(Key, Salt, 1, 20),
        rtp_salt => prf(Key, Salt, 2, 14),
        rtcp_enc => prf(Key, Salt, 3, 16),
        rtcp_auth => prf(Key, Salt, 4, 20),
        rtcp_salt => prf(Key, Salt, 5, 14)
    }.

%% An RTP packet (no CSRC, no extension unless given) protected at
%% rollover counter Roc.
protect(<<_:16, Seq:16, _:32, Ssrc:32, _/binary>> = Rtp, Roc, S) ->
    HL = hdr_len(Rtp),
    <<Hdr:HL/binary, Payload/binary>> = Rtp,
    #{rtp_enc := K, rtp_salt := Salt, rtp_auth := A, tag := T, mki := Mki} = S,
    Enc = xor_ks(K, iv(Salt, Ssrc, (Roc bsl 16) + Seq), Payload),
    Tag = trunc(crypto:mac(hmac, sha, A, <<Hdr/binary, Enc/binary, Roc:32>>), T),
    <<Hdr/binary, Enc/binary, Mki/binary, Tag/binary>>.

%% An RTCP compound packet protected with SRTCP index Index, E set.
protect_rtcp(<<First:8/binary, Rest/binary>>, Index, S) ->
    <<_:32, Ssrc:32>> = First,
    #{rtcp_enc := K, rtcp_salt := Salt, rtcp_auth := A, mki := Mki} = S,
    Enc = xor_ks(K, iv(Salt, Ssrc, Index), Rest),
    Body = <<First/binary, Enc/binary, 1:1, Index:31>>,
    Tag = trunc(crypto:mac(hmac, sha, A, Body), 10),
    <<Body/binary, Mki/binary, Tag/binary>>.

hdr_len(<<_:3, 0:1, CC:4, _/binary>>) ->
    12 + CC * 4;
hdr_len(<<_:3, 1:1, CC:4, _/binary>> = P) ->
    Off = 12 + CC * 4,
    <<_:Off/binary, _:16, Len:16, _/binary>> = P,
    Off + 4 + Len * 4.

%% IV = (k_s * 2^16) XOR (SSRC * 2^64) XOR (i * 2^16), as octets
iv(Salt, Ssrc, Index) ->
    <<S:128>> = <<Salt/binary, 0:16>>,
    <<I:128>> = <<0:32, Ssrc:32, 0:64>>,
    <<J:128>> = <<0:64, Index:48, 0:16>>,
    S bxor I bxor J.

%% the keystream, block by block: E(k, IV + n)
xor_ks(K, Iv, Data) ->
    N = (byte_size(Data) + 15) div 16,
    Ks = <<
        <<(crypto:crypto_one_time(aes_128_ecb, K, <<((Iv + B) rem (1 bsl 128)):128>>, true))/binary>>
     || B <- lists:seq(0, N - 1)
    >>,
    crypto:exor(Data, binary:part(Ks, 0, byte_size(Data))).

%% RFC 3711 4.3.3: PRF_n(k_master, x) = AES-CM keystream at x * 2^16
prf(Key, Salt, Label, Len) ->
    <<X:112>> = crypto:exor(Salt, <<0:56, Label:8, 0:48>>),
    xor_ks(Key, X bsl 16, <<0:(Len * 8)>>).

trunc(Mac, N) -> binary:part(Mac, 0, N).
