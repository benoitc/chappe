%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% RTP packets (RFC 3550), as far as a mixer needs them.
%%
%% parse/1 is total: whatever a peer sends comes back as a map or as an
%% error value, never an exception. Header extensions and padding are
%% skipped to reach the payload. The mixer sends its own SSRC with a CSRC
%% list naming the sources in the mix (RFC 3550 7.1). RTCP arriving on the
%% RTP port (RFC 5761 multiplexing) is reported as such so the caller can
%% hand it to chappe_mix_rtcp.
-module(chappe_mix_rtp).

-export([parse/1, build/1, extend_seq/2]).

-export_type([packet/0]).

-type packet() :: #{
    pt := 0..127,
    seq := 0..65535,
    ts := 0..16#FFFFFFFF,
    ssrc := 0..16#FFFFFFFF,
    marker := boolean(),
    csrcs => [0..16#FFFFFFFF],
    payload := binary()
}.

-spec parse(binary()) -> {ok, packet()} | {error, malformed | rtcp}.
parse(<<2:2, _:6, B, _/binary>>) when B >= 192, B =< 223 ->
    %% RFC 5761 4: RTP payload types 64..95 are not used on a shared
    %% port, so a second octet of 192..223 (M and PT together) is RTCP:
    %% SR..APP (200..204) and the feedback and XR types around them
    {error, rtcp};
parse(
    <<2:2, P:1, X:1, CC:4, M:1, PT:7, Seq:16, TS:32, SSRC:32, Rest0/binary>>
) ->
    CsrcBytes = CC * 4,
    case Rest0 of
        <<Csrc:CsrcBytes/binary, Rest1/binary>> ->
            case skip_ext(X, Rest1) of
                {ok, Rest2} ->
                    case strip_padding(P, Rest2) of
                        {ok, Payload} ->
                            {ok, #{
                                pt => PT,
                                seq => Seq,
                                ts => TS,
                                ssrc => SSRC,
                                marker => M =:= 1,
                                csrcs => [C || <<C:32>> <= Csrc],
                                payload => Payload
                            }};
                        error ->
                            {error, malformed}
                    end;
                error ->
                    {error, malformed}
            end;
        _ ->
            {error, malformed}
    end;
parse(_) ->
    {error, malformed}.

%% At most 15 CSRCs fit in CC; the caller keeps the list that short.
-spec build(packet()) -> binary().
build(
    #{
        pt := PT, seq := Seq, ts := TS, ssrc := SSRC, marker := M, payload := P
    } = Pkt
) ->
    MBit =
        case M of
            true -> 1;
            false -> 0
        end,
    case maps:get(csrcs, Pkt, []) of
        [] ->
            <<2:2, 0:1, 0:1, 0:4, MBit:1, PT:7, Seq:16, TS:32, SSRC:32,
                P/binary>>;
        Csrcs ->
            CC = length(Csrcs),
            Csrc = <<<<C:32>> || C <- Csrcs>>,
            <<2:2, 0:1, 0:1, CC:4, MBit:1, PT:7, Seq:16, TS:32, SSRC:32,
                Csrc/binary, P/binary>>
    end.

%% Extend a 16-bit sequence number to the cycle closest to the last
%% extended one seen, so the wrap at 65535 is not a gap and a packet from
%% just before the wrap that arrives late is not a jump forward.
-spec extend_seq(0..65535, non_neg_integer() | undefined) -> integer().
extend_seq(Seq, undefined) ->
    Seq;
extend_seq(Seq, Last) ->
    Cand = (Last band (bnot 16#FFFF)) bor Seq,
    nearest(Cand, Last).

nearest(Cand, Last) when Cand - Last > 32768 -> Cand - 65536;
nearest(Cand, Last) when Last - Cand > 32768 -> Cand + 65536;
nearest(Cand, _Last) -> Cand.

%% ---- internal ----

skip_ext(0, Bin) ->
    {ok, Bin};
skip_ext(1, <<_Profile:16, Len:16, Rest/binary>>) ->
    Bytes = Len * 4,
    case Rest of
        <<_:Bytes/binary, Rest1/binary>> -> {ok, Rest1};
        _ -> error
    end;
skip_ext(1, _) ->
    error.

strip_padding(0, Bin) ->
    {ok, Bin};
strip_padding(1, <<>>) ->
    error;
strip_padding(1, Bin) ->
    Pad = binary:last(Bin),
    Size = byte_size(Bin) - Pad,
    case Pad > 0 andalso Size >= 0 of
        true -> {ok, binary:part(Bin, 0, Size)};
        false -> error
    end.
