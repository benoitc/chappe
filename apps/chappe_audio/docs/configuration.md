# Configuration

This page lists what you can set in chappe_audio: two application
environment keys, the listener options and the stream options. Read it when
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
| `connect_timeout` | `30000` | Milliseconds to wait for the fork. |
| `store` | `none` | `default` writes the stream to the recording store. |

## Storage options

`storage` env, or `chappe_audio_store:configure/1` (per node).

| Key | Default | What it does |
|---|---|---|
| `backend` | `file` | `file`, or a module implementing `chappe_audio_store`. |
| `dir` | `"recordings"` | The file backend's folder. |
| `retention_days` | unset | Day folders older than this are deleted by the sweep. |
| `sweep_interval` | `3600000` | Milliseconds between sweeps. |

Related: chappe_mrf's `shared_dir` env maps the folder FreeSWITCH records
into to this node's view of it ([Record a call](guides/record.md)).
