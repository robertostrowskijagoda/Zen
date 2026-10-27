import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/relay/mailbox_quiet_notice.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

String _a(String suffix) => PeerShareCodec.normalizeAddress('200::$suffix');

const int _day = 24 * 60 * 60 * 1000;
const int _hour = 60 * 60 * 1000;

final class _Peers implements RelayPeerSource {
  _Peers(this.self, this.friends);

  final String self;
  List<RelayFriend> friends;

  @override
  bool get isReady => true;

  @override
  String get localAddress => self;

  @override
  List<RelayFriend> acceptedFriends() => friends;

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];
}

/// Engines that hear each other through a queue of datagrams; a device
/// that is off hears nothing.
final class _Net {
  int now = 100 * _day;
  final Map<String, RelayEngine> engines = <String, RelayEngine>{};
  final Map<String, MemoryRelayStateStore> stores =
      <String, MemoryRelayStateStore>{};
  final Map<String, _Peers> peers = <String, _Peers>{};
  final Set<String> off = <String>{};
  final Queue<(String, String, Map<String, dynamic>)> _queue =
      Queue<(String, String, Map<String, dynamic>)>();

  /// Every datagram sent, for looking at what went where.
  final List<(String, String, Map<String, dynamic>)> sent =
      <(String, String, Map<String, dynamic>)>[];

  RelayEngine add(
    String address, {
    RelayDeviceClass kind = RelayDeviceClass.unknown,
    RelayDeviceClass Function()? kindOf,
    RelayConfig config = const RelayConfig(),
  }) {
    final MemoryRelayStateStore store = MemoryRelayStateStore();
    final _Peers p = _Peers(address, <RelayFriend>[]);
    final RelayEngine engine = RelayEngine(
      store: store,
      peers: p,
      send: (String to, Map<String, dynamic> payload) async {
        if (off.contains(address)) {
          return;
        }
        final Map<String, dynamic> copy =
            jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
        sent.add((address, to, copy));
        _queue.add((address, to, copy));
      },
      clock: () => now,
      deviceClass: kindOf ?? () => kind,
      config: config,
    );
    engines[address] = engine;
    stores[address] = store;
    peers[address] = p;
    return engine;
  }

  Future<void> settle() async {
    int steps = 0;
    while (_queue.isNotEmpty) {
      if (++steps > 20000) {
        fail('the network did not settle');
      }
      final (String from, String to, Map<String, dynamic> payload) = _queue
          .removeFirst();
      if (off.contains(to) || !engines.containsKey(to)) {
        continue;
      }
      await engines[to]!.handleIncoming(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: now,
        ),
      );
    }
  }

  /// Moves the clock on in [step]s, every engine that is on ticking.
  Future<void> advance(
    Duration total, {
    Duration step = const Duration(minutes: 5),
  }) async {
    final int end = now + total.inMilliseconds;
    while (now < end) {
      now += step.inMilliseconds;
      for (final MapEntry<String, RelayEngine> e in engines.entries) {
        if (!off.contains(e.key)) {
          await e.value.tick();
        }
      }
      await settle();
    }
  }

  Future<RelayState> state(String address) => stores[address]!.load();
}

void main() {
  RelayDeviceClass iphone(String _) => RelayDeviceClass.iphone;

  group('rankRelays', () {
    final int now = 100 * _day;

    test('free places go to friends whose device stays online first', () {
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 6; i++)
          RelayFriend(
            address: _a('c$i'),
            closeness: 2,
            lastSeenAtMillis: now - 1000,
          ),
        RelayFriend(address: _a('d1'), lastSeenAtMillis: now - 5000),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: const <String>[],
        friends: friends,
        deviceClass: (String a) =>
            a == _a('d1') ? RelayDeviceClass.android : RelayDeviceClass.iphone,
        nowMillis: now,
      );
      expect(picked, hasLength(6));
      expect(picked.first, _a('d1'));
    });

    test('a weak acquaintance does not jump the queue for staying online', () {
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 6; i++)
          RelayFriend(address: _a('c$i'), lastSeenAtMillis: now - 1000),
        RelayFriend(address: _a('w1'), closeness: 0, lastSeenAtMillis: now),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: const <String>[],
        friends: friends,
        deviceClass: (String a) =>
            a == _a('w1') ? RelayDeviceClass.desktop : RelayDeviceClass.iphone,
        nowMillis: now,
      );
      expect(picked, isNot(contains(_a('w1'))));
    });

    test('a device that stays online replaces one that does not, one at a '
        'time', () {
      final List<String> current = <String>[
        for (int i = 0; i < 6; i++) _a('i$i'),
      ];
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 6; i++)
          RelayFriend(address: _a('i$i'), lastSeenAtMillis: now - i * 1000),
        RelayFriend(address: _a('pc'), lastSeenAtMillis: now - 60000),
        RelayFriend(address: _a('pc2'), lastSeenAtMillis: now - 60000),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        deviceClass: (String a) => a == _a('pc') || a == _a('pc2')
            ? RelayDeviceClass.desktop
            : RelayDeviceClass.iphone,
        nowMillis: now,
      );
      expect(picked, hasLength(6));
      // Exactly one of the two computers came in, for the least recently
      // seen iPhone.
      expect(
        picked.where((String a) => a == _a('pc') || a == _a('pc2')),
        hasLength(1),
      );
      expect(picked, isNot(contains(_a('i5'))));
    });

    test('within a day of the last change nothing is replaced, but an empty '
        'place is still filled', () {
      final List<RelayFriend> friends = <RelayFriend>[
        RelayFriend(address: _a('i0'), lastSeenAtMillis: now),
        RelayFriend(address: _a('pc'), lastSeenAtMillis: now),
        RelayFriend(address: _a('pc2'), lastSeenAtMillis: now),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: <String>[_a('i0'), _a('gone')],
        friends: friends,
        deviceClass: (String a) =>
            a == _a('i0') ? RelayDeviceClass.iphone : RelayDeviceClass.desktop,
        nowMillis: now,
        config: const RelayConfig(maxRelays: 2),
        mayReplace: false,
      );
      expect(picked.first, _a('i0'), reason: 'kept: no change allowed now');
      expect(picked, hasLength(2));
      expect(picked.last, anyOf(_a('pc'), _a('pc2')));
    });

    test('kept relays stay while nothing better shows up (sticky)', () {
      final List<String> current = <String>[_a('i1'), _a('i0')];
      final List<RelayFriend> friends = <RelayFriend>[
        RelayFriend(address: _a('i0'), lastSeenAtMillis: now - 1000),
        RelayFriend(address: _a('i1'), lastSeenAtMillis: now - 2 * _day),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        deviceClass: iphone,
        nowMillis: now,
      );
      expect(picked, current);
    });

    test('a mailbox that answers is not replaced for a small difference', () {
      // An Android phone that missed a few polls against a computer nobody
      // has asked yet: not worth making every friend move its mail.
      final RelayReach phone = RelayReach(
        answered: 30,
        hours: 40,
        sampledAtMillis: now,
        heardAtMillis: now - _hour,
      );
      final List<String> picked = RelayEngine.rankRelays(
        current: <String>[_a('ph')],
        friends: <RelayFriend>[
          RelayFriend(address: _a('ph'), lastSeenAtMillis: now),
          RelayFriend(address: _a('pc'), lastSeenAtMillis: now),
        ],
        deviceClass: (String a) =>
            a == _a('ph') ? RelayDeviceClass.android : RelayDeviceClass.desktop,
        reach: (String a) => a == _a('ph') ? phone : null,
        nowMillis: now,
        config: const RelayConfig(maxRelays: 1),
      );
      expect(picked, <String>[_a('ph')]);
    });

    test('a mailbox that went quiet is replaced by one that answers, but not '
        'by an iPhone nobody has seen answer', () {
      final RelayReach gone = RelayReach(
        hours: 30,
        sampledAtMillis: now,
        heardAtMillis: now - 4 * _day,
        askedAtMillis: now - 60000,
        failingSinceMillis: now - 4 * _day + _hour,
      );
      List<String> pick(RelayDeviceClass other) => RelayEngine.rankRelays(
        current: <String>[_a('gone')],
        friends: <RelayFriend>[
          RelayFriend(address: _a('gone'), lastSeenAtMillis: now - 4 * _day),
          RelayFriend(address: _a('x'), lastSeenAtMillis: now - _hour),
        ],
        deviceClass: (String a) =>
            a == _a('gone') ? RelayDeviceClass.android : other,
        reach: (String a) => a == _a('gone') ? gone : null,
        nowMillis: now,
        config: const RelayConfig(maxRelays: 1),
      );
      expect(pick(RelayDeviceClass.android), <String>[_a('x')]);
      expect(pick(RelayDeviceClass.iphone), <String>[_a('gone')]);
    });

    test('coming back after days away does not make the mailboxes quiet with '
        'the first missed poll', () {
      // Last heard five days ago, but asked in vain only for the last hour:
      // this device was the one away.
      final RelayReach away = RelayReach(
        hours: 5,
        answered: 4,
        sampledAtMillis: now,
        heardAtMillis: now - 5 * _day,
        askedAtMillis: now - 60000,
        failingSinceMillis: now - _hour,
      );
      final List<String> picked = RelayEngine.rankRelays(
        current: <String>[_a('m')],
        friends: <RelayFriend>[
          RelayFriend(address: _a('m'), lastSeenAtMillis: now - 5 * _day),
          RelayFriend(address: _a('x'), lastSeenAtMillis: now),
        ],
        deviceClass: (String _) => RelayDeviceClass.android,
        reach: (String a) => a == _a('m') ? away : null,
        nowMillis: now,
        config: const RelayConfig(maxRelays: 1),
      );
      expect(picked, <String>[_a('m')]);
    });

    test('a relay not seen for days makes way for a friend seen lately', () {
      final List<String> current = <String>[
        for (int i = 0; i < 6; i++) _a('i$i'),
      ];
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 5; i++)
          RelayFriend(address: _a('i$i'), lastSeenAtMillis: now - 1000),
        RelayFriend(address: _a('i5'), lastSeenAtMillis: now - 10 * _day),
        RelayFriend(address: _a('new'), lastSeenAtMillis: now - 1000),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        deviceClass: (String _) => RelayDeviceClass.unknown,
        nowMillis: now,
      );
      expect(picked, contains(_a('new')));
      expect(picked, isNot(contains(_a('i5'))));
    });

    test('a stale relay stays when nobody fresher is there', () {
      final List<String> current = <String>[_a('i0')];
      final List<RelayFriend> friends = <RelayFriend>[
        RelayFriend(address: _a('i0'), lastSeenAtMillis: now - 10 * _day),
        RelayFriend(address: _a('i1'), lastSeenAtMillis: now - 20 * _day),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        deviceClass: iphone,
        nowMillis: now,
        config: const RelayConfig(maxRelays: 1),
      );
      expect(picked, <String>[_a('i0')]);
    });

    test('a former friend is dropped from the kept relays', () {
      final List<String> picked = RelayEngine.rankRelays(
        current: <String>[_a('gone'), _a('i0')],
        friends: <RelayFriend>[
          RelayFriend(address: _a('i0'), lastSeenAtMillis: now),
        ],
        deviceClass: iphone,
        nowMillis: now,
      );
      expect(picked, <String>[_a('i0')]);
    });
  });

  group('friends with several devices', () {
    final int now = 100 * _day;

    test('one device per friend, the best of theirs', () {
      // Bartek's entry is his iPhone; his computer is another device of
      // the same account.
      final List<String> picked = RelayEngine.rankRelays(
        current: const <String>[],
        friends: <RelayFriend>[
          RelayFriend(
            address: _a('b-phone'),
            devices: <String>[_a('b-pc')],
            lastSeenAtMillis: now,
          ),
        ],
        deviceClass: (String a) => a == _a('b-pc')
            ? RelayDeviceClass.desktop
            : RelayDeviceClass.iphone,
        nowMillis: now,
      );
      expect(picked, <String>[_a('b-pc')]);
    });

    test('a friend who moved to a new phone: the old one goes quiet even '
        'though the friend is seen on the new one, and the new one takes '
        'its place', () {
      final RelayReach old = RelayReach(
        hours: 40,
        sampledAtMillis: now,
        heardAtMillis: now - 5 * _day,
        askedAtMillis: now - 60000,
        failingSinceMillis: now - 5 * _day + 60000,
      );
      final RelayReach fresh = RelayReach(
        hours: 3,
        answered: 3,
        sampledAtMillis: now,
        heardAtMillis: now - 60000,
      );
      final List<String> picked = RelayEngine.rankRelays(
        current: <String>[_a('b-old'), _a('c')],
        friends: <RelayFriend>[
          // The friend's presence comes from the new phone: fresh.
          RelayFriend(
            address: _a('b-old'),
            devices: <String>[_a('b-new')],
            lastSeenAtMillis: now - 60000,
          ),
          RelayFriend(address: _a('c'), lastSeenAtMillis: now),
        ],
        deviceClass: (String _) => RelayDeviceClass.android,
        reach: (String a) => switch (a) {
          _ when a == _a('b-old') => old,
          _ when a == _a('b-new') => fresh,
          _ => null,
        },
        nowMillis: now,
      );
      expect(picked, <String>[_a('b-new'), _a('c')]);
    });

    test('two devices of one friend never hold the mail twice', () {
      final List<String> picked = RelayEngine.rankRelays(
        current: <String>[_a('b1'), _a('b2')],
        friends: <RelayFriend>[
          RelayFriend(address: _a('b1'), devices: <String>[_a('b2')]),
          RelayFriend(address: _a('c')),
        ],
        deviceClass: (String _) => RelayDeviceClass.android,
        nowMillis: now,
      );
      expect(picked, <String>[_a('b1'), _a('c')]);
    });
  });

  group('RelayReach', () {
    const Duration halfLife = Duration(days: 3);
    const Duration within = Duration(minutes: 2);

    test('counts by the hour: an hour with an answer, an hour without', () {
      final RelayReach r = RelayReach();
      // First hour: asked several times, answered.
      r.asked(1000, answerWithin: within, halfLife: halfLife);
      r.heard(2000, halfLife);
      r.asked(10 * 60000, answerWithin: within, halfLife: halfLife);
      r.heard(10 * 60000 + 500, halfLife);
      // Second hour: asked again and again, never answered.
      for (int m = 61; m < 120; m += 5) {
        r.asked(m * 60000, answerWithin: within, halfLife: halfLife);
      }
      expect(r.failingSinceMillis, 61 * 60000);
      // The third hour's first ask closes the second.
      r.asked(125 * 60000, answerWithin: within, halfLife: halfLife);
      expect(r.hoursAt(125 * 60000, halfLife), closeTo(2, 0.05));
      expect(r.answeredShare(125 * 60000, halfLife), closeTo(0.5, 0.02));
      r.heard(126 * 60000, halfLife);
      expect(r.failingSinceMillis, 0);
      expect(r.heardAtMillis, 126 * 60000);
    });

    test('old hours fade with the half-life, and the kind is worth a day', () {
      final RelayReach r = RelayReach(
        answered: 8,
        hours: 8,
        sampledAtMillis: 1,
      );
      expect(r.hoursAt(3 * _day + 1, halfLife), closeTo(4, 0.001));
      expect(
        r.quality(RelayDeviceClass.iphone, 1, halfLife),
        closeTo((8 + 24 * 0.15) / (8 + 24), 0.001),
      );
      expect(RelayReach().quality(RelayDeviceClass.desktop, 0, halfLife), 0.9);
      // A night off costs an Android phone little.
      final RelayReach night = RelayReach(
        answered: 16,
        hours: 24,
        sampledAtMillis: 1,
      );
      expect(
        RelayDeviceClass.desktop.prior -
            night.quality(RelayDeviceClass.android, 1, halfLife),
        lessThan(kMailboxQualityGap),
      );
    });

    test('survives the stored state', () {
      final RelayState state = RelayState(
        reach: <String, RelayReach>{
          'a': RelayReach(
            answered: 1.5,
            hours: 2,
            sampledAtMillis: 5,
            hourAtMillis: 4,
            hourAnswered: true,
            heardAtMillis: 6,
            askedAtMillis: 7,
            failingSinceMillis: 8,
          ),
        },
        mailboxChangedAtMillis: 9,
        announcedClass: 'pc',
        quietTold: <String, int>{'a': 6},
      );
      final RelayState back = RelayState.fromJsonString(state.toJsonString());
      final RelayReach r = back.reach['a']!;
      expect(
        <num>[
          r.answered,
          r.hours,
          r.sampledAtMillis,
          r.hourAtMillis,
          r.heardAtMillis,
          r.askedAtMillis,
          r.failingSinceMillis,
        ],
        <num>[1.5, 2, 5, 4, 6, 7, 8],
      );
      expect(r.hourAnswered, isTrue);
      expect(back.mailboxChangedAtMillis, 9);
      expect(back.announcedClass, 'pc');
      expect(back.quietTold, <String, int>{'a': 6});
    });
  });

  group('what kind of device it is, announced', () {
    test(
      'the announcement carries the kind and friends prefer a computer',
      () async {
        final String self = _a('1');
        final String computer = _a('pc');
        final List<RelayFriend> phones = <RelayFriend>[
          for (int i = 0; i < 6; i++)
            RelayFriend(address: _a('p$i'), lastSeenAtMillis: 5000 - i),
        ];
        final List<Map<String, dynamic>> sentByComputer =
            <Map<String, dynamic>>[];
        final RelayEngine computerEngine = RelayEngine(
          store: MemoryRelayStateStore(),
          peers: _Peers(computer, <RelayFriend>[RelayFriend(address: self)]),
          send: (String to, Map<String, dynamic> payload) async {
            sentByComputer.add(payload);
          },
          clock: () => 6000,
          deviceClass: () => RelayDeviceClass.desktop,
        );
        await computerEngine.activate();
        await computerEngine.tick();
        final Map<String, dynamic> announcement = sentByComputer.firstWhere(
          (Map<String, dynamic> p) => p['type'] == 'rly_announce',
        );
        expect(announcement['dc'], 'pc');

        final MemoryRelayStateStore store = MemoryRelayStateStore();
        final _Peers peers = _Peers(self, <RelayFriend>[
          ...phones,
          RelayFriend(address: computer, lastSeenAtMillis: 1000),
        ]);
        final RelayEngine engine = RelayEngine(
          store: store,
          peers: peers,
          send: (String to, Map<String, dynamic> payload) async {},
          clock: () => 6000,
        );
        await engine.activate();
        expect((await store.load()).currentRelays, isNot(contains(computer)));

        await engine.handleIncoming(
          SignalTransportFrame(
            from: computer,
            payload: announcement,
            receivedAtMillis: 6000,
          ),
        );
        await engine.tick();
        final RelayState state = await store.load();
        expect(state.peers[computer]?.deviceClass, RelayDeviceClass.desktop);
        expect(state.currentRelays, contains(computer));
        expect(state.currentRelays, hasLength(6));
        // The least recently seen phone made way.
        expect(state.currentRelays, isNot(contains(_a('p5'))));
      },
    );

    test(
      'an iPhone says it is one; a device of unknown kind says nothing',
      () async {
        Future<Map<String, dynamic>> announcementOf(
          RelayDeviceClass kind,
        ) async {
          final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
          final RelayEngine engine = RelayEngine(
            store: MemoryRelayStateStore(),
            peers: _Peers(_a('1'), <RelayFriend>[
              RelayFriend(address: _a('2')),
            ]),
            send: (String to, Map<String, dynamic> payload) async {
              sent.add(payload);
            },
            clock: () => 6000,
            deviceClass: () => kind,
          );
          await engine.activate();
          await engine.tick();
          return sent.firstWhere(
            (Map<String, dynamic> p) => p['type'] == 'rly_announce',
          );
        }

        expect((await announcementOf(RelayDeviceClass.iphone))['dc'], 'ios');
        expect(
          (await announcementOf(RelayDeviceClass.iphoneKeepAlive))['dc'],
          'ios_on',
        );
        expect(
          (await announcementOf(RelayDeviceClass.unknown)).containsKey('dc'),
          isFalse,
        );
      },
    );

    test(
      'switching the iPhone keep-alive on is announced to friends',
      () async {
        final _Net net = _Net();
        RelayDeviceClass kind = RelayDeviceClass.iphone;
        final RelayEngine me = net.add(_a('1'), kindOf: () => kind);
        final RelayEngine friend = net.add(_a('2'));
        net.peers[_a('1')]!.friends = <RelayFriend>[
          RelayFriend(address: _a('2')),
        ];
        net.peers[_a('2')]!.friends = <RelayFriend>[
          RelayFriend(address: _a('1')),
        ];
        await me.activate();
        await friend.activate();
        await net.advance(
          const Duration(minutes: 1),
          step: const Duration(seconds: 5),
        );
        expect(
          (await net.state(_a('2'))).peers[_a('1')]?.deviceClass,
          RelayDeviceClass.iphone,
        );
        kind = RelayDeviceClass.iphoneKeepAlive;
        await net.advance(
          const Duration(minutes: 3),
          step: const Duration(seconds: 5),
        );
        expect(
          (await net.state(_a('2'))).peers[_a('1')]?.deviceClass,
          RelayDeviceClass.iphoneKeepAlive,
        );
      },
    );

    test('the kind survives the stored state', () {
      const RelayPeerInfo info = RelayPeerInfo(
        address: '200::1',
        deviceClass: RelayDeviceClass.android,
      );
      expect(
        RelayPeerInfo.fromJson(info.toJson())?.deviceClass,
        RelayDeviceClass.android,
      );
      expect(
        RelayPeerInfo.fromJson(
          const RelayPeerInfo(address: '200::1').toJson(),
        )?.deviceClass,
        RelayDeviceClass.unknown,
      );
    });

    test('each platform says what it is', () {
      expect(
        zenPlatformDeviceClass(TargetPlatform.android, web: false),
        RelayDeviceClass.android,
      );
      expect(
        zenPlatformDeviceClass(TargetPlatform.iOS, web: false),
        RelayDeviceClass.iphone,
      );
      expect(
        zenPlatformDeviceClass(
          TargetPlatform.iOS,
          web: false,
          iosKeepAlive: true,
        ),
        RelayDeviceClass.iphoneKeepAlive,
      );
      for (final TargetPlatform desktop in <TargetPlatform>[
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        expect(
          zenPlatformDeviceClass(desktop, web: false),
          RelayDeviceClass.desktop,
        );
      }
      expect(
        zenPlatformDeviceClass(TargetPlatform.android, web: true),
        RelayDeviceClass.unknown,
      );
    });
  });

  group('watching the mailboxes', () {
    test(
      'a mailbox with nothing to hand over still answers a periodic poll',
      () async {
        final _Net net = _Net();
        final RelayEngine me = net.add(_a('1'));
        final RelayEngine box = net.add(
          _a('2'),
          kind: RelayDeviceClass.android,
        );
        net.peers[_a('1')]!.friends = <RelayFriend>[
          RelayFriend(address: _a('2')),
        ];
        net.peers[_a('2')]!.friends = <RelayFriend>[
          RelayFriend(address: _a('1')),
        ];
        await box.activate();
        await me.activate();
        await net.settle();
        await net.advance(const Duration(hours: 2));
        expect(
          net.sent.where(
            (s) =>
                s.$1 == _a('1') &&
                s.$3['type'] == 'rly_poll' &&
                s.$3['p'] == true,
          ),
          isNotEmpty,
        );
        expect(
          net.sent.where((s) => s.$1 == _a('2') && s.$3['type'] == 'rly_here'),
          isNotEmpty,
        );
        final RelayReach reach = (await net.state(_a('1'))).reach[_a('2')]!;
        expect(reach.answeredShare(net.now, const Duration(days: 3)), 1);
        expect(
          me.overview.value.candidates[_a('2')]?.deviceClass,
          RelayDeviceClass.android,
        );
        expect(me.overview.value.quiet, isEmpty);
      },
    );

    test('a hand-picked mailbox that stops answering for days is reported, '
        'once', () async {
      final _Net net = _Net();
      final RelayEngine me = net.add(_a('1'));
      final RelayEngine box = net.add(_a('2'), kind: RelayDeviceClass.iphone);
      net.peers[_a('1')]!.friends = <RelayFriend>[
        RelayFriend(address: _a('2')),
      ];
      net.peers[_a('2')]!.friends = <RelayFriend>[
        RelayFriend(address: _a('1')),
      ];
      await box.activate();
      await me.activate();
      await me.setManualRelays(<String>[_a('2')]);
      await net.settle();
      await net.advance(const Duration(hours: 1));
      expect(me.overview.value.quiet, isEmpty);

      net.off.add(_a('2'));
      box.deactivate();
      await net.advance(
        const Duration(days: 2),
        step: const Duration(minutes: 30),
      );
      expect(me.overview.value.quiet, isEmpty, reason: 'not three days yet');
      await net.advance(
        const Duration(days: 2),
        step: const Duration(minutes: 30),
      );
      final List<RelayQuietMailbox> quiet = me.overview.value.quiet;
      expect(quiet, hasLength(1));
      expect(quiet.single.device, _a('2'));
      expect(quiet.single.told, isFalse);
      expect(net.now - quiet.single.sinceMillis, greaterThan(3 * _day));

      await me.markQuietTold(quiet);
      expect(me.overview.value.quiet.single.told, isTrue);

      // Back: no longer quiet.
      net.off.remove(_a('2'));
      await box.activate();
      await net.advance(const Duration(minutes: 30));
      expect(me.overview.value.quiet, isEmpty);
    });

    test('the person is told once in the notifications, with the way to the '
        'picker', () async {
      final _Net net = _Net();
      final RelayEngine me = net.add(_a('1'));
      final RelayEngine box = net.add(_a('2'), kind: RelayDeviceClass.iphone);
      net.peers[_a('1')]!.friends = <RelayFriend>[
        RelayFriend(address: _a('2')),
      ];
      net.peers[_a('2')]!.friends = <RelayFriend>[
        RelayFriend(address: _a('1')),
      ];
      await box.activate();
      await me.activate();
      await me.setManualRelays(<String>[_a('2')]);
      await net.advance(const Duration(hours: 1));
      final List<InboxEntry> told = <InboxEntry>[];
      final RelayQuietWatch watch = RelayQuietWatch(
        engine: me,
        state: SocialHubState.empty,
        addToInbox: (InboxEntry entry) async => told.add(entry),
        now: () => net.now,
      );
      addTearDown(watch.dispose);

      net.off.add(_a('2'));
      box.deactivate();
      await net.advance(
        const Duration(days: 4),
        step: const Duration(minutes: 30),
      );
      await pumpEventQueue();
      expect(told, hasLength(1));
      expect(told.single.type, InboxEntryType.mailbox);
      expect(told.single.title, contains('nie odpowiada od 3 dni'));
      expect(
        runtimeRouteIntentFromRouteKey(
          id: 'x',
          routeKey: told.single.routeKey,
        )?.target,
        RuntimeRouteTarget.mailboxes,
      );
      // Days more of the same: not told again.
      await net.advance(
        const Duration(days: 1),
        step: const Duration(minutes: 30),
      );
      await pumpEventQueue();
      expect(told, hasLength(1));
    });

    test('the picker warns about an iPhone without the keep-alive only', () {
      RelayMailboxCandidate of(RelayDeviceClass kind) => RelayMailboxCandidate(
        friend: _a('2'),
        device: _a('2'),
        deviceClass: kind,
      );
      expect(isWeakMailbox(of(RelayDeviceClass.iphone)), isTrue);
      expect(isWeakMailbox(of(RelayDeviceClass.iphoneKeepAlive)), isFalse);
      expect(isWeakMailbox(of(RelayDeviceClass.android)), isFalse);
      expect(isWeakMailbox(null), isFalse);
      expect(quietForText(0, 4 * _day + _hour), 'od 4 dni');
      expect(quietForText(0, _day), 'od 1 dnia');
    });

    test('with nobody left to take their place, quiet mailboxes stay and the '
        'person is told', () async {
      final _Net net = _Net();
      final RelayEngine me = net.add(_a('1'));
      final List<String> boxes = <String>[_a('b1'), _a('b2')];
      for (final String a in boxes) {
        net.add(a, kind: RelayDeviceClass.android);
        net.peers[a]!.friends = <RelayFriend>[RelayFriend(address: _a('1'))];
        await net.engines[a]!.activate();
      }
      net.peers[_a('1')]!.friends = <RelayFriend>[
        for (final String a in boxes) RelayFriend(address: a),
      ];
      await me.activate();
      await net.settle();
      await net.advance(const Duration(minutes: 10));
      final RelayState before = await net.state(_a('1'));
      expect(before.currentRelays.toSet(), boxes.toSet());

      for (final String a in boxes) {
        net.off.add(a);
        net.engines[a]!.deactivate();
      }
      await net.advance(
        const Duration(days: 5),
        step: const Duration(minutes: 30),
      );
      final RelayState state = await net.state(_a('1'));
      expect(state.currentRelays, before.currentRelays);
      expect(state.relaySetVersion, before.relaySetVersion);
      expect(
        me.overview.value.quiet.map((RelayQuietMailbox q) => q.device).toSet(),
        boxes.toSet(),
      );
    });

    test('with spares there, quiet mailboxes are replaced by themselves, one '
        'per day', () async {
      final _Net net = _Net();
      final RelayEngine me = net.add(
        _a('1'),
        config: const RelayConfig(maxRelays: 2),
      );
      final List<String> boxes = <String>[_a('b1'), _a('b2')];
      final List<String> spares = <String>[_a('s1'), _a('s2')];
      for (final String a in <String>[...boxes, ...spares]) {
        net.add(a, kind: RelayDeviceClass.android);
        net.peers[a]!.friends = <RelayFriend>[RelayFriend(address: _a('1'))];
        await net.engines[a]!.activate();
      }
      // Two places: the close friends get them.
      net.peers[_a('1')]!.friends = <RelayFriend>[
        for (final String a in boxes) RelayFriend(address: a, closeness: 2),
        for (final String a in spares) RelayFriend(address: a),
      ];
      await me.activate();
      await net.settle();
      await net.advance(const Duration(minutes: 10));
      expect((await net.state(_a('1'))).currentRelays.toSet(), boxes.toSet());

      for (final String a in boxes) {
        net.off.add(a);
        net.engines[a]!.deactivate();
      }
      // Three days unheard and half a day of asking in vain: one goes.
      await net.advance(
        const Duration(days: 3, hours: 6),
        step: const Duration(minutes: 30),
      );
      List<String> current = (await net.state(_a('1'))).currentRelays;
      expect(current.where(spares.contains), hasLength(1));
      expect(
        me.overview.value.quiet,
        isEmpty,
        reason: 'the automatic choice handles it',
      );
      // The other only a day after the first.
      await net.advance(
        const Duration(hours: 12),
        step: const Duration(minutes: 30),
      );
      current = (await net.state(_a('1'))).currentRelays;
      expect(current.where(spares.contains), hasLength(1));
      await net.advance(
        const Duration(hours: 12),
        step: const Duration(minutes: 30),
      );
      current = (await net.state(_a('1'))).currentRelays;
      expect(current.toSet(), spares.toSet());
    });
  });
}
