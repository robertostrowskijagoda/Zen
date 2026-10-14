import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// [SignalTransport] with store-and-forward delivery on top of a raw mesh
/// transport.
///
/// * Reliable payload types ([kReliablePayloadTypes]) go through the
///   [RelayEngine] outbox: acknowledged, retried, relayed while the recipient
///   is offline. Everything else (calls, typing, presence, file chunks) is
///   passed straight through — those are either real-time or have their own
///   delivery protocol.
/// * Incoming frames are filtered by the engine: relay protocol frames are
///   consumed, duplicates dropped, relayed mail unpacked into ordinary frames
///   from the original sender.
///
/// The app above sees the same interface as before and does not need to know
/// whether a message came straight from the sender or from a friend's phone.
final class ReliableSignalTransport implements SignalTransport {
  ReliableSignalTransport({
    required SignalTransport delegate,
    required this.engine,
    this.tickInterval = const Duration(seconds: 5),
    ValueListenable<bool>? nodeRunning,
  }) : _delegate = delegate,
       _nodeRunning = nodeRunning {
    _nodeRunning?.addListener(_handleNodeRunningChanged);
  }

  final SignalTransport _delegate;
  final RelayEngine engine;
  final Duration tickInterval;

  /// Whether this isolate's mesh node is up. The node can be stopped and
  /// started behind this wrapper's back (the Android background handoff
  /// drives the runtime directly), so ownership of the relay state follows
  /// this signal rather than [start]/[stop] alone.
  final ValueListenable<bool>? _nodeRunning;

  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();
  StreamSubscription<SignalTransportFrame>? _subscription;
  Timer? _ticker;
  bool _engineActive = false;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    _subscription ??= _delegate.frames.listen(
      _handleFrame,
      onError: _frames.addError,
    );
    await _delegate.start();
    await _activateEngine();
  }

  @override
  Future<void> stop() async {
    _deactivateEngine();
    await _delegate.stop();
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    if (isReliablePayload(payload)) {
      await engine.submit(remoteAddress, payload);
      return;
    }
    final Map<String, dynamic> wire = payload.containsKey(kSendOnceKey)
        ? (Map<String, dynamic>.from(payload)..remove(kSendOnceKey))
        : payload;
    await _delegate.send(remoteAddress: remoteAddress, payload: wire);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) {
    return _delegate.openRelay(callId: callId, remoteAddress: remoteAddress);
  }

  @override
  Future<void> closeRelay(String callId) => _delegate.closeRelay(callId);

  Future<void> dispose() async {
    _nodeRunning?.removeListener(_handleNodeRunningChanged);
    _deactivateEngine();
    await _subscription?.cancel();
    _subscription = null;
    await _frames.close();
  }

  void _handleFrame(SignalTransportFrame frame) {
    // Any frame at all means the node is up in this isolate.
    if (!_engineActive) {
      unawaitedLogged(_activateEngine(), context: 'Relay engine activation');
    }
    unawaitedLogged(
      engine.handleIncoming(frame).then((List<SignalTransportFrame> out) {
        for (final SignalTransportFrame next in out) {
          if (!_frames.isClosed) {
            _frames.add(next);
          }
        }
      }),
      context: 'Relay frame handling failed',
    );
  }

  void _handleNodeRunningChanged() {
    final bool running = _nodeRunning?.value ?? false;
    if (running && !_engineActive) {
      unawaitedLogged(_activateEngine(), context: 'Relay engine activation');
    } else if (!running && _engineActive) {
      _deactivateEngine();
    }
  }

  Future<void> _activateEngine() async {
    if (_engineActive) {
      return;
    }
    if (_nodeRunning != null && !_nodeRunning.value) {
      return;
    }
    _engineActive = true;
    await engine.activate();
    _ticker?.cancel();
    _ticker = Timer.periodic(tickInterval, (_) {
      unawaitedLogged(engine.tick(), context: 'Relay engine tick failed');
    });
  }

  void _deactivateEngine() {
    _engineActive = false;
    _ticker?.cancel();
    _ticker = null;
    engine.deactivate();
  }
}
