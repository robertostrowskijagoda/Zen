import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/update/github_redirects.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/presentation/github_update_banner.dart';
import 'package:zen/src/features/update/presentation/sidestore_source_option.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/update_service.dart';

Map<String, Object?> _releaseJson(
  String tag, {
  Map<String, int> assets = const <String, int>{'Zen-arm64-v8a.apk': 5},
  bool draft = false,
  bool prerelease = false,
}) => <String, Object?>{
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'assets': <Object?>[
    for (final MapEntry<String, int> a in assets.entries)
      <String, Object?>{'name': a.key, 'size': a.value},
  ],
};

/// An iPhone's update check and what it opened, copied and downloaded.
typedef _IosRun = ({
  GithubUpdateService service,
  List<String> pages,
  List<String> links,
  List<String> copied,
  List<Uri> downloads,
});

final class _FakeInstaller implements GithubUpdateInstaller {
  _FakeInstaller(
    this.dir, {
    this.assetName = 'Zen-arm64-v8a.apk',
    this.target = UpdateTarget.android,
  });

  final Directory dir;
  final List<File> installed = <File>[];

  @override
  final String? assetName;

  @override
  final UpdateTarget target;

  @override
  Future<Directory> workDirectory() async => dir;

  @override
  Future<GithubInstallOutcome> install(File file, GithubRelease release) async {
    installed.add(file);
    return const GithubInstallOutcome('installed');
  }
}

void main() {
  group('the release from GitHub', () {
    test('reads the tag as the version and compares numerically', () {
      final GithubRelease r = GithubRelease.fromJson(_releaseJson('v1.12.0'))!;
      expect(r.version, '1.12.0');
      expect(r.isNewerThan('1.11.0'), isTrue);
      expect(r.isNewerThan('1.12.0'), isFalse);
      expect(r.isNewerThan('1.13.0'), isFalse);
      expect(
        GithubRelease.fromJson(_releaseJson('v1.10.0'))!.isNewerThan('1.9.9'),
        isTrue,
      );
      expect(r.assets, <String, int>{'Zen-arm64-v8a.apk': 5});
      expect(
        r.assetUri('Zen-arm64-v8a.apk').toString(),
        'https://github.com/robertostrowskijagoda/Zen/releases/download/'
        'v1.12.0/Zen-arm64-v8a.apk',
      );
    });

    test('drafts, pre-releases and odd tags are not releases', () {
      expect(
        GithubRelease.fromJson(_releaseJson('v1.12.0', draft: true)),
        isNull,
      );
      expect(
        GithubRelease.fromJson(_releaseJson('v1.12.0', prerelease: true)),
        isNull,
      );
      expect(GithubRelease.fromJson(_releaseJson('1.12.0')), isNull);
      expect(GithubRelease.fromJson(_releaseJson('v1.12')), isNull);
      expect(GithubRelease.fromJson(_releaseJson('nightly')), isNull);
      expect(GithubRelease.fromJson('nope'), isNull);
    });

    test('asset names that are not plain file names are dropped', () {
      final GithubRelease r = GithubRelease.fromJson(
        _releaseJson(
          'v2.0.0',
          assets: <String, int>{
            '../evil': 3,
            'Zen-arm64-v8a.apk': 0,
            'SHA256SUMS': 9,
          },
        ),
      )!;
      expect(r.assets, <String, int>{'SHA256SUMS': 9});
    });

    test('each platform gets its release file', () {
      String? name(
        String p,
        Abi abi, [
        LinuxInstall l = LinuxInstall.tarball,
      ]) => githubAssetName(releasePlatform: p, abi: abi, linux: l);
      expect(name('android', Abi.androidArm64), 'Zen-arm64-v8a.apk');
      expect(name('android', Abi.androidArm), 'Zen-armeabi-v7a.apk');
      expect(name('android', Abi.androidX64), 'Zen-x86_64.apk');
      // No build for 32-bit x86: the APK of most phones.
      expect(name('android', Abi.androidIA32), 'Zen-arm64-v8a.apk');
      expect(name('windows', Abi.windowsX64), 'Zen-Windows.zip');
      expect(name('windows', Abi.windowsArm64), 'Zen-Windows-arm64.zip');
      expect(name('linux', Abi.linuxX64), 'Zen-Linux-x64.tar.gz');
      expect(name('linux', Abi.linuxArm64), 'Zen-Linux-arm64.tar.gz');
      expect(
        name('linux', Abi.linuxX64, LinuxInstall.deb),
        'Zen-Linux-x64.deb',
      );
      expect(
        name('linux', Abi.linuxX64, LinuxInstall.flatpak),
        'Zen-Linux-x64.flatpak',
      );
      expect(
        name('linux', Abi.linuxArm64, LinuxInstall.flatpak),
        'Zen-Linux-arm64.tar.gz',
      );
      expect(name('macos', Abi.macosArm64), 'Zen-macOS.zip');
      expect(name('ios', Abi.iosArm64), isNull);
    });

    test('Android takes the APK of the best ABI the device supports', () {
      String apk(List<String> device, Abi running) => githubAssetName(
        releasePlatform: 'android-armeabi-v7a',
        abi: running,
        androidAbis: device,
      )!;
      // A 64-bit phone running a 32-bit copy (from a friend) moves to the
      // 64-bit APK: every APK has the same version code.
      expect(
        apk(<String>['arm64-v8a', 'armeabi-v7a', 'armeabi'], Abi.androidArm),
        'Zen-arm64-v8a.apk',
      );
      // 32-bit Android on a 64-bit processor lists only 32-bit ABIs.
      expect(
        apk(<String>['armeabi-v7a', 'armeabi'], Abi.androidArm),
        'Zen-armeabi-v7a.apk',
      );
      // A Chromebook: x86_64 first, then the translated ARM ABIs.
      expect(
        apk(<String>['x86_64', 'x86', 'arm64-v8a'], Abi.androidX64),
        'Zen-x86_64.apk',
      );
      // Only 32-bit x86 and ARM: not x86 (no build), the ARM one.
      expect(
        apk(<String>['x86', 'armeabi-v7a'], Abi.androidArm),
        'Zen-armeabi-v7a.apk',
      );
      // The device said nothing: the ABI the app runs as.
      expect(apk(const <String>[], Abi.androidArm), 'Zen-armeabi-v7a.apk');
    });

    test('Flatpak is recognised (and then nothing is downloaded)', () {
      bool none(String path) => false;
      expect(isFlatpakSandbox(const <String, String>{}, none), isFalse);
      expect(
        isFlatpakSandbox(const <String, String>{
          'FLATPAK_ID': 'com.roj.zen',
        }, none),
        isTrue,
      );
      expect(
        isFlatpakSandbox(
          const <String, String>{},
          (String path) => path == '/.flatpak-info',
        ),
        isTrue,
      );
      expect(flatpakUpdateHint, contains('flatpak install --user'));
    });

    test('each system is its own kind of installation', () {
      UpdateTarget target(String os, [LinuxInstall l = LinuxInstall.tarball]) =>
          updateTargetFor(operatingSystem: os, linux: l);
      expect(target('android'), UpdateTarget.android);
      expect(target('windows'), UpdateTarget.windows);
      // The Mac is never taken for an iPhone, nor an iPad for a Mac.
      expect(target('macos'), UpdateTarget.macos);
      expect(target('ios'), UpdateTarget.ios);
      expect(target('linux'), UpdateTarget.linuxTarball);
      expect(target('linux', LinuxInstall.deb), UpdateTarget.linuxDeb);
      expect(target('linux', LinuxInstall.flatpak), UpdateTarget.flatpak);
      // The install kind matters on Linux only.
      expect(target('macos', LinuxInstall.flatpak), UpdateTarget.macos);
      expect(target('fuchsia'), UpdateTarget.other);
    });

    test('what "Aktualizuj" does on each kind of installation', () {
      final GithubRelease release = GithubRelease.fromJson(
        _releaseJson(
          'v1.12.0',
          assets: <String, int>{
            'Zen-arm64-v8a.apk': 5,
            'Zen-Windows.zip': 5,
            'Zen-macOS.zip': 5,
            'Zen-Linux-x64.tar.gz': 5,
            'Zen-Linux-x64.deb': 5,
            'Zen-Linux-x64.flatpak': 5,
            'Zen-unsigned.ipa': 5,
          },
        ),
      )!;
      GithubUpdateRoute route(UpdateTarget t, String? file) =>
          githubUpdateRoute(target: t, release: release, assetName: file);
      expect(
        route(UpdateTarget.android, 'Zen-arm64-v8a.apk'),
        GithubUpdateRoute.download,
      );
      expect(
        route(UpdateTarget.windows, 'Zen-Windows.zip'),
        GithubUpdateRoute.download,
      );
      expect(
        route(UpdateTarget.macos, 'Zen-macOS.zip'),
        GithubUpdateRoute.download,
      );
      expect(
        route(UpdateTarget.linuxTarball, 'Zen-Linux-x64.tar.gz'),
        GithubUpdateRoute.download,
      );
      expect(
        route(UpdateTarget.linuxDeb, 'Zen-Linux-x64.deb'),
        GithubUpdateRoute.download,
      );
      // iPhone and iPad never download, whatever file is named.
      expect(route(UpdateTarget.ios, null), GithubUpdateRoute.sideload);
      expect(
        route(UpdateTarget.ios, 'Zen-unsigned.ipa'),
        GithubUpdateRoute.sideload,
      );
      // A Flatpak never installs the bundle (nor a .deb) itself.
      expect(route(UpdateTarget.flatpak, null), GithubUpdateRoute.flatpak);
      expect(
        route(UpdateTarget.flatpak, 'Zen-Linux-x64.flatpak'),
        GithubUpdateRoute.flatpak,
      );
      // The release lacks this device's file (Windows ARM64 is optional).
      expect(
        route(UpdateTarget.windows, 'Zen-Windows-arm64.zip'),
        GithubUpdateRoute.releasePage,
      );
      expect(route(UpdateTarget.other, null), GithubUpdateRoute.releasePage);
    });

    test('SideStore and Safari get the IPA of exactly the announced '
        'version', () {
      final GithubRelease release = GithubRelease.fromJson(
        _releaseJson('v1.12.0', assets: <String, int>{kIosIpaAssetName: 9}),
      )!;
      expect(kIosIpaAssetName, 'Zen-unsigned.ipa');
      expect(
        iosIpaUrl(release),
        'https://github.com/robertostrowskijagoda/Zen/'
        'releases/download/v1.12.0/Zen-unsigned.ipa',
      );
      expect(
        iosIpaUrl(GithubRelease.fromJson(_releaseJson('v1.12.0'))!),
        isNull,
      );
      // SideStore's documented links: install that very IPA, add the
      // source (apps.json, the one the iPhone page adds). iOS opens the
      // source link exactly and install links only for this repository's
      // release IPAs.
      expect(
        sideStoreInstallLink(iosIpaUrl(release)!),
        'sidestore://install?url=https://github.com/robertostrowskijagoda/'
        'Zen/releases/download/v1.12.0/Zen-unsigned.ipa',
      );
      expect(
        kSideStoreSourceUrl,
        'https://robertostrowskijagoda.github.io/Zen/apps.json',
      );
      expect(
        kSideStoreSourceLink,
        'sidestore://source?url=$kSideStoreSourceUrl',
      );
      final String swift = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      expect(swift, contains('"$kSideStoreSourceLink"'));
      expect(
        swift,
        contains(
          '"sidestore://install?url=https://github.com/'
          'robertostrowskijagoda/Zen/releases/download/"',
        ),
      );
      expect(swift, contains('"/Zen-unsigned.ipa"'));
      expect(kIphoneInstallPageUrl, endsWith('/install/iphone/'));
      expect(kIphoneInstallPageUrl, startsWith('https://'));
    });

    test('the texts say what happens on each system', () {
      expect(
        githubUpdatePlan(UpdateTarget.android, 'Zen-arm64-v8a.apk'),
        allOf(contains('Zen-arm64-v8a.apk'), contains('instalator Androida')),
      );
      expect(
        githubUpdatePlan(UpdateTarget.windows, 'Zen-Windows.zip'),
        contains('zamknie się i uruchomi'),
      );
      expect(
        githubUpdatePlan(UpdateTarget.linuxDeb, 'Zen-Linux-x64.deb'),
        contains('instalatorem pakietów'),
      );
      for (final UpdateTarget t in <UpdateTarget>[
        UpdateTarget.ios,
        UpdateTarget.flatpak,
        UpdateTarget.other,
      ]) {
        expect(githubUpdatePlan(t, 'x'), isNull, reason: t.name);
      }
      String saved(UpdateTarget t, String file) => savedUpdateMessage(
        t,
        file: file,
        folder: '/home/a/Pobrane',
        path: '/home/a/Pobrane/$file',
      );
      expect(
        saved(UpdateTarget.linuxDeb, 'Zen-Linux-x64.deb'),
        contains("sudo apt install '/home/a/Pobrane/Zen-Linux-x64.deb'"),
      );
      expect(saved(UpdateTarget.macos, 'Zen-macOS.zip'), contains('Aplikacji'));
      expect(
        saved(UpdateTarget.windows, 'Zen-Windows.zip'),
        contains('rozpakuj'),
      );
      expect(
        saved(UpdateTarget.linuxTarball, 'Zen-Linux-x64.tar.gz'),
        contains('rozpakuj'),
      );
      expect(iosUpdateHint, contains('SideStore'));
      expect(iosSideStoreLabel, 'Zaktualizuj w SideStore');
      expect(iosDownloadLabel('1.12.0'), 'Pobierz Zen 1.12.0');
      final List<String> steps = iosUpdateSteps('1.12.0');
      expect(steps, hasLength(3));
      // The words of the iPhone install page and the install guide: the
      // VPN first, then the button that hands the IPA to SideStore.
      expect(steps[0], allOf(contains('LocalDevVPN'), contains('„Connect”')));
      expect(
        steps[1],
        allOf(contains('„Zaktualizuj w SideStore”'), contains('1.12.0')),
      );
      expect(steps[2], contains('Nie usuwaj'));
      // The other ways in SideStore: "Update" with the source, "+" with the
      // file from Safari.
      expect(
        iosOtherWaysHint('1.12.0'),
        allOf(
          contains('„My Apps” → „Update”'),
          contains('„Pobierz Zen 1.12.0”'),
          contains('„+”'),
          contains('Zen-unsigned.ipa'),
        ),
      );
    });

    test('SHA256SUMS must list the file by name with its sum', () {
      final String hex = 'ab' * 32;
      final String sums =
          '$hex  Zen-arm64-v8a.apk\n${'cd' * 32} *Zen-macOS.zip\n';
      expect(
        sha256SumsConfirm(
          sumsText: sums,
          name: 'Zen-arm64-v8a.apk',
          sha256Hex: hex,
        ),
        isTrue,
      );
      expect(
        sha256SumsConfirm(
          sumsText: sums,
          name: 'Zen-arm64-v8a.apk',
          sha256Hex: hex.toUpperCase(),
        ),
        isTrue,
      );
      expect(
        sha256SumsConfirm(
          sumsText: sums,
          name: 'Zen-arm64-v8a.apk',
          sha256Hex: 'cd' * 32,
        ),
        isFalse,
      );
      // The right sum under another name is not enough.
      expect(
        sha256SumsConfirm(
          sumsText: sums,
          name: 'Zen-Windows.zip',
          sha256Hex: hex,
        ),
        isFalse,
      );
    });

    test('requests and their redirects stay on GitHub, over HTTPS', () {
      for (final String ok in <String>[
        'https://api.github.com/repos/x/y/releases/latest',
        'https://github.com/robertostrowskijagoda/Zen/releases/download/v1.0.0/Zen-arm64-v8a.apk',
        'https://objects.githubusercontent.com/github-production-release-asset/1',
        'https://release-assets.githubusercontent.com/github-production-release-asset/1',
      ]) {
        expect(isGithubUri(Uri.parse(ok)), isTrue, reason: ok);
      }
      for (final String bad in <String>[
        'http://github.com/x',
        'https://github.com.evil.example/x',
        'https://evil.example/github.com',
        'https://user@github.com/x',
        'https://github.com:8443/x',
        'https://raw.githubusercontent.com/x',
      ]) {
        expect(isGithubUri(Uri.parse(bad)), isFalse, reason: bad);
      }
      expect(
        getFromGithub(
          HttpClient(),
          Uri.parse('https://example.com/SHA256SUMS'),
          timeout: const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
    });

    test('network failures count as unreachable, answers do not', () {
      expect(isUnreachableError(const SocketException('no route')), isTrue);
      expect(isUnreachableError(TimeoutException('slow')), isTrue);
      expect(isUnreachableError(const HandshakeException('tls')), isTrue);
      expect(isUnreachableError(const GithubStatusException(403)), isFalse);
      expect(isUnreachableError(const FormatException('json')), isFalse);
    });
  });

  group('the check', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('zen_gh_'));
    tearDown(() => dir.deleteSync(recursive: true));

    GithubUpdateService service({
      required GithubJsonFetcher fetchJson,
      bool internet = true,
      Future<String> Function(Uri uri)? fetchSums,
      GithubDownloader? download,
      Future<String?> Function()? beforeDownload,
      _FakeInstaller? installer,
      List<String> releaseKeys = const <String>[],
    }) {
      final GithubUpdateService s = GithubUpdateService(
        installer: installer ?? _FakeInstaller(dir),
        beforeDownload: beforeDownload,
        releaseKeys: releaseKeys,
        fetchJson: fetchJson,
        fetchSums: fetchSums ?? (Uri uri) async => '',
        download:
            download ??
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) async {},
        internetWorks: () => internet,
        currentVersion: '1.11.0',
      );
      addTearDown(s.dispose);
      return s;
    }

    test('a newer release is offered', () async {
      final GithubUpdateService s = service(
        fetchJson: (Uri uri) async {
          // The project's pages first; GitHub's API only when they fail.
          expect(uri, kZenReleaseInfoUri);
          return _releaseJson('v1.12.0');
        },
      );
      await s.check();
      expect(s.state, GithubCheckState.newer);
      expect(s.newer?.version, '1.12.0');
      expect(s.showNewerBanner, isTrue);
      expect(s.canInstall, isTrue);
      expect(s.showUnreachableBanner, isFalse);
      s.dismissNewer();
      expect(s.showNewerBanner, isFalse);
    });

    test('the same or an older version is no update', () async {
      for (final String tag in <String>['v1.11.0', 'v1.9.0']) {
        final GithubUpdateService s = service(
          fetchJson: (Uri uri) async => _releaseJson(tag),
        );
        await s.check();
        expect(s.state, GithubCheckState.upToDate, reason: tag);
        expect(s.newer, isNull);
        expect(s.showNewerBanner, isFalse);
      }
    });

    test('no published release (404) is said so, not "up to date"', () async {
      bool gone = false;
      final GithubUpdateService s = service(
        fetchJson: (Uri uri) async => gone
            ? throw const GithubStatusException(404)
            : _releaseJson('v1.12.0'),
      );
      await s.check();
      expect(s.newer?.version, '1.12.0');
      gone = true;
      await s.check();
      expect(s.state, GithubCheckState.missing);
      // A release that is gone is not offered any more.
      expect(s.newer, isNull);
      expect(s.showUnreachableBanner, isFalse);
      expect(s.nextCheckAt, isNull);
    });

    test('a rate limit: tried again when GitHub says, and said so', () async {
      final DateTime now = DateTime(2026, 10, 22, 12);
      final GithubUpdateService s = GithubUpdateService(
        installer: _FakeInstaller(dir),
        fetchJson: (Uri uri) async => throw const GithubStatusException(
          403,
          retryAfter: Duration(minutes: 30),
        ),
        now: () => now,
        currentVersion: '1.11.0',
      );
      addTearDown(s.dispose);
      await s.check();
      expect(s.state, GithubCheckState.failed);
      expect(s.rateLimited, isTrue);
      expect(s.nextCheckAt, now.add(const Duration(minutes: 31)));
    });

    test('other errors: retried sooner than the next regular check, '
        'twice as late each time', () async {
      final DateTime now = DateTime(2026, 10, 22, 12);
      bool broken = true;
      final GithubUpdateService s = GithubUpdateService(
        installer: _FakeInstaller(dir),
        fetchJson: (Uri uri) async => broken
            ? throw const GithubStatusException(502)
            : _releaseJson('v1.11.0'),
        now: () => now,
        currentVersion: '1.11.0',
        // Room for the doubling to show (the default is 15 minutes).
        checkEvery: const Duration(hours: 1),
      );
      addTearDown(s.dispose);
      await s.check();
      expect(s.rateLimited, isFalse);
      expect(s.nextCheckAt, now.add(const Duration(minutes: 15)));
      await s.check();
      expect(s.nextCheckAt, now.add(const Duration(minutes: 30)));
      for (int i = 0; i < 10; i++) {
        await s.check();
      }
      expect(s.nextCheckAt, now.add(s.checkEvery));
      broken = false;
      await s.check();
      expect(s.state, GithubCheckState.upToDate);
      expect(s.nextCheckAt, isNull);
    });

    test("GitHub's wait is read from its headers", () {
      final DateTime now = DateTime.utc(2026, 10, 22, 12);
      final int inForty =
          now.add(const Duration(minutes: 40)).millisecondsSinceEpoch ~/ 1000;
      expect(
        githubRetryAfter(retryAfter: '120', now: now),
        const Duration(minutes: 2),
      );
      expect(
        githubRetryAfter(
          rateLimitRemaining: '0',
          rateLimitReset: '$inForty',
          now: now,
        ),
        const Duration(minutes: 40),
      );
      // Requests left: no wait, however near the reset.
      expect(
        githubRetryAfter(
          rateLimitRemaining: '12',
          rateLimitReset: '${now.millisecondsSinceEpoch ~/ 1000}',
          now: now,
        ),
        isNull,
      );
      expect(githubRetryAfter(now: now), isNull);
      expect(const GithubStatusException(429).rateLimited, isTrue);
      expect(const GithubStatusException(403).rateLimited, isFalse);
      expect(
        const GithubStatusException(403, retryAfter: Duration.zero).rateLimited,
        isTrue,
      );
    });

    test('an unchanged release comes from the cache (If-None-Match)', () async {
      final List<String?> sent = <String?>[];
      final GithubJsonCache cache = GithubJsonCache(
        fetch: (Uri uri, {String? etag}) async {
          sent.add(etag);
          return etag == '"a"'
              ? const GithubJsonAnswer(etag: '"a"', notModified: true)
              : GithubJsonAnswer(json: _releaseJson('v1.12.0'), etag: '"a"');
        },
      );
      final Object? first = await cache(kGithubLatestReleaseUri);
      final Object? second = await cache(kGithubLatestReleaseUri);
      expect(sent, <String?>[null, '"a"']);
      expect(GithubRelease.fromJson(second)?.version, '1.12.0');
      expect(second, same(first));
    });

    test('an error answer is not "unreachable"', () async {
      final GithubUpdateService s = service(
        fetchJson: (Uri uri) async => throw const GithubStatusException(403),
      );
      await s.check();
      await s.check();
      expect(s.state, GithubCheckState.failed);
      expect(s.showUnreachableBanner, isFalse);
    });

    test('unreachable twice while the internet works: the warning', () async {
      final GithubUpdateService s = service(
        fetchJson: (Uri uri) async => throw const SocketException('blocked'),
      );
      await s.check();
      expect(s.state, GithubCheckState.unreachable);
      // One failure may be a hiccup.
      expect(s.showUnreachableBanner, isFalse);
      await s.check();
      expect(s.showUnreachableBanner, isTrue);
      expect(
        githubUnreachableMessage,
        contains('strona github jest niedostępna'),
      );
      s.dismissUnreachable();
      expect(s.showUnreachableBanner, isFalse);
    });

    test('offline (no mesh peers either): no warning banner', () async {
      final GithubUpdateService s = service(
        internet: false,
        fetchJson: (Uri uri) async => throw TimeoutException('offline'),
      );
      await s.check();
      await s.check();
      expect(s.state, GithubCheckState.unreachable);
      expect(s.showUnreachableBanner, isFalse);
    });

    test('a newer release found earlier stays offered when GitHub '
        'goes away', () async {
      bool up = true;
      final GithubUpdateService s = service(
        fetchJson: (Uri uri) async =>
            up ? _releaseJson('v1.12.0') : throw const SocketException('gone'),
      );
      await s.check();
      up = false;
      await s.check();
      expect(s.state, GithubCheckState.unreachable);
      expect(s.newer?.version, '1.12.0');
    });

    test('update: downloads, checks SHA256SUMS, installs', () async {
      final List<int> bytes = utf8.encode('hello');
      final _FakeInstaller installer = _FakeInstaller(dir);
      Uri? sumsUri;
      final GithubUpdateService s = service(
        installer: installer,
        fetchJson: (Uri uri) async => _releaseJson('v1.12.0'),
        download:
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) async {
              expect(uri.path, endsWith('/v1.12.0/Zen-arm64-v8a.apk'));
              expect(maxBytes, 5);
              await target.writeAsBytes(bytes);
              onProgress?.call(bytes.length);
            },
        fetchSums: (Uri uri) async {
          sumsUri = uri;
          return '${sha256Hex(bytes)}  Zen-arm64-v8a.apk\n';
        },
      );
      await s.check();
      await s.update();
      expect(sumsUri?.path, endsWith('/v1.12.0/SHA256SUMS'));
      expect(s.installState, GithubInstallState.done);
      expect(installer.installed, hasLength(1));
      expect(s.installMessage, 'installed');
    });

    test('update: a sum that does not match installs nothing', () async {
      final _FakeInstaller installer = _FakeInstaller(dir);
      final GithubUpdateService s = service(
        installer: installer,
        fetchJson: (Uri uri) async => _releaseJson('v1.12.0'),
        download:
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) => target.writeAsString('evil!'),
        fetchSums: (Uri uri) async => '${'00' * 32}  Zen-arm64-v8a.apk\n',
      );
      await s.check();
      await s.update();
      expect(s.installState, GithubInstallState.failed);
      expect(installer.installed, isEmpty);
      expect(File('${dir.path}/Zen-arm64-v8a.apk').existsSync(), isFalse);
    });

    test('update: the install permission is asked for before the download, '
        'and granted it goes on', () async {
      final List<int> bytes = utf8.encode('hello');
      final List<String> order = <String>[];
      final _FakeInstaller installer = _FakeInstaller(dir);
      final GithubUpdateService s = service(
        installer: installer,
        fetchJson: (Uri uri) async => _releaseJson('v1.12.0'),
        beforeDownload: () async {
          order.add('permission');
          return null;
        },
        download:
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) async {
              order.add('download');
              await target.writeAsBytes(bytes);
            },
        fetchSums: (Uri uri) async =>
            '${sha256Hex(bytes)}  Zen-arm64-v8a.apk\n',
      );
      await s.check();
      await s.update();
      expect(order, <String>['permission', 'download']);
      expect(s.installState, GithubInstallState.done);
      expect(installer.installed, hasLength(1));
    });

    test('update: without the install permission nothing is downloaded '
        'and the person is told', () async {
      int downloads = 0;
      int asked = 0;
      final _FakeInstaller installer = _FakeInstaller(dir);
      final GithubUpdateService s = service(
        installer: installer,
        fetchJson: (Uri uri) async => _releaseJson('v1.12.0'),
        beforeDownload: () async {
          asked++;
          return 'Zezwól Zen na instalowanie aplikacji';
        },
        download:
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) async {
              downloads++;
            },
      );
      await s.check();
      await s.update();
      expect(asked, 1);
      expect(downloads, 0);
      expect(installer.installed, isEmpty);
      expect(s.installState, GithubInstallState.failed);
      expect(s.installMessage, 'Zezwól Zen na instalowanie aplikacji');
      expect(s.installing, isFalse);
      // Allowed later: the next press downloads.
      await s.update();
      expect(asked, 2);
    });

    test('without release keys the author signature is not asked for '
        '(and the build says so)', () {
      final GithubUpdateService s = service(
        fetchJson: (Uri uri) async => _releaseJson('v1.12.0'),
      );
      expect(s.verifiesAuthorSignature, isFalse);
      expect(
        GithubUpdateService(
          installer: _FakeInstaller(dir),
          fetchJson: (Uri uri) async => null,
        ).verifiesAuthorSignature,
        kReleaseMaintainers.isNotEmpty,
      );
    });

    group('with a release key', () {
      final List<int> bytes = utf8.encode('hello');
      const Map<String, int> assets = <String, int>{
        'Zen-arm64-v8a.apk': 5,
        kSignedSumsAssetName: 400,
      };

      Future<String> signedSums(
        LedgerKeyPair key, {
        String version = '1.12.0',
        String? sha,
      }) async {
        final SignedSums signed = await SignedSums(
          version: version,
          files: <String, String>{
            'Zen-arm64-v8a.apk': sha ?? sha256Hex(bytes),
            'LICENSE': 'ab' * 32,
          },
          signatures: const <String, String>{},
        ).signedBy(key);
        return jsonEncode(signed.toJson());
      }

      Future<(GithubUpdateService, _FakeInstaller, List<Uri>)> run({
        required LedgerKeyPair trusted,
        required Future<String> Function() signature,
        Map<String, int> releaseAssets = assets,
      }) async {
        final _FakeInstaller installer = _FakeInstaller(dir);
        final List<Uri> fetched = <Uri>[];
        final GithubUpdateService s = service(
          installer: installer,
          releaseKeys: <String>[trusted.hybridId],
          fetchJson: (Uri uri) async =>
              _releaseJson('v1.12.0', assets: releaseAssets),
          download:
              (
                Uri uri,
                File target, {
                required int maxBytes,
                void Function(int received)? onProgress,
              }) async {
                fetched.add(uri);
                await target.writeAsBytes(bytes);
              },
          fetchSums: (Uri uri) async {
            fetched.add(uri);
            return uri.path.endsWith('/$kSignedSumsAssetName')
                ? signature()
                : '${sha256Hex(bytes)}  Zen-arm64-v8a.apk\n';
          },
        );
        await s.check();
        await s.update();
        return (s, installer, fetched);
      }

      test('a release signed with it installs', () async {
        final LedgerKeyPair key = await LedgerKeyPair.generate();
        final (GithubUpdateService s, _FakeInstaller installer, List<Uri> got) =
            await run(trusted: key, signature: () => signedSums(key));
        expect(s.verifiesAuthorSignature, isTrue);
        expect(s.installState, GithubInstallState.done);
        expect(installer.installed, hasLength(1));
        expect(
          got.map((Uri u) => u.path),
          contains(endsWith('/v1.12.0/$kSignedSumsAssetName')),
        );
      });

      test(
        'a release without the signature file is not even downloaded',
        () async {
          final LedgerKeyPair key = await LedgerKeyPair.generate();
          final (
            GithubUpdateService s,
            _FakeInstaller installer,
            List<Uri> got,
          ) = await run(
            trusted: key,
            signature: () => signedSums(key),
            releaseAssets: const <String, int>{'Zen-arm64-v8a.apk': 5},
          );
          expect(s.installState, GithubInstallState.failed);
          expect(s.installMessage, contains(kSignedSumsAssetName));
          expect(got, isEmpty);
          expect(installer.installed, isEmpty);
        },
      );

      test('another key, another version, another sum or no JSON: nothing '
          'is installed', () async {
        final LedgerKeyPair key = await LedgerKeyPair.generate();
        final LedgerKeyPair other = await LedgerKeyPair.generate();
        for (final Future<String> Function() signature
            in <Future<String> Function()>[
              () => signedSums(other),
              () => signedSums(key, version: '1.11.0'),
              () => signedSums(key, sha: '00' * 32),
              () async => 'not json',
            ]) {
          final (GithubUpdateService s, _FakeInstaller installer, _) =
              await run(trusted: key, signature: signature);
          expect(s.installState, GithubInstallState.failed);
          expect(installer.installed, isEmpty);
          expect(File('${dir.path}/Zen-arm64-v8a.apk').existsSync(), isFalse);
        }
      });
    });

    test('update: GitHub unreachable while downloading', () async {
      final _FakeInstaller installer = _FakeInstaller(dir);
      final GithubUpdateService s = service(
        installer: installer,
        fetchJson: (Uri uri) async => _releaseJson('v1.12.0'),
        download:
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) async => throw const SocketException('reset'),
      );
      await s.check();
      await s.update();
      expect(s.installState, GithubInstallState.failed);
      expect(s.installMessage, contains('github jest niedostępna'));
      expect(installer.installed, isEmpty);
    });

    group('iPhone and iPad', () {
      const String ipa =
          'https://github.com/robertostrowskijagoda/Zen/releases/download/'
          'v1.12.0/Zen-unsigned.ipa';
      final Map<String, Object?> withIpa = _releaseJson(
        'v1.12.0',
        assets: <String, int>{'Zen-unsigned.ipa': 9, 'Zen-arm64-v8a.apk': 5},
      );

      _IosRun ios({
        Map<String, Object?>? json,
        bool Function(String url)? browser,
        bool sideStore = true,
        String? assetName,
      }) {
        final List<String> pages = <String>[];
        final List<String> links = <String>[];
        final List<String> copied = <String>[];
        final List<Uri> downloads = <Uri>[];
        final GithubUpdateService s = GithubUpdateService(
          installer: _FakeInstaller(
            dir,
            assetName: assetName,
            target: UpdateTarget.ios,
          ),
          fetchJson: (Uri uri) async => json ?? withIpa,
          fetchSums: (Uri uri) async => '',
          download:
              (
                Uri uri,
                File target, {
                required int maxBytes,
                void Function(int received)? onProgress,
              }) async => downloads.add(uri),
          openPage: (String url) async {
            pages.add(url);
            return browser?.call(url) ?? true;
          },
          openSideStore: (String link) async {
            links.add(link);
            return sideStore;
          },
          copy: (String text) async => copied.add(text),
          currentVersion: '1.11.0',
        );
        addTearDown(s.dispose);
        return (
          service: s,
          pages: pages,
          links: links,
          copied: copied,
          downloads: downloads,
        );
      }

      test('never download an IPA, even when a file is named', () async {
        final _IosRun r = ios(assetName: 'Zen-unsigned.ipa');
        await r.service.check();
        expect(r.service.showNewerBanner, isTrue);
        expect(r.service.route, GithubUpdateRoute.sideload);
        expect(r.service.canInstall, isFalse);
        await r.service.update();
        expect(r.service.installState, GithubInstallState.idle);
        await r.service.openInSideStore();
        await r.service.openIpaInSafari();
        expect(r.downloads, isEmpty);
      });

      test('SideStore gets the IPA of exactly the announced version', () async {
        final _IosRun r = ios();
        await r.service.check();
        await r.service.openInSideStore();
        expect(r.links, <String>['sidestore://install?url=$ipa']);
        expect(r.pages, isEmpty);
        expect(r.downloads, isEmpty);
        expect(r.service.installState, GithubInstallState.done);
        // What to check when the install does not start: the VPN.
        expect(
          r.service.installMessage,
          allOf(
            contains('Otwarto SideStore'),
            contains('1.12.0'),
            contains('LocalDevVPN'),
          ),
        );
      });

      test('SideStore did not open: the file instead', () async {
        final _IosRun r = ios(sideStore: false);
        await r.service.check();
        await r.service.openInSideStore();
        expect(r.links, <String>['sidestore://install?url=$ipa']);
        expect(r.pages, isEmpty);
        expect(r.service.installState, GithubInstallState.failed);
        expect(
          r.service.installMessage,
          allOf(
            contains('Nie udało się otworzyć SideStore'),
            contains('„Pobierz Zen 1.12.0”'),
          ),
        );
      });

      test('SideStore for a release without the IPA: the install '
          'page', () async {
        final _IosRun r = ios(json: _releaseJson('v1.12.0'));
        await r.service.check();
        await r.service.openInSideStore();
        expect(r.links, isEmpty);
        expect(r.pages, <String>[kIphoneInstallPageUrl]);
      });

      test('Safari opens the IPA of exactly the announced version', () async {
        final _IosRun r = ios();
        await r.service.check();
        await r.service.openIpaInSafari();
        expect(r.pages, <String>[ipa]);
        expect(r.links, isEmpty);
        expect(r.downloads, isEmpty);
        expect(r.copied, isEmpty);
        expect(r.service.installState, GithubInstallState.done);
        // The message says the next step in SideStore: "+" in "My Apps".
        expect(
          r.service.installMessage,
          allOf(
            contains('1.12.0'),
            contains('Pliki'),
            contains('SideStore'),
            contains('„My Apps”'),
            contains('„+”'),
          ),
        );
      });

      test('a release without the IPA: the install page', () async {
        final _IosRun r = ios(json: _releaseJson('v1.12.0'));
        await r.service.check();
        await r.service.openIpaInSafari();
        expect(r.pages, <String>[kIphoneInstallPageUrl]);
        expect(r.service.installState, GithubInstallState.done);
        expect(r.service.installMessage, contains('stronę instalacji'));
      });

      test('the IPA did not open in a browser: the install page', () async {
        final _IosRun r = ios(browser: (String url) => url != ipa);
        await r.service.check();
        await r.service.openIpaInSafari();
        expect(r.pages, <String>[ipa, kIphoneInstallPageUrl]);
        expect(r.copied, isEmpty);
        expect(r.service.installMessage, contains('stronę instalacji'));
      });

      test('nothing opens: the page address is copied and said', () async {
        final _IosRun r = ios(browser: (String url) => false);
        await r.service.check();
        await r.service.openIpaInSafari();
        expect(r.pages, <String>[ipa, kIphoneInstallPageUrl]);
        expect(r.copied, <String>[kIphoneInstallPageUrl]);
        expect(r.service.installState, GithubInstallState.failed);
        expect(r.service.installMessage, contains(kIphoneInstallPageUrl));
      });

      test('the install page button opens the install page', () async {
        final _IosRun r = ios();
        await r.service.check();
        await r.service.openInstallPage();
        expect(r.pages, <String>[kIphoneInstallPageUrl]);
      });

      test('no newer release: nothing opens', () async {
        final _IosRun r = ios(json: _releaseJson('v1.11.0'));
        await r.service.check();
        await r.service.openInSideStore();
        await r.service.openIpaInSafari();
        expect(r.pages, isEmpty);
        expect(r.links, isEmpty);
      });
    });

    test('Flatpak: nothing downloaded, the release page opens', () async {
      final List<String> pages = <String>[];
      final List<Uri> downloads = <Uri>[];
      final GithubUpdateService s = GithubUpdateService(
        installer: _FakeInstaller(
          dir,
          assetName: 'Zen-Linux-x64.flatpak',
          target: UpdateTarget.flatpak,
        ),
        fetchJson: (Uri uri) async => _releaseJson(
          'v1.12.0',
          assets: <String, int>{
            'Zen-Linux-x64.flatpak': 5,
            'Zen-Linux-x64.deb': 5,
          },
        ),
        download:
            (
              Uri uri,
              File target, {
              required int maxBytes,
              void Function(int received)? onProgress,
            }) async => downloads.add(uri),
        openPage: (String url) async {
          pages.add(url);
          return true;
        },
        currentVersion: '1.11.0',
      );
      addTearDown(s.dispose);
      await s.check();
      expect(s.route, GithubUpdateRoute.flatpak);
      expect(s.canInstall, isFalse);
      await s.update();
      expect(downloads, isEmpty);
      await s.openReleasePage();
      expect(pages, <String>[
        'https://github.com/robertostrowskijagoda/Zen/releases/tag/v1.12.0',
      ]);
    });

    test('a release without this device\'s file: its page', () async {
      final GithubUpdateService s = service(
        installer: _FakeInstaller(
          dir,
          assetName: 'Zen-Windows-arm64.zip',
          target: UpdateTarget.windows,
        ),
        fetchJson: (Uri uri) async => _releaseJson(
          'v1.12.0',
          assets: <String, int>{'Zen-Windows.zip': 5},
        ),
      );
      await s.check();
      expect(s.route, GithubUpdateRoute.releasePage);
      expect(s.canInstall, isFalse);
    });
  });

  group('the install permission (Android channel)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = MethodChannel('zen/app_update');
    final List<String> calls = <String>[];

    void answer(bool allowed) {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call.method);
            return call.method == 'canInstall' ? allowed : null;
          });
    }

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('allowed: nothing is opened and nothing is said', () async {
      answer(true);
      expect(await requestInstallPermission(), isNull);
      expect(calls, <String>['canInstall']);
    });

    test('not allowed: the settings open and the person is told', () async {
      answer(false);
      final String? said = await requestInstallPermission();
      expect(said, contains('Zezwól Zen'));
      // It names the button the updates screen has: "Aktualizuj".
      expect(said, contains('„Aktualizuj”'));
      expect(said, isNot(contains('Zainstaluj')));
      expect(calls, <String>['canInstall', 'openInstallSettings']);
    });

    test('no plugin: said, so nothing would be downloaded', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(
        await requestInstallPermission(),
        'Instalowanie nie działa na tym urządzeniu.',
      );
    });
  });

  group('the store build', () {
    test('does not look at GitHub, nor do tests', () {
      expect(
        githubUpdatesEnabledFor(
          storeBuild: true,
          web: false,
          environment: const <String, String>{},
        ),
        isFalse,
      );
      expect(
        githubUpdatesEnabledFor(
          storeBuild: false,
          web: false,
          environment: const <String, String>{'FLUTTER_TEST': 'true'},
        ),
        isFalse,
      );
      expect(
        githubUpdatesEnabledFor(
          storeBuild: false,
          web: false,
          environment: const <String, String>{},
        ),
        isTrue,
      );
    });

    test('has no service', () {
      final ProviderContainer container = ProviderContainer(
        overrides: [githubUpdatesEnabledProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);
      expect(container.read(githubUpdateServiceProvider), isNull);
    });
  });

  group('the helpers that swap the app folder', () {
    test('quote paths safely', () {
      expect(shellQuote("/home/o'neil/Zen"), r"'/home/o'\''neil/Zen'");
      expect(
        powershellQuote(r"C:\Users\O'Neil\Zen"),
        r"'C:\Users\O''Neil\Zen'",
      );
      // PowerShell ends a quoted string at typographic quotes too.
      expect(
        powershellQuote('C:\\Users\\O\u2019Brien \u2018x\u201A\u201B'),
        "'C:\\Users\\O\u2019\u2019Brien \u2018\u2018x\u201A\u201A\u201B\u201B'",
      );
      expect(powershellQuote(r'C:\[Zen] $env:x `n'), r"'C:\[Zen] $env:x `n'");
    });

    test('wait for Zen, swap, restart', () {
      final String ps = windowsSwapScript(
        pid: 4242,
        appDir: r'C:\Apps\Zen',
        newDir: r'C:\Apps\.zen-update-1.12.0\Zen',
        oldDir: r'C:\Apps\Zen.old-1.12.0',
        stagingDir: r'C:\Apps\.zen-update-1.12.0',
        exeName: 'zen.exe',
      );
      expect(ps, contains('Wait-Process -Id 4242'));
      expect(ps, contains(r"$app = 'C:\Apps\Zen'"));
      // Literal paths only: brackets and the like in a folder name are
      // not wildcards there.
      expect(ps, contains(r'[System.IO.Directory]::Move($app, $old)'));
      expect(ps, contains(r'[System.IO.Directory]::Move($new, $app)'));
      expect(ps, contains("[System.IO.Path]::Combine(\$app, 'zen.exe')"));
      expect(ps, isNot(contains('Start-Process')));
      expect(ps, isNot(contains('-Destination')));
      final String sh = posixSwapScript(
        pid: 4242,
        appDir: '/home/a/Zen',
        newDir: '/home/a/.zen-update-1.12.0/Zen',
        oldDir: '/home/a/Zen.old-1.12.0',
        stagingDir: '/home/a/.zen-update-1.12.0',
        relaunch: "nohup '/home/a/Zen/zen' >/dev/null 2>&1 &",
      );
      expect(sh, startsWith('#!/bin/sh'));
      expect(sh, contains('kill -0 4242'));
      expect(sh, contains("app='/home/a/Zen'"));
      expect(sh, contains(r'mv "$new" "$app"'));
      expect(sh, contains("nohup '/home/a/Zen/zen'"));
      // The script lives in a private folder of its own and takes it along.
      expect(sh, contains(r'rmdir "$(dirname "$0")"'));
    });

    test('only a folder that is provably Zen\'s own is swapped', () {
      const String marker = 'zen-app 1\nzen.exe\nflutter_windows.dll\ndata\n';
      const List<String> release = <String>[
        'zen.exe',
        'flutter_windows.dll',
        'data',
        'zen-app.marker',
      ];
      bool own(String? text, List<String> entries, {bool ignoreCase = false}) =>
          isOwnAppFolderListing(
            marker: text,
            entries: entries,
            exeName: 'zen.exe',
            ignoreCase: ignoreCase,
          );
      expect(kAppFolderMarker, 'zen-app.marker');
      expect(own(marker, release), isTrue);
      // Downloads or the Desktop with Zen's files unpacked loose into it:
      // the person's own files are there too.
      expect(own(marker, <String>[...release, 'tax-return.pdf']), isFalse);
      expect(own(marker, <String>[...release, 'Photos']), isFalse);
      // No marker, another format, or one that does not name the program.
      expect(own(null, release), isFalse);
      expect(own('', release), isFalse);
      final String other = marker.replaceFirst('zen-app 1', 'zen-app 2');
      expect(own(other, release), isFalse);
      expect(
        own('zen-app 1\nflutter_windows.dll\ndata\n', <String>['data']),
        isFalse,
      );
      // The program itself must be there.
      expect(own(marker, <String>['data', 'zen-app.marker']), isFalse);
      // Windows: names ignore case, lines end with CRLF.
      const String windows = 'zen-app 1\r\nZEN.EXE\r\nData\r\n';
      expect(
        own(windows, <String>['zen.exe', 'data'], ignoreCase: true),
        isTrue,
      );
      expect(own(windows, <String>['zen.exe', 'data']), isFalse);
    });

    test('a folder on disk is checked by its marker and its files', () async {
      final Directory root = await Directory.systemTemp.createTemp('zen_own_');
      addTearDown(() => root.delete(recursive: true));
      final Directory app = await Directory('${root.path}/Zen').create();
      await File('${app.path}/zen').writeAsString('');
      await Directory('${app.path}/lib').create();
      await Directory('${app.path}/data').create();
      await File(
        '${app.path}/$kAppFolderMarker',
      ).writeAsString('$kAppFolderMarkerHeader\ndata\nlib\nzen\n');
      expect(
        await isOwnAppFolder(app, exeName: 'zen', ignoreCase: false),
        isTrue,
      );
      // The folder around it holds no marker.
      expect(
        await isOwnAppFolder(root, exeName: 'zen', ignoreCase: false),
        isFalse,
      );
      // Someone else's file next to Zen's: the folder is never swapped.
      await File('${app.path}/notes.txt').writeAsString('mine');
      expect(
        await isOwnAppFolder(app, exeName: 'zen', ignoreCase: false),
        isFalse,
      );
    });
  });

  group('the banner', () {
    Future<GithubUpdateService> pumpBanner(
      WidgetTester tester,
      GithubJsonFetcher fetchJson,
    ) async {
      final GithubUpdateService s = GithubUpdateService(
        installer: _FakeInstaller(Directory.systemTemp),
        fetchJson: fetchJson,
        currentVersion: '1.11.0',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [githubUpdateServiceProvider.overrideWithValue(s)],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const Scaffold(body: GithubUpdateBanner()),
          ),
        ),
      );
      return s;
    }

    Future<void> finish(WidgetTester tester, GithubUpdateService s) async {
      await tester.pumpWidget(const SizedBox.shrink());
      s.dispose();
    }

    testWidgets('says that a newer version is worth installing', (
      WidgetTester tester,
    ) async {
      final GithubUpdateService s = await pumpBanner(
        tester,
        (Uri uri) async => _releaseJson('v1.12.0'),
      );
      expect(find.byKey(const Key('github-newer-banner')), findsNothing);
      await s.check();
      await tester.pump();
      expect(find.byKey(const Key('github-newer-banner')), findsOneWidget);
      expect(
        find.text('Jest nowa wersja 1.12.0 — warto zaktualizować'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('github-update-install')), findsOneWidget);
      await finish(tester, s);
    });

    testWidgets('warns when GitHub is blocked', (WidgetTester tester) async {
      final GithubUpdateService s = await pumpBanner(
        tester,
        (Uri uri) async => throw const SocketException('blocked'),
      );
      await s.check();
      await s.check();
      await tester.pump();
      expect(
        find.byKey(const Key('github-unreachable-banner')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Nie mogę sprawdzić aktualizacji, strona github jest niedostępna. '
          'Możliwe, że ktoś zwalcza tę aplikację.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Zamknij'));
      await tester.pump();
      expect(find.byKey(const Key('github-unreachable-banner')), findsNothing);
      await finish(tester, s);
    });

    testWidgets('the updates card says when the author signature cannot be '
        'checked yet', (WidgetTester tester) async {
      Future<void> pumpCard(GithubUpdateService s) => tester.pumpWidget(
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
      final GithubUpdateService unsigned = GithubUpdateService(
        installer: _FakeInstaller(Directory.systemTemp),
        fetchJson: (Uri uri) async => null,
        releaseKeys: const <String>[],
      );
      await pumpCard(unsigned);
      expect(
        find.byKey(const Key('github-no-author-signature')),
        findsOneWidget,
      );
      await finish(tester, unsigned);

      final GithubUpdateService signed = GithubUpdateService(
        installer: _FakeInstaller(Directory.systemTemp),
        fetchJson: (Uri uri) async => null,
        releaseKeys: const <String>['key'],
      );
      await pumpCard(signed);
      expect(find.byKey(const Key('github-no-author-signature')), findsNothing);
      await finish(tester, signed);
    });

    testWidgets('the updates card says when a check failed and when it is '
        'tried again', (WidgetTester tester) async {
      final GithubUpdateService s = GithubUpdateService(
        installer: _FakeInstaller(Directory.systemTemp),
        fetchJson: (Uri uri) async => throw const GithubStatusException(
          429,
          retryAfter: Duration(minutes: 5),
        ),
        now: () => DateTime(2026, 10, 22, 12),
        currentVersion: '1.11.0',
      );
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
      await s.check();
      await tester.pump();
      expect(find.byKey(const Key('github-state-failed')), findsOneWidget);
      expect(
        find.text(
          'Nie udało się sprawdzić aktualizacji: GitHub chwilowo ogranicza '
          'liczbę zapytań.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Spróbuję ponownie'), findsOneWidget);
      await finish(tester, s);
    });

    Future<GithubUpdateService> pumpWith(
      WidgetTester tester,
      _FakeInstaller installer,
      Map<String, Object?> json, {
      Widget home = const Scaffold(body: GithubUpdateBanner()),
      Future<bool> Function(String url)? openPage,
      Future<bool> Function(String link)? openSideStore,
    }) async {
      final GithubUpdateService s = GithubUpdateService(
        installer: installer,
        fetchJson: (Uri uri) async => json,
        fetchSums: (Uri uri) async => '',
        openPage: openPage ?? (String url) async => true,
        openSideStore: openSideStore ?? (String link) async => true,
        currentVersion: '1.11.0',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [githubUpdateServiceProvider.overrideWithValue(s)],
          child: MaterialApp(theme: ZenTheme.dark(), home: home),
        ),
      );
      await s.check();
      await tester.pump();
      return s;
    }

    _FakeInstaller iosInstaller() => _FakeInstaller(
      Directory.systemTemp,
      assetName: null,
      target: UpdateTarget.ios,
    );

    testWidgets('on iPhone: "Zaktualizuj w SideStore" and numbered steps, '
        'never "Aktualizuj"', (WidgetTester tester) async {
      // Tall enough for the steps, both buttons and the message after a tap.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<String> opened = <String>[];
      final List<String> links = <String>[];
      final GithubUpdateService s = await pumpWith(
        tester,
        iosInstaller(),
        _releaseJson('v1.12.0', assets: <String, int>{'Zen-unsigned.ipa': 9}),
        openPage: (String url) async {
          opened.add(url);
          return true;
        },
        openSideStore: (String link) async {
          links.add(link);
          return true;
        },
      );
      const String ipa =
          'https://github.com/robertostrowskijagoda/Zen/releases/download/'
          'v1.12.0/Zen-unsigned.ipa';
      expect(find.byKey(const Key('github-update-install')), findsNothing);
      expect(find.byKey(const Key('github-update-sidestore')), findsOneWidget);
      expect(find.text('Zaktualizuj w SideStore'), findsOneWidget);
      expect(find.byKey(const Key('github-update-ipa')), findsOneWidget);
      expect(find.text('Pobierz Zen 1.12.0'), findsOneWidget);
      expect(
        find.byKey(const Key('github-update-install-page')),
        findsOneWidget,
      );
      expect(find.text(iosUpdateHint), findsOneWidget);
      final List<String> steps = iosUpdateSteps('1.12.0');
      for (int i = 0; i < steps.length; i++) {
        expect(
          tester
              .widget<Text>(find.byKey(Key('github-update-ios-step-${i + 1}')))
              .data,
          steps[i],
        );
        expect(find.text('${i + 1}.'), findsOneWidget);
      }
      expect(find.text(iosOtherWaysHint('1.12.0')), findsOneWidget);
      await tester.tap(find.byKey(const Key('github-update-sidestore')));
      await tester.pump();
      expect(links, <String>['sidestore://install?url=$ipa']);
      expect(opened, isEmpty);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('github-update-message')))
            .data,
        contains('Otwarto SideStore'),
      );
      await tester.tap(find.byKey(const Key('github-update-ipa')));
      await tester.pump();
      expect(opened, <String>[ipa]);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('github-update-message')))
            .data,
        allOf(contains('„My Apps”'), contains('„+”')),
      );
      await finish(tester, s);
    });

    testWidgets('the iPhone steps are not shown on other systems', (
      WidgetTester tester,
    ) async {
      for (final _FakeInstaller installer in <_FakeInstaller>[
        _FakeInstaller(Directory.systemTemp),
        _FakeInstaller(
          Directory.systemTemp,
          assetName: 'Zen-Windows.zip',
          target: UpdateTarget.windows,
        ),
        _FakeInstaller(
          Directory.systemTemp,
          assetName: null,
          target: UpdateTarget.flatpak,
        ),
      ]) {
        final GithubUpdateService s = await pumpWith(
          tester,
          installer,
          _releaseJson(
            'v1.12.0',
            assets: <String, int>{
              'Zen-arm64-v8a.apk': 5,
              'Zen-Windows.zip': 5,
              'Zen-Linux-x64.flatpak': 5,
              'Zen-unsigned.ipa': 9,
            },
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: GithubUpdateCard()),
          ),
        );
        final String system = installer.target.name;
        expect(
          find.byKey(const Key('github-update-ios-steps')),
          findsNothing,
          reason: system,
        );
        expect(
          find.byKey(const Key('github-update-ipa')),
          findsNothing,
          reason: system,
        );
        expect(
          find.byKey(const Key('github-update-sidestore')),
          findsNothing,
          reason: system,
        );
        expect(find.text(iosUpdateHint), findsNothing, reason: system);
        expect(
          find.byType(SideStoreSourceOption),
          findsNothing,
          reason: system,
        );
        await finish(tester, s);
      }
    });

    // A small phone (320 x 568) at twice the text size: the banner above
    // the app's content as in the shell, the card on the updates screen.
    for (final (String where, Widget home) in <(String, Widget)>[
      (
        'banner',
        const Scaffold(
          body: Column(
            children: <Widget>[
              GithubUpdateBanner(),
              Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
      (
        'card',
        const Scaffold(body: SingleChildScrollView(child: GithubUpdateCard())),
      ),
    ]) {
      testWidgets('the iPhone steps fit 320 px at twice the text size '
          '($where)', (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final GithubUpdateService s = await pumpWith(
          tester,
          iosInstaller(),
          _releaseJson('v1.12.0', assets: <String, int>{'Zen-unsigned.ipa': 9}),
          home: home,
        );
        expect(
          find.byKey(const Key('github-update-ios-steps')),
          findsOneWidget,
        );
        for (int i = 1; i <= 3; i++) {
          expect(find.byKey(Key('github-update-ios-step-$i')), findsOneWidget);
        }
        expect(
          find.byKey(const Key('github-update-ios-other-ways')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('github-update-sidestore')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('github-update-ipa')), findsOneWidget);
        if (where == 'card') {
          expect(find.byKey(const Key('sidestore-source-add')), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await finish(tester, s);
      });
    }

    group('the SideStore source', () {
      Future<(List<String>, List<String>)> pumpOption(
        WidgetTester tester, {
        required bool opens,
      }) async {
        final List<String> opened = <String>[];
        final List<String> copied = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ZenTheme.dark(),
            home: Scaffold(
              body: SideStoreSourceOption(
                openLink: (String link) async {
                  opened.add(link);
                  return opens;
                },
                copy: (String text) async => copied.add(text),
              ),
            ),
          ),
        );
        return (opened, copied);
      }

      String message(WidgetTester tester) => tester
          .widget<Text>(find.byKey(const Key('sidestore-source-message')))
          .data!;

      testWidgets('the button opens exactly the source link', (
        WidgetTester tester,
      ) async {
        final (List<String> opened, List<String> copied) = await pumpOption(
          tester,
          opens: true,
        );
        // The step by hand is said before anything is tapped.
        expect(
          tester
              .widget<Text>(find.byKey(const Key('sidestore-source-manual')))
              .data,
          allOf(contains('„Sources”'), contains('„+”')),
        );
        await tester.tap(find.byKey(const Key('sidestore-source-add')));
        await tester.pump();
        expect(opened, <String>[
          'sidestore://source?url=https://robertostrowskijagoda.github.io/'
              'Zen/apps.json',
        ]);
        expect(copied, isEmpty);
        expect(message(tester), contains('Otwarto SideStore'));
      });

      testWidgets('SideStore did not open: the address is copied', (
        WidgetTester tester,
      ) async {
        final (List<String> opened, List<String> copied) = await pumpOption(
          tester,
          opens: false,
        );
        await tester.tap(find.byKey(const Key('sidestore-source-add')));
        await tester.pump();
        expect(opened, hasLength(1));
        expect(copied, <String>[kSideStoreSourceUrl]);
        expect(message(tester), contains('„Sources” → „+”'));
      });

      testWidgets('"Kopiuj adres źródła" copies and shows the address', (
        WidgetTester tester,
      ) async {
        final (List<String> opened, List<String> copied) = await pumpOption(
          tester,
          opens: true,
        );
        await tester.tap(find.byKey(const Key('sidestore-source-copy')));
        await tester.pump();
        expect(opened, isEmpty);
        expect(copied, <String>[kSideStoreSourceUrl]);
        expect(message(tester), contains(kSideStoreSourceUrl));
      });
    });

    testWidgets('in a Flatpak: the command and the release page', (
      WidgetTester tester,
    ) async {
      final GithubUpdateService s = await pumpWith(
        tester,
        _FakeInstaller(
          Directory.systemTemp,
          assetName: null,
          target: UpdateTarget.flatpak,
        ),
        _releaseJson(
          'v1.12.0',
          assets: <String, int>{'Zen-Linux-x64.flatpak': 5},
        ),
      );
      expect(find.byKey(const Key('github-update-install')), findsNothing);
      expect(find.byKey(const Key('github-update-ipa')), findsNothing);
      expect(find.byKey(const Key('github-update-open-page')), findsOneWidget);
      expect(find.text(flatpakUpdateHint), findsOneWidget);
      await finish(tester, s);
    });

    testWidgets('the updates card says beforehand what Android will do', (
      WidgetTester tester,
    ) async {
      final GithubUpdateService s = await pumpWith(
        tester,
        _FakeInstaller(Directory.systemTemp),
        _releaseJson('v1.12.0'),
        home: const Scaffold(
          body: SingleChildScrollView(child: GithubUpdateCard()),
        ),
      );
      expect(find.byKey(const Key('github-update-install')), findsOneWidget);
      expect(
        find.text(githubUpdatePlan(UpdateTarget.android, 'Zen-arm64-v8a.apk')!),
        findsOneWidget,
      );
      await finish(tester, s);
    });

    testWidgets('the updates card on iPhone does not promise a download', (
      WidgetTester tester,
    ) async {
      final GithubUpdateService s = await pumpWith(
        tester,
        _FakeInstaller(
          Directory.systemTemp,
          assetName: null,
          target: UpdateTarget.ios,
        ),
        _releaseJson('v1.11.0'),
        home: const Scaffold(
          body: SingleChildScrollView(child: GithubUpdateCard()),
        ),
      );
      final String how = tester
          .widget<Text>(find.byKey(const Key('github-update-how')))
          .data!;
      expect(how, contains('SideStore'));
      // The SideStore source, even with no new version.
      expect(find.byType(SideStoreSourceOption), findsOneWidget);
      expect(find.byKey(const Key('sidestore-source-copy')), findsOneWidget);
      expect(how, isNot(contains('Pobrany plik')));
      await finish(tester, s);
    });

    testWidgets('nothing without the service (store build)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [githubUpdateServiceProvider.overrideWithValue(null)],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const Scaffold(body: GithubUpdateBanner()),
          ),
        ),
      );
      expect(find.byKey(const Key('github-newer-banner')), findsNothing);
      expect(find.byKey(const Key('github-unreachable-banner')), findsNothing);
    });
  });
}
