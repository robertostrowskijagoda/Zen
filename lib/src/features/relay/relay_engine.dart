import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

part 'relay_engine_blobs.dart';

/// A friend as the relay layer sees it.
@immutable
final class RelayFriend {
  const RelayFriend({
    required this.address,
    this.lastSeenAtMillis = 0,
    this.closeness = 1,
  });

  final String address;
  final int lastSeenAtMillis;

  /// How close this friend is (0 "Słaby znajomy", 1 "Znajomy", 2
  /// "Przyjaciel"): free mailbox places go to the closest first.
  final int closeness;
}

/// The social facts the relay layer needs, without depending on the social
/// controller itself.
abstract interface class RelayPeerSource {
  String get localAddress;

  /// False until the friend list has been loaded. Until then an empty list
  /// means "not known yet", not "no friends" — acting on it would drop every
  /// relay and announce an empty set on each app start.
  bool get isReady;

  List<RelayFriend> acceptedFriends();

  /// People this device shares a group with but is not friends with.
  ///
  /// They get this device's key and relay list only if the person opted in
  /// (see [RelayState.shareWithGroups], off by default), so that group
  /// messages to someone offline can wait in that person's mailboxes like a
  /// friend's message would. Their own announcements are accepted either way.
  List<RelayFriend> groupContacts();
}

@immutable
final class RelayConfig {
  const RelayConfig({
    this.maxRelays = 6,
    this.messageTtl = const Duration(days: 14),
    this.depositAfter = const Duration(seconds: 4),
    this.directRetrySchedule = const <Duration>[
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
      Duration(minutes: 30),
      Duration(hours: 1),
      Duration(hours: 2),
      Duration(hours: 4),
    ],
    this.depositRetryInterval = const Duration(minutes: 2),
    this.depositRetryMaxInterval = const Duration(minutes: 30),
    this.networkQuietGap = const Duration(minutes: 10),
    this.maxTrackedMessages = 1000,
    this.announceRetryInterval = const Duration(minutes: 2),
    this.pollInterval = const Duration(minutes: 5),
    this.relaySyncInterval = const Duration(minutes: 10),
    this.peerSeenThrottle = const Duration(seconds: 5),
    this.maxHeldPerRecipient = 300,
    this.maxHeldPerSender = 100,
    this.maxHeldBytesPerRecipient = 2 * 1024 * 1024,
    this.maxRelayablePayloadBytes = 48 * 1024,
    this.maxMailBatchBytes = 6 * 1024,
    this.maxSeenEntries = 5000,
    this.maxIdsPerFrame = 200,
    this.maxTombstones = 5000,
    this.maxUnvouchedHeldPerRecipient = 30,
    this.maxUnvouchedBytesPerRecipient = 256 * 1024,
    this.maxUnvouchedHeldPerNetwork = 10,
    this.maxClockSkew = const Duration(days: 1),
    this.unattributableGrace = const Duration(hours: 12),
    this.maxStrangerSeenEntries = 2000,
    this.defaultBlobQuotaBytes = 20 * 1024 * 1024,
    this.maxHeldBlobBytesTotal = 200 * 1024 * 1024,
    this.maxBlobBytes = 24 * 1024 * 1024,
    this.maxPayloadBlobBytes = 2 * 1024 * 1024,
    this.blobChunkBytes = 64 * 1024,
    this.maxBlobChunkBytes = 128 * 1024,
    this.blobWindow = 8,
    this.blobRequestTimeout = const Duration(seconds: 20),
    this.maxIncomingBlobs = 32,
    this.maxOutgoingBlobs = 64,
    this.maxBlobCopies = 3,
  });

  /// How many friends hold this device's mail.
  final int maxRelays;

  /// How long anything is kept for delivery (outbox and relays alike).
  final Duration messageTtl;

  /// How long a direct send may go unacknowledged before relays get a copy.
  final Duration depositAfter;

  /// Waits between direct tries of one payload; the last one repeats. Any
  /// sign of life from the recipient starts it over, so the long steps only
  /// spare the battery while the recipient is really away.
  final List<Duration> directRetrySchedule;

  /// Wait between deposit tries at a mailbox that did not confirm, for the
  /// first ten minutes of a payload's life; it then grows step by step up to
  /// [depositRetryMaxInterval]. A mailbox that shows up gets its copy at
  /// once either way.
  final Duration depositRetryInterval;
  final Duration depositRetryMaxInterval;

  /// No frame at all for this long, then one arrives: the network was
  /// probably gone (or changed), so everything queued is tried again now
  /// instead of at the end of its backoff.
  final Duration networkQuietGap;

  /// Outgoing chat messages whose delivery is kept for the chat
  /// ([RelayTrackedMessage]); settled ones go first.
  final int maxTrackedMessages;
  final Duration announceRetryInterval;
  final Duration pollInterval;
  final Duration relaySyncInterval;
  final Duration peerSeenThrottle;
  final int maxHeldPerRecipient;

  /// Per (recipient, sender) cap, so one noisy sender — say, a group member
  /// the recipient barely knows — can neither fill a friend's mailbox nor push
  /// other people's mail out of it.
  final int maxHeldPerSender;
  final int maxHeldBytesPerRecipient;
  final int maxRelayablePayloadBytes;

  /// Mesh signals travel as ~1.3 kB fragments and one lost fragment loses
  /// the whole signal, so batches stay small.
  final int maxMailBatchBytes;
  final int maxSeenEntries;

  /// Ids looked at in one acknowledgement, purge or mail frame. Real ones
  /// carry a few dozen; the rest of an oversized list is ignored.
  final int maxIdsPerFrame;

  /// Delivery receipts kept as a relay (the soonest-expiring go first).
  final int maxTombstones;

  /// Budget for mail handed in by senders this relay cannot vouch for:
  /// neither its owner's contacts nor holding the recipient's deposit token
  /// (strangers). That mail only ever competes with
  /// more of the same, never with mail from people the recipient knows.
  final int maxUnvouchedHeldPerRecipient;
  final int maxUnvouchedBytesPerRecipient;

  /// Per /64 network: one mesh node can use any address inside its own /64.
  final int maxUnvouchedHeldPerNetwork;

  /// How far ahead of this device's clock a sender's may run.
  final Duration maxClockSkew;

  /// How long relayed mail whose sender this device cannot identify (no key
  /// announced) is left with the relays before they are told to drop it.
  /// The sender's own direct retries still deliver it later.
  final Duration unattributableGrace;

  /// Reliable ids from people who are not contacts, remembered in memory.
  final int maxStrangerSeenEntries;

  // Attachments through mailboxes (blobs, see [RelayEngine.submitAttachment]).

  /// Bytes of attachments held per sender for each friend this device serves
  /// as a mailbox, unless the person chose otherwise
  /// ([RelayEngine.setBlobQuota]).
  final int defaultBlobQuotaBytes;

  /// Bytes of attachments held for all friends together.
  final int maxHeldBlobBytesTotal;

  /// Largest attachment (plaintext) sent or collected as a blob.
  final int maxBlobBytes;

  /// Largest reliable payload cut into a blob when it is too large for one
  /// envelope (one signal at most, so about 2 MB).
  final int maxPayloadBlobBytes;

  /// Chunk size of payload blobs (attachments use the app's own chunks).
  final int blobChunkBytes;

  /// Largest plaintext chunk taken.
  final int maxBlobChunkBytes;

  /// Chunks asked for (or handed in) at once, per blob and device.
  final int blobWindow;

  /// How long an unanswered window of chunks is waited for.
  final Duration blobRequestTimeout;

  /// Blobs being collected at once (more manifests are ignored).
  final int maxIncomingBlobs;

  /// Blobs from here not yet in the mailboxes.
  final int maxOutgoingBlobs;

  /// Mailboxes that get a copy of each blob: every copy is uploaded from the
  /// sender's phone, so not all six.
  final int maxBlobCopies;
}

/// Snapshot for the settings screen.
@immutable
final class RelayOverview {
  const RelayOverview({
    this.isAutomatic = true,
    this.relays = const <String>[],
    this.outboxCount = 0,
    this.heldEnvelopeCount = 0,
    this.heldForPeerCount = 0,
    this.publicKeyFingerprint = '',
    this.shareWithGroups = false,
    this.blobQuotaBytes = 0,
    this.heldBlobBytes = 0,
    this.outgoingBlobCount = 0,
  });

  final bool isAutomatic;

  /// Whether group members who are not friends learn this device's mailboxes
  /// (off unless the person switched it on).
  final bool shareWithGroups;

  /// Friends currently holding this device's mail.
  final List<String> relays;

  /// Messages from here still waiting for their recipient.
  final int outboxCount;

  /// Messages held here on behalf of friends.
  final int heldEnvelopeCount;
  final int heldForPeerCount;
  final String publicKeyFingerprint;

  /// Attachments this device holds per sender for each friend (0: none, or
  /// no attachment storage in this build).
  final int blobQuotaBytes;

  /// Bytes of attachments held here for friends.
  final int heldBlobBytes;

  /// Attachments from here still on their way to the mailboxes.
  final int outgoingBlobCount;
}

/// Payload types that must reach their recipient eventually.
const Set<String> kReliablePayloadTypes = <String>{
  'message',
  'message_ack',
  'message_read',
  'message_transfer_cancel',
  'friend_request',
  'friend_accept',
  'friend_reject',
  'friend_cancel',
  'friend_remove',
  'group_invite',
  'group_invite_ack',
  'group_leave',
  'group_message',
  // Group board posts; the sync between members is real-time.
  'group_post',
  'profile_update',
  'disappear_timer',
  // Meeting features: a friend offline now still gets them.
  'intent',
  'alarm',
  'alarm_resp',
  'alarm_audio',
  'alarm_ack',
  'nearby_key',
  'friend_list',
  // "Open to meet" on the graph (graph/open_to_meet.dart).
  'graph_open',
  'event',
  'event_rsvp',
  'event_pass',
  'event_plus1',
  'event_photo',
  'event_thanks',
  'ask',
  'ask_answer',
  'ask_passed',
  'table_wish',
  'circle',
  'circle_swap',
  'circle_guest',
  'food_offer',
  'food_req',
  'food_ans',
  'weekend_plan',
  'weekend_plan_ans',
  // Contact economy: introductions (gates), letters, friend-list requests,
  // gate terms, how a way through gates ended, paid first messages.
  'intro_ask',
  'intro_fwd',
  'intro_ans',
  'intro_res',
  'intro_gate',
  'intro_end',
  'intro_pay',
  'intro_paid',
  // Pyramid: records, co-signing, votes, payments, reports.
  'pyr_rec',
  'pyr_recs',
  'pyr_prop',
  'pyr_sig',
  'pyr_vote',
  'pyr_pay',
  'pyr_paysig',
  'pyr_report',
  'pyr_anon',
  'pyr_nat',
  // Dating: only between friends; the content is sealed anyway.
  'date_lantern',
  'date_back',
  'date_ask',
  'date_ask_re',
  'date_vouch_req',
  'date_vouch',
  'date_safe',
  'date_safe_ok',
  'date_loc_req',
  'date_key',
  'date_intro',
  'date_intro_re',
  // Neighbours: flats are usually not friends, so only directly.
  'flat_hello',
  'flat_nope',
  'flat_profile',
  'flat_get',
  'flat_msg',
  'flat_signup',
  'flat_signup_ok',
  'flat_house',
  'flat_join',
  'flat_leave',
  'flat_moved',
  'flat_kick',
  'flat_rekey',
  'flat_newkey',
  'flat_reveal',
  // Knocks while nobody is home (flat_door_mail.dart): to a friend's
  // mailbox door, a friend's mailbox door handed over, and passed on.
  'flat_seal',
  'flat_slot',
  'flat_held',
};

/// Reliable, but only ever sent directly: the recipient is not a friend yet,
/// so neither its relays nor its key are known.
const Set<String> _directOnlyPayloadTypes = <String>{
  'friend_request',
  // A paid first message: to and from someone who is not a friend.
  'intro_pay',
  'intro_paid',
  'flat_hello',
  'flat_nope',
  'flat_profile',
  'flat_get',
  'flat_msg',
  'flat_signup',
  'flat_signup_ok',
  'flat_house',
  'flat_join',
  'flat_leave',
  'flat_moved',
  'flat_kick',
  'flat_rekey',
  'flat_newkey',
  'flat_reveal',
  // A door never answers; a friend passes a knock on the moment the
  // resident shows up (the other mailboxes took the same knock).
  'flat_seal',
  'flat_held',
};

/// Key marking a payload as reliable: `rly_ack` echoes it back.
const String kReliableIdKey = '_rid';

/// Opt-out key: sent once, never queued (e.g. automatic replies to strangers).
const String kSendOnceKey = '_once';

/// How long (ms) a reliable payload is retried, when shorter than
/// [RelayConfig.messageTtl]; not sent along.
const String kReliableTtlKey = '_ttl';

/// Longest reliable id accepted; the app's own are about 25 characters.
const int _maxReliableIdLength = 128;

/// The one payload type whose delivery the chat shows per message (its `msgId`
/// is the chat message's id), and so the only one reported through
/// [RelayEngine.takeDeliveryReports]. Others carry a `msgId` that refers to a
/// message of the *other* side (`message_ack`, `message_read`).
const String _chatMessageType = 'message';

/// A group chat message: tracked for the chat's (aggregated) status like a
/// chat message, and reported once every member confirmed it or it expired.
const String _groupMessageType = 'group_message';

/// Delivery reports kept for the chat layer; the oldest go first.
const int _maxDeliveryReports = 200;

bool isReliablePayload(Map<String, dynamic> payload) {
  return payload[kSendOnceKey] != true &&
      kReliablePayloadTypes.contains(payload['type']);
}

/// Store-and-forward delivery.
///
/// **Direct first.** Every reliable payload gets an id (`_rid`), goes straight
/// to the recipient and waits in the outbox until the recipient answers
/// `rly_ack`. Retries back off, and restart immediately whenever the
/// recipient shows any sign of life.
///
/// **Relays second.** If the direct send is not acknowledged within
/// [RelayConfig.depositAfter], the payload is sealed for the recipient (see
/// [RelayCipher]) and deposited with each of the up to six friends the
/// *recipient* chose as relays (`rly_deposit`). Relays hold the ciphertext:
///
/// * they push it to the recipient the moment it shows up, and answer the
///   recipient's `rly_poll` when it comes online;
/// * a relay that was itself offline catches up from the others (`rly_sync`
///   exchanges held ids and delivery tombstones between co-relays);
/// * once the recipient confirms (`rly_mail_ack`) it also tells its other
///   relays (`rly_purge`), and everyone drops the copy.
///
/// **Relay sets propagate.** Each device announces its relay list, version
/// and public key to all friends (`rly_announce`) — when the set changes and
/// whenever a friend that has not confirmed the latest version shows up.
///
/// The recipient de-duplicates by `_rid`, so the same payload arriving
/// directly and from several relays is handled exactly once.
final class RelayEngine {
  RelayEngine({
    required RelayStateStore store,
    required RelayPeerSource peers,
    required Future<void> Function(
      String remoteAddress,
      Map<String, dynamic> payload,
    )
    send,
    this.config = const RelayConfig(),
    int Function()? clock,
    RelayBlobStore? blobStore,
  }) : _store = store,
       _peers = peers,
       _rawSend = send,
       _blobs = blobStore,
       _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final RelayStateStore _store;

  /// Where sealed attachment chunks are kept; `null` = no attachments through
  /// mailboxes (nothing is announced, large payloads stay direct-only).
  final RelayBlobStore? _blobs;
  final RelayPeerSource _peers;
  final Future<void> Function(String, Map<String, dynamic>) _rawSend;
  final int Function() _now;
  final RelayConfig config;

  final ValueNotifier<RelayOverview> overview = ValueNotifier<RelayOverview>(
    const RelayOverview(),
  );

  /// How many [RelayDeliveryReport]s wait for [takeDeliveryReports]. The chat
  /// layer listens to this and takes the reports whenever it is above zero.
  final ValueNotifier<int> deliveryReportCount = ValueNotifier<int>(0);

  /// Where outgoing chat messages are (see [RelayTrackedMessage]), for the
  /// bubbles' delivery status. Updated whenever the queue changes, and when
  /// a first try turns into waiting as time passes.
  final ValueNotifier<RelayProgressSnapshot> progress =
      ValueNotifier<RelayProgressSnapshot>(const RelayProgressSnapshot());

  /// Outbox ids already reported as [RelayDeliveryStatus.directOnly]. Memory
  /// only: after a restart the repeat is harmless (the chat applies it once).
  final Set<String> _reportedDirectOnly = <String>{};

  /// Payloads queued but not yet sent: they go out right after the queue is
  /// on the disk, so a crash in between never loses one that was tried.
  final List<RelayOutboxEntry> _unsent = <RelayOutboxEntry>[];

  /// Sealed envelopes per reliable id (and recipient key), so retries to
  /// offline mailboxes do not run the post-quantum encapsulation again.
  final Map<String, ({String key, Map<String, dynamic> envelope})> _sealed =
      <String, ({String key, Map<String, dynamic> envelope})>{};
  static const int _maxSealedCached = 64;

  /// When the last frame of any kind arrived (0: none yet).
  int _lastFrameAtMillis = 0;

  /// Deposits ignore their spacing once (after a network change).
  bool _depositsDueNow = false;

  /// Whether the next tick should come soon (see [wantsFrequentTicks]).
  bool _frequentTicks = true;

  RelayState? _state;
  bool _active = false;
  Future<void> _lock = Future<void>.value();
  final Random _random = Random.secure();

  // Pacing kept in memory only: after a restart re-announcing or re-polling
  // once too often is harmless.
  final Map<String, int> _lastSeenHandledAt = <String, int>{};
  final Map<String, int> _lastAnnounceAt = <String, int>{};
  final Map<String, int> _lastPollAt = <String, int>{};
  final Map<String, int> _lastSyncAt = <String, int>{};

  /// Reliable ids from people who are not contacts (friend requests,
  /// neighbours): de-duplicated in memory only, so strangers can neither
  /// grow the stored state nor push friends' receipts out of it.
  final Map<String, int> _strangerSeen = <String, int>{};

  /// Relayed envelopes this device cannot attribute -> first offered.
  final Map<String, int> _unattributableSince = <String, int>{};

  /// recipient -> envelope id -> last handed over, so a relay does not
  /// resend its whole mailbox every time the recipient shows a sign of life.
  final Map<String, Map<String, int>> _lastPushedAt =
      <String, Map<String, int>>{};

  /// Chunk windows handed to a mailbox and not confirmed yet:
  /// `blobId|relay` -> window.
  final Map<String, _BlobWindow> _blobDeposits = <String, _BlobWindow>{};

  /// Last window sent per `blobId|relay`, to space out tries to a mailbox
  /// that is offline.
  final Map<String, int> _blobDepositAt = <String, int>{};

  /// Collection progress per incoming blob (`sender|blobId`).
  final Map<String, _BlobPull> _blobPulls = <String, _BlobPull>{};

  bool get isActive => _active;

  /// Whether this engine can send, hold and collect attachments through
  /// mailboxes at all.
  bool get supportsBlobs => _blobs != null;

  String get _self => PeerShareCodec.normalizeAddress(_peers.localAddress);

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Takes the relay state over (this isolate now owns the mesh node).
  Future<void> activate() {
    return _locked(() async {
      _state = null;
      _blobDeposits.clear();
      _blobPulls.clear();
      final RelayState state = await _load();
      _active = true;
      _refreshRelaySet(state);
      // A new start of the node (an app start, a restart after the network
      // changed): whatever waits is tried again on the next tick instead of
      // at the end of its backoff.
      _retryAllSoon(state, _now());
      await _save(state);
      logZenMessage(
        'Relay engine active: ${state.currentRelays.length} relays '
        '(v${state.relaySetVersion}, '
        '${state.manualRelays == null ? 'auto' : 'manual'}), '
        '${state.outbox.length} pending, '
        '${state.mailbox.length} peers held for, '
        '${state.peers.length} known peers.',
      );
      final int now = _now();
      // Fresh ownership of the node: ask the relays for anything that piled
      // up, and make sure every friend knows where to leave mail.
      for (final String relay in state.currentRelays) {
        _lastPollAt[relay] = now;
        await _sendQuietly(relay, <String, dynamic>{'type': 'rly_poll'});
      }
    });
  }

  /// Drops the cached state; another isolate may write it from now on.
  void deactivate() {
    _active = false;
    _state = null;
  }

  // ---------------------------------------------------------------------------
  // Outgoing
  // ---------------------------------------------------------------------------

  /// Queues [payload] for reliable delivery and makes the first direct try,
  /// once the queue holding it is on the disk.
  ///
  /// Never throws for transport problems: the payload is safely queued, and
  /// "the node is down right now" is exactly what the queue is for.
  Future<void> submit(String recipient, Map<String, dynamic> payload) {
    return _locked(() async {
      final RelayState state = await _load();
      await _enqueue(
        state,
        PeerShareCodec.normalizeAddress(recipient),
        payload,
        _now(),
      );
      await _save(state);
    });
  }

  /// [payload] sealed now for [recipient], as one `rly_deposit` frame per
  /// mailbox the recipient chose: handed in later by a node that holds none
  /// of this device's keys (the alarm kit of the locked Android service).
  /// The payload's [kReliableIdKey] becomes the envelope's id (`id`
  /// below). Nothing is queued here. Empty while this isolate does not own
  /// the relay state, or the recipient's key or mailboxes are not known.
  Future<List<({String mailbox, String id, Map<String, dynamic> frame})>>
  presealDeposits(String recipient, Map<String, dynamic> payload) {
    return _locked(() async {
      const List<({String mailbox, String id, Map<String, dynamic> frame})>
      none = <({String mailbox, String id, Map<String, dynamic> frame})>[];
      if (!_active) {
        return none;
      }
      final RelayState state = await _load();
      final String to = PeerShareCodec.normalizeAddress(recipient);
      final RelayIdentity? identity = state.identity;
      final RelayPeerInfo? info = state.peers[to];
      final RelayPublicKeys? recipientKey = info?.keys;
      if (identity == null || info == null || recipientKey == null) {
        return none;
      }
      final List<String> mailboxes = <String>[
        for (final String relay in info.relays)
          if (relay != _self && relay != to) relay,
      ];
      if (mailboxes.isEmpty) {
        return none;
      }
      final int now = _now();
      final String rid = _newReliableId();
      final RelayOutboxEntry entry = RelayOutboxEntry(
        rid: rid,
        recipient: to,
        payload: <String, dynamic>{...payload, kReliableIdKey: rid},
        createdAtMillis: now,
        expiresAtMillis: now + config.messageTtl.inMilliseconds,
        relayable: true,
      );
      final RelayEnvelope envelope = await _seal(identity, recipientKey, entry);
      final Map<String, dynamic> wire = <String, dynamic>{
        ...envelope.toJson(),
        if (info.depositToken != null) 'tk': info.depositToken,
      };
      return <({String mailbox, String id, Map<String, dynamic> frame})>[
        for (final String mailbox in mailboxes)
          (
            mailbox: mailbox,
            id: rid,
            frame: <String, dynamic>{'type': 'rly_deposit', 'env': wire},
          ),
      ];
    });
  }

  /// Puts [payload] into the outbox for [to]; returns its reliable id. The
  /// caller saves, and the first direct try goes out right after the save.
  Future<String> _enqueue(
    RelayState state,
    String to,
    Map<String, dynamic> payload,
    int now,
  ) async {
    final String rid = (payload[kReliableIdKey] as String?) ?? _newReliableId();
    final Object? ttl = payload[kReliableTtlKey];
    final int life = ttl is int && ttl > 0
        ? min(ttl, config.messageTtl.inMilliseconds)
        : config.messageTtl.inMilliseconds;
    final Map<String, dynamic> wire = Map<String, dynamic>.from(payload)
      ..remove(kSendOnceKey)
      ..remove(kReliableTtlKey)
      ..[kReliableIdKey] = rid;
    final bool relayable =
        !_directOnlyPayloadTypes.contains(wire['type']) &&
        utf8.encode(jsonEncode(wire)).length <= config.maxRelayablePayloadBytes;
    final RelayOutboxEntry entry = _scheduleNextDirect(
      RelayOutboxEntry(
        rid: rid,
        recipient: to,
        payload: wire,
        createdAtMillis: now,
        expiresAtMillis: now + life,
        relayable: relayable,
      ),
      now,
    );
    state.outbox[rid] = entry;
    _unsent.add(entry);
    _track(state, entry, now);
    return rid;
  }

  // ---------------------------------------------------------------------------
  // Delivery of chat messages, for the chat's status
  // ---------------------------------------------------------------------------

  /// The chat message [payload] stands for, if its delivery is tracked: a
  /// chat or group message, or the manifest of a chat attachment.
  static String? _trackedIdOf(Map<String, dynamic> payload) {
    final Object? type = payload['type'];
    final bool tracked =
        type == _chatMessageType ||
        type == _groupMessageType ||
        (type == kBlobManifestType &&
            payload['k'] == RelayBlobKind.attachment.wire);
    final Object? id = payload['msgId'];
    return tracked && id is String && id.isNotEmpty ? id : null;
  }

  void _track(RelayState state, RelayOutboxEntry entry, int now) {
    final String? id = _trackedIdOf(entry.payload);
    if (id == null) {
      return;
    }
    final Object? group = entry.payload['groupId'];
    final RelayTrackedMessage tracked = state.tracked.putIfAbsent(
      id,
      () => RelayTrackedMessage(
        messageId: id,
        createdAtMillis: now,
        groupId: entry.payload['type'] == _groupMessageType && group is String
            ? group
            : null,
      ),
    );
    tracked.pending[entry.recipient] = entry.rid;
    tracked.delivered.remove(entry.recipient);
    tracked.expired.remove(entry.recipient);
    tracked.settledAtMillis = 0;
    _capTracked(state);
  }

  /// [entry] was confirmed by its recipient ([delivered]) or expired.
  void _settleTracked(
    RelayState state,
    RelayOutboxEntry entry, {
    required bool delivered,
    required int now,
  }) {
    final String? id = _trackedIdOf(entry.payload);
    final RelayTrackedMessage? tracked = id == null ? null : state.tracked[id];
    if (tracked == null || tracked.pending[entry.recipient] != entry.rid) {
      return;
    }
    tracked.pending.remove(entry.recipient);
    (delivered ? tracked.delivered : tracked.expired).add(entry.recipient);
    if (!tracked.isSettled) {
      return;
    }
    tracked.settledAtMillis = now;
    final String? groupId = tracked.groupId;
    if (groupId == null) {
      return; // a chat message has its own receipt (and expiry report)
    }
    state.deliveryReports.add(
      RelayDeliveryReport(
        rid: entry.rid,
        recipient: entry.recipient,
        messageId: tracked.messageId,
        status: tracked.expired.isEmpty
            ? RelayDeliveryStatus.delivered
            : RelayDeliveryStatus.expired,
        atMillis: now,
        groupId: groupId,
      ),
    );
    final int excess = state.deliveryReports.length - _maxDeliveryReports;
    if (excess > 0) {
      state.deliveryReports.removeRange(0, excess);
    }
  }

  /// Keeps [RelayState.tracked] within [RelayConfig.maxTrackedMessages]:
  /// settled messages go first, oldest first; and none outlives the time a
  /// message may wait.
  void _capTracked(RelayState state, {int? now}) {
    if (now != null) {
      final int keep = config.messageTtl.inMilliseconds;
      state.tracked.removeWhere(
        (String _, RelayTrackedMessage m) =>
            (m.isSettled && now - m.settledAtMillis > keep) ||
            now - m.createdAtMillis > keep * 2,
      );
    }
    final int excess = state.tracked.length - config.maxTrackedMessages;
    if (excess <= 0) {
      return;
    }
    final List<RelayTrackedMessage> order = state.tracked.values.toList()
      ..sort((RelayTrackedMessage a, RelayTrackedMessage b) {
        if (a.isSettled != b.isSettled) {
          return a.isSettled ? -1 : 1;
        }
        return a.createdAtMillis.compareTo(b.createdAtMillis);
      });
    for (final RelayTrackedMessage m in order.take(excess)) {
      state.tracked.remove(m.messageId);
    }
  }

  /// The mailboxes friends announced: canonical address → the friends that
  /// hold its mail. Shared files of a friend (films) can be fetched from
  /// them too, and a device sees here whom it serves as a mailbox.
  Future<Map<String, List<String>>> announcedMailboxes() {
    return _locked(() async {
      final RelayState state = await _load();
      return <String, List<String>>{
        for (final RelayPeerInfo p in state.peers.values)
          if (p.relays.isNotEmpty) p.address: List<String>.of(p.relays),
      };
    });
  }

  /// Who confirmed the chat message [messageId] (canonical addresses); for
  /// sending it again only to whoever is still missing it.
  Future<Set<String>> deliveredRecipientsOf(String messageId) {
    return _locked(() async {
      final RelayState state = await _load();
      return Set<String>.of(
        state.tracked[messageId]?.delivered ?? const <String>{},
      );
    });
  }

  RelayProgressSnapshot _progressOf(RelayState state, int now) {
    final Map<String, MessageDeliveryProgress> messages =
        <String, MessageDeliveryProgress>{};
    for (final RelayTrackedMessage tracked in state.tracked.values) {
      int sending = 0;
      int waiting = 0;
      int inMailboxes = 0;
      int copies = 0;
      bool heldBySelf = false;
      tracked.pending.forEach((String recipient, String rid) {
        final RelayOutboxEntry? entry = state.outbox[rid];
        if (entry == null) {
          sending++;
          return;
        }
        final bool own = _holdsOwnCopy(state, entry);
        final int held = _mailboxCopiesOf(entry) + (own ? 1 : 0);
        if (held > 0) {
          inMailboxes++;
          copies += held;
          heldBySelf = heldBySelf || own;
        } else if (entry.directAttempts <= 1 &&
            now - entry.createdAtMillis <
                config.depositAfter.inMilliseconds * 2) {
          sending++;
        } else {
          waiting++;
        }
      });
      messages[tracked.messageId] = MessageDeliveryProgress(
        recipients:
            tracked.pending.length +
            tracked.delivered.length +
            tracked.expired.length,
        delivered: tracked.delivered.length,
        failed: tracked.expired.length,
        sending: sending,
        waitingHere: waiting,
        inMailboxes: inMailboxes,
        mailboxCopies: copies,
        heldBySelf: heldBySelf,
      );
    }
    return RelayProgressSnapshot(
      ready: true,
      messages: Map<String, MessageDeliveryProgress>.unmodifiable(messages),
    );
  }

  /// Copies of [entry] that the recipient's other mailboxes confirmed.
  static int _mailboxCopiesOf(RelayOutboxEntry entry) {
    if (entry.blobId != null || entry.payload['type'] == kBlobManifestType) {
      // Only useful where the whole blob is held too.
      return entry.blobHeldBy.length;
    }
    return entry.depositedTo.length;
  }

  /// Whether this device holds [entry] for its recipient as one of the
  /// recipient's own mailboxes.
  bool _holdsOwnCopy(RelayState state, RelayOutboxEntry entry) {
    if (state.mailbox[entry.recipient]?.containsKey(entry.rid) ?? false) {
      return true;
    }
    final String? blobId = entry.blobId ?? _blobIdOfManifest(entry);
    return blobId != null &&
        state.outBlobs.containsKey(blobId) &&
        (state.peers[entry.recipient]?.relays.contains(_self) ?? false);
  }

  static String? _blobIdOfManifest(RelayOutboxEntry entry) {
    final Object? blobId = entry.payload['b'];
    return entry.payload['type'] == kBlobManifestType && blobId is String
        ? blobId
        : null;
  }

  void _publishProgress(RelayState state) {
    final RelayProgressSnapshot next = _progressOf(state, _now());
    if (next != progress.value) {
      progress.value = next;
    }
  }

  /// Whether the periodic work should run at its short interval: a first
  /// try or a deposit is due soon, attachments are moving, or frames came
  /// in lately. Otherwise a slow tick does (see `ReliableSignalTransport`),
  /// which spares the battery while everything just waits.
  bool get wantsFrequentTicks => _frequentTicks;

  bool _computeFrequentTicks(RelayState state, int now) {
    const int soon = 30 * 1000;
    if (_blobDeposits.isNotEmpty || _blobPulls.isNotEmpty) {
      return true;
    }
    if (_lastFrameAtMillis > 0 && now - _lastFrameAtMillis < 60 * 1000) {
      return true;
    }
    for (final RelayOutboxEntry entry in state.outbox.values) {
      if (entry.nextDirectAttemptAtMillis - now < soon ||
          now - entry.createdAtMillis <
              config.depositAfter.inMilliseconds * 3) {
        return true;
      }
    }
    return false;
  }

  /// Makes everything queued due now: on the next tick each payload is tried
  /// directly and each mailbox that has not confirmed gets its copy.
  void _retryAllSoon(RelayState state, int now) {
    for (final RelayOutboxEntry entry in state.outbox.values.toList()) {
      if (entry.nextDirectAttemptAtMillis > now) {
        state.outbox[entry.rid] = entry.copyWith(
          nextDirectAttemptAtMillis: now,
        );
      }
    }
    _depositsDueNow = true;
    _frequentTicks = true;
  }

  /// Hands the chat layer what it must not keep believing about its queued
  /// messages, and forgets it here. Each [RelayDeliveryReport] names the chat
  /// message (`messageId`, in the conversation with `recipient`):
  ///
  /// * [RelayDeliveryStatus.directOnly] — too large for the mailboxes, so it
  ///   only arrives if both devices are online together. Reported once the
  ///   mailboxes would have received a copy ([RelayConfig.depositAfter]) and
  ///   nobody has acknowledged it yet.
  /// * [RelayDeliveryStatus.expired] — dropped from the queue after
  ///   [RelayConfig.messageTtl] without an acknowledgement: it failed.
  ///
  /// The reports live in the stored state until taken, so they are not lost
  /// when the queue was last worked on by another isolate (the Android
  /// background service) or before the chat layer was listening. Reports of a
  /// message that was acknowledged in the meantime are withdrawn, but the
  /// chat's own delivery receipt (`message_ack`) can still outrun one: apply a
  /// report only to a message that is still waiting, never to a delivered one.
  ///
  /// Returns nothing while this isolate does not own the mesh node (the
  /// owner is the only writer of the stored state); the reports are still
  /// there after [activate]. Watch [deliveryReportCount] to know when to call.
  Future<List<RelayDeliveryReport>> takeDeliveryReports() {
    return _locked(() async {
      if (!_active) {
        return const <RelayDeliveryReport>[];
      }
      final RelayState state = await _load();
      if (state.deliveryReports.isEmpty) {
        return const <RelayDeliveryReport>[];
      }
      final List<RelayDeliveryReport> taken = List<RelayDeliveryReport>.of(
        state.deliveryReports,
      );
      state.deliveryReports.clear();
      try {
        await _save(state);
      } catch (_) {
        // Not stored as taken: they must be offered again.
        state.deliveryReports.insertAll(0, taken);
        rethrow;
      }
      return taken;
    });
  }

  /// Queues delivery news about [entry] for the chat layer; only chat messages
  /// are reported. Returns whether the queue changed.
  bool _report(
    RelayState state,
    RelayOutboxEntry entry,
    RelayDeliveryStatus status,
    int now,
  ) {
    final Object? messageId = entry.payload['msgId'];
    // An attachment's manifest stands for its chat message.
    final bool chatMessage =
        entry.payload['type'] == _chatMessageType ||
        (entry.payload['type'] == kBlobManifestType &&
            entry.payload['k'] == RelayBlobKind.attachment.wire);
    if (!chatMessage ||
        messageId is! String ||
        messageId.isEmpty ||
        state.deliveryReports.any(
          (RelayDeliveryReport r) => r.rid == entry.rid && r.status == status,
        )) {
      return false;
    }
    state.deliveryReports.add(
      RelayDeliveryReport(
        rid: entry.rid,
        recipient: entry.recipient,
        messageId: messageId,
        status: status,
        atMillis: now,
      ),
    );
    final int excess = state.deliveryReports.length - _maxDeliveryReports;
    if (excess > 0) {
      state.deliveryReports.removeRange(0, excess);
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Incoming
  // ---------------------------------------------------------------------------

  /// Handles one incoming frame; returns the frames the app should process.
  Future<List<SignalTransportFrame>> handleIncoming(
    SignalTransportFrame frame,
  ) {
    return _locked(() async {
      final String from = PeerShareCodec.normalizeAddress(frame.from);
      final RelayState state = await _load();
      final Object? rawType = frame.payload['type'];
      final String type = rawType is String ? rawType : '';
      final List<SignalTransportFrame> forward = <SignalTransportFrame>[];
      bool changed = false;
      final int arrivedAt = _now();
      if (_active &&
          _lastFrameAtMillis > 0 &&
          arrivedAt - _lastFrameAtMillis >=
              config.networkQuietGap.inMilliseconds) {
        // Nothing at all came in for a long while: the network was most
        // likely gone or changed. Whatever waits goes out again now.
        _retryAllSoon(state, arrivedAt);
        changed = true;
      }
      _lastFrameAtMillis = arrivedAt;
      if (type.startsWith('rly_')) {
        changed = await _handleProtocolFrame(
          state,
          from,
          type,
          frame.payload,
          forward,
        );
      } else if (frame.payload[kReliableIdKey] is String) {
        changed = await _acceptReliable(state, from, frame, forward);
      } else {
        forward.add(frame);
      }
      if (forward.any(
        (SignalTransportFrame f) => f.payload['type'] == kBlobManifestType,
      )) {
        // Blob manifests are the relay layer's own: they become the blob's
        // collection (and, for an attachment, the chat's placeholder).
        final List<SignalTransportFrame> kept = <SignalTransportFrame>[];
        for (final SignalTransportFrame f in forward) {
          if (f.payload['type'] == kBlobManifestType) {
            changed =
                await _acceptBlobManifest(state, f, kept, via: from) || changed;
          } else {
            kept.add(f);
          }
        }
        forward
          ..clear()
          ..addAll(kept);
      }
      changed = await _onPeerSeen(state, from) || changed;
      if (changed) {
        await _save(state);
      }
      return forward;
    });
  }

  Future<bool> _acceptReliable(
    RelayState state,
    String from,
    SignalTransportFrame frame,
    List<SignalTransportFrame> forward,
  ) async {
    final String rid = frame.payload[kReliableIdKey] as String;
    if (rid.isEmpty || rid.length > _maxReliableIdLength) {
      return false; // nothing this app sends
    }
    await _sendQuietly(from, <String, dynamic>{'type': 'rly_ack', 'rid': rid});
    final String key = '$from|$rid';
    final int now = _now();
    if (state.seen.containsKey(key) || (_strangerSeen[key] ?? 0) > now) {
      if (frame.payload['type'] == kBlobManifestType) {
        // The sender is still retrying a blob that was collected long ago.
        await _remindBlobCollected(state, from, frame.payload['b']);
      }
      return false;
    }
    forward.add(frame);
    if (_peers.isReady && !_isContact(from)) {
      // A friend request or a neighbour: remembered in memory only.
      _strangerSeen.remove(key);
      _strangerSeen[key] = now + config.messageTtl.inMilliseconds;
      while (_strangerSeen.length > config.maxStrangerSeenEntries) {
        _strangerSeen.remove(_strangerSeen.keys.first);
      }
      return false;
    }
    state.seen[key] = now + config.messageTtl.inMilliseconds;
    return true;
  }

  Future<bool> _handleProtocolFrame(
    RelayState state,
    String from,
    String type,
    Map<String, dynamic> payload,
    List<SignalTransportFrame> forward,
  ) async {
    switch (type) {
      case 'rly_ack':
        final RelayOutboxEntry? entry = state.outbox[payload['rid']];
        if (entry != null && entry.recipient == from) {
          state.outbox.remove(entry.rid);
          _sealed.remove(entry.rid);
          // Arrived after all: whatever was about to be said about it is stale.
          state.deliveryReports.removeWhere(
            (RelayDeliveryReport r) => r.rid == entry.rid,
          );
          _reportedDirectOnly.remove(entry.rid);
          _settleTracked(state, entry, delivered: true, now: _now());
          // Our own copy as one of the recipient's mailboxes is not needed
          // any more either; remembered as delivered, so a co-relay's late
          // copy is not taken in again.
          _dropDelivered(
            state,
            recipient: entry.recipient,
            ids: <String>[entry.rid],
          );
          final String? blobId = entry.blobId;
          if (blobId != null) {
            // Its copy for the mailboxes is not needed any more.
            final RelayBlobOut? blob = state.outBlobs[blobId];
            if (blob != null) {
              state.outbox.remove(blob.manifestRid);
              await _dropOutBlob(state, blob);
            }
          }
          return true;
        }
        return false;
      case 'rly_announce':
        return _handleAnnounce(state, from, payload);
      case 'rly_announce_ack':
        return _handleAnnounceAck(state, from, payload);
      case 'rly_deposit':
        return _handleDeposit(state, from, payload['env']);
      case 'rly_deposit_ack':
        final RelayOutboxEntry? entry = state.outbox[payload['id']];
        if (entry == null ||
            entry.depositedTo.contains(from) ||
            !(state.peers[entry.recipient]?.relays.contains(from) ?? false)) {
          return false;
        }
        state.outbox[entry.rid] = entry.copyWith(
          depositedTo: <String>[...entry.depositedTo, from],
        );
        return true;
      case 'rly_poll':
        // Asked for explicitly: everything, even what went out a moment ago.
        await _pushMail(state, from, force: true);
        return false;
      case 'rly_mail':
        return _handleMail(state, from, payload['items'], forward);
      case 'rly_mail_ack':
      case 'rly_purge':
        // Only the recipient itself can clear its mail (mesh addresses are
        // authenticated), and only what is actually held for it.
        return _dropDelivered(state, recipient: from, ids: payload['ids']);
      case 'rly_sync':
        return _handleSync(state, from, payload);
      case 'rly_bput':
        return _handleBlobPut(state, from, payload);
      case 'rly_bput_ack':
        return _handleBlobPutAck(state, from, payload);
      case 'rly_bput_no':
        return _handleBlobRefused(state, from, payload);
      case 'rly_bget':
        await _handleBlobGet(state, from, payload);
        return false;
      case 'rly_bchunk':
        return _handleBlobChunk(state, from, payload, forward);
      case 'rly_bnone':
        await _handleBlobNone(state, from, payload);
        return false;
      case 'rly_bdrop':
        return _handleBlobDrop(state, from, payload);
      case 'rly_bdone':
        return _handleBlobDone(state, from, payload);
      case 'rly_sync_want':
        final String recipient = PeerShareCodec.normalizeAddress(
          payload['r'] as String? ?? '',
        );
        if (!_isCoRelay(state, recipient, from)) {
          return false;
        }
        await _sendHeld(
          state,
          from,
          recipient,
          _stringList(payload['ids'], limit: config.maxIdsPerFrame),
        );
        return false;
      default:
        return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Announcements
  // ---------------------------------------------------------------------------

  bool _handleAnnounce(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) {
    if (!_isContact(from)) {
      // Relay sets are only taken from friends and group members; an
      // unconfirmed announcement is simply re-sent once the relationship is
      // in place.
      return false;
    }
    final int version = (payload['v'] as num?)?.toInt() ?? 0;
    final Uint8List? publicKey = decodeRelayKey(payload['pk']);
    final Uint8List? pqPublicKey = decodeHybridPublicKey(payload['pq']);
    final Object? token = payload['tk'];
    final RelayPeerInfo? known = state.peers[from];
    unawaited(
      _sendQuietly(from, <String, dynamic>{
        'type': 'rly_announce_ack',
        'v': version,
      }),
    );
    if (known != null &&
        known.version > version &&
        known.publicKey != null &&
        listEquals(known.publicKey, publicKey)) {
      return false; // stale copy
    }
    final List<String> relays =
        _stringList(payload['relays'], limit: config.maxRelays * 4)
            .map(PeerShareCodec.normalizeAddress)
            .where((String a) => a.isNotEmpty && a != from)
            .take(config.maxRelays)
            .toList(growable: false);
    final Map<String, int> blobRelaysBefore = _blobRelaysOf(state);
    state.peers[from] = RelayPeerInfo(
      address: from,
      publicKey: publicKey ?? known?.publicKey,
      pqPublicKey: pqPublicKey ?? known?.pqPublicKey,
      relays: relays,
      version: version,
      updatedAtMillis: _now(),
      // Sent only to the peer's relays.
      depositKey: decodeRelayKey(payload['dk']),
      depositToken: token is String && token.isNotEmpty && token.length <= 64
          ? token
          : null,
      blobQuotaBytes: max(0, _intOf(payload['bq'])),
      blobRelays: _blobRelaysFrom(payload['br'], relays),
    );
    if (_blobs != null &&
        state.currentRelays.contains(from) &&
        !mapEquals(blobRelaysBefore, _blobRelaysOf(state))) {
      // One of our mailboxes started (or stopped) holding attachments:
      // friends have to hear it to leave attachments with it.
      state.relaySetVersion += 1;
      _lastAnnounceAt.clear();
    }
    return true;
  }

  bool _handleAnnounceAck(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) {
    final int? version = (payload['v'] as num?)?.toInt();
    // Announcements only go to contacts, so only their confirmations count;
    // anything else would just grow the stored state.
    if (version == null ||
        version > state.relaySetVersion ||
        state.announcedVersions[from] == version ||
        !_shouldAnnounceTo(state, from)) {
      return false;
    }
    state.announcedVersions[from] = version;
    return true;
  }

  /// The announcement for [to]: our key and relays, the token [to] shows
  /// our relays when it leaves mail for us, and — for our relays only — the
  /// key that checks those tokens.
  Map<String, dynamic> _announcement(RelayState state, String to) {
    final RelayIdentity identity = state.identity!;
    final Uint8List depositKey = _depositKeyOf(identity);
    return <String, dynamic>{
      'type': 'rly_announce',
      'pk': identity.publicKeyBase64,
      if (identity.pqPublicKey != null)
        'pq': base64Url.encode(identity.pqPublicKey!),
      'relays': state.currentRelays,
      'v': state.relaySetVersion,
      'tk': _depositToken(depositKey, recipient: _self, sender: to),
      if (state.currentRelays.contains(to)) 'dk': base64Url.encode(depositKey),
      if (_blobs != null) ...<String, dynamic>{
        if (_blobQuota(state) > 0) 'bq': _blobQuota(state),
        'br': _blobRelaysOf(state),
      },
    };
  }

  /// Secret shared with this device's relays, derived from its identity so
  /// it needs no storage of its own.
  static Uint8List _depositKeyOf(RelayIdentity identity) => Uint8List.fromList(
    crypto.Hmac(
      crypto.sha256,
      identity.privateKey,
    ).convert(utf8.encode('zen.relay.deposit-key.v1')).bytes,
  );

  /// Proof that [sender] is someone [recipient] announced itself to.
  static String _depositToken(
    Uint8List depositKey, {
    required String recipient,
    required String sender,
  }) {
    final List<int> mac = crypto.Hmac(crypto.sha256, depositKey)
        .convert(utf8.encode('zen.relay.deposit-token.v1|$recipient|$sender'))
        .bytes;
    return base64Url.encode(mac.sublist(0, 16));
  }

  /// Re-derives this device's relay set; bumps the version when it changed.
  ///
  /// Automatic mode is sticky on purpose: a relay stays until it stops being
  /// a friend, and only vacancies are filled with the most recently seen
  /// friends. Re-ranking on every presence change would re-announce to every
  /// friend all the time and scatter the mail across ever-changing devices.
  bool _refreshRelaySet(RelayState state) {
    if (!_peers.isReady) {
      return false;
    }
    final List<RelayFriend> friends = _peers.acceptedFriends();
    final Set<String> friendAddresses =
        friends
            .map((RelayFriend f) => PeerShareCodec.normalizeAddress(f.address))
            .toSet()
          ..remove(_self);
    final List<String> next;
    final List<String>? manual = state.manualRelays;
    if (manual != null) {
      next = manual
          .map(PeerShareCodec.normalizeAddress)
          .where(friendAddresses.contains)
          .toSet()
          .take(config.maxRelays)
          .toList(growable: false);
    } else {
      final List<String> kept = state.currentRelays
          .where(friendAddresses.contains)
          .toList();
      final List<RelayFriend> candidates =
          friends.where((RelayFriend f) {
            final String a = PeerShareCodec.normalizeAddress(f.address);
            return friendAddresses.contains(a) && !kept.contains(a);
          }).toList()..sort((RelayFriend a, RelayFriend b) {
            // "Przyjaciel" first, then the most recently seen.
            final int byLevel = b.closeness.compareTo(a.closeness);
            return byLevel != 0
                ? byLevel
                : b.lastSeenAtMillis.compareTo(a.lastSeenAtMillis);
          });
      for (final RelayFriend candidate in candidates) {
        if (kept.length >= config.maxRelays) {
          break;
        }
        kept.add(PeerShareCodec.normalizeAddress(candidate.address));
      }
      next = kept;
    }
    if (listEquals(next, state.currentRelays)) {
      return false;
    }
    state.currentRelays = next;
    state.relaySetVersion += 1;
    _lastAnnounceAt.clear();
    return true;
  }

  /// Switches between automatic (`null`) and a hand-picked relay list.
  Future<void> setManualRelays(List<String>? relays) {
    return _locked(() async {
      final RelayState state = await _load();
      state.manualRelays = relays
          ?.map(PeerShareCodec.normalizeAddress)
          .where((String a) => a.isNotEmpty)
          .toSet()
          .take(config.maxRelays)
          .toList(growable: false);
      if (_refreshRelaySet(state) && _active) {
        await _announceToAll(state);
      }
      await _save(state);
    });
  }

  Future<void> _announceToAll(RelayState state) async {
    final int now = _now();
    for (final RelayFriend friend in _announceAudience(state)) {
      final String address = PeerShareCodec.normalizeAddress(friend.address);
      if (address == _self) {
        continue;
      }
      _lastAnnounceAt[address] = now;
      await _sendQuietly(address, _announcement(state, address));
    }
  }

  // ---------------------------------------------------------------------------
  // Relay side: holding mail for friends
  // ---------------------------------------------------------------------------

  bool _servesRecipient(RelayState state, String recipient) {
    if (recipient == _self || !_isAcceptedFriend(recipient)) {
      return false;
    }
    final RelayPeerInfo? info = state.peers[recipient];
    return info != null && info.relays.contains(_self);
  }

  bool _isCoRelay(RelayState state, String recipient, String other) {
    final RelayPeerInfo? info = state.peers[recipient];
    return info != null &&
        info.relays.contains(other) &&
        _servesRecipient(state, recipient);
  }

  Future<bool> _handleDeposit(
    RelayState state,
    String from,
    Object? rawEnvelope,
  ) async {
    final RelayEnvelope? envelope = RelayEnvelope.tryParse(rawEnvelope);
    if (envelope == null) {
      return false;
    }
    final String recipient = PeerShareCodec.normalizeAddress(
      envelope.recipient,
    );
    final int now = _now();
    final String claimedSender = PeerShareCodec.normalizeAddress(
      envelope.sender,
    );
    if (!_servesRecipient(state, recipient) ||
        envelope.expiresAtMillis <= now ||
        envelope.approximateBytes > config.maxRelayablePayloadBytes * 2) {
      return false;
    }
    // Only the sender itself, or a fellow relay catching us up, may hand in
    // an envelope. Anyone else claiming a sender would get a stranger's junk
    // charged to that sender's quota.
    if (from != claimedSender && !_isCoRelay(state, recipient, from)) {
      return false;
    }
    final Object? token = rawEnvelope is Map ? rawEnvelope['tk'] : null;
    final bool tokenValid = _tokenValid(state, recipient, claimedSender, token);
    await _sendQuietly(from, <String, dynamic>{
      'type': 'rly_deposit_ack',
      'id': envelope.id,
      'r': recipient,
    });
    if (state.tombstones.containsKey('$recipient|${envelope.id}')) {
      return false; // already delivered; the ack stops the depositor
    }
    final Map<String, Map<String, dynamic>> held = state.mailbox.putIfAbsent(
      recipient,
      () => <String, Map<String, dynamic>>{},
    );
    if (held.containsKey(envelope.id)) {
      return false;
    }
    held[envelope.id] = <String, dynamic>{
      ...envelope.toJson(),
      if (tokenValid) 'tk': token,
      // Kept here only (see _wireCopy): vouched for or not, when it arrived,
      // and how long it is held — never longer than any message lives, even
      // if the envelope claims otherwise.
      'hv': tokenValid || _isContact(claimedSender),
      'ha': now,
      'hx': min(
        envelope.expiresAtMillis,
        now + config.messageTtl.inMilliseconds,
      ),
    };
    _enforceQuota(held);
    if (!held.containsKey(envelope.id)) {
      return true; // over the budget for unvouched mail
    }
    // The recipient may well be online right now (a lost datagram, not an
    // offline phone): try handing it over straight away.
    await _pushMail(state, recipient);
    return true;
  }

  /// Whether [token] proves that [recipient] announced itself to [sender]
  /// (only checkable while the recipient has us as one of its relays).
  bool _tokenValid(
    RelayState state,
    String recipient,
    String sender,
    Object? token,
  ) {
    final Uint8List? key = state.peers[recipient]?.depositKey;
    return key != null &&
        token is String &&
        token == _depositToken(key, recipient: recipient, sender: sender);
  }

  /// Keeps one recipient's held mail within its limits.
  ///
  /// Mail from senders this relay vouches for (its owner's contacts, or
  /// holders of the recipient's deposit token) is counted per sender; the
  /// rest per /64 network, inside a small budget of its own. Whatever has
  /// to go is taken from whoever holds the most, oldest first, and unvouched
  /// mail always goes before vouched mail: a flood only ever pushes out the
  /// flooder's own messages, never a friend's.
  void _enforceQuota(Map<String, Map<String, dynamic>> held) {
    while (true) {
      final List<MapEntry<String, Map<String, dynamic>>> unvouched = held
          .entries
          .where(
            (MapEntry<String, Map<String, dynamic>> e) => !_isVouched(e.value),
          )
          .toList(growable: false);
      if (unvouched.isEmpty) {
        break;
      }
      final MapEntry<String, int> busiest = _busiest(unvouched);
      if (unvouched.length <= config.maxUnvouchedHeldPerRecipient &&
          _bytesOf(unvouched) <= config.maxUnvouchedBytesPerRecipient &&
          busiest.value <= config.maxUnvouchedHeldPerNetwork) {
        break;
      }
      held.remove(_oldestOf(unvouched, busiest.key));
    }
    while (held.isNotEmpty) {
      final List<MapEntry<String, Map<String, dynamic>>> all = held.entries
          .toList(growable: false);
      final MapEntry<String, int> busiest = _busiest(all);
      final bool overSender = busiest.value > config.maxHeldPerSender;
      final bool overTotal =
          all.length > config.maxHeldPerRecipient ||
          (all.length > 1 && _bytesOf(all) > config.maxHeldBytesPerRecipient);
      if (!overSender && !overTotal) {
        return;
      }
      List<MapEntry<String, Map<String, dynamic>>> pool = all;
      String owner = busiest.key;
      if (!overSender) {
        final List<MapEntry<String, Map<String, dynamic>>> unvouched = all
            .where(
              (MapEntry<String, Map<String, dynamic>> e) =>
                  !_isVouched(e.value),
            )
            .toList(growable: false);
        if (unvouched.isNotEmpty) {
          pool = unvouched;
          owner = _busiest(unvouched).key;
        }
      }
      held.remove(_oldestOf(pool, owner));
    }
  }

  /// Envelopes held before senders were told apart count as vouched for.
  static bool _isVouched(Map<String, dynamic> envelope) =>
      envelope['hv'] != false;

  /// Whom a held envelope is charged to: its sender, or for unvouched mail
  /// the sender's /64 network.
  static String _ownerOf(Map<String, dynamic> envelope) {
    final String sender = envelope['s'] as String? ?? '';
    return _isVouched(envelope) ? sender : 'net:${_network64(sender)}';
  }

  static MapEntry<String, int> _busiest(
    List<MapEntry<String, Map<String, dynamic>>> envelopes,
  ) {
    final Map<String, int> counts = <String, int>{};
    for (final MapEntry<String, Map<String, dynamic>> e in envelopes) {
      final String owner = _ownerOf(e.value);
      counts[owner] = (counts[owner] ?? 0) + 1;
    }
    return counts.entries.reduce(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          a.value >= b.value ? a : b,
    );
  }

  static int _bytesOf(List<MapEntry<String, Map<String, dynamic>>> envelopes) =>
      envelopes.fold<int>(
        0,
        (int sum, MapEntry<String, Map<String, dynamic>> e) =>
            sum + ((e.value['b'] as String?)?.length ?? 0),
      );

  /// The id of [owner]'s envelope that arrived first.
  static String _oldestOf(
    List<MapEntry<String, Map<String, dynamic>>> envelopes,
    String owner,
  ) {
    int arrival(Map<String, dynamic> e) =>
        ((e['ha'] as num?) ?? (e['c'] as num?) ?? 0).toInt();
    return envelopes
        .where(
          (MapEntry<String, Map<String, dynamic>> e) =>
              _ownerOf(e.value) == owner,
        )
        .reduce(
          (
            MapEntry<String, Map<String, dynamic>> a,
            MapEntry<String, Map<String, dynamic>> b,
          ) => arrival(a.value) <= arrival(b.value) ? a : b,
        )
        .key;
  }

  /// The /64 network of [address]. A mesh node may use any address inside
  /// its own /64, so per-address limits for strangers count those together.
  static String _network64(String address) {
    try {
      return Uri.parseIPv6Address(
        address,
      ).take(8).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    } on FormatException {
      return address;
    }
  }

  /// When a held envelope is dropped at the latest.
  static int _holdUntil(Map<String, dynamic> envelope) {
    final int expires = (envelope['x'] as num?)?.toInt() ?? 0;
    final int? hold = (envelope['hx'] as num?)?.toInt();
    return hold == null ? expires : min(expires, hold);
  }

  /// [envelope] as it travels: without what only this relay keeps. Fellow
  /// relays get the deposit token too, so they can vouch for it as well.
  static Map<String, dynamic> _wireCopy(
    Map<String, dynamic> envelope, {
    required bool keepToken,
  }) {
    final Map<String, dynamic> copy = Map<String, dynamic>.from(envelope)
      ..remove('hv')
      ..remove('ha')
      ..remove('hx');
    if (!keepToken) {
      copy.remove('tk');
    }
    return copy;
  }

  /// Sends what is held for [recipient] to it, in size-bounded batches.
  ///
  /// Envelopes handed over within the last poll interval are skipped unless
  /// [force]d (the recipient asked with `rly_poll`): every frame from the
  /// recipient counts as a sighting, and resending the whole mailbox each
  /// time would flood it.
  Future<void> _pushMail(
    RelayState state,
    String recipient, {
    bool force = false,
  }) async {
    final Map<String, Map<String, dynamic>>? held = state.mailbox[recipient];
    if (held == null || held.isEmpty) {
      _lastPushedAt.remove(recipient);
      return;
    }
    final int now = _now();
    final Map<String, int> pushed = _lastPushedAt.putIfAbsent(
      recipient,
      () => <String, int>{},
    )..removeWhere((String id, int _) => !held.containsKey(id));
    List<Map<String, dynamic>> batch = <Map<String, dynamic>>[];
    int batchBytes = 0;
    for (final MapEntry<String, Map<String, dynamic>> entry
        in held.entries.toList(growable: false)) {
      final int? last = pushed[entry.key];
      if (!force &&
          last != null &&
          now - last < config.pollInterval.inMilliseconds) {
        continue;
      }
      pushed[entry.key] = now;
      final Map<String, dynamic> envelope = _wireCopy(
        entry.value,
        keepToken: false,
      );
      final int size = (envelope['b'] as String?)?.length ?? 0;
      if (batch.isNotEmpty && batchBytes + size > config.maxMailBatchBytes) {
        await _sendQuietly(recipient, <String, dynamic>{
          'type': 'rly_mail',
          'items': batch,
        });
        batch = <Map<String, dynamic>>[];
        batchBytes = 0;
      }
      batch.add(envelope);
      batchBytes += size;
    }
    if (batch.isNotEmpty) {
      await _sendQuietly(recipient, <String, dynamic>{
        'type': 'rly_mail',
        'items': batch,
      });
    }
  }

  /// Drops what [recipient] confirmed (or a co-relay reports delivered) and
  /// remembers it as delivered, so a late copy is not stored again.
  ///
  /// Only envelopes actually held here count: ids are cheap to make up, and
  /// remembering arbitrary ones would let anyone grow this device's state.
  bool _dropDelivered(
    RelayState state, {
    required String recipient,
    required Object? ids,
  }) {
    final Map<String, Map<String, dynamic>>? held = state.mailbox[recipient];
    if (held == null || held.isEmpty) {
      return false;
    }
    final int latest = _now() + config.messageTtl.inMilliseconds;
    bool changed = false;
    for (final String id in _stringList(ids, limit: config.maxIdsPerFrame)) {
      final Map<String, dynamic>? envelope = held.remove(id);
      if (envelope == null) {
        continue;
      }
      state.tombstones['$recipient|$id'] = min(_holdUntil(envelope), latest);
      changed = true;
    }
    if (held.isEmpty) {
      state.mailbox.remove(recipient);
    }
    if (changed) {
      _capTombstones(state);
    }
    return changed;
  }

  void _capTombstones(RelayState state) {
    final int excess = state.tombstones.length - config.maxTombstones;
    if (excess <= 0) {
      return;
    }
    final List<MapEntry<String, int>> soonestFirst =
        state.tombstones.entries.toList()..sort(
          (MapEntry<String, int> a, MapEntry<String, int> b) =>
              a.value.compareTo(b.value),
        );
    for (final MapEntry<String, int> entry in soonestFirst.take(excess)) {
      state.tombstones.remove(entry.key);
    }
  }

  Future<void> _syncWithCoRelay(RelayState state, String coRelay) async {
    for (final String recipient in <String>{
      ...state.mailbox.keys,
      ..._tombstonedRecipients(state),
    }) {
      if (!_isCoRelay(state, recipient, coRelay)) {
        continue;
      }
      final List<String> ids =
          state.mailbox[recipient]?.keys.toList() ?? const <String>[];
      final List<String> tombstones = _tombstonesFor(state, recipient);
      // Id lists are split to keep each signal a few fragments long. Only a
      // single complete list lets the other side infer what *we* lack.
      final int frames = max(
        1,
        max(
          (ids.length / _syncIdsPerFrame).ceil(),
          (tombstones.length / _syncIdsPerFrame).ceil(),
        ),
      );
      for (int frame = 0; frame < frames; frame++) {
        await _sendQuietly(coRelay, <String, dynamic>{
          'type': 'rly_sync',
          'r': recipient,
          'ids': _slice(ids, frame),
          't': _slice(tombstones, frame),
          'all': frames == 1,
        });
      }
    }
  }

  Future<bool> _handleSync(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final String recipient = PeerShareCodec.normalizeAddress(
      payload['r'] as String? ?? '',
    );
    if (!_isCoRelay(state, recipient, from)) {
      return false;
    }
    final bool changed = _dropDelivered(
      state,
      recipient: recipient,
      ids: payload['t'],
    );
    final Set<String> theirs = _stringList(
      payload['ids'],
      limit: config.maxIdsPerFrame,
    ).toSet();
    final Map<String, Map<String, dynamic>> mine =
        state.mailbox[recipient] ?? const <String, Map<String, dynamic>>{};
    final List<String> wanted = theirs
        .where(
          (String id) =>
              !mine.containsKey(id) &&
              !state.tombstones.containsKey('$recipient|$id'),
        )
        .toList(growable: false);
    for (int frame = 0; frame * _syncIdsPerFrame < wanted.length; frame++) {
      await _sendQuietly(from, <String, dynamic>{
        'type': 'rly_sync_want',
        'r': recipient,
        'ids': _slice(wanted, frame),
      });
    }
    if (payload['all'] == true) {
      final List<String> missingThere = mine.keys
          .where((String id) => !theirs.contains(id))
          .toList(growable: false);
      await _sendHeld(state, from, recipient, missingThere);
    }
    return changed;
  }

  Future<void> _sendHeld(
    RelayState state,
    String to,
    String recipient,
    List<String> ids,
  ) async {
    final Map<String, Map<String, dynamic>>? held = state.mailbox[recipient];
    if (held == null) {
      return;
    }
    for (final String id in ids) {
      final Map<String, dynamic>? envelope = held[id];
      if (envelope != null) {
        await _sendQuietly(to, <String, dynamic>{
          'type': 'rly_deposit',
          'env': _wireCopy(envelope, keepToken: true),
        });
      }
    }
  }

  static const int _syncIdsPerFrame = 40;

  static List<String> _slice(List<String> ids, int frame) {
    final int start = frame * _syncIdsPerFrame;
    if (start >= ids.length) {
      return const <String>[];
    }
    return ids.sublist(start, min(ids.length, start + _syncIdsPerFrame));
  }

  Iterable<String> _tombstonedRecipients(RelayState state) =>
      state.tombstones.keys.map((String key) => key.split('|').first).toSet();

  List<String> _tombstonesFor(RelayState state, String recipient) {
    final String prefix = '$recipient|';
    final List<String> all = state.tombstones.keys
        .where((String key) => key.startsWith(prefix))
        .map((String key) => key.substring(prefix.length))
        .toList(growable: false);
    // Newest last in insertion order; the recent ones are what a co-relay
    // coming back is most likely still holding.
    return all.length > 200 ? all.sublist(all.length - 200) : all;
  }

  // ---------------------------------------------------------------------------
  // Recipient side: collecting mail
  // ---------------------------------------------------------------------------

  Future<bool> _handleMail(
    RelayState state,
    String relay,
    Object? items,
    List<SignalTransportFrame> forward,
  ) async {
    if (items is! List) {
      return false;
    }
    // Relays are always friends. Mail from anyone else would only make this
    // device try to open junk and tell its relays to purge made-up ids.
    if (!state.currentRelays.contains(relay) && !_isAcceptedFriend(relay)) {
      return false;
    }
    final RelayIdentity? identity = state.identity;
    if (identity == null) {
      return false;
    }
    final int now = _now();
    final List<String> handled = <String>[];
    bool changed = false;
    for (final Object? item in items.take(config.maxIdsPerFrame)) {
      final RelayEnvelope? envelope = RelayEnvelope.tryParse(item);
      if (envelope == null ||
          PeerShareCodec.normalizeAddress(envelope.recipient) != _self) {
        continue;
      }
      final String sender = PeerShareCodec.normalizeAddress(envelope.sender);
      final String seenKey = '$sender|${envelope.id}';
      if (state.seen.containsKey(seenKey) ||
          (_strangerSeen[seenKey] ?? 0) > now) {
        handled.add(envelope.id);
        continue;
      }
      if (!_isFresh(state, envelope, sender, now)) {
        // Expired, stretched past the lifetime any sender gives, dated in
        // the future, or old enough to have been delivered and forgotten:
        // at best a stale copy, at worst a relay replaying it.
        handled.add(envelope.id);
        continue;
      }
      final Uint8List? senderKey = state.peers[sender]?.publicKey;
      if (senderKey == null) {
        // Not verifiable yet (the sender's announcement has not arrived).
        // Left with the relay for a while; the next poll tries again.
        if (_giveUpOnUnattributable(seenKey, now)) {
          handled.add(envelope.id);
        }
        continue;
      }
      _unattributableSince.remove(seenKey);
      final Map<String, dynamic>? inner = await _open(
        identity,
        senderKey,
        envelope,
      );
      if (inner == null || inner[kReliableIdKey] != envelope.id) {
        // Forged, tampered or mis-addressed: drop it everywhere.
        handled.add(envelope.id);
        continue;
      }
      handled.add(envelope.id);
      // Remembered for as long as any copy of it may still be around.
      state.seen[seenKey] = envelope.expiresAtMillis;
      changed = true;
      forward.add(
        SignalTransportFrame(
          from: sender,
          payload: inner,
          receivedAtMillis: _now(),
        ),
      );
      // The original sender keeps retrying until it hears from us directly.
      await _sendQuietly(sender, <String, dynamic>{
        'type': 'rly_ack',
        'rid': envelope.id,
      });
    }
    if (handled.isNotEmpty) {
      await _sendQuietly(relay, <String, dynamic>{
        'type': 'rly_mail_ack',
        'ids': handled,
      });
      for (final String other in state.currentRelays) {
        if (other != relay) {
          await _sendQuietly(other, <String, dynamic>{
            'type': 'rly_purge',
            'ids': handled,
          });
        }
      }
    }
    return changed;
  }

  /// Whether a relayed [envelope] (not seen yet) may still be taken. Its
  /// dates are sealed in by the sender, so a relay cannot change them.
  bool _isFresh(
    RelayState state,
    RelayEnvelope envelope,
    String sender,
    int now,
  ) {
    final int lifetime = envelope.expiresAtMillis - envelope.createdAtMillis;
    return envelope.expiresAtMillis > now &&
        lifetime > 0 &&
        lifetime <= config.messageTtl.inMilliseconds &&
        envelope.createdAtMillis <= now + config.maxClockSkew.inMilliseconds &&
        envelope.expiresAtMillis > state.seenFloorMillis &&
        envelope.expiresAtMillis > (state.seenFloors[sender] ?? 0);
  }

  /// True once relayed mail nobody can attribute has been offered for
  /// [RelayConfig.unattributableGrace]: then the relays may drop it.
  bool _giveUpOnUnattributable(String key, int now) {
    final int? since = _unattributableSince[key];
    if (since == null) {
      _unattributableSince[key] = now;
      while (_unattributableSince.length > config.maxStrangerSeenEntries) {
        _unattributableSince.remove(_unattributableSince.keys.first);
      }
      return false;
    }
    if (now - since < config.unattributableGrace.inMilliseconds) {
      return false;
    }
    _unattributableSince.remove(key);
    return true;
  }

  Future<Map<String, dynamic>?> _open(
    RelayIdentity identity,
    Uint8List senderKey,
    RelayEnvelope envelope,
  ) async {
    try {
      final Uint8List plaintext = await RelayCipher.openHybrid(
        recipient: identity,
        senderPublicKey: senderKey,
        box: envelope.box,
        associatedData: envelope.associatedData,
      );
      final Object? decoded = jsonDecode(utf8.decode(plaintext));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (error) {
      logZenWarning('Dropping a relayed envelope that failed to open: $error');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Peer presence and periodic work
  // ---------------------------------------------------------------------------

  /// Everything that can move forward because [address] is reachable now.
  Future<bool> _onPeerSeen(RelayState state, String address) async {
    if (!_active || address.isEmpty || address == _self) {
      return false;
    }
    final int now = _now();
    final int? last = _lastSeenHandledAt[address];
    if (last != null && now - last < config.peerSeenThrottle.inMilliseconds) {
      return false;
    }
    // Silent for a while: probably just back (a phone off the network for a
    // minute), so whatever is held for it goes out again in full.
    final bool cameBack =
        last == null ||
        now - last > config.peerSeenThrottle.inMilliseconds * 12;
    if (_lastSeenHandledAt.length >= 4096) {
      // Anyone can send a frame from a fresh address: keep only the recent.
      _lastSeenHandledAt.removeWhere(
        (String _, int at) =>
            now - at >= config.peerSeenThrottle.inMilliseconds,
      );
    }
    _lastSeenHandledAt[address] = now;
    bool changed = false;
    // 1. Our own undelivered payloads for it: straight away, backoff reset.
    for (final RelayOutboxEntry entry in state.outbox.values.toList()) {
      if (entry.recipient == address) {
        state.outbox[entry.rid] = await _attemptDirect(
          entry.copyWith(directAttempts: 0),
          now,
        );
        changed = true;
      }
    }
    // 2. Mail we hold for it (what went out moments ago only if it was away).
    await _pushMail(state, address, force: cameBack);
    // 3. It holds mail for someone we also serve: compare notes.
    await _syncWithCoRelay(state, address);
    // 4. It is a relay for recipients of our pending payloads.
    changed = await _depositPending(state, onlyRelay: address) || changed;
    // 5. It has not confirmed our latest relay set.
    if (_shouldAnnounceTo(state, address) &&
        state.announcedVersions[address] != state.relaySetVersion) {
      _lastAnnounceAt[address] = now;
      await _sendQuietly(address, _announcement(state, address));
    }
    // 6. It is one of our relays: collect.
    if (state.currentRelays.contains(address)) {
      final int? lastPoll = _lastPollAt[address];
      if (lastPoll == null ||
          now - lastPoll > config.peerSeenThrottle.inMilliseconds * 6) {
        _lastPollAt[address] = now;
        await _sendQuietly(address, <String, dynamic>{'type': 'rly_poll'});
      }
    }
    // 7. Attachments: chunks for it to hold, and chunks to collect from it.
    if (_blobs != null) {
      await _depositBlobs(state, onlyRelay: address);
      await _resumeBlobPulls(state, now, onlySource: address);
    }
    return changed;
  }

  /// Periodic housekeeping; cheap when there is nothing to do.
  Future<void> tick() {
    return _locked(() async {
      if (!_active) {
        return;
      }
      final RelayState state = await _load();
      final int now = _now();
      bool changed = _expire(state, now);
      if (_forgetFormerContacts(state)) {
        changed = true;
      }
      if (_refreshRelaySet(state)) {
        changed = true;
      }
      // Announcements not yet confirmed.
      for (final RelayFriend friend in _announceAudience(state)) {
        final String address = PeerShareCodec.normalizeAddress(friend.address);
        if (address == _self ||
            state.announcedVersions[address] == state.relaySetVersion) {
          continue;
        }
        final int? last = _lastAnnounceAt[address];
        if (last == null ||
            now - last >= config.announceRetryInterval.inMilliseconds) {
          _lastAnnounceAt[address] = now;
          await _sendQuietly(address, _announcement(state, address));
        }
      }
      // Direct retries on their backoff.
      for (final RelayOutboxEntry entry in state.outbox.values.toList()) {
        if (now >= entry.nextDirectAttemptAtMillis) {
          state.outbox[entry.rid] = await _attemptDirect(entry, now);
          changed = true;
        }
      }
      changed = await _depositPending(state) || changed;
      if (_blobs != null) {
        changed = await _blobHousekeeping(state, now) || changed;
        await _depositBlobs(state);
        await _resumeBlobPulls(state, now);
      }
      // Collect from our relays now and then.
      for (final String relay in state.currentRelays) {
        final int? last = _lastPollAt[relay];
        if (last == null || now - last >= config.pollInterval.inMilliseconds) {
          _lastPollAt[relay] = now;
          await _sendQuietly(relay, <String, dynamic>{'type': 'rly_poll'});
        }
      }
      // Co-relays catch each other up.
      final Set<String> coRelays = <String>{};
      for (final String recipient in state.mailbox.keys) {
        coRelays.addAll(state.peers[recipient]?.relays ?? const <String>[]);
      }
      coRelays.remove(_self);
      for (final String coRelay in coRelays) {
        final int? last = _lastSyncAt[coRelay];
        if (last == null ||
            now - last >= config.relaySyncInterval.inMilliseconds) {
          _lastSyncAt[coRelay] = now;
          await _syncWithCoRelay(state, coRelay);
        }
      }
      if (changed) {
        await _save(state);
      } else {
        // First tries turn into "waiting" as time passes, unsaved.
        _publishProgress(state);
      }
      _frequentTicks = _computeFrequentTicks(state, _now());
    });
  }

  bool _expire(RelayState state, int now) {
    final int before =
        state.outbox.length +
        state.tombstones.length +
        state.seen.length +
        state.mailbox.values.fold<int>(0, (int s, Map m) => s + m.length);
    // Dropped unacknowledged after the retention window: the chat must not go
    // on showing such a message as sent.
    final List<RelayOutboxEntry> lapsed = state.outbox.values
        .where((RelayOutboxEntry e) => e.expiresAtMillis <= now)
        .toList(growable: false);
    for (final RelayOutboxEntry entry in lapsed) {
      state.outbox.remove(entry.rid);
      _sealed.remove(entry.rid);
      _report(state, entry, RelayDeliveryStatus.expired, now);
      _settleTracked(state, entry, delivered: false, now: now);
    }
    final int trackedBefore = state.tracked.length;
    _capTracked(state, now: now);
    _reportedDirectOnly.removeWhere(
      (String rid) => !state.outbox.containsKey(rid),
    );
    state.tombstones.removeWhere((String _, int expiry) => expiry <= now);
    _capTombstones(state);
    state.seen.removeWhere((String _, int expiry) => expiry <= now);
    state.seenFloors.removeWhere((String _, int floor) => floor <= now);
    if (state.seen.length > config.maxSeenEntries) {
      // Whoever holds the most entries gives up its oldest: a contact that
      // floods this list only pushes out (and later refuses) its own.
      final Map<String, List<MapEntry<String, int>>> bySender =
          <String, List<MapEntry<String, int>>>{};
      for (final MapEntry<String, int> e in state.seen.entries) {
        final int bar = e.key.indexOf('|');
        (bySender[bar < 0 ? e.key : e.key.substring(0, bar)] ??=
                <MapEntry<String, int>>[])
            .add(e);
      }
      for (final List<MapEntry<String, int>> l in bySender.values) {
        l.sort(
          (MapEntry<String, int> a, MapEntry<String, int> b) =>
              a.value.compareTo(b.value),
        );
      }
      int excess = state.seen.length - config.maxSeenEntries;
      while (excess > 0) {
        String biggest = '';
        int most = 0;
        bySender.forEach((String sender, List<MapEntry<String, int>> l) {
          if (l.length > most) {
            most = l.length;
            biggest = sender;
          }
        });
        if (most == 0) {
          break;
        }
        final MapEntry<String, int> entry = bySender[biggest]!.removeAt(0);
        state.seen.remove(entry.key);
        // Anything relayed from this sender that expires no later could be
        // the one just forgotten: from now on it is refused (see _isFresh).
        state.seenFloors[biggest] = max(
          state.seenFloors[biggest] ?? 0,
          entry.value,
        );
        excess--;
      }
    }
    _strangerSeen.removeWhere((String _, int expiry) => expiry <= now);
    for (final Map<String, Map<String, dynamic>> held in state.mailbox.values) {
      held.removeWhere(
        (String _, Map<String, dynamic> e) => _holdUntil(e) <= now,
      );
    }
    state.mailbox.removeWhere(
      (String _, Map<String, Map<String, dynamic>> held) => held.isEmpty,
    );
    _lastPushedAt.removeWhere(
      (String recipient, Map<String, int> _) =>
          !state.mailbox.containsKey(recipient),
    );
    final int after =
        state.outbox.length +
        state.tombstones.length +
        state.seen.length +
        state.mailbox.values.fold<int>(0, (int s, Map m) => s + m.length);
    return before != after || trackedBefore != state.tracked.length;
  }

  /// Forgets announcement confirmations of people who are no longer
  /// contacts (and any that should never have been stored).
  bool _forgetFormerContacts(RelayState state) {
    if (!_peers.isReady || state.announcedVersions.isEmpty) {
      return false;
    }
    final Set<String> audience = _announceAudience(state)
        .map((RelayFriend f) => PeerShareCodec.normalizeAddress(f.address))
        .toSet();
    final int before = state.announcedVersions.length;
    state.announcedVersions.removeWhere(
      (String address, int _) => !audience.contains(address),
    );
    return state.announcedVersions.length != before;
  }

  Future<RelayOutboxEntry> _attemptDirect(
    RelayOutboxEntry entry,
    int now,
  ) async {
    await _sendQuietly(entry.recipient, entry.payload);
    return _scheduleNextDirect(entry, now);
  }

  /// [entry] counted as tried now, with its next try on the backoff.
  RelayOutboxEntry _scheduleNextDirect(RelayOutboxEntry entry, int now) {
    final List<Duration> schedule = config.directRetrySchedule;
    final Duration wait = schedule.isEmpty
        ? config.messageTtl
        : schedule[min(entry.directAttempts, schedule.length - 1)];
    return entry.copyWith(
      directAttempts: entry.directAttempts + 1,
      nextDirectAttemptAtMillis: now + wait.inMilliseconds,
    );
  }

  /// Deposits unacknowledged relayable payloads with the recipients' relays.
  Future<bool> _depositPending(RelayState state, {String? onlyRelay}) async {
    final RelayIdentity? identity = state.identity;
    if (identity == null) {
      return false;
    }
    final int now = _now();
    final bool dueNow = onlyRelay == null && _depositsDueNow;
    if (dueNow) {
      _depositsDueNow = false;
    }
    bool changed = false;
    for (final RelayOutboxEntry entry in state.outbox.values.toList()) {
      if (now - entry.createdAtMillis < config.depositAfter.inMilliseconds) {
        continue;
      }
      if (!entry.relayable) {
        if (entry.blobId != null) {
          continue; // its copy travels to the mailboxes as a blob
        }
        if (await _cutIntoBlob(state, entry, now)) {
          changed = true;
          continue;
        }
        // The mailboxes would have got a copy by now but this one is too large
        // for them: it waits for both devices to be online together, and the
        // chat should say so rather than keep showing it as safely sent.
        if (entry.payload['type'] == _chatMessageType &&
            _reportedDirectOnly.add(entry.rid) &&
            _report(state, entry, RelayDeliveryStatus.directOnly, now)) {
          changed = true;
        }
        continue;
      }
      final RelayPeerInfo? info = state.peers[entry.recipient];
      final RelayPublicKeys? recipientKey = info?.keys;
      if (info == null || recipientKey == null) {
        continue;
      }
      if (info.relays.contains(_self) &&
          _servesRecipient(state, entry.recipient) &&
          !(state.mailbox[entry.recipient]?.containsKey(entry.rid) ?? false) &&
          !state.tombstones.containsKey('${entry.recipient}|${entry.rid}')) {
        // The recipient chose this very device as one of its relays (a
        // trusted friend holding its mail): keep a copy here like any other
        // relay would, besides the one in the outbox. It is handed over
        // when the recipient polls its mailboxes, and co-relays that were
        // away catch up from it.
        state.mailbox.putIfAbsent(
          entry.recipient,
          () => <String, Map<String, dynamic>>{},
        )[entry.rid] = <String, dynamic>{
          ...await _sealedEnvelope(identity, recipientKey, entry),
          if (info.depositToken != null) 'tk': info.depositToken,
          'hv': true,
          'ha': now,
          'hx': entry.expiresAtMillis,
        };
        changed = true;
      }
      final int spacing = _depositSpacingOf(entry, now);
      final List<String> targets = info.relays
          .where(
            (String relay) =>
                relay != _self &&
                relay != entry.recipient &&
                !entry.depositedTo.contains(relay) &&
                (onlyRelay == null || relay == onlyRelay) &&
                (onlyRelay != null ||
                    dueNow ||
                    now - (entry.depositAttemptAtMillis[relay] ?? 0) >=
                        spacing),
          )
          .toList(growable: false);
      if (targets.isEmpty) {
        continue;
      }
      final Map<String, dynamic> wire = <String, dynamic>{
        ...await _sealedEnvelope(identity, recipientKey, entry),
        // Lets relays that do not know us see that the recipient does.
        if (info.depositToken != null) 'tk': info.depositToken,
      };
      final Map<String, int> attempts = Map<String, int>.from(
        entry.depositAttemptAtMillis,
      );
      for (final String relay in targets) {
        attempts[relay] = now;
        await _sendQuietly(relay, <String, dynamic>{
          'type': 'rly_deposit',
          'env': wire,
        });
      }
      state.outbox[entry.rid] = entry.copyWith(
        depositAttemptAtMillis: attempts,
      );
      changed = true;
    }
    return changed;
  }

  /// How long to wait before handing [entry] again to a mailbox that did
  /// not confirm: [RelayConfig.depositRetryInterval] while it is young, then
  /// longer the older it gets, up to [RelayConfig.depositRetryMaxInterval].
  /// Mailboxes that come online get it at once (see [_onPeerSeen]).
  int _depositSpacingOf(RelayOutboxEntry entry, int now) {
    const int step = 10 * 60 * 1000;
    final int base = config.depositRetryInterval.inMilliseconds;
    final int age = max(0, now - entry.createdAtMillis);
    return min(
      config.depositRetryMaxInterval.inMilliseconds,
      base * (1 + age ~/ step),
    );
  }

  /// [entry] sealed for its recipient as envelope JSON, reused while the
  /// recipient's key stays the same: a retry to a mailbox is the very same
  /// envelope again.
  Future<Map<String, dynamic>> _sealedEnvelope(
    RelayIdentity identity,
    RelayPublicKeys recipientKey,
    RelayOutboxEntry entry,
  ) async {
    final String key = base64Url.encode(recipientKey.x25519);
    final ({String key, Map<String, dynamic> envelope})? cached =
        _sealed[entry.rid];
    if (cached != null && cached.key == key) {
      return cached.envelope;
    }
    final Map<String, dynamic> envelope = (await _seal(
      identity,
      recipientKey,
      entry,
    )).toJson();
    _sealed.remove(entry.rid);
    _sealed[entry.rid] = (key: key, envelope: envelope);
    while (_sealed.length > _maxSealedCached) {
      _sealed.remove(_sealed.keys.first);
    }
    return envelope;
  }

  Future<RelayEnvelope> _seal(
    RelayIdentity identity,
    RelayPublicKeys recipientKey,
    RelayOutboxEntry entry,
  ) async {
    final Uint8List associatedData = RelayEnvelope.associatedDataFor(
      id: entry.rid,
      sender: _self,
      recipient: entry.recipient,
      createdAtMillis: entry.createdAtMillis,
      expiresAtMillis: entry.expiresAtMillis,
    );
    final RelayHybridBox box = await RelayCipher.sealHybrid(
      sender: identity,
      recipient: recipientKey,
      plaintext: Uint8List.fromList(utf8.encode(jsonEncode(entry.payload))),
      associatedData: associatedData,
    );
    return RelayEnvelope(
      id: entry.rid,
      sender: _self,
      recipient: entry.recipient,
      createdAtMillis: entry.createdAtMillis,
      expiresAtMillis: entry.expiresAtMillis,
      box: box,
    );
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  /// Friends always; group members too while sharing with groups is on.
  List<RelayFriend> _announceAudience(RelayState state) {
    if (!_peers.isReady) {
      return const <RelayFriend>[];
    }
    return <RelayFriend>[
      ..._peers.acceptedFriends(),
      if (state.shareWithGroups) ..._peers.groupContacts(),
    ];
  }

  bool _shouldAnnounceTo(RelayState state, String address) {
    return _isAcceptedFriend(address) ||
        (state.shareWithGroups && _isGroupContact(address));
  }

  /// Someone whose relay announcements we take: a friend or a group member.
  bool _isContact(String address) =>
      _isAcceptedFriend(address) || _isGroupContact(address);

  bool _isGroupContact(String address) {
    if (!_peers.isReady) {
      return false;
    }
    return _peers.groupContacts().any(
      (RelayFriend f) => PeerShareCodec.addressesEqual(f.address, address),
    );
  }

  /// Drops everything still queued for [recipient], except payload types in
  /// [keepTypes] (the "we are done" signal itself must still arrive).
  ///
  /// Used when a relationship ends: messages to someone who was just removed
  /// or blocked must not keep being retried, and relayed, for two weeks.
  Future<void> cancelPendingTo(
    String recipient, {
    Set<String> keepTypes = const <String>{},
  }) {
    return _locked(() async {
      final RelayState state = await _load();
      final String to = PeerShareCodec.normalizeAddress(recipient);
      final int before = state.outbox.length;
      state.outbox.removeWhere(
        (String _, RelayOutboxEntry e) =>
            e.recipient == to && !keepTypes.contains(e.payload['type']),
      );
      bool changed = state.outbox.length != before;
      // Their messages are not on their way any more: nobody to wait for.
      for (final RelayTrackedMessage tracked in state.tracked.values.toList()) {
        final String? rid = tracked.pending[to];
        if (rid != null && !state.outbox.containsKey(rid)) {
          tracked.pending.remove(to);
          if (tracked.pending.isEmpty &&
              tracked.delivered.isEmpty &&
              tracked.expired.isEmpty) {
            state.tracked.remove(tracked.messageId);
          } else if (tracked.isSettled) {
            tracked.settledAtMillis = _now();
          }
          changed = true;
        }
      }
      for (final RelayBlobOut blob in state.outBlobs.values.toList()) {
        if (blob.recipient == to) {
          await _dropOutBlob(state, blob);
          changed = true;
        }
      }
      if (changed) {
        await _save(state);
      }
    });
  }

  /// Turns sharing this device's key and mailboxes with group members who are
  /// not friends on or off (off until the person opts in). Off keeps group
  /// messages direct-only (still acknowledged and retried), and reveals
  /// nothing about your friends to group members. It does not take back what
  /// group members already received while it was on.
  Future<void> setShareWithGroups(bool share) {
    return _locked(() async {
      final RelayState state = await _load();
      if (state.shareWithGroups == share) {
        return;
      }
      state.shareWithGroups = share;
      if (share) {
        // Group members have not seen the current version yet.
        for (final RelayFriend contact in _peers.groupContacts()) {
          state.announcedVersions.remove(
            PeerShareCodec.normalizeAddress(contact.address),
          );
        }
        _lastAnnounceAt.clear();
      }
      await _save(state);
    });
  }

  /// Sets how many bytes of attachments this device holds per sender for
  /// each friend it serves as a mailbox (0: none). Friends hear it with the
  /// next announcement; what is already held stays until collected or
  /// expired.
  Future<void> setBlobQuota(int bytes) {
    return _locked(() async {
      final RelayState state = await _load();
      final int next = max(0, bytes);
      if (_blobQuota(state) == next && state.blobQuotaBytes != null) {
        return;
      }
      state.blobQuotaBytes = next;
      state.relaySetVersion += 1;
      _lastAnnounceAt.clear();
      if (_active) {
        await _announceToAll(state);
      }
      await _save(state);
    });
  }

  /// Whether an attachment of [bytes] to [recipient] can wait in the
  /// recipient's mailboxes: at least one of the mailboxes it announced
  /// (other than this device) holds that much. Otherwise attachments go
  /// only while both devices are online.
  Future<bool> canSendAttachmentTo(
    String recipient, {
    required int bytes,
    required int chunkSize,
  }) {
    return _locked(() async {
      if (_blobs == null || bytes <= 0 || chunkSize <= 0) {
        return false;
      }
      final RelayState state = await _load();
      final int count = (bytes + chunkSize - 1) ~/ chunkSize;
      return _canSendBlob(
        state,
        PeerShareCodec.normalizeAddress(recipient),
        bytes + count * RelayBlobCipher.overheadBytes,
      );
    });
  }

  /// Hands a chat attachment to [recipient]'s mailboxes, for when the two
  /// devices are not online together.
  ///
  /// The attachment ([totalBytes], read with [readChunk] in [chunkSize]
  /// pieces — the app's own transfer chunks) is sealed chunk by chunk under
  /// a fresh key ([RelayBlobCipher]) and kept here until the mailboxes hold
  /// it. The key travels in a small manifest, an ordinary reliable payload
  /// (direct, or sealed for the mailboxes like any message). The recipient
  /// collects the chunks from its mailboxes (or from this device) and its
  /// app gets them as the usual `message_placeholder` + `message_chunk`
  /// frames carrying [meta] and [messageId], so they are put together and
  /// checked by the media guard exactly as a live transfer would be.
  ///
  /// Returns false — and nothing is queued — when the recipient or its
  /// mailboxes cannot take it (see [canSendAttachmentTo]) or the file could
  /// not be read; the caller then keeps its own (online-only) transfer.
  Future<bool> submitAttachment({
    required String recipient,
    required String messageId,
    required Map<String, dynamic> meta,
    required int totalBytes,
    required int chunkSize,
    required Future<Uint8List> Function(int index) readChunk,
  }) async {
    final String to = PeerShareCodec.normalizeAddress(recipient);
    if (_blobs == null ||
        messageId.isEmpty ||
        totalBytes <= 0 ||
        totalBytes > config.maxBlobBytes ||
        chunkSize <= 0 ||
        chunkSize > config.maxBlobChunkBytes) {
      return false;
    }
    final int count = (totalBytes + chunkSize - 1) ~/ chunkSize;
    final int expectedCipherBytes =
        totalBytes + count * RelayBlobCipher.overheadBytes;
    final bool possible = await _locked(() async {
      final RelayState state = await _load();
      return state.outBlobs.length < config.maxOutgoingBlobs &&
          _canSendBlob(state, to, expectedCipherBytes);
    });
    if (!possible) {
      return false;
    }
    final String blobId = _newBlobId();
    final Uint8List key = RelayBlobCipher.newKey();
    // Sealed outside the lock: megabytes of AEAD must not hold up messages.
    final int? cipherBytes = await _sealBlobChunks(
      blobId: blobId,
      recipient: to,
      key: key,
      count: count,
      chunkAt: (int index) async {
        final Uint8List chunk = await readChunk(index);
        final int expected = index < count - 1
            ? chunkSize
            : totalBytes - chunkSize * (count - 1);
        if (chunk.length != expected) {
          throw StateError('Attachment chunk $index has the wrong size.');
        }
        return chunk;
      },
    );
    if (cipherBytes == null) {
      return false;
    }
    return _locked(() async {
      final RelayState state = await _load();
      if (!_canSendBlob(state, to, cipherBytes)) {
        await _deleteChunks(count, (int i) => _outChunkKey(blobId, i));
        return false;
      }
      final int now = _now();
      final int expires = now + config.messageTtl.inMilliseconds;
      final String manifestRid = await _enqueue(state, to, <String, dynamic>{
        'type': kBlobManifestType,
        'b': blobId,
        'k': RelayBlobKind.attachment.wire,
        'key': base64Url.encode(key),
        'n': count,
        'cs': chunkSize,
        'z': totalBytes,
        'x': expires,
        'msgId': messageId,
        'meta': _attachmentMeta(meta),
      }, now);
      state.outBlobs[blobId] = RelayBlobOut(
        blobId: blobId,
        recipient: to,
        kind: RelayBlobKind.attachment,
        manifestRid: manifestRid,
        chunkCount: count,
        cipherBytes: cipherBytes,
        createdAtMillis: now,
        expiresAtMillis: expires,
      );
      await _depositBlobs(state, onlyBlob: blobId);
      await _save(state);
      return true;
    });
  }

  bool _isAcceptedFriend(String address) {
    if (!_peers.isReady) {
      return false;
    }
    return _peers.acceptedFriends().any(
      (RelayFriend f) => PeerShareCodec.addressesEqual(f.address, address),
    );
  }

  Future<void> _sendQuietly(String to, Map<String, dynamic> payload) async {
    if (to.isEmpty || to == _self) {
      return;
    }
    try {
      await _rawSend(to, payload);
    } catch (error) {
      // Unreachable peers are the normal case here; the state machine retries.
      logZenWarning('Relay send "${payload['type']}" to $to failed: $error');
    }
  }

  Future<RelayState> _load() async {
    final RelayState? cached = _state;
    if (cached != null) {
      return cached;
    }
    final RelayState loaded = await _store.load();
    if (loaded.identity?.isHybrid != true) {
      // Mail is sealed with the hybrid post-quantum key too.
      loaded.identity = await RelayIdentity.generateHybrid();
    }
    if (_active) {
      _state = loaded;
    }
    return loaded;
  }

  Future<void> _save(RelayState state) async {
    await _store.save(state);
    if (_active) {
      _state = state;
    }
    // On the disk now: first tries of what was just queued may go out.
    if (_unsent.isNotEmpty) {
      final List<RelayOutboxEntry> unsent = List<RelayOutboxEntry>.of(_unsent);
      _unsent.clear();
      for (final RelayOutboxEntry entry in unsent) {
        if (state.outbox.containsKey(entry.rid)) {
          await _sendQuietly(entry.recipient, entry.payload);
        }
      }
    }
    _publishProgress(state);
    overview.value = RelayOverview(
      isAutomatic: state.manualRelays == null,
      relays: List<String>.unmodifiable(state.currentRelays),
      outboxCount: state.outbox.length,
      heldEnvelopeCount: state.mailbox.values.fold<int>(
        0,
        (int sum, Map<String, Map<String, dynamic>> held) => sum + held.length,
      ),
      heldForPeerCount: state.mailbox.length,
      publicKeyFingerprint: _fingerprint(state.identity?.publicKey),
      shareWithGroups: state.shareWithGroups,
      blobQuotaBytes: _blobQuota(state),
      heldBlobBytes: _heldBlobBytes(state),
      outgoingBlobCount: state.outBlobs.length,
    );
    deliveryReportCount.value = state.deliveryReports.length;
  }

  static String _fingerprint(Uint8List? key) {
    if (key == null) {
      return '';
    }
    final String hex = key
        .take(8)
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}';
  }

  String _newReliableId() {
    final int a = _random.nextInt(1 << 32);
    final int b = _random.nextInt(1 << 32);
    return 'r${_now().toRadixString(36)}'
        '${a.toRadixString(36)}${b.toRadixString(36)}';
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final Future<T> result = _lock.then((_) => action());
    _lock = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace st) {
        logZenError('Relay engine operation failed', error, st);
      },
    );
    return result;
  }

  /// [value] as an int, or -1 for anything that is not a number.
  static int _intOf(Object? value) => value is num ? value.toInt() : -1;

  static List<int> _intListOf(Object? value, {required int limit}) {
    if (value is! List) {
      return const <int>[];
    }
    return value
        .take(limit)
        .whereType<num>()
        .map((num n) => n.toInt())
        .toList(growable: false);
  }

  static List<String> _stringList(Object? value, {int? limit}) {
    if (value is! List) {
      return const <String>[];
    }
    final Iterable<Object?> items = limit == null ? value : value.take(limit);
    return items.whereType<String>().toList(growable: false);
  }
}
