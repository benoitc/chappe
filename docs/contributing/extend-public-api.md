# Extend the public API

Each app has one facade module named after it (`chappe_sip`,
`chappe_rtpengine`, `chappe_esl`, `chappe_mix`, `chappe_mrf`), plus a few
public modules users call directly (`chappe_sip_b2b`, `chappe_sip_media`,
`chappe_sip_dialog`, `chappe_mrf_conf`, ...). Use this page when you add a
function or an option users will call, so the change arrives with its spec,
its documentation, its tests and its changelog line.

## Before you start

- [navigation.md](../navigation.md): which modules are public and which are
  internal.
- The facade you extend, read top to bottom: the option comments above each
  function are the reference users read.

## Where to look

| Piece | Where |
|---|---|
| Facades | `apps/chappe_sip/src/api/chappe_sip.erl`, `apps/chappe_rtpengine/src/chappe_rtpengine.erl`, `apps/chappe_esl/src/chappe_esl.erl`, `apps/chappe_mix/src/chappe_mix.erl`, `apps/chappe_mrf/src/chappe_mrf.erl` |
| ex_doc module groups | `groups_for_modules` in `apps/<app>/rebar.config` |
| Defaults of app settings | `apps/chappe_sip/src/chappe_sip_config.erl` (`default/1`) for chappe_sip |
| Guides | `apps/<app>/docs/guides/` |
| Capability tracker | `apps/<app>/docs/features.md` |
| Changelog | `apps/<app>/CHANGELOG.md`, under `## [Unreleased]` |

## Steps

1. Put the function in the module that owns the concept, and export it from
   the facade only if users reach the concept through the facade today (as
   `chappe_sip:register_client/2` does for `chappe_sip_regc`).
2. Give it a `-spec`. Take options as a map, return `ok`, `{ok, _}` or
   `{error, _}`, and document every option key, its default and its type in
   the comment above the function, as `chappe_sip:start/1` does.
3. A new option on an existing function must default to today's behaviour.
4. A new setting read from the app env gets a `default/1` clause in
   `chappe_sip_config` (or the app's equivalent), never a default scattered at
   call sites.
5. Write the CT case first, on the old code, through the public function, not
   the internal one.
6. Document it: a section in the guide of that task, or a new guide
   ([write-a-guide.md](write-a-guide.md)), with a snippet that calls the new
   function. Add the line to `docs/features.md`.
7. A new public module goes into the right group of `groups_for_modules`.
8. If the function makes a protocol promise, claim the row
   ([compliance.md](compliance.md)).
9. Add your line to the app's CHANGELOG, or hand the text to whoever merges: short, plain
   English, what is new and what it means for the user, no code and no
   internal names.

## Tests to add or run

```sh
rebar3 xref
rebar3 dialyzer
rebar3 eunit --module=doc_snippets_tests
make check
```

## How to know it works

- `xref` and `dialyzer` are clean: no call to an unexported function, no spec
  mismatch.
- `doc_snippets_tests` passes with your new snippet in it.
- The function shows in the ex_doc module page with its spec
  (`rebar3 ex_doc` in the app directory).

## Notes

- There is no written deprecation policy yet. Do not remove or change the
  meaning of an exported function in passing: add the new form, keep the old
  one, and say in the PR description what breaks if it is ever removed.
- Leaf apps stay SIP-free: a SIP-aware option belongs in chappe_sip or
  chappe_mrf, not in chappe_rtpengine, chappe_mix or chappe_esl.
- An internal module that core code calls back into the facade for creates a
  cycle; put shared helpers in the module that owns the concept instead.

## Related

- [write-a-guide.md](write-a-guide.md)
- [add-sip-feature.md](add-sip-feature.md)
- [compliance.md](compliance.md)
