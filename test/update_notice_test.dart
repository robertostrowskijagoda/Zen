import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/update/background_update_check.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/update_notice.dart';

Map<String, Object?> _releaseJson(String tag) => <String, Object?>{
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'assets': <Object?>[
    <String, Object?>{'name': 'Zen-arm64-v8a.apk', 'size': 5},
  ],
};

/// Every notification posted, in order.
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
      expect(updateCheckDue(0, nowMillis: 12 * _hour - 1), isFalse);
      expect(updateCheckDue(0, nowMillis: 12 * _hour), isTrue);
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
              .subtract(const Duration(hours: 2))
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
      await s.checkIfDue();
      expect(asked, 0, reason: 'the background asked two hours ago');

      now = now.add(const Duration(hours: 10));
      await s.checkIfDue();
      expect(asked, 1);
      await s.checkIfDue();
      expect(asked, 1, reason: 'just asked');

      // The background service found a version in the meantime.
      now = now.add(const Duration(hours: 1));
      store.state = store.state.answered(
        at: now.millisecondsSinceEpoch,
        newest: '1.12.0',
      );
      await s.checkIfDue();
      expect(asked, 2);
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
        'GitHub at most every 12 hours', () async {
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

      expect(check.every, const Duration(hours: 12));
      expect(check.beatEvery, const Duration(hours: 3));
      final _Alarm wake = platform.live.single;
      expect(wake.whileIdle, isFalse);
      expect(wake.delay, const Duration(hours: 3));

      // On the beat, before the 12 hours are up: nothing is asked.
      for (int h = 3; h < 12; h += 3) {
        now += 3 * _hour;
        await check.checkIfDue();
      }
      expect(asked, 0);

      now += 3 * _hour;
      await check.checkIfDue();
      expect(asked, 1);
      expect(notices.shown, hasLength(1));
      expect(notices.shown.single.routeKey, buildUpdatesRouteKey());
      expect(store.state.checkedAtMillis, now);

      // Twelve hours later the same version: asked again, not announced.
      now += 12 * _hour;
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
          checkedAtMillis: now - 13 * _hour,
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
}
