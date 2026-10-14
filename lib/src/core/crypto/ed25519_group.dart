import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Arithmetic on the Ed25519 curve (twisted Edwards, RFC 8032), just enough
/// for the ring signatures of the pyramid (§20.3a). Plain [BigInt]: slow
/// next to native code, but a ring of three takes milliseconds.
///
/// Not for anything secret-dependent in a hostile timing environment: the
/// operations are not constant-time.
abstract final class Ed25519Group {
  static final BigInt p = (BigInt.one << 255) - BigInt.from(19);

  /// Order of the prime subgroup.
  static final BigInt l =
      (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');

  static final BigInt d =
      (BigInt.from(-121665) * BigInt.from(121666).modInverse(p)) % p;

  static final BigInt _sqrtM1 = BigInt.parse(
    '19681161376707505956807079304988542015446066515923890162744021073123829784752',
  );

  static final EdPoint base = EdPoint._affine(
    BigInt.parse(
      '15112221349535400772501151409588531511454012693041857206046113283949847762202',
    ),
    BigInt.parse(
      '46316835694926478169428394003475163141307993866256225615783033603165251855960',
    ),
  );

  static final EdPoint identity = EdPoint._(
    BigInt.zero,
    BigInt.one,
    BigInt.one,
    BigInt.zero,
  );

  static BigInt _mod(BigInt a) => a % p;

  /// Little-endian bytes to a number.
  static BigInt fromLe(List<int> bytes) {
    BigInt r = BigInt.zero;
    for (int i = bytes.length - 1; i >= 0; i--) {
      r = (r << 8) | BigInt.from(bytes[i]);
    }
    return r;
  }

  static Uint8List toLe(BigInt v, [int length = 32]) {
    final Uint8List out = Uint8List(length);
    BigInt x = v;
    for (int i = 0; i < length; i++) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }

  /// A scalar from any bytes (SHA-512, reduced mod [l]).
  static BigInt hashToScalar(List<int> data) =>
      fromLe(crypto.sha512.convert(data).bytes) % l;

  /// A point of the prime subgroup nobody knows the logarithm of
  /// (try-and-increment, then times the cofactor 8).
  static EdPoint hashToPoint(List<int> data) {
    for (int counter = 0; counter < 1000; counter++) {
      final List<int> h = crypto.sha256
          .convert(<int>[...data, counter & 0xff, (counter >> 8) & 0xff])
          .bytes
          .toList();
      h[31] &= 0x7f;
      final EdPoint? candidate = decode(h);
      if (candidate == null) {
        continue;
      }
      final EdPoint q = candidate.times(BigInt.from(8));
      if (!q.isIdentity) {
        return q;
      }
    }
    throw StateError('hashToPoint failed');
  }

  /// The secret scalar of an Ed25519 key from its 32-byte seed (the same
  /// one Ed25519 signing uses, so its point is the usual public key).
  static BigInt scalarFromSeed(List<int> seed) {
    final List<int> h = crypto.sha512.convert(seed).bytes.sublist(0, 32);
    h[0] &= 248;
    h[31] &= 127;
    h[31] |= 64;
    return fromLe(h);
  }

  static EdPoint? decode(List<int> bytes) {
    if (bytes.length != 32) {
      return null;
    }
    final List<int> b = List<int>.of(bytes);
    final int sign = (b[31] >> 7) & 1;
    b[31] &= 0x7f;
    final BigInt y = fromLe(b);
    if (y >= p) {
      return null;
    }
    final BigInt y2 = _mod(y * y);
    final BigInt u = _mod(y2 - BigInt.one);
    final BigInt v = _mod(d * y2 + BigInt.one);
    final BigInt x2 = _mod(u * v.modInverse(p));
    if (x2 == BigInt.zero) {
      if (sign == 1) {
        return null;
      }
      return EdPoint._affine(BigInt.zero, y);
    }
    BigInt x = x2.modPow((p + BigInt.from(3)) >> 3, p);
    if (_mod(x * x) != x2) {
      x = _mod(x * _sqrtM1);
    }
    if (_mod(x * x) != x2) {
      return null;
    }
    if ((x & BigInt.one).toInt() != sign) {
      x = p - x;
    }
    return EdPoint._affine(x, y);
  }
}

/// A point in extended coordinates.
final class EdPoint {
  EdPoint._(this.x, this.y, this.z, this.t);

  factory EdPoint._affine(BigInt x, BigInt y) =>
      EdPoint._(x, y, BigInt.one, (x * y) % Ed25519Group.p);

  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;

  static BigInt get _p => Ed25519Group.p;

  bool get isIdentity => x % _p == BigInt.zero && (y - z) % _p == BigInt.zero;

  EdPoint operator +(EdPoint o) {
    final BigInt p = _p;
    final BigInt a = ((y - x) * (o.y - o.x)) % p;
    final BigInt b = ((y + x) * (o.y + o.x)) % p;
    final BigInt c = (t * BigInt.two * Ed25519Group.d * o.t) % p;
    final BigInt dd = (z * BigInt.two * o.z) % p;
    final BigInt e = b - a;
    final BigInt f = dd - c;
    final BigInt g = dd + c;
    final BigInt h = b + a;
    return EdPoint._((e * f) % p, (g * h) % p, (f * g) % p, (e * h) % p);
  }

  EdPoint times(BigInt k) {
    BigInt n = k % Ed25519Group.l;
    if (k > BigInt.zero && n == BigInt.zero) {
      // A multiple of the order: exactly the order itself, never a huge
      // multiple (millions of additions for a crafted input). The subgroup
      // check uses [timesRaw].
      n = Ed25519Group.l;
    }
    EdPoint result = Ed25519Group.identity;
    EdPoint addend = this;
    while (n > BigInt.zero) {
      if ((n & BigInt.one) == BigInt.one) {
        result = result + addend;
      }
      addend = addend + addend;
      n = n >> 1;
    }
    return result;
  }

  /// Exactly [k] times (no reduction), for the subgroup check.
  EdPoint timesRaw(BigInt k) {
    BigInt n = k;
    EdPoint result = Ed25519Group.identity;
    EdPoint addend = this;
    while (n > BigInt.zero) {
      if ((n & BigInt.one) == BigInt.one) {
        result = result + addend;
      }
      addend = addend + addend;
      n = n >> 1;
    }
    return result;
  }

  /// In the prime-order subgroup and not the identity.
  bool get isTorsionFreeNonZero =>
      !isIdentity && timesRaw(Ed25519Group.l).isIdentity;

  Uint8List encode() {
    final BigInt p = _p;
    final BigInt zi = z.modInverse(p);
    final BigInt ax = (x * zi) % p;
    final BigInt ay = (y * zi) % p;
    final Uint8List out = Ed25519Group.toLe(ay);
    if ((ax & BigInt.one) == BigInt.one) {
      out[31] |= 0x80;
    }
    return out;
  }

  @override
  bool operator ==(Object other) {
    if (other is! EdPoint) {
      return false;
    }
    final BigInt p = _p;
    return (x * other.z - other.x * z) % p == BigInt.zero &&
        (y * other.z - other.y * z) % p == BigInt.zero;
  }

  @override
  int get hashCode => Object.hashAll(encode());
}
