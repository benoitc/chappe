# Release the apps

A release of a chappe app is a version bump and a CHANGELOG section, merged
to `main`; you then publish the app to Hex by hand. CI turns every merge
that bumps at least one app into a dated bundle, the only thing chappe
tags. Read this page when you cut a release or publish an app.

## What a release is

- Each app under `apps/` has its own version (`vsn` in
  `apps/<app>/src/<app>.app.src`), its own `apps/<app>/CHANGELOG.md` and
  its own Hex package.
- An app is never tagged on its own, and has no GitHub release of its own.
- A merge to `main` that passes CI and changes at least one app's version
  is a bundle named `YYYY.MM.N`: the year and month of the merge (UTC), and
  N counting the bundles of that month from 0. CI tags it `vYYYY.MM.N` and
  creates its GitHub release, titled `chappe YYYY.MM.N`, whose notes list
  every app's version and the CHANGELOG section of each app whose version
  changed. A merge that bumps no app releases nothing.
- Never create a bundle tag or release by hand: the workflow counts the
  existing tags to name the next bundle.

## Cut a release

1. Bump `vsn` in `apps/<app>/src/<app>.app.src`. For chappe_sip, also bump
   the relx release version in `apps/chappe_sip/rebar.config`.
2. In `apps/<app>/CHANGELOG.md`, turn `## [Unreleased]` into the version
   and the date, and open a new empty Unreleased section above it:

   ```markdown
   ## [Unreleased]

   ## [0.3.0] - 2026-11-24
   ```

   The heading must start with `## [<vsn>]`: `scripts/bundle_notes.sh`
   finds the section by it.
3. Bump the `~>` pin of the app in the `deps` of every app that depends on
   it (today chappe_mrf depends on chappe_sip, chappe_esl and
   chappe_audio):

   ```erlang
   {deps, [
       {chappe_sip, "~> 0.3.0"},
       {chappe_esl, "~> 0.2.0"},
       {chappe_audio, "~> 0.1.0"}
   ]}.
   ```

4. Check the notes the bundle will carry, against `main`:

   ```sh
   scripts/bundle_notes.sh origin/main HEAD
   ```

5. Open the pull request. Its `Release` dry run builds the same notes and
   uploads them as the `notes` artifact.
6. Merge it. CI tags the bundle and creates the release.

## What CI does

- `.github/workflows/ci.yml`, job `package`: for each app, the docs and the
  Hex package as `rebar3 hex publish` builds them
  (`scripts/check_package.sh <app>`). It checks that the package declares
  every dep of `rebar.config`, that it fits the Hex limits (8 MB
  compressed, 64 MB uncompressed), and, for chappe_sip, that the NIF builds
  from the unpacked package with no git. An app whose sibling's new version
  is not on Hex yet gets a warning instead.
- `.github/workflows/release.yml`, after CI passes on `main`: job `plan`
  names the bundle, or stops when the commit is already tagged or no
  version changed; job `release` tags it and creates the GitHub release.

## Publish to Hex

Publish only the apps whose version is not on Hex yet
(`curl -s https://hex.pm/api/packages/<app>` shows the latest), leaves
first, since a package is published only once every sibling it depends on
is on Hex:

| # | App | Needs |
|---|---|---|
| 1 | chappe_audio | |
| 2 | chappe_esl | |
| 3 | chappe_rtpengine | |
| 4 | chappe_mix | |
| 5 | chappe_cluster | |
| 6 | chappe_sip | (chappe_rtpengine, chappe_mix, chappe_cluster, chappe_audio: optional) |
| 7 | chappe_mrf | chappe_sip, chappe_esl, chappe_audio |

For each app, from a clean tree on the merged commit:

```sh
scripts/check_package.sh chappe_esl
cd apps/chappe_esl
rm -rf _checkouts rebar.lock
rebar3 compile
rebar3 hex build
python3 ../../scripts/check_hex_requirements.py .
rebar3 hex publish
```

Run `scripts/check_package.sh` again for an app once its siblings are on
Hex: before, it only warns.

## Notes

- Publishing is irreversible: Hex refuses to overwrite a version. Bump
  `vsn` first.
- Siblings are default-profile deps. rebar3_hex reads a package's
  requirements from the default lock, so a dep in a `hex` (or any other)
  profile is dropped from the tarball and the user gets an `undef` at
  runtime.
- Remove `apps/<app>/_checkouts` and a stale `apps/<app>/rebar.lock`
  before you publish: a dep resolved through either never reaches the
  package's requirements. `scripts/check_package.sh` refuses to run with a
  `_checkouts`.
- An optional sibling (one chappe_sip starts on demand) is not a dep: a
  node that uses it adds it to its own deps.
- Hex rejects git deps: keep every dep of a published app on Hex.
- `rebar3_hex` is pinned to 7.2.0: 7.3.0 with hex_core 0.19.0 crashes on
  publish (a `badmatch` on `cli_auth_callbacks`). Check
  `ls _build/default/plugins` after a build and keep the pin until a fixed
  release is out.
- The `files` list in each `.app.src` is what ships. Keep it current when
  you add a directory the build needs; chappe_sip ships `c_src` without
  its fuzz harness or build output.
- Sort bundles with a version-aware sort (`git tag --sort=v:refname`):
  past ten bundles in a month, `2026.11.10` sorts before `2026.11.9` by
  name.
