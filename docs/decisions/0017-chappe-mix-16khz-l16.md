# 0017: a chappe_mix room runs at 8 or 16 kHz, on L16 at 16 kHz

This record explains how chappe_mix mixes wideband (HD) audio while it stays
codec-free, and what a room's rate fixes. Read it before you add a rate, a
codec, or a way to change a room's rate, or when you choose between a native
and an `fs` room for HD callers.

## Status

Accepted (the maintainer's decision, 2026-10-02 and 2026-11-24). Amends
[0005](0005-chappe-mix.md), whose mixer was G.711 only.

## Context

- Callers speak Opus, G.722, PCMU or PCMA. An 8 kHz G.711 room takes the
  band above 3.4 kHz away from every one of them, even when two HD phones
  talk.
- rtpengine already sits in front of every mixer leg to transcode and to
  terminate SRTP ([0004](0004-rtpengine-external.md)). From 13.x it has an
  L16 RTP codec: the lab's mr26.3.1.4 converts Opus and G.722 callers to and
  from `L16/16000` with `codec => #{mask => [<<"all">>], transcode =>
  [<<"L16/16000/1">>, <<"telephone-event/16000">>]}` on the offer
  toward the mixer (`apps/chappe_mix/test/audit/ATTEMPTS.md`, "the L16
  gate"). Ubuntu 24.04's 11.5 has no L16.
- The band check of the test tone helper (`chappe_mix_test_tone:band_check/3`)
  tells a 16 kHz path from one that went through 8 kHz: G.722 and Opus pjsua
  calls pass it, PCMU fails, and a FreeSWITCH `wideband` room passes it.
- The 8 kHz byte mix is measured and tuned (`PERF.md`); its bytes must not
  move.

## Decision

- The mixer stays codec-free. rtpengine converts every caller to and from
  the room's format.
- A room's rate is fixed when it starts: `rate => 8000` (default, the G.711
  byte mix, unchanged) or `rate => 16000` (every leg L16 at 16 kHz on a
  dynamic payload type, a linear mix). Any other value is
  `{error, {bad_option, rate}}`.
- The format facts of a rate live in one module, `chappe_mix_fmt`: samples
  per frame, octets per sample, silence, payload type, PCM.
- In `chappe_sip_media`, the join that creates a room sets its rate; a join
  asking another rate gets `{error, {rate_mismatch, Rate}}`.
  `chappe_sip_media:mixer_params/2` gives the rtpengine flags for each side.
- In chappe_mrf, a native room takes `rate => 16000`; an `fs` room refuses
  `rate` (`{error, {unsupported, rate}}`) and gets 16 kHz from its
  mod_conference profile (`profile => <<"wideband">>`).
- A 16 kHz room needs rtpengine 13.4 or later.

## Consequences

- An 8 kHz room is the mixer of before, byte for byte:
  `chappe_mix_golden_tests` pins a seeded digest taken on the G.711-only
  mixer.
- A 16 kHz room costs more per tick (twice the samples, two octets each)
  and more per leg in rtpengine (a transcode both ways for every caller,
  PCMU ones included). `PERF.md` has the thresholds (the rows set
  2026-11-24) and the first runs, void on a loaded box: the mix at 1.5 to
  1.8 times the 8 kHz one; the rest is to be measured on a quiet box.
- A PCMU caller in a 16 kHz room hears the HD parties through 8 kHz and is
  heard as 8 kHz audio; the others keep their band.
- A leg moves only between rooms of one rate.
- telephone-event runs at the room's clock: 8000 at 8 kHz, 16000 at 16 kHz.
- SIPREC of a 16 kHz room is refused for now (`{error, {unsupported,
  {rate, 16000}}}`).

## Open questions

- SIPREC of a 16 kHz room: L16 toward the recording server, or a transcode
  back to 8 kHz in rtpengine.
- Changing a room's rate while it runs (a room that starts at 8 kHz and
  moves up when the second HD caller joins).
- 48 kHz rooms (Opus fullband).
