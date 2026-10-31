# Presence and message waiting

chappe_sip serves and watches two event packages beyond conference state:
presence (RFC 3856, documents in PIDF, RFC 3863), whose state the PUBLISHes
of RFC 3903 set, and message waiting (RFC 3842). Read this when you run a
presence server or a voicemail notifier, or when your node publishes its
own presence and watches someone else's.

## When to use it

- Phones PUBLISH their presence to you and subscribe to each other's.
- Your voicemail store must light the message-waiting lamp of phones.
- Your node publishes the state of a user (an agent's availability) to a
  presence server, or watches a presentity or a mailbox there.

## Serve presence

```erlang
ok = chappe_sip_presence:serve(#{
    authorize => fun(Watcher, Presentity, _Req) ->
        case my_acl:allowed(Watcher, Presentity) of
            true -> allow;
            false -> deny
        end
    end,
    auth => #{realm => <<"example.com">>, secret => fun my_users:password/1}
}).
```

This registers the PUBLISH handler (the event state compositor, ESC) and
the `presence` package's SUBSCRIBE handler. Or pass `presence => Opts` to
`chappe_sip:start/1`.

- `authorize` is required (RFC 3856 6.6.2): `allow`, `deny` (403),
  `polite` (200 and a document saying closed, so the watcher cannot tell it
  was blocked) or `pending` (200 and a pending NOTIFY whose document has a
  note). Settle a pending watcher later with
  `chappe_sip_presence:decide(Presentity, allow | polite | deny)`.
- With `auth`, SUBSCRIBEs and PUBLISHes without valid digest credentials
  get 401, and an authenticated user may publish only its own presence
  (see [Control who publishes](#control-who-publishes)).
- Without `auth`, every PUBLISH gets 403 unless you pass
  `esc => #{allow_unauthenticated => true}`.
- Every NOTIFY carries the full state: the tuples of the presentity's live
  publications, one per tuple id, the most recently published winning.
  A change reaches each watcher at most once per `min_interval` (5000 ms).
- A SUBSCRIBE whose Accept leaves out `application/pidf+xml` gets 406.

`chappe_sip_presence:state(Presentity)` gives the composed document.

## Take PUBLISH for other packages

```erlang
ok = chappe_sip:publish(#{
    packages => #{<<"presence">> => [<<"application/pidf+xml">>],
                  <<"dialog">> => [<<"application/dialog-info+xml">>]},
    auth => #{realm => <<"example.com">>, secret => fun my_users:password/1},
    resources => fun(Aor) -> my_users:exists(Aor) end,
    min_expires => 60,
    max_expires => 3600
}).
```

The ESC answers each PUBLISH with the granted `Expires` and a new
`SIP-ETag`; `SIP-If-Match` refreshes (no body), modifies (a body) or removes
(`Expires: 0`) the publication it names, and gets 412 when it names none.
Other answers: 404 for a resource `resources` refuses, 489 for a package
not served, 423 with `Min-Expires` below `min_expires`, 415 for a body type
the package does not take, 400 for no body and no entity-tag, 403 for a
publisher not allowed to set that state, 413 for a body over
`esc_max_body_size`, and 503 with `Retry-After` (your `min_expires`) when
a new publication would go past `esc_max_publications` or
`esc_max_publications_per_resource` (see the
[configuration reference](../configuration.md)). Read the state back with
`chappe_sip_esc:publications(Aor, Package)`, newest first.

## Control who publishes

By default an authenticated user may publish only to its own
address-of-record: the user part of the Request-URI is the digest user
and its host is one of the auth domains (`domain` in the `auth` map, one
binary or a list, else the realm). This is the rule the registrar applies
to REGISTER. Anything else gets 403.

To set your own policy, pass `authorize`. It replaces the own-AOR rule and
sees the identity and the resource together:

```erlang
ok = chappe_sip:publish(#{
    auth => #{realm => <<"example.com">>, secret => fun my_users:password/1},
    authorize => fun(#{user := User, resource := Aor, event := Package}) ->
        my_acl:may_publish(User, Aor, Package)
    end
}).
```

The map also carries `realm` (or `undefined`) and `req`. `user` is
`undefined` when you run without `auth`. Return `true` to accept, `false`
for 403. The `resources` allow list still runs first (404).

Without `auth` and without `authorize`, every PUBLISH gets 403. On a closed
network where you trust every sender, opt in:

```erlang
ok = chappe_sip:publish(#{allow_unauthenticated => true}).
```

## Publish your own state

```erlang
Doc = chappe_sip_pidf:render(#{
    entity => <<"sip:agent7@example.com">>,
    tuples => [#{id => <<"desk">>, basic => open,
                 contact => <<"sip:agent7@10.0.0.7">>, priority => 0.8}]
}),
{ok, Pub} = chappe_sip:publish_state(<<"sip:agent7@example.com">>,
                                     <<"presence">>, Doc,
                                     #{expires => 3600,
                                       auth => #{user => <<"agent7">>,
                                                 pass => <<"secret">>}}).
```

The process keeps the publication alive:

- it refreshes before the granted `Expires` runs out, with `SIP-If-Match`
  and no body;
- `chappe_sip_publisher:update(Pub, NewDoc)` sends a modify;
  `chappe_sip_publisher:unpublish(Pub)` removes the state;
- a 412 (the compositor forgot it) republishes the whole state; a 423 is
  retried with its `Min-Expires`;
- one PUBLISH at a time: an update made meanwhile waits its turn.

The owner gets `{chappe_sip_publication, Pub, {published, Expires}}`,
`{failed, Reason}` or `unpublished`. When the owner exits the state is
removed.

## Watch someone's presence

```erlang
{ok, Sub} = chappe_sip:subscribe_to(<<"sip:bob@example.com">>,
                                    <<"presence">>, #{}),
receive
    {chappe_sip_subscription, Sub, {notify, #{doc := #{tuples := Tuples}}}} ->
        Tuples
end.
```

A presence subscription sends `Accept: application/pidf+xml` and makes one
dialog per SUBSCRIBE (RFC 3856 6.9: a NOTIFY from another fork gets 481).
The PIDF of each NOTIFY is parsed into `doc`: `entity`, and per tuple `id`,
`basic`, `contact`, `priority` (0.0 when absent or out of range), `notes`
and `timestamp`. Unknown elements are skipped. See the
[subscriptions guide](subscriptions.md) for the rest of the subscriber.

## Light message-waiting lamps

```erlang
ok = chappe_sip_mwi:serve(#{
    summary => fun(Account) -> my_voicemail:summary(Account) end,
    auth => #{realm => <<"example.com">>, secret => fun my_users:password/1}
}),
ok = chappe_sip_mwi:update(<<"sip:alice@example.com">>,
                           #{messages => #{voice => {2, 8}}}).
```

A `message-summary` subscription gets the account's summary at once (the
`summary` fun, for the account named by the Request-URI), then every
`update/2` of that account, at most one NOTIFY a second per subscriber. A
summary is `#{waiting => boolean(), account => Uri, messages => #{Class =>
{New, Old} | {New, Old, NewUrgent, OldUrgent}}}`, with Class one of
`voice`, `fax`, `pager`, `multimedia`, `text`, `none`; `waiting` defaults
to "any new message". `authorize => fun(User, Account, Req) -> boolean()`
refuses with 403.

`chappe_sip_mwi:render/1` and `parse/1` build and read the
`application/simple-message-summary` body; a subscriber's `doc` holds the
parsed summary.

## Notes

- Publications live in the node: they outlive an engine restart, not a node
  restart (EPAs then republish on their next refresh, after a 412).
- chappe_sip does not sign or encrypt the documents (no S/MIME); use TLS.
- The rows these packages answer to are in the compliance catalogue under
  RFC 3903, 3856, 3863 and 3842.

## Where it lives

- Modules: `chappe_sip_presence`, `chappe_sip_pidf`, `chappe_sip_mwi`,
  `chappe_sip_esc`, `chappe_sip_notifier`, `chappe_sip_publisher`,
  `chappe_sip_events_sup`.
- Tests: `chappe_sip_presence_SUITE`.
- Lab: none.
