import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/relay/relay_engine.dart'
    show kReliablePayloadTypes;
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

final class _Host implements MeetHost {
  _Host(this.mine);

  final List<String> mine;
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

  List<Map<String, dynamic>> to(String a) => <Map<String, dynamic>>[
    for (final (String who, Map<String, dynamic> p) in sent)
      if (who == a) p,
  ];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async =>
      sent.add((to, payload));

  @override
  List<String> friends() => mine;

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => mine.contains(PeerShareCodec.normalizeAddress(a));

  @override
  bool isSelf(String a) => false;

  @override
  String nameOf(String a) => 'Ktoś';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

SignalTransportFrame _frame(String from, Map<String, dynamic> body) =>
    SignalTransportFrame(
      from: from,
      payload: <String, dynamic>{'type': OpenToMeetService.frameType, ...body},
      receivedAtMillis: 0,
    );

void main() {
  final String ania = addr('a1');
  final String hidden = addr('b2');
  final String weak = addr('c3');
  final String yeti = addr('d4');
  final String zosia = addr('e5');
  final String quiet = addr('f6');
  final String stranger = addr('99');

  test('the intention follows the dating profile and is off by default', () {
    expect(OpenToMeet.forIntent(DatingIntent.dates), OpenToMeet.dates);
    expect(OpenToMeet.forIntent(DatingIntent.friends), OpenToMeet.friends);
    expect(OpenToMeet.forIntent(DatingIntent.both), OpenToMeet.both);
    final OpenToMeetService s = OpenToMeetService(
      host: _Host(<String>[ania]),
      disk: MemoryLedgerDisk(),
    );
    expect(s.mine, isNull);
    expect(s.payloadFor(ania).keys, <String>['type']);
    // A friend offline now still gets it.
    expect(kReliablePayloadTypes, contains(OpenToMeetService.frameType));
  });

  test(
    'own flag: friends get it, people it is hidden from and weak '
    'acquaintances never; unchanged is not sent again; off is taken back',
    () async {
      final _Host host = _Host(<String>[ania, hidden, weak]);
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final OpenToMeetService s = OpenToMeetService(
        host: host,
        disk: disk,
        isWeak: (String a) => a == weak,
        hiddenFrom: () => <String>{hidden},
      );
      await s.setMine(OpenToMeet.dates, hiddenFrom: <String>[hidden]);
      expect(host.to(ania).single['o'], 'd');
      // The hidden person and the weak acquaintance: a friend who passes the
      // flag on keeps it from both.
      expect(host.to(ania).single['ex'], hasLength(2));
      final FriendOpenness atAnia = FriendOpenness.fromJson(
        host.to(ania).single,
      );
      expect(atAnia.reaches(hidden), isFalse);
      expect(atAnia.reaches(weak), isFalse);
      expect(atAnia.reaches(yeti), isTrue);
      expect(
        host.to(ania).single.containsKey('r'),
        isFalse,
        reason: 'no friend list shown: nobody passed on',
      );
      expect(host.to(hidden), isEmpty);
      expect(host.to(weak), isEmpty);

      await s.shareAll();
      expect(host.sent, hasLength(1), reason: 'nothing changed');

      // Kept on disk.
      final OpenToMeetService again = OpenToMeetService(host: host, disk: disk);
      await again.load();
      expect(again.mine, OpenToMeet.dates);

      await s.setMine(null);
      expect(host.to(ania), hasLength(2));
      expect(host.to(ania).last.keys, <String>['type'], reason: 'forget it');
      expect(host.to(hidden), isEmpty);
    },
  );

  test('a friend passes a flag on only to friends who see their list and '
      'are not hidden from it', () async {
    final _Host host = _Host(<String>[yeti, zosia, hidden, quiet]);
    final OpenToMeetService s = OpenToMeetService(
      host: host,
      disk: MemoryLedgerDisk(),
      // Quiet does not see this person's friend list.
      listVisibleTo: (String a) => a != quiet,
    );
    // Yeti is open to both and hides it from `hidden`.
    await s.handle(
      _frame(yeti, <String, dynamic>{
        'o': 'b',
        'xs': 'salt',
        'ex': <String>[openHideHash('salt', hidden)],
      }),
    );
    expect(s.openOf(yeti), OpenToMeet.both);
    // Yeti's flag changed here: friends who may see it were told, with
    // Yeti's hide list, so it can go one step further.
    final Map<dynamic, dynamic> toZosia =
        host.to(zosia).single['r'] as Map<dynamic, dynamic>;
    expect(toZosia.keys, <String>[yeti]);
    expect(toZosia[yeti]['o'], 'b');
    expect(toZosia[yeti]['h'], 1);
    expect(toZosia[yeti]['xs'], 'salt');
    expect(RelayedOpen.fromJson(toZosia[yeti])!.reaches(hidden), isFalse);
    expect(host.to(hidden), isEmpty);
    expect(host.to(quiet), isEmpty);
    expect(host.to(yeti), isEmpty, reason: 'never back to Yeti');
    expect(s.payloadFor(hidden).containsKey('r'), isFalse);
    expect(s.payloadFor(quiet).containsKey('r'), isFalse);
  });

  test('a hide list too long for a flag: the flag goes no further than the '
      'friend', () async {
    final List<String> many = <String>[
      for (int i = 0; i <= kOpenMaxHidden; i++) addr('7${i.toRadixString(16)}'),
    ];
    final _Host host = _Host(<String>[ania]);
    final OpenToMeetService s = OpenToMeetService(
      host: host,
      disk: MemoryLedgerDisk(),
      hiddenFrom: () => many.toSet(),
    );
    await s.setMine(OpenToMeet.dates, hiddenFrom: many);
    final Map<String, dynamic> sent = host.to(ania).single;
    expect(sent['ex'], hasLength(kOpenMaxHidden));
    expect(sent['nr'], isTrue);
    final FriendOpenness atAnia = FriendOpenness.fromJson(sent);
    expect(atAnia.reaches(yeti), isFalse, reason: 'passed on to nobody');

    // A friend that relays: a flag marked so is not passed on.
    final _Host relay = _Host(<String>[yeti, zosia]);
    final OpenToMeetService r = OpenToMeetService(
      host: relay,
      disk: MemoryLedgerDisk(),
      listVisibleTo: (String a) => true,
    );
    await r.handle(
      _frame(yeti, <String, dynamic>{
        'o': 'd',
        'xs': 'salt',
        'ex': <String>[openHideHash('salt', hidden)],
        'nr': true,
      }),
    );
    expect(r.openOf(yeti), OpenToMeet.dates);
    expect(r.payloadFor(zosia).containsKey('r'), isFalse);
  });

  test('on the receiving side: a friend of a friend shows what friends '
      'passed on, a friend only their own word, strangers nothing', () async {
    final _Host host = _Host(<String>[ania, yeti]);
    final OpenToMeetService s = OpenToMeetService(
      host: host,
      disk: MemoryLedgerDisk(),
    );
    // Ania passes on Zosia (a friend of a friend) and Yeti (also a friend
    // here, who did not tell this phone).
    await s.handle(
      _frame(ania, <String, dynamic>{
        'r': <String, String>{zosia: 'f', yeti: 'd'},
      }),
    );
    expect(s.openOf(zosia), OpenToMeet.friends);
    expect(s.openOf(yeti), isNull, reason: 'a friend tells it themselves');
    expect(s.openOf(ania), isNull);
    // A stranger's frame is not taken.
    await s.handle(
      _frame(stranger, <String, dynamic>{
        'o': 'd',
        'r': <String, String>{quiet: 'd'},
      }),
    );
    expect(s.openOf(stranger), isNull);
    expect(s.openOf(quiet), isNull);
    // Ania stops passing it on: it is gone.
    await s.handle(_frame(ania, const <String, dynamic>{}));
    expect(s.openOf(zosia), isNull);
  });

  test('a flag goes three steps: a friend of a friend passes it on once more '
      '(checking the hide list), and far people show for the graph', () async {
    final String fof = addr('a7');
    final String far = addr('a8');
    final _Host host = _Host(<String>[ania, zosia, hidden]);
    final OpenToMeetService s = OpenToMeetService(
      host: host,
      disk: MemoryLedgerDisk(),
      listVisibleTo: (String a) => true,
    );
    // Ania passes on her friend Yeti (hidden from `hidden`) and someone
    // three steps from here, known to her friend of a friend.
    await s.handle(
      _frame(ania, <String, dynamic>{
        'r': <String, dynamic>{
          yeti: <String, dynamic>{
            'o': 'd',
            'n': 'Yeti',
            'h': 1,
            'xs': 'salt',
            'ex': <String>[openHideHash('salt', hidden)],
          },
          far: <String, dynamic>{'o': 'b', 'n': 'Daleki', 'h': 2, 'v': fof},
        },
      }),
    );
    expect(s.openOf(yeti), OpenToMeet.dates);
    expect(s.openOf(far), OpenToMeet.both);
    // Yeti goes on to Zosia as three steps away from her, known to Ania;
    // never to the one Yeti hides from, never further than that.
    final Map<dynamic, dynamic> toZosia =
        s.payloadFor(zosia)['r'] as Map<dynamic, dynamic>;
    expect(toZosia[yeti]['h'], 2);
    expect(toZosia[yeti]['v'], ania);
    expect(toZosia[yeti].containsKey('ex'), isFalse);
    expect(RelayedOpen.fromJson(toZosia[yeti])!.reaches(quiet), isFalse);
    expect(toZosia.containsKey(far), isFalse, reason: 'three steps is all');
    expect(
      (s.payloadFor(hidden)['r'] as Map?)?.containsKey(yeti) ?? false,
      isFalse,
    );
    // For the graph's far ring: who is three steps away, and who knows them.
    final Map<String, ({String name, Set<String> via})> farOnes = s.farOpen();
    expect(farOnes.keys, <String>[far]);
    expect(farOnes[far]!.name, 'Daleki');
    expect(farOnes[far]!.via, <String>{fof});
  });

  test('people across an opened gate get the flag and theirs is taken, '
      'never passed further', () async {
    final String gate = addr('9a');
    final String behind = addr('9b');
    final _Host host = _Host(<String>[ania]);
    final OpenToMeetService s = OpenToMeetService(
      host: host,
      disk: MemoryLedgerDisk(),
      listVisibleTo: (String a) => true,
      gateContacts: () => <String>{gate},
    );
    await s.setMine(OpenToMeet.friends);
    expect(host.to(gate).single['o'], 'f');
    await s.handle(
      _frame(gate, <String, dynamic>{
        'o': 'd',
        'xs': 's',
        'r': <String, String>{behind: 'b'},
      }),
    );
    expect(s.openOf(gate), OpenToMeet.dates);
    expect(s.openOf(behind), OpenToMeet.both);
    final Map<String, ({String name, Set<String> via})> farOnes = s.farOpen();
    expect(farOnes.keys.toSet(), <String>{gate, behind});
    expect(farOnes[behind]!.via, <String>{gate});
    // Not passed on to friends.
    expect(s.payloadFor(ania).containsKey('r'), isFalse);
    // A stranger is still not listened to.
    await s.handle(_frame(stranger, <String, dynamic>{'o': 'd'}));
    expect(s.openOf(stranger), isNull);
  });
}
