import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/ed25519_group.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';

/// Ring signatures from outside are checked strictly (§20.3a): one image,
/// one spelling; scalars below the order; never an exception.
void main() {
  late List<LedgerKeyPair> keys;
  late List<Uint8List> ring;
  final List<int> msg = utf8.encode('glos');

  setUpAll(() async {
    keys = <LedgerKeyPair>[
      await LedgerKeyPair.generate(),
      await LedgerKeyPair.generate(),
      await LedgerKeyPair.generate(),
    ];
    ring = keys.map((LedgerKeyPair k) => k.publicKey).toList();
  });

  Map<String, dynamic> signed() => RingSignature.sign(
    seed: keys[0].seed,
    ring: ring,
    context: 'c',
    message: msg,
  ).toJson();

  test('another spelling of the same key image is refused', () {
    final Map<String, dynamic> json = signed();
    final String image = json['i'] as String;
    expect(RingSignature.canonicalImage(image), image);
    expect(RingSignature.fromJson(json), isNotNull);
    final List<String> aliases = <String>[
      // No padding.
      image.replaceAll('=', ''),
      // The other alphabet (the decoder takes both).
      image.replaceAll('-', '+').replaceAll('_', '/'),
      // Padding spelled out as an escape.
      image.replaceAll('=', '%3D'),
    ].where((String a) => a != image).toList();
    expect(aliases, isNotEmpty);
    for (final String alias in aliases) {
      expect(RingSignature.canonicalImage(alias), isNull, reason: alias);
      expect(
        RingSignature.fromJson(<String, dynamic>{...json, 'i': alias}),
        isNull,
        reason: alias,
      );
    }
    // Stray low bits in the last character (unused by the 32 bytes).
    final String last = image[42];
    const String alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final String other = alphabet[alphabet.indexOf(last) ^ 1];
    final String strayBits = '${image.substring(0, 42)}$other=';
    expect(RingSignature.canonicalImage(strayBits), isNull);
  });

  test('a key image that is not base64 makes verify false, never throw', () {
    final RingSignature good = RingSignature.fromJson(signed())!;
    final RingSignature junk = RingSignature(
      c0: good.c0,
      s: good.s,
      keyImage: 'not base64 at all!',
    );
    expect(junk.verify(ring: ring, context: 'c', message: msg), isFalse);
    final RingSignature short = RingSignature(
      c0: good.c0,
      s: good.s,
      keyImage: base64Url.encode(<int>[1, 2, 3]),
    );
    expect(short.verify(ring: ring, context: 'c', message: msg), isFalse);
    expect(good.verify(ring: ring, context: 'c', message: msg), isTrue);
    // A ring key that is no point: false, not an exception.
    final List<Uint8List> badRing = <Uint8List>[
      ...ring.sublist(0, 2),
      Uint8List.fromList(List<int>.filled(32, 0xff)),
    ];
    expect(good.verify(ring: badRing, context: 'c', message: msg), isFalse);
  });

  test('scalars must be below the group order (no huge multiples)', () {
    final Map<String, dynamic> json = signed();
    final BigInt c0 = BigInt.parse(json['c'] as String, radix: 16);
    // c0 + k·l is the same scalar mod l but would cost millions of additions.
    final BigInt huge = c0 + Ed25519Group.l * (BigInt.one << 4000);
    expect(
      RingSignature.fromJson(<String, dynamic>{
        ...json,
        'c': huge.toRadixString(16),
      }),
      isNull,
    );
    expect(
      RingSignature.fromJson(<String, dynamic>{
        ...json,
        'c': (c0 + Ed25519Group.l).toRadixString(16),
      }),
      isNull,
    );
    expect(
      RingSignature.fromJson(<String, dynamic>{...json, 'c': '-1'}),
      isNull,
    );
    final List<String> s = List<String>.of((json['s'] as List).cast<String>());
    s[0] = Ed25519Group.l.toRadixString(16);
    expect(RingSignature.fromJson(<String, dynamic>{...json, 's': s}), isNull);
    expect(
      RingSignature.fromJson(<String, dynamic>{...json, 's': <String>[]}),
      isNull,
    );
    expect(
      RingSignature.fromJson(<String, dynamic>{
        ...json,
        's': List<String>.filled(RingSignature.maxRing + 1, '1'),
      }),
      isNull,
    );
    // Built by hand, a huge c0 is refused by verify at once.
    final RingSignature good = RingSignature.fromJson(json)!;
    final Stopwatch watch = Stopwatch()..start();
    expect(
      RingSignature(
        c0: huge,
        s: good.s,
        keyImage: good.keyImage,
      ).verify(ring: ring, context: 'c', message: msg),
      isFalse,
    );
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });

  test('a multiple of the order never makes a long multiplication', () {
    final Stopwatch watch = Stopwatch()..start();
    final EdPoint p = Ed25519Group.base.times(
      Ed25519Group.l * (BigInt.one << 100000),
    );
    expect(p.isIdentity, isTrue);
    expect(watch.elapsedMilliseconds, lessThan(5000));
  });

  test('remembered results are the same results', () {
    final RingSignature good = RingSignature.fromJson(signed())!;
    for (int i = 0; i < 3; i++) {
      expect(good.verify(ring: ring, context: 'c', message: msg), isTrue);
      expect(good.verify(ring: ring, context: 'other', message: msg), isFalse);
      expect(
        good.verify(ring: ring, context: 'c', message: utf8.encode('inny')),
        isFalse,
      );
    }
  });
}
