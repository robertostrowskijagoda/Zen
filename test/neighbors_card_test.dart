import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';

FlatProfile _profile({
  String about = '',
  List<FlatItem> items = const <FlatItem>[],
}) => FlatProfile(
  key: base64Url.encode(List<int>.filled(32, 7)),
  name: 'Nowakowie',
  place: 'm. 12',
  about: about,
  items: items,
  members: const <String, String>{},
  rev: 0,
);

void main() {
  test('"Co widzi pukający": privacy first, and it survives JSON', () {
    const FlatDoorView bare = FlatDoorView();
    expect(bare.bare, isTrue);
    expect(bare.toJson(), isEmpty);
    expect(FlatDoorView.fromJson(null), bare);
    expect(FlatDoorView.fromJson('nonsense'), bare);

    const FlatDoorView some = FlatDoorView(
      photo: true,
      names: true,
      note: 'Dzwonek nie działa',
    );
    expect(some.bare, isFalse);
    expect(const FlatDoorView(note: 'x').bare, isFalse);
    final FlatDoorView back = FlatDoorView.fromJson(
      jsonDecode(jsonEncode(some.toJson())),
    );
    expect(back, some);
    expect(back.items, isFalse);
    expect(back.about, isFalse);
    expect(
      FlatDoorView.fromJson(<String, dynamic>{
        'nt': 'n' * (FlatDoorView.maxNote + 10),
      }).note,
      hasLength(FlatDoorView.maxNote),
    );
    expect(some.copyWith(photo: false).photo, isFalse);
    expect(some.copyWith(photo: false).note, some.note);
  });

  test('a card and a knock survive JSON; a decision too', () {
    final FlatCard card = FlatCard(
      profile: _profile(about: 'Mamy psa'),
      names: const <String>['Ania', 'Tomek'],
      note: 'Pukajcie mocno',
    );
    final FlatKnock knock = FlatKnock(
      card: card,
      sender: '200::d1',
      at: 5,
      id: 'k1',
    );
    final FlatKnock back = FlatKnock.fromJson(
      jsonDecode(jsonEncode(knock.toJson())),
    )!;
    expect(back.key, card.key);
    expect(back.card.names, <String>['Ania', 'Tomek']);
    expect(back.card.note, 'Pukajcie mocno');
    expect(back.profile.about, 'Mamy psa');
    expect(back.id, 'k1');
    expect(FlatKnock.fromJson(<String, dynamic>{'a': '200::d1'}), isNull);
    // Names that are not text, or empty, are dropped.
    expect(
      FlatCard.fromJson(<String, dynamic>{
        'p': card.profile.toJson(),
        'nm': <Object?>['Ola', 3, ' ', null],
      })!.names,
      <String>['Ola'],
    );

    const FlatKnockDecision decision = FlatKnockDecision(
      flat: 'f',
      id: 'k1',
      at: 9,
      ok: true,
    );
    final FlatKnockDecision again = FlatKnockDecision.fromJson(
      jsonDecode(jsonEncode(decision.toJson())),
    )!;
    expect(again.ok, isTrue);
    expect(again.id, 'k1');
    expect(
      FlatKnockDecision.fromJson(<String, dynamic>{'f': 'f', 'at': 1}),
      isNull,
    );
  });

  testWidgets('a card shows only what the household chose to show', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              FlatCardDetails(
                key: const Key('full'),
                card: FlatCard(
                  profile: _profile(
                    about: 'Mamy psa',
                    items: const <FlatItem>[
                      FlatItem(
                        id: 'i1',
                        kind: FlatItemKind.offer,
                        text: 'Pożyczę drabinę',
                      ),
                    ],
                  ),
                  names: const <String>['Ania', 'Tomek'],
                  note: 'Dzwonek nie działa',
                ),
              ),
              FlatCardDetails(
                key: const Key('bare'),
                card: FlatCard(profile: _profile()),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Dzwonek nie działa'), findsOneWidget);
    expect(find.text('Domownicy: Ania, Tomek'), findsOneWidget);
    expect(find.text('Mamy psa'), findsOneWidget);
    expect(find.text('Pożyczę drabinę'), findsOneWidget);
    // Nothing chosen: nothing shown beyond the name.
    expect(
      find.descendant(
        of: find.byKey(const Key('bare')),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
  });
}
