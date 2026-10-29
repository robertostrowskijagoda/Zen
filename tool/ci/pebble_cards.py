#!/usr/bin/env python3
"""Writes the test cards of the pebble page (tool/pages/k), signed with a
fixed test key, and what the page must read from each.

  python3 tool/ci/pebble_cards.py           writes tool/ci/pebble_card_vectors.json
  python3 tool/ci/pebble_cards.py --check   fails when that file is not what
                                            this script writes, or when the
                                            signer misses RFC 8032's examples

A card (format v1, all integers big-endian, base64url without padding in the
link https://robertostrowskijagoda.github.io/Zen/k/#<card>):

  u8 version = 1 | 16 bytes pebble id | 32 bytes author key (Ed25519)
  u32 created (Unix seconds) | u8 shape preset | u32 shape seed
  u8 material preset | 3 bytes main colour | 3 bytes second colour
  u8 length + UTF-8 name | u8 length + UTF-8 note | u8 length + UTF-8 author
  u8 thumbnail length (0 or 176): 16 colours x 3 bytes, then 16 x 16 pixels
     of 4 bits, row by row from the top, the left pixel in the high half of
     each byte; colour 0 is transparent
  64 bytes Ed25519 signature over everything before it

test/pages_site_test.dart runs the page's decoder (tool/pages/k/pebble.js)
on every card with node and compares what it reads. Ed25519 is written out
here (RFC 8032, section 6) because the standard library has none; it only
signs test cards. Standard library only.
"""

import base64
import hashlib
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "pebble_card_vectors.json")
LINK = "https://robertostrowskijagoda.github.io/Zen/k/#"

# --- Ed25519 (RFC 8032) -------------------------------------------------------

P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _sha512(data):
    return hashlib.sha512(data).digest()


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    aa = (y1 - x1) * (y2 - x2) % P
    bb = (y1 + x1) * (y2 + x2) % P
    cc = t1 * 2 * D * t2 % P
    dd = z1 * 2 * z2 % P
    e, f, g, h = bb - aa, dd - cc, dd + cc, bb + aa
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s, point):
    out = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            out = _add(out, point)
        point = _add(point, point)
        s >>= 1
    return out


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


_GY = 4 * pow(5, P - 2, P) % P
_GX = _recover_x(_GY, 0)
G = (_GX, _GY, 1, _GX * _GY % P)


def _compress(point):
    zinv = pow(point[2], P - 2, P)
    x = point[0] * zinv % P
    y = point[1] * zinv % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _expand(secret):
    h = _sha512(secret)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(secret):
    """The Ed25519 public key of the 32-byte [secret]."""
    a, _ = _expand(secret)
    return _compress(_mul(a, G))


def sign(secret, message):
    """The Ed25519 signature of [message] by [secret] (RFC 8032, 5.1.6)."""
    a, prefix = _expand(secret)
    key = _compress(_mul(a, G))
    r = int.from_bytes(_sha512(prefix + message), "little") % L
    big_r = _compress(_mul(r, G))
    k = int.from_bytes(_sha512(big_r + key + message), "little") % L
    return big_r + int.to_bytes((r + k * a) % L, 32, "little")


# RFC 8032, 7.1: TEST 1, 2 and 3 (secret, public key, message, signature).
RFC8032 = [
    ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
     "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
     "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
     "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
     "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
    ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
     "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
     "af82",
     "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
     "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
]


def check_rfc8032():
    """The signer gives RFC 8032's signatures; the problems found."""
    problems = []
    for number, (secret, key, message, signature) in enumerate(RFC8032, 1):
        s = bytes.fromhex(secret)
        if public_key(s).hex() != key:
            problems.append(f"RFC 8032 TEST {number}: another public key")
        if sign(s, bytes.fromhex(message)).hex() != signature:
            problems.append(f"RFC 8032 TEST {number}: another signature")
    return problems


# --- Cards --------------------------------------------------------------------

#: The test author's secret (never a real account's).
TEST_SECRET = hashlib.sha256(b"zen pebble test author").digest()
#: Another test account, for a card whose key is not the signer's.
OTHER_SECRET = hashlib.sha256(b"zen pebble other author").digest()


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _text(value):
    raw = value.encode("utf-8")
    if len(raw) > 255:
        raise ValueError(f"too long: {value!r}")
    return bytes([len(raw)]) + raw


def ladybird():
    """A 16 x 16 top view of a ladybird: (palette, pixels), 0 transparent."""
    palette = [(0, 0, 0), (214, 58, 47), (27, 27, 31), (250, 250, 245)]
    palette += [(0, 0, 0)] * (16 - len(palette))
    pixels = []
    for row in range(16):
        for col in range(16):
            x, y = (col - 7.5) / 7.5, (row - 8.0) / 7.2
            if x * x + y * y > 1.0:
                pixels.append(0)
            elif y < -0.55:
                # The head, with two white eyes.
                pixels.append(3 if abs(abs(x) - 0.28) < 0.12 and y > -0.8 else 2)
            elif abs(x) < 0.07 or any((x - sx) ** 2 + (y - sy) ** 2 < 0.045
                                      for sx, sy in ((-0.45, -0.1), (0.45, -0.1),
                                                     (-0.4, 0.45), (0.4, 0.45))):
                pixels.append(2)
            else:
                pixels.append(1)
    return palette, pixels


def stripes():
    """A 16 x 16 top view of three stripes, a ring of transparency around."""
    palette = [(0, 0, 0), (40, 92, 160), (238, 232, 214), (231, 168, 63)]
    palette += [(10 * i, 10 * i, 10 * i) for i in range(4, 16)]
    pixels = []
    for row in range(16):
        for col in range(16):
            x, y = (col - 7.5) / 8.0, (row - 7.5) / 8.0
            if x * x + y * y > 0.95:
                pixels.append(0)
            else:
                pixels.append(1 + (row // 4) % 3)
    return palette, pixels


def thumbnail_bytes(thumb):
    palette, pixels = thumb
    out = bytearray()
    for r, g, b in palette:
        out += bytes([r, g, b])
    for i in range(0, 256, 2):
        out.append((pixels[i] << 4) | pixels[i + 1])
    return bytes(out)


def card_body(c, key):
    thumb = thumbnail_bytes(c["thumbnail"]) if c["thumbnail"] else b""
    body = bytearray([1])
    body += c["id"]
    body += key
    body += struct.pack(">IBIB", c["created"], c["shape"], c["seed"], c["material"])
    body += bytes(c["main"]) + bytes(c["second"])
    body += _text(c["name"]) + _text(c["note"]) + _text(c["author"])
    body += bytes([len(thumb)]) + thumb
    return bytes(body)


def signed_card(c, secret=TEST_SECRET, key=None):
    body = card_body(c, key if key is not None else public_key(secret))
    return body + sign(secret, body)


def expected(c, key, valid):
    def colour(rgb):
        return "#%02x%02x%02x" % tuple(rgb)

    thumb = None
    if c["thumbnail"]:
        palette, pixels = c["thumbnail"]
        thumb = {"palette": [colour(p) for p in palette], "pixels": pixels}
    return {
        "version": 1,
        "id": c["id"].hex(),
        "authorKey": key.hex(),
        "created": c["created"],
        "shape": c["shape"],
        "seed": c["seed"],
        "material": c["material"],
        "main": colour(c["main"]),
        "second": colour(c["second"]),
        "name": c["name"],
        "note": c["note"],
        "author": c["author"],
        "thumbnail": thumb,
        "signature": "valid" if valid else "invalid",
    }


def base_cards():
    return {
        "ladybird": {
            "id": hashlib.sha256(b"Biedronka").digest()[:16],
            "created": 1790000000,
            "shape": 3, "seed": 0x5EED1234, "material": 1,
            "main": (214, 58, 47), "second": (27, 27, 31),
            "name": "Biedronka", "note": "niedaleko Wisły w Warszawie", "author": "Kasia",
            "thumbnail": ladybird(),
        },
        "planet": {
            "id": hashlib.sha256(b"Planeta").digest()[:16],
            "created": 1767225600,
            "shape": 0, "seed": 0xFFFFFFFF, "material": 4,
            "main": (40, 92, 160), "second": (231, 168, 63),
            "name": "Planeta 🪐", "note": "", "author": "Zoë",
            "thumbnail": None,
        },
        "right-to-left": {
            "id": hashlib.sha256(b"rtl").digest()[:16],
            "created": 1800000000,
            "shape": 21, "seed": 7, "material": 33,
            "main": (238, 232, 214), "second": (40, 92, 160),
            "name": "حجر النهر", "note": "قرب الجسر القديم", "author": "ليلى",
            "thumbnail": stripes(),
        },
        "longest": {
            "id": bytes(range(16)),
            "created": 4294967295,
            "shape": 255, "seed": 0, "material": 255,
            "main": (0, 0, 0), "second": (255, 255, 255),
            "name": "Ż" * 40, "note": "n" * 100, "author": "Ą" * 32,
            "thumbnail": ladybird(),
        },
    }


def vectors():
    cards = base_cards()
    key = public_key(TEST_SECRET)
    out = []
    for name, c in cards.items():
        out.append({"name": name, "card": b64url(signed_card(c)), "expect": expected(c, key, True)})

    good = signed_card(cards["ladybird"])
    # One letter of the note changed after signing: still a card, not the
    # author's.
    at = good.index("Warszawie".encode("utf-8")) + len("Warszawi")
    tampered = good[:at] + b"a" + good[at + 1:]
    changed = dict(cards["ladybird"], note="niedaleko Wisły w Warszawia")
    out.append({"name": "tampered", "card": b64url(tampered), "expect": expected(changed, key, False)})
    # Signed by another account than the one it names.
    other = signed_card(cards["ladybird"], secret=OTHER_SECRET, key=key)
    out.append({"name": "other-signer", "card": b64url(other),
                "expect": expected(cards["ladybird"], key, False)})

    # Not cards at all: the page shows that the pebble cannot be read.
    body = card_body(cards["planet"], key)
    sig = sign(TEST_SECRET, body)
    broken = {
        "empty": "",
        "not-base64": "kamyczek!",
        "one-char-too-many": b64url(body + sig) + "A",
        "truncated": b64url((body + sig)[:-1]),
        "trailing-byte": b64url(body + sig + b"\0"),
        "version-2": b64url(b"\2" + (body + sig)[1:]),
        "thumbnail-length-100": b64url(body[:-1] + b"\x64" + bytes(100) + sig),
        "name-not-utf8": None,
        "padded": b64url(body + sig) + "==",
    }
    name_at = 1 + 16 + 32 + 4 + 1 + 4 + 1 + 6
    bad_name = bytearray(body)
    bad_name[name_at + 1] = 0xFF
    broken["name-not-utf8"] = b64url(bytes(bad_name) + sign(TEST_SECRET, bytes(bad_name)))
    for name, text in broken.items():
        out.append({"name": name, "card": text, "expect": None})
    return {
        "link": LINK,
        "authorKey": key.hex(),
        "rfc8032": [{"key": k, "message": m, "signature": s} for _, k, m, s in RFC8032],
        "vectors": out,
    }


def render():
    return json.dumps(vectors(), ensure_ascii=False, indent=1) + "\n"


def main(argv):
    problems = check_rfc8032()
    if problems:
        print("\n".join(problems))
        return 1
    text = render()
    if "--check" in argv:
        try:
            with open(OUT, encoding="utf-8") as f:
                kept = f.read()
        except OSError:
            kept = ""
        if kept != text:
            print(f"{os.path.relpath(OUT)} is stale: run python3 tool/ci/pebble_cards.py")
            return 1
        print("pebble cards: up to date")
        return 0
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"pebble cards: wrote {len(vectors()['vectors'])} cards to {os.path.relpath(OUT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
