import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// Ania's account: 'ania1' is her stolen phone (unlinked), 'ania2' the
/// other one. Nothing is known until [ready] (the ledger is loading).
final class _LoadingDir implements AccountDeviceDirectory {
  bool ready = false;

  @override
  String get ownAccount => ready ? 'ME' : '';

  @override
  String? accountOf(String address) =>
      ready && (address == 'ania1' || address == 'ania2') ? 'ANIA' : null;

  @override
  List<String> addressesOf(String account) => ready && account == 'ANIA'
      ? const <String>['ania1', 'ania2']
      : const <String>[];

  @override
  String? contactAddressOf(String account) =>
      account == 'ANIA' ? 'ania1' : null;

  @override
  String? unlinkedAccountOf(String address) =>
      ready && address == 'ania1' ? 'ANIA' : null;
}

void main() {
  test('while the ledger loads, frames wait; then the unlinked phone is not '
      'heard and the others arrive', () async {
    final MemorySignalTransport wire = MemorySignalTransport();
    await wire.start();
    addTearDown(wire.stop);
    final _LoadingDir dir = _LoadingDir();
    final AccountDirectoryHolder holder = AccountDirectoryHolder()
      ..directory = dir;
    final void Function() loaded = holder.expectLedger();
    final AccountRoutingTransport routed = AccountRoutingTransport(
      delegate: wire,
      directory: () => holder.directory,
      loading: () => holder.loading,
    );
    final List<String> got = <String>[];
    final StreamSubscription<SignalTransportFrame> sub = routed.frames.listen(
      (SignalTransportFrame f) => got.add('${f.from}:${f.payload['text']}'),
    );
    addTearDown(sub.cancel);

    await wire.injectIncoming(
      from: 'ania1',
      payload: <String, dynamic>{'type': 'message', 'text': 'thief'},
    );
    await wire.injectIncoming(
      from: 'ania2',
      payload: <String, dynamic>{'type': 'message', 'text': 'ania'},
    );
    await wire.injectIncoming(
      from: 'bob',
      payload: <String, dynamic>{'type': 'message', 'text': 'bob'},
    );
    await pumpEventQueue();
    expect(got, isEmpty, reason: 'nothing passes before the ledger knows');

    dir.ready = true;
    loaded();
    await pumpEventQueue();
    // Held, not dropped: Ania's other phone shows as her, Bob as Bob.
    expect(got, <String>['ania1:ania', 'bob:bob']);
    expect(holder.loading, isNull);
  });

  test('a send while the ledger loads waits, then skips the unlinked '
      'phone', () async {
    final MemorySignalTransport wire = MemorySignalTransport();
    await wire.start();
    addTearDown(wire.stop);
    final _LoadingDir dir = _LoadingDir();
    final AccountDirectoryHolder holder = AccountDirectoryHolder()
      ..directory = dir;
    final void Function() loaded = holder.expectLedger();
    final AccountRoutingTransport routed = AccountRoutingTransport(
      delegate: wire,
      directory: () => holder.directory,
      loading: () => holder.loading,
    );
    bool sent = false;
    unawaited(
      routed
          .send(
            remoteAddress: 'ania1',
            payload: <String, dynamic>{'type': 'message', 'text': 'hej'},
          )
          .then((_) => sent = true),
    );
    await pumpEventQueue();
    expect(sent, isFalse);
    expect(wire.sentSignals, isEmpty);

    dir.ready = true;
    loaded();
    await pumpEventQueue();
    expect(sent, isTrue);
    expect(
      <String>{
        for (final s in wire.sentSignals)
          if (s.payload['type'] == 'message') s.remoteAddress,
      },
      <String>{'ania2'},
    );
  });

  test('a ledger that never loads lets the traffic go as before', () async {
    final MemorySignalTransport wire = MemorySignalTransport();
    await wire.start();
    addTearDown(wire.stop);
    final AccountDirectoryHolder holder = AccountDirectoryHolder()
      ..directory = _LoadingDir();
    final void Function() gaveUp = holder.expectLedger();
    final AccountRoutingTransport routed = AccountRoutingTransport(
      delegate: wire,
      directory: () => holder.directory,
      loading: () => holder.loading,
    );
    final List<String> got = <String>[];
    final StreamSubscription<SignalTransportFrame> sub = routed.frames.listen(
      (SignalTransportFrame f) => got.add(f.from),
    );
    addTearDown(sub.cancel);
    await wire.injectIncoming(
      from: 'bob',
      payload: <String, dynamic>{'type': 'message', 'text': 'x'},
    );
    gaveUp();
    await pumpEventQueue();
    expect(got, <String>['bob']);
  });
}
