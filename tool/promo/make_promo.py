#!/usr/bin/env python3
"""Renders Zen's promo films from the app's own screens.

  python tool/promo/make_promo.py [--ffmpeg path/to/ffmpeg] [--lang pl,en]
                                  [--format vertical,horizontal] [--sheets-only]
                                  [--no-check] [--jobs N]

(from the repository root; needs Python 3 with Pillow and numpy, ffmpeg with
libx264, libvpx-vp9 and libopus, and the app's screens in build/shots/,
which `dart run tool/screenshots.dart` renders). Every frame is drawn here
(kinetic type, phone and laptop frames, the background, the end card) on
a grid of the music's beats: 130 BPM, 23 bars. The frames go
straight into ffmpeg as a high quality master (build/promo/master/), and
from the masters come the files of the website, tool/pages/promo/:

  zen-promo-<lang>.mp4         1080x1920 (Reels, TikTok, Shorts)
  zen-promo-<lang>-16x9.mp4    1920x1080
  zen-promo-<lang>.webm        1080x1920, VP9 and Opus
  zen-promo-poster-<lang>.jpg  the end card, for the page before playing
  zen-promo-<lang>.vtt         captions

H.264 High, yuv420p, faststart, two passes at a bitrate that keeps each
file under 8 MB; the sound is normalised to -14 LUFS. Contact sheets (one
frame every 2 seconds) for checking the films by eye are left in
build/promo/, and the end card frames in build/promo/check/, which
`flutter test tool/promo/qr_test.dart` reads back (run at the end unless
--no-check).
"""

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
from functools import lru_cache
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHOTS = os.path.join(ROOT, "build", "shots")
BUILD = os.path.join(ROOT, "build", "promo")
OUT = os.path.join(ROOT, "tool", "pages", "promo")
MUSIC = os.path.join(ROOT, "tool", "promo", "music", "specular-city-excerpt.m4a")
QR_FILE = os.path.join(ROOT, "tool", "promo", "qr-about.txt")
FONTS = os.path.join(ROOT, "assets", "fonts")
LOGO = os.path.join(ROOT, "assets", "branding", "logo.jpg")

# The music: "Specular City" (vitalezzz, CC0), 130 BPM; the excerpt starts
# on a downbeat, the build-up before the drop, which comes on bar 6.
BPM = 130.0
BEAT = 60.0 / BPM
BAR = 4 * BEAT
BARS = 23
FPS = 30
DURATION = BARS * BAR
FRAMES = int(round(DURATION * FPS))
FADE_OUT = 3.0
LOUDNESS = -14.0

# The site's colours (tool/pages/site.css, dark theme).
BG = (11, 10, 16)
CARD = (22, 20, 31)
TEXT = (243, 241, 250)
MUTED = (166, 161, 186)
LINE = (42, 39, 56)
LINK = (185, 162, 255)
VIOLET = (109, 61, 245)
MAGENTA = (176, 31, 196)
PINK = (240, 110, 220)
GREY = (120, 116, 136)

FORMATS = {"vertical": (1080, 1920), "horizontal": (1920, 1080)}
LANGS = ("pl", "en")

# -- What the film says --------------------------------------------------------
#
# Facts follow README.md and docs/guide: no ads and no algorithm, no company
# in the middle (messages go straight between friends' devices; Zen has no
# servers of its own, only public relay nodes that see nothing of the
# content), ML-KEM-768 + X25519 and Ed25519 + ML-DSA-65, no sign-up and no
# phone number (the QR code is the address), the data encrypted on
# the device with the user's password, GPL-3.0 and five systems, the feed,
# groups and chats, posts for chosen people, the friend graph with its
# timeline, introductions through friends, audio and video calls with screen
# sharing.

TEXTS = {
    "pl": {
        "hook": ["Twoje wiadomości.", "Twoje zdjęcia.", "Nie ich."],
        "big_apps": "WIELKIE APLIKACJE",
        "problems": ["Reklamy.", "Algorytm decyduje, co widzisz.", "Firma czyta, co piszesz.", "Dość."],
        "drop": ["Prywatna sieć społecznościowa", "dla ludzi, którzy się znają."],
        "answers": [
            ("Bez reklam.|Bez algorytmów.", "Nikt nie decyduje za Ciebie, co zobaczysz."),
            ("Żadna firma nie czyta Twoich wiadomości.", "Prosto między telefonami znajomych."),
            ("Szyfrowanie postkwantowe.", "ML-KEM-768 + X25519 · Ed25519 + ML-DSA-65"),
            ("Bez rejestracji.|Bez numeru telefonu.", "Twój kod QR to Twój adres."),
            ("Twoje dane zostają u Ciebie.", "Zaszyfrowane Twoim hasłem."),
            ("Za darmo.|Otwarty kod.", "Android · iPhone · Windows · Mac · Linux"),
        ],
        "circle": [
            ("Twój krąg.", "Tablica · Grupy · Czaty"),
            ("Posty tylko dla wybranych.", "Ty decydujesz, kto co widzi."),
            ("Graf znajomych.", "Kto zna kogo, z osią czasu."),
            ("Poznawaj przez znajomych.", "Przedstawienia przez ludzi, których znasz."),
            ("Rozmowy audio i wideo.", "Także z udostępnianiem ekranu."),
        ],
        "end_title": "Zen — prywatna sieć społecznościowa dla ludzi, którzy się znają.",
        "end_tagline": "Bez własnych serwerów. Bez reklam. Bez algorytmów.",
        "end_get": "Pobierz:",
        "end_url": "robertostrowskijagoda.github.io/Zen",
        "qr_card": "Twój adres",
        "music": "Muzyka: „Specular City”, vitalezzz (CC0)",
    },
    "en": {
        "hook": ["Your messages.", "Your photos.", "Not theirs."],
        "big_apps": "BIG APPS",
        "problems": ["Ads.", "An algorithm picks what you see.", "A company reads what you write.", "Enough."],
        "drop": ["A private social network", "for people who know each other."],
        "answers": [
            ("No ads.|No algorithms.", "Nobody decides for you what you see."),
            ("No company reads your messages.", "Straight between your friends' phones."),
            ("Post-quantum encryption.", "ML-KEM-768 + X25519 · Ed25519 + ML-DSA-65"),
            ("No sign-up.|No phone number.", "Your QR code is your address."),
            ("Your data stays with you.", "Encrypted with your password."),
            ("Free.|Open source.", "Android · iPhone · Windows · Mac · Linux"),
        ],
        "circle": [
            ("Your circle.", "Feed · Groups · Chats"),
            ("Posts only for the people you choose.", "You decide who sees what."),
            ("The friend graph.", "Who knows whom, with a timeline."),
            ("Meet people through people.", "Introductions through friends you trust."),
            ("Audio and video calls.", "Screen sharing included."),
        ],
        "end_title": "Zen — a private social network for people who know each other.",
        "end_tagline": "No servers of its own. No ads. No algorithms.",
        "end_get": "Download:",
        "end_url": "robertostrowskijagoda.github.io/Zen",
        "qr_card": "Your address",
        "music": "Music: “Specular City” by vitalezzz (CC0)",
    },
}

# The cards on the timeline: (first bar, bars, kind, index).
TIMELINE = [
    (0, 2, "hook", 0),
    (2, 1, "problem", 0),
    (3, 1, "problem", 1),
    (4, 1, "problem", 2),
    (5, 1, "problem", 3),
    (6, 1, "drop", 0),
    (7, 1, "drop", 1),
    (8, 1, "answer", 0),
    (9, 1, "answer", 1),
    (10, 1, "answer", 2),
    (11, 1, "answer", 3),
    (12, 1, "answer", 4),
    (13, 1, "answer", 5),
    (14, 1, "circle", 0),
    (15, 1, "circle", 1),
    (16, 1, "circle", 2),
    (17, 1, "circle", 3),
    (18, 1, "circle", 4),
    (19, 4, "end", 0),
]


def card_at(t):
    bar = t / BAR
    for first, bars, kind, index in TIMELINE:
        if first <= bar < first + bars:
            return first, bars, kind, index
    return TIMELINE[-1]


def captions(lang):
    """(start, end, text) of every card, for the .vtt file."""
    tx = TEXTS[lang]
    cues = []
    for first, bars, kind, index in TIMELINE:
        if kind == "hook":
            text = " ".join(tx["hook"])
        elif kind == "problem":
            text = (tx["big_apps"].capitalize() + ": " if index == 0 else "") + tx["problems"][index]
        elif kind == "drop":
            text = ("Zen. " if index == 0 else "") + tx["drop"][index]
        elif kind in ("answer", "circle"):
            head, sub = tx["answers" if kind == "answer" else "circle"][index]
            text = head.replace("|", " ") + " " + sub
        else:
            text = (f"{tx['end_title']} {tx['end_tagline']} "
                    f"{tx['end_get']} {tx['end_url']}\n[{tx['music']}]")
        cues.append((first * BAR, (first + bars) * BAR, text))
    return cues


def vtt_time(s):
    ms = int(round(s * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"


def write_vtt(lang, path):
    lines = ["WEBVTT", ""]
    for i, (a, b, text) in enumerate(captions(lang), 1):
        lines += [str(i), f"{vtt_time(a)} --> {vtt_time(b)}", text, ""]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


# -- Small helpers -------------------------------------------------------------


def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def ease_out(p):
    p = clamp(p)
    return 1 - (1 - p) ** 3


def ease_in_out(p):
    p = clamp(p)
    return 4 * p ** 3 if p < 0.5 else 1 - (-2 * p + 2) ** 3 / 2


def ease_back(p):
    p = clamp(p)
    c = 1.70158
    return 1 + (c + 1) * (p - 1) ** 3 + c * (p - 1) ** 2


def mix(a, b, p):
    return tuple(int(round(x + (y - x) * p)) for x, y in zip(a, b))


def pulse(t, every=BEAT, decay=0.13):
    """1 on every beat, falling off quickly."""
    if t < 0:
        return 0.0
    return math.exp(-(t % every) / decay)


@lru_cache(maxsize=None)
def font(kind, size):
    size = max(8, int(size))
    if kind == "mono":
        return ImageFont.truetype(os.path.join(FONTS, "SpaceMono-Bold.ttf"), size)
    f = ImageFont.truetype(os.path.join(FONTS, "HankenGrotesk-Variable.ttf"), size)
    f.set_variation_by_axes([{"black": 900, "bold": 760, "semi": 620}[kind]])
    return f


def gradient(w, h, a=LINK, b=PINK, vertical=False):
    n = h if vertical else w
    ramp = np.linspace(0, 1, max(n, 1))[:, None]
    row = (np.array(a)[None, :] * (1 - ramp) + np.array(b)[None, :] * ramp).astype(np.uint8)
    if vertical:
        arr = np.repeat(row[:, None, :], w, axis=1)
    else:
        arr = np.repeat(row[None, :, :], h, axis=0)
    return Image.fromarray(arr, "RGB")


@lru_cache(maxsize=4096)
def word_sprite(text, kind, size, fill):
    """[text] as an RGBA picture: line height high, baseline at the ascent."""
    f = font(kind, size)
    ascent, descent = f.getmetrics()
    w = int(math.ceil(f.getlength(text))) + 8
    h = ascent + descent + 4
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).text((4, ascent + 2), text, font=f, fill=255, anchor="ls")
    if fill == "grad":
        color = gradient(w, h)
    else:
        color = Image.new("RGB", (w, h), fill)
    color.putalpha(mask)
    return color


def wrap(text, kind, size, max_w):
    f = font(kind, size)
    lines = []
    for para in text.split("|"):
        line = ""
        for word in para.split(" "):
            trial = (line + " " + word).strip()
            if line and f.getlength(trial) > max_w:
                lines.append(line)
                line = word
            else:
                line = trial
        lines.append(line)
    return lines


def fit(text, kind, max_w, max_size, min_size, max_lines):
    """The largest size (and its lines) at which [text] fits."""
    size = max_size
    while size > min_size:
        lines = wrap(text, kind, size, max_w)
        f = font(kind, size)
        if len(lines) <= max_lines and all(f.getlength(l) <= max_w for l in lines):
            return size, lines
        size -= 2
    return min_size, wrap(text, kind, min_size, max_w)


class Words:
    """A block of text laid out word by word, which rises into place."""

    def __init__(self):
        self.items = []  # (sprite, x, y, delay)
        self.height = 0

    def add(self, text, kind, size, fill, x, y, max_w, max_lines, delay=0.0,
            stagger=0.045, align="left", line_gap=1.0, min_size=None):
        size, lines = fit(text, kind, max_w, size, min_size or int(size * 0.5), max_lines)
        f = font(kind, size)
        ascent, descent = f.getmetrics()
        lh = int((ascent + descent) * line_gap)
        space = f.getlength(" ")
        n = 0
        for i, line in enumerate(lines):
            words = line.split(" ")
            widths = [f.getlength(w) for w in words]
            total = sum(widths) + space * (len(words) - 1)
            cx = x if align == "left" else x + (max_w - total) / 2
            for word, ww in zip(words, widths):
                self.items.append((word_sprite(word, kind, size, fill), int(cx) - 4,
                                   int(y + i * lh) - 2, delay + n * stagger))
                cx += ww + space
                n += 1
        bottom = y + len(lines) * lh
        self.height = max(self.height, bottom)
        return bottom

    def draw(self, cv, t, rise=0.34, dx=0, dy=0):
        for sprite, x, y, delay in self.items:
            p = ease_out((t - delay) / rise)
            if p <= 0:
                continue
            w, h = sprite.size
            shift = int(round((1 - p) * h))
            if shift >= h:
                continue
            part = sprite if shift == 0 else sprite.crop((0, 0, w, h - shift))
            cv.alpha_composite(part, (x + dx, y + shift + dy))


# -- Pictures ------------------------------------------------------------------


@lru_cache(maxsize=None)
def screenshot(lang, name):
    path = os.path.join(SHOTS, lang, name + ".png")
    if not os.path.isfile(path):
        sys.exit(f"make_promo: {os.path.relpath(path, ROOT)} is missing: "
                 "run `dart run tool/screenshots.dart` first")
    return Image.open(path).convert("RGB")


@lru_cache(maxsize=None)
def film(lang, name):
    folder = os.path.join(SHOTS, lang, name)
    with open(os.path.join(folder, "frames.json"), encoding="utf-8") as f:
        durations = json.load(f)
    names = sorted(n for n in os.listdir(folder) if n.endswith(".png"))
    return durations, [os.path.join(folder, n) for n in names]


@lru_cache(maxsize=8)
def film_frame(path):
    return Image.open(path).convert("RGB")


@lru_cache(maxsize=128)
def resized_shot(lang, name, w, h):
    return screenshot(lang, name).resize((w, h), Image.LANCZOS)


@lru_cache(maxsize=256)
def resized_film_frame(path, w, h):
    return film_frame(path).resize((w, h), Image.LANCZOS)


def view(src_small, sw, sh, zoom=1.0, focus=(0.5, 0.5)):
    """A window of [src_small] (sized sw*Z x sh*Z) at [zoom], shown at sw x sh."""
    bw, bh = src_small.size
    cw, ch = sw / zoom * (bw / sw), sh / zoom * (bh / sh)
    fx, fy = focus
    x0 = clamp(fx * bw - cw / 2, 0, bw - cw)
    y0 = clamp(fy * bh - ch / 2, 0, bh - ch)
    box = (x0, y0, x0 + cw, y0 + ch)
    if abs(cw - sw) < 0.5 and abs(ch - sh) < 0.5 and x0 == int(x0) and y0 == int(y0):
        return src_small.crop(tuple(int(v) for v in box))
    return src_small.resize((sw, sh), Image.BILINEAR, box=box)


ZMAX = 1.35


def shot_view(lang, name, sw, sh, zoom=1.0, focus=(0.5, 0.5)):
    base = resized_shot(lang, name, int(sw * ZMAX), int(sh * ZMAX))
    return view(base, sw, sh, zoom, focus)


def film_view(lang, name, ms, sw, sh, zoom=1.0, focus=(0.5, 0.5)):
    durations, paths = film(lang, name)
    at, path = 0, paths[-1]
    for d, p in zip(durations, paths):
        at += d
        if ms < at:
            path = p
            break
    base = resized_film_frame(path, int(sw * ZMAX), int(sh * ZMAX))
    return view(base, sw, sh, zoom, focus)


def rounded_mask(w, h, r, scale=3):
    big = Image.new("L", (w * scale, h * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, w * scale - 1, h * scale - 1), r * scale, fill=255)
    return big.resize((w, h), Image.LANCZOS)


@lru_cache(maxsize=None)
def phone_parts(sh):
    """A phone body for a screen [sh] pixels high, its screen mask and its shadow."""
    sw = int(round(sh * 1080 / 2340))
    pad = max(6, int(round(sw * 0.035)))
    bw, bh = sw + 2 * pad, sh + 2 * pad
    rb = int(round(sw * 0.13))
    rs = rb - pad
    body = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    edge = Image.new("RGBA", (bw, bh), (88, 80, 118, 255))
    body.paste(edge, (0, 0), rounded_mask(bw, bh, rb))
    inner = Image.new("RGBA", (bw - 4, bh - 4), (24, 22, 32, 255))
    body.paste(inner, (2, 2), rounded_mask(bw - 4, bh - 4, rb - 2))
    black = Image.new("RGBA", (sw + pad, sh + pad), (4, 4, 6, 255))
    body.paste(black, (pad // 2, pad // 2), rounded_mask(sw + pad, sh + pad, rs + pad // 2))
    mask = rounded_mask(sw, sh, rs)
    margin = max(30, int(bh * 0.04))
    shadow = Image.new("RGBA", (bw + 2 * margin, bh + 2 * margin), (0, 0, 0, 0))
    sd = Image.new("RGBA", (bw, bh), (0, 0, 0, 170))
    shadow.paste(sd, (margin, margin), rounded_mask(bw, bh, rb))
    shadow = shadow.filter(ImageFilter.GaussianBlur(margin / 2.2))
    # A faint sheen across the glass.
    sheen = gradient(sw, sh, (255, 255, 255), (255, 255, 255)).convert("RGBA")
    ramp = np.clip(np.linspace(1.0, -0.6, sw)[None, :] + np.linspace(0, -0.5, sh)[:, None], 0, 1)
    alpha = (ramp * 16).astype(np.uint8)
    alpha = np.minimum(alpha, np.array(mask))
    sheen.putalpha(Image.fromarray(alpha, "L"))
    cam = max(8, int(sw * 0.028))
    return {"sw": sw, "sh": sh, "pad": pad, "body": body, "mask": mask, "shadow": shadow,
            "margin": margin, "sheen": sheen, "cam": cam}


def phone(screen, sh):
    """[screen] (sw x sh) in a phone body: an RGBA picture."""
    p = phone_parts(sh)
    out = p["body"].copy()
    out.paste(screen, (p["pad"], p["pad"]), p["mask"])
    out.alpha_composite(p["sheen"], (p["pad"], p["pad"]))
    d = ImageDraw.Draw(out)
    cx, cy, r = out.width // 2, p["pad"] + int(p["sw"] * 0.045), p["cam"] // 2
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(2, 2, 4, 255))
    return out


def place(cv, sprite, cx, cy, shadow=None, margin=0, angle=0.0, scale=1.0, alpha=1.0):
    """[sprite] centred at (cx, cy), turned by [angle] degrees and scaled, with its shadow."""
    if scale != 1.0:
        sprite = sprite.resize((max(1, int(sprite.width * scale)), max(1, int(sprite.height * scale))),
                               Image.BILINEAR)
        if shadow is not None:
            shadow = shadow.resize((max(1, int(shadow.width * scale)), max(1, int(shadow.height * scale))),
                                   Image.BILINEAR)
    if angle:
        sprite = sprite.rotate(angle, Image.BICUBIC, expand=True)
        if shadow is not None:
            shadow = shadow.rotate(angle, Image.BICUBIC, expand=True)
    if alpha < 1.0:
        a = sprite.getchannel("A").point(lambda v: int(v * alpha))
        sprite = sprite.copy()
        sprite.putalpha(a)
        if shadow is not None:
            a = shadow.getchannel("A").point(lambda v: int(v * alpha))
            shadow = shadow.copy()
            shadow.putalpha(a)
    if shadow is not None:
        sx = int(cx - shadow.width / 2)
        sy = int(cy - shadow.height / 2 + sprite.height * 0.025)
        paste_clipped(cv, shadow, sx, sy)
    paste_clipped(cv, sprite, int(cx - sprite.width / 2), int(cy - sprite.height / 2))


def paste_clipped(cv, sprite, x, y):
    w, h = cv.size
    if x >= w or y >= h or x + sprite.width <= 0 or y + sprite.height <= 0:
        return
    l, t = max(0, -x), max(0, -y)
    r, b = min(sprite.width, w - x), min(sprite.height, h - y)
    part = sprite if (l, t, r, b) == (0, 0, sprite.width, sprite.height) else sprite.crop((l, t, r, b))
    cv.alpha_composite(part, (x + l, y + t))


@lru_cache(maxsize=None)
def logo(width, fill="white"):
    """The Zen logo (assets/branding/logo.jpg) as a cut-out, [width] wide."""
    src = Image.open(LOGO).convert("L")
    arr = np.asarray(src).astype(np.float32)
    alpha = np.clip((arr - 40) / (230 - 40), 0, 1)
    ys, xs = np.where(alpha > 0.5)
    box = (xs.min() - 6, ys.min() - 6, xs.max() + 7, ys.max() + 7)
    a = Image.fromarray((alpha * 255).astype(np.uint8), "L").crop(box)
    h = int(round(a.height * width / a.width))
    a = a.resize((width, h), Image.LANCZOS)
    color = gradient(width, h, (255, 255, 255), (232, 222, 255)) if fill == "white" else gradient(width, h)
    out = color.convert("RGBA")
    out.putalpha(a)
    return out


# Material Icons (Apache-2.0), the font Flutter ships and the app draws its
# icons with; code points of Flutter's Icons class (the rounded ones).
ICONS = {"call": 0xF608, "videocam": 0xF027E, "screen_share": 0xF0136, "lock": 0xF889,
         "visibility": 0xF0293, "campaign": 0xF614}


@lru_cache(maxsize=None)
def icon_font(size):
    root = os.environ.get("FLUTTER_ROOT")
    if not root:
        flutter = shutil.which("flutter")
        if not flutter:
            sys.exit("make_promo: Flutter not found (set FLUTTER_ROOT): its Material Icons font is needed")
        root = os.path.dirname(os.path.dirname(os.path.realpath(flutter)))
    return ImageFont.truetype(os.path.join(root, "bin", "cache", "artifacts", "material_fonts",
                                           "materialicons-regular.otf"), size)


@lru_cache(maxsize=None)
def icon(name, size, color=(255, 255, 255)):
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(out).text((size // 2, size // 2), chr(ICONS[name]), font=icon_font(size),
                             fill=color + (255,), anchor="mm")
    return out


@lru_cache(maxsize=None)
def qr_modules():
    with open(QR_FILE, encoding="utf-8") as f:
        rows = [line.strip() for line in f if line.strip()]
    return [[c == "#" for c in row] for row in rows]


@lru_cache(maxsize=None)
def qr_tile(module, dark=BG, light=(255, 255, 255), quiet=4, radius=None):
    rows = qr_modules()
    n = len(rows)
    size = (n + 2 * quiet) * module
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg = Image.new("RGBA", (size, size), light + (255,))
    tile.paste(bg, (0, 0), rounded_mask(size, size, radius if radius is not None else module * 2))
    d = ImageDraw.Draw(tile)
    for y, row in enumerate(rows):
        for x, on in enumerate(row):
            if on:
                x0, y0 = (x + quiet) * module, (y + quiet) * module
                d.rectangle((x0, y0, x0 + module - 1, y0 + module - 1), fill=dark + (255,))
    return tile


@lru_cache(maxsize=None)
def dot_grid(w, h, step):
    tile = Image.new("RGBA", (w + step, h + step), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    for y in range(0, h + step, step):
        for x in range(0, w + step, step):
            d.ellipse((x - 1.4, y - 1.4, x + 1.4, y + 1.4), fill=(200, 190, 255, 26))
    return tile


@lru_cache(maxsize=None)
def coords(w, h, step):
    ys, xs = np.mgrid[0:h:step, 0:w:step].astype(np.float32)
    return xs, ys


def background(w, h, t, brand):
    """The moving glow behind everything; [brand] 0 is grey, 1 is the brand's colours."""
    step = 8
    xs, ys = coords(w, h, step)
    out = np.zeros(xs.shape + (3,), np.float32) + np.array(BG, np.float32)
    beat = pulse(t) * 0.25 + pulse(t, BAR, 0.3) * 0.35
    m = max(w, h)
    blobs = [
        (0.25 + 0.12 * math.sin(t * 0.37), 0.22 + 0.08 * math.cos(t * 0.29), 0.55, VIOLET, 0.55),
        (0.80 + 0.10 * math.cos(t * 0.31), 0.75 + 0.10 * math.sin(t * 0.23), 0.50, MAGENTA, 0.42),
        (0.55 + 0.20 * math.sin(t * 0.19 + 1.0), 0.50 + 0.15 * math.cos(t * 0.41), 0.35, LINK, 0.18),
    ]
    for bx, by, r, color, a in blobs:
        c = mix((70, 66, 84), color, brand)
        d2 = ((xs - bx * w) ** 2 + (ys - by * h) ** 2) / (r * m) ** 2
        k = np.exp(-d2 * 2.2) * a * (0.55 + 0.45 * brand) * (1 + beat)
        out += k[..., None] * np.array(c, np.float32)
    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB").resize((w, h), Image.BILINEAR)
    cv = img.convert("RGBA")
    grid = dot_grid(w, h, 46)
    off = int(t * 18) % 46
    cv.alpha_composite(grid.crop((off, off, off + w, off + h)))
    return cv


# -- The layout of each format -------------------------------------------------


def layout(fmt):
    w, h = FORMATS[fmt]
    if fmt == "vertical":
        return {
            "w": w, "h": h,
            "text": (84, 250, w - 168),     # x, top, width of the text column
            "head": 104, "sub": 46, "label": 34, "head_lines": 3,
            "visual": (0, 760, w, h - 760),  # the area under the text
            "phone_h": 1000, "phone_c": (w // 2, 1320),
        }
    return {
        "w": w, "h": h,
        "text": (130, 0, 820),
        "head": 96, "sub": 38, "label": 28, "head_lines": 3,
        "visual": (1000, 40, 880, h - 80),
        "phone_h": 880, "phone_c": (1440, 560),
    }


@lru_cache(maxsize=None)
def text_card(lang, fmt, label, head, sub, head_fill, center=False):
    """A label, a headline and a line under it, laid out for [fmt]."""
    L = layout(fmt)
    x, top, width = L["text"]
    words = Words()
    y = top
    if fmt == "horizontal":
        y = 0  # moved to the vertical middle after measuring
    align = "center" if center else "left"
    if label:
        y = words.add(label, "mono", L["label"], LINK, x, y, width, 1, delay=0.0, align=align) + 18
    # A headline with its own line breaks keeps each of its lines whole.
    lines = head.count("|") + 1 if "|" in head else L["head_lines"]
    y = words.add(head, "black", L["head"], head_fill, x, y, width, lines,
                  delay=0.04, align=align, line_gap=0.98) + 22
    if sub:
        words.add(sub, "semi", L["sub"], MUTED, x, y, width, 2, delay=0.22, stagger=0.02,
                  align=align, min_size=int(L["sub"] * 0.7))
    if fmt == "horizontal":
        shift = (L["h"] - words.height) // 2
        words.items = [(s, ix, iy + shift, d) for s, ix, iy, d in words.items]
        words.height += shift
    return words


# -- The scenes ----------------------------------------------------------------


def scene_hook(cv, lang, fmt, t):
    hook_words(lang, fmt).draw(cv, t)


@lru_cache(maxsize=None)
def hook_words(lang, fmt):
    L = layout(fmt)
    tx = TEXTS[lang]["hook"]
    w, h = L["w"], L["h"]
    words = Words()
    width = w - 2 * (90 if fmt == "vertical" else 220)
    x = (w - width) // 2
    size = 128 if fmt == "vertical" else 132
    # Lines at beat 0, beat 2 and the next bar's downbeat.
    delays = [0.0, 2 * BEAT, 4 * BEAT]
    heights = []
    for i, line in enumerate(tx):
        s, lines = fit(line, "black", width, size if i < 2 else int(size * 1.35), 60, 1)
        f = font("black", s)
        a, d = f.getmetrics()
        heights.append(len(lines) * (a + d) * 0.98)
    total = sum(heights) + 30 * 2
    y = (h - total) / 2
    for i, line in enumerate(tx):
        fill = TEXT if i < 2 else "grad"
        y = words.add(line, "black", size if i < 2 else int(size * 1.35), fill, x, int(y), width, 1,
                      delay=delays[i], align="center", line_gap=0.98, stagger=0.07) + 30
    return words


def scene_problem(cv, lang, fmt, t, index):
    L = layout(fmt)
    tx = TEXTS[lang]
    w, h = L["w"], L["h"]
    text = tx["problems"][index]
    if index == 3:
        # "Enough.": one big word that hits harder on every beat.
        s, _ = fit(text, "black", int(w * 0.8), 260 if fmt == "vertical" else 280, 80, 1)
        sprite = word_sprite(text, "black", s, TEXT)
        k = 1.0 + 0.10 * pulse(t, BEAT, 0.10) + 0.05 * (t / BAR)
        sp = sprite.resize((int(sprite.width * k), int(sprite.height * k)), Image.BILINEAR)
        jitter = int(10 * pulse(t, BEAT, 0.06))
        paste_clipped(cv, sp, (w - sp.width) // 2 + jitter, (h - sp.height) // 2 - jitter)
        return
    words = problem_words(lang, fmt, index)
    words.draw(cv, t)
    # The strike-through on the third beat.
    p = ease_out((t - 2 * BEAT) / 0.25)
    if p > 0:
        d = ImageDraw.Draw(cv)
        lines = {}
        skip = len(TEXTS[lang]["big_apps"].split(" "))
        for sprite, x, y, delay in words.items[skip:]:
            lo, hi, _ = lines.get(y, (10 ** 9, -1, 0))
            lines[y] = (min(lo, x + 4), max(hi, x + sprite.width - 4), sprite.height)
        for y, (x0, x1, sh) in sorted(lines.items()):
            ym = y + int(sh * 0.56)
            d.rectangle((x0, ym - 7, x0 + int((x1 - x0) * p), ym + 7), fill=PINK + (255,))
    problem_icon(cv, fmt, t, index)


@lru_cache(maxsize=None)
def problem_words(lang, fmt, index):
    L = layout(fmt)
    tx = TEXTS[lang]
    x, top, width = L["text"]
    words = Words()
    y = 420 if fmt == "vertical" else 340
    y = words.add(tx["big_apps"], "mono", L["label"], GREY, x, y, width, 1) + 24
    words.add(tx["problems"][index], "black", int(L["head"] * 1.15), (205, 200, 220), x, y, width, 4,
              delay=0.05, line_gap=0.98)
    return words


def problem_icon(cv, fmt, t, index):
    L = layout(fmt)
    vx, vy, vw, vh = L["visual"]
    if fmt == "vertical":
        cx, cy, s = L["w"] // 2, 1400, 300
    else:
        cx, cy, s = vx + vw // 2, L["h"] // 2, 300
    p = ease_back((t - 0.05) / 0.4)
    if p <= 0:
        return
    s = int(s * (0.6 + 0.4 * p))
    layer = Image.new("RGBA", (s * 2, s * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    c = s
    col = (150, 146, 166, 255)
    wd = max(6, s // 22)
    if index == 0:
        # An ad banner.
        d.rounded_rectangle((c - s * 0.9, c - s * 0.5, c + s * 0.9, c + s * 0.5), int(s * 0.12), outline=col,
                            width=wd)
        f = font("mono", int(s * 0.42))
        d.text((c, c), "AD", font=f, fill=col, anchor="mm")
    elif index == 1:
        # An endless feed scrolling by itself.
        off = (t * 220) % (s * 0.55)
        for k in range(-1, 5):
            y0 = c - s * 0.9 + k * s * 0.55 - off
            if y0 < c - s * 0.95 or y0 > c + s * 0.7:
                continue
            d.rounded_rectangle((c - s * 0.6, y0, c + s * 0.6, y0 + s * 0.42), int(s * 0.07), outline=col,
                                width=wd)
        d.rounded_rectangle((c - s * 0.75, c - s * 1.0, c + s * 0.75, c + s * 0.95), int(s * 0.16),
                            outline=col, width=wd)
    else:
        # An eye that watches, opening wider on every beat.
        eye = icon("visibility", int(s * 1.7), col[:3])
        k = 1.0 + 0.08 * pulse(t, BEAT, 0.12)
        eye = eye.resize((int(eye.width * k), int(eye.height * k)), Image.BILINEAR)
        layer.alpha_composite(eye, (c - eye.width // 2, c - eye.height // 2))
    cv.alpha_composite(layer, (cx - c, cy - c))


def scene_drop(cv, lang, fmt, t, index):
    L = layout(fmt)
    tx = TEXTS[lang]
    w, h = L["w"], L["h"]
    if index == 0:
        lw = 640 if fmt == "vertical" else 700
        k = 1.0 + 0.35 * (1 - ease_out(t / 0.45)) + 0.03 * pulse(t, BEAT, 0.12)
        lg = logo(lw)
        sp = lg.resize((int(lg.width * k), int(lg.height * k)), Image.BILINEAR)
        cy = h // 2 - (120 if fmt == "vertical" else 90)
        paste_clipped(cv, sp, (w - sp.width) // 2, cy - sp.height // 2)
        words = drop_words(lang, fmt, 0)
        words.draw(cv, t - BEAT)
        return
    # The second line, while the phone comes up with a message being sent.
    words = text_card(lang, fmt, "", tx["drop"][1], "", "grad")
    words.draw(cv, t)
    rise = ease_out(t / 0.5)
    send_phone(cv, lang, fmt, t, rise)


@lru_cache(maxsize=None)
def drop_words(lang, fmt, index):
    L = layout(fmt)
    w, h = L["w"], L["h"]
    words = Words()
    width = w - 160
    y = h // 2 + (110 if fmt == "vertical" else 150)
    words.add(TEXTS[lang]["drop"][0], "bold", 64 if fmt == "vertical" else 62, LINK, 80, y, width, 2,
              align="center", stagger=0.06)
    return words


def send_phone(cv, lang, fmt, t_since_bar7, rise=1.0):
    """The message being sent (bars 7 and 8): the film plays about twice as fast."""
    L = layout(fmt)
    sh = L["phone_h"]
    p = phone_parts(sh)
    ms = max(0.0, (t_since_bar7 - 0.2)) * 1000 * 1.9
    screen = film_view(lang, "send-message-dark", ms, p["sw"], p["sh"], zoom=1.0 + 0.06 * (t_since_bar7 / (2 * BAR)),
                       focus=(0.5, 0.75))
    sprite = phone(screen, sh)
    cx, cy = L["phone_c"]
    off = int((1 - rise) * L["h"] * 0.6)
    place(cv, sprite, cx, cy + off, p["shadow"])


def answer_chip(cv, text, cx, cy, t, delay):
    p = ease_back((t - delay) / 0.35)
    if p <= 0:
        return
    f = font("mono", 30)
    tw = int(f.getlength(text))
    w, h = tw + 64, 66
    chip = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    bg = gradient(w, h, VIOLET, MAGENTA).convert("RGBA")
    chip.paste(bg, (0, 0), rounded_mask(w, h, h // 2))
    ImageDraw.Draw(chip).text((w // 2, h // 2 + 1), text, font=f, fill=(255, 255, 255, 255), anchor="mm")
    place(cv, chip, cx, cy, scale=max(0.05, p))


def scene_answer(cv, lang, fmt, t, index):
    L = layout(fmt)
    tx = TEXTS[lang]
    head, sub = tx["answers"][index]
    words = text_card(lang, fmt, "", head, sub, TEXT if index else "grad")
    cx, cy = L["phone_c"]
    sh = L["phone_h"]
    p = phone_parts(sh)
    bump = 1.0 + 0.03 * math.exp(-t / 0.12)
    if index == 0:
        send_phone(cv, lang, fmt, t + BAR)
    elif index == 1:
        screen = shot_view(lang, "chats-dark", p["sw"], p["sh"], zoom=1.0 + 0.08 * t / BAR, focus=(0.5, 0.3))
        place(cv, phone(screen, sh), cx, cy, p["shadow"], scale=bump)
    elif index == 2:
        screen = shot_view(lang, "conversation-dark", p["sw"], p["sh"], zoom=1.05 + 0.10 * t / BAR,
                           focus=(0.5, 0.45))
        place(cv, phone(screen, sh), cx, cy, p["shadow"], scale=bump)
        # A sealed lock floating over the conversation.
        lock_badge(cv, cx, cy - int(sh * 0.12), t, int(sh * 0.16))
        answer_chip(cv, "ML-KEM-768", cx, cy + int(sh * 0.12), t, 0.25)
    elif index == 3:
        qr_scene(cv, lang, fmt, t)
    elif index == 4:
        screen = shot_view(lang, "lock-dark", p["sw"], p["sh"], zoom=1.0 + 0.08 * t / BAR, focus=(0.5, 0.5))
        place(cv, phone(screen, sh), cx, cy, p["shadow"], scale=bump)
    else:
        everywhere_scene(cv, lang, fmt, t)
    words.draw(cv, t)


def lock_badge(cv, cx, cy, t, s):
    p = ease_back((t - 0.1) / 0.4)
    if p <= 0:
        return
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    bg = gradient(s, s, VIOLET, MAGENTA).convert("RGBA")
    layer.paste(bg, (0, 0), rounded_mask(s, s, s // 2))
    lock = icon("lock", int(s * 0.56))
    layer.alpha_composite(lock, ((s - lock.width) // 2, (s - lock.height) // 2))
    glow = 1.0 + 0.06 * pulse(t)
    place(cv, layer, cx, cy, scale=p * glow)


def qr_scene(cv, lang, fmt, t):
    L = layout(fmt)
    cx, cy = L["phone_c"]
    module = 14 if fmt == "vertical" else 13
    tile = qr_tile(module)
    p = ease_back(t / 0.4)
    card_w = tile.width + 80
    card_h = tile.height + 190
    card = Image.new("RGBA", (card_w, card_h), (0, 0, 0, 0))
    bg = gradient(card_w, card_h, (40, 30, 80), (70, 20, 80), vertical=True).convert("RGBA")
    card.paste(bg, (0, 0), rounded_mask(card_w, card_h, 48))
    card.alpha_composite(tile, (40, 40))
    d = ImageDraw.Draw(card)
    f = font("bold", 46)
    d.text((card_w // 2, tile.height + 40 + 75), TEXTS[lang]["qr_card"], font=f, fill=TEXT + (255,), anchor="mm")
    # The scanning line.
    sy = 40 + int((0.5 + 0.5 * math.sin(t * 5.0)) * tile.height)
    d.rectangle((30, sy - 3, card_w - 30, sy + 3), fill=PINK + (230,))
    shadow = Image.new("RGBA", (card_w + 80, card_h + 80), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (card_w, card_h), (0, 0, 0, 160)), (40, 40), rounded_mask(card_w, card_h, 48))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    angle = 4 * (1 - ease_out(t / 0.6))
    place(cv, card, cx, cy, shadow, angle=angle, scale=max(0.05, p))


@lru_cache(maxsize=None)
def laptop(lang, width):
    shot = screenshot(lang, "desktop-dark")
    sw = width
    sh = int(round(sw * shot.height / shot.width))
    pad = int(sw * 0.025)
    lid = Image.new("RGBA", (sw + 2 * pad, sh + 2 * pad), (0, 0, 0, 0))
    lid.paste(Image.new("RGBA", lid.size, (60, 56, 78, 255)), (0, 0), rounded_mask(lid.width, lid.height, pad * 2))
    lid.paste(Image.new("RGBA", (lid.width - 4, lid.height - 4), (8, 8, 12, 255)), (2, 2),
              rounded_mask(lid.width - 4, lid.height - 4, pad * 2 - 2))
    screen = shot.resize((sw, sh), Image.LANCZOS)
    lid.paste(screen, (pad, pad), rounded_mask(sw, sh, max(4, pad // 2)))
    base_h = int(sw * 0.045)
    out = Image.new("RGBA", (lid.width + 2 * int(sw * 0.07), lid.height + base_h), (0, 0, 0, 0))
    ox = (out.width - lid.width) // 2
    out.alpha_composite(lid, (ox, 0))
    base = gradient(out.width, base_h, (120, 114, 142), (54, 50, 70), vertical=True).convert("RGBA")
    out.paste(base, (0, lid.height), rounded_mask(out.width, base_h, base_h // 2))
    d = ImageDraw.Draw(out)
    nw = int(sw * 0.16)
    d.rounded_rectangle((out.width // 2 - nw // 2, lid.height, out.width // 2 + nw // 2, lid.height + base_h // 3),
                        base_h // 6, fill=(40, 37, 52, 255))
    shadow = Image.new("RGBA", (out.width + 120, out.height + 120), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", out.size, (0, 0, 0, 150)), (60, 60), rounded_mask(out.width, out.height, pad * 2))
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    return out, shadow


def everywhere_scene(cv, lang, fmt, t):
    L = layout(fmt)
    vx, vy, vw, vh = L["visual"]
    lw = int(vw * (0.74 if fmt == "vertical" else 0.70))
    lap, shadow = laptop(lang, lw)
    cx, cy = vx + vw // 2, vy + vh // 2 - (40 if fmt == "vertical" else 30)
    p = ease_out(t / 0.45)
    place(cv, lap, cx, cy + int((1 - p) * 120), shadow, alpha=p)
    sh = int(L["phone_h"] * 0.5)
    pp = phone_parts(sh)
    q = ease_back((t - 0.25) / 0.4)
    if q > 0:
        sprite = phone(shot_view(lang, "chats-dark", pp["sw"], pp["sh"]), sh)
        place(cv, sprite, cx + int(lw * 0.40), cy + int(lap.height * 0.30), pp["shadow"], angle=-6,
              scale=max(0.05, q))


def scene_circle(cv, lang, fmt, t, index):
    L = layout(fmt)
    tx = TEXTS[lang]
    head, sub = tx["circle"][index]
    words = text_card(lang, fmt, "", head, sub, "grad" if index == 0 else TEXT)
    if index < 2:
        fan_scene(cv, lang, fmt, t + index * BAR)
    elif index < 4:
        graph_scene(cv, lang, fmt, t + (index - 2) * BAR)
    else:
        calls_scene(cv, lang, fmt, t)
    words.draw(cv, t)


def fan_scene(cv, lang, fmt, t):
    """The feed in the middle, a group and the chats fanned out behind it (bars 14 and 15)."""
    L = layout(fmt)
    cx, cy = L["phone_c"]
    sh = L["phone_h"]
    p = phone_parts(sh)
    side_h = int(sh * 0.84)
    sp = phone_parts(side_h)
    open_ = ease_out((t - 0.05) / 0.5)
    spread = int((225 if fmt == "vertical" else 250) * open_)
    side = side_sprites(lang, side_h)
    place(cv, side[0], cx - spread, cy + int(40 * open_), sp["shadow"], angle=9 * open_)
    place(cv, side[1], cx + spread, cy + int(40 * open_), sp["shadow"], angle=-9 * open_)
    # The feed scrolls slowly towards the post with the photo.
    zoom = 1.0 + 0.18 * ease_in_out((t - BAR) / BAR)
    screen = shot_view(lang, "feed-dark", p["sw"], p["sh"], zoom=zoom, focus=(0.55, 0.55))
    bump = 1.0 + 0.025 * math.exp(-(t % BAR) / 0.12)
    place(cv, phone(screen, sh), cx, cy, p["shadow"], scale=bump)


@lru_cache(maxsize=None)
def side_sprites(lang, side_h):
    sp = phone_parts(side_h)
    return (phone(shot_view(lang, "group-dark", sp["sw"], sp["sh"]), side_h),
            phone(shot_view(lang, "chats-dark", sp["sw"], sp["sh"]), side_h))


def graph_scene(cv, lang, fmt, t):
    """The friend graph growing (bars 16 and 17), the camera moving in."""
    L = layout(fmt)
    cx, cy = L["phone_c"]
    sh = L["phone_h"]
    p = phone_parts(sh)
    # Skip the film's first still; 23 steps of 260 ms in about 3.2 s.
    ms = 700 + max(0.0, t - 0.1) * 1000 * 2.0
    zoom = 1.0 + 0.30 * ease_in_out(t / (2 * BAR))
    screen = film_view(lang, "graph-growth-dark", ms, p["sw"], p["sh"], zoom=zoom, focus=(0.55, 0.36))
    rise = ease_out(t / 0.4)
    bump = 1.0 + 0.025 * math.exp(-(t % BAR) / 0.12)
    place(cv, phone(screen, sh), cx, cy + int((1 - rise) * 200), p["shadow"], scale=bump)


def calls_scene(cv, lang, fmt, t):
    """A conversation, and the call buttons popping out of it on the beats."""
    L = layout(fmt)
    cx, cy = L["phone_c"]
    sh = L["phone_h"]
    p = phone_parts(sh)
    screen = shot_view(lang, "conversation-dark", p["sw"], p["sh"], zoom=1.0 + 0.25 * ease_in_out(t / BAR),
                       focus=(0.7, 0.12))
    bump = 1.0 + 0.025 * math.exp(-t / 0.12)
    place(cv, phone(screen, sh), cx, cy, p["shadow"], scale=bump)
    s = int(sh * 0.17)
    for k, (name, dx) in enumerate((("call", -1.0), ("videocam", 0.0), ("screen_share", 1.0))):
        call_button(cv, name, cx + int(dx * s * 1.3), cy + int(sh * 0.30), s, t, k * BEAT)


def call_button(cv, name, cx, cy, s, t, delay):
    p = ease_back((t - delay) / 0.35)
    if p <= 0:
        return
    pad = s // 2
    layer = Image.new("RGBA", (s + 2 * pad, s + 2 * pad), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # A ring going out on every beat after it came.
    age = ((t - delay) % BEAT) / BEAT
    r = int(s / 2 + age * pad)
    c = s // 2 + pad
    d.ellipse((c - r, c - r, c + r, c + r), outline=PINK + (int(200 * (1 - age)),), width=5)
    disc = gradient(s, s, VIOLET, MAGENTA).convert("RGBA")
    layer.paste(disc, (pad, pad), rounded_mask(s, s, s // 2))
    glyph = icon(name, int(s * 0.55))
    layer.alpha_composite(glyph, (c - glyph.width // 2, c - glyph.height // 2))
    place(cv, layer, cx, cy, scale=max(0.05, p))


def scene_end(cv, lang, fmt, t):
    L = layout(fmt)
    tx = TEXTS[lang]
    w, h = L["w"], L["h"]
    e = end_layout(lang, fmt)
    p = ease_out(t / 0.5)
    lg = logo(e["logo_w"])
    k = 1.0 + 0.15 * (1 - p)
    sp = lg.resize((int(lg.width * k), int(lg.height * k)), Image.BILINEAR)
    if p < 1:
        a = sp.getchannel("A").point(lambda v: int(v * p))
        sp.putalpha(a)
    lx, ly = e["logo_c"]
    paste_clipped(cv, sp, lx - sp.width // 2, ly - sp.height // 2)
    e["words"].draw(cv, t)
    q = ease_back((t - 3 * BEAT) / 0.4)
    if q > 0:
        tile = qr_tile(e["module"])
        qx, qy = e["qr_c"]
        if q >= 0.999:
            cv.alpha_composite(tile, (qx - tile.width // 2, qy - tile.height // 2))
        else:
            place(cv, tile, qx, qy, scale=max(0.05, q))
    e["words2"].draw(cv, t - 3 * BEAT)


@lru_cache(maxsize=None)
def end_layout(lang, fmt):
    L = layout(fmt)
    tx = TEXTS[lang]
    w, h = L["w"], L["h"]
    words = Words()
    words2 = Words()
    if fmt == "vertical":
        # Everything above y = 1560: the apps put their own buttons and
        # captions over the bottom of a vertical film.
        logo_w, module = 500, 9
        logo_c = (w // 2, 300)
        x, width = 80, w - 160
        y = 480
        y = words.add(tx["end_title"], "black", 72, TEXT, x, y, width, 4, delay=BEAT, align="center",
                      stagger=0.04, line_gap=1.0) + 24
        # One sentence a line.
        y = words.add(tx["end_tagline"].replace(". ", ".|"), "bold", 48, "grad", x, y, width, 3,
                      delay=2 * BEAT, align="center", stagger=0.06, line_gap=0.95) + 40
        tile = qr_tile(module)
        qr_c = (w // 2, y + tile.height // 2)
        y += tile.height + 36
        y = words2.add(tx["end_get"], "semi", 42, MUTED, x, y, width, 1, align="center") + 2
        words2.add(tx["end_url"], "bold", 50, TEXT, x, y, width, 1, delay=0.08, align="center")
    else:
        logo_w, module = 460, 10
        x, width = 130, 960
        logo_c = (x + logo_w // 2, 310)
        y = 470
        y = words.add(tx["end_title"], "black", 70, TEXT, x, y, width, 3, delay=BEAT, stagger=0.04,
                      line_gap=1.02) + 26
        y = words.add(tx["end_tagline"].replace(". ", ".|"), "bold", 44, "grad", x, y, width, 3,
                      delay=2 * BEAT, stagger=0.06, line_gap=0.95) + 40
        tile = qr_tile(module)
        qr_c = (1500, 480)
        ty = qr_c[1] + tile.height // 2 + 34
        ty = words2.add(tx["end_get"], "semi", 38, MUTED, 1100, ty, 800, 1, align="center") + 2
        words2.add(tx["end_url"], "bold", 42, TEXT, 1100, ty, 800, 1, delay=0.08, align="center")
    return {"logo_w": logo_w, "logo_c": logo_c, "module": module, "qr_c": qr_c, "words": words,
            "words2": words2}


# -- One frame -----------------------------------------------------------------


def frame(lang, fmt, i):
    t = i / FPS
    w, h = FORMATS[fmt]
    first, bars, kind, index = card_at(t)
    tl = t - first * BAR
    # Grey while the problems are told, the brand's colours from the drop on.
    if t < 2 * BAR:
        brand = 0.65
    elif t < 6 * BAR:
        brand = 0.0
    else:
        brand = 1.0
    cv = background(w, h, t, brand)
    if kind == "hook":
        scene_hook(cv, lang, fmt, tl)
    elif kind == "problem":
        scene_problem(cv, lang, fmt, tl, index)
    elif kind == "drop":
        scene_drop(cv, lang, fmt, tl if index == 0 else tl, index)
    elif kind == "answer":
        scene_answer(cv, lang, fmt, tl, index)
    elif kind == "circle":
        scene_circle(cv, lang, fmt, tl, index)
    else:
        scene_end(cv, lang, fmt, tl)
    img = cv.convert("RGB")
    # A small punch on every new card from the drop on.
    if kind not in ("end",) and t >= 6 * BAR:
        k = 0.035 * math.exp(-(tl % BAR) / 0.11)
        if k > 0.002:
            cw, ch = int(w / (1 + k)), int(h / (1 + k))
            img = img.resize((w, h), Image.BILINEAR, box=((w - cw) / 2, (h - ch) / 2, (w + cw) / 2, (h + ch) / 2))
    # The drop: a white flash.
    if 6 * BAR <= t < 6 * BAR + 0.4:
        a = 1 - (t - 6 * BAR) / 0.4
        img = Image.blend(img, Image.new("RGB", (w, h), (255, 255, 255)), a * 0.9)
    # Glitches on the beats while the problems are told.
    if 2 * BAR <= t < 6 * BAR:
        g = pulse(t, BEAT, 0.05)
        if g > 0.2:
            arr = np.asarray(img).copy()
            s = int(14 * g)
            arr[..., 0] = np.roll(arr[..., 0], s, axis=1)
            arr[..., 2] = np.roll(arr[..., 2], -s, axis=1)
            rng = np.random.default_rng(i)
            for _ in range(4):
                y0 = int(rng.integers(0, h - 40))
                hh = int(rng.integers(8, 40))
                arr[y0:y0 + hh] = np.roll(arr[y0:y0 + hh], int(rng.integers(-40, 40)), axis=1)
            img = Image.fromarray(arr)
    # Fade in from black at the very start.
    if t < 0.25:
        img = Image.blend(Image.new("RGB", (w, h), (0, 0, 0)), img, t / 0.25)
    return img


def render_one(job):
    lang, fmt, i = job
    return frame(lang, fmt, i).tobytes()


# -- Encoding ------------------------------------------------------------------


def run(cmd):
    subprocess.run(cmd, check=True)


def prepare_audio(ffmpeg):
    """The music cut to the film, faded, normalised to -14 LUFS: build/promo/music.wav."""
    out = os.path.join(BUILD, "music.wav")
    chain = f"atrim=0:{DURATION:.4f},afade=t=in:d=0.02,afade=t=out:st={DURATION - FADE_OUT:.4f}:d={FADE_OUT}"
    probe = subprocess.run([ffmpeg, "-hide_banner", "-nostats", "-i", MUSIC, "-af",
                            chain + f",loudnorm=I={LOUDNESS}:TP=-1.5:LRA=11:print_format=json",
                            "-f", "null", "-"], capture_output=True, text=True, check=True).stderr
    m = json.loads(probe[probe.rindex("{"):probe.rindex("}") + 1])
    run([ffmpeg, "-v", "error", "-y", "-i", MUSIC, "-af",
         chain + f",loudnorm=I={LOUDNESS}:TP=-1.5:LRA=11:measured_I={m['input_i']}:"
         f"measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:"
         f"offset={m['target_offset']}:linear=true", "-ar", "48000", "-ac", "2", out])
    return out


def render_master(ffmpeg, lang, fmt, jobs):
    w, h = FORMATS[fmt]
    os.makedirs(os.path.join(BUILD, "master"), exist_ok=True)
    out = os.path.join(BUILD, "master", f"zen-promo-{lang}-{fmt}.mp4")
    enc = subprocess.Popen([ffmpeg, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                            "-s", f"{w}x{h}", "-r", str(FPS), "-i", "-",
                            "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p",
                            "-profile:v", "high", "-an", out], stdin=subprocess.PIPE)
    with Pool(jobs) as pool:
        for n, data in enumerate(pool.imap(render_one, [(lang, fmt, i) for i in range(FRAMES)], chunksize=3)):
            enc.stdin.write(data)
            if n % 150 == 0:
                print(f"make_promo: {lang} {fmt} frame {n}/{FRAMES}", flush=True)
    enc.stdin.close()
    if enc.wait() != 0:
        sys.exit("make_promo: encoding the master failed")
    return out


def encode_h264(ffmpeg, master, audio, out, kbps):
    log = os.path.join(BUILD, "x264pass")
    common = ["-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-pix_fmt", "yuv420p",
              "-b:v", f"{kbps}k", "-maxrate", f"{kbps * 2}k", "-bufsize", f"{kbps * 4}k",
              "-g", str(FPS * 2), "-passlogfile", log]
    run([ffmpeg, "-v", "error", "-y", "-i", master] + common + ["-pass", "1", "-an", "-f", "null", os.devnull])
    run([ffmpeg, "-v", "error", "-y", "-i", master, "-i", audio] + common +
        ["-pass", "2", "-c:a", "aac", "-b:a", "128k", "-map", "0:v", "-map", "1:a",
         "-map_metadata", "-1", "-movflags", "+faststart", out])


def encode_webm(ffmpeg, master, audio, out, kbps):
    log = os.path.join(BUILD, "vp9pass")
    common = ["-c:v", "libvpx-vp9", "-b:v", f"{kbps}k", "-row-mt", "1", "-deadline", "good",
              "-cpu-used", "2", "-pix_fmt", "yuv420p", "-g", str(FPS * 4), "-passlogfile", log]
    run([ffmpeg, "-v", "error", "-y", "-i", master] + common + ["-pass", "1", "-an", "-f", "null", os.devnull])
    run([ffmpeg, "-v", "error", "-y", "-i", master, "-i", audio] + common +
        ["-pass", "2", "-c:a", "libopus", "-b:a", "96k", "-map", "0:v", "-map", "1:a",
         "-map_metadata", "-1", out])


def grab(ffmpeg, video, at, out):
    run([ffmpeg, "-v", "error", "-y", "-ss", f"{at:.3f}", "-i", video, "-frames:v", "1", out])


def contact_sheet(ffmpeg, video, fmt, out):
    """One frame every 2 seconds, with its time, in one picture."""
    tmp = os.path.join(BUILD, "sheet")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    run([ffmpeg, "-v", "error", "-y", "-i", video, "-vf", "fps=1/2", os.path.join(tmp, "%03d.png")])
    names = sorted(os.listdir(tmp))
    tw = 270 if fmt == "vertical" else 480
    cols = 6 if fmt == "vertical" else 4
    thumbs = []
    for n, name in enumerate(names):
        im = Image.open(os.path.join(tmp, name)).convert("RGB")
        im = im.resize((tw, int(im.height * tw / im.width)), Image.LANCZOS)
        ImageDraw.Draw(im).text((8, 6), f"{n * 2 + 1:02d}s", font=font("mono", 22), fill=(255, 255, 0))
        thumbs.append(im)
    th = thumbs[0].height
    rows = (len(thumbs) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * tw, rows * th), (0, 0, 0))
    for n, im in enumerate(thumbs):
        sheet.paste(im, ((n % cols) * tw, (n // cols) * th))
    sheet.save(out)
    shutil.rmtree(tmp, ignore_errors=True)


def size_mb(path):
    return os.path.getsize(path) / 1024 / 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--lang", default=",".join(LANGS))
    parser.add_argument("--format", default=",".join(FORMATS))
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    parser.add_argument("--sheets-only", action="store_true",
                        help="render the masters and their contact sheets, not the site's files")
    parser.add_argument("--frame", type=float, help="write one frame at this second of each film and stop")
    parser.add_argument("--no-check", action="store_true", help="don't read the end card's code back")
    args = parser.parse_args()
    langs = [l for l in args.lang.split(",") if l]
    fmts = [f for f in args.format.split(",") if f]
    os.makedirs(BUILD, exist_ok=True)
    if args.frame is not None:
        for lang in langs:
            for fmt in fmts:
                out = os.path.join(BUILD, f"frame-{lang}-{fmt}-{args.frame:05.2f}.png")
                frame(lang, fmt, int(round(args.frame * FPS))).save(out)
                print(out)
        return
    if not os.path.isfile(QR_FILE):
        sys.exit("make_promo: tool/promo/qr-about.txt is missing: run `flutter test tool/promo/qr_test.dart`")
    audio = prepare_audio(args.ffmpeg)
    os.makedirs(OUT, exist_ok=True)
    check = os.path.join(BUILD, "check")
    shutil.rmtree(check, ignore_errors=True)
    os.makedirs(check)
    for lang in langs:
        for fmt in fmts:
            master = render_master(args.ffmpeg, lang, fmt, args.jobs)
            sheet = os.path.join(BUILD, f"contact-{lang}-{fmt}.png")
            contact_sheet(args.ffmpeg, master, fmt, sheet)
            print(f"make_promo: contact sheet {os.path.relpath(sheet, ROOT)}")
            if args.sheets_only:
                continue
            name = f"zen-promo-{lang}" + ("" if fmt == "vertical" else "-16x9")
            mp4 = os.path.join(OUT, name + ".mp4")
            encode_h264(args.ffmpeg, master, audio, mp4, 1250)
            print(f"make_promo: {os.path.relpath(mp4, ROOT)} {size_mb(mp4):.2f} MB")
            grab(args.ffmpeg, mp4, DURATION - 1.0, os.path.join(check, f"{name}.png"))
            if fmt == "vertical":
                webm = os.path.join(OUT, name + ".webm")
                encode_webm(args.ffmpeg, master, audio, webm, 1150)
                print(f"make_promo: {os.path.relpath(webm, ROOT)} {size_mb(webm):.2f} MB")
                poster = os.path.join(OUT, f"zen-promo-poster-{lang}.jpg")
                png = os.path.join(BUILD, f"poster-{lang}.png")
                grab(args.ffmpeg, master, DURATION - 1.0, png)
                Image.open(png).convert("RGB").save(poster, "JPEG", quality=86, optimize=True, progressive=True)
                print(f"make_promo: {os.path.relpath(poster, ROOT)} {os.path.getsize(poster) // 1024} KB")
        write_vtt(lang, os.path.join(OUT, f"zen-promo-{lang}.vtt"))
    for name in ("x264pass-0.log", "x264pass-0.log.mbtree", "vp9pass-0.log"):
        try:
            os.remove(os.path.join(BUILD, name))
        except OSError:
            pass
    if not args.no_check and not args.sheets_only:
        flutter = "flutter.bat" if os.name == "nt" else "flutter"
        run([flutter, "test", "--no-pub", "tool/promo/qr_test.dart"])


if __name__ == "__main__":
    main()
