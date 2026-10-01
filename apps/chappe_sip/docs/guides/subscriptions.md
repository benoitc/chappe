# Subscriptions (SUBSCRIBE/NOTIFY)

A subscription (RFC 6665) is a dialog formed by a SUBSCRIBE: the subscriber
asks for an event package (`conference`, `dialog`, ...), you answer, and you
send NOTIFYs with the current state until the subscription ends. chappe_sip
runs the notifier side: you accept the SUBSCRIBE with `chappe_sip:create_uas/3`
and send NOTIFYs with `chappe_sip_dialog:notify/2`; the dialog process handles
refreshes, unsubscribes, and expiry. Read this when you serve an event
package, such as RFC 4575 conference state, or when you report the progress
of a REFER.

## When to use it

- You serve an event package to subscribers (conference roster, dialog
  state, a custom package).
- You accepted a REFER and must report the transfer with NOTIFYs in the
  INVITE dialog (the implicit subscription of RFC 3515).

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

## Notes

- Subscriptions work over UDP, TCP, TLS, and WebSocket alike.
- A subscription dialog is not in the Replaces index: `chappe_sip:find_replaced/1`
  only finds INVITE dialogs.
- Only the notifier side is implemented; chappe_sip does not send or refresh
  SUBSCRIBEs itself.
