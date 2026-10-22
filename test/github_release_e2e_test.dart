import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/release.dart';

import '../tool/release_contract.dart';
import '../tool/zen_release.dart' as tool;

/// A release folder made the way .github/workflows/release.yml makes it:
/// every file the workflow writes, SHA256SUMS in `sha256sum` format
/// (sorted, two spaces) and SHA256SUMS.sig from the release tool's
/// `sums-manifest`, signed with [key].
Future<Directory> _buildRelease(
  Directory root, {
  required String version,
  required LedgerKeyPair key,
  String? signedVersion,
}) async {
  final Directory dist = Directory('${root.path}/dist')..createSync();
  final Set<String> names = workflowAssetNames(
    File('.github/workflows/release.yml').readAsStringSync(),
    iosYml: File('.github/workflows/ios.yml').readAsStringSync(),
  )..removeAll(<String>[kSumsAsset, kSignedSumsAsset]);
  for (final String name in <String>[
    ...names,
    'LICENSE',
    'NOTICE',
    'LICENSES-GO.txt',
  ]) {
    File('${dist.path}/$name').writeAsStringSync('$name of Zen $version\n');
  }
  final List<String> files =
      dist
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
  final StringBuffer sums = StringBuffer();
  for (final String name in files) {
    sums.writeln('${await fileSha256(File('${dist.path}/$name'))}  $name');
  }
  File('${dist.path}/$kSumsAsset').writeAsStringSync(sums.toString());
  final SignedSums unsigned = SignedSums.fromJson(
    tool.createSignedSums(
      version: signedVersion ?? version,
      sumsText: sums.toString(),
    ),
  )!;
  final SignedSums signed = await unsigned.signedBy(key);
  File(
    '${dist.path}/$kSignedSumsAsset',
  ).writeAsStringSync(jsonEncode(signed.toJson()));
  return dist;
}

/// GitHub's `releases/latest` answer for [dist] published as [tag].
Map<String, Object?> _githubJson(Directory dist, String tag) =>
    <String, Object?>{
      'tag_name': tag,
      'draft': false,
      'prerelease': false,
      'assets': <Object?>[
        for (final File f in dist.listSync().whereType<File>())
          <String, Object?>{
            'name': f.uri.pathSegments.last,
            'size': f.lengthSync(),
            'browser_download_url':
                'https://github.com/robertostrowskijagoda/Zen/releases/'
                'download/$tag/${f.uri.pathSegments.last}',
          },
      ],
    };

final class _Installer implements GithubUpdateInstaller {
  _Installer(this.dir, this.assetName);

  final Directory dir;
  final List<List<int>> installed = <List<int>>[];

  @override
  final String assetName;

  @override
  Future<Directory> workDirectory() async => dir;

  @override
  Future<GithubInstallOutcome> install(File file, GithubRelease release) async {
    installed.add(await file.readAsBytes());
    return const GithubInstallOutcome('installed');
  }
}

/// GitHub as the app sees it, serving [dist]: the API answer, the files
/// under `/releases/download/<tag>/` and their text (SHA256SUMS, .sig).
/// [tamper] changes what is served for a name.
({
  GithubJsonFetcher json,
  GithubDownloader download,
  Future<String> Function(Uri) text,
  List<Uri> requests,
})
_github(
  Directory dist,
  String tag, {
  List<int> Function(String name, List<int> bytes)? tamper,
}) {
  final List<Uri> requests = <Uri>[];
  List<int> served(Uri uri) {
    requests.add(uri);
    expect(uri.scheme, 'https');
    expect(uri.host, 'github.com');
    final List<String> path = uri.pathSegments;
    expect(path.sublist(0, 5), <String>[
      'robertostrowskijagoda',
      'Zen',
      'releases',
      'download',
      tag,
    ]);
    final List<int> bytes = File('${dist.path}/${path.last}').readAsBytesSync();
    return tamper?.call(path.last, bytes) ?? bytes;
  }

  return (
    json: (Uri uri) async {
      requests.add(uri);
      expect(uri, kGithubLatestReleaseUri);
      return _githubJson(dist, tag);
    },
    download:
        (
          Uri uri,
          File target, {
          required int maxBytes,
          void Function(int received)? onProgress,
        }) async {
          final List<int> bytes = served(uri);
          if (bytes.length > maxBytes) {
            throw const GithubStatusException(413);
          }
          await target.writeAsBytes(bytes);
          onProgress?.call(bytes.length);
        },
    text: (Uri uri) async => utf8.decode(served(uri)),
    requests: requests,
  );
}

void main() {
  late Directory root;
  late LedgerKeyPair key;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('zen_release_e2e_');
    key = await LedgerKeyPair.generate();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<(GithubUpdateService, _Installer)> update(
    Directory dist,
    String asset, {
    List<String>? keys,
    List<int> Function(String name, List<int> bytes)? tamper,
    String tag = 'v9.9.9',
  }) async {
    final ({
      GithubJsonFetcher json,
      GithubDownloader download,
      Future<String> Function(Uri) text,
      List<Uri> requests,
    })
    github = _github(dist, tag, tamper: tamper);
    final Directory work = Directory('${root.path}/work-$asset')..createSync();
    final _Installer installer = _Installer(work, asset);
    final GithubUpdateService service = GithubUpdateService(
      installer: installer,
      fetchJson: github.json,
      fetchSums: github.text,
      download: github.download,
      currentVersion: '1.11.0',
      releaseKeys: keys ?? <String>[key.hybridId],
    );
    addTearDown(service.dispose);
    await service.check();
    expect(service.state, GithubCheckState.newer);
    expect(service.newer?.version, '9.9.9');
    await service.update();
    return (service, installer);
  }

  test('a release built like release.yml passes the release tool and '
      'updates every platform, checked against SHA256SUMS and the '
      'signature', () async {
    final Directory dist = await _buildRelease(
      root,
      version: '9.9.9',
      key: key,
    );
    expect(await verifyReleaseFolder(dist, version: '9.9.9'), isEmpty);
    expect(
      verifyReleaseJson(
        _githubJson(dist, 'v9.9.9'),
        version: '9.9.9',
        requireSignature: true,
      ),
      isEmpty,
    );
    for (final String asset in kUpdateAssets) {
      final (GithubUpdateService s, _Installer installer) = await update(
        dist,
        asset,
      );
      expect(s.installState, GithubInstallState.done, reason: asset);
      expect(installer.installed, hasLength(1), reason: asset);
      expect(
        installer.installed.single,
        File('${dist.path}/$asset').readAsBytesSync(),
        reason: asset,
      );
    }
  });

  test('a changed file, a changed SHA256SUMS or a foreign key installs '
      'nothing', () async {
    final Directory dist = await _buildRelease(
      root,
      version: '9.9.9',
      key: key,
    );
    // Same length, one byte changed: only the sums can tell.
    List<int> evil(List<int> bytes) => <int>[bytes.first ^ 1, ...bytes.skip(1)];

    // The APK swapped on the way: its sum does not match.
    final (GithubUpdateService a, _Installer ia) = await update(
      dist,
      'Zen-arm64-v8a.apk',
      tamper: (String name, List<int> b) =>
          name == 'Zen-arm64-v8a.apk' ? evil(b) : b,
    );
    expect(a.installState, GithubInstallState.failed);
    expect(ia.installed, isEmpty);

    // The APK and SHA256SUMS swapped together: the signature does not
    // cover the new sum.
    final List<int> fake = evil(
      File('${dist.path}/Zen-arm64-v8a.apk').readAsBytesSync(),
    );
    final (GithubUpdateService b, _Installer ib) = await update(
      dist,
      'Zen-arm64-v8a.apk',
      tamper: (String name, List<int> bytes) {
        if (name == 'Zen-arm64-v8a.apk') {
          return fake;
        }
        if (name == kSumsAsset) {
          return utf8.encode(
            utf8
                .decode(bytes)
                .replaceFirst(
                  RegExp(
                    r'^[0-9a-f]{64}(?=  Zen-arm64-v8a\.apk$)',
                    multiLine: true,
                  ),
                  sha256Hex(fake),
                ),
          );
        }
        return bytes;
      },
    );
    expect(b.installState, GithubInstallState.failed);
    expect(ib.installed, isEmpty);

    // Signed, but not with a key this build trusts.
    final LedgerKeyPair other = await LedgerKeyPair.generate();
    final (GithubUpdateService c, _Installer ic) = await update(
      dist,
      'Zen-arm64-v8a.apk',
      keys: <String>[other.hybridId],
    );
    expect(c.installState, GithubInstallState.failed);
    expect(ic.installed, isEmpty);

    // The folder check of the release tool sees the swapped file too.
    File('${dist.path}/Zen-arm64-v8a.apk').writeAsStringSync('changed');
    expect(
      await verifyReleaseFolder(dist, version: '9.9.9'),
      contains('Zen-arm64-v8a.apk does not match its sum in $kSumsAsset'),
    );
  });

  test('the files of an older release passed off as a newer one are '
      'refused', () async {
    final Directory dist = await _buildRelease(
      root,
      version: '9.9.9',
      key: key,
      signedVersion: '9.9.8',
    );
    expect(
      await verifyReleaseFolder(dist, version: '9.9.9'),
      contains(contains('signs version 9.9.8')),
    );
    final (GithubUpdateService s, _Installer installer) = await update(
      dist,
      'Zen-Windows.zip',
    );
    expect(s.installState, GithubInstallState.failed);
    expect(installer.installed, isEmpty);
  });

  test('a release without SHA256SUMS.sig is not downloaded by a build '
      'that pins a key', () async {
    final Directory dist = await _buildRelease(
      root,
      version: '9.9.9',
      key: key,
    );
    File('${dist.path}/$kSignedSumsAsset').deleteSync();
    expect(
      await verifyReleaseFolder(dist, version: '9.9.9', requireSignature: true),
      <String>['$kSignedSumsAsset is missing'],
    );
    final (GithubUpdateService s, _Installer installer) = await update(
      dist,
      'Zen-arm64-v8a.apk',
    );
    expect(s.installState, GithubInstallState.failed);
    expect(installer.installed, isEmpty);
  });
}
