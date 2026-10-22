import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

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
    test('is off for a new state', () async {
      expect(RelayState().shareWithGroups, isFalse);
      expect(RelayState.fromJsonString('{}').shareWithGroups, isFalse);
      expect(
        (await FileRelayStateStore(store: binary).load()).shareWithGroups,
        isFalse,
      );
      expect(const RelayOverview().shareWithGroups, isFalse);
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

  group('outbox payloads', () {
    RelayOutboxEntry entry(String rid, String text) => RelayOutboxEntry(
      rid: rid,
      recipient: 'p',
      payload: <String, dynamic>{'type': 'message', 'text': text},
      createdAtMillis: 1,
      expiresAtMillis: 2,
      relayable: false,
    );

    test('a big one lives in a file of its own, written once and removed '
        'with its entry', () async {
      final FileRelayStateStore store = FileRelayStateStore(store: binary);
      final String big = 'x' * (kRelayInlinePayloadChars + 10);
      final RelayState state = RelayState(
        outbox: <String, RelayOutboxEntry>{
          'small': entry('small', 'hej'),
          'big': entry('big', big),
        },
      );
      await store.save(state);
      final String core = utf8.decode((await binary.read('relay/state'))!);
      expect(core, contains('hej'));
      expect(core, isNot(contains('xxxxxxxxxx')));

      final RelayState loaded = await FileRelayStateStore(store: binary).load();
      expect(loaded.outbox['big']!.payload['text'], big);
      expect(loaded.outbox['small']!.payload['text'], 'hej');

      state.outbox.remove('big');
      await store.save(state);
      final RelayState after = await FileRelayStateStore(store: binary).load();
      expect(after.outbox.keys, <String>['small']);
      final List<String> files = <String>[];
      await for (final FileSystemEntity e in tempDir.list(recursive: true)) {
        if (e is File && e.path.contains('${Platform.pathSeparator}out')) {
          files.add(e.path);
        }
      }
      expect(
        files.where((String f) => f.endsWith('.zenbin')),
        isEmpty,
        reason: 'the payload file went with its entry',
      );
    });

    test('the queue refuses a big message once it holds too much', () async {
      final RelayEngine engine = RelayEngine(
        store: MemoryRelayStateStore(),
        peers: _OnePeer(),
        send: (String to, Map<String, dynamic> payload) async {},
        clock: () => 1000000,
      );
      await engine.activate();
      final String chunk = 'y' * (4 * 1024 * 1024);
      Object? refused;
      for (int i = 0; i < 12 && refused == null; i++) {
        try {
          await engine.submit(_peer, <String, dynamic>{
            'type': 'message',
            'msgId': 'm$i',
            'text': chunk,
          });
        } on RelayOutboxFullException catch (error) {
          refused = error;
        }
      }
      expect(refused, isA<RelayOutboxFullException>());
      // Small frames (receipts) still go.
      await engine.submit(_peer, <String, dynamic>{
        'type': 'message',
        'msgId': 'small',
        'text': 'ok',
      });
    });
  });

  test('a newer build\'s state is kept as it is, not started afresh', () async {
    addTearDown(ZenFormatGuard.instance.reset);
    final Uint8List newer = Uint8List.fromList(
      utf8.encode(jsonEncode(<String, Object>{'v': 99, 'id': 'kept'})),
    );
    await binary.write('relay/state', newer);
    final FileRelayStateStore store = FileRelayStateStore(store: binary);
    await expectLater(store.load(), throwsA(isA<NewerFormatException>()));
    expect(binary.isHeldNewer('relay/state'), isTrue);
    await store.save(RelayState());
    expect(await binary.read('relay/state'), newer);
    expect(ZenFormatGuard.instance.newerAreas, contains('relay'));
  });

  test('a corrupt file starts fresh instead of failing', () async {
    await binary.write('relay/state', Uint8List.fromList('{nope'.codeUnits));
    final RelayState state = await FileRelayStateStore(store: binary).load();
    expect(state.outbox, isEmpty);
  });
}

final String _peer = PeerShareCodec.normalizeAddress('200::b');

final class _OnePeer implements RelayPeerSource {
  @override
  bool get isReady => true;

  @override
  String get localAddress => PeerShareCodec.normalizeAddress('200::a');

  @override
  List<RelayFriend> acceptedFriends() => <RelayFriend>[
    RelayFriend(address: _peer),
  ];

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
