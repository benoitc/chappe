# Reliable provisionals (PRACK)

100rel (RFC 3262) makes a provisional response reliable: the UAS retransmits it
until the UAC confirms with PRACK. chappe_sip lets a UAS send a reliable 1xx and block
for the PRACK, and a UAC advertise 100rel and auto-PRACK. Read this when a
provisional carries state (early media SDP) that must not be lost.

## When to use it

- Your UAS sends early media (a 183 with SDP) and must know the caller received
  it before proceeding.
- You interop with a peer that requires 100rel.

## UAS: send a reliable 1xx

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    Tag = chappe_sip_dialog:gen_tag(),
    ok = chappe_sip_res:send_reliable(Res, #{status => 183, to_tag => Tag,
                                       local_sdp => early_media()}),
    {ok, _PrackBody} = chappe_sip_res:await_prack(Res),
    %% the 200 reuses the early dialog's tag
    {ok, Dialog} = chappe_sip:create_uas(Req, Res, #{local_tag => Tag,
                                               local_sdp => answer()}),
    chappe_sip_dialog:wait(Dialog)
end).
```

`send_reliable/2` sends the 1xx with an RSeq and a To-tag (the early dialog);
`await_prack/2` blocks until the matching PRACK arrives (nta owns RSeq/RAck,
retransmit, and PRACK matching). The final 2xx reuses that tag via `local_tag`.

## UAS: answer an offer in the PRACK

A caller may put a new offer in its PRACK (RFC 3262 5). `await_prack/2` then
returns `{offer, Prack, PrackRes}` and you answer on `PrackRes` with a 2xx
carrying your SDP:

```erlang
case chappe_sip_res:await_prack(Res, 8000) of
    {ok, _Prack} ->
        ok;
    {offer, Prack, PrackRes} ->
        Answer = answer_to(chappe_sip_msg:body(parse(Prack))),
        ok = chappe_sip_res:send(PrackRes, 200, #{
            body => Answer,
            headers => [{<<"Content-Type">>, <<"application/sdp">>}]
        })
end.
```

A PRACK without a body is answered 200 by the stack. A PRACK for a 1xx that
was already PRACKed, or naming no reliable 1xx, gets 481.

When the INVITE has no offer, your first reliable 1xx must carry one: a
reliable 1xx without a body is not sent until then. The caller's answer comes
in the PRACK, which the stack answers 200; `await_prack/2` returns it as
`{ok, Prack}`.

## UAC: advertise and auto-PRACK

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@10.0.0.2">>, #{
    local_sdp => Offer,
    rel100    => supported
}).
```

With `rel100 => supported` the UAC auto-PRACKs any reliable 1xx it receives
(building the RAck from the RSeq and the INVITE CSeq). Use `require` to demand
it; `Require: 100rel` only goes on an INVITE.

Reliable 1xx are taken in RSeq order per early dialog: a retransmission or a
1xx that skips an RSeq is dropped, not PRACKed and not reported. When your
INVITE has no offer and the reliable 1xx brings one, the PRACK carries the
answer your `answer` fun returns, and the ACK then has no body:

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@10.0.0.2">>, #{
    rel100 => supported,
    answer => fun(Offer) -> {ok, answer_to(Offer)} end
}).
```

## Notes

- The ACK keeps the INVITE CSeq; PRACKs use their own CSeq sequence.
- `await_prack/1` uses the default timeout; `await_prack/2` takes an explicit one.

## Where it lives

- Modules: `chappe_sip_res` (`send_reliable/2`, `await_prack/1,2`),
  `chappe_sip_uac_fsm` (auto-PRACK), the PRACK path of the NIF (`prack_cb`).
- Tests: `chappe_sip_prack_SUITE`, `chappe_sip_prack_conf_SUITE`.
- Lab: `make interop-conformance`.
