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
