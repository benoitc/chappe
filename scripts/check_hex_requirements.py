#!/usr/bin/env python3
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
"""Check that a built Hex tarball declares every dependency the app needs,
with the version constraint rebar.config gives it.

Usage: check_hex_requirements.py apps/<app>

rebar3_hex builds the package's "requirements" from rebar.lock, not from
rebar.config. A dependency resolved through _checkouts never enters the lock,
so it is silently dropped from the tarball: the package publishes with a
missing dependency, and a consumer only finds out at runtime with an undef.
Publishing is irreversible, so check before, not after.

Run `rebar3 hex build` in the app directory first (this script does not build).
"""
import glob
import os
import re
import sys
import tarfile
import tempfile


def rebar_config_constraints(app_dir):
    """Top-level {deps, [...]} of rebar.config: app name to its version
    constraint (None for a bare name or a non-Hex source). Profiles are
    ignored: only the default profile lands in the package."""
    path = os.path.join(app_dir, "rebar.config")
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"^\s*%.*$", "", text, flags=re.M)
    m = re.search(r"^\{deps,\s*\[(.*?)\]\}\s*\.", text, re.S | re.M)
    if not m:
        return {}
    return dict(top_level_deps(m.group(1)))


def rebar_config_deps(app_dir):
    """The app names of the default-profile deps of rebar.config."""
    return set(rebar_config_constraints(app_dir))


def top_level_deps(body):
    """(name, constraint) for each entry of a deps list: a bare atom, or a
    tuple at the list's own level whose second element may be the version
    string, so {ws, "~> 0.5.0", {pkg, erlang_ws}} gives ("ws", "~> 0.5.0"),
    not pkg."""
    deps, depth, cur, pos = [], 0, None, 0
    for tok in re.findall(r'"[^"]*"|[{}\[\],]|[a-z_][a-z_0-9]*', body):
        if tok in "{[":
            depth += 1
            if tok == "{" and depth == 1:
                cur, pos = [None, None], 0
            continue
        if tok in "}]":
            depth -= 1
            if depth == 0 and cur is not None:
                deps.append(tuple(cur))
                cur = None
            continue
        if tok == ",":
            if depth == 1 and cur is not None:
                pos += 1
            continue
        if depth == 0:
            deps.append((tok, None))
        elif depth == 1 and cur is not None:
            if pos == 0:
                cur[0] = tok
            elif pos == 1 and tok.startswith('"'):
                cur[1] = tok.strip('"')
    return deps


def tarball_requirements(app_dir, app):
    """The tarball and its requirements: app name to requirement string."""
    pattern = os.path.join(app_dir, "_build", "**", f"{app}-*.tar")
    tars = [t for t in glob.glob(pattern, recursive=True) if "-docs" not in t]
    if not tars:
        sys.exit(f"{app}: no tarball; run `rebar3 hex build` in {app_dir} first")
    tar = max(tars, key=os.path.getmtime)
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(tar) as tf:
            tf.extract("metadata.config", tmp, filter="data")
        meta = open(os.path.join(tmp, "metadata.config"), encoding="utf-8").read()
    m = re.search(r'\{<<"requirements">>,\s*\[(.*?)\]\}\.', meta, re.S)
    if not m:
        return tar, {}
    # A dep is a package name whose value opens with the "app" key, and its
    # app is what rebar.config names (erlang_ws is the package of app ws).
    # Matching bare binaries would also pick up the inner keys.
    reqs = {}
    for one in re.finditer(
            r'\{<<"[a-z_][a-z_0-9]*">>,\s*\[\{<<"app">>,\s*<<"([a-z_][a-z_0-9]*)">>'
            r'(.*?)\]\}', m.group(1), re.S):
        r = re.search(r'\{<<"requirement">>,\s*<<"([^"]*)">>\}', one.group(2))
        reqs[one.group(1)] = r.group(1) if r else None
    return tar, reqs


def norm(constraint):
    """A constraint without spaces or a leading ==: "0.14.1" is "== 0.14.1"."""
    c = re.sub(r"\s+", "", constraint or "")
    return c[2:] if c.startswith("==") else c


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    app_dir = sys.argv[1].rstrip("/")
    app = os.path.basename(app_dir)

    declared = rebar_config_constraints(app_dir)
    tar, shipped = tarball_requirements(app_dir, app)
    missing = sorted(set(declared) - set(shipped))
    differ = sorted(
        f"{n}: rebar.config {declared[n]!r}, package {shipped[n]!r}"
        for n in set(declared) & set(shipped)
        if declared[n] is not None and norm(declared[n]) != norm(shipped[n]))

    print(f"{app}")
    print(f"  tarball:      {tar}")
    print(f"  rebar.config: {sorted(declared.items()) or '-'}")
    print(f"  requirements: {sorted(shipped.items()) or '-'}")

    if missing:
        print(f"\n  MISSING from the package: {missing}")
        if os.path.isdir(os.path.join(app_dir, "_checkouts")):
            print("  _checkouts/ is present. Deps resolved there never reach")
            print("  rebar.lock, so they are dropped. Remove it, publish the")
            print("  siblings first, then rebuild.")
    if differ:
        print("\n  CONSTRAINT differs from rebar.config:")
        for d in differ:
            print(f"    {d}")
    if missing or differ:
        sys.exit(1)

    print("\n  OK: every rebar.config dep is declared in the package, with its constraint")


if __name__ == "__main__":
    main()
