import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/presentation/intent_widgets.dart';

const int _minute = 60 * 1000;
final int _now = DateTime(2026, 10, 14, 12).millisecondsSinceEpoch;

const Map<String, String> _names = <String, String>{
  'b': 'Bartek',
  'c': 'Cela',
  'd': 'Dawid',
  'e': 'Ewa',
};

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
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
      builder: (BuildContext context, Widget? app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[child],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('time left: minutes, an hour, until switched off', () {
    final IntentStatus soon = IntentStatus(
      kind: IntentKind.talk,
      setAt: _now - 15 * _minute,
      until: _now + 45 * _minute,
    );
    expect(intentTimeLeft(soon, _now), 'jeszcze 45 min');
    expect(intentTimeShare(soon, _now), closeTo(0.75, 0.001));
    final IntentStatus evening = IntentStatus(
      kind: IntentKind.out,
      setAt: _now,
      until: DateTime(2026, 10, 14, 18).millisecondsSinceEpoch,
    );
    expect(intentTimeLeft(evening, _now), 'do 18:00');
    final IntentStatus open = IntentStatus(kind: IntentKind.dnd, setAt: _now);
    expect(intentTimeLeft(open, _now), 'do odwołania');
    expect(intentTimeShare(open, _now), isNull);
  });

  testWidgets('my own status stands apart, with the time left, change and '
      'off', (WidgetTester tester) async {
    int edits = 0;
    int clears = 0;
    await _pump(
      tester,
      MyIntentCard(
        status: IntentStatus(
          kind: IntentKind.walk,
          setAt: _now - 15 * _minute,
          until: _now + 45 * _minute,
          note: 'Park Skaryszewski',
          onlyClose: true,
        ),
        now: _now,
        onEdit: () => edits++,
        onClear: () => clears++,
      ),
    );
    expect(find.text('TWÓJ STATUS'), findsOneWidget);
    expect(find.text('Idę na spacer'), findsOneWidget);
    expect(find.text('Park Skaryszewski'), findsOneWidget);
    expect(find.text('widzą przyjaciele'), findsOneWidget);
    expect(find.text('Zgaśnie sam: jeszcze 45 min'), findsOneWidget);
    final LinearProgressIndicator bar = tester.widget(
      find.byKey(const Key('intent-mine-time')),
    );
    expect(bar.value, closeTo(0.75, 0.001));

    await tester.tap(find.byKey(const Key('intent-edit')));
    await tester.tap(find.byKey(const Key('intent-clear')));
    expect(edits, 1);
    expect(clears, 1);
  });

  testWidgets('a custom status says it is one, an open one has no bar', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      MyIntentCard(
        status: IntentStatus(
          kind: IntentKind.custom,
          setAt: _now,
          note: 'W pracy do 17',
          emoji: '💻',
        ),
        now: _now,
        onEdit: () {},
        onClear: () {},
      ),
    );
    expect(find.text('TWÓJ WŁASNY STATUS'), findsOneWidget);
    expect(find.text('W pracy do 17'), findsOneWidget);
    expect(find.text('Własny'), findsOneWidget);
    expect(find.text('Do odwołania'), findsOneWidget);
    expect(find.byKey(const Key('intent-mine-time')), findsNothing);
  });

  testWidgets('friends\' statuses are grouped by kind, the urgent one first', (
    WidgetTester tester,
  ) async {
    final List<String> opened = <String>[];
    await _pump(
      tester,
      FriendIntents(
        byKind: <IntentKind, List<(String, IntentStatus)>>{
          IntentKind.talk: <(String, IntentStatus)>[
            (
              'b',
              IntentStatus(
                kind: IntentKind.talk,
                setAt: _now - 10 * _minute,
                until: _now + 50 * _minute,
                note: 'Nudzę się w pociągu',
              ),
            ),
            ('c', IntentStatus(kind: IntentKind.talk, setAt: _now)),
          ],
          IntentKind.urgent: <(String, IntentStatus)>[
            (
              'd',
              IntentStatus(
                kind: IntentKind.urgent,
                setAt: _now,
                note: 'Złapałem gumę',
              ),
            ),
          ],
          IntentKind.custom: <(String, IntentStatus)>[
            (
              'e',
              IntentStatus(
                kind: IntentKind.custom,
                setAt: _now,
                note: 'Na siłowni do 18',
                emoji: '💪',
              ),
            ),
          ],
          IntentKind.eat: const <(String, IntentStatus)>[],
        },
        now: _now,
        nameOf: (String a) => _names[a] ?? '?',
        onOpen: opened.add,
      ),
    );
    expect(find.text('ZNAJOMI TERAZ · 4'), findsOneWidget);
    final Finder urgent = find.byKey(const Key('intent-friends-urgent'));
    final Finder talk = find.byKey(const Key('intent-friends-talk'));
    final Finder custom = find.byKey(const Key('intent-friends-custom'));
    expect(urgent, findsOneWidget);
    expect(talk, findsOneWidget);
    expect(custom, findsOneWidget);
    expect(find.byKey(const Key('intent-friends-eat')), findsNothing);
    expect(tester.getTopLeft(urgent).dy, lessThan(tester.getTopLeft(talk).dy));
    expect(tester.getTopLeft(talk).dy, lessThan(tester.getTopLeft(custom).dy));

    expect(
      find.descendant(of: talk, matching: find.text('Bartek')),
      findsOneWidget,
    );
    expect(find.text('Nudzę się w pociągu'), findsOneWidget);
    expect(find.text('jeszcze 50 min'), findsOneWidget);
    expect(find.text('Złapałem gumę'), findsOneWidget);
    // A custom status shows its own words (and the group says what it is).
    expect(find.text('Własne statusy'), findsOneWidget);
    expect(find.text('Na siłowni do 18'), findsOneWidget);

    await tester.tap(find.text('Bartek'));
    await tester.pump();
    expect(opened, <String>['b']);
  });

  testWidgets('nobody with a status: a line that invites to set one', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      FriendIntents(
        byKind: const <IntentKind, List<(String, IntentStatus)>>{},
        now: _now,
        nameOf: (String a) => a,
        onOpen: (String _) {},
      ),
    );
    expect(find.byKey(const Key('intent-friends-empty')), findsOneWidget);
    expect(find.text('Ustaw swój, a może ktoś dołączy.'), findsOneWidget);
  });

  testWidgets('the picker offers statuses; „Randkuję” only with dating on', (
    WidgetTester tester,
  ) async {
    final List<IntentKind> picked = <IntentKind>[];
    await _pump(tester, IntentPicker(datingOn: false, onPick: picked.add));
    await tester.tap(find.byKey(const Key('intent-set-talk')));
    await tester.tap(find.byKey(const Key('intent-set-urgent')));
    expect(picked, <IntentKind>[IntentKind.talk, IntentKind.urgent]);

    await tester.tap(find.byKey(const Key('intent-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('intent-set-dating')), findsNothing);
    await tester.tap(find.byKey(const Key('intent-set-walk')));
    await tester.pumpAndSettle();
    expect(picked.last, IntentKind.walk);
  });

  testWidgets('fits a narrow phone with large text, in the dark theme', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      Column(
        children: <Widget>[
          MyIntentCard(
            status: IntentStatus(
              kind: IntentKind.urgent,
              setAt: _now,
              until: _now + 60 * _minute,
              note: 'Zepsuty samochód na obwodnicy, potrzebuję transportu',
            ),
            now: _now,
            onEdit: () {},
            onClear: () {},
          ),
          FriendIntents(
            byKind: <IntentKind, List<(String, IntentStatus)>>{
              IntentKind.canHelp: <(String, IntentStatus)>[
                (
                  'b',
                  IntentStatus(
                    kind: IntentKind.canHelp,
                    setAt: _now,
                    until: _now + 30 * _minute,
                    note: 'Mam auto i wolne popołudnie',
                  ),
                ),
              ],
            },
            now: _now,
            nameOf: (String _) => 'Bartłomiej Długonazwiskowski',
            onOpen: (String _) {},
          ),
          const IntentPicker(datingOn: true, onPick: _ignore),
        ],
      ),
      theme: ZenTheme.dark(),
      size: const Size(320, 900),
      textScale: 1.8,
    );
    expect(tester.takeException(), isNull);
  });
}

void _ignore(IntentKind _) {}
