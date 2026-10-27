import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/realtime_attachment_transfer.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/relay/reliable_signal_transport.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// What kind of device a [FriendsPhone] is: it decides whether the device
/// announces that it stays online (friends then prefer it as a mailbox) and
/// whether it can be locked.
enum SimDevice {
  /// An Android phone: stays online through its background service, so it
  /// is a good mailbox, and it can be locked.
  android,

  /// A computer with Zen in the tray: a good mailbox, never locked.
  desktop,

  /// An iPhone: receives only while Zen is open, so it is no mailbox of
  /// choice.
  iphone;

  /// What the device announces about itself.
  RelayDeviceClass get relayClass => switch (this) {
    android => RelayDeviceClass.android,
    desktop => RelayDeviceClass.desktop,
    iphone => RelayDeviceClass.iphone,
  };
}

/// Every notification a phone posted (the ones the user could see or hear),
/// not only the ones still in the shade: several posts into one slot fold
/// into one entry in the shade, and a test that counts messages needs the
/// posts.
final class RecordingNotices implements RuntimeSystemNotificationService {
  final MemoryRuntimeSystemNotificationService shade =
      MemoryRuntimeSystemNotificationService();

  /// Posts the system accepted, oldest first.
  final List<RuntimeSystemNotification> posted = <RuntimeSystemNotification>[];

  /// Posts about a chat message (not friend requests, calls, ...).
  List<RuntimeSystemNotification> get messages => <RuntimeSystemNotification>[
    for (final RuntimeSystemNotification n in posted)
      if (n.category == RuntimeSystemNotificationCategory.message) n,
  ];

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) => shade.initialize(onOpenRoute: onOpenRoute, onAction: onAction);

  @override
  Future<bool> show(RuntimeSystemNotification notification) async {
    final bool shown = await shade.show(notification);
    if (shown) {
      posted.add(notification);
    }
    return shown;
  }

  @override
  Future<void> dismiss(String id) => shade.dismiss(id);

  @override
  Future<void> dismissSlot(String slotKey) => shade.dismissSlot(slotKey);

  @override
  Future<void> clear() => shade.clear();
}

/// The part of the phone that sends into the simulated network: nothing
/// leaves a phone that is switched off.
final class _PhoneLink implements SignalTransport {
  _PhoneLink(this.phone);

  final FriendsPhone phone;

  @override
  Stream<SignalTransportFrame> get frames =>
      const Stream<SignalTransportFrame>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    if (!phone.sim.online) {
      return;
    }
    await phone.sim.send(remoteAddress, payload);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

/// What other services on a phone (the recovery circle, the ledger) use as
/// their transport: sends go through the phone's reliable transport (outbox,
/// mailboxes), what arrives is what the relay engine hands to the app.
final class _AppLink implements SignalTransport {
  _AppLink(this.phone);

  final FriendsPhone phone;

  @override
  Stream<SignalTransportFrame> get frames => phone._appFrames.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) => phone.transport.send(remoteAddress: remoteAddress, payload: payload);

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

/// WebRTC is not there: the realtime path of an attachment gives up at once
/// and the mailboxes carry it.
final class _NoRealtimeSession implements RealtimeAttachmentTransferSession {
  @override
  ValueChanged<double>? onProgress;

  @override
  ValueChanged<Uint8List>? onComplete;

  @override
  ValueChanged<Object>? onError;

  @override
  Future<void> send({
    required Uint8List bytes,
    required String text,
    required ChatMessageType type,
    String? fileName,
    String? mimeType,
    int? attachmentSizeBytes,
    int? durationMs,
  }) async {
    throw TimeoutException('no peer connection in tests');
  }

  @override
  Future<void> acceptIncoming({
    required Map<String, dynamic> description,
    required int fileSize,
  }) async {}

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {}

  @override
  Future<void> close() async {}
}

/// The locked Android service of a phone: what runs while the app is locked.
final class _LockedSide {
  _LockedSide({
    required this.receiver,
    required this.mailbox,
    required this.vault,
  });

  final LockedReceiver receiver;
  final LockedMailbox mailbox;
  final FileBackgroundVault vault;

  /// The mailbox kit as the service saved it last (what the app takes over
  /// at unlock); `null` while nothing changed.
  LockedMailboxKit? held;
}

/// One member of a [FriendsWorld]: a phone or a computer with its own relay
/// engine, social controller (a real [SocialHubController] over memory
/// stores), reliable transport and notifications, on the simulated network.
final class FriendsPhone implements RelayPeerSource {
  FriendsPhone._(
    this.world,
    this.name,
    this.sim,
    this.device,
    this.directory, {
    SocialHubState? seed,
  }) : _seed = seed;

  /// The social state the phone starts with (another device of an account
  /// starts with the account's friends).
  final SocialHubState? _seed;

  /// Which account each address belongs to, as this phone's ledger would
  /// tell (see [FriendsWorld.addDevice]).
  late final AccountDeviceDirectory accounts = _WorldAccounts(this);

  final FriendsWorld world;
  final String name;
  final SimPhone sim;
  final SimDevice device;

  /// Where this phone keeps its files (attachments, the locked service's
  /// vault).
  final Directory directory;

  final MemoryRelayStateStore relayStore = MemoryRelayStateStore();
  final MemoryMessageTimelineStore timeline = MemoryMessageTimelineStore();
  final RecordingNotices notices = RecordingNotices();
  final StreamController<SignalTransportFrame> _appFrames =
      StreamController<SignalTransportFrame>.broadcast(sync: true);

  late final RelayEngine engine;
  late final ReliableSignalTransport transport;
  late final ProviderContainer container;
  late final RuntimeNodeRuntime _runtime;
  late final Uint8List _masterKey;

  /// The phone's frames as the account's other services see them (the
  /// recovery circle, the ledger): what the relay engine handed to the app.
  late final SignalTransport appTransport = _AppLink(this);

  _LockedSide? _locked;
  int _generation = 1;

  String get address => sim.address;

  bool get online => sim.online;

  /// Whether the app is locked and only its background service runs.
  bool get locked => _locked != null;

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  /// Posts about a chat message this phone made (the app's and, while
  /// locked, the service's).
  List<RuntimeSystemNotification> get messageNotices => notices.messages;

  /// The message notifications in the shade now: one per chat, however many
  /// posts went into it.
  List<RuntimeSystemNotification> get shownMessageNotices =>
      <RuntimeSystemNotification>[
        for (final RuntimeSystemNotification n
            in notices.shade.activeNotifications)
          if (n.category == RuntimeSystemNotificationCategory.message) n,
      ];

  @override
  bool get isReady => true;

  @override
  String get localAddress => address;

  /// Friends with their other devices (never an unlinked one); a friend's
  /// presence is the newest of their devices', as the app sees it (every
  /// device of theirs speaks as the friend).
  @override
  List<RelayFriend> acceptedFriends() => <RelayFriend>[
    for (final FriendProfile f in state.acceptedFriends)
      if (accounts.unlinkedAccountOf(f.address) == null ||
          world._devicesOf(f.address).length > 1)
        RelayFriend(
          linked: accounts.unlinkedAccountOf(f.address) == null,
          address: f.address,
          lastSeenAtMillis: <int>[
            for (final String a in world._devicesOf(f.address))
              world._lastSeenOf(a),
          ].fold<int>(0, max),
          devices: <String>[
            for (final String a in world._devicesOf(f.address))
              if (a != PeerShareCodec.normalizeAddress(f.address) &&
                  accounts.unlinkedAccountOf(a) == null)
                a,
          ],
        ),
  ];

  @override
  List<RelayFriend> groupContacts() {
    final Set<String> seen = <String>{};
    return <RelayFriend>[
      for (final GroupProfile group in state.groups.values)
        if (!group.isInvitePending)
          for (final String member in group.memberAddresses)
            if (PeerShareCodec.normalizeAddress(member) != address &&
                state.friendByAddress(member) == null &&
                seen.add(PeerShareCodec.normalizeAddress(member)))
              RelayFriend(address: member),
    ];
  }

  /// The conversation with [peer] (a phone, or `group:<id>` for a group), as
  /// stored on this phone, oldest first.
  Future<List<ChatMessage>> thread(Object peer) async {
    final String key = peer is FriendsPhone ? peer.address : '$peer';
    return timeline.load(key);
  }

  /// The texts [from] sent that are in this phone's chat, in the order shown.
  Future<List<String>> textsFrom(Object from) async => <String>[
    for (final ChatMessage m in await thread(from))
      if (m.direction == ChatMessageDirection.incoming) m.text,
  ];

  /// The delivery state of the message with [text] that this phone sent to
  /// [peer], or `null` when there is none.
  Future<ChatMessageDeliveryState?> deliveryOf(Object peer, String text) async {
    for (final ChatMessage m in await thread(peer)) {
      if (m.direction == ChatMessageDirection.outgoing && m.text == text) {
        return m.deliveryState;
      }
    }
    return null;
  }

  /// The app goes to the background: what arrives raises notifications and
  /// goes into the stored chats (with the app on screen it would be left
  /// for the chat screen, which this world has none of).
  Future<void> _toBackground() async {
    _generation += 1;
    await hub.setLifecycle(
      LifecycleSnapshot(
        visibility: AppVisibilityState.background,
        generation: _generation,
        capturedAtMillis: world.net.now,
      ),
    );
  }

  Future<void> _start() async {
    _runtime = RuntimeNodeRuntime.live(
      bootstrap: () async => RuntimeNodeSession(
        transport: MemorySignalTransport(),
        snapshot: RuntimeTransportSnapshot.started(
          localAddress: address,
          peers: 1,
        ),
      ),
    );
    await _runtime.start();
    final _PhoneLink link = _PhoneLink(this);
    engine = RelayEngine(
      store: relayStore,
      blobStore: relayStore,
      peers: this,
      send: (String to, Map<String, dynamic> payload) =>
          link.send(remoteAddress: to, payload: payload),
      clock: () => world.net.now,
      deviceClass: () => device.relayClass,
    );
    // Only used to send: the frames are taken to the engine by [_onFrame],
    // which waits for the app to be done with each one.
    transport = ReliableSignalTransport(
      delegate: link,
      engine: engine,
      tickInterval: const Duration(days: 1),
    );
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(_seed),
        ),
        messageTimelineStoreProvider.overrideWithValue(timeline),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        // Friends with several devices look like one person, as in the app.
        signalTransportProvider.overrideWithValue(
          AccountRoutingTransport(
            delegate: transport,
            directory: () => accounts,
          ),
        ),
        relayEngineProvider.overrideWithValue(engine),
        runtimeNodeRuntimeProvider.overrideWithValue(_runtime),
        runtimeSystemNotificationServiceProvider.overrideWithValue(notices),
        supportDirectoryResolverProvider.overrideWithValue(
          () async => directory,
        ),
        realtimeAttachmentTransferFactoryProvider.overrideWithValue(
          ({required String transferId, required String remoteAddress}) =>
              _NoRealtimeSession(),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ),
        ),
      ],
    );
    // The keys the locked service would hold no master key for.
    final Random random = Random(address.hashCode);
    _masterKey = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    sim.attach(_onFrame);
    // The social state exists from here on.
    await hub.whenHydrated;
    await engine.activate();
  }

  /// One frame from the network: while locked, the background service takes
  /// it; otherwise the relay engine does, and the app gets what the engine
  /// hands on, one frame at a time.
  Future<bool> _onFrame(SignalTransportFrame frame) async {
    world._sawAlive(frame.from);
    final _LockedSide? side = _locked;
    if (side != null) {
      await side.receiver.handleFrame(frame);
      return true;
    }
    return _toApp(frame);
  }

  Future<bool> _toApp(SignalTransportFrame frame) async {
    if (!engine.isActive) {
      return false;
    }
    final List<SignalTransportFrame> out = await engine.handleIncoming(frame);
    for (final SignalTransportFrame next in out) {
      _appFrames.add(next);
      final String? from = _speakerOf(next.from);
      if (from == null) {
        continue;
      }
      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: from,
        payload: next.payload,
      );
      if (signal != null) {
        await hub.receiveSignal(
          signal,
          receivedAtMillis: next.receivedAtMillis,
        );
      }
    }
    return true;
  }

  /// Who the app hears in a frame from [address], as the account routing
  /// makes it: a friend's other device speaks as the friend; an unlinked
  /// device is not heard (`null`).
  String? _speakerOf(String address) {
    if (accounts.unlinkedAccountOf(address) != null) {
      return null;
    }
    final String? account = accounts.accountOf(address);
    if (account == null || account == accounts.ownAccount) {
      return address;
    }
    return accounts.contactAddressOf(account) ?? address;
  }

  Future<void> _lock() async {
    if (device == SimDevice.desktop) {
      throw StateError('A computer is not locked like a phone.');
    }
    if (locked) {
      return;
    }
    // What the app hands to its service before it goes: the mailbox kit and
    // the capability (who may be talked to, where the mail waits).
    final LockedMailboxKit kit = LockedMailboxKit.fromJson(
      jsonDecode(jsonEncode((await engine.lockedMailboxKit()).toJson())),
    )!;
    final Set<String> friends = <String>{
      for (final FriendProfile f in state.acceptedFriends) f.address,
    };
    final Set<String> groupMembers = <String>{
      for (final RelayFriend f in groupContacts()) f.address,
    };
    final FileBackgroundVault appVault = FileBackgroundVault(
      supportDirectory: () async => directory,
      credentials: _credentials,
      createKey: true,
    );
    await appVault.publish(
      BackgroundCapabilityDraft(
        inboxPublicKey: await inboxPublicKeyFor(_masterKey),
        friends: friends,
        groupMembers: groupMembers,
        blocked: const <String>{},
        mailboxes: (await relayStore.load()).currentRelays,
      ),
    );
    final FileBackgroundVault vault = FileBackgroundVault(
      supportDirectory: () async => directory,
      credentials: _credentials,
    );
    final BackgroundCapability capability = (await vault.load())!;
    engine.deactivate();
    final _PhoneLink link = _PhoneLink(this);
    late final _LockedSide side;
    final LockedMailbox mailbox = LockedMailbox(
      transport: link,
      kit: kit,
      isFriend: (String a) =>
          capability.kindOf(a) == BackgroundContactKind.friend,
      isContact: (String a) =>
          capability.kindOf(a) == BackgroundContactKind.friend ||
          capability.kindOf(a) == BackgroundContactKind.groupMember,
      save: (LockedMailboxKit saved) async {
        // Through JSON, as the service's file does it.
        side.held = LockedMailboxKit.fromJson(
          jsonDecode(jsonEncode(saved.toJson())),
        );
      },
      now: () => world.net.now,
    );
    final LockedReceiver receiver = LockedReceiver(
      transport: link,
      capability: capability,
      inbox: SealedInboxWriter(
        file: await vault.inboxFile(),
        recipientPublicKey: capability.inboxPublicKey,
      ),
      notices: notices,
      mailbox: mailbox,
      taken: kit.taken,
      now: () => world.net.now,
      mailboxPollInterval: Duration.zero,
    );
    side = _LockedSide(receiver: receiver, mailbox: mailbox, vault: vault);
    _locked = side;
    await receiver.start();
    await _toBackground();
  }

  /// The locked service's credentials: shared with the app's side of the
  /// vault, as in the real app.
  final MemorySecurityCredentialsStore _credentials =
      MemorySecurityCredentialsStore();

  /// The user unlocks the phone: the app takes over what the service held
  /// (mailbox mail, frames kept in the sealed inbox).
  Future<void> _unlock() async {
    final _LockedSide? side = _locked;
    if (side == null) {
      return;
    }
    await side.receiver.stop();
    _locked = null;
    await engine.takeLockedMailbox(side.held);
    await engine.activate();
    // The inbox, handed over as if it had just arrived.
    await side.vault.drain(
      masterKey: _masterKey,
      settle: Duration.zero,
      deliver: (Uint8List record) async {
        final SignalTransportFrame? frame = decodeInboxFrame(record);
        if (frame != null) {
          await _toApp(frame);
        }
      },
    );
    for (final String slot in kLockedReceiverSlots) {
      await notices.dismissSlot(slot);
    }
  }

  Future<void> _dispose() async {
    final _LockedSide? side = _locked;
    if (side != null) {
      await side.receiver.stop();
      _locked = null;
    }
    await _appFrames.close();
    await transport.dispose();
    container.dispose();
    await _runtime.stop();
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Still open on Windows: left to the system's temp cleaning.
    }
  }

  @override
  String toString() => name;
}

/// Friends on a simulated network, for testing messaging end to end:
/// every member is a [FriendsPhone] with a real relay engine, a real
/// [SocialHubController], a real reliable transport and its own
/// notifications; the network between them is a [SimNetwork] with a virtual
/// clock (no real timers: a day passes in milliseconds).
///
/// ```dart
/// final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
/// w.setOnline(w['B'], false);
/// await w.send(w['A'], w['B'], 'hello');
/// await w.setOnline(w['B'], true);
/// await w.assertDelivered(w['B'], 'hello', from: w['A']);
/// ```
///
/// Not simulated: Yggdrasil itself (sessions, routing), presence pings, and
/// the platform (wake locks, radios). A message travels as the app sends it:
/// controller, reliable transport, relay engine, then datagrams that the
/// network delays, drops or holds back.
final class FriendsWorld {
  FriendsWorld({int seed = 1, double dropRate = 0})
    : net = SimNetwork(seed: seed, dropRate: dropRate, holdForOffline: false);

  /// The network; its virtual clock is [now].
  final SimNetwork net;
  final Map<String, FriendsPhone> _byName = <String, FriendsPhone>{};
  final Map<String, FriendsPhone> _byAddress = <String, FriendsPhone>{};
  final Map<String, int> _aliveAt = <String, int>{};

  /// Address -> account (each phone has its own unless added with
  /// [addDevice]).
  final Map<String, String> _accountOf = <String, String>{};

  /// Devices their owner unlinked.
  final Set<String> _unlinked = <String>{};
  int _sentAtGuard = 0;

  /// Builds a world with [names] (one phone each, or with the device kinds
  /// in [devices]), everyone friends with everyone, mailbox announcements
  /// settled. Cleaned up when the test ends.
  static Future<FriendsWorld> create(
    List<String> names, {
    Map<String, SimDevice> devices = const <String, SimDevice>{},
    bool allFriends = true,
    int seed = 1,
    double dropRate = 0,
  }) async {
    final FriendsWorld w = FriendsWorld(seed: seed, dropRate: dropRate);
    addTearDown(w.dispose);
    for (final String name in names) {
      await w.add(name, device: devices[name] ?? SimDevice.android);
    }
    if (allFriends) {
      await w.befriendAll();
    }
    return w;
  }

  /// Virtual time, milliseconds.
  int get now => net.now;

  List<FriendsPhone> get phones => _byName.values.toList();

  FriendsPhone operator [](String name) => _byName[name]!;

  /// Adds a phone (switched on, app in the background, no friends yet).
  Future<FriendsPhone> add(
    String name, {
    SimDevice device = SimDevice.android,
  }) => _add(name, device: device, account: name);

  Future<FriendsPhone> _add(
    String name, {
    required SimDevice device,
    required String account,
    SocialHubState? seed,
  }) async {
    final SimPhone sim = net.phone(name);
    final Directory dir = Directory.systemTemp.createTempSync('zen-world-');
    final FriendsPhone p = FriendsPhone._(
      this,
      name,
      sim,
      device,
      dir,
      seed: seed,
    );
    _byName[name] = p;
    _byAddress[sim.address] = p;
    _accountOf[sim.address] = account;
    await p._start();
    return p;
  }

  /// [owner]'s account gets another device, [name]: a second phone, a
  /// computer, or the phone the account moved to. It has the account's
  /// friends (the account's devices share them), but its own address,
  /// mailbox key and mailboxes; the friends know it is [owner]'s (as their
  /// ledger tells them). The announcements settle afterwards.
  Future<FriendsPhone> addDevice(
    FriendsPhone owner,
    String name, {
    SimDevice device = SimDevice.android,
  }) async {
    final SocialHubState seed =
        SocialHubState.empty(
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.background,
            generation: 1,
            capturedAtMillis: 0,
          ),
        ).copyWith(
          friends: <String, FriendProfile>{
            for (final FriendProfile f in owner.state.acceptedFriends)
              f.address: f,
          },
        );
    final FriendsPhone p = await _add(
      name,
      device: device,
      account: _accountOf[owner.address]!,
      seed: seed,
    );
    await settleMailboxes();
    return p;
  }

  /// [p]'s owner unlinks it (a lost phone): friends neither send to it nor
  /// hear it any more; the account's other devices stand in for it.
  void unlink(FriendsPhone p) => _unlinked.add(p.address);

  /// Every device of the account [address] belongs to.
  List<String> _devicesOf(String address) {
    final String normal = PeerShareCodec.normalizeAddress(address);
    final String? account = _accountOf[normal];
    return account == null
        ? <String>[normal]
        : <String>[
            for (final MapEntry<String, String> e in _accountOf.entries)
              if (e.value == account) e.key,
          ];
  }

  /// Makes [a] and [b] friends the way the app does it: an invitation over
  /// the network and its acceptance. Both must be online.
  Future<void> befriend(FriendsPhone a, FriendsPhone b) async {
    await a.hub.sendFriendRequest(
      peerAddress: b.address,
      knownName: b.name,
      senderDisplayName: a.name,
    );
    await settle();
    await b.hub.acceptFriendRequest(
      peerAddress: a.address,
      senderDisplayName: b.name,
    );
    await settle();
    for (final (FriendsPhone x, FriendsPhone y)
        in <(FriendsPhone, FriendsPhone)>[(a, b), (b, a)]) {
      if (x.state.friendByAddress(y.address)?.status !=
          FriendRelationshipStatus.accepted) {
        fail('${x.name} and ${y.name} did not become friends');
      }
    }
  }

  /// Everybody friends with everybody, then the mailbox announcements settle
  /// (see [settleMailboxes]).
  Future<void> befriendAll([List<FriendsPhone>? among]) async {
    final List<FriendsPhone> list = among ?? phones;
    for (int i = 0; i < list.length; i++) {
      for (int j = i + 1; j < list.length; j++) {
        await befriend(list[i], list[j]);
      }
    }
    await settleMailboxes();
  }

  /// Friends in a chain a-b-c-...
  Future<void> befriendChain(List<FriendsPhone> list) async {
    for (int i = 0; i + 1 < list.length; i++) {
      await befriend(list[i], list[i + 1]);
    }
    await settleMailboxes();
  }

  /// Time for every phone to announce its mailboxes to its friends and for
  /// the friends to confirm.
  Future<void> settleMailboxes() => advance(const Duration(seconds: 12));

  /// [owner] picks [mailboxes] as the friends that hold its mail while it is
  /// away (what "Skrzynki" in the settings does), and tells its friends.
  /// Without this call the engine picks up to six friends by itself.
  Future<void> chooseMailboxes(
    FriendsPhone owner,
    List<FriendsPhone> mailboxes,
  ) async {
    await owner.engine.setManualRelays(<String>[
      for (final FriendsPhone m in mailboxes) m.address,
    ]);
    await settleMailboxes();
  }

  /// The mailboxes [owner] has now (its relay set), as phones.
  Future<List<FriendsPhone>> mailboxesOf(FriendsPhone owner) async =>
      <FriendsPhone>[
        for (final String a in (await owner.relayStore.load()).currentRelays)
          if (_byAddress[a] != null) _byAddress[a]!,
      ];

  /// Switches [p] on or off. A phone that is off sends nothing, receives
  /// nothing (what is sent to it is lost, unless a mailbox keeps a copy)
  /// and its engine does not tick; switching it on starts the engine again,
  /// which asks its mailboxes for what waits there.
  Future<void> setOnline(FriendsPhone p, bool on) async {
    if (p.online == on) {
      return;
    }
    if (on) {
      net.setOnline(p.sim, true);
      _aliveAt[p.address] = net.now;
      if (!p.locked) {
        await p.engine.activate();
      }
      await settle();
    } else {
      _aliveAt[p.address] = net.now;
      net.setOnline(p.sim, false);
      if (!p.locked) {
        p.engine.deactivate();
      }
    }
  }

  /// The phone [p] is locked: only its background service runs (mailbox
  /// duties, a sealed inbox for what arrives, one notice per message).
  Future<void> lock(FriendsPhone p) => p._lock();

  /// The user unlocks [p]: the app takes over what the service kept.
  Future<void> unlock(FriendsPhone p) async {
    await p._unlock();
    await settle();
  }

  /// Cuts the network between the two groups until [heal].
  void partition(List<FriendsPhone> a, List<FriendsPhone> b) => net.partition(
    a.map((FriendsPhone p) => p.sim),
    b.map((FriendsPhone p) => p.sim),
  );

  void heal() => net.heal();

  /// Share of datagrams lost on the way (0-1).
  set dropRate(double rate) => net.dropRate = rate;

  /// Sends [text] from [from] to the friend [to], as the user does with the
  /// send button (the message is stamped with the virtual time). By default
  /// the network settles afterwards; with `settleAfter: false` only the
  /// first send is made.
  Future<void> send(
    FriendsPhone from,
    FriendsPhone to,
    String text, {
    bool settleAfter = true,
  }) async {
    await from.hub.sendLocalMessage(
      peerAddress: to.address,
      text: text,
      sentAtMillis: net.now,
    );
    if (settleAfter) {
      await settle();
    }
  }

  /// Creates a group of [creator] and [members] (all friends of the creator),
  /// has every member join, and returns its id.
  Future<String> createGroup(
    FriendsPhone creator,
    String name,
    List<FriendsPhone> members,
  ) async {
    final GroupProfile group = await creator.hub.createGroup(
      name: name,
      description: '',
      memberAddresses: <String>[
        for (final FriendsPhone m in members) m.address,
      ],
    );
    await settle();
    for (final FriendsPhone m in members) {
      final GroupProfile? invite = m.state.groups[group.id];
      if (invite != null && invite.isInvitePending) {
        await m.hub.acceptGroupInvite(
          groupId: group.id,
          groupName: name,
          senderAddress: creator.address,
        );
      }
    }
    await settle();
    return group.id;
  }

  /// Sends [text] to the group [groupId] from [from].
  Future<void> sendGroup(
    FriendsPhone from,
    String groupId,
    String text, {
    bool settleAfter = true,
  }) async {
    // A group message's id is made from the wall clock to the millisecond.
    while (DateTime.now().millisecondsSinceEpoch <= _sentAtGuard) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _sentAtGuard = DateTime.now().millisecondsSinceEpoch;
    await from.hub.sendGroupMessage(groupId: groupId, text: text);
    if (settleAfter) {
      await settle();
    }
  }

  /// The texts of the group chat on [p], oldest first, whoever wrote them.
  Future<List<String>> groupTexts(FriendsPhone p, String groupId) async =>
      <String>[
        for (final ChatMessage m in await p.thread('group:$groupId')) m.text,
      ];

  int _lastSeenOf(String address) => _aliveAt[address] ?? 0;

  void _sawAlive(String address) =>
      _aliveAt[PeerShareCodec.normalizeAddress(address)] = net.now;

  /// Lets everything that is in flight land and every phone finish what it
  /// was doing, without moving the clock beyond the network's own delays.
  Future<void> settle() async {
    for (int round = 0; round < 200; round++) {
      final int before = net.stats.sent;
      await net.run();
      // The apps' own asynchronous work (state saves, replies queued from
      // a handler) can still send something.
      await pumpEventQueue(times: 6);
      if (net.stats.sent == before) {
        return;
      }
    }
    fail('the simulated network did not settle');
  }

  /// Moves the virtual clock on by [duration]: datagrams land when due, and
  /// every phone's relay engine ticks (as its transport's timer would do)
  /// every [step] (5 seconds while something waits to be tried again, as the
  /// transport does, 30 seconds while everything just waits).
  Future<void> advance(Duration duration, {Duration? step}) async {
    final int end = net.now + duration.inMilliseconds;
    while (net.now < end) {
      final Duration every =
          step ??
          (phones.any(
                (FriendsPhone p) =>
                    p.online && !p.locked && p.engine.wantsFrequentTicks,
              )
              ? const Duration(seconds: 5)
              : const Duration(seconds: 30));
      final int next = min(end, net.now + every.inMilliseconds);
      await net.run(forAtMost: Duration(milliseconds: next - net.now));
      for (final FriendsPhone p in phones) {
        if (p.online && !p.locked) {
          await p.engine.tick();
        }
      }
      await settle();
    }
  }

  /// Lets time pass until the network and all phones are quiet: the usual
  /// "and now everything has been delivered" step.
  Future<void> deliver() => advance(const Duration(seconds: 15));

  /// Advances in steps until [done] holds or [within] of virtual time has
  /// passed; fails with [reason] and a list of what is still waiting.
  Future<void> until(
    Future<bool> Function() done, {
    Duration within = const Duration(minutes: 5),
    String reason = 'the condition',
  }) async {
    final int end = net.now + within.inMilliseconds;
    while (true) {
      if (await done()) {
        return;
      }
      if (net.now >= end) {
        break;
      }
      await advance(
        const Duration(seconds: 5),
        step: const Duration(seconds: 5),
      );
    }
    fail('$reason did not happen within $within\n${await describe()}');
  }

  /// [text] from [from] is in [to]'s chat within [within] of virtual time.
  Future<void> assertDelivered(
    FriendsPhone to,
    String text, {
    required FriendsPhone from,
    Duration within = const Duration(minutes: 1),
  }) => until(
    () async => (await to.textsFrom(from)).contains(text),
    within: within,
    reason: '"$text" from ${from.name} reaching ${to.name}',
  );

  /// [text] from [from] is not in [to]'s chat after [after] of virtual time.
  Future<void> assertNotDelivered(
    FriendsPhone to,
    String text, {
    required FriendsPhone from,
    Duration after = const Duration(minutes: 1),
  }) async {
    await advance(after);
    expect(
      await to.textsFrom(from),
      isNot(contains(text)),
      reason: '"$text" from ${from.name} must not have reached ${to.name}',
    );
  }

  /// Everything waiting anywhere: for a failing test's message.
  Future<String> describe() async {
    final StringBuffer out = StringBuffer(
      'virtual time +${net.now - 1700000000000} ms; ${net.stats}\n',
    );
    for (final FriendsPhone p in phones) {
      final RelayState state = await p.relayStore.load();
      out.writeln(
        '${p.name} (${p.online ? 'online' : 'offline'}${p.locked ? ', locked' : ''}): '
        'outbox ${state.outbox.length}, '
        'holds mail for ${state.mailbox.entries.map((e) => '${_byAddress[e.key]?.name}:${e.value.length}').join(', ')}',
      );
    }
    return out.toString();
  }

  Future<void> dispose() async {
    for (final FriendsPhone p in phones) {
      await p._dispose();
    }
  }
}

/// What a phone's ledger would know about accounts: the world's truth.
final class _WorldAccounts implements AccountDeviceDirectory {
  _WorldAccounts(this.phone);

  final FriendsPhone phone;

  FriendsWorld get _world => phone.world;

  @override
  String get ownAccount => _world._accountOf[phone.address] ?? '';

  @override
  String? accountOf(String address) =>
      _world._accountOf[PeerShareCodec.normalizeAddress(address)];

  @override
  List<String> addressesOf(String account) => <String>[
    for (final MapEntry<String, String> e in _world._accountOf.entries)
      if (e.value == account && e.key != phone.address) e.key,
  ];

  @override
  String? contactAddressOf(String account) {
    for (final FriendProfile f in phone.state.acceptedFriends) {
      if (accountOf(f.address) == account) {
        return f.address;
      }
    }
    return null;
  }

  @override
  String? unlinkedAccountOf(String address) =>
      _world._unlinked.contains(PeerShareCodec.normalizeAddress(address))
      ? accountOf(address)
      : null;
}
