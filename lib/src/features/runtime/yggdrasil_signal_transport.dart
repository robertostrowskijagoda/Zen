import 'dart:async';
import 'dart:convert';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

abstract interface class NativeSignalBridge {
  Map<String, dynamic> startSignaling(int handle);

  Map<String, dynamic> sendSignal(
    int handle,
    String remoteAddress,
    String payload,
  );

  Map<String, dynamic> waitSignal(int handle, int timeoutMs);

  Map<String, dynamic> pollSignal(int handle);

  Map<String, dynamic> openRelay(int handle, String payloadJson);

  Map<String, dynamic> closeRelay(int handle, String callId);
}

final class YggdrasilSignalTransport implements SignalTransport {
  YggdrasilSignalTransport({
    required this.bridge,
    required this.nodeHandle,
    required this.compressor,
    this.waitTimeout = const Duration(seconds: 2),
    this.maxIdleDelay = const Duration(milliseconds: 500),
  });

  final NativeSignalBridge bridge;
  final int nodeHandle;
  final SignalPayloadCompressor compressor;
  final Duration waitTimeout;

  /// Upper bound of the adaptive idle backoff. The pump sleeps longer and
  /// longer between empty polls while nothing happens, and snaps back to the
  /// fast path as soon as traffic flows.
  final Duration maxIdleDelay;

  static const Duration _minIdleDelay = Duration(milliseconds: 40);
  static const Duration _recentTrafficIdleCap = Duration(milliseconds: 120);
  static const int _recentTrafficWindowMillis = 60000;

  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();

  bool _running = false;
  Future<void>? _pumpFuture;

  /// Completed by [stop] to cut a sleeping pump short. Without it a background
  /// runtime with a multi-second idle cap kept the node alive long after the
  /// foreground asked for it back, and the two nodes overlapped.
  Completer<void>? _idleWakeup;
  Duration _idleDelay = _minIdleDelay;
  int _lastActivityMillis = DateTime.now().millisecondsSinceEpoch;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    bridge.startSignaling(nodeHandle);
    final Future<void> pump = _pumpSignals();
    _pumpFuture = pump;
    // If the pump ever dies unexpectedly, allow start() to relaunch it.
    unawaited(
      pump.whenComplete(() {
        if (identical(_pumpFuture, pump)) {
          _running = false;
          _pumpFuture = null;
        }
      }),
    );
  }

  @override
  Future<void> stop() async {
    _running = false;
    _wakeIdlePump();
    await (_pumpFuture ?? Future<void>.value());
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String encoded = await encodeRuntimeSignalPayload(
      payload,
      compressor,
    );
    bridge.sendSignal(nodeHandle, remoteAddress, encoded);
    _noteActivity();
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async {
    final Map<String, dynamic> result = bridge.openRelay(
      nodeHandle,
      jsonEncode(<String, dynamic>{
        'callId': callId,
        'remoteAddress': remoteAddress,
      }),
    );
    return (result['port'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> closeRelay(String callId) async {
    bridge.closeRelay(nodeHandle, callId);
  }

  Future<void> _pumpSignals() async {
    while (_running) {
      bool receivedAny = false;
      try {
        final bool drainedAny = await _drainAvailableSignals();
        if (!_running) {
          break;
        }
        receivedAny = drainedAny;
      } catch (error, stackTrace) {
        // A failing FFI poll or a crashing decoder must not kill the pump —
        // without this the receiver goes permanently deaf until app restart.
        logZenError('signal pump iteration failed', error, stackTrace);
        if (!_running) {
          break;
        }
        await _sleep(const Duration(seconds: 1));
        continue;
      }
      if (!_running) {
        break;
      }
      if (receivedAny) {
        _noteActivity();
        await Future<void>.delayed(Duration.zero);
      } else {
        final Duration cap = _currentIdleCap();
        final int nextDelayMs = (_idleDelay.inMilliseconds * 1.5).toInt();
        _idleDelay = Duration(
          milliseconds: nextDelayMs.clamp(
            _minIdleDelay.inMilliseconds,
            cap.inMilliseconds,
          ),
        );
        await _sleep(_idleDelay);
      }
    }
  }

  /// Interruptible sleep: returns after [duration], or immediately once
  /// [stop] flips the pump off.
  Future<void> _sleep(Duration duration) async {
    if (!_running) {
      return;
    }
    final Completer<void> completer = Completer<void>();
    _idleWakeup = completer;
    final Timer timer = Timer(duration, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future;
    } finally {
      timer.cancel();
      if (identical(_idleWakeup, completer)) {
        _idleWakeup = null;
      }
    }
  }

  void _wakeIdlePump() {
    final Completer<void>? completer = _idleWakeup;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _noteActivity() {
    _idleDelay = _minIdleDelay;
    _lastActivityMillis = DateTime.now().millisecondsSinceEpoch;
  }

  Duration _currentIdleCap() {
    final bool recentlyActive =
        DateTime.now().millisecondsSinceEpoch - _lastActivityMillis <
        _recentTrafficWindowMillis;
    return recentlyActive ? _recentTrafficIdleCap : maxIdleDelay;
  }

  Future<void> _processSignalResult(Map<String, dynamic> result) async {
    final String rawPayload = result['payload'] as String? ?? '';
    final String from = result['from'] as String? ?? '';
    if (rawPayload.isEmpty || from.isEmpty) {
      return;
    }
    final Map<String, dynamic>? payload;
    try {
      payload = await decodeRuntimeSignalPayload(rawPayload, compressor);
    } catch (error, stackTrace) {
      logZenError(
        'failed to decode incoming signal payload',
        error,
        stackTrace,
      );
      return;
    }
    if (payload == null) {
      return;
    }
    _frames.add(
      SignalTransportFrame(
        from: from,
        payload: payload,
        receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<bool> _drainAvailableSignals() async {
    bool drainedAny = false;
    while (_running) {
      final Map<String, dynamic> result = bridge.pollSignal(nodeHandle);
      if (result['available'] != true) {
        return drainedAny;
      }
      drainedAny = true;
      await _processSignalResult(result);
    }
    return drainedAny;
  }
}
