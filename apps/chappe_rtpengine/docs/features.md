# Features

## Current

- Bencode codec (canonical key ordering, duplicate keys refused on encode, non-canonical integers and length prefixes rejected, nesting bounded at 64, unsorted dicts tolerated, wire types preserved)
- NG command data model: atom-keyed maps to NG wire names (including `media address`, `address family`, `received from`, `ICE-lite`, `TOS`, `DTLS-fingerprint`, `DTLS-reverse`, `T.38`), hyphenated option words under `flags`/`replace`/`ICE`/... and verbatim atom values elsewhere, `{bad_param, Key, Value}` for floats and tuples, binary passthrough for unmapped keys
- Supervised client, one per rtpengine node, added and removed at runtime; NG over UDP (default), TCP (`transport => tcp`) with incremental stream parsing, or WebSocket (`transport => ws | wss`) against `--listen-http`/`--listen-https` with `ng.rtpengine.com` subprotocol negotiation and TLS options; reliable transports reconnect automatically
- Request cookies with response correlation, per-attempt retransmission of the identical datagram, bounded timeouts
- Commands: ping, offer, answer, delete, query, plus any NG command through `chappe_rtpengine:cmd/3`
- Reply classification: ok/pong (with any `warning` kept in the reply), rtpengine errors with reason, `load_limit`, unexpected results, timeout, malformed reply
- UDP size guard: `max_datagram` (default 65507) and kernel `emsgsize` both give `{error, too_large}`; 256 KiB socket buffers for large SDP
- Node addresses follow DNS: TCP and WebSocket resolve the host on every connect; UDP re-resolves every `resolve_interval_ms` (default 60000, `infinity` disables) and after `resolve_after_timeouts` consecutive timeouts (default 2), in a helper process, swapping the destination (and the socket when the address family changes); `resolver` replaces inet for custom lookups; `address_changes` counts moves
- NG over TCP framed by a pure incremental parser (`chappe_rtpengine_stream`): linear in the stream size, 4 MiB stream and 256-byte cookie caps
- TCP host re-resolution on every connect attempt; WebSocket replies accepted in binary or text frames
- Per-node transport counters (sent, replies, retransmits, timeouts, bad replies, unknown cookies)
- Node pool: registry, health checks (consecutive-timeout down, health-ping recovery), least-loaded selection, call pinning, generation bump on recovery for restart detection, node up/down event subscription
- Media session `gen_statem` per call: offer/answer lifecycle, automatic node selection and pinning, owner monitoring with delete on owner death, best-effort delete on any termination, re-INVITE with glare rejection (every competing offer while an exchange is open), `reoffer_rejected/1` rollback, failed answers keep the to-tag, repeated answers, `{error, stopped}` for requests in flight at stop or owner death
- Callee-initiated re-INVITE (`initiator => callee`) with wire-level tag swap
- Fork branch tracking: answers with distinct to-tags accumulate branches, `final => true` prunes losing branches with targeted deletes
- Session media helpers: play_media (file, blob, blob64, db_id, repeat_times, party selection), stop_media, play_dtmf, block/unblock_dtmf, start/stop_recording, plus `chappe_rtpengine_session:cmd/3` for any NG command with the session identity injected
- Ducking: block/unblock_media and silence/unsilence_media with `party => caller | callee` (from-tag plus the `directional` flag on the wire) or whole-call default
- STT forking: subscriptions with `party` selection, `codec` mask/transcode control and `ptime`; `allow_transcoding` answers accepted
- Owner notifications: `{chappe_rtpengine_session, Pid, {node_down, Node}}` and `{node_restarted, Node}` (generation bump on recovery, or an "unknown call-id" reply on a live session)
- DTMF event listener (`chappe_rtpengine_dtmf`): receives rtpengine's `--dtmf-log-dest` JSON datagrams, dispatches per call-id to subscribers; sessions started with `dtmf => true` forward events to their owner; `open/2` binds an `ip` and filters by `allowed_sources`
- Media subscriptions on sessions: `subscribe_request` (SDP offer for the tapped streams plus subscription to-tag), `subscribe_answer`, `unsubscribe`; the building blocks for recording taps, listen-in, and conference graphs. Requires an rtpengine built with transcoding support
- One-sided anchor: `publish` (session and node level) for a call with no second leg, such as a recording server taking N sendonly streams; rtpengine writes the answer and the session goes straight to established
- Per-stream forking (`chappe_rtpengine_sdp`): a subscription offer's m-line order and labels through `streams/1`, and `fork_answer/2,3` to answer it with one stream (by `a=label` or m-line index) routed to one receiver and the rest rejected, IPv4 or IPv6 receivers, errors for streams the offer rejected and for bad selectors. rtpengine has no request-side stream selector, so the answer carries the selection
- Test double (`chappe_rtpengine_fake_server`) with drop, duplicate, delayed and raw-reply injection, runtime handler swap
- Compliance catalogue (`docs/compliance/requirements.tsv`): NG protocol behaviours, each claimed by the tests that prove it with `%% req:` lines
- Live test suite against a real rtpengine, gated on `RTPENGINE_HOST`, driven by the `interop/` docker compose harness
- Leaf-library toolchain (docs/design/leaf-library-contract.md): seven verification gates (compile, eunit, ct, elvis lint, xref, dialyzer, erlfmt) wired into the Makefile and CI

## Roadmap

- Kernel-module statistics surfaced through the pool
