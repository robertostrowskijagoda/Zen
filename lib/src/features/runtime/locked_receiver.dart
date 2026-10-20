import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/locked_alarm.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Notification slots of the [LockedReceiver]; the app clears them once it
/// drained the inbox.
const String kLockedMessageSlot = 'locked-inbox-message';
const String kLockedSocialSlot = 'locked-inbox-social';
const String kLockedAlarmSlot = 'locked-inbox-alarm';
const String kLockedCallSlot = 'locked-inbox-call';
const String kLockedMissedCallSlot = 'locked-inbox-missed-call';
const String kLockedPowerAlarmSlot = 'locked-inbox-power-alarm';

const List<String> kLockedReceiverSlots = <String>[
  kLockedMessageSlot,
  kLockedSocialSlot,
  kLockedAlarmSlot,
  kLockedCallSlot,
  kLockedMissedCallSlot,
  kLockedPowerAlarmSlot,
];

/// Frames that only mean something the moment they arrive (a ring, a call's
/// media negotiation, typing, a direct file transfer): a locked phone takes
/// no part, and replayed after unlock they would be stale. Never kept.
const Set<String> _realTimeTypes = <String>{
  'typing',
  'offer',
  'answer',
  'hangup',
  'ringing',
  'busy',
  'message_chunk',
  'message_chunk_ack',
  'transfer_offer',
  'transfer_answer',
};

bool _isRealTime(String type) =>
    _realTimeTypes.contains(type) ||
    type.startsWith('call_') ||
    type.startsWith('group_call_') ||
    type.startsWith('gc_');

const Set<String> _ringTypes = <String>{'call_invite', 'group_call_invite'};
const Set<String> _ringEndTypes = <String>{
  'call_end',
  'call_decline',
  'hangup',
  'group_call_leave',
};

/// Relay frames about this phone's own mail (acknowledgements of what it
/// sent, friends' mailbox sets, mail held for it): kept, the app's relay
/// layer handles them after unlock. Every other relay frame is a mailbox
/// duty for friends (holding, handing out, syncing their mail), paused
/// while the app is locked: unanswered, the friends' phones use their other
/// mailboxes.
const Set<String> _keptRelayTypes = <String>{
  'rly_ack',
  'rly_announce',
  'rly_announce_ack',
  'rly_deposit_ack',
  'rly_mail',
  'rly_bput_ack',
  'rly_bput_no',
};

/// The ledger syncs by asking (heads, wants, entries, media): what friends
/// ask of this phone while it is locked goes unanswered (other copies
/// answer, and the sync runs again after unlock), and what they push is
/// fetched again then — kept, it would only fill the inbox with stale
/// requests and media. Only keys and revocations, small and one-off, are
/// kept.
const Set<String> _keptLedgerTypes = <String>{'lg_keys', 'lg_revoke'};

const Set<String> _messageTypes = <String>{
  'message',
  'group_message',
  'message_placeholder',
};

const Set<String> _socialTypes = <String>{
  'friend_request',
  'friend_accept',
  'group_invite',
  'event',
  'ask',
  'intent',
  // Mail from a mailbox: sealed for the relay key, so what it is cannot be
  // told here.
  'rly_mail',
};

/// What a stranger may leave while the app is locked, per run of the
/// receiver (friend requests, neighbours).
const int kLockedStrangerFramesPerSender = 5;
const int kLockedStrangerFramesTotal = 50;

/// How often the receiver asks its mailboxes for mail held for it.
const Duration kLockedMailboxPollInterval = Duration(minutes: 5);

/// One frame as the inbox keeps it (JSON: sender, time, payload).
Uint8List encodeInboxFrame(SignalTransportFrame frame) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'f': frame.from,
        't': frame.receivedAtMillis,
        'p': frame.payload,
      }),
    ),
  );
}

/// The frame [record] holds, or `null` for anything else.
SignalTransportFrame? decodeInboxFrame(Uint8List record) {
  try {
    final Object? json = jsonDecode(utf8.decode(record));
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final Object? from = json['f'];
    final Object? at = json['t'];
    final Object? payload = json['p'];
    if (from is! String || at is! int || payload is! Map<String, dynamic>) {
      return null;
    }
    return SignalTransportFrame(
      from: from,
      payload: payload,
      receivedAtMillis: at,
    );
  } on FormatException {
    return null;
  }
}

/// Who counts as a contact for the background service, from the app's
/// state (normalized addresses): accepted friends with every device of
/// theirs the account directory knows, this account's own other devices,
/// members of joined groups, and the blocked.
BackgroundCapabilityDraft backgroundCapabilityDraftOf(
  SocialHubState state, {
  required Uint8List inboxPublicKey,
  AccountDeviceDirectory? directory,
  Iterable<String> mailboxes = const <String>[],
}) {
  String normal(String address) => PeerShareCodec.normalizeAddress(address);
  final Set<String> friends = <String>{};
  final Set<String> blocked = <String>{};
  for (final FriendProfile friend in state.friends.values) {
    final String address = normal(friend.address);
    if (address.isEmpty) {
      continue;
    }
    if (friend.status == FriendRelationshipStatus.blocked) {
      blocked.add(address);
      continue;
    }
    if (friend.status != FriendRelationshipStatus.accepted) {
      continue;
    }
    friends.add(address);
    final String? account = directory?.accountOf(friend.address);
    if (directory != null && account != null) {
      friends.addAll(directory.addressesOf(account).map(normal));
    }
  }
  if (directory != null && directory.ownAccount.isNotEmpty) {
    friends.addAll(directory.addressesOf(directory.ownAccount).map(normal));
  }
  final Set<String> members = <String>{};
  for (final GroupProfile group in state.groups.values) {
    if (group.isInvitePending) {
      // Not joined: its members are strangers until the person says yes.
      continue;
    }
    for (final String member in <String>[
      ...group.memberAddresses,
      group.createdById,
    ]) {
      final String address = normal(member);
      if (address.isNotEmpty &&
          !friends.contains(address) &&
          !blocked.contains(address)) {
        members.add(address);
      }
    }
  }
  return BackgroundCapabilityDraft(
    inboxPublicKey: inboxPublicKey,
    friends: friends,
    groupMembers: members,
    blocked: blocked,
    mailboxes: <String>[
      for (final String mailbox in mailboxes)
        if (normal(mailbox).isNotEmpty) normal(mailbox),
    ],
  );
}

/// What in [state] changes the background capability (to republish it
/// only then).
String backgroundContactsSignature(SocialHubState state) {
  final List<String> parts = <String>[
    for (final FriendProfile friend in state.friends.values)
      '${friend.status.name}:${friend.address}',
    for (final GroupProfile group in state.groups.values)
      if (!group.isInvitePending)
        'g:${group.id}:${group.createdById}:${group.memberAddresses.join(',')}',
  ]..sort();
  return parts.join('|');
}

/// The Android background service while the app is locked or gone
/// (§14.1): it holds no master key, only the [BackgroundCapability].
///
/// * Frames from contacts (and, within a small budget, what a stranger
///   must be able to leave: a friend request, a neighbour) are sealed into
///   the inbox; a reliable one is acknowledged (`rly_ack`) only once it is
///   on the disk, so nothing the sender drops is lost. The app opens and
///   merges them after unlock.
/// * Presence: a ping from a contact gets a pong ("background"), so
///   friends deliver directly instead of through mailboxes. It pings no
///   one itself.
/// * Its own mailboxes are asked for held mail (`rly_poll`); the mail is
///   kept like any frame.
/// * The power-button alarm goes out from the alarm kit ([LockedAlarm]):
///   the frames it needs to see (confirmations, answers, pings) are shown
///   to it as well.
/// * Paused while locked: mailbox duties for friends, the ledger (posts and
///   photos for friends, its sync), outgoing retries, dating and pyramid
///   duties — they all need the master key.
/// * Notifications say only what kind of thing came (a message, an alarm, a
///   call), never from whom or what: nothing else is readable here.
final class LockedReceiver {
  LockedReceiver({
    required SignalTransport transport,
    required BackgroundCapability capability,
    required SealedInboxWriter inbox,
    required RuntimeSystemNotificationService notices,
    LockedAlarm? alarm,
    int Function()? now,
    this.ringTimeout = const Duration(seconds: 6),
    this.noticeThrottle = const Duration(minutes: 1),
    this.mailboxPollInterval = kLockedMailboxPollInterval,
  }) : _transport = transport,
       _capability = capability,
       _inbox = inbox,
       _notices = notices,
       _alarm = alarm,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SignalTransport _transport;
  final BackgroundCapability _capability;
  final SealedInboxWriter _inbox;
  final RuntimeSystemNotificationService _notices;

  /// This person's alarm from the alarm kit (`null`: the app never wrote
  /// one).
  final LockedAlarm? _alarm;
  final int Function() _now;

  /// A caller re-sends its invite every second while it rings: this long
  /// without one, the ring is over.
  final Duration ringTimeout;

  /// The same kind of notice at most this often.
  final Duration noticeThrottle;
  final Duration mailboxPollInterval;

  StreamSubscription<SignalTransportFrame>? _subscription;
  Timer? _pollTimer;
  Timer? _ringTimer;
  String? _ringingFrom;
  bool _running = false;

  /// What was kept in this run (repeats are not kept twice).
  final LinkedHashSet<String> _kept = LinkedHashSet<String>();
  static const int _maxKeptIds = 4000;

  final Map<String, int> _strangerFrames = <String, int>{};
  int _strangerTotal = 0;
  final Map<String, int> _lastNoticeAt = <String, int>{};

  /// Records kept in this run (tests, logs).
  int get keptCount => _keptCount;
  int _keptCount = 0;

  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    // Before the node starts: `frames` is a broadcast stream.
    _subscription = _transport.frames.listen(
      (SignalTransportFrame frame) => unawaitedLogged(
        handleFrame(frame),
        context: 'A frame for the locked inbox failed',
      ),
    );
    try {
      await _transport.start();
    } on Object catch (error, stackTrace) {
      // The node retries on its own; frames come once it runs.
      logZenError('The locked receiver node did not start', error, stackTrace);
    }
    if (!_running) {
      return;
    }
    // An alarm that was going on when the app locked carries on here.
    await _alarm?.start();
    await _pollMailboxes();
    if (mailboxPollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(
        mailboxPollInterval,
        (_) => unawaitedLogged(_pollMailboxes(), context: 'Mailbox poll'),
      );
    }
    logZenMessage(
      'Locked receiver runs (no master key; '
      '${_capability.mailboxes.length} mailboxes).',
    );
  }

  Future<void> stop() async {
    _running = false;
    await _alarm?.stop();
    _pollTimer?.cancel();
    _pollTimer = null;
    _ringTimer?.cancel();
    _ringTimer = null;
    _ringingFrom = null;
    await _subscription?.cancel();
    _subscription = null;
    await _transport.stop();
  }

  Future<void> _pollMailboxes() async {
    for (final String mailbox in _capability.mailboxes) {
      if (!_running) {
        return;
      }
      await _sendQuietly(mailbox, const <String, dynamic>{'type': 'rly_poll'});
    }
  }

  Future<void> _sendQuietly(String to, Map<String, dynamic> payload) async {
    try {
      await _transport.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      logZenWarning('The locked receiver could not answer: $error');
    }
  }

  /// One frame from the node.
  @visibleForTesting
  Future<void> handleFrame(SignalTransportFrame frame) async {
    if (!_running || frame.door) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final Object? rawType = frame.payload['type'];
    final String type = rawType is String ? rawType : '';
    final BackgroundContactKind kind = _capability.kindOf(from);
    if (from.isEmpty || kind == BackgroundContactKind.blocked) {
      return;
    }
    final bool contact = kind != BackgroundContactKind.stranger;
    // Friends' confirmations and answers, and mailboxes (possibly strangers
    // here) taking their copy of the alarm.
    _alarm?.observe(frame);
    if (type == 'ping') {
      if (contact) {
        await _sendQuietly(frame.from, <String, dynamic>{
          'type': 'pong',
          'state': 'background',
          if (kind == BackgroundContactKind.friend) ...versionHello(),
        });
      }
      return;
    }
    if (type == 'pong') {
      return;
    }
    if (_isRealTime(type)) {
      if (contact) {
        await _followRing(from, type);
      }
      return;
    }
    if (type.startsWith('rly_')) {
      if (contact && _keptRelayTypes.contains(type)) {
        await _keep(frame, from, type, kind, rid: null);
      }
      return;
    }
    if (type.startsWith('lg_')) {
      if (contact && _keptLedgerTypes.contains(type)) {
        await _keep(frame, from, type, kind, rid: null);
      }
      return;
    }
    final Object? rawRid = frame.payload[kReliableIdKey];
    final String? rid = rawRid is String && rawRid.isNotEmpty ? rawRid : null;
    if (!contact) {
      // From strangers only what was meant to arrive (it is reliable), and
      // only a little of it.
      if (rid == null || !_strangerMayLeave(from)) {
        return;
      }
    }
    await _keep(frame, from, type, kind, rid: rid);
  }

  bool _strangerMayLeave(String from) {
    final int sent = _strangerFrames[from] ?? 0;
    if (sent >= kLockedStrangerFramesPerSender ||
        _strangerTotal >= kLockedStrangerFramesTotal) {
      return false;
    }
    _strangerFrames[from] = sent + 1;
    _strangerTotal += 1;
    return true;
  }

  Future<void> _keep(
    SignalTransportFrame frame,
    String from,
    String type,
    BackgroundContactKind kind, {
    required String? rid,
  }) async {
    final Uint8List record;
    try {
      record = encodeInboxFrame(frame);
    } on Object {
      return; // not JSON: nothing this app sends
    }
    final String id = rid != null
        ? 'r|$from|$rid'
        : 'h|$from|${crypto.sha256.convert(record)}';
    if (_kept.contains(id)) {
      // A repeat: the sender did not hear the first acknowledgement.
      if (rid != null) {
        await _acknowledge(frame.from, rid);
      }
      return;
    }
    if (!await _inbox.append(
      record,
      sender: from,
      stranger: kind == BackgroundContactKind.stranger,
    )) {
      // Not on the disk (or the sender used its share of the inbox): not
      // acknowledged either, the sender keeps it (and its mailboxes get
      // it).
      return;
    }
    _kept.add(id);
    while (_kept.length > _maxKeptIds) {
      _kept.remove(_kept.first);
    }
    _keptCount += 1;
    if (rid != null) {
      await _acknowledge(frame.from, rid);
    }
    await _announce(type, frame.payload, kind);
  }

  Future<void> _acknowledge(String to, String rid) =>
      _sendQuietly(to, <String, dynamic>{'type': 'rly_ack', 'rid': rid});

  Future<void> _announce(
    String type,
    Map<String, dynamic> payload,
    BackgroundContactKind kind,
  ) async {
    if (type == 'alarm') {
      if (payload['end'] != null || kind != BackgroundContactKind.friend) {
        // Over (the app tells about it after unlock), or from someone whose
        // alarm the app does not take.
        return;
      }
      await _post(
        RuntimeSystemNotification(
          id: '$kLockedAlarmSlot-${_now()}',
          title: t('🚨 ALARM: ktoś bliski potrzebuje pomocy'),
          body: t('Odblokuj Zen, żeby zobaczyć, kto i gdzie.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.alarm,
          routeKey: buildInboxRouteKey(),
          slotKey: kLockedAlarmSlot,
          isRingingCall: true,
        ),
      );
      return;
    }
    if (_messageTypes.contains(type)) {
      await _postThrottled(
        RuntimeSystemNotification(
          id: '$kLockedMessageSlot-${_now()}',
          title: t('Nowa wiadomość'),
          body: t('Odblokuj Zen, żeby przeczytać.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.message,
          routeKey: buildInboxRouteKey(),
          slotKey: kLockedMessageSlot,
          contentRedacted: true,
        ),
      );
      return;
    }
    if (_socialTypes.contains(type)) {
      await _postThrottled(
        RuntimeSystemNotification(
          id: '$kLockedSocialSlot-${_now()}',
          title: PrivacyRedactingNotificationService.genericTitle,
          body: t('Odblokuj Zen, żeby zobaczyć szczegóły.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          routeKey: buildInboxRouteKey(),
          slotKey: kLockedSocialSlot,
          contentRedacted: true,
        ),
      );
    }
  }

  /// A ring keeps the call notice up; it ends with the caller's own end or
  /// once the invites stop, and leaves a "missed call" behind.
  Future<void> _followRing(String from, String type) async {
    if (_ringTypes.contains(type)) {
      final bool fresh = _ringingFrom == null;
      _ringingFrom = from;
      _ringTimer?.cancel();
      _ringTimer = Timer(ringTimeout, () {
        unawaitedLogged(_ringEnded(), context: 'Locked ring end');
      });
      if (fresh) {
        await _post(
          RuntimeSystemNotification(
            id: '$kLockedCallSlot-${_now()}',
            title: t('Połączenie przychodzące'),
            body: t('Odblokuj Zen, żeby odebrać.'),
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.call,
            routeKey: buildInboxRouteKey(),
            slotKey: kLockedCallSlot,
            isRingingCall: true,
          ),
        );
      }
      return;
    }
    if (_ringEndTypes.contains(type) && _ringingFrom == from) {
      await _ringEnded();
    }
  }

  Future<void> _ringEnded() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    if (_ringingFrom == null) {
      return;
    }
    _ringingFrom = null;
    await _notices.dismissSlot(kLockedCallSlot);
    await _post(
      RuntimeSystemNotification(
        id: '$kLockedMissedCallSlot-${_now()}',
        title: t('Nieodebrane połączenie'),
        body: t('Ktoś dzwonił, gdy Zen był zablokowany.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.message,
        routeKey: buildInboxRouteKey(),
        slotKey: kLockedMissedCallSlot,
        contentRedacted: true,
      ),
    );
  }

  /// The power-button shortcut while the app is locked or closed: the alarm
  /// goes out from the alarm kit. Without a kit (the app was not unlocked
  /// since it was installed) it is said plainly that it did not go out.
  Future<void> onPowerShortcut() async {
    final LockedAlarm? alarm = _alarm;
    if (alarm != null) {
      try {
        final ShortcutAlarmResult result = await alarm.raise();
        logZenMessage('Power-button alarm while locked: ${result.name}.');
        if (result == ShortcutAlarmResult.raised ||
            result == ShortcutAlarmResult.alreadyRunning) {
          return;
        }
      } on Object catch (error, stackTrace) {
        logZenError('The locked alarm failed', error, stackTrace);
      }
    }
    await _post(
      RuntimeSystemNotification(
        id: '$kLockedPowerAlarmSlot-${_now()}',
        title: t('Alarm nie został wysłany'),
        body: t('Zen jest zablokowany. Odblokuj go, żeby wysłać alarm.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.message,
        routeKey: buildInboxRouteKey(),
        slotKey: kLockedPowerAlarmSlot,
        contentRedacted: true,
      ),
    );
  }

  /// One entry per kind at most every [noticeThrottle], posted anew (so
  /// the shade does not stack the same line).
  Future<void> _postThrottled(RuntimeSystemNotification notice) async {
    final String slot = notice.slotKey!;
    final int now = _now();
    final int? last = _lastNoticeAt[slot];
    if (last != null && now - last < noticeThrottle.inMilliseconds) {
      return;
    }
    _lastNoticeAt[slot] = now;
    await _notices.dismissSlot(slot);
    await _post(notice);
  }

  Future<void> _post(RuntimeSystemNotification notice) async {
    try {
      await _notices.show(notice);
    } on Object catch (error, stackTrace) {
      logZenError('A locked notice failed', error, stackTrace);
    }
  }
}
