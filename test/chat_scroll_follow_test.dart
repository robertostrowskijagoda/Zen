import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/presentation/jump_to_latest.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// A conversation at its newest message stays there: when the keyboard
/// opens, when a message comes in, when one's own goes out (also a long
/// one, also from further up). Scrolled up, it keeps its place.

const String _ada = 'ada.ygg';
const String _groupId = 'grp-follow';
const String _groupKey = 'group:$_groupId';

String _long(int n) =>
    'Długa wiadomość numer $n. ${'Bardzo długi tekst. ' * 40}';

ChatMessage _message(
  int n, {
  bool outgoing = false,
  String sender = _ada,
  String? text,
}) {
  return ChatMessage(
    id: 'm-$n',
    sender: outgoing ? 'self' : sender,
    text: text ?? 'Wiadomość numer $n',
    sentAtMillis: 1000000 + n * 1000,
    direction: outgoing
        ? ChatMessageDirection.outgoing
        : ChatMessageDirection.incoming,
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> _addMessage(
  WidgetTester tester,
  MemoryMessageTimelineStore store,
  String key,
  ChatMessage message,
) async {
  await store.append(key, message);
  ProviderScope.containerOf(
    tester.element(find.byType(Scaffold).first),
  ).read(messageTimelineRevisionProvider.notifier).bump();
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

double _distanceFromNewest(WidgetTester tester, {required bool reversed}) {
  final ScrollPosition position = _position(tester);
  return reversed
      ? position.pixels - position.minScrollExtent
      : position.maxScrollExtent - position.pixels;
}

/// The bottom of the text [text] is on screen, above the list's bottom.
void _expectShown(WidgetTester tester, String text) {
  final Rect list = tester.getRect(find.byType(ListView));
  final Finder found = find.textContaining(text);
  expect(found, findsOneWidget);
  final Rect rect = tester.getRect(found);
  expect(rect.bottom, lessThanOrEqualTo(list.bottom + 0.5));
  expect(rect.bottom, greaterThan(list.top));
}

Future<void> _openKeyboard(WidgetTester tester) async {
  tester.view.viewInsets = const FakeViewPadding(bottom: 900);
  addTearDown(tester.view.resetViewInsets);
  // The keyboard slides in over several frames.
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

Future<MemoryMessageTimelineStore> _pumpDirect(
  WidgetTester tester, {
  bool longMessages = false,
}) async {
  _phone(tester);
  final MemoryMessageTimelineStore store = MemoryMessageTimelineStore(
    <String, List<ChatMessage>>{
      _ada: <ChatMessage>[
        for (int i = 0; i < 40; i++)
          _message(i, text: longMessages && i.isEven ? _long(i) : null),
      ],
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        messageTimelineStoreProvider.overrideWithValue(store),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _ada: FriendProfile(
                  address: _ada,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ),
      ],
      child: const MaterialApp(
        home: ConversationScreen(peerAddress: _ada, title: 'Ada'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<MemoryMessageTimelineStore> _pumpGroup(
  WidgetTester tester, {
  bool longMessages = false,
}) async {
  _phone(tester);
  final MemoryMessageTimelineStore store = MemoryMessageTimelineStore(
    <String, List<ChatMessage>>{
      _groupKey: <ChatMessage>[
        for (int i = 0; i < 40; i++)
          _message(
            i,
            sender: 'bob.ygg',
            text: longMessages && i.isEven ? _long(i) : null,
          ),
      ],
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        messageTimelineStoreProvider.overrideWithValue(store),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            groups: const <String, GroupProfile>{
              _groupId: GroupProfile(
                id: _groupId,
                name: 'Ekipa',
                createdById: 'self',
                createdAtMillis: 0,
                memberAddresses: <String>['self', 'bob.ygg'],
              ),
            },
          ),
        ),
      ],
      child: const MaterialApp(
        home: GroupConversationScreen(groupId: _groupId, groupName: 'Ekipa'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  group('1:1 chat', () {
    testWidgets('opens at the newest message, also with long ones', (
      WidgetTester tester,
    ) async {
      await _pumpDirect(tester, longMessages: true);
      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
      _expectShown(tester, 'Wiadomość numer 39');
    });

    testWidgets('the keyboard opening keeps it at the newest message', (
      WidgetTester tester,
    ) async {
      await _pumpDirect(tester, longMessages: true);
      await tester.tap(find.byKey(const Key('conversation-composer-field')));
      await _openKeyboard(tester);
      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
      _expectShown(tester, 'Wiadomość numer 39');
    });

    testWidgets('a message coming in at the bottom is followed', (
      WidgetTester tester,
    ) async {
      final MemoryMessageTimelineStore store = await _pumpDirect(tester);
      await _addMessage(tester, store, _ada, _message(100, text: _long(100)));
      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
      expect(find.byKey(const Key('jump-to-latest-button')), findsNothing);
    });

    testWidgets('one\'s own message is shown at once, also a long one from '
        'further up', (WidgetTester tester) async {
      await _pumpDirect(tester, longMessages: true);
      final ScrollPosition position = _position(tester);
      position.jumpTo(
        position.maxScrollExtent - 3 * position.viewportDimension,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('jump-to-latest-button')), findsOneWidget);

      final String text = 'Moja odpowiedź. ${'Słowo po słowie. ' * 30}';
      await tester.enterText(
        find.byKey(const Key('conversation-composer-field')),
        text,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('conversation-send-button')));
      await tester.pumpAndSettle();

      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
      _expectShown(tester, 'Moja odpowiedź.');
      expect(find.byKey(const Key('jump-to-latest-button')), findsNothing);
    });

    testWidgets('scrolled up, it keeps its place while messages come in and '
        'the keyboard opens', (WidgetTester tester) async {
      final MemoryMessageTimelineStore store = await _pumpDirect(tester);
      final ScrollPosition position = _position(tester);
      position.jumpTo(
        position.maxScrollExtent - 2 * position.viewportDimension,
      );
      await tester.pumpAndSettle();
      final double pixels = _position(tester).pixels;
      final double top = tester.getTopLeft(find.text('Wiadomość numer 20')).dy;

      await _addMessage(tester, store, _ada, _message(100));
      await _addMessage(tester, store, _ada, _message(101, text: _long(101)));
      expect(_position(tester).pixels, pixels);
      expect(find.byKey(const Key('jump-to-latest-badge')), findsOneWidget);

      await tester.tap(find.byKey(const Key('conversation-composer-field')));
      await _openKeyboard(tester);
      expect(_position(tester).pixels, pixels);
      expect(
        tester.getTopLeft(find.text('Wiadomość numer 20')).dy,
        closeTo(top, 0.5),
      );
      expect(find.byKey(const Key('jump-to-latest-badge')), findsOneWidget);
    });
  });

  group('group chat', () {
    testWidgets('the keyboard opening keeps it at the newest message', (
      WidgetTester tester,
    ) async {
      await _pumpGroup(tester, longMessages: true);
      await tester.tap(find.byKey(const Key('group-chat-composer-field')));
      await _openKeyboard(tester);
      expect(_distanceFromNewest(tester, reversed: true), lessThan(1));
      _expectShown(tester, 'Wiadomość numer 39');
    });

    testWidgets('a message coming in at the bottom is shown', (
      WidgetTester tester,
    ) async {
      final MemoryMessageTimelineStore store = await _pumpGroup(tester);
      await _addMessage(
        tester,
        store,
        _groupKey,
        _message(100, sender: 'bob.ygg', text: _long(100)),
      );
      expect(_distanceFromNewest(tester, reversed: true), lessThan(1));
      _expectShown(tester, 'Długa wiadomość numer 100');
    });

    testWidgets('one\'s own message is shown at once, also a long one from '
        'further up', (WidgetTester tester) async {
      await _pumpGroup(tester, longMessages: true);
      final ScrollPosition position = _position(tester);
      position.jumpTo(3 * position.viewportDimension);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('jump-to-latest-button')), findsOneWidget);

      final String text = 'Moja odpowiedź. ${'Słowo po słowie. ' * 30}';
      await tester.enterText(
        find.byKey(const Key('group-chat-composer-field')),
        text,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('group-chat-send-button')));
      await tester.pumpAndSettle();

      expect(_distanceFromNewest(tester, reversed: true), lessThan(1));
      _expectShown(tester, 'Moja odpowiedź.');
    });

    testWidgets('scrolled up, the messages read stay where they are while '
        'new ones come in below', (WidgetTester tester) async {
      final MemoryMessageTimelineStore store = await _pumpGroup(tester);
      final ScrollPosition position = _position(tester);
      position.jumpTo(2 * position.viewportDimension);
      await tester.pumpAndSettle();
      final Finder read = find.text('Wiadomość numer 20');
      expect(read, findsOneWidget);
      final double top = tester.getTopLeft(read).dy;

      await _addMessage(
        tester,
        store,
        _groupKey,
        _message(100, sender: 'bob.ygg'),
      );
      await _addMessage(
        tester,
        store,
        _groupKey,
        _message(101, sender: 'bob.ygg', text: _long(101)),
      );
      expect(tester.getTopLeft(read).dy, closeTo(top, 0.5));
      expect(find.byKey(const Key('jump-to-latest-badge')), findsOneWidget);

      // Down again, a new one is followed.
      await tester.tap(find.byKey(const Key('jump-to-latest-button')));
      await tester.pumpAndSettle();
      await _addMessage(
        tester,
        store,
        _groupKey,
        _message(102, sender: 'bob.ygg', text: _long(102)),
      );
      expect(_distanceFromNewest(tester, reversed: true), lessThan(1));
      _expectShown(tester, 'Długa wiadomość numer 102');
    });
  });

  group('ChatScrollController', () {
    Widget list(ChatScrollController controller, ValueNotifier<double> last) {
      return MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            reverse: controller.reversed,
            itemCount: 30,
            itemBuilder: (BuildContext context, int i) {
              // The newest item: a picture that takes its size once decoded.
              final bool newest = controller.reversed ? i == 0 : i == 29;
              return newest
                  ? ValueListenableBuilder<double>(
                      valueListenable: last,
                      builder: (BuildContext context, double h, _) =>
                          SizedBox(height: h, child: Text('item $i')),
                    )
                  : SizedBox(height: 80, child: Text('item $i'));
            },
          ),
        ),
      );
    }

    for (final bool reversed in <bool>[false, true]) {
      testWidgets('reversed: $reversed: an item growing at the newest end is '
          'followed, not when scrolled up', (WidgetTester tester) async {
        final ChatScrollController controller = ChatScrollController(
          reversed: reversed,
        );
        addTearDown(controller.dispose);
        final ValueNotifier<double> last = ValueNotifier<double>(40);
        addTearDown(last.dispose);
        await tester.pumpWidget(list(controller, last));
        double distance() {
          final ScrollPosition p = controller.position;
          return reversed
              ? p.pixels - p.minScrollExtent
              : p.maxScrollExtent - p.pixels;
        }

        expect(distance(), lessThan(0.5), reason: 'opens at the newest');
        last.value = 400;
        await tester.pump();
        expect(distance(), lessThan(0.5), reason: 'in the same frame');
        expect(controller.followsLatest, isTrue);

        // Away from the newest end: the place is kept.
        final double away = reversed
            ? 600
            : controller.position.maxScrollExtent - 600;
        controller.jumpTo(away);
        await tester.pump();
        expect(controller.followsLatest, isFalse);
        last.value = 40;
        await tester.pump();
        last.value = 500;
        await tester.pump();
        expect(controller.position.pixels, away);

        controller.showLatest();
        await tester.pump();
        expect(distance(), lessThan(0.5));
        expect(controller.followsLatest, isTrue);
      });
    }
  });
}
