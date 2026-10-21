import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('FeatureFlags', () {
    test('pyramid, wallet and dating on; neighbours are core', () {
      const FeatureFlags flags = FeatureFlags();
      expect(flags.isEnabled(ZenFeature.pyramid), isTrue);
      expect(flags.isEnabled(ZenFeature.wallet), isTrue);
      expect(flags.isEnabled(ZenFeature.dating), isTrue);
      expect(flags.showsTab('pyramid'), isTrue);
      expect(flags.showsTab('dating'), isTrue);
      // Tabs of no feature always show; neighbours have no flag.
      expect(ZenFeature.ofTab('neighbors'), isNull);
      expect(flags.showsTab('neighbors'), isTrue);
      expect(flags.showsTab('chats'), isTrue);
      expect(flags.showsTab('films'), isTrue);
    });

    test('a feature left out hides its tab; equality by choices', () {
      final FeatureFlags flags = const FeatureFlags()
          .withFeature(ZenFeature.pyramid, false)
          .withFeature(ZenFeature.dating, false);
      expect(flags.showsTab('pyramid'), isFalse);
      expect(flags.showsTab('dating'), isFalse);
      expect(flags.showsTab('wallet'), isTrue);
      expect(
        flags,
        const FeatureFlags()
            .withFeature(ZenFeature.dating, false)
            .withFeature(ZenFeature.pyramid, false),
      );
    });

    test('nothing is stored: the controller gives the build defaults', () {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ProviderContainer container = ProviderContainer(
        overrides: [ledgerDiskProvider.overrideWithValue(disk)],
      );
      addTearDown(container.dispose);
      expect(container.read(featureFlagsProvider), const FeatureFlags());
      container
          .read(featureFlagsProvider.notifier)
          .setEnabled(ZenFeature.dating, false);
      expect(
        container.read(featureFlagsProvider).isEnabled(ZenFeature.dating),
        isFalse,
      );
      expect(disk.files, isEmpty);
    });

    test('settings no longer offer "Funkcje eksperymentalne"', () {
      expect(
        File(
          'lib/src/features/settings/presentation/'
          'experimental_features_screen.dart',
        ).existsSync(),
        isFalse,
      );
      final String views = File(
        'lib/src/features/shell/presentation/app_shell_screen_views.dart',
      ).readAsStringSync();
      expect(views.contains('Funkcje eksperymentalne'), isFalse);
    });
  });

  testWidgets('a feature left out leaves the rail', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
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
    expect(find.byKey(const Key('side-tab-dating')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-pyramid')), findsOneWidget);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    container
        .read(featureFlagsProvider.notifier)
        .setEnabled(ZenFeature.dating, false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('side-tab-dating')), findsNothing);
    expect(find.byKey(const Key('side-tab-pyramid')), findsOneWidget);
    expect(find.byKey(const Key('chats-page')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(_settle);
  });
}
