# Changelog

All notable changes to chappe_cluster, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

## [0.1.0] - 2026-11-23

### New

- Needs Erlang/OTP 29.1.2 or later: earlier OTP 29 releases let a TLS 1.3
  server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).
- A new app that lets chappe nodes agree on one owner for anything that
  must not run twice (a room, a registration, a trunk pinger), share a small
  key-value store, and run a job on exactly one node. With most nodes
  unreachable nothing new is claimed, calls already up are never touched,
  and node clocks need not agree.
