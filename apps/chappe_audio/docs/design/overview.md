# Design overview

This page describes how chappe_audio is built: its processes, what each
one owns, and the bounds it keeps. Read it before you change the sink or
the store, or review a change to them.

## Processes

```
chappe_audio_sup (rest_for_one)
|-- chappe_audio_rtp_sup           one chappe_audio_rtp per received RTP stream
|-- pg scope chappe_audio          its own, for streams by ref and the stores
|-- chappe_audio_registry          streams waiting for their fork, by id (ETS)
|-- chappe_audio_store_srv         the node's store: config, pg group, sweep
|-- chappe_audio_writer_sup        one chappe_audio_writer per recording
|-- chappe_audio_adopt_sup         one chappe_audio_adopt per file taken into the store
|-- chappe_audio_stream_sup        one chappe_audio_stream per fork
|-- chappe_audio_conn_sup          one chappe_audio_conn per handshake
|-- chappe_audio_listener_sup      one chappe_audio_listener per port
`-- chappe_audio_listener          the default listener, with the env
```

Every child of a `_sup` is temporary: a stream, a writer or a handshake
that crashes is not restarted, and its owner sees it go through its
monitor.

| Module | Role |
|---|---|
| `chappe_audio` | Public API: listeners, `open/1,2` for forks, `streams/1`, `levels/2`, and `rtp_receiver/1`, the RTP receiver a SIPREC recording server (`chappe_sip_siprec_srs`) starts per recorded stream. |
| `chappe_audio_rtp` | One received RTP stream: UDP socket, G.711 decode to PCM, sink to a recording or a process. |
| `chappe_audio_srtp` | Receive-only SRTP and SRTCP (RFC 3711) for `chappe_audio_rtp`. |
| `chappe_audio_listener`, `chappe_audio_conn`, `chappe_audio_http` | The WebSocket listener, one opening handshake, its HTTP/1.1 side. |
| `chappe_audio_stream`, `chappe_audio_ws`, `chappe_audio_registry` | One fork's stream, its ws_handler, the streams by id. |
| `chappe_audio_store`, `chappe_audio_store_srv`, `chappe_audio_store_file` | The store API and behaviour, the node's store, the folder backend. |
| `chappe_audio_writer`, `chappe_audio_adopt` | One recording being written, one finished file taken into the store. |
| `chappe_audio_pcm`, `chappe_audio_wav` | 16-bit PCM helpers, the WAVE container. |
| `chappe_audio_lib`, `chappe_audio_pg` | Shared helpers (bounded sends), the pg scope. |
| `chappe_audio_app`, `chappe_audio_sup` | Boot and the root supervisor. |

| Process | Owner | Cleans up | pg | Bound |
|---|---|---|---|---|
| listener | its supervisor | its socket, its acceptor (linked) | none | `max_pending` handshakes, `max_pending_per_ip` per address |
| handshake | the listener's acceptor | its socket, unless handed to a stream | none | `handshake_timeout`, `max_handshake` |
| stream | the app (monitored) | the connection (1001), its writer | `{chappe_audio, Ref}` | `max_queue` events at the owner, `max_frame` per message |
| writer | its feeder (monitored) | finishes the file when the feeder goes | none | `max_queue`, applied by the sender |
| store | its supervisor | the sweep | `chappe_audio_store` | lookups time out after 5 s |

## A fork's path

1. `open/2` asks the listener (any node) to start a stream on its node; the
   stream registers its id and the hash of a random token.
2. FreeSWITCH connects. The acceptor hands the socket to a handshake, which
   reads the request (RFC 6455 4.2.1), checks the path, the token (constant
   time) and the upgrade, claims the stream (one connection each), answers
   101 and hands the socket over. A refusal is an HTTP status, and 401 does
   not say whether the stream exists.
3. The stream starts the ws_session (erlang_ws) on the socket and links to
   it. The session's handler only relays messages to the stream.
4. The stream sends events to its owner, drops past the bound, and writes to
   its recording with `store => default`.

## Recorded RTP

A SIPREC recording server (`chappe_sip_siprec_srs` in chappe_sip) does
the SIP and asks chappe_audio for one receiver per recorded stream with
`chappe_audio:rtp_receiver/1`. The design of both sides is in the
[SIPREC design page](../../../chappe_sip/docs/design/siprec.md).

- **One process per stream.** Each receiver is a `chappe_audio_rtp` under
  `chappe_audio_rtp_sup`, owned by the process that started it. It stops
  when the owner exits or on `chappe_audio_rtp:stop/1`, and then finishes
  its store recording. A receiver that crashes leaves its partial file to
  the store's sweep and touches neither its owner nor the other streams.
- **G.711 decode.** PCMU and PCMA become 16-bit linear PCM
  (`chappe_audio_pcm`). Another payload type, RTCP and anything that does
  not parse is dropped.
- **The source.** The receiver latches to the first source at the
  `remote` address it was given (any port), or, with `remote =>
  undefined`, to the first source at all, and drops every other source.
  `chappe_audio_rtp:remote/2` (the sender moved) makes it learn again from
  the new address, the old source dropped for 1 s only.
- **SRTP.** Given `srtp => Ctx` (`chappe_audio_srtp:new/1`), it takes SRTP
  only: each packet is authenticated, checked against the replay window
  and decrypted before it is decoded, and it latches only once a packet
  authenticates. Failed packets are counted (`chappe_audio_rtp:stats/1`)
  and logged at most once per 10 s. `chappe_audio_rtp:rekey/2` takes the
  sender's new key. The keys stay in a closure and out of every report
  ([decision 0009](../../../../docs/decisions/0009-srtp-in-erlang.md)).
- **The sink.** `{store, Mod, Info}` writes a recording of the store;
  `{pid, Pid}` sends `{Tag, Stream, {audio, Pcm}}` (`tag`, default
  `chappe_audio_rtp`) and drops frames while the process has `max_queue`
  (default 500) messages waiting.
- **Ports.** `ports => {Min, Max}` binds a free port in the range;
  none free is `{error, no_port}`. The app not running is
  `{error, not_started}`.
- **It outlives the store.** `chappe_audio_rtp_sup` is the first child of
  the `rest_for_one` root, needing none of the others, so a crash of the
  store or the registry never drops a live stream
  ([decision 0011](../../../../docs/decisions/0011-chappe-audio-leaf.md)).

## The store

`chappe_audio_store` is the API and the behaviour. Calls that write go to
the local node; `find/1` asks every member of the `chappe_audio_store` pg
group and merges; `get/1`, `read/2` and `delete/1` ask the local store and
then the others. The file backend renames the audio, then the sidecar, so a
listing never shows a recording in progress. A call_ref that is not a plain
name becomes `x-` and its SHA-256 in the path.

## Tests

| Area | Tests |
|---|---|
| WebSocket forks, the listener and the handshake | `chappe_audio_SUITE`, `chappe_audio_http_tests` |
| The store, writers, adoption, retention, lookups across nodes | `chappe_audio_store_SUITE` |
| The pg scope | `chappe_audio_pg_SUITE` |
| Recorded RTP: G.711, the source latch, SRTP, port range, owner exit, store sink, store crash | `chappe_audio_rtp_SUITE` |
| SRTP against the RFC 3711 vectors and a reference sender | `chappe_audio_srtp_tests` (with `chappe_audio_test_srtp`) |
| PCM and WAVE helpers | `chappe_audio_pcm_tests`, `chappe_audio_wav_tests` |
| Real FreeSWITCH forks | `chappe_audio_live_SUITE` (`make interop-esl`) |
| The SIPREC server end to end | `chappe_sip_siprec_SUITE`, `chappe_sip_siprec_live_SUITE` (`make interop`), in chappe_sip |

## Sources checked

- mod_audio_fork: the module's source (the drachtio code base as
  continued in W1ck3dZA/mod_audio_fork, read 2026-11-14) and the lab image
  (drachtio-freeswitch-mrf, FreeSWITCH 1.10.10): subprotocol
  `audio.drachtio.org`, metadata as the first text message, binary L16
  messages, Basic auth from channel variables, the path with its query.
- mod_audio_stream v1.1.0 (fe3af21, the lab's pin): no subprotocol,
  metadata as the first text message, binary L16, extra headers from
  `STREAM_EXTRA_HEADERS`, permessage-deflate not negotiated by the sink.
- RFC 6455 (updated by RFC 7936, 8307, 8441; none touch the opening
  handshake of HTTP/1.1), read 2026-11-14.
