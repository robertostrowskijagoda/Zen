#!/usr/bin/env python3
"""Draws the printable promo materials of the website (tool/pages/promo/).

  python tool/ci/promo_materials.py      (from the repository root; needs Pillow)

- zen-poster-<lang>.png and .pdf (pl, en): a poster in the A series'
  proportions (A4 at 300 dpi; it prints as well on A3): the headline, the
  four strongest reasons to try Zen, a phone with the app's chat list
  (tool/pages/shots/<lang>/chats-light.webp), the QR code of the about page
  and the Zen mark, in the colours of the pages (site.css, light theme).
  The PDF holds the picture with the QR code drawn over it as vector
  squares, so it stays sharp at any size. zen-poster-<lang>-preview.webp
  is the small picture the promo page shows.
- zen-qr-about.png and .svg: the QR code of the about page with its quiet
  zone, nothing else (to put on anything).
- zen-qr-about-<lang>.pdf (pl, en): an A4 page with a square in the middle,
  to cut out along its dashed line: the QR code, "Scan to get to know Zen"
  and a small Zen signature.

The QR codes are made by qr.py (level Q, a quarter of the code can be
damaged). The PDF files are written here directly; their texts are
pictures (600 dpi), the QR codes vectors. The fonts are the system's, as
in site_images.py. The files are kept in the repository; run this again
after the address, the texts, the screenshots or the colours change.
"""

import argparse
import io
import os
import sys
import zlib

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import qr  # noqa: E402
from site_images import (BG, BOLD_FONTS, BTN1, BTN2, GLOW, GLOW2, ICON, MUTED,  # noqa: E402
                         ROOT, TEXT_FONTS, font, glow, gradient_text, rounded, wrap)

OUT = os.path.join(ROOT, "tool", "pages", "promo")
SHOTS = os.path.join(ROOT, "tool", "pages", "shots")
ABOUT = "https://robertostrowskijagoda.github.io/Zen/about/"
SHORT = "robertostrowskijagoda.github.io/Zen"
LEVEL = "Q"

TEXT = (0x17, 0x15, 0x1F)
LINK = (0x62, 0x34, 0xD8)
CARD = (0xFF, 0xFF, 0xFF)
LINE = (0xE4, 0xE0, 0xEF)
SOFT = (0xEF, 0xEA, 0xFF)
FRAME = (0x18, 0x16, 0x1F)

# A4 at 300 dpi; A3 has the same proportions.
POSTER = (2480, 3508)
A4_PT = (595.28, 841.89)
MM = 72 / 25.4

WORDS = {
    "pl": {
        "head": ["Twoi ludzie.", "Bez firmy pośrodku."],
        "sub": "Prywatna sieć społecznościowa dla ludzi, którzy się znają.",
        "points": [
            "Bez reklam i śledzenia. Nikt nie czyta Twoich rozmów.",
            "Działa bez internetu, gdy znajomi są blisko.",
            "Za darmo, z otwartym kodem.",
            "Szyfrowanie odporne na komputery kwantowe.",
        ],
        "scan": "Zeskanuj, żeby poznać Zen",
        "systems": "Android · iPhone · Windows · Mac · Linux",
    },
    "en": {
        "head": ["Your people.", "No company in between."],
        "sub": "A private social network for people who know each other.",
        "points": [
            "No ads, no tracking. Nobody reads your conversations.",
            "Works without the internet when friends are close.",
            "Free, with open source code.",
            "Encryption built to withstand quantum computers.",
        ],
        "scan": "Scan to get to know Zen",
        "systems": "Android · iPhone · Windows · Mac · Linux",
    },
}


def bold(size):
    return font("", BOLD_FONTS, size)


def regular(size):
    return font("", TEXT_FONTS, size)


def qr_matrix():
    return qr.encode(ABOUT, LEVEL)


def qr_image(matrix, module, quiet=4, dark=TEXT, light=CARD):
    """The QR code as a picture, [module] pixels a module."""
    n = len(matrix) + 2 * quiet
    small = Image.new("RGB", (n, n), light)
    px = small.load()
    for y, row in enumerate(matrix):
        for x, on in enumerate(row):
            if on:
                px[x + quiet, y + quiet] = dark
    return small.resize((n * module, n * module), Image.NEAREST)


def qr_runs(matrix):
    """The dark modules as horizontal runs: (x, y, length)."""
    runs = []
    for y, row in enumerate(matrix):
        x = 0
        while x < len(row):
            if row[x]:
                start = x
                while x < len(row) and row[x]:
                    x += 1
                runs.append((start, y, x - start))
            else:
                x += 1
    return runs


def qr_svg(matrix, quiet=4):
    n = len(matrix) + 2 * quiet
    path = "".join(f"M{x + quiet} {y + quiet}h{w}v1h-{w}z" for x, y, w in qr_runs(matrix))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n} {n}" '
            f'shape-rendering="crispEdges">\n'
            f"<title>QR: {ABOUT}</title>\n"
            f'<rect width="{n}" height="{n}" fill="#fff"/>\n'
            f'<path fill="#17151f" d="{path}"/>\n</svg>\n')


def qr_ops(matrix, x0, y_top, size, quiet=4):
    """PDF operators that draw the QR code (quiet zone included) as a
    [size] point square whose top left corner is (x0, y_top)."""
    n = len(matrix) + 2 * quiet
    m = size / n
    ops = ["q 1 1 1 rg", f"{x0:.3f} {y_top - size:.3f} {size:.3f} {size:.3f} re f",
           "%.4f %.4f %.4f rg" % tuple(c / 255 for c in TEXT)]
    for x, y, w in qr_runs(matrix):
        ops.append(f"{x0 + (x + quiet) * m:.3f} {y_top - (y + quiet + 1) * m:.3f} {w * m:.3f} {m:.3f} re")
    ops += ["f", "Q"]
    return ops


class Pdf:
    """A one-page PDF: pictures and drawing operators, nothing more."""

    def __init__(self, size):
        self.size = size
        self.images = []
        self.ops = []

    def image(self, picture, x, y, w, h, jpeg=False):
        """[picture] at (x, y) (bottom left, points), [w] x [h] points."""
        name = f"Im{len(self.images) + 1}"
        if jpeg:
            buf = io.BytesIO()
            picture.convert("RGB").save(buf, "JPEG", quality=90, optimize=True, subsampling=0)
            data, colour, filt = buf.getvalue(), "/DeviceRGB", "/DCTDecode"
        else:
            gray = picture.convert("L")
            data, colour, filt = zlib.compress(gray.tobytes(), 9), "/DeviceGray", "/FlateDecode"
        self.images.append((name, picture.size, colour, filt, data))
        self.ops.append(f"q {w:.3f} 0 0 {h:.3f} {x:.3f} {y:.3f} cm /{name} Do Q")

    def save(self, path, title):
        objects = []

        def add(body):
            objects.append(body)
            return len(objects)

        catalog = add(None)
        pages = add(None)
        xobjects = []
        for name, (w, h), colour, filt, data in self.images:
            ref = add(f"<< /Type /XObject /Subtype /Image /Width {w} /Height {h} "
                      f"/ColorSpace {colour} /BitsPerComponent 8 /Filter {filt} "
                      f"/Length {len(data)} >>\nstream\n".encode() + data + b"\nendstream")
            xobjects.append(f"/{name} {ref} 0 R")
        content = zlib.compress("\n".join(self.ops).encode(), 9)
        stream = add(f"<< /Length {len(content)} /Filter /FlateDecode >>\nstream\n".encode()
                     + content + b"\nendstream")
        page = add(f"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 {self.size[0]} {self.size[1]}] "
                   f"/Resources << /XObject << {' '.join(xobjects)} >> >> /Contents {stream} 0 R >>")
        # UTF-16 with its byte order mark: the titles have Polish letters.
        info = add(f"<< /Title <FEFF{title.encode('utf-16-be').hex().upper()}> "
                   f"/Author (Robert Ostrowski-Jagoda) >>")
        objects[catalog - 1] = f"<< /Type /Catalog /Pages {pages} 0 R >>"
        objects[pages - 1] = f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>"
        out = io.BytesIO()
        out.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for i, body in enumerate(objects, 1):
            offsets.append(out.tell())
            body = body.encode() if isinstance(body, str) else body
            out.write(f"{i} 0 obj\n".encode() + body + b"\nendobj\n")
        xref = out.tell()
        out.write(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
        for off in offsets:
            out.write(f"{off:010d} 00000 n \n".encode())
        out.write(f"trailer\n<< /Size {len(objects) + 1} /Root {catalog} 0 R /Info {info} 0 R >>\n"
                  f"startxref\n{xref}\n%%EOF\n".encode())
        with open(path, "wb") as f:
            f.write(out.getvalue())


def text_picture(lines, dpi=600):
    """Centred lines [(text, face_pt, bold?, rgb)] as one picture on white;
    the face size is in points at [dpi]."""
    scale = dpi / 72
    faces = [(t, (bold if b else regular)(round(s * scale)), c) for t, s, b, c in lines]
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    boxes = [probe.textbbox((0, 0), t, font=f) for t, f, _ in faces]
    w = max(b[2] for b in boxes) + 8
    gap = round(0.35 * max(s for _, s, _, _ in lines) * scale)
    h = sum(b[3] for b in boxes) + gap * (len(lines) - 1) + 8
    pic = Image.new("RGB", (w, h), CARD)
    draw = ImageDraw.Draw(pic)
    y = 4
    for (t, f, c), b in zip(faces, boxes):
        draw.text(((w - b[2]) / 2, y), t, font=f, fill=c)
        y += b[3] + gap
    return pic, w / scale, h / scale


def signature_picture(icon, dpi=600, height_pt=26):
    """The Zen mark: the icon and the name beside it, on white."""
    scale = dpi / 72
    side = round(height_pt * scale)
    face = bold(round(height_pt * 0.82 * scale))
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    box = probe.textbbox((0, 0), "Zen", font=face)
    gap = round(side * 0.3)
    pic = Image.new("RGB", (side + gap + box[2] + 8, side), CARD)
    mark = rounded(icon.resize((side, side), Image.LANCZOS), round(side * 24 / 88))
    pic.paste(mark, (0, 0), mark)
    gradient_text(pic, (side + gap, (side - box[3]) / 2 - box[1] / 4), "Zen", face)
    return pic, pic.size[0] / scale, height_pt


def qr_card_pdf(matrix, icon, lang, path):
    """A4 with a 120 mm square to cut out: the QR code, a line, the mark."""
    words = WORDS[lang]
    pdf = Pdf(A4_PT)
    side = 120 * MM
    x0 = (A4_PT[0] - side) / 2
    top = (A4_PT[1] + side) / 2
    pdf.ops += ["q 0.55 0.53 0.62 RG 0.6 w [4 3] 0 d",
                f"{x0:.3f} {top - side:.3f} {side:.3f} {side:.3f} re S Q"]
    qr_side = 78 * MM
    pdf.ops += qr_ops(matrix, (A4_PT[0] - qr_side) / 2, top - 5 * MM, qr_side)
    caption, cw, ch = text_picture([(words["scan"], 15, True, TEXT), (SHORT, 9, False, LINK)])
    y = top - 5 * MM - qr_side - 1 * MM - ch
    pdf.image(caption, (A4_PT[0] - cw) / 2, y, cw, ch)
    sig, sw, sh = signature_picture(icon, height_pt=22)
    pdf.image(sig, (A4_PT[0] - sw) / 2, top - side + 7 * MM, sw, sh)
    pdf.save(path, f"Zen: {words['scan']}")


def phone(shot, width):
    """The screenshot in a phone's frame, [width] pixels wide."""
    border = round(width * 0.028)
    inner = width - 2 * border
    screen = shot.resize((inner, round(inner * shot.size[1] / shot.size[0])), Image.LANCZOS)
    radius = round(width * 0.11)
    body = Image.new("RGBA", (width, screen.size[1] + 2 * border), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((0, 0, body.size[0] - 1, body.size[1] - 1), radius,
                                           fill=FRAME + (255,))
    body.alpha_composite(rounded(screen, radius - border), (border, border))
    return body


def check_badge(size):
    """A filled circle in the headings' gradient with a white tick."""
    big = size * 4
    grad = Image.new("RGB", (big, big))
    d = ImageDraw.Draw(grad)
    for i in range(big):
        t = i / (big - 1)
        d.line([(i, 0), (0, i)], fill=tuple(round(a + (b - a) * t) for a, b in zip(BTN1, BTN2)))
        d.line([(i, big - 1), (big - 1, i)],
               fill=tuple(round(a + (b - a) * min(1, t + 0.5)) for a, b in zip(BTN1, BTN2)))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, big - 1, big - 1), fill=255)
    out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    ImageDraw.Draw(out).line([(big * .29, big * .52), (big * .44, big * .67), (big * .72, big * .36)],
                             fill=(255, 255, 255, 255), width=round(big * .1), joint="curve")
    return out.resize((size, size), Image.LANCZOS)


def poster(lang, matrix, icon):
    """The poster picture and where its QR code is: (picture, (x, y, side))."""
    words = WORDS[lang]
    W, H = POSTER
    m = 170
    canvas = Image.new("RGB", POSTER, BG)
    glow(canvas, GLOW[0], GLOW[1] * 1.3, (W // 2, 520), (1500, 900))
    glow(canvas, GLOW2[0], GLOW2[1] * 1.3, (W - 420, 380), (900, 700))
    glow(canvas, GLOW[0], GLOW[1], (520, H - 900), (1100, 700))
    base = canvas.convert("RGBA")

    # The mark.
    side = 190
    shadow = Image.new("RGBA", POSTER, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((m, m + 26, m + side, m + 26 + side), 52, fill=BTN1 + (90,))
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    base.alpha_composite(rounded(icon.resize((side, side), Image.LANCZOS), round(side * 24 / 88)), (m, m))
    canvas = base.convert("RGB")
    draw = ImageDraw.Draw(canvas)
    name = bold(150)
    nb = draw.textbbox((0, 0), "Zen", font=name)
    gradient_text(canvas, (m + side + 50, m + (side - nb[3]) / 2 - nb[1] / 3), "Zen", name)

    # The headline: the second line in the headings' gradient.
    head = bold(178)
    y = m + side + 150
    for i, line in enumerate(words["head"]):
        face = head
        while draw.textlength(line, font=face) > W - 2 * m:
            face = bold(face.size - 6)
        if i == 0:
            draw.text((m, y), line, font=face, fill=TEXT)
        else:
            gradient_text(canvas, (m, y), line, face)
        y += round(face.size * 1.16)
    sub = regular(74)
    y += 50
    for line in wrap(words["sub"], sub, W - 2 * m):
        draw.text((m, y), line, font=sub, fill=MUTED)
        y += 98

    # The phone on the right, as tall as the room above the card allows,
    # and the reasons on the left, in the middle of its height.
    card_h = 560
    cy = H - m - card_h
    shot = Image.open(os.path.join(SHOTS, lang, "chats-light.webp")).convert("RGB")
    py = y + 110
    room = cy - 90 - py
    ph = phone(shot, min(860, round(room * shot.size[0] / shot.size[1] / 1.0)))
    px = W - m - ph.size[0] + 20
    shadow = Image.new("RGBA", POSTER, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((px + 10, py + 50, px + ph.size[0] - 10, py + ph.size[1] + 30),
                                             90, fill=(70, 40, 140, 70))
    base = canvas.convert("RGBA")
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(40)))
    base.alpha_composite(ph, (px, py))
    canvas = base.convert("RGB")
    draw = ImageDraw.Draw(canvas)

    badge = check_badge(110)
    point = bold(76)
    text_w = px - m - 150 - 70
    blocks = [wrap(item, point, text_w) for item in words["points"]]
    step = 98
    gap = 120
    total = sum(max(len(b) * step, 120) for b in blocks) + gap * (len(blocks) - 1)
    ty = py + (ph.size[1] - total) // 2
    for lines in blocks:
        canvas.paste(badge, (m, ty + 2), badge)
        ly = ty
        for line in lines:
            draw.text((m + 150, ly), line, font=point, fill=TEXT)
            ly += step
        ty += max(len(lines) * step, 120) + gap

    # The card at the bottom: the QR code, what to do, where, which systems.
    shadow = Image.new("RGBA", POSTER, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((m, cy + 24, W - m, cy + card_h + 24), 60, fill=(70, 40, 140, 45))
    base = canvas.convert("RGBA")
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(30)))
    canvas = base.convert("RGB")
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((m, cy, W - m, cy + card_h), 60, fill=CARD, outline=LINE, width=3)
    n = len(matrix) + 8
    module = (card_h - 80) // n
    code = qr_image(matrix, module)
    qx, qy = m + 50, cy + (card_h - code.size[0]) // 2
    canvas.paste(code, (qx, qy))
    tx = qx + code.size[0] + 70
    tw = W - m - 60 - tx
    scan = bold(96)
    while draw.textlength(words["scan"], font=scan) > tw:
        scan = bold(scan.size - 4)
    url = bold(56)
    while draw.textlength(SHORT, font=url) > tw:
        url = bold(url.size - 2)
    systems = regular(52)
    ty = cy + 120
    draw.text((tx, ty), words["scan"], font=scan, fill=TEXT)
    draw.text((tx, ty + 150), SHORT, font=url, fill=LINK)
    draw.text((tx, ty + 240), words["systems"], font=systems, fill=MUTED)
    return canvas, (qx, qy, code.size[0])


def save_png(image, path, limit):
    image.save(path, optimize=True, dpi=(300, 300))
    if os.path.getsize(path) > limit:
        image.quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG).save(
            path, optimize=True, dpi=(300, 300))


def report(path):
    print(f"promo_materials: {os.path.relpath(path, ROOT)} {os.path.getsize(path) // 1024} KB")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    icon = Image.open(ICON).convert("RGB")
    matrix = qr_matrix()

    path = os.path.join(args.out, "zen-qr-about.svg")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(qr_svg(matrix))
    report(path)
    path = os.path.join(args.out, "zen-qr-about.png")
    qr_image(matrix, 1200 // (len(matrix) + 8)).save(path, optimize=True, dpi=(300, 300))
    report(path)
    for lang in WORDS:
        path = os.path.join(args.out, f"zen-qr-about-{lang}.pdf")
        qr_card_pdf(matrix, icon, lang, path)
        report(path)

    for lang in WORDS:
        picture, (qx, qy, qs) = poster(lang, matrix, icon)
        path = os.path.join(args.out, f"zen-poster-{lang}.png")
        save_png(picture, path, 2400 * 1024)
        report(path)
        preview = picture.resize((620, round(620 * POSTER[1] / POSTER[0])), Image.LANCZOS)
        path = os.path.join(args.out, f"zen-poster-{lang}-preview.webp")
        preview.save(path, "WEBP", quality=82, method=6)
        report(path)
        pdf = Pdf(A4_PT)
        pdf.image(picture, 0, 0, A4_PT[0], A4_PT[1], jpeg=True)
        k = A4_PT[0] / POSTER[0]
        pdf.ops += qr_ops(matrix, qx * k, A4_PT[1] - qy * k, qs * k)
        path = os.path.join(args.out, f"zen-poster-{lang}.pdf")
        pdf.save(path, f"Zen: {' '.join(WORDS[lang]['head'])}")
        report(path)


if __name__ == "__main__":
    main()
