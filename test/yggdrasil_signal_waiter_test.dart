import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/yggdrasil_signal_transport.dart';
import 'package:zen/src/features/runtime/yggdrasil_signal_waiter.dart';

void main() {
  test(
    'the worker isolate blocks in the bridge and hands signals over',
    () async {
      final IsolateSignalWaiter waiter = await IsolateSignalWaiter.spawn(
        nodeHandle: 7,
        openBridge: _openWorkerBridge,
      );

      final Map<String, dynamic> first = await waiter.wait(
        const Duration(seconds: 5),
      );
      expect(first['available'], isTrue);
      expect(first['from'], 'ada.ygg');
      // The fake echoes the handle and timeout the worker passed to Go.
      expect(first['payload'], '{"handle":7,"timeoutMs":5000}');

      final Map<String, dynamic> empty = await waiter.wait(
        const Duration(milliseconds: 20),
      );
      expect(empty['available'], isFalse);

      await waiter.close();
      expect(await waiter.wait(const Duration(seconds: 5)), <String, dynamic>{
        'available': false,
        'closed': true,
      });
    },
  );

  test('close resolves a wait in progress as closed', () async {
    final IsolateSignalWaiter waiter = await IsolateSignalWaiter.spawn(
      nodeHandle: 7,
      openBridge: _openWorkerBridge,
    );
    await waiter.wait(const Duration(seconds: 1));

    final Future<Map<String, dynamic>> pending = waiter.wait(
      const Duration(milliseconds: 300),
    );
    await waiter.close();

    expect((await pending)['closed'], isTrue);
  });

  test('a bridge that does not open fails the spawn', () async {
    await expectLater(
      IsolateSignalWaiter.spawn(nodeHandle: 7, openBridge: _openBrokenBridge),
      throwsA(isA<StateError>()),
    );
  });

  test('a failing wait surfaces as an error', () async {
    final IsolateSignalWaiter waiter = await IsolateSignalWaiter.spawn(
      nodeHandle: -1,
      openBridge: _openWorkerBridge,
    );

    await expectLater(
      waiter.wait(const Duration(seconds: 1)),
      throwsA(isA<StateError>()),
    );
    await waiter.close();
  });
}

NativeSignalBridge _openWorkerBridge() => _WorkerBridge();

NativeSignalBridge _openBrokenBridge() =>
    throw UnsupportedError('no bridge here');

/// Runs inside the worker isolate: the first wait gets a signal, later
/// ones block for their timeout like the Go bridge with nothing queued.
final class _WorkerBridge implements NativeSignalBridge {
  int _waits = 0;

  @override
  Map<String, dynamic> waitSignal(int handle, int timeoutMs) {
    if (handle < 0) {
      throw StateError('node handle $handle does not exist');
    }
    _waits += 1;
    if (_waits == 1) {
      return <String, dynamic>{
        'available': true,
        'from': 'ada.ygg',
        'payload': '{"handle":$handle,"timeoutMs":$timeoutMs}',
      };
    }
    sleep(Duration(milliseconds: timeoutMs));
    return <String, dynamic>{'available': false};
  }

  @override
  Map<String, dynamic> pollSignal(int handle) => waitSignal(handle, 0);

  @override
  Map<String, dynamic> startSignaling(int handle) => const <String, dynamic>{
    'started': true,
  };

  @override
  Map<String, dynamic> sendSignal(
    int handle,
    String remoteAddress,
    String payload,
  ) => const <String, dynamic>{'sent': true};

  @override
  Map<String, dynamic> openRelay(int handle, String payloadJson) =>
      const <String, dynamic>{'port': 0};

  @override
  Map<String, dynamic> closeRelay(int handle, String callId) =>
      const <String, dynamic>{'closed': true};
}
