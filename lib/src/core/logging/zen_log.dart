import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// Rolling on-device log of the UI isolate and the foreground service
/// isolate.
///
/// The background runtime does most of its work with no UI attached and no
/// debugger in reach, so a failure there is otherwise invisible: the user just
/// sees a call that never rings. Each isolate appends to a file of its own in
/// the app support directory (`zen-diagnostics-<source>.log`), so neither
/// ever cuts into the other's lines; when a file grows past
/// [fileLimitBytes] it becomes `<file>.1` (replacing the one before) and a
/// new one starts. The settings screen reads all of them back as one log,
/// in time order.
abstract final class ZenDiagnosticsLog {
  /// What every file of the log is named after.
  static const String filePrefix = 'zen-diagnostics';

  /// How large a file grows before it is set aside as `<file>.1`: each
  /// isolate keeps at most about twice this. Tests lower it.
  static int fileLimitBytes = 512 * 1024;

  /// The current file of [source] (`ui`, `svc`).
  static String fileNameFor(String source) => '$filePrefix-$source.log';

  static File? _file;
  static String _source = 'app';
  static Future<void> _writes = Future<void>.value();

  /// The app's own folders and the user's home, cut down in every line (see
  /// [redactDiagnosticsText]).
  static List<String> _privatePlaces = const <String>[];
  static String? _home;

  /// Lines written before [attach] (the first moments of a start, before
  /// the data folder is known), the latest [earlyLineLimit] of them, with
  /// the time they were written. They go into the file when the log is
  /// attached: without them a start whose window came up before its data
  /// folder was ready reads as if it stopped at the attach.
  static final List<(DateTime, String)> _early = <(DateTime, String)>[];

  /// How many lines written before [attach] are kept for it.
  static const int earlyLineLimit = 200;

  static File? get file => _file;

  /// Completes once every line this isolate queued so far is written.
  static Future<void> get settled => _writes;

  /// Points the log at [supportDirectory]. [source] names this isolate's
  /// file and tags every line, so the two isolates can be told apart when
  /// reading the log back.
  static Future<void> attach(
    Directory supportDirectory, {
    required String source,
  }) async {
    try {
      final File target = File(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '${fileNameFor(source)}',
      );
      await target.parent.create(recursive: true);
      _source = source;
      _privatePlaces = diagnosticsPrivatePlaces(supportDirectory.path);
      _home = _homeDirectory();
      _file = target;
      write(
        '--- $source attached (Zen $kAppVersion+$kAppBuild, '
        '${Platform.operatingSystemVersion}) ---',
      );
      final List<(DateTime, String)> early = List<(DateTime, String)>.of(
        _early,
      );
      _early.clear();
      // In one write: a slow disk (or a scanner holding the file) then
      // costs one wait, not one per line.
      final StringBuffer batch = StringBuffer();
      for (final (DateTime time, String line) in early) {
        batch.write(_entry(time, line));
      }
      if (batch.isNotEmpty) {
        _queue(target, batch.toString());
      }
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
      if (_early.length >= earlyLineLimit) {
        _early.removeAt(0);
      }
      _early.add((DateTime.now(), line));
      return;
    }
    _append(target, DateTime.now(), line);
  }

  /// Queues [line], written at [time], for [target] (redacted here: an
  /// early line only once the app's folders are known).
  static void _append(File target, DateTime time, String line) {
    _queue(target, _entry(time, line));
  }

  /// One line of the file, redacted.
  static String _entry(DateTime time, String line) {
    final String redacted = redactDiagnosticsText(
      line,
      privatePlaces: _privatePlaces,
      homeDirectory: _home,
    );
    return '${time.toIso8601String()} [$_source] '
        '$redacted\n';
  }

  /// Appends [entry] after everything queued before it.
  static void _queue(File target, String entry) {
    _writes = _writes
        .then((_) => _appendEntry(target, entry))
        .catchError((Object _) {});
  }

  static Future<void> _appendEntry(File target, String entry) async {
    // On Windows another process (a virus scanner, the indexer) may hold
    // the file for a moment: try again shortly instead of losing the line.
    for (int attempt = 1; ; attempt++) {
      try {
        await target.writeAsString(entry, mode: FileMode.append, flush: false);
        break;
      } on FileSystemException {
        if (attempt >= 5) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
      }
    }
    if (await target.length() <= fileLimitBytes) {
      return;
    }
    // Only this isolate writes this file, so setting it aside cannot cut
    // into anyone's line; a rename that fails (a scanner holding the file)
    // is tried again on the next line.
    final File previous = File('${target.path}.1');
    if (await previous.exists()) {
      await previous.delete();
    }
    await target.rename(previous.path);
  }

  /// The log's files in [folder] by source, each source's older file
  /// first.
  static Future<Map<String, List<File>>> _files(Directory folder) async {
    final RegExp name = RegExp(
      '^${RegExp.escape(filePrefix)}-([a-z0-9]+)\\.log(\\.1)?\$',
    );
    final Map<String, List<File>> bySource = <String, List<File>>{};
    if (!await folder.exists()) {
      return bySource;
    }
    final List<(String, bool, File)> found = <(String, bool, File)>[];
    await for (final FileSystemEntity entity in folder.list()) {
      if (entity is! File) {
        continue;
      }
      final RegExpMatch? match = name.firstMatch(_nameOf(entity));
      if (match != null) {
        found.add((match[1]!, match[2] != null, entity));
      }
    }
    found.sort(((String, bool, File) a, (String, bool, File) b) {
      final int bySourceName = a.$1.compareTo(b.$1);
      if (bySourceName != 0 || a.$2 == b.$2) {
        return bySourceName;
      }
      return a.$2 ? -1 : 1;
    });
    for (final (String source, bool _, File file) in found) {
      bySource.putIfAbsent(source, () => <File>[]).add(file);
    }
    return bySource;
  }

  /// Every entry of the log (a line, with the stack frames under it), of
  /// both isolates, oldest first. Empty when nothing has been recorded yet.
  /// Lines are redacted when written.
  static Future<List<String>> entries() async {
    final File? target = _file;
    if (target == null) {
      // Not attached yet (a start that waits before its data folder is
      // known): what was written so far, so that "Zapisz dziennik" on the
      // slow-start screen still says something.
      return <String>[
        for (final (DateTime time, String line) in _early)
          _entry(time, line).trimRight(),
      ];
    }
    final List<String> texts = <String>[];
    for (final List<File> files in (await _files(target.parent)).values) {
      final StringBuffer text = StringBuffer();
      for (final File file in files) {
        try {
          // A line cut short by the process ending must not lose the rest.
          text.write(
            utf8.decode(await file.readAsBytes(), allowMalformed: true),
          );
        } on FileSystemException {
          // Set aside or deleted meanwhile: the rest still reads.
        }
      }
      texts.add(text.toString());
    }
    return mergeDiagnosticsLogs(texts);
  }

  /// Reads the log back as text, newest content last (see [entries]).
  /// Returns an empty string when nothing has been recorded yet.
  static Future<String> read() async {
    try {
      final List<String> all = await entries();
      return all.isEmpty ? '' : '${all.join('\n')}\n';
    } catch (error) {
      return t('Nie udało się odczytać dziennika: {error}', {'error': error});
    }
  }

  /// Deletes the log, both isolates' files: the settings' "clear", and
  /// every wipe of the app's data (the panic password's too). Queued after
  /// the lines already written, so none of them brings a file back
  /// afterwards.
  static Future<void> clear() async {
    _early.clear();
    final File? target = _file;
    if (target == null) {
      return;
    }
    final Future<void> cleared = _writes.then((_) => _delete(target.parent));
    _writes = cleared.catchError((Object _) {});
    try {
      await cleared;
    } catch (error) {
      _console('[ZEN] Clearing the diagnostics log failed: $error');
    }
  }

  static Future<void> _delete(Directory folder) async {
    if (!await folder.exists()) {
      return;
    }
    await for (final FileSystemEntity entity in folder.list()) {
      // The log's files and what the technical log keeps beside them.
      if (entity is File && _nameOf(entity).startsWith(filePrefix)) {
        await entity.delete();
      }
    }
  }

  static String _nameOf(File file) => file.path.split(RegExp(r'[/\\]')).last;
}

/// The logs of several isolates ([texts], each in the order it was
/// written) as one, by time: entry by entry (a line starting with its
/// time, with the lines under it that do not), each log's own order kept.
@visibleForTesting
List<String> mergeDiagnosticsLogs(List<String> texts) {
  final List<List<String>> logs = <List<String>>[
    for (final String text in texts) _entriesOf(text),
  ];
  final List<int> next = List<int>.filled(logs.length, 0);
  final List<String> merged = <String>[];
  while (true) {
    int? pick;
    for (int i = 0; i < logs.length; i++) {
      if (next[i] >= logs[i].length) {
        continue;
      }
      if (pick == null ||
          _timeOf(logs[i][next[i]]).compareTo(_timeOf(logs[pick][next[pick]])) <
              0) {
        pick = i;
      }
    }
    if (pick == null) {
      return merged;
    }
    merged.add(logs[pick][next[pick]]);
    next[pick] += 1;
  }
}

final RegExp _entryStart = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d');

List<String> _entriesOf(String text) {
  final List<String> entries = <String>[];
  for (final String line in const LineSplitter().convert(text)) {
    if (line.isEmpty) {
      continue;
    }
    if (entries.isEmpty || _entryStart.hasMatch(line)) {
      entries.add(line);
    } else {
      entries.last = '${entries.last}\n$line';
    }
  }
  return entries;
}

/// The time an entry starts with (ISO 8601, local: such times sort as
/// text).
String _timeOf(String entry) {
  final int space = entry.indexOf(' ');
  return space < 0 ? entry : entry.substring(0, space);
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

/// [text] as the diagnostics log keeps it, readable outside the
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
