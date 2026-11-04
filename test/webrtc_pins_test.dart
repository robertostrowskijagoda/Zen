import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The release builds check the WebRTC that flutter_webrtc downloads
/// against pinned SHA-256 (tool/ci/libwebrtc.sha256, tool/ci/webrtc_sdk.sha256)
/// and fail on a version without a pin; ordinary CI only warns. This test
/// makes a flutter_webrtc update that brings a new WebRTC fail at once, not
/// at the release tag (1.15.4 failed so).
void main() {
  final Directory package = _flutterWebrtc();

  test('every libwebrtc file the desktop builds take is pinned', () {
    final String ini = File(
      '${package.path}/third_party/libwebrtc_version.ini',
    ).readAsStringSync();
    final String version = RegExp(
      r'^\s*binary_version\s*=\s*(\S+)',
      multiLine: true,
    ).firstMatch(ini)!.group(1)!;
    final Set<String> pinned = _pinnedKeys('tool/ci/libwebrtc.sha256');
    const Map<String, List<String>> files = <String, List<String>>{
      'linux-x64': <String>['libwebrtc.so', 'libwebrtc-linux-x64-release.zip'],
      'linux-arm64': <String>[
        'libwebrtc.so',
        'libwebrtc-linux-arm64-release.zip',
      ],
      'windows-x64': <String>['libwebrtc.dll', 'libwebrtc-win-x64-release.zip'],
      'windows-arm64': <String>[
        'libwebrtc.dll',
        'libwebrtc-win-arm64-release.zip',
      ],
    };
    final List<String> missing = <String>[
      for (final MapEntry<String, List<String>> platform in files.entries)
        for (final String file in platform.value)
          if (!pinned.contains('$version/${platform.key}/$file'))
            '$version/${platform.key}/$file',
    ];
    expect(
      missing,
      isEmpty,
      reason:
          'Pin them in tool/ci/libwebrtc.sha256 from the official '
          'webrtc-sdk/libwebrtc release (the release build prints the lines).',
    );
  });

  test('the WebRTC framework iOS and macOS take is pinned', () {
    final Set<String> pinned = _pinnedLines('tool/ci/webrtc_sdk.sha256');
    for (final String platform in <String>['ios', 'macos']) {
      final String swift = File(
        '${package.path}/$platform/flutter_webrtc/Package.swift',
      ).readAsStringSync();
      final String version = RegExp(
        r'releases/download/([^/"]+)/WebRTC\.xcframework\.zip',
      ).firstMatch(swift)!.group(1)!;
      final String checksum = RegExp(
        r'checksum:\s*"([0-9a-f]{64})"',
      ).firstMatch(swift)!.group(1)!;
      expect(
        pinned,
        contains('$checksum  $version/WebRTC.xcframework.zip'),
        reason:
            '$platform: pin it in tool/ci/webrtc_sdk.sha256 after checking '
            'the official webrtc-sdk/Specs release.',
      );
    }
  });
}

Directory _flutterWebrtc() {
  final Map<String, dynamic> config =
      jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
          as Map<String, dynamic>;
  for (final Object? entry in config['packages'] as List<Object?>) {
    final Map<String, dynamic> p = entry! as Map<String, dynamic>;
    if (p['name'] == 'flutter_webrtc') {
      final Uri root = Uri.parse(p['rootUri'] as String);
      return Directory.fromUri(
        root.isAbsolute ? root : Directory('.dart_tool').uri.resolveUri(root),
      );
    }
  }
  throw StateError('flutter_webrtc is not in .dart_tool/package_config.json');
}

Iterable<String> _lines(String path) => File(path)
    .readAsLinesSync()
    .map((String line) => line.trim())
    .where((String line) => line.isNotEmpty && !line.startsWith('#'));

Set<String> _pinnedLines(String path) => _lines(path).toSet();

Set<String> _pinnedKeys(String path) => <String>{
  for (final String line in _lines(path)) line.split(RegExp(r'\s+')).last,
};
