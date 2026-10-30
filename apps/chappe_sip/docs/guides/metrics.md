# Metrics

chappe_sip counts the SIP traffic it handles and reports its live state
(dialogs, bindings, registrations, peers) in the `instrument` registry, the
one livery renders in the Prometheus text format. Read this when you want a
dashboard or alerts on your SIP node.

## When to use it

- You scrape your nodes with Prometheus.
- You want an alert when an outbound registration fails or a peer goes down.
- You want to see how much the guard turns away.

## What is recorded

Counters, updated as traffic flows:

| Metric | Labels | Counts |
|---|---|---|
| `chappe_sip_requests_total` | `direction` (`in`, `out`), `method` | requests received and sent; an unknown method is `other` |
| `chappe_sip_responses_total` | `direction`, `status` | responses received on our requests, and sent |
| `chappe_sip_guard_blocked_total` | `reason` (`user_agent`, `source`, `rate`) | requests `chappe_sip_guard` turned away |

Gauges, read when the metrics are scraped:

| Metric | Labels | Value |
|---|---|---|
| `chappe_sip_dialogs` | none | dialogs alive |
| `chappe_sip_registrar_bindings` | none | live bindings in the location store |
| `chappe_sip_registrations` | `status` | outbound registrations by status |
| `chappe_sip_peers` | `state` | monitored peers by state |

Recording starts with the application. Nothing needs configuring.

## Serve them over HTTP

`chappe_sip_metrics:handler/0` returns a livery handler that refreshes the
gauges and renders the registry. Add it to the router of your livery
service:

```erlang
R1 = livery_router:add('GET', <<"/metrics">>,
                       chappe_sip_metrics:handler(), #{}, R0).
```

## Read the gauges without HTTP

`refresh/0` updates the gauges in the registry, for a scraper of your own or
a test.

```erlang
ok = chappe_sip_metrics:refresh().
```

## Turn recording off

Set the `metrics` setting to `false`. Nothing is registered or counted, and
`chappe_sip_metrics:enabled/0` returns `false`.

```erlang
{chappe_sip, [{metrics, false}]}
```

## Notes

- Labels are bounded: methods outside the SIP set are `other`, so a peer
  cannot grow the label set.
- The metrics are registered once; an application restart keeps them.

## Where it lives

- Modules: `chappe_sip_metrics` (registration, counters, gauges, handler),
  set up by `chappe_sip_app`, fed by `chappe_sip_engine` and
  `chappe_sip_guard`.
- Tests: `chappe_sip_metrics_tests`.
- Lab: none.
