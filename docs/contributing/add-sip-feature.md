# Add a SIP feature or header

Most SIP features touch the same few places: the header grammar, the message
model, the dialog or UAC state machine that acts on it, and the facade that
exposes it. Use this page when you add support for a new header, option tag,
method or RFC rule in chappe_sip.

## Before you start

- [concepts.md: Engine and nta](../concepts.md#engine-and-nta): what sofia
  does for you (transactions, retransmits, Via) and what the Erlang side owns.
- [apps/chappe_sip/docs/design/overview.md](../../apps/chappe_sip/docs/design/overview.md):
  the layers of `src/`.
- [apps/chappe_sip/docs/design/ws-transport.md](../../apps/chappe_sip/docs/design/ws-transport.md):
  WebSocket has its own transaction layer that must stay in step with nta.
- The RFC section, and its rows in
  `apps/chappe_sip/docs/compliance/requirements.tsv`.

## Where to look

| Need | Module (under `apps/chappe_sip/`) |
|---|---|
| Parse or format a header value | `src/sip/chappe_sip_hdr.erl` (grammar: Via, CSeq, name-addr, Replaces, Refer-To, Event, Subscription-State, ...) |
| Read or change headers on a message | `src/sip/chappe_sip_msg.erl` (`get/2`, `get_all/2`, `set/3`, `add/3`, `remove/2`) |
| URIs | `src/sip/chappe_sip_uri.erl` |
| The request and response handed to apps | `src/sip/chappe_sip_req.erl`, `src/sip/chappe_sip_res.erl` |
| SDP | `src/sip/chappe_sip_sdp.erl` |
| Default `Allow` and `Supported` | `include/chappe_sip.hrl` (`?ALLOW`, `?SUPPORTED_TAGS`), `src/chappe_sip_config.erl` |
| In-dialog behaviour | `src/dialog/chappe_sip_dialog_fsm.erl`, `chappe_sip_session_timer`, `chappe_sip_refer` |
| Outbound requests | `src/uac/chappe_sip_uac_fsm.erl` |
| Inbound dispatch | `src/engine/chappe_sip_engine.erl`, `src/conn/chappe_sip_request_worker.erl` |
| WebSocket transactions | `src/ws/chappe_sip_ws_transport.erl` |
| Public entry points | `src/api/chappe_sip.erl` |

## Steps

1. Find the clause. Note its row ids in `requirements.tsv`; add rows if the
   catalogue lacks them ([compliance.md](compliance.md)).
2. Grammar first. Add the parser and formatter to `chappe_sip_hdr` with
   eunit cases in `test/chappe_sip_hdr_tests.erl`. Before writing a helper,
   look for one:

   ```sh
   grep -rn '^name(' apps/chappe_sip/src
   ```

3. Behaviour next. Change the fsm that owns the decision. If the rule applies
   to WebSocket traffic too, check that `chappe_sip_ws_transport` does the same
   thing nta does for UDP, TCP and TLS.
4. If apps need to drive the feature, expose it through the facade:
   [extend-public-api.md](extend-public-api.md).
5. Write the CT case with a `%% req:` line, run it on the old code to see it
   fail, then on the new code.
6. If an independent stack can check it on the wire, add a SIPp scenario to
   the conformance lab
   ([conformance README](../../apps/chappe_sip/interop/conformance/README.md)).

## Tests to add or run

| Kind | Where |
|---|---|
| Grammar | `test/chappe_sip_hdr_tests.erl`, `chappe_sip_msg_tests`, `chappe_sip_uri_tests`, `chappe_sip_sdp_tests` |
| Torture messages | `test/chappe_sip_rfc4475_SUITE.erl` (RFC 4475 corpus in `_SUITE_data`) |
| Behaviour over real sockets | the suite of the area: `uas`, `uac`, `indialog`, `dialog_ops`, `session_timer`, `refer`, `replaces`, `prack`, `subscribe`, ... |
| Exact headers seen by a peer | `chappe_sip_raw_peer` and `chappe_sip_test_ua` in those suites |
| Wire conformance | `apps/chappe_sip/interop/sipp/scenarios/<case>.xml` plus a case in `chappe_sip_conformance_SUITE` |

## How to know it works

- `make check` passes.
- `make interop-conformance` passes, and your new case is not in
  `interop/conformance/expected-fail`.
- `make compliance GATE=demo` passes, and the rows you claimed show `pass` in
  `apps/chappe_sip/docs/compliance.md`.

## Notes

- sofia is vendored as upstream ships it. Where nta deviates from an RFC,
  record the row as a `deviation` with the reason. A patch in
  `apps/chappe_sip/c_src/sofia-patches` is for a bug in sofia (with an
  upstream ticket and a repro), not for a behaviour you can handle in Erlang.
- Header names are case-insensitive; `chappe_sip_msg` lowercases them, so
  match on lowercase binaries.

## Related

- [compliance.md](compliance.md)
- [extend-public-api.md](extend-public-api.md)
- [add-event-package.md](add-event-package.md)
- [change-c-engine.md](change-c-engine.md)
