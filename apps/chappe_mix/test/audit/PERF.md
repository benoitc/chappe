# chappe_mix performance record

Every performance claim about chappe_mix cites this page, and it is updated in
the same commit as the change it describes. The thresholds were written in
the plan before the mixer existed. A threshold that is missed is recorded as
missed here, never redefined after the numbers arrive.

## Thresholds

| Measure | Threshold | Reference (mod_conference) | chappe_mix | Status |
| --- | --- | ---: | ---: | --- |
| Mixer latency added, RTP in to mixed RTP out, p50 / p99 | <= 25 ms / <= 45 ms, and <= reference + 10 ms | 41.1 / 45.9 ms | 9.3 / 10.6 ms (every one of 5 reruns <= 11.3 / 31.0 ms); 16.3 / 22.9 ms beside the reference | met |
| Tick jitter at 20 ms ptime, p99 | <= 2 ms idle, <= 5 ms at capacity | n/a | 0.06 ms idle, < 0.5 ms at 100 conferences | met |
| Capacity, 4-party PCMU conferences, one scheduler, every tick in budget | >= 100 conferences (400 legs), and >= reference per core | 75 rooms on one CPU | 275 conferences; 300 rooms by the reference's judge | met |
| Memory per 4-party conference | <= 256 KiB | 2.9 to 3.0 MiB per room | 65 to 80 KiB (137 to 148 KiB of VM growth) | met |
| Mix correctness: each receiver detects every other tone, own tone >= 40 dB down | same detection result as the reference | every tone, own <= -54.7 dBFS | the same, to 0.01 dB | met |
| 5% random loss on one leg | no crash, other legs keep their thresholds | n/a | no crash; probe 9.5 / 9.6 ms, every one of 5 reruns <= 12.9 ms p99 | met |
| Mix compute per tick, 4 / 64 legs (`mix_cost`), set 2026-10-02 | <= 10 us / <= 200 us | n/a | 19.8 / 331.9 us | missed |
| Capacity as above, set 2026-10-02 | >= 500 conferences (2000 legs) | n/a | 275 | missed |
| Mixed output after a change to the mix | byte for byte the same as before it for the same input | n/a | the same, 500 seeded rooms of 1 to 64 legs | met |
| Framing, 30 ms sender, set 2026-10-03 | its tone present in every 200 ms judging window at each listener, and no run of 80 or more silent samples (10 ms) inside any 20 ms frame heard once the room has settled | n/a | not measured yet | open |
| Framing, 10 ms sender, set 2026-10-03 | the same as the 30 ms row, and no jitter-buffer trim (`dropped` 0) on its leg over 60 s | n/a | not measured yet | open |
| Limiter, distortion, set 2026-10-03 | 8 talkers at -6 dBFS each (distinct tones): THD+N at a receiver <= -26 dB (5%); the hard clip it replaces is measured first, as the baseline | n/a | -10.67 dB (hard clip -10.19 dB) | missed |
| Limiter, cost, set 2026-10-03 | `mix_cost` at 4 and 64 legs rises by no more than 10% | n/a | not measured yet | open |
| Tick timer, set 2026-10-03 | ticks that fire more than 100 us early: none at p99 (under 1% of traced ticks), in the `jitter idle` and `jitter capacity` arms, with p99 lateness inside the tick jitter row | n/a | not measured yet | open |
| Prefill, set 2026-10-03 | `latency` arm: p99 within one frame (20 ms) of p50 in 5 of 5 launches; `loss` arm: the underrun count does not rise | n/a | not measured yet | open |
| DTMF forwarding (RFC 4733), set 2026-10-03 | a forwarded event keeps its event code, duration and E bit, and leaves within one tick (20 ms) of arriving | n/a | not measured yet | open |
| Per-pair relations, cost, set 2026-10-03 | `mix_cost` at 4 and 64 legs with no relation set rises by no more than 5%; the cost of each exclusion is measured and recorded | n/a | not measured yet | open |
| Talker events, latency, set 2026-10-03 | `{talking, Leg, true}` within 100 ms of the first loud frame entering the mix (60 ms hysteresis plus up to two ticks), `false` within 340 ms of the last one (300 ms plus two ticks), at the defaults | n/a | not measured yet | open |
| Talker events, cost, set 2026-10-03 | `mix_cost` at 4 and 64 legs with a subscriber set rises by no more than 5% | n/a | not measured yet | open |

The numbers in the table are the quiet-box ones from "2026-10-01: native
reference" below, minimum of the runs unless that section says otherwise.
"Void only", in older sections, means the arm ran end to end on a loaded
box: the number exists, and it cannot pass or fail a threshold.

## How to measure

Check the load average first (`uptime`); a busy box makes every number here
meaningless. Interleave runs of the two sides so a change in load lands on
both, run each arm at least five times, and keep the minimum. The arms live in
`apps/chappe_mix/bench/`.

## Results

### 2026-09-23: void, load 18 to 174

Every number in this section is **void**. The box was running unrelated
CPU-bound processes the whole time; the 1-minute load average is given for
each run, next to a limit of 3.5 (a quarter of 14 CPUs). They are recorded
to show the arms run and what they report, and as a first shape to check
against on a quiet box. None of them marks a threshold met or missed.

```
uptime: 21:44  up 4 days, 19:48, 24 users, load averages: 19.84 34.98 40.34
uptime: 21:45  up 4 days, 19:49, 24 users, load averages: 23.96 31.92 38.58
uptime: 21:47  up 4 days, 19:51, 24 users, load averages: 25.60 30.18 37.23
uptime: 22:04  up 4 days, 20:08, 24 users, load averages: 174.36 92.61 72.44
uptime: 22:12  up 4 days, 20:16, 27 users, load averages: 57.32 76.88 73.52
uptime: 22:12  up 4 days, 20:16, 27 users, load averages: 47.53 73.39 72.35
```

Box noise, `null` (void, load 19.8): empty fun 8.95 ns; bare 20 ms timers
late by 59 us p50, 198 us p99, 1471 us max over 250 ticks.

Compute of one tick, `mix_cost`, minimum of 5 rounds (void, load 19.4):

| legs | us per tick | us per leg | share of a 20 ms tick |
| ---: | ---: | ---: | ---: |
| 2 | 25.4 | 12.7 | 0.13% |
| 4 | 53.0 | 13.2 | 0.26% |
| 8 | 117.0 | 14.6 | 0.59% |
| 16 | 263.7 | 16.5 | 1.3% |
| 32 | 519.6 | 16.2 | 2.6% |
| 64 | 1062.6 | 16.6 | 5.3% |

Interleaved against `359a605` (5 launches each, void, load 140 to 174),
4 legs: 52.4 us before, 51.7 us after. The compute did not change; this run
checks the comparison procedure, not the mixer.

Latency, `latency 50` (void, load 57.3), 4 legs, probe in a peer node: 39 of
50 bursts heard, 11 missed; p50 52.5 ms, p99 386 ms. Tick-to-send (trace)
242 us p50, 728 us p99, 10.8 ms max. The jitter buffers dropped 928 of 4034
frames received and every leg's prefill had grown to 2: a bursting sender
overflows the depth of 3 and the single-frame burst is dropped with it,
which is what the missed bursts are. (Earlier latency runs, before the probe
tagged its bursts, are not recorded: see `ATTEMPTS.md`.)

Jitter (void):

| run | load | ticks | overruns | p99 bucket | traced p99 | traced max | tick-to-send p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| idle, 1 conference, 10 s | 18.3 | 500 | 0 | < 1 ms | 569 us | 1965 us | 793 us |
| 100 conferences, 10 s | 21.6 | 50021 | 0 | < 2 ms | 558 us | 2552 us | 6967 us |

In both runs over 94% of traced ticks fired **early**, by up to 1 ms (p50
-73 us idle, -487 us at 100 conferences): the timer is armed at millisecond
resolution, truncated. The mixer's own histogram clamps early to zero, so it
cannot show this; the trace can.

Capacity, `capacity 25 3 400` (void, load 23.8): in budget at 125
conferences (500 legs), scheduler utilisation 0.40; 150 conferences had 11
overruns and a p99 bucket of 20 ms. A run a minute earlier (load 24.0) held
100 and failed at 125 (p99 bucket 10 ms). Memory at 125 conferences:
137 KiB per conference in the VM (process plus its four sockets' port
memory), 247 KiB per conference of total VM growth, and a kernel buffer
ceiling of 3.0 MiB per conference (four sockets' default recbuf plus
sndbuf, allowed, not used).

Reference, what each party hears, `ref_latency` (void, load 25.6;
FreeSWITCH 1.10.12 amd64 emulated on arm64, so its timing is doubly void):

| receiver | chappe_mix, others / own (dBFS) | mod_conference, others / own (dBFS) |
| --- | --- | --- |
| 440 Hz | -15.0 -15.1 / -81.4 | -18.2 -18.2 / -100.8 |
| 1100 Hz | -15.1 -15.1 / -60.9 | -21.1 -18.3 / -63.7 |
| 1700 Hz | -15.1 -15.1 / -73.5 | -21.0 -18.3 / -75.8 |

Levels are over the whole 2 s record. mod_conference delivered about 25100
samples in a 2 s window against 16160 for chappe_mix: the emulated reference
sends in bursts, and its gaps are why its tones read lower. That run still
used 440 Hz, which the arm and the suite have since dropped (see
`ATTEMPTS.md`).

Reference latency, `ref_latency 5 30` with tagged bursts (void, load 47.5):

| mixer | p50, min of 5 rounds | p99, min of 5 rounds | missed per round (of 30) |
| --- | ---: | ---: | --- |
| chappe_mix | 59.1 ms | 59.2 ms | 5 to 15 |
| mod_conference | 55.4 ms | 100.1 ms | 12 to 29 |

With that many bursts missed, a round's p99 can rest on one sample (the
reference's 100.1 ms comes from a round that heard 1 of 30), so the minimum
of p99 says little here. chappe_mix's p50 sat at 59.1 to 59.2 ms in every
round, which is three frames: consistent with a prefill of 2 plus the tick
phase, and worth checking first on a quiet box.

Correctness, the one row that does not depend on timing: with
`chappe_mix_ref_SUITE` in its final form (tones at 1100, 1700 and 2300 Hz,
steady-state wait), both mixers gave the same detection result (every
receiver hears the other two, own tone under -54.7 dBFS) in 2 of 4 runs.
The other two failed on chappe_mix's side at loads 102 and 108 for presence
(tones in 1 of 10 windows, no leak), while mod_conference fed by the same
senders passed. A passing run at load 121 had 23 to 25 of 131 frames per
chappe_mix leg trimmed by the jitter buffer, so a buffer of depth 3 against
senders the load makes burst is the likely cause. This is not a threshold result
either: the reference is emulated and the box was loaded.

Behind a real rtpengine (`chappe_mix_live_SUITE`, rtpengine 11.5 from Ubuntu
24.04, PCMU, PCMA and an opus hop): N-1 held in 3 of 4 runs at loads 107 to
143; the first failed for presence (tones in 6 of 10 windows, no leak) while
the image was building next to it.

Loss, `loss 30 2` (void, load 23.0), 4 legs, two of them carrying a tone
with 5% random loss: no crash; 23 of 30 probe bursts heard, p50 54.9 ms,
p99 323 ms; 46 frames counted lost, 561 trimmed by the jitter buffers.
The probe's p50 matches the lossless `latency` run at a similar load, so
loss on other legs does not show here; the loaded box does.

### 2026-09-24: RFC 3550 mixer rules, void, load 10 to 13

The tick now builds a CSRC list per leg and checks, per leg, whether an
RTCP report is due; reports (every 2 to 6 s per leg) are sent after the
tick's trace message, so they do not count in tick-to-send. With the
default `rtcp => mux` a leg still owns one socket, so the memory row is
unchanged in kind; `rtcp => pair` adds a second socket per leg and is not
measured.

`mix_cost 4 64`, interleaved against `2ee8b11` (5 launches each, `+S 1`,
void), minimum of the five:

| legs | before, us per tick | after, us per tick |
| ---: | ---: | ---: |
| 4 | 29.63 | 29.91 |
| 64 | 611.5 | 635.3 |

About 4% more at 64 legs, where every listener's list is capped at 15; no
threshold is claimed from it. The latency, jitter and capacity arms were not
rerun on this change.

### 2026-10-01: native reference, quiet box

FreeSWITCH 1.10.10 `mod_conference` native on arm64 (`interop/freeswitch`,
`drachtio/drachtio-freeswitch-mrf`, one CPU), on the same 14-CPU box as
chappe_mix, OrbStack's Linux VM. Arms ran from 23:50 to 02:49 under
`ref.sh`, interleaved round by round, each refusing above a 1-minute load of
3.5; the 5- and 15-minute averages were higher (4 to 14) because the box
went quiet between bursts of unrelated work. From 03:07 the load stayed
between 8 and 39 for over an hour, so round 5 and a second set of
`ref_capacity` runs were not taken.

Where each side ran:

- `host`: the arm on macOS with `+S 1`; FreeSWITCH reached through its
  published ports, so its packets also cross the host-to-VM hop.
- `vm`: the arm in an `erlang:29` container on FreeSWITCH's docker network,
  `+S 1`. Both mixers in the same VM; chappe_mix on loopback, FreeSWITCH
  over the docker bridge. The arm checks the VM's load (0.0 to 0.7 for
  every vm run) and `ref.sh` checks the host's (given below).

Only `vm` numbers compare the two mixers under shared conditions. The
chappe_mix-only arms ran on the host.

Box noise, `null` (host, 4 runs, load 2.53 to 3.10): bare 20 ms timers
late by 59 to 267 us p50, 124 to 1047 us p99. The quietest (load 2.53):
59 / 124 / 376 us p50 / p99 / max.

Compute, `mix_cost` (host, 4 runs, load 2.33 to 3.03), minimum: 27.79 us
per tick for 4 legs (0.14% of a tick), 604.67 us for 64 legs (3.0%). The
four runs stay within 2%.

Reference latency, `ref_latency 5 50` (5 interleaved rounds of 50 bursts
per launch, every burst heard in every round):

| run | load (host / VM) | chappe_mix p50 / p99, min | mod_conference p50 / p99, min |
| --- | --- | ---: | ---: |
| host, 23:50 | 2.84 / | 19.4 / 19.8 ms | 39.5 / 45.2 ms |
| vm, 23:58 | 2.90 / 0.19 | 16.3 / 22.9 ms | 41.1 / 45.9 ms |
| host, 02:06 | 2.65 / | 18.5 / 18.9 ms | 40.8 / 46.7 ms |

In `ref_latency` the probe shares the node with chappe_mix. mod_conference's
p50 sat at 39 to 43 ms in most rounds and near 60 ms in two (one more
frame), its p99 at 45 to 86 ms. The host-to-VM hop does not show: the host
and vm reference numbers are within 2 ms.

What each party hears, `ref_tones` (3 runs): both mixers gave every
receiver the other two tones at -14.7 dBFS and its own at -54.7 (1100 Hz),
-64.5 (1700 Hz) and -100.9 dBFS (2300 Hz), the same to 0.01 dB in every
run. The own-tone floor is the Goertzel judge's leakage, not the mix.
`chappe_mix_ref_SUITE` passed 5 times against this reference (load 2.8 to
10.9; correctness only, no timing asserted).

chappe_mix latency, `latency 100` (host, probe in a peer node, 4 legs):

| load | p50 | p99 | max | tick-to-send p99 | max prefill |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2.94 | 16.6 ms | 17.2 ms | 17.6 ms | 1.3 ms | 1 |
| 2.22 | 32.0 ms | 33.2 ms | 34.8 ms | 1.7 ms | 2 |
| 2.71 | 16.0 ms | 18.1 ms | 20.9 ms | 2.5 ms | 1 |
| 2.94 | 9.3 ms | 10.6 ms | 11.3 ms | 1.5 ms | 1 |

Minimum 9.3 / 10.6 ms. The p50 moves by whole frames between launches,
with the phase of the tick against the probe's sends and the prefill: the
run whose prefill had grown to 2 is the 32 ms one. Every launch is inside
25 / 45 ms.

Tick jitter (host):

| run | load | ticks | overruns | p99 bucket | traced p99 | traced max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| idle, 30 s | 3.02 | 1500 | 0 | < 0.5 ms | 62 us | 3517 us |
| idle, 30 s | 3.05 | 1500 | 0 | < 0.5 ms | -764 us | 3804 us |
| idle, 30 s | 2.65 | 1500 | 0 | < 2 ms | 1113 us | 6195 us |
| idle, 30 s | 2.06 | 1499 | 1 | < 2 ms | 1286 us | 30039 us |
| 100 conferences, 30 s | 2.82 | 150011 | 0 | < 0.5 ms | -348 us | 695 us |
| 100 conferences, 30 s | 2.63 | 150011 | 0 | < 0.5 ms | -769 us | -727 us |

Every run is inside 2 ms idle and 5 ms at capacity at p99; the one overrun
is a tick 30 ms late, in the run at load 2.06. Two
capacity runs only: the other launches waited out their 20 minutes for the
load.

Capacity, `capacity 25 5 1000` (host, `+S 1`):

| load | in budget | sched util | VM bytes per conf | VM growth per conf |
| ---: | ---: | ---: | ---: | ---: |
| 2.85 | 275 | 0.48 | 100.6 KiB | 152.8 KiB |
| 3.16 | 275 | 0.48 | 101.9 KiB | 149.1 KiB |
| 3.13 | 200 | 0.40 | 87.7 KiB | 150.2 KiB |
| 2.70 | 275 | 0.48 | 101.0 KiB | 154.2 KiB |

The kernel buffer ceiling stays 3.0 MiB per conference (allowed, not used).

Capacity against the reference, `ref_capacity 25 20 1000` (vm, rooms of 4
PCMU legs fed a tone, a fresh probe room of 20 bursts at each step;
mod_conference limited to one CPU, chappe_mix on one scheduler). The first
run of each used an earlier judge (see `ATTEMPTS.md`); its step lines are
re-judged here with the one in the arm now:

| mixer | load (host) | in budget | CPU at that step | p50 / p99 there | memory per room | first step out |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| chappe_mix | 3.04 | 300 | 74% | 17.6 / 19.3 ms | 125 KiB | 325: p99 20.7 ms over p50, B got 97% |
| chappe_mix | 2.81 | 275 | 72% | 17.4 / 21.5 ms | 125 KiB | 300: one burst 20.6 ms over p50 |
| chappe_mix | 2.48 | 25 | 28% | 18.8 / 20.7 ms | 151 KiB | 50: one burst 24 ms over p50, at 33% CPU |
| mod_conference | 3.00 | 25 | 59% | 25.9 / 29.5 ms | 3.0 MiB | 50: one burst 22 ms over p50 |
| mod_conference | 3.00 | 75 | 88% | 39.9 / 42.7 ms | (1.0 MiB, reused container) | 100: p99 165 ms, 92% CPU |
| mod_conference | 2.97 | 75 | 87% | 77.6 / 81.7 ms | 2.9 MiB | 100: p99 159 ms, 95% CPU |

A single late burst out of 20 ends a ramp, so a run that stops early at a
low CPU share says more about the box than the mixer; the best run of each
is 300 rooms against 75, four times the reference on one core. Where both
reached the step, chappe_mix used 49 to 50% of a core at 100 rooms and
mod_conference 87 to 95%. Memory per room is the container's growth
(`docker stats`) for mod_conference and `erlang:memory(total)` growth for
chappe_mix; the middle mod_conference run reused a container that had held
earlier runs' calls, so its figure is low.

Loss, `loss 100 2` (host, two of four legs with 5% random loss), every
burst heard, no crash in 4 runs:

| load | p50 | p99 | lost | trimmed |
| ---: | ---: | ---: | ---: | ---: |
| 3.14 | 12.3 ms | 13.6 ms | 172 | 0 |
| 2.57 | 12.4 ms | 53.0 ms | 210 | 5 |
| 2.72 | 23.3 ms | 25.4 ms | 212 | 2 |
| 3.09 | 47.4 ms | 50.2 ms | 187 | 1 |

The minimum (12.3 / 13.6 ms) keeps the latency thresholds; two of the four
night runs do not (p99 53.0 and 50.2 ms). The quieter rerun below has all
five launches inside them.

Rerun of `latency 100` and `loss 100 2` (host, 5 launches each,
interleaved, 07:12 to 07:31 the next morning, load 2.06 to 3.17 with the
5- and 15-minute averages at 3.3 to 4.7, quieter than the night run):

| launch | load | latency p50 / p99 | prefill | loss p50 / p99 | lost |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2.51 / 2.06 | 10.6 / 31.0 ms | 2 | 10.6 / 12.9 ms | 197 |
| 2 | 3.13 / 3.09 | 9.9 / 10.3 ms | 1 | 10.8 / 10.9 ms | 215 |
| 3 | 3.15 / 3.17 | 10.2 / 10.3 ms | 1 | 10.2 / 10.3 ms | 198 |
| 4 | 2.93 / 2.29 | 10.5 / 10.7 ms | 1 | 11.9 / 12.0 ms | 191 |
| 5 | 2.35 / 2.20 | 11.2 / 11.3 ms | 1 | 9.5 / 9.6 ms | 204 |

All ten launches are inside 25 / 45 ms, so the latency and loss rows hold
for every launch, not only the minimum. The p50 sat at 9.5 to 11.9 ms in
all ten; the whole-frame jumps of the night run (16 to 47 ms) did not come
back. The one outlying p99 (31.0 ms) is the launch whose jitter-buffer
prefill grew to 2; the 32 ms night run had the same. Prefill growth, not
the tick phase, is what moves the probe by a frame, which is the Planned
item on the prefill that only grows.

Comparison, the shared-conditions numbers (vm unless noted):

| | chappe_mix | mod_conference |
| --- | ---: | ---: |
| latency p50 / p99, min of 5 rounds | 16.3 / 22.9 ms | 41.1 / 45.9 ms |
| rooms of 4 in budget on one core, best run | 300 | 75 |
| CPU at 100 rooms | 49 to 50% | 87 to 95% |
| memory per room | 125 KiB | 2.9 to 3.0 MiB |
| what each party hears | other tones -14.7 dBFS, own gone | the same, to 0.01 dB |

Not measured: tick jitter has no reference counterpart (mod_conference
exposes no tick timing), and the loss row was not run against the
reference.

### 2026-10-02: where a tick goes (before `chappe_mix_dsp`)

The compute and capacity thresholds dated 2026-10-02 in the table were set
before this section and before any code, to decide whether denser mixing is
worth a NIF. Host, `+S 1`, OTP 29, mixer code at `1244d99`.

One tick split by part (a scratch module mirroring `chappe_mix_conf:mix/2`
and `chappe_mix_leg:pop/send` part by part, best of 5, sends to loopback
from one socket per leg; 3 runs at load 2.58 to 2.68, within 1% of each
other):

| part | 4 legs | share | 64 legs | share |
| --- | ---: | ---: | ---: | ---: |
| decode (code words to a list) | 6.2 us | 12% | 109 us | 12% |
| sum | 6.3 us | 12% | 152 us | 16% |
| subtract own | 8.7 us | 17% | 167 us | 18% |
| encode | 9.5 us | 19% | 170 us | 18% |
| RTP build | 0.8 us | 2% | 25 us | 3% |
| `gen_udp:send` | 19.5 us | 38% | 314 us | 34% |
| total | 51.0 us | | 936 us | |

The compute (decode to encode) is about 60% of what the tick does once it
has its frames, and the sends on macOS loopback are most of the rest. The
receive path (packets in, RTP parse, jitter buffer) is not in this split.

The capacity ceiling is the CPU. The `capacity` arm reported
`scheduler:utilization/1`'s `total`, which with `+S 1` averages the one
normal scheduler with the one idle dirty CPU scheduler: a process spinning
flat out reads 0.5 in it (checked: `normal` 100%, `total` 50.0%). Every
`sched_util` in the sections above is that total, so the 0.48 at 275
conferences was a scheduler about 96% busy, not half idle. The arm now
reports the normal schedulers' average; on the code before `chappe_mix_dsp`
it read 0.96 at its last step in budget (250 conferences, load 2.94).

How the scheduler sleeps does not move it: `capacity 25 5 1000` on the same
code, twice each, interleaved (load 2.58 to 3.16):

| flags | conferences in budget |
| --- | --- |
| default | 225, 225 |
| `+sbwt none` | 225, 250 |
| `+sbwt very_long` | 200, 250 |

### 2026-10-02: the mix on an atomics sum (`chappe_mix_dsp`)

The tick now decodes every talking leg straight into one sum, an atomics
array of 160 signed slots, and encodes each leg's output from the sum less
its own frame, decoded again from the code words it came in. No decoded
frame is kept as a list. Chosen from six representations measured side by
side (see `ATTEMPTS.md`). The mixed output is the same, byte for byte:
`chappe_mix_dsp_tests` checks it against the list mix it replaces.

Interleaved against `1244d99` (the mixer as `26d5536` has it; the same
arms copied into both trees, `+S 1`, host). `mix_cost 4 64`, 5 launches each, load 2.75 to 3.20:

| legs | before, us per tick | after, us per tick | change |
| ---: | ---: | ---: | ---: |
| 4 | 28.71 (28.71 to 30.84) | 19.79 (19.79 to 21.52) | -31% |
| 64 | 607.3 (607.3 to 661.0) | 331.9 (331.9 to 365.2) | -45% |

Minimum of 5, range in brackets. Both miss the compute thresholds (10 and
200 us).

`capacity 25 5 1000`, 5 launches each, interleaved, load 2.61 to 3.20:

| | before | after |
| --- | --- | --- |
| conferences in budget | 250, 175, 225, 275, 250 | 275, 275, 275, 275, 250 |
| VM bytes per conference | 88 to 99 KiB | 65 to 80 KiB |
| VM growth per conference | 149 to 177 KiB | 137 to 148 KiB |

The best launch of each is 275: at a 25-conference step the gain does not
show in the best run, only in the spread (median 250 before, 275 after;
one of 5 below 275 after, against 4 of 5 before). Three pairs at a 10
conference step were planned to resolve it; one before-launch read 250, one
after-launch stopped at 30 when the load rose to 14 during it, and the
other four gave up after 30 minutes above the load limit (load 9 to 27 from
09:53 to 11:00). The capacity threshold (500) is missed. The compute is
about 60% of a tick once the frames are in, before the receive path, so a
31% cut in it was never going to double the ceiling.

`chappe_mix_SUITE`, `chappe_mix_rfc_SUITE`, `chappe_mix_ref_SUITE` (against
`mod_conference`) and `chappe_mix_live_SUITE` (behind rtpengine, PCMA and
opus legs) pass on the new mix.

### 2026-10-02: what a faster mix could reach (the NIF question)

Before writing a NIF for the mix, its best case was measured: a scratch
build of `0ea59d9` whose `chappe_mix_dsp` adds nothing and returns a fixed
frame, so the mixing math costs nothing (`mix_cost` 0.91 us at 4 legs,
30.7 us at 64) while receiving, the jitter buffer, RTCP and sending are
unchanged. `capacity 10 5 600`, three rounds of the three builds,
interleaved, host, `+S 1`, load 2.21 to 3.18:

| build | in budget, scheduler busy at that step |
| --- | --- |
| list mix (`1244d99`) | 120 (0.53), 240 (0.94), 250 (0.97) |
| atomics mix (`0ea59d9`) | 240 (0.84), 310 (0.98), 180 (0.62) |
| no mixing math | 410 (0.93), 260 (0.58), 230 (0.58) |

A ramp that stops with the scheduler well under 0.9 stopped on a late
tick the box caused, not on the mixer; the runs that ran the scheduler
out place the ceilings at about 245, 310 and 410. A mix that costs
nothing reaches about 410 conferences: no NIF for the mix meets the 500
threshold, so none was written.

Where the rest goes, from `tprof` call time on the 300 conference
processes of the no-math build over 5 s (`jitter capacity 300 20`, load
6.2, void as numbers, kept for the shares):

| | share of the conferences' time |
| --- | ---: |
| `erts_internal:port_command/3` (the UDP send into the inet driver) | 33.7% |
| the rest of `gen_udp:send` (`do_sendto`, `getaddr` per packet, `port_get_data`, option encoding) | about 8% |
| receiving: RTP parse, latch, jitter buffer, RTCP statistics | about 15%, spread |

The next lever is the send path, not the mix.

### 2026-10-02: the send path

Three changes to how a leg sends, each a scratch build of `0cd3bb2` with
that one change, against the current mixer and the no-math build above.
A ramp proved too fragile on this box (one load spike ends it early: a
connected-socket ramp stopped at 10 conferences), so every build was held
at 200 conferences for 10 s and the mixer's scheduler read (`capacity 200
10 200`, host, `+S 1`). Every launch below: load 2.22 to 3.20, no tick
late except where noted, every packet sent and received.

| build | launches | scheduler busy at 200 | ceiling if it scales |
| --- | ---: | --- | ---: |
| current mixer, `gen_udp:send/4` | 6 | 0.68 to 0.71 | about 290 |
| E1: socket connected to the far end, `gen_udp:send/2` | 6 | 0.58 to 0.60 | about 340 |
| E2: `gen_udp` with `{inet_backend, socket}` | 5 | 0.68 to 0.73 | about 280 |
| E3: E2, sending with `socket:sendto/3` directly | 2 | 0.69, 0.77 (2 late ticks, load 3.1) | about 270 |
| no mixing math (from the section above) | 4 | 0.44 to 0.51 | about 420 |

Only E1 helps, by about 15%. None of them reaches the 500 threshold,
which stays missed. E3 has two launches only: the box stayed above the
limit for over 40 minutes after them and the session was stopped.

### 2026-10-02: the sum read out once, element/2 throughout (void so far)

`chappe_mix_dsp` now reads the atomics sum out into a tuple once per tick
(`mixed/1`) and encodes through a 65536-tuple per law (`chappe_mix_g711:
encoder/1`, 512 KiB each in `persistent_term`), appending to a binary:
every per-sample lookup is `element/2`. Output unchanged:
`chappe_mix_dsp_tests` passes and catches the same three mutations.

Scratch harness, compute only (decode, sum, subtract, encode; no RTP
build), best of 5, `+S 1`, load 3.97 to 4.17, so **void**, kept for the
order:

| legs | atomics sum (`0cd3bb2`) | + `element/2` encode | + sum read out once |
| ---: | ---: | ---: | ---: |
| 4 | 20.3 us | 14.3 us | 13.8 us |
| 16 | 83.2 us | 56.9 us | 46.4 us |
| 64 | 326.1 us | 227.1 us | 180.4 us |

Interleaved against `0cd3bb2` in the mixer, one round got through before
the load went back above the limit (load 2.94 to 3.19, host, `+S 1`):

| | `0cd3bb2` | `eba11e7` |
| --- | ---: | ---: |
| `mix_cost`, 4 legs | 21.29 us | 14.81 us |
| `mix_cost`, 64 legs | 362.8 us | 214.3 us |
| scheduler busy, 200 conferences held 10 s | 0.70 | 0.66 |

One launch each, so no minimum of five: no threshold changes status. The
compute thresholds (10 and 200 us) stay missed; 64 legs is within 8%. The
whole mixer gains less than the compute (6% at 200 conferences): the send
path is the larger share now.

### 2026-10-03: Step 3 thresholds (no code yet)

The rows dated 2026-10-03 in the table were written before any of the code
they judge: 10 and 30 ms framing, the soft limiter, the tick timer and the
prefill, RFC 4733 event forwarding, per-pair relations and talker events.
How each is measured:

- Framing: a tone endpoint sending 30 ms (240 octets) or 10 ms (80 octets)
  packets into a room with two 20 ms parties. Every 200 ms window at the
  other parties carries its tone (`chappe_mix_test_tone:hears/3`), and each
  160-sample frame they receive is scanned for a run of 80 or more samples
  at the law's silence value. The 10 ms row also reads the sender leg's
  `dropped` after 60 s.
- Limiter: THD+N at one receiver of a room of 9, eight talkers on distinct
  tones at -6 dBFS each: the power left after removing the eight tone bins,
  over the power of the eight tones, on 1 s of received audio. The hard
  clip is measured on the commit before the limiter.
- Timer: the traced conference of the `jitter` arms reports `early_ticks`
  and `late_p50_us`; the row reads the share of traced ticks earlier than
  -100 us.
- Prefill: the `latency` and `loss` arms, 5 interleaved launches each, both
  ways; the underrun count is a new leg counter, `underruns`.
- DTMF: a suite case timestamps each event packet sent into a leg and each
  forward read at another leg, on loopback.
- Talker events: a suite case timestamps the first loud frame it sends and
  the event the subscriber gets.

R3550-21 (the mixer's own SSRC in the CSRC list when it is itself a
source) needs media the mixer injects. With input-only legs (Part B) the
room carries media of its own, so the row stays `platform` and is planned
there. The new RFC 4733 and RFC 3605 rows are `platform`: the demo flows
do not exercise them.
