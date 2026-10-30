# chappe_mix

`chappe_mix` is an RTP audio conference mixer written in Erlang. Each
conference is one process that owns a UDP socket per participant (a leg),
mixes every 20 ms, and sends each leg the sum of the others, never its own
voice. You need it when your service runs conference rooms, whispers,
listen-only supervisors or prompt players next to SIP calls, and you want
the room to live in your Erlang node instead of on a media server.

It speaks G.711 (PCMU and PCMA) over plain RTP/AVP only. SRTP, DTLS, ICE and
every other codec stay in rtpengine, which you put in front of the mixer.
It knows nothing about SIP or SDP.

## When to use it rather than a FreeSWITCH conference

| You want | Use |
|---|---|
| Rooms in your own node, controlled per pair of legs (`relate/4`), talker events, no media server to run | chappe_mix |
| Low latency and density: see the measured numbers in [`test/audit/PERF.md`](test/audit/PERF.md) | chappe_mix |
| Recording, playback, TTS or PIN prompts inside the room, mod_conference features | a FreeSWITCH room (`chappe_mrf`, backend `fs`) |
| Wideband (G.722, Opus mixed at 16 kHz) | not yet: see [features](docs/features.md) |

`chappe_mrf` drives both kinds of room behind one API (backend `native` is
chappe_mix, backend `fs` is FreeSWITCH).

## How you reach it

- **From a SIP service (most common).** Configure `media => #{mix => ...}`
  in `chappe_sip:start/1` and join calls with
  `chappe_sip_media:conference/3`. chappe_sip builds the leg's SDP and puts
  rtpengine in front when the call needs it. See
  [Run a conference](docs/guides/conference.md).
- **Standalone.** Call the `chappe_mix` module yourself: start a
  conference, add a leg, put its address in your own SDP.

```erlang
{ok, _} = application:ensure_all_started(chappe_mix),
{ok, Conf} = chappe_mix:start(#{ip => {10, 0, 0, 5}}),
{ok, Leg, #{ip := Ip, port := Port}} = chappe_mix:add_leg(Conf, #{}),
%% advertise Ip and Port to the far end; its address is learnt from
%% the first packet, or set it with chappe_mix:set_remote/3
ok = chappe_mix:remove_leg(Conf, Leg),
ok = chappe_mix:stop(Conf).
```

The public module is `chappe_mix`. Every other `chappe_mix_*` module is
internal.

## Documentation

- [Documentation index](docs/README.md)
- [Run a conference](docs/guides/conference.md)
- [Configuration](docs/configuration.md)
- [Design overview](docs/design/overview.md): the clock, the mix, the
  jitter buffer, RTCP, sockets
- [Features](docs/features.md)
- Evidence: [`test/audit/PERF.md`](test/audit/PERF.md) (measurements
  against thresholds) and [`test/audit/ATTEMPTS.md`](test/audit/ATTEMPTS.md)
  (what was tried and kept or reverted)

Render the guides and the API reference with `rebar3 ex_doc` from this
directory.

## Tests

From the umbrella root:

```sh
rebar3 ct --dir apps/chappe_mix/test   # rooms on loopback, RFC 3550 rules
make interop-mix                       # behind a real rtpengine (docker)
make interop-ref                       # against FreeSWITCH mod_conference
```

The bench arms are in [`bench/`](bench/README.md).

## License

Apache-2.0
