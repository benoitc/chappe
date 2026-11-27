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

## Add a lab image

A lab image is a docker image a lab builds from a directory of this
repository, such as rtpengine, SIPp, pjsua or the FreeSWITCH of the esl and
mrf labs. `scripts/lab_image.sh` builds it only when that directory
changed, and CI keeps it in the Actions cache. You need this when your lab
builds an image of its own.

1. Add its line to the table in `scripts/lab_image.sh`: a name, the tag
   and the build context, relative to the repository root.

   ```sh
   x-daemon) TAG=chappe-x-daemon CTX=apps/chappe_x/interop/daemon ;;
   ```

2. Build it through the script where the lab starts, then bring the lab up
   without `--build`:

   ```sh
   scripts/lab_image.sh x-daemon || exit 1
   $COMPOSE up -d --wait --wait-timeout 120
   ```

   In the compose file, give the service `image: chappe-x-daemon` and keep
   its `build:`, so that `docker compose build` still works by hand.

3. If the build is slow (apt, a source build), restore the image from the
   cache in each CI job that runs the lab, before the lab's step:

   ```yaml
   - uses: ./.github/actions/lab-image
     with:
       image: x-daemon
   ```

4. Run `scripts/lab_image.sh x-daemon` twice: it prints `built`, then
   `up to date`.

Notes:

- The key is the sha256 of every file git sees in the context, committed
  or not. An edit there rebuilds the image; an edit elsewhere does not.
  A file the lab only mounts at run time (a scenario, a script) still
  counts, so keep the context small.
- The key covers the context only. Pin the base and the sources (see
  Notes above), or the image changes under an unchanged key.
- An image under the same tag built from another checkout, or by hand,
  carries another key and is rebuilt. Two checkouts with different
  contexts still replace each other's image: run them one after the
  other.
- `scripts/lab_image.sh --key x-daemon` prints the key. CI's entry is
  `lab-x-daemon-<key>`, and GitHub drops an entry unused for 7 days.
- Keep lab images out of registries. The Actions cache stays private to
  the repository's workflows, while a published image distributes the GPL
  software inside it (rtpengine, pjproject, the FreeSWITCH modules).

## Related

- [labs.md](labs.md)
- [add-tests.md](add-tests.md)
- [debug-a-call.md](debug-a-call.md)
