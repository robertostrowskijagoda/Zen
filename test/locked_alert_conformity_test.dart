import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// The locked phone decides "ring and show the call card / post a notice /
// nothing" by the app's own rules: the same frames go to the app (Zen in
// the background) and to the locked receiver, each run from the same state
// and settings (the receiver from the capability and the notice kit the app
// writes of them), and each frame must end the same on both.
//
// Not compared: a 1:1 message from someone who is no friend, which the app
// takes in as a request to talk and the locked phone keeps for after unlock
// without a notice.

const String _self = 'me.ygg';
const String _ada = 'ada.ygg'; // a friend, in the group
const String _bob = 'bob.ygg'; // a friend, not in the group
const String _member = 'member.ygg'; // in the group, no friend
const String _joined = 'grp-joined';
const String _pending = 'grp-pending'; // only invited to it

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);

SocialHubState _seed({Map<String, int> mutedUntil = const <String, int>{}}) =>
    SocialHubState.empty(lifecycle: _background).copyWith(
      book: FriendshipBook.restore(
        profiles: const <String, FriendProfile>{
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
      ),
      groups: const <String, GroupProfile>{
        _joined: GroupProfile(
          id: _joined,
          name: 'Ekipa',
          createdById: _ada,
          createdAtMillis: 0,
          memberAddresses: <String>[_ada, _member, _self],
        ),
        _pending: GroupProfile(
          id: _pending,
          name: 'Zaproszenie',
          createdById: _bob,
          createdAtMillis: 0,
          memberAddresses: <String>[_bob, _self],
          isInvitePending: true,
        ),
      },
      mutedUntil: mutedUntil,
    );

/// A notification service that writes down what it was given to show.
final class _Shown implements RuntimeSystemNotificationService {
  _Shown(this._delegate);

  final MemoryRuntimeSystemNotificationService _delegate;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) => _delegate.initialize(onOpenRoute: onOpenRoute, onAction: onAction);

  @override
  Future<bool> show(RuntimeSystemNotification notification) async {
    final bool done = await _delegate.show(notification);
    if (done) {
      shown.add(notification);
    }
    return done;
  }

  @override
  Future<void> dismiss(String id) => _delegate.dismiss(id);

  @override
  Future<void> dismissSlot(String slotKey) => _delegate.dismissSlot(slotKey);

  @override
  Future<void> clear() => _delegate.clear();
}

/// What one frame did: `ring`, `notice:<kind>` or `nothing`.
String _outcome({
  required bool rang,
  required List<RuntimeSystemNotification> shown,
}) {
  if (rang) {
    return 'ring';
  }
  final List<RuntimeSystemNotification> notices = <RuntimeSystemNotification>[
    for (final RuntimeSystemNotification n in shown)
      if (n.category != RuntimeSystemNotificationCategory.call) n,
  ];
  if (notices.isEmpty) {
    return 'nothing';
  }
  return 'notice:${noticeKindOf(notices.last)?.name}';
}

/// One frame [payload] from [from].
typedef _Frame = ({String name, String from, Map<String, dynamic> payload});

Map<String, dynamic> _mentioning(
  String groupId,
  String id,
) => <String, dynamic>{
  'type': 'group_message',
  'groupId': groupId,
  'msgId': id,
  '_rid': id,
  'text': 'Hej <@0>',
  kMentionsKey: <Object?>[const Mention(address: _self, name: 'Ja').toJson()],
};

final List<_Frame> _frames = <_Frame>[
  (
    name: 'a friend calls',
    from: _ada,
    payload: <String, dynamic>{'type': 'call_invite', 'callId': 'c1'},
  ),
  (
    name: 'a group member who is no friend calls alone',
    from: _member,
    payload: <String, dynamic>{'type': 'call_invite', 'callId': 'c2'},
  ),
  (
    name: 'a group call in the joined group',
    from: _member,
    payload: <String, dynamic>{
      'type': 'group_call_invite',
      'groupId': _joined,
      'callId': 'c3',
    },
  ),
  (
    name: 'a group call to a made-up group',
    from: _ada,
    payload: <String, dynamic>{
      'type': 'group_call_invite',
      'groupId': 'made-up',
      'callId': 'c4',
    },
  ),
  (
    name: 'a group call in a group only invited to',
    from: _bob,
    payload: <String, dynamic>{
      'type': 'group_call_invite',
      'groupId': _pending,
      'callId': 'c5',
    },
  ),
  (
    name: 'a group call from a friend outside the group',
    from: _bob,
    payload: <String, dynamic>{
      'type': 'group_call_invite',
      'groupId': _joined,
      'callId': 'c6',
    },
  ),
  (
    name: 'a friend writes',
    from: _ada,
    payload: <String, dynamic>{
      'type': 'message',
      'msgId': 'm1',
      '_rid': 'm1',
      'text': 'Hej',
    },
  ),
  (
    name: 'a member writes in the group',
    from: _member,
    payload: <String, dynamic>{
      'type': 'group_message',
      'groupId': _joined,
      'msgId': 'm2',
      '_rid': 'm2',
      'text': 'Kto idzie?',
    },
  ),
  (
    name: 'a member mentions this phone',
    from: _member,
    payload: _mentioning(_joined, 'm3'),
  ),
  (
    name: 'a member mentions this phone under a padded group id',
    from: _member,
    payload: _mentioning(' $_joined', 'm4'),
  ),
  (
    name: 'a friend "mentions" this phone in a made-up group',
    from: _ada,
    payload: _mentioning('made-up', 'm5'),
  ),
  (
    name: 'a friend outside the group "mentions" this phone in it',
    from: _bob,
    payload: _mentioning(_joined, 'm6'),
  ),
  (
    name: 'a friend writes in a group only invited to',
    from: _bob,
    payload: <String, dynamic>{
      'type': 'group_message',
      'groupId': _pending,
      'msgId': 'm7',
      '_rid': 'm7',
      'text': 'Hej',
    },
  ),
];

/// The settings and mutes each frame is tried under.
final List<({String name, AppSettings settings, bool muteChats})> _worlds =
    <({String name, AppSettings settings, bool muteChats})>[
      (name: 'default', settings: const AppSettings(), muteChats: false),
      (
        name: 'every group message',
        settings: const AppSettings(groupMentionsOnly: false),
        muteChats: false,
      ),
      (
        name: 'calls off',
        settings: AppSettings(
          mutedNotices: <NoticeKind>{NoticeKind.call},
          groupMentionsOnly: false,
        ),
        muteChats: false,
      ),
      (
        name: 'the friend and the group muted',
        settings: const AppSettings(groupMentionsOnly: false),
        muteChats: true,
      ),
      (
        name: 'messages, group messages and mentions off',
        settings: AppSettings(
          mutedNotices: <NoticeKind>{
            NoticeKind.message,
            NoticeKind.groupMessage,
            NoticeKind.mention,
          },
          groupMentionsOnly: false,
        ),
        muteChats: false,
      ),
    ];

Uint8List _masterKey() =>
    Uint8List.fromList(List<int>.generate(32, (int i) => i + 7));

void main() {
  late Directory support;
  late MemorySecurityCredentialsStore credentials;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('zen-conformity-');
    credentials = MemorySecurityCredentialsStore();
  });

  tearDown(() async {
    if (await support.exists()) {
      await support.delete(recursive: true);
    }
  });

  Map<String, int> mutes(bool on) => on
      ? <String, int>{
          _ada: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          groupConversationKey(_joined): DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        }
      : const <String, int>{};

  /// What [frames] do, one after the other, in the app in the background.
  Future<List<String>> inTheApp(
    AppSettings settings,
    SocialHubState seed,
    List<_Frame> frames,
  ) async {
    final _Shown shade = _Shown(MemoryRuntimeSystemNotificationService());
    final List<String> cards = <String>[];
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
      bootstrap: () async => RuntimeNodeSession(
        transport: MemorySignalTransport(),
        snapshot: RuntimeTransportSnapshot.started(
          localAddress: _self,
          peers: 1,
        ),
      ),
    );
    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: settings,
          hydrationEnabled: false,
        ),
        runtimeNodeRuntimeProvider.overrideWithValue(runtime),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        runtimeSystemNotificationServiceProvider.overrideWith(
          (Ref ref) => NoticeSettingsNotificationService(
            shade,
            muted: (NoticeKind kind) =>
                ref.read(appSettingsControllerProvider).mutes(kind),
            sounds: () =>
                ref.read(appSettingsControllerProvider).notificationSounds,
          ),
        ),
        incomingCallCardProvider.overrideWithValue(({
          required String displayName,
          required bool isVideo,
          required String peerAddress,
          required String acceptRouteKey,
        }) async {
          cards.add(peerAddress);
          return true;
        }),
        socialHubSeedProvider.overrideWithValue(seed),
      ],
    );
    addTearDown(container.dispose);
    container.read(socialHubControllerProvider);
    await runtime.start();
    final SocialHubController hub = container.read(
      socialHubControllerProvider.notifier,
    );
    final List<String> outcomes = <String>[];
    for (final _Frame frame in frames) {
      final int cardsBefore = cards.length;
      final int shownBefore = shade.shown.length;
      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: frame.from,
        payload: frame.payload,
      );
      if (signal != null) {
        await hub.receiveSignal(
          signal,
          receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
        );
        await pumpEventQueue();
      }
      outcomes.add(
        _outcome(
          rang: cards.length > cardsBefore,
          shown: shade.shown.sublist(shownBefore),
        ),
      );
    }
    return outcomes;
  }

  /// What [frames] do, one after the other, on the locked phone, run from
  /// what the app writes for it of [seed] and [settings].
  Future<List<String>> whileLocked(
    AppSettings settings,
    SocialHubState seed,
    List<_Frame> frames,
  ) async {
    final FileBackgroundVault appVault = FileBackgroundVault(
      supportDirectory: () async => support,
      credentials: credentials,
      createKey: true,
    );
    final FileBackgroundVault serviceVault = FileBackgroundVault(
      supportDirectory: () async => support,
      credentials: credentials,
    );
    await appVault.publish(
      backgroundCapabilityDraftOf(
        seed,
        inboxPublicKey: await inboxPublicKeyFor(_masterKey()),
      ),
    );
    final BackgroundCapability capability = (await serviceVault.load())!;
    // As the kit file carries it.
    final LockedNoticeKit kit = LockedNoticeKit.fromJson(
      lockedNoticeKitOf(
        seed,
        privacy: settings.notificationPrivacy,
        muted: <NoticeKind>{
          for (final NoticeKind kind in NoticeKind.values)
            if (settings.mutes(kind)) kind,
        },
        sounds: settings.notificationSounds,
        kindLevels: settings.noticePrivacy,
        groupMentionsOnly: settings.groupMentionsOnly,
        self: _self,
      ).toJson(),
    )!;
    final _Shown notices = _Shown(MemoryRuntimeSystemNotificationService());
    final LockedReceiver receiver = LockedReceiver(
      transport: MemorySignalTransport(),
      capability: capability,
      inbox: SealedInboxWriter(
        file: await serviceVault.inboxFile(),
        recipientPublicKey: capability.inboxPublicKey,
      ),
      notices: notices,
      mailboxPollInterval: Duration.zero,
      noticeThrottle: Duration.zero,
      noticeKit: kit,
    );
    final List<bool> rings = <bool>[];
    final List<String> cards = <String>[];
    receiver.ringForCall = (bool on) async => rings.add(on);
    receiver.showCallCard = (String from) async => cards.add(from);
    await receiver.start();
    addTearDown(receiver.stop);
    final List<String> outcomes = <String>[];
    for (final _Frame frame in frames) {
      final int ringsBefore = rings.where((bool on) => on).length;
      final int cardsBefore = cards.length;
      final int shownBefore = notices.shown.length;
      await receiver.handleFrame(
        SignalTransportFrame(
          from: frame.from,
          payload: frame.payload,
          receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final bool rang = rings.where((bool on) => on).length > ringsBefore;
      // A ring always comes with its card, and a card never without it.
      expect(cards.length > cardsBefore, rang, reason: frame.name);
      outcomes.add(
        _outcome(rang: rang, shown: notices.shown.sublist(shownBefore)),
      );
    }
    return outcomes;
  }

  for (final ({String name, AppSettings settings, bool muteChats}) world
      in _worlds) {
    test('${world.name}: each frame ends the same while locked as in the '
        'app', () async {
      final SocialHubState seed = _seed(mutedUntil: mutes(world.muteChats));
      final Map<String, String> app = <String, String>{};
      final Map<String, String> locked = <String, String>{};
      // Each frame on a phone of its own: a ring would make the next call
      // find the line busy.
      for (final _Frame frame in _frames) {
        app[frame.name] = (await inTheApp(world.settings, seed, <_Frame>[
          frame,
        ])).single;
        locked[frame.name] = (await whileLocked(world.settings, seed, <_Frame>[
          frame,
        ])).single;
      }
      expect(locked, app);
    });
  }

  test(
    'the expected outcomes hold (so the comparison means something)',
    () async {
      final SocialHubState seed = _seed();
      final List<String> locked = <String>[
        for (final _Frame frame in _frames)
          (await whileLocked(const AppSettings(), seed, <_Frame>[
            frame,
          ])).single,
      ];
      expect(locked, <String>[
        'ring', // a friend calls
        'nothing', // a member who is no friend calls alone
        'ring', // a group call in the joined group
        'nothing', // a made-up group
        'nothing', // a group only invited to
        'nothing', // a friend outside the group
        'notice:message',
        'nothing', // mentions only by default
        'notice:mention',
        'notice:mention', // the padded id is the same group
        'nothing',
        'nothing',
        'nothing',
      ]);
    },
  );

  test('a flood of mentions from one member: the same mentions are told, '
      'the rest is quiet, in the app and while locked', () async {
    final SocialHubState seed = _seed(mutedUntil: mutes(true));
    final List<_Frame> flood = <_Frame>[
      for (int i = 0; i < kMaxMentionAlertsPerSender + 3; i++)
        (
          name: 'mention $i',
          from: _member,
          payload: _mentioning(_joined, 'f$i'),
        ),
    ];
    const AppSettings settings = AppSettings();
    final List<String> app = await inTheApp(settings, seed, flood);
    final List<String> locked = await whileLocked(settings, seed, flood);
    expect(locked, app);
    expect(
      locked.where((String o) => o == 'notice:mention'),
      hasLength(kMaxMentionAlertsPerSender),
    );
    expect(locked.skip(kMaxMentionAlertsPerSender), everyElement('nothing'));
  });
}
