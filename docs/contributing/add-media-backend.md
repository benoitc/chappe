# Add a media backend or capability

`chappe_sip_media` is the one media API the SIP code calls. A caller asks for a
capability (`anchor`, `play`, `conference`, ...) and the facade routes it to a
backend adapter: `rtpengine` (through chappe_rtpengine) or `mix` (through
chappe_mix). Use this page when you add a capability to an existing backend,
or a new backend such as another media server.

## Before you start

- [concepts.md: Anchor and direct media](../concepts.md#anchor-and-direct-media)
  and [NG protocol](../concepts.md#ng-protocol).
- [apps/chappe_sip/docs/design/media.md](../../apps/chappe_sip/docs/design/media.md):
  the boundary and why media stays out of the SIP processes.
- The leaf rule in [AGENTS.md](../../AGENTS.md): chappe_rtpengine and
  chappe_mix take no SIP dependency. SIP-aware glue lives in chappe_sip.

## Where to look

| Piece | Where (under `apps/chappe_sip/src/media/`) |
|---|---|
| The facade, capability routing | `chappe_sip_media.erl`: `default_backend/1`, `backend_for/1`, `configure/1`, one clause per backend in each API function |
| The rtpengine adapter | `chappe_sip_media_rtpengine.erl` (plain functions over `chappe_rtpengine_session`) |
| The mixer adapter | `chappe_sip_media_mix.erl` (a registered gen_server that keeps the rooms), `chappe_sip_media_mix_sdp.erl` |
| Starting a backend's app on demand | `chappe_sip_media_sup:ensure_app/1` |
| The SIP-free libraries | `apps/chappe_rtpengine/src/chappe_rtpengine.erl`, `apps/chappe_mix/src/chappe_mix.erl` |

There is no adapter behaviour. The contract is the set of facade functions a
backend has a clause for. Today:

| Function | rtpengine | mix |
|---|---|---|
| `session/2` (start) | `start/2` | `start/2` |
| `offer/2,3`, `answer/2,3`, `publish/2,3` | yes | no |
| `play/2`, `record/2`, `stop_record/1`, `dtmf/2` | yes | no |
| `subscribe/2`, `subscribe_answer/2`, `unsubscribe/2`, `duck/2`, `unduck/2` | yes | no |
| `conference/2,3`, `leave/1`, `mute/1`, `deaf/1`, `relate/3`, `set_remote/2` | no | yes |
| `stop/1`, `info/1` | yes | yes |
| `set_owner/2` | yes | no |

A function a backend lacks returns `{error, {unsupported, Op}}`.

## Steps

To add a capability to an existing backend:

1. Add the atom to the `capability()` type and a `default_backend/1` clause in
   `chappe_sip_media`.
2. Add the facade function, with a clause for the backend that serves it and a
   catch-all returning `{error, {unsupported, Op}}`.
3. Implement it in the adapter. If it needs a new NG command or mixer call,
   add it to the leaf app first, with its own tests there.

To add a backend:

1. Add it to the `backend()` type, to `app/1`, to `backend_configure/2` and to
   `backend_start/3` in `chappe_sip_media`.
2. Write `chappe_sip_media_<name>.erl` with `start/2` and the functions of the
   capabilities it serves. Tie each session to the process that called
   `session/2`: when it exits, the backend session must go.
3. If the backend is a new library, it is a leaf app: see
   [add-app.md](add-app.md). Add it to `plt_extra_apps` in
   `apps/chappe_sip/rebar.config`.
4. Document the config key in the media guide and in
   [configuration.md](../../apps/chappe_sip/docs/guides/configuration.md).

## Tests to add or run

| Suite | Covers |
|---|---|
| `chappe_sip_media_SUITE` | the facade: an in-suite NG server for rtpengine, real chappe_mix rooms on loopback; group `rtpengine_live` with a real daemon |
| `chappe_sip_b2b_relay_SUITE` | anchoring in the B2BUA, against `chappe_sip_test_rtpe` |
| `chappe_sip_proxy_media_SUITE` | anchoring in the proxy |
| the leaf app's suites | `chappe_rtpengine_*_SUITE` (with `chappe_rtpengine_fake_server`), `chappe_mix_SUITE` |

Run the live group against a real rtpengine:

```sh
make interop
make interop-mix
```

## How to know it works

- `make check` passes.
- `make interop`, `make interop-mix` and, for anything chappe_mrf uses,
  `make interop-mrf` pass.
- `make interop-sbc` passes if the anchor path changed.

## Notes

- `configure/1` with an empty map starts nothing: the media libraries stay
  dormant unless `media` is configured.
- `configure(#{freeswitch := _})` returns `{error, {unsupported_backend,
  freeswitch}}`: FreeSWITCH is reached through chappe_esl and chappe_mrf, not
  through this facade.
- The `capabilities` key of the media config (`#{Capability => Backend}`)
  overrides `default_backend/1`, and a `backend` option on `session/2`
  overrides both. The backend must have clauses for the functions you call.

## Related

- [change-b2bua.md](change-b2bua.md)
- [add-mrf-conference-backend.md](add-mrf-conference-backend.md)
- [add-app.md](add-app.md)
