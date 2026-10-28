import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The send button of a chat composer sits in the middle of the one-line
/// text field (the same centre line), its icon in the middle of the button,
/// and the button as far from the right end of the rounded box as from its
/// top and bottom: concentric with the round end. Measured, no goldens.

const GroupProfile _group = GroupProfile(
  id: 'grp-1',
  name: 'Ekipa',
  createdById: 'self',
  createdAtMillis: 1000,
  memberAddresses: <String>['peer-alice'],
);

Widget _chat() => ProviderScope(
  overrides: [
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(),
    ),
    socialHubAutoHydrateProvider.overrideWithValue(false),
    socialHubSeedProvider.overrideWithValue(
      SocialHubState.empty().copyWith(
        friends: const <String, FriendProfile>{
          'ada.ygg': FriendProfile(
            address: 'ada.ygg',
            displayName: 'Ada',
            status: FriendRelationshipStatus.accepted,
          ),
        },
      ),
    ),
  ],
  child: MaterialApp(
    theme: ZenTheme.dark(),
    home: const ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
  ),
);

Widget _groupChat() => ProviderScope(
  overrides: [
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(),
    ),
    socialHubAutoHydrateProvider.overrideWithValue(false),
    socialHubSeedProvider.overrideWithValue(
      SocialHubState.empty().copyWith(
        groups: <String, GroupProfile>{_group.id: _group},
      ),
    ),
  ],
  child: MaterialApp(
    theme: ZenTheme.dark(),
    home: GroupConversationScreen(groupId: _group.id, groupName: _group.name),
  ),
);

/// The rounded box the composer row is drawn in.
Rect _composerBox(WidgetTester tester, Finder field) {
  final Finder row = find.ancestor(of: field, matching: find.byType(Row)).first;
  return tester.getRect(row);
}

Future<void> _expectCentred(
  WidgetTester tester, {
  required Key fieldKey,
  required Key buttonKey,
}) async {
  final Finder field = find.byKey(fieldKey);
  final Finder button = find.byKey(buttonKey);
  expect(field, findsOneWidget);
  expect(button, findsOneWidget);

  // The visible circle of the button: its Material.
  final Rect circle = tester.getRect(
    find.descendant(of: button, matching: find.byType(Material)).first,
  );
  final Rect icon = tester.getRect(
    find.descendant(of: button, matching: find.byIcon(Icons.send_rounded)),
  );
  final Rect text = tester.getRect(field);
  final Rect box = _composerBox(tester, field);

  expect(circle.width, closeTo(circle.height, 0.01), reason: 'round');
  expect(icon.center.dx, closeTo(circle.center.dx, 0.5), reason: 'icon x');
  expect(icon.center.dy, closeTo(circle.center.dy, 0.5), reason: 'icon y');
  expect(
    circle.center.dy,
    closeTo(text.center.dy, 0.5),
    reason: 'button on the centre line of the text field',
  );
  expect(
    circle.center.dy,
    closeTo(box.center.dy, 0.5),
    reason: 'button in the middle of the composer',
  );
  final double top = circle.top - box.top;
  final double bottom = box.bottom - circle.bottom;
  final double end = box.right - circle.right;
  expect(top, closeTo(bottom, 0.5), reason: 'as far from top as bottom');
  expect(end, closeTo(top, 0.5), reason: 'as far from the end as the top');
}

void main() {
  for (final double scale in <double>[1, 1.3]) {
    group('text scale $scale', () {
      testWidgets('the chat send button is centred', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(1080, 2340);
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(_chat());
        await tester.pump(const Duration(milliseconds: 500));

        await _expectCentred(
          tester,
          fieldKey: const Key('conversation-composer-field'),
          buttonKey: const Key('conversation-send-button'),
        );
        // With text it is still in the same place.
        await tester.enterText(
          find.byKey(const Key('conversation-composer-field')),
          'Cześć',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await _expectCentred(
          tester,
          fieldKey: const Key('conversation-composer-field'),
          buttonKey: const Key('conversation-send-button'),
        );
      });

      testWidgets('the group chat send button is centred', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = const Size(1080, 2340);
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(_groupChat());
        await tester.pump(const Duration(milliseconds: 500));

        await _expectCentred(
          tester,
          fieldKey: const Key('group-chat-composer-field'),
          buttonKey: const Key('group-chat-send-button'),
        );
        // Its tap target is larger than the circle, around it evenly.
        final Size target = tester.getSize(
          find.byKey(const Key('group-chat-send-button')),
        );
        expect(target.width, greaterThanOrEqualTo(44));
        expect(target.height, greaterThanOrEqualTo(44));
      });
    });
  }

  testWidgets('a long message grows the field and the button stays at '
      'the bottom', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_chat());
    await tester.pump(const Duration(milliseconds: 500));
    final Finder field = find.byKey(const Key('conversation-composer-field'));
    final double oneLine = tester.getRect(field).height;
    await tester.enterText(field, 'a\nb\nc\nd');
    await tester.pump(const Duration(milliseconds: 300));
    final Rect text = tester.getRect(field);
    expect(text.height, greaterThan(oneLine + 20));
    final Rect circle = tester.getRect(
      find
          .descendant(
            of: find.byKey(const Key('conversation-send-button')),
            matching: find.byType(Material),
          )
          .first,
    );
    final Rect box = _composerBox(tester, field);
    expect(box.bottom - circle.bottom, closeTo(box.right - circle.right, 0.5));
  });
}
