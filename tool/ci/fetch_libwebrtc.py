#!/usr/bin/env python3
"""Fetches the libwebrtc that flutter_webrtc's CMake would download, before
`flutter build`, and checks it against its pin.

  fetch_libwebrtc.py [--pins FILE] [--package DIR] [--attempts N] PLATFORM

  PLATFORM  linux-x64, linux-arm64, windows-x64 or windows-arm64

flutter_webrtc's CMake downloads the prebuilt libwebrtc (a release asset of
webrtc-sdk/libwebrtc) once, from the release's download link, with no retry,
and only when the zip is not in its third_party/downloads yet. On the 1.16.1
release GitHub answered that link with "504 Gateway Time-out" for hours for
the Windows ARM64 zip while the API's link to the same asset served it, and
both Windows builds failed. This script fetches the zip into the place CMake
looks first, trying the API's link and the download link in turn, several
times with growing pauses, and keeps it only when its SHA-256 is the pin in
tool/ci/libwebrtc.sha256 (so the library is checked before it is built in,
not only after). GITHUB_TOKEN, when set, goes with the API's requests (the
runners share their address, and the API limits requests without one).

Exit status: 0 when the zip is in place with the pinned hash (also when it
was there already); 1 otherwise.

Standard library only.
"""

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_libwebrtc  # noqa: E402

REPO = "webrtc-sdk/libwebrtc"
TIMEOUT = 120


def _request(url, token=None, accept=None):
    request = urllib.request.Request(url, headers={"User-Agent": "zen-release-ci"})
    if accept:
        request.add_header("Accept", accept)
    if token and url.startswith("https://api.github.com/"):
        request.add_header("Authorization", "Bearer " + token)
    return request


def api_asset_url(version, asset, token=None, opener=urllib.request.urlopen):
    """The API's link to the release asset, or None when it is not listed."""
    url = "https://api.github.com/repos/%s/releases/tags/%s" % (REPO, version)
    with opener(_request(url, token, "application/vnd.github+json"), timeout=TIMEOUT) as r:
        release = json.load(r)
    for a in release.get("assets", []):
        if a.get("name") == asset:
            return a.get("url")
    return None


def _download(request, dest, opener):
    with opener(request, timeout=TIMEOUT) as r, open(dest, "wb") as f:
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            f.write(block)


def fetch(platform, pins_path=check_libwebrtc.PINS, package=None, attempts=6,
          token=None, opener=urllib.request.urlopen, sleep=time.sleep, out=print):
    if platform not in check_libwebrtc.PLATFORMS:
        out("unknown platform %s" % platform)
        return 1
    package = package or check_libwebrtc.package_dir(os.getcwd())
    if package is None:
        out("flutter_webrtc not found (run flutter pub get first)")
        return 1
    version = check_libwebrtc.binary_version(package)
    if version is None:
        out("no binary_version in %s" % package)
        return 1
    asset = check_libwebrtc.asset_name(platform)
    key = "%s/%s/%s" % (version, platform, asset)
    pin = check_libwebrtc.read_pins(pins_path).get(key)
    if pin is None:
        out("no pin for %s in %s: add it from a trusted download first" % (key, pins_path))
        return 1
    downloads = os.path.join(package, "third_party", "downloads")
    dest = os.path.join(downloads, asset)
    if os.path.exists(dest):
        if check_libwebrtc.sha256_of(dest) == pin:
            out("%s: there already, as pinned" % asset)
            return 0
        os.remove(dest)
    os.makedirs(downloads, exist_ok=True)
    direct = "https://github.com/%s/releases/download/%s/%s" % (REPO, version, asset)
    pause = 5
    for attempt in range(1, attempts + 1):
        sources = []
        try:
            api = api_asset_url(version, asset, token, opener)
            if api:
                sources.append(("api", _request(api, token, "application/octet-stream")))
        except (urllib.error.URLError, OSError, ValueError) as error:
            out("attempt %d: the release's listing failed: %s" % (attempt, error))
        sources.append(("download link", _request(direct)))
        for name, request in sources:
            fd, temporary = tempfile.mkstemp(dir=downloads, suffix=".part")
            os.close(fd)
            try:
                _download(request, temporary, opener)
                got = check_libwebrtc.sha256_of(temporary)
                if got != pin:
                    out("attempt %d, %s: SHA-256 %s, pinned %s" % (attempt, name, got, pin))
                    continue
                os.replace(temporary, dest)
                out("%s: fetched through the %s, as pinned (%s)" % (asset, name, pin))
                return 0
            except (urllib.error.URLError, OSError) as error:
                out("attempt %d, %s: %s" % (attempt, name, error))
            finally:
                if os.path.exists(temporary):
                    os.remove(temporary)
        if attempt < attempts:
            sleep(pause)
            pause = min(pause * 2, 60)
    out("%s: not fetched after %d attempts" % (asset, attempts))
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("platform", choices=check_libwebrtc.PLATFORMS)
    parser.add_argument("--pins", default=check_libwebrtc.PINS)
    parser.add_argument("--package")
    parser.add_argument("--attempts", type=int, default=6)
    args = parser.parse_args(argv)
    return fetch(args.platform, args.pins, args.package, args.attempts,
                 token=os.environ.get("GITHUB_TOKEN") or None)


if __name__ == "__main__":
    sys.exit(main())
