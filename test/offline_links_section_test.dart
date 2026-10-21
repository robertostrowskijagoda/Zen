import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/local_links_controller.dart';
import 'package:zen/src/features/runtime/presentation/offline_links_section.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

final class _NoTarget implements LocalLinksTarget {
  @override
  void setLocalLinks(String? settingsJson) {}

  @override
  LocalLinkNodeApi? get localLinks => null;
}

final class _FakeLink extends LocalLink {
  _FakeLink([this.transport = LocalLinkTransport.wifiDirect]);

  @override
  final LocalLinkTransport transport;
  int permissionRequests = 0;
  final ValueNotifier<LocalLinkState> _state = ValueNotifier<LocalLinkState>(
    LocalLinkState.off,
  );

  @override
  bool get isSupported => true;

  @override
  ValueListenable<LocalLinkState> get state => _state;

  @override
  Future<bool> requestPermissions() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> start(
    LocalLinkNodeApi? Function() node, {
    required bool foreground,
  }) async {}

  @override
  Future<void> stop() async {}
}

LocalLinksStatus _linked() => LocalLinksStatus.fromJson(<String, dynamic>{
  'lan': <String, Object>{'on': true, 'running': true},
  'links': <Map<String, Object>>[
    <String, Object>{
      'id': 'a',
      'transport': 'lan',
      'address': '200::1',
      'up': true,
    },
  ],
});

void main() {
  Future<MemoryAppSettingsStore> pumpSection(
    WidgetTester tester, {
    required _FakeLink wifiDirect,
    bool android = true,
    _FakeLink? bluetooth,
    bool apple = false,
  }) async {
    final MemoryAppSettingsStore store = MemoryAppSettingsStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...buildAppSettingsProviderOverrides(store: store),
          wifiDirectAvailableProvider.overrideWithValue(android),
          bluetoothLinksAvailableProvider.overrideWithValue(bluetooth != null),
          multipeerLinksAvailableProvider.overrideWithValue(apple),
          localLinksStatusReaderProvider.overrideWithValue(_linked),
          localLinksControllerProvider.overrideWithValue(
            LocalLinksController(
              target: _NoTarget(),
              loadPeers: () async => const <LocalLinkPeer>[],
              transports: <LocalLink>[wifiDirect, ?bluetooth],
              setMulticastLock: (bool held) async {},
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: OfflineLinksSection()),
          ),
        ),
      ),
    );
    await tester.pump();
    return store;
  }

  testWidgets('the section shows both switches and who is linked', (
    WidgetTester tester,
  ) async {
    final _FakeLink wifiDirect = _FakeLink();
    await pumpSection(tester, wifiDirect: wifiDirect);

    expect(find.text('Łączność bez internetu'), findsOneWidget);
    expect(find.text('Znajomi w tej samej sieci Wi-Fi'), findsOneWidget);
    expect(find.text('Wi-Fi Direct (Android)'), findsOneWidget);
    final SwitchListTile lan = tester.widget<SwitchListTile>(
      find.byKey(const Key('settings-lan-discovery-switch')),
    );
    expect(lan.value, isTrue, reason: 'on by default');
    final SwitchListTile direct = tester.widget<SwitchListTile>(
      find.byKey(const Key('settings-wifi-direct-switch')),
    );
    expect(direct.value, isFalse, reason: 'off by default');
    final Text status = tester.widget<Text>(
      find.byKey(const Key('offline-links-status')),
    );
    expect(status.data, contains('1'));
    expect(status.data, contains('Wi-Fi: 1'));
  });

  testWidgets('turning Wi-Fi Direct on asks for the permission', (
    WidgetTester tester,
  ) async {
    final _FakeLink wifiDirect = _FakeLink();
    final MemoryAppSettingsStore store = await pumpSection(
      tester,
      wifiDirect: wifiDirect,
    );

    await tester.tap(find.byKey(const Key('settings-wifi-direct-switch')));
    await tester.pump();
    await tester.pump();

    expect(wifiDirect.permissionRequests, 1);
    final AppSettings? saved = await store.load();
    expect(saved?.wifiDirect, isTrue);
  });

  testWidgets('without the LAN, Wi-Fi Direct cannot be turned on', (
    WidgetTester tester,
  ) async {
    final _FakeLink wifiDirect = _FakeLink();
    final MemoryAppSettingsStore store = await pumpSection(
      tester,
      wifiDirect: wifiDirect,
    );

    await tester.tap(find.byKey(const Key('settings-lan-discovery-switch')));
    await tester.pump();
    await tester.pump();

    expect((await store.load())?.lanDiscoveryOn, isFalse);
    final SwitchListTile direct = tester.widget<SwitchListTile>(
      find.byKey(const Key('settings-wifi-direct-switch')),
    );
    expect(direct.onChanged, isNull);
    expect(
      find.text('Najpierw włącz „Znajomi w tej samej sieci Wi-Fi”.'),
      findsOneWidget,
    );
  });

  testWidgets('without Wi-Fi Direct (Linux, Apple) there is no switch', (
    WidgetTester tester,
  ) async {
    await pumpSection(tester, wifiDirect: _FakeLink(), android: false);
    expect(find.byKey(const Key('settings-wifi-direct-switch')), findsNothing);
    expect(
      find.byKey(const Key('settings-lan-discovery-switch')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Windows offers Wi-Fi Direct between Windows computers and BLE links',
    (WidgetTester tester) async {
      final _FakeLink wifiDirect = _FakeLink();
      final MemoryAppSettingsStore store = await pumpSection(
        tester,
        wifiDirect: wifiDirect,
        bluetooth: _FakeLink(LocalLinkTransport.bluetooth),
      );
      expect(find.text('Wi-Fi Direct (Windows)'), findsOneWidget);
      expect(find.text('Wi-Fi Direct (Android)'), findsNothing);
      expect(
        find.textContaining('komputerami znajomych z Windows'),
        findsOneWidget,
      );
      expect(
        find.textContaining('z telefonami z Androidem i komputerami z Windows'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('settings-wifi-direct-switch')));
      await tester.pump();
      await tester.pump();
      expect(wifiDirect.permissionRequests, 1);
      expect((await store.load())?.wifiDirect, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Bluetooth is off by default and asks for the permission', (
    WidgetTester tester,
  ) async {
    final _FakeLink bluetooth = _FakeLink(LocalLinkTransport.bluetooth);
    final MemoryAppSettingsStore store = await pumpSection(
      tester,
      wifiDirect: _FakeLink(),
      bluetooth: bluetooth,
    );
    expect(find.text('Bluetooth'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-multipeer-links-switch')),
      findsNothing,
      reason: 'only on Apple devices',
    );
    final Finder toggle = find.byKey(
      const Key('settings-bluetooth-links-switch'),
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();

    expect(bluetooth.permissionRequests, 1);
    expect((await store.load())?.bluetoothLinks, isTrue);
    expect((await store.load())?.wifiDirect, isFalse);
  });

  testWidgets('Apple devices also offer Multipeer', (
    WidgetTester tester,
  ) async {
    final MemoryAppSettingsStore store = await pumpSection(
      tester,
      wifiDirect: _FakeLink(),
      android: false,
      apple: true,
    );
    final Finder toggle = find.byKey(
      const Key('settings-multipeer-links-switch'),
    );
    expect(find.text('Apple Wi-Fi/Bluetooth'), findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();
    expect((await store.load())?.multipeerLinks, isTrue);
  });
}
