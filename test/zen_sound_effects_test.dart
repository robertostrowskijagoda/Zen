import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

final class _FakeHandle implements ZenSoundHandle {
  bool stopped = false;

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

final class _FakeOutput implements ZenSoundOutput {
  final List<String> played = <String>[];
  final List<String> looped = <String>[];
  final List<_FakeHandle> handles = <_FakeHandle>[];

  @override
  Future<ZenSoundHandle?> play(String asset, {required bool loop}) async {
    (loop ? looped : played).add(asset);
    final _FakeHandle handle = _FakeHandle();
    handles.add(handle);
    return handle;
  }
}

RuntimeSystemNotification _notification(
  RuntimeSystemNotificationCategory category, {
  String id = 'n-1',
  bool ringing = false,
}) {
  return RuntimeSystemNotification(
    id: id,
    title: 'T',
    body: 'B',
    createdAtMillis: 1,
    category: category,
    isRingingCall: ringing,
  );
}

void main() {
  late _FakeOutput output;
  late bool settingOn;
  late bool notificationsOn;
  late bool quiet;
  late DateTime now;

  ZenSoundEffects effects(TargetPlatform platform) {
    return ZenSoundEffects(
      output: output,
      inAppSoundsOn: () => settingOn,
      notificationSoundsOn: () => notificationsOn,
      deviceKeepsQuiet: () async => quiet,
      platform: platform,
      clock: () => now,
    );
  }

  setUp(() {
    output = _FakeOutput();
    settingOn = true;
    notificationsOn = true;
    quiet = false;
    now = DateTime(2026, 10, 21, 12);
  });

  test('"Dźwięki w aplikacji" is on by default', () {
    expect(const AppSettings().inAppSounds, isTrue);
    expect(const AppSettings().notificationSounds, isTrue);
    expect(
      AppSettings.fromJson(<String, dynamic>{'inAppSounds': false}).inAppSounds,
      isFalse,
    );
    expect(
      const AppSettings().copyWith(inAppSounds: false).toJson()['inAppSounds'],
      isFalse,
    );
  });

  test(
    'an in-app effect plays its own asset while the setting is on',
    () async {
      final ZenSoundEffects sounds = effects(TargetPlatform.android);
      expect(await sounds.play(ZenSound.messageSent), isTrue);
      expect(output.played, <String>['assets/sounds/zen_sent.wav']);
    },
  );

  test('the setting off silences the effects', () async {
    settingOn = false;
    final ZenSoundEffects sounds = effects(TargetPlatform.android);
    expect(await sounds.play(ZenSound.messageSent), isFalse);
    expect(await sounds.play(ZenSound.callConnected), isFalse);
    expect(await sounds.play(ZenSound.callEnded), isFalse);
    expect(output.played, isEmpty);
  });

  test('a device that keeps quiet silences the effects', () async {
    quiet = true;
    final ZenSoundEffects sounds = effects(TargetPlatform.android);
    expect(await sounds.play(ZenSound.callEnded), isFalse);
    expect(output.played, isEmpty);
  });

  test('a broken settings read falls back to on', () async {
    final ZenSoundEffects sounds = ZenSoundEffects(
      output: output,
      inAppSoundsOn: () => throw StateError('not ready'),
      deviceKeepsQuiet: () async => false,
      platform: TargetPlatform.android,
    );
    expect(await sounds.play(ZenSound.messageSent), isTrue);
  });

  test('no effects on iOS (its silent switch cannot be read)', () async {
    final ZenSoundEffects sounds = effects(TargetPlatform.iOS);
    expect(sounds.playsEffects, isFalse);
    expect(await sounds.play(ZenSound.messageSent), isFalse);
    expect(output.played, isEmpty);
  });

  test('the same sound right again is dropped', () async {
    final ZenSoundEffects sounds = effects(TargetPlatform.android);
    expect(await sounds.play(ZenSound.messageSent), isTrue);
    now = now.add(const Duration(milliseconds: 100));
    expect(await sounds.play(ZenSound.messageSent), isFalse);
    now = now.add(ZenSoundEffects.repeatGap);
    expect(await sounds.play(ZenSound.messageSent), isTrue);
    expect(output.played, hasLength(2));
  });

  test(
    'notification sounds play in the app only on Windows and Linux',
    () async {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        final ZenSoundEffects sounds = effects(platform);
        expect(sounds.playsNotificationSounds, isFalse, reason: '$platform');
        expect(
          await sounds.play(ZenSound.message),
          isFalse,
          reason: '$platform',
        );
      }
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final ZenSoundEffects sounds = effects(platform);
        expect(sounds.playsNotificationSounds, isTrue, reason: '$platform');
        expect(await sounds.play(ZenSound.knock), isTrue, reason: '$platform');
      }
    },
  );

  test('an alarm always sounds; a ringtone ignores only the setting', () async {
    notificationsOn = false;
    quiet = true;
    final ZenSoundEffects sounds = effects(TargetPlatform.windows);
    expect(await sounds.play(ZenSound.message), isFalse);
    expect(await sounds.allows(ZenSound.ringtone), isFalse);
    expect(await sounds.play(ZenSound.alarm), isTrue);

    quiet = false;
    now = now.add(ZenSoundEffects.quietCheckValidFor);
    expect(await sounds.allows(ZenSound.ringtone), isTrue);
    expect(await sounds.allows(ZenSound.social), isFalse);
  });

  test('the two switches are independent', () async {
    settingOn = false;
    final ZenSoundEffects sounds = effects(TargetPlatform.windows);
    // The effects are off, the notification sounds (Windows plays them
    // itself) are not.
    expect(await sounds.play(ZenSound.messageSent), isFalse);
    expect(await sounds.play(ZenSound.like), isFalse);
    expect(await sounds.play(ZenSound.message), isTrue);

    settingOn = true;
    notificationsOn = false;
    now = now.add(ZenSoundEffects.repeatGap);
    expect(await sounds.play(ZenSound.like), isTrue);
    expect(await sounds.play(ZenSound.knock), isFalse);
  });

  test('the new effects play their own assets', () async {
    final ZenSoundEffects sounds = effects(TargetPlatform.android);
    for (final ZenSound sound in <ZenSound>[
      ZenSound.messageReceived,
      ZenSound.like,
      ZenSound.posted,
      ZenSound.pop,
    ]) {
      expect(await sounds.play(sound), isTrue, reason: sound.name);
    }
    expect(output.played, <String>[
      'assets/sounds/zen_received.wav',
      'assets/sounds/zen_like.wav',
      'assets/sounds/zen_posted.wav',
      'assets/sounds/zen_pop.wav',
    ]);
  });

  test('a loop plays until stopped', () async {
    final ZenSoundEffects sounds = effects(TargetPlatform.linux);
    final ZenSoundLoop? loop = await sounds.loop(ZenSound.ringtone);
    expect(loop, isNotNull);
    expect(output.looped, <String>['assets/sounds/zen_ringtone.wav']);
    await loop!.stop();
    expect(loop.isStopped, isTrue);
    expect(output.handles.single.stopped, isTrue);
  });

  group('notification sounds', () {
    test('each kind of notification gets its own sound', () {
      expect(
        zenSoundFor(_notification(RuntimeSystemNotificationCategory.message)),
        ZenSound.message,
      );
      expect(
        zenSoundFor(
          _notification(RuntimeSystemNotificationCategory.call, ringing: true),
        ),
        ZenSound.ringtone,
      );
      // A missed or ended call is told like a message, not with a ringtone.
      expect(
        zenSoundFor(_notification(RuntimeSystemNotificationCategory.call)),
        ZenSound.message,
      );
      expect(
        zenSoundFor(_notification(RuntimeSystemNotificationCategory.social)),
        ZenSound.social,
      );
      expect(
        zenSoundFor(
          _notification(
            RuntimeSystemNotificationCategory.social,
            id: 'flat-knock-1-2',
          ),
        ),
        ZenSound.knock,
      );
      expect(
        zenSoundFor(
          _notification(RuntimeSystemNotificationCategory.alarm, ringing: true),
        ),
        ZenSound.alarm,
      );
      expect(
        zenSoundFor(_notification(RuntimeSystemNotificationCategory.transfer)),
        isNull,
      );
    });

    test('each Android channel carries the sound of what it gets', () {
      String? soundOf(AndroidNotificationChannel channel) =>
          channel.playSound ? channel.sound?.sound : null;

      final List<AndroidNotificationChannel> channels =
          FlutterLocalRuntimeSystemNotificationService.androidChannels();
      expect(
        channels.map((AndroidNotificationChannel c) => c.id).toSet(),
        hasLength(channels.length),
      );
      for (final RuntimeSystemNotification n in <RuntimeSystemNotification>[
        _notification(RuntimeSystemNotificationCategory.message),
        _notification(RuntimeSystemNotificationCategory.call, ringing: true),
        _notification(RuntimeSystemNotificationCategory.call),
        _notification(RuntimeSystemNotificationCategory.social),
        _notification(RuntimeSystemNotificationCategory.social, id: 'flat-x'),
        _notification(RuntimeSystemNotificationCategory.alarm, ringing: true),
        _notification(RuntimeSystemNotificationCategory.transfer),
      ]) {
        final AndroidNotificationChannel channel =
            FlutterLocalRuntimeSystemNotificationService.androidChannelFor(n);
        expect(soundOf(channel), zenSoundFor(n)?.fileName, reason: n.id);
      }
      // Messages, calls, friends' news, the neighbours and alarms each have
      // a channel (and a sound) of their own; transfers stay silent.
      expect(channels.map(soundOf).toSet(), <String?>{
        'zen_message',
        'zen_ringtone',
        'zen_alarm',
        'zen_social',
        'zen_knock',
        null,
      });
    });
  });
}
