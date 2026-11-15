---
name: protocol-change-review
description: Run the three required checks (compliance, latest specification, safety) on a chappe change, commit or pull request that touches SIP messages, transactions, dialogs, the B2BUA or proxy, REFER and transfer, events and subscriptions, registration and auth, SIPREC, SDP and offer/answer, RTP or DTMF handling, the WebSocket transport, the sofia NIF, or the rtpengine, FreeSWITCH ESL and HEP protocols. Use before committing, before opening or merging a PR, and when reviewing a lane's or a contributor's work.
---

# Protocol change review

chappe talks to untrusted peers: phones, carriers, browsers, and whatever reaches its
listening ports. A change is done when it matches the spec, the spec is the current one,
and a hostile peer cannot use it. Run the three checks below on each commit; a PR with
several commits gets one verdict per commit. The spec list is in the
[rfc-compliance](../rfc-compliance/SKILL.md) skill.

## 1. Compliance

Follow the [rfc-compliance](../rfc-compliance/SKILL.md) skill: fetch the spec text, check
every quoted sentence and the section around it, the requirement level, the status code
and the action, and every path that reaches the code (each transport, in and out of a
dialog, forked and retransmitted requests, the native engine and the WebSocket layer).

Then run what the change touches (commands in `AGENTS.md` and `docs/contributing/`):

- always `make check`, and `make compliance GATE=demo`;
- SIP behaviour: `make interop-conformance` (SIPp, pjsua, DNS), `make interop` (JsSIP,
  Kamailio), `make interop-sbc`;
- media: `make interop-mrf`, `make interop-esl`, `make interop-mix`, and the rtpengine
  suites;
- the C engine: `make asan`, `make tsan`, `make lint-c`, `make fuzz`, on a fresh
  `NIF_VOLUME` when the NIF changed.

## 2. Latest specification

1. Name the governing document and confirm it is current on
   https://datatracker.ietf.org/doc/rfcNNNN/ ("Obsoleted by", "Updated by"), or
   `https://www.rfc-editor.org/rfc/rfcNNNN.json`. Read an updating RFC's changes to the
   section you rely on: for example RFC 7647 changes how REFER uses RFC 6665, RFC 8217
   changes the name-addr rules of RFC 3515 and RFC 3892, and RFC 9806 updates RFC 7866.
2. For a draft, check the latest revision on datatracker and read the section in that
   revision.
3. Check for errata on https://www.rfc-editor.org/errata/rfcNNNN.
4. For a protocol with no RFC (rtpengine NG, FreeSWITCH ESL, mod_audio_fork,
   mod_audio_stream, HEP), name the version or commit of the source you read, and check
   it against the version the labs run.
5. Write the versions and the date checked in the PR description. If the latest text
   disagrees with the code, fix it in the change or say in the PR that it is out of
   scope, and record it as an open compliance row.

## 3. Safety

Walk the classes that apply and state which you checked.

- **Amplification:** a response larger than the request it answers over UDP, DNS
  lookups an attacker can trigger, forks and redirects a single request can fan out to.
- **Floods:** INVITE, REGISTER, SUBSCRIBE, OPTIONS and NOTIFY floods; retransmission
  storms; re-INVITE and UPDATE churn on one dialog. The guard's rate limits and the
  blocklist must apply before work is done.
- **Resource exhaustion:** dialogs, transactions, subscriptions, registrations per AOR,
  forks per call, header count and size, body size, multipart parts, media streams,
  queued frames and events. A peer must not grow any of them without a bound set by the
  spec or an option.
- **Spoofing:** Via, rport and the source address; a NOTIFY or a BYE from someone who is
  not the dialog's peer; Replaces and Target-Dialog naming a dialog the sender is not
  part of.
- **Authentication:** digest nonce reuse, replay and algorithm downgrade; realm checks;
  TLS certificate and hostname checks; a request authenticated once and reused.
- **Loops:** Max-Forwards, spirals through the proxy, a REFER or a redirect pointing back
  at the PBX, a transfer that transfers again.
- **Toll fraud:** open relay; REFER, 3xx, forward and Refer-To toward a number the caller
  may not reach; Referred-By trusted as identity. Every transfer target goes through the
  app's policy.
- **Privacy:** recording and SIPREC metadata, Privacy and P-Asserted-Identity removed at
  a trust boundary, recordings and logs holding personal data.
- **The NIF boundary:** sizes, embedded NULs and lengths checked before sofia sees them
  (`apps/chappe_sip/docs/design/engine.md`, "Safety rules").

Never weaken a limit to let a legitimate peer pass; exclude that case precisely. A
regression test for an attack drives it over a real transport or through the parser and
asserts the bound, the response or the drop.

A finding from this check is a bug when its fix is to follow the spec, even if it is an
amplification, exhaustion or crash vector: a public PR, a CHANGELOG entry under its fix
with the spec section, no advisory and no attack description. Authentication bypass and
key or credential handling stay security issues and are reported privately.

## Report

One block per commit, in the PR description or the hand-off:

```
<sha> <subject>
  spec: RFC 3515 §2.4.4 MUST, quote verified | not found | paraphrased
  latest: RFC 3515 updated by 7647 and 8217, read (checked 2026-11-14)
  verdict: compliant | partial (<missing>) | wrong (<why>) | not a spec item
  test: fails before, passes after | does not discriminate | missing
  interop: labs run, result
  safety: <classes checked>, <bounds>, no new unbounded state
  erlang: chappe-erlang-patterns checked (supervisor, owner, pg, bound, tests)
```

Then list what needs the maintainer's decision: a SHOULD left out, a deliberate
deviation, a spec update that is out of scope.
