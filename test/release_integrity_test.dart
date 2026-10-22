import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/update/apk_signature.dart';
import 'package:zen/src/features/update/canary.dart';
import 'package:zen/src/features/update/official_info.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/update_book.dart';
import 'package:zen/src/features/update/update_service.dart';

import '../tool/release_contract.dart' show pinnedSignatureProblems;
import '../tool/zen_release.dart' as tool;

const int _day = 24 * 3600 * 1000;
const String _otherDonation = 'https://example.org/zbiorka';

Uint8List _bytes(int n, [int seed = 7]) => Uint8List.fromList(
  List<int>.generate(n, (int i) => (i * 31 + seed) & 0xFF),
);

/// A friend-to-friend network in memory (as in network_update_test.dart).
final class _Host implements UpdateHost {
  _Host(this.net, this.address, this.friendList) {
    net[address] = this;
  }

  final Map<String, _Host> net;
  final String address;
  final List<String> friendList;

  @override
  final LedgerDisk disk = MemoryLedgerDisk();

  @override
  final BlobStore blobs = BlobStore();

  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();
  final StreamController<String> _greeted =
      StreamController<String>.broadcast();
  final StreamController<String> _done = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Stream<String> get greeted => _greeted.stream;

  @override
  Stream<String> get blobCompleted => _done.stream;

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  Iterable<String> friends() => friendList;

  @override
  void fetchBlob(String id, List<String> sources) {}

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    net[to]?._frames.add(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }
}

Future<void> _settle(List<UpdateService> services) async {
  for (int round = 0; round < 3; round++) {
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    for (final UpdateService s in services) {
      await s.idle;
    }
  }
}

// ---- a minimal APK with an APK Signing Block (see apk_signature_test) ----

const int _v2 = 0x7109871a;
const int _v3 = 0xf05368c0;

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _u64(int value) =>
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List();

Uint8List _prefixed(List<int> bytes) =>
    Uint8List.fromList(<int>[..._u32(bytes.length), ...bytes]);

Uint8List _schemeValue(List<int> certificate, {required bool v3}) {
  final Uint8List signedData = Uint8List.fromList(<int>[
    ..._prefixed(_prefixed(<int>[1, 2, 3])),
    ..._prefixed(_prefixed(certificate)),
    if (v3) ...<int>[..._u32(24), ..._u32(0x7fffffff)],
    ..._prefixed(const <int>[]),
  ]);
  final Uint8List signer = Uint8List.fromList(<int>[
    ..._prefixed(signedData),
    if (v3) ...<int>[..._u32(24), ..._u32(0x7fffffff)],
    ..._prefixed(_prefixed(<int>[9, 9])),
    ..._prefixed(<int>[7, 7, 7]),
  ]);
  return _prefixed(_prefixed(signer));
}

Uint8List _apk(Map<int, List<int>> schemes) {
  final BytesBuilder pairs = BytesBuilder();
  schemes.forEach((int id, List<int> certificate) {
    final Uint8List value = _schemeValue(certificate, v3: id == _v3);
    pairs
      ..add(_u64(value.length + 4))
      ..add(_u32(id))
      ..add(value);
  });
  final Uint8List pairBytes = pairs.takeBytes();
  final int blockSize = pairBytes.length + 8 + 16;
  final Uint8List block = Uint8List.fromList(<int>[
    ..._u64(blockSize),
    ...pairBytes,
    ..._u64(blockSize),
    ...ascii.encode('APK Sig Block 42'),
  ]);
  final Uint8List entries = Uint8List.fromList(List<int>.filled(40, 0x11));
  final Uint8List centralDirectory = Uint8List.fromList(
    List<int>.filled(46, 0x22),
  );
  final ByteData end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint32(12, centralDirectory.length, Endian.little)
    ..setUint32(16, entries.length + block.length, Endian.little)
    ..setUint16(20, 0, Endian.little);
  return Uint8List.fromList(<int>[
    ...entries,
    ...block,
    ...centralDirectory,
    ...end.buffer.asUint8List(),
  ]);
}

void main() {
  late List<tool.ToolKey> toolKeys;
  late List<String> maintainers;

  setUpAll(() async {
    // The tool signs as the app does (the bridge when the run has it).
    tool.useToolSigner(hybridSigner);
    toolKeys = <tool.ToolKey>[
      for (int i = 0; i < 3; i++)
        await tool.keyFromSeed(List<int>.filled(32, i + 11)),
    ];
    maintainers = <String>[
      for (final tool.ToolKey k in toolKeys) await tool.publicKeyOf(k),
    ];
  });
  tearDownAll(() => tool.useToolSigner(null));

  Future<Map<String, dynamic>> signedJson(
    Map<String, dynamic> unsigned, {
    int signers = 2,
  }) async {
    Map<String, dynamic> out = unsigned;
    for (int i = 0; i < signers; i++) {
      out = await tool.signRelease(out, toolKeys[i]);
    }
    return jsonDecode(jsonEncode(out)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> release({
    int build = kAppBuild + 1,
    Map<String, dynamic>? official,
    List<String> mirrors = const <String>[],
    int signers = 2,
  }) => signedJson(
    tool.createRelease(
      version: '9.9.$build',
      build: build,
      publishedAt: 1000,
      files: <Map<String, dynamic>>[
        tool.describeFile(_bytes(2000), platform: 'android', name: 'z.apk'),
        tool.describeFile(_bytes(3000, 9), platform: 'windows', name: 'z.zip'),
      ],
      official: official,
      mirrors: mirrors,
    ),
    signers: signers,
  );

  group('signed donation details', () {
    test('the tool writes the same details the app shows', () {
      expect(tool.kDefaultDonationUrl, kDonationUrl);
      expect(tool.kDefaultAuthor, kOfficialAuthor);
      expect(tool.kDefaultRepositoryUrl, PeerShareCodec.repositoryUrl);
      final OfficialInfo build = thisBuildOfficialInfo();
      expect(
        OfficialInfo.fromJson(tool.officialInfo())!.differencesFrom(build),
        isEmpty,
      );
    });

    test(
      'the manifest signs APK and ZIP hashes, donation and mirrors',
      () async {
        final Map<String, dynamic> json = await release(
          official: tool.officialInfo(),
          mirrors: <String>['https://codeberg.org/zen/Zen'],
        );
        final SignedRelease signed = SignedRelease.fromJson(json)!;
        expect(await signed.isTrusted(maintainers: maintainers), isTrue);
        expect(signed.manifest.official!.donation, kDonationUrl);
        expect(signed.manifest.official!.author, kOfficialAuthor);
        expect(signed.manifest.mirrors, <String>[
          'https://codeberg.org/zen/Zen',
        ]);
        expect(signed.manifest.fileFor('windows')!.sha256, hasLength(64));
        expect(
          signed.manifest.toJson(),
          json['m'],
          reason: 'the app signs exactly what the tool wrote',
        );

        // A copy that swaps the link in the manifest loses the signatures.
        final Map<String, dynamic> swapped =
            jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
        ((swapped['m'] as Map<String, dynamic>)['official']
                as Map<String, dynamic>)['donation'] =
            _otherDonation;
        expect(
          await SignedRelease.fromJson(
            swapped,
          )!.isTrusted(maintainers: maintainers),
          isFalse,
        );
        // So does one that swaps a mirror or a file hash.
        final Map<String, dynamic> mirror =
            jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
        (mirror['m'] as Map<String, dynamic>)['mirrors'] = <String>[
          'https://evil.example/Zen',
        ];
        expect(
          await SignedRelease.fromJson(
            mirror,
          )!.isTrusted(maintainers: maintainers),
          isFalse,
        );
      },
    );

    test('a build showing another link is told apart', () {
      const OfficialInfo signed = OfficialInfo(
        donation: 'https://buycoffee.to/zen',
        author: kOfficialAuthor,
        repository: 'https://github.com/robertostrowskijagoda/Zen',
      );
      expect(
        signed.differencesFrom(
          const OfficialInfo(
            donation: 'https://buycoffee.to/zen/',
            author: kOfficialAuthor,
            repository: 'https://GitHub.com/robertostrowskijagoda/Zen',
          ),
        ),
        isEmpty,
      );
      expect(
        signed.differencesFrom(
          const OfficialInfo(
            donation: _otherDonation,
            author: 'Ktoś Inny',
            repository: 'https://github.com/robertostrowskijagoda/Zen',
          ),
        ),
        <String>['donation', 'author'],
      );
      // Only what is signed is compared.
      expect(
        const OfficialInfo(
          donation: 'https://buycoffee.to/zen',
        ).differencesFrom(const OfficialInfo(donation: kDonationUrl)),
        isEmpty,
      );
    });

    test(
      'unknown fields keep signatures valid, unsafe ones are refused',
      () async {
        final Map<String, dynamic> future = tool.createRelease(
          version: '9.9.9',
          build: kAppBuild + 1,
          publishedAt: 1,
          files: <Map<String, dynamic>>[
            tool.describeFile(_bytes(10), platform: 'android', name: 'z.apk'),
          ],
        );
        (future['m'] as Map<String, dynamic>)['later'] = <String, dynamic>{
          'x': 1,
          'y': <String>['a'],
        };
        final SignedRelease signed = SignedRelease.fromJson(
          await signedJson(future),
        )!;
        expect(signed.manifest.extra.keys, <String>['later']);
        expect(await signed.isTrusted(maintainers: maintainers), isTrue);

        Map<String, dynamic> withField(String key, Object? value) {
          final Map<String, dynamic> copy =
              jsonDecode(jsonEncode(future)) as Map<String, dynamic>;
          (copy['m'] as Map<String, dynamic>)[key] = value;
          return copy;
        }

        expect(SignedRelease.fromJson(withField('later', 1.5)), isNull);
        expect(
          SignedRelease.fromJson(
            withField('official', <String, dynamic>{
              'donation': 'http://buycoffee.to/zen',
            }),
          ),
          isNull,
        );
        expect(
          SignedRelease.fromJson(
            withField('mirrors', <String>['ftp://mirror.example/zen']),
          ),
          isNull,
        );
        expect(
          SignedRelease.fromJson(
            withField('mirrors', <String>['http://zenzenzen.onion/']),
          ),
          isNull,
        );
      },
    );

    test(
      'the book keeps the newest signed details, even for this build',
      () async {
        final UpdateBook book = UpdateBook(
          currentBuild: 10,
          maintainers: maintainers,
        );
        final SignedRelease same = SignedRelease.fromJson(
          await release(build: 10, official: tool.officialInfo()),
        )!;
        expect(await book.offerRelease(same, now: 0), isFalse);
        expect(await book.offerOfficial(same), isTrue);
        expect(await book.offerOfficial(same), isFalse);
        final SignedRelease older = SignedRelease.fromJson(
          await release(
            build: 9,
            official: tool.officialInfo(donation: _otherDonation),
          ),
        )!;
        expect(await book.offerOfficial(older), isFalse);
        final SignedRelease oneSignature = SignedRelease.fromJson(
          await release(build: 11, official: tool.officialInfo(), signers: 1),
        )!;
        expect(await book.offerOfficial(oneSignature), isFalse);
        expect(book.signedOfficial!.donation, kDonationUrl);

        final UpdateBook again = UpdateBook(
          currentBuild: 10,
          maintainers: maintainers,
        )..restore(jsonDecode(jsonEncode(book.toJson())));
        expect(again.officialSource!.manifest.build, 10);

        final UpdateBook off = UpdateBook(
          currentBuild: 10,
          maintainers: const <String>[],
        );
        expect(await off.offerOfficial(same), isFalse);
      },
    );

    test('a signed link that differs is noticed and passed on', () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host a = _Host(net, 'a', <String>['b']);
      final _Host b = _Host(net, 'b', <String>['a']);
      const OfficialInfo modified = OfficialInfo(
        donation: _otherDonation,
        author: kOfficialAuthor,
        repository: 'https://github.com/robertostrowskijagoda/Zen',
      );
      final UpdateService sa = UpdateService(
        host: a,
        book: UpdateBook(currentBuild: kAppBuild, maintainers: maintainers),
        platform: 'android',
        buildInfo: modified,
      );
      final UpdateService sb = UpdateService(
        host: b,
        book: UpdateBook(currentBuild: kAppBuild, maintainers: maintainers),
        platform: 'android',
      );
      await sa.start();
      await sb.start();
      addTearDown(() async {
        await sa.stop();
        await sb.stop();
      });
      expect(sa.officialDifferences, isEmpty);

      final Map<String, dynamic> json = await release(
        build: kAppBuild,
        official: tool.officialInfo(),
      );
      expect(
        await sa.importBundle(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        contains('podpisane dane'),
      );
      await _settle(<UpdateService>[sa, sb]);
      expect(sa.officialDifferences, <String>['donation']);
      expect(sb.book.signedOfficial!.donation, kDonationUrl);
      expect(sb.officialDifferences, isEmpty);
      expect(sb.status.phase, UpdatePhase.upToDate);
    });
  });

  group('warrant canary', () {
    test('signed, checked, expiring and spread like a veto', () async {
      int now = 5000;
      final Map<String, dynamic> unsigned = tool.createCanary(
        text: 'Nikt nas nie zmusił do zmian w Zen.',
        validFor: const Duration(days: 90),
        at: 1000,
      );
      final SignedCanary one = SignedCanary.fromJson(
        await signedJson(unsigned, signers: 1),
      )!;
      expect(await one.isTrusted(maintainers: maintainers), isFalse);
      final Map<String, dynamic> json = await signedJson(unsigned);
      final SignedCanary canary = SignedCanary.fromJson(json)!;
      expect(await canary.isTrusted(maintainers: maintainers), isTrue);
      expect(canary.isExpired(1000 + 89 * _day), isFalse);
      expect(canary.isExpired(1000 + 91 * _day), isTrue);
      expect(SignedRelease.fromJson(json), isNull);
      final Map<String, dynamic> edited =
          jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      (edited['m'] as Map<String, dynamic>)['until'] = 1000 + 900 * _day;
      expect(
        await SignedCanary.fromJson(
          edited,
        )!.isTrusted(maintainers: maintainers),
        isFalse,
      );

      final Map<String, _Host> net = <String, _Host>{};
      final _Host a = _Host(net, 'a', <String>['b']);
      final _Host b = _Host(net, 'b', <String>['a']);
      UpdateService service(_Host h) => UpdateService(
        host: h,
        book: UpdateBook(currentBuild: kAppBuild, maintainers: maintainers),
        platform: 'android',
        now: () => now,
      );
      final UpdateService sa = service(a);
      final UpdateService sb = service(b);
      await sa.start();
      await sb.start();
      addTearDown(() async {
        await sa.stop();
        await sb.stop();
      });
      expect(
        await sa.importBundle(
          Uint8List.fromList(utf8.encode(jsonEncode(one.toJson()))),
        ),
        contains('nie ma wymaganych podpisów'),
      );
      expect(
        await sa.importBundle(Uint8List.fromList(utf8.encode(canary.encode()))),
        contains('oświadczenie'),
      );
      await _settle(<UpdateService>[sa, sb]);
      expect(sb.canary!.statement.text, contains('Nikt nas'));
      expect(sb.canaryExpired, isFalse);
      now = 1000 + 100 * _day;
      expect(sb.canaryExpired, isTrue);
      expect(
        await sa.importBundle(Uint8List.fromList(utf8.encode(canary.encode()))),
        contains('już znane'),
      );
    });
  });

  group('zen_release tool', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zen-release-tool-');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    String at(String name) => '${dir.path}${Platform.pathSeparator}$name';

    test('keys, create, two signatures and a bundle the app takes', () async {
      final List<String> keys = <String>[];
      for (int i = 0; i < 3; i++) {
        await tool.main(<String>['keygen', at('m$i.key')]);
        final String seed = File(at('m$i.key')).readAsStringSync().trim();
        keys.add(
          await tool.publicKeyOf(
            await tool.keyFromSeed(base64Url.decode(seed)),
          ),
        );
      }
      final Uint8List apk = _bytes(400 * 1024, 5);
      File(at('app-release.apk')).writeAsBytesSync(apk);
      await tool.main(<String>[
        'create',
        '--version',
        '9.9.9',
        '--build',
        '${kAppBuild + 1}',
        '--notes',
        'a=b',
        '--mirror',
        'https://codeberg.org/zen/Zen',
        '--out',
        at('release.json'),
        'android=${at('app-release.apk')}',
      ]);
      await tool.main(<String>['sign', at('release.json'), at('m0.key')]);
      await tool.main(<String>['sign', at('release.json'), at('m2.key')]);
      await tool.main(<String>[
        'bundle',
        at('release.json'),
        at('zen.zenupdate'),
        'android=${at('app-release.apk')}',
      ]);
      final Map<String, dynamic> written =
          jsonDecode(File(at('release.json')).readAsStringSync())
              as Map<String, dynamic>;
      expect(
        tool.sha256Sums(written),
        contains(crypto.sha256.convert(apk).toString()),
      );
      expect((written['m'] as Map<String, dynamic>)['notes'], 'a=b');

      final _Host host = _Host(<String, _Host>{}, 'me', <String>[]);
      final UpdateService service = UpdateService(
        host: host,
        book: UpdateBook(currentBuild: kAppBuild, maintainers: keys),
        platform: 'android',
        now: () => 0,
      );
      await service.start();
      addTearDown(service.stop);
      expect(
        await service.importBundle(File(at('zen.zenupdate')).readAsBytesSync()),
        contains('Wczytano'),
      );
      expect(service.status.phase, UpdatePhase.waiting);
      expect(service.book.mirrors, <String>['https://codeberg.org/zen/Zen']);
      expect(service.book.signedOfficial!.donation, kDonationUrl);
      expect(await service.fileBytes(), apk);
    });

    test('signed SHA256SUMS for the GitHub update: the tool signs, the app '
        'checks', () async {
      await tool.main(<String>['keygen', at('release.key')]);
      final String seed = File(at('release.key')).readAsStringSync().trim();
      final String key = await tool.publicKeyOf(
        await tool.keyFromSeed(base64Url.decode(seed)),
      );
      final String apk = 'ab' * 32;
      File(at('SHA256SUMS')).writeAsStringSync(
        '$apk  Zen.apk\n${'cd' * 32}  Zen-Windows.zip\nnot a line\n',
      );
      await tool.main(<String>[
        'sums-manifest',
        '--version',
        '1.12.0',
        '--out',
        at('SHA256SUMS.sig'),
        at('SHA256SUMS'),
      ]);
      await tool.main(<String>[
        'sign',
        at('SHA256SUMS.sig'),
        at('release.key'),
      ]);
      final SignedSums signed = SignedSums.decode(
        File(at('SHA256SUMS.sig')).readAsStringSync(),
      )!;
      expect(signed.files.keys, <String>['Zen.apk', 'Zen-Windows.zip']);
      // What CI checks after signing (verify --pinned): the key it signed
      // with is one the app pins, and the app pins one at all.
      final List<String> signers = await tool.validSigners(
        jsonDecode(File(at('SHA256SUMS.sig')).readAsStringSync())
            as Map<String, dynamic>,
      );
      expect(signers, <String>[key]);
      expect(
        pinnedSignatureProblems(signers: signers, pinned: <String>[key]),
        isEmpty,
      );
      expect(
        pinnedSignatureProblems(signers: signers, pinned: maintainers),
        hasLength(1),
      );
      expect(
        pinnedSignatureProblems(signers: signers, pinned: const <String>[]),
        hasLength(1),
      );
      Future<bool> confirms({
        String version = '1.12.0',
        String name = 'Zen.apk',
        String? sha,
        List<String>? maintainers,
      }) => signed.confirms(
        version: version,
        name: name,
        sha256Hex: sha ?? apk,
        maintainers: maintainers ?? <String>[key],
      );
      expect(await confirms(), isTrue);
      expect(await confirms(sha: apk.toUpperCase()), isTrue);
      expect(await confirms(version: '1.13.0'), isFalse);
      expect(await confirms(name: 'Zen-Windows.zip'), isFalse);
      expect(await confirms(sha: 'ee' * 32), isFalse);
      expect(await confirms(maintainers: <String>[]), isFalse);
      final LedgerKeyPair other = await LedgerKeyPair.generate();
      expect(await confirms(maintainers: <String>[other.hybridId]), isFalse);
      // The key is a hybrid id: both halves pinned. Its Ed25519 half alone,
      // or paired with another ML-DSA key, is not the maintainer.
      expect(key, hasLength(89));
      expect(
        await confirms(maintainers: <String>[key.substring(0, 44)]),
        isFalse,
      );
      expect(
        signed.signatures[key],
        hasLength(kKeyedHybridSignatureChars),
        reason: 'SHA256SUMS.sig carries a keyed hybrid signature',
      );
      expect(
        () => tool.createSignedSums(version: 'v1.12.0', sumsText: ''),
        throwsFormatException,
      );
      expect(
        () => tool.createSignedSums(version: '1.12.0', sumsText: 'nothing'),
        throwsFormatException,
      );
    });

    test('options with "=" in their value are not taken for files', () {
      expect(
        tool.fileArgs(<String>[
          '--notes',
          'x=y',
          '--no-official',
          'android=a.apk',
        ]),
        <String, String>{'android': 'a.apk'},
      );
      expect(
        tool.positionalArgs(<String>['--write', 'K1', '--alias', 'zen', 'K2']),
        <String>['K1', 'K2'],
      );
    });

    test('the certificate fingerprint is read and pinned', () async {
      final List<int> certificate = utf8.encode('certyfikat wydania');
      final String sha = crypto.sha256.convert(certificate).toString();
      final File apk = File(at('zen.apk'))
        ..writeAsBytesSync(
          _apk(<int, List<int>>{_v2: certificate, _v3: certificate}),
        );
      expect(await tool.apkFingerprints(apk), <String>[sha]);

      final File mixed = File(at('mixed.apk'))
        ..writeAsBytesSync(
          _apk(<int, List<int>>{_v2: utf8.encode('inny'), _v3: certificate}),
        );
      await expectLater(tool.apkFingerprints(mixed), throwsFormatException);
      await expectLater(
        tool.apkFingerprints(File(at('missing.apk'))),
        throwsFormatException,
      );

      // The APKs of every ABI: one certificate, or the release stops.
      final File arm32 = File(at('Zen-armeabi-v7a.apk'))
        ..writeAsBytesSync(
          _apk(<int, List<int>>{_v2: certificate, _v3: certificate}),
        );
      final File other = File(at('Zen-x86_64.apk'))
        ..writeAsBytesSync(
          _apk(<int, List<int>>{
            _v2: utf8.encode('inny'),
            _v3: utf8.encode('inny'),
          }),
        );
      expect(await tool.sameApkFingerprints(<File>[apk, arm32]), <String>[sha]);
      await expectLater(
        tool.sameApkFingerprints(<File>[apk, arm32, other]),
        throwsFormatException,
      );
      await expectLater(
        tool.sameApkFingerprints(const <File>[]),
        throwsFormatException,
      );

      final String source = File(tool.kApkSignaturePath).readAsStringSync();
      final String pinned = tool.replaceConstList(
        source,
        'kOfficialApkCertificatesSha256',
        <String>[sha],
      );
      expect(
        pinned,
        contains(
          "const List<String> kOfficialApkCertificatesSha256 = <String>[\n"
          "  '$sha',\n];",
        ),
      );
      // Running it again replaces the list instead of adding to it.
      final String again = tool.replaceConstList(
        pinned,
        'kOfficialApkCertificatesSha256',
        <String>[sha, 'ab' * 32],
      );
      expect(RegExp(sha).allMatches(again), hasLength(1));
      expect(again, contains('ab' * 32));
      expect(
        apkSignatureVerdict(
          schemes: <List<String>>[
            <String>[sha],
          ],
          reference: <String>[sha],
        ),
        ApkSignatureVerdict.matches,
      );

      final String release = File(tool.kReleasePath).readAsStringSync();
      expect(
        tool.replaceConstList(release, 'kReleaseMaintainers', <String>[
          'k1',
          'k2',
          'k3',
        ]),
        contains("  'k3',\n];"),
      );
      expect(
        () => tool.replaceConstList('nic', 'kReleaseMaintainers', <String>[]),
        throwsFormatException,
      );
      // A commented-out declaration stays as it is; the real one changes.
      expect(
        tool.replaceConstList(
          "// const List<String> kReleaseMaintainers = <String>['old'];\n"
              'const List<String> kReleaseMaintainers = <String>[\n'
              "  // 'off',\n"
              '];\n',
          'kReleaseMaintainers',
          <String>['k1'],
        ),
        "// const List<String> kReleaseMaintainers = <String>['old'];\n"
        "const List<String> kReleaseMaintainers = <String>[\n  'k1',\n];\n",
      );
    });
  });

  testWidgets('the updates screen warns about a swapped donation link', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 5400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final UpdateBook book = UpdateBook(
      currentBuild: kAppBuild,
      maintainers: maintainers,
    );
    await tester.runAsync(() async {
      final SignedRelease signed = SignedRelease.fromJson(
        await release(
          build: kAppBuild,
          official: tool.officialInfo(donation: _otherDonation),
          mirrors: <String>['https://codeberg.org/zen/Zen'],
        ),
      )!;
      expect(await book.offerOfficial(signed), isTrue);
      expect(
        await book.offerCanary(
          SignedCanary.fromJson(
            await signedJson(
              tool.createCanary(
                text: 'Bez nacisków.',
                validFor: const Duration(days: 1),
                at: 0,
              ),
            ),
          )!,
        ),
        isTrue,
      );
    });
    final UpdateService service = UpdateService(
      host: _Host(<String, _Host>{}, 'me', <String>[]),
      book: book,
      platform: 'android',
      now: () => 10 * _day,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateServiceProvider.overrideWithValue(service)],
        child: MaterialApp(theme: ZenTheme.dark(), home: const UpdatesScreen()),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('updates-official-differs')), findsOneWidget);
    expect(find.textContaining(_otherDonation), findsOneWidget);
    expect(find.byKey(const Key('updates-canary-expired')), findsOneWidget);
    expect(find.byKey(const Key('updates-mirrors')), findsOneWidget);
  });
}
