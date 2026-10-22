#!/usr/bin/env python3
"""Checks the install page and the SideStore / AltStore source.

  python3 tool/ci/test_release_source.py      (from the repository root)

- release_source.py run on a fake release gives an apps.json with every
  field an AltStore / SideStore source needs, pointing to the release's
  Zen-unsigned.ipa, with the app's bundle id and minimum iOS version.
- Every download link of tool/pages/install/index.html names a file the
  release workflow makes (the list in tool/release_contract.dart), the
  add-source links use the documented `sidestore://source?url=` /
  `altstore://source?url=` form (AltStore's handler: host "source", query
  "url"; SideStore is a fork of it), Obtainium's is `obtainium://add/<repo>`,
  and every link a text uses exists.
- The app's constants (install page, source address) are the same.

Standard library only.
"""

import json
import os
import re
import sys
import tempfile
import unittest
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tool", "ci"))

import release_source  # noqa: E402


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def contract_assets():
    """The file names of tool/release_contract.dart."""
    text = read("tool/release_contract.dart")
    block = re.search(r"kUpdateAssets = <String>\[(.*?)\];", text, re.S).group(1)
    names = re.findall(r"'([^']+)'", block)
    for const in ("kIpaAsset", "kSumsAsset", "kSignedSumsAsset"):
        names.append(re.search(const + r" = '([^']+)'", text).group(1))
    return names


class SourceTest(unittest.TestCase):
    def run_source(self, release):
        def fake_api(path, token, raw=False):
            if raw:
                return "name: zen\nversion: 9.9.9+99\n"
            return release

        original = release_source.api
        release_source.api = fake_api
        try:
            site = tempfile.mkdtemp()
            argv = sys.argv
            sys.argv = ["release_source.py", "--repo", "robertostrowskijagoda/Zen",
                        "--site", site,
                        "--info-plist", os.path.join(ROOT, "ios/Runner/Info.plist")]
            try:
                release_source.main()
            finally:
                sys.argv = argv
        finally:
            release_source.api = original
        with open(os.path.join(site, "apps.json"), encoding="utf-8") as f:
            source = json.load(f)
        with open(os.path.join(site, "release.json"), encoding="utf-8") as f:
            page = json.load(f)
        return source, page

    def fake_release(self, names):
        base = "https://github.com/robertostrowskijagoda/Zen/releases/download/v9.9.9/"
        return {
            "tag_name": "v9.9.9",
            "published_at": "2030-01-02T03:04:05Z",
            "html_url": "https://github.com/robertostrowskijagoda/Zen/releases/tag/v9.9.9",
            "draft": False,
            "prerelease": False,
            "assets": [
                {"name": n, "size": 1000 + i, "browser_download_url": base + n}
                for i, n in enumerate(names)
            ],
        }

    def test_apps_json_has_every_field_of_a_source(self):
        source, page = self.run_source(self.fake_release(contract_assets()))
        for key in ("name", "identifier", "sourceURL", "iconURL", "apps"):
            self.assertIn(key, source)
        self.assertEqual(source["sourceURL"], release_source.PAGES + "apps.json")
        self.assertEqual(len(source["apps"]), 1)
        app = source["apps"][0]
        for key in ("name", "bundleIdentifier", "developerName",
                    "localizedDescription", "iconURL", "versions",
                    "appPermissions"):
            self.assertIn(key, app)
        bundle = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = ([\w.]+);",
                           read("ios/Runner.xcodeproj/project.pbxproj")).group(1)
        self.assertEqual(app["bundleIdentifier"], bundle)
        version = app["versions"][0]
        for key in ("version", "buildVersion", "date", "downloadURL", "size",
                    "minOSVersion"):
            self.assertIn(key, version)
        self.assertEqual(version["version"], "9.9.9")
        self.assertEqual(version["buildVersion"], "99")
        self.assertRegex(version["date"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertTrue(version["downloadURL"].startswith("https://github.com/"))
        self.assertTrue(version["downloadURL"].endswith("/v9.9.9/Zen-unsigned.ipa"))
        self.assertIsInstance(version["size"], int)
        target = re.search(r"IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);",
                           read("ios/Runner.xcodeproj/project.pbxproj")).group(1)
        self.assertEqual(version["minOSVersion"], target)
        privacy = app["appPermissions"]["privacy"]
        self.assertIsInstance(app["appPermissions"]["entitlements"], list)
        self.assertIn("NSCameraUsageDescription", privacy)
        for value in privacy.values():
            self.assertNotIn("$(", value)
        self.assertEqual(page["version"], "9.9.9")
        self.assertIn("Zen.apk", page["assets"])

    def test_no_ipa_no_app_but_still_a_valid_source(self):
        names = [n for n in contract_assets() if n != "Zen-unsigned.ipa"]
        source, _ = self.run_source(self.fake_release(names))
        self.assertEqual(source["apps"], [])
        source, page = self.run_source(None)
        self.assertEqual(source["apps"], [])
        self.assertEqual(page["tag"], "")


class InstallPageTest(unittest.TestCase):
    def setUp(self):
        self.html = read("tool/pages/install/index.html")
        self.links = dict(re.findall(r'^\s{4}(\w+): (.+?),?$',
                                     re.search(r"var LINKS = \{(.*?)\n  \};",
                                               self.html, re.S).group(1), re.M))

    def test_downloads_name_release_files(self):
        assets = set(contract_assets())
        downloads = re.findall(r'DL \+ "([^"]+)"', self.html)
        self.assertGreaterEqual(len(downloads), 10)
        for name in downloads:
            self.assertIn(name, assets, name)
        self.assertIn('REPO + "/releases/latest/download/"', self.html)

    def test_deep_links(self):
        self.assertIn('"sidestore://source?url=" + encodeURIComponent(SOURCE)',
                      self.links["addSideStore"])
        self.assertIn('"altstore://source?url=" + encodeURIComponent(SOURCE)',
                      self.links["addAltStore"])
        self.assertEqual(self.links["obtainium"], '"obtainium://add/" + REPO')
        self.assertIn('var REPO = "https://github.com/robertostrowskijagoda/Zen";',
                      self.html)
        source = re.search(r'var SOURCE = "([^"]+)";', self.html).group(1)
        self.assertEqual(source, release_source.PAGES + "apps.json")
        url = "sidestore://source?url=" + urllib.parse.quote(source, safe="")
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        self.assertEqual(query["url"], [source])

    def test_every_link_a_text_uses_exists(self):
        texts = re.search(r"var TEXTS = \{(.*?)\n  \};", self.html, re.S).group(1)
        used = set(re.findall(r"[\[{][^|\]{}]+\|(\w+)[\]}]", texts))
        self.assertTrue(used)
        for key in used:
            self.assertIn(key, self.links, key)

    def test_the_app_points_to_the_same_page_and_source(self):
        dart = read("lib/src/features/update/presentation/install_guide_screen.dart")
        page = re.search(r"kInstallPageUrl =\s*'([^']+)'", dart).group(1)
        source = re.search(r"kSideStoreSourceUrl =\s*'([^']+)'", dart).group(1)
        self.assertEqual(page, release_source.PAGES + "install/")
        self.assertEqual(source, release_source.PAGES + "apps.json")
        self.assertTrue(os.path.exists(os.path.join(ROOT, "tool/pages/install/index.html")))


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
