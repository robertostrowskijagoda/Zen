#!/usr/bin/env python3
"""Checks the WebRTC.xcframework CocoaPods downloaded against a pinned hash.

  check_webrtc_sdk.py [--strict] [--pins FILE] PODS        (after a build)
  check_webrtc_sdk.py --hash FOLDER/WebRTC.xcframework     (to pin one)

  PODS  ios/Pods or macos/Pods after `flutter build ios` / `flutter build
        macos`

flutter_webrtc depends on the WebRTC-SDK pod at one exact version, but the
pod's framework is a zip from a GitHub release that CocoaPods downloads
without checking any hash, and it goes into Zen-macOS.zip and
Zen-unsigned.ipa. This script hashes the framework as it is in
PODS/WebRTC-SDK/WebRTC.xcframework (its tree hash: the SHA-256 of a list
of every file's relative path and SHA-256 and every symbolic link's
target, sorted) and compares it with tool/ci/webrtc_sdk.sha256, whose lines
are

  <sha256>  <WebRTC-SDK version>/WebRTC.xcframework

(the version from PODS/Manifest.lock, so a new WebRTC-SDK needs a new
pin). The same framework serves iPhone and Mac.

Exit status: 1 when the hash differs from its pin, or the framework is not
in PODS. A version without a pin is only a warning (with the line to add)
unless --strict is given: pin it from the official zip (--hash on the
unpacked folder), see the release instructions.

Standard library only.
"""

import argparse
import hashlib
import os
import re
import sys

PINS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "webrtc_sdk.sha256")
POD = "WebRTC-SDK"
FRAMEWORK = "WebRTC.xcframework"
_PIN_LINE = re.compile(r"^([0-9a-f]{64})\s+(\S+)$")
_MANIFEST_LINE = re.compile(r"^\s*-\s+WebRTC-SDK\s+\(([^)\s]+)\)\s*:?\s*$")


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_hash(root):
    """The SHA-256 of the sorted lines `F <path> <sha256>` (files) and
    `L <path> <target>` (symbolic links, never followed) of everything
    under ROOT, paths relative with `/`."""
    lines = []
    for folder, dirs, files in os.walk(root):
        for name in dirs + files:
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            if os.path.islink(path):
                lines.append("L %s %s" % (relative, os.readlink(path)))
            elif os.path.isfile(path):
                lines.append("F %s %s" % (relative, sha256_of(path)))
    lines.sort()
    return hashlib.sha256(("\n".join(lines) + "\n").encode("utf-8")).hexdigest()


def read_pins(path):
    """{key: sha256}; comments (#) and blank lines skipped. A malformed line
    is an error: a pin that is silently ignored would pass anything."""
    pins = {}
    if not os.path.exists(path):
        return pins
    with open(path, encoding="utf-8") as f:
        for number, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match = _PIN_LINE.match(line)
            if match is None:
                raise ValueError("%s:%d: not '<sha256>  <key>'" % (path, number))
            pins[match.group(2)] = match.group(1)
    return pins


def pod_version(pods):
    """The WebRTC-SDK version CocoaPods installed (Manifest.lock), or None."""
    try:
        with open(os.path.join(pods, "Manifest.lock"), encoding="utf-8") as f:
            for raw in f:
                match = _MANIFEST_LINE.match(raw)
                if match:
                    return match.group(1)
    except OSError:
        return None
    return None


def check(pods, pins_path=PINS, strict=False, out=print):
    """Returns the exit status; reports through OUT."""
    pins = read_pins(pins_path)
    version = pod_version(pods)
    framework = os.path.join(pods, POD, FRAMEWORK)
    if version is None or not os.path.isdir(framework):
        out("::error::No %s in %s (Manifest.lock, %s/%s)." % (POD, pods, POD, FRAMEWORK))
        return 1
    key = "%s/%s" % (version, FRAMEWORK)
    actual = tree_hash(framework)
    expected = pins.get(key)
    if expected is None:
        level = "error" if strict else "warning"
        out("::%s::No pinned SHA-256 for %s %s. Pin it from the official zip "
            "(check_webrtc_sdk.py --hash on the unpacked %s) in %s; this build "
            "has:" % (level, POD, version, FRAMEWORK, pins_path))
        out("    %s  %s" % (actual, key))
        return 1 if strict else 0
    if expected != actual:
        out("::error::%s: tree SHA-256 %s, pinned %s (%s). The downloaded "
            "WebRTC is not the one that was checked." % (framework, actual, expected, key))
        return 1
    out("WebRTC-SDK OK: %s (%s)" % (key, actual))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("pods", nargs="?")
    parser.add_argument("--pins", default=PINS)
    parser.add_argument("--strict", action="store_true", help="a version without a pin fails")
    parser.add_argument("--hash", metavar="FRAMEWORK", help="print the tree hash of FRAMEWORK")
    args = parser.parse_args(argv)
    if args.hash:
        if not os.path.isdir(args.hash):
            print("::error::%s is not a folder" % args.hash)
            return 1
        print(tree_hash(args.hash))
        return 0
    if not args.pods:
        parser.error("PODS is required")
    try:
        return check(args.pods, args.pins, args.strict)
    except ValueError as error:
        print("::error::%s" % error)
        return 1


if __name__ == "__main__":
    sys.exit(main())
