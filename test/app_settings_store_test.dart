import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

void main() {
  late Directory tempDir;
  late FileBinaryStore files;
  late FileAppSettingsStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zen-app-settings-');
    files = FileBinaryStore(
      tempDir,
      codec: BinaryCodec(compressor: const _PassThroughCompressor()),
    );
    store = FileAppSettingsStore(store: files);
  });

  tearDown(() => tempDir.delete(recursive: true));

  test('settings survive a round-trip', () async {
    await store.save(
      const AppSettings(
        inboxLimitMb: 80,
        autoCleanupDays: 14,
        lockMode: AppLockMode.appClose,
        backgroundLockDelaySeconds: 12,
        themeMode: AppThemeMode.dark,
        accentTheme: AppAccentTheme.aurora,
        palette: AppPalette.forest,
        gifApiKey: 'my-own_key.123',
        autoDownloadMedia: false,
        hideNotificationContent: false,
        secureScreens: false,
        allowNoAppPassword: true,
        bridgeEnabled: false,
      ),
    );

    final AppSettings restored = (await store.load())!;
    expect(restored.inboxLimitMb, 80);
    expect(restored.autoCleanupDays, 14);
    expect(restored.lockMode, AppLockMode.appClose);
    expect(restored.backgroundLockDelaySeconds, 12);
    expect(restored.themeMode, AppThemeMode.dark);
    expect(restored.accentTheme, AppAccentTheme.aurora);
    expect(restored.palette, AppPalette.forest);
    expect(restored.gifApiKey, 'my-own_key.123');
    expect(restored.autoDownloadMedia, isFalse);
    expect(restored.hideNotificationContent, isFalse);
    expect(restored.secureScreens, isFalse);
    expect(restored.allowNoAppPassword, isTrue);
    expect(restored.bridgeEnabled, isFalse);
  });

  test('nothing saved yet means the defaults', () async {
    expect(await store.load(), isNull);
    const AppSettings defaults = AppSettings();
    expect(defaults.themeMode, AppThemeMode.system);
    expect(defaults.lockMode, AppLockMode.background);
    expect(defaults.backgroundLockDelaySeconds, 300);
    expect(defaults.bridgeEnabled, isTrue, reason: 'a computer is a bridge');
    expect(defaults.autoDownloadMedia, isTrue);
  });

  test(
    'a missing field keeps its default, an unknown one is ignored',
    () async {
      await files.write(
        'settings/app',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object>{
              'themeMode': 'light',
              'somethingNew': 42,
              'lockMode': 'noSuchMode',
            }),
          ),
        ),
      );
      final AppSettings loaded = (await store.load())!;
      expect(loaded.themeMode, AppThemeMode.light);
      expect(loaded.lockMode, AppSettings.defaultLockMode);
      expect(loaded.bridgeEnabled, isTrue);
      expect(loaded.accentTheme, AppSettings.defaultAccentTheme);
      expect(loaded.palette, AppPalette.classic);
    },
  );

  test('a file it cannot read falls back to the defaults', () async {
    await files.write('settings/app', Uint8List.fromList(<int>[255, 10, 0, 7]));
    expect(await store.load(), isNull);
  });

  test('values out of range are clamped', () {
    final AppSettings s = AppSettings.fromJson(<String, dynamic>{
      'backgroundLockDelaySeconds': 0,
      'inboxLimitMb': 1,
    });
    expect(
      s.backgroundLockDelaySeconds,
      AppSettings.minimumBackgroundLockDelaySeconds,
    );
    expect(s.inboxLimitMb, AppSettings.minimumInboxLimitMb);
  });

  test('a GIF key that is not a key is not kept', () {
    expect(
      const AppSettings().copyWith(gifApiKey: ' https://evil?x=1 ').gifApiKey,
      isEmpty,
    );
    expect(
      const AppSettings().copyWith(gifApiKey: '  good_key-1.2  ').gifApiKey,
      'good_key-1.2',
    );
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
