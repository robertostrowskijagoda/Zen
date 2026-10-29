import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_deep_link_bridge.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/shell/shell_location.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const String _ada = 'ada.ygg';
const String _bob = 'bob.ygg';
const String _groupId = 'grp-1';

/// No link opens the app.
final class _NoLinks implements DeepLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get linkStream => const Stream<Uri>.empty();
}

/// The disk that counts how often the stored place is read.
final class _SpyDisk implements LedgerDisk {
  final MemoryLedgerDisk _inner = MemoryLedgerDisk();
  int placeReads = 0;

  @override
  Future<Uint8List?> read(String key) {
    if (key == ShellLocationController.key) {
      placeReads += 1;
    }
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, Uint8List data) => _inner.write(key, data);

  @override
  Future<void> delete(String key) => _inner.delete(key);
}

/// A thread whose bubbles differ in height (every third one is long), so
/// that a pixel offset and a message anchor part ways.
List<ChatMessage> _thread(String sender, {int count = 60}) => <ChatMessage>[
  for (int i = 0; i < count; i++)
    ChatMessage(
      id: 'm$i',
      sender: i.isEven ? sender : 'self',
      text:
          'Wiadomość $i.'
          '${i % 3 == 0 ? ' Dłuższy tekst, który zajmuje kilka wierszy. ' * 5 : ''}',
      sentAtMillis: 1700000000000 + i * 60000,
      direction: i.isEven
          ? ChatMessageDirection.incoming
          : ChatMessageDirection.outgoing,
    ),
];

SocialHubState _social({RuntimeRouteIntent? launch, int friends = 1}) {
  return SocialHubState.empty().copyWith(
    book: FriendshipBook.restore(
      profiles: <String, FriendProfile>{
        _ada: const FriendProfile(
          address: _ada,
          displayName: 'Ada',
          status: FriendRelationshipStatus.accepted,
        ),
        _bob: const FriendProfile(
          address: _bob,
          displayName: 'Bob',
          status: FriendRelationshipStatus.accepted,
        ),
        // Enough people for the chat list to scroll.
        for (int i = 0; i < friends; i++)
          'f$i.ygg': FriendProfile(
            address: 'f$i.ygg',
            displayName: 'Znajomy $i',
            status: FriendRelationshipStatus.accepted,
          ),
      },
    ),
    groups: const <String, GroupProfile>{
      _groupId: GroupProfile(
        id: _groupId,
        name: 'Gildia Zen',
        createdById: 'self',
        createdAtMillis: 1000,
        memberAddresses: <String>[_ada],
      ),
    },
    pendingLaunchIntent: launch,
  );
}

MemoryMessageTimelineStore _timeline() =>
    MemoryMessageTimelineStore(<String, List<ChatMessage>>{
      _ada: _thread(_ada),
      _bob: _thread(_bob, count: 3),
      'group:$_groupId': _thread(_ada),
    });

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The whole app, the way a launch builds it. [disk] is the account's
/// store: opening the app again means pumping again with the same one.
Future<void> _launch(
  WidgetTester tester, {
  required LedgerDisk disk,
  MemoryMessageTimelineStore? timeline,
  RuntimeRouteIntent? launch,
  AppSecurityService? security,
  int friends = 1,
}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deepLinkSourceProvider.overrideWithValue(_NoLinks()),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          _social(launch: launch, friends: friends),
        ),
        messageTimelineStoreProvider.overrideWithValue(timeline ?? _timeline()),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ledgerNodeEnabledProvider.overrideWithValue(true),
        ledgerDiskProvider.overrideWithValue(disk),
        if (security != null)
          appSecurityServiceProvider.overrideWithValue(security),
      ],
      child: const ZenRewriteApp(),
    ),
  );
  await tester.runAsync(_settle);
  await _frames(tester);
}

/// Frames for a restore that waits for the list to be built.
Future<void> _frames(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The app is closed: the tree goes away, the account's disk stays.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(_settle);
}

/// Long enough for the place to be written (it is written a moment after
/// the last change).
Future<void> _rest(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(_settle);
}

Finder _list(Type screen) => find
    .descendant(of: find.byType(screen), matching: find.byType(ListView))
    .first;

/// The bubbles that are on screen: their number, and where they sit.
Map<int, double> _visible(WidgetTester tester, Type screen, {int count = 60}) {
  final Rect list = tester.getRect(_list(screen));
  final Map<int, double> seen = <int, double>{};
  for (int i = 0; i < count; i++) {
    final Finder bubble = find.textContaining('Wiadomość $i.');
    if (bubble.evaluate().length != 1) {
      continue;
    }
    final Rect r = tester.getRect(bubble);
    if (r.bottom > list.top && r.top < list.bottom) {
      seen[i] = r.top;
    }
  }
  return seen;
}

void _expectSameBubbles(Map<int, double> now, Map<int, double> before) {
  expect(before, isNotEmpty);
  expect(now.keys.toSet(), before.keys.toSet());
  for (final int i in before.keys) {
    expect(now[i], closeTo(before[i]!, 2), reason: 'bubble $i');
  }
}

/// The back button of the open page.
void _back() => zenRootNavigatorKey.currentState!.pop();

Future<void> _openConversation(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('conversation-card-$_ada')));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _openGroup(WidgetTester tester) async {
  await tester.tap(find.text('Gildia Zen'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('the stored place', () {
    test('keeps ids and offsets only, and reads them back', () {
      const ShellLocation place = ShellLocation(
        tab: 'chats',
        tabScroll: 120.5,
        place: ShellPlace.peerChat(_ada),
        memory: PlaceMemory(anchor: ChatAnchor('m12', -30)),
      );
      final String stored = String.fromCharCodes(place.encode());
      // What the screens show is not in it.
      expect(stored, isNot(contains('Wiadomość')));
      expect(stored, isNot(contains('Ada')));

      final ShellLocation back = ShellLocation.decode(place.encode())!;
      expect(back.tab, 'chats');
      expect(back.tabScroll, 120.5);
      expect(back.place, const ShellPlace.peerChat(_ada));
      expect(back.memory.anchor, const ChatAnchor('m12', -30));
    });

    test('a record that is not one is no place', () {
      for (final String bad in <String>['', 'x', '[]', '{}', '{"tab":""}']) {
        expect(
          ShellLocation.decode(Uint8List.fromList(bad.codeUnits)),
          isNull,
          reason: bad,
        );
      }
      final ShellLocation odd = ShellLocation.decode(
        Uint8List.fromList(
          '{"tab":"feed","tabScroll":-5,"place":{"kind":3},"anchor":{"id":1}}'
              .codeUnits,
        ),
      )!;
      expect(odd.tab, 'feed');
      expect(odd.tabScroll, 0);
      expect(odd.place, isNull);
      expect(odd.memory.anchor, isNull);
    });

    test('the first tab is no change, a tab is', () {
      final ShellLocationController c = ShellLocationController(
        MemoryLedgerDisk(),
      );
      addTearDown(c.dispose);
      c.startOn('chats');
      expect(c.changeCount, 0);
      c.selectTab('feed');
      expect(c.changeCount, 1);
      c.selectTab('feed');
      expect(c.changeCount, 1);
      expect(c.current.tab, 'feed');
    });
  });

  testWidgets('the app opens on the tab it was closed on', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await _launch(tester, disk: disk);
    expect(find.byKey(const Key('side-tab-label-chats')), findsOneWidget);
    await tester.tap(find.byKey(const Key('side-tab-films')));
    await tester.pump(const Duration(milliseconds: 300));
    await _rest(tester);
    await _close(tester);

    await _launch(tester, disk: disk);
    expect(find.byKey(const Key('side-tab-label-films')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-label-chats')), findsNothing);
    await _close(tester);
  });

  testWidgets('the tab is kept when the app is sent away at once, '
      'before the delay of the write is over', (WidgetTester tester) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await _launch(tester, disk: disk);
    await tester.tap(find.byKey(const Key('side-tab-wallet')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(disk.files.containsKey(ShellLocationController.key), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(disk.files.containsKey(ShellLocationController.key), isTrue);
    await _close(tester);
    // The next launch is a fresh process: its frames are on again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await _launch(tester, disk: disk);
    expect(find.byKey(const Key('side-tab-label-wallet')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('the list of the tab is scrolled as it was', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await _launch(tester, disk: disk, friends: 40);
    final Finder body = find.byKey(const Key('chats-tab-body'));
    await tester.drag(body, const Offset(0, -700));
    await tester.pumpAndSettle();
    double offset() => tester
        .state<ScrollableState>(
          find.descendant(of: body, matching: find.byType(Scrollable)).first,
        )
        .position
        .pixels;
    final double before = offset();
    expect(before, greaterThan(300));
    await _rest(tester);
    await _close(tester);

    await _launch(tester, disk: disk, friends: 40);
    expect(offset(), closeTo(before, 1));
    await _close(tester);
  });

  testWidgets('an open conversation is open again, at the same message', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final MemoryMessageTimelineStore timeline = _timeline();
    await _launch(tester, disk: disk, timeline: timeline);
    await _openConversation(tester);
    expect(find.byType(ConversationScreen), findsOneWidget);
    // Up into the older messages.
    // (The first drag only takes the list back from where the jump to the
    // end left it.)
    await tester.drag(_list(ConversationScreen), const Offset(0, 900));
    await tester.pumpAndSettle();
    await tester.drag(_list(ConversationScreen), const Offset(0, 900));
    await tester.pumpAndSettle();
    final Map<int, double> before = _visible(tester, ConversationScreen);
    expect(before.keys.reduce((int a, int b) => a > b ? a : b), lessThan(55));
    await _rest(tester);
    await _close(tester);

    await _launch(tester, disk: disk, timeline: timeline);
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(find.text('Ada'), findsWidgets);
    _expectSameBubbles(_visible(tester, ConversationScreen), before);

    // Back: the list of the chats, as the user would find it.
    _back();
    await _frames(tester);
    expect(find.byType(ConversationScreen), findsNothing);
    expect(find.byKey(const Key('conversation-card-$_ada')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('a conversation left at its latest message opens there, '
      'new messages included', (WidgetTester tester) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final MemoryMessageTimelineStore timeline = _timeline();
    await _launch(tester, disk: disk, timeline: timeline);
    await _openConversation(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Wiadomość 59.'), findsOneWidget);
    // Scrolled and brought back to the end: the end is what is kept.
    await tester.drag(_list(ConversationScreen), const Offset(0, 500));
    await tester.pumpAndSettle();
    await tester.drag(_list(ConversationScreen), const Offset(0, -2000));
    await tester.pumpAndSettle();
    await _rest(tester);
    await _close(tester);

    await timeline.append(
      _ada,
      const ChatMessage(
        id: 'm100',
        sender: _ada,
        text: 'Wiadomość 100.',
        sentAtMillis: 1800000000000,
        direction: ChatMessageDirection.incoming,
      ),
    );
    await _launch(tester, disk: disk, timeline: timeline);
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(find.textContaining('Wiadomość 100.'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('an open group is open again, at the same message '
      '(the list is reversed)', (WidgetTester tester) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final MemoryMessageTimelineStore timeline = _timeline();
    await _launch(tester, disk: disk, timeline: timeline);
    await _openGroup(tester);
    expect(find.byType(GroupConversationScreen), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.drag(_list(GroupConversationScreen), const Offset(0, 900));
    await tester.pumpAndSettle();
    final Map<int, double> before = _visible(tester, GroupConversationScreen);
    expect(before.keys.reduce((int a, int b) => a > b ? a : b), lessThan(55));
    await _rest(tester);
    await _close(tester);

    await _launch(tester, disk: disk, timeline: timeline);
    expect(find.byType(GroupConversationScreen), findsOneWidget);
    _expectSameBubbles(_visible(tester, GroupConversationScreen), before);
    await _close(tester);
  });

  testWidgets('the settings are open again, scrolled as they were', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await _launch(tester, disk: disk);
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final Finder body = find.byKey(const Key('settings-tab-body'));
    expect(body, findsOneWidget);
    await tester.drag(body, const Offset(0, -400));
    await tester.pumpAndSettle();
    double offset() => tester
        .state<ScrollableState>(
          find.descendant(of: body, matching: find.byType(Scrollable)).first,
        )
        .position
        .pixels;
    final double before = offset();
    expect(before, greaterThan(100));
    await _rest(tester);
    await _close(tester);

    await _launch(tester, disk: disk);
    expect(find.byKey(const Key('settings-tab-body')), findsOneWidget);
    expect(offset(), closeTo(before, 1));
    _back();
    await _frames(tester);
    expect(find.byKey(const Key('settings-tab-body')), findsNothing);
    await _close(tester);
  });

  testWidgets('a page that was closed by the user is not opened again', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await _launch(tester, disk: disk);
    await _openConversation(tester);
    _back();
    await _frames(tester);
    await _rest(tester);
    await _close(tester);

    await _launch(tester, disk: disk);
    expect(find.byType(ConversationScreen), findsNothing);
    expect(find.byKey(const Key('conversation-card-$_ada')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('a conversation or a group that is gone leaves the tab', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      ShellLocationController.key,
      const ShellLocation(
        tab: 'films',
        place: ShellPlace.peerChat('ghost.ygg'),
      ).encode(),
    );
    await _launch(tester, disk: disk);
    expect(find.byType(ConversationScreen), findsNothing);
    expect(find.byKey(const Key('side-tab-label-films')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);

    await disk.write(
      ShellLocationController.key,
      const ShellLocation(
        tab: 'wallet',
        place: ShellPlace.groupChat('left-group'),
      ).encode(),
    );
    await _launch(tester, disk: disk);
    expect(find.byType(GroupConversationScreen), findsNothing);
    expect(find.byKey(const Key('side-tab-label-wallet')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);

    // Neither a place of a kind nobody knows, nor a tab the rail lacks.
    await disk.write(
      ShellLocationController.key,
      const ShellLocation(
        tab: 'no-such-tab',
        place: ShellPlace('no-such-kind', 'x'),
      ).encode(),
    );
    await _launch(tester, disk: disk);
    expect(find.byKey(const Key('side-tab-label-chats')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('another account has a place of its own', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk first = MemoryLedgerDisk();
    await _launch(tester, disk: first);
    await tester.tap(find.byKey(const Key('side-tab-films')));
    await tester.pump(const Duration(milliseconds: 300));
    await _rest(tester);
    await _close(tester);

    // The other account's store never held one.
    await _launch(tester, disk: MemoryLedgerDisk());
    expect(find.byKey(const Key('side-tab-label-chats')), findsOneWidget);
    await _close(tester);
    await _launch(tester, disk: first);
    expect(find.byKey(const Key('side-tab-label-films')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('a notification opens its screen, not the one that was open', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      ShellLocationController.key,
      const ShellLocation(
        tab: 'films',
        place: ShellPlace.peerChat(_ada),
      ).encode(),
    );
    await _launch(
      tester,
      disk: disk,
      launch: RuntimeRouteIntent.conversation(id: 'n1', peerAddress: _bob),
    );
    await _frames(tester);
    final Finder screens = find.byType(ConversationScreen, skipOffstage: false);
    expect(screens, findsOneWidget);
    expect(
      tester.widget<ConversationScreen>(screens).peerAddress,
      _bob,
      reason: 'the notification, and nothing under it',
    );
    // The tab is the start tab too: the stored place is dropped whole.
    expect(find.byKey(const Key('side-tab-label-films')), findsNothing);
    await _close(tester);
  });

  testWidgets('what the user did before the restore was ready is kept', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      ShellLocationController.key,
      const ShellLocation(tab: 'films').encode(),
    );
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deepLinkSourceProvider.overrideWithValue(_NoLinks()),
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(_social()),
          messageTimelineStoreProvider.overrideWithValue(_timeline()),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(disk),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    // Before the stored place could be read.
    await tester.tap(find.byKey(const Key('side-tab-feed')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(_settle);
    await _frames(tester);
    expect(find.byKey(const Key('side-tab-label-feed')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-label-films')), findsNothing);
    await _close(tester);
  });

  testWidgets('after the lock, nothing is read or shown before the unlock', (
    WidgetTester tester,
  ) async {
    final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
      const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 9,
      ),
    );
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
    );
    await security.initialize(
      settings: const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 9,
      ),
    );
    await security.setPassword('sekret12');
    final _SpyDisk disk = _SpyDisk();
    await disk.write(
      ShellLocationController.key,
      const ShellLocation(
        tab: 'films',
        place: ShellPlace.peerChat(_ada),
      ).encode(),
    );
    // The app was closed with a conversation open; it starts locked.
    security.lock();
    expect(security.isLocked, isTrue);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(settingsStore),
          appSecurityServiceProvider.overrideWithValue(security),
          deepLinkSourceProvider.overrideWithValue(_NoLinks()),
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(_social()),
          messageTimelineStoreProvider.overrideWithValue(_timeline()),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(disk),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.runAsync(_settle);
    await _frames(tester);

    expect(find.byKey(const Key('app-unlock-password-field')), findsOneWidget);
    expect(find.byKey(const Key('tabbed-shell')), findsNothing);
    expect(find.byType(ConversationScreen, skipOffstage: false), findsNothing);
    expect(find.textContaining('Wiadomość'), findsNothing);
    expect(disk.placeReads, 0, reason: 'the store is not touched while locked');

    await tester.enterText(
      find.byKey(const Key('app-unlock-password-field')),
      'sekret12',
    );
    await tester.tap(find.byKey(const Key('app-unlock-submit-button')));
    await tester.pump();
    await tester.runAsync(_settle);
    await _frames(tester);

    expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);
    expect(disk.placeReads, 1);
    expect(find.byType(ConversationScreen), findsOneWidget);
    _back();
    await _frames(tester);
    expect(find.byKey(const Key('side-tab-label-films')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('locked while open, the app comes back to the same page', (
    WidgetTester tester,
  ) async {
    final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
      const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 9,
      ),
    );
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
    );
    await security.initialize(
      settings: const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 9,
      ),
    );
    await security.setPassword('sekret12');
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(settingsStore),
          appSecurityServiceProvider.overrideWithValue(security),
          deepLinkSourceProvider.overrideWithValue(_NoLinks()),
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(_social()),
          messageTimelineStoreProvider.overrideWithValue(_timeline()),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.runAsync(_settle);
    await _frames(tester);
    await tester.tap(find.byKey(const Key('side-tab-films')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('side-tab-chats')));
    await tester.pump(const Duration(milliseconds: 300));
    await _openConversation(tester);
    expect(find.byType(ConversationScreen), findsOneWidget);

    // Locking takes the whole navigator down; unlocking builds it again.
    security.lock();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('app-unlock-password-field')), findsOneWidget);
    expect(find.byType(ConversationScreen, skipOffstage: false), findsNothing);
    await tester.enterText(
      find.byKey(const Key('app-unlock-password-field')),
      'sekret12',
    );
    await tester.tap(find.byKey(const Key('app-unlock-submit-button')));
    await tester.pump();
    await tester.runAsync(_settle);
    await _frames(tester);

    expect(find.byType(ConversationScreen), findsOneWidget);
    _back();
    await _frames(tester);
    expect(find.byKey(const Key('side-tab-label-chats')), findsOneWidget);
    await _close(tester);
  });
}
