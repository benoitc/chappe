# Changelog

Each chappe app keeps its own changelog, next to its code, and is published
on Hex under its own version. This page tells you where each one is, how the
apps are released together, and what changed in the umbrella itself.

## Per-app changelogs

| App | Changelog |
|---|---|
| chappe_sip | [apps/chappe_sip/CHANGELOG.md](apps/chappe_sip/CHANGELOG.md) |
| chappe_rtpengine | [apps/chappe_rtpengine/CHANGELOG.md](apps/chappe_rtpengine/CHANGELOG.md) |
| chappe_esl | [apps/chappe_esl/CHANGELOG.md](apps/chappe_esl/CHANGELOG.md) |
| chappe_mix | [apps/chappe_mix/CHANGELOG.md](apps/chappe_mix/CHANGELOG.md) |
| chappe_audio | [apps/chappe_audio/CHANGELOG.md](apps/chappe_audio/CHANGELOG.md) |
| chappe_cluster | [apps/chappe_cluster/CHANGELOG.md](apps/chappe_cluster/CHANGELOG.md) |
| chappe_mrf | [apps/chappe_mrf/CHANGELOG.md](apps/chappe_mrf/CHANGELOG.md) |

## Bundles

A merge to `main` that bumps at least one app's version is released as a
bundle named `YYYY.MM.N` (tag `vYYYY.MM.N`, N counting the bundles of that
month from 0). Its GitHub release lists every app's version and the
changelog section of each app whose version changed. Apps are not tagged on
their own. See [Release the apps](docs/contributing/releasing.md).

## Umbrella and tooling

Changes to the repository that are not part of any app's package.

### Unreleased

#### Breaking

- Every app needs Erlang/OTP 29.1.2 or later: earlier OTP 29 releases let a
  TLS 1.3 server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).

#### New

- `make demo` runs a small SBC with a registrar, a WebRTC page and an IVR on
  2000; `make demo-cluster` runs three nodes sharing a registrar, a room
  and a trunk pinger.
- Interop labs against real rtpengine, FreeSWITCH and Kamailio run in CI
  and by hand (`make interop`, `interop-sbc`, `interop-esl`, `interop-mrf`).
- Each app has its own changelog, and a merge that bumps an app's version
  releases a dated bundle of all the apps.
- Each app's Hex package now carries its documentation for hexdocs.pm,
  and links from an app's docs to the rest of the repository point to
  GitHub, so they work there too.
- The labs run rtpengine 26.3, built from its upstream release, so they can
  carry 16 kHz audio; FreeSWITCH and pjsua are pinned to exact images, and
  the lab pjsua places Opus and G.722 calls.

### 0.1.0

The SIP/media platform, previously the separate `enki_sipserver`,
`enki_rtpengine` and `enki_esl` repositories, moved into one umbrella with
the `chappe_` prefix. sofia-sip is vendored, so the NIF builds from a clean
clone with no network. The app changelogs of chappe_sip, chappe_rtpengine
and chappe_esl carry the details.
