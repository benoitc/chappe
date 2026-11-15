# Take audio from a fork

This guide shows you how to get a FreeSWITCH channel's audio into an Erlang
process: you open a stream on a chappe_audio listener, give its URL to
mod_audio_fork or mod_audio_stream, and the audio arrives as messages. Use it
to transcribe a call, detect speech, measure levels, or record a channel
without FreeSWITCH writing a file.

## Start a listener

```erlang
{ok, _} = application:ensure_all_started(chappe_audio),
{ok, L} = chappe_audio:listen(#{
    ip => {0, 0, 0, 0},
    port => 8090,
    %% how FreeSWITCH reaches this node
    url => <<"ws://10.0.0.5:8090">>
}).
```

The listener binds `127.0.0.1` unless you give `ip`. Set `url` whenever
FreeSWITCH sees the node at another address (a container, a NAT). For wss,
add `tls => SslServerOptions`; the URL then starts with `wss://`.

To start one with the application instead, set the `listener` env (see
[configuration](../configuration.md)) and call `chappe_audio:open/1`.

## Open a stream and start the fork

```erlang
{ok, Stream, Url} = chappe_audio:open(L, #{
    ref => CallRef,
    format => #{rate => 8000, channels => 1}
}),
ok = chappe_mrf:fork_audio_start(Ep, Url, #{mix => mono, rate => 8000,
                                            metadata => <<"{\"call\":\"42\"}">>}).
```

`Url` carries the stream's own path and a random token as `?token=`.
mod_audio_fork may send the token as a Basic auth password instead
(`MOD_AUDIO_BASIC_AUTH_USERNAME` and `MOD_AUDIO_BASIC_AUTH_PASSWORD` channel
variables), and any client as `Authorization: Bearer`. A fork that does not
connect within `connect_timeout` (30 s) closes the stream.

Without chappe_mrf, the commands are the modules' own:

```
uuid_audio_fork <uuid> start <url> mono 8000 audio_fork {"call":"42"}
uuid_audio_stream <uuid> start <url> mono 8k {"call":"42"}
```

## Receive the audio

```erlang
loop(Stream) ->
    receive
        {chappe_audio, Stream, {connected, #{peer := Peer}}} ->
            loop(Stream);
        {chappe_audio, Stream, {text, Metadata}} ->
            loop(Stream);
        {chappe_audio, Stream, {frame, Pcm}} ->
            [Db] = chappe_audio:levels(Pcm, 1),
            loop(Stream);
        {chappe_audio, Stream, {closed, Why}} ->
            {done, Why}
    end.
```

The events keep this shape with or without a `ref`; read the stream's ref
with `chappe_audio:ref(Stream)`.

- `{frame, Pcm}` is one WebSocket message: 16-bit signed little-endian PCM
  at the rate you started the fork with, usually 20 ms. In stereo the two
  channels are interleaved, the caller on the left.
- `{text, Bin}` is the fork's metadata first, then any text it sends.
- `{closed, Why}` is always the last event. `Why` is `normal` (you called
  `close/1`), `peer_closed` (the fork stopped, or the connection ended for
  a reason the stream cannot tell), `timeout` (no fork connected within
  `connect_timeout`), `too_large` (a message over `max_frame`), `idle`
  (nothing for `idle_timeout`) or `{error, Reason}` (the session could not
  start). When the owner dies, nothing is sent.

Send text back to the fork (both modules take JSON commands this way):

```erlang
ok = chappe_audio:send_text(Stream, <<"{\"type\":\"mark\"}">>).
```

## Stop

Stop the fork (`chappe_mrf:fork_audio_stop/1`) and the stream closes on its
own, or close it from your side:

```erlang
ok = chappe_audio:close(Stream).
```

## Find a call's streams from any node

```erlang
[Stream] = chappe_audio:streams(CallRef).
```

## Notes

- The owner is the caller of `open/2` unless you pass `owner`. The stream
  monitors it: when the owner dies, the stream closes the connection (1001)
  and stops. `set_owner/2` hands it to another process.
- The bound: when the owner already has `max_queue` messages waiting (500
  by default, 10 s of 20 ms frames), a frame is dropped and counted in
  `chappe_audio:info(Stream)` (`dropped`). A slow owner never grows the
  stream's memory.
- A message over `max_frame` bytes (256 KiB) closes the connection with
  1009 and the stream ends with `too_large`; one over twice that is cut
  while it is read, and the stream ends with `peer_closed`. A message that is not a whole number of samples is dropped and
  counted (`bad_frames`).
- The token is in the URL, so it shows in FreeSWITCH's debug log. Each
  stream has its own and accepts one connection.
- The stream and the listener are pids: you can open a stream on a
  listener of another node and get its events where you are.
