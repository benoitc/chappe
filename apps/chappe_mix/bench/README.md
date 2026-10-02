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
| `mix_cost` | `[N ...]` (2 4 8 16 32 64), `nohear K [N ...]` or `talk [N ...]` (4 64) | CPU of the compute in one tick for N legs, no sockets; with `nohear K`, every listener also kept from hearing K other legs; with `talk`, every leg's energy taken for talker events |
| `ref_latency` | `[Rounds] [Bursts]` (5, 50) | chappe_mix and FreeSWITCH `mod_conference` side by side: what each party hears, then interleaved latency rounds |
| `ref_capacity` | `fs\|chappe [Step] [Bursts] [Max]` (10, 25, 1000) | adds 4-party rooms to one mixer `Step` at a time, judged from outside by a probe room, until the probe or the mixer's CPU says it broke |

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
5 ms, and reports the step before it. `sched_util` is the busy share of the
normal schedulers (with `+S 1`, the mixer's one scheduler). Before
2026-10-02 the arm reported `scheduler:utilization/1`'s `total`, which also
averages in the idle dirty CPU scheduler: double those older numbers. Memory per conference is the process
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

It runs the compute of one tick with the mixer's own code,
`chappe_mix_dsp`: every leg decoded into the sum, then for each leg the sum
less its own frame encoded and built into an RTP packet. On a commit from
before `chappe_mix_dsp` it runs the list mix that commit had, so the arm
still compares two commits.

### ref_latency

Needs a FreeSWITCH that joins a call to `conf-<name>` into
`conference <name>@default`. `apps/chappe_mix/interop/freeswitch/` has one:
FreeSWITCH 1.10.10 from `drachtio/drachtio-freeswitch-mrf`, native on arm64
and amd64, with a test-only config that plays no enter or exit tone, adds no
comfort noise and mixes every member (`energy-level` 0), and limited to one
CPU to compare with the mixer on one scheduler. `ref.sh` brings it up, waits
for its SIP profile, exports the environment and tears it down:

```sh
apps/chappe_mix/test/ref.sh host ref_latency 5 50   # or: make bench-ref
apps/chappe_mix/test/ref.sh vm ref_latency 5 50     # make bench-ref REF="vm ref_latency 5 50"
```

`host` runs the arm on this machine. FreeSWITCH publishes SIP on 15060/udp
and RTP on 16384-16583/udp; the calls are raw SIP over UDP from
`chappe_mix_sip_ua`, FreeSWITCH's SDP names its container address, so media
goes to `FREESWITCH_HOST` on the port from the SDP, and
`FREESWITCH_MEDIA_IP` is the address the container reaches this machine at
(`ref.sh` resolves `host.docker.internal` inside the container).

On macOS docker runs a Linux VM, so in `host` mode every FreeSWITCH packet
crosses the host-to-VM hop and chappe_mix's do not. `vm` runs the same arm in
an `erlang:29` container on FreeSWITCH's network (the umbrella mounted
read-only), so both mixers run in the same VM; chappe_mix is still reached on
loopback there and FreeSWITCH over the docker bridge. Compare latency in `vm`
mode. The arm checks the load in the VM, which on macOS leaves out the host,
so `ref.sh vm` checks the host's load first with the same limit.

`KEEP=1` leaves FreeSWITCH up between launches when you interleave several.

### ref_capacity

The `capacity` arm reads chappe_mix's own tick statistics, which
`mod_conference` does not have. This arm judges either mixer from outside,
so the two ramps compare:

```sh
apps/chappe_mix/test/ref.sh vm ref_capacity fs 25 20 1000
apps/chappe_mix/test/ref.sh vm ref_capacity chappe 25 20 1000
```

Each room is four calls (`fs`) or four legs (`chappe`) fed a 500 Hz PCMU
tone by one sender group in a peer node, as in `capacity`. At each step a
fresh probe room, probe legs A and B plus two silent legs, runs `Bursts`
probe bursts and reports, per step:

- `p50_us`, `p99_us`, `missed`: burst latency A to B, as in `latency`
- `b_rx_per_frame`, `b_gap_max_us`, `b_gap_dev_p50_us`, `b_gap_dev_p99_us`,
  `b_gap_hist`: packets B received per frame the probe sent, and the gaps
  between them (deviation from 20 ms, 5 ms buckets)
- `cpu_pct_one_core`: the mixer's CPU over the probe window, in percent of
  one core. For `fs` it is the container's cgroup CPU time from the docker
  API (`DOCKER_SOCK`, default `/var/run/docker.sock`, mounted into the bench
  container); for `chappe` it is the VM's `statistics(runtime)`, every
  thread of the node that runs the mixer and nothing else
- `mem_per_room_bytes`: growth since the start, per room: the container's
  memory less its inactive page cache (what `docker stats` shows), or the
  VM's `erlang:memory(total)`

A step is in budget when every burst is heard with a p99 at most 20 ms (one
frame) above the same room's p50, B gets at least 98% of a packet per frame
with no gap over 60 ms, and the mixer uses under 95% of one core. Latency is
judged within the room: each step's probe room is new, and `mod_conference`'s
latency moves by whole frames from room to room with the phase of its timers.
The gap spread is reported, not judged: `mod_conference` paces its output
with a p99 spread near 5 ms even with a few rooms. The ramp stops at the first step out of budget and
reports the step before it. The `fs` ramp needs more RTP ports than the
published range, so `ref.sh` widens FreeSWITCH's range to 16384-32767 for it;
run it in `vm` mode.

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
  same detection result (skips without `FREESWITCH_HOST`). `make interop-ref`
  brings FreeSWITCH up, runs it, and tears it down.
- `chappe_mix_live_SUITE` puts every leg behind a real rtpengine, one of them
  PCMA and one through an opus leg, and checks N-1 at each party (skips without
  `RTPENGINE_HOST`). `make interop-mix` brings rtpengine up, runs it, and tears
  it down.
