import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

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

  /// The app's own folders and the user's home, cut down in every line (see
  /// [redactDiagnosticsText]).
  static List<String> _privatePlaces = const <String>[];
  static String? _home;

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
      _privatePlaces = diagnosticsPrivatePlaces(supportDirectory.path);
      _home = _homeDirectory();
      _file = target;
      write('--- $source attached (${Platform.operatingSystemVersion}) ---');
    } catch (error) {
      _console('[ZEN] Attaching the diagnostics log failed: $error');
    }
  }

  /// The user's home folder (it holds the user's name on a computer), when
  /// it is a real one: not `/` or a single folder.
  static String? _homeDirectory() {
    final Map<String, String> environment = Platform.environment;
    final String? home = Platform.isWindows
        ? environment['USERPROFILE']
        : environment['HOME'];
    if (home == null) {
      return null;
    }
    final int depth = home
        .split(RegExp(r'[/\\]'))
        .where((String part) => part.isNotEmpty)
        .length;
    return depth >= 2 ? home.replaceFirst(RegExp(r'[/\\]+$'), '') : null;
  }

  /// Appends one line. Fire-and-forget: logging must never fail a caller, and
  /// must never block the runtime it is observing.
  static void write(String line) {
    final File? target = _file;
    if (target == null) {
      return;
    }
    final String redacted = redactDiagnosticsText(
      line,
      privatePlaces: _privatePlaces,
      homeDirectory: _home,
    );
    final String entry =
        '${DateTime.now().toIso8601String()} [$_source] '
        '$redacted\n';
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
  /// nothing has been recorded yet. Lines written by an older version,
  /// before the redaction covered URLs and paths, are redacted here too.
  static Future<String> read() async {
    final File? target = _file;
    if (target == null) {
      return '';
    }
    try {
      if (!await target.exists()) {
        return '';
      }
      return redactDiagnosticsText(
        await target.readAsString(),
        privatePlaces: _privatePlaces,
        homeDirectory: _home,
      );
    } catch (error) {
      return t('Nie udało się odczytać dziennika: {error}', {'error': error});
    }
  }

  /// Deletes the log: the settings' "clear", and every wipe of the app's
  /// data (the panic password's too). Queued after the lines already
  /// written, so none of them brings the file back afterwards.
  static Future<void> clear() async {
    final File? target = _file;
    if (target == null) {
      return;
    }
    final Future<void> cleared = _writes.then((_) => _delete(target));
    _writes = cleared.catchError((Object _) {});
    try {
      await cleared;
    } catch (error) {
      _console('[ZEN] Clearing the diagnostics log failed: $error');
    }
  }

  static Future<void> _delete(File target) async {
    // The trim's temporary copy too, if one was left behind.
    for (final File file in <File>[target, File('${target.path}.tmp')]) {
      if (await file.exists()) {
        await file.delete();
      }
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

/// [text] as the diagnostics log keeps it (S-16), readable outside the
/// encrypted data:
///  - paths under the app's own folders ([privatePlaces], see
///    [diagnosticsPrivatePlaces]) become `<app>/<first folder>/…`: file
///    names there can be what someone sent;
///  - the user's home folder ([homeDirectory]) becomes `~`;
///  - URLs (bridges, peers, routers) keep only their scheme: `tls://…`;
///  - mesh addresses keep two groups ([redactPeerAddresses]), other IP
///    addresses one (loopback stays as it is).
String redactDiagnosticsText(
  String text, {
  List<String> privatePlaces = const <String>[],
  String? homeDirectory,
}) {
  String result = text;
  for (final String place in privatePlaces) {
    result = _cutPrivatePaths(result, place);
  }
  if (homeDirectory != null && homeDirectory.isNotEmpty) {
    result = result.replaceAll(
      _compiled('${RegExp.escape(homeDirectory)}(?![A-Za-z0-9_.-])'),
      '~',
    );
  }
  result = result.replaceAllMapped(
    _urlPattern,
    (Match match) => '${match[1]}://…',
  );
  result = redactPeerAddresses(result);
  result = result.replaceAllMapped(_ipv4Pattern, (Match match) {
    final String address = match[0]!;
    return address.startsWith('127.') || address == '0.0.0.0'
        ? address
        : '${match[1]}.…';
  });
  return result.replaceAllMapped(_ipv6Pattern, (Match match) {
    final String address = match[0]!;
    if (address == '::1') {
      return address;
    }
    return address.startsWith('::')
        ? '::…'
        : '${address.substring(0, address.indexOf(':'))}:…';
  });
}

/// The app's own folders for a support folder at [supportPath], as
/// regular expressions for [redactDiagnosticsText]: on Android the whole
/// `/data/user/<n>/<package>` (and the same package under `Android/data`),
/// on iOS the app's container, on a computer the support folder (without a
/// `profiles/<name>` of a second instance).
List<String> diagnosticsPrivatePlaces(String supportPath) {
  final String path = supportPath.replaceFirst(RegExp(r'[/\\]+$'), '');
  final RegExpMatch? android = RegExp(
    r'^/data/(?:user(?:_de)?/\d+|data)/([^/]+)',
  ).firstMatch(path);
  if (android != null) {
    final String appId = RegExp.escape(android[1]!);
    return <String>[
      '/data/(?:user(?:_de)?/\\d+|data)/$appId',
      '/(?:storage/emulated/\\d+|sdcard)/Android/(?:data|media|obb)/$appId',
    ];
  }
  if (path.contains('/Containers/Data/Application/')) {
    return <String>[
      r'(?:/[^/\s]+)*?/Containers/(?:Data|Shared)/(?:Application|AppGroup)/[0-9A-Fa-f-]+',
    ];
  }
  return <String>[
    RegExp.escape(path.replaceFirst(RegExp(r'[/\\]profiles[/\\][^/\\]+$'), '')),
  ];
}

/// Every path under [place] in [text], cut down to the folder right under
/// it. A quoted path (as in `FileSystemException`) is taken up to its
/// closing quote, so a file name with spaces goes whole.
String _cutPrivatePaths(String text, String place) {
  String shorten(String? rest) {
    if (rest == null || rest.isEmpty) {
      return '';
    }
    final String separator = rest[0];
    final List<String> parts = rest
        .split(RegExp(r'[/\\]'))
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return separator;
    }
    return parts.length == 1
        ? '$separator${parts.first}'
        : '$separator${parts.first}$separator…';
  }

  String result = text;
  for (final String quote in const <String>["'", '"']) {
    result = result.replaceAllMapped(
      _compiled('$quote(?:$place)(${r'[/\\]'}[^$quote\\n]*)?$quote'),
      (Match match) => '$quote<app>${shorten(match[1])}$quote',
    );
  }
  return result.replaceAllMapped(
    _compiled('(?:$place)$_pathEndAhead(${r'[/\\]'}$_unquotedPathChars)?'),
    (Match match) => '<app>${shorten(match[1])}',
  );
}

/// The expressions built from the places and the home folder (paths:
/// any case), compiled once — every log line goes through them.
final Map<String, RegExp> _compiledPatterns = <String, RegExp>{};

RegExp _compiled(String source) {
  if (_compiledPatterns.length > 64) {
    _compiledPatterns.clear();
  }
  return _compiledPatterns.putIfAbsent(
    source,
    () => RegExp(source, caseSensitive: false),
  );
}

/// Where a folder's name ends in running text.
const String _pathEndAhead = r'''(?=[/\\\s'",;:()\[\]{}<>]|$)''';

/// What an unquoted path is made of (it stops at a space).
const String _unquotedPathChars = r'''[^\s'",;:()\[\]{}<>]*''';

/// `scheme://anything` up to a space, quote or bracket.
final RegExp _urlPattern = RegExp(
  r'''(?<![A-Za-z0-9+.\-])([A-Za-z][A-Za-z0-9+.\-]{1,15})://[^\s'"<>(),]+''',
);

/// A dotted IPv4 address, not part of a longer dotted number.
final RegExp _ipv4Pattern = RegExp(
  r'(?<![0-9A-Za-z.])(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
  r'(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(?![0-9]|\.[0-9])',
);

/// Any other IPv6 address (and MAC-like runs of hex pairs): five groups or
/// more, or `::`-compressed. A clock time (`23:29:01`) has too few groups.
final RegExp _ipv6Pattern = RegExp(
  r'(?<![0-9A-Za-z:_.])('
  r'(?:[0-9A-Fa-f]{1,4}:){4,7}[0-9A-Fa-f]{1,4}'
  r'|(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,5})?'
  r'|::[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}'
  r')(?![0-9A-Za-z_:])',
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
