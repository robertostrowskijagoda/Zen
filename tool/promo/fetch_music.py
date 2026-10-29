#!/usr/bin/env python3
"""Downloads the promo film's music again and cuts the part the film uses.

  python tool/promo/fetch_music.py --ffmpeg path/to/ffmpeg [--dir build/promo/download]

(from the repository root). The track is "Specular City" by vitalezzz,
CC0 1.0 (public domain), from OpenGameArt (MUSIC_LICENSE.md has the
details). The download is checked against its SHA-256; the 45.5 seconds
the film uses (from the start of bar 58 at 130 BPM, where the build-up
before the second drop begins) are written to
tool/promo/music/specular-city-excerpt.m4a, which make_promo.py reads.
Only needed if that file is lost: it is kept in the repository.
"""

import argparse
import hashlib
import os
import subprocess
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
URL = "https://opengameart.org/sites/default/files/specular_city_1.mp3"
SHA256 = "c3865e5435ac38a1a7c5611a674f629b212a912421a95999845e0a4801004ce1"
# The first beat of the track is at 0.4586 s and it is exactly 130 BPM:
# bar 58 starts at 0.4586 + 58 * 4 * 60 / 130 seconds.
START = 107.5355
LENGTH = 45.5
EXCERPT = os.path.join(ROOT, "tool", "promo", "music", "specular-city-excerpt.m4a")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--dir", default=os.path.join(ROOT, "build", "promo", "download"))
    args = parser.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    track = os.path.join(args.dir, "specular_city.mp3")
    if not os.path.isfile(track):
        print(f"fetch_music: downloading {URL}")
        with urllib.request.urlopen(URL, timeout=60) as response, open(track, "wb") as f:
            f.write(response.read())
    with open(track, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != SHA256:
        os.remove(track)
        sys.exit(f"fetch_music: the download is not the expected file ({digest})")
    os.makedirs(os.path.dirname(EXCERPT), exist_ok=True)
    subprocess.run([
        args.ffmpeg, "-v", "error", "-y", "-i", track, "-ss", f"{START}", "-t", f"{LENGTH}",
        "-map_metadata", "-1", "-c:a", "aac", "-b:a", "256k", "-ar", "48000",
        "-movflags", "+faststart", EXCERPT,
    ], check=True)
    print(f"fetch_music: wrote {os.path.relpath(EXCERPT, ROOT)} "
          f"({os.path.getsize(EXCERPT) // 1024} KB)")


if __name__ == "__main__":
    main()
