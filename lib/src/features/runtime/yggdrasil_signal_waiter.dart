import 'dart:async';
import 'dart:isolate';

import 'package:zen/src/features/runtime/yggdrasil_signal_transport.dart';

/// A [SignalWaiter] that blocks on the bridge's `YggWaitSignal` in an
/// isolate of its own, so the isolate running the app (or the Android
/// background service) is woken only when a signal arrives.
///
/// One wait at a time: the transport asks, the worker blocks in Go and
/// replies, the transport takes the signal (and drains what queued up) and
/// asks again. Signals stay in the bridge's bounded inbox
/// (signal_inbox.go) until the app is ready for them, instead of piling up
/// in a port.
///
/// Stopping the node (`YggStopNode`) wakes a blocked wait at once; [close]
/// lets the worker end after its current wait.
final class IsolateSignalWaiter implements SignalWaiter {
  IsolateSignalWaiter._(this._replies) {
    // A worker that fails before [spawn] awaits this must not surface as
    // an unhandled error; [spawn] still gets it.
    _ready.future.ignore();
    _replies.listen(_onReply);
  }

  /// Starts the worker for [nodeHandle]. [openBridge] runs in the worker
  /// and opens its own handle to the bridge (a top-level or static
  /// function, e.g. `YggdrasilBridgeFfi.load`).
  static Future<IsolateSignalWaiter> spawn({
    required int nodeHandle,
    required NativeSignalBridge Function() openBridge,
  }) async {
    final ReceivePort replies = ReceivePort('zen-signal-waiter');
    final IsolateSignalWaiter waiter = IsolateSignalWaiter._(replies);
    try {
      await Isolate.spawn<_WaiterStart>(
        _signalWaiterMain,
        _WaiterStart(
          replies: replies.sendPort,
          nodeHandle: nodeHandle,
          openBridge: openBridge,
        ),
        onExit: replies.sendPort,
        onError: replies.sendPort,
        debugName: 'zen-signal-waiter',
      );
      await waiter._ready.future;
    } catch (_) {
      waiter._closed = true;
      replies.close();
      rethrow;
    }
    return waiter;
  }

  static const Map<String, dynamic> _closedResult = <String, dynamic>{
    'available': false,
    'closed': true,
  };

  final ReceivePort _replies;
  final Completer<void> _ready = Completer<void>();
  SendPort? _requests;
  Completer<Map<String, dynamic>>? _pending;
  bool _closed = false;

  @override
  Future<Map<String, dynamic>> wait(Duration timeout) {
    if (_closed) {
      return Future<Map<String, dynamic>>.value(_closedResult);
    }
    final SendPort? requests = _requests;
    if (requests == null) {
      return Future<Map<String, dynamic>>.error(
        StateError('The signal waiter has not started.'),
      );
    }
    if (_pending != null) {
      return Future<Map<String, dynamic>>.error(
        StateError('A signal wait is already in progress.'),
      );
    }
    final Completer<Map<String, dynamic>> pending =
        Completer<Map<String, dynamic>>();
    _pending = pending;
    requests.send(timeout.inMilliseconds < 0 ? 0 : timeout.inMilliseconds);
    return pending.future;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    // The worker ends once its current wait returns (at once when the node
    // stopped); its exit closes the port.
    _requests?.send(null);
    _settle(_closedResult);
  }

  void _onReply(Object? message) {
    if (message is SendPort) {
      _requests = message;
      if (!_ready.isCompleted) {
        _ready.complete();
      }
      if (_closed) {
        message.send(null);
      }
      return;
    }
    if (message is _WaiterReply) {
      final String? error = message.error;
      if (error != null) {
        _fail(StateError(error));
      } else {
        _settle(message.result ?? const <String, dynamic>{'available': false});
      }
      return;
    }
    if (message is List) {
      // An uncaught error in the worker: [error, stack trace].
      _fail(StateError('Signal waiter crashed: ${message.first}'));
      return;
    }
    // null: the worker exited.
    _replies.close();
    _fail(StateError('The signal waiter stopped.'));
    _closed = true;
  }

  void _settle(Map<String, dynamic> result) {
    final Completer<Map<String, dynamic>>? pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(result);
    }
  }

  void _fail(Object error) {
    if (!_ready.isCompleted) {
      _ready.completeError(error);
    }
    final Completer<Map<String, dynamic>>? pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
    }
  }
}

final class _WaiterStart {
  const _WaiterStart({
    required this.replies,
    required this.nodeHandle,
    required this.openBridge,
  });

  final SendPort replies;
  final int nodeHandle;
  final NativeSignalBridge Function() openBridge;
}

final class _WaiterReply {
  const _WaiterReply({this.result, this.error});

  final Map<String, dynamic>? result;
  final String? error;
}

/// The worker: opens the bridge, then serves one wait per request (the
/// timeout in milliseconds) until it gets `null`.
void _signalWaiterMain(_WaiterStart start) {
  final NativeSignalBridge bridge;
  try {
    bridge = start.openBridge();
  } on Object catch (error) {
    start.replies.send(_WaiterReply(error: 'Bridge did not open: $error'));
    return;
  }
  final ReceivePort requests = ReceivePort('zen-signal-waiter-requests');
  start.replies.send(requests.sendPort);
  requests.listen((Object? message) {
    if (message is! int) {
      requests.close();
      return;
    }
    try {
      start.replies.send(
        _WaiterReply(result: bridge.waitSignal(start.nodeHandle, message)),
      );
    } on Object catch (error) {
      start.replies.send(_WaiterReply(error: '$error'));
    }
  });
}
