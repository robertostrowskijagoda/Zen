# The promo films

A 42-second film about Zen, in Polish and English, for Reels, TikTok and
Shorts (vertical) and for the website and YouTube (horizontal). Every frame
is drawn by `make_promo.py` from the app's real screens; nothing is filmed
or edited by hand, so the films can be made again after the app changes.

## Making them again

From the repository root, with Flutter, Python 3 (Pillow and numpy) and
ffmpeg (libx264, libvpx-vp9, libopus):

```
dart run tool/screenshots.dart                       # the app's screens, into build/shots/
python tool/promo/make_promo.py --ffmpeg <ffmpeg>    # about 15 minutes with 16 cores
```

The films in `tool/pages/promo/` are committed only on a deliberate
re-render (after a visible change worth showing, never as a side effect of
other work): every commit of them adds about 42 MB to the repository's
history for good.

Options: `--lang pl` or `--lang en`, `--format vertical` or
`--format horizontal`, `--sheets-only` (only the masters and contact sheets,
for a quick look), `--frame 12.5` (one frame of each film at that second,
into `build/promo/`), `--no-check`, `--jobs N`.

What it writes:

| File | What |
|---|---|
| `tool/pages/promo/zen-promo-<lang>.mp4` | 1080 × 1920, H.264 High, yuv420p, faststart, AAC; about 10 MB |
| `tool/pages/promo/zen-promo-<lang>-16x9.mp4` | the same at 1920 × 1080 |
| `tool/pages/promo/zen-promo-<lang>.webm` | the vertical film in VP9 and Opus, for browsers without H.264 |
| `tool/pages/promo/zen-promo-poster-<lang>.jpg` | the end card, for a page to show before playing |
| `build/promo/master/` | high quality masters (CRF 12, no sound), not committed |
| `build/promo/contact-<lang>-<format>.png` | one frame every 2 seconds, to look the film over |
| `build/promo/check/` | the end card as encoded, read back by `qr_test.dart` |

The sound is the music alone, faded out over the last 3 seconds and
normalised to -14 LUFS (two-pass loudnorm). At the end the script runs
`flutter test tool/promo/qr_test.dart`, which reads the QR code of every
encoded end card with the decoder the app uses for camera pictures and
fails unless it gives the About page,
`https://robertostrowskijagoda.github.io/Zen/about/`. The same test writes
`qr-about.txt`, the code's modules, which the script draws.

## How the film is built

The music is 93.33 BPM; the film is 23 bars of it (59.1 s) and every cut,
word and pop lands on a beat. `TIMELINE` in `make_promo.py` gives each card
its bars, `TEXTS` every line in both languages:

| Bars | Seconds | Card |
|---|---|---|
| 0–1 | 0.0–5.1 | Hook: "Your messages. Your photos. Not theirs." |
| 2–5 | 5.1–15.4 | Big apps: ads, an algorithm picks what you see, a company reads what you write, "Enough." (grey, glitches on the beats) |
| 6–7 | 15.4–20.6 | The drop: white flash, the logo, "A private social network for people who know each other." and a message being sent |
| 8–13 | 20.6–36.0 | No ads, no algorithms · no company reads your messages · post-quantum encryption · no sign-up, no phone number · your data stays with you · free and open source |
| 14–18 | 36.0–48.9 | Your circle (feed, groups, chats) · posts for the people you choose · the friend graph growing · meeting people through people · audio and video calls |
| 19–22 | 48.9–59.1 | End card: logo, the line, "No servers of its own. No ads. No algorithms.", the QR code and the address |

Every claim follows `README.md` and `docs/guide`; change a line there first
if the app changes. Colours come from `tool/pages/site.css`, type from
`assets/fonts` (Hanken Grotesk, Space Mono), icons from the Material Icons
font of Flutter, the logo from `assets/branding/logo.jpg`. The phones, the
laptop, the background and the end card are drawn in code.

## The music

"Ancient Memories" by HoliznaCC0, CC0 1.0 (public domain):
[MUSIC_LICENSE.md](MUSIC_LICENSE.md). `music/ancient-memories-excerpt.m4a`
is the part the film uses; `fetch_music.py` downloads the track again,
checks its SHA-256 and cuts the same part, if it is ever needed.
