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


VERSION_RE = re.compile(r"^\s*v?(\d+(?:\.\d+)*)\s*$")
OPS = {
    "<=": lambda c: c <= 0,
    ">=": lambda c: c >= 0,
    "<": lambda c: c < 0,
    ">": lambda c: c > 0,
    "=": lambda c: c == 0,
    "==": lambda c: c == 0,
}


def version(text):
    """A dotted version as a tuple of ints (1.13.17 -> (1, 13, 17)).
    Anything else (a suffix, a word, nothing) is a ValueError."""
    m = VERSION_RE.match(text or "")
    if not m:
        raise ValueError("not a version: %r" % text)
    return tuple(int(p) for p in m.group(1).split("."))


def compare(a, b):
    """-1, 0 or 1, the shorter version padded with zeros: 1.13 == 1.13.0."""
    n = max(len(a), len(b))
    a = a + (0,) * (n - len(a))
    b = b + (0,) * (n - len(b))
    return (a > b) - (a < b)


def in_range(v, expr):
    """True when v satisfies every comma-separated clause of expr:
    `<= 1.13.17`, `>= 1.0, < 1.13.18`, `1.13.13` (equal) or
    `1.13.17 - 1.13.18` (both ends included). A range that does not parse
    is a ValueError: the caller counts it as affected."""
    clauses = [c.strip() for c in (expr or "").split(",")]
    if not clauses or any(c == "" for c in clauses):
        raise ValueError("not a range: %r" % expr)
    for clause in clauses:
        hyphen = re.match(r"^(\S+)\s+-\s+(\S+)$", clause)
        if hyphen:
            lo, hi = version(hyphen.group(1)), version(hyphen.group(2))
            if not (compare(v, lo) >= 0 and compare(v, hi) <= 0):
                return False
            continue
        m = re.match(r"^(<=|>=|==|<|>|=)?\s*(.+)$", clause)
        op = m.group(1) or "="
        if not OPS[op](compare(v, version(m.group(2)))):
            return False
    return True


def affected(v, advisory):
    """[(range, reason)] of the advisory's entries that cover v; an entry
    with no range, or one that does not parse, covers it (fail closed)."""
    vulns = advisory.get("vulnerabilities") or []
    if not vulns:
        return [("-", "no vulnerable range given")]
    hits = []
    for vuln in vulns:
        rng = vuln.get("vulnerable_version_range")
        if not rng:
            hits.append(("-", "no vulnerable range given"))
            continue
        try:
            if in_range(v, rng):
                hits.append((rng, "in range"))
        except ValueError as e:
            hits.append((rng, "range not understood (%s)" % e))
    return hits


def flatten(advisories):
    """The advisories of a `gh api` answer, slurped pages flattened."""
    if not isinstance(advisories, list):
        raise ValueError("advisories are not a list")
    if advisories and all(isinstance(a, list) for a in advisories):
        advisories = [a for page in advisories for a in page]
    return advisories


def sofia(configure_ac, advisories_json):
    with open(configure_ac) as f:
        m = re.search(r"AC_INIT\(\[sofia-sip\],\s*\[([^\]]+)\]", f.read())
    if not m:
        print("error: no AC_INIT([sofia-sip], ...) in %s" % configure_ac)
        return 2
    pin = m.group(1)
    try:
        v = version(pin)
        with open(advisories_json) as f:
            advisories = flatten(json.load(f))
    except ValueError as e:
        print("error: %s" % e)
        return 2
    published = [a for a in advisories
                 if a.get("state", "published") == "published"]
    # freeswitch/sofia-sip has published advisories (at least the three
    # fixed in 1.13.18): none means the query or its answer went wrong
    if not published:
        print("error: no published sofia-sip advisory in %s" % advisories_json)
        return 2
    print("sofia-sip %s, %d advisories checked" % (pin, len(published)))
    bad = 0
    for adv in published:
        for rng, why in affected(v, adv):
            bad += 1
            print("AFFECTED %s %s (%s): vulnerable %s, patched %s, %s: %s" % (
                adv.get("ghsa_id"), adv.get("cve_id") or "-",
                adv.get("severity") or "?", rng,
                patched(adv), why, adv.get("summary") or ""))
    if bad:
        return 1
    print("ok: no advisory covers sofia-sip %s" % pin)
    return 0


def patched(adv):
    return ", ".join(v.get("patched_versions") or "?"
                     for v in adv.get("vulnerabilities") or []) or "?"


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
    return hex_report(pkgs, results, accepted)


def hex_report(pkgs, results, accepted=frozenset()):
    """Print the osv.dev results of pkgs (one per package, in order) and
    return the exit status."""
    if not isinstance(results, list) or len(results) != len(pkgs):
        print("error: osv.dev answered %s results for %d packages" % (
            len(results) if isinstance(results, list) else "no",
            len(pkgs)))
        return 2
    flagged = 0
    for (app, name, vsn), res in zip(pkgs, results):
        ids = [v["id"] for v in res.get("vulns") or []]
        known = [i for i in ids if (i, name, vsn) in accepted]
        ids = [i for i in ids if i not in known]
        if known:
            print("accepted %s %s (app %s): %s" % (
                name, vsn, app, " ".join(known)))
        if ids:
            flagged += 1
            print("AFFECTED %s %s (app %s): %s" % (
                name, vsn, app, " ".join(ids)))
    print("%d hex packages checked against osv.dev" % len(pkgs))
    if flagged:
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
