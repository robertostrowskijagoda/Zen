import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/calls/call_recorder.dart';
import 'package:zen/src/features/calls/call_recordings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a finished recording is kept encrypted and the plain file goes',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync('zen-rec-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File file = File('${dir.path}/r.wav')
        ..writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4]));
      final MemoryLedgerDisk disk = MemoryLedgerDisk();

      final CallRecording? rec = await keepCallRecording(
        disk,
        path: file.path,
        mime: 'audio/wav',
        label: 'Rodzina',
        millis: 42,
      );

      expect(rec, isNotNull);
      expect(file.existsSync(), isFalse);
      final List<CallRecording> all = await CallRecordingStore(disk).list();
      expect(all.single.peer, 'Rodzina');
      expect(all.single.isAudioOnly, isTrue);
      expect(all.single.extension, 'wav');
      expect(await CallRecordingStore(disk).read(all.single.id), <int>[
        1,
        2,
        3,
        4,
      ]);

      // Nothing recorded: nothing kept.
      expect(
        await keepCallRecording(
          disk,
          path: '${dir.path}/missing.wav',
          mime: 'audio/wav',
          label: 'x',
        ),
        isNull,
      );
    },
  );

  test('recordings from before keep working as video', () {
    final CallRecording? old = CallRecording.fromJson(<String, dynamic>{
      'id': 'rec-1',
      'peer': 'Ania',
      'at': 1,
      'bytes': 10,
    });
    expect(old!.mime, 'video/mp4');
    expect(old.extension, 'mp4');
    expect(old.isAudioOnly, isFalse);
    final CallRecording back = CallRecording.fromJson(
      const CallRecording(
        id: 'rec-2',
        peer: 'Kuba',
        millis: 2,
        bytes: 3,
        mime: 'audio/wav',
      ).toJson(),
    )!;
    expect(back.mime, 'audio/wav');
  });

  test('the Windows recorder talks to the runner', () async {
    const MethodChannel channel = MethodChannel('zen/recorder-test');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return call.method == 'stop' ? 'C:/x.wav' : true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final WindowsCallRecorder recorder = WindowsCallRecorder(channel: channel);
    expect(recorder.extension, 'wav');
    expect(recorder.mime, 'audio/wav');
    await recorder.start('C:/x.wav');
    expect(recorder.isRecording, isTrue);
    await recorder.stop();
    expect(recorder.isRecording, isFalse);
    expect(calls.map((MethodCall c) => c.method), <String>['start', 'stop']);
    expect(calls.first.arguments, <String, Object>{'path': 'C:/x.wav'});
  });

  test('a runner without the recorder says so plainly', () async {
    final WindowsCallRecorder recorder = WindowsCallRecorder(
      channel: const MethodChannel('zen/recorder-missing'),
    );
    await expectLater(recorder.start('C:/x.wav'), throwsUnsupportedError);
    expect(recorder.isRecording, isFalse);
  });
}
