# The B2BUA subsystem

The B2BUA bridges an inbound dialog (leg A) to an outbound one (leg B) and
keeps both under your process's control. It is the largest feature built on
the dialog and UAC layers, spread over nine modules. This page is for you if
you are about to change how calls are bridged, relayed, forked or replaced.
To use the B2BUA, read the guides: [B2BUA](../guides/b2bua.md),
[forking](../guides/b2bua-forking.md),
[call control](../guides/b2bua-call-control.md) and
[re-INVITE](../guides/b2bua-reinvite.md).

## Modules

All live in `src/api/` today (see finding M5 of the
[documentation plan](https://github.com/benoitc/chappe/blob/main/docs/plans/documentation-and-maintainability.md)).

| Module | Owns |
|---|---|
| `chappe_sip_b2b` | The API: `create_b2bua/4` (set-up while B rings), `relay/1,2`, `relay_async/2`, `set_media/2`, `info/1`, `hangup/2`, `replace_b/3`, and `call/2,3`, the request channel to a running relay. |
| `chappe_sip_b2b_relay` | The relay loop: one offer at a time between the legs, in-dialog requests, hangup, replace, set_media. |
| `chappe_sip_b2b_fork` | The B-leg branches while B rings: serial and `{parallel, Dests}` (a URI or `{Uri, BranchOpts}`), the winner and the `winner` the result reports, the best final (RFC 3261 16.7), `pass_failure`, failover on 408/503. |
| `chappe_sip_b2b_early` | UPDATE between the early dialogs while B rings (RFC 3311 5.1). |
| `chappe_sip_b2b_media` | The SDP path: the app's `rewrite_sdp` hook, then the rtpengine anchor, hold detection. |
| `chappe_sip_b2b_replace` | `replace_b/3`: the new B, the swap in rtpengine, the abort. |
| `chappe_sip_b2b_requests` | The in-dialog requests the call claims (`requests`, `relay_info`). |
| `chappe_sip_b2b_async` | `relay_async/2`: moving the dialogs and the media session to a new process. |
| `chappe_sip_b2b_hdr` | Headers carried across: Reason (RFC 3326), request and response header copying, privacy (RFC 3323). |

They depend on `chappe_sip_dialog` (both legs are dialog fsms),
`chappe_sip_uac` (each B branch), `chappe_sip_media` (the anchor),
`chappe_sip_peers` (peer groups) and `chappe_sip_proxy_rules` (the 16.7
choice shared with the proxy).

## Set-up: create_b2bua/4

`create_b2bua/4` runs in the request worker that received A's INVITE, so it
can see A's CANCEL while B rings.

1. Privacy check: a `critical` Privacy level that cannot be applied gets 500
   before anything is sent (`chappe_sip_b2b_hdr:privacy_unsupported/2`).
2. Targets: `chappe_sip_b2b_fork:targets/2` turns a URI, a list, a peer
   group or `{parallel, Dests}` into branches, each with its own UAC options and media profile. No target up: 503.
3. Media: `chappe_sip_b2b_media:new/2` and `start/1` decide direct or
   anchored (`media` may be a fun of the call) and open the rtpengine
   session when anchored.
4. Offer to B: A's SDP (or `local_sdp_b`) through the hook and the anchor.
   An offerless INVITE (late offer) is bridged with B's offer in its 2xx and
   A's answer in its ACK.
5. Ringing: every provisional of every branch goes to A under one To-tag,
   with its body (early media). Timer C (default `timer_c_ms`) restarts on
   each one. Each leg does 100rel on its own.
6. The first 2xx wins; the other branches are CANCELled through
   `chappe_sip_uac:abandon/2`, and a 2xx of theirs that still comes is ACKed
   and BYEd by their UAC. A is answered with the (anchored) answer, and the
   function returns `{ok, #{uas, uac, b2b, media, ...}}`.

A failure of every branch ends in `chappe_sip_b2b_fork:fail/2`, which
answers A unless `pass_failure => false`.

## The relay loop

`relay/1,2` (`chappe_sip_b2b_relay:run/2`) runs in the process that owns
both dialogs. Both legs are created with `modify` and `update` handled by
their owner, so every offer reaches the loop. The loop:

- carries a re-INVITE or UPDATE with a new offer to the other leg, and its
  answer or failure (491 included) back;
- carries an offerless re-INVITE offerless; the other leg's offer comes back
  in our 2xx, and the answer in the ACK goes on in the ACK to that leg (the
  dialog's manual ACK, RFC 3261 14.1);
- lets a leg answer its own session refresh (an UPDATE without an offer, or
  the same `o=` version, RFC 3264 8); each leg runs its own session timer;
- answers a second offer while one is pending with 500 and Retry-After
  (RFC 3261 14.2, RFC 3311 5.2);
- hands claimed requests to the notify process
  (`chappe_sip_b2b_requests`);
- answers `{chappe_sip_b2b, Ref, {call, From, Req}}` messages sent by
  `chappe_sip_b2b:call/2,3`: `info`, `set_media`, `hangup`, `replace_b`;
- ends when a leg ends, and BYEs the other with the Reason it got.

When the far leg refuses an anchored offer, rtpengine gets that leg's last
good SDP back as the answer, so the session in rtpengine stays consistent.

## Ownership

A dialog fsm sends its events to one owner process and monitors it
(`on_owner_exit` decides what happens when it dies). The B2BUA relies on
this:

- During set-up, the owner of both legs is the request worker.
- `relay/1,2` runs in that same worker: no hand-over.
- `relay_async/2` starts a new process and moves both dialogs to it with
  `chappe_sip_dialog:set_owner/2`, and the rtpengine session with
  `chappe_sip_media:set_owner/2`. Messages the dialogs sent before the move
  are forwarded so none is lost.
- `replace_b/3` with `{dialog, D}` calls `set_owner/2` to make the relay the
  owner of the new B.

`call/2,3` from the relay process itself returns `{error, relay_process}`:
the loop cannot answer its own request.

## replace_b: how A sees no re-INVITE

rtpengine names the parties by tag: the caller is A's From tag, the callee
B's To tag. `replace_b/3` uses that:

```
 app            relay              rtpengine            new B         old B
  | replace_b ->  |                    |                  |             |
  |               |-- offer (A's tag, A's SDP) -->        |             |
  |               |<-- offer for B side ---|              |             |
  |               |-------------- INVITE (or re-INVITE) ->|             |
  |               |<------------------------------- 2xx --|             |
  |               |-- answer under leg B's tag -->        |             |
  |               |   (rtpengine keeps B's ports          |             |
  |               |    and A's ports)                     |             |
  |               |--------------------------------------------- BYE -->|
  |<-- ok --------|                    |                  |             |
```

A keeps sending to the same rtpengine address and port, and rtpengine now
forwards to the new B, so nothing needs to be renegotiated with A. When
the new B's flags mask A's codecs (rtpengine converts A, for a 16 kHz
mixer), the offer is made from A's SDP cut to the codecs A was answered
with (`chappe_sip_sdp:answered/2`), so rtpengine keeps sending A the codec
it agreed to. On a failure (`chappe_sip_b2b_replace:abort/3`) rtpengine
gets the old B's SDP back and the call goes on with the old B. If the call
ends while the new B rings, the new B is CANCELled. This needs `media => anchor`: with direct
media there is no rtpengine session to keep A's ports.

## Tests

| Suite | Covers |
|---|---|
| `chappe_sip_b2bua_SUITE` | set-up, CANCEL, Timer C, forking, `pass_failure` |
| `chappe_sip_b2b_relay_SUITE` | the relay loop, anchoring, hold, set_media, early UPDATE, hangup, requests, replace_b, relay_async |
| `chappe_sip_forked_2xx_SUITE` | late 2xx of other forks |
| `chappe_sip_webrtc_gateway_SUITE` | WS to UDP bridging |
| `chappe_sip_sbc_interop_SUITE` | the SBC lab (`make interop-sbc`) |

`chappe_sip_test_rtpe` is the rtpengine fake the relay suites use.
