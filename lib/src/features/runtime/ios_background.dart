import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/relay/locked_mailbox_writer.dart';
import 'package:zen/src/features/relay/locked_outbox_writer.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/ios_locked_receiver.dart';
import 'package:zen/src/features/runtime/locked_handoff.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The channel of ZenBackgroundBridge.swift.
const MethodChannel _channel = MethodChannel('zen/background');

/// Whether iOS lets Zen be woken in the background ("Odświeżanie w tle").
enum IosBackgroundRefresh { available, denied, restricted, unknown }

/// Whether Zen may show notifications on this iPhone.
enum IosNotifications { allowed, denied, notDetermined, unknown }

/// What the iPhone reports about Zen's time off the screen.
@immutable
final class IosBackgroundStatus {
  const IosBackgroundStatus({
    this.refresh = IosBackgroundRefresh.unknown,
    this.lowPower = false,
    this.keepAlive = false,
    this.notifications = IosNotifications.unknown,
    this.lastRunAtMillis = 0,
    this.lastRunResult = '',
    this.runs = 0,
    this.lastShortcutAtMillis = 0,
    this.shortcutRuns = 0,
  });

  factory IosBackgroundStatus.fromMap(Object? raw) {
    if (raw is! Map) {
      return const IosBackgroundStatus();
    }
    int number(Object? value) => value is num ? value.toInt() : 0;
    final Object? refresh = raw['refresh'];
    final Object? notifications = raw['notifications'];
    final Object? lastRunResult = raw['lastRunResult'];
    return IosBackgroundStatus(
      refresh: IosBackgroundRefresh.values.firstWhere(
        (IosBackgroundRefresh value) => value.name == refresh,
        orElse: () => IosBackgroundRefresh.unknown,
      ),
      lowPower: raw['lowPower'] == true,
      keepAlive: raw['keepAlive'] == true,
      notifications: IosNotifications.values.firstWhere(
        (IosNotifications value) => value.name == notifications,
        orElse: () => IosNotifications.unknown,
      ),
      lastRunAtMillis: number(raw['lastRunAt']),
      lastRunResult: lastRunResult is String ? lastRunResult : '',
      runs: number(raw['runs']),
      lastShortcutAtMillis: number(raw['lastShortcutAt']),
      shortcutRuns: number(raw['shortcutRuns']),
    );
  }

  final IosBackgroundRefresh refresh;

  /// Low Power Mode: iOS wakes no app in the background then.
  final bool lowPower;

  /// The silent sound plays now (only ever while Zen is off the screen).
  final bool keepAlive;

  final IosNotifications notifications;

  /// When iOS last woke Zen for a background check (0 = never), and how it
  /// went: "done", "skipped" (no node, no capability), "notReady" (Zen
  /// could not run the check at all), "expired" (out of time).
  final int lastRunAtMillis;
  final String lastRunResult;

  /// How many times iOS woke Zen since it was installed.
  final int runs;

  /// When "Sprawdź wiadomości Zen" (the Shortcuts action) last ran (0 =
  /// never), and how many times it did.
  final int lastShortcutAtMillis;
  final int shortcutRuns;

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

Future<void> _open(String method) async {
  try {
    await _channel.invokeMethod<void>(method);
  } on MissingPluginException {
    // Not an iPhone.
  } on PlatformException catch (error) {
    logZenWarning('zen/background $method: ${error.message}');
  }
}

/// Opens Zen's page in the iPhone's Settings (background refresh,
/// notifications), and the Shortcuts app; tests replace them.
final Provider<Future<void> Function()> iosOpenZenSettingsProvider =
    Provider<Future<void> Function()>(
      (Ref ref) =>
          () => _open('openSettings'),
    );
final Provider<Future<void> Function()> iosOpenShortcutsProvider =
    Provider<Future<void> Function()>(
      (Ref ref) =>
          () => _open('openShortcuts'),
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
/// budget, and ends at the next step once [cancelled] says so.
final class IosCatchUp {
  IosCatchUp({
    required Future<void> Function() poll,
    required Stream<bool> arrivals,
    this.retryAfter = const Duration(seconds: 8),
    this.maxPolls = 3,
    this.quietAfter = const Duration(seconds: 5),
    this.minimum = const Duration(seconds: 8),
    this.step = const Duration(seconds: 1),
    bool Function()? cancelled,
    @visibleForTesting Future<void> Function(Duration step)? wait,
  }) : _poll = poll,
       _arrivals = arrivals,
       _cancelled = cancelled,
       _wait = wait ?? Future<void>.delayed;

  final Future<void> Function() _poll;
  final Stream<bool> _arrivals;
  final bool Function()? _cancelled;
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
      while (elapsed + step <= budget && !(_cancelled?.call() ?? false)) {
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

/// One node per identity: while a locked receiver runs its node in this
/// process, the app's own node must not start. The app's node config is
/// read through [protector], which waits until the receiver let go: the one
/// in this isolate ([hold], [release]), and one in an engine without a
/// screen (ZenBackgroundBridge.swift), whose isolate has a gate of its own,
/// so only the native side can tell when it stopped its node (`nodeFree`).
abstract final class IosNodeGate {
  static Completer<void>? _held;

  /// The longest the app's node waits for each (a receiver that never let
  /// go must not keep the app offline for good; the bridge then refuses a
  /// second node with the same key, and the app's start retries).
  static const Duration maxWait = Duration(seconds: 30);

  /// Completes once no engine without a screen runs a node (tests replace
  /// it).
  @visibleForTesting
  static Future<void> Function() headlessFree = _askNodeFree;

  static bool get isHeld => _held != null;

  static void hold() => _held ??= Completer<void>();

  static void release() {
    final Completer<void>? held = _held;
    _held = null;
    held?.complete();
  }

  /// Completes once no receiver holds the node.
  static Future<void> free() async {
    final Completer<void>? held = _held;
    if (held != null) {
      await held.future.timeout(
        maxWait,
        onTimeout: () => logZenWarning(
          'The locked receiver kept the node too long; the app starts its own.',
        ),
      );
    }
    await headlessFree().timeout(
      maxWait,
      onTimeout: () => logZenWarning(
        'The background engine kept the node too long; the app starts its own.',
      ),
    );
  }

  static Future<void> _askNodeFree() async {
    try {
      await _channel.invokeMethod<Object?>('nodeFree');
    } on MissingPluginException {
      // Not an iPhone: no engine without a screen.
    } on PlatformException catch (error) {
      logZenWarning('zen/background nodeFree: ${error.message}');
    }
  }

  /// [inner], opening the node config only once the node is free.
  static KeyedBinaryPayloadProtector protector(
    KeyedBinaryPayloadProtector inner,
  ) => _GatedProtector(inner);
}

final class _GatedProtector implements KeyedBinaryPayloadProtector {
  const _GatedProtector(this._inner);

  final KeyedBinaryPayloadProtector _inner;

  @override
  bool isSealed(Uint8List payload) => _inner.isSealed(payload);

  @override
  Future<Uint8List> seal(Uint8List payload) => _inner.seal(payload);

  @override
  Future<Uint8List> unseal(Uint8List payload) => _inner.unseal(payload);

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) =>
      _inner.sealFor(storageKey, payload);

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async {
    await IosNodeGate.free();
    return _inner.unsealFor(storageKey, payload);
  }
}

/// What an iPhone does whenever iOS lets Zen run off the screen, for as
/// long as the app's isolate lives (docs/IOS_BACKGROUND.md). It owns the
/// channel of ZenBackgroundBridge.swift:
///  - tells the native side whether Zen can receive in the background now
///    (`ready`: the unlocked app runs, or the locked receiver does) and
///    whether the person chose the keep-alive;
///  - answers the background checks iOS wakes Zen for (`catchUp`): the
///    unlocked app's own check ([attachApp]), or, while Zen is locked, the
///    locked receiver's ([runLockedCatchUp]);
///  - runs the locked receiver from the moment Zen locks ([appLocked]) or a
///    check finds it locked, until it is unlocked again — the app's node is
///    stopped first and stays down meanwhile ([IosNodeGate]).
final class IosBackgroundHost {
  IosBackgroundHost({
    required AppSecurityService security,
    required bool Function() keepAlive,
    required Future<IosLockedSession?> Function() openSession,
    required Future<void> Function() stopAppNode,
    MethodChannel channel = _channel,
  }) : _security = security,
       _keepAlive = keepAlive,
       _openSessionWith = openSession,
       _stopAppNode = stopAppNode,
       _methods = channel;

  final AppSecurityService _security;
  final bool Function() _keepAlive;
  final Future<IosLockedSession?> Function() _openSessionWith;
  final Future<void> Function() _stopAppNode;
  final MethodChannel _methods;

  /// The host whose handler the channel has (a new account's app makes a
  /// new one before the old one goes).
  static IosBackgroundHost? _current;

  Future<bool> Function(Duration budget)? _appCheck;
  bool _appSeen = false;
  IosLockedSession? _session;

  /// Zen locked and the receiver is being started: Zen stays "ready"
  /// meanwhile, so iOS does not suspend it halfway.
  int _handovers = 0;
  Future<void> _work = Future<void>.value();
  Future<bool>? _catchUp;
  bool? _sentReady;
  bool? _sentKeepAlive;
  bool _disposed = false;

  /// Whether the unlocked app ran in this isolate (and so set up the
  /// notifications the locked receiver posts with).
  bool get appSeen => _appSeen;

  /// The locked receiver runs.
  bool get receiving => _session != null;

  /// Completes once the opening or closing of the locked receiver asked for
  /// so far is done.
  Future<void> get idle => _work;

  bool get _locked => isSecurityBlockingUi(_security);

  void start() {
    _current = this;
    _methods.setMethodCallHandler(_handleCall);
    _security.addListener(_onSecurityChanged);
    _configure();
  }

  Future<void> dispose() async {
    _disposed = true;
    _security.removeListener(_onSecurityChanged);
    if (identical(_current, this)) {
      _current = null;
      _methods.setMethodCallHandler(null);
      _send(ready: false, keepAlive: false);
    }
    await _enqueue(_closeSession);
  }

  /// The unlocked app runs and checks with [check] (the relay engine).
  void attachApp(Future<bool> Function(Duration budget) check) {
    _appCheck = check;
    _appSeen = true;
    _configure();
  }

  void detachApp() {
    _appCheck = null;
    _configure();
  }

  /// The app locked: once [kitsWritten] (what the receiver reads), the
  /// locked receiver takes over.
  Future<void> appLocked({Future<void>? kitsWritten}) {
    _handovers += 1;
    detachApp();
    return _enqueue(() async {
      try {
        await kitsWritten;
      } on Object catch (error, stackTrace) {
        logZenError('Writing the locked kits failed', error, stackTrace);
      }
      await _openSession();
    }).whenComplete(() {
      _handovers -= 1;
      _configure();
    });
  }

  /// The keep-alive setting changed.
  void refresh() => _configure();

  void _onSecurityChanged() {
    if (_disposed) {
      return;
    }
    if (!_locked && _session != null) {
      unawaitedLogged(
        _enqueue(_closeSession),
        context: 'Stopping the locked receiver failed',
      );
    }
    _configure();
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final Future<void> next = _work.then((_) async {
      try {
        await job();
      } on Object catch (error, stackTrace) {
        logZenError('The locked receiver (iOS) failed', error, stackTrace);
      }
    });
    _work = next;
    return next;
  }

  Future<void> _openSession() async {
    if (_session != null || !_locked || _disposed) {
      return;
    }
    IosNodeGate.hold();
    IosLockedSession? session;
    try {
      // One node per identity: the app's goes down first.
      await _stopAppNode();
      session = await _openSessionWith();
      if (session == null) {
        logZenMessage('Locked receiver (iOS): no background capability yet.');
        return;
      }
      if (!_locked || _disposed) {
        await session.dispose();
        session = null;
        return;
      }
      _session = session;
      await session.start();
      logZenMessage('Zen is locked: the locked receiver runs (iOS).');
    } finally {
      if (_session == null) {
        IosNodeGate.release();
      }
      _configure();
    }
  }

  Future<void> _closeSession() async {
    final IosLockedSession? session = _session;
    _session = null;
    try {
      await session?.dispose();
      if (session != null) {
        logZenMessage('Zen is unlocked: the locked receiver stopped (iOS).');
      }
    } finally {
      IosNodeGate.release();
      _configure();
    }
  }

  void _configure() {
    if (_disposed || !identical(_current, this)) {
      return;
    }
    _send(
      ready: _locked ? _session != null || _handovers > 0 : _appCheck != null,
      keepAlive: _keepAlive(),
    );
  }

  void _send({required bool ready, required bool keepAlive}) {
    if (ready == _sentReady && keepAlive == _sentKeepAlive) {
      return;
    }
    _sentReady = ready;
    _sentKeepAlive = keepAlive;
    unawaitedLogged(
      _methods.invokeMethod<Object?>('configure', <String, Object?>{
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
        // A refresh, a charging catch-up and a Shortcuts run at once share
        // one check.
        return _catchUp ??= check(budget).whenComplete(() {
          _catchUp = null;
        });
      default:
        throw MissingPluginException('zen/background: ${call.method}');
    }
  }

  /// One background check; `false` when Zen could not check.
  @visibleForTesting
  Future<bool> check(Duration budget) async {
    if (_disposed) {
      return false;
    }
    if (!_locked) {
      final Future<bool> Function(Duration budget)? app = _appCheck;
      if (app == null) {
        logZenMessage('Background check (iOS) skipped: Zen is not running.');
        return false;
      }
      return app(budget);
    }
    await _enqueue(_openSession);
    final IosLockedSession? session = _session;
    if (session == null) {
      logZenMessage('Background check (iOS) skipped: no locked receiver.');
      return false;
    }
    final Stopwatch watch = Stopwatch()..start();
    final int frames = await runLockedCatchUp(
      session,
      budget,
      cancelled: () => _session == null,
    );
    logZenMessage(
      'Background check (iOS, locked): $frames frames in '
      '${watch.elapsed.inSeconds} s.',
    );
    return true;
  }
}

/// The [IosBackgroundHost] of this app (`null` where there is none). The
/// app reads it at start, so a background check finds it also while Zen is
/// locked.
final Provider<IosBackgroundHost?> iosBackgroundHostProvider =
    Provider<IosBackgroundHost?>((Ref ref) {
      if (!ref.watch(iosBackgroundBridgeEnabledProvider)) {
        return null;
      }
      late final IosBackgroundHost host;
      host = IosBackgroundHost(
        security: ref.read(appSecurityServiceProvider),
        keepAlive: () =>
            ref.read(appSettingsControllerProvider).keepReceivingInBackground,
        openSession: () async {
          final RuntimeSystemNotificationService notices = ref.read(
            runtimeSystemNotificationServiceProvider,
          );
          if (!host.appSeen) {
            // Not unlocked since Zen started: the notices are not set up.
            await notices.initialize(onOpenRoute: (String routeKey) async {});
          }
          return openIosLockedSession(
            settings: ref.read(appSettingsControllerProvider),
            notices: notices,
          );
        },
        // What the lock on the screen stops anyway; a lock in the
        // background draws no frame, so it is stopped here.
        stopAppNode: () async {
          await ref.read(zenCoreProvider).stop();
          await ref.read(runtimeNodeRuntimeProvider).stop();
        },
      );
      ref.listen<bool>(
        appSettingsControllerProvider.select(
          (AppSettings settings) => settings.keepReceivingInBackground,
        ),
        (bool? previous, bool next) => host.refresh(),
      );
      ref.onDispose(() {
        unawaitedLogged(
          host.dispose(),
          context: 'Closing the background host failed',
        );
      });
      host.start();
      return host;
    });

/// The unlocked app's part of the iPhone's time off the screen
/// (docs/IOS_BACKGROUND.md):
///  - the background check iOS wakes Zen for while it is unlocked
///    ([IosCatchUp] on the relay engine): the friends' mailboxes are asked
///    for what they hold, and what comes in is handled as always off the
///    screen (stored, with a notification);
///  - what the locked receiver needs later, kept in step: whom to take mail
///    from (the background capability), what this device still has to send
///    and the mail it holds for friends (the outbox and mailbox kits); the
///    notice kit is [LockedNoticeKitBridge]'s;
///  - the lock: the kits are written and the [IosBackgroundHost] takes over;
///  - after unlock: what the locked receiver kept is opened and handed to
///    the app, and the mail it held for friends taken over.
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
  IosBackgroundHost? _host;
  AppSecurityService? _security;
  bool _handedOff = false;
  LockedOutboxKitWriter? _outboxKitWriter;
  LockedMailboxKitWriter? _mailboxKitWriter;
  BackgroundCapabilityPublisher? _capabilityPublisher;
  Future<void> _publishing = Future<void>.value();
  bool _draining = false;
  bool _drained = false;
  Timer? _drainRetry;
  int _drainTries = 0;

  @override
  void initState() {
    super.initState();
    final IosBackgroundHost? host = ref.read(iosBackgroundHostProvider);
    if (host == null) {
      return;
    }
    _host = host;
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    security.addListener(_onSecurityChanged);
    _security = security;
    if (isSecurityBlockingUi(security)) {
      return;
    }
    host.attachApp(_runCatchUp);
    unawaitedLogged(_afterUnlock(), context: 'Taking over from the lock');
  }

  @override
  void dispose() {
    final IosBackgroundHost? host = _host;
    if (host != null) {
      _security?.removeListener(_onSecurityChanged);
      if (!_handedOff &&
          _security != null &&
          isSecurityBlockingUi(_security!)) {
        _handOff();
      } else if (!_handedOff) {
        host.detachApp();
      }
      _outboxKitWriter?.detach();
      _mailboxKitWriter?.detach();
      _drainRetry?.cancel();
    }
    super.dispose();
  }

  void _onSecurityChanged() {
    final AppSecurityService? security = _security;
    if (mounted && security != null && isSecurityBlockingUi(security)) {
      _handOff();
    }
  }

  /// Zen locked: what the locked receiver reads is written, then the host
  /// runs it. Everything is read before the first wait: the lock screen
  /// replaces this widget on the next frame.
  void _handOff() {
    final IosBackgroundHost? host = _host;
    if (_handedOff || host == null) {
      return;
    }
    _handedOff = true;
    final Future<void> kits = Future.wait(<Future<void>>[
      _publishCapability(),
      _outboxKitWriter?.flush() ?? Future<void>.value(),
      _mailboxKitWriter?.flush() ?? Future<void>.value(),
    ]);
    unawaitedLogged(
      host.appLocked(kitsWritten: kits),
      context: 'Handing over to the locked receiver failed',
    );
  }

  /// Unlocked: once the locked receiver let go, the mail it held for friends
  /// is taken over, the kits are kept in step and the inbox is opened.
  Future<void> _afterUnlock() async {
    final IosBackgroundHost? host = _host;
    if (host == null) {
      return;
    }
    await host.idle;
    if (!mounted || _handedOff) {
      return;
    }
    _attachKitWriters();
    unawaitedLogged(
      _publishCapability(),
      context: 'Publishing the background capability failed',
    );
    await _drainInbox();
  }

  void _attachKitWriters() {
    final RelayEngine? relay = ref.read(relayEngineProvider);
    if (relay == null || _outboxKitWriter != null) {
      return;
    }
    final SupportDirectoryResolver support = ref.read(
      supportDirectoryResolverProvider,
    );
    final AppSecurityCredentialsStore credentials = ref
        .read(appSecurityServiceProvider)
        .credentialsStore;
    _outboxKitWriter = LockedOutboxKitWriter(
      engine: relay,
      write: (Object? json) => lockedOutboxKitFile(
        supportDirectory: support,
        credentials: credentials,
        createKey: true,
      ).write(json),
    )..attach();
    // Attaching takes over what the locked receiver held for friends.
    _mailboxKitWriter = LockedMailboxKitWriter(
      engine: relay,
      write: (Object? json) => lockedMailboxKitFile(
        supportDirectory: support,
        credentials: credentials,
        createKey: true,
      ).write(json),
      readHeld: () => lockedMailboxHeldFile(
        supportDirectory: support,
        credentials: credentials,
      ).read(),
    )..attach();
  }

  /// Tells the locked receiver who counts as a contact and the public part
  /// of the inbox key. Only once the friends were read: an empty list then
  /// must not replace the one stored. Everything is read before the first
  /// wait.
  Future<void> _publishCapability() {
    if (!mounted) {
      return _publishing;
    }
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    final SocialHubState state = ref.read(socialHubControllerProvider);
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final AccountDeviceDirectory? directory = ref
        .read(accountDirectoryHolderProvider)
        .directory;
    final List<String> mailboxes =
        ref.read(relayEngineProvider)?.overview.value.relays ??
        const <String>[];
    final BackgroundCapabilityPublisher publisher = _capabilityPublisher ??=
        BackgroundCapabilityPublisher(ref.read(backgroundVaultProvider));
    if (!hub.isHydrated || state.snapshotUnreadable) {
      return _publishing;
    }
    _publishing = _publishing
        .then((_) async {
          await publisher.publish(
            masterKey: await security.currentEncryptionKey(),
            state: state,
            directory: directory,
            mailboxes: mailboxes,
          );
        })
        .catchError((Object error, StackTrace stackTrace) {
          logZenError(
            'Publishing the background capability failed',
            error,
            stackTrace,
          );
        });
    return _publishing;
  }

  /// Opens what the locked receiver kept and hands it to the app as if it
  /// had just arrived: only unlocked, with the receiver stopped, the app's
  /// services listening and its node up — otherwise it waits.
  Future<void> _drainInbox() async {
    if (_draining || _drained || !mounted) {
      return;
    }
    final IosBackgroundHost? host = _host;
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final BackgroundVault vault = ref.read(backgroundVaultProvider);
    final ZenCore core = ref.read(zenCoreProvider);
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
    final RuntimeSystemNotificationService notices = ref.read(
      runtimeSystemNotificationServiceProvider,
    );
    final EncounterLog encounters = ref.read(encounterLogProvider);
    _draining = true;
    try {
      if (host == null || host.receiving || isSecurityBlockingUi(security)) {
        return;
      }
      final Uint8List? masterKey = await security.currentEncryptionKey();
      if (masterKey == null) {
        return;
      }
      if (!await vault.hasInbox()) {
        _drained = true;
        return;
      }
      // The app's services have to be listening before anything is handed
      // to them.
      await core.start();
      await hub.whenHydrated;
      if (!mounted ||
          ref.read(socialHubControllerProvider).snapshotUnreadable) {
        return;
      }
      if (!runtime.snapshot.serviceRunning) {
        // The node comes up a moment after the unlock.
        if (_drainTries++ < 20) {
          _drainRetry?.cancel();
          _drainRetry = Timer(const Duration(seconds: 3), () {
            if (mounted) {
              unawaitedLogged(_drainInbox(), context: 'Draining the inbox');
            }
          });
        }
        return;
      }
      final int delivered = await drainLockedInbox(
        vault: vault,
        masterKey: masterKey,
        runtime: runtime,
        notices: notices,
        encounters: encounters,
        self: runtime.snapshot.localAddress,
      );
      _drained = true;
      logZenMessage(
        'Drained $delivered frame(s) kept while the app was locked (iOS).',
      );
    } on Object catch (error, stackTrace) {
      logZenError('Draining the inbox failed', error, stackTrace);
    } finally {
      _draining = false;
    }
  }

  /// The background check while Zen is unlocked: the relay engine asks the
  /// mailboxes.
  Future<bool> _runCatchUp(Duration budget) async {
    if (!mounted) {
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
