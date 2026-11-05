import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/send_later.dart';
import 'package:zen/src/features/chat/scheduled_messages.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// "Wyślij później" in one place: every waiting message with where it goes
// and when; its text and time can be changed, or it is taken back. The
// chats list shows how many wait.
const String _ola = '200:1111:2222:3333:4444:5555:6666:7777';

Widget _app(ScheduledMessagesService scheduled, Widget home) => ProviderScope(
  overrides: [
    scheduledMessagesProvider.overrideWithValue(scheduled),
    signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
    socialSnapshotStoreProvider.overrideWithValue(MemorySocialSnapshotStore()),
    messageTimelineStoreProvider.overrideWithValue(
      MemoryMessageTimelineStore(),
    ),
    runtimeSystemNotificationServiceProvider.overrideWithValue(
      MemoryRuntimeSystemNotificationService(),
    ),
    signalTransportProvider.overrideWithValue(MemorySignalTransport()),
    socialHubSeedProvider.overrideWithValue(
      SocialHubState.empty().copyWith(
        book: FriendshipBook.restore(
          profiles: const <String, FriendProfile>{
            _ola: FriendProfile(
              address: _ola,
              displayName: 'Ola',
              status: FriendRelationshipStatus.accepted,
            ),
          },
        ),
        groups: const <String, GroupProfile>{
          'g1': GroupProfile(
            id: 'g1',
            name: 'Ekipa',
            createdById: 'self',
            createdAtMillis: 1,
            memberAddresses: <String>[_ola],
          ),
        },
      ),
    ),
  ],
  child: MaterialApp(
    theme: ZenTheme.light(),
    home: Scaffold(body: home),
  ),
);

void main() {
  testWidgets('every waiting message, where it goes and when; changed and '
      'taken back from the list', (WidgetTester tester) async {
    final ScheduledMessagesService scheduled = ScheduledMessagesService(
      disk: MemoryLedgerDisk(),
      send: (String to, String text) async {},
    );
    final int at = DateTime(2030, 1, 2, 20).millisecondsSinceEpoch;
    late final ScheduledMessage toGroup;
    await tester.runAsync(() async {
      await scheduled.schedule(to: _ola, text: 'Kupisz chleb?', atMillis: at);
      toGroup = (await scheduled.schedule(
        to: 'group:g1',
        text: 'Gramy <@0>',
        atMillis: at + 60000,
        mentions: const <Mention>[Mention(address: _ola, name: 'Ola')],
      ))!;
    });
    await tester.pumpWidget(_app(scheduled, const ScheduledMessagesScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Kupisz chleb?'), findsOneWidget);
    expect(find.text('Do: Ola · 02.01 20:00'), findsOneWidget);
    expect(find.text('Gramy @Ola'), findsOneWidget);
    expect(find.text('Do: Ekipa · 02.01 20:01'), findsOneWidget);

    // A text with a mention is kept as written; the other one is changed.
    await tester.tap(find.byKey(Key('scheduled-menu-${toGroup.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scheduled-edit')), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    final ScheduledMessage toOla = scheduled.waiting(_ola).single;
    await tester.tap(find.byKey(Key('scheduled-menu-${toOla.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduled-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('scheduled-edit-field')),
      'Kupisz mleko?',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('scheduled-edit-save')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Kupisz mleko?'), findsOneWidget);
    expect(scheduled.waiting(_ola).single.text, 'Kupisz mleko?');

    await tester.tap(find.byKey(Key('scheduled-menu-${toOla.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduled-cancel')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(scheduled.waiting(), hasLength(1));
    expect(find.text('Kupisz mleko?'), findsNothing);
  });

  testWidgets('the chats list counts what waits; nothing while none does', (
    WidgetTester tester,
  ) async {
    final ScheduledMessagesService scheduled = ScheduledMessagesService(
      disk: MemoryLedgerDisk(),
      send: (String to, String text) async {},
    );
    await tester.runAsync(scheduled.load);
    await tester.pumpWidget(_app(scheduled, const ScheduledMessagesCard()));
    await tester.pump();
    expect(find.byKey(const Key('chats-scheduled')), findsNothing);
    await tester.runAsync(() async {
      await scheduled.schedule(to: _ola, text: 'a', atMillis: 1 << 50);
      await scheduled.schedule(to: 'group:g1', text: 'b', atMillis: 1 << 50);
    });
    await tester.pump();
    expect(find.text('2 zaplanowane wiadomości'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chats-scheduled')));
    await tester.pumpAndSettle();
    expect(find.byType(ScheduledMessagesScreen), findsOneWidget);
    scheduled.stop();
  });

  testWidgets('nothing waiting: the screen says how to schedule', (
    WidgetTester tester,
  ) async {
    final ScheduledMessagesService scheduled = ScheduledMessagesService(
      disk: MemoryLedgerDisk(),
      send: (String to, String text) async {},
    );
    await tester.runAsync(scheduled.load);
    await tester.pumpWidget(_app(scheduled, const ScheduledMessagesScreen()));
    await tester.pump();
    expect(find.byKey(const Key('scheduled-empty')), findsOneWidget);
  });
  testWidgets('in a group, holding send schedules the text for the group', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final ScheduledMessagesService scheduled = ScheduledMessagesService(
      disk: MemoryLedgerDisk(),
      send: (String to, String text) async {},
    );
    await tester.pumpWidget(
      _app(
        scheduled,
        const GroupConversationScreen(groupId: 'g1', groupName: 'Ekipa'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-chat-composer-field')),
      'Jutro o 18?',
    );
    await tester.pump();
    await tester.longPress(find.byKey(const Key('group-chat-send-button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-hour')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final ScheduledMessage m = scheduled.waiting('group:g1').single;
    expect(m.text, 'Jutro o 18?');
    expect(m.groupId, 'g1');
    final TextField field = tester.widget<TextField>(
      find.byKey(const Key('group-chat-composer-field')),
    );
    expect(field.controller!.text, isEmpty);
    scheduled.stop();
  });
}
