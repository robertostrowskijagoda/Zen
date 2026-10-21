import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Transports wired by address; every frame carries the post-quantum
/// device key of the session it came over, as the bridge reports it.
final class _Mesh {
  final Map<String, _Transport> nodes = <String, _Transport>{};

  /// The device key each address's sessions are sealed with.
  final Map<String, String> sessionKeys = <String, String>{};

  _Transport add(String address) => nodes[address] = _Transport(this, address);
}

final class _Transport extends MemorySignalTransport {
  _Transport(this.mesh, this.address);

  final _Mesh mesh;
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Transport? target =
        mesh.nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target == null) {
      return;
    }
    final String? key = mesh.sessionKeys[address];
    scheduleMicrotask(
      () => target.injectIncoming(
        from: address,
        payload: payload,
        senderKey: key,
      ),
    );
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final String ada = PeerShareCodec.normalizeAddress('200::a');
final String bob = PeerShareCodec.normalizeAddress('200::b');
final String keyA = 'a1' * 32;
final String keyB = 'b2' * 32;
final String impostorKey = 'ee' * 32;

final class _Pins {
  final List<(Map<String, String>, bool)> calls =
      <(Map<String, String>, bool)>[];
  final List<String> warnings = <String>[];

  void pin(Map<String, String> keys, {bool force = false}) =>
      calls.add((Map<String, String>.of(keys), force));
}

void main() {
  late _Mesh mesh;

  setUp(() => mesh = _Mesh());

  Future<(LedgerNode, _Pins)> node(
    String address,
    String sessionKey,
    List<String> friends,
  ) async {
    final _Transport transport = mesh.add(address);
    mesh.sessionKeys[address] = sessionKey;
    await transport.start();
    final _Pins pins = _Pins();
    final LedgerNode n =
        LedgerNode(
            transport: transport,
            disk: MemoryLedgerDisk(),
            friendAddresses: () => friends,
            localAddress: () => address,
            localSessionKey: () => sessionKey,
          )
          ..onSessionKeys = pins.pin
          ..onDeviceKeyMismatch = pins.warnings.add;
    addTearDown(n.stop);
    return (n, pins);
  }

  test(
    'the hello binds the address to the device key of its session',
    () async {
      final (LedgerNode a, _Pins aPins) = await node(ada, keyA, <String>[bob]);
      final (LedgerNode b, _Pins _) = await node(bob, keyB, <String>[ada]);
      await a.start();
      await b.start();
      await _settle();

      expect(a.accountOf(bob), b.account);
      expect(b.accountOf(ada), a.account);
      expect(a.sessionKeyOf(bob), keyB);
      expect(b.sessionKeyOf(ada), keyA);
      expect(
        aPins.calls.any(
          ((Map<String, String>, bool) c) => c.$1[bob] == keyB && !c.$2,
        ),
        isTrue,
        reason: 'a proven key is pinned in the bridge',
      );
      expect(aPins.warnings, isEmpty);

      // The device record names the key, so friends pin it before any
      // contact with the address it names.
      final LogEntry record = a
          .entriesOf(spaceKind: 'acts')
          .lastWhere((LogEntry e) => e.kind == kDeviceRecordKind);
      expect(record.body['address'], ada);
      expect(record.body['pq'], keyA);
    },
  );

  test('a hello over another device key is refused and warned about', () async {
    final (LedgerNode a, _Pins aPins) = await node(ada, keyA, <String>[bob]);
    final (LedgerNode b, _Pins _) = await node(bob, keyB, <String>[ada]);
    await a.start();
    await b.start();
    await _settle();
    expect(a.accountOf(bob), b.account);
    aPins.calls.clear();

    // Someone with bob's broken node key runs a session of their own and
    // replays (or relays) bob's genuine, signed hello through it.
    mesh.sessionKeys[bob] = impostorKey;
    b.greet(ada);
    await _settle();

    expect(aPins.warnings, contains(bob));
    expect(
      aPins.calls.any(
        ((Map<String, String>, bool) c) => c.$1[bob] == keyB && c.$2,
      ),
      isTrue,
      reason: 'bob signed keyB: it replaces the impostor session\'s pin',
    );
    expect(
      aPins.calls.any(
        ((Map<String, String>, bool) c) => c.$1[bob] == impostorKey,
      ),
      isFalse,
    );
    expect(a.sessionKeyOf(bob), keyB);

    // One warning an hour, however often it comes.
    b.greet(ada);
    await _settle();
    expect(aPins.warnings.where((String w) => w == bob), hasLength(1));
  });

  test('a hello that came without a session (a mailbox) still binds', () async {
    final (LedgerNode a, _Pins aPins) = await node(ada, keyA, <String>[bob]);
    final (LedgerNode b, _Pins _) = await node(bob, keyB, <String>[ada]);
    // Frames from bob arrive without the bridge's session key.
    mesh.sessionKeys.remove(bob);
    await a.start();
    await b.start();
    await _settle();
    expect(a.accountOf(bob), b.account);
    expect(a.sessionKeyOf(bob), keyB, reason: 'the signed key itself');
    expect(aPins.warnings, isEmpty);
  });
}
