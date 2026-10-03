# Remote apps and the outbound connection model (draft)

This is a design draft for review. No code exists for it yet. It describes
how a chappe_sip node could serve applications that run outside its VM:
either on other Erlang nodes, or in any language over a control socket in
the spirit of drachtio. Read it if you are deciding how a product (an SBC,
an AI voice service, a PBX) should be split between the SIP stack and the
call logic, or if you are about to touch the route table, `chappe_sip_res`,
or dialog ownership.

## Problem and goals

Today the SIP stack and the application share one VM: you call
`chappe_sip:handle/3` with a fun, and that fun runs in a request worker on
the node that owns the NIF. That is fast and simple, but it ties three
things together that products want to separate:

- **One SIP node, many apps.** An SBC front end, an IVR and a voicemail
  service should be able to register for different requests on one SIP
  node, without being linked into one release.
- **App restart without dropping calls.** Deploying a new version of the
  call logic should not tear down the calls in progress.
- **Scale-out.** Call logic should scale horizontally (several app
  instances behind one SIP node, or one app serving several SIP nodes),
  and an app instance should be able to sit behind a load balancer the
  SIP node connects out to.
- **Other languages.** An AI voice product may want its call logic in
  Python or TypeScript, as drachtio's srf apps are in Node.

Non-goals:

- Replicating SIP transaction or dialog state between SIP nodes. A SIP node
  restart still loses its calls (see `docs/design/engine.md`, rest_for_one).
- Changing the in-node API. In-node apps stay the default and keep working
  unchanged; remote is opt-in.

## What is node-local today

Each item below is a reason an app cannot simply run on another node.

| Piece | Where | Why it is node-local |
|---|---|---|
| Routes | `chappe_sip_engine` `#state.routes :: #{binary() => fun()}`, set by `handle_call({handle, ...})` | One fun per method for the whole node: a second `handle/3` for INVITE replaces the first. Snapshotted with middleware into the `chappe_sip_engine_cfg` ETS table (owned by `chappe_sip_registry_keeper`) so an engine crash restores them; funs only make sense in this VM. |
| Middleware | `#state.middlewares`, `chappe_sip_middleware:mw()` | Funs `(Req, Res, Next)`, run inside the request worker. |
| Dispatch | `dispatch_route/4` (engine ~1518), `spawn_worker/7` (~1808) | Spawns a local `chappe_sip_request_worker` that runs the handler fun in-process. The engine monitors it, arms `handler_deadline/1` (`handler_deadline_ms`, capped by `non_invite_deadline_ms` for non-INVITE), and answers 500 on `'DOWN'` if no final went out. `disarm/1` removes the deadline once the worker becomes a call owner. |
| Request | `chappe_sip_req` `#req{msg, txn, meta}` | Plain data, so it crosses nodes, but `txn` is an engine integer that means nothing elsewhere and can be reused after an engine restart. |
| Response | `chappe_sip_res` `#res{txn, sender, final}` | `sender` is a fun from `make_sender/2` (~1863) that closes over the backend module and the NIF engine resource. `final` is an `atomics` ref shared with the engine. Neither survives distribution: an atomics ref and a NIF resource are not usable on another node, and a fun needs the same module version loaded there. `await_prack/2` also expects `{chappe_sip_prack, ...}` in the caller's mailbox. |
| Handles | `#state.handles :: #{TxnH or LegH => pid()}`, `workers`, `dialogs`, `monitored`, `proxied` | The engine routes responses, in-dialog requests, ACKs and CANCELs to a pid by integer handle. A remote pid would work as a target, but the integers are not stable identities outside the engine. |
| Dialog handle | `include/chappe_sip_dialog.hrl` `#dialog{pid, id}` | The pid is distribution-safe (`chappe_sip_dialog` uses `gen_statem:call/3` on it), but events carry a live `Res` built by the fsm's `dialog_sender/2`, which has the same problem as above. |
| Dialog ownership | `chappe_sip_dialog_fsm` `owner`, `owner_mon`, `on_owner_exit :: destroy \| continue` | The fsm monitors its owner. `destroy` (default) tears the call down when the owner dies; `continue` keeps it, but there is no way to give the dialog a new owner, so events keep going to a dead pid. |
| UAC | `chappe_sip_uac` `#uac_ref{pid, ref}`, events `{chappe_sip_uac, Ref, Event}` to `notify` | Message-based and close to distribution-safe. `create_uac/2` blocks the caller; the `answer` option is a fun; the UAC fsm does not monitor its owner yet (being fixed on the CDR lane). |
| Engine calls | `chappe_sip_engine:create_uas/2` | `gen_server:call(?MODULE, ...)` to a locally registered name, with the caller pid taken as the worker. |
| B2BUA | `chappe_sip_b2b:create_b2bua/4`, `relay/2` | The worker owns both dialogs and runs the relay loop. |
| Proxy | `chappe_sip_proxy:proxy_request/3` | The proxy loop runs in the worker, which registers client branch handles. |
| Media | `chappe_sip_media` `#media_session{backend, ref, identity}` | Session lifetime is bound to the calling process (the rtpengine session's owner monitor). |
| ETS state | `chappe_sip_dialog_index` (Call-ID and tags to fsm), `chappe_sip_registry` (location), `chappe_sip_refer_registry`, `chappe_sip_digest_nc` | Belongs with the stack; fine to stay on the SIP node. |
| Secrets | `persistent_term`: flow token secret and boot time (`chappe_sip_route`), nonce secret (`chappe_sip_digest`), media caps | Per node. The nonce secret is random per boot; the flow token secret is random unless `flow_token_secret` is configured. Matters when an app spans several SIP nodes. |
| Distribution | `config/vm.args.src`, `chappe_sip_app:insecure_cookie/1` | Distribution and epmd are bound to loopback; the node refuses to boot with the placeholder cookie. Distribution is intentionally not an external interface today. |

The short version: requests and dialog handles are mostly data plus pids,
but everything that answers or acts (`Res`, routes, middleware, option
funs) is a closure over VM-local state.

## Options

### Option A: Erlang distribution

App nodes connect to the SIP node over distribution, register routes, and
receive requests as messages. The API they program against stays the
`chappe_sip` API, with remote-safe handles underneath.

### Option B: language-neutral control socket

Apps connect to the SIP node (or the SIP node connects to them) over a
TCP or WebSocket connection and exchange framed JSON messages, as
drachtio-server does with srf apps over its control port. The app sees SIP
as data and commands, not as Erlang terms.

### Option C: in-node restart only

Keep apps in the VM, and only make dialogs survive the restart of the app's
own OTP application (`on_owner_exit => continue` plus a reattach). This
solves "deploy without dropping calls" for Erlang products in one release,
but none of the other goals. It is listed because its primitives are a
prerequisite for A and B anyway.

### What both A and B need

Both models need the same three changes on the SIP node. Building them
first, and in-node, keeps A and B thin.

1. **A route table keyed by method plus match rules.** Replace
   `#{Method => Fun}` with ordered entries:

   ```erlang
   #{id => RouteId,
     method => <<"INVITE">>,
     match => #{ruri_user => {prefix, <<"+1">>},
                ruri_host => <<"pbx.example.com">>,
                header => {<<"X-Tenant">>, {exact, <<"acme">>}},
                event => <<"presence">>,          % SUBSCRIBE/NOTIFY package
                source => {cidr, <<"10.0.0.0/8">>},
                local_addr => <<"10.0.0.5:5060">>},
     priority => 10,
     group => <<"ivr">>,                        % load-balancing group
     target => {local, Fun} | {endpoint, Pid}}
   ```

   Match rules are data only (no funs), so they serialize over distribution
   and JSON. The highest priority matching entry wins; within one `group`,
   the engine picks a healthy endpoint by least in-flight requests. An
   existing `handle(Method, Fun, Opts)` call becomes one catch-all entry at
   priority 0 and still replaces the previous catch-all for that method, so
   current apps behave as before. The event-package match also gives
   SUBSCRIBE per-package routing, which the subscriber/presence work needs.

2. **A message-based responder.** `chappe_sip_res` gains a second sender
   form. Instead of a fun over the NIF resource, it holds the pid of an
   engine-side transaction proxy and a tag:

   ```erlang
   -record(res, {txn, sender :: fun() | {proxy, pid(), reference()},
                 final :: atomics:atomics_ref() | proxy}).
   ```

   `send/3` on a proxy res is a call to that pid, which owns the real sender
   and the duplicate-final guard and replies `ok | {error, already_final}`.
   The proxy is the request worker that exists today: for a remote route,
   the worker runs local middleware, delivers the request to the endpoint,
   then stays alive as the transaction's proxy until a final goes out or
   the deadline fires. For in-dialog requests the dialog fsm plays the same
   role. `finished/1` on a proxy res becomes a call.

3. **Reattachable dialogs.** With `on_owner_exit => continue`, a dialog
   whose owner dies enters an *orphaned* state for `owner_grace_ms`
   instead of keeping a dead owner forever:

   ```erlang
   {ok, Dialog, Snapshot} = chappe_sip_dialog:attach(DialogId, #{}),
   %% Snapshot: #{call_id, local_tag, remote_tag, state, role,
   %%             local_sdp, remote_sdp, app_data, missed => [Event]}
   ok = chappe_sip_dialog:set_app_data(Dialog, Bin),
   Dialogs = chappe_sip_dialog:list(#{app => <<"ivr">>}),
   ```

   While orphaned, the fsm answers in-dialog requests by its unclaimed
   rules (BYE 200 then destroy, INFO 200, a re-INVITE or UPDATE with an
   offer 491 or 500 with Retry-After), keeps session timers running, and
   records a bounded list of what happened. `attach/2` sets the new owner,
   returns the snapshot, and bumps an owner epoch so the old owner's
   operations get `{error, not_owner}`. `app_data` is a small opaque blob
   (size-capped) the app stores with the dialog so a restarted instance can
   rebuild its call context. When the grace expires, the dialog is
   destroyed with reason `owner_down`. The default stays `destroy`, with no
   grace.

   Media follows the dialog: in continue mode, the fsm (not the app
   process) becomes the owner of the call's `chappe_sip_media` sessions, so
   an app restart does not tear down the rtpengine session.

Handles that cross a boundary become opaque and carry the engine's boot
identity, so a handle from before an engine restart is refused instead of
aliasing a reused integer:

```
txn:    t.<boot>.<int>      dialog: d.<boot>.<int>      uac: u.<boot>.<int>
```

`<boot>` reuses the boot stamp `chappe_sip_route` already keeps in
`persistent_term`.

## Model A: Erlang distribution

### Shape

```
 app node (chappe_sip_client)            SIP node (chappe_sip)
 ----------------------------            -----------------------------------
 handle(<<"INVITE">>, Fun, Match)  --->  chappe_sip_app_endpoint (one per
                                         connected app node): owns its routes,
                                         monitors the node and its handlers
 per-request handler process     <---   {chappe_sip_request, Req, Res}
 chappe_sip_res:send(Res, 200)    --->  request worker (txn proxy) -> NIF
 chappe_sip:create_uas(Req, Res)  --->  request worker -> engine -> dialog fsm
 {chappe_sip_dialog, D, Ev, Req, Res} <-- dialog fsm (owner = remote pid)
```

The app side is a small library (`chappe_sip_client`, a separate hex
package or a module set in `chappe_sip`, see open questions) that mirrors
`chappe_sip`: `handle/3`, `use/2` is not offered (middleware stays on the
SIP node), `create_uas/3`, `create_uac/2`, `request/2`, `create_b2bua/4`,
`proxy_request/3`. Each takes the remote res and routes the operation to
the engine-side proxy that owns the transaction, so no call needs the
engine's registered name on another node.

### Protocol

All messages are Erlang terms; the app library hides them.

```erlang
%% app -> SIP node (to the registered chappe_sip_app_endpoint_sup)
{register, AppName, #{max_inflight => 200, owner_grace_ms => 30000}}
    -> {ok, EndpointPid}
{route_add, EndpointPid, RouteSpec} -> {ok, RouteId}
{route_remove, EndpointPid, RouteId} -> ok

%% SIP node -> app (to the app's dispatcher, which spawns a handler)
{chappe_sip_request, DeliveryRef, Req, Res}
%% app -> SIP node: the handler took it (ends the delivery window)
{chappe_sip_accepted, DeliveryRef, HandlerPid}

%% app -> txn proxy (gen_server-style call)
{respond, Status, Opts}                 -> ok | {error, already_final}
{create_uas, Opts}                      -> {ok, Dialog} | {error, _}
{proxy, Dests, Opts}                    -> {ok, Result} | {error, _}
{b2bua, Uri, Opts}                      -> {ok, #{uas, uac}} | {error, _}
```

Dialog and UAC events keep their current shapes
(`{chappe_sip_dialog, Dialog, Event, Req, Res}`,
`{chappe_sip_uac, Ref, Event}`); only the `Res` inside them is a proxy
res. Funs in options are refused in remote mode: the UAC `answer` fun
becomes an `{answer_to, Pid}` message exchange, a registrar `secret` fun
stays a SIP-node configuration.

### Failure handling

- **App node lost before it accepted a request.** The endpoint sees
  `nodedown` or a missing `chappe_sip_accepted` within
  `delivery_timeout_ms`; the worker retries the next endpoint in the group,
  then the next route by priority, then answers 503 with Retry-After.
- **App lost after it accepted.** The worker monitors the handler pid.
  On `'DOWN'` with no final sent, it answers 500 (as today). If the
  handler had created a dialog in continue mode, the dialog goes orphaned
  and waits for a reattach.
- **App lost mid-call.** Dialogs in destroy mode end as today. Dialogs in
  continue mode wait `owner_grace_ms`. The restarted app calls
  `chappe_sip_dialog:list/1` and `attach/2` for each, then rebuilds from
  `app_data`.
- **SIP node restart.** Every remote monitor fires `noconnection`. The app
  library reconnects, re-registers its routes, and treats every dialog it
  held as gone (an `attach/2` with an old-boot handle returns
  `{error, unknown_dialog}`).
- **Netsplit.** Distribution detects a dead link only after
  `net_ticktime` (60 s by default). Set it low on both sides (for example
  10 s) or the SIP node keeps delivering to a vanished app for up to a
  minute. After a split heals, the epoch fence rejects operations from an
  owner that lost its dialogs while it was cut off.
- **Slow app.** `max_inflight` per endpoint: past it, the endpoint is
  skipped by the balancer. The handler deadline still bounds every
  transaction. A distribution channel that reports busy (`busy_dist_port`)
  marks the endpoint unhealthy instead of blocking the worker.
- **Partial delivery.** A request is either accepted (the app owns it) or
  retried elsewhere, never both: the worker ignores a late
  `chappe_sip_accepted` after it moved on, and the losing app's res calls
  get `{error, not_owner}`.

### Security

Distribution is full trust: any connected node can run any code on the
SIP node (`rpc`, `erlang:spawn/4`). Use it only between nodes you operate
in one trust domain.

- Move distribution off loopback only with TLS distribution
  (`-proto_dist inet_tls`, `verify_peer`, client certificates), a real
  cookie (`chappe_sip_app` already refuses the placeholder), and a fixed
  port range behind a firewall.
- Run app nodes as hidden nodes or with `-connect_all false`, so the app
  nodes do not mesh with each other through the SIP node.
- An endpoint can only be granted routes on its register call; there is no
  real isolation between apps under distribution, which is the main
  reason Model B exists.

### Cost

One extra message per request and one synchronous round trip per
response, over a link that is usually on a LAN. The `Req` already carries
the parsed message; send the raw bytes and parse on the app side if
profiling shows term copying matters. Distribution multiplexes everything
between two nodes on one connection, so a large body can delay other
messages; OTP fragments large messages, which limits this. Measure added
latency and cps against the in-node path before shipping, the same way
`PERF.md` records the mixer.

### Migration

In-node apps change nothing. To move an app out, you add
`chappe_sip_client` to it, point it at the SIP node, and replace
`chappe_sip:handle/3` with `chappe_sip_client:handle/3`. Code that uses
middleware, option funs, or `chappe_sip_res:finished/1` in a tight loop
needs a review.

## Model B: control socket

### Shape

```
 app (any language)                        SIP node
 -----------------                         ----------------------------
 inbound:  connect wss://sip:9022  ------> chappe_sip_ctl listener
 outbound: listen  wss://app:4000  <------ chappe_sip_ctl connector
                                           (a route whose target is a URL)
                 one chappe_sip_ctl_conn process per connection,
                 an endpoint in the same route table as Model A
```

Two modes, as in drachtio:

- **Inbound connect.** The app connects to a control listener on the SIP
  node, authenticates, and registers routes. Good for a few long-lived
  apps.
- **Outbound listen.** A route names a URL. When a request matches, the
  SIP node opens (or reuses, from a pool) a connection to that URL and
  delivers the request there. The app needs no knowledge of SIP nodes and
  can sit behind an HTTP load balancer, which is how you scale it. drachtio
  opens one connection per call in this mode; pooling is cheaper and is
  proposed as the default, with `per_call => true` as an option.

The connection process is just another endpoint: it translates between
frames and the same engine-side messages Model A uses, so the SIP node
logic is shared.

### Transport and framing

- WebSocket with subprotocol `chappe.ctl.v1` over TLS, reusing the `ws`
  dependency; or TCP over TLS with a 4-byte big-endian length prefix per
  frame. Plain TCP only on loopback.
- JSON by default (OTP's `json` module). An `encoding` field in `hello`
  leaves room for CBOR or MessagePack later.
- The raw SIP message is carried as a string and is the source of truth,
  like drachtio. A parsed summary rides along so a simple app does not
  need a SIP parser.

### Messages

Every frame is an object with `type`. Commands from the app carry an `id`
for the reply; events from the SIP node carry a per-connection `seq`.

```json
{"type":"hello","v":[1],"app":"ivr","auth":{"scheme":"hmac","key_id":"ivr1"},
 "max_inflight":200,"resume":{"session":"s1","token":"…","last_seq":4211}}
{"type":"challenge","nonce":"b64…"}
{"type":"auth","mac":"b64(HMAC-SHA256(secret, nonce))"}
{"type":"welcome","v":1,"session":"s1","token":"…","boot":"1730000000",
 "limits":{"max_frame":1048576,"max_inflight":200}}

{"type":"route.add","id":1,"method":"INVITE",
 "match":{"ruri_user":{"prefix":"+1"}},"priority":10,"group":"ivr"}
{"type":"result","id":1,"ok":{"route":"r7"}}

{"type":"request","seq":4212,"txn":"t.1730000000.88",
 "method":"INVITE","uri":"sip:+15551234@pbx","source":"10.0.0.9:5060",
 "transport":"udp","headers":{"from":"…","to":"…","call-id":"…"},
 "raw":"INVITE sip:+15551234@pbx SIP/2.0\r\n…"}
{"type":"accept","txn":"t.1730000000.88"}

{"type":"respond","id":2,"txn":"t.1730000000.88","status":180}
{"type":"uas.create","id":3,"txn":"t.1730000000.88","status":200,
 "sdp":"v=0…","on_owner_exit":"continue"}
{"type":"result","id":3,"ok":{"dialog":"d.1730000000.91"}}

{"type":"dialog.event","seq":4213,"dialog":"d.1730000000.91",
 "event":"info","txn":"t.1730000000.95","raw":"INFO …"}
{"type":"dialog.destroy","seq":4214,"dialog":"d.1730000000.91",
 "reason":{"bye":"remote"}}
{"type":"ack","seq":4214}
```

The full command set mirrors the Erlang API:

| Command | Maps to |
|---|---|
| `route.add`, `route.remove` | route table |
| `respond` (`reliable`, `to_tag`), `prack.await` | `chappe_sip_res:send/3`, `send_reliable/2`, `await_prack/2` |
| `uas.create` | `chappe_sip:create_uas/3` |
| `uac.create`, `request.send`, `uac.cancel` | `create_uac/2`, `request/2`, `chappe_sip_uac:cancel/1` (results stream as `uac.provisional`, `uac.early_dialog`, `uac.ok`, `uac.response`, `uac.error`) |
| `dialog.request`, `dialog.modify`, `dialog.notify`, `dialog.ack`, `dialog.destroy` | `chappe_sip_dialog` |
| `dialog.list`, `dialog.attach`, `dialog.set_data` | the reattach primitives |
| `proxy` | `proxy_request/3` (runs on the SIP node; the result comes back) |
| `b2bua` | `create_b2bua/4` plus `relay/2` on the SIP node |
| `ping`, `pong` | liveness |

Events: `request`, `txn.cancel`, `prack`, `dialog.event`,
`dialog.destroy`, `uac.*`, `route.lost` (a route removed by the server).
Errors use a fixed catalog (`not_owner`, `already_final`, `unknown_txn`,
`unknown_dialog`, `stale_boot`, `forbidden`, `overloaded`, `bad_request`).

Media (`chappe_sip_media`) is not in v1; see open questions.

### Delivery, acknowledgement and backpressure

- **Request delivery** has a window: the app must `accept` (or answer)
  within `delivery_timeout_ms`, otherwise the request is offered to the
  next endpoint in the group, then the next route, then answered 503.
- **Events** are numbered. The app acknowledges cumulatively with `ack`.
  The SIP node keeps unacknowledged events in a bounded per-session buffer
  so a resumed session can replay them.
- **Commands** are idempotent by `id` within a session: a command repeated
  after a reconnect returns the stored result instead of acting twice.
- **Credit.** The app announces `max_inflight` (requests it holds without
  a final). Past it, the endpoint is skipped by the balancer. If the
  outbound frame queue for a connection passes a high-water mark (bytes or
  frames), the connection is marked busy; if it stays over for
  `busy_timeout_ms`, the SIP node closes it and its dialogs go orphaned.
  The SIP node never blocks a worker or a dialog fsm on a socket write: the
  connection process owns the socket and the queue.

### Failure handling

- **App connection lost.** The session lingers for `resume_window_ms`. If
  the same app reconnects with the session id and token, its dialogs are
  rebound and unacknowledged events replayed; nothing in SIP notices. If
  not, routes are removed, in-flight requests are answered (500 if
  accepted, retried elsewhere if not), and dialogs follow their
  `on_owner_exit` policy.
- **App restart (new process, no resume token).** It reconnects, lists
  its dialogs with `dialog.list` (filtered by app name), and attaches them.
- **Outbound mode, instance gone.** The SIP node reconnects to the route
  URL; a load balancer may land on another instance. Orphaned dialogs of
  that group are then offered to the new connection as
  `dialog.orphaned` events, and any instance can `dialog.attach` them using
  `app_data`.
- **SIP node restart.** Connections drop; the boot stamp in `welcome`
  changes, so the app knows every handle it held is gone.
- **Slow app.** Covered by credit and the busy timeout above. The handler
  deadline still bounds each transaction.
- **Partial delivery.** A frame is either fully written or the connection
  is considered lost; there is no half-delivered request. After a
  reconnect the app may see a request twice (once before the drop, once
  replayed); `txn` identifies it, and only the first `accept` wins.

### Security

- TLS for every non-loopback listener and connector, with
  `verify_peer`. `verify_none` stays test-only.
- Authentication: either mTLS (the client certificate's SAN maps to an app
  name) or an HMAC challenge over a shared secret; the secret never
  travels. Tokens for session resume are random, per session, and expire
  with the resume window.
- Authorization per app name: which methods and match patterns it may
  register, whether it may `proxy`, which domains `uac.create` may target,
  and its `max_inflight` ceiling. An app cannot receive another app's
  requests or touch another app's dialogs (`not_owner`).
- Frame size limit (`max_frame`), and a limit on routes and sessions per
  app.

### Versioning

`hello.v` lists the protocol versions the app speaks; `welcome.v` picks
one. Within a major version, new message types and fields are additive and
receivers ignore unknown fields. A breaking change is a new major version
and a new WS subprotocol name; the SIP node supports the current and the
previous major.

### Cost

JSON encode and decode per frame, the raw message escaped as a JSON
string, plus a socket write and read. That costs more than Model A, and the
extra round trip on each `respond` matters most on short transactions
(OPTIONS, REGISTER). Keep keep-alive traffic (OPTIONS pings, REGISTER
refreshes) answerable on the SIP node with in-node handlers, and send only
call logic to remote apps. Benchmark against the in-node path before
shipping.

### Migration

Same rule: in-node is unchanged. A non-Erlang app is new code against
the protocol (a small client library per language, starting with one).
An Erlang app does not need Model B; it can use Model A, or the socket if
it must cross a trust boundary.

## Recommendation

Build the shared core first, then the socket, and treat distribution as a
thin convenience on top.

1. **Phase 0, in-node (no remote yet).** The route table with match
   rules, priorities and groups; the proxy form of `chappe_sip_res`; dialog
   orphaning, `attach/2`, `list/1`, `set_app_data/2` and the owner epoch;
   media following the dialog in continue mode; opaque handles with the
   boot stamp. Ship it as an in-node feature: it already gives Erlang
   products "deploy without dropping calls" (Option C) and per-package
   SUBSCRIBE routing.
2. **Phase 1, control socket, inbound connect.** `chappe_sip_ctl` with
   hello, auth, routes, request delivery, responses, UAS, UAC, dialog ops,
   resume and credit. One reference client (Erlang, which also serves as
   the conformance test driver), then one non-Erlang client.
3. **Phase 2, outbound listen.** URL route targets, connection pools,
   orphan offers for load-balanced instances.
4. **Phase 3, Erlang distribution endpoint.** `chappe_sip_client` for
   Erlang products in one trust domain that want the `chappe_sip` API
   remotely, at a lower cost than JSON.

Why the socket before distribution: it is the only model that gives real
isolation between apps, works across languages and load balancers, and
keeps distribution on loopback as `vm.args.src` intends. Distribution is
cheap to add once Phase 0 exists, and is opt-in for people who already run
TLS distribution. If your products are all Erlang and run next to the SIP
node, swap phases 1 and 3.

Each phase ships with requirement rows, failing tests first, a benchmark
against the in-node path, and its own design update here.

## Decisions

Recorded on 2026-10-03 after review:

- The phases ship in the order of the Recommendation: Phase 0 (in-node
  groundwork), then Phase 1 (control socket, apps connect in), then Phase 2
  (outbound connect), then Phase 3 (Erlang distribution client). This answers
  open question 1.
- Remote clients are separate hex packages, not modules of `chappe_sip`: the
  reference socket client and the Erlang distribution client each get their
  own package. This answers open question 2.

The remaining open questions are settled in the plan of the phase they
belong to.

## Open questions

1. (Decided: phases in order.) Is the first remote consumer an Erlang product or a non-Erlang one (the
   AI voice product)? That decides whether Phase 1 is the socket or
   distribution.
2. (Decided: separate hex packages.) Should `chappe_sip_client` (Model A) and the reference socket client be
   separate hex packages, or modules inside `chappe_sip`?
3. Orphaned dialogs: answer a re-INVITE with 491 or with 500 plus
   Retry-After? And should the default `owner_grace_ms` be 0 (today's
   behaviour) even in continue mode?
4. Owner epoch fencing: should it apply in-node too, where any process
   holding a `#dialog{}` can operate on it today?
5. How much media to expose remotely in v1: none, a `media.anchor`
   subset, or the full `chappe_sip_media` facade?
6. Middleware: keep it SIP-node only (auth, rate limits, as policy), or
   let remote apps register pre-route filters?
7. Should the per-boot nonce secret and flow-token secret be required in
   config when several SIP nodes front one app group, so digest nonces and
   flow tokens validate on any of them?
8. Outbound listen: pooled connections by default, or one connection per
   call as drachtio does?
9. Do we want CDR, HEP and presence events available on the socket from
   Phase 1, or later?
