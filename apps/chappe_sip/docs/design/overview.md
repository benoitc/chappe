# Architecture overview

chappe_sip runs sofia-sip's transaction layer inside the VM through a thin
NIF, and makes every transaction-user decision (dialogs, UAC and UAS,
B2BUA, proxy, registrar, digest, middleware) in Erlang. This page is the map
of the app for contributors: the supervision tree, what each directory of
`src/` owns, where execution enters, which modules are public, and which
tests cover what. Read it before you open the tree. The mental model shared
by all apps is in [concepts](../../../../docs/concepts.md); the NIF and its
threads are in [the engine design](engine.md).

## Layers

```
 SIP peers --UDP/TCP/TLS--> sofia nta (C, in the VM)     browsers --WS-->
                              |  events / enqueued ops        |
                              |                    chappe_sip_ws_transport
                              |                               |  same events
                         chappe_sip_engine  (singleton gen_server)
                              |  routes, dispatch, handle table
   +--------------------------+--------------------------+
   |               |                |                    |
 request        dialog fsm       uac fsm             proxy loop
 workers        (gen_statem)     (gen_statem)        (in a worker)
   |               |                |                    |
   +--- middleware, handlers, B2BUA, application code ---+
                              |
                  chappe_sip_media --> chappe_rtpengine, chappe_mix
```

- **The NIF shim** (`c_src/chappe_sip_engine_nif.c`) owns one sofia stack
  thread. It delivers inbound SIP as messages and accepts enqueue-only
  operations. It has no SIP logic: raw messages cross as binaries.
- **The WebSocket transport** is an Erlang transaction layer that emits the
  same events; see [ws-transport](ws-transport.md).
- **chappe_sip_engine** is the one process that talks to the NIF. It holds
  the routes and a handle table mapping engine handles to the processes that
  own them, and dispatches inbound events. Its responsibilities are mapped
  in [the engine design](engine.md#chappe_sip_engine-what-it-is-responsible-for).
- **A call is a process.** Each inbound out-of-dialog request runs in its
  own `chappe_sip_request_worker`. Each dialog is a `chappe_sip_dialog_fsm`;
  each outbound transaction a `chappe_sip_uac_fsm`.

## Supervision

```
chappe_sip_sup (one_for_one)
|-- chappe_sip_registry_keeper    ETS owner: location store, engine config snapshot
|-- chappe_sip_registry           location store
|-- chappe_sip_dialog_index       live dialogs by identity (Replaces, lookups)
|-- chappe_sip_digest_nc          accepted digest nonce counts
|-- chappe_sip_cdr                call records
|-- chappe_sip_hep                HEP capture of WS traffic
|-- chappe_sip_refer_sup (rest_for_one)
|   |-- chappe_sip_refer_registry
|   `-- chappe_sip_refer_subs (simple_one_for_one: chappe_sip_refer_sub)
|-- chappe_sip_subscriber_sup     (simple_one_for_one: chappe_sip_subscriber)
|-- chappe_sip_events_sup (rest_for_one)
|   |-- chappe_sip_esc                 event state compositor (PUBLISH)
|   |-- chappe_sip_presence_notifier   chappe_sip_notifier for presence
|   |-- chappe_sip_mwi_notifier        chappe_sip_notifier for message-summary
|   `-- chappe_sip_publishers (simple_one_for_one: chappe_sip_publisher)
|-- chappe_sip_peers_sup (rest_for_one)
|   |-- chappe_sip_peers           peers table and subscribers
|   |-- chappe_sip_peer_sup        (simple_one_for_one: chappe_sip_peer)
|   |-- chappe_sip_qualify         registrar keepalive of UDP contacts
|   `-- chappe_sip_peers_env       temporary: loads the `peers` setting
|-- chappe_sip_ws_sup (one_for_one)
|   |-- chappe_sip_ws_transport
|   `-- chappe_sip_ws_listener     added when a WS listener is configured
|-- chappe_sip_media_sup (one_for_one)
|   `-- chappe_sip_media_mix       added when `mix` is configured
|-- chappe_sip_stack_sup (rest_for_one)
|   |-- chappe_sip_engine          NIF owner and dispatcher
|   |-- chappe_sip_request_sup     (simple_one_for_one: chappe_sip_request_worker)
|   |-- chappe_sip_dialog_sup      (simple_one_for_one: chappe_sip_dialog_fsm)
|   `-- chappe_sip_uac_sup         (simple_one_for_one: chappe_sip_uac_fsm)
`-- chappe_sip_regc_sup (one_for_one)
    |-- chappe_sip_regc_pg         pg scope for registration subscribers
    `-- {regc, Name}               one chappe_sip_regc per registration
```

Why the order matters:

- Everything above `chappe_sip_stack_sup` survives an engine restart: the
  location store, the dialog index, call records, subscriptions, peers, the
  WS transport and media state.
- `rest_for_one` under the stack means an engine failure restarts the call
  state below it (workers, dialogs, UACs).
- `chappe_sip_regc_sup` comes after the stack, so it stops first and a
  registration can still send its `Expires: 0` on shutdown.
- `chappe_sip_sup` also creates the guard's rate table
  (`chappe_sip_guard:init_table/0`) for the life of the application.
- A NIF-level crash takes the node; run the release under heart or systemd
  (see [deployment](../guides/deployment.md)).

## What each directory owns

| Directory | Owns | Modules |
|---|---|---|
| root | Boot, root supervisor, configuration defaults, metrics | `chappe_sip_app`, `chappe_sip_sup`, `chappe_sip_config`, `chappe_sip_metrics` |
| `engine/` | The NIF and the dispatcher, listen addresses, HEP for WS | `chappe_sip_engine`, `chappe_sip_nif`, `chappe_sip_binds`, `chappe_sip_bind_uri`, `chappe_sip_hep` |
| `conn/` | Request workers, the stack supervisor, the location store | `chappe_sip_request_worker`, `chappe_sip_request_sup`, `chappe_sip_stack_sup`, `chappe_sip_registry`, `chappe_sip_registry_keeper` |
| `sip/` | The message model and pure protocol helpers | `chappe_sip_msg`, `chappe_sip_hdr`, `chappe_sip_hdr_io`, `chappe_sip_uri`, `chappe_sip_req`, `chappe_sip_res`, `chappe_sip_sdp`, `chappe_sip_sdes`, `chappe_sip_multipart`, `chappe_sip_sipfrag`, `chappe_sip_digest`, `chappe_sip_digest_nc`, `chappe_sip_net` |
| `dialog/` | Dialogs, session timers, REFER, the subscriber side of events, the NOTIFY router | `chappe_sip_dialog`, `chappe_sip_dialog_fsm`, `chappe_sip_dialog_index`, `chappe_sip_dialog_sup`, `chappe_sip_session_timer`, `chappe_sip_refer*`, `chappe_sip_subscriber*`, `chappe_sip_notify_router` |
| `uac/` | Outbound transactions | `chappe_sip_uac`, `chappe_sip_uac_fsm`, `chappe_sip_uac_sup` |
| `proxy/` | The stateful proxy and Record-Route | `chappe_sip_proxy`, `chappe_sip_proxy_rules`, `chappe_sip_proxy_dialog`, `chappe_sip_route` |
| `ws/` | SIP over WebSocket | `chappe_sip_ws*` |
| `media/` | The media facade and its backends | `chappe_sip_media*` |
| `siprec/` | SIPREC: the recording client, its metadata, the recording server side | `chappe_sip_siprec*` |
| `peers/` | OPTIONS-monitored peers and the registrar's qualify | `chappe_sip_peers`, `chappe_sip_peer`, `chappe_sip_peers_sup`, `chappe_sip_peer_sup`, `chappe_sip_qualify` |
| `api/` | The facade, extension behaviours, feature subsystems, event packages | see below |

Where the layout is surprising (findings M5, M6 and M9 of the
[documentation plan](../../../../docs/plans/documentation-and-maintainability.md)):

- `api/` mixes four kinds of module: the facade (`chappe_sip`), extension
  points (`chappe_sip_handler`, `chappe_sip_middleware`, `chappe_sip_guard`),
  feature subsystems (the nine `chappe_sip_b2b*` modules, `chappe_sip_focus`,
  `chappe_sip_confinfo`, `chappe_sip_regc*`, `chappe_sip_registrar`) and the
  event packages (`chappe_sip_esc`, `chappe_sip_notifier`,
  `chappe_sip_presence`, `chappe_sip_pidf`, `chappe_sip_mwi`,
  `chappe_sip_publisher`, `chappe_sip_events_sup`). The other half of
  events (subscriber, REFER, the NOTIFY router) is in `dialog/`.
- `chappe_sip_cdr` lives in `api/` but is a core service: dialogs, UACs, the
  B2BUA and the proxy all report to it, and it is a direct child of
  `chappe_sip_sup`.
- `chappe_sip_route` lives in `proxy/` but is cross-cutting: Record-Route,
  the HMAC route markers and the boot secret (`ensure_secret/0`, called by
  `chappe_sip_app`), WS flow tokens and NAT `received` flows. The engine,
  dialogs, UAC, B2BUA and registrar all use it.
- `chappe_sip_hdr` parses far more than its name suggests (Replaces,
  Subscription-State, Refer-To, Privacy...), and `chappe_sip_hdr_io` holds
  one serialization function.
- Core modules call back into the `chappe_sip` facade (finding M7), so the
  facade is not a pure top layer.

The B2BUA subsystem is described in [b2bua](b2bua.md), the media facade in
[media](media.md).

## Entry points

**Boot.** `chappe_sip_app:start/2` refuses the placeholder distribution
cookie, seeds the route secret (`chappe_sip_route:ensure_secret/0`), sets up
metrics and starts `chappe_sip_sup`. Nothing listens yet.
`chappe_sip:start/1` then configures HEP, starts the WS listener if asked,
configures media, starts the native engine (`chappe_sip_engine:start/1`),
serves presence if asked, and loads the `registrations` setting.

**Inbound request.**

1. The NIF (or the WS transport) sends `{request, TxnH, LegH, Meta, Raw}` to
   `chappe_sip_engine`.
2. `handle_event` sends an in-dialog request (a `LegH`) to the dialog fsm
   that owns the leg.
3. Otherwise `dispatch` checks our own Record-Route (in-dialog proxying),
   a stray in-dialog request (481), the merge rule (482) and the route
   (`route_for`: method, NOTIFY router, SUBSCRIBE event package).
4. `spawn_worker` starts a `chappe_sip_request_worker` under the worker
   cap and arms the handler deadline.
5. The worker parses the message, checks Require, runs the middleware and
   the handler `fun(Req, Res)`. The handler calls `create_uas/3`,
   `create_b2bua/4`, `proxy_request/3` or answers with
   `chappe_sip_res:send/3`.

**Outbound request.** `chappe_sip:create_uac/2` and `chappe_sip:request/2`
start a `chappe_sip_uac_fsm` (through `chappe_sip_uac:start/2`), which asks
the engine to send (`send_request/3,4`), registers its handle, and receives
`response` events. A 2xx to an INVITE creates a `chappe_sip_dialog_fsm`
(`chappe_sip_engine:create_dialog/1`).

## Message contracts

- Inbound request to a handler: the worker runs the middleware, then the
  method handler `fun(Req, Res)`.
- Dialog events to the owner process:
  `{chappe_sip_dialog, Dialog, Event, Req, Res}` for claimed events and
  `ack`, `{chappe_sip_dialog, Dialog, {auto_answered, Event}, Req}` for
  unclaimed ones, `{chappe_sip_dialog, Dialog, destroy, ReqOrReason}` at
  the end.
- UAC events to the notify process:
  `{chappe_sip_uac, Ref, {request_sent | provisional | ok | response | error, _}}`.
- B2BUA events to the notify process: `{chappe_sip_b2b, Ref, Event}`.

## Public and internal modules

Public (documented, stable within a release, used by applications):

- Facade and extension points: `chappe_sip`, `chappe_sip_handler`,
  `chappe_sip_middleware`, `chappe_sip_guard`.
- Calls and dialogs: `chappe_sip_dialog`, `chappe_sip_uac`, `chappe_sip_req`,
  `chappe_sip_res`, `chappe_sip_b2b`.
- Features: `chappe_sip_proxy`, `chappe_sip_registry`, `chappe_sip_regc`,
  `chappe_sip_peers`, `chappe_sip_refer`, `chappe_sip_subscriber`,
  `chappe_sip_presence`, `chappe_sip_pidf`, `chappe_sip_mwi`,
  `chappe_sip_focus`, `chappe_sip_confinfo`, `chappe_sip_cdr`,
  `chappe_sip_media`, `chappe_sip_metrics`, `chappe_sip_config`.
- Message helpers: `chappe_sip_msg`, `chappe_sip_hdr`, `chappe_sip_uri`,
  `chappe_sip_sdp`, `chappe_sip_multipart`, `chappe_sip_sipfrag`, `chappe_sip_digest`.

Everything else is internal: the engine and NIF, fsms, supervisors, the WS
transport, the B2BUA helper modules (`chappe_sip_b2b_*`), the proxy helpers,
the media backends, the event package internals. The ex_doc build groups
them under "Internal". No deprecation policy is written down yet.

## Protocol behaviour

Behaviour that holds across the layers, kept here rather than in one guide:

- The RFC 4475 torture-test corpus is embedded (`test/chappe_sip_rfc4475_SUITE`,
  50 messages, IETF Trust license). Each vector is classified against our
  lenient layer: well-formed messages parse, malformed start lines are
  rejected, and the rest survive without crashing.
- The message parser is total: `chappe_sip_msg:parse/1` never throws on any input
  (a non-token or non-UTF-8 header name yields `{error, malformed}`, not a
  worker crash), and header values are trimmed byte-wise, so `get/2`,
  `get_all/2` and `validate/1` never throw either. The SIP-Version is
  case-insensitive, the method a token, and every IANA compact header form is
  read. `chappe_sip_msg:validate/1` checks the mandatory headers
  (Via/From/To/Call-ID/CSeq) and that a request's CSeq is `1*DIGIT LWS Method`
  naming its own method; a failure is a 400 on both the UDP and WS ingress.
  Over WS a Content-Length that is repeated, negative or not the body size is
  a 400 too; a response with either problem is dropped.
  Max-Forwards is not required of a received request (a proxy adds 70).
- URIs: a user part may carry `;` (`sip:alice;day=tuesday@example.com`), the
  scheme is case-insensitive, and `chappe_sip_uri:equal/2` compares by RFC
  3261 19.1.4. `chappe_sip_uri:format/1` percent-escapes what each component
  (user, tel subscriber, password, parameters, headers) may not carry raw,
  keeps existing escapes, and writes a repeated parameter once.
- Handling MUSTs: an out-of-dialog method with no handler gets 405 with
  `Allow` (21.4.5), or 501 when unknown (21.5.2), and OPTIONS 200 with our
  capabilities (11); a non-100 response
  carries a To-tag (8.2.6.2), an unsupported `Require` gets a 420 with
  `Unsupported` (8.2.2.3), in a dialog too, never for ACK or CANCEL, while a
  UAS ignores `Proxy-Require`. The accepted tags are `supported_option_tags`
  plus a route's own (`chappe_sip:handle/3` `option_tags`, e.g. `siprec` for a
  recording server, RFC 7866 6.1.1); a route with `proxy => true` and the
  in-dialog forwarding of a record-routed dialog leave `Require` to the far
  UAS and check `Proxy-Require` (16.3). A too-brief REGISTER gets a 423 with
  `Min-Expires` (10.3), INVITE gets a 100 Trying, and merged requests get a
  482 (8.2.2.2).
- No content coding: sofia's zlib support is turned off at build time
  (`c_src/build.sh`), so nta neither inflates a request body nor deflates a
  response. An INVITE whose body has a Content-Encoding other than identity
  gets 415 with `Accept-Encoding: identity`; any other request reaches the
  app with its body and Content-Encoding as sent (RFC 3261 20.12).
- Requests to a domain are resolved per RFC 3263 by nta (NAPTR, SRV, A,
  with failover to the next SRV target, over TLS for a `sips:` URI); the
  conformance lab checks both against a dnsmasq server.
- Dialogs build a route set from Record-Route and route in-dialog
  requests through it (12.1.1/12.2.1.1): loose routing, or behind a strict
  router the first route as the Request-URI and the remote target last in
  Route; an out-of-order in-dialog request is rejected (12.2.2).

## Tests by area

Suites are in `apps/chappe_sip/test`; run one from the umbrella root with
`rebar3 ct --suite apps/chappe_sip/test/<suite>`. Most suites drive real SIP
over UDP against the NIF; `chappe_sip_engine_fake` is a pure-Erlang engine
backend for TU logic and error paths (`engine_mod`).

| Area | Suites and eunit modules |
|---|---|
| Engine and NIF | `engine_smoke`, `engine_lifecycle`, `ops`, `handler`, `pipeline` (fake engine), `source_ip`, `multihome`, `transport`, `test/asan/` |
| Inbound pipeline, guard | `pipeline`, `ood`, `guard` |
| UAS, dialogs | `core`, `uas`, `indialog`, `dialog_ops`, `dialog_fsm_tests`, `replaces` |
| UAC | `core_uac`, `uac`, `digest`, `digest_tests` |
| PRACK, session timers | `prack`, `prack_conf`, `session_timer` |
| B2BUA | `b2bua`, `b2b_relay`, `forked_2xx`, `webrtc_gateway` |
| Proxy | `proxy_conf`, `proxy_forking`, `proxy_record_route`, `proxy_media`, `route_tests` |
| Registrar, regc, peers | `registrar`, `regc`, `peers` |
| WebSocket, TLS | `websocket`, `ws_conf`, `tls` |
| Events, REFER, focus | `subscribe`, `subscriber`, `presence`, `refer`, `focus`, `confinfo_tests`, `sipfrag_tests` |
| CDR, HEP, metrics | `cdr`, `hep`, `hep_tests`, `metrics_tests` |
| Media | `media` (NG fake, real chappe_mix rooms) |
| Message model | `msg_tests`, `hdr_tests`, `uri_tests`, `sdp_tests`, `rfc4475` |
| Compliance gates | `gate1`, `gate2`, `conformance` (`make interop-conformance`), `compliance_tests` |
| Real stacks | `interop` (`INTEROP=1`, JsSIP and Kamailio), `sbc_interop` (`make interop-sbc`) |
| Docs | `doc_snippets_tests` (every `erlang` block in the docs) |

Suite names drop the `chappe_sip_` prefix and the `_SUITE` suffix here.
Test helpers: `chappe_sip_test_ua`, `chappe_sip_raw_peer`,
`chappe_sip_core_peer`, `chappe_sip_ws_test_client`, `chappe_sip_test_rtpe`
(rtpengine fake), `chappe_sip_test_port`.
