import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/chat/stranger_chats.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/graph/gate_prices.dart';
import 'package:zen/src/features/meet/intro/gate_route.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/presentation/gate_widgets.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

const int _day = 24 * 3600 * 1000;

/// The pyramid's points for the test: conditional payments only, kept or
/// returned as the real wallet does (the receiver decides; the payer only
/// takes back, and only after the time).
final class _Bank {
  final Map<String, int> balance = <String, int>{};
  final Map<String, GateHold> holds = <String, GateHold>{};

  /// Device address → pyramid key (members only).
  final Map<String, String> keys = <String, String>{};
  int _seq = 0;

  /// Payments that reach the pyramid only when let through.
  bool slow = false;
  final Map<String, GateHold> late = <String, GateHold>{};

  void letThrough() {
    holds.addAll(late);
    late.clear();
  }
}

final class _Wallet implements GateWallet {
  _Wallet(this.bank, this.address, this.net);

  final _Bank bank;
  final String address;
  final _Net net;

  @override
  String? get myKey => bank.keys[address];

  @override
  String? keyOf(String a) => bank.keys[PeerShareCodec.normalizeAddress(a)];

  @override
  Future<String?> payeeKeyOf(String a) async => keyOf(a);

  @override
  int get balance => bank.balance[myKey] ?? 0;

  @override
  Future<String?> hold(String to, int amount, {required String memo}) async {
    final String? me = myKey;
    if (me == null || amount <= 0 || balance < amount) {
      return null;
    }
    bank.balance[me] = balance - amount;
    final String id = 'pay${bank._seq++}';
    final GateHold h = GateHold(
      from: me,
      to: to,
      condBy: to,
      amount: amount,
      until: net.clock + kGateHoldTime.inMilliseconds,
    );
    if (bank.slow) {
      bank.late[id] = h;
    } else {
      bank.holds[id] = h;
    }
    return id;
  }

  @override
  GateHold? held(String id) => bank.holds[id];

  @override
  Future<bool> settle(String id, {required bool keep}) async {
    final GateHold? h = bank.holds[id];
    final String? me = myKey;
    if (h == null || h.settled != null || me == null) {
      return false;
    }
    final bool mayDecide = me == h.condBy;
    final bool mayTakeBack = !keep && me == h.from && net.clock >= h.until;
    if (!mayDecide && !mayTakeBack) {
      return false;
    }
    final String gets = keep ? h.to : h.from;
    bank.balance[gets] = (bank.balance[gets] ?? 0) + h.amount;
    bank.holds[id] = GateHold(
      from: h.from,
      to: h.to,
      condBy: h.condBy,
      amount: h.amount,
      until: h.until,
      settled: keep,
    );
    return true;
  }

  @override
  Listenable? get changes => null;
}

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  final _Bank bank = _Bank();
  int clock = 1000000;
}

/// One phone: friend lists ([MeetService]), the conversations outside
/// friends and the contact economy ([IntroService]) with the points.
final class _Phone implements MeetHost, EventHost {
  _Phone(this.net, this.name, String hex, {bool member = true})
    : address = addr(hex) {
    net.phones[address] = this;
    if (member) {
      net.bank.keys[address] = 'k-$name';
    }
    meet = MeetService(host: this, store: MeetStore(disk), now: () => net.clock)
      ..friendNames = () => <String, String>{
        for (final String f in friendList) f: net.phones[f]?.name ?? '?',
      };
    strangers = StrangerChatBook(
      disk: disk,
      isFriendOfFriend: (String a) => meet.mutualFriends(a).isNotEmpty,
      now: () => net.clock,
    );
    intro = open();
  }

  final _Net net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final List<String> friendList = <String>[];
  late final MeetService meet;
  late final StrangerChatBook strangers;
  late IntroService intro;
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  String get key => 'k-$name';
  int get points => net.bank.balance[key] ?? 0;

  IntroService open() => IntroService(
    host: this,
    disk: disk,
    meet: () => meet,
    wallet: _Wallet(net.bank, address, net),
    passes: strangers,
    now: () => net.clock,
  );

  Iterable<Map<String, dynamic>> sentOf(String type) => <Map<String, dynamic>>[
    for (final (String, Map<String, dynamic>) s in sent)
      if (s.$2['type'] == type) s.$2,
  ];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add((to, payload));
    final _Phone? other = net.phones[PeerShareCodec.normalizeAddress(to)];
    if (other == null) {
      return;
    }
    final SignalTransportFrame f = SignalTransportFrame(
      from: address,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
      receivedAtMillis: 0,
    );
    await other.meet.handle(f);
    await other.intro.handle(f);
  }

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) =>
      friendList.contains(PeerShareCodec.normalizeAddress(a));

  @override
  bool isSelf(String a) => PeerShareCodec.addressesEqual(a, address);

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) =>
      net.phones[PeerShareCodec.normalizeAddress(a)]?.name ?? 'Ktoś';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

void _befriend(_Phone a, _Phone b) {
  if (!a.friendList.contains(b.address)) {
    a.friendList.add(b.address);
  }
  if (!b.friendList.contains(a.address)) {
    b.friendList.add(a.address);
  }
}

/// A line: Ania – Bartek – Celina – Darek, and Ewa nobody's friend. Every
/// friend list shared, Ania with 100 points.
Future<
  ({
    _Net net,
    _Phone ania,
    _Phone bartek,
    _Phone celina,
    _Phone darek,
    _Phone ewa,
  })
>
_line() async {
  final _Net net = _Net();
  final _Phone ania = _Phone(net, 'Ania', 'a1');
  final _Phone bartek = _Phone(net, 'Bartek', 'b2');
  final _Phone celina = _Phone(net, 'Celina', 'c3');
  final _Phone darek = _Phone(net, 'Darek', 'd4');
  final _Phone ewa = _Phone(net, 'Ewa', 'e5');
  _befriend(ania, bartek);
  _befriend(bartek, celina);
  _befriend(celina, darek);
  final List<_Phone> all = <_Phone>[ania, bartek, celina, darek, ewa];
  for (final _Phone p in all) {
    // Everything that travels through a middle friend is signed.
    await LedgerIdentity.loadOrCreate(p.disk);
    await p.intro.load();
    await p.strangers.load();
  }
  for (final _Phone p in all) {
    if (p.friendList.isNotEmpty) {
      await p.meet.shareFriendList(p.meet.friendNames!(), force: true);
    }
  }
  net.bank.balance[ania.key] = 10000;
  return (
    net: net,
    ania: ania,
    bartek: bartek,
    celina: celina,
    darek: darek,
    ewa: ewa,
  );
}

const GateTerms _free = GateTerms();

/// The same terms for close friends, friends and those further away.
Future<void> _all(_Phone p, GateTerms terms) async {
  for (final GateTier tier in GateTier.values) {
    await p.intro.setGateTier(tier, terms);
  }
}

const GateTerms _freeAtOnce = GateTerms(consent: false);

void main() {
  group('gate terms', () {
    test('free gates ask for consent, priced ones open by buying', () {
      expect(_free.consent, isTrue);
      expect(const GateTerms(price: 500).consent, isFalse);
      expect(const GateTerms(price: 500, consent: true).consent, isTrue);
      expect(const GateTerms(price: 500).label, '5 pkt');
      expect(
        const GateTerms(price: 250, consent: true).label,
        contains('za zgodą'),
      );
      expect(
        GateTerms.fromJson(const GateTerms(price: 7).toJson()),
        const GateTerms(price: 7),
      );
      expect(GateTerms.fromJson(<String, dynamic>{'p': -1, 'c': true}), isNull);
    });

    testWidgets('the terms dialog: a price turns the consent off by default', (
      WidgetTester tester,
    ) async {
      GateTerms? got;
      await tester.pumpWidget(
        MaterialApp(
          theme: ZenTheme.dark(),
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                got = await editGateTerms(
                  context,
                  initial: GateTerms.standard,
                  title: 'Brama',
                  member: false,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      bool consent() => tester
          .widget<SwitchListTile>(find.byKey(const Key('gate-consent')))
          .value;
      expect(consent(), isTrue);
      expect(find.byKey(const Key('gate-price-field')), findsNothing);
      await tester.tap(find.byKey(const Key('gate-paid')));
      await tester.pump();
      expect(consent(), isFalse);
      // Outside the pyramid nobody could pay: said so.
      expect(find.textContaining('tylko między członkami'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('gate-price-field')), '5');
      await tester.tap(find.byKey(const Key('gate-terms-save')));
      await tester.pumpAndSettle();
      expect(got, const GateTerms(price: 500));
      // The dialog's field is disposed once it has gone (disposeLater).
      await tester.pump(const Duration(seconds: 1));
    });

    test('settings: a price for close friends, friends and those further '
        'away, free for chosen people, passed on; kept on disk and sent to '
        'friends as cards', () async {
      final (:net, :ania, :bartek, :celina, :darek, ewa: _) = await _line();
      expect(bartek.intro.gateTermsFor(ania.address), GateTerms.standard);
      bartek.meet.levelOf = (String a) =>
          a == ania.address ? FriendLevel.close : FriendLevel.friend;
      await bartek.intro.setGateTier(GateTier.close, _freeAtOnce);
      await bartek.intro.setGateTier(
        GateTier.friend,
        const GateTerms(price: 300),
      );
      await bartek.intro.setGateTier(GateTier.far, const GateTerms(price: 900));
      await bartek.intro.setGateRelay(true);
      expect(bartek.intro.gateTierOf(ania.address), GateTier.close);
      expect(bartek.intro.gateTierOf(celina.address), GateTier.friend);
      expect(bartek.intro.gateTierOf(darek.address), GateTier.far);
      expect(bartek.intro.gateTermsFor(ania.address), _freeAtOnce);
      expect(
        bartek.intro.gateTermsFor(celina.address),
        const GateTerms(price: 300),
      );
      expect(
        bartek.intro.gateTermsFor(darek.address),
        const GateTerms(price: 900),
      );
      // Each friend heard their own terms; those further away get the
      // price for them passed on.
      expect(ania.intro.cardOf(bartek.address)!.terms, _freeAtOnce);
      expect(
        celina.intro.cardOf(bartek.address)!.terms,
        const GateTerms(price: 300),
      );
      expect(ania.intro.cardOf(bartek.address)!.relay, isTrue);
      expect(
        ania.intro.cardOf(bartek.address)!.open,
        const GateTerms(price: 900),
      );
      // Nothing new: nothing sent again.
      final int cards = bartek.sentOf(IntroTypes.gate).length;
      await bartek.intro.shareGates();
      expect(bartek.sentOf(IntroTypes.gate).length, cards);

      // Free for Celina: no price, and (as for a priced tier) no consent.
      await bartek.intro.setGateFree(celina.address, free: true);
      expect(
        bartek.intro.gateTermsFor(celina.address),
        const GateTerms(consent: false),
      );
      expect(celina.intro.cardOf(bartek.address)!.terms.free, isTrue);
      // A free tier stays as it is (Bartek still decides when it says so).
      await bartek.intro.setGateTier(GateTier.friend, _free);
      expect(bartek.intro.gateTermsFor(celina.address), _free);
      await bartek.intro.setGateTier(
        GateTier.friend,
        const GateTerms(price: 300),
      );

      // The app opens again on the same store.
      bartek.intro = bartek.open();
      await bartek.intro.load();
      expect(bartek.intro.gates.isFreeFor(celina.address), isTrue);
      expect(bartek.intro.gates.of(GateTier.far), const GateTerms(price: 900));
      expect(bartek.intro.gates.relay, isTrue);
      await bartek.intro.setGateFree(celina.address, free: false);
      expect(
        celina.intro.cardOf(bartek.address)!.terms,
        const GateTerms(price: 300),
      );
      expect(
        GateSettings.fromJson(
          jsonDecode(jsonEncode(bartek.intro.gates.toJson())),
        ).of(GateTier.close),
        _freeAtOnce,
      );
      expect(net.clock, greaterThan(0));
    });
  });

  group('opening a gate', () {
    test('a free gate needs the friend\'s consent by default', () async {
      final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = await _line();
      final IntroCase? c = await ania.intro.askIntro(
        middle: bartek.address,
        target: celina.address,
        targetName: 'Celina',
      );
      expect(bartek.intro.needsMe.single.id, c!.id);
      expect(celina.intro.needsMe, isEmpty);
      await bartek.intro.forward(c.id);
      expect(ania.intro.caseOf(c.id)!.status, IntroStatus.forwarded);
      expect(ania.intro.caseOf(c.id)!.reached, isTrue);
      // The gate lets each write to the other outside friends.
      expect(celina.strangers.passFrom(ania.address)!.via, bartek.address);
      expect(ania.strangers.passTo(celina.address), isNotNull);
    });

    test('a free gate without consent opens at once', () async {
      final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = await _line();
      await _all(bartek, _freeAtOnce);
      final IntroCase? c = await ania.intro.askIntro(
        middle: bartek.address,
        target: celina.address,
        targetName: 'Celina',
      );
      expect(bartek.intro.needsMe, isEmpty, reason: 'nobody asked Bartek');
      expect(ania.intro.caseOf(c!.id)!.status, IntroStatus.forwarded);
      expect(celina.intro.needsMe.single.asker, ania.address);
      expect(bartek.shown.last.title, contains('Otwarto bramę'));
    });

    test(
      'a priced gate asked without paying: the asker learns the price',
      () async {
        final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) =
            await _line();
        await _all(bartek, const GateTerms(price: 500));
        final IntroCase? c = await ania.intro.askIntro(
          middle: bartek.address,
          target: celina.address,
          targetName: 'Celina',
        );
        final IntroCase back = ania.intro.caseOf(c!.id)!;
        expect(back.status, IntroStatus.declined);
        expect(back.price, 500);
        expect(celina.intro.needsMe, isEmpty);
      },
    );

    test('bought without consent: Bartek\'s app opens it, the points are his '
        'once it opens', () async {
      final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = await _line();
      await _all(bartek, const GateTerms(price: 500));
      final ReachPlan plan = ania.intro.planTo(celina.address);
      expect(plan.best, ReachChoice.gates);
      expect(plan.gates!.price, 500);
      expect(plan.gates!.pending, 0);
      final GateRun? run = await ania.intro.openWay(
        plan.gates!,
        target: celina.address,
        targetName: 'Celina',
      );
      expect(run!.state, GateRunState.done);
      expect(bartek.intro.needsMe, isEmpty, reason: 'no consent asked');
      expect(celina.intro.needsMe.single.asker, ania.address);
      expect(bartek.points, 500);
      expect(ania.points, 9500);
    });

    test(
      'bought with consent: waits for Bartek; his "no" returns the points',
      () async {
        final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) =
            await _line();
        await _all(bartek, const GateTerms(price: 500, consent: true));
        final GatePlan plan = ania.intro.planTo(celina.address).gates!;
        expect(plan.pending, 1);
        final GateRun? run = await ania.intro.openWay(
          plan,
          target: celina.address,
          targetName: 'Celina',
        );
        expect(run!.state, GateRunState.going);
        expect(ania.points, 9500, reason: 'put aside');
        final IntroCase asked = bartek.intro.needsMe.single;
        expect(asked.price, 500);
        await bartek.intro.decline(asked.id);
        expect(ania.intro.runOf(run.id)!.state, GateRunState.failed);
        expect(ania.points, 10000);
        expect(bartek.points, 0);
      },
    );

    test('more than the price is never kept: it goes back and the asker '
        'learns the price', () async {
      final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = await _line();
      await _all(bartek, const GateTerms(price: 500));
      final GatePlan plan = ania.intro.planTo(celina.address).gates!;
      expect(plan.price, 500);
      // Bartek lowers it before Ania's request comes: she pays the old one.
      await _all(bartek, const GateTerms(price: 300));
      final GateRun? run = await ania.intro.openWay(
        plan,
        target: celina.address,
        targetName: 'Celina',
      );
      expect(run!.state, GateRunState.failed);
      expect(bartek.points, 0);
      expect(ania.points, 10000);
    });

    test('a payment not in the pyramid yet: the gate waits for it', () async {
      final (:net, :ania, :bartek, :celina, darek: _, ewa: _) = await _line();
      await _all(bartek, const GateTerms(price: 500));
      net.bank.slow = true;
      final GateRun? run = await ania.intro.openWay(
        ania.intro.planTo(celina.address).gates!,
        target: celina.address,
        targetName: 'Celina',
      );
      expect(run!.steps.single.state, GateStepState.paying);
      expect(bartek.sentOf(IntroTypes.forward), isEmpty);
      net.bank.letThrough();
      await ania.intro.tick();
      expect(ania.intro.runOf(run.id)!.state, GateRunState.done);
      expect(bartek.points, 500);
    });

    test('one payment pays for one gate: sent again for another request it '
        'counts as none', () async {
      final (net: _, :ania, :bartek, :celina, darek: _, :ewa) = await _line();
      _befriend(bartek, ewa);
      await _all(bartek, const GateTerms(price: 500, consent: true));
      final GateRun? run = await ania.intro.openWay(
        ania.intro.planTo(celina.address).gates!,
        target: celina.address,
        targetName: 'Celina',
      );
      expect(run!.state, GateRunState.going);
      expect(bartek.intro.needsMe, hasLength(1));
      // A client that sends what it likes: the same (still unsettled)
      // payment for a gate to somebody else.
      final Map<String, dynamic> first = ania.sentOf(IntroTypes.ask).last;
      const String again = 'reusedpayment01';
      await ania.send(bartek.address, <String, dynamic>{
        ...first,
        'id': again,
        'a': ewa.address,
      });
      expect(bartek.intro.caseOf(again), isNull);
      expect(bartek.intro.needsMe, hasLength(1));
      expect(ewa.intro.needsMe, isEmpty);
    });
  });

  group('the cheapest way (Dijkstra)', () {
    final String me = addr('a0');
    final String a = addr('a1');
    final String b = addr('b2');
    final String c = addr('c3');
    final String d = addr('d4');
    final String x = addr('e5');
    Map<String, String> Function(String) lists(Map<String, List<String>> m) =>
        (String p) => <String, String>{
          for (final String q in m[p] ?? const <String>[]) q: q,
        };

    test('the cheaper gate wins; on a price tie, fewer consents, then fewer '
        'gates', () {
      final Map<String, GateTerms> terms = <String, GateTerms>{
        a: const GateTerms(price: 500),
        b: _free,
      };
      GatePlan plan = cheapestGates(
        target: x,
        friends: <String>[a, b],
        friendsOf: lists(<String, List<String>>{
          a: <String>[x],
          b: <String>[x],
        }),
        termsOf: (String k) => terms[k],
        canPay: (String _) => true,
        self: me,
      );
      expect(plan.steps.single.via, b, reason: 'free beats 5 pkt');

      // Same price: the one that opens without asking.
      terms[a] = _freeAtOnce;
      plan = cheapestGates(
        target: x,
        friends: <String>[a, b],
        friendsOf: lists(<String, List<String>>{
          a: <String>[x],
          b: <String>[x],
        }),
        termsOf: (String k) => terms[k],
        self: me,
      );
      expect(plan.steps.single.via, a);

      // Same price and consents: one gate rather than two.
      plan = cheapestGates(
        target: x,
        friends: <String>[b, a],
        friendsOf: lists(<String, List<String>>{
          b: <String>[c],
          c: <String>[x],
          a: <String>[x],
        }),
        termsOf: (String _) => _freeAtOnce,
        self: me,
      );
      expect(plan.steps, hasLength(1));
      expect(plan.steps.single.via, a);
    });

    test('several gates, friends of friends of friends', () {
      final Map<String, GateTerms> terms = <String, GateTerms>{
        a: const GateTerms(price: 100),
        c: const GateTerms(price: 200),
        d: _freeAtOnce,
      };
      final GatePlan plan = cheapestGates(
        target: x,
        friends: <String>[a],
        friendsOf: lists(<String, List<String>>{
          a: <String>[me, c],
          c: <String>[a, d],
          d: <String>[x],
        }),
        termsOf: (String k) => terms[k],
        canPay: (String _) => true,
        self: me,
      );
      expect(
        <(String, String)>[
          for (final GateStepPlan s in plan.steps) (s.via, s.to),
        ],
        <(String, String)>[(a, c), (c, d), (d, x)],
      );
      expect(plan.price, 300);
      expect(plan.through, <String>[a, c, d]);

      // A cheaper long way beats an expensive short one.
      final GatePlan cheap = cheapestGates(
        target: x,
        friends: <String>[a, b],
        friendsOf: lists(<String, List<String>>{
          a: <String>[c],
          c: <String>[d],
          d: <String>[x],
          b: <String>[x],
        }),
        termsOf: (String k) =>
            k == b ? const GateTerms(price: 2000) : _freeAtOnce,
        canPay: (String _) => true,
        self: me,
      );
      expect(cheap.steps, hasLength(3));
      expect(cheap.price, 0);
    });

    test(
      'a price nobody can pay closes that gate; a long way is still a way',
      () {
        GatePlan plan = cheapestGates(
          target: x,
          friends: <String>[a],
          friendsOf: lists(<String, List<String>>{
            a: <String>[x],
          }),
          termsOf: (String _) => const GateTerms(price: 100),
          canPay: (String _) => false,
          self: me,
        );
        expect(plan.isEmpty, isTrue);
        // Unknown terms count as a decision to wait for.
        plan = cheapestGates(
          target: x,
          friends: <String>[a],
          friendsOf: lists(<String, List<String>>{
            a: <String>[x],
          }),
          termsOf: (String _) => null,
          self: me,
        );
        expect(plan.pending, 1);
        expect(plan.unknown, 1);
        final List<String> chain = <String>[
          for (int i = 0; i < 7; i++) addr('f${i + 1}'),
        ];
        plan = cheapestGates(
          target: chain.last,
          friends: <String>[chain.first],
          friendsOf: (String p) {
            final int i = chain.indexOf(p);
            return i < 0 || i == chain.length - 1
                ? const <String, String>{}
                : <String, String>{chain[i + 1]: ''};
          },
          termsOf: (String _) => _freeAtOnce,
          self: me,
        );
        expect(plan.steps, hasLength(6), reason: 'no limit of gates');
        expect(plan.through, chain.take(6).toList());
      },
    );

    test('writing directly against the gates', () {
      ReachPlan plan(DirectTerms direct) => planReach(
        target: x,
        friends: <String>[a],
        friendsOf: lists(<String, List<String>>{
          a: <String>[x],
        }),
        termsOf: (String _) => const GateTerms(price: 500),
        canPay: (String _) => true,
        direct: direct,
        self: me,
      );
      expect(
        plan(const DirectTerms.price(200, payable: true)).best,
        ReachChoice.direct,
      );
      expect(
        plan(const DirectTerms.price(2000, payable: true)).best,
        ReachChoice.gates,
      );
      expect(
        plan(const DirectTerms.price(500, payable: true)).best,
        ReachChoice.direct,
        reason: 'a tie: nobody in between',
      );
      expect(plan(const DirectTerms.price(0)).best, ReachChoice.direct);
      expect(
        plan(const DirectTerms.price(200)).best,
        ReachChoice.gates,
        reason: 'a price outside the pyramid cannot be paid',
      );
      expect(plan(const DirectTerms.closed()).best, ReachChoice.gates);
      expect(plan(const DirectTerms.unknown()).best, ReachChoice.gates);
      expect(
        planReach(
          target: a,
          friends: <String>[a],
          friendsOf: lists(const <String, List<String>>{}),
          termsOf: (String _) => null,
        ).friend,
        isTrue,
      );
      expect(
        planReach(
          target: d,
          friends: <String>[a],
          friendsOf: lists(const <String, List<String>>{}),
          termsOf: (String _) => null,
        ).best,
        ReachChoice.none,
      );
    });
  });

  group('a way of several gates', () {
    /// Bartek opens to Celina for 5 pkt; Celina, who lets her terms travel,
    /// opens to Darek for 3 pkt ([celinaConsent]: only with her consent).
    Future<
      ({
        _Net net,
        _Phone ania,
        _Phone bartek,
        _Phone celina,
        _Phone darek,
        GatePlan plan,
      })
    >
    setUpWay({bool celinaConsent = false}) async {
      final (:net, :ania, :bartek, :celina, :darek, ewa: _) = await _line();
      await _all(celina, GateTerms(price: 300, consent: celinaConsent));
      await celina.intro.setGateRelay(true);
      await bartek.intro.setGateTier(
        GateTier.friend,
        const GateTerms(price: 500),
      );
      // Ania knows Darek only from what Bartek passed on about Celina.
      expect(ania.meet.book.friendsOf(celina.address), isEmpty);
      expect(
        ania.intro.knownFriendsOf(celina.address).keys,
        contains(darek.address),
      );
      final ReachPlan reach = ania.intro.planTo(darek.address);
      expect(reach.best, ReachChoice.gates);
      return (
        net: net,
        ania: ania,
        bartek: bartek,
        celina: celina,
        darek: darek,
        plan: reach.gates!,
      );
    }

    test('planned through friends of friends, opened gate after gate, every '
        'gatekeeper paid as its gate opens', () async {
      final (net: _, :ania, :bartek, :celina, :darek, :plan) = await setUpWay();
      expect(
        <String>[for (final GateStepPlan s in plan.steps) s.via],
        <String>[bartek.address, celina.address],
      );
      expect(plan.price, 800);
      final GateRun? run = await ania.intro.openWay(
        plan,
        target: darek.address,
        targetName: 'Darek',
        note: 'Szukam fotografa',
      );
      expect(run!.state, GateRunState.done);
      // Celina was asked by Ania directly: Bartek's gate opened to her.
      expect(
        ania.sent.any(
          ((String, Map<String, dynamic>) s) =>
              s.$1 == celina.address && s.$2['type'] == IntroTypes.ask,
        ),
        isTrue,
      );
      expect(darek.intro.needsMe.single.asker, ania.address);
      expect(darek.intro.needsMe.single.text, 'Szukam fotografa');
      expect(bartek.points, 500);
      expect(celina.points, 300);
      expect(ania.points, 10000 - 800);
      expect(ania.strangers.passTo(darek.address), isNotNull);
      expect(darek.strangers.passFrom(ania.address)!.via, celina.address);
    });

    test('a later gate does not open: only its payment comes back, an opened '
        'gate stays paid', () async {
      final (:net, :ania, :bartek, :celina, darek: _, :plan) = await setUpWay(
        celinaConsent: true,
      );
      final GateRun? run = await ania.intro.openWay(
        plan,
        target: plan.steps.last.to,
        targetName: 'Darek',
      );
      expect(run!.state, GateRunState.going);
      expect(run.steps.first.state, GateStepState.open);
      expect(ania.points, 10000 - 800, reason: 'both paid');
      expect(bartek.points, 500, reason: 'kept as his gate opened');
      // Celina also has Ania's introduction to accept (Bartek's gate): she
      // turns down her own gate.
      await celina.intro.decline(
        celina.intro.needsMe
            .singleWhere((IntroCase c) => c.role == IntroRole.middle)
            .id,
      );
      expect(ania.intro.runOf(run.id)!.state, GateRunState.failed);
      expect(ania.points, 10000 - 500);
      expect(bartek.points, 500, reason: 'his gate did what was paid for');
      expect(celina.points, 0);

      // Nobody answers at all: the way gives up, the points come back by
      // themselves once their time is over.
      final (
        net: _Net net2,
        ania: _Phone ania2,
        bartek: _Phone _,
        celina: _Phone celina2,
        darek: _Phone _,
        plan: GatePlan plan2,
      ) = await setUpWay(
        celinaConsent: true,
      );
      final GateRun? quiet = await ania2.intro.openWay(
        plan2,
        target: plan2.steps.last.to,
        targetName: 'Darek',
      );
      // Celina's phone is gone from now on.
      net2.phones.remove(celina2.address);
      net2.clock += 2 * _day;
      await ania2.intro.tick();
      expect(ania2.intro.runOf(quiet!.id)!.state, GateRunState.failed);
      expect(ania2.points, 10000 - 800, reason: 'Celina\'s waits for her');
      net2.clock += 8 * _day;
      await ania2.intro.tick();
      expect(
        ania2.points,
        10000 - 500,
        reason: 'Celina\'s back after its time; Bartek\'s gate opened',
      );
      expect(net.clock, greaterThan(0));
    });

    test('an opened gate is kept at once: the asker cannot take it back by '
        'saying the way failed', () async {
      final (net: _, :ania, :bartek, celina: _, darek: _, :plan) =
          await setUpWay(celinaConsent: true);
      final GateRun? run = await ania.intro.openWay(
        plan,
        target: plan.steps.last.to,
        targetName: 'Darek',
      );
      expect(run!.steps.first.state, GateStepState.open);
      expect(bartek.points, 500, reason: 'kept as the gate opened');
      // A client that sends what it likes: "the way failed" for Bartek's
      // opened gate.
      final String caseId = run.steps.first.caseId!;
      await ania.send(bartek.address, <String, dynamic>{
        'type': IntroTypes.end,
        'id': caseId,
        'ok': false,
      });
      await bartek.intro.tick();
      expect(bartek.points, 500);
      expect(bartek.intro.caseOf(caseId)!.settled, isTrue);
    });
  });

  group('a first message for a price', () {
    test('paid: Ewa\'s app takes it and lets Ania in; closed: back', () async {
      final (net: _, :ania, bartek: _, celina: _, darek: _, :ewa) =
          await _line();
      await ewa.strangers.setFrom(StrangerMessagesFrom.everyone);
      await ewa.strangers.setPrice(200);
      expect(ewa.strangers.admits(ania.address), isFalse);
      expect(await ania.intro.payToWrite(ewa.address, price: 200), isTrue);
      expect(ania.intro.messagePayTo(ewa.address)!.state, MessagePayState.ok);
      expect(ewa.strangers.passFrom(ania.address)!.paid, isTrue);
      expect(ewa.strangers.admits(ania.address), isTrue);
      expect(ania.strangers.passTo(ewa.address)!.paid, isTrue);
      expect(ewa.points, 200);
      expect(ania.points, 9800);

      // Closed to everyone: the points come back.
      final _Phone zofia = _Phone(ania.net, 'Zofia', 'f1');
      await zofia.strangers.setFrom(StrangerMessagesFrom.nobody);
      expect(await ania.intro.payToWrite(zofia.address, price: 200), isTrue);
      expect(
        ania.intro.messagePayTo(zofia.address)!.state,
        MessagePayState.failed,
      );
      expect(zofia.points, 0);
      expect(ania.points, 9800);

      // Free after all: in, and nothing kept.
      final _Phone jan = _Phone(ania.net, 'Jan', 'f2');
      await jan.strangers.setFrom(StrangerMessagesFrom.everyone);
      expect(await ania.intro.payToWrite(jan.address, price: 100), isTrue);
      expect(jan.strangers.passFrom(ania.address), isNotNull);
      expect(jan.points, 0);
      expect(ania.points, 9800);
    });

    test('outside the pyramid nothing can be paid', () async {
      final _Net net = _Net();
      final _Phone ania = _Phone(net, 'Ania', 'a1', member: false);
      final _Phone ewa = _Phone(net, 'Ewa', 'e5');
      await ewa.strangers.setFrom(StrangerMessagesFrom.everyone);
      await ewa.strangers.setPrice(200);
      expect(await ania.intro.payToWrite(ewa.address, price: 200), isFalse);
      expect(ania.intro.canPay(ewa.address), isFalse);
    });
  });

  group('the graph\'s gate prices', () {
    test('friends free, introductions at the friend\'s terms, further away '
        'what was passed on', () async {
      final (net: _, :ania, :bartek, :celina, :darek, ewa: _) = await _line();
      final IntroGatePrices prices = IntroGatePrices(ania.intro);
      expect(prices.gateOf(bartek.address), const GatePrice.free());
      expect(prices.gateOf(celina.address), isNull, reason: 'not a friend');
      expect(
        prices.gateOf(celina.address, via: bartek.address),
        isNull,
        reason: 'Bartek has not said yet',
      );
      await bartek.intro.setGateTier(
        GateTier.friend,
        const GateTerms(price: 500),
      );
      expect(
        prices.gateOf(celina.address, via: bartek.address),
        const GatePrice.price(500, shown: '5 pkt'),
      );
      await bartek.intro.setGateTier(GateTier.friend, _free);
      expect(
        prices.gateOf(celina.address, via: bartek.address),
        const GatePrice.consent(),
      );
      await bartek.intro.setGateTier(
        GateTier.friend,
        const GateTerms(price: 500, consent: true),
      );
      final GatePrice? both = prices.gateOf(
        celina.address,
        via: bartek.address,
      );
      expect(both!.consent, isTrue);
      expect(both.label, '5 pkt · za zgodą');
      await _all(celina, _freeAtOnce);
      await celina.intro.setGateRelay(true);
      expect(
        prices.gateOf(darek.address, via: celina.address),
        const GatePrice.free(),
      );
      expect(prices.changes, same(ania.intro));
    });
  });

  group('ways of any length', () {
    test('Dijkstra over a long line and a wide graph: the cheapest of all, '
        'as many gates as it takes', () {
      final String me = addr('a0');
      // A line of 60 people, and a short way through an expensive gate.
      final List<String> line = <String>[
        for (int i = 0; i < 60; i++) addr('1${i.toString().padLeft(3, '0')}'),
      ];
      final String pricey = addr('fff1');
      final Map<String, Map<String, String>> lists =
          <String, Map<String, String>>{
            for (int i = 0; i < line.length - 1; i++)
              line[i]: <String, String>{line[i + 1]: 'n$i'},
            pricey: <String, String>{line.last: 'koniec'},
          };
      // Many dead ends next to the line (a wide graph).
      for (int i = 0; i < line.length - 1; i++) {
        for (int k = 0; k < 30; k++) {
          lists[line[i]]![addr('2${i.toString().padLeft(2, '0')}$k')] = '';
        }
      }
      GatePlan plan = cheapestGates(
        target: line.last,
        friends: <String>[line.first, pricey],
        friendsOf: (String p) => lists[p] ?? const <String, String>{},
        termsOf: (String k) =>
            k == pricey ? const GateTerms(price: 100) : _freeAtOnce,
        canPay: (String _) => true,
        self: me,
      );
      expect(plan.steps, hasLength(59), reason: 'free beats 1 pkt');
      expect(plan.steps.first.via, line.first);
      expect(plan.steps.last.to, line.last);
      expect(plan.price, 0);
      expect(plan.through, line.take(59).toList());
      // The pricey one is free too now: one gate wins (fewer gates).
      plan = cheapestGates(
        target: line.last,
        friends: <String>[line.first, pricey],
        friendsOf: (String p) => lists[p] ?? const <String, String>{},
        termsOf: (String _) => _freeAtOnce,
        self: me,
      );
      expect(plan.steps.single.via, pricey);
    });

    test('a card passes the nearest gatekeepers first, each once, never the '
        'one it is for', () {
      RelayedGate g(
        String a, [
        List<RelayedGate> below = const <RelayedGate>[],
      ]) => RelayedGate(address: addr(a), terms: _freeAtOnce, relayed: below);
      final List<RelayedGate> roots = <RelayedGate>[
        g('11', <RelayedGate>[
          g('12', <RelayedGate>[
            g('13', <RelayedGate>[g('14')]),
          ]),
        ]),
        g('21', <RelayedGate>[g('22'), g('11'), g('99')]),
        g('31'),
      ];
      final List<RelayedGate> cut = trimRelayed(
        roots,
        budget: 6,
        exclude: <String>{addr('99')},
      );
      List<String> flat(List<RelayedGate> gates) => <String>[
        for (final RelayedGate r in gates) ...<String>[
          r.address,
          ...flat(r.relayed),
        ],
      ];
      expect(flat(cut), <String>[
        addr('11'),
        addr('12'),
        addr('13'),
        addr('21'),
        addr('22'),
        addr('31'),
      ]);
      // Deep enough and big enough: the whole line.
      expect(
        flat(trimRelayed(roots, exclude: <String>{addr('99')})),
        contains(addr('14')),
      );
      expect(
        <String>[
          for (final RelayedGate r in trimRelayed(roots, depth: 1)) r.address,
        ],
        <String>[addr('11'), addr('21'), addr('31')],
      );
      // A card read back keeps all the levels.
      final GateCard card = GateCard(
        terms: _free,
        relay: true,
        open: _free,
        relayed: trimRelayed(roots),
      );
      final GateCard back = GateCard.fromJson(
        jsonDecode(jsonEncode(card.toJson())),
      )!;
      expect(flat(back.relayed), contains(addr('14')));
    });

    test('six gates, known only from what friends passed on, opened one '
        'after another', () async {
      final _Net net = _Net();
      final _Phone ania = _Phone(net, 'Ania', 'a0');
      final List<_Phone> line = <_Phone>[
        for (int i = 1; i <= 7; i++) _Phone(net, 'P$i', 'b$i'),
      ];
      _befriend(ania, line.first);
      for (int i = 0; i < line.length - 1; i++) {
        _befriend(line[i], line[i + 1]);
      }
      final List<_Phone> all = <_Phone>[ania, ...line];
      for (final _Phone p in all) {
        await LedgerIdentity.loadOrCreate(p.disk);
        await p.intro.load();
        await p.strangers.load();
        await p.meet.shareFriendList(p.meet.friendNames!(), force: true);
      }
      for (final _Phone p in line.reversed) {
        await _all(p, _freeAtOnce);
        await p.intro.setGateRelay(true);
      }
      for (final _Phone p in line.reversed) {
        await p.intro.shareGates(force: true);
      }
      final _Phone target = line.last;
      expect(
        ania.intro.knownFriendsOf(line[5].address).keys,
        contains(target.address),
        reason: 'five steps away, passed on friend to friend',
      );
      final ReachPlan reach = ania.intro.planTo(target.address);
      expect(reach.best, ReachChoice.gates);
      final GatePlan plan = reach.gates!;
      expect(plan.steps, hasLength(6));
      final GateRun? run = await ania.intro.openWay(
        plan,
        target: target.address,
        targetName: 'P7',
      );
      expect(run!.state, GateRunState.done);
      expect(
        run.steps.every((GateRunStep s) => s.state == GateStepState.open),
        isTrue,
      );
      expect(target.intro.needsMe.single.asker, ania.address);
      expect(
        GateRun.fromJson(jsonDecode(jsonEncode(run.toJson())))!.steps,
        hasLength(6),
        reason: 'kept whole',
      );
    });

    test('beyond what friends pass on by themselves: asked further along the '
        'known way, as many steps as the graph goes', () async {
      final _Net net = _Net();
      final _Phone ania = _Phone(net, 'Ania', 'a0');
      final List<_Phone> line = <_Phone>[
        for (int i = 1; i <= 10; i++) _Phone(net, 'Q$i', 'c$i'),
      ];
      _befriend(ania, line.first);
      for (int i = 0; i < line.length - 1; i++) {
        _befriend(line[i], line[i + 1]);
      }
      for (final _Phone p in <_Phone>[ania, ...line]) {
        await LedgerIdentity.loadOrCreate(p.disk);
        await p.intro.load();
        await p.strangers.load();
        await p.meet.shareFriendList(p.meet.friendNames!(), force: true);
      }
      for (final _Phone p in line.reversed) {
        await _all(p, _freeAtOnce);
        await p.intro.setGateRelay(true);
      }
      for (final _Phone p in line.reversed) {
        await p.intro.shareGates(force: true);
      }
      final _Phone target = line.last;
      expect(
        ania.intro.planTo(target.address).best,
        ReachChoice.none,
        reason: 'nine gates away: further than cards reach',
      );
      expect(await ania.intro.exploreFurther(), 1);
      expect(await ania.intro.exploreFurther(), 0, reason: 'not again so soon');
      // Nobody on the way learned who asked.
      for (final _Phone p in line) {
        for (final Map<String, dynamic> f in p.sentOf(IntroTypes.more)) {
          expect(jsonEncode(f), isNot(contains(ania.address)));
        }
      }
      final ReachPlan reach = ania.intro.planTo(target.address);
      expect(reach.best, ReachChoice.gates);
      expect(reach.gates!.steps, hasLength(9));
      expect(ania.intro.farPeople().keys, contains(target.address));
      final GateRun? run = await ania.intro.openWay(
        reach.gates!,
        target: target.address,
        targetName: 'Q10',
      );
      expect(run!.state, GateRunState.done);
      expect(target.intro.needsMe.single.asker, ania.address);
      // A gatekeeper who keeps their terms to themselves answers nothing.
      net.clock += kGateMoreEvery.inMilliseconds + 1;
      await line[6].intro.setGateRelay(false);
      expect(line[6].intro.gates.relay, isFalse);
    });
  });
}
