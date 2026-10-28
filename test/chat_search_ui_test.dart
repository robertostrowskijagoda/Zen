import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/search/presentation/message_search_results.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Search in a chat (the magnifier or Ctrl+F, the words marked, the arrows
/// going from match to match and the list scrolling there, also far up a
/// long conversation) and on the chat list (results grouped by
/// conversation, a tap opening the chat at that message), on a wide screen
/// and on a 320 px phone with the text twice as big.

const String _ada = 'ada.ygg';
const String _bob = 'bob.ygg';
const String _groupId = 'grp-search';

ChatMessage _message(
  int n, {
  String sender = _ada,
  String? text,
  int base = 0,
}) => ChatMessage(
  id: 'm-$n',
  sender: sender,
  text: text ?? 'Wiadomość numer $n o niczym szczególnym',
  sentAtMillis: 1000000 + base + n * 60000,
  direction: sender == 'self'
      ? ChatMessageDirection.outgoing
      : ChatMessageDirection.incoming,
);

/// 80 messages; the tortoise in numbers 2, 40 and 75.
List<ChatMessage> _thread({String sender = _ada}) => <ChatMessage>[
  for (int i = 0; i < 80; i++)
    _message(
      i,
      sender: i.isEven ? 'self' : sender,
      text: switch (i) {
        2 => 'Bardzo stara wiadomość: mój ŻÓŁW uciekł',
        40 => 'W połowie: żółw się znalazł',
        75 => 'Nowa: zolw je sałatę',
        _ => null,
      },
    ),
];

SocialHubState _people() => SocialHubState.empty().copyWith(
  friends: const <String, FriendProfile>{
    _ada: FriendProfile(
      address: _ada,
      displayName: 'Ada',
      status: FriendRelationshipStatus.accepted,
    ),
    _bob: FriendProfile(
      address: _bob,
      displayName: 'Bob',
      status: FriendRelationshipStatus.accepted,
    ),
  },
  groups: const <String, GroupProfile>{
    _groupId: GroupProfile(
      id: _groupId,
      name: 'Ekipa',
      createdById: 'self',
      createdAtMillis: 0,
      memberAddresses: <String>['self', _bob],
    ),
  },
);

/// A wide phone (466 px): the magnifier is in the app bar.
void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// 320 px wide, the text twice as big.
void _narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(960, 1800);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Widget _app(
  Widget home, {
  Map<String, List<ChatMessage>>? threads,
  double textScale = 1,
}) => ProviderScope(
  overrides: [
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(
        threads ??
            <String, List<ChatMessage>>{
              _ada: _thread(),
              'group:$_groupId': _thread(sender: _bob),
            },
      ),
    ),
    socialHubSeedProvider.overrideWithValue(_people()),
  ],
  child: MaterialApp(
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  ),
);

/// The bubble text [text] is on screen, inside the list.
void _expectShown(WidgetTester tester, String text) {
  final Finder found = find.textContaining(text, findRichText: true);
  expect(found, findsWidgets);
  final Rect list = tester.getRect(find.byType(ListView).first);
  final Rect rect = tester.getRect(found.first);
  expect(rect.bottom, greaterThan(list.top));
  expect(rect.top, lessThan(list.bottom));
}

String _count(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('chat-search-count'))).data!;

/// Whether some text on screen has [word] marked as found.
bool _marked(WidgetTester tester, String word) {
  bool found = false;
  for (final RichText r in tester.widgetList<RichText>(find.byType(RichText))) {
    r.text.visitChildren((InlineSpan span) {
      if (span is TextSpan &&
          span.style?.backgroundColor != null &&
          span.text == word) {
        found = true;
      }
      return !found;
    });
  }
  return found;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat-search-field')), text);
  // The search waits for typing to pause.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  group('in a chat with a friend', () {
    testWidgets('finds, counts, marks and jumps far up', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(
        _app(const ConversationScreen(peerAddress: _ada, title: 'Ada')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chat-search-button')));
      await tester.pumpAndSettle();
      // The field to write in gives way to the matches and arrows.
      expect(
        find.byKey(const Key('conversation-composer-field')),
        findsNothing,
      );
      await _type(tester, 'zolw');

      expect(_count(tester), '1 z 3');
      _expectShown(tester, 'Nowa: zolw je sałatę');
      expect(_marked(tester, 'zolw'), isTrue);

      await tester.tap(find.byKey(const Key('chat-search-older')));
      await tester.pumpAndSettle();
      expect(_count(tester), '2 z 3');
      _expectShown(tester, 'W połowie');
      expect(_marked(tester, 'żółw'), isTrue);

      await tester.tap(find.byKey(const Key('chat-search-older')));
      await tester.pumpAndSettle();
      expect(_count(tester), '3 z 3');
      _expectShown(tester, 'Bardzo stara wiadomość');
      expect(_marked(tester, 'ŻÓŁW'), isTrue);

      await tester.tap(find.byKey(const Key('chat-search-newer')));
      await tester.pumpAndSettle();
      expect(_count(tester), '2 z 3');
      _expectShown(tester, 'W połowie');

      // Closed: the field to write in is back, nothing is marked.
      await tester.tap(find.byKey(const Key('chat-search-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-search-field')), findsNothing);
      expect(
        find.byKey(const Key('conversation-composer-field')),
        findsOneWidget,
      );
      expect(_marked(tester, 'żółw'), isFalse);
    });

    testWidgets('several words, and nothing found', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(
        _app(const ConversationScreen(peerAddress: _ada, title: 'Ada')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-search-button')));
      await tester.pumpAndSettle();
      await _type(tester, 'ZNALAZŁ zolw');
      expect(_count(tester), '1 z 1');
      _expectShown(tester, 'W połowie');
      await _type(tester, 'kangur');
      expect(_count(tester), 'Brak wyników');
    });

    testWidgets('Ctrl+F opens the search, Enter goes on, Esc closes', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          _app(const ConversationScreen(peerAddress: _ada, title: 'Ada')),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('chat-search-field')), findsOneWidget);

        await _type(tester, 'zolw');
        expect(_count(tester), '1 z 3');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(_count(tester), '2 z 3');

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('chat-search-field')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('opened from a result: at that message, searching', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(
        _app(
          const ConversationScreen(
            peerAddress: _ada,
            title: 'Ada',
            initialMessageId: 'm-2',
            searchText: 'zolw',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_count(tester), '3 z 3');
      _expectShown(tester, 'Bardzo stara wiadomość');
    });

    testWidgets('320 px, text twice as big: in the menu, nothing overflows', (
      WidgetTester tester,
    ) async {
      _narrow(tester);
      await tester.pumpWidget(
        _app(
          const ConversationScreen(peerAddress: _ada, title: 'Ada'),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      // No room for the magnifier next to the name: it is in the menu.
      expect(find.byKey(const Key('chat-search-button')), findsNothing);
      await tester.tap(find.byKey(const Key('conversation-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation-search-menu')));
      await tester.pumpAndSettle();
      await _type(tester, 'zolw');
      expect(tester.takeException(), isNull);
      expect(_count(tester), '1 z 3');
      await tester.tap(find.byKey(const Key('chat-search-older')));
      await tester.tap(find.byKey(const Key('chat-search-older')));
      await tester.pumpAndSettle();
      expect(_count(tester), '3 z 3');
      _expectShown(tester, 'Bardzo stara wiadomość');
      expect(tester.takeException(), isNull);
      // The arrows are named for screen readers and big enough to hit.
      expect(find.byTooltip('Starszy wynik'), findsOneWidget);
      expect(find.byTooltip('Nowszy wynik'), findsOneWidget);
      final Size arrow = tester.getSize(
        find.byKey(const Key('chat-search-older')),
      );
      expect(arrow.width, greaterThanOrEqualTo(48));
      expect(arrow.height, greaterThanOrEqualTo(48));
      // The count is announced when it changes.
      final SemanticsHandle semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byKey(const Key('chat-search-count'))),
        matchesSemantics(label: '3 z 3', isLiveRegion: true),
      );
      semantics.dispose();
    });
  });

  group('in a group', () {
    testWidgets('finds and jumps far up a reversed list', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(
        _app(
          const GroupConversationScreen(groupId: _groupId, groupName: 'Ekipa'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-search-button')));
      await tester.pumpAndSettle();
      await _type(tester, 'ŻÓŁW');
      expect(_count(tester), '1 z 3');
      await tester.tap(find.byKey(const Key('chat-search-older')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-search-older')));
      await tester.pumpAndSettle();
      expect(_count(tester), '3 z 3');
      _expectShown(tester, 'Bardzo stara wiadomość');
      expect(_marked(tester, 'ŻÓŁW'), isTrue);
    });

    testWidgets('320 px, text twice as big', (WidgetTester tester) async {
      _narrow(tester);
      await tester.pumpWidget(
        _app(
          const GroupConversationScreen(groupId: _groupId, groupName: 'Ekipa'),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('group-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('group-search-menu')));
      await tester.pumpAndSettle();
      await _type(tester, 'zolw');
      expect(tester.takeException(), isNull);
      expect(_count(tester), '1 z 3');
    });
  });

  group('on the chat list', () {
    Widget searchPage() => Scaffold(
      body: _QueryHarness(
        builder: (String query) =>
            ListView(children: <Widget>[MessageSearchResults(query: query)]),
      ),
    );

    Map<String, List<ChatMessage>> threads() => <String, List<ChatMessage>>{
      _ada: <ChatMessage>[
        _message(1, text: 'Ada: kupiłam żółwia', base: 0),
        _message(2, text: 'Ada: nic', base: 0),
      ],
      _bob: <ChatMessage>[
        _message(1, sender: _bob, text: 'Bob: ŻÓŁW stary', base: 1000),
        _message(2, sender: _bob, text: 'Bob: zolw nowy', base: 9000000),
      ],
      'group:$_groupId': <ChatMessage>[
        _message(1, sender: _bob, text: 'Ekipa: żółwie wyścigi', base: 5000000),
      ],
    };

    testWidgets('grouped by conversation, newest first; a tap opens it', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_app(searchPage(), threads: threads()));
      await tester.enterText(find.byKey(const Key('harness-query')), 'zolw');
      // Built with the new words, then the pause in typing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // Bob's newest match is the newest of all, then the group, then Ada.
      final double bob = tester.getTopLeft(find.text('Bob')).dy;
      final double group = tester.getTopLeft(find.text('Ekipa')).dy;
      final double ada = tester.getTopLeft(find.text('Ada')).dy;
      expect(bob, lessThan(group));
      expect(group, lessThan(ada));
      expect(find.text('2 wiadomości'), findsOneWidget);
      // Within Bob's: the newest first.
      expect(
        tester
            .getTopLeft(
              find.textContaining('Bob: zolw nowy', findRichText: true),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.textContaining('Bob: ŻÓŁW stary', findRichText: true),
              )
              .dy,
        ),
      );
      expect(_marked(tester, 'ŻÓŁW'), isTrue);

      await tester.tap(
        find.textContaining('Bob: ŻÓŁW stary', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(_count(tester), '2 z 2');
      _expectShown(tester, 'Bob: ŻÓŁW stary');
    });

    testWidgets('a group result opens the group at that message', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_app(searchPage(), threads: threads()));
      await tester.enterText(find.byKey(const Key('harness-query')), 'wyscigi');
      // Built with the new words, then the pause in typing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(
        find.textContaining('Ekipa: żółwie', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GroupConversationScreen), findsOneWidget);
      expect(_count(tester), '1 z 1');
    });

    testWidgets('nothing found, and one letter searches no messages', (
      WidgetTester tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_app(searchPage(), threads: threads()));
      await tester.enterText(find.byKey(const Key('harness-query')), 'z');
      // Built with the new words, then the pause in typing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-search-results')), findsNothing);
      await tester.enterText(find.byKey(const Key('harness-query')), 'kangur');
      // Built with the new words, then the pause in typing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-search-empty')), findsOneWidget);
    });

    testWidgets('320 px, text twice as big', (WidgetTester tester) async {
      _narrow(tester);
      await tester.pumpWidget(
        _app(searchPage(), threads: threads(), textScale: 2),
      );
      await tester.enterText(find.byKey(const Key('harness-query')), 'zolw');
      // Built with the new words, then the pause in typing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Bob'), findsOneWidget);
    });
  });
}

/// A field and what it typed, for [MessageSearchResults].
class _QueryHarness extends StatefulWidget {
  const _QueryHarness({required this.builder});

  final Widget Function(String query) builder;

  @override
  State<_QueryHarness> createState() => _QueryHarnessState();
}

class _QueryHarnessState extends State<_QueryHarness> {
  String _query = '';

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      TextField(
        key: const Key('harness-query'),
        onChanged: (String v) => setState(() => _query = v),
      ),
      Expanded(child: widget.builder(_query)),
    ],
  );
}
