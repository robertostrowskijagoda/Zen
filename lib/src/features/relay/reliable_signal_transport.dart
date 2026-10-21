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
    this.idleTickInterval = const Duration(seconds: 30),
    ValueListenable<bool>? nodeRunning,
  }) : _delegate = delegate,
       _nodeRunning = nodeRunning {
    _nodeRunning?.addListener(_handleNodeRunningChanged);
  }

  final SignalTransport _delegate;
  final RelayEngine engine;

  /// How often the engine's housekeeping runs while something is due soon
  /// (a first try, a deposit, attachments moving, frames coming in)…
  final Duration tickInterval;

  /// …and while everything just waits (recipients offline, copies with
  /// their mailboxes, backoffs running): fewer wake-ups, which is what
  /// matters for the battery while the app works in the background.
  final Duration idleTickInterval;

  /// Whether this isolate's mesh node is up. The node can be stopped and
  /// started behind this wrapper's back (the Android background handoff
  /// drives the runtime directly), so ownership of the relay state follows
  /// this signal rather than [start]/[stop] alone.
  final ValueListenable<bool>? _nodeRunning;

  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();
  StreamSubscription<SignalTransportFrame>? _subscription;
  Timer? _ticker;
  DateTime? _tickDueAt;
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
      // Its mailboxes get a copy a few seconds from now if nobody answers.
      _hurryTick();
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
    } else {
      _hurryTick();
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
    _scheduleTick(tickInterval);
  }

  /// Arms the next tick [delay] from now; each tick arms the one after it,
  /// at the short or the idle interval as the engine needs.
  void _scheduleTick(Duration delay) {
    _ticker?.cancel();
    _ticker = null;
    _tickDueAt = null;
    if (!_engineActive) {
      return;
    }
    _tickDueAt = DateTime.now().add(delay);
    _ticker = Timer(delay, () {
      _ticker = null;
      _tickDueAt = null;
      unawaitedLogged(
        engine.tick().whenComplete(() {
          if (_engineActive && _ticker == null) {
            _scheduleTick(_nextTickDelay());
          }
        }),
        context: 'Relay engine tick failed',
      );
    });
  }

  Duration _nextTickDelay() {
    if (engine.wantsFrequentTicks || idleTickInterval <= tickInterval) {
      return tickInterval;
    }
    return idleTickInterval;
  }

  /// Something was queued or came in: the next tick comes at the short
  /// interval, not the idle one.
  void _hurryTick() {
    final DateTime? due = _tickDueAt;
    if (!_engineActive || _ticker == null || due == null) {
      return; // a tick is running and arms the next one itself
    }
    if (due.isAfter(DateTime.now().add(tickInterval))) {
      _scheduleTick(tickInterval);
    }
  }

  void _deactivateEngine() {
    _engineActive = false;
    _ticker?.cancel();
    _ticker = null;
    _tickDueAt = null;
    engine.deactivate();
  }
}
