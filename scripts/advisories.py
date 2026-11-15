#!/usr/bin/env python3
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
"""Check chappe's third-party code against published advisories.

Usage:
  advisories.py sofia CONFIGURE_AC ADVISORIES_JSON
      fail when the sofia-sip version in CONFIGURE_AC (AC_INIT) is in the
      vulnerable range of an advisory in ADVISORIES_JSON, the output of
      `gh api [--paginate --slurp] repos/freeswitch/sofia-sip/security-advisories`
  advisories.py hex REBAR_LOCK [ACCEPTED]
      fail when a hex package locked in REBAR_LOCK has an osv.dev advisory
      (ecosystem Hex); osv-scanner does not read rebar.lock. ACCEPTED lists
      advisories looked at and accepted, one `ID PACKAGE VERSION # reason`
      per line: an entry covers that locked version only, so a new advisory
      or another version fails again.

Exit status: 0 clean, 1 affected, 2 bad input or network error.
"""

import json
import re
import sys
import urllib.request

OSV_BATCH = "https://api.osv.dev/v1/querybatch"


def version(text):
    """A dotted version as a tuple of ints (1.13.17 -> (1, 13, 17))."""
    parts = re.findall(r"\d+", text)
    if not parts:
        raise ValueError("no version in %r" % text)
    return tuple(int(p) for p in parts)


def in_range(v, expr):
    """True when v satisfies every comma-separated clause of expr:
    `<= 1.13.17`, `>= 1.0, < 1.13.18`, or a bare `1.13.13` (equal)."""
    ops = {
        "<=": lambda a, b: a <= b,
        ">=": lambda a, b: a >= b,
        "<": lambda a, b: a < b,
        ">": lambda a, b: a > b,
        "=": lambda a, b: a == b,
    }
    clauses = [c.strip() for c in expr.split(",") if c.strip()]
    if not clauses:
        return False
    for clause in clauses:
        m = re.match(r"^(<=|>=|<|>|=)?\s*(.+)$", clause)
        op, ver = m.group(1) or "=", m.group(2)
        if not ops[op](v, version(ver)):
            return False
    return True


def sofia(configure_ac, advisories_json):
    with open(configure_ac) as f:
        m = re.search(r"AC_INIT\(\[sofia-sip\],\s*\[([^\]]+)\]", f.read())
    if not m:
        print("error: no AC_INIT([sofia-sip], ...) in %s" % configure_ac)
        return 2
    pin = m.group(1)
    v = version(pin)
    with open(advisories_json) as f:
        advisories = json.load(f)
    # `gh api --paginate --slurp` gives a list of pages
    if advisories and all(isinstance(a, list) for a in advisories):
        advisories = [a for page in advisories for a in page]
    hits = []
    for adv in advisories:
        if adv.get("state", "published") != "published":
            continue
        for vuln in adv.get("vulnerabilities") or []:
            rng = vuln.get("vulnerable_version_range") or ""
            if rng and in_range(v, rng):
                hits.append((adv, rng, vuln.get("patched_versions") or "?"))
    print("sofia-sip %s, %d advisories checked" % (pin, len(advisories)))
    for adv, rng, fixed in hits:
        print("AFFECTED %s %s (%s): vulnerable %s, patched %s: %s" % (
            adv.get("ghsa_id"), adv.get("cve_id") or "-",
            adv.get("severity") or "?", rng, fixed,
            adv.get("summary") or ""))
    if hits:
        return 1
    print("ok: no advisory covers sofia-sip %s" % pin)
    return 0


def locked_hex(rebar_lock):
    """[(app, hex package, version)] of the pkg entries of a rebar.lock."""
    with open(rebar_lock) as f:
        text = f.read()
    pat = r'\{<<"([^"]+)">>,\s*\{pkg,\s*<<"([^"]+)">>,\s*<<"([^"]+)">>'
    return re.findall(pat, text)


def accepted_list(path):
    """{(id, package, version)} of an accepted-advisories file."""
    out = set()
    if not path:
        return out
    with open(path) as f:
        for line in f:
            words = line.split("#", 1)[0].split()
            if len(words) == 3:
                out.add(tuple(words))
            elif words:
                raise ValueError("bad accepted line: %r" % line)
    return out


def hex_check(rebar_lock, accepted_path=None):
    accepted = accepted_list(accepted_path)
    pkgs = locked_hex(rebar_lock)
    if not pkgs:
        print("error: no hex package in %s" % rebar_lock)
        return 2
    body = json.dumps({"queries": [
        {"package": {"ecosystem": "Hex", "name": name}, "version": vsn}
        for _app, name, vsn in pkgs]}).encode()
    req = urllib.request.Request(
        OSV_BATCH, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            results = json.load(resp)["results"]
    except Exception as e:  # network or API error: not a clean result
        print("error: osv.dev query failed: %s" % e)
        return 2
    affected = 0
    for (app, name, vsn), res in zip(pkgs, results):
        ids = [v["id"] for v in res.get("vulns") or []]
        known = [i for i in ids if (i, name, vsn) in accepted]
        ids = [i for i in ids if i not in known]
        if known:
            print("accepted %s %s (app %s): %s" % (
                name, vsn, app, " ".join(known)))
        if ids:
            affected += 1
            print("AFFECTED %s %s (app %s): %s" % (
                name, vsn, app, " ".join(ids)))
    print("%d hex packages checked against osv.dev" % len(pkgs))
    if affected:
        return 1
    print("ok: no osv.dev advisory for the locked hex packages")
    return 0


def main(argv):
    if len(argv) == 4 and argv[1] == "sofia":
        return sofia(argv[2], argv[3])
    if len(argv) in (3, 4) and argv[1] == "hex":
        return hex_check(argv[2], argv[3] if len(argv) == 4 else None)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
