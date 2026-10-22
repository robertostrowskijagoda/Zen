// Runs on a real Windows build (the app's own runner, with its recorder):
//   flutter test integration_test/call_recorder_test.dart -d windows
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zen/src/features/calls/call_recorder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows records only the app sound and the microphone into a WAV',
    (WidgetTester tester) async {
      if (!Platform.isWindows) {
        return;
      }
      final String path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}zen_rec_it.wav';
      final RunnerCallRecorder recorder = RunnerCallRecorder.wav();
      await tester.runAsync(() async {
        await recorder.start(path);
        await Future<void>.delayed(const Duration(seconds: 2));
        await recorder.stop();
      });
      final File file = File(path);
      expect(file.existsSync(), isTrue);
      final Uint8List bytes = file.readAsBytesSync();
      file.deleteSync();
      final ByteData header = ByteData.sublistView(bytes, 0, 44);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(header.getUint16(22, Endian.little), 2); // stereo
      expect(header.getUint32(24, Endian.little), 48000);
      expect(header.getUint16(34, Endian.little), 16);
      final int data = header.getUint32(40, Endian.little);
      expect(data, bytes.length - 44);
      // About two seconds of 48 kHz stereo 16-bit (192 000 bytes a second).
      expect(data, greaterThan(300000));
      expect(data, lessThan(600000));
    },
  );
}
