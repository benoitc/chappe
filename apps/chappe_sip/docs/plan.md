# chappe_sip plan

Port of drachtio (server + srf) to Erlang/OTP 29 in one application.
Architecture: sofia-sip nta wrapped by a thin plain-C NIF shim; all
transaction-user logic (dialogs, UAC, B2BUA, proxy, digest, middleware) in
Erlang. Full design: `docs/design/engine.md` and the approved plan this
file tracks.

Pins:
- sofia-sip: freeswitch/sofia-sip @ 7333682a297f28130ff46d5ef0f9e2f72adca0e8 (v1.13.17-55)
- Erlang/OTP: 29 only

One commit closes each milestone.

## Milestones

- [x] M0 Scaffold + hello SIP: repo, build.sh, skeleton shim
      (start/stop/respond/health), OPTIONS answered from Erlang,
      start-failure barrier, start/stop cycling, health round-trip.
      Closed 2026-07-14: chappe_sip_engine_smoke_SUITE 5/5 green on macOS arm64.
- [x] M1 SIP message model: chappe_sip_msg, chappe_sip_hdr, chappe_sip_uri,
      chappe_sip_req/chappe_sip_res, chappe_sip_digest. eunit corpus incl. RFC 4475 samples.
      Closed 2026-07-14: 29 eunit tests green, byte-faithful round-trips,
      RFC 2617 digest vector. Known limit: escaped quotes inside display
      names are not unescaped (drachtio-sip parity).
- [x] M2 Engine layer + inbound pipeline: dispatch, route table, request
      workers, middleware, chappe_sip_engine_fake, limits (worker cap 503,
      handler deadline 500), live OPTIONS/MESSAGE.
      Closed 2026-07-14: chappe_sip_pipeline_SUITE 10/10 (fake + live over gen_udp).
      Deferred: chappe_sip_registry arrives with dialogs (M3); engine-local
      worker map suffices until cross-process lookup is needed. sipp
      arrives with M3 INVITE scenarios. Oversized-inbound live test
      moves to the M7 overload batch.
- [x] M3 UAS INVITE dialogs: dialog fsm as source of truth, ACK/BYE,
      auto-answer rule, op_ok/op_failed confirmation, in-dialog routing
      by leg, app-initiated destroy (BYE). Closed 2026-07-14:
      chappe_sip_uas_SUITE 5/5 (live INVITE/200/ACK/BYE both directions + fake
      auto-answer/claimed/owner-exit). Review findings folded in: nta
      constructor mapping (mcreate + leg_tcreate), op result events,
      su_init SIGPIPE preservation. Deferred to M4: forking (tagged 1xx
      early dialogs, multiple 2xx), CANCEL/487 live test needs a UAC that
      cancels; chappe_sip_registry still lives inside chappe_sip_engine state.
- [x] M4 UAC: chappe_sip_uac start/await/await_response/cancel, provisionals,
      digest 401/407 retry, redirects, 3PCC no_ack, forked-2xx cleanup
      (auto ACK+BYE), out-of-dialog request. C shim gains send (stateless
      ACK), cancel, txn_done; outgoing txn kept until the fsm finishes.
      Closed 2026-07-14: chappe_sip_uac_SUITE 5/5 (180/200/ACK/BYE, 486,
      cancel-while-ringing, 407-digest, OPTIONS await_response). 25 CT +
      29 eunit green. Deferred: live forking test (needs a forking proxy;
      the dual-2xx cleanup path is coded, not yet exercised live).
- [x] M5 B2BUA. chappe_sip_b2b bridges a UAS leg and a UAC leg: header proxy
      rules (list | all | {all, exclude}), CANCEL relay A->B, pass_failure,
      pass_provisional (tagged with a pre-chosen A-leg tag), relay loop
      cross-destroying legs. Dialogs expose remote_sdp; create_uas takes a
      local_tag. Closed 2026-07-14: chappe_sip_b2bua_SUITE 3/3 (caller->app b2bua
      ->callee full call+BYE both ways, callee 486 passthrough, caller
      CANCEL while ringing). 28 CT + 29 eunit green. Note: proxy_response
      _headers deferred (dialog does not retain the raw 2xx yet).
- [x] M6 Proxy engine: chappe_sip_proxy serial + parallel forking, provisional
      relay, first-2xx-wins with CANCEL of pending branches, best-final on
      all-fail, Max-Forwards decrement, Record-Route insertion. C shim gains
      relay (nta_incoming_mreply) to forward a downstream response upstream;
      chappe_sip_msg gains drop_first/prepend/decr_max_forwards. Closed
      2026-07-14: chappe_sip_proxy_forking_SUITE 3/3 (single 200, serial 486->200 failover,
      parallel first-wins + loser CANCEL). 31 CT + 29 eunit green.
      Documented limits: a second forked 2xx is logged not forwarded (needs
      a stateless response transport this sofia lacks); record-routed
      in-dialog forwarding (2xx ACK / routed BYE through the proxy) is not
      yet wired to a persistent entry point - deferred to M7.
- [x] M7 In-dialog ops + resilience: serialized re-INVITE (modify with
      sdp | hold | unhold, in_transaction state postpones competing ops),
      chappe_sip_dialog:request for INFO/REFER/UPDATE, controlled engine restart
      (chappe_sip_engine:restart_engine tears down dialogs with engine_restart,
      keeps routes, restarts NIF). Closed 2026-07-14: chappe_sip_dialog_ops_SUITE 3/3
      (re-INVITE hold + ACK, in-dialog INFO, restart teardown + recovery).
      34 CT + 29 eunit green. Overload (worker cap 503 / deadline 500) is
      covered by chappe_sip_pipeline_SUITE. Deferred to M8: proxy record-route
      in-dialog forwarding and second-forked-2xx.
- [x] M8 Hardening + release + docs: chappe_sip_handler behaviour, relx prod
      release (boots, NIF loads from priv_dir, health ok), README +
      docs/features.md + docs/design/overview.md + engine.md sanitizer
      procedure, examples/chappe_sip_demo.erl (echo/b2bua/registrar), ASan/UBSan
      build option (ENGINE_SANITIZE) + valgrind notes, load test (60
      concurrent OPTIONS + 6 restart cycles). Closed 2026-07-14:
      chappe_sip_handler_SUITE 3/3, 37 CT + 29 eunit green. Deferred proxy items
      (record-route in-dialog forwarding, second forked 2xx) documented in
      docs/features.md as the roadmap.

- [x] M9 Proxy record-route in-dialog forwarding: a new chappe_sip_route module
      builds the self-identifying Record-Route (`;lr;espx`), recognises it
      as the top Route, and pops it to the next hop (loose routing). Routed
      in-dialog requests (BYE, re-INVITE, INFO) are forwarded by a transit
      worker reusing spawn_worker (chappe_sip_proxy:forward_indialog), the 2xx ACK
      by a stateless send (chappe_sip_proxy:forward_indialog_ack). The 2xx ACK
      reaches the default leg because OP_RELAY destroys the incoming
      transaction on the final, so NTATAG_UA does not absorb it; no C change.
      Closed 2026-07-14: chappe_sip_proxy_record_route_SUITE 3/3 (caller ACK+BYE routed, callee
      BYE routed, re-INVITE routed). 40 CT + 29 eunit green. Limits: single
      Record-Route; multi-hop pre-existing Route sets forwarded by the next
      Route or Request-URI; no strict-router recovery; a CANCEL for a
      proxied in-dialog re-INVITE is not correlated to the transit worker.

- [x] M10 Registrar location store: chappe_sip_registry gen_server under chappe_sip_sup
      (above the stack sup, so its ETS survives engine restarts), keyed by
      AOR with per-contact bindings and expiry. RFC 3261 section 10.3 rules
      (per-contact/header Expires, expires=0 removal, Contact:* clear, CSeq
      reorder rejection, periodic sweep + read-time expiry filter).
      chappe_sip:registrar/0 ready handler, chappe_sip:location/1 lookup. Closed
      2026-07-14: chappe_sip_registrar_SUITE 10/10 (9 fake + 1 live REGISTER). 50 CT +
      29 eunit green. No C change.

- [x] M11 Forked second 2xx: C shim gains send_response (OP_MSG_TSEND ->
      nta_msg_tsend), a stateless response forward. chappe_sip_engine:
      forward_response/1; chappe_sip_proxy forwards a forked second 2xx (in drain
      and on_response) instead of dropping it, keeping the proxy's own top
      Via intact (nta_msg_tsend strips it and routes by the next). Closed
      2026-07-14: chappe_sip_forked_2xx_SUITE 1/1 (parallel dual-200, caller gets both
      To-tags). 51 CT + 29 eunit green.

- [x] M12 TLS contacts: a TLS listener bound on its own port via a second
      nta_agent_add_tport (comma-listed transports share one port). C shim
      parses a tls start opt (contact/cert_dir/passphrase/verify/ciphers),
      passes TPTAG_CERTIFICATE + explicit TPTAG_TLS_VERSION (TLS 1.2 floor) +
      TPTAG_TLS_CIPHERS (default; sofia rejects NULL) + verify policy. The
      TLS contact must be sips:...;transport=tls (a sip: URI excludes tls).
      cert_dir holds agent.pem + cafile.pem. Closed 2026-07-14:
      chappe_sip_tls_SUITE 2/2 (OPTIONS over Erlang ssl, UDP still answered).
      53 CT + 29 eunit green.

- [x] M13 PRACK / 100rel: C shim gains reliable_respond (OP_RELIABLE_1XX ->
      nta_reliable_treply with a prack_cb that emits a {prack, TxnH, Raw}
      event and auto-200s the PRACK); nta owns RSeq/RAck/retransmit. UAS:
      chappe_sip_res:send_reliable/2 + await_prack/2 (make_sender routes reliable
      1xx; engine routes the prack event to the txn owner). UAC:
      chappe_sip_uac_fsm advertises rel100 => supported and auto-PRACKs any 1xx
      carrying RSeq (RAck built from RSeq + INVITE CSeq), tracking PRACK txns
      and a separate next_cseq so the ACK keeps the INVITE CSeq. Closed
      2026-07-15: chappe_sip_prack_SUITE 2/2 (our-UAS reliable 183 + PRACK notify;
      our-UAC auto-PRACK). 55 CT + 29 eunit green.

- [x] M14 SIP-over-WebSocket via livery: livery dep (started lazily by
      chappe_sip_ws_sup, only when a WS listener is configured, so UDP-only nodes
      pay nothing). New src/ws/: chappe_sip_ws (handle-range helper), chappe_sip_ws_sup,
      chappe_sip_ws_listener (a livery H1 service upgrading GET /ws), chappe_sip_ws_conn
      (ws_handler), chappe_sip_ws_transport (Erlang transaction layer: server txns
      by branch, legs by Call-ID+tags, ws:send outbound). chappe_sip_engine
      multiplexes each op to the sofia NIF or the WS transport by handle
      (?IS_WS guard) and ingests {chappe_sip_engine, ws, Event}; registrar stores
      the WS flow. chappe_sip:start `ws => #{port}` opt. Closed 2026-07-15:
      chappe_sip_websocket_SUITE 2/2 (REGISTER over WS; full INVITE/200/ACK/BYE call over
      WS), 57 CT + 29 eunit green, release assembles with {livery, load}.
      Deferred (documented): sip subprotocol echo + idle_timeout + peer for
      browser interop; outbound-to-WS; B2BUA WS<->UDP bridge.

- [x] M15 WebRTC gateway over WS (parts A/C/B). A: outbound-to-WS
      (chappe_sip_ws_transport client txns; {ws, Flow} routing in chappe_sip_engine;
      chappe_sip_uac_fsm flow opt; chappe_sip:location_flow/1). C: B2BUA both directions
      over WS. B: proxy both directions incl. in-dialog. In-dialog across a
      WS<->UDP dialog uses a Record-Route flow token (chappe_sip_route ftok) and
      the arrival transport to pick direction (arrived-WS -> UDP by R-URI;
      arrived-UDP -> WS by ftok); chappe_sip_ws_transport emits an unmatched 2xx
      ACK as {ack, Flow, Raw}. Closed 2026-07-15: chappe_sip_webrtc_gateway_SUITE 6/6 (proxy
      + b2bua both directions, callee BYE, received placeholder); 63 CT + 29
      eunit green. Dropped: the original external control-protocol M15
      (re-adds the process boundary the design removed).
- [x] M15 part D (livery handshake): livery 0.6.0 (tag v0.6.0) plumbs the
      WS subprotocol, idle timeout, and peer through livery_ws:upgrade/3.
      chappe_sip_ws_listener negotiates `sip` + idle_timeout=infinity;
      chappe_sip_ws_conn reads the peer from the WS Req; ws_received now asserts
      real received/rport. Test WS clients offer subprotocols=[<<"sip">>].
      Closed 2026-07-16: 63 CT + 29 eunit green.
- [x] M15 part E (interop track): opt-in (`INTEROP=1`) chappe_sip_interop_SUITE and
      an `interop/` harness. A real JsSIP UA registers over WS; two JsSIP UAs
      place a WebRTC media call bridged by the b2bua over WS; a Kamailio
      container OPTIONS-pings chappe_sip both directions (via host.docker.internal,
      dispatcher). Real JsSIP caught two RFC gaps the lenient UDP peers never
      did, now fixed: a dialog-forming 2xx MUST carry a Contact (RFC 3261
      12.1.1; chappe_sip_engine:send_uas_response adds one, bare URI from the bound
      contact), and a UAC-built WS request (2xx ACK) needs a Via the transport
      adds (chappe_sip_ws_transport send_stateless ensure_via, symmetric to
      send_request). The registrar also purges a WS binding when its flow drops
      (RFC 5626; chappe_sip_registry:remove_flow from chappe_sip_ws_transport drop_flow) so
      a disconnected browser is deregistered. Closed 2026-07-16: interop 3/3
      (INTEROP=1), regression 64 CT + 29 eunit green.
- [x] M16 WS transport conformance (RFC 7118, RFC 3261 reliable-transport
      rules, RFC 3262, RFC 5626 keepalive). Server transactions match on
      {Flow, Branch, Method} and answer retransmissions; a non-2xx INVITE
      final waits for its ACK (Timer H); CANCEL answers the INVITE 487; the
      reaper answers 408/500; an unACKed 2xx is BYEd. Client transactions get
      Timer B/F, Timer C with CANCEL, a held CANCEL and the non-2xx ACK.
      100rel over WS (RSeq, PRACK matching, 481). Binary frames both ways,
      400 on a missing header or bad Content-Length, Record-Route mirrored,
      RFC 3581 rport. Overload 503/500 go over WS (and work on a WS-only
      node). CRLF pong on WS and on TCP/TLS (sofia TPTAG_PONG2PING), server
      pings below the 600 s idle timeout (which replaced the earlier
      idle_timeout=infinity), a WSS listener, 1009 close past
      max_message_size. chappe_sip_ws_conf_SUITE.

## Notes

- M0 smoke tests drive SIP over gen_udp directly; sipp lands with M2's
  live groups.
