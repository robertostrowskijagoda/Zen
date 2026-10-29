#!/usr/bin/env python3
"""Reads every printable QR sticker test/qr_sticker_test.dart wrote with
another decoder than the app's own: zbar (zbarimg, from Ubuntu's
zbar-tools). The test writes one PNG per kind of sticker, code style and
logo choice, as printed, and expected.json with what each must say.

    python3 tool/ci/decode_qr_stickers.py build/qr-stickers

Fails when a picture is missing, says something else or nothing at all.
"""

import json
import os
import subprocess
import sys


def decode(path):
    """What zbar reads in the picture at [path] ('' when nothing)."""
    out = subprocess.run(
        ["zbarimg", "--raw", "--quiet", "-Sdisable", "-Sqrcode.enable", path],
        capture_output=True,
        check=False,
    )
    if out.returncode != 0:
        return ""
    return out.stdout.decode("utf-8", "replace").strip()


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    folder = argv[1]
    with open(os.path.join(folder, "expected.json"), encoding="utf-8") as f:
        expected = json.load(f)
    if not expected:
        print("No sticker pictures were written.")
        return 1
    failed = []
    for name, text in sorted(expected.items()):
        path = os.path.join(folder, name)
        if not os.path.isfile(path):
            failed.append(f"{name}: missing")
            continue
        got = decode(path)
        if got != text:
            failed.append(f"{name}: read {got!r}")
    print(f"{len(expected) - len(failed)} of {len(expected)} stickers read back.")
    for line in failed:
        print(f"  {line}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
