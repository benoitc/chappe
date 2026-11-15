# chappe_mix labs

The mixer has two labs. One puts it behind a real rtpengine, the way a
product deploys it. The other runs FreeSWITCH mod_conference, the reference
mixer, fed the same tones and judged by the same Goertzel code. Use them when
you change mixing, timing, the jitter buffer, RTCP or the leg SDP.

## What they prove

| Target | Suite | Proves |
|---|---|---|
| `make interop-mix` | `chappe_mix_live_SUITE` | N-1 at each of three parties anchored by rtpengine (PCMU relayed, PCMA transcoded, an opus leg encoded and decoded by rtpengine), 30 ms packets, DTMF through rtpengine |
| `make interop-ref` | `chappe_mix_ref_SUITE` | the mixer detects what mod_conference detects, for the same input; burst latency is logged, never asserted |

## Services

- `interop-mix` reuses the rtpengine stack of
  [apps/chappe_rtpengine/interop](../../chappe_rtpengine/interop/README.md)
  (container `rtpe-e2e`, NG on 12222/udp, RTP 30000-30100/udp).
- `interop-ref` runs `freeswitch/docker-compose.yml` (project
  `chappe-mix-ref`, container `chappe-mix-fs`): FreeSWITCH 1.10.10 on one CPU
  (`FS_CPUS`), SIP on 15060/udp, RTP 16384-16583/udp, config in
  `freeswitch/conf/`. The `bench` profile adds an `erlang:29.1.2` container next
  to it for bench arms.

## Run them

From the umbrella root:

```sh
make interop-mix
make interop-ref
```

`apps/chappe_mix/test/interop.sh` and `apps/chappe_mix/test/ref.sh suite`
bring the stack up, set `RTPENGINE_HOST` and `RTPENGINE_MEDIA_IP`, or
`FREESWITCH_HOST` and `FREESWITCH_MEDIA_IP`, run the suite, and tear down.
Without those variables the suites skip.

## Keep it up

```sh
KEEP=1 apps/chappe_mix/test/ref.sh suite     # leaves FreeSWITCH running, reuses it next time
docker compose -f apps/chappe_mix/interop/freeswitch/docker-compose.yml --profile bench down
```

`interop.sh` always tears rtpengine down; run that stack by hand as its
README shows.

## Add a case

1. Start from the non-gated suites (`chappe_mix_SUITE`, `chappe_mix_rfc_SUITE`)
   with `chappe_mix_test_peer` or the tone endpoints, if loopback can show it.
2. A live case goes in `chappe_mix_live_SUITE`; judge audio with the Goertzel
   helpers there, not by packet count.
3. A reference case goes in `chappe_mix_ref_SUITE` and runs the same input
   through both mixers.
4. Never assert on timing in a suite: latency and cost are bench arms
   (`make bench-ref`, `make bench-pass`, see `apps/chappe_mix/bench/README.md`),
   with results in `apps/chappe_mix/test/audit/PERF.md`.

## Troubleshooting

- Live cases skip: `host.docker.internal` did not resolve inside the
  container, so `RTPENGINE_MEDIA_IP` is empty.
- The capacity bench needs more RTP ports: `ref.sh` raises `FS_RTP_END` for
  `ref_capacity`.
- A bench arm refuses to run: the load average is above its limit. Check
  `uptime` and rerun on a quiet machine.

See also [docs/contributing/labs.md](../../../docs/contributing/labs.md).
