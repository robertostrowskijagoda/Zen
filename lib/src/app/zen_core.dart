import 'dart:async';

import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// One part of Zen that [ZenCore] starts and stops: its services, timers and
/// what it does when the app comes back.
///
/// A module of a [feature] runs only while that feature is enabled; a module
/// without one is part of the core and always runs.
abstract class ZenModule {
  const ZenModule();

  /// A short, unique name (logs, tests).
  String get id;

  /// The feature flag this module belongs to; `null` for the core.
  ZenFeature? get feature => null;

  /// Starts the module's services. Modules start one after another, in the
  /// order of the registry, each once the previous one has started — or
  /// once [ZenCore.modulePatience] has passed: one module that hangs
  /// (a node that does not come up, a store that does not answer) never
  /// holds the others back.
  FutureOr<void> start();

  /// Stops what [start] started. Modules stop in the reverse order.
  ///
  /// Timers are cancelled synchronously, before anything is awaited: a
  /// widget test checks for pending timers right after the app goes away.
  FutureOr<void> stop() {}

  /// The app came back to the screen: re-read what the background service
  /// may have changed on disk meanwhile.
  void onResume() {}

  /// Called once a minute while the core runs ([minute] counts from 1).
  void onMinute(int minute) {}

  /// Whether the user can see and use the app (on screen and unlocked).
  void onInteractiveChanged(bool interactive) {}
}

/// The composition root (step 0): starts and stops Zen's modules in a
/// defined order, honouring the feature flags, and runs their minute duties.
///
/// Plain Dart: the app creates one through a provider and its widgets only
/// forward what the platform tells them (lifecycle, visibility).
final class ZenCore {
  ZenCore({
    required List<ZenModule> modules,
    required Future<FeatureFlags> Function() loadFlags,
    this.minute = const Duration(minutes: 1),
    this.modulePatience = const Duration(seconds: 15),
  }) : modules = List<ZenModule>.unmodifiable(modules),
       _loadFlags = loadFlags {
    final Set<String> ids = <String>{};
    for (final ZenModule module in modules) {
      if (!ids.add(module.id)) {
        throw ArgumentError.value(module.id, 'modules', 'Duplicate module id');
      }
    }
  }

  /// The registry, in start order.
  final List<ZenModule> modules;

  /// How often [ZenModule.onMinute] runs (shorter in tests).
  final Duration minute;

  /// How long the next module waits for one that is still starting; the
  /// late one joins the running ones once its start is done.
  final Duration modulePatience;

  final Future<FeatureFlags> Function() _loadFlags;

  /// Started modules, in the order they started.
  final List<ZenModule> _running = <ZenModule>[];

  /// The modules whose start is in progress (more than one once a start
  /// outlived [modulePatience]); [stop] stops them at once.
  final List<ZenModule> _starting = <ZenModule>[];

  FeatureFlags? _flags;
  bool _started = false;

  /// Bumped by [stop]: a start still in progress gives up.
  int _generation = 0;

  /// The start (and later starts of features turned on) in progress.
  Future<void> _work = Future<void>.value();
  int _pending = 0;
  Timer? _ticker;
  int _minutes = 0;
  bool _interactive = false;

  /// Whether [start] was called and [stop] not since.
  bool get isStarted => _started;

  /// Ids of the modules running now, in start order.
  List<String> get runningModules =>
      List<String>.unmodifiable(_running.map((ZenModule m) => m.id));

  /// Starts every enabled module, one after another. Completes once all of
  /// them have started (a module that fails is logged and skipped).
  Future<void> start() {
    if (_started) {
      return _work;
    }
    _started = true;
    final int generation = ++_generation;
    _minutes = 0;
    _ticker = Timer.periodic(minute, (_) => _tick());
    return _enqueue(() => _startModules(generation));
  }

  /// Stops the running modules in the reverse order of their start.
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;
    _generation++;
    _ticker?.cancel();
    _ticker = null;
    final List<ZenModule> running = <ZenModule>[
      ..._starting.reversed,
      ..._running.reversed,
    ];
    _starting.clear();
    _running.clear();
    for (final ZenModule module in running) {
      // Not awaited when synchronous: `await null` would still yield, and the
      // next module's timers must go in this same call.
      final FutureOr<void> stopped = _stopModule(module);
      if (stopped is Future<void>) {
        await stopped;
      }
    }
  }

  /// The user's flags changed while the app runs: a feature turned off stops
  /// its module, one turned on starts it.
  void applyFlags(FeatureFlags flags) {
    _flags = flags;
    if (!_started) {
      return;
    }
    for (final ZenModule module in _running.reversed.toList()) {
      if (!_isEnabled(module, flags)) {
        _running.remove(module);
        final FutureOr<void> stopped = _stopModule(module);
        if (stopped is Future<void>) {
          unawaited(stopped);
        }
      }
    }
    final int generation = _generation;
    unawaited(_enqueue(() => _startMissing(generation)));
  }

  /// The app came back to the screen.
  void resumed() {
    for (final ZenModule module in List<ZenModule>.of(_running)) {
      _guard(module, 'resume', module.onResume);
    }
  }

  /// Whether the user can see and use the app (on screen and unlocked).
  void setInteractive(bool interactive) {
    if (_interactive == interactive) {
      return;
    }
    _interactive = interactive;
    for (final ZenModule module in List<ZenModule>.of(_running)) {
      _guard(
        module,
        'visibility change',
        () => module.onInteractiveChanged(interactive),
      );
    }
  }

  /// Runs [task] after the starts already in progress (a start after a quick
  /// stop must not race the old one), or right away when there are none, so
  /// the first module starts within [start] itself.
  Future<void> _enqueue(Future<void> Function() task) {
    final Future<void> previous = _work;
    final bool idle = _pending == 0;
    _pending++;
    Future<void> run() async {
      try {
        await task();
      } finally {
        _pending--;
      }
    }

    return _work = idle ? run() : previous.then((_) => run());
  }

  void _tick() {
    _minutes++;
    final int minute = _minutes;
    for (final ZenModule module in List<ZenModule>.of(_running)) {
      _guard(module, 'minute', () => module.onMinute(minute));
    }
  }

  Future<void> _startModules(int generation) async {
    for (final ZenModule module in modules) {
      if (generation != _generation) {
        return;
      }
      if (module.feature != null) {
        final FeatureFlags flags = await _currentFlags();
        if (generation != _generation) {
          return;
        }
        if (!_isEnabled(module, flags)) {
          logZenMessage('Module ${module.id} is off (feature flag).');
          continue;
        }
      }
      await _startModule(module, generation);
    }
  }

  /// Starts the enabled feature modules that are not running yet.
  Future<void> _startMissing(int generation) async {
    for (final ZenModule module in modules) {
      if (generation != _generation) {
        return;
      }
      final FeatureFlags? flags = _flags;
      if (module.feature == null ||
          flags == null ||
          !_isEnabled(module, flags) ||
          _running.contains(module) ||
          _starting.contains(module)) {
        continue;
      }
      await _startModule(module, generation);
    }
  }

  Future<FeatureFlags> _currentFlags() async {
    final FeatureFlags? known = _flags;
    if (known != null) {
      return known;
    }
    FeatureFlags loaded;
    try {
      loaded = await _loadFlags();
    } catch (error, stackTrace) {
      logZenError('Reading the feature flags failed', error, stackTrace);
      loaded = const FeatureFlags();
    }
    // Flags applied meanwhile are newer than the loaded ones.
    return _flags ??= loaded;
  }

  Future<void> _startModule(ZenModule module, int generation) async {
    _starting.add(module);
    final Stopwatch watch = Stopwatch()..start();
    final Future<bool> started = () async {
      try {
        await module.start();
        return true;
      } catch (error, stackTrace) {
        logZenError(
          'Starting the ${module.id} module failed',
          error,
          stackTrace,
        );
        return false;
      }
    }();
    final bool? ok = await started
        .then<bool?>((bool value) => value)
        .timeout(modulePatience, onTimeout: () => null);
    if (ok == null) {
      logZenWarning(
        'The ${module.id} module is still starting after '
        '${modulePatience.inSeconds} s; the next modules start meanwhile.',
      );
      ZenStartTrace.note('module ${module.id} still starting');
      unawaited(
        started.then((bool late) async {
          ZenStartTrace.note(
            'module ${module.id} started late after '
            '${watch.elapsedMilliseconds} ms',
          );
          await _finishStart(module, generation, late);
        }),
      );
      return;
    }
    if (watch.elapsedMilliseconds >= 1000) {
      ZenStartTrace.note(
        'module ${module.id} took ${watch.elapsedMilliseconds} ms',
      );
    }
    await _finishStart(module, generation, ok);
  }

  /// After [module]'s start ended ([ok]: without an error): it runs from
  /// now on, or is stopped again when the core stopped meanwhile, its
  /// feature went off or the start failed.
  Future<void> _finishStart(ZenModule module, int generation, bool ok) async {
    if (!_starting.remove(module)) {
      // [stop] came meanwhile and has stopped this module already.
      return;
    }
    final FeatureFlags? flags = _flags;
    if (!ok ||
        generation != _generation ||
        (flags != null && !_isEnabled(module, flags))) {
      await _stopModule(module);
      return;
    }
    _running.add(module);
    if (_interactive) {
      _guard(
        module,
        'visibility change',
        () => module.onInteractiveChanged(true),
      );
    }
  }

  /// Synchronous when the module's stop is: then the next one stops at once.
  FutureOr<void> _stopModule(ZenModule module) {
    try {
      final FutureOr<void> result = module.stop();
      if (result is Future<void>) {
        return result.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) => logZenError(
            'Stopping the ${module.id} module failed',
            error,
            stackTrace,
          ),
        );
      }
    } catch (error, stackTrace) {
      logZenError('Stopping the ${module.id} module failed', error, stackTrace);
    }
  }

  static bool _isEnabled(ZenModule module, FeatureFlags flags) {
    final ZenFeature? feature = module.feature;
    return feature == null || flags.isEnabled(feature);
  }

  static void _guard(ZenModule module, String what, void Function() call) {
    try {
      call();
    } catch (error, stackTrace) {
      logZenError('Module ${module.id} ($what) failed', error, stackTrace);
    }
  }
}
