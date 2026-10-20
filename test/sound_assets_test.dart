import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

/// Every sound the code refers to is really there, on every platform.
void main() {
  test('every sound has its Flutter asset, listed in pubspec.yaml', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/sounds/'));
    for (final ZenSound sound in ZenSound.values) {
      final File file = File(sound.asset);
      expect(file.existsSync(), isTrue, reason: sound.asset);
      final List<int> head = file.readAsBytesSync().sublist(0, 12);
      expect(String.fromCharCodes(head.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(head.sublist(8, 12)), 'WAVE');
    }
  });

  test('every notification sound is in Android res/raw and kept', () {
    final String keep = File(
      'android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();
    expect(keep, contains('@raw/zen_*'));
    for (final ZenSound sound in ZenSound.values.where(
      (ZenSound s) => s.isNotificationSound,
    )) {
      final String path = 'android/app/src/main/res/raw/${sound.fileName}.ogg';
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  test('every Android channel sound exists in res/raw', () {
    for (final AndroidNotificationChannel channel
        in FlutterLocalRuntimeSystemNotificationService.androidChannels()) {
      final String? name = channel.sound?.sound;
      if (name == null) {
        continue;
      }
      final String path = 'android/app/src/main/res/raw/$name.ogg';
      expect(File(path).existsSync(), isTrue, reason: channel.id);
    }
  });

  test('the native call card rings with the bundled ringtone', () {
    for (final String path in <String>[
      'android/app/src/main/kotlin/com/roj/zen/IncomingCallActivity.kt',
      'android/app/src/main/kotlin/com/roj/zen/IncomingCallUi.kt',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('R.raw.${ZenSound.ringtone.fileName}'),
        reason: path,
      );
    }
  });

  test('every notification sound is in the iOS and macOS bundles', () {
    for (final String platform in <String>['ios', 'macos']) {
      final String project = File(
        '$platform/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      for (final ZenSound sound in ZenSound.values.where(
        (ZenSound s) => s.isNotificationSound,
      )) {
        final String path = '$platform/Runner/Sounds/${sound.appleFileName}';
        expect(File(path).existsSync(), isTrue, reason: path);
        expect(
          project,
          contains('${sound.appleFileName} in Resources'),
          reason: '$platform: ${sound.appleFileName}',
        );
      }
    }
  });
}
