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
      waitTimeout: const Duration(milliseconds: 1),
    );
    final Completer<SignalTransportFrame> completer =
        Completer<SignalTransportFrame>();

    bridge.pollResponses.add(<String, dynamic>{
      'available': true,
      'from': 'ada.ygg',
      'payload': '{"type":"pong","state":"foreground"}',
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
      const Duration(seconds: 1),
    );
    await transport.stop();
    await subscription.cancel();

    expect(bridge.startSignalingCalls, 1);
    expect(frame.from, 'ada.ygg');
    expect(frame.payload, const <String, dynamic>{
      'type': 'pong',
      'state': 'foreground',
    });
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
      waitTimeout: const Duration(milliseconds: 1),
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
      waitTimeout: const Duration(milliseconds: 1),
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

  test('pump survives pollSignal errors and keeps receiving', () async {
    final _FakeNativeSignalBridge bridge = _FakeNativeSignalBridge();
    final YggdrasilSignalTransport transport = YggdrasilSignalTransport(
      bridge: bridge,
      nodeHandle: 7,
      compressor: const _PassthroughSignalCompressor(),
      waitTimeout: const Duration(milliseconds: 1),
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
  });
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
