# Reliable provisionals (PRACK)

100rel (RFC 3262) makes a provisional response reliable: the UAS retransmits it
until the UAC confirms with PRACK. enki lets a UAS send a reliable 1xx and block
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

## UAC: advertise and auto-PRACK

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@10.0.0.2">>, #{
    local_sdp => Offer,
    rel100    => supported
}).
```

With `rel100 => supported` the UAC auto-PRACKs any reliable 1xx it receives
(building the RAck from the RSeq and the INVITE CSeq). Use `require` to demand
it.

## Notes

- The ACK keeps the INVITE CSeq; PRACKs use their own CSeq sequence.
- `await_prack/1` uses the default timeout; `await_prack/2` takes an explicit one.
