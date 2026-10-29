import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/graph/graph_full_screen.dart';
import 'package:zen/src/features/meet/graph/graph_insights.dart';
import 'package:zen/src/features/meet/graph/graph_notes.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/graph/graph_panels.dart';
import 'package:zen/src/features/meet/graph/graph_providers.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// "Oś czasu": how the graph grew, from the dates this phone knows. The
// order comes from the data, the slider shows only who was there on its
// day, the timeline works over every mode, steps without growing when the
// animations are off, and plays without laying the graph out again.

const int _day = 24 * 3600 * 1000;

/// A fixed "now" (midday), so the days do not depend on when tests run.
const int _now = 1800000000000 - 1800000000000 % _day + _day ~/ 2;

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

final String _ania = addr('a1');
final String _bartek = addr('b2');
final String _celina = addr('c3');
final String _xawery = addr('e5');
final String _lucja = addr('f6');

GraphNode _node(String a, String name, int ring, [List<String>? via]) =>
    GraphNode(address: a, name: name, ring: ring, via: via);

GroupProfile _group(
  String id,
  int createdAt,
  List<String> members, {
  bool pending = false,
}) => GroupProfile(
  id: id,
  name: id,
  description: '',
  avatarPreset: '',
  createdById: members.first,
  createdAtMillis: createdAt,
  memberAddresses: members,
  isInvitePending: pending,
);

/// Ania 300 days ago, Bartek 100 days ago (but in a group since 200 days
/// ago), Celina 20 days ago; Xawery (through Ania) seen 50 days ago, Łucja
/// (through Ania) from before the dates were kept.
GraphNotes _notes() => GraphNotes()
  ..baseline = _now - 400 * _day
  ..friendSince[_ania] = _now - 300 * _day
  ..friendSince[_bartek] = _now - 100 * _day
  ..friendSince[_celina] = _now - 20 * _day
  ..farSince[_xawery] = _now - 50 * _day
  ..farSince[_lucja] = 0;

List<GraphNode> _nodes() => <GraphNode>[
  _node(_ania, 'Ania', 1),
  _node(_bartek, 'Bartek', 2),
  _node(_celina, 'Celina', 2),
  _node(_xawery, 'Xawery', 4, <String>[_ania]),
  _node(_lucja, 'Łucja', 4, <String>[_ania]),
];

final class _Host implements MeetHost {
  _Host(this.names);

  final Map<String, String> names;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => names.keys.toList();

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) =>
      names.containsKey(PeerShareCodec.normalizeAddress(a));

  @override
  bool isSelf(String a) => false;

  @override
  String nameOf(String a) =>
      names[PeerShareCodec.normalizeAddress(a)] ?? 'Ktoś';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

FriendProfile _friend(String address, String name) => FriendProfile(
  address: address,
  displayName: name,
  status: FriendRelationshipStatus.accepted,
);

/// The graph with the friends and dates above, opened on [view].
Future<ProviderContainer> _pumpGraph(
  WidgetTester tester, {
  GraphView view = const GraphView(),
}) async {
  tester.view.physicalSize = const Size(480, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Host host = _Host(<String, String>{
    _ania: 'Ania',
    _bartek: 'Bartek',
    _celina: 'Celina',
  });
  final MeetService meet = MeetService(
    host: host,
    store: MeetStore(MemoryLedgerDisk()),
    now: () => _now,
  );
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  await tester.runAsync(() async {
    await meet.handle(
      SignalTransportFrame(
        from: _ania,
        payload: <String, dynamic>{
          'type': MeetTypes.friendList,
          'l': <Map<String, String>>[
            <String, String>{'a': _xawery, 'n': 'Xawery'},
            <String, String>{'a': _lucja, 'n': 'Łucja'},
          ],
          'd': 'list-of-ania',
        },
        receivedAtMillis: 0,
      ),
    );
    await disk.write(
      GraphNotesService.storeKey,
      Uint8List.fromList(utf8.encode(jsonEncode(_notes().toJson()))),
    );
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                _ania: _friend(_ania, 'Ania'),
                _bartek: _friend(_bartek, 'Bartek'),
                _celina: _friend(_celina, 'Celina'),
              },
            ),
            groups: <String, GroupProfile>{
              'g': _group('g', _now - 200 * _day, <String>[_bartek, _celina]),
            },
          ),
        ),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ledgerDiskProvider.overrideWithValue(disk),
        graphNotesProvider.overrideWith((Ref ref) {
          final GraphNotesService notes = GraphNotesService(
            disk: disk,
            now: () => _now,
          );
          unawaited(notes.load());
          ref.onDispose(notes.dispose);
          return notes;
        }),
        meetServiceProvider.overrideWithValue(meet),
        pyramidServiceProvider.overrideWithValue(
          PyramidService(
            host: MeetEventHost(host, address: () => '', name: () => 'Ja'),
            disk: MemoryLedgerDisk(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        home: GraphScreen(initial: view),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(GraphScreen)));
}

/// The people a screen reader finds on the picture now.
Set<String> _onPicture(WidgetTester tester) {
  final List<String> labels = <String>[];
  void visit(SemanticsNode node) {
    labels.add(node.label);
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  final PipelineOwner owner = tester
      .renderObject(find.byKey(const Key('graph-canvas')))
      .owner!;
  visit(owner.semanticsOwner!.rootSemanticsNode!);
  return <String>{
    for (final String name in <String>[
      'Ania',
      'Bartek',
      'Celina',
      'Xawery',
      'Łucja',
    ])
      if (labels.any((String l) => l.startsWith('$name, '))) name,
  };
}

/// The phase of [at] on the timeline the screen builds for the data above.
double _phase(int at) {
  final GraphTimeline tl = graphGrowth(
    _nodes(),
    _notes(),
    now: _now,
    firstContact: <String, int>{
      _bartek: _now - 200 * _day,
      _celina: _now - 200 * _day,
    },
  );
  return tl.phaseOf(at);
}

Future<void> _scrub(WidgetTester tester, double phase) async {
  tester.widget<Slider>(find.byKey(const Key('graph-time-slider'))).onChanged!(
    phase,
  );
  await tester.pump();
}

GraphPainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((CustomPaint p) => p.painter)
    .whereType<GraphPainter>()
    .single;

void main() {
  group('the order comes from the data', () {
    test('the story starts the day before the earliest date; friends come '
        'on the earliest of their dates, friends of friends not before the '
        'friend who connects them', () {
      final GraphTimeline tl = graphGrowth(
        _nodes(),
        _notes(),
        now: _now,
        firstContact: groupContactDays(<GroupProfile>[
          _group('g', _now - 200 * _day, <String>[_bartek, _celina]),
          // Not joined yet: no contact.
          _group('p', _now - 380 * _day, <String>[_celina], pending: true),
        ]),
        metAt: <String, int>{_ania: _now - 10 * _day},
      );
      final int startDay = _now - 300 * _day;
      expect(tl.from, startDay - startDay % _day - _day);
      expect(tl.to, _now - _now % _day + _day);
      expect(tl.timeAt(tl.born[0]), closeTo(_now - 300 * _day, _day));
      // Bartek: in a group since 200 days ago, a friend since 100.
      expect(tl.timeAt(tl.born[1]), closeTo(_now - 200 * _day, _day));
      // Celina: the group too, earlier than her friendship.
      expect(tl.born[2], tl.born[1]);
      expect(tl.timeAt(tl.born[3]), closeTo(_now - 50 * _day, _day));
      expect(tl.born[4], tl.born[0], reason: 'Łucja comes with Ania');
      // In the order they came; a tie keeps the layout's order.
      expect(tl.order.toList(), <int>[0, 4, 1, 2, 3]);
      // Every moment once, in order: three arrival days and one meeting.
      expect(tl.steps.length, 4);
      for (int i = 1; i < tl.steps.length; i++) {
        expect(tl.steps[i], greaterThan(tl.steps[i - 1]));
      }
      expect(tl.nextStep(-1), tl.born[0]);
      expect(tl.nextStep(tl.born[0]), tl.born[1]);
      expect(tl.nextStep(tl.steps.last), 1);
      expect(tl.knownAt(3, tl.born[1]), isFalse);
      expect(tl.knownAt(3, tl.born[3]), isTrue);
    });

    test('with no dates at all the story is the last 12 months, everyone '
        'there from its start', () {
      final GraphNotes none = GraphNotes()..baseline = _now;
      final GraphTimeline tl = graphGrowth(_nodes(), none, now: _now);
      expect(tl.to - tl.from, 360 * _day);
      expect(tl.order, isEmpty);
      expect(tl.knownAt(0, 0), isTrue);
    });

    test('a group counts from its start, the earliest one wins, an '
        'invitation not accepted counts for nothing', () {
      expect(
        groupContactDays(<GroupProfile>[
          _group('a', 500, <String>[_ania, _bartek]),
          _group('b', 300, <String>[_bartek]),
          _group('c', 100, <String>[_celina], pending: true),
          _group('d', 0, <String>[_xawery]),
        ]),
        <String, int>{_ania: 500, _bartek: 300},
      );
    });
  });

  testWidgets('scrubbing to a day shows only the people known by then', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpGraph(tester, view: const GraphView(mode: GraphMode.time));
    expect(find.byKey(const Key('graph-time-bar')), findsOneWidget);
    // "Oś czasu" itself has no close button and no extra toggle.
    expect(find.byKey(const Key('graph-time-close')), findsNothing);
    expect(find.byKey(const Key('graph-timeline-toggle')), findsNothing);
    expect(_onPicture(tester), <String>{
      'Ania',
      'Bartek',
      'Celina',
      'Xawery',
      'Łucja',
    });

    // 250 days ago: Ania (and Łucja, through her) only.
    await _scrub(tester, _phase(_now - 250 * _day));
    expect(_onPicture(tester), <String>{'Ania', 'Łucja'});
    expect(
      tester.widget<Text>(find.byKey(const Key('graph-time-state'))).data,
      contains(graphDate(_now - 250 * _day)),
    );
    // 150 days ago: Bartek and Celina came with their group.
    await _scrub(tester, _phase(_now - 150 * _day));
    expect(_onPicture(tester), <String>{'Ania', 'Łucja', 'Bartek', 'Celina'});
    // 30 days ago: Xawery too.
    await _scrub(tester, _phase(_now - 30 * _day));
    expect(_onPicture(tester), hasLength(5));
    // Before anyone: nobody to tap.
    await _scrub(tester, 0);
    expect(_onPicture(tester), isEmpty);

    // Play from there, pause on the way, go on at double speed.
    await tester.tap(find.byKey(const Key('graph-time-play')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byKey(const Key('graph-time-play')));
    await tester.pump();
    final double paused = tester
        .widget<Slider>(find.byKey(const Key('graph-time-slider')))
        .value;
    expect(paused, greaterThan(0.2));
    expect(paused, lessThan(0.5));
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.widget<Slider>(find.byKey(const Key('graph-time-slider'))).value,
      paused,
    );
    await tester.tap(find.byKey(const Key('graph-time-speed')));
    await tester.pump();
    expect(find.text('2×'), findsOneWidget);
    await tester.tap(find.byKey(const Key('graph-time-play')));
    await tester.pump();
    // The rest of the story at double speed: well under the normal pace.
    await tester.pump(kGraphTimePlay * 0.4);
    await tester.pump();
    expect(
      tester.widget<Slider>(find.byKey(const Key('graph-time-slider'))).value,
      1,
    );
    expect(_onPicture(tester), hasLength(5));
    expect(_painter(tester).still, isFalse);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the timeline opens over any mode keeping its colours, and '
      'with the animations off it steps from one day to the next', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpGraph(tester);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('graph-mode-presence')))
          .selected,
      isTrue,
    );
    expect(find.byKey(const Key('graph-time-bar')), findsNothing);

    await tester.tap(find.byKey(const Key('graph-timeline-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('graph-time-bar')), findsOneWidget);
    // Still the presence mode, with the timeline over it.
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('graph-mode-presence')))
          .selected,
      isTrue,
    );
    expect(find.byKey(const Key('graph-legend-presence')), findsOneWidget);
    expect(_painter(tester).still, isTrue);
    expect(_onPicture(tester), isEmpty);

    // One step: Ania's day, nothing in between.
    await tester.pump(kGraphTimeStep);
    expect(_onPicture(tester), <String>{'Ania', 'Łucja'});
    final GraphPainter painter = _painter(tester);
    expect(
      painter.clock!.value,
      closeTo(_phase(_now - 300 * _day), 0.0001),
      reason: 'stopped exactly on the day, not between two',
    );
    await tester.pump(kGraphTimeStep);
    expect(_onPicture(tester), <String>{'Ania', 'Łucja', 'Bartek', 'Celina'});
    await tester.pump(kGraphTimeStep);
    expect(_onPicture(tester), hasLength(5));
    await tester.pump(kGraphTimeStep);
    expect(
      tester.widget<Slider>(find.byKey(const Key('graph-time-slider'))).value,
      1,
    );

    // The mode stays when the timeline closes.
    await tester.tap(find.byKey(const Key('graph-time-close')));
    await tester.pump();
    expect(find.byKey(const Key('graph-time-bar')), findsNothing);
    expect(find.byKey(const Key('graph-timeline-toggle')), findsOneWidget);
    expect(_onPicture(tester), hasLength(5));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('playing 500 people is only repainting: the timeline is built once '
      'in milliseconds and a frame paints well within 60 fps', () {
    const int count = 500;
    final List<GraphNode> nodes = <GraphNode>[
      for (int i = 0; i < 150; i++)
        _node(addr('1${i.toRadixString(16)}'), 'P$i', 1 + i % 3),
      for (int i = 0; i < count - 150; i++)
        _node(addr('2${i.toRadixString(16)}'), 'F$i', 4, <String>[
          addr('1${(i % 150).toRadixString(16)}'),
          addr('1${((i * 7) % 150).toRadixString(16)}'),
        ]),
    ];
    final GraphNotes notes = GraphNotes()..baseline = _now - 1000 * _day;
    for (int i = 0; i < 150; i++) {
      notes.friendSince[nodes[i].address] = _now - (900 - i * 5) * _day;
    }
    for (int i = 150; i < count; i++) {
      notes.farSince[nodes[i].address] = _now - (600 - i) * _day;
    }
    final Stopwatch build = Stopwatch()..start();
    final GraphTimeline tl = graphGrowth(nodes, notes, now: _now);
    build.stop();
    expect(build.elapsedMilliseconds, lessThan(200));
    expect(tl.order.length, count);

    final GraphLayout layout = graphLayout(nodes, const Size(900, 900));
    final Map<String, int> index = <String, int>{
      for (int i = 0; i < nodes.length; i++) nodes[i].address: i,
    };
    final List<int> ef = <int>[];
    final List<int> et = <int>[];
    for (int i = 0; i < nodes.length; i++) {
      if (nodes[i].isFriend) {
        ef.add(-1);
        et.add(i);
      } else {
        for (final String v in nodes[i].via) {
          ef.add(index[v]!);
          et.add(i);
        }
      }
    }
    final GraphScene scene = GraphScene(
      layout: layout,
      from: Float32List.fromList(layout.xy),
      edgeFrom: Int32List.fromList(ef),
      edgeTo: Int32List.fromList(et),
      links: Int32List.fromList(<int>[
        for (int i = 1; i < 150; i++) ...<int>[i - 1, i],
      ]),
    );
    final ZenColors zen = ZenTheme.dark().extension<ZenColors>()!;
    final GraphLook look = graphLook(
      scene: scene,
      mode: GraphMode.presence,
      facts: GraphFacts(),
      zen: zen,
    );
    final Float32List xy = layout.xy;
    final Float32List before = Float32List.fromList(xy);
    final AnimationController clock = AnimationController(
      vsync: const TestVSync(),
      value: 0,
    );
    final GraphLabelCache labels = GraphLabelCache();
    final GraphPainter painter = GraphPainter(
      scene: scene,
      look: look,
      progress: const AlwaysStoppedAnimation<double>(1),
      labels: labels,
      me: zen.accent,
      meText: zen.onAccent,
      text: zen.textPrimary,
      labelBg: zen.surfaceRaised,
      guide: zen.outlineSoft,
      timeline: tl,
      clock: clock,
    );
    // A warm-up frame (labels laid out once), then two seconds of frames.
    void frame(double at) {
      clock.value = at;
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(900, 900));
      recorder.endRecording().dispose();
    }

    frame(1);
    const int frames = 120;
    final Stopwatch paint = Stopwatch()..start();
    for (int f = 0; f < frames; f++) {
      frame(f / (frames - 1));
    }
    paint.stop();
    // 16 ms a frame at 60 fps; a test build on a busy machine is given
    // twice that.
    expect(paint.elapsedMilliseconds / frames, lessThan(32));
    // The layout was not touched by playing.
    expect(identical(scene.layout.xy, xy), isTrue);
    expect(scene.layout.xy, before);
    clock.dispose();
    labels.clear();
  });
}
