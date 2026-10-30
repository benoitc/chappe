# Add an event package

An event package (RFC 6665) names what a SUBSCRIBE watches: `presence`,
`message-summary`, `conference`, `dialog`. chappe_sip routes a SUBSCRIBE to a
package handler by its `Event` header, and ships a notifier process that keeps
the watchers and sends them the full state. Use this page when you add a
package to chappe_sip itself, as `chappe_sip_mwi` and `chappe_sip_presence`
do. To serve a package from your own app, the user guide
[subscriptions.md](../../apps/chappe_sip/docs/guides/subscriptions.md) is
enough.

## Before you start

- The guides [subscriptions.md](../../apps/chappe_sip/docs/guides/subscriptions.md)
  and [presence.md](../../apps/chappe_sip/docs/guides/presence.md).
- The package's RFC, and RFC 6665 sections 4.2 (notifier) and 4.1
  (subscriber).

## Where to look

| Piece | Module (under `apps/chappe_sip/src/`) |
|---|---|
| Route a SUBSCRIBE by `Event` | `chappe_sip:event_package/2` (`api/chappe_sip.erl`), stored by `chappe_sip_engine:handle/3` |
| Keep watchers, send full-state NOTIFYs, rate-limit | `api/chappe_sip_notifier.erl` (behaviour: `body/3`) |
| Start the notifier | `api/chappe_sip_events_sup.erl` |
| A full example: message waiting (RFC 3842) | `api/chappe_sip_mwi.erl` |
| A larger one: presence (RFC 3856) with PUBLISH state | `api/chappe_sip_presence.erl`, `chappe_sip_esc`, `chappe_sip_pidf` |
| A partial-state package: conference (RFC 4575) | `api/chappe_sip_focus.erl`, `chappe_sip_confinfo` |
| The subscriber side | `dialog/chappe_sip_subscriber.erl`, `chappe_sip:subscribe_to/3` |
| Digest and resource names for SUBSCRIBE | `api/chappe_sip_esc.erl` (`authenticate/2`, `resource/1`) |

## Steps

1. Write a module with a body renderer and the `chappe_sip_notifier`
   callback, `body(Key, WState, Data) -> {ContentType, Body}`.
2. Add a notifier child to `chappe_sip_events_sup`, as
   `chappe_sip_mwi_notifier` is:
   `chappe_sip_notifier:start_link(Name, Module, MinIntervalMs)`.
3. Add `serve/1`. It registers the package and, for each SUBSCRIBE,
   authenticates, answers with `create_uas/3` naming the notifier as owner,
   and adds the watcher:

   ```erlang
   serve(Opts) ->
       chappe_sip:event_package(<<"my-package">>, fun(Req, Res) ->
           subscribe(Req, Res, Opts)
       end).

   subscribe(Req, Res, _Opts) ->
       Key = chappe_sip_esc:resource(chappe_sip_req:uri(Req)),
       UasOpts = #{owner => whereis(my_package_notifier), expires => 3600},
       case chappe_sip:create_uas(Req, Res, UasOpts) of
           {ok, Dialog} ->
               chappe_sip_notifier:add(my_package_notifier, Dialog, Key, active);
           {error, _} ->
               ok
       end.
   ```

4. Add `update/2`, which stores the new state and notifies the watchers with
   `chappe_sip_notifier:put/3`.
5. Add the package's rows to `requirements.tsv` and claim them from the tests
   ([compliance.md](compliance.md)).
6. Write a guide or a section in `presence.md` or `subscriptions.md`
   ([write-a-guide.md](write-a-guide.md)), and list it in `docs/features.md`.

## Tests to add or run

| Suite | Covers |
|---|---|
| `chappe_sip_subscribe_SUITE` | the notifier side of RFC 6665: initial NOTIFY, Expires bounds, 423, refresh, unsubscribe, expiry, 489 |
| `chappe_sip_subscriber_SUITE` | the subscriber side |
| `chappe_sip_presence_SUITE` | PUBLISH, presence and message-summary end to end |
| `chappe_sip_focus_SUITE` | the conference package |

Add a suite or a group for the new package next to these, with a raw peer that
checks the exact `Event`, `Subscription-State` and body of each NOTIFY.

## How to know it works

- `make check` passes.
- An `OPTIONS` to the node lists the package in `Allow-Events`, and a
  SUBSCRIBE to an unknown package still gets 489.
- If you add a SIPp scenario (as `presence.xml` and `mwi.xml` do),
  `make interop-conformance` passes.

## Notes

- `chappe_sip:subscribe/1,2` is the catch-all SUBSCRIBE handler; a package
  registered with `event_package/2` wins over it.
- The notifier never sends two NOTIFYs to one watcher closer than its
  interval, and a held-back change is sent when the interval has passed.
- A fetch (`Expires: 0`) is `chappe_sip_notifier:add/5` with `Fetch = true`.

## Related

- [add-sip-feature.md](add-sip-feature.md)
- [extend-public-api.md](extend-public-api.md)
- [compliance.md](compliance.md)
