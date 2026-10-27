import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_notification_center.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// What a chat message's notification says at each level ("Nadawca i
// treść", "Tylko nadawca", "Tylko informacja"), the global level against a
// conversation's own, and what the locked background receiver is given to
// say the same.

const String _ada = 'ada.ygg';
const String _bob = 'bob.ygg';
const String _groupId = 'grp-1';
const String _eve = 'eve.ygg';
const String _mallory = 'mallory.ygg';
const String _pat = 'pat.ygg';

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

ZenSignal _direct(String id) => ZenSignal(
  type: ZenSignalType.message,
  sender: _ada,
  displayName: 'Ada',
  messageId: id,
  content: 'Tajny plan',
);

ZenSignal _inGroup(String id) => ZenSignal(
  type: ZenSignalType.groupMessage,
  sender: _ada,
  displayName: 'Ada',
  groupId: _groupId,
  groupName: 'Ekipa',
  messageId: id,
  content: 'Tajny plan',
);

SocialHubState _seed(
  LifecycleSnapshot lifecycle, {
  Map<String, NotificationPrivacy> own = const <String, NotificationPrivacy>{},
}) => SocialHubState.empty(lifecycle: lifecycle).copyWith(
  friends: const <String, FriendProfile>{
    _ada: FriendProfile(
      address: _ada,
      displayName: 'Ada',
      status: FriendRelationshipStatus.accepted,
    ),
    _bob: FriendProfile(
      address: _bob,
      displayName: 'Bob',
      status: FriendRelationshipStatus.accepted,
    ),
  },
  groups: const <String, GroupProfile>{
    _groupId: GroupProfile(
      id: _groupId,
      name: 'Ekipa',
      createdById: _ada,
      createdAtMillis: 0,
      memberAddresses: <String>[_ada, _bob],
    ),
  },
  notificationPrivacy: own,
);

/// The app as it runs: the hub posts through the central redaction, which
/// reads the same setting.
({ProviderContainer container, MemoryRuntimeSystemNotificationService shade})
_boot({
  required NotificationPrivacy global,
  Map<String, NotificationPrivacy> own = const <String, NotificationPrivacy>{},
  LifecycleSnapshot lifecycle = _background,
  RuntimeNotificationCenter? center,
  MemorySocialSnapshotStore? snapshots,
  SocialHubState? seed,
}) {
  final MemoryRuntimeSystemNotificationService shade =
      MemoryRuntimeSystemNotificationService();
  late final ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      ...buildAppSettingsProviderOverrides(
        store: MemoryAppSettingsStore(),
        initialState: AppSettings(notificationPrivacy: global),
        hydrationEnabled: false,
      ),
      signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
      socialSnapshotStoreProvider.overrideWithValue(
        snapshots ?? MemorySocialSnapshotStore(),
      ),
      messageTimelineStoreProvider.overrideWithValue(
        MemoryMessageTimelineStore(),
      ),
      runtimeSystemNotificationServiceProvider.overrideWithValue(
        PrivacyRedactingNotificationService(
          shade,
          privacy: () =>
              container.read(appSettingsControllerProvider).notificationPrivacy,
        ),
      ),
      if (center != null)
        runtimeNotificationCenterProvider.overrideWithValue(center),
      socialHubSeedProvider.overrideWithValue(
        seed ?? _seed(lifecycle, own: own),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, shade: shade);
}

Future<RuntimeSystemNotification> _shown(
  ZenSignal signal, {
  required NotificationPrivacy global,
  Map<String, NotificationPrivacy> own = const <String, NotificationPrivacy>{},
}) async {
  final (:container, :shade) = _boot(global: global, own: own);
  await container
      .read(socialHubControllerProvider.notifier)
      .receiveSignal(signal, receivedAtMillis: 1000);
  return shade.activeNotifications.single;
}

void main() {
  group('a chat message\'s notification', () {
    test('"Nadawca i treść" (the default): who and what', () async {
      expect(
        const AppSettings().notificationPrivacy,
        NotificationPrivacy.senderAndContent,
      );
      RuntimeSystemNotification n = await _shown(
        _direct('m-1'),
        global: NotificationPrivacy.senderAndContent,
      );
      expect(n.title, 'Ada');
      expect(n.body, 'Tajny plan');
      n = await _shown(
        _inGroup('g-1'),
        global: NotificationPrivacy.senderAndContent,
      );
      expect(n.title, 'Ekipa');
      expect(n.body, 'Ada: Tajny plan');
    });

    test('"Tylko nadawca": who, never what', () async {
      RuntimeSystemNotification n = await _shown(
        _direct('m-1'),
        global: NotificationPrivacy.senderOnly,
      );
      expect(n.title, 'Ada');
      expect(n.body, 'Nowa wiadomość');
      n = await _shown(_inGroup('g-1'), global: NotificationPrivacy.senderOnly);
      expect(n.title, 'Ekipa');
      expect(n.body, 'Ada wysłał(a) wiadomość');
    });

    test('"Tylko informacja": neither who nor what', () async {
      for (final ZenSignal signal in <ZenSignal>[
        _direct('m-1'),
        _inGroup('g-1'),
      ]) {
        final RuntimeSystemNotification n = await _shown(
          signal,
          global: NotificationPrivacy.generic,
        );
        expect(n.title, 'Nowa wiadomość');
        expect('${n.title} ${n.body}', isNot(contains('Ada')));
        expect('${n.title} ${n.body}', isNot(contains('Ekipa')));
        expect('${n.title} ${n.body}', isNot(contains('Tajny')));
      }
    });

    test(
      'a conversation\'s own level beats the global one, both ways',
      () async {
        RuntimeSystemNotification n = await _shown(
          _direct('m-1'),
          global: NotificationPrivacy.generic,
          own: const <String, NotificationPrivacy>{
            _ada: NotificationPrivacy.senderAndContent,
          },
        );
        expect(n.title, 'Ada');
        expect(n.body, 'Tajny plan');

        n = await _shown(
          _inGroup('g-1'),
          global: NotificationPrivacy.senderAndContent,
          own: const <String, NotificationPrivacy>{
            'group:$_groupId': NotificationPrivacy.generic,
          },
        );
        expect(n.title, 'Nowa wiadomość');
        expect(n.body, isNot(contains('Tajny')));

        // The group's own level is not Ada's 1:1 chat's.
        n = await _shown(
          _direct('m-2'),
          global: NotificationPrivacy.senderAndContent,
          own: const <String, NotificationPrivacy>{
            'group:$_groupId': NotificationPrivacy.generic,
          },
        );
        expect(n.body, 'Tajny plan');
      },
    );

    test('the in-app banner tells as much as the notification', () async {
      final MemoryRuntimeNotificationCenter center =
          MemoryRuntimeNotificationCenter();
      final (:container, shade: _) = _boot(
        global: NotificationPrivacy.generic,
        lifecycle: _focused,
        center: center,
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(_direct('m-1'), receivedAtMillis: 1000);
      final RuntimeNotification banner = center.activeNotifications.single;
      expect(banner.title, 'Nowa wiadomość');
      expect('${banner.title} ${banner.body}', isNot(contains('Tajny')));
      expect('${banner.title} ${banner.body}', isNot(contains('Ada')));
    });
  });

  group('a group message\'s notice with the app unlocked', () {
    // Eve is in the group but not a friend, Pat's friend request still
    // waits (both named themselves), Mallory is not in the group at all.
    SocialHubState mixed(LifecycleSnapshot lifecycle) {
      final SocialHubState seeded = _seed(lifecycle);
      return seeded.copyWith(
        friends: <String, FriendProfile>{
          ...seeded.friends,
          _pat: const FriendProfile(
            address: _pat,
            displayName: 'Ada',
            status: FriendRelationshipStatus.pendingIncoming,
          ),
        },
        groups: <String, GroupProfile>{
          _groupId: seeded.groups[_groupId]!.copyWith(
            memberAddresses: <String>[_ada, _bob, _eve, _pat],
            memberNames: const <String, String>{_eve: 'Bob', _pat: 'Ada'},
          ),
        },
      );
    }

    // Each claims a name and a group name of its own choosing.
    ZenSignal from(String sender, String id, {String claimed = 'Ada'}) =>
        ZenSignal(
          type: ZenSignalType.groupMessage,
          sender: sender,
          displayName: claimed,
          groupId: _groupId,
          groupName: 'Bank',
          messageId: id,
          content: 'Hej',
        );

    Future<({List<RuntimeSystemNotification> shown, List<InboxEntry> alerts})>
    background(ZenSignal signal) async {
      final (:container, :shade) = _boot(
        global: NotificationPrivacy.senderAndContent,
        seed: mixed(_background),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(signal, receivedAtMillis: 1000);
      return (
        shown: shade.activeNotifications,
        alerts: container.read(socialHubControllerProvider).backgroundAlerts,
      );
    }

    Future<({List<RuntimeNotification> banners, List<InboxEntry> inbox})>
    focused(ZenSignal signal, NotificationPrivacy global) async {
      final MemoryRuntimeNotificationCenter center =
          MemoryRuntimeNotificationCenter();
      final (:container, shade: _) = _boot(
        global: global,
        lifecycle: _focused,
        center: center,
        seed: mixed(_focused),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(signal, receivedAtMillis: 1000);
      return (
        banners: center.activeNotifications,
        inbox: container.read(socialHubControllerProvider).inbox,
      );
    }

    test('a member who is a friend: by the name given here', () async {
      final r = await background(from(_bob, 'g-1'));
      expect(r.shown.single.title, 'Ekipa');
      expect(r.shown.single.body, 'Bob: Hej');
      expect(r.alerts.single.title, 'Ekipa: Bob');
    });

    test('any other member: "Kontakt Zen", never their own name', () async {
      for (final String member in <String>[_eve, _pat]) {
        final r = await background(from(member, 'g-$member', claimed: 'Bob'));
        expect(r.shown.single.title, 'Ekipa');
        expect(r.shown.single.body, 'Kontakt Zen: Hej');
        expect(r.alerts.single.title, 'Ekipa: Kontakt Zen');
      }
    });

    test('not a member: nothing about that group', () async {
      final r = await background(from(_mallory, 'g-1'));
      expect(r.shown, isEmpty);
      expect(r.alerts, isEmpty);
    });

    test('the in-app list and banner name members the same way', () async {
      var r = await focused(
        from(_eve, 'g-1', claimed: 'Bob'),
        NotificationPrivacy.senderOnly,
      );
      expect(r.inbox.single.title, 'Ekipa: Kontakt Zen');
      expect(r.banners.single.title, 'Ekipa');
      expect(r.banners.single.body, 'Kontakt Zen wysłał(a) wiadomość');

      r = await focused(
        from(_bob, 'g-2'),
        NotificationPrivacy.senderAndContent,
      );
      expect(r.inbox.single.title, 'Ekipa: Bob');
      expect(r.banners.single.title, 'Ekipa: Bob');

      r = await focused(
        from(_mallory, 'g-3'),
        NotificationPrivacy.senderAndContent,
      );
      expect(r.inbox, isEmpty);
      expect(r.banners, isEmpty);
    });
  });

  group('a conversation\'s own level', () {
    test(
      'is kept with the conversations and "Jak globalnie" removes it',
      () async {
        final MemorySocialSnapshotStore snapshots = MemorySocialSnapshotStore();
        final (:container, shade: _) = _boot(
          global: NotificationPrivacy.senderAndContent,
          snapshots: snapshots,
        );
        final SocialHubController hub = container.read(
          socialHubControllerProvider.notifier,
        );
        await hub.setConversationNotificationPrivacy(
          _ada,
          NotificationPrivacy.senderOnly,
        );
        await hub.setConversationNotificationPrivacy(
          'group:$_groupId',
          NotificationPrivacy.generic,
        );
        SocialHubState state = container.read(socialHubControllerProvider);
        expect(
          state.ownNotificationPrivacyOf(_ada),
          NotificationPrivacy.senderOnly,
        );
        expect(
          state.notificationPrivacyFor(
            _bob,
            global: NotificationPrivacy.senderAndContent,
          ),
          NotificationPrivacy.senderAndContent,
        );
        expect(
          (await snapshots.load())!.notificationPrivacy['group:$_groupId'],
          NotificationPrivacy.generic,
        );

        await hub.setConversationNotificationPrivacy(_ada, null);
        state = container.read(socialHubControllerProvider);
        expect(state.ownNotificationPrivacyOf(_ada), isNull);
        expect((await snapshots.load())!.notificationPrivacy.keys, <String>[
          'group:$_groupId',
        ]);
      },
    );

    test('survives the snapshot file', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'zen-notify-privacy-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          dir,
          codec: BinaryCodec(compressor: const _Plain()),
        ),
      );
      await store.save(
        _seed(
          _background,
          own: const <String, NotificationPrivacy>{
            _ada: NotificationPrivacy.generic,
            'group:$_groupId': NotificationPrivacy.senderOnly,
          },
        ),
      );
      final SocialHubState loaded = (await FileSocialSnapshotStore(
        store: FileBinaryStore(
          dir,
          codec: BinaryCodec(compressor: const _Plain()),
        ),
      ).load())!;
      expect(loaded.notificationPrivacy, <String, NotificationPrivacy>{
        _ada: NotificationPrivacy.generic,
        'group:$_groupId': NotificationPrivacy.senderOnly,
      });
    });
  });

  group('the locked receiver\'s notice kit', () {
    test('names only the conversations whose level shows who wrote', () {
      final LockedNoticeKit kit = lockedNoticeKitOf(
        _seed(
          _background,
          own: const <String, NotificationPrivacy>{
            _bob: NotificationPrivacy.generic,
          },
        ),
        privacy: NotificationPrivacy.senderOnly,
      );
      expect(kit.privacy, NotificationPrivacy.senderOnly);
      expect(kit.names[_ada], 'Ada');
      expect(kit.names['group:$_groupId'], 'Ekipa');
      expect(kit.overrides[_bob], NotificationPrivacy.generic);
      expect(kit.levelOf(_bob), NotificationPrivacy.generic);

      // Nothing shows who: no names at all.
      final LockedNoticeKit quiet = lockedNoticeKitOf(
        _seed(_background),
        privacy: NotificationPrivacy.generic,
      );
      expect(quiet.names, isEmpty);
    });

    test(
      'reads back what it wrote, and an unreadable level says the least',
      () {
        final LockedNoticeKit kit = lockedNoticeKitOf(
          _seed(
            _background,
            own: const <String, NotificationPrivacy>{
              'group:$_groupId': NotificationPrivacy.senderAndContent,
            },
          ),
          privacy: NotificationPrivacy.senderOnly,
        );
        final LockedNoticeKit back = LockedNoticeKit.fromJson(kit.toJson())!;
        expect(back.privacy, kit.privacy);
        expect(back.overrides, kit.overrides);
        expect(back.names, kit.names);
        expect(back.members, kit.members);
        expect(back.members['group:$_groupId'], <String>{_ada, _bob});
        expect(LockedNoticeKit.fromJson(<String, dynamic>{'v': 2}), isNull);
        expect(
          LockedNoticeKit.fromJson(<String, dynamic>{
            'v': 1,
            'p': '?',
          })!.privacy,
          NotificationPrivacy.generic,
        );
      },
    );

    test('a message\'s notice per level', () {
      final LockedNoticeKit kit = lockedNoticeKitOf(
        _seed(
          _background,
          own: const <String, NotificationPrivacy>{
            _bob: NotificationPrivacy.generic,
          },
        ),
        privacy: NotificationPrivacy.senderAndContent,
      );
      NoticeText notice(String from, Map<String, dynamic> payload) =>
          kit.messageNotice(from: from, payload: payload, genericBody: '…');
      expect(
        notice(_ada, <String, dynamic>{'type': 'message', 'text': 'Hej'}),
        (title: 'Ada', body: 'Hej'),
      );
      expect(
        notice(_bob, <String, dynamic>{'type': 'message', 'text': 'Hej'}),
        (title: 'Nowa wiadomość', body: '…'),
      );
      expect(
        notice(_bob, <String, dynamic>{
          'type': 'group_message',
          'groupId': _groupId,
          'text': 'Hej',
        }),
        (title: 'Ekipa', body: 'Bob: Hej'),
      );
      // A photo: only its type, never the caption.
      expect(
        notice(_ada, <String, dynamic>{
          'type': 'message',
          'text': 'podpis',
          'messageType': 'image',
          'attachmentData': 'AAAA',
        }).body,
        isNot(contains('podpis')),
      );
    });

    test('a group notice names only its members, by names given here', () {
      final SocialHubState seeded = _seed(_background);
      final LockedNoticeKit kit = lockedNoticeKitOf(
        seeded.copyWith(
          friends: <String, FriendProfile>{
            ...seeded.friends,
            // Their friend request still waits: the name is their own.
            _pat: const FriendProfile(
              address: _pat,
              displayName: 'Ada',
              status: FriendRelationshipStatus.pendingIncoming,
            ),
          },
          groups: <String, GroupProfile>{
            _groupId: seeded.groups[_groupId]!.copyWith(
              memberAddresses: <String>[_ada, _bob, _eve, _pat],
              // Names members gave themselves, one of them for someone
              // who is not in the group at all.
              memberNames: const <String, String>{_eve: 'Bob', _mallory: 'Ada'},
            ),
          },
        ),
        privacy: NotificationPrivacy.senderAndContent,
      );
      expect(kit.names.containsKey(_eve), isFalse);
      expect(kit.names.containsKey(_mallory), isFalse);
      NoticeText notice(String from, String claimed) => kit.messageNotice(
        from: from,
        payload: <String, dynamic>{
          'type': 'group_message',
          'groupId': _groupId,
          'text': 'Hej',
          'senderName': claimed,
        },
        genericBody: '…',
      );
      // A member who is a friend: the name this person gave them.
      expect(notice(_bob, 'Ada'), (title: 'Ekipa', body: 'Bob: Hej'));
      // A member who is not a friend: no name at all.
      expect(notice(_eve, 'Bob'), (title: 'Ekipa', body: 'Kontakt Zen: Hej'));
      expect(kit.names.containsKey(_pat), isFalse);
      expect(notice(_pat, 'Ada'), (title: 'Ekipa', body: 'Kontakt Zen: Hej'));
      // Not a member: only that something came.
      expect(notice(_mallory, 'Ada'), (title: 'Nowa wiadomość', body: '…'));
      // Nor a 1:1 message from someone a group named.
      expect(
        kit.messageNotice(
          from: _mallory,
          payload: <String, dynamic>{'type': 'message', 'text': 'Hej'},
          genericBody: '…',
        ),
        (title: 'Nowa wiadomość', body: '…'),
      );
    });

    test('a locked notice never carries the whole message', () {
      final LockedNoticeKit kit = lockedNoticeKitOf(
        _seed(_background),
        privacy: NotificationPrivacy.senderAndContent,
      );
      final String long = '${'ż' * 70} koniec wiadomości, której nie widać';
      final String body = kit
          .messageNotice(
            from: _ada,
            payload: <String, dynamic>{'type': 'message', 'text': long},
            genericBody: '…',
          )
          .body;
      expect(body.runes.length, kLockedNoticePreviewChars);
      expect(body, endsWith('…'));
      expect(body, isNot(contains('nie widać')));
      expect(shortNoticePreview('  krótko  '), 'krótko');
      // Whole characters: an emoji is never cut in half.
      final String emoji = shortNoticePreview('😀' * 100, max: 5);
      expect(emoji, '😀😀😀😀…');
    });
  });
}

final class _Plain implements BinaryCompressor {
  const _Plain();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
