import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/runtime_lifecycle_bridge.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const Key _bell = Key('status-notices');
const Key _count = Key('status-notices-count');

const FriendProfile _ada = FriendProfile(
  address: 'ada.ygg',
  displayName: 'Ada',
  status: FriendRelationshipStatus.accepted,
  unreadCount: 2,
);

InboxEntry _entry(
  String id,
  InboxEntryType type, {
  int millis = 1000,
  String? routeKey,
  String title = 'Tytuł',
  String body = '',
}) {
  return InboxEntry(
    id: id,
    type: type,
    title: title,
    body: body,
    createdAtMillis: millis,
    routeKey: routeKey,
    peerAddress: 'ada.ygg',
  );
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  List<InboxEntry> inbox = const <InboxEntry>[],
  List<InboxEntry> alerts = const <InboxEntry>[],
  FriendProfile friend = _ada,
  AppSecurityService? security,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        runtimeLifecycleBindingEnabledProvider.overrideWithValue(false),
        if (security != null)
          appSecurityServiceProvider.overrideWithValue(security),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            friends: <String, FriendProfile>{friend.address: friend},
            inbox: inbox,
            backgroundAlerts: alerts,
          ),
        ),
      ],
      child: const ZenRewriteApp(),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(AppShellScreen)));
}

String? _countText(WidgetTester tester) {
  final Finder count = find.byKey(_count);
  return count.evaluate().isEmpty ? null : tester.widget<Text>(count).data;
}

Finder _keyStartingWith(String prefix) => find.byWidgetPredicate(
  (Widget w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(prefix),
);

void main() {
  testWidgets('the bell counts what is new and opening the list resets it', (
    WidgetTester tester,
  ) async {
    await _pumpApp(
      tester,
      alerts: <InboxEntry>[
        _entry(
          'message-2000-ada.ygg',
          InboxEntryType.message,
          millis: 2000,
          routeKey: 'zen://chat/ada.ygg?title=Ada',
          title: 'Nowa wiadomość od Ada',
          body: 'Cześć!',
        ),
      ],
      inbox: <InboxEntry>[
        _entry(
          'accept-ada',
          InboxEntryType.friendAccepted,
          millis: 1000,
          routeKey: 'zen://inbox',
          title: 'Ada zaakceptował(a) zaproszenie',
        ),
      ],
    );

    expect(_countText(tester), '2');
    // The chats list no longer carries the alert banner or the plain cards.
    expect(find.text('Ada zaakceptował(a) zaproszenie'), findsNothing);

    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifications-screen')), findsOneWidget);
    // Newest first, what was new is marked.
    expect(
      tester.getTopLeft(find.text('Nowa wiadomość od Ada')).dy,
      lessThan(
        tester.getTopLeft(find.text('Ada zaakceptował(a) zaproszenie')).dy,
      ),
    );
    expect(_keyStartingWith('notice-new-'), findsNWidgets(2));
    // The message's own text is shown (the list is inside the unlocked app).
    expect(find.text('Cześć!'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(_countText(tester), isNull);

    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();
    expect(find.text('Cześć!'), findsOneWidget);
    expect(_keyStartingWith('notice-new-'), findsNothing);
  });

  testWidgets('only a newer entry counts after the list was seen', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await _pumpApp(
      tester,
      inbox: <InboxEntry>[
        _entry('a', InboxEntryType.friendAccepted, millis: 1000),
      ],
    );
    await container
        .read(appSettingsControllerProvider.notifier)
        .markNotificationsSeen(1000);
    await tester.pumpAndSettle();
    expect(_countText(tester), isNull);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.friendRequest,
            sender: 'bob.ygg',
            displayName: 'Bob',
          ),
          receivedAtMillis: 5000,
        );
    await tester.pumpAndSettle();
    expect(_countText(tester), '1');
  });

  testWidgets('a read chat is not listed and a chat is one row', (
    WidgetTester tester,
  ) async {
    const String route = 'zen://chat/ada.ygg?title=Ada';
    await _pumpApp(
      tester,
      inbox: <InboxEntry>[
        _entry(
          'message-3000-ada.ygg',
          InboxEntryType.message,
          millis: 3000,
          routeKey: route,
          title: 'Nowa wiadomość od Ada',
          body: 'trzecia',
        ),
        _entry(
          'message-2000-ada.ygg',
          InboxEntryType.message,
          millis: 2000,
          routeKey: route,
          title: 'Nowa wiadomość od Ada',
          body: 'druga',
        ),
        // Receipts and the like have nowhere to go.
        _entry('junk', InboxEntryType.message, millis: 4000),
      ],
    );

    expect(_countText(tester), '1');
    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();
    expect(find.text('trzecia'), findsOneWidget);
    expect(find.text('druga'), findsNothing);
    expect(_keyStartingWith('notice-row-'), findsOneWidget);
  });

  testWidgets('a read chat leaves nothing to count', (
    WidgetTester tester,
  ) async {
    await _pumpApp(
      tester,
      friend: _ada.copyWith(unreadCount: 0),
      inbox: <InboxEntry>[
        _entry(
          'message-3000-ada.ygg',
          InboxEntryType.message,
          millis: 3000,
          routeKey: 'zen://chat/ada.ygg?title=Ada',
        ),
      ],
    );
    expect(_countText(tester), isNull);
    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();
    expect(find.text('Brak powiadomień'), findsOneWidget);
  });

  testWidgets('a tap opens the entry, a swipe and the cross remove it', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await _pumpApp(
      tester,
      inbox: <InboxEntry>[
        _entry(
          'one',
          InboxEntryType.friendAccepted,
          millis: 3000,
          title: 'Pierwsze',
          routeKey: 'zen://chat/ada.ygg?title=Ada',
        ),
        _entry(
          'two',
          InboxEntryType.friendRemoved,
          millis: 2000,
          title: 'Drugie',
        ),
        _entry(
          'three',
          InboxEntryType.transferCancelled,
          millis: 1000,
          title: 'Trzecie',
        ),
      ],
    );
    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('notice-two')),
      const Offset(-700, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Drugie'), findsNothing);
    // Hidden at once, gone from the inbox when the time for "Cofnij" is up.
    expect(find.byKey(const Key('notifications-undo-action')), findsOneWidget);
    List<String> inboxIds() => container
        .read(socialHubControllerProvider)
        .inbox
        .map((InboxEntry e) => e.id)
        .toList();
    expect(inboxIds(), <String>['one', 'two', 'three']);
    await tester.pump(const Duration(seconds: 6));
    expect(inboxIds(), <String>['one', 'three']);

    await tester.tap(find.byKey(const Key('notice-dismiss-three')));
    await tester.pumpAndSettle();
    expect(find.text('Trzecie'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(inboxIds(), <String>['one']);

    await tester.tap(find.text('Pierwsze'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifications-screen')), findsNothing);
    expect(
      find.byKey(const Key('conversation-composer-field')),
      findsOneWidget,
    );
  });

  testWidgets('a day folds away and "Wyczyść wszystko" empties the list', (
    WidgetTester tester,
  ) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int yesterday = now - const Duration(days: 1).inMilliseconds;
    final ProviderContainer container = await _pumpApp(
      tester,
      inbox: <InboxEntry>[
        _entry('today', InboxEntryType.friendAccepted, millis: now, title: 'A'),
        _entry(
          'yesterday',
          InboxEntryType.friendRemoved,
          millis: yesterday,
          title: 'B',
        ),
      ],
    );
    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();

    expect(find.text('Dziś (1)'), findsOneWidget);
    expect(find.text('Wczoraj (1)'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);

    await tester.tap(find.text('Dziś (1)'));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsOneWidget);

    await tester.tap(find.byKey(const Key('notifications-clear-all')));
    await tester.pumpAndSettle();
    expect(find.text('Brak powiadomień'), findsOneWidget);
    // "Cofnij" brings everything back; left alone, it is cleared for good.
    await tester.tap(find.byKey(const Key('notifications-undo-action')));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(container.read(socialHubControllerProvider).inbox, hasLength(2));

    await tester.tap(find.byKey(const Key('notifications-clear-all')));
    await tester.pumpAndSettle();
    expect(find.text('Brak powiadomień'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(container.read(socialHubControllerProvider).inbox, isEmpty);
  });

  testWidgets('every button of the top bar has a 44 px hit box on the '
      'smallest phone, with "Mój kod" and the status in view', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    await _pumpApp(
      tester,
      security: MemoryAppSecurityService(
        hasPassword: true,
        passwordIterations: 10,
      ),
    );
    expect(tester.takeException(), isNull);
    final List<Rect> boxes = <Rect>[];
    for (final Key key in const <Key>[
      _bell,
      Key('status-my-code'),
      Key('side-tabs-lock'),
      Key('account-menu-button'),
    ]) {
      final Rect box = tester.getRect(find.byKey(key));
      expect(box.width, greaterThanOrEqualTo(44), reason: '$key');
      expect(box.height, greaterThanOrEqualTo(44), reason: '$key');
      expect(box.right, lessThanOrEqualTo(320), reason: '$key');
      boxes.add(box);
    }
    // No two hit boxes overlap.
    for (int i = 0; i < boxes.length; i++) {
      for (int j = i + 1; j < boxes.length; j++) {
        expect(boxes[i].overlaps(boxes[j]), isFalse, reason: '$i / $j');
      }
    }
    // The status still has room, and there is exactly one bell (the wall
    // has none of its own).
    expect(find.byKey(const Key('chats-status-chip')), findsOneWidget);
    expect(find.byKey(const Key('status-health')), findsNothing);
    expect(find.byKey(const Key('feed-notices')), findsNothing);
    expect(find.byKey(_bell), findsOneWidget);
  });

  testWidgets('the top bar and the list fit the smallest phone', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    await _pumpApp(
      tester,
      // With a password, so the lock button takes its place in the bar, and
      // a long text in the list.
      security: MemoryAppSecurityService(
        hasPassword: true,
        passwordIterations: 10,
      ),
      inbox: <InboxEntry>[
        _entry(
          'long',
          InboxEntryType.friendAccepted,
          title:
              'Bardzo długi tytuł powiadomienia, który nie mieści się w jednej linii',
          body:
              'Jeszcze dłuższa treść, która też musi się zawinąć i obciąć, '
              'zamiast wypchnąć coś poza ekran na małym telefonie.',
          routeKey: 'zen://inbox',
        ),
      ],
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(_bell), findsOneWidget);
    expect(find.byKey(const Key('status-my-code')), findsOneWidget);
    expect(find.byKey(const Key('side-tabs-lock')), findsOneWidget);
    // The unread-chats text leaves the room to the status label (the bell
    // counts the chats too); a wide window keeps it.
    expect(find.text('2 nowe'), findsNothing);
    // Every button of the bar is on screen.
    for (final Key key in const <Key>[
      _bell,
      Key('status-my-code'),
      Key('side-tabs-lock'),
      Key('account-menu-button'),
    ]) {
      final Rect box = tester.getRect(find.byKey(key));
      expect(box.right, lessThanOrEqualTo(320), reason: '$key');
      expect(box.left, greaterThanOrEqualTo(0), reason: '$key');
    }

    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('notifications-clear-all')), findsOneWidget);
  });

  testWidgets('a wide window keeps the unread-chats text next to the bell', (
    WidgetTester tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    await _pumpApp(tester);
    expect(find.text('2 nowe'), findsOneWidget);
    expect(find.byKey(_bell), findsOneWidget);
  });

  test('the seen mark survives a round trip and is kept in the settings', () {
    const AppSettings settings = AppSettings(notificationsSeenMillis: 42);
    expect(AppSettings.fromJson(settings.toJson()).notificationsSeenMillis, 42);
    expect(
      const AppSettings().toJson().containsKey('notificationsSeenMillis'),
      isFalse,
    );
  });
}
