# Configuration

This page lists every option chappe_mix takes, with its default. Read it
when you start a conference or add a leg and need to know what a key does.
chappe_mix has no application environment: everything is set per
conference (`chappe_mix:start/1`), per leg (`chappe_mix:add_leg/2`) or
per tap (`chappe_mix:tap/3`).

## Conference options

Passed to `chappe_mix:start/1`.

| Key | Default | What it does |
|---|---|---|
| `ip` | `{127, 0, 0, 1}` | Address legs bind to and report. Loopback, so nothing is exposed until you choose. |
| `owner` | the caller | The conference stops when this process exits. |
| `rate` | `8000` | The room's sample rate, for good: `8000` (G.711 legs) or `16000` (L16 legs, rtpengine with L16 in front: tested on 26.3.1.4, none in 11.5.1.18, upstream from 13.4.1.1). Anything else is `{error, {bad_option, rate}}`. |
| `law` | `ulaw` | Default codec of a leg in an 8 kHz room (`ulaw` is PCMU, `alaw` PCMA). A bad option at 16000. |
| `depth` | `3` | Jitter buffer depth, in 20 ms frames. |
| `events` | none | Process that gets `{chappe_mix, Conf, {talking, Leg, true \| false}}`. Unset, levels are not computed. |
| `talk_threshold` | `-40` | dBFS RMS over a frame that counts as talk. |
| `talk_start_ms` | `60` | Talk this long before `true`. |
| `talk_stop_ms` | `300` | Silence this long before `false`. |
| `tick_ceiling` | `true` | Arm the tick at the millisecond at or after it is due, so it never fires early. |
| `prefill_shrink` | `false` | Take back a grown jitter buffer prefill after 10 s without an underrun. Off: its A/B raised underruns. |
| `trace` | none | Process that gets `{chappe_mix_tick, Conf, #{due, start, done, legs}}` after every tick. For measurement. |
| `cname` | 96 random bits, base64 | RTCP CNAME the mixer uses on every leg (RFC 7022). |
| `ssrc_draw` | cryptographic random | Fun that draws a candidate SSRC. Set it in tests to script the draws. |

```erlang
{ok, Conf} = chappe_mix:start(#{
    ip => {10, 0, 0, 5},
    law => alaw,
    events => self(),
    talk_threshold => -35
}).
```

## Leg options

Passed to `chappe_mix:add_leg/2`.

| Key | Default | What it does |
|---|---|---|
| `remote` | learnt from the first packet | Where to send the mix. |
| `law` | the conference's | This leg's codec in an 8 kHz room. A bad option at 16000. |
| `pt` | `96` | The payload type of an L16 leg, both ways, as its SDP says. A bad option at 8000 (G.711 uses 0 and 8). |
| `rtcp` | `mux` | `mux`: RTCP on the RTP port (SDP with `a=rtcp-mux`). `pair`: even RTP port, RTCP on the next one. |
| `rtcp_remote` | the RTP port, or the one after | Where RTCP goes when the far end names it with `a=rtcp`. |
| `ptime` | `20` | What the far end sends, reported by `legs/1`. Packets of any size up to 200 ms are taken anyway. |
| `dtmf_pt` | none | RFC 4733 payload type. Unset, the leg takes and gets no events. The leg's audio payload type is `{error, {bad_option, dtmf_pt}}`. |
| `dtmf_events` | `0` to `15` | Event codes the leg is sent. |
| `direction` | `sendrecv` | `sendrecv`, `sendonly`, `recvonly` or `inactive`, seen from the room. |
| `mute` | `false` | On top of `direction`, as `mute/3` does. |
| `injected` | `false` | The leg is the room's own media (a prompt): listeners see the mixer's SSRC for it. |
| `name` | none | SDES NAME the other legs see for this leg's source. |

```erlang
{ok, Leg, #{ip := Ip, port := Port, rtcp_port := RtcpPort}} =
    chappe_mix:add_leg(Conf, #{rtcp => pair, dtmf_pt => 101, name => <<"bob">>}).
```

## Tap options

The options of `chappe_mix:tap/3`, which hands a party's or the room's
decoded audio to a process as `{chappe_mix, Conf, {tap, Tap, Pcm}}` every
20 ms.

| Key | Default | What it does |
| --- | --- | --- |
| `to` | the caller | Process that gets the frames. The tap ends when it dies. |
| `max_queue` | `500` | Messages waiting at `to` past which a frame is dropped and counted in `taps/1`. |
| `ref` | the leg's, else the room's | The ref `taps/1` shows for the tap. |

```erlang
{ok, Tap} = chappe_mix:tap(Conf, Leg, #{max_queue => 100}).
```

## From chappe_sip

When you use the mixer through `chappe_sip_media`, its settings go under
`media => #{mix => ...}` in `chappe_sip:start/1`: `ip`, `advertise`, `rate`, `law`
and `depth`. The join options (`persist`, `talk_events`, `talk_tag`, ...)
are those of `chappe_sip_media:conference/3`. See the chappe_sip
[media design](https://github.com/benoitc/chappe/blob/main/apps/chappe_sip/docs/design/media.md).

## Where it lives

- Defaults: `chappe_mix_conf:init/1`, `chappe_mix_leg:open/3`
- Types: `chappe_mix:conf_opts()`, `chappe_mix:leg_opts()`
