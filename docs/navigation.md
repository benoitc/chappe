# Navigation

This page takes you from a concept to the code: the app and directory, the
module to start reading, the internal modules behind it, the tests and the
lab that cover it. Read it before you open the tree to change something, or
when a guide names a feature and you want its implementation. Test names
are short: `b2bua` means `chappe_sip_b2bua_SUITE`, `hdr` means
`chappe_sip_hdr_tests`, in the app's `test/` directory.

## Start here

- [Concept to code](#concept-to-code)
- [Public and internal modules per app](#public-and-internal-modules-per-app)
- [Where configuration and startup live](#where-configuration-and-startup-live)

## Concept to code

Directories under chappe_sip are relative to `apps/chappe_sip/`. Module
names with a leading `_` carry the app prefix (`_proxy_rules` is
`chappe_sip_proxy_rules`).

| If you care about | App, directory | Start at | Internal modules | Tests | Lab |
|---|---|---|---|---|---|
| Answering and placing calls | chappe_sip `src/api`, `src/dialog`, `src/uac` | `chappe_sip`, `chappe_sip_dialog`, `chappe_sip_uac` | `_dialog_fsm`, `_uac_fsm`, `_dialog_index`, `_session_timer` | `core`, `core_uac`, `uas`, `uac`, `indialog`, `dialog_ops`, `handler`, `session_timer`, `prack` | `make interop-conformance` |
| Inbound request pipeline | chappe_sip `src/engine`, `src/conn` | `chappe_sip_engine` (`handle_event/2`, `dispatch/4`), `chappe_sip_request_worker` | `_middleware`, `_guard`, `_request_sup` | `pipeline` (fake engine), `guard`, `ood` | none |
| B2BUA | chappe_sip `src/api/chappe_sip_b2b*` | `chappe_sip_b2b` | `_b2b_relay`, `_b2b_fork`, `_b2b_early`, `_b2b_media`, `_b2b_replace`, `_b2b_requests`, `_b2b_async`, `_b2b_hdr` | `b2bua`, `b2b_relay`, `forked_2xx`, `webrtc_gateway` | `make interop-sbc` |
| Proxy | chappe_sip `src/proxy` | `chappe_sip_proxy` | `_proxy_rules`, `_proxy_dialog`, `_route` | `proxy_conf`, `proxy_forking`, `proxy_record_route`, `proxy_media` | `make interop-conformance` |
| Registrar and location | chappe_sip `src/api/chappe_sip_registrar.erl`, `src/conn/chappe_sip_registry.erl` | `chappe_sip:registrar/1` | `_registry`, `_registry_keeper`, `_qualify` (`src/peers`), `_digest`, `_digest_nc` | `registrar`, `digest`, `digest_tests` | `make interop-conformance` |
| Registering to a carrier | chappe_sip `src/api/chappe_sip_regc.erl` | `chappe_sip:register_client/2` | `_regc_sup` | `regc` | none |
| WebSocket and WebRTC | chappe_sip `src/ws` | `chappe_sip_ws_listener` | `_ws_transport`, `_ws_conn`, `_ws_sup` | `websocket`, `ws_conf`, `webrtc_gateway` | JsSIP suite (`INTEROP=1`, `chappe_sip_interop_SUITE`) |
| Presence, MWI, subscriptions | chappe_sip `src/api` (packages), `src/dialog` (subscriber, refer) | `chappe_sip:event_package/2`, `chappe_sip:subscribe_to/3` | `_notifier`, `_subscriber`, `_notify_router`, `_presence`, `_mwi`, `_pidf` | `subscribe`, `subscriber`, `presence`, `refer` | none |
| Peers, OPTIONS, failover | chappe_sip `src/peers` | `chappe_sip:peer_add/2` | `_peer`, `_peers`, `_peer_sup` | `peers` | `make interop-sbc` |
| Media facade | chappe_sip `src/media` | `chappe_sip_media` | `_media_rtpengine`, `_media_mix`, `_media_mix_sdp`, `_media_sup` | `media` (fake `chappe_sip_test_rtpe`), `proxy_media` | `make interop` |
| Call records and capture | chappe_sip `src/api/chappe_sip_cdr.erl`, `src/engine/chappe_sip_hep.erl` | `chappe_sip_cdr:subscribe/1` | `_hep` | `cdr`, `hep`, `hep_tests` | none |
| Conference focus | chappe_sip `src/api` | `chappe_sip_focus` | `_confinfo` | `focus`, `confinfo_tests` | none |
| Metrics | chappe_sip `src/chappe_sip_metrics.erl` | `chappe_sip_metrics` | none | `metrics_tests` | none |
| The C engine | chappe_sip `c_src`, `src/engine/chappe_sip_nif.erl` | [engine.md](../apps/chappe_sip/docs/design/engine.md) | `c_src/chappe_sip_engine_nif.c` | `engine_lifecycle`, `engine_smoke`, `ops` | `make asan` |
| rtpengine control | `apps/chappe_rtpengine/src` | `chappe_rtpengine`, `chappe_rtpengine_session` | `_client`, `_pool`, `_ng`, `_bencode`, `_stream`, `_sdp`, `_dtmf` | `client`, `pool`, `session`, `dtmf`, `siprec`, `live`, `e2e` | `make interop` |
| Conference mixing | `apps/chappe_mix/src` | `chappe_mix` | `_conf`, `_room`, `_leg`, `_session`, `_dsp`, `_jbuf`, `_rtp`, `_rtcp`, `_g711` | `chappe_mix`, `rfc`, `live`, `ref` | `make interop-mix`, `make interop-ref` |
| FreeSWITCH control | `apps/chappe_esl/src` | `chappe_esl`, `chappe_esl_call` | `_conn`, `_exec`, `_inbound`, `_listener`, `_node`, `_nodes`, `_parser` | `conn`, `call`, `outbound`, `nodes`, `live` | `make interop-esl` |
| IVR, bridging, conferences | `apps/chappe_mrf/src` | `chappe_mrf`, `chappe_mrf_conf` | `_endpoint`, `_esl`, `_registry`, `_conf_native`, `_conf_fs`, `_lib` | `chappe_mrf` (fake `chappe_mrf_fake`), `live` | `make interop-mrf` |
| Compliance | `apps/*/docs/compliance` | `requirements.tsv` | `apps/chappe_sip/test/chappe_sip_compliance.erl`, `scripts/compliance.escript` | every suite (`%% req:` lines) | `make compliance` |
| Configuration | see [below](#where-configuration-and-startup-live) | `chappe_sip_config:get/1` | none | each app's suites | none |

Test fakes, one per remote end:

| App | Fake |
|---|---|
| chappe_sip | `chappe_sip_engine_fake` (the NIF), `chappe_sip_test_rtpe` (rtpengine) |
| chappe_rtpengine | `chappe_rtpengine_fake_server`, `chappe_rtpengine_fake_ws_handler` |
| chappe_esl | `chappe_esl_fake_server` |
| chappe_mrf | `chappe_mrf_fake` |

## Public and internal modules per app

Public modules are the ones your code calls: the facade, and the modules the
guides use. Everything else is internal and may change without notice.
No module is marked internal in its source yet.

| App | Public | Internal |
|---|---|---|
| chappe_sip | `chappe_sip` (facade), `chappe_sip_req`, `chappe_sip_res`, `chappe_sip_dialog`, `chappe_sip_uac`, `chappe_sip_b2b`, `chappe_sip_handler` (behaviour), `chappe_sip_media`, `chappe_sip_refer`, `chappe_sip_focus`, `chappe_sip_confinfo`, `chappe_sip_presence`, `chappe_sip_mwi`, `chappe_sip_publisher`, `chappe_sip_pidf`, `chappe_sip_cdr`, `chappe_sip_guard`, `chappe_sip_metrics`, `chappe_sip_digest`, and the message helpers `chappe_sip_hdr`, `chappe_sip_msg`, `chappe_sip_uri`, `chappe_sip_sdp` | the engine and NIF, the fsms (`_dialog_fsm`, `_uac_fsm`), every `_sup`, `_request_worker`, `_registry*`, `_route`, `_proxy_*`, `_ws_*`, `_b2b_*` helpers, `_media_rtpengine`, `_media_mix*`, `_notify_router`, `_subscriber`, `_peer`, `_qualify`, `_digest_nc`, `_hep`, `_config` |
| chappe_rtpengine | `chappe_rtpengine` (facade), `chappe_rtpengine_session`, `chappe_rtpengine_sdp`, `chappe_rtpengine_ng` (types and params), `chappe_rtpengine_dtmf` | `_client`, `_pool`, `_bencode`, `_stream`, `_resolve`, `_ws_handler`, every `_sup` |
| chappe_mix | `chappe_mix` (facade) | `_conf`, `_room`, `_leg`, `_session`, `_dsp`, `_jbuf`, `_rtp`, `_rtcp`, `_g711`, `_sup` |
| chappe_esl | `chappe_esl` (facade), `chappe_esl_call`, `chappe_esl_event`, `chappe_esl_handler` (behaviour) | `_conn`, `_exec`, `_inbound`, `_listener`, `_node`, `_nodes`, `_parser`, every `_sup` |
| chappe_mrf | `chappe_mrf` (facade), `chappe_mrf_conf` | `_endpoint`, `_esl`, `_registry`, `_conf_native`, `_conf_fs`, `_lib`, `_sup` |

## Where configuration and startup live

| App | Started by | Configured with | Defaults and reference |
|---|---|---|---|
| chappe_sip | the application, then `chappe_sip:start/1` brings up the stack, the WS listener, media, presence and the `registrations` | `chappe_sip:start/1` options and the `chappe_sip` app env | `chappe_sip_config:get/1` (defaults in `default/1`), `apps/chappe_sip/config/sys.config`, [configuration guide](../apps/chappe_sip/docs/guides/configuration.md), [configuration reference](../apps/chappe_sip/docs/configuration.md) |
| chappe_rtpengine | the application; started on demand by `chappe_sip_media_sup` when chappe_sip's `media` config names it | `chappe_rtpengine:add_node/2`, or chappe_sip's `media => #{rtpengine => ...}`; app env `dtmf_listen`, `dtmf_ip`, `dtmf_allowed_sources` | `chappe_rtpengine_dtmf`, [configuration reference](../apps/chappe_rtpengine/docs/configuration.md) |
| chappe_mix | the application; started on demand like chappe_rtpengine | `chappe_mix:start/1` options per room, or chappe_sip's `media => #{mix => ...}` | `chappe_mix` moduledoc, [configuration reference](../apps/chappe_mix/docs/configuration.md) |
| chappe_esl | the application; the node registry starts when the `nodes` app env is set | `chappe_esl:connect/1`, `chappe_esl:node_add/2`, `chappe_esl:start_listener/3`; app env `nodes`, `max_frame_bytes` | `chappe_esl_sup`, `chappe_esl_parser`, [configuration reference](../apps/chappe_esl/docs/configuration.md) |
| chappe_mrf | the application, after chappe_sip and chappe_esl; `chappe_mrf:start/1` after `chappe_sip:start/1` | `chappe_mrf:start/1` (`esl_port`, `esl_ip`, `esl_allow`); app env `esl_port` starts the listener with the app | `chappe_mrf_app`, [configuration reference](../apps/chappe_mrf/docs/configuration.md) |

The development shell (`rebar3 shell`) starts all five apps with
`apps/chappe_sip/config/sys.config` (root `rebar.config`, `shell`).

## Read this next

- [Architecture](architecture.md): the flows through these modules.
- [Contributor workflows](README.md#if-you-want-to-change-something): the
  files, tests and checks for a given change.
