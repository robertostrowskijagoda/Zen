import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Rolling on-device log shared by the UI isolate and the foreground service
/// isolate.
///
/// The background runtime does most of its work with no UI attached and no
/// debugger in reach, so a failure there is otherwise invisible: the user just
/// sees a call that never rings. Both isolates append to one file in the app
/// support directory, and the settings screen can read it back.
abstract final class ZenDiagnosticsLog {
  static const String fileName = 'zen-diagnostics.log';

  /// Size the log is trimmed back to, and the point at which trimming kicks in
  /// (at twice this, so trims stay rare).
  static const int keepBytes = 128 * 1024;

  static File? _file;
  static String _source = 'app';
  static Future<void> _writes = Future<void>.value();

  static File? get file => _file;

  /// Points the log at [supportDirectory]. [source] tags every line so the two
  /// isolates can be told apart when reading the file back.
  static Future<void> attach(
    Directory supportDirectory, {
    required String source,
  }) async {
    try {
      final File target = File(
        '${supportDirectory.path}${Platform.pathSeparator}$fileName',
      );
      await target.parent.create(recursive: true);
      _source = source;
      _file = target;
      write('--- $source attached (${Platform.operatingSystemVersion}) ---');
    } catch (error) {
      _console('[ZEN] Attaching the diagnostics log failed: $error');
    }
  }

  /// Appends one line. Fire-and-forget: logging must never fail a caller, and
  /// must never block the runtime it is observing.
  static void write(String line) {
    final File? target = _file;
    if (target == null) {
      return;
    }
    final String entry =
        '${DateTime.now().toIso8601String()} [$_source] '
        '${redactPeerAddresses(line)}\n';
    _writes = _writes
        .then((_) => _append(target, entry))
        .catchError((Object _) {});
  }

  static Future<void> _append(File target, String entry) async {
    await target.writeAsString(entry, mode: FileMode.append, flush: false);
    final int length = await target.length();
    if (length <= keepBytes * 2) {
      return;
    }
    // Trim through a temp file + rename: the rename is atomic, so the other
    // isolate never observes a half-written log.
    final String contents = await target.readAsString();
    final String trimmed = contents.substring(
      contents.length > keepBytes ? contents.length - keepBytes : 0,
    );
    final int newlineIndex = trimmed.indexOf('\n');
    final File temp = File('${target.path}.tmp');
    await temp.writeAsString(
      newlineIndex >= 0 ? trimmed.substring(newlineIndex + 1) : trimmed,
      flush: true,
    );
    await temp.rename(target.path);
  }

  /// Reads the log back, newest content last. Returns an empty string when
  /// nothing has been recorded yet.
  static Future<String> read() async {
    final File? target = _file;
    if (target == null) {
      return '';
    }
    try {
      if (!await target.exists()) {
        return '';
      }
      return await target.readAsString();
    } catch (error) {
      return 'Nie udało się odczytać dziennika: $error';
    }
  }

  static Future<void> clear() async {
    final File? target = _file;
    if (target == null) {
      return;
    }
    try {
      if (await target.exists()) {
        await target.delete();
      }
    } catch (error) {
      _console('[ZEN] Clearing the diagnostics log failed: $error');
    }
  }
}

/// Console output (logcat on Android) for development only.
///
/// `debugPrint` is not stripped from release builds, and logcat can be read
/// over adb or by OEM log collectors - with peer addresses and names in it.
/// Release builds keep only the on-device diagnostics log, which is redacted
/// (see [redactPeerAddresses]).
void _console(String line) {
  if (kReleaseMode) {
    return;
  }
  debugPrint(line);
}

/// Mesh addresses (Yggdrasil, `200::/7`) in [text], cut down to their first
/// two groups: still enough to tell peers apart while reading a log, no
/// longer enough to identify (or contact) one.
String redactPeerAddresses(String text) {
  return text.replaceAllMapped(_peerAddressPattern, (Match match) {
    final List<String> groups = match[0]!.split(':');
    final String second = groups.length > 1 ? groups[1] : '';
    return second.isEmpty ? '${groups[0]}:…' : '${groups[0]}:$second:…';
  });
}

/// A `2xx:` / `3xx:` IPv6 address (full or `::`-compressed), not glued to
/// other hex digits, colons or word characters on either side.
final RegExp _peerAddressPattern = RegExp(
  r'(?<![0-9A-Za-z:_])[23][0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Za-z_])',
);

void logZenError(
  String message,
  Object error,
  StackTrace stackTrace, {
  String tag = 'ZEN',
}) {
  _console('[$tag] $message: $error');
  if (!kReleaseMode) {
    debugPrintStack(label: '[$tag] $message', stackTrace: stackTrace);
  }
  ZenDiagnosticsLog.write('ERROR $message: $error\n${_topFrames(stackTrace)}');
}

void logZenMessage(String message, {String tag = 'ZEN'}) {
  _console('[$tag] $message');
  ZenDiagnosticsLog.write('INFO  $message');
}

void logZenWarning(String message, {String tag = 'ZEN'}) {
  _console('[$tag][WARN] $message');
  ZenDiagnosticsLog.write('WARN  $message');
}

/// Just enough of the stack to locate the failure without filling the log.
String _topFrames(StackTrace stackTrace, {int count = 6}) {
  final List<String> lines = stackTrace
      .toString()
      .split('\n')
      .where((String line) => line.trim().isNotEmpty)
      .take(count)
      .toList(growable: false);
  return lines.map((String line) => '    $line').join('\n');
}

void unawaitedLogged(
  Future<void>? future, {
  required String context,
  String tag = 'ZEN',
}) {
  if (future == null) {
    return;
  }
  unawaited(
    future.catchError((Object error, StackTrace stackTrace) {
      logZenError(context, error, stackTrace, tag: tag);
    }),
  );
}
