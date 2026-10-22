import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

void main() {
  test('bridges no longer chosen are dropped, new ones added, and all are '
      'added again after a restart', () async {
    final List<String> added = <String>[];
    final List<String> removed = <String>[];
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
      bootstrap: () async => RuntimeNodeSession(
        transport: MemorySignalTransport(),
        snapshot: RuntimeTransportSnapshot.started(
          localAddress: '200::1',
          peers: 1,
        ),
        addPeer: added.add,
        removePeer: removed.add,
      ),
    );
    addTearDown(runtime.dispose);

    // Before the node is up: kept for its start.
    runtime.setMeshPeers(<String>['tls://a:1', 'tls://b:1']);
    expect(added, isEmpty);
    await runtime.start();
    expect(added, unorderedEquals(<String>['tls://a:1', 'tls://b:1']));

    added.clear();
    runtime.setMeshPeers(<String>['tls://b:1', 'tls://c:1']);
    expect(removed, <String>['tls://a:1']);
    expect(added, <String>['tls://c:1']);
    expect(runtime.meshPeers, <String>{'tls://b:1', 'tls://c:1'});

    // The same choice again changes nothing.
    added.clear();
    removed.clear();
    runtime.setMeshPeers(<String>['tls://c:1', 'tls://b:1']);
    expect(added, isEmpty);
    expect(removed, isEmpty);
  });

  test('a phone connects to one friend\'s bridge, a computer to five', () {
    expect(ledgerBridgeConnections(phone: true), 1);
    expect(ledgerBridgeConnections(phone: false), 5);
  });
}
