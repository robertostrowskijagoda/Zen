import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/permissions/presentation/permissions_screen.dart';
import 'package:zen/src/features/permissions/presentation/vendor_battery_help.dart';

/// An Android-like phone without Bluetooth (so no meeting service is
/// needed): location, exact alarms and battery are the steps under test.
final class _Platform implements PermissionsPlatform {
  _Platform({this.manufacturer = ''});

  final String manufacturer;
  final Map<ZenPermission, bool> granted = <ZenPermission, bool>{
    ZenPermission.notifications: true,
    ZenPermission.location: false,
    ZenPermission.backgroundLocation: false,
    ZenPermission.exactAlarms: false,
    ZenPermission.battery: false,
  };
  final List<ZenPermission> asked = <ZenPermission>[];

  @override
  bool get hasAnything => true;

  @override
  bool get hasBluetooth => false;

  @override
  Future<PermissionsSnapshot> check() async => PermissionsSnapshot(
    applicable: granted.keys.toList(),
    granted: Map<ZenPermission, bool>.of(granted),
    manufacturer: manufacturer,
  );

  @override
  Future<void> request(ZenPermission permission) async {
    asked.add(permission);
    granted[permission] = true;
  }

  @override
  Future<void> openSettings(ZenPermission permission) async {}

  @override
  Stream<bool> get bluetoothChanges => const Stream<bool>.empty();
}

Future<void> _open(
  WidgetTester tester,
  _Platform platform, {
  double textScale = 1,
  Widget home = const PermissionsScreen(),
}) async {
  tester.view.physicalSize = const Size(360, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        permissionsPlatformProvider.overrideWithValue(platform),
      ],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('location (also in the background) and exact alarms are listed '
      'with the reason', (WidgetTester tester) async {
    final _Platform platform = _Platform();
    await _open(tester, platform);
    for (final String id in <String>[
      'location', 'background-location', 'exact-alarms', 'battery', //
    ]) {
      expect(
        find.byKey(Key('permissions-row-$id')),
        findsOneWidget,
        reason: id,
      );
    }
    // Why: the alarm and the neighbours.
    expect(
      find.textContaining('Alarm wysyła znajomym miejsce'),
      findsOneWidget,
    );
    expect(find.text('Położenie także w tle'), findsOneWidget);
    expect(find.text('Dokładne alarmy'), findsOneWidget);
    // "All the time" waits for the first step.
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('permissions-step-background-location')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Najpierw zezwól na położenie.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('permissions-step-location')));
    await tester.pump();
    await tester.pump();
    expect(platform.asked, <ZenPermission>[ZenPermission.location]);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('permissions-step-background-location')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('permissions-step-exact-alarms')));
    await tester.pump();
    await tester.pump();
    expect(platform.asked.last, ZenPermission.exactAlarms);
    // Optional: a missing one does not block the first-start button.
    expect(ZenPermission.location.optional, isTrue);
    expect(ZenPermission.exactAlarms.optional, isTrue);
    expect(ZenPermission.notifications.optional, isFalse);
    // Let the follow-up refresh timer run out.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('battery instructions for the maker of this phone', (
    WidgetTester tester,
  ) async {
    await _open(tester, _Platform(manufacturer: 'samsung'));
    expect(find.byKey(const Key('vendor-battery-help')), findsOneWidget);
    expect(find.textContaining('Twój telefon (Samsung)'), findsOneWidget);
    expect(find.textContaining('Limity użycia w tle'), findsOneWidget);
    // The others fold away.
    await tester.ensureVisible(find.byKey(const Key('vendor-battery-others')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('vendor-battery-others')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Autostart'), findsWidgets);
    expect(
      find.byKey(const Key('vendor-battery-open-settings')),
      findsOneWidget,
    );
  });

  testWidgets('an unknown maker gets the general instructions', (
    WidgetTester tester,
  ) async {
    await _open(tester, _Platform());
    expect(
      find.textContaining('Telefony mają też własne „zabójce baterii”'),
      findsOneWidget,
    );
  });

  testWidgets('the first start shows a short welcome above the steps', (
    WidgetTester tester,
  ) async {
    await _open(tester, _Platform(), home: const PermissionsSetupStage());
    expect(find.byKey(const Key('permissions-welcome')), findsOneWidget);
    expect(find.text('Witaj w Zen'), findsOneWidget);
    // And not in the settings.
    await tester.pumpWidget(const SizedBox.shrink());
    await _open(tester, _Platform());
    expect(find.byKey(const Key('permissions-welcome')), findsNothing);
  });

  testWidgets('nothing is clipped at 1.3x text on a small phone', (
    WidgetTester tester,
  ) async {
    await _open(tester, _Platform(manufacturer: 'xiaomi'), textScale: 1.3);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  test('vendors are told apart by the manufacturer name', () {
    expect(PhoneVendor.fromManufacturer('Xiaomi'), PhoneVendor.xiaomi);
    expect(PhoneVendor.fromManufacturer('POCO'), PhoneVendor.xiaomi);
    expect(PhoneVendor.fromManufacturer('samsung'), PhoneVendor.samsung);
    expect(PhoneVendor.fromManufacturer('HUAWEI'), PhoneVendor.huawei);
    expect(PhoneVendor.fromManufacturer('OnePlus'), PhoneVendor.oneplus);
    expect(PhoneVendor.fromManufacturer('realme'), PhoneVendor.oppo);
    expect(PhoneVendor.fromManufacturer('Google'), PhoneVendor.other);
    expect(PhoneVendor.fromManufacturer(''), PhoneVendor.other);
  });
}
