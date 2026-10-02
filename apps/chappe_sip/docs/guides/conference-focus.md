# Conference focus

A focus is the SIP user agent that hosts a conference (RFC 4579): every
participant has a dialog with it, its Contact is the conference URI marked
`isfocus`, and it serves the conference's state to watchers through the
`conference` event package (RFC 4575). `chappe_sip_focus` is the SIP side of
that focus, as a library for the process you run per conference, and
`chappe_sip_confinfo` renders the conference-info+xml documents. Read this when
you build a conference (ad hoc or dial-in) and want conference-aware phones to
see who is in it.

## When to use it

- You mix or bridge several parties under one conference URI.
- Watchers (phones, operator consoles) subscribe to that URI with
  `Event: conference`.
- Participants may ask for privacy and must then appear anonymously.

Media is not involved: mix with `chappe_mix` or anything else.

## Keep a focus in your conference process

```erlang
init(Uri) ->
    {ok, #{uri => Uri,
           contact => chappe_sip_focus:contact(Uri),
           focus => chappe_sip_focus:new(#{entity => Uri})}}.

handle_info(Msg, #{focus := F0} = S) ->
    case chappe_sip_focus:handle_info(Msg, F0) of
        {ok, F} -> {noreply, S#{focus := F}};
        ignore -> my_handle_info(Msg, S)
    end.

terminate(_Reason, #{focus := F}) ->
    chappe_sip_focus:stop(F).
```

`contact/1` is `<Uri>;isfocus`. `handle_info/2` takes the focus's own messages
and the events of the subscription dialogs it serves; anything else returns
`ignore`. `stop/1` ends every subscription with one
`Subscription-State: terminated;reason=noresource` NOTIFY.

## Tell the focus what the conference looks like

```erlang
changed(#{uri := Uri, focus := F} = S) ->
    Conf = #{entity => Uri, version => 0,
             user_count => 1,
             users => [#{entity => <<"sip:alice@example.com">>,
                         display_text => <<"Alice">>,
                         roles => [<<"host">>],
                         endpoints => [#{entity => <<"sip:alice@192.0.2.1">>,
                                         status => connected,
                                         joining_method => dialed_in}]}]},
    S#{focus := chappe_sip_focus:update(Conf, F)}.
```

Call `update/2` after every join, leave, or role change. The model is a
`chappe_sip_confinfo:conf()`; the focus sets its entity and the versions
itself. Each watcher gets a partial document with what changed since its last
NOTIFY, never two NOTIFYs within `min_interval` ms (5000 by default, RFC 4575
3.9): a change coming sooner is held and sent with the next one.

`chappe_sip_confinfo` keeps keys unique whatever your model says (RFC 4575
4.5): users sharing an entity become one user with all their endpoints, an
endpoint entity a sibling already has gets `;ep=N`, and repeated media ids,
`conf_uris` or `available_media` entries are dropped. Enumerated values outside
the RFC's lists are left out, and when you list `available_media`, an endpoint
media `label` naming none of them is dropped.

## Describe each endpoint from SIP

```erlang
joined(Dialog, Available) ->
    Sdp = chappe_sip_dialog:remote_sdp(Dialog),
    #{entity => contact_of(Dialog),
      status => chappe_sip_focus:leg_status(Sdp),
      joining_method => dialed_in,
      media => chappe_sip_focus:media(Sdp, Available)}.

dialing(Target, Refer) ->
    #{entity => Target, status => dialing_out, joining_method => dialed_out,
      referred => chappe_sip_focus:referred(Refer)}.

left(Endpoint, Why) ->
    Endpoint#{status => disconnected,
              disconnection_method => chappe_sip_focus:departure(Why)}.
```

- `leg_status/1` is `on_hold` when every stream of the peer's SDP is
  `sendonly` or `inactive`, `connected` otherwise; call it again on each
  re-INVITE.
- `media/2` gives one `<media>` per accepted m= line, with its SDP type and
  direction, labelled with the `available_media` entry of the same type, and
  the stream's first `a=ssrc` as its `src-id` (RFC 4575 5.8.4).
- `referred/1` takes the REFER that made you call the endpoint: `by` is its
  Referred-By.
- `departure/1` takes the reason of the dialog's `destroy` message or the
  error of your INVITE: the peer's BYE is `departed`, yours `booted`, 486 or
  600 `busy`, anything else `failed`.

The endpoints' `call_info` (the dialog identifiers) is left out of every
document unless you start the focus with `call_info => true`: RFC 4575 5.7.9
makes it a privacy decision.

## Answer INVITE and OPTIONS as a focus

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    Conf = my_conference(Req),
    Contact = my_conf:contact(Conf),
    {ok, Dialog} = chappe_sip:create_uas(Req, Res, #{
        owner => Conf,
        local_sdp => my_conf:answer(Conf, Req),
        headers => chappe_sip_focus:headers(Contact)
    }),
    my_conf:joined(Conf, Dialog, chappe_sip_focus:privacy_requested(Req))
end),
ok = chappe_sip:options(fun(Req, Res) ->
    Contact = my_conf:contact(my_conference(Req)),
    chappe_sip_res:send(Res, 200, #{headers => chappe_sip_focus:headers(Contact)})
end).
```

`headers/1` is the Contact plus the Allow, Accept, Allow-Events
(`conference`), and Supported (`replaces`) a focus advertises (RFC 4579 5.13).
On the INVITEs your conference sends, pass `chappe_sip_focus:contact_params()`
as the UAC `contact_params`.

## Serve subscriptions

```erlang
ok = chappe_sip:subscribe(fun(Req, Res) ->
    Conf = my_conference(Req),
    chappe_sip_focus:subscribe(Req, Res, Conf, #{
        contact => my_conf:contact(Conf),
        expires => 600
    })
end).
```

`subscribe/4` answers 489 with `Allow-Events: conference` to any other
package and 406 with `Accept` when the SUBSCRIBE's Accept leaves out
`application/conference-info+xml`. Otherwise the subscription dialog belongs
to `Conf`, which gets `{chappe_sip_focus, subscribed, Dialog, Opts}`; passed
to `handle_info/2`, it sends the full state as version 1. A refresh gets the
full state again, an unsubscribe gets it in a terminated NOTIFY.

## Give a subscriber its own view

RFC 4575 8.2 has the focus send different documents to subscribers with
different roles. Pass `view` to `subscribe/4`: a fun from the conference as
you gave it to `update/2` to what this subscriber may see. It replaces the
focus-wide `call_info` policy for that subscriber.

```erlang
View = case is_moderator(Req) of
    true -> fun(Conf) -> Conf end;                %% call-info included
    false -> fun(Conf) -> hide_call_info(Conf) end
end,
chappe_sip_focus:subscribe(Req, Res, Conf, #{contact => Contact, view => View}).
```

A subscriber your policy denies should still get 200 and documents that look
real (RFC 6665 6.2), so it cannot tell it was refused. Give it an empty
roster:

```erlang
chappe_sip_focus:subscribe(Req, Res, Conf, #{
    contact => Contact,
    view => fun(C) -> C#{users => []} end
}).
```

The focus keeps the entity and the per-subscription versions whatever the
view returns.

## Show a participant anonymously

```erlang
User = chappe_sip_confinfo:anonymize(User0, JoinOrder).
```

A participant whose INVITE carried `Privacy: id` (or `user`, `header`) is
shown as `"AnonymousN" <sip:anonymousN@anonymous.invalid>` (RFC 4575 5.6):
URI, display name, endpoint URIs and dialog identifiers are replaced or
dropped. Pick an `N` that stays the same while the participant is in, such as
its join order.

## Notes

- NOTIFYs go out through one process per watcher, so a slow watcher never
  blocks your conference process.
- `chappe_sip_confinfo:full/1` and `partial/3` work without the focus, for
  example to publish the same document elsewhere.
- The focus does not authenticate watchers; do that in middleware before
  `subscribe/4`.
