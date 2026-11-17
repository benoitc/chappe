# Add tests

Every app has fast tests that need nothing but the VM (eunit, and CT suites
over loopback sockets and in-process fakes) and gated lab suites that need
docker. Use this page to pick the right kind of test, the fake that stands in
for the external system, and the conventions the suites share.

## Before you start

- [labs.md](labs.md): the gated suites and their variables.
- The app's testing guide where one exists:
  [chappe_esl testing](../../apps/chappe_esl/docs/guides/testing.md),
  [chappe_rtpengine testing](../../apps/chappe_rtpengine/docs/guides/testing.md),
  [chappe_sip interop testing](../../apps/chappe_sip/docs/guides/interop-testing.md).

## Where to look

| App | eunit (`*_tests.erl`) | CT (`*_SUITE.erl`) | Fakes and helpers |
|---|---|---|---|
| chappe_sip | message model, headers, URIs, SDP, digest, compliance tool | one suite per area, real sockets on loopback | `chappe_sip_engine_fake` (engine without the NIF), `chappe_sip_test_rtpe` (rtpengine NG over UDP), `chappe_sip_test_ua` and `chappe_sip_raw_peer` (scripted SIP peers), `chappe_sip_test_port` (ports), `chappe_sip_ws_test_client` |
| chappe_rtpengine | bencode, NG, SDP, streams | client, pool, session, dtmf; live, e2e, siprec gated | `chappe_rtpengine_fake_server` (UDP, TCP, WS, WSS; scriptable replies) |
| chappe_esl | parser, events | conn, call, outbound, nodes; live gated | `chappe_esl_fake_server` (inbound and outbound event socket) |
| chappe_mix | G.711, DSP, jitter buffer, RTP, RTCP | `chappe_mix_SUITE`, `rfc`; live and ref gated | `chappe_mix_test_peer` (raw RTP), `chappe_mix_test_tone`, `chappe_mix_probe` |
| chappe_mrf | lib | `chappe_mrf_SUITE`; live gated | `chappe_mrf_fake` (FreeSWITCH SIP and ESL, rtpengine, a UDP caller) |

## Steps

1. Pick the level. Pure functions: eunit. A process, a protocol exchange or a
   timer: a CT case with a fake. A behaviour of the real daemon: a lab case.
2. Write the case first and run it on the code before your change. It must
   fail, for the reason you expect.

   ```sh
   rebar3 ct --suite apps/chappe_sip/test/chappe_sip_uas_SUITE --case my_case
   rebar3 eunit --module=chappe_sip_hdr_tests
   ```

3. Fix the code, rerun the case, then the whole suite.
4. If the case proves a requirement, put its ids on a `%% req:` line directly
   above the case function ([compliance.md](compliance.md)). Only
   `*_SUITE.erl` cases count.
5. To run chappe_sip without the NIF, point the engine at the fake, as
   `chappe_sip_pipeline_SUITE` does:

   ```erlang
   application:set_env(chappe_sip, engine_mod, chappe_sip_engine_fake,
                       [{persistent, true}]).
   ```

   Then drive it with `chappe_sip_engine_fake:inject_request/2` and read the
   answer with `chappe_sip_engine_fake:await_response/1`.

## Conventions

- One suite per area, named for what it exercises
  (`chappe_sip_<area>_SUITE`). Add to an existing suite before creating one.
- Take ports from `chappe_sip_test_port:pick/0`, never from a random range: a
  random port in the ephemeral range clashes on CI.
- Wait on a message or a monitor with a timeout, never `timer:sleep/1`
  followed by an assertion.
- Clean up in `end_per_testcase/2`, so a failed case does not break the next.
- A gated suite returns `{skip, Why}` from `all/0` or `init_per_suite/1`
  without its variable, so `rebar3 ct` stays green with no docker.
- `make ct` drops the copied test dirs first: a deleted suite does not linger.

## Tests to add or run

```sh
make check
make cover MIN_COVERAGE=80
```

## How to know it works

- The new case failed before the change and passes after it.
- `make cover` stays above the floor in `.github/workflows/ci.yml`.

## Notes

- A flaky failure: rerun the suite alone, check the load average, and look for
  a fixed port, a sleep, or a shared registered name before calling it a
  regression.
- A fake reproduces what the tests need, not the whole protocol. When a case
  depends on a behaviour the fake does not have, extend the fake in its own
  module and say what real behaviour it models in its header comment.
- `doc_snippets_tests` (in the umbrella `test/`) checks the code blocks in
  the docs: see [write-a-guide.md](write-a-guide.md).

## Related

- [labs.md](labs.md)
- [add-interop-lab.md](add-interop-lab.md)
- [compliance.md](compliance.md)
