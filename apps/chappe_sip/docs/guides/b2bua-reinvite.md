# Handle re-INVITE in a B2BUA

Once a B2BUA call is up, either side can change the session: put the call on
hold, add a stream, move its media, or just refresh it. Each change is a new
offer in a re-INVITE or an UPDATE, and `chappe_sip_b2b:relay/1,2` carries it to
the other leg. Read this when you need to see, rewrite or anchor those
offers, or react to hold.

## What relay does with each offer

- A re-INVITE or UPDATE with a new offer goes to the other leg; its answer,
  or its failure (491 included), comes back to the offering leg.
- A re-INVITE without an offer goes to the other leg without one. That leg's
  offer comes back in your 2xx, and the answer in the ACK goes on in the ACK
  to that leg.
- An UPDATE without an offer, or an offer with the `o=` version its leg sent
  last (RFC 3264 8), is a session refresh: its own leg answers it.
- While the callee rings, an UPDATE in either early dialog goes to the other
  one (RFC 3311). An offer in a PRACK is refused with 488.
- A second offer while one is pending gets 500 with Retry-After.

## Rewrite offers and answers

Give `rewrite_sdp` a 3-arity fun. It gets the leg that sent the SDP, `offer`
or `answer`, and the SDP as the leg sent it. Return the SDP to send on, or
`{reject, Code}` to refuse it.

```erlang
Rewrite = fun
    (a, offer, Sdp) -> strip_video(Sdp);
    (_Leg, _Kind, Sdp) -> Sdp
end,
{ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{rewrite_sdp => Rewrite}),
chappe_sip_b2b:relay(Legs).
```

The 2-arity `fun(Leg, Sdp)` of earlier releases still works. A refused offer
sends `Code` to the offering leg and nothing to the other one.

## Anchor every offer in rtpengine

With `media => anchor` the call's offers and answers go through one
rtpengine session, the initial ones and every re-offer from either leg, so
the media ports stay where they are for the whole call:

```erlang
chappe_sip:create_b2bua(Req, Res, Callee, #{media => anchor}).
```

When the far leg refuses an anchored re-offer, rtpengine gets that leg's last
good SDP back as the answer, so the next offer goes through. Your
`rewrite_sdp` runs before the anchor and sees each leg's own SDP.

## Late offer

An INVITE without an offer is bridged as one: B's offer comes in its 2xx
and goes to A's 2xx, and A's answer in its ACK goes on in the ACK to B.
With `media => anchor` both go through rtpengine, the offer first.

## React to hold

Pass `notify` to get an event each time an offer puts the call on hold (no
stream left receiving, RFC 3264 8.4) or takes it off:

```erlang
{ok, #{b2b := {_, Ref}} = Legs} =
    chappe_sip:create_b2bua(Req, Res, Callee, #{notify => self()}),
spawn_link(fun() -> chappe_sip_b2b:relay(Legs) end),
receive {chappe_sip_b2b, Ref, {hold, Leg}} -> play_music_to(other(Leg)) end.
```

The events are `{hold, a | b}` and `{unhold, a | b}`; `a` is the caller.

## Re-INVITE without an offer from your code

`chappe_sip_dialog:modify/3` sends one on any dialog. Its 2xx carries the
peer's offer, which you answer in the ACK:

```erlang
{ok, Offer} = chappe_sip_dialog:modify(Dialog, none, #{ack => manual}),
ok = chappe_sip_dialog:ack(Dialog, #{local_sdp => answer_to(Offer)}).
```

`ack => manual` also works with an SDP offer, when you want to send the ACK
yourself.

## SDP hooks and anchoring in detail

- B2BUA SDP and media: `rewrite_sdp => fun(Leg, offer | answer, Sdp)` sees
  each SDP with its leg and kind and may refuse it (`{reject, Code}`); the
  2-arity form still works. `media => direct | anchor | fun(CallInfo)` puts
  the call's offers and answers, re-offers included, through an rtpengine
  session; a refused anchored re-offer gives rtpengine the last good answer
  back. `chappe_sip_media:bypass/2` decides direct or anchored from the two
  sides (WebRTC, address family, NAT, private networks), and
  `chappe_sip_b2b:set_media/2` switches a live call. See
  `docs/guides/b2bua-reinvite.md` and `docs/guides/sbc.md`.

## Notes

- `relay/2` takes `rewrite_sdp`, `notify` and `anchor_params` too, over the
  ones given to `create_b2bua/4`.
- Both legs run their own session timer; refreshes stay on their leg.
- `chappe_sip_b2b:set_media/2` uses the offerless re-INVITE to switch a live
  call between direct and anchored media (see [Run an SBC](sbc.md)).

## Where it lives

- Modules: `chappe_sip_b2b_relay`, `chappe_sip_b2b_media`,
  `chappe_sip_b2b_early`, `chappe_sip_dialog` (`modify/3`, `ack/2`).
- Tests: `chappe_sip_b2b_relay_SUITE`.
- Lab: `make interop-sbc` (`apps/chappe_sip/interop/sbc`).
