import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

void main() {
  group('format version helper', () {
    test('adds v without touching the fields; a document v wins', () {
      expect(withFormatVersion(<String, Object?>{'a': 1}), <String, Object?>{
        'v': 1,
        'a': 1,
      });
      expect(withFormatVersion(<String, Object?>{'v': 3})['v'], 3);
    });
  });

  group('stores write v: 1', () {
    late Directory dir;
    late FileBinaryStore files;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zen-format-v-');
      files = FileBinaryStore(
        dir,
        codec: BinaryCodec(compressor: const _PassThroughCompressor()),
      );
    });

    tearDown(() => dir.delete(recursive: true));

    Future<Map<String, dynamic>> stored(String key) async =>
        jsonDecode(utf8.decode((await files.read(key))!))
            as Map<String, dynamic>;

    test('settings', () async {
      final FileAppSettingsStore store = FileAppSettingsStore(store: files);
      await store.save(const AppSettings(themeMode: AppThemeMode.dark));
      final Map<String, dynamic> json = await stored('settings/app');
      expect(json['v'], 1);
      expect(json['themeMode'], 'dark');
    });

    test('profile', () async {
      final FileUserProfileStore store = FileUserProfileStore(store: files);
      await store.save(const UserProfile(displayName: 'Ada'));
      final Map<String, dynamic> json = await stored('user_profile');
      expect(json['v'], 1);
      expect((await store.load())!.displayName, 'Ada');
    });
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
