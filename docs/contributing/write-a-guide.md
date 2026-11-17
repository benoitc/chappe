# Write or change a guide

User guides live with their app, because each app is published on its own,
and they are rendered by ex_doc next to the module reference. Their Erlang
snippets are checked against the real API by a test. Use this page when you
document a new feature, fix a guide, or add a design page.

## Before you start

- Two existing guides of the same app, to match their shape.
  [capture.md](../../apps/chappe_sip/docs/guides/capture.md) and
  [call-records.md](../../apps/chappe_sip/docs/guides/call-records.md) are
  short examples.
- [CONTRIBUTING.md](../../CONTRIBUTING.md) for the writing rules shared with
  commits and PRs.

## Where to look

| Kind | Where |
|---|---|
| Task guides (users) | `apps/<app>/docs/guides/*.md` |
| Design pages (contributors) | `apps/<app>/docs/design/*.md` |
| Capability tracker | `apps/<app>/docs/features.md` |
| App index | `apps/<app>/docs/README.md` (chappe_sip), else the app `README.md` |
| ex_doc wiring | `apps/<app>/rebar.config`: `extras`, `groups_for_extras` |
| Pages that span apps | `docs/` at the root (concepts, architecture, decisions, navigation, contributing) |
| The snippet check | `test/doc_snippets_tests.erl` |

## Style

- Second person, task first. The page opens with one paragraph: what it is
  and when you need it.
- Then: when to use it, how (code), short notes. Minimal prose between code
  blocks.
- Snippets in Erlang (` ```erlang `) or shell (` ```sh `). A fragment that is
  not valid Erlang on its own (a CT case with `...`, a `%% req:` line) goes in
  ` ```text `.
- No em-dash character, none of the words CONTRIBUTING.md bans, no hype.
- End with where it lives: the modules, the tests and the lab.

## Steps

1. Write the page in `docs/guides/<task>.md`, named for the task
   (`register-to-a-carrier.md`, not `regc.md`).
2. Add it to `extras` and to the "Guides" group of `groups_for_extras` in
   `apps/<app>/rebar.config`. Apps without an ex_doc config
   (chappe_mix, chappe_mrf today) skip this step.
3. Link it from the app index and from the matching line of
   `docs/features.md`.
4. Run the snippet check and render the docs:

   ```sh
   rebar3 eunit --module=doc_snippets_tests
   (cd apps/chappe_sip && rebar3 ex_doc)
   ```

## What doc_snippets_tests checks

- It scans every ` ```erlang ` block in `apps/*/docs/**/*.md`,
  `apps/*/README.md` and the root `README.md`.
- Each block must parse. `...` is accepted as an elision (`#{...}`, `[...]`,
  or a bare `...`).
- Every call to a `chappe_*` module must name a function that exists and is
  exported with that arity. Calls to other modules (`io`, `maps`, your own
  `my_call`) are not checked.
- The snippets are not run. A failure names the file, the line and the call.

It does not scan the root `docs/` tree or the `interop/` READMEs, but keep
their snippets real anyway: they will be scanned later.

## Tests to add or run

```sh
rebar3 eunit --module=doc_snippets_tests
```

## How to know it works

- `doc_snippets_tests` passes.
- The rendered page appears in the ex_doc sidebar under "Guides", and its
  links resolve.
- A reader can run the steps from a clean checkout, from the umbrella root.

## Notes

- When you rename or remove an exported function, the snippet check tells you
  which guides call it.
- Keep option lists in one place: the moduledoc or the guide, and link the
  other.

## Related

- [extend-public-api.md](extend-public-api.md)
- [add-app.md](add-app.md)
