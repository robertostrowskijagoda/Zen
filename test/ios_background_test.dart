import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/ios_locked_receiver.dart';
import 'package:zen/src/features/runtime/presentation/ios_background_section.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// A catch-up on a clock that moves only when it waits; [onTime] runs at
/// each second (frames "arrive" there).
({IosCatchUp catchUp, List<Duration> polls, Duration Function() now}) _catchUp({
  void Function(Duration now, StreamController<bool> arrivals)? onTime,
  Future<void> Function()? poll,
}) {
  final StreamController<bool> arrivals = StreamController<bool>.broadcast(
    sync: true,
  );
  Duration now = Duration.zero;
  final List<Duration> polls = <Duration>[];
  final IosCatchUp catchUp = IosCatchUp(
    poll: () async {
      polls.add(now);
      await poll?.call();
    },
    arrivals: arrivals.stream,
    wait: (Duration step) async {
      now += step;
      onTime?.call(now, arrivals);
    },
  );
  return (catchUp: catchUp, polls: polls, now: () => now);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IosBackgroundStatus', () {
    test('reads what the iPhone reports', () {
      final IosBackgroundStatus status =
          IosBackgroundStatus.fromMap(<String, Object?>{
            'refresh': 'available',
            'lowPower': false,
            'keepAlive': true,
            'lastRunAt': 1700000000000,
            'lastRunResult': 'done',
            'runs': 4,
            'notifications': 'denied',
            'lastShortcutAt': 1700000100000,
            'shortcutRuns': 2,
          });
      expect(status.refresh, IosBackgroundRefresh.available);
      expect(status.notifications, IosNotifications.denied);
      expect(status.lastShortcutAtMillis, 1700000100000);
      expect(status.shortcutRuns, 2);
      expect(status.keepAlive, isTrue);
      expect(status.lastRunAtMillis, 1700000000000);
      expect(status.lastRunResult, 'done');
      expect(status.runs, 4);
      expect(status.canRefresh, isTrue);
    });

    test('anything else is "not known", never an error', () {
      final IosBackgroundStatus status = IosBackgroundStatus.fromMap(
        <String, Object?>{'refresh': 'sideways', 'runs': 'many'},
      );
      expect(status.refresh, IosBackgroundRefresh.unknown);
      expect(status.runs, 0);
      expect(status.notifications, IosNotifications.unknown);
      expect(status.canRefresh, isFalse);
      expect(
        IosBackgroundStatus.fromMap(null).refresh,
        IosBackgroundRefresh.unknown,
      );
    });

    test('Low Power Mode or the switch off means no background refresh', () {
      expect(
        const IosBackgroundStatus(
          refresh: IosBackgroundRefresh.available,
          lowPower: true,
        ).canRefresh,
        isFalse,
      );
      expect(
        const IosBackgroundStatus(
          refresh: IosBackgroundRefresh.denied,
        ).canRefresh,
        isFalse,
      );
    });
  });

  group('IosCatchUp', () {
    test('ends at the next step once cancelled', () async {
      bool cancelled = false;
      Duration now = Duration.zero;
      final IosCatchUp catchUp = IosCatchUp(
        poll: () async {},
        arrivals: const Stream<bool>.empty(),
        cancelled: () => cancelled,
        wait: (Duration step) async {
          now += step;
          cancelled = now >= const Duration(seconds: 2);
        },
      );
      await catchUp.run(const Duration(seconds: 25));
      expect(now, const Duration(seconds: 2));
    });

    test('asks the mailboxes and ends once mail stopped coming', () async {
      final c = _catchUp(
        onTime: (Duration now, StreamController<bool> arrivals) {
          if (now == const Duration(seconds: 3) ||
              now == const Duration(seconds: 4)) {
            arrivals.add(true);
          }
        },
      );
      final int frames = await c.catchUp.run(const Duration(seconds: 25));
      expect(frames, 2);
      expect(c.polls, <Duration>[Duration.zero]);
      // Quiet for 5 s after the last frame (4 s), past the 8 s minimum.
      expect(c.now(), const Duration(seconds: 9));
    });

    test('asks once more when the links came back without an answer', () async {
      final c = _catchUp(
        onTime: (Duration now, StreamController<bool> arrivals) {
          if (now == const Duration(seconds: 2)) {
            arrivals.add(false); // a friend's ping: the links are up
          }
          if (now == const Duration(seconds: 4)) {
            arrivals.add(true);
          }
        },
      );
      expect(await c.catchUp.run(const Duration(seconds: 25)), 2);
      expect(c.polls, <Duration>[Duration.zero, const Duration(seconds: 2)]);
      expect(c.now(), const Duration(seconds: 9));
    });

    test('asks again while nothing came, then uses the whole budget', () async {
      final c = _catchUp();
      final int frames = await c.catchUp.run(const Duration(seconds: 25));
      expect(frames, 0);
      expect(c.polls, <Duration>[
        Duration.zero,
        const Duration(seconds: 8),
        const Duration(seconds: 16),
      ]);
      expect(c.now(), const Duration(seconds: 25));
    });

    test('never runs past the budget, also while mail keeps coming', () async {
      final c = _catchUp(
        onTime: (Duration now, StreamController<bool> arrivals) =>
            arrivals.add(true),
      );
      expect(await c.catchUp.run(const Duration(seconds: 6)), 6);
      expect(c.now(), const Duration(seconds: 6));
    });

    test('a failing ask does not end the check', () async {
      final c = _catchUp(poll: () async => throw StateError('node down'));
      expect(await c.catchUp.run(const Duration(seconds: 10)), 0);
      expect(c.polls, hasLength(2));
      expect(c.now(), const Duration(seconds: 10));
    });
  });

  group('settings page texts', () {
    test('what iOS allows', () {
      expect(
        iosBackgroundRefreshText(
          const IosBackgroundStatus(refresh: IosBackgroundRefresh.denied),
        ),
        contains('Ogólne → Odświeżanie w tle'),
      );
      expect(
        iosBackgroundRefreshText(
          const IosBackgroundStatus(
            refresh: IosBackgroundRefresh.available,
            lowPower: true,
          ),
        ),
        contains('niskiego zużycia energii'),
      );
    });

    test('the last wake-up, and how many there were', () {
      expect(
        iosLastCheckText(const IosBackgroundStatus()),
        'iOS jeszcze nie obudził Zen w tle.',
      );
      final String text = iosLastCheckText(
        const IosBackgroundStatus(
          lastRunAtMillis: 1700000000000,
          lastRunResult: 'done',
          runs: 3,
        ),
        at: (DateTime at) => 'TIME',
      );
      expect(text, contains('TIME (skrzynki sprawdzone)'));
      expect(text, contains('Od instalacji: 3 razy.'));
      expect(
        iosLastCheckText(
          const IosBackgroundStatus(
            lastRunAtMillis: 1700000000000,
            lastRunResult: 'notReady',
            runs: 1,
          ),
          at: (DateTime at) => 'TIME',
        ),
        contains('nie mógł sprawdzić'),
      );
    });

    test('the last Shortcuts run, and how many there were', () {
      expect(
        iosShortcutRunText(const IosBackgroundStatus()),
        'Skróty jeszcze nie uruchomiły Zen.',
      );
      final String text = iosShortcutRunText(
        const IosBackgroundStatus(
          lastShortcutAtMillis: 1700000000000,
          shortcutRuns: 5,
        ),
        at: (DateTime at) => 'TIME',
      );
      expect(text, contains('TIME'));
      expect(text, contains('Od instalacji: 5 razy.'));
      expect(iosShortcutSteps().join(' '), contains('Sprawdź wiadomości Zen'));
    });

    test('notifications', () {
      expect(
        iosNotificationsText(IosNotifications.denied),
        contains('wyłączone'),
      );
      expect(
        iosNotificationsText(IosNotifications.allowed),
        contains('włączone'),
      );
    });
  });

  test('the keep-alive is off by default and survives a round trip', () {
    expect(const AppSettings().keepReceivingInBackground, isFalse);
    final AppSettings restored = AppSettings.fromJson(
      const AppSettings(keepReceivingInBackground: true).toJson(),
    );
    expect(restored.keepReceivingInBackground, isTrue);
  });

  group('IosBackgroundHost', () {
    const MethodChannel channel = MethodChannel('zen/background');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return <String, Object?>{'refresh': 'available'};
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      IosNodeGate.release();
    });

    ({IosBackgroundHost host, List<String> log, List<_FakeSession> sessions})
    make(_Security security, {bool capability = true, bool keepAlive = false}) {
      final List<String> log = <String>[];
      final List<_FakeSession> sessions = <_FakeSession>[];
      final IosBackgroundHost host = IosBackgroundHost(
        security: security,
        keepAlive: () => keepAlive,
        stopAppNode: () async => log.add('app node stopped'),
        openSession: () async {
          log.add('open');
          if (!capability) {
            return null;
          }
          final _FakeSession session = _FakeSession(log);
          sessions.add(session);
          return session;
        },
      );
      addTearDown(host.dispose);
      host.start();
      return (host: host, log: log, sessions: sessions);
    }

    Map<Object?, Object?> lastConfigure() =>
        calls.lastWhere((MethodCall c) => c.method == 'configure').arguments
            as Map<Object?, Object?>;

    test(
      'unlocked, the app checks; locked, the locked receiver does',
      () async {
        final _Security security = _Security();
        final h = make(security);
        expect(lastConfigure(), <String, Object?>{
          'ready': false,
          'keepAlive': false,
        });
        // Not running yet: nothing to check with.
        expect(await h.host.check(const Duration(seconds: 1)), isFalse);

        h.host.attachApp((Duration budget) async => true);
        expect(lastConfigure()['ready'], isTrue);
        expect(await h.host.check(const Duration(seconds: 1)), isTrue);
        expect(h.log, isEmpty);

        // Zen locks: the app's node goes down first, then the receiver runs
        // and holds the node.
        security.lock();
        await h.host.appLocked(kitsWritten: Future<void>.value());
        expect(h.log, <String>['app node stopped', 'open', 'start']);
        expect(h.host.receiving, isTrue);
        expect(IosNodeGate.isHeld, isTrue);
        expect(lastConfigure()['ready'], isTrue);

        expect(await h.host.check(const Duration(seconds: 1)), isTrue);
        expect(h.sessions.single.catchUps, greaterThan(0));

        // Unlocked: the receiver stops and the app's node may start again.
        security.open();
        await h.host.idle;
        expect(h.log.last, 'dispose');
        expect(h.host.receiving, isFalse);
        expect(IosNodeGate.isHeld, isFalse);
        expect(lastConfigure()['ready'], isFalse);
      },
    );

    test('a check while locked starts the receiver itself', () async {
      final _Security security = _Security(locked: true);
      final h = make(security, keepAlive: true);
      expect(lastConfigure(), <String, Object?>{
        'ready': false,
        'keepAlive': true,
      });
      expect(await h.host.check(const Duration(seconds: 1)), isTrue);
      expect(h.log.take(3), <String>['app node stopped', 'open', 'start']);
      expect(lastConfigure()['ready'], isTrue);
    });

    test('without a capability nothing runs and the node stays free', () async {
      final _Security security = _Security(locked: true);
      final h = make(security, capability: false);
      expect(await h.host.check(const Duration(seconds: 1)), isFalse);
      expect(h.host.receiving, isFalse);
      expect(IosNodeGate.isHeld, isFalse);
      expect(lastConfigure()['ready'], isFalse);
    });

    test('a check asked for by the iPhone reaches the host', () async {
      final _Security security = _Security();
      final h = make(security);
      h.host.attachApp((Duration budget) async => budget.inSeconds == 7);
      ByteData? reply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('catchUp', <String, Object?>{'seconds': 7}),
            ),
            (ByteData? data) => reply = data,
          );
      expect(const StandardMethodCodec().decodeEnvelope(reply!), isTrue);
    });

    test(
      'the app\'s node config opens only once the receiver let go',
      () async {
        final KeyedBinaryPayloadProtector gated = IosNodeGate.protector(
          const _PlainProtector(),
        );
        IosNodeGate.hold();
        bool opened = false;
        final Future<void> open = gated
            .unsealFor('node', Uint8List.fromList(<int>[1]))
            .then((_) => opened = true);
        await Future<void>.delayed(Duration.zero);
        expect(opened, isFalse);
        IosNodeGate.release();
        await open;
        expect(opened, isTrue);
        // The native side was asked whether an engine without a screen
        // still runs a node.
        expect(calls.map((MethodCall c) => c.method), contains('nodeFree'));
      },
    );

    test(
      'the app\'s node config waits for the engine without a screen too',
      () async {
        final Future<void> Function() original = IosNodeGate.headlessFree;
        addTearDown(() => IosNodeGate.headlessFree = original);
        final Completer<void> headlessStopped = Completer<void>();
        IosNodeGate.headlessFree = () => headlessStopped.future;
        final KeyedBinaryPayloadProtector gated = IosNodeGate.protector(
          const _PlainProtector(),
        );
        bool opened = false;
        final Future<void> open = gated
            .unsealFor('node', Uint8List.fromList(<int>[1]))
            .then((_) => opened = true);
        await Future<void>.delayed(Duration.zero);
        // Nothing holds the gate in this isolate, yet the other engine's
        // node still runs.
        expect(IosNodeGate.isHeld, isFalse);
        expect(opened, isFalse);
        headlessStopped.complete();
        await open;
        expect(opened, isTrue);
      },
    );
  });
}

/// A security service whose lock the test turns.
final class _Security extends ChangeNotifier implements AppSecurityService {
  _Security({bool locked = false}) : _locked = locked;

  bool _locked;

  @override
  bool get isReady => true;

  @override
  bool get encryptionEnabled => true;

  @override
  bool get hasPassword => true;

  @override
  bool get isLocked => _locked;

  @override
  void lock() {
    _locked = true;
    notifyListeners();
  }

  void open() {
    _locked = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A locked receiver that only says what was done with it; a mailbox
/// answers each ask.
final class _FakeSession implements IosLockedSession {
  _FakeSession(this._log);

  final List<String> _log;
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast(sync: true);
  int catchUps = 0;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async => _log.add('start');

  @override
  Future<void> catchUp() async {
    catchUps += 1;
    _frames.add(
      const SignalTransportFrame(
        from: 'mailbox',
        payload: <String, dynamic>{'type': 'rly_mail'},
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  Future<void> dispose() async => _log.add('dispose');
}

final class _PlainProtector implements KeyedBinaryPayloadProtector {
  const _PlainProtector();

  @override
  bool isSealed(Uint8List payload) => true;

  @override
  Future<Uint8List> seal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> unseal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async =>
      payload;

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async =>
      payload;
}
