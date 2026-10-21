import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/security/hybrid_kem_ffi.dart';

/// The bridge built for this computer (build_linux.sh, build_windows.ps1),
/// or the one `ZEN_BRIDGE_LIBRARY` names; `null` when there is none.
String? _bridgeLibrary() {
  final String? named = Platform.environment['ZEN_BRIDGE_LIBRARY'];
  final List<String> candidates = <String>[
    if (named != null && named.isNotEmpty) named,
    if (Platform.isLinux) ...<String>[
      'native/yggdrasil_bridge/bin/linux-x64/libyggdrasil_bridge.so',
      'native/yggdrasil_bridge/bin/linux-arm64/libyggdrasil_bridge.so',
    ],
    if (Platform.isWindows) r'native\yggdrasil_bridge\bin\yggdrasil_bridge.dll',
  ];
  for (final String candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

Future<void> _roundTrip(HybridKem kem) async {
  final Uint8List seed = randomHybridSeed();
  final Uint8List publicKey = await kem.publicKeyOf(seed);
  expect(publicKey, hasLength(kHybridPublicKeyBytes));
  expect(await kem.publicKeyOf(seed), orderedEquals(publicKey));
  final List<int> info = utf8.encode('zen.test|a|b');
  final HybridEncapsulation made = await kem.encapsulate(publicKey, info: info);
  expect(made.ciphertext, hasLength(kHybridCiphertextBytes));
  expect(made.secret, hasLength(kHybridSecretBytes));
  expect(
    await kem.decapsulate(seed, made.ciphertext, info: info),
    orderedEquals(made.secret),
  );

  // Another key, another info, a changed ciphertext: another secret.
  final Uint8List other = Uint8List.fromList(seed)..[0] ^= 1;
  expect(
    await kem.decapsulate(other, made.ciphertext, info: info),
    isNot(orderedEquals(made.secret)),
  );
  expect(
    await kem.decapsulate(seed, made.ciphertext, info: utf8.encode('x')),
    isNot(orderedEquals(made.secret)),
  );
  for (final int at in <int>[0, 600, kHybridCiphertextBytes - 1]) {
    final Uint8List damaged = Uint8List.fromList(made.ciphertext)..[at] ^= 1;
    expect(
      await kem.decapsulate(seed, damaged, info: info),
      isNot(orderedEquals(made.secret)),
      reason: 'changed at $at',
    );
  }
  final HybridEncapsulation again = await kem.encapsulate(
    publicKey,
    info: info,
  );
  expect(again.secret, isNot(orderedEquals(made.secret)));

  await expectLater(
    kem.encapsulate(publicKey.sublist(0, 32), info: info),
    throwsA(anything),
  );
  await expectLater(
    kem.decapsulate(seed, made.ciphertext.sublist(1), info: info),
    throwsA(anything),
  );
}

void main() {
  test('the bridge KEM (ML-KEM-768 + X25519 from Go) round trips', () async {
    final String? path = _bridgeLibrary();
    if (path == null) {
      markTestSkipped(
        'No bridge library built (build_linux.sh / build_windows.ps1, or '
        'ZEN_BRIDGE_LIBRARY); the Go tests cover the KEM itself.',
      );
      return;
    }
    await _roundTrip(BridgeHybridKem.fromLibrary(DynamicLibrary.open(path)));
  });

  test('the classical test stand-in behaves like the KEM', () async {
    await _roundTrip(kClassicalStandInHybridKem);
  });

  test('without the bridge, tests run on the stand-in', () async {
    if (_bridgeLibrary() != null) {
      return;
    }
    final Uint8List seed = randomHybridSeed();
    expect(
      await hybridKem.publicKeyOf(seed),
      orderedEquals(await kClassicalStandInHybridKem.publicKeyOf(seed)),
    );
  });

  test('a hybrid public key decodes only at its size', () {
    final Uint8List key = Uint8List(kHybridPublicKeyBytes)..[5] = 7;
    expect(decodeHybridPublicKey(base64Url.encode(key)), orderedEquals(key));
    expect(decodeHybridPublicKey(base64Url.encode(Uint8List(32))), isNull);
    expect(decodeHybridPublicKey('not base64!'), isNull);
    expect(decodeHybridPublicKey(null), isNull);
  });
}
