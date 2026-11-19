# Features

What chappe_audio does today, and what is planned. Each line links to the
page that shows you how to use it.

## Working

- **WebSocket sink** for FreeSWITCH's mod_audio_fork and mod_audio_stream:
  one listener, a path and a token per stream checked before the upgrade, a
  bound on the handshakes one address may hold, ws or wss.
  [Take audio from a fork](guides/fork.md)
- **A listener under your supervisor**: `child_spec/1` keeps one for your
  app's lifetime, restarted on its port.
  [Take audio from a fork](guides/fork.md#keep-a-listener-for-your-apps-lifetime)
- **One process per stream**, owned by the process you name: mono or stereo
  16-bit PCM as `{frame, Pcm}`, the fork's text and metadata, and `closed`
  with its reason. Frames past the stream's bound are dropped and counted;
  a stream ends when its owner exits. [Take audio from a fork](guides/fork.md#receive-the-audio)
- **Levels**: `levels/2` reads a frame's level in dBFS.
- **Lookups across nodes**: a call's streams by its `call_ref`, through the
  `chappe_audio` pg scope. [Take audio from a fork](guides/fork.md#find-a-calls-streams-from-any-node)
- **Default recording store** (`chappe_audio_store`), a folder of WAV files
  with a JSON sidecar each, written under a temporary name and renamed: open,
  write, close, adopt a finished file, find by `call_ref` on every node, get,
  read a byte range, delete, and a retention sweep. Another backend is a
  module with the same callbacks. [Record a call](guides/record.md)
- **Sweep guard**: a fun that says whether this node sweeps, so one node
  sweeps a store the nodes share.
  [Record a call](guides/record.md#sweep-a-shared-store-from-one-node)
- **Store writers**: one supervised process per recording, bounded, owned by
  the stream or session that feeds it; one that crashes leaves a partial
  file the sweep removes. [Record a call](guides/record.md#notes)
- **Every chappe entry point writes to it**: forks, FreeSWITCH recordings
  and room recordings (chappe_mrf), and chappe_sip's SIPREC recording
  server. [Record a call](guides/record.md#where-each-entry-points-audio-goes)

## Also exported

These functions are exported and supported, but no guide shows them yet.

- `chappe_audio:stop_listener/1` stops a listener `listen/1` started.
- `chappe_audio_store:config/0` returns this node's store settings (backend,
  dir, retention, sweep interval and guard).
- `chappe_audio_store_file:ref_dir/1` gives the folder name the file
  backend uses for a `call_ref`.
- `chappe_audio_srtp:derive/4` and `crypt/5` are the RFC 3711 key
  derivation and AES-CM keystream the receiver uses.

## Planned

- An object store backend (S3 and the like).
