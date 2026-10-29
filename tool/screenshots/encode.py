#!/usr/bin/env python3
"""Turns the rendered frames of the website's pictures into small WebP files.

  python tool/screenshots/encode.py [--raw build/shots] [--out tool/pages/shots]

(from the repository root; needs Pillow; `dart run tool/screenshots.dart`
runs it after rendering). For every language folder of --raw:

- <screen>-<theme>.png -> <out>/<lang>/<screen>-<theme>.webp, lossy WebP at
  the best quality that keeps the file under the limit of shots.dart
  (kShotMaxBytes);
- <film>-<theme>/ (numbered PNG frames and frames.json, how long each one
  shows) -> <out>/<lang>/<film>-<theme>.webp, a looping animated WebP at
  kFilmScale of the size, under kFilmMaxBytes, and
  <film>-<theme>-poster.webp, its last frame, for visitors who asked for
  less motion (under kPosterMaxBytes).

The same frames give the same bytes: no metadata, no dates, fixed encoder
settings.
"""

import argparse
import json
import os
import re
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHOTS_DART = os.path.join(ROOT, "tool", "screenshots", "shots.dart")
QUALITIES = (86, 82, 78, 74, 70, 66, 62, 58, 54, 50, 46, 42)


def constant(name, source):
    """A `const ... name = <expression>;` of shots.dart (numbers, * and .)."""
    m = re.search(r"const \w+ " + name + r" = ([0-9.* ]+);", source)
    if not m:
        sys.exit(f"encode: {name} not found in shots.dart")
    value = 1.0
    for part in m.group(1).split("*"):
        value *= float(part)
    return value


def encode(image, path, limit, **extra):
    """Saves [image] at the best quality that keeps it under [limit] bytes."""
    for quality in QUALITIES:
        image.save(path, "WEBP", quality=quality, method=6, exact=False, **extra)
        if os.path.getsize(path) <= limit:
            return quality
    sys.exit(f"encode: {os.path.relpath(path, ROOT)} stays over {limit} bytes")


def report(path, quality):
    size = os.path.getsize(path)
    print(f"encode: {os.path.relpath(path, ROOT)} {size // 1024} KB (q{quality})")


def picture(src, dst, limit):
    image = Image.open(src).convert("RGB")
    report(dst, encode(image, dst, limit))


def film(folder, dst, poster, scale, limit, poster_limit):
    with open(os.path.join(folder, "frames.json"), encoding="utf-8") as f:
        durations = json.load(f)
    names = sorted(n for n in os.listdir(folder) if n.endswith(".png"))
    if len(names) != len(durations):
        sys.exit(f"encode: {folder}: {len(names)} frames, {len(durations)} durations")
    frames = []
    for name in names:
        image = Image.open(os.path.join(folder, name)).convert("RGB")
        size = (round(image.width * scale), round(image.height * scale))
        frames.append(image.resize(size, Image.LANCZOS))
    quality = encode(frames[0], dst, limit, save_all=True, append_images=frames[1:],
                     duration=durations, loop=0, minimize_size=True,
                     allow_mixed=False)
    report(dst, quality)
    report(poster, encode(frames[-1], poster, poster_limit))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--raw", default=os.path.join(ROOT, "build", "shots"))
    parser.add_argument("--out", default=os.path.join(ROOT, "tool", "pages", "shots"))
    args = parser.parse_args()
    with open(SHOTS_DART, encoding="utf-8") as f:
        source = f.read()
    shot_limit = constant("kShotMaxBytes", source)
    film_limit = constant("kFilmMaxBytes", source)
    poster_limit = constant("kPosterMaxBytes", source)
    scale = constant("kFilmScale", source)
    if not os.path.isdir(args.raw):
        sys.exit(f"encode: nothing rendered in {args.raw}")
    for lang in sorted(os.listdir(args.raw)):
        src = os.path.join(args.raw, lang)
        if not os.path.isdir(src):
            continue
        out = os.path.join(args.out, lang)
        os.makedirs(out, exist_ok=True)
        for name in sorted(os.listdir(src)):
            path = os.path.join(src, name)
            if name.endswith(".png"):
                picture(path, os.path.join(out, name[:-4] + ".webp"), shot_limit)
            elif os.path.isfile(os.path.join(path, "frames.json")):
                film(path, os.path.join(out, name + ".webp"),
                     os.path.join(out, name + "-poster.webp"), scale, film_limit,
                     poster_limit)


if __name__ == "__main__":
    main()
