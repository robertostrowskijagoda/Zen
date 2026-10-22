import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/presentation/dating_deck.dart';

SeenProfile _seen(String name, {String? friend = '200::f'}) => SeenProfile(
  profile: DatingProfile(
    key: 'k-$name',
    name: name,
    gender: DatingGender.woman,
    at: 1,
    about: '$name lubi góry i dobrą kawę.',
    lookingFor: 'Kogoś do wspólnych wypraw',
    vouchSlots: const <DatingVouch?>[
      DatingVouch(
        id: 'v1',
        by: 'Kasia',
        text: 'Najlepsza kumpela',
        signer: 'vk',
        sig: 'sig',
        at: 1,
      ),
    ],
  ),
  replyTo: 'r-$name',
  at: 1,
  friend: friend,
  path: const <String>['Bob'],
  distance: 2,
);

void main() {
  final List<(String, bool)> decided = <(String, bool)>[];
  final List<String> matched = <String>[];
  final List<String> asked = <String>[];
  final List<String> opened = <String>[];

  setUp(() {
    decided.clear();
    matched.clear();
    asked.clear();
    opened.clear();
  });

  Future<void> pumpDeck(
    WidgetTester tester,
    List<SeenProfile> profiles, {
    ThemeData? theme,
    Size size = const Size(360, 740),
    double textScale = 1,
    bool Function(SeenProfile s)? canAsk,
    int Function(SeenProfile s)? verdicts,
    Future<bool> Function(SeenProfile s)? confirmYes,
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
        home: Scaffold(
          body: DatingSwipeDeck(
            profiles: profiles,
            onDecide: (SeenProfile s, bool yes) async =>
                decided.add((s.profile.key, yes)),
            onOpen: (SeenProfile s) => opened.add(s.profile.name),
            onMatchmake: (SeenProfile s) => matched.add(s.profile.name),
            onAsk: (SeenProfile s) => asked.add(s.profile.name),
            canAsk: canAsk,
            verdicts: verdicts,
            confirmYes: confirmYes,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the first card is the description; swiping right says „Tak”', (
    WidgetTester tester,
  ) async {
    await pumpDeck(tester, <SeenProfile>[_seen('Ania'), _seen('Basia')]);
    expect(find.byKey(const Key('dating-card-Ania')), findsOneWidget);
    // The description is the first "photo".
    expect(find.text('Ania'), findsOneWidget);
    expect(find.text('Ania lubi góry i dobrą kawę.'), findsOneWidget);
    // The card under it shows its own description.
    expect(find.text('Basia lubi góry i dobrą kawę.'), findsOneWidget);
    expect(find.text('Znacie się przez: Bob'), findsWidgets);
    expect(find.textContaining('Najlepsza kumpela'), findsWidgets);

    await tester.drag(
      find.byKey(const Key('dating-card-Ania')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(decided, <(String, bool)>[('k-Ania', true)]);
    expect(find.byKey(const Key('dating-card-Basia')), findsOneWidget);
    expect(find.byKey(const Key('dating-card-Ania')), findsNothing);

    await tester.drag(
      find.byKey(const Key('dating-card-Basia')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(decided.last, ('k-Basia', false));
  });

  testWidgets('a short drag goes back; the buttons decide too', (
    WidgetTester tester,
  ) async {
    await pumpDeck(tester, <SeenProfile>[_seen('Ania'), _seen('Basia')]);
    await tester.drag(
      find.byKey(const Key('dating-card-Ania')),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    expect(decided, isEmpty);
    expect(find.byKey(const Key('dating-card-Ania')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dating-deck-no')));
    await tester.pumpAndSettle();
    expect(decided, <(String, bool)>[('k-Ania', false)]);

    await tester.tap(find.byKey(const Key('dating-deck-yes')));
    await tester.pumpAndSettle();
    expect(decided.last, ('k-Basia', true));
  });

  testWidgets('the stamp follows the swipe', (WidgetTester tester) async {
    await pumpDeck(tester, <SeenProfile>[_seen('Ania')]);
    final TestGesture g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('dating-card-Ania'))),
    );
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(find.text('TAK'), findsOneWidget);
    expect(find.text('NIE'), findsNothing);
    await g.moveBy(const Offset(-130, 0));
    await tester.pump();
    expect(find.text('NIE'), findsOneWidget);
    expect(find.text('TAK'), findsNothing);
    await g.up();
    await tester.pumpAndSettle();
    expect(decided, isEmpty, reason: 'not far enough');
  });

  testWidgets('„Swatuj”, „Zapytaj o opinię” and the whole profile', (
    WidgetTester tester,
  ) async {
    await pumpDeck(tester, <SeenProfile>[
      _seen('Ania'),
      _seen('Basia', friend: null),
    ]);
    await tester.tap(find.byKey(const Key('dating-deck-match')));
    await tester.tap(find.byKey(const Key('dating-deck-ask')));
    await tester.tap(find.byKey(const Key('dating-card-open')));
    await tester.pump();
    expect(matched, <String>['Ania']);
    expect(asked, <String>['Ania']);
    expect(opened, <String>['Ania']);

    // Basia came with nobody to ask (an introduction).
    await tester.tap(find.byKey(const Key('dating-deck-yes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dating-deck-ask')));
    await tester.pump();
    expect(asked, <String>['Ania']);
  });

  testWidgets('fits a narrow phone with large text, in the dark theme', (
    WidgetTester tester,
  ) async {
    await pumpDeck(
      tester,
      <SeenProfile>[_seen('Ania'), _seen('Basia'), _seen('Cela')],
      theme: ZenTheme.dark(),
      size: const Size(320, 600),
      textScale: 1.8,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('dating-deck-yes')), findsOneWidget);
  });

  testWidgets('„Zapytaj o opinię” only when someone knows the person; many '
      'vouches are counted, not all shown', (WidgetTester tester) async {
    final SeenProfile many = SeenProfile(
      profile: DatingProfile(
        key: 'k-Ola',
        name: 'Ola',
        gender: DatingGender.woman,
        at: 1,
        vouchDigests: <String>[for (int i = 0; i < 12; i++) 'd$i'],
        vouchSlots: <DatingVouch?>[
          for (int i = 0; i < 12; i++)
            DatingVouch(
              id: 'v$i',
              by: 'Kasia',
              text: 'Słowo $i',
              signer: 'vk',
              sig: 'sig',
              at: i,
            ),
        ],
      ),
      replyTo: 'r',
      at: 1,
      friend: '200::f',
      distance: 1,
    );
    await pumpDeck(tester, <SeenProfile>[
      many,
    ], canAsk: (SeenProfile s) => false);
    expect(find.text('i 10 poręczeń więcej w całym profilu'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dating-deck-ask')));
    await tester.pump();
    expect(asked, isEmpty, reason: 'the only friend is the person');
  });

  testWidgets('a verdict of the pyramid\'s court shows on the card and is '
      'asked about before „Tak”', (WidgetTester tester) async {
    final List<String> confirmed = <String>[];
    bool allow = false;
    await pumpDeck(
      tester,
      <SeenProfile>[_seen('Ania'), _seen('Basia')],
      verdicts: (SeenProfile s) => s.profile.name == 'Ania' ? 1 : 0,
      confirmYes: (SeenProfile s) async {
        confirmed.add(s.profile.name);
        return allow;
      },
    );
    expect(find.byKey(const Key('dating-card-verdict')), findsOneWidget);
    expect(find.text('Wyrok sądu piramidy'), findsOneWidget);
    // Declined: the card stays, nothing decided.
    await tester.tap(find.byKey(const Key('dating-deck-yes')));
    await tester.pumpAndSettle();
    expect(confirmed, <String>['Ania']);
    expect(decided, isEmpty);
    expect(find.byKey(const Key('dating-card-Ania')), findsOneWidget);
    // Read and accepted: decided.
    allow = true;
    await tester.tap(find.byKey(const Key('dating-deck-yes')));
    await tester.pumpAndSettle();
    expect(decided, <(String, bool)>[('k-Ania', true)]);
    expect(find.byKey(const Key('dating-card-verdict')), findsNothing);
  });
}
