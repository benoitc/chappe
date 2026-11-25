# Add an interop lab

A lab runs a CT suite against real daemons in docker: rtpengine, FreeSWITCH,
Kamailio, SIPp, pjsua. The labs in this repository follow one of two shapes,
and share the same gate, keep and port conventions. Use this page when a
behaviour can only be proven against the real software, or when you add a case
to an existing lab.

## Before you start

- [labs.md](labs.md): the existing labs and what each proves. Add a case to
  one of them before creating a new lab.
- One lab in the shape you need (below), read end to end.

## Where to look

| Shape | When | Example |
|---|---|---|
| Host node: the suite is the chappe node on your machine, the daemons in compose with published ports | the daemons can reach the host and the host can reach them | `apps/chappe_mrf/test/e2e.sh` + `apps/chappe_mrf/interop/docker-compose.yml`; `apps/chappe_esl/test/e2e.sh`; `apps/chappe_rtpengine/test/e2e.sh` |
| Everything in containers: a chappe node container on a fixed subnet, driven by a `lab.sh` the suite calls | SIP over UDP to containers, which Docker Desktop on macOS cannot do from the host | `apps/chappe_sip/interop/sbc/lab.sh`, `apps/chappe_sip/interop/conformance/lab.sh` |

## Steps

For a host-node lab:

1. Write `apps/<app>/interop/docker-compose.yml`. Take every published port
   from a variable with a default (`${MRF_NG_PORT:-17222}`), keep the ports
   below 32768 (out of Linux's ephemeral range), add a healthcheck, and map
   `host.docker.internal` to `host-gateway` for Linux.
2. Write `apps/<app>/test/e2e.sh`, in the shape of
   `apps/chappe_mrf/test/e2e.sh`:
   - `cd` to the umbrella root;
   - `docker compose -p ${X_PROJECT:-chappe-x} -f ... up -d --wait`;
   - discover the address the daemon reaches the host at
     (`getent hosts host.docker.internal` inside a container);
   - export the gate variable and the ports, run
     `rebar3 ct --dir apps/<app>/test --suite <suite>`;
   - `down` unless `X_KEEP=1`; exit with the suite's status.
3. Gate the suite: in `all/0` or `init_per_suite/1`, return
   `{skip, "set X=1 (make interop-x)"}` without the variable. If the CI job
   must not pass on a silent skip, add a `*_REQUIRED` variable as
   chappe_esl's `FS_REQUIRED` does.
4. If a case stops a daemon (failover), pass the compose command to the suite
   (`MRF_COMPOSE`, `FS_COMPOSE`) and let the case run `stop` and `start`.

For an all-in-containers lab:

1. Give it its own subnet (the existing ones are `10.253.7.0/24` and
   `10.253.9.0/24`) and fixed addresses.
2. Compile the tree into a docker volume (`lab.sh build`) so the node
   container runs your working copy.
3. Give `lab.sh` the subcommands the suite needs: `images`, `build`, `up`,
   `down`, plus one per action (`sipp`, `ctl`, `fs`, `logs`).
4. The suite calls `lab.sh` from `init_per_suite/1`, and `down` from
   `end_per_suite/1` unless `*_KEEP=1`.

Then, for both:

5. Add a `make interop-<x>` target to the root `Makefile` and a job to
   `.github/workflows/ci.yml` gated on `build`, uploading `_build/test/logs`
   on failure.
6. Write `interop/README.md`: what the lab proves, the services, how to run
   it, how to keep it up, how to add a case, troubleshooting. Link it from
   [labs.md](labs.md).

## Tests to add or run

- The lab's suite, through its make target, twice in a row: the second run
  must not trip on leftovers from the first.
- `make ct` with docker stopped: the suite must skip, not fail.

## How to know it works

- `make interop-<x>` exits 0 with every case run, none skipped.
- The CI job is green on your PR.
- Two copies run side by side with different `*_PROJECT` and ports.

## Notes

- Configs in a lab are test-only: an allow-all ESL ACL, an unauthenticated SIP
  profile, `verify_none`. Say so in the compose header, never copy them to
  `src/`.
- rtpengine needs `--delete-delay=0` in a lab, or deleted sessions hold their
  ports and the range runs out mid-suite.
- Pin every image: a base by its multi-arch digest (`image@sha256:...`, which
  `docker buildx imagetools inspect` prints), a source build by its release
  tag checked against its commit. A moving tag such as `:latest` changes the
  lab under you. [labs.md](labs.md#pinned-images) lists what each pin runs.

## Related

- [labs.md](labs.md)
- [add-tests.md](add-tests.md)
- [debug-a-call.md](debug-a-call.md)
