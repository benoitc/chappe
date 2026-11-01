# Fork and hunt with the B2BUA

A B2BUA call can ring several devices at once (a parallel fork), try targets
one after the other (a list or a peer group), or give every failure back to
you so you decide where to go next (hunting). Read this when one inbound call
should reach the first of several phones that answers, or when your dial plan
needs to move to the next target on a busy or a timeout.

## When to use it

- A user has several devices (a desk phone, a softphone, a browser) and the
  first one to answer takes the call: use a parallel fork.
- You have an ordered list of destinations and want the next one tried when
  one fails: use a list, or a `{peer_group, G}` for monitored peers (see
  [Run an SBC](sbc.md)).
- Your app owns the decision of what happens after a failure (voicemail,
  another queue, an announcement): turn `pass_failure` off and hunt yourself.

## Ring several devices at once

Give `create_b2bua/4` a `{parallel, Dests}` target. A destination is a URI,
or `{Uri, BranchOpts}` when that branch needs options of its own (see
[Give each branch its own options](#give-each-branch-its-own-options)).

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    Devices = [<<"sip:alice@10.0.0.21">>, <<"sip:alice@10.0.0.22">>],
    case chappe_sip:create_b2bua(Req, Res, {parallel, Devices}, #{}) of
        {ok, Legs} -> chappe_sip_b2b:relay(Legs);
        {error, _} -> ok
    end
end).
```

What the caller sees:

- every branch's provisionals, under one To-tag, so the caller plays the
  early media of the branch that sent the last 1xx with SDP;
- the first 2xx; the other branches are CANCELled with a Reason (RFC 3326);
- when every branch fails, the best final response (RFC 3261 16.7, the same
  choice the proxy makes). A 6xx ends the fork at once.

A 2xx that still arrives from a losing branch is ACKed and BYEd for you.
Timer C covers the whole fork: each provisional of any branch restarts it.

## Give each branch its own options

A user's devices rarely look alike: a desk phone over UDP, a browser over its
WebSocket flow. Put the options that differ on the destination:

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, BrowserUri, WsFlow} = chappe_sip:location_flow(<<"sip:alice@example.com">>),
    Dests = [
        {BrowserUri, #{flow => WsFlow}},
        {<<"sip:alice@10.0.0.21">>,
         #{headers => [{<<"Alert-Info">>, <<"<urn:alert:service:normal>">>}],
           anchor_params => #{b => #{direction => [priv, pub]}}}}
    ],
    case chappe_sip:create_b2bua(Req, Res, {parallel, Dests}, #{media => anchor}) of
        {ok, Legs} -> chappe_sip_b2b:relay(Legs);
        {error, _} -> ok
    end
end).
```

`BranchOpts` keys, each applied over the call's options:

| Key | What it does for that branch |
|---|---|
| `flow` | the registered flow its INVITE goes over (a WebSocket flow marks it a browser) |
| `headers` | added to its INVITE, after the call's `b_headers` |
| `anchor_params` | `#{a \| b => map()}`, merged flag by flag over the call's `anchor_params` |

The same `{Uri, BranchOpts}` form works in a list tried in turn. To ring
every registered device of a user, build the destinations from
`chappe_sip:bindings/1` and each binding's `send_flow` (see
[Registrar](registrar.md)).

## Know which branch answered

The result carries `winner`, the destination that took the call:

```erlang
{ok, #{winner := #{uri := Uri, index := Index, opts := BranchOpts}} = Legs} =
    chappe_sip:create_b2bua(Req, Res, {parallel, Dests}, #{}).
```

- `index` is the destination's place in the target, from 1 (in the
  candidates, for a peer group); `opts` is `#{}` for a bare URI.
- `chappe_sip_b2b:info/1` returns `winner` while the call runs, so a
  process that only holds the call's handle (after `relay_async/2`, say)
  can ask for it.

## Fork an anchored call

With `media => anchor`, each branch answers an rtpengine offer under its own
To-tag. Once a branch answers, rtpengine drops the early media sessions of
the others.

```erlang
chappe_sip:create_b2bua(Req, Res, {parallel, Devices}, #{media => anchor}).
```

When every branch takes the same flags there is one offer. When they differ
(a browser gets ICE and DTLS-SRTP, a desk phone plain RTP, or a branch has its
own `anchor_params`), rtpengine gets one offer per distinct set of flags, each
under its own via-branch, and each branch answers the offer it was sent. The
winner's flags stay with the call afterwards.

## Try targets in turn

A plain list is tried in order. The call moves to the next URI when one
answers 408 or 503, or cannot be reached. Any other failure ends the call.

```erlang
chappe_sip:create_b2bua(Req, Res, [Primary, Backup], #{timer_c => 20000}).
```

`timer_c` bounds how long each target may ring (in ms, restarted by each
provisional).

## Hunt yourself

With `pass_failure => false`, a failure of the B leg is returned to you and
the caller is not answered. You can call the next target with the same `Req`
and `Res`, or answer the caller yourself.

```erlang
-include_lib("chappe_sip/include/chappe_sip.hrl").

hunt(Req, Res, []) ->
    chappe_sip_res:send(Res, 480, #{reason => <<"Temporarily Unavailable">>});
hunt(Req, Res, [Target | Rest]) ->
    case chappe_sip:create_b2bua(Req, Res, Target,
                                 #{pass_failure => false, timer_c => 15000}) of
        {ok, Legs} ->
            chappe_sip_b2b:relay(Legs);
        {error, cancelled} ->
            ok;
        {error, #chappe_sip_error{status = Status}} when Status >= 600 ->
            chappe_sip_res:send(Res, Status, #{});
        {error, _} ->
            hunt(Req, Res, Rest)
    end.
```

The caller sees one dialog across the whole hunt: the To-tag of the 180 a
first target relayed is the one the 200 of a later target carries, so
ringback can play while you move from target to target and the caller's BYE
reaches the call.

Every failure comes back: a final response from B
(`#chappe_sip_error{status, reason}`), Timer C (`timeout`), a transport
error, or a target that cannot be called. `{error, cancelled}` means the
caller hung up while B rang; stop hunting then.

## Notes

- `{parallel, Dests}` takes URIs and `{Uri, BranchOpts}`, not a peer group.
- The `media` fun sees the first destination's URI as `uri`.
- The fork runs in your request worker. The handler deadline does not apply
  once the B leg is sent, so a long ring is not cut.
- A forked INVITE produces one call record per branch (role `b2b_b`); see
  [Call records](call-records.md).

## Where it lives

- Modules: `chappe_sip_b2b` (entry), `chappe_sip_b2b_fork` (branches,
  winner, best final, `pass_failure`), `chappe_sip_proxy_rules` (the 16.7
  choice shared with the proxy).
- Tests: `chappe_sip_b2bua_SUITE` (`fork_*`, `serial_branch_opts`,
  `hunt_keeps_a_tag`, `pass_failure_timer_c`), `chappe_sip_b2b_relay_SUITE`
  (`fork_anchored_per_branch`), `chappe_sip_webrtc_gateway_SUITE`
  (`fork_ws_udp_*`), `chappe_sip_sbc_interop_SUITE`
  (`fork_webrtc_and_plain`, against the real rtpengine).
- Design: [B2BUA design](../design/b2bua.md).
- Lab: `make interop-sbc` (`apps/chappe_sip/interop/sbc`).
