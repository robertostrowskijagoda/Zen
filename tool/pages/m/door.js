// The door code of the door page (/m#<code>), read in the visitor's
// browser (the code never leaves it: it stays after the "#"). The page
// shows only the flat's name; the rest is read to tell a whole code from a
// broken one, and test/flat_door_link_test.dart runs this reader with node
// on codes the app wrote.
//
// Stickers carry link format 2 (FlatDoorCode.linkCode in the app) as
// decimal digits: the bytes as one big-endian number, padded with zeros to
// the digits of 256^n - 1 for its n bytes. In them: the format (2) in the
// high four bits of the first byte and the number of mailbox doors (0-14)
// in the low four, the household's key (32), the door token (12), the
// door's address without its first byte, always 0x02 (15), each mailbox
// door's address the same way (15 each), the sealing key (32) when there
// are mailbox doors, the name (its length in UTF-8 bytes, 7 bits a byte,
// the lowest first, the high bit set while more follow; then the UTF-8)
// and records to the end (a tag, a length and that many bytes; tag 1 is
// until when a short-lived code works, 6 bytes of milliseconds; other tags
// are skipped).
//
// Older stickers carry format 1: base64url of the JSON
// {"v":3,"k":key,"d":token,"a":address,"n":name,"s":doors,"x":seal}.
(function (root) {
  "use strict";

  var MAX_BYTES = 1024;
  var DOORS = 14;

  function b64(bytes, pad) {
    var s = "";
    for (var i = 0; i < bytes.length; i++) { s += String.fromCharCode(bytes[i]); }
    var out = btoa(s).replace(/\+/g, "-").replace(/\//g, "_");
    return pad ? out : out.replace(/=+$/, "");
  }

  function fromBase64Url(text) {
    if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) { return null; }
    var s = text.replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) { s += "="; }
    var raw;
    try { raw = atob(s); } catch (e) { return null; }
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

  // The decimal digits of 256^n - 1, for n = 0 to MAX_BYTES (worked out on
  // whole digits, no floating point).
  var DIGITS = (function () {
    var table = [0], d = [1];
    for (var n = 1; n <= MAX_BYTES; n++) {
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

  // The bytes the decimal [digits] stand for, or null when no number of
  // bytes is written with that many digits (or the number is too large).
  function fromDigits(digits) {
    var n = DIGITS.indexOf(digits.length);
    if (n < 1) { return null; }
    var out = new Uint8Array(n);
    for (var i = 0; i < digits.length; i++) {
      var carry = digits.charCodeAt(i) - 48;
      for (var j = n - 1; j >= 0; j--) {
        var v = out[j] * 10 + carry;
        out[j] = v & 255;
        carry = v >> 8;
      }
      if (carry) { return null; }
    }
    return out;
  }

  // A door's address from its last 15 bytes, as 16 bytes in hex.
  function node(rest) { return "02" + hex(rest); }

  // Link format 2 in [b], or null.
  function decodeLink(b) {
    if (!b.length || b[0] >> 4 !== 2) { return null; }
    var doors = b[0] & 15;
    if (doors > DOORS) { return null; }
    var at = 1;
    function take(n) {
      if (at + n > b.length) { throw new Error("short"); }
      var part = b.subarray(at, at + n);
      at += n;
      return part;
    }
    try {
      var code = { format: 2 };
      code.key = b64(take(32), true);
      code.door = b64(take(12), false);
      code.inbox = node(take(15));
      code.slots = [];
      for (var i = 0; i < doors; i++) { code.slots.push(node(take(15))); }
      code.seal = doors ? b64(take(32), true) : null;
      var length = 0;
      for (var shift = 0; ; shift += 7) {
        var v = take(1)[0];
        length += (v & 127) * Math.pow(2, shift);
        if (v < 128) { break; }
        if (shift >= 14) { return null; }
      }
      code.name = text(take(length));
      code.until = null;
      while (at < b.length) {
        var tag = take(1)[0];
        var data = take(take(1)[0]);
        if (tag === 1 && data.length === 6) {
          var u = 0;
          for (var k = 0; k < 6; k++) { u = u * 256 + data[k]; }
          code.until = u;
        }
      }
      return code;
    } catch (e) {
      return null;
    }
  }

  // Format 1 (base64url of the JSON) in [link], or null.
  function decodeJson(link) {
    if (link.length < 16 || link.length > 2000) { return null; }
    var b = fromBase64Url(link);
    if (!b) { return null; }
    var json;
    try { json = JSON.parse(text(b)); } catch (e) { return null; }
    if (!json || typeof json.k !== "string" || typeof json.d !== "string" ||
        typeof json.a !== "string" || typeof json.n !== "string") {
      return null;
    }
    return { format: 1, key: json.k, door: json.d, inbox: json.a, name: json.n };
  }

  // The door code in [link] (the text after "#", or after "zen-flat:"):
  // {format, name, ...}, or null when it is not a well-formed one. The name
  // is cut to 150 letters, as the app cuts it.
  function decode(link) {
    if (typeof link !== "string") { return null; }
    link = link.replace(/^zen-flat:/, "");
    var code;
    if (/^[0-9]+$/.test(link)) {
      var b = fromDigits(link);
      code = b ? decodeLink(b) : null;
    } else {
      code = decodeJson(link);
    }
    if (code) { code.name = code.name.slice(0, 150); }
    return code;
  }

  var api = { decode: decode, fromDigits: fromDigits };
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.ZenDoor = api;
  }
})(this);
