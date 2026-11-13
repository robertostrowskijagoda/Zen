import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

import 'support/text_fit.dart';

// Device names are kept and sent as Zen gives them (other devices and
// older versions read them), and shown in the app's language.

/// The English texts, with the device names as the translation gives them.
Map<String, Object?> _english() => <String, Object?>{
  ...textFitStrings('en'),
  'Przeglądarka': 'Browser',
  'Telefon (Android)': 'Phone (Android)',
  'Komputer (Windows)': 'Computer (Windows)',
  'Komputer (macOS)': 'Computer (macOS)',
  'Komputer (Linux)': 'Computer (Linux)',
  'Urządzenie': 'Device',
};

void main() {
  tearDown(ZenI18n.debugReset);

  test('names Zen gives are translated, any other is shown as it is', () {
    ZenI18n.debugUse('en', _english());
    expect(deviceNameLabel('Telefon (Android)'), 'Phone (Android)');
    expect(deviceNameLabel('Komputer (Linux)'), 'Computer (Linux)');
    expect(deviceNameLabel('iPhone'), 'iPhone');
    expect(deviceNameLabel('Laptop Ali'), 'Laptop Ali');
    ZenI18n.debugReset();
    expect(deviceNameLabel(thisDeviceName), thisDeviceName);
  });

  testWidgets('the devices screen shows this device in English, the stored '
      'name stays as it was', (WidgetTester tester) async {
    ZenI18n.debugUse('en', _english());
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        socialHubAutoHydrateProvider.overrideWithValue(false),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ledgerNodeEnabledProvider.overrideWithValue(true),
        ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ZenTheme.light(),
          home: const AccountDevicesScreen(),
        ),
      ),
    );
    final LedgerNode node = container.read(ledgerNodeProvider)!;
    // The tile of a device: `device-<its id>`.
    final Finder tile = find.byWidgetPredicate((Widget w) {
      final Key? key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('device-') &&
          key.value != 'device-unlink-confirm';
    });
    for (int i = 0; i < 200 && tile.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(node.ownDevices.single.name, thisDeviceName);
    final String shown = deviceNameLabel(thisDeviceName);
    expect(shown, isNot(contains('Komputer')));
    expect(shown, isNot(contains('Telefon')));
    expect(
      find.descendant(of: tile, matching: find.text(shown)),
      findsOneWidget,
    );
    expect(
      find.text(thisDeviceName),
      shown == thisDeviceName ? findsOneWidget : findsNothing,
    );
    // The screen and the node go before the test ends (their timers too).
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
}
