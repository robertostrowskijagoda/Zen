import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/atomic_file.dart';
import 'package:zen/src/core/storage/unmetered_network.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/locked_alarm.dart';
import 'package:zen/src/features/neighbors/locked_knocks.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
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

/// The ledger's frames that come reliably (queued at the sender until this
/// phone confirms them, [kReliablePayloadTypes]): a post, comment or like
/// pushed to a friend who is away, a mention. Kept and confirmed like a
/// message. Dropped unconfirmed, as the other ledger frames are, each one
/// waited at its sender ("Czeka na doręczenie") and with the sender's
/// mailboxes for two weeks, tried again and again.
const Set<String> _reliableLedgerTypes = <String>{'lg_push', 'lg_mention'};

const Set<String> _messageTypes = <String>{
  'message',
  'group_message',
  'message_placeholder',
};

/// Of those, what the switch "Zaproszenia i prośby o kontakt" governs.
const Set<String> _invitationTypes = <String>{
  'friend_request',
  'friend_accept',
  'group_invite',
};

/// What is told about while locked besides messages, alarms and calls:
/// invitations only. Events, questions and meeting intents are kept
/// without a notice: most of their frames are updates (a guest list, an
/// answer counted, an intent renewed) the app announces nothing for, and
/// here each of them rang a bare "Nowe powiadomienie" — over and over while
/// a friend's event filled up. The app tells of a new invitation or a
/// cancellation once it opens them after unlock. Mail from a mailbox has
/// its own notice ([LockedReceiver._announceMail]).
const Set<String> _socialTypes = <String>{
  'friend_request',
  'friend_accept',
  'group_invite',
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

/// How often a locked phone answers one contact's pings at most. A contact
/// pings every kPresencePingInterval (2 min) while Zen is on their screen:
/// the first ping after a quiet while (Zen just came on their screen) is
/// answered at once, then every other one — a little under two intervals,
/// so however the timings drift, an answer comes every 4 min.
const Duration kLockedPongEvery = Duration(minutes: 3, seconds: 30);

/// A contact whose Zen just started marks its first pings so
/// ([kPresenceFreshKey]): the answer this phone gave before the start went
/// to an app that is gone, so it answers at once, whenever it answered
/// last, but at most this often, so marking every ping buys nobody more
/// than an answer twice a minute. The pings a start sends again in its
/// first minute to friends who did not answer come further apart.
const Duration kLockedFreshPongEvery = Duration(seconds: 20);

/// How often a locked phone asks the friends who see its status how they
/// are (a `ping`, on a wake of the shared beat, whatever the mailbox polls
/// do: those come every half hour once nothing comes, and friends whose
/// pings could not reach this phone between its wakes saw it "poza
/// siecią" for most of that), so the app knows their
/// statuses at once when it opens: their answers, and the pings of friends
/// with Zen open, are kept for the app as they come (the newest of each
/// friend, [kPresenceRememberedFor] old at most). Under
/// kPresenceRememberedFor, so a status is never unknown for want of a
/// round; a friend's locked phone answers at most every
/// [kLockedPongEvery].
const Duration kLockedPresenceRoundEvery = Duration(minutes: 10);

/// A friend this phone has heard nothing from for this long (no ping, pong
/// or `away`: their phone is off, or out of reach) gets a round's ping only
/// every [kLockedSilentRoundEvery]th round: the ping wakes nobody and only
/// costs this phone a send. Once back, the friend hears this phone at the
/// latest (kLockedSilentRoundEvery - 1) rounds later, unless their own
/// ping (Zen on their screen, or their own round) gets its pong first.
/// [kPresenceRememberedFor]: their status is no longer shown by then.
const Duration kLockedSilentAfter = Duration(minutes: 30);
const int kLockedSilentRoundEvery = 3;

/// How old a friend's frame in the locked service's presence file
/// (`presence.zbox`) may grow while newer frames of theirs say the same,
/// before it is written again, and how often at most the file is written
/// for that: each write seals the whole file anew, and with many friends
/// one of them comes due on almost every round's ping. A change (a friend's
/// first frame, another state, another last opening) is written at once.
/// The app reads the file when it opens and ages each status from its
/// frame: a friend "w tle" shows as such for [kPresenceBackgroundFor]
/// (25 min) from it, so a frame a few minutes older than the newest costs
/// them at most that much of it (the app asks every friend as it opens),
/// while the friend's pings and pongs (every few minutes each) mostly go
/// unwritten. What waits for the next write is written on the first frame
/// or presence round once the time is up, and when the receiver stops; if
/// the service is killed meanwhile, only the age of unchanged statuses is
/// lost: the file shows them from frames older than the newest by this
/// much and the wait for that frame or round (at most a round), never a
/// wrong state.
const Duration kKeptPresenceRefreshEvery = Duration(minutes: 5);

/// The same for a friend online, who counts as offline 5 minutes after
/// their last frame (kPresenceForegroundFor) and pings every 2 while Zen is
/// on their screen: every other ping is written (for all such friends at
/// once), so the written one is at most a ping older than the newest and
/// still says "online" when the app opens while the friend is on the
/// screen.
const Duration kKeptPresenceOnlineRefreshEvery = Duration(
  minutes: 2,
  seconds: 30,
);

/// A one-way presence announcement ("leaving the screen", "back", "closing"):
/// sent to friends who have Zen open when this device's state changes
/// (runtime_signal_module.dart). Nothing to keep for later.
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
    // The service reads the old one or the new one, never half of one.
    await writeFileAtomically(await file(), sealed);
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

/// The Android background service while the app is locked or gone, and an
/// iPhone's locked Zen while iOS lets it run (ios_locked_receiver.dart):
/// it holds no master key, only the [BackgroundCapability].
///
/// * Frames from contacts (and, within a small budget, what a stranger
///   must be able to leave: a friend request, a neighbour) are sealed into
///   the inbox; a reliable one is acknowledged (`rly_ack`) only once it is
///   on the disk, so nothing the sender drops is lost. The app opens and
///   merges them after unlock.
/// * Presence: a ping from a contact gets a pong, so friends deliver
///   directly instead of through mailboxes; to the friends who may see it
///   the pong also says "w tle" and when Zen was last open
///   ([LockedPresenceKit]). Its own pings go on the presence rounds
///   ([kLockedPresenceRoundEvery]).
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
/// * Notifications say what kind of thing came (a message, an alarm, a
///   call); a chat message also who wrote it and the start of what
///   ([kLockedNoticePreviewChars]), as far as the notification privacy
///   level of its conversation allows and the [LockedNoticeKit] knows the
///   name. A message is read here only in memory, for that; it is kept
///   only sealed. Nothing else is readable here.
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
    LockedNoticeKit? noticeKit,
    LockedPresenceKit? presence,
    SealedSnapshotWriter? presenceSnapshot,
    Set<String> taken = const <String>{},
    int Function()? now,
    this.ringTimeout = const Duration(seconds: 6),
    this.noticeThrottle = const Duration(minutes: 1),
    this.mailboxPollInterval = kLockedMailboxPollInterval,
    this.mailboxPollMax = kLockedMailboxPollMaxInterval,
    this.pollAnswerGrace = const Duration(seconds: 3),
    this.pongEvery = kLockedPongEvery,
    this.freshPongEvery = kLockedFreshPongEvery,
    this.presenceRoundEvery = kLockedPresenceRoundEvery,
    WakeBeat? beat,
    Future<bool> Function()? meshLinked,
    Future<bool> Function()? onNetwork,
    this.relinkWait = const Duration(seconds: 10),
    this.relinkStep = const Duration(milliseconds: 500),
  }) : _transport = transport,
       _beat = beat,
       _meshLinked = meshLinked,
       _onNetwork = onNetwork ?? onAnyNetwork,
       _capability = capability,
       _inbox = inbox,
       _notices = notices,
       _alarm = alarm,
       _doorFrames = doorFrames,
       _knocks = knocks,
       _mailbox = mailbox,
       _noticeKit = noticeKit ?? const LockedNoticeKit(),
       _presence = presence ?? const LockedPresenceKit(),
       _presenceSnapshot =
           presenceSnapshot ??
           SealedSnapshotWriter(
             file: File(
               '${inbox.file.parent.path}${Platform.pathSeparator}'
               '$kKeptPresenceFileName',
             ),
             recipientPublicKey: inbox.recipientPublicKey,
           ),
       _taken = taken,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SignalTransport _transport;
  final BackgroundCapability _capability;
  final SealedInboxWriter _inbox;
  final RuntimeSystemNotificationService _notices;

  /// The beat the mailbox polls go on (`null`: the app's, [ZenWake.beat]).
  final WakeBeat? _beat;

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

  /// What a message's notice may say (without a kit: only that it came).
  final LockedNoticeKit _noticeKit;

  /// What decides whether a call rings and a chat message is told about,
  /// by the app's own rules ([incomingAlertOf]): who is a friend from the
  /// capability, the rest from the notice kit. Without a kit only friends'
  /// calls and messages count; with a kit of before 1.16.5, which does not
  /// say who speaks in which group, the capability's friends and group
  /// members do, as they did then.
  late final AlertFacts _alertFacts = _noticeKit.alertFacts(
    isFriend: (String address) =>
        _capability.kindOf(address) == BackgroundContactKind.friend,
    inJoinedGroup: (String address) => switch (_capability.kindOf(address)) {
      BackgroundContactKind.friend || BackgroundContactKind.groupMember => true,
      _ => false,
    },
  );

  /// The mention notices of this run, per sender, as the app limits them.
  final MentionAlerts _mentionAlerts = MentionAlerts();

  /// The signal [payload] from [from] is, read as the app reads it; `null`
  /// for what the app would not take in either.
  ZenSignal? _signalOf(String from, Map<String, dynamic> payload) =>
      zenSignalFromTransportPayload(
        sender: PeerShareCodec.normalizeAddress(from),
        payload: payload,
      );

  /// What a pong may say about this phone (without a kit: only that it
  /// answers).
  final LockedPresenceKit _presence;

  /// How often the friends who see this phone's status are pinged.
  final Duration presenceRoundEvery;
  int _presenceRoundAt = 0;

  /// The presence rounds of this run, counted, and the round each friend
  /// was last pinged in ([kLockedSilentRoundEvery]).
  int _presenceRounds = 0;
  final Map<String, int> _roundPinged = <String, int>{};

  /// When this run started (a friend not heard from since is silent from
  /// then on, [kLockedSilentAfter]).
  int _startedAt = 0;

  /// When this phone last told each friend its status (a ping or a pong
  /// sent), and last heard theirs (a ping, pong or `away`): a friend who
  /// did both within a round's period needs no ping of the round
  /// ([_presenceRound]).
  final Map<String, int> _toldAt = <String, int>{};
  final Map<String, int> _heardAt = <String, int>{};
  static const int _maxPresencePeers = 2000;

  /// The newest ping, pong or `away` of each friend, kept up to date in
  /// [_presenceSnapshot] as their statuses change ([_presenceChanged]), so the
  /// app shows their statuses the moment it opens
  /// (BackgroundVault.keptPresence), without waiting for this receiver to
  /// stop or for its own node.
  final Map<String, SignalTransportFrame> _presenceHeard =
      <String, SignalTransportFrame>{};
  final SealedSnapshotWriter _presenceSnapshot;

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

  /// Whether the node has a link to the mesh now (`null`: not known). A
  /// wake's poll that went out without one, and that no mailbox answered,
  /// is sent once more in the same wake as soon as a link is up, waiting at
  /// most [relinkWait] for it (looking every [relinkStep]).
  final Future<bool> Function()? _meshLinked;

  /// Whether the phone is on any network at all ([onAnyNetwork]): without
  /// one no link can come up within [relinkWait], so the wake does not wait
  /// for it. The locked node links only over IP networks (public peers, the
  /// shared Wi-Fi), never Bluetooth or Wi-Fi Direct.
  final Future<bool> Function() _onNetwork;
  final Duration relinkWait;
  final Duration relinkStep;

  /// A mailbox sent something since the wake's poll went out.
  bool _mailboxAnswered = false;

  late final Set<String> _mailboxSet = <String>{
    for (final String m in _capability.mailboxes)
      PeerShareCodec.normalizeAddress(m),
  };

  /// A contact's pings get a pong at most this often: friends ping only
  /// while Zen is on their screen; the first ping after a quiet while gets
  /// one at once, and a pong every other ping keeps this phone reachable,
  /// "w tle", for them (kPresenceOfflineAfter).
  final Duration pongEvery;

  /// Rings for a call as a phone call rings, or stops (setCallRinging,
  /// call_platform_channel.dart; replaced in tests).
  Future<void> Function(bool on) ringForCall = setCallRinging;

  /// Who calls, as the card over the lock screen may say it: the name the
  /// notice kit knows, unless the notification level keeps names off it.
  String _callCardName(String from) {
    final String name = (_noticeKit.names[from] ?? '').trim();
    return name.isEmpty ||
            _noticeKit.levelOf(from) == NotificationPrivacy.generic
        ? t('Połączenie przychodzące')
        : name;
  }

  /// Shows the native call card for a call from [from] (replaced in
  /// tests): the name as the notice kit knows it.
  late Future<void> Function(String from) showCallCard = (String from) =>
      showIncomingCallPopup(
        displayName: _callCardName(from),
        isVideo: false,
        peerAddress: from,
        acceptRouteKey: '',
      );
  final Map<String, int> _pongedAt = <String, int>{};

  /// A contact's pings from a Zen that just started ([kPresenceFreshKey])
  /// get a pong whenever the last one went, but at most this often.
  final Duration freshPongEvery;
  final Map<String, int> _freshPongedAt = <String, int>{};

  StreamSubscription<SignalTransportFrame>? _subscription;
  StreamSubscription<SignalTransportFrame>? _doorSubscription;
  final Map<String, int> _doorFramesBy = <String, int>{};
  int _doorFramesTotal = 0;
  BeatTimer? _pollTimer;

  /// The presence round's place on the beat ([presenceRoundEvery]).
  BeatTimer? _roundTimer;

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
    // The app pinged everyone a moment ago: the first round comes later.
    _presenceRoundAt = _now();
    _startedAt = _presenceRoundAt;
    await _pollMailboxes();
    if (mailboxPollInterval > Duration.zero &&
        _capability.mailboxes.isNotEmpty) {
      // On the shared beat: one wake of the phone for the polls of every
      // account (and a look around nearby, the outbox's rounds), held for
      // the polls and their first answers and let go then. Polls that find
      // nothing come less and less often ([nextMailboxPollWait]).
      const Duration hold = Duration(seconds: 10);
      final WakeBeat? beat = _beat;
      _pollTimer = beat == null
          ? ZenWake.beat(
              'mailbox-poll',
              mailboxPollInterval,
              _pollOnWake,
              hold: hold,
            )
          : beat.add(
              'mailbox-poll',
              mailboxPollInterval,
              _pollOnWake,
              hold: hold,
              whileIdle: true,
            );
    }
    if (presenceRoundEvery > Duration.zero && _presence.shownTo.isNotEmpty) {
      // Its own place on the beat, a multiple of the polls' first period:
      // it shares their wakes and the others', and takes none while they
      // come at least as often. Nobody to tell: no wake for it.
      const Duration hold = Duration(seconds: 5);
      final WakeBeat? beat = _beat;
      _roundTimer = beat == null
          ? ZenWake.beat(
              'presence-round',
              presenceRoundEvery,
              _presenceRound,
              hold: hold,
            )
          : beat.add(
              'presence-round',
              presenceRoundEvery,
              _presenceRound,
              hold: hold,
              whileIdle: true,
            );
    }
    logZenMessage(
      'Locked receiver runs (no master key; '
      '${_capability.mailboxes.length} mailboxes).',
    );
  }

  Future<void> stop() async {
    _running = false;
    // The last write (if one runs) is on the disk before the app reads it.
    await _keepPresence();
    await _alarm?.stop();
    _pollTimer?.cancel();
    _pollTimer = null;
    _roundTimer?.cancel();
    _roundTimer = null;
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
        : 'd|$from|${frameContentHash(frame.payload)}';
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
  /// One wake of the mailbox polls (tests).
  @visibleForTesting
  Future<void> pollOnWakeForTest() => _pollOnWake();

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
    // Without a link to the mesh the poll goes nowhere: the first wake
    // after an outage, while the node redials (phone_peers.go).
    final bool linked = await _meshLinkedNow();
    _mailboxAnswered = false;
    try {
      await _pollMailboxes();
    } on Object catch (error, stackTrace) {
      logZenError('Mailbox poll failed', error, stackTrace);
    }
    if (_running) {
      await Future<void>.delayed(pollAnswerGrace);
    }
    if (!linked && !_mailboxAnswered && _running && await _onNetwork()) {
      // Asked once more in the same wake as soon as a link is up, rather
      // than a whole poll period later. Not on no network at all (flight
      // mode, no signal): no link comes, and the phone sleeps at once.
      await ZenWake.holdWhile(
        _pollAgainOnceLinked,
        tag: 'relink',
        limit: relinkWait + pollAnswerGrace + const Duration(seconds: 2),
      );
    }
  }

  /// Whether the node has a link to the mesh now (`true` when that is not
  /// known: nothing more is done then).
  Future<bool> _meshLinkedNow() async {
    final Future<bool> Function()? meshLinked = _meshLinked;
    if (meshLinked == null) {
      return true;
    }
    try {
      return await meshLinked();
    } on Object {
      return true;
    }
  }

  /// Waits up to [relinkWait] for a link to the mesh, then polls again.
  ///
  /// The wait goes by the receiver's clock ([_now]: the wall clock, or a
  /// test's virtual one), not by a stopwatch: under a busy test runner a
  /// few looks took longer than a simulated wait in real time, and the poll
  /// was given up. The looks themselves are counted too, so a clock that
  /// stands still cannot keep it waiting.
  Future<void> _pollAgainOnceLinked() async {
    final int start = _now();
    final int maxLooks = relinkStep > Duration.zero
        ? relinkWait.inMicroseconds ~/ relinkStep.inMicroseconds
        : 1;
    int looks = 0;
    while (!await _meshLinkedNow()) {
      looks += 1;
      if (!_running ||
          _now() - start >= relinkWait.inMilliseconds ||
          looks >= maxLooks) {
        return;
      }
      await Future<void>.delayed(relinkStep);
    }
    if (!_running || _mailboxAnswered) {
      return;
    }
    await _pollMailboxes();
    await Future<void>.delayed(pollAnswerGrace);
  }

  /// Asks every mailbox for what it holds now, outside the beat (an
  /// iPhone's background wake, which may be the only moment for it).
  Future<void> pollMailboxes() => _pollMailboxes();

  /// Pings the friends who see this phone's status, at most every
  /// [presenceRoundEvery] (the ping says "w tle", as a pong would). A wake
  /// early by as much as the beat may run it early ([wakeBeatEarly]: work
  /// due soon on a wake that comes anyway), and [_roundClockSlack] more,
  /// still counts: skipped, the round would wait a whole period more, and
  /// the friends would hear nothing for up to two rounds. A wall clock set
  /// back counts as a round due.
  ///
  /// A friend this phone told its status and heard theirs from within that
  /// much of a period (their own round's ping and this phone's pong, or the
  /// other way round) is not pinged: each ping woke their locked phone, so
  /// two locked friends woke each other twice a period. One of the two
  /// rounds keeps both told, the other finds the exchange and skips; a ping
  /// or pong lost leaves one side without the other's word, and its next
  /// round pings again. A friend whose word says Zen is on their screen is
  /// pinged every round as before (their phone is awake; their pings come
  /// on their own cadence). A friend silent for long ([kLockedSilentAfter])
  /// is pinged every [kLockedSilentRoundEvery]th round.
  @visibleForTesting
  Future<void> presenceRoundForTest() => _presenceRound();

  /// The beat reads its clock for a wake a moment before the round reads
  /// its own, and the works before it on the wake take their moment too.
  static const Duration _roundClockSlack = Duration(seconds: 1);

  Future<void> _presenceRound() async {
    try {
      await _pingRound();
    } finally {
      // A wake that comes anyway: what waits to be written goes now if its
      // time is up.
      await _keepPresenceDue();
    }
  }

  Future<void> _pingRound() async {
    final int at = _now();
    final int every = presenceRoundEvery.inMilliseconds;
    final int soonest =
        every -
        wakeBeatEarly(presenceRoundEvery).inMilliseconds -
        _roundClockSlack.inMilliseconds;
    final int since = at - _presenceRoundAt;
    if (every <= 0 || !_running || (since >= 0 && since < soonest)) {
      return;
    }
    _presenceRoundAt = at;
    _presenceRounds += 1;
    if (_roundPinged.length >= _maxPresencePeers) {
      _roundPinged.clear();
    }
    for (final String friend in _presence.shownTo) {
      if (!_running) {
        return;
      }
      if (_capability.kindOf(friend) != BackgroundContactKind.friend) {
        continue;
      }
      // As frames name their sender ([handleFrame]).
      final String key = PeerShareCodec.normalizeAddress(friend);
      if (_exchangedWithin(key, at, soonest) && !_onScreenAt(key, at)) {
        continue;
      }
      final int? pingedIn = _roundPinged[key];
      if (pingedIn != null &&
          _presenceRounds - pingedIn < kLockedSilentRoundEvery &&
          _silentAt(key, at)) {
        continue;
      }
      _roundPinged[key] = _presenceRounds;
      if (await _sendQuietly(friend, <String, dynamic>{
        'type': 'ping',
        ..._presence.pongFields(friend, at),
        ...versionHello(),
      })) {
        _noteTold(key, at);
      }
    }
  }

  /// Whether this phone told [friend] its status and heard theirs, both
  /// within [withinMs] before [at] (a clock set back: not).
  bool _exchangedWithin(String friend, int at, int withinMs) {
    bool lately(int? t) => t != null && at >= t && at - t < withinMs;
    return lately(_toldAt[friend]) && lately(_heardAt[friend]);
  }

  /// Whether [friend]'s newest word says Zen is on their screen, and is
  /// still worth that ([kPresenceForegroundFor]).
  bool _onScreenAt(String friend, int at) {
    final SignalTransportFrame? frame = _presenceHeard[friend];
    if (frame == null) {
      return false;
    }
    final int age = at - frame.receivedAtMillis;
    return age >= 0 &&
        age < kPresenceForegroundFor.inMilliseconds &&
        PresenceReport.fromPayload(frame.payload).presence ==
            PeerPresence.online;
  }

  /// Whether nothing came from [friend] for [kLockedSilentAfter] by [at]
  /// (in this run; a clock set back: not).
  bool _silentAt(String friend, int at) {
    final int since = _heardAt[friend] ?? _startedAt;
    return at >= since && at - since > kLockedSilentAfter.inMilliseconds;
  }

  void _noteTold(String friend, int at) {
    if (_toldAt.length >= _maxPresencePeers) {
      _toldAt.clear();
    }
    _toldAt[friend] = at;
  }

  void _noteHeard(String friend, int at) {
    if (_heardAt.length >= _maxPresencePeers) {
      _heardAt.clear();
    }
    _heardAt[friend] = at;
  }

  /// Done once the statuses heard so far are written down (tests).
  @visibleForTesting
  Future<void> get presenceKept => _presenceSnapshot.idle;

  /// Notes the newest presence frame of a friend ([_presenceHeard]) and
  /// writes them all down ([_keepPresence]): at once when it tells the app
  /// something the written one does not ([_presenceChanged]), and when the
  /// written one grew old ([_presenceRefresh]) once that much has passed
  /// since the last write ([_keepPresenceDue]).
  Future<void> _notePresenceHeard(
    String from,
    SignalTransportFrame frame,
  ) async {
    final SignalTransportFrame? had = _presenceHeard[from];
    if (had != null && had.receivedAtMillis > frame.receivedAtMillis) {
      return;
    }
    if (had == null && _presenceHeard.length >= LockedPresenceKit.maxEntries) {
      return;
    }
    _presenceHeard[from] = frame;
    final SignalTransportFrame? written = _presenceWritten[from];
    if (written == null || _presenceChanged(written, frame)) {
      await _keepPresence();
      return;
    }
    final Duration? refresh = _presenceRefresh(written, frame);
    if (refresh == null) {
      return;
    }
    final Duration? within = _presenceWriteWithin;
    if (within == null || refresh < within) {
      _presenceWriteWithin = refresh;
    }
    await _keepPresenceDue();
  }

  /// Writes what waits to be written ([_presenceWriteWithin]) once its
  /// time since the last write is up (a clock set back: at once).
  Future<void> _keepPresenceDue() async {
    final Duration? within = _presenceWriteWithin;
    if (within == null) {
      return;
    }
    final int since = _now() - _presenceWrittenAt;
    if (since >= 0 && since < within.inMilliseconds) {
      return;
    }
    await _keepPresence();
  }

  /// What [_presenceSnapshot] holds of each friend (as last written).
  final Map<String, SignalTransportFrame> _presenceWritten =
      <String, SignalTransportFrame>{};

  /// When [_presenceSnapshot] was last written (the receiver's clock).
  int _presenceWrittenAt = 0;

  /// The file is behind what was heard, and is written again once this long
  /// has passed since its last write (`null`: nothing waits).
  Duration? _presenceWriteWithin;

  /// Whether [frame] tells the app something [written], the friend's frame
  /// the file holds, does not: another state, or another last opening
  /// while not online (shown only then; a minute's difference, as `lo` is
  /// told in seconds and goes by the clocks of two phones).
  static bool _presenceChanged(
    SignalTransportFrame written,
    SignalTransportFrame frame,
  ) {
    final PresenceReport now = PresenceReport.fromPayload(frame.payload);
    final PresenceReport was = PresenceReport.fromPayload(written.payload);
    if (now.presence != was.presence) {
      return true;
    }
    final int openedNow = now.lastOpenedAt(frame.receivedAtMillis);
    final int openedWas = was.lastOpenedAt(written.receivedAtMillis);
    return now.presence != PeerPresence.online &&
        (openedNow - openedWas).abs() >
            const Duration(minutes: 1).inMilliseconds;
  }

  /// How soon after the last write [frame], saying what [written] says, is
  /// to be written: once the written one is [kKeptPresenceRefreshEvery]
  /// old, that long (an online friend's [kKeptPresenceOnlineRefreshEvery]);
  /// `null` while it is younger. A friend's frames come every few minutes;
  /// each write seals the whole file anew and waits for the disk.
  static Duration? _presenceRefresh(
    SignalTransportFrame written,
    SignalTransportFrame frame,
  ) {
    final Duration refresh =
        PresenceReport.fromPayload(frame.payload).presence ==
            PeerPresence.online
        ? kKeptPresenceOnlineRefreshEvery
        : kKeptPresenceRefreshEvery;
    return frame.receivedAtMillis - written.receivedAtMillis >=
            refresh.inMilliseconds
        ? refresh
        : null;
  }

  /// Writes the newest presence frame of each friend, heard within
  /// [kPresenceRememberedFor], to [_presenceSnapshot] (with the time they
  /// came, so a status is aged as it would have been): the app reads it
  /// when it opens and shows its friends' statuses at once instead of
  /// "nieznany". A small file, written when a friend's status changed, when
  /// what it holds of them grew a few minutes old (at most every
  /// [kKeptPresenceRefreshEvery] for that, [_notePresenceHeard]), and when
  /// the receiver stops, while the phone is awake anyway.
  Future<void> _keepPresence() {
    final int at = _now();
    _presenceWrittenAt = at;
    _presenceWriteWithin = null;
    _presenceHeard.removeWhere(
      (String _, SignalTransportFrame f) =>
          at - f.receivedAtMillis > kPresenceRememberedFor.inMilliseconds,
    );
    _presenceWritten
      ..clear()
      ..addAll(_presenceHeard);
    return _presenceSnapshot.write(<Uint8List>[
      for (final SignalTransportFrame frame in _presenceHeard.values)
        encodeInboxFrame(frame),
    ]);
  }

  Future<void> _pollMailboxes() async {
    for (final String mailbox in _capability.mailboxes) {
      if (!_running) {
        return;
      }
      await _sendQuietly(mailbox, const <String, dynamic>{'type': 'rly_poll'});
    }
  }

  /// Whether a contact's ping at [at] gets a pong ([pongEvery]; a ping
  /// from a Zen that just started, [freshPongEvery]), noting it when so.
  /// A clock set back answers at once.
  bool _answersPing(String from, int at, Map<String, dynamic> payload) {
    bool lately(Map<String, int> answered, Duration every) {
      final int? last = answered[from];
      return last != null && at >= last && at - last < every.inMilliseconds;
    }

    final bool fresh = payload[kPresenceFreshKey] == true;
    if (lately(_pongedAt, pongEvery) &&
        (!fresh || lately(_freshPongedAt, freshPongEvery))) {
      return false;
    }
    if (_pongedAt.length >= 2000) {
      _pongedAt.clear();
      _freshPongedAt.clear();
    }
    _pongedAt[from] = at;
    if (fresh) {
      _freshPongedAt[from] = at;
    }
    return true;
  }

  /// Sends [payload] to [to]; false when it could not go.
  Future<bool> _sendQuietly(String to, Map<String, dynamic> payload) async {
    try {
      await _transport.send(remoteAddress: to, payload: payload);
      return true;
    } on Object catch (error) {
      logZenWarning('The locked receiver could not answer: $error');
      return false;
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
    if (_mailboxSet.contains(from)) {
      _mailboxAnswered = true;
    }
    // Friends' confirmations and answers, and mailboxes (possibly strangers
    // here) taking their copy of the alarm.
    _alarm?.observe(frame);
    if (kind == BackgroundContactKind.friend &&
        (type == 'ping' || type == 'pong' || type == kPresenceAwayType)) {
      _noteHeard(from, _now());
      // Written in the background: the answer below does not wait for it.
      unawaited(_notePresenceHeard(from, frame));
    }
    if (type == 'ping') {
      final int at = _now();
      if (contact && _answersPing(from, at, frame.payload)) {
        final bool sent = await _sendQuietly(frame.from, <String, dynamic>{
          'type': 'pong',
          if (kind == BackgroundContactKind.friend)
            ..._presence.pongFields(from, at),
          if (kind == BackgroundContactKind.friend) ...versionHello(),
        });
        if (sent && kind == BackgroundContactKind.friend) {
          _noteTold(from, at);
        }
      }
      return;
    }
    if (type == 'pong' || type == kPresenceAwayType) {
      return;
    }
    if (_isRealTime(type)) {
      if (contact) {
        await _followRing(from, type, frame.payload);
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
      final Object? ledgerRid = frame.payload[kReliableIdKey];
      if (contact &&
          _reliableLedgerTypes.contains(type) &&
          ledgerRid is String &&
          ledgerRid.isNotEmpty) {
        await _keep(frame, from, type, kind, rid: ledgerRid);
      } else if (contact && _keptLedgerTypes.contains(type)) {
        await _keep(frame, from, type, kind, rid: null);
      }
      return;
    }
    final Object? rawRid = frame.payload[kReliableIdKey];
    final String? rid = rawRid is String && rawRid.isNotEmpty ? rawRid : null;
    if (!contact) {
      // From strangers only what was meant to arrive (it is reliable), and
      // only a little of it. A copy of what is kept already only gets its
      // acknowledgement again, free: a friend request is tried every few
      // seconds until it is heard back, and the repeats used to use up the
      // budget and go unacknowledged, so the sender kept trying.
      if (rid == null ||
          (!_alreadyHere(from, rid) && !_strangerMayLeave(from))) {
        return;
      }
    }
    await _keep(frame, from, type, kind, rid: rid);
  }

  /// How a reliable frame [rid] from [from] is known among the kept.
  static String _keptId(String from, String rid) => 'r|$from|$rid';

  /// Whether the reliable frame [rid] from [from] is kept already, or the
  /// app took it before it locked.
  bool _alreadyHere(String from, String rid) =>
      _kept.contains(_keptId(from, rid)) ||
      _taken.contains(LockedMailboxKit.takenTag(from, rid));

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
        ? _keptId(from, rid)
        : 'h|$from|${frameContentHash(frame.payload)}';
    if (_kept.contains(id) || (rid != null && _alreadyHere(from, rid))) {
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
    await _announce(type, frame.payload, kind, from: from);
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
    // Only mail worth a notice (a message, a call, an invitation; a Zen
    // before 1.15.4 does not say, so its mail still is): receipts and
    // statuses came in silently before the app shows them, never as
    // "Odblokuj Zen" with nothing behind it.
    final Set<String> worth = <String>{
      for (final Map<String, dynamic> item in fresh)
        if (item['k'] != 0)
          PeerShareCodec.normalizeAddress(item['s'] as String),
    };
    if (worth.isNotEmpty) {
      await _announceMail(worth);
    }
  }

  /// Mail a mailbox handed over, from [senders]: sealed for the relay key,
  /// so what it is cannot be told here, only from whom (the envelope says
  /// it). Nothing when none of them is a contact (a removed friend, a
  /// stranger: the app would not let it in either); the sender's name when
  /// it is one friend the notice kit names at a level that shows who
  /// wrote.
  Future<void> _announceMail(Set<String> senders) async {
    final List<String> contacts = <String>[
      for (final String s in senders)
        if (_capability.kindOf(s) != BackgroundContactKind.stranger) s,
    ];
    if (contacts.isEmpty) {
      return;
    }
    final String? name = contacts.length == 1
        ? _noticeKit.senderName(contacts.single)
        : null;
    await _postThrottled(
      RuntimeSystemNotification(
        id: '$kLockedSocialSlot-${_now()}',
        title: name ?? PrivacyRedactingNotificationService.genericTitle,
        body: t('Odblokuj Zen, żeby zobaczyć szczegóły.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        routeKey: buildInboxRouteKey(),
        slotKey: kLockedSocialSlot,
        contentRedacted: true,
      ),
      log: (
        kind: 'mail',
        level: name == null
            ? NotificationPrivacy.generic
            : NotificationPrivacy.senderOnly,
        known: name != null,
        version: contacts.length == 1
            ? _noticeKit.versionOf(contacts.single)
            : null,
      ),
    );
  }

  Future<void> _announce(
    String type,
    Map<String, dynamic> payload,
    BackgroundContactKind kind, {
    String from = '',
  }) async {
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
      final ZenSignal? read = _signalOf(from, payload);
      if (read == null) {
        // Nothing the app would take in as a chat message.
        return;
      }
      // Marked as a mention of this person only as the app marks it: from
      // someone who speaks in that group, within the limit per sender.
      final ZenSignal signal = withMentionOfSelf(
        read,
        _alertFacts,
        _mentionAlerts,
        _now(),
      );
      if (incomingAlertOf(signal, _alertFacts, nowMillis: _now()) !=
          IncomingAlert.notice) {
        // By the app's rules: someone this person did not name (a removed
        // friend, a group member outside the group's chat, a stranger: a
        // stranger's message is told about after unlock, as one from
        // outside friends), a group not joined, a muted conversation
        // ("Wycisz…"), a mentions-only group and no mention, or a switch
        // that is off.
        return;
      }
      final bool inGroup = signal.type == ZenSignalType.groupMessage;
      final NoticeText text = _noticeKit.messageNotice(
        from: from,
        payload: payload,
        genericBody: t('Odblokuj Zen, żeby przeczytać.'),
      );
      final String key = conversationKeyOfSignal(signal);
      await _postThrottled(
        RuntimeSystemNotification(
          id: '$kLockedMessageSlot-${_now()}',
          title: text.title,
          body: text.body,
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.message,
          kind: chatNoticeKind(signal),
          routeKey: buildInboxRouteKey(),
          slotKey: kLockedMessageSlot,
          contentRedacted: true,
        ),
        log: (
          kind: inGroup ? 'group-message' : 'message',
          level: _noticeKit.levelOf(
            key,
            inGroup ? NoticeKind.groupMessage : NoticeKind.message,
          ),
          known: _noticeKit.senderName(from) != null,
          version: _noticeKit.versionOf(from),
        ),
      );
      return;
    }
    if (_socialTypes.contains(type)) {
      if (type == 'friend_accept' &&
          _noticeKit.removed.contains(PeerShareCodec.normalizeAddress(from))) {
        // A removed friend's old acceptance sent again: it answers nothing
        // (the app drops it too).
        return;
      }
      final ZenSignal? social = _signalOf(from, payload);
      if (social == null) {
        // Nothing the app would take in (an invitation to no group).
        return;
      }
      if (type == 'group_invite' && isManagedGroupId(social.groupId ?? '')) {
        // A group another feature keeps (a pyramid cell's chat): nobody
        // invites to it, and the app drops this after unlock. The id as
        // the app reads it (trimmed), never the raw one: " pyrcell-…" is
        // the same cell.
        return;
      }
      if (switch (type) {
        'friend_request' => PeerShareCodec.fromStaleCode(
          _noticeKit.inviteToken,
          switch (payload['it']) {
            final String token => token,
            _ => null,
          },
        ),
        'group_invite' =>
          _noticeKit.inviteToken.isNotEmpty &&
              kind == BackgroundContactKind.stranger,
        _ => false,
      }) {
        // Not from the current invitation code ("Zmień kod"): the app
        // refuses it after unlock (or lets in the request of someone it
        // invited, which needs no notice either).
        return;
      }
      // Who invited (or accepted) and what they wrote, as the
      // notification level allows; a group invitation stays plain.
      final NoticeText? invite = _noticeKit.invitationNotice(
        from: from,
        type: type,
        payload: payload,
      );
      await _postThrottled(
        RuntimeSystemNotification(
          id: '$kLockedSocialSlot-${_now()}',
          title:
              invite?.title ?? PrivacyRedactingNotificationService.genericTitle,
          body: invite?.body ?? t('Odblokuj Zen, żeby zobaczyć szczegóły.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          kind: _invitationTypes.contains(type) ? NoticeKind.invitation : null,
          routeKey: buildInboxRouteKey(),
          slotKey: kLockedSocialSlot,
          contentRedacted: true,
        ),
        log: (
          kind: _invitationTypes.contains(type) ? 'invitation' : 'social',
          level: NotificationPrivacy.generic,
          known: kind != BackgroundContactKind.stranger,
          version: _noticeKit.versionOf(from),
        ),
      );
    }
  }

  /// A ring keeps the call notice up; it ends with the caller's own end or
  /// once the invites stop, and leaves a "missed call" behind. Only a call
  /// the app would ring for rings here ([callRings]): from a friend, a
  /// group call from someone in that joined group, and not with
  /// "Połączenia" switched off (then no ring, no card, no notice).
  Future<void> _followRing(
    String from,
    String type,
    Map<String, dynamic> payload,
  ) async {
    if (_ringTypes.contains(type)) {
      final ZenSignal? call = _signalOf(from, payload);
      if (call == null ||
          incomingAlertOf(call, _alertFacts, nowMillis: _now()) !=
              IncomingAlert.ring) {
        return;
      }
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
        await ringForCall(true);
        // The call card over the lock screen, as a call shows: "Odbierz"
        // opens Zen to unlock it, and the call rings on there.
        await showCallCard(from);
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
    await ringForCall(false);
    await hideIncomingCallPopup();
    try {
      await _notices.dismissSlot(kLockedCallSlot);
      await _post(
        RuntimeSystemNotification(
          id: '$kLockedMissedCallSlot-${_now()}',
          title: t('Nieodebrane połączenie'),
          body: t('Ktoś dzwonił, gdy Zen był zablokowany.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.message,
          kind: NoticeKind.call,
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

  /// One entry per kind, posted anew (so the shade does not stack the same
  /// line), with a sound at most every [noticeThrottle]: one that comes
  /// sooner updates the entry on screen, silently. It was not shown at all
  /// then, so the shade kept the first message of the minute and a newer
  /// one looked as if it had not come.
  Future<void> _postThrottled(
    RuntimeSystemNotification notice, {
    NoticeLog? log,
  }) async {
    if (_noticeKit.settingsApplied(notice) == null) {
      // Switched off: it neither shows nor takes the slot's turn.
      return;
    }
    final String slot = notice.slotKey!;
    final int now = _now();
    final int? last = _lastNoticeAt[slot];
    final bool sounded =
        last != null && now - last < noticeThrottle.inMilliseconds;
    if (sounded) {
      // An update of the one on screen (stacked with it), without a sound.
      await _post(notice.asSilent(), log: log);
      return;
    }
    _lastNoticeAt[slot] = now;
    await _notices.dismissSlot(slot);
    await _post(notice, log: log);
  }

  Future<void> _post(RuntimeSystemNotification notice, {NoticeLog? log}) async {
    // The notification switches of the settings (from the notice kit).
    final RuntimeSystemNotification? shown = _noticeKit.settingsApplied(notice);
    if (shown == null) {
      return;
    }
    try {
      if (await _notices.show(shown)) {
        logNoticePosted(
          'svc',
          log ??
              (
                kind: noticeLogKindOf(shown),
                level: null,
                known: false,
                version: null,
              ),
        );
      }
    } on Object catch (error, stackTrace) {
      logZenError('A locked notice failed', error, stackTrace);
    }
  }
}
