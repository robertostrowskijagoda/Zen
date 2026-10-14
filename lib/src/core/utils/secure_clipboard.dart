import 'dart:async';

import 'package:flutter/services.dart';

/// How long text copied from the app stays in the system clipboard (§14.1).
const Duration kClipboardTtl = Duration(seconds: 60);

Timer? _clearTimer;

/// Copies [text] and clears the clipboard after [ttl], unless something
/// else was copied in the meantime. Codes and messages do not linger where
/// other apps (or a spy) can read them.
Future<void> copyWithExpiry(String text, {Duration ttl = kClipboardTtl}) async {
  await Clipboard.setData(ClipboardData(text: text));
  _clearTimer?.cancel();
  _clearTimer = Timer(ttl, () async {
    try {
      final ClipboardData? now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } on PlatformException {
      // No clipboard access in the background: nothing to do.
    }
  });
}
