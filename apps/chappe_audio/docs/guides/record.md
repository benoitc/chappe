# Record a call

This guide lists every way chappe can record a call, and says for each one
where its audio lands and how you find it again. chappe never decides where
a recording lives: you configure the store (by default a folder), and every
recording carries the call's `call_ref`, so `chappe_audio_store:find/1`
returns a call's recordings whatever made them. Read it before you choose
how to record, or when you look for a recording.

## Where each entry point's audio goes

| Entry point | Where the audio goes |
|---|---|
| SIPREC client (chappe_sip) | the recording server URI you give, per call or as a default: enki_vox, a vendor recorder, or chappe's own server side |
| chappe's SIPREC server side | `store => default` on `chappe_sip_siprec_srs:serve/3` writes each stream to the store, source `siprec`; or your handler takes the streams (`sink => Pid`) and the parsed metadata itself |
| a FreeSWITCH fork into chappe_audio | `store => default` on `chappe_audio:open/2` writes the stream to the store; or the owner takes the frames |
| a chappe_mix tap | your process gets the PCM; write it with `chappe_audio_store:open/2` |
| FreeSWITCH `record`, `record_session` | `store => default` on `chappe_mrf:record/3` or `record_session/3`: FreeSWITCH writes into the folder it shares with chappe, and chappe adopts the file when it is done; or you give your own path and keep it |
| FreeSWITCH room recording | `store => default` on `chappe_mrf_conf:record/3`: adopted when it stops |
| native room recording | `chappe_mrf_conf:record(Conf, SrsUri, Opts)`: the mix goes through SIPREC to the recording server you name; chappe's own server side with `store => default` writes it to the store |
| rtpengine recording | rtpengine's spool, set by the operator; with a shared spool, adopt the file with `chappe_audio_store:adopt/3` |

## Configure the store

The default needs nothing: a `recordings` folder in the node's working
directory.

```erlang
%% sys.config
[{chappe_audio, [
    {storage, #{backend => file, dir => "/var/lib/chappe/recordings",
                retention_days => 30}}
]}].
```

Or at run time:

```erlang
ok = chappe_audio_store:configure(#{dir => "/var/lib/chappe/recordings"}).
```

A recording is `dir/YYYY/MM/DD/<call_ref>/<id>.wav`, with `<id>.json` next
to it: the call_ref, parties, source, start, duration and format. Both are
written under a `.part` name and renamed, so a recording in progress is
never listed.

## Record a fork

```erlang
%% format says what the fork sends
{ok, Stream, Url} = chappe_audio:open(L, #{
    ref => CallRef, store => default, format => #{rate => 16000, channels => 2}
}),
ok = chappe_mrf:fork_audio_start(Ep, Url, #{mix => stereo, rate => 16000}).
```

The owner still gets the frames.

## Record on FreeSWITCH

Map the folder FreeSWITCH records into to the same folder on this node:

```erlang
%% sys.config
[{chappe_mrf, [{shared_dir, #{freeswitch => "/media", local => "/srv/fs-media"}}]}].
```

Then:

```erlang
{ok, Id} = chappe_mrf:record(Ep, <<"/media/msg.wav">>, #{max_secs => 30, store => default}),
ok = chappe_mrf:record_session(Ep, <<"/media/call.wav">>, #{store => default}),
ok = chappe_mrf:record_session_stop(Ep, <<"/media/call.wav">>),
receive {chappe_mrf, Ep, {recorded, Id2}} -> Id2 end.
```

A session recording is adopted once FreeSWITCH has closed the file (its
RECORD_STOP, after `record_session_stop/2` or the hangup), and the
endpoint's owner gets `{chappe_mrf, Ep, {recorded, Id}}`. If the close is
never seen (the endpoint goes first), the file is copied once it stops
growing and the source is left where it is. The recording is
filed under the endpoint's call_ref; pass `ref => Bin` to choose another.
A path outside the shared folder returns `{error, not_shared}` before
FreeSWITCH sees the command.

A room:

```erlang
ok = chappe_mrf_conf:record(Conf, <<"/media/room.wav">>, #{store => default, ref => RoomRef}),
ok = chappe_mrf_conf:stop_record(Conf),
receive
    {chappe_mrf_conf, Conf, {recorded, _Path, {ok, Id}}} -> Id
end.
```

## Write your own audio to the store

```erlang
{ok, Rec} = chappe_audio_store:open(#{call_ref => CallRef, source => room,
                                      format => #{rate => 8000, channels => 1}}, #{}),
{ok, Tap} = chappe_mix:tap(Conf, room, #{}),
receive
    {chappe_mix, Conf, {tap, Tap, Pcm}} -> ok = chappe_audio_store:write(Rec, Pcm)
end,
{ok, Id} = chappe_audio_store:close(Rec, #{parties => [<<"alice">>, <<"bob">>]}).
```

The writer is owned by the caller of `open/2`: when that process dies, the
writer finishes the recording with what it has. Past `max_queue` writes
waiting at it (500), `write/2` returns `dropped`.

## Take in a file something else wrote

```erlang
{ok, Id} = chappe_audio_store:adopt("/var/spool/rtpengine/abc.wav", CallRef,
                                    #{source => rtpengine}).
```

The file is moved in (copied, then removed, across file systems; `keep =>
true` copies it). A WAVE file's format and length come from its header.

## Find and read recordings

```erlang
[#{id := Id, node := Node, path := Path, duration_ms := Ms}] =
    chappe_audio_store:find(CallRef),
{ok, Rec} = chappe_audio_store:get(Id),
{ok, Bytes} = chappe_audio_store:read(Id, {0, 65536}),
ok = chappe_audio_store:delete(Id).
```

`find/1` asks the store of every node through pg, so a cluster finds a
call's recordings wherever they were written. `read/2` returns a byte range
of the file, for playback over HTTP with Range requests.

## Sweep a shared store from one node

Each node sweeps its own store. That is right for the file backend, where
each node holds its own folder. When the nodes share one store (a shared
folder, an object store backend), let one node sweep it: pass a
`sweep_guard`, a fun (or `{M, F, A}`) that says whether this node sweeps
now. Back it with a chappe_cluster singleton, whose lease is held by one
node of the region at a time:

```erlang
%% on every node: one of them runs the (idle) child and holds the lease
ok = chappe_cluster:singleton(recording_sweep,
                              #{id => sweep, start => {my_idle, start_link, []}}),
ok = chappe_audio_store:configure(#{
    backend => my_store,
    sweep_guard => fun() -> chappe_cluster:singleton_valid(recording_sweep) end
}).
```

- The guard runs before each sweep, timed or asked for with
  `chappe_audio_store:sweep/0`. A guard that returns anything but `true`,
  or fails, skips the sweep (`{ok, 0}`).
- The default is no guard: the node always sweeps.
- chappe_audio does not depend on chappe_cluster; the guard is yours.

## Notes

- Retention: with `retention_days`, the sweep (hourly, `sweep_interval`)
  deletes the day folders older than that. It also removes `.part` files an
  hour old, which a writer that died leaves behind. On a shared store, see
  `sweep_guard` above.
- Another backend (an object store) is a module with the
  `chappe_audio_store` callbacks, set as `backend => my_store`.
- The SIPREC server side writes to the store through the same API
  (`chappe_audio_store:open/2` with `source => siprec`, one recording per
  stream). chappe_audio must run on the node that answers the session:
  without it `open/2` returns `{error, not_started}` and each stream is
  refused with port 0.
- Recordings and their sidecars hold personal data. Set `retention_days`,
  and keep `dir` readable only by the node's user.
