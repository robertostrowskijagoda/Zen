import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zen/src/core/utils/desktop_opener.dart';

/// How long text copied from the app stays in the system clipboard.
const Duration kClipboardTtl = Duration(seconds: 60);

/// Copies [text] and clears the clipboard after [ttl], unless something
/// else was copied in the meantime. Codes, addresses and keys do not linger
/// where other apps (or a spy) can read them: where the system can be told,
/// the text is marked as a secret too (Android 13+ hides it from the
/// clipboard preview and keyboards; Windows keeps it out of the clipboard
/// history and the cloud clipboard). Every copy of such text in the app
/// goes through here, never through `Clipboard.setData`.
Future<void> copyWithExpiry(String text, {Duration ttl = kClipboardTtl}) =>
    ExpiringClipboard.instance.copy(text, ttl: ttl);

/// Copies public text that is meant to be pasted elsewhere, possibly minutes
/// later in another app (an invitation link: the person's address in the
/// network, the same thing the QR code shows to anyone). It is not cleared;
/// a secret copied before it is gone from the clipboard anyway.
Future<void> copyPublicText(String text) =>
    ExpiringClipboard.instance.copyPublic(text);

/// Clears the clipboard now if it still holds what the app last copied:
/// when the app locks, and when the account is left or wiped.
Future<void> clearCopiedNow() => ExpiringClipboard.instance.clearNow();

/// Puts [text] on the system clipboard marked as a secret; false where
/// this system has no such call (the plain clipboard is used then).
Future<bool> writeMarkedSecret(String text) async {
  if (kIsWeb) {
    return false;
  }
  final MethodChannel? channel = switch (defaultTargetPlatform) {
    TargetPlatform.android => const MethodChannel('zen/system'),
    TargetPlatform.windows => const MethodChannel('zen/clipboard'),
    _ => null,
  };
  if (channel == null) {
    return false;
  }
  try {
    return await channel.invokeMethod<bool>('copySensitive', <String, Object?>{
          'text': text,
        }) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// The system clipboard as [ExpiringClipboard] uses it (replaceable in tests).
abstract interface class ClipboardAccess {
  Future<void> write(String text);

  /// The text on the clipboard; `null` when there is none or it cannot be
  /// read (Android hides it from an app in the background).
  Future<String?> read();
}

final class _SystemClipboard implements ClipboardAccess {
  const _SystemClipboard();

  @override
  Future<void> write(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String?> read() async {
    try {
      return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on PlatformException {
      return null;
    }
  }
}

/// Remembers the last text it copied and clears it after its time is up.
/// A phone that put the app in the background when the timer fired cannot
/// touch the clipboard then (Android 10+); the clearing is retried when the
/// app is back in front.
final class ExpiringClipboard with WidgetsBindingObserver {
  /// [writeSensitive] puts a secret on the clipboard marked as one and
  /// answers false where it cannot (then [access] writes it plainly); by
  /// default the system's own call with the system clipboard ([access]
  /// left out, outside `flutter test`, where no platform answers), none
  /// otherwise.
  ExpiringClipboard({
    ClipboardAccess? access,
    bool Function()? isInForeground,
    Future<bool> Function(String text)? writeSensitive,
  }) : _access = access ?? const _SystemClipboard(),
       _writeSensitive =
           writeSensitive ??
           (access == null && !runningUnderFlutterTest
               ? writeMarkedSecret
               : _cannotMark),
       _isInForeground = isInForeground ?? _bindingInForeground;

  static final ExpiringClipboard instance = ExpiringClipboard();

  final ClipboardAccess _access;
  final Future<bool> Function(String text) _writeSensitive;
  final bool Function() _isInForeground;

  static Future<bool> _cannotMark(String text) async => false;

  Timer? _timer;
  String? _pending;
  DateTime? _deadline;
  bool _observing = false;

  static bool _bindingInForeground() {
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Text that is waiting to be cleared (tests).
  String? get pendingText => _pending;

  Future<void> copy(String text, {Duration ttl = kClipboardTtl}) async {
    if (!await _writeSensitive(text)) {
      await _access.write(text);
    }
    _timer?.cancel();
    _pending = text;
    _deadline = DateTime.now().add(ttl);
    _timer = Timer(ttl, () => unawaited(_expire()));
    if (!_observing) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } on Object {
        // No binding (a plain unit test): the timer alone does the job.
      }
    }
  }

  /// Copies [text] without clearing it later (see [copyPublicText]).
  Future<void> copyPublic(String text) async {
    await _access.write(text);
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _deadline = null;
  }

  /// Clears it as if its time were up now: from the background (where a
  /// phone hides the clipboard) it is cleared when the app is back.
  Future<void> clearNow() async {
    _timer?.cancel();
    if (_pending == null) {
      return;
    }
    _deadline = DateTime.now();
    await _expire();
  }

  Future<void> _expire() async {
    final String? text = _pending;
    if (text == null) {
      return;
    }
    final String? now = await _access.read();
    if (now == text) {
      try {
        await _access.write('');
      } on PlatformException {
        if (!_isInForeground()) {
          return;
        }
      }
    } else if (now == null && !_isInForeground()) {
      // Cannot see it from the background: try again when we are back.
      return;
    }
    if (_pending == text) {
      _pending = null;
      _deadline = null;
      _timer?.cancel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final DateTime? deadline = _deadline;
    if (state == AppLifecycleState.resumed &&
        _pending != null &&
        deadline != null &&
        !DateTime.now().isBefore(deadline)) {
      unawaited(_expire());
    }
  }
}
