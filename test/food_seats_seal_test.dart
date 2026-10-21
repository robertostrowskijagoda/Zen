import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/circle/food_model.dart';
import 'package:zen/src/features/meet/circle/food_seal.dart';
import 'package:zen/src/features/meet/circle/food_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_thread.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

const String _place = 'ul. Lipowa 3, II piętro';
const int hour = 3600 * 1000;

final class _Net {
  final Map<String, _Host> hosts = <String, _Host>{};
  final List<Future<void>> inflight = <Future<void>>[];
  int clock = DateTime(2026, 10, 1, 12).millisecondsSinceEpoch;

  Future<void> settle() async {
    while (inflight.isNotEmpty) {
      final List<Future<void>> now = List<Future<void>>.of(inflight);
      inflight.clear();
      await Future.wait(now);
    }
  }
}

final class _Host implements EventHost {
  _Host(
    this.net,
    this.name,
    List<String> friends, {
    List<String> close = const <String>[],
  }) : address = addr(name),
       friendList = friends.map(addr).toList(),
       closeList = close.map(addr).toList() {
    net.hosts[address] = this;
    circles = CircleService(host: this, disk: disk, now: () => net.clock);
    food = FoodService(
      host: this,
      disk: disk,
      circles: circles,
      closeFriends: () => closeList,
      now: () => net.clock,
    );
  }

  final _Net net;
  final String name;
  final String address;
  final List<String> friendList;
  final List<String> closeList;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late final CircleService circles;
  late final FoodService food;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  /// Everything this phone sent or received, as it went over the wire.
  final List<String> wire = <String>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final String json = jsonEncode(payload);
    wire.add(json);
    net.inflight.add(
      Future<void>(() async {
        final _Host? h = net.hosts[to];
        if (h == null) {
          return;
        }
        h.wire.add(json);
        final SignalTransportFrame frame = SignalTransportFrame(
          from: address,
          payload: jsonDecode(json) as Map<String, dynamic>,
          receivedAtMillis: 0,
        );
        if (!await h.circles.handle(frame)) {
          await h.food.handle(frame);
        }
      }),
    );
  }

  @override
  List<String> friends() => friendList;

  @override
  bool isFriend(String a) =>
      friendList.contains(PeerShareCodec.normalizeAddress(a));

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net.hosts[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  Iterable<String> get titles =>
      shown.map((RuntimeSystemNotification n) => n.title);
}

/// Ania (close friend: Bob) is friends with Bob and Ewa; Ewa with Filip and
/// Gosia, who do not know Ania.
final class _World {
  _World() {
    ania = _Host(net, 'a1', <String>['b2', 'e5'], close: <String>['b2']);
    bob = _Host(net, 'b2', <String>['a1']);
    ewa = _Host(net, 'e5', <String>['a1', 'f6', 'g7']);
    filip = _Host(net, 'f6', <String>['e5']);
    gosia = _Host(net, 'g7', <String>['e5']);
  }

  final _Net net = _Net();
  late final _Host ania;
  late final _Host bob;
  late final _Host ewa;
  late final _Host filip;
  late final _Host gosia;

  Future<FoodOffer?> seats({
    FoodReach reach = FoodReach.friendsOfFriends,
    Set<FoodMode> modes = const <FoodMode>{FoodMode.dineIn},
    int seats = 2,
  }) async {
    final FoodOffer? o = await ania.food.share(
      circleId: '',
      seats: true,
      title: 'Lazania',
      portions: seats,
      readyFrom: net.clock + hour,
      readyUntil: net.clock + 3 * hour,
      modes: modes,
      exchanges: const <FoodExchange>{FoodExchange.free},
      allergenInfo: FoodAllergenInfo.unknown,
      reach: reach,
      place: _place,
    );
    await net.settle();
    return o;
  }
}

void main() {
  test('the place opens only with the request\'s key; chat messages are '
      'bound to their direction', () async {
    final HybridKeyPair keys = await newFoodRequestKeys();
    final FoodPlaceSeal seal = await sealFoodPlace(
      offerId: 'o1',
      place: _place,
      publicKey: keys.publicKey,
    );
    expect(
      utf8.decode(seal.box, allowMalformed: true),
      isNot(contains('Lipowa')),
    );
    final (String, Uint8List)? opened = await openFoodPlace(
      offerId: 'o1',
      seed: keys.seed,
      kemCiphertext: seal.kemCiphertext,
      box: seal.box,
    );
    expect(opened!.$1, _place);
    expect(opened.$2, seal.chatKey);
    // Another key, another offer: nothing.
    final HybridKeyPair other = await newFoodRequestKeys();
    expect(
      await openFoodPlace(
        offerId: 'o1',
        seed: other.seed,
        kemCiphertext: seal.kemCiphertext,
        box: seal.box,
      ),
      isNull,
    );
    expect(
      await openFoodPlace(
        offerId: 'o2',
        seed: keys.seed,
        kemCiphertext: seal.kemCiphertext,
        box: seal.box,
      ),
      isNull,
    );
    final Uint8List box = await sealFoodChat(
      seal.chatKey,
      'o1',
      fromCook: true,
      json: <String, dynamic>{'m': 'x1', 'x': 'Dzwoń domofonem 12', 't': 1},
    );
    expect(
      (await openFoodChat(seal.chatKey, 'o1', fromCook: true, box: box))!['x'],
      'Dzwoń domofonem 12',
    );
    expect(
      await openFoodChat(seal.chatKey, 'o1', fromCook: false, box: box),
      isNull,
    );
  });

  test('"Gotuję dziś — dosiądź się": friends see it at once, a friend of a '
      'friend only through a friend who vouches; the friend in between '
      'never sees the place or the chat', () async {
    final _World w = _World();
    final FoodOffer o = (await w.seats())!;
    expect(o.seats, isTrue);
    expect(o.circleId, isEmpty);
    expect(w.bob.food.offer(o.id)!.seats, isTrue);
    expect(w.bob.titles, contains('a1 gotuje dziś — dosiądź się: Lazania'));
    expect(w.filip.food.viaOf(o.id), w.ewa.address);

    // Filip asks; it waits at Ewa's for "Ręczę".
    expect(
      await w.filip.food.ask(
        o.id,
        mode: FoodMode.dineIn,
        exchange: FoodExchange.free,
      ),
      isTrue,
    );
    expect(
      await w.gosia.food.ask(
        o.id,
        mode: FoodMode.dineIn,
        exchange: FoodExchange.free,
      ),
      isTrue,
    );
    await w.net.settle();
    expect(w.ania.food.offer(o.id)!.requests, isEmpty);
    expect(
      w.ewa.food.toVouch.map(((FoodOffer, String, String) v) => v.$2),
      containsAll(<String>[w.filip.address, w.gosia.address]),
    );
    expect(w.ewa.titles, contains('f6 chce się dosiąść u a1'));

    // Ewa vouches for Filip, not for Gosia.
    await w.ewa.food.vouch(o.id, w.filip.address, true);
    await w.ewa.food.vouch(o.id, w.gosia.address, false);
    await w.net.settle();
    expect(w.ewa.food.toVouch, isEmpty);
    expect(w.gosia.food.myRequest(o.id)!.state, FoodRequestState.declined);
    final FoodRequest r = w.ania.food.offer(o.id)!.requests.values.single;
    expect(r.address, w.filip.address);
    expect(r.vouched, isTrue);
    expect(r.via, w.ewa.address);
    expect(w.ania.titles, contains('f6 chce się dosiąść: Lazania'));

    // Accepted: the place reaches Filip, sealed all the way.
    expect(await w.ania.food.accept(o.id, w.filip.address), isTrue);
    await w.net.settle();
    expect(w.filip.food.myRequest(o.id)!.state, FoodRequestState.accepted);
    expect(w.filip.food.myRequest(o.id)!.place, _place);
    expect(w.ewa.wire.any((String f) => f.contains('Lipowa')), isFalse);
    final List<int>? ewaDisk = await w.ewa.disk.read('meet/food');
    expect(utf8.decode(ewaDisk!).contains('Lipowa'), isFalse);
    expect(w.ewa.food.offer(o.id)!.place, isEmpty);

    // Their small chat goes through Ewa too, and she cannot read it.
    expect(w.filip.food.canChat(o.id), isTrue);
    expect(w.ewa.food.canChat(o.id), isFalse);
    expect(await w.filip.food.sendChat(o.id, 'Spóźnię się 10 min'), isTrue);
    await w.net.settle();
    final List<MeetThreadMessage> atAnia = w.ania.food.thread(
      o.id,
      who: w.filip.address,
    );
    expect(atAnia.single.text, 'Spóźnię się 10 min');
    expect(w.ania.food.unread(o.id, who: w.filip.address), 1);
    w.net.clock += 1000;
    expect(
      await w.ania.food.sendChat(
        o.id,
        'Dzwoń domofonem 12',
        who: w.filip.address,
      ),
      isTrue,
    );
    await w.net.settle();
    expect(
      w.filip.food.thread(o.id).map((MeetThreadMessage m) => m.text),
      <String>['Spóźnię się 10 min', 'Dzwoń domofonem 12'],
    );
    expect(w.filip.food.unread(o.id), 1);
    await w.filip.food.markRead(o.id);
    expect(w.filip.food.unread(o.id), 0);
    expect(
      w.ewa.wire.any(
        (String f) => f.contains('Spóźnię') || f.contains('domofonem'),
      ),
      isFalse,
    );
    expect(w.ewa.food.thread(o.id), isEmpty);
    // Bob was never accepted: no chat.
    expect(w.bob.food.canChat(o.id), isFalse);
    expect(await w.bob.food.sendChat(o.id, 'Hej'), isFalse);
  });

  test('free seats: eaten at the table only, a circle or a reach beyond it, '
      'close friends only when chosen', () async {
    final _World w = _World();
    expect(await w.seats(modes: const <FoodMode>{FoodMode.takeaway}), isNull);
    expect(await w.seats(reach: FoodReach.circle), isNull);
    // Food (not seats) still needs a circle.
    expect(
      await w.ania.food.share(
        circleId: '',
        title: 'Zupa',
        portions: 2,
        readyFrom: w.net.clock,
        readyUntil: w.net.clock + hour,
        modes: const <FoodMode>{FoodMode.takeaway},
        exchanges: const <FoodExchange>{FoodExchange.free},
        allergenInfo: FoodAllergenInfo.none,
        reach: FoodReach.friends,
      ),
      isNull,
    );
    final FoodOffer close = (await w.seats(reach: FoodReach.close))!;
    expect(w.bob.food.offer(close.id), isNotNull);
    expect(w.ewa.food.offer(close.id), isNull);
    expect(w.filip.food.offer(close.id), isNull);
    // Someone who is not a close friend cannot ask for it either.
    await w.ewa.send(w.ania.address, <String, dynamic>{
      'type': FoodTypes.request,
      'id': close.id,
      'n': 1,
      'm': FoodMode.dineIn.code,
      'x': FoodExchange.free.code,
      'ek': foodB64((await newFoodRequestKeys()).publicKey),
    });
    await w.net.settle();
    expect(w.ania.food.offer(close.id)!.requests, isEmpty);
    // A request without a key for the place is not taken.
    await w.bob.send(w.ania.address, <String, dynamic>{
      'type': FoodTypes.request,
      'id': close.id,
      'n': 1,
      'm': FoodMode.dineIn.code,
      'x': FoodExchange.free.code,
    });
    await w.net.settle();
    expect(w.ania.food.offer(close.id)!.requests, isEmpty);
    expect(
      await w.bob.food.ask(
        close.id,
        mode: FoodMode.dineIn,
        exchange: FoodExchange.free,
      ),
      isTrue,
    );
    await w.net.settle();
    expect(w.ania.food.offer(close.id)!.requests.keys.single, w.bob.address);

    final FoodOffer friends = (await w.seats(reach: FoodReach.friends))!;
    expect(w.ewa.food.offer(friends.id), isNotNull);
    expect(w.filip.food.offer(friends.id), isNull);
  });
}
