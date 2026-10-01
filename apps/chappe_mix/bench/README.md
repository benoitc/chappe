# Measuring the mixer

Each arm measures one thing about chappe_mix in isolation, so a number can be
charged to what caused it. Use them when you change anything on the tick path
and need a number rather than an opinion, and to check the mixer against the
thresholds in `../test/audit/PERF.md`, which were written before the code.

## Check the box first

Every arm starts by printing `uptime` and refuses to run when the 1-minute
load average is above a quarter of the logical CPUs (3.5 on a 14-CPU box,
never below 1.0). A loaded box stalls timers by tens of milliseconds, and the
mixer is a timer.

```sh
uptime
```

Set `CHAPPE_MIX_BENCH_MAX_LOAD=2.0` to change the limit. Set
`CHAPPE_MIX_BENCH_FORCE=1` to run anyway: every result line then ends in
`VOID`, and a VOID line is never quoted against a threshold. It only shows the
arm runs end to end.

## Build the arms

From the umbrella root:

```sh
rebar3 compile
mkdir -p _build/bench
erlc -o _build/bench -pa _build/default/lib/chappe_mix/ebin \
    apps/chappe_mix/bench/*.erl \
    apps/chappe_mix/test/chappe_mix_test_tone.erl \
    apps/chappe_mix/test/chappe_mix_probe.erl \
    apps/chappe_mix/test/chappe_mix_sip_ua.erl \
    apps/chappe_mix/test/chappe_mix_ref.erl
```

The four test modules are the tone endpoints, the latency probe and the
FreeSWITCH caller that the suites use, so the bench and the suites judge with
the same code.

## Run an arm

One arm per VM. `+S 1` gives the mixer node one scheduler, which is what the
capacity threshold is written against:

```sh
erl -noshell +S 1 -pa _build/default/lib/chappe_mix/ebin -pa _build/bench \
    -run chappe_mix_bench main null
```

Start with `null`. It times an empty fun and 250 bare 20 ms timers. If the
timers wake more than a millisecond late at p99, nothing else you measure
today means anything.

| arm | args | what it measures |
| --- | --- | --- |
| `null` | | empty fun cost; lateness of bare 20 ms `send_after` timers |
| `latency` | `[Bursts] [ExtraLegs]` (100, 2) | time from a tone burst leaving leg A to the first loud packet on leg B, p50/p99; tick lateness and tick-to-send time from the trace |
| `loss` | `[Bursts] [LossyLegs]` (100, 2) | the `latency` arm while the other legs carry a tone with 5% random loss: the probe's latency, tick lateness, and each leg's counted losses (the PERF.md loss row) |
| `jitter` | `idle [Secs]` or `capacity [Confs] [Secs]` (30; 100, 30) | tick lateness: the mixer's histogram over the window, plus exact values from the trace of one conference |
| `capacity` | `[Step] [StepSecs] [Max]` (10, 5, 1000) | adds 4-party conferences `Step` at a time until a tick misses its budget; conferences, legs, scheduler utilisation and memory per conference at the last step in budget |
| `mix_cost` | `[N ...]` (2 4 8 16 32 64) | CPU of the compute in one tick for N legs, no sockets |
| `ref_latency` | `[Rounds] [Bursts]` (5, 50) | chappe_mix and FreeSWITCH `mod_conference` side by side: what each party hears, then interleaved latency rounds |

### latency

A probe owns two RTP sockets joined to one conference. Every 20 ms both send
a frame of silence, and every 400 ms leg A sends one frame of a loud 1 kHz
tone instead. The latency of a burst is the time from handing it to A's
socket to the first packet on B whose samples are loud; send and receive are
timed by the same process, so no clock sync is involved. Bursts that never
arrive are counted as `missed`.

`chappe_mix_SUITE:probe_calibration` checks the probe against a reflector
that holds every packet exactly 60 ms: it must never read less.

The conference runs with `trace => Pid` (see `chappe_mix:conf_opts()`), which
sends one message per tick with when it was due, when it fired and when the
last packet was handed to its socket. `tick_to_send` is the mixer's own work
per tick, compute and I/O together; `mix_cost` is the compute alone.

### jitter

`late_histogram_us` counts how late each tick fired. The mixer clamps early
ticks to zero, and the timer is armed at millisecond resolution, truncated,
so most ticks fire up to 1 ms early; the traced conference reports those as
`early_ticks` and negative `late_p50_us`. `late_max_since_start_us` covers
the conference's whole life, setup included, not just the window.

### capacity

The ramp stops at the first step with an overrun or with the p99 bucket above
5 ms, and reports the step before it. Memory per conference is the process
plus its sockets' port memory (`erl_bytes_per_conf`, what the VM holds), and
separately the kernel buffer sizes the sockets are allowed
(`kernel_buf_ceiling_per_conf`, a ceiling, not memory in use).

The traffic comes from a peer node: a second `erl` started with the `peer`
module, a separate OS process with its own schedulers. In the mixer's node the
senders would share the one scheduler with the mixer, and the utilisation and
tick lateness would count them. Each conference gets one sender process and
one socket that feeds all four legs with pre-encoded frames and never reads
what comes back, so the peer spends its time sending. `sent_per_expected`
says whether the peer kept up; `rx_per_sent` says how much of it the mixer
received. Both are read around the step window, not exactly on it, so expect
them to wander by a few percent on short steps.

### mix_cost

It mirrors the compute in `chappe_mix_conf:mix/1`: decode every leg, sum
once, and for each leg subtract its own frame, encode and build the packet.
If you change the mix, change `mix_tick/1` in `chappe_mix_bench.erl` with it.

### ref_latency

Needs a FreeSWITCH that joins a call to `conf-<name>` into
`conference <name>@default`. The i3_bridge interop stack has one:

```sh
docker compose -f ../i3_bridge/interop/docker-compose.yml up -d --wait freeswitch
FREESWITCH_HOST=127.0.0.1 FREESWITCH_MEDIA_IP=0.250.250.254 \
    erl -noshell +S 1 -pa _build/default/lib/chappe_mix/ebin -pa _build/bench \
    -run chappe_mix_bench main ref_latency
docker compose -f ../i3_bridge/interop/docker-compose.yml down
```

`FREESWITCH_MEDIA_IP` is the address the container reaches this machine at:

```sh
docker run --rm --entrypoint getent ubuntu:24.04 hosts host.docker.internal
```

The calls are raw SIP over UDP from `chappe_mix_sip_ua`. FreeSWITCH's SDP
names its container address, so media goes to `FREESWITCH_HOST` on the port
from the SDP (the RTP range is published 1:1).

That image is amd64 only. On an arm64 host it runs emulated and its timing is
not a fair reference: record reference numbers from an amd64 host.

## Compare two commits

Build the other side somewhere else rather than rebuilding in place, copy the
current arms into it, and interleave the launches so a change in load lands on
both. At least five launches per side; keep the minimum.

```sh
mkdir -p /tmp/mixbase && git archive <commit> | tar -x -C /tmp/mixbase
mkdir -p /tmp/mixbase/apps/chappe_mix/bench
cp apps/chappe_mix/bench/*.erl /tmp/mixbase/apps/chappe_mix/bench/
cp apps/chappe_mix/test/chappe_mix_{test_tone,probe,sip_ua,ref}.erl \
    /tmp/mixbase/apps/chappe_mix/test/
(cd /tmp/mixbase && rebar3 compile && mkdir -p _build/bench && \
    erlc -o _build/bench -pa _build/default/lib/chappe_mix/ebin \
    apps/chappe_mix/bench/*.erl apps/chappe_mix/test/chappe_mix_{test_tone,probe,sip_ua,ref}.erl)

for i in 1 2 3 4 5; do
  uptime
  (cd /tmp/mixbase && erl -noshell +S 1 -pa _build/default/lib/chappe_mix/ebin \
      -pa _build/bench -run chappe_mix_bench main mix_cost 4)
  erl -noshell +S 1 -pa _build/default/lib/chappe_mix/ebin -pa _build/bench \
      -run chappe_mix_bench main mix_cost 4
done
```

An older commit without the `trace` option still runs every arm; the tick
trace lines are simply absent.

## The suites that go with it

- `chappe_mix_ref_SUITE` feeds the same tones to both mixers and requires the
  same detection result (skips without `FREESWITCH_HOST`).
- `chappe_mix_live_SUITE` puts every leg behind a real rtpengine, one of them
  PCMA and one through an opus leg, and checks N-1 at each party (skips without
  `RTPENGINE_HOST`). `make interop-mix` brings rtpengine up, runs it, and tears
  it down.
