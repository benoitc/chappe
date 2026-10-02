# SIPp conformance scenarios

One SIPp scenario per RFC flow, run against the chappe node of the
conformance lab by `chappe_sip_conformance_SUITE` (see
`docs/guides/interop-testing.md`). You read this when you add or change a
scenario.

## Run one

```sh
apps/chappe_sip/interop/conformance/lab.sh up
apps/chappe_sip/interop/conformance/lab.sh sipp glare
```

`run.sh` prints every message SIPp sent and received, then the SIPp error
log, and exits 0 only if the call went through the whole scenario.

## Write a check

A check is an `<ereg>` action with `check_it="true"`: a regexp that does
not match fails the call. Check headers in the whole message, anchored at
the start of a line:

```xml
<ereg regexp="
Refer-Sub[ 	]*:[ 	]*false" search_in="msg" check_it="true" assign_to="chk"/>
```

Notes:

- The regexp starts with a literal newline (and uses literal tabs). SIPp
  does not decode character references such as `&#10;` in attributes.
- Do not use `search_in="hdr"` for a check: SIPp finds the header by
  substring, so `header="Allow-Events:"` also matches `X-Allow-Events:`
  and `header="To:"` matches `Refer-To:`. It is fine for capturing a value
  to reuse (a Via to answer later).
- POSIX `.` matches a newline here; write `[^` newline `]*` to stay on the
  header's line.
- Every variable must be used twice or SIPp refuses the scenario; end the
  file with `<Reference variables="chk"/>`.
- A scenario for a feature chappe lacks stays strict: list the case in
  `../conformance/expected-fail` instead of loosening it.

## DNS cases

The `dns_*` cases test RFC 3263 resolution. `lab.sh sipp` runs their
container at `10.253.7.30`, the address the lab's DNS records
(`../conformance/dns/dnsmasq.conf`) point at, so it can play the
destination. `CASE.xml` sends a MESSAGE to `sip:dial@<node>` whose body is
the URI to dial; the node sends an OPTIONS there and answers the MESSAGE
with the status it got.

- `dns_srv`: SIPp listens on UDP 5080 (`dns_srv-target.xml`), the SRV port.
- `dns_sips_failover`: socat takes TLS on 5061 with the lab's `svcs.lab`
  certificate and `tls_target.sh` answers, because SIPp's own TLS listener
  fails to send its answers.
