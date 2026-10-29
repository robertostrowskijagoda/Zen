import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';

/// One step on the way from `main` to the first screen.
@immutable
final class ZenStartStep {
  const ZenStartStep(this.id, {required this.label, this.optional = false});

  /// The step in the logs: a short fixed word (`app-lock`), see
  /// [formatTechLine].
  final String id;

  /// What the slow-start screen calls it (already translated).
  final String label;

  /// The app can start without it ("Uruchom bez …" skips it).
  final bool optional;

  @override
  String toString() => id;
}

/// A start step that took longer than it may: the start cannot go on
/// without it (an optional step falls back instead).
final class ZenStartStepTimeout implements Exception {
  const ZenStartStepTimeout(this.step, this.timeout);

  final ZenStartStep step;
  final Duration timeout;

  @override
  String toString() =>
      'Start step "${step.id}" did not finish in ${timeout.inSeconds} s.';
}

/// The way from `main` to the first screen, step by step: every step that
/// waits on the disk, the system or another part of the app runs through
/// [run], with a time limit and, where the app can do without it, a
/// fallback. A start therefore never hangs on one step, and one that is
/// slow shows which step it waits on (the slow-start screen reads
/// [current]).
///
/// Each step also goes, before it begins, into the start log: a file of
/// the diagnostics log (`zen-diagnostics-start.log`, read back with the
/// rest) written at once, not queued. A start that hangs or is ended
/// half way leaves its last step on disk, and the next start says where
/// the previous one stopped ([previousStop]). Each finished step is a
/// `TECH  start step=<id> ms=<n> result=<ok|timeout|failed|skipped>` line
/// as well.
abstract final class ZenStartTrace {
  /// The source name of the start log among the diagnostics log's files.
  static const String logSource = 'start';

  /// The line a start that reached its first screen ends with.
  static const String reachedMarker = 'START reached the first screen';

  /// The line every start begins with.
  static const String beginMarker = 'START begins';

  /// The step running now (the innermost one), `null` between steps.
  static final ValueNotifier<ZenStartStep?> current =
      ValueNotifier<ZenStartStep?>(null);

  /// Whether the first screen of this start is up ([reached]).
  static final ValueNotifier<bool> done = ValueNotifier<bool>(false);

  static File? _file;
  static List<String> _privatePlaces = const <String>[];
  static final List<String> _pending = <String>[];
  static final Stopwatch _sinceBegin = Stopwatch();
  static Completer<void>? _skip;
  static String? _previousStop;

  /// Where the previous start stopped, when it did not reach its first
  /// screen: the step it was in (or the last one it began). `null` when
  /// it did, or when there was none.
  static String? get previousStop => _previousStop;

  /// The start log's file, once [attach]ed.
  static File? get file => _file;

  /// A start begins (the app's own, or another account's being opened).
  /// While one is already on its way to the first screen this only goes
  /// on with it: `main` begins the app's start and the bootstrap's own
  /// call must not restart the clock, or "reached the first screen after
  /// N ms" would leave out the steps `main` took.
  static void begin() {
    if (_sinceBegin.isRunning && !done.value) {
      return;
    }
    done.value = false;
    _sinceBegin
      ..reset()
      ..start();
    note(beginMarker);
  }

  /// Writes the start log into [folder] from now on (with the lines noted
  /// before). Once per process: later calls keep the first folder. The
  /// log of the start before is kept beside it (`.1`), and when it did not
  /// reach its first screen that is said in the diagnostics log.
  static void attach(Directory folder) {
    if (_file != null) {
      return;
    }
    try {
      final File target = File(
        '${folder.path}${Platform.pathSeparator}'
        '${ZenDiagnosticsLog.fileNameFor(logSource)}',
      );
      folder.createSync(recursive: true);
      _privatePlaces = diagnosticsPrivatePlaces(folder.path);
      if (target.existsSync()) {
        _previousStop = stopOf(target.readAsStringSync());
        final File previous = File('${target.path}.1');
        if (previous.existsSync()) {
          previous.deleteSync();
        }
        target.renameSync(previous.path);
      }
      _file = target;
      final String lines = _pending.join();
      _pending.clear();
      target.writeAsStringSync(lines, flush: true);
    } on Object catch (error) {
      logZenWarning('The start log could not be written: $error');
      return;
    }
    final String? stop = _previousStop;
    if (stop != null) {
      logZenWarning('The previous start stopped at step "$stop".');
      ZenTechLog.event('start-stopped', <String, Object?>{'step': stop});
    }
  }

  /// Where the start logged in [text] stopped: `null` when its last start
  /// reached the first screen (or nothing began), else the step it was in.
  @visibleForTesting
  static String? stopOf(String text) {
    final List<String> lines = text.split('\n');
    final int begun = lines.lastIndexWhere(
      (String line) => line.contains(beginMarker),
    );
    if (begun < 0) {
      return null;
    }
    final List<String> run = lines.sublist(begun);
    if (run.any((String line) => line.contains(reachedMarker))) {
      return null;
    }
    final Set<String> finished = <String>{};
    String? last;
    for (final String line in run) {
      final RegExpMatch? began = _beganPattern.firstMatch(line);
      if (began != null) {
        last = began[1];
        continue;
      }
      final RegExpMatch? ended = _endedPattern.firstMatch(line);
      if (ended != null) {
        finished.add(ended[1]!);
      }
    }
    // The innermost step still running, else the last one begun.
    for (final String line in run.reversed) {
      final RegExpMatch? began = _beganPattern.firstMatch(line);
      if (began != null && !finished.contains(began[1])) {
        return began[1];
      }
    }
    return last ?? 'begin';
  }

  static final RegExp _beganPattern = RegExp(r'step ([a-z0-9-]+) begins');
  static final RegExp _endedPattern = RegExp(
    r'step ([a-z0-9-]+) (?:ok|timeout|failed|skipped)',
  );

  /// The first screen is up: this start is done.
  static void reached() {
    if (done.value) {
      return;
    }
    done.value = true;
    note('$reachedMarker after ${_sinceBegin.elapsedMilliseconds} ms');
    ZenTechLog.event('start', <String, Object?>{
      'step': 'first-screen',
      'ms': _sinceBegin.elapsedMilliseconds,
      'result': 'ok',
    });
  }

  /// One line in the start log, written to disk before this returns
  /// (once attached).
  static void note(String line) {
    final String entry =
        '${DateTime.now().toIso8601String()} [$logSource] '
        '${redactDiagnosticsText(line, privatePlaces: _privatePlaces)}\n';
    final File? target = _file;
    if (target == null) {
      if (_pending.length >= ZenDiagnosticsLog.earlyLineLimit) {
        _pending.removeAt(0);
      }
      _pending.add(entry);
      return;
    }
    try {
      target.writeAsStringSync(entry, mode: FileMode.append, flush: true);
    } on FileSystemException {
      // Logging never stops a start.
    }
  }

  /// Whether the step running now can be skipped ([skip]).
  static bool get canSkip => _skip != null && !_skip!.isCompleted;

  /// Skips the optional step running now: it gives its fallback at once
  /// (and goes on alone; what it brings later is dropped).
  static void skip() {
    final Completer<void>? skip = _skip;
    if (skip != null && !skip.isCompleted) {
      skip.complete();
    }
  }

  /// Runs [action] as [step]: at most [timeout] long. When it takes longer
  /// (or [skip] skips it), [fallback] answers instead — or, without one,
  /// a [ZenStartStepTimeout] is thrown. With [fallbackOnError] a failure
  /// gives the fallback too (logged). Only an optional [step] with a
  /// [fallback] can be skipped.
  static Future<T> run<T>(
    ZenStartStep step,
    FutureOr<T> Function() action, {
    required Duration timeout,
    T Function()? fallback,
    bool fallbackOnError = false,
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    note('step ${step.id} begins');
    final Completer<T> result = Completer<T>();
    final Completer<void>? skip = step.optional && fallback != null
        ? Completer<void>()
        : null;
    final Completer<void>? outerSkip = _skip;
    // Before [current] changes: whoever follows it may offer the skip.
    _skip = skip;
    final ZenStartStep? outer = current.value;
    current.value = step;
    String outcome = 'ok';
    unawaited(
      Future<T>.sync(action).then(
        (T value) {
          if (!result.isCompleted) {
            result.complete(value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) {
            result.completeError(error, stackTrace);
          } else {
            logZenError(
              'Start step "${step.id}" failed after it was left',
              error,
              stackTrace,
            );
          }
        },
      ),
    );
    final Timer timer = Timer(timeout, () {
      if (result.isCompleted) {
        return;
      }
      outcome = 'timeout';
      if (fallback != null) {
        logZenWarning(
          'Start step "${step.id}" took over ${timeout.inSeconds} s; '
          'the start goes on without it.',
        );
        result.complete(fallback());
      } else {
        result.completeError(ZenStartStepTimeout(step, timeout));
      }
    });
    unawaited(
      skip?.future.then((_) {
        if (result.isCompleted) {
          return;
        }
        outcome = 'skipped';
        logZenWarning('Start step "${step.id}" skipped by the person.');
        result.complete(fallback!());
      }),
    );
    Object? failure;
    try {
      return await result.future;
    } on Object catch (error, stackTrace) {
      failure = error;
      if (outcome == 'ok') {
        outcome = 'failed';
      }
      if (error is ZenStartStepTimeout ||
          fallback == null ||
          !fallbackOnError) {
        rethrow;
      }
      logZenError(
        'Start step "${step.id}" failed; the start goes on without it',
        error,
        stackTrace,
      );
      return fallback();
    } finally {
      timer.cancel();
      if (identical(_skip, skip)) {
        _skip = outerSkip;
      }
      if (identical(current.value, step)) {
        current.value = outer;
      }
      note(
        'step ${step.id} $outcome ${watch.elapsedMilliseconds} ms'
        '${failure == null ? '' : ': $failure'}',
      );
      ZenTechLog.event('start', <String, Object?>{
        'step': step.id,
        'ms': watch.elapsedMilliseconds,
        'result': outcome,
      });
    }
  }

  /// For tests: forgets the folder, the lines and the state.
  @visibleForTesting
  static void debugReset() {
    _file = null;
    _privatePlaces = const <String>[];
    _pending.clear();
    _skip = null;
    _previousStop = null;
    current.value = null;
    done.value = false;
    _sinceBegin
      ..stop()
      ..reset();
  }
}
