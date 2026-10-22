import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/settings/app_settings.dart';

abstract interface class AppSettingsStore {
  Future<AppSettings?> load();

  Future<void> save(AppSettings settings);
}

/// The settings as named JSON fields (see [AppSettings.toJson]). A file it
/// cannot read falls back to the defaults; one a newer build wrote (`v`
/// above 1) is kept as it is. Fields a newer build added are written back
/// as they were read, so going back to an older build does not erase them.
final class FileAppSettingsStore implements AppSettingsStore {
  FileAppSettingsStore({required this.store, this.storageKey = 'settings/app'});

  final FileBinaryStore store;
  final String storageKey;

  /// Fields of the file this build does not know (a newer build's).
  Map<String, Object?> _carried = const <String, Object?>{};

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
    if (store.heldAsNewer(storageKey, json, current: kFirstFormatVersion) ||
        json is! Map<String, dynamic>) {
      return null;
    }
    final AppSettings settings = AppSettings.fromJson(json);
    _carried = unknownFields(json, settings.toJson());
    return settings;
  }

  @override
  Future<void> save(AppSettings settings) async {
    await store.write(
      storageKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            withCarriedFields(withFormatVersion(settings.toJson()), _carried),
          ),
        ),
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
