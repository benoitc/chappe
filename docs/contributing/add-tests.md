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
| chappe_sip | message model, headers, URIs, SDP, digest, dispatch, flows | one suite per area, real sockets on loopback; `*_cluster_SUITE` on `peer` nodes | `chappe_sip_engine_fake` (engine without the NIF), `chappe_sip_test_rtpe` (rtpengine NG over UDP), `chappe_sip_test_ua` and `chappe_sip_raw_peer` (scripted SIP peers), `chappe_sip_test_port` (ports), `chappe_sip_ws_test_client`, `chappe_sip_test_store` (a recording store), `chappe_sip_location_lagging` (a lagging location store), `chappe_sip_test_dist`, `chappe_sip_test_cluster` |
| chappe_rtpengine | bencode, NG, SDP, streams | client, pool, session, dtmf; live, e2e, siprec gated | `chappe_rtpengine_fake_server` (UDP, TCP, WS, WSS; scriptable replies) |
| chappe_esl | parser, events | conn, call, outbound, nodes; live gated | `chappe_esl_fake_server` (inbound and outbound event socket) |
| chappe_mix | G.711, DSP, jitter buffer, RTP, RTCP | `chappe_mix_SUITE`, `rfc`, `tap`; live and ref gated | `chappe_mix_test_peer` (raw RTP), `chappe_mix_test_tone`, `chappe_mix_probe`, `chappe_mix_test_dist` |
| chappe_audio | PCM, WAV, SRTP, HTTP | `chappe_audio_SUITE`, `pg`, `rtp`, `store`; live gated | `chappe_audio_test_ws` (a fork module's client), `chappe_audio_test_srtp` (an SRTP sender), `chappe_audio_test_dist` |
| chappe_cluster | the Ra machine (PropEr), the lab checker and schedule | `chappe_cluster_SUITE`, `peer` | `chappe_cluster_test_dist` (`peer` nodes running chappe_cluster); the chaos lab's code in `test/lab` |
| chappe_mrf | lib, store | `chappe_mrf_SUITE`, `conf_backend`, `cluster`; live gated | `chappe_mrf_fake` (FreeSWITCH SIP and ESL, rtpengine, a UDP caller), `chappe_mrf_conf_fake_backend` (a conference backend), `chappe_mrf_test_cluster` |
| umbrella `test/` | `doc_snippets_tests`, `chappe_sip_compliance_tests` | none | none |

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
   above the case or EUnit test function ([compliance.md](compliance.md)).
   Claims in `*_SUITE.erl` and `*_tests.erl` both count, keyed
   `Module:Function`.
5. To run chappe_sip without the NIF, point the engine at the fake, as
   `chappe_sip_pipeline_SUITE` does:

   ```erlang
   application:set_env(chappe_sip, engine_mod, chappe_sip_engine_fake,
                       [{persistent, true}]).
   ```

   Then drive it with `chappe_sip_engine_fake:inject_request/2` and read the
   answer with `chappe_sip_engine_fake:await_response/1`.

## Several nodes

Use a `peer` node when the behaviour crosses nodes: a lookup through `pg`,
a lease, a singleton, a room or a binding owned on another node, a pid
used as a handle from elsewhere. Every new long-lived process needs four
tests (the distributable rule in `AGENTS.md`):

- owner death: kill the owner and assert the cleanup (peer told, leg hung
  up, nothing left registered or in `pg`);
- its own crash: kill the process and assert the call goes on and the
  owner hears it;
- from another node: a `peer` node calls the API, gets the events and
  finds the process through `pg`;
- the bound: flood it past its bound and assert the documented behaviour,
  with flat memory.

Steps:

1. Turn distribution on in `init_per_suite/1`. `chappe_sip_test_dist:ensure/0`
   (and the same in chappe_audio, chappe_mix and chappe_cluster) starts epmd
   and names the CT node. `chappe_sip_test_cluster:ensure/0` and
   `chappe_mrf_test_cluster:ensure/0` do it on `@localhost`.
2. Start the peers in `init_per_testcase/2` with
   `chappe_sip_test_cluster:peer/1` (or `chappe_mrf_test_cluster:peer/1`,
   `chappe_cluster_test_dist:peer/1`). Each peer gets this node's code
   path; the chappe_sip helper also gives it this node's engine backend.
3. For a cluster, start chappe_cluster on each peer with short leases and
   wait for it to take leases:

   ```erlang
   Peers = [chappe_sip_test_cluster:peer("pc" ++ integer_to_list(I))
            || I <- [1, 2, 3]],
   Nodes = [N || {_, N} <- Peers],
   [ok = chappe_sip_test_cluster:start_cluster(N, Nodes, Dir) || N <- Nodes],
   [ok = chappe_sip_test_cluster:wait_live(N) || N <- Nodes].
   ```

4. Drive the peers with `erpc:call/4`. Stop them in
   `end_per_testcase/2` with `chappe_sip_test_cluster:stop_peer/1`, so a
   failed case leaves no node behind.

Copy a real suite: `chappe_sip_peers_cluster_SUITE` (a singleton trunk
pinger on three nodes) or `chappe_mrf_cluster_SUITE` (rooms across a
region, an owner node that dies or shuts down).

## The umbrella tests

The umbrella's own `test/` directory holds `doc_snippets_tests` (the code
blocks of the docs) and `chappe_sip_compliance_tests` (the compliance
generator in `scripts/compliance/`). The `test` profile of the root
`rebar.config` adds both directories with `extra_src_dirs`, so
`rebar3 eunit` runs them with every app's tests:

```sh
rebar3 eunit --module doc_snippets_tests
```

chappe_cluster adds its `test/lab` code the same way, with
`{recursive, true}` in its own `rebar.config`.

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
- Races seen on CI, and their fixes:
  - wait on a condition with a deadline (poll a status, a monitor, a
    message), never on a fixed sleep;
  - when frames can arrive out of order, use a selective receive on the
    one you wait for and leave the others in the mailbox (#47, in
    `chappe_sip_webrtc_gateway_SUITE`);
  - in the code, count an event before the side effect a test observes:
    the ESL listener counts a refused peer before it closes the socket, so
    a peer that sees the close also sees the count (#44).
- A fake reproduces what the tests need, not the whole protocol. When a case
  depends on a behaviour the fake does not have, extend the fake in its own
  module and say what real behaviour it models in its header comment.
- `doc_snippets_tests` (in the umbrella `test/`) checks the code blocks in
  the docs: see [write-a-guide.md](write-a-guide.md).

## Related

- [labs.md](labs.md)
- [add-interop-lab.md](add-interop-lab.md)
- [compliance.md](compliance.md)
