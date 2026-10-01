# Originate calls (UAC)

You place calls and send out-of-dialog requests with the UAC API. `create_uac`
originates an INVITE and returns an established dialog; `request` sends a
one-shot method (OPTIONS, MESSAGE) and returns a handle you await. Read this to
call out from chappe_sip.

## When to use it

- You start a call (3PCC, click-to-dial, a bot) rather than answering one.
- You send an out-of-dialog OPTIONS/MESSAGE and want the response.

## Place a call

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@10.0.0.2">>, #{
    local_sdp => my_offer_sdp(),
    from      => <<"<sip:alice@example.com>">>,
    timeout   => 32000
}),
%% ... talk ...
ok = chappe_sip_dialog:destroy(Dialog).
```

`create_uac/2` returns once the call is answered (the 2xx is ACKed) or errors
(`{error, #chappe_sip_error{status = 486}}`, `{error, timeout}`, ...). It handles
provisionals, digest 401/407 retry, and 3xx redirects. When `timeout` passes
first, the INVITE is CANCELled and you get `{error, timeout}`; a 2xx that
crosses the CANCEL is ACKed and BYEd, so no call is left behind.

The dialog's `chappe_sip_dialog:remote_sdp/1` is the first SDP the callee
sent: an answer in a 183 wins over a different body in the 200 (RFC 3261
13.2.1).

## Call without an offer

Leave out `local_sdp` to send an INVITE with no offer. The 2xx then carries
the callee's offer and your answer goes in the ACK; `answer` computes it:

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@10.0.0.2">>, #{
    answer => fun(Offer) -> {ok, my_answer(Offer)} end
}).
```

Without `answer`, or when it returns anything but `{ok, Answer}`, chappe_sip
ACKs with an answer refusing every stream, sends a BYE (RFC 3261 13.2.2.4),
and `create_uac/2` returns `{error, offer_not_acceptable}`.

## Watch provisionals

To see ringing before the answer, drive the reference yourself:

```erlang
{ok, Ref} = chappe_sip_uac:start(<<"sip:bob@10.0.0.2">>, #{local_sdp => Offer}),
case chappe_sip_uac:await(Ref, 32000) of
    {ok, Dialog}    -> Dialog;
    {error, Reason} -> {error, Reason}
end.
```

## Work in an early dialog

A provisional with a To tag (180, 183, ...) forms an early dialog with that
callee (RFC 3261 12.1). You get its handle as `{early_dialog, Dialog}`, just
before the provisional itself, once per To tag (a forked call gives you
one per fork). Use it to send UPDATE before the answer (RFC 3311):

```erlang
{ok, Ref} = chappe_sip_uac:start(<<"sip:bob@10.0.0.2">>, #{local_sdp => Offer}),
Early = receive {chappe_sip_uac, Ref, {early_dialog, D}} -> D end,
{ok, _Resp} = chappe_sip_dialog:request(Early, #{
    method => <<"UPDATE">>, body => NewOffer,
    content_type => <<"application/sdp">>
}),
{ok, Dialog} = chappe_sip_uac:await(Ref, 32000).
```

- The callee's UPDATE and INFO in the early dialog reach its owner as in a
  confirmed dialog (claimed with `handled_events`, else auto-answered).
- The callee's BYE in it gets 200, and the owner gets `destroy` with the
  BYE; the INVITE still ends with the callee's final response.
- The 2xx with that To tag confirms the same handle: `Dialog =:= Early`.
  Its route set and remote target are taken again from the 2xx.
- The other early dialogs end when the INVITE gets its final response;
  their owner gets `destroy` with reason `{early_ended, Status}`.
- `chappe_sip_dialog:destroy/1` on an early handle CANCELs the INVITE, and
  `modify/2` returns `{error, early}` (no re-INVITE before the answer).

## Cancel a ringing call

`chappe_sip_uac:cancel/1` sends a CANCEL once the call rings. To say why
(RFC 3326), put a Reason on it:

```erlang
ok = chappe_sip_uac:cancel(Ref, #{headers => [{<<"Reason">>, <<"SIP;cause=200">>}]}).
```

`await/2` then returns `{error, #chappe_sip_error{status = 487}}`.

## Send an out-of-dialog request

```erlang
{ok, Ref} = chappe_sip:request(<<"sip:bob@10.0.0.2">>, #{method => <<"OPTIONS">>}),
{ok, Resp} = chappe_sip_uac:await_response(Ref, 5000),
200 = chappe_sip_msg:status(Resp).
```

## Follow redirects

Pass `follow_redirects => true` to act on a 3xx yourself rather than get it
as an error:

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@example.com">>, #{
    local_sdp => Offer, follow_redirects => true
}).
```

The Contacts of the 3xx are tried best `q` first (1.0 when absent). A
target that fails with a 4xx or 5xx, or cannot be sent to, moves on to the
next one; a 6xx ends the search. Only `sip:` and `sips:` Contacts are tried,
each URI once, and at most five 3xx are followed. A Contact's `?headers`
part is dropped: a redirect does not add headers to your request.
Credentials stay with their scheme, host and port.

## 3PCC (answer with no ACK)

Originate a leg without ACKing its 2xx, so you can take its SDP elsewhere
first (RFC 3725). Send the INVITE without an offer and with `no_ack`; the 2xx
carries the callee's offer, and `chappe_sip_dialog:ack/2` sends the ACK with
your answer once you have it:

```erlang
{ok, Ref} = chappe_sip_uac:start(Uri, #{no_ack => true}),
{ok, B} = chappe_sip_uac:await(Ref, 32000),
OfferB = chappe_sip_dialog:remote_sdp(B),
%% ... get the answer to OfferB from the other leg ...
ok = chappe_sip_dialog:ack(B, #{local_sdp => AnswerB}).
```

The ACK reuses the INVITE's CSeq number and credentials. Send it promptly:
the callee retransmits its 2xx until the ACK and gives up after 32 s.
`ack/2` returns `{error, no_pending_ack}` on a dialog with nothing left to
ACK.

## Notes

- Digest auth: pass `auth => #{user => U, pass => P}` and chappe_sip retries on
  401/407 (several realms, stale nonces, SHA-256). See
  [Authentication](authentication.md).
- A reliable provisional (`Require: 100rel` and an `RSeq`) is PRACKed through
  its route set to its Contact; one lacking either is not PRACKed.
- In-dialog requests follow the route set; behind a strict router (no `lr`)
  the first route takes the Request-URI and the remote target goes last in
  Route (RFC 3261 12.2.1.1).
- `timeout` bounds the whole attempt (default 32000 ms).
- To bridge an inbound call to an originated one, use the
  [B2BUA](b2bua.md) helper instead of wiring two dialogs by hand.
