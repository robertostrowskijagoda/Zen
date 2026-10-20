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
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_record_log.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
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

  /// A message to a member through the access market (§24): paid inbox,
  /// a request for an introduction, a reshare or an announcement.
  static const String dm = 'pyr_dm';

  /// "Send me the whole pyramid you keep" (a friend's other pyramid, e.g.
  /// before joining it as a branch).
  static const String wantAll = 'pyr_wantall';

  /// The key of an exchange payment, from the payer to the one paid out in
  /// the other pyramid (§23.5).
  static const String fxKey = 'pyr_fx';

  /// Anonymous sums of a branch for the cell head above (§20.2a statistics,
  /// §22.1a "Dotarło / przeczytało"). 1.10.0 phones do not know it: their
  /// branches are simply not counted.
  static const String sum = 'pyr_sum';

  static const Set<String> all = <String>{
    sum,
    wantAll,
    fxKey,
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

/// Bluetooth wave version of a crisis announcement (§28.1).
const int kCrisisWaveVersion = 3;

/// An emission this phone first sees this long after its own time came
/// late (back-dated, or held back): its money waits here for the whole
/// veto time before a treasurer signs spending it (§23.4).
const int kPyrLateEmitMs = 30 * 60 * 1000;

/// How old an order (or a settlement) a treasurer still signs: it may
/// wait for treasurers who are offline, but not for ever (§23.2).
const int kPyrMaxOrderAgeMs = 7 * 24 * 3600 * 1000;

/// A paid market message needs its payment to wait at least this long
/// for the answer (else the payer could take it back while it is read).
const int kPyrMarketMinWaitMs = 24 * 3600 * 1000;

/// Frames one sender may send in [kPyrRateWindowMs] (generous: a big
/// pyramid's first sync fits; a flood does not).
const int kPyrRateLimit = 3000;
const int kPyrRateWindowMs = 10 * 60 * 1000;

/// Reports and appeals kept on this phone (§21.4): only from members, each
/// one this long at most, this many per sender and in all (the oldest go
/// first). They live under their own key, so the main state stays small.
const int kPyrReportEvidenceChars = 8000;

/// The largest signed original entry a report carries (S36), encoded; a
/// bigger one goes without it (the text evidence stays).
const int kPyrReportEntryBytes = 16 * 1024;
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

/// Market messages kept: open ones per sender, all of them.
const int kPyrMarketOpenPerSender = 30;
const int kPyrMarketTotal = 400;

/// An exchange payment (§23.5): the payer's money waits this long for the
/// exchanger; the payout in the other pyramid ends [kPyrFxMarginMs]
/// earlier, so the exchanger always has a day to take what it is owed;
/// the exchanger pays out only with at least [kPyrFxMinPayoutMs] left.
const int kPyrFxWaitMs = 3 * 24 * 3600 * 1000;
const int kPyrFxMarginMs = 24 * 3600 * 1000;
const int kPyrFxMinPayoutMs = 12 * 3600 * 1000;

/// Exchange keys and exchanges remembered at most.
const int kPyrFxKept = 200;

/// An exchange payment that waited in vain goes back this long after its
/// time (treasurers still sign an acceptance made just before it).
const int kPyrFxRefundGraceMs = 60 * 60 * 1000;

/// Political posts whose reach is counted (the newest, at most this old).
const int kPyrReachPosts = 50;
const int kPyrReachMaxAgeMs = 30 * 24 * 3600 * 1000;

/// A branch's anonymous statistics are shown only from this many people
/// (fewer would point at somebody).
const int kPyrStatsMinPeople = 5;

/// The topic of the anonymous statistics among the sums (§20.2a), and its
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

/// A report (§21.4): what, why, the evidence; never who reported.
final class PyrReport {
  PyrReport({
    required this.id,
    required this.reason,
    required this.at,
    this.target = '',
    this.evidence = '',
    this.datingKey,
    this.contentHash,
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

  /// Hash of the reported text: what 1.10.0 phones ban by.
  final String? contentHash;

  /// Id of the reported entry (a post, comment, message): what a content
  /// ban names (S36).
  final String? entryId;

  /// The signed original entry, when the reporter had it (S36): evidence
  /// nobody can make up. In an inbox only once its signatures checked out.
  final Map<String, dynamic>? entry;

  /// Device that sent it (only in the delegate's inbox).
  final String? from;

  /// Reached the top (the last step of escalation).
  bool escalated;

  /// Escalation step (§21.4): 0 = the delegates of the narrowest branch
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
    if (contentHash != null) 'h': contentHash,
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
      contentHash: s('h'),
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

/// What a market message asks for (§24).
Map<String, String> get kMarketKinds => <String, String>{
  'inbox': t('Wiadomość (płatna skrzynka)'),
  'intro': t('Prośba o przedstawienie'),
  'reshare': t('Udostępnij moje ogłoszenie swojej gałęzi'),
  'ad': t('Ogłoszenie w sieci'),
};

/// A message from the access market (§24), with the payment attached.
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
    this.introduce,
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

  /// An announcement: how many more times it may be passed on (§24).
  final int hops;

  /// An announcement passed on: who wrote and paid for it.
  final String? origin;

  /// The level of acquaintance the price was for ([kPriceLevels]).
  final String? level;

  /// A paid introduction (§24): the member the payer asks to be introduced
  /// to. The payment waits for their answer, not the intermediary's: the
  /// intermediary passes the request on, and is paid only when that person
  /// accepts it.
  final String? introduce;

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
    if (introduce != null) 'y': introduce,
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
      introduce: json['y'] is String ? json['y'] as String : null,
    );
  }
}

/// Report reasons (§21.4).
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

/// The pyramid on this phone (§20–24, §28): keeps and spreads the signed
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
    int Function()? now,
    Random? random,
    this.tallyWait = const Duration(hours: 6),
    int recordSegmentEntries = kPyrLogSegmentEntries,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure(),
       _log = PyramidRecordLog(
         disk,
         prefix: _keyRecords,
         segmentEntries: recordSegmentEntries,
       );

  final EventHost host;
  final LedgerDisk disk;

  /// Friends' friend lists (address → name), when they share them: tells
  /// a friend of a friend from a stranger for market prices (§24).
  final Map<String, String> Function(String friend)? friendsOf;

  /// This person's private level for the friend at an address (§8): a
  /// newcomer is admitted only at "Znajomy" or above (§20.2). Null: not
  /// known here (tests, no ledger), so only friendship is checked.
  final FriendLevel? Function(String address)? friendLevelOf;

  /// Sends a crisis wave over Bluetooth to phones around (§28.1).
  final Future<int> Function(Map<String, dynamic> wave)? crisisBroadcast;

  /// How long a cell head waits for the sums below before counting anyway.
  final Duration tallyWait;
  final int Function() _now;
  final Random _random;
  static const String _keyMe = 'pyramid/me';
  static const String _keyRecords = 'pyramid/records';

  /// Reports and appeals others sent here (§21.4), apart from the rest: a
  /// flood of them can never make [_keyMe] too big to save.
  static const String _keyReports = 'pyramid/reports';

  /// Ring signatures already checked (their cache keys), so a restart does
  /// not redo minutes of curve arithmetic on a slow phone.
  static const String _keyRingOk = 'pyramid/ring-ok';

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
  String? _seed;

  /// Private data confirmed at entry (§20.2a): birth year, gender, salt.
  Map<String, dynamic> myData = <String, dynamic>{};
  String? current;
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
  /// once (§21.4), and the screen shows that it is on its way.
  final Map<String, int> sentAppeals = <String, int>{};
  final Map<String, PyrMarketMessage> market = <String, PyrMarketMessage>{};

  /// Exchange keys (§23.5) this person received as the one paid out: lock
  /// → key, used to take the payout once it is there.
  final Map<String, String> _fxKeys = <String, String>{};

  /// Exchanges this person paid for: lock → {s: key, py: pyramid of the
  /// payout, to: who is paid out, x: own payment, at, sent}.
  final Map<String, Map<String, dynamic>> _fxOut =
      <String, Map<String, dynamic>>{};

  /// Exchanges this person handled as the exchanger: payment → own payout
  /// order ('' when it was returned instead).
  final Map<String, String> _fxDone = <String, String>{};

  /// Exchange duties are running (they pay and settle, which takes time).
  bool _fxBusy = false;

  /// Other pyramids folded (pyramid → state, when), cleared with [_dirty].
  final Map<String, ({PyramidState state, int at})> _others =
      <String, ({PyramidState state, int at})>{};
  final Set<String> _announced = <String>{};

  /// Crisis waves already handled (the newest few hundred, kept).
  final Set<String> _crisisSeen = <String>{};

  /// Pyramids this phone keeps or is joining (id → since when, this
  /// phone's time): records of any other pyramid are not taken.
  final Map<String, int> _follow = <String, int>{};

  /// What this person has signed (the body without its time → until
  /// when): a fresh copy of the same proposal is signed again without
  /// asking, so late approvals never publish a record dated in the past.
  final Map<String, int> _consent = <String, int>{};

  /// Emissions this phone first saw late (id → when seen, §23.4).
  final Map<String, int> _lateEmits = <String, int>{};

  /// Anonymous sums from the members right below (§20.2a, §22.1a): topic
  /// ([kPyrStatsTopic], or 'r|' + a post id) → member → their branch's
  /// numbers.
  final Map<String, Map<String, List<int>>> _sumsBelow =
      <String, Map<String, List<int>>>{};

  /// What this person last sent up, per topic (sent again only changed).
  final Map<String, List<int>> _sumsSent = <String, List<int>>{};

  /// Political posts this person opened (id → when), for "przeczytało".
  final Map<String, int> _readPosts = <String, int>{};

  /// Market messages whose payment has not arrived yet (§24).
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

  /// Pyramids this phone has records of.
  List<String> get knownPyramids => <String>[
    for (final PyramidRecord r in _records.values)
      if (r.type == PyrT.genesis) r.id,
  ];

  PyramidState? stateOf(String pyramid) => PyramidState.fold(
    pyramid,
    _records.values,
    now: _now(),
    treasurerSigs: _tsigs,
  );

  /// The pyramid this person is in (§20.5), folded.
  PyramidState? get state {
    final String? py = current;
    if (py == null) {
      return null;
    }
    if (_state == null || _now() - _stateAt > 60 * 1000) {
      _state = stateOf(py);
      _stateAt = _now();
    }
    return _state;
  }

  bool get isMember {
    final String? k = myKey;
    return k != null && (state?.isMember(k) ?? false);
  }

  /// The state of pyramid [py]: the one shown, or another one this phone
  /// keeps (folded once a minute at most, like the one shown).
  PyramidState? _stateFor(String py) {
    if (py.isEmpty) {
      return null;
    }
    if (py == current) {
      return state;
    }
    final ({PyramidState state, int at})? had = _others[py];
    final int t = _now();
    if (had != null && t - had.at <= 60 * 1000) {
      return had.state;
    }
    final PyramidState? s = stateOf(py);
    if (s == null) {
      _others.remove(py);
      return null;
    }
    _others[py] = (state: s, at: t);
    return s;
  }

  /// The state of pyramid [py] this phone keeps (cached for a minute; the
  /// one shown is [state]).
  PyramidState? pyramidState(String py) => _stateFor(py);

  /// Pyramids this person is a member of (not closed), the shown one first.
  List<PyramidState> get myPyramids {
    final String? me = myKey;
    if (me == null) {
      return const <PyramidState>[];
    }
    final List<String> ids = <String>[
      ?current,
      for (final String py in knownPyramids)
        if (py != current) py,
    ];
    return <PyramidState>[
      for (final String py in ids)
        if (_stateFor(py) case final PyramidState s
            when s.isMember(me) && s.mergedInto == null)
          s,
    ];
  }

  void _dirty() {
    _state = null;
    _others.clear();
  }

  /// Picks the pyramid to show (§20.5): the one this person is in (the one
  /// it merged into, if so), else the one with most friends.
  void _choose() {
    final String? k = myKey;
    String? best;
    int bestFriends = -1;
    // A member of more than one pyramid sees the one joined last (joining
    // is the clearest sign of where someone wants to be).
    int newestJoin = -1;
    String? mine;
    for (final String py in knownPyramids) {
      final PyramidState? s = stateOf(py);
      if (s == null || k == null || !s.isMember(k) || s.mergedInto != null) {
        continue;
      }
      final int joined = s.members[k]?.joinedAt ?? 0;
      if (joined > newestJoin) {
        newestJoin = joined;
        mine = py;
      }
    }
    best = mine;
    for (final String py in mine == null ? knownPyramids : const <String>[]) {
      final PyramidState? s = stateOf(py);
      if (s == null) {
        continue;
      }
      final Set<String> friends = host.friends().map(_n).toSet();
      final int count = s.members.values
          .where((PyrMember m) => friends.contains(_n(m.addr)))
          .length;
      if (count > bestFriends) {
        best = py;
        bestFriends = count;
      }
    }
    if (best != current) {
      current = best;
      _dirty();
    }
  }

  // ---- storage ----

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_keyMe);
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        _seed = json['seed'] is String ? json['seed'] as String : null;
        final Uint8List? seed = unb64(_seed, length: 32);
        _identity = seed == null ? null : await LedgerKeyPair.fromSeed(seed);
        myData = json['data'] is Map
            ? Map<String, dynamic>.from(json['data'] as Map)
            : <String, dynamic>{};
        current = json['cur'] is String ? json['cur'] as String : null;
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
        _fxKeys
          ..clear()
          ..addAll(_strs(json['fxk']));
        _fxDone
          ..clear()
          ..addAll(_strs(json['fxd']));
        _fxOut.clear();
        if (json['fxo'] is Map) {
          for (final MapEntry<dynamic, dynamic> e
              in (json['fxo'] as Map).entries) {
            if (e.key is String && e.value is Map) {
              _fxOut[e.key as String] = Map<String, dynamic>.from(
                e.value as Map,
              );
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
        _follow
          ..clear()
          ..addAll(_ints(json['fol']));
        _consent
          ..clear()
          ..addAll(_ints(json['cs']));
        _lateEmits
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
      _diskUnreadable = false;
      if (logged != null) {
        _records.clear();
        // In order: a record appended again later (with more signatures)
        // replaces its earlier entry and keeps its place.
        for (final Object? item in logged) {
          if (item is! Map) {
            continue;
          }
          final PyramidRecord? r = PyramidRecord.fromJson(item['r']);
          if (r != null) {
            _records[r.id] = r;
            if (item['tv'] is List) {
              _tsigs[r.id] = (item['tv'] as List).whereType<String>().toSet();
            }
          }
        }
        // Memory is what is on disk now.
        _recordsUnsaved.clear();
        _recordsRewrite = false;
      }
      final String? cur = current;
      if (cur != null) {
        _follow.putIfAbsent(cur, () => 0);
      }
      _dirty();
      if (current == null) {
        _choose();
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt piramidy', error, stack);
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
          if (_seed != null) 'seed': _seed,
          'data': myData,
          if (current != null) 'cur': current,
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
          'fxk': _fxKeys,
          'fxd': _fxDone,
          'fxo': _fxOut,
          'ann': _announced.toList(),
          'mk': <Map<String, dynamic>>[
            for (final PyrMarketMessage m in market.values) m.toJson(),
          ],
          'cr': _crisisSeen.toList(),
          'fol': _follow,
          'cs': _consent,
          'le': _lateEmits,
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

  Future<LedgerKeyPair> _ensureIdentity() async {
    if (_identity != null) {
      return _identity!;
    }
    final LedgerKeyPair k = await LedgerKeyPair.generate();
    _identity = k;
    _seed = b64(k.seed);
    await _save();
    return k;
  }

  // ---- records in and out ----

  /// Keeps [py]'s records from now on (this phone joins, founds, looks at
  /// or follows it).
  void _followPyramid(String py) {
    if (py.isNotEmpty) {
      _follow.putIfAbsent(py, _now);
    }
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
    for (final PyramidRecord r in rs) {
      final PyramidRecord? kept = await _check(r);
      if (kept == null) {
        continue;
      }
      if (!folded) {
        before = current == null ? null : state;
        folded = true;
      }
      _keep(kept);
      added.add(kept);
    }
    if (added.isEmpty) {
      return added;
    }
    _dirty();
    if (current == null ||
        added.any(
          (PyramidRecord x) =>
              x.type == PyrT.genesis ||
              x.type == PyrT.admit ||
              x.type == PyrT.merged ||
              x.type == PyrT.merge,
        )) {
      _choose();
    }
    await _save(records: true);
    if (spread) {
      for (final PyramidRecord x in added) {
        await _spread(x, except: from);
      }
    }
    for (final PyramidRecord x in added) {
      if (x.type == PyrT.merge) {
        await _closeAfterMerge(x);
      }
    }
    if (added.any((PyramidRecord x) => x.type == PyrT.merged)) {
      await _followMerge();
    }
    await _afterChange(before);
    return added;
  }

  /// Stores a checked record: published, so nothing more to sign or to
  /// wait for — also no other copy of the same content.
  void _keep(PyramidRecord r) {
    final int t = _now();
    final PyramidRecord? had = _records[r.id];
    _records[r.id] = r;
    _recordsUnsaved.add(r.id);
    if (PyrT.treasured.contains(r.type)) {
      _tsigs[r.id] = r.tsigs.keys.toSet();
    }
    if (had == null && (r.type == PyrT.emit || r.type == PyrT.merge)) {
      // Seen long after its own time while this phone already kept the
      // pyramid: late — back-dated past its veto window, or held back (a
      // merge too: the money it converts is new money here).
      final int since = _follow[r.pyramid] ?? t;
      if (t - r.at > kPyrLateEmitMs && t - since > 3600 * 1000) {
        _lateEmits[r.id] = t;
      }
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
    final String py = r.type == PyrT.genesis ? r.id : r.pyramid;
    if (py.isEmpty || !_follow.containsKey(py)) {
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
    final Uint8List? seed = unb64(_seed, length: 32);
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

  /// Once the merge is in the other pyramid, the head of the old top asks
  /// the old top (2 of 3) to close it: from then on its records are the
  /// past and everybody lives in the bigger pyramid (§20.5).
  Future<void> _closeAfterMerge(PyramidRecord r) async {
    final String old = r.str('from');
    final String? me = myKey;
    if (old.isEmpty ||
        me == null ||
        !knownPyramids.contains(old) ||
        !knownPyramids.contains(r.pyramid)) {
      return;
    }
    final PyramidState? before = stateOf(old);
    final PyramidState? into = stateOf(r.pyramid);
    if (before == null ||
        into == null ||
        before.mergedInto != null ||
        before.occupant[''] != me ||
        !into.applied.contains(r.id)) {
      return;
    }
    final bool asked = _mine.values.any(
      (PyramidRecord x) => x.type == PyrT.merged && x.pyramid == old,
    );
    if (asked) {
      return;
    }
    await propose(
      <String, dynamic>{
        't': PyrT.merged,
        'py': old,
        'into': r.pyramid,
        // The money went over as counted then: nothing later counts here.
        if (r.body['cut'] is int) 'cut': r.body['cut'],
      },
      candidates: before.topCell,
      need: min(2, before.topCell.length),
    );
  }

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
    final List<String> pys = knownPyramids;
    for (final String f in to ?? host.friends()) {
      await _send(f, <String, dynamic>{
        'type': PyramidTypes.hello,
        'py': <Map<String, dynamic>>[
          for (final String py in pys)
            <String, dynamic>{'id': py, 'd': _digest(py)},
        ],
      });
    }
  }

  /// Sends everything of [py] to [to] (after admitting them).
  Future<void> sendAll(String to, String py) async {
    final List<PyramidRecord> list = <PyramidRecord>[
      for (final PyramidRecord r in _records.values)
        if (r.id == py || r.pyramid == py) r,
    ]..sort((PyramidRecord a, PyramidRecord b) => a.at.compareTo(b.at));
    for (int i = 0; i < list.length; i += 40) {
      await _send(to, <String, dynamic>{
        'type': PyramidTypes.records,
        'rs': <Map<String, dynamic>>[
          for (final PyramidRecord r in list.sublist(
            i,
            min(i + 40, list.length),
          ))
            r.toJson(),
        ],
      });
    }
  }

  /// Asks friends for the pyramids they keep and this phone does not (to
  /// look at them, or to join ours to one as a branch). Returns how many
  /// were asked for.
  Future<int> fetchFriendsPyramids() async {
    final Set<String> mine = knownPyramids.toSet();
    final Set<String> asked = <String>{};
    for (final MapEntry<String, Set<String>> e in _peers.entries) {
      for (final String py in e.value) {
        if (!mine.contains(py) && asked.add(py)) {
          _followPyramid(py);
          await _send(e.key, <String, dynamic>{
            'type': PyramidTypes.wantAll,
            'py': py,
          });
        }
      }
    }
    if (asked.isNotEmpty) {
      await _save();
    }
    return asked.length;
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
        'n': _cut(name.trim(), 40),
        'nat': nat.trim().toUpperCase(),
        'dc': myData['dc'],
        'addr': _n(host.ownAddress()),
      };

  void _setData(int birthYear, String gender) {
    final String salt = _newId(16);
    myData = <String, dynamic>{
      'by': birthYear,
      'g': gender,
      'salt': salt,
      'dc': dataCommit(birthYear, gender, salt),
    };
  }

  /// Starts a new pyramid with this person at the top.
  Future<String> createPyramid({
    required String name,
    required String myName,
    required String nat,
    required int birthYear,
    required String gender,
  }) async {
    final LedgerKeyPair me = await _ensureIdentity();
    _setData(birthYear, gender);
    final PyramidRecord g = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.genesis,
        'py': '',
        'at': _now(),
        'by': <String>[me.id],
        'name': name.trim(),
        'founder': _memberJson(me, myName, nat),
        // A new pyramid starts with the newest rules (rules 2, §21.7).
        'params': PyrParams(rules: kPyrRules).toJson(),
      },
    ).signedBy(me);
    current = g.id;
    _followPyramid(g.id);
    await ingest(g);
    return g.id;
  }

  /// The QR a cell head shows to admit a friend met in person (§20.2).
  String? inviteCode() {
    final PyramidState? s = state;
    final String? k = myKey;
    final String? p = k == null ? null : s?.pathOf(k);
    if (s == null || p == null || s.freeSlot(p) == null) {
      return null;
    }
    return 'zen-pyr:${base64Url.encode(utf8.encode(jsonEncode(<String, String>{'py': s.id, 'h': k!, 'a': _n(host.ownAddress())}))).replaceAll('=', '')}';
  }

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
          json['h'] is String &&
          json['a'] is String) {
        return <String, String>{
          'py': json['py'] as String,
          'h': json['h'] as String,
          'a': json['a'] as String,
        };
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// The newcomer's side: asks the head to admit (data to confirm).
  Future<bool> askToJoin({
    required String invite,
    required String myName,
    required String nat,
    required int birthYear,
    required String gender,
  }) async {
    final Map<String, String>? inv = parseInvite(invite);
    if (inv == null) {
      return false;
    }
    final LedgerKeyPair me = await _ensureIdentity();
    _setData(birthYear, gender);
    final PyramidRecord r = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.admit,
        'py': inv['py'],
        'at': _now(),
        'by': <String>[inv['h']!, me.id],
        'head': inv['h'],
        'm': _memberJson(me, myName, nat),
        'pn': _newId(16),
      },
    ).signedBy(me);
    _mine[r.id] = r;
    _mineNeed[r.id] = 2;
    _agree(r);
    // The pyramid this person is joining: its records are taken from now.
    _followPyramid(inv['py']!);
    await _save();
    await _send(inv['a']!, <String, dynamic>{
      'type': PyramidTypes.proposal,
      'r': r.toJson(),
      'need': 2,
      'x': <String, dynamic>{
        'by': birthYear,
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
  /// (a newcomer, another pyramid's merge) the count [need] decides. Once
  /// everybody asked has signed, it goes out either way.
  bool _ready(PyramidRecord r, int need) {
    if (r.candidates.every(r.sigs.containsKey)) {
      return true;
    }
    final String py = r.type == PyrT.genesis ? r.id : r.pyramid;
    if (!knownPyramids.contains(py)) {
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
      // (signed late, §20.5) count once, however many go round.
      if (candidates.any((String k) => k != me.id) && body['pn'] == null)
        'pn': _newId(16),
    };
    // A revocation lists the acts of the delegate it knows of: anything
    // dated earlier that is not on the list was made up later (§21.2).
    if (full['t'] == PyrT.revoke &&
        full['acts'] == null &&
        full['d'] is String) {
      full['acts'] = (state?.actsOf(full['d'] as String).toList() ?? <String>[])
        ..sort();
    }
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
      // Stays waiting: the level can still be raised (§20.2).
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
      final String py = signed.pyramid;
      // A newcomer gets the whole pyramid.
      if (signed.type == PyrT.admit && p.from.isNotEmpty) {
        await sendAll(p.from, py);
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
    if (r.pyramid != current && knownPyramids.contains(r.pyramid)) {
      final String other = stateOf(r.pyramid)?.members[key]?.addr ?? '';
      if (other.isNotEmpty) {
        return other;
      }
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

  /// Why this person cannot admit the newcomer of [p] yet (§20.2), or
  /// null (also for anything but an admission): the newcomer must be a
  /// friend (met in person, the QR) at the level "Znajomy" or above.
  String? admitProblem(PyrProposal p) {
    if (p.record.type != PyrT.admit) {
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

  /// Open swap in a cell (§20.3): proposes that [up] becomes its head.
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

  /// Anonymous request for a new vote in a cell (§20.3a).
  Future<bool> requestElection(String cell) async {
    final PyramidState? s = state;
    final LedgerKeyPair? me = _identity;
    final String? head = s?.occupant[cell];
    if (s == null || me == null || head == null) {
      return false;
    }
    final List<String> ring = s.cellOf(cell)..sort();
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

  /// Anonymous vote for the head of a cell (§20.3a).
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

  /// One of the people under a free place moves up into it (§20.4).
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

  /// Moves this person under [toHead] (§20.4). With [branch], everybody
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

  // ---- power (§21) ----

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

  Future<PyramidRecord?> ban({
    required String target,
    required String kind,
    int? until,
    String? hash,
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
        'hash': ?hash,
        // The entry itself (S36); the hash stays for 1.10.0 phones.
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

  Future<PyramidRecord?> referendum({
    required String question,
    required List<String> options,
    required int end,
    String scopeKind = 'all',
    String scopePath = '',
    String scopeNat = '',
    String kind = 'normal',
    Map<String, dynamic>? params,
    String? via,
  }) async {
    // New rules need at least 72 h of voting (§21.7); a day more, so a
    // late second signature (a fresh copy, §20.5) still leaves enough.
    final int minEnd = _now() + kPyrMinConstitutionMs + 24 * 3600 * 1000;
    // Money above the limit is voted on the same way (§23.4).
    final int finalEnd = kind == 'constitution' || kind == 'emit'
        ? (end < minEnd ? minEnd : end)
        : max(end, _now() + kPyrMinReferendumMs + 5000);
    // Through a branch delegation only the branch can be asked.
    final ({String kind, String path}) scope = _delegatedScope(
      via,
      scopeKind,
      scopePath,
    );
    final Map<String, dynamic> body = <String, dynamic>{
      't': PyrT.referendum,
      'params': ?params,
      'q': question,
      'opts': options,
      'end': finalEnd,
      'scope': <String, String>{
        'k': scope.kind,
        'p': scope.path,
        'nat': scopeNat,
      },
      'kind': kind,
    };
    final PyramidState? s = state;
    if (scopeKind == 'nat' && s != null && s.nationalLead(scopeNat) == myKey) {
      return propose(body, candidates: <String>[myKey!], need: 1);
    }
    return topDecision(body, via: via);
  }

  /// The reach of an act through delegation [via]: a delegate of a branch
  /// reaches only that branch (§21.2), so anything wider becomes the
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

  // ---- referendum votes and sums (§21.3) ----

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
        if (s.pathOf(v.key) != null && PyrPath.parent(s.pathOf(v.key)!) == mp) {
          counts[v.value]++;
        }
      }
      for (final String v in extra) {
        final int? o = int.tryParse(v.split(':').last);
        if (o != null && o >= 0 && o < counts.length) {
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

  // ---- money (§23) ----

  /// Pays [to]: an order to the treasurers, valid with a majority of them.
  /// With [condBy], it waits for that person's word (§24); with [share],
  /// it is an announcement passed on through intermediaries, each keeping
  /// [share], at most [hops] times after the first ([hash]: its text).
  /// With [lock], it is an exchange payment, taken only with the key of
  /// the lock ([fx]: what the exchanger pays out elsewhere, §23.5). In
  /// [pyramid] (another one this person is in), else the one shown.
  Future<PyramidRecord?> pay(
    String to,
    int amount, {
    String memo = '',
    String? condBy,
    int? condUntil,
    int share = 0,
    int hops = 0,
    String? hash,
    String? lock,
    Map<String, dynamic>? fx,
    String? pyramid,
  }) async {
    final PyramidState? s = pyramid == null ? state : _stateFor(pyramid);
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
            'hl': ?lock,
            'fx': ?fx,
          };
    if (pyrCondProblem(cond) != null) {
      return null;
    }
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

  /// One order at a time per account and pyramid (the next needs the next
  /// number).
  bool _paymentWaiting(String payer, String py) => _payments.values.any(
    (PyramidRecord r) =>
        r.type == PyrT.transfer && r.str('from') == payer && r.pyramid == py,
  );

  /// Sends a signed order (or settlement) to every treasurer of its
  /// pyramid (this phone's own part directly). It is kept until most of
  /// them have signed — also across a restart — and sent again as it is.
  Future<void> _toTreasurers(PyramidRecord order) async {
    final PyramidState? s = _stateFor(order.pyramid);
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
  /// two orders with the same number, never two settlements of one payment
  /// (§23.2, §23.5). Any pyramid this person keeps and is a treasurer of.
  Future<void> _onPay(String from, Map<String, dynamic> p) async {
    final LedgerKeyPair? me = _identity;
    final PyramidRecord? order = PyramidRecord.fromJson(p['r']);
    if (me == null ||
        order == null ||
        !PyrT.treasured.contains(order.type) ||
        !_follow.containsKey(order.pyramid)) {
      return;
    }
    final PyramidState? s = _stateFor(order.pyramid);
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
  /// signed it, it is the next number, the condition is well formed, the
  /// money is there — and not money of an emission this phone saw late and
  /// that has not yet waited here as long as its veto time
  /// ([kPyrLateEmitMs], §23.4).
  String? _orderSlot(PyramidState s, PyramidRecord order) {
    final String payer = order.str('from');
    final int amount = order.integer('amount');
    final PyrAccount acc = s.accounts[payer] ?? PyrAccount();
    if (!s.canSpend(payer, order.signers) ||
        order.integer('seq') != acc.seq + 1 ||
        amount <= 0 ||
        amount > kPyrMaxAmount ||
        pyrCondProblem(order.body['cond']) != null) {
      return null;
    }
    if (acc.balance - heldEmission(payer, s) < amount) {
      return null;
    }
    return '$payer|${order.integer('seq')}';
  }

  /// The payment a settlement settles, when it is one to sign: by the one
  /// whose word the payment waits for (an acceptance only while it waits,
  /// and of an exchange payment only with the key of its lock), or the
  /// payer's refund after the time.
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
    final String? lock = e.lock;
    if (ok && lock != null && !pyrUnlocks(lock, r.str('pre'))) {
      return null;
    }
    return 'x|${e.id}';
  }

  /// Money of [key] from emissions this phone first saw late, still
  /// waiting here: treasurers do not sign spending it yet, so the veto can
  /// still come without undoing payments (§23.4). In [st], else the
  /// pyramid shown.
  int heldEmission(String key, [PyramidState? st]) {
    final PyramidState? s = st ?? state;
    if (s == null) {
      return 0;
    }
    final int t = _now();
    int held = 0;
    for (final PyrEmission e in s.emissions.values) {
      final int? seen = _lateEmits[e.group ?? e.id];
      if (seen != null &&
          e.to == key &&
          e.done &&
          !e.vetoed &&
          t < seen + s.params.emitDelayHours * 3600 * 1000) {
        held = pyrAdd(held, e.amount);
      }
    }
    return held;
  }

  /// Whether this phone first saw emission [id] late (for money converted
  /// at a merge: the merge record's id, [PyrEmission.group]).
  bool seenLate(String id) => _lateEmits.containsKey(id);

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
    final PyramidState? s = _stateFor(order.pyramid);
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

  /// Payments waiting for treasurers (in any pyramid).
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
  /// one person it goes on to (with the rest of the money); for an
  /// exchange payment, [pre] is the key of its lock. Like a transfer, it
  /// goes to the treasurers, who sign one settlement per payment (§23.5);
  /// it counts once most of them have. In [pyramid], else the one shown.
  Future<PyramidRecord?> settle(
    String transferId,
    bool ok, {
    String? next,
    String? pre,
    String? pyramid,
  }) async {
    final LedgerKeyPair? me = _identity;
    final PyramidState? s = pyramid == null ? state : _stateFor(pyramid);
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
        if (ok && pre != null) 'pre': pre,
      },
    ).signedBy(me);
    await _toTreasurers(r);
    return r;
  }

  Future<PyramidRecord?> emit(String to, int amount, String why) => topDecision(
    <String, dynamic>{'t': PyrT.emit, 'to': to, 'amount': amount, 'why': why},
  );

  /// Whether this person may still veto [e]: one of those who could when
  /// it was signed, within its waiting time — or, when it reached this
  /// phone late (back-dated?), within the same time counted from then.
  bool canVeto(PyrEmission e) {
    final String? k = myKey;
    if (k == null || e.vetoed || !e.vetoers.contains(k)) {
      return false;
    }
    final int t = _now();
    final int? seen = _lateEmits[e.group ?? e.id];
    return t < e.effectiveAt ||
        (seen != null && t < seen + (e.effectiveAt - e.at));
  }

  /// Vetoes emission [emitId]. The veto is dated within the emission's
  /// waiting time — when it came late, at the last moment of it — so it
  /// counts the same on every phone (§23.4).
  Future<PyramidRecord?> veto(String emitId) async {
    final String? k = myKey;
    if (k == null) {
      return null;
    }
    final PyrEmission? e = state?.emissions[emitId];
    final int t = _now();
    final int at = e == null ? t : min(max(t, e.at), e.effectiveAt - 1);
    return propose(
      <String, dynamic>{'t': PyrT.veto, 'emit': emitId},
      candidates: <String>[k],
      need: 1,
      at: at,
    );
  }

  /// Publishes this person's prices (§24): [prices] the same for
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

  // ---- tips (§17.5, §24) ----

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

  // ---- the access market (§24) ----

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

  /// Writes to member [to] through the market: pays the asked price as a
  /// conditional payment that [to] keeps or returns (§24). An announcement
  /// ('ad') may go through [steps] intermediaries, each keeping [share]
  /// (at least what [to] asks); [to] is the first of them.
  ///
  /// A paid introduction ('intro') to member [introduce]: the payment goes
  /// to [to], the intermediary, but waits for [introduce]'s answer (§24) —
  /// paid when they accept, back to the payer when they refuse, or when
  /// nobody answers in a week.
  Future<bool> sendMarket(
    String to,
    String kind,
    String text, {
    int steps = 1,
    int? share,
    String? introduce,
  }) async {
    final PyramidState? s = state;
    final String? me = myKey;
    final PyrMember? m = s?.members[to];
    if (s == null ||
        me == null ||
        m == null ||
        m.addr.isEmpty ||
        text.trim().isEmpty ||
        to == me) {
      return false;
    }
    final String? target = kind == 'intro' ? introduce : null;
    if (target != null &&
        (target == me || target == to || !s.isMember(target))) {
      return false;
    }
    final String body = text.trim();
    final ({int price, String? level}) asked = priceToSend(to, kind);
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
        condBy: target ?? to,
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
      introduce: target,
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
      'y': ?target,
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
    final String? payment = p['x'] is String ? p['x'] as String : null;
    final String? origin = p['o'] is String && s.members.containsKey(p['o'])
        ? p['o'] as String
        : null;
    // A paid introduction (§24): at the intermediary it names the member
    // to introduce to (who decides on the payment); at that member it
    // comes from the intermediary, paid by [origin], and the money is the
    // intermediary's once this person accepts.
    final Object? y = p['y'];
    final String? introduce =
        kind == 'intro' && y is String && y != me && s.isMember(y) ? y : null;
    final bool introducedHere = kind == 'intro' && y == me && origin != null;
    // The price for the sender's level, as this phone knows them (§24);
    // an introduction passed on was priced by the intermediary.
    final String level = levelOfAddress(from) ?? 'stranger';
    final int asked = introducedHere ? 0 : s.priceFor(me, kind, level) ?? 0;
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
            't': _cut(text, 4000),
            'x': payment,
            if (p['h'] is int) 'h': p['h'],
            'o': ?origin,
            if (p['y'] is String) 'y': p['y'],
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
          escrow.condBy != (introduce ?? me) ||
          escrow.to != (introducedHere ? sender : me) ||
          escrow.from != (origin ?? sender) ||
          escrow.settled != null ||
          escrow.until < _now() + kPyrMarketMinWaitMs ||
          escrow.lock != null ||
          (escrow.hash != null && escrow.hash != contentHash(text));
    }
    if (forged || paid < asked) {
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
      text: _cut(text, 4000),
      at: _now(),
      payment: payment,
      amount: paid,
      hops: hops,
      origin: origin,
      level: level,
      introduce: introduce,
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
        body: text,
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

  /// Keeps the payment (and, for a reshare or an announcement, posts it to
  /// this person's branch) or returns it. An announcement that may go
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
    final String? introduce = m.introduce;
    if (m.kind == 'intro' && introduce != null) {
      // The intermediary of a paid introduction (§24) does not take the
      // money: it passes the request on, and the person asked decides.
      m.done = true;
      await _save();
      final String addr = s?.members[introduce]?.addr ?? '';
      if (!accept || addr.isEmpty || me == null) {
        return;
      }
      await _send(addr, <String, dynamic>{
        'type': PyramidTypes.dm,
        'id': _newId(16),
        'k': 'intro',
        'f': me,
        't': m.text,
        'x': ?m.payment,
        'a': m.amount,
        'o': m.origin ?? m.from,
        'y': introduce,
      });
      return;
    }
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
    PyramidRecord? settled;
    if (m.payment != null) {
      settled = await settle(
        m.payment!,
        accept,
        next: onwardAddr.isEmpty ? null : onward,
      );
    }
    if (accept && (m.kind == 'reshare' || m.kind == 'ad')) {
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

  // ---- exchange between pyramids (§23.5) ----

  /// Announces this person's offer as an exchanger: in pyramid [payoutPy]
  /// (where this person pays out), [numer] hundredths for every [denom]
  /// received in pyramid [fromPy], at most [most] per exchange (0 = no
  /// limit). [numer] 0 withdraws the offer.
  Future<PyramidRecord?> setFxRate({
    required String payoutPy,
    required String fromPy,
    required int numer,
    int denom = 10000,
    int most = 0,
  }) async {
    final String? me = myKey;
    final PyramidState? s = _stateFor(payoutPy);
    if (me == null ||
        s == null ||
        !s.isMember(me) ||
        fromPy.isEmpty ||
        fromPy == payoutPy ||
        numer < 0 ||
        numer > kPyrMaxRate ||
        denom < 1 ||
        denom > kPyrMaxRate ||
        most < 0 ||
        most > kPyrMaxAmount) {
      return null;
    }
    return propose(
      <String, dynamic>{
        't': PyrT.fxRate,
        'py': payoutPy,
        'k': me,
        'from': fromPy,
        'n': numer,
        'd': denom,
        'max': most,
      },
      candidates: <String>[me],
      need: 1,
    );
  }

  /// Who can exchange money of the pyramid shown into pyramid [other]:
  /// members of both (not this person), each with the rate it pays out in
  /// [other] (null: no offer yet).
  List<({String key, String name, PyrFxRate? rate})> exchangers(String other) {
    final PyramidState? s = state;
    final PyramidState? q = _stateFor(other);
    final String? me = myKey;
    if (s == null || q == null || other == s.id) {
      return const <({String key, String name, PyrFxRate? rate})>[];
    }
    return <({String key, String name, PyrFxRate? rate})>[
      for (final String k in s.position.keys)
        if (k != me && q.isMember(k))
          (key: k, name: s.members[k]?.name ?? '?', rate: q.fxRates[k]?[s.id]),
    ]..sort(
      (
        ({String key, String name, PyrFxRate? rate}) a,
        ({String key, String name, PyrFxRate? rate}) b,
      ) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  /// Pays [to] in pyramid [other] through the exchanger [via], a member
  /// of both (§23.5); [to] gets [amount] there. This person pays [via]
  /// here what its rate asks, locked with a key only this person knows,
  /// and gives the key to [to]. [via] pays [to] there, locked the same
  /// way; [to] takes it with the key, which shows [via] the key to take
  /// the money here. When nothing happens, both come back after their
  /// time. Returns the payment and what it costs here.
  Future<({PyramidRecord order, int cost})?> payAcross({
    required String other,
    required String to,
    required String via,
    required int amount,
  }) async {
    final PyramidState? s = state;
    final PyramidState? q = _stateFor(other);
    final String? me = myKey;
    if (s == null ||
        q == null ||
        me == null ||
        other == s.id ||
        amount <= 0 ||
        amount > kPyrMaxAmount ||
        !s.isMember(me) ||
        !s.isMember(via) ||
        !q.isMember(via) ||
        !q.isMember(to) ||
        via == me ||
        via == to ||
        to == me) {
      return null;
    }
    final PyrFxRate? rate = q.fxRates[via]?[s.id];
    if (rate == null || (rate.max > 0 && amount > rate.max)) {
      return null;
    }
    final int cost = pyrConvertUp(amount, rate.numer, rate.denom);
    if (cost <= 0 ||
        rate.payout(cost) < amount ||
        s.balanceOf(me) - heldEmission(me, s) < cost) {
      return null;
    }
    final String key = _newId(32);
    final String lock = sha256Hex(utf8.encode(key));
    final int nowMs = _now();
    final PyramidRecord? order = await pay(
      via,
      cost,
      memo: t('Wymiana: {amount} dla {name} w „{pyramid}”', {
        'amount': formatMoney(amount),
        'name': q.members[to]?.name ?? '?',
        'pyramid': q.name,
      }),
      condBy: via,
      condUntil: nowMs + kPyrFxWaitMs,
      lock: lock,
      fx: <String, dynamic>{'py': other, 'to': to, 'a': amount},
    );
    if (order == null) {
      return null;
    }
    _fxOut[lock] = <String, dynamic>{
      's': key,
      'py': other,
      'to': to,
      'p': s.id,
      'x': order.id,
      'at': nowMs,
      'sent': 0,
    };
    _trimFx();
    await _save();
    await _sendFxKey(lock);
    return (order: order, cost: cost);
  }

  /// Whether this phone holds the key of exchange lock [lock] (as the one
  /// paid out).
  bool hasFxKey(String lock) => _fxKeys.containsKey(lock);

  /// Sends the key of [lock] to the one paid out there.
  Future<void> _sendFxKey(String lock) async {
    final Map<String, dynamic>? x = _fxOut[lock];
    final Object? py = x?['py'];
    final Object? to = x?['to'];
    final Object? key = x?['s'];
    if (x == null || py is! String || to is! String || key is! String) {
      return;
    }
    x['sent'] = _now();
    final String addr = _stateFor(py)?.members[to]?.addr ?? '';
    if (addr.isEmpty) {
      return;
    }
    final Map<String, dynamic> json = <String, dynamic>{'h': lock, 's': key};
    if (_n(addr) == _n(host.ownAddress())) {
      await _onFxKey(json);
    } else {
      await _send(addr, <String, dynamic>{'type': PyramidTypes.fxKey, ...json});
    }
  }

  /// The key of an exchange lock, from the payer: kept when it opens the
  /// lock (anybody may send one; a key that fits proves itself).
  Future<void> _onFxKey(Map<String, dynamic> p) async {
    final Object? lock = p['h'];
    final Object? key = p['s'];
    if (lock is! String ||
        key is! String ||
        !pyrIsLock(lock) ||
        !pyrUnlocks(lock, key) ||
        _fxKeys[lock] == key) {
      return;
    }
    _fxKeys[lock] = key;
    _trimFx();
    await _save();
  }

  /// Keeps the newest [kPyrFxKept] of each exchange list.
  void _trimFx() {
    for (final Map<String, Object> m in <Map<String, Object>>[
      _fxKeys,
      _fxOut,
      _fxDone,
    ]) {
      while (m.length > kPyrFxKept) {
        m.remove(m.keys.first);
      }
    }
  }

  /// Exchange work (§23.5), with the duties: takes payouts this person
  /// holds the key for (or that the other side already opened), pays out
  /// as an exchanger (or returns the payment at once when it cannot),
  /// takes back own exchange payments that waited in vain, and sends the
  /// key again to whoever is to be paid out, until it is over.
  Future<void> _fxDuties() async {
    final String? me = myKey;
    if (me == null || _fxBusy) {
      return;
    }
    _fxBusy = true;
    try {
      final int t = _now();
      final List<PyramidState> mine = myPyramids;
      // Keys of locks: received, or shown by whoever took a payout.
      final Map<String, String> opened = <String, String>{..._fxKeys};
      for (final PyramidState s in mine) {
        for (final PyrEscrow e in s.escrows.values) {
          final String? lock = e.lock;
          final String? pre = e.pre;
          if (lock != null && pre != null) {
            opened[lock] = pre;
          }
        }
      }
      for (final PyramidState s in mine) {
        for (final PyrEscrow e in s.escrows.values.toList()) {
          final String? lock = e.lock;
          if (lock == null || e.settled != null) {
            continue;
          }
          if (e.from == me && t >= e.until + kPyrFxRefundGraceMs) {
            // Waited in vain: back (a little after the time, so a late
            // acceptance still signed in time is not split with it).
            await settle(e.id, false, pyramid: s.id);
            continue;
          }
          if (e.condBy != me) {
            continue;
          }
          final String? key = opened[lock];
          if (key != null) {
            if (t < e.until) {
              await settle(e.id, true, pre: key, pyramid: s.id);
            }
            continue;
          }
          if (e.to == me && e.fxPy != null && !_fxDone.containsKey(e.id)) {
            await _fxPayOut(s, e);
          }
        }
      }
      bool changed = false;
      for (final String lock in _fxOut.keys.toList()) {
        final Map<String, dynamic> x = _fxOut[lock]!;
        final Object? home = x['p'];
        final Object? id = x['x'];
        final Object? at = x['at'];
        final PyrEscrow? e = home is String && id is String
            ? _stateFor(home)?.escrows[id]
            : null;
        if (at is! int ||
            t - at > kPyrFxWaitMs + kPyrMaxOrderAgeMs ||
            (e != null && e.settled != null)) {
          _fxOut.remove(lock);
          changed = true;
          continue;
        }
        final Object? sent = x['sent'];
        if (sent is! int || t - sent > 30 * 60 * 1000) {
          await _sendFxKey(lock);
          changed = true;
        }
      }
      if (changed) {
        await _save();
      }
    } finally {
      _fxBusy = false;
    }
  }

  /// As the exchanger: pays out in the other pyramid what the payment [e]
  /// (in [s]) asks, when this person's own rate covers it and the money
  /// and time are there — locked with the same lock, ending a day before
  /// [e] does. Otherwise [e] goes back at once.
  Future<void> _fxPayOut(PyramidState s, PyrEscrow e) async {
    final String? me = myKey;
    final String? py = e.fxPy;
    final String? to = e.fxTo;
    if (me == null || py == null || to == null) {
      return;
    }
    final int nowMs = _now();
    final int until = e.until - kPyrFxMarginMs;
    final PyramidState? q = _stateFor(py);
    final PyrFxRate? rate = q?.fxRates[me]?[s.id];
    if (q == null ||
        rate == null ||
        !q.isMember(me) ||
        q.mergedInto != null ||
        !q.isMember(to) ||
        to == me ||
        e.fxAmount <= 0 ||
        e.fxAmount > rate.payout(e.amount) ||
        (rate.max > 0 && e.fxAmount > rate.max) ||
        until - nowMs < kPyrFxMinPayoutMs ||
        q.balanceOf(me) - heldEmission(me, q) < e.fxAmount) {
      // Not possible (no offer, not enough money, too late): the payment
      // goes back now instead of waiting for days.
      _fxDone[e.id] = '';
      _trimFx();
      await _save();
      await settle(e.id, false, pyramid: s.id);
      return;
    }
    if (_paymentWaiting(me, q.id)) {
      // The next number is taken: next time.
      return;
    }
    final PyramidRecord? order = await pay(
      to,
      e.fxAmount,
      memo: t('Wymiana od {name} z „{pyramid}”', {
        'name': s.members[e.from]?.name ?? '?',
        'pyramid': s.name,
      }),
      condBy: to,
      condUntil: until,
      lock: e.lock,
      pyramid: q.id,
    );
    if (order != null) {
      _fxDone[e.id] = order.id;
      _trimFx();
      await _save();
    }
  }

  // ---- alarm, merge (§28, §20.5) ----

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

  /// Pyramid [py] as it stood at [cut]: only its records up to then.
  PyramidState _foldUpTo(String py, int cut) => PyramidState.fold(
    py,
    <PyramidRecord>[
      for (final PyramidRecord r in _records.values)
        if (r.at <= cut) r,
    ],
    now: cut,
    treasurerSigs: _tsigs,
  );

  /// The money of each person placed in [st]: the balance and what still
  /// waits in conditional payments they made (it would come back to them).
  static Map<String, int> _moneyOf(PyramidState st) {
    final Map<String, int> out = <String, int>{
      for (final String k in st.position.keys)
        if (st.balanceOf(k) > 0) k: st.balanceOf(k),
    };
    for (final PyrEscrow e in st.escrows.values) {
      if (e.settled == null && st.isMember(e.from)) {
        out[e.from] = pyrAdd(out[e.from] ?? 0, e.amount);
      }
    }
    return out;
  }

  /// What the money of the pyramid shown would be in [into] at the rate
  /// [numer]/[denom] (§20.5): its total, converted, the room left in
  /// [into]'s 30-day emission limit (converted money counts in it), and
  /// how many of its own emissions still wait (they would not go over).
  /// Null when [into] is not known here.
  ({int total, int converted, int room, int waiting})? mergeMoney(
    String into, {
    int numer = 1,
    int denom = 1,
  }) {
    final PyramidState? s = state;
    final PyramidState? other = _stateFor(into);
    if (s == null || other == null || other.members.isEmpty) {
      return null;
    }
    int total = 0;
    int converted = 0;
    for (final int v in _moneyOf(s).values) {
      total = pyrAdd(total, v);
      converted = pyrAdd(converted, pyrConvert(v, numer, denom));
    }
    final int t = _now();
    return (
      total: total,
      converted: converted,
      room: max(0, other.params.emitLimit - other.emittedWithin(t)),
      waiting: s.emissions.values
          .where((PyrEmission e) => !e.done && !e.vetoed)
          .length,
    );
  }

  /// Proposes joining this pyramid as a branch under [underKey] of the
  /// pyramid [into] (§20.5): this top (2 of 3) and that person sign. With
  /// a [rate] ({numer, denom}), everybody's money goes over too, converted
  /// at it: counted now (the cut), and 2 of [into]'s top sign as well
  /// (it is new money there, like an emission). Without one, the money
  /// stays behind in the closed pyramid.
  Future<PyramidRecord?> proposeMerge(
    String into,
    String underKey,
    String underAddr, {
    ({int numer, int denom})? rate,
  }) async {
    final PyramidState? shown = state;
    final LedgerKeyPair? me = _identity;
    final PyramidState? other = _stateFor(into);
    if (shown == null || me == null) {
      return null;
    }
    if (rate != null &&
        (rate.numer < 1 ||
            rate.numer > kPyrMaxRate ||
            rate.denom < 1 ||
            rate.denom > kPyrMaxRate ||
            other == null ||
            other.members.isEmpty)) {
      return null;
    }
    _followPyramid(into);
    final int cut = _now();
    final int numer = rate?.numer ?? 1;
    final int denom = rate?.denom ?? 1;
    // With money: the pyramid as it stands at the cut, its records only.
    final PyramidState s = rate == null ? shown : _foldUpTo(shown.id, cut);
    final Map<String, int> money = rate == null
        ? const <String, int>{}
        : _moneyOf(s);
    final bool withMoney = money.values.any(
      (int v) => pyrConvert(v, numer, denom) > 0,
    );
    final List<Map<String, dynamic>> snap = <Map<String, dynamic>>[
      for (final MapEntry<String, String> e in s.occupant.entries)
        <String, dynamic>{
          'p': e.key,
          'k': e.value,
          'n': s.members[e.value]?.name ?? '',
          'nat': s.members[e.value]?.nat ?? '',
          'dc': s.members[e.value]?.dataCommit ?? '',
          'addr': s.members[e.value]?.addr ?? '',
          if (withMoney && (money[e.value] ?? 0) > 0) 'bal': money[e.value],
        },
    ];
    final List<String> theirTop = withMoney ? other!.topCell : const <String>[];
    final int need = withMoney ? 5 : 3;
    final PyramidRecord r = await propose(
      <String, dynamic>{
        't': PyrT.merge,
        'py': into,
        'from': s.id,
        'under': underKey,
        'snap': snap,
        if (withMoney) 'rate': <String, int>{'n': numer, 'd': denom},
        if (withMoney) 'cut': cut,
      },
      candidates: <String>{...s.topCell, underKey, ...theirTop}.toList(),
      need: need,
    );
    final Map<String, dynamic> ask = <String, dynamic>{
      'type': PyramidTypes.proposal,
      'r': r.toJson(),
      'need': need,
      'x': const <String, dynamic>{'what': 'merge'},
    };
    final Set<String> sent = <String>{_n(host.ownAddress())};
    for (final String addr in <String>[
      underAddr,
      for (final String k in theirTop) other?.members[k]?.addr ?? '',
    ]) {
      if (addr.isNotEmpty && sent.add(_n(addr))) {
        await _send(addr, ask);
      }
    }
    return r;
  }

  // ---- emission above the limit (§23.4) ----

  /// Asks the whole pyramid to allow emitting [amount] to [to] above the
  /// 30-day limit (§23.4): a referendum of everybody, at least 72 h like
  /// new rules, passed by more than half of the active members with "Tak"
  /// above the rest. The emission itself follows ([emitByReferendum]); it
  /// still waits its day and can be vetoed.
  Future<PyramidRecord?> emitReferendum({
    required String to,
    required int amount,
    required String why,
    int? end,
  }) async {
    final PyramidState? s = state;
    if (s == null ||
        s.params.rules < 2 ||
        !s.isMember(to) ||
        amount <= 0 ||
        amount > kPyrMaxAmount) {
      return null;
    }
    return referendum(
      question: t('Emisja {amount} dla {name} ponad limit: {why}', {
        'amount': formatMoney(amount),
        'name': s.members[to]?.name ?? '?',
        'why': why,
      }),
      options: <String>[t('Tak'), t('Nie')],
      end: end ?? 0,
      kind: 'emit',
      params: <String, dynamic>{'to': to, 'amount': amount},
    );
  }

  /// The emission the referendum [refId] allowed (§23.4), proposed to the
  /// top (2 of 3).
  Future<PyramidRecord?> emitByReferendum(String refId, String why) async {
    final PyrReferendum? r = state?.referenda[refId];
    final Map<String, dynamic>? p = r?.params;
    if (r == null || r.kind != 'emit' || p == null) {
      return null;
    }
    return topDecision(<String, dynamic>{
      't': PyrT.emit,
      'to': p['to'],
      'amount': p['amount'],
      'why': why,
      'ref': refId,
    });
  }

  // ---- national section, badge (§22.2, §20.2a) ----

  /// The section's lead pins (or unpins) a post of the section (§22.2).
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

  /// Shows (or hides) this person's age and gender badge (§20.2a): the
  /// data confirmed at admission is opened publicly, so anybody can check
  /// it against the commitment. Null when there is nothing to show.
  Future<PyramidRecord?> showBadge(bool show) async {
    final String? k = myKey;
    final Object? year = myData['by'];
    final Object? gender = myData['g'];
    final Object? salt = myData['salt'];
    if (k == null || !isMember) {
      return null;
    }
    if (show && (year is! int || gender is! String || salt is! String)) {
      return null;
    }
    return propose(
      show
          ? <String, dynamic>{
              't': PyrT.badge,
              'k': k,
              'yr': year,
              'g': gender,
              'salt': salt,
            }
          : <String, dynamic>{'t': PyrT.badge, 'k': k, 'off': true},
      candidates: <String>[k],
      need: 1,
    );
  }

  // ---- anonymous sums up the tree (§20.2a, §22.1a) ----

  /// Notes that this person opened political posts [ids] ("przeczytało").
  void markRead(Iterable<String> ids) {
    final int t = _now();
    for (final String id in ids) {
      _readPosts.putIfAbsent(id, () => t);
    }
  }

  /// This person's own numbers for [topic] in [s].
  List<int>? _ownSum(PyramidState s, String me, String topic) {
    if (topic == kPyrStatsTopic) {
      final List<int> out = List<int>.filled(kPyrStatsBuckets, 0);
      final Object? year = myData['by'];
      final Object? gender = myData['g'];
      if (year is int && gender is String) {
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

  /// "Dotarło / przeczytało" for this person's own post [postId] (§22.1a):
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

  /// Anonymous statistics of this person's branch (§20.2a): people by
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
  /// of the newest political posts of the line above (§22.1a).
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

  // ---- reports (§21.4) ----

  /// The delegates for reports whose branch covers this person, by the
  /// depth of that branch, the narrowest first: the steps a report climbs
  /// (§21.4).
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

  /// Who gets a report of this person at escalation [stage] (§21.4): the
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

  /// Whether [stage] is the last step, the top (§21.4).
  bool _reportAtTop(int stage) {
    final PyramidState? s = state;
    return s == null || stage >= _reportSteps(s).length;
  }

  /// Reports something (§21.4). [entryId] names the reported entry (a
  /// post, comment or message) and [entry] is its signed original when
  /// this phone has it (S36): a ban then names the entry, not only the
  /// hash of its text.
  Future<PyrReport> report({
    required String reason,
    String target = '',
    String evidence = '',
    String? datingKey,
    String? contentHash,
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
      contentHash: contentHash,
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

  /// Whether this person takes reports from [sender] (§21.4): as one of
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
    final String? hash = r.contentHash;
    return PyrReport(
      id: r.id,
      reason: kReportReasons.containsKey(r.reason) ? r.reason : 'other',
      at: r.at,
      target: PyramidRecord.isCanonicalKey(r.target) ? r.target : '',
      evidence: _cut(r.evidence, kPyrReportEvidenceChars),
      datingKey: dk != null && dk.isNotEmpty && dk.length <= 200 ? dk : null,
      contentHash: hash != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)
          ? hash
          : null,
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

  /// The signed original of a report (S36), when it holds: a well-formed
  /// entry whose device signature and certificate check out, and — when
  /// the report names an entry — that very one. Null otherwise.
  static Future<LogEntry?> verifiedReportEntry(PyrReport r) async {
    final Map<String, dynamic>? json = r.entry;
    if (json == null) {
      return null;
    }
    final LogEntry? e = LogEntry.fromJson(json);
    if (e == null ||
        (r.entryId != null && r.entryId != e.id) ||
        !await e.verifySignature() ||
        !await e.certificate.verify()) {
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
      contentHash: r.contentHash,
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
  /// report: the first counts (§21.4).
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
        hash: r.contentHash,
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

  /// An appeal to the top against a decision (§21.4): [reportId] is the id
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

  // ---- crisis over Bluetooth (§28.1) ----

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
    if (r == null || r.type != PyrT.alarm || _crisisSeen.contains(r.id)) {
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
    if (py != null && r.pyramid == py) {
      if (_records.containsKey(r.id)) {
        valid = state?.alarms.any((PyrAlarm a) => a.id == r.id) ?? false;
      } else {
        // Would it count? A trial fold, before anything is kept.
        final PyramidState trial = PyramidState.fold(
          py,
          <PyramidRecord>[..._records.values, r],
          now: max(nowMs, r.at),
          treasurerSigs: _tsigs,
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
      PyramidTypes.wantAll,
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
          for (int i = 0; i < out.length; i += 40) {
            await _send(from, <String, dynamic>{
              'type': PyramidTypes.records,
              'rs': out.sublist(i, min(i + 40, out.length)),
            });
          }
        }
      case PyramidTypes.wantAll:
        final Object? py = p['py'];
        if (py is String && knownPyramids.contains(py)) {
          await sendAll(from, py);
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
      case PyramidTypes.fxKey:
        await _onFxKey(p);
      case PyramidTypes.sum:
        await _onSums(from, p);
    }
  }

  Future<void> _onHello(String from, Map<String, dynamic> p) async {
    final Object? list = p['py'];
    if (list is! List) {
      return;
    }
    final Set<String> theirs = <String>{};
    final Set<String> mine = knownPyramids.toSet();
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
    await _followMerge();
  }

  /// When this person's pyramid has joined another as a branch, gets that
  /// one from a friend who keeps it (members of the old top already have
  /// it; the rest learn it this way).
  Future<void> _followMerge() async {
    final String? into = state?.mergedInto;
    if (into == null || knownPyramids.contains(into)) {
      return;
    }
    _followPyramid(into);
    for (final MapEntry<String, Set<String>> e in _peers.entries) {
      if (e.value.contains(into)) {
        await _send(e.key, <String, dynamic>{
          'type': PyramidTypes.wantAll,
          'py': into,
        });
        return;
      }
    }
  }

  Future<void> _onIds(String from, Map<String, dynamic> p) async {
    final Object? ids = p['ids'];
    if (ids is! List || p['py'] is! String || !_follow.containsKey(p['py'])) {
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
    for (int i = 0; i < extra.length; i += 40) {
      await _send(from, <String, dynamic>{
        'type': PyramidTypes.records,
        'rs': extra.sublist(i, min(i + 40, extra.length)),
      });
    }
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
    if (_now() - all.at > kPyrMaxSkewMs) {
      // Enough signatures, but too late for this time: a fresh copy, which
      // those who signed sign again without being asked.
      await _redate(all, need: need, alsoTo: from, manual: false);
      return;
    }
    await ingest(all);
    // The head published an admission: the newcomer gets the pyramid.
    if (all.type == PyrT.admit && all.str('head') == myKey) {
      final Object? m = all.body['m'];
      final String addr =
          m is Map && m['addr'] is String && (m['addr'] as String).isNotEmpty
          ? m['addr'] as String
          : from;
      await sendAll(addr, all.pyramid);
    }
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
    if (r == null ||
        need is! int ||
        me == null ||
        !r.candidates.contains(me) ||
        r.sigs.containsKey(me)) {
      return;
    }
    final int nowMs = _now();
    // Never anything dated ahead (it would wait as a time bomb).
    if (r.at > nowMs + kPyrMaxSkewMs) {
      return;
    }
    // From a friend, a member who signed it, or a merge asking this person
    // to take a branch in — not from anybody at all.
    if (!host.isFriend(from) &&
        !_fromSigner(from, r) &&
        !(r.type == PyrT.merge && r.pyramid == current)) {
      return;
    }
    if (!await r.verifySigners() ||
        proposals.containsKey(r.id) ||
        _records.containsKey(r.id)) {
      return;
    }
    // A fresh copy of something this person already signed: signed again
    // without asking (the content is the same, only the time is now).
    final int? agreed = _consent[_contentKey(r)];
    if (agreed != null && agreed > nowMs && nowMs - r.at <= kPyrMaxSkewMs) {
      await _cosign(r, need.clamp(1, 20), from);
      return;
    }
    final Map<String, dynamic> extra = p['x'] is Map
        ? Map<String, dynamic>.from(p['x'] as Map)
        : <String, dynamic>{};
    // Admission only for friends (met in person, §20.2).
    if (r.type == PyrT.admit && !host.isFriend(from)) {
      return;
    }
    if (r.type == PyrT.admit) {
      final Object? by = extra['by'];
      final Object? g = extra['g'];
      final Object? salt = extra['salt'];
      final Object? m = r.body['m'];
      if (by is! int ||
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

  /// Proposals kept for this person: at most [kPyrProposalsPerSender]
  /// from one device, [kPyrProposalsTotal] in all and
  /// [kPyrProposalsBytes] together (a merge brings a big one); the oldest
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
      PyrT.admit => t('Przyjęcie do komórki: {name}', {
        'name': (r.body['m'] as Map?)?['n'] ?? '?',
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
      PyrT.merge =>
        r.body['rate'] is Map
            ? t('Połączenie piramid (z przeliczeniem pieniędzy)')
            : t('Połączenie piramid'),
      PyrT.merged => t('Ta piramida staje się gałęzią innej'),
      PyrT.fxRate => t('Kurs wymiany'),
      PyrT.natPin =>
        r.body['on'] == false
            ? t('Odpięcie posta w sekcji krajowej')
            : t('Przypięcie posta w sekcji krajowej'),
      PyrT.badge =>
        r.body['off'] == true
            ? t('Ukrycie odznaki wieku i płci')
            : t('Odznaka wieku i płci'),
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
  /// referendum's kind, reach, end and new rules, where a pyramid goes.
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
          if (cond['hl'] is String) {
            out.add(t('Wymiana między piramidami: przyjęcie tylko z kluczem'));
          }
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
        final Object? acts = r.body['acts'];
        out.add(
          acts is List
              ? t('Delegacja {id} · znane akty: {count}', {
                  'id': _short(r.str('d')),
                  'count': acts.length,
                })
              : t('Delegacja {id}', {'id': _short(r.str('d'))}),
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
            t('Rodzaj: {kind} · zasięg: {scope}', {
              'kind': r.str('kind').isEmpty ? 'normal' : r.str('kind'),
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
        final Object? params = r.body['params'];
        if (params is Map && r.str('kind') == 'emit') {
          out.add(
            t('Emisja ponad limit: {amount} dla {name}', {
              'amount': formatMoney(
                params['amount'] is int ? params['amount'] as int : 0,
              ),
              'name': name(params['to']),
            }),
          );
        } else if (params is Map) {
          out.add(t('Nowe zasady: {params}', {'params': jsonEncode(params)}));
        }
      case PyrT.constitution:
        out.add(
          t('Referendum: {question}', {
            'question':
                s?.referenda[r.str('ref')]?.question ?? _short(r.str('ref')),
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
        if (r.str('ref').isNotEmpty) {
          out.add(
            t('Ponad limit, po referendum: {question}', {
              'question':
                  s?.referenda[r.str('ref')]?.question ?? _short(r.str('ref')),
            }),
          );
        }
      case PyrT.alarm:
        out.add(
          t('Zasięg: {scope} · ważne do {time}', {
            'scope': scope(r.body['scope']),
            'time': _when(r.integer('until')),
          }),
        );
      case PyrT.merge:
        out.add(
          t('Piramida {id} dołącza pod {name} · osób: {count}', {
            'id': _short(r.str('from')),
            'name': name(r.str('under')),
            'count': r.body['snap'] is List
                ? (r.body['snap'] as List).length
                : 0,
          }),
        );
        final Object? rate = r.body['rate'];
        int total = 0;
        for (final Object? e
            in r.body['snap'] is List
                ? r.body['snap'] as List
                : const <Object?>[]) {
          if (e is Map && e['bal'] is int) {
            total = pyrAdd(total, e['bal'] as int);
          }
        }
        if (total > 0) {
          // No rate in the record: 1:1.
          final int numer = rate is Map && rate['n'] is int
              ? rate['n'] as int
              : 1;
          final int denom = rate is Map && rate['d'] is int
              ? rate['d'] as int
              : 1;
          out.add(
            t(
              'Pieniądze przechodzą: {amount} po kursie {numer}:{denom} ≈ '
              '{converted} tutaj (jak emisja: limit 30 dni, czeka, można '
              'zawetować)',
              {
                'amount': formatMoney(total),
                'numer': numer,
                'denom': denom,
                'converted': formatMoney(pyrConvert(total, numer, denom)),
              },
            ),
          );
          final String from = r.str('from');
          final PyramidState? old = knownPyramids.contains(from)
              ? _foldUpTo(from, r.integer('cut'))
              : null;
          if (old == null) {
            out.add(
              t('Salda nie sprawdzone: ten telefon nie zna tej piramidy.'),
            );
          } else {
            int real = 0;
            for (final int v in _moneyOf(old).values) {
              real = pyrAdd(real, v);
            }
            out.add(
              real == total
                  ? t('Salda zgadzają się z tym, co widzi ten telefon.')
                  : t('Uwaga: ten telefon widzi inne salda ({amount}).', {
                      'amount': formatMoney(real),
                    }),
            );
          }
        }
      case PyrT.merged:
        out.add(
          t('Staje się gałęzią piramidy {id}', {'id': _short(r.str('into'))}),
        );
        if (r.body['cut'] is int) {
          out.add(
            t('Przelewy po {time} już się tu nie liczą (pieniądze przeszły).', {
              'time': _when(r.integer('cut')),
            }),
          );
        }
      case PyrT.fxRate:
        out.add(
          r.integer('n') == 0
              ? t('Wycofanie kursu')
              : t('Za {amount} z innej piramidy wypłaca tu {payout}', {
                  'amount': formatMoney(r.integer('d')),
                  'payout': formatMoney(r.integer('n')),
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
    final List<String> up = s.lineUp(me);
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
    for (final PyrPost p in s.posts.values) {
      if (p.author != me &&
          (up.contains(p.author)) &&
          nowMs - p.at < 7 * 24 * 3600 * 1000) {
        await tell(
          'post-${p.id}',
          t('Poziom {level}: {name}', {
            'level': p.level,
            'name': s.members[p.author]?.name ?? '',
          }),
          p.text,
        );
      }
    }
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
      // Money converted at a merge comes in parts: one notice for all.
      final String id = e.group ?? e.id;
      if (!e.done && !e.vetoed && e.vetoers.contains(me)) {
        await tell(
          'emit-$id',
          e.group == null
              ? t('Emisja czeka 24 h')
              : t('Przeliczenie po połączeniu'),
          e.group == null
              ? t('{amount} — możesz zawetować.', {
                  'amount': formatMoney(e.amount),
                })
              : t('Pieniądze dołączonej piramidy czekają — możesz zawetować.'),
        );
      } else if (seenLate(id) && canVeto(e)) {
        // It reached this phone after its own time: maybe back-dated past
        // the veto window. The veto is still possible (§23.4).
        await tell(
          'emit-late-$id',
          t('Emisja dotarła z opóźnieniem'),
          e.group == null
              ? t(
                  '{amount} dla {name} — możliwe antydatowanie. Możesz ją '
                  'zawetować.',
                  {
                    'amount': formatMoney(e.amount),
                    'name': s.members[e.to]?.name ?? '?',
                  },
                )
              : t(
                  'Przeliczenie pieniędzy po połączeniu — możliwe '
                  'antydatowanie. Możesz je zawetować.',
                ),
          cat: RuntimeSystemNotificationCategory.alarm,
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

  /// Periodic work (every few minutes): counting, escalating reports,
  /// saying hello, a sign of life.
  Future<void> duties() async {
    await _countDuties();
    final PyramidState? s = state;
    final String? me = myKey;
    if (s == null || me == null) {
      return;
    }
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
    await _fxDuties();
    await _retryHeld();
    await _sumDuties(s, me);
    // A report without a decision climbs one step every
    // [PyrParams.reportEscalateHours]: the next wider branch's delegates,
    // at last the top (§21.4).
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
        host.ownAddress().isNotEmpty) {
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
}

/// 12345 → "123,45" (thousands grouped with a non-breaking space).
String formatMoney(int hundredths) => pyrMoney(hundredths);

/// Hash of content to ban (§21.1).
String contentHash(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();
