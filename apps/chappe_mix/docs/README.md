# chappe_mix documentation

This is the map of the chappe_mix pages. Start with the app
[README](../README.md) for what the mixer is and when to use it.

## Use it

- [Run a conference](guides/conference.md): standalone, behind rtpengine,
  from a SIP call
- [Configuration](configuration.md): conference and leg options, defaults

## Understand it

- [Design overview](design/overview.md): process model, clock, N-1 mix,
  jitter buffer, RTCP, sockets
- [Features](features.md): what works today and what is planned

## Evidence and compliance

- [Performance record](https://github.com/benoitc/chappe/blob/main/apps/chappe_mix/test/audit/PERF.md): thresholds and measurements
- [Attempts](https://github.com/benoitc/chappe/blob/main/apps/chappe_mix/test/audit/ATTEMPTS.md): what was tried, kept or reverted
- [Bench arms](https://github.com/benoitc/chappe/blob/main/apps/chappe_mix/bench/README.md)
- [Compliance matrix](compliance.md), generated from
  `compliance/requirements.tsv`; how to claim a row is in
  [the shared compliance page](https://github.com/benoitc/chappe/blob/main/docs/contributing/compliance.md)
