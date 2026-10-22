// Tool for the project maintainers: keys, signing and bundling releases
// for network updates, the signed donation details and mirrors,
// the warrant canary, and the APK certificate fingerprint.
// Plain Dart, no Flutter:
//
//   dart run tool/zen_release.dart keygen maintainer.key
//   dart run tool/zen_release.dart maintainers --write ID1 ID2 ID3
//   dart run tool/zen_release.dart create --version 1.10.0 --build 10 \
//       --notes "Co nowego" --out release.json \
//       --mirror https://codeberg.org/... \
//       android-arm64-v8a=dist/Zen-arm64-v8a.apk \
//       android-armeabi-v7a=dist/Zen-armeabi-v7a.apk \
//       android-x86_64=dist/Zen-x86_64.apk \
//       windows=dist/zen-windows.zip
//   dart run tool/zen_release.dart sign release.json maintainer.key
//   dart run tool/zen_release.dart verify release.json
//   dart run tool/zen_release.dart sums release.json > SHA256SUMS
//   dart run tool/zen_release.dart sums-manifest --version 1.10.0 \
//       --out SHA256SUMS.sig SHA256SUMS        # then: sign SHA256SUMS.sig key
//   dart run tool/zen_release.dart bundle release.json zen-1.10.0.zenupdate \
//       android-arm64-v8a=... windows=...
//   dart run tool/zen_release.dart revoke --build 10 --why "Powód" \
//       maintainer.key revoke-10.json
//   dart run tool/zen_release.dart canary --text "..." --days 90 \
//       --out canary.json                      # then: sign canary.json key
//   dart run tool/zen_release.dart fingerprint Zen-arm64-v8a.apk \
//       [Zen-armeabi-v7a.apk Zen-x86_64.apk] [--write]   # one certificate
//   dart run tool/zen_release.dart fingerprint --keystore zen-release.jks \
//       [--alias zen]                          # password: $ZEN_STOREPASS
//
// Signatures are Zen's hybrid ones (Ed25519 + ML-DSA-65, zen_sig.dart),
// made by the bridge's `cmd/zensig`: keygen, pubkey, sign and verify need
// Go. A maintainer's public key is its hybrid id `<Ed25519>.<ML-DSA
// fingerprint>`.
//
// See docs/RELEASES.md, sections 2 and 8.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:zen/src/core/crypto/hybrid_signature_core.dart';
import 'package:zen/src/features/update/apk_signing_block.dart';

import 'zen_sig.dart';

export 'zen_sig.dart' show ToolKey, useToolSigner;

/// The official donation link, author and repository written into each
/// release manifest by default (the app compares them with its own; a test
/// keeps these equal to the app's constants).
const String kDefaultDonationUrl = 'https://buycoffee.to/zen';
const String kDefaultAuthor = 'Robert Ostrowski-Jagoda';
const String kDefaultRepositoryUrl =
    'https://github.com/robertostrowskijagoda/Zen';

/// Where the pinned lists live in the app.
const String kApkSignaturePath = 'lib/src/features/update/apk_signature.dart';
const String kReleasePath = 'lib/src/features/update/release.dart';

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

/// The `official` part of a manifest (`OfficialInfo` in the app).
Map<String, dynamic> officialInfo({
  String? donation = kDefaultDonationUrl,
  String? author = kDefaultAuthor,
  String? repository = kDefaultRepositoryUrl,
}) => <String, dynamic>{
  'donation': ?donation,
  'author': ?author,
  'repo': ?repository,
};

Map<String, dynamic> createRelease({
  required String version,
  required int build,
  required List<Map<String, dynamic>> files,
  String notes = '',
  int? publishedAt,
  Map<String, dynamic>? official,
  List<String> mirrors = const <String>[],
}) => <String, dynamic>{
  'm': <String, dynamic>{
    't': 'zen_release',
    'app': 'zen',
    'version': version,
    'build': build,
    'at': publishedAt ?? DateTime.now().millisecondsSinceEpoch,
    'notes': notes,
    'files': files,
    'official': ?official,
    if (mirrors.isNotEmpty) 'mirrors': mirrors,
  },
  'sigs': <Map<String, String>>[],
};

/// An unsigned warrant canary (`SignedCanary` in the app): "until" is when
/// the next one is due at the latest.
Map<String, dynamic> createCanary({
  required String text,
  required Duration validFor,
  int? at,
}) {
  final int when = at ?? DateTime.now().millisecondsSinceEpoch;
  return <String, dynamic>{
    'm': <String, dynamic>{
      't': 'zen_canary',
      'app': 'zen',
      'at': when,
      'until': when + validFor.inMilliseconds,
      'text': text,
    },
    'sigs': <Map<String, String>>[],
  };
}

/// The unsigned `SHA256SUMS.sig` of GitHub release [version] (`SignedSums`
/// in the app): every file [sumsText] (a `SHA256SUMS`) lists, with its sum.
Map<String, dynamic> createSignedSums({
  required String version,
  required String sumsText,
}) {
  if (!RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$').hasMatch(version)) {
    throw FormatException('To nie jest numer wersji: $version');
  }
  final RegExp line = RegExp(r'^([0-9a-fA-F]{64}) [ *]?(.+)$');
  final Map<String, String> files = <String, String>{};
  for (final String raw in const LineSplitter().convert(sumsText)) {
    final RegExpMatch? m = line.firstMatch(raw.trim());
    if (m == null) {
      continue;
    }
    final String name = m.group(2)!.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$').hasMatch(name)) {
      throw FormatException('Nazwa pliku nie do podpisania: $name');
    }
    files[name] = m.group(1)!.toLowerCase();
  }
  if (files.isEmpty || files.length > 64) {
    throw const FormatException('SHA256SUMS bez plików (albo ponad 64).');
  }
  return <String, dynamic>{
    'm': <String, dynamic>{
      't': 'zen_sums',
      'app': 'zen',
      'version': version,
      'files': files,
    },
    'sigs': <Map<String, String>>[],
  };
}

/// `SHA256SUMS` lines (`sha256  name`) for the files of a release.
String sha256Sums(Map<String, dynamic> release) {
  final List<dynamic> files =
      (release['m'] as Map<String, dynamic>)['files'] as List<dynamic>;
  return <String>[
    for (final dynamic f in files)
      '${(f as Map<String, dynamic>)['sha256']}  ${f['name']}',
  ].map((String line) => '$line\n').join();
}

/// The SHA-256 fingerprints of the certificates [apk] is signed with
/// (every scheme; normally one certificate), lower-case hex. Throws when
/// the file has no v2/v3 signature or its schemes name different signers.
Future<List<String>> apkFingerprints(File apk) async {
  final List<List<String>>? schemes = await readApkSignerCertificates(apk);
  if (schemes == null || schemes.any((List<String> s) => s.isEmpty)) {
    throw const FormatException(
      'Brak podpisu APK v2/v3 (albo plik uszkodzony).',
    );
  }
  final Set<String> all = <String>{for (final List<String> s in schemes) ...s};
  final Set<String> newest = schemes.first.toSet();
  if (all.length != newest.length) {
    throw const FormatException(
      'Schematy podpisu wskazują różne certyfikaty — sprawdź apksigner.',
    );
  }
  return newest.toList();
}

/// The certificates every one of [apks] is signed with (the per-ABI APKs
/// of a release): throws when there is no file, or when they are not all
/// signed with exactly the same certificates.
Future<List<String>> sameApkFingerprints(List<File> apks) async {
  if (apks.isEmpty) {
    throw const FormatException('Podaj co najmniej jeden plik APK.');
  }
  final List<String> first = await apkFingerprints(apks.first);
  for (final File apk in apks.skip(1)) {
    final List<String> other = await apkFingerprints(apk);
    if (other.toSet().length != first.toSet().length ||
        !other.toSet().containsAll(first)) {
      throw FormatException(
        '${apk.path} jest podpisany innym certyfikatem niż '
        '${apks.first.path}.',
      );
    }
  }
  return first;
}

/// SHA-256 of the certificate of [alias] in [keystore], via `keytool`
/// (JDK). The password comes from `ZEN_STOREPASS`, or keytool asks.
Future<String> keystoreFingerprint(String keystore, String alias) async {
  final bool fromEnv = Platform.environment.containsKey('ZEN_STOREPASS');
  final Process process = await Process.start('keytool', <String>[
    '-exportcert',
    '-keystore',
    keystore,
    '-alias',
    alias,
    if (fromEnv) '-storepass:env',
    if (fromEnv) 'ZEN_STOREPASS',
  ]);
  // keytool asks for the password on stderr and reads it from stdin.
  final StreamSubscription<List<int>>? input = fromEnv
      ? null
      : stdin.listen(process.stdin.add, onError: (Object _) {});
  process.stderr.listen(stderr.add);
  final List<int> der = <int>[
    for (final List<int> chunk in await process.stdout.toList()) ...chunk,
  ];
  final int code = await process.exitCode;
  await input?.cancel();
  if (code != 0 || der.isEmpty) {
    throw const FormatException('keytool nie zwrócił certyfikatu.');
  }
  return sha256Hex(der);
}

/// [source] (a Dart file) with `const List<String> [name] = <String>[…];`
/// set to [values]. Throws when the declaration is not there.
String replaceConstList(String source, String name, List<String> values) {
  final RegExp declaration = RegExp(
    'const List<String> ${RegExp.escape(name)}\\s*=\\s*<String>\\[[^\\]]*\\];',
  );
  if (!declaration.hasMatch(source)) {
    throw FormatException('Nie znaleziono $name.');
  }
  final String list = values.isEmpty
      ? '<String>[]'
      : '<String>[\n${values.map((String v) => "  '$v',\n").join()}]';
  return source.replaceFirst(declaration, 'const List<String> $name = $list;');
}

Future<ToolKey> keyFromSeed(List<int> seed) => ToolKey.fromSeed(seed);

/// The key's public part as `kReleaseMaintainers` holds it: its hybrid id.
Future<String> publicKeyOf(ToolKey key) async => key.hybridId;

Future<Map<String, dynamic>> signRelease(
  Map<String, dynamic> release,
  ToolKey key,
) async {
  final String sig = await key.sign(canonicalBytes(release['m']));
  final String pub = key.hybridId;
  final List<dynamic> sigs = <dynamic>[
    for (final dynamic s in release['sigs'] as List<dynamic>)
      if ((s as Map<String, dynamic>)['k'] != pub) s,
    <String, String>{'k': pub, 's': sig},
  ];
  return <String, dynamic>{'m': release['m'], 'sigs': sigs};
}

/// The hybrid ids whose signature in [release] holds (both halves).
Future<List<String>> validSigners(Map<String, dynamic> release) async {
  final List<int> message = canonicalBytes(release['m']);
  final List<String> ok = <String>[];
  for (final dynamic s in release['sigs'] as List<dynamic>) {
    final Map<String, dynamic> m = s as Map<String, dynamic>;
    final Object? k = m['k'];
    final Object? sig = m['s'];
    if (k is String &&
        sig is String &&
        await verifyByHybridId(k, message, sig)) {
      ok.add(k);
    }
  }
  return ok;
}

Future<Map<String, dynamic>> createRevocation({
  required int build,
  required String reason,
  required ToolKey key,
  int? at,
}) async {
  final Map<String, dynamic> body = <String, dynamic>{
    't': 'zen_revoke',
    'app': 'zen',
    'build': build,
    'at': at ?? DateTime.now().millisecondsSinceEpoch,
    'why': reason,
  };
  return <String, dynamic>{
    ...body,
    'k': key.hybridId,
    's': await key.sign(canonicalBytes(body)),
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

Future<ToolKey> _readKey(String path) async =>
    keyFromSeed(base64Url.decode((await File(path).readAsString()).trim()));

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void _writeJson(String path, Object json) => File(
  path,
).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

/// Options without a value.
const Set<String> _flags = <String>{'--write', '--no-official'};

/// The arguments that are not options or option values.
List<String> positionalArgs(List<String> args) => <String>[
  for (int i = 0; i < args.length; i++)
    if (!args[i].startsWith('--') &&
        (i == 0 ||
            !args[i - 1].startsWith('--') ||
            _flags.contains(args[i - 1])))
      args[i],
];

/// `platform=path` arguments.
Map<String, String> fileArgs(List<String> args) => <String, String>{
  for (final String a in positionalArgs(args))
    if (a.contains('='))
      a.substring(0, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
};

String? _option(List<String> args, String name) {
  final int i = args.indexOf('--$name');
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// Every value of a repeatable option.
List<String> _options(List<String> args, String name) => <String>[
  for (int i = 0; i + 1 < args.length; i++)
    if (args[i] == '--$name') args[i + 1],
];

const String _usage = '''
Użycie: dart run tool/zen_release.dart <polecenie>
  keygen PLIK                     nowy klucz opiekuna (prywatny do PLIKU)
  pubkey PLIK                     identyfikator klucza (Ed25519.ML-DSA)
  maintainers [--write] ID1 [ID2 ID3]  lista kReleaseMaintainers (release.dart)
  create --version V --build N [--notes T] [--out release.json]
         [--donation URL] [--author A] [--repo URL] [--no-official]
         [--mirror URL]... platforma=plik...
  canary --text T [--days 90] [--out canary.json]
  sign PLIK.json KLUCZ            podpis wydania albo kanarka
  verify PLIK.json                kto podpisał i co jest w środku
  sums release.json               linie SHA256SUMS
  sums-manifest --version V [--out SHA256SUMS.sig] SHA256SUMS
                                  SHA256SUMS do podpisania (aktualizacja z GitHuba)
  bundle release.json WYJŚCIE.zenupdate platforma=plik...
  revoke --build N --why T KLUCZ WYJŚCIE.json
  fingerprint PLIK.apk... [--write]  odcisk certyfikatu APK (kilka plików:
                                  muszą mieć ten sam certyfikat)
  fingerprint --keystore PLIK.jks [--alias zen] [--write]''';

String _dartList(String name, List<String> values) =>
    replaceConstList('const List<String> $name = <String>[];', name, values);

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  try {
    await _run(args.first, args.skip(1).toList());
  } on Object catch (error) {
    stderr.writeln('Błąd: $error');
    exitCode = 1;
  }
}

Future<void> _run(String command, List<String> args) async {
  final List<String> positional = positionalArgs(args);
  switch (command) {
    case 'keygen':
      final File out = File(positional.first);
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
      stdout.writeln(
        'Identyfikator klucza (Ed25519.ML-DSA, do kReleaseMaintainers):',
      );
      stdout.writeln(await publicKeyOf(await keyFromSeed(seed)));
    case 'pubkey':
      stdout.writeln(await publicKeyOf(await _readKey(positional.first)));
    case 'maintainers':
      for (final String key in positional) {
        if (parseHybridKeyId(key) == null) {
          throw FormatException(
            'To nie jest identyfikator klucza (Ed25519.ML-DSA): $key',
          );
        }
      }
      if (positional.toSet().length != positional.length ||
          positional.isEmpty) {
        throw const FormatException('Podaj różne identyfikatory kluczy.');
      }
      if (positional.length < 3) {
        stdout.writeln(
          'Uwaga: aktualizacje z GitHuba wymagają podpisu jednym z tych '
          'kluczy; aktualizacje przez sieć zostają wyłączone (potrzebują 2 '
          'podpisów z listy co najmniej 3 kluczy).',
        );
      }
      if (args.contains('--write')) {
        final File file = File(kReleasePath);
        file.writeAsStringSync(
          replaceConstList(
            file.readAsStringSync(),
            'kReleaseMaintainers',
            positional,
          ),
        );
        stdout.writeln(
          'Zapisano w ${file.path}. Aktualizacje przez sieć działają od '
          'następnej kompilacji.',
        );
      } else {
        stdout.writeln(_dartList('kReleaseMaintainers', positional));
      }
    case 'create':
      final String version = _option(args, 'version')!;
      final int build = int.parse(_option(args, 'build')!);
      final String out = _option(args, 'out') ?? 'release.json';
      final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
      for (final MapEntry<String, String> f in fileArgs(args).entries) {
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
          official: args.contains('--no-official')
              ? null
              : officialInfo(
                  donation: _option(args, 'donation') ?? kDefaultDonationUrl,
                  author: _option(args, 'author') ?? kDefaultAuthor,
                  repository: _option(args, 'repo') ?? kDefaultRepositoryUrl,
                ),
          mirrors: _options(args, 'mirror'),
        ),
      );
      stdout.writeln(
        'Zapisano $out (${files.length} plików). Teraz podpisz: sign $out klucz',
      );
    case 'canary':
      final String? text = _option(args, 'text');
      if (text == null || text.trim().isEmpty) {
        throw const FormatException('Podaj --text.');
      }
      final int days = int.parse(_option(args, 'days') ?? '90');
      final String out = _option(args, 'out') ?? 'canary.json';
      _writeJson(
        out,
        createCanary(
          text: text.trim(),
          validFor: Duration(days: days),
        ),
      );
      stdout.writeln(
        'Zapisano $out (ważny $days dni). Teraz podpisz: sign $out klucz',
      );
    case 'sign':
      final Map<String, dynamic> signed = await signRelease(
        _readJson(positional[0]),
        await _readKey(positional[1]),
      );
      _writeJson(positional[0], signed);
      stdout.writeln(
        'Podpisano. Ważne podpisy: ${(await validSigners(signed)).length}',
      );
    case 'verify':
      final Map<String, dynamic> json = _readJson(positional.first);
      final Map<String, dynamic> m = json['m'] as Map<String, dynamic>;
      if (m['t'] == 'zen_sums') {
        stdout.writeln('SHA256SUMS wydania ${m['version']} na GitHubie:');
        (m['files'] as Map<String, dynamic>).forEach(
          (String name, dynamic sha) => stdout.writeln('  $sha  $name'),
        );
      } else if (m['t'] == 'zen_canary') {
        stdout.writeln(
          'Kanarek z ${_day(m['at'] as int)}, następny do '
          '${_day(m['until'] as int)}:\n${m['text']}',
        );
      } else {
        stdout.writeln('Wydanie ${m['version']} (kompilacja ${m['build']})');
        for (final dynamic f in m['files'] as List<dynamic>) {
          final Map<String, dynamic> file = f as Map<String, dynamic>;
          stdout.writeln('  ${file['p']}: ${file['name']} ${file['sha256']}');
        }
        final Map<String, dynamic>? official =
            m['official'] as Map<String, dynamic>?;
        stdout.writeln(
          official == null
              ? 'Bez podpisanego linku do zbiórki.'
              : 'Zbiórka: ${official['donation']}, autor: '
                    '${official['author']}, repozytorium: ${official['repo']}',
        );
        for (final dynamic mirror
            in (m['mirrors'] as List<dynamic>?) ?? const <dynamic>[]) {
          stdout.writeln('  lustro: $mirror');
        }
      }
      final List<String> ok = await validSigners(json);
      final bool sums = m['t'] == 'zen_sums';
      stdout.writeln(
        'Ważne podpisy (${ok.length}; aplikacja wymaga ${sums ? 1 : 2} z '
        'listy kReleaseMaintainers):',
      );
      ok.forEach(stdout.writeln);
      if (sums && ok.isEmpty) {
        stderr.writeln('Brak ważnego podpisu.');
        exitCode = 1;
      }
    case 'sums':
      stdout.write(sha256Sums(_readJson(positional.first)));
    case 'sums-manifest':
      final String? version = _option(args, 'version');
      if (version == null) {
        throw const FormatException('Podaj --version.');
      }
      final String out = _option(args, 'out') ?? 'SHA256SUMS.sig';
      _writeJson(
        out,
        createSignedSums(
          version: version,
          sumsText: File(positional.first).readAsStringSync(),
        ),
      );
      stdout.writeln('Zapisano $out. Teraz podpisz: sign $out klucz');
    case 'bundle':
      final Map<String, dynamic> release = _readJson(positional[0]);
      final Map<String, dynamic> m = release['m'] as Map<String, dynamic>;
      final Map<String, Uint8List> files = <String, Uint8List>{};
      for (final MapEntry<String, String> f in fileArgs(args).entries) {
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
      await File(positional[1]).writeAsBytes(encodeBundle(release, files));
      stdout.writeln('Zapisano ${positional[1]}.');
    case 'revoke':
      final int build = int.parse(_option(args, 'build')!);
      _writeJson(
        positional[1],
        await createRevocation(
          build: build,
          reason: _option(args, 'why') ?? '',
          key: await _readKey(positional[0]),
        ),
      );
      stdout.writeln(
        'Zapisano ${positional[1]}. Wczytaj go w aplikacji jak aktualizację.',
      );
    case 'fingerprint':
      final String? keystore = _option(args, 'keystore');
      final List<String> fingerprints = keystore != null
          ? <String>[
              await keystoreFingerprint(
                keystore,
                _option(args, 'alias') ?? 'zen',
              ),
            ]
          : await sameApkFingerprints(<File>[
              for (final String path in positional) File(path),
            ]);
      stdout.writeln('Odcisk certyfikatu (SHA-256), do README i wydania:');
      for (final String fp in fingerprints) {
        stdout.writeln('  ${formatCertificateFingerprint(fp)}');
      }
      if (args.contains('--write')) {
        final File file = File(kApkSignaturePath);
        file.writeAsStringSync(
          replaceConstList(
            file.readAsStringSync(),
            'kOfficialApkCertificatesSha256',
            fingerprints,
          ),
        );
        stdout.writeln('Zapisano w ${file.path}.');
      } else {
        stdout.writeln(
          '\n${_dartList('kOfficialApkCertificatesSha256', fingerprints)}',
        );
      }
    default:
      stderr.writeln('Nieznane polecenie $command\n$_usage');
      exitCode = 64;
  }
}

String _day(int millis) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year}';
}
