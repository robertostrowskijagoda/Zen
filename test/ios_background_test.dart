import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/presentation/ios_background_section.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

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
          });
      expect(status.refresh, IosBackgroundRefresh.available);
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
        contains('zablokowany albo zamknięty'),
      );
    });

    test('the lock note shows only for the lock after leaving the app', () {
      expect(
        iosLockEndsBackground(
          MemoryAppSecurityService(
            hasPassword: true,
            settings: const AppSettings(lockMode: AppLockMode.background),
          ),
        ),
        isTrue,
      );
      expect(
        iosLockEndsBackground(
          MemoryAppSecurityService(
            hasPassword: true,
            settings: const AppSettings(lockMode: AppLockMode.appClose),
          ),
        ),
        isFalse,
      );
      expect(iosLockEndsBackground(MemoryAppSecurityService()), isFalse);
    });
  });

  test('the keep-alive is off by default and survives a round trip', () {
    expect(const AppSettings().keepReceivingInBackground, isFalse);
    final AppSettings restored = AppSettings.fromJson(
      const AppSettings(keepReceivingInBackground: true).toJson(),
    );
    expect(restored.keepReceivingInBackground, isTrue);
  });

  group('IosBackgroundBridge', () {
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
    });

    Future<ProviderContainer> pump(
      WidgetTester tester,
      AppSecurityService security,
    ) async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          iosBackgroundBridgeEnabledProvider.overrideWithValue(true),
          appSecurityServiceProvider.overrideWithValue(security),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const IosBackgroundBridge(child: SizedBox()),
        ),
      );
      await tester.pump();
      return container;
    }

    Future<Object?> callFromNative(WidgetTester tester, MethodCall call) async {
      ByteData? reply;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(call),
        (ByteData? data) => reply = data,
      );
      return const StandardMethodCodec().decodeEnvelope(reply!);
    }

    testWidgets('tells the iPhone when Zen may run and the keep-alive', (
      WidgetTester tester,
    ) async {
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        hasPassword: true,
      );
      final ProviderContainer container = await pump(tester, security);
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments, <String, Object?>{
        'ready': true,
        'keepAlive': false,
      });

      await container
          .read(appSettingsControllerProvider.notifier)
          .setKeepReceivingInBackground(true);
      await tester.pump();
      expect(calls.last.arguments, <String, Object?>{
        'ready': true,
        'keepAlive': true,
      });

      // Locked (in the background no frame comes): nothing runs any more.
      security.lock();
      await tester.pump();
      expect(calls.last.arguments, <String, Object?>{
        'ready': false,
        'keepAlive': true,
      });
      expect(calls, hasLength(3));

      await tester.pumpWidget(const SizedBox());
      expect(calls.last.arguments, <String, Object?>{
        'ready': false,
        'keepAlive': false,
      });
    });

    testWidgets('a background check is refused while locked', (
      WidgetTester tester,
    ) async {
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        hasPassword: true,
        locked: true,
      );
      await pump(tester, security);
      expect(calls.single.arguments, <String, Object?>{
        'ready': false,
        'keepAlive': false,
      });
      expect(
        await callFromNative(
          tester,
          const MethodCall('catchUp', <String, Object?>{'seconds': 5}),
        ),
        isFalse,
      );
    });

    testWidgets('without a running node there is nothing to check', (
      WidgetTester tester,
    ) async {
      await pump(tester, MemoryAppSecurityService());
      expect(
        await callFromNative(
          tester,
          const MethodCall('catchUp', <String, Object?>{'seconds': 5}),
        ),
        isFalse,
      );
    });
  });
}
