import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/crypto/hybrid_signature_ffi.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_root.dart';

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

Uint8List _seedOf(String label) =>
    Uint8List.fromList(crypto.sha256.convert(utf8.encode(label)).bytes);

String _hex(List<int> bytes) => crypto.Digest(bytes).toString();

/// The vectors of `internal/zensig/zensig_test.go`: seed = SHA-256 of the
/// label, message "zen hybrid signature test vector"; hex of the Ed25519
/// key, of F (SHA-256 of the ML-DSA key), of SHA-256(signature) and of
/// SHA-256(keyed signature).
const List<(String, String, String, String, String)> _goVectors =
    <(String, String, String, String, String)>[
      (
        'zen-sig-vector-1',
        '5b90b773c1a5588e3d23cd6bd32f99168e7db7f973427dd4292d3dd8edef32a1',
        '616d8e5ce803836c8d5290a944ac3b7a8cd72ce7f4cdc96090464f52d21d2a7e',
        '6012f1199ad528a734ea5e5069525a8ff5ac38723c4386cf1607e44f756967f5',
        '8fecc8502e64432995b6bdca68e94cdba0cb1658ef4333fbd380884bfa927828',
      ),
      (
        'zen-sig-vector-2',
        '7cf3c2181b287d1b76bf11291659bfd945404d7127fa9228be55cc0e53f54bbb',
        '0533107785ad0b463d7965a6201ba1aadcb78e0709d8411a769d6ebe0e9bd2df',
        'dcfb1171db1940eb429c4e5ad15025bdcee77046f10a3c5f6b1c7f4f252fa1f1',
        '3fe55918b7e7bf05e83337a5f17c034043801642b638b6bd2dd2192679ba26f0',
      ),
    ];

final List<int> _vectorMessage = utf8.encode(
  'zen hybrid signature test vector',
);

/// A signature by [victim]'s Ed25519 half that names [attacker]'s ML-DSA
/// key (and carries it, [keyed]), with a valid ML-DSA half of that key:
/// what a quantum computer (which forges Ed25519) and its owner's own
/// ML-DSA key make. With the stand-in signer the forger's ML-DSA half is
/// computable.
Future<String> _forge(
  LedgerKeyPair victim,
  LedgerKeyPair attacker,
  List<int> message, {
  bool keyed = true,
}) async {
  final Uint8List fingerprint = Uint8List.fromList(
    crypto.sha256.convert(attacker.pqPublicKey).bytes,
  );
  final Uint8List t = hybridToBeSigned(
    victim.publicKey,
    fingerprint,
    hybridDigest(message),
  );
  final Signature ed = await Ed25519().sign(
    t,
    keyPair: await Ed25519().newKeyPairFromSeed(victim.seed),
  );
  return b64(<int>[
    ...ed.bytes,
    ...(keyed ? attacker.pqPublicKey : fingerprint),
    ...standInMlDsaSignature(attacker.pqPublicKey, t),
  ]);
}

void main() {
  setUp(HybridKeyPins.clear);
  tearDown(() => debugOverrideHybridSigner(null));

  group('the hybrid signature (stand-in signer in tests)', () {
    test('a key signs with both halves; the signature has the hybrid '
        'layout', () async {
      final LedgerKeyPair key = await LedgerKeyPair.fromSeed(_seedOf('a'));
      final List<int> message = utf8.encode('a ledger entry');
      final Uint8List sig = await key.sign(message);
      expect(sig, hasLength(kHybridSignatureBytes));
      expect(kHybridSignatureBytes, 3405);
      expect(b64(sig), hasLength(kHybridSignatureChars));
      expect(kHybridSignatureChars, 4540);
      // The signature names the ML-DSA key by its fingerprint, the key's
      // pq id; the keyed form carries the key itself instead.
      expect(hybridSignaturePqKey(sig), isNull);
      expect(hybridSignaturePqId(b64(sig)), key.pqId);
      final Uint8List keyed = await key.signWithKey(message);
      expect(keyed, hasLength(kKeyedHybridSignatureBytes));
      expect(kKeyedHybridSignatureBytes, 5325);
      expect(b64(keyed), hasLength(kKeyedHybridSignatureChars));
      expect(hybridSignaturePqKey(keyed), orderedEquals(key.pqPublicKey));
      expect(hybridSignaturePqId(b64(keyed)), key.pqId);
      // The same two halves in both forms.
      expect(
        hybridSignatureMlDsaHalf(keyed),
        orderedEquals(hybridSignatureMlDsaHalf(sig)),
      );
      expect(key.pqPublicKey, hasLength(kMlDsaPublicKeyBytes));
      // Deterministic, like Ed25519.
      expect(await key.sign(message), orderedEquals(sig));
      expect(
        await verifyLedgerSignature(
          publicKey: key.id,
          message: message,
          signature: b64(keyed),
        ),
        isTrue,
      );
      expect(
        await verifyLedgerSignature(
          publicKey: key.id,
          message: message,
          signature: b64(sig),
        ),
        isTrue,
      );
      // The Ed25519 half is the seed's own key: the id does not change.
      final SimpleKeyPair ed = await Ed25519().newKeyPairFromSeed(key.seed);
      expect((await ed.extractPublicKey()).bytes, orderedEquals(key.publicKey));
    });

    test(
      'tampering with either half, or another message, is refused',
      () async {
        final LedgerKeyPair key = await LedgerKeyPair.fromSeed(_seedOf('b'));
        final List<int> message = utf8.encode('a pyramid record');
        final Uint8List sig = await key.sign(message);
        Future<bool> check(List<int> s, [List<int>? m]) =>
            verifyLedgerSignature(
              publicKey: key.id,
              message: m ?? message,
              signature: b64(s),
            );
        expect(await check(sig), isTrue);
        expect(await check(sig, utf8.encode('another record')), isFalse);
        for (final int at in <int>[
          3, // Ed25519 half
          kEd25519SignatureBytes + 10, // the fingerprint it names
          kEd25519SignatureBytes + kSigFingerprintBytes + 5, // ML-DSA half
          kHybridSignatureBytes - 1,
        ]) {
          final Uint8List bad = Uint8List.fromList(sig)..[at] ^= 1;
          expect(await check(bad), isFalse, reason: 'byte $at changed');
        }
        // Truncated, empty, or another key's.
        expect(await check(sig.sublist(1)), isFalse);
        expect(await check(const <int>[]), isFalse);
        final LedgerKeyPair other = await LedgerKeyPair.generate();
        expect(await check(await other.sign(message)), isFalse);
      },
    );

    test('a signature that names its key is checked only with that key: '
        'never taken while the key is unknown', () async {
      final LedgerKeyPair key = await LedgerKeyPair.generate();
      final LedgerKeyPair other = await LedgerKeyPair.generate();
      final List<int> message = utf8.encode('a like');
      final String sig = b64(await key.sign(message));
      final String keyed = b64(await key.signWithKey(message));
      // A phone that never saw the record publishing the key.
      HybridKeyBook.clear();
      expect(hybridSignatureLacksKey(sig), isTrue);
      expect(hybridSignatureLacksKey(keyed), isFalse);
      Future<bool> check(String s, {Uint8List? pqKey}) => verifyLedgerSignature(
        publicKey: key.id,
        message: message,
        signature: s,
        pqKey: pqKey,
      );
      expect(await check(sig), isFalse);
      expect(await check(sig, pqKey: other.pqPublicKey), isFalse);
      expect(await check(keyed, pqKey: other.pqPublicKey), isFalse);
      // Handed the key (a device certificate) or holding it (a record that
      // published it): checked.
      expect(await check(sig, pqKey: key.pqPublicKey), isTrue);
      expect(await check(keyed), isTrue);
      expect(HybridKeyBook.add(key.pqPublicKey), key.pqId);
      expect(hybridSignatureLacksKey(sig), isFalse);
      expect(await check(sig), isTrue);
      // The book files a key under its own hash only.
      expect(HybridKeyBook.add(Uint8List(10)), isNull);
      expect(HybridKeyBook.lookup(key.pqId), orderedEquals(key.pqPublicKey));
    });

    test('an Ed25519-only signature is refused', () async {
      final LedgerKeyPair key = await LedgerKeyPair.generate();
      final List<int> message = utf8.encode('signed the old way');
      final String classical = b64(await key.signClassical(message));
      expect(classical, hasLength(88));
      expect(
        await verifyLedgerSignature(
          publicKey: key.id,
          message: message,
          signature: classical,
        ),
        isFalse,
      );
      expect(isHybridSignatureText(classical), isFalse);
      // It is only for what has to fit a QR code (event tickets).
      expect(
        await verifyClassicalSignature(
          publicKey: key.id,
          message: message,
          signature: classical,
        ),
        isTrue,
      );
    });

    test(
      'a forged Ed25519 half with the forger\'s ML-DSA key: refused once '
      'the real key is pinned, and always where a record anchors it',
      () async {
        final LedgerKeyPair victim = await LedgerKeyPair.generate();
        final LedgerKeyPair attacker = await LedgerKeyPair.generate();
        final List<int> message = utf8.encode(
          'give everything to the attacker',
        );
        final String forged = await _forge(victim, attacker, message);
        final String forgedShort = await _forge(
          victim,
          attacker,
          message,
          keyed: false,
        );
        // Both halves of the forgery hold on their own (that is what a
        // quantum computer buys): only the binding to the key stops it.
        expect(
          await kStandInHybridSigner.verifyDigest(
            victim.publicKey,
            hybridDigest(message),
            decodeHybridSignature(forged)!,
          ),
          isTrue,
        );
        // Anchored (a device certificate, a maintainer, an alarm key or a
        // pyramid record names the fingerprint): refused.
        expect(
          await verifyLedgerSignature(
            publicKey: victim.id,
            message: message,
            signature: forged,
            pqId: victim.pqId,
          ),
          isFalse,
        );
        expect(
          await verifyLedgerSignature(
            publicKey: victim.id,
            message: message,
            signature: forgedShort,
            pqId: victim.pqId,
          ),
          isFalse,
        );
        // Pinned from a genuine signature seen before: refused.
        final List<int> earlier = utf8.encode('an earlier entry');
        expect(
          await verifyLedgerSignature(
            publicKey: victim.id,
            message: earlier,
            signature: b64(await victim.sign(earlier)),
          ),
          isTrue,
        );
        expect(HybridKeyPins.pinnedFor(victim.id), victim.pqId);
        for (final String f in <String>[forged, forgedShort]) {
          expect(
            await verifyLedgerSignature(
              publicKey: victim.id,
              message: message,
              signature: f,
            ),
            isFalse,
          );
        }
        // The genuine key still signs.
        expect(
          await verifyLedgerSignature(
            publicKey: victim.id,
            message: message,
            signature: b64(await victim.sign(message)),
          ),
          isTrue,
        );
      },
    );

    test('pins come back from storage', () async {
      final LedgerKeyPair account = await LedgerKeyPair.generate();
      final LedgerKeyPair device = await LedgerKeyPair.generate();
      final DeviceCertificate cert = await DeviceCertificate.issue(
        account: account,
        device: device,
        name: 'tel',
        issued: 1,
      );
      HybridKeyPins.clear();
      AccountDirectory().trustCertificate(cert);
      expect(HybridKeyPins.pinnedFor(account.id), account.pqId);
    });

    test('a hybrid id names both halves', () async {
      final LedgerKeyPair key = await LedgerKeyPair.generate();
      expect(key.hybridId, hasLength(89));
      expect(parseHybridKeyId(key.hybridId), (ed: key.id, pq: key.pqId));
      expect(parseHybridKeyId(key.id), isNull);
      expect(parseHybridKeyId('${key.id}.${key.id}x'), isNull);
      expect(parseHybridKeyId('${key.id}:${key.pqId}'), isNull);
      expect(parseHybridKeyId(null), isNull);
    });
  });

  group('device records', () {
    test('the certificate publishes the device key\'s ML-DSA half, and what '
        'the device signs must name exactly that key', () async {
      final LedgerKeyPair account = await LedgerKeyPair.generate();
      final LedgerKeyPair device = await LedgerKeyPair.generate();
      final LedgerKeyPair attacker = await LedgerKeyPair.generate();
      final DeviceCertificate cert = await DeviceCertificate.issue(
        account: account,
        device: device,
        name: 'tel',
        issued: 1,
      );
      expect(cert.devicePq, device.pqId);
      expect(cert.devicePqKey, b64(device.pqPublicKey));
      // Checked on its own, by anyone: the account's signature carries
      // the account's ML-DSA key.
      expect(cert.signature, hasLength(kKeyedHybridSignatureChars));
      HybridKeyBook.clear();
      expect(await cert.verify(), isTrue);
      final List<int> message = utf8.encode('zen.hello.v1|200::1');
      expect(
        await cert.verifyByDevice(message, b64(await device.sign(message))),
        isTrue,
      );
      // Not pinned anywhere yet, and still refused: the record anchors it.
      HybridKeyPins.clear();
      for (final bool keyed in <bool>[true, false]) {
        expect(
          await cert.verifyByDevice(
            message,
            await _forge(device, attacker, message, keyed: keyed),
          ),
          isFalse,
        );
      }
      // The key is signed by the account: changing it breaks the
      // certificate.
      final Map<String, dynamic> json = cert.toJson()
        ..['dpk'] = b64(attacker.pqPublicKey);
      expect(await DeviceCertificate.fromJson(json)!.verify(), isFalse);
      // Without it, with an Ed25519-only signature or with one that does
      // not carry the account's key, it does not parse.
      expect(DeviceCertificate.fromJson(cert.toJson()..remove('dpk')), isNull);
      expect(
        DeviceCertificate.fromJson(
          cert.toJson()..['sig'] = b64(await account.signClassical(message)),
        ),
        isNull,
      );
      expect(
        DeviceCertificate.fromJson(
          cert.toJson()..['sig'] = b64(await account.sign(message)),
        ),
        isNull,
      );
    });
  });

  group('the Go bridge', () {
    test('the Ed25519 halves match Go\'s vectors', () async {
      for (final (String label, String ed, _, _, _) in _goVectors) {
        final SimpleKeyPair pair = await Ed25519().newKeyPairFromSeed(
          _seedOf(label),
        );
        expect(_hex((await pair.extractPublicKey()).bytes), ed);
      }
      // The pinned test genesis was signed by Go: its Ed25519 half checks
      // out with this app's composition of what both halves sign.
      final PyramidRoot root = kZenTestPyramidRoot;
      expect(
        await verifyHybridEd25519Half(
          unb64(root.powerKey, length: 32)!,
          hybridDigest(root.genesis.signedBytes),
          decodeHybridSignature(root.genesis.sigs[root.powerKey])!,
        ),
        isTrue,
      );
    });

    test('vectors, both halves and tampering through the bridge', () async {
      final String? path = _bridgeLibrary();
      if (path == null) {
        markTestSkipped(
          'No bridge library built (build_linux.sh / build_windows.ps1, or '
          'ZEN_BRIDGE_LIBRARY); internal/zensig tests cover the signature.',
        );
        return;
      }
      final BridgeHybridSigner bridge = BridgeHybridSigner.inline(
        DynamicLibrary.open(path),
      );
      for (final (
            String label,
            String ed,
            String f,
            String sigHash,
            String keyedHash,
          )
          in _goVectors) {
        final HybridPublicKey key = await bridge.publicKeyOf(_seedOf(label));
        expect(_hex(key.ed), ed);
        expect(_hex(key.fingerprint), f);
        final Uint8List digest = hybridDigest(_vectorMessage);
        final Uint8List sig = await bridge.signDigest(_seedOf(label), digest);
        final Uint8List keyed = await bridge.signDigest(
          _seedOf(label),
          digest,
          withKey: true,
        );
        expect(_hex(crypto.sha256.convert(sig).bytes), sigHash);
        expect(_hex(crypto.sha256.convert(keyed).bytes), keyedHash);
        expect(
          await bridge.verifyDigest(key.ed, digest, sig, pqKey: key.pq),
          isTrue,
        );
        expect(await bridge.verifyDigest(key.ed, digest, keyed), isTrue);
        // Without its key a signature that names it is not valid.
        expect(await bridge.verifyDigest(key.ed, digest, sig), isFalse);
        for (final int at in <int>[
          0,
          70,
          100,
          3000,
          kHybridSignatureBytes - 1,
        ]) {
          final Uint8List bad = Uint8List.fromList(sig)..[at] ^= 1;
          expect(
            await bridge.verifyDigest(key.ed, digest, bad, pqKey: key.pq),
            isFalse,
            reason: 'byte $at changed',
          );
        }
      }
      // The pinned test genesis verifies in full.
      final PyramidRoot root = kZenTestPyramidRoot;
      expect(
        await bridge.verifyDigest(
          unb64(root.powerKey, length: 32)!,
          hybridDigest(root.genesis.signedBytes),
          decodeHybridSignature(root.genesis.sigs[root.powerKey])!,
        ),
        isTrue,
      );
      // And the app's keys work on it as on the stand-in.
      debugOverrideHybridSigner(bridge);
      final LedgerKeyPair key = await LedgerKeyPair.generate();
      final List<int> message = utf8.encode('through the bridge');
      expect(
        await verifyLedgerSignature(
          publicKey: key.id,
          message: message,
          signature: b64(await key.sign(message)),
          pqId: key.pqId,
        ),
        isTrue,
      );
    });

    test('without the bridge, tests run on the stand-in', () async {
      if (_bridgeLibrary() != null) {
        return;
      }
      final Uint8List seed = _seedOf('stand-in');
      expect(
        (await hybridSigner.publicKeyOf(seed)).pq,
        orderedEquals((await kStandInHybridSigner.publicKeyOf(seed)).pq),
      );
    });
  });
}
