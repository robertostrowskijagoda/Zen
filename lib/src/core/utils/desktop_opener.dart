import 'dart:io';

/// True inside `flutter test` (it sets FLUTTER_TEST for the test process).
bool get runningUnderFlutterTest =>
    Platform.environment['FLUTTER_TEST'] == 'true';

/// Hands something to the computer's own opener: [executable] is
/// explorer.exe, `open` or `xdg-open`, [arguments] a link, a file or a
/// folder to show. Returns `false` when nothing was started.
///
/// Never inside `flutter test`: a widget test (the monkey above all) taps
/// links and "show in folder" buttons, and each opened a page or a window
/// on the developer's own computer.
Future<bool> runDesktopOpener(String executable, List<String> arguments) async {
  if (runningUnderFlutterTest) {
    return false;
  }
  await Process.run(executable, arguments);
  return true;
}
