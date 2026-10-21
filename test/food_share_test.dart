import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/circle/food_model.dart';
import 'package:zen/src/features/meet/circle/food_points.dart';
import 'package:zen/src/features/meet/circle/food_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/relay/relay_engine.dart'
    show kReliablePayloadTypes;
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

final int t0 = DateTime(2026, 10, 1, 12).millisecondsSinceEpoch;
const int hour = 3600 * 1000;

/// Phones that deliver to each other on the event loop (like the mesh:
/// sending never waits for the other phone's handling).
final class _Net {
  final Map<String, _Host> hosts = <String, _Host>{};
  final List<Future<void>> inflight = <Future<void>>[];
  int clock = t0;

  Future<void> settle() async {
    while (inflight.isNotEmpty) {
      final List<Future<void>> now = List<Future<void>>.of(inflight);
      inflight.clear();
      await Future.wait(now);
    }
  }
}

/// Payment orders as the pyramid has them (the phones of one test share
/// it): an order is in once let through.
final class _Ledger {
  final List<(String, String, String, int)> orders =
      <(String, String, String, int)>[];
  final List<(String, String, String, int)> waiting =
      <(String, String, String, int)>[];
  int _seq = 0;

  void letThrough() {
    orders.addAll(waiting);
    waiting.clear();
  }
}

/// Pyramid points as the food code sees them.
final class _Points implements FoodPoints {
  _Points(this.myKey, {this.balance = 0, _Ledger? ledger})
    : ledger = ledger ?? _Ledger();

  @override
  final String? myKey;
  int balance;
  final _Ledger ledger;
  final List<(String, int, String)> paid = <(String, int, String)>[];

  @override
  String? get pyramid => myKey == null ? null : 'py1';

  @override
  bool canPay(String key, {String? pyramid}) =>
      myKey != null &&
      key != myKey &&
      key.startsWith('pk-') &&
      (pyramid == null || pyramid == 'py1') &&
      balance > 0;

  @override
  Future<String?> pay(
    String key,
    int amount, {
    required String memo,
    String? pyramid,
  }) async {
    if (!canPay(key, pyramid: pyramid) || amount > balance) {
      return null;
    }
    balance -= amount;
    paid.add((key, amount, memo));
    final String id = 'order${ledger._seq++}';
    ledger.waiting.add((id, myKey!, key, amount));
    return id;
  }

  @override
  bool received(String order, {required String from, required int amount}) =>
      ledger.orders.any(
        ((String, String, String, int) o) =>
            o.$1 == order && o.$2 == from && o.$3 == myKey && o.$4 >= amount,
      );

  @override
  String format(int amount) => (amount / 100).toStringAsFixed(2);
}

final class _Host implements EventHost {
  _Host(
    this.net,
    this.name,
    List<String> friends, {
    FoodPoints points = const NoFoodPoints(),
    MemoryLedgerDisk? disk,
  }) : address = addr(name),
       friendList = friends.map(addr).toList(),
       disk = disk ?? MemoryLedgerDisk() {
    net.hosts[address] = this;
    circles = CircleService(host: this, disk: this.disk, now: () => net.clock);
    food = FoodService(
      host: this,
      disk: this.disk,
      circles: circles,
      points: points,
      now: () => net.clock,
    );
  }

  final _Net net;
  final String name;
  final String address;
  final List<String> friendList;
  final MemoryLedgerDisk disk;
  late final CircleService circles;
  late final FoodService food;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add((to, payload));
    final Map<String, dynamic> copy =
        jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    net.inflight.add(
      Future<void>(() async {
        final _Host? h = net.hosts[to];
        if (h == null) {
          return;
        }
        final SignalTransportFrame frame = SignalTransportFrame(
          from: address,
          payload: copy,
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

/// Ania's circle with Bob, Cela and Dina (Ania is friends with all; the
/// others only with her); Ewa is a friend of Ania outside the circle and
/// Filip a friend of Ewa only.
final class _World {
  _World({
    FoodPoints? aniaPoints,
    FoodPoints? bobPoints,
    FoodPoints? celaPoints,
  }) {
    ania = _Host(net, 'a1', <String>[
      'b2',
      'c3',
      'd4',
      'e5',
    ], points: aniaPoints ?? const NoFoodPoints());
    bob = _Host(net, 'b2', <String>[
      'a1',
    ], points: bobPoints ?? const NoFoodPoints());
    cela = _Host(net, 'c3', <String>[
      'a1',
    ], points: celaPoints ?? const NoFoodPoints());
    dina = _Host(net, 'd4', <String>['a1']);
    ewa = _Host(net, 'e5', <String>['a1', 'f6']);
    filip = _Host(net, 'f6', <String>['e5']);
  }

  final _Net net = _Net();
  late final _Host ania;
  late final _Host bob;
  late final _Host cela;
  late final _Host dina;
  late final _Host ewa;
  late final _Host filip;
  late final DinnerCircle circle;

  Future<void> start() async {
    circle = await ania.circles.create(
      name: 'Czwartki',
      friends: <String>[bob.address, cela.address, dina.address],
      weekday: DateTime.thursday,
      hour: 19,
      firstDinner: DateTime(2026, 10, 1),
    );
    await net.settle();
    // Everyone says "Dołączam".
    for (final _Host h in <_Host>[bob, cela, dina]) {
      await h.circles.answerInvite(circle.id, true);
      await net.settle();
    }
  }

  Future<FoodOffer> share(
    _Host who, {
    String title = 'Pierogi',
    int portions = 3,
    Set<FoodMode> modes = const <FoodMode>{FoodMode.takeaway, FoodMode.dineIn},
    Set<FoodExchange> exchanges = const <FoodExchange>{
      FoodExchange.free,
      FoodExchange.swap,
    },
    FoodReach reach = FoodReach.circle,
    int points = 0,
  }) async {
    final FoodOffer? o = await who.food.share(
      circleId: circle.id,
      title: title,
      portions: portions,
      readyFrom: net.clock,
      readyUntil: net.clock + 4 * hour,
      modes: modes,
      exchanges: exchanges,
      allergenInfo: FoodAllergenInfo.listed,
      allergens: <FoodAllergen>{FoodAllergen.gluten},
      diet: <FoodDiet>{FoodDiet.vegetarian},
      pointsPerPortion: points,
      reach: reach,
      place: 'ul. Lipowa 3, II piętro',
    );
    expect(o, isNotNull);
    await net.settle();
    return o!;
  }
}

void main() {
  test('food payload types are delivered reliably', () {
    expect(kReliablePayloadTypes, containsAll(FoodTypes.all));
  });

  test('an offer: requests, accept/decline, portions, hand-over, no-show, '
      'expiry', () async {
    final _World w = _World();
    await w.start();
    final FoodOffer o = await w.share(w.ania);

    // The circle sees it, with a notification; the place stays with Ania.
    for (final _Host h in <_Host>[w.bob, w.cela, w.dina]) {
      expect(h.food.offers().single.id, o.id, reason: h.name);
      expect(h.food.offer(o.id)!.place, isEmpty);
      expect(h.titles, contains('a1 dzieli się jedzeniem: Pierogi'));
    }
    expect(
      w.net.hosts.values
          .expand((_Host h) => h.sent)
          .where((s) => s.$2['type'] == FoodTypes.offer)
          .every((s) => !jsonEncode(s.$2).contains('Lipowa')),
      isTrue,
    );
    // A circle offer does not reach a friend outside the circle.
    expect(w.ewa.food.offers(), isEmpty);

    // "Biorę": a way of taking and an exchange the cook offers.
    expect(
      await w.bob.food.ask(
        o.id,
        mode: FoodMode.takeaway,
        exchange: FoodExchange.points,
      ),
      isFalse,
    );
    expect(
      await w.bob.food.ask(
        o.id,
        mode: FoodMode.takeaway,
        exchange: FoodExchange.free,
        portions: 2,
      ),
      isTrue,
    );
    // One request per person.
    expect(
      await w.bob.food.ask(
        o.id,
        mode: FoodMode.dineIn,
        exchange: FoodExchange.free,
      ),
      isFalse,
    );
    expect(
      await w.cela.food.ask(
        o.id,
        mode: FoodMode.dineIn,
        exchange: FoodExchange.swap,
        portions: 2,
      ),
      isTrue,
    );
    await w.net.settle();
    expect(w.ania.food.offer(o.id)!.requests, hasLength(2));
    expect(w.ania.food.pendingForMe, 2);
    expect(w.ania.titles, contains('b2 prosi o jedzenie: Pierogi'));

    // Accepting counts the portions down for everyone; the place goes to
    // the accepted one only.
    expect(await w.ania.food.accept(o.id, w.bob.address), isTrue);
    await w.net.settle();
    expect(w.ania.food.offer(o.id)!.left, 1);
    expect(w.dina.food.offer(o.id)!.left, 1);
    expect(w.bob.food.myRequest(o.id)!.state, FoodRequestState.accepted);
    expect(w.bob.food.myRequest(o.id)!.place, 'ul. Lipowa 3, II piętro');
    expect(w.bob.titles, contains('Przyjęte: Pierogi'));
    expect(w.cela.food.myRequest(o.id)!.place, isEmpty);

    // Two portions no longer fit.
    expect(await w.ania.food.accept(o.id, w.cela.address), isFalse);
    await w.ania.food.decline(o.id, w.cela.address);
    await w.net.settle();
    expect(w.cela.food.myRequest(o.id)!.state, FoodRequestState.declined);
    expect(w.cela.titles, contains('Tym razem nie: Pierogi'));

    // More than is left cannot even be asked for.
    expect(
      await w.dina.food.ask(
        o.id,
        mode: FoodMode.takeaway,
        exchange: FoodExchange.free,
        portions: 2,
      ),
      isFalse,
    );
    expect(
      await w.dina.food.ask(
        o.id,
        mode: FoodMode.takeaway,
        exchange: FoodExchange.free,
      ),
      isTrue,
    );
    await w.net.settle();
    expect(await w.ania.food.accept(o.id, w.dina.address), isTrue);
    await w.net.settle();
    expect(w.bob.food.offer(o.id)!.left, 0);
    expect(w.bob.food.offer(o.id)!.openAt(w.net.clock), isFalse);

    // Hand-over: Bob got his; the offer stays until Dina's is settled.
    await w.ania.food.handedOver(o.id, w.bob.address);
    await w.net.settle();
    expect(w.bob.food.myRequest(o.id)!.state, FoodRequestState.done);
    expect(w.ania.food.offer(o.id)!.closed, isFalse);

    // Dina never came: her portion is free again, only Ania knows.
    final int sentToDina = w.ania.sent
        .where(
          (s) => s.$1 == w.dina.address && s.$2['type'] == FoodTypes.answer,
        )
        .length;
    await w.ania.food.markNoShow(o.id, w.dina.address);
    await w.net.settle();
    expect(w.ania.food.noShowsOf(w.dina.address), 1);
    expect(w.ania.food.offer(o.id)!.left, 1);
    expect(w.cela.food.offer(o.id)!.left, 1);
    expect(
      w.ania.sent
          .where(
            (s) => s.$1 == w.dina.address && s.$2['type'] == FoodTypes.answer,
          )
          .length,
      sentToDina,
    );
    expect(w.dina.food.myRequest(o.id)!.state, FoodRequestState.accepted);
    expect(w.dina.food.noShowsOf(w.ania.address), 0);

    // Past "ready until" it closes by itself.
    w.net.clock = t0 + 4 * hour;
    expect(w.cela.food.offer(o.id)!.openAt(w.net.clock), isFalse);
    expect(w.cela.food.offers().where((FoodOffer x) => x.id == o.id), isEmpty);
    expect(await w.ania.food.accept(o.id, w.cela.address), isFalse);
  });

  test('handing over the last portion closes the offer for everyone', () async {
    final _World w = _World();
    await w.start();
    final FoodOffer o = await w.share(w.ania, portions: 1);
    await w.bob.food.ask(
      o.id,
      mode: FoodMode.dineIn,
      exchange: FoodExchange.free,
    );
    await w.net.settle();
    await w.ania.food.accept(o.id, w.bob.address);
    await w.net.settle();
    await w.ania.food.handedOver(o.id, w.bob.address);
    await w.net.settle();
    expect(w.ania.food.offer(o.id)!.closed, isTrue);
    expect(w.cela.food.offer(o.id)!.closed, isTrue);
    expect(w.cela.food.offers(), isEmpty);
    expect(w.ania.food.offers(), isEmpty);
  });

  test('closing declines the requests still waiting', () async {
    final _World w = _World();
    await w.start();
    final FoodOffer o = await w.share(w.ania);
    await w.bob.food.ask(
      o.id,
      mode: FoodMode.takeaway,
      exchange: FoodExchange.free,
    );
    await w.net.settle();
    await w.ania.food.close(o.id);
    await w.net.settle();
    expect(w.bob.food.myRequest(o.id)!.state, FoodRequestState.declined);
    expect(w.cela.food.offer(o.id)!.closed, isTrue);
  });

  test('the private give/take balance of a pair (free and "Dziś Ty, jutro '
      'ja" only)', () async {
    final _World w = _World(
      aniaPoints: _Points('pk-a', balance: 1000),
      bobPoints: _Points('pk-b', balance: 1000),
    );
    await w.start();
    Future<void> give(_Host cook, _Host taker, FoodExchange x) async {
      final FoodOffer o = await w.share(
        cook,
        portions: 1,
        exchanges: <FoodExchange>{x},
        points: x == FoodExchange.points ? 100 : 0,
      );
      expect(
        await taker.food.ask(o.id, mode: FoodMode.takeaway, exchange: x),
        isTrue,
      );
      await w.net.settle();
      expect(await cook.food.accept(o.id, taker.address), isTrue);
      await w.net.settle();
      await cook.food.handedOver(o.id, taker.address);
      await w.net.settle();
    }

    await give(w.ania, w.bob, FoodExchange.free);
    await give(w.ania, w.bob, FoodExchange.swap);
    await give(w.bob, w.ania, FoodExchange.swap);
    // Settled otherwise: not counted.
    await give(w.ania, w.bob, FoodExchange.money);
    await give(w.ania, w.bob, FoodExchange.points);

    final FoodBalance a = w.ania.food.balanceWith(w.bob.address);
    final FoodBalance b = w.bob.food.balanceWith(w.ania.address);
    expect((a.gave, a.got), (2, 1));
    expect((b.gave, b.got), (1, 2));
    // Nobody else learns it.
    expect(w.cela.food.balanceWith(w.ania.address).isEmpty, isTrue);
    for (final (String _, Map<String, dynamic> p) in w.ania.sent) {
      expect(p.containsKey('gave'), isFalse);
      expect(p.containsKey('got'), isFalse);
    }

    // Kept on the phone.
    final FoodService again = FoodService(
      host: w.ania,
      disk: w.ania.disk,
      circles: w.ania.circles,
      now: () => w.net.clock,
    );
    await again.load();
    expect(again.balanceWith(w.bob.address).gave, 2);
    expect(again.balanceWith(w.bob.address).got, 1);
  });

  test('"Za punkty" goes through the points interface, only between '
      'members', () async {
    final _Ledger ledger = _Ledger();
    final _Points aniaPts = _Points('pk-a', ledger: ledger);
    final _Points bobPts = _Points('pk-b', balance: 1000, ledger: ledger);
    final _World w = _World(aniaPoints: aniaPts, bobPoints: bobPts);
    await w.start();

    // Not a member: no "Za punkty" offer.
    expect(
      await w.cela.food.share(
        circleId: w.circle.id,
        title: 'Zupa',
        portions: 2,
        readyFrom: w.net.clock,
        readyUntil: w.net.clock + hour,
        modes: <FoodMode>{FoodMode.takeaway},
        exchanges: <FoodExchange>{FoodExchange.points},
        allergenInfo: FoodAllergenInfo.unknown,
        pointsPerPortion: 250,
      ),
      isNull,
    );
    // A member, but no price.
    expect(
      await w.ania.food.share(
        circleId: w.circle.id,
        title: 'Zupa',
        portions: 2,
        readyFrom: w.net.clock,
        readyUntil: w.net.clock + hour,
        modes: <FoodMode>{FoodMode.takeaway},
        exchanges: <FoodExchange>{FoodExchange.points},
        allergenInfo: FoodAllergenInfo.unknown,
      ),
      isNull,
    );

    final FoodOffer o = await w.share(
      w.ania,
      title: 'Zupa',
      exchanges: <FoodExchange>{FoodExchange.points, FoodExchange.free},
      points: 250,
    );
    expect(w.bob.food.offer(o.id)!.pyramidKey, 'pk-a');
    expect(w.bob.food.canPayPoints(w.bob.food.offer(o.id)!), isTrue);
    // Cela is not in the pyramid: free only.
    expect(w.cela.food.canPayPoints(w.cela.food.offer(o.id)!), isFalse);
    expect(
      await w.cela.food.ask(
        o.id,
        mode: FoodMode.takeaway,
        exchange: FoodExchange.points,
      ),
      isFalse,
    );

    expect(
      await w.bob.food.ask(
        o.id,
        mode: FoodMode.takeaway,
        exchange: FoodExchange.points,
        portions: 2,
      ),
      isTrue,
    );
    // Paying waits for the cook's yes.
    expect(await w.bob.food.payPoints(o.id), isFalse);
    await w.net.settle();
    expect(
      w.ania.food.offer(o.id)!.requests[w.bob.address]!.pyramidKey,
      'pk-b',
    );
    await w.ania.food.accept(o.id, w.bob.address);
    await w.net.settle();

    expect(await w.bob.food.payPoints(o.id), isTrue);
    expect(bobPts.paid.single, ('pk-a', 500, 'Jedzenie: Zupa'));
    expect(bobPts.balance, 500);
    // Once.
    expect(await w.bob.food.payPoints(o.id), isFalse);
    await w.net.settle();
    final FoodRequest atCook = w.ania.food
        .offer(o.id)!
        .requests[w.bob.address]!;
    expect(atCook.payment, isNotNull);
    expect(w.ania.titles, contains('Punkty za jedzenie: Zupa'));
    expect(
      w.ania.food.pointsIn(w.ania.food.offer(o.id)!, atCook),
      isFalse,
      reason: 'the taker\'s word only: the order is not in the pyramid yet',
    );
    ledger.letThrough();
    expect(w.ania.food.pointsIn(w.ania.food.offer(o.id)!, atCook), isTrue);
    // An order id the taker made up never counts.
    expect(
      w.ania.food.pointsIn(
        w.ania.food.offer(o.id)!,
        atCook.copyWith(payment: 'made-up'),
      ),
      isFalse,
    );
  });

  test('reach: circle, friends, friends of friends through a friend', () async {
    final _World w = _World();
    await w.start();

    final FoodOffer friends = await w.share(
      w.ania,
      title: 'Bigos',
      reach: FoodReach.friends,
    );
    expect(w.ewa.food.offer(friends.id), isNotNull);
    expect(w.filip.food.offer(friends.id), isNull);

    final FoodOffer wide = await w.share(
      w.ania,
      title: 'Placki',
      reach: FoodReach.friendsOfFriends,
    );
    expect(w.ewa.food.offer(wide.id), isNotNull);
    expect(w.filip.food.offer(wide.id), isNotNull);
    expect(w.filip.food.viaOf(wide.id), w.ewa.address);
    expect(w.filip.shown.last.title, 'a1 dzieli się jedzeniem: Placki');
    expect(w.filip.shown.last.body, contains('przez e5'));
    // Circle members get it from Ania herself, never passed on.
    expect(w.bob.food.viaOf(wide.id), isNull);

    // Filip asks through Ewa; Ania answers through Ewa.
    expect(
      await w.filip.food.ask(
        wide.id,
        mode: FoodMode.takeaway,
        exchange: FoodExchange.free,
      ),
      isTrue,
    );
    await w.net.settle();
    final FoodRequest r = w.ania.food
        .offer(wide.id)!
        .requests[w.filip.address]!;
    expect(r.via, w.ewa.address);
    expect(r.name, 'f6');
    expect(await w.ania.food.accept(wide.id, w.filip.address), isTrue);
    await w.net.settle();
    expect(w.filip.food.myRequest(wide.id)!.state, FoodRequestState.accepted);
    expect(w.filip.food.myRequest(wide.id)!.place, 'ul. Lipowa 3, II piętro');
    expect(w.filip.food.offer(wide.id)!.left, 2);
    expect(w.ania.sent.any((s) => s.$1 == w.filip.address), isFalse);

    // A circle offer is not passed on, even if someone tries.
    final FoodOffer inCircle = await w.share(w.ania, title: 'Rosół');
    await w.ewa.send(w.filip.address, <String, dynamic>{
      'type': FoodTypes.offer,
      'o': w.bob.food.offer(inCircle.id)!.toJson(),
      'hops': 0,
    });
    await w.net.settle();
    expect(w.filip.food.offer(inCircle.id), isNull);

    // Someone outside the circle cannot ask for a circle offer.
    await w.ewa.send(w.ania.address, <String, dynamic>{
      'type': FoodTypes.request,
      'id': inCircle.id,
      'n': 1,
      'm': FoodMode.takeaway.code,
      'x': FoodExchange.free.code,
    });
    await w.net.settle();
    expect(w.ania.food.offer(inCircle.id)!.requests, isEmpty);

    // A stranger's offer is not taken in.
    final _Host gosia = _Host(w.net, 'g7', <String>[]);
    await gosia.send(w.bob.address, <String, dynamic>{
      'type': FoodTypes.offer,
      'o': <String, dynamic>{
        ...friends.toJson(),
        'id': 'obce1',
        'cook': gosia.address,
      },
    });
    await w.net.settle();
    expect(w.bob.food.offer('obce1'), isNull);
  });

  test('allergens must be considered; times are bounded', () async {
    final _World w = _World();
    await w.start();
    Future<FoodOffer?> share({
      FoodAllergenInfo? info,
      Set<FoodAllergen> allergens = const <FoodAllergen>{},
      int until = 2 * hour,
    }) => w.ania.food.share(
      circleId: w.circle.id,
      title: 'Ciasto',
      portions: 4,
      readyFrom: w.net.clock,
      readyUntil: w.net.clock + until,
      modes: <FoodMode>{FoodMode.takeaway},
      exchanges: <FoodExchange>{FoodExchange.free},
      allergenInfo: info,
      allergens: allergens,
    );

    expect(await share(), isNull);
    expect(await share(info: FoodAllergenInfo.listed), isNull);
    expect(
      await share(info: FoodAllergenInfo.unknown, until: 49 * hour),
      isNull,
    );
    expect(await share(info: FoodAllergenInfo.unknown, until: 0), isNull);
    expect(await share(info: FoodAllergenInfo.unknown), isNotNull);
    expect(await share(info: FoodAllergenInfo.none), isNotNull);
    expect(
      await share(
        info: FoodAllergenInfo.listed,
        allergens: <FoodAllergen>{FoodAllergen.nuts, FoodAllergen.lactose},
      ),
      isNotNull,
    );

    // The same rules for what comes from other phones.
    final FoodOffer ok = (await share(info: FoodAllergenInfo.none))!;
    final Map<String, dynamic> json = ok.toJson();
    expect(FoodOffer.fromJson(json), isNotNull);
    expect(
      FoodOffer.fromJson(<String, dynamic>{...json}..remove('ai')),
      isNull,
    );
    expect(
      FoodOffer.fromJson(<String, dynamic>{...json, 'ai': 'listed'}),
      isNull,
    );
    expect(
      FoodOffer.fromJson(<String, dynamic>{
        ...json,
        'until': ok.readyFrom + 49 * hour,
      }),
      isNull,
    );
    // "Za punkty" without the cook's key is dropped.
    final FoodOffer? noKey = FoodOffer.fromJson(<String, dynamic>{
      ...json,
      'ex': <String>['pts', 'free'],
      'pts': 100,
    });
    expect(noKey!.exchanges, <FoodExchange>{FoodExchange.free});
    expect(
      FoodOffer.fromJson(<String, dynamic>{
        ...json,
        'ex': <String>['pts'],
        'pts': 100,
      }),
      isNull,
    );
  });

  test('a reported offer is removed and stays out', () async {
    final _World w = _World();
    await w.start();
    final FoodOffer o = await w.share(w.ania);
    await w.bob.food.ask(
      o.id,
      mode: FoodMode.takeaway,
      exchange: FoodExchange.free,
    );
    await w.net.settle();
    await w.bob.food.hide(o.id);
    await w.net.settle();
    expect(w.bob.food.offer(o.id), isNull);
    expect(
      w.ania.food.offer(o.id)!.requests[w.bob.address]!.state,
      FoodRequestState.cancelled,
    );
    // A newer copy (another request accepted) does not bring it back.
    await w.cela.food.ask(
      o.id,
      mode: FoodMode.takeaway,
      exchange: FoodExchange.free,
    );
    await w.net.settle();
    await w.ania.food.accept(o.id, w.cela.address);
    await w.net.settle();
    expect(w.bob.food.offer(o.id), isNull);
  });
}
