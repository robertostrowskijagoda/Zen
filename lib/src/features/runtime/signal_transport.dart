import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final signalTransportProvider = Provider<SignalTransport>((Ref ref) {
  return const NoopSignalTransport();
});

bool isRoutablePeerAddress(String value) {
  final String trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) {
    return false;
  }
  final InternetAddress? address = InternetAddress.tryParse(trimmed);
  if (address != null && address.type == InternetAddressType.IPv6) {
    return true;
  }
  if (trimmed.contains(':') &&
      !trimmed.contains('/') &&
      !trimmed.contains(' ')) {
    final List<String> parts = trimmed.split(':');
    if (parts.length >= 3 &&
        parts.every(
          (String p) => p.isEmpty || RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(p),
        )) {
      return true;
    }
  }
  return false;
}

@immutable
final class SignalTransportFrame {
  const SignalTransportFrame({
    required this.from,
    required this.payload,
    required this.receivedAtMillis,
    this.door = false,
  });

  final String from;
  final Map<String, dynamic> payload;
  final int receivedAtMillis;

  /// It came to the flat's door address (a knock on the door sticker,
  /// §18.2), not to this phone's own address.
  final bool door;
}

abstract interface class SignalTransport {
  Stream<SignalTransportFrame> get frames;

  Future<void> start();

  Future<void> stop();

  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  });

  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  });

  Future<void> closeRelay(String callId);
}

class MemorySignalTransport implements SignalTransport {
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();
  final List<({String remoteAddress, Map<String, dynamic> payload})>
  sentSignals = <({String remoteAddress, Map<String, dynamic> payload})>[];
  final List<({String callId, String remoteAddress})> openedRelays =
      <({String callId, String remoteAddress})>[];
  final List<String> closedRelays = <String>[];

  bool _started = false;
  int relayPortResult = 0;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    _started = true;
  }

  @override
  Future<void> stop() async {
    _started = false;
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    sentSignals.add((
      remoteAddress: remoteAddress,
      payload: Map<String, dynamic>.from(payload),
    ));
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async {
    openedRelays.add((callId: callId, remoteAddress: remoteAddress));
    return relayPortResult;
  }

  @override
  Future<void> closeRelay(String callId) async {
    closedRelays.add(callId);
  }

  Future<void> injectIncoming({
    required String from,
    required Map<String, dynamic> payload,
    int? receivedAtMillis,
  }) async {
    if (!_started) {
      return;
    }
    _frames.add(
      SignalTransportFrame(
        from: from,
        payload: Map<String, dynamic>.from(payload),
        receivedAtMillis:
            receivedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}

class NoopSignalTransport implements SignalTransport {
  const NoopSignalTransport();

  @override
  Stream<SignalTransportFrame> get frames =>
      const Stream<SignalTransportFrame>.empty();

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {}

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async {
    return 0;
  }

  @override
  Future<void> closeRelay(String callId) async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}
