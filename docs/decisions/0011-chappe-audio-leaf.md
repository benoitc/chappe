# 0011: chappe_audio is a leaf app with a store behaviour, and takes in recorded RTP

This record explains why a call's audio, from a FreeSWITCH fork or from a
SIPREC recording client, enters chappe through chappe_audio, a leaf app,
and why where a recording is kept is a behaviour the app picks. Read it
before you add a source of audio, a recording backend, or a dependency to
chappe_audio.

## Status

Accepted. It records the code as merged.

## Context

What the repository shows:

- chappe_audio takes in two kinds of audio: WebSocket forks from
  FreeSWITCH (`mod_audio_fork`, `mod_audio_stream`), and RTP streams, one
  process per stream, started with `chappe_audio:rtp_receiver/1`
  (moduledocs of `apps/chappe_audio/src/chappe_audio.erl` and
  `chappe_audio_rtp.erl`). The RTP receiver decodes G.711 and, given an
  SDES context, takes SRTP ([0009](0009-srtp-in-erlang.md)).
- Its `applications` are kernel, stdlib, `crypto` and `ws`
  (`apps/chappe_audio/src/chappe_audio.app.src`): no umbrella app, as
  [0003](0003-leaf-apps.md) requires.
- `chappe_audio_store` is a behaviour: `open/2`, `write/2`, `close/2`,
  `abort/1`, `adopt/3`, `find/2`, `get/2`, `read/3`, `delete/2`, `sweep/1`,
  and the optional `part/1`. The default is the file backend in a folder,
  `#{backend => file, dir => "recordings"}` (the `storage` env in the
  `.app.src`, `chappe_audio_store_file`). Its moduledoc: "chappe never
  decides where a recording lives: the app configures the store".
- `find/1` asks the store of every node through pg, since the file backend
  keeps a recording on the node that wrote it (`chappe_audio_store`
  moduledoc).
- `chappe_audio_sup` is `rest_for_one` and starts the RTP receivers'
  supervisor first, "which needs none of the others to start: a crash of
  the store or the registry never drops a live SIPREC stream" (its
  moduledoc).
- Two users above it: the SIPREC recording server
  (`chappe_sip_siprec_srs`, store `default` is the `siprec_store` setting,
  `chappe_audio_store` by default in `chappe_sip_config`), and chappe_mrf,
  which adopts FreeSWITCH recordings into the store
  (`apps/chappe_mrf/src/chappe_mrf_store.erl`, `chappe_audio_store:adopt/4`).

## Decision

- Audio that chappe receives itself enters through chappe_audio, a leaf
  app under the contract of [0003](0003-leaf-apps.md). Its concern is the
  intake of recorded audio and the store, nothing about SIP.
- A recording is kept by a module that implements `chappe_audio_store`.
  The app configures it; chappe ships the file backend.
- An RTP receiver is a process of its own under `chappe_audio_rtp_sup`,
  owned by the process that started it, and outlives a crash of the store.

## Consequences

- A product with no SIP can record FreeSWITCH forks with chappe_audio
  alone.
- To keep recordings in an object store or a database, you write a module
  with the callbacks above and name it as `backend => Module`.
- A SIP process never receives RTP: the SIPREC server's SIP side asks
  chappe_audio for receivers ([0012](0012-siprec-srs.md)).
- `chappe_audio:rtp_receiver/1` returns `{error, not_started}` when the app
  is not running, so a caller must handle a node without it
  ([0014](0014-optional-siblings.md)).

## Open questions

- The receiver decodes PCMU and PCMA only (`chappe_audio_rtp` moduledoc).
  Whether other codecs are decoded there, or rtpengine transcodes in front,
  is not recorded.
