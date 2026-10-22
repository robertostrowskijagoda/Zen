import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_engine.dart'
    show kReliableIdKey, kReliableTtlKey;
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

abstract final class FlatTypes {
  /// "We scanned your door": our profile + the door secret.
  static const String hello = 'flat_hello';

  /// The door secret is no longer valid.
  static const String nope = 'flat_nope';

  /// A flat's current profile.
  static const String profile = 'flat_profile';

  /// "Send me your current profile" (a neighbour).
  static const String get = 'flat_get';
  static const String message = 'flat_msg';
  static const String signup = 'flat_signup';
  static const String signupAck = 'flat_signup_ok';

  /// Between housemates: the whole shared state of the flat.
  static const String house = 'flat_house';

  /// A new resident (holding the flat key) asks to be added.
  static const String join = 'flat_join';
  static const String leave = 'flat_leave';

  /// "We moved out of here": neighbours drop us; the flat is free for the
  /// new tenants' own profile.
  static const String moved = 'flat_moved';

  /// Between housemates: a vote to remove one phone that will not leave
  /// by itself.
  static const String kick = 'flat_kick';

  /// Between housemates: the household's new key, without the removed
  /// phone (signed with the old key).
  static const String rekey = 'flat_rekey';

  /// To neighbours: "we have a new key" (signed with the old one).
  static const String newKey = 'flat_newkey';

  /// To a neighbour flat: one resident shows their own account ("Pokaż mój
  /// profil").
  static const String reveal = 'flat_reveal';

  /// To a mailbox door: a knock (or the answer to one) sealed for the flat
  /// (flat_door_mail.dart).
  static const String seal = 'flat_seal';

  /// To a friend who keeps this phone's mailbox: "run this mailbox door"
  /// (its key), or "stop" (an empty key).
  static const String slot = 'flat_slot';

  /// From that friend: a sealed knock its mailbox door took for us.
  static const String held = 'flat_held';

  /// Door to door: "your frame (its id) came", so the sender stops
  /// retrying it.
  static const String ack = 'flat_ack';

  /// Door to door, to a flat that knocked: the household's card, when it
  /// shows knockers more than its name before "Wpuść" ([FlatDoorView]).
  static const String card = 'flat_card';

  /// What comes in through a door (the bridge lets only these through,
  /// `kFlatDoorTypes`): knocks and everything between neighbour flats, sent
  /// from the sender's door; [reveal] comes from the resident's own phone;
  /// [seal] only to mailbox doors.
  static const Set<String> atDoor = <String>{
    hello,
    nope,
    profile,
    get,
    message,
    signup,
    signupAck,
    moved,
    newKey,
    reveal,
    ack,
    seal,
    card,
  };

  /// What goes phone to phone, through the relay layer: between housemates,
  /// and between friends for the mailbox doors.
  static const Set<String> atPhone = <String>{
    house,
    join,
    leave,
    kick,
    rekey,
    slot,
    held,
  };

  static const Set<String> all = <String>{...atDoor, ...atPhone};
}

/// How long a frame for a neighbour flat's doors is retried until a door
/// says it came ([FlatTypes.ack]).
const Duration kFlatSendLife = Duration(days: 3);

/// Frames waiting to be retried from the door at most; the oldest go first.
const int kMaxDoorOutbox = 300;

/// Knock notifications per hour, all knockers together; one knocker rings
/// once an hour at most. More knocks still wait in the list, silently.
const int kKnockRingsPerHour = 4;

/// After a housemate's phone left ("Opuść"), the resident with the lowest
/// resident key makes the household's new key; when it has not come after
/// this long, any remaining phone makes one (two at once settle on the
/// lower key).
const Duration kLeaveRekeyWait = Duration(minutes: 10);

/// In a household of two, removing the other resident waits this long for
/// their answer ("Zgadzam się" / "Nie zgadzam się"); without one, it
/// happens.
const Duration kTwoResidentWait = Duration(days: 7);

/// Short-lived door tokens (invitations nearby) a household keeps at most.
const int kMaxTempDoors = 20;

/// A new phone waiting for a housemate to confirm its joining
/// ([FlatHomeCode]): where it asked, with which code, and the keys the
/// household's key comes sealed to.
final class _JoinAsk {
  _JoinAsk({
    required this.address,
    required this.token,
    required this.flatKey,
    required this.flatName,
    required this.sealPrivate,
    required this.sealPublic,
    required this.kemSeed,
  });

  final String address;
  final String token;
  final String flatKey;
  final String flatName;
  final String sealPrivate;
  final String sealPublic;
  final String kemSeed;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    't': token,
    'k': flatKey,
    'n': flatName,
    'sp': sealPrivate,
    'su': sealPublic,
    'q': kemSeed,
  };

  static _JoinAsk? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? a = json['a'];
    final Object? t = json['t'];
    final Object? k = json['k'];
    final Object? n = json['n'];
    final Object? sp = json['sp'];
    final Object? su = json['su'];
    final Object? q = json['q'];
    if (a is! String ||
        t is! String ||
        k is! String ||
        n is! String ||
        sp is! String ||
        su is! String ||
        q is! String) {
      return null;
    }
    return _JoinAsk(
      address: a,
      token: t,
      flatKey: k,
      flatName: n,
      sealPrivate: sp,
      sealPublic: su,
      kemSeed: q,
    );
  }
}

/// Photos of the knocks passed on to housemates in one go at most (base64
/// characters); knocks over it follow once others are answered.
const int kKnockSyncPhotoChars = 300 * 1024;

/// Waits between the retries of a frame sent from the door.
const List<Duration> _doorRetries = <Duration>[
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 10),
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 3),
  Duration(hours: 6),
];

/// One frame sent from this phone's door, kept until a door says it came
/// (or, with [acked] off, until its time is up: doors never answer a knock).
final class _DoorSend {
  _DoorSend({
    required this.id,
    required this.to,
    required this.payload,
    required this.until,
    required this.acked,
    this.about = '',
  });

  final String id;
  final String to;
  final Map<String, dynamic> payload;
  final int until;
  final bool acked;

  /// The flat a sealed knock is for (it does not say so itself): its
  /// copies stop once that flat lets us in. Kept on this phone only.
  final String about;
  int next = 0;
  int tries = 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'to': to,
    'p': payload,
    'u': until,
    if (acked) 'ack': true,
    if (about.isNotEmpty) 'ab': about,
  };

  static _DoorSend? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['to'] is! String ||
        json['p'] is! Map ||
        json['u'] is! int) {
      return null;
    }
    return _DoorSend(
      id: json['id'] as String,
      to: json['to'] as String,
      payload: Map<String, dynamic>.from(json['p'] as Map),
      until: json['u'] as int,
      acked: json['ack'] == true,
      about: json['ab'] is String ? json['ab'] as String : '',
    );
  }
}

/// Wave payload version of a flat's invitation passed over Bluetooth.
const int kFlatWaveVersion = 2;

/// How long an invitation heard nearby is kept.
const Duration kNearbyInviteLife = kNearbyCodeLife;

/// What happened to a scanned door code.
enum FlatScan { sent, own, noFlat, alreadyNeighbor, expired }

/// How long a knock on the door waits for a resident to let them in or
/// not, also while the phones are offline (friends hold it); after
/// that it is gone, as if refused.
const Duration kKnockLife = kHeldKnockLife;

/// How long a knock already answered (let in, refused, expired) is
/// remembered, so the knocker's retries of the same knock do not ask again:
/// as long as a sender retries it (`RelayConfig.messageTtl`).
const Duration kKnockMemory = Duration(days: 14);

/// At most this many knocks wait at once; the oldest goes first.
const int kMaxKnocks = 20;

/// A resident key a neighbour has known at least this long counts when a
/// household announces a new key. A key that showed up just before
/// could have been slipped in by the phone being removed.
const Duration kResidentKeyTrust = Duration(days: 1);

/// The warning when a neighbour household announced two different new keys.
String get kFlatKeyConflict =>
    t('Dwa różne nowe klucze mieszkania — zapytaj sąsiadów osobiście');

/// "Sekcja sąsiedzka": this phone's flat (shared by its residents,
/// who all hold the flat's key), the door QR, "Moi sąsiedzi", messages
/// between flats and sign-ups for invitations. Everything is signed with
/// the flats' keys. Between flats everything goes from door to door (each
/// resident's phone runs one, [doorInbox]), so the residents' accounts never
/// show; a resident's own address only with "Pokaż mój profil". Housemates
/// reach each other phone to phone.
final class NeighborsService extends ChangeNotifier {
  NeighborsService({
    required this.host,
    required this.disk,
    int Function()? now,
    Random? random,
    this.doorInbox,
    this.doorSend,
    this.mailboxes,
    this.dismissNotification,
    this.deviceName,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// The address of the flat's door while it runs: a node of its own that
  /// this phone runs with [doorKey] (door_node.go in the bridge). The door
  /// QR carries it and never a resident's address; without it there
  /// is no door QR. The flat's profile lists it as this resident's door.
  final String? Function()? doorInbox;

  /// Sends a frame from that door (false while it does not run): all
  /// traffic to neighbour flats goes this way, never from this phone's own
  /// address.
  final Future<bool> Function(String to, Map<String, dynamic> payload)?
  doorSend;

  /// The friends who keep this phone's offline mailboxes, `null` while
  /// not known yet: they run this door's mailbox doors.
  final List<String>? Function()? mailboxes;

  /// Takes a notification (by its slot) off the screen: a knock answered on
  /// a housemate's phone stops ringing here.
  final Future<void> Function(String slotKey)? dismissNotification;

  /// This device as housemates see it when it asks to join ("Telefon
  /// (Android)").
  final String Function()? deviceName;
  final int Function() _now;
  final Random _random;
  static const String _key = 'neighbors/state';

  String? _seed;
  LedgerKeyPair? _pair;
  FlatProfile? _profile;
  String _door = '';
  int _doorAt = 0;

  /// This phone's door key (a 32-byte ed25519 seed, hex) and the door token
  /// it was made for: a new token ("Nowy kod", here or at a housemate's) is
  /// a new key, so an old sticker's address stops answering. Kept on this
  /// phone only: two phones never run one key on the mesh.
  String? _doorKey;
  String _doorKeyFor = '';

  /// What [_doorKey] gives (mailbox doors, the sealing key); worked out
  /// again after a restart, never stored.
  FlatDoorKeys? _doorKeys;

  /// Who runs which of this door's mailbox doors (slot → friend), and for
  /// which door key they got the keys.
  final Map<int, String> _slotHolders = <int, String>{};
  String _slotsFor = '';

  /// The stamp of the last hand-over; a friend keeps only a newer one.
  int _slotAt = 0;
  bool _syncingSlots = false;

  /// Mailbox doors this phone runs for friends (friend → door).
  final Map<String, HostedDoor> _hosted = <String, HostedDoor>{};

  /// Sealed knocks already taken at those doors (hash of knocker and retry
  /// id → until when): the knocker retries until [kSealRetryLife] is over.
  final Map<String, int> _heldSeen = <String, int>{};

  /// When each [pending] door was knocked at: the answer may come days
  /// later, through the mailboxes.
  final Map<String, int> _pendingAt = <String, int>{};
  bool shareWithScanners = false;
  int _shareAt = 0;

  /// Waiting for the housemate to answer our "flat_join".
  bool joining = false;

  final Map<String, NeighborFlat> _neighbors = <String, NeighborFlat>{};

  /// Neighbours removed (key → when), so housemates do not bring them back.
  final Map<String, int> _removed = <String, int>{};
  final Map<String, FlatMessage> _messages = <String, FlatMessage>{};
  final Map<String, int> _lastRead = <String, int>{};

  /// Our invitations' sign-ups: item id → flat key → sign-up.
  final Map<String, Map<String, FlatSignup>> _signups =
      <String, Map<String, FlatSignup>>{};

  /// Our sign-ups at neighbours ("flatKey|itemId" → count, 0 = refused or
  /// cancelled).
  final Map<String, FlatSignup> _mine = <String, FlatSignup>{};

  /// Doors scanned, waiting for the flat's answer (key → code).
  final Map<String, FlatDoorCode> pending = <String, FlatDoorCode>{};

  /// Knocks on our door waiting for a resident (flat key → knock), see
  /// [knocks].
  final Map<String, FlatKnock> _knocks = <String, FlatKnock>{};

  /// Knocks already seen ("sender|retry id" → until when), see
  /// [kKnockMemory].
  final Map<String, int> _knocksSeen = <String, int>{};

  /// Knocks answered on any of the residents' phones (knocking flat →
  /// the last answer), kept [kKnockMemory]: shared with the housemates, so
  /// a knock answered on one phone closes on all of them.
  final Map<String, FlatKnockDecision> _decided = <String, FlatKnockDecision>{};

  /// What the household shows knockers before "Wpuść" ("Co widzi
  /// pukający"), and when it was set (the newest setting wins between
  /// housemates).
  FlatDoorView _view = const FlatDoorView();
  int _viewAt = 0;

  /// Cards that doors we knocked at showed us before letting us in (flat
  /// key → card), while we wait.
  final Map<String, FlatCard> _cards = <String, FlatCard>{};

  /// Housemates whose phones left ("Opuść") and are still in the profile
  /// until the household's new key is made: resident key → (their signed
  /// statement, when it came).
  final Map<String, (String, int)> _leaving = <String, (String, int)>{};

  /// Household codes this phone showed and nobody used yet (token → until
  /// when), and the phones that asked to join with one, waiting for
  /// "Dołącz" or "Odrzuć". Kept in memory only: a code works minutes.
  final Map<String, int> _invites = <String, int>{};
  final Map<String, FlatJoinRequest> _joinRequests =
      <String, FlatJoinRequest>{};

  /// Resident keys let in here ("Dołącz"), until when their phone may say
  /// it is in.
  final Map<String, int> _approved = <String, int>{};

  /// This phone asked to join a household and waits for the housemate.
  _JoinAsk? _joinAsk;

  /// Short-lived door tokens for invitations nearby (token → until when),
  /// shared with the housemates: a knock with one counts until then.
  final Map<String, int> _tempDoors = <String, int>{};

  /// In a household of two: the other resident this phone asked to remove,
  /// and when ([kTwoResidentWait]).
  final Map<String, int> _kickAsks = <String, int>{};

  /// In a household of two: the resident who asked to remove this phone,
  /// and when.
  (String, int)? _askedToGo;

  /// Doors that turned out stale (key → name).
  final Map<String, String> staleDoors = <String, String>{};
  final List<NearbyFlatInvite> _nearby = <NearbyFlatInvite>[];

  /// Residents' first names (resident key → name), shared between
  /// housemates only.
  final Map<String, String> _names = <String, String>{};

  /// Housemates' phones (resident key → phone address, this phone's too):
  /// housemates reach each other phone to phone. Shared between housemates
  /// only, never in the profile.
  final Map<String, String> _phones = <String, String>{};

  /// Votes to remove a resident: target → the residents who voted (all
  /// resident keys).
  final Map<String, Set<String>> _kickVotes = <String, Set<String>>{};

  /// A new key that came before enough votes did (target → sender, body).
  final Map<String, (String, Map<String, dynamic>)> _pendingRekeys =
      <String, (String, Map<String, dynamic>)>{};

  /// Our household's key before the last change (a housemate who made a
  /// new key at the same time is reconciled through it).
  String? _oldKey;

  /// This phone's own key as a resident (Ed25519; not the flat's key, which
  /// every resident holds): it names this resident in the profile, and votes
  /// to remove a resident and the "new key" notice for neighbours are
  /// signed with it, so a removed phone cannot speak for the others.
  String? _residentSeed;
  LedgerKeyPair? _resident;

  /// Signed votes to remove a resident: target → voter → signature.
  final Map<String, Map<String, String>> _voteSigs =
      <String, Map<String, String>>{};

  /// Neighbour households that moved to a new key (old key → the switch).
  final Map<String, FlatKeySwitch> _switches = <String, FlatKeySwitch>{};

  /// Residents of neighbour flats who showed us their own account:
  /// flat key → reveals.
  final Map<String, List<FlatReveal>> _reveals = <String, List<FlatReveal>>{};

  /// Neighbour flats this phone showed its own account to.
  final Set<String> _revealedTo = <String>{};

  /// Frames sent from the door, waiting to be retried (id → frame).
  final Map<String, _DoorSend> _doorOut = <String, _DoorSend>{};

  /// Knock notifications of the last hour (when, which flat).
  final List<(int, String)> _knockRings = <(int, String)>[];
  Future<void> _queue = Future<void>.value();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  FlatProfile? get profile => _profile;
  bool get hasFlat => _profile != null && _pair != null;
  String get door => _door;

  /// The door QR, once the door runs ([doorInbox]); `null` before.
  FlatDoorCode? get doorCode {
    final FlatProfile? p = _profile;
    final String? inbox = doorInbox?.call();
    if (p == null || inbox == null || !isRoutablePeerAddress(inbox)) {
      return null;
    }
    final FlatDoorKeys? keys = _doorKeys;
    final String own = _n(inbox);
    return FlatDoorCode(
      key: p.key,
      door: _door,
      inbox: own,
      name: p.label,
      // The other residents' doors take sealed copies too: a knock reaches
      // every phone of the household that is on.
      mail: keys != null && keys.doorKey == doorKey
          ? keys.mailDoor(
              _slotHolders.keys,
              doors: <String>[
                for (final MapEntry<String, String> m in p.members.entries)
                  if (m.key != _resident?.id &&
                      m.value.isNotEmpty &&
                      m.value != own)
                    m.value,
              ],
            )
          : null,
    );
  }

  /// The seed of the household's sealing key for the current door token
  /// (hex, [flatSealSeed]): what knockers sealed for this household opens
  /// with it, so the locked background service can tell a knock; `null`
  /// without a flat.
  String? get sealSeed {
    final LedgerKeyPair? pair = _pair;
    return pair == null || _door.isEmpty
        ? null
        : flatHex(flatSealSeed(pair.seed, _door));
  }

  /// What the household shows knockers before "Wpuść".
  FlatDoorView get doorView => _view;

  /// Changes what the household shows knockers before "Wpuść" (and what
  /// its own knocks show); the housemates follow.
  Future<void> setDoorView(FlatDoorView view) async {
    if (!hasFlat) {
      return;
    }
    _view = view.copyWith(note: _clip(view.note, FlatDoorView.maxNote));
    _viewAt = max(_now(), _viewAt + 1);
    await _save();
    await _syncHouse();
  }

  /// The card the flat [key] showed us while we wait at its door, or
  /// `null`.
  FlatCard? doorCard(String key) => _cards[key];

  /// Keys of the mailbox doors this phone runs for friends (door_node.go).
  /// What comes to a door of someone who is no friend any more is dropped
  /// ([_onSealed]); such a door goes when a friend needs the room.
  List<String> get hostedDoorKeys => <String>[
    for (final HostedDoor d in _hosted.values) d.seed,
  ];

  /// The friends holding this phone's mailboxes changed ([mailboxes]): they
  /// get (or give back) this door's mailbox doors.
  Future<void> mailboxesChanged() {
    final Completer<void> done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _syncSlots();
      } on Object catch (error, stack) {
        logZenError('Sąsiedzi: skrzynki', error, stack);
      }
      done.complete();
    });
    return done.future;
  }

  /// [_doorKeys] for the current door key and household; `null` without
  /// one.
  Future<FlatDoorKeys?> _currentKeys() async {
    final String? key = doorKey;
    final LedgerKeyPair? pair = _pair;
    if (key == null || pair == null) {
      return null;
    }
    final Uint8List seal = flatSealSeed(pair.seed, _door);
    if (_doorKeys?.doorKey != key || _doorKeys?.sealSeed != flatHex(seal)) {
      _doorKeys = await FlatDoorKeys.derive(key, sealSeed: seal);
      notifyListeners();
    }
    return _doorKeys;
  }

  /// Hands this door's mailbox doors to the friends holding this phone's
  /// mailboxes, one slot each, and takes them back from friends who no
  /// longer do (or all of them, without a flat). A new door key ("Nowy
  /// kod") gives every holder the new key of its slot.
  Future<void> _syncSlots() async {
    final List<String>? boxes = mailboxes?.call();
    if (_syncingSlots || _diskUnreadable || boxes == null) {
      return;
    }
    _syncingSlots = true;
    try {
      final FlatDoorKeys? keys = await _currentKeys();
      final List<String> wanted = keys == null
          ? const <String>[]
          : boxes.map(_n).toSet().take(kDoorSlots).toList();
      final int now = max(_now(), _slotAt + 1);
      bool changed = false;
      for (final MapEntry<int, String> e in _slotHolders.entries.toList()) {
        if (!wanted.contains(e.value)) {
          _slotHolders.remove(e.key);
          changed = true;
          await _send(e.value, <String, dynamic>{
            'type': FlatTypes.slot,
            's': '',
            'at': now,
          });
        }
      }
      if (keys != null) {
        final bool rotated = _slotsFor != keys.doorKey;
        for (final String friend in wanted) {
          int? slot;
          for (final MapEntry<int, String> e in _slotHolders.entries) {
            if (e.value == friend) {
              slot = e.key;
            }
          }
          if (slot != null && !rotated) {
            continue;
          }
          if (slot == null) {
            int free = 0;
            while (_slotHolders.containsKey(free)) {
              free++;
            }
            if (free >= kDoorSlots) {
              continue;
            }
            _slotHolders[free] = friend;
            slot = free;
          }
          changed = true;
          await _send(friend, <String, dynamic>{
            'type': FlatTypes.slot,
            's': keys.slotSeeds[slot],
            'at': now,
          });
        }
        changed = changed || rotated;
        _slotsFor = keys.doorKey;
      } else if (_slotsFor.isNotEmpty) {
        _slotsFor = '';
        changed = true;
      }
      if (changed) {
        _slotAt = now;
        await _write();
      }
    } finally {
      _syncingSlots = false;
    }
  }

  /// The key this phone runs the flat's door with ([doorInbox]); `null`
  /// without a flat.
  String? get doorKey =>
      hasFlat && _door.isNotEmpty && _doorKeyFor == _door ? _doorKey : null;

  /// The door came up, went down or moved ([doorInbox]): the door QR
  /// changes with it, the profile names the new door, and what waits to go
  /// out from the door is tried now.
  void doorInboxChanged() {
    notifyListeners();
    _later(() async {
      await _syncOwnDoor();
      await _retryDoorSends();
    });
  }

  /// Runs [work] once what is queued now (handling frames) is done, but
  /// outside the queue, as the public calls run: what it sends may be
  /// answered with frames this phone then has to handle.
  void _later(Future<void> Function() work) {
    unawaited(
      _queue.then((_) async {
        try {
          await work();
        } on Object catch (error, stack) {
          logZenError('Sąsiedzi', error, stack);
        }
      }),
    );
  }

  /// This phone's door address ([doorInbox]), or `null` while none runs.
  String? get _ownDoor {
    final String? d = doorInbox?.call();
    return d != null && isRoutablePeerAddress(d) ? _n(d) : null;
  }

  /// Whether the profile still names an old door (or none) for this
  /// resident while the door runs at [_ownDoor].
  bool get _ownDoorStale {
    final FlatProfile? p = _profile;
    final String? me = _resident?.id;
    final String? door = _ownDoor;
    return p != null &&
        _pair != null &&
        !joining &&
        me != null &&
        door != null &&
        p.members.containsKey(me) &&
        p.members[me] != door;
  }

  /// Puts this phone's current door into the profile (a new door code
  /// gives every resident's door a new key, so a new address).
  Future<void> _syncOwnDoor() async {
    if (!_ownDoorStale) {
      return;
    }
    final String me = _resident!.id;
    final String door = _ownDoor!;
    final List<NeighborFlat> others = <NeighborFlat>[
      for (final NeighborFlat f in _neighbors.values)
        if (!audience.contains(f)) f,
    ];
    await _changeProfile(
      (FlatProfile p) =>
          p.copyWith(members: <String, String>{...p.members, me: door}),
    );
    // Everyone else must reach the new door too (the audience got it).
    await _pushProfile(to: others, quiet: true);
  }

  /// Makes [_doorKey] match the door token; true when it changed.
  bool _syncDoorKey() {
    if (_door.isEmpty || !hasFlat) {
      final bool had = _doorKey != null;
      _doorKey = null;
      _doorKeyFor = '';
      return had;
    }
    if (_doorKey != null && _doorKeyFor == _door) {
      return false;
    }
    _doorKey = List<String>.generate(
      32,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _doorKeyFor = _door;
    return true;
  }

  /// A new household code ("Pokaż kod domownika"): it works once, for
  /// [kHomeCodeLife], and only lets a phone ask; this phone then confirms
  /// it ([approveJoin]). `null` without a flat or an address.
  FlatHomeCode? inviteHousemate() {
    final FlatProfile? p = _profile;
    final String own = _own;
    if (p == null || !hasFlat || own.isEmpty) {
      return null;
    }
    final int now = _now();
    _invites.removeWhere((String _, int until) => until <= now);
    while (_invites.length >= 8) {
      _invites.remove(_invites.keys.first);
    }
    final String token = _newDoor();
    final int until = now + kHomeCodeLife.inMilliseconds;
    _invites[token] = until;
    return FlatHomeCode(
      token: token,
      address: own,
      flatKey: p.key,
      name: p.label,
      until: until,
    );
  }

  /// Phones asking to join with a code this phone showed, oldest first.
  List<FlatJoinRequest> get joinRequests =>
      _joinRequests.values.toList()
        ..sort((FlatJoinRequest a, FlatJoinRequest b) => a.at.compareTo(b.at));

  /// The household this phone asked to join, while it waits ([joining]).
  String? get joiningName => _joinAsk?.flatName;

  /// The household's own key (tests compare housemates' keys).
  @visibleForTesting
  String? get flatSeed => _seed;

  /// This resident's first name in the flat: what housemates see, and what
  /// messages to neighbour flats are signed with.
  String get myName {
    final String? me = _resident?.id;
    final String name = me == null ? '' : residentName(me);
    return name.isNotEmpty ? name : _defaultName();
  }

  /// Changes this resident's first name in the flat.
  Future<void> setMyName(String name) async {
    final String? me = _resident?.id;
    final String clipped = _clip(name, 40);
    if (me == null || !hasFlat || clipped.isEmpty) {
      return;
    }
    _names[me] = clipped;
    await _save();
    await _syncHouse();
  }

  /// The first word of the account's name: a first name to start with.
  String _defaultName() {
    final String name = host.ownName().trim();
    return name.isEmpty ? '' : _clip(name.split(RegExp(r'\s+')).first, 40);
  }

  /// This phone's own address (housemates only ever see it).
  String get _own => _n(host.ownAddress());

  List<NeighborFlat> get neighbors => _neighbors.values.toList()
    ..sort(
      (NeighborFlat a, NeighborFlat b) => a.profile.label
          .toLowerCase()
          .compareTo(b.profile.label.toLowerCase()),
    );

  NeighborFlat? neighbor(String key) => _neighbors[key];

  List<FlatMessage> messagesWith(String key) =>
      _messages.values.where((FlatMessage m) => m.flat == key).toList()
        ..sort((FlatMessage a, FlatMessage b) => a.at.compareTo(b.at));

  /// The small chat about one invitation ([itemId]) with the flat [key].
  List<FlatMessage> threadAbout(String key, String itemId) =>
      messagesWith(key).where((FlatMessage m) => m.item == itemId).toList();

  int unread(String key) {
    final int since = _lastRead[key] ?? 0;
    return _messages.values
        .where((FlatMessage m) => m.flat == key && !m.mine && m.at > since)
        .length;
  }

  Future<void> markRead(String key) async {
    _lastRead[key] = _now();
    await _save();
  }

  List<FlatSignup> signupsFor(String itemId) =>
      (_signups[itemId]?.values ?? const Iterable<FlatSignup>.empty())
          .where((FlatSignup s) => s.count > 0)
          .toList()
        ..sort((FlatSignup a, FlatSignup b) => a.at.compareTo(b.at));

  /// How many places we hold for [itemId] at [flat] (0 = none).
  int mySignup(String flat, String itemId) =>
      _mine['$flat|$itemId']?.count ?? 0;

  /// A resident's name (by resident key), as housemates told it ('' when
  /// unknown).
  String residentName(String resident) => _names[resident] ?? '';

  /// Residents (resident keys) who voted to remove the resident [target].
  Set<String> votesFor(String target) {
    final Map<String, String> members =
        _profile?.members ?? const <String, String>{};
    return <String>{
      for (final String v in _kickVotes[target] ?? const <String>{})
        if (members.containsKey(v) && v != target) v,
    };
  }

  /// Votes needed to remove [target]: a majority of the other residents.
  int votesNeeded(String target) {
    final int others = (_profile?.members.length ?? 1) - 1;
    return others ~/ 2 + 1;
  }

  bool _enoughVotes(String target) =>
      votesFor(target).length >= votesNeeded(target);

  /// Residents of [key] who showed us their own account.
  List<FlatReveal> revealsFrom(String key) =>
      List<FlatReveal>.of(_reveals[key] ?? const <FlatReveal>[]);

  /// Whether this phone already showed its account to [key].
  bool revealedTo(String key) => _revealedTo.contains(key);

  /// The other new key of [key]'s household when two different ones came
  /// ([kFlatKeyConflict]); `null` normally. Scanning the household's new
  /// door code ([scanDoor]) or [keepCurrentKey] settles it.
  FlatProfile? keyRival(String key) {
    for (final FlatKeySwitch s in _switches.values) {
      if (s.newKey == key && s.rival != null) {
        return s.rival;
      }
    }
    return null;
  }

  /// Keeps the key [key]'s household has now and drops the other one.
  Future<void> keepCurrentKey(String key) async {
    bool changed = false;
    for (final FlatKeySwitch s in _switches.values.toList()) {
      if (s.newKey == key && s.rival != null) {
        s
          ..rival = null
          ..rivalRemoved = <String>{}
          ..rivalBy = '';
        changed = true;
      }
    }
    if (changed) {
      await _save();
    }
  }

  /// This phone's resident key (public), once there is one.
  String? get residentKey => _resident?.id;

  /// Signs [message] with this phone's resident key (tests play a removed
  /// phone that cheats with its own key).
  @visibleForTesting
  Future<String?> residentSign(List<int> message) async {
    final LedgerKeyPair? r = _resident;
    return r == null ? null : b64(await r.signWithKey(message));
  }

  List<NearbyFlatInvite> get nearbyInvites {
    final int t = _now();
    return _nearby
        .where(
          (NearbyFlatInvite i) =>
              t - i.at < kNearbyInviteLife.inMilliseconds &&
              !i.door.expiredAt(t),
        )
        .toList()
      ..sort((NearbyFlatInvite a, NearbyFlatInvite b) => b.at.compareTo(a.at));
  }

  /// Knocks on our door waiting for a resident: "{name} puka do drzwi",
  /// let in ([acceptKnock]) or not ([rejectKnock]). Each one waits
  /// [kKnockLife].
  List<FlatKnock> get knocks {
    final int t = _now();
    return _knocks.values
        .where((FlatKnock k) => t - k.at < kKnockLife.inMilliseconds)
        .toList()
      ..sort((FlatKnock a, FlatKnock b) => a.at.compareTo(b.at));
  }

  String _newId([int length = 12]) => List<String>.generate(
    length,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  String _newDoor() => b64(
    List<int>.generate(12, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');

  // ---- storage ----

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  /// The stored state was read at least once ([doorKey] and
  /// [hostedDoorKeys] are the real ones, not empty memory).
  bool get isLoaded => _loaded;
  bool _loaded = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_key);
      _diskUnreadable = false;
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        await _fromJson(json);
      }
      _loaded = true;
      await _checkRestored();
      if (_syncDoorKey()) {
        await _save();
      }
      await _currentKeys();
      await _syncSlots();
      await _syncOwnDoor();
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt sąsiadów', error, stack);
    }
  }

  Future<void> _fromJson(Map<dynamic, dynamic> json) async {
    final Object? seed = json['seed'];
    _seed = seed is String ? seed : null;
    _pair = null;
    final Uint8List? seedBytes = unb64(_seed, length: 32);
    if (seedBytes != null) {
      _pair = await LedgerKeyPair.fromSeed(seedBytes);
    }
    _profile = FlatProfile.fromJson(json['p']);
    _door = json['door'] is String ? json['door'] as String : '';
    _doorAt = json['doorAt'] is int ? json['doorAt'] as int : 0;
    _doorKey = json['dk'] is String ? json['dk'] as String : null;
    _doorKeyFor = json['dkFor'] is String ? json['dkFor'] as String : '';
    _knocks.clear();
    final Object? knocks = json['knock'];
    if (knocks is List) {
      for (final Object? item in knocks) {
        final FlatKnock? k = FlatKnock.fromJson(item);
        if (k != null) {
          _knocks[k.key] = k;
        }
      }
    }
    _knocksSeen
      ..clear()
      ..addAll(_intMap(json['knockSeen']));
    _decided.clear();
    _takeDecisions(json['kd']);
    _view = FlatDoorView.fromJson(json['view']);
    _viewAt = json['viewAt'] is int ? json['viewAt'] as int : 0;
    _joinAsk = _JoinAsk.fromJson(json['jask']);
    _tempDoors
      ..clear()
      ..addAll(_intMap(json['td']));
    _kickAsks
      ..clear()
      ..addAll(_intMap(json['kask']));
    final Object? asked = json['asked'];
    _askedToGo = asked is Map && asked['by'] is String && asked['at'] is int
        ? (asked['by'] as String, asked['at'] as int)
        : null;
    _leaving.clear();
    final Object? leaving = json['leaving'];
    if (leaving is Map) {
      for (final MapEntry<dynamic, dynamic> e in leaving.entries) {
        final Object? v = e.value;
        if (e.key is String && v is Map && v['s'] is String && v['at'] is int) {
          _leaving[e.key as String] = (v['s'] as String, v['at'] as int);
        }
      }
    }
    _slotHolders.clear();
    final Object? slots = json['slots'];
    if (slots is Map) {
      for (final MapEntry<dynamic, dynamic> e in slots.entries) {
        final int? slot = e.key is String
            ? int.tryParse(e.key as String)
            : null;
        if (slot != null &&
            slot >= 0 &&
            slot < kDoorSlots &&
            e.value is String) {
          _slotHolders[slot] = _n(e.value as String);
        }
      }
    }
    _slotsFor = json['slotsFor'] is String ? json['slotsFor'] as String : '';
    _slotAt = json['slotAt'] is int ? json['slotAt'] as int : 0;
    _hosted.clear();
    final Object? hosted = json['hosted'];
    if (hosted is List) {
      for (final Object? item in hosted.take(kMaxHostedDoors)) {
        final HostedDoor? d = HostedDoor.fromJson(item);
        if (d != null) {
          _hosted[d.owner] = d;
        }
      }
    }
    _heldSeen
      ..clear()
      ..addAll(_intMap(json['heldSeen']));
    pending.clear();
    _pendingAt.clear();
    _cards.clear();
    final Object? pend = json['pend'];
    if (pend is List) {
      for (final Object? item in pend) {
        if (item is Map && item['q'] is String && item['at'] is int) {
          final FlatDoorCode? code = FlatDoorCode.parse(item['q'] as String);
          if (code != null) {
            pending[code.key] = code;
            _pendingAt[code.key] = item['at'] as int;
            final FlatCard? card = FlatCard.fromJson(item['c']);
            if (card != null && card.key == code.key) {
              _cards[code.key] = card;
            }
          }
        }
      }
    }
    shareWithScanners = json['share'] == true;
    _shareAt = json['shareAt'] is int ? json['shareAt'] as int : 0;
    joining = json['joining'] == true;
    _neighbors.clear();
    final Object? nb = json['nb'];
    if (nb is List) {
      for (final Object? item in nb) {
        final NeighborFlat? f = NeighborFlat.fromJson(item);
        if (f != null) {
          _neighbors[f.key] = f;
        }
      }
    }
    _removed
      ..clear()
      ..addAll(_intMap(json['rm']));
    _messages.clear();
    final Object? msgs = json['msgs'];
    if (msgs is List) {
      for (final Object? item in msgs) {
        final FlatMessage? m = FlatMessage.fromJson(item);
        if (m != null) {
          _messages[m.id] = m;
        }
      }
    }
    _lastRead
      ..clear()
      ..addAll(_intMap(json['read']));
    _signups
      ..clear()
      ..addAll(_signupsFromJson(json['sign']));
    _mine
      ..clear()
      ..addAll(_flatSignupMap(json['my']));
    _nearby.clear();
    final Object? near = json['near'];
    if (near is List) {
      for (final Object? item in near) {
        final NearbyFlatInvite? i = NearbyFlatInvite.fromJson(item);
        if (i != null) {
          _nearby.add(i);
        }
      }
    }
    _names
      ..clear()
      ..addAll(_stringMap(json['names']));
    _phones
      ..clear()
      ..addAll(_phoneMap(json['phones']));
    _doorOut.clear();
    final Object? out = json['out'];
    if (out is List) {
      for (final Object? item in out.take(kMaxDoorOutbox)) {
        final _DoorSend? d = _DoorSend.fromJson(item);
        if (d != null) {
          _doorOut[d.id] = d;
        }
      }
    }
    _kickVotes.clear();
    final Object? kick = json['kick'];
    if (kick is Map) {
      for (final MapEntry<dynamic, dynamic> e in kick.entries) {
        if (e.key is String && e.value is List) {
          _kickVotes[e.key as String] = (e.value as List)
              .whereType<String>()
              .toSet();
        }
      }
    }
    _oldKey = json['oldKey'] is String ? json['oldKey'] as String : null;
    _reveals.clear();
    final Object? rv = json['rv'];
    if (rv is Map) {
      for (final MapEntry<dynamic, dynamic> e in rv.entries) {
        if (e.key is String && e.value is List) {
          _reveals[e.key as String] = <FlatReveal>[
            for (final Object? r in (e.value as List).take(20))
              if (FlatReveal.fromJson(r) != null) FlatReveal.fromJson(r)!,
          ];
        }
      }
    }
    _revealedTo
      ..clear()
      ..addAll(
        ((json['rvTo'] as List?) ?? const <Object?>[]).whereType<String>(),
      );
    final Uint8List? residentSeed = unb64(json['rseed'], length: 32);
    _residentSeed = residentSeed == null ? null : json['rseed'] as String;
    _resident = residentSeed == null
        ? null
        : await LedgerKeyPair.fromSeed(residentSeed);
    _restoredAt = json['rest'] is int ? json['rest'] as int : null;
    _voteSigs.clear();
    final Object? kickSig = json['kickSig'];
    if (kickSig is Map) {
      for (final MapEntry<dynamic, dynamic> e in kickSig.entries) {
        if (e.key is String && e.value is Map) {
          _voteSigs[e.key as String] = <String, String>{
            for (final MapEntry<dynamic, dynamic> v in (e.value as Map).entries)
              if (v.key is String && v.value is String)
                v.key as String: v.value as String,
          };
        }
      }
    }
    _switches.clear();
    final Object? sw = json['sw'];
    if (sw is List) {
      for (final Object? item in sw) {
        final FlatKeySwitch? s = FlatKeySwitch.fromJson(item);
        if (s != null) {
          _switches[s.oldKey] = s;
        }
      }
    }
  }

  /// Phone addresses by resident key, from JSON (anything else dropped).
  Map<String, String> _phoneMap(Object? json) => <String, String>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (unb64(e.key, length: 32) != null &&
            e.value is String &&
            isRoutablePeerAddress(e.value as String))
          e.key as String: _n(e.value as String),
  };

  static Map<String, String> _stringMap(Object? json) => <String, String>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is String)
          e.key as String: (e.value as String).length > 40
              ? (e.value as String).substring(0, 40)
              : e.value as String,
  };

  static Map<String, int> _intMap(Object? json) => <String, int>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
  };

  static Map<String, FlatSignup> _flatSignupMap(Object? json) =>
      <String, FlatSignup>{
        if (json is Map)
          for (final MapEntry<dynamic, dynamic> e in json.entries)
            if (e.key is String && FlatSignup.fromJson(e.value) != null)
              e.key as String: FlatSignup.fromJson(e.value)!,
      };

  static Map<String, Map<String, FlatSignup>> _signupsFromJson(Object? json) =>
      <String, Map<String, FlatSignup>>{
        if (json is Map)
          for (final MapEntry<dynamic, dynamic> e in json.entries)
            if (e.key is String) e.key as String: _flatSignupMap(e.value),
      };

  Map<String, dynamic> _signupsJson() => <String, dynamic>{
    for (final MapEntry<String, Map<String, FlatSignup>> e in _signups.entries)
      e.key: <String, dynamic>{
        for (final MapEntry<String, FlatSignup> s in e.value.entries)
          s.key: s.value.toJson(),
      },
  };

  Map<String, dynamic> _mineJson() => <String, dynamic>{
    for (final MapEntry<String, FlatSignup> e in _mine.entries)
      e.key: e.value.toJson(),
  };

  List<Map<String, dynamic>> _decisionsJson() => <Map<String, dynamic>>[
    for (final FlatKnockDecision d in _decided.values) d.toJson(),
  ];

  /// Takes answers to knocks from [json] (a list, stored or from a
  /// housemate): a newer answer replaces an older one for the same flat,
  /// and the knock it answers closes. Returns the flats whose knock closed.
  Set<String> _takeDecisions(Object? json) {
    final Set<String> closed = <String>{};
    if (json is! List) {
      return closed;
    }
    for (final Object? item in json.take(500)) {
      final FlatKnockDecision? d = FlatKnockDecision.fromJson(item);
      if (d == null) {
        continue;
      }
      final FlatKnockDecision? had = _decided[d.flat];
      if (had != null && had.at >= d.at) {
        continue;
      }
      _decided[d.flat] = d;
      // Retries of the same knock do not ask again.
      _knocksSeen['${d.flat}|${d.id}'] = d.at + kKnockMemory.inMilliseconds;
      final FlatKnock? k = _knocks[d.flat];
      if (k != null && _answers(d, k)) {
        _knocks.remove(d.flat);
        closed.add(d.flat);
      }
    }
    return closed;
  }

  /// Whether the answer [d] is about the knock [k] (or an older one).
  static bool _answers(FlatKnockDecision d, FlatKnock k) =>
      d.flat == k.key && (k.id.isNotEmpty ? d.id == k.id : k.at <= d.at);

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    await _write();
    // A new door key, or no flat any more: the mailbox doors follow.
    await _currentKeys();
    await _syncSlots();
  }

  Future<void> _write() async {
    if (_diskUnreadable) {
      return;
    }
    final int t = _now();
    _syncDoorKey();
    final int held = kHeldKnockLife.inMilliseconds;
    _heldSeen.removeWhere((String _, int until) => until <= t);
    for (final HostedDoor d in _hosted.values) {
      d.knocks.removeWhere((HeldKnock k) => t - k.at >= held);
    }
    pending.removeWhere(
      (String key, FlatDoorCode _) => t - (_pendingAt[key] ?? t) >= held,
    );
    _pendingAt.removeWhere((String key, int _) => !pending.containsKey(key));
    _nearby.removeWhere(
      (NearbyFlatInvite i) => t - i.at >= kNearbyInviteLife.inMilliseconds,
    );
    _knocks.removeWhere(
      (String _, FlatKnock k) => t - k.at >= kKnockLife.inMilliseconds,
    );
    _knocksSeen.removeWhere((String _, int until) => until <= t);
    _decided.removeWhere(
      (String _, FlatKnockDecision d) =>
          t - d.at >= kKnockMemory.inMilliseconds,
    );
    _cards.removeWhere((String key, FlatCard _) => !pending.containsKey(key));
    _tempDoors.removeWhere((String _, int until) => until <= t);
    _doorOut.removeWhere((String _, _DoorSend d) => d.until <= t);
    // Keep the newest 300 messages per neighbour.
    final Map<String, List<FlatMessage>> byFlat = <String, List<FlatMessage>>{};
    for (final FlatMessage m in _messages.values) {
      (byFlat[m.flat] ??= <FlatMessage>[]).add(m);
    }
    for (final List<FlatMessage> list in byFlat.values) {
      if (list.length > 300) {
        list.sort((FlatMessage a, FlatMessage b) => b.at.compareTo(a.at));
        for (final FlatMessage m in list.skip(300)) {
          _messages.remove(m.id);
        }
      }
    }
    // Key switches of neighbours are kept a month (an unsettled one, three).
    const int month = 30 * 24 * 3600 * 1000;
    _switches.removeWhere(
      (String _, FlatKeySwitch s) =>
          t - s.at > (s.rival == null ? month : 3 * month) ||
          !_neighbors.containsKey(s.newKey),
    );
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          if (_seed != null) 'seed': _seed,
          if (_profile != null) 'p': _profile!.toJson(),
          'door': _door,
          'doorAt': _doorAt,
          'dk': ?_doorKey,
          'dkFor': _doorKeyFor,
          if (shareWithScanners) 'share': true,
          'shareAt': _shareAt,
          if (joining) 'joining': true,
          'nb': <Map<String, dynamic>>[
            for (final NeighborFlat f in _neighbors.values) f.toJson(),
          ],
          'rm': _removed,
          'msgs': <Map<String, dynamic>>[
            for (final FlatMessage m in _messages.values) m.toJson(),
          ],
          'read': _lastRead,
          'sign': _signupsJson(),
          'my': _mineJson(),
          'near': <Map<String, dynamic>>[
            for (final NearbyFlatInvite i in _nearby) i.toJson(),
          ],
          'knock': <Map<String, dynamic>>[
            for (final FlatKnock k in _knocks.values) k.toJson(),
          ],
          'knockSeen': _knocksSeen,
          'kd': _decisionsJson(),
          'jask': ?_joinAsk?.toJson(),
          'td': _tempDoors,
          'kask': _kickAsks,
          if (_askedToGo != null)
            'asked': <String, dynamic>{
              'by': _askedToGo!.$1,
              'at': _askedToGo!.$2,
            },
          if (!_view.bare) 'view': _view.toJson(),
          'viewAt': _viewAt,
          'leaving': <String, dynamic>{
            for (final MapEntry<String, (String, int)> e in _leaving.entries)
              e.key: <String, dynamic>{'s': e.value.$1, 'at': e.value.$2},
          },
          'slots': <String, String>{
            for (final MapEntry<int, String> e in _slotHolders.entries)
              '${e.key}': e.value,
          },
          'slotsFor': _slotsFor,
          'slotAt': _slotAt,
          'hosted': <Map<String, dynamic>>[
            for (final HostedDoor d in _hosted.values) d.toJson(),
          ],
          'heldSeen': _heldSeen,
          'pend': <Map<String, dynamic>>[
            for (final MapEntry<String, FlatDoorCode> e in pending.entries)
              <String, dynamic>{
                'q': e.value.toQr(),
                'at': _pendingAt[e.key] ?? t,
                'c': ?_cards[e.key]?.toJson(),
              },
          ],
          'names': _names,
          'phones': _phones,
          'out': <Map<String, dynamic>>[
            for (final _DoorSend d in _doorOut.values) d.toJson(),
          ],
          'kick': <String, dynamic>{
            for (final MapEntry<String, Set<String>> e in _kickVotes.entries)
              e.key: e.value.toList(),
          },
          'oldKey': ?_oldKey,
          'rv': <String, dynamic>{
            for (final MapEntry<String, List<FlatReveal>> e in _reveals.entries)
              if (_neighbors.containsKey(e.key))
                e.key: <Map<String, dynamic>>[
                  for (final FlatReveal r in e.value) r.toJson(),
                ],
          },
          'rvTo': <String>[
            for (final String k in _revealedTo)
              if (_neighbors.containsKey(k)) k,
          ],
          'rseed': ?_residentSeed,
          'rest': ?_restoredAt,
          'kickSig': _voteSigs,
          'sw': <Map<String, dynamic>>[
            for (final FlatKeySwitch s in _switches.values) s.toJson(),
          ],
        }),
      ),
    );
    notifyListeners();
  }

  // ---- sending ----

  /// A message signed by our flat, addressed to the flat [to].
  Future<Map<String, dynamic>> _envelope(
    String type,
    String to,
    Map<String, dynamic> body,
  ) => _envelopeWith(_pair!, type, to, body);

  Future<Map<String, dynamic>> _envelopeWith(
    LedgerKeyPair pair,
    String type,
    String to,
    Map<String, dynamic> body,
  ) async {
    final Map<String, dynamic> signed = <String, dynamic>{
      'type': type,
      'f': pair.id,
      'to': to,
      'b': body,
    };
    final Uint8List sig = await pair.signWithKey(canonicalJsonBytes(signed));
    return <String, dynamic>{...signed, 's': b64(sig)};
  }

  /// Sends a frame signed by our flat to housemates' phones.
  Future<void> _sendToHouse(
    List<String> phones,
    String type,
    Map<String, dynamic> body,
  ) async {
    final LedgerKeyPair? pair = _pair;
    if (pair == null) {
      return;
    }
    final Map<String, dynamic> payload = await _envelope(type, pair.id, body);
    final String own = _own;
    for (final String m in phones.toSet()) {
      if (_n(m) != own) {
        await _send(m, payload);
      }
    }
  }

  /// Sends a frame signed by our flat to the flat [to] at its [doors], from
  /// this phone's door.
  Future<void> _sendToDoors(
    Iterable<String> doors,
    String type,
    String to,
    Map<String, dynamic> body, {
    LedgerKeyPair? pair,
  }) async {
    final LedgerKeyPair? signer = pair ?? _pair;
    if (signer == null) {
      return;
    }
    final Map<String, dynamic> payload = await _envelopeWith(
      signer,
      type,
      to,
      body,
    );
    bool waits = false;
    for (final String d in doors.toSet()) {
      waits = await _sendFromDoor(d, payload, save: false) || waits;
    }
    if (waits) {
      await _write();
    }
  }

  /// Sends [payload] from this phone's door to [to] and keeps it for
  /// retries (on disk too, unless [save] is off): until a door says it came
  /// ([FlatTypes.ack]) when [acked], otherwise (knocks: a door never answers
  /// one) until [life] is over. True while it waits.
  Future<bool> _sendFromDoor(
    String to,
    Map<String, dynamic> payload, {
    Duration life = kFlatSendLife,
    bool acked = true,
    bool save = true,
    String about = '',
  }) async {
    final String target = _n(to);
    if (target.isEmpty || target == _ownDoor) {
      return false;
    }
    final int now = _now();
    final Object? type = payload['type'];
    final Object? flat = payload['to'];
    if (type == FlatTypes.profile || type == FlatTypes.get) {
      // Only the newest profile (or request) for a door waits.
      _doorOut.removeWhere(
        (String _, _DoorSend d) =>
            d.to == target &&
            d.payload['type'] == type &&
            d.payload['to'] == flat,
      );
    }
    final String id = _newId(20);
    final _DoorSend out = _DoorSend(
      id: id,
      to: target,
      payload: <String, dynamic>{...payload, kReliableIdKey: id},
      until: now + life.inMilliseconds,
      acked: acked,
      about: about,
    );
    // Kept before it goes: the answer may come back while it is sent.
    _doorOut[id] = out;
    while (_doorOut.length > kMaxDoorOutbox) {
      _doorOut.remove(_doorOut.keys.first);
    }
    await _tryDoorSend(out);
    final bool waits = _doorOut.containsKey(id);
    if (waits && save) {
      await _write();
    }
    return waits;
  }

  Future<void> _tryDoorSend(_DoorSend out) async {
    bool sent = false;
    try {
      sent = await doorSend?.call(out.to, out.payload) ?? false;
    } on Object catch (error) {
      logZenWarning('Sąsiedzi: ${out.payload['type']} do ${out.to}: $error');
    }
    if (sent) {
      out.tries++;
    }
    out.next =
        _now() +
        _doorRetries[min(max(out.tries - 1, 0), _doorRetries.length - 1)]
            .inMilliseconds;
  }

  /// Retries what waits to go out from the door; the app calls it now and
  /// then, and when the door comes up.
  Future<void> retryDoorSends() {
    final Completer<void> done = Completer<void>();
    _later(() async {
      try {
        await _retryDoorSends();
        // A housemate left and the first one to make the new key did not.
        await _maybeRekeyAfterLeave();
        // In a household of two: a week without an answer.
        for (final String target in _kickAsks.keys.toList()) {
          await _maybeRekey(target);
        }
        await _syncOwnDoor();
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  Future<void> _retryDoorSends() async {
    final int now = _now();
    final int before = _doorOut.length;
    _doorOut.removeWhere((String _, _DoorSend d) => d.until <= now);
    for (final _DoorSend d in _doorOut.values.toList()) {
      if (d.next <= now && _doorOut.containsKey(d.id)) {
        await _tryDoorSend(d);
      }
    }
    if (_doorOut.length != before) {
      await _write();
    }
  }

  /// Frames still waiting to go out from the door (tests).
  @visibleForTesting
  int get doorOutbox => _doorOut.length;

  /// A door says our frame [id] came: it is not retried any more.
  void _onAck(String from, Map<String, dynamic> p) {
    final Object? id = p['id'];
    final _DoorSend? out = id is String ? _doorOut[id] : null;
    if (out != null && out.to == from && out.acked) {
      _doorOut.remove(id);
    }
  }

  /// Tells the door [to] that its frame [rid] came (from our door: the
  /// answer must not name this phone either).
  void _ack(String to, Object? rid) {
    if (rid is! String || rid.isEmpty || rid.length > 64) {
      return;
    }
    unawaited(
      Future<void>(() async {
        try {
          await doorSend?.call(to, <String, dynamic>{
            'type': FlatTypes.ack,
            'id': rid,
          });
        } on Object catch (error) {
          logZenWarning('Sąsiedzi: potwierdzenie do $to: $error');
        }
      }),
    );
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Sąsiedzi: ${payload['type']} do $to: $error');
    }
  }

  /// Housemates' phones (all residents but this phone).
  List<String> get _housemates {
    final String own = _own;
    return <String>[
      for (final String r in _profile?.members.keys ?? const <String>[])
        if (_phones[r] != null && _phones[r] != own) _phones[r]!,
    ];
  }

  /// Neighbours who get our profile (and so our invitations) pushed.
  List<NeighborFlat> get audience => <NeighborFlat>[
    for (final NeighborFlat f in _neighbors.values)
      if (f.weScanned || (f.scannedUs && shareWithScanners)) f,
  ];

  /// Sends our profile to [to] (the [audience] by default). [quiet]: only
  /// so they reach our doors (a door moved); they do not hear of our news
  /// from it.
  Future<void> _pushProfile({
    Iterable<NeighborFlat>? to,
    bool quiet = false,
  }) async {
    final FlatProfile? p = _profile;
    if (p == null) {
      return;
    }
    for (final NeighborFlat f in (to ?? audience).toList()) {
      await _sendToDoors(
        f.profile.doors,
        FlatTypes.profile,
        f.key,
        <String, dynamic>{'p': p.toJson(), if (quiet) 'q': true},
      );
    }
  }

  /// Makes sure this phone has its resident key, and that its phone is on
  /// the housemates' list.
  Future<LedgerKeyPair> _ensureResident() async {
    LedgerKeyPair? pair = _resident;
    if (pair == null) {
      pair = await LedgerKeyPair.generate();
      _resident = pair;
      _residentSeed = b64(pair.seed);
    }
    final String own = _own;
    if (own.isNotEmpty) {
      _phones[pair.id] = own;
    }
    return pair;
  }

  /// Pins the residents' keys of a neighbour flat's profile [p]: the first
  /// time each was seen stays for good.
  bool _pinResidents(NeighborFlat f, FlatProfile p) {
    bool changed = false;
    for (final String r in p.members.keys) {
      if (!f.residents.containsKey(r)) {
        f.residents[r] = _now();
        changed = true;
      }
    }
    return changed;
  }

  /// Sends the whole shared state to the housemates. With [ring] a knock
  /// that just came is in it: the housemates' phones ring for it too.
  Future<void> _syncHouse({List<String>? to, bool ring = false}) async {
    final FlatProfile? p = _profile;
    if (p == null) {
      return;
    }
    final List<FlatMessage> recent = _messages.values.toList()
      ..sort((FlatMessage a, FlatMessage b) => b.at.compareTo(a.at));
    await _sendToHouse(to ?? _housemates, FlatTypes.house, <String, dynamic>{
      'p': p.toJson(),
      'door': _door,
      'doorAt': _doorAt,
      'share': shareWithScanners,
      'shareAt': _shareAt,
      // Knocks wait on every resident's phone; the first answer counts.
      'kn': _knocksForHouse(),
      'kd': _decisionsJson(),
      if (ring) 'ring': true,
      // Short-lived door tokens of invitations passed nearby.
      'td': _tempDoors,
      'view': _view.toJson(),
      'viewAt': _viewAt,
      'nb': <Map<String, dynamic>>[
        for (final NeighborFlat f in _neighbors.values)
          <String, dynamic>{
            'p': f.profile.toJson(),
            'at': f.addedAt,
            if (f.weScanned) 'ws': true,
            if (f.scannedUs) 'su': true,
            if (f.residents.isNotEmpty) 'rk': f.residents,
          },
      ],
      'rm': _removed,
      'msgs': <Map<String, dynamic>>[
        for (final FlatMessage m in recent.take(200)) m.toJson(),
      ],
      'sign': _signupsJson(),
      'my': _mineJson(),
      'names': _names,
      'ph': <String, String>{
        for (final MapEntry<String, String> e in _phones.entries)
          if (p.members.containsKey(e.key)) e.key: e.value,
      },
    });
  }

  /// The knocks waiting here, as they go to the housemates: the newest
  /// first, photos within [kKnockSyncPhotoChars].
  List<Map<String, dynamic>> _knocksForHouse() {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    int photos = 0;
    for (final FlatKnock k in knocks.reversed) {
      final int size = k.profile.photo.length;
      if (size > 0 && photos + size > kKnockSyncPhotoChars) {
        continue;
      }
      photos += size;
      out.add(k.toJson());
    }
    return out;
  }

  /// Takes the knocks a housemate has ([json]); returns the ones new here.
  List<FlatKnock> _takeKnocks(Object? json) {
    final List<FlatKnock> fresh = <FlatKnock>[];
    if (json is! List) {
      return fresh;
    }
    final int now = _now();
    for (final Object? item in json.take(kMaxKnocks)) {
      final FlatKnock? k = FlatKnock.fromJson(item);
      if (k == null ||
          now - k.at >= kKnockLife.inMilliseconds ||
          _neighbors.containsKey(k.key) ||
          k.key == _profile?.key) {
        continue;
      }
      final FlatKnockDecision? d = _decided[k.key];
      if (d != null && _answers(d, k)) {
        continue;
      }
      final FlatKnock? had = _knocks[k.key];
      if (had != null && (had.id == k.id || had.at >= k.at)) {
        continue;
      }
      _knocks[k.key] = k;
      if (had == null) {
        fresh.add(k);
      }
    }
    _trimKnocks();
    return <FlatKnock>[
      for (final FlatKnock k in fresh)
        if (_knocks.containsKey(k.key)) k,
    ];
  }

  /// At most [kMaxKnocks] wait; the oldest go first.
  void _trimKnocks() {
    while (_knocks.length > kMaxKnocks) {
      final FlatKnock oldest = _knocks.values.reduce(
        (FlatKnock a, FlatKnock c) => a.at <= c.at ? a : c,
      );
      _knocks.remove(oldest.key);
    }
  }

  // ---- this flat ----

  /// Creates this phone's flat ("Nowakowie, m. 12").
  Future<FlatProfile?> createFlat(
    String name, {
    String place = '',
    String about = '',
  }) async {
    final String own = _own;
    if (name.trim().isEmpty || own.isEmpty || hasFlat) {
      return null;
    }
    final LedgerKeyPair pair = await LedgerKeyPair.generate();
    _seed = b64(pair.seed);
    _pair = pair;
    _phones.clear();
    final LedgerKeyPair me = await _ensureResident();
    _door = _newDoor();
    _doorAt = _now();
    _profile = await FlatProfile(
      key: pair.id,
      name: _clip(name, 60),
      place: _clip(place, 80),
      about: _clip(about, 1000),
      // The door comes up with the door key ([_save]); then it is named.
      members: <String, String>{me.id: ''},
      rev: 1,
    ).signedWith(pair);
    _names[me.id] = _defaultName();
    joining = false;
    await _save();
    await _syncOwnDoor();
    return _profile;
  }

  static String _clip(String s, int max) {
    final String t = s.trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  /// Asks to join a housemate's flat with their household code: the
  /// housemate's phone shows this phone's name and device and confirms it;
  /// only then does the household's key come, sealed to this phone. False
  /// when the code is over or this phone already has a flat.
  Future<bool> joinFlat(FlatHomeCode code) async {
    final String own = _own;
    if (own.isEmpty || hasFlat || code.until <= _now()) {
      return false;
    }
    final RelayIdentity box = await RelayIdentity.generate();
    final Uint8List kemSeed = randomHybridSeed();
    _seed = null;
    _pair = null;
    _phones.clear();
    joining = true;
    final LedgerKeyPair me = await _ensureResident();
    _joinAsk = _JoinAsk(
      address: code.address,
      token: code.token,
      flatKey: code.flatKey,
      flatName: code.name,
      sealPrivate: b64(box.privateKey),
      sealPublic: box.publicKeyBase64,
      kemSeed: b64(kemSeed),
    );
    await _save();
    final Map<String, Object?> ask = <String, Object?>{
      't': code.token,
      'n': _defaultName(),
      'dv': _clip(deviceName?.call() ?? '', 40),
      'rk': me.id,
      'x': box.publicKeyBase64,
      'q': b64(await hybridKem.publicKeyOf(kemSeed)),
    };
    await _send(code.address, <String, dynamic>{
      'type': FlatTypes.join,
      'step': 'ask',
      ...ask,
      'rs': b64(await me.signWithKey(flatJoinAskBytes(ask))),
    });
    return true;
  }

  /// The steps of joining with a household code, phone to phone and not
  /// signed with the household's key (the new phone has none yet): the
  /// new phone asks ('ask'), the housemate's phone answers with the key
  /// sealed to it ('ok') or says no ('no').
  Future<void> _onJoinStep(String sender, Map<String, dynamic> p) async {
    switch (p['step']) {
      case 'ask':
        await _onJoinAsk(sender, p);
      case 'ok':
        await _onJoinOk(sender, p);
      case 'no':
        await _onJoinNo(sender, p);
    }
  }

  Future<void> _onJoinAsk(String sender, Map<String, dynamic> p) async {
    final FlatProfile? f = _profile;
    final Object? token = p['t'];
    final Object? rk = p['rk'];
    final Object? x = p['x'];
    final Object? q = p['q'];
    final Object? rs = p['rs'];
    final Object? n = p['n'];
    final Object? dv = p['dv'];
    final int now = _now();
    final Uint8List? kem = q is String && q.length <= 2000 ? unb64(q) : null;
    if (f == null ||
        !hasFlat ||
        token is! String ||
        (_invites[token] ?? 0) <= now ||
        rk is! String ||
        unb64(rk, length: 32) == null ||
        x is! String ||
        decodeRelayKey(x) == null ||
        kem == null ||
        kem.length != kHybridPublicKeyBytes ||
        rs is! String ||
        (n != null && n is! String) ||
        (dv != null && dv is! String) ||
        !await verifyLedgerSignature(
          publicKey: rk,
          message: flatJoinAskBytes(<String, Object?>{
            't': token,
            'n': n,
            'dv': dv,
            'rk': rk,
            'x': x,
            'q': q,
          }),
          signature: rs,
        )) {
      return;
    }
    // A code works once.
    _invites.remove(token);
    final String name = n is String ? _clip(n, 40) : '';
    final String device = dv is String ? _clip(dv, 40) : '';
    _joinRequests[token] = FlatJoinRequest(
      id: token,
      name: name,
      device: device,
      resident: rk,
      phone: sender,
      seal: x,
      kem: kem,
      at: now,
    );
    notifyListeners();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-join-ask-${token.hashCode}',
        title: t('{name} chce zostać domownikiem', {
          'name': name.isEmpty ? t('Ktoś') : name,
        }),
        body: t('{device} — potwierdź albo odrzuć w Sąsiadach.', {
          'device': device.isEmpty ? t('Nowy telefon') : device,
        }),
        createdAtMillis: now,
        category: RuntimeSystemNotificationCategory.social,
        routeKey: buildFlatKnocksRouteKey(),
        slotKey: 'flat-join',
      ),
    );
  }

  /// "Dołącz": the new phone gets the household's key, sealed to it; it
  /// then joins as a resident ([FlatTypes.join], signed with the key).
  Future<bool> approveJoin(String id) async {
    final FlatJoinRequest? r = _joinRequests.remove(id);
    final String? seed = _seed;
    final LedgerKeyPair? pair = _pair;
    if (r == null || seed == null || pair == null || !hasFlat) {
      notifyListeners();
      return false;
    }
    final Map<String, dynamic>? box = await FlatSeal.seal(
      <String, dynamic>{'s': seed, 'k': pair.id},
      r.seal,
      kem: r.kem,
    );
    if (box == null) {
      notifyListeners();
      return false;
    }
    _approved[r.resident] = _now() + const Duration(days: 1).inMilliseconds;
    if (r.name.isNotEmpty) {
      _names[r.resident] = r.name;
    }
    await _save();
    await _send(r.phone, <String, dynamic>{
      'type': FlatTypes.join,
      'step': 'ok',
      't': r.id,
      ...box,
    });
    return true;
  }

  /// "Odrzuć": the new phone is told no, and gets nothing.
  Future<void> declineJoin(String id) async {
    final FlatJoinRequest? r = _joinRequests.remove(id);
    notifyListeners();
    if (r != null) {
      await _send(r.phone, <String, dynamic>{
        'type': FlatTypes.join,
        'step': 'no',
        't': r.id,
      });
    }
  }

  /// The housemate let this phone in: the household's key, sealed to it.
  Future<void> _onJoinOk(String sender, Map<String, dynamic> p) async {
    final _JoinAsk? ask = _joinAsk;
    if (ask == null ||
        hasFlat ||
        sender != _n(ask.address) ||
        p['t'] != ask.token) {
      return;
    }
    final Uint8List? private = unb64(ask.sealPrivate, length: 32);
    final Uint8List? public = decodeRelayKey(ask.sealPublic);
    final Uint8List? kemSeed = unb64(ask.kemSeed);
    final Map<String, dynamic>? box =
        private == null || public == null || kemSeed == null
        ? null
        : await FlatSeal.open(
            p,
            RelayIdentity(privateKey: private, publicKey: public),
            kemSeed: kemSeed,
          );
    final Object? seed = box?['s'];
    final Uint8List? seedBytes = unb64(seed, length: 32);
    if (seed is! String || seedBytes == null) {
      return;
    }
    final LedgerKeyPair pair = await LedgerKeyPair.fromSeed(seedBytes);
    if (pair.id != ask.flatKey) {
      return;
    }
    final LedgerKeyPair me = await _ensureResident();
    _pair = pair;
    _seed = seed;
    _joinAsk = null;
    _names[me.id] = _defaultName();
    await _save();
    // In: the housemate adds this resident and shares the household (after
    // this frame: the answer comes back here).
    _later(
      () async => _send(
        sender,
        await _envelope(FlatTypes.join, pair.id, <String, dynamic>{
          'a': _own,
          'n': _defaultName(),
          'rk': me.id,
        }),
      ),
    );
  }

  /// The housemate said no.
  Future<void> _onJoinNo(String sender, Map<String, dynamic> p) async {
    final _JoinAsk? ask = _joinAsk;
    if (ask == null || sender != _n(ask.address) || p['t'] != ask.token) {
      return;
    }
    _joinAsk = null;
    joining = false;
    _seed = null;
    _pair = null;
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-join-no-${ask.token.hashCode}',
        title: t('Dołączenie odrzucone'),
        body: t('Domownik nie potwierdził dołączenia do „{name}”.', {
          'name': ask.flatName,
        }),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-join',
      ),
    );
  }

  Future<void> _changeProfile(
    FlatProfile Function(FlatProfile p) change,
  ) async {
    final FlatProfile? p = _profile;
    final LedgerKeyPair? pair = _pair;
    if (p == null || pair == null) {
      return;
    }
    final FlatProfile next = change(p);
    _profile = await next.copyWith(rev: p.rev + 1).signedWith(pair);
    await _save();
    await _syncHouse();
    await _pushProfile();
  }

  Future<void> editProfile({String? name, String? place, String? about}) =>
      _changeProfile(
        (FlatProfile p) => p.copyWith(
          name: name == null || name.trim().isEmpty ? null : _clip(name, 60),
          place: place == null ? null : _clip(place, 80),
          about: about == null ? null : _clip(about, 1000),
        ),
      );

  /// Sets (or with `null` removes) the household's photo: a JPEG already
  /// made small with `compressFlatPhoto`.
  Future<bool> setPhoto(Uint8List? jpeg) async {
    if (!hasFlat) {
      return false;
    }
    final String photo = jpeg == null ? '' : b64(jpeg);
    if (photo.length > FlatProfile.maxPhotoChars) {
      return false;
    }
    await _changeProfile((FlatProfile p) => p.copyWith(photo: photo));
    return true;
  }

  /// Adds an invitation, offer or need. Returns its id.
  Future<String?> addItem(
    FlatItemKind kind,
    String text, {
    int? at,
    int seats = 0,
  }) async {
    if (!hasFlat || text.trim().isEmpty || _profile!.items.length >= 60) {
      return null;
    }
    final String id = _newId();
    await _changeProfile(
      (FlatProfile p) => p.copyWith(
        items: <FlatItem>[
          ...p.items,
          FlatItem(
            id: id,
            kind: kind,
            text: _clip(text, 300),
            at: kind == FlatItemKind.invite ? at : null,
            seats: kind == FlatItemKind.invite ? seats.clamp(0, 999) : 0,
          ),
        ],
      ),
    );
    return id;
  }

  Future<void> removeItem(String id) async {
    _signups.remove(id);
    await _changeProfile(
      (FlatProfile p) =>
          p.copyWith(items: p.items.where((FlatItem i) => i.id != id).toList()),
    );
  }

  /// A new door QR: the old one stops working (moving out, a leaked code).
  Future<void> newDoor() async {
    if (!hasFlat) {
      return;
    }
    _door = _newDoor();
    // Invitations passed nearby stop working too.
    _tempDoors.clear();
    // Always newer than the door it replaces, or housemates (same
    // millisecond, a clock behind theirs) keep the old one.
    _doorAt = max(_now(), _doorAt + 1);
    await _save();
    await _syncHouse();
    await _syncOwnDoor();
  }

  /// A flat that scanned our door code becomes a full neighbour: it gets
  /// our profile and invitations (as if we had scanned theirs).
  Future<void> confirmNeighbor(String key) async {
    final NeighborFlat? f = _neighbors[key];
    if (f == null || f.weScanned) {
      return;
    }
    f.weScanned = true;
    await _save();
    notifyListeners();
    await _syncHouse();
    await _pushProfile(to: <NeighborFlat>[f]);
  }

  Future<void> setShareWithScanners(bool on) async {
    shareWithScanners = on;
    _shareAt = _now();
    await _save();
    await _syncHouse();
    if (on) {
      await _pushProfile(
        to: _neighbors.values.where(
          (NeighborFlat f) => f.scannedUs && !f.weScanned,
        ),
      );
    }
  }

  /// This phone leaves the flat (the others keep it). The others make a
  /// new household key and door code without it, as when a phone is
  /// removed, so this phone can no longer sign for the household or read
  /// what comes to it; neighbours follow them.
  Future<void> leaveFlat() async {
    final FlatProfile? p = _profile;
    final LedgerKeyPair? me = _resident;
    if (p != null && _pair != null && me != null && !joining) {
      final List<String> others = _housemates;
      if (others.isNotEmpty) {
        // Signed with this phone's own key: neighbours take it as this
        // resident's consent when the household announces its new key.
        final String consent = b64(
          await me.signWithKey(flatLeaveBytes(p.key, me.id)),
        );
        await _sendToHouse(others, FlatTypes.leave, <String, dynamic>{
          'a': me.id,
          'ls': consent,
        });
      }
    }
    _dropFlat();
    await _save();
  }

  // ---- the circle copy (after a recovery) ----

  /// When the household was taken back from the circle copy, while no
  /// housemate has confirmed it yet; null otherwise.
  int? _restoredAt;

  /// How long a household taken from the circle copy waits for a
  /// housemate.
  static const Duration restoreConfirmWait = Duration(days: 14);

  /// Whether the household came from the circle copy and waits for a
  /// housemate's confirmation.
  bool get restoredUnconfirmed => _restoredAt != null;

  /// What the circle copy keeps of the household: its key, this resident's
  /// key, the profile, housemates' names and phones. Never the door key
  /// (one phone runs one door) nor neighbours (they come back with the
  /// household's state from a housemate). Null without a household.
  Map<String, dynamic>? backupState() {
    final FlatProfile? p = _profile;
    final String? seed = _seed;
    final String? residentSeed = _residentSeed;
    if (p == null || seed == null || residentSeed == null || joining) {
      return null;
    }
    return <String, dynamic>{
      'seed': seed,
      'rseed': residentSeed,
      'p': p.toJson(),
      'names': Map<String, String>.of(_names),
      'phones': Map<String, String>.of(_phones),
    };
  }

  /// Takes the household back from the circle copy (after a recovery),
  /// held back until a housemate confirms it with the household's current
  /// state: this phone asks the housemates to take it as the same resident
  /// (signed with the resident key). A household that changed its key
  /// meanwhile does not answer under the old one; after
  /// [restoreConfirmWait] the old key is dropped, never put in place of the
  /// new one (the person joins again from a housemate's code). Nothing when
  /// this phone has a household already.
  Future<bool> restoreFromBackup(Map<String, dynamic> json) async {
    if (_profile != null || _pair != null || joining) {
      return false;
    }
    final Object? seed = json['seed'];
    final Object? residentSeed = json['rseed'];
    final Uint8List? seedBytes = unb64(seed, length: 32);
    final Uint8List? residentBytes = unb64(residentSeed, length: 32);
    if (seed is! String ||
        residentSeed is! String ||
        seedBytes == null ||
        residentBytes == null) {
      return false;
    }
    final LedgerKeyPair pair = await LedgerKeyPair.fromSeed(seedBytes);
    final LedgerKeyPair resident = await LedgerKeyPair.fromSeed(residentBytes);
    final FlatProfile? p = await _verifiedProfile(pair.id, json['p']);
    if (p == null || !p.members.containsKey(resident.id)) {
      return false;
    }
    _seed = seed;
    _pair = pair;
    _profile = p;
    _residentSeed = residentSeed;
    _resident = resident;
    _names
      ..clear()
      ..addAll(_stringMap(json['names']));
    _phones
      ..clear()
      ..addAll(_phoneMap(json['phones']));
    _restoredAt = _now();
    await _ensureResident();
    await _save();
    await _announceRestored();
    return true;
  }

  /// Tells the housemates this resident is on this phone now.
  Future<void> _announceRestored() async {
    final LedgerKeyPair? me = _resident;
    final FlatProfile? p = _profile;
    final String own = _own;
    if (me == null || p == null || _pair == null || own.isEmpty) {
      return;
    }
    final String moved = b64(
      await me.signWithKey(flatMovedBytes(p.key, me.id, own)),
    );
    for (final String phone in _housemates) {
      await _send(
        phone,
        await _envelope(FlatTypes.join, p.key, <String, dynamic>{
          'a': own,
          'n': _names[me.id] ?? _defaultName(),
          'rk': me.id,
          'rs': moved,
        }),
      );
    }
  }

  /// At start: a household from the circle copy asks the housemates again,
  /// or is dropped once [restoreConfirmWait] passed without an answer.
  Future<void> _checkRestored() async {
    final int? at = _restoredAt;
    if (at == null) {
      return;
    }
    if (_now() - at > restoreConfirmWait.inMilliseconds) {
      _restoredAt = null;
      _dropFlat();
      await _save();
      return;
    }
    await _announceRestored();
  }

  /// Forgets everything of the household on this phone (it left, was
  /// removed, or gave up joining).
  void _dropFlat() {
    _joinAsk = null;
    _tempDoors.clear();
    _kickAsks.clear();
    _askedToGo = null;
    _invites.clear();
    _joinRequests.clear();
    _approved.clear();
    _knocks.clear();
    _knocksSeen.clear();
    _decided.clear();
    _cards.clear();
    _leaving.clear();
    _view = const FlatDoorView();
    _viewAt = 0;
    staleDoors.clear();
    _seed = null;
    _pair = null;
    _profile = null;
    _door = '';
    joining = false;
    shareWithScanners = false;
    _shareAt = 0;
    _neighbors.clear();
    _removed.clear();
    _messages.clear();
    _signups.clear();
    _mine.clear();
    pending.clear();
    _names.clear();
    _phones.clear();
    _kickVotes.clear();
    _pendingRekeys.clear();
    _oldKey = null;
    _reveals.clear();
    _revealedTo.clear();
    _voteSigs.clear();
    _switches.clear();
    _doorOut.clear();
    // The next household gets a resident key of its own.
    _resident = null;
    _residentSeed = null;
  }

  /// The household moves out: the door code stops working,
  /// neighbours are told and dropped, invitations and offers go — the
  /// household itself (name, residents, "O nas") stays and starts again at
  /// [newPlace]. The new tenants make their own profile from scratch.
  Future<void> moveOut({String newPlace = ''}) async {
    final FlatProfile? p = _profile;
    if (p == null || _pair == null) {
      return;
    }
    for (final NeighborFlat f in _neighbors.values.toList()) {
      await _sendToDoors(
        f.profile.doors,
        FlatTypes.moved,
        f.key,
        <String, dynamic>{'pl': p.place},
      );
    }
    final int t = _now();
    for (final String key in _neighbors.keys) {
      _removed[key] = t;
    }
    _neighbors.clear();
    _messages.clear();
    _signups.clear();
    _mine.clear();
    _nearby.clear();
    pending.clear();
    staleDoors.clear();
    _knocks.clear();
    _reveals.clear();
    _revealedTo.clear();
    _switches.clear();
    _door = _newDoor();
    _doorAt = t;
    _tempDoors.clear();
    await _changeProfile(
      (FlatProfile p) =>
          p.copyWith(place: _clip(newPlace, 80), items: const <FlatItem>[]),
    );
    await _syncOwnDoor();
  }

  // ---- neighbours ----

  /// A door QR was scanned (or an invitation nearby accepted).
  Future<FlatScan> scanDoor(FlatDoorCode code) async {
    final FlatProfile? p = _profile;
    if (p == null || _pair == null) {
      return FlatScan.noFlat;
    }
    if (code.key == p.key) {
      return FlatScan.own;
    }
    if (code.expiredAt(_now())) {
      return FlatScan.expired;
    }
    staleDoors.remove(code.key);
    // Asked in person, scanned their new door: that key stays.
    await _settleByDoor(code.key);
    final NeighborFlat? had = _neighbors[code.key];
    if (had != null && had.weScanned) {
      // Also at the door on the sticker: their doors may have moved since.
      await _sendToDoors(
        <String>[...had.profile.doors, code.inbox],
        FlatTypes.get,
        code.key,
        const <String, dynamic>{},
      );
      return FlatScan.alreadyNeighbor;
    }
    pending[code.key] = code;
    _pendingAt[code.key] = _now();
    await _save();
    // One knock, whichever way it reaches them: they are asked once. With
    // our own mailbox doors, so the answer can wait for us there too.
    final FlatMailDoor? reply = (await _currentKeys())?.mailDoor(
      _slotHolders.keys,
      withKem: true,
    );
    final Map<String, dynamic> body = <String, dynamic>{
      'door': code.door,
      'kid': _newId(16),
      'ra': ?reply?.toJson(),
    };
    // From our door: the knock names no one of us either. It carries our
    // card only ("Co widzi pukający"): the full profile goes once they let
    // us in.
    await _sendFromDoor(
      code.inbox,
      await _envelope(FlatTypes.hello, code.key, <String, dynamic>{
        ...body,
        ...(await _ownCard()).toJson(),
      }),
      life: kDoorRetryLife,
      acked: false,
    );
    final FlatMailDoor? mail = code.mail;
    if (mail != null && pending.containsKey(code.key)) {
      // For the other residents' phones, and for when nobody is home: the
      // friends at their mailbox doors keep it sealed (the card without
      // the photo).
      await _sendSealed(
        mail,
        await _envelope(FlatTypes.hello, code.key, <String, dynamic>{
          ...body,
          ...(await _ownCard(small: true)).toJson(),
        }),
        about: code.key,
        doorToken: code.door,
      );
    }
    return FlatScan.sent;
  }

  /// This household's card ([FlatDoorView]): what it shows a flat before
  /// either side lets the other in. [small]: without the photo, and the
  /// invitations only when they are short, to fit a sealed knock.
  Future<FlatCard> _ownCard({bool small = false}) async {
    final FlatProfile p = _profile!;
    final FlatDoorView v = _view;
    final bool items =
        v.items && (!small || jsonEncode(p.items).length <= 8000);
    final FlatProfile shown = await FlatProfile(
      key: p.key,
      name: p.name,
      place: p.place,
      about: v.about ? p.about : '',
      items: items ? p.items : const <FlatItem>[],
      photo: v.photo && !small ? p.photo : '',
      members: const <String, String>{},
      rev: 0,
    ).signedWith(_pair!);
    return FlatCard(
      profile: shown,
      names: v.names
          ? <String>[
              for (final String r in p.members.keys)
                if (residentName(r).isNotEmpty) residentName(r),
            ]
          : const <String>[],
      note: v.note,
    );
  }

  /// Our profile as it travels through friends' phones: without the photo,
  /// and at revision 0, so the full profile replaces it once it arrives.
  Future<FlatProfile> _mailProfile() =>
      _profile!.copyWith(photo: '', rev: 0).signedWith(_pair!);

  /// Leaves [envelope] sealed at the mailbox doors of [to] (a flat whose
  /// phones may be offline), from our door, naming our door for the answer.
  /// Keyed also with the [doorToken] of their sticker (a knock) or their
  /// hybrid key (an answer: their knock carried it), so it stays shut to a
  /// quantum computer ([FlatSeal]).
  Future<void> _sendSealed(
    FlatMailDoor to,
    Map<String, dynamic> envelope, {
    String about = '',
    String? doorToken,
  }) async {
    final String? door = _ownDoor;
    if (door == null) {
      return;
    }
    final Map<String, dynamic>? box = await FlatSeal.seal(
      <String, dynamic>{'e': envelope, 'a': door},
      to.seal,
      doorToken: doorToken,
      kem: to.kem,
    );
    if (box == null || (box['c'] as String).length > kMaxSealedChars) {
      return;
    }
    for (final String slot in to.slots) {
      await _sendFromDoor(
        slot,
        <String, dynamic>{'type': FlatTypes.seal, 'd': slot, ...box},
        life: kSealRetryLife,
        acked: false,
        about: about,
      );
    }
  }

  /// A neighbour household with two different new keys ([keyRival]): the
  /// one whose door code was scanned ([key]) stays, the other goes.
  Future<void> _settleByDoor(String key) async {
    for (final FlatKeySwitch s in _switches.values.toList()) {
      final FlatProfile? rival = s.rival;
      if (rival == null) {
        continue;
      }
      if (s.newKey == key) {
        await keepCurrentKey(key);
        return;
      }
      final NeighborFlat? current = _neighbors[s.newKey];
      if (rival.key != key || current == null || _neighbors.containsKey(key)) {
        continue;
      }
      _moveNeighbor(current, rival);
      s
        ..newKey = rival.key
        ..removed = s.rivalRemoved
        ..by = s.rivalBy
        ..rival = null
        ..rivalRemoved = <String>{}
        ..rivalBy = '';
      await _save();
      await _syncHouse();
      return;
    }
  }

  Future<void> removeNeighbor(String key) async {
    _neighbors.remove(key);
    _removed[key] = _now();
    _switches.removeWhere((String _, FlatKeySwitch s) => s.newKey == key);
    await _save();
    await _syncHouse();
  }

  Future<void> setFollowing(String key, bool on) async {
    final NeighborFlat? f = _neighbors[key];
    if (f == null) {
      return;
    }
    f.following = on;
    await _save();
  }

  /// Asks a neighbour for their current profile.
  Future<void> refresh(String key) async {
    final NeighborFlat? f = _neighbors[key];
    if (f != null) {
      await _sendToDoors(
        f.profile.doors,
        FlatTypes.get,
        key,
        const <String, dynamic>{},
      );
    }
  }

  /// Writes to the flat [key]. With [itemId] the message belongs to the
  /// small chat of that invitation.
  Future<bool> sendMessage(String key, String text, {String? itemId}) async {
    final NeighborFlat? f = _neighbors[key];
    if (f == null || text.trim().isEmpty || !hasFlat) {
      return false;
    }
    final String about =
        itemId != null &&
            (f.profile.item(itemId) != null || _profile?.item(itemId) != null)
        ? itemId
        : '';
    final FlatMessage m = FlatMessage(
      id: _newId(16),
      flat: key,
      mine: true,
      text: _clip(text, 2000),
      at: _now(),
      // The resident's first name in the flat, never the account's name.
      by: myName,
      item: about,
    );
    _messages[m.id] = m;
    _lastRead[key] = m.at;
    await _save();
    await _sendToDoors(
      f.profile.doors,
      FlatTypes.message,
      key,
      <String, dynamic>{
        'id': m.id,
        't': m.text,
        'at': m.at,
        'by': m.by,
        if (about.isNotEmpty) 'it': about,
      },
    );
    await _syncHouse();
    return true;
  }

  /// Signs up for a neighbour's invitation ([count] places, 0 = cancel).
  Future<bool> signUp(String key, String itemId, int count) async {
    final NeighborFlat? f = _neighbors[key];
    final FlatItem? item = f?.profile.item(itemId);
    if (f == null ||
        item == null ||
        item.kind != FlatItemKind.invite ||
        !hasFlat) {
      return false;
    }
    _mine['$key|$itemId'] = FlatSignup(
      flat: key,
      name: _profile!.name,
      count: count.clamp(0, 20),
      at: _now(),
    );
    await _save();
    await _sendToDoors(
      f.profile.doors,
      FlatTypes.signup,
      key,
      <String, dynamic>{'i': itemId, 'c': count.clamp(0, 20)},
    );
    await _syncHouse();
    return true;
  }

  // ---- nearby (Bluetooth) ----

  /// The Bluetooth "wave" that carries one of our invitations to people
  /// around. `null` when there is nothing to send. Its door code has a
  /// token of its own that works [kNearbyCodeLife]: whoever happened to be
  /// nearby can knock until then, never with the sticker's permanent code.
  Future<Map<String, dynamic>?> nearbyWave(String itemId) async {
    final FlatDoorCode? sticker = doorCode;
    final FlatItem? item = _profile?.item(itemId);
    if (sticker == null || item == null) {
      return null;
    }
    final int now = _now();
    _tempDoors.removeWhere((String _, int until) => until <= now);
    while (_tempDoors.length >= kMaxTempDoors) {
      _tempDoors.remove(_tempDoors.keys.first);
    }
    final String token = _newDoor();
    final int until = now + kNearbyCodeLife.inMilliseconds;
    _tempDoors[token] = until;
    await _save();
    await _syncHouse();
    final FlatDoorCode code = FlatDoorCode(
      key: sticker.key,
      door: token,
      inbox: sticker.inbox,
      name: sticker.name,
      mail: sticker.mail,
      until: until,
    );
    final String when = item.at == null ? '' : ' (${_shortDate(item.at!)})';
    return <String, dynamic>{
      'v': kFlatWaveVersion,
      'q': code.toQr(),
      'm': _clip('${code.name}: ${item.text}$when', 180),
    };
  }

  /// Whether [token] opens the door now: the sticker's, or a short-lived
  /// one of an invitation nearby that is not over.
  bool _doorOpensWith(Object? token) =>
      token is String &&
      token.isNotEmpty &&
      (token == _door || (_tempDoors[token] ?? 0) > _now());

  /// The tokens that open the door now (the sticker's first).
  List<String> get _liveDoorTokens {
    final int now = _now();
    return <String>[
      if (_door.isNotEmpty) _door,
      for (final MapEntry<String, int> e in _tempDoors.entries)
        if (e.value > now) e.key,
    ];
  }

  /// The short-lived door tokens that work now (token → until when), for
  /// the locked background service.
  Map<String, int> get tempDoorTokens {
    final int now = _now();
    return <String, int>{
      for (final MapEntry<String, int> e in _tempDoors.entries)
        if (e.value > now) e.key: e.value,
    };
  }

  static String _shortDate(int millis) =>
      ZenFormat.dayMonthTime(DateTime.fromMillisecondsSinceEpoch(millis));

  /// Someone nearby passed us an invitation.
  Future<void> onNearbyWave(Map<dynamic, dynamic> json) async {
    if (json['v'] != kFlatWaveVersion ||
        json['q'] is! String ||
        json['m'] is! String) {
      return;
    }
    final FlatDoorCode? code = FlatDoorCode.parse(json['q'] as String);
    final int? until = code?.until;
    if (code == null ||
        code.key == _profile?.key ||
        until == null ||
        until <= _now() ||
        until - _now() > kNearbyCodeLife.inMilliseconds) {
      // Only a short-lived code comes nearby.
      return;
    }
    final String text = _clip(json['m'] as String, 200);
    if (_nearby.any(
      (NearbyFlatInvite i) => i.door.key == code.key && i.text == text,
    )) {
      return;
    }
    _nearby.add(NearbyFlatInvite(door: code, text: text, at: _now()));
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-near-${code.key.hashCode}-${text.hashCode}',
        title: t('Zaproszenie w pobliżu'),
        body: text,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-near',
      ),
    );
  }

  Future<void> dismissNearby(NearbyFlatInvite invite) async {
    _nearby.remove(invite);
    await _save();
  }

  // ---- receiving ----

  Future<bool> handle(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if (type is! String || !FlatTypes.all.contains(type)) {
      return Future<bool>.value(false);
    }
    if (frame.door != FlatTypes.atDoor.contains(type)) {
      // Between flats only through the doors (the bridge and the runtime
      // let nothing else in there), between housemates and friends only
      // phone to phone.
      return Future<bool>.value(false);
    }
    final Completer<bool> done = Completer<bool>();
    _queue = _queue.then((_) async {
      try {
        await _handle(type, frame);
      } on Object catch (error, stack) {
        logZenError('Sąsiedzi', error, stack);
      }
      done.complete(true);
      if (_ownDoorStale) {
        // A new door code from a housemate gave this phone's door a new
        // address: the profile names it (after this frame, not inside it).
        _later(_syncOwnDoor);
      }
    });
    return done.future;
  }

  Future<void> _handle(
    String type,
    SignalTransportFrame frame, {
    int? heldAt,
  }) async {
    final Map<String, dynamic> p = frame.payload;
    switch (type) {
      case FlatTypes.ack:
        _onAck(_n(frame.from), p);
        return;
      case FlatTypes.seal:
        await _onSealed(frame);
        return;
      case FlatTypes.slot:
        await _onSlot(_n(frame.from), p);
        return;
      case FlatTypes.held:
        await _onHeld(_n(frame.from), p);
        return;
    }
    if (type == FlatTypes.join && p['step'] is String) {
      await _onJoinStep(_n(frame.from), p);
      return;
    }
    final Object? from = p['f'];
    final Object? to = p['to'];
    final Object? body = p['b'];
    final Object? sig = p['s'];
    if (from is! String || to is! String || body is! Map || sig is! String) {
      return;
    }
    final bool ok = await verifyLedgerSignature(
      publicKey: from,
      message: canonicalJsonBytes(<String, dynamic>{
        'type': type,
        'f': from,
        'to': to,
        'b': body,
      }),
      signature: sig,
    );
    if (!ok) {
      return;
    }
    final String sender = _n(frame.from);
    final Map<String, dynamic> b = Map<String, dynamic>.from(body);
    final String? ownKey = _pair?.id;
    if (type == FlatTypes.rekey &&
        ownKey != null &&
        from == to &&
        to == _oldKey &&
        to != ownKey) {
      // A housemate made a new key at the same moment as this phone.
      await _onRekeyRace(sender, b);
      return;
    }
    if (ownKey == null || to != ownKey) {
      return;
    }
    if (from == ownKey) {
      switch (type) {
        case FlatTypes.house:
          await _onHouse(sender, b);
        case FlatTypes.join:
          await _onJoin(sender, b);
        case FlatTypes.leave:
          await _onLeave(sender, b);
        case FlatTypes.kick:
          await _onKick(sender, b);
        case FlatTypes.rekey:
          await _onRekey(sender, b);
      }
      return;
    }
    if (_profile == null) {
      return;
    }
    if (frame.door &&
        type != FlatTypes.hello &&
        type != FlatTypes.reveal &&
        (_neighbors.containsKey(from) ||
            pending.containsKey(from) ||
            _switches.containsKey(from))) {
      // Door to door: their phone stops retrying it. Only flats we know
      // hear back, so nobody learns from the sticker alone whether the
      // phone behind the door is online.
      _ack(sender, p[kReliableIdKey]);
    }
    switch (type) {
      case FlatTypes.hello:
        await _onHello(
          from,
          sender,
          b,
          retryId: p[kReliableIdKey],
          heldAt: heldAt,
        );
      case FlatTypes.nope:
        final FlatDoorCode? code = pending.remove(from);
        if (code != null) {
          staleDoors[from] = code.name;
          notifyListeners();
        }
      case FlatTypes.profile:
        await _onProfile(from, b);
      case FlatTypes.get:
        final NeighborFlat? f = _neighbors[from];
        if (f != null) {
          await _pushProfile(to: <NeighborFlat>[f]);
        }
      case FlatTypes.message:
        await _onMessage(from, b);
      case FlatTypes.signup:
        await _onSignup(from, b);
      case FlatTypes.signupAck:
        await _onSignupAck(from, b);
      case FlatTypes.moved:
        await _onMoved(from);
      case FlatTypes.newKey:
        await _onNewKey(from, sender, b);
      case FlatTypes.reveal:
        await _onReveal(from, sender, b);
      case FlatTypes.card:
        await _onCard(from, b);
    }
  }

  Future<void> _onMoved(String from) async {
    final NeighborFlat? f = _neighbors.remove(from);
    if (f == null) {
      return;
    }
    _removed[from] = _now();
    _messages.removeWhere((String _, FlatMessage m) => m.flat == from);
    await _save();
    await _syncHouse();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-moved-${from.hashCode}',
        title: t('{name} wyprowadzili się', {'name': f.profile.name}),
        body: f.profile.place.isEmpty
            ? t('Znikają z listy sąsiadów.')
            : t('Z {place}. Nowi lokatorzy założą własny profil.', {
                'place': f.profile.place,
              }),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-moved',
      ),
    );
  }

  Future<FlatProfile?> _verifiedProfile(String key, Object? json) async {
    final FlatProfile? p = FlatProfile.fromJson(json);
    if (p == null || p.key != key || !await p.verify()) {
      return null;
    }
    return p;
  }

  /// The card in a knock or a door's answer [b] of the flat [key], when
  /// its signature holds.
  Future<FlatCard?> _verifiedCard(String key, Map<String, dynamic> b) async {
    final FlatCard? card = FlatCard.fromJson(b);
    return card == null || card.key != key || !await card.profile.verify()
        ? null
        : card;
  }

  Future<void> _onHello(
    String from,
    String sender,
    Map<String, dynamic> b, {
    Object? retryId,
    int? heldAt,
  }) async {
    final FlatCard? card = await _verifiedCard(from, b);
    if (card == null || !_doorOpensWith(b['door'])) {
      // Anyone can knock at the door address; an answer would only tell
      // them the door's phone is online. (An old sticker's door has a key
      // that no longer runs, so its knocks reach nobody anyway.)
      return;
    }
    // The knocker's phone retries the same knock, and sends it to the door
    // and to the mailbox doors at once; one already let in, refused or
    // expired does not ask again.
    final int now = _now();
    final Object? kid = b['kid'];
    final String id = kid is String && kid.isNotEmpty && kid.length <= 40
        ? kid
        : '';
    final String? once = id.isNotEmpty
        ? '$from|$id'
        : retryId is String && retryId.isNotEmpty
        ? '$sender|$retryId'
        : null;
    if (once != null) {
      if ((_knocksSeen[once] ?? 0) > now) {
        return;
      }
      _knocksSeen.remove(once);
      _knocksSeen[once] = now + kKnockMemory.inMilliseconds;
      while (_knocksSeen.length > 500) {
        _knocksSeen.remove(_knocksSeen.keys.first);
      }
    }
    final NeighborFlat? known = _neighbors[from];
    if (known != null) {
      // Neighbours already: they have our profile, so answering tells them
      // nothing new.
      known.scannedUs = true;
      await _save();
      await _pushProfile(to: <NeighborFlat>[known]);
      await _syncHouse();
      return;
    }
    // A knock friends held waits from when they took it.
    final int at = min(heldAt ?? now, now);
    final FlatKnockDecision? decided = _decided[from];
    if (now - at >= kKnockLife.inMilliseconds ||
        (decided != null && id.isNotEmpty && decided.id == id)) {
      // Too old, or answered on a housemate's phone already.
      await _save();
      return;
    }
    final FlatKnock? had = _knocks[from];
    final FlatKnock? waiting =
        had != null && now - had.at < kKnockLife.inMilliseconds ? had : null;
    final bool fresh = waiting == null;
    // The copy that came straight to a door carries the photo; a sealed
    // copy of the same knock does not replace it.
    final FlatCard shown =
        waiting != null &&
            waiting.id == id &&
            waiting.profile.photo.isNotEmpty &&
            card.profile.photo.isEmpty
        ? waiting.card
        : card;
    final FlatKnock knock = FlatKnock(
      card: shown,
      sender: sender,
      at: waiting?.at ?? at,
      id: id,
      reply: FlatMailDoor.fromJson(b['ra']) ?? waiting?.reply,
    );
    _knocks[from] = knock;
    _trimKnocks();
    await _save();
    if (!fresh || !_knocks.containsKey(from)) {
      return;
    }
    await _ringKnock(knock);
    // Every resident's phone gets it, and rings: whoever is at home opens.
    await _syncHouse(ring: true);
    await _answerWithCard(knock, sealed: heldAt != null);
  }

  /// "{name} puka do drzwi", within [_mayRingKnock]; tapping it opens the
  /// knocks.
  Future<void> _ringKnock(FlatKnock k) async {
    final int now = _now();
    if (!_mayRingKnock(k.key, now)) {
      return;
    }
    await host.notify(
      RuntimeSystemNotification(
        // One per knocker: a knock again replaces it instead of piling up.
        id: 'flat-knock-${k.key.hashCode}',
        title: t('{name} puka do drzwi', {'name': k.profile.name}),
        body: t('Otwórz Sąsiadów, żeby ich wpuścić albo odmówić.'),
        createdAtMillis: now,
        category: RuntimeSystemNotificationCategory.social,
        // Tapping it opens the knocks.
        routeKey: buildFlatKnocksRouteKey(),
        slotKey: 'flat-knock:${k.key}',
      ),
    );
  }

  /// A knock answered (here or on a housemate's phone) stops ringing.
  Future<void> _dismissKnock(String flat) async {
    try {
      await dismissNotification?.call('flat-knock:$flat');
    } on Object catch (error) {
      logZenWarning('Sąsiedzi: powiadomienie o pukaniu: $error');
    }
  }

  /// Shows the flat that knocked ([k]) the household's card, when the
  /// residents chose to show knockers more than the name on the sticker
  /// ([FlatDoorView]); otherwise the door stays silent. [sealed]: the knock
  /// came while this phone was offline, so the card waits at the knocker's
  /// mailbox doors too.
  Future<void> _answerWithCard(FlatKnock k, {required bool sealed}) async {
    if (_view.bare || !hasFlat) {
      return;
    }
    await _sendToDoors(
      <String>[k.sender],
      FlatTypes.card,
      k.key,
      (await _ownCard()).toJson(),
    );
    final FlatMailDoor? reply = k.reply;
    if (sealed && reply != null) {
      await _sendSealed(
        reply,
        await _envelope(
          FlatTypes.card,
          k.key,
          (await _ownCard(small: true)).toJson(),
        ),
      );
    }
  }

  /// A door we knocked at shows us its household's card while we wait.
  Future<void> _onCard(String from, Map<String, dynamic> b) async {
    if (!pending.containsKey(from)) {
      return;
    }
    final FlatCard? card = await _verifiedCard(from, b);
    if (card == null) {
      return;
    }
    _cards[from] = card;
    await _save();
  }

  /// Whether a knock from [flat] may ring now: once an hour per knocker and
  /// [kKnockRingsPerHour] an hour in all, so a flood of knocks (new flat
  /// keys cost nothing) cannot keep the phone ringing.
  bool _mayRingKnock(String flat, int now) {
    const int hour = 3600 * 1000;
    _knockRings.removeWhere(((int, String) r) => now - r.$1 >= hour);
    if (_knockRings.length >= kKnockRingsPerHour ||
        _knockRings.any(((int, String) r) => r.$2 == flat)) {
      return false;
    }
    _knockRings.add((now, flat));
    return true;
  }

  /// Records this phone's answer to the knock [k]: the housemates close it
  /// too, and its retries do not ask again.
  void _decide(FlatKnock k, {required bool ok}) {
    final int now = max(_now(), (_decided[k.key]?.at ?? 0) + 1);
    _decided[k.key] = FlatKnockDecision(flat: k.key, id: k.id, at: now, ok: ok);
    if (k.id.isNotEmpty) {
      _knocksSeen['${k.key}|${k.id}'] = now + kKnockMemory.inMilliseconds;
    }
  }

  /// Lets in the flat that knocked ([knocks]): only now do both flats
  /// exchange profiles. False when the knock is gone (expired, or another
  /// answer came first, here or on a housemate's phone).
  Future<bool> acceptKnock(String key) async {
    final FlatKnock? k = _knocks.remove(key);
    if (k == null || _now() - k.at >= kKnockLife.inMilliseconds) {
      await _save();
      return false;
    }
    _decide(k, ok: true);
    final NeighborFlat f = _addNeighbor(k.profile)..scannedUs = true;
    _pinResidents(f, k.profile);
    await _save();
    await _dismissKnock(key);
    final FlatProfile? p = _profile;
    if (p != null) {
      // To the door that knocked: their card names none of their doors.
      // Their full profile comes back from there.
      await _sendToDoors(
        <String>[...f.profile.doors, k.sender],
        FlatTypes.profile,
        f.key,
        <String, dynamic>{'p': p.toJson()},
      );
    }
    final FlatMailDoor? reply = k.reply;
    if (reply != null && _profile != null) {
      // Their phone may be offline by now: the answer waits at their
      // mailbox doors too.
      await _sendSealed(
        reply,
        await _envelope(FlatTypes.profile, f.key, <String, dynamic>{
          'p': (await _mailProfile()).toJson(),
        }),
      );
    }
    await _syncHouse();
    return true;
  }

  /// Leaves the knock unanswered: the knocker learns nothing, not even
  /// that someone said no. The housemates' phones close it too.
  Future<void> rejectKnock(String key) async {
    final FlatKnock? k = _knocks.remove(key);
    if (k == null) {
      return;
    }
    _decide(k, ok: false);
    await _save();
    await _dismissKnock(key);
    await _syncHouse();
  }

  // ---- mailbox doors (flat_door_mail.dart) ----

  /// A sealed knock came to a mailbox door this phone runs for a friend:
  /// passed on to the friend unread, within the door's caps.
  Future<void> _onSealed(SignalTransportFrame frame) async {
    final Map<String, dynamic> p = frame.payload;
    final Object? d = p['d'];
    if (d is! String || !FlatSeal.looksSealed(p)) {
      return;
    }
    final String address = _n(d);
    if (address == _ownDoor) {
      // The sticker lists this phone's door among its mailbox doors (a
      // housemate printed it): a knock for the household.
      await _onOwnSealed(p);
      return;
    }
    HostedDoor? door;
    for (final HostedDoor h in _hosted.values) {
      if (h.address == address) {
        door = h;
      }
    }
    if (door == null || !host.isFriend(door.owner)) {
      return;
    }
    final int now = _now();
    final String sender = _n(frame.from);
    // The knocker's phone retries until it gives up ([kSealRetryLife]):
    // the door never answers, or it would say who runs it.
    final Object? rid = p[kReliableIdKey];
    if (rid is String && rid.isNotEmpty && rid.length <= 128) {
      final String seen = flatMailHash('$address|$sender|$rid');
      if ((_heldSeen[seen] ?? 0) > now) {
        return;
      }
      _heldSeen[seen] = now + kSealRetryLife.inMilliseconds;
      while (_heldSeen.length > 500) {
        _heldSeen.remove(_heldSeen.keys.first);
      }
    }
    final int life = kHeldKnockLife.inMilliseconds;
    door.knocks.removeWhere((HeldKnock k) => now - k.at >= life);
    final String who = HeldKnock.hashOf(
      address,
      PeerShareCodec.identityKeyForAddress(sender),
    );
    const int day = Duration.millisecondsPerDay;
    if (door.knocks.length >= kHeldPerDoor ||
        door.knocks.where((HeldKnock k) => now - k.at < day).length >=
            kHeldPerDoorPerDay ||
        door.knocks.where((HeldKnock k) => k.who == who).length >=
            kHeldPerKnocker) {
      await _save();
      return;
    }
    door.knocks.add(HeldKnock(at: now, who: who));
    await _save();
    // Through the relay layer: straight to the friend, again as soon as
    // they show up, for as long as a knock waits.
    await _send(door.owner, <String, dynamic>{
      'type': FlatTypes.held,
      'd': address,
      'x': p['x'],
      'n': p['n'],
      'c': p['c'],
      'k': p['k'],
      // The inner layer's marks (flat_door_mail.dart): without them the box
      // does not open.
      'p': ?p['p'],
      'q': ?p['q'],
      'at': now,
      kReliableTtlKey: life,
    });
  }

  /// A friend whose mailbox this phone keeps hands over one of its mailbox
  /// doors (or takes it back).
  Future<void> _onSlot(String sender, Map<String, dynamic> p) async {
    final Object? seed = p['s'];
    final Object? at = p['at'];
    if (seed is! String || at is! int) {
      return;
    }
    final HostedDoor? had = _hosted[sender];
    if (had != null && at <= had.at) {
      return;
    }
    // Taking a door back is fine from a former friend too; running one
    // only for a friend.
    if (seed.isNotEmpty && !host.isFriend(sender)) {
      return;
    }
    if (seed.isEmpty) {
      if (had != null) {
        _hosted.remove(sender);
        await _save();
      }
      return;
    }
    final String? address = await doorAddressForSeed(seed);
    if (address == null || seed == _doorKey) {
      return;
    }
    if (had == null && _hosted.length >= kMaxHostedDoors) {
      // Room only by dropping doors of people who are friends no more.
      _hosted.removeWhere(
        (String owner, HostedDoor _) => !host.isFriend(owner),
      );
      if (_hosted.length >= kMaxHostedDoors) {
        return;
      }
    }
    _hosted[sender] = HostedDoor(
      owner: sender,
      seed: seed,
      address: address,
      at: at,
    );
    await _save();
  }

  /// A sealed knock at this phone's own door, from a sticker a housemate
  /// printed: handled as if it had come to the door itself.
  Future<void> _onOwnSealed(Map<String, dynamic> p) async {
    final (String, Map<String, dynamic>, String)? open = await _openSealed(p);
    if (open == null || open.$1 != FlatTypes.hello) {
      return;
    }
    await _handle(
      open.$1,
      SignalTransportFrame(
        from: open.$3,
        payload: open.$2,
        receivedAtMillis: _now(),
        door: true,
      ),
    );
  }

  /// Opens what knockers (or flats answering our knock) sealed for this
  /// household: its type, the frame inside and the door that sent it; `null`
  /// when it does not open (sealed for another household, or for an old
  /// door code) or is not a knock, an answer or a card.
  Future<(String, Map<String, dynamic>, String)?> _openSealed(
    Map<String, dynamic> p,
  ) async {
    if (!hasFlat) {
      return null;
    }
    // Sealed for the current door code: an old sticker's knocks stay shut.
    final FlatDoorKeys? keys = await _currentKeys();
    Map<String, dynamic>? box;
    if (keys != null) {
      // A knock with an invitation's short-lived code is keyed with its
      // token.
      final List<String> tokens = p['p'] == 1
          ? _liveDoorTokens
          : <String>[_door];
      for (final String token in tokens) {
        box = await FlatSeal.open(
          p,
          keys.seal,
          doorToken: token,
          kemSeed: keys.kemSeed,
        );
        if (box != null) {
          break;
        }
      }
    }
    final Object? e = box?['e'];
    if (box == null || e is! Map) {
      return null;
    }
    final Map<String, dynamic> inner = Map<String, dynamic>.from(e);
    final Object? type = inner['type'];
    if (type != FlatTypes.hello &&
        type != FlatTypes.profile &&
        type != FlatTypes.card) {
      return null;
    }
    // The knocker's (or the answering flat's) door, as it named it.
    final Object? a = box['a'];
    if (a is! String || !isRoutablePeerAddress(a)) {
      return null;
    }
    return (type as String, inner, a);
  }

  /// A friend passes on a sealed knock (or the answer to ours) one of our
  /// mailbox doors took while this phone was offline.
  Future<void> _onHeld(String sender, Map<String, dynamic> p) async {
    final Object? at = p['at'];
    final int now = _now();
    if (at is! int ||
        !host.isFriend(sender) ||
        now - at >= kHeldKnockLife.inMilliseconds) {
      return;
    }
    final (String, Map<String, dynamic>, String)? open = await _openSealed(p);
    if (open == null) {
      return;
    }
    await _handle(
      open.$1,
      SignalTransportFrame(
        from: open.$3,
        payload: open.$2,
        receivedAtMillis: now,
        door: true,
      ),
      heldAt: min(at, now),
    );
  }

  NeighborFlat _addNeighbor(FlatProfile p) {
    _removed.remove(p.key);
    final NeighborFlat? had = _neighbors[p.key];
    if (had != null) {
      if (p.newerThan(had.profile)) {
        had.profile = p;
      }
      return had;
    }
    return _neighbors[p.key] = NeighborFlat(
      profile: p,
      addedAt: _now(),
      seenItems: p.items.map((FlatItem i) => i.id).toSet(),
    );
  }

  Future<void> _onProfile(String from, Map<String, dynamic> b) async {
    final FlatProfile? theirs = await _verifiedProfile(from, b['p']);
    if (theirs == null) {
      return;
    }
    final bool wasPending = pending.remove(from) != null;
    _cards.remove(from);
    if (wasPending) {
      // Let in: the knock (and its sealed copies) is not retried any more.
      _doorOut.removeWhere(
        (String _, _DoorSend d) =>
            (d.payload['type'] == FlatTypes.hello && d.payload['to'] == from) ||
            d.about == from,
      );
    }
    NeighborFlat? f = _neighbors[from];
    if (f == null && !wasPending) {
      return;
    }
    if (f == null) {
      f = _addNeighbor(theirs)..weScanned = true;
      _pinResidents(f, theirs);
      await _save();
      await _syncHouse();
      // They may have only our card (through their friends): the full
      // profile follows (not waited for: their answer may come back here).
      unawaited(_pushProfile(to: <NeighborFlat>[f]));
      return;
    }
    if (wasPending && !f.weScanned) {
      f.weScanned = true;
    }
    final bool pinned = _pinResidents(f, theirs);
    if (!theirs.newerThan(f.profile)) {
      if (wasPending || pinned) {
        await _save();
      }
      return;
    }
    f.profile = theirs;
    final List<FlatItem> news = <FlatItem>[
      for (final FlatItem i in theirs.items)
        if (!f.seenItems.contains(i.id)) i,
    ];
    f.seenItems.addAll(theirs.items.map((FlatItem i) => i.id));
    await _save();
    // Sent only because one of their doors moved: no news from it.
    if (f.following && b['q'] != true) {
      for (final FlatItem i in news) {
        await host.notify(
          RuntimeSystemNotification(
            id: 'flat-item-${i.id}',
            title: switch (i.kind) {
              FlatItemKind.invite => t('{name} zapraszają', {
                'name': theirs.name,
              }),
              FlatItemKind.offer => t('{name} oferują', {'name': theirs.name}),
              FlatItemKind.need => t('{name} szukają pomocy', {
                'name': theirs.name,
              }),
            },
            body: i.at == null ? i.text : '${i.text} — ${_shortDate(i.at!)}',
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'flat-item:$from',
          ),
        );
      }
    }
  }

  Future<void> _onMessage(String from, Map<String, dynamic> b) async {
    final NeighborFlat? f = _neighbors[from];
    final Object? id = b['id'];
    final Object? text = b['t'];
    if (f == null ||
        id is! String ||
        id.length > 40 ||
        text is! String ||
        _messages.containsKey(id)) {
      return;
    }
    final Object? by = b['by'];
    final FlatMessage m = FlatMessage(
      id: id,
      flat: from,
      mine: false,
      text: text.length > 2000 ? text.substring(0, 2000) : text,
      at: _now(),
      by: by is String ? _clip(by, 40) : '',
      item: b['it'] is String && (b['it'] as String).length <= 40
          ? b['it'] as String
          : '',
    );
    _messages[id] = m;
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-msg-$id',
        title: f.profile.name,
        body: m.by.isEmpty ? m.text : '${m.by}: ${m.text}',
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-msg:$from',
      ),
    );
  }

  Future<void> _onSignup(String from, Map<String, dynamic> b) async {
    final NeighborFlat? f = _neighbors[from];
    final Object? itemId = b['i'];
    final Object? c = b['c'];
    final FlatItem? item = itemId is String ? _profile!.item(itemId) : null;
    if (f == null ||
        item == null ||
        item.kind != FlatItemKind.invite ||
        c is! int) {
      return;
    }
    final int count = c.clamp(0, 20);
    final Map<String, FlatSignup> list = _signups[item.id] ??=
        <String, FlatSignup>{};
    final int before = list[from]?.count ?? 0;
    final int othersTaken = item.taken - before;
    final bool accepted =
        count == 0 || item.seats == 0 || othersTaken + count <= item.seats;
    if (accepted) {
      list[from] = FlatSignup(
        flat: from,
        name: f.profile.name,
        count: count,
        at: _now(),
      );
    }
    await _sendToDoors(
      f.profile.doors,
      FlatTypes.signupAck,
      from,
      <String, dynamic>{
        'i': item.id,
        'c': accepted ? count : before,
        'ok': accepted,
      },
    );
    if (!accepted) {
      return;
    }
    await _changeProfile(
      (FlatProfile p) => p.copyWith(
        items: <FlatItem>[
          for (final FlatItem i in p.items)
            i.id == item.id ? i.copyWith(taken: othersTaken + count) : i,
        ],
      ),
    );
    // The one who signed up gets the new count even when not in audience.
    if (!audience.contains(f)) {
      await _pushProfile(to: <NeighborFlat>[f]);
    }
    if (count > before) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-signup-${item.id}-${from.hashCode}-$count',
          title: t('{name} przyjdą', {'name': f.profile.name}),
          body: tn(
            count,
            one: '{text}: {n} osoba',
            few: '{text}: {n} osoby',
            many: '{text}: {n} osób',
            args: <String, Object?>{'text': item.text},
          ),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-signup:${item.id}',
        ),
      );
    }
  }

  Future<void> _onSignupAck(String from, Map<String, dynamic> b) async {
    final Object? itemId = b['i'];
    final Object? c = b['c'];
    final NeighborFlat? f = _neighbors[from];
    if (f == null || itemId is! String || c is! int) {
      return;
    }
    _mine['$from|$itemId'] = FlatSignup(
      flat: from,
      name: _profile!.name,
      count: c,
      at: _now(),
    );
    await _save();
    await _syncHouse();
    if (b['ok'] != true) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-full-$itemId',
          title: t('Brak miejsc'),
          body:
              '${f.profile.name}: '
              '${f.profile.item(itemId)?.text ?? t('zaproszenie')}',
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-full:$itemId',
        ),
      );
    }
  }

  // ---- housemates ----

  Future<void> _onJoin(String sender, Map<String, dynamic> b) async {
    final Object? a = b['a'];
    final Object? rk = b['rk'];
    final FlatProfile? p = _profile;
    if (p == null ||
        a is! String ||
        _n(a) != sender ||
        unb64(rk, length: 32) == null) {
      return;
    }
    final String resident = rk as String;
    final String? phone = _phones[resident];
    if ((!p.members.containsKey(resident) &&
            (_approved[resident] ?? 0) <= _now()) ||
        (phone != null &&
            phone != sender &&
            // The resident's account came back on a new phone (signed with
            // the resident's own key).
            !(p.members.containsKey(resident) &&
                b['rs'] is String &&
                await verifyLedgerSignature(
                  publicKey: resident,
                  message: flatMovedBytes(p.key, resident, sender),
                  signature: b['rs'] as String,
                ))) ||
        (!p.members.containsKey(resident) &&
            p.members.length >= FlatProfile.maxMembers)) {
      // A resident key already someone else's, or no room.
      return;
    }
    _phones[resident] = sender;
    _approved.remove(resident);
    final Object? name = b['n'];
    if (name is String &&
        name.trim().isNotEmpty &&
        (_names[resident] ?? '').isEmpty) {
      _names[resident] = _clip(name, 40);
    }
    if (!p.members.containsKey(resident)) {
      // Their door is named once it runs (they put it in themselves).
      await _changeProfile(
        (FlatProfile p) =>
            p.copyWith(members: <String, String>{...p.members, resident: ''}),
      );
    } else {
      await _save();
      await _syncHouse(to: <String>[sender]);
    }
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-join-${sender.hashCode}',
        title: t('Nowy domownik'),
        body: t('Kolejny telefon dołączył do „{name}”.', {'name': p.name}),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-join',
      ),
    );
  }

  /// The resident whose phone is [phone] (resident key), or `null`.
  String? _residentOf(String phone) {
    for (final MapEntry<String, String> e in _phones.entries) {
      if (e.value == phone && (_profile?.members.containsKey(e.key) ?? false)) {
        return e.key;
      }
    }
    return null;
  }

  /// A housemate's phone left ("Opuść"): it still holds the household's
  /// key, so the household gets a new one without it
  /// ([_maybeRekeyAfterLeave]).
  Future<void> _onLeave(String sender, Map<String, dynamic> b) async {
    final Object? a = b['a'];
    final Object? consent = b['ls'];
    final FlatProfile? p = _profile;
    if (p == null ||
        a is! String ||
        consent is! String ||
        a == _resident?.id ||
        _phones[a] != sender ||
        !p.members.containsKey(a) ||
        !await verifyLedgerSignature(
          publicKey: a,
          message: flatLeaveBytes(p.key, a),
          signature: consent,
        )) {
      return;
    }
    _leaving[a] = (consent, _now());
    _kickVotes.remove(a);
    _voteSigs.remove(a);
    await _save();
    await _maybeRekeyAfterLeave();
  }

  /// The signed consents of the residents [json] names as leaving the
  /// household [flatKey] (resident key → signature), when every one holds
  /// and names a resident of [members]; `null` otherwise.
  Future<Map<String, String>?> _leaveConsents(
    String flatKey,
    Iterable<String> members,
    Object? json,
  ) async {
    if (json is! Map || json.isEmpty || json.length > FlatProfile.maxMembers) {
      return null;
    }
    final Set<String> known = members.toSet();
    final Map<String, String> out = <String, String>{};
    for (final MapEntry<dynamic, dynamic> e in json.entries) {
      final Object? r = e.key;
      final Object? sig = e.value;
      if (r is! String ||
          sig is! String ||
          !known.contains(r) ||
          !await verifyLedgerSignature(
            publicKey: r,
            message: flatLeaveBytes(flatKey, r),
            signature: sig,
          )) {
        return null;
      }
      out[r] = sig;
    }
    return out;
  }

  /// Makes the household's new key once housemates left: the remaining
  /// resident with the lowest resident key does it at once, any other
  /// after [kLeaveRekeyWait] (the first may be offline).
  Future<void> _maybeRekeyAfterLeave() async {
    final FlatProfile? p = _profile;
    final String? me = _resident?.id;
    if (p == null || _pair == null || me == null) {
      return;
    }
    _leaving.removeWhere(
      (String r, (String, int) _) => !p.members.containsKey(r) || r == me,
    );
    if (_leaving.isEmpty) {
      return;
    }
    final List<String> stay = <String>[
      for (final String r in p.members.keys)
        if (!_leaving.containsKey(r)) r,
    ]..sort();
    final int first = _leaving.values
        .map(((String, int) l) => l.$2)
        .reduce(min);
    if ((stay.isNotEmpty && stay.first == me) ||
        _now() - first >= kLeaveRekeyWait.inMilliseconds) {
      final List<String> gone = _leaving.keys.toList()..sort();
      await _rekey(
        gone.first,
        leaves: <String, String>{
          for (final String r in gone) r: _leaving[r]!.$1,
        },
      );
    }
  }

  Future<void> _onHouse(String sender, Map<String, dynamic> b) async {
    final FlatProfile? p = await _verifiedProfile(_pair!.id, b['p']);
    if (p == null) {
      return;
    }
    // A household taken from the circle copy: a housemate confirmed it.
    _restoredAt = null;
    final bool wasJoining = joining;
    final Map<String, String> before =
        _profile?.members ?? const <String, String>{};
    if (p.newerThan(_profile)) {
      _profile = p;
    }
    joining = false;
    final Object? door = b['door'];
    final Object? doorAt = b['doorAt'];
    if (door is String && doorAt is int && doorAt > _doorAt) {
      _door = door;
      _doorAt = doorAt;
      // "Nowy kod" ended the invitations passed nearby with the old door.
      _tempDoors.clear();
    }
    final Object? shareAt = b['shareAt'];
    if (shareAt is int && shareAt > _shareAt) {
      shareWithScanners = b['share'] == true;
      _shareAt = shareAt;
    }
    final int now = _now();
    // Short-lived tokens only of the current door: a housemate still on an
    // older one does not bring back the tokens "Nowy kod" ended.
    final bool currentDoor = doorAt is int && doorAt >= _doorAt;
    _intMap(b['td']).forEach((String token, int until) {
      if (currentDoor &&
          until > now &&
          until - now <= kNearbyCodeLife.inMilliseconds &&
          token.length <= 40 &&
          _tempDoors.length < kMaxTempDoors) {
        _tempDoors[token] = max(until, _tempDoors[token] ?? 0);
      }
    });
    final Object? viewAt = b['viewAt'];
    if (viewAt is int && viewAt > _viewAt) {
      _view = FlatDoorView.fromJson(b['view']);
      _viewAt = viewAt;
    }
    _intMap(b['rm']).forEach((String key, int at) {
      if (at > (_removed[key] ?? 0)) {
        _removed[key] = at;
      }
    });
    final Object? nb = b['nb'];
    if (nb is List) {
      for (final Object? item in nb) {
        if (item is! Map || item['at'] is! int) {
          continue;
        }
        final FlatProfile? fp = FlatProfile.fromJson(item['p']);
        if (fp == null || fp.key == p.key || !await fp.verify()) {
          continue;
        }
        final int addedAt = item['at'] as int;
        if ((_removed[fp.key] ?? 0) >= addedAt) {
          continue;
        }
        final NeighborFlat? had = _neighbors[fp.key];
        // Residents' keys a housemate pinned (ours stay where we have one).
        final Map<String, int> pins = flatPinsFromJson(item['rk']);
        if (had == null) {
          _neighbors[fp.key] = NeighborFlat(
            profile: fp,
            addedAt: addedAt,
            weScanned: item['ws'] == true,
            scannedUs: item['su'] == true,
            seenItems: fp.items.map((FlatItem i) => i.id).toSet(),
            residents: pins,
          );
        } else {
          if (fp.newerThan(had.profile)) {
            had.profile = fp;
          }
          had
            ..weScanned = had.weScanned || item['ws'] == true
            ..scannedUs = had.scannedUs || item['su'] == true;
          pins.forEach((String r, int since) {
            had.residents.putIfAbsent(r, () => since);
          });
        }
      }
    }
    _neighbors.removeWhere(
      (String key, NeighborFlat f) => (_removed[key] ?? 0) >= f.addedAt,
    );
    _messages.removeWhere(
      (String _, FlatMessage m) => !_neighbors.containsKey(m.flat),
    );
    final Object? msgs = b['msgs'];
    if (msgs is List) {
      for (final Object? item in msgs) {
        final FlatMessage? m = FlatMessage.fromJson(item);
        if (m != null &&
            !_messages.containsKey(m.id) &&
            _neighbors.containsKey(m.flat)) {
          _messages[m.id] = m;
        }
      }
    }
    _signupsFromJson(b['sign']).forEach((
      String item,
      Map<String, FlatSignup> list,
    ) {
      final Map<String, FlatSignup> mine = _signups[item] ??=
          <String, FlatSignup>{};
      list.forEach((String flat, FlatSignup s) {
        if (s.at > (mine[flat]?.at ?? -1)) {
          mine[flat] = s;
        }
      });
    });
    _flatSignupMap(b['my']).forEach((String key, FlatSignup s) {
      if (s.at > (_mine[key]?.at ?? -1)) {
        _mine[key] = s;
      }
    });
    final Set<String> residents =
        (_profile?.members ?? const <String, String>{}).keys.toSet();
    // A resident's first name: each resident says their own (the
    // housemate who sent this, for theirs); others' only when unknown here.
    final String? from = _residentOf(sender);
    _stringMap(b['names']).forEach((String r, String n) {
      if (residents.contains(r) &&
          n.trim().isNotEmpty &&
          r != _resident?.id &&
          (r == from || (_names[r] ?? '').isEmpty)) {
        _names[r] = n;
      }
    });
    // Housemates' phones: the first one known for a resident stays, and
    // this phone's own is never taken from elsewhere.
    final String? me = _resident?.id;
    _phoneMap(b['ph']).forEach((String r, String phone) {
      if (residents.contains(r) && r != me) {
        _phones.putIfAbsent(r, () => phone);
      }
    });
    // Two housemates changed the profile at once and theirs won: a resident
    // only ours had (one who just joined) comes back. One who left or was
    // removed is no housemate here any more.
    final Map<String, String> lost = <String, String>{
      for (final MapEntry<String, String> e in before.entries)
        if (!residents.contains(e.key) && _phones.containsKey(e.key))
          e.key: e.value,
    };
    if (lost.isNotEmpty) {
      _later(() => _restoreResidents(lost));
    }
    // Knocks: answered on a housemate's phone, they close here; new ones
    // wait here too (and ring, when the housemate just got them).
    final Set<String> closed = _takeDecisions(b['kd']);
    final List<FlatKnock> fresh = _takeKnocks(b['kn']);
    await _save();
    for (final String flat in closed) {
      await _dismissKnock(flat);
    }
    if (b['ring'] == true) {
      for (final FlatKnock k in fresh) {
        await _ringKnock(k);
      }
    }
    if (wasJoining && hasFlat) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-joined-${p.key.hashCode}',
          title: t('Jesteś domownikiem'),
          body: t('Dołączyłeś(-aś) do „{name}”.', {'name': p.name}),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-join',
        ),
      );
    }
  }

  /// Puts back the residents [lost] (resident key → door) that are still
  /// housemates here but missing from the profile.
  Future<void> _restoreResidents(Map<String, String> lost) async {
    final FlatProfile? p = _profile;
    if (p == null) {
      return;
    }
    final Map<String, String> back = <String, String>{
      for (final MapEntry<String, String> e in lost.entries)
        if (!p.members.containsKey(e.key) && _phones.containsKey(e.key))
          e.key: e.value,
    };
    if (back.isEmpty ||
        p.members.length + back.length > FlatProfile.maxMembers) {
      return;
    }
    await _changeProfile(
      (FlatProfile p) =>
          p.copyWith(members: <String, String>{...back, ...p.members}),
    );
  }

  // ---- removing a housemate who will not leave ----

  /// Votes to remove the resident [target] (their resident key) from the
  /// household. Once a majority of the other residents agree, the
  /// household gets a new key and a new door code without them, and
  /// neighbours are told. Returns whether the vote counted.
  Future<bool> voteRemove(String target) async {
    final FlatProfile? p = _profile;
    final String? me = _resident?.id;
    if (p == null ||
        _pair == null ||
        me == null ||
        target == me ||
        !p.members.containsKey(target)) {
      return false;
    }
    // Signed with this phone's own key: neighbours check the votes when
    // the household announces its new key.
    final LedgerKeyPair pair = await _ensureResident();
    final String vote = b64(
      await pair.signWithKey(flatKickBytes(p.key, target)),
    );
    (_kickVotes[target] ??= <String>{}).add(me);
    (_voteSigs[target] ??= <String, String>{})[me] = vote;
    // In a household of two, the other resident is asked first.
    final bool two = p.members.length == 2;
    if (two) {
      _kickAsks.putIfAbsent(target, _now);
    }
    await _save();
    await _sendToHouse(
      <String>[
        for (final String m in _housemates)
          if (m != _phones[target]) m,
      ],
      FlatTypes.kick,
      <String, dynamic>{'a': target, 'by': me, 'v': vote},
    );
    if (two) {
      final String? phone = _phones[target];
      if (phone != null) {
        await _sendToHouse(
          <String>[phone],
          FlatTypes.kick,
          <String, dynamic>{
            'a': target,
            'by': me,
            'v': vote,
            'ask': true,
            'at': _kickAsks[target],
          },
        );
      }
      final String name = residentName(target);
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-kick-wait-${target.hashCode}',
          title: t('Czekamy na zgodę: {name}', {
            'name': name.isEmpty ? t('Jeden z telefonów') : name,
          }),
          body: t(
            'Jeśli nie odpowie w ciągu 7 dni, telefon zostanie odłączony.',
          ),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-kick',
        ),
      );
      return true;
    }
    await _maybeRekey(target);
    await _syncOwnDoor();
    return true;
  }

  /// In a household of two: when removing [target] (asked by this phone)
  /// happens without their answer, or `null` when it was not asked.
  int? removalDeadline(String target) {
    final int? asked = _kickAsks[target];
    return asked == null ? null : asked + kTwoResidentWait.inMilliseconds;
  }

  /// In a household of two: who asked to remove this phone (their resident
  /// key) and when it happens without an answer; `null` normally.
  (String, int)? get removalAsked {
    final (String, int)? asked = _askedToGo;
    return asked == null
        ? null
        : (asked.$1, asked.$2 + kTwoResidentWait.inMilliseconds);
  }

  /// "Nie zgadzam się": this phone stays; the housemate who asked is told.
  /// ("Zgadzam się" is [leaveFlat].)
  Future<void> refuseRemoval() async {
    final (String, int)? asked = _askedToGo;
    final String? me = _resident?.id;
    final String? phone = asked == null ? null : _phones[asked.$1];
    if (asked == null || me == null) {
      return;
    }
    _askedToGo = null;
    await _save();
    await _dismissSlot('flat-kick-ask');
    if (phone != null) {
      await _sendToHouse(
        <String>[phone],
        FlatTypes.kick,
        <String, dynamic>{'a': me, 'by': me, 'refuse': true},
      );
    }
  }

  Future<void> _dismissSlot(String slot) async {
    try {
      await dismissNotification?.call(slot);
    } on Object catch (error) {
      logZenWarning('Sąsiedzi: powiadomienie: $error');
    }
  }

  /// In a household of two: the other resident asks to remove this phone
  /// ('ask'), takes it back ('no'), or removed it after a week without an
  /// answer ('gone').
  Future<void> _onAskedToGo(
    String sender,
    String by,
    Map<String, dynamic> b,
  ) async {
    final FlatProfile? p = _profile;
    final String? me = _resident?.id;
    if (p == null ||
        me == null ||
        !p.members.containsKey(by) ||
        _phones[by] != sender) {
      return;
    }
    final String name = residentName(by).isEmpty
        ? t('Domownik')
        : residentName(by);
    if (b['no'] == true) {
      if (_askedToGo?.$1 == by) {
        _askedToGo = null;
        await _save();
        await _dismissSlot('flat-kick-ask');
      }
      return;
    }
    if (b['gone'] == true) {
      if (_askedToGo?.$1 != by) {
        return;
      }
      final String flat = p.name;
      _dropFlat();
      await _save();
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-kick-gone-${p.key.hashCode}',
          title: t('Ten telefon odłączono od „{name}”', {'name': flat}),
          body: t('Minęło 7 dni bez odpowiedzi.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-kick-ask',
        ),
      );
      return;
    }
    final Object? vote = b['v'];
    if (b['ask'] != true ||
        vote is! String ||
        !await verifyLedgerSignature(
          publicKey: by,
          message: flatKickBytes(p.key, me),
          signature: vote,
        )) {
      return;
    }
    final Object? at = b['at'];
    final bool fresh = _askedToGo == null;
    _askedToGo = (by, at is int ? min(at, _now()) : _now());
    await _save();
    if (fresh) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-kick-ask-${by.hashCode}',
          title: t('{name} chce odłączyć ten telefon', {'name': name}),
          body: t(
            'Zgódź się albo odmów w „Domownicy”. Bez odpowiedzi za 7 dni '
            'telefon zostanie odłączony.',
          ),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          routeKey: buildFlatKnocksRouteKey(),
          slotKey: 'flat-kick-ask',
        ),
      );
    }
  }

  /// In a household of two: the other resident does not agree to leave.
  Future<void> _onRemovalRefused(String sender, String target) async {
    if (_phones[target] != sender || !_kickAsks.containsKey(target)) {
      return;
    }
    _kickAsks.remove(target);
    _kickVotes.remove(target);
    _voteSigs.remove(target);
    await _save();
    final String name = residentName(target);
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-kick-no-${target.hashCode}',
        title: t('{name} nie zgadza się na odłączenie', {
          'name': name.isEmpty ? t('Jeden z telefonów') : name,
        }),
        body: t('Telefon zostaje domownikiem.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-kick',
      ),
    );
  }

  /// Takes back this phone's vote.
  Future<void> withdrawVote(String target) async {
    final FlatProfile? p = _profile;
    final String? me = _resident?.id;
    if (p == null || me == null || !(_kickVotes[target]?.remove(me) ?? false)) {
      return;
    }
    _voteSigs[target]?.remove(me);
    final bool asked = _kickAsks.remove(target) != null;
    await _save();
    await _sendToHouse(
      <String>[
        for (final String m in _housemates)
          if (asked || m != _phones[target]) m,
      ],
      FlatTypes.kick,
      <String, dynamic>{'a': target, 'by': me, 'no': true},
    );
  }

  Future<void> _onKick(String sender, Map<String, dynamic> b) async {
    final FlatProfile? p = _profile;
    final Object? a = b['a'];
    final Object? by = b['by'];
    final String? me = _resident?.id;
    if (p == null || a is! String || by is! String) {
      return;
    }
    final String target = a;
    if (target == me && by != me) {
      await _onAskedToGo(sender, by, b);
      return;
    }
    if (target == by && b['refuse'] == true) {
      await _onRemovalRefused(sender, target);
      return;
    }
    if (target == me ||
        target == by ||
        !p.members.containsKey(target) ||
        !p.members.containsKey(by)) {
      return;
    }
    if (b['no'] == true) {
      // Only the voter's own phone takes a vote back.
      if (_phones[by] == sender) {
        _kickVotes[target]?.remove(by);
        _voteSigs[target]?.remove(by);
        await _save();
      }
      return;
    }
    // The vote signed with the voter's own key.
    final Object? vote = b['v'];
    if (vote is! String ||
        !await verifyLedgerSignature(
          publicKey: by,
          message: flatKickBytes(p.key, target),
          signature: vote,
        )) {
      return;
    }
    (_voteSigs[target] ??= <String, String>{})[by] = vote;
    final bool added = (_kickVotes[target] ??= <String>{}).add(by);
    await _save();
    if (added && me != null && !(_kickVotes[target]?.contains(me) ?? false)) {
      final String name = residentName(target);
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-kick-${target.hashCode}-${by.hashCode}',
          title: t('Domownicy chcą odłączyć telefon'),
          body: t(
            '{name}: głosów {votes} z {needed}. Zajrzyj do „Domownicy”.',
            <String, Object?>{
              'name': name.isEmpty ? t('Jeden z telefonów') : name,
              'votes': votesFor(target).length,
              'needed': votesNeeded(target),
            },
          ),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-kick',
        ),
      );
    }
    final (String, Map<String, dynamic>)? waiting = _pendingRekeys[target];
    if (waiting != null && _enoughVotes(target)) {
      _pendingRekeys.remove(target);
      await _applyRekey(target, waiting.$2);
      return;
    }
    await _maybeRekey(target);
  }

  /// With a majority, the voter with the lowest resident key makes the new
  /// key (so two phones do not do it at once).
  Future<void> _maybeRekey(String target) async {
    final String? me = _resident?.id;
    final Set<String> votes = votesFor(target);
    if (me == null || !_enoughVotes(target) || !votes.contains(me)) {
      return;
    }
    if ((_profile?.members.length ?? 0) == 2) {
      // Two residents: the other one's consent (they leave themselves), or
      // a week without an answer.
      final int? asked = _kickAsks[target];
      if (asked == null || _now() - asked < kTwoResidentWait.inMilliseconds) {
        return;
      }
      final String? phone = _phones[target];
      if (phone != null) {
        await _sendToHouse(
          <String>[phone],
          FlatTypes.kick,
          <String, dynamic>{'a': target, 'by': me, 'gone': true},
        );
      }
      await _rekey(target);
      return;
    }
    final List<String> sorted = votes.toList()..sort();
    if (sorted.first == me) {
      await _rekey(target);
    }
  }

  /// Makes the household's new key and door code without the resident
  /// [target]: voted out, or (with [leaves], the signed consents of the
  /// residents who left, [target] among them) without everyone who left.
  Future<void> _rekey(
    String target, {
    Map<String, String> leaves = const <String, String>{},
  }) async {
    final FlatProfile? p = _profile;
    final LedgerKeyPair? old = _pair;
    final String? me = _resident?.id;
    if (p == null || old == null || me == null) {
      return;
    }
    final Set<String> gone = <String>{target, ...leaves.keys};
    final LedgerKeyPair pair = await LedgerKeyPair.generate();
    final int t = _now();
    final String door = _newDoor();
    final FlatProfile next = await p
        .copyWith(
          key: pair.id,
          members: <String, String>{
            for (final MapEntry<String, String> e in p.members.entries)
              if (!gone.contains(e.key)) e.key: e.value,
          },
          rev: 1,
        )
        .signedWith(pair);
    // Signed with the old key (the one housemates and neighbours trust),
    // before switching to the new one.
    final Map<String, dynamic> toHouse =
        await _envelopeWith(old, FlatTypes.rekey, old.id, <String, dynamic>{
          'a': target,
          'seed': b64(pair.seed),
          'p': next.toJson(),
          'door': door,
          'doorAt': t,
          if (leaves.isNotEmpty) 'lv': leaves,
        });
    // For neighbours the old key is not enough (the removed phone has it
    // too): the notice carries this resident's own signature and the
    // others' signed votes, checked with the residents' keys the neighbours
    // pinned while everyone was still in.
    final LedgerKeyPair mine = await _ensureResident();
    final String bySig = b64(
      await mine.signWithKey(flatNewKeyBytes(old.id, pair.id, target)),
    );
    final Map<String, String> votes = <String, String>{
      for (final String v in votesFor(target))
        if (_voteSigs[target]?[v] != null) v: _voteSigs[target]![v]!,
    };
    final Map<String, dynamic> notice = <String, dynamic>{
      'p': next.toJson(),
      'a': target,
      'by': me,
      'bs': bySig,
      'v': votes,
      // Who left by themselves: their own consent instead of votes.
      if (leaves.isNotEmpty) 'lv': leaves,
    };
    final List<String> stay = <String>[
      for (final String r in next.members.keys)
        if (r != me && _phones[r] != null) _phones[r]!,
    ];
    // To neighbours first, from the door they know: the new door code gives
    // this phone's door a new key, and so a new address.
    for (final NeighborFlat f in _neighbors.values.toList()) {
      await _sendToDoors(
        f.profile.doors,
        FlatTypes.newKey,
        f.key,
        notice,
        pair: old,
      );
    }
    _oldKey = old.id;
    _seed = b64(pair.seed);
    _pair = pair;
    _profile = next;
    _door = door;
    _doorAt = t;
    _kickVotes.clear();
    _voteSigs.clear();
    _pendingRekeys.clear();
    _leaving.clear();
    _tempDoors.clear();
    _kickAsks.clear();
    for (final String r in gone) {
      _names.remove(r);
      _phones.remove(r);
    }
    await _save();
    for (final String m in stay) {
      await _send(m, toHouse);
    }
    await _notifyRekeyed(next, left: leaves.isNotEmpty);
  }

  Future<void> _notifyRekeyed(FlatProfile next, {bool left = false}) =>
      host.notify(
        RuntimeSystemNotification(
          id: 'flat-rekey-${next.key.hashCode}',
          title: left
              ? t('Domownik opuścił „{name}”', {'name': next.name})
              : t('Telefon odłączony od „{name}”', {'name': next.name}),
          body: t(
            'Macie nowy klucz mieszkania i nowy kod na drzwi — wydrukujcie '
            'nową naklejkę. Sąsiedzi dostali informację.',
          ),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-kick',
        ),
      );

  Future<void> _onRekey(String sender, Map<String, dynamic> b) async {
    final FlatProfile? p = _profile;
    final Object? a = b['a'];
    final String? by = _residentOf(sender);
    if (p == null || a is! String || by == null) {
      return;
    }
    final String target = a;
    if (target == _resident?.id ||
        by == target ||
        !p.members.containsKey(target)) {
      return; // the removed phone gets nothing; nobody removes us by mail
    }
    // Phones that left by themselves: their own consent is enough.
    final Map<String, String>? leaves = b['lv'] == null
        ? null
        : await _leaveConsents(p.key, p.members.keys, b['lv']);
    if (b['lv'] != null &&
        (leaves == null ||
            !leaves.containsKey(target) ||
            leaves.containsKey(by) ||
            leaves.containsKey(_resident?.id))) {
      return;
    }
    if (leaves == null && !_enoughVotes(target)) {
      // The votes may still be on their way.
      _pendingRekeys[target] = (sender, b);
      return;
    }
    await _applyRekey(target, b, leaves: leaves?.keys.toSet());
  }

  /// Checks a new key from a housemate and switches to it: without the
  /// resident [target] (and, when they left by themselves, the residents
  /// [leaves]).
  Future<bool> _applyRekey(
    String target,
    Map<String, dynamic> b, {
    Set<String>? leaves,
  }) async {
    final String? me = _resident?.id;
    final Object? seed = b['seed'];
    final Uint8List? seedBytes = unb64(seed, length: 32);
    if (seed is! String || seedBytes == null || me == null) {
      return false;
    }
    final Set<String> gone = <String>{target, ...?leaves};
    final LedgerKeyPair pair = await LedgerKeyPair.fromSeed(seedBytes);
    final FlatProfile? next = await _verifiedProfile(pair.id, b['p']);
    if (next == null ||
        !next.members.containsKey(me) ||
        gone.any(next.members.containsKey)) {
      return false;
    }
    final Object? door = b['door'];
    final Object? doorAt = b['doorAt'];
    _oldKey = _pair?.id;
    _seed = seed;
    _pair = pair;
    _profile = next;
    if (door is String && doorAt is int) {
      _door = door;
      _doorAt = doorAt;
    } else {
      _door = _newDoor();
      _doorAt = _now();
    }
    _kickVotes.clear();
    _voteSigs.clear();
    _pendingRekeys.clear();
    _leaving.clear();
    _tempDoors.clear();
    _kickAsks.clear();
    for (final String r in gone) {
      _names.remove(r);
      _phones.remove(r);
    }
    await _save();
    await _notifyRekeyed(next, left: leaves != null);
    return true;
  }

  /// Two housemates made a new key at once: everyone keeps the one with
  /// the lower key, and the phone that switches tells neighbours (with the
  /// key they now know) where the household went.
  Future<void> _onRekeyRace(String sender, Map<String, dynamic> b) async {
    final FlatProfile? p = _profile;
    final LedgerKeyPair? mine = _pair;
    final Object? a = b['a'];
    final Uint8List? seedBytes = unb64(b['seed'], length: 32);
    if (p == null ||
        mine == null ||
        a is! String ||
        seedBytes == null ||
        p.members.containsKey(a) ||
        _residentOf(sender) == null) {
      return;
    }
    final LedgerKeyPair theirs = await LedgerKeyPair.fromSeed(seedBytes);
    if (theirs.id.compareTo(mine.id) >= 0) {
      return; // ours stays; they will switch when ours reaches them
    }
    final FlatProfile? next = await _verifiedProfile(theirs.id, b['p']);
    if (next == null) {
      return;
    }
    for (final NeighborFlat f in _neighbors.values.toList()) {
      await _sendToDoors(
        f.profile.doors,
        FlatTypes.newKey,
        f.key,
        <String, dynamic>{'p': next.toJson()},
        pair: mine,
      );
    }
    _seed = b64(seedBytes);
    _pair = theirs;
    _profile = next;
    final Object? door = b['door'];
    final Object? doorAt = b['doorAt'];
    if (door is String && doorAt is int) {
      _door = door;
      _doorAt = doorAt;
    }
    await _save();
  }

  /// A neighbour household has a new key: they removed a phone.
  ///
  /// The notice is signed with the old key, which the removed phone holds
  /// too. So it must also carry the signature of the resident who made the
  /// new key and the signed votes of a majority of the others, checked with
  /// the residents' own keys this phone pinned while they were all in (at
  /// least [kResidentKeyTrust] ago). A notice made by the phone it names as
  /// removed, or without those votes, is ignored. When no resident key is
  /// known that long (a household met just now), a notice from a resident
  /// who stays counts.
  ///
  /// A second, different new key for the same old one never silently
  /// replaces the first: the same removal made twice at once (two
  /// housemates) ends on the lower key, as for the housemates; two
  /// different stories of who was removed raise [kFlatKeyConflict] — the
  /// one made by a phone the other names as removed loses, otherwise the
  /// first stays — and scanning the household's new door code settles it.
  Future<void> _onNewKey(
    String from,
    String sender,
    Map<String, dynamic> b,
  ) async {
    final FlatProfile? next = FlatProfile.fromJson(b['p']);
    if (next == null ||
        next.key == from ||
        next.key == _profile?.key ||
        _neighbors.containsKey(next.key) ||
        !await next.verify()) {
      return;
    }
    final int now = _now();
    final NeighborFlat? f = _neighbors[from];
    if (f != null) {
      final FlatKeySwitch? hop = _switchTo(from);
      if (hop != null &&
          now - hop.at < const Duration(days: 1).inMilliseconds &&
          next.key.compareTo(from) < 0 &&
          setEquals(
            next.members.keys.toSet(),
            f.profile.members.keys.toSet(),
          ) &&
          f.profile.residentAt(sender) != null) {
        // Two housemates made a new key at once: the household keeps the
        // lower one, and the key it leaves is one the removed phone never
        // had.
        _moveNeighbor(f, next);
        hop.newKey = next.key;
        await _save();
        await _syncHouse();
        return;
      }
      final (Set<String>, String)? claim = await _checkNewKey(
        from,
        f.profile.members,
        f.residents,
        next,
        sender,
        b,
      );
      if (claim == null) {
        return;
      }
      _switches[from] = FlatKeySwitch(
        oldKey: from,
        name: f.profile.name,
        members: Map<String, String>.of(f.profile.members),
        pins: Map<String, int>.of(f.residents),
        newKey: next.key,
        removed: claim.$1,
        by: claim.$2,
        at: now,
      );
      _moveNeighbor(f, next);
      await _save();
      await _syncHouse();
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-newkey-${next.key.hashCode}',
          title: t('{name}: zmiana domowników', {'name': next.name}),
          body: t(
            'Odłączyli jeden telefon i mają nowy klucz. Lista sąsiadów jest '
            'aktualna.',
          ),
          createdAtMillis: now,
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-newkey',
        ),
      );
      return;
    }
    // A notice for a key this phone already moved away from.
    final FlatKeySwitch? s = _switches[from];
    final NeighborFlat? current = s == null ? null : _neighbors[s.newKey];
    if (s == null || current == null || s.rival?.key == next.key) {
      return;
    }
    final (Set<String>, String)? claim = await _checkNewKey(
      from,
      s.members,
      s.pins,
      next,
      sender,
      b,
    );
    if (claim == null) {
      return;
    }
    if (setEquals(claim.$1, s.removed)) {
      // The same phone removed, two keys made at once.
      if (next.key.compareTo(s.newKey) < 0) {
        _moveNeighbor(current, next);
        s
          ..newKey = next.key
          ..by = claim.$2;
        await _save();
        await _syncHouse();
      }
      return;
    }
    // Two different stories of who was removed.
    final bool rivalMadeByRemoved = s.removed.contains(claim.$2);
    final bool currentMadeByRemoved = claim.$1.contains(s.by);
    if (currentMadeByRemoved && !rivalMadeByRemoved) {
      final FlatProfile was = current.profile;
      final Set<String> wasRemoved = s.removed;
      final String wasBy = s.by;
      _moveNeighbor(current, next);
      s
        ..newKey = next.key
        ..removed = claim.$1
        ..by = claim.$2
        ..rival = was
        ..rivalRemoved = wasRemoved
        ..rivalBy = wasBy;
    } else {
      s
        ..rival = next
        ..rivalRemoved = claim.$1
        ..rivalBy = claim.$2;
    }
    await _save();
    await _syncHouse();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-newkey-conflict-${from.hashCode}',
        title: kFlatKeyConflict,
        body: t(
          '„{name}”: nie wiadomo, który telefon naprawdę odłączyli. '
          'Zeskanujcie ich nowy kod z drzwi.',
          <String, Object?>{'name': s.name},
        ),
        createdAtMillis: now,
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-newkey',
      ),
    );
  }

  /// The switch that led to [key], if this phone followed one.
  FlatKeySwitch? _switchTo(String key) {
    for (final FlatKeySwitch s in _switches.values) {
      if (s.newKey == key) {
        return s;
      }
    }
    return null;
  }

  /// Checks a "new key" notice of the household that had the key [oldKey]
  /// with the residents [members] (resident key → door) and the residents'
  /// keys [pins] (→ when first seen), sent from the door [sender]. Returns
  /// who it removes and who made it (resident keys), or `null` when it does
  /// not hold up.
  Future<(Set<String>, String)?> _checkNewKey(
    String oldKey,
    Map<String, String> members,
    Map<String, int> pins,
    FlatProfile next,
    String sender,
    Map<String, dynamic> b,
  ) async {
    final Set<String> removed = <String>{
      for (final String m in members.keys)
        if (!next.members.containsKey(m)) m,
    };
    final int t = _now();
    final Set<String> trusted = <String>{
      for (final MapEntry<String, int> e in pins.entries)
        if (members.containsKey(e.key) &&
            t - e.value >= kResidentKeyTrust.inMilliseconds)
          e.key,
    };
    final Object? a = b['a'];
    final String? target = a is String ? a : null;
    // The residents whose votes can be checked: keys known long enough,
    // but not the one being removed.
    final List<String> voters = <String>[
      for (final String v in trusted)
        if (v != target) v,
    ];
    if (voters.isEmpty) {
      // Nothing to check the votes with (a household met just now): a
      // resident who stays, from their own door.
      String? maker;
      for (final MapEntry<String, String> e in members.entries) {
        if (e.value.isNotEmpty && e.value == sender) {
          maker = e.key;
        }
      }
      return maker != null && next.members.containsKey(maker)
          ? (removed, maker)
          : null;
    }
    final Object? by = b['by'];
    final Object? bySig = b['bs'];
    final Object? votes = b['v'];
    if (target == null || by is! String || bySig is! String || votes is! Map) {
      return null;
    }
    if (!removed.contains(target) ||
        by == target ||
        !next.members.containsKey(by) ||
        !pins.containsKey(by) ||
        !await verifyLedgerSignature(
          publicKey: by,
          message: flatNewKeyBytes(oldKey, next.key, target),
          signature: bySig,
        )) {
      return null;
    }
    final Object? lv = b['lv'];
    if (lv != null) {
      // Phones that left by themselves ("Opuść"): each one's own signed
      // consent stands for the votes, checked with the keys pinned for
      // them; the new key's maker must be a resident known long enough.
      final Map<String, String>? leaves = await _leaveConsents(
        oldKey,
        pins.keys.where(members.containsKey),
        lv,
      );
      return leaves != null &&
              setEquals(leaves.keys.toSet(), removed) &&
              trusted.contains(by)
          ? (removed, by)
          : null;
    }
    // A majority of the other residents whose keys are known voted for it.
    int yes = 0;
    for (final String v in voters) {
      final Object? sig = votes[v];
      if (sig is String &&
          await verifyLedgerSignature(
            publicKey: v,
            message: flatKickBytes(oldKey, target),
            signature: sig,
          )) {
        yes++;
      }
    }
    if (yes < voters.length ~/ 2 + 1) {
      return null;
    }
    return (removed, by);
  }

  /// Moves the neighbour household [f] to its new key [next], with its
  /// messages, sign-ups, reveals and residents' keys.
  void _moveNeighbor(NeighborFlat f, FlatProfile next) {
    final String from = f.key;
    final int t = _now();
    _neighbors.remove(from);
    _removed[from] = t;
    _removed.remove(next.key);
    _neighbors[next.key] = NeighborFlat(
      profile: next,
      addedAt: t,
      weScanned: f.weScanned,
      scannedUs: f.scannedUs,
      following: f.following,
      seenItems: <String>{
        ...f.seenItems,
        ...next.items.map((FlatItem i) => i.id),
      },
      residents: Map<String, int>.of(f.residents),
    );
    for (final FlatMessage m in _messages.values.toList()) {
      if (m.flat == from) {
        _messages[m.id] = FlatMessage(
          id: m.id,
          flat: next.key,
          mine: m.mine,
          text: m.text,
          at: m.at,
          by: m.by,
          item: m.item,
        );
      }
    }
    final int? read = _lastRead.remove(from);
    if (read != null) {
      _lastRead[next.key] = read;
    }
    for (final Map<String, FlatSignup> list in _signups.values) {
      final FlatSignup? s = list.remove(from);
      if (s != null) {
        list[next.key] = FlatSignup(
          flat: next.key,
          name: s.name,
          count: s.count,
          at: s.at,
        );
      }
    }
    for (final String k in _mine.keys.toList()) {
      if (k.startsWith('$from|')) {
        _mine['${next.key}|${k.substring(from.length + 1)}'] = _mine.remove(k)!;
      }
    }
    final List<FlatReveal>? reveals = _reveals.remove(from);
    if (reveals != null) {
      _reveals[next.key] = <FlatReveal>[
        for (final FlatReveal r in reveals)
          if (next.members.containsKey(r.resident))
            FlatReveal(
              flat: next.key,
              name: r.name,
              address: r.address,
              resident: r.resident,
              at: r.at,
            ),
      ];
    }
    if (_revealedTo.remove(from)) {
      _revealedTo.add(next.key);
    }
    pending.remove(from);
  }

  // ---- "Pokaż mój profil" ----

  /// Shows this resident's own account to the neighbour flat [key]: they
  /// see the name and can send a friend invitation. Only this phone's
  /// person is revealed, never the housemates, and this is the only time a
  /// neighbour learns a resident's own address: the reveal goes from this
  /// phone itself (to their doors), not from our door.
  Future<bool> revealMyProfile(String key) async {
    final NeighborFlat? f = _neighbors[key];
    final FlatProfile? p = _profile;
    final String own = _own;
    if (f == null || p == null || !hasFlat || own.isEmpty) {
      return false;
    }
    final LedgerKeyPair me = await _ensureResident();
    final String name = _clip(host.ownName(), 60);
    _revealedTo.add(key);
    await _save();
    final Map<String, dynamic> payload = <String, dynamic>{
      ...await _envelope(FlatTypes.reveal, key, <String, dynamic>{
        'n': name,
        'a': own,
        'rk': me.id,
        'rs': b64(await me.signWithKey(flatRevealBytes(p.key, key, own, name))),
      }),
      kReliableTtlKey: kDoorRetryLife.inMilliseconds,
    };
    for (final String d in f.profile.doors.toSet()) {
      await _send(d, payload);
    }
    return true;
  }

  Future<void> _onReveal(
    String from,
    String sender,
    Map<String, dynamic> b,
  ) async {
    final NeighborFlat? f = _neighbors[from];
    final String? ownKey = _pair?.id;
    final Object? a = b['a'];
    final Object? n = b['n'];
    final Object? rk = b['rk'];
    final Object? rs = b['rs'];
    // Only the phone itself reveals its own account, and only a resident
    // of that flat, signed with their own key.
    if (f == null ||
        ownKey == null ||
        a is! String ||
        _n(a) != sender ||
        n is! String ||
        n.trim().isEmpty ||
        rk is! String ||
        rs is! String ||
        !f.profile.members.containsKey(rk) ||
        !await verifyLedgerSignature(
          publicKey: rk,
          message: flatRevealBytes(from, ownKey, a, n),
          signature: rs,
        )) {
      return;
    }
    final FlatReveal r = FlatReveal(
      flat: from,
      name: _clip(n, 60),
      address: sender,
      resident: rk,
      at: _now(),
    );
    _reveals[from] = <FlatReveal>[
      ...(_reveals[from] ?? const <FlatReveal>[]).where(
        (FlatReveal x) => x.resident != rk && x.address != sender,
      ),
      r,
    ];
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-reveal-${from.hashCode}-${rk.hashCode}',
        title: t('{flat}: {name} pokazuje swój profil', {
          'flat': f.profile.name,
          'name': r.name,
        }),
        body: t('Możesz zaprosić do znajomych.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-reveal:$from',
      ),
    );
  }
}
