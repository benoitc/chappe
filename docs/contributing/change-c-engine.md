# Change the C engine

The SIP engine is sofia-sip's nta transaction layer, linked into a NIF through
a plain-C shim, `apps/chappe_sip/c_src/chappe_sip_engine_nif.c`. A bug there
does not crash a process, it crashes the node. Use this page when you add an
operation or an event to the NIF, change its threading or lifecycle, or move
the vendored sofia-sip.

## Before you start

- [apps/chappe_sip/docs/design/engine.md](../../apps/chappe_sip/docs/design/engine.md),
  all of it: shape, threads, lifecycle protocols, health and hang policy,
  memory-safety checks.
- [concepts.md: Engine and nta](../concepts.md#engine-and-nta).
- [docs/decisions/](../decisions/): why a NIF over sofia nta.

## Where to look

| Piece | Where (under `apps/chappe_sip/`) |
|---|---|
| The shim | `c_src/chappe_sip_engine_nif.c` |
| The build | `c_src/build.sh` (stamp-gated: sofia rebuilds when its tree changes, the NIF when the shim, the script, the sanitizer or ERTS change) |
| Vendored sofia-sip (LGPL-2.1, keep unmodified) | `c_src/sofia-sip/`, `NOTICE` |
| NIF stubs and the event contract | `src/engine/chappe_sip_nif.erl` (`{chappe_sip_engine, Ref, Event}` and every event shape) |
| The process that owns the NIF | `src/engine/chappe_sip_engine.erl` |
| The pure-Erlang stand-in | `test/chappe_sip_engine_fake.erl`: the same call surface |
| ASan | `test/asan/run.sh`, `test/asan/Dockerfile`, `test/asan/lsan.supp` |

The regions where a change most easily breaks memory safety, as `engine.md`
describes them: the state CAS (INIT, READY, STOPPING, EXITED), the root
read-write lock in `enqueue`, the destructor and the owner monitor, the handle
table drain on stop, and the handling of a stray 2xx.

## Steps

1. Keep every nta call on the stack thread. A NIF call allocates a handle and
   enqueues an operation with `su_msg_send`; results come back with
   `enif_send`. Only `start/2` and `stop/1` wait, as dirty IO NIFs.
2. To add an operation:
   - the op in the shim, with its handle and its `{op_ok, H}` or
     `{op_failed, H, Reason}` result;
   - the stub and its `-spec` in `chappe_sip_nif.erl`, and the event shape in
     its header comment;
   - the call site in `chappe_sip_engine`;
   - the same function in `chappe_sip_engine_fake`, so the pure-Erlang suites
     keep working.
3. Do not patch `c_src/sofia-sip`. If nta deviates from an RFC, work around it
   in the shim or in Erlang, and record a `deviation` row
   ([compliance.md](compliance.md)).
4. Update `engine.md` in the same change when you touch a lifecycle protocol.

## Tests to add or run

| Suite | Covers |
|---|---|
| `chappe_sip_engine_smoke_SUITE` | boot, SIP through the shim, a failed start, start/stop cycles, health round trips |
| `chappe_sip_engine_lifecycle_SUITE` | start, stop and restart raced against inbound traffic, many cycles |
| `chappe_sip_dialog_ops_SUITE` | in-dialog operations and an engine restart that tears live dialogs down |
| `chappe_sip_ops_SUITE` | the failure policy on missed health checks, the dialog ceiling, the message-size cap |
| `chappe_sip_handler_SUITE` | start/stop cycling and an OPTIONS burst |

```sh
rebar3 compile
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_engine_lifecycle_SUITE
make asan
```

`make asan` runs the smoke, dialog_ops and lifecycle suites under
AddressSanitizer with LeakSanitizer on, in a Linux container (macOS strips the
interceptors from a dlopen'd NIF). Pass other suites as the first argument of
`apps/chappe_sip/test/asan/run.sh`. `ASAN_DETECT_LEAKS=0` checks memory errors
only.

## How to know it works

- `make check` passes, with the NIF built (not `SKIP_ENGINE_BUILD`).
- `make asan` passes with no new suppression in `lsan.supp`. A suppression
  must never match a frame through `chappe_sip_engine_nif.c` or sofia.
- `make interop-conformance` and `make interop-sbc` pass: real traffic over
  UDP, TCP, TLS and WS.

## Notes

- A `.so` built against another `erl_nif.h` can crash the VM; the build stamp
  includes the ERTS version for that reason. After an OTP upgrade, rebuild.
- On a hang, the health check fails and `engine_failure_action` decides:
  `halt` (default) or `degrade`. Do not make a stop path block a scheduler.
- WebSocket traffic does not go through the NIF: it has its own transaction
  layer in `chappe_sip_ws_transport`. A behaviour change in nta may need its
  twin there.

## Related

- [labs.md](labs.md)
- [add-sip-feature.md](add-sip-feature.md)
- [add-tests.md](add-tests.md)
