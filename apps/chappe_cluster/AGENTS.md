# Agents

Instructions for AI coding agents working on this app.

## Overview

`chappe_cluster` gives a key one owner across a region, part of the `chappe`
platform umbrella. It is SIP-free. Facade module: `chappe_cluster`. Internal
module prefix: `chappe_cluster_*`. Why it works this way:
`docs/decisions/0010-cluster-ownership.md` at the umbrella root.

Layers: `chappe_cluster_config` (the env, validated at start),
`chappe_cluster_machine` (the Ra machine: liveness, leases, KV; pure, applied
directly by its tests), `chappe_cluster_tab` (the node's holders and liveness, a
table the supervisor owns), `chappe_cluster_lapse` (gives every lease up at
the local deadline), `chappe_cluster_node` (one per node: the Ra system and
member, renewals), `chappe_cluster_ra` (Ra calls bounded by one deadline),
`chappe_cluster_watch` (hands KV changes to
local watchers, found through the `chappe_cluster` pg scope),
`chappe_cluster_singleton_sup` and `chappe_cluster_singleton` (one contender
per singleton name), and `chappe_cluster_directory` (the cross-region seam)
with its `local` backend.

## Required Checks

Run from the umbrella root (`chappe/`), which owns the shared gate config:

```bash
rebar3 fmt        # erlfmt, 80 cols (run first)
rebar3 compile    # warnings_as_errors
rebar3 lint       # Elvis (config: ../../elvis.config)
rebar3 xref
rebar3 dialyzer
rebar3 eunit      # the machine, with PropEr properties
rebar3 ct         # chappe_cluster_SUITE (one node), chappe_cluster_peer_SUITE
```

## Conventions

- Keep this lib SIP-free. Its dependencies are `ra` and `hlc`.
- The machine has no clock: it never reads a time or the command
  metadata's `system_time`. Expiry is the leader's monotonic Ra timer;
  timestamps are HLC values carried in commands.
- Every new process follows the `chappe-erlang-patterns` skill, with its four
  tests (owner death, own crash, a `peer` node, a flood past the bound).
- OTP 29. No em-dash in code, docs or messages; never the word "comprehensive".
- No generated or co-authored commit trailers; one imperative subject line.
