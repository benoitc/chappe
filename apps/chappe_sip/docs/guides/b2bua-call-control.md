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
        %% 200, never 202 (RFC 7647 5)
        _ = chappe_sip_res:send(ReferRes, 200, #{reason => <<"OK">>}),
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

The call has no owner unless you name one: `owner => Pid` hangs it up when
`Pid` dies. The notify process is never the owner by default, since it is
often the handler that made the call and returns at once.

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

### Show the caller to the new B

Without `from`, the INVITE to the new B names your node, so a phone rung after
a menu shows the PBX. Pass the caller's identity, as for `create_b2bua/4`:

```erlang
ok = chappe_sip_b2b:replace_b(B2b, <<"sip:agent7@10.0.0.40">>,
                              #{from => <<"\"Alice\" <sip:alice@example.com>">>}).
```

- It applies to a URI and to every destination of `{parallel, Dests}`; a
  destination has no `from` of its own.
- Leave out the tag: each INVITE adds its own.
- `create_b2bua/4` falls back to A's name and URI, anonymous under user or
  header privacy. `replace_b/3` has no such default, and what you pass goes
  out as it is, so apply the caller's privacy before you set it.
- `{dialog, D}` ignores it: a re-INVITE keeps the identity of its dialog.
- A malformed value returns `{error, badarg}` for any target, and the call
  goes on.

### Ring several destinations

After an IVR, a user with a desk phone and a browser rings on both. Pass
`{parallel, Dests}`, with the same destinations as `create_b2bua/4`: a URI,
or `{Uri, #{flow, headers, anchor_params}}`.

```erlang
{ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@example.com">>),
Dests = [{Uri, #{flow => Flow}}, <<"sip:bob-desk@10.0.0.40">>],
case chappe_sip_b2b:replace_b(B2b, {parallel, Dests}, #{timer_c => 30000}) of
    {ok, #{winner := #{index := I}}} -> {answered, I};
    {error, Why} -> {still_on_old_b, Why}
end.
```

The first 2xx wins. The other branches get a CANCEL, or a BYE if their 2xx
still comes. When every branch fails or `timer_c` passes, the call keeps the
old B, and you can call `replace_b/3` again.

| Result | Meaning |
|---|---|
| `{ok, #{winner := Winner}}` | `Winner` answered: its `uri`, `opts` and `index`, from 1 |
| `{error, #chappe_sip_error{status = 486}}` | the best final of the branches: busy when all are busy |
| `{error, timeout}` | `timer_c` passed; it covers the whole fork, and a 180 does not restart it |
| `{error, call_ended}` | the caller hung up; every branch got a CANCEL |
| `{error, none_up}` | `Dests` is empty |
| `{error, badarg}` | a malformed target or options; the call goes on |

`info/1` follows the call: its `winner` is the destination that answered, and
`undefined` after a replace to a URI or a dialog. If the old B had the call on
hold, the notify process gets `{unhold, b}` when it goes.

Notes on a fork:

- The caller's old B keeps playing to the caller while the branches ring, so
  a media server can play a ring tone.
- A destination over a WebSocket (its URI or its flow) gets WebRTC flags.
  Destinations with different flags need one rtpengine offer each, under its
  own via-branch: the old B then stops hearing the caller while they ring,
  and rtpengine keeps the ports of those offers until the call ends.
- Those separate offers cannot be made on a call whose INVITE had no SDP: you
  get `{error, {rejected, 488}}` and the call goes on.

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
  `relay_info_forwarded`, `replace_b_*`, `fork_replace_*`,
  `relay_async_outlives_handler`), `chappe_sip_webrtc_gateway_SUITE`
  (`replace_b_fork_ws_udp`).
- Design: [B2BUA design](../design/b2bua.md).
- Lab: `make interop-sbc` (`apps/chappe_sip/interop/sbc`).
