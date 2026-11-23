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
| Check targets | `Makefile` (`check`, `test`, `test-static`, `cover`, `docs-check`) |
| Lab scripts | `apps/chappe_rtpengine/test/e2e.sh`, `apps/chappe_esl/test/e2e.sh`, `apps/chappe_mrf/test/e2e.sh`, `apps/chappe_cluster/test/e2e.sh`, `apps/chappe_mix/test/interop.sh`, `apps/chappe_mix/test/ref.sh` |
| Lab definitions | `apps/*/interop/` (compose files, configs, lab READMEs) |
| Demos | `demo/sbc/`, `demo/cluster/` (with `smoke.sh`), `apps/chappe_esl/examples/` |
| Advisories | `scripts/advisories.py`, `scripts/advisories_test.py`, `.github/workflows/advisories.yml` |
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
- `make demo-compile`, after `rebar3 compile`, builds the demos
  (`demo/sbc/src`, `demo/cluster/src`) with warnings as errors, then runs
  xref on them: a demo that calls a function the apps no longer export
  fails. CI runs it in the build job.
- `make advisories-test` runs the unit tests of `scripts/advisories.py`.
  The Advisories workflow (`.github/workflows/advisories.yml`) runs them,
  then checks the vendored sofia-sip and the hex packages of `rebar.lock`
  against published advisories, on each pull request and every Monday.
- `make docs` builds the ex_doc HTML of each app into `apps/<app>/doc`.
- `make docs-check` runs `scripts/docs_check.escript`, OTP only, no build.
  CI runs it next to the static checks. For each app it checks that:
  - every src module is in one ex_doc group, and every module a group
    names exists;
  - every `docs/**/*.md` is an ex_doc extra, and every extra exists;
  - every supervisor, and every src module, is named in the app's
    `docs/design/overview.md`, in full or by a prefix wildcard such as
    `chappe_sip_engine_*` (the bare `<app>_*` names nothing);
  - every src module has a module doc, `%% @doc` or `-moduledoc`, before
    its first function;
  - the app's row in the public and internal table of
    [navigation.md](../navigation.md) agrees with ex_doc: a module of the
    group named "Internal" is in the Internal column, a module of any other
    group in the Public column. A cell writes a name in full or as
    `_suffix`; `_x*` is a prefix and "every `_x`" a suffix; a name written
    out wins over a wildcard. A mismatch names the module, the
    navigation.md line and the rebar.config line.

  For the repository it checks that every relative markdown link and
  `#anchor` resolves.

## The labs

Every lab suite is gated: without its variable it returns `{skip, ...}`, so a
plain `rebar3 ct` stays green with no docker.

| Target | Runs | Proves | Gate | Keep it up |
|---|---|---|---|---|
| `make interop` | `chappe_rtpengine_live_SUITE`, `_e2e_SUITE`, `_siprec_SUITE` against rtpengine, then `chappe_sip_siprec_live_SUITE` | NG over UDP, TCP and WS, SDP rewriting, SRTP/DTLS, relay, subscriptions, playback; a call recorded through SIPREC to chappe's own SRS, RTP and SRTP | `RTPENGINE_HOST` (relay cases also need `RTPENGINE_MEDIA_IP`) | none: run the compose by hand, see [the lab README](../../apps/chappe_rtpengine/interop/README.md) |
| `make interop-mix` | `chappe_mix_live_SUITE` behind the same rtpengine | the mixer behind rtpengine, transcoded legs, N-1 checked by Goertzel | `RTPENGINE_HOST` and `RTPENGINE_MEDIA_IP` | none |
| `make interop-ref` | `chappe_mix_ref_SUITE` against FreeSWITCH mod_conference | the mixer against its reference, same tones, same judge | `FREESWITCH_HOST` | `KEEP=1` |
| `make interop-esl` | `chappe_esl_live_SUITE` against two FreeSWITCH nodes, then `chappe_audio_live_SUITE` | auth, api, bgapi, events, outbound sockets, the node registry, a node stopped and restarted; FreeSWITCH audio forks (mod_audio_fork, mod_audio_stream) into a chappe_audio listener and its store | `FS_HOST`; `FS_REQUIRED=1` turns a failed connect into a failure; the audio suite also needs chappe_esl on the code path (`AUDIO_PORT`, default 18085) | none: see [the lab README](../../apps/chappe_esl/interop/README.md) |
| `make demo-esl` | two FreeSWITCH nodes and a shell with chappe_esl monitoring them | the node registry by hand: nodes up and down, load, drain, selection | none | the shell keeps it up; `q().` stops the nodes, see [the example README](../../apps/chappe_esl/examples/README.md) |
| `make interop-mrf` | `chappe_mrf_live_SUITE` against rtpengine and two FreeSWITCH nodes | IVR, bridging, recording, native and FreeSWITCH conferences, owner death, node failover | `MRF=1` | `MRF_KEEP=1` |
| `make interop-conformance` | `chappe_sip_conformance_SUITE`: SIPp, pjsua, dnsmasq, heplify-server | one RFC flow per case, exact headers, RFC 3263, HEP | `CONFORMANCE=1` | none: drive `lab.sh` by hand, see [the lab README](../../apps/chappe_sip/interop/conformance/README.md) |
| `make interop-sbc` | `chappe_sip_sbc_interop_SUITE`: SIPp, FreeSWITCH, rtpengine, Kamailio | the B2BUA as an SBC: direct and anchored calls, hold, glare, `set_media`, `replace_b`, failover | `INTEROP=1` | `SBC_KEEP=1` |
| `make interop-cluster` | three to five chappe_cluster nodes under a seeded schedule of partitions, kills, pauses, delays and clock skews, then `chappe_cluster_lab_checker` over every node's log | no key ever had two valid leases at once; every node claims again after the last heal | none; `SEED` replays a run, `DURATION` (5m), `NODES` (3 to 5), `MODE=proofs` runs each fault against `chappe_cluster_lab_fake` and expects a violation (about 20 minutes, by hand) | `KEEP=1`; logs in `_build/clb/logs/<seed>/`, see [the lab README](../../apps/chappe_cluster/interop/README.md) |
| `make demo` | a small SBC: rtpengine and Kamailio in docker, the chappe node in the foreground | a call through the B2BUA by hand | none | stays up while the node runs; `make demo-shell` attaches a shell, `make demo-down` stops the containers, see [the demo README](../../demo/sbc/README.md) |
| `make demo-cluster` | three chappe nodes on chappe_cluster in docker, with rtpengine and a trunk | one registrar, one conference room and one trunk pinger across the nodes | none | stays up until `make demo-cluster-down`; `make demo-cluster-shell N=n2` attaches a shell, see [the demo README](../../demo/cluster/README.md) |
| `make demo-cluster-smoke` | the cluster demo's walkthrough with SIPp, every step checked | a call across nodes, one room for every caller, the room moving off a stopped node, one trunk pinger | none | `KEEP=1`; on a failure the logs land in `_build/demo-cluster-logs` |
| (no target) | `chappe_sip_interop_SUITE`: JsSIP and Kamailio | WS registration, a WebRTC call through the B2BUA, OPTIONS both ways | `INTEROP=1` | none |
| `make asan` | every chappe_sip suite with the NIF under AddressSanitizer and UndefinedBehaviorSanitizer and the BEAM allocators off (`+Mea min`), in a Linux container | memory errors, leaks and undefined behaviour in the C NIF | none | the build volume persists; `ASAN_VOLUME` names it |
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
| cluster | `CLB_PROJECT` (clb) | none published: the nodes are on the `clb_lab` network |
| cluster demo | chappe-demo-cluster (`DEMO_CLUSTER_PROJECT` for the smoke test) | none published; `DEMO_CLUSTER_PREFIX` moves its /24 (172.29.18) |

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
