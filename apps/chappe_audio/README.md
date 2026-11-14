# chappe_audio

chappe_audio takes a call's audio in and keeps it. It is a WebSocket sink
for FreeSWITCH's mod_audio_fork and mod_audio_stream, with one process per
stream that hands the audio to the process you name, and a recording store
that every chappe entry point writes to and finds recordings in by
`call_ref`. Use it when you want a call's audio in Erlang (to transcribe it,
to measure it, to record it) or when you want one place where a call's
recordings land. It is a leaf app: it depends on erlang_ws and nothing SIP.

## Take a fork's audio

```erlang
{ok, _} = application:ensure_all_started(chappe_audio),
{ok, L} = chappe_audio:listen(#{ip => {0, 0, 0, 0}, port => 8090,
                                url => <<"ws://10.0.0.5:8090">>}),
{ok, Stream, Url} = chappe_audio:open(L, #{ref => CallRef}),
ok = chappe_mrf:fork_audio_start(Ep, Url, #{mix => mono, rate => 8000}),
receive
    {chappe_audio, Stream, {frame, Pcm}, CallRef} -> handle(Pcm)
end.
```

Each stream has its own path and token in `Url`; a fork with another path
or token is refused before the upgrade.

## Keep a recording

```erlang
{ok, Stream, Url} = chappe_audio:open(L, #{ref => CallRef, store => default}),
%% ... the fork runs, then stops ...
[#{id := Id, path := Path, duration_ms := Ms}] = chappe_audio_store:find(CallRef).
```

The default store writes `recordings/YYYY/MM/DD/<call_ref>/<id>.wav` with a
JSON sidecar next to it.

## Guides

- [Take audio from a fork](docs/guides/fork.md)
- [Record a call](docs/guides/record.md): every entry point and where its
  audio lands
- [Configuration](docs/configuration.md)
- [Design overview](docs/design/overview.md)
