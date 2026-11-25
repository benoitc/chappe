%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The format facts of a room's audio, in one place: how many samples a
%% 20 ms frame holds at a rate, how many octets a sample takes in a payload,
%% what silence is, which payload type a format goes on, and a payload as
%% 16-bit PCM.
%%
%% A room has one rate, fixed when it starts: 8000 (G.711, PCMU or PCMA, one
%% octet a sample, the byte mix of before) or 16000 (L16, RFC 3551 4.5.11:
%% 16-bit signed samples in network byte order, two octets a sample, on a
%% dynamic payload type). The mixer stays codec-free: rtpengine in front of
%% it turns whatever a caller speaks into the room's format.
-module(chappe_mix_fmt).

-export([frame/1, width/1, fill/1, pt/1, pcm/3]).

-export_type([rate/0, codec/0]).

%% the sample rates a room runs at
-type rate() :: 8000 | 16000.
%% a leg's payload format: G.711 at 8 kHz, L16 at 16 kHz
-type codec() :: chappe_mix_g711:law() | l16.

%% Samples in a 20 ms frame (RFC 3551 4.2: the mixer sends 20 ms): 160 at
%% 8 kHz, 320 at 16 kHz. It is also the RTP timestamp step of a frame.
-spec frame(rate()) -> pos_integer().
frame(Rate) -> Rate div 50.

%% Octets per sample in a payload.
-spec width(codec()) -> 1 | 2.
width(l16) -> 2;
width(_Law) -> 1.

%% The octet whose repetition is silence: what fills a lost sample (one
%% octet for G.711, the two zero octets of an L16 sample).
-spec fill(codec()) -> byte().
fill(ulaw) -> 16#FF;
fill(alaw) -> 16#D5;
fill(l16) -> 0.

%% The payload type a format goes on unless the leg says otherwise: the
%% static ones of G.711 (RFC 3551 6), 96 for L16 at 16 kHz, which has no
%% static one (its static types 10 and 11 are 44.1 kHz).
-spec pt(codec()) -> 0..127.
pt(ulaw) -> 0;
pt(alaw) -> 8;
pt(l16) -> 96.

%% A payload as 16-bit signed little-endian PCM, one 20 ms frame of Frame
%% samples: a shorter payload is padded with silence, as the mix does
%% (chappe_mix_dsp), and an odd trailing L16 octet is dropped.
-spec pcm(codec(), pos_integer(), binary()) -> binary().
pcm(l16, Frame, Payload) ->
    Pcm = <<<<S:16/little-signed>> || <<S:16/big-signed>> <= Payload>>,
    pad(Pcm, Frame);
pcm(Law, Frame, Payload) ->
    pad(chappe_mix_g711:pcm(Law, Payload), Frame).

pad(Pcm, Frame) ->
    case Frame * 2 - byte_size(Pcm) of
        Pad when Pad > 0 -> <<Pcm/binary, 0:(Pad * 8)>>;
        _ -> Pcm
    end.
