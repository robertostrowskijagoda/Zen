#!/usr/bin/env python3
"""Tests of check_links.py and check_site.py, on small made-up Markdown files
and websites, and the repository's own documentation and website.

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
import check_site  # noqa: E402


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


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>A page</title>
<meta name="description" content="About a page.">
<link rel="canonical" href="https://robertostrowskijagoda.github.io/Zen/{path}">
<link rel="stylesheet" href="{up}site.css">
<script src="{up}site.js"></script>
</head>
<body data-nav="{nav}">
<header class="top" id="zenTop"></header>
<main><h1 id="top-of-page">A page</h1>{body}</main>
<footer class="foot" id="zenFoot"></footer>
</body>
</html>
"""

CONTRACT = """
const List<String> kUpdateAssets = <String>[
  'Zen-arm64-v8a.apk',
  'Zen-Windows.zip',
];
const String kIpaAsset = 'Zen-unsigned.ipa';
const String kSumsAsset = 'SHA256SUMS';
const String kSignedSumsAsset = 'SHA256SUMS.sig';
const String kWhatsNewAsset = 'whats-new.json';
"""

DOWNLOADS = "https://github.com/robertostrowskijagoda/Zen/releases/latest/download/"


class SiteTest(unittest.TestCase):
    """check_site.py on a small made-up website with the real site.js."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        self.write("tool/release_contract.dart", CONTRACT)
        os.makedirs(os.path.join(self.root, "tool", "pages"))
        shutil.copy(os.path.join(ROOT, "tool", "pages", "site.js"),
                    os.path.join(self.root, "tool", "pages", "site.js"))
        for name in ("docs/PRIVACY.md", "docs/TERMS.md", "LICENSE"):
            self.write(name, "text\n")
        for name in ("install", "features", "support", "about", "promo"):
            self.page(name + "/index.html", name + "/", name)
        self.write("tool/pages/site.css", "")
        self.write("tool/pages/zen-icon.png", "")
        self.page("index.html", "", "")
        self.page("guide/index.html", "guide/", "guide",
                  '<h2 id="start">Start</h2><a href="../">home</a>')
        self.write("tool/pages/404.html", self.html("404.html", "/Zen/", "", ""))
        check_site.write_chrome(self.root)

    def html(self, path, up, nav, body):
        return PAGE.format(path=path, up=up, nav=nav, body=body)

    def write(self, path, text):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8", newline="") as f:
            f.write(text)

    def read(self, path):
        with open(os.path.join(self.root, path), encoding="utf-8") as f:
            return f.read()

    def page(self, path, folder, nav, body=""):
        up = "../" * folder.count("/")
        self.write("tool/pages/" + path, self.html(folder, up, nav, body))

    def problems(self):
        return check_site.Site(self.root).problems()

    def with_body(self, body):
        self.page("guide/index.html", "guide/", "guide", body)
        check_site.write_chrome(self.root)
        return self.problems()

    def test_a_good_site_passes(self):
        self.assertEqual(self.problems(), [])

    def test_a_page_without_the_menu_is_reported_and_written(self):
        self.write("tool/pages/about/index.html",
                   self.html("about/", "../", "about", ""))
        found = self.problems()
        self.assertEqual(len(found), 1, found)
        self.assertIn("about/index.html", found[0])
        self.assertIn("--write", found[0])
        self.assertEqual(check_site.write_chrome(self.root), ["about/index.html"])
        self.assertEqual(self.problems(), [])
        self.assertEqual(check_site.write_chrome(self.root), [])

    def test_the_menu_follows_the_page_and_its_depth(self):
        guide = self.read("tool/pages/guide/index.html")
        header = guide[guide.index("<noscript>"):guide.index("</header>")]
        self.assertIn('<a href="../guide/" aria-current="page">', header)
        self.assertIn('<a href="../install/">', header)
        self.assertEqual(header.count("aria-current"), 1)
        # The 404 page is served at any depth: its links start at /Zen/.
        missing = self.read("tool/pages/404.html")
        self.assertIn('<a href="/Zen/install/">', missing)
        self.assertNotIn("aria-current", missing)
        footer = guide[guide.index('id="zenFoot"'):]
        self.assertIn('<a href="../promo/">', footer)
        self.assertIn("docs/PRIVACY.md", footer)

    def test_a_changed_menu_is_noticed(self):
        path = os.path.join(self.root, "tool", "pages", "site.js")
        script = self.read("tool/pages/site.js")
        with open(path, "w", encoding="utf-8") as f:
            f.write(script.replace('["support", "support/", "lifebuoy", "navSupport"],', ""))
        found = self.problems()
        self.assertEqual(len(found), 8, found)  # every page of the site
        self.assertIn("--write", found[0])
        # The footer is written by site.js too: a change there is not
        # guessed at.
        with open(path, "w", encoding="utf-8") as f:
            f.write(script.replace('data-i="footTerms"', 'data-i="footTermsX"'))
        self.assertRaises(ValueError, self.problems)

    def test_good_links_pass(self):
        self.assertEqual(self.with_body(
            '<h2 id="start">Start</h2><a href="#start">a</a> <a href="../#top">b</a> '
            '<a href="../guide/#start">c</a> <a href="../site.css">d</a> '
            '<a href="/Zen/guide/">e</a> <a href="../?lang=pl">f</a> '
            '<a href="zen://x">g</a>'
            '<a href="https://robertostrowskijagoda.github.io/Zen/guide/#start">h</a>'
            '<a href="https://github.com/robertostrowskijagoda/Zen/blob/main/docs/PRIVACY.md">i</a>'
            '<a href="https://example.com/" target="_blank" rel="noopener noreferrer">j</a>'),
            [])

    def test_broken_links_and_anchors_are_reported(self):
        found = self.with_body(
            '<a href="../gone/">a</a> <a href="#nowhere">b</a>'
            '<a href="../guide/#nowhere">c</a> <a href="/img/x.png">d</a>'
            '<a href="https://robertostrowskijagoda.github.io/Zen/gone/">e</a>'
            '<a href="https://github.com/robertostrowskijagoda/Zen/blob/main/docs/old.md">f</a>'
            '<a href="https://example.com/" target="_blank">g</a>'
            '<img src="../missing.png" alt="">')
        self.assertEqual(len(found), 8, found)
        text = "\n".join(found)
        for part in ("../gone/ does not exist", "#nowhere is not on the page",
                     "has no #nowhere", "starts at the root of the host",
                     "Zen/gone/ does not exist", "docs/old.md names a path",
                     'without rel="noopener"', "../missing.png does not exist"):
            self.assertIn(part, text)

    def test_nothing_is_loaded_from_another_host(self):
        found = self.with_body('<script src="https://cdn.example.com/x.js"></script>'
                               '<img src="https://example.com/a.png" alt="">')
        self.assertEqual(len(found), 2, found)
        self.assertIn("from another host", found[0])

    def test_downloads_name_files_the_release_attaches(self):
        self.assertEqual(self.with_body(
            '<a href="%sZen-arm64-v8a.apk">a</a><a href="%sZen-unsigned.ipa">b</a>'
            '<script>go(DL + "Zen-Windows.zip");</script>' % (DOWNLOADS, DOWNLOADS)), [])
        found = self.with_body(
            '<a href="%sZen-Gone.apk">a</a>'
            '<script>go(DL + "Zen-Gone.deb");</script>'
            '<a href="https://github.com/robertostrowskijagoda/Zen/releases/download/'
            'v1.0.0/Zen-Windows.zip">b</a>' % DOWNLOADS)
        self.assertEqual(len(found), 3, found)
        text = "\n".join(found)
        self.assertIn("Zen-Gone.apk, which the release does not attach", text)
        self.assertIn("Zen-Gone.deb", text)
        self.assertIn("pinned release", text)

    def test_what_every_page_needs(self):
        found = self.with_body('<img src="../zen-icon.png"><h1>Two</h1>')
        self.assertEqual(len(found), 2, found)
        self.assertIn("image without alt text", "\n".join(found))
        self.assertIn("2 <h1>", "\n".join(found))
        bare = self.html("guide/", "../", "guide", "")
        bare = bare.replace('<html lang="en">', "<html>")
        bare = bare.replace("<title>A page</title>", "")
        bare = bare.replace('<meta name="description" content="About a page.">', "")
        bare = bare.replace(
            '<link rel="canonical" href="https://robertostrowskijagoda.github.io/Zen/guide/">',
            "")
        self.write("tool/pages/guide/index.html", bare)
        check_site.write_chrome(self.root)
        text = "\n".join(self.problems())
        for part in ("no lang", "no <title>", "no meta description", "no canonical"):
            self.assertIn(part, text)
        # A page kept out of search engines needs no canonical address.
        self.write("tool/pages/guide/index.html", bare.replace(
            "<head>", '<head><meta name="robots" content="noindex">'))
        check_site.write_chrome(self.root)
        self.assertNotIn("no canonical", "\n".join(self.problems()))


class RepositorySiteTest(unittest.TestCase):
    def test_the_website_passes_its_checks(self):
        site = check_site.Site(ROOT)
        self.assertGreaterEqual(len(site.names), 15)
        self.assertEqual(site.problems(), [])

    def test_every_page_has_the_menu_for_visitors_without_javascript(self):
        site = check_site.Site(ROOT)
        nav, english, _ = check_site.read_script(site.site)
        self.assertEqual([entry[1] for entry in nav],
                         ["install/", "guide/", "features/", "support/", "about/", "promo/"])
        for name in site.names:
            text = site.texts[name]
            header = text[text.index('id="zenTop"'):text.index("</header>")]
            self.assertIn("<noscript>", header, name)
            for _, path, _, label in nav:
                self.assertIn(">%s</a>" % english[label], header, name)
                self.assertIn(path + '"', header, name)
            footer = text[text.index('id="zenFoot"'):text.index("</footer>")]
            self.assertIn("<noscript>", footer, name)
            self.assertIn("Privacy policy", footer, name)


class RepositoryTest(unittest.TestCase):
    def test_the_documentation_has_no_broken_links(self):
        found = check_links.Checker(ROOT).problems(check_links.default_files(ROOT))
        self.assertEqual(found, [])


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
