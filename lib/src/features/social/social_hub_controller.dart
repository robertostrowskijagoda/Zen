import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/friends/friend_lifecycle_reducer.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/signal_routing_policy.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/calls/call_safety_cues.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/chat/attachment_transfer_runner.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/chat_attachment_transport_codec.dart';
import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/chat/conversation_history_preview.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/realtime_attachment_transfer.dart';
import 'package:zen/src/features/chat/stranger_chats.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/health/clock_skew_tracker.dart';
import 'package:zen/src/features/ledger/friend_level_lookup.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_notification_center.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_event_text.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

part 'social_hub_controller_helpers.dart';
part 'social_hub_controller_lifecycle_signal.dart';
part 'social_hub_controller_messages.dart';
part 'social_hub_controller_transfers.dart';
part 'social_hub_controller_social.dart';
part 'social_hub_controller_retention.dart';
part 'social_hub_controller_group_call.dart';
part 'social_hub_controller_profile.dart';
part 'social_hub_controller_devices.dart';
part 'social_hub_controller_disappearing.dart';
part 'social_hub_controller_strangers.dart';
part 'social_hub_controller_chat_extras.dart';

final Provider<SignalQueueStore> signalQueueStoreProvider =
    Provider<SignalQueueStore>((Ref ref) {
      return MemorySignalQueueStore();
    });

final Provider<SignalRoutingPolicy> signalRoutingPolicyProvider =
    Provider<SignalRoutingPolicy>((Ref ref) {
      return const SignalRoutingPolicy();
    });

final Provider<SocialHubState> socialHubSeedProvider = Provider<SocialHubState>(
  (Ref ref) {
    return SocialHubState.empty();
  },
);

final Provider<SocialSnapshotStore> socialSnapshotStoreProvider =
    Provider<SocialSnapshotStore>((Ref ref) {
      return MemorySocialSnapshotStore();
    });

typedef SupportDirectoryResolver = Future<Directory> Function();

final Provider<SupportDirectoryResolver> supportDirectoryResolverProvider =
    Provider<SupportDirectoryResolver>((Ref ref) {
      return ZenInstance.supportDirectory;
    });

final Provider<MessageTimelineStore> messageTimelineStoreProvider =
    Provider<MessageTimelineStore>((Ref ref) {
      return DisappearingTimelineStore(MemoryMessageTimelineStore());
    });

final Provider<AttachmentTransferStore> attachmentTransferStoreProvider =
    Provider<AttachmentTransferStore>((Ref ref) {
      return MemoryAttachmentTransferStore();
    });

final Provider<bool> socialHubAutoHydrateProvider = Provider<bool>((Ref ref) {
  return true;
});

/// How long the callee waits for the SDP offer after accepting an incoming
/// call before giving up and notifying the caller. The offer can be missing
/// after a background/foreground handoff or an app restart because it lives
/// only in memory; when the wait starts, a resend request is issued.
final Provider<Duration> callOfferWaitTimeoutProvider = Provider<Duration>((
  Ref ref,
) {
  return const Duration(seconds: 12);
});

final Provider<Duration> callRingingWaitTimeoutProvider = Provider<Duration>((
  Ref ref,
) {
  return const Duration(seconds: 45);
});

/// How often an accept that is still waiting for the SDP offer re-asks for it.
///
/// Bounded by [callOfferWaitTimeoutProvider]. Zero asks exactly once.
final Provider<Duration> callOfferResendIntervalProvider = Provider<Duration>((
  Ref ref,
) {
  return const Duration(milliseconds: 400);
});

/// How often an outgoing ringing call re-sends its invite.
///
/// The invite is a single datagram with no ACK, so one lost frame used to mean
/// a call that never rang on the other side. The callee deduplicates repeats
/// by callId, which makes re-sending safe. One small datagram per second costs
/// effectively no battery — the node and its radios run regardless — and the
/// ringing timeout is the hard stop. Zero disables re-ringing entirely.
final Provider<Duration> callReRingIntervalProvider = Provider<Duration>((
  Ref ref,
) {
  return const Duration(seconds: 1);
});

/// A friend who keeps answering pings has their "last seen" time (and the
/// time their presence was confirmed) written to the state at most this
/// often (in between it lives in memory).
const Duration kPresenceStoreEvery = Duration(minutes: 10);

final NotifierProvider<SocialHubController, SocialHubState>
socialHubControllerProvider =
    NotifierProvider<SocialHubController, SocialHubState>(
      SocialHubController.new,
    );

/// The social state for a screen that only names and lists people: it is
/// rebuilt when friends or their profiles change, not on every message,
/// call or presence tick (B3).
SocialHubState watchSocialPeople(WidgetRef ref) {
  ref.watch(
    socialHubControllerProvider.select(
      (SocialHubState s) => (s.friends, s.peerProfiles),
    ),
  );
  return ref.read(socialHubControllerProvider);
}

List buildSocialHubProviderOverrides({
  required SignalQueueStore signalQueueStore,
  required SocialSnapshotStore socialSnapshotStore,
  required MessageTimelineStore messageTimelineStore,
  required AttachmentTransferStore attachmentTransferStore,
  SupportDirectoryResolver? supportDirectoryResolver,
  bool autoHydrate = true,
  SocialHubState? seedState,
}) {
  return [
    signalQueueStoreProvider.overrideWithValue(signalQueueStore),
    socialSnapshotStoreProvider.overrideWithValue(socialSnapshotStore),
    messageTimelineStoreProvider.overrideWithValue(messageTimelineStore),
    attachmentTransferStoreProvider.overrideWithValue(attachmentTransferStore),
    if (supportDirectoryResolver != null)
      supportDirectoryResolverProvider.overrideWithValue(
        supportDirectoryResolver,
      ),
    socialHubAutoHydrateProvider.overrideWithValue(autoHydrate),
    socialHubSeedProvider.overrideWithValue(
      seedState ?? SocialHubState.empty(),
    ),
  ];
}

const FriendLifecycleReducer _friendReducer = FriendLifecycleReducer();

/// How long extra copies of one lifecycle signal are folded into the first.
const Duration _lifecycleRepeatWindow = Duration(seconds: 10);

/// Minimum spacing of invite re-sends to one peer for one group.
const Duration _groupInviteResendCooldown = Duration(seconds: 30);

const int _rejectedGroupHistoryLimit = 200;

/// Window of the limits on invitations from people who are not friends.
const Duration _strangerInviteWindow = Duration(minutes: 10);

/// Invitation signals one stranger identity may send per window (each
/// invitation arrives up to four times).
const int _maxStrangerInvitesPerWindow = 24;

/// Different strangers whose invitations may raise a notification per
/// window.
const int _maxStrangerAlertSendersPerWindow = 10;

const int _maxTrackedStrangerIdentities = 4096;

/// Window of the limit on mention notifications from one person.
const Duration _mentionAlertWindow = Duration(minutes: 10);

/// Group messages of one sender per window that may say they mention this
/// person; past it they notify like any other message.
const int kMaxMentionAlertsPerSender = 5;

/// How long reading the stored snapshot (friends, groups, the inbox) may
/// take at start before it counts as unreadable.
const Duration kSnapshotReadTimeout = Duration(seconds: 45);

/// Delays of the extra call-teardown attempts, relative to the first one.
const List<Duration> _callTeardownRetryDelays = <Duration>[
  Duration(milliseconds: 400),
  Duration(milliseconds: 1400),
];

abstract class _SocialHubControllerBase extends Notifier<SocialHubState> {
  bool _hydrationScheduled = false;
  String? _openConversationAddress;

  /// Group whose chat is on screen right now, if any.
  String? _openGroupId;

  /// Group traffic that must not raise a notification: messages for a group
  /// the user has not joined yet (they are kept, shown once they join), and
  /// messages for the group chat the user is looking at.
  bool _isSilencedGroupSignal(ZenSignal signal) {
    if (signal.type != ZenSignalType.groupMessage) {
      return false;
    }
    final GroupProfile? group = state.groups[signal.groupId ?? ''];
    if (group == null) {
      return false;
    }
    return group.isInvitePending ||
        (_openGroupId == group.id && _isUiFocused());
  }

  ZenSignal? _pendingIncomingCallOffer;
  bool _pendingIncomingCallAccept = false;
  Timer? _pendingOfferTimeoutTimer;
  Timer? _callRingingTimeoutTimer;
  Timer? _callReRingTimer;
  Timer? _callOfferResendTimer;
  String? _armedRingingCallId;

  /// Pending teardown re-sends, kept so they can be cancelled with the
  /// controller instead of firing into a disposed container.
  final Set<Timer> _callTeardownRetries = <Timer>{};

  /// Serialises the asynchronous state machines; see `receiveSignal`.
  Future<void> _signalQueue = Future<void>.value();

  /// Set from `ref.onDispose`, so queued work stops instead of reaching for a
  /// container that is being torn down.
  bool _controllerDisposed = false;

  /// Whether the stored snapshot has been read back yet.
  ///
  /// The controller starts on an empty seed and fills it in from disk a few
  /// turns later. Anything that persists in between would write that empty
  /// seed over the real snapshot — every friend, every conversation, gone, and
  /// the background service left with no peers whose calls it may accept. So a
  /// write that comes in first waits for the read instead of racing it.
  bool _hydrationCompleted = false;
  final Completer<void> _hydrationSettled = Completer<void>();

  /// Completes once hydration from persistent store has completed (or failed).
  Future<void> get whenHydrated => _hydrationSettled.future;

  /// Whether the stored friends are known yet (false while a locked app
  /// waits to read them). Also true after a read that failed: check
  /// [SocialHubState.snapshotUnreadable] before trusting an empty list.
  bool get isHydrated => _hydrationCompleted;

  /// Whether a read of the stored snapshot has come back in this run (with
  /// data or with "nothing stored"). Until then a failed read leaves the
  /// state a stand-in (see [SocialHubState.snapshotUnreadable]); after it,
  /// the state in memory is the user's own and a failed re-read changes
  /// nothing.
  bool _snapshotLoaded = false;

  /// Logged once per run: saving is paused over an unreadable snapshot.
  bool _loggedPausedSave = false;

  /// The last save failed (the app locked under it): memory holds what the
  /// store does not.
  bool _unsavedState = false;

  /// Releases the writers. Called once the read came back — or failed, because
  /// an unreadable snapshot must not block saving for the rest of the session.
  void _markHydrationSettled() {
    if (_hydrationCompleted) {
      return;
    }
    _hydrationCompleted = true;
    if (!_hydrationSettled.isCompleted) {
      _hydrationSettled.complete();
    }
  }

  /// Ids of calls whose teardown was already applied here.
  ///
  /// Teardown signals are re-sent, and both sides can hang up at once, so
  /// without this every repeat would append another "call ended" line to the
  /// conversation and re-raise the missed-call note.
  final List<String> _tornDownCallIds = <String>[];

  /// Recently handled lifecycle/group signals: fingerprint -> receipt time.
  ///
  /// Lifecycle signals are fired four times within ~1.5 s so one lost
  /// datagram cannot lose a relationship change. The receiver has to fold
  /// those copies back into one event.
  final Map<String, int> _recentLifecycleFingerprints = <String, int>{};

  /// Recent invitations (friend requests, group invites) from people who are
  /// not friends: sender identity (see
  /// [PeerShareCodec.identityKeyForAddress]) -> receipt times.
  final Map<String, List<int>> _strangerInviteTimes = <String, List<int>>{};

  /// Sender identities whose invitations recently raised a notification ->
  /// when the first one did.
  final Map<String, int> _strangerAlertSenders = <String, int>{};

  /// Whether one more invitation from [sender] (not a friend) is let in.
  ///
  /// Lifecycle signals go out four times, so a person inviting a few times
  /// in a row stays well inside the limit; a script cycling invitations from
  /// one key - or from one /64 subnet - does not.
  bool _admitStrangerInvite(String sender, int nowMillis) {
    final int windowStart = nowMillis - _strangerInviteWindow.inMilliseconds;
    _strangerInviteTimes.removeWhere((String _, List<int> times) {
      times.removeWhere((int at) => at < windowStart);
      return times.isEmpty;
    });
    final String key = PeerShareCodec.identityKeyForAddress(sender);
    final List<int> times = _strangerInviteTimes.putIfAbsent(
      key,
      () => <int>[],
    );
    if (times.length >= _maxStrangerInvitesPerWindow) {
      return false;
    }
    times.add(nowMillis);
    while (_strangerInviteTimes.length > _maxTrackedStrangerIdentities) {
      _strangerInviteTimes.remove(_strangerInviteTimes.keys.first);
    }
    return true;
  }

  /// Whether an invitation from [sender] may still ring the phone. Many
  /// different strangers inviting at once (a flood from throwaway keys) are
  /// stored, within their caps, but stay quiet past a handful.
  bool _admitStrangerAlert(String sender, int nowMillis) {
    final int windowStart = nowMillis - _strangerInviteWindow.inMilliseconds;
    _strangerAlertSenders.removeWhere((String _, int at) => at < windowStart);
    final String key = PeerShareCodec.identityKeyForAddress(sender);
    if (_strangerAlertSenders.containsKey(key)) {
      return true;
    }
    if (_strangerAlertSenders.length >= _maxStrangerAlertSendersPerWindow) {
      return false;
    }
    _strangerAlertSenders[key] = nowMillis;
    return true;
  }

  /// When each sender's recent mentions of this person were announced.
  final Map<String, List<int>> _mentionAlertTimes = <String, List<int>>{};

  /// [signal] marked as mentioning this person ([kMentionsYouKey]) when it
  /// is a group message whose text names this device, from a member of a
  /// group this device is in, and its sender is still within
  /// [kMaxMentionAlertsPerSender]. Anything else comes back unchanged.
  ZenSignal _withMentionOfSelf(ZenSignal signal, int nowMillis) {
    if (signal.type != ZenSignalType.groupMessage) {
      return signal;
    }
    final GroupProfile? group = state.groups[signal.groupId ?? ''];
    final String self = ref.read(runtimeNodeSnapshotProvider).localAddress;
    if (group == null ||
        group.isInvitePending ||
        self.isEmpty ||
        PeerShareCodec.addressesEqual(signal.sender, self) ||
        !(groupHasMember(group, signal.sender) ||
            PeerShareCodec.addressesEqual(group.createdById, signal.sender)) ||
        !mentionsAnyOf(
          signal.content ?? '',
          signalMentions(signal),
          addresses: <String>[self],
        )) {
      return signal;
    }
    final int windowStart = nowMillis - _mentionAlertWindow.inMilliseconds;
    final String key = PeerShareCodec.identityKeyForAddress(signal.sender);
    final List<int> times = _mentionAlertTimes[key] ??= <int>[];
    times.removeWhere((int at) => at < windowStart);
    if (times.length >= kMaxMentionAlertsPerSender) {
      return signal;
    }
    times.add(nowMillis);
    while (_mentionAlertTimes.length > _maxTrackedStrangerIdentities) {
      _mentionAlertTimes.remove(_mentionAlertTimes.keys.first);
    }
    return signal.withChatExtras(<String, dynamic>{
      ...?signal.chatExtras,
      kMentionsYouKey: true,
    });
  }

  /// When each (group, peer) invite was last re-sent from here.
  final Map<String, int> _groupInviteResentAtMillis = <String, int>{};
  final Set<String> _dismissedOrRejectedGroupIds = <String>{};
  final Set<String> _activeOutgoingTransfers = <String>{};
  final Map<String, RealtimeAttachmentTransferSession>
  _activeRealtimeTransfers = <String, RealtimeAttachmentTransferSession>{};

  SignalQueueStore get _queueStore => ref.read(signalQueueStoreProvider);

  SignalRoutingPolicy get _routing => ref.read(signalRoutingPolicyProvider);

  RuntimeNotificationCenter get _notificationCenter =>
      ref.read(runtimeNotificationCenterProvider);

  RuntimeSystemNotificationService get _systemNotifications =>
      ref.read(runtimeSystemNotificationServiceProvider);

  AppSecurityService get _security => ref.read(appSecurityServiceProvider);

  AppSettings get _appSettings => ref.read(appSettingsControllerProvider);

  /// How much a notification about [signal]'s conversation tells: its own
  /// level, else the setting; while this device shares its screen in a
  /// call, never more than who wrote.
  NotificationPrivacy _noticePrivacyFor(ZenSignal signal) {
    final NotificationPrivacy level = state.notificationPrivacyFor(
      conversationKeyOfSignal(signal),
      global: _appSettings.notificationPrivacy,
    );
    return screenShareHidesNotifications.value
        ? level.atLeast(NotificationPrivacy.senderOnly)
        : level;
  }

  SocialSnapshotStore get _snapshotStore =>
      ref.read(socialSnapshotStoreProvider);

  /// Next sweep of disappearing messages, and when it is due.
  Timer? _disappearTimer;
  int? _disappearAt;

  DisappearingTimelineStore? _disappearing;

  /// The timeline store with disappearing messages on top (whatever store
  /// the provider gives, wrapped once).
  DisappearingTimelineStore get _disappearingStore {
    final MessageTimelineStore raw = ref.read(messageTimelineStoreProvider);
    final DisappearingTimelineStore? have = _disappearing;
    if (have != null &&
        (identical(have, raw) || identical(have.delegate, raw))) {
      return have;
    }
    final DisappearingTimelineStore store = raw is DisappearingTimelineStore
        ? raw
        : DisappearingTimelineStore(raw);
    store
      ..timerFor = _disappearSecondsFor
      ..onExpired = _onMessageExpired
      ..onStamped = _noteExpiry;
    return _disappearing = store;
  }

  MessageTimelineStore get _messageTimelineStore => _disappearingStore;

  int _disappearSecondsFor(String key);

  Future<void> _onMessageExpired(String key, ChatMessage message);

  Future<bool> _dropDisappearedCopy(ZenSignal signal);

  void _noteExpiry(int atMillis);

  Future<void> sweepDisappearingMessages();

  Future<void> _handleDisappearTimer(ZenSignal signal, int timestamp);

  Future<void> _adoptDisappearTimerOf(ZenSignal signal, int timestamp);

  Future<void> _applyMirroredDisappearTimer(
    String peerAddress,
    Map<String, dynamic> payload,
  );

  AttachmentTransferStore get _transferStore =>
      ref.read(attachmentTransferStoreProvider);

  ChatAttachmentTransportCodec get _attachmentTransport =>
      ref.read(chatAttachmentTransportCodecProvider);

  CallMediaSessionController get _callMedia =>
      ref.read(callMediaSessionControllerProvider);

  AttachmentTransferRunner get _transferRunner =>
      const AttachmentTransferRunner();

  CreateRealtimeAttachmentTransferSession get _realtimeTransferFactory =>
      ref.read(realtimeAttachmentTransferFactoryProvider);

  bool get _isSecurityBlockingUi {
    final AppSecurityService security = _security;
    if (!security.isReady) {
      return true;
    }
    return security.encryptionEnabled &&
        security.hasPassword &&
        security.isLocked;
  }

  bool _isUiInteractive([LifecycleSnapshot? snapshot]) {
    return (snapshot ?? state.lifecycle).isInteractive &&
        !_isSecurityBlockingUi;
  }

  bool _isUiFocused([LifecycleSnapshot? snapshot]) {
    return (snapshot ?? state.lifecycle).isFocused && !_isSecurityBlockingUi;
  }

  /// Posts a system notification. Ringing-call window flags and the native
  /// popup are owned by [_syncRingingCallWindow], not by the shade entry.
  /// Posts [notification]; [about]: the signal it tells of, for the line
  /// the diagnostics log gets (kind, level, sender known, their version).
  Future<bool> _presentSystemNotification(
    RuntimeSystemNotification notification, {
    ZenSignal? about,
  }) async {
    if (about != null) {
      final FriendProfile? friend = state.friendByAddress(about.sender);
      final bool chat =
          about.type == ZenSignalType.message ||
          about.type == ZenSignalType.groupMessage;
      noticeLogs[notification] = (
        kind: switch (about.type) {
          ZenSignalType.message => 'message',
          ZenSignalType.groupMessage => 'group-message',
          ZenSignalType.friendRequest ||
          ZenSignalType.friendAccept ||
          ZenSignalType.groupInvite => 'invitation',
          _ => noticeLogKindOf(notification),
        },
        level: chat
            ? _noticePrivacyFor(about)
            : (notification.category ==
                          RuntimeSystemNotificationCategory.call ||
                      notification.category ==
                          RuntimeSystemNotificationCategory.alarm
                  ? null
                  : _appSettings.notificationPrivacy),
        known:
            friend != null &&
            friend.status == FriendRelationshipStatus.accepted &&
            (friend.hasProfileName ||
                state.nameFor(friend) != friend.displayLabel),
        version: friend == null ? null : state.peerAppVersions[friend.address],
      );
    }
    return _systemNotifications.show(notification);
  }

  Future<void> _syncRingingCallWindow() async {
    final CallSession? session = state.activeCall;
    final bool ringingIncoming =
        session != null &&
        session.isIncoming &&
        session.status == CallSessionStatus.ringing;
    final bool flutterUiVisible = state.lifecycle.isInteractive;
    if (ringingIncoming && flutterUiVisible) {
      // App is already on screen: the Flutter overlay is the UI. Show it
      // over the keyguard if the user locks the phone, but never dismiss
      // the keyguard — that would put the PIN pad on the buttons.
      await hideIncomingCallPopup();
      await setRingingCallWindowActive(true);
      return;
    }
    if (ringingIncoming &&
        !flutterUiVisible &&
        _appSettings.mutes(NoticeKind.call)) {
      // "Połączenia" are switched off: no card and no ring while Zen is in
      // the background. The call ends up in the list of notifications as
      // a missed one.
      await setRingingCallWindowActive(false);
      await hideIncomingCallPopup();
      return;
    }
    if (ringingIncoming && !flutterUiVisible) {
      // Stay in the background and raise only the native card. Bringing
      // MainActivity forward is what made the whole messenger pop up.
      await setRingingCallWindowActive(false);
      final String acceptToken = await _ensureCallAcceptToken(session);
      await showIncomingCallPopup(
        displayName: session.displayName,
        isVideo: session.kind == CallInviteKind.video,
        peerAddress: session.peerAddress,
        // The card's "Odbierz" opens the app on this route. Its token is the
        // call's own secret, so the app can tell this route from a link
        // anyone could fire at it.
        acceptRouteKey: buildCallRouteKey(
          peerAddress: session.peerAddress,
          title: session.displayName,
          autoAccept: true,
          acceptToken: acceptToken,
          callId: session.id,
        ),
      );
      return;
    }
    await setRingingCallWindowActive(false);
    await hideIncomingCallPopup();
  }

  /// The accept token of the ringing [session], created (and stored, so the
  /// other isolate can check it) on first use.
  Future<String> _ensureCallAcceptToken(CallSession session) async {
    final String? existing = session.acceptToken;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final String token = generateCallAcceptToken();
    final CallSession? current = state.activeCall;
    if (current != null && current.id == session.id) {
      state = state.copyWith(activeCall: current.copyWith(acceptToken: token));
      await _persistState();
    }
    return token;
  }

  LifecycleSnapshot _effectiveLifecycleForRouting([
    LifecycleSnapshot? snapshot,
  ]) {
    final LifecycleSnapshot current = snapshot ?? state.lifecycle;
    if (!_isSecurityBlockingUi || !current.isInteractive) {
      return current;
    }
    return LifecycleSnapshot(
      visibility: AppVisibilityState.foreground,
      generation: current.generation,
      capturedAtMillis: current.capturedAtMillis,
    );
  }

  /// Stops the outgoing invite re-ring loop.
  ///
  /// Lives on the base so every mixin can end it the moment the callee proves
  /// it knows about the call: re-inviting past that point only knocks the
  /// callee's session back into the ringing state.
  void _stopCallReRing() {
    _callReRingTimer?.cancel();
    _callReRingTimer = null;
  }

  final Set<String> _presentedCallPopupIds = <String>{};

  /// Records that the user has been presented with the interactive in-app
  /// popup for the incoming call from [peerAddress].
  ///
  /// Once seen, all system notifications in the shade are immediately
  /// dismissed and repeat/missed-call notifications are suppressed.
  Future<void> markCallPopupPresented(
    String peerAddress, [
    String? callId,
  ]) async {
    final String id = callId?.trim() ?? '';
    if (id.isNotEmpty) {
      _presentedCallPopupIds.add(id);
    }
    final CallSession? call = state.activeCall;
    if (call != null &&
        _currentCallMatches(call: call, peerAddress: peerAddress)) {
      _presentedCallPopupIds.add(call.id);
    }
    final List<InboxEntry> cleanedAlerts = _removeCallAlertsForPeer(
      state.backgroundAlerts,
      peerAddress,
    );
    final List<InboxEntry> cleanedInbox = _removeCallAlertsForPeer(
      state.inbox,
      peerAddress,
    );
    if (cleanedAlerts.length != state.backgroundAlerts.length ||
        cleanedInbox.length != state.inbox.length) {
      state = state.copyWith(
        backgroundAlerts: cleanedAlerts,
        inbox: cleanedInbox,
      );
      await _persistState();
    }
    await _dismissCallNotification(peerAddress);
  }

  List<InboxEntry> _removeCallAlertsForPeer(
    List<InboxEntry> alerts,
    String peerAddress,
  ) {
    return alerts
        .where(
          (InboxEntry entry) =>
              entry.type != InboxEntryType.callInvite ||
              !PeerShareCodec.addressesEqual(
                entry.peerAddress ?? '',
                peerAddress,
              ),
        )
        .toList(growable: false);
  }

  bool _wasCallPopupPresented(String? callId) {
    final String id = callId?.trim() ?? '';
    return id.isNotEmpty && _presentedCallPopupIds.contains(id);
  }

  /// Takes down the ringing notification for [peerAddress].
  ///
  /// It is posted `ongoing`, so without this a call the peer cancelled leaves
  /// a notification the user cannot even swipe away.
  Future<void> _dismissCallNotification(String peerAddress) async {
    try {
      await hideIncomingCallPopup();
      await setRingingCallWindowActive(false);
      await _systemNotifications.dismissSlot(
        callNotificationSlotKey(peerAddress),
      );
    } catch (error, stackTrace) {
      logZenError('Dismissing the call notification failed', error, stackTrace);
    }
  }

  /// Takes down every notification a call may have posted. A group call's
  /// ringing entry sits in the slot of the member who rang, not the group.
  Future<void> _dismissCallNotificationsFor(CallSession session) async {
    await _dismissCallNotification(session.peerAddress);
    for (final String participant in session.participantAddresses) {
      try {
        await _systemNotifications.dismissSlot(
          callNotificationSlotKey(participant),
        );
      } catch (error, stackTrace) {
        logZenError('Dismissing a call notification failed', error, stackTrace);
      }
    }
  }

  bool _isCallAlreadyTornDown(String? callId) {
    final String id = callId?.trim() ?? '';
    return id.isNotEmpty && _tornDownCallIds.contains(id);
  }

  void _rememberTornDownCall(String? callId) {
    final String id = callId?.trim() ?? '';
    if (id.isEmpty || _tornDownCallIds.contains(id)) {
      return;
    }
    _tornDownCallIds.add(id);
    if (_tornDownCallIds.length > 16) {
      _tornDownCallIds.removeAt(0);
    }
  }

  void _cancelCallTeardownRetries() {
    for (final Timer timer in _callTeardownRetries) {
      timer.cancel();
    }
    _callTeardownRetries.clear();
  }

  /// Runs [action] after everything already queued.
  ///
  /// Signal handling, hydration and the queue flush all read `state`, await
  /// encrypted stores, and write `state` back. Interleaved, the later write
  /// silently drops whatever the other one did in between, so they take turns.
  Future<void> _enqueueStateWork(Future<void> Function() action) {
    final Future<void> done = _signalQueue.then((_) {
      // The queue outlives a single turn, so the provider can already be gone
      // by the time a task gets its turn.
      if (_controllerDisposed || !ref.mounted) {
        return null;
      }
      return action();
    });
    // One failure must not wedge the chain for everything after it; the caller
    // still sees the error on its own future.
    _signalQueue = done.catchError((Object error, StackTrace stackTrace) {
      logZenError('Queued social hub work failed', error, stackTrace);
    });
    return done;
  }

  Future<void>? _activePersist;

  /// When each friend last answered a ping. A pong that changes nothing on
  /// screen only lands here: the whole state is not copied, re-encrypted
  /// and written for it (B3).
  final Map<String, int> _presenceSeenAt = <String, int>{};

  /// When each friend's presence was last confirmed, and when they last had
  /// Zen open as they told it: in memory like [_presenceSeenAt] while the
  /// state shows the same.
  final Map<String, int> _presenceConfirmedAt = <String, int>{};
  final Map<String, int> _openedAt = <String, int>{};

  /// [hub] as saved: each friend's presence with its latest confirmation
  /// from memory (and, while online, the last opening that goes with it),
  /// so what is shown after a restart ("w sieci" from 3 min ago, offline
  /// from 8 min ago, "ostatnio w sieci 2 godz. temu") is not older than it
  /// was.
  SocialHubState _withConfirmedPresence(SocialHubState hub) {
    Map<String, FriendProfile>? friends;
    for (final MapEntry<String, FriendProfile> entry in hub.friends.entries) {
      final FriendProfile friend = entry.value;
      final String key = PeerShareCodec.normalizeAddress(friend.address);
      final int confirmed = _presenceConfirmedAt[key] ?? 0;
      final int seen = _presenceSeenAt[key] ?? 0;
      final int opened = friend.presence == PeerPresence.online
          ? _openedAt[key] ?? 0
          : 0;
      if (confirmed <= friend.presenceAtMillis &&
          seen <= friend.lastPresenceAtMillis &&
          opened <= friend.lastOpenedAtMillis) {
        continue;
      }
      (friends ??= Map<String, FriendProfile>.from(
        hub.friends,
      ))[entry.key] = friend.copyWith(
        presenceAtMillis: max(confirmed, friend.presenceAtMillis),
        lastPresenceAtMillis: max(seen, friend.lastPresenceAtMillis),
        lastOpenedAtMillis: max(opened, friend.lastOpenedAtMillis),
      );
    }
    return friends == null ? hub : hub.copyWith(friends: friends);
  }

  Timer? _persistSoonTimer;

  /// Saves the state a moment later, once for a burst of small changes
  /// (presence) instead of once per change.
  void _persistSoon([Duration delay = const Duration(seconds: 5)]) {
    if (_controllerDisposed || (_persistSoonTimer?.isActive ?? false)) {
      return;
    }
    _persistSoonTimer = Timer(delay, () {
      _persistSoonTimer = null;
      unawaitedLogged(
        _enqueueStateWork(_persistState),
        context: 'Delayed social state save failed',
      );
    });
  }

  Future<void> _persistState() async {
    if (!_hydrationCompleted) {
      // See [_hydrationCompleted].
      await _hydrationSettled.future;
      if (_controllerDisposed || !ref.mounted) {
        return;
      }
    }
    while (_activePersist != null) {
      try {
        await _activePersist;
      } catch (_) {}
    }
    final Completer<void> completer = Completer<void>();
    _activePersist = completer.future;
    try {
      if (_controllerDisposed || !ref.mounted) {
        return;
      }
      if (state.snapshotUnreadable) {
        // A stand-in for a snapshot that could not be read: saving it would
        // put it over that snapshot, and one save later over its backup too,
        // turning a read error into an empty friend list for good.
        if (!_loggedPausedSave) {
          _loggedPausedSave = true;
          logZenWarning(
            'Social snapshot unreadable: saving is paused for this run.',
          );
        }
        return;
      }
      final SocialHubState saving = state;
      await _snapshotStore.save(_withConfirmedPresence(saving));
      if (identical(state, saving)) {
        _unsavedState = false;
      }
    } catch (error, stackTrace) {
      // What is in memory is newer than the store now (a save after the
      // lock): it must not be replaced by the older copy at the return to
      // the screen, and goes to the store at the next chance.
      _unsavedState = true;
      logZenError('Saving social hub state snapshot failed', error, stackTrace);
    } finally {
      _activePersist = null;
      completer.complete();
    }
  }

  /// Encrypted files: attachments, voice messages, friends' photos.
  MediaVault get _mediaVault => ref.read(mediaVaultProvider);

  /// Stores an attachment that came from someone (or from another device
  /// of this account) after checking what it really is (see
  /// `media_guard.dart`): a photo is re-encoded, a film or recording must
  /// be one, and anything else is kept as a plain file — so the type,
  /// MIME type and name to show are the ones returned here, not the
  /// sender's. The file goes into the [MediaVault]: encrypted, under a
  /// random name that says nothing about [peerAddress] or [messageId].
  Future<StoredAttachment> _persistIncomingAttachmentFile({
    required String peerAddress,
    required String messageId,
    required Uint8List bytes,
    required ChatMessageType type,
    String? mimeType,
    String? fileName,
  }) async {
    final GuardedMedia guarded = await guardIncomingMedia(
      bytes,
      declared: switch (type) {
        ChatMessageType.image => MediaKind.image,
        ChatMessageType.video => MediaKind.video,
        ChatMessageType.voice => MediaKind.audio,
        ChatMessageType.file || ChatMessageType.text => MediaKind.file,
      },
      mimeType: mimeType,
      fileName: fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : 'zalacznik-${type.name}',
    );
    final String path = await _mediaVault.put(guarded.bytes);
    return StoredAttachment(
      path: path,
      type: switch (guarded.kind) {
        MediaKind.image => ChatMessageType.image,
        MediaKind.video => ChatMessageType.video,
        MediaKind.audio => ChatMessageType.voice,
        MediaKind.file => ChatMessageType.file,
      },
      mimeType: guarded.mimeType,
      fileName: guarded.fileName,
      sizeBytes: guarded.bytes.length,
    );
  }

  /// Deletes the app's own copy of [message]'s file (in the vault); a file
  /// the user picked to send stays where it is.
  Future<void> _deleteManagedAttachmentIfPresent(ChatMessage message) async {
    final String? path = message.attachmentPath?.trim();
    if (path == null || path.isEmpty || !isMediaVaultPath(path)) {
      return;
    }
    await _mediaVault.delete(path);
  }

  Future<void> _setPendingLaunchIntent(RuntimeRouteIntent intent) async {
    state = state.copyWith(pendingLaunchIntent: intent);
    await _persistState();
  }

  Future<void> resetLocalState();

  void _bumpTimelineRevision() {
    ref.read(messageTimelineRevisionProvider.notifier).bump();
  }

  Future<void> _resumeOutgoingAttachmentTransfers();

  /// Drops unfinished incoming transfers that went stale (see the transfers
  /// part).
  Future<void> _pruneStaleIncomingTransfers();

  Future<void> _persistSignalArtifacts(ZenSignal signal, int timestamp);

  /// Conversations with people who are not friends
  /// (`social_hub_controller_strangers.dart`).
  bool _isStrangerChatPeer(String address);

  Future<Map<String, dynamic>> _strangerMessageMini(
    String peerAddress,
    String text,
  );

  Future<void> _noteStrangerMessageSent(
    String peerAddress,
    String text,
    String? name,
  );

  Future<bool> _handleStrangerChatSignal(ZenSignal signal, int timestamp);

  Future<void> _queueOutgoingAttachmentTransfer({
    required String peerAddress,
    required ChatMessage message,
    Uint8List? attachmentBytes,
    String? attachmentPath,
    required int attachmentSizeBytes,
  });

  Future<void> _persistIncomingAttachmentPlaceholder({
    required ZenSignal signal,
    required int timestamp,
  });

  Future<void> _persistIncomingAttachmentChunk({
    required ZenSignal signal,
    required int timestamp,
  });

  Future<void> _acceptIncomingRealtimeAttachmentTransfer({
    required ZenSignal signal,
    required int timestamp,
  });

  Future<void> _applyOutgoingRealtimeTransferAnswer(ZenSignal signal);

  Future<void> _closeRealtimeTransferSession(
    String peerAddress,
    String messageId,
  );

  Future<void> dismissInboxEntry(String id);

  Future<bool> _timelineHasMessage({
    required String peerAddress,
    required String messageId,
  });

  Future<void> _sendMessageAck({
    required String peerAddress,
    required String messageId,
  });

  /// Stops retrying (and relaying) anything still queued for [peer].
  /// Drops everything from [peer] kept in the queue for the app's return
  /// (a removed friend's old acceptance would be replayed over the
  /// removal).
  Future<void> _dropQueuedSignalsFrom(String peer) async {
    final List<QueuedSignal> queue = await _queueStore.load();
    final List<QueuedSignal> rest = queue
        .where(
          (QueuedSignal q) =>
              !PeerShareCodec.addressesEqual(q.signal.sender, peer),
        )
        .toList(growable: false);
    if (rest.length != queue.length) {
      await _queueStore.save(rest);
      state = state.copyWith(pendingSignalCount: rest.length);
    }
  }

  Future<void> _cancelQueuedTraffic(String peer, {String? keep}) async {
    try {
      await ref
          .read(relayEngineProvider)
          ?.cancelPendingTo(peer, keepTypes: <String>{?keep});
    } catch (error, stackTrace) {
      logZenError('Cancelling queued traffic failed', error, stackTrace);
    }
  }

  bool _isGroupRejected(String groupId) {
    return _dismissedOrRejectedGroupIds.contains(groupId) ||
        state.rejectedGroupIds.contains(groupId);
  }

  String? _pendingInviteIdFor(GroupProfile group, String address) {
    for (final MapEntry<String, String> entry
        in group.pendingInviteIds.entries) {
      if (PeerShareCodec.addressesEqual(entry.key, address)) {
        return entry.value;
      }
    }
    return null;
  }

  /// [state] with [groupId] recorded as declined/left (bounded history),
  /// together with the invitations it came from ([inviteIds]).
  SocialHubState _withRejectedGroup(
    SocialHubState current,
    String groupId, {
    List<String> inviteIds = const <String>[],
  }) {
    _dismissedOrRejectedGroupIds.add(groupId);
    final List<String> rejectedInvites = <String>[
      ...current.rejectedInviteIds,
      for (final String id in inviteIds)
        if (!current.rejectedInviteIds.contains('$groupId|$id')) '$groupId|$id',
    ];
    final List<String> next = current.rejectedGroupIds.contains(groupId)
        ? current.rejectedGroupIds
        : <String>[...current.rejectedGroupIds, groupId];
    return current.copyWith(
      rejectedGroupIds: next.length > _rejectedGroupHistoryLimit
          ? next.sublist(next.length - _rejectedGroupHistoryLimit)
          : next,
      rejectedInviteIds: rejectedInvites.length > _rejectedGroupHistoryLimit * 4
          ? rejectedInvites.sublist(
              rejectedInvites.length - _rejectedGroupHistoryLimit * 4,
            )
          : rejectedInvites,
    );
  }

  /// Whether [signal] is an invitation the user has not turned down yet: a
  /// new one after declining or leaving brings the group back.
  bool _isFreshInvitation(ZenSignal signal) {
    final String? inviteId = signal.inviteId;
    final String? groupId = signal.groupId;
    return inviteId != null &&
        groupId != null &&
        !state.rejectedInviteIds.contains('$groupId|$inviteId');
  }

  SocialHubState _withoutRejectedGroup(SocialHubState current, String groupId) {
    _dismissedOrRejectedGroupIds.remove(groupId);
    if (!current.rejectedGroupIds.contains(groupId)) {
      return current;
    }
    return current.copyWith(
      rejectedGroupIds: current.rejectedGroupIds
          .where((String id) => id != groupId)
          .toList(growable: false),
    );
  }

  /// One-shot reply to a group signal (receipt ack, or "I am not in it").
  ///
  /// Deliberately a single datagram: the other side re-sends the invite
  /// until it gets an answer, so a lost reply only costs one more round.
  void _replyToGroupSignal({
    required String peerAddress,
    required String type,
    required String groupId,
  }) {
    final String target = PeerShareCodec.normalizeAddress(peerAddress);
    if (!isRoutablePeerAddress(target)) {
      return;
    }
    unawaitedLogged(
      Future<void>(() async {
        await ref
            .read(signalTransportProvider)
            .send(
              remoteAddress: target,
              payload: <String, dynamic>{'type': type, 'groupId': groupId},
            );
      }),
      context: 'Replying "$type" for group $groupId failed',
    );
  }

  /// True when [signal] is an extra copy of a lifecycle/group signal that was
  /// handled moments ago.
  bool _isRepeatedLifecycleDelivery(ZenSignal signal, int timestamp) {
    final String? fingerprint = _lifecycleFingerprint(signal);
    if (fingerprint == null) {
      return false;
    }
    _recentLifecycleFingerprints.removeWhere(
      (String _, int seenAt) =>
          (timestamp - seenAt).abs() > _lifecycleRepeatWindow.inMilliseconds,
    );
    if (_recentLifecycleFingerprints.containsKey(fingerprint)) {
      return true;
    }
    // A different lifecycle step from the same peer (request -> cancel ->
    // request) is a real change; forget the older steps so the next repeat
    // of any of them counts as new again.
    final String senderPrefix = '${signal.sender}|';
    _recentLifecycleFingerprints.removeWhere(
      (String key, int _) =>
          key.startsWith(senderPrefix) && !key.contains('|group:'),
    );
    _recentLifecycleFingerprints[fingerprint] = timestamp;
    return false;
  }

  String? _lifecycleFingerprint(ZenSignal signal) {
    final String sender = signal.sender;
    return switch (signal.type) {
      ZenSignalType.friendAccept ||
      ZenSignalType.friendReject ||
      ZenSignalType.friendCancel ||
      ZenSignalType.friendRemove => '$sender|${signal.type.name}',
      ZenSignalType.groupLeave ||
      ZenSignalType.groupUpdate ||
      ZenSignalType.groupInviteAck =>
        '$sender|group:${signal.groupId}|${signal.type.name}',
      _ => null,
    };
  }

  /// A fresh id for one explicit invitation (see [ZenSignal.inviteId]).
  String _newInviteId() {
    final Random random = Random.secure();
    return List<String>.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Payload of a group invite; also used to sync the member list. Only a
  /// real invitation carries [inviteId]; member-list syncs never do, so they
  /// cannot bring back a group the recipient declined or left.
  Map<String, dynamic> _groupInvitePayload(
    GroupProfile group, {
    String? inviteId,
  }) {
    final String senderName = ref
        .read(userProfileControllerProvider)
        .publicName;
    return <String, dynamic>{
      'type': 'group_invite',
      'groupId': group.id,
      'groupName': group.name,
      'description': group.description,
      'avatarPreset': group.avatarPreset,
      'memberAddresses': _groupMembersWithSelf(group),
      if (senderName.trim().isNotEmpty) 'senderName': senderName.trim(),
      'inviteId': ?inviteId,
    };
  }

  /// The group's members plus this node, as every peer should see the group.
  List<String> _groupMembersWithSelf(GroupProfile group) {
    final String localAddr = ref.read(runtimeNodeSnapshotProvider).localAddress;
    return normalizedGroupMembers(<String>[
      if (localAddr.isNotEmpty) localAddr,
      ...group.memberAddresses,
    ]);
  }

  /// Re-sends every invite [peerAddress] has not confirmed yet.
  ///
  /// Called whenever the peer shows signs of life (a ping, a pong, any
  /// signal). That is what gets an invite to a phone that was offline or
  /// asleep when the group was created.
  Future<void> syncGroupInvitesToPeer(String peerAddress) async {
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    final String peer = PeerShareCodec.normalizeAddress(peerAddress);
    if (!isRoutablePeerAddress(peer)) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final GroupProfile group in state.groups.values) {
      if (!group.pendingInviteAddresses.any(
        (String member) => PeerShareCodec.addressesEqual(member, peer),
      )) {
        continue;
      }
      final String key = '${group.id}|$peer';
      final int? lastSent = _groupInviteResentAtMillis[key];
      if (lastSent != null &&
          now - lastSent < _groupInviteResendCooldown.inMilliseconds) {
        continue;
      }
      _groupInviteResentAtMillis[key] = now;
      try {
        await ref
            .read(signalTransportProvider)
            .send(
              remoteAddress: peer,
              payload: _groupInvitePayload(
                group,
                inviteId: _pendingInviteIdFor(group, peer),
              ),
            );
      } catch (error, stackTrace) {
        logZenError(
          'Re-sending group invite to $peer failed',
          error,
          stackTrace,
        );
      }
    }
  }

  Future<void> _ackOutgoingAttachmentChunk(ZenSignal signal);

  Future<void> _applyRetentionAcrossConversations({required int nowMillis});

  Future<void> _applyConversationRetention({
    required String peerAddress,
    required int nowMillis,
  });

  Future<void> _updateMessageDeliveryState({
    required String peerAddress,
    required String messageId,
    required ChatMessageDeliveryState deliveryState,
  });

  Future<void> _sendReadReceiptIfNeeded(
    String peerAddress, {
    int? readAtMillis,
  });

  void _updateFriendPreview({
    required String peerAddress,
    required String preview,
    String? displayName,
  });

  /// Replaces message [messageId] in the conversation with [peerAddress]
  /// by what [build] makes of it, or adds it: at the end, or — [byTime] —
  /// by its send time (history that may be older than what is here).
  Future<void> _upsertTimelineMessage({
    required String peerAddress,
    required String messageId,
    required ChatMessage Function(ChatMessage? existing) build,
    bool byTime = false,
  });

  /// A system line in the conversation with [peerAddress]: [event] (shown
  /// in the language of the moment) or a plain [text].
  Future<void> _appendSystemMessage({
    required String peerAddress,
    String? text,
    SocialEventText? event,
    required int timestamp,
  });

  Future<void> _sendFriendLifecycleSignal({
    required String peerAddress,
    required Map<String, dynamic> payload,
  });

  /// A group message to every other member through the reliable transport
  /// (`social_hub_controller_messages.dart`).
  Future<void> _sendGroupMessageToMembers({
    required GroupProfile group,
    required String messageId,
    required String text,
    required int timestamp,
    required Set<String> skip,
    Map<String, dynamic> extra = const <String, dynamic>{},
  });

  /// Chat messages (`social_hub_controller_messages.dart`), group messages
  /// (`social_hub_controller_social.dart`): also used to forward.
  Future<void> sendLocalMessage({
    required String peerAddress,
    required String text,
    String? displayName,
    int? sentAtMillis,
    ChatReply? replyTo,
    bool forwarded = false,
  });

  Future<void> sendLocalAttachment({
    required String peerAddress,
    Uint8List? bytes,
    String? attachmentPath,
    required String fileName,
    String? mimeType,
    String? displayName,
    int? sentAtMillis,
    ChatMessageType? type,
    int? durationMs,
    ChatReply? replyTo,
    bool forwarded = false,
  });

  Future<void> sendGroupMessage({
    required String groupId,
    required String text,
    ChatReply? replyTo,
    bool forwarded = false,
    List<Mention> mentions = const <Mention>[],
  });

  /// Reactions, edits, deletions, files in groups
  /// (`social_hub_controller_chat_extras.dart`).
  Future<void> _sendGroupFile(
    GroupProfile group,
    ChatMessage message, {
    required Set<String> skip,
  });

  Future<void> _storeIncomingGroupMessage(
    ZenSignal signal,
    String messageId,
    int timestamp,
  );

  Future<void> _handleChatChange(ZenSignal signal, int timestamp);

  Future<void> _applyMirroredChatChange(
    String peerAddress,
    Map<String, dynamic> payload,
  );

  Future<void> _sendCallSignal({
    required String remoteAddress,
    required String type,
    required CallSession session,
  });

  /// [_sendCallSignal] that swallows transport failures.
  ///
  /// Every teardown path uses it: an unreachable peer (a dead mesh route
  /// throws out of the native bridge) must never stop the local session from
  /// being torn down, or the call is stuck on screen with no way to end it —
  /// and `sendCallInvite` then refuses every new call.
  Future<void> _sendCallSignalQuietly({
    required String remoteAddress,
    required String type,
    required CallSession session,
  });

  Future<void> _handleIncomingCallOffer({
    required ZenSignal signal,
    required int timestamp,
  });

  Future<void> _handleCallOfferRequest(ZenSignal signal);

  Future<void> _handleIncomingCallAnswer(ZenSignal signal);

  Future<void> _closeCallMediaSession();

  void _armCallRingingTimeout(CallSession session);

  /// Arms the ringing timeout for whatever call is currently ringing, and
  /// cancels it as soon as no call is.
  void _syncCallRingingTimeout();

  void _handleCallMediaStatusChanged(
    String callId,
    CallMediaSessionLifecycle status,
  );

  void _handleCallMediaError(String? callId, Object error);

  GroupCallMedia get _groupMedia => ref.read(groupCallMediaProvider);

  /// Hooks the group call media up to this controller (see the group call
  /// part).
  void _wireGroupCallMedia();

  Future<void> _handleGroupCallSignal(ZenSignal signal);

  Future<void> _acceptGroupRing(CallSession session);

  Future<void> _declineGroupRing(CallSession session);

  Future<void> _expireGroupRing(CallSession session);

  Future<void> _leaveGroupCall(CallSession session);

  Future<void> _dropGroupCallsFor(String groupId);

  Future<void> _toggleGroupCall(GroupCallToggle toggle);

  /// Shares the user's profile with friends whenever it changes.
  void _watchOwnProfile();

  Future<void> _broadcastOwnProfileIfChanged();

  Future<void> _sendOwnProfileTo(String peerAddress);

  Future<void> _handleProfileUpdate(ZenSignal signal);
}

/// What the group call controls switch.
enum GroupCallToggle { mute, speaker, camera }

bool _isGroupCallSignalType(ZenSignalType type) => switch (type) {
  ZenSignalType.groupCallInvite ||
  ZenSignalType.groupCallJoin ||
  ZenSignalType.groupCallLeave ||
  ZenSignalType.groupCallState ||
  ZenSignalType.groupCallOffer ||
  ZenSignalType.groupCallAnswer ||
  ZenSignalType.groupCallDecline => true,
  _ => false,
};

final class SocialHubController extends _SocialHubControllerBase
    with
        _SocialHubLifecycleSignalMixin,
        _SocialHubMessagesMixin,
        _SocialHubTransfersMixin,
        _SocialHubSocialMixin,
        _SocialHubChatExtrasMixin,
        _SocialHubRetentionMixin,
        _SocialHubGroupCallMixin,
        _SocialHubProfileMixin,
        _SocialHubDevicesMixin,
        _SocialHubDisappearingMixin,
        _SocialHubStrangersMixin {}

/// An incoming attachment as stored (after `guardIncomingMedia`).
@immutable
final class StoredAttachment {
  const StoredAttachment({
    required this.path,
    required this.type,
    required this.mimeType,
    required this.fileName,
    required this.sizeBytes,
  });

  final String path;
  final ChatMessageType type;
  final String mimeType;
  final String fileName;
  final int sizeBytes;
}
