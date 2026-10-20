import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/settings/app_settings.dart';

abstract interface class AppSettingsStore {
  Future<AppSettings?> load();

  Future<void> save(AppSettings settings);
}

/// The settings as named JSON fields (see [AppSettings.toJson]). The app is
/// not released yet, so there is no reader for older formats: a file it
/// cannot read simply falls back to the defaults.
final class FileAppSettingsStore implements AppSettingsStore {
  FileAppSettingsStore({required this.store, this.storageKey = 'settings/app'});

  final FileBinaryStore store;
  final String storageKey;

  @override
  Future<AppSettings?> load() async {
    final Uint8List? bytes = await store.read(storageKey);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    return json is Map<String, dynamic> ? AppSettings.fromJson(json) : null;
  }

  @override
  Future<void> save(AppSettings settings) async {
    await store.write(
      storageKey,
      Uint8List.fromList(
        utf8.encode(jsonEncode(withFormatVersion(settings.toJson()))),
      ),
    );
  }
}

final class MemoryAppSettingsStore implements AppSettingsStore {
  MemoryAppSettingsStore([this._settings]);

  AppSettings? _settings;

  @override
  Future<AppSettings?> load() async => _settings;

  @override
  Future<void> save(AppSettings settings) async {
    _settings = settings;
  }
}
