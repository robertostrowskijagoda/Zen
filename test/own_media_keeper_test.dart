import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

LedgerNode _node(MemorySignalTransport transport) {
  final LedgerNode node = LedgerNode(
    transport: transport,
    disk: MemoryLedgerDisk(),
    friendAddresses: () => const <String>[],
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => '200:1::1',
    greetAlso: () => const <String>[],
    syncInterval: Duration.zero,
  );
  addTearDown(node.stop);
  return node;
}

void main() {
  test(
    'the account files keeper stops with its owner, also mid-start',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      await transport.start();
      addTearDown(transport.stop);
      final LedgerNode node = _node(transport);

      // Stopped while the node was still starting: no timer outlives it.
      final OwnMediaKeeper early = OwnMediaKeeper(node: node);
      final Future<void> starting = early.start();
      early.stop();
      await starting;
      expect(early.ticking, isFalse);

      final OwnMediaKeeper keeper = OwnMediaKeeper(node: node);
      await keeper.start();
      expect(keeper.ticking, isTrue);
      keeper.stop();
      expect(keeper.ticking, isFalse);
    },
  );

  test('every state is scanned only now and then; changes do not wait', () {
    // Each scan decrypts about ten stores: a safety net, not the way
    // changes travel (they go out a moment after a domain tells them).
    expect(
      kAccountSyncScanEvery,
      greaterThanOrEqualTo(const Duration(minutes: 15)),
    );
  });
}
