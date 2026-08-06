# Testing

This guide covers running the test suites, including the end-to-end suites against a real rtpengine. You need it when contributing, or when validating the library against your own rtpengine build.

## Unit and integration tests

No rtpengine needed; the CT suites run against `chappe_rtpengine_fake_server`, a scriptable NG server double (UDP and TCP) that can drop, delay, duplicate and corrupt replies, and serves duplicate cookies from a reply cache like the real daemon:

```sh
make test          # eunit + ct
make test-static   # lint + xref + dialyzer + fmt-check
make check         # everything above plus compile
```

The seven gates (compile, eunit, ct, lint, xref, dialyzer, fmt -c) also run in CI (.github/workflows/ci.yml) and must pass before a change lands. The gated suites (`chappe_rtpengine_live_SUITE`, `chappe_rtpengine_e2e_SUITE`) skip when `RTPENGINE_HOST` is not set.

## End-to-end against a real rtpengine

One command, needs docker:

```sh
make interop
```

That runs `test/e2e.sh`, which brings up `interop/docker-compose.yml`: a transcoding-enabled rtpengine built from `interop/Dockerfile` (Ubuntu's rtpengine package, native arch, subscribe/playback/silence available), NG on UDP and TCP, a published media port range, media bound on the container interface but advertised as 127.0.0.1. The script discovers the address rtpengine can reach your machine at, runs `chappe_rtpengine_live_SUITE` and `chappe_rtpengine_e2e_SUITE`, and tears the stack down. See `interop/README.md` for running the stack by hand.

What the end-to-end suites prove:

- `chappe_rtpengine_live_SUITE`: ping, the offer/answer/query/delete cycle with SDP rewriting, media subscriptions, and NG over TCP against the real daemon.
- `chappe_rtpengine_e2e_SUITE`: SDES-SRTP negotiation (plain caller bridged to an SRTP callee: crypto attributes appear in the rewritten offer and not in the answer), DTLS-SRTP negotiation (fingerprint and setup role in the rewritten offer), an actual RTP packet relayed through rtpengine in both directions via a media session, and the interpreter primitives over one anchored call: a party's media forked to a receiver socket as transcoded PCMU (real RTP asserted at the receiver), a WAV blob injected into the other leg, and one direction blocked (relay stops) and unblocked (relay resumes).

## Against your own rtpengine

Point the suites at any reachable instance:

```sh
RTPENGINE_HOST=10.0.0.5 RTPENGINE_PORT=2223 \
    rebar3 ct --suite chappe_rtpengine_live_SUITE,chappe_rtpengine_e2e_SUITE
```

Optional environment:

- `RTPENGINE_TCP_PORT`: a `--listen-tcp-ng` port; enables the TCP transport case.
- `RTPENGINE_MEDIA_IP`: the address rtpengine can reach the test machine at; enables the media relay case. On a flat network this is just the machine's IP.

Notes:

- rtpengine builds without transcoding (including the default `drachtio/rtpengine` docker image) compile out publish/subscribe and playback; the media subscription case skips itself on such builds with an explanatory message.
- Use `--delete-delay=0` on test instances, otherwise deleted sessions hold their ports for 30 seconds and small port ranges run out.
