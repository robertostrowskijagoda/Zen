import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const String _ada = 'ada.ygg';
const String _groupId = 'grp-jump';
const String _jumpButton = 'jump-to-latest-button';
const String _jumpBadge = 'jump-to-latest-badge';

ChatMessage _message(int n, {bool outgoing = false, String? sender}) {
  return ChatMessage(
    id: 'm-$n',
    sender: outgoing ? 'self' : (sender ?? _ada),
    text: 'Wiadomość numer $n',
    sentAtMillis: 1000000 + n * 1000,
    direction: outgoing
        ? ChatMessageDirection.outgoing
        : ChatMessageDirection.incoming,
  );
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

ScrollPosition _position(WidgetTester tester) {
  return tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
}

/// Scrolls the list [screens] viewports away from its newest message.
Future<void> _scrollAway(
  WidgetTester tester, {
  required bool reversed,
  required double screens,
}) async {
  final ScrollPosition position = _position(tester);
  final double away = position.viewportDimension * screens;
  position.jumpTo(reversed ? away : position.maxScrollExtent - away);
  await tester.pumpAndSettle();
}

double _distanceFromNewest(WidgetTester tester, {required bool reversed}) {
  final ScrollPosition position = _position(tester);
  return reversed
      ? position.pixels - position.minScrollExtent
      : position.maxScrollExtent - position.pixels;
}

Future<MemoryMessageTimelineStore> _pumpDirect(WidgetTester tester) async {
  final MemoryMessageTimelineStore store = MemoryMessageTimelineStore(
    <String, List<ChatMessage>>{
      _ada: <ChatMessage>[for (int i = 0; i < 60; i++) _message(i)],
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        messageTimelineStoreProvider.overrideWithValue(store),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            friends: const <String, FriendProfile>{
              _ada: FriendProfile(
                address: _ada,
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
              ),
            },
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

Future<MemoryMessageTimelineStore> _pumpGroup(WidgetTester tester) async {
  final MemoryMessageTimelineStore store = MemoryMessageTimelineStore(
    <String, List<ChatMessage>>{
      'group:$_groupId': <ChatMessage>[
        for (int i = 0; i < 60; i++) _message(i, sender: 'bob.ygg'),
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
  group('jump to the latest message, 1:1 chat', () {
    testWidgets('is hidden at the newest message and shows when far above', (
      WidgetTester tester,
    ) async {
      await _pumpDirect(tester);
      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
      expect(find.byKey(const Key(_jumpButton)), findsNothing);

      // Within a screen of the newest message: still no button.
      await _scrollAway(tester, reversed: false, screens: 0.5);
      expect(find.byKey(const Key(_jumpButton)), findsNothing);

      await _scrollAway(tester, reversed: false, screens: 2);
      expect(find.byKey(const Key(_jumpButton)), findsOneWidget);
      expect(find.byTooltip('Przewiń na sam dół'), findsOneWidget);
      expect(find.byKey(const Key(_jumpBadge)), findsNothing);
    });

    testWidgets('tapping returns to the newest message and hides itself', (
      WidgetTester tester,
    ) async {
      await _pumpDirect(tester);
      await _scrollAway(tester, reversed: false, screens: 3);

      await tester.tap(find.byKey(const Key(_jumpButton)));
      await tester.pumpAndSettle();

      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
      expect(find.byKey(const Key(_jumpButton)), findsNothing);
    });

    testWidgets('counts what comes in while scrolled up, resets at the end', (
      WidgetTester tester,
    ) async {
      final MemoryMessageTimelineStore store = await _pumpDirect(tester);
      await _scrollAway(tester, reversed: false, screens: 3);
      final double pixels = _position(tester).pixels;

      await _addMessage(tester, store, _ada, _message(100));
      await _addMessage(tester, store, _ada, _message(101));
      await _addMessage(tester, store, _ada, _message(102));

      // The reader is not pulled down.
      expect(_position(tester).pixels, pixels);
      expect(find.byKey(const Key(_jumpBadge)), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.byKey(const Key(_jumpButton)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key(_jumpBadge)), findsNothing);
      expect(find.byKey(const Key(_jumpButton)), findsNothing);
      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));

      // At the end a new message is followed, not counted.
      await _addMessage(tester, store, _ada, _message(103));
      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
      expect(find.byKey(const Key(_jumpButton)), findsNothing);
    });

    testWidgets('a message of one\'s own is not counted', (
      WidgetTester tester,
    ) async {
      final MemoryMessageTimelineStore store = await _pumpDirect(tester);
      await _scrollAway(tester, reversed: false, screens: 3);

      await _addMessage(tester, store, _ada, _message(100, outgoing: true));

      expect(find.byKey(const Key(_jumpBadge)), findsNothing);
      // Sending takes the person to the message.
      expect(_distanceFromNewest(tester, reversed: false), lessThan(1));
    });
  });

  group('jump to the latest message, group chat', () {
    testWidgets('is hidden at the newest message and shows when far above', (
      WidgetTester tester,
    ) async {
      await _pumpGroup(tester);
      expect(_distanceFromNewest(tester, reversed: true), lessThan(1));
      expect(find.byKey(const Key(_jumpButton)), findsNothing);

      await _scrollAway(tester, reversed: true, screens: 0.5);
      expect(find.byKey(const Key(_jumpButton)), findsNothing);

      await _scrollAway(tester, reversed: true, screens: 2);
      expect(find.byKey(const Key(_jumpButton)), findsOneWidget);
      expect(find.byTooltip('Przewiń na sam dół'), findsOneWidget);
    });

    testWidgets('tapping returns to the newest message and hides itself', (
      WidgetTester tester,
    ) async {
      await _pumpGroup(tester);
      await _scrollAway(tester, reversed: true, screens: 3);

      await tester.tap(find.byKey(const Key(_jumpButton)));
      await tester.pumpAndSettle();

      expect(_distanceFromNewest(tester, reversed: true), lessThan(1));
      expect(find.byKey(const Key(_jumpButton)), findsNothing);
    });

    testWidgets('counts what comes in while scrolled up, resets at the end', (
      WidgetTester tester,
    ) async {
      final MemoryMessageTimelineStore store = await _pumpGroup(tester);
      await _scrollAway(tester, reversed: true, screens: 3);

      final String key = 'group:$_groupId';
      await _addMessage(tester, store, key, _message(100, sender: 'bob.ygg'));
      await _addMessage(tester, store, key, _message(101, sender: 'bob.ygg'));

      expect(find.byKey(const Key(_jumpBadge)), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.byKey(const Key(_jumpButton)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key(_jumpBadge)), findsNothing);
      expect(find.byKey(const Key(_jumpButton)), findsNothing);

      // At the end a new message is simply there, not counted.
      await _addMessage(tester, store, key, _message(102, sender: 'bob.ygg'));
      expect(_distanceFromNewest(tester, reversed: true), lessThan(1));
      expect(find.byKey(const Key(_jumpButton)), findsNothing);
    });
  });
}
