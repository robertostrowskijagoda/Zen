import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Mentions in a group chat: only the group's members are mentioned, the
// person mentioned is told so (once per message, at the conversation's
// privacy level, within a limit per sender), with an entry that opens the
// chat at that message.

const String _self = 'me.ygg';
const String _ada = 'ada.ygg';
const String _bob = 'bob.ygg';
const String _carol = 'carol.ygg';
const String _groupId = 'grp-1';

const Mention _me = Mention(address: _self, name: 'Ja');
const Mention _bobM = Mention(address: _bob, name: 'Bob');

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);

ZenSignal _message(
  String id, {
  String sender = _ada,
  String text = 'Hej <@0>',
  List<Mention> mentions = const <Mention>[_me],
}) => ZenSignal(
  type: ZenSignalType.groupMessage,
  sender: sender,
  displayName: sender == _ada ? 'Ada' : 'Karol',
  groupId: _groupId,
  groupName: 'Ekipa',
  messageId: id,
  content: text,
  chatExtras: <String, dynamic>{kMentionsKey: mentionsToJson(mentions)},
);

Future<
  ({ProviderContainer container, MemoryRuntimeSystemNotificationService shade})
>
_boot({
  NotificationPrivacy global = NotificationPrivacy.senderAndContent,
  MemoryMessageTimelineStore? timelines,
}) async {
  final MemoryRuntimeSystemNotificationService shade =
      MemoryRuntimeSystemNotificationService();
  // The node up, so the hub knows this device's own address.
  final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
    bootstrap: () async => RuntimeNodeSession(
      transport: MemorySignalTransport(),
      snapshot: RuntimeTransportSnapshot.started(localAddress: _self, peers: 1),
    ),
  );
  late final ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      ...buildAppSettingsProviderOverrides(
        store: MemoryAppSettingsStore(),
        initialState: AppSettings(notificationPrivacy: global),
        hydrationEnabled: false,
      ),
      runtimeNodeRuntimeProvider.overrideWithValue(runtime),
      signalTransportProvider.overrideWithValue(MemorySignalTransport()),
      signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
      socialSnapshotStoreProvider.overrideWithValue(
        MemorySocialSnapshotStore(),
      ),
      messageTimelineStoreProvider.overrideWithValue(
        timelines ?? MemoryMessageTimelineStore(),
      ),
      runtimeSystemNotificationServiceProvider.overrideWithValue(
        PrivacyRedactingNotificationService(
          shade,
          privacy: () =>
              container.read(appSettingsControllerProvider).notificationPrivacy,
        ),
      ),
      socialHubSeedProvider.overrideWithValue(
        SocialHubState.empty(lifecycle: _background).copyWith(
          friends: const <String, FriendProfile>{
            _ada: FriendProfile(
              address: _ada,
              displayName: 'Ada',
              status: FriendRelationshipStatus.accepted,
            ),
          },
          groups: const <String, GroupProfile>{
            _groupId: GroupProfile(
              id: _groupId,
              name: 'Ekipa',
              createdById: _ada,
              createdAtMillis: 0,
              memberAddresses: <String>[_ada, _bob, _self],
            ),
          },
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(socialHubControllerProvider);
  await runtime.start();
  expect(container.read(runtimeNodeSnapshotProvider).localAddress, _self);
  return (container: container, shade: shade);
}

List<InboxEntry> _entries(SocialHubState s) => <InboxEntry>[
  ...s.backgroundAlerts,
  ...s.inbox,
];

void main() {
  test('a mention of this person says so, and opens the chat at the '
      'message', () async {
    final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
    final (:container, :shade) = await _boot(timelines: timelines);
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(_message('m-1'), receivedAtMillis: 1000);
    final RuntimeSystemNotification n = shade.activeNotifications.single;
    expect(n.title, 'Ekipa');
    expect(n.body, 'Ada wspomniał(a) o Tobie: Hej @Ja');
    expect(n.slotKey, 'group-mention:$_groupId');
    expect(n.category, RuntimeSystemNotificationCategory.message);

    final List<InboxEntry> entries = _entries(
      container.read(socialHubControllerProvider),
    ).where((InboxEntry e) => e.type == InboxEntryType.mention).toList();
    expect(entries, hasLength(1));
    final InboxEntry entry = entries.single;
    expect(entry.displayTitle, 'Ada wspomniał(a) o Tobie');
    expect(entry.displayBody, 'Hej @Ja');
    final RuntimeRouteIntent? route = runtimeRouteIntentFromRouteKey(
      id: entry.id,
      routeKey: entry.routeKey,
    );
    expect(route?.groupId, _groupId);
    expect(route?.messageId, 'm-1');

    // Stored with whom it names; the same message again changes nothing.
    final ChatMessage stored = (await timelines.load('group:$_groupId')).single;
    expect(stored.mentions, <Mention>[_me]);
    expect(stored.plainText, 'Hej @Ja');
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(_message('m-1'), receivedAtMillis: 2000);
    expect(shade.activeNotifications, hasLength(1));
    expect(
      _entries(
        container.read(socialHubControllerProvider),
      ).where((InboxEntry e) => e.type == InboxEntryType.mention),
      hasLength(1),
    );
  });

  test('the conversation\'s privacy level decides what it tells', () async {
    ({
      ProviderContainer container,
      MemoryRuntimeSystemNotificationService shade,
    })
    booted = await _boot(global: NotificationPrivacy.senderOnly);
    await booted.container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(_message('m-1'), receivedAtMillis: 1000);
    RuntimeSystemNotification n = booted.shade.activeNotifications.single;
    expect(n.title, 'Ekipa');
    expect(n.body, 'Ada wspomniał(a) o Tobie');

    booted = await _boot(global: NotificationPrivacy.generic);
    await booted.container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(_message('m-1'), receivedAtMillis: 1000);
    n = booted.shade.activeNotifications.single;
    expect(n.title, 'Nowa wiadomość');
    expect('${n.title} ${n.body}', isNot(contains('Ada')));
    expect('${n.title} ${n.body}', isNot(contains('Ekipa')));
  });

  test('a message mentioning someone else is an ordinary message', () async {
    final (:container, :shade) = await _boot();
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          _message('m-1', mentions: const <Mention>[_bobM]),
          receivedAtMillis: 1000,
        );
    final RuntimeSystemNotification n = shade.activeNotifications.single;
    expect(n.body, 'Ada: Hej @Bob');
    expect(n.slotKey, 'group-message:$_groupId');
    expect(
      _entries(
        container.read(socialHubControllerProvider),
      ).where((InboxEntry e) => e.type == InboxEntryType.mention),
      isEmpty,
    );
  });

  test('someone outside the group mentions nobody', () async {
    final (:container, :shade) = await _boot();
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(_message('m-1', sender: _carol), receivedAtMillis: 1000);
    expect(shade.activeNotifications, isEmpty);
    expect(_entries(container.read(socialHubControllerProvider)), isEmpty);
  });

  test(
    'one sender\'s mentions are limited; past it they are messages',
    () async {
      final (:container, :shade) = await _boot();
      final SocialHubController hub = container.read(
        socialHubControllerProvider.notifier,
      );
      for (int i = 0; i < kMaxMentionAlertsPerSender + 2; i++) {
        await hub.receiveSignal(_message('m-$i'), receivedAtMillis: 1000 + i);
      }
      expect(
        _entries(
          container.read(socialHubControllerProvider),
        ).where((InboxEntry e) => e.type == InboxEntryType.mention),
        hasLength(kMaxMentionAlertsPerSender),
      );
      expect(
        shade.activeNotifications.map(
          (RuntimeSystemNotification n) => n.slotKey,
        ),
        containsAll(<String>[
          'group-mention:$_groupId',
          'group-message:$_groupId',
        ]),
      );
    },
  );

  test('a message sent here mentions members only', () async {
    final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
    final (:container, shade: _) = await _boot(timelines: timelines);
    final SocialHubController hub = container.read(
      socialHubControllerProvider.notifier,
    );
    await hub.sendGroupMessage(
      groupId: _groupId,
      text: 'Hej <@0>',
      mentions: const <Mention>[_bobM],
    );
    await hub.sendGroupMessage(
      groupId: _groupId,
      text: 'A ty <@0>?',
      mentions: const <Mention>[Mention(address: _carol, name: 'Karol')],
    );
    final List<ChatMessage> sent = await timelines.load('group:$_groupId');
    expect(sent.first.text, 'Hej <@0>');
    expect(sent.first.mentions, <Mention>[_bobM]);
    // Karol is not in the group: a plain name.
    expect(sent.last.text, 'A ty @Karol?');
    expect(sent.last.mentions, isEmpty);
  });
}
