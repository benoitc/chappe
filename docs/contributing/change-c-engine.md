# Change the C engine

The SIP engine is sofia-sip's nta transaction layer, linked into a NIF through
a plain-C shim, `apps/chappe_sip/c_src/chappe_sip_engine_nif.c`. A bug there
does not crash a process, it crashes the node. Use this page when you add an
operation or an event to the NIF, change its threading or lifecycle, or move
the vendored sofia-sip.

## Before you start

- [apps/chappe_sip/docs/design/engine.md](../../apps/chappe_sip/docs/design/engine.md),
  all of it: shape, threads, lifecycle protocols, health and hang policy,
  the risky regions, the safety rules and how to check them.
- [concepts.md: Engine and nta](../concepts.md#engine-and-nta).
- [decision 0001](../decisions/0001-sofia-nta-nif.md): why a NIF over
  sofia nta, and why that commits the shim to the safety rules.

## Where to look

| Piece | Where (under `apps/chappe_sip/`) |
|---|---|
| The shim | `c_src/chappe_sip_engine_nif.c` |
| The build | `c_src/build.sh` (stamp-gated: sofia rebuilds when its tree changes, the NIF when the shim, the script, `CC`, the sanitizer, `ENGINE_WERROR`, `ENGINE_EXTRA_CFLAGS` or ERTS change); `c_src/prepare_sofia.sh` makes the patched copy sofia is built from (build.sh and the fuzz build both use it), and `c_src/pin_autotools_mtimes.sh` keeps make from rerunning autotools on it |
| Vendored sofia-sip (LGPL-2.1, keep unmodified; fixes are patches) | `c_src/sofia-sip/`, `c_src/sofia-patches/`, `NOTICE` |
| NIF stubs and the event contract | `src/engine/chappe_sip_nif.erl` (`{chappe_sip_engine, Ref, Event}` and every event shape) |
| The process that owns the NIF | `src/engine/chappe_sip_engine.erl` |
| The pure-Erlang stand-in | `test/chappe_sip_engine_fake.erl`: the same call surface |
| ASan, UBSan, TSan, clang-tidy, fuzzing | `test/asan/run.sh`, `test/asan/in_container.sh`, `test/asan/Dockerfile`, `test/asan/*.supp`, `c_src/.clang-tidy`, `c_src/fuzz/` |

The regions where a change most easily breaks memory safety, as `engine.md`
describes them with the suites that cover each: the state CAS (INIT, READY,
STOPPING, EXITED), the root read-write lock in `enqueue`, the destructor and
the owner monitor, the handle table drain on stop, the handling of a stray
2xx, and the argument checks at the NIF boundary.

## Steps

1. Keep every nta call on the stack thread. A NIF call allocates a handle and
   enqueues an operation with `su_msg_send`; results come back with
   `enif_send`. Only `start/2` and `stop/1` wait, as dirty IO NIFs.
2. To add an operation:
   - the op in the shim, with its handle and its `{op_ok, H}` or
     `{op_failed, H, Reason}` result, its payload freed on every path;
   - its NIF checks every argument before the copy (`has_nul`, `bin_cstr`,
     a size cap) and returns `{error, enomem}` when a copy fails;
   - the stub and its `-spec` in `chappe_sip_nif.erl`, and the event shape in
     its header comment;
   - the call site in `chappe_sip_engine`;
   - the same function in `chappe_sip_engine_fake`, so the pure-Erlang suites
     keep working.
3. Do not edit `c_src/sofia-sip` in place. If nta deviates from an RFC, work
   around it in the shim or in Erlang, and record a `deviation` row
   ([compliance.md](compliance.md)). A bug inside sofia (a crash, undefined
   behaviour) is fixed with a patch in `c_src/sofia-patches`, with an
   upstream ticket and a repro; its README says how.
4. Keep the safety rules in `engine.md`: checked arithmetic (`chk_add`,
   `chk_mul`) for every computed size, `parse_long` for numbers in text,
   `NODISCARD` on a status helper, and no failure left silent.
5. Build with warnings as errors, as CI does. The build prints the hardening
   flags this compiler took:

   ```sh
   ENGINE_WERROR=1 rebar3 compile
   ```

6. Update `engine.md` in the same change when you touch a lifecycle protocol
   or a risky region, and name the tests that cover it.

## Tests to add or run

| Suite | Covers |
|---|---|
| `chappe_sip_engine_smoke_SUITE` | boot, SIP through the shim, a failed start, start/stop cycles, health round trips |
| `chappe_sip_engine_lifecycle_SUITE` | start, stop and restart raced against inbound traffic, many cycles |
| `chappe_sip_dialog_ops_SUITE` | in-dialog operations and an engine restart that tears live dialogs down |
| `chappe_sip_ops_SUITE` | the failure policy on missed health checks, the dialog ceiling, the message-size cap and its bounds |
| `chappe_sip_nif_boundary_SUITE` | what the shim refuses: NUL bytes, oversized fields, invalid start options, a request handed to `send_response/2`, and the `events_dropped` count |
| `chappe_sip_handler_SUITE` | start/stop cycling and an OPTIONS burst |

```sh
ENGINE_WERROR=1 rebar3 compile
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_nif_boundary_SUITE
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_engine_lifecycle_SUITE
make asan
```

`make tsan`, `make lint-c` and `make fuzz` are the other checks; `engine.md`
("How to check") says what each runs.

`make asan` runs the smoke, dialog_ops, lifecycle, NIF boundary and core
suites under AddressSanitizer and UndefinedBehaviorSanitizer with
LeakSanitizer on, in a Linux container (macOS strips the interceptors from a
dlopen'd NIF). Pass other suites as the first argument of
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
