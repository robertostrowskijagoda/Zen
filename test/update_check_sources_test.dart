import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/update/background_update_check.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/latest_release.dart';
import 'package:zen/src/features/update/presentation/github_update_banner.dart';
import 'package:zen/src/features/update/update_notice.dart';

/// Where the update check finds the newest release (the project's pages,
/// GitHub's API, GitHub's redirect), and what it keeps and shows about its
/// checks. A phone on 1.13.1 never heard of 1.14.0: the only source was
/// GitHub's API, whose 60 requests an hour per IP address a mobile
/// operator's shared address uses up, and every failed check stayed
/// silent.

const String _apk = 'Zen-arm64-v8a.apk';
const int _hour = 60 * 60 * 1000;

/// GitHub's API answer for [tag].
Map<String, Object?> _apiJson(String tag, {int size = 5}) => <String, Object?>{
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'assets': <Object?>[
    <String, Object?>{'name': _apk, 'size': size},
  ],
};

/// The project's release.json for [tag], as tool/ci/release_source.py
/// writes it.
Map<String, Object?> _pagesJson(String tag, {int size = 5, String min = ''}) =>
    <String, Object?>{
      'version': tag.substring(1),
      'build': '20',
      'tag': tag,
      'date': '2026-10-28',
      'url': 'https://github.com/robertostrowskijagoda/Zen/releases/tag/$tag',
      'minVersion': min,
      'assets': <String, Object?>{
        _apk: <String, Object?>{
          'url':
              'https://github.com/robertostrowskijagoda/Zen/releases/'
              'download/$tag/$_apk',
          'size': size,
        },
      },
      'apkCertificateSha256': '',
      'apkCertificatesSha256': <String>[],
    };

/// GitHub's API with its rate limit used up (as behind a mobile operator's
/// shared address).
const GithubStatusException _rateLimited = GithubStatusException(
  HttpStatus.forbidden,
  retryAfter: Duration(minutes: 30),
);

/// The three places, each answering as told; and what was asked.
final class _Net {
  Object? Function() pages = () => throw const SocketException('pages');
  Object? Function() api = () => throw _rateLimited;
  String? Function()? tag;
  final List<Uri> asked = <Uri>[];

  Future<Object?> json(Uri uri) async {
    asked.add(uri);
    if (uri == kZenReleaseInfoUri) {
      return pages();
    }
    expect(uri, kGithubLatestReleaseUri);
    return api();
  }

  Future<String?> redirect(Uri uri) async {
    asked.add(uri);
    expect(uri, kGithubLatestReleasePageUri);
    final String? Function()? answer = tag;
    if (answer == null) {
      throw const SocketException('github.com');
    }
    return answer();
  }

  int count(Uri uri) => asked.where((Uri u) => u == uri).length;
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
  _Installer(this.dir);

  final Directory dir;
  final List<List<int>> installed = <List<int>>[];

  @override
  UpdateTarget get target => UpdateTarget.android;

  @override
  String? get assetName => _apk;

  @override
  Future<Directory> workDirectory() async => dir;

  @override
  Future<GithubInstallOutcome> install(File file, GithubRelease release) async {
    installed.add(await file.readAsBytes());
    return const GithubInstallOutcome('installed');
  }
}

void main() {
  group('where the newest release is found', () {
    test('release.json of the pages is read like GitHub\'s answer', () {
      final GithubRelease release = GithubRelease.fromJson(
        _pagesJson('v1.14.0', size: 1234, min: '1.13.0'),
      )!;
      expect(release.tag, 'v1.14.0');
      expect(release.version, '1.14.0');
      expect(release.assets, <String, int>{_apk: 1234});
      expect(release.minVersion, '1.13.0');
      expect(release.detailed, isTrue);
      // Before the first release the pages name none.
      expect(
        GithubRelease.fromJson(<String, Object?>{'tag': '', 'assets': {}}),
        isNull,
      );
      // A minimum above the release itself is not one.
      expect(
        GithubRelease.fromJson(
          _pagesJson('v1.14.0', min: '1.15.0'),
        )!.minVersion,
        isNull,
      );
    });

    test('GitHub\'s redirect names the tag, and nothing else counts', () {
      final Uri from = kGithubLatestReleasePageUri;
      expect(
        releaseTagOfLocation(
          from,
          'https://github.com/robertostrowskijagoda/Zen/releases/tag/v1.14.0',
        ),
        'v1.14.0',
      );
      expect(
        releaseTagOfLocation(
          from,
          '/robertostrowskijagoda/Zen/releases/tag/v1.14.1',
        ),
        'v1.14.1',
      );
      for (final String? other in <String?>[
        null,
        '/robertostrowskijagoda/Zen/releases',
        'https://github.com/someone/Zen/releases/tag/v9.0.0',
        'https://evil.example/robertostrowskijagoda/Zen/releases/tag/v9.0.0',
        '/robertostrowskijagoda/Zen/releases/tag/nightly',
      ]) {
        expect(releaseTagOfLocation(from, other), isNull, reason: other);
      }
      final GithubRelease partial = GithubRelease.fromTag('v1.14.0')!;
      expect(partial.detailed, isFalse);
      expect(partial.mayHave(_apk), isTrue);
    });

    test('the repository first: its redirect names the newest version and '
        'the API brings its files; the pages are not asked then', () async {
      final _Net net = _Net()
        ..tag = (() => 'v1.14.0')
        ..api = (() => _apiJson('v1.14.0'))
        ..pages = (() => _pagesJson('v1.13.1'));
      final LatestReleaseAnswer answer = await LatestReleaseFinder(
        fetchJson: net.json,
        fetchTag: net.redirect,
      )();
      expect(answer.release?.version, '1.14.0');
      expect(answer.source, LatestReleaseSource.api);
      expect(net.asked, <Uri>[
        kGithubLatestReleasePageUri,
        kGithubLatestReleaseUri,
      ]);
    });

    test('the API refused: the pages bring the files only when they name '
        "the same version, else the redirect's version alone; a 404 of the "
        'API is "no release"', () async {
      final _Net net = _Net()
        ..tag = (() => 'v1.14.0')
        ..api = (() => throw _rateLimited)
        ..pages = (() => _pagesJson('v1.14.0'));
      LatestReleaseFinder find() =>
          LatestReleaseFinder(fetchJson: net.json, fetchTag: net.redirect);
      expect((await find()()).source, LatestReleaseSource.pages);

      // The pages not rebuilt yet after the release: the redirect wins.
      net.pages = () => _pagesJson('v1.13.1');
      final LatestReleaseAnswer redirected = await find()();
      expect(redirected.source, LatestReleaseSource.redirect);
      expect(redirected.release?.version, '1.14.0');
      expect(redirected.release?.detailed, isFalse);

      net.tag = null;
      net.asked.clear();
      net.api = () => throw const GithubStatusException(HttpStatus.notFound);
      await expectLater(
        find()(),
        throwsA(
          isA<GithubStatusException>().having(
            (GithubStatusException e) => e.statusCode,
            'status',
            HttpStatus.notFound,
          ),
        ),
      );
      // The redirect named nothing: the pages are not asked either.
      expect(net.count(kZenReleaseInfoUri), 0);

      // Nothing answers: the API's error, so a rate limit stays one.
      net
        ..api = (() => throw _rateLimited)
        ..pages = (() => throw const SocketException('pages'))
        ..tag = null;
      await expectLater(find()(), throwsA(same(_rateLimited)));
    });
  });

  group('the check in the app', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zen-update-sources');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    GithubUpdateService service(
      _Net net, {
      UpdateNoticeStore? store,
      _Notices? notices,
      _Installer? installer,
      Future<String> Function(Uri uri)? sums,
      Future<void> Function(Uri uri, File target, int maxBytes)? download,
      Duration confirmAfter = const Duration(minutes: 2),
    }) {
      final GithubUpdateService s = GithubUpdateService(
        installer: installer ?? _Installer(dir),
        fetchJson: net.json,
        fetchTag: net.redirect,
        fetchSums: sums ?? (Uri uri) async => '',
        download:
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) async => download?.call(uri, target, maxBytes),
        noticeStore: store ?? MemoryUpdateNoticeStore(),
        notifications: notices ?? _Notices(),
        currentVersion: '1.13.1',
        releaseKeys: const <String>[],
        confirmAfter: confirmAfter,
      );
      addTearDown(s.dispose);
      return s;
    }

    test('GitHub\'s API rate-limited: 1.14.0 is still found and announced, '
        'from the pages', () async {
      final _Net net = _Net()..pages = () => _pagesJson('v1.14.0');
      final _Notices notices = _Notices();
      final GithubUpdateService s = service(net, notices: notices);
      await s.check();
      expect(s.state, GithubCheckState.newer);
      expect(s.newer?.version, '1.14.0');
      expect(s.canInstall, isTrue);
      expect(notices.shown.single.body, contains('1.14.0'));
      // The API was asked first and refused.
      expect(net.count(kGithubLatestReleaseUri), 1);
    });

    test(
      'the pages down and the API rate-limited: the version comes from '
      'GitHub\'s redirect, and "Aktualizuj" still checks SHA256SUMS',
      () async {
        final List<int> apk = utf8.encode('the real apk');
        final _Net net = _Net()..tag = () => 'v1.14.0';
        final _Notices notices = _Notices();
        final _Installer installer = _Installer(dir);
        int? limit;
        String served = sha256Hex(apk);
        final GithubUpdateService s = service(
          net,
          notices: notices,
          installer: installer,
          sums: (Uri uri) async {
            expect(uri.pathSegments, containsAllInOrder(<String>['v1.14.0']));
            return '$served  $_apk\n';
          },
          download: (Uri uri, File target, int maxBytes) async {
            expect(uri.toString(), endsWith('/download/v1.14.0/$_apk'));
            limit = maxBytes;
            await target.writeAsBytes(apk);
          },
        );
        await s.check();
        expect(s.newer?.version, '1.14.0');
        expect(s.newer?.detailed, isFalse);
        expect(notices.shown.single.body, contains('1.14.0'));
        expect(s.canInstall, isTrue);

        await s.update();
        expect(s.installState, GithubInstallState.done);
        expect(installer.installed.single, apk);
        expect(limit, kMaxGithubAssetBytes, reason: 'its size is not known');

        // A file SHA256SUMS does not name with that hash is never installed.
        served = '0' * 64;
        await s.update();
        expect(s.installState, GithubInstallState.failed);
        expect(installer.installed, hasLength(1));
      },
    );

    test('the last success and the last error are kept for the other '
        'isolate and the updates screen', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Net net = _Net()
        ..pages = (() => throw const SocketException('pages'))
        ..api = (() => throw _rateLimited);
      final GithubUpdateService s = service(net, store: store);
      await s.check();
      expect(s.state, GithubCheckState.failed);
      expect(s.rateLimited, isTrue);
      expect(store.state.failedAtMillis, isNotNull);
      expect(store.state.error, 'HTTP 403');
      expect(s.lastError, 'HTTP 403');
      expect(s.checkedAt, isNull);

      net.pages = () => _pagesJson('v1.13.1');
      await s.check();
      expect(s.state, GithubCheckState.upToDate);
      expect(store.state.checkedAtMillis, isNotNull);
      expect(s.checkedAt, isNotNull);
      // The error stays, with its time, for the screen.
      expect(s.lastError, 'HTTP 403');
    });

    test('a version the background service found shows at once, before the '
        'app\'s own check, which then brings its files', () async {
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState(
          checkedAtMillis: DateTime.now().millisecondsSinceEpoch,
          newestVersion: '1.14.0',
          notifiedVersion: '1.14.0',
        ),
      );
      final _Net net = _Net()..pages = () => _pagesJson('v1.14.0');
      final GithubUpdateService s = service(net, store: store)..start();
      await pumpEventQueue();
      expect(s.newer?.version, '1.14.0');
      expect(s.showNewerBanner, isTrue);
      expect(net.asked, isEmpty, reason: 'the background just asked');

      await s.checkIfDue();
      // The API refused (the fake's default): the pages had the files.
      expect(net.asked.last, kZenReleaseInfoUri);
      expect(s.newer?.detailed, isTrue);
    });

    test('a friend\'s newer version right after a check is asked about once '
        'the short pause is over, not an hour later', () async {
      final _Net net = _Net()..pages = () => _pagesJson('v1.13.1');
      final GithubUpdateService s = service(
        net,
        confirmAfter: const Duration(milliseconds: 200),
      );
      await s.check();
      net.pages = () => _pagesJson('v1.14.0');
      await s.hintNewer('1.14.0');
      expect(net.count(kZenReleaseInfoUri), 1, reason: 'just asked');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();
      expect(net.count(kZenReleaseInfoUri), 2);
      expect(s.newer?.version, '1.14.0');
    });

    testWidgets('the updates screen says when the last check succeeded and '
        'what the last error was, also when the background service checked', (
      WidgetTester tester,
    ) async {
      final DateTime now = DateTime.now();
      final DateTime success = now.subtract(const Duration(hours: 2));
      final DateTime failure = now.subtract(const Duration(hours: 1));
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState(
          checkedAtMillis: success.millisecondsSinceEpoch,
          failedAtMillis: failure.millisecondsSinceEpoch,
          error: 'HTTP 403',
        ),
      );
      // Nothing checked in this isolate yet: what the background service
      // kept is all there is (the card used to say "not checked yet").
      final GithubUpdateService s = GithubUpdateService(
        installer: _Installer(Directory.systemTemp),
        fetchJson: (Uri uri) async => throw const SocketException('offline'),
        noticeStore: store,
        currentVersion: '1.13.1',
        checkEvery: const Duration(days: 36500),
      );
      addTearDown(s.dispose);
      await tester.runAsync(() => s.checkIfDue());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [githubUpdateServiceProvider.overrideWithValue(s)],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: GithubUpdateCard()),
            ),
          ),
        ),
      );
      await tester.pump();
      final String history = tester
          .widget<Text>(find.byKey(const Key('github-check-history')))
          .data!;
      expect(history, contains('Sprawdzono'));
      expect(history, contains(ZenFormat.time(success)));
      expect(history, contains('Ostatni błąd'));
      expect(history, contains(ZenFormat.time(failure)));
      expect(history, contains('HTTP 403'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the check in the Android background service', () {
    test('a rate limit is kept with its wait; the next run on the beat '
        'tries again once it is over, and finds the release', () async {
      int now = 1000 * _hour;
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore();
      final _Notices notices = _Notices();
      final _Net net = _Net()
        ..api = (() => throw const GithubStatusException(
          HttpStatus.tooManyRequests,
          retryAfter: Duration(minutes: 40),
        ));
      final BackgroundUpdateCheck check = BackgroundUpdateCheck(
        notices: () async => notices,
        store: store,
        now: () => now,
        fetchJson: net.json,
        currentVersion: '1.13.1',
        releaseKeys: const <String>[],
      );
      await check.checkIfDue();
      expect(store.state.checkedAtMillis, isNull);
      expect(store.state.error, 'HTTP 429');
      expect(store.state.retryAtMillis, now + 41 * 60 * 1000);

      // The next beat (30 minutes on): GitHub asked to wait 40.
      now += check.beatEvery.inMilliseconds;
      await check.checkIfDue();
      expect(net.count(kZenReleaseInfoUri), 1);

      // A beat later the wait is over; the pages answer again.
      net.pages = () => _pagesJson('v1.14.0');
      now += check.beatEvery.inMilliseconds;
      await check.checkIfDue();
      expect(net.count(kZenReleaseInfoUri), 2);
      expect(store.state.checkedAtMillis, now);
      expect(store.state.newestVersion, '1.14.0');
      expect(store.state.retryAtMillis, isNull);
      expect(notices.shown.single.body, contains('1.14.0'));
    });

    test('not reached: kept as the last error and tried again on the next '
        'beat, not hours later', () async {
      int now = 1000 * _hour;
      final MemoryUpdateNoticeStore store = MemoryUpdateNoticeStore(
        UpdateNoticeState(checkedAtMillis: now - 3 * _hour),
      );
      final _Net net = _Net()
        ..api = (() => throw const SocketException('offline'));
      final BackgroundUpdateCheck check = BackgroundUpdateCheck(
        notices: () async => _Notices(),
        store: store,
        now: () => now,
        fetchJson: net.json,
        currentVersion: '1.13.1',
      );
      await check.checkIfDue();
      expect(store.state.failedAtMillis, now);
      now += check.beatEvery.inMilliseconds;
      net.pages = () => _pagesJson('v1.13.1');
      await check.checkIfDue();
      expect(net.count(kZenReleaseInfoUri), 2);
      expect(store.state.checkedAtMillis, now);
    });
  });

  test('what Zen 1.13.x and 1.14.0 ask: only GitHub\'s API for the latest '
      'release, which a new release must stay', () {
    // Builds before this one know no other source: a release reaches them
    // only as GitHub's "latest" full release (not a draft, not a
    // pre-release), when their address still has requests left.
    expect(
      kGithubLatestReleaseUri.toString(),
      'https://api.github.com/repos/robertostrowskijagoda/Zen/releases/latest',
    );
    expect(GithubRelease.fromJson(_apiJson('v1.14.1'))?.version, '1.14.1');
    expect(
      GithubRelease.fromJson(<String, Object?>{
        ..._apiJson('v1.14.1'),
        'prerelease': true,
      }),
      isNull,
    );
  });
}
