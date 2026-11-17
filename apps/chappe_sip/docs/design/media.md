# Media integration (chappe_sip_media)

`chappe_sip_media` is the media control plane of chappe_sip: the one place
where a SIP call meets the engines that carry its RTP. This page explains
where that boundary sits, why it lives in chappe_sip, and how a request for a
capability reaches an engine. Read it before you change the facade or add a
backend. To use it, read the [media guide](../guides/media.md).

## The boundary

```
 SIP processes (dialogs, b2b relay, your handler)
        |  chappe_sip_media: session/2, offer/2, conference/3, ...
        v
 chappe_sip_media  --capability-->  backend adapter
        |                             |
 chappe_sip_media_rtpengine     chappe_sip_media_mix (+ _mix_sdp)
        |                             |
 chappe_rtpengine (NG client)   chappe_mix (rooms, legs)
        |                             |
     rtpengine daemon            UDP sockets in the VM
```

- The SIP processes never touch RTP. RTP flows through rtpengine and through
  the chappe_mix conference processes. The one receiver in chappe_sip is the
  SIPREC recording server's stream process (`chappe_audio_rtp`, in chappe_audio), the
  media's last stop: it decrypts SRTP itself (`chappe_audio_srtp`, receive
  only), and never relays or sends media
  ([decision 0009](../../../../docs/decisions/0009-srtp-in-erlang.md)).
- The engines are driven by SIP-free leaf apps: `chappe_rtpengine` speaks
  the rtpengine NG protocol, `chappe_mix` mixes RTP. See
  [chappe_rtpengine](../../../chappe_rtpengine/README.md) and
  [chappe_mix](../../../chappe_mix/README.md).
- FreeSWITCH (IVR, bridging, conferences on a media server) is driven by
  chappe_mrf, an orchestration app above chappe_sip, not by this facade. See
  [chappe_mrf](../../../chappe_mrf/README.md).

## Why this lives in chappe_sip

`chappe_sip_media` binds media to SIP: it reads dialog identity, writes the
SDP for the call, and ties a session's lifetime to the call process. That
coupling is why it belongs here rather than in a leaf app, which must stay
SIP-free.

## Capability routing

You ask for a capability, not an engine. Each capability has a default
backend:

| Capability | Backend | What you get |
|---|---|---|
| `anchor`, `relay` | rtpengine | anchor or relay the call's RTP and rewrite SDP (`offer`/`answer`) |
| `transcode` | rtpengine | codec transcoding (needs a transcoding-enabled rtpengine) |
| `subscribe` | rtpengine | fork a party's media to another consumer (a tap) |
| `duck` | rtpengine | block or silence a party while a prompt plays |
| `play`, `record`, `dtmf` | rtpengine | play a file, record, send DTMF |
| `conference` | chappe_mix | a mixer leg in a named room (`conference`/`leave`/`mute`/`unmute`) |

An operation the session's backend does not have returns
`{error, {unsupported, Op}}`. The default can be overridden per session
(`backend`) or globally (`capabilities` in the media config).

## Dormant by default

The media libraries are load-only in the release. Nothing in them starts
unless a `media` config is given, as the `chappe_sip:start/1` option or the
`media` application env (the option wins). `chappe_sip_media:configure/1`
then starts a configured backend's app on demand through
`chappe_sip_media_sup:ensure_app/1`; the conference room server
(`chappe_sip_media_mix`) is added under `chappe_sip_media_sup`, which sits
above the stack supervisor so media state survives an engine restart.

## Session lifetime

A session is bound to the process that created it (the call handler, the
b2b relay). When that process exits, the backend session is torn down: an
rtpengine session is deleted, a conference leg leaves its room. A room stops
when its last leg leaves or when its owner exits. A session is correlated by
SIP dialog identity (Call-ID and tags), mapped by role: the dialog's From tag
is the peer's on a UAS dialog and ours on a UAC dialog.

## Testing

`test/chappe_sip_media_SUITE` drives the rtpengine path against an in-suite
fake that speaks the NG wire protocol, and the conference path against real
chappe_mix rooms on loopback, with G.711 RTP sent and checked over UDP. Its
`rtpengine_live` group runs a conference leg behind a real rtpengine when
`RTPENGINE_HOST` and `RTPENGINE_MEDIA_IP` are set (the stack in
`apps/chappe_rtpengine/interop`). The B2BUA's use of the facade is covered by
`chappe_sip_b2b_relay_SUITE` with `chappe_sip_test_rtpe`.
