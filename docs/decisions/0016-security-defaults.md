# 0016: Security defaults

This record lists the defaults chappe ships so that a node is closed until
you open it: the ESL listener on loopback, sofia's own WebSocket transport
never built, the OTP floor, the distribution cookie check, and the
advisory gate. Read it before you change a listener's default address, a
configure flag of sofia, `minimum_otp_vsn`, or the advisory workflow.

## Status

Accepted. It records the code as merged (#36 and the security entries of
`CHANGELOG.md`, "Unreleased").

## Context

What the repository shows:

- **The ESL outbound listener.** It listens on 127.0.0.1 unless you give
  `ip` (`maps:get(ip, Opts, {127, 0, 0, 1})` in
  `apps/chappe_esl/src/chappe_esl_listener.erl`, the `listener_opts()` doc
  in `chappe_esl.erl`). With `allow`, a list of CIDR networks parsed by
  `chappe_esl_cidr`, a peer outside is closed and counted before any byte
  is read or any process started; an empty list is refused
  (`valid_listener_value/2` in `chappe_esl.erl`). A peer that does not send
  its channel data within `first_frame_timeout` (5000 ms) is closed, and
  new connections past `max_pending` (64) waiting ones are closed as busy.
  chappe_mrf passes its `esl_ip` and `esl_allow` env as `ip` and `allow`
  (`apps/chappe_mrf/src/chappe_mrf_esl.erl`).
- **sofia's WebSocket transport.** sofia is configured with
  `--disable-nth`, "the only switch for sofia's ws, wss and HTTP CONNECT
  transports", since "chappe serves WebSocket in Erlang and links none of
  them" (`apps/chappe_sip/c_src/build.sh`). A native or TLS contact naming
  `ws`, `wss` or `*` is refused with `badarg`, and one naming no transport
  binds `udp,tcp` (`tls` for `sips:`)
  (`apps/chappe_sip/src/engine/chappe_sip_bind_uri.erl`). The CHANGELOG
  records a memory corruption in that transport (CVE-2026-116791).
- **The OTP floor.** Every `rebar.config` sets
  `{minimum_otp_vsn, "29.1.2"}`. The root `rebar.config` names the reason:
  "Older OTP 29 releases have TLS CVEs (CVE-2026-89422 before 29.1.1,
  CVE-2026-105236 before 29.1.2)."
- **The distribution cookie.** `chappe_sip_app:start/2` refuses to boot
  with `{error, insecure_distribution_cookie}` when the cookie is the
  shipped placeholder or the historical default (`insecure_cookie/1`): "a
  reachable node with a known cookie is remote code execution".
- **The advisory gate.** `.github/workflows/advisories.yml` runs on every
  push and pull request to main and weekly. It checks the vendored
  sofia-sip version against sofia-sip's GitHub security advisories, and
  each hex package of `rebar.lock` against osv.dev
  (`scripts/advisories.py`, tested by `scripts/advisories_test.py`).
- `verify_none` and permissive TLS are test-only (`AGENTS.md`,
  `CONTRIBUTING.md`).

## Decision

- The listeners FreeSWITCH connects to bind loopback unless you give them
  an address: the ESL listener, and the chappe_audio listener ("nothing is
  exposed unless you say so", the `listen_opts()` doc in
  `apps/chappe_audio/src/chappe_audio.erl`). The ESL listener, which hands
  out calls, also takes an allow list.
- sofia's WebSocket and HTTP code is not built. WebSocket is served in
  Erlang only ([0007](0007-ws-transaction-layer.md)).
- chappe refuses to build on an OTP with a known TLS flaw it is exposed to,
  and refuses to boot with a known cookie.
- Third-party code is checked against published advisories on every change
  and weekly; a hit fails the job.

## Consequences

- When FreeSWITCH runs on another host, you set the listener's address and
  the networks FreeSWITCH connects from (`ip` and `allow`, or chappe_mrf's
  `esl_ip` and `esl_allow`). Before #36 it listened on every interface.
- A contact that named `ws`, `wss` or `*` fails the start; use the `ws`
  and `wss` options of `chappe_sip:start/1` for WebSocket.
- A new OTP advisory that reaches chappe is answered by raising
  `minimum_otp_vsn` in every `rebar.config`, as #36 did.
- A new advisory against sofia-sip or a locked hex package fails CI until
  you update the dependency or, for hex, list it as accepted with a reason
  (`advisories.py hex REBAR_LOCK [ACCEPTED]`).

## Open questions

- The workflow's hex job passes no accepted list today
  (`advisories.yml`), so an accepted advisory has no home yet.
