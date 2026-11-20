# Configuration

This page lists what you can set in chappe_audio: two application
environment keys, the listener options, the stream options and the RTP
receiver options. Read it when
you wire chappe_audio into a release or tune a listener.

## Application environment

| Key | Default | What it does |
|---|---|---|
| `listener` | unset | Listener options (below). Set, a listener starts with the application, registered as `chappe_audio_listener`, and `chappe_audio:open/1` uses it. |
| `storage` | `#{backend => file, dir => "recordings"}` | The recording store (below). |

```erlang
%% sys.config
[{chappe_audio, [
    {listener, #{ip => {0, 0, 0, 0}, port => 8090, url => <<"ws://10.0.0.5:8090">>}},
    {storage, #{backend => file, dir => "/var/lib/chappe/recordings", retention_days => 30}}
]}].
```

## Listener options

`chappe_audio:listen/1`, or the `listener` env.

| Key | Default | What it does |
|---|---|---|
| `port` | `0` | TCP port; 0 picks one (`listener_info/1` says which). |
| `ip` | `{127, 0, 0, 1}` | Address to bind. |
| `url` | `ws://ip:port` | Base of the URLs streams hand out: how FreeSWITCH reaches the node. |
| `prefix` | `<<"/audio">>` | Path the streams live under. |
| `tls` | unset | `ssl` server options; the listener then speaks wss. |
| `max_pending` | `64` | Handshakes going at once; past it a new connection is closed at once. |
| `max_pending_per_ip` | `8` | Handshakes going at once from one address; past it that address's new connection is closed at once. Connected streams do not count. |
| `handshake_timeout` | `5000` | Milliseconds for the upgrade request. |
| `max_handshake` | `8192` | Bytes for the upgrade request. |
| `max_frame` | `262144` | Bytes for one message; past it the connection closes with 1009 and the stream ends with `{closed, too_large}`. |
| `idle_timeout` | `infinity` | Milliseconds without a message before the connection closes with 1001 and the stream ends with `{closed, idle}` (a paused fork sends nothing). |
| `subprotocols` | `[<<"audio.drachtio.org">>]` | Subprotocols the listener accepts (mod_audio_fork offers this one). |

## Stream options

`chappe_audio:open/1,2`.

| Key | Default | What it does |
|---|---|---|
| `owner` | the caller | Gets the events. |
| `ref` | unset | The call's opaque binary: in every event, the pg group, and the store. |
| `format` | `#{rate => 8000, channels => 1}` | What the fork sends. |
| `max_queue` | `500` | Events waiting at the owner past which a frame is dropped. |
| `max_queue_bytes` | `8388608` | Bytes of frames waiting at the owner past which one is dropped (with large frames this binds before `max_queue`). |
| `connect_timeout` | `30000` | Milliseconds to wait for the fork. |
| `store` | `none` | `default` writes the stream to the recording store. |

## RTP receiver options

`chappe_audio:rtp_receiver/1`, one receiver per recorded RTP stream (the
SIPREC recording server starts them).

| Key | Default | What it does |
|---|---|---|
| `owner` | required | The process the receiver lives for; it stops when the owner exits. |
| `ip` | required | Address the socket binds. |
| `label` | required | Its name in logs. |
| `sink` | required | `{store, Module, Meta}` writes a recording; `{pid, Pid}` sends `{Tag, Receiver, {audio, Pcm}}`. |
| `max_queue` | `500` | Messages waiting at a `{pid, Pid}` sink past which a frame is dropped. |
| `remote` | `undefined` | The sender's address from its SDP; the receiver latches to the first source at that address (any port). `undefined` latches to the first source. |
| `srtp` | `undefined` | A `chappe_audio_srtp` context of the sender's key: the stream takes SRTP only. |
| `ports` | `undefined` (any) | `{Min, Max}`: the range the socket binds a free port of; none free is `{error, no_port}`. |
| `tag` | `chappe_audio_rtp` | The first element of the sink's messages. |
| `rtcp` | `none` | `none`: no RTCP, as before. `mux`: RTCP on the RTP port (`a=rtcp-mux`, RFC 5761). `port`: an even RTP port and RTCP on the next one. With `mux` or `port` the receiver reads the source's RTCP and sends a receiver report about every 5 s. |
| `rtcp_remote` | `undefined` | With `rtcp => port`: where to send reports when the offer's `a=rtcp` names a port other than RTP + 1, until RTCP arrives from the source. |
| `cname` | random | The CNAME in its reports (RFC 7022). Give the streams of one recording the same one to tie them together. |
| `srtcp_out` | `undefined` | On an SRTP stream, a `chappe_audio_srtp` context of the receiver's own key, the one its SDP answer's `a=crypto` gives: it protects the reports as SRTCP. Without it an SRTP stream sends no report. |

```erlang
{ok, R} = chappe_audio:rtp_receiver(#{
    owner => self(), ip => {10, 0, 0, 5}, label => <<"1">>,
    sink => {pid, self()}, remote => {{10, 0, 0, 9}, 4000},
    rtcp => mux
}),
Port = chappe_audio_rtp:port(R),          %% the m= port
RtcpPort = chappe_audio_rtp:rtcp_port(R). %% the same with mux, Port + 1 with port
```

Where the receiver departs from RFC 3550 (each is a `deviation` row of
the [compliance matrix](compliance.md)):

- The interval is the 5 s minimum (2.5 s before the first report) times
  0.5 to 1.5. There is no timer reconsideration, no reverse
  reconsideration on BYE, and no e - 3/2 division (A.7), since the
  session has two members.
- The session bandwidth is fixed at 80 kbit/s; the SDP `b=` lines are not
  read.
- Sources are not timed out (6.3.5): a report carries only the sources
  heard since the last one, and a BYE drops its source at once (6.2.1).
- On an SSRC collision the receiver takes a new SSRC without a BYE for
  the old one (8.2).
- It never sends media, so it sends RR, never SR.

With `rtcp => port`, a source sending from port 65535 has no port above
it: the receiver sends it no report until `rtcp_remote` or the source's
own RTCP gives an address. A report that cannot be sent is dropped; the
receiver keeps recording.

`chappe_audio_rtp:stats/1` then also gives `rtcp_sent`, `rtcp_received`
and `sources`, one map per source: `ssrc`, `cname`, `received`, `lost`,
`highest`, `jitter`. With a new key on a re-INVITE,
`chappe_audio_rtp:rekey/3` takes the sender's key and the receiver's own.

One timing is fixed:

| What | Value | What it does |
|---|---|---|
| Move grace | 1 s | After `chappe_audio_rtp:remote/2` (the sender moved), packets from the source latched before are dropped for this long. Past it, with no new source latched, that source may latch again when its address is the new remote address (any port), so a sender whose SDP port alone changed is heard again. |

## Storage options

`storage` env, or `chappe_audio_store:configure/1` (per node).

| Key | Default | What it does |
|---|---|---|
| `backend` | `file` | `file`, or a module implementing `chappe_audio_store`. |
| `dir` | `"recordings"` | The file backend's folder. |
| `retention_days` | unset | Day folders older than this are deleted by the sweep. |
| `sweep_interval` | `3600000` | Milliseconds between sweeps. |
| `sweep_guard` | unset (always) | A fun of no argument, or `{M, F, A}`, returning whether this node sweeps now; anything but `true`, or a failure, skips the sweep. For a store the nodes share, back it with a chappe_cluster singleton ([Record a call](guides/record.md#sweep-a-shared-store-from-one-node)). |

Related: chappe_mrf's `shared_dir` env maps the folder FreeSWITCH records
into to this node's view of it ([Record a call](guides/record.md)).
