import 'dart:typed_data';

// Bytes as decimal digits, for what goes after the "#" of a sticker's
// link: a QR code writes digits in its numeric mode at 3.3 bits each, so
// the bytes cost hardly more than their own 8 bits (base64url takes 8 bits
// per 6 even in the more compact segments). The pebble and door pages read
// the same digits (tool/pages/k/pebble.js, tool/pages/m/door.js).

/// [bytes] as one big-endian number in decimal, padded with zeros to the
/// digits of the largest number of that many bytes (so the length tells
/// how many bytes there are: [qrBytesFromDigits]).
String qrDigits(List<int> bytes) {
  BigInt v = BigInt.zero;
  for (final int b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v.toString().padLeft(qrDigitsFor(bytes.length), '0');
}

/// The bytes [digits] stand for ([qrDigits]), at most [maxBytes] of them;
/// `null` when no number of bytes is written with that many digits, or
/// for anything but digits.
Uint8List? qrBytesFromDigits(String digits, {required int maxBytes}) {
  if (!_digits.hasMatch(digits)) {
    return null;
  }
  int n = 0;
  while (n <= maxBytes && qrDigitsFor(n) < digits.length) {
    n++;
  }
  if (n > maxBytes || qrDigitsFor(n) != digits.length) {
    return null;
  }
  BigInt v = BigInt.parse(digits);
  if (v.bitLength > n * 8) {
    return null;
  }
  final Uint8List out = Uint8List(n);
  for (int i = n - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v >>= 8;
  }
  return out;
}

final RegExp _digits = RegExp(r'^[0-9]+$');

/// The decimal digits of 256^[n] − 1, worked out on whole digits (the
/// same table the pages build).
int qrDigitsFor(int n) {
  while (_table.length <= n) {
    int carry = 0;
    for (int i = 0; i < _power.length; i++) {
      final int v = _power[i] * 256 + carry;
      _power[i] = v % 10;
      carry = v ~/ 10;
    }
    while (carry > 0) {
      _power.add(carry % 10);
      carry ~/= 10;
    }
    _table.add(_power.length);
  }
  return _table[n];
}

/// [qrDigitsFor] so far, and 256^(its length − 1) in decimal digits, the
/// lowest first.
final List<int> _table = <int>[0];
final List<int> _power = <int>[1];
