import 'dart:async';
import 'dart:convert';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';

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

/// Waits for the bridge's next signal off the caller's isolate
/// (`YggWaitSignal` blocks a thread; yggdrasil_signal_waiter.dart).
abstract interface class SignalWaiter {
  /// The next result of the bridge's wait: `{available: true, from,
  /// payload, door?}`, or `{available: false}` after [timeout] with nothing,
  /// or `{available: false, closed: true}` once the node stopped.
  Future<Map<String, dynamic>> wait(Duration timeout);

  /// Ends the waiter; a wait in progress resolves as closed.
  Future<void> close();
}

/// Signals from the Go bridge as they arrive: a [SignalWaiter] blocks on
/// the bridge's wait in an isolate of its own and wakes this one per
/// signal (no polling timer). Only when no waiter can be opened, or it
/// fails, the transport polls every [fallbackPollInterval].
final class YggdrasilSignalTransport implements SignalTransport {
  YggdrasilSignalTransport({
    required this.bridge,
    required this.nodeHandle,
    required this.compressor,
    this.openWaiter,
    this.waitTimeout = const Duration(seconds: 2),
    this.fallbackPollInterval = const Duration(seconds: 1),
  });

  final NativeSignalBridge bridge;
  final int nodeHandle;
  final SignalPayloadCompressor compressor;

  /// Opens the waiter for this node; `null` means poll only.
  final Future<SignalWaiter> Function()? openWaiter;

  /// How long one wait blocks before it returns empty and is renewed.
  final Duration waitTimeout;

  /// Polling interval used only without a working waiter.
  final Duration fallbackPollInterval;

  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();

  bool _running = false;
  Future<void>? _pumpFuture;

  /// Completed by [stop]: cuts a fallback sleep or a pending wait short, so
  /// stopping never waits for a wait's timeout.
  Completer<void>? _stopRequested;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    _stopRequested = Completer<void>();
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
    final Completer<void>? stopRequested = _stopRequested;
    if (stopRequested != null && !stopRequested.isCompleted) {
      stopRequested.complete();
    }
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
    SignalWaiter? waiter = await _openWaiter();
    try {
      while (_running) {
        if (waiter == null) {
          await _pollOnce();
          await _sleep(fallbackPollInterval);
          continue;
        }
        final Map<String, dynamic>? result;
        try {
          result = await _waitOrStop(waiter);
        } catch (error) {
          // A broken waiter (its isolate died, the FFI call failed) must
          // not leave the app deaf: poll for the rest of this session. Its
          // stack (an async chain across isolates) says nothing useful.
          logZenWarning('signal wait failed; falling back to polling: $error');
          unawaited(waiter.close());
          waiter = null;
          continue;
        }
        if (result == null || !_running) {
          break;
        }
        if (result['closed'] == true) {
          logZenMessage('Signal wait ended: the node stopped.');
          break;
        }
        if (result['available'] == true) {
          // The packet woke the phone; it stays awake a few seconds so the
          // signal is handled (no lock holds it otherwise).
          ZenWake.signalArrived();
          await _processSignalResult(result);
          // Whatever queued up meanwhile, without another round trip.
          await _pollOnce();
        }
      }
    } finally {
      await waiter?.close();
    }
  }

  Future<SignalWaiter?> _openWaiter() async {
    final Future<SignalWaiter> Function()? open = openWaiter;
    if (open == null) {
      return null;
    }
    try {
      return await open();
    } catch (error) {
      logZenWarning(
        'signal waiter did not start; falling back to polling: $error',
      );
      return null;
    }
  }

  /// The waiter's next result, or `null` once [stop] was asked for.
  Future<Map<String, dynamic>?> _waitOrStop(SignalWaiter waiter) {
    final Completer<void>? stopRequested = _stopRequested;
    final Future<Map<String, dynamic>?> next = waiter.wait(waitTimeout);
    if (stopRequested == null) {
      return next;
    }
    return Future.any<Map<String, dynamic>?>(<Future<Map<String, dynamic>?>>[
      next,
      stopRequested.future.then((_) => null),
    ]);
  }

  /// Takes every signal queued now. A failing FFI poll or a crashing
  /// decoder must not kill the pump: without this the receiver went deaf
  /// until the app restarted.
  Future<void> _pollOnce() async {
    try {
      await _drainAvailableSignals();
    } catch (error, stackTrace) {
      logZenError('signal poll failed', error, stackTrace);
    }
  }

  /// Interruptible sleep: returns after [duration], or as soon as [stop] is
  /// asked for.
  Future<void> _sleep(Duration duration) async {
    final Completer<void>? stopRequested = _stopRequested;
    if (!_running || stopRequested == null) {
      return;
    }
    final Completer<void> slept = Completer<void>();
    final Timer timer = Timer(duration, slept.complete);
    try {
      await Future.any<void>(<Future<void>>[
        slept.future,
        stopRequested.future,
      ]);
    } finally {
      timer.cancel();
    }
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
        door: result['door'] == true,
        senderKey: result['key'] as String?,
      ),
    );
  }

  Future<void> _drainAvailableSignals() async {
    while (_running) {
      final Map<String, dynamic> result = bridge.pollSignal(nodeHandle);
      if (result['available'] != true) {
        return;
      }
      await _processSignalResult(result);
    }
  }
}
