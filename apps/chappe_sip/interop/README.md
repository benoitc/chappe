# chappe_sip interop

This directory holds the drivers and labs that run chappe_sip against SIP
software it does not control. Use it to confirm that a change works on the
wire with real clients, servers and proxies, not only with the scripted peers
of the CT suites.

| Lab | What it proves | Run | README |
|---|---|---|---|
| JsSIP and Kamailio (this page) | a browser SIP stack over WebSocket, a WebRTC call through the B2BUA, OPTIONS with Kamailio | `INTEROP=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_interop_SUITE` | here |
| Conformance | one RFC flow per case against SIPp, pjsua, a DNS server and heplify-server | `make interop-conformance` | [conformance/README.md](conformance/README.md) |
| SBC | the B2BUA in front of FreeSWITCH, rtpengine and Kamailio | `make interop-sbc` | [sbc/README.md](sbc/README.md) |
| SIPp scenarios | shared by the conformance and SBC labs | | [sipp/README.md](sipp/README.md) |
| HD peer | one Opus or G.722 call from pjsua at 16 or 48 kHz, a wav played and the reply recorded | `pjsua/hd.sh` | [labs.md](../../../docs/contributing/labs.md#the-hd-peer) |

## What the JsSIP and Kamailio suite proves

`apps/chappe_sip/test/chappe_sip_interop_SUITE.erl`; the node runs in the
suite, on your machine.

- `jssip_register` (`jssip_register.js`): a JsSIP UA registers over WS. The WS
  transport, the `sip` subprotocol and the registrar accept a browser stack's
  output, and Via `received` and `rport` are stamped.
- `jssip_call` (`jssip_call.js`): two JsSIP UAs place a WebRTC call bridged by
  `create_b2bua/4` over WS. The caller reaching `confirmed` proves
  INVITE/200/ACK crossed the node and the WebRTC SDP passed through intact.
- `kamailio_options` (`kamailio/kamailio.cfg`): Kamailio's dispatcher pings
  the node with OPTIONS, the node answers 200, and Kamailio marks it active:
  Kamailio's OPTIONS parse in chappe_sip, and chappe_sip's 200 is accepted by
  Kamailio.

## Services

- node (v18 or later; CI uses 22) with `jssip`, and `@roamhq/wrtc` for the
  media call (an optional dependency with prebuilt binaries).
- docker, with the Kamailio image `ghcr.io/kamailio/kamailio-ci:5.8`. On Linux
  the container shares the host network; elsewhere it reaches the node at
  `host.docker.internal`.

## Run it

From the umbrella root, as CI does:

```sh
(cd apps/chappe_sip/interop && npm install --no-audit --no-fund)
docker pull ghcr.io/kamailio/kamailio-ci:5.8
INTEROP=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_interop_SUITE
```

Without `INTEROP=1` the suite skips. Without `node_modules`, without node, or
without the Kamailio image, the affected cases skip with the reason.

## Keep it up

There is nothing to keep up: the node lives in the suite and the Kamailio
container is removed after its case. To run a driver by hand against a node
you started with a WS listener:

```sh
cd apps/chappe_sip/interop
WS_URL=ws://127.0.0.1:9001/ws node jssip_register.js
WS_URL=ws://127.0.0.1:9001/ws node jssip_call.js
```

## Add a case

1. Write a node driver next to the others. It prints one line,
   `RESULT <outcome>` or `RESULT failed <what>`, and exits non-zero on
   failure.
2. Add a case to `chappe_sip_interop_SUITE` that starts the node with what the
   driver needs, runs it with `run_node/3` and matches the `RESULT` line.
3. Take ports from `chappe_sip_test_port:pick/0`.

## Troubleshooting

- `DEBUG=1` on a driver prints JsSIP's wire-level logs on stderr.
- `KAMAILIO_IMAGE` runs another Kamailio image; `CHAPPE_SIP_INTEROP_DIR`
  points the suite at another copy of this directory.
- `node_modules/` is git-ignored and never used by the plain `rebar3 ct` run.

See also [docs/contributing/labs.md](../../../docs/contributing/labs.md).
