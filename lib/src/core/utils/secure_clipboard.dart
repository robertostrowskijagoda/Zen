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
///
/// False when the text did not reach the clipboard: where the system can
/// mark a secret and the marked copy failed, the text is not put on the
/// plain clipboard instead (on Windows the history and the cloud clipboard
/// would keep it), and the caller tells the person.
Future<bool> copyWithExpiry(String text, {Duration ttl = kClipboardTtl}) =>
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

/// The channel of the system's own clipboard calls for secrets, where the
/// runner has them (Android, Windows).
MethodChannel? get _secretChannel {
  if (kIsWeb) {
    return null;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => const MethodChannel('zen/system'),
    TargetPlatform.windows => const MethodChannel('zen/clipboard'),
    _ => null,
  };
}

/// Puts [text] on the system clipboard marked as a secret: true when done;
/// false when this system has such a call and it failed (the secret then
/// goes nowhere); null where the system has no such call (Linux, macOS,
/// iOS: the plain clipboard is used then).
Future<bool?> writeMarkedSecret(String text) async {
  final MethodChannel? channel = _secretChannel;
  if (channel == null) {
    return null;
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

/// Empties the system clipboard with the system's own call: true when done,
/// false where there is none or it failed ([ExpiringClipboard] then writes
/// an empty text). Android empties it from the background too, where an
/// app may write the clipboard but not read it; Windows waits a moment for
/// another program that holds the clipboard open.
Future<bool> clearSystemClipboard() async {
  final MethodChannel? channel = _secretChannel;
  if (channel == null) {
    return false;
  }
  try {
    return await channel.invokeMethod<bool>('clearSensitive') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Whether this system hides the clipboard from an app in the background
/// (Android 10+ answers no text at all), so that from there it cannot be
/// seen whether the secret is still on it.
bool _backgroundHidesClipboardHere() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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

/// Remembers the last text it copied and clears it after its time is up,
/// or at once when the app locks.
///
/// Where the clipboard can be read, it is cleared only while it still
/// holds that text. A phone that hides the clipboard from an app in the
/// background (Android 10+) still lets it write there, and Zen locks
/// exactly while it is in the background: there the clipboard is emptied
/// without looking, since waiting for the app to come back would leave the
/// secret for whatever app is in front, and for good if the system ends
/// Zen meanwhile. So that this does not wipe something the person copied
/// in Zen after the secret, the clipboard is looked at once more as Zen is
/// left, while it can still be read; what the person copies in another
/// app afterwards cannot be told apart and goes with the secret.
/// Elsewhere a clipboard that shows no text to the app in the background
/// is looked at again when the app is back in front (an iPhone stops Zen
/// in the background anyway).
final class ExpiringClipboard with WidgetsBindingObserver {
  /// [writeSensitive] puts a secret on the clipboard marked as one (see
  /// [writeMarkedSecret]: null where it cannot, then [access] writes it
  /// plainly) and [clearSystem] empties it with the system's own call (see
  /// [clearSystemClipboard]); by default the system's calls with the system
  /// clipboard ([access] left out, outside `flutter test`, where no
  /// platform answers), none otherwise. [backgroundHidesClipboard] tells
  /// whether a read from the background sees nothing (Android by default).
  ExpiringClipboard({
    ClipboardAccess? access,
    bool Function()? isInForeground,
    Future<bool?> Function(String text)? writeSensitive,
    Future<bool> Function()? clearSystem,
    bool Function()? backgroundHidesClipboard,
  }) : _access = access ?? const _SystemClipboard(),
       _writeSensitive =
           writeSensitive ??
           (access == null && !runningUnderFlutterTest
               ? writeMarkedSecret
               : _cannotMark),
       _clearSystem =
           clearSystem ??
           (access == null && !runningUnderFlutterTest
               ? clearSystemClipboard
               : _cannotClear),
       _isInForeground = isInForeground ?? _bindingInForeground,
       _backgroundHidesClipboard =
           backgroundHidesClipboard ?? _backgroundHidesClipboardHere;

  static final ExpiringClipboard instance = ExpiringClipboard();

  final ClipboardAccess _access;
  final Future<bool?> Function(String text) _writeSensitive;
  final Future<bool> Function() _clearSystem;
  final bool Function() _isInForeground;
  final bool Function() _backgroundHidesClipboard;

  static Future<bool?> _cannotMark(String text) async => null;

  static Future<bool> _cannotClear() async => false;

  Timer? _timer;
  String? _pending;
  DateTime? _deadline;
  bool _observing = false;
  AppLifecycleState? _lastState;

  static bool _bindingInForeground() {
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Text that is waiting to be cleared (tests).
  String? get pendingText => _pending;

  /// Copies [text] (see [copyWithExpiry]); false when it is not on the
  /// clipboard.
  Future<bool> copy(String text, {Duration ttl = kClipboardTtl}) async {
    final bool? marked = await _writeSensitive(text);
    if (marked == false) {
      return false;
    }
    if (marked == null) {
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
    return true;
  }

  /// Copies [text] without clearing it later (see [copyPublicText]).
  Future<void> copyPublic(String text) async {
    await _access.write(text);
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _deadline = null;
  }

  /// Clears it as if its time were up now (see the class comment for the
  /// background).
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
    final bool unseen = now == null && !_isInForeground();
    if (unseen && !_backgroundHidesClipboard()) {
      // Cannot see it from the background: try again when we are back.
      return;
    }
    if (now == text || unseen) {
      if (!await _clear()) {
        // Still on the clipboard: tried again at the next change of the
        // app's state, or the next lock.
        return;
      }
    }
    _forget(text);
  }

  /// Empties the clipboard: the system's own call where there is one, an
  /// empty text otherwise. False when neither got through.
  Future<bool> _clear() async {
    if (await _clearSystem()) {
      return true;
    }
    try {
      await _access.write('');
      return true;
    } on PlatformException {
      return false;
    }
  }

  void _forget(String text) {
    if (_pending == text) {
      _pending = null;
      _deadline = null;
      _timer?.cancel();
    }
  }

  /// Zen is being left: if the clipboard can still be read and holds
  /// something else than the secret now (copied in Zen after it), that is
  /// the person's and is not wiped from the background later.
  Future<void> _lookBeforeLeaving() async {
    final String? text = _pending;
    if (text == null) {
      return;
    }
    final String? now = await _access.read();
    if (now != null && now != text) {
      _forget(text);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final AppLifecycleState? before = _lastState;
    _lastState = state;
    if (_pending == null) {
      return;
    }
    final DateTime? deadline = _deadline;
    final bool due = deadline != null && !DateTime.now().isBefore(deadline);
    if (due && state != AppLifecycleState.inactive) {
      // Back in front, or just left with the time already up.
      unawaited(_expire());
    } else if (!due &&
        state == AppLifecycleState.inactive &&
        (before ?? AppLifecycleState.resumed) == AppLifecycleState.resumed &&
        _backgroundHidesClipboard()) {
      unawaited(_lookBeforeLeaving());
    }
  }
}
