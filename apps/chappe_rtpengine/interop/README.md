# Interop harness

This directory brings up a real rtpengine in docker for the gated live and
e2e suites. You need it when you want to prove the library against the
actual daemon rather than the in-process fake: SDP rewriting, SRTP and DTLS
negotiation, media relay, subscriptions, playback, and media blocking.

## Run everything with one command

```sh
make interop
```

That runs `test/e2e.sh`, which builds the image, starts the compose stack,
discovers the address rtpengine can reach your machine at, runs
`chappe_rtpengine_live_SUITE`, `chappe_rtpengine_e2e_SUITE` and
`chappe_rtpengine_siprec_SUITE`, and tears the stack down.

## Run the stack by hand

```sh
docker compose -f interop/docker-compose.yml up -d --build
RTPENGINE_HOST=127.0.0.1 RTPENGINE_PORT=12222 RTPENGINE_TCP_PORT=12223 \
    RTPENGINE_HTTP_PORT=12224 RTPENGINE_HTTPS_PORT=12225 \
    rebar3 ct --suite chappe_rtpengine_live_SUITE,chappe_rtpengine_e2e_SUITE,chappe_rtpengine_siprec_SUITE
docker compose -f interop/docker-compose.yml down
```

Set `RTPENGINE_MEDIA_IP` to the address rtpengine can send media back to
(the media relay, fork and interpreter cases skip without it):

```sh
docker exec rtpe-e2e getent hosts host.docker.internal
```

`host.docker.internal` comes free with Docker Desktop; on plain Linux the
compose file maps it to `host-gateway` so the same lookup works there.

## Notes

- The image comes from Ubuntu's rtpengine package (see Dockerfile), which
  carries transcoding support. Minimal builds compile out
  publish/subscribe, playback and silence, and those cases skip with an
  explanatory message.
- `--delete-delay=0` matters: without it deleted sessions hold their ports
  for 30 seconds and the published port range runs out mid-suite. The range
  is 30000-30100: a three-stream recording fork alone takes 24 ports (the
  anchor plus one subscription per stream, RTP and RTCP each).
- The stack exposes all four NG listeners: UDP 12222, TCP 12223, HTTP
  12224 (`--listen-http`, WebSocket) and HTTPS 12225 (`--listen-https`,
  TLS WebSocket with a throwaway self-signed certificate generated at
  container start).
- The suites are opt-in: without `RTPENGINE_HOST` they return
  `{skip, ...}`, so `rebar3 ct` stays green with no docker at all. CI runs
  them in a separate `interop` job, gated on the build like `ct` is.
- A blob for `play media` rides inside the NG datagram, so a real-size
  clip needs the TCP or WebSocket transport rather than UDP; the suites
  keep UDP blobs under one MTU and prove the large-clip path over
  WebSocket instead.
