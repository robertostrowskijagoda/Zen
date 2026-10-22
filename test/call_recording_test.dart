import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/calls/call_recorder.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/media/media_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a finished recording is kept encrypted and the plain file goes',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync('zen-rec-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File file = File('${dir.path}/r.wav')
        ..writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4]));
      final Uint8List key = Uint8List.fromList(List<int>.filled(32, 7));
      final CallRecordingStore store = CallRecordingStore(
        MemoryLedgerDisk(),
        MediaVault(
          masterKey: () async => key,
          supportDirectory: () async => dir,
          temporaryDirectory: () async => dir,
        ),
      );

      final CallRecording? rec = await keepCallRecording(
        store,
        path: file.path,
        mime: 'audio/wav',
        label: 'Rodzina',
        millis: 42,
      );

      expect(rec, isNotNull);
      expect(file.existsSync(), isFalse);
      final List<CallRecording> all = await store.list();
      expect(all.single.peer, 'Rodzina');
      expect(all.single.isAudioOnly, isTrue);
      expect(all.single.extension, 'wav');
      final File copy = await store.openTemporary(all.single);
      expect(copy.readAsBytesSync(), <int>[1, 2, 3, 4]);

      // Nothing recorded: nothing kept.
      expect(
        await keepCallRecording(
          store,
          path: '${dir.path}/missing.wav',
          mime: 'audio/wav',
          label: 'x',
        ),
        isNull,
      );
    },
  );

  test('a recording without a type is video; one without a file is none', () {
    final CallRecording? old = CallRecording.fromJson(<String, dynamic>{
      'id': 'rec-1',
      'peer': 'Ania',
      'at': 1,
      'bytes': 10,
      'file': '${'a' * 32}.zmedia',
    });
    expect(
      CallRecording.fromJson(<String, dynamic>{
        'id': 'rec-1',
        'peer': 'Ania',
        'at': 1,
        'bytes': 10,
      }),
      isNull,
    );
    expect(old!.mime, 'video/mp4');
    expect(old.extension, 'mp4');
    expect(old.isAudioOnly, isFalse);
    final CallRecording back = CallRecording.fromJson(
      const CallRecording(
        id: 'rec-2',
        peer: 'Kuba',
        millis: 2,
        bytes: 3,
        file: 'b.zmedia',
        mime: 'audio/wav',
      ).toJson(),
    )!;
    expect(back.mime, 'audio/wav');
  });

  test('AAC recordings (iPhone, Mac) are sound and export as m4a', () {
    final CallRecording rec = CallRecording.fromJson(
      const CallRecording(
        id: 'rec-3',
        peer: 'Ola',
        millis: 3,
        bytes: 4,
        file: 'c.zmedia',
        mime: 'audio/mp4',
      ).toJson(),
    )!;
    expect(rec.mime, 'audio/mp4');
    expect(rec.isAudioOnly, isTrue);
    expect(rec.extension, 'm4a');
  });

  test('every platform gets its own recorder and file type', () {
    expect(callRecorderForPlatform('android'), isA<AndroidCallRecorder>());
    for (final String os in <String>['ios', 'macos']) {
      final CallRecorder recorder = callRecorderForPlatform(os);
      expect(recorder, isA<RunnerCallRecorder>(), reason: os);
      expect(recorder.extension, 'm4a', reason: os);
      expect(recorder.mime, 'audio/mp4', reason: os);
    }
    for (final String os in <String>['windows', 'linux']) {
      final CallRecorder recorder = callRecorderForPlatform(os);
      expect(recorder, isA<RunnerCallRecorder>(), reason: os);
      expect(recorder.extension, 'wav', reason: os);
      expect(recorder.mime, 'audio/wav', reason: os);
    }
    final CallRecorder none = callRecorderForPlatform('fuchsia');
    expect(none, isA<UnavailableCallRecorder>());
    expect(none.available, isFalse);
  });

  test('the runner recorder talks to the runner', () async {
    const MethodChannel channel = MethodChannel('zen/recorder-test');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return call.method == 'stop' ? '/tmp/x.m4a' : true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final RunnerCallRecorder recorder =
        callRecorderForPlatform('ios', channel: channel) as RunnerCallRecorder;
    expect(await recorder.checkAvailable(), isTrue);
    expect(recorder.available, isTrue);
    await recorder.start('/tmp/x.m4a');
    expect(recorder.isRecording, isTrue);
    // A second start while recording does nothing.
    await recorder.start('/tmp/y.m4a');
    await recorder.stop();
    expect(recorder.isRecording, isFalse);
    // Stopping twice asks the runner once.
    await recorder.stop();
    expect(calls.map((MethodCall c) => c.method), <String>[
      'available',
      'start',
      'stop',
    ]);
    expect(calls[1].arguments, <String, Object>{'path': '/tmp/x.m4a'});
  });

  test('the runner is asked once whether it can record', () async {
    const MethodChannel channel = MethodChannel('zen/recorder-probe');
    int asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          asked++;
          return false;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final RunnerCallRecorder recorder = RunnerCallRecorder.wav(
      channel: channel,
    );
    // Offered until the runner answers, then honest.
    expect(recorder.available, isTrue);
    expect(await recorder.checkAvailable(), isFalse);
    expect(recorder.available, isFalse);
    expect(await recorder.checkAvailable(), isFalse);
    expect(asked, 1);
  });

  test('a device without a way to record says so when starting', () async {
    const MethodChannel channel = MethodChannel('zen/recorder-none');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'start') {
            throw PlatformException(
              code: 'unavailable',
              message: 'libpulse is missing',
            );
          }
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final RunnerCallRecorder recorder = RunnerCallRecorder.wav(
      channel: channel,
    );
    await expectLater(recorder.start('/tmp/x.wav'), throwsUnsupportedError);
    expect(recorder.isRecording, isFalse);
    expect(recorder.available, isFalse);
  });

  test('a recording that cannot start gives the reason', () async {
    const MethodChannel channel = MethodChannel('zen/recorder-fail');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          throw PlatformException(code: 'start_failed', message: 'no sound');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final RunnerCallRecorder recorder = RunnerCallRecorder.aac(
      channel: channel,
    );
    await expectLater(recorder.start('/tmp/x.m4a'), throwsStateError);
    expect(recorder.isRecording, isFalse);
  });

  test('a runner without the recorder says so plainly', () async {
    final RunnerCallRecorder recorder = RunnerCallRecorder.wav(
      channel: const MethodChannel('zen/recorder-missing'),
    );
    expect(await recorder.checkAvailable(), isFalse);
    await expectLater(recorder.start('C:/x.wav'), throwsUnsupportedError);
    expect(recorder.isRecording, isFalse);
  });
}
