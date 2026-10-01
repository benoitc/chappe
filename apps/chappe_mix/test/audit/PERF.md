# chappe_mix performance record

Every performance claim about chappe_mix cites this page, and it is updated in
the same commit as the change it describes. The thresholds were written in
the plan before the mixer existed. A threshold that is missed is recorded as
missed here, never redefined after the numbers arrive.

## Thresholds

| Measure | Threshold | Reference (mod_conference) | chappe_mix | Status |
| --- | --- | ---: | ---: | --- |
| Mixer latency added, RTP in to mixed RTP out, p50 / p99 | <= 25 ms / <= 45 ms, and <= reference + 10 ms | void only | void only | open |
| Tick jitter at 20 ms ptime, p99 | <= 2 ms idle, <= 5 ms at capacity | n/a | void only | open |
| Capacity, 4-party PCMU conferences, one scheduler, every tick in budget | >= 100 conferences (400 legs), and >= reference per core | not measured | void only | open |
| Memory per 4-party conference | <= 256 KiB | not measured | void only | open |
| Mix correctness: each receiver detects every other tone, own tone >= 40 dB down | same detection result as the reference | emulated, see below | see below | open |
| 5% random loss on one leg | no crash, other legs keep their thresholds | n/a | void only | open |

"Void only" means the arm ran end to end on a loaded box: the number below
exists, and it cannot pass or fail a threshold.

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
