# Run the checks and the labs

This page lists every check and every docker lab in the umbrella: what each
one runs, what it proves, and the environment variable that turns it on. Read
it before your first change, when CI fails on a job you have never run, or
when you need to keep a lab up to look at it by hand.

## Before you start

- [CONTRIBUTING.md](../../CONTRIBUTING.md): the commit and PR rules.
- The root [Makefile](../../Makefile) and
  [.github/workflows/ci.yml](../../.github/workflows/ci.yml): the source of
  truth for everything below.
- Docker for the labs. Each lab script brings its stack up and tears it down.

## Where to look

| What | Where |
|---|---|
| Check targets | `Makefile` (`check`, `test`, `test-static`, `cover`) |
| Lab scripts | `apps/chappe_rtpengine/test/e2e.sh`, `apps/chappe_esl/test/e2e.sh`, `apps/chappe_mrf/test/e2e.sh`, `apps/chappe_mix/test/interop.sh`, `apps/chappe_mix/test/ref.sh` |
| Lab definitions | `apps/*/interop/` (compose files, configs, lab READMEs) |
| SIP labs driven from a suite | `apps/chappe_sip/interop/conformance/lab.sh`, `apps/chappe_sip/interop/sbc/lab.sh` |
| The C engine checks | `apps/chappe_sip/test/asan/` (ASan, UBSan, TSan), `apps/chappe_sip/c_src/fuzz/`, `.clang-tidy` |

## The checks

```sh
make fmt            # erlfmt, writes files
make check          # compile, eunit, ct, lint, xref, dialyzer, fmt-check
make cover MIN_COVERAGE=80
```

- `make check` is `compile test test-static`. `test` is `eunit ct`;
  `test-static` is `lint xref dialyzer fmt-check`.
- `make ct` removes `_build/test/lib/chappe_*/test` first: rebar3 never prunes
  the copied test dirs, so a deleted suite would still run.
- `make cover` runs eunit and ct under cover and fails under `MIN_COVERAGE`.
  CI sets the floor in `ci.yml` (`MIN_COVERAGE: '80'`). Raise it, never lower
  it.
- `SKIP_ENGINE_BUILD=1 rebar3 compile` skips the C build. CI uses it for lint,
  xref and dialyzer only.

## The labs

Every lab suite is gated: without its variable it returns `{skip, ...}`, so a
plain `rebar3 ct` stays green with no docker.

| Target | Runs | Proves | Gate | Keep it up |
|---|---|---|---|---|
| `make interop` | `chappe_rtpengine_live_SUITE`, `_e2e_SUITE`, `_siprec_SUITE` against rtpengine | NG over UDP, TCP and WS, SDP rewriting, SRTP/DTLS, relay, subscriptions, playback | `RTPENGINE_HOST` (relay cases also need `RTPENGINE_MEDIA_IP`) | none: run the compose by hand, see [the lab README](../../apps/chappe_rtpengine/interop/README.md) |
| `make interop-mix` | `chappe_mix_live_SUITE` behind the same rtpengine | the mixer behind rtpengine, transcoded legs, N-1 checked by Goertzel | `RTPENGINE_HOST` and `RTPENGINE_MEDIA_IP` | none |
| `make interop-ref` | `chappe_mix_ref_SUITE` against FreeSWITCH mod_conference | the mixer against its reference, same tones, same judge | `FREESWITCH_HOST` | `KEEP=1` |
| `make interop-esl` | `chappe_esl_live_SUITE` against two FreeSWITCH nodes | auth, api, bgapi, events, outbound sockets, the node registry, a node stopped and restarted | `FS_HOST`; `FS_REQUIRED=1` turns a failed connect into a failure | none: see [the lab README](../../apps/chappe_esl/interop/README.md) |
| `make interop-mrf` | `chappe_mrf_live_SUITE` against rtpengine and two FreeSWITCH nodes | IVR, bridging, recording, native and FreeSWITCH conferences, owner death, node failover | `MRF=1` | `MRF_KEEP=1` |
| `make interop-conformance` | `chappe_sip_conformance_SUITE`: SIPp, pjsua, dnsmasq, heplify-server | one RFC flow per case, exact headers, RFC 3263, HEP | `CONFORMANCE=1` | none: drive `lab.sh` by hand, see [the lab README](../../apps/chappe_sip/interop/conformance/README.md) |
| `make interop-sbc` | `chappe_sip_sbc_interop_SUITE`: SIPp, FreeSWITCH, rtpengine, Kamailio | the B2BUA as an SBC: direct and anchored calls, hold, glare, `set_media`, `replace_b`, failover | `INTEROP=1` | `SBC_KEEP=1` |
| (no target) | `chappe_sip_interop_SUITE`: JsSIP and Kamailio | WS registration, a WebRTC call through the B2BUA, OPTIONS both ways | `INTEROP=1` | none |
| `make asan` | the lifecycle, smoke, dialog_ops, NIF boundary and core suites with the NIF under AddressSanitizer and UndefinedBehaviorSanitizer, in a Linux container | memory errors, leaks and undefined behaviour in the C NIF | none | the build volume persists; `ASAN_VOLUME` names it |
| `make tsan` | the lifecycle stress and smoke suites with the NIF under ThreadSanitizer | data races between the stack thread and the NIF callers | none | n/a |
| `make lint-c` | clang-tidy and `gcc -fanalyzer` over the shim | static findings in `chappe_sip_engine_nif.c` | none | n/a |
| `make fuzz` | the libFuzzer target on sofia's message parser and the NIF boundary fuzz suite, `FUZZ_TIME` seconds | no crash on random bytes or random NIF arguments | none | crashes are kept as regression seeds |
| `make compliance GATE=demo` | the requirement matrices | no hard `demo` row is failing | none | n/a |

Run the JsSIP and Kamailio suite like CI does:

```sh
(cd apps/chappe_sip/interop && npm install --no-audit --no-fund)
docker pull ghcr.io/kamailio/kamailio-ci:5.8
INTEROP=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_interop_SUITE
```

Run one conformance case:

```sh
CONFORMANCE=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_conformance_SUITE \
    --case refer_notify
```

Keep the SBC lab up after the suite and read its logs:

```sh
SBC_KEEP=1 make interop-sbc
apps/chappe_sip/interop/sbc/lab.sh logs sbc
apps/chappe_sip/interop/sbc/lab.sh down
```

## Run two labs side by side

Each lab takes a compose project name and its ports from the environment:

| Lab | Project | Ports |
|---|---|---|
| esl | `ESL_PROJECT` (chappe-esl) | `FS1_ESL_PORT`, `FS2_ESL_PORT`, `ESL_SOCKET_PORT` |
| mrf | `MRF_PROJECT` (chappe-mrf) | `MRF_NG_PORT`, `MRF_RTP_MIN`, `MRF_RTP_MAX`, `MRF_FS1_SIP`, `MRF_FS2_SIP`, `MRF_FS1_ESL`, `MRF_FS2_ESL`, `MRF_SOCKET_PORT`, `MRF_SIP_PORT` |
| sbc | `SBC_LAB` (chappe-sbc) | none published: everything is on 10.253.9.0/24 |

The rtpengine lab (container `rtpe-e2e`) and the conformance lab (network
`chappe-conf`) use fixed names: run one copy at a time.

## Tests to add or run

- After any change: `make check`.
- Then the lab of the area you touched. The "Lab" column of
  [navigation.md](../navigation.md) maps an area to its lab.

## How to know it works

- `make check` exits 0.
- A lab script exits 0 and the CT summary shows no skipped case you expected
  to run. A skip on a lab suite usually means a missing gate variable or
  docker.

## Notes

- Check the load average before timing anything; other work on the machine
  skews the mixer bench and the timer cases.
- A port clash (`eaddrinuse`, "nta_agent_create failed") on a plain CT suite
  is a known source of flakiness: rerun the suite on its own before calling
  it a regression. New suites take ports from `chappe_sip_test_port:pick/0`.
- `make bench-ref` and `make bench-pass` are measurements, not checks. See
  `apps/chappe_mix/bench/README.md`.

## Related

- [debug-a-call.md](debug-a-call.md)
- [add-interop-lab.md](add-interop-lab.md)
- [compliance.md](compliance.md)
- [change-c-engine.md](change-c-engine.md)
