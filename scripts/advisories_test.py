#!/usr/bin/env python3
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
"""Unit tests of advisories.py: versions, ranges, and the fail-closed
cases. Run: python3 -I scripts/advisories_test.py (make advisories-test).
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import advisories as a  # noqa: E402


def quiet(fun, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = fun(*args)
    return rc, out.getvalue()


def adv(rng, ghsa="GHSA-test", key="vulnerable_version_range"):
    vuln = {"patched_versions": ">= 9"}
    if key:
        vuln[key] = rng
    return {"ghsa_id": ghsa, "state": "published", "vulnerabilities": [vuln]}


class Versions(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(a.version("1.13.17"), (1, 13, 17))
        self.assertEqual(a.version(" v1.13 "), (1, 13))

    def test_garbage_is_an_error(self):
        for bad in ["", None, "1.13.x", "latest", "1.13.17-rc1", "1..2"]:
            with self.assertRaises(ValueError, msg=bad):
                a.version(bad)

    def test_padding(self):
        self.assertEqual(a.compare((1, 13), (1, 13, 0)), 0)
        self.assertEqual(a.compare((1, 13, 1), (1, 13)), 1)
        self.assertEqual(a.compare((1, 9), (1, 13)), -1)


class Ranges(unittest.TestCase):
    V17, V18, V19 = (1, 13, 17), (1, 13, 18), (1, 13, 19)

    def test_operators(self):
        self.assertTrue(a.in_range(self.V17, "<= 1.13.17"))
        self.assertFalse(a.in_range(self.V18, "<= 1.13.17"))
        self.assertTrue(a.in_range(self.V17, "< 1.13.18"))
        self.assertTrue(a.in_range(self.V19, ">= 1.13.18"))
        self.assertTrue(a.in_range(self.V17, ">= 1.0, < 1.13.18"))
        self.assertFalse(a.in_range(self.V19, ">= 1.0, < 1.13.18"))

    def test_bare_and_padded(self):
        self.assertTrue(a.in_range((1, 13, 0), "1.13"))
        self.assertTrue(a.in_range((1, 13), "= 1.13.0"))
        self.assertFalse(a.in_range(self.V17, "1.13.13"))

    def test_hyphen_range(self):
        self.assertTrue(a.in_range(self.V17, "1.13.17 - 1.13.18"))
        self.assertTrue(a.in_range(self.V18, "1.13.17 - 1.13.18"))
        self.assertFalse(a.in_range(self.V19, "1.13.17 - 1.13.18"))

    def test_unparsable_is_an_error(self):
        for bad in ["", None, ",", "<= ", "~> 1.13", "1.13.x", "<= 1.13,"]:
            with self.assertRaises(ValueError, msg=bad):
                a.in_range(self.V17, bad)


class FailClosed(unittest.TestCase):
    V = (1, 13, 19)

    def test_missing_range_is_affected(self):
        self.assertTrue(a.affected(self.V, adv(None)))
        self.assertTrue(a.affected(self.V, adv(None, key=None)))
        self.assertTrue(a.affected(self.V, {"vulnerabilities": []}))

    def test_unparsable_range_is_affected(self):
        [(rng, why)] = a.affected(self.V, adv("~> 1.13"))
        self.assertEqual(rng, "~> 1.13")
        self.assertIn("not understood", why)

    def test_out_of_range_is_clean(self):
        self.assertEqual(a.affected(self.V, adv("<= 1.13.17")), [])

    def run_sofia(self, pin, advisories):
        with tempfile.TemporaryDirectory() as d:
            ac = os.path.join(d, "configure.ac")
            js = os.path.join(d, "adv.json")
            with open(ac, "w") as f:
                f.write("AC_INIT([sofia-sip], [%s])\n" % pin)
            with open(js, "w") as f:
                json.dump(advisories, f)
            return quiet(a.sofia, ac, js)

    def test_sofia_needs_an_advisory(self):
        rc, out = self.run_sofia("1.13.19", [])
        self.assertEqual(rc, 2, out)
        rc, out = self.run_sofia("1.13.19", [[]])
        self.assertEqual(rc, 2, out)

    def test_sofia_unparsable_range_fails(self):
        rc, out = self.run_sofia("1.13.19", [adv("<= 1.13.17"), adv("odd")])
        self.assertEqual(rc, 1, out)
        self.assertIn("AFFECTED", out)

    def test_sofia_pages_and_ranges(self):
        pages = [[adv("<= 1.13.17")], [adv("1.13.17 - 1.13.18")]]
        self.assertEqual(self.run_sofia("1.13.19", pages)[0], 0)
        self.assertEqual(self.run_sofia("1.13.18", pages)[0], 1)
        self.assertEqual(self.run_sofia("1.13.17", pages)[0], 1)

    def test_hex_result_count(self):
        pkgs = [("a", "a", "1.0"), ("b", "b", "1.0")]
        self.assertEqual(quiet(a.hex_report, pkgs, [{}])[0], 2)
        self.assertEqual(quiet(a.hex_report, pkgs, None)[0], 2)
        self.assertEqual(quiet(a.hex_report, pkgs, [{}, {}])[0], 0)
        self.assertEqual(
            quiet(a.hex_report, pkgs, [{}, {"vulns": [{"id": "X"}]}])[0], 1)


if __name__ == "__main__":
    unittest.main()
