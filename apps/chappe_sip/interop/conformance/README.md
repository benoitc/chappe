# Conformance lab

This lab checks chappe_sip against independent SIP stacks, one RFC flow per
case: SIPp scenarios that fail on any header the RFC requires and does not
see, pjsua for transfers and session timers, a DNS server for RFC 3263
resolution, and heplify-server for HEP capture. Run it when you change dialog,
REFER, Replaces, session timer, subscription, transport or DNS behaviour, and
before a release. CI runs it in the `conformance` job, followed by the
compliance gate.

## What it proves

`apps/chappe_sip/test/chappe_sip_conformance_SUITE.erl`, three groups:

| Group | Cases |
|---|---|
| `sipp` | OPTIONS and unknown methods, 100 Trying, rport both ways, BYE Reason, re-INVITE with and without offer, UPDATE, glare, Replaces (no match, confirmed, early), REFER (NOTIFY, event id, norefersub), session timers (negotiate, 422, refresh both sides, expiry), SUBSCRIBE and 489, presence, MWI, DNS SRV and SIPS failover |
| `pjsua` | blind and attended transfer, session timer with pjsua |
| `hep` | one call over each of UDP, TCP, TLS and WS reaches heplify-server, both directions |

Each case comment names the RFC clause and carries the `%% req:` ids it
proves, so most chappe_sip compliance rows pass only after this lab ran.

## Services

All on the docker network `chappe-conf` (`10.253.7.0/24`); nothing runs on the
host, because Docker Desktop on macOS cannot send UDP from the host to a
container.

| Container | Address | Role |
|---|---|---|
| `chappe-conf-node` | 10.253.7.10 (5060 UDP/TCP, 5061 TLS, 5066 WS with HEP) | `node/chappe_conf_node.erl` on the public chappe_sip API, compiled from your tree into the `chappe_conf_work` volume |
| `chappe-conf-dns` | 10.253.7.53 | dnsmasq with the records in `dns/dnsmasq.conf` |
| SIPp | per case; 10.253.7.30 for `dns_*` | `../sipp/run.sh` with `../sipp/scenarios/<case>.xml` |
| pjsua agents | per case | `../pjsua/agent.sh`, flows in `../pjsua/scenario.sh` |
| `chappe-conf-hep`, `chappe-conf-hepdb` | 10.253.7.40 (HEP UDP 9060) | heplify-server and its PostgreSQL, for the `hep` group |

The node is a plain endpoint. The Request-URI user picks what it does with an
INVITE: `uas` (answer), `ringing` (180, never answer), `slow` (answer after
1 s), `byer` (hang up after the ACK, with Reason), `glare` (re-INVITE after
the ACK). A MESSAGE to `dial` makes it send an OPTIONS to the URI in the body,
which is how the `dns_*` cases make it resolve.

## Run it

```sh
make interop-conformance
```

That is `CONFORMANCE=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_conformance_SUITE`.
The first run builds four images and compiles the tree; later runs recompile
what changed. `CONFORMANCE_NOBUILD=1` skips the image and compile checks.
Without `CONFORMANCE=1`, or without docker, the suite skips.

One case:

```sh
CONFORMANCE=1 rebar3 ct --suite apps/chappe_sip/test/chappe_sip_conformance_SUITE \
    --case refer_notify
```

## Keep it up and drive it by hand

The suite always removes the lab at the end. To keep one up, drive `lab.sh`
yourself:

```sh
apps/chappe_sip/interop/conformance/lab.sh images
apps/chappe_sip/interop/conformance/lab.sh build
apps/chappe_sip/interop/conformance/lab.sh up
apps/chappe_sip/interop/conformance/lab.sh sipp refer_notify
apps/chappe_sip/interop/conformance/lab.sh logs
apps/chappe_sip/interop/conformance/lab.sh logs dns
apps/chappe_sip/interop/conformance/lab.sh down
```

HEP by hand:

```sh
apps/chappe_sip/interop/conformance/lab.sh hep up
CHAPPE_HEP=10.253.7.40:9060 apps/chappe_sip/interop/conformance/lab.sh up
apps/chappe_sip/interop/conformance/lab.sh hep calls
apps/chappe_sip/interop/conformance/lab.sh hep stored <Call-ID>
```

`LAB_PROXY=http://host.docker.internal:8888` sends the build container's hex
fetches through an HTTP proxy on your machine.

## Add a case

1. Write `../sipp/scenarios/<case>.xml`. A check is an `<ereg>` with
   `check_it="true"`; follow the rules in [../sipp/README.md](../sipp/README.md)
   (literal newline at the start of the regexp, no `search_in="hdr"` for a
   check, every variable used twice).
2. If the node must behave differently, add a Request-URI user to
   `node/chappe_conf_node.erl`, on the public API only.
3. Add the case to the `sipp` group of the suite: a comment naming the RFC
   clause, a `%% req:` line, and `<case>(Config) -> sipp(?FUNCTION_NAME, Config).`
4. Run it on the code before your change. If the feature does not exist yet,
   keep the scenario strict and list the case in `expected-fail` with the
   reason.

## expected-fail

`expected-fail` lists the cases for features not built yet, one per line with
the reason. A listed case that fails is reported as skipped; one that passes
fails the run, so remove its line in the change that makes it pass. Never
weaken a scenario to make it pass.

## Troubleshooting

- `up` times out: `lab.sh logs` prints the node's output; it must print
  `chappe_conf_node up`.
- A case fails: the CT log of the case holds every message SIPp sent and
  received and the node's output for that case.
- A `dns_*` case fails: `lab.sh logs dns` shows the queries dnsmasq answered.
- TLS cases: `lab.sh build` makes throwaway certificates (a CA, the node's
  `agent.pem`, a `svcs.lab` certificate) in the `chappe_conf_certs` volume.
- The lab uses fixed container names and a fixed network: run one copy at a
  time, and `lab.sh down` if a previous run was interrupted.

See also [docs/contributing/labs.md](../../../../docs/contributing/labs.md),
[docs/contributing/add-sip-feature.md](../../../../docs/contributing/add-sip-feature.md)
and [docs/contributing/compliance.md](../../../../docs/contributing/compliance.md).
