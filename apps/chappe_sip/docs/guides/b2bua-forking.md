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

Give `create_b2bua/4` a `{parallel, Uris}` target.

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

## Fork an anchored call

With `media => anchor`, each branch answers the same rtpengine offer under
its own To-tag. Once a branch answers, rtpengine drops the early media
sessions of the others.

```erlang
chappe_sip:create_b2bua(Req, Res, {parallel, Devices}, #{media => anchor}).
```

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

Every failure comes back: a final response from B
(`#chappe_sip_error{status, reason}`), Timer C (`timeout`), a transport
error, or a target that cannot be called. `{error, cancelled}` means the
caller hung up while B rang; stop hunting then.

## Notes

- `{parallel, Uris}` takes URIs only, not a peer group.
- The fork runs in your request worker. The handler deadline does not apply
  once the B leg is sent, so a long ring is not cut.
- A forked INVITE produces one call record per branch (role `b2b_b`); see
  [Call records](call-records.md).

## Where it lives

- Modules: `chappe_sip_b2b` (entry), `chappe_sip_b2b_fork` (branches,
  winner, best final, `pass_failure`), `chappe_sip_proxy_rules` (the 16.7
  choice shared with the proxy).
- Tests: `chappe_sip_b2bua_SUITE` (`fork_*`, `pass_failure_timer_c`),
  `chappe_sip_b2b_relay_SUITE` (`fork_anchored_per_branch`).
- Design: [B2BUA design](../design/b2bua.md).
- Lab: `make interop-sbc` (`apps/chappe_sip/interop/sbc`).
