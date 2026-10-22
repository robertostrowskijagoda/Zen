import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/chat/presentation/message_extras.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

Widget _app(Widget child) => MaterialApp(
  theme: ZenTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('reactions: counted per emoji, a tap toggles, a long press '
      'shows who', (WidgetTester tester) async {
    final List<String> toggled = <String>[];
    await tester.pumpWidget(
      _app(
        ChatReactionsBar(
          reactions: const <String, String>{
            'self': '👍',
            'bob': '👍',
            'carol': '❤️',
          },
          onToggle: toggled.add,
          nameOf: (String who) => who == 'self' ? 'Ty' : who.toUpperCase(),
        ),
      ),
    );
    expect(find.text('👍 2'), findsOneWidget);
    expect(find.text('❤️ 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reaction-chip-👍')));
    expect(toggled, <String>['👍']);

    await tester.longPress(find.byKey(const Key('reaction-chip-❤️')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reaction-people')), findsOneWidget);
    expect(find.text('Reakcje'), findsOneWidget);
    expect(find.text('CAROL'), findsOneWidget);
    expect(find.text('BOB'), findsOneWidget);
    expect(find.text('Ty'), findsOneWidget);
  });

  testWidgets('no reactions, nothing drawn', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        ChatReactionsBar(
          reactions: const <String, String>{},
          onToggle: (_) {},
          nameOf: (String who) => who,
        ),
      ),
    );
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a quote shows the original and jumps to it', (
    WidgetTester tester,
  ) async {
    int taps = 0;
    const ChatReply reply = ChatReply(
      messageId: 'm1',
      sender: 'ada',
      text: 'Stary tekst',
    );
    const ChatMessage original = ChatMessage(
      id: 'm1',
      sender: 'ada',
      text: 'Idziemy jutro?',
      sentAtMillis: 1,
      direction: ChatMessageDirection.incoming,
    );
    await tester.pumpWidget(
      _app(
        ChatReplyQuote(
          reply: reply,
          original: original,
          senderLabel: 'Ada',
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Idziemy jutro?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reply-quote-m1')));
    expect(taps, 1);

    await tester.pumpWidget(
      _app(
        ChatReplyQuote(
          reply: reply,
          original: original.deletedAt(5),
          senderLabel: 'Ada',
        ),
      ),
    );
    expect(find.text('Wiadomość usunięta'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        const ChatReplyQuote(
          reply: ChatReply(messageId: 'gone'),
          senderLabel: 'Ada',
        ),
      ),
    );
    expect(find.text('Wiadomość niedostępna'), findsOneWidget);
  });

  testWidgets('the reply bar over the composer can be cancelled', (
    WidgetTester tester,
  ) async {
    int cancelled = 0;
    await tester.pumpWidget(
      _app(
        ChatReplyComposerBar(
          reply: const ChatReply(messageId: 'm1', text: 'Kiedy?'),
          senderLabel: 'Ada',
          onCancel: () => cancelled++,
        ),
      ),
    );
    expect(find.text('Odpowiadasz: Ada'), findsOneWidget);
    expect(find.text('Kiedy?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reply-composer-cancel')));
    expect(cancelled, 1);
  });

  testWidgets('a bubble\'s menu: the actions first, then copying', (
    WidgetTester tester,
  ) async {
    final List<String> chosen = <String>[];
    await tester.pumpWidget(
      _app(
        CopyableText(
          'Hej',
          style: const TextStyle(),
          actions: <ChatMenuItem>[
            ChatMenuItem(
              id: 'react',
              icon: Icons.add_reaction_outlined,
              label: 'Zareaguj',
              onSelected: () => chosen.add('react'),
            ),
            ChatMenuItem(
              id: 'reply',
              icon: Icons.reply_rounded,
              label: 'Odpowiedz',
              onSelected: () => chosen.add('reply'),
            ),
          ],
        ),
      ),
    );
    await tester.longPress(find.text('Hej'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bubble-react')), findsOneWidget);
    expect(find.byKey(const Key('bubble-copy')), findsOneWidget);
    expect(find.byKey(const Key('bubble-report')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const Key('bubble-react'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('bubble-copy'))).dy),
    );
    await tester.tap(find.byKey(const Key('bubble-reply')));
    await tester.pumpAndSettle();
    expect(chosen, <String>['reply']);
  });

  testWidgets('forwarding offers friends and joined groups', (
    WidgetTester tester,
  ) async {
    final SocialHubState hub =
        SocialHubState.empty(
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.foreground,
            generation: 1,
            capturedAtMillis: 0,
          ),
        ).copyWith(
          friends: const <String, FriendProfile>{
            'ada': FriendProfile(
              address: 'ada',
              displayName: 'Ada',
              status: FriendRelationshipStatus.accepted,
            ),
          },
          groups: const <String, GroupProfile>{
            'g1': GroupProfile(
              id: 'g1',
              name: 'Ekipa',
              createdById: 'self',
              createdAtMillis: 0,
              memberAddresses: <String>['ada'],
            ),
            'g2': GroupProfile(
              id: 'g2',
              name: 'Zaproszenie',
              createdById: 'ada',
              createdAtMillis: 0,
              memberAddresses: <String>['ada'],
              isInvitePending: true,
            ),
          },
        );
    final Completer<String?> picked = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => picked.complete(pickForwardTarget(context, hub)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Przekaż do'), findsOneWidget);
    expect(find.byKey(const Key('forward-to-ada')), findsOneWidget);
    expect(find.byKey(const Key('forward-to-group:g2')), findsNothing);
    await tester.tap(find.byKey(const Key('forward-to-group:g1')));
    await tester.pumpAndSettle();
    expect(await picked.future, 'group:g1');
  });

  testWidgets('deleting for everyone says what it cannot do', (
    WidgetTester tester,
  ) async {
    final Completer<bool> answer = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  answer.complete(confirmDeleteForEveryone(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Usunąć u wszystkich?'), findsOneWidget);
    expect(find.textContaining('zmieniona wersja aplikacji'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-for-everyone-confirm')));
    await tester.pumpAndSettle();
    expect(await answer.future, isTrue);
  });
}
