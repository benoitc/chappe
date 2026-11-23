# Changelog

All notable changes to chappe_cluster, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### New

- A new app that lets chappe nodes agree on one owner for anything that
  must not run twice (a room, a registration, a trunk pinger), share a small
  key-value store, and run a job on exactly one node. With most nodes
  unreachable nothing new is claimed, calls already up are never touched,
  and node clocks need not agree.
