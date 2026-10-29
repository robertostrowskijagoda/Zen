// Owner report R5-#22 (28.10.2026, after 1.14.0): 1.14.0 sometimes did not start until its data was wiped.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in app_settings_store.dart (an unreadable settings file is set
// aside, f5b9d873); guarded by the tests below, test/start_upgrade_test.dart
// ("a damaged file never stops the start") and test/persistence_fuzz_test.dart.
// The bridge deadlock found with it is R5-F4 (r5_found_by_tests_test.dart).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

import '../support/damaged_files.dart';
import '../support/start_harness.dart';

/// How a settings file got damaged: a write killed halfway, a bad sector.
enum _Damage {
  emptied,
  cutShort,
  garbage;

  void apply(File file) {
    final Uint8List bytes = file.readAsBytesSync();
    switch (this) {
      case _Damage.emptied:
        file.writeAsBytesSync(const <int>[]);
      case _Damage.cutShort:
        file.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      case _Damage.garbage:
        final Random random = Random(bytes.length);
        file.writeAsBytesSync(<int>[
          for (int i = 0; i < bytes.length; i++) random.nextInt(256),
        ]);
    }
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-r5-22-');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open a moment longer.
    }
  });

  /// The settings store the start reads first, as the app builds it.
  AppSettingsStore settingsStore() => buildZenAppSettingsStoreForDirectory(
    root,
    codec: harnessCodec,
    secrets: null,
  );

  for (final _Damage damage in _Damage.values) {
    test('R5-#22: 1.14.0 starts without wiping its data '
        '(settings file ${damage.name}, its backups too)', () async {
      // Saved twice: a backup is there as well.
      await settingsStore().save(const AppSettings(autoCleanupDays: 9));
      await settingsStore().save(const AppSettings(autoCleanupDays: 8));
      final List<File> files = <File>[
        for (final FileSystemEntity e in root.listSync(recursive: true))
          if (e is File) e,
      ];
      expect(files, isNotEmpty);
      for (final File file in files) {
        damage.apply(file);
      }

      // Before: the first step of every start threw here (the store's read
      // or the JSON), so the app stayed on the logo until its data was
      // wiped.
      final AppSettings? loaded = await settingsStore().load();

      expect(loaded, isNull, reason: 'the defaults for this start');
      expect(setAsideUnder(root), isNotEmpty, reason: 'kept for a look');
      // The next save and start are normal ones.
      await settingsStore().save(const AppSettings(autoCleanupDays: 3));
      expect((await settingsStore().load())?.autoCleanupDays, 3);
    });
  }

  test('R5-#22: a damaged settings file under the protected copy starts '
      'with what secure storage kept', () async {
    final MemorySecurityCredentialsStore secrets =
        MemorySecurityCredentialsStore();
    AppSettingsStore guarded() => buildZenAppSettingsStoreForDirectory(
      root,
      codec: harnessCodec,
      secrets: secrets,
    );
    await guarded().save(
      const AppSettings(
        lockMode: AppLockMode.background,
        notificationPrivacy: NotificationPrivacy.generic,
      ),
    );
    for (final FileSystemEntity e in root.listSync(recursive: true)) {
      if (e is File) {
        _Damage.cutShort.apply(e);
      }
    }

    final AppSettings? loaded = await guarded().load();

    expect(loaded?.lockMode, AppLockMode.background);
    expect(loaded?.notificationPrivacy, NotificationPrivacy.generic);
  });
}
