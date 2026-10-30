#!/usr/bin/env python3
"""Downloads the promo film's music again and cuts the part the film uses.

  python tool/promo/fetch_music.py --ffmpeg path/to/ffmpeg [--dir build/promo/download]

(from the repository root). The track is "Ancient Memories" by
HoliznaCC0, CC0 1.0 (public domain), from the Free Music Archive
(MUSIC_LICENSE.md has the details). The download is checked against its
SHA-256; the 62.5 seconds the film uses (from its first beat, at 93.33 BPM)
are written to tool/promo/music/ancient-memories-excerpt.m4a, which
make_promo.py reads. Only needed if that file is lost: it is kept in the
repository.
"""

import argparse
import hashlib
import os
import subprocess
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
URL = "https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/ryt7QGXtRyVCxGpToytgi0HYkoEjPG4tE3aer1sr.mp3"
SHA256 = "a4f1d0e515c8d800862812a125cf6979649acad3bb5c14e4e91113e32038c09f"
# The first beat of the track is at 0.20 s, at 93.33 BPM.
START = 0.20
LENGTH = 62.5
EXCERPT = os.path.join(ROOT, "tool", "promo", "music", "ancient-memories-excerpt.m4a")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--dir", default=os.path.join(ROOT, "build", "promo", "download"))
    args = parser.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    track = os.path.join(args.dir, "ancient-memories.mp3")
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
