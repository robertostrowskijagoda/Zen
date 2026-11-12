import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/update/background_update_check.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/update_notice.dart';

// What the update notice remembers (the version announced, the version
// whose banner was closed) holds back the notice of every version up to
// it. It is therefore taken only from a version whose SHA256SUMS.sig the
// pinned key signed, never from GitHub's unsigned word on the newest
// release, and a remembered version whose signed sums are gone stops
// counting: a tag set by mistake (v1.17.0 for v1.16.6) or a forged answer
// naming 1.99.0 must not silence the notice of the real 1.16.6.

final class _Notices implements RuntimeSystemNotificationService {
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  List<String> get versions => <String>[
    for (final RuntimeSystemNotification n in shown)
      n.id.substring(kUpdateNoticeSlot.length + 1),
  ];

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
  UpdateTarget get target => UpdateTarget.android;

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

/// GitHub as the app sees it: [latest] is the version its unsigned answer
/// names; [sums] holds the `SHA256SUMS.sig` of each version that has one
/// (missing: 404); [offline] versions cannot be fetched at all.
final class _Github {
  String latest = '1.16.6';
  final Map<String, String> sums = <String, String>{};
  final Set<String> offline = <String>{};
  final List<String> sumsAsked = <String>[];

  Future<Object?> json(Uri uri) async => <String, Object?>{
    'tag_name': 'v$latest',
    'draft': false,
    'prerelease': false,
    'assets': <Object?>[
      <String, Object?>{'name': 'Zen-arm64-v8a.apk', 'size': 5},
      <String, Object?>{'name': kSignedSumsAssetName, 'size': 400},
    ],
  };

  Future<String> text(Uri uri) async {
    final String tag = uri.pathSegments[uri.pathSegments.length - 2];
    final String version = tag.substring(1);
    sumsAsked.add(version);
    if (offline.contains(version)) {
      throw const SocketException('offline');
    }
    final String? text = uri.pathSegments.last == kSignedSumsAssetName
        ? sums[version]
        : null;
    if (text == null) {
      throw HttpException('HTTP 404', uri: uri);
    }
    return text;
  }
}

Future<String> _signedSums(LedgerKeyPair key, String version) async {
  final SignedSums signed = await SignedSums(
    version: version,
    files: <String, String>{'Zen-arm64-v8a.apk': 'ab' * 32},
    signatures: const <String, String>{},
  ).signedBy(key);
  return jsonEncode(signed.toJson());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LedgerKeyPair key;
  late LedgerKeyPair stranger;

  setUpAll(() async {
    key = await LedgerKeyPair.generate();
    stranger = await LedgerKeyPair.generate();
  });

  GithubUpdateService app(
    _Github github,
    UpdateNoticeStore store,
    _Notices notices,
  ) {
    final GithubUpdateService s = GithubUpdateService(
      installer: _Installer(),
      fetchJson: github.json,
      fetchSums: github.text,
      noticeStore: store,
      notifications: notices,
      currentVersion: '1.16.5',
      releaseKeys: <String>[key.hybridId],
    );
    addTearDown(s.dispose);
    return s;
  }

  BackgroundUpdateCheck background(
    _Github github,
    UpdateNoticeStore store,
    _Notices notices,
    int Function() now,
  ) => BackgroundUpdateCheck(
    notices: () async => notices,
    store: store,
    fetchJson: github.json,
    fetchText: github.text,
    now: now,
    currentVersion: '1.16.5',
    releaseKeys: <String>[key.hybridId],
  );

  group('in the app', () {
    test('a version nobody signed is shown in the banner but neither '
        'announced nor kept, and the real one below it is announced', () async {
      final _Github github = _Github()..latest = '1.17.0';
      github.sums['1.16.6'] = await _signedSums(key, '1.16.6');
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      final GithubUpdateService s = app(github, store, notices);

      await s.check();
      expect(s.newer?.version, '1.17.0');
      expect(s.showNewerBanner, isTrue);
      expect(notices.shown, isEmpty);
      expect(store.state.notifiedVersion, isNull);

      // The tag goes; the real release is the newest one.
      github.latest = '1.16.6';
      final GithubUpdateService restarted = app(github, store, notices);
      await restarted.check();
      expect(notices.versions, <String>['1.16.6']);
      expect(store.state.notifiedVersion, '1.16.6');
      await restarted.check();
      expect(notices.versions, <String>['1.16.6'], reason: 'once');
    });

    test('a version signed by a key this build does not trust, or whose '
        'signed sums name another version, is not taken', () async {
      final _Github github = _Github()..latest = '1.99.0';
      github.sums['1.99.0'] = await _signedSums(stranger, '1.99.0');
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      await app(github, store, notices).check();
      github.sums['1.99.0'] = await _signedSums(key, '1.16.6');
      await app(github, store, notices).check();
      expect(notices.shown, isEmpty);
      expect(store.state.notifiedVersion, isNull);
    });

    test('a signed release that was withdrawn stops holding back the one '
        'below it', () async {
      final _Github github = _Github()..latest = '1.17.0';
      github.sums['1.17.0'] = await _signedSums(key, '1.17.0');
      github.sums['1.16.6'] = await _signedSums(key, '1.16.6');
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      await app(github, store, notices).check();
      expect(store.state.notifiedVersion, '1.17.0');

      // Deleted: its files with it.
      github
        ..latest = '1.16.6'
        ..sums.remove('1.17.0');
      await app(github, store, notices).check();
      expect(notices.versions, <String>['1.17.0', '1.16.6']);
      expect(store.state.notifiedVersion, '1.16.6');
    });

    test('a remembered version that cannot be checked now is kept', () async {
      final _Github github = _Github()
        ..latest = '1.16.6'
        ..offline.add('1.17.0');
      github.sums['1.16.6'] = await _signedSums(key, '1.16.6');
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        const UpdateNoticeState(notifiedVersion: '1.17.0'),
      );
      final _Notices notices = _Notices();
      await app(github, store, notices).check();
      expect(notices.shown, isEmpty);
      expect(store.state.notifiedVersion, '1.17.0');
      // Asked about only while it is newer than GitHub's answer.
      github.latest = '1.17.0';
      github.sumsAsked.clear();
      github.offline.clear();
      github.sums['1.17.0'] = await _signedSums(key, '1.17.0');
      await app(github, store, notices).check();
      expect(github.sumsAsked, isNot(contains('1.16.6')));
      expect(notices.shown, isEmpty);
    });

    test('data kept by an older Zen: an announced 1.99.0 that is not '
        'published is forgotten at the next check', () async {
      final _Github github = _Github()..latest = '1.16.6';
      github.sums['1.16.6'] = await _signedSums(key, '1.16.6');
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState.fromJson(<String, Object?>{
          'notified': '1.99.0',
          'dismissed': '1.99.0',
        }),
      );
      expect(updateNoticeDue(store.state, '1.16.6'), isFalse);
      final _Notices notices = _Notices();
      final GithubUpdateService s = app(github, store, notices);
      await s.check();
      expect(notices.versions, <String>['1.16.6']);
      expect(store.state.dismissedVersion, isNull);
      expect(s.showNewerBanner, isTrue);
    });

    test('closing the banner of a version nobody signed hides it in this run '
        'only, and hides no other version', () async {
      final _Github github = _Github()..latest = '1.17.0';
      github.sums['1.16.6'] = await _signedSums(key, '1.16.6');
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      final GithubUpdateService s = app(github, store, notices);
      await s.check();
      s.dismissNewer();
      expect(s.showNewerBanner, isFalse);
      await pumpEventQueue();
      expect(store.state.dismissedVersion, isNull);

      github.latest = '1.16.6';
      final GithubUpdateService restarted = app(github, store, notices);
      await restarted.check();
      expect(restarted.showNewerBanner, isTrue);

      // A signed one stays closed, also after a restart.
      restarted.dismissNewer();
      await pumpEventQueue();
      expect(store.state.dismissedVersion, '1.16.6');
      final GithubUpdateService again = app(github, store, notices);
      await again.check();
      expect(again.showNewerBanner, isFalse);
    });
  });

  group('in the Android background service', () {
    test('announces and keeps only a signed version; a withdrawn one is '
        'forgotten', () async {
      int now = 1000 * 60 * 60 * 1000;
      final _Github github = _Github()..latest = '1.17.0';
      github.sums['1.16.6'] = await _signedSums(key, '1.16.6');
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();

      await background(github, store, notices, () => now).checkIfDue();
      expect(notices.shown, isEmpty);
      expect(store.state.notifiedVersion, isNull);
      expect(store.state.newestVersion, '1.17.0');

      github.latest = '1.16.6';
      now += 5 * 60 * 60 * 1000;
      await background(github, store, notices, () => now).checkIfDue();
      expect(notices.versions, <String>['1.16.6']);
      expect(store.state.notifiedVersion, '1.16.6');

      // A signed slip, announced, then deleted.
      github
        ..latest = '1.17.0'
        ..sums['1.17.0'] = await _signedSums(key, '1.17.0');
      now += 5 * 60 * 60 * 1000;
      await background(github, store, notices, () => now).checkIfDue();
      expect(store.state.notifiedVersion, '1.17.0');
      github
        ..latest = '1.16.7'
        ..sums.remove('1.17.0')
        ..sums['1.16.7'] = await _signedSums(key, '1.16.7');
      now += 5 * 60 * 60 * 1000;
      await background(github, store, notices, () => now).checkIfDue();
      expect(notices.versions, <String>['1.16.6', '1.17.0', '1.16.7']);
    });
  });

  group('githubReleaseSigned', () {
    test('true for the pinned key\'s signature of that version, false for '
        'none, another key or another version, null when not reached; '
        'true without a pinned key', () async {
      final _Github github = _Github()..offline.add('1.20.0');
      github.sums['1.17.0'] = await _signedSums(key, '1.17.0');
      github.sums['1.18.0'] = await _signedSums(stranger, '1.18.0');
      github.sums['1.19.0'] = await _signedSums(key, '1.17.0');
      github.sums['1.21.0'] = 'not json';
      Future<bool?> signed(String version, [List<String>? keys]) =>
          githubReleaseSigned(
            version,
            fetchText: github.text,
            keys: keys ?? <String>[key.hybridId],
          );
      expect(await signed('1.17.0'), isTrue);
      expect(await signed('1.16.9'), isFalse, reason: 'missing');
      expect(await signed('1.18.0'), isFalse);
      expect(await signed('1.19.0'), isFalse);
      expect(await signed('1.21.0'), isFalse);
      expect(await signed('1.20.0'), isNull);
      expect(await signed('1.16.9', const <String>[]), isTrue);
    });
  });
}
