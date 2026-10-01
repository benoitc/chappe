# Interop harness

Drivers that exercise chappe_sip against real stacks: a real JsSIP UA over
WebSocket (register and a WebRTC media call), a Kamailio container over UDP, and
a FreeSWITCH container for the media control plane (chappe_sip_media over ESL). Use
this to confirm chappe_sip interoperates on the wire with software it does not control.
The tests are opt-in (`INTEROP=1`) so they stay out of the fast `rebar3 ct` run.

## When to use

- After changing the WebSocket transport, the registrar, or the b2bua/proxy
  response building.
- Before a release, to confirm real-client compatibility.

## Prerequisites

- node (v18+; v22 tested) and the JsSIP cases: `cd interop && npm install`
- The media call also needs a WebRTC stack: `npm install @roamhq/wrtc`
  (installed as an optional dependency; ships prebuilt binaries).
- The Kamailio case needs docker running and the image pulled:
  `docker pull ghcr.io/kamailio/kamailio-ci:5.8`
- The FreeSWITCH media e2e needs docker running with `docker compose`. The image
  (`safarov/freeswitch` by default) is pulled on first `docker compose up`.

## Run

All interop cases:

From the umbrella root:

```
(cd apps/chappe_sip/interop && npm install)
docker pull ghcr.io/kamailio/kamailio-ci:5.8
INTEROP=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_interop_SUITE
```

A single driver by hand (chappe_sip must be listening; see the suite for how it
starts one):

```
cd interop
WS_URL=ws://127.0.0.1:9001/ws node jssip_register.js
WS_URL=ws://127.0.0.1:9001/ws node jssip_call.js
```

## What each case proves

- `jssip_register.js`: a real JsSIP UA registers over WS. Proves the WS
  transport, `sip` subprotocol negotiation, and registrar accept a browser
  stack's output, and Via `received`/`rport` are stamped.
- `jssip_call.js`: two JsSIP UAs (caller + callee) place a WebRTC call bridged
  by chappe_sip as a b2bua over WS. The caller reaching `confirmed` proves
  INVITE/200/ACK traversed chappe_sip and the WebRTC SDP passed through intact.
- `kamailio/`: Kamailio's dispatcher pings chappe_sip with OPTIONS; chappe_sip answers 200
  and Kamailio marks it Active. Proves both directions: Kamailio emits OPTIONS
  chappe_sip parses, chappe_sip emits a 200 Kamailio accepts. The container reaches chappe_sip
  via `host.docker.internal`.
- `freeswitch/` (suite `chappe_sip_media_fs_e2e_SUITE`): brings up FreeSWITCH with its
  Event Socket reachable, then drives the real ESL control path through
  `chappe_sip_media` (`status_roundtrip` connects and runs an api command;
  `conference_join` originates a live channel and joins it to a conference with
  `chappe_sip_media:conference/3`, asserting membership on the node). Run it with
  `INTEROP=1 rebar3 ct --suite test/chappe_sip_media_fs_e2e_SUITE`. The suite brings
  the container up and down itself.

## Notes

- Each driver prints one machine-readable line: `RESULT registered ...`,
  `RESULT established`, or `RESULT failed <what>`, and exits non-zero on
  failure.
- `node_modules/` is gitignored and never touched by the fast test run.
- Set `DEBUG=1` on a JsSIP driver for wire-level logs on stderr.
- Override the Kamailio image with `KAMAILIO_IMAGE=...`, the FreeSWITCH image
  with `FREESWITCH_IMAGE=...`, and the harness location with `CHAPPE_SIP_INTEROP_DIR=...`.
- The FreeSWITCH config under `freeswitch/conf/` is test-only and insecure (an
  allow-all ESL ACL). It exists to make the Event Socket reachable from the test.
- Docker Desktop for Mac: its published-port loopback forwarding can reset the
  ESL connection to the container (an empty banner), so the host-run
  `chappe_sip_media_fs_e2e_SUITE` skips there. Instead run it container-to-container:

  ```
  rebar3 as test compile
  docker compose -f interop/freeswitch/docker-compose.e2e.yml up \
    --abort-on-container-exit --exit-code-from runner
  ```

  This runs the suite inside a Linux `erlang` container on FreeSWITCH's own
  network (the runner's exit code is the result). It reuses the host-built beams
  read-only, so it needs neither the private media dep repos nor a C toolchain.
  On a Linux runner the host-run suite works directly over the published port.
