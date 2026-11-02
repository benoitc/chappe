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
need it when you change dialog, REFER, Replaces, session timer,
subscription or DNS resolution behaviour, and before a release. CI runs it
in the conformance job.

Everything runs in docker on one network (`10.253.7.0/24`): a chappe node
(`interop/conformance/node/chappe_conf_node.erl`, on the public API), SIPp,
pjsua and a dnsmasq server. Docker Desktop on macOS cannot send UDP from
the host to a container, so the node runs in a container too.

```bash
make interop-conformance
```

The first run builds four images and compiles the tree into a volume;
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
- The node resolves through dnsmasq at `10.253.7.53` (its `/etc/resolv.conf`
  is `interop/conformance/dns/resolv.conf`; sofia reads it). The records are
  in `interop/conformance/dns/dnsmasq.conf`: `svc.lab` has a NAPTR to a UDP
  SRV on port 5080, `svcs.lab` a NAPTR to a TLS SRV whose first target
  refuses connections. The `dns_*` cases run SIPp at `10.253.7.30`, the
  address the records name, and ask the node to dial: a MESSAGE to
  `sip:dial@10.253.7.10` whose body is the URI. The node sends an OPTIONS
  there and answers with the status it got.
- `lab.sh build` also makes throwaway TLS certificates (a CA, the node's
  `agent.pem`, and a `svcs.lab` certificate for the TLS target) in the
  `chappe_conf_certs` volume; the node listens for TLS on 5061 with them.
- `lab.sh logs dns` prints the queries dnsmasq answered.
- The `hep_capture` case starts heplify-server (`10.253.7.40`, HEP on UDP
  9060) with its PostgreSQL, restarts the node with `CHAPPE_HEP` set so it
  captures to it, makes one call over each of UDP, TCP, TLS and WebSocket
  from a second node container (`lab.sh hep calls`), and reads back from
  the Homer tables that each Call-ID has messages sent by the node and
  messages it received (`lab.sh hep stored ID`).
- `LAB_PROXY=http://host.docker.internal:8888` sends the build container's
  hex fetches through an HTTP proxy on your machine.

## SBC lab (FreeSWITCH, rtpengine, Kamailio)

The SBC lab runs real calls through the B2BUA: SIPp calls a chappe node
(`interop/sbc/node/chappe_sbc_node.erl`), which sends them to two FreeSWITCH
peers kept alive with OPTIONS, with rtpengine anchoring the calls that ask
for it and Kamailio pinging the node both ways. Run it when you change the
B2BUA, the media anchor or the peers.

```sh
make interop-sbc
```

It builds the images, compiles this tree into the node's volume, starts the
lab on 10.253.9.0/24 and runs `chappe_sip_sbc_interop_SUITE`: direct and
anchored calls (the c= SIPp gets, rtpengine's packet count), hold from SIPp
and from FreeSWITCH (`uuid_hold`), an offerless re-INVITE, UPDATE, glare,
`set_media` both ways, a session timer refresh, failover when fs1 stops, and
the Kamailio pings. To drive the lab by hand:

```sh
apps/chappe_sip/interop/sbc/lab.sh up
apps/chappe_sip/interop/sbc/lab.sh sipp sbc_call anchor 5000 my-call@lab
apps/chappe_sip/interop/sbc/lab.sh ctl calls
apps/chappe_sip/interop/sbc/lab.sh down
```

Set `SBC_LAB` to give the compose project another name, and `SBC_KEEP=1` to
leave the lab up after the suite.

## Where it lives

- Modules: `apps/chappe_sip/interop/` (JsSIP drivers, Kamailio, SIPp, pjsua,
  the SBC and conformance labs).
- Tests: `chappe_sip_interop_SUITE`, `chappe_sip_conformance_SUITE`,
  `chappe_sip_sbc_interop_SUITE`.
- Lab: `make interop`, `make interop-conformance`, `make interop-sbc`.

## Running suites on a Mac

After SIP over TCP, a new engine on the same port can fail to start on macOS
with `nta_agent_create failed (bad or busy contact?)`. sofia sets `SO_REUSEADDR`
after `bind` on anything but Linux, on purpose, so a port with a connection in
TIME_WAIT stays busy until it clears. That took 30 s on the Mac where we
measured it. Pick a fresh port for each engine instead of waiting. On Linux
sofia sets the option before `bind`: the same stop and restart rebinds at once,
with the old connection still in TIME_WAIT, so production is not affected.

macOS also refuses `chappe_sip_nif:start/2` with a contact that has no
transport, because `;transport=udp,tcp` is only added on the engine path
(`chappe_sip_binds`). A suite using the NIF directly must pass a transport.
