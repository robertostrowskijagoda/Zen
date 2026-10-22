#!/usr/bin/env python3
"""Checks tool/ci/check_libwebrtc.py.

  python3 tool/ci/test_check_libwebrtc.py      (from the repository root)

- Without pins it only warns and prints the lines to add; with --strict
  it fails.
- A pinned library or zip with another hash fails; the right one passes.
- The library missing from the bundle fails.
- The package folder and libwebrtc's version are found the way pub and
  flutter_webrtc's CMake name them.

Standard library only.
"""

import hashlib
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_libwebrtc  # noqa: E402

VERSION = "libwebrtc.m150.7871.03"


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


class CheckLibwebrtcTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.package = os.path.join(root, "pub", "flutter_webrtc-1.6.2")
        _write(
            os.path.join(self.package, "third_party", "libwebrtc_version.ini"),
            ("[libwebrtc]\nbinary_version = %s\n"
             "download_url = https://example.invalid\n" % VERSION).encode(),
        )
        self.zip = os.path.join(
            self.package, "third_party", "downloads", "libwebrtc-linux-x64-release.zip"
        )
        _write(self.zip, b"zip bytes")
        self.bundle = os.path.join(root, "bundle")
        self.library = os.path.join(self.bundle, "lib", "libwebrtc.so")
        _write(self.library, b"library bytes")
        self.pins = os.path.join(root, "pins")
        self.lines = []

    def tearDown(self):
        self.tmp.cleanup()

    def run_check(self, pins, strict=False, platform="linux-x64"):
        with open(self.pins, "w", encoding="utf-8") as f:
            f.write("# comment\n\n")
            for key, value in pins.items():
                f.write("%s  %s\n" % (value, key))
        self.lines = []
        return check_libwebrtc.check(
            platform, self.bundle, self.pins, self.package, strict, self.lines.append
        )

    def key(self, name):
        return "%s/linux-x64/%s" % (VERSION, name)

    def test_without_pins_it_warns_with_the_lines_to_add(self):
        self.assertEqual(self.run_check({}), 0)
        text = "\n".join(self.lines)
        self.assertIn("::warning::", text)
        self.assertIn(
            "%s  %s" % (hashlib.sha256(b"library bytes").hexdigest(),
                        self.key("libwebrtc.so")),
            text,
        )
        self.assertIn(self.key("libwebrtc-linux-x64-release.zip"), text)
        self.assertEqual(self.run_check({}, strict=True), 1)

    def test_right_hashes_pass(self):
        pins = {
            self.key("libwebrtc.so"): hashlib.sha256(b"library bytes").hexdigest(),
            self.key("libwebrtc-linux-x64-release.zip"):
                hashlib.sha256(b"zip bytes").hexdigest(),
        }
        self.assertEqual(self.run_check(pins, strict=True), 0)

    def test_a_swapped_library_fails(self):
        pins = {self.key("libwebrtc.so"): hashlib.sha256(b"other").hexdigest()}
        self.assertEqual(self.run_check(pins), 1)
        self.assertIn("::error::", "\n".join(self.lines))

    def test_a_swapped_zip_fails(self):
        pins = {
            self.key("libwebrtc.so"): hashlib.sha256(b"library bytes").hexdigest(),
            self.key("libwebrtc-linux-x64-release.zip"): "0" * 64,
        }
        self.assertEqual(self.run_check(pins), 1)

    def test_a_pin_of_another_version_does_not_count(self):
        pins = {
            "libwebrtc.m149/linux-x64/libwebrtc.so":
                hashlib.sha256(b"library bytes").hexdigest(),
        }
        self.assertEqual(self.run_check(pins, strict=True), 1)

    def test_the_library_must_be_in_the_bundle(self):
        os.remove(self.library)
        self.assertEqual(self.run_check({}), 1)

    def test_windows_names(self):
        self.assertEqual(check_libwebrtc.library_name("windows-arm64"), "libwebrtc.dll")
        self.assertEqual(
            check_libwebrtc.asset_name("windows-x64"), "libwebrtc-win-x64-release.zip"
        )
        self.assertEqual(
            check_libwebrtc.asset_name("linux-arm64"), "libwebrtc-linux-arm64-release.zip"
        )

    def test_a_malformed_pin_is_an_error(self):
        with open(self.pins, "w", encoding="utf-8") as f:
            f.write("not-a-hash  key\n")
        with self.assertRaises(ValueError):
            check_libwebrtc.read_pins(self.pins)

    def test_the_package_is_found_through_pub(self):
        root = os.path.join(self.tmp.name, "app")
        config = os.path.join(root, ".dart_tool", "package_config.json")
        uri = "file://" + ("/" if os.name == "nt" else "") + self.package.replace(os.sep, "/")
        _write(config, json.dumps({
            "configVersion": 2,
            "packages": [
                {"name": "other", "rootUri": "../other"},
                {"name": "flutter_webrtc", "rootUri": uri},
            ],
        }).encode())
        found = check_libwebrtc.package_dir(root)
        self.assertEqual(os.path.normcase(found), os.path.normcase(os.path.normpath(self.package)))
        self.assertEqual(check_libwebrtc.binary_version(found), VERSION)

    def test_the_pins_file_in_the_repository_reads(self):
        check_libwebrtc.read_pins(check_libwebrtc.PINS)


if __name__ == "__main__":
    unittest.main()
