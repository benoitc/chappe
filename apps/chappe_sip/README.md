# chappe_sip

chappe_sip is the SIP core of the chappe umbrella: a SIP application server
you embed in an Erlang release. sofia-sip's transaction layer runs inside the
VM behind a thin C NIF, and everything above it (dialogs, UAS and UAC, the
B2BUA, the proxy, the registrar, digest, middleware, events) is Erlang that
your code calls directly. There is no separate signalling daemon and no
control protocol. Media stays outside: chappe_sip drives rtpengine and
chappe_mix through its media facade, and chappe_mrf builds on it to drive
FreeSWITCH. How the apps fit together is in the
[umbrella documentation](https://github.com/benoitc/chappe/blob/main/docs/README.md) and the vocabulary in
[concepts](https://github.com/benoitc/chappe/blob/main/docs/concepts.md).

On several nodes, the `cluster => chappe_cluster` setting shares the
registrar's location store and lets one node ping a peer for all of them.
In that mode chappe_sip starts chappe_cluster as it starts, before its own
processes, so chappe_cluster stops after it; include it in your release as
`{chappe_cluster, load}`. With the default, `none`, nothing of it runs
([configuration](docs/configuration.md)).

## Public modules

| Module | Use it to |
|---|---|
| `chappe_sip` | start the stack, register handlers and middleware, answer, place, bridge and proxy calls, run a registrar, register to a carrier, manage peers, serve event packages |
| `chappe_sip_req`, `chappe_sip_res` | read an inbound request, answer it |
| `chappe_sip_dialog` | drive a dialog: re-INVITE, hold, BYE, in-dialog requests, NOTIFY |
| `chappe_sip_uac` | place a request and follow its responses |
| `chappe_sip_b2b` | relay, hang up, replace leg B, switch media on a bridged call |
| `chappe_sip_handler`, `chappe_sip_middleware`, `chappe_sip_guard` | structure a UAS, chain middleware, turn unwanted traffic away |
| `chappe_sip_media` | anchor, tap, duck, conference: media on rtpengine and chappe_mix |
| `chappe_sip_refer`, `chappe_sip_subscriber`, `chappe_sip_presence`, `chappe_sip_mwi`, `chappe_sip_focus` | transfer, events, presence, message waiting, conference state |
| `chappe_sip_cdr`, `chappe_sip_metrics` | call records, Prometheus metrics |
| `chappe_sip_msg`, `chappe_sip_hdr`, `chappe_sip_uri`, `chappe_sip_sdp`, `chappe_sip_digest` | parse and build SIP |

The full list, and which modules are internal, is in the
[design overview](docs/design/overview.md#public-and-internal-modules).

## Quickstart

You need Erlang/OTP 29.1.2 or later (earlier releases have TLS flaws (CVE-2026-89422, a TLS 1.3 server impersonation, and CVE-2026-105236, an SNI resumption bypass)), a C toolchain, autoconf, automake, libtool and
pkg-config (on macOS: `brew install boost autoconf automake libtool pkg-config`,
and `openssl@3` if missing). sofia-sip is vendored, so the build needs no
network for it.

1. Build from the umbrella root (the first compile builds sofia-sip and the
   NIF):

   ```sh
   git clone https://github.com/benoitc/chappe.git
   cd chappe
   rebar3 compile
   rebar3 shell
   ```

2. Start the stack and answer every INVITE, echoing the caller's SDP:

   ```erlang
   ok = chappe_sip:start(#{contact => <<"sip:0.0.0.0:5060">>}),
   ok = chappe_sip:invite(fun(Req, Res) ->
       {ok, Dlg} = chappe_sip:create_uas(Req, Res,
                                         #{local_sdp => chappe_sip_req:body(Req)}),
       chappe_sip_dialog:wait(Dlg)
   end).
   ```

3. Or bridge every INVITE to another endpoint (a B2BUA):

   ```erlang
   ok = chappe_sip:invite(fun(Req, Res) ->
       {ok, Legs} = chappe_sip:create_b2bua(Req, Res, <<"sip:bob@10.0.0.2">>, #{}),
       chappe_sip_b2b:relay(Legs)
   end).
   ```

`SKIP_ENGINE_BUILD=1 rebar3 compile` skips the C build for pure-Erlang work.
For a release, `rebar3 as prod release`, and run it under heart or systemd:
a crash in the C engine takes the node down by design (see
[deployment](docs/guides/deployment.md)). A runnable SBC built on chappe_sip
is in `demo/sbc` (`make demo` from the umbrella root).

## Documentation

- [Documentation index](docs/README.md): every guide and design page.
- [Getting started](docs/guides/getting-started.md).
- [Features](docs/features.md): what chappe_sip does today.
- [Design overview](docs/design/overview.md): supervision, layers, entry
  points, tests.
- [Concepts](https://github.com/benoitc/chappe/blob/main/docs/concepts.md): the words used across chappe.
- [CHANGELOG](https://github.com/benoitc/chappe/blob/main/apps/chappe_sip/CHANGELOG.md).

## License

Copyright 2026 Benoit Chesneau. Apache-2.0; see `LICENSE` and `NOTICE`. The
bundled sofia-sip is LGPL-2.1; see `THIRD_PARTY_LICENSES.md`. The API design
follows drachtio-srf (MIT), used here as a design reference.
