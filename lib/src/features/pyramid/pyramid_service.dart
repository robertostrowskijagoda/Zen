import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_record_log.dart';
import 'package:zen/src/features/pyramid/pyramid_root.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

abstract final class PyramidTypes {
  /// A new record, passed on.
  static const String record = 'pyr_rec';

  /// Records in bulk (sync, after admission).
  static const String records = 'pyr_recs';

  /// "These pyramids I keep, and their fingerprints."
  static const String hello = 'pyr_hello';

  /// Ids of one bucket that differed.
  static const String ids = 'pyr_ids';
  static const String want = 'pyr_want';

  /// A record to co-sign, and its signed copy back.
  static const String proposal = 'pyr_prop';
  static const String signature = 'pyr_sig';

  /// A referendum vote for one's cell head.
  static const String vote = 'pyr_vote';

  /// A payment order for a treasurer, and the treasurer's signature.
  static const String pay = 'pyr_pay';
  static const String paySig = 'pyr_paysig';
  static const String report = 'pyr_report';
  static const String appeal = 'pyr_appeal';

  /// An anonymous record to publish on someone else's behalf.
  static const String anon = 'pyr_anon';

  /// A message to a member through the access market: paid inbox, a
  /// reshare or an announcement (introductions are gates, see
  /// `meet/intro/`).
  static const String dm = 'pyr_dm';

  /// Anonymous sums of a branch for the cell head above (statistics,
  /// "Dotarło / przeczytało").
  static const String sum = 'pyr_sum';

  /// Pyramid posts a member passes on to friends outside the pyramid,
  /// read-only: the top's posts to everyone, national-section posts to
  /// those whose profile shows that nationality.
  static const String national = 'pyr_nat';

  /// "Whose pyramid key is at this address?", and the device's answer
  /// signed with its key ([PyramidService.provenKeyAt]).
  static const String who = 'pyr_who';
  static const String here = 'pyr_here';

  static const Set<String> all = <String>{
    who,
    here,
    national,
    sum,
    record,
    records,
    hello,
    ids,
    want,
    proposal,
    signature,
    vote,
    pay,
    paySig,
    report,
    appeal,
    anon,
    dm,
  };
}

/// The one notification for new pyramid posts (its id and slot).
const String kPyrPostsNotification = 'pyr-posts';

/// Bluetooth wave version of a crisis announcement.
const int kCrisisWaveVersion = 3;

/// How old an order (or a settlement) a treasurer still signs: it may
/// wait for treasurers who are offline, but not for ever.
const int kPyrMaxOrderAgeMs = 7 * 24 * 3600 * 1000;

/// A paid market message needs its payment to wait at least this long
/// for the answer (else the payer could take it back while it is read).
const int kPyrMarketMinWaitMs = 24 * 3600 * 1000;

/// Frames one sender may send in [kPyrRateWindowMs] (generous: a big
/// pyramid's first sync fits; a flood does not).
const int kPyrRateLimit = 3000;
const int kPyrRateWindowMs = 10 * 60 * 1000;

/// Reports and appeals kept on this phone: only from members, each
/// one this long at most, this many per sender and in all (the oldest go
/// first). They live under their own key, so the main state stays small.
const int kPyrReportEvidenceChars = 8000;

/// The largest signed original entry a report carries, encoded; a
/// bigger one goes without it (the text evidence stays). The entry's
/// signature and its device certificate take about 15 KB.
const int kPyrReportEntryBytes = 32 * 1024;

/// Records kept aside until the key their signatures name has come.
const int kPyrAwaitingKeys = 500;

/// How long the device at an address is taken to hold the pyramid key it
/// proved holding there ([PyramidService.provenKeyAt]), and how long its
/// answer is waited for.
const int kPyrAddressProofMs = 24 * 3600 * 1000;
const Duration kPyrAddressProofWait = Duration(seconds: 10);
const int kPyrAppealChars = 2000;
const int kPyrReportsPerSender = 10;
const int kPyrReportsTotal = 150;
const int kPyrAppealsPerSender = 5;
const int kPyrAppealsTotal = 100;

/// Own reports remembered (for escalation and decisions).
const int kPyrMyReportsKept = 100;

/// Proposals waiting for this person's signature: per sending device, in
/// all, and their size together.
const int kPyrProposalsPerSender = 20;
const int kPyrProposalsTotal = 100;
const int kPyrProposalsBytes = 6 * 1024 * 1024;

/// About how much of the records one `pyr_recs` frame carries.
const int kPyrRecordFrameBytes = 1024 * 1024;

/// Market messages kept: open ones per sender, all of them.
const int kPyrMarketOpenPerSender = 30;
const int kPyrMarketTotal = 400;

/// Political posts whose reach is counted (the newest, at most this old).
const int kPyrReachPosts = 50;
const int kPyrReachMaxAgeMs = 30 * 24 * 3600 * 1000;

/// A branch's anonymous statistics are shown only from this many people
/// (fewer would point at somebody).
const int kPyrStatsMinPeople = 5;

/// The topic of the anonymous statistics among the sums, and its
/// buckets: gender (k, m, other) × age (under 25, 25–39, 40–59, 60+).
const String kPyrStatsTopic = 'st';
const int kPyrStatsBuckets = 12;
const List<String> kPyrStatsGenders = <String>['k', 'm', ''];
const List<int> kPyrStatsAgeFrom = <int>[0, 25, 40, 60];

/// The bucket of a person born in [birthYear] with [gender] in [year].
int pyrStatsBucket(int birthYear, String gender, int year) {
  final int age = year - birthYear;
  int a = 0;
  for (int i = 0; i < kPyrStatsAgeFrom.length; i++) {
    if (age >= kPyrStatsAgeFrom[i]) {
      a = i;
    }
  }
  final int g = gender == 'k' ? 0 : (gender == 'm' ? 1 : 2);
  return g * kPyrStatsAgeFrom.length + a;
}

/// A record waiting for this person's signature.
final class PyrProposal {
  PyrProposal({
    required this.record,
    required this.from,
    required this.need,
    required this.at,
    this.extra = const <String, dynamic>{},
  });

  PyramidRecord record;

  /// Device that sent it.
  final String from;

  /// Signatures needed to publish.
  final int need;
  final int at;

  /// Private details for the signer (e.g. the newcomer's birth year).
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'r': record.toJson(),
    'f': from,
    'n': need,
    'at': at,
    'x': extra,
  };

  static PyrProposal? fromJson(Object? json) {
    if (json is! Map ||
        json['f'] is! String ||
        json['n'] is! int ||
        json['at'] is! int) {
      return null;
    }
    final PyramidRecord? r = PyramidRecord.fromJson(json['r']);
    return r == null
        ? null
        : PyrProposal(
            record: r,
            from: json['f'] as String,
            need: json['n'] as int,
            at: json['at'] as int,
            extra: json['x'] is Map
                ? Map<String, dynamic>.from(json['x'] as Map)
                : const <String, dynamic>{},
          );
  }
}

/// A report: what, why, the evidence; never who reported.
final class PyrReport {
  PyrReport({
    required this.id,
    required this.reason,
    required this.at,
    this.target = '',
    this.evidence = '',
    this.datingKey,
    this.from,
    this.escalated = false,
    this.entryId,
    this.entry,
    this.stage = 0,
    this.sentAt,
  });

  final String id;
  final String reason;
  final int at;

  /// Pyramid key of the reported person (if a member).
  final String target;
  final String evidence;
  final String? datingKey;

  /// Id of the reported entry (a post, comment, message): what a content
  /// ban names.
  final String? entryId;

  /// The signed original entry, when the reporter had it: evidence
  /// nobody can make up. In an inbox only once its signatures checked out.
  final Map<String, dynamic>? entry;

  /// Device that sent it (only in the delegate's inbox).
  final String? from;

  /// Reached the top (the last step of escalation).
  bool escalated;

  /// Escalation step: 0 = the delegates of the narrowest branch
  /// around the reporter, each step the next wider ones, then the top.
  int stage;

  /// When it went to the current step (own reports).
  int? sentAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'why': reason,
    'at': at,
    't': target,
    'ev': evidence,
    if (datingKey != null) 'dk': datingKey,
    if (from != null) 'f': from,
    if (escalated) 'esc': true,
    if (entryId != null) 'eid': entryId,
    if (entry != null) 'en': entry,
    if (stage > 0) 'st': stage,
    if (sentAt != null) 'sa': sentAt,
  };

  static PyrReport? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['why'] is! String ||
        json['at'] is! int) {
      return null;
    }
    String? s(String k) => json[k] is String ? json[k] as String : null;
    return PyrReport(
      id: json['id'] as String,
      reason: json['why'] as String,
      at: json['at'] as int,
      target: s('t') ?? '',
      evidence: s('ev') ?? '',
      datingKey: s('dk'),
      from: s('f'),
      escalated: json['esc'] == true,
      entryId: s('eid'),
      entry: json['en'] is Map
          ? Map<String, dynamic>.from(json['en'] as Map)
          : null,
      stage: json['st'] is int ? (json['st'] as int).clamp(0, 64) : 0,
      sentAt: json['sa'] is int ? json['sa'] as int : null,
    );
  }
}

/// What a market message asks for. The price of 'inbox' is this person's
/// price for a first message from people who are not friends (set with the
/// conversations outside friends, [PyramidService.setOfferKind]); a level
/// missing from it means "nobody of that level may write first".
/// Introductions are gates (`meet/intro/`), priced per friend in private.
Map<String, String> get kMarketKinds => <String, String>{
  'inbox': t('Wiadomość od osoby spoza znajomych'),
  'reshare': t('Udostępnienie mojego posta Twoim znajomym'),
  'ad': t('Ogłoszenie w sieci'),
};

/// Largest signed post a reshare on order may carry (its JSON with the
/// device certificate; signature and certificate take about 15 KB).
const int kMarketPostMaxBytes = 48 * 1024;

/// The text of [post] when it is a post that may be reshared on order:
/// a signed entry of its author's feed, public, not sealed.
/// Null for anything else. A post of photos only reads as "(zdjęcia)".
Future<String?> marketPostText(Map<String, dynamic>? post) async {
  final LogEntry? entry = post == null ? null : await verifiedEntry(post);
  if (entry == null ||
      entry.kind != kPostKind ||
      entry.space != accountSpace('feed', entry.account) ||
      isSealed(entry.body) ||
      entry.body['aud'] != Audience.public.name) {
    return null;
  }
  final Object? text = entry.body['text'];
  final String shown = text is String ? text.trim() : '';
  return shown.isEmpty ? t('(zdjęcia)') : shown;
}

/// A message from the access market, with the payment attached.
final class PyrMarketMessage {
  PyrMarketMessage({
    required this.id,
    required this.kind,
    required this.from,
    required this.text,
    required this.at,
    this.payment,
    this.amount = 0,
    this.mine = false,
    this.done = false,
    this.hops = 0,
    this.origin,
    this.level,
    this.post,
  });

  final String id;
  final String kind;

  /// Pyramid key of the sender (the other side when [mine]).
  final String from;
  final String text;
  final int at;
  final String? payment;

  /// What the receiver gets (for an announcement through intermediaries:
  /// each one's share).
  final int amount;
  final bool mine;
  bool done;

  /// An announcement: how many more times it may be passed on.
  final int hops;

  /// An announcement passed on: who wrote and paid for it.
  final String? origin;

  /// The level of acquaintance the price was for ([kPriceLevels]).
  final String? level;

  /// A reshare on order: the payer's signed public post (a ledger
  /// entry) that the one paid shares with their own friends. [text] is the
  /// post's text, the preview the one paid accepts or refuses.
  final Map<String, dynamic>? post;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'k': kind,
    'f': from,
    't': text,
    'at': at,
    if (payment != null) 'x': payment,
    'a': amount,
    if (mine) 'mine': true,
    if (done) 'done': true,
    if (hops > 0) 'h': hops,
    if (origin != null) 'o': origin,
    if (level != null) 'lv': level,
    if (post != null) 'en': post,
  };

  static PyrMarketMessage? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['k'] is! String ||
        json['f'] is! String ||
        json['t'] is! String ||
        json['at'] is! int) {
      return null;
    }
    return PyrMarketMessage(
      id: json['id'] as String,
      kind: json['k'] as String,
      from: json['f'] as String,
      text: json['t'] as String,
      at: json['at'] as int,
      payment: json['x'] is String ? json['x'] as String : null,
      amount: json['a'] is int ? json['a'] as int : 0,
      mine: json['mine'] == true,
      done: json['done'] == true,
      hops: json['h'] is int ? (json['h'] as int).clamp(0, kMaxAdHops) : 0,
      origin: json['o'] is String ? json['o'] as String : null,
      level: json['lv'] is String ? json['lv'] as String : null,
      post: json['en'] is Map
          ? Map<String, dynamic>.from(json['en'] as Map)
          : null,
    );
  }
}

/// Report reasons.
Map<String, String> get kReportReasons => <String, String>{
  'illegal': t('Nielegalna treść'),
  'fake': t('Fałszywe konto'),
  'farm': t('Farma kont'),
  'harass': t('Nękanie'),
  'fraud': t('Oszustwo'),
  'spam': t('Spam'),
  'minor': t('Osoba niepełnoletnia (randki)'),
  'other': t('Inne'),
};

/// The pyramid on this phone: keeps and spreads the signed
/// records, folds them into the state, and does this person's part —
/// co-signing, voting, counting the branch, signing payments as a
/// treasurer, reports.
final class PyramidService extends ChangeNotifier {
  PyramidService({
    required this.host,
    required this.disk,
    this.crisisBroadcast,
    this.friendsOf,
    this.friendLevelOf,
    this.identitySeed,
    PyramidRoot? root,
    this.otherDevices,
    this.resharePost,
    this.ownPublicPosts,
    this.nationalitiesOf,
    this.myNationalities,
    int Function()? now,
    Random? random,
    this.tallyWait = const Duration(hours: 6),
    int recordSegmentEntries = kPyrLogSegmentEntries,
  }) : root = root ?? zenPyramidRoot,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure(),
       _log = PyramidRecordLog(
         disk,
         prefix: _keyRecords,
         segmentEntries: recordSegmentEntries,
       ) {
    _keepGenesis();
  }

  final EventHost host;
  final LedgerDisk disk;

  /// Friends' friend lists (address → name), when they share them: tells
  /// a friend of a friend from a stranger for market prices.
  final Map<String, String> Function(String friend)? friendsOf;

  /// This person's private level for the friend at an address: a
  /// newcomer is admitted only at "Znajomy" or above. Null: not
  /// known here (tests, no ledger), so only friendship is checked.
  final FriendLevel? Function(String address)? friendLevelOf;

  /// The seed of this person's pyramid key, derived from the account key:
  /// the same on every device of the account and after recovery.
  /// By default the one of the ledger identity on [disk]; null while there
  /// is none.
  final Future<Uint8List?> Function()? identitySeed;

  /// The one pyramid this phone keeps ([zenPyramidRoot] unless given):
  /// records of any other are never taken nor passed on. Null while the
  /// original pyramid is not pinned yet.
  final PyramidRoot? root;

  /// Addresses of this account's other devices: they share the pyramid key
  /// ([identitySeed]), so pyramid traffic going to one of them is not taken
  /// over by this device (they would take turns for ever).
  final Iterable<String> Function()? otherDevices;

  /// Sends a crisis wave over Bluetooth to phones around.
  final Future<int> Function(Map<String, dynamic> wave)? crisisBroadcast;

  /// Shares a signed public post (a reshare on order) with this
  /// person's friends, as their own reshare in the feed; true when done.
  /// Null (tests without a ledger): such an order cannot be accepted.
  final Future<bool> Function(Map<String, dynamic> post)? resharePost;

  /// This person's own public posts (signed entries, newest first): what
  /// they can order a reshare of.
  final List<Map<String, dynamic>> Function()? ownPublicPosts;

  /// The nationalities a friend's profile shows this device, by
  /// address: a member passes the section of those on to them.
  /// Null: nothing is passed on.
  final List<String> Function(String address)? nationalitiesOf;

  /// The nationalities in this person's own profile: the national
  /// sections it reads, member or not.
  final List<String> Function()? myNationalities;

  /// How long a cell head waits for the sums below before counting anyway.
  final Duration tallyWait;
  final int Function() _now;
  final Random _random;
  static const String _keyMe = 'pyramid/me';
  static const String _keyRecords = 'pyramid/records';

  /// Reports and appeals others sent here, apart from the rest: a
  /// flood of them can never make [_keyMe] too big to save.
  static const String _keyReports = 'pyramid/reports';

  /// Ring signatures already checked (their cache keys), so a restart does
  /// not redo minutes of curve arithmetic on a slow phone.
  static const String _keyRingOk = 'pyramid/ring-ok';

  /// Pyramid posts friends passed on, apart from the rest.
  static const String _keyNational = 'pyramid/national';

  /// Pyramid posts read from outside, passed on by friends who are
  /// members: id → post, at most [kPyrNationalKept] per nationality of this
  /// person's profile and of the top.
  final Map<String, PyrNationalPost> _nationalFeed =
      <String, PyrNationalPost>{};

  /// The records: an append-only log in segments under `pyramid/records/`
  /// (a new record writes one segment, not all of them).
  final PyramidRecordLog _log;

  /// Records kept (or merged with more signatures) since they were last
  /// written to the log.
  final Set<String> _recordsUnsaved = <String>{};

  /// The log does not hold what memory holds (a write failed halfway): the
  /// next save writes them all afresh.
  bool _recordsRewrite = false;

  /// Record writes run one after another (each reads the log's end first).
  Future<void> _recordsWriting = Future<void>.value();

  LedgerKeyPair? _identity;
  Uint8List? _seed;

  /// Private data confirmed at entry: birth year, gender, salt.
  Map<String, dynamic> myData = <String, dynamic>{};

  /// The id of the pyramid ([root]), or null without one.
  String? get current => root?.id;

  /// The seed of the power key this person holds as the head (the
  /// founder's, or one handed over to them), and the one made for a
  /// handover still waiting.
  Uint8List? _powerSeed;
  Uint8List? _powerNext;

  /// The public keys of [_powerSeed] and [_powerNext].
  String? _powerId;
  String? _powerNextId;

  /// When the handover waiting was last sent round.
  int _handoverSentAt = 0;
  final Map<String, PyramidRecord> _records = <String, PyramidRecord>{};
  final Map<String, Set<String>> _tsigs = <String, Set<String>>{};
  final Map<String, Set<String>> _peers = <String, Set<String>>{};
  final Map<String, PyrProposal> proposals = <String, PyrProposal>{};
  final Map<String, PyramidRecord> _mine = <String, PyramidRecord>{};
  final Map<String, int> _mineNeed = <String, int>{};
  final Map<String, Map<String, int>> _headVotes = <String, Map<String, int>>{};
  final Map<String, Set<String>> _extraVotes = <String, Set<String>>{};
  final Map<String, int> myVotes = <String, int>{};
  final Map<String, String> _tallySent = <String, String>{};
  final Map<String, String> _signedOrders = <String, String>{};
  final Map<String, PyramidRecord> _payments = <String, PyramidRecord>{};
  final Map<String, PyrReport> inbox = <String, PyrReport>{};
  final Map<String, PyrReport> myReports = <String, PyrReport>{};

  /// Appeals to the top: {rep, t, k, at, f} (report, text, member key, when
  /// received, sender device).
  final List<Map<String, dynamic>> appeals = <Map<String, dynamic>>[];

  /// Appeals this person sent (the matter's id → when): an appeal is made
  /// once, and the screen shows that it is on its way.
  final Map<String, int> sentAppeals = <String, int>{};
  final Map<String, PyrMarketMessage> market = <String, PyrMarketMessage>{};

  final Set<String> _announced = <String>{};

  /// Crisis waves already handled (the newest few hundred, kept).
  final Set<String> _crisisSeen = <String>{};

  /// Since when this phone keeps the pyramid's records (this phone's
  /// time): it is a member or joining; null — it takes none.
  int? _followSince;

  /// What this person has signed (the body without its time → until
  /// when): a fresh copy of the same proposal is signed again without
  /// asking, so late approvals never publish a record dated in the past.
  final Map<String, int> _consent = <String, int>{};

  /// Records of [PyrT.timed] this phone first saw late (id → when seen,
  /// [kPyrLateMs]): their waits and limits count from then here
  /// ([PyramidState.fold]).
  final Map<String, int> _late = <String, int>{};

  /// When this run of the app took each record in (those read from disk
  /// count as long kept).
  final Map<String, int> _keptAt = <String, int>{};

  /// Anonymous sums from the members right below: topic
  /// ([kPyrStatsTopic], or 'r|' + a post id) → member → their branch's
  /// numbers.
  final Map<String, Map<String, List<int>>> _sumsBelow =
      <String, Map<String, List<int>>>{};

  /// What this person last sent up, per topic (sent again only changed).
  final Map<String, List<int>> _sumsSent = <String, List<int>>{};

  /// Political posts this person opened (id → when), for "przeczytało".
  final Map<String, int> _readPosts = <String, int>{};

  /// Market messages whose payment has not arrived yet.
  final List<Map<String, dynamic>> _marketHeld = <Map<String, dynamic>>[];
  bool _retryingHeld = false;

  /// When a waiting order was last sent to the treasurers again.
  final Map<String, int> _resentAt = <String, int>{};

  /// Fresh copies made of each proposal (by content), automatically.
  final Map<String, int> _redates = <String, int>{};

  /// Frames per sender in the current window.
  final Map<String, ({int start, int count})> _rate =
      <String, ({int start, int count})>{};
  PyramidState? _state;
  int _stateAt = 0;
  Future<void> _queue = Future<void>.value();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);
  int get now => _now();

  String? get myKey => _identity?.id;
  bool get hasIdentity => _identity != null;

  String _newId([int n = 12]) => List<String>.generate(
    n,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  // ---- state ----

  /// Whether this phone keeps record [id] (tests: what got in).
  @visibleForTesting
  bool keeps(String id) => _records.containsKey(id);

  /// This phone's copy of record [id] (tests).
  @visibleForTesting
  PyramidRecord? recordOf(String id) => _records[id];

  /// Ids of the records this phone keeps (tests).
  @visibleForTesting
  List<String> get recordIds => _records.keys.toList();

  /// Entries in the record log on disk, as last read or written (tests).
  @visibleForTesting
  int get recordLogEntries => _log.entryCount;

  /// [r] signed with this person's pyramid key, published nowhere (tests:
  /// what a modified app could sign).
  @visibleForTesting
  Future<PyramidRecord> signAsMe(PyramidRecord r) async =>
      r.signedBy(await _ensureIdentity());

  /// The pyramid folded from the records this phone keeps (always with
  /// the pinned genesis), or null without a [root].
  PyramidState? _fold() {
    final PyramidRoot? r = root;
    return r == null
        ? null
        : PyramidState.fold(
            r.id,
            _records.values,
            now: _now(),
            treasurerSigs: _tsigs,
            late: _late,
          );
  }

  /// The pyramid, folded (again once a minute at most).
  PyramidState? get state {
    if (root == null) {
      return null;
    }
    if (_state == null || _now() - _stateAt > 60 * 1000) {
      _state = _fold();
      _stateAt = _now();
    }
    return _state;
  }

  bool get isMember {
    final String? k = myKey;
    return k != null && (state?.isMember(k) ?? false);
  }

  void _dirty() {
    _state = null;
  }

  // ---- storage ----

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      await _loadIdentity();
      final List<int>? raw = await disk.read(_keyMe);
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        myData = json['data'] is Map
            ? Map<String, dynamic>.from(json['data'] as Map)
            : <String, dynamic>{};
        await _setPower(unb64(json['pw'], length: 32));
        await _setPowerNext(unb64(json['pwn'], length: 32));
        proposals.clear();
        if (json['props'] is List) {
          for (final Object? p in json['props'] as List) {
            final PyrProposal? x = PyrProposal.fromJson(p);
            if (x != null) {
              proposals[x.record.id] = x;
            }
          }
        }
        _headVotes
          ..clear()
          ..addAll(<String, Map<String, int>>{
            if (json['hv'] is Map)
              for (final MapEntry<dynamic, dynamic> e
                  in (json['hv'] as Map).entries)
                if (e.key is String && e.value is Map)
                  e.key as String: <String, int>{
                    for (final MapEntry<dynamic, dynamic> v
                        in (e.value as Map).entries)
                      if (v.key is String && v.value is int)
                        v.key as String: v.value as int,
                  },
          });
        _extraVotes
          ..clear()
          ..addAll(<String, Set<String>>{
            if (json['xv'] is Map)
              for (final MapEntry<dynamic, dynamic> e
                  in (json['xv'] as Map).entries)
                if (e.key is String && e.value is List)
                  e.key as String: (e.value as List)
                      .whereType<String>()
                      .toSet(),
          });
        myVotes
          ..clear()
          ..addAll(_ints(json['mv']));
        _tallySent
          ..clear()
          ..addAll(_strs(json['ts']));
        _signedOrders
          ..clear()
          ..addAll(_strs(json['so']));
        sentAppeals
          ..clear()
          ..addAll(_ints(json['apl']));
        myReports.clear();
        if (json['rep'] is List) {
          for (final Object? r in json['rep'] as List) {
            final PyrReport? x = PyrReport.fromJson(r);
            if (x != null) {
              myReports[x.id] = x;
            }
          }
        }
        market.clear();
        if (json['mk'] is List) {
          for (final Object? m in json['mk'] as List) {
            final PyrMarketMessage? x = PyrMarketMessage.fromJson(m);
            if (x != null) {
              market[x.id] = x;
            }
          }
        }
        _announced
          ..clear()
          ..addAll(
            json['ann'] is List
                ? (json['ann'] as List).whereType<String>()
                : const <String>[],
          );
        _crisisSeen
          ..clear()
          ..addAll(
            json['cr'] is List
                ? (json['cr'] as List).whereType<String>()
                : const <String>[],
          );
        _followSince = json['fol'] is int ? json['fol'] as int : null;
        _consent
          ..clear()
          ..addAll(_ints(json['cs']));
        _late
          ..clear()
          ..addAll(_ints(json['le']));
        _payments.clear();
        // Sent again soon after a start (the treasurers may have missed it).
        _resentAt.clear();
        if (json['pay'] is List) {
          for (final Object? item in json['pay'] as List) {
            final PyramidRecord? r = PyramidRecord.fromJson(item);
            if (r != null && PyrT.treasured.contains(r.type)) {
              _payments[r.id] = r;
            }
          }
        }
        _marketHeld
          ..clear()
          ..addAll(
            json['mh'] is List
                ? (json['mh'] as List).whereType<Map<dynamic, dynamic>>().map(
                    Map<String, dynamic>.from,
                  )
                : const <Map<String, dynamic>>[],
          );
        _sumsBelow.clear();
        if (json['sb'] is Map) {
          for (final MapEntry<dynamic, dynamic> e
              in (json['sb'] as Map).entries) {
            if (e.key is String && e.value is Map) {
              _sumsBelow[e.key as String] = <String, List<int>>{
                for (final MapEntry<dynamic, dynamic> k
                    in (e.value as Map).entries)
                  if (k.key is String && k.value is List)
                    k.key as String: (k.value as List)
                        .whereType<int>()
                        .toList(),
              };
            }
          }
        }
        _sumsSent.clear();
        if (json['ss'] is Map) {
          for (final MapEntry<dynamic, dynamic> e
              in (json['ss'] as Map).entries) {
            if (e.key is String && e.value is List) {
              _sumsSent[e.key as String] = (e.value as List)
                  .whereType<int>()
                  .toList();
            }
          }
        }
        _readPosts
          ..clear()
          ..addAll(_ints(json['rd']));
      }
      final List<Object?>? logged = await _log.readAll();
      try {
        final List<int>? rawOk = await disk.read(_keyRingOk);
        final Object? oks = rawOk == null
            ? null
            : jsonDecode(utf8.decode(rawOk));
        final Object? keys = oks is Map ? oks['k'] : null;
        final String? mac = keys is List ? _ringOkMac(keys) : null;
        // Taken only with this phone's MAC: a planted list of "already
        // verified" signatures would let forged records through.
        if (keys is List && mac != null && oks is Map && oks['m'] == mac) {
          for (final Object? k in keys) {
            if (k is String && k.length == 64) {
              RingSignature.remember(k, true);
            }
          }
        }
      } on Object {
        // Only a cache: the checks are simply done again.
      }
      // Reports and appeals from others: their own key.
      final List<int>? rawReports = await disk.read(_keyReports);
      Object? reportsJson;
      if (rawReports != null) {
        try {
          reportsJson = jsonDecode(utf8.decode(rawReports));
        } on Object {
          // Unreadable: they start again from nothing.
          reportsJson = null;
        }
      }
      _readReports(reportsJson);
      _nationalFeed.clear();
      _nationalRevision++;
      final List<int>? rawNational = await disk.read(_keyNational);
      try {
        final Object? national = rawNational == null
            ? null
            : jsonDecode(utf8.decode(rawNational));
        if (national is List) {
          // Signed when they came; the limits apply again.
          for (final Object? item in national.take(4 * kPyrNationalKept)) {
            final PyrNationalPost? p = PyrNationalPost.fromJson(item);
            if (p != null) {
              _nationalFeed[p.id] = p;
            }
          }
        }
      } on Object {
        // Unreadable: friends pass them on again.
        _nationalFeed.clear();
      }
      _diskUnreadable = false;
      if (logged != null) {
        _records.clear();
        // The pinned genesis first, as on a fresh start.
        _keepGenesis();
        // In order:a record appended again later (with more signatures)
        // replaces its earlier entry and keeps its place.
        for (final Object? item in logged) {
          if (item is! Map) {
            continue;
          }
          final PyramidRecord? r = PyramidRecord.fromJson(item['r']);
          if (r != null && r.type != PyrT.genesis && r.pyramid == current) {
            _records[r.id] = r;
            // Checked when it came: its keys check what members sign next.
            r.fileKeys();
            if (item['tv'] is List) {
              _tsigs[r.id] = (item['tv'] as List).whereType<String>().toSet();
            }
          }
        }
        // Memory is what is on disk now.
        _recordsUnsaved.clear();
        _recordsRewrite = false;
      }
      _keepGenesis();
      _dirty();
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt piramidy', error, stack);
    }
  }

  /// The pinned genesis is always among the records (never written to the
  /// log: it is in the app).
  void _keepGenesis() {
    final PyramidRoot? r = root;
    if (r != null) {
      _records[r.id] = r.genesis;
      r.genesis.fileKeys();
    }
  }

  static Map<String, int> _ints(Object? json) => <String, int>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
  };

  static Map<String, String> _strs(Object? json) => <String, String>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
  };

  /// Reports and appeals as stored under [_keyReports] (limits applied
  /// again, whatever is on disk).
  void _readReports(Object? json) {
    inbox.clear();
    appeals.clear();
    if (json is! Map) {
      return;
    }
    if (json['in'] is List) {
      for (final Object? item in json['in'] as List) {
        final PyrReport? r = item is Map
            ? _cleanReport(Map<String, dynamic>.from(item), item['f'])
            : null;
        if (r != null) {
          inbox[r.id] = r;
        }
      }
    }
    if (json['ap'] is List) {
      for (final Object? item in json['ap'] as List) {
        final Map<String, dynamic>? a = item is Map ? _cleanAppeal(item) : null;
        if (a != null) {
          appeals.add(a);
        }
      }
    }
    _trimReports();
    _trimAppeals();
  }

  Future<void> _saveReports() async {
    if (_diskUnreadable) {
      return;
    }
    await disk.write(
      _keyReports,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'in': <Map<String, dynamic>>[
            for (final PyrReport r in inbox.values) r.toJson(),
          ],
          'ap': appeals,
        }),
      ),
    );
  }

  Future<void> _save({bool records = false}) async {
    if (_diskUnreadable) {
      return;
    }
    await disk.write(
      _keyMe,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'data': myData,
          if (_powerSeed != null) 'pw': b64(_powerSeed!),
          if (_powerNext != null) 'pwn': b64(_powerNext!),
          'props': <Map<String, dynamic>>[
            for (final PyrProposal p in proposals.values) p.toJson(),
          ],
          'hv': _headVotes,
          'xv': <String, List<String>>{
            for (final MapEntry<String, Set<String>> e in _extraVotes.entries)
              e.key: e.value.toList(),
          },
          'mv': myVotes,
          'ts': _tallySent,
          'so': _signedOrders,
          'rep': <Map<String, dynamic>>[
            for (final PyrReport r in myReports.values) r.toJson(),
          ],
          'apl': sentAppeals,
          'ann': _announced.toList(),
          'mk': <Map<String, dynamic>>[
            for (final PyrMarketMessage m in market.values) m.toJson(),
          ],
          'cr': _crisisSeen.toList(),
          'fol': ?_followSince,
          'cs': _consent,
          'le': _late,
          // Orders waiting for treasurers survive a restart and are sent
          // again as they are (a new order would need a number some
          // treasurers have already promised to this one).
          'pay': <Map<String, dynamic>>[
            for (final PyramidRecord r in _payments.values) r.toJson(),
          ],
          'mh': _marketHeld,
          'sb': _sumsBelow,
          'ss': _sumsSent,
          'rd': _readPosts,
        }),
      ),
    );
    if (records) {
      final List<String> trusted = RingSignature.trustedKeys;
      final String? mac = _ringOkMac(trusted);
      if (mac != null) {
        await disk.write(
          _keyRingOk,
          utf8.encode(jsonEncode(<String, Object>{'k': trusted, 'm': mac})),
        );
      }
      await _saveRecords();
    }
    notifyListeners();
  }

  /// Writes the records kept since the last write (one batch, one write of
  /// the log's last segment), queued behind any write still running.
  Future<void> _saveRecords() {
    final Future<void> run = _recordsWriting.then((_) => _writeRecords());
    _recordsWriting = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Appends the records changed since the last write to the log; writes
  /// all of them afresh instead when the log does not hold what memory
  /// holds, or has grown past twice the records (each change of a record
  /// is one more entry) — rare.
  Future<void> _writeRecords() async {
    if (_diskUnreadable) {
      return;
    }
    final List<String> ids = <String>[
      for (final String id in _recordsUnsaved)
        if (_records.containsKey(id)) id,
    ];
    final int entries = _log.entryCount + ids.length;
    final bool rewrite =
        _recordsRewrite ||
        (entries > 2 * _records.length && entries > _log.segmentEntries);
    if (!rewrite && ids.isEmpty) {
      return;
    }
    // Taken now: a record changed while this is written is marked again.
    final List<Object?> batch = rewrite
        ? <Object?>[
            for (final PyramidRecord r in _records.values) _recordEntry(r),
          ]
        : <Object?>[for (final String id in ids) _recordEntry(_records[id]!)];
    if (rewrite) {
      _recordsUnsaved.clear();
    } else {
      _recordsUnsaved.removeAll(ids);
    }
    _recordsRewrite = false;
    try {
      if (rewrite) {
        await _log.rewrite(batch);
      } else {
        await _log.append(batch);
      }
    } on Object {
      // How much got in is not known: everything is written afresh next time.
      _recordsRewrite = true;
      rethrow;
    }
  }

  Map<String, dynamic> _recordEntry(PyramidRecord r) => <String, dynamic>{
    'r': r.toJson(),
    if (_tsigs[r.id] != null) 'tv': _tsigs[r.id]!.toList(),
  };

  /// The pyramid key from the account's seed, when there is one.
  Future<void> _loadIdentity() async {
    if (_identity != null) {
      return;
    }
    final Uint8List? seed = identitySeed != null
        ? await identitySeed!()
        : (await LedgerIdentity.read(disk))?.pyramidSeed;
    if (seed == null || seed.length != 32 || _identity != null) {
      return;
    }
    _seed = seed;
    _identity = await LedgerKeyPair.fromSeed(seed);
  }

  Future<LedgerKeyPair> _ensureIdentity() async {
    await _loadIdentity();
    final LedgerKeyPair? k = _identity;
    if (k == null) {
      throw StateError(t('Brak klucza konta na tym urządzeniu.'));
    }
    return k;
  }

  // ---- records in and out ----

  /// Keeps the pyramid's records from now on (this phone joins or
  /// founds it, or another device of the account is in it).
  void _follow() {
    _followSince ??= _now();
  }

  /// Takes a record (own or someone's): checks it, keeps it and passes it
  /// on to the pyramid's people. Returns whether it was new (or brought new
  /// signatures).
  Future<bool> ingest(
    PyramidRecord r, {
    String? from,
    bool spread = true,
  }) async => (await _ingestAll(
    <PyramidRecord>[r],
    from: from,
    spread: spread,
  )).isNotEmpty;

  /// Takes records in one go: each is checked (cheap checks first) and kept,
  /// then the pyramid is folded, saved and passed on once — not once per
  /// record.
  Future<List<PyramidRecord>> _ingestAll(
    List<PyramidRecord> rs, {
    String? from,
    bool spread = true,
  }) async {
    final List<PyramidRecord> added = <PyramidRecord>[];
    PyramidState? before;
    bool folded = false;
    Future<void> take(PyramidRecord r) async {
      final PyramidRecord? kept = await _check(r);
      if (kept == null) {
        return;
      }
      if (!folded) {
        before = state;
        folded = true;
      }
      _keep(kept);
      added.add(kept);
    }

    // Records that publish keys first: a batch may bring an admission
    // together with what the newcomer signed since.
    for (final PyramidRecord r in <PyramidRecord>[
      ...rs.where((PyramidRecord x) => x.signsWithKeys),
      ...rs.where((PyramidRecord x) => !x.signsWithKeys),
    ]) {
      if (r.lacksKeys) {
        _awaitKeys(r);
        continue;
      }
      await take(r);
    }
    // What waited for a key that came now (never taken unchecked).
    while (added.isNotEmpty) {
      final List<PyramidRecord> ready = <PyramidRecord>[
        for (final PyramidRecord w in _awaitingKeys.values)
          if (!w.lacksKeys) w,
      ];
      if (ready.isEmpty) {
        break;
      }
      for (final PyramidRecord r in ready) {
        _awaitingKeys.remove(r.id);
        await take(r);
      }
    }
    if (added.isEmpty) {
      return added;
    }
    _dirty();
    await _save(records: true);
    if (spread) {
      for (final PyramidRecord x in added) {
        await _spread(x, except: from);
      }
      await _passNational(added);
      // A newcomer this person vouched for gets the whole pyramid (from a
      // friend: the head of the cell chosen for them may be a stranger).
      for (final PyramidRecord x in added) {
        final Object? m = x.body['m'];
        if (x.type == PyrT.admit &&
            x.str('sp') == myKey &&
            m is Map &&
            m['addr'] is String) {
          await sendAll(m['addr'] as String, x.pyramid);
        }
      }
    }
    await _afterChange(before);
    return added;
  }

  /// The newest time among the records this phone took in by [until]: what
  /// it surely had then. A sync that brings old and new records together
  /// (a phone back after a while away) makes none of them late.
  int _keptBefore(int until) {
    int newest = 0;
    for (final PyramidRecord x in _records.values) {
      if (x.at > newest && (_keptAt[x.id] ?? 0) <= until) {
        newest = x.at;
      }
    }
    return newest;
  }

  /// Stores a checked record: published, so nothing more to sign or to
  /// wait for — also no other copy of the same content.
  void _keep(PyramidRecord r) {
    final int t = _now();
    final PyramidRecord? had = _records[r.id];
    if (had == null &&
        PyrT.timed.contains(r.type) &&
        r.at < _keptBefore(t - kPyrLateMs) - kPyrLateMs) {
      // Dated well before records this phone already had for a while:
      // late — back-dated past its wait, or held back. Its wait counts from
      // now here.
      _late[r.id] = max(t, r.at);
    }
    _keptAt.putIfAbsent(r.id, () => t);
    _records[r.id] = r;
    r.fileKeys();
    _recordsUnsaved.add(r.id);
    if (PyrT.treasured.contains(r.type)) {
      _tsigs[r.id] = r.tsigs.keys.toSet();
    }
    final String content = _contentKey(r);
    _consent.remove(content);
    proposals.removeWhere(
      (String id, PyrProposal p) =>
          id == r.id || _contentKey(p.record) == content,
    );
    final List<String> stale = <String>[
      for (final MapEntry<String, PyramidRecord> e in _mine.entries)
        if (e.key == r.id ||
            (e.value.type != PyrT.transfer && _contentKey(e.value) == content))
          e.key,
    ];
    for (final String id in stale) {
      _mine.remove(id);
      _mineNeed.remove(id);
    }
  }

  /// Records whose signatures name ML-DSA keys this phone does not hold
  /// yet (the admission or handover that publishes them has not come), by
  /// id: checked once it has; the oldest go past [kPyrAwaitingKeys] (sync
  /// brings them again).
  final Map<String, PyramidRecord> _awaitingKeys = <String, PyramidRecord>{};

  void _awaitKeys(PyramidRecord r) {
    _awaitingKeys.remove(r.id);
    _awaitingKeys[r.id] = r;
    while (_awaitingKeys.length > kPyrAwaitingKeys) {
      _awaitingKeys.remove(_awaitingKeys.keys.first);
    }
  }

  /// The checked record to keep — merged with the copy already here — or
  /// null. In order of cost: not from the future, of a pyramid this phone
  /// keeps, then signatures one by one (only the valid ones are kept, so a
  /// bad copy never blocks a good one), then a ring signature against its
  /// ring.
  Future<PyramidRecord?> _check(PyramidRecord r) async {
    final int t = _now();
    if (r.at > t + kPyrMaxSkewMs) {
      // Dated ahead: it would wait here as a time bomb. It comes again
      // with sync once it is due.
      return null;
    }
    // Only the pinned pyramid, and only while this phone keeps it; its
    // genesis is in the app, never taken from anybody.
    if (r.type == PyrT.genesis ||
        current == null ||
        r.pyramid != current ||
        _followSince == null) {
      return null;
    }
    final PyramidRecord? had = _records[r.id];
    if (PyrT.anonymous.contains(r.type)) {
      await _verifyRingInBackground(r);
      // Anonymous: no signatures, a ring signature that holds (a copy whose
      // ring holds replaces one kept here whose ring does not).
      if (r.sigs.isNotEmpty ||
          r.ring == null ||
          (had != null && _ringOk(had)) ||
          !_ringOk(r)) {
        return null;
      }
      return PyramidRecord(body: r.body, ring: r.ring);
    }
    if (r.ring != null) {
      return null;
    }
    final Map<String, String> ok = await PyramidRecord(
      body: r.body,
      sigs: <String, String>{
        for (final MapEntry<String, String> e in r.sigs.entries)
          if (had == null || !had.sigs.containsKey(e.key)) e.key: e.value,
      },
    ).validSigs();
    Map<String, String> tok = const <String, String>{};
    if (PyrT.treasured.contains(r.type)) {
      final Set<String> known = _tsigs[r.id] ?? const <String>{};
      tok = await PyramidRecord(
        body: r.body,
        tsigs: <String, String>{
          for (final MapEntry<String, String> e in r.tsigs.entries)
            if (!known.contains(e.key)) e.key: e.value,
        },
      ).validTreasurerSigMap();
    }
    if (had == null) {
      return ok.isEmpty
          ? null
          : PyramidRecord(body: r.body, sigs: ok, tsigs: tok);
    }
    if (ok.isEmpty && tok.isEmpty) {
      return null;
    }
    final Set<String> known = _tsigs[had.id] ?? const <String>{};
    return PyramidRecord(
      body: had.body,
      sigs: <String, String>{...had.sigs, ...ok},
      tsigs: <String, String>{
        for (final MapEntry<String, String> e in had.tsigs.entries)
          if (known.contains(e.key)) e.key: e.value,
        ...tok,
      },
    );
  }

  /// Whether an anonymous record's ring signature holds against its ring:
  /// a request names its cell, a vote is checked against the request it
  /// belongs to (which must be here first; sync brings it). The result is
  /// remembered for the folds.
  ({
    RingSignature ring,
    List<Uint8List> points,
    String context,
    List<int> message,
  })?
  _ringInput(PyramidRecord r) {
    final RingSignature? ring = r.ring;
    if (ring == null) {
      return null;
    }
    final Object? keys;
    final String context;
    if (r.type == PyrT.voteRequest) {
      keys = r.body['ring'];
      context = PyramidState.voteRequestContext(
        r.pyramid,
        r.str('cell'),
        r.str('head'),
      );
    } else {
      final PyramidRecord? request = _records[r.str('elect')];
      if (request == null ||
          request.type != PyrT.voteRequest ||
          request.pyramid != r.pyramid) {
        return null;
      }
      keys = request.body['ring'];
      context = PyramidState.voteContext(request.id);
    }
    if (keys is! List || keys.isEmpty || keys.length > RingSignature.maxRing) {
      return null;
    }
    final List<Uint8List> points = <Uint8List>[];
    for (final Object? k in keys) {
      if (!PyramidRecord.isCanonicalKey(k)) {
        return null;
      }
      points.add(unb64(k, length: 32)!);
    }
    return (
      ring: ring,
      points: points,
      context: context,
      message: r.signedBytes,
    );
  }

  /// MAC of the cache of verified ring signatures, keyed with a secret of
  /// this phone (derived from the pyramid identity seed); null without one.
  String? _ringOkMac(List<Object?> keys) {
    final Uint8List? seed = _seed;
    if (seed == null) {
      return null;
    }
    final List<int> macKey = crypto.Hmac(
      crypto.sha256,
      seed,
    ).convert(utf8.encode('zen.pyramid.ring-ok')).bytes;
    return crypto.Hmac(
      crypto.sha256,
      macKey,
    ).convert(utf8.encode(jsonEncode(keys))).toString();
  }

  bool _ringOk(PyramidRecord r) {
    final ({
      RingSignature ring,
      List<Uint8List> points,
      String context,
      List<int> message,
    })?
    input = _ringInput(r);
    return input != null &&
        input.ring.verify(
          ring: input.points,
          context: input.context,
          message: input.message,
        );
  }

  /// Works out a new ring signature off the UI thread (the curve
  /// arithmetic takes long on a phone), so the checks that follow find the
  /// answer ready.
  Future<void> _verifyRingInBackground(PyramidRecord r) async {
    final ({
      RingSignature ring,
      List<Uint8List> points,
      String context,
      List<int> message,
    })?
    input = _ringInput(r);
    if (input == null) {
      return;
    }
    final String key = input.ring.cacheKeyFor(
      input.points,
      input.context,
      input.message,
    );
    if (RingSignature.known(key) != null) {
      return;
    }
    try {
      final RingSignature ring = input.ring;
      final List<Uint8List> points = input.points;
      final String context = input.context;
      final List<int> message = input.message;
      final bool ok = await Isolate.run(
        () => ring.verify(ring: points, context: context, message: message),
      );
      RingSignature.remember(key, ok);
    } on Object {
      // Left to the synchronous check.
    }
  }

  /// The content of a record without its time: the same proposal signed
  /// again later is the same content.
  static String _contentKey(PyramidRecord r) => r.contentKey;

  /// Friends who keep the same pyramid (announced, or members by address).
  List<String> _pyramidFriends(String py) {
    final Set<String> out = <String>{};
    final PyramidState? s = py == current ? state : null;
    final Set<String> memberAddrs = <String>{
      if (s != null)
        for (final PyrMember m in s.members.values)
          if (m.addr.isNotEmpty) _n(m.addr),
    };
    for (final String f in host.friends()) {
      final String a = _n(f);
      if ((_peers[a]?.contains(py) ?? false) || memberAddrs.contains(a)) {
        out.add(a);
      }
    }
    return out.toList()..sort();
  }

  Future<void> _spread(PyramidRecord r, {String? except}) async {
    final String py = r.type == PyrT.genesis ? r.id : r.pyramid;
    for (final String f in _pyramidFriends(py)) {
      if (f != except) {
        await _send(f, <String, dynamic>{
          'type': PyramidTypes.record,
          'r': r.toJson(),
        });
      }
    }
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    if (to.isEmpty || _n(to) == _n(host.ownAddress())) {
      return;
    }
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Piramida: ${payload['type']} do $to: $error');
    }
  }

  /// Records of [py] in buckets by the first character of the id.
  Map<String, List<String>> _buckets(String py) {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final PyramidRecord r in _records.values) {
      if (r.id == py || r.pyramid == py) {
        (out[r.id.substring(0, 1)] ??= <String>[]).add(r.id);
      }
    }
    return out;
  }

  /// What this phone has of [r] besides its id: who signed it and which
  /// treasurer signatures hold. In the sync digest, so a copy with fewer
  /// signatures (e.g. passed on stripped) gets repaired.
  String _fp(PyramidRecord r) => sha256Hex(
    utf8.encode(
      '${(r.sigs.keys.toList()..sort()).join(',')}|'
      '${((_tsigs[r.id] ?? const <String>{}).toList()..sort()).join(',')}',
    ),
  ).substring(0, 8);

  Map<String, String> _digest(String py) => <String, String>{
    for (final MapEntry<String, List<String>> e in _buckets(py).entries)
      e.key: sha256Hex(
        utf8.encode(
          (e.value..sort())
              .map((String id) => '$id:${_fp(_records[id]!)}')
              .join(','),
        ),
      ).substring(0, 16),
  };

  /// Says hello to friends (on start, every few hours, to a new friend).
  Future<void> greet({Iterable<String>? to}) async {
    // The pyramid, while this phone keeps it.
    final List<String> pys = <String>[
      if (current != null && _followSince != null) current!,
    ];
    // A reader from outside: the newest it has of each kind.
    final Map<String, int> since = _nationalSince(top: false);
    final Map<String, int> topSince = _nationalSince(top: true);
    for (final String f in to ?? host.friends()) {
      await _send(f, <String, dynamic>{
        'type': PyramidTypes.hello,
        'py': <Map<String, dynamic>>[
          for (final String py in pys)
            <String, dynamic>{'id': py, 'd': _digest(py)},
        ],
        if (since.isNotEmpty) 'nf': since,
        if (topSince.isNotEmpty) 'tf': topSince,
      });
    }
  }

  /// Sends everything of [py] to [to] (after admitting them).
  Future<void> sendAll(String to, String py) async {
    final List<PyramidRecord> list = <PyramidRecord>[
      for (final PyramidRecord r in _records.values)
        if (r.id == py || r.pyramid == py) r,
    ]..sort((PyramidRecord a, PyramidRecord b) => a.at.compareTo(b.at));
    final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
      for (final PyramidRecord r in list) r.toJson(),
    ];
    for (final List<Map<String, dynamic>> frame in _recordFrames(all)) {
      await _send(to, <String, dynamic>{
        'type': PyramidTypes.records,
        'rs': frame,
      });
    }
  }

  // ---- identity, joining ----

  static String dataCommit(int birthYear, String gender, String salt) =>
      pyrDataCommit(birthYear, gender, salt);

  /// At most [n] UTF-16 units, never cutting an emoji in half (a lone
  /// half would make the record unreadable for everybody else).
  static String _cut(String s, int n) {
    if (s.length <= n) {
      return s;
    }
    final int end =
        s.codeUnitAt(n - 1) >= 0xD800 && s.codeUnitAt(n - 1) <= 0xDBFF
        ? n - 1
        : n;
    return s.substring(0, end);
  }

  Map<String, dynamic> _memberJson(LedgerKeyPair me, String name, String nat) =>
      <String, dynamic>{
        'k': me.id,
        // The ML-DSA half of the key, fixed for good by the admission.
        'pq': me.pqId,
        'n': _cut(name.trim(), 40),
        'nat': nat.trim().toUpperCase(),
        // Public to the pyramid, confirmed by the admitting signature.
        'yr': myData['by'],
        'dc': myData['dc'],
        'addr': _n(host.ownAddress()),
      };

  /// The birth year is required at entry, any plausible one
  /// ([pyrBirthYearValid]): minors are admitted, age is never a condition.
  void _setData(int birthYear, String gender) {
    if (!pyrBirthYearValid(birthYear, _now())) {
      throw ArgumentError.value(birthYear, 'birthYear', 'not a birth year');
    }
    final String salt = _newId(16);
    myData = <String, dynamic>{
      'by': birthYear,
      'g': gender,
      'salt': salt,
      'dc': dataCommit(birthYear, gender, salt),
    };
  }

  /// Whether the pyramid is still empty: its first head founds it with
  /// the power key of the genesis ([found]).
  bool get canFound {
    final PyramidState? s = state;
    return s != null && s.position.isEmpty;
  }

  /// Whether founding needs the power key pasted in: the original pyramid
  /// (the test pyramid's key is public).
  bool get foundNeedsKey => root?.powerSeed == null;

  /// Seats this person as the first head of the pinned pyramid, while
  /// nobody is in it, signed with its power key: [powerSecret] (the seed
  /// the founder got from `tool/zen_pyramid.dart genesis`) or the test
  /// pyramid's own. This person then holds the power key. Returns the
  /// pyramid's id, or null when the key does not fit.
  Future<String?> found({
    required String myName,
    required String nat,
    required int birthYear,
    required String gender,
    String? powerSecret,
  }) async {
    final PyramidRoot? r = root;
    final PyramidState? s = state;
    final Uint8List? seed = powerSecret == null
        ? r?.powerSeed
        : unb64(powerSecret.trim(), length: 32);
    if (r == null ||
        s == null ||
        s.position.isNotEmpty ||
        seed == null ||
        !pyrBirthYearValid(birthYear, _now())) {
      return null;
    }
    final LedgerKeyPair power = await LedgerKeyPair.fromSeed(seed);
    if (power.id != s.powerKey) {
      return null;
    }
    final LedgerKeyPair me = await _ensureIdentity();
    _setData(birthYear, gender);
    _follow();
    final PyramidRecord unsigned = PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.found,
        'py': r.id,
        'at': _now(),
        'by': <String>[power.id, me.id]..sort(),
        'm': _memberJson(me, myName, nat),
      },
    );
    final PyramidRecord rec = await (await unsigned.signedBy(
      power,
    )).signedBy(me);
    await _setPower(seed);
    await _save();
    await ingest(rec);
    return isMember ? r.id : null;
  }

  /// Whether this phone holds the power key now in force.
  bool get holdsPowerKey {
    final String? pk = state?.powerKey;
    return pk != null && _powerId == pk;
  }

  /// Takes [seed] as the power key this person holds (null: none).
  Future<void> _setPower(Uint8List? seed) async {
    _powerSeed = seed;
    _powerId = seed == null ? null : (await LedgerKeyPair.fromSeed(seed)).id;
    if (_powerId != null && _powerNextId == _powerId) {
      await _setPowerNext(null);
    }
  }

  /// Takes [seed] as the power key made for a handover still waiting.
  Future<void> _setPowerNext(Uint8List? seed) async {
    _powerNext = seed;
    _powerNextId = seed == null
        ? null
        : (await LedgerKeyPair.fromSeed(seed)).id;
  }

  /// The free places this person can bring somebody to ("Polecenie"): in
  /// their branch, nearest the top first ([PyramidState.freePlaces]).
  List<String> freePlaces({int limit = 12}) {
    final PyramidState? s = state;
    final String? k = myKey;
    final String? p = k == null ? null : s?.pathOf(k);
    return s == null || p == null
        ? const <String>[]
        : s.freePlaces(p, limit: limit);
  }

  /// The QR a member shows a friend met in person to bring them in
  /// ("Polecenie"): every member, the head of the pyramid too, at any
  /// time and with no limit. [slot] is the free place of this person's
  /// branch the newcomer goes to (by default the one nearest the top);
  /// the head of the cell there co-signs. Null when not a member or the
  /// place is not free.
  String? inviteCode({String? slot}) {
    final PyramidState? s = state;
    final String? k = myKey;
    final String? p = k == null ? null : s?.pathOf(k);
    if (s == null || k == null || p == null) {
      return null;
    }
    final String? place = slot ?? s.freePlaces(p, limit: 1).firstOrNull;
    if (place == null ||
        place.isEmpty ||
        !PyrPath.within(place, p) ||
        !s.freePlaces(PyrPath.parent(place), limit: 2).contains(place)) {
      return null;
    }
    final String head = s.occupant[PyrPath.parent(place)]!;
    return 'zen-pyr:${base64Url.encode(utf8.encode(jsonEncode(<String, String>{'py': s.id, 's': k, 'h': head, 'p': place, 'a': _n(host.ownAddress())}))).replaceAll('=', '')}';
  }

  /// An invitation: pyramid, sponsor, head of the cell, place, the
  /// sponsor's address; null when [text] is none.
  static Map<String, String>? parseInvite(String text) {
    if (!text.startsWith('zen-pyr:')) {
      return null;
    }
    try {
      final Object? json = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(text.substring(8)))),
      );
      if (json is Map &&
          json['py'] is String &&
          json['s'] is String &&
          json['h'] is String &&
          json['p'] is String &&
          (json['p'] as String).isNotEmpty &&
          PyrPath.valid(json['p'] as String) &&
          json['a'] is String) {
        return <String, String>{
          'py': json['py'] as String,
          's': json['s'] as String,
          'h': json['h'] as String,
          'p': json['p'] as String,
          'a': json['a'] as String,
        };
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// Whether [invite] is one to this app's pyramid (a code of any other
  /// "pyramid" is refused: phones keep only the pinned one).
  bool invitesHere(String invite) {
    final Map<String, String>? inv = parseInvite(invite);
    return inv != null && current != null && inv['py'] == current;
  }

  /// The newcomer's side: asks the sponsor to vouch (data to confirm);
  /// the head of the chosen cell co-signs after them.
  Future<bool> askToJoin({
    required String invite,
    required String myName,
    required String nat,
    required int birthYear,
    required String gender,
  }) async {
    final Map<String, String>? inv = parseInvite(invite);
    if (inv == null ||
        !invitesHere(invite) ||
        !pyrBirthYearValid(birthYear, _now())) {
      return false;
    }
    final LedgerKeyPair me = await _ensureIdentity();
    _setData(birthYear, gender);
    final List<String> by = <String>{inv['s']!, inv['h']!, me.id}.toList()
      ..sort();
    final PyramidRecord r = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.admit,
        'py': inv['py'],
        'at': _now(),
        'by': by,
        'sp': inv['s'],
        'head': inv['h'],
        'slot': inv['p'],
        'm': _memberJson(me, myName, nat),
        'pn': _newId(16),
      },
    ).signedBy(me);
    _mine[r.id] = r;
    _mineNeed[r.id] = by.length;
    _agree(r);
    // The pyramid this person is joining: its records are taken from now.
    _follow();
    await _save();
    await _send(inv['a']!, <String, dynamic>{
      'type': PyramidTypes.proposal,
      'r': r.toJson(),
      'need': by.length,
      // The gender for the sponsor to confirm (the year is in the member
      // data itself).
      'x': <String, dynamic>{
        'g': gender,
        'salt': myData['salt'],
        'what': 'admit',
      },
    });
    return true;
  }

  // ---- proposals ----

  /// Whether [r] carries the signatures its rule asks for. When this phone
  /// keeps the pyramid, the rule itself decides (a trial fold), so mixed
  /// rules — 2 of the top and 2 of the person's own cell, a delegate plus
  /// the cell — are met exactly, never published half-signed. Otherwise
  /// (a newcomer keeps nothing of it yet) the count [need] decides. Once
  /// everybody asked has signed, it goes out either way.
  bool _ready(PyramidRecord r, int need) {
    if (r.candidates.every(r.sigs.containsKey)) {
      return true;
    }
    final String py = r.pyramid;
    if (py != current || !isMember) {
      return r.sigs.length >= need;
    }
    final PyramidState trial = PyramidState.fold(
      py,
      <PyramidRecord>[
        for (final PyramidRecord x in _records.values)
          if (x.id != r.id) x,
        r,
      ],
      now: max(_now(), r.at),
      treasurerSigs: _tsigs,
      late: _late,
    );
    return trial.applied.contains(r.id);
  }

  /// Signs [r] as this person and sends it to the other [candidates] who
  /// still have to sign; publishes at once when [need] is already met.
  Future<PyramidRecord> propose(
    Map<String, dynamic> body, {
    required List<String> candidates,
    required int need,
    Map<String, dynamic> extra = const <String, dynamic>{},
    int? at,
  }) async {
    final LedgerKeyPair me = await _ensureIdentity();
    final Map<String, dynamic> full = <String, dynamic>{
      ...body,
      'py': body['py'] ?? current,
      'at': at ?? _now(),
      'by': <String>{me.id, ...candidates}.toList()..sort(),
      // Others sign too: a nonce of this proposal, so its fresh copies
      // (signed late) count once, however many go round.
      if (candidates.any((String k) => k != me.id) && body['pn'] == null)
        'pn': _newId(16),
    };
    final PyramidRecord r = await PyramidRecord(body: full).signedBy(me);
    _agree(r);
    if (_ready(r, need)) {
      await ingest(r);
      return r;
    }
    _mine[r.id] = r;
    _mineNeed[r.id] = need;
    await _save();
    final PyramidState? s = state;
    for (final String k in candidates) {
      if (k == me.id) {
        continue;
      }
      final String addr = s?.members[k]?.addr ?? '';
      if (addr.isNotEmpty) {
        await _send(addr, <String, dynamic>{
          'type': PyramidTypes.proposal,
          'r': r.toJson(),
          'need': need,
          'x': extra,
        });
      }
    }
    return r;
  }

  /// Remembers that this person agreed to [r]'s content (for a week): a
  /// fresh copy of it is signed again without asking.
  void _agree(PyramidRecord r) {
    _consent[_contentKey(r)] = _now() + 7 * 24 * 3600 * 1000;
  }

  /// Agrees to a proposal: adds this person's signature, publishes when
  /// enough, and tells the proposer. A proposal signed long after it was
  /// made is not published with its old time (it would land in the past
  /// and change what happened since): a fresh copy goes round instead, and
  /// those who signed the old one sign it again without being asked.
  Future<void> approve(String id) async {
    final PyrProposal? waiting = proposals[id];
    if (waiting != null && admitProblem(waiting) != null) {
      // Stays waiting: the level can still be raised.
      return;
    }
    final PyrProposal? p = proposals.remove(id);
    final LedgerKeyPair? me = _identity;
    if (p == null || me == null) {
      return;
    }
    final int t = _now();
    if (p.record.at > t + kPyrMaxSkewMs) {
      // From the future: never signed (it would wait as a time bomb).
      await _save();
      return;
    }
    if (t - p.record.at > kPyrMaxSkewMs) {
      await _redate(p.record, need: p.need, alsoTo: p.from);
      await _save();
      return;
    }
    final PyramidRecord signed = await p.record.signedBy(me);
    _agree(signed);
    await _save();
    if (_ready(signed, p.need)) {
      await ingest(signed);
    } else if (signed.type == PyrT.admit &&
        signed.str('sp') == me.id &&
        signed.str('head') != me.id) {
      // "Polecenie": the head of the chosen cell co-signs next; its
      // signature comes back here, and this person (a friend of the
      // newcomer) publishes it.
      _mine[signed.id] = signed;
      _mineNeed[signed.id] = p.need;
      await _save();
      final String addr = state?.members[signed.str('head')]?.addr ?? '';
      if (addr.isNotEmpty) {
        await _send(addr, <String, dynamic>{
          'type': PyramidTypes.proposal,
          'r': signed.toJson(),
          'need': p.need,
          'x': <String, dynamic>{...p.extra, 'what': 'admit'},
        });
      }
    }
    await _send(p.from, <String, dynamic>{
      'type': PyramidTypes.signature,
      'r': signed.toJson(),
    });
  }

  /// Where to send [r] for [key]'s signature: the member's device, or for
  /// a newcomer the address in the admission.
  String _addrOf(String key, PyramidRecord r) {
    final String fromState = state?.members[key]?.addr ?? '';
    if (fromState.isNotEmpty) {
      return fromState;
    }
    final Object? m = r.body['m'];
    return m is Map && m['k'] == key && m['addr'] is String
        ? m['addr'] as String
        : '';
  }

  /// A fresh copy of [old] — the same content, the time now — signed by
  /// this person and sent to the others asked to sign (and to [alsoTo]);
  /// published at once when that is already enough.
  Future<void> _redate(
    PyramidRecord old, {
    required int need,
    String alsoTo = '',
    bool manual = true,
  }) async {
    final LedgerKeyPair? me = _identity;
    if (me == null) {
      return;
    }
    // Without a person's tap, a few rounds at most (a network slower than
    // the 10 minutes would otherwise go round and round).
    final int round = (_redates[old.contentKey] ?? 0) + 1;
    if (!manual && round > 5) {
      return;
    }
    _redates[old.contentKey] = round;
    final PyramidRecord fresh = await PyramidRecord(
      body: <String, dynamic>{...old.body, 'at': _now()},
    ).signedBy(me);
    _agree(fresh);
    _mine.remove(old.id);
    _mineNeed.remove(old.id);
    if (_ready(fresh, need)) {
      await ingest(fresh);
      return;
    }
    _mine[fresh.id] = fresh;
    _mineNeed[fresh.id] = need;
    await _save();
    final Map<String, dynamic> proposal = <String, dynamic>{
      'type': PyramidTypes.proposal,
      'r': fresh.toJson(),
      'need': need,
      'x': const <String, dynamic>{'what': 'fresh'},
    };
    final Set<String> sent = <String>{_n(host.ownAddress())};
    for (final String k in fresh.candidates) {
      final String addr = k == me.id ? '' : _addrOf(k, fresh);
      if (addr.isNotEmpty && sent.add(_n(addr))) {
        await _send(addr, proposal);
      }
    }
    if (alsoTo.isNotEmpty && sent.add(_n(alsoTo))) {
      await _send(alsoTo, proposal);
    }
  }

  /// Signs a fresh copy of something this person already agreed to,
  /// publishes it when enough, and sends the signature back.
  Future<void> _cosign(PyramidRecord r, int need, String from) async {
    final LedgerKeyPair? me = _identity;
    if (me == null) {
      return;
    }
    final PyramidRecord signed = await r.signedBy(me);
    _agree(signed);
    await _save();
    if (signed.type != PyrT.transfer && _ready(signed, need)) {
      await ingest(signed);
    }
    await _send(from, <String, dynamic>{
      'type': PyramidTypes.signature,
      'r': signed.toJson(),
    });
  }

  /// Why this person cannot vouch for the newcomer of [p] yet, or
  /// null (also for anything but an admission, and for the head of the
  /// cell a sponsor chose — it only co-signs): the newcomer must be the
  /// sponsor's friend (met in person, the QR) at the level "Znajomy" or
  /// above.
  String? admitProblem(PyrProposal p) {
    if (p.record.type != PyrT.admit || p.record.str('sp') != myKey) {
      return null;
    }
    if (!host.isFriend(p.from)) {
      return t('Przyjąć można tylko znajomego spotkanego osobiście.');
    }
    final FriendLevel? Function(String address)? levelOf = friendLevelOf;
    if (levelOf == null) {
      return null;
    }
    final FriendLevel? level = levelOf(p.from);
    if (level == null || level.index < FriendLevel.friend.index) {
      return t(
        'Najpierw ustaw tej osobie poziom co najmniej „Znajomy” — do piramidy przyjmuje się tylko bliższych znajomych.',
      );
    }
    return null;
  }

  Future<void> reject(String id) async {
    proposals.remove(id);
    await _save();
  }

  // ---- the cell ----

  /// Open swap in a cell: proposes that [up] becomes its head.
  Future<PyramidRecord?> proposeSwap(String cell, String up) async {
    final PyramidState? s = state;
    final String? head = s?.occupant[cell];
    if (s == null || head == null) {
      return null;
    }
    return propose(
      <String, dynamic>{'t': PyrT.swap, 'cell': cell, 'head': head, 'up': up},
      candidates: s.cellOf(cell),
      need: 2,
    );
  }

  /// Anonymous request for a new vote in a cell.
  Future<bool> requestElection(String cell) async {
    final PyramidState? s = state;
    final LedgerKeyPair? me = _identity;
    final String? head = s?.occupant[cell];
    if (s == null || me == null || head == null) {
      return false;
    }
    // The ring: those of the cell with a vote ([PyramidState.canVote]).
    final List<String> ring = s.cellVoters(cell, _now())..sort();
    if (!ring.contains(me.id) || ring.length < 2) {
      return false;
    }
    final Map<String, dynamic> body = <String, dynamic>{
      't': PyrT.voteRequest,
      'py': s.id,
      'at': _now(),
      'by': const <String>[],
      'cell': cell,
      'head': head,
      'ring': ring,
      'n': _newId(),
    };
    final PyramidRecord unsigned = PyramidRecord(body: body);
    final RingSignature sig = RingSignature.sign(
      seed: me.seed,
      ring: ring.map((String k) => unb64(k, length: 32)!).toList(),
      context: PyramidState.voteRequestContext(s.id, cell, head),
      message: unsigned.signedBytes,
    );
    await _publishAnonymously(
      PyramidRecord(body: body, ring: sig),
      avoid: ring,
    );
    return true;
  }

  /// Anonymous vote for the head of a cell.
  Future<bool> voteInCell(String electionId, String choice) async {
    final PyramidState? s = state;
    final LedgerKeyPair? me = _identity;
    final PyrElection? e = s?.elections[electionId];
    if (s == null ||
        me == null ||
        e == null ||
        e.closed ||
        !e.ring.contains(me.id)) {
      return false;
    }
    final Map<String, dynamic> body = <String, dynamic>{
      't': PyrT.vote,
      'py': s.id,
      'at': _now(),
      'by': const <String>[],
      'elect': electionId,
      'choice': choice,
      // Two equal votes are still two records.
      'n': _newId(),
    };
    final RingSignature sig = RingSignature.sign(
      seed: me.seed,
      ring: e.ring.map((String k) => unb64(k, length: 32)!).toList(),
      context: PyramidState.voteContext(electionId),
      message: PyramidRecord(body: body).signedBytes,
    );
    await _publishAnonymously(
      PyramidRecord(body: body, ring: sig),
      avoid: e.ring,
    );
    return true;
  }

  /// Hands an anonymous record to a friend outside [avoid] to publish, so
  /// the first phone to see it is not this one.
  Future<void> _publishAnonymously(
    PyramidRecord r, {
    required List<String> avoid,
  }) async {
    final PyramidState? s = state;
    final Set<String> avoidAddrs = <String>{
      for (final String k in avoid)
        if ((s?.members[k]?.addr ?? '').isNotEmpty) _n(s!.members[k]!.addr),
    };
    final List<String> relays = _pyramidFriends(
      r.pyramid,
    ).where((String a) => !avoidAddrs.contains(a)).toList();
    if (relays.isEmpty) {
      await ingest(r);
      return;
    }
    await _send(relays[_random.nextInt(relays.length)], <String, dynamic>{
      'type': PyramidTypes.anon,
      'r': r.toJson(),
    });
  }

  Future<void> leave() async {
    final LedgerKeyPair? me = _identity;
    if (me == null || !isMember) {
      return;
    }
    await propose(
      <String, dynamic>{'t': PyrT.leave, 'k': me.id},
      candidates: <String>[me.id],
      need: 1,
    );
  }

  /// One of the people under a free place moves up into it.
  Future<PyramidRecord?> proposeFill(String cell, String up) async {
    final PyramidState? s = state;
    if (s == null || !s.vacant.contains(cell)) {
      return null;
    }
    final List<String> kids = <String>[
      for (final String c in PyrPath.children(cell))
        if (s.occupant[c] != null) s.occupant[c]!,
    ];
    final List<String> need = kids.length >= 2
        ? kids
        : <String>[
            up,
            if (cell.isNotEmpty && s.occupant[PyrPath.parent(cell)] != null)
              s.occupant[PyrPath.parent(cell)]!,
          ];
    return propose(
      <String, dynamic>{'t': PyrT.fill, 'cell': cell, 'up': up},
      candidates: need,
      need: need.length,
    );
  }

  Future<PyramidRecord?> proposeAbsent(String key) async {
    final PyramidState? s = state;
    final String? p = s?.pathOf(key);
    if (s == null || p == null) {
      return null;
    }
    final List<String> around = <String>[
      for (final String q in <String>[
        if (p.isNotEmpty) PyrPath.parent(p),
        if (p.isNotEmpty) PyrPath.sibling(p),
        ...PyrPath.children(p),
      ])
        if (s.occupant[q] != null && s.occupant[q] != key) s.occupant[q]!,
    ];
    return propose(
      <String, dynamic>{'t': PyrT.absent, 'k': key},
      candidates: around,
      need: min(2, around.length),
    );
  }

  Future<PyramidRecord?> proposeRemove(String key) async {
    final PyramidState? s = state;
    if (s == null) {
      return null;
    }
    return propose(
      <String, dynamic>{'t': PyrT.remove, 'k': key},
      candidates: s.ownCellOf(key),
      need: 2,
    );
  }

  /// Moves this person under [toHead]. With [branch], everybody
  /// below comes along in the same places (the whole own cell signs);
  /// without people below it is an ordinary move.
  Future<PyramidRecord?> proposeMigrate(
    String toHead, {
    bool branch = false,
  }) async {
    final LedgerKeyPair? me = _identity;
    if (me == null) {
      return null;
    }
    final List<String> below = myCellBelow;
    if (branch && below.isNotEmpty) {
      final List<String> all = <String>{me.id, toHead, ...below}.toList();
      return propose(
        <String, dynamic>{
          't': PyrT.migrate,
          'k': me.id,
          'to': toHead,
          'branch': true,
        },
        candidates: all,
        need: all.length,
      );
    }
    return propose(
      <String, dynamic>{'t': PyrT.migrate, 'k': me.id, 'to': toHead},
      candidates: <String>[me.id, toHead],
      need: 2,
    );
  }

  /// The people directly under this person (its own cell).
  List<String> get myCellBelow {
    final PyramidState? s = state;
    final String? k = myKey;
    final String? p = k == null ? null : s?.pathOf(k);
    if (s == null || p == null) {
      return const <String>[];
    }
    return <String>[
      for (final String c in PyrPath.children(p))
        if (s.occupant[c] != null) s.occupant[c]!,
    ];
  }

  // ---- power ----

  /// A decision of the top cell, 2 of 3 (or, through a delegation, alone).
  Future<PyramidRecord?> topDecision(
    Map<String, dynamic> body, {
    String? via,
    List<String> alsoNeed = const <String>[],
  }) async {
    final PyramidState? s = state;
    final String? k = myKey;
    if (s == null || k == null) {
      return null;
    }
    if (via != null) {
      return propose(
        <String, dynamic>{...body, 'via': via},
        candidates: <String>[k, ...alsoNeed],
        need: 1 + min(2, alsoNeed.length),
      );
    }
    return propose(
      body,
      candidates: <String>{...s.topCell, ...alsoNeed}.toList(),
      need: 2 + min(2, alsoNeed.length),
    );
  }

  Future<PyramidRecord?> delegate({
    required String to,
    required String power,
    String scope = '',
    int limit = 0,
    required int until,
    bool sub = false,
    String? parent,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      't': PyrT.delegate,
      'to': to,
      'power': power,
      'scope': scope,
      'limit': limit,
      'until': until,
      'sub': sub,
      'parent': ?parent,
    };
    if (parent != null) {
      return propose(body, candidates: <String>[myKey!], need: 1);
    }
    return topDecision(body);
  }

  /// Revokes delegation [id] (2 of the top): from now on it, and every
  /// delegation passed on from it, is worth nothing. What was done with it
  /// so far stays; the revocation lists those acts, so one dated back
  /// later does not count.
  Future<PyramidRecord?> revokeDelegation(String id) async {
    final PyramidState? s = state;
    if (s == null) {
      return null;
    }
    return topDecision(<String, dynamic>{
      't': PyrT.revoke,
      'd': id,
      'acts': s.actsOf(id).toList()..sort(),
    });
  }

  Future<PyramidRecord?> ban({
    required String target,
    required String kind,
    int? until,
    String? datingKey,
    String reason = '',
    String? via,
    String? entryId,
  }) async {
    final PyramidState? s = state;
    final String? p = s?.pathOf(target);
    final List<String> immunity =
        p != null &&
            p.length < s!.params.immunityDepth &&
            kind != 'content' &&
            kind != 'dating'
        ? s.ownCellOf(target)
        : const <String>[];
    return topDecision(
      <String, dynamic>{
        't': PyrT.ban,
        'target': target,
        'kind': kind,
        'until': ?until,
        // The entry itself.
        'eid': ?entryId,
        'dk': ?datingKey,
        'reason': reason,
      },
      via: via,
      alsoNeed: immunity,
    );
  }

  Future<PyramidRecord?> post(String text) async {
    final PyramidState? s = state;
    final String? k = myKey;
    final int? lvl = k == null ? null : s?.levelOf(k);
    if (lvl == null || text.trim().isEmpty) {
      return null;
    }
    return propose(
      <String, dynamic>{'t': PyrT.post, 'text': text.trim(), 'lvl': lvl},
      candidates: <String>[k!],
      need: 1,
    );
  }

  Future<PyramidRecord?> comment(String postId, String text) async {
    final String? k = myKey;
    if (k == null || text.trim().isEmpty) {
      return null;
    }
    return propose(
      <String, dynamic>{'t': PyrT.comment, 'post': postId, 'text': text.trim()},
      candidates: <String>[k],
      need: 1,
    );
  }

  Future<PyramidRecord?> natPost(String text) async {
    final PyramidState? s = state;
    final String? k = myKey;
    final PyrMember? m = k == null ? null : s?.members[k];
    final int? lvl = k == null ? null : s?.levelOf(k);
    if (m == null || lvl == null || text.trim().isEmpty) {
      return null;
    }
    return propose(
      <String, dynamic>{
        't': PyrT.natPost,
        'nat': m.nat,
        'text': text.trim(),
        'lvl': lvl,
      },
      candidates: <String>[k!],
      need: 1,
    );
  }

  /// A referendum on any question, asked by the top (2 of 3): the members
  /// vote secretly, the result is published and only advises the top.
  Future<PyramidRecord?> referendum({
    required String question,
    required List<String> options,
    required int end,
    String scopeKind = 'all',
    String scopePath = '',
    String scopeNat = '',
  }) => topDecision(<String, dynamic>{
    't': PyrT.referendum,
    'q': question,
    'opts': options,
    // A late second signature (a fresh copy) still leaves the minimum.
    'end': max(end, _now() + kPyrMinReferendumMs + 5000),
    'scope': <String, String>{'k': scopeKind, 'p': scopePath, 'nat': scopeNat},
  });

  /// New rules (the fields of [PyrParams] that change), signed by the top
  /// (2 of 3): public at once, applied [kPyrParamsDelayMs] later.
  Future<PyramidRecord?> changeRules(Map<String, dynamic> params) =>
      topDecision(<String, dynamic>{'t': PyrT.constitution, 'params': params});

  /// The reach of an act through delegation [via]: a delegate of a branch
  /// reaches only that branch, so anything wider becomes the
  /// branch.
  ({String kind, String path}) _delegatedScope(
    String? via,
    String kind,
    String path,
  ) {
    final PyrDelegation? d = via == null ? null : state?.delegations[via];
    if (d == null || d.scope.isEmpty) {
      return (kind: kind, path: path);
    }
    if (kind == 'branch' && PyrPath.within(path, d.scope)) {
      return (kind: kind, path: path);
    }
    return (kind: 'branch', path: d.scope);
  }

  // ---- referendum votes and sums ----

  /// The root of [r]'s counting: the top, or the branch root.
  String _countRoot(PyrReferendum r) =>
      r.scopeKind == 'branch' ? r.scopePath : '';

  /// Votes: secret from everyone but one's own cell head.
  Future<bool> voteReferendum(String refId, int option) async {
    final PyramidState? s = state;
    final String? k = myKey;
    final PyrReferendum? r = s?.referenda[refId];
    final String? p = k == null ? null : s?.pathOf(k);
    if (s == null ||
        k == null ||
        r == null ||
        p == null ||
        !s.eligible(r, k) ||
        _now() >= r.end ||
        option < 0 ||
        option >= r.options.length) {
      return false;
    }
    if (myVotes.containsKey(refId)) {
      return false;
    }
    myVotes[refId] = option;
    await _save();
    final String root = _countRoot(r);
    String? to;
    bool extra = false;
    if (p == root) {
      // The root's vote goes to its first child (or stays here).
      for (final String c in PyrPath.children(p)) {
        if (s.occupant[c] != null) {
          to = s.occupant[c];
          extra = true;
          break;
        }
      }
      if (to == null) {
        (_extraVotes[refId] ??= <String>{}).add('$k:$option');
        await _save();
        return true;
      }
    } else {
      to = s.occupant[PyrPath.parent(p)];
    }
    if (to == null) {
      return false;
    }
    final String addr = s.members[to]?.addr ?? '';
    if (addr == _n(host.ownAddress())) {
      await _onVote(addr, <String, dynamic>{
        'ref': refId,
        'k': k,
        'opt': option,
        'extra': extra,
      });
    } else {
      await _send(addr, <String, dynamic>{
        'type': PyramidTypes.vote,
        'ref': refId,
        'k': k,
        'opt': option,
        'extra': extra,
      });
    }
    return true;
  }

  Future<void> _onVote(String from, Map<String, dynamic> p) async {
    final PyramidState? s = state;
    final String? me = myKey;
    final Object? refId = p['ref'];
    final Object? voter = p['k'];
    final Object? opt = p['opt'];
    if (s == null ||
        me == null ||
        refId is! String ||
        voter is! String ||
        opt is! int) {
      return;
    }
    final PyrReferendum? r = s.referenda[refId];
    final String? vp = s.pathOf(voter);
    final String? mp = s.pathOf(me);
    if (r == null ||
        vp == null ||
        mp == null ||
        !s.eligible(r, voter) ||
        opt < 0 ||
        opt >= r.options.length) {
      return;
    }
    // Only one's own: a direct member, or (extra) the root above.
    final bool direct = PyrPath.parent(vp) == mp && vp != mp;
    final bool fromRoot =
        p['extra'] == true && vp == PyrPath.parent(mp) && vp == _countRoot(r);
    if (_n(s.members[voter]?.addr ?? '') != _n(from) &&
        _n(from) != _n(host.ownAddress())) {
      return;
    }
    if (direct) {
      (_headVotes[refId] ??= <String, int>{})[voter] = opt;
    } else if (fromRoot) {
      (_extraVotes[refId] ??= <String>{})
        ..removeWhere((String v) => v.startsWith('$voter:'))
        ..add('$voter:$opt');
    } else {
      return;
    }
    await _save();
  }

  /// This person's part in counting: publishes the sum of its branch once
  /// the voting ended and the sums below arrived (or waiting is over).
  Future<void> _countDuties() async {
    final PyramidState? s = state;
    final String? me = myKey;
    final String? mp = me == null ? null : s?.pathOf(me);
    if (s == null || me == null || mp == null) {
      return;
    }
    for (final PyrReferendum r in s.referenda.values) {
      final int t = _now();
      if (t < r.end || t > r.end + 7 * 24 * 3600 * 1000) {
        continue;
      }
      final String root = _countRoot(r);
      if (!PyrPath.within(mp, root)) {
        continue;
      }
      final List<String> kidPaths = PyrPath.children(
        mp,
      ).where((String c) => s.occupant[c] != null).toList();
      final Map<String, int> direct = _headVotes[r.id] ?? const <String, int>{};
      // The root's own vote is held by its first child (or the root alone).
      final List<String> rootKids = PyrPath.children(
        root,
      ).where((String c) => s.occupant[c] != null).toList();
      final bool holdsRootVote = rootKids.isEmpty
          ? mp == root
          : mp == rootKids.first;
      final List<String> extra = holdsRootVote
          ? (_extraVotes[r.id] ?? const <String>{}).take(1).toList()
          : const <String>[];
      if (kidPaths.isEmpty && extra.isEmpty) {
        continue;
      }
      // The newest sum of every branch right below (whoever holds the
      // place now): the fold checks that none is left out.
      final List<PyrTally> kids = <PyrTally>[
        for (final String c in kidPaths) ?s.latestTally(r, c),
      ];
      final bool complete = kidPaths
          .where(
            (String c) =>
                PyrPath.children(c).any((String g) => s.occupant[g] != null),
          )
          .every((String c) => s.latestTally(r, c) != null);
      // Without a branch's sum only once the wait is over (the fold
      // refuses it sooner).
      if (!complete &&
          t < r.end + max(tallyWait.inMilliseconds, kPyrTallyGraceMs)) {
        continue;
      }
      final List<int> counts = List<int>.filled(r.options.length, 0);
      for (final PyrTally k in kids) {
        for (int i = 0; i < counts.length; i++) {
          counts[i] += k.counts[i];
        }
      }
      for (final MapEntry<String, int> v in direct.entries) {
        if (s.pathOf(v.key) != null &&
            PyrPath.parent(s.pathOf(v.key)!) == mp &&
            s.eligible(r, v.key)) {
          counts[v.value]++;
        }
      }
      for (final String v in extra) {
        final int? o = int.tryParse(v.split(':').last);
        if (o != null &&
            o >= 0 &&
            o < counts.length &&
            s.eligible(r, v.split(':').first)) {
          counts[o]++;
        }
      }
      final String signature =
          '${counts.join(',')}|${kids.map((PyrTally k) => k.id).join(',')}';
      if (_tallySent[r.id] == signature) {
        continue;
      }
      _tallySent[r.id] = signature;
      await propose(
        <String, dynamic>{
          't': PyrT.tally,
          'ref': r.id,
          'counts': counts,
          'kids': kids.map((PyrTally k) => k.id).toList(),
          'extra': extra.isNotEmpty,
        },
        candidates: <String>[me],
        need: 1,
      );
    }
  }

  // ---- money ----

  /// Pays [to]: an order to the treasurers, valid with a majority of them.
  /// With [condBy], it waits for that person's word; with [share],
  /// it is an announcement passed on through intermediaries, each keeping
  /// [share], at most [hops] times after the first ([hash]: its text).
  Future<PyramidRecord?> pay(
    String to,
    int amount, {
    String memo = '',
    String? condBy,
    int? condUntil,
    int share = 0,
    int hops = 0,
    String? hash,
  }) async {
    final PyramidState? s = state;
    final LedgerKeyPair? me = _identity;
    final String payer = me?.id ?? '';
    if (s == null ||
        me == null ||
        amount <= 0 ||
        amount > kPyrMaxAmount ||
        payer.isEmpty ||
        to.isEmpty ||
        to == payer) {
      return null;
    }
    if (_paymentWaiting(payer, s.id)) {
      return null;
    }
    final Map<String, dynamic>? cond = condBy == null
        ? null
        : <String, dynamic>{
            'by': condBy,
            'until': condUntil ?? _now() + 7 * 24 * 3600 * 1000,
            if (share > 0) 'share': share,
            if (share > 0) 'hops': hops,
            'h': ?hash,
          };
    final PyramidRecord order = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.transfer,
        'py': s.id,
        'at': _now(),
        'by': <String>[me.id],
        'from': payer,
        'to': to,
        'amount': amount,
        'seq': s.account(payer).seq + 1,
        'memo': memo,
        'cond': ?cond,
      },
    ).signedBy(me);
    await _toTreasurers(order);
    return order;
  }

  /// One order at a time per account (the next needs the next number).
  bool _paymentWaiting(String payer, String py) => _payments.values.any(
    (PyramidRecord r) =>
        r.type == PyrT.transfer && r.str('from') == payer && r.pyramid == py,
  );

  /// Sends a signed order (or settlement) to every treasurer of its
  /// pyramid (this phone's own part directly). It is kept until most of
  /// them have signed — also across a restart — and sent again as it is.
  Future<void> _toTreasurers(PyramidRecord order) async {
    final PyramidState? s = order.pyramid == current ? state : null;
    final String? me = myKey;
    if (s == null || me == null) {
      return;
    }
    _payments[order.id] ??= order;
    _resentAt[order.id] = _now();
    await _save();
    for (final String t in s.treasurers) {
      final String addr = s.members[t]?.addr ?? '';
      if (t == me) {
        await _onPay(_n(host.ownAddress()), <String, dynamic>{
          'r': order.toJson(),
        });
      } else if (addr.isNotEmpty) {
        await _send(addr, <String, dynamic>{
          'type': PyramidTypes.pay,
          'r': order.toJson(),
        });
      }
    }
  }

  /// A treasurer checks an order (or a settlement) against its own copy
  /// and signs it: fresh (not from the future, at most a week old), never
  /// two orders with the same number, never two settlements of one payment.
  Future<void> _onPay(String from, Map<String, dynamic> p) async {
    final LedgerKeyPair? me = _identity;
    final PyramidRecord? order = PyramidRecord.fromJson(p['r']);
    if (me == null ||
        order == null ||
        !PyrT.treasured.contains(order.type) ||
        order.pyramid != current) {
      return;
    }
    final PyramidState? s = state;
    if (s == null || order.pyramid != s.id || !s.treasurers.contains(me.id)) {
      return;
    }
    final int t = _now();
    if (order.at > t + kPyrMaxSkewMs || t - order.at > kPyrMaxOrderAgeMs) {
      return;
    }
    // From the device of whoever signed it (or this phone).
    if (_n(from) != _n(host.ownAddress()) && !_fromSigner(from, order, s)) {
      return;
    }
    if (!await order.verifySigners()) {
      return;
    }
    final String? slot = order.type == PyrT.settle
        ? _settleSlot(s, order, t)
        : _orderSlot(s, order);
    if (slot == null) {
      return;
    }
    final String? already = _signedOrders[slot];
    if (already != null && already != order.id) {
      return;
    }
    _signedOrders[slot] = order.id;
    await _save();
    final String sig = b64(
      await me.sign(PyramidRecord.treasurerBytes(order.id)),
    );
    if (_n(from) == _n(host.ownAddress())) {
      await _onPaySig(<String, dynamic>{'id': order.id, 'k': me.id, 's': sig});
    } else {
      await _send(from, <String, dynamic>{
        'type': PyramidTypes.paySig,
        'id': order.id,
        'k': me.id,
        's': sig,
      });
    }
  }

  /// The number a payment order takes, when it is one to sign: the payer
  /// signed it, it is the next number, the money is there (an emission
  /// this phone saw late is not there before its whole veto time here,
  /// [PyramidState.fold]).
  String? _orderSlot(PyramidState s, PyramidRecord order) {
    final String payer = order.str('from');
    final int amount = order.integer('amount');
    final PyrAccount acc = s.accounts[payer] ?? PyrAccount();
    if (!s.canSpend(payer, order.signers) ||
        order.integer('seq') != acc.seq + 1 ||
        amount <= 0 ||
        amount > kPyrMaxAmount) {
      return null;
    }
    if (acc.balance < amount) {
      return null;
    }
    return '$payer|${order.integer('seq')}';
  }

  /// The payment a settlement settles, when it is one to sign: by the one
  /// whose word the payment waits for (an acceptance only while it waits),
  /// or the payer's refund after the time.
  String? _settleSlot(PyramidState s, PyramidRecord r, int t) {
    final PyrEscrow? e = s.escrows[r.str('x')];
    if (e == null || e.settled != null || r.at < e.at) {
      return null;
    }
    final bool ok = r.body['ok'] == true;
    final bool byCond = r.signers.contains(e.condBy);
    final bool refund = !ok && s.canSpend(e.from, r.signers) && r.at >= e.until;
    if (!byCond && !refund) {
      return null;
    }
    if (ok && t > e.until + kPyrMaxSkewMs) {
      return null;
    }
    return 'x|${e.id}';
  }

  /// Whether this phone first saw emission [id] late.
  bool seenLate(String id) => _late.containsKey(id);

  /// A treasurer's signature for an order waiting here: only a valid one
  /// is added, and one already kept is never replaced (whoever sends a
  /// different one for the same treasurer).
  Future<void> _onPaySig(Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final Object? k = p['k'];
    final Object? sig = p['s'];
    final PyramidRecord? order = id is String ? _payments[id] : null;
    if (order == null ||
        k is! String ||
        sig is! String ||
        order.tsigs.containsKey(k)) {
      return;
    }
    final PyramidState? s = order.pyramid == current ? state : null;
    if (s == null) {
      return;
    }
    final Map<String, String> fresh = await PyramidRecord(
      body: order.body,
      tsigs: <String, String>{k: sig},
    ).validTreasurerSigMap();
    if (fresh.isEmpty) {
      return;
    }
    // The order may have changed while the signature was checked.
    final PyramidRecord? now = _payments[order.id];
    if (now == null || now.tsigs.containsKey(k)) {
      return;
    }
    final PyramidRecord clean = PyramidRecord(
      body: now.body,
      sigs: now.sigs,
      tsigs: <String, String>{...now.tsigs, ...fresh},
    );
    _payments[order.id] = clean;
    if (clean.tsigs.keys.where(s.treasurers.contains).length >=
        s.treasurerMajority) {
      _payments.remove(order.id);
      _resentAt.remove(order.id);
      await ingest(clean);
    }
    await _save();
  }

  /// Payments waiting for treasurers.
  List<PyramidRecord> get pendingPayments => <PyramidRecord>[
    for (final PyramidRecord r in _payments.values)
      if (r.type == PyrT.transfer) r,
  ];

  void cancelPending(String id) {
    _payments.remove(id);
    _resentAt.remove(id);
    if (_mine[id]?.type == PyrT.transfer) {
      _mine.remove(id);
      _mineNeed.remove(id);
    }
    unawaited(_save());
    notifyListeners();
  }

  /// Settles a conditional payment; for an announcement, [next] is the
  /// one person it goes on to (with the rest of the money). Like a
  /// transfer, it goes to the treasurers, who sign one settlement per
  /// payment; it counts once most of them have.
  Future<PyramidRecord?> settle(
    String transferId,
    bool ok, {
    String? next,
  }) async {
    final LedgerKeyPair? me = _identity;
    final PyramidState? s = state;
    if (me == null || s == null) {
      return null;
    }
    // Already on its way: the same one, not a second.
    for (final PyramidRecord r in _payments.values) {
      if (r.type == PyrT.settle &&
          r.str('x') == transferId &&
          r.pyramid == s.id) {
        return r;
      }
    }
    final PyramidRecord r = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.settle,
        'py': s.id,
        'at': _now(),
        'by': <String>[me.id],
        'x': transferId,
        'ok': ok,
        if (ok && next != null) 'next': next,
      },
    ).signedBy(me);
    await _toTreasurers(r);
    return r;
  }

  Future<PyramidRecord?> emit(String to, int amount, String why) => topDecision(
    <String, dynamic>{'t': PyrT.emit, 'to': to, 'amount': amount, 'why': why},
  );

  /// Whether this person may still veto [e]: one of those who could when
  /// it was signed, within its waiting time — counted from when it reached
  /// this phone, when it came late (back-dated?).
  bool canVeto(PyrEmission e) {
    final String? k = myKey;
    if (k == null || e.vetoed || !e.vetoers.contains(k)) {
      return false;
    }
    return _now() < e.effectiveAt;
  }

  /// Vetoes emission [emitId]. The veto is dated within the emission's
  /// waiting time as its own time sets it — when it came late, at the last
  /// moment of it — so it counts the same on every phone.
  Future<PyramidRecord?> veto(String emitId) async {
    final String? k = myKey;
    if (k == null) {
      return null;
    }
    final PyrEmission? e = state?.emissions[emitId];
    final int t = _now();
    final int at = e == null ? t : min(max(t, e.signedAt), e.signedEnd - 1);
    return propose(
      <String, dynamic>{'t': PyrT.veto, 'emit': emitId},
      candidates: <String>[k],
      need: 1,
      at: at,
    );
  }

  /// Publishes this person's prices: [prices] the same for
  /// everybody, [levels] by acquaintance ({friend, fof, stranger}) for the
  /// kinds that differ (they win over [prices]). Every kind goes out by
  /// level.
  Future<PyramidRecord?> setOffers(
    Map<String, int> prices, {
    Map<String, Map<String, int>> levels = const <String, Map<String, int>>{},
  }) async {
    final String? k = myKey;
    final Map<String, Map<String, int>> all = <String, Map<String, int>>{
      for (final MapEntry<String, int> e in prices.entries)
        e.key: <String, int>{
          for (final String l in kPriceLevels.keys) l: e.value,
        },
      for (final MapEntry<String, Map<String, int>> e in levels.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    return k == null
        ? null
        : propose(
            <String, dynamic>{'t': PyrT.offer, 'prices': all},
            candidates: <String>[k],
            need: 1,
          );
  }

  // ---- tips ----

  /// Whether this person can give a tip to member [key] (of [pyramid],
  /// when known): both in the pyramid, someone else, money on the account.
  bool canTip(String? key, {String? pyramid}) {
    final PyramidState? s = state;
    final String? me = myKey;
    return s != null &&
        me != null &&
        key != null &&
        key != me &&
        s.isMember(me) &&
        s.isMember(key) &&
        (pyramid == null || pyramid.isEmpty || pyramid == s.id) &&
        s.balanceOf(me) > 0;
  }

  /// A tip: an ordinary payment with a title.
  Future<PyramidRecord?> tip(
    String key,
    int amount, {
    String? memo,
    String? pyramid,
  }) async {
    if (amount <= 0 || !canTip(key, pyramid: pyramid)) {
      return null;
    }
    return pay(key, amount, memo: memo ?? t('Napiwek za odpowiedź'));
  }

  // ---- whose device is at an address ----

  /// Addresses whose device proved holding a member's key (address →
  /// key, when).
  final Map<String, ({String key, int at})> _proven =
      <String, ({String key, int at})>{};

  /// Questions sent to an address, waiting for the device's answer.
  final Map<String, ({String nonce, Completer<String?> done})> _asked =
      <String, ({String nonce, Completer<String?> done})>{};

  static Uint8List _hereBytes(String py, String address, String nonce) =>
      Uint8List.fromList(utf8.encode('zen.pyr.here|$py|$address|$nonce'));

  /// The member whose device is at [address], once that device proved it:
  /// it signed a fresh question with the member's key, and its answer came
  /// from that address (the mesh vouches for the sender). A member's
  /// address in the pyramid is only their own word: points paid "to an
  /// address" go to nobody before this (a member who wrote in somebody
  /// else's address gets nothing). Null when the device does not answer
  /// within [wait], or answers for nobody.
  Future<String?> provenKeyAt(
    String address, {
    Duration wait = kPyrAddressProofWait,
  }) async {
    final String a = _n(address);
    final PyramidState? s = state;
    final String? py = current;
    if (s == null || py == null || a.isEmpty || !isMember) {
      return null;
    }
    final String key = pyramidKeyForAddress(s.members.values, a);
    if (key.isEmpty || !s.isMember(key) || key == myKey) {
      return null;
    }
    final ({String key, int at})? had = _proven[a];
    if (had != null && had.key == key && _now() - had.at < kPyrAddressProofMs) {
      return key;
    }
    ({String nonce, Completer<String?> done})? asked = _asked[a];
    if (asked == null) {
      asked = (nonce: _newId(24), done: Completer<String?>());
      _asked[a] = asked;
      await _send(a, <String, dynamic>{
        'type': PyramidTypes.who,
        'py': py,
        'n': asked.nonce,
      });
    }
    final String? got = await asked.done.future.timeout(
      wait,
      onTimeout: () => null,
    );
    if (identical(_asked[a]?.done, asked.done)) {
      _asked.remove(a);
    }
    return got == key ? key : null;
  }

  /// Somebody asks whose key is at this device: the answer is signed with
  /// this person's key while a member of the pyramid asked about (empty
  /// otherwise, so the asker need not wait).
  Future<void> _onWho(String from, Map<String, dynamic> p) async {
    final Object? n = p['n'];
    if (n is! String || n.isEmpty || n.length > 64) {
      return;
    }
    final LedgerKeyPair? me = _identity;
    final String? py = current;
    final PyramidState? s = state;
    final String own = _n(host.ownAddress());
    if (me == null ||
        py == null ||
        s == null ||
        p['py'] != py ||
        own.isEmpty ||
        !s.isMember(me.id)) {
      await _send(from, <String, dynamic>{'type': PyramidTypes.here, 'n': n});
      return;
    }
    final Uint8List sig = await me.sign(_hereBytes(py, own, n));
    await _send(from, <String, dynamic>{
      'type': PyramidTypes.here,
      'n': n,
      'k': me.id,
      's': b64(sig),
    });
  }

  /// The answer of the device at [from] to this phone's question.
  Future<void> _onHere(String from, Map<String, dynamic> p) async {
    final ({String nonce, Completer<String?> done})? asked = _asked[from];
    final String? py = current;
    if (asked == null || py == null || p['n'] != asked.nonce) {
      return;
    }
    final Object? k = p['k'];
    final Object? sig = p['s'];
    String? key;
    if (k is String && sig is String) {
      final PyramidState? s = state;
      if (s != null &&
          s.isMember(k) &&
          pyramidKeyForAddress(s.members.values, from) == k &&
          await verifyLedgerSignature(
            publicKey: k,
            message: _hereBytes(py, from, asked.nonce),
            signature: sig,
          )) {
        key = k;
        _proven[from] = (key: k, at: _now());
        while (_proven.length > 500) {
          _proven.remove(_proven.keys.first);
        }
      }
    }
    _asked.remove(from);
    if (!asked.done.isCompleted) {
      asked.done.complete(key);
    }
  }

  // ---- the access market ----

  /// How well this phone knows [address]: 'friend', 'fof' (a friend's
  /// shared friend list has it), else 'stranger' — or null when not [sure]
  /// (the sender cannot see the receiver's lists, so it assumes the most).
  String? levelOfAddress(String address, {bool sure = true}) {
    final String a = _n(address);
    if (a.isEmpty) {
      return sure ? 'stranger' : null;
    }
    if (host.isFriend(a)) {
      return 'friend';
    }
    final Map<String, String> Function(String friend)? lists = friendsOf;
    if (lists != null) {
      for (final String f in host.friends()) {
        if (lists(f).keys.any((String x) => _n(x) == a)) {
          return 'fof';
        }
      }
    }
    return sure ? 'stranger' : null;
  }

  /// The price [key] asks for [kind] (0 = free, null = not offered): the
  /// highest of its levels.
  int? priceOf(String key, String kind) => state?.offers[key]?[kind];

  /// What this person will be charged writing to [key]: the price for the
  /// level this phone can tell (the receiver decides), the highest when
  /// it cannot.
  ({int price, String? level}) priceToSend(String key, String kind) {
    final PyramidState? s = state;
    final String addr = s?.members[key]?.addr ?? '';
    final String? level = addr.isEmpty
        ? null
        : levelOfAddress(addr, sure: false);
    return (price: s?.priceFor(key, kind, level) ?? 0, level: level);
  }

  /// Whether member [key] takes no first message ('inbox') from someone of
  /// [level]: their price for it has levels, and [level] is not among them.
  /// An unknown level (null) is closed only when nobody but friends may
  /// write first.
  bool closedTo(String key, String? level) {
    final Map<String, int>? levels = state?.offerLevels[key]?['inbox'];
    if (levels == null) {
      return false;
    }
    if (level == null) {
      return !levels.keys.any((String l) => l != 'friend');
    }
    return !levels.containsKey(level);
  }

  /// Publishes this person's price list with [kind] priced by [levels]
  /// ({friend, fof, stranger}; a level left out is not offered to), the
  /// other kinds as they are. Null or empty: [kind] not offered at all.
  /// The first-message price ('inbox') comes from the settings of the
  /// conversations outside friends.
  Future<PyramidRecord?> setOfferKind(
    String kind,
    Map<String, int>? levels,
  ) async {
    final String? k = myKey;
    final PyramidState? s = state;
    if (k == null || s == null || !s.isMember(k)) {
      return null;
    }
    final Map<String, int> priced = <String, int>{
      for (final MapEntry<String, int> e
          in (levels ?? const <String, int>{}).entries)
        if (kPriceLevels.containsKey(e.key) && e.value >= 0)
          e.key: min(e.value, kPyrMaxAmount),
    };
    final Map<String, Map<String, int>> all = <String, Map<String, int>>{
      for (final MapEntry<String, Map<String, int>> e
          in (s.offerLevels[k] ?? const <String, Map<String, int>>{}).entries)
        if (e.key != kind) e.key: e.value,
      if (priced.isNotEmpty) kind: priced,
    };
    return propose(
      <String, dynamic>{'t': PyrT.offer, 'prices': all},
      candidates: <String>[k],
      need: 1,
    );
  }

  /// Writes to member [to] through the market: pays the asked price as a
  /// conditional payment that [to] keeps or returns. An announcement
  /// ('ad') may go through [steps] intermediaries, each keeping [share]
  /// (at least what [to] asks); [to] is the first of them. A message
  /// ('inbox') to someone who takes none from this person's level does not
  /// go.
  Future<bool> sendMarket(
    String to,
    String kind,
    String text, {
    int steps = 1,
    int? share,
    Map<String, dynamic>? post,
  }) async {
    final PyramidState? s = state;
    final String? me = myKey;
    final PyrMember? m = s?.members[to];
    // A reshare on order carries the post itself; its text is the preview.
    final String? postText = kind == 'reshare'
        ? await marketPostText(post)
        : null;
    if (kind == 'reshare' && postText == null) {
      return false;
    }
    final String content = postText ?? text;
    if (s == null ||
        me == null ||
        m == null ||
        m.addr.isEmpty ||
        content.trim().isEmpty ||
        to == me) {
      return false;
    }
    final String body = content.trim();
    final ({int price, String? level}) asked = priceToSend(to, kind);
    if (kind == 'inbox' && closedTo(to, asked.level)) {
      return false;
    }
    final int hops = kind == 'ad' ? steps.clamp(1, kMaxAdHops) - 1 : 0;
    final int each = hops > 0
        ? max(share ?? asked.price, asked.price)
        : asked.price;
    String? paymentId;
    if (each > 0) {
      final PyramidRecord? order = await pay(
        to,
        each * (hops + 1),
        memo: kMarketKinds[kind] ?? kind,
        condBy: to,
        share: hops > 0 ? each : 0,
        hops: hops,
        hash: hops > 0 ? contentHash(body) : null,
      );
      if (order == null) {
        return false;
      }
      paymentId = order.id;
    }
    final PyrMarketMessage msg = PyrMarketMessage(
      id: _newId(16),
      kind: kind,
      from: to,
      text: body,
      at: _now(),
      payment: paymentId,
      amount: each * (hops + 1),
      mine: true,
      hops: hops,
      level: asked.level,
      post: postText == null ? null : post,
    );
    market[msg.id] = msg;
    await _save();
    await _send(m.addr, <String, dynamic>{
      'type': PyramidTypes.dm,
      'id': msg.id,
      'k': kind,
      'f': me,
      't': msg.text,
      'x': ?paymentId,
      'a': each,
      if (hops > 0) 'h': hops,
      if (postText != null) 'en': post,
    });
    return true;
  }

  /// Market messages whose payment has arrived meanwhile are taken now;
  /// those still without it after two days are dropped.
  Future<void> _retryHeld() async {
    if (_marketHeld.isEmpty || _retryingHeld) {
      return;
    }
    _retryingHeld = true;
    try {
      final List<Map<String, dynamic>> held = List<Map<String, dynamic>>.of(
        _marketHeld,
      );
      _marketHeld.clear();
      final int t = _now();
      bool changed = false;
      for (final Map<String, dynamic> h in held) {
        final Object? p = h['p'];
        final Object? f = h['f'];
        final Object? at = h['at'];
        if (p is! Map ||
            f is! String ||
            at is! int ||
            t - at > 2 * 24 * 3600 * 1000) {
          changed = true;
          continue;
        }
        final Object? payment = p['x'];
        if (payment is String && state?.escrows[payment] == null) {
          _marketHeld.add(h);
          continue;
        }
        changed = true;
        await _onMarket(f, Map<String, dynamic>.from(p), held: true);
      }
      if (changed) {
        await _save();
      }
    } finally {
      _retryingHeld = false;
    }
  }

  Future<void> _onMarket(
    String from,
    Map<String, dynamic> p, {
    bool held = false,
  }) async {
    final Object? id = p['id'];
    final Object? kind = p['k'];
    final Object? sender = p['f'];
    final Object? text = p['t'];
    final PyramidState? s = state;
    final String? me = myKey;
    if (id is! String ||
        kind is! String ||
        sender is! String ||
        text is! String ||
        id.isEmpty ||
        id.length > 64 ||
        !kMarketKinds.containsKey(kind) ||
        market.containsKey(id) ||
        s == null ||
        me == null) {
      return;
    }
    if (_n(s.members[sender]?.addr ?? '') != _n(from)) {
      return;
    }
    // A reshare on order brings the post to share: it has to be a
    // signed public post, and what this person sees is its own text.
    final Object? en = p['en'];
    Map<String, dynamic>? post;
    String body = text;
    if (kind == 'reshare') {
      if (en is! Map || jsonEncode(en).length > kMarketPostMaxBytes) {
        return;
      }
      post = Map<String, dynamic>.from(en);
      final String? shown = await marketPostText(post);
      if (shown == null) {
        return;
      }
      body = shown;
    }
    final String? payment = p['x'] is String ? p['x'] as String : null;
    final String? origin = p['o'] is String && s.members.containsKey(p['o'])
        ? p['o'] as String
        : null;
    // The price for the sender's level, as this phone knows them; a
    // message from a level this person takes none from does not come in.
    final String level = levelOfAddress(from) ?? 'stranger';
    final bool closed = kind == 'inbox' && closedTo(me, level);
    final int asked = s.priceFor(me, kind, level) ?? 0;
    final PyrEscrow? escrow = payment == null ? null : s.escrows[payment];
    if (payment != null && escrow == null) {
      // The payment has not reached this phone yet: the message waits for
      // it. One that never comes (made up) never gets the message in.
      if (!held) {
        // Only what the message needs, the text cut (no blob kept here).
        _marketHeld.add(<String, dynamic>{
          'f': from,
          'p': <String, dynamic>{
            'id': id,
            'k': kind,
            'f': sender,
            't': _cut(body, 4000),
            'x': payment,
            if (p['h'] is int) 'h': p['h'],
            'o': ?origin,
            'en': ?post,
          },
          'at': _now(),
        });
        while (_marketHeld.length > 200) {
          _marketHeld.removeAt(0);
        }
        await _save();
      }
      return;
    }
    // What is really paid is what the payment holds, never what the
    // message says: to this person, from the sender (or the one who paid
    // for the announcement), not settled, waiting long enough for the
    // answer, and for an announcement the very text paid for.
    int paid = 0;
    bool forged = false;
    if (escrow != null) {
      paid = escrow.isChain ? min(escrow.share, escrow.amount) : escrow.amount;
      forged =
          escrow.condBy != me ||
          escrow.to != me ||
          escrow.from != (origin ?? sender) ||
          escrow.settled != null ||
          escrow.until < _now() + kPyrMarketMinWaitMs ||
          (escrow.hash != null && escrow.hash != contentHash(body));
    }
    if (forged || closed || paid < asked) {
      if (escrow != null && escrow.condBy == me && escrow.settled == null) {
        // Not enough for this level, or not what was paid for: back.
        await settle(payment!, false);
      }
      return;
    }
    final int hops = kind != 'ad'
        ? 0
        : escrow != null && escrow.isChain
        ? escrow.hops
        : p['h'] is int
        ? (p['h'] as int).clamp(0, kMaxAdHops - 1)
        : 0;
    market[id] = PyrMarketMessage(
      id: id,
      kind: kind,
      from: sender,
      text: _cut(body, 4000),
      at: _now(),
      payment: payment,
      amount: paid,
      hops: hops,
      origin: origin,
      level: level,
      post: post,
    );
    _trimMarket(sender);
    if (!market.containsKey(id)) {
      return;
    }
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'pyr-dm-$id',
        title: t('{kind} od {name}', {
          'kind': kMarketKinds[kind] ?? kind,
          'name': s.members[origin ?? sender]?.name ?? '?',
        }),
        body: body,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.message,
        slotKey: 'pyr-dm',
      ),
    );
  }

  /// At most [kPyrMarketOpenPerSender] open messages from [sender] and
  /// [kPyrMarketTotal] messages in all: the oldest go (answered ones first).
  void _trimMarket(String sender) {
    final List<PyrMarketMessage> open =
        market.values
            .where(
              (PyrMarketMessage m) => !m.mine && !m.done && m.from == sender,
            )
            .toList()
          ..sort(
            (PyrMarketMessage a, PyrMarketMessage b) => a.at.compareTo(b.at),
          );
    for (final PyrMarketMessage m in open.take(
      max(0, open.length - kPyrMarketOpenPerSender),
    )) {
      market.remove(m.id);
    }
    if (market.length <= kPyrMarketTotal) {
      return;
    }
    final List<PyrMarketMessage> all = market.values.toList()
      ..sort((PyrMarketMessage a, PyrMarketMessage b) {
        final int byDone = (b.done ? 1 : 0).compareTo(a.done ? 1 : 0);
        return byDone != 0 ? byDone : a.at.compareTo(b.at);
      });
    for (final PyrMarketMessage m in all.take(all.length - kPyrMarketTotal)) {
      market.remove(m.id);
    }
  }

  /// Keeps the payment (for a reshare on order, once the post is shared with
  /// this person's friends; for an announcement, posting it to this
  /// person's branch) or returns it. An announcement that may go
  /// further is passed on to [next] (a member), with the rest of the money
  /// waiting for them.
  Future<void> answerMarket(
    String id, {
    required bool accept,
    String? next,
  }) async {
    final PyrMarketMessage? m = market[id];
    if (m == null || m.mine || m.done) {
      return;
    }
    final PyramidState? s = state;
    final String? me = myKey;
    final PyrEscrow? held = m.payment == null ? null : s?.escrows[m.payment];
    final bool mayGoOn =
        m.kind == 'ad' && m.hops > 0 && (held == null || held.hops > 0);
    final String? onward =
        accept &&
            mayGoOn &&
            next != null &&
            next != me &&
            next != m.from &&
            next != m.origin
        ? next
        : null;
    final String onwardAddr = onward == null
        ? ''
        : s?.members[onward]?.addr ?? '';
    m.done = true;
    await _save();
    if (m.kind == 'reshare') {
      // Shared first, paid after: the money is kept only when the
      // post really went out to this person's friends.
      final Map<String, dynamic>? shared = m.post;
      final Future<bool> Function(Map<String, dynamic>)? share = resharePost;
      final bool done =
          accept && shared != null && share != null && await share(shared);
      if (m.payment != null) {
        await settle(m.payment!, done);
      }
      return;
    }
    PyramidRecord? settled;
    if (m.payment != null) {
      settled = await settle(
        m.payment!,
        accept,
        next: onwardAddr.isEmpty ? null : onward,
      );
    }
    if (accept && m.kind == 'ad') {
      await post(m.text);
    }
    if (onward == null || onwardAddr.isEmpty || me == null) {
      return;
    }
    // Passed on: the next one sees who wrote it and gets the same share.
    final String? escrow = m.payment == null ? null : settled?.id;
    if (m.payment != null && escrow == null) {
      return;
    }
    await _send(onwardAddr, <String, dynamic>{
      'type': PyramidTypes.dm,
      'id': _newId(16),
      'k': 'ad',
      'f': me,
      't': m.text,
      'x': ?escrow,
      'a': m.amount,
      'h': m.hops - 1,
      'o': m.origin ?? m.from,
    });
  }

  // ---- alarm ----

  Future<PyramidRecord?> alarm(
    String text, {
    String scopeKind = 'all',
    String scopePath = '',
    String scopeNat = '',
    Duration length = const Duration(days: 1),
    String? via,
  }) async {
    final PyramidState? s = state;
    final ({String kind, String path}) scope = _delegatedScope(
      via,
      scopeKind,
      scopePath,
    );
    final Map<String, dynamic> body = <String, dynamic>{
      't': PyrT.alarm,
      'text': text,
      'scope': <String, String>{
        'k': scope.kind,
        'p': scope.path,
        'nat': scopeNat,
      },
      'until': _now() + length.inMilliseconds,
    };
    if (scopeKind == 'nat' && s != null && s.nationalLead(scopeNat) == myKey) {
      return propose(body, candidates: <String>[myKey!], need: 1);
    }
    return topDecision(body, via: via);
  }

  // ---- national section, badge ----

  /// The section's lead pins (or unpins) a post of the section.
  Future<PyramidRecord?> pinNational(String postId, {bool on = true}) async {
    final PyramidState? s = state;
    final String? k = myKey;
    final String? nat = s?.natPosts[postId]?.nat;
    if (s == null || k == null || nat == null || s.nationalLead(nat) != k) {
      return null;
    }
    return propose(
      <String, dynamic>{'t': PyrT.natPin, 'nat': nat, 'post': postId, 'on': on},
      candidates: <String>[k],
      need: 1,
    );
  }

  /// Confirms that this person knows [key], somebody of their cell
  /// ("poznaliśmy się" — knowing each other, not a meeting): from then on
  /// [key] votes in the cell and in referenda. Null when [key] is no
  /// cellmate without a vote, this person has no vote yet, or it was said
  /// already.
  Future<PyramidRecord?> confirmKnown(String key) async {
    final PyramidState? s = state;
    final String? me = myKey;
    final int t = _now();
    if (s == null ||
        me == null ||
        !s.cellmates(key).contains(me) ||
        !s.canVote(me, t) ||
        s.canVote(key, t) ||
        (s.knownBy[key]?.containsKey(me) ?? false)) {
      return null;
    }
    return propose(
      <String, dynamic>{'t': PyrT.known, 'k': key},
      candidates: <String>[me],
      need: 1,
    );
  }

  /// Shows (or hides) this person's gender badge: the gender
  /// confirmed at admission is opened publicly, so anybody can check it
  /// against the commitment (the age shows anyway). Null when there is
  /// nothing to show.
  Future<PyramidRecord?> showBadge(bool show) async {
    final String? k = myKey;
    final Object? gender = myData['g'];
    final Object? salt = myData['salt'];
    if (k == null || !isMember) {
      return null;
    }
    if (show && (gender is! String || salt is! String)) {
      return null;
    }
    return propose(
      show
          ? <String, dynamic>{
              't': PyrT.badge,
              'k': k,
              'g': gender,
              'salt': salt,
            }
          : <String, dynamic>{'t': PyrT.badge, 'k': k, 'off': true},
      candidates: <String>[k],
      need: 1,
    );
  }

  // ---- pyramid posts read from outside ----

  /// The nationalities in this person's profile, as country codes.
  List<String> get profileNationalities => <String>[
    for (final String c in myNationalities?.call() ?? const <String>[])
      if (c.trim().isNotEmpty) c.trim().toUpperCase(),
  ];

  /// The national section of [nat] as somebody who is not its member reads
  /// it (read-only): from the records this phone keeps (it is joining,
  /// say) and what friends who are members passed on. Pinned first, then
  /// the lead's, then by level, newest first in one.
  List<PyrNationalPost> nationalSection(String nat) =>
      _readFromOutside((PyrNationalPost p) => !p.top && p.nat == nat);

  /// The top's posts to the whole pyramid as somebody who is not a member
  /// reads them, the same way; newest first.
  List<PyrNationalPost> topPosts() =>
      _readFromOutside((PyrNationalPost p) => p.top);

  List<PyrNationalPost> _readFromOutside(bool Function(PyrNationalPost) of) {
    final Map<String, PyrNationalPost> out = <String, PyrNationalPost>{};
    final PyramidState? s = state;
    if (s != null) {
      final Set<String> banned = s.bannedEntries(_now());
      for (final PyrPost p in <PyrPost>[
        ...s.natPosts.values,
        ...s.posts.values,
      ]) {
        if (!banned.contains(p.id)) {
          if (_readerCopy(s, p) case final PyrNationalPost x when of(x)) {
            out[x.id] = x;
          }
        }
      }
    }
    // What the records here hold wins over a friend's view of it.
    for (final PyrNationalPost p in _nationalFeed.values) {
      if (p.pyramid == current && of(p)) {
        out.putIfAbsent(p.id, () => p);
      }
    }
    return out.values.toList()..sort(_nationalOrder);
  }

  static int _nationalOrder(PyrNationalPost a, PyrNationalPost b) {
    if (a.pinned != b.pinned) {
      return a.pinned ? -1 : 1;
    }
    if (a.lead != b.lead) {
      return a.lead ? -1 : 1;
    }
    return a.level != b.level
        ? a.level.compareTo(b.level)
        : b.at.compareTo(a.at);
  }

  /// What the pyramid puts on this person's Tablica (one rule of who sees
  /// what): a member's from the records, anybody else's from what member
  /// friends passed on.
  PyramidFeed get feed {
    final PyramidState? s = state;
    final String? me = myKey;
    final bool member = s != null && me != null && s.isMember(me);
    // Built again only when what it reads changed (the Tablica asks on
    // every build): the folded state, the posts from outside, the votes,
    // the profile's nationalities, the minute (ends of votes, alarms).
    final Object key = (
      s,
      me,
      _nationalRevision,
      myVotes.length,
      _now() ~/ 60000,
      profileNationalities.join(','),
    );
    final PyramidFeed? kept = _feedKept;
    if (kept != null && _feedKey == key) {
      return kept;
    }
    _feedKey = key;
    return _feedKept = pyramidFeedOf(
      state: s,
      me: me,
      now: _now(),
      top: member ? const <PyrNationalPost>[] : topPosts(),
      national: member
          ? const <PyrNationalPost>[]
          : <PyrNationalPost>[
              for (final String nat in profileNationalities.toSet())
                ...nationalSection(nat),
            ],
      voted: myVotes.keys.toSet(),
    );
  }

  PyramidFeed? _feedKept;
  Object? _feedKey;

  /// Bumped whenever the posts read from outside change.
  int _nationalRevision = 0;

  /// Post [p] of [s] as a reader outside gets it, with what this phone sees
  /// of it in the pyramid: a national-section post, or one written at the
  /// top (to the whole pyramid). Null for any other.
  PyrNationalPost? _readerCopy(PyramidState s, PyrPost p) {
    final PyramidRecord? r = _records[p.id];
    final String nat = p.nat ?? '';
    final bool top = p.nat == null && p.level == 0;
    if (r == null || (nat.isEmpty && !top)) {
      return null;
    }
    final String? path = s.pathOf(p.author);
    return PyrNationalPost(
      record: r,
      name: s.members[p.author]?.name ?? '',
      depth: s.depth,
      branch: path == null ? 0 : s.branchSize(path),
      lead: !top && s.nationalLead(nat) == p.author,
      pinned: !top && (s.natPins[nat]?.containsKey(p.id) ?? false),
      comments: p.comments.length,
    );
  }

  /// Whether the friend at [address] is outside pyramid [s]: no member's
  /// address, and it did not say it keeps the pyramid (it would sync it).
  bool _outside(PyramidState s, String address) {
    final String a = _n(address);
    if (_peers[a]?.contains(s.id) ?? false) {
      return false;
    }
    return !s.members.values.any((PyrMember m) => _n(m.addr) == a);
  }

  /// The nationalities [address]'s profile shows this device, as codes.
  Set<String> _nationsOf(String address) => <String>{
    for (final String c in nationalitiesOf?.call(address) ?? const <String>[])
      c.trim().toUpperCase(),
  };

  /// Whether [x] is read outside the pyramid: a national-section post or
  /// one written at the top.
  static bool _readOutside(PyramidRecord x) =>
      x.type == PyrT.natPost || (x.type == PyrT.post && x.integer('lvl') == 0);

  /// Passes posts just taken in on to friends outside the pyramid: the
  /// top's to every such friend, a section's to those whose profile shows
  /// that nationality. One frame per friend and kind, the newest
  /// [kPyrNationalBatch] (a big sync passes on no more). Members only: a
  /// reader outside passes nothing on.
  Future<void> _passNational(List<PyramidRecord> added) async {
    final String? me = myKey;
    final PyramidState? s = state;
    if (me == null ||
        s == null ||
        !s.isMember(me) ||
        !added.any(_readOutside)) {
      return;
    }
    final Map<String, List<PyrNationalPost>> to =
        <String, List<PyrNationalPost>>{};
    final List<String> friends = host.friends();
    for (final PyramidRecord x in added) {
      if (!_readOutside(x)) {
        continue;
      }
      final PyrPost? p = x.type == PyrT.natPost
          ? s.natPosts[x.id]
          : s.posts[x.id];
      final PyrNationalPost? out = p == null ? null : _readerCopy(s, p);
      if (out == null ||
          out.record.signedBytes.length > kPyrNationalPostBytes) {
        continue;
      }
      for (final String f in friends) {
        if (_outside(s, f) && (out.top || _nationsOf(f).contains(out.nat))) {
          (to[_n(f)] ??= <PyrNationalPost>[]).add(out);
        }
      }
    }
    for (final String f in to.keys.toList()..sort()) {
      final List<PyrNationalPost> posts = to[f]!
        ..sort((PyrNationalPost a, PyrNationalPost b) => b.at.compareTo(a.at));
      for (final bool top in <bool>[true, false]) {
        final List<Map<String, dynamic>> frame = <Map<String, dynamic>>[
          for (final PyrNationalPost p
              in posts
                  .where((PyrNationalPost x) => x.top == top)
                  .take(kPyrNationalBatch))
            p.toJson(),
        ];
        if (frame.isNotEmpty) {
          await _send(f, <String, dynamic>{
            'type': PyramidTypes.national,
            'ps': frame,
            if (top) 'hc': _powerLine(s),
          });
        }
      }
    }
  }

  /// The power key's line as the records here have it (the founding and
  /// the handovers that counted): a reader outside checks with it, from
  /// the pinned genesis, that a post of the top is the head's
  /// ([certifiedHeads]).
  List<Map<String, dynamic>> _powerLine(PyramidState s) =>
      <Map<String, dynamic>>[
        for (final PyramidRecord r in _records.values)
          if ((r.type == PyrT.found || r.type == PyrT.handover) &&
              s.applied.contains(r.id))
            r.toJson(),
      ];

  /// Sends the friend at [to], outside the pyramid, the posts it lacks:
  /// the top's newer than [topSince], those of the sections its profile
  /// shows newer than [since] (each pyramid → newest it has); the newest
  /// [kPyrNationalBatch] of each kind.
  Future<void> _catchUpNational(
    String to,
    Object? since,
    Object? topSince,
  ) async {
    final PyramidState? s = state;
    if (s == null || !isMember || !_outside(s, to)) {
      return;
    }
    int after(Object? m) {
      final Object? had = m is Map ? m[s.id] : null;
      return had is int ? had : 0;
    }

    final Set<String> nats = _nationsOf(to);
    final Set<String> banned = s.bannedEntries(_now());
    final int natAfter = after(since);
    final int topAfter = after(topSince);
    for (final (bool top, List<PyrPost> posts) in <(bool, List<PyrPost>)>[
      (
        true,
        <PyrPost>[
          for (final PyrPost p in s.posts.values)
            if (p.level == 0 && p.at > topAfter && !banned.contains(p.id)) p,
        ],
      ),
      (
        false,
        <PyrPost>[
          for (final PyrPost p in s.natPosts.values)
            if (nats.contains(p.nat) &&
                p.at > natAfter &&
                !banned.contains(p.id))
              p,
        ],
      ),
    ]) {
      posts.sort((PyrPost a, PyrPost b) => b.at.compareTo(a.at));
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[
        for (final PyrPost p in posts.take(kPyrNationalBatch))
          if (_readerCopy(s, p) case final PyrNationalPost x
              when x.record.signedBytes.length <= kPyrNationalPostBytes)
            x.toJson(),
      ];
      if (out.isNotEmpty) {
        await _send(to, <String, dynamic>{
          'type': PyramidTypes.national,
          'ps': out,
          if (top) 'hc': _powerLine(s),
        });
      }
    }
  }

  /// The newest post of one kind (the top's, or the sections') this phone
  /// has read from outside, per pyramid (in the hello: friends send only
  /// what is newer).
  Map<String, int> _nationalSince({required bool top}) {
    final Map<String, int> out = <String, int>{};
    for (final PyrNationalPost p in _nationalFeed.values) {
      if (p.top == top && (out[p.pyramid] ?? -1) < p.at) {
        out[p.pyramid] = p.at;
      }
    }
    return out;
  }

  /// Posts a friend passed on: kept when the author's signature holds, of
  /// the pinned pyramid, the top's or of a nationality in this person's
  /// profile. A post of the top only from the head the power key's line
  /// names for its time (the frame carries the line, checked from the
  /// pinned genesis): anybody can sign "level 0". A member reads them from
  /// the records instead.
  Future<void> _onNational(String from, Map<String, dynamic> p) async {
    final Set<String> mine = profileNationalities.toSet();
    final Object? list = p['ps'];
    if (list is! List || isMember) {
      return;
    }
    final int t = _now();
    bool changed = false;
    List<PyrCertifiedHead>? heads;
    Future<List<PyrCertifiedHead>> headsNow() async =>
        heads ??= await _headsFrom(p['hc']);
    for (final Object? item in list.take(kPyrNationalBatch)) {
      final PyrNationalPost? post = PyrNationalPost.fromJson(item, from: from);
      if (post == null ||
          (!post.top && !mine.contains(post.nat)) ||
          post.pyramid != current ||
          post.at > t + kPyrMaxSkewMs) {
        continue;
      }
      final PyrNationalPost? had = _nationalFeed[post.id];
      if (had == null &&
          (!await post.record.verifySigners() ||
              (post.top && !byCertifiedHead(await headsNow(), post)))) {
        continue;
      }
      // The same signed record: only what the friend sees of it changes.
      final PyrNationalPost next = had == null
          ? post
          : PyrNationalPost(
              record: had.record,
              name: post.name,
              depth: post.depth,
              branch: post.branch,
              lead: post.lead,
              pinned: post.pinned,
              comments: post.comments,
              from: from,
            );
      if (had == null ||
          jsonEncode(had.toJson()) != jsonEncode(next.toJson())) {
        _nationalFeed[post.id] = next;
        changed = true;
      }
    }
    // Nationalities taken off the profile are not read any more.
    final int before = _nationalFeed.length;
    _nationalFeed.removeWhere(
      (String _, PyrNationalPost x) => !x.top && !mine.contains(x.nat),
    );
    changed = changed || _nationalFeed.length != before;
    if (!changed) {
      return;
    }
    _trimNational();
    _nationalRevision++;
    await _saveNational();
    notifyListeners();
  }

  /// The heads the power key's line [json] certifies, from the pinned
  /// genesis ([certifiedHeads]); the last line checked is remembered (the
  /// same comes with every frame).
  Future<List<PyrCertifiedHead>> _headsFrom(Object? json) async {
    final PyramidRoot? r = root;
    if (r == null || json is! List) {
      return const <PyrCertifiedHead>[];
    }
    final List<PyramidRecord> chain = <PyramidRecord>[
      for (final Object? j in json.take(kPyrPowerLineMax))
        ?PyramidRecord.fromJson(j),
    ];
    final String key = (chain.map((PyramidRecord x) => x.id).toList()..sort())
        .join(',');
    final (String, List<PyrCertifiedHead>)? had = _heads;
    if (had != null && had.$1 == key) {
      return had.$2;
    }
    final List<PyrCertifiedHead> heads = await certifiedHeads(r.genesis, chain);
    _heads = (key, heads);
    return heads;
  }

  /// The power key's line last checked ([_headsFrom]).
  (String, List<PyrCertifiedHead>)? _heads;

  /// At most [kPyrNationalKept] per nationality and of the top, the newest.
  void _trimNational() {
    final Map<String, List<PyrNationalPost>> byNat =
        <String, List<PyrNationalPost>>{};
    for (final PyrNationalPost p in _nationalFeed.values) {
      (byNat[p.top ? '' : p.nat] ??= <PyrNationalPost>[]).add(p);
    }
    for (final List<PyrNationalPost> list in byNat.values) {
      if (list.length <= kPyrNationalKept) {
        continue;
      }
      list.sort((PyrNationalPost a, PyrNationalPost b) => b.at.compareTo(a.at));
      for (final PyrNationalPost p in list.skip(kPyrNationalKept)) {
        _nationalFeed.remove(p.id);
      }
    }
  }

  Future<void> _saveNational() async {
    if (_diskUnreadable) {
      return;
    }
    await disk.write(
      _keyNational,
      utf8.encode(
        jsonEncode(<Map<String, dynamic>>[
          for (final PyrNationalPost p in _nationalFeed.values) p.toJson(),
        ]),
      ),
    );
  }

  // ---- anonymous sums up the tree ----

  /// Notes that this person read pyramid posts [ids] ("przeczytało"): the
  /// Tablica calls it once a card was really on the screen.
  void markRead(Iterable<String> ids) {
    final int t = _now();
    bool added = false;
    for (final String id in ids) {
      if (!_readPosts.containsKey(id)) {
        _readPosts[id] = t;
        added = true;
      }
    }
    if (added) {
      // Saved (and told) at once: a post read stays read after a restart.
      unawaited(_save());
    }
  }

  /// Whether this person read pyramid post [id] ([markRead]).
  bool wasRead(String id) => _readPosts.containsKey(id);

  /// This person's own numbers for [topic] in [s].
  List<int>? _ownSum(PyramidState s, String me, String topic) {
    if (topic == kPyrStatsTopic) {
      final List<int> out = List<int>.filled(kPyrStatsBuckets, 0);
      final Object? year = myData['by'];
      final Object? gender = myData['g'];
      if (year is int && year > 0 && gender is String) {
        final int now = DateTime.fromMillisecondsSinceEpoch(_now()).year;
        out[pyrStatsBucket(year, gender, now)] = 1;
      }
      return out;
    }
    final PyrPost? post = s.posts[topic.substring(2)];
    final String? ap = post == null ? null : s.pathOf(post.author);
    final String? mine = s.pathOf(me);
    if (ap == null || mine == null) {
      return null;
    }
    // The author does not count themself.
    final bool got = mine != ap && PyrPath.within(mine, ap);
    return <int>[
      if (got) 1 else 0,
      if (got && _readPosts.containsKey(topic.substring(2))) 1 else 0,
    ];
  }

  /// The numbers of this person's branch for [topic]: their own and the
  /// newest of each member right below (who is there now).
  List<int>? _branchSum(PyramidState s, String me, String topic) {
    final List<int>? own = _ownSum(s, me, topic);
    final String? mine = s.pathOf(me);
    if (own == null || mine == null) {
      return null;
    }
    final List<int> sum = List<int>.of(own);
    final Map<String, List<int>> below =
        _sumsBelow[topic] ?? const <String, List<int>>{};
    for (final String c in PyrPath.children(mine)) {
      final List<int>? kid = below[s.occupant[c] ?? ''];
      if (kid == null || kid.length != sum.length) {
        continue;
      }
      for (int i = 0; i < sum.length; i++) {
        sum[i] += kid[i];
      }
    }
    return sum;
  }

  /// "Dotarło / przeczytało" for this person's own post [postId]:
  /// how many in the branch have it and how many opened it, as the sums
  /// came up the tree. Null for anybody else's post.
  ({int got, int read})? reachOf(String postId) {
    final PyramidState? s = state;
    final String? me = myKey;
    if (s == null || me == null || s.posts[postId]?.author != me) {
      return null;
    }
    final List<int>? sum = _branchSum(s, me, 'r|$postId');
    return sum == null ? null : (got: sum[0], read: sum[1]);
  }

  /// Anonymous statistics of this person's branch: people by
  /// gender and age ([pyrStatsBucket]), null below [kPyrStatsMinPeople].
  List<int>? branchStats() {
    final PyramidState? s = state;
    final String? me = myKey;
    if (s == null || me == null || !s.isMember(me)) {
      return null;
    }
    final List<int>? sum = _branchSum(s, me, kPyrStatsTopic);
    if (sum == null ||
        sum.fold(0, (int a, int b) => a + b) < kPyrStatsMinPeople) {
      return null;
    }
    return sum;
  }

  /// The topics this person sends up now: the statistics, and the reach
  /// of the newest political posts of the line above.
  List<String> _sumTopics(PyramidState s, String mine) {
    final int t = _now();
    final List<PyrPost> posts = s.posts.values.where((PyrPost p) {
      final String? ap = s.pathOf(p.author);
      return t - p.at <= kPyrReachMaxAgeMs &&
          ap != null &&
          ap != mine &&
          PyrPath.within(mine, ap);
    }).toList()..sort((PyrPost a, PyrPost b) => b.at.compareTo(a.at));
    return <String>[
      kPyrStatsTopic,
      for (final PyrPost p in posts.take(kPyrReachPosts)) 'r|${p.id}',
    ];
  }

  /// Sends the branch's sums that changed to the cell head above, and
  /// forgets the ones nobody counts any more.
  Future<void> _sumDuties(PyramidState s, String me) async {
    final String? mine = s.pathOf(me);
    if (mine == null) {
      return;
    }
    final int t = _now();
    _readPosts.removeWhere((String _, int at) => t - at > kPyrReachMaxAgeMs);
    final Set<String> live = <String>{
      kPyrStatsTopic,
      for (final PyrPost p in s.posts.values)
        if (t - p.at <= kPyrReachMaxAgeMs) 'r|${p.id}',
    };
    _sumsBelow.removeWhere((String topic, _) => !live.contains(topic));
    _sumsSent.removeWhere((String topic, _) => !live.contains(topic));
    if (mine.isEmpty) {
      return;
    }
    final String addr =
        s.members[s.occupant[PyrPath.parent(mine)] ?? '']?.addr ?? '';
    if (addr.isEmpty) {
      return;
    }
    final Map<String, List<int>> changed = <String, List<int>>{};
    for (final String topic in _sumTopics(s, mine)) {
      final List<int>? sum = _branchSum(s, me, topic);
      final List<int>? sent = _sumsSent[topic];
      if (sum != null && !listEquals(sum, sent)) {
        changed[topic] = sum;
      }
    }
    if (changed.isEmpty) {
      return;
    }
    _sumsSent.addAll(changed);
    await _save();
    await _send(addr, <String, dynamic>{
      'type': PyramidTypes.sum,
      'py': s.id,
      's': changed,
    });
  }

  /// Sums from a member right below this person: each topic checked (a
  /// post of this person's line, numbers no bigger than the sender's
  /// branch) and kept as that member's newest.
  Future<void> _onSums(String from, Map<String, dynamic> p) async {
    final PyramidState? s = state;
    final String? me = myKey;
    final String? mine = me == null ? null : s?.pathOf(me);
    final Object? sums = p['s'];
    if (s == null || mine == null || p['py'] != s.id || sums is! Map) {
      return;
    }
    final String? child = _membersAt(s, from)
        .where((String k) => PyrPath.parent(s.pathOf(k) ?? '') == mine)
        .where((String k) => s.pathOf(k) != mine)
        .firstOrNull;
    if (child == null) {
      return;
    }
    final int cap = s.branchSize(s.pathOf(child)!);
    bool changed = false;
    for (final MapEntry<dynamic, dynamic> e in sums.entries.take(
      kPyrReachPosts + 1,
    )) {
      final Object? topic = e.key;
      final Object? raw = e.value;
      if (topic is! String || raw is! List) {
        continue;
      }
      final int size;
      if (topic == kPyrStatsTopic) {
        size = kPyrStatsBuckets;
      } else if (topic.startsWith('r|')) {
        final PyrPost? post = s.posts[topic.substring(2)];
        final String? ap = post == null ? null : s.pathOf(post.author);
        if (ap == null || !PyrPath.within(mine, ap)) {
          continue;
        }
        size = 2;
      } else {
        continue;
      }
      final List<int> v = raw.whereType<int>().toList();
      if (v.length != size ||
          v.any((int x) => x < 0 || x > cap) ||
          v.fold(0, (int a, int b) => a + b) > (size == 2 ? 2 * cap : cap)) {
        continue;
      }
      (_sumsBelow[topic] ??= <String, List<int>>{})[child] = v;
      changed = true;
    }
    if (changed) {
      await _save();
    }
  }

  // ---- reports ----

  /// The delegates for reports whose branch covers this person, by the
  /// depth of that branch, the narrowest first: the steps a report climbs.
  List<List<String>> _reportSteps(PyramidState s) {
    final String? k = myKey;
    final String myPath = k == null ? '' : s.pathOf(k) ?? '';
    final Map<int, Set<String>> byDepth = <int, Set<String>>{};
    for (final PyrDelegation d in s.delegations.values) {
      if (d.power == 'reports' &&
          !d.revoked &&
          d.until > _now() &&
          s.isMember(d.to) &&
          PyrPath.within(myPath, d.scope)) {
        (byDepth[d.scope.length] ??= <String>{}).add(d.to);
      }
    }
    final List<int> depths = byDepth.keys.toList()
      ..sort((int a, int b) => b.compareTo(a));
    return <List<String>>[
      for (final int d in depths) byDepth[d]!.toList()..sort(),
    ];
  }

  /// Who gets a report of this person at escalation [stage]: the
  /// delegates of the narrowest branch around them first, then level by
  /// level the wider ones, at last the top.
  List<String> _reportReceivers(int stage) {
    final PyramidState? s = state;
    if (s == null) {
      return const <String>[];
    }
    final List<List<String>> steps = _reportSteps(s);
    return stage < steps.length ? steps[stage] : s.topCell;
  }

  /// Whether [stage] is the last step, the top.
  bool _reportAtTop(int stage) {
    final PyramidState? s = state;
    return s == null || stage >= _reportSteps(s).length;
  }

  /// Reports something. [entryId] names the reported entry (a
  /// post, comment or message) and [entry] is its signed original when
  /// this phone has it: a ban then names the entry.
  Future<PyrReport> report({
    required String reason,
    String target = '',
    String evidence = '',
    String? datingKey,
    String? entryId,
    Map<String, dynamic>? entry,
  }) async {
    final Map<String, dynamic>? original =
        entry != null &&
            utf8.encode(jsonEncode(entry)).length <= kPyrReportEntryBytes
        ? entry
        : null;
    final int t = _now();
    final PyrReport r = PyrReport(
      id: _newId(16),
      reason: reason,
      at: t,
      target: target,
      evidence: _cut(evidence, kPyrReportEvidenceChars),
      datingKey: datingKey,
      entryId: entryId != null && entryId.isNotEmpty && entryId.length <= 128
          ? entryId
          : null,
      entry: original,
      sentAt: t,
    );
    r.escalated = _reportAtTop(0);
    myReports[r.id] = r;
    // Only the newest are remembered.
    while (myReports.length > kPyrMyReportsKept) {
      final PyrReport oldest = myReports.values.reduce(
        (PyrReport a, PyrReport b) => b.at < a.at ? b : a,
      );
      myReports.remove(oldest.id);
    }
    await _save();
    await _sendReport(r, _reportReceivers(0));
    return r;
  }

  Future<void> _sendReport(PyrReport r, List<String> to) async {
    final PyramidState? s = state;
    for (final String k in to.toSet()) {
      final String addr = s?.members[k]?.addr ?? '';
      if (addr.isEmpty) {
        continue;
      }
      // What the receiver needs, never this phone's own bookkeeping.
      final Map<String, dynamic> json = r.toJson()
        ..remove('f')
        ..remove('st')
        ..remove('sa');
      if (_n(addr) == _n(host.ownAddress())) {
        await _onReport(addr, json);
      } else {
        await _send(addr, <String, dynamic>{
          'type': PyramidTypes.report,
          ...json,
        });
      }
    }
  }

  /// Whether a frame from [from] comes from member [key] of [s]: the
  /// transport proves the address, the member's own signed record ties
  /// the address to the key (this phone: this person).
  bool _sentBy(PyramidState s, String from, String key) {
    if (!s.isMember(key)) {
      return false;
    }
    final String a = _n(from);
    if (key == myKey && a == _n(host.ownAddress())) {
      return true;
    }
    final String addr = s.members[key]?.addr ?? '';
    return addr.isNotEmpty && _n(addr) == a;
  }

  /// Members of [s] whose device is at [from] (normally one).
  List<String> _membersAt(PyramidState s, String from) => <String>[
    for (final String k in s.position.keys)
      if (_sentBy(s, from, k)) k,
  ];

  /// Whether this person takes reports from [sender]: as one of
  /// the top, or as a delegate for reports whose branch covers [sender].
  bool _takesReportsFrom(PyramidState s, String sender) {
    final String? me = myKey;
    if (me == null || !s.isMember(me)) {
      return false;
    }
    if (s.topCell.contains(me)) {
      return true;
    }
    final String path = s.pathOf(sender) ?? '';
    final int t = _now();
    return s.delegations.values.any(
      (PyrDelegation d) =>
          d.to == me &&
          d.power == 'reports' &&
          !d.revoked &&
          d.until > t &&
          PyrPath.within(path, d.scope),
    );
  }

  /// A report as it may be kept: known fields only, each of a sane size;
  /// null when it is not one.
  PyrReport? _cleanReport(Map<String, dynamic> p, Object? from) {
    final PyrReport? r = PyrReport.fromJson(p);
    if (r == null || r.id.isEmpty || r.id.length > 64) {
      return null;
    }
    final String? dk = r.datingKey;
    return PyrReport(
      id: r.id,
      reason: kReportReasons.containsKey(r.reason) ? r.reason : 'other',
      at: r.at,
      target: PyramidRecord.isCanonicalKey(r.target) ? r.target : '',
      evidence: _cut(r.evidence, kPyrReportEvidenceChars),
      datingKey: dk != null && dk.isNotEmpty && dk.length <= 200 ? dk : null,
      from: from is String && from.length <= 300 ? from : null,
      escalated: r.escalated,
      entryId: r.entryId != null && r.entryId!.length <= 128 ? r.entryId : null,
      entry:
          r.entry != null &&
              utf8.encode(jsonEncode(r.entry)).length <= kPyrReportEntryBytes
          ? r.entry
          : null,
    );
  }

  /// The signed original of a report, when it holds: a well-formed
  /// entry whose device signature and certificate check out, and — when
  /// the report names an entry — that very one. Null otherwise.
  static Future<LogEntry?> verifiedReportEntry(PyrReport r) async {
    final Map<String, dynamic>? json = r.entry;
    if (json == null) {
      return null;
    }
    final LogEntry? e = await verifiedEntry(json);
    if (e == null || (r.entryId != null && r.entryId != e.id)) {
      return null;
    }
    return e;
  }

  /// At most [kPyrReportsPerSender] reports per sender and
  /// [kPyrReportsTotal] in all; the oldest go.
  void _trimReports() {
    final Map<String, List<PyrReport>> bySender = <String, List<PyrReport>>{};
    for (final PyrReport r in inbox.values) {
      (bySender[r.from ?? ''] ??= <PyrReport>[]).add(r);
    }
    for (final List<PyrReport> list in bySender.values) {
      if (list.length <= kPyrReportsPerSender) {
        continue;
      }
      list.sort((PyrReport a, PyrReport b) => a.at.compareTo(b.at));
      for (final PyrReport r in list.take(list.length - kPyrReportsPerSender)) {
        inbox.remove(r.id);
      }
    }
    if (inbox.length > kPyrReportsTotal) {
      final List<PyrReport> all = inbox.values.toList()
        ..sort((PyrReport a, PyrReport b) => a.at.compareTo(b.at));
      for (final PyrReport r in all.take(all.length - kPyrReportsTotal)) {
        inbox.remove(r.id);
      }
    }
  }

  /// An appeal as it may be kept, or null.
  static Map<String, dynamic>? _cleanAppeal(Map<dynamic, dynamic> a) {
    final Object? rep = a['rep'];
    final Object? text = a['t'];
    final Object? k = a['k'];
    final Object? at = a['at'];
    if (rep is! String ||
        rep.isEmpty ||
        rep.length > 64 ||
        text is! String ||
        !PyramidRecord.isCanonicalKey(k) ||
        at is! int) {
      return null;
    }
    final Object? from = a['f'];
    return <String, dynamic>{
      'rep': rep,
      't': _cut(text, kPyrAppealChars),
      'k': k,
      'at': at,
      if (from is String && from.length <= 300) 'f': from,
    };
  }

  /// At most [kPyrAppealsPerSender] appeals per member and
  /// [kPyrAppealsTotal] in all; the oldest go.
  void _trimAppeals() {
    appeals.sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          (a['at'] as int).compareTo(b['at'] as int),
    );
    final Map<String, int> left = <String, int>{};
    for (final Map<String, dynamic> a in appeals.reversed) {
      final String k = a['k'] as String;
      left[k] = (left[k] ?? 0) + 1;
    }
    appeals.removeWhere((Map<String, dynamic> a) {
      final String k = a['k'] as String;
      if ((left[k] ?? 0) > kPyrAppealsPerSender) {
        left[k] = left[k]! - 1;
        return true;
      }
      return false;
    });
    if (appeals.length > kPyrAppealsTotal) {
      appeals.removeRange(0, appeals.length - kPyrAppealsTotal);
    }
  }

  /// A report from a member of this pyramid, to this person as one who
  /// takes reports from them; anything else (strangers, other pyramids,
  /// members outside a delegate's branch) is dropped.
  Future<void> _onReport(String from, Map<String, dynamic> p) async {
    final PyramidState? s = state;
    if (s == null ||
        !_membersAt(
          s,
          from,
        ).any((String sender) => _takesReportsFrom(s, sender))) {
      return;
    }
    final PyrReport? r = _cleanReport(p, from);
    if (r == null || inbox.containsKey(r.id)) {
      return;
    }
    // The signed original is kept only when it holds; it then names the
    // entry a ban will name.
    final LogEntry? original = await verifiedReportEntry(r);
    inbox[r.id] = PyrReport(
      id: r.id,
      reason: r.reason,
      at: _now(),
      target: r.target,
      evidence: r.evidence,
      datingKey: r.datingKey,
      from: _n(from),
      entryId: original?.id ?? r.entryId,
      entry: original == null ? null : r.entry,
    );
    _trimReports();
    if (!inbox.containsKey(r.id)) {
      return;
    }
    await _saveReports();
    notifyListeners();
    await host.notify(
      RuntimeSystemNotification(
        id: 'pyr-report-${r.id}',
        title: t('Nowe zgłoszenie'),
        body: kReportReasons[r.reason] ?? r.reason,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'pyr-report',
      ),
    );
  }

  /// An appeal from a member (its key must be the one of the device that
  /// sent it), to this person as one of the top. One per member and
  /// report: the first counts.
  Future<void> _onAppeal(String from, Map<String, dynamic> p) async {
    final PyramidState? s = state;
    final String? me = myKey;
    final Object? sender = p['k'];
    if (s == null ||
        me == null ||
        sender is! String ||
        !_sentBy(s, from, sender) ||
        !s.topCell.contains(me)) {
      return;
    }
    final Map<String, dynamic>? a = _cleanAppeal(<String, dynamic>{
      'rep': p['rep'],
      't': p['t'],
      'k': sender,
      'at': _now(),
      'f': _n(from),
    });
    if (a == null ||
        appeals.any(
          (Map<String, dynamic> x) => x['k'] == sender && x['rep'] == a['rep'],
        )) {
      return;
    }
    appeals.add(a);
    _trimAppeals();
    await _saveReports();
    notifyListeners();
  }

  /// A delegate's (or the top's) answer to a report: a public decision,
  /// and a ban when it is one.
  Future<void> decide(
    String reportId,
    String outcome, {
    String? via,
    String? banVia,
    String? banKind,
    int? until,
  }) async {
    final PyrReport? r = inbox[reportId];
    if (r == null) {
      return;
    }
    await topDecision(<String, dynamic>{
      't': PyrT.decision,
      'rep': reportId,
      'outcome': outcome,
    }, via: via);
    if (banKind != null) {
      await ban(
        target: r.target,
        kind: banKind,
        until: until,
        entryId: banKind == 'content' ? r.entryId : null,
        datingKey: r.datingKey,
        reason: kReportReasons[r.reason] ?? r.reason,
        via: banVia ?? via,
      );
    }
    inbox.remove(reportId);
    await _saveReports();
    await _save();
  }

  /// An appeal to the top against a decision: [reportId] is the id
  /// of the matter — the ban (or the report) it concerns — and [text] a
  /// short reason. Once per matter; false when nothing was sent (not a
  /// member, no reason, or it was appealed before). The top answers by
  /// lifting the ban, which every phone sees in the state.
  Future<bool> appeal(String reportId, String text) async {
    final PyramidState? s = state;
    final String? me = myKey;
    if (s == null ||
        me == null ||
        reportId.isEmpty ||
        reportId.length > 64 ||
        text.trim().isEmpty ||
        sentAppeals.containsKey(reportId)) {
      return false;
    }
    for (final String k in s.topCell) {
      final String addr = s.members[k]?.addr ?? '';
      if (addr.isEmpty) {
        continue;
      }
      final Map<String, dynamic> json = <String, dynamic>{
        'rep': reportId,
        't': _cut(text, kPyrAppealChars),
        'k': me,
      };
      if (_n(addr) == _n(host.ownAddress())) {
        await _onAppeal(addr, json);
      } else {
        await _send(addr, <String, dynamic>{
          'type': PyramidTypes.appeal,
          ...json,
        });
      }
    }
    sentAppeals[reportId] = _now();
    // Only the newest are remembered.
    while (sentAppeals.length > kPyrMyReportsKept) {
      final String oldest = sentAppeals.entries
          .reduce(
            (MapEntry<String, int> a, MapEntry<String, int> b) =>
                b.value < a.value ? b : a,
          )
          .key;
      sentAppeals.remove(oldest);
    }
    await _save();
    return true;
  }

  // ---- crisis over Bluetooth ----

  /// Sends a crisis announcement over Bluetooth to phones around.
  Future<int> broadcastCrisis(String alarmId) async {
    final Map<String, dynamic>? wave = crisisWave(alarmId);
    if (wave == null) {
      return 0;
    }
    _crisisSeen.add(alarmId);
    return await crisisBroadcast?.call(wave) ?? 0;
  }

  Map<String, dynamic>? crisisWave(String alarmId) {
    final PyramidRecord? r = _records[alarmId];
    return r == null
        ? null
        : <String, dynamic>{'v': kCrisisWaveVersion, 'r': r.toJson()};
  }

  /// A crisis announcement heard over Bluetooth: checked, shown and — only
  /// when it counts in this person's own pyramid — kept and passed on to
  /// the next phones. Nothing from the future, nothing over or older than
  /// three days (no replays); each one handled once, remembered across
  /// restarts. One that does not count is shown as unverified, never kept
  /// or passed on.
  Future<void> onCrisisWave(Map<dynamic, dynamic> json) async {
    if (json['v'] != kCrisisWaveVersion) {
      return;
    }
    final PyramidRecord? r = PyramidRecord.fromJson(json['r']);
    // Only the pinned pyramid's: another "pyramid" is not shown at all.
    if (r == null ||
        r.type != PyrT.alarm ||
        r.pyramid != current ||
        _crisisSeen.contains(r.id)) {
      return;
    }
    final int nowMs = _now();
    final int until = r.integer('until') > r.at
        ? r.integer('until')
        : r.at + 24 * 3600 * 1000;
    if (r.at > nowMs + kPyrMaxSkewMs ||
        nowMs - r.at > 3 * 24 * 3600 * 1000 ||
        nowMs >= until) {
      return;
    }
    if (!await r.verifySigners()) {
      return;
    }
    _crisisSeen.add(r.id);
    while (_crisisSeen.length > 300) {
      _crisisSeen.remove(_crisisSeen.first);
    }
    bool valid = false;
    final String? py = current;
    if (py != null && _followSince != null) {
      if (_records.containsKey(r.id)) {
        valid = state?.alarms.any((PyrAlarm a) => a.id == r.id) ?? false;
      } else {
        // Would it count? A trial fold, before anything is kept.
        final PyramidState trial = PyramidState.fold(
          py,
          <PyramidRecord>[..._records.values, r],
          now: max(nowMs, r.at),
          treasurerSigs: _tsigs,
          late: _late,
        );
        valid = trial.alarms.any((PyrAlarm a) => a.id == r.id);
        if (valid) {
          await ingest(r);
        }
      }
    }
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'pyr-crisis-${r.id}',
        title: valid
            ? t('⚠️ Komunikat kryzysowy')
            : t('Komunikat (niesprawdzony)'),
        body: r.str('text'),
        createdAtMillis: nowMs,
        category: RuntimeSystemNotificationCategory.alarm,
        slotKey: 'pyr-crisis',
      ),
    );
    if (valid) {
      await crisisBroadcast?.call(<String, dynamic>{
        'v': kCrisisWaveVersion,
        'r': r.toJson(),
      });
    }
  }

  // ---- receiving ----

  Future<bool> handle(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if (type is! String || !PyramidTypes.all.contains(type)) {
      return Future<bool>.value(false);
    }
    if (!_allow(_n(frame.from))) {
      // A flood: dropped (what matters comes again with the next sync).
      return Future<bool>.value(true);
    }
    final Completer<bool> done = Completer<bool>();
    _queue = _queue.then((_) async {
      try {
        await _handle(type, _n(frame.from), frame.payload);
      } on Object catch (error, stack) {
        logZenError('Piramida', error, stack);
      }
      done.complete(true);
    });
    return done.future;
  }

  /// At most [kPyrRateLimit] frames per sender in [kPyrRateWindowMs].
  bool _allow(String from) {
    final int t = _now();
    final ({int start, int count})? r = _rate[from];
    if (r == null || t - r.start > kPyrRateWindowMs) {
      if (_rate.length > 2000) {
        _rate.clear();
      }
      _rate[from] = (start: t, count: 1);
      return true;
    }
    if (r.count >= kPyrRateLimit) {
      return false;
    }
    _rate[from] = (start: r.start, count: r.count + 1);
    return true;
  }

  Future<void> _handle(String type, String from, Map<String, dynamic> p) async {
    // Records and sync only between friends (who keep the same pyramid):
    // nobody else gets the pyramid's records or fills this phone with
    // theirs.
    const Set<String> friendsOnly = <String>{
      PyramidTypes.record,
      PyramidTypes.anon,
      PyramidTypes.records,
      PyramidTypes.hello,
      PyramidTypes.ids,
      PyramidTypes.want,
      PyramidTypes.national,
    };
    if (friendsOnly.contains(type) && !host.isFriend(from)) {
      return;
    }
    switch (type) {
      case PyramidTypes.record:
        final PyramidRecord? r = PyramidRecord.fromJson(p['r']);
        if (r != null) {
          await ingest(r, from: from);
        }
      case PyramidTypes.anon:
        // Publishing an anonymous record for a friend: only a fresh one
        // (a vote dated back into a closed vote is not passed on).
        final PyramidRecord? r = PyramidRecord.fromJson(p['r']);
        if (r != null &&
            PyrT.anonymous.contains(r.type) &&
            (_now() - r.at).abs() <= kPyrMaxSkewMs) {
          await ingest(r);
        }
      case PyramidTypes.records:
        final Object? rs = p['rs'];
        if (rs is List) {
          // In time order, so a vote comes after the request it belongs to.
          final List<PyramidRecord> list = <PyramidRecord>[
            for (final Object? j in rs.take(200)) ?PyramidRecord.fromJson(j),
          ]..sort((PyramidRecord a, PyramidRecord b) => a.at.compareTo(b.at));
          await _ingestAll(list, from: from);
        }
      case PyramidTypes.hello:
        await _onHello(from, p);
      case PyramidTypes.ids:
        await _onIds(from, p);
      case PyramidTypes.want:
        final Object? ids = p['ids'];
        if (ids is List) {
          final List<Map<String, dynamic>> out = <Map<String, dynamic>>[
            for (final String id in ids.whereType<String>().take(400))
              if (_records[id] != null) _records[id]!.toJson(),
          ];
          for (final List<Map<String, dynamic>> frame in _recordFrames(out)) {
            await _send(from, <String, dynamic>{
              'type': PyramidTypes.records,
              'rs': frame,
            });
          }
        }
      case PyramidTypes.proposal:
        await _onProposal(from, p);
      case PyramidTypes.signature:
        await _onSignature(from, p);
      case PyramidTypes.vote:
        await _onVote(from, p);
      case PyramidTypes.pay:
        await _onPay(from, p);
      case PyramidTypes.paySig:
        await _onPaySig(p);
      case PyramidTypes.report:
        await _onReport(from, p);
      case PyramidTypes.dm:
        await _onMarket(from, p);
      case PyramidTypes.appeal:
        await _onAppeal(from, p);
      case PyramidTypes.sum:
        await _onSums(from, p);
      case PyramidTypes.national:
        await _onNational(from, p);
      case PyramidTypes.who:
        await _onWho(from, p);
      case PyramidTypes.here:
        await _onHere(from, p);
    }
  }

  Future<void> _onHello(String from, Map<String, dynamic> p) async {
    final Object? list = p['py'];
    if (list is! List) {
      return;
    }
    final Set<String> theirs = <String>{};
    final Set<String> mine = <String>{
      if (current != null && _followSince != null) current!,
    };
    for (final Object? e in list) {
      if (e is! Map || e['id'] is! String) {
        continue;
      }
      final String py = e['id'] as String;
      theirs.add(py);
      if (!mine.contains(py)) {
        continue;
      }
      final Map<String, String> myDigest = _digest(py);
      final Map<dynamic, dynamic> theirDigest = e['d'] is Map
          ? e['d'] as Map
          : const <String, String>{};
      final Map<String, List<String>> buckets = _buckets(py);
      for (final String b in <String>{
        ...myDigest.keys,
        ...theirDigest.keys.whereType<String>(),
      }) {
        if (myDigest[b] != theirDigest[b]) {
          final List<String> ids = buckets[b] ?? const <String>[];
          await _send(from, <String, dynamic>{
            'type': PyramidTypes.ids,
            'py': py,
            'ids': ids,
            // What this phone has of each (signers): a copy with fewer
            // signatures on either side gets repaired.
            'fp': <String, String>{
              for (final String id in ids) id: _fp(_records[id]!),
            },
          });
        }
      }
    }
    _peers[from] = theirs;
    // A friend outside the pyramid reads the top's posts and its national
    // section.
    await _catchUpNational(from, p['nf'], p['tf']);
  }

  Future<void> _onIds(String from, Map<String, dynamic> p) async {
    final Object? ids = p['ids'];
    if (ids is! List ||
        p['py'] != current ||
        current == null ||
        _followSince == null) {
      return;
    }
    final Set<String> theirs = ids
        .whereType<String>()
        .where((String id) => id.isNotEmpty)
        .toSet();
    // Their fingerprints (newer apps): the same record with other
    // signatures is exchanged both ways and merged.
    final Map<dynamic, dynamic> fps = p['fp'] is Map
        ? p['fp'] as Map
        : const <String, String>{};
    bool differs(String id) {
      final Object? theirFp = fps[id];
      final PyramidRecord? mine = _records[id];
      return theirFp is String && mine != null && theirFp != _fp(mine);
    }

    final List<String> missing = theirs
        .where((String id) => !_records.containsKey(id) || differs(id))
        .toList();
    if (missing.isNotEmpty) {
      await _send(from, <String, dynamic>{
        'type': PyramidTypes.want,
        'ids': missing,
      });
    }
    // And what they lack from the same buckets (or have with fewer
    // signatures).
    final Set<String> prefixes = theirs
        .map((String id) => id.substring(0, 1))
        .toSet();
    final List<Map<String, dynamic>> extra = <Map<String, dynamic>>[
      for (final MapEntry<String, List<String>> b in _buckets(
        p['py'] as String,
      ).entries)
        if (prefixes.contains(b.key) || theirs.isEmpty)
          for (final String id in b.value)
            if (!theirs.contains(id) || differs(id)) _records[id]!.toJson(),
    ];
    for (final List<Map<String, dynamic>> frame in _recordFrames(extra)) {
      await _send(from, <String, dynamic>{
        'type': PyramidTypes.records,
        'rs': frame,
      });
    }
  }

  /// [records] (JSON) in frames of at most 40 records and about
  /// [kPyrRecordFrameBytes]: every signer adds a 4.5 KB hybrid signature
  /// (7 KB on records that carry keys), and a signal holds at most 2 MiB.
  static List<List<Map<String, dynamic>>> _recordFrames(
    List<Map<String, dynamic>> records,
  ) {
    final List<List<Map<String, dynamic>>> frames =
        <List<Map<String, dynamic>>>[];
    List<Map<String, dynamic>> current = <Map<String, dynamic>>[];
    int bytes = 0;
    for (final Map<String, dynamic> r in records) {
      final int size = jsonEncode(r).length;
      if (current.isNotEmpty &&
          (current.length >= 40 || bytes + size > kPyrRecordFrameBytes)) {
        frames.add(current);
        current = <Map<String, dynamic>>[];
        bytes = 0;
      }
      current.add(r);
      bytes += size;
    }
    if (current.isNotEmpty) {
      frames.add(current);
    }
    return frames;
  }

  /// A signature back for something this person proposed: checked before
  /// it is added; published when enough (a fresh copy when the time has
  /// gone stale meanwhile).
  Future<void> _onSignature(String from, Map<String, dynamic> p) async {
    final PyramidRecord? r = PyramidRecord.fromJson(p['r']);
    final PyramidRecord? mine = r == null ? null : _mine[r.id];
    if (r == null || mine == null) {
      return;
    }
    final Map<String, String> ok = await PyramidRecord(
      body: mine.body,
      sigs: <String, String>{
        for (final MapEntry<String, String> e in r.sigs.entries)
          if (!mine.sigs.containsKey(e.key)) e.key: e.value,
      },
    ).validSigs();
    if (ok.isEmpty) {
      return;
    }
    final PyramidRecord all = PyramidRecord(
      body: mine.body,
      sigs: <String, String>{...mine.sigs, ...ok},
    );
    _mine[all.id] = all;
    final int need = _mineNeed[all.id] ?? all.candidates.length;
    if (!_ready(all, need)) {
      await _save();
      return;
    }
    // A handover may come in late (its time decides nothing a late
    // signature could change; a fresh copy would lack the new key's
    // signature).
    if (_now() - all.at > kPyrMaxSkewMs && all.type != PyrT.handover) {
      // Enough signatures, but too late for this time: a fresh copy, which
      // those who signed sign again without being asked.
      await _redate(all, need: need, alsoTo: from, manual: false);
      return;
    }
    await ingest(all);
  }

  /// Whether [from] is the device of a member who signed [r] (in [st],
  /// else the pyramid shown).
  bool _fromSigner(String from, PyramidRecord r, [PyramidState? st]) {
    final PyramidState? s = st ?? state;
    if (s == null) {
      return false;
    }
    final String a = _n(from);
    return r.signers.any((String k) => _n(s.members[k]?.addr ?? '') == a);
  }

  Future<void> _onProposal(String from, Map<String, dynamic> p) async {
    final PyramidRecord? r = PyramidRecord.fromJson(p['r']);
    final Object? need = p['need'];
    final String? me = myKey;
    if (r == null || need is! int || me == null || r.pyramid != current) {
      return;
    }
    final int nowMs = _now();
    // Never anything dated ahead (it would wait as a time bomb).
    if (r.at > nowMs + kPyrMaxSkewMs) {
      return;
    }
    // The power key passes on: signed by the app itself where the rule
    // lets this person sign.
    if (r.type == PyrT.handover) {
      await _onHandover(from, r, need.clamp(1, 20));
      return;
    }
    if (!r.candidates.contains(me) || r.sigs.containsKey(me)) {
      return;
    }
    if (!await r.verifySigners() ||
        proposals.containsKey(r.id) ||
        _records.containsKey(r.id)) {
      return;
    }
    // A fresh copy of something this person already signed: signed again
    // without asking, whoever brings it (only what this person agreed to,
    // dated now) — the head of a cell a sponsor chose may be a stranger.
    final int? agreed = _consent[_contentKey(r)];
    if (agreed != null && agreed > nowMs && nowMs - r.at <= kPyrMaxSkewMs) {
      await _cosign(r, need.clamp(1, 20), from);
      return;
    }
    // From a friend or a member who signed it — not from anybody at all.
    if (!host.isFriend(from) && !_fromSigner(from, r)) {
      return;
    }
    final Map<String, dynamic> extra = p['x'] is Map
        ? Map<String, dynamic>.from(p['x'] as Map)
        : <String, dynamic>{};
    // The sponsor vouches only for a friend (met in person); the head of
    // the chosen cell gets it from the sponsor.
    if (r.type == PyrT.admit && r.str('sp') == me && !host.isFriend(from)) {
      return;
    }
    // The sponsor confirms the data: the gender must open the commitment.
    if (r.type == PyrT.admit && r.str('sp') == me) {
      final Object? g = extra['g'];
      final Object? salt = extra['salt'];
      final Object? m = r.body['m'];
      final Object? by = m is Map ? m['yr'] : null;
      if (by is! int ||
          !pyrBirthYearValid(by, r.at) ||
          g is! String ||
          salt is! String ||
          m is! Map ||
          m['dc'] != dataCommit(by, g, salt)) {
        return;
      }
    }
    proposals[r.id] = PyrProposal(
      record: r,
      from: from,
      need: need.clamp(1, 20),
      at: _now(),
      extra: extra,
    );
    _trimProposals();
    if (!proposals.containsKey(r.id)) {
      return;
    }
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'pyr-prop-${r.id}',
        title: t('Piramida: do podpisania'),
        body: describeRecord(r),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'pyr-prop',
      ),
    );
  }

  /// A handover of the power key to sign: with the old key, which this
  /// phone holds, for the head now at the top — or as a member of the top
  /// cell once that head has held the top for [kPyrHandoverWaitMs]. The
  /// app signs by itself: the key gives no power, it only certifies who
  /// the head is, and every phone checks that against the records.
  Future<void> _onHandover(String from, PyramidRecord r, int need) async {
    final PyramidState? s = state;
    final LedgerKeyPair? id = _identity;
    final Uint8List? old = _powerSeed;
    if (s == null ||
        id == null ||
        _records.containsKey(r.id) ||
        r.str('from') != s.powerKey ||
        r.str('head') != s.head ||
        r.str('head') == id.id ||
        !await r.verifySigners()) {
      return;
    }
    PyramidRecord signed = r;
    final String? held = _powerId;
    if (old != null &&
        held == s.powerKey &&
        r.candidates.contains(held) &&
        !r.sigs.containsKey(held)) {
      signed = await signed.signedBy(await LedgerKeyPair.fromSeed(old));
    }
    if (s.topCell.contains(id.id) &&
        r.candidates.contains(id.id) &&
        !r.sigs.containsKey(id.id) &&
        r.at >= s.headSince + kPyrHandoverWaitMs) {
      signed = await signed.signedBy(id);
    }
    if (identical(signed, r)) {
      return;
    }
    if (_ready(signed, need)) {
      await ingest(signed);
    }
    await _send(from, <String, dynamic>{
      'type': PyramidTypes.signature,
      'r': signed.toJson(),
    });
  }

  /// Proposals kept for this person: at most [kPyrProposalsPerSender]
  /// from one device, [kPyrProposalsTotal] in all and
  /// [kPyrProposalsBytes] together; the oldest
  /// go, so nobody can make the saved state too big to write.
  void _trimProposals() {
    final List<PyrProposal> all = proposals.values.toList()
      ..sort((PyrProposal a, PyrProposal b) => b.at.compareTo(a.at));
    final Map<String, int> perSender = <String, int>{};
    int bytes = 0;
    int count = 0;
    for (final PyrProposal p in all) {
      final int size = p.record.signedBytes.length;
      final int fromThem = (perSender[p.from] ?? 0) + 1;
      if (fromThem > kPyrProposalsPerSender ||
          count >= kPyrProposalsTotal ||
          bytes + size > kPyrProposalsBytes) {
        proposals.remove(p.record.id);
        continue;
      }
      perSender[p.from] = fromThem;
      bytes += size;
      count++;
    }
  }

  /// A record in words.
  String describeRecord(PyramidRecord r) {
    final PyramidState? s = state;
    String name(String k) =>
        s?.members[k]?.name ??
        (r.body['m'] is Map && (r.body['m'] as Map)['k'] == k
            ? (r.body['m'] as Map)['n'] as String? ?? '?'
            : '?');
    return switch (r.type) {
      PyrT.admit =>
        r.str('sp') == r.str('head')
            ? t('Przyjęcie do komórki: {name}', {
                'name': (r.body['m'] as Map?)?['n'] ?? '?',
              })
            : t('Polecenie od {sponsor}: przyjąć {name} do Twojej komórki?', {
                'sponsor': name(r.str('sp')),
                'name': (r.body['m'] as Map?)?['n'] ?? '?',
              }),
      PyrT.found => t('Założenie piramidy: {name}', {
        'name': (r.body['m'] as Map?)?['n'] ?? '?',
      }),
      PyrT.handover => t('Klucz władzy dla {name}', {
        'name': name(r.str('head')),
      }),
      PyrT.swap => t('Zamiana: {name} zostaje szefem komórki', {
        'name': name(r.str('up')),
      }),
      PyrT.fill => t('Wolne miejsce zajmuje {name}', {
        'name': name(r.str('up')),
      }),
      PyrT.absent => t('Uznanie miejsca {name} za wolne (nieobecność)', {
        'name': name(r.str('k')),
      }),
      PyrT.remove => t('Usunięcie {name} z piramidy', {
        'name': name(r.str('k')),
      }),
      PyrT.migrate =>
        r.body['branch'] == true
            ? t('Przejście {name} z całą gałęzią pod {head}', {
                'name': name(r.str('k')),
                'head': name(r.str('to')),
              })
            : t('Przejście {name} pod {head}', {
                'name': name(r.str('k')),
                'head': name(r.str('to')),
              }),
      PyrT.transfer => t('Przelew {amount} dla {name}', {
        'amount': formatMoney(r.integer('amount')),
        'name': name(r.str('to')),
      }),
      PyrT.delegate => t('Delegacja „{power}” dla {name}', {
        'power': r.str('power'),
        'name': name(r.str('to')),
      }),
      PyrT.ban => t('Ban ({kind}) dla {name}', {
        'kind': r.str('kind'),
        'name': name(r.str('target')),
      }),
      PyrT.unban => t('Uchylenie bana'),
      PyrT.decision => t('Decyzja w sprawie zgłoszenia'),
      PyrT.referendum => t('Referendum: {question}', {'question': r.str('q')}),
      PyrT.constitution => t('Zmiana zasad piramidy'),
      PyrT.emit => t('Emisja {amount} dla {name}', {
        'amount': formatMoney(r.integer('amount')),
        'name': name(r.str('to')),
      }),
      PyrT.alarm => t('Ogłoszenie alarmowe: {text}', {'text': r.str('text')}),
      PyrT.natPin =>
        r.body['on'] == false
            ? t('Odpięcie posta w sekcji krajowej')
            : t('Przypięcie posta w sekcji krajowej'),
      PyrT.known => t('{name} potwierdza: zna {other}', {
        'name': name(r.signers.firstOrNull ?? ''),
        'other': name(r.str('k')),
      }),
      PyrT.badge =>
        r.body['off'] == true ? t('Ukrycie odznaki płci') : t('Odznaka płci'),
      _ => r.type,
    };
  }

  /// A time for people: "13.10.2026 18:05" (this phone's zone, in the
  /// app's language).
  static String _when(int ms) =>
      ZenFormat.dateTime(DateTime.fromMillisecondsSinceEpoch(ms));

  /// A length of time for people: "25 min", "3 h", "2 dni".
  static String _span(int ms) {
    final int minutes = ms ~/ 60000;
    if (minutes < 120) {
      return t('{minutes} min', {'minutes': minutes});
    }
    final int hours = minutes ~/ 60;
    return hours < 48
        ? t('{hours} h', {'hours': hours})
        : tn(hours ~/ 24, one: '{n} dzień', few: '{n} dni', many: '{n} dni');
  }

  static String _short(String id) =>
      id.length > 8 ? '${id.substring(0, 8)}…' : id;

  /// What a signer sees besides the headline: the record's own time (with
  /// a warning when it is far from now) and every field that decides what
  /// it does — who pays whom, a delegation's reach, limit and end, a
  /// referendum's reach and end, new rules, where a newcomer goes.
  List<String> recordDetails(PyramidRecord r) {
    final PyramidState? s = state;
    final int nowMs = _now();
    String name(Object? k) {
      if (k is! String || k.isEmpty) {
        return '—';
      }
      final Object? m = r.body['m'];
      return s?.members[k]?.name ??
          (m is Map && m['k'] == k && m['n'] is String
              ? m['n'] as String
              : _short(k));
    }

    String account(String a) => name(a);

    String scope(Object? json) {
      final Map<dynamic, dynamic> m = json is Map
          ? json
          : const <String, dynamic>{};
      return switch (m['k']) {
        'branch' =>
          m['p'] is String && (m['p'] as String).isNotEmpty
              ? t('gałąź {path}', {'path': m['p']})
              : t('gałąź (szczyt)'),
        'nat' => t('narodowość {nat}', {'nat': m['nat'] ?? '?'}),
        _ => t('cała piramida'),
      };
    }

    final List<String> out = <String>[
      t('Czas rekordu: {time}', {'time': _when(r.at)}),
    ];
    final int skew = r.at - nowMs;
    if (skew > kPyrMaxSkewMs) {
      out.add(
        t(
          'Uwaga: czas z przyszłości (za {span}) — taki rekord nie zostanie podpisany.',
          {'span': _span(skew)},
        ),
      );
    } else if (-skew > kPyrMaxSkewMs) {
      out.add(
        t(
          'Uwaga: rekord sprzed {span} — podpis wyśle świeżą kopię z obecnym czasem.',
          {'span': _span(-skew)},
        ),
      );
    }
    final String via = r.str('via');
    if (via.isNotEmpty) {
      out.add(t('Przez delegację: {id}', {'id': _short(via)}));
    }
    switch (r.type) {
      case PyrT.transfer:
        out
          ..add(
            t('Z: {from} → do: {to}', {
              'from': account(r.str('from')),
              'to': account(r.str('to')),
            }),
          )
          ..add(
            t('Kwota: {amount} · numer zlecenia {seq}', {
              'amount': formatMoney(r.integer('amount')),
              'seq': r.integer('seq'),
            }),
          );
        if (r.str('memo').isNotEmpty) {
          out.add(t('Tytuł: {memo}', {'memo': r.str('memo')}));
        }
        final Object? cond = r.body['cond'];
        if (cond is Map) {
          out.add(
            cond['until'] is int
                ? t('Warunek: decyduje {name}, zwrot po {time}', {
                    'name': name(cond['by']),
                    'time': _when(cond['until'] as int),
                  })
                : t('Warunek: decyduje {name}, zwrot po 7 dniach', {
                    'name': name(cond['by']),
                  }),
          );
        }
      case PyrT.settle:
        out.add(
          r.body['ok'] == true
              ? t('Rozliczenie: przyjęcie płatności {id}', {
                  'id': _short(r.str('x')),
                })
              : t('Rozliczenie: zwrot płatności {id}', {
                  'id': _short(r.str('x')),
                }),
        );
      case PyrT.delegate:
        out
          ..add(
            t('Uprawnienie: {power} · zakres: {scope}', {
              'power': r.str('power'),
              'scope': r.str('scope').isEmpty
                  ? t('cała piramida')
                  : t('gałąź {path}', {'path': r.str('scope')}),
            }),
          )
          ..add(
            t('Limit: {limit} · ważna do {time}', {
              'limit': r.integer('limit') > 0
                  ? t('{count} na 30 dni', {'count': r.integer('limit')})
                  : t('bez limitu'),
              'time': _when(r.integer('until')),
            }),
          )
          ..add(
            r.body['sub'] == true
                ? t('Może delegować dalej')
                : t('Bez dalszego delegowania'),
          );
        if (r.str('parent').isNotEmpty) {
          out.add(
            t('Przekazana z delegacji {id}', {'id': _short(r.str('parent'))}),
          );
        }
      case PyrT.revoke:
        // From now on only; the acts it lists stay.
        final Object? known = r.body['acts'];
        out.add(
          t(
            'Delegacja {id} · od teraz nieważna, dotychczasowe akty zostają: {count}',
            {
              'id': _short(r.str('d')),
              'count': known is List ? known.length : 0,
            },
          ),
        );
      case PyrT.ban:
        out.add(
          t('Rodzaj: {kind} · dla: {name} · {until}', {
            'kind': r.str('kind'),
            'name': name(r.str('target')),
            'until': r.body['until'] is int
                ? t('do {time}', {'time': _when(r.body['until'] as int)})
                : t('bez końca'),
          }),
        );
        if (r.str('reason').isNotEmpty) {
          out.add(t('Powód: {reason}', {'reason': r.str('reason')}));
        }
      case PyrT.referendum:
        out
          ..add(
            t('Zasięg: {scope} · wynik doradczy, decyduje szczyt', {
              'scope': scope(r.body['scope']),
            }),
          )
          ..add(t('Głosowanie do {time}', {'time': _when(r.integer('end'))}));
        if (r.body['opts'] is List) {
          out.add(
            t('Opcje: {options}', {
              'options': (r.body['opts'] as List).whereType<String>().join(
                ', ',
              ),
            }),
          );
        }
      case PyrT.constitution:
        final Object? params = r.body['params'];
        out
          ..add(
            t('Nowe zasady: {params}', {
              'params': params is Map ? jsonEncode(params) : '—',
            }),
          )
          ..add(
            t('Obowiązują od {time}', {
              'time': _when(r.at + kPyrParamsDelayMs),
            }),
          );
      case PyrT.emit:
        out.add(
          t('Dla: {name} · {amount} · uzasadnienie: {why}', {
            'name': name(r.str('to')),
            'amount': formatMoney(r.integer('amount')),
            'why': r.str('why'),
          }),
        );
      case PyrT.alarm:
        out.add(
          t('Zasięg: {scope} · ważne do {time}', {
            'scope': scope(r.body['scope']),
            'time': _when(r.integer('until')),
          }),
        );
      case PyrT.admit:
        final String place = r.str('slot');
        out.add(
          r.str('sp') == r.str('head')
              ? t('Miejsce: pod {head} · poziom {level}', {
                  'head': name(r.str('head')),
                  'level': place.length + 1,
                })
              : t(
                  'Polecenie od {sponsor} · miejsce: pod {head} · poziom {level}',
                  {
                    'sponsor': name(r.str('sp')),
                    'head': name(r.str('head')),
                    'level': place.length + 1,
                  },
                ),
        );
      case PyrT.handover:
        out.add(
          t('Klucz władzy dla szefa piramidy: {name}', {
            'name': name(r.str('head')),
          }),
        );
    }
    return out;
  }

  // ---- after changes ----

  Future<void> _afterChange(PyramidState? before) async {
    final PyramidState? s = state;
    final String? me = myKey;
    if (s == null || me == null) {
      return;
    }
    final int nowMs = _now();
    Future<void> tell(
      String id,
      String title,
      String body, {
      RuntimeSystemNotificationCategory cat =
          RuntimeSystemNotificationCategory.social,
    }) async {
      if (!_announced.add(id)) {
        return;
      }
      await host.notify(
        RuntimeSystemNotification(
          id: 'pyr-$id',
          title: title,
          body: body,
          createdAtMillis: nowMs,
          category: cat,
          slotKey: 'pyr-$id',
        ),
      );
    }

    // Records arrive in batches: a newcomer gets the whole pyramid in one,
    // with no pyramid shown before it.
    if (!(before?.isMember(me) ?? false) && s.isMember(me) && s.head != me) {
      await tell(
        'joined-${s.id}',
        t('Jesteś w piramidzie'),
        t('Poziom {level} w „{pyramid}”.', {
          'level': s.levelOf(me),
          'pyramid': s.name,
        }),
      );
    }
    await _tellPosts(nowMs);
    for (final PyrAlarm a in s.alarms) {
      final String myPath = s.pathOf(me) ?? '';
      final bool mine = switch (a.scopeKind) {
        'branch' => PyrPath.within(myPath, a.scopePath),
        'nat' => s.members[me]?.nat == a.scopeNat,
        _ => true,
      };
      if (mine && nowMs < a.until) {
        await tell(
          'alarm-${a.id}',
          t('⚠️ Ogłoszenie alarmowe'),
          a.text,
          cat: RuntimeSystemNotificationCategory.alarm,
        );
      }
    }
    for (final PyrReferendum r in s.referenda.values) {
      if (s.eligible(r, me) && nowMs < r.end) {
        await tell('ref-${r.id}', t('Referendum'), r.question);
      }
    }
    for (final PyrElection e in s.elections.values) {
      if (!e.closed && e.ring.contains(me)) {
        await tell(
          'elect-${e.id}',
          t('Głosowanie w komórce'),
          t(
            'Ktoś z komórki chce wybrać szefa na nowo. Zagłosuj w ciągu '
            '{hours} h.',
            {'hours': s.params.electionHours},
          ),
        );
      }
    }
    for (final PyrTransferInfo x in s.transfers) {
      if (x.to == me && nowMs - x.at < 7 * 24 * 3600 * 1000) {
        await tell(
          'pay-${x.id}',
          t('Wpłata'),
          x.memo.isEmpty
              ? t('{amount} od {name}', {
                  'amount': formatMoney(x.amount),
                  'name': s.members[x.from]?.name ?? x.from,
                })
              : t('{amount} od {name} — {memo}', {
                  'amount': formatMoney(x.amount),
                  'name': s.members[x.from]?.name ?? x.from,
                  'memo': x.memo,
                }),
        );
      }
    }
    for (final PyrEmission e in s.emissions.values) {
      if (seenLate(e.id) && canVeto(e)) {
        // It reached this phone after its own time: maybe back-dated past
        // the veto window. Its wait counts from then here, so the veto is
        // still possible.
        await tell(
          'emit-late-${e.id}',
          t('Emisja dotarła z opóźnieniem'),
          t(
            '{amount} dla {name} — możliwe antydatowanie. Możesz ją '
            'zawetować.',
            {
              'amount': formatMoney(e.amount),
              'name': s.members[e.to]?.name ?? '?',
            },
          ),
          cat: RuntimeSystemNotificationCategory.alarm,
        );
      } else if (!e.done && !e.vetoed && e.vetoers.contains(me)) {
        await tell(
          'emit-${e.id}',
          t('Emisja czeka 24 h'),
          t('{amount} — możesz zawetować.', {'amount': formatMoney(e.amount)}),
        );
      }
    }
    for (final MapEntry<String, String> d in s.decisions.entries) {
      if (myReports.containsKey(d.key)) {
        await tell('dec-${d.key}', t('Decyzja w Twoim zgłoszeniu'), d.value);
      }
    }
    await _retryHeld();
  }

  /// One notification for the new posts of the top and the line up,
  /// updated in place when another comes (never one per post); a tap opens
  /// the Tablica on "Piramida". Members only.
  Future<void> _tellPosts(int nowMs) async {
    if (!isMember) {
      return;
    }
    final List<PyrFeedPost> fresh = feed.unread(wasRead, nowMs);
    if (fresh.every((PyrFeedPost p) => _announced.contains('post-${p.id}'))) {
      return;
    }
    _announced.addAll(<String>[
      for (final PyrFeedPost p in fresh) 'post-${p.id}',
    ]);
    final PyrFeedPost newest = fresh.first;
    await host.notify(
      RuntimeSystemNotification(
        id: kPyrPostsNotification,
        title: tn(
          fresh.length,
          one: 'Piramida: {n} nowy post',
          few: 'Piramida: {n} nowe posty',
          many: 'Piramida: {n} nowych postów',
        ),
        body: t('{name}: {text}', <String, Object?>{
          'name': newest.name,
          'text': newest.text,
        }),
        createdAtMillis: nowMs,
        category: RuntimeSystemNotificationCategory.social,
        slotKey: kPyrPostsNotification,
        routeKey: buildFeedRouteKey('pyramid'),
        stackCount: fresh.length,
      ),
    );
  }

  /// Periodic work (every few minutes): counting, escalating reports,
  /// saying hello, a sign of life.
  Future<void> duties() async {
    await _loadIdentity();
    await _countDuties();
    final PyramidState? s = state;
    final String? me = myKey;
    if (s == null || me == null) {
      return;
    }
    await _powerDuties(s, me);
    final int t = _now();
    _consent.removeWhere((String _, int until) => until <= t);
    // Orders and settlements still waiting for treasurers go out again as
    // they are (every half hour), until they count or are a week old.
    for (final PyramidRecord r in _payments.values.toList()) {
      if (_records.containsKey(r.id) || t - r.at > kPyrMaxOrderAgeMs) {
        _payments.remove(r.id);
        _resentAt.remove(r.id);
        await _save();
      } else if (t - (_resentAt[r.id] ?? 0) > 30 * 60 * 1000) {
        await _toTreasurers(r);
      }
    }
    await _retryHeld();
    await _sumDuties(s, me);
    // A report without a decision climbs one step every
    // [PyrParams.reportEscalateHours]: the next wider branch's delegates,
    // at last the top.
    for (final PyrReport r in myReports.values.toList()) {
      if (!r.escalated &&
          !s.decisions.containsKey(r.id) &&
          t - (r.sentAt ?? r.at) > s.params.reportEscalateHours * 3600 * 1000) {
        r
          ..stage += 1
          ..sentAt = t
          ..escalated = _reportAtTop(r.stage);
        await _save();
        await _sendReport(r, _reportReceivers(r.stage));
      }
    }
    // A sign of life every 7 days, so nobody takes the place for empty.
    if (s.isMember(me) && t - (s.lastSeen[me] ?? 0) > 7 * 24 * 3600 * 1000) {
      await propose(
        <String, dynamic>{'t': PyrT.alive, 'k': me},
        candidates: <String>[me],
        need: 1,
      );
    }
    // A new device address.
    final PyrMember? m = s.members[me];
    if (m != null &&
        _n(m.addr) != _n(host.ownAddress()) &&
        host.ownAddress().isNotEmpty &&
        !(otherDevices?.call() ?? const <String>[])
            .map(_n)
            .contains(_n(m.addr))) {
      await propose(
        <String, dynamic>{
          't': PyrT.address,
          'k': me,
          'addr': _n(host.ownAddress()),
        },
        candidates: <String>[me],
        need: 1,
      );
    }
  }

  /// The power key's part of the duties. The head now at the top makes a
  /// new power key and asks for the handover — the old key (its holder's
  /// app signs at once), after 72 h most of the top cell — every half hour
  /// until it is in. A key handed on is forgotten; the new one is kept.
  Future<void> _powerDuties(PyramidState s, String me) async {
    if (_powerNextId != null && s.powerKey == _powerNextId) {
      await _setPower(_powerNext);
      await _save();
    } else if (_powerId != null &&
        s.powerKey != _powerId &&
        s.usedPowerKeys.contains(_powerId)) {
      await _setPower(null);
      await _save();
    }
    final String? old = s.powerKey;
    final int t = _now();
    if (s.head != me ||
        !s.handoverDue ||
        old == null ||
        t - _handoverSentAt < 30 * 60 * 1000) {
      return;
    }
    _handoverSentAt = t;
    if (_powerNext == null) {
      await _setPowerNext(randomBytes(32));
      await _save();
    }
    final LedgerKeyPair next = await LedgerKeyPair.fromSeed(_powerNext!);
    final LedgerKeyPair id = await _ensureIdentity();
    final List<String> top = s.topCell;
    final PyramidRecord r = await (await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.handover,
        'py': s.id,
        'at': t,
        'by': <String>{old, next.id, me, ...top}.toList()..sort(),
        'from': old,
        'to': next.id,
        'tpq': next.pqId,
        'head': me,
      },
    ).signedBy(next)).signedBy(id);
    if (_ready(r, 3)) {
      await ingest(r);
      return;
    }
    // One handover asked for at a time: the newest.
    final List<String> stale = <String>[
      for (final MapEntry<String, PyramidRecord> e in _mine.entries)
        if (e.value.type == PyrT.handover) e.key,
    ];
    for (final String x in stale) {
      _mine.remove(x);
      _mineNeed.remove(x);
    }
    _mine[r.id] = r;
    _mineNeed[r.id] = 3;
    await _save();
    final Set<String> sent = <String>{_n(host.ownAddress())};
    for (final String k in <String>{?s.powerHead, ...top}) {
      final String addr = s.members[k]?.addr ?? '';
      if (k != me && addr.isNotEmpty && sent.add(_n(addr))) {
        await _send(addr, <String, dynamic>{
          'type': PyramidTypes.proposal,
          'r': r.toJson(),
          'need': 3,
        });
      }
    }
  }

  // ---- the account's own devices ----

  /// At most this many records signed by this person go to the account's
  /// other devices with [sharedState] (the rest comes from friends).
  static const int sharedRecordsLimit = 200;

  /// What the account's other devices take over (they hold the same
  /// pyramid key): membership (the data confirmed at entry, the
  /// pyramids followed), the newest records this person signed and the
  /// votes in progress — what this person voted, the votes it holds as a
  /// head, sent tallies, signed treasury orders and agreements. `null`
  /// before the key and the stored state are known.
  Map<String, dynamic>? sharedState() {
    final String? me = myKey;
    if (me == null || _diskUnreadable) {
      return null;
    }
    final List<PyramidRecord> own = <PyramidRecord>[
      for (final PyramidRecord r in _records.values)
        if (r.sigs.containsKey(me)) r,
    ]..sort((PyramidRecord a, PyramidRecord b) => b.at.compareTo(a.at));
    // A copy: the maps here keep changing while it is sent.
    return Map<String, dynamic>.from(
      jsonDecode(
            jsonEncode(<String, dynamic>{
              'k': me,
              'data': myData,
              'fol': ?_followSince,
              // The power key goes with the person (the head's devices).
              if (_powerSeed != null) 'pw': b64(_powerSeed!),
              if (_powerNext != null) 'pwn': b64(_powerNext!),
              'mv': myVotes,
              'hv': _headVotes,
              'xv': <String, List<String>>{
                for (final MapEntry<String, Set<String>> e
                    in _extraVotes.entries)
                  e.key: e.value.toList()..sort(),
              },
              'ts': _tallySent,
              'so': _signedOrders,
              'cs': _consent,
              'apl': sentAppeals,
              'rs': <Map<String, dynamic>>[
                for (final PyramidRecord r
                    in own.take(sharedRecordsLimit).toList().reversed)
                  r.toJson(),
              ],
            }),
          )
          as Map,
    );
  }

  /// Takes in [sharedState] of another device of this account: everything
  /// is added, nothing this device knows is replaced, so a vote cast on
  /// one device is never cast again on another (one vote per member key,
  /// whichever device it comes from). Runs in turn with incoming frames.
  /// Returns whether anything was new.
  Future<bool> mergeFromOwnDevice(Map<String, dynamic> shared) {
    final Completer<bool> done = Completer<bool>();
    _queue = _queue.then((_) async {
      bool changed = false;
      try {
        changed = await _mergeShared(shared);
      } on Object catch (error, stack) {
        logZenError('Piramida: stan z innego urządzenia', error, stack);
      }
      done.complete(changed);
    });
    return done.future;
  }

  Future<bool> _mergeShared(Map<String, dynamic> shared) async {
    await _loadIdentity();
    final String? me = myKey;
    // Another key is another person (not linked yet, or recovered apart).
    if (me == null || _diskUnreadable || shared['k'] != me) {
      return false;
    }
    bool changed = false;
    final Object? data = shared['data'];
    if (myData.isEmpty && data is Map && data.isNotEmpty) {
      myData = Map<String, dynamic>.from(data);
      changed = true;
    }
    if (_followSince == null && shared['fol'] is int) {
      _followSince = shared['fol'] as int;
      changed = true;
    }
    final Uint8List? power = unb64(shared['pw'], length: 32);
    if (_powerSeed == null && power != null) {
      await _setPower(power);
      changed = true;
    }
    final Uint8List? next = unb64(shared['pwn'], length: 32);
    if (_powerNext == null && next != null && !listEquals(_powerSeed, next)) {
      await _setPowerNext(next);
      changed = true;
    }
    changed = _addInts(myVotes, shared['mv']) | changed;
    changed = _addStrs(_tallySent, shared['ts']) | changed;
    changed = _addStrs(_signedOrders, shared['so']) | changed;
    changed = _addInts(sentAppeals, shared['apl']) | changed;
    final Object? consent = shared['cs'];
    if (consent is Map) {
      final int t = _now();
      for (final MapEntry<dynamic, dynamic> e in consent.entries) {
        final Object? until = e.value;
        if (e.key is String &&
            until is int &&
            until > t &&
            (_consent[e.key as String] ?? 0) < until) {
          _consent[e.key as String] = until;
          changed = true;
        }
      }
    }
    final Object? hv = shared['hv'];
    if (hv is Map) {
      for (final MapEntry<dynamic, dynamic> e in hv.entries) {
        if (e.key is! String || e.value is! Map) {
          continue;
        }
        for (final MapEntry<dynamic, dynamic> v in (e.value as Map).entries) {
          if (v.key is String && v.value is int) {
            final Map<String, int> votes = _headVotes[e.key as String] ??=
                <String, int>{};
            if (!votes.containsKey(v.key)) {
              votes[v.key as String] = v.value as int;
              changed = true;
            }
          }
        }
      }
    }
    final Object? xv = shared['xv'];
    if (xv is Map) {
      for (final MapEntry<dynamic, dynamic> e in xv.entries) {
        if (e.key is! String || e.value is! List) {
          continue;
        }
        for (final String v in (e.value as List).whereType<String>()) {
          final int cut = v.lastIndexOf(':');
          if (cut <= 0) {
            continue;
          }
          final String voter = v.substring(0, cut + 1);
          final Set<String> votes = _extraVotes[e.key as String] ??= <String>{};
          // One vote per voter: the one this device holds stays.
          if (!votes.any((String x) => x.startsWith(voter))) {
            votes.add(v);
            changed = true;
          }
        }
      }
    }
    if (changed) {
      _dirty();
      await _save();
    }
    // The records this person signed, after the pyramids they belong to
    // are followed (records of other pyramids are not taken).
    final Object? rs = shared['rs'];
    if (rs is List) {
      final List<PyramidRecord> list = <PyramidRecord>[
        for (final Object? j in rs.take(sharedRecordsLimit))
          ?PyramidRecord.fromJson(j),
      ]..sort((PyramidRecord a, PyramidRecord b) => a.at.compareTo(b.at));
      // Already known to the pyramid's people: not passed on again.
      if ((await _ingestAll(list, spread: false)).isNotEmpty) {
        changed = true;
      }
    }
    return changed;
  }

  static bool _addInts(Map<String, int> into, Object? from) {
    bool changed = false;
    if (from is Map) {
      for (final MapEntry<dynamic, dynamic> e in from.entries) {
        if (e.key is String && e.value is int && !into.containsKey(e.key)) {
          into[e.key as String] = e.value as int;
          changed = true;
        }
      }
    }
    return changed;
  }

  static bool _addStrs(Map<String, String> into, Object? from) {
    bool changed = false;
    if (from is Map) {
      for (final MapEntry<dynamic, dynamic> e in from.entries) {
        if (e.key is String && e.value is String && !into.containsKey(e.key)) {
          into[e.key as String] = e.value as String;
          changed = true;
        }
      }
    }
    return changed;
  }
}

/// 12345 → "123,45" (thousands grouped with a non-breaking space).
String formatMoney(int hundredths) => pyrMoney(hundredths);

/// Hash of content to ban.
String contentHash(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();
