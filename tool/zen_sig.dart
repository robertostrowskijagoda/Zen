// Zen's hybrid signature (Ed25519 + ML-DSA-65) for the maintainers' tools
// (zen_release.dart, zen_pyramid.dart). They are plain Dart and cannot load
// the bridge, so they run its command line twin, which needs Go (the same
// Go that builds the bridge):
//
//   go run ./cmd/zensig        (in native/yggdrasil_bridge)
//
// Under `flutter test` the tests hand the tools the app's own signer
// ([useToolSigner]): the bridge's when the run has it, else the stand-in.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zen/src/core/crypto/hybrid_signature_core.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';

HybridSigner? _signer;

/// The signer of the tools: the Go command, or what [useToolSigner] set
/// (under `flutter test` without it, the app's stand-in).
HybridSigner get toolSigner =>
    _signer ??
    (Platform.environment.containsKey('FLUTTER_TEST')
        ? kStandInHybridSigner
        : const GoHybridSigner());

/// Makes the tools sign and check with [signer]; `null` restores the
/// default. Tests pass the app's own signer, so the tools and the app sign
/// alike — with the bridge whenever the test run loaded it.
void useToolSigner(HybridSigner? signer) => _signer = signer;

/// A maintainer's (or the power key's) key: the seed and both public
/// halves.
final class ToolKey {
  const ToolKey(this.seed, this.ed, this.pqId);

  final Uint8List seed;

  /// The Ed25519 public key (base64url).
  final String ed;

  /// The fingerprint of the ML-DSA-65 public key (base64url).
  final String pqId;

  /// What `kReleaseMaintainers` holds: `<ed>.<pqId>`.
  String get hybridId => hybridKeyId(ed, pqId);

  static Future<ToolKey> fromSeed(List<int> seed) async {
    final Uint8List s = Uint8List.fromList(seed);
    final HybridPublicKey key = await toolSigner.publicKeyOf(s);
    return ToolKey(s, b64(key.ed), b64(key.fingerprint));
  }

  /// The hybrid signature of [message] (base64url), keyed: releases and
  /// the genesis are checked by phones that pin the key by fingerprint and
  /// hold no other record of it.
  Future<String> sign(List<int> message) async => b64(
    await toolSigner.signDigest(seed, hybridDigest(message), withKey: true),
  );
}

/// Whether [signature] (base64url) over [message] is by the key with the
/// hybrid id [keyId]: both halves, the ML-DSA one of exactly that key.
Future<bool> verifyByHybridId(
  String keyId,
  List<int> message,
  String signature,
) async {
  final ({String ed, String pq})? key = parseHybridKeyId(keyId);
  final Uint8List? sig = decodeHybridSignature(signature);
  if (key == null || sig == null || hybridSignaturePqId(signature) != key.pq) {
    return false;
  }
  try {
    return await toolSigner.verifyDigest(
      unb64(key.ed, length: 32)!,
      hybridDigest(message),
      sig,
    );
  } on Object {
    return false;
  }
}

/// [HybridSigner] of `native/yggdrasil_bridge/cmd/zensig`, one `go run`
/// per call (a release is signed a handful of times).
final class GoHybridSigner implements HybridSigner {
  const GoHybridSigner();

  static Directory _bridgeDirectory() {
    final List<Directory> roots = <Directory>[
      File.fromUri(Platform.script).parent.parent,
      Directory.current,
    ];
    for (final Directory root in roots) {
      final Directory d = Directory('${root.path}/native/yggdrasil_bridge');
      if (File('${d.path}/cmd/zensig/main.go').existsSync()) {
        return d;
      }
    }
    throw StateError(
      'native/yggdrasil_bridge/cmd/zensig not found: run the tool from the '
      'repository.',
    );
  }

  static Future<Map<String, dynamic>> _run(Map<String, Object> request) async {
    final Process process = await Process.start('go', <String>[
      'run',
      './cmd/zensig',
    ], workingDirectory: _bridgeDirectory().path);
    process.stdin.write(jsonEncode(request));
    await process.stdin.close();
    final Future<String> out = process.stdout.transform(utf8.decoder).join();
    final Future<String> err = process.stderr.transform(utf8.decoder).join();
    final int code = await process.exitCode;
    if (code != 0) {
      throw StateError('zensig: ${(await err).trim()}');
    }
    final Object? answer = jsonDecode(await out);
    if (answer is! Map<String, dynamic>) {
      throw const FormatException('zensig gave no object.');
    }
    return answer;
  }

  static Uint8List _bytes(Object? value, int length) {
    final Uint8List? bytes = unb64(value, length: length);
    if (bytes == null) {
      throw const FormatException('zensig gave bad bytes.');
    }
    return bytes;
  }

  @override
  Future<HybridPublicKey> publicKeyOf(Uint8List seed) async {
    final Map<String, dynamic> a = await _run(<String, Object>{
      'op': 'public',
      'seed': b64(seed),
    });
    return HybridPublicKey(
      ed: _bytes(a['ed'], kEd25519PublicKeyBytes),
      pq: _bytes(a['pq'], kMlDsaPublicKeyBytes),
      fingerprint: _bytes(a['fingerprint'], kSigFingerprintBytes),
    );
  }

  @override
  Future<Uint8List> signDigest(
    Uint8List seed,
    Uint8List digest, {
    bool withKey = false,
  }) async {
    final Map<String, dynamic> a = await _run(<String, Object>{
      'op': 'sign',
      'seed': b64(seed),
      'digest': b64(digest),
      'withKey': withKey,
    });
    return _bytes(
      a['signature'],
      withKey ? kKeyedHybridSignatureBytes : kHybridSignatureBytes,
    );
  }

  @override
  Future<bool> verifyDigest(
    Uint8List ed,
    Uint8List digest,
    Uint8List signature, {
    Uint8List? pqKey,
  }) async {
    final Map<String, dynamic> a = await _run(<String, Object>{
      'op': 'verify',
      'publicKey': b64(ed),
      'digest': b64(digest),
      'signature': b64(signature),
      if (pqKey != null) 'pqKey': b64(pqKey),
    });
    return a['valid'] == true;
  }
}
