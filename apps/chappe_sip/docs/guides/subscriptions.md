# Subscriptions (SUBSCRIBE/NOTIFY)

A subscription (RFC 6665) is a dialog formed by a SUBSCRIBE: the subscriber
asks for an event package (`conference`, `presence`, ...), the notifier
answers and sends NOTIFYs with the current state until the subscription ends.
chappe_sip runs both sides. As the notifier you accept the SUBSCRIBE with
`chappe_sip:create_uas/3` and send NOTIFYs with `chappe_sip_dialog:notify/2`;
the dialog process handles refreshes, unsubscribes, and expiry. As the
subscriber, `chappe_sip:subscribe_to/3` starts a process that sends the
SUBSCRIBE, answers the NOTIFYs, refreshes and re-subscribes, and hands you
each NOTIFY. Read this when you serve an event package, such as RFC 4575
conference state, when you watch one (a buddy's presence, a mailbox), or
when you report the progress of a REFER.

## When to use it

- You serve an event package to subscribers (conference roster, dialog
  state, a custom package).
- You accepted a REFER and must report the transfer with NOTIFYs in the
  INVITE dialog (the implicit subscription of RFC 3515).
- You want another node's state: presence, message waiting, a dialog
  package.

## Accept a SUBSCRIBE

```erlang
ok = chappe_sip:subscribe(fun(Req, Res) ->
    {ok, Dialog} = chappe_sip:create_uas(Req, Res, #{expires => 3600,
                                                    min_expires => 60}),
    {ok, _} = chappe_sip_dialog:notify(Dialog, #{
        state => active,
        content_type => <<"application/conference-info+xml">>,
        body => conference_info()
    }),
    serve(Dialog)
end).
```

The 200 carries the granted `Expires`: the one the subscriber asked for,
capped by `expires` (default 3600). A request below `min_expires` gets a 423
with `Min-Expires` and `create_uas/3` returns
`{error, {interval_too_brief, Min}}`. Send the first NOTIFY right away: RFC 6665
requires it.

To serve only some event packages, name them. Any other package, or a
SUBSCRIBE without an `Event`, is answered 489 with `Allow-Events` listing
yours, and your handler never runs. An out-of-dialog SUBSCRIBE for `refer`
always gets 403 (RFC 3515 2.4.4): a refer subscription lives only in its
REFER's dialog.

```erlang
ok = chappe_sip:subscribe([<<"conference">>], fun(Req, Res) ->
    ...
end).
```

## Give each package its own handler

```erlang
ok = chappe_sip:event_package(<<"presence">>, fun my_presence:subscribe/2),
ok = chappe_sip:event_package(<<"conference">>, fun my_conf:subscribe/2).
```

A SUBSCRIBE whose `Event` names a registered package (compared without
case) runs that package's handler; `chappe_sip:subscribe/1,2` stays the
catch-all for the others. With packages only, any other package gets 489.
`Allow-Events` on the 489 and on the OPTIONS 200 lists every package you
registered (plus the catch-all's list).

## Send NOTIFYs

```erlang
{ok, Resp} = chappe_sip_dialog:notify(Dialog, #{
    state => active,
    content_type => <<"application/conference-info+xml">>,
    body => conference_info()
}),
200 = chappe_sip_msg:status(Resp).
```

The Event header repeats the SUBSCRIBE's (including any `id` parameter).
`state` is `active`, `pending`, or `{terminated, Reason}`; for `active` and
`pending` the dialog adds `expires=<seconds left>` to `Subscription-State`,
never more than the subscriber was granted (0 after an unsubscribe or a
fetch).
Use `headers` for anything extra. NOTIFYs are serialized with the other
in-dialog requests.

## Handle refresh, unsubscribe, and the end

```erlang
serve(Dialog) ->
    receive
        {chappe_sip_dialog, Dialog, {refreshed, _Seconds}, _Req} ->
            %% RFC 6665 4.2.1.2: every accepted refresh gets a NOTIFY
            {ok, _} = chappe_sip_dialog:notify(Dialog, #{
                state => active,
                content_type => <<"application/conference-info+xml">>,
                body => conference_info()
            }),
            serve(Dialog);
        {chappe_sip_dialog, Dialog, unsubscribed, _Req} ->
            {ok, _} = chappe_sip_dialog:notify(Dialog, #{
                state => {terminated, timeout},
                content_type => <<"application/conference-info+xml">>,
                body => conference_info()
            }),
            chappe_sip_dialog:wait(Dialog);
        {chappe_sip_dialog, Dialog, destroy, Reason} ->
            {destroyed, Reason}
    end.
```

- A refresh (an in-dialog SUBSCRIBE) is answered 200 with the new `Expires`
  and restarts the expiry timer; you get `{refreshed, Seconds}`. Send a
  NOTIFY right away: RFC 6665 requires one after each refresh.
- An in-dialog SUBSCRIBE whose Event (type and `id`) is not the
  subscription's is refused 403: one subscription per dialog (RFC 6665
  4.5.2).
- `Expires: 0` is an unsubscribe: it is answered 200 and you get
  `unsubscribed`. Send the final NOTIFY with `{terminated, Reason}` within
  `unsubscribe_grace` ms (default 5000); otherwise the dialog sends a bodyless
  one itself. An initial SUBSCRIBE with `Expires: 0` (a fetch) works the same
  way: send one terminated NOTIFY.
- Once a terminated NOTIFY is answered, the dialog stops and you get
  `destroy` with reason `terminated`.
- No refresh before expiry: the dialog sends
  `Subscription-State: terminated;reason=timeout` and you get `destroy` with
  reason `expired`.
- A NOTIFY answered 404, 405, 408, 410, 416, 480 to 485, 489, 501 or 604
  ends the subscription (RFC 6665 4.2.2): `notify/2` returns the response
  and you get `destroy` with `{notify_failed, Status}`.

## End a subscription yourself

```erlang
ok = chappe_sip_dialog:destroy(Dialog).
```

On a subscription `destroy/1` sends
`Subscription-State: terminated;reason=noresource` instead of a BYE. The same
happens when the owner process exits (unless `on_owner_exit => continue`).

## Report a REFER in an INVITE dialog

`chappe_sip_refer` does this for you (Event id, expiry, refresh, rate limit):
see the [REFER guide](refer.md). To send such a NOTIFY by hand:

```erlang
{ok, _} = chappe_sip_dialog:notify(Dialog, #{
    event => <<"refer">>,
    state => {terminated, noresource},
    content_type => <<"message/sipfrag">>,
    body => <<"SIP/2.0 200 OK\r\n">>
}).
```

An INVITE dialog has no subscription, so name the `event`; `expires` is sent
only when you pass it. A terminated NOTIFY leaves the call up. Any package
other than `refer` gets `{error, no_subscription}` there: a subscription
starts with a SUBSCRIBE (RFC 6665 4.2.1).

## Subscribe to someone else's state

```erlang
start() ->
    {ok, Sub} = chappe_sip:subscribe_to(
        <<"sip:bob@example.com">>, <<"presence">>,
        #{expires => 3600,
          accept => [<<"application/pidf+xml">>],
          auth => #{user => <<"alice">>, pass => <<"secret">>}}),
    watch(Sub).

watch(Sub) ->
    receive
        {chappe_sip_subscription, Sub, {notify, #{state := _, body := Body}}} ->
            show(Body),
            watch(Sub);
        {chappe_sip_subscription, Sub, {forked, Sub2}} ->
            watch(Sub2);
        {chappe_sip_subscription, Sub, {retrying, _Reason, _Secs}} ->
            watch(Sub);
        {chappe_sip_subscription, Sub, {terminated, Reason}} ->
            {ended, Reason}
    end.
```

`subscribe_to/3` returns at once; the SUBSCRIBE goes through the UAC, so
`auth`, `proxy`, `route_set`, `from`, `contact` and `flow` work as for
`chappe_sip:request/2`. The owner (the caller, or `owner`) gets:

| Event | When |
| --- | --- |
| `{notify, Info}` | each NOTIFY, after it was answered 200. `Info` has `state` (`active`, `pending`, `terminated`), `expires`, `reason`, `retry_after`, `content_type`, `body`, `req`, and `doc` for a PIDF or a message summary, parsed (see the [presence guide](presence.md)) |
| `{forked, Sub2}` | a NOTIFY came from another fork: `Sub2` is a subscription of its own, with its own events (not for presence, which keeps one dialog: `forks => true` to take them) |
| `{retrying, Reason, Secs}` | the subscription ended and a new SUBSCRIBE (new Call-ID and From tag) goes out in `Secs` |
| `{terminated, Reason}` | it is over; the process has stopped |

What the process does for you:

- The dialog is formed by the 2xx or by the first NOTIFY, whichever comes
  first: a NOTIFY may beat the 2xx.
- It refreshes in the dialog before the subscription expires, a NOTIFY's
  `expires` taking over from the 2xx's `Expires`.
- Timer N (`timer_n`, 32 s): with no NOTIFY after a SUBSCRIBE the
  subscription ends with `{terminated, timer_n}`.
- A refresh answered 404, 405, 410, 416, 480 to 485, 489, 501 or 604 ends it
  with `{refresh_failed, Status}`; another error leaves it until it expires.
- A terminated NOTIFY: `deactivated` and `timeout` re-subscribe at once;
  `probation` and `giveup` after their `retry-after` (`probation_retry`, 60 s,
  when probation has none); `rejected`, `noresource` and `invariant` end it
  (`{terminated, Reason}`); another reason re-subscribes only after a
  `retry-after`.
- A SUBSCRIBE refused gives `{terminated, {subscribe_failed, Status}}`.

## Unsubscribe

```erlang
ok = chappe_sip:unsubscribe(Sub).
```

A SUBSCRIBE with `Expires: 0` goes out in the dialog; you get the final
NOTIFY as `{notify, ...}`, then `{terminated, unsubscribed}`. The same
happens when the owner exits.

## Where NOTIFYs go

Every NOTIFY outside a dialog of the stack goes through one router: a
subscription of yours first, then a REFER you sent outside a dialog
(`chappe_sip_refer`), then your `chappe_sip:notify/1` handler. With none of
them it gets 481 (RFC 6665 4.1.3). A NOTIFY handler of yours therefore sees
only the NOTIFYs nothing else claimed.

## Subscription behaviour in detail

- SUBSCRIBE/NOTIFY subscription dialogs (RFC 6665, notifier side):
  `chappe_sip:create_uas/3` on a SUBSCRIBE answers 200 with the granted
  `Expires` (capped by `expires`, 423 below `min_expires`) and confirms the
  dialog at once. `chappe_sip_dialog:notify/2` sends NOTIFY with Event and
  `Subscription-State` (`active`/`pending` carry the seconds left). In-dialog
  refreshes and `Expires: 0` unsubscribes are answered by the dialog and
  reported to the owner; expiry, `destroy/1` and owner death send a final
  `terminated` NOTIFY instead of a BYE; a NOTIFY failure of RFC 6665 4.2.2 ends
  the subscription; `chappe_sip:subscribe/2` answers 489 with Allow-Events
  for packages you do not serve. `notify/2` also sends the implicit REFER subscription's NOTIFYs
  inside an INVITE dialog. Works over UDP/TCP and WS. See the subscriptions
  guide.
- Event package routing: `chappe_sip:event_package/2` gives each package
  its own SUBSCRIBE handler, `subscribe/1,2` staying the catch-all;
  Allow-Events (OPTIONS 200, the 489) lists the registered packages.
- Subscriber side (RFC 6665): `chappe_sip:subscribe_to/3` starts a process
  that sends the SUBSCRIBE through the UAC (digest, proxy, flow), forms the
  dialog from the 2xx or the first NOTIFY, starts a subscription of its own
  for each forked NOTIFY, refreshes before expiry (a NOTIFY's `expires`
  wins), runs Timer N, ends on the refresh failures of 4.1.2.2, and acts on
  the terminated reasons (re-subscribe at once, after `retry-after`, or
  stop). `chappe_sip:unsubscribe/1` sends `Expires: 0`. NOTIFYs outside a
  dialog go through one router: our subscriptions, then REFERs we sent,
  then your `notify/1` handler, else 481. `chappe_sip_hdr:subscription_state/1`
  parses the header.

## Behaviour changes

- Every NOTIFY outside a dialog goes through the built-in router: your
  `chappe_sip:notify/1` handler sees only the NOTIFYs no subscription of
  ours and no REFER we sent claims, and without a handler a NOTIFY gets 481
  instead of 405. NOTIFY is always in Allow.

## Notes

- Subscriptions work over UDP, TCP, TLS, and WebSocket alike.
- A subscription dialog is not in the Replaces index: `chappe_sip:find_replaced/1`
  only finds INVITE dialogs.
- chappe_sip does not challenge NOTIFYs itself; put a
  `chappe_sip:use(<<"NOTIFY">>, Mw)` middleware in front if your peers
  authenticate them (RFC 6665 4.1.3).

## Where it lives

- Modules: `chappe_sip` (`subscribe/1,2`, `event_package/2`,
  `subscribe_to/3`, `unsubscribe/1`), `chappe_sip_dialog` (`notify/2`),
  `chappe_sip_subscriber`, `chappe_sip_notify_router`, `chappe_sip_hdr`
  (`subscription_state/1`).
- Tests: `chappe_sip_subscribe_SUITE`, `chappe_sip_subscriber_SUITE`.
- Lab: none.
