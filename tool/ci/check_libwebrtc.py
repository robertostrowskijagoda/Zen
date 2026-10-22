#!/usr/bin/env python3
"""Checks the libwebrtc that flutter_webrtc downloaded against pinned hashes.

  check_libwebrtc.py [--strict] [--pins FILE] [--package DIR] PLATFORM BUNDLE

  PLATFORM  linux-x64, linux-arm64, windows-x64 or windows-arm64
  BUNDLE    the built app folder (build/linux/x64/release/bundle,
            build/windows/x64/runner/Release)

On Windows and Linux flutter_webrtc's CMake downloads a prebuilt
libwebrtc (a zip from the webrtc-sdk/libwebrtc GitHub releases) without
checking any hash, and that library goes into the signed release. This
script, run after `flutter build`, hashes (SHA-256)

- the libwebrtc.so / libwebrtc.dll in BUNDLE (what ships), and
- the downloaded zip in flutter_webrtc's third_party/downloads, when the
  package folder is found (from .dart_tool/package_config.json, or
  --package),

and compares them with tool/ci/libwebrtc.sha256, whose lines are

  <sha256>  <binary_version>/<platform>/<file name>

(binary_version from the package's third_party/libwebrtc_version.ini, so a
new libwebrtc needs new pins).

Exit status: 1 when a hash differs from its pin, or the library is not in
BUNDLE. A file without a pin is only a warning (with the line to add)
unless --strict is given: the pins are filled in from a build that is
trusted, see the release instructions.

Standard library only.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.parse

PINS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "libwebrtc.sha256")
PLATFORMS = ("linux-x64", "linux-arm64", "windows-x64", "windows-arm64")
_PIN_LINE = re.compile(r"^([0-9a-f]{64})\s+(\S+)$")



def _shown(path):
    """The path relative to the current folder when it can be (on Windows a
    path on another drive cannot), else as it is."""
    try:
        return os.path.relpath(path)
    except ValueError:
        return path

def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_pins(path):
    """{key: sha256} from a pin file; comments (#) and blank lines skipped.

    A malformed line is an error: a pin that is silently ignored would
    pass anything."""
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


def package_dir(root):
    """flutter_webrtc's folder from the pub package config, or None."""
    config = os.path.join(root, ".dart_tool", "package_config.json")
    try:
        with open(config, encoding="utf-8") as f:
            packages = json.load(f).get("packages", [])
    except (OSError, ValueError):
        return None
    for package in packages:
        if package.get("name") != "flutter_webrtc":
            continue
        uri = package.get("rootUri", "")
        parsed = urllib.parse.urlparse(uri)
        if parsed.scheme == "file":
            path = urllib.parse.unquote(parsed.path)
            if os.name == "nt" and re.match(r"^/[A-Za-z]:", path):
                path = path[1:]
            return os.path.normpath(path)
        relative = urllib.parse.unquote(uri)
        return os.path.normpath(os.path.join(os.path.dirname(config), relative))
    return None


def binary_version(package):
    """binary_version from third_party/libwebrtc_version.ini, or None."""
    ini = os.path.join(package, "third_party", "libwebrtc_version.ini")
    try:
        with open(ini, encoding="utf-8") as f:
            for raw in f:
                key, sep, value = raw.partition("=")
                if sep and key.strip() == "binary_version":
                    return value.strip() or None
    except OSError:
        return None
    return None


def library_name(platform):
    return "libwebrtc.dll" if platform.startswith("windows") else "libwebrtc.so"


def asset_name(platform):
    """The release asset flutter_webrtc's CMake downloads for PLATFORM."""
    system, arch = platform.split("-", 1)
    return "libwebrtc-%s-%s-release.zip" % ("win" if system == "windows" else "linux", arch)


def find_library(bundle, name):
    found = []
    for folder, _dirs, files in os.walk(bundle):
        if name in files:
            found.append(os.path.join(folder, name))
    return sorted(found)


def check(platform, bundle, pins_path=PINS, package=None, strict=False, out=print):
    """Returns the exit status; reports through OUT."""
    pins = read_pins(pins_path)
    version = binary_version(package) if package else None
    if version is None:
        version = "unknown"
        out("::warning::flutter_webrtc's libwebrtc_version.ini was not found; "
            "pins are looked up as 'unknown/...'.")
    files = []
    libraries = find_library(bundle, library_name(platform))
    if not libraries:
        out("::error::%s is not in %s." % (library_name(platform), bundle))
        return 1
    files.extend(libraries)
    if package:
        zip_path = os.path.join(package, "third_party", "downloads", asset_name(platform))
        if os.path.isfile(zip_path):
            files.append(zip_path)
    status = 0
    missing = []
    for path in files:
        key = "%s/%s/%s" % (version, platform, os.path.basename(path))
        actual = sha256_of(path)
        expected = pins.get(key)
        if expected is None:
            missing.append("%s  %s" % (actual, key))
        elif expected != actual:
            out("::error::%s: SHA-256 %s, pinned %s (%s). The downloaded libwebrtc "
                "is not the one that was checked." % (path, actual, expected, key))
            status = 1
        else:
            out("libwebrtc OK: %s (%s)" % (key, actual))
    if missing:
        level = "error" if strict else "warning"
        out("::%s::No pinned SHA-256 for %d libwebrtc file(s). After checking "
            "a trusted build, add to %s:" % (level, len(missing), _shown(pins_path)))
        for line in missing:
            out("    " + line)
        if strict:
            status = 1
    return status


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("platform", choices=PLATFORMS)
    parser.add_argument("bundle")
    parser.add_argument("--pins", default=PINS)
    parser.add_argument("--package", help="flutter_webrtc's folder (default: from .dart_tool)")
    parser.add_argument("--strict", action="store_true", help="a file without a pin fails")
    args = parser.parse_args(argv)
    package = args.package or package_dir(os.getcwd())
    try:
        return check(args.platform, args.bundle, args.pins, package, args.strict)
    except ValueError as error:
        print("::error::%s" % error)
        return 1


if __name__ == "__main__":
    sys.exit(main())
