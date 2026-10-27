import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/update/background_update_check.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/update_notice.dart';
import 'package:zen/src/features/update/whats_new.dart';

import '../tool/release_contract.dart' as contract;

const String _version = '1.12.0';

final Map<String, List<String>> _lines = <String, List<String>>{
  'en': <String>['Messages reach you while Zen is closed.', 'Presence.'],
  'pl': <String>['Wiadomości docierają przy zamkniętym Zen.', 'Obecność.'],
};

/// A release of [_version] on GitHub with [note] as its whats-new.json,
/// listed in its SHA256SUMS and signed by [key] in SHA256SUMS.sig (with
/// [signedNote] in place of the note, when given). [served] counts what
/// was fetched.
final class _Release {
  _Release({
    required this.key,
    String? note,
    this.signedNote,
    this.withNote = true,
  }) : note = note ?? contract.whatsNewJson(_version, _lines);

  final LedgerKeyPair key;
  final String note;
  final String? signedNote;
  final bool withNote;
  final List<Uri> served = <Uri>[];
  late final String sums =
      '${sha256Hex(utf8.encode(signedNote ?? note))}  $kWhatsNewAssetName\n'
      '${'0' * 64}  Zen-arm64-v8a.apk\n';
  String? _signed;

  Map<String, Object?> json() => <String, Object?>{
    'tag_name': 'v$_version',
    'draft': false,
    'prerelease': false,
    'assets': <Object?>[
      <String, Object?>{'name': 'Zen-arm64-v8a.apk', 'size': 5},
      <String, Object?>{'name': 'SHA256SUMS', 'size': sums.length},
      <String, Object?>{'name': kSignedSumsAssetName, 'size': 100},
      if (withNote)
        <String, Object?>{'name': kWhatsNewAssetName, 'size': note.length},
    ],
  };

  Future<String> text(Uri uri) async {
    served.add(uri);
    expect(uri.host, 'github.com');
    final String name = uri.pathSegments.last;
    if (name == kWhatsNewAssetName) {
      return note;
    }
    if (name == 'SHA256SUMS') {
      return sums;
    }
    if (name == kSignedSumsAssetName) {
      return _signed ??= jsonEncode(
        (await SignedSums(
          version: _version,
          files: contract.parseSums(sums),
          signatures: const <String, String>{},
        ).signedBy(key)).toJson(),
      );
    }
    throw HttpException('HTTP 404', uri: uri);
  }
}

final class _Notices implements RuntimeSystemNotificationService {
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) async {}

  @override
  Future<bool> show(RuntimeSystemNotification notification) async {
    shown.add(notification);
    return true;
  }

  @override
  Future<void> dismiss(String id) async {}

  @override
  Future<void> dismissSlot(String slotKey) async {}

  @override
  Future<void> clear() async {}
}

final class _Installer implements GithubUpdateInstaller {
  @override
  String? get assetName => 'Zen-arm64-v8a.apk';

  @override
  Future<Directory> workDirectory() async => Directory.systemTemp;

  @override
  Future<GithubInstallOutcome> install(
    File file,
    GithubRelease release,
  ) async => const GithubInstallOutcome('installed');
}

void main() {
  late LedgerKeyPair key;
  setUpAll(() async {
    key = await LedgerKeyPair.generate();
  });

  group('the note', () {
    test('the release tool writes exactly what the app reads', () {
      expect(contract.kWhatsNewAsset, kWhatsNewAssetName);
      expect(contract.kMaxWhatsNewLines, kMaxWhatsNewLines);
      expect(contract.kMaxWhatsNewLineLength, kMaxWhatsNewLineLength);
      expect(contract.kWhatsNewFallbackLanguage, kWhatsNewFallbackLanguage);
      final WhatsNew note = WhatsNew.decode(
        contract.whatsNewJson(_version, _lines),
      )!;
      expect(note.version, _version);
      expect(note.lines, _lines);
      expect(
        contract.whatsNewProblems(
          contract.whatsNewJson(_version, _lines),
          version: _version,
        ),
        isEmpty,
      );
    });

    test('the app language, else English', () {
      final WhatsNew note = WhatsNew(version: _version, lines: _lines);
      expect(note.linesFor('pl'), _lines['pl']);
      expect(note.linesFor('de'), _lines['en']);
    });

    test('only plain lines, at most three, always with English', () {
      for (final String line in <String>[
        'See https://example.org',
        'Visit www.example.org',
        'Open zen://invite',
        '**Bold** news',
        'A <b>tag</b>',
        'A [link](x)',
        'Two\nrows',
        ' padded',
        '',
        'x' * (kMaxWhatsNewLineLength + 1),
      ]) {
        expect(isPlainWhatsNewLine(line), isFalse, reason: line);
        expect(contract.whatsNewLineProblem(line), isNotNull, reason: line);
        expect(
          WhatsNew.decode(
            contract.whatsNewJson(_version, <String, List<String>>{
              'en': <String>[line],
            }),
          ),
          isNull,
          reason: line,
        );
      }
      for (final String line in <String>[
        "Friends' phones keep your messages: like mailboxes.",
        'Wiadomości docierają — nawet przy zamkniętym Zen (100%).',
        'x' * kMaxWhatsNewLineLength,
      ]) {
        expect(isPlainWhatsNewLine(line), isTrue, reason: line);
        expect(contract.whatsNewLineProblem(line), isNull, reason: line);
      }
      expect(
        WhatsNew.decode(
          contract.whatsNewJson(_version, <String, List<String>>{
            'en': <String>['a', 'b', 'c', 'd'],
          }),
        ),
        isNull,
      );
      expect(
        WhatsNew.decode(
          contract.whatsNewJson(_version, <String, List<String>>{
            'pl': <String>['tylko po polsku'],
          }),
        ),
        isNull,
      );
    });
  });

  group('fetched from the release', () {
    GithubRelease release(_Release r) => GithubRelease.fromJson(r.json())!;

    test('taken when SHA256SUMS.sig signs it, without the API', () async {
      final _Release r = _Release(key: key);
      final WhatsNew? note = await fetchWhatsNew(
        release(r),
        fetchText: r.text,
        maintainers: <String>[key.hybridId],
      );
      expect(note?.lines, _lines);
      expect(r.served.map((Uri u) => u.pathSegments.last), <String>[
        kWhatsNewAssetName,
        kSignedSumsAssetName,
      ]);
      expect(
        r.served.every((Uri u) => u.host == 'github.com'),
        isTrue,
        reason: 'never api.github.com: no rate limit spent',
      );
    });

    test('refused when changed, signed by another key or of another '
        'version', () async {
      final LedgerKeyPair other = await LedgerKeyPair.generate();
      final _Release changed = _Release(
        key: key,
        signedNote: contract.whatsNewJson(_version, <String, List<String>>{
          'en': <String>['Something else.'],
        }),
      );
      await expectLater(
        fetchWhatsNew(
          release(changed),
          fetchText: changed.text,
          maintainers: <String>[key.hybridId],
        ),
        throwsFormatException,
      );
      final _Release foreign = _Release(key: other);
      await expectLater(
        fetchWhatsNew(
          release(foreign),
          fetchText: foreign.text,
          maintainers: <String>[key.hybridId],
        ),
        throwsFormatException,
      );
      final _Release older = _Release(
        key: key,
        note: contract.whatsNewJson('1.11.0', _lines),
      );
      await expectLater(
        fetchWhatsNew(
          release(older),
          fetchText: older.text,
          maintainers: <String>[key.hybridId],
        ),
        throwsFormatException,
      );
    });

    test('no key pinned: SHA256SUMS must list it; no file: no note', () async {
      final _Release r = _Release(key: key);
      expect(
        (await fetchWhatsNew(
          release(r),
          fetchText: r.text,
          maintainers: const <String>[],
        ))?.lines,
        _lines,
      );
      expect(r.served.last.pathSegments.last, 'SHA256SUMS');
      final _Release none = _Release(key: key, withNote: false);
      expect(
        await fetchWhatsNew(
          release(none),
          fetchText: none.text,
          maintainers: <String>[key.hybridId],
        ),
        isNull,
      );
      expect(none.served, isEmpty);
    });
  });

  group('shown with the notice', () {
    test('the notification carries the lines below the version', () {
      final RuntimeSystemNotification n = updateAvailableNotification(
        _version,
        createdAtMillis: 1,
        whatsNew: _lines['pl']!,
      );
      expect(n.body.split('\n'), <String>[
        'Wersja 1.12.0 — warto zaktualizować',
        '• Wiadomości docierają przy zamkniętym Zen.',
        '• Obecność.',
      ]);
      expect(
        updateAvailableNotification(_version, createdAtMillis: 1).body,
        isNot(contains('\n')),
      );
    });

    test('by the app: in the banner and the notification; a note that '
        'does not hold up leaves only the version', () async {
      final _Release r = _Release(key: key);
      final _Notices notices = _Notices();
      final GithubUpdateService s = GithubUpdateService(
        installer: _Installer(),
        fetchJson: (Uri uri) async => r.json(),
        fetchSums: r.text,
        noticeStore: MemoryUpdateNoticeStore(),
        notifications: notices,
        language: () => 'de',
        currentVersion: '1.11.0',
        releaseKeys: <String>[key.hybridId],
      );
      addTearDown(s.dispose);
      await s.check();
      expect(s.whatsNewLines, _lines['en']);
      expect(notices.shown.single.body, contains(_lines['en']!.first));
      await s.check();
      expect(
        r.served.where((Uri u) => u.pathSegments.last == kWhatsNewAssetName),
        hasLength(1),
        reason: 'fetched once per version',
      );

      final LedgerKeyPair other = await LedgerKeyPair.generate();
      final _Release forged = _Release(key: other);
      final _Notices forgedNotices = _Notices();
      final GithubUpdateService f = GithubUpdateService(
        installer: _Installer(),
        fetchJson: (Uri uri) async => forged.json(),
        fetchSums: forged.text,
        noticeStore: MemoryUpdateNoticeStore(),
        notifications: forgedNotices,
        currentVersion: '1.11.0',
        releaseKeys: <String>[key.hybridId],
      );
      addTearDown(f.dispose);
      await f.check();
      expect(f.newer?.version, _version);
      expect(f.whatsNewLines, isEmpty);
      expect(
        forgedNotices.shown.single.body,
        'Wersja 1.12.0 — warto zaktualizować',
      );
    });

    test('by the Android background service, in the app\'s language; '
        'nothing fetched for a version already announced', () async {
      final _Release r = _Release(key: key);
      final _Notices notices = _Notices();
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      BackgroundUpdateCheck check() => BackgroundUpdateCheck(
        notices: () async => notices,
        store: store,
        fetchJson: (Uri uri) async => r.json(),
        fetchText: r.text,
        now: () => DateTime(2026, 10, 27).millisecondsSinceEpoch,
        language: () => 'pl',
        currentVersion: '1.11.0',
        releaseKeys: <String>[key.hybridId],
      );
      await check().checkIfDue();
      expect(notices.shown.single.body, contains(_lines['pl']!.first));
      final int fetched = r.served.length;

      store.state = store.state.copyWith(checkedAtMillis: 0);
      await check().checkIfDue();
      expect(notices.shown, hasLength(1));
      expect(r.served, hasLength(fetched));
    });
  });
}
