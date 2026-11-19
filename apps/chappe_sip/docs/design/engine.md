# The engine: sofia-sip inside the VM

This document describes how the SIP engine is embedded, what crosses the
boundary between C and Erlang, and what keeps the VM safe. Read it before
you touch `c_src/chappe_sip_engine_nif.c`, `src/engine/chappe_sip_nif.erl`
or `src/engine/chappe_sip_engine.erl`. The layers above the engine are in
the [overview](overview.md).

## Shape

The engine is sofia-sip's nta transaction layer compiled into
`priv/lib/chappe_sip_engine_nif.so` and driven through a thin plain-C shim.
There is no dialog, proxy, or offer/answer logic in C; all of that is
Erlang. The shim wraps four nta object kinds: agent, leg, incoming
(server transaction), outgoing (client transaction).

Requests reach Erlang through two nta callbacks: the default leg (out of
dialog) and one leg per dialog. nta never matches a SUBSCRIBE to a dialog
leg (it leaves subscriptions to nua, which the shim does not use), so the
default-leg callback looks a To-tagged SUBSCRIBE up with
`nta_leg_by_dialog` and delivers it on that dialog's leg. That is what lets
a subscription dialog see its refreshes; the WS transport matches legs by
Call-ID and tags for every method and needs no such step.

## Why a NIF

The decision and its alternatives are recorded in
[decision 0001](../../../../docs/decisions/0001-sofia-nta-nif.md).
What the repository itself shows:

- sofia-sip's nta already implements the RFC 3261 transaction layer, RFC
  3263 resolution (NAPTR, SRV, A, checked against dnsmasq in the
  conformance lab), RFC 5626 flows on TCP and TLS, TLS with RFC 5922
  verification, and the RFC 4475 parser edge cases; chappe_sip reuses it
  (`c_src/sofia-sip`, vendored as upstream ships it, LGPL-2.1). The few
  fixes it needs are patches in `c_src/sofia-patches`, each with an upstream
  ticket and a repro, applied to a copy of the tree at build time
  (`c_src/prepare_sofia.sh`, see the patches' README).
- The shim is about 2600 lines of C and carries no SIP logic: raw messages
  cross as binaries, and dialogs, proxying and offer/answer are Erlang.
- The cost is that a crash in sofia or the shim takes the node down. The
  mitigations are below: the small surface, AddressSanitizer and
  LeakSanitizer in CI (`make asan`), the lifecycle stress suite, and running
  the release under heart or systemd.
- WebSocket does not go through the NIF; see
  [the WebSocket transport](ws-transport.md).

## The event contract

The NIF talks to one owner process, `chappe_sip_engine`. Every function of
`chappe_sip_nif` except `start/2` and `stop/1` (dirty IO NIFs) is
enqueue-only: it allocates an operation, hands it to the stack thread and
returns. A creating operation (`request/3,4,5`, `leg_create/4`) returns a
handle at once, but the nta object is built later on the stack thread; its
success or failure arrives as an event. Enqueue success is not operation
success.

Events arrive as `{chappe_sip_engine, EngineRef, Event}`:

| Event | Meaning |
|---|---|
| `{request, TxnH, LegH \| undefined, Meta, RawSip}` | An inbound request; `LegH` when it is in a dialog leg. `Meta` carries the method, `source_ip`, `source_port`, the transport, `conn` (the TCP/TLS flow id), and `local_ip`, `local_port`, `local` (the listen address and its ident). |
| `{response, TxnH, Meta, RawSip}` | A response to one of our requests. |
| `{ack, LegH \| TxnH, RawSip}` | The ACK of a 2xx, on a dialog leg or on the INVITE server transaction. |
| `{ack_timeout, LegH \| TxnH}` | That 2xx was never ACKed. |
| `{cancel, TxnH}` | A CANCEL of our server transaction. |
| `{op_ok, H}`, `{op_failed, H, Reason}` | The result of a deferred operation. |
| `{flow_closed, FlowId}` | A TCP/TLS connection we hold a flow on closed. |
| `{health_ok, Seq}` | The answer to `health/1`, from inside the event loop. |
| `{started, Contact}` | The stack is READY. |
| `{log, Level, Text}` | sofia's log, bridged to `logger`. |

The WebSocket transport emits the same events as
`{chappe_sip_engine, ws, Event}`, so the engine treats both alike. The
authoritative list is the header of `src/engine/chappe_sip_nif.erl`; change
both together.

## chappe_sip_engine: what it is responsible for

`chappe_sip_engine` is the one process that talks to the NIF. It keeps
the gen_server, the call envelopes and the stack's lifecycle; its helper
modules run in the same process, on the `#state{}` they share through
`src/engine/chappe_sip_engine.hrl`. Before you add to it, find the part
you are changing:

| Responsibility | Where |
|---|---|
| NIF lifecycle and health | `chappe_sip_engine`: `start/1`, `stop/0`, `restart_engine/0`, `check_health/1`, `bring_up`, `start_engine`, `engine_failed`, `stack_gone` (the `chappe_sip_engine_restart` message), `stack_down`, `schedule_health` |
| Start options | `chappe_sip_engine_opts`: `start_opts/1` (TLS, listen addresses, agent settings, size cap, HEP capture; no side effect), `tls_uri/2` |
| Config snapshot (survives an engine crash) | `chappe_sip_engine_opts`: `cfg_put/2`, `cfg_get/2`, `cfg_del/1` over the `chappe_sip_engine_cfg` ETS table owned by `chappe_sip_registry_keeper` |
| Route registry | `chappe_sip_engine`: `use/2`, `handle/3`, `reset_routes/0`; kept by `chappe_sip_engine_opts:routes/3` |
| Inbound events and dispatch | `chappe_sip_engine_events`: `handle_event/2`, `to_owner`, `dispatch`, `dispatch_route`, `dispatch_handler`, `cancelled`, the 481 (`no_dialog`) and the 503 (`busy`); the pure policy in `chappe_sip_dispatch` (`stray_in_dialog`, `route_for`, `unrouted`, `merge_check` for RFC 3261 8.2.2.2, `is_own_route`) |
| Worker pool | `chappe_sip_engine_events`: `spawn_worker`, `handler_deadline`; `chappe_sip_engine_handles`: `disarm_deadline/2`, `down/4` (the 500 of a worker gone without a final) |
| Handle table and dialogs | `chappe_sip_engine_handles`: `handle/3` (`create_uas`, `early_leg`, `create_dialog`, `mark_proxied`, `disarm`, `reg_handle`), `ensure_monitored/2`, `down/4` |
| UAS response building | `chappe_sip_engine_handles`: `start_uas`; the pure part in `chappe_sip_uas_response` (`build/2`, `contact/3`, `fsm_args/2`) |
| Backend and WS calls | `chappe_sip_engine_backend`: every call to the engine backend (`engine_mod`), to `chappe_sip_ws_transport` (by `chappe_sip_ws:is_ws/1`) and to the forwarder (`forwarder/1`, `forward_ack/3`); `respond/8`, `relay/5`, `request/6`, `leg_create/6`, `leg_destroy/3`, `sender/2`, `native_route/1` |
| Closed connections | `chappe_sip_engine_conns`: `conn_closed/1`, `closed/1`, `clear/0` (RFC 5626 5.3, read by the edge proxy) |

The guard support (`discard/1`, `block_source/2`, `stats/0`) and the proxy
support (`mark_proxied/1`, `relay_response/3`, `forward_response/1`) sit on
top of these. Tests reach the engine through its exported API, and the
pure parts through `chappe_sip_engine_tests` (start options, `tls_uri/2`,
`native_route/1`, `raw_method/1`).

## Threads

- `su_init()` runs once at NIF load; `su_deinit()` at unload. Per-engine
  lifecycle is only su_root + nta_agent, so stop/start cycles never
  repeat global init.
- One engine thread (created with `enif_thread_create`) runs
  `su_root_run`. Every nta call happens on that thread. NIF calls
  allocate a handle id and enqueue an operation with `su_msg_send`,
  which is safe from foreign threads; results and SIP traffic return via
  `enif_send` from the stack thread.
- Scheduler threads never block on the engine: `start/2` and `stop/1`
  are dirty IO NIFs, everything else is enqueue-only.
- The handle table (handle id to nta object) is a chained hash table with
  4096 buckets, touched only by the stack thread, so a lookup stays
  constant time however many transactions and legs are live.

## nta settings that differ from a plain UA

- `NTATAG_MERGE_482(0)`: merged-request detection (RFC 3261 8.2.2.2) runs
  in `chappe_sip_engine`, which knows which server transactions a proxy
  owns, so a request spiralling back through the proxy is not refused.
- `NTATAG_CANCEL_487(0)`: the CANCEL callback answers a UAS INVITE 487
  itself, but not one a proxy owns (`proxy_mark/2`): the proxy relays the
  downstream 487, or a 2xx that crossed the CANCEL (RFC 3261 16.10).
- A proxy INVITE branch (`request/4`, which also sets the Via branch to the
  loop-detection hash) is created with UA mode off for that call, so the
  client transaction passes every 2xx up instead of ACKing and BYEing a
  second one (RFC 6026).
- On TCP/TLS nta terminates an INVITE client transaction at its first
  final response, so a later 2xx of the same branch (a fork downstream)
  matches no transaction. The agent is created with a message callback
  (`stray_cb`), which nta calls for such a response: a 2xx to an INVITE
  whose top Via branch is a live proxy branch (`nta_outgoing_branch`) goes
  to that branch's handle, the proxy still being in the Accepted state;
  anything else is dropped as before.

## Several listen addresses

`contact` and the TLS `contact` take a list (`chappe_sip_binds:options/1`
turns it into the NIF's `contact`, `ident` and `contacts`). The first
address goes to `nta_agent_create`, every other one to
`nta_agent_add_tport`, each with `TPTAG_IDENT(Ident)`, the address's host
in canonical form; addresses on one host (UDP, TCP and TLS) share an ident.
tport compares a requested ident with every primary's using `strcmp` and no
NULL check, so the shim sets an ident on every transport and accepts more
than one address only with idents throughout.

- Receiving: the request meta carries `local_ip` and `local_port` (the
  bound address of the primary transport, the parent of a connection) and
  `local` (its `tport_ident`).
- Sending: `request/5` and `send/4` pass an ident as `TPTAG_IDENT` to
  `nta_outgoing_mcreate`; nta then picks the primary with that ident and the
  request's protocol and family, and the Via is that primary's. The engine
  keeps the ident per sending process (a dialog, a UAC), so a dialog's
  in-dialog requests and ACKs leave from the address it was formed on.

## HEP capture

A `capture` start option (built by `chappe_sip_engine` from the `hep`
option) is passed to `nta_agent_create` as `TPTAG_CAPT`: tport then sends a
HEPv3 copy of every message it sends and receives over a UDP socket of its
own. tport never closes that socket (`tport_destroy` leaves `mr_capt_sock`
open), so the stack thread finds it right after the agent is created (the
datagram socket, new since the create, connected to the collector's port,
from a `/dev/fd` listing before and after) and closes it after the agent is
destroyed. Without that, every engine restart with capture on would leak a
descriptor. The WebSocket transport is Erlang and is captured by
`chappe_sip_hep`.

## Flows (RFC 5626)

A request that arrives over a TCP or TLS connection (a secondary, reliable
tport) carries `conn => FlowId` in its meta. The first request on a
connection creates the flow: the shim takes a `tport_ref` (the pointer stays
valid) and a pending entry with `tport_pend(tp, NULL, ...)`, so tport
reports the connection's close or error to `flow_err_cb`. That drops the
reference and sends `{flow_closed, FlowId}`; the engine then removes the
bindings learned on it. The health tick also sweeps flows whose tport is
closed. `request/3,4` and `send/3` take a flow id as the route and send with
`NTATAG_TPORT`, so the request goes over that connection. Engine teardown
releases every flow before the agent is destroyed.

## Lifecycle protocols

- Root lifetime: `su_root` is created and destroyed on the stack thread,
  but foreign threads read it in `enqueue` (via `su_root_task`). An
  `ErlNifRWLock` guards it: an op takes the read side, re-checks READY,
  posts its `su_msg`, and releases; teardown takes the write side to
  destroy the root. So an op never touches a freed root, and an op that
  arrives after STOPPING is rejected instead of dropped behind OP_STOP
  (which would leak its payload and a kept ref).
- Startup readiness barrier: the stack thread performs all sofia setup,
  then a single `CAS INIT -> READY` publishes it. `start` polls boundedly
  and joins on FAILED. On timeout `start` claims `CAS INIT -> STOPPING`
  instead; the two are mutually exclusive, so a thread the start gave up
  on never goes READY and runs orphaned.
- Destructor safety: the stack thread holds one resource reference for its
  whole life and drops it as its last act. The destructor therefore runs
  only after the thread has exited, so it never joins or frees under a
  running (or stuck) thread and never blocks a scheduler. It reclaims the
  thread handle unless it is itself the exiting thread (compared with
  `enif_equal_tids`), where a self-join would deadlock.
- Shutdown: `stop` moves the state to STOPPING and wakes the loop; the
  stack thread destroys the agent, drains the handle table, breaks the
  loop, and destroys the root under the write lock. `stop` polls EXITED
  (50ms steps, 5s cap) and joins. On timeout it returns `{error, hung}`
  without joining or freeing; the stuck thread keeps the resource alive
  (no use-after-free), and if it ever unblocks it self-cleans and resets
  the singleton. The thread slot leaks in that pathological case by design.
- Singleton: one engine at a time. `g_engine_state` (C atomic) plus the
  chappe_sip_engine gen_server serialize detach, stop, and reattach; while a
  teardown is in flight `start` returns `{error, stopping}` and the
  Erlang side retries with capped backoff.
- Owner monitor: the C side monitors the chappe_sip_engine pid. Owner death
  triggers an asynchronous stop; the supervisor restarts chappe_sip_engine,
  which starts a fresh engine against the serialization guard.

## Health and the hang policy

`chappe_sip_nif:health/1` enqueues a no-op answered from inside the su_root
event loop. It proves the loop is being serviced; nothing can answer it
from a side thread. chappe_sip_engine sends one every `health_interval_ms`
(5s); after `health_miss_limit` (3) misses it attempts a bounded stop
and applies `engine_failure_action`:

- `halt` (default): log critical, flush, `erlang:halt(1)`. A hung sofia
  thread cannot trip heart on its own because the BEAM stays responsive;
  halting is the deliberate path that lets heart or systemd restart the
  node.
- `degrade`: leave SIP dead and the node up, for operators with external
  watchdogs.

## Risky regions

These are the places in the C shim where a change can corrupt memory, leak,
or deadlock. Read the comment above each function before you edit it, and
run `make asan` after. The last column names the suites that exercise the
region; run them under the sanitizers when you touch it.

| Region | Functions | What can go wrong | Tests |
|---|---|---|---|
| State CAS | `nif_start`, `stack_main`, `set_failed`, `request_stop` | `INIT -> READY` (stack thread), `INIT -> STOPPING` (a start that gave up) and `INIT -> FAILED` must stay mutually exclusive; a plain store lets an abandoned thread run orphaned. | `chappe_sip_engine_lifecycle_SUITE`, `chappe_sip_engine_smoke_SUITE` (`bind_failure`, `start_stop_cycles`) |
| Root rwlock in enqueue | `enqueue`, `enqueue_locked`, `request_stop`, `teardown_sofia` | Foreign threads post under the read lock after re-checking READY; `request_stop` flips to STOPPING and posts OP_STOP under the write lock, so no op lands behind OP_STOP (it would leak its payload and a kept engine ref); the root is destroyed under the write lock. | `chappe_sip_engine_lifecycle_SUITE` |
| Engine destructor and owner down | `engine_dtor`, `engine_down`, `thread_exit`, `start_refused` | The stack thread holds a resource ref until its last act, so the destructor runs after it exited; never self-join (`enif_equal_tids`), and never compare the tid of an engine refused before its thread existed (`tid_valid` first); release the singleton only by CAS from `G_STOPPING`, or a successor engine is clobbered. | `chappe_sip_nif_boundary_SUITE` (refused starts, a dead owner), `chappe_sip_engine_lifecycle_SUITE` |
| Handle table drain, orphans, proxy branch list | `tab_drain`, `tab_del`, `ctx_release`, `orphans_sweep`, `px_unlink` | Teardown destroys every nta object before the agent; an incoming ctx a PRACK callback may still use goes on the orphan list instead of being freed; an outgoing ctx must leave the `px_head` list `stray_cb` walks before it is freed. | `chappe_sip_dialog_ops_SUITE`, `chappe_sip_prack_SUITE`, `chappe_sip_proxy_forking_SUITE` |
| Flows | `flow_of`, `flow_free`, `flow_closed`, `flows_sweep`, `flow_err_cb` | A flow holds a `tport_ref` and a pending entry; both are released once, and the H_FLOW handle is removed by the caller. | `chappe_sip_transport_SUITE`, `chappe_sip_registrar_SUITE` |
| Stray 2xx | `stray_cb`, `outgoing_response_cb` | A later 2xx of a proxy INVITE branch over TCP/TLS matches no transaction; it is sent to the branch handle only while that branch is in `px_head` (RFC 6026 Accepted state), else dropped. The outgoing callback never destroys the transaction: Erlang does with `txn_done`. | `chappe_sip_forked_2xx_SUITE`, `chappe_sip_proxy_forking_SUITE` |
| Request intake and discard | `request_in`, `blk_msg`, `blk_put`, `blk_has`, the `OP_DISCARD` case of `op_cb` | A blocked source is discarded before a server transaction exists; the blocklist is process-wide under `g_blk_lock` and outlives an engine; a discarded transaction gets no 100 Trying and ends with nta's silent 408. | `chappe_sip_guard_SUITE` |
| The op dispatcher | `op_cb` (about 300 lines, 14 ops) | Every op must look its handle up with the right kind (`tab_get`), answer `op_failed` for an unknown one, and free its payload on every path (`op_free_payload`); an unknown kind reaches `default:`. | `chappe_sip_engine_smoke_SUITE`, `chappe_sip_dialog_ops_SUITE`, `chappe_sip_ops_SUITE` |
| The NIF boundary | `nif_reply`, `send_raw`, `nif_leg_create`, `nif_cancel`, `get_opt_bin`, `get_tls`, `get_capture`, `get_max_size` | Every string sofia reads as a C string is refused when it holds a NUL, every size is capped before the copy, and a start option that is there but invalid fails the start. | `chappe_sip_nif_boundary_SUITE`, `chappe_sip_ops_SUITE` (`max_message_size_*`) |

## Safety rules

The NIF runs inside the VM, so a fault in it takes the node down
([decision 0001](../../../../docs/decisions/0001-sofia-nta-nif.md)). Every
change to `chappe_sip_engine_nif.c` keeps these rules:

- **Explicit lengths, checked sizes.** A binary is copied with its length,
  never found by `strlen`. Every computed allocation size goes through
  `chk_add`/`chk_mul` (C23 `ckd_add`/`ckd_mul` when the compiler has them,
  the gcc/clang overflow builtins otherwise). Numbers from text are read
  with `parse_long`, which takes the whole string or nothing.
- **No raw pointer handed to Erlang.** Erlang holds the engine as a
  refcounted resource and nta objects as integer handles looked up in the
  handle table, by kind.
- **One sofia owner thread.** Every nta and tport call happens on the stack
  thread. A NIF only checks its arguments, copies them into an op and
  enqueues it (`enqueue`), except `start/2` and `stop/1`.
- **Every op answers and frees.** Each path through `op_cb` frees the op's
  payload and, for an op with a handle, answers `op_ok` or `op_failed`. A
  NIF that cannot queue an op frees what it copied.
- **Checks at the boundary.** NUL bytes are refused in headers, body,
  route, reason, to-tag, the leg Call-ID, local and remote, and every start
  option string. Leg fields are capped at 8 KiB, `max_message_size` must be
  1 KiB to 64 MiB, a capture port 1 to 65535, the SIP timers, `udp_mtu` and
  `tcp_keepalive_ms` within the bounds of `get_agent_opts`, and an outbound
  proxy a `sip:` or `sips:` URI (nta drops any other without a word, so the
  shim also checks it took one). A start option that is there
  but invalid is `{error, badarg}`, never ignored.
- **No silent failure.** A status helper is `NODISCARD` (C23 `[[nodiscard]]`
  or `warn_unused_result`). An allocation that fails in a NIF returns
  `{error, enomem}` instead of sending the op without its fields. An event
  that cannot be delivered is counted in `events_dropped` and written to
  stderr once per window; an event binary that cannot be allocated is
  counted in `alloc_failed` (both in `chappe_sip_engine:stats/0`). A failed
  nta call the op cannot answer for (`nta_*_set_params`, `nta_incoming_tag`)
  is logged as a warning. `static_assert` pins the buffer sizes and table
  shapes the code relies on.

The build enforces part of this. `c_src/build.sh` compiles the shim with
`-std=gnu17`, `-Wall -Wextra -Wformat=2 -Wconversion -Wsign-conversion
-Wshadow -Wnull-dereference -Wimplicit-fallthrough`, the stack protector,
stack clash protection, `_FORTIFY_SOURCE=3` (not under a sanitizer),
zero-initialised automatic variables, control-flow protection
(`-fcf-protection` on x86_64, `-mbranch-protection=standard` on arm64) and
full RELRO with a non-executable stack on Linux. Each flag is kept only
when the compiler takes it, and the build prints the flags it kept.
`ENGINE_WERROR=1`, which CI sets, makes every warning in the shim an error.
`CC` picks the compiler and `ENGINE_EXTRA_CFLAGS` adds flags to the shim;
both are part of the build stamp, so changing either rebuilds the NIF.
The erts and sofia headers are included with `-isystem`, and sofia itself
keeps its own flags.

## How to check

| Command | What it runs |
|---|---|
| `make asan` | every chappe_sip suite with the NIF under AddressSanitizer, LeakSanitizer and UndefinedBehaviorSanitizer (UBSan halts on the first error) and the BEAM allocators off (`+Mea min`), in a Linux container |
| `make tsan` | the lifecycle stress and smoke suites with the NIF under ThreadSanitizer, for the threading of the stack thread and the NIF callers; the shim tells TSan that a destructor happens before ERTS reuses its memory (`TSAN_RELEASE`, `TSAN_ACQUIRE`), since the ERTS allocator is not instrumented |
| `make lint-c` | clang-tidy (`bugprone-*`, `cert-*`, `clang-analyzer-*`, `misc-*`, configured in `.clang-tidy`) and `gcc -fanalyzer` over the shim only |
| `make fuzz` | the libFuzzer targets in `c_src/fuzz/` on sofia's message and header parsers (sofia built from the same patched copy as the NIF's), and the NIF boundary fuzz suite; `FUZZ_TIME` sets the run in seconds, crashes are kept as regression seeds |
| `ENGINE_WERROR=1 rebar3 compile` | the hardened build with warnings as errors, as CI builds it |

## Memory-safety checks

`ENGINE_SANITIZE=address` (or `undefined`) in `c_src/build.sh` builds the
shim with the sanitizer. Loading a sanitized `.so` into the BEAM requires
preloading the sanitizer runtime:

```sh
# Linux, from the umbrella root
ENGINE_SANITIZE=address rebar3 compile
LD_PRELOAD=$(cc -print-file-name=libasan.so) rebar3 ct --suite=apps/chappe_sip/test/chappe_sip_handler_SUITE

# macOS
ENGINE_SANITIZE=address rebar3 compile
DYLD_INSERT_LIBRARIES=$(cc -print-file-name=libclang_rt.asan_osx_dynamic.dylib) \
  rebar3 ct --suite=apps/chappe_sip/test/chappe_sip_handler_SUITE
```

`make asan` (`apps/chappe_sip/test/asan/run.sh`) runs every chappe_sip suite
under ASan and UBSan in a Linux container, from the umbrella root so the
suites that need a sibling app (the SIPREC and media ones) run too; macOS
strips ASan interceptors for a dlopen'd NIF, so use the container. Every
suite starts the NIF, and a path only one of them reaches (two listen
addresses, forking, TLS) is otherwise never under ASan. The BEAM runs with
`+Mea min`: without it `enif_alloc` comes from the BEAM's own allocators,
which ASan does not see, so a use after `enif_free` of an op or a payload
goes unnoticed.
LeakSanitizer is on: a leak allocated on a NIF call path (sofia or the shim)
fails the run. `test/asan/lsan.supp` suppresses only stacks that never carry a
NIF frame: the erts DNS helper, the programs rebar3 runs, and OTP's crypto NIF.
Set `ASAN_DETECT_LEAKS=0` to check memory errors only, and `ASAN_VOLUME` to
use another build volume when two runs share a Docker host.
`chappe_sip_engine_lifecycle_SUITE` is the lifecycle stress: it races inbound
traffic against stop and restart over many cycles, exercising the
enqueue-vs-root-destroy lock, the INIT->READY/abandon CAS, and the thread-ref
destructor.

For valgrind, run the ct suites under `cerl -valgrind` or start the node
with `valgrind erl ...` and drive `chappe_sip_handler_SUITE` (start/stop cycling and
the OPTIONS burst exercise allocation and teardown paths). The
start/stop-cycle and burst cases in `chappe_sip_handler_SUITE` are the intended load
for both tools.

## TLS

A TLS listener is bound on its own port, separate from the primary
UDP/TCP contact, because comma-listed transports share one port. Pass a
`tls` option to `chappe_sip:start/1`:

```erlang
chappe_sip:start(#{
    contact => <<"sip:0.0.0.0:5060">>,
    tls => #{contact => <<"sips:0.0.0.0:5061;transport=tls">>,
             cert_dir => <<"/etc/chappe/certs">>}}).
```

- The TLS contact must use the `sips:` scheme (a `sip:` URI only resolves
  udp/tcp/sctp/ws); `;transport=tls` restricts it to TLS alone (a bare
  `sips:` contact would also try to bind wss, which needs its own certs).
- `cert_dir` holds `agent.pem` (certificate + private key, concatenated)
  and `cafile.pem`. sofia also reads an optional `tls_seed.dat`.
- The shim passes an explicit `TPTAG_TLS_VERSION` floored at TLS 1.2 (the
  sofia default disables modern TLS) and a default cipher list (sofia rejects a
  NULL cipher list); override the ciphers with the `ciphers` key.
- `verify => peer` (the default) checks the server certificate of outbound
  connections: `TPTLS_VERIFY_SUBJECTS_OUT`, so the chain must reach
  `cafile.pem` and the target host must be among the certificate's
  subjectAltName URI/DNS entries (RFC 5922). `verify_clients => true` adds
  `TPTLS_VERIFY_IN` (a client certificate is required). `verify => none` is
  accepted only with `allow_insecure => true`.
- Portability: a build host without OpenSSL development headers makes
  `build.sh` pass `--with-openssl=no`, which silently drops TLS (and WSS).

## macOS notes

- `libsofia-sip-ua.a` references CoreFoundation and SystemConfiguration
  (`su_os_nw.c`); both sofia's own utilities and the NIF link with those
  frameworks.
- An unrestricted contact (`transport=*`) makes the freeswitch fork bind
  ws on the same TCP port and fail with "address already in use";
  chappe_sip_bind_uri defaults contacts to `;transport=udp,tcp` (`tls` for a
  sips: or TLS contact) and refuses one naming `ws`, `wss` or `*`, so
  sofia's own WebSocket transport is never opened. sofia is also built
  with `--disable-nth`, so its ws, wss, HTTP CONNECT, http and nth code is
  not compiled (patch 0007 makes that build link; see
  `c_src/sofia-patches/README.md`).

## Appendix: abort audit (M0, sofia @ 7333682, freeswitch fork)

- `exit()`/`abort()` call sites in the modules we link (su, msg, url,
  sip, nta, tport) exist only in standalone utility and test programs
  (`addrinfo.c`, `localinfo.c`, `su_perf.c`, `su_proxy.c`, `test_*.c`).
  They are separate binaries and are not part of `libsofia-sip-ua.a`
  code paths reachable from the shim.
- Library `assert()` calls (su_alloc.c and friends) are compiled out:
  the build passes `-DNDEBUG` (see `c_src/build.sh`).
- `su_log` output is redirected into the shim; before the engine is
  READY it goes to stderr, afterwards it becomes `{log, Level, Text}`
  events bridged to `logger`.
- A crash in sofia or the shim still kills the node. That is the
  accepted trade-off of the NIF design; the mitigations are the small C
  surface, the ASan/UBSan and valgrind procedure below, and running the
  release under heart.
