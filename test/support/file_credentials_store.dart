import 'dart:convert';
import 'dart:io';

import 'package:zen/src/features/security/app_security_service.dart';

/// The system's secret store of one test device, as a file next to its data
/// folder: it survives the device's restarts like the real one does (the
/// master key, the background key, the guarded settings).
final class FileCredentialsStore implements AppSecurityCredentialsStore {
  FileCredentialsStore(this.file);

  final File file;

  Map<String, String> _read() {
    if (!file.existsSync()) {
      return <String, String>{};
    }
    return (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>).map(
      (String k, dynamic v) => MapEntry<String, String>(k, '$v'),
    );
  }

  @override
  Future<String?> read(String key) async => _read()[key];

  @override
  Future<void> write(String key, String value) async {
    final Map<String, String> values = _read()..[key] = value;
    file.writeAsStringSync(jsonEncode(values), flush: true);
  }

  @override
  Future<void> delete(String key) async {
    final Map<String, String> values = _read()..remove(key);
    file.writeAsStringSync(jsonEncode(values), flush: true);
  }
}
