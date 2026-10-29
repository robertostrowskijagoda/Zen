#!/usr/bin/env python3
"""Checks the install page and the SideStore / AltStore source.

  python3 tool/ci/test_release_source.py      (from the repository root)

- release_source.py run on a fake release gives an apps.json with every
  field an AltStore / SideStore source needs, pointing to the release's
  Zen-unsigned.ipa, with the app's bundle id and minimum iOS version, the
  permissions and version numbers of that very IPA (checked against the
  release's SHA256SUMS), and the APK fingerprint the code pins at the tag;
  no other source file is published.
- Every download link of tool/pages/install/index.html, the invitation
  page and the door page names a file the release workflow makes (the
  list in tool/release_contract.dart; Android: one APK per ABI), the
  add-source links use the documented `sidestore://source?url=` /
  `altstore://source?url=` form (AltStore's handler: host "source", query
  "url"; SideStore is a fork of it), Obtainium's is `obtainium://add/<repo>`,
  the iPhone page adds the source in one of its steps, with the address,
  and every link a text uses exists.
- The app's constants (install page, source address, its SideStore link)
  are the same.
- The invitation and door pages start with the "Open in Zen" button, and
  the pages link the Discord server the app links.
- site_files.py (run at deployment) lists in sitemap.xml every page that
  may be indexed, in all 21 languages with the same hreflang alternates as
  the pages' heads, dated by git or by the deployment; writes a
  security.txt that follows RFC 9116 and expires in less than a year; and
  puts the release's version into the structured data, nothing else.

Standard library only.
"""

import datetime
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
import zipfile
from xml.etree import ElementTree

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tool", "ci"))

import release_source  # noqa: E402
import site_files  # noqa: E402


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


def fake_ipa(info):
    """An IPA (a zip with Payload/Runner.app/Info.plist) holding [info]."""
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/Runner.app/Runner", b"binary")
    return out.getvalue()


IPA_INFO = {
    "CFBundleShortVersionString": "9.9.9",
    "CFBundleVersion": "99",
    "NSCameraUsageDescription": "Camera, as built.",
    "NSContactsUsageDescription": "Only in the release.",
}
FINGERPRINT = "ab" * 32
APK_SIGNATURE_AT_TAG = (
    "const List<String> kOfficialApkCertificatesSha256 = <String>[\n"
    "  '" + FINGERPRINT.upper() + "',\n];\n"
)


class SourceTest(unittest.TestCase):
    def run_source(self, release, ipa=None, sums=None, apk_signature="",
                   info_plist_at_tag=None, apk_fingerprint=""):
        """release_source.main() against a fake GitHub; (source, page, status)."""
        def fake_api(path, token, raw=False):
            if not raw:
                return release
            if path.startswith("repos/robertostrowskijagoda/Zen/contents/pubspec.yaml"):
                self.assertIn("?ref=v9.9.9", path)
                return "name: zen\nversion: 9.9.9+98\n"
            if path.startswith("repos/robertostrowskijagoda/Zen/contents/ios/Runner/Info.plist"):
                self.assertIn("?ref=v9.9.9", path)
                return info_plist_at_tag
            if "apk_signature.dart" in path:
                self.assertIn("?ref=v9.9.9", path)
                return apk_signature
            return None

        def fake_download(url, limit=release_source.MAX_DOWNLOAD):
            if url.endswith("/Zen-unsigned.ipa"):
                return ipa
            if url.endswith("/SHA256SUMS"):
                return sums
            return None

        saved = (release_source.api, release_source.download)
        release_source.api = fake_api
        release_source.download = fake_download
        site = tempfile.mkdtemp()
        fingerprint = os.path.join(site, "fingerprint.txt")
        with open(fingerprint, "w", encoding="utf-8") as f:
            f.write(apk_fingerprint)
        status = 0
        try:
            argv = sys.argv
            sys.argv = ["release_source.py", "--repo", "robertostrowskijagoda/Zen",
                        "--site", site, "--fingerprint", fingerprint]
            try:
                release_source.main()
            except release_source.IntegrityError:
                status = 1
            finally:
                sys.argv = argv
        finally:
            release_source.api, release_source.download = saved
        if status:
            return None, None, status
        with open(os.path.join(site, "apps.json"), encoding="utf-8") as f:
            source = json.load(f)
        with open(os.path.join(site, "release.json"), encoding="utf-8") as f:
            page = json.load(f)
        self.published = sorted(os.listdir(site))
        return source, page, status

    def fake_release(self, names, ipa=None):
        base = "https://github.com/robertostrowskijagoda/Zen/releases/download/v9.9.9/"
        return {
            "tag_name": "v9.9.9",
            "published_at": "2030-01-02T03:04:05Z",
            "html_url": "https://github.com/robertostrowskijagoda/Zen/releases/tag/v9.9.9",
            "draft": False,
            "prerelease": False,
            "assets": [
                {"name": n,
                 "size": len(ipa) if (ipa is not None and n == "Zen-unsigned.ipa") else 1000 + i,
                 "browser_download_url": base + n}
                for i, n in enumerate(names)
            ],
        }

    def released(self, **kwargs):
        ipa = kwargs.pop("ipa", fake_ipa(IPA_INFO))
        default_sums = b"" if ipa is None else (
            hashlib.sha256(ipa).hexdigest() + "  Zen-unsigned.ipa\n").encode()
        sums = kwargs.pop("sums", default_sums)
        return self.run_source(self.fake_release(contract_assets(), ipa=ipa),
                               ipa=ipa, sums=sums, **kwargs)

    def test_apps_json_has_every_field_of_a_source(self):
        source, page, _ = self.released()
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
                    "minOSVersion", "sha256"):
            self.assertIn(key, version)
        self.assertEqual(version["version"], "9.9.9")
        # From the IPA's Info.plist (CFBundleVersion), not from pubspec.yaml.
        self.assertEqual(version["buildVersion"], "99")
        self.assertRegex(version["date"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertTrue(version["downloadURL"].startswith("https://github.com/"))
        self.assertTrue(version["downloadURL"].endswith("/v9.9.9/Zen-unsigned.ipa"))
        self.assertIsInstance(version["size"], int)
        target = re.search(r"IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);",
                           read("ios/Runner.xcodeproj/project.pbxproj")).group(1)
        self.assertEqual(version["minOSVersion"], target)
        self.assertIsInstance(app["appPermissions"]["entitlements"], list)
        self.assertEqual(page["version"], "9.9.9")
        for apk in ("Zen-arm64-v8a.apk", "Zen-armeabi-v7a.apk", "Zen-x86_64.apk"):
            self.assertIn(apk, page["assets"])

    def test_release_json_carries_what_the_app_update_check_needs(self):
        # lib/src/features/update/github_release.dart reads tag, assets
        # (name -> {"size": n}) and minVersion from it.
        release = self.fake_release(contract_assets())
        release["body"] = "Notes\nzen-min: 1.13.0\n"
        _, page, _ = self.run_source(release)
        self.assertEqual(page["tag"], "v9.9.9")
        self.assertEqual(page["minVersion"], "1.13.0")
        for name, asset in page["assets"].items():
            self.assertIsInstance(asset["size"], int, name)
        # A zen-min above the release itself, or none: no minimum.
        release["body"] = "zen-min: 10.0.0"
        self.assertEqual(self.run_source(release)[1]["minVersion"], "")
        del release["body"]
        self.assertEqual(self.run_source(release)[1]["minVersion"], "")

    def test_only_the_sidestore_source_and_the_release_data_are_written(self):
        # The fingerprint file is the test's own input.
        written = ["apps.json", "fingerprint.txt", "release.json"]
        self.released()
        self.assertEqual(self.published, written)
        names = [n for n in contract_assets() if n != "Zen-unsigned.ipa"]
        self.run_source(self.fake_release(names))
        self.assertEqual(self.published, written)

    def test_permissions_come_from_the_released_ipa_not_from_main(self):
        source, _, _ = self.released()
        privacy = source["apps"][0]["appPermissions"]["privacy"]
        self.assertEqual(privacy, {
            "NSCameraUsageDescription": "Camera, as built.",
            "NSContactsUsageDescription": "Only in the release.",
        })
        # The script has no way to read the default branch's Info.plist.
        self.assertNotIn("--info-plist", read("tool/ci/release_source.py"))

    def test_without_the_ipa_the_info_plist_at_the_tag_is_used(self):
        with open(os.path.join(ROOT, "ios/Runner/Info.plist"), encoding="utf-8") as f:
            plist = f.read()
        source, _, _ = self.released(ipa=None, info_plist_at_tag=plist)
        privacy = source["apps"][0]["appPermissions"]["privacy"]
        self.assertIn("NSCameraUsageDescription", privacy)
        for value in privacy.values():
            self.assertNotIn("$(", value)
        self.assertEqual(source["apps"][0]["versions"][0]["buildVersion"], "98")
        self.assertNotIn("sha256", source["apps"][0]["versions"][0])
        # Neither the IPA nor the tag's Info.plist: no app rather than a wrong one.
        source, _, _ = self.released(ipa=None, info_plist_at_tag=None)
        self.assertEqual(source["apps"], [])

    def test_an_ipa_that_does_not_match_sha256sums_stops_the_deployment(self):
        _, _, status = self.released(sums=(("00" * 32) + "  Zen-unsigned.ipa\n").encode())
        self.assertEqual(status, 1)

    def test_the_fingerprint_is_the_one_the_code_pins(self):
        _, page, _ = self.released(apk_signature=APK_SIGNATURE_AT_TAG,
                                   apk_fingerprint=":".join(["AB"] * 32))
        self.assertEqual(page["apkCertificateSha256"], FINGERPRINT)
        # An APK signed with another key stops the deployment.
        _, _, status = self.released(apk_signature=APK_SIGNATURE_AT_TAG,
                                     apk_fingerprint="cd" * 32)
        self.assertEqual(status, 1)
        # One line per APK (one per ABI): every one must be pinned.
        _, page, _ = self.released(apk_signature=APK_SIGNATURE_AT_TAG,
                                   apk_fingerprint=("ab" * 32 + "\n") * 3)
        self.assertEqual(page["apkCertificateSha256"], FINGERPRINT)
        _, _, status = self.released(
            apk_signature=APK_SIGNATURE_AT_TAG,
            apk_fingerprint="ab" * 32 + "\n" + "cd" * 32 + "\n" + "ab" * 32 + "\n")
        self.assertEqual(status, 1)
        # Nothing pinned at the tag: no fingerprint, even if the APK has one.
        _, page, _ = self.released(apk_signature="", apk_fingerprint="cd" * 32)
        self.assertEqual(page["apkCertificateSha256"], "")
        # The parser reads the real file's constant (empty or not).
        source = read(release_source.APK_SIGNATURE_DART)
        self.assertIn("kOfficialApkCertificatesSha256", source)
        self.assertIsInstance(release_source.pinned_fingerprints(source), list)

    def test_a_commented_out_fingerprint_is_not_pinned(self):
        # The compiled app holds none of these: neither does the page.
        name = "kOfficialApkCertificatesSha256"
        for text in (
            "const List<String> %s = <String>[\n  // '%s',\n];" % (name, "ab" * 32),
            "const List<String> %s = <String>[\n  /* '%s', */\n];" % (name, "ab" * 32),
            "// const List<String> %s = <String>['%s'];\n"
            "const List<String> %s = <String>[];" % (name, "ab" * 32, name),
        ):
            self.assertEqual(release_source.pinned_fingerprints(text), [], text)
        # Comment markers inside a string are not comments; adjacent
        # literals join, as in Dart.
        text = ("const u = 'https://x/*y'; const List<String> %s = <String>[\n"
                "  '%s'\n  '%s', // old: '%s'\n];" % (name, "AB" * 16, "ab" * 16, "cd" * 32))
        self.assertEqual(release_source.pinned_fingerprints(text), ["ab" * 32])
        # Anything but a plain literal stops the deployment instead of a guess.
        for entry in ("other", "'${x}'", "'$x'"):
            with self.assertRaises(release_source.IntegrityError):
                release_source.pinned_fingerprints(
                    "const List<String> %s = <String>[%s];" % (name, entry))

    def test_no_ipa_no_app_but_still_a_valid_source(self):
        names = [n for n in contract_assets() if n != "Zen-unsigned.ipa"]
        source, _, _ = self.run_source(self.fake_release(names))
        self.assertEqual(source["apps"], [])
        source, page, _ = self.run_source(None)
        self.assertEqual(source["apps"], [])
        self.assertEqual(page["tag"], "")

    def test_downloads_only_from_github(self):
        self.assertIsNone(release_source.download("https://example.com/Zen-unsigned.ipa"))
        self.assertIsNone(release_source.download("http://github.com/x/Zen-unsigned.ipa"))


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
        web = read("lib/src/app/zen_web.dart")
        base = re.search(r"kZenGithubPagesBase =\s*'([^']+)'", web).group(1)
        own = re.search(r"kZenOwnDomain = '([^']*)';", web).group(1)
        if own:
            # The pages moved to the own domain: so must the source.
            base = "https://" + own + "/"

        def resolve(value):
            return value.replace("${kZenPagesBase}", base)

        page = resolve(re.search(r"kInstallPageUrl =\s*'([^']+)'", dart).group(1))
        self.assertEqual(page, release_source.PAGES + "install/")
        # The app adds the same SideStore source, with SideStore's
        # documented link, and iOS opens exactly that link.
        release = read("lib/src/features/update/github_release.dart")
        source = resolve(re.search(r"kSideStoreSourceUrl =\s*'([^']+)'", release).group(1))
        self.assertEqual(source, release_source.PAGES + "apps.json")
        self.assertIn("'sidestore://source?url=$kSideStoreSourceUrl'", release)
        self.assertIn('"sidestore://source?url=' + source + '"',
                      read("ios/Runner/AppDelegate.swift"))
        self.assertTrue(os.path.exists(os.path.join(ROOT, "tool/pages/install/index.html")))


class InvitationPagesTest(unittest.TestCase):
    PAGES = ("tool/pages/index.html", "tool/pages/m/index.html")

    def test_downloads_name_release_files(self):
        assets = set(contract_assets())
        for path in self.PAGES:
            html = read(path)
            downloads = re.findall(r"/releases/latest/download/([^\"]+)\"", html)
            self.assertIn("Zen-arm64-v8a.apk", downloads, path)
            self.assertIn("Zen-armeabi-v7a.apk", downloads, path)
            self.assertIn("Zen-x86_64.apk", downloads, path)
            for name in downloads:
                self.assertIn(name, assets, path + ": " + name)
            # The Android button is the APK of most phones.
            button = re.search(r'id="android"[^>]*href="([^"]+)"', html).group(1)
            self.assertTrue(button.endswith("/Zen-arm64-v8a.apk"), path)

    def test_open_in_zen_comes_first_and_big(self):
        for path in self.PAGES:
            html = read(path)
            main = re.search(r"<main>\s*(<[^>]+>)", html).group(1)
            self.assertIn('id="open"', main, path)
            self.assertIn("open", re.search(r'class="([^"]+)"', main).group(1).split(), path)
            self.assertRegex(html, r"a\.btn\.open \{[^}]*font: 800 30px")

    def test_every_language_names_the_other_phones(self):
        html = read("tool/pages/index.html")
        texts = re.search(r"var TEXTS = \{(.*?)\n  \};", html, re.S).group(1)
        languages = re.findall(r'^    "(\w+)": \{', texts, re.M)
        self.assertEqual(len(languages), 21)
        self.assertEqual(texts.count('"otherPhones": '), len(languages))


SITE_PAGES = ("index.html", "m/index.html", "about/index.html", "guide/index.html",
              "features/index.html", "support/index.html", "install/index.html",
              "install/android/index.html", "install/iphone/index.html",
              "install/windows/index.html", "install/macos/index.html",
              "install/linux/index.html", "promo/index.html")


def language_tables(text):
    """{language: {key: text}} of the "xx": {...} lines of a TEXTS / COMMON block."""
    return {lang: json.loads(body) for lang, body in
            re.findall(r'^\s{4}"(\w+)": (\{.*\}),?$', text, re.M)}


class SitePagesTest(unittest.TestCase):
    """Every page has all 21 languages, with the same texts keys in each."""

    def test_the_shared_texts_cover_21_languages(self):
        script = read("tool/pages/site.js")
        common = language_tables(re.search(r"var COMMON = \{(.*?)\n  \};", script, re.S).group(1))
        self.assertEqual(len(common), 21)
        keys = set(common["en"])
        for lang, table in common.items():
            self.assertEqual(set(table), keys, lang)
        self.common_keys = keys

    def test_every_page_has_21_languages_and_the_same_keys(self):
        script = read("tool/pages/site.js")
        common = set(language_tables(
            re.search(r"var COMMON = \{(.*?)\n  \};", script, re.S).group(1))["en"])
        for path in SITE_PAGES:
            html = read("tool/pages/" + path)
            block = re.search(r"var TEXTS = \{(.*?)\n  \};", html, re.S).group(1)
            tables = language_tables(block)
            self.assertEqual(len(tables), 21, path)
            keys = set(tables["en"])
            for lang, table in tables.items():
                self.assertEqual(set(table), keys, path + " " + lang)
            # Every text an element asks for exists (the page's own or the shared).
            asked = set(re.findall(r'data-i(?:a|al|t)?="([\w.]+)"', html))
            for key in asked:
                self.assertTrue(key in keys or key in common, path + ": " + key)

    def test_downloads_of_every_page_name_release_files(self):
        assets = set(contract_assets())
        for path in SITE_PAGES:
            html = read("tool/pages/" + path)
            for name in re.findall(r'/releases/latest/download/([^"]+)"', html):
                self.assertIn(name, assets, path + ": " + name)

    def test_the_iphone_page_links_the_latest_ipa_and_the_android_page_the_apk(self):
        iphone = read("tool/pages/install/iphone/index.html")
        self.assertIn("/releases/latest/download/Zen-unsigned.ipa", iphone)
        self.assertIn("sidestore://source?url=" + urllib.parse.quote(
            release_source.PAGES + "apps.json", safe=""), iphone)
        # The source's address to add by hand ("Sources" → "+"), in every
        # language, in the step that adds it.
        texts = language_tables(
            re.search(r"var TEXTS = \{(.*?)\n  \};", iphone, re.S).group(1))
        for lang, table in texts.items():
            self.assertIn("`" + release_source.PAGES + "apps.json`",
                          table["s5d"], lang)
        android = read("tool/pages/install/android/index.html")
        self.assertIn("/releases/latest/download/Zen-arm64-v8a.apk", android)

    def test_every_page_has_the_shared_header_and_the_language_switch(self):
        for path in SITE_PAGES:
            html = read("tool/pages/" + path)
            self.assertIn('id="zenTop"', html, path)
            self.assertIn('id="zenFoot"', html, path)
            self.assertRegex(html, r'<script src="(\.\./)*site\.js"></script>', path)
        script = read("tool/pages/site.js")
        for part in ('id="langSel"', 'id="langCode"', 'id="langName"', 'localStorage'):
            self.assertIn(part, script)
        self.assertIn('"zen-lang"', script)

    def test_every_page_links_the_pages_of_the_header(self):
        script = read("tool/pages/site.js")
        for target in ("install/", "guide/", "features/", "support/", "about/"):
            self.assertIn('"' + target + '"', script)
            self.assertTrue(os.path.exists(os.path.join(ROOT, "tool/pages", target, "index.html")))


class SiteFilesTest(unittest.TestCase):
    """site_files.py on a copy of the site, as the Pages workflow runs it."""

    NOW = datetime.datetime(2026, 10, 28, 12, 30, 45, 123456, tzinfo=datetime.timezone.utc)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.site = os.path.join(self.tmp.name, "_site")
        shutil.copytree(os.path.join(ROOT, "tool", "pages"), self.site)
        self.codes = site_files.languages(self.site)

    def tearDown(self):
        self.tmp.cleanup()

    def indexable(self):
        return [p for p in SITE_PAGES
                if 'content="noindex"' not in read("tool/pages/" + p)]

    def parse(self, xml):
        ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9",
              "x": "http://www.w3.org/1999/xhtml"}
        urls = {}
        for url in ElementTree.fromstring(xml).findall("s:url", ns):
            urls[url.find("s:loc", ns).text] = (
                url.find("s:lastmod", ns).text,
                {link.get("hreflang"): link.get("href") for link in url.findall("x:link", ns)},
            )
        return urls

    def test_the_sitemap_lists_every_page_that_may_be_indexed_in_every_language(self):
        self.assertEqual(len(self.codes), 21)
        self.assertEqual(self.codes[0], "en")
        seen = []
        xml = site_files.sitemap(self.site, "tool/pages", self.NOW,
                                 last_change=lambda paths: seen.append(paths) or
                                 "2026-01-02T03:04:05+01:00")
        urls = self.parse(xml)
        pages = self.indexable()
        # The invitation and door pages ask not to be indexed.
        self.assertNotIn("index.html", pages)
        self.assertNotIn("m/index.html", pages)
        self.assertEqual(len(pages), len(SITE_PAGES) - 2)
        self.assertEqual(sorted(site_files.pages(self.site)), sorted(pages))
        expected = {}
        for page in pages:
            base = release_source.PAGES + page[: -len("index.html")]
            links = {c: base if c == "en" else base + "?lang=" + c for c in self.codes}
            links["x-default"] = base
            for code in self.codes:
                expected[links[code]] = ("2026-01-02T03:04:05+01:00", links)
        self.assertEqual(urls, expected)
        self.assertNotIn(release_source.PAGES, urls)
        self.assertNotIn(release_source.PAGES + "m/", urls)
        # Dated by the page and the shared script, in the sources.
        self.assertIn([os.path.join("tool/pages", "about/index.html"),
                       os.path.join("tool/pages", "site.js")], seen)

    def test_the_sitemap_and_the_pages_name_the_same_alternates(self):
        for page in self.indexable():
            html = read("tool/pages/" + page)
            url = site_files.page_url(page)
            self.assertIn('<link rel="canonical" href="%s">' % url, html)
            head = re.findall(r'<link rel="alternate" hreflang="([\w-]+)" href="([^"]+)">', html)
            self.assertEqual(head, site_files.alternates(url, self.codes), page)

    def test_without_git_the_date_of_the_deployment(self):
        urls = self.parse(site_files.sitemap(self.site, "tool/pages", self.NOW,
                                             last_change=lambda paths: ""))
        self.assertEqual({v[0] for v in urls.values()}, {"2026-10-28T12:30:45Z"})

    def test_security_txt_follows_rfc_9116(self):
        text = site_files.security_txt(self.NOW)
        self.assertTrue(text.endswith("\n"))
        fields = {}
        for line in text.splitlines():
            name, value = line.split(": ", 1)
            self.assertNotIn(name, fields, "each field once")
            fields[name] = value
        self.assertEqual(fields["Contact"],
                         "https://github.com/robertostrowskijagoda/Zen/security/advisories/new")
        self.assertEqual(fields["Preferred-Languages"], "pl, en")
        self.assertEqual(fields["Canonical"],
                         release_source.PAGES + ".well-known/security.txt")
        self.assertTrue(fields["Policy"].startswith("https://"))
        self.assertIn("SECURITY.md", fields["Policy"])
        self.assertTrue(os.path.exists(os.path.join(ROOT, "SECURITY.md")))
        self.assertIn(fields["Contact"], read("SECURITY.md"))
        # Expires: RFC 3339, in the future, less than a year away.
        self.assertRegex(fields["Expires"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        expires = datetime.datetime.strptime(fields["Expires"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        self.assertGreater(expires, self.NOW + datetime.timedelta(days=300))
        self.assertLess(expires, self.NOW + datetime.timedelta(days=365))

    def test_the_release_version_goes_into_the_structured_data(self):
        with open(os.path.join(self.site, "release.json"), "w", encoding="utf-8") as f:
            json.dump({"version": "9.8.7", "date": "2026-10-01"}, f)
        self.assertEqual(site_files.release_version(self.site), "9.8.7")
        changed = site_files.fill_version(self.site, "9.8.7")
        self.assertEqual(changed, ["about/index.html", "index.html", "install/index.html"])
        for page in changed:
            with open(os.path.join(self.site, page), encoding="utf-8") as f:
                html = f.read()
            block = re.search(r'<script type="application/ld\+json">(.*?)</script>',
                              html, re.S).group(1)
            data = json.loads(block)
            nodes = data.get("@graph", [data])
            apps = [n for n in nodes if n["@type"] == "SoftwareApplication"]
            self.assertEqual([a["softwareVersion"] for a in apps], ["9.8.7"], page)
            self.assertTrue(all("softwareVersion" not in n for n in nodes
                                if n["@type"] != "SoftwareApplication"), page)
            # The rest of the page stays as it was.
            self.assertEqual(re.sub(r"<script type=\"application/ld\+json\">.*?</script>", "",
                                    html, flags=re.S),
                             re.sub(r"<script type=\"application/ld\+json\">.*?</script>", "",
                                    read("tool/pages/" + page), flags=re.S))

    def test_no_release_no_version(self):
        self.assertEqual(site_files.release_version(self.site), "")
        for bad in ({"version": ""}, {"version": "v1<script>"}, ["1.0.0"]):
            with open(os.path.join(self.site, "release.json"), "w", encoding="utf-8") as f:
                json.dump(bad, f)
            self.assertEqual(site_files.release_version(self.site), "", bad)

    def test_the_script_writes_every_file(self):
        result = subprocess.run(
            [sys.executable, os.path.join(ROOT, "tool", "ci", "site_files.py"),
             "--site", self.site, "--source", os.path.join(ROOT, "tool", "pages")],
            capture_output=True, text=True, cwd=ROOT, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("sitemap.xml", os.path.join(".well-known", "security.txt")):
            self.assertTrue(os.path.exists(os.path.join(self.site, name)), name)
        with open(os.path.join(self.site, "sitemap.xml"), encoding="utf-8") as f:
            urls = self.parse(f.read())
        self.assertEqual(len(urls), len(self.indexable()) * 21)
        for lastmod, _ in urls.values():
            self.assertRegex(lastmod, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)$")


class DiscordTest(unittest.TestCase):
    def test_the_pages_and_the_app_link_the_same_server(self):
        url = re.search(r"kZenDiscordUrl = '([^']+)'",
                        read("lib/src/app/zen_web.dart")).group(1)
        self.assertTrue(url.startswith("https://discord.gg/"))
        for path in ("tool/pages/index.html", "tool/pages/install/index.html"):
            self.assertIn(url, read(path), path)


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
