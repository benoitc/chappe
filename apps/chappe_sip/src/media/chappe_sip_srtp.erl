%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Receive-only SRTP and SRTCP (RFC 3711): authenticate, check for
%% replay and decrypt the packets of one stream, for a process of chappe
%% that receives media itself (the SIPREC recording server's streams,
%% chappe_sip_siprec_rtp). chappe never sends SRTP; media it relays stays
%% with rtpengine (docs/decisions/0009-srtp-in-erlang.md).
%%
%% Suites: AES_CM_128_HMAC_SHA1_80 and AES_CM_128_HMAC_SHA1_32 (RFC 4568
%% 6.2.1, 6.2.2): AES-128 in counter mode (RFC 3711 4.1.1), HMAC-SHA1
%% tags of 80 or 32 bits for SRTP and 80 bits for SRTCP (4.2.1), the
%% AES-CM key derivation with a key derivation rate of 0 (4.3), through
%% OTP crypto only.
%%
%% new/1 takes the master key and salt (as chappe_sip_sdes:select/1 reads
%% them) and gives a context; unprotect/2 and unprotect_rtcp/2 take a
%% packet and the context and give the plain packet and the next context,
%% or {error, Why} with the context unchanged. For each packet, in the
%% order of RFC 3711 3.3: the index is estimated from the stream's rollover
%% counter (3.3.1), checked against the replay window (3.3.2), the tag is
%% checked in constant time, and only then is the payload decrypted and
%% the context moved on. A stream's SSRC gets its context (late binding,
%% RFC 4568 6.4.1) only once a packet of it authenticates, and a context
%% holds at most max_ssrcs of them.
%%
%% Keys never leave this module: the context keeps them in a closure, so
%% printing a context, a crash report or sys:get_state/1 shows no key, and
%% every error is an atom.
-module(chappe_sip_srtp).

-export([new/1, rekey/2, unprotect/2, unprotect_rtcp/2, is_rtcp/1]).
-export([derive/4, crypt/5]).

-export_type([ctx/0, suite/0, reason/0]).

-type suite() :: aes_cm_128_hmac_sha1_80 | aes_cm_128_hmac_sha1_32.
-type reason() :: malformed | mki | replay | auth | expired | too_many_ssrcs.

-record(keys, {
    rtp_enc :: binary(),
    rtp_auth :: binary(),
    rtp_salt :: binary(),
    rtcp_enc :: binary(),
    rtcp_auth :: binary(),
    rtcp_salt :: binary()
}).

-record(ctx, {
    keys :: fun(() -> #keys{}),
    tag_len :: 4 | 10,
    mki = <<>> :: binary(),
    %% packets the master key may still protect, each of SRTP and SRTCP
    %% (RFC 4568 6.1)
    lifetime :: pos_integer(),
    rtp_used = 0 :: non_neg_integer(),
    rtcp_used = 0 :: non_neg_integer(),
    window :: pos_integer(),
    max_ssrcs :: pos_integer(),
    %% SSRC => {ROC, s_l, replay bitmap}, its bit 0 the highest index
    rtp = #{} :: #{
        non_neg_integer() => {non_neg_integer(), 0..65535, non_neg_integer()}
    },
    %% SSRC => {highest SRTCP index, replay bitmap}
    rtcp = #{} :: #{non_neg_integer() => {non_neg_integer(), non_neg_integer()}}
}).

-opaque ctx() :: #ctx{}.

%% RFC 3711 3.3.2: at least 64
-define(MIN_WINDOW, 64).
-define(DEFAULT_WINDOW, 128).
-define(MAX_WINDOW, 1024).
-define(DEFAULT_SSRCS, 4).
-define(SRTP_MAX, (1 bsl 48)).
-define(SRTCP_MAX, (1 bsl 31)).
-define(SRTCP_TAG, 10).

%% Opts: #{suite := suite(), key := <<_:128>>, salt := <<_:112>>, mki =>
%% binary() (the MKI each packet carries, 1 to 128 octets), lifetime =>
%% pos_integer() (default and at most 2^48), window => pos_integer()
%% (replay window, 64 to 1024, default 128), max_ssrcs => pos_integer()
%% (default 4)}.
-spec new(map()) -> {ok, ctx()} | {error, badarg}.
new(
    #{suite := Suite, key := <<_:16/binary>> = K, salt := <<_:14/binary>> = S} =
        Opts
) ->
    Mki = maps:get(mki, Opts, undefined),
    Life = maps:get(lifetime, Opts, ?SRTP_MAX),
    Window = maps:get(window, Opts, ?DEFAULT_WINDOW),
    Ssrcs = maps:get(max_ssrcs, Opts, ?DEFAULT_SSRCS),
    case
        tag_len(Suite) =/= error andalso valid_mki(Mki) andalso
            is_integer(Life) andalso Life > 0 andalso Life =< ?SRTP_MAX andalso
            is_integer(Window) andalso Window >= ?MIN_WINDOW andalso
            Window =< ?MAX_WINDOW andalso is_integer(Ssrcs) andalso Ssrcs > 0
    of
        true ->
            Keys = session_keys(K, S),
            {ok, #ctx{
                keys = fun() -> Keys end,
                tag_len = tag_len(Suite),
                mki = mki_bin(Mki),
                lifetime = Life,
                window = Window,
                max_ssrcs = Ssrcs
            }};
        false ->
            {error, badarg}
    end;
new(_) ->
    {error, badarg}.

%% A new master key for a context (a re-INVITE that changes the key): the
%% streams keep their rollover counters, indices and replay lists (RFC
%% 3711 3.3.1: the ROC MUST NOT be reset), the new key gets its lifetime.
-spec rekey(ctx(), ctx()) -> ctx().
rekey(#ctx{rtp = Rtp, rtcp = Rtcp}, #ctx{} = New) ->
    New#ctx{rtp = Rtp, rtcp = Rtcp}.

tag_len(aes_cm_128_hmac_sha1_80) -> 10;
tag_len(aes_cm_128_hmac_sha1_32) -> 4;
tag_len(_) -> error.

valid_mki(undefined) ->
    true;
valid_mki(M) ->
    is_binary(M) andalso byte_size(M) >= 1 andalso byte_size(M) =< 128.

mki_bin(undefined) -> <<>>;
mki_bin(M) -> M.

%% RFC 5761 4: on a multiplexed port, a packet whose second octet is 192
%% to 223 (RTCP SR 200, RR 201, ...) is RTCP.
-spec is_rtcp(binary()) -> boolean().
is_rtcp(<<_, B, _/binary>>) -> B >= 192 andalso B =< 223;
is_rtcp(_) -> false.

%% ---- SRTP ----

%% An SRTP packet to its RTP packet (RFC 3711 3.3, the receiver's steps).
-spec unprotect(binary(), ctx()) -> {ok, binary(), ctx()} | {error, reason()}.
unprotect(Packet, #ctx{} = C) ->
    case split_rtp(Packet, C) of
        {ok, Hdr, Enc, Mki, Tag, Seq, Ssrc} ->
            unprotect(Hdr, Enc, Mki, Tag, Seq, Ssrc, C);
        error ->
            {error, malformed}
    end.

unprotect(_Hdr, _Enc, Mki, _Tag, _Seq, _Ssrc, #ctx{mki = M}) when Mki =/= M ->
    {error, mki};
unprotect(_Hdr, _Enc, _Mki, _Tag, _Seq, _Ssrc, #ctx{rtp_used = U, lifetime = L}) when
    U >= L
->
    {error, expired};
unprotect(Hdr, Enc, _Mki, Tag, Seq, Ssrc, #ctx{rtp = Rtp, max_ssrcs = Max} = C) ->
    case maps:find(Ssrc, Rtp) of
        error when map_size(Rtp) >= Max ->
            {error, too_many_ssrcs};
        error ->
            %% the first packet of an SSRC: s_l is its SEQ, ROC 0 (3.3.1)
            accept(Hdr, Enc, Tag, Ssrc, 0, 0, Seq, {0, Seq, 0}, C);
        {ok, {Roc, Sl, Bits} = St} ->
            {V, Delta} = estimate(Roc, Sl, Seq),
            case replayed(Delta, Bits, C#ctx.window) of
                true -> {error, replay};
                false -> accept(Hdr, Enc, Tag, Ssrc, V, Delta, Seq, St, C)
            end
    end.

accept(
    Hdr, Enc, Tag, Ssrc, V, Delta, Seq, St, #ctx{keys = KF, tag_len = TL} = C
) ->
    K = KF(),
    Expected = tag(K#keys.rtp_auth, [Hdr, Enc, <<V:32>>], TL),
    case crypto:hash_equals(Expected, Tag) of
        true ->
            Index = (V bsl 16) bor Seq,
            Plain = crypt(K#keys.rtp_enc, K#keys.rtp_salt, Ssrc, Index, Enc),
            St1 = advance(St, V, Seq, Delta, C#ctx.window),
            {ok, <<Hdr/binary, Plain/binary>>, C#ctx{
                rtp = (C#ctx.rtp)#{Ssrc => St1},
                rtp_used = C#ctx.rtp_used + 1
            }};
        false ->
            {error, auth}
    end.

%% The header (RFC 3550 5.1: 12 octets, the CSRCs, the extension), the
%% encrypted portion, the MKI and the tag.
split_rtp(
    <<2:2, _P:1, X:1, CC:4, _M:1, _PT:7, Seq:16, _Ts:32, Ssrc:32, Rest/binary>> =
        Packet,
    #ctx{mki = Mki, tag_len = TL}
) ->
    case hdr_len(X, CC, Rest) of
        {ok, HL} ->
            ML = byte_size(Mki),
            EL = byte_size(Packet) - HL - ML - TL,
            case EL >= 0 of
                true ->
                    <<Hdr:HL/binary, Enc:EL/binary, M:ML/binary, Tag:TL/binary>> =
                        Packet,
                    {ok, Hdr, Enc, M, Tag, Seq, Ssrc};
                false ->
                    error
            end;
        error ->
            error
    end;
split_rtp(_Packet, _C) ->
    error.

hdr_len(X, CC, Rest) ->
    Csrc = CC * 4,
    case {X, Rest} of
        {0, <<_:Csrc/binary, _/binary>>} ->
            {ok, 12 + Csrc};
        {1, <<_:Csrc/binary, _Profile:16, Len:16, Ext/binary>>} when
            byte_size(Ext) >= Len * 4
        ->
            {ok, 12 + Csrc + 4 + Len * 4};
        _ ->
            error
    end.

%% RFC 3711 3.3.1 (Appendix A): v in {ROC-1, ROC, ROC+1} so that the index
%% is closest to 2^16 * ROC + s_l; Delta is how far past the highest index
%% the packet is (0 or less: behind it).
estimate(Roc, Sl, Seq) when Sl < 32768 ->
    case Seq - Sl > 32768 of
        true -> {(Roc - 1) band 16#FFFFFFFF, Seq - Sl - 65536};
        false -> {Roc, Seq - Sl}
    end;
estimate(Roc, Sl, Seq) ->
    case Sl - 32768 > Seq of
        true -> {(Roc + 1) band 16#FFFFFFFF, Seq + 65536 - Sl};
        false -> {Roc, Seq - Sl}
    end.

%% RFC 3711 3.3.2: a packet ahead of the window is new; inside it, new
%% only when its bit is clear; behind it, replayed.
replayed(Delta, _Bits, _W) when Delta > 0 -> false;
replayed(Delta, _Bits, W) when -Delta >= W -> true;
replayed(Delta, Bits, _W) -> Bits band (1 bsl -Delta) =/= 0.

%% after authentication (3.3.1, 3.3.2): the window moves ahead and the
%% packet's bit is set; v = ROC+1 moves the ROC, a SEQ past s_l moves s_l
advance({_Roc, _Sl, Bits}, V, Seq, Delta, W) when Delta > 0 ->
    {V, Seq, mask((Bits bsl Delta) bor 1, W)};
advance({Roc, Sl, Bits}, _V, _Seq, Delta, W) ->
    {Roc, Sl, mask(Bits bor (1 bsl -Delta), W)}.

%% ---- SRTCP ----

%% An SRTCP packet to its RTCP compound packet (RFC 3711 3.4).
-spec unprotect_rtcp(binary(), ctx()) ->
    {ok, binary(), ctx()} | {error, reason()}.
unprotect_rtcp(Packet, #ctx{mki = M} = C) ->
    ML = byte_size(M),
    case byte_size(Packet) - 8 - 4 - ML - ?SRTCP_TAG of
        RL when RL >= 0 ->
            <<Rtcp:(8 + RL)/binary, EI:4/binary, Mki:ML/binary,
                Tag:?SRTCP_TAG/binary>> =
                Packet,
            rtcp(Rtcp, EI, Mki, Tag, C);
        _ ->
            {error, malformed}
    end.

rtcp(<<V:2, _:30, _/binary>>, _EI, _Mki, _Tag, _C) when V =/= 2 ->
    {error, malformed};
rtcp(_Rtcp, _EI, Mki, _Tag, #ctx{mki = M}) when Mki =/= M ->
    {error, mki};
rtcp(_Rtcp, _EI, _Mki, _Tag, #ctx{rtcp_used = U, lifetime = L}) when
    U >= L; U >= ?SRTCP_MAX
->
    {error, expired};
rtcp(<<_:32, Ssrc:32, _/binary>> = Rtcp, <<E:1, Index:31>> = EI, _Mki, Tag, C) ->
    #ctx{rtcp = Ctxs, max_ssrcs = Max, window = W} = C,
    case maps:find(Ssrc, Ctxs) of
        error when map_size(Ctxs) >= Max ->
            {error, too_many_ssrcs};
        error ->
            rtcp_accept(Rtcp, EI, E, Index, Tag, Ssrc, {Index, 0}, 0, C);
        {ok, {High, Bits} = St} ->
            Delta = Index - High,
            case replayed(Delta, Bits, W) of
                true ->
                    {error, replay};
                false ->
                    rtcp_accept(Rtcp, EI, E, Index, Tag, Ssrc, St, Delta, C)
            end
    end.

%% RFC 4568 6.3.2: without UNENCRYPTED_SRTCP (not supported), every SRTCP
%% packet is encrypted, its E bit set.
rtcp_accept(_Rtcp, _EI, 0, _Index, _Tag, _Ssrc, _St, _Delta, _C) ->
    {error, malformed};
rtcp_accept(Rtcp, EI, 1, Index, Tag, Ssrc, St, Delta, #ctx{keys = KF} = C) ->
    K = KF(),
    case
        crypto:hash_equals(tag(K#keys.rtcp_auth, [Rtcp, EI], ?SRTCP_TAG), Tag)
    of
        true ->
            <<First:8/binary, Enc/binary>> = Rtcp,
            Plain = crypt(K#keys.rtcp_enc, K#keys.rtcp_salt, Ssrc, Index, Enc),
            St1 = rtcp_advance(St, Index, Delta, C#ctx.window),
            {ok, <<First/binary, Plain/binary>>, C#ctx{
                rtcp = (C#ctx.rtcp)#{Ssrc => St1},
                rtcp_used = C#ctx.rtcp_used + 1
            }};
        false ->
            {error, auth}
    end.

rtcp_advance({_High, Bits}, Index, Delta, W) when Delta > 0 ->
    {Index, mask((Bits bsl Delta) bor 1, W)};
rtcp_advance({High, Bits}, _Index, Delta, W) ->
    {High, mask(Bits bor (1 bsl -Delta), W)}.

%% ---- the transforms ----

mask(Bits, W) -> Bits band ((1 bsl W) - 1).

%% RFC 3711 4.2.1: HMAC-SHA1 truncated to the tag's length
tag(AuthKey, Data, Len) ->
    crypto:macN(hmac, sha, AuthKey, Data, Len).

%% RFC 3711 4.1.1: AES-CM, IV = (k_s * 2^16) XOR (SSRC * 2^64) XOR (i *
%% 2^16); the same keystream encrypts and decrypts.
-spec crypt(binary(), binary(), non_neg_integer(), non_neg_integer(), binary()) ->
    binary().
crypt(Key, <<Salt:112>>, Ssrc, Index, Data) ->
    Iv = (Salt bsl 16) bxor (Ssrc bsl 64) bxor (Index bsl 16),
    crypto:crypto_one_time(aes_128_ctr, Key, <<Iv:128>>, Data, true).

%% RFC 3711 4.3.1, 4.3.3: the session key or salt of Label, Len octets,
%% from the master key and salt, the key derivation rate 0 (r = 0).
-spec derive(binary(), binary(), 0..5, pos_integer()) -> binary().
derive(Master, <<Salt:112>>, Label, Len) ->
    X = Salt bxor (Label bsl 48),
    crypto:crypto_one_time(
        aes_128_ctr, Master, <<X:112, 0:16>>, <<0:(Len * 8)>>, true
    ).

session_keys(K, S) ->
    #keys{
        rtp_enc = derive(K, S, 0, 16),
        rtp_auth = derive(K, S, 1, 20),
        rtp_salt = derive(K, S, 2, 14),
        rtcp_enc = derive(K, S, 3, 16),
        rtcp_auth = derive(K, S, 4, 20),
        rtcp_salt = derive(K, S, 5, 14)
    }.
