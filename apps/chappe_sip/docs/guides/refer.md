# REFER (call transfer)

A REFER (RFC 3515) asks the recipient to contact a third party, typically to
transfer a call, and to report how that went with NOTIFYs in an implicit
subscription. `chappe_sip_refer` does both sides: as the recipient you accept
the REFER and report the referenced request's status; as the sender you send a
REFER and receive its progress as messages. Read this when you implement
blind or attended transfer, or a conference focus that adds or removes
participants on request (RFC 4579).

## When to use it

- A peer transfers a call to you or through you (you are the recipient).
- You transfer a call yourself (you are the sender).
- A B2BUA call carries a transfer out itself, blind or attended
  (`transfer => auto`, below).
- A conference focus handles REFERs to add (`method=INVITE`), remove
  (`method=BYE`) or refer (`method=REFER`) a participant.

## Accept a REFER inside a call

Claim the `refer` event on the dialog, validate and accept the REFER, then
report what happens to the target:

```erlang
{ok, Dialog} = chappe_sip:create_uas(Req, Res, #{handled_events => [refer]}),
receive
    {chappe_sip_dialog, Dialog, refer, RReq, RRes} ->
        case chappe_sip:accept_refer(Dialog, RReq, RRes, #{}) of
            {ok, Refer} ->
                #{target := Uri} = chappe_sip_refer:target(Refer),
                Status = dial(Uri, chappe_sip_refer:referred_by(Refer)),
                ok = chappe_sip_refer:final(Refer, Status);
            {error, {rejected, _Status}} ->
                ok
        end
end.
```

- The REFER is answered 200 (never 202, RFC 7647) with the dialog's Contact,
  and a NOTIFY `SIP/2.0 100 Trying` goes out at once.
- `chappe_sip_refer:progress(Refer, 180)` sends an `active` NOTIFY;
  `final(Refer, 200)` sends the last one, `terminated;reason=noresource`.
- NOTIFYs go out at most once a second (RFC 3515 3.10). A report that has to
  wait is replaced by a newer one; the final one is never dropped.
- The first REFER in a dialog uses `Event: refer`, later ones
  `Event: refer;id=<CSeq>` (RFC 3515 2.4.6).
- A refreshing SUBSCRIBE (`Event: refer`, with the id when there is one) is
  answered 200 with the granted Expires and a NOTIFY; `Expires: 0` ends the
  subscription with `terminated;reason=timeout`. A SUBSCRIBE naming no live
  REFER gets 403 (RFC 3515 2.4.4). You do not see these requests.
- The subscription lasts `expires` seconds (default 60) unless refreshed
  (up to `max_expires`, default 3600). If your owner process dies first, it
  ends with the last status reported.

## Validate before you act

`accept_refer/4` runs `chappe_sip_refer:check/2` and answers the rejection
itself:

| REFER                                       | Answer |
|---------------------------------------------|--------|
| zero Refer-To, or more than one              | 400    |
| malformed Refer-To (or its Replaces)         | 400    |
| more than one Referred-By                    | 400    |
| target scheme other than sip, sips, tel      | 416    |
| `method=BYE` without an `authorize` approval | 403    |
| your `authorize` fun returns false           | 403    |

Removing a conference participant (RFC 4579 5.11) needs your approval:

```erlang
Authorize = fun(#{method := <<"BYE">>}, Req) -> is_owner(Req);
               (_Target, _Req) -> true
            end,
{ok, Refer} = chappe_sip:accept_refer(Dialog, RReq, RRes,
                                      #{authorize => Authorize}).
```

The target map (`chappe_sip_hdr:refer_to/1`) gives you `target` (the URI
without method and headers), `method`, the unescaped URI `headers` (a nested
`Refer-To` for RFC 4579 5.7), and `replaces`, parsed, for an attended
transfer.

## No subscription (Refer-Sub: false)

A REFER with `Refer-Sub: false` and `norefersub` in Supported or Require
(RFC 4488) is answered 200 with `Refer-Sub: false` and gets no NOTIFY;
`progress` and `final` are no-ops. Without `norefersub` the subscription is
made and the 200 says `Refer-Sub: true`.

## Accept a REFER outside any dialog

RFC 7647 sends REFERs outside the dialog, naming it with Target-Dialog
(RFC 4538). Register a REFER handler and accept there; the 200 forms the
subscription's own dialog:

```erlang
ok = chappe_sip:refer(fun(Req, Res) ->
    case chappe_sip_refer:target_dialog(Req) of
        {ok, Call} ->
            {ok, Refer} = chappe_sip:accept_refer(Req, Res, #{}),
            transfer(Call, Refer);
        {error, _} ->
            chappe_sip_res:send(Res, 403)
    end
end).
```

`target_dialog/1` returns the live dialog the header names, or
`{error, no_target_dialog | malformed | not_found}` (a header missing a tag
is ignored, RFC 4538 4). `Require: tdialog` and `Require: norefersub` are
accepted.

## Send a REFER

```erlang
{ok, Id, #{subscription := true}} =
    chappe_sip:send_refer(Dialog, <<"sip:carol@example.com">>, #{
        referred_by => #{uri => <<"sip:alice@example.com">>}
    }),
receive
    {refer_done, Id, 200} -> transferred;
    {refer_done, Id, Status} -> {failed, Status}
end.
```

- `send_refer/3` returns once the REFER is answered; 202 counts as 200.
  A failure is `{error, {rejected, Status, Response}}`.
- Each NOTIFY is answered 200 and becomes `{refer_progress, Id, Status}`
  (still active) or `{refer_done, Id, Status}` (terminated) in the owner
  (`owner`, default the caller). A NOTIFY can beat the REFER's response; it
  is still matched.
- A NOTIFY for a REFER you do not know gets 481.

Options: `replaces => chappe_sip_hdr:replaces()` (embedded in Refer-To, for an
attended transfer), `referred_by => binary() | map()` (RFC 3892),
`refer_sub => false` (adds `Refer-Sub: false` and `Supported: norefersub`;
`subscription := false` when granted), `headers`, `timeout`. The target is a
URI, or a map for `chappe_sip_hdr:refer_to_value/1` (`method`, `headers`,
`display`).

## Send a REFER outside any dialog

Give a URI instead of a dialog, and name the dialog you transfer with
`target_dialog`:

```erlang
{ok, Id, _} = chappe_sip:send_refer(TransfereeUri, TargetUri, #{
    target_dialog => Call,
    replaces => Replaces
}).
```

The Target-Dialog carries the tags as the recipient sees them, with
`Require: tdialog`. The NOTIFYs come back outside any dialog; the stack's
NOTIFY router hands them to `chappe_sip_refer` before your own
`chappe_sip:notify/1` handler, so you need none for them.
`chappe_sip_refer:notify_handler/0` and `handle_notify/2` still work in a
handler of yours.

## Transfer a B2BUA call

When the call is a B2BUA call (`create_b2bua/4`), let the B2BUA carry the
REFER out itself. The leg that sends the REFER is the transferor; the other
leg is the transferee and keeps its media: the target replaces the
transferor's leg behind rtpengine, so the transferee sees no re-INVITE.
This needs `media => anchor`.

```erlang
{ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{
    media => anchor,
    notify => self(),
    transfer => auto,
    transfer_opts => #{domains => [<<"pbx.example.com">>]}
}),
{done, _} = chappe_sip_b2b:relay(Legs).
```

What happens on a REFER from either leg:

- The REFER is checked (as above), then the call's policy decides. It is
  answered 200 and the referrer gets `NOTIFY 100 Trying`.
- Blind (RFC 5589 6): the B2BUA INVITEs the Refer-To target on the
  referrer's side, under the identity the referrer saw on its leg, with the
  REFER's Referred-By unchanged. On a 2xx the referrer gets the final
  `NOTIFY 200`, then a BYE. On a failure it gets the final status and the
  call stays as it was.
- Attended (RFC 5589 7.3): a Refer-To with Replaces naming a leg of another
  B2BUA call, on this node or another node of the cluster (found through
  the `chappe_sip` pg scope), joins the two remote parties through rtpengine:
  the target's leg leaves its call and is re-INVITEd into this one, and no
  new INVITE goes out. A Replaces naming no local dialog goes to the target
  in an INVITE with Replaces and `Require: replaces`.
- The new leg keeps the call's `call_ref`, and its call record names it with
  `related`.

The notify process gets `{chappe_sip_b2b, Ref, Event}`:

| Event | When |
|---|---|
| `{transfer, Leg, Info}` | the REFER was accepted |
| `{replaced, Leg}` | the target took the leg over |
| `{transferred, Leg, Info}` | the referrer heard the result and was hung up |
| `{transfer_failed, Leg, Info}` | the target failed; `Info` has `status` |

### Decide who may transfer where

Without a policy fun, a target must be a sip or sips URI with a user, on
one of `domains`, and without `maddr`; anything else gets 403 before
anything is called:

- A domain given as `<<"pbx.example.com">>` takes any port;
  `<<"pbx.example.com:5080">>` takes only that one.
- Without `domains`, the target must be this node at one of its own listen
  addresses, port included, so your INVITE handler routes it.
- `maddr` would send the INVITE elsewhere than the host you allowed.
- The target's 3xx is not followed: the transfer fails with that status.

Give your own policy to decide:

```erlang
Policy = fun(#{target := Target, referrer := Who}) ->
    allowed(Who, Target)
end,
Opts = #{media => anchor, transfer => auto,
         transfer_opts => #{policy => Policy, max_transfers => 3}}.
```

The fun gets `kind` (`blind` or `attended`), `leg`, `target`, `refer_to`,
`referrer`, `referred_by`, `principal`, `call_ref` and `transfers` (and
`local` and `replaces_principal` for an attended transfer), and returns `true`,
`false` (403) or `{reject, Code}`. It runs in the transfer's process, on
the node that holds the call.

- `referrer` is the REFER's From, the identity its dialog was formed with.
  `referred_by` is only what the REFER claims (RFC 3892 6): never grant on
  it alone.
- An attended transfer that joins two calls of this node needs proof that
  the referrer is the party it replaces (RFC 3891 3). Record who your app
  authenticated on each leg with `create_b2bua/4`'s `principal => #{a | b
  => Who}`: without a policy fun, the join goes ahead only when the
  referrer's leg and the leg the Replaces names carry the same principal,
  and gets 403 otherwise, that call left alone. A policy fun sees them as
  `principal` and `replaces_principal`. The REFER's From is never enough:
  nothing authenticated it.
- A call carries at most `max_transfers` transfers (default 5), one at a
  time: a second REFER while one runs gets 500 with Retry-After.
- A REFER for another method than INVITE gets 403. A REFER with
  `Require: multiple-refer` (RFC 5368) gets 420 with Unsupported.

### Decide each transfer in your app

With `transfer => notify` your notify process gets each REFER first:

```erlang
receive
    {chappe_sip_b2b, Ref, {refer, #{target := Target} = Info}} ->
        case allowed(Target) of
            true -> ok = chappe_sip_b2b_transfer:accept(Info, #{});
            false -> ok = chappe_sip_b2b_transfer:reject(Info, 403)
        end
end.
```

`accept/2` takes `target => Uri` to send the transferee elsewhere (a blind
transfer then). Without an answer within `transfer_opts` `timeout` (10000
ms) the REFER gets 603. Both calls work from any node.

### Calls to FreeSWITCH and conferences

- A chappe_mrf call (`chappe_mrf:connect_caller/3` with `transfer => auto`)
  is a B2BUA call: a REFER from the FreeSWITCH side (a deflect) is carried
  out by chappe, the channel gets the final NOTIFY and a BYE, and the
  caller sees neither the REFER nor a re-INVITE.
- A conference member's REFER on its call is a transfer of that call: the
  target takes the member's place, on either backend.
- A REFER to the focus (RFC 4579) goes through `chappe_sip_focus:refer/4`:

```erlang
case chappe_sip_focus:refer(Dialog, RReq, RRes, #{policy => Policy}) of
    {add, Uri, Refer} -> dial_in(Uri, Refer);
    {remove, Uri, Refer} -> kick(Uri, Refer);
    {error, _} -> ok
end.
```

`add` is a Refer-To for an INVITE (5.5), `remove` one with `method=BYE`
(5.11). The policy gets `action`, `target`, `referrer` and `referred_by`;
without one both are refused 403. Report with `chappe_sip_refer:final/2`.

## REFER behaviour in detail

- REFER (RFC 3515 as updated by RFC 7647), both sides, in `chappe_sip_refer`
  (facade: `chappe_sip:accept_refer/3,4`, `send_refer/3`). Recipient: 400 for
  zero or several Refer-To, 416 for a non sip/sips/tel target, an `authorize`
  hook (required for `method=BYE`, RFC 4579 5.11), 200 never 202, the implicit
  subscription with message/sipfrag NOTIFYs, `Event: refer;id=<CSeq>` from
  the second REFER in a dialog, refresh/unsubscribe by SUBSCRIBE (403 for an
  unknown id), expiry, at most one NOTIFY a second with the final one never
  dropped, `Refer-Sub: false` with `norefersub` (RFC 4488), Target-Dialog
  lookups (RFC 4538) for out-of-dialog REFERs, Replaces and nested Refer-To
  in the target. Sender: in or out of dialog, Referred-By (RFC 3892), Replaces,
  Refer-Sub, Target-Dialog; NOTIFYs become `{refer_progress, Id, Code}` and
  `{refer_done, Id, Code}`, unknown ones get 481. `chappe_sip_sipfrag` builds
  and parses message/sipfrag (RFC 3420). See the REFER guide.

## Notes

- `chappe_sip_sipfrag` builds and parses the message/sipfrag bodies
  (`build(200)` is `<<"SIP/2.0 200 OK\r\n">>`).
- The Contact of the REFER's 200 is the stack's contact, not a GRUU
  (RFC 7647 3 asks for one); chappe_sip has no GRUU support.
- Inside a dialog, the REFER package's SUBSCRIBEs and NOTIFYs only reach
  `chappe_sip_refer` once it has accepted or sent a REFER in that dialog;
  before that they go to the owner as usual.

## Where it lives

- Modules: `chappe_sip_refer`, `chappe_sip_refer_sub`,
  `chappe_sip_refer_registry`, `chappe_sip_sipfrag`,
  `chappe_sip_notify_router`, `chappe_sip_b2b_transfer`,
  `chappe_sip_b2b_sup`, `chappe_sip_focus`.
- Tests: `chappe_sip_refer_SUITE`, `chappe_sip_sipfrag_tests`,
  `chappe_sip_b2b_transfer_SUITE`, `chappe_sip_focus_SUITE`,
  `chappe_mrf_SUITE` (`fs_refer_transfers_caller`).
- Lab: the conformance lab (`make interop-conformance`): `b2b_refer_refused`
  (SIPp), `pjsua_b2b_refer_blind` and `pjsua_b2b_refer_attended`.
