#!/usr/bin/env python3
"""Tests of check_links.py, on small made-up Markdown files, and the
repository's own documentation.

  python3 tool/ci/test_check_links.py      (from the repository root)

Standard library only.
"""

import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tool", "ci"))

import check_links  # noqa: E402


class SlugTest(unittest.TestCase):
    def test_github_anchors(self):
        self.assertEqual(check_links.slug("Isn't it a virus? How to check"),
                         "isnt-it-a-virus-how-to-check")
        self.assertEqual(check_links.slug("Your own bridge (for advanced users)"),
                         "your-own-bridge-for-advanced-users")
        self.assertEqual(check_links.slug("3.1 The Go bridge — `build_if_changed`"),
                         "31-the-go-bridge--build_if_changed")
        self.assertEqual(check_links.slug("[Linked](x.md) **bold** heading"),
                         "linked-bold-heading")
        self.assertEqual(check_links.slug("Zażółć gęślą"), "zażółć-gęślą")

    def test_repeated_headings_are_numbered(self):
        found = check_links.anchors("# A\n## Notes\n## Notes\n## Notes\n")
        self.assertEqual(found, {"a", "notes", "notes-1", "notes-2"})

    def test_headings_inside_code_are_not_anchors(self):
        found = check_links.anchors("# Real\n```\n# not a heading\n```\n")
        self.assertEqual(found, {"real"})

    def test_html_ids_are_anchors(self):
        self.assertIn("top", check_links.anchors('<a id="top"></a>\n# Title\n'))


class CheckerTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        self.write("docs/guide.md", "# Guide\n\n## Getting started\n\ntext\n")
        self.write("docs/img/a.png", "")
        self.write("tool/run.sh", "")

    def write(self, path, text):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)
        return full

    def problems(self, text, name="README.md"):
        file = self.write(name, text)
        return check_links.Checker(self.root).problems([file])

    def test_good_links_pass(self):
        self.assertEqual(self.problems(
            "# Top\n"
            "[guide](docs/guide.md) [start](docs/guide.md#getting-started)\n"
            "![pic](docs/img/a.png) [folder](docs/) [script](tool/run.sh)\n"
            "[up](#top) [web](https://example.com/x.md) [mail](mailto:a@b.c)\n"
            '<img src="docs/img/a.png"> <source srcset="docs/img/a.png 2x">\n'
            "[ref]: docs/guide.md\n"
            "[on GitHub](https://github.com/robertostrowskijagoda/Zen/blob/main/docs/guide.md)\n"
        ), [])

    def test_a_missing_file_is_reported_with_its_line(self):
        found = self.problems("# Top\n\nSee [gone](docs/gone.md).\n")
        self.assertEqual(found, ["README.md:3: docs/gone.md does not exist"])

    def test_a_missing_heading_is_reported(self):
        found = self.problems("[x](docs/guide.md#getting-going)\n[y](#nowhere)\n")
        self.assertEqual(len(found), 2, found)
        self.assertIn("docs/guide.md has no heading for #getting-going", found[0])
        self.assertIn("no heading for #nowhere in this file", found[1])

    def test_relative_to_the_file(self):
        self.write("README.md", "# Zen\n")
        self.assertEqual(self.problems("[back](../README.md) [img](img/a.png)\n",
                                       name="docs/other.md"), [])
        self.assertEqual(len(self.problems("[x](guide.md)\n")), 1)

    def test_html_and_images_are_checked(self):
        found = self.problems('<img src="docs/img/b.png">\n![b](docs/img/c.png)\n')
        self.assertEqual(len(found), 2, found)

    def test_this_repository_on_github_is_checked(self):
        found = self.problems(
            "[x](https://github.com/robertostrowskijagoda/Zen/blob/main/docs/old.md)\n"
            "[y](https://github.com/robertostrowskijagoda/Zen/tree/main/docs)\n"
            "[z](https://github.com/robertostrowskijagoda/Zen/releases/latest)\n")
        self.assertEqual(len(found), 1, found)
        self.assertIn("docs/old.md", found[0])

    def test_code_is_skipped(self):
        self.assertEqual(self.problems(
            "`[x](missing.md)`\n```\n[y](missing.md)\n```\n~~~md\n![z](no.png)\n~~~\n"), [])

    def test_outside_the_repository(self):
        found = self.problems("[x](../../etc/passwd)\n")
        self.assertIn("outside the repository", found[0])

    def test_encoded_names(self):
        self.write("docs/a b.md", "# A\n")
        self.assertEqual(self.problems("[x](docs/a%20b.md)\n"), [])

    def test_default_files(self):
        self.write(".github/template.md", "x\n")
        self.write("lib/notes.md", "x\n")
        names = [os.path.relpath(p, self.root).replace(os.sep, "/")
                 for p in check_links.default_files(self.root)]
        self.assertIn("docs/guide.md", names)
        self.assertIn(".github/template.md", names)
        self.assertNotIn("lib/notes.md", names)


class RepositoryTest(unittest.TestCase):
    def test_the_documentation_has_no_broken_links(self):
        found = check_links.Checker(ROOT).problems(check_links.default_files(ROOT))
        self.assertEqual(found, [])


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
