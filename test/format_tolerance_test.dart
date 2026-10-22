import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/runtime/public_peers.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/version_gate.dart';

final class _Plain implements BinaryCompressor {
  const _Plain();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// What every reader does with data a newer build wrote: keeps it as it
/// is, says so, and reads what it can.
void main() {
  late Directory dir;
  late FileBinaryStore files;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zen-tolerance-');
    files = FileBinaryStore(
      dir,
      codec: BinaryCodec(compressor: const _Plain()),
    );
  });

  tearDown(() async {
    ZenFormatGuard.instance.reset();
    await dir.delete(recursive: true);
  });

  group('format versions', () {
    test('older and current are read, newer is newer, nothing is invalid', () {
      expect(formatAgeOf(1, current: 1), FormatAge.readable);
      expect(formatAgeOf(1, current: 3), FormatAge.readable);
      expect(formatAgeOf(2, current: 3, oldest: 3), FormatAge.invalid);
      expect(formatAgeOf(4, current: 3), FormatAge.newer);
      expect(formatAgeOf('1', current: 1), FormatAge.invalid);
      expect(
        jsonFormatAge(<String, Object>{'v': 2}, current: 1),
        FormatAge.newer,
      );
      expect(jsonFormatAge(<Object>[], current: 1), FormatAge.invalid);
    });

    test('unknown fields are carried along, known ones win', () {
      final Map<String, Object?> carried = unknownFields(
        <String, Object?>{'v': 2, 'a': 1, 'later': true},
        <String, Object?>{'a': 5},
      );
      expect(carried, <String, Object?>{'later': true});
      expect(
        withCarriedFields(<String, Object?>{'a': 5}, carried),
        <String, Object?>{'later': true, 'a': 5},
      );
    });

    test('an enum index from a newer build falls back', () {
      expect(enumAt(FormatAge.values, 1, FormatAge.invalid), FormatAge.newer);
      expect(enumAt(FormatAge.values, 9, FormatAge.invalid), FormatAge.invalid);
    });
  });

  group('the store', () {
    test('a held key is neither written over nor deleted', () async {
      await files.write('x/doc', _json(<String, Object>{'v': 9}));
      expect(
        files.heldAsNewer(
          'x/doc',
          jsonDecode(utf8.decode((await files.read('x/doc'))!)),
          current: 1,
        ),
        isTrue,
      );
      await files.write('x/doc', _json(<String, Object>{'v': 1}));
      await files.delete('x/doc');
      expect(
        jsonDecode(utf8.decode((await files.read('x/doc'))!)),
        <String, Object>{'v': 9},
      );
      expect(ZenFormatGuard.instance.newerAreas, <String>{'x'});
    });

    test(
      'an envelope from a newer build is held, not read as damage',
      () async {
        final File file = await files.write('y/doc', _json(<String, Object>{}));
        final Uint8List bytes = await file.readAsBytes();
        bytes[4] = BinaryCodec.currentVersion + 1;
        await file.writeAsBytes(bytes);
        await expectLater(
          files.read('y/doc'),
          throwsA(isA<NewerFormatException>()),
        );
        expect(files.isHeldNewer('y/doc'), isTrue);
        await files.write('y/doc', _json(<String, Object>{'v': 1}));
        expect(await file.readAsBytes(), bytes);
      },
    );

    test(
      'settings keep fields a newer build added; a newer file stays',
      () async {
        await files.write(
          'settings/app',
          _json(<String, Object>{'v': 1, 'themeMode': 'dark', 'later': 42}),
        );
        final FileAppSettingsStore store = FileAppSettingsStore(store: files);
        final AppSettings? loaded = await store.load();
        expect(loaded?.themeMode, AppThemeMode.dark);
        await store.save(loaded!.copyWith(themeMode: AppThemeMode.light));
        final Map<String, dynamic> saved =
            jsonDecode(utf8.decode((await files.read('settings/app'))!))
                as Map<String, dynamic>;
        expect(saved['later'], 42);
        expect(saved['themeMode'], 'light');

        await files.write('settings/app', _json(<String, Object>{'v': 2}));
        final FileAppSettingsStore other = FileAppSettingsStore(store: files);
        expect(await other.load(), isNull);
        await other.save(const AppSettings());
        expect(
          jsonDecode(utf8.decode((await files.read('settings/app'))!)),
          <String, Object>{'v': 2},
        );
      },
    );

    test('the friend list of a newer build is kept, not set aside', () async {
      final Uint8List newer = Uint8List.fromList(<int>[255, 99, 1, 2, 3]);
      await files.write('social/hub', newer);
      await expectLater(
        FileSocialSnapshotStore(store: files).load(),
        throwsA(isA<NewerFormatException>()),
      );
      expect(await files.read('social/hub.unreadable'), isNull);
      expect(await files.read('social/hub'), newer);
      expect(files.isHeldNewer('social/hub'), isTrue);
    });

    test('a newer queue is read as empty and kept', () async {
      final Uint8List newer = Uint8List.fromList(<int>[0x5A, 0x53, 0x51, 99]);
      await files.write('signals/pending', newer);
      final FileSignalQueueStore store = FileSignalQueueStore(store: files);
      expect(await store.load(), isEmpty);
      await store.save(const <QueuedSignal>[]);
      expect(await files.read('signals/pending'), newer);
    });
  });

  group('printed and shared codes', () {
    test('a door code with more fields still opens; one that must not '
        'says "update"', () {
      String code(Map<String, Object?> json) =>
          '${FlatDoorCode.qrPrefix}'
          '${base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '')}';
      final Map<String, Object?> base = <String, Object?>{
        'v': 4,
        'k': base64Url.encode(List<int>.filled(32, 7)),
        'd': 'abc',
        'a': PeerShareCodec.normalizeAddress('200::d1'),
        'n': 'Nowakowie',
        'later': <String, Object?>{'x': 1},
      };
      expect(FlatDoorCode.parse(code(base))?.name, 'Nowakowie');
      final String strict = code(<String, Object?>{...base, 'mv': 4});
      expect(FlatDoorCode.parse(strict), isNull);
      expect(FlatDoorCode.isNewer(strict), isTrue);
      expect(FlatDoorCode.isNewer(code(base)), isFalse);
    });

    test('the project pages are named in one place', () {
      expect(kZenPageBases, contains(kZenPagesBase));
      expect(PeerShareCodec.invitePageUrl, kZenPagesBase);
      expect(
        isZenPage(Uri.parse('${kZenGithubPagesBase}m#abc'), path: 'm'),
        isTrue,
      );
      expect(
        isZenPage(Uri.parse('https://example.com/Zen/m'), path: 'm'),
        isFalse,
      );
      expect(isZenPage(Uri.parse(kZenRepositoryUrl)), isTrue);
    });
  });

  group('too old to talk to', () {
    test('a friend says the oldest Zen it still talks to', () {
      final PeerVersion? v = PeerVersion.fromPayload(<String, dynamic>{
        'ver': '9.0.0',
        'minv': '8.0.0',
      });
      expect(v?.minVersion, '8.0.0');
      expect(v!.refuses('1.12.0'), isTrue);
      expect(v.refuses('8.0.0'), isFalse);
      // Never above its own version.
      expect(
        PeerVersion.fromPayload(<String, dynamic>{
          'ver': '1.0.0',
          'minv': '2.0.0',
        })?.minVersion,
        isNull,
      );
      expect(versionHello()['minv'], kMinPeerVersion);
      expect(compareAppVersions(kMinPeerVersion, kAppVersion), lessThan(1));
    });

    test('an update is required by friends or by the newest release', () {
      expect(
        updateRequiredFor(
          friends: <PeerVersion>[
            const PeerVersion(version: '9.0.0', minVersion: '8.0.0'),
          ],
          ours: '1.12.0',
        )?.minimum,
        '8.0.0',
      );
      final UpdateRequired? byRelease = updateRequiredFor(
        friends: const <PeerVersion>[],
        releaseMinimum: '1.13.0',
        ours: '1.12.0',
      );
      expect(byRelease?.byRelease, isTrue);
      expect(
        updateRequiredFor(
          friends: const <PeerVersion>[PeerVersion(version: '1.12.0')],
          releaseMinimum: '1.12.0',
          ours: '1.12.0',
        ),
        isNull,
      );
    });

    test('the release notes may name the oldest supported Zen', () {
      final GithubRelease? r = GithubRelease.fromJson(<String, Object?>{
        'tag_name': 'v1.14.0',
        'body': 'Co nowego\n\nzen-min: 1.13.0\n',
        'assets': <Object?>[],
      });
      expect(r?.minVersion, '1.13.0');
      expect(
        GithubRelease.fromJson(<String, Object?>{
          'tag_name': 'v1.14.0',
          'body': 'zen-min: 2.0.0',
        })?.minVersion,
        isNull,
        reason: 'not above the release itself',
      );
    });
  });

  test('a release manifest with a file this build does not take still '
      'offers its own platform, signed as received', () {
    final Map<String, Object?> android = <String, Object?>{
      'p': 'android',
      'name': 'Zen.apk',
      'size': 1000,
      'blob': 'a' * 64,
      'sha256': 'b' * 64,
    };
    final Map<String, Object?> json = <String, Object?>{
      't': 'zen_release',
      'app': kReleaseApp,
      'version': '1.13.0',
      'build': 13,
      'at': 1,
      'notes': '',
      'files': <Object?>[
        android,
        <String, Object?>{...android, 'name': 'Zen-second.apk'},
        <String, Object?>{'p': 'visionos', 'name': 'Zen.weird', 'size': -1},
        for (int i = 0; i < 12; i++)
          <String, Object?>{...android, 'p': 'p$i', 'name': 'f$i.zip'},
      ],
      'min': '1.12.0',
    };
    final ReleaseManifest? m = ReleaseManifest.fromJson(json);
    expect(m?.fileFor('android')?.name, 'Zen.apk');
    expect(m!.minVersion, '1.12.0');
    expect(jsonEncode(m.toJson()['files']), jsonEncode(json['files']));
  });

  test('a kept public peer list takes new built-in peers and drops dead '
      'ones the user never touched', () {
    const PublicPeer a = PublicPeer(uri: 'tls://a.example:1');
    const PublicPeer b = PublicPeer(uri: 'tls://b.example:1');
    const PublicPeer c = PublicPeer(uri: 'tls://c.example:1');
    const PublicPeer mine = PublicPeer(uri: 'tls://mine.example:1');
    // Saved: the user switched b off and added their own.
    final PublicPeerList kept = PublicPeerList.fromJson(
      jsonDecode(
        jsonEncode(
          const PublicPeerList(
            custom: true,
            peers: <PublicPeer>[
              a,
              PublicPeer(uri: 'tls://b.example:1', enabled: false),
              mine,
            ],
            base: <PublicPeer>[a, b],
          ).toJson(),
        ),
      ),
    )!;
    // The update dropped a and b, and brought c.
    final PublicPeerList now = kept.mergedWith(const <PublicPeer>[c]);
    expect(now.peers.map((PublicPeer p) => p.uri), <String>[
      'tls://b.example:1',
      'tls://mine.example:1',
      'tls://c.example:1',
    ]);
  });

  test('a pyramid on rules this build does not know stops where they '
      'start', () async {
    final LedgerKeyPair power = await LedgerKeyPair.generate();
    final LedgerKeyPair s = await LedgerKeyPair.generate();
    final LedgerKeyPair a = await LedgerKeyPair.generate();
    final LedgerKeyPair b = await LedgerKeyPair.generate();
    Future<PyramidRecord> rec(
      String type,
      String py,
      int at,
      List<LedgerKeyPair> signers,
      Map<String, dynamic> fields,
    ) async {
      PyramidRecord r = PyramidRecord(
        body: <String, dynamic>{
          't': type,
          'py': py,
          'at': at,
          'by': <String>[for (final LedgerKeyPair k in signers) k.id],
          ...fields,
        },
      );
      for (final LedgerKeyPair k in signers) {
        r = await r.signedBy(k);
      }
      return r;
    }

    Map<String, dynamic> member(LedgerKeyPair k, String name) =>
        <String, dynamic>{
          'k': k.id,
          'pq': k.pqId,
          'n': name,
          'nat': 'PL',
          'yr': 1950,
          'dc': 'x',
        };

    final PyramidRecord g = await rec(
      PyrT.genesis,
      '',
      1,
      <LedgerKeyPair>[power],
      <String, dynamic>{'name': 'Test', 'pk': power.id},
    );
    final String py = g.id;
    Future<PyramidRecord> admit(
      int at,
      LedgerKeyPair who,
      String slot, {
      Map<String, dynamic> extra = const <String, dynamic>{},
    }) => rec(
      PyrT.admit,
      py,
      at,
      <LedgerKeyPair>[s, who],
      <String, dynamic>{
        'sp': s.id,
        'head': s.id,
        'slot': slot,
        'm': member(who, 'X$slot'),
        ...extra,
      },
    );
    final List<PyramidRecord> all = <PyramidRecord>[
      g,
      await rec(
        PyrT.found,
        py,
        1,
        <LedgerKeyPair>[power, s],
        <String, dynamic>{'m': member(s, 'S')},
      ),
      await admit(2, a, '0'),
    ];
    final PyramidState before = PyramidState.fold(py, all, now: 100);
    expect(before.rulesTooNew, isNull);
    expect(before.pathOf(a.id), '0');

    final PyramidRecord newer = await admit(
      3,
      b,
      '1',
      extra: <String, dynamic>{'rv': kPyramidRulesVersion + 1},
    );
    final PyramidState after = PyramidState.fold(py, <PyramidRecord>[
      ...all,
      newer,
    ], now: 100);
    expect(after.rulesTooNew, kPyramidRulesVersion + 1);
    expect(after.pathOf(a.id), '0');
    expect(after.pathOf(b.id), isNull);
    expect(after.rejected[newer.id], isNotNull);
  });
}
