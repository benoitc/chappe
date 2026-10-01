# chappe

An opensource SIP/media platform for Erlang/OTP. `chappe` is an umbrella of
composable apps you build voice services on: a SIP stack, an rtpengine control
client, an RTP conference mixer, and a FreeSWITCH Event Socket client.

Named after Claude Chappe, who built the first practical telecommunications
network (the optical semaphore telegraph, 1794).

## Apps

- **chappe_sip** - the SIP application server: UAS/UAC/B2BUA/proxy/registrar over
  sofia-sip's `nta` transaction layer via a plain-C NIF, SIP-over-WebSocket, TLS,
  and a media control-plane facade (`chappe_sip_media`). Public API module: `chappe_sip`.
- **chappe_rtpengine** - a client for the rtpengine NG control protocol (media
  relay/anchoring, subscribe/duck). SIP-free.
- **chappe_mix** - an RTP audio conference mixer (G.711, RFC 3550 mixer
  behaviour). The `conference` backend of `chappe_sip_media`. SIP-free.
- **chappe_esl** - a standalone FreeSWITCH Event Socket (ESL) client for
  products that drive FreeSWITCH directly. chappe_sip does not use it. SIP-free.

Products are built on top of chappe as separate applications (an SBC, an AI
voice product, a PBX); they depend on these packages, they are not part of this
repo.

## Build

Requires Erlang/OTP 29 and rebar3. `chappe_sip` builds a vendored sofia-sip (no
submodule, no network needed).

```
make            # compile (builds sofia + the NIF on first run)
make test       # eunit + ct
make test-static  # lint + xref + dialyzer + fmt-check
make check      # everything
make asan       # the C NIF under AddressSanitizer (Linux container)
make cover      # eunit + ct line coverage (MIN_COVERAGE=N to gate)
make compliance # per-app RFC requirement matrices (GATE=demo to gate)
```

## Layout

```
apps/chappe_sip/         # SIP stack + media facade; c_src (vendored sofia)
apps/chappe_rtpengine/   # rtpengine NG client
apps/chappe_mix/         # RTP conference mixer
apps/chappe_esl/         # FreeSWITCH ESL client (standalone)
```

Inside the umbrella the apps reference each other by name. Each app is published
to hex independently.

## License

Apache-2.0 (see LICENSE). Bundles sofia-sip under LGPL-2.1 (see NOTICE).
