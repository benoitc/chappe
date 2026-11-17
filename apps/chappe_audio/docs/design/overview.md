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

## The store

`chappe_audio_store` is the API and the behaviour. Calls that write go to
the local node; `find/1` asks every member of the `chappe_audio_store` pg
group and merges; `get/1`, `read/2` and `delete/1` ask the local store and
then the others. The file backend renames the audio, then the sidecar, so a
listing never shows a recording in progress. A call_ref that is not a plain
name becomes `x-` and its SHA-256 in the path.

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
