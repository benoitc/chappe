# Change B2BUA behaviour

The B2BUA bridges an inbound INVITE (leg A) to an outbound one (leg B) and then
relays what each side sends to the other. Its code is split over nine modules
that share one call process. Read this page before you change how a call is
set up, forked, relayed, anchored, replaced or hung up.

## Before you start

- [glossary.md: A leg and B leg](../glossary.md#a-leg-and-b-leg) and
  [Anchor and direct media](../glossary.md#anchor-and-direct-media).
- [apps/chappe_sip/docs/design/b2bua.md](../../apps/chappe_sip/docs/design/b2bua.md):
  the subsystem, the relay loop, `replace_b`.
- The user guides [b2bua.md](../../apps/chappe_sip/docs/guides/b2bua.md),
  [b2bua-reinvite.md](../../apps/chappe_sip/docs/guides/b2bua-reinvite.md) and
  [sbc.md](../../apps/chappe_sip/docs/guides/sbc.md).

## Where to look

All in `apps/chappe_sip/src/api/`:

| Module | Owns |
|---|---|
| `chappe_sip_b2b` | the API: `create_b2bua/4`, `relay/1,2`, `relay_async/2`, `set_media/2`, `info/1`, `hangup/2`, `replace_b/3`; call setup while B rings, Timer C |
| `chappe_sip_b2b_relay` | the relay loop once both legs are up: re-INVITE, UPDATE, glare, BYE |
| `chappe_sip_b2b_async` | `relay_async/2`: the relay loop in a process of its own |
| `chappe_sip_b2b_fork` | the B branches of a `{parallel, Dests}` target |
| `chappe_sip_b2b_early` | UPDATE in early dialogs (RFC 3311 5.1) |
| `chappe_sip_b2b_media` | the SDP path: the app's `rewrite_sdp` hook, then rtpengine when anchored |
| `chappe_sip_b2b_replace` | `replace_b/3`: a new B behind rtpengine, A sees no re-INVITE |
| `chappe_sip_b2b_requests` | in-dialog requests other than offers (INFO, MESSAGE, NOTIFY, ...) |
| `chappe_sip_b2b_hdr` | the headers carried from one leg to the other (Reason, ...) |

The media anchor goes through `chappe_sip_media` (`apps/chappe_sip/src/media/`).
Proxy forking is a different path (`chappe_sip_proxy`); the B2BUA fork shares
only the best-final rule with it.

## Steps

1. Find the module from the table. A change to what happens after the 2xx is
   almost always in `chappe_sip_b2b_relay`; one before the 2xx is in
   `chappe_sip_b2b` or `chappe_sip_b2b_fork`.
2. Write the case first, in the suite that covers that phase (below), and run
   it against the current code to see it fail.
3. Change the code. Keep header grammar in `chappe_sip_hdr`, URIs in
   `chappe_sip_uri`, tags in `chappe_sip_dialog`: do not copy a helper into a
   b2b module.
4. If the change is visible to users (a new option, a new event, a new
   status), update the guide and see [extend-public-api.md](extend-public-api.md).
5. If it closes an RFC requirement, claim the row: [compliance.md](compliance.md).

## Tests to add or run

| Suite | Covers |
|---|---|
| `chappe_sip_b2bua_SUITE` | setup, failures, CANCEL, Timer C, parallel forking, `pass_failure` |
| `chappe_sip_b2b_relay_SUITE` | relay once up and while ringing: re-INVITE, UPDATE, glare, early media, 100rel, Reason, refreshes; `rewrite_sdp`, anchoring and `set_media` against `chappe_sip_test_rtpe`; `hangup/2`, claimed requests, `relay_info`, `replace_b/3`, `relay_async/2` |
| `chappe_sip_webrtc_gateway_SUITE` | a WebSocket A leg to a UDP B leg |
| `chappe_sip_cdr_SUITE` | the `b2b_a` and `b2b_b` records |
| `chappe_sip_peers_SUITE` | B targets from a peer group, failover |

The peers are scripted `gen_udp` sockets (`chappe_sip_test_ua`,
`chappe_sip_raw_peer`); `chappe_sip_test_rtpe` is a fake rtpengine that marks
the SDP it rewrote (`a=rtpe-offer:<from-tag>`), so a case can tell which SDP
went through the anchor.

```sh
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_b2b_relay_SUITE
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_b2bua_SUITE --case <case>
```

## How to know it works

- The suites above and `make check` pass.
- `make interop-sbc` passes: real FreeSWITCH peers, rtpengine and SIPp, with
  direct and anchored calls, hold both ways, glare, `set_media` both ways, a
  session refresh, `replace_b` and failover. See the
  [SBC lab](../../apps/chappe_sip/interop/sbc/README.md).
- For a change to SDP passthrough over WebSocket, the JsSIP call of
  `chappe_sip_interop_SUITE` ([labs.md](labs.md)).

## Notes

- Both legs are created with `modify` and `update` handled by their owner, so
  the owner must run `relay/1,2` or answer those events itself.
- Anchored, every fork branch answers the same rtpengine offer under its own
  To-tag; rtpengine drops the losers' early sessions once one answers.
- `replace_b/3` needs an anchored call: the new B's SDP is answered by
  rtpengine, not by A.

## Related

- [debug-a-call.md](debug-a-call.md)
- [add-media-backend.md](add-media-backend.md)
- [add-sip-feature.md](add-sip-feature.md)
