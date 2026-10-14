import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';

/// A call shown small, floating over other apps:
/// - Android: picture-in-picture — leaving the app during a call (home,
///   another app) shrinks it into a small window the system keeps on top;
/// - computers: a small window that stays on top of other windows
///   (minimizing or closing Zen during a call turns it into one, and the
///   call screen has a button for it).
///
/// The call UI tells it whether a call is running ([updateCall]); the
/// platform side tells it whether the small window is up ([active]).
final class CallCompactMode {
  CallCompactMode._() {
    pictureInPictureChanged = reportPictureInPicture;
    pictureInPictureHangUp = hangUpFromPictureInPicture;
  }

  static final CallCompactMode instance = CallCompactMode._();

  /// Size of the floating window on computers.
  static const Size desktopAudioSize = Size(300, 170);
  static const Size desktopVideoSize = Size(320, 260);

  /// Whether the call is shown as the small floating window right now.
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Asked to end the call from the floating window (Android's "Rozłącz"
  /// button in picture-in-picture).
  Future<void> Function()? onHangUp;

  bool _callRunning = false;
  bool _video = false;

  /// Set by the desktop window bridge once the window plugin is ready, so
  /// tests and other platforms never touch it.
  bool desktopWindowReady = false;

  /// The window's normal minimum size (restored after the floating mode).
  Size desktopMinimumSize = const Size(390, 720);

  Rect? _savedBounds;
  bool _wasMaximized = false;
  bool _switching = false;

  bool get callRunning => _callRunning;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// The call UI reports the current call. On Android this arms (or
  /// disarms) picture-in-picture; when the call ends, the floating window
  /// on a computer goes back to normal.
  void updateCall({required bool running, required bool video}) {
    if (running == _callRunning && video == _video) {
      return;
    }
    _callRunning = running;
    _video = video;
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(setPictureInPictureCall(active: running, video: video));
    }
    if (!running && _isDesktop && active.value) {
      unawaited(exitDesktop());
    }
  }

  /// Android reports entering or leaving picture-in-picture.
  void reportPictureInPicture(bool inPip) {
    active.value = inPip && _callRunning;
  }

  /// Android's "Rozłącz" in the picture-in-picture window.
  Future<void> hangUpFromPictureInPicture() async {
    final Future<void> Function()? hangUp = onHangUp;
    if (hangUp != null) {
      await hangUp();
    }
  }

  /// Turns the window into the small floating call window (computers).
  Future<void> enterDesktop() async {
    if (!_isDesktop || !desktopWindowReady || active.value || _switching) {
      return;
    }
    _switching = true;
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      if (!await windowManager.isVisible()) {
        await windowManager.show();
      }
      _wasMaximized = await windowManager.isMaximized();
      if (_wasMaximized) {
        await windowManager.unmaximize();
      }
      _savedBounds = await windowManager.getBounds();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setMinimumSize(desktopAudioSize);
      await windowManager.setSize(_video ? desktopVideoSize : desktopAudioSize);
      await windowManager.setAlignment(Alignment.bottomRight);
      await windowManager.setAlwaysOnTop(true);
      active.value = true;
    } catch (error, stackTrace) {
      logZenError(
        'Entering the floating call window failed',
        error,
        stackTrace,
      );
    } finally {
      _switching = false;
    }
  }

  /// Brings the normal window back (computers).
  Future<void> exitDesktop() async {
    if (!_isDesktop || !desktopWindowReady || !active.value || _switching) {
      return;
    }
    _switching = true;
    try {
      active.value = false;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setMinimumSize(desktopMinimumSize);
      final Rect? bounds = _savedBounds;
      if (bounds != null) {
        await windowManager.setBounds(bounds);
      }
      if (_wasMaximized) {
        await windowManager.maximize();
      }
      await windowManager.focus();
    } catch (error, stackTrace) {
      logZenError('Leaving the floating call window failed', error, stackTrace);
    } finally {
      _switching = false;
    }
  }

  @visibleForTesting
  void resetForTest() {
    active.value = false;
    onHangUp = null;
    _callRunning = false;
    _video = false;
    desktopWindowReady = false;
    _savedBounds = null;
  }
}
