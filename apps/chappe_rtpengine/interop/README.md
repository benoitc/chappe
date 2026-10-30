# rtpengine lab

This directory brings up a real rtpengine in docker for the gated live and
e2e suites. Use it to prove chappe_rtpengine against the actual daemon rather
than the in-process fake: SDP rewriting, SRTP and DTLS negotiation, media
relay, subscriptions, playback and media blocking. The same stack serves the
mixer's live suite.

## What it proves

| Suite | Proves |
|---|---|
| `chappe_rtpengine_live_SUITE` | NG over UDP, TCP, WebSocket and secure WebSocket; ping, offer, answer, query, delete, a media subscription |
| `chappe_rtpengine_e2e_SUITE` | SDES and DTLS-SRTP negotiation, media relay through a session (UDP and WS), the interpreter primitives (play, block, silence), recording and DTMF, a playback blob larger than one MTU over WS |
| `chappe_rtpengine_siprec_SUITE` | recording forks (per-stream subscriptions) |
| `chappe_mix_live_SUITE` (`make interop-mix`) | the mixer behind rtpengine, legs transcoded to PCMU, N-1 checked by Goertzel |
| `chappe_sip_media_SUITE` group `rtpengine_live` | the chappe_sip media facade in front of a real daemon; no make target runs it, set `RTPENGINE_HOST` and `RTPENGINE_MEDIA_IP` against this stack |

## Services

One container, `rtpe-e2e`, built from `Dockerfile` (Ubuntu's rtpengine
package, which carries transcoding):

| Listener | Host port |
|---|---|
| NG over UDP | 12222/udp |
| NG over TCP | 12223/tcp |
| NG over WebSocket (`--listen-http`) | 12224/tcp |
| NG over TLS WebSocket (`--listen-https`, a throwaway self-signed certificate) | 12225/tcp |
| RTP | 30000-30100/udp |

Media binds on the container interface and is advertised as 127.0.0.1, so the
host reaches it through the published range.

## Run it

From the umbrella root:

```sh
make interop        # the three chappe_rtpengine suites
make interop-mix    # the mixer's live suite on the same stack
```

`make interop` runs `apps/chappe_rtpengine/test/e2e.sh`: it builds the image,
starts the stack, finds the address rtpengine can reach your machine at
(`RTPENGINE_MEDIA_IP`), runs the suites from `apps/chappe_rtpengine`, and tears
the stack down. Their logs are in `apps/chappe_rtpengine/_build/test/logs`.

Without `RTPENGINE_HOST` the suites return `{skip, ...}`, so `rebar3 ct` stays
green with no docker. Without `RTPENGINE_MEDIA_IP` the media relay, fork and
interpreter cases skip.

## Keep it up

The scripts always tear the stack down. Run it by hand, from
`apps/chappe_rtpengine`:

```sh
docker compose -f interop/docker-compose.yml up -d --build
export RTPENGINE_MEDIA_IP=$(docker exec rtpe-e2e getent hosts host.docker.internal | awk '{print $1}')
RTPENGINE_HOST=127.0.0.1 RTPENGINE_PORT=12222 RTPENGINE_TCP_PORT=12223 \
    RTPENGINE_HTTP_PORT=12224 RTPENGINE_HTTPS_PORT=12225 \
    rebar3 ct --suite chappe_rtpengine_live_SUITE,chappe_rtpengine_e2e_SUITE,chappe_rtpengine_siprec_SUITE
docker logs rtpe-e2e
docker compose -f interop/docker-compose.yml down
```

`host.docker.internal` comes with Docker Desktop; on plain Linux the compose
file maps it to `host-gateway`, so the same lookup works.

## Add a case

1. Write it first against `chappe_rtpengine_fake_server` in the non-gated
   suite of the area (`client`, `session`, `dtmf`, ...), if the fake can show
   it.
2. Add the live case to `chappe_rtpengine_live_SUITE` (control plane) or
   `chappe_rtpengine_e2e_SUITE` (media), reading the ports from the
   `RTPENGINE_*` variables.
3. A case that needs a daemon feature a minimal build lacks must skip with a
   message saying so, not fail.

## Troubleshooting

- The published range runs out mid-suite: `--delete-delay=0` must stay, or
  deleted sessions hold their ports for 30 seconds. A three-stream recording
  fork alone takes 24 ports.
- Publish/subscribe, playback or silence cases skip: the image is a minimal
  build. This Dockerfile's package has them.
- A large `play media` blob fails over UDP: it rides inside one NG datagram.
  Use TCP or WebSocket for a real-size clip; the suites keep UDP blobs under
  one MTU.
- Only one copy at a time: the container name and ports are fixed.

See also [docs/contributing/labs.md](../../../docs/contributing/labs.md).
