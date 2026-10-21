import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';

void main() {
  group('ZenCore', () {
    test('starts the modules in registry order, one after another', () async {
      final List<String> log = <String>[];
      final Completer<void> signalUp = Completer<void>();
      final ZenCore core = _core(<ZenModule>[
        _Recording('signal', log, startGate: signalUp.future),
        _Recording('ledger', log),
        _Recording('meet', log),
      ]);

      final Future<void> started = core.start();
      await _settle();
      // The next module waits until the one before has started.
      expect(log, <String>['start signal']);
      expect(core.runningModules, isEmpty);

      signalUp.complete();
      await started;
      expect(log, <String>['start signal', 'start ledger', 'start meet']);
      expect(core.runningModules, <String>['signal', 'ledger', 'meet']);
      expect(core.isStarted, isTrue);
      await core.stop();
    });

    test('stops the modules in reverse order, timers at once', () async {
      final List<String> log = <String>[];
      final ZenCore core = _core(<ZenModule>[
        _Recording('signal', log),
        _Recording('ledger', log),
        _Recording('meet', log),
      ]);
      await core.start();
      log.clear();

      // Synchronous stops all run in the call itself (no pending timers
      // after a widget test's tree goes away).
      unawaited(core.stop());
      expect(log, <String>['stop meet', 'stop ledger', 'stop signal']);
      expect(core.isStarted, isFalse);
      expect(core.runningModules, isEmpty);

      // Nothing runs after the stop.
      core
        ..resumed()
        ..setInteractive(true);
      expect(log, <String>['stop meet', 'stop ledger', 'stop signal']);
    });

    test('does not start the modules of disabled features', () async {
      final List<String> log = <String>[];
      final Completer<FeatureFlags> flags = Completer<FeatureFlags>();
      final ZenCore core = ZenCore(
        modules: <ZenModule>[
          _Recording('signal', log),
          _Recording('dating', log, feature: ZenFeature.dating),
          _Recording('pyramid', log, feature: ZenFeature.pyramid),
          _Recording('plan', log),
        ],
        loadFlags: () => flags.future,
      );

      final Future<void> started = core.start();
      await _settle();
      // The core starts at once; feature modules wait for the stored flags.
      expect(log, <String>['start signal']);
      flags.complete(
        const FeatureFlags().withFeature(ZenFeature.pyramid, false),
      );
      await started;
      expect(log, <String>['start signal', 'start dating', 'start plan']);
      expect(core.runningModules, <String>['signal', 'dating', 'plan']);
      await core.stop();
    });

    test('follows flags changed while it runs', () async {
      final List<String> log = <String>[];
      final ZenCore core = _core(<ZenModule>[
        _Recording('signal', log),
        _Recording('dating', log, feature: ZenFeature.dating),
        _Recording('pyramid', log, feature: ZenFeature.pyramid),
      ], flags: const FeatureFlags().withFeature(ZenFeature.pyramid, false));
      await core.start();
      log.clear();

      // The pyramid is on by default.
      core.applyFlags(
        const FeatureFlags().withFeature(ZenFeature.dating, false),
      );
      await _settle();
      expect(log, <String>['stop dating', 'start pyramid']);
      expect(core.runningModules, <String>['signal', 'pyramid']);
      await core.stop();
    });

    test('runs the minute duties of running modules only', () async {
      final List<String> log = <String>[];
      final ZenCore core = _core(
        <ZenModule>[
          _Recording('dating', log, feature: ZenFeature.dating),
          _Recording('pyramid', log, feature: ZenFeature.pyramid),
        ],
        flags: const FeatureFlags().withFeature(ZenFeature.pyramid, false),
        minute: const Duration(milliseconds: 10),
      );
      await core.start();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      await core.stop();
      final List<String> minutes = log
          .where((String e) => e.startsWith('minute'))
          .toList();
      expect(minutes, isNotEmpty);
      expect(minutes.first, 'minute dating 1');
      expect(
        minutes.every((String e) => e.startsWith('minute dating')),
        isTrue,
      );

      log.clear();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(log, isEmpty);
    });

    test('forwards resume and visibility to running modules', () async {
      final List<String> log = <String>[];
      final Completer<void> ledgerUp = Completer<void>();
      final ZenCore core = _core(<ZenModule>[
        _Recording('signal', log),
        _Recording('ledger', log, startGate: ledgerUp.future),
      ]);
      final Future<void> started = core.start();
      await _settle();

      core
        ..setInteractive(true)
        ..resumed();
      expect(log, <String>[
        'start signal',
        'start ledger',
        'interactive signal true',
        'resume signal',
      ]);

      // A module that starts later learns the current visibility.
      ledgerUp.complete();
      await started;
      expect(log.last, 'interactive ledger true');

      log.clear();
      core
        ..setInteractive(true)
        ..setInteractive(false);
      expect(log, <String>[
        'interactive signal false',
        'interactive ledger false',
      ]);
      await core.stop();
    });

    test('a stop during the start stops the module still starting', () async {
      final List<String> log = <String>[];
      final Completer<void> ledgerUp = Completer<void>();
      final ZenCore core = _core(<ZenModule>[
        _Recording('signal', log),
        _Recording('ledger', log, startGate: ledgerUp.future),
        _Recording('meet', log),
      ]);
      final Future<void> started = core.start();
      await _settle();
      await core.stop();
      // At once, the newest first; nothing more once its start completes.
      expect(log, <String>[
        'start signal',
        'start ledger',
        'stop ledger',
        'stop signal',
      ]);
      ledgerUp.complete();
      await started;
      expect(log, hasLength(4));
      expect(core.runningModules, isEmpty);
    });

    test('a module that fails to start is skipped', () async {
      final List<String> log = <String>[];
      final ZenCore core = _core(<ZenModule>[
        _Recording('signal', log, fails: true),
        _Recording('ledger', log),
      ]);
      await core.start();
      expect(log, <String>['start signal', 'stop signal', 'start ledger']);
      expect(core.runningModules, <String>['ledger']);
      await core.stop();
    });

    test('rejects duplicate module ids', () {
      expect(
        () => _core(<ZenModule>[
          _Recording('meet', <String>[]),
          _Recording('meet', <String>[]),
        ]),
        throwsArgumentError,
      );
    });
  });

  test('the app registry: the core first, features behind their flags', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final ZenCore core = container.read(zenCoreProvider);
    expect(core.modules.map((ZenModule m) => m.id), <String>[
      'signal',
      'ledger',
      'local-links',
      'feed',
      'meet',
      'neighbors',
      'dating',
      'pyramid',
      'plan',
    ]);
    expect(
      <String, ZenFeature?>{
        for (final ZenModule m in core.modules) m.id: m.feature,
      },
      <String, ZenFeature?>{
        'signal': null,
        'ledger': null,
        'local-links': null,
        'feed': null,
        'meet': null,
        'neighbors': null,
        'dating': ZenFeature.dating,
        'pyramid': ZenFeature.pyramid,
        'plan': null,
      },
    );
    // One core per app.
    expect(container.read(zenCoreProvider), same(core));
  });
}

ZenCore _core(
  List<ZenModule> modules, {
  FeatureFlags flags = const FeatureFlags(),
  Duration minute = const Duration(minutes: 1),
}) => ZenCore(modules: modules, loadFlags: () async => flags, minute: minute);

Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Recording extends ZenModule {
  _Recording(
    this.id,
    this.log, {
    this.feature,
    this.startGate,
    this.fails = false,
  });

  @override
  final String id;

  @override
  final ZenFeature? feature;

  final List<String> log;
  final Future<void>? startGate;
  final bool fails;

  @override
  Future<void> start() async {
    log.add('start $id');
    if (startGate != null) {
      await startGate;
    }
    if (fails) {
      throw StateError('$id cannot start');
    }
  }

  @override
  void stop() => log.add('stop $id');

  @override
  void onResume() => log.add('resume $id');

  @override
  void onMinute(int minute) => log.add('minute $id $minute');

  @override
  void onInteractiveChanged(bool interactive) =>
      log.add('interactive $id $interactive');
}
