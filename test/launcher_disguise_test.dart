import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/launcher_disguise.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('zen/system-test');

  void answer(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  ProviderContainer containerWith(LauncherDisguise disguise) {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appSettingsStoreProvider.overrideWithValue(MemoryAppSettingsStore()),
        launcherDisguiseProvider.overrideWithValue(disguise),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the channel gets setDisguise with the wanted state', () async {
    final List<MethodCall> calls = <MethodCall>[];
    answer((MethodCall call) async {
      calls.add(call);
      return true;
    });
    const LauncherDisguise disguise = LauncherDisguise(
      channel: channel,
      supported: true,
    );

    expect(await disguise.set(enabled: true), isTrue);
    expect(await disguise.set(enabled: false), isTrue);

    expect(calls.map((MethodCall c) => c.method), everyElement('setDisguise'));
    expect(calls.map((MethodCall c) => c.arguments), <Object>[
      <String, Object>{'enabled': true},
      <String, Object>{'enabled': false},
    ]);
  });

  test('unsupported platforms never call the channel', () async {
    final List<MethodCall> calls = <MethodCall>[];
    answer((MethodCall call) async {
      calls.add(call);
      return true;
    });

    const LauncherDisguise disguise = LauncherDisguise(
      channel: channel,
      supported: false,
    );

    expect(await disguise.set(enabled: true), isFalse);
    expect(calls, isEmpty);
  });

  test('a failing channel call reports false', () async {
    answer((MethodCall call) async => throw PlatformException(code: 'x'));

    const LauncherDisguise disguise = LauncherDisguise(
      channel: channel,
      supported: true,
    );

    expect(await disguise.set(enabled: true), isFalse);
  });

  test('the setting is saved only after the phone took the switch', () async {
    answer((MethodCall call) async => true);
    final ProviderContainer container = containerWith(
      const LauncherDisguise(channel: channel, supported: true),
    );
    final AppSettingsController controller = container.read(
      appSettingsControllerProvider.notifier,
    );

    expect(container.read(appSettingsControllerProvider).disguiseIcon, isFalse);
    expect(await controller.setDisguiseIcon(true), isTrue);
    expect(container.read(appSettingsControllerProvider).disguiseIcon, isTrue);
    expect(await controller.setDisguiseIcon(false), isTrue);
    expect(container.read(appSettingsControllerProvider).disguiseIcon, isFalse);
  });

  test('a refused switch leaves the setting unchanged', () async {
    answer((MethodCall call) async => false);
    final ProviderContainer container = containerWith(
      const LauncherDisguise(channel: channel, supported: true),
    );

    final bool ok = await container
        .read(appSettingsControllerProvider.notifier)
        .setDisguiseIcon(true);

    expect(ok, isFalse);
    expect(container.read(appSettingsControllerProvider).disguiseIcon, isFalse);
  });

  test('disguiseIcon survives the JSON round trip', () {
    const AppSettings on = AppSettings(disguiseIcon: true);

    expect(AppSettings.fromJson(on.toJson()).disguiseIcon, isTrue);
    expect(
      AppSettings.fromJson(const <String, dynamic>{}).disguiseIcon,
      isFalse,
    );
  });
}
