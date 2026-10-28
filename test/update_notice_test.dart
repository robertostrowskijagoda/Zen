import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/update/background_update_check.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/presentation/github_update_banner.dart';
import 'package:zen/src/features/update/update_notice.dart';
import 'package:zen/src/features/update/whats_new.dart';

import '../tool/release_contract.dart' as contract;

Map<String, Object?> _releaseJson(String tag) => <String, Object?>{
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'assets': <Object?>[
    <String, Object?>{'name': 'Zen-arm64-v8a.apk', 'size': 5},
  ],
};

/// Every notification posted, in order, and what the shade holds now (one
/// per slot, as the system keeps them).
final class _Notices implements RuntimeSystemNotificationService {
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final Map<String, RuntimeSystemNotification> _bySlot =
      <String, RuntimeSystemNotification>{};

  List<RuntimeSystemNotification> get onScreen =>
      _bySlot.values.toList(growable: false);

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) async {}

  @override
  Future<bool> show(RuntimeSystemNotification notification) async {
    shown.add(notification);
    _bySlot[notification.slotKey ?? notification.id] = notification;
    return true;
  }

  @override
  Future<void> dismiss(String id) async {}

  @override
  Future<void> dismissSlot(String slotKey) async => _bySlot.remove(slotKey);

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

final class _Alarm implements WakeTimer {
  _Alarm(this.delay, this.fire, {required this.whileIdle});

  final Duration delay;
  final FutureOr<void> Function() fire;
  final bool whileIdle;
  bool cancelled = false;

  @override
  bool get isActive => !cancelled;

  @override
  void cancel() => cancelled = true;
}

/// Alarms as the phone would get them (none goes off by itself).
final class _WakePlatform implements ZenWakePlatform {
  final List<_Alarm> alarms = <_Alarm>[];

  List<_Alarm> get live =>
      alarms.where((_Alarm a) => a.isActive).toList(growable: false);

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) {
    final _Alarm alarm = _Alarm(delay, fire, whileIdle: whileIdle);
    alarms.add(alarm);
    return alarm;
  }

  @override
  Future<void> hold(String tag, Duration duration) async {}

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {}

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();
}

const int _hour = 60 * 60 * 1000;

/// A release of [version] on GitHub whose whats-new.json says [line],
/// listed in its SHA256SUMS (no maintainer key pinned). [fails]: github.com
/// does not answer for its files.
final class _NotedRelease {
  _NotedRelease(this.version, this.line)
    : note = contract.whatsNewJson(version, <String, List<String>>{
        'en': <String>[line],
        'pl': <String>[line],
      });

  final String version;
  final String line;
  final String note;
  bool fails = false;
  late final String sums =
      '${sha256Hex(utf8.encode(note))}  $kWhatsNewAssetName\n'
      '${'0' * 64}  Zen-arm64-v8a.apk\n';

  Map<String, Object?> json() => <String, Object?>{
    'tag_name': 'v$version',
    'draft': false,
    'prerelease': false,
    'assets': <Object?>[
      <String, Object?>{'name': 'Zen-arm64-v8a.apk', 'size': 5},
      <String, Object?>{'name': 'SHA256SUMS', 'size': sums.length},
      <String, Object?>{'name': kWhatsNewAssetName, 'size': note.length},
    ],
  };

  Future<String> text(Uri uri) async {
    if (fails) {
      throw const SocketException('offline');
    }
    expect(uri.pathSegments, contains('v$version'));
    return switch (uri.pathSegments.last) {
      kWhatsNewAssetName => note,
      'SHA256SUMS' => sums,
      _ => throw HttpException('HTTP 404', uri: uri),
    };
  }
}

void main() {
  group('the notification about a new version', () {
    test('is quiet, opens the updates screen and keeps the version under '
        'the "no content" setting', () {
      final RuntimeSystemNotification n = updateAvailableNotification(
        '1.12.0',
        createdAtMillis: 1,
      );
      expect(n.category, RuntimeSystemNotificationCategory.update);
      expect(n.slotKey, kUpdateNoticeSlot);
      expect(n.routeKey, buildUpdatesRouteKey());
      expect(zenSoundFor(n), isNull);
      final AndroidNotificationChannel channel =
          FlutterLocalRuntimeSystemNotificationService.androidChannelFor(n);
      expect(channel.id, 'zen_updates');
      expect(channel.importance, Importance.low);
      expect(channel.playSound, isFalse);
      final RuntimeSystemNotification redacted =
          PrivacyRedactingNotificationService(
            _Notices(),
            privacy: () => NotificationPrivacy.senderOnly,
          ).redact(n);
      expect(redacted.body, contains('1.12.0'));
      expect(redacted.title, n.title);
    });

    test('tapping it leads to "Aktualizacje i Podaj dalej"', () {
      final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
        id: 'x',
        routeKey: buildUpdatesRouteKey(),
      );
      expect(intent?.target, RuntimeRouteTarget.updates);
    });

    test('is shown once per version, never for an older one, and not for '
        'one whose banner was closed', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      Future<bool> announce(String version) => announceUpdateOnce(
        store: store,
        notices: notices,
        version: version,
        nowMillis: 1,
      );
      expect(await announce('1.12.0'), isTrue);
      expect(await announce('1.12.0'), isFalse);
      expect(await announce('1.11.5'), isFalse);
      expect(notices.shown, hasLength(1));
      expect(store.state.notifiedVersion, '1.12.0');
      expect(await announce('1.13.0'), isTrue);
      expect(notices.shown.map((RuntimeSystemNotification n) => n.id), <String>[
        '$kUpdateNoticeSlot-1.12.0',
        '$kUpdateNoticeSlot-1.13.0',
      ]);
      store.state = store.state.copyWith(dismissedVersion: '1.14.0');
      expect(await announce('1.14.0'), isFalse);
      expect(notices.shown, hasLength(2));
    });
  });

  group('the kept state', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('zen_update_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('survives in its file; a broken file is an empty state', () async {
      final FileUpdateNoticeStore store = FileUpdateNoticeStore(
        directory: () async => dir,
      );
      expect(await store.read(), const UpdateNoticeState());
      await store.update(
        (UpdateNoticeState s) => s.answered(at: 42, newest: '1.12.0'),
      );
      await store.update(
        (UpdateNoticeState s) =>
            s.copyWith(notifiedVersion: '1.12.0', dismissedVersion: '1.12.0'),
      );
      final UpdateNoticeState again = await FileUpdateNoticeStore(
        directory: () async => dir,
      ).read();
      expect(
        again,
        const UpdateNoticeState(
          checkedAtMillis: 42,
          newestVersion: '1.12.0',
          notifiedVersion: '1.12.0',
          dismissedVersion: '1.12.0',
        ),
      );
      // An answer without a newer release forgets the one before.
      await store.update((UpdateNoticeState s) => s.answered(at: 43));
      expect((await store.read()).newestVersion, isNull);
      expect((await store.read()).notifiedVersion, '1.12.0');
      File('${dir.path}/$kUpdateNoticeFileName').writeAsStringSync('{oops');
      expect(await store.read(), const UpdateNoticeState());
    });

    test('a check is due after the interval, or with a clock set back', () {
      expect(updateCheckDue(null, nowMillis: 0), isTrue);
      expect(updateCheckDue(0, nowMillis: _hour - 1), isFalse);
      expect(updateCheckDue(0, nowMillis: _hour), isTrue);
      expect(
        updateCheckDue(
          0,
          nowMillis: 4 * _hour - 1,
          every: kBackgroundGithubCheckEvery,
        ),
        isFalse,
      );
      expect(updateCheckDue(10 * _hour, nowMillis: 0), isTrue);
    });
  });

  group('the check in the app', () {
    GithubUpdateService service({
      required UpdateNoticeStore store,
      required _Notices notices,
      required GithubJsonFetcher fetchJson,
      DateTime Function()? now,
    }) {
      final GithubUpdateService s = GithubUpdateService(
        installer: _Installer(),
        fetchJson: fetchJson,
        noticeStore: store,
        notifications: notices,
        now: now,
        currentVersion: '1.11.0',
      );
      addTearDown(s.dispose);
      return s;
    }

    test('a newer release is announced once, also across restarts', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      String tag = 'v1.12.0';
      Future<Object?> fetch(Uri uri) async => _releaseJson(tag);
      final GithubUpdateService first = service(
        store: store,
        notices: notices,
        fetchJson: fetch,
      );
      await first.check();
      await first.check();
      expect(notices.shown, hasLength(1));
      expect(notices.shown.single.body, contains('1.12.0'));
      expect(store.state.newestVersion, '1.12.0');
      expect(store.state.checkedAtMillis, isNotNull);

      final GithubUpdateService restarted = service(
        store: store,
        notices: notices,
        fetchJson: fetch,
      );
      await restarted.check();
      expect(notices.shown, hasLength(1));

      tag = 'v1.13.0';
      await restarted.check();
      expect(notices.shown, hasLength(2));
      expect(notices.shown.last.body, contains('1.13.0'));
    });

    test('nothing newer: nothing announced', () async {
      final _Notices notices = _Notices();
      final GithubUpdateService s = service(
        store: MemoryUpdateNoticeStore(),
        notices: notices,
        fetchJson: (Uri uri) async => _releaseJson('v1.11.0'),
      );
      await s.check();
      expect(notices.shown, isEmpty);
    });

    test('a closed banner stays closed after a restart, for that version '
        'only; the card still offers it', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      String tag = 'v1.12.0';
      Future<Object?> fetch(Uri uri) async => _releaseJson(tag);
      final GithubUpdateService first = service(
        store: store,
        notices: notices,
        fetchJson: fetch,
      );
      await first.check();
      expect(first.showNewerBanner, isTrue);
      first.dismissNewer();
      expect(first.showNewerBanner, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(store.state.dismissedVersion, '1.12.0');

      final GithubUpdateService restarted = service(
        store: store,
        notices: notices,
        fetchJson: fetch,
      )..start();
      await Future<void>.delayed(Duration.zero);
      await restarted.check();
      expect(restarted.newer?.version, '1.12.0');
      expect(restarted.showNewerBanner, isFalse);

      tag = 'v1.13.0';
      await restarted.check();
      expect(restarted.showNewerBanner, isTrue);
    });

    test('at start and on coming back it asks only when a check is due '
        '(here or in the background service)', () async {
      DateTime now = DateTime(2026, 10, 27, 12);
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState(
          checkedAtMillis: now
              .subtract(const Duration(minutes: 40))
              .millisecondsSinceEpoch,
        ),
      );
      int asked = 0;
      final GithubUpdateService s = service(
        store: store,
        notices: _Notices(),
        now: () => now,
        fetchJson: (Uri uri) async {
          asked++;
          return _releaseJson('v1.11.0');
        },
      );
      expect(s.checkEvery, const Duration(hours: 1));
      await s.checkIfDue();
      expect(asked, 0, reason: 'the background asked 40 minutes ago');

      // Back in the app 20 minutes later: the last answer is an hour old.
      now = now.add(const Duration(minutes: 20));
      await s.checkIfDue();
      expect(asked, 1);
      await s.checkIfDue();
      expect(asked, 1, reason: 'just asked');
      now = now.add(const Duration(minutes: 59));
      await s.checkIfDue();
      expect(asked, 1, reason: 'not an hour yet');
      now = now.add(const Duration(minutes: 1));
      await s.checkIfDue();
      expect(asked, 2);

      // The background service found a version in the meantime.
      now = now.add(const Duration(minutes: 10));
      store.state = store.state.answered(
        at: now.millisecondsSinceEpoch,
        newest: '1.12.0',
      );
      await s.checkIfDue();
      expect(asked, 3);
    });

    test('a friend running a newer Zen makes it ask GitHub at once, once '
        'per version', () async {
      DateTime now = DateTime(2026, 10, 27, 12);
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      String tag = 'v1.11.0';
      int asked = 0;
      final GithubUpdateService s = service(
        store: store,
        notices: notices,
        now: () => now,
        fetchJson: (Uri uri) async {
          asked++;
          return _releaseJson(tag);
        },
      );
      await s.checkIfDue();
      expect(asked, 1);

      // Not newer than this build: nothing.
      await s.hintNewer('1.11.0');
      expect(asked, 1);

      // Published while this app was open; a friend already runs it.
      tag = 'v1.12.0';
      now = now.add(const Duration(minutes: 5));
      await s.hintNewer('1.12.0');
      expect(asked, 2, reason: 'asked at once, not an hour later');
      expect(s.newer?.version, '1.12.0');
      expect(notices.shown.single.body, contains('1.12.0'));

      // The same claim again, or one GitHub does not confirm: asked once.
      now = now.add(const Duration(minutes: 5));
      await s.hintNewer('1.12.0');
      expect(asked, 2);
      await s.hintNewer('1.13.0');
      expect(asked, 3);
      await s.hintNewer('1.13.0');
      expect(asked, 3);
      expect(s.newer?.version, '1.12.0');
      expect(notices.shown, hasLength(1));

      // A newer claim right after an attempt waits for the next check.
      await s.hintNewer('1.14.0');
      expect(asked, 3);
    });

    test('a release the maintainers signed, from friends, is announced at '
        'once', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      final GithubUpdateService s = service(
        store: store,
        notices: notices,
        fetchJson: (Uri uri) async => _releaseJson('v1.11.0'),
      );
      await s.hintNewer('1.12.0', signed: true);
      expect(notices.shown.single.body, contains('1.12.0'));
      expect(store.state.notifiedVersion, '1.12.0');
      await s.hintNewer('1.12.0', signed: true);
      expect(notices.shown, hasLength(1));
    });

    test('an unanswered check is not repeated on every return', () async {
      DateTime now = DateTime(2026, 10, 27, 12);
      int asked = 0;
      final GithubUpdateService s = service(
        store: MemoryUpdateNoticeStore(),
        notices: _Notices(),
        now: () => now,
        fetchJson: (Uri uri) async {
          asked++;
          throw TimeoutException('offline');
        },
      );
      await s.checkIfDue();
      await s.checkIfDue();
      expect(asked, 1);
      now = now.add(s.retryFirst);
      await s.checkIfDue();
      expect(asked, 2);
    });
  });

  group('the check in the Android background service', () {
    late _WakePlatform platform;
    int now = 0;

    setUp(() {
      platform = _WakePlatform();
      now = 1000 * _hour;
      ZenWake.platform = platform;
      ZenWake.nowMillis = () => now;
    });

    tearDown(() {
      ZenWake.resetForTest();
      ZenWake.platform = const TimerWakePlatform();
      ZenWake.nowMillis = () => DateTime.now().millisecondsSinceEpoch;
    });

    test('rides the shared beat without waking the phone in Doze, and asks '
        'GitHub at most every 4 hours', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState(checkedAtMillis: now),
      );
      final _Notices notices = _Notices();
      int asked = 0;
      final BackgroundUpdateCheck check = BackgroundUpdateCheck(
        notices: () async => notices,
        store: store,
        now: () => now,
        currentVersion: '1.11.0',
        firstAfter: const Duration(days: 1),
        fetchJson: (Uri uri) async {
          asked++;
          return _releaseJson('v1.12.0');
        },
      )..start();
      addTearDown(check.stop);

      expect(check.every, const Duration(hours: 4));
      expect(check.beatEvery, const Duration(hours: 1));
      final _Alarm wake = platform.live.single;
      expect(wake.whileIdle, isFalse);
      expect(wake.delay, const Duration(hours: 1));

      // On the beat, before the 4 hours are up: nothing is asked.
      for (int h = 1; h < 4; h++) {
        now += _hour;
        await check.checkIfDue();
      }
      expect(asked, 0);

      now += _hour;
      await check.checkIfDue();
      expect(asked, 1);
      expect(notices.shown, hasLength(1));
      expect(notices.shown.single.routeKey, buildUpdatesRouteKey());
      expect(store.state.checkedAtMillis, now);

      // Four hours later the same version: asked again, not announced.
      now += 4 * _hour;
      await check.checkIfDue();
      expect(asked, 2);
      expect(notices.shown, hasLength(1));

      check.stop();
      expect(platform.live, isEmpty);
    });

    test('takes the app\'s answer into account and leaves out a version '
        'the app already announced', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState(
          checkedAtMillis: now - 5 * _hour,
          notifiedVersion: '1.12.0',
        ),
      );
      final _Notices notices = _Notices();
      int asked = 0;
      final BackgroundUpdateCheck check = BackgroundUpdateCheck(
        notices: () async => notices,
        store: store,
        now: () => now,
        currentVersion: '1.11.0',
        fetchJson: (Uri uri) async {
          asked++;
          return _releaseJson('v1.12.0');
        },
      );
      await check.checkIfDue();
      expect(asked, 1);
      expect(notices.shown, isEmpty);
    });

    test('GitHub not reached: no answer kept, the next run tries', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      int asked = 0;
      final BackgroundUpdateCheck check = BackgroundUpdateCheck(
        notices: () async => _Notices(),
        store: store,
        now: () => now,
        currentVersion: '1.11.0',
        fetchJson: (Uri uri) async {
          asked++;
          throw const SocketException('offline');
        },
      );
      await check.checkIfDue();
      expect(store.state.checkedAtMillis, isNull);
      now += 3 * _hour;
      await check.checkIfDue();
      expect(asked, 2);
    });
  });

  group('a newer release after one already announced', () {
    const String apk = 'Zen-arm64-v8a.apk';

    GithubUpdateService app({
      required UpdateNoticeStore store,
      required _Notices notices,
      required _NotedRelease Function() latest,
      String currentVersion = '1.13.0',
    }) {
      final GithubUpdateService s = GithubUpdateService(
        installer: _Installer(),
        fetchJson: (Uri uri) async => latest().json(),
        fetchSums: (Uri uri) => latest().text(uri),
        noticeStore: store,
        notifications: notices,
        language: () => 'pl',
        currentVersion: currentVersion,
        releaseKeys: const <String>[],
      );
      addTearDown(s.dispose);
      return s;
    }

    test('in the app: 1.14.0 takes the place of 1.13.1 in the notification, '
        'the banner and the card, with its own note, once', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      _NotedRelease latest = _NotedRelease(
        '1.13.1',
        'Rozmowy są wyraźniejsze.',
      );
      final GithubUpdateService s = app(
        store: store,
        notices: notices,
        latest: () => latest,
      );
      await s.check();
      expect(notices.onScreen.single.body, contains('1.13.1'));
      expect(notices.onScreen.single.body, contains(latest.line));
      // "Później" for 1.13.1.
      s.dismissNewer();
      expect(s.showNewerBanner, isFalse);

      latest = _NotedRelease('1.14.0', 'Dźwięki wiadomości.');
      await s.check();
      expect(notices.shown, hasLength(2), reason: 'exactly one more');
      final RuntimeSystemNotification n = notices.onScreen.single;
      expect(n.id, '$kUpdateNoticeSlot-1.14.0');
      expect(n.slotKey, kUpdateNoticeSlot);
      expect(n.body.split('\n'), <String>[
        'Wersja 1.14.0 — warto zaktualizować',
        '• Dźwięki wiadomości.',
      ]);
      expect(s.newer?.version, '1.14.0');
      expect(
        s.showNewerBanner,
        isTrue,
        reason: '1.13.1 was closed, not 1.14.0',
      );
      expect(s.whatsNewLines, <String>['Dźwięki wiadomości.']);
      expect(s.newer!.assetUri(apk).pathSegments, contains('v1.14.0'));
      expect(store.state.notifiedVersion, '1.14.0');
      expect(store.state.newestVersion, '1.14.0');

      // The same version again, also after a restart: nothing more.
      await s.check();
      final GithubUpdateService restarted = app(
        store: store,
        notices: notices,
        latest: () => latest,
      )..start();
      await Future<void>.delayed(Duration.zero);
      await restarted.check();
      expect(notices.shown, hasLength(2));
      expect(notices.onScreen.single.id, '$kUpdateNoticeSlot-1.14.0');
      expect(restarted.showNewerBanner, isTrue);
    });

    test('in the Android background service: a closed 1.13.1 does not hold '
        'back 1.14.0, whose notification replaces the old one', () async {
      final int now = 1000 * _hour;
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState(
          checkedAtMillis: now - 5 * _hour,
          newestVersion: '1.13.1',
          notifiedVersion: '1.13.1',
          dismissedVersion: '1.13.1',
        ),
      );
      final _Notices notices = _Notices();
      await notices.show(
        updateAvailableNotification(
          '1.13.1',
          createdAtMillis: now - 6 * _hour,
          whatsNew: const <String>['Rozmowy są wyraźniejsze.'],
        ),
      );
      int clock = now;
      final _NotedRelease latest = _NotedRelease(
        '1.14.0',
        'Dźwięki wiadomości.',
      );
      BackgroundUpdateCheck check() => BackgroundUpdateCheck(
        notices: () async => notices,
        store: store,
        fetchJson: (Uri uri) async => latest.json(),
        fetchText: latest.text,
        now: () => clock,
        language: () => 'pl',
        currentVersion: '1.13.0',
        releaseKeys: const <String>[],
      );
      await check().checkIfDue();
      expect(notices.shown, hasLength(2));
      final RuntimeSystemNotification n = notices.onScreen.single;
      expect(n.id, '$kUpdateNoticeSlot-1.14.0');
      expect(n.body, contains('1.14.0'));
      expect(n.body, contains(latest.line));
      expect(n.body, isNot(contains('1.13.1')));
      expect(store.state.notifiedVersion, '1.14.0');

      // Asked again 4 hours later: the same version is not announced again.
      clock += 4 * _hour;
      await check().checkIfDue();
      expect(notices.shown, hasLength(2));
    });

    testWidgets('the banner and the card switch to 1.14.0 and its note', (
      WidgetTester tester,
    ) async {
      _NotedRelease latest = _NotedRelease(
        '1.13.1',
        'Rozmowy są wyraźniejsze.',
      );
      final GithubUpdateService s = app(
        store: MemoryUpdateNoticeStore(),
        notices: _Notices(),
        latest: () => latest,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [githubUpdateServiceProvider.overrideWithValue(s)],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: <Widget>[GithubUpdateBanner(), GithubUpdateCard()],
                ),
              ),
            ),
          ),
        ),
      );
      await s.check();
      await tester.pump();
      const String old = 'Jest nowa wersja 1.13.1 — warto zaktualizować';
      expect(find.text(old), findsNWidgets(2));
      expect(find.text('• Rozmowy są wyraźniejsze.'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Zamknij'));
      await tester.pump();
      expect(find.byKey(const Key('github-newer-banner')), findsNothing);

      latest = _NotedRelease('1.14.0', 'Dźwięki wiadomości.');
      await s.check();
      await tester.pump();
      expect(find.byKey(const Key('github-newer-banner')), findsOneWidget);
      expect(
        find.text('Jest nowa wersja 1.14.0 — warto zaktualizować'),
        findsNWidgets(2),
      );
      expect(find.text('• Dźwięki wiadomości.'), findsNWidgets(2));
      expect(find.text(old), findsNothing);
      expect(find.text('• Rozmowy są wyraźniejsze.'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('a note github.com did not give is asked for again at the next '
        'check', () async {
      final _NotedRelease latest = _NotedRelease(
        '1.14.0',
        'Dźwięki wiadomości.',
      )..fails = true;
      final GithubUpdateService s = app(
        store: MemoryUpdateNoticeStore(),
        notices: _Notices(),
        latest: () => latest,
      );
      await s.check();
      expect(s.newer?.version, '1.14.0');
      expect(s.whatsNewLines, isEmpty);
      latest.fails = false;
      await s.check();
      expect(s.whatsNewLines, <String>['Dźwięki wiadomości.']);
    });

    test('once installed, its notification goes, in the app and in the '
        'background service; a newer one stays', () async {
      Future<_Notices> shade(String version) async {
        final _Notices notices = _Notices();
        await notices.show(
          updateAvailableNotification(version, createdAtMillis: 1),
        );
        return notices;
      }

      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        const UpdateNoticeState(
          checkedAtMillis: 1,
          newestVersion: '1.14.0',
          notifiedVersion: '1.14.0',
          dismissedVersion: '1.13.1',
        ),
      );
      final _Notices notices = await shade('1.14.0');
      app(
        store: store,
        notices: notices,
        latest: () => _NotedRelease('1.14.0', 'Dźwięki wiadomości.'),
        currentVersion: '1.14.0',
      ).start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(notices.onScreen, isEmpty);
      expect(store.state, const UpdateNoticeState(checkedAtMillis: 1));

      final MemoryUpdateNoticeStore background = MemoryUpdateNoticeStore(
        UpdateNoticeState(
          checkedAtMillis: DateTime.now().millisecondsSinceEpoch,
          notifiedVersion: '1.14.0',
        ),
      );
      final _Notices backgroundNotices = await shade('1.14.0');
      await BackgroundUpdateCheck(
        notices: () async => backgroundNotices,
        store: background,
        fetchJson: (Uri uri) async => fail('not due'),
        currentVersion: '1.14.0',
      ).checkIfDue();
      expect(backgroundNotices.onScreen, isEmpty);
      expect(background.state.notifiedVersion, isNull);

      final MemoryUpdateNoticeStore newer = MemoryUpdateNoticeStore(
        const UpdateNoticeState(notifiedVersion: '1.15.0'),
      );
      final _Notices newerNotices = await shade('1.15.0');
      expect(
        await withdrawInstalledUpdateNotice(
          store: newer,
          notices: newerNotices,
          currentVersion: '1.14.0',
        ),
        isFalse,
      );
      expect(newerNotices.onScreen.single.id, '$kUpdateNoticeSlot-1.15.0');
      expect(newer.state.notifiedVersion, '1.15.0');
    });
  });
}
