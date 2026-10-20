import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:zen/src/features/update/release.dart';

Map<String, Object?> _releaseJson(
  String tag, {
  Map<String, int> assets = const <String, int>{'Zen.apk': 5},
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

final class _FakeInstaller implements GithubUpdateInstaller {
  _FakeInstaller(this.dir, {this.assetName = 'Zen.apk'});

  final Directory dir;
  final List<File> installed = <File>[];

  @override
  final String? assetName;

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
      expect(r.assets, <String, int>{'Zen.apk': 5});
      expect(
        r.assetUri('Zen.apk').toString(),
        'https://github.com/robertostrowskijagoda/Zen/releases/download/'
        'v1.12.0/Zen.apk',
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
          assets: <String, int>{'../evil': 3, 'Zen.apk': 0, 'SHA256SUMS': 9},
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
      expect(name('android', Abi.androidArm64), 'Zen.apk');
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

    test('SHA256SUMS must list the file by name with its sum', () {
      final String hex = 'ab' * 32;
      final String sums = '$hex  Zen.apk\n${'cd' * 32} *Zen-macOS.zip\n';
      expect(
        sha256SumsConfirm(sumsText: sums, name: 'Zen.apk', sha256Hex: hex),
        isTrue,
      );
      expect(
        sha256SumsConfirm(
          sumsText: sums,
          name: 'Zen.apk',
          sha256Hex: hex.toUpperCase(),
        ),
        isTrue,
      );
      expect(
        sha256SumsConfirm(
          sumsText: sums,
          name: 'Zen.apk',
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
        'https://github.com/robertostrowskijagoda/Zen/releases/download/v1.0.0/Zen.apk',
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
      _FakeInstaller? installer,
      List<String> releaseKeys = const <String>[],
    }) {
      final GithubUpdateService s = GithubUpdateService(
        installer: installer ?? _FakeInstaller(dir),
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
          expect(uri, kGithubLatestReleaseUri);
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

    test('no published release (404) is no update, not unreachable', () async {
      final GithubUpdateService s = service(
        fetchJson: (Uri uri) async => throw const GithubStatusException(404),
      );
      await s.check();
      expect(s.state, GithubCheckState.upToDate);
      expect(s.showUnreachableBanner, isFalse);
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
              expect(uri.path, endsWith('/v1.12.0/Zen.apk'));
              expect(maxBytes, 5);
              await target.writeAsBytes(bytes);
              onProgress?.call(bytes.length);
            },
        fetchSums: (Uri uri) async {
          sumsUri = uri;
          return '${sha256Hex(bytes)}  Zen.apk\n';
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
        fetchSums: (Uri uri) async => '${'00' * 32}  Zen.apk\n',
      );
      await s.check();
      await s.update();
      expect(s.installState, GithubInstallState.failed);
      expect(installer.installed, isEmpty);
      expect(File('${dir.path}/Zen.apk').existsSync(), isFalse);
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
        'Zen.apk': 5,
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
            'Zen.apk': sha ?? sha256Hex(bytes),
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
          releaseKeys: <String>[trusted.id],
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
                : '${sha256Hex(bytes)}  Zen.apk\n';
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
            releaseAssets: const <String, int>{'Zen.apk': 5},
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
          expect(File('${dir.path}/Zen.apk').existsSync(), isFalse);
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

    test('where Zen cannot install itself (iOS) only the prompt', () async {
      final GithubUpdateService s = service(
        installer: _FakeInstaller(dir, assetName: null),
        fetchJson: (Uri uri) async => _releaseJson('v1.12.0'),
      );
      await s.check();
      expect(s.showNewerBanner, isTrue);
      expect(s.canInstall, isFalse);
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
        newDir: r'C:\Apps\.zen-update-1.12.0',
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
