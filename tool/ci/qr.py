#!/usr/bin/env python3
"""A small QR code encoder (ISO/IEC 18004), standard library only.

Byte mode, versions 1 to 6 (up to 41x41 modules, enough for a web address
of the site), every error correction level. Used by promo_materials.py to
draw the QR codes of the printed materials; the app draws its own with the
Dart qr package, which made the same modules for the same mask when this
was written.

  matrix = encode("https://robertostrowskijagoda.github.io/Zen/about/", "Q")
  matrix[row][col] is True for a dark module (no quiet zone).
"""

# Error correction codewords per block and the blocks of each version and
# level: (ec per block, [(blocks, data codewords per block), ...]).
_BLOCKS = {
    1: {"L": (7, [(1, 19)]), "M": (10, [(1, 16)]), "Q": (13, [(1, 13)]), "H": (17, [(1, 9)])},
    2: {"L": (10, [(1, 34)]), "M": (16, [(1, 28)]), "Q": (22, [(1, 22)]), "H": (28, [(1, 16)])},
    3: {"L": (15, [(1, 55)]), "M": (26, [(1, 44)]), "Q": (18, [(2, 17)]), "H": (22, [(2, 13)])},
    4: {"L": (20, [(1, 80)]), "M": (18, [(2, 32)]), "Q": (26, [(2, 24)]), "H": (16, [(4, 9)])},
    5: {"L": (26, [(1, 108)]), "M": (24, [(2, 43)]), "Q": (18, [(2, 15), (2, 16)]),
        "H": (22, [(2, 11), (2, 12)])},
    6: {"L": (18, [(2, 68)]), "M": (16, [(4, 27)]), "Q": (24, [(4, 19)]), "H": (28, [(4, 15)])},
}
_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34]}
_LEVEL_BITS = {"L": 1, "M": 0, "Q": 3, "H": 2}

# GF(256) with the polynomial x^8 + x^4 + x^3 + x^2 + 1.
_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _mul(a, b):
    return 0 if a == 0 or b == 0 else _EXP[_LOG[a] + _LOG[b]]


def _ec_codewords(data, n):
    """The [n] Reed-Solomon error correction codewords of [data]."""
    gen = [1]
    for i in range(n):
        nxt = [0] * (len(gen) + 1)
        for j, c in enumerate(gen):
            nxt[j] ^= c
            nxt[j + 1] ^= _mul(c, _EXP[i])
        gen = nxt
    rem = [0] * n
    for byte in data:
        factor = byte ^ rem[0]
        rem = rem[1:] + [0]
        for j in range(n):
            rem[j] ^= _mul(gen[j + 1], factor)
    return rem


def _capacity(version, level):
    ec, groups = _BLOCKS[version][level]
    return sum(count * size for count, size in groups)


def _codewords(data, version, level):
    """The data with its padding and error correction, interleaved."""
    total = _capacity(version, level)
    bits = [0, 1, 0, 0]
    bits += [(len(data) >> i) & 1 for i in range(7, -1, -1)]
    for byte in data:
        bits += [(byte >> i) & 1 for i in range(7, -1, -1)]
    bits += [0] * min(4, total * 8 - len(bits))
    bits += [0] * (-len(bits) % 8)
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0
    while len(words) < total:
        words.append((0xEC, 0x11)[pad % 2])
        pad += 1
    ec, groups = _BLOCKS[version][level]
    blocks, at = [], 0
    for count, size in groups:
        for _ in range(count):
            blocks.append(words[at:at + size])
            at += size
    out = []
    for i in range(max(len(b) for b in blocks)):
        out += [b[i] for b in blocks if i < len(b)]
    ecs = [_ec_codewords(b, ec) for b in blocks]
    for i in range(ec):
        out += [e[i] for e in ecs]
    return out


def _mask(n, x, y):
    return (
        (x + y) % 2 == 0,
        y % 2 == 0,
        x % 3 == 0,
        (x + y) % 3 == 0,
        (x // 3 + y // 2) % 2 == 0,
        x * y % 2 + x * y % 3 == 0,
        (x * y % 2 + x * y % 3) % 2 == 0,
        ((x + y) % 2 + x * y % 3) % 2 == 0,
    )[n]


def _format_bits(level, mask):
    data = _LEVEL_BITS[level] << 3 | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return (data << 10 | rem) ^ 0x5412


class _Grid:
    def __init__(self, version):
        self.size = version * 4 + 17
        self.dark = [[False] * self.size for _ in range(self.size)]
        self.fixed = [[False] * self.size for _ in range(self.size)]

    def put(self, x, y, dark):
        self.dark[y][x] = dark
        self.fixed[y][x] = True


def _function_patterns(grid, version):
    size = grid.size
    for i in range(size):
        grid.put(6, i, i % 2 == 0)
        grid.put(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    d = max(abs(dx), abs(dy))
                    grid.put(x, y, d not in (2, 4))
    pos = _ALIGN[version]
    for i, ay in enumerate(pos):
        for j, ax in enumerate(pos):
            if (i == 0 and j == 0) or (i == 0 and j == len(pos) - 1) or (i == len(pos) - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    grid.put(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1)
    _format(grid, "L", 0)


def _format(grid, level, mask):
    bits = _format_bits(level, mask)
    size = grid.size

    def bit(i):
        return (bits >> i) & 1 == 1

    for i in range(6):
        grid.put(8, i, bit(i))
    grid.put(8, 7, bit(6))
    grid.put(8, 8, bit(7))
    grid.put(7, 8, bit(8))
    for i in range(9, 15):
        grid.put(14 - i, 8, bit(i))
    for i in range(8):
        grid.put(size - 1 - i, 8, bit(i))
    for i in range(8, 15):
        grid.put(8, size - 15 + i, bit(i))
    grid.put(8, size - 8, True)


def _place(grid, words):
    size = grid.size
    i, total = 0, len(words) * 8
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                upward = ((right + 1) & 2) == 0
                y = size - 1 - vert if upward else vert
                if not grid.fixed[y][x] and i < total:
                    grid.dark[y][x] = (words[i >> 3] >> (7 - (i & 7))) & 1 == 1
                    i += 1
        right -= 2


def _penalty(m):
    size = len(m)
    score = 0
    lines = m + [list(col) for col in zip(*m)]
    for line in lines:
        run, prev = 0, None
        for v in line:
            if v == prev:
                run += 1
            else:
                if run >= 5:
                    score += run - 2
                run, prev = 1, v
        if run >= 5:
            score += run - 2
        s = "".join("1" if v else "0" for v in line)
        score += 40 * (s.count("10111010000") + s.count("00001011101"))
    for y in range(size - 1):
        for x in range(size - 1):
            v = m[y][x]
            if v == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                score += 3
    dark = sum(sum(row) for row in m)
    score += abs(dark * 20 - size * size * 10) // (size * size) * 10
    return score


def version_for(data, level):
    """The smallest version (1 to 6) that holds [data] (bytes) at [level]."""
    for version in sorted(_BLOCKS):
        if len(data) + 2 <= _capacity(version, level):
            return version
    raise ValueError(f"{len(data)} bytes do not fit a version 6 QR code at level {level}")


def encode(text, level="M", version=None, mask=None):
    """The modules of a QR code of [text] (UTF-8, byte mode): rows of
    booleans, True for dark. The smallest version that fits unless
    [version] is given, the mask with the lowest penalty unless [mask]."""
    data = text.encode("utf-8")
    version = version or version_for(data, level)
    words = _codewords(data, version, level)
    best = None
    for n in ([mask] if mask is not None else range(8)):
        grid = _Grid(version)
        _function_patterns(grid, version)
        _place(grid, words)
        for y in range(grid.size):
            for x in range(grid.size):
                if not grid.fixed[y][x] and _mask(n, x, y):
                    grid.dark[y][x] = not grid.dark[y][x]
        _format(grid, level, n)
        score = _penalty(grid.dark)
        if best is None or score < best[0]:
            best = (score, grid.dark)
    return best[1]
