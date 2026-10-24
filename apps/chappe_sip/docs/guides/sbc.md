# Run an SBC

An SBC (session border controller) is a B2BUA at the edge of your network:
callers reach it, and it sends each call to one of your SIP peers (trunks,
FreeSWITCH nodes, a PBX), keeping both legs under its control. Read this when
you put chappe_sip in front of other SIP servers and need it to pick a live
peer, fail over when one goes away, and decide per call whether the media
goes through rtpengine.

## Watch your peers with OPTIONS

Add each peer with a name, a URI and a group. chappe_sip sends it an OPTIONS
every `interval_ms` and keeps its state.

```erlang
ok = chappe_sip:peer_add(fs1, #{uri => <<"sip:10.0.0.31:5080">>,
                                group => media, priority => 1}),
ok = chappe_sip:peer_add(fs2, #{uri => <<"sip:10.0.0.32:5080">>,
                                group => media, priority => 2}),
[{fs1, #{state := up}}, {fs2, #{state := up}}] = chappe_sip:peers().
```

A peer is `up` after `up_after` answered probes in a row (default 1) and
`down` after `down_after` failed ones (default 2). Any final response is an
answer except 408 and 503; set `alive_codes => [200]` to accept only some.
No response within `timeout_ms` (default 2000) is a failure.

To be told when a peer changes state, subscribe:

```erlang
ok = chappe_sip:peer_subscribe(self()),
receive {chappe_sip_peer, fs1, down} -> page_someone() end.
```

Peers can also come from the application environment:

```erlang
{chappe_sip, [{peers, [{fs1, #{uri => <<"sip:10.0.0.31:5080">>, group => media}}]}]}
```

## Send calls to a group

Give `create_b2bua/4` a `{peer_group, Group}` target. The call goes to the
best up peer, and moves to the next one when a peer answers 408 or 503 or
cannot be reached. With no up peer the caller gets 503.

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    case chappe_sip:create_b2bua(Req, Res, {peer_group, media}, #{}) of
        {ok, Legs} -> chappe_sip_b2b:relay(Legs);
        {error, _} -> ok
    end
end).
```

A list of URIs is tried in turn the same way, which lets you put the peer
you picked first. `b_headers` adds headers to the INVITE to the peer, such
as an id the peer hands back to you:

```erlang
chappe_sip:create_b2bua(Req, Res, [Picked | Others],
                        #{b_headers => [{<<"X-Chappe-Call">>, CallId}]}).
```

`peer_policy` picks the first peer: `priority` (the lowest number, the
default), `round_robin` or `weighted` (at random, by `weight`). To pick a
peer yourself, use `chappe_sip:peer_select/2`:

```erlang
{ok, Uri} = chappe_sip:peer_select(media, round_robin).
```

## Choose direct or anchored media

With `media => direct` (the default) the SDP passes through and RTP flows
between the endpoints. With `media => anchor` every offer and answer goes
through rtpengine (configure it with the `media` option of
`chappe_sip:start/1`), so RTP flows through it.

Let `chappe_sip_media:bypass/2` decide per call. It anchors when either side
is WebRTC, when the address families differ, when an SDP address is not the
address the signalling came from (a NAT), and when an address is private and
no network you list holds both sides:

```erlang
Media = fun(#{sdp := Sdp, source := Source}) ->
    chappe_sip_media:bypass(#{a => #{sdp => Sdp, source => Source},
                              b => {10, 0, 0, 31}},
                            #{networks => [<<"10.0.0.0/16">>]})
end,
chappe_sip:create_b2bua(Req, Res, {peer_group, media}, #{media => Media}).
```

## Switch a live call

`chappe_sip_b2b:set_media/2` moves a call between direct and anchored, for
example to start a recording. Keep the `b2b` handle the call returns:

```erlang
{ok, #{b2b := B2b} = Legs} = chappe_sip:create_b2bua(Req, Res, Target, #{}),
%% ... later, from any process
ok = chappe_sip_b2b:set_media(B2b, anchor),
#{media := anchor} = chappe_sip_b2b:info(B2b).
```

It re-INVITEs the caller without an offer, sends the caller's new offer to
the callee (through rtpengine when it anchors), and ACKs the caller with the
callee's answer. It returns `{error, busy}` while another offer of the call
is pending.

## Keep registered UDP contacts open

A UA behind a NAT stays reachable only while packets keep its NAT binding
open. Set `qualify_interval_ms` on the registrar to send each contact
registered over UDP an OPTIONS that often, to the address its REGISTER came
from (RFC 3581), whatever its Contact says. A contact that leaves
`qualify_down_after` of them unanswered in a row (default 2) loses its
binding, and the peer subscribers get
`{chappe_sip_qualify, Aor, Contact, unreachable}`.

```erlang
ok = chappe_sip:register(chappe_sip:registrar(#{
    auth => Auth,
    qualify_interval_ms => 30000
})).
```

## Reach UAs behind a NAT

A UA behind a NAT often sends a Contact with its private address. The
stack sends to where its requests came from instead:

- `chappe_sip:location_flow/1` returns `{udp, Ip, Port}`, the REGISTER's
  source, for such a binding; pass it as `flow` and the call and every
  request of its dialog go there.
- A caller whose INVITE Contact is not its UDP source gets its dialog's
  requests (a re-INVITE from `set_media/2`, the BYE) at that source.

```erlang
{ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@example.com">>),
chappe_sip:create_b2bua(Req, Res, Uri, #{flow => Flow}).
```

## Notes

- Peer state lives in ETS: `chappe_sip:peers/0`, `chappe_sip:peer_status/1`
  and `peer_select/2` do not call a process.
- A peer's OPTIONS need the stack started: before `chappe_sip:start/1` every
  probe fails and the peer reads down.
- The failover is for the start of a call. Once a peer answered, the call
  stays on it.
- Kamailio's dispatcher (`ds_ping_method OPTIONS`) and chappe_sip ping each
  other the same way; the SBC interop lab (`make interop-sbc`) runs both.
