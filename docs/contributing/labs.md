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
| `make lint-c` | clang-tidy and `gcc -fanalyzer` over each file of the shim, and the exported symbols of the `.so` | static findings in `c_src/nif/`, a shim symbol the NIF exports | none | n/a |
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
| rtpengine, mix | `RTPE_PROJECT` (interop), `RTPE_NAME` (rtpe-e2e) | `RTPE_NG_PORT`, `RTPE_TCP_PORT`, `RTPE_HTTP_PORT`, `RTPE_HTTPS_PORT`, `RTPE_RTP_MIN`, `RTPE_RTP_MAX` |
| esl | `ESL_PROJECT` (chappe-esl) | `FS1_ESL_PORT`, `FS2_ESL_PORT`, `ESL_SOCKET_PORT` |
| mrf | `MRF_PROJECT` (chappe-mrf) | `MRF_NG_PORT`, `MRF_RTP_MIN`, `MRF_RTP_MAX`, `MRF_FS1_SIP`, `MRF_FS2_SIP`, `MRF_FS1_ESL`, `MRF_FS2_ESL`, `MRF_SOCKET_PORT`, `MRF_SIP_PORT` |
| sbc | `SBC_LAB` (chappe-sbc) | none published: everything is on 10.253.9.0/24 |
| cluster | `CLB_PROJECT` (clb) | none published: the nodes are on the `clb_lab` network |
| cluster demo | chappe-demo-cluster (`DEMO_CLUSTER_PROJECT` for the smoke test) | none published; `DEMO_CLUSTER_PREFIX` moves its /24 (172.29.18) |

The conformance lab (network `chappe-conf`) uses fixed names: run one copy
at a time. The mrf, sbc and demo compose files build to fixed image names
(`chappe-rtpengine-interop`, `chappe-esl-fs:lab`): two checkouts with
different Dockerfiles overwrite each other's image, so run them one after
the other.

## Pinned images

What the labs run. Bump a pin in its Dockerfile or compose file, run every
lab that uses it, and update this table.

| Image | Pinned to | Runs | Used by |
|---|---|---|---|
| rtpengine (`apps/chappe_rtpengine/interop/Dockerfile`) | upstream tag `mr26.3.1.4` (commit `1165c63`), built on `ubuntu:26.04` by digest | rtpengine 26.3.1.4, userspace only, with transcoding: L16, opus, G722, PCMU, telephone-event | `make interop`, `interop-mix`, `interop-mrf`, `interop-sbc`, both demos |
| FreeSWITCH (`drachtio/drachtio-freeswitch-mrf`) | digest `sha256:2f1583c3...` (amd64 and arm64) | FreeSWITCH 1.10.10, git `4cb05e7`; G722 from mod_spandsp, OPUS from mod_opus | `interop-ref`, `interop-esl`, `interop-mrf`, `interop-sbc`, `make demo` |
| pjsua (`apps/chappe_sip/interop/pjsua/Dockerfile`) | pjproject 2.15.1 by sha256, on `ubuntu:24.04` by digest | pjsua with Opus (libopus) and G.722 | `interop-conformance`, `hd.sh` |

Until 2026-11 the rtpengine lab ran Ubuntu 24.04's package (11.5.1.18),
which has no L16 RTP codec. Moving to 26.3 changed two replies: the `siprec`
flag of a subscription now relabels the streams zero-based instead of adding
a label beside the source one, and a `delete` reply with statistics grew to
10 KB for a three-stream recording, more than the Mac docker UDP forwarding
carries (chappe_rtpengine sessions now delete with `fast`, no statistics).
`apps/chappe_mix/test/audit/ATTEMPTS.md` has the details.

## The HD peer

`apps/chappe_sip/interop/pjsua/hd.sh` places (or, with no target, answers)
one call from the lab pjsua with a single codec, a wav played into the call
and a recording of what comes back, at a 16 or 48 kHz clock:

```sh
apps/chappe_sip/interop/pjsua/hd.sh -c G722 -r 16000 -p probe.wav \
    -o out/rec.wav -d 8 -n my-lab-net sip:room@10.0.0.5:5060
```

Use `-c opus` for Opus. The recording and the pjsua log (`NAME.log`) land
in the directory of `-o`. To check a path for wideband audio, keep the
clock at 16 kHz (`-r 16000`), which is the rate the band check reads:

1. Write the band probe from an Erlang shell:

   ```erlang
   Probe = chappe_mix_test_tone:band_probe(8000),
   Pcm = << <<S:16/signed-little>> || S <- Probe >>,
   Header = chappe_audio_wav:header(16000, 1, byte_size(Pcm)),
   ok = file:write_file("probe.wav", [Header, Pcm]).
   ```

2. Run `hd.sh` with `-p probe.wav -r 16000`.
3. Read the recording back and judge it:

   ```erlang
   {ok, Wav} = file:read_file("out/rec.wav"),
   {ok, #{rate := 16000, data_offset := Off, data_bytes := N}} =
       chappe_audio_wav:info(Wav),
   <<_:Off/binary, Data:N/binary, _/binary>> = Wav,
   Got = [S || <<S:16/signed-little>> <= Data],
   Cal = chappe_mix_test_tone:band_calibrate(Probe),
   chappe_mix_test_tone:band_check(Got, Cal, #{tolerance => 6.0}).
   ```

A G.722 or Opus path gives `ok`; a G.711 hop gives `{error, Faults}` with
the 5000 and 6000 Hz tones missing.

## Score speech through the HD rooms

The band check says a path carries 16 kHz; it does not say how speech
sounds. To compare what listeners hear in two rooms, use taq
(telephony audio quality): it plays pinned speech clips through pjsua
calls, records each listener, and gives the paired ViSQOL and NISQA
differences with intervals, plus bandwidth, level and dropout checks,
against margins you declare before the first run.

1. Start the demo (`make demo`): `1004` is the FreeSWITCH 16 kHz room
   (the baseline), `1003` the chappe_mix one (the candidate).
2. Write the margins in a taq manifest, then run each clip in each
   direction, interleaving the arms, and run the baseline twice.
3. `uv run taq compare <manifest> --out <dir>`, with and without
   `--require-verified`.

[QUALITY.md](../../apps/chappe_mix/test/audit/QUALITY.md) has the last
run: its margins, host, versions, results, and the exact commands.

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
