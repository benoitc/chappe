# 0014: chappe_cluster and chappe_audio are optional siblings

This record explains how chappe_sip and chappe_mrf use chappe_cluster and
chappe_audio without a hard dependency on them, and why chappe_cluster is
started by its users instead of being listed in `applications`. Read it
before you build a release, or before you make another app depend on one
of the two.

## Status

Accepted. It records the code as merged.

## Context

What the repository shows:

- chappe_audio is in both `applications` and `optional_applications` of
  chappe_sip (`apps/chappe_sip/src/chappe_sip.app.src`): when it is on the
  node it starts before chappe_sip, and without it "the rest of chappe_sip
  runs as before" (the comment in `apps/chappe_sip/rebar.config`).
- chappe_cluster is in neither list. With the `cluster` setting
  `chappe_cluster`, `chappe_sip_app:start/2` starts it (`start_cluster/1`)
  before chappe_sip's top supervisor. The comment there gives the reason:
  "the application controller then stops it after chappe_sip, so
  prep_stop/1 still finds it and withdraws the registry sweep. It is not
  in `applications' (nor `optional_applications', which would start it in
  every mode)". With `cluster => none`, the default
  (`chappe_sip_config`), it stays unstarted.
- `chappe_sip_app:prep_stop/1` calls `chappe_sip_registry:leave_cluster/0`
  to hand the registry sweep to another node first.
- Before that, `chappe_sip_config:check_cluster/0` loads chappe_cluster and
  refuses the boot with `{cluster, {chappe_cluster_not_installed, _}}` when
  the release does not include it, "rather than left to fail on the first
  REGISTER".
- chappe_mrf does the same (`apps/chappe_mrf/src/chappe_mrf_app.erl`):
  `start/2` starts chappe_cluster before its supervisor when its `cluster`
  env is `chappe_cluster`, and `prep_stop/1` drains the rooms to a live
  node within `drain_ms` (5000) through `chappe_mrf_conf_move:drain/1`.
- The chappe_sip release lists `{chappe_cluster, load}` and `chappe_audio`
  (`relx` in `apps/chappe_sip/rebar.config`); the guides show the same
  load entry (`apps/chappe_sip/docs/guides/registrar.md`,
  `apps/chappe_mrf/docs/configuration.md`).
- chappe_mrf lists chappe_audio in its `applications`, not as optional
  (`apps/chappe_mrf/src/chappe_mrf.app.src`).

## Decision

- chappe_audio is an optional application of chappe_sip. A node that runs
  it records with SIPREC; a node without it refuses recording sessions
  ([0012](0012-siprec-srs.md)).
- chappe_cluster is started by the app that uses it, before that app's
  supervisor, and only when its `cluster` setting asks for it. So it stops
  after that app, and the app hands off what it owns in `prep_stop/1`
  while its cluster still runs.
- A release that runs a cluster includes chappe_cluster as
  `{chappe_cluster, load}`. Without it, a node set to
  `cluster => chappe_cluster` refuses to start.

## Consequences

- When you build a release with a cluster, add `{chappe_cluster, load}` to
  it. Do not list chappe_cluster in an app's `applications`, or it starts
  before that app in every mode and the stop order is lost.
- A single node with the defaults runs no chappe_cluster at all.
- An app that adds a cluster user follows the same pattern: start it in
  `start/2`, hand off in `prep_stop/1`.

## Open questions

- chappe_mrf requires chappe_audio, while chappe_sip only takes it when it
  is there. Whether chappe_mrf should take it as optional too is not
  recorded.
