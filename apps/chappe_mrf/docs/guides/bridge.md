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

## Ring several destinations

A user with a desk phone and a browser rings on both. The caller goes to
the first that answers:

```erlang
Dests = [<<"sip:alice-desk@10.0.0.20">>,
         {<<"sip:alice-web@10.0.0.21;transport=ws">>, #{flow => Flow}}],
case chappe_mrf:bridge(B2b, {parallel, Dests},
                       #{timer_c => 30000, anchor_params => AnchorParams}) of
    {ok, #{winner := #{index := I}}} -> {answered, I};
    {error, Why} -> {still_on_endpoint, Why}
end.
```

While they ring the caller stays on the endpoint, so play a ring tone there.
On a failure (all busy, no answer) you get `{error, _}` and the caller stays
on it: play a prompt, or bridge again. A destination takes the same options as
in `chappe_sip_b2b:replace_b/3`.

## Show the caller

Without `from`, the phone you ring shows your node, not the person calling.
Pass the caller's identity on a SIP target or a fork:

```erlang
ok = chappe_mrf:bridge(B2b, <<"sip:alice@10.0.0.20">>,
                       #{from => <<"\"Bob\" <sip:bob@example.com>">>}).
```

A malformed value returns `{error, badarg}` and the caller stays where it was.
An endpoint ignores `from`: its re-INVITE keeps the identity of its dialog.

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

## Where it lives

- Modules: `chappe_mrf` (`bridge/2,3`, `create_endpoint/1`),
  `chappe_mrf_endpoint` (`handed/1`); the swap is
  `chappe_sip_b2b:replace_b/3` in chappe_sip
- Tests: `apps/chappe_mrf/test/chappe_mrf_SUITE.erl`,
  `chappe_mrf_live_SUITE.erl`
- Lab: `make interop-mrf`
