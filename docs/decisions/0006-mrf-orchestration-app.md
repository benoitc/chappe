# 0006: chappe_mrf is an orchestration app

This record explains why code that needs SIP and FreeSWITCH at once lives in
its own app, chappe_mrf, on top of chappe_sip and chappe_esl, and not inside
either of them. Read it before you add a feature that spans the SIP stack
and a media server, or before you start a new app that depends on
chappe_sip.

## Status

Accepted (the maintainer's decision, 2026-11-17). The rule is also in
`AGENTS.md`, "Conventions".

## Context

What the repository shows:

- `AGENTS.md`: "An orchestration app (chappe_mrf) may depend on chappe_sip
  and on the leaf apps. Nothing in the umbrella depends on it, and the leaf
  apps never depend on chappe_sip or on an orchestration app."
- `apps/chappe_mrf/src/chappe_mrf.app.src` lists `chappe_sip` and
  `chappe_esl` in `applications`; no other app lists `chappe_mrf`.
- No module under `apps/chappe_sip/src/` references chappe_esl, and no
  module outside `apps/chappe_mrf/` references chappe_mrf.
- chappe_mrf is the controller of a media resource function, with
  FreeSWITCH, rtpengine and chappe_mix as processors (moduledoc of
  `apps/chappe_mrf/src/chappe_mrf.erl`), modelled on drachtio-fsmrf
  (`apps/chappe_mrf/docs/drachtio-mapping.md`).

## Decision

chappe_mrf sits above chappe_sip and chappe_esl. It reaches SIP through the
public `chappe_sip` API (`create_b2bua/4`, `relay_async/2`, `replace_b/3`,
`use/2`) and FreeSWITCH through `chappe_esl`. Nothing depends on it.

## Consequences

- chappe_sip stays free of FreeSWITCH and ESL concepts, and a product that
  needs no media server does not load chappe_mrf.
- chappe_mrf can only do what the public chappe_sip API allows. A missing
  hook is added to chappe_sip as a general feature, not as an mrf special
  case. The CHANGELOG entry that ships chappe_mrf also ships
  `relay_async/2` as a B2BUA feature ("a call can run in a process of its
  own, so the process that set it up can drive a media server meanwhile").
- chappe_mrf installs an INVITE middleware for its loopback conference
  INVITEs (`chappe_mrf:install/0`), so it shares the request pipeline with
  the application.
- A future app with the same shape (SIP plus another engine) follows the
  same rule.

## Open questions

None.
