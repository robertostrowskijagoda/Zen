import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/quiet_timer.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_hosting.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Entry kind of the "Kamyczki" part of a profile, in the account's
/// `profile` space, sealed for all friends ([Audience.all]): the cards of
/// the pebbles the account made and collected (with the date and the
/// finder's note). The newest entry wins; an older Zen ignores the kind.
const String kPebblesProfileKind = 'pebbles';

/// The most bytes the part's body takes before sealing (the oldest
/// collected pebbles are left out first, then the oldest made ones).
const int kPebblesProfileMaxBytes = 40 * 1024;

/// One pebble in someone's "Kamyczki".
@immutable
final class PebbleProfileItem {
  const PebbleProfileItem({
    required this.card,
    this.foundAtMillis,
    this.findNote = '',
  });

  final PebbleCard card;
  final int? foundAtMillis;
  final String findNote;
}

/// Someone's "Kamyczki" as their friends see it.
@immutable
final class PebbleProfile {
  const PebbleProfile({
    required this.created,
    required this.collected,
    this.removed = const <PebbleId, int>{},
  });

  final List<PebbleProfileItem> created;
  final List<PebbleProfileItem> collected;

  /// Pebbles removed on one of the account's devices (its other devices
  /// drop them too).
  final Map<PebbleId, int> removed;

  bool get isEmpty => created.isEmpty && collected.isEmpty;
}

/// The body of the "Kamyczki" part for [created] and [collected] (newest
/// first), within [kPebblesProfileMaxBytes].
Map<String, dynamic> pebbleProfileBody({
  required List<PebbleEntry> created,
  required List<PebbleEntry> collected,
  Map<PebbleId, int> removed = const <PebbleId, int>{},
}) {
  List<Map<String, dynamic>> items(List<PebbleEntry> list, bool found) =>
      <Map<String, dynamic>>[
        for (final PebbleEntry e in list)
          <String, dynamic>{
            'c': e.card.text,
            if (found && e.foundAtMillis != null) 'f': e.foundAtMillis,
            if (found && e.findNote.isNotEmpty) 'n': e.findNote,
          },
      ];
  final List<Map<String, dynamic>> made = items(created, false);
  final List<Map<String, dynamic>> found = items(collected, true);
  Map<String, dynamic> body() => <String, dynamic>{
    'v': 1,
    'c': made,
    'k': found,
    if (removed.isNotEmpty)
      'x': <String, int>{
        for (final MapEntry<PebbleId, int> r in removed.entries)
          r.key.text: r.value,
      },
  };
  while (utf8.encode(jsonEncode(body())).length > kPebblesProfileMaxBytes &&
      (found.isNotEmpty || made.isNotEmpty)) {
    if (found.isNotEmpty) {
      found.removeLast();
    } else {
      made.removeLast();
    }
  }
  return body();
}

/// The "Kamyczki" part in [body] (cards are checked: [verifyPebbleProfile]).
PebbleProfile? pebbleProfileFromBody(Map<String, dynamic>? body) {
  if (body == null) {
    return null;
  }
  List<PebbleProfileItem> items(Object? raw) => <PebbleProfileItem>[
    if (raw is List)
      for (final Object? i in raw.take(1000))
        if (i is Map && i['c'] is String)
          if (PebbleCard.fromText(i['c'] as String) case final PebbleCard card)
            PebbleProfileItem(
              card: card,
              foundAtMillis: i['f'] is int ? i['f'] as int : null,
              findNote: i['n'] is String ? clipFindNote(i['n'] as String) : '',
            ),
  ];
  final Object? x = body['x'];
  return PebbleProfile(
    created: items(body['c']),
    collected: items(body['k']),
    removed: <PebbleId, int>{
      if (x is Map)
        for (final MapEntry<Object?, Object?> e in x.entries)
          if (PebbleId.parse(e.key) case final PebbleId id)
            if (e.value is int) id: e.value! as int,
    },
  );
}

/// [profile] with only the cards whose signatures hold, and made ones only
/// when [account] signed them.
Future<PebbleProfile> verifyPebbleProfile(
  PebbleProfile profile,
  String account,
) async {
  Future<List<PebbleProfileItem>> keep(
    List<PebbleProfileItem> list, {
    required bool own,
  }) async => <PebbleProfileItem>[
    for (final PebbleProfileItem i in list)
      if ((!own || i.card.authorAccount == account) && await i.card.verify()) i,
  ];
  return PebbleProfile(
    created: await keep(profile.created, own: true),
    collected: await keep(profile.collected, own: false),
    removed: profile.removed,
  );
}

LogEntry? _latestPebblesEntry(LedgerNode node, String account) {
  LogEntry? best;
  for (final LogEntry e in node.entriesOf(
    spaceKind: 'profile',
    ofAccount: account,
  )) {
    if (e.kind == kPebblesProfileKind && (best == null || e.hlc > best.hlc)) {
      best = e;
    }
  }
  return best;
}

/// The newest "Kamyczki" of [account] this device can open (a friend's,
/// or the account's own from its other devices); `null` when there is
/// none or it is sealed for others.
PebbleProfile? readPebbleProfile(LedgerNode node, String account) {
  if (!node.isReady) {
    return null;
  }
  final LogEntry? e = _latestPebblesEntry(node, account);
  return e == null ? null : pebbleProfileFromBody(node.bodyOf(e));
}

/// The pebbles of this account: its store, the hosting protocol, and the
/// "Kamyczki" part of the profile (written when the collection changes,
/// taken in from the account's other devices).
final class PebbleService {
  PebbleService({required this.store, required this.hosting, this.node});

  final PebbleStore store;
  final PebbleHosting hosting;
  final LedgerNode? node;

  static const String _profileHashKey = 'pebbles/profile_hash';

  QuietTimer? _profileTimer;
  StreamSubscription<LogEntry>? _added;
  bool _publishing = false;

  Future<void> start() async {
    await hosting.start();
    final LedgerNode? n = node;
    if (n == null) {
      return;
    }
    _profileTimer = QuietTimer(
      quiet: const Duration(seconds: 20),
      atMost: const Duration(minutes: 2),
      action: () => unawaitedLogged(
        publishProfile(),
        context: 'Saving the pebbles in the profile failed',
      ),
    );
    store.addListener(_profileTimer!.nudge);
    await n.start();
    _added = n.store.added.listen((LogEntry e) {
      if (e.kind == kPebblesProfileKind && e.account == n.account) {
        unawaitedLogged(
          takeFromOtherDevices(),
          context: 'Taking pebbles from another device failed',
        );
      }
    });
    await takeFromOtherDevices();
  }

  Future<void> stop() async {
    final QuietTimer? timer = _profileTimer;
    if (timer != null) {
      store.removeListener(timer.nudge);
      timer.cancel();
    }
    await _added?.cancel();
    await hosting.stop();
  }

  /// The account's own pebbles saved on its other devices come here too
  /// (their designs follow from those devices); removals there apply here.
  Future<void> takeFromOtherDevices() async {
    final LedgerNode? n = node;
    if (n == null || !n.isReady) {
      return;
    }
    final PebbleProfile? own = readPebbleProfile(n, n.account);
    if (own == null) {
      return;
    }
    await store.applyRemovals(own.removed);
    final PebbleProfile checked = await verifyPebbleProfile(own, n.account);
    for (final PebbleProfileItem i in checked.created) {
      if (store.entry(i.card.id) == null &&
          !store.removed.containsKey(i.card.id)) {
        await store.addFromOtherDevice(i.card);
      }
    }
    for (final PebbleProfileItem i in checked.collected) {
      if (!(store.entry(i.card.id)?.collected ?? false) &&
          !store.removed.containsKey(i.card.id)) {
        await store.addCollected(
          i.card,
          findNote: i.findNote,
          foundAtMillis: i.foundAtMillis,
        );
      }
    }
  }

  /// Writes the "Kamyczki" part when it changed.
  Future<bool> publishProfile() async {
    final LedgerNode? n = node;
    if (n == null || _publishing) {
      return false;
    }
    _publishing = true;
    try {
      await n.start();
      final Map<String, dynamic> body = pebbleProfileBody(
        created: store.created,
        collected: store.collected,
        removed: store.removed,
      );
      final LogEntry? previous = _latestPebblesEntry(n, n.account);
      if (previous == null &&
          store.created.isEmpty &&
          store.collected.isEmpty) {
        return false;
      }
      final String hash = sha256Hex(utf8.encode(canonicalJson(body)));
      if (previous != null) {
        final Map<String, dynamic>? open = n.bodyOf(previous);
        if (open != null) {
          if (canonicalJson(open) == canonicalJson(body)) {
            return false;
          }
        } else {
          // Not opened yet: what this device wrote last time.
          final Uint8List? saved = await n.disk.read(_profileHashKey);
          if (saved != null && utf8.decode(saved) == '${previous.id}|$hash') {
            return false;
          }
        }
      }
      final LogEntry written = await n.publish(
        kPebblesProfileKind,
        await n.seal(Audience.all, body),
        spaceKind: 'profile',
      );
      await n.disk.write(
        _profileHashKey,
        Uint8List.fromList(utf8.encode('${written.id}|$hash')),
      );
      return true;
    } finally {
      _publishing = false;
    }
  }

  /// Collects the pebble of [card] (after its signature is checked): saved
  /// at once, the full design looked for in the background, the author told
  /// it was found.
  Future<PebbleCollectResult> collect(
    PebbleCard card, {
    String findNote = '',
  }) async {
    if (!await card.verify()) {
      return PebbleCollectResult.invalid;
    }
    await store.load();
    final PebbleEntry? had = store.entry(card.id);
    if (had != null && had.created) {
      return PebbleCollectResult.own;
    }
    if (had != null && had.collected) {
      return PebbleCollectResult.already;
    }
    final PebbleEntry? e = await store.addCollected(card, findNote: findNote);
    if (e == null) {
      return PebbleCollectResult.full;
    }
    unawaitedLogged(hosting.want(card.id), context: 'Fetching a pebble');
    unawaitedLogged(hosting.sendFound(card.id), context: 'Pebble found note');
    return PebbleCollectResult.collected;
  }

  /// Makes, signs and publishes a pebble of [design]; keepers are drawn.
  /// Throws [StateError] while the account key is locked.
  Future<PebbleEntry> create({
    required LedgerKeyPair key,
    required Uint8List design,
    required PebbleCardLook look,
    required Uint8List? thumbnail,
    required String name,
    required String note,
    required String authorName,
    DateTime? at,
  }) async {
    final PebbleCard card = await PebbleCard.sign(
      key: key,
      design: design,
      createdSeconds: (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
      look: look,
      name: name,
      note: note,
      authorName: authorName,
      thumbnail: thumbnail,
    );
    return hosting.publish(card, design);
  }
}

/// What collecting a card ended in.
enum PebbleCollectResult {
  /// Saved; the full design comes in the background.
  collected,

  /// It is in the collection already.
  already,

  /// This account made it.
  own,

  /// The signature does not hold: not saved.
  invalid,

  /// The collection is full.
  full,
}

/// The people around this device, as the pebbles need them: friends and
/// blocked people from the friendship book, accounts and devices from the
/// ledger's directory, keeper candidates from the mailboxes' measures.
final class AppPebblePeers implements PebblePeers {
  AppPebblePeers(this.ref);

  final Ref ref;

  SocialHubState get _social => ref.read(socialHubControllerProvider);

  AccountDeviceDirectory? get _directory =>
      ref.read(accountDirectoryHolderProvider).directory;

  @override
  List<String> friends() => acceptedFriendAddresses(_social);

  @override
  bool isFriend(String address) =>
      _social.friendByAddress(address)?.status ==
      FriendRelationshipStatus.accepted;

  @override
  bool isBlocked(String address) =>
      _social.friendByAddress(address)?.status ==
      FriendRelationshipStatus.blocked;

  @override
  String? accountOf(String address) => _directory?.accountOf(address);

  @override
  List<String> addressesOfAccount(String account) {
    final AccountDeviceDirectory? d = _directory;
    if (d == null) {
      return const <String>[];
    }
    final String? contact = d.contactAddressOf(account);
    final bool own = account == d.ownAccount;
    if (contact == null && !own) {
      return const <String>[];
    }
    return <String>{
      ?contact,
      ...d.addressesOf(account),
    }.map(PeerShareCodec.normalizeAddress).where((String a) {
      return d.unlinkedAccountOf(a) == null;
    }).toList();
  }

  @override
  List<PebbleKeeperCandidate> keeperCandidates() {
    final RelayEngine? engine = ref.read(relayEngineProvider);
    final Map<String, RelayMailboxCandidate> seen =
        engine?.overview.value.candidates ??
        const <String, RelayMailboxCandidate>{};
    return <PebbleKeeperCandidate>[
      for (final String f in friends())
        if (seen[PeerShareCodec.normalizeAddress(f)] case final c?)
          PebbleKeeperCandidate(
            address: c.device.isEmpty ? f : c.device,
            desktop: c.deviceClass == RelayDeviceClass.desktop,
            quality: c.quality,
          )
        else
          PebbleKeeperCandidate(address: f),
    ];
  }
}

/// The pebbles of this account, or `null` while the ledger is off (tests,
/// previews). Reading it starts it.
final Provider<PebbleService?> pebbleServiceProvider = Provider<PebbleService?>(
  (Ref ref) {
    final LedgerNode? node = ref.watch(ledgerNodeProvider);
    if (node == null) {
      return null;
    }
    final PebbleStore store = PebbleStore(ref.read(ledgerDiskProvider));
    final PebbleHosting hosting = PebbleHosting(
      transport: ref.read(meshTransportProvider),
      store: store,
      peers: AppPebblePeers(ref),
      accountKey: () => node.isReady ? node.identity.accountKey : null,
      serveCollected: () =>
          ref.read(appSettingsControllerProvider).servePebbles,
    );
    hosting.onKeepRequest = (PebbleKeepRequest request) {
      final FriendProfile? friend = ref
          .read(socialHubControllerProvider)
          .friendByAddress(request.from);
      final String who = friend == null
          ? request.card.authorName
          : ref.read(socialHubControllerProvider).nameFor(friend);
      unawaitedLogged(
        ref
            .read(runtimeSystemNotificationServiceProvider)
            .show(
              RuntimeSystemNotification(
                id: 'pebble-keep-${request.card.id.text}',
                title: t('Prośba o przechowanie kamyczka'),
                body: pebbleKeepQuestion(who, request),
                createdAtMillis: DateTime.now().millisecondsSinceEpoch,
                category: RuntimeSystemNotificationCategory.social,
                routeKey: buildPebblesRouteKey(),
                slotKey: 'pebble-keep',
                kind: NoticeKind.invitation,
              ),
            ),
        context: 'Notification about keeping a pebble',
      );
    };
    final PebbleService service = PebbleService(
      store: store,
      hosting: hosting,
      node: node,
    );
    unawaitedLogged(
      node.start().then((_) => service.start()),
      context: 'Starting the pebbles failed',
    );
    // Designs still missing, keepers who did not answer: on the wake beat.
    final BeatTimer beat = ZenWake.beat(
      'pebbles',
      const Duration(minutes: 15),
      hosting.tick,
    );
    ref.onDispose(() {
      beat.cancel();
      unawaitedLogged(service.stop(), context: 'Stopping the pebbles');
    });
    return service;
  },
);

/// The keepers' consent question: "{autor} prosi, żebyś przechowywał(a)
/// jego kamyczek „{nazwa}”. Zajmuje {n} KB. Zgadzasz się?"
String pebbleKeepQuestion(String who, PebbleKeepRequest request) => t(
  '{author} prosi, żebyś przechowywał(a) jego kamyczek „{name}”. '
  'Zajmuje {n} KB. Zgadzasz się?',
  <String, Object?>{
    'author': who,
    'name': request.card.name,
    'n': (request.sizeBytes + 1023) ~/ 1024,
  },
);
