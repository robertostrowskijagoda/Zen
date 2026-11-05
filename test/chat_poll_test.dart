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
