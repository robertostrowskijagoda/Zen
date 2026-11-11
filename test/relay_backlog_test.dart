import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What waits ("Czeka na doręczenie") and what is held for friends
/// ("Przechowujesz dla znajomych") on a phone whose friends barely use Zen:
/// two weeks and more of a small circle on the real relay engines, with a
/// virtual clock. The owner's phone is always on (an Android phone whose
/// background service keeps the node); each friend opens Zen for a few
/// minutes a day and is away otherwise (an iPhone, a phone whose service
/// is stopped). One friend moved to a new phone and the old one is gone
/// (still a device of their account, never unlinked), one uninstalled Zen.
///
/// The app is modelled by what it queues (each send to a friend goes to
/// every device of their account, as the account routing does): messages
/// and their receipts, posts and likes pushed to friends who are offline
/// (`lg_push`), the daily "open to meet" frame (`graph_open`), profile
/// edits, friend list changes.

// ---------------------------------------------------------------------------
// The world
// ---------------------------------------------------------------------------

/// Keeps the state object itself, as a phone keeps it on its disk.
final class _Store implements RelayStateStore {
  RelayState? state;

  @override
  Future<RelayState> load() async => state ??= RelayState();

  @override
  Future<void> save(RelayState next) async => state = next;
}

final class _Person {
  _Person(this.name);

  final String name;
  final List<_Device> devices = <_Device>[];

  /// The address the friends' apps know this person by (their first
  /// device: a friend who moved to a new phone is still known by the old).
  String get main => devices.first.address;
}

final class _Device implements RelayPeerSource {
  _Device(this.world, this.person, this.address) {
    engine = RelayEngine(
      store: store,
      peers: this,
      send: (String to, Map<String, dynamic> payload) async =>
          world._send(address, to, payload),
      clock: () => world.now,
    );
  }

  final _World world;
  final _Person person;
  final String address;
  final _Store store = _Store();
  late final RelayEngine engine;
  bool online = false;

  /// Chat messages from each person not read yet (newest last).
  final Map<String, List<String>> unread = <String, List<String>>{};

  /// What the app here got, by type (each payload once).
  final Map<String, int> received = <String, int>{};

  /// What the app here got, in order.
  final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];

  @override
  bool get isReady => true;

  @override
  String get localAddress => address;

  @override
  List<RelayFriend> acceptedFriends() => <RelayFriend>[
    for (final _Person p in world.people)
      if (p != person && !world.apart.contains(world._pair(p, person)))
        RelayFriend(
          address: p.main,
          devices: <String>[
            for (final _Device d in p.devices.skip(1)) d.address,
          ],
          lastSeenAtMillis: world.lastSeen[p.name] ?? 0,
        ),
  ];

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];

  Future<void> receive(String from, Map<String, dynamic> payload) async {
    final List<SignalTransportFrame> forward = await engine.handleIncoming(
      SignalTransportFrame(
        from: from,
        payload: payload,
        receivedAtMillis: world.now,
      ),
    );
    for (final SignalTransportFrame frame in forward) {
      await world._app(this, frame);
    }
  }
}

final class _World {
  _World({int seed = 7}) : random = Random(seed);

  final Random random;
  int now = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;
  final List<_Person> people = <_Person>[];
  final Map<String, _Device> devices = <String, _Device>{};
  final Map<String, int> lastSeen = <String, int>{};

  /// Pairs of people who are no friends (any more).
  final Set<String> apart = <String>{};

  String _pair(_Person a, _Person b) =>
      (<String>[a.name, b.name]..sort()).join('|');

  void unfriend(String a, String b) => apart.add(_pair(this[a], this[b]));
  final Queue<({String from, String to, Map<String, dynamic> payload})>
  _inFlight = Queue<({String from, String to, Map<String, dynamic> payload})>();

  /// Reliable id → (type, sender and recipient device, when) of everything
  /// queued.
  final Map<String, ({String type, String from, String to, int at})> queued =
      <String, ({String type, String from, String to, int at})>{};
  int _ids = 0;

  _Person person(String name, int deviceCount) {
    final _Person p = _Person(name);
    for (int i = 0; i < deviceCount; i++) {
      final String address = PeerShareCodec.normalizeAddress(
        '200:${people.length + 1}::${i + 1}',
      );
      final _Device d = _Device(this, p, address);
      p.devices.add(d);
      devices[address] = d;
    }
    people.add(p);
    return p;
  }

  _Person operator [](String name) =>
      people.firstWhere((_Person p) => p.name == name);

  void _send(String from, String to, Map<String, dynamic> payload) {
    final _Device? target = devices[PeerShareCodec.normalizeAddress(to)];
    if (target == null || !target.online || !devices[from]!.online) {
      return; // like a datagram to a phone that is away
    }
    _inFlight.add((
      from: from,
      to: target.address,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
    ));
  }

  Future<void> settle() async {
    int steps = 0;
    while (_inFlight.isNotEmpty) {
      if (++steps > 200000) {
        fail('the network did not settle');
      }
      final ({String from, String to, Map<String, dynamic> payload}) d =
          _inFlight.removeFirst();
      final _Device target = devices[d.to]!;
      if (target.online) {
        await target.receive(d.from, d.payload);
      }
    }
  }

  Future<void> setOnline(_Device d, bool on) async {
    if (d.online == on) {
      return;
    }
    d.online = on;
    if (on) {
      lastSeen[d.person.name] = now;
      await d.engine.activate();
      await settle();
    } else {
      d.engine.deactivate();
    }
  }

  /// Moves the clock on by [by] in ticks: every 30 s while a friend is
  /// online, every 5 minutes while only the always-on phones are.
  Future<void> advance(Duration by) async {
    final int end = now + by.inMilliseconds;
    while (now < end) {
      final bool busy = devices.values.any(
        (_Device d) => d.online && d.person.name != 'owner',
      );
      final int step = busy ? 30 * 1000 : 5 * 60 * 1000;
      now = min(end, now + step);
      for (final _Device d in devices.values) {
        if (d.online) {
          lastSeen[d.person.name] = now;
          await d.engine.tick();
        }
      }
      await settle();
    }
  }

  /// [payload] from [from] to every device of [to], each with an id of its
  /// own (as the account routing queues it).
  Future<void> sendToPerson(
    _Device from,
    _Person to,
    Map<String, dynamic> payload,
  ) async {
    for (final _Device d in to.devices) {
      await sendToDevice(from, d, payload);
    }
  }

  Future<void> sendToDevice(
    _Device from,
    _Device to,
    Map<String, dynamic> payload,
  ) async {
    final String rid = 'r${_ids++}x${random.nextInt(1 << 30)}';
    queued[rid] = (
      type: payload['type'] as String,
      from: from.address,
      to: to.address,
      at: now,
    );
    await from.engine.submit(to.address, <String, dynamic>{
      ...payload,
      kReliableIdKey: rid,
    });
    await settle();
  }

  /// What the app does with a frame the engine handed it.
  Future<void> _app(_Device at, SignalTransportFrame frame) async {
    final String type = '${frame.payload['type']}';
    at.received[type] = (at.received[type] ?? 0) + 1;
    at.got.add(frame.payload);
    final _Device? from = devices[PeerShareCodec.normalizeAddress(frame.from)];
    if (from == null || type != 'message') {
      return;
    }
    final String msgId = '${frame.payload['msgId']}';
    // The delivery receipt goes at once, to the sender's account.
    await sendToPerson(at, from.person, <String, dynamic>{
      'type': 'message_ack',
      'msgId': msgId,
    });
    (at.unread[from.person.name] ??= <String>[]).add(msgId);
    if (at.person.name == 'owner') {
      await read(at);
    }
  }

  /// The app shows the chats: the newest unread message of each gets its
  /// read receipt.
  Future<void> read(_Device at) async {
    for (final MapEntry<String, List<String>> e in at.unread.entries) {
      if (e.value.isEmpty) {
        continue;
      }
      await sendToPerson(at, this[e.key], <String, dynamic>{
        'type': 'message_read',
        'msgId': e.value.last,
      });
      e.value.clear();
    }
  }

  int _msg = 0;

  Future<void> message(_Device from, _Person to) => sendToPerson(
    from,
    to,
    <String, dynamic>{'type': 'message', 'msgId': 'm${_msg++}', 'text': 'hej'},
  );

  /// A post or like of [from], pushed to every friend's device the app
  /// takes for offline (LedgerMailPush: the presence of a friend is known
  /// by the address the app knows them by, so a second device always
  /// counts as offline).
  Future<void> push(_Device from) async {
    for (final _Person p in people) {
      if (p == from.person) {
        continue;
      }
      for (final _Device d in p.devices) {
        final bool knownOnline = d == p.devices.first && d.online;
        if (!knownOnline) {
          await sendToDevice(from, d, <String, dynamic>{
            'type': 'lg_push',
            'entries': <Object>[
              <String, dynamic>{'k': 'post', 'at': now},
            ],
          });
        }
      }
    }
  }

  Future<void> toAllFriends(_Device from, Map<String, dynamic> payload) async {
    for (final _Person p in people) {
      if (p != from.person) {
        await sendToPerson(from, p, payload);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Two weeks of a small circle
// ---------------------------------------------------------------------------

final class _Tally {
  _Tally(this.label);

  final String label;
  int waiting = 0;
  int held = 0;
  int heldFor = 0;
  final Map<String, int> waitingBy = <String, int>{};
  final Map<String, int> heldBy = <String, int>{};
  final Map<String, int> waitingFor = <String, int>{};
  final Map<String, int> heldForWhom = <String, int>{};
  RelayOverview overview = const RelayOverview();

  @override
  String toString() {
    String sorted(Map<String, int> m) {
      final List<MapEntry<String, int>> l = m.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return l
          .map((MapEntry<String, int> e) => '${e.key}=${e.value}')
          .join(' ');
    }

    return '$label: waiting $waiting (${sorted(waitingBy)}) for '
        '[${sorted(waitingFor)}]; held $held for $heldFor '
        '(${sorted(heldBy)}) for [${sorted(heldForWhom)}]; screen '
        '${overview.outboxCount} / ${overview.heldEnvelopeCount} '
        '(${overview.heldForPeerCount} os.)';
  }
}

/// Who a device is, for the tallies.
String _whoIs(_World w, String address) {
  final _Device? d = w.devices[address];
  if (d == null) {
    return '?';
  }
  final int i = d.person.devices.indexOf(d);
  return d.person.devices.length > 1
      ? '${d.person.name}#${i + 1}'
      : d.person.name;
}

Future<_Tally> _tally(_World w, _Device phone, String label) async {
  final RelayState s = await phone.store.load();
  final _Tally t = _Tally(label);
  for (final RelayOutboxEntry e in s.outbox.values) {
    t.waiting++;
    final String type = '${e.payload['type']}';
    t.waitingBy[type] = (t.waitingBy[type] ?? 0) + 1;
    final String who = _whoIs(w, e.recipient);
    t.waitingFor[who] = (t.waitingFor[who] ?? 0) + 1;
  }
  t.heldFor = s.mailbox.length;
  s.mailbox.forEach((String recipient, Map<String, Map<String, dynamic>> m) {
    for (final String id in m.keys) {
      t.held++;
      final String type = w.queued[id]?.type ?? '?';
      t.heldBy[type] = (t.heldBy[type] ?? 0) + 1;
      final String who = _whoIs(w, recipient);
      t.heldForWhom[who] = (t.heldForWhom[who] ?? 0) + 1;
    }
  });
  t.overview = phone.engine.overview.value;
  return t;
}

/// The circle: the owner (always on), five friends who open Zen once a day
/// for five minutes, friend `moved` whose first phone is gone since before
/// the start, and friend `gone` who uninstalled Zen at the start. Runs
/// [days] days; returns the owner's phone.
Future<_World> _twoWeeks({int days = 21}) async {
  final _World w = _World();
  final _Person owner = w.person('owner', 1);
  final List<_Person> friends = <_Person>[
    for (final String n in <String>['ania', 'bartek', 'celina', 'darek'])
      w.person(n, 1),
    w.person('moved', 2),
    w.person('gone', 1),
  ];
  // Everyone was around once: mailboxes chosen and announced.
  for (final _Device d in w.devices.values) {
    await w.setOnline(d, true);
  }
  await w.advance(const Duration(minutes: 2));
  // Then the old phone of `moved` and the phone of `gone` go for good.
  await w.setOnline(w['moved'].devices.first, false);
  await w.setOnline(w['gone'].devices.first, false);
  for (final _Person f in friends) {
    for (final _Device d in f.devices) {
      if (d != w['moved'].devices.first && d != w['gone'].devices.first) {
        await w.setOnline(d, false);
      }
    }
  }
  final _Device me = owner.devices.first;
  final List<_Device> active = <_Device>[
    for (final _Person f in friends)
      if (f.name != 'gone') f.devices.last,
  ];
  final int start = w.now;
  for (int day = 0; day < days; day++) {
    final int midnight = start + day * Duration.millisecondsPerDay;
    // When each friend opens Zen today.
    final Map<int, _Device> opens = <int, _Device>{};
    for (final _Device d in active) {
      int at;
      do {
        at = 8 * 60 + 5 * w.random.nextInt(14 * 12);
      } while (opens.containsKey(at));
      opens[at] = d;
    }
    for (int minute = 0; minute < 24 * 60; minute += 5) {
      final int at = midnight + minute * 60 * 1000;
      if (w.now < at) {
        await w.advance(Duration(milliseconds: at - w.now));
      }
      final int hour = minute ~/ 60;
      final bool onTheHour = minute % 60 == 0;
      // The owner's day: the "open to meet" frame goes to every friend
      // once a day, posts and likes are pushed four times a day, three
      // messages, a profile edit every third day, a new friend list twice.
      if (onTheHour && hour == 8) {
        await w.toAllFriends(me, <String, dynamic>{
          'type': 'graph_open',
          'o': <String, dynamic>{'d': day},
        });
      }
      if (onTheHour && <int>[9, 13, 17, 21].contains(hour)) {
        await w.push(me);
      }
      if (onTheHour && <int>[10, 14, 20].contains(hour)) {
        await w.message(me, friends[(day * 3 + hour) % friends.length]);
      }
      if (onTheHour && hour == 12 && day % 3 == 0) {
        await w.toAllFriends(me, <String, dynamic>{
          'type': 'profile_update',
          'v': day,
        });
      }
      if (onTheHour && hour == 18 && (day == 4 || day == 11)) {
        await w.toAllFriends(me, <String, dynamic>{
          'type': 'friend_list',
          'l': <Object>[],
          'd': 'v$day',
        });
      }
      // A friend's few minutes: they read, now and then write back, like
      // one of the owner's posts.
      final _Device? friend = opens[minute];
      if (friend != null) {
        await w.setOnline(friend, true);
        await w.advance(const Duration(minutes: 1));
        await w.read(friend);
        if (w.random.nextBool()) {
          await w.message(friend, owner);
        }
        await w.push(friend);
        await w.advance(const Duration(minutes: 4));
        await w.setOnline(friend, false);
      }
    }
  }
  return w;
}

void main() {
  test('a small circle that barely uses Zen leaves only what is really on its '
      'way: nothing for a phone its friend replaced, no pile of the same '
      'kind, and the mail of a friend who is just away still waits', () async {
    final _World w = await _twoWeeks();
    final _Device me = w['owner'].devices.first;
    final _Tally t = await _tally(w, me, 'owner after 21 days');
    // What waits and what is held, by kind and for whom, on each phone:
    // the table to compare with a phone's "Relay backlog" log line.
    // ignore: avoid_print
    print(t);
    for (final _Device d in w.devices.values) {
      if (d != me) {
        // ignore: avoid_print
        print(await _tally(w, d, _whoIs(w, d.address)));
      }
    }
    final RelayState s = await me.store.load();
    final String oldPhone = w['moved'].devices.first.address;
    // For the phone `moved` left behind only what a person sent waits and
    // is held (with 1.16.4: 90 waiting, 146 held, a third of each number;
    // posts, "open to meet", profiles and receipts for it).
    expect(s.goneDevices.keys, <String>[oldPhone]);
    expect(
      s.outbox.values
          .where((RelayOutboxEntry e) => e.recipient == oldPhone)
          .every((RelayOutboxEntry e) => relayIsPersonalPayload(e.payload)),
      isTrue,
    );
    expect(
      s.mailbox[oldPhone]?.values.where(
            (Map<String, dynamic> e) => e['a'] == 1,
          ) ??
          const <Object>[],
      isEmpty,
    );
    expect(t.waitingFor['moved#1'] ?? 0, lessThanOrEqualTo(20));
    // One of each kind where only the newest matters, per device.
    final Map<String, int> kinds = <String, int>{};
    for (final RelayOutboxEntry e in s.outbox.values) {
      final String? key = relayReplaceKeyOf(e.payload);
      if (key != null) {
        final String slot = '${e.recipient}|$key';
        kinds[slot] = (kinds[slot] ?? 0) + 1;
      }
    }
    expect(kinds.values.where((int n) => n > 1), isEmpty);
    // The messages to the friend who uninstalled Zen still wait, two weeks
    // as before; posts pushed to them one week.
    const int day = Duration.millisecondsPerDay;
    final Iterable<RelayOutboxEntry> toGone = s.outbox.values.where(
      (RelayOutboxEntry e) => e.recipient == w['gone'].main,
    );
    expect(
      toGone
          .where((RelayOutboxEntry e) => e.payload['type'] == 'message')
          .length,
      w.queued.values
          .where(
            (({String type, String from, String to, int at}) q) =>
                q.type == 'message' &&
                q.from == me.address &&
                q.to == w['gone'].main &&
                w.now - q.at < 14 * day,
          )
          .length,
    );
    expect(
      toGone.every(
        (RelayOutboxEntry e) =>
            e.payload['type'] != 'lg_push' ||
            w.now - e.createdAtMillis < 7 * day,
      ),
      isTrue,
    );
    // With 1.16.4 the owner's phone showed 192 waiting and 328 held for 7.
    expect(t.waiting, lessThan(70));
    expect(t.held, lessThan(130));
    expect(t.overview.outboxCount, lessThanOrEqualTo(t.waitingBy['message']!));
    expect(t.overview.heldForPeerCount, lessThanOrEqualTo(6));
    // Between friends who are never online together nothing stays waiting
    // for a friend who took it from a mailbox: what waits is for the two
    // phones nobody collects from, and the last day or so.
    for (final String name in <String>['ania', 'bartek', 'celina', 'darek']) {
      final _Tally f = await _tally(w, w[name].devices.first, name);
      for (final String other in <String>[
        'ania',
        'bartek',
        'celina',
        'darek',
      ]) {
        expect(
          f.waitingFor[other] ?? 0,
          lessThanOrEqualTo(3),
          reason: '$name for $other',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  group('kinds where only the newest matters', () {
    test('the kinds a real phone piled up are among them: friend lists, '
        'nearby keys, gate terms, profiles', () {
      // A phone on 1.16.4 with ten friends had 804 frames waiting: 488
      // friend lists, 228 nearby keys, 43 gate terms, 17 profiles.
      for (final String type in <String>[
        'friend_list',
        'nearby_key',
        'intro_gate',
        'profile_update',
      ]) {
        expect(
          relayReplaceKeyOf(<String, dynamic>{'type': type}),
          type,
          reason: type,
        );
      }
      expect(relayReplaceKeyOf(<String, dynamic>{'type': 'message'}), isNull);
    });

    test('a newer profile replaces the older one in the queue and in the '
        "friend's mailboxes; the friend gets the newest only", () async {
      final _World w = await _circle(<String, int>{
        'owner': 1,
        'ania': 1,
        'bartek': 1,
        'celina': 1,
      });
      final _Device me = w['owner'].devices.first;
      final _Device bartek = w['bartek'].devices.first;
      await w.setOnline(bartek, false);
      for (int v = 1; v <= 3; v++) {
        await w.sendToDevice(me, bartek, <String, dynamic>{
          'type': 'profile_update',
          'v': v,
        });
        await w.advance(const Duration(minutes: 1));
      }
      final RelayState mine = await me.store.load();
      expect(
        <Object?>[
          for (final RelayOutboxEntry e in mine.outbox.values) e.payload['v'],
        ],
        <Object?>[3],
      );
      for (final String m in <String>['ania', 'celina']) {
        final Map<String, Map<String, dynamic>> held =
            (await w[m].devices.first.store.load()).mailbox[bartek.address]!;
        expect(held, hasLength(1), reason: '$m holds the newest only');
        expect(held.values.single['rp'], isA<String>());
      }
      await w.setOnline(bartek, true);
      await w.advance(const Duration(minutes: 1));
      expect(
        <Object?>[
          for (final Map<String, dynamic> p in bartek.got)
            if (p['type'] == 'profile_update') p['v'],
        ],
        <Object?>[3],
      );
    });

    test('missed calls to a friend who is away wait in their mailboxes, the '
        'newest per caller, and reach them when back', () async {
      final _World w = await _circle(<String, int>{
        'owner': 1,
        'ania': 1,
        'bartek': 1,
        'celina': 1,
      });
      final _Device me = w['owner'].devices.first;
      final _Device bartek = w['bartek'].devices.first;
      await w.setOnline(bartek, false);
      for (int i = 1; i <= 3; i++) {
        await w.sendToDevice(me, bartek, <String, dynamic>{
          'type': 'call_missed',
          'callId': 'call-$i',
          'kind': 'audio',
          'at': w.now,
        });
        await w.advance(const Duration(minutes: 1));
      }
      expect(
        <Object?>[
          for (final RelayOutboxEntry e
              in (await me.store.load()).outbox.values)
            e.payload['callId'],
        ],
        <Object?>['call-3'],
      );
      for (final String m in <String>['ania', 'celina']) {
        final Map<String, Map<String, dynamic>> held =
            (await w[m].devices.first.store.load()).mailbox[bartek.address]!;
        expect(held, hasLength(1), reason: '$m holds the newest only');
      }
      // Its own kind of mail: a device taken for gone still gets it.
      expect(
        relayIsPersonalPayload(<String, dynamic>{'type': 'call_missed'}),
        isTrue,
      );
      await w.setOnline(bartek, true);
      await w.advance(const Duration(minutes: 1));
      expect(
        <Object?>[
          for (final Map<String, dynamic> p in bartek.got)
            if (p['type'] == 'call_missed') p['callId'],
        ],
        <Object?>['call-3'],
      );
      expect((await me.store.load()).outbox, isEmpty);
    });

    test('a fellow mailbox catching up cannot make a mailbox drop what the '
        'sender handed in', () async {
      final _World w = await _circle(<String, int>{
        'owner': 1,
        'ania': 1,
        'bartek': 1,
        'celina': 1,
      });
      final _Device me = w['owner'].devices.first;
      final _Device bartek = w['bartek'].devices.first;
      final _Device ania = w['ania'].devices.first;
      final _Device celina = w['celina'].devices.first;
      await w.setOnline(bartek, false);
      await w.sendToDevice(me, bartek, <String, dynamic>{
        'type': 'profile_update',
        'v': 1,
      });
      await w.advance(const Duration(minutes: 1));
      final Map<String, dynamic> real =
          (await ania.store.load()).mailbox[bartek.address]!.values.single;
      // Celina claims a newer one of the same kind.
      final Map<String, dynamic> claimed = Map<String, dynamic>.of(real)
        ..remove('hv')
        ..remove('ha')
        ..remove('hx')
        ..['id'] = 'newer'
        ..['c'] = (real['c'] as int) + 1000;
      await ania.receive(celina.address, <String, dynamic>{
        'type': 'rly_deposit',
        'env': claimed,
      });
      expect(
        (await ania.store.load()).mailbox[bartek.address]!.keys,
        containsAll(<String>[real['id'] as String, 'newer']),
      );
    });

    test('a profile queued by an older version is kept once: the newest of '
        'each kind per friend, and posts pushed a week ago are dropped at '
        'the first start', () async {
      final _World w = await _circle(<String, int>{
        'owner': 1,
        'ania': 1,
        'bartek': 1,
      });
      final _Device me = w['owner'].devices.first;
      final _Device ania = w['ania'].devices.first;
      await w.setOnline(ania, false);
      await w.setOnline(me, false);
      final RelayState old = RelayState.fromJsonString(
        (await me.store.load()).toJsonString(),
      );
      const int day = Duration.millisecondsPerDay;
      for (int i = 0; i < 5; i++) {
        old.outbox['p$i'] = RelayOutboxEntry(
          rid: 'p$i',
          recipient: ania.address,
          payload: <String, dynamic>{
            'type': 'profile_update',
            'v': i,
            kReliableIdKey: 'p$i',
          },
          createdAtMillis: w.now - (5 - i) * day,
          expiresAtMillis: w.now + 9 * day,
          relayable: true,
        );
      }
      old.outbox['push'] = RelayOutboxEntry(
        rid: 'push',
        recipient: ania.address,
        payload: const <String, dynamic>{
          'type': 'lg_push',
          'entries': <Object>[],
          kReliableIdKey: 'push',
        },
        createdAtMillis: w.now - 8 * day,
        expiresAtMillis: w.now + 6 * day,
        relayable: true,
      );
      old.outbox['msg'] = RelayOutboxEntry(
        rid: 'msg',
        recipient: ania.address,
        payload: const <String, dynamic>{
          'type': 'message',
          'msgId': 'old',
          kReliableIdKey: 'msg',
        },
        createdAtMillis: w.now - 8 * day,
        expiresAtMillis: w.now + 6 * day,
        relayable: true,
      );
      me.store.state = RelayState.fromJsonString(old.toJsonString());
      await w.setOnline(me, true);
      final RelayState now = await me.store.load();
      expect(now.outbox.keys.toSet(), <String>{'p4', 'msg'});
      expect(me.engine.overview.value.outboxCount, 1);
    });
  });

  group('a friend who moved to another phone', () {
    test('a second device silent for 10 days while the phone answers is taken '
        'for gone: the app stops queuing its own frames for it, but every '
        'chat message of those days and the newest profile wait for it and '
        'arrive when it is opened', () async {
      final _World w = await _circle(<String, int>{
        'owner': 1,
        'ania': 1,
        'tomek': 2,
      });
      final _Device me = w['owner'].devices.first;
      final _Device ania = w['ania'].devices.first;
      final _Device phone = w['tomek'].devices.first;
      final _Device laptop = w['tomek'].devices.last;
      await w.setOnline(phone, false);
      await w.setOnline(laptop, false);
      await w.setOnline(ania, false);
      for (int day = 0; day < 10; day++) {
        await w.message(me, w['tomek']);
        await w.push(me);
        await w.sendToPerson(me, w['tomek'], <String, dynamic>{
          'type': 'graph_open',
          'o': <String, dynamic>{'d': day},
        });
        if (day % 3 == 0) {
          await w.sendToPerson(me, w['tomek'], <String, dynamic>{
            'type': 'profile_update',
            'v': day,
          });
        }
        await w.advance(const Duration(hours: 12));
        await w.setOnline(phone, true);
        await w.advance(const Duration(minutes: 5));
        await w.setOnline(phone, false);
        await w.advance(const Duration(hours: 11, minutes: 55));
      }
      final RelayState mine = await me.store.load();
      expect(mine.goneDevices.keys, <String>[laptop.address]);
      final List<RelayOutboxEntry> forLaptop = mine.outbox.values
          .where((RelayOutboxEntry e) => e.recipient == laptop.address)
          .toList();
      expect(
        <Object?>{
          for (final RelayOutboxEntry e in forLaptop) e.payload['type'],
        },
        <Object?>{'message', 'profile_update'},
      );
      expect(
        forLaptop.where((RelayOutboxEntry e) => e.payload['type'] == 'message'),
        hasLength(10),
      );
      expect(
        mine.mailbox[laptop.address]!.values.where(
          (Map<String, dynamic> e) => e['a'] == 1,
        ),
        isEmpty,
        reason: 'only what a person sent is held for it',
      );
      expect(phone.received['message'], 10);

      // The laptop is opened: every message of those days, the newest
      // profile, nothing it would miss.
      await w.setOnline(laptop, true);
      await w.advance(const Duration(minutes: 2));
      expect(laptop.received['message'], 10);
      expect(
        <Object?>[
          for (final Map<String, dynamic> p in laptop.got)
            if (p['type'] == 'profile_update') p['v'],
        ],
        <Object?>[9],
      );
      expect((await me.store.load()).goneDevices, isEmpty);
      // And the app's own frames go to it again.
      final int pushes = laptop.received['lg_push'] ?? 0;
      await w.push(me);
      await w.advance(const Duration(minutes: 1));
      expect(laptop.received['lg_push'], pushes + 1);
    });

    test('a friend away for a week with all their devices still gets the '
        'message on each', () async {
      final _World w = await _circle(<String, int>{
        'owner': 1,
        'ania': 1,
        'moved': 2,
      });
      final _Device me = w['owner'].devices.first;
      for (final _Device d in w['moved'].devices) {
        await w.setOnline(d, false);
      }
      await w.message(me, w['moved']);
      await w.advance(const Duration(days: 8));
      for (final _Device d in w['moved'].devices) {
        await w.setOnline(d, true);
      }
      await w.advance(const Duration(minutes: 1));
      for (final _Device d in w['moved'].devices) {
        expect(d.received['message'], 1);
      }
      expect((await me.store.load()).goneDevices, isEmpty);
    });
  });

  test('a sender away when its message was taken from a mailbox learns it '
      'from its own mailboxes: nothing stays "waiting"', () async {
    final _World w = await _circle(<String, int>{
      'owner': 1,
      'ania': 1,
      'bartek': 1,
    });
    final _Device ania = w['ania'].devices.first;
    final _Device bartek = w['bartek'].devices.first;
    await w.setOnline(bartek, false);
    await w.message(ania, w['bartek']);
    await w.sendToDevice(ania, bartek, <String, dynamic>{
      'type': 'lg_push',
      'entries': <Object>[],
    });
    await w.advance(const Duration(minutes: 1));
    await w.setOnline(ania, false);
    // Long enough for bartek's phone to take her as away.
    await w.advance(const Duration(minutes: 5));
    await w.setOnline(bartek, true);
    await w.advance(const Duration(minutes: 2));
    await w.setOnline(bartek, false);
    expect(bartek.received['message'], 1);
    expect(
      (await bartek.store.load()).outbox.values.where(
        (RelayOutboxEntry e) => e.payload['type'] == kRelayReceiptType,
      ),
      isEmpty,
      reason: 'the receipt is with her mailboxes',
    );
    await w.setOnline(ania, true);
    await w.advance(const Duration(minutes: 2));
    expect(
      (await ania.store.load()).outbox.values.map(
        (RelayOutboxEntry e) => e.payload['type'],
      ),
      isEmpty,
    );
    expect(ania.engine.overview.value.outboxCount, 0);
  });

  test('mail held for a friend who is no friend any more goes', () async {
    final _World w = await _circle(<String, int>{
      'owner': 1,
      'ania': 1,
      'bartek': 1,
    });
    final _Device me = w['owner'].devices.first;
    final _Device bartek = w['bartek'].devices.first;
    await w.setOnline(bartek, false);
    await w.message(w['ania'].devices.first, w['bartek']);
    await w.advance(const Duration(minutes: 1));
    expect((await me.store.load()).mailbox[bartek.address], hasLength(1));
    w.unfriend('owner', 'bartek');
    await w.advance(const Duration(minutes: 1));
    expect((await me.store.load()).mailbox[bartek.address], isNull);
    expect(me.engine.overview.value.heldEnvelopeCount, 0);
  });

  test('the screen counts messages once per person, not receipts and '
      'statuses, and the people mail is held for', () async {
    final _World w = await _circle(<String, int>{
      'owner': 1,
      'ania': 1,
      'moved': 2,
    });
    final _Device me = w['owner'].devices.first;
    for (final _Device d in w['moved'].devices) {
      await w.setOnline(d, false);
    }
    await w.message(me, w['moved']);
    await w.sendToPerson(me, w['moved'], <String, dynamic>{
      'type': 'profile_update',
      'v': 1,
    });
    await w.sendToPerson(me, w['moved'], <String, dynamic>{
      'type': 'friend_list',
      'l': <Object>[],
    });
    await w.advance(const Duration(minutes: 1));
    expect((await me.store.load()).outbox, hasLength(6));
    expect(me.engine.overview.value.outboxCount, 1);
    final RelayOverview ania = w['ania'].devices.first.engine.overview.value;
    expect(ania.heldEnvelopeCount, 6);
    expect(ania.heldForPeerCount, 1);
  });
}

/// [people] (name → devices), friends with each other, everyone online
/// for two minutes so the mailboxes are chosen and announced.
Future<_World> _circle(Map<String, int> people) async {
  final _World w = _World();
  people.forEach(w.person);
  for (final _Device d in w.devices.values) {
    await w.setOnline(d, true);
  }
  await w.advance(const Duration(minutes: 2));
  return w;
}
