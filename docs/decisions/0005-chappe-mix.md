# 0005: chappe_mix exists next to FreeSWITCH conferences

This record explains why the umbrella has its own RTP conference mixer when
FreeSWITCH's `mod_conference` is available, and what the measurements
behind it show. Read it before you choose a conference backend, or before
you change the mixer's timing, mix or send path.

## Status

Accepted (the maintainer's decision, 2026-11-17).

## Context

What the repository shows, all in the mixer's lab notebooks:

- [PERF.md](../../apps/chappe_mix/test/audit/PERF.md) writes thresholds
  before the code and records each run against them, beside a native
  `mod_conference` reference (FreeSWITCH 1.10.10 on the same box, judged by
  the same Goertzel tones). From its "Thresholds" table, quiet-box numbers:

  | Measure | mod_conference | chappe_mix |
  |---|---|---|
  | Latency added, p50 / p99 | 41.1 / 45.9 ms | 9.3 / 10.6 ms |
  | 4-party rooms on one CPU, every tick in budget | 75 | 275 |
  | Memory per 4-party room | 2.9 to 3.0 MiB | 65 to 80 KiB |
  | Mix correctness | every tone, own tone <= -54.7 dBFS | the same, to 0.01 dB |

  Two rows are recorded as missed: mix compute per tick at 4 / 64 legs, and
  the 500-conference capacity target.
- [ATTEMPTS.md](../../apps/chappe_mix/test/audit/ATTEMPTS.md), "rtpengine as
  the mixer: not on Ubuntu 24.04": rtpengine 11.5 cannot do an N-1 mix; 26.x
  can, with no gain control. Verdict there: "a usable fallback only if we
  ship rtpengine 26.x ourselves".
- ATTEMPTS.md, "A NIF for the mix: not written": a mix that costs nothing
  would reach about 410 conferences, short of 500, so the C was not worth
  its crash radius.
- The mixer gives per-pair relations (`chappe_mix:relate/4`), talker events
  and per-leg direction, used by `chappe_mrf_conf` for mute, deaf and talker
  events (`apps/chappe_mrf/src/chappe_mrf_conf.erl`, moduledoc).
- chappe_mrf keeps both backends: `native` (chappe_mix) and `fs`
  (`mod_conference`) (`chappe_mrf_conf`).

## Decision

Conferences run on chappe_mix by default (`conference` routes to `mix` in
`chappe_sip_media`, `native` is the default backend of `chappe_mrf_conf`).
`mod_conference` stays available through chappe_mrf's `fs` backend.
chappe_mix mixes G.711 only, one process per room, with rtpengine in front
for every other codec and for SRTP.

## Consequences

- A conference needs no FreeSWITCH, and its rooms live in the Erlang node.
- The mixer's performance claims must cite `PERF.md`, and every change to
  the mix, the clock or the send path is measured there first
  (`AGENTS.md`, "Measure before you claim").
- Codecs other than G.711 cost an rtpengine transcode on each leg.
- Features `mod_conference` has and chappe_mix lacks are reached through
  the `fs` backend.

## Open questions

None.
