import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_form_screen.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// Every button a screen reader reaches on the main screens has a name: an
// icon alone (Send, the microphone, the eye of a password) is announced as
// "button" and nothing else otherwise.

const GroupProfile _group = GroupProfile(
  id: 'grp-1',
  name: 'Ekipa',
  createdById: 'self',
  createdAtMillis: 1000,
  memberAddresses: <String>['peer-alice'],
);

SocialHubState _withFriend() => SocialHubState.empty().copyWith(
  book: FriendshipBook.restore(
    profiles: const <String, FriendProfile>{
      'ada.ygg': FriendProfile(
        address: 'ada.ygg',
        displayName: 'Ada',
        status: FriendRelationshipStatus.accepted,
      ),
    },
  ),
);

SocialHubState _withGroup() => SocialHubState.empty().copyWith(
  groups: <String, GroupProfile>{_group.id: _group},
);

/// Every node a tap reaches with no label, tooltip or value, described by
/// where it is on the screen.
List<String> _unnamedTappables(WidgetTester tester) {
  final List<String> found = <String>[];
  void visit(SemanticsNode node) {
    final SemanticsData data = node.getSemanticsData();
    final bool tappable =
        data.hasAction(SemanticsAction.tap) ||
        data.hasAction(SemanticsAction.longPress);
    final bool named =
        data.label.trim().isNotEmpty ||
        data.tooltip.trim().isNotEmpty ||
        data.value.trim().isNotEmpty ||
        data.hint.trim().isNotEmpty;
    if (tappable && !named && !node.isInvisible) {
      Rect rect = node.rect;
      for (SemanticsNode? n = node; n != null; n = n.parent) {
        final Matrix4? transform = n.transform;
        if (transform != null) {
          rect = MatrixUtils.transformRect(transform, rect);
        }
      }
      found.add('$data at $rect');
    }
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return found;
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  List<Override> overrides = const <Override>[],
  SocialHubState? seed,
}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        socialHubSeedProvider.overrideWithValue(seed ?? SocialHubState.empty()),
        ...overrides,
      ],
      child: MaterialApp(theme: ZenTheme.dark(), home: home),
    ),
  );
  for (int i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 5));
}

void main() {
  final Map<String, Future<void> Function(WidgetTester)> screens =
      <String, Future<void> Function(WidgetTester)>{
        'a chat with a friend': (WidgetTester tester) => _pump(
          tester,
          const ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
          seed: _withFriend(),
        ),
        'a chat with a friend, a message written': (WidgetTester tester) async {
          await _pump(
            tester,
            const ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
            seed: _withFriend(),
          );
          await tester.enterText(
            find.byKey(const Key('conversation-composer-field')),
            'Cześć',
          );
          await tester.pump();
        },
        'a group chat': (WidgetTester tester) => _pump(
          tester,
          GroupConversationScreen(groupId: _group.id, groupName: _group.name),
          seed: _withGroup(),
        ),
        'a new password': (WidgetTester tester) => _pump(
          tester,
          const PasswordFormScreen(),
          overrides: <Override>[
            passwordVaultServiceProvider.overrideWithValue(
              PasswordVaultService(disk: MemoryLedgerDisk()),
            ),
          ],
        ),
        'the account devices': (WidgetTester tester) => _pump(
          tester,
          const AccountDevicesScreen(),
          overrides: <Override>[
            ledgerNodeEnabledProvider.overrideWithValue(true),
            ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          ],
        ),
      };

  for (final MapEntry<String, Future<void> Function(WidgetTester)> screen
      in screens.entries) {
    testWidgets('every tappable on ${screen.key} has a name', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await screen.value(tester);
      final List<String> unnamed = _unnamedTappables(tester);
      await _done(tester);
      handle.dispose();
      expect(unnamed, isEmpty, reason: 'buttons without a name');
    });
  }

  testWidgets('the Send button of a chat says what it does', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(
      tester,
      const ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
      seed: _withFriend(),
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('conversation-send-button')))
          .getSemanticsData()
          .label,
      'Wyślij',
    );
    await _done(tester);
    handle.dispose();
  });

  testWidgets('the group Send button says what it does', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(
      tester,
      GroupConversationScreen(groupId: _group.id, groupName: _group.name),
      seed: _withGroup(),
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('group-chat-send-button')))
          .getSemanticsData()
          .label,
      'Wyślij',
    );
    await _done(tester);
    handle.dispose();
  });
}
