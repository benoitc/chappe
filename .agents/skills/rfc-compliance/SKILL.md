---
name: rfc-compliance
description: Check a chappe change, commit or pull request against the RFCs and protocol specs it claims to follow (SIP RFC 3261 and its extensions, REFER and transfer, events, SIPREC, SDP, RTP, DTMF, WebSocket, plus rtpengine NG, FreeSWITCH ESL and HEP from their source). Use when reviewing a PR, before merging a protocol fix, or when asked whether code complies with a spec.
---

# RFC compliance check

Use this to decide whether a change does what the spec says, no more and no less. It
applies to one commit at a time; a PR with several commits gets one verdict per commit.

## The specs chappe follows

| Area | Specs |
|---|---|
| SIP core | RFC 3261, 3263 (locating servers), 6026 (2xx handling), 3581 (rport), 5626 (outbound), 3327 (Path), 5627 (GRUU) |
| SIP extensions | RFC 3262 (PRACK), 3311 (UPDATE), 4028 (session timers), 3326 (Reason), 3323 and 3325 (privacy, asserted identity), 8760 (digest), 7118 (SIP over WebSocket) |
| Events | RFC 6665 (updated by 7621), 3856 and 3863 (presence, PIDF), 3842 (MWI), 4235 (dialog event), 4575 (conference event) |
| REFER and transfer | RFC 3515 (updated by 7647, 8217), 7647, 3420 (sipfrag), 3891 (Replaces), 3892 (Referred-By, updated by 8217), 4488 (Refer-Sub), 7614 (explicit REFER subscriptions), 4538 (Target-Dialog), 4508 (feature tags in Refer-To), 5589 (transfer flows), 4579 (conferencing for user agents), 5368 (multiple REFER targets) |
| Recording | RFC 6341 (requirements), 7865 (metadata model), 7866 (recording protocol, updated by 9806) |
| Media description | RFC 8866 (SDP), 3264 (offer/answer), 3550 and 3551 (RTP, RTCP), 4733 (DTMF events, updated by 4734 and 5244) |
| Transport | RFC 6455 (WebSocket), the TLS version the engine negotiates |

Each app claims what it implements in `apps/<app>/docs/compliance/requirements.tsv`,
and `make compliance GATE=demo` checks the claims against the tests.

Protocols with no RFC are checked against their source, named with the version or
commit you read:

- **rtpengine NG:** the daemon's `docs/ng_control_protocol.md` and `daemon/call_interfaces.c`.
- **FreeSWITCH event socket:** `mod_event_socket.c` and the dptools apps it drives.
- **mod_audio_fork and mod_audio_stream:** each module's README and source for the
  commands and the WebSocket framing.
- **HEP:** the HEPv3 specification from sipcapture.

## 1. Get the spec text

Never quote a spec from memory. Fetch the plain text once and grep it:

```bash
mkdir -p "$SCRATCH/rfc" && cd "$SCRATCH/rfc"
for r in 3261 3515 3891 6665; do
  [ -f rfc$r.txt ] || curl -sfL https://www.rfc-editor.org/rfc/rfc$r.txt -o rfc$r.txt
done
grep -n "MUST respond to the REFER" rfc3515.txt
```

Use the session scratchpad for `$SCRATCH`, never the repo.

## 2. Check the claim

For each commit:

1. Find every spec sentence the commit message, PR body or a `%% req:` line quotes.
   Confirm it is verbatim and in the section cited.
2. Read the whole section around it, not only the sentence: exceptions, "unless", and
   the rule for the other role (UAC and UAS, notifier and subscriber, proxy and user
   agent, referrer and recipient) are usually a paragraph away.
3. Note the requirement level: MUST and MUST NOT are a fix; SHOULD needs a reason not to;
   MAY is a choice, so the change must say why it is worth it.
4. Check the status code, the header and the action (reject with 400, 420 with
   Unsupported, 481, 489, ignore, retransmit) match the text exactly.
5. Check every path that reaches the code: UDP, TCP, TLS and WebSocket; in-dialog and
   out of dialog; a forked request; a retransmission; the native engine and the
   WebSocket transaction layer, which must stay in step.
6. Check it goes no further than the spec: a new hard failure where the RFC says SHOULD
   or MAY breaks interop with peers that are allowed to do it.

## 3. Check the test

- The test fails on `origin/main` without the change and passes with it. Run it both
  ways, in a worktree at the base, never with `git stash`:

```bash
git worktree add ../chappe_base origin/main
cp apps/chappe_sip/test/chappe_sip_x_SUITE.erl ../chappe_base/apps/chappe_sip/test/
cd ../chappe_base && rebar3 ct --suite apps/chappe_sip/test/chappe_sip_x_SUITE
```

- It asserts the outcome the spec names (the status, the header, the NOTIFY sent, the
  dialog torn down) and cannot also pass on a crash or a missing response.
- It carries a `%% req:` line for each requirement it claims.

## 4. Report

One block per commit:

```
<sha> <subject>
  spec: RFC 3515 §2.4.2 MUST, quote verified | quote not found | paraphrased
  verdict: compliant | partial (<what is missing>) | wrong (<why>) | not a spec item (<what it is>)
  test: fails before, passes after | does not discriminate | missing
```

Then list anything that needs the maintainer's decision: a SHOULD left out, a deliberate
deviation, a spec defect.
