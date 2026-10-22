import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// How long text copied from the app stays in the system clipboard.
const Duration kClipboardTtl = Duration(seconds: 60);

/// Copies [text] and clears the clipboard after [ttl], unless something
/// else was copied in the meantime. Codes, addresses and keys do not linger
/// where other apps (or a spy) can read them. Every copy of such text in
/// the app goes through here, never through `Clipboard.setData`.
Future<void> copyWithExpiry(String text, {Duration ttl = kClipboardTtl}) =>
    ExpiringClipboard.instance.copy(text, ttl: ttl);

/// Copies public text that is meant to be pasted elsewhere, possibly minutes
/// later in another app (an invitation link: the person's address in the
/// network, the same thing the QR code shows to anyone). It is not cleared;
/// a secret copied before it is gone from the clipboard anyway.
Future<void> copyPublicText(String text) =>
    ExpiringClipboard.instance.copyPublic(text);

/// Clears the clipboard now if it still holds what the app last copied
/// (for example when the app locks).
Future<void> clearCopiedNow() => ExpiringClipboard.instance.clearNow();

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
  ExpiringClipboard({
    ClipboardAccess access = const _SystemClipboard(),
    bool Function()? isInForeground,
  }) : _access = access,
       _isInForeground = isInForeground ?? _bindingInForeground;

  static final ExpiringClipboard instance = ExpiringClipboard();

  final ClipboardAccess _access;
  final bool Function() _isInForeground;

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
    await _access.write(text);
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

  Future<void> clearNow() async {
    _timer?.cancel();
    await _expire(force: true);
  }

  Future<void> _expire({bool force = false}) async {
    final String? text = _pending;
    if (text == null) {
      return;
    }
    final String? now = await _access.read();
    if (now == text) {
      try {
        await _access.write('');
      } on PlatformException {
        if (!force && !_isInForeground()) {
          return;
        }
      }
    } else if (now == null && !force && !_isInForeground()) {
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
