import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The search field of the chat list (names with or without Polish
/// letters, and messages of every conversation under them) and the one at
/// the top of the settings (a setting by its name).

const String _zofia = 'zofia.ygg';
const String _jan = 'jan.ygg';

Widget _app({int parkFriends = 0}) => ProviderScope(
  overrides: [
    appSettingsStoreProvider.overrideWithValue(
      MemoryAppSettingsStore(const AppSettings()),
    ),
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(<String, List<ChatMessage>>{
        _jan: const <ChatMessage>[
          ChatMessage(
            id: 'j1',
            sender: _jan,
            text: 'Widziałem dziś żółwia w parku',
            sentAtMillis: 1000,
            direction: ChatMessageDirection.incoming,
          ),
        ],
      }),
    ),
    socialHubSeedProvider.overrideWithValue(
      SocialHubState.empty().copyWith(
        book: FriendshipBook.restore(
          profiles: <String, FriendProfile>{
            for (int i = 0; i < parkFriends; i++)
              'park$i.ygg': FriendProfile(
                address: 'park$i.ygg',
                displayName: 'Parkowy $i',
                status: FriendRelationshipStatus.accepted,
              ),
            _zofia: const FriendProfile(
              address: _zofia,
              displayName: 'Zofia Żółkiewska',
              status: FriendRelationshipStatus.accepted,
            ),
            _jan: const FriendProfile(
              address: _jan,
              displayName: 'Jan',
              nickname: 'Sąsiad',
              status: FriendRelationshipStatus.accepted,
            ),
          },
        ),
      ),
    ),
  ],
  child: const ZenRewriteApp(),
);

Future<void> _search(WidgetTester tester, Key field, String text) async {
  await tester.enterText(find.byKey(field), text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the chat list finds people without Polish letters and messages',
    (WidgetTester tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      const Key field = Key('chats-search-field');

      await _search(tester, field, 'zolk');
      expect(find.text('Zofia Żółkiewska'), findsOneWidget);
      expect(find.text('Jan'), findsNothing);

      // The nickname given counts too.
      await _search(tester, field, 'sasiad');
      expect(find.text('Jan'), findsWidgets);
      expect(find.text('Zofia Żółkiewska'), findsNothing);

      // A word from a message: the conversation it is in, under "Wiadomości".
      await _search(tester, field, 'zolwia');
      expect(find.byKey(const Key('message-search-results')), findsOneWidget);
      final Finder hit = find.textContaining(
        'Widziałem dziś żółwia',
        findRichText: true,
      );
      await tester.scrollUntilVisible(
        hit,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('chats-tab-body')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(hit);
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(find.byKey(const Key('chat-search-count')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-search-count'))).data,
        '1 z 1',
      );
    },
  );

  testWidgets('messages are searched also below a long list of names', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(parkFriends: 30));
    await tester.pumpAndSettle();
    // Thirty names match "park", and so does Jan's message: its results
    // are far below, off screen, and still read.
    await _search(tester, const Key('chats-search-field'), 'park');
    expect(find.text('Parkowy 0'), findsOneWidget);
    expect(
      find.byKey(const Key('message-search-results'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Widziałem dziś żółwia',
        findRichText: true,
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  for (final double scale in <double>[1, 2]) {
    testWidgets('a screen reader finds each search field where it is drawn '
        '(320 px, text ×${scale.round()})', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      /// The field's node: its own, as large as the field, and a tap at its
      /// middle lands on the field.
      void ownNode(Key key) {
        final Finder field = find.byKey(key);
        final SemanticsNode node = tester.getSemantics(field);
        expect(node, isSemantics(isTextField: true));
        Rect bounds = node.rect;
        for (SemanticsNode? n = node; n != null; n = n.parent) {
          if (n.transform != null) {
            bounds = MatrixUtils.transformRect(n.transform!, bounds);
          }
        }
        final Rect drawn = tester.getRect(field);
        expect(
          drawn.inflate(1).contains(bounds.topLeft) &&
              drawn.inflate(1).contains(bounds.bottomRight),
          isTrue,
          reason: '$key: read out at $bounds, drawn at $drawn',
        );
        final HitTestResult hit = tester.hitTestOnBinding(bounds.center);
        final RenderObject box = tester.renderObject(field);
        expect(
          hit.path.any((HitTestEntry e) => identical(e.target, box)),
          isTrue,
          reason: '$key: a tap at the middle of its bounds misses it',
        );
      }

      ownNode(const Key('chats-search-field'));
      await tester.tap(find.byKey(const Key('chats-status-chip')));
      await tester.pumpAndSettle();
      ownNode(const Key('settings-search-field'));
      semantics.dispose();
    });
  }

  testWidgets('the settings find a setting by its name', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    await tester.pumpAndSettle();
    const Key field = Key('settings-search-field');
    expect(find.byKey(field), findsOneWidget);

    await _search(tester, field, 'jezyk');
    expect(
      find.byKey(const ValueKey<String>('settings-language-tile')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-nav-invite')), findsNothing);
    expect(find.byKey(const Key('settings-rerun-setup')), findsNothing);

    // By what is written under it.
    await _search(tester, field, 'haslo blokada');
    expect(find.byKey(const Key('settings-nav-security')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('settings-language-tile')),
      findsNothing,
    );

    // A group's title shows the whole group.
    await _search(tester, field, 'zaawansowane');
    expect(find.byKey(const Key('settings-nav-diagnostics')), findsOneWidget);
    expect(find.byKey(const Key('settings-nav-network')), findsNothing);
    await _search(tester, field, 'siec');
    expect(find.byKey(const Key('settings-nav-network')), findsOneWidget);

    await _search(tester, field, 'kangur');
    expect(find.byKey(const Key('settings-search-empty')), findsOneWidget);

    await _search(tester, field, '');
    expect(find.byKey(const Key('settings-rerun-setup')), findsOneWidget);
  });
}
