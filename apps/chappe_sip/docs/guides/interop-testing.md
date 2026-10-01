# Interop testing

The interop track drives real SIP stacks at chappe_sip: a real JsSIP UA over
WebSocket (register and a WebRTC call) and a Kamailio container over UDP. It is
opt-in so it stays out of the fast test run. Read this to verify chappe_sip
interoperates on the wire before a release.

## When to use it

- You changed the WebSocket transport, the registrar, or the b2bua/proxy
  response building.
- You want to confirm real-client compatibility, not just chappe_sip-vs-chappe_sip tests.

## Prerequisites

- node and `npm install` in `interop/` (JsSIP cases). The media call also needs
  `npm install @roamhq/wrtc`.
- docker running, with the Kamailio image pulled:
  `docker pull ghcr.io/kamailio/kamailio-ci:5.8`.

## Run

From the umbrella root:

```bash
(cd apps/chappe_sip/interop && npm install)
INTEROP=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_interop_SUITE
# or, from apps/chappe_sip: make interop
```

Without `INTEROP=1` the suite skips, so the normal `rebar3 ct` run is
unaffected.

## What each case proves

- `jssip_register`: a real JsSIP UA registers over WS; the binding lands in the
  store.
- `jssip_call`: two JsSIP UAs place a WebRTC call bridged by the b2bua over WS;
  the SDP passes through intact.
- `kamailio_options`: Kamailio's dispatcher OPTIONS-pings chappe_sip and marks it
  active; proves both wire directions.

## Notes

- The drivers live in `interop/` (node) and `interop/kamailio/` (config); each
  prints a `RESULT ...` line.
- The Kamailio container reaches chappe_sip via `host.docker.internal`; no
  `--network host` needed.
- `test/asan/run.sh` runs the C NIF under AddressSanitizer in a Linux container
  (macOS cannot install interceptors for a dlopen'd NIF).

## Conformance lab (SIPp and pjsua)

The conformance lab checks chappe_sip against two independent SIP stacks,
one RFC flow per case: SIPp scenarios that fail on any header the RFC
requires and does not see, and pjsua for transfers and session timers. You
need it when you change dialog, REFER, Replaces, session timer or
subscription behaviour, and before a release.

Everything runs in docker on one network (`10.253.7.0/24`): a chappe node
(`interop/conformance/node/chappe_conf_node.erl`, on the public API), SIPp
and pjsua. Docker Desktop on macOS cannot send UDP from the host to a
container, so the node runs in a container too.

```bash
make interop-conformance
```

The first run builds three images and compiles the tree into a volume;
later runs recompile only what changed. To run one case, or to keep the lab
up and drive it by hand:

```bash
CONFORMANCE=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_conformance_SUITE \
    --case refer_notify
apps/chappe_sip/interop/conformance/lab.sh build
apps/chappe_sip/interop/conformance/lab.sh up
apps/chappe_sip/interop/conformance/lab.sh sipp refer_notify
apps/chappe_sip/interop/conformance/lab.sh down
```

Notes:

- Each case is `interop/sipp/scenarios/<case>.xml`, or a pjsua flow in
  `interop/pjsua/scenario.sh`; the case comment in the suite names the RFC
  clause and carries the `%% req:` ids.
- `interop/conformance/expected-fail` lists the cases for features not built
  yet. A listed case that fails is reported skipped; one that passes fails
  the run, so remove its line in the change that fixes it. Do not weaken a
  scenario to make it pass.
- Without `CONFORMANCE=1`, or without docker, the suite skips.
- `CONFORMANCE_NOBUILD=1` skips the image and compile steps.
- `LAB_PROXY=http://host.docker.internal:8888` sends the build container's
  hex fetches through an HTTP proxy on your machine.
