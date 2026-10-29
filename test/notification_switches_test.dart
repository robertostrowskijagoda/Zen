import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

// The notification switches of the settings (what is posted, what is quiet)
// and the sounds inside the app, with a player that plays nothing.

const String _ada = 'ada.ygg';
const String _groupId = 'grp-1';

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);
const LifecycleSnapshot _focused = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 1,
  capturedAtMillis: 0,
);

const GroupProfile _group = GroupProfile(
  id: _groupId,
  name: 'Ekipa',
  createdById: _ada,
  createdAtMillis: 0,
  memberAddresses: <String>[_ada, 'bob.ygg'],
);

ZenSignal _direct(String id) => ZenSignal(
  type: ZenSignalType.message,
  sender: _ada,
  displayName: 'Ada',
  messageId: id,
  content: 'Hej!',
);

ZenSignal _inGroup(String id, {bool mentionsYou = false}) => ZenSignal(
  type: ZenSignalType.groupMessage,
  sender: _ada,
  displayName: 'Ada',
  groupId: _groupId,
  groupName: 'Ekipa',
  messageId: id,
  content: 'Hej!',
  chatExtras: mentionsYou ? <String, dynamic>{kMentionsYouKey: true} : null,
);

RuntimeSystemNotification _notification(
  RuntimeSystemNotificationCategory category, {
  NoticeKind? kind,
  bool ringing = false,
}) {
  return RuntimeSystemNotification(
    id: 'n-1',
    title: 'T',
    body: 'B',
    createdAtMillis: 1,
    category: category,
    kind: kind,
    isRingingCall: ringing,
  );
}

final class _FakeHandle implements ZenSoundHandle {
  @override
  Future<void> stop() async {}
}

final class _FakeOutput implements ZenSoundOutput {
  final List<String> played = <String>[];

  @override
  Future<ZenSoundHandle?> play(String asset, {required bool loop}) async {
    played.add(asset);
    return _FakeHandle();
  }
}

/// One run of the hub with the real switches in front of a memory shade.
final class _World {
  _World(
    this.lifecycle, {
    AppSettings settings = const AppSettings(),
    TargetPlatform platform = TargetPlatform.android,
  }) {
    final DateTime start = DateTime(2026, 10, 28, 12);
    int ticks = 0;
    container = ProviderContainer(
      overrides: [
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: settings,
          hydrationEnabled: false,
        ),
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timeline),
        runtimeSystemNotificationServiceProvider.overrideWith(
          (Ref ref) => NoticeSettingsNotificationService(
            shade,
            muted: (NoticeKind kind) =>
                ref.read(appSettingsControllerProvider).mutes(kind),
            sounds: () =>
                ref.read(appSettingsControllerProvider).notificationSounds,
          ),
        ),
        zenSoundEffectsProvider.overrideWith(
          (Ref ref) => ZenSoundEffects(
            output: output,
            inAppSoundsOn: () =>
                ref.read(appSettingsControllerProvider).inAppSounds,
            notificationSoundsOn: () =>
                ref.read(appSettingsControllerProvider).notificationSounds,
            deviceKeepsQuiet: () async => false,
            platform: platform,
            // Each look at the clock is later than the last: the "same
            // sound again" guard cannot hide a second sound.
            clock: () => start.add(Duration(seconds: ticks++)),
          ),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(lifecycle: lifecycle).copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _ada: FriendProfile(
                  address: _ada,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            groups: const <String, GroupProfile>{_groupId: _group},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  final LifecycleSnapshot lifecycle;
  final MemoryRuntimeSystemNotificationService shade =
      MemoryRuntimeSystemNotificationService();
  final MemoryMessageTimelineStore timeline = MemoryMessageTimelineStore();
  final _FakeOutput output = _FakeOutput();
  late final ProviderContainer container;

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  AppSettingsController get settings =>
      container.read(appSettingsControllerProvider.notifier);

  Future<void> receive(ZenSignal signal, {int at = 1000}) async {
    await hub.receiveSignal(signal, receivedAtMillis: at);
    await pumpEventQueue();
  }
}

void main() {
  group('AppSettings', () {
    test('only the far friends\' posts are off at first', () {
      const AppSettings settings = AppSettings();
      for (final NoticeKind kind in NoticeKind.values) {
        expect(
          settings.mutes(kind),
          kind == NoticeKind.farPost,
          reason: '$kind',
        );
      }
      expect(settings.notificationSounds, isTrue);
      expect(settings.inAppSounds, isTrue);
    });

    test('the switches survive a round trip through the stored form', () {
      final AppSettings back = AppSettings.fromJson(
        const AppSettings(
          notificationSounds: false,
          postNotifications: false,
          mutedNotices: <NoticeKind>{NoticeKind.call, NoticeKind.reaction},
        ).toJson(),
      );
      expect(back.notificationSounds, isFalse);
      expect(back.mutedNotices, <NoticeKind>{
        NoticeKind.call,
        NoticeKind.reaction,
      });
      expect(back.mutes(NoticeKind.friendPost), isTrue);
      expect(back.mutes(NoticeKind.farPost), isFalse);
      expect(back.mutes(NoticeKind.message), isFalse);
    });

    test('an unknown stored kind is ignored and none stored means the '
        'default', () {
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'mutedNotices': <String>['nonsense', 'update'],
        }).mutedNotices,
        <NoticeKind>{NoticeKind.update},
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{}).mutedNotices,
        NoticeKind.defaultMuted,
      );
    });

    test('the controller switches a kind, the friends\' posts through '
        'their own flag', () async {
      final _World world = _World(_background);
      await world.settings.setNoticeMuted(NoticeKind.call, muted: true);
      await world.settings.setNoticeMuted(NoticeKind.farPost, muted: false);
      await world.settings.setNoticeMuted(NoticeKind.friendPost, muted: true);
      final AppSettings now = world.container.read(
        appSettingsControllerProvider,
      );
      expect(now.mutedNotices, <NoticeKind>{NoticeKind.call});
      expect(now.postNotifications, isFalse);
      expect(now.mutes(NoticeKind.friendPost), isTrue);
      await world.settings.setNoticeMuted(NoticeKind.friendPost, muted: false);
      expect(
        world.container.read(appSettingsControllerProvider).postNotifications,
        isTrue,
      );
      await world.settings.setNotificationSounds(false);
      expect(
        world.container.read(appSettingsControllerProvider).notificationSounds,
        isFalse,
      );
    });
  });

  group('what the switches hold back', () {
    test('calls and updates are known by their category, an alarm and '
        'the rest are never switched off', () {
      expect(
        noticeKindOf(_notification(RuntimeSystemNotificationCategory.call)),
        NoticeKind.call,
      );
      expect(
        noticeKindOf(_notification(RuntimeSystemNotificationCategory.update)),
        NoticeKind.update,
      );
      expect(
        noticeKindOf(_notification(RuntimeSystemNotificationCategory.alarm)),
        isNull,
      );
      expect(
        noticeKindOf(_notification(RuntimeSystemNotificationCategory.social)),
        isNull,
      );
      expect(
        noticeKindOf(
          _notification(
            RuntimeSystemNotificationCategory.social,
            kind: NoticeKind.reaction,
          ),
        ),
        NoticeKind.reaction,
      );
    });

    test('a kind that is off posts nothing, the others come', () async {
      final MemoryRuntimeSystemNotificationService shade =
          MemoryRuntimeSystemNotificationService();
      final NoticeSettingsNotificationService service =
          NoticeSettingsNotificationService(
            shade,
            muted: (NoticeKind kind) => kind == NoticeKind.reaction,
            sounds: () => true,
          );
      expect(
        await service.show(
          _notification(
            RuntimeSystemNotificationCategory.social,
            kind: NoticeKind.reaction,
          ),
        ),
        isFalse,
      );
      expect(shade.activeNotifications, isEmpty);
      expect(
        await service.show(
          _notification(
            RuntimeSystemNotificationCategory.social,
            kind: NoticeKind.mention,
          ),
        ),
        isTrue,
      );
      expect(shade.activeNotifications.single.silent, isFalse);
    });

    test('with the sounds off everything comes quietly, but a ringing call '
        'and an alarm do not', () async {
      final MemoryRuntimeSystemNotificationService shade =
          MemoryRuntimeSystemNotificationService();
      final NoticeSettingsNotificationService service =
          NoticeSettingsNotificationService(
            shade,
            muted: (NoticeKind kind) => false,
            sounds: () => false,
          );
      RuntimeSystemNotification posted(
        RuntimeSystemNotificationCategory category, {
        bool ringing = false,
      }) {
        final RuntimeSystemNotification n = _notification(
          category,
          ringing: ringing,
        );
        return service.apply(n)!;
      }

      expect(posted(RuntimeSystemNotificationCategory.message).silent, isTrue);
      expect(posted(RuntimeSystemNotificationCategory.social).silent, isTrue);
      expect(
        posted(RuntimeSystemNotificationCategory.call).silent,
        isTrue,
        reason: 'a missed call is an ordinary notification',
      );
      expect(
        posted(RuntimeSystemNotificationCategory.call, ringing: true).silent,
        isFalse,
      );
      expect(
        posted(RuntimeSystemNotificationCategory.alarm, ringing: true).silent,
        isFalse,
      );
      expect(posted(RuntimeSystemNotificationCategory.alarm).silent, isFalse);
    });

    test('the quiet form survives stacking and redaction', () {
      final RuntimeSystemNotification quiet = _notification(
        RuntimeSystemNotificationCategory.message,
        kind: NoticeKind.message,
      ).asSilent();
      final RuntimeSystemNotification stacked = stackRuntimeNotification(
        quiet,
        quiet,
      );
      expect(stacked.silent, isTrue);
      expect(stacked.kind, NoticeKind.message);
      expect(quiet.withRedactedBody('x').silent, isTrue);
      expect(quiet.withRedactedBody('x').kind, NoticeKind.message);
    });

    test('settings that cannot be read leave everything as it was', () async {
      final MemoryRuntimeSystemNotificationService shade =
          MemoryRuntimeSystemNotificationService();
      final NoticeSettingsNotificationService service =
          NoticeSettingsNotificationService(
            shade,
            muted: (NoticeKind kind) => throw StateError('not ready'),
            sounds: () => throw StateError('not ready'),
          );
      expect(
        await service.show(
          _notification(RuntimeSystemNotificationCategory.call, ringing: true),
        ),
        isTrue,
      );
      expect(shade.activeNotifications.single.silent, isFalse);
    });
  });

  group('through the hub, with Zen in the background', () {
    test('a message, a group message and a mention each follow their own '
        'switch', () async {
      final _World world = _World(_background);
      await world.receive(_direct('m-1'));
      expect(world.shade.activeNotifications.single.kind, NoticeKind.message);

      await world.settings.setNoticeMuted(NoticeKind.message, muted: true);
      await world.receive(_direct('m-2'), at: 200000);
      // Nothing new: the first one is all that is in the shade.
      expect(world.shade.activeNotifications.single.stackCount, 1);

      await world.receive(_inGroup('g-1'), at: 300000);
      expect(world.shade.activeNotifications, hasLength(2));
      expect(
        world.shade.activeNotifications.map(noticeKindOf),
        contains(NoticeKind.groupMessage),
      );

      await world.settings.setNoticeMuted(NoticeKind.groupMessage, muted: true);
      await world.receive(_inGroup('g-2'), at: 400000);
      expect(world.shade.activeNotifications, hasLength(2));

      // A mention in the muted group still comes: it has its own switch.
      await world.receive(_inGroup('g-3', mentionsYou: true), at: 500000);
      expect(
        world.shade.activeNotifications.map(noticeKindOf),
        contains(NoticeKind.mention),
      );
      await world.settings.setNoticeMuted(NoticeKind.mention, muted: true);
      final int before = world.shade.activeNotifications.length;
      await world.receive(_inGroup('g-4', mentionsYou: true), at: 600000);
      expect(world.shade.activeNotifications, hasLength(before));
    });

    test('a muted message is still in the in-app list', () async {
      final _World world = _World(_background);
      await world.settings.setNoticeMuted(NoticeKind.message, muted: true);
      await world.receive(_direct('m-1'));

      expect(world.shade.activeNotifications, isEmpty);
      // What came in the background is listed (the bell) all the same.
      final SocialHubState state = world.container.read(
        socialHubControllerProvider,
      );
      expect(
        <InboxEntry>[
          ...state.inbox,
          ...state.backgroundAlerts,
        ].where((InboxEntry e) => e.type == InboxEntryType.message),
        hasLength(1),
      );
    });

    test('a friend request is an invitation', () async {
      final _World world = _World(_background);
      await world.receive(
        const ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: 'eve.ygg',
          displayName: 'Eve',
        ),
      );
      expect(
        world.shade.activeNotifications.single.kind,
        NoticeKind.invitation,
      );

      final _World quiet = _World(
        _background,
        settings: AppSettings(
          mutedNotices: <NoticeKind>{NoticeKind.invitation},
        ),
      );
      await quiet.receive(
        const ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: 'eve.ygg',
          displayName: 'Eve',
        ),
      );
      expect(quiet.shade.activeNotifications, isEmpty);
      expect(
        quiet.container.read(socialHubControllerProvider).inbox.single.type,
        InboxEntryType.friendRequest,
      );
    });

    test(
      'with the notification sounds off a message arrives quietly',
      () async {
        final _World world = _World(
          _background,
          settings: const AppSettings(notificationSounds: false),
        );
        await world.receive(_direct('m-1'));
        expect(world.shade.activeNotifications.single.silent, isTrue);
      },
    );
  });

  group('the locked receiver\'s notice kit', () {
    test('carries the switches, sealed like the rest', () {
      final LockedNoticeKit kit = LockedNoticeKit(
        muted: <NoticeKind>{NoticeKind.groupMessage, NoticeKind.call},
        sounds: false,
      );
      final LockedNoticeKit back = LockedNoticeKit.fromJson(kit.toJson())!;
      expect(back.muted, <NoticeKind>{
        NoticeKind.groupMessage,
        NoticeKind.call,
      });
      expect(back.sounds, isFalse);
      expect(const LockedNoticeKit().toJson().containsKey('q'), isFalse);
      expect(const LockedNoticeKit().toJson().containsKey('s'), isFalse);
      expect(
        LockedNoticeKit.fromJson(const LockedNoticeKit().toJson())!.sounds,
        isTrue,
      );
    });

    test('holds back what is switched off and quietens the rest', () {
      const LockedNoticeKit kit = LockedNoticeKit(
        muted: <NoticeKind>{NoticeKind.groupMessage},
        sounds: false,
      );
      expect(
        kit.settingsApplied(
          _notification(
            RuntimeSystemNotificationCategory.message,
            kind: NoticeKind.groupMessage,
          ),
        ),
        isNull,
      );
      expect(
        kit
            .settingsApplied(
              _notification(
                RuntimeSystemNotificationCategory.message,
                kind: NoticeKind.message,
              ),
            )!
            .silent,
        isTrue,
      );
      expect(
        kit
            .settingsApplied(
              _notification(
                RuntimeSystemNotificationCategory.call,
                ringing: true,
              ),
            )!
            .silent,
        isFalse,
      );
    });

    test('tells a group message from a message by its payload', () {
      const LockedNoticeKit kit = LockedNoticeKit();
      expect(
        kit.messageKind(
          from: _ada,
          payload: <String, dynamic>{
            'type': 'group_message',
            'groupId': _groupId,
            'content': 'Hej',
            'messageId': 'g-1',
          },
        ),
        NoticeKind.groupMessage,
      );
      expect(
        kit.messageKind(
          from: _ada,
          payload: <String, dynamic>{
            'type': 'message',
            'content': 'Hej',
            'messageId': 'm-1',
          },
        ),
        NoticeKind.message,
      );
    });
  });

  group('sounds inside the app', () {
    test(
      'a message that comes into the open chat plays its own tone',
      () async {
        final _World world = _World(_focused);
        await world.hub.enterConversation(_ada);
        await world.receive(_direct('m-1'));
        expect(world.output.played, <String>['assets/sounds/zen_received.wav']);
      },
    );

    test(
      'not in a chat that is not open, nor for a copy of the message',
      () async {
        final _World world = _World(_focused);
        await world.receive(_direct('m-1'));
        expect(world.output.played, isEmpty);

        await world.hub.enterConversation(_ada);
        await world.receive(_direct('m-2'), at: 2000);
        await world.receive(_direct('m-2'), at: 3000);
        expect(world.output.played, hasLength(1));
      },
    );

    test('a message into the open group chat plays it too', () async {
      final _World world = _World(_focused);
      await world.hub.enterGroupConversation(_groupId);
      await world.receive(_inGroup('g-1'));
      expect(world.output.played, <String>['assets/sounds/zen_received.wav']);
    });

    test('"Dźwięki w aplikacji" off silences them', () async {
      final _World world = _World(
        _focused,
        settings: const AppSettings(inAppSounds: false),
      );
      await world.hub.enterConversation(_ada);
      await world.receive(_direct('m-1'));
      expect(world.output.played, isEmpty);
    });

    test('a reaction given plays the like, taking it back does not', () async {
      final _World world = _World(_focused);
      await world.timeline.append(
        _ada,
        const ChatMessage(
          id: 'm-1',
          sender: _ada,
          text: 'Hej!',
          sentAtMillis: 1,
          direction: ChatMessageDirection.incoming,
        ),
      );
      await world.hub.reactToMessage(
        conversationKey: _ada,
        messageId: 'm-1',
        emoji: '👍',
      );
      await pumpEventQueue();
      expect(world.output.played, <String>['assets/sounds/zen_like.wav']);

      await world.hub.reactToMessage(
        conversationKey: _ada,
        messageId: 'm-1',
        emoji: '👍',
      );
      await pumpEventQueue();
      expect(world.output.played, hasLength(1));
    });

    test('an entry in the list of notifications has the kind of news it '
        'tells of', () {
      InboxEntry entry(InboxEntryType type, {String? routeKey}) => InboxEntry(
        id: 'e',
        type: type,
        title: 'T',
        body: 'B',
        createdAtMillis: 1,
        routeKey: routeKey,
      );
      expect(
        noticeKindOfInboxEntry(entry(InboxEntryType.friendRequest)),
        NoticeKind.invitation,
      );
      expect(
        noticeKindOfInboxEntry(entry(InboxEntryType.post)),
        NoticeKind.friendPost,
      );
      expect(
        noticeKindOfInboxEntry(entry(InboxEntryType.mention)),
        NoticeKind.mention,
      );
      expect(
        noticeKindOfInboxEntry(entry(InboxEntryType.message)),
        NoticeKind.message,
      );
      expect(noticeKindOfInboxEntry(entry(InboxEntryType.callInvite)), isNull);
      expect(
        noticeKindOfInboxEntry(entry(InboxEntryType.friendRemoved)),
        isNull,
      );
    });
  });

  group('the sound module', () {
    ZenSoundEffects effects({
      required bool inApp,
      required bool notifications,
      TargetPlatform platform = TargetPlatform.windows,
    }) => ZenSoundEffects(
      output: _FakeOutput(),
      inAppSoundsOn: () => inApp,
      notificationSoundsOn: () => notifications,
      deviceKeepsQuiet: () async => false,
      platform: platform,
    );

    test('the in-app switch governs the effects, the other the notification '
        'sounds Zen plays itself', () async {
      final ZenSoundEffects onlyInApp = effects(
        inApp: true,
        notifications: false,
      );
      expect(await onlyInApp.allows(ZenSound.like), isTrue);
      expect(await onlyInApp.allows(ZenSound.pop), isTrue);
      expect(await onlyInApp.allows(ZenSound.posted), isTrue);
      expect(await onlyInApp.allows(ZenSound.messageReceived), isTrue);
      expect(await onlyInApp.allows(ZenSound.message), isFalse);
      expect(await onlyInApp.allows(ZenSound.knock), isFalse);

      final ZenSoundEffects onlyNotifications = effects(
        inApp: false,
        notifications: true,
      );
      expect(await onlyNotifications.allows(ZenSound.like), isFalse);
      expect(await onlyNotifications.allows(ZenSound.message), isTrue);
      expect(await onlyNotifications.allows(ZenSound.social), isTrue);
    });

    test('the new effects are effects of the app only', () {
      for (final ZenSound sound in <ZenSound>[
        ZenSound.messageReceived,
        ZenSound.like,
        ZenSound.posted,
        ZenSound.pop,
      ]) {
        expect(sound.isInAppEffect, isTrue, reason: sound.name);
        expect(sound.isNotificationSound, isFalse, reason: sound.name);
      }
    });
  });
}
