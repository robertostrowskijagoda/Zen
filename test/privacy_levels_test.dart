import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/recovery_circle_pick.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/friend_level_lookup.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Levels of acquaintance: what a weak acquaintance
/// gets, who may invite to groups, who keeps the mailboxes and recovery
/// pieces.
final String weak = PeerShareCodec.normalizeAddress('200::a1');
final String mid = PeerShareCodec.normalizeAddress('200::b2');
final String close = PeerShareCodec.normalizeAddress('200::c3');
final String stranger = PeerShareCodec.normalizeAddress('200::d4');

final class _Host implements MeetHost {
  _Host(this.friendList, {this.close = const <String>[]});

  final List<String> friendList;
  final List<String> close;
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

  /// The last payload of [type] sent to [to].
  Map<String, dynamic>? last(String to, String type) {
    for (final (String, Map<String, dynamic>) s in sent.reversed) {
      if (s.$1 == to && s.$2['type'] == type) {
        return s.$2;
      }
    }
    return null;
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async =>
      sent.add((to, payload));

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => close;

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  bool isSelf(String a) => false;

  @override
  String nameOf(String a) => a;

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

final class _Peers implements RelayPeerSource {
  _Peers(this.list);

  final List<RelayFriend> list;

  @override
  bool get isReady => true;

  @override
  String get localAddress => PeerShareCodec.normalizeAddress('200::ff');

  @override
  List<RelayFriend> acceptedFriends() => list;

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];
}

void main() {
  final Map<String, FriendLevel> levels = <String, FriendLevel>{};
  FriendLevel levelOf(String a) => levels[a] ?? FriendLevel.friend;

  setUp(() {
    levels
      ..clear()
      ..[weak] = FriendLevel.weak
      ..[mid] = FriendLevel.friend
      ..[close] = FriendLevel.close;
  });

  (MeetService, _Host) meet() {
    final _Host host = _Host(
      <String>[weak, mid, close],
      close: <String>[close],
    );
    final MeetService service = MeetService(
      host: host,
      store: MeetStore(MemoryLedgerDisk()),
      now: () => 1000,
    );
    service
      ..levelOf = levelOf
      ..friendNames = () => <String, String>{
        weak: 'Wiesia',
        mid: 'Marek',
        close: 'Celina',
      };
    return (service, host);
  }

  group('friend list', () {
    test('by default weak acquaintances get an empty list', () async {
      final (MeetService service, _Host host) = meet();
      expect(service.book.friendListAudience, FriendListAudience.friends);
      await service.shareFriendList(service.friendNames!());

      final Map<String, dynamic> toWeak = host.last(
        weak,
        MeetTypes.friendList,
      )!;
      expect(toWeak['l'], isEmpty);
      expect(toWeak['d'], MeetService.emptyFriendListDigest);
      expect(host.last(mid, MeetTypes.friendList)!['l'], isNotEmpty);
      expect(host.last(close, MeetTypes.friendList)!['l'], isNotEmpty);
      expect(service.friendListVisibleTo(weak), isFalse);
      expect(service.friendListVisibleTo(mid), isTrue);
    });

    test('a weak acquaintance let in, or "Wszyscy znajomi", sees it', () async {
      final (MeetService service, _Host host) = meet();
      await service.allowFriendList(weak, allow: true);
      expect(host.last(weak, MeetTypes.friendList)!['l'], isNotEmpty);

      await service.allowFriendList(weak, allow: false);
      expect(host.last(weak, MeetTypes.friendList)!['l'], isEmpty);

      await service.setFriendListAudience(FriendListAudience.all);
      await service.resendFriendList(weak);
      expect(host.last(weak, MeetTypes.friendList)!['l'], isNotEmpty);
    });

    test('a level going up sends the list and the status at once', () async {
      final (MeetService service, _Host host) = meet();
      await service.setMyIntent(
        const IntentStatus(kind: IntentKind.talk, setAt: 900),
      );
      expect(host.last(weak, MeetTypes.intent)!.containsKey('s'), isFalse);

      levels[weak] = FriendLevel.friend;
      await service.levelChanged(weak);
      expect(host.last(weak, MeetTypes.friendList)!['l'], isNotEmpty);
      expect(host.last(weak, MeetTypes.intent)!['s'], isNotNull);

      // And down again: the status is taken back.
      levels[weak] = FriendLevel.weak;
      await service.levelChanged(weak);
      expect(host.last(weak, MeetTypes.friendList)!['l'], isEmpty);
      expect(host.last(weak, MeetTypes.intent)!.containsKey('s'), isFalse);
    });

    test('the audience is kept by name; old books get the new default', () {
      final MeetBook all = MeetBook()
        ..friendListAudience = FriendListAudience.all;
      expect(
        MeetBook.fromJson(all.toJson()).friendListAudience,
        FriendListAudience.all,
      );
      final MeetBook friends = MeetBook();
      expect(
        MeetBook.fromJson(friends.toJson()).friendListAudience,
        FriendListAudience.friends,
      );
      expect(
        MeetBook.fromJson(<String, dynamic>{'v': 1}).friendListAudience,
        FriendListAudience.friends,
      );
      final MeetBook nobody = MeetBook()
        ..friendListAudience = FriendListAudience.nobody;
      expect(
        MeetBook.fromJson(nobody.toJson()).friendListAudience,
        FriendListAudience.nobody,
      );
    });
  });

  group('statuses', () {
    test('weak acquaintances see only "Nie przeszkadzać"', () async {
      final (MeetService service, _Host host) = meet();
      await service.setMyIntent(
        const IntentStatus(kind: IntentKind.walk, setAt: 900),
      );
      expect(host.last(weak, MeetTypes.intent)!.containsKey('s'), isFalse);
      expect(host.last(mid, MeetTypes.intent)!['s'], isNotNull);
      expect(service.helloFor(weak)['ms'], 0);
      expect(service.helloFor(mid)['ms'], 900);

      await service.setMyIntent(
        const IntentStatus(kind: IntentKind.dnd, setAt: 950),
      );
      expect(host.last(weak, MeetTypes.intent)!['s'], isNotNull);
      expect(service.helloFor(weak)['ms'], 950);
    });

    test('"tylko przyjaciele" still reaches only close friends', () async {
      final (MeetService service, _Host host) = meet();
      await service.setMyIntent(
        const IntentStatus(kind: IntentKind.out, setAt: 900, onlyClose: true),
      );
      expect(host.last(close, MeetTypes.intent)!['s'], isNotNull);
      expect(host.last(mid, MeetTypes.intent), isNull);
      expect(service.statusVisibleTo(service.book.myIntent!, mid), isFalse);
    });

    test('without levels known every friend counts as "Znajomy"', () {
      final (MeetService service, _) = meet();
      service.levelOf = null;
      expect(service.isWeak(weak), isFalse);
      expect(service.friendListVisibleTo(weak), isTrue);
    });
  });

  group('group invitations', () {
    test('the threshold by level', () {
      bool ok(GroupInviteFrom f, FriendLevel? l, {bool friend = true}) =>
          groupInviteAllowed(f, isFriend: friend, level: l);
      // The default: "Znajomy" and up.
      expect(const AppSettings().groupInviteFrom, GroupInviteFrom.friends);
      expect(ok(GroupInviteFrom.friends, FriendLevel.weak), isFalse);
      expect(ok(GroupInviteFrom.friends, FriendLevel.friend), isTrue);
      expect(ok(GroupInviteFrom.friends, null), isTrue);
      expect(ok(GroupInviteFrom.friends, null, friend: false), isFalse);
      expect(ok(GroupInviteFrom.allFriends, FriendLevel.weak), isTrue);
      expect(ok(GroupInviteFrom.allFriends, null, friend: false), isFalse);
      expect(ok(GroupInviteFrom.closeFriends, FriendLevel.friend), isFalse);
      expect(ok(GroupInviteFrom.closeFriends, FriendLevel.close), isTrue);
      expect(ok(GroupInviteFrom.everyone, null, friend: false), isTrue);
    });

    ProviderContainer hub({GroupInviteFrom from = GroupInviteFrom.friends}) {
      final FriendLevelLookup lookup = FriendLevelLookup()..levelOf = levelOf;
      final ProviderContainer container = ProviderContainer(
        overrides: [
          appSettingsInitialStateProvider.overrideWithValue(
            AppSettings(groupInviteFrom: from),
          ),
          appSettingsHydrationEnabledProvider.overrideWithValue(false),
          friendLevelLookupProvider.overrideWithValue(lookup),
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  for (final String a in <String>[weak, mid, close])
                    a: FriendProfile(
                      address: a,
                      displayName: a,
                      status: FriendRelationshipStatus.accepted,
                    ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    ZenSignal invite(String from, String id) => ZenSignal(
      type: ZenSignalType.groupInvite,
      sender: from,
      groupId: id,
      groupName: 'Wyprawa',
      memberAddresses: <String>[from],
    );

    test(
      'a weak acquaintance and a stranger are declined by default',
      () async {
        final ProviderContainer c = hub();
        final SocialHubController controller = c.read(
          socialHubControllerProvider.notifier,
        );
        await controller.receiveSignal(
          invite(weak, 'g-w'),
          receivedAtMillis: 1,
        );
        await controller.receiveSignal(
          invite(stranger, 'g-s'),
          receivedAtMillis: 2,
        );
        await controller.receiveSignal(invite(mid, 'g-m'), receivedAtMillis: 3);
        final SocialHubState s = c.read(socialHubControllerProvider);
        expect(s.groups.containsKey('g-w'), isFalse);
        expect(s.groups.containsKey('g-s'), isFalse);
        expect(s.groups['g-m']?.isInvitePending, isTrue);
      },
    );

    test('"Tylko przyjaciele" takes only close friends', () async {
      final ProviderContainer c = hub(from: GroupInviteFrom.closeFriends);
      final SocialHubController controller = c.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(invite(mid, 'g-m'), receivedAtMillis: 1);
      await controller.receiveSignal(invite(close, 'g-c'), receivedAtMillis: 2);
      final SocialHubState s = c.read(socialHubControllerProvider);
      expect(s.groups.containsKey('g-m'), isFalse);
      expect(s.groups['g-c']?.isInvitePending, isTrue);
    });

    test('the setting is saved by name', () {
      const AppSettings s = AppSettings(
        groupInviteFrom: GroupInviteFrom.closeFriends,
      );
      expect(
        AppSettings.fromJson(s.toJson()).groupInviteFrom,
        GroupInviteFrom.closeFriends,
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{}).groupInviteFrom,
        GroupInviteFrom.friends,
      );
    });
  });

  group('circle and mailboxes prefer "Przyjaciel"', () {
    test('closest first, stable within a level', () {
      expect(closestFirst(<String>[weak, mid, close], levelOf), <String>[
        close,
        mid,
        weak,
      ]);
      final String mid2 = PeerShareCodec.normalizeAddress('200::b3');
      expect(closestFirst(<String>[mid2, weak, mid], levelOf), <String>[
        mid2,
        mid,
        weak,
      ]);
    });

    test('the key\'s pieces: every close friend once, at most twelve, in an '
        'order of their own for each account', () {
      final List<String> many = <String>[
        for (int i = 0; i < 15; i++)
          PeerShareCodec.normalizeAddress('200::e$i'),
      ];
      final List<String> picked = pieceHolders(
        close: <String>[...many, many[0], close],
        account: 'konto-a',
      );
      expect(picked, hasLength(kMaxPieceHolders));
      expect(picked.toSet(), hasLength(picked.length));
      expect(
        pieceHolders(
          close: <String>[close, ...many.reversed],
          account: 'konto-a',
        ),
        picked,
        reason: 'the same for the same account, whatever the order given',
      );
      expect(
        pieceHolders(close: <String>[...many, close], account: 'konto-b'),
        isNot(picked),
        reason: 'not the same friends keep everyone\'s',
      );
      // Under the limit every close friend holds one.
      final List<String> few = many.take(5).toList();
      expect(pieceHolders(close: few, account: 'k').toSet(), few.toSet());
      expect(
        pieceHolders(close: <String>[...few, close], account: 'k').toSet(),
        <String>{...few, close},
      );
    });

    test('free mailbox places go to close friends first', () async {
      final MemoryRelayStateStore store = MemoryRelayStateStore();
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 8; i++)
          RelayFriend(
            address: PeerShareCodec.normalizeAddress('200::e$i'),
            lastSeenAtMillis: 1000 + i,
          ),
        // Seen long ago, but "Przyjaciel".
        RelayFriend(address: close, closeness: FriendLevel.close.index),
      ];
      final RelayEngine engine = RelayEngine(
        store: store,
        peers: _Peers(friends),
        send: (String to, Map<String, dynamic> payload) async {},
        clock: () => 5000,
      );
      await engine.activate();
      final RelayState state = await store.load();
      expect(state.currentRelays, hasLength(6));
      expect(state.currentRelays.first, close);
    });
  });
}
