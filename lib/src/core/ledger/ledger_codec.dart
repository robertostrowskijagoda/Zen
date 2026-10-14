import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Deterministic JSON: object keys sorted, no whitespace, integers only.
///
/// Everything that is signed or hashed goes through this, so two devices
/// always produce the same bytes for the same value. Doubles are refused
/// because their text form is not stable across platforms.
Uint8List canonicalJsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(canonicalJson(value)));

String canonicalJson(Object? value) {
  final StringBuffer out = StringBuffer();
  _write(out, value);
  return out.toString();
}

void _write(StringBuffer out, Object? value) {
  if (value == null || value is bool || value is String) {
    out.write(jsonEncode(value));
  } else if (value is int) {
    out.write(value);
  } else if (value is double) {
    throw ArgumentError('Liczby zmiennoprzecinkowe nie są dozwolone: $value');
  } else if (value is List) {
    out.write('[');
    for (int i = 0; i < value.length; i++) {
      if (i > 0) {
        out.write(',');
      }
      _write(out, value[i]);
    }
    out.write(']');
  } else if (value is Map) {
    final List<String> keys = value.keys.map((Object? k) {
      if (k is! String) {
        throw ArgumentError('Klucze obiektu muszą być tekstem: $k');
      }
      return k;
    }).toList()..sort();
    out.write('{');
    for (int i = 0; i < keys.length; i++) {
      if (i > 0) {
        out.write(',');
      }
      out
        ..write(jsonEncode(keys[i]))
        ..write(':');
      _write(out, value[keys[i]]);
    }
    out.write('}');
  } else {
    throw ArgumentError('Nieobsługiwany typ: ${value.runtimeType}');
  }
}

/// Lower-case hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

String b64(List<int> bytes) => base64Url.encode(bytes);

/// Decodes base64url (padding optional); `null` for anything malformed or
/// not exactly [length] bytes long when [length] is given.
Uint8List? unb64(Object? value, {int? length}) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  try {
    final Uint8List bytes = base64Url.decode(base64Url.normalize(value));
    if (length != null && bytes.length != length) {
      return null;
    }
    return bytes;
  } on FormatException {
    return null;
  }
}

final Random _secureRandom = Random.secure();

Uint8List randomBytes(int length) => Uint8List.fromList(
  List<int>.generate(length, (_) => _secureRandom.nextInt(256)),
);

/// A random id, hex, [bytes] long before encoding.
String randomId([int bytes = 16]) => randomBytes(
  bytes,
).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

bool isHex(Object? value, int length) =>
    value is String &&
    value.length == length &&
    RegExp(r'^[0-9a-f]+$').hasMatch(value);
