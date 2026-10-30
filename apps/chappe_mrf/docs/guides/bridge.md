# Bridge a caller

`chappe_mrf:bridge/3` moves a connected caller to a SIP target or to
another endpoint. The caller sees no re-INVITE: the leg behind rtpengine
is swapped (`chappe_sip_b2b:replace_b/3`), and the leg the caller had gets
a BYE. Use it to send an IVR caller to an agent, to a voicemail endpoint,
or from one media server to another.

## When to use it

- The menu is done and the caller goes to a person.
- The caller moves to an endpoint prepared beforehand (an echo test, a
  recorder, a conference endpoint).

## Bridge to a SIP target

```erlang
ok = chappe_mrf:bridge(B2b, <<"sip:alice@10.0.0.20">>, #{}).
```

On a failure (busy, no answer) you get `{error, _}` and the caller stays
where it was, so you can play a prompt and go back to the menu.

## Bridge to a new endpoint

`create_endpoint/1` calls a node with an inactive SDP and takes the channel
over, with no caller yet:

```erlang
{ok, Echo} = chappe_mrf:create_endpoint(#{node => fs2}),
ok = chappe_mrf:bridge(B2b, Echo, #{}),
{ok, _} = chappe_mrf:execute(Echo, <<"echo">>, <<>>).
```

The endpoint's dialog now belongs to the call: hanging up either side ends
both.

## Cross networks

When the new target sits on another rtpengine interface than the old one
(a SIP phone on the host, the old leg a FreeSWITCH node in a container),
give the new leg's interfaces:

```erlang
ok = chappe_mrf:bridge(B2b, <<"sip:bob@192.168.1.30">>,
                       #{anchor_params => #{b => #{direction => [host, host]}}}).
```

## Notes

- The call must be anchored (`connect_caller/3` anchors by default);
  `{error, not_anchored}` otherwise.
- rtpengine keeps the caller's ports across the swap (port latching on the
  answer), since the caller never hears of the new offer.
