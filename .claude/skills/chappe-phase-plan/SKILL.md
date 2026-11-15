---
name: chappe-phase-plan
description: Template and checklist for planning one phase of chappe work in plan mode. Use when entering plan mode for a new chappe phase, milestone or feature chunk.
---

# Plan one chappe phase

Each phase of chappe work gets its own plan, written in plan mode and approved before any code. Later phases stay notes, not detailed plans. Use this skill to write that plan so nothing the project relies on is forgotten.

## Before writing

1. Explore the code the phase touches (read-only agents, at most three in parallel).
2. Collect the history that applies:
   - commits, branches and parked work to reuse (`git log`, removed code with `git show <sha>^:<path>`);
   - gap lists from the apps that drive the work (for example `chappe_switchboard/docs/chappe-gaps.md`);
   - design docs under `apps/*/docs/design/`.
3. Check facts against code, not docs: a feature in `features.md` with no module and no test counts as absent.

## Plan layout

```markdown
# <Phase name>

## Context
Why this phase, what prompted it, the outcome. The history it reuses
(commits, branches, removed code, gap numbers it closes). Facts from
exploration that shape the design, with file:line.

## Delivery and lanes
PRs (few, about three commits each), lanes that can run in parallel on
disjoint files, waves, and who reviews and verifies each PR.

## <PR or step sections>
Numbered steps: what to build, the API (signatures, message shapes),
files to touch, existing functions to reuse.

## Tests
Each new case listed; each runs first against the old code to fail.
Interop and e2e cases on real peers (FreeSWITCH, rtpengine, Kamailio,
SIPp, pjsua, JsSIP).

## Demo you can run by hand
`make demo` (or a target of its own), what to try, what you should see,
README walkthrough.

## After this phase
Notes only: the next phases, each with its own plan.

## Verification
`make check`, the interop targets, the demo, CI green before merge.
```

## Notes

- Name only the recommended approach; leave alternatives out.
- Docs are task-oriented, second person. CHANGELOG entries are short, plain English, no code.
- No em-dash, no "comprehensive", no trailers in commits or PRs.
- Product code and customer code from other repos never comes into chappe; record clean-room decisions where the product keeps its design log.
