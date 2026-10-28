import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Zen's own sounds, synthesised by `tool/sounds/generate_sounds.py`.
enum ZenSound {
  /// A soft two-note chime: a new message.
  message('zen_message'),

  /// A very small "bloop" when a message leaves (in the app only).
  messageSent('zen_sent'),

  /// One quiet, round tone: a message arrives in the chat that is open (in
  /// the app only; the chime is for a notification).
  messageReceived('zen_received'),

  /// A tiny bright "pluck": a like or a reaction given (in the app only).
  like('zen_like'),

  /// Two light rising notes: a post is published (in the app only).
  posted('zen_posted'),

  /// A soft "pop": a new entry in the list of notifications while the app
  /// is open (in the app only).
  pop('zen_pop'),

  /// One soft tone: groups, posts, events and other news from friends.
  social('zen_social'),

  /// Two soft knocks: the neighbours (someone at the flat's door).
  knock('zen_knock'),

  /// A gentle kalimba melody that loops while a call rings.
  ringtone('zen_ringtone'),

  /// Loud and urgent, unlike anything else: a friend's alarm.
  alarm('zen_alarm'),

  /// Two quick rising notes: the call is on (in the app only).
  callConnected('zen_call_connected'),

  /// The same notes falling: the call is over (in the app only).
  callEnded('zen_call_ended');

  const ZenSound(this.fileName);

  /// The name without an extension, the same on every platform.
  final String fileName;

  /// The Flutter asset (played inside the app).
  String get asset => 'assets/sounds/$fileName.wav';

  /// Whether a system notification carries it: then it is also in
  /// `android/app/src/main/res/raw/<fileName>.ogg` (channel sounds) and in
  /// the iOS and macOS bundles as [appleFileName].
  bool get isNotificationSound => switch (this) {
    ZenSound.message ||
    ZenSound.social ||
    ZenSound.knock ||
    ZenSound.ringtone ||
    ZenSound.alarm => true,
    ZenSound.messageSent ||
    ZenSound.messageReceived ||
    ZenSound.like ||
    ZenSound.posted ||
    ZenSound.pop ||
    ZenSound.callConnected ||
    ZenSound.callEnded => false,
  };

  /// The notification sound in the iOS and macOS bundles (`Runner/Sounds`).
  String get appleFileName => '$fileName.caf';

  /// A short effect inside the app, governed by "Dźwięki w aplikacji" (the
  /// notification sounds by "Dźwięk powiadomień").
  bool get isInAppEffect => !isNotificationSound;
}

/// Plays a sound file; the platform part of [ZenSoundEffects].
abstract interface class ZenSoundOutput {
  /// Starts [asset] (over and over when [loop]). The handle stops it; it is
  /// `null` when the sound could not start.
  Future<ZenSoundHandle?> play(String asset, {required bool loop});
}

/// One sound that is playing.
abstract interface class ZenSoundHandle {
  Future<void> stop();
}

/// Plays nothing (widget tests, platforms without a player).
final class SilentSoundOutput implements ZenSoundOutput {
  const SilentSoundOutput();

  @override
  Future<ZenSoundHandle?> play(String asset, {required bool loop}) async =>
      null;
}

/// Plays through `video_player`, which Zen already has on every platform
/// (on Linux through its GStreamer backend). Mixed with other audio: an
/// effect never pauses the person's music.
final class VideoPlayerSoundOutput implements ZenSoundOutput {
  const VideoPlayerSoundOutput();

  @override
  Future<ZenSoundHandle?> play(String asset, {required bool loop}) async {
    final VideoPlayerController player = VideoPlayerController.asset(
      asset,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    final _VideoPlayerSound sound = _VideoPlayerSound(player);
    try {
      await player.initialize();
      await player.setLooping(loop);
      if (!loop) {
        player.addListener(sound.onTick);
        sound.stopAfter(player.value.duration);
      }
      await player.play();
      return sound;
    } on Object catch (error) {
      logZenWarning('Dźwięk $asset: $error');
      await sound.stop();
      return null;
    }
  }
}

final class _VideoPlayerSound implements ZenSoundHandle {
  _VideoPlayerSound(this._player);

  VideoPlayerController? _player;
  Timer? _safety;

  /// Releases the player once a one-off sound is over.
  void onTick() {
    final VideoPlayerValue? value = _player?.value;
    if (value != null && (value.isCompleted || value.hasError)) {
      unawaited(stop());
    }
  }

  /// In case the end is never reported.
  void stopAfter(Duration length) {
    _safety = Timer(length + const Duration(seconds: 2), () {
      unawaited(stop());
    });
  }

  @override
  Future<void> stop() async {
    _safety?.cancel();
    _safety = null;
    final VideoPlayerController? player = _player;
    _player = null;
    if (player == null) {
      return;
    }
    player.removeListener(onTick);
    try {
      await player.dispose();
    } on Object {
      // Already gone.
    }
  }
}

const MethodChannel _systemChannel = MethodChannel('zen/system');

/// Whether the device is set to stay quiet right now, where that can be
/// told: Android's silent or vibrate mode and "Nie przeszkadzać", GNOME's
/// "Nie przeszkadzać" on Linux. Elsewhere (and when asking fails): `false`.
Future<bool> deviceKeepsQuietNow() async {
  try {
    if (Platform.isAndroid) {
      return await _systemChannel.invokeMethod<bool>('soundsSilenced') ?? false;
    }
    if (Platform.isLinux) {
      final ProcessResult result = await Process.run('gsettings', <String>[
        'get',
        'org.gnome.desktop.notifications',
        'show-banners',
      ]);
      return result.exitCode == 0 && result.stdout.toString().trim() == 'false';
    }
  } on Object {
    // Cannot be told here: play.
  }
  return false;
}

Future<bool> _neverQuiet() async => false;

bool _alwaysOn() => true;

final Provider<ZenSoundEffects> zenSoundEffectsProvider =
    Provider<ZenSoundEffects>((Ref ref) {
      // Widget tests have no media player and no system channel.
      final bool underTest = Platform.environment.containsKey('FLUTTER_TEST');
      return ZenSoundEffects(
        output: underTest
            ? const SilentSoundOutput()
            : const VideoPlayerSoundOutput(),
        inAppSoundsOn: () =>
            ref.read(appSettingsControllerProvider).inAppSounds,
        notificationSoundsOn: () =>
            ref.read(appSettingsControllerProvider).notificationSounds,
        deviceKeepsQuiet: underTest ? _neverQuiet : deviceKeepsQuietNow,
      );
    });

/// Zen's sounds inside the app.
///
/// * In-app effects ([ZenSound.isInAppEffect]: a message sent or received
///   in the open chat, a like, a post published, a new entry in the list
///   of notifications, a call that connects or ends) play on Android,
///   macOS, Windows and Linux while "Dźwięki w aplikacji" is on. Not on
///   iOS: its silent switch cannot be read, and a player would sound
///   through it.
/// * Notification sounds play here only on Windows and Linux, where the
///   system notification cannot carry Zen's own sound reliably (a Windows
///   toast only can from an MSIX package; Linux notification servers often
///   ignore a sound file), and while "Dźwięk powiadomień" is on. Elsewhere
///   the notification itself sounds.
/// * Nothing plays while the device keeps quiet (silent mode, "Nie
///   przeszkadzać"), except a friend's alarm, which always does; and the
///   settings never silence an alarm or a ringing call.
final class ZenSoundEffects {
  ZenSoundEffects({
    required ZenSoundOutput output,
    required bool Function() inAppSoundsOn,
    bool Function()? notificationSoundsOn,
    Future<bool> Function()? deviceKeepsQuiet,
    TargetPlatform? platform,
    DateTime Function()? clock,
  }) : _output = output,
       _inAppSoundsOn = inAppSoundsOn,
       _notificationSoundsOn = notificationSoundsOn ?? _alwaysOn,
       _deviceKeepsQuiet = deviceKeepsQuiet ?? deviceKeepsQuietNow,
       _platform = platform ?? defaultTargetPlatform,
       _clock = clock ?? DateTime.now;

  final ZenSoundOutput _output;
  final bool Function() _inAppSoundsOn;
  final bool Function() _notificationSoundsOn;
  final Future<bool> Function() _deviceKeepsQuiet;
  final TargetPlatform _platform;
  final DateTime Function() _clock;

  /// The same sound again sooner than this is dropped (a burst of sends).
  static const Duration repeatGap = Duration(milliseconds: 250);

  /// How long "the device keeps quiet" is believed before asking again.
  static const Duration quietCheckValidFor = Duration(seconds: 10);

  final Map<ZenSound, DateTime> _lastStart = <ZenSound, DateTime>{};
  DateTime? _quietCheckedAt;
  bool _quiet = false;

  /// Whether this platform plays the in-app effects.
  bool get playsEffects =>
      !kIsWeb &&
      switch (_platform) {
        TargetPlatform.android ||
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux => true,
        _ => false,
      };

  /// Whether Zen plays its notification sounds itself on this platform.
  bool get playsNotificationSounds =>
      !kIsWeb &&
      (_platform == TargetPlatform.windows ||
          _platform == TargetPlatform.linux);

  /// Whether [sound] may play right now.
  Future<bool> allows(ZenSound sound) async {
    if (sound.isInAppEffect ? !playsEffects : !playsNotificationSounds) {
      return false;
    }
    if (sound == ZenSound.alarm) {
      return true;
    }
    if (sound != ZenSound.ringtone && !_settingOn(sound)) {
      return false;
    }
    if (await _keepsQuiet()) {
      logZenMessage('Sound ${sound.fileName} skipped: the device keeps quiet.');
      return false;
    }
    return true;
  }

  /// Plays [sound] once, when it may. Returns whether it started.
  Future<bool> play(ZenSound sound) async {
    final DateTime now = _clock();
    final DateTime? last = _lastStart[sound];
    if (last != null && now.difference(last) < repeatGap) {
      return false;
    }
    if (!await allows(sound)) {
      return false;
    }
    _lastStart[sound] = now;
    return await _output.play(sound.asset, loop: false) != null;
  }

  /// Plays [sound] over and over until the loop is stopped or [maxDuration]
  /// passes. `null` when it may not play now (or could not start).
  Future<ZenSoundLoop?> loop(
    ZenSound sound, {
    Duration maxDuration = const Duration(minutes: 1),
  }) async {
    if (!await allows(sound)) {
      return null;
    }
    final ZenSoundHandle? handle = await _output.play(sound.asset, loop: true);
    return handle == null ? null : ZenSoundLoop._(handle, maxDuration);
  }

  bool _settingOn(ZenSound sound) {
    try {
      return sound.isInAppEffect ? _inAppSoundsOn() : _notificationSoundsOn();
    } catch (_) {
      // Settings not readable (yet): the default, on.
      return true;
    }
  }

  Future<bool> _keepsQuiet() async {
    final DateTime now = _clock();
    final DateTime? checked = _quietCheckedAt;
    if (checked != null && now.difference(checked) < quietCheckValidFor) {
      return _quiet;
    }
    try {
      _quiet = await _deviceKeepsQuiet();
    } on Object {
      _quiet = false;
    }
    _quietCheckedAt = now;
    return _quiet;
  }
}

/// A sound playing over and over (a ringing call, an alarm).
final class ZenSoundLoop {
  ZenSoundLoop._(this._handle, Duration maxDuration) {
    _limit = Timer(maxDuration, () => unawaited(stop()));
  }

  final ZenSoundHandle _handle;
  late final Timer _limit;
  bool _stopped = false;

  bool get isStopped => _stopped;

  Future<void> stop() async {
    _limit.cancel();
    if (_stopped) {
      return;
    }
    _stopped = true;
    await _handle.stop();
  }
}
