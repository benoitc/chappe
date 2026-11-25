# SBC lab

This lab runs real calls through the chappe_sip B2BUA used as an SBC: SIPp
calls a chappe node, which sends each call to one of two FreeSWITCH peers,
with rtpengine anchoring the calls that ask for it and Kamailio pinging the
node both ways. Run it when you change the B2BUA, the media anchor, the peers
or OPTIONS keepalive.

## What it proves

`apps/chappe_sip/test/chappe_sip_sbc_interop_SUITE.erl`, one SIPp call per
case:

| Case | Proves |
|---|---|
| `kamailio_pings` | Kamailio's dispatcher pings the node and the node pings Kamailio; both see the other up |
| `direct_call` | the SDP passes through: SIPp's answer names FreeSWITCH |
| `anchored_call` | rtpengine anchors: SIPp's answer names rtpengine, which relays FreeSWITCH's tone |
| `hold_from_sipp`, `hold_from_fs` | a re-INVITE with `sendonly` from either side is relayed and reported as hold and unhold of leg a or b |
| `offerless_reinvite` | an offerless re-INVITE: FreeSWITCH's offer comes back in the 2xx, the answer goes on in the ACK |
| `update_offer` | an UPDATE offer in a confirmed call, answered by FreeSWITCH |
| `glare` | the node's re-INVITE and SIPp's cross: each side gets 491 |
| `set_media_both_ways` | a direct call goes anchored and back with offerless re-INVITEs |
| `session_timer_refresh` | SIPp refreshes its session timer through the node; no BYE before expiry |
| `replace_b` | an anchored call moves from fs1 to fs2; SIPp sees no re-INVITE |
| `options_failover` | fs1 stops, its peer goes down, the next call lands on fs2 |

## Services

All on the docker network `10.253.9.0/24`; nothing runs on the host, because
Docker Desktop on macOS cannot send UDP from the host to a container.

| Service | Address | Role |
|---|---|---|
| `sbc` | 10.253.9.10:5060 | the chappe node, `node/chappe_sbc_node.erl` on the public chappe_sip API, compiled from your working tree |
| `rtpengine` | 10.253.9.20 (NG on 2223) | media anchor, built from `apps/chappe_rtpengine/interop` |
| `fs1`, `fs2` | 10.253.9.31, .32 | FreeSWITCH peers answering any number with a tone (`freeswitch/freeswitch.xml`) |
| `kamailio` | 10.253.9.40 | dispatcher pinging the node (`dispatcher.list`, `../kamailio/kamailio.cfg`) |
| SIPp | from 10.253.9.128/25 | one container per call (`lab.sh sipp`), image built from `../sipp` |

The node also sits on a second network, `nat` (`10.253.10.0/24`), as a host
behind 1:1 NAT: it binds 10.253.10.10:5060 and advertises 203.0.113.10, except
to its local network 10.253.10.0/26. `lab.sh sipp-nat` runs SIPp there, from
10.253.10.128/25 (outside: it gets the public address) or from the address
you give (inside: it gets the local one).

The Request-URI user picks what the node does with a call: `anchor...` anchors
it, `direct...` passes the SDP through, `glare` answers then re-INVITEs right
after the ACK.

## Run it

```sh
make interop-sbc
```

That is `INTEROP=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_sbc_interop_SUITE`.
The suite runs `lab.sh images`, `build` and `up`, then the cases, then
`down`. Without `INTEROP=1`, or without docker, it skips. The first run
builds the images and compiles the tree into the `chappe-sbc-work` volume.

## Keep it up and drive it by hand

```sh
SBC_KEEP=1 make interop-sbc                      # leave it up after the suite
apps/chappe_sip/interop/sbc/lab.sh up             # or start it yourself
apps/chappe_sip/interop/sbc/lab.sh sipp sbc_call anchor 5000 my-call@lab
apps/chappe_sip/interop/sbc/lab.sh ctl calls
apps/chappe_sip/interop/sbc/lab.sh ctl events '["my-call@lab"]'
apps/chappe_sip/interop/sbc/lab.sh ctl query '["my-call@lab"]'
apps/chappe_sip/interop/sbc/lab.sh fs 1 'show channels'
apps/chappe_sip/interop/sbc/lab.sh kam
apps/chappe_sip/interop/sbc/lab.sh logs sbc
apps/chappe_sip/interop/sbc/lab.sh down           # keeps the build volume
apps/chappe_sip/interop/sbc/lab.sh clean          # removes it too
```

`lab.sh ctl FUN ARGS` calls `chappe_sbc_node:FUN(ARGS)` on the node with
`erl_call`: `calls/0`, `set_media/2`, `replace_b/2`, `query/1`, `events/1`,
`peers/0`. After changing chappe code, run `lab.sh build` and `lab.sh up`
again.

`SBC_LAB` names the compose project (default `chappe-sbc`), so a second copy
can run next to this one.

## Add a case

1. Pick or write the SIPp scenario. `lab.sh sipp SCEN ...` looks for
   `scenarios/SCEN.xml` here first, then reuses the conformance scenarios in
   `../sipp/scenarios/`. Checks follow the rules in
   [../sipp/README.md](../sipp/README.md).
2. If the case needs to ask the node something new, add an exported function
   to `node/chappe_sbc_node.erl` and call it with `ctl`.
3. Add the case to the suite: start SIPp with `sipp/5` (scenario, user, pause,
   Call-ID), poll the node with `until/2`, finish with `done/1`. Use a Call-ID
   of its own (`<case>-1@lab`).
4. Put its `%% req:` ids above it if it proves a catalogued requirement.

## Troubleshooting

- The suite times out in `up`: `lab.sh logs sbc` shows the node's output; the
  node waits until both FreeSWITCH peers are up.
- A case fails with no SIP trace: the SIPp output, every message exchanged,
  is in the CT log of the case under `_build/test/logs`.
- A stale node after a code change: `lab.sh build` recompiles into the
  volume; `lab.sh clean` starts from nothing.
- FreeSWITCH pulls are slow: pull the image the compose file pins (by
  digest) and `ghcr.io/kamailio/kamailio-ci:5.8` once, as CI does.
- The configs here are test-only (an unauthenticated SIP profile). Never copy
  them to a deployment.

See also [docs/contributing/labs.md](../../../../docs/contributing/labs.md)
and [docs/contributing/change-b2bua.md](../../../../docs/contributing/change-b2bua.md).
