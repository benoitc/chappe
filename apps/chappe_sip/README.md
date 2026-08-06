# chappe_sip

A SIP application server for Erlang/OTP. It is a port of the drachtio
model to the BEAM: sofia-sip provides the SIP transaction layer through a
thin NIF, and everything above it (dialogs, UAC/UAS orchestration, B2BUA,
proxy, digest auth, middleware) is Erlang. You write SIP applications
against an srf-like API in your own Erlang code; there is no external
signaling daemon and no control protocol.

## What you get

- An embedded SIP engine (sofia-sip nta) started and supervised by your
  Erlang application.
- An application API modeled on drachtio-srf: request handlers by SIP
  method, `create_uas`, `create_uac`, `create_b2bua`, `proxy_request`,
  dialogs as processes with an events contract.
- One OTP app, one process image. A dialog is a process.

## Status

Working: UAS, UAC, B2BUA, forking proxy, in-dialog operations, and a
controlled engine restart. Start with `docs/README.md` for the guides;
`docs/features.md` is the feature list and `docs/plan.md` the milestone history.

## Requirements

- Erlang/OTP 29
- A C toolchain, autoconf, automake, libtool, pkg-config (to build the
  bundled sofia-sip and the NIF shim). On macOS: `brew install boost
  autoconf automake libtool pkg-config` (openssl@3 too if missing).

## Quickstart

```sh
git clone --recursive https://github.com/benoitc/chappe_sip.git
cd chappe_sip
rebar3 compile        # builds sofia-sip + the NIF on first run
rebar3 shell
```

Answer every INVITE, echoing the caller's SDP:

```erlang
ok = chappe_sip:start(#{contact => <<"sip:0.0.0.0:5060">>}),
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{local_sdp => chappe_sip_req:body(Req)}),
    chappe_sip_dialog:wait(Dlg)
end).
```

Bridge every INVITE to another endpoint (B2BUA):

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Legs} = chappe_sip:create_b2bua(Req, Res, <<"sip:bob@10.0.0.2">>, #{}),
    chappe_sip_b2b:relay(Legs)
end).
```

Fork a call to two destinations, first 2xx wins:

```erlang
ok = chappe_sip:invite(fun(Req, _Res) ->
    chappe_sip:proxy_request(Req, [<<"10.0.0.2">>, <<"10.0.0.3">>],
                       #{forking => parallel})
end).
```

More in `examples/chappe_sip_demo.erl` (echo UAS, B2BUA, registrar) and the
API surface in `docs/design/overview.md`.

## Building the engine

`rebar3 compile` runs `c_src/build.sh`, which builds sofia-sip as a static
library and links the NIF into `priv/lib/`. It is stamped, so later
compiles are instant. `SKIP_ENGINE_BUILD=1 rebar3 compile` skips the C
build entirely for pure-Erlang work (tests then use the fake engine).

For a production release:

```sh
rebar3 as prod release
```

Run the node under `heart` or `systemd Restart=always`: a crash in the C
engine takes the BEAM down by design (see `docs/design/engine.md`), and the
supervisor restarts the node.

## License

Copyright 2026 Benoit Chesneau. Apache-2.0; see `LICENSE` and `NOTICE`. The
bundled sofia-sip is LGPL-2.1; see `THIRD_PARTY_LICENSES.md`. The API design
follows drachtio-srf (MIT), used here as a design reference.
