import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
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

// Every runner that receives while Zen is locked or away decides "ring and
// show the call card / tell about it / nothing" as the app in front does,
// from the same state and settings: the same frames go to the app (behind
// the account routing, which makes a friend's other device speak as the
// friend) and to each background runner as the product builds it from the
// files the app writes into the account's folder (the capability and the
// notice kit):
//
// * the default account's Android service (and an iPhone's), which reads
//   the kit with readLockedNoticeKit;
// * a computer's tray node of the default account, and an additional
//   account's node (Android service and tray), both made by
//   BackgroundAccountKits as BackgroundAccountNode.openAt makes them.
//
// A runner without a kit, and an additional account whose notifications
// are off, stay quiet.

const String _self = 'me.ygg';
const String _ada = 'ada.ygg'; // a friend, in the group
const String _adaLaptop = 'ada-laptop.ygg'; // the same friend's laptop
const String _bob = 'bob.ygg'; // a friend, not in the group
const String _member = 'member.ygg'; // in the group, no friend
const String _joined = 'grp-joined';

/// This device's account, and Ada's with her two devices.
final class _Directory implements AccountDeviceDirectory {
  @override
  String get ownAccount => 'ME';

  @override
  String? accountOf(String address) =>
      address == _ada || address == _adaLaptop ? 'ADA' : null;

  @override
  List<String> addressesOf(String account) =>
      account == 'ADA' ? const <String>[_ada, _adaLaptop] : const <String>[];

  @override
  String? contactAddressOf(String account) => account == 'ADA' ? _ada : null;

  @override
  String? unlinkedAccountOf(String address) => null;
}

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
      },
      mutedUntil: mutedUntil,
    );

/// A notification service that writes down what it was given to show.
final class _Shown implements RuntimeSystemNotificationService {
  final MemoryRuntimeSystemNotificationService _delegate =
      MemoryRuntimeSystemNotificationService();
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

/// What one frame did: `ring`, `notice` or `nothing`. (An additional
/// account's notices say no more than that something came, so the kind of
/// a notice is not compared here: locked_alert_conformity_test does.)
String _outcome({
  required bool rang,
  required List<RuntimeSystemNotification> shown,
}) {
  if (rang) {
    return 'ring';
  }
  return shown.any(
        // The ringing call's own entry goes with the ring; a missed call's
        // is a notice (the app posts it as a call, the receiver as a
        // message of the kind "Połączenia").
        (RuntimeSystemNotification n) => !n.isRingingCall,
      )
      ? 'notice'
      : 'nothing';
}

typedef _Frame = ({String name, String from, Map<String, dynamic> payload});

Map<String, dynamic> _message(String id) => <String, dynamic>{
  'type': 'message',
  'msgId': id,
  '_rid': id,
  'text': 'Hej',
};

final List<_Frame> _frames = <_Frame>[
  (
    name: 'a friend calls',
    from: _ada,
    payload: <String, dynamic>{'type': 'call_invite', 'callId': 'c1'},
  ),
  (
    name: "a friend calls from their other device",
    from: _adaLaptop,
    payload: <String, dynamic>{'type': 'call_invite', 'callId': 'c2'},
  ),
  (
    name: 'a group member who is no friend calls',
    from: _member,
    payload: <String, dynamic>{'type': 'call_invite', 'callId': 'c3'},
  ),
  (
    name: 'a group call in the joined group',
    from: _member,
    payload: <String, dynamic>{
      'type': 'group_call_invite',
      'groupId': _joined,
      'callId': 'c4',
    },
  ),
  (name: 'a friend writes', from: _ada, payload: _message('m1')),
  (
    name: 'a friend writes from their other device',
    from: _adaLaptop,
    payload: _message('m2'),
  ),
  (name: 'another friend writes', from: _bob, payload: _message('m3')),
  (
    name: 'a member writes in the group',
    from: _member,
    payload: <String, dynamic>{
      'type': 'group_message',
      'groupId': _joined,
      'msgId': 'm4',
      '_rid': 'm4',
      'text': 'Kto idzie?',
    },
  ),
  (
    name: 'a member mentions this device in the group',
    from: _member,
    payload: <String, dynamic>{
      'type': 'group_message',
      'groupId': _joined,
      'msgId': 'm5',
      '_rid': 'm5',
      'text': 'Hej <@0>',
      kMentionsKey: <Object?>[
        const Mention(address: _self, name: 'Ja').toJson(),
      ],
    },
  ),
  (
    name: 'a friend tells of a call nobody answered',
    from: _ada,
    payload: <String, dynamic>{
      'type': kCallMissedType,
      'callId': 'c5',
      '_rid': 'cm-c5',
    },
  ),
];

typedef _World = ({String name, AppSettings settings, bool muteChats});

final List<_World> _worlds = <_World>[
  (name: 'default', settings: const AppSettings(), muteChats: false),
  (
    name: 'calls off',
    settings: AppSettings(
      mutedNotices: <NoticeKind>{NoticeKind.call},
      groupMentionsOnly: false,
    ),
    muteChats: false,
  ),
  (
    // Ada and the group muted ("Wycisz"): a mention still comes.
    name: 'a friend and the group muted',
    settings: const AppSettings(groupMentionsOnly: false),
    muteChats: true,
  ),
  (
    name: 'messages and group messages off',
    settings: AppSettings(
      mutedNotices: <NoticeKind>{NoticeKind.message, NoticeKind.groupMessage},
      groupMentionsOnly: false,
    ),
    muteChats: false,
  ),
];

Map<String, int> _mutes(bool on) => on
    ? <String, int>{
        _ada: DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        groupConversationKey(_joined): DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      }
    : const <String, int>{};

Uint8List _masterKey() =>
    Uint8List.fromList(List<int>.generate(32, (int i) => i + 7));

/// An account's folder with what the app writes into it for its background
/// runners while it is open: the capability, and the notice kit (unless
/// [kit] is false).
final class _Folder {
  _Folder(this.dir);

  final Directory dir;
  final MemorySecurityCredentialsStore credentials =
      MemorySecurityCredentialsStore();

  Future<void> write(
    SocialHubState state,
    AppSettings settings, {
    bool kit = true,
  }) async {
    final AccountDeviceDirectory directory = _Directory();
    await FileBackgroundVault(
      supportDirectory: () async => dir,
      credentials: credentials,
      createKey: true,
    ).publish(
      backgroundCapabilityDraftOf(
        state,
        inboxPublicKey: await inboxPublicKeyFor(_masterKey()),
        directory: directory,
      ),
    );
    if (kit) {
      // As LockedNoticeKitBridge writes it.
      await lockedNoticeKitFile(
        supportDirectory: () async => dir,
        credentials: credentials,
        createKey: true,
      ).write(
        lockedNoticeKitFor(
          state,
          settings: settings,
          directory: directory,
          self: _self,
        ).toJson(),
      );
    }
  }
}

/// A background runner's receiver on [transport], posting to [notices].
typedef _Runner =
    Future<LockedReceiver> Function(
      SignalTransport transport,
      RuntimeSystemNotificationService notices,
    );

/// The default account's Android service, as LockedReceiverSession opens
/// it (the parts that decide what rings and what is told).
_Runner _androidDefault(_Folder folder) =>
    (
      SignalTransport transport,
      RuntimeSystemNotificationService notices,
    ) async {
      final FileBackgroundVault vault = FileBackgroundVault(
        supportDirectory: () async => folder.dir,
        credentials: folder.credentials,
      );
      final BackgroundCapability capability = (await vault.load())!;
      return LockedReceiver(
        transport: transport,
        capability: capability,
        inbox: SealedInboxWriter(
          file: await vault.inboxFile(),
          recipientPublicKey: capability.inboxPublicKey,
        ),
        notices: notices,
        noticeKit: await readLockedNoticeKit(
          supportDirectory: () async => folder.dir,
          credentials: folder.credentials,
        ),
        mailboxPollInterval: Duration.zero,
        noticeThrottle: Duration.zero,
      );
    };

/// A node as BackgroundAccountNode.openAt makes it: a computer's tray node
/// of the default account ([account] `null`), or an additional account's.
_Runner _node(_Folder folder, {ZenBackgroundAccount? account}) =>
    (
      SignalTransport transport,
      RuntimeSystemNotificationService notices,
    ) async {
      final BackgroundAccountKits kits = (await BackgroundAccountKits.read(
        support: folder.dir,
        credentials: folder.credentials,
      ))!;
      return kits.receiver(
        transport: transport,
        notices: notices,
        account: account,
        slot: 1,
      );
    };

ZenBackgroundAccount _account(_Folder folder, {bool notify = true}) =>
    ZenBackgroundAccount(
      folder: folder.dir.uri.pathSegments
          .where((String s) => s.isNotEmpty)
          .last,
      secret: Uint8List(32),
      notify: notify,
    );

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-runners-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<_Folder> folder(String name) async {
    final Directory dir = Directory('${root.path}/$name');
    await dir.create(recursive: true);
    return _Folder(dir);
  }

  /// What [frame] does in the app with Zen in the background: it comes
  /// through the account routing, as every frame does there.
  Future<String> inTheApp(
    AppSettings settings,
    SocialHubState seed,
    _Frame frame,
  ) async {
    final _Shown shade = _Shown();
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
    final ProviderContainer container = ProviderContainer(
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
    final MemorySignalTransport wire = MemorySignalTransport();
    await wire.start();
    final AccountRoutingTransport routing = AccountRoutingTransport(
      delegate: wire,
      directory: _Directory.new,
    );
    final Future<SignalTransportFrame> routed = routing.frames.first;
    await wire.injectIncoming(from: frame.from, payload: frame.payload);
    final SignalTransportFrame arrived = await routed.timeout(
      const Duration(seconds: 5),
    );
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: arrived.from,
      payload: arrived.payload,
    );
    if (signal != null) {
      await hub.receiveSignal(
        signal,
        receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      await pumpEventQueue();
    }
    return _outcome(rang: cards.isNotEmpty, shown: shade.shown);
  }

  /// What [frame] does on a runner made by [runner], straight from the
  /// node (no routing there).
  Future<String> onRunner(_Runner runner, _Frame frame) async {
    final _Shown shade = _Shown();
    final LockedReceiver receiver = await runner(
      MemorySignalTransport(),
      shade,
    );
    final List<bool> rings = <bool>[];
    final List<String> cards = <String>[];
    receiver.ringForCall = (bool on) async => rings.add(on);
    receiver.showCallCard = (String from) async => cards.add(from);
    await receiver.start();
    addTearDown(receiver.stop);
    await receiver.handleFrame(
      SignalTransportFrame(
        from: frame.from,
        payload: frame.payload,
        receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final bool rang = rings.contains(true);
    // A ring always comes with its card, and a card never without it.
    expect(cards.isNotEmpty, rang, reason: frame.name);
    await receiver.stop();
    return _outcome(rang: rang, shown: shade.shown);
  }

  for (final _World world in _worlds) {
    test('${world.name}: every background runner ends each frame as the '
        'app does', () async {
      final SocialHubState seed = _seed(mutedUntil: _mutes(world.muteChats));
      final _Folder home = await folder('home');
      final _Folder other = await folder(
        'accounts/0123456789abcdef0123456789abcdef',
      );
      await home.write(seed, world.settings);
      await other.write(seed, world.settings);
      final Map<String, _Runner> runners = <String, _Runner>{
        'android service, default account': _androidDefault(home),
        'tray, default account': _node(home),
        'additional account': _node(other, account: _account(other)),
      };
      final Map<String, String> app = <String, String>{
        for (final _Frame frame in _frames)
          frame.name: await inTheApp(world.settings, seed, frame),
      };
      for (final MapEntry<String, _Runner> runner in runners.entries) {
        final Map<String, String> locked = <String, String>{
          for (final _Frame frame in _frames)
            frame.name: await onRunner(runner.value, frame),
        };
        expect(locked, app, reason: runner.key);
      }
    });
  }

  test(
    'the expected outcomes hold (so the comparison means something)',
    () async {
      final _Folder home = await folder('home');
      Future<List<String>> run(
        SocialHubState seed,
        AppSettings settings,
      ) async {
        await home.write(seed, settings);
        return <String>[
          for (final _Frame frame in _frames)
            await onRunner(_node(home), frame),
        ];
      }

      expect(await run(_seed(), const AppSettings()), <String>[
        'ring', // a friend calls
        'ring', // from their other device
        'nothing', // a member who is no friend calls alone
        'ring', // a group call in the joined group
        'notice',
        'notice', // from the friend's other device
        'notice',
        'nothing', // mentions only by default
        'notice', // the mention
        'notice', // the missed call
      ]);
      // Muted: the friend's other device is quiet too; the mention comes.
      expect(
        await run(
          _seed(mutedUntil: _mutes(true)),
          const AppSettings(groupMentionsOnly: false),
        ),
        <String>[
          'ring',
          'ring',
          'nothing',
          'ring',
          'nothing',
          'nothing',
          'notice',
          'nothing',
          'notice',
          'notice',
        ],
      );
      expect(
        await run(
          _seed(),
          AppSettings(mutedNotices: <NoticeKind>{NoticeKind.call}),
        ),
        <String>[
          'nothing',
          'nothing',
          'nothing',
          'nothing',
          'notice',
          'notice',
          'notice',
          'nothing',
          'notice',
          'nothing',
        ],
      );
    },
  );

  test('a runner without a notice kit, and an additional account whose '
      'notifications are off, ring nothing and tell of nothing', () async {
    final SocialHubState seed = _seed();
    final _Folder home = await folder('home');
    final _Folder other = await folder(
      'accounts/0123456789abcdef0123456789abcdef',
    );
    // The first run after the update: the capability is there, no kit yet.
    await home.write(seed, const AppSettings(), kit: false);
    await other.write(seed, const AppSettings());
    final Map<String, _Runner> runners = <String, _Runner>{
      'android service without a kit': _androidDefault(home),
      'tray without a kit': _node(home),
      'additional account, its notifications off': _node(
        other,
        account: _account(other, notify: false),
      ),
    };
    for (final MapEntry<String, _Runner> runner in runners.entries) {
      expect(
        <String>[
          for (final _Frame frame in _frames)
            await onRunner(runner.value, frame),
        ],
        everyElement('nothing'),
        reason: runner.key,
      );
    }
  });

  test("an additional account's call card names nobody and opens that "
      'account', () async {
    final SocialHubState seed = _seed();
    final _Folder home = await folder('home');
    final _Folder other = await folder(
      'accounts/0123456789abcdef0123456789abcdef',
    );
    await home.write(seed, const AppSettings());
    await other.write(seed, const AppSettings());
    final ZenBackgroundAccount account = _account(other);
    final LockedReceiver extra = await _node(other, account: account)(
      MemorySignalTransport(),
      _Shown(),
    );
    expect(extra.callCardFor(_ada), (
      name: 'Połączenie przychodzące',
      route: buildAccountRouteKey(account.folder),
    ));
    final LockedReceiver own = await _node(home)(
      MemorySignalTransport(),
      _Shown(),
    );
    expect(own.callCardFor(_ada), (name: 'Ada', route: ''));
  });

  test('groups past the kit\'s member tags still ring and tell, from the '
      'capability\'s word, not from nobody\'s', () async {
    // 120 groups of 200 members: more than the kit keeps tags for.
    final Map<String, GroupProfile> groups = <String, GroupProfile>{
      for (int g = 0; g < 120; g++)
        'grp$g': GroupProfile(
          id: 'grp$g',
          name: 'G$g',
          createdById: 'm$g-0.ygg',
          createdAtMillis: 0,
          memberAddresses: <String>[
            for (int m = 0; m < 200; m++) 'm$g-$m.ygg',
            _self,
          ],
        ),
    };
    final SocialHubState seed = _seed().copyWith(groups: groups);
    final LockedNoticeKit kit = LockedNoticeKit.fromJson(
      lockedNoticeKitFor(
        seed,
        settings: const AppSettings(),
        self: _self,
      ).toJson(),
    )!;
    expect(
      kit.memberTags.length,
      lessThanOrEqualTo(LockedNoticeKit.maxMemberTags),
    );
    expect(kit.unlistedGroups, isNotEmpty);
    // Nine groups of two hundred fit in whole.
    final LockedNoticeKit nine = lockedNoticeKitFor(
      _seed().copyWith(
        groups: <String, GroupProfile>{
          for (final String id in groups.keys.take(9)) id: groups[id]!,
        },
      ),
      settings: const AppSettings(),
    );
    expect(nine.unlistedGroups, isEmpty);
    expect(<bool>[
      for (int g = 0; g < 9; g++) nine.speaksIn('grp$g', 'm$g-100.ygg'),
    ], everyElement(isTrue));

    final _Folder home = await folder('home');
    await home.write(seed, const AppSettings());
    final _Frame call = (
      name: 'a group call in the last group',
      from: 'm119-100.ygg',
      payload: <String, dynamic>{
        'type': 'group_call_invite',
        'groupId': 'grp119',
        'callId': 'g119',
      },
    );
    expect(await onRunner(_node(home), call), 'ring');
    // A made-up group stays quiet.
    expect(
      await onRunner(_node(home), (
        name: 'a group call in a made-up group',
        from: 'm119-100.ygg',
        payload: <String, dynamic>{
          'type': 'group_call_invite',
          'groupId': 'made-up',
          'callId': 'g0',
        },
      )),
      'nothing',
    );
  });
}
