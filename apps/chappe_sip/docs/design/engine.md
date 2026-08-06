# The engine: sofia-sip inside the VM

This document describes how the SIP engine is embedded and what keeps the
VM safe. Read it before touching `c_src/chappe_sip_engine_nif.c`.

## Shape

The engine is sofia-sip's nta transaction layer compiled into
`priv/lib/chappe_sip_engine_nif.so` and driven through a thin plain-C shim.
There is no dialog, proxy, or offer/answer logic in C; all of that is
Erlang. The shim wraps four nta object kinds: agent, leg, incoming
(server transaction), outgoing (client transaction).

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

## Abort audit (M0, sofia @ 7333682, freeswitch fork)

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

## Memory-safety checks

`ENGINE_SANITIZE=address` (or `undefined`) in `c_src/build.sh` builds the
shim with the sanitizer. Loading a sanitized `.so` into the BEAM requires
preloading the sanitizer runtime:

```sh
# Linux
ENGINE_SANITIZE=address rebar3 compile
LD_PRELOAD=$(cc -print-file-name=libasan.so) rebar3 ct --suite=test/chappe_sip_handler_SUITE

# macOS
ENGINE_SANITIZE=address rebar3 compile
DYLD_INSERT_LIBRARIES=$(cc -print-file-name=libclang_rt.asan_osx_dynamic.dylib) \
  rebar3 ct --suite=test/chappe_sip_handler_SUITE
```

`test/asan/run.sh` runs the lifecycle suites (`chappe_sip_engine_smoke`, `chappe_sip_dialog_ops`,
`chappe_sip_engine_lifecycle`) under ASan in a Linux container; macOS strips ASan
interceptors for a dlopen'd NIF, so use the container.
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
             cert_dir => <<"/etc/enki/certs">>,
             verify => none}}).
```

- The TLS contact must use the `sips:` scheme (a `sip:` URI only resolves
  udp/tcp/sctp/ws); `;transport=tls` restricts it to TLS alone (a bare
  `sips:` contact would also try to bind wss, which needs its own certs).
- `cert_dir` holds `agent.pem` (certificate + private key, concatenated)
  and `cafile.pem`. sofia also reads an optional `tls_seed.dat`.
- The shim passes an explicit `TPTAG_TLS_VERSION` floored at TLS 1.2 (the
  sofia default disables modern TLS) and a default cipher list (sofia rejects a
  NULL cipher list); override the ciphers with the `ciphers` key.
- `verify => peer` requires a client certificate; the default is `none`.
- Portability: a build host without OpenSSL development headers makes
  `build.sh` pass `--with-openssl=no`, which silently drops TLS (and WSS).

## macOS notes

- `libsofia-sip-ua.a` references CoreFoundation and SystemConfiguration
  (`su_os_nw.c`); both sofia's own utilities and the NIF link with those
  frameworks.
- An unrestricted contact (`transport=*`) makes the freeswitch fork bind
  ws on the same TCP port and fail with "address already in use";
  chappe_sip_engine defaults contacts to `;transport=udp,tcp`.
