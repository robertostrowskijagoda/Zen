import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/chat_poll.dart';
import 'package:zen/src/features/groups/presentation/group_poll.dart';

// "Ankiety w grupach": a poll is a group message with its question and
// answers; a vote is a keycap reaction, so a Zen without polls still reads
// the poll as text and the votes as reactions.
void main() {
  test('a poll is made of what was typed, or not at all', () {
    expect(ChatPoll.of('  ', <String>['a', 'b']), isNull);
    expect(ChatPoll.of('Pytanie', <String>['a', ' ', 'a']), isNull);
    expect(
      ChatPoll.of('Pytanie', List<String>.generate(11, (int i) => '$i')),
      isNull,
    );
    final ChatPoll poll = ChatPoll.of(' Kiedy? ', <String>[
      ' Sobota ',
      '',
      'Niedziela',
      'Sobota',
    ])!;
    expect(poll.question, 'Kiedy?');
    expect(poll.options, <String>['Sobota', 'Niedziela']);
    expect(
      poll.asText,
      'Kiedy?\n${kPollVotes[0]} Sobota\n${kPollVotes[1]} Niedziela',
    );
  });

  test('the wire form is taken exactly or not at all', () {
    final ChatPoll poll = ChatPoll.of('Kiedy?', <String>['A', 'B'])!;
    expect(ChatPoll.fromJson(poll.toJson()), poll);
    expect(
      ChatPoll.fromJson(<String, Object?>{
        'q': 'x',
        'o': <Object?>['A', 1],
      }),
      isNull,
    );
    // Cleaned up it would point the numbers at other answers.
    expect(
      ChatPoll.fromJson(<String, Object?>{
        'q': 'x',
        'o': <String>['A', '', 'B'],
      }),
      isNull,
    );
    expect(ChatPoll.fromJson('poll'), isNull);
  });

  test('stored with the message; votes counted from the reactions', () {
    final ChatPoll poll = ChatPoll.of('Kiedy?', <String>['A', 'B', 'C'])!;
    final ChatMessage m = ChatMessage(
      id: 'm',
      sender: 'self',
      text: poll.asText,
      sentAtMillis: 1,
      direction: ChatMessageDirection.outgoing,
      poll: poll,
      reactions: <String, String>{
        'self': kPollVotes[2],
        'ola': kPollVotes[2],
        'jan': kPollVotes[0],
        'ewa': '❤️',
        // A number past the answers is no vote.
        'ala': kPollVotes[7],
      },
    );
    final ChatMessage back = chatMessageWithExtras(
      ChatMessage(
        id: 'm',
        sender: 'self',
        text: m.text,
        sentAtMillis: 1,
        direction: ChatMessageDirection.outgoing,
      ),
      chatMessageExtrasToJson(m),
    );
    expect(back.poll, poll);
    expect(poll.votersIn(back.reactions), <List<String>>[
      <String>['jan'],
      <String>[],
      <String>['self', 'ola'],
    ]);
    expect(reactionsBesidePoll(poll, back.reactions).keys, <String>[
      'ewa',
      'ala',
    ]);
    expect(m.deletedAt(5).poll, isNull);
  });

  test('open until its time or until its author ends it, whichever is '
      'first; the leader is the answer with the most votes', () {
    final ChatPoll open = ChatPoll.of('Kiedy?', <String>['A', 'B'])!;
    expect(open.isClosedAt(1 << 50), isFalse);
    final ChatPoll timed = ChatPoll.of('Kiedy?', <String>[
      'A',
      'B',
    ], closesAtMillis: 1000)!;
    expect(timed.isClosedAt(999), isFalse);
    expect(timed.closedSince(1000), 1000);
    final ChatPoll ended = timed.endedAt(400);
    expect(ended.closedSince(500), 400);
    // Ended once: a later ending changes nothing.
    expect(ended.endedAt(700), ended);
    // Ended after its time: it closed at its time.
    expect(timed.endedAt(5000).closedSince(5000), 1000);

    expect(ChatPoll.fromJson(ended.toJson()), ended);
    expect(ended.toJson(), <String, Object?>{
      'q': 'Kiedy?',
      'o': <String>['A', 'B'],
      'd': 1000,
      'c': 400,
    });
    for (final Object? bad in <Object?>[0, -5, 'jutro', 1.5]) {
      expect(
        ChatPoll.fromJson(<String, Object?>{
          'q': 'x',
          'o': <String>['A', 'B'],
          'd': bad,
        }),
        isNull,
        reason: '$bad',
      );
      expect(
        ChatPoll.fromJson(<String, Object?>{
          'q': 'x',
          'o': <String>['A', 'B'],
          'c': bad,
        }),
        isNull,
        reason: '$bad',
      );
    }

    expect(open.leading(<List<String>>[<String>[], <String>[]]), isEmpty);
    expect(
      open.leading(<List<String>>[
        <String>['a'],
        <String>['b', 'c'],
      ]),
      <int>[1],
    );
    expect(
      open.leading(<List<String>>[
        <String>['a'],
        <String>['b'],
      ]),
      <int>[0, 1],
    );
  });

  test("an ending counts only as the same poll's, once, never later than "
      'it came', () {
    final ChatPoll poll = ChatPoll.of('Kiedy?', <String>[
      'A',
      'B',
    ], closesAtMillis: 9000)!;
    expect(
      poll.endingOf(poll.endedAt(300).toJson(), receivedAtMillis: 500),
      poll.endedAt(300),
    );
    // Claimed in the future: ended when it came.
    expect(
      poll.endingOf(poll.endedAt(800).toJson(), receivedAtMillis: 500),
      poll.endedAt(500),
    );
    // Not ended, another poll, another time limit, already ended: nothing.
    expect(poll.endingOf(poll.toJson(), receivedAtMillis: 500), isNull);
    expect(
      poll.endingOf(
        ChatPoll.of('Gdzie?', <String>['A', 'B'])!.endedAt(1).toJson(),
        receivedAtMillis: 500,
      ),
      isNull,
    );
    expect(
      poll.endingOf(
        ChatPoll.of('Kiedy?', <String>['A', 'B'])!.endedAt(1).toJson(),
        receivedAtMillis: 500,
      ),
      isNull,
    );
    expect(
      poll
          .endedAt(100)
          .endingOf(poll.endedAt(50).toJson(), receivedAtMillis: 500),
      isNull,
    );
  });

  testWidgets('the card: the leader on top, the time limit, its author '
      'ends it; ended, the result and no more votes', (
    WidgetTester tester,
  ) async {
    final int now = DateTime(2026, 11, 5, 12).millisecondsSinceEpoch;
    final ChatPoll poll = ChatPoll.of('Kiedy?', <String>[
      'A',
      'B',
    ], closesAtMillis: DateTime(2026, 11, 5, 18).millisecondsSinceEpoch)!;
    final List<int> votes = <int>[];
    int ends = 0;
    Future<void> show(ChatPoll p) => tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Scaffold(
          body: GroupPollCard(
            poll: p,
            reactions: <String, String>{
              'self': kPollVotes[1],
              'ola': kPollVotes[1],
              'jan': kPollVotes[0],
            },
            nameOf: (String who) => who,
            onVote: votes.add,
            onEnd: () => ends++,
            nowMillis: now,
          ),
        ),
      ),
    );
    await show(poll);
    expect(find.text('Prowadzi: B'), findsOneWidget);
    expect(find.text('Głosowanie do 18:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-poll-end')));
    expect(ends, 1);

    await show(poll.endedAt(now - 1000));
    expect(find.text('Wynik: B'), findsOneWidget);
    expect(find.text('Ankieta zakończona'), findsOneWidget);
    expect(find.byKey(const Key('group-poll-end')), findsNothing);
    await tester.tap(find.byKey(const Key('group-poll-option-0')));
    expect(votes, isEmpty);
  });

  testWidgets('the card says ended by itself when its time comes', (
    WidgetTester tester,
  ) async {
    final ChatPoll poll = ChatPoll.of('Kiedy?', <String>[
      'A',
      'B',
    ], closesAtMillis: DateTime.now().millisecondsSinceEpoch + 300)!;
    final List<int> votes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Scaffold(
          body: GroupPollCard(
            poll: poll,
            reactions: const <String, String>{},
            nameOf: (String who) => who,
            onVote: votes.add,
          ),
        ),
      ),
    );
    expect(find.text('Ankieta zakończona'), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ankieta zakończona'), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-poll-option-0')));
    expect(votes, isEmpty);
  });

  testWidgets('the card names who has not voted yet, the address in any '
      'spelling; ended, who did not vote', (WidgetTester tester) async {
    const String ola = '200:aaaa:1111:2222:3333:4444:5555:6666';
    const String jan = '200:bbbb:1111:2222:3333:4444:5555:6666';
    const String ewa = '200:cccc:1111:2222:3333:4444:5555:6666';
    final ChatPoll poll = ChatPoll.of('Kiedy?', <String>['A', 'B'])!;
    Future<void> show(ChatPoll p, Map<String, String> reactions) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ZenTheme.light(),
            home: Scaffold(
              body: GroupPollCard(
                poll: p,
                reactions: reactions,
                members: const <String>['self', ola, jan, ewa],
                nameOf: (String who) => switch (who) {
                  'self' => 'Ty',
                  ola => 'Ola',
                  jan => 'Jan',
                  _ => 'Ewa',
                },
                onVote: (_) {},
                nowMillis: 1000,
              ),
            ),
          ),
        );
    await show(poll, <String, String>{
      ola.toUpperCase(): kPollVotes[0],
      'self': kPollVotes[1],
      // Not a vote: still not voted.
      jan: '❤️',
    });
    expect(find.text('Jeszcze nie głosowali: Jan, Ewa'), findsOneWidget);
    await show(poll.endedAt(500), <String, String>{
      ola: kPollVotes[0],
      'self': kPollVotes[1],
      jan: kPollVotes[1],
    });
    expect(find.text('Nie zagłosowali: Ewa'), findsOneWidget);
    await show(poll, <String, String>{
      ola: kPollVotes[0],
      'self': kPollVotes[1],
      jan: kPollVotes[1],
      ewa: kPollVotes[0],
    });
    expect(find.byKey(const Key('group-poll-not-voted')), findsNothing);
  });

  testWidgets('the card shows the counts; a tap votes', (
    WidgetTester tester,
  ) async {
    final ChatPoll poll = ChatPoll.of('Kiedy?', <String>['A', 'B'])!;
    final List<int> votes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Scaffold(
          body: GroupPollCard(
            poll: poll,
            reactions: <String, String>{
              'self': kPollVotes[1],
              'ola': kPollVotes[1],
            },
            nameOf: (String who) => who,
            onVote: votes.add,
          ),
        ),
      ),
    );
    expect(find.text('Kiedy?'), findsOneWidget);
    expect(find.text('self, ola'), findsOneWidget);
    await tester.tap(find.byKey(const Key('group-poll-option-0')));
    expect(votes, <int>[0]);
  });

  testWidgets('the composer sends only a whole poll', (
    WidgetTester tester,
  ) async {
    ChatPoll? made;
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => made = await showPollComposer(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('poll-question')), 'Kiedy?');
    await tester.enterText(find.byKey(const Key('poll-option-0')), 'A');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('poll-send'))).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('poll-add-option')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('poll-option-2')), 'C');
    await tester.pump();
    await tester.tap(find.byKey(const Key('poll-send')));
    await tester.pumpAndSettle();
    expect(made?.options, <String>['A', 'C']);
  });
}
