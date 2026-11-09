#!/usr/bin/env python3
"""Checks tool/ci/fetch_libwebrtc.py, without the network.

  python3 tool/ci/test_fetch_libwebrtc.py      (from the repository root)

- A download link that answers 504 (as GitHub's did for the 1.16.1
  release) is not the end: the API's link brings the zip.
- A zip with another hash than its pin is never kept.
- A zip already there with the pinned hash is not fetched again.
- No pin, no fetch.

Standard library only.
"""

import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch_libwebrtc  # noqa: E402

VERSION = "libwebrtc.m150.7871.07"
ASSET = "libwebrtc-win-arm64-release.zip"
ZIP = b"PK zip of libwebrtc"
API_ASSET = "https://api.github.com/repos/webrtc-sdk/libwebrtc/releases/assets/1"


class _Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class Opener:
    """Answers each URL as told; counts what was asked."""

    def __init__(self, answers):
        self.answers = answers
        self.asked = []

    def __call__(self, request, timeout=None):
        url = request.full_url
        self.asked.append(url)
        answer = self.answers.get(url)
        if isinstance(answer, Exception):
            raise answer
        if answer is None:
            raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
        return _Response(answer)


def _gateway(url):
    return urllib.error.HTTPError(url, 504, "Gateway Time-out", {}, None)


class FetchTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        self.package = os.path.join(root, "flutter_webrtc")
        os.makedirs(os.path.join(self.package, "third_party"))
        with open(os.path.join(self.package, "third_party", "libwebrtc_version.ini"), "w") as f:
            f.write("[libwebrtc]\nbinary_version = %s\n" % VERSION)
        self.pins = os.path.join(root, "pins")
        with open(self.pins, "w") as f:
            f.write("%s  %s/windows-arm64/%s\n" % (hashlib.sha256(ZIP).hexdigest(), VERSION, ASSET))
        self.dest = os.path.join(self.package, "third_party", "downloads", ASSET)
        self.listing = "https://api.github.com/repos/webrtc-sdk/libwebrtc/releases/tags/" + VERSION
        self.direct = "https://github.com/webrtc-sdk/libwebrtc/releases/download/%s/%s" % (VERSION, ASSET)
        self.lines = []

    def tearDown(self):
        self.dir.cleanup()

    def run_fetch(self, opener, attempts=3):
        return fetch_libwebrtc.fetch(
            "windows-arm64", self.pins, self.package, attempts,
            opener=opener, sleep=lambda s: None, out=self.lines.append)

    def listing_with_asset(self):
        return json.dumps({"assets": [{"name": ASSET, "url": API_ASSET}]}).encode()

    def test_a_download_link_that_times_out_is_not_the_end(self):
        opener = Opener({
            self.listing: self.listing_with_asset(),
            API_ASSET: ZIP,
            self.direct: _gateway(self.direct),
        })
        self.assertEqual(self.run_fetch(opener), 0, self.lines)
        with open(self.dest, "rb") as f:
            self.assertEqual(f.read(), ZIP)

    def test_the_download_link_when_the_api_fails(self):
        opener = Opener({
            self.listing: _gateway(self.listing),
            self.direct: ZIP,
        })
        self.assertEqual(self.run_fetch(opener), 0, self.lines)
        self.assertTrue(os.path.exists(self.dest))

    def test_tried_again_after_a_pause(self):
        calls = {"n": 0}

        class Flaky(Opener):
            def __call__(inner, request, timeout=None):
                if request.full_url == self.direct:
                    calls["n"] += 1
                    if calls["n"] < 3:
                        raise _gateway(self.direct)
                return Opener.__call__(inner, request, timeout)

        opener = Flaky({self.listing: b"{}", self.direct: ZIP})
        self.assertEqual(self.run_fetch(opener, attempts=4), 0, self.lines)
        self.assertEqual(calls["n"], 3)

    def test_another_hash_is_never_kept(self):
        opener = Opener({
            self.listing: self.listing_with_asset(),
            API_ASSET: b"something else",
            self.direct: b"something else",
        })
        self.assertEqual(self.run_fetch(opener), 1)
        self.assertFalse(os.path.exists(self.dest))
        downloads = os.path.dirname(self.dest)
        self.assertEqual(os.listdir(downloads), [], "no part left behind")

    def test_a_pinned_zip_already_there_is_kept(self):
        os.makedirs(os.path.dirname(self.dest))
        with open(self.dest, "wb") as f:
            f.write(ZIP)
        opener = Opener({})
        self.assertEqual(self.run_fetch(opener), 0, self.lines)
        self.assertEqual(opener.asked, [])

    def test_a_wrong_zip_already_there_is_replaced(self):
        os.makedirs(os.path.dirname(self.dest))
        with open(self.dest, "wb") as f:
            f.write(b"tampered")
        opener = Opener({self.listing: b"{}", self.direct: ZIP})
        self.assertEqual(self.run_fetch(opener), 0, self.lines)
        with open(self.dest, "rb") as f:
            self.assertEqual(f.read(), ZIP)

    def test_no_pin_no_fetch(self):
        with open(self.pins, "w") as f:
            f.write("")
        opener = Opener({self.listing: self.listing_with_asset(), API_ASSET: ZIP})
        self.assertEqual(self.run_fetch(opener), 1)
        self.assertEqual(opener.asked, [])


if __name__ == "__main__":
    unittest.main()
