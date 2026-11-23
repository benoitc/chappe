# Navigation

This page takes you from a concept to the code: the app and directory, the
module to start reading, the internal modules behind it, the tests and the
lab that cover it. Read it before you open the tree to change something, or
when a guide names a feature and you want its implementation. Test names
are short: `b2bua` means `chappe_sip_b2bua_SUITE`, `hdr_tests` means
`chappe_sip_hdr_tests`, in the app's `test/` directory. A word you do not
know is in the [glossary](glossary.md).

## Start here

- [Glossary](glossary.md): the terms the rows below use.
- [Concept to code](#concept-to-code)
- [Public and internal modules per app](#public-and-internal-modules-per-app)
- [Where configuration and startup live](#where-configuration-and-startup-live)

## Concept to code

Directories are relative to the app (`apps/<app>/`). Module names with a
leading `_` carry the prefix of the row's app (`_proxy_rules` is
`chappe_sip_proxy_rules`); a module of another app is written in full.
"Modules behind it" lists what the start module relies on, public or not;
which modules are public is in [the table below](#public-and-internal-modules-per-app).

| If you care about | App, directory | Start at | Modules behind it | Tests | Lab |
|---|---|---|---|---|---|
| Answering and placing calls | chappe_sip `src/api`, `src/dialog`, `src/uac` | `chappe_sip`, `chappe_sip_dialog`, `chappe_sip_uac` | `_dialog_fsm` with `_dialog_route`, `_dialog_offer`, `_dialog_out`, `_dialog_sub`, `_dialog_st`, `_dialog_owner`; `_uac_fsm`, `_uac_auth`, `_dialog_index`, `_session_timer` | `core`, `core_uac`, `uas`, `uac`, `indialog`, `dialog_ops`, `dialog_fsm`, `handler`, `session_timer`, `prack`, `uac_auth_tests`, `dialog_parts_tests` | `make interop-conformance` |
| Inbound request pipeline | chappe_sip `src/engine`, `src/conn` | `chappe_sip_engine`, `chappe_sip_request_worker` | `_dispatch`, `_middleware`, `_guard`, `_request_sup` | `pipeline` (fake engine), `guard`, `ood` | none |
| Engine dispatch | chappe_sip `src/engine` | `chappe_sip_engine` | `_dispatch`, `_uas_response` (both pure) | `dispatch_tests`, `uas_response_tests`, `pipeline` | `make interop-conformance` |
| B2BUA | chappe_sip `src/b2b` | `chappe_sip_b2b` | `_b2b_relay`, `_b2b_fork`, `_b2b_early`, `_b2b_media`, `_b2b_replace`, `_b2b_requests`, `_b2b_async`, `_b2b_hdr` | `b2bua`, `b2b_relay`, `forked_2xx`, `webrtc_gateway` | `make interop-sbc` |
| B2BUA transfers and joins | chappe_sip `src/b2b` | `chappe_sip_b2b_transfer`, `chappe_sip_b2b_join` | `_b2b_replace`, `_b2b_async` | `b2b_transfer`, `b2b_async`, `replaces` | `make interop-conformance` |
| Call correlation | chappe_sip `src/core` | `chappe_sip:calls/1`, `chappe_sip_call` | the `chappe_sip` pg scope (`chappe_sip_call:scope/0`), a child of `chappe_sip_sup` | `call` | none |
| Proxy | chappe_sip `src/proxy`, `src/sip` | `chappe_sip_proxy` | `_proxy_rules`, `_proxy_dialog`, `_proxy_accepted`, `_proxy_redirect`, `_route`, `_flow` | `proxy_conf`, `proxy_forking`, `proxy_record_route`, `proxy_media` | `make interop-conformance` |
| Registrar and location | chappe_sip `src/api/chappe_sip_registrar.erl`, `src/conn` | `chappe_sip:registrar/1` | `_registry`, `_registry_keeper`, `_location`, `_location_ets`, `_location_cluster`, `_flow`, `_qualify` (`src/peers`), `_digest`, `_digest_nc` | `registrar`, `registrar_cluster`, `digest`, `digest_tests` | `make interop-conformance`, `make demo-cluster` |
| Location store | chappe_sip `src/conn` | `chappe_sip_location` (the backend calls), [registrar design](../apps/chappe_sip/docs/design/registrar.md) | `_location_ets`, `_location_cluster`, `_registry_store`, `_registry_contact`, `_registry_sweep` | `registrar`, `registrar_cluster`, `registry_lag_tests` (store `chappe_sip_location_lagging`) | `make demo-cluster` |
| Edge routes and flow tokens | chappe_sip `src/sip` | `chappe_sip_flow`, [registrar design](../apps/chappe_sip/docs/design/registrar.md#flows-and-edge-routes) | `_route` (Record-Route), `_proxy_dialog` (430 Flow Failed) | `flow_tests`, `route_tests`, `registrar_cluster`, `proxy_record_route` | `make demo-cluster` |
| Registering to a carrier | chappe_sip `src/api/chappe_sip_regc.erl` | `chappe_sip:register_client/2` | `_regc_sup` | `regc` | none |
| WebSocket and WebRTC | chappe_sip `src/ws` | `chappe_sip_ws_listener` | `_ws_transport` with `_ws_txn`, `_ws_ctxn`, `_ws_msg`; `_ws_conn`, `_ws_sup` | `websocket`, `ws_conf`, `ws_msg_tests`, `webrtc_gateway` | JsSIP suite (`INTEROP=1`, `chappe_sip_interop_SUITE`) |
| Presence, MWI, subscriptions | chappe_sip `src/events` (packages), `src/dialog` (subscriber, refer) | `chappe_sip:event_package/2`, `chappe_sip:subscribe_to/3` | `_notifier`, `_subscriber`, `_subscription`, `_notify_router`, `_presence`, `_mwi`, `_pidf` | `subscribe`, `subscriber`, `presence`, `refer` | none |
| Peers, OPTIONS, failover | chappe_sip `src/peers` | `chappe_sip:peer_add/2` | `_peer`, `_peers`, `_peer_sup` | `peers`, `peers_cluster` | `make interop-sbc` |
| Media facade | chappe_sip `src/media` | `chappe_sip_media` | `_media_rtpengine`, `_media_mix`, `_media_mix_sdp`, `_media_sup` | `media` (fake `chappe_sip_test_rtpe`), `proxy_media` | `make interop` |
| SIPREC client | chappe_sip `src/siprec` | `chappe_sip_siprec`, [SIPREC design](../apps/chappe_sip/docs/design/siprec.md) | `_siprec_meta`, `_siprec_body`, `_siprec_tap`, `_siprec_peer`, `_siprec_sup` | `siprec`, `siprec_meta_tests` | `make interop` (`siprec_live`) |
| SIPREC server | chappe_sip `src/siprec`, chappe_audio `src` | `chappe_sip_siprec_srs`, [SIPREC design](../apps/chappe_sip/docs/design/siprec.md) | `chappe_sip_siprec_srs_stream` (one per recorded stream), `chappe_audio_rtp` with `chappe_audio_rtp_rtcp` and `chappe_audio_rtcp`, `chappe_audio_srtp`, `chappe_audio_store` | `siprec` (store `chappe_sip_test_store`), chappe_audio's `rtp`, `rtp_rtcp_tests`, `rtcp_tests` | `make interop` (`siprec_live`) |
| SRTP and SDES | chappe_audio `src`, chappe_sip `src/sip` | [decision 0009](decisions/0009-srtp-in-erlang.md) | `chappe_audio_srtp`, `chappe_sip_sdes` | chappe_audio's `srtp_tests` (sender `chappe_audio_test_srtp`), chappe_sip's `sdes_tests` | none |
| Call records and capture | chappe_sip `src/core/chappe_sip_cdr.erl`, `src/engine/chappe_sip_hep.erl` | `chappe_sip_cdr:subscribe/1` | `_hep` | `cdr`, `hep`, `hep_tests` | none |
| Conference focus | chappe_sip `src/events` | `chappe_sip_focus` | `_confinfo` | `focus`, `confinfo_tests` | none |
| Metrics | chappe_sip `src/chappe_sip_metrics.erl` | `chappe_sip_metrics` | none | `metrics_tests` | none |
| The C engine | chappe_sip `c_src`, `src/engine/chappe_sip_nif.erl` | [engine.md](../apps/chappe_sip/docs/design/engine.md) | `c_src/nif/` (one file per area, see engine.md "Where the code lives"); on the Erlang side `_engine_opts`, `_engine_backend`, `_engine_events`, `_engine_handles`, `_engine_conns`, `_nif_reload` (replacing the library) | `engine_lifecycle`, `engine_smoke`, `engine_opts`, `ops`, `nif_boundary`, `nif_upgrade`, `nif_fuzz` | `make asan`, `make tsan` |
| Ownership in a cluster | chappe_cluster `src` | `chappe_cluster` (`claim/2`, `owner/1`, `fence/1`), [cluster design](../apps/chappe_cluster/docs/design/overview.md) | `_machine`, `_ra`, `_node`, `_lapse`, `_tab`, `_watch`, `_config` | `chappe_cluster`, `peer`, `machine_tests` (PropEr), the lab code in `test/lab` (`lab_checker_tests`, `lab_schedule_tests`) | `make interop-cluster` |
| Singletons | chappe_cluster `src` | `chappe_cluster:singleton/2` | `_singleton`, `_singleton_sup` | `chappe_cluster`, `peer`, chappe_sip's `peers_cluster` | `make interop-cluster` |
| Cross-region seam | chappe_cluster `src` | `chappe_cluster_directory` (behaviour) | `_directory_local` | `chappe_cluster` | none |
| rtpengine control | `apps/chappe_rtpengine/src` | `chappe_rtpengine`, `chappe_rtpengine_session`, `chappe_rtpengine_cmd` | `_client`, `_pool`, `_ng`, `_bencode`, `_stream`, `_sdp`, `_offer`, `_dtmf` | `client`, `pool`, `session`, `dtmf`, `siprec`, `offer_tests`, `live`, `e2e` | `make interop` |
| Conference mixing | `apps/chappe_mix/src` | `chappe_mix` | `_conf`, `_room`, `_leg`, `_session`, `_dsp`, `_jbuf`, `_rtp`, `_rtcp`, `_g711` | `chappe_mix`, `rfc`, `live`, `ref` | `make interop-mix`, `make interop-ref` |
| Media taps | chappe_mix `src` | `chappe_mix:tap/3` | `_tap`, `_conf` | `tap` | none |
| Audio forks and streams | chappe_audio `src` | `chappe_audio` | `_listener`, `_conn`, `_stream`, `_ws`, `_pcm`, `_registry`, `_pg`, `_http` | `chappe_audio` (client `chappe_audio_test_ws`), `pg`, `pcm_tests`, `http_tests` | `make interop-esl` (`chappe_audio_live_SUITE`) |
| Recording store | chappe_audio `src`, chappe_mrf `src` | `chappe_audio_store` (behaviour) | `_store_srv`, `_store_file`, `_writer`, `_adopt`, `_wav`, `chappe_mrf_store` | `store`, `wav_tests`, chappe_mrf's `store_tests` | `make interop-esl` (`chappe_audio_live_SUITE`) |
| FreeSWITCH control | `apps/chappe_esl/src` | `chappe_esl`, `chappe_esl_call` | `_conn`, `_verbs`, `_exec`, `_inbound`, `_listener`, `_cidr`, `_node`, `_nodes`, `_parser` | `conn`, `call`, `outbound`, `nodes`, `live` | `make interop-esl` |
| ESL verbs | chappe_esl `src` | `chappe_esl_call` | `_verbs`, `_exec` | `call` | `make interop-esl` |
| ESL listener screening | chappe_esl `src` | `chappe_esl:start_listener/4` (`allow`) | `_listener`, `_cidr`, `_outbound_sup` | `outbound`, `cidr_tests` | `make interop-esl` |
| IVR, bridging, conferences | `apps/chappe_mrf/src` | `chappe_mrf`, `chappe_mrf_conf` | `_endpoint`, `_esl`, `_registry`, `_conf_backend`, `_conf_native`, `_conf_fs`, `_conf_fs_join`, `_conf_focus`, `_conf_refer`, `_conf_transfer`, `_store`, `_lib` | `chappe_mrf` (fake `chappe_mrf_fake`), `conf_backend`, `store_tests`, `live` | `make interop-mrf` |
| Conference backends | chappe_mrf `src` | `chappe_mrf_conf_backend` (behaviour) | `_conf_native`, `_conf_fs`, `_conf_fs_join`, `_conf_focus`, `_conf_refer` | `chappe_mrf`, `conf_backend` (backend `chappe_mrf_conf_fake_backend`) | `make interop-mrf` |
| Rooms in a cluster | chappe_mrf `src` | `chappe_mrf_conf`, [rooms in a cluster](../apps/chappe_mrf/docs/design/overview.md#rooms-in-a-cluster) | `_conf_cluster`, `_conf_move`, `_conf_transfer`, `chappe_mix_move` | `cluster` (peers `chappe_mrf_test_cluster`) | `make demo-cluster` |
| Compliance | `apps/*/docs/compliance` | `requirements.tsv` | `scripts/compliance/chappe_sip_compliance.erl`, `scripts/compliance.escript` | every suite (`%% req:` lines), the umbrella's `test/chappe_sip_compliance_tests.erl` | `make compliance` |
| Configuration | see [below](#where-configuration-and-startup-live) | `chappe_sip_config:get/1` | none | each app's suites | none |

Test fakes and helpers, one per remote end or per kind of setup:

| App | Fakes | Helpers |
|---|---|---|
| chappe_sip | `chappe_sip_engine_fake` (the NIF), `chappe_sip_test_rtpe` (rtpengine), `chappe_sip_test_store` (a recording store), `chappe_sip_location_lagging` (a location store whose replica lags) | `chappe_sip_test_ua`, `chappe_sip_raw_peer` (scripted SIP peers), `chappe_sip_test_port` (ports), `chappe_sip_ws_test_client`, `chappe_sip_test_dist` (distribution on), `chappe_sip_test_cluster` (`peer` nodes, chappe_cluster on them) |
| chappe_rtpengine | `chappe_rtpengine_fake_server`, `chappe_rtpengine_fake_ws_handler` | none |
| chappe_esl | `chappe_esl_fake_server` | none |
| chappe_mix | none | `chappe_mix_test_peer` (raw RTP), `chappe_mix_test_tone`, `chappe_mix_probe`, `chappe_mix_test_dist` |
| chappe_audio | none | `chappe_audio_test_ws` (a fork module's client), `chappe_audio_test_srtp` (an SRTP sender), `chappe_audio_test_dist` |
| chappe_cluster | `chappe_cluster_lab_fake` (a cluster with a chosen bug, lab only) | `chappe_cluster_test_dist` (`peer` nodes running chappe_cluster) |
| chappe_mrf | `chappe_mrf_fake` (FreeSWITCH, rtpengine, a caller), `chappe_mrf_conf_fake_backend` (a conference backend) | `chappe_mrf_test_cluster` (`peer` nodes, chappe_cluster on them) |

## Public and internal modules per app

Public modules are the ones your code calls: the facade, and the modules the
guides use. Everything else is internal and may change without notice. The
record is each app's ex_doc config (`groups_for_modules` in
`apps/<app>/rebar.config`): a module in its "Internal" group is internal,
every other group is public.

| App | Public | Internal |
|---|---|---|
| chappe_sip | `chappe_sip` (facade), `chappe_sip_handler`, `chappe_sip_middleware`, `chappe_sip_config`; calls: `chappe_sip_req`, `chappe_sip_res`, `chappe_sip_dialog`, `chappe_sip_uac`, `chappe_sip_call`, `chappe_sip_subscription`; B2BUA and proxy: `chappe_sip_b2b`, `chappe_sip_b2b_join`, `chappe_sip_b2b_transfer`, `chappe_sip_proxy`, `chappe_sip_proxy_accepted`, `chappe_sip_proxy_redirect`, `chappe_sip_peers`; registration: `chappe_sip_registry`, `chappe_sip_regc`, `chappe_sip_location`, `chappe_sip_location_ets`, `chappe_sip_location_cluster`, `chappe_sip_registry_store`, `chappe_sip_registry_contact`, `chappe_sip_registry_sweep`, `chappe_sip_flow`; events: `chappe_sip_refer`, `chappe_sip_subscriber`, `chappe_sip_presence`, `chappe_sip_pidf`, `chappe_sip_mwi`, `chappe_sip_focus`, `chappe_sip_confinfo`; `chappe_sip_media`; SIPREC: `chappe_sip_siprec`, `chappe_sip_siprec_srs`, `chappe_sip_siprec_srs_stream`, `chappe_sip_siprec_meta`, `chappe_sip_siprec_body`, `chappe_sip_siprec_tap`, `chappe_sip_siprec_peer`, `chappe_sip_sdes`; operations: `chappe_sip_guard`, `chappe_sip_cdr`, `chappe_sip_metrics`, `chappe_sip_metrics_http`, `chappe_sip_hlc`; messages: `chappe_sip_msg`, `chappe_sip_hdr`, `chappe_sip_uri`, `chappe_sip_sdp`, `chappe_sip_sipfrag`, `chappe_sip_digest`, `chappe_sip_multipart` | the engine and NIF (`_engine`, `_engine_opts`, `_engine_backend`, `_engine_events`, `_engine_handles`, `_engine_conns`, `_nif`, `_nif_reload`, `_dispatch`, `_uas_response`, `_binds`, `_bind_uri`, `_net`), the fsms and their parts (`_dialog_fsm`, `_dialog_route`, `_dialog_offer`, `_dialog_out`, `_dialog_sub`, `_dialog_st`, `_dialog_owner`, `_uac_fsm`, `_uac_auth`, `_uac_early`, `_uac_req`, `_uac_retry`, `_uac_sdp`), every `_sup`, `_request_worker`, `_registrar`, `_registry_keeper`, `_route`, `_proxy_rules`, `_proxy_dialog`, `_ws*`, the `_b2b_*` helpers other than join and transfer, `_media_rtpengine`, `_media_mix*`, `_notifier`, `_notify_router`, `_publisher`, `_esc`, `_refer_registry`, `_refer_sub`, `_peer`, `_qualify`, `_digest_nc`, `_dialog_index`, `_session_timer`, `_hdr_io`, `_hep`, `_lib`, `_app` |
| chappe_rtpengine | `chappe_rtpengine` (facade), `chappe_rtpengine_session`, `chappe_rtpengine_cmd`, `chappe_rtpengine_dtmf`, `chappe_rtpengine_sdp`, `chappe_rtpengine_ng`, `chappe_rtpengine_pool` | `_client`, `_resolve`, `_ws_handler`, `_bencode`, `_stream`, `_offer`, `_app`, every `_sup` |
| chappe_mix | `chappe_mix` (facade) | `_conf`, `_room`, `_leg`, `_session`, `_dsp`, `_jbuf`, `_rtp`, `_rtcp`, `_g711`, `_move`, `_tap`, `_app`, `_sup` |
| chappe_esl | `chappe_esl` (facade); connection: `chappe_esl_conn`, `chappe_esl_inbound`; outbound: `chappe_esl_outbound_sup`, `chappe_esl_listener`, `chappe_esl_handler` (behaviour), `chappe_esl_cidr`; call control: `chappe_esl_call`, `chappe_esl_verbs`, `chappe_esl_exec`; nodes: `chappe_esl_nodes`, `chappe_esl_node`; protocol: `chappe_esl_parser`, `chappe_esl_event` | `_app`, `_sup` |
| chappe_audio | `chappe_audio` (facade), `chappe_audio_store` (behaviour), `chappe_audio_store_file`; forks and streams: `chappe_audio_listener`, `chappe_audio_conn`, `chappe_audio_stream`, `chappe_audio_ws`, `chappe_audio_registry`, `chappe_audio_pg`; recording: `chappe_audio_writer`, `chappe_audio_store_srv`, `chappe_audio_adopt`, `chappe_audio_wav`, `chappe_audio_pcm`; RTP intake: `chappe_audio_rtp`, `chappe_audio_rtp_rtcp`, `chappe_audio_srtp`, `chappe_audio_rtcp` | `_app`, `_sup`, `_lib`, `_http` |
| chappe_cluster | `chappe_cluster` (facade), `chappe_cluster_directory` (behaviour), `chappe_cluster_directory_local`; ownership: `chappe_cluster_node`, `chappe_cluster_lapse`, `chappe_cluster_watch`, `chappe_cluster_tab`; consensus: `chappe_cluster_machine`, `chappe_cluster_ra`; `chappe_cluster_singleton`, `chappe_cluster_singleton_sup` | `_app`, `_sup`, `_config` |
| chappe_mrf | `chappe_mrf` (facade), `chappe_mrf_conf`; conferences: `chappe_mrf_conf_backend` (behaviour), `chappe_mrf_conf_native`, `chappe_mrf_conf_fs`, `chappe_mrf_conf_fs_join`, `chappe_mrf_conf_refer`, `chappe_mrf_conf_transfer`, `chappe_mrf_conf_focus`; cluster rooms: `chappe_mrf_conf_cluster`, `chappe_mrf_conf_move`; `chappe_mrf_store` | `_endpoint`, `_esl`, `_registry`, `_lib`, `_app`, `_sup` |

## Where configuration and startup live

| App | Started by | Configured with | Defaults and reference |
|---|---|---|---|
| chappe_sip | the application, after chappe_audio when it is on the node; with `cluster => chappe_cluster` it starts chappe_cluster first ([0014](decisions/0014-optional-siblings.md)); then `chappe_sip:start/1` brings up the stack, the WS listener, media, presence and the `registrations` | `chappe_sip:start/1` options and the `chappe_sip` app env | `chappe_sip_config:get/1` (defaults in `default/1`), `apps/chappe_sip/config/sys.config`, [configuration guide](../apps/chappe_sip/docs/guides/configuration.md), [configuration reference](../apps/chappe_sip/docs/configuration.md) |
| chappe_rtpengine | the application; started on demand by `chappe_sip_media_sup` when chappe_sip's `media` config names it | `chappe_rtpengine:add_node/2`, or chappe_sip's `media => #{rtpengine => ...}`; app env `dtmf_listen`, `dtmf_ip`, `dtmf_allowed_sources` | `chappe_rtpengine_dtmf`, [configuration reference](../apps/chappe_rtpengine/docs/configuration.md) |
| chappe_mix | the application; started on demand like chappe_rtpengine | `chappe_mix:start/1` options per room, or chappe_sip's `media => #{mix => ...}` | `chappe_mix` moduledoc, [configuration reference](../apps/chappe_mix/docs/configuration.md) |
| chappe_esl | the application; the node registry starts when the `nodes` app env is set | `chappe_esl:connect/1`, `chappe_esl:node_add/2`, `chappe_esl:start_listener/3`; app env `nodes`, `max_frame_bytes` | `chappe_esl_sup`, `chappe_esl_parser`, [configuration reference](../apps/chappe_esl/docs/configuration.md) |
| chappe_audio | the application; `chappe_audio_sup` starts the RTP receivers' supervisor first, then its pg scope, the registry and the store; the default listener starts with the app when the `listener` env is set | app env `listener`, `storage` | `chappe_audio_sup`, [configuration reference](../apps/chappe_audio/docs/configuration.md) |
| chappe_cluster | the app that uses it, at boot, before that app's supervisor, when its `cluster` setting is `chappe_cluster` ([0014](decisions/0014-optional-siblings.md)); a release lists it as `{chappe_cluster, load}` | app env `region`, `voters`, `data_dir`, `lease_ms`, `renew_ms`, `max_leases`, `max_keys`, `max_value_bytes` | `chappe_cluster_config`, [cluster guide](../apps/chappe_cluster/docs/guides/cluster.md) |
| chappe_mrf | the application, after chappe_sip, chappe_esl and chappe_audio; with `cluster => chappe_cluster` it starts chappe_cluster first; `chappe_mrf:start/1` after `chappe_sip:start/1` | `chappe_mrf:start/1` (`esl_port`, `esl_ip`, `esl_allow`); app env `esl_port` starts the listener with the app, `cluster`, `drain_ms` | `chappe_mrf_app`, [configuration reference](../apps/chappe_mrf/docs/configuration.md) |

The development shell (`rebar3 shell`) starts all seven apps with
`apps/chappe_sip/config/sys.config` (root `rebar.config`, `shell`).

## Read this next

- [Glossary](glossary.md): every term these tables use.
- [Architecture](architecture.md): the flows through these modules.
- [Contributor workflows](README.md#if-you-want-to-change-something): the
  files, tests and checks for a given change.
