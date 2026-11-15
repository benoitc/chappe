# Follow a call

Every call chappe handles has one `call_ref`, an opaque binary that ties its
SIP legs, its dialogs, its rtpengine session, its call records and its HEP
capture together. Use it when you need to find a call again (from an
operator console, from another node of your cluster, from a billing or a
capture search) without tracking each leg's Call-ID yourself.

## Where the ref comes from

The stack makes one when the first request of a call arrives. Your handler
reads it from the request:

```erlang
handle(Req, Res) ->
    Ref = chappe_sip_req:call_ref(Req),
    logger:info("call ~s", [Ref]),
    {ok, Legs} = chappe_sip:create_b2bua(Req, Res, <<"sip:bob@10.0.0.2">>, #{}),
    chappe_sip_b2b:relay(Legs).
```

When an upstream node already named the call (an `X-Call-Ref` header you
trust, say), give that ref instead. It must be a token of 1 to 128
characters, or the call is refused with `{error, badarg}`:

```erlang
handle(Req, Res) ->
    Opts =
        case chappe_sip_req:get(<<"x-call-ref">>, Req) of
            undefined -> #{};
            Up -> #{call_ref => Up}
        end,
    {ok, Legs} = chappe_sip:create_b2bua(Req, Res, <<"sip:bob@10.0.0.2">>, Opts),
    chappe_sip_b2b:relay(Legs).
```

A middleware can do the same for every handler with
`chappe_sip_req:set_call_ref/2`. `create_uas/3` and `create_uac/2` take a
`call_ref` option too; an INVITE you originate without one gets its own.

## Where the ref appears

| Where | What you see |
| --- | --- |
| the request | `chappe_sip_req:call_ref(Req)`, the dialog's ref on in-dialog requests |
| the B2BUA | `call_ref` in the `create_b2bua/4` result and in `chappe_sip_b2b:info/1` |
| each INVITE the call sends | an `X-Chappe-Call: Ref` header (B leg, a `replace_b/3` callee, a `create_uac/2` call) |
| call records | `call_ref` in every record of the call, both B2BUA legs included |
| HEP | a log packet (type 100) per Call-ID, once under the Call-ID and once under the ref |

The INVITE to B never copies A's own `X-Chappe-Call`: A's header names the
upstream call. When your `b_headers` carry an `X-Chappe-Call`, yours goes
instead of the ref. Set `call_ref_header => false` to send none.

## Find a call from any node

```erlang
{ok, #{b2b := B2bs, dialogs := Dialogs, media := Sessions}} =
    chappe_sip:calls(#{call_ref => Ref}).
```

Each list holds the handles of the processes that serve the call right now,
on every node of the cluster: the B2BUA (a `chappe_sip_b2b:b2b()` for
`info/1`, `hangup/2`, `replace_b/3`), the dialogs and the rtpengine sessions.
A process is listed while it serves the call and leaves when it ends.
The handles work from the node that looked them up:

```erlang
hangup_call(Ref) ->
    case chappe_sip:calls(#{call_ref => Ref}) of
        {ok, #{b2b := [B2b | _]}} ->
            chappe_sip_b2b:hangup(B2b, #{reason => <<"Q.850;cause=16">>});
        {ok, _} ->
            {error, not_found}
    end.
```

## Search the call records

```erlang
init() ->
    ok = chappe_sip_cdr:subscribe(self()),
    loop().

loop() ->
    receive
        {chappe_sip_cdr, stop, #{call_ref := Ref} = Record} ->
            store(Ref, Record),
            loop()
    end.
```

Index your store by `call_ref`: both legs of a B2BUA share it, and a leg a
transfer brings in carries the transferred call's ref, with `related`
naming the call it came from.

## Search the capture

With HEP on, each Call-ID of the call gets two log packets whose payload is
`{"call_ref": Ref, "call_id": CallId, "role": "uas" | "uac"}`. A collector
such as heplify-server stores them by correlation id: search the logs for
the ref to get every Call-ID of the call, then open those calls.

## Notes

- The lookup uses `pg` in the `chappe_sip` scope, which chappe_sip starts
  and stops with itself. A node joins the cluster's lookups once it runs
  chappe_sip and is connected.
- A lookup can be briefly stale: a process that just ended may still be
  listed for a moment. Its handle then answers `{error, noproc}`.
- B2BUA events keep their `{chappe_sip_b2b, Ref, Event}` shape: map the
  event's reference to the call with the `b2b` handle of the result.

## Where it lives

- Modules: `chappe_sip_call` (the ref, the lookup), `chappe_sip_req`,
  `chappe_sip_b2b`, `chappe_sip_uac_fsm`, `chappe_sip_cdr`, `chappe_sip_hep`.
- Tests: `chappe_sip_call_SUITE`.
