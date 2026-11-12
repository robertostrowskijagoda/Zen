import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/block_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// A block made in one feature holds in the others: pebbles and
/// introductions take nothing from the person, encounters with them are not
/// shown; lifting the block brings them back.

final String _eve = PeerShareCodec.normalizeAddress('200::e1');
final String _ola = PeerShareCodec.normalizeAddress('200::0a');

final Provider<AppPebblePeers> _pebbles = Provider<AppPebblePeers>(
  AppPebblePeers.new,
);
final Provider<AppIntroFriending> _intros = Provider<AppIntroFriending>(
  AppIntroFriending.new,
);

void main() {
  late Directory dir;
  late ProviderContainer container;
  late MemorySignalTransport transport;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('zen-blocked-everywhere-');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Still open on Windows.
      }
    });
    transport = MemorySignalTransport();
    await transport.start();
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(container.dispose);
    await container.read(socialHubControllerProvider.notifier).whenHydrated;
  });

  SocialHubController hub() =>
      container.read(socialHubControllerProvider.notifier);

  test('pebbles and introductions refuse a person blocked in Dating or "W '
      'pobliżu"; unblocked, they are let in', () async {
    final AppPebblePeers pebbles = container.read(_pebbles);
    final AppIntroFriending intros = container.read(_intros);
    expect(pebbles.isBlocked(_eve), isFalse);
    expect(intros.isBlocked(_eve), isFalse);

    // Blocked from her dating profile (her address known), and Ola nearby.
    await hub().blockPerson(
      address: _eve,
      datingKey: 'K-eve',
      name: 'Eve',
      origin: BlockOrigin.dating,
    );
    await hub().blockPerson(
      address: _ola,
      name: 'Zielona Sowa',
      origin: BlockOrigin.nearby,
    );
    for (final String a in <String>[_eve, _ola]) {
      expect(pebbles.isBlocked(a), isTrue, reason: a);
      expect(intros.isBlocked(a), isTrue, reason: a);
    }

    // "Odblokuj wszystkich" nearby lifts only what was blocked there.
    await hub().unblockAllFrom(BlockOrigin.nearby);
    expect(pebbles.isBlocked(_ola), isFalse);
    expect(intros.isBlocked(_ola), isFalse);
    expect(pebbles.isBlocked(_eve), isTrue);

    await hub().unblockFriend(peerAddress: _eve);
    expect(pebbles.isBlocked(_eve), isFalse);
    expect(intros.isBlocked(_eve), isFalse);
  });

  test('encounters with someone blocked since are not shown; unblocked, they '
      'are', () async {
    final EncounterLog log = EncounterLog(
      disk: MemoryLedgerDisk(),
      now: () => 1000000,
    );
    addTearDown(log.dispose);
    log.saw(token: 't-1', at: 1000000, friend: _eve);
    expect(log.encounters.single.friend, _eve);
    final Set<String> blocked = <String>{_eve};
    log.leaveOut = blocked.contains;
    expect(log.encounters, isEmpty);
    blocked.clear();
    expect(log.encounters.single.friend, _eve);
  });
}
