import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';

void main() {
  late Directory tempDir;
  late FileBinaryStore binary;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zen-relay-store-');
    binary = FileBinaryStore(
      tempDir,
      codec: BinaryCodec(compressor: const _PassThroughCompressor()),
    );
  });

  tearDown(() => tempDir.delete(recursive: true));

  test('round-trips identity, directory, outbox and held mail', () async {
    final RelayIdentity identity = await RelayIdentity.generate();
    final RelayState state = RelayState(
      identity: identity,
      peers: <String, RelayPeerInfo>{
        'p': RelayPeerInfo(
          address: 'p',
          publicKey: identity.publicKey,
          relays: const <String>['r1', 'r2'],
          version: 3,
        ),
      },
      manualRelays: <String>['r1'],
      currentRelays: <String>['r1'],
      relaySetVersion: 7,
      outbox: <String, RelayOutboxEntry>{
        'id1': const RelayOutboxEntry(
          rid: 'id1',
          recipient: 'p',
          payload: <String, dynamic>{'type': 'message', 'text': 'x'},
          createdAtMillis: 1,
          expiresAtMillis: 2,
          relayable: true,
          depositedTo: <String>['r1'],
        ),
      },
      mailbox: <String, Map<String, Map<String, dynamic>>>{
        'friend': <String, Map<String, dynamic>>{
          'e1': <String, dynamic>{'id': 'e1', 'b': 'AAAA'},
        },
      },
      tombstones: <String, int>{'friend|e0': 99},
      seen: <String, int>{'p|id0': 99},
    );

    await FileRelayStateStore(store: binary).save(state);
    final RelayState loaded = await FileRelayStateStore(store: binary).load();

    expect(loaded.identity!.publicKey, identity.publicKey);
    expect(loaded.identity!.privateKey, identity.privateKey);
    expect(loaded.peers['p']!.relays, <String>['r1', 'r2']);
    expect(loaded.peers['p']!.version, 3);
    expect(loaded.manualRelays, <String>['r1']);
    expect(loaded.relaySetVersion, 7);
    expect(loaded.outbox['id1']!.depositedTo, <String>['r1']);
    expect(loaded.mailbox['friend']!['e1']!['b'], 'AAAA');
    expect(loaded.tombstones, <String, int>{'friend|e0': 99});
    expect(loaded.seen, <String, int>{'p|id0': 99});
  });

  test('held mail lives in its own document and is removed with it', () async {
    final FileRelayStateStore store = FileRelayStateStore(store: binary);
    final RelayState state = RelayState(
      mailbox: <String, Map<String, Map<String, dynamic>>>{
        'friend': <String, Map<String, dynamic>>{
          'e1': <String, dynamic>{'id': 'e1'},
        },
      },
    );
    await store.save(state);
    final Uint8List? core = await binary.read('relay/state');
    expect(String.fromCharCodes(core!), isNot(contains('"e1"')));

    state.mailbox.clear();
    await store.save(state);
    expect((await FileRelayStateStore(store: binary).load()).mailbox, isEmpty);
  });

  test('a corrupt file starts fresh instead of failing', () async {
    await binary.write('relay/state', Uint8List.fromList('{nope'.codeUnits));
    final RelayState state = await FileRelayStateStore(store: binary).load();
    expect(state.outbox, isEmpty);
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
