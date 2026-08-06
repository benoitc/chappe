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

```bash
cd interop && npm install && cd ..
INTEROP=1 rebar3 ct --suite test/chappe_sip_interop_SUITE
# or: make interop
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
