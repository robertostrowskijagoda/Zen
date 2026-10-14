import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_codec.dart';

/// Shamir's secret sharing over GF(256), byte by byte: any [threshold] of
/// the shares give back the secret, fewer say nothing about it.
///
/// A share is `[x, y0, y1, …]` with x in 1..255.

final List<int> _exp = List<int>.filled(512, 0);
final List<int> _log = List<int>.filled(256, 0);
bool _tablesReady = false;

void _tables() {
  if (_tablesReady) {
    return;
  }
  int x = 1;
  for (int i = 0; i < 255; i++) {
    _exp[i] = x;
    _log[x] = i;
    // Multiply by the generator 3 in GF(2^8) mod x^8+x^4+x^3+x+1.
    x ^= (x << 1) ^ ((x & 0x80) != 0 ? 0x11b : 0);
    x &= 0xff;
  }
  for (int i = 255; i < 512; i++) {
    _exp[i] = _exp[i - 255];
  }
  _tablesReady = true;
}

int _mul(int a, int b) {
  if (a == 0 || b == 0) {
    return 0;
  }
  return _exp[_log[a] + _log[b]];
}

int _div(int a, int b) {
  if (b == 0) {
    throw ArgumentError('Dzielenie przez zero w GF(256).');
  }
  if (a == 0) {
    return 0;
  }
  return _exp[_log[a] + 255 - _log[b]];
}

/// Splits [secret] into [count] shares, any [threshold] of which recover it.
List<Uint8List> shamirSplit(Uint8List secret, int threshold, int count) {
  _tables();
  if (threshold < 1 || threshold > count || count > 255) {
    throw ArgumentError('Nieprawidłowy próg albo liczba udziałów.');
  }
  final List<Uint8List> shares = <Uint8List>[
    for (int i = 1; i <= count; i++) Uint8List(secret.length + 1)..[0] = i,
  ];
  for (int b = 0; b < secret.length; b++) {
    // Random polynomial with the secret byte as constant term.
    final Uint8List coeffs = randomBytes(threshold)..[0] = secret[b];
    for (final Uint8List share in shares) {
      final int x = share[0];
      int y = 0;
      for (int k = threshold - 1; k >= 0; k--) {
        y = _mul(y, x) ^ coeffs[k];
      }
      share[b + 1] = y;
    }
  }
  return shares;
}

/// Recovers the secret from [shares] (at least the threshold, distinct x).
/// With too few shares the result is simply wrong, so callers check it
/// (e.g. by decrypting something with it).
Uint8List shamirCombine(List<Uint8List> shares) {
  _tables();
  if (shares.isEmpty) {
    throw ArgumentError('Brak udziałów.');
  }
  final int length = shares.first.length;
  final Set<int> xs = <int>{};
  for (final Uint8List s in shares) {
    if (s.length != length || s[0] == 0 || !xs.add(s[0])) {
      throw ArgumentError('Udziały nie pasują do siebie.');
    }
  }
  final Uint8List secret = Uint8List(length - 1);
  for (int b = 1; b < length; b++) {
    int value = 0;
    for (int i = 0; i < shares.length; i++) {
      final int xi = shares[i][0];
      // Lagrange basis at 0: prod xj / (xj - xi); minus is xor in GF(2^8).
      int basis = 1;
      for (int j = 0; j < shares.length; j++) {
        if (i != j) {
          final int xj = shares[j][0];
          basis = _mul(basis, _div(xj, xj ^ xi));
        }
      }
      value ^= _mul(shares[i][b], basis);
    }
    secret[b - 1] = value;
  }
  return secret;
}
