import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Technical events in the diagnostics log ([ZenDiagnosticsLog]): what the
/// background work did and what the mesh node held, to find out afterwards
/// why a phone was ended, stayed awake or moved a lot of data at night.
///
/// Every line reads `TECH  <event> key=value …`, and a value can only be a
/// number, yes/no, a time or a short fixed word (a job's or a mode's name):
/// never a message, a name, an address, a key or a file name, whatever a
/// caller passes ([formatTechLine] writes anything else as `?`).
///
/// It costs no wake of its own: events are written when they happen, and
/// the node is sampled ([node]) from the node reads that run anyway.
abstract final class ZenTechLog {
  /// How often a running node's numbers are written at most.
  static const Duration nodeSampleEvery = Duration(minutes: 5);

  static String? _mode;
  static final Map<int, DateTime> _sampledAt = <int, DateTime>{};

  /// Writes [event] with [fields] (see [formatTechLine]).
  static void event(String event, [Map<String, Object?> fields = const {}]) {
    ZenDiagnosticsLog.write(formatTechLine(event, fields));
  }

  /// This isolate's runtime is now in [mode] (`app`, `background`,
  /// `receive-only`, `parked`); written only when it changed.
  static void mode(String mode, [Map<String, Object?> fields = const {}]) {
    if (mode == _mode) {
      return;
    }
    // None yet: `-`.
    final String? from = _mode;
    _mode = mode;
    event('mode', <String, Object?>{'to': mode, 'from': from, ...fields});
  }

  /// The node was handed [to] the service or back to the `app`, [ok]: it
  /// was taken, in [took]. Handed to the service, this isolate's runtime
  /// only waits ([mode] `receive-only`, the service's side).
  static void handover(String to, {required bool ok, required Duration took}) {
    event('handover', <String, Object?>{
      'to': to,
      'ok': ok,
      'ms': took.inMilliseconds,
    });
    if (ok && to == 'service') {
      mode('receive-only');
    }
  }

  /// A wake's work ended: [job] took [took].
  static void wake(String job, Duration took) {
    event('wake', <String, Object?>{'job': job, 'ms': took.inMilliseconds});
  }

  /// A read of the node ([info], the bridge's node info): its numbers are
  /// written the first time and then at most every [nodeSampleEvery].
  static void node(Map<String, dynamic> info, {DateTime? now}) {
    final int handle = _int(info['handle']);
    final DateTime at = now ?? DateTime.now();
    final DateTime? last = _sampledAt[handle];
    if (last != null && at.difference(last).abs() < nodeSampleEvery) {
      return;
    }
    if (last == null) {
      event('node-start', <String, Object?>{'h': handle});
    }
    _sampledAt[handle] = at;
    ZenDiagnosticsLog.write(nodeSampleLine(info));
  }

  /// The node [handle] stopped.
  static void nodeStopped(int handle) {
    _sampledAt.remove(handle);
    event('node-stop', <String, Object?>{'h': handle});
  }

  /// Writes how Android ended the app's earlier runs (Android 11 on; only
  /// the ones not written yet). Once per isolate's start, after
  /// [ZenDiagnosticsLog.attach]. The app and the background service start
  /// together and both ask: the one that claims the newest record first
  /// (a file made only if it is not there yet) writes them, so they are
  /// written once, not once per isolate.
  static Future<void> noteExits({
    MethodChannel channel = const MethodChannel('zen/power'),
    bool? android,
  }) async {
    final File? log = ZenDiagnosticsLog.file;
    if (kIsWeb || !(android ?? Platform.isAndroid) || log == null) {
      return;
    }
    try {
      final String base =
          '${log.parent.path}${Platform.pathSeparator}'
          '${ZenDiagnosticsLog.filePrefix}-exits';
      final File seen = File(base);
      int since = 0;
      if (await seen.exists()) {
        since = int.tryParse((await seen.readAsString()).trim()) ?? 0;
      }
      final List<Object?> exits =
          await channel.invokeListMethod<Object?>('exitReasons') ??
          const <Object?>[];
      int newest = since;
      for (final Object? exit in exits) {
        if (exit is Map && _int(exit['at']) > newest) {
          newest = _int(exit['at']);
        }
      }
      if (newest <= since) {
        return;
      }
      try {
        await File('$base-$newest').create(exclusive: true);
      } on FileSystemException {
        // The other isolate claimed these records: it writes them.
        return;
      }
      for (final String line in exitLines(exits, since: since)) {
        ZenDiagnosticsLog.write(line);
      }
      await seen.writeAsString('$newest', flush: true);
      // Older claims are done with; this one stays, so an isolate that
      // read the mark before it moved cannot claim the same records.
      await for (final FileSystemEntity entity in log.parent.list()) {
        final String name = entity.path.split(RegExp(r'[/\\]')).last;
        final int? claimed =
            name.startsWith('${ZenDiagnosticsLog.filePrefix}-exits-')
            ? int.tryParse(name.split('-').last)
            : null;
        if (entity is File && claimed != null && claimed < newest) {
          await entity.delete();
        }
      }
    } on Object catch (error) {
      // An older build of the native side, or Android before 11.
      logZenWarning('Exit reasons unavailable: $error');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _mode = null;
    _sampledAt.clear();
  }
}

/// `TECH  <event> key=value …`: keys are camelCase words; values numbers
/// (fractions with one digit), `true`/`false`, `-` for none, times (to the
/// second), short lower-case words (`mailbox-poll`), lists of such words and
/// maps of words to numbers (`mailbox-poll:120,watchdog:6000`). Anything
/// else (text, addresses, keys, paths) becomes `?`, and so does a key that
/// is not a plain word.
String formatTechLine(String event, Map<String, Object?> fields) {
  final StringBuffer line = StringBuffer('TECH  ${_word(event)}');
  for (final MapEntry<String, Object?> field in fields.entries) {
    final String key = _keyPattern.hasMatch(field.key) ? field.key : '?';
    line.write(' $key=${_value(field.value)}');
  }
  return line.toString();
}

final RegExp _keyPattern = RegExp(r'^[a-z][A-Za-z0-9]{0,23}$');
final RegExp _wordPattern = RegExp(r'^[a-z][a-z0-9-]{0,31}$');

String _word(Object? value) =>
    value is String && _wordPattern.hasMatch(value) ? value : '?';

String _value(Object? value) {
  if (value == null) {
    return '-';
  }
  if (value is bool) {
    return '$value';
  }
  if (value is int) {
    return '$value';
  }
  if (value is double) {
    return value.isFinite ? value.toStringAsFixed(1) : '?';
  }
  if (value is DateTime) {
    return value.toIso8601String().substring(0, 19);
  }
  if (value is Map) {
    if (value.isEmpty) {
      return '-';
    }
    return <String>[
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${_word(entry.key)}:${entry.value is num ? _value(entry.value) : '?'}',
    ].join(',');
  }
  if (value is Iterable) {
    return value.isEmpty ? '-' : value.map(_word).join(',');
  }
  return _word(value);
}

/// One sample of a running node from its info (the bridge's
/// `normalizeNodeState`): peers by count only, the Go side's memory
/// (`goMemory`) and what passed through (`traffic`, its transit guard and
/// the door host's public peering). Sizes in KiB, rates in bytes a second.
String nodeSampleLine(Map<String, dynamic> info) {
  final Object? rawPeers = info['peers'];
  int peers = 0;
  int up = 0;
  int inbound = 0;
  if (rawPeers is List) {
    peers = rawPeers.length;
    for (final Object? peer in rawPeers) {
      if (peer is Map && peer['up'] == true) {
        up += 1;
      }
      if (peer is Map && peer['inbound'] == true) {
        inbound += 1;
      }
    }
  }
  final Map<String, dynamic> memory = _map(info['goMemory']);
  final Map<String, dynamic> traffic = _map(info['traffic']);
  final Map<String, dynamic> guard = _map(traffic['transitGuard']);
  final Map<String, dynamic> door = _map(traffic['doorHost']);
  int kib(Map<String, dynamic> from, String key) => _int(from[key]) ~/ 1024;
  return formatTechLine('node', <String, Object?>{
    'h': _int(info['handle']),
    'peers': peers,
    'up': up,
    'inbound': inbound,
    'pool': _int(info['peerPoolCount']),
    'routes': _int(info['routingEntries']),
    'heapKb': kib(memory, 'heapBytes'),
    'goalKb': kib(memory, 'heapGoalBytes'),
    'retainedKb': kib(memory, 'retainedBytes'),
    'limitKb': kib(memory, 'memoryLimitBytes'),
    'goroutines': _int(memory['goroutines']),
    'gc': _int(memory['gcCycles']),
    'rxBps': _int(traffic['rxRate']),
    'txBps': _int(traffic['txRate']),
    'transitBps': _int(traffic['transitRate']),
    'transitKb': kib(traffic, 'transitBytes'),
    'pubRxKb': kib(traffic, 'publicRxBytes'),
    'pubTxKb': kib(traffic, 'publicTxBytes'),
    'locRxKb': kib(traffic, 'localRxBytes'),
    'locTxKb': kib(traffic, 'localTxBytes'),
    'sigRxKb': kib(traffic, 'ownSignalRxBytes'),
    'sigTxKb': kib(traffic, 'ownSignalTxBytes'),
    'relayRxKb': kib(traffic, 'ownRelayRxBytes'),
    'relayTxKb': kib(traffic, 'ownRelayTxBytes'),
    if (guard.isNotEmpty) ...<String, Object?>{
      'holding': guard['holding'] == true,
      'holds': _int(guard['holds']),
      'holdLeftS': _int(guard['holdSecondsLeft']),
      'heldS': _int(guard['heldSecondsTotal']),
      'hourKb': kib(guard, 'hourBytes'),
      'setAside': _int(guard['setAside']),
    },
    if (door.isNotEmpty) ...<String, Object?>{
      'doorPubRxKb': kib(door, 'publicRxBytes'),
      'doorPubTxKb': kib(door, 'publicTxBytes'),
    },
  });
}

/// Lines for Android's records of how earlier runs ended ([exits]: the
/// `exitReasons` answer of `zen/power`), those after [since] (epoch
/// milliseconds), oldest first. Reasons and importance by name; memory in
/// KiB; no description (free text from the system).
List<String> exitLines(List<Object?> exits, {int since = 0}) {
  final List<Map<Object?, Object?>> fresh = <Map<Object?, Object?>>[
    for (final Object? exit in exits)
      if (exit is Map<Object?, Object?> && _int(exit['at']) > since) exit,
  ]..sort((a, b) => _int(a['at']).compareTo(_int(b['at'])));
  return <String>[
    for (final Map<Object?, Object?> exit in fresh)
      formatTechLine('exit', <String, Object?>{
        'at': DateTime.fromMillisecondsSinceEpoch(_int(exit['at'])),
        'reason': _exitReasons[_int(exit['reason'])] ?? 'unknown',
        'importance': _importance(_int(exit['importance'])),
        'status': _int(exit['status']),
        'pssKb': _int(exit['pssKb']),
        'rssKb': _int(exit['rssKb']),
      }),
  ];
}

/// `ApplicationExitInfo.REASON_*`.
const Map<int, String> _exitReasons = <int, String>{
  0: 'unknown',
  1: 'exit-self',
  2: 'signaled',
  3: 'low-memory',
  4: 'crash',
  5: 'crash-native',
  6: 'anr',
  7: 'initialization-failure',
  8: 'permission-change',
  9: 'excessive-resource-usage',
  10: 'user-requested',
  11: 'user-stopped',
  12: 'dependency-died',
  13: 'other',
  14: 'freezer',
  15: 'package-state-change',
  16: 'package-updated',
};

/// `RunningAppProcessInfo.IMPORTANCE_*`, at or above.
String _importance(int value) {
  if (value <= 0) {
    return 'unknown';
  }
  if (value <= 100) {
    return 'foreground';
  }
  if (value <= 125) {
    return 'foreground-service';
  }
  if (value <= 200) {
    return 'visible';
  }
  if (value <= 230) {
    return 'perceptible';
  }
  if (value <= 300) {
    return 'service';
  }
  if (value <= 325) {
    return 'top-sleeping';
  }
  if (value <= 350) {
    return 'cant-save-state';
  }
  if (value <= 400) {
    return 'cached';
  }
  return 'gone';
}

int _int(Object? value) => value is num ? value.toInt() : 0;

Map<String, dynamic> _map(Object? value) => value is Map
    ? <String, dynamic>{
        for (final MapEntry<Object?, Object?> entry in value.entries)
          if (entry.key is String) entry.key! as String: entry.value,
      }
    : const <String, dynamic>{};
