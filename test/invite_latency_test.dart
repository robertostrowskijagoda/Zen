import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/social/social_event_text.dart';

import 'support/friends_world.dart';

/// How long an invitation takes, from the scan of a code to two friends who
/// see each other's names: the real relay engines, social controllers and
/// locked services of two phones (`FriendsWorld`) on a virtual clock, with
/// the mesh's first contact in it (a way to an address nobody talked to yet
/// has to be found first, and what is sent meanwhile is lost).
///
/// Ada shows her code, Bob scans it. Neither knows the other, so neither
/// has mailboxes of the other: the invitation and its answer can only go
/// straight from phone to phone.

const Duration _quick = Duration(seconds: 5);
const Duration _idle = Duration(seconds: 30);

/// Lets time pass the way the phones' timers do (the engine's tick every
/// 5 s while something is due soon, every 30 s otherwise) until [done];
/// returns how long that took. Fails past [within].
Future<Duration> _timeUntil(
  FriendsWorld w,
  Future<bool> Function() done, {
  required Duration within,
  required String what,
}) async {
  final int start = w.now;
  while (!await done()) {
    final int took = w.now - start;
    if (took > within.inMilliseconds) {
      fail(
        '$what did not happen within $within '
        '(${w.lostToLookups} frames lost to lookups)\n${await w.describe()}',
      );
    }
    final bool soon = w.phones.any(
      (FriendsPhone p) => p.online && !p.locked && p.engine.wantsFrequentTicks,
    );
    await w.advance(soon ? _quick : _idle);
  }
  return Duration(milliseconds: w.now - start);
}

/// Ada and Bob, strangers, each with their own name chosen.
Future<FriendsWorld> _strangers({
  required Duration routeLookup,
  required Duration? routeHold,
}) async {
  final FriendsWorld w = await FriendsWorld.create(<String>[
    'Ada',
    'Bob',
  ], allFriends: false);
  for (final FriendsPhone p in w.phones) {
    await p.container
        .read(userProfileControllerProvider.notifier)
        .updateProfile(displayName: p.name);
  }
  await w.settle();
  w
    ..routeLookup = routeLookup
    ..routeHold = routeHold;
  return w;
}

FriendRelationshipStatus? _statusOf(FriendsPhone on, FriendsPhone peer) =>
    on.state.friendByAddress(peer.address)?.status;

/// Bob scans Ada's code and sends the request as the app does (his name
/// filled in by the app).
Future<void> _scan(FriendsWorld w) => w['Bob'].hub.sendFriendRequest(
  peerAddress: w['Ada'].address,
  message: 'To ja z imprezy',
);

Future<Duration> _requestArrives(FriendsWorld w, {required Duration within}) =>
    _timeUntil(
      w,
      () async =>
          _statusOf(w['Ada'], w['Bob']) ==
          FriendRelationshipStatus.pendingIncoming,
      within: within,
      what: "Bob's request reaching Ada",
    );

/// Ada accepts; returns how long until Bob is her friend too.
Future<Duration> _acceptArrives(
  FriendsWorld w, {
  required Duration within,
}) async {
  await w['Ada'].hub.acceptFriendRequest(peerAddress: w['Bob'].address);
  return _timeUntil(
    w,
    () async =>
        _statusOf(w['Bob'], w['Ada']) == FriendRelationshipStatus.accepted,
    within: within,
    what: "Ada's answer reaching Bob",
  );
}

/// The "connected" notes in [on]'s chat with [peer], as the screen shows
/// them.
Future<List<String>> _connectedNotes(
  FriendsPhone on,
  FriendsPhone peer,
) async => <String>[
  for (final ChatMessage m in await on.thread(peer))
    if (chatMessageEvent(m)?.code == 'chat.connected') chatMessageText(m),
];

Future<void> _expectNamesBothWays(FriendsWorld w) async {
  final FriendsPhone ada = w['Ada'];
  final FriendsPhone bob = w['Bob'];
  expect(ada.state.friendByAddress(bob.address)?.displayLabel, 'Bob');
  expect(bob.state.friendByAddress(ada.address)?.displayLabel, 'Ada');
  expect(await _connectedNotes(ada, bob), <String>[
    'Połączenie z Bob jest gotowe.',
  ]);
  expect(await _connectedNotes(bob, ada), <String>[
    'Połączenie z Ada jest gotowe.',
  ]);
}

void main() {
  // The mesh in two ways: what is sent while the way to a new address is
  // looked up is lost (the worst case: the bridge's first key exchange
  // lost, nothing asked again), or the bridge holds it and asks again until
  // the way is known (as pq_session.go does, for up to 20 s).
  for (final (String mesh, Duration? hold) in <(String, Duration?)>[
    ('frames lost while the way is looked up', null),
    ('frames held by the bridge meanwhile', const Duration(seconds: 20)),
  ]) {
    group(mesh, () {
      _scenarios(hold);
    });
  }
}

void _scenarios(Duration? hold) {
  test('both online: the request and the answer arrive within seconds, '
      'and both see the other one by name', () async {
    final FriendsWorld w = await _strangers(
      routeLookup: const Duration(seconds: 4),
      routeHold: hold,
    );
    await _scan(w);
    final Duration request = await _requestArrives(
      w,
      within: const Duration(seconds: 10),
    );
    final Duration answer = await _acceptArrives(
      w,
      within: const Duration(seconds: 10),
    );
    await w.deliver();
    await _expectNamesBothWays(w);
    _report('both online', request, answer);
  });

  test(
    'the scanner on a slow network: lookups take long and datagrams get '
    'lost, the request and the answer still arrive within a minute',
    () async {
      final FriendsWorld w = await _strangers(
        routeLookup: const Duration(seconds: 20),
        routeHold: hold,
      );
      w.net
        ..minLatencyMs = 800
        ..maxLatencyMs = 2500;
      w.dropRate = 0.2;
      await _scan(w);
      final Duration request = await _requestArrives(
        w,
        within: const Duration(minutes: 1),
      );
      final Duration answer = await _acceptArrives(
        w,
        within: const Duration(minutes: 1),
      );
      w.dropRate = 0;
      await w.deliver();
      await _expectNamesBothWays(w);
      _report('slow network', request, answer);
    },
  );

  test('the inviter locked: the request is kept and announced at once, and '
      'shows up the moment she unlocks', () async {
    final FriendsWorld w = await _strangers(
      routeLookup: const Duration(seconds: 4),
      routeHold: hold,
    );
    await w.lock(w['Ada']);
    await _scan(w);
    final Duration noticed = await _timeUntil(
      w,
      () async => w['Ada'].notices.posted.any(
        (RuntimeSystemNotification n) =>
            n.category == RuntimeSystemNotificationCategory.social,
      ),
      within: const Duration(seconds: 10),
      what: "the notice of Bob's request on Ada's locked phone",
    );
    await w.advance(const Duration(minutes: 3));
    await w.unlock(w['Ada']);
    expect(
      _statusOf(w['Ada'], w['Bob']),
      FriendRelationshipStatus.pendingIncoming,
    );
    final Duration answer = await _acceptArrives(
      w,
      within: const Duration(seconds: 10),
    );
    await w.deliver();
    await _expectNamesBothWays(w);
    _report('inviter locked (notice)', noticed, answer);
  });

  for (final (Duration away, Duration within) in const <(Duration, Duration)>[
    (Duration(minutes: 10), Duration(minutes: 2)),
    (Duration(hours: 1), Duration(minutes: 5)),
    (Duration(hours: 5), Duration(minutes: 5)),
    (Duration(hours: 12), Duration(minutes: 11)),
  ]) {
    test('the inviter offline for $away: the request arrives within $within '
        'of her coming back', () async {
      final FriendsWorld w = await _strangers(
        routeLookup: const Duration(seconds: 4),
        routeHold: hold,
      );
      await w.setOnline(w['Ada'], false);
      await _scan(w);
      await w.advance(away);
      expect(_statusOf(w['Ada'], w['Bob']), isNull);
      await w.setOnline(w['Ada'], true);
      final Duration request = await _requestArrives(w, within: within);
      final Duration answer = await _acceptArrives(
        w,
        within: const Duration(seconds: 10),
      );
      await w.deliver();
      await _expectNamesBothWays(w);
      _report('inviter offline $away (after return)', request, answer);
    });
  }
}

void _report(String what, Duration request, Duration answer) {
  // ignore: avoid_print
  print('$what: request ${_s(request)}, answer ${_s(answer)}');
}

String _s(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
