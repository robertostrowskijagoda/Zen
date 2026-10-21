import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:zen/src/core/crypto/ed25519_group.dart';

/// A linkable ring signature (LSAG, Liu–Wei–Wong) over Ed25519 keys:
/// it proves that one of the [ring] signed, not which one.
/// Two signatures by the same key under the same [context] carry the same
/// [keyImage] — "the same person asks for the 5th time" — while different
/// contexts cannot be linked.
///
/// Everything that arrives from outside is checked strictly: scalars below
/// the group order, the key image in its one canonical encoding (so one
/// image cannot pass for two), and a malformed signature is simply invalid
/// — it never throws.
///
/// Classical only: there is no standard post-quantum linkable ring
/// signature, so the anonymous cell votes stay on Ed25519 while everything
/// else is signed hybrid (hybrid_signature.dart). A quantum computer would
/// break them in two ways: whoever holds one could forge a vote of a ring
/// at the time of the vote, and could later work out from a recorded vote
/// who cast it (the key image is the signer's secret times a hashed point).
final class RingSignature {
  const RingSignature({
    required this.c0,
    required this.s,
    required this.keyImage,
  });

  final BigInt c0;
  final List<BigInt> s;

  /// Encoded key image: equal for the same signer and context, always the
  /// canonical base64url of the 32-byte point.
  final String keyImage;

  /// Most keys a ring may have (a cell has 2–3; generous).
  static const int maxRing = 64;

  static final Random _random = Random.secure();

  /// Results of [verify] (same inputs → same answer), so folding the
  /// pyramid again does not redo the curve arithmetic.
  static final Map<String, bool> _verified = <String, bool>{};
  static const int _cacheSize = 4096;

  static BigInt _randomScalar() {
    final List<int> bytes = List<int>.generate(64, (_) => _random.nextInt(256));
    return Ed25519Group.fromLe(bytes) % Ed25519Group.l;
  }

  static List<int> _base(String context, List<int> key) => <int>[
    ...utf8.encode('zen-ring-base|$context|'),
    ...key,
  ];

  static BigInt _challenge(
    String context,
    List<int> message,
    List<Uint8List> ring,
    EdPoint l,
    EdPoint r,
  ) => Ed25519Group.hashToScalar(<int>[
    ...utf8.encode('zen-ring|$context|'),
    for (final Uint8List k in ring) ...k,
    ...message,
    ...l.encode(),
    ...r.encode(),
  ]);

  /// The key image [value] if it is the canonical base64url of 32 bytes
  /// (the only form [sign] produces), else null. Other spellings of the
  /// same bytes — the other alphabet, no padding, stray bits — are refused,
  /// so one person cannot vote twice under two spellings.
  static String? canonicalImage(Object? value) {
    if (value is! String || value.length != 44) {
      return null;
    }
    try {
      final Uint8List bytes = base64Url.decode(value);
      return bytes.length == 32 && base64Url.encode(bytes) == value
          ? value
          : null;
    } on FormatException {
      return null;
    }
  }

  static bool _scalar(BigInt v) => v >= BigInt.zero && v < Ed25519Group.l;

  /// Signs [message] as the holder of [seed] (an Ed25519 seed whose public
  /// key is one of [ring]).
  static RingSignature sign({
    required List<int> seed,
    required List<Uint8List> ring,
    required String context,
    required List<int> message,
  }) {
    final BigInt x = Ed25519Group.scalarFromSeed(seed) % Ed25519Group.l;
    final Uint8List own = Ed25519Group.base.times(x).encode();
    final int n = ring.length;
    int me = -1;
    for (int i = 0; i < n; i++) {
      if (_same(ring[i], own)) {
        me = i;
      }
    }
    if (me < 0) {
      throw ArgumentError('The signer is not in the ring.');
    }
    final List<EdPoint> points = <EdPoint>[
      for (final Uint8List k in ring) Ed25519Group.decode(k)!,
    ];
    final List<EdPoint> bases = <EdPoint>[
      for (final Uint8List k in ring)
        Ed25519Group.hashToPoint(_base(context, k)),
    ];
    final EdPoint image = bases[me].times(x);
    final List<BigInt> s = List<BigInt>.filled(n, BigInt.zero);
    final List<BigInt> c = List<BigInt>.filled(n, BigInt.zero);
    final BigInt alpha = _randomScalar();
    c[(me + 1) % n] = _challenge(
      context,
      message,
      ring,
      Ed25519Group.base.times(alpha),
      bases[me].times(alpha),
    );
    for (int k = 1; k < n; k++) {
      final int i = (me + k) % n;
      s[i] = _randomScalar();
      final EdPoint l = Ed25519Group.base.times(s[i]) + points[i].times(c[i]);
      final EdPoint r = bases[i].times(s[i]) + image.times(c[i]);
      c[(i + 1) % n] = _challenge(context, message, ring, l, r);
    }
    s[me] = (alpha - c[me] * x) % Ed25519Group.l;
    return RingSignature(
      c0: c[0],
      s: s,
      keyImage: base64Url.encode(image.encode()),
    );
  }

  /// Checks the signature against [ring], [context] and [message]. False
  /// for anything malformed; never throws.
  bool verify({
    required List<Uint8List> ring,
    required String context,
    required List<int> message,
  }) {
    final int n = ring.length;
    if (n == 0 ||
        n > maxRing ||
        s.length != n ||
        !_scalar(c0) ||
        !s.every(_scalar)) {
      return false;
    }
    if (canonicalImage(keyImage) == null) {
      return false;
    }
    final String key = _cacheKey(ring, context, message);
    final bool? known = _verified[key];
    if (known != null) {
      return known;
    }
    bool ok;
    try {
      ok = _verify(ring, context, message);
    } on Object {
      ok = false;
    }
    if (_verified.length >= _cacheSize) {
      _verified.clear();
    }
    _verified[key] = ok;
    return ok;
  }

  bool _verify(List<Uint8List> ring, String context, List<int> message) {
    final int n = ring.length;
    final EdPoint? image = Ed25519Group.decode(base64Url.decode(keyImage));
    if (image == null || !image.isTorsionFreeNonZero) {
      return false;
    }
    final List<EdPoint> points = <EdPoint>[];
    for (final Uint8List k in ring) {
      final EdPoint? pt = Ed25519Group.decode(k);
      if (pt == null) {
        return false;
      }
      points.add(pt);
    }
    BigInt c = c0;
    for (int i = 0; i < n; i++) {
      final EdPoint base = Ed25519Group.hashToPoint(_base(context, ring[i]));
      final EdPoint l = Ed25519Group.base.times(s[i]) + points[i].times(c);
      final EdPoint r = base.times(s[i]) + image.times(c);
      c = _challenge(context, message, ring, l, r);
    }
    return c == c0;
  }

  /// What [verify] remembers its answer under (ring, context, message and
  /// this very signature).
  String cacheKeyFor(List<Uint8List> ring, String context, List<int> message) =>
      _cacheKey(ring, context, message);

  /// The answer remembered under [key], if any.
  static bool? known(String key) => _verified[key];

  /// Remembers an answer worked out elsewhere (a background isolate, or a
  /// previous run of the app read back from encrypted storage).
  static void remember(String key, bool ok) {
    if (_verified.length >= _cacheSize) {
      _verified.clear();
    }
    _verified[key] = ok;
  }

  /// The keys of signatures that held, to keep across restarts.
  static List<String> get trustedKeys => <String>[
    for (final MapEntry<String, bool> e in _verified.entries)
      if (e.value) e.key,
  ];

  String _cacheKey(
    List<Uint8List> ring,
    String context,
    List<int> message,
  ) => crypto.sha256.convert(<int>[
    ...utf8.encode('$context|${ring.length}|'),
    for (final Uint8List k in ring) ...k,
    ...crypto.sha256.convert(message).bytes,
    ...utf8.encode(
      '|${c0.toRadixString(16)}|${s.map((BigInt v) => v.toRadixString(16)).join(',')}|$keyImage',
    ),
  ]).toString();

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'c': c0.toRadixString(16),
    's': <String>[for (final BigInt v in s) v.toRadixString(16)],
    'i': keyImage,
  };

  /// Parses a signature; null unless every part is well formed: hex
  /// scalars below the group order, 1–[maxRing] responses, a canonical key
  /// image.
  static RingSignature? fromJson(Object? json) {
    if (json is! Map ||
        json['c'] is! String ||
        json['s'] is! List ||
        json['i'] is! String) {
      return null;
    }
    final String? image = canonicalImage(json['i']);
    final List<Object?> raw = json['s'] as List<Object?>;
    if (image == null || raw.isEmpty || raw.length > maxRing) {
      return null;
    }
    BigInt? scalar(Object? v) {
      // 64 hex digits hold anything below the order; longer is junk.
      if (v is! String || v.isEmpty || v.length > 64) {
        return null;
      }
      final BigInt? x = BigInt.tryParse(v, radix: 16);
      return x != null && _scalar(x) ? x : null;
    }

    final BigInt? c0 = scalar(json['c']);
    final List<BigInt> s = <BigInt>[];
    for (final Object? v in raw) {
      final BigInt? x = scalar(v);
      if (x == null) {
        return null;
      }
      s.add(x);
    }
    if (c0 == null) {
      return null;
    }
    return RingSignature(c0: c0, s: s, keyImage: image);
  }
}
