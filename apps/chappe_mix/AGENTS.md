# Agents

Instructions for AI coding agents working on this app.

## Overview

`chappe_mix` is an RTP audio conference mixer, part of the `chappe` platform
umbrella. It is SIP-free: it takes RTP on UDP sockets it owns, mixes each
listener's audio from every other participant, and sends the result back. It
never touches a dialog or an SDP body. SRTP, DTLS and codec transcoding stay in
rtpengine in front of it, so the mixer only handles G.711. Facade module:
`chappe_mix`. Internal module prefix: `chappe_mix_*`.

## Required Checks

Run from the umbrella root (`chappe/`), which owns the shared gate config:

```bash
rebar3 fmt        # erlfmt, 80 cols (run first)
rebar3 compile    # warnings_as_errors
rebar3 lint       # Elvis (config: ../../elvis.config)
rebar3 xref
rebar3 dialyzer
rebar3 eunit
rebar3 ct
```

## Measure before you claim

- `test/audit/PERF.md` is what every performance claim cites. It holds the
  thresholds, set before the code existed. Update it in the same commit as the
  change it describes, and record a missed threshold as missed.
- `test/audit/ATTEMPTS.md` is what was tried and reverted. Read it before
  proposing an optimisation.
- The reference is FreeSWITCH `mod_conference`, driven with the same input.
  Interleave runs, take the minimum of five, and check the load average first.

**A test that cannot fail is worse than no test.** Run every new case before
the code it covers exists and watch it fail, then mutate the code and watch it
fail again. Record the mutations in `ATTEMPTS.md` and the commit body.

## Conventions

- Keep this lib SIP-free.
- Nothing a peer sends becomes an atom.
- Run `rebar3 fmt`; elvis must pass (per-module ignores live in the umbrella
  `elvis.config` with a one-line reason).
- OTP 29. No em-dash in code, docs or messages; never the word "comprehensive".
- No generated or co-authored commit trailers; one imperative subject line.
