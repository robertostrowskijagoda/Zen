#!/usr/bin/env python3
"""Draws the pictures of the website that are made from the app icon.

  python tool/ci/site_images.py      (from the repository root; needs Pillow)

- tool/pages/og-image.png (1200 x 630): the picture a link to the site
  shows in messengers and social apps: the icon, the name and one line
  about Zen, in the colours of the pages (site.css: the light background,
  its two glows and the violet-to-magenta gradient of the headings). The
  icon and the name sit in the middle, so a square crop keeps them.
- tool/pages/zen-icon-192.png and zen-icon-512.png: the icons of
  manifest.webmanifest (a bookmark on the home screen).

The icon is the app's own (ios/Runner/.../Icon-App-1024x1024@1x.png, the
one the Pages workflow publishes as zen-icon.png). The files are kept in
the repository; run this again after the icon, the colours or the line
change. The fonts are the system's (Segoe UI, DejaVu Sans, Noto Sans or
Helvetica; --bold / --text to choose others).
"""

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICON = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset",
                    "Icon-App-1024x1024@1x.png")
OUT = os.path.join(ROOT, "tool", "pages")

NAME = "Zen"
TAGLINE = "A private messenger for people who know each other \u2014 no servers of its own, no ads"
WIDTH, HEIGHT = 1200, 630

# site.css, light theme.
BG = (0xF6, 0xF4, 0xFB)
MUTED = (0x5D, 0x59, 0x70)
BTN1 = (0x6D, 0x3D, 0xF5)
BTN2 = (0xB0, 0x1F, 0xC4)
GLOW = ((124, 77, 255), 0.20)
GLOW2 = ((214, 70, 190), 0.12)

BOLD_FONTS = (
    "C:/Windows/Fonts/segoeuib.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
)
TEXT_FONTS = (
    "C:/Windows/Fonts/seguisb.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
)


def font(choice, candidates, size):
    for path in ((choice,) if choice else candidates):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    sys.exit("site_images: no font found; pass one with --bold / --text")


def glow(canvas, colour, alpha, centre, radii):
    """A radial glow (CSS radial-gradient(closest-side, colour, transparent))."""
    w, h = radii[0] * 2, radii[1] * 2
    # Full colour in the middle, none from the edge of the ellipse outwards.
    falloff = Image.new("L", (256, 256))
    falloff.putdata([
        round(255 * alpha * max(0.0, 1 - (((x - 127.5) ** 2 + (y - 127.5) ** 2) ** 0.5) / 128))
        for y in range(256) for x in range(256)
    ])
    mask = falloff.resize((w, h), Image.BICUBIC)
    layer = Image.new("RGB", (w, h), colour)
    canvas.paste(layer, (centre[0] - radii[0], centre[1] - radii[1]), mask)


def rounded(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.size[0] - 1, image.size[1] - 1),
                                           radius, fill=255)
    out = image.convert("RGBA")
    out.putalpha(mask)
    return out


def gradient_text(canvas, xy, text, face):
    """[text] filled with the headings' gradient, left to right."""
    xy = (round(xy[0]), round(xy[1]))
    box = ImageDraw.Draw(canvas).textbbox(xy, text, font=face)
    w, h = box[2] - box[0], box[3] - box[1]
    fill = Image.new("RGB", (w, h))
    draw = ImageDraw.Draw(fill)
    for x in range(w):
        t = x / max(1, w - 1)
        draw.line([(x, 0), (x, h)],
                  fill=tuple(round(a + (b - a) * t) for a, b in zip(BTN1, BTN2)))
    mask = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(mask).text(xy, text, font=face, fill=255)
    canvas.paste(fill, box[:2], mask.crop(box))


def wrap(text, face, width):
    lines, line = [], ""
    for word in text.split(" "):
        candidate = (line + " " + word).strip()
        if line and face.getlength(candidate) > width:
            lines.append(line)
            line = word
        else:
            line = candidate
    return lines + [line]


def og_image(icon, bold, text):
    canvas = Image.new("RGB", (WIDTH, HEIGHT), BG)
    glow(canvas, GLOW[0], GLOW[1], (WIDTH // 2, 190), (640, 330))
    glow(canvas, GLOW2[0], GLOW2[1], (880, 170), (340, 270))

    size, top = 196, 82
    radius = round(size * 24 / 88)  # .hero-icon: 88 px with 24 px corners
    shadow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    left = (WIDTH - size) // 2
    ImageDraw.Draw(shadow).rounded_rectangle(
        (left, top + 30, left + size, top + 30 + size), radius, fill=BTN1 + (95,))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    base = canvas.convert("RGBA")
    base.alpha_composite(shadow)
    base.alpha_composite(rounded(icon.resize((size, size), Image.LANCZOS), radius), (left, top))
    canvas = base.convert("RGB")

    draw = ImageDraw.Draw(canvas)
    name_face = font(bold, BOLD_FONTS, 112)
    width = draw.textlength(NAME, font=name_face)
    gradient_text(canvas, ((WIDTH - width) / 2, top + size + 16), NAME, name_face)

    line_face = font(text, TEXT_FONTS, 40)
    y = top + size + 164
    for line in wrap(TAGLINE, line_face, 1040):
        width = draw.textlength(line, font=line_face)
        draw.text(((WIDTH - width) / 2, y), line, font=line_face, fill=MUTED)
        y += 54
    return canvas


def save(image, path):
    image.save(path, optimize=True)
    if path.endswith("og-image.png") and os.path.getsize(path) > 200 * 1024:
        image.quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(
            path, optimize=True)
    print(f"site_images: {os.path.relpath(path, ROOT)} {image.size[0]}x{image.size[1]}, "
          f"{os.path.getsize(path) // 1024} KB")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--icon", default=ICON)
    parser.add_argument("--out", default=OUT)
    parser.add_argument("--bold", default="")
    parser.add_argument("--text", default="")
    args = parser.parse_args()
    icon = Image.open(args.icon).convert("RGB")
    save(og_image(icon, args.bold, args.text), os.path.join(args.out, "og-image.png"))
    for size in (192, 512):
        save(icon.resize((size, size), Image.LANCZOS),
             os.path.join(args.out, f"zen-icon-{size}.png"))


if __name__ == "__main__":
    main()
