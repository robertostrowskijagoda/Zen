import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/presentation/experimental_features_screen.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Uint8List _stored(FeatureFlags flags) =>
    Uint8List.fromList(utf8.encode(jsonEncode(flags.toJson())));

void main() {
  group('FeatureFlags', () {
    test('pyramid, wallet and dating on by default; neighbours are core', () {
      const FeatureFlags flags = FeatureFlags();
      expect(flags.isEnabled(ZenFeature.pyramid), isTrue);
      expect(flags.isEnabled(ZenFeature.wallet), isTrue);
      expect(flags.isEnabled(ZenFeature.dating), isTrue);
      expect(flags.showsTab('pyramid'), isTrue);
      expect(flags.showsTab('wallet'), isTrue);
      expect(flags.showsTab('dating'), isTrue);
      // Tabs of no feature always show; neighbours have no flag.
      expect(ZenFeature.ofTab('neighbors'), isNull);
      expect(flags.showsTab('neighbors'), isTrue);
      expect(flags.showsTab('chats'), isTrue);
    });

    test('a choice survives the round-trip; v is written', () {
      final FeatureFlags flags = const FeatureFlags()
          .withFeature(ZenFeature.pyramid, false)
          .withFeature(ZenFeature.dating, false);
      final Map<String, Object?> json = flags.toJson();
      expect(json['v'], 1);
      final FeatureFlags back = FeatureFlags.fromJson(
        jsonDecode(jsonEncode(json)),
      );
      expect(back, flags);
      expect(back.showsTab('pyramid'), isFalse);
      expect(back.showsTab('dating'), isFalse);
      expect(back.showsTab('wallet'), isTrue);
    });

    test('unknown or malformed values keep the defaults', () {
      expect(FeatureFlags.fromJson(null), const FeatureFlags());
      expect(FeatureFlags.fromJson('x'), const FeatureFlags());
      final FeatureFlags flags = FeatureFlags.fromJson(<String, Object?>{
        'on': <String, Object?>{
          'dating': 'no',
          'teleport': false,
          'neighbors': false,
        },
      });
      expect(flags, const FeatureFlags());
      expect(flags.isEnabled(ZenFeature.dating), isTrue);
    });

    test('the controller loads and saves the choices', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await disk.write(
        kFeatureFlagsKey,
        _stored(const FeatureFlags().withFeature(ZenFeature.dating, false)),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [ledgerDiskProvider.overrideWithValue(disk)],
      );
      addTearDown(container.dispose);
      expect(container.read(featureFlagsProvider), const FeatureFlags());
      await _settle();
      expect(
        container.read(featureFlagsProvider).isEnabled(ZenFeature.dating),
        isFalse,
      );
      await container
          .read(featureFlagsProvider.notifier)
          .setEnabled(ZenFeature.wallet, false);
      final FeatureFlags saved = FeatureFlags.fromJson(
        jsonDecode(utf8.decode(disk.files[kFeatureFlagsKey]!)),
      );
      expect(saved.isEnabled(ZenFeature.wallet), isFalse);
      expect(saved.isEnabled(ZenFeature.dating), isFalse);
    });
  });

  testWidgets('switched-off features leave the rail', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      kFeatureFlagsKey,
      _stored(
        const FeatureFlags()
            .withFeature(ZenFeature.pyramid, false)
            .withFeature(ZenFeature.wallet, false),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(disk),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const AppShellScreen(),
        ),
      ),
    );
    await tester.runAsync(_settle);
    await tester.pump();

    expect(find.byKey(const Key('side-tab-chats')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-neighbors')), findsOneWidget);
    // Dating sits in the "Więcej" sheet; pyramid and wallet are off.
    await tester.tap(find.byKey(const Key('side-tab-more')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('more-tab-dating')), findsOneWidget);
    expect(find.byKey(const Key('more-tab-pyramid')), findsNothing);
    expect(find.byKey(const Key('more-tab-wallet')), findsNothing);
    await tester.tapAt(const Offset(2, 2));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // Switched off while the app runs: the rail follows at once.
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    await tester.runAsync(
      () => container
          .read(featureFlagsProvider.notifier)
          .setEnabled(ZenFeature.dating, false),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('side-tab-more')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('more-tab-dating')), findsNothing);
    await tester.tapAt(const Offset(2, 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('chats-page')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(_settle);
  });

  testWidgets('"Funkcje eksperymentalne" switches a feature', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [ledgerDiskProvider.overrideWithValue(disk)],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const ExperimentalFeaturesScreen(),
        ),
      ),
    );
    await tester.runAsync(_settle);
    await tester.pump();

    // Neighbours are core: no switch.
    expect(find.byKey(const Key('feature-flag-neighbors')), findsNothing);
    final Finder pyramid = find.byKey(const Key('feature-flag-pyramid'));
    expect(tester.widget<SwitchListTile>(pyramid).value, isTrue);
    await tester.tap(pyramid);
    await tester.runAsync(_settle);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(pyramid).value, isFalse);
    expect(disk.files[kFeatureFlagsKey], isNotNull);
  });
}
