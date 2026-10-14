import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// Friends of friends (B1/B2): lists kept apart from the book, frames that
/// came too early, and lists lost on the way asked for again.
final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};

  /// Frames are dropped while this is false (a lost frame, an ack too early).
  bool deliver = true;
}

final class _Phone implements MeetHost {
  _Phone(this.net, this.address, List<String> friends)
    : friendList = <String>[...friends],
      disk = MemoryLedgerDisk() {
    net.phones[address] = this;
    service = MeetService(host: this, store: MeetStore(disk), now: () => clock)
      ..friendNames = () => <String, String>{
        for (final String f in friendList) f: f.toUpperCase(),
      };
  }

  final _Net net;
  final String address;
  final List<String> friendList;
  final MemoryLedgerDisk disk;
  late final MeetService service;
  int clock = 1000;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    if (!net.deliver) {
      return;
    }
    await net.phones[to]?.service.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  /// A ping to [friend] carrying the hello digests.
  Future<void> ping(_Phone friend) => friend.service.handle(
    SignalTransportFrame(
      from: address,
      payload: <String, dynamic>{
        'type': 'ping',
        ...service.helloFor(friend.address),
      },
      receivedAtMillis: 0,
    ),
  );

  Map<String, String> get names => <String, String>{
    for (final String f in friendList) f: f.toUpperCase(),
  };

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  bool isSelf(String a) => a == address;

  @override
  String nameOf(String a) => a.toUpperCase();

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

void main() {
  test('a friend list lives in its own file, with limits', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await bob.service.handle(
      SignalTransportFrame(
        from: 'ania',
        payload: <String, dynamic>{
          'type': MeetTypes.friendList,
          'l': <Object>[
            <String, String>{'a': 'cyryl', 'n': 'Cyryl ${'x' * 500}'},
            <String, String>{'a': 'zły adres z spacjami', 'n': 'Ewa'},
            <String, String>{'a': 'bob', 'n': 'Ja'},
          ],
          'd': 'abc',
        },
        receivedAtMillis: 0,
      ),
    );
    final Map<String, String> list = bob.service.book.friendsOf('ania');
    expect(list.keys, <String>['cyryl']);
    expect(list['cyryl']!.length, lessThanOrEqualTo(60));
    // The book itself does not carry the list.
    final String book = utf8.decode(bob.disk.files[MeetStore.key]!);
    expect(book, isNot(contains('cyryl')));
    expect(bob.disk.files.containsKey(MeetStore.listKey('ania')), isTrue);
    // Read back from disk.
    final MeetService again = MeetService(
      host: bob,
      store: MeetStore(bob.disk),
    );
    await again.reload();
    expect(again.book.friendsOf('ania').keys, <String>['cyryl']);
    expect(ania.sent, isEmpty);
  });

  test('frames that came before the friendship are handled after', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob', 'cyryl']);
    // Bob has not accepted yet (his accept is still in the queue).
    final _Phone bob = _Phone(net, 'bob', <String>[]);
    await ania.service.shareFriendList(ania.names);
    expect(bob.service.book.friendsOf('ania'), isEmpty);

    bob.friendList.add('ania');
    await bob.service.replayParked('ania');
    expect(bob.service.book.friendsOf('ania').keys, <String>['cyryl']);
  });

  test('a list lost on the way is asked for again', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob', 'cyryl']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    net.deliver = false;
    await ania.service.shareFriendList(ania.names);
    net.deliver = true;
    expect(bob.service.book.friendsOf('ania'), isEmpty);

    // Ania's next ping says what she sent; Bob sees it is missing.
    await ania.ping(bob);
    expect(bob.service.book.friendsOf('ania').keys, <String>['cyryl']);
    expect(
      bob.sent.where((Map<String, dynamic> p) => p['type'] == 'meet_req'),
      hasLength(1),
    );

    // Everything matches now: no more asking.
    await ania.ping(bob);
    expect(
      bob.sent.where((Map<String, dynamic> p) => p['type'] == 'meet_req'),
      hasLength(1),
    );
  });

  test('a nearby key and a status lost on the way come again', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    net.deliver = false;
    await ania.service.shareNearbySecret('bob');
    await ania.service.setMyIntent(
      const IntentStatus(kind: IntentKind.talk, setAt: 1000, until: 9000),
    );
    net.deliver = true;
    expect(bob.service.book.friendNearbySecrets['ania'], isNull);

    await ania.ping(bob);
    expect(
      bob.service.book.friendNearbySecrets['ania'],
      ania.service.book.nearbySecret,
    );
    expect(bob.service.book.intentOf('ania', 1500)?.kind, IntentKind.talk);
  });
}
