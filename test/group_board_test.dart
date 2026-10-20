import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/groups/group_board.dart';
import 'package:zen/src/features/groups/presentation/group_board_view.dart';

ChatMessage _msg(
  String id,
  int at, {
  String text = 'x',
  ChatMessageDirection direction = ChatMessageDirection.incoming,
}) => ChatMessage(
  id: id,
  sender: 'ada.ygg',
  text: text,
  sentAtMillis: at,
  direction: direction,
);

void main() {
  test('board posts are recognised by id and sorted newest first', () {
    final String id = newBoardPostId(timestamp: 5, groupId: 'g1');
    expect(id, 'grp-board-5-g1');
    final List<ChatMessage> all = <ChatMessage>[
      _msg('grp-msg-1-g1', 1),
      _msg('grp-board-2-g1', 2),
      _msg(id, 5),
      const ChatMessage(
        id: 'grp-board-9-g1',
        sender: 'system',
        text: 'sys',
        sentAtMillis: 9,
        direction: ChatMessageDirection.system,
      ),
    ];
    expect(boardPostsOf(all).map((ChatMessage m) => m.id), <String>[
      id,
      'grp-board-2-g1',
    ]);
    expect(isBoardPost(all.first), isFalse);
  });

  testWidgets('board view lists only posts, with a hint when empty', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupBoardView(
            messages: <ChatMessage>[_msg('grp-msg-1-g1', 1, text: 'chat')],
            senderName: (ChatMessage m) => 'Ada',
            canPost: true,
          ),
        ),
      ),
    );
    expect(find.text('Tablica grupy jest pusta'), findsOneWidget);
    expect(find.text('chat'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupBoardView(
            messages: <ChatMessage>[
              _msg('grp-msg-1-g1', 1, text: 'chat'),
              _msg('grp-board-2-g1', 2, text: 'Spotkanie w piątek'),
            ],
            senderName: (ChatMessage m) => 'Ada',
            canPost: true,
          ),
        ),
      ),
    );
    expect(find.text('Spotkanie w piątek'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('chat'), findsNothing);
  });
}
