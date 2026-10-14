import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/plan/plan_model.dart';
import 'package:zen/src/features/meet/plan/plan_service.dart';
import 'package:zen/src/features/relay/relay_engine.dart'
    show kReliablePayloadTypes;
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

/// Phones that deliver to each other a moment later (like the mesh: a send
/// does not wait for the other side to handle it).
final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};

  /// A Wednesday at noon.
  int clock = DateTime(2026, 10, 14, 12).millisecondsSinceEpoch;
  int inFlight = 0;

  void link(_Phone a, _Phone b) {
    a.friendSet.add(b.address);
    b.friendSet.add(a.address);
  }

  /// Lets every frame on the way arrive and be handled.
  Future<void> settle() async {
    int quiet = 0;
    for (int i = 0; i < 5000 && quiet < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      quiet = inFlight == 0 ? quiet + 1 : 0;
    }
  }
}

final class _Phone implements EventHost {
  _Phone(this.net, this.name, {bool convert = true}) : address = addr(name) {
    net.phones[address] = this;
    events = EventService(host: this, disk: MemoryLedgerDisk(), now: _now);
    plans = PlanService(
      host: this,
      disk: planDisk,
      events: events,
      closeFriends: () => close,
      convert: convert,
      now: _now,
    );
  }

  final _Net net;
  final String name;
  final String address;
  final Set<String> friendSet = <String>{};
  List<String> close = <String>[];
  final MemoryLedgerDisk planDisk = MemoryLedgerDisk();
  late final EventService events;
  late final PlanService plans;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  int _now() => net.clock;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    final _Phone? other = net.phones[PeerShareCodec.normalizeAddress(to)];
    if (other == null) {
      return;
    }
    final SignalTransportFrame frame = SignalTransportFrame(
      from: address,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
      receivedAtMillis: 0,
    );
    net.inFlight++;
    unawaited(
      Future<void>(() async {
        try {
          await other.plans.handle(frame);
          await other.events.handle(frame);
        } finally {
          net.inFlight--;
        }
      }),
    );
  }

  @override
  List<String> friends() => friendSet.toList();

  @override
  bool isFriend(String a) =>
      friendSet.contains(PeerShareCodec.normalizeAddress(a));

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) =>
      net.phones[PeerShareCodec.normalizeAddress(a)]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);
}

/// Saturday 10:00 after the test's Wednesday.
int _saturday(_Net net) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(net.clock);
  return DateTime(d.year, d.month, d.day + 3, 10).millisecondsSinceEpoch;
}

void main() {
  test('friends answer, everyone sees who is in, and at the threshold the '
      'plan becomes an event with a chat', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'a1');
    final _Phone bob = _Phone(net, 'b2');
    final _Phone cela = _Phone(net, 'c3');
    final _Phone dawid = _Phone(net, 'd4');
    net
      ..link(ania, bob)
      ..link(ania, cela)
      ..link(ania, dawid);
    final List<String> chats = <String>[];
    ania.plans.onEvent = (WeekendPlan plan, MeetEvent event) async {
      chats.add('${plan.title}: ${plan.joined.length}');
    };

    final WeekendPlan p = await ania.plans.create(
      title: '  Rower nad Wisłą ',
      startsAt: _saturday(net),
      place: 'Bulwary',
    );
    await net.settle();
    expect(p.title, 'Rower nad Wisłą');
    expect(p.threshold, kPlanDefaultThreshold);
    final WeekendPlan atBob = bob.plans.plan(p.id)!;
    expect(atBob.isMine, isFalse);
    expect(atBob.organizer, ania.address);
    expect(atBob.place, 'Bulwary');
    expect(bob.shown.single.title, contains('Rower nad Wisłą'));
    expect(bob.shown.single.body, contains('Sobota, 10:00'));

    await bob.plans.answer(p.id, PlanAnswerKind.join);
    await cela.plans.answer(p.id, PlanAnswerKind.maybe);
    await net.settle();
    WeekendPlan mine = ania.plans.plan(p.id)!;
    expect(mine.joinCount, 1);
    expect(mine.maybe.single.name, 'c3');
    expect(mine.isEvent, isFalse);
    // Everyone has the current list.
    expect(dawid.plans.plan(p.id)!.answers.keys.toSet(), <String>{
      bob.address,
      cela.address,
    });
    expect(bob.plans.myAnswer(p.id), PlanAnswerKind.join);
    expect(
      ania.shown.where((RuntimeSystemNotification n) => n.title.contains('b2')),
      hasLength(1),
    );

    // Changing one's mind: "Może" becomes "Dołączam".
    await cela.plans.answer(p.id, PlanAnswerKind.join);
    await net.settle();
    expect(ania.plans.plan(p.id)!.joinCount, 2);
    expect(ania.plans.plan(p.id)!.isEvent, isFalse);

    await dawid.plans.answer(p.id, PlanAnswerKind.join);
    await net.settle();
    mine = ania.plans.plan(p.id)!;
    expect(mine.isEvent, isTrue);
    final MeetEvent e = ania.events.event(mine.eventId!)!;
    expect(e.title, 'Rower nad Wisłą');
    expect(e.kind, EventKind.meeting);
    expect(e.startsAt, _saturday(net));
    expect(e.guests.keys.toSet(), <String>{
      bob.address,
      cela.address,
      dawid.address,
    });
    expect(chats, <String>['Rower nad Wisłą: 3']);
    // The friends got the invitation and see the plan is an event now.
    expect(bob.events.event(e.id), isNotNull);
    expect(bob.plans.plan(p.id)!.eventId, e.id);
    // Answers are over.
    await bob.plans.answer(p.id, null);
    await net.settle();
    expect(ania.plans.plan(p.id)!.joinCount, 3);
  });

  test('friends of friends answer through the friend in between, who vouches '
      'for them', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'a1');
    final _Phone kuba = _Phone(net, 'b2');
    final _Phone ola = _Phone(net, 'c3');
    final _Phone dalej = _Phone(net, 'd4');
    net
      ..link(ania, kuba)
      ..link(kuba, ola)
      ..link(ola, dalej);

    final WeekendPlan p = await ania.plans.create(
      title: 'Planszówki',
      startsAt: _saturday(net),
      reach: PlanReach.friendsOfFriends,
      threshold: 2,
    );
    await net.settle();
    expect(kuba.plans.viaOf(p.id), isNull);
    expect(ola.plans.plan(p.id), isNotNull, reason: 'Kuba passed it on');
    expect(ola.plans.viaOf(p.id), kuba.address);
    expect(ola.shown.single.body, contains('przez b2'));
    expect(dalej.plans.plan(p.id), isNull, reason: 'only one step further');

    await ola.plans.answer(p.id, PlanAnswerKind.join);
    await net.settle();
    final PlanAnswer olaIn = ania.plans.plan(p.id)!.answers[ola.address]!;
    expect(olaIn.name, 'c3');
    expect(olaIn.via, kuba.address);
    expect(olaIn.viaName, 'b2');
    // Ola sees herself on the list, through Kuba.
    expect(ola.plans.plan(p.id)!.answers[ola.address]!.via, kuba.address);
    expect(ania.plans.plan(p.id)!.isEvent, isFalse);

    await kuba.plans.answer(p.id, PlanAnswerKind.join);
    await net.settle();
    final WeekendPlan mine = ania.plans.plan(p.id)!;
    expect(mine.isEvent, isTrue);
    final MeetEvent e = ania.events.event(mine.eventId!)!;
    expect(e.guest(ola.address)!.broughtBy, kuba.address);
    expect(
      ola.events.event(e.id),
      isNotNull,
      reason: 'the invitation came through Kuba',
    );
  });

  test(
    'only people in reach answer; nobody answers for someone else',
    () async {
      final _Net net = _Net();
      final _Phone ania = _Phone(net, 'a1');
      final _Phone bob = _Phone(net, 'b2');
      final _Phone cela = _Phone(net, 'c3');
      final _Phone obcy = _Phone(net, 'e5');
      net
        ..link(ania, bob)
        ..link(ania, cela);
      ania.close = <String>[bob.address];

      final WeekendPlan p = await ania.plans.create(
        title: 'Kolacja u mnie',
        startsAt: _saturday(net),
        reach: PlanReach.close,
      );
      await net.settle();
      expect(bob.plans.plan(p.id), isNotNull);
      expect(cela.plans.plan(p.id), isNull, reason: 'only close friends');

      Future<void> answer(_Phone from, Map<String, dynamic> extra) =>
          ania.plans.handle(
            SignalTransportFrame(
              from: from.address,
              payload: <String, dynamic>{
                'type': PlanTypes.answer,
                'id': p.id,
                's': 'join',
                ...extra,
              },
              receivedAtMillis: 0,
            ),
          );
      // A friend outside the reach, a stranger, and a friend answering for
      // someone else (only for friends of friends).
      await answer(cela, const <String, dynamic>{});
      await answer(obcy, const <String, dynamic>{});
      await answer(bob, <String, dynamic>{'by': obcy.address, 'n': 'Obcy'});
      expect(ania.plans.plan(p.id)!.answers, isEmpty);

      await answer(bob, const <String, dynamic>{});
      expect(ania.plans.plan(p.id)!.answers.keys.toList(), <String>[
        bob.address,
      ]);
    },
  );

  test('a plan can be taken back, and one nobody joined fades after its '
      'time', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'a1');
    final _Phone bob = _Phone(net, 'b2');
    net.link(ania, bob);

    final WeekendPlan cancelled = await ania.plans.create(
      title: 'Kino',
      startsAt: _saturday(net),
    );
    final WeekendPlan quiet = await ania.plans.create(
      title: 'Spacer',
      startsAt: _saturday(net) + 3600 * 1000,
    );
    await net.settle();
    expect(bob.plans.plans, hasLength(2));

    await ania.plans.cancel(cancelled.id);
    await net.settle();
    expect(bob.plans.plan(cancelled.id)!.cancelled, isTrue);
    expect(bob.plans.plans.map((WeekendPlan p) => p.id).toList(), <String>[
      quiet.id,
    ]);
    // Taken back: no answers any more.
    await bob.plans.answer(cancelled.id, PlanAnswerKind.join);
    expect(bob.plans.myAnswer(cancelled.id), isNull);

    net.clock = quiet.startsAt + kPlanFadeAfter.inMilliseconds + 1;
    expect(ania.plans.plans, isEmpty);
    expect(bob.plans.plans, isEmpty);
    expect(ania.plans.plan(quiet.id)!.isEvent, isFalse);
  });

  test('answers taken in by the background service are turned into an '
      'event by the app', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'a1', convert: false);
    final _Phone bob = _Phone(net, 'b2');
    final _Phone cela = _Phone(net, 'c3');
    net
      ..link(ania, bob)
      ..link(ania, cela);

    final WeekendPlan p = await ania.plans.create(
      title: 'Grill',
      startsAt: _saturday(net),
      threshold: 2,
    );
    await net.settle();
    await bob.plans.answer(p.id, PlanAnswerKind.join);
    await cela.plans.answer(p.id, PlanAnswerKind.join);
    await net.settle();
    expect(ania.plans.plan(p.id)!.joinCount, 2);
    expect(ania.plans.plan(p.id)!.isEvent, isFalse);

    // The app reads what the background service kept, then converts.
    final PlanService app = PlanService(
      host: ania,
      disk: ania.planDisk,
      events: ania.events,
      now: () => net.clock,
    );
    await app.load();
    await app.checkThresholds();
    await net.settle();
    expect(app.plan(p.id)!.isEvent, isTrue);
    expect(bob.plans.plan(p.id)!.isEvent, isTrue);
  });

  test('plans travel as JSON with limits', () {
    final WeekendPlan p = WeekendPlan(
      id: 'abc',
      organizer: addr('a1'),
      organizerName: 'Ania',
      title: 'Rower',
      startsAt: 1000,
      reach: PlanReach.friendsOfFriends,
      threshold: 4,
      answers: <String, PlanAnswer>{
        addr('b2'): PlanAnswer(
          address: addr('b2'),
          name: 'Bob',
          kind: PlanAnswerKind.maybe,
          at: 5,
          via: addr('c3'),
          viaName: 'Cela',
        ),
      },
      updatedAt: 7,
    );
    final WeekendPlan back = WeekendPlan.fromJson(
      jsonDecode(jsonEncode(p.toJson())),
    )!;
    expect(back.reach, PlanReach.friendsOfFriends);
    expect(back.threshold, 4);
    expect(back.maybe.single.viaName, 'Cela');
    expect(back.answers[addr('b2')]!.via, addr('c3'));
    expect(back.updatedAt, 7);

    final Map<String, dynamic> odd = p.toJson()
      ..['min'] = 1000
      ..['title'] = 'x' * 500
      ..['reach'] = 'everyone';
    final WeekendPlan clipped = WeekendPlan.fromJson(odd)!;
    expect(clipped.threshold, kPlanMaxThreshold);
    expect(clipped.title.length, kPlanMaxTitle);
    expect(clipped.reach, PlanReach.close);
    expect(WeekendPlan.fromJson(p.toJson()..['title'] = '  '), isNull);
  });

  test('plans and answers reach friends who are offline now', () {
    expect(kReliablePayloadTypes, containsAll(PlanTypes.all));
  });

  test('when a plan is, said the short way', () {
    final int now = DateTime(2026, 10, 14, 12).millisecondsSinceEpoch;
    int at(int day, int hour) =>
        DateTime(2026, 10, day, hour).millisecondsSinceEpoch;
    expect(planWhen(at(14, 18), now), 'Dziś, 18:00');
    expect(planWhen(at(15, 10), now), 'Jutro, 10:00');
    expect(planWhen(at(17, 10), now), 'Sobota, 10:00');
    expect(planWhen(at(25, 9), now), '25.10, 09:00');
  });
}
