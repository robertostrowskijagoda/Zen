import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_host.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/unmetered_network.dart';
import 'package:zen/src/core/utils/quiet_timer.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_media.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/bridge_host.dart';
import 'package:zen/src/features/ledger/friend_level_lookup.dart';
import 'package:zen/src/features/ledger/ledger_chat_media.dart';
import 'package:zen/src/features/ledger/ledger_mail_push.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/follows.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Quiet time before reactions are bundled and passed on (a like or a
/// comment reaches the author's other friends this soon).
const Duration kReactionRelayDelay = Duration(seconds: 5);

/// The longest reactions wait to be bundled while more keep coming: a
/// lively thread is passed on about once a minute, not only once it calms
/// down.
const Duration kReactionRelayAtMost = Duration(minutes: 1);

/// Off by default (tests, previews); the real app turns it on at bootstrap.
final Provider<bool> ledgerNodeEnabledProvider = Provider<bool>(
  (Ref ref) => false,
);

/// Where the ledger keeps its files (the app's encrypted store in the app).
final Provider<LedgerDisk> ledgerDiskProvider = Provider<LedgerDisk>(
  (Ref ref) => MemoryLedgerDisk(),
);

/// Addresses of accepted friends (who the ledger syncs with).
List<String> acceptedFriendAddresses(SocialHubState state) => <String>[
  for (final FriendProfile f in state.friends.values)
    if (f.status == FriendRelationshipStatus.accepted) f.address,
];

/// What the account routing (several devices) asks the ledger.
final class LedgerAccountDirectory implements AccountDeviceDirectory {
  LedgerAccountDirectory(this.node, this.friends, {this.groupMembers});

  final LedgerNode node;

  /// Accepted friends' addresses (as the app knows them).
  final Iterable<String> Function() friends;

  /// Addresses in the groups (members who may not be friends).
  final Iterable<String> Function()? groupMembers;

  @override
  String get ownAccount => node.isReady ? node.account : '';

  @override
  String? accountOf(String address) => node.isReady
      ? node.accountOfAnyAddress(address) ?? node.unlinkedAccountOf(address)
      : null;

  @override
  String? unlinkedAccountOf(String address) =>
      node.isReady ? node.unlinkedAccountOf(address) : null;

  @override
  List<String> addressesOf(String account) =>
      node.isReady ? node.anyAddressesOf(account) : const <String>[];

  @override
  String? contactAddressOf(String account) {
    for (final String f in friends()) {
      if (node.accountOf(f) == account) {
        return f;
      }
    }
    // A group member with several devices: the address the group lists.
    for (final String m in groupMembers?.call() ?? const <String>[]) {
      if (node.accountOfAnyAddress(m) == account) {
        return m;
      }
    }
    return null;
  }
}

/// Addresses of group members (joined groups only).
List<String> groupMemberAddresses(SocialHubState state) => <String>{
  for (final GroupProfile g in state.groups.values)
    if (!g.isInvitePending) ...g.memberAddresses,
}.toList();

final class _HubChatTarget implements ChatSyncTarget {
  _HubChatTarget(this.ref);

  final Ref ref;

  SocialHubController get _hub =>
      ref.read(socialHubControllerProvider.notifier);

  @override
  List<String> conversationKeys() => _hub.conversationKeys();

  @override
  Future<List<ChatMessage>> conversationMessages(String key) =>
      _hub.conversationMessages(key);

  @override
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
    String? storedPath,
  }) => _hub.importSyncedMessage(
    key,
    message,
    bytes: bytes,
    storedPath: storedPath,
  );

  @override
  Future<void> forgetFriendFromOtherDevice(
    String address, {
    int atMillis = 0,
  }) => _hub.forgetFriendFromOtherDevice(address, atMillis: atMillis);

  @override
  Future<void> forgetGroupFromOtherDevice(String groupId) =>
      _hub.forgetGroupFromOtherDevice(groupId);
}

/// A plain name for this device, as other devices of the account show it.
String get thisDeviceName {
  if (kIsWeb) {
    return 'Przeglądarka';
  }
  if (Platform.isAndroid) {
    return 'Telefon (Android)';
  }
  if (Platform.isIOS) {
    return 'iPhone';
  }
  if (Platform.isWindows) {
    return 'Komputer (Windows)';
  }
  if (Platform.isMacOS) {
    return 'Komputer (macOS)';
  }
  return 'Komputer (Linux)';
}

/// How many friends' bridges a device connects to besides its public
/// peers: a phone one (its four public peers carry it; each connection
/// costs traffic and keep-alives), a computer five (a computer on battery
/// dials only one of them, peer_keepers.go).
int ledgerBridgeConnections({required bool phone}) => phone ? 1 : 5;

/// The running ledger node, or `null` while disabled. Reading it starts it.
final Provider<LedgerNode?> ledgerNodeProvider = Provider<LedgerNode?>((
  Ref ref,
) {
  if (!ref.watch(ledgerNodeEnabledProvider)) {
    return null;
  }
  // The Android background service runs the ledger while the app is away
  // (the app has suspended its own): it starts at once, and never makes a
  // new identity — that is the app's job, before the service ever runs.
  final bool inService = ref.read(zenHostProvider) == ZenHost.backgroundService;
  final LedgerNode node = LedgerNode(
    // Devices, not accounts: the ledger knows which device it talks to.
    transport: ref.read(meshTransportProvider),
    localAddress: () => ref.read(runtimeNodeSnapshotProvider).localAddress,
    localSessionKey: () => ref.read(runtimeNodeRuntimeProvider).sessionKey,
    deviceName: thisDeviceName,
    // Group members who are not friends: their answer tells their account,
    // so their other devices count as them too.
    greetAlso: () {
      final SocialHubState s = ref.read(socialHubControllerProvider);
      final Set<String> friends = acceptedFriendAddresses(
        s,
      ).map(PeerShareCodec.normalizeAddress).toSet();
      return groupMemberAddresses(s)
          .map(PeerShareCodec.normalizeAddress)
          .where((String a) => !friends.contains(a));
    },
    disk: ref.read(ledgerDiskProvider),
    friendAddresses: () =>
        acceptedFriendAddresses(ref.read(socialHubControllerProvider)),
    autoDownloadMedia: () => ref
        .read(appSettingsControllerProvider)
        .allowsAutoDownload(onUnmetered: UnmeteredNetwork.instance.onUnmetered),
    // The chosen bridges replace the earlier choice (dropped ones are
    // disconnected).
    onBridgesChosen: (List<String> uris) =>
        ref.read(runtimeNodeRuntimeProvider).setMeshPeers(uris),
    bridgeConnections: ledgerBridgeConnections(
      phone: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
    ),
    // On Android the background service may still be serving the ledger
    // (the app was closed): the background bridge resumes this node once
    // the service has handed it back.
    startSuspended: !inService && !kIsWeb && Platform.isAndroid,
    createIdentity: !inService,
  );
  // Device keys proven by hybrid-signed hellos and named by friends'
  // signed device records are pinned in the bridge (pq_session.go); a
  // signed key that contradicts the session, or a pin, is warned about in
  // the chat with that address.
  final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
  void warnKeyMismatch(String address) => unawaitedLogged(
    ref
        .read(socialHubControllerProvider.notifier)
        .warnDeviceKeyMismatch(address),
    context: 'Device key warning',
  );
  node
    ..onSessionKeys = (Map<String, String> keys, {bool force = false}) {
      runtime.vouchSessionKeys(keys, force: force);
    }
    ..onDeviceKeyMismatch = warnKeyMismatch
    // A friend's device its owner unlinked (lost or stolen): said in the
    // chat with that friend.
    ..onDeviceUnlinked = (String address) => unawaitedLogged(
      ref
          .read(socialHubControllerProvider.notifier)
          .warnDeviceUnlinked(address),
      context: 'Unlinked device warning',
    );
  // A friend met on a new device (theirs, or this one after a restore):
  // the profiles go both ways, so names and photos are there at once.
  node.onPeerLearnt = (String address, String account) {
    final SocialHubState social = ref.read(socialHubControllerProvider);
    String? friend;
    if (social.friendByAddress(address)?.status ==
        FriendRelationshipStatus.accepted) {
      friend = address;
    } else {
      for (final String f in acceptedFriendAddresses(social)) {
        if (node.accountOf(f) == account) {
          friend = f;
          break;
        }
      }
    }
    if (friend != null) {
      unawaitedLogged(
        ref
            .read(socialHubControllerProvider.notifier)
            .shareOwnProfileWith(friend),
        context: 'Sending the profile to a new device',
      );
    }
  };
  final StreamSubscription<String> keyConflicts = runtime.sessionKeyConflicts
      .listen(warnKeyMismatch);
  ref.onDispose(keyConflicts.cancel);
  // Until the ledger knows which devices were unlinked, the account
  // routing holds what comes and goes.
  final void Function() ledgerLoaded = ref
      .read(accountDirectoryHolderProvider)
      .expectLedger();
  unawaited(node.settled.then((_) => ledgerLoaded()));
  unawaitedLogged(node.start(), context: 'Starting the ledger failed');
  // Files shared in groups travel as blocks of this store.
  final ChatMediaBlocksHolder mediaBlocks = ref.read(
    chatMediaBlocksHolderProvider,
  )..blocks = LedgerChatMediaBlocks(node);
  ref.onDispose(() => mediaBlocks.blocks = null);
  // Posts, comments and likes reach friends who are offline through the
  // reliable queue (their mailboxes hold them while this phone is away).
  final LedgerMailPush mailPush = LedgerMailPush(
    node: node,
    isOnline: (String address) =>
        ref
            .read(socialHubControllerProvider)
            .friendByAddress(address)
            ?.isOnline ??
        false,
    send: (String address, Map<String, dynamic> payload) =>
        node.transport.send(remoteAddress: address, payload: payload),
  )..start();
  ref.onDispose(
    () => unawaitedLogged(mailPush.stop(), context: 'Stopping entry pushes'),
  );
  // Follows are signed entries; followers learn of them from hellos.
  final FollowLedger follows = FollowLedger.of(node);
  ref.onDispose(
    () =>
        unawaitedLogged(follows.dispose(), context: 'Zatrzymanie obserwowania'),
  );
  // The unwrapped account key lives only while the app is open.
  final AppSecurityService security = ref.read(appSecurityServiceProvider);
  void lockAccountKey() {
    if (security.isLocked && node.isReady) {
      node.identity.lock();
    }
  }

  security.addListener(lockAccountKey);
  // Friends with several devices look like one person to the app.
  final AccountDirectoryHolder holder = ref.read(accountDirectoryHolderProvider)
    ..directory = LedgerAccountDirectory(
      node,
      () => acceptedFriendAddresses(ref.read(socialHubControllerProvider)),
      groupMembers: () =>
          groupMemberAddresses(ref.read(socialHubControllerProvider)),
    )
    ..mirrored = ((String peer, Map<String, dynamic> payload) => ref
        .read(socialHubControllerProvider.notifier)
        .recordMirroredSend(peer, payload))
    ..friendRemoved = ((String address) => unawaitedLogged(
      node.publishForOwnDevices(kContactRemovedKind, <String, dynamic>{
        'a': address,
      }, spaceKind: 'private'),
      context: 'Saving a friend removal failed',
    ))
    ..groupLeft = ((String groupId) => unawaitedLogged(
      node.publishForOwnDevices(kContactRemovedKind, <String, dynamic>{
        'g': groupId,
      }, spaceKind: 'private'),
      context: 'Saving leaving a group failed',
    ));
  // The social hub asks friends' levels without starting the ledger.
  final FriendLevelLookup levels = ref.read(friendLevelLookupProvider)
    ..levelOf = node.levelOf
    ..unlinked = node.isUnlinkedAddress;
  ref.onDispose(() {
    if (levels.levelOf == node.levelOf) {
      levels.levelOf = null;
    }
    if (levels.unlinked == node.isUnlinkedAddress) {
      levels.unlinked = null;
    }
  });
  // Conversations are the same on every device of the account.
  final DeviceChatSync chatSync = DeviceChatSync(
    node: node,
    target: _HubChatTarget(ref),
    vault: ref.read(mediaVaultProvider),
    // Big files wait for Wi-Fi when "Media tylko przez Wi-Fi" is on.
    policy: ref.read(accountMediaPolicyProvider),
  );
  unawaitedLogged(chatSync.start(), context: 'Shared device conversations');
  final MessageTimelineStore timelines = DisappearingTimelineStore.unwrap(
    ref.read(messageTimelineStoreProvider),
  );
  if (timelines is SyncingMessageTimelineStore) {
    timelines.onNewOutgoing = chatSync.onOutgoing;
  }
  // Friends and groups are the same on every device of the account: each
  // change is saved (sealed) in the private space, and what another device
  // saved is taken in.
  Timer? contactsTimer;
  Future<void> takeContacts() async {
    final Map<String, dynamic>? backup = node.latestContacts();
    if (backup != null) {
      final SocialHubController hub = ref.read(
        socialHubControllerProvider.notifier,
      );
      await hub.importContactsBackup(
        backup,
        removedAt: node.contactRemovals(),
        backupAt: node.latestContactsMillis,
      );
      if (hub.contactsBackupBehind(backup)) {
        // This device knows of a removal (or a friendship) the newest copy
        // lacks: its own copy goes out, so the devices end up agreeing
        // whichever saved last.
        await node.publishContacts(hub.contactsBackup());
      }
    }
  }

  unawaitedLogged(
    node.start().then((_) async {
      await takeContacts();
      // What this device knows goes out once at the start when the newest
      // copy says otherwise (a removal whose copy was cut short by the
      // lock): the copy is otherwise written only on a change.
      await node.publishContacts(
        ref.read(socialHubControllerProvider.notifier).contactsBackup(),
      );
    }),
    context: 'Reading the friends backup failed',
  );
  final StreamSubscription<void> contactsSub = node.contactsChanged.listen(
    (_) => unawaitedLogged(
      takeContacts(),
      context: 'Reading the friends backup failed',
    ),
  );
  ref.listen<String>(
    socialHubControllerProvider.select(
      (SocialHubState s) => jsonEncode(contactsBackupOf(s)),
    ),
    (String? previous, String next) {
      contactsTimer?.cancel();
      contactsTimer = Timer(const Duration(seconds: 5), () {
        unawaitedLogged(
          node.publishContacts(
            ref.read(socialHubControllerProvider.notifier).contactsBackup(),
          ),
          context: 'Saving the friends backup failed',
        );
      });
    },
  );
  final Timer unmanaged = Timer(
    const Duration(seconds: 45),
    () => unawaitedLogged(
      node.resumeIfUnmanaged(),
      context: 'Emergency start of the ledger failed',
    ),
  );
  ref.listen<String>(
    socialHubControllerProvider.select(
      (SocialHubState state) =>
          (acceptedFriendAddresses(state)..sort()).join(','),
    ),
    (String? previous, String next) {
      if (previous != next) {
        unawaitedLogged(
          node.onFriendsChanged(),
          context: 'Refreshing friends in the ledger failed',
        );
      }
    },
  );
  // The profile you edit is mirrored into the public profile space,
  // with your mesh address only once something public of yours can bring
  // followers (friends know it anyway).
  Future<void> publishProfile() async {
    await node.start();
    final UserProfile me = ref.read(userProfileControllerProvider);
    final String address = profileNeedsAddress(node)
        ? ref.read(runtimeNodeSnapshotProvider).localAddress
        : '';
    // Each field goes to whom the user chose: public ones in the
    // public entry, the others sealed per audience; the photo and cover
    // are read from the vault.
    await publishOwnProfile(
      node,
      me: me,
      address: address,
      readImage: readOwnProfileImage,
      friendCount: acceptedFriendAddresses(
        ref.read(socialHubControllerProvider),
      ).length,
      followerCount: follows.followerCount,
    );
  }

  void mirrorProfile() => unawaitedLogged(
    publishProfile(),
    context: 'Saving the profile in the ledger failed',
  );
  // The numbers of friends and followers are profile fields too.
  final StreamSubscription<void> followersSub = follows.changes.listen(
    (_) => mirrorProfile(),
  );
  ref.onDispose(() => unawaited(followersSub.cancel()));
  ref.listen<int>(
    socialHubControllerProvider.select(
      (SocialHubState s) => acceptedFriendAddresses(s).length,
    ),
    (int? previous, int next) => mirrorProfile(),
  );
  // The first public post or reshare: the profile gets the address now.
  final StreamSubscription<LogEntry> profileAddressSub = node.store.added
      .listen((LogEntry e) {
        if (e.account == node.account &&
            reachesStrangers(e) &&
            (latestProfile(node, node.account)?.address.isEmpty ?? true)) {
          mirrorProfile();
        }
      });
  ref.onDispose(() => unawaited(profileAddressSub.cancel()));
  unawaitedLogged(
    node.start().then((_) => mirrorProfile()),
    context: 'Saving the profile in the ledger failed',
  );
  ref.listen<UserProfile>(
    userProfileControllerProvider,
    (UserProfile? previous, UserProfile next) => mirrorProfile(),
  );
  ref.listen<String>(
    runtimeNodeSnapshotProvider.select(
      (RuntimeTransportSnapshot s) => s.localAddress,
    ),
    (String? previous, String next) {
      mirrorProfile();
      unawaitedLogged(
        node.publishOwnDevice(),
        context: 'Saving the device address failed',
      );
    },
  );
  // Likes and comments travel along the reshare tree: after a quiet
  // moment, bundle what this circle said about posts we wrote or reshared.
  final QuietTimer relayTimer = QuietTimer(
    quiet: kReactionRelayDelay,
    atMost: kReactionRelayAtMost,
    action: () {
      final SocialHubState social = ref.read(socialHubControllerProvider);
      unawaitedLogged(
        relayReactions(
          node,
          nameOf: (String address) {
            final FriendProfile? f = social.friendByAddress(address);
            return f == null ? '' : social.nameFor(f);
          },
        ),
        context: 'Passing on a reaction failed',
      );
    },
  );
  const Set<String> relayKinds = <String>{
    kLikeKind,
    kCommentKind,
    kReactionsKind,
    kReshareKind,
    ...kReactionRelayExtraKinds,
  };
  final StreamSubscription<LogEntry> relaySub = node.store.added.listen((
    LogEntry e,
  ) {
    if (relayKinds.contains(e.kind)) {
      relayTimer.nudge();
    }
  });
  ref.onDispose(() {
    security.removeListener(lockAccountKey);
    unmanaged.cancel();
    relayTimer.cancel();
    contactsTimer?.cancel();
    unawaitedLogged(contactsSub.cancel(), context: 'Zatrzymanie kopii');
    unawaitedLogged(chatSync.stop(), context: 'Stopping shared conversations');
    if (timelines is SyncingMessageTimelineStore &&
        timelines.onNewOutgoing == chatSync.onOutgoing) {
      timelines.onNewOutgoing = null;
    }
    final AccountDeviceDirectory? directory = holder.directory;
    if (directory is LedgerAccountDirectory &&
        identical(directory.node, node)) {
      holder
        ..directory = null
        ..mirrored = null
        ..friendRemoved = null
        ..groupLeft = null;
    }
    unawaitedLogged(relaySub.cancel(), context: 'Zatrzymanie przekazywania');
    unawaitedLogged(node.stop(), context: 'Stopping the ledger failed');
  });
  return node;
});

/// Off by default (tests, previews); the real desktop app turns it on.
final Provider<bool> bridgeHostEnabledProvider = Provider<bool>(
  (Ref ref) => false,
);

/// Whether this platform is a desktop (a computer, not a phone): only
/// those can accept incoming connections and be bridges.
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Makes this computer a bridge of the mesh. `null` on phones and
/// while disabled. Reading it starts it.
final Provider<BridgeHost?> bridgeHostProvider = Provider<BridgeHost?>((
  Ref ref,
) {
  if (!ref.watch(bridgeHostEnabledProvider) || !isDesktopPlatform) {
    return null;
  }
  // The person can switch it off at the bottom of the settings.
  if (!ref.watch(
    appSettingsControllerProvider.select((AppSettings s) => s.bridgeEnabled),
  )) {
    return null;
  }
  final LedgerNode? node = ref.watch(ledgerNodeProvider);
  if (node == null) {
    return null;
  }
  final BridgeHost host = BridgeHost(node: node)..start();
  ref.onDispose(
    () => unawaitedLogged(host.stop(), context: 'Zatrzymanie mostu sieci'),
  );
  return host;
});
