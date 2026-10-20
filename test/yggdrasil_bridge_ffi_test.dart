import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';

void main() {
  test('release builds load the Windows bridge only from next to the exe', () {
    expect(
      windowsBridgeLibraryCandidates(
        exeDirectory: r'C:\Program Files\Zen',
        currentDirectory: r'C:\Users\ada\Downloads',
        debugMode: false,
      ),
      <String>[r'C:\Program Files\Zen\yggdrasil_bridge.dll'],
    );
  });

  test('debug builds also try the checkout in the working directory', () {
    expect(
      windowsBridgeLibraryCandidates(
        exeDirectory: r'C:\src\zen\build\windows\x64\runner\Debug',
        currentDirectory: r'C:\src\zen',
        debugMode: true,
      ),
      <String>[
        r'C:\src\zen\build\windows\x64\runner\Debug\yggdrasil_bridge.dll',
        r'C:\src\zen\native\yggdrasil_bridge\bin\yggdrasil_bridge.dll',
        r'C:\src\zen\yggdrasil_bridge.dll',
      ],
    );
  });

  test('debug builds on Windows on ARM try the arm64 bridge of the checkout', () {
    expect(
      windowsBridgeLibraryCandidates(
        exeDirectory: r'C:\src\zen\build\windows\arm64\runner\Debug',
        currentDirectory: r'C:\src\zen',
        debugMode: true,
        arm64: true,
      ),
      <String>[
        r'C:\src\zen\build\windows\arm64\runner\Debug\yggdrasil_bridge.dll',
        r'C:\src\zen\native\yggdrasil_bridge\bin\windows-arm64\yggdrasil_bridge.dll',
        r'C:\src\zen\yggdrasil_bridge.dll',
      ],
    );
  });

  test(
    'release builds on Windows on ARM also load only from next to the exe',
    () {
      expect(
        windowsBridgeLibraryCandidates(
          exeDirectory: r'C:\Program Files\Zen',
          currentDirectory: r'C:\Users\ada',
          debugMode: false,
          arm64: true,
        ),
        <String>[r'C:\Program Files\Zen\yggdrasil_bridge.dll'],
      );
    },
  );

  test('the Android load error names every bundled ABI', () {
    final String message = androidBridgeLoadError('dlopen failed');
    expect(message, contains('arm64-v8a'));
    expect(message, contains('armeabi-v7a'));
    expect(message, contains('x86_64'));
    expect(message, contains('dlopen failed'));
  });
}
