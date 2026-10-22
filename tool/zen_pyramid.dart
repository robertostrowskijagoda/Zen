// The original pyramid's genesis record and its first power key, made once
// by the founder before the pyramid opens. Plain Dart, no Flutter:
//
//   dart run tool/zen_pyramid.dart genesis --name "Zen" \
//       --key-out private/pyramid_power_key.txt [--write]
//   dart run tool/zen_pyramid.dart check
//   dart run tool/zen_pyramid.dart test-pin
//
// `genesis` makes a new power key and the genesis record it signs, writes
// the key's seed to --key-out (never committed, never shown again) and
// prints the constant to pin; with --write it pins it in
// lib/src/features/pyramid/pyramid_root.dart itself (only while nothing is
// pinned). The founder then opens Pyramid in the app and founds it with
// the key ("Załóż piramidę kluczem władzy"). `check` verifies what is
// pinned; `test-pin` prints the test pyramid's genesis again.
//
// The genesis is signed with Zen's hybrid signature (Ed25519 + ML-DSA-65)
// by the bridge's `cmd/zensig` (needs Go, zen_sig.dart), and names the
// power key's ML-DSA fingerprint (`pq`) next to its Ed25519 key (`pk`).
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zen/src/core/crypto/hybrid_signature_core.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';

import 'zen_sig.dart';

/// Where the pin lives in the app.
const String kRootPath = 'lib/src/features/pyramid/pyramid_root.dart';

/// The test pyramid: public power key seed, fixed time and name.
const String kTestSeedText = 'zen-pyramid-test-power';
const int kTestAt = 1600000000000;
const String kTestName = 'Zen (test)';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
  }
  switch (args.first) {
    case 'genesis':
      await _genesis(args.skip(1).toList());
    case 'check':
      await _check();
    case 'test-pin':
      await _testPin();
    default:
      _usage();
  }
}

Never _usage() {
  print(
    'Użycie: genesis --name NAZWA --key-out PLIK [--write] | check | '
    'test-pin',
  );
  exit(64);
}

String? _option(List<String> args, String name) {
  final int i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// The genesis record ({b, s}) signed by the power key of [seed]. The
/// original pyramid's names the key's ML-DSA fingerprint too ([anchor]);
/// the test pyramid's key is public, so its genesis does not.
Future<({Map<String, dynamic> record, String id, String pk})> makeGenesis(
  Uint8List seed, {
  required String name,
  required int at,
  bool anchor = true,
}) async {
  final ToolKey key = await ToolKey.fromSeed(seed);
  final String pk = key.ed;
  final Map<String, dynamic> body = <String, dynamic>{
    't': 'genesis',
    'at': at,
    'by': <String>[pk],
    'name': name,
    'pk': pk,
    if (anchor) 'pq': key.pqId,
  };
  final Uint8List bytes = canonicalJsonBytes(body);
  return (
    record: <String, dynamic>{
      'b': body,
      's': <String, String>{pk: await key.sign(bytes)},
    },
    id: sha256Hex(bytes),
    pk: pk,
  );
}

/// [text] as a Dart single-quoted string literal.
String _dartString(String text) =>
    "'${text.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

Future<void> _genesis(List<String> args) async {
  final String name = (_option(args, '--name') ?? 'Zen').trim();
  final String? keyOut = _option(args, '--key-out');
  if (keyOut == null || name.isEmpty) {
    _usage();
  }
  final File keyFile = File(keyOut);
  if (keyFile.existsSync()) {
    print('$keyOut już istnieje — nie nadpisuję klucza władzy.');
    exit(1);
  }
  final Random random = Random.secure();
  final Uint8List seed = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  final ({Map<String, dynamic> record, String id, String pk}) g =
      await makeGenesis(
        seed,
        name: name,
        at: DateTime.now().millisecondsSinceEpoch,
      );
  final String json = jsonEncode(g.record);
  keyFile
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '# Klucz władzy piramidy Zen (ziarno Ed25519 + ML-DSA-65, base64url).\n'
      '# Tylko dla założyciela: wklej w aplikacji przy zakładaniu piramidy,\n'
      '# potem trzymaj offline. Piramida: ${g.id}\n'
      '${b64(seed)}\n',
    );
  if (!Platform.isWindows) {
    await Process.run('chmod', <String>['600', keyOut]);
  }
  final String line = 'const String kZenPyramidGenesis = ${_dartString(json)};';
  if (args.contains('--write')) {
    final File root = File(kRootPath);
    final String src = root.readAsStringSync();
    const String empty = "const String kZenPyramidGenesis = '';";
    if (!src.contains(empty)) {
      print('W $kRootPath coś już jest przypięte — nie zmieniam.');
      exit(1);
    }
    root.writeAsStringSync(src.replaceFirst(empty, line));
    print('Przypięte w $kRootPath.');
  } else {
    print('Wklej do $kRootPath:\n\n$line\n');
  }
  print('Piramida (id): ${g.id}');
  print('Klucz władzy (publiczny): ${g.pk}');
  print('Ziarno klucza władzy zapisane w: $keyOut');
}

/// The text of the string constant [name] in [src] (adjacent literals
/// joined, escapes undone), or null.
String? _constant(String src, String name) {
  final int start = src.indexOf('const String $name =');
  if (start < 0) {
    return null;
  }
  final int end = src.indexOf(';\n', start);
  final String expr = src.substring(start, end);
  final StringBuffer out = StringBuffer();
  for (final RegExpMatch m in RegExp(r"'((?:[^'\\]|\\.)*)'").allMatches(expr)) {
    out.write(
      m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (Match e) => e.group(1)!),
    );
  }
  return out.toString();
}

/// Checks a pinned genesis: well formed, signed (both halves) by its own
/// power key — with the ML-DSA key its `pq` names, when it names one.
Future<String?> verifyGenesis(String json) async {
  final Object? r = jsonDecode(json);
  if (r is! Map || r['b'] is! Map || r['s'] is! Map) {
    return null;
  }
  final Map<String, dynamic> body = Map<String, dynamic>.from(r['b'] as Map);
  final Object? pk = body['pk'];
  final Object? pq = body['pq'];
  final Object? sig = (r['s'] as Map)[pk];
  if (body['t'] != 'genesis' ||
      pk is! String ||
      sig is! String ||
      (pq != null && pq is! String)) {
    return null;
  }
  final Uint8List bytes = canonicalJsonBytes(body);
  final String keyId = '$pk.${pq ?? hybridSignaturePqId(sig) ?? ''}';
  return await verifyByHybridId(keyId, bytes, sig) ? sha256Hex(bytes) : null;
}

Future<void> _check() async {
  final String src = File(kRootPath).readAsStringSync();
  for (final String name in <String>[
    'kZenPyramidGenesis',
    'kZenTestPyramidGenesis',
  ]) {
    final String? json = _constant(src, name);
    if (json == null || json.isEmpty) {
      print('$name: nic nie jest przypięte.');
      continue;
    }
    final String? id = await verifyGenesis(json);
    print(
      id == null
          ? '$name: ZŁY PODPIS albo zły rekord.'
          : '$name: dobry, id $id',
    );
  }
}

Future<void> _testPin() async {
  final Uint8List seed = Uint8List.fromList(
    sha256Bytes(utf8.encode(kTestSeedText)),
  );
  final ({Map<String, dynamic> record, String id, String pk}) g =
      await makeGenesis(seed, name: kTestName, at: kTestAt, anchor: false);
  print('kZenTestPyramidGenesis = ${jsonEncode(g.record)}');
  print('kZenTestPowerSeed = ${b64(seed)}');
  print('id ${g.id}');
}

/// SHA-256 of [bytes].
List<int> sha256Bytes(List<int> bytes) {
  final String hex = sha256Hex(bytes);
  return <int>[
    for (int i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
