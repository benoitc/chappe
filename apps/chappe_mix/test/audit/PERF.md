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
| Memory per 4-party conference | <= 256 KiB | 2.9 to 3.0 MiB per room | 101 KiB (153 KiB of VM growth) | met |
| Mix correctness: each receiver detects every other tone, own tone >= 40 dB down | same detection result as the reference | every tone, own <= -54.7 dBFS | the same, to 0.01 dB | met |
| 5% random loss on one leg | no crash, other legs keep their thresholds | n/a | no crash; probe 9.5 / 9.6 ms, every one of 5 reruns <= 12.9 ms p99 | met |
| Mix compute per tick, 4 / 64 legs (`mix_cost`), set 2026-10-02 | <= 10 us / <= 200 us | n/a | 27.8 / 604.7 us | open |
| Capacity as above, set 2026-10-02 | >= 500 conferences (2000 legs) | n/a | 275 | open |
| Mixed output after a change to the mix | byte for byte the same as before it for the same input | n/a | n/a | open |

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
worth a NIF. Host, `+S 1`, OTP 29, code at `3e0eba4`.

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
