import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/windows_system_paths.dart';

void main() {
  test('system tools are run by their full path under SystemRoot', () {
    const Map<String, String> env = <String, String>{'SystemRoot': r'D:\WINNT'};
    expect(windowsSystemRoot(env), r'D:\WINNT');
    expect(windowsRoutePath(env), r'D:\WINNT\System32\route.exe');
    expect(windowsExplorerPath(env), r'D:\WINNT\explorer.exe');
  });

  test('the usual spelling of the variable and a trailing slash work', () {
    expect(
      windowsExplorerPath(const <String, String>{'SYSTEMROOT': r'C:\Windows\'}),
      r'C:\Windows\explorer.exe',
    );
    expect(
      windowsRoutePath(const <String, String>{'SystemRoot': r'E:\'}),
      r'E:\System32\route.exe',
    );
  });

  test('a missing or unusable SystemRoot falls back to C:\\Windows', () {
    for (final Map<String, String> env in <Map<String, String>>[
      const <String, String>{},
      const <String, String>{'SystemRoot': ''},
      const <String, String>{'SystemRoot': 'Windows'},
      const <String, String>{'SystemRoot': r'..\Windows'},
      const <String, String>{'SystemRoot': r'\\server\share\Windows'},
      const <String, String>{'SystemRoot': r'C:\Win"dows'},
    ]) {
      expect(windowsSystemRoot(env), r'C:\Windows', reason: '$env');
      expect(windowsRoutePath(env), r'C:\Windows\System32\route.exe');
      expect(windowsExplorerPath(env), r'C:\Windows\explorer.exe');
    }
  });
}
