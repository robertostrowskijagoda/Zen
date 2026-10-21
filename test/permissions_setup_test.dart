import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// The system side: every step starts missing; a request grants it,
/// except the camera (the person says no).
final class _Platform implements PermissionsPlatform {
  _Platform({this.anything = true});

  final bool anything;
  final Map<ZenPermission, bool> granted = <ZenPermission, bool>{
    for (final ZenPermission p in ZenPermission.values) p: false,
  };
  final List<ZenPermission> asked = <ZenPermission>[];
  final List<ZenPermission> opened = <ZenPermission>[];
  final StreamController<bool> bluetooth = StreamController<bool>.broadcast();

  @override
  bool get hasAnything => anything;

  @override
  bool get hasBluetooth => anything;

  @override
  Future<PermissionsSnapshot> check() async => PermissionsSnapshot(
    applicable: anything ? ZenPermission.values.toList() : <ZenPermission>[],
    granted: Map<ZenPermission, bool>.of(granted),
  );

  @override
  Future<void> request(ZenPermission permission) async {
    asked.add(permission);
    if (permission != ZenPermission.camera) {
      granted[permission] = true;
    }
  }

  @override
  Future<void> openSettings(ZenPermission permission) async =>
      opened.add(permission);

  @override
  Stream<bool> get bluetoothChanges => bluetooth.stream;
}

final class _Radio implements NearbyRadio {
  Uint8List? advertised;

  @override
  Stream<Map<Object?, Object?>> get events =>
      const Stream<Map<Object?, Object?>>.empty();

  @override
  Future<Map<Object?, Object?>> state() async => <Object?, Object?>{
    'supported': true,
    'enabled': true,
    'permitted': true,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> requestEnable() async => true;

  @override
  Future<bool> startAdvertising(Uint8List token) async {
    advertised = token;
    return true;
  }

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async => true;

  @override
  Future<void> stopAdvertising() async => advertised = null;

  @override
  Future<bool> startScan({bool lowPower = false}) async => true;

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> wave(String device, Uint8List data) async => false;
}

final class _Host implements MeetHost {
  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => const <String>[];

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String address) => false;

  @override
  bool isSelf(String address) => false;

  @override
  String nameOf(String address) => address;

  @override
  Future<void> notify(RuntimeSystemNotification notification) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

/// The meeting service and the radio behind "Widoczny(-a) w pobliżu".
final class _Nearby {
  _Nearby() {
    meet = MeetService(host: _Host(), store: MeetStore(MemoryLedgerDisk()));
    nearby = NearbyService(
      radio: radio,
      meet: meet,
      ownAddress: () => '',
      sendMesh: (String to, Map<String, dynamic> payload) async {},
      frames: const Stream<SignalTransportFrame>.empty(),
    );
  }

  final _Radio radio = _Radio();
  late final MeetService meet;
  late final NearbyService nearby;

  List get overrides => [
    meetServiceProvider.overrideWithValue(meet),
    nearbyServiceProvider.overrideWithValue(nearby),
  ];
}

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 7000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Widget _gatedApp({required List overrides}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: ZenTheme.dark(),
    // Same place as in the app: above the root Navigator.
    builder: (BuildContext context, Widget? child) =>
        AppSecurityGate(child: child!),
    home: const Scaffold(body: Text('aplikacja')),
  ),
);

FilledButton _button(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(Key(key)));

void main() {
  testWidgets('first start: after the password, the permissions step asks '
      'one thing at a time, turns visibility on and never comes back', (
    WidgetTester tester,
  ) async {
    _tallScreen(tester);
    final _Platform platform = _Platform();
    final _Nearby near = _Nearby();
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    await tester.pumpWidget(
      _gatedApp(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(store),
          permissionsSetupRequiredProvider.overrideWithValue(true),
          permissionsPlatformProvider.overrideWithValue(platform),
          ...near.overrides,
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('permissions-setup')), findsOneWidget);
    expect(find.text('aplikacja'), findsNothing);

    // Bluetooth can be switched on only once it may be used.
    expect(_button(tester, 'permissions-step-bluetooth-on').onPressed, isNull);
    await tester.tap(find.byKey(const Key('permissions-step-notifications')));
    await tester.pumpAndSettle();
    expect(platform.asked, <ZenPermission>[ZenPermission.notifications]);
    expect(
      find.byKey(const Key('permissions-step-notifications')),
      findsNothing,
      reason: 'done: no button any more',
    );
    await tester.tap(find.byKey(const Key('permissions-step-bluetooth')));
    await tester.pumpAndSettle();
    expect(
      _button(tester, 'permissions-step-bluetooth-on').onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('permissions-step-bluetooth-on')));
    await tester.pumpAndSettle();
    expect(platform.asked.last, ZenPermission.bluetoothOn);

    // The camera: a "no"; the next tap opens the system settings.
    await tester.tap(find.byKey(const Key('permissions-step-camera')));
    await tester.pumpAndSettle();
    expect(find.text('Ustawienia'), findsOneWidget);
    await tester.tap(find.byKey(const Key('permissions-step-camera')));
    await tester.pumpAndSettle();
    expect(platform.opened, <ZenPermission>[ZenPermission.camera]);

    // Visible nearby: off until the person turns it on.
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('permissions-nearby-visible')),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('permissions-nearby-visible')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('permissions-setup-done')));
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('permissions-setup')), findsNothing);
    expect(near.meet.book.nearbyVisible, isTrue);
    expect(near.radio.advertised, isNotNull, reason: 'shown nearby now');
    final AppSettings saved = (await store.load())!;
    expect(saved.permissionsSetupDone, isTrue);

    // The next start goes straight to the app.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _gatedApp(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(store),
          appSettingsInitialStateProvider.overrideWithValue(saved),
          appSettingsHydrationEnabledProvider.overrideWithValue(false),
          permissionsSetupRequiredProvider.overrideWithValue(true),
          permissionsPlatformProvider.overrideWithValue(platform),
          ...near.overrides,
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('permissions-setup')), findsNothing);
    // Closing waits on stream cancels outside the fake clock.
    await tester.runAsync(near.nearby.close);
  });

  testWidgets('not turning visibility on keeps the phone hidden', (
    WidgetTester tester,
  ) async {
    _tallScreen(tester);
    final _Nearby near = _Nearby();
    await tester.pumpWidget(
      _gatedApp(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(MemoryAppSettingsStore()),
          permissionsSetupRequiredProvider.overrideWithValue(true),
          permissionsPlatformProvider.overrideWithValue(_Platform()),
          ...near.overrides,
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('permissions-setup-done')));
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(near.meet.book.nearbyVisible, isFalse);
    expect(near.radio.advertised, isNull);
    // Closing waits on stream cancels outside the fake clock.
    await tester.runAsync(near.nearby.close);
  });

  testWidgets('nothing to ask on this device, or not required (tests, '
      'scripts): straight to the app', (WidgetTester tester) async {
    await tester.pumpWidget(
      _gatedApp(
        overrides: [
          permissionsSetupRequiredProvider.overrideWithValue(true),
          permissionsPlatformProvider.overrideWithValue(
            _Platform(anything: false),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _gatedApp(
        overrides: [permissionsPlatformProvider.overrideWithValue(_Platform())],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
  });

  testWidgets('the same screen opens from the settings', (
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
          // The same answer on every test host (Windows has things to ask).
          permissionsPlatformProvider.overrideWithValue(
            _Platform(anything: false),
          ),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const AppShellScreen(),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    // Not pumpAndSettle: the status bar keeps pulsing.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-nav-permissions')),
      220,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('settings-tab-body')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-nav-permissions')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('permissions-screen')), findsOneWidget);
    // Nothing to ask in a test run; and no first-start button here.
    expect(find.text('Nic do ustawienia'), findsOneWidget);
    expect(find.byKey(const Key('permissions-setup-done')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });

  test('the first-start step is remembered in the settings', () {
    expect(const AppSettings().permissionsSetupDone, isFalse);
    final AppSettings done = const AppSettings().copyWith(
      permissionsSetupDone: true,
    );
    expect(done.toJson()['permissionsSetupDone'], isTrue);
    expect(AppSettings.fromJson(done.toJson()).permissionsSetupDone, isTrue);
    expect(
      AppSettings.fromJson(<String, dynamic>{}).permissionsSetupDone,
      isFalse,
    );
  });

  test('a snapshot knows when Bluetooth is ready', () {
    expect(const PermissionsSnapshot().bluetoothReady, isFalse);
    expect(
      const PermissionsSnapshot(
        granted: <ZenPermission, bool>{
          ZenPermission.bluetooth: true,
          ZenPermission.bluetoothOn: true,
        },
      ).bluetoothReady,
      isTrue,
    );
    expect(ZenPermission.camera.optional, isTrue);
    expect(ZenPermission.bluetooth.optional, isFalse);
    expect(MeetBook().nearbyVisible, isFalse, reason: 'hidden by default');
  });
}
