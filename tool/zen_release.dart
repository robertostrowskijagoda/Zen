// Tool for the project maintainers: keys, signing and bundling releases
// for network updates (§14.2). Plain Dart, no Flutter:
//
//   dart run tool/zen_release.dart keygen maintainer.key
//   dart run tool/zen_release.dart create --version 1.10.0 --build 10 \
//       --notes "Co nowego" --out release.json \
//       android=build/app/outputs/flutter-apk/app-release.apk \
//       windows=dist/zen-setup.exe
//   dart run tool/zen_release.dart sign release.json maintainer.key
//   dart run tool/zen_release.dart verify release.json
//   dart run tool/zen_release.dart bundle release.json zen-1.10.0.zenupdate \
//       android=... windows=...
//   dart run tool/zen_release.dart revoke --build 10 --why "Powód" \
//       maintainer.key revoke-10.json
//
// See docs/WYDANIA.md.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

const int blobChunkSize = 256 * 1024;

String canonicalJson(Object? value) {
  final StringBuffer out = StringBuffer();
  void write(Object? v) {
    if (v == null || v is bool || v is String) {
      out.write(jsonEncode(v));
    } else if (v is int) {
      out.write(v);
    } else if (v is List) {
      out.write('[');
      for (int i = 0; i < v.length; i++) {
        if (i > 0) {
          out.write(',');
        }
        write(v[i]);
      }
      out.write(']');
    } else if (v is Map) {
      final List<String> keys = v.keys.cast<String>().toList()..sort();
      out.write('{');
      for (int i = 0; i < keys.length; i++) {
        if (i > 0) {
          out.write(',');
        }
        out
          ..write(jsonEncode(keys[i]))
          ..write(':');
        write(v[keys[i]]);
      }
      out.write('}');
    } else {
      throw ArgumentError('Nieobsługiwany typ: ${v.runtimeType}');
    }
  }

  write(value);
  return out.toString();
}

List<int> canonicalBytes(Object? value) => utf8.encode(canonicalJson(value));

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

String b64(List<int> bytes) => base64Url.encode(bytes);

String mimeFor(String name) {
  final String lower = name.toLowerCase();
  if (lower.endsWith('.apk')) {
    return 'application/vnd.android.package-archive';
  }
  if (lower.endsWith('.zip')) {
    return 'application/zip';
  }
  return 'application/octet-stream';
}

/// The ledger blob id of [bytes] (same as `BlobManifest.describe`).
String blobId(Uint8List bytes, String mime) {
  final List<String> chunks = <String>[
    for (int i = 0; i < bytes.length; i += blobChunkSize)
      sha256Hex(
        Uint8List.sublistView(bytes, i, min(i + blobChunkSize, bytes.length)),
      ),
  ];
  return sha256Hex(
    canonicalBytes(<String, dynamic>{
      't': 'blob',
      'size': bytes.length,
      'mime': mime,
      'chunk': blobChunkSize,
      'chunks': chunks,
    }),
  );
}

Map<String, dynamic> describeFile(
  Uint8List bytes, {
  required String platform,
  required String name,
}) => <String, dynamic>{
  'p': platform,
  'name': name,
  'size': bytes.length,
  'blob': blobId(bytes, mimeFor(name)),
  'sha256': sha256Hex(bytes),
};

Map<String, dynamic> createRelease({
  required String version,
  required int build,
  required List<Map<String, dynamic>> files,
  String notes = '',
  int? publishedAt,
}) => <String, dynamic>{
  'm': <String, dynamic>{
    't': 'zen_release',
    'app': 'zen',
    'version': version,
    'build': build,
    'at': publishedAt ?? DateTime.now().millisecondsSinceEpoch,
    'notes': notes,
    'files': files,
  },
  'sigs': <Map<String, String>>[],
};

final Ed25519 _ed = Ed25519();

Future<SimpleKeyPair> keyFromSeed(List<int> seed) =>
    _ed.newKeyPairFromSeed(seed);

Future<String> publicKeyOf(SimpleKeyPair pair) async =>
    b64((await pair.extractPublicKey()).bytes);

Future<Map<String, dynamic>> signRelease(
  Map<String, dynamic> release,
  SimpleKeyPair key,
) async {
  final Signature sig = await _ed.sign(
    canonicalBytes(release['m']),
    keyPair: key,
  );
  final String pub = await publicKeyOf(key);
  final List<dynamic> sigs = <dynamic>[
    for (final dynamic s in release['sigs'] as List<dynamic>)
      if ((s as Map<String, dynamic>)['k'] != pub) s,
    <String, String>{'k': pub, 's': b64(sig.bytes)},
  ];
  return <String, dynamic>{'m': release['m'], 'sigs': sigs};
}

Future<List<String>> validSigners(Map<String, dynamic> release) async {
  final List<int> message = canonicalBytes(release['m']);
  final List<String> ok = <String>[];
  for (final dynamic s in release['sigs'] as List<dynamic>) {
    final Map<String, dynamic> m = s as Map<String, dynamic>;
    try {
      final bool valid = await _ed.verify(
        message,
        signature: Signature(
          base64Url.decode(m['s'] as String),
          publicKey: SimplePublicKey(
            base64Url.decode(m['k'] as String),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (valid) {
        ok.add(m['k'] as String);
      }
    } on Object {
      // not valid
    }
  }
  return ok;
}

Future<Map<String, dynamic>> createRevocation({
  required int build,
  required String reason,
  required SimpleKeyPair key,
  int? at,
}) async {
  final Map<String, dynamic> body = <String, dynamic>{
    't': 'zen_revoke',
    'app': 'zen',
    'build': build,
    'at': at ?? DateTime.now().millisecondsSinceEpoch,
    'why': reason,
  };
  final Signature sig = await _ed.sign(canonicalBytes(body), keyPair: key);
  return <String, dynamic>{
    ...body,
    'k': await publicKeyOf(key),
    's': b64(sig.bytes),
  };
}

/// The `.zenupdate` format read by `ReleaseBundle.decode`.
Uint8List encodeBundle(
  Map<String, dynamic> release,
  Map<String, Uint8List> files,
) {
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(<int>[0x5A, 0x45, 0x4E, 0x55, 0x50, 0x44, 0x31]);
  final List<int> json = utf8.encode(jsonEncode(release));
  out
    ..add((ByteData(4)..setUint32(0, json.length)).buffer.asUint8List())
    ..add(json);
  files.forEach((String name, Uint8List bytes) {
    final List<int> n = utf8.encode(name);
    out
      ..add(<int>[n.length >> 8, n.length & 0xFF])
      ..add(n)
      ..add(
        (ByteData(8)
              ..setUint32(0, bytes.length ~/ 0x100000000)
              ..setUint32(4, bytes.length % 0x100000000))
            .buffer
            .asUint8List(),
      )
      ..add(bytes);
  });
  return out.takeBytes();
}

Future<SimpleKeyPair> _readKey(String path) async =>
    keyFromSeed(base64Url.decode((await File(path).readAsString()).trim()));

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void _writeJson(String path, Object json) => File(
  path,
).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

/// `platform=path` arguments.
Map<String, String> _fileArgs(List<String> args) => <String, String>{
  for (final String a in args)
    if (a.contains('=') && !a.startsWith('--'))
      a.substring(0, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
};

String? _option(List<String> args, String name) {
  final int i = args.indexOf('--$name');
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Użycie: keygen | pubkey | create | sign | verify | bundle | revoke',
    );
    exitCode = 64;
    return;
  }
  switch (args.first) {
    case 'keygen':
      final File out = File(args[1]);
      if (out.existsSync()) {
        stderr.writeln('Plik ${out.path} już istnieje — nie nadpisuję.');
        exitCode = 1;
        return;
      }
      final Random random = Random.secure();
      final List<int> seed = List<int>.generate(32, (_) => random.nextInt(256));
      out.writeAsStringSync(b64(seed));
      stdout.writeln(
        'Klucz prywatny zapisany w ${out.path} — trzymaj go offline.',
      );
      stdout.writeln('Klucz publiczny (do kReleaseMaintainers):');
      stdout.writeln(await publicKeyOf(await keyFromSeed(seed)));
    case 'pubkey':
      stdout.writeln(await publicKeyOf(await _readKey(args[1])));
    case 'create':
      final String version = _option(args, 'version')!;
      final int build = int.parse(_option(args, 'build')!);
      final String out = _option(args, 'out') ?? 'release.json';
      final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
      for (final MapEntry<String, String> f in _fileArgs(
        args.skip(1).toList(),
      ).entries) {
        final Uint8List bytes = await File(f.value).readAsBytes();
        final String ext = f.value.contains('.')
            ? f.value.substring(f.value.lastIndexOf('.'))
            : '';
        files.add(
          describeFile(
            bytes,
            platform: f.key,
            name: 'zen-$version-${f.key}$ext',
          ),
        );
      }
      _writeJson(
        out,
        createRelease(
          version: version,
          build: build,
          files: files,
          notes: _option(args, 'notes') ?? '',
        ),
      );
      stdout.writeln(
        'Zapisano $out (${files.length} plików). Teraz podpisz: sign $out klucz',
      );
    case 'sign':
      final Map<String, dynamic> signed = await signRelease(
        _readJson(args[1]),
        await _readKey(args[2]),
      );
      _writeJson(args[1], signed);
      stdout.writeln(
        'Podpisano. Ważne podpisy: ${(await validSigners(signed)).length}',
      );
    case 'verify':
      final List<String> ok = await validSigners(_readJson(args[1]));
      stdout.writeln('Ważne podpisy (${ok.length}):');
      ok.forEach(stdout.writeln);
    case 'bundle':
      final Map<String, dynamic> release = _readJson(args[1]);
      final Map<String, dynamic> m = release['m'] as Map<String, dynamic>;
      final Map<String, Uint8List> files = <String, Uint8List>{};
      for (final MapEntry<String, String> f in _fileArgs(
        args.skip(3).toList(),
      ).entries) {
        final Map<String, dynamic>? meant = (m['files'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .where((Map<String, dynamic> x) => x['p'] == f.key)
            .firstOrNull;
        if (meant == null) {
          stderr.writeln('Wydanie nie ma pliku dla ${f.key}.');
          exitCode = 1;
          return;
        }
        final Uint8List bytes = await File(f.value).readAsBytes();
        if (sha256Hex(bytes) != meant['sha256']) {
          stderr.writeln('Plik ${f.value} nie zgadza się z wydaniem.');
          exitCode = 1;
          return;
        }
        files[meant['name'] as String] = bytes;
      }
      await File(args[2]).writeAsBytes(encodeBundle(release, files));
      stdout.writeln('Zapisano ${args[2]}.');
    case 'revoke':
      final int build = int.parse(_option(args, 'build')!);
      final List<String> rest = <String>[
        for (int i = 1; i < args.length; i++)
          if (!args[i].startsWith('--') && !args[i - 1].startsWith('--'))
            args[i],
      ];
      _writeJson(
        rest[1],
        await createRevocation(
          build: build,
          reason: _option(args, 'why') ?? '',
          key: await _readKey(rest[0]),
        ),
      );
      stdout.writeln(
        'Zapisano ${rest[1]}. Wczytaj go w aplikacji jak aktualizację.',
      );
    default:
      stderr.writeln('Nieznane polecenie ${args.first}');
      exitCode = 64;
  }
}
