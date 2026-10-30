// The pebble card of the pebble page (/k/#<card>): read, and checked
// against its author's signature when it carries one, all in the visitor's
// browser (the card never leaves it: it stays after the "#").
//
// Stickers carry the QR card (format v2) as decimal digits: the card's
// bytes as one big-endian number, padded with zeros to the digits of
// 256^n - 1 for its n bytes. It holds version 2, the pebble id (16), the
// author's key (32), shape preset (u8), shape seed (u32), material preset
// (u8), main and second colour (RGB), the name (u8 length + at most 24
// bytes of UTF-8) and the author (u8 length + at most 16 bytes). It is not
// signed: the app checks the author's signature on the full card that
// comes with the design, and the page says so.
//
// The first test builds' links carry the full card (format v1, integers
// big-endian, base64url; tool/ci/pebble_cards.py writes test cards of both
// formats and documents every field): version 1, the pebble id (16),
// the author's key (Ed25519, 32), created (u32 Unix seconds), shape preset
// (u8), shape seed (u32), material preset (u8), main and second colour
// (RGB), the name, note and author (u8 length + UTF-8 each), the thumbnail
// (u8 length, 0 or 176: 16 RGB colours, then 16 x 16 pixels of 4 bits, the
// left one high, colour 0 transparent) and the Ed25519 signature (64) over
// everything before it.
//
// The signature is checked with the browser's own Ed25519 (Web Crypto)
// where it has one, otherwise with the short verifier below (RFC 8032,
// BigInt arithmetic, SHA-512 from Web Crypto): both give the same answer,
// test/pages_site_test.dart runs them on the test cards with node. Without
// either the page says the app checks the signature.
(function (root) {
  "use strict";

  var THUMB = 16 * 3 + 128;

  // base64url without padding, strictly: anything else is not a card.
  function fromBase64Url(text) {
    if (typeof text !== "string" || !/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) {
      return null;
    }
    var b64 = text.replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) { b64 += "="; }
    var raw;
    try { raw = atob(b64); } catch (e) { return null; }
    var out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) { out[i] = raw.charCodeAt(i); }
    return out;
  }

  function hex(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i++) { s += (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16); }
    return s;
  }

  var utf8 = typeof TextDecoder === "function" ? new TextDecoder("utf-8", { fatal: true }) : null;
  function text(bytes) {
    if (utf8) { return utf8.decode(bytes); }
    var s = "";
    for (var i = 0; i < bytes.length; i++) { s += "%" + (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16); }
    return decodeURIComponent(s);
  }

  // The decimal digits of 256^n - 1, for n = 0 to 255 (worked out on whole
  // digits, no floating point).
  var DIGITS = (function () {
    var table = [0], d = [1];
    for (var n = 1; n <= 255; n++) {
      var carry = 0;
      for (var i = 0; i < d.length; i++) {
        var v = d[i] * 256 + carry;
        d[i] = v % 10;
        carry = Math.floor(v / 10);
      }
      while (carry) { d.push(carry % 10); carry = Math.floor(carry / 10); }
      table.push(d.length);
    }
    return table;
  })();

  // The bytes the decimal [text] stands for, or null when no number of
  // bytes is written with that many digits (or the number is too large).
  function fromDigits(text) {
    if (typeof text !== "string" || !/^[0-9]+$/.test(text)) { return null; }
    var n = DIGITS.indexOf(text.length);
    if (n < 1) { return null; }
    var out = new Uint8Array(n);
    for (var i = 0; i < text.length; i++) {
      var carry = text.charCodeAt(i) - 48;
      for (var j = n - 1; j >= 0; j--) {
        var v = out[j] * 10 + carry;
        out[j] = v & 255;
        carry = v >> 8;
      }
      if (carry) { return null; }
    }
    return out;
  }

  // The QR card in [b] (format v2), or null. Since Zen 1.15.3 a sticker
  // may name up to 3 keepers after it (u8 count, 16 bytes of each network
  // address): whom the app asks for the full design. The page shows none
  // of them; the link it opens in the app keeps them.
  function decodeQr(b) {
    if (b.length < 1 + 16 + 32 + 12 + 2 || b.length > 1 + 16 + 32 + 12 + 1 + 24 + 1 + 16 + 1 + 3 * 16) { return null; }
    var at = 1;
    function take(n) {
      if (at + n > b.length) { throw new Error("short"); }
      var part = b.subarray(at, at + n);
      at += n;
      return part;
    }
    function u8() { return take(1)[0]; }
    function u32() { var p = take(4); return ((p[0] << 24) >>> 0) + (p[1] << 16) + (p[2] << 8) + p[3]; }
    function rgb() { var p = take(3); return [p[0], p[1], p[2]]; }
    function limited(max) { var n = u8(); if (n > max) { throw new Error("long"); } return text(take(n)); }
    try {
      var card = { version: 2 };
      card.id = take(16);
      card.authorKey = take(32);
      card.shape = u8();
      card.seed = u32();
      card.material = u8();
      card.main = rgb();
      card.second = rgb();
      card.name = limited(24);
      card.author = limited(16);
      card.note = "";
      card.created = null;
      card.thumbnail = null;
      card.keepers = 0;
      if (at < b.length) {
        var n = u8();
        if (n < 1 || n > 3 || at + 16 * n !== b.length) { return null; }
        card.keepers = n;
        at += 16 * n;
      }
      if (at !== b.length) { return null; }
      return card;
    } catch (e) {
      return null;
    }
  }

  // The card in [link] (the text after "#": the digits of a QR card, or
  // the base64url of a card), or null when it is not a whole, well-formed
  // card of version 1 or 2.
  function decode(link) {
    if (/^[0-9]+$/.test(link)) {
      var q = fromDigits(link);
      return q && q[0] === 2 ? decodeQr(q) : null;
    }
    var b = fromBase64Url(link);
    if (b && b.length && b[0] === 2) { return decodeQr(b); }
    if (!b || b.length < 1 + 16 + 32 + 4 + 1 + 4 + 1 + 6 + 3 + 1 + 64 || b[0] !== 1) { return null; }
    var at = 1;
    function take(n) {
      if (at + n > b.length) { throw new Error("short"); }
      var part = b.subarray(at, at + n);
      at += n;
      return part;
    }
    function u8() { return take(1)[0]; }
    function u32() { var p = take(4); return ((p[0] << 24) >>> 0) + (p[1] << 16) + (p[2] << 8) + p[3]; }
    function rgb() { var p = take(3); return [p[0], p[1], p[2]]; }
    try {
      var card = { version: 1 };
      card.id = take(16);
      card.authorKey = take(32);
      card.created = u32();
      card.shape = u8();
      card.seed = u32();
      card.material = u8();
      card.main = rgb();
      card.second = rgb();
      card.name = text(take(u8()));
      card.note = text(take(u8()));
      card.author = text(take(u8()));
      var thumbLength = u8();
      card.thumbnail = null;
      if (thumbLength === THUMB) {
        var palette = [];
        for (var i = 0; i < 16; i++) { palette.push(rgb()); }
        var packed = take(128), pixels = new Uint8Array(256);
        for (var j = 0; j < 128; j++) {
          pixels[2 * j] = packed[j] >> 4;
          pixels[2 * j + 1] = packed[j] & 15;
        }
        card.thumbnail = { palette: palette, pixels: pixels };
      } else if (thumbLength !== 0) {
        return null;
      }
      card.signed = b.subarray(0, at);
      card.signature = take(64);
      if (at !== b.length) { return null; }
      return card;
    } catch (e) {
      return null;
    }
  }

  // --- Ed25519 verification (RFC 8032, 5.1.7), for browsers without it ------

  var hasBigInt = typeof BigInt === "function";
  var N = hasBigInt ? function (v) { return BigInt(v); } : null;
  var C = hasBigInt ? (function () {
    var p = (N(1) << N(255)) - N(19);
    var c = {
      p: p,
      l: (N(1) << N(252)) + N("27742317777372353535851937790883648493"),
      zero: N(0), one: N(1), two: N(2), eight: N(8)
    };
    function mod(a) { var r = a % p; return r < c.zero ? r + p : r; }
    function pow(b, e) {
      var r = c.one;
      b = mod(b);
      while (e > c.zero) {
        if (e & c.one) { r = r * b % p; }
        b = b * b % p;
        e >>= c.one;
      }
      return r;
    }
    c.mod = mod;
    c.pow = pow;
    c.inv = function (a) { return pow(a, p - c.two); };
    c.d = mod(N(-121665) * c.inv(N(121666)));
    c.d2 = mod(c.d * c.two);
    c.i = pow(c.two, (p - c.one) / N(4));
    var gy = mod(N(4) * c.inv(N(5)));
    var gx = N("15112221349535400772501151409588531511454012693041857206046113283949847762202");
    c.g = [gx, gy, c.one, mod(gx * gy)];
    return c;
  })() : null;

  function add(a, b) {
    var m = C.mod;
    var A = m((a[1] - a[0]) * (b[1] - b[0])), B = m((a[1] + a[0]) * (b[1] + b[0]));
    var Cc = m(a[3] * C.d2 * b[3]), D = m(a[2] * C.two * b[2]);
    var E = B - A, F = D - Cc, G = D + Cc, H = B + A;
    return [m(E * F), m(G * H), m(F * G), m(E * H)];
  }
  function mul(s, point) {
    var out = [C.zero, C.one, C.one, C.zero];
    while (s > C.zero) {
      if (s & C.one) { out = add(out, point); }
      point = add(point, point);
      s >>= C.one;
    }
    return out;
  }
  function le(bytes) {
    var n = C.zero;
    for (var i = bytes.length - 1; i >= 0; i--) { n = (n << C.eight) + N(bytes[i]); }
    return n;
  }
  // A point from its 32 bytes, or null.
  function point(bytes) {
    var top = bytes[31];
    var copy = new Uint8Array(bytes);
    copy[31] = top & 127;
    var y = le(copy), sign = top >> 7;
    if (y >= C.p) { return null; }
    var y2 = C.mod(y * y), u = C.mod(y2 - C.one), v = C.mod(C.d * y2 + C.one);
    var v3 = C.mod(v * v * v);
    var x = C.mod(u * v3 * C.pow(u * v3 * v3 * v, (C.p - N(5)) / C.eight));
    var vx2 = C.mod(v * x * x);
    if (vx2 !== u) {
      if (vx2 === C.mod(-u)) { x = C.mod(x * C.i); } else { return null; }
    }
    if (x === C.zero && sign) { return null; }
    if (Number(x & C.one) !== sign) { x = C.p - x; }
    return [x, y, C.one, C.mod(x * y)];
  }
  function encode(pt) {
    var zi = C.inv(pt[2]);
    var x = C.mod(pt[0] * zi), y = C.mod(pt[1] * zi);
    var out = new Uint8Array(32);
    for (var i = 0; i < 32; i++) { out[i] = Number(y & N(255)); y >>= C.eight; }
    out[31] |= Number(x & C.one) << 7;
    return out;
  }
  function concat(parts) {
    var length = 0, i;
    for (i = 0; i < parts.length; i++) { length += parts[i].length; }
    var out = new Uint8Array(length), at = 0;
    for (i = 0; i < parts.length; i++) { out.set(parts[i], at); at += parts[i].length; }
    return out;
  }
  function subtleCrypto() {
    var c = typeof crypto !== "undefined" ? crypto : null;
    return c && c.subtle ? c.subtle : null;
  }

  // true / false, or null when this browser cannot tell (no BigInt or no
  // SHA-512).
  function verifyPure(key, signature, message) {
    var subtle = subtleCrypto();
    if (!C || !subtle || key.length !== 32 || signature.length !== 64) {
      return Promise.resolve(C && subtle ? false : null);
    }
    var r = signature.subarray(0, 32), s = le(signature.subarray(32));
    var a = point(key);
    if (s >= C.l || !a) { return Promise.resolve(false); }
    return subtle.digest("SHA-512", concat([r, key, message])).then(function (h) {
      var k = le(new Uint8Array(h)) % C.l;
      var minusA = [C.p - a[0], a[1], a[2], C.p - a[3]];
      // [S]B - [k]A is R for the author's signature.
      var back = encode(add(mul(s, C.g), mul(k, minusA)));
      for (var i = 0; i < 32; i++) { if (back[i] !== r[i]) { return false; } }
      return true;
    }, function () { return null; });
  }

  // The browser's own Ed25519: true / false, or null without it.
  function verifyNative(key, signature, message) {
    var subtle = subtleCrypto();
    if (!subtle) { return Promise.resolve(null); }
    try {
      return subtle.importKey("raw", key, { name: "Ed25519" }, false, ["verify"])
        .then(function (k) { return subtle.verify({ name: "Ed25519" }, k, signature, message); })
        .then(function (ok) { return !!ok; }, function () { return null; });
    } catch (e) {
      return Promise.resolve(null);
    }
  }

  // "valid" (signed by the key in the card), "invalid", "unknown" when
  // this browser cannot check it, or "unsigned" for a QR card (the app
  // checks the full card's signature).
  function verify(card) {
    if (card.version === 2) { return Promise.resolve("unsigned"); }
    return verifyNative(card.authorKey, card.signature, card.signed).then(function (ok) {
      return ok === null ? verifyPure(card.authorKey, card.signature, card.signed) : ok;
    }).then(function (ok) {
      return ok === null ? "unknown" : (ok ? "valid" : "invalid");
    });
  }

  var api = {
    decode: decode,
    verify: verify,
    verifyNative: verifyNative,
    verifyPure: verifyPure,
    fromBase64Url: fromBase64Url,
    fromDigits: fromDigits,
    hex: hex
  };
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.ZenPebble = api;
  }
})(this);
