#!/usr/bin/env python3
"""Checks the install page and the SideStore / AltStore source.

  python3 tool/ci/test_release_source.py      (from the repository root)

- release_source.py run on a fake release gives an apps.json with every
  field an AltStore / SideStore source needs, pointing to the release's
  Zen-unsigned.ipa, with the app's bundle id and minimum iOS version, the
  permissions and version numbers of that very IPA (checked against the
  release's SHA256SUMS), and the APK fingerprint the code pins at the tag.
- Every download link of tool/pages/install/index.html, the invitation
  page and the door page names a file the release workflow makes (the
  list in tool/release_contract.dart; Android: one APK per ABI), the
  add-source links use the documented `sidestore://source?url=` /
  `altstore://source?url=` form (AltStore's handler: host "source", query
  "url"; SideStore is a fork of it), Obtainium's is `obtainium://add/<repo>`,
  and every link a text uses exists.
- The app's constants (install page, source address) are the same.
- The invitation and door pages start with the "Open in Zen" button, and
  the pages link the Discord server the app links.

Standard library only.
"""

import hashlib
import io
import json
import os
import plistlib
import re
import sys
import tempfile
import unittest
import urllib.parse
import zipfile

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
        source = resolve(re.search(r"kSideStoreSourceUrl =\s*'([^']+)'", dart).group(1))
        self.assertEqual(page, release_source.PAGES + "install/")
        self.assertEqual(source, release_source.PAGES + "apps.json")
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
