import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/plan/plan_model.dart';
import 'package:zen/src/features/meet/plan/plan_service.dart';
import 'package:zen/src/features/meet/presentation/plan_screen.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

/// A Wednesday at noon.
final int _now = DateTime(2026, 10, 14, 12).millisecondsSinceEpoch;

final class _Host implements EventHost {
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];
  final Map<String, String> names = <String, String>{
    addr('b2'): 'Bartek',
    addr('c3'): 'Cela',
  };

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async =>
      sent.add((to, payload));

  @override
  List<String> friends() => names.keys.toList();

  @override
  bool isFriend(String a) =>
      names.containsKey(PeerShareCodec.normalizeAddress(a));

  @override
  String ownAddress() => addr('a1');

  @override
  String ownName() => 'Ania';

  @override
  String nameOf(String a) => names[PeerShareCodec.normalizeAddress(a)] ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}
}

/// Bartek's plan as his phone sends it.
SignalTransportFrame _fromBartek({String? eventId}) => SignalTransportFrame(
  from: addr('b2'),
  payload: <String, dynamic>{
    'type': PlanTypes.plan,
    'p': WeekendPlan(
      id: 'rower1',
      organizer: addr('b2'),
      organizerName: 'Bartek',
      title: 'Rower nad Wisłą',
      place: 'Bulwary',
      startsAt: DateTime(2026, 10, 17, 10).millisecondsSinceEpoch,
      eventId: eventId,
      updatedAt: 5,
    ).toJson(),
  },
  receivedAtMillis: 0,
);

Future<void> _pump(
  WidgetTester tester,
  PlanService plans, {
  ThemeData? theme,
  Size size = const Size(360, 800),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ZenTheme.light(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: PlanBoard(plans: plans),
    ),
  );
  await tester.pump();
}

void main() {
  late _Host host;
  late PlanService plans;

  setUp(() => host = _Host());

  // Made inside each test: its futures must belong to the test's fake clock.
  PlanService make() => plans = PlanService(
    host: host,
    disk: MemoryLedgerDisk(),
    now: () => _now,
  );

  testWidgets('an empty board invites to put out a plan, which goes to '
      'friends', (WidgetTester tester) async {
    await _pump(tester, make());
    expect(find.byKey(const Key('plan-empty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('plan-title')),
      'Rower nad Wisłą',
    );
    await tester.pump();
    for (final String key in <String>[
      'plan-reach-friendsOfFriends',
      'plan-threshold-4',
      'plan-create',
    ]) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    final WeekendPlan p = plans.plans.single;
    expect(p.title, 'Rower nad Wisłą');
    expect(p.threshold, 4);
    expect(p.reach, PlanReach.friendsOfFriends);
    // The coming Saturday, 10:00.
    expect(p.startsAt, DateTime(2026, 10, 17, 10).millisecondsSinceEpoch);
    expect(
      host.sent.where(
        ((String, Map<String, dynamic>) s) =>
            s.$2['type'] == PlanTypes.plan && s.$2['hops'] == 1,
      ),
      hasLength(2),
    );
    expect(find.byKey(Key('plan-${p.id}')), findsOneWidget);
    expect(find.text('Chętnych: 0 z 4'), findsOneWidget);
    expect(find.text('Twój plan'), findsOneWidget);
    // The sheet's text controllers are disposed a moment later.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a friend\'s plan is joined, and tapping again takes it back', (
    WidgetTester tester,
  ) async {
    await _pump(tester, make());
    await plans.handle(_fromBartek());
    await tester.pump();
    expect(find.text('Rower nad Wisłą'), findsOneWidget);
    expect(find.text('Bartek'), findsOneWidget);
    expect(find.text('Bulwary'), findsOneWidget);
    expect(find.text('Sobota, 10:00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-join-rower1')));
    await tester.pump();
    expect(plans.myAnswer('rower1'), PlanAnswerKind.join);
    expect(host.sent.last.$1, addr('b2'));
    expect(host.sent.last.$2, <String, dynamic>{
      'type': PlanTypes.answer,
      'id': 'rower1',
      's': 'join',
    });
    expect(find.text('Dołączasz'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-join-rower1')));
    await tester.pump();
    expect(plans.myAnswer('rower1'), isNull);
    expect(host.sent.last.$2.containsKey('s'), isFalse);
    expect(find.text('Dołączam'), findsOneWidget);
  });

  testWidgets('a plan that became an event says so, with no answers left', (
    WidgetTester tester,
  ) async {
    await _pump(tester, make());
    await plans.handle(_fromBartek(eventId: 'ev1'));
    await tester.pump();
    expect(find.text('Jest ekipa! Plan jest już wydarzeniem.'), findsOneWidget);
    expect(find.byKey(const Key('plan-join-rower1')), findsNothing);
    expect(find.text('Zaproszenie przyjdzie od organizatora.'), findsOneWidget);
  });

  testWidgets('fits a narrow phone with large text, in the dark theme', (
    WidgetTester tester,
  ) async {
    final PlanService withEvents = PlanService(
      host: host,
      disk: MemoryLedgerDisk(),
      events: EventService(host: host, disk: MemoryLedgerDisk()),
      now: () => _now,
    );
    await _pump(
      tester,
      withEvents,
      theme: ZenTheme.dark(),
      size: const Size(320, 640),
      textScale: 1.8,
    );
    await withEvents.handle(_fromBartek());
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('plan-new')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('plan-create')), findsOneWidget);
  });
}
