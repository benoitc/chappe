# B2BUA

A back-to-back user agent terminates the inbound call and originates a fresh
one, so chappe_sip sits in the middle of two independent dialogs. It relays
provisionals (with early media), the answer, re-INVITEs and UPDATEs, and BYE
between the legs, and can rewrite headers and SDP. Read this to bridge a
caller to a callee under your control.

## When to use it

- You need to control both dialogs (record media, rewrite SDP/headers, insert an
  IVR, re-target) rather than transparently proxying.
- You bridge across transports (a WebSocket browser to a UDP peer). See
  [SIP over WebSocket](websocket.md).

## Bridge a call

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    Callee = <<"sip:bob@10.0.0.2">>,
    case chappe_sip:create_b2bua(Req, Res, Callee, #{}) of
        {ok, Legs}      -> chappe_sip_b2b:relay(Legs);
        {error, Reason} -> chappe_sip_res:send(Res, 500), {error, Reason}
    end
end).
```

`create_b2bua/4` originates the B leg, relays provisionals to the caller (with a
shared To-tag and their body), bridges the 2xx SDP, and returns the two legs.
`chappe_sip_b2b:relay/1` carries the call until either leg is torn down, then
destroys the other.

Both legs hand re-INVITE and UPDATE to their owner, so run `relay/1,2` (or
answer those events yourself) for as long as the call lasts.

## Options

```erlang
chappe_sip:create_b2bua(Req, Res, Callee, #{
    proxy_request_headers  => {all, [<<"route">>]},  %% copy headers A -> B
    proxy_response_headers => [<<"X-Account">>],     %% copy B's 2xx -> A's 2xx
    pass_failure           => true,                  %% relay a B failure to A
    session_expires        => 1800,                  %% a session timer per leg
    timer_c                => 60000,                 %% how long B may ring (ms)
    flow                   => Flow,                  %% originate B over a WS flow
    privacy                => true                   %% act as a privacy service
}).
```

`proxy_request_headers` and `proxy_response_headers` take
`list | all | {all, Exclude}`. `all` never copies the dialog headers,
`Session-Expires`/`Min-SE`, and, from B's 2xx, `Require`, `Supported`,
`Allow` and `RSeq`: those belong to one leg. A `Privacy: none` from A always
reaches B unchanged, whatever you copy (RFC 3323 4.2). Set `flow` (from
`chappe_sip:location_flow/1`) to send the B leg to a registered WebSocket UA.

`from` sets the `From` of the INVITE to B, for example from a caller's display
name. A malformed value, such as one holding a line break, never reaches B on
any transport: you get `{error, badarg}` and A hears a 500, or nothing with
`pass_failure => false`, where you answer A yourself.

More options, each a drachtio-srf one you may know:

```erlang
chappe_sip:create_b2bua(Req, Res, Callee, #{
    a_headers        => [{<<"X-Billing">>, Account}],  %% on A's final response
    local_sdp_b      => fun(SdpA) -> strip_video(SdpA) end,
    local_sdp_a      => fun(SdpB) -> SdpB end,
    auth             => fun(Challenge) -> credentials_for(Challenge) end,
    follow_redirects => true,                           %% B's 3xx, on the B leg
    keep_uri_on_redirect => true,                       %% a 3xx Contact is the next hop only
    call_ref         => UpstreamRef,                    %% see Follow a call
    notify           => self()
}).
```

- `a_headers` go on A's 2xx and on the failure A gets when B fails
  (`responseHeaders`).
- `local_sdp_b` and `local_sdp_a` take a value or a fun; `auth` takes a
  credentials map, a list, or a fun of the parsed challenge. A fun runs on
  the node that holds the call (`local_sdp_*` in your handler's process,
  `auth` in the B leg's UAC process).
- `follow_redirects` and `keep_uri_on_redirect` work as for
  [create_uac/2](originate-calls.md#follow-redirects): A never sees B's 3xx.

## Watch the B leg ring

With `notify`, your process hears of B before it answers (drachtio's
`cbRequest`, `cbProvisional` and `cbFinalizedUac`):

```erlang
watch(Ref) ->
    receive
        {chappe_sip_b2b, Ref, {b_request, #{call_id := BCallId, uac := Uac}}} ->
            logger:info("B leg ~s", [BCallId]),
            put_aside(Uac),
            watch(Ref);
        {chappe_sip_b2b, Ref, {b_early, _EarlyDialog}} ->
            watch(Ref);
        {chappe_sip_b2b, Ref, {b_provisional, Msg}} ->
            logger:info("B rings: ~p", [chappe_sip_msg:status(Msg)]),
            watch(Ref)
    end.
```

- `b_request` comes each time B's INVITE goes out (again after a 401 or a
  3xx), with `call_id`, `uri`, `method`, `cseq` and `uac`.
  `chappe_sip_uac:cancel(Uac)` CANCELs B; A then gets B's 487.
- `b_early` names each early dialog B forms, `b_provisional` each 1xx (a
  `chappe_sip_msg:msg()`). With a fork, each branch sends its own.
- `Ref` is the reference of the result's `b2b`; you learn it when
  `create_b2bua/4` returns, so take these events in another process, or
  match `{chappe_sip_b2b, _, _}` while the call rings.

## Act as a privacy service

Set `privacy => true` when your b2bua is the privacy service of RFC 3323 for
its callers. It reads the `Privacy` header of A's INVITE:

- `none`: nothing is removed, and the header reaches B unchanged.
- `user` or `header`: Subject, Call-Info, Organization, User-Agent, Reply-To
  and In-Reply-To stay off the B leg, even with
  `proxy_request_headers => all`. The b2bua already gives B its own From,
  Contact, Via and Call-ID.
- `id`: P-Asserted-Identity and P-Preferred-Identity stay off the B leg.
- `session`: the b2bua cannot anonymize media on its own. If you do it (for
  example through rtpengine and `local_sdp_b`), say so with
  `privacy => #{session => true}`.
- `critical` with a level it cannot apply (`session` without that flag, or a
  token it does not know): A gets a 500 whose reason phrase names the levels,
  such as `Privacy Failure: session not supported`, B is never called, and
  `create_b2bua/4` returns `{error, {privacy, [<<"session">>]}}`.

```erlang
case chappe_sip:create_b2bua(Req, Res, Callee, #{privacy => true}) of
    {ok, Legs} -> chappe_sip_b2b:relay(Legs);
    {error, _} -> ok
end.
```

## How long B may ring

B rings as long as it keeps sending provisionals: each one other than 100
restarts Timer C on the B leg (RFC 3261 16.7). When Timer C fires, B is
CANCELled and the caller gets a 408. `timer_c` sets it per call; the default
is the `timer_c_ms` setting (185 s). The handler deadline does not apply
while B rings: the worker owns the call from the moment the B leg is sent.

## Rewrite the SDP that crosses

```erlang
chappe_sip_b2b:relay(Legs, #{
    rewrite_sdp => fun(From, Sdp) -> anchor(From, Sdp) end
}).
```

`From` is the leg (`a` or `b`) the offer or answer came from. Use it to run
the SDP through a media anchor such as rtpengine before the other leg sees it.

## What crosses the legs

- A re-INVITE or UPDATE with a new offer goes to the other leg; its answer
  comes back in the 2xx. A failure (a 488, a 491 on glare) comes back as is.
- A re-INVITE or UPDATE with no offer, or with the SDP already in force (the
  same `o=` line), is a session refresh: its own leg answers it.
- A reliable 1xx from B (100rel, RFC 3262) is PRACKed on the B leg. The
  caller gets a reliable 1xx when it asked for 100rel, and the 2xx waits for
  its PRACK when that 1xx carried SDP.
- The `Reason` of a BYE or CANCEL (RFC 3326) goes out on the other leg's BYE
  or CANCEL.
- A REFER never crosses. With `transfer => auto` or `notify` the B2BUA
  carries the transfer out itself (see [REFER](refer.md#transfer-a-b2bua-call));
  otherwise it goes to your notify process when `requests` names it, else
  it gets 603.

## Notes

- Each leg negotiates and refreshes its own session timer (RFC 4028): see
  [Session timers](session-timers.md).
- A crash of either dialog fsm tears the call down (the relay monitors both).
- With `media => anchor`, each leg is answered in the RTP profile it used
  itself: an SRTP caller (`RTP/SAVP`, `RTP/SAVPF`) stays SRTP, with a key of
  rtpengine's, a plain one plain. The first offer toward B is plain RTP, or
  DTLS-SRTP with ICE for a WebRTC B. `anchor_params => #{a | b => #{
  transport_protocol => ...}}` overrides it.
- Server-initiated BYE reaches a WebSocket B leg over its flow automatically.

## Where it lives

- Modules: `chappe_sip_b2b`, `chappe_sip_b2b_relay`, `chappe_sip_b2b_hdr`
  (headers, privacy), `chappe_sip_b2b_fork`.
- Tests: `chappe_sip_b2bua_SUITE`, `chappe_sip_b2b_relay_SUITE`,
  `chappe_sip_webrtc_gateway_SUITE`.
- Lab: `make interop-sbc`.
