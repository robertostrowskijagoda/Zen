import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// "Daj napiwek" in "Zapytaj sieć": answers of pyramid
/// members carry their pyramid key, the asker pays a tip in the pyramid's
/// money.
void main() {
  test('an answer keeps the pyramid key and the tip; one without its friend '
      'is not read', () {
    const AskAnswer a = AskAnswer(
      text: 'dr Nowak',
      path: <String>['Kasia'],
      at: 5,
      from: 'kasia',
      pyramidKey: 'klucz',
      pyramid: 'ruch',
    );
    final AskAnswer back = AskAnswer.fromJson(a.withTip(250).toJson())!;
    expect(back.pyramidKey, 'klucz');
    expect(back.pyramid, 'ruch');
    expect(back.tipped, 250);
    expect(back.withTip(100).tipped, 350);
    expect(back.from, 'kasia');
    expect(
      AskAnswer.fromJson(<String, dynamic>{
        't': 'stara',
        'p': <String>['Bartek'],
        'at': 1,
      }),
      isNull,
    );
    expect(askKeyField(''), isNull);
    expect(askKeyField('x' * 101), isNull);
    expect(askKeyField(42), isNull);
  });

  test('the asker tips an answer, also one that came two steps back', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String a1 = w['A1'].myKey!;
    final String b = w['B'].myKey!;
    final String a2 = w['A2'].myKey!;
    await w['S'].emit(a1, 10000, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));

    // Answers are signed: the answerers have ledger keys.
    for (final String n in <String>['A', 'B', 'A2']) {
      await LedgerIdentity.loadOrCreate(w.ask(n).disk);
    }
    // A1 asks its friends (A and B).
    final Question q = (await w.ask('A1').ask('Kto zna dobrego hydraulika?'))!;
    await w.net.run();
    expect(w.ask('B').fromOthers.single.id, q.id);
    // B answers as a pyramid member; A passes the question on to A2, who
    // answers too; A also answers, without its key.
    await w
        .ask('B')
        .answer(q.id, 'Pan Zenek', pyramidKey: b, pyramid: w['B'].current);
    expect(
      await w.ask('A').forward(q.id, <String>[w.net['A2'].address]),
      isTrue,
    );
    await w.net.run();
    await w
        .ask('A2')
        .answer(
          q.id,
          'Hydraulik z Mokotowa',
          pyramidKey: a2,
          pyramid: w['A2'].current,
        );
    await w.ask('A').answer(q.id, 'Nie wiem');
    await w.net.run();

    final List<AskAnswer> answers = w.ask('A1').mine.single.answers;
    expect(answers, hasLength(3));
    final AskAnswer fromB = answers.firstWhere(
      (AskAnswer x) => x.text == 'Pan Zenek',
    );
    final AskAnswer fromA2 = answers.firstWhere(
      (AskAnswer x) => x.text == 'Hydraulik z Mokotowa',
    );
    final AskAnswer fromA = answers.firstWhere(
      (AskAnswer x) => x.text == 'Nie wiem',
    );
    expect(fromB.pyramidKey, b);
    expect(fromA2.pyramidKey, a2, reason: 'kept on the way back through A');
    expect(fromA2.path, <String>['A2', 'A']);
    expect(fromA.pyramidKey, isNull);

    // What the button shows: a tip is possible to members, not to oneself,
    // not without a key, not into another pyramid, not without money.
    expect(w['A1'].canTip(fromB.pyramidKey, pyramid: fromB.pyramid), isTrue);
    expect(w['A1'].canTip(fromA2.pyramidKey, pyramid: fromA2.pyramid), isTrue);
    expect(w['A1'].canTip(fromA.pyramidKey), isFalse);
    expect(w['A1'].canTip(a1), isFalse);
    expect(w['A1'].canTip(b, pyramid: 'inna-piramida'), isFalse);
    expect(w['B1'].canTip(b), isFalse, reason: 'B1 has no money');

    final PyramidRecord? order = await w['A1'].tip(
      b,
      2500,
      pyramid: fromB.pyramid,
    );
    expect(order, isNotNull);
    await w.ask('A1').noteTip(q.id, answers.indexOf(fromB), 2500);
    await w.net.run();
    final PyramidState st = w['S'].state!;
    expect(st.balanceOf(b), 2500);
    expect(st.balanceOf(a1), 7500);
    expect(st.transfers.last.memo, 'Napiwek za odpowiedź');
    expect(
      w
          .ask('A1')
          .mine
          .single
          .answers
          .firstWhere((AskAnswer x) => x.text == 'Pan Zenek')
          .tipped,
      2500,
    );
    expect(await w['A1'].tip(b, 0), isNull);
  });
}
