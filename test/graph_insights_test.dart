import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/graph/graph_insights.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';
import 'package:zen/src/features/meet/graph/graph_notes.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/graph/graph_snapshot.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/graph/trust_map.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

const int _day = 24 * 3600 * 1000;

FriendProfile _friend(String address, String name) => FriendProfile(
  address: address,
  displayName: name,
  status: FriendRelationshipStatus.accepted,
);

SocialHubState _social(Map<String, String> people) =>
    SocialHubState.empty().copyWith(
      book: FriendshipBook.restore(
        profiles: <String, FriendProfile>{
          for (final MapEntry<String, String> e in people.entries)
            e.key: _friend(e.key, e.value),
        },
      ),
    );

GraphNode _node(String a, String name, int ring, [List<String>? via]) =>
    GraphNode(address: a, name: name, ring: ring, via: via);

ChatMessage _msg(int at, {bool system = false}) => ChatMessage(
  id: 'm$at',
  sender: 'x',
  text: 'hej',
  sentAtMillis: at,
  direction: system
      ? ChatMessageDirection.system
      : ChatMessageDirection.incoming,
);

void main() {
  final String ania = addr('a1');
  final String bartek = addr('b2');
  final String celina = addr('c3');
  final String darek = addr('d4');
  final String ewa = addr('e5');
  final String xawery = addr('f6');
  final String zenon = addr('f7');

  group('far people and long routes', () {
    test('people further away hang on someone drawn, ring 5, step by '
        'step', () {
      final MeetBook book = MeetBook()
        ..friendLists[ania] = <String, String>{xawery: 'Xawery'};
      final List<GraphNode> nodes = buildGraph(
        social: _social(<String, String>{ania: 'Ania'}),
        book: book,
        levelOf: (String _) => FriendLevel.friend,
        far: <String, FarPerson>{
          zenon: (name: 'Zenon', via: <String>{xawery}),
          // Known only through Zenon: drawn after him.
          ewa: (name: '', via: <String>{zenon}),
          // Nobody drawn knows them: not drawn.
          darek: (name: 'Darek', via: <String>{addr('99')}),
        },
      );
      final Map<String, GraphNode> by = <String, GraphNode>{
        for (final GraphNode n in nodes) n.address: n,
      };
      expect(by[zenon]!.ring, 5);
      expect(by[zenon]!.isFar, isTrue);
      expect(by[zenon]!.via, <String>[xawery]);
      expect(by[ewa]!.via, <String>[zenon]);
      expect(by[ewa]!.name, 'ktoś');
      expect(by.containsKey(darek), isFalse);
      // Friends of friends are never drawn again further out.
      expect(nodes.where((GraphNode n) => n.address == xawery), hasLength(1));
      expect(mutualCounts(nodes, book)[zenon], 0);
      // Their own address is never someone else.
      final List<GraphNode> withSelf = buildGraph(
        social: _social(<String, String>{ania: 'Ania'}),
        book: MeetBook()
          ..friendLists[ania] = <String, String>{celina: 'Ja', xawery: 'X'},
        levelOf: (String _) => FriendLevel.friend,
        self: (String a) => a == celina,
      );
      expect(withSelf.map((GraphNode n) => n.address), isNot(contains(celina)));
    });

    test('a route through what friends passed on has no limit of steps', () {
      final List<String> line = <String>[
        for (int i = 0; i < 12; i++) addr('1${i.toString().padLeft(2, '0')}'),
      ];
      final Map<String, Map<String, String>> known =
          <String, Map<String, String>>{
            for (int i = 0; i < line.length - 1; i++)
              line[i]: <String, String>{line[i + 1]: ''},
          };
      final GraphRoute r = graphRoute(
        friends: <String>[line.first],
        book: MeetBook(),
        target: line.last,
        friendsOf: (String p) => known[p] ?? const <String, String>{},
      );
      expect(r.path, line);
      expect(r.cost.hops, 12);
      expect(
        wayText(<String>['Ty', ...line]),
        'Ty → ${line[0]} → … 9 … → ${line[10]} → ${line[11]}',
      );
      expect(wayText(<String>['Ty', 'A', 'B']), 'Ty → A → B');
    });
  });

  group('filters', () {
    test('"Przyjaciele" alone, friends and close friends, everyone; a '
        'private circle name', () {
      expect(RingPreset.of(GraphFilters.allRings), RingPreset.all);
      expect(RingPreset.of(<int>{1, 2}), RingPreset.friends);
      expect(RingPreset.of(<int>{1}), RingPreset.close);
      expect(RingPreset.of(<int>{2}), isNull);
      final GraphNode close = _node(ania, 'Ania', 1);
      final GraphNode friend = _node(bartek, 'Bartek', 2);
      final GraphFacts facts = GraphFacts(
        inLabel: (String a, String label) => label == 'k' && a == bartek,
      );
      final GraphFilters onlyClose = GraphFilters(
        rings: RingPreset.close.rings,
      );
      expect(onlyClose.passes(close, facts), isTrue);
      expect(onlyClose.passes(friend, facts), isFalse);
      const GraphFilters label = GraphFilters(label: 'k');
      expect(label.active, 1);
      expect(label.passes(friend, facts), isTrue);
      expect(label.passes(close, facts), isFalse);
      expect(label.copyWith(label: () => null), const GraphFilters());
    });
  });

  group('timeline', () {
    test('people come on their day, friends of friends not before the '
        'friend who connects them, meetings ring on theirs', () {
      final int now = 400 * _day;
      final int from = monthsBack(now, 12);
      final GraphNotes notes = GraphNotes()
        ..baseline = from - _day
        ..friendSince[ania] = 0
        ..friendSince[bartek] = now - 90 * _day
        ..farSince[xawery] = 0;
      final List<GraphNode> nodes = <GraphNode>[
        _node(ania, 'Ania', 1),
        _node(bartek, 'Bartek', 2),
        _node(xawery, 'Xawery', 4, <String>[bartek]),
      ];
      final GraphTimeline tl = graphTimeline(
        nodes,
        notes,
        from: from,
        to: now,
        metAt: <String, int>{ania: now - 30 * _day},
      );
      expect(tl.born[0], lessThan(0), reason: 'there before the dates');
      expect(tl.born[1], closeTo(1 - 90 / 360, 0.01));
      expect(tl.born[2], tl.born[1], reason: 'came with Bartek');
      expect(tl.met[0], closeTo(1 - 30 / 360, 0.01));
      expect(tl.met[1], kTimelineNever);
      // Six months back: Ania only, not met yet; now: both, one meeting.
      expect(tl.countAt(0.5, nodes), (people: 1, met: 0));
      expect(tl.countAt(1, nodes), (people: 2, met: 1));
      expect(tl.timeAt(tl.phaseOf(now - 10 * _day)), now - 10 * _day);
    });
  });

  group('who to meet, bridges, long silences', () {
    test('friends of friends with most mutual friends and a matching '
        'intention first; one mutual friend is enough with a match', () {
      final List<GraphNode> nodes = <GraphNode>[
        _node(ania, 'Ania', 1),
        _node(bartek, 'Bartek', 2),
        _node(celina, 'Celina', 2),
        _node(xawery, 'Xawery', 4, <String>[ania, bartek, celina]),
        _node(zenon, 'Zenon', 4, <String>[ania]),
        _node(darek, 'Darek', 4, <String>[ania]),
        _node(ewa, 'Ewa', 4, <String>[ania, bartek]),
      ];
      final GraphFacts facts = GraphFacts(
        openOf: (String a) => a == zenon ? OpenToMeet.friends : null,
        statusOf: (String a) => a == ewa
            ? const IntentStatus(kind: IntentKind.out, setAt: 1)
            : null,
      );
      final List<MeetSuggestion> got = whoToMeet(
        nodes,
        facts,
        myOpen: OpenToMeet.both,
        myStatus: const IntentStatus(kind: IntentKind.out, setAt: 1),
      );
      expect(got.map((MeetSuggestion s) => s.node.address), <String>[
        ewa,
        xawery,
        zenon,
      ]);
      expect(got.first.match, isTrue);
      expect(got.first.mutual, 2);
      expect(
        whoToMeet(
          nodes,
          facts,
          skip: <String>{xawery, ewa},
        ).map((MeetSuggestion s) => s.node.address),
        isEmpty,
        reason: 'without a match two mutual friends are needed',
      );
      expect(openMatches(OpenToMeet.dates, OpenToMeet.friends), isFalse);
      expect(openMatches(OpenToMeet.dates, OpenToMeet.both), isTrue);
      expect(openMatches(null, OpenToMeet.both), isFalse);
    });

    test('a bridge alone connects two circles; a circle with no link is an '
        'island, with a hint whom to introduce', () {
      final List<GraphNode> nodes = <GraphNode>[
        for (final String a in <String>[
          ania,
          bartek,
          celina,
          darek,
          ewa,
          xawery,
        ])
          _node(a, 'N$a', 2),
      ];
      final Map<String, int> clusters = <String, int>{
        ania: 0,
        bartek: 0,
        celina: 1,
        darek: 1,
        ewa: 2,
        xawery: 2,
      };
      final List<(String, String)> links = <(String, String)>[
        (ania, bartek),
        (celina, darek),
        (ewa, xawery),
        (bartek, celina),
      ];
      final BridgeReport r = bridgesOf(
        nodes,
        clusters,
        links,
        mutual: <String, int>{ewa: 3, ania: 5},
      );
      expect(r.bridges, <String>{bartek, celina});
      expect(r.islands, <int>{2});
      expect(r.hints, <(String, String)>[(ewa, ania)]);
      // Two links between the circles through Bartek: he alone is the
      // bridge.
      final BridgeReport two = bridgesOf(nodes, clusters, <(String, String)>[
        ...links,
        (bartek, darek),
      ]);
      expect(two.bridges, <String>{bartek});
      expect(const BridgeReport().isEmpty, isTrue);
    });

    test('long silences: only what is known, not new friends, not snoozed, '
        'closest first', () {
      final int now = 1000 * _day;
      final GraphNotes notes = GraphNotes()
        ..baseline = now - 400 * _day
        ..neglectWeeks = 8
        ..friendSince[ania] = 0
        ..friendSince[bartek] = now - 300 * _day
        ..friendSince[celina] = now - 10 * _day
        ..friendSince[darek] = 0
        ..friendSince[ewa] = now - 300 * _day
        ..scanned.addAll(<String>[ania, bartek, celina, ewa])
        ..lastTalk[ania] = now - 100 * _day
        ..lastTalk[bartek] = now - 200 * _day
        ..lastTalk[ewa] = now - 3 * _day
        ..snoozed[darek] = now + _day;
      final List<GraphNode> nodes = <GraphNode>[
        _node(bartek, 'Bartek', 2),
        _node(ania, 'Ania', 1),
        _node(celina, 'Celina', 1),
        _node(darek, 'Darek', 2),
        _node(ewa, 'Ewa', 2),
        _node(xawery, 'Xawery', 4, <String>[ania]),
      ];
      List<String> who(Map<String, int> met) => <String>[
        for (final NeglectedFriend f in neglectedFriends(
          nodes,
          notes,
          now: now,
          metAt: met,
        ))
          f.node.address,
      ];
      expect(who(const <String, int>{}), <String>[ania, bartek]);
      // A meeting counts as much as a conversation.
      expect(who(<String, int>{ania: now - 7 * _day}), <String>[bartek]);
      notes.neglectWeeks = 26;
      expect(who(const <String, int>{}), <String>[bartek]);
    });
  });

  group('notes kept on this phone', () {
    test('dates from now on, older ones from conversations; private names; '
        'reminders; all read back', () async {
      int clock = 100 * _day;
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final GraphNotesService notes = GraphNotesService(
        disk: disk,
        now: () => clock,
      );
      await notes.observe(friends: <String>[ania], far: <String>[xawery]);
      expect(notes.notes.baseline, clock);
      expect(notes.notes.friendSince[ania], 0, reason: 'before the dates');
      expect(notes.notes.farSince[xawery], 0);
      clock += 5 * _day;
      await notes.observe(
        friends: <String>[ania, bartek],
        far: <String>[xawery, zenon],
      );
      expect(notes.notes.friendSince[bartek], clock);
      expect(notes.notes.farSince[zenon], clock);
      // Conversations: the first message dates a friendship from before,
      // the last real one is the last talk.
      await notes.scanConversations(<String>[ania, bartek], (String f) async {
        return f == ania
            ? <ChatMessage>[_msg(10 * _day, system: true), _msg(20 * _day)]
            : <ChatMessage>[_msg(clock + 1000)];
      });
      expect(notes.notes.friendSince[ania], 10 * _day);
      expect(notes.notes.lastTalk[ania], 20 * _day);
      expect(notes.notes.lastTalk[bartek], clock + 1000);
      expect(notes.notes.scanned, <String>{ania, bartek});
      // Read once only (unless asked again).
      int loads = 0;
      await notes.scanConversations(<String>[ania], (String f) async {
        loads++;
        return const <ChatMessage>[];
      });
      expect(loads, 0);

      final CircleLabel? label = await notes.setLabel(<String>{
        ania,
        bartek,
      }, '  Wspinaczka\n');
      expect(label!.name, 'Wspinaczka');
      // The same circle, a bit changed: the same label, renamed.
      final CircleLabel? again = await notes.setLabel(<String>{
        ania,
        bartek,
        celina,
      }, 'Ściana');
      expect(again!.id, label.id);
      expect(notes.notes.labels, hasLength(1));
      expect(
        labelFor(<String>{ania, bartek}, notes.notes.labels.values),
        again,
      );
      expect(labelFor(<String>{zenon, ewa}, notes.notes.labels.values), isNull);
      await notes.setNeglectWeeks(12);
      await notes.setNeglectWeeks(5);
      expect(notes.notes.neglectWeeks, 12);
      await notes.snooze(bartek, const Duration(days: 28));
      expect(notes.notes.snoozed[bartek], clock + 28 * _day);

      // Gone friends are forgotten.
      await notes.observe(friends: <String>[ania]);
      expect(notes.notes.friendSince.containsKey(bartek), isFalse);
      expect(notes.notes.snoozed.containsKey(bartek), isFalse);

      final GraphNotesService back = GraphNotesService(disk: disk);
      await back.load();
      expect(back.notes.friendSince, notes.notes.friendSince);
      expect(back.notes.labels.values.single.name, 'Ściana');
      expect(back.notes.neglectWeeks, 12);
      expect(back.notes.baseline, 100 * _day);
      expect(
        GraphNotes.fromJson(<String, dynamic>{'v': 2}).baseline,
        0,
        reason: 'another format is not read',
      );
      await notes.removeLabel(again.id);
      expect(notes.notes.labels, isEmpty);
      expect(cleanCircleLabel('a' * 80), hasLength(kCircleLabelMaxChars));
    });
  });

  group('trust map', () {
    test('the day of a meeting from signed acts, gatherings both went to, '
        'no scores', () {
      const String acc = 'account-of-celina';
      expect(
        metDayIn(<ActEntry>[
          (
            kind: 'met',
            space: 'acts/me',
            author: 'me',
            body: <String, dynamic>{'a': acc, 'd': '2026-03-04'},
          ),
          (
            kind: 'met',
            space: 'acts/someone',
            author: 'me',
            body: <String, dynamic>{'a': acc, 'd': '2020-01-01'},
          ),
          (
            kind: 'thanks',
            space: 'acts/me',
            author: 'me',
            body: <String, dynamic>{'a': acc, 'd': '2019-01-01'},
          ),
        ], acc),
        DateTime.utc(2026, 3, 4).millisecondsSinceEpoch,
      );
      expect(metDayIn(const <ActEntry>[], acc), isNull);
      MeetEvent event(String id, int at, {bool cancelled = false}) => MeetEvent(
        id: id,
        organizer: 'self',
        organizerName: 'Ja',
        title: 'Grill $id',
        startsAt: at,
        cancelled: cancelled,
      );
      final List<MeetEvent> events = <MeetEvent>[
        event('a', 10),
        event('b', 20),
        event('c', 30, cancelled: true),
        event('d', 9000),
      ];
      final TrustMap m = trustMapOf(
        address: celina,
        nameOf: (String a) => a,
        pyramidSince: 5000,
        events: events,
        went: (MeetEvent e, String? who) => who == null || e.id != 'a',
        now: 1000,
      );
      expect(m.sharedEvents.map((SharedEvent e) => e.title), <String>[
        'Grill b',
      ]);
      expect(m.pyramidSince, 5000);
      expect(m.metByMe, isNull);
      expect(m.isEmpty, isFalse);
      expect(
        trustMapOf(address: celina, nameOf: (String a) => a).isEmpty,
        isTrue,
      );
    });
  });

  group('the answer path of "Zapytaj sieć"', () {
    test('who passed the question on and who answered, never the '
        'words', () {
      final Question q = Question(
        id: 'q1',
        text: 'Dentysta?',
        askerName: 'Ja',
        at: 1,
        hops: 1,
        sentTo: <String>{ania, bartek, celina, darek},
        passedOn: <String, int>{bartek: 3},
        answers: <AskAnswer>[
          AskAnswer(
            text: 'tajne',
            path: const <String>['Ania'],
            at: 2,
            from: ania,
          ),
          AskAnswer(
            text: 'też tajne',
            path: const <String>['Zenon', 'Bartek'],
            at: 3,
            from: bartek,
          ),
        ],
      );
      final ({List<AskPathBranch> branches, int quiet}) p = askPathOf(q);
      expect(p.branches.map((AskPathBranch b) => b.friend), <String>[
        ania,
        bartek,
      ]);
      expect(p.branches.first.answered, isTrue);
      expect(p.branches.last.passedTo, 3);
      expect(p.branches.last.further, <String>['Zenon']);
      expect(p.quiet, 2);
      final Question back = Question.fromJson(
        jsonDecode(jsonEncode(q.toJson())),
      )!;
      expect(back.passedOn, <String, int>{bartek: 3});
    });
  });

  group('picture without personal data', () {
    test('initials and circle colours only', () {
      expect(initialsOf('anna maria kowalska'), 'AM');
      expect(initialsOf('  łucja '), 'Ł');
      expect(initialsOf(''), '?');
      final ZenColors zen = ZenTheme.dark().extension<ZenColors>()!;
      final List<GraphNode> nodes = <GraphNode>[
        _node(ania, 'Anna Kowalska', 1),
        _node(xawery, 'Xawery Nowak', 4, <String>[ania]),
      ];
      final GraphLayout layout = graphLayout(nodes, const Size(300, 300));
      final GraphScene scene = GraphScene(
        layout: layout,
        from: Float32List.fromList(layout.xy),
        edgeFrom: Int32List.fromList(<int>[-1, 0]),
        edgeTo: Int32List.fromList(<int>[0, 1]),
        links: Int32List(0),
      );
      final List<SnapshotDot> dots = snapshotDots(scene, <String, int>{
        ania: 0,
      }, zen);
      expect(dots.map((SnapshotDot d) => d.letters), <String>['AK', 'XN']);
      expect(dots.first.color, isNot(dots.last.color));
      for (final SnapshotDot d in dots) {
        expect(d.at.dx, inInclusiveRange(0, kGraphSnapshotSize));
        expect(d.at.dy, inInclusiveRange(0, kGraphSnapshotSize));
      }
    });

    testWidgets('the picture is a PNG', (WidgetTester tester) async {
      final ZenColors zen = ZenTheme.dark().extension<ZenColors>()!;
      final List<GraphNode> nodes = <GraphNode>[_node(ania, 'Anna', 1)];
      final GraphLayout layout = graphLayout(nodes, const Size(200, 200));
      final GraphScene scene = GraphScene(
        layout: layout,
        from: Float32List.fromList(layout.xy),
        edgeFrom: Int32List.fromList(<int>[-1]),
        edgeTo: Int32List.fromList(<int>[0]),
        links: Int32List(0),
      );
      final Uint8List? png = await tester.runAsync<Uint8List?>(
        () => graphSnapshotPng(scene, const <String, int>{}, zen, size: 64),
      );
      expect(png, isNotNull);
      expect(png!.sublist(1, 4), utf8.encode('PNG'));
    });
  });
}
