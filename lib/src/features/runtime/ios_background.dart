import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The channel of ZenBackgroundBridge.swift.
const MethodChannel _channel = MethodChannel('zen/background');

/// Whether iOS lets Zen be woken in the background ("Odświeżanie w tle").
enum IosBackgroundRefresh { available, denied, restricted, unknown }

/// What the iPhone reports about Zen's time off the screen.
@immutable
final class IosBackgroundStatus {
  const IosBackgroundStatus({
    this.refresh = IosBackgroundRefresh.unknown,
    this.lowPower = false,
    this.keepAlive = false,
    this.lastRunAtMillis = 0,
    this.lastRunResult = '',
    this.runs = 0,
  });

  factory IosBackgroundStatus.fromMap(Object? raw) {
    if (raw is! Map) {
      return const IosBackgroundStatus();
    }
    final Object? refresh = raw['refresh'];
    final Object? lastRunAt = raw['lastRunAt'];
    final Object? lastRunResult = raw['lastRunResult'];
    final Object? runs = raw['runs'];
    return IosBackgroundStatus(
      refresh: IosBackgroundRefresh.values.firstWhere(
        (IosBackgroundRefresh value) => value.name == refresh,
        orElse: () => IosBackgroundRefresh.unknown,
      ),
      lowPower: raw['lowPower'] == true,
      keepAlive: raw['keepAlive'] == true,
      lastRunAtMillis: lastRunAt is num ? lastRunAt.toInt() : 0,
      lastRunResult: lastRunResult is String ? lastRunResult : '',
      runs: runs is num ? runs.toInt() : 0,
    );
  }

  final IosBackgroundRefresh refresh;

  /// Low Power Mode: iOS wakes no app in the background then.
  final bool lowPower;

  /// The silent sound plays now (only ever while Zen is off the screen).
  final bool keepAlive;

  /// When iOS last woke Zen for a background check (0 = never), and how it
  /// went: "done", "skipped" (locked, no node), "notReady" (Zen was not
  /// running, or locked), "expired" (out of time).
  final int lastRunAtMillis;
  final String lastRunResult;

  /// How many times iOS woke Zen since it was installed.
  final int runs;

  /// Whether iOS may wake Zen now at all.
  bool get canRefresh => refresh == IosBackgroundRefresh.available && !lowPower;
}

/// Reads [IosBackgroundStatus] from the iPhone (`null` where there is none).
Future<IosBackgroundStatus?> readIosBackgroundStatus() async {
  try {
    return IosBackgroundStatus.fromMap(await _channel.invokeMethod('status'));
  } on MissingPluginException {
    return null;
  } on PlatformException catch (error, stackTrace) {
    logZenError('Reading the background status failed', error, stackTrace);
    return null;
  }
}

/// How the settings page reads the status (tests replace it).
final Provider<Future<IosBackgroundStatus?> Function()>
iosBackgroundStatusReaderProvider =
    Provider<Future<IosBackgroundStatus?> Function()>(
      (Ref ref) => readIosBackgroundStatus,
    );

/// One background check on an iPhone, in the few seconds iOS gives.
///
/// The node was frozen with the app, so its links may need a moment to come
/// back: the mailboxes are asked at once ([poll]), and again every
/// [retryAfter] while nothing at all has come in (the first asks went
/// nowhere), or once when the first frame shows the links are back and it
/// is not a mailbox's answer ([arrivals] carries `true` for frames of the
/// mailbox protocol). Once something came, the check ends when it has been
/// quiet for [quietAfter] (but not before [minimum]), so held mail, its
/// acknowledgements and the notifications have time; it never runs past the
/// budget.
final class IosCatchUp {
  IosCatchUp({
    required Future<void> Function() poll,
    required Stream<bool> arrivals,
    this.retryAfter = const Duration(seconds: 8),
    this.maxPolls = 3,
    this.quietAfter = const Duration(seconds: 5),
    this.minimum = const Duration(seconds: 8),
    this.step = const Duration(seconds: 1),
    @visibleForTesting Future<void> Function(Duration step)? wait,
  }) : _poll = poll,
       _arrivals = arrivals,
       _wait = wait ?? Future<void>.delayed;

  final Future<void> Function() _poll;
  final Stream<bool> _arrivals;
  final Future<void> Function(Duration step) _wait;
  final Duration retryAfter;
  final int maxPolls;
  final Duration quietAfter;
  final Duration minimum;
  final Duration step;

  /// Runs within [budget]; returns how many frames came in meanwhile.
  Future<int> run(Duration budget) async {
    int arrived = 0;
    bool answered = false;
    bool arrivedThisStep = false;
    final StreamSubscription<bool> subscription = _arrivals.listen((
      bool fromMailbox,
    ) {
      arrived += 1;
      answered = answered || fromMailbox;
      arrivedThisStep = true;
    });
    try {
      await _pollQuietly();
      int polls = 1;
      Duration elapsed = Duration.zero;
      Duration sincePoll = Duration.zero;
      Duration quiet = Duration.zero;
      bool askedOnceUp = false;
      while (elapsed + step <= budget) {
        await _wait(step);
        elapsed += step;
        sincePoll += step;
        quiet = arrivedThisStep ? Duration.zero : quiet + step;
        arrivedThisStep = false;
        if (arrived == 0) {
          if (sincePoll >= retryAfter && polls < maxPolls) {
            await _pollQuietly();
            polls += 1;
            sincePoll = Duration.zero;
          }
          continue;
        }
        if (!answered && !askedOnceUp && polls < maxPolls) {
          // The links are back, but the asks may have gone out before.
          askedOnceUp = true;
          await _pollQuietly();
          polls += 1;
          sincePoll = Duration.zero;
          quiet = Duration.zero;
        } else if (elapsed >= minimum && quiet >= quietAfter) {
          break;
        }
      }
      return arrived;
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _pollQuietly() async {
    try {
      await _poll();
    } on Object catch (error, stackTrace) {
      logZenError('Asking the mailboxes failed', error, stackTrace);
    }
  }
}

/// Whether this device has ZenBackgroundBridge.swift (an iPhone or iPad).
final Provider<bool> iosBackgroundBridgeEnabledProvider = Provider<bool>(
  (Ref ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
);

/// The iPhone's time off the screen, as far as iOS allows it
/// (docs/IOS_BACKGROUND.md):
///  - tells the native side whether Zen may run in the background now
///    (`ready`: the core runs and the app is unlocked — a locked app cannot
///    store what comes in) and whether the person chose the keep-alive;
///  - runs the background checks iOS wakes Zen for ([IosCatchUp]): the
///    friends' mailboxes are asked for what they hold, and what comes in is
///    handled as always off the screen (stored, with a notification).
///
/// Under [RuntimeSignalBridge], so it lives as long as the core: locking
/// the app on the screen unmounts it. A lock while Zen is in the background
/// draws no frame, so the security service is followed as well.
class IosBackgroundBridge extends ConsumerStatefulWidget {
  const IosBackgroundBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<IosBackgroundBridge> createState() =>
      _IosBackgroundBridgeState();
}

final class _IosBackgroundBridgeState
    extends ConsumerState<IosBackgroundBridge> {
  bool _enabled = false;
  AppSecurityService? _security;
  bool? _sentReady;
  bool? _sentKeepAlive;
  Future<bool>? _catchUp;

  @override
  void initState() {
    super.initState();
    _enabled = ref.read(iosBackgroundBridgeEnabledProvider);
    if (!_enabled) {
      return;
    }
    _channel.setMethodCallHandler(_handleCall);
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    security.addListener(_configure);
    _security = security;
    ref.listenManual<bool>(
      appSettingsControllerProvider.select(
        (AppSettings settings) => settings.keepReceivingInBackground,
      ),
      (bool? previous, bool next) => _configure(),
    );
    _configure();
  }

  @override
  void dispose() {
    if (_enabled) {
      _security?.removeListener(_configure);
      _channel.setMethodCallHandler(null);
      _send(ready: false, keepAlive: false);
    }
    super.dispose();
  }

  bool get _ready {
    final AppSecurityService? security = _security;
    return security != null && !isSecurityBlockingUi(security);
  }

  void _configure() {
    if (!mounted) {
      return;
    }
    _send(
      ready: _ready,
      keepAlive: ref
          .read(appSettingsControllerProvider)
          .keepReceivingInBackground,
    );
  }

  void _send({required bool ready, required bool keepAlive}) {
    if (ready == _sentReady && keepAlive == _sentKeepAlive) {
      return;
    }
    _sentReady = ready;
    _sentKeepAlive = keepAlive;
    unawaitedLogged(
      _channel.invokeMethod<Object?>('configure', <String, Object?>{
        'ready': ready,
        'keepAlive': keepAlive,
      }),
      context: 'Configuring the background work failed',
    );
  }

  Future<Object?> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'catchUp':
        final Object? arguments = call.arguments;
        final Object? seconds = arguments is Map ? arguments['seconds'] : null;
        final Duration budget = Duration(
          seconds: seconds is int ? seconds.clamp(1, 600) : 25,
        );
        // A refresh and a charging catch-up at once share one check.
        return _catchUp ??= _runCatchUp(budget).whenComplete(() {
          _catchUp = null;
        });
      default:
        throw MissingPluginException('zen/background: ${call.method}');
    }
  }

  Future<bool> _runCatchUp(Duration budget) async {
    if (!mounted || !_ready) {
      logZenMessage('Background check (iOS) skipped: Zen is locked.');
      return false;
    }
    final RelayEngine? engine = ref.read(relayEngineProvider);
    final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
    if (engine == null || !engine.isActive) {
      logZenMessage('Background check (iOS) skipped: the node is not up.');
      return false;
    }
    final Stopwatch watch = Stopwatch()..start();
    // `activate` is what a fresh start of the node does: ask every mailbox
    // for what piled up, and try whatever waits to be sent again soon.
    final int frames = await IosCatchUp(
      poll: engine.activate,
      arrivals: runtime.frames.map(
        (SignalTransportFrame frame) =>
            frame.payload['type'].toString().startsWith('rly_'),
      ),
    ).run(budget);
    logZenMessage(
      'Background check (iOS): $frames frames in '
      '${watch.elapsed.inSeconds} s.',
    );
    ZenTechLog.event('wake', {
      'job': 'ios-check',
      'ms': watch.elapsedMilliseconds,
      'frames': frames,
    });
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
