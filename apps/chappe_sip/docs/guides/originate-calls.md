# Originate calls (UAC)

You place calls and send out-of-dialog requests with the UAC API. `create_uac`
originates an INVITE and returns an established dialog; `request` sends a
one-shot method (OPTIONS, MESSAGE) and returns a handle you await. Read this to
call out from enki.

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
provisionals, digest 401/407 retry, and 3xx redirects.

## Watch provisionals

To see ringing before the answer, drive the reference yourself:

```erlang
{ok, Ref} = chappe_sip_uac:start(<<"sip:bob@10.0.0.2">>, #{local_sdp => Offer}),
case chappe_sip_uac:await(Ref, 32000) of
    {ok, Dialog}    -> Dialog;
    {error, Reason} -> {error, Reason}
end.
```

## Send an out-of-dialog request

```erlang
{ok, Ref} = chappe_sip:request(<<"sip:bob@10.0.0.2">>, #{method => <<"OPTIONS">>}),
{ok, Resp} = chappe_sip_uac:await_response(Ref, 5000),
200 = chappe_sip_msg:status(Resp).
```

## 3PCC (answer with no ACK)

Originate the B leg without ACKing, so you can bridge its SDP into another leg:

```erlang
{ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => Offer, no_ack => true}).
```

## Notes

- Digest auth: pass `auth => #{user => U, pass => P}` and enki retries on
  401/407. See [Authentication](authentication.md).
- `timeout` bounds the whole attempt (default 32000 ms).
- To bridge an inbound call to an originated one, use the
  [B2BUA](b2bua.md) helper instead of wiring two dialogs by hand.
