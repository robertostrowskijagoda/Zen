import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
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

  group('sharing mailboxes with group members', () {
    Future<void> writeRaw(Object document) => binary.write(
      'relay/state',
      Uint8List.fromList(jsonEncode(document).codeUnits),
    );

    test('is off for a new state', () async {
      expect(RelayState().shareWithGroups, isFalse);
      expect(RelayState.fromJsonString('{}').shareWithGroups, isFalse);
      expect(
        (await FileRelayStateStore(store: binary).load()).shareWithGroups,
        isFalse,
      );
      expect(const RelayOverview().shareWithGroups, isFalse);
    });

    test('a state stored before the settings version is switched off, '
        'whatever it held', () async {
      for (final Object? stored in <Object?>[true, false, null]) {
        final RelayState loaded = RelayState.fromJsonString(
          jsonEncode(<String, dynamic>{'v': 1, 'swg': ?stored}),
        );
        expect(loaded.shareWithGroups, isFalse, reason: 'swg: $stored');
      }
    });

    test('the migration runs once: the next save records the version and '
        'the person\'s later choice sticks', () async {
      await writeRaw(<String, dynamic>{
        'v': 1,
        'swg': true,
        'peers': <Object>[],
        'cur': <String>['r1'],
        'ver': 4,
      });
      final FileRelayStateStore store = FileRelayStateStore(store: binary);

      RelayState state = await store.load();
      expect(state.shareWithGroups, isFalse);
      expect(state.relaySetVersion, 4, reason: 'nothing else is touched');
      expect(state.currentRelays, <String>['r1']);
      await store.save(state);

      final Uint8List? written = await binary.read('relay/state');
      expect(
        (jsonDecode(utf8.decode(written!)) as Map<String, dynamic>)['sv'],
        kRelaySettingsVersion,
      );
      state = await FileRelayStateStore(store: binary).load();
      expect(state.shareWithGroups, isFalse);

      // Opting in again is kept across restarts…
      state.shareWithGroups = true;
      await store.save(state);
      state = await FileRelayStateStore(store: binary).load();
      expect(state.shareWithGroups, isTrue);

      // …and so is opting out.
      state.shareWithGroups = false;
      await store.save(state);
      state = await FileRelayStateStore(store: binary).load();
      expect(state.shareWithGroups, isFalse);
    });

    test('a deliberate choice written by this version round-trips', () {
      final RelayState on = RelayState.fromJsonString(
        RelayState(shareWithGroups: true).toJsonString(),
      );
      expect(on.shareWithGroups, isTrue);
      final RelayState off = RelayState.fromJsonString(
        RelayState().toJsonString(),
      );
      expect(off.shareWithGroups, isFalse);
    });
  });

  group('delivery reports', () {
    test('are stored with the state and read back in order', () async {
      final RelayState state = RelayState(
        deliveryReports: <RelayDeliveryReport>[
          const RelayDeliveryReport(
            rid: 'r1',
            recipient: 'p',
            messageId: 'm1',
            status: RelayDeliveryStatus.directOnly,
            atMillis: 10,
          ),
          const RelayDeliveryReport(
            rid: 'r2',
            recipient: 'q',
            messageId: 'm2',
            status: RelayDeliveryStatus.expired,
            atMillis: 20,
          ),
        ],
      );
      await FileRelayStateStore(store: binary).save(state);
      final RelayState loaded = await FileRelayStateStore(store: binary).load();

      expect(
        loaded.deliveryReports
            .map((RelayDeliveryReport r) => r.toJson())
            .toList(),
        state.deliveryReports
            .map((RelayDeliveryReport r) => r.toJson())
            .toList(),
      );
      expect(loaded.deliveryReports.last.status, RelayDeliveryStatus.expired);
      expect(loaded.deliveryReports.last.messageId, 'm2');
      expect(loaded.deliveryReports.last.recipient, 'q');
    });

    test('a state without reports, or with garbage in their place, loads', () {
      expect(RelayState.fromJsonString('{"v":1}').deliveryReports, isEmpty);
      expect(
        RelayState.fromJsonString('{"v":1,"rep":"nope"}').deliveryReports,
        isEmpty,
      );
      final RelayState state = RelayState.fromJsonString(
        jsonEncode(<String, dynamic>{
          'v': 1,
          'rep': <Object?>[
            7,
            <String, dynamic>{'rid': 'a', 'to': 'p', 'mid': 'm', 's': 'gone'},
            <String, dynamic>{'rid': '', 'to': 'p', 'mid': 'm', 's': 'expired'},
            <String, dynamic>{
              'rid': 'b',
              'to': 'p',
              'mid': 'm',
              's': 'expired',
            },
          ],
        }),
      );
      expect(
        state.deliveryReports.map((RelayDeliveryReport r) => r.rid).toList(),
        <String>['b'],
      );
      expect(state.deliveryReports.single.atMillis, 0);
    });
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
