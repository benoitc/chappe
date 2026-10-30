# Control a live B2BUA call

Once `create_b2bua/4` has bridged a call, your application can still act on
it: end it with a cause, answer the in-dialog requests the far ends send,
forward DTMF INFO, move leg B to another callee, or hand the whole call to a
process of its own. Read this when the call is up and your service needs to
do more than relay it until a BYE.

## When to use it

- You end calls from your own logic (a billing limit, an operator action).
- Your service answers REFER, MESSAGE or INFO itself instead of letting the
  dialog refuse or accept them.
- You move the caller to another destination (a media server, an agent)
  without the caller seeing a re-INVITE.
- The process that set the call up must stay free, for example to drive a
  FreeSWITCH channel while the call runs.

## Get the call handle

Every control call takes the `b2b` handle that `create_b2bua/4` returns in
its result map. The process running `relay/1,2` answers these calls, so you
call them from another process.

```erlang
{ok, #{b2b := B2b} = Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{}),
Controller ! {call_up, B2b},
chappe_sip_b2b:relay(Legs).
```

Read what the call is doing:

```erlang
#{media := Mode, hold := #{a := HoldA, b := HoldB}, call_id := CallId} =
    chappe_sip_b2b:info(B2b).
```

## Hang up with a cause

`hangup/2` sends a BYE on both legs, with an RFC 3326 Reason and any extra
headers. `relay/1,2` then returns `{done, hangup}`.

```erlang
ok = chappe_sip_b2b:hangup(B2b, #{reason => <<"Q.850;cause=16">>,
                                  headers => [{<<"X-Why">>, <<"limit">>}]}).
```

## Answer in-dialog requests yourself

Name the requests you want with `requests`, and give a `notify` process.
Each one arrives as `{chappe_sip_b2b, Ref, {request, Leg, Method, Req, Res}}`,
where `Leg` is `a` or `b`. Answer it with `chappe_sip_res:send/3`.

```erlang
{ok, #{b2b := {_, Ref}} = Legs} =
    chappe_sip:create_b2bua(Req, Res, Callee,
                            #{requests => [refer, message], notify => self()}),
{ok, _} = chappe_sip_b2b:relay_async(Legs, #{}),
receive
    {chappe_sip_b2b, Ref, {request, a, refer, ReferReq, ReferRes}} ->
        _ = chappe_sip_res:send(ReferRes, 202, #{reason => <<"Accepted">>}),
        transfer(ReferReq)
end.
```

The names are `refer`, `info`, `message`, `notify` and `options`. Without a
notify process the call answers them as a dialog does: REFER 603, the
others 200.

## Forward DTMF INFO

`relay_info => true` sends an INFO from one leg (SIP INFO DTMF, RFC 6086) to
the other, and its final response back.

```erlang
chappe_sip:create_b2bua(Req, Res, Callee, #{relay_info => true}).
```

## Run the call in its own process

`relay/1,2` blocks the process that calls it. `relay_async/2` moves both
dialogs and the rtpengine session to a new process and returns the handle at
once, so your handler can go on (to drive a media server on the call, say).
Call it from the process that ran `create_b2bua/4`.

```erlang
{ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{media => anchor}),
{ok, {_Pid, Ref} = B2b} = chappe_sip_b2b:relay_async(Legs, #{notify => self()}),
drive_media_server(B2b),
receive {chappe_sip_b2b, Ref, {done, Result}} -> Result end.
```

`Result` is what `relay/2` would have returned, such as `{done, a_bye}`.

## Replace leg B

`replace_b/3` moves an anchored call to a new B. The new B gets rtpengine's
offer for A's side of the session, so A keeps its media addresses and sees
no re-INVITE. On a 2xx the old B gets a BYE; on a failure the call keeps the
old B.

```erlang
ok = chappe_sip_b2b:replace_b(B2b, <<"sip:agent7@10.0.0.40">>,
                              #{timer_c => 30000}).
```

The call must be anchored (`media => anchor`): with direct media you get
`{error, not_anchored}`, and `{error, busy}` while another offer of the call
is pending. The notify process gets `{chappe_sip_b2b, Ref, {replaced, b}}`.

To bring in a dialog you already have (a call you placed to a media
server), pass `{dialog, D}`. It gets a re-INVITE with rtpengine's offer, and
the call takes ownership of it.

```erlang
{ok, URef} = chappe_sip_uac:start(MediaServer, #{local_sdp => Sdp}),
{ok, D} = chappe_sip_uac:await(URef, 5000),
ok = chappe_sip_b2b:replace_b(B2b, {dialog, D}, #{}).
```

`anchor_params => #{b => Flags}` puts the new B on another rtpengine
interface, for example a media server on a private network.

## Hand a dialog to another process

A dialog sends its events to its owner and watches it. `set_owner/2` moves
both to another process; `on_owner_exit` then applies to the new owner.
`replace_b/3` and `relay_async/2` do this for you.

```erlang
ok = chappe_sip_dialog:set_owner(D, Pid).
```

## Notes

- A control call made from the relay process itself returns
  `{error, relay_process}`.
- `set_media/2` switches a live call between direct and anchored media; see
  [Run an SBC](sbc.md).
- A `chappe_sip_uac:abandon/2` with `headers` puts them on its CANCEL, for a
  branch you give up yourself.

## Where it lives

- Modules: `chappe_sip_b2b` (the API), `chappe_sip_b2b_relay` (the loop that
  answers these calls), `chappe_sip_b2b_requests` (`requests`,
  `relay_info`), `chappe_sip_b2b_replace` (`replace_b/3`),
  `chappe_sip_b2b_async` (`relay_async/2`), `chappe_sip_dialog`
  (`set_owner/2`).
- Tests: `chappe_sip_b2b_relay_SUITE` (`hangup_*`, `requests_*`,
  `relay_info_forwarded`, `replace_b_*`, `relay_async_outlives_handler`).
- Design: [B2BUA design](../design/b2bua.md).
- Lab: `make interop-sbc` (`apps/chappe_sip/interop/sbc`).
