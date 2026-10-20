import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/yggdrasil_signal_transport.dart';

void main() {
  test('send encodes payload through the runtime codec', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
    );

    await transport.send(
      remoteAddress: 'ada.ygg',
      payload: const <String, dynamic>{'type': 'ping'},
    );

    expect(bridge.sentSignals, hasLength(1));
    expect(bridge.sentSignals.single.remoteAddress, 'ada.ygg');
    expect(bridge.sentSignals.single.payload, '{"type":"ping"}');
  });

  test('startSignaling pumps decoded incoming signals into frames', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      fallbackPollInterval: const Duration(milliseconds: 10),
    );
    final List<SignalTransportFrame> frames = <SignalTransportFrame>[];
    final Completer<void> completer = Completer<void>();

    bridge.pollResponses
      ..add(<String, dynamic>{
        'available': true,
        'from': 'ada.ygg',
        'payload': '{"type":"pong","state":"foreground"}',
      })
      // A knock that came to the flat's door (door_node.go).
      ..add(<String, dynamic>{
        'available': true,
        'from': 'bob.ygg',
        'payload': '{"type":"flat_hello"}',
        'door': true,
      });

    final StreamSubscription<SignalTransportFrame> subscription = transport
        .frames
        .listen((SignalTransportFrame frame) {
          frames.add(frame);
          if (frames.length == 2 && !completer.isCompleted) {
            completer.complete();
          }
        });

    await transport.start();
    await completer.future.timeout(const Duration(seconds: 1));
    await transport.stop();
    await subscription.cancel();

    expect(bridge.startSignalingCalls, 1);
    final SignalTransportFrame frame = frames.first;
    expect(frame.from, 'ada.ygg');
    expect(frame.payload, const <String, dynamic>{
      'type': 'pong',
      'state': 'foreground',
    });
    expect(frame.door, isFalse);
    expect(frames.last.from, 'bob.ygg');
    expect(frames.last.door, isTrue);
  });

  test('openRelay delegates to the native bridge', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    bridge.relayPort = 54322;
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
    );

    final int port = await transport.openRelay(
      callId: 'call-1',
      remoteAddress: 'ada.ygg',
    );
    await transport.closeRelay('call-1');

    expect(port, 54322);
    expect(bridge.openedRelays.single.callId, 'call-1');
    expect(bridge.openedRelays.single.remoteAddress, 'ada.ygg');
    expect(bridge.closedRelays, <String>['call-1']);
  });

  test('pump survives an undecodable signal and keeps receiving', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      fallbackPollInterval: const Duration(milliseconds: 10),
    );
    final Completer<SignalTransportFrame> completer =
        Completer<SignalTransportFrame>();

    bridge.pollResponses.add(<String, dynamic>{
      'available': true,
      'from': 'eve.ygg',
      'payload': '!!!not-json!!!',
    });
    bridge.pollResponses.add(<String, dynamic>{
      'available': true,
      'from': 'ada.ygg',
      'payload': '{"type":"pong"}',
    });

    final StreamSubscription<SignalTransportFrame> subscription = transport
        .frames
        .listen((SignalTransportFrame frame) {
          if (!completer.isCompleted) {
            completer.complete(frame);
          }
        });

    await transport.start();
    final SignalTransportFrame frame = await completer.future.timeout(
      const Duration(seconds: 5),
    );
    await transport.stop();
    await subscription.cancel();

    expect(frame.from, 'ada.ygg');
    expect(frame.payload, const <String, dynamic>{'type': 'pong'});
  });

  test('pump drops a signal over the size limit and keeps receiving', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      fallbackPollInterval: const Duration(milliseconds: 10),
    );
    final List<SignalTransportFrame> frames = <SignalTransportFrame>[];
    final Completer<void> received = Completer<void>();

    bridge.pollResponses.add(<String, dynamic>{
      'available': true,
      'from': 'eve.ygg',
      'payload': '{"type":"pong","pad":"${'x' * kRuntimeSignalMaxBytes}"}',
    });
    bridge.pollResponses.add(<String, dynamic>{
      'available': true,
      'from': 'ada.ygg',
      'payload': '{"type":"pong"}',
    });

    final StreamSubscription<SignalTransportFrame> subscription = transport
        .frames
        .listen((SignalTransportFrame frame) {
          frames.add(frame);
          if (frame.from == 'ada.ygg' && !received.isCompleted) {
            received.complete();
          }
        });

    await transport.start();
    await received.future.timeout(const Duration(seconds: 5));
    await transport.stop();
    await subscription.cancel();

    expect(frames.map((SignalTransportFrame frame) => frame.from), <String>[
      'ada.ygg',
    ]);
  });

  test(
    'pump survives pollSignal errors and keeps receiving (polling)',
    () async {
      final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
      final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
        bridge: bridge,
        nodeHandle: 7,
        compressor: const _PassthroughSignalCompressor(),
        fallbackPollInterval: const Duration(milliseconds: 10),
      );
      final Completer<SignalTransportFrame> completer =
          Completer<SignalTransportFrame>();

      bridge.pollFailuresRemaining = 2;
      bridge.pollResponses.add(<String, dynamic>{
        'available': true,
        'from': 'ada.ygg',
        'payload': '{"type":"pong"}',
      });

      final StreamSubscription<SignalTransportFrame> subscription = transport
          .frames
          .listen((SignalTransportFrame frame) {
            if (!completer.isCompleted) {
              completer.complete(frame);
            }
          });

      await transport.start();
      final SignalTransportFrame frame = await completer.future.timeout(
        const Duration(seconds: 10),
      );
      await transport.stop();
      await subscription.cancel();

      expect(frame.from, 'ada.ygg');
      expect(frame.payload, const <String, dynamic>{'type': 'pong'});
    },
  );

  test('signals arrive through the waiter as they come', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final _FakeSignalWaiter waiter = _FakeSignalWaiter();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      openWaiter: () async => waiter,
      // A poll would show up here only as the drain after each signal.
      fallbackPollInterval: const Duration(hours: 1),
    );
    final List<SignalTransportFrame> frames = <SignalTransportFrame>[];
    final StreamSubscription<SignalTransportFrame> subscription = transport
        .frames
        .listen(frames.add);

    await transport.start();
    await waiter.untilWaiting();
    expect(frames, isEmpty);
    expect(bridge.pollCalls, 0);

    waiter.deliver(<String, dynamic>{
      'available': true,
      'from': 'ada.ygg',
      'payload': '{"type":"ping"}',
    });
    await waiter.untilWaiting();
    expect(frames.single.from, 'ada.ygg');
    // One drain after the signal, nothing on a timer.
    expect(bridge.pollCalls, 1);

    // An empty wait (its timeout) is simply renewed.
    waiter.deliver(const <String, dynamic>{'available': false});
    await waiter.untilWaiting();
    expect(frames, hasLength(1));
    expect(bridge.pollCalls, 1);
    expect(waiter.timeouts.toSet(), <Duration>{const Duration(seconds: 2)});

    await transport.stop();
    await subscription.cancel();
    expect(waiter.closed, isTrue);
  });

  test('stop does not wait for a pending wait', () async {
    final _FakeSignalWaiter waiter = _FakeSignalWaiter();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: _FakeNativeSignalBridge(),
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      openWaiter: () async => waiter,
      waitTimeout: const Duration(hours: 1),
    );

    await transport.start();
    await waiter.untilWaiting();
    await transport.stop().timeout(const Duration(seconds: 1));

    expect(waiter.closed, isTrue);
  });

  test('the pump ends when the node stops', () async {
    final _FakeSignalWaiter waiter = _FakeSignalWaiter();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: _FakeNativeSignalBridge(),
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      openWaiter: () async => waiter,
    );

    await transport.start();
    await waiter.untilWaiting();
    waiter.deliver(const <String, dynamic>{'available': false, 'closed': true});
    await waiter.closedFuture.timeout(const Duration(seconds: 1));
    expect(waiter.waitCount, 1);
    await transport.stop();
  });

  test('a failing waiter falls back to polling', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final _FakeSignalWaiter waiter = _FakeSignalWaiter();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      openWaiter: () async => waiter,
      fallbackPollInterval: const Duration(milliseconds: 10),
    );
    final Completer<SignalTransportFrame> received =
        Completer<SignalTransportFrame>();
    final StreamSubscription<SignalTransportFrame> subscription = transport
        .frames
        .listen((SignalTransportFrame frame) {
          if (!received.isCompleted) {
            received.complete(frame);
          }
        });

    await transport.start();
    await waiter.untilWaiting();
    waiter.fail(StateError('simulated waiter crash'));
    bridge.pollResponses.add(<String, dynamic>{
      'available': true,
      'from': 'ada.ygg',
      'payload': '{"type":"pong"}',
    });
    final SignalTransportFrame frame = await received.future.timeout(
      const Duration(seconds: 5),
    );
    await transport.stop();
    await subscription.cancel();

    expect(frame.from, 'ada.ygg');
    expect(waiter.closed, isTrue);
  });

  test('a waiter that cannot start falls back to polling', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      openWaiter: () async => throw StateError('no isolate'),
      fallbackPollInterval: const Duration(milliseconds: 10),
    );
    final Completer<SignalTransportFrame> received =
        Completer<SignalTransportFrame>();
    bridge.pollResponses.add(<String, dynamic>{
      'available': true,
      'from': 'ada.ygg',
      'payload': '{"type":"pong"}',
    });
    final StreamSubscription<SignalTransportFrame> subscription = transport
        .frames
        .listen((SignalTransportFrame frame) {
          if (!received.isCompleted) {
            received.complete(frame);
          }
        });

    await transport.start();
    final SignalTransportFrame frame = await received.future.timeout(
      const Duration(seconds: 5),
    );
    await transport.stop();
    await subscription.cancel();

    expect(frame.from, 'ada.ygg');
  });
}

/// A waiter driven by the test: each wait stays pending until [deliver].
final class _FakeSignalWaiter implements SignalWaiter {
  final Completer<void> _closed = Completer<void>();
  final List<Duration> timeouts = <Duration>[];
  Completer<Map<String, dynamic>>? _pending;
  int waitCount = 0;

  bool get closed => _closed.isCompleted;

  Future<void> get closedFuture => _closed.future;

  /// Returns once the transport is blocked in a wait (so whatever it did
  /// with the previous result is done).
  Future<void> untilWaiting() async {
    for (int tries = 0; _pending == null; tries++) {
      if (tries > 2000) {
        throw StateError('The transport never waited.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void deliver(Map<String, dynamic> result) {
    final Completer<Map<String, dynamic>> pending = _pending!;
    _pending = null;
    pending.complete(result);
  }

  void fail(Object error) {
    final Completer<Map<String, dynamic>> pending = _pending!;
    _pending = null;
    pending.completeError(error);
  }

  @override
  Future<Map<String, dynamic>> wait(Duration timeout) {
    waitCount += 1;
    timeouts.add(timeout);
    final Completer<Map<String, dynamic>> pending =
        Completer<Map<String, dynamic>>();
    _pending = pending;
    return pending.future;
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }
}

final class _FakeNativeSignalBridge implements NativeSignalBridge {
  final Queue<Map<String, dynamic>> pollResponses =
      Queue<Map<String, dynamic>>();
  final List<({int handle, String remoteAddress, String payload})> sentSignals =
      <({int handle, String remoteAddress, String payload})>[];
  final List<({int handle, String callId, String remoteAddress})> openedRelays =
      <({int handle, String callId, String remoteAddress})>[];
  final List<String> closedRelays = <String>[];
  int startSignalingCalls = 0;
  int relayPort = 0;
  int pollFailuresRemaining = 0;
  int pollCalls = 0;

  @override
  Map<String, dynamic> sendSignal(
    int handle,
    String remoteAddress,
    String payload,
  ) {
    sentSignals.add((
      handle: handle,
      remoteAddress: remoteAddress,
      payload: payload,
    ));
    return const <String, dynamic>{'sent': true};
  }

  @override
  Map<String, dynamic> startSignaling(int handle) {
    startSignalingCalls += 1;
    return const <String, dynamic>{'started': true};
  }

  @override
  Map<String, dynamic> waitSignal(int handle, int timeoutMs) {
    return pollSignal(handle);
  }

  @override
  Map<String, dynamic> pollSignal(int handle) {
    pollCalls += 1;
    if (pollFailuresRemaining > 0) {
      pollFailuresRemaining -= 1;
      throw StateError('simulated FFI poll failure');
    }
    return pollResponses.isEmpty
        ? const <String, dynamic>{'available': false}
        : pollResponses.removeFirst();
  }

  @override
  Map<String, dynamic> openRelay(int handle, String payloadJson) {
    final Map<String, dynamic> payload =
        jsonDecode(payloadJson) as Map<String, dynamic>;
    openedRelays.add((
      handle: handle,
      callId: payload['callId'] as String? ?? '',
      remoteAddress: payload['remoteAddress'] as String? ?? '',
    ));
    return <String, dynamic>{'port': relayPort};
  }

  @override
  Map<String, dynamic> closeRelay(int handle, String callId) {
    closedRelays.add(callId);
    return const <String, dynamic>{'closed': true};
  }
}

final class _PassthroughSignalCompressor implements SignalPayloadCompressor {
  const _PassthroughSignalCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async {
    return input;
  }

  @override
  Future<Uint8List?> decompress(Uint8List input) async {
    return input;
  }
}
