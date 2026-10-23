#!/usr/bin/env python3
"""Checks tool/ci/check_webrtc_sdk.py.

  python3 tool/ci/test_check_webrtc_sdk.py      (from the repository root)

- Without a pin it only warns and prints the line to add; with --strict
  it fails.
- A framework with another hash fails (a changed file, an added file, a
  changed symbolic link); the pinned one passes.
- The version comes from Pods/Manifest.lock; a missing pod fails.
- --hash prints the same tree hash the check computes.

Standard library only.
"""

import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_webrtc_sdk  # noqa: E402

VERSION = "150.7871.01"
MANIFEST = """PODS:
  - Flutter (1.0.0)
  - flutter_webrtc (1.6.2):
    - Flutter
    - WebRTC-SDK (= 150.7871.01)
  - WebRTC-SDK (150.7871.01)

COCOAPODS: 1.16.2
"""


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


class CheckWebrtcSdkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.pods = os.path.join(self.tmp.name, "Pods")
        _write(os.path.join(self.pods, "Manifest.lock"), MANIFEST.encode())
        self.framework = os.path.join(self.pods, "WebRTC-SDK", "WebRTC.xcframework")
        mac = os.path.join(self.framework, "macos-arm64_x86_64", "WebRTC.framework")
        _write(os.path.join(mac, "Versions", "A", "WebRTC"), b"mach-o")
        _write(os.path.join(self.framework, "Info.plist"), b"<plist/>")
        try:
            os.symlink("A", os.path.join(mac, "Versions", "Current"))
            os.symlink("Versions/Current/WebRTC", os.path.join(mac, "WebRTC"))
        except (OSError, NotImplementedError):
            self.tmp.cleanup()
            self.skipTest("no symbolic links here (Windows without the right)")
        self.pins = os.path.join(self.tmp.name, "pins")

    def tearDown(self):
        self.tmp.cleanup()

    def run_check(self, strict=False):
        lines = []
        status = check_webrtc_sdk.check(
            self.pods, self.pins, strict, lines.append,
            package=os.path.join(self.tmp.name, "no-package"))
        return status, "\n".join(lines)

    def pin(self, value):
        with open(self.pins, "w", encoding="utf-8") as f:
            f.write("# comment\n\n%s  %s/WebRTC.xcframework\n" % (value, VERSION))

    def test_unpinned_warns_or_fails(self):
        status, text = self.run_check()
        self.assertEqual(status, 0)
        self.assertIn("::warning::", text)
        actual = check_webrtc_sdk.tree_hash(self.framework)
        self.assertIn("%s  %s/WebRTC.xcframework" % (actual, VERSION), text)
        status, text = self.run_check(strict=True)
        self.assertEqual(status, 1)
        self.assertIn("::error::", text)

    def test_pinned_passes_and_any_change_fails(self):
        self.pin(check_webrtc_sdk.tree_hash(self.framework))
        self.assertEqual(self.run_check(strict=True)[0], 0)
        binary = os.path.join(self.framework, "macos-arm64_x86_64", "WebRTC.framework",
                              "Versions", "A", "WebRTC")
        _write(binary, b"other mach-o")
        self.assertEqual(self.run_check()[0], 1)
        _write(binary, b"mach-o")
        self.assertEqual(self.run_check()[0], 0)
        extra = os.path.join(self.framework, "ios-arm64", "extra.dylib")
        _write(extra, b"x")
        self.assertEqual(self.run_check()[0], 1)
        os.remove(extra)
        os.rmdir(os.path.dirname(extra))
        link = os.path.join(self.framework, "macos-arm64_x86_64", "WebRTC.framework",
                            "WebRTC")
        os.remove(link)
        os.symlink("/tmp/elsewhere", link)
        self.assertEqual(self.run_check()[0], 1)

    def test_version_and_missing_pod(self):
        self.assertEqual(check_webrtc_sdk.pod_version(self.pods), VERSION)
        _write(os.path.join(self.pods, "Manifest.lock"), b"PODS:\n  - Flutter (1.0.0)\n")
        self.assertEqual(self.run_check()[0], 1)

    def test_malformed_pin_fails(self):
        with open(self.pins, "w", encoding="utf-8") as f:
            f.write("not a pin\n")
        with self.assertRaises(ValueError):
            check_webrtc_sdk.read_pins(self.pins)
        self.assertEqual(check_webrtc_sdk.main(["--pins", self.pins, self.pods]), 1)

    def test_hash_option(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(check_webrtc_sdk.main(["--hash", self.framework]), 0)
        self.assertEqual(out.getvalue().strip(), check_webrtc_sdk.tree_hash(self.framework))

    def test_the_pin_file_reads(self):
        check_webrtc_sdk.read_pins(check_webrtc_sdk.PINS)


ZIP_SUM = "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"
PACKAGE_SWIFT = """let package = Package(
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/%s/WebRTC.xcframework.zip",
            checksum: "%s"
        ),
    ]
)
"""


class SwiftPackageManagerTest(unittest.TestCase):
    """No WebRTC-SDK pod: flutter_webrtc's Package.swift must name the
    pinned zip checksum (Swift Package Manager checks the zip itself)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.pods = os.path.join(self.tmp.name, "app", "macos", "Pods")
        _write(os.path.join(self.pods, "Manifest.lock"), b"PODS:\n  - FlutterMacOS (1.0.0)\n")
        self.package = os.path.join(self.tmp.name, "flutter_webrtc")
        self.pins = os.path.join(self.tmp.name, "pins")

    def tearDown(self):
        self.tmp.cleanup()

    def swift(self, checksum):
        _write(os.path.join(self.package, "macos", "flutter_webrtc", "Package.swift"),
               (PACKAGE_SWIFT % (VERSION, checksum)).encode())

    def run_check(self, strict=False):
        lines = []
        status = check_webrtc_sdk.check(
            self.pods, self.pins, strict, lines.append, package=self.package)
        return status, "\n".join(lines)

    def test_pinned_checksum_passes_another_fails(self):
        self.swift(ZIP_SUM)
        with open(self.pins, "w", encoding="utf-8") as f:
            f.write("%s  %s/WebRTC.xcframework.zip\n" % (ZIP_SUM, VERSION))
        self.assertEqual(self.run_check(strict=True)[0], 0)
        self.swift("0" * 64)
        self.assertEqual(self.run_check()[0], 1)

    def test_unpinned_warns_or_fails_and_no_package_fails(self):
        self.swift(ZIP_SUM)
        status, text = self.run_check()
        self.assertEqual(status, 0)
        self.assertIn("%s  %s/WebRTC.xcframework.zip" % (ZIP_SUM, VERSION), text)
        self.assertEqual(self.run_check(strict=True)[0], 1)
        self.package = os.path.join(self.tmp.name, "missing")
        self.assertEqual(self.run_check()[0], 1)

    def test_the_repository_pins_the_zip(self):
        pins = check_webrtc_sdk.read_pins(check_webrtc_sdk.PINS)
        self.assertEqual(pins.get("%s/WebRTC.xcframework.zip" % VERSION), ZIP_SUM)


if __name__ == "__main__":
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    unittest.main(verbosity=2)
