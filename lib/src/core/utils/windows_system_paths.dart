import 'dart:io';

/// `%SystemRoot%` (usually `C:\Windows`) from [environment] (by default the
/// process environment), without a trailing backslash. `C:\Windows` when the
/// variable is missing or not an absolute local path: a program of Windows
/// is run by its full path, never looked up on `PATH`, where a program of
/// the same name in a folder the person can write to could be found first.
String windowsSystemRoot([Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String root = (env['SystemRoot'] ?? env['SYSTEMROOT'] ?? '').trim();
  final bool usable = RegExp(r'^[A-Za-z]:\\[^"<>|?*]*$').hasMatch(root);
  String base = usable ? root : r'C:\Windows';
  while (base.endsWith(r'\')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

/// `%SystemRoot%\System32\route.exe`.
String windowsRoutePath([Map<String, String>? environment]) =>
    '${windowsSystemRoot(environment)}\\System32\\route.exe';

/// `%SystemRoot%\explorer.exe`.
String windowsExplorerPath([Map<String, String>? environment]) =>
    '${windowsSystemRoot(environment)}\\explorer.exe';
