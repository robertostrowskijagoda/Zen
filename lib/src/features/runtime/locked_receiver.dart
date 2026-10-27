import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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
import 'package:zen/src/features/neighbors/locked_knocks.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/app_security_service.dart';
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
const String kLockedKnockSlot = 'locked-inbox-knock';

const List<String> kLockedReceiverSlots = <String>[
  kLockedMessageSlot,
  kLockedSocialSlot,
  kLockedAlarmSlot,
  kLockedCallSlot,
  kLockedMissedCallSlot,
  kLockedPowerAlarmSlot,
  kLockedKnockSlot,
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
/// sent, friends' mailbox sets): kept, the app's relay layer handles them
/// after unlock. Mail held for this phone (`rly_mail`) is kept envelope by
/// envelope ([LockedReceiver._keepMail]). The mailbox duties for friends
/// ([LockedMailbox.dutyTypes]) go to the [LockedMailbox] the app left a kit
/// for; without one they go unanswered and the friends' phones use their
/// other mailboxes. Anything else (attachments held for friends) waits.
const Set<String> _keptRelayTypes = <String>{
  'rly_ack',
  'rly_announce',
  'rly_announce_ack',
  'rly_deposit_ack',
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

/// How often the receiver asks its mailboxes for mail held for it, at
/// first and again once something came.
///
/// The polls only back the mailboxes up: they hand mail over by themselves
/// the moment it is deposited while this phone is reachable, and whenever
/// it shows a sign of life. A poll catches what such a hand-over missed.
const Duration kLockedMailboxPollInterval = Duration(minutes: 5);

/// The longest wait between polls: each poll that brought nothing doubles
/// the wait (5, 10, 20, 30 minutes), all multiples of the first, so the
/// polls keep sharing their wakes with the rest of the beat.
const Duration kLockedMailboxPollMaxInterval = Duration(minutes: 30);

/// The wait before the mailboxes are asked again, after one that lasted
/// [last]: [base] when something was kept since the last poll, otherwise
/// twice [last], at most [max].
Duration nextMailboxPollWait({
  required Duration last,
  required bool keptSince,
  Duration base = kLockedMailboxPollInterval,
  Duration max = kLockedMailboxPollMaxInterval,
}) {
  if (keptSince || last < base) {
    return base;
  }
  final Duration doubled = last * 2;
  return doubled > max ? max : doubled;
}

/// How often a locked phone answers one contact's pings at most.
const Duration kLockedPongEvery = Duration(minutes: 4);

/// "I am leaving the screen": sent to friends when Zen goes to the
/// background (runtime_signal_module.dart). Nothing to keep for later.
const String kPresenceAwayType = 'away';

/// What came to a door while the app was locked, per run of the receiver
/// (knocks and neighbour flats' frames, from anyone who has the sticker).
const int kLockedDoorFramesPerSender = 5;
const int kLockedDoorFramesTotal = 50;

/// One frame as the inbox keeps it (JSON: sender, time, payload, `d`
/// when it came to a door, `k` the sender's device key fingerprint).
Uint8List encodeInboxFrame(SignalTransportFrame frame) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'f': frame.from,
        't': frame.receivedAtMillis,
        'p': frame.payload,
        if (frame.door) 'd': true,
        if (frame.senderKey != null) 'k': frame.senderKey,
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
      door: json['d'] == true,
      senderKey: json['k'] is String ? json['k'] as String : null,
    );
  } on FormatException {
    return null;
  }
}

/// A JSON document in the background folder sealed with the background key
/// (`BackgroundKeyProtector`): what the locked service needs besides the
/// capability (the nearby kit, the door kit). The app writes it and makes
/// the key; the service only reads it.
final class BackgroundKitFile {
  BackgroundKitFile({
    required Future<Directory> Function() supportDirectory,
    required AppSecurityCredentialsStore credentials,
    required this.storageKey,
    required this.fileName,
    this.createKey = false,
  }) : _supportDirectory = supportDirectory,
       _credentials = credentials;

  final String storageKey;
  final String fileName;

  /// Whether this side makes the background key when there is none (the
  /// app does; the service never does).
  final bool createKey;
  final Future<Directory> Function() _supportDirectory;
  final AppSecurityCredentialsStore _credentials;

  Future<File> file() async {
    final Directory support = await _supportDirectory();
    final String sep = Platform.pathSeparator;
    return File(
      '${support.path}$sep${FileBackgroundVault.folderName}$sep$fileName',
    );
  }

  Future<void> write(Object? json) async {
    final Uint8List sealed = await BackgroundKeyProtector(
      _credentials,
      createKey: createKey,
    ).sealFor(storageKey, Uint8List.fromList(utf8.encode(jsonEncode(json))));
    final File target = await file();
    await target.parent.create(recursive: true);
    // Beside the file and moved over it: the service reads the old one or
    // the new one, never half of one.
    final File next = File('${target.path}.next');
    await next.writeAsBytes(sealed, flush: true);
    await next.rename(target.path);
  }

  /// The document last written; `null` when there is none or it does not
  /// open.
  Future<Object?> read() async {
    final File source = await file();
    if (!await source.exists()) {
      return null;
    }
    try {
      final Uint8List plain = await BackgroundKeyProtector(
        _credentials,
      ).unsealFor(storageKey, await source.readAsBytes());
      return jsonDecode(utf8.decode(plain));
    } on Object catch (error, stackTrace) {
      logZenError(
        'A background kit is unreadable ($fileName)',
        error,
        stackTrace,
      );
      return null;
    }
  }
}

final RegExp _doorSeedPattern = RegExp(r'^[0-9a-f]{64}$');

/// What the locked service runs the doors with: the flat's door key and
/// the keys of the mailbox doors this phone runs for friends; and what it
/// tells a knock by ([LockedKnockWatch]): the household's public key, the
/// door token and the household's sealing seed, which opens sealed knocks
/// and nothing else. Sealed with the background key, like the alarm kit:
/// none of it signs for the household or reads anything but knocks (the
/// household's own key stays under the master key), and the doors answer
/// nothing while locked.
@immutable
final class LockedDoorKit {
  const LockedDoorKit({
    this.doorKey,
    this.mailboxDoorKeys = const <String>[],
    this.flatKey,
    this.doorToken,
    this.sealSeed,
    this.tempTokens = const <String, int>{},
  });

  /// The flat's door key (hex seed); `null` without a flat.
  final String? doorKey;

  /// Keys (hex seeds) of the mailbox doors run for friends.
  final List<String> mailboxDoorKeys;

  /// The household's public key, the current door token and the
  /// household's sealing seed (hex); `null` without a flat.
  final String? flatKey;
  final String? doorToken;
  final String? sealSeed;

  /// Short-lived door tokens of invitations passed nearby (token → until
  /// when).
  final Map<String, int> tempTokens;

  bool get isEmpty => doorKey == null && mailboxDoorKeys.isEmpty;

  /// What tells a knock while locked; `null` without a flat.
  LockedKnockWatch? knockWatch() {
    final String? key = flatKey;
    final String? token = doorToken;
    final String? seal = sealSeed;
    return key == null || token == null || seal == null
        ? null
        : LockedKnockWatch(
            flatKey: key,
            doorToken: token,
            sealSeed: seal,
            tempTokens: tempTokens,
          );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'dk': ?doorKey,
    'mb': mailboxDoorKeys,
    'fk': ?flatKey,
    'dt': ?doorToken,
    'ss': ?sealSeed,
    if (tempTokens.isNotEmpty) 'tt': tempTokens,
  };

  static LockedDoorKit? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) {
      return null;
    }
    final Object? dk = json['dk'];
    final Object? mb = json['mb'];
    final Object? fk = json['fk'];
    final Object? dt = json['dt'];
    final Object? ss = json['ss'];
    final Object? tt = json['tt'];
    return LockedDoorKit(
      doorKey: dk is String && _doorSeedPattern.hasMatch(dk) ? dk : null,
      mailboxDoorKeys: <String>[
        if (mb is List)
          for (final Object? seed in mb.take(16))
            if (seed is String && _doorSeedPattern.hasMatch(seed)) seed,
      ],
      flatKey: fk is String && fk.isNotEmpty && fk.length <= 64 ? fk : null,
      doorToken: dt is String && dt.isNotEmpty && dt.length <= 64 ? dt : null,
      sealSeed: ss is String && _doorSeedPattern.hasMatch(ss) ? ss : null,
      tempTokens: <String, int>{
        if (tt is Map)
          for (final MapEntry<dynamic, dynamic> e in tt.entries.take(32))
            if (e.key is String &&
                (e.key as String).length <= 64 &&
                e.value is int)
              e.key as String: e.value as int,
      },
    );
  }
}

/// Where the door kit is kept.
BackgroundKitFile lockedDoorKitFile({
  required Future<Directory> Function() supportDirectory,
  required AppSecurityCredentialsStore credentials,
  bool createKey = false,
}) => BackgroundKitFile(
  supportDirectory: supportDirectory,
  credentials: credentials,
  storageKey: 'background/door-kit',
  fileName: 'door-kit.zenbg',
  createKey: createKey,
);

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
    // A device its owner unlinked (lost or stolen) is no contact; the
    // account's other devices are.
    if (directory?.unlinkedAccountOf(friend.address) == null) {
      friends.add(address);
    }
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
      // A friend's unlinked phone in a shared group is no member either.
      if (address.isNotEmpty &&
          !friends.contains(address) &&
          !blocked.contains(address) &&
          directory?.unlinkedAccountOf(member) == null) {
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

/// The Android background service while the app is locked or gone:
/// it holds no master key, only the [BackgroundCapability].
///
/// * Frames from contacts (and, within a small budget, what a stranger
///   must be able to leave: a friend request, a neighbour) are sealed into
///   the inbox; a reliable one is acknowledged (`rly_ack`) only once it is
///   on the disk, so nothing the sender drops is lost. The app opens and
///   merges them after unlock.
/// * Presence: a ping from a contact gets a pong ("background"), so
///   friends deliver directly instead of through mailboxes. It pings no
///   one itself.
/// * Its own mailboxes are asked for held mail (`rly_poll`); each envelope
///   is kept once (also when it came directly before, or the app already
///   took it: `taken`) and confirmed to whoever handed it over, so it is
///   not handed over (and told about) again and again.
/// * Mailbox duties for friends run from the mailbox kit ([LockedMailbox]):
///   friends who chose this phone as a mailbox keep it while Zen is locked.
/// * The power-button alarm goes out from the alarm kit ([LockedAlarm]):
///   the frames it needs to see (confirmations, answers, pings) are shown
///   to it as well.
/// * The doors ([doorFrames], run from the [LockedDoorKit]): knocks at the
///   flat's door, neighbour flats' frames and sealed knocks at the mailbox
///   doors run for friends are kept like strangers' frames (a budget of
///   their own) and never answered — a door never says who runs it, and
///   the app handles them after unlock. A real knock for this household
///   (checked with the kit, [LockedKnockWatch]: at the door, sealed, held
///   by a friend or passed on by a housemate) rings "Ktoś puka do drzwi",
///   which opens the knocks once Zen is unlocked.
/// * Paused while locked: attachments held for friends, the ledger (posts
///   and photos for friends, its sync), dating and pyramid duties — they
///   need the master key. (Outgoing retries go from the outbox kit,
///   `LockedOutbox`.)
/// * Notifications say only what kind of thing came (a message, an alarm, a
///   call), never from whom or what: nothing else is readable here.
final class LockedReceiver {
  LockedReceiver({
    required SignalTransport transport,
    required BackgroundCapability capability,
    required SealedInboxWriter inbox,
    required RuntimeSystemNotificationService notices,
    LockedAlarm? alarm,
    Stream<SignalTransportFrame>? doorFrames,
    LockedKnockWatch? knocks,
    LockedMailbox? mailbox,
    Set<String> taken = const <String>{},
    int Function()? now,
    this.ringTimeout = const Duration(seconds: 6),
    this.noticeThrottle = const Duration(minutes: 1),
    this.mailboxPollInterval = kLockedMailboxPollInterval,
    this.mailboxPollMax = kLockedMailboxPollMaxInterval,
    this.pollAnswerGrace = const Duration(seconds: 3),
    this.pongEvery = kLockedPongEvery,
  }) : _transport = transport,
       _capability = capability,
       _inbox = inbox,
       _notices = notices,
       _alarm = alarm,
       _doorFrames = doorFrames,
       _knocks = knocks,
       _mailbox = mailbox,
       _taken = taken,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SignalTransport _transport;
  final BackgroundCapability _capability;
  final SealedInboxWriter _inbox;
  final RuntimeSystemNotificationService _notices;

  /// What came to the doors the node runs (`RuntimeNodeRuntime.doorFrames`);
  /// `null`: no doors.
  final Stream<SignalTransportFrame>? _doorFrames;

  /// Tells knocks for this household (`null`: no flat, or no kit yet).
  final LockedKnockWatch? _knocks;

  /// This person's alarm from the alarm kit (`null`: the app never wrote
  /// one).
  final LockedAlarm? _alarm;

  /// This phone as a mailbox for friends (`null`: no mailbox kit).
  final LockedMailbox? _mailbox;

  /// [LockedMailboxKit.takenTag]s of what the app already took before it
  /// locked: a copy of one is confirmed, never kept or told about again.
  final Set<String> _taken;
  final int Function() _now;

  /// A caller re-sends its invite every second while it rings: this long
  /// without one, the ring is over.
  final Duration ringTimeout;

  /// The same kind of notice at most this often.
  final Duration noticeThrottle;
  final Duration mailboxPollInterval;

  /// The longest wait between polls ([nextMailboxPollWait]).
  final Duration mailboxPollMax;

  /// How long a poll's wake waits for the mailboxes' first answers (later
  /// ones wake the phone themselves, like any frame).
  final Duration pollAnswerGrace;

  /// A contact's pings get a pong at most this often: friends ping only
  /// while Zen is on their screen, and a pong every other ping keeps this
  /// phone "in the background" for them (kPresenceOfflineAfter).
  final Duration pongEvery;
  final Map<String, int> _pongedAt = <String, int>{};

  StreamSubscription<SignalTransportFrame>? _subscription;
  StreamSubscription<SignalTransportFrame>? _doorSubscription;
  final Map<String, int> _doorFramesBy = <String, int>{};
  int _doorFramesTotal = 0;
  BeatTimer? _pollTimer;

  /// [keptCount] when the last poll went out.
  int _keptAtPoll = 0;
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
    _doorSubscription = _doorFrames?.listen(
      (SignalTransportFrame frame) => unawaitedLogged(
        // Kept and rung (a knock): the phone stays awake until done.
        ZenWake.holdWhile(
          () => handleDoorFrame(frame),
          tag: _keepHoldTag,
          limit: _keepHoldLimit,
        ),
        context: 'A door frame for the locked inbox failed',
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
    _keptAtPoll = _keptCount;
    await _pollMailboxes();
    if (mailboxPollInterval > Duration.zero &&
        _capability.mailboxes.isNotEmpty) {
      // On the shared beat: one wake of the phone for the polls of every
      // account (and a look around nearby, the outbox's rounds), held for
      // the polls and their first answers and let go then. Polls that find
      // nothing come less and less often ([nextMailboxPollWait]).
      _pollTimer = ZenWake.beat(
        'mailbox-poll',
        mailboxPollInterval,
        _pollOnWake,
        hold: const Duration(seconds: 10),
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
    await _doorSubscription?.cancel();
    _doorSubscription = null;
    await _transport.stop();
  }

  /// One frame that came to a door: kept for the app (the neighbours
  /// section handles it after unlock), within [kLockedDoorFramesPerSender]
  /// and [kLockedDoorFramesTotal], and never answered.
  @visibleForTesting
  Future<void> handleDoorFrame(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String ||
        !_running ||
        !frame.door ||
        !kFlatDoorTypes.contains(type)) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    if (from.isEmpty ||
        _capability.kindOf(from) == BackgroundContactKind.blocked) {
      return;
    }
    final Uint8List record;
    try {
      record = encodeInboxFrame(frame);
    } on Object {
      return;
    }
    // A knocker retries the same knock until it gives up: kept once.
    final Object? rawRid = frame.payload[kReliableIdKey];
    final String id = rawRid is String && rawRid.isNotEmpty
        ? 'd|$from|$rawRid'
        : 'd|$from|${_payloadHash(frame.payload)}';
    if (_kept.contains(id)) {
      return;
    }
    final int sent = _doorFramesBy[from] ?? 0;
    if (sent >= kLockedDoorFramesPerSender ||
        _doorFramesTotal >= kLockedDoorFramesTotal) {
      return;
    }
    _doorFramesBy[from] = sent + 1;
    _doorFramesTotal += 1;
    // Taken before the write: a retry arriving meanwhile is the same knock.
    _kept.add(id);
    while (_kept.length > _maxKeptIds) {
      _kept.remove(_kept.first);
    }
    if (!await _inbox.append(record, sender: from, stranger: true)) {
      _kept.remove(id);
      return;
    }
    _keptCount += 1;
    if (await _ringKnock(frame)) {
      return;
    }
    if ((type == kFlatKnockType && _knocks == null) || type == 'flat_msg') {
      // A neighbour's message, or a knock without a kit to check it with:
      // only that something came, at most once a minute.
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

  /// "Ktoś puka do drzwi" when [frame] is a knock for this household
  /// ([LockedKnockWatch]); true when it was one.
  Future<bool> _ringKnock(SignalTransportFrame frame) async {
    final LockedKnockWatch? watch = _knocks;
    final String? knocker = watch == null ? null : await watch.knocker(frame);
    if (watch == null || knocker == null) {
      return false;
    }
    if (watch.mayRing(knocker)) {
      await _notices.dismissSlot(kLockedKnockSlot);
      await _post(
        RuntimeSystemNotification(
          // `flat-`: the neighbours' knock sound.
          id: 'flat-knock-locked-${_now()}',
          title: t('Ktoś puka do drzwi'),
          body: t('Odblokuj Zen, żeby wpuścić albo odmówić.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          routeKey: buildFlatKnocksRouteKey(),
          slotKey: kLockedKnockSlot,
          contentRedacted: true,
        ),
      );
    }
    return true;
  }

  /// The polls on a wake, then a moment for the answers (mail that comes
  /// later wakes the phone itself, like any frame).
  Future<void> _pollOnWake() async {
    final BeatTimer? poll = _pollTimer;
    if (poll != null) {
      final Duration next = nextMailboxPollWait(
        last: poll.every,
        keptSince: _keptCount != _keptAtPoll,
        base: mailboxPollInterval,
        max: mailboxPollMax,
      );
      if (next != poll.every) {
        poll.setEvery(next);
      }
    }
    _keptAtPoll = _keptCount;
    try {
      await _pollMailboxes();
    } on Object catch (error, stackTrace) {
      logZenError('Mailbox poll failed', error, stackTrace);
    }
    if (_running) {
      await Future<void>.delayed(pollAnswerGrace);
    }
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
      final int at = _now();
      final int? last = _pongedAt[from];
      if (contact && (last == null || at - last >= pongEvery.inMilliseconds)) {
        _pongedAt[from] = at;
        await _sendQuietly(frame.from, <String, dynamic>{
          'type': 'pong',
          'state': 'background',
          if (kind == BackgroundContactKind.friend) ...versionHello(),
        });
      }
      return;
    }
    if (type == 'pong' || type == kPresenceAwayType) {
      return;
    }
    if (_isRealTime(type)) {
      if (contact) {
        await _followRing(from, type);
      }
      return;
    }
    if (type.startsWith('rly_')) {
      final LockedMailbox? mailbox = _mailbox;
      if (mailbox != null && LockedMailbox.dutyTypes.contains(type)) {
        // From friends' senders too, who need not be contacts here: the
        // mailbox checks who may leave what.
        await ZenWake.holdWhile(
          () => mailbox.handle(frame),
          tag: _keepHoldTag,
          limit: _keepHoldLimit,
        );
        return;
      }
      if (contact && type == 'rly_mail') {
        await ZenWake.holdWhile(
          () => _keepMail(frame, from, kind),
          tag: _keepHoldTag,
          limit: _keepHoldLimit,
        );
        return;
      }
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

  /// Keeps [frame] in the inbox (and tells about it): the phone stays
  /// awake until that is done, then may sleep (a frame that is dropped
  /// costs only the short hold of its arrival).
  Future<void> _keep(
    SignalTransportFrame frame,
    String from,
    String type,
    BackgroundContactKind kind, {
    required String? rid,
  }) => ZenWake.holdWhile(
    () => _keepHeld(frame, from, type, kind, rid: rid),
    tag: _keepHoldTag,
    limit: _keepHoldLimit,
  );

  static const String _keepHoldTag = 'locked-keep';
  static const Duration _keepHoldLimit = Duration(seconds: 20);

  Future<void> _keepHeld(
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
        : 'h|$from|${_payloadHash(frame.payload)}';
    if (_kept.contains(id) ||
        (rid != null &&
            _taken.contains(LockedMailboxKit.takenTag(from, rid)))) {
      // A repeat (the sender did not hear the first acknowledgement), or
      // what the app took before it locked.
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
    _noteKept();
    if (rid != null) {
      await _acknowledge(frame.from, rid);
    }
    // A knock a friend held for this phone, or one a housemate just got.
    if ((type == 'flat_held' || type == 'flat_house') &&
        await _ringKnock(frame)) {
      return;
    }
    await _announce(type, frame.payload, kind);
  }

  /// Something from friends was kept: more may be on its way, so the
  /// mailboxes are asked again in [mailboxPollInterval] (not after a long
  /// wait that grew while nothing came).
  void _noteKept() {
    _keptCount += 1;
    final BeatTimer? poll = _pollTimer;
    if (poll != null && poll.every > mailboxPollInterval) {
      poll.setEvery(mailboxPollInterval);
    }
  }

  /// How long until the next poll now (tests).
  @visibleForTesting
  Duration? get mailboxPollWait => _pollTimer?.every;

  Future<void> _acknowledge(String to, String rid) =>
      _sendQuietly(to, <String, dynamic>{'type': 'rly_ack', 'rid': rid});

  /// What a frame without a reliable id is told apart by: its payload, not
  /// the moment it arrived (a repeat arrives later).
  static String _payloadHash(Map<String, dynamic> payload) =>
      crypto.sha256.convert(utf8.encode(jsonEncode(payload))).toString();

  /// Mail held for this phone, from one of its mailboxes or straight from a
  /// sender's locked outbox. Each envelope counts as its payload would
  /// directly (`r|sender|id`): one that came already, directly or from
  /// another mailbox, or that the app took before it locked, is not kept
  /// or told about again. Whoever handed the envelopes over hears that they
  /// are here once they are on the disk (`rly_mail_ack`; a sender also
  /// `rly_ack`), so it stops handing them over. The app opens and checks
  /// them after unlock; the other mailboxes keep their copies until then.
  Future<void> _keepMail(
    SignalTransportFrame frame,
    String from,
    BackgroundContactKind kind,
  ) async {
    final Object? items = frame.payload['items'];
    if (items is! List) {
      return;
    }
    final List<Map<String, dynamic>> fresh = <Map<String, dynamic>>[];
    final List<String> freshKeys = <String>[];
    final List<String> here = <String>[];
    final List<String> fromSender = <String>[];
    for (final Object? item in items.take(200)) {
      if (item is! Map) {
        continue;
      }
      final Object? id = item['id'];
      final Object? rawSender = item['s'];
      if (id is! String || id.isEmpty || rawSender is! String) {
        continue; // nothing the app could open either
      }
      final String sender = PeerShareCodec.normalizeAddress(rawSender);
      final String key = 'r|$sender|$id';
      if (sender == from) {
        fromSender.add(id);
      }
      if (_kept.contains(key) ||
          _taken.contains(LockedMailboxKit.takenTag(sender, id)) ||
          freshKeys.contains(key)) {
        here.add(id);
        continue;
      }
      fresh.add(Map<String, dynamic>.from(item));
      freshKeys.add(key);
    }
    if (fresh.isNotEmpty) {
      final Uint8List record;
      try {
        record = encodeInboxFrame(
          SignalTransportFrame(
            from: frame.from,
            payload: <String, dynamic>{'type': 'rly_mail', 'items': fresh},
            receivedAtMillis: frame.receivedAtMillis,
            senderKey: frame.senderKey,
          ),
        );
      } on Object {
        return;
      }
      if (await _inbox.append(
        record,
        sender: from,
        stranger: kind == BackgroundContactKind.stranger,
      )) {
        _kept.addAll(freshKeys);
        while (_kept.length > _maxKeptIds) {
          _kept.remove(_kept.first);
        }
        _noteKept();
        here.addAll(<String>[
          for (final Map<String, dynamic> item in fresh) item['id'] as String,
        ]);
      } else {
        // Not on the disk: not confirmed, the mailbox keeps it.
        fresh.clear();
      }
    }
    if (here.isNotEmpty) {
      await _sendQuietly(frame.from, <String, dynamic>{
        'type': 'rly_mail_ack',
        'ids': here,
      });
      for (final String id in fromSender) {
        if (here.contains(id)) {
          await _acknowledge(frame.from, id);
        }
      }
    }
    if (fresh.isNotEmpty) {
      await _announce('rly_mail', frame.payload, kind);
    }
  }

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
      // Awake while it rings: the ring ends (and "missed call" shows) when
      // the invites stop, which only a running timer notices.
      unawaited(
        ZenWake.hold(ringTimeout + const Duration(seconds: 2), tag: 'ring'),
      );
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
    try {
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
    } finally {
      unawaited(
        ZenWake.release(tag: 'ring', after: const Duration(seconds: 1)),
      );
    }
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
