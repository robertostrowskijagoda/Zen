#!/usr/bin/env python3
"""Tests of coverage_report.py, on small made-up lcov files.

  python3 tool/ci/test_coverage_report.py      (from the repository root)

Standard library only.
"""

import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tool", "ci"))

import coverage_report  # noqa: E402


class CoverageReportTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        os.makedirs(os.path.join(self.root, "lib", "src", "dev"))
        for name in ("lib/a.dart", "lib/b.dart", "lib/never.dart",
                     "lib/src/dev/sim.dart"):
            with open(os.path.join(self.root, name), "w") as f:
                f.write("// x\n")
        runs = os.path.join(self.root, "coverage")
        os.makedirs(runs)
        with open(os.path.join(runs, "lcov-1.info"), "w") as f:
            # A Windows runner's path.
            f.write(r"SF:C:\work\lib\a.dart" "\nDA:1,1\nDA:2,0\nend_of_record\n"
                    "SF:lib/src/dev/sim.dart\nDA:1,0\nend_of_record\n")
        with open(os.path.join(runs, "lcov-2.info"), "w") as f:
            f.write("SF:lib/a.dart\nDA:2,3\nend_of_record\n"
                    "SF:lib/b.dart\nDA:1,0\nDA:2,0\nend_of_record\n")
        self.runs = runs

    def test_runs_add_up_and_untouched_files_are_named(self):
        result = coverage_report.report([self.runs], self.root)
        self.assertEqual(result["runs"], 2)
        # a.dart both lines (one in each run), b.dart none; dev/ left out.
        self.assertEqual(result["lines"], 4)
        self.assertEqual(result["hit"], 2)
        self.assertAlmostEqual(result["percent"], 50.0)
        self.assertEqual(result["untouched"], ["lib/never.dart"])
        self.assertIn("50.0%", coverage_report.markdown(result))

    def test_a_minimum_fails_below_it(self):
        self.assertEqual(
            coverage_report.main([self.runs, "--root", self.root, "--min", "40"]), 0)
        self.assertEqual(
            coverage_report.main([self.runs, "--root", self.root, "--min", "60"]), 1)


if __name__ == "__main__":
    unittest.main()
