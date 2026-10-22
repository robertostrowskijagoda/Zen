import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show immutable, listEquals, visibleForTesting;
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/crypto/hybrid_signature_core.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';

/// A referendum only advises the top (which decides), so it may be
/// short — but never so short that it closes before anyone could see it.
const int kPyrMinReferendumMs = 2 * 60 * 1000;

/// A referendum asks 2 to this many options.
const int kPyrMaxReferendumOptions = 6;

/// After a referendum ends, a cell head waits this long for the sum of a
/// branch below before counting without it.
const int kPyrTallyGraceMs = 6 * 3600 * 1000;

/// New rules signed by the top ([PyrT.constitution]) apply this long after
/// the record, so everybody sees them coming.
const int kPyrParamsDelayMs = 24 * 3600 * 1000;

/// The emission limit counts the emissions of this rolling window,
/// whatever happens to terms in it.
const int kPyrEmitWindowMs = 30 * 24 * 3600 * 1000;

/// The largest amount one record may move or emit, in hundredths
/// (10 bilionów, 10^13 points): far below the 64-bit limit, so no sum of
/// amounts can wrap around, whatever a record claims.
const int kPyrMaxAmount = 1000000000000000;

/// The most an account can hold (2^60 hundredths). Credits stop there
/// instead of wrapping around to a negative balance.
const int kPyrMaxBalance = 1 << 60;

/// [a] + [b] for amounts, never past [kPyrMaxBalance] (and never wrapping:
/// both are at most that, so the sum fits in 64 bits).
int pyrAdd(int a, int b) {
  final int x = a.clamp(0, kPyrMaxBalance);
  final int y = b.clamp(0, kPyrMaxBalance);
  return min(kPyrMaxBalance, x + y);
}

/// 12345 → "123,45": money for people in the app's language (in Polish
/// thousands grouped with a non-breaking space; "123.45" in English).
String pyrMoney(int hundredths) => ZenFormat.money(hundredths);

/// From this many records a whole fold runs in a background isolate.
const int kPyrBackgroundFoldRecords = 1500;

/// [PyramidState.fold] in a background isolate, in the app's language (the
/// texts of the history are written while folding).
Future<PyramidState> pyrFoldInBackground(
  String pyramidId,
  List<PyramidRecord> records, {
  required int now,
  Map<String, int> late = const <String, int>{},
}) {
  final (String, Map<String, Object?>) texts = ZenI18n.snapshot;
  return Isolate.run(() {
    ZenI18n.adopt(texts);
    return PyramidState.fold(pyramidId, records, now: now, late: late);
  });
}

/// The public commitment to a member's birth year and gender:
/// the year is published in the member data too, the gender only as this
/// hash; the member may open it later (a gender badge).
String pyrDataCommit(int birthYear, String gender, String salt) =>
    sha256Hex(utf8.encode('zen-pyr-data|$birthYear|$gender|$salt'));

/// The earliest birth year the pyramid takes.
const int kPyrMinBirthYear = 1900;

/// Whether [year] is a plausible birth year at [atMs]: from
/// [kPyrMinBirthYear] to that year itself. Age is never a condition —
/// minors of any age are admitted.
bool pyrBirthYearValid(int year, int atMs) =>
    year >= kPyrMinBirthYear &&
    year <= DateTime.fromMillisecondsSinceEpoch(atMs, isUtc: true).year;

/// The age of someone born in [birthYear] at [atMs] (by the year only).
int pyrAge(int birthYear, int atMs) =>
    DateTime.fromMillisecondsSinceEpoch(atMs).year - birthYear;

/// A new member votes in their cell and in referenda this long after
/// joining — or as soon as somebody of their cell confirms that they know
/// each other ([PyrT.known]).
const int kPyrVoteAfterMs = 14 * 24 * 3600 * 1000;

/// Somebody who moved up a level moves up again at the earliest this long
/// after: a swap, a vote, taking a free place above or moving into a cell
/// one level higher — never more than one level at a time.
const int kPyrRiseCooldownMs = 7 * 24 * 3600 * 1000;

/// A change of the emission limit that lets more money out (a higher
/// limit, a shorter wait before an emission counts) is announced to
/// everybody and applies this long after ([PyrT.emitRule]); a lower one
/// applies at once.
const int kPyrEmitChangeWaitMs = 30 * 24 * 3600 * 1000;

/// Payments one member may order per day: by default, and the hard
/// bounds the top sets it within ([PyrT.emitRule], like the emission
/// limit: higher only 30 days after it is announced).
const int kPyrDefaultXfers = 30;
const int kPyrMinXfers = 5;
const int kPyrMaxXfers = 200;

/// A day.
const int kPyrDayMs = 24 * 3600 * 1000;

/// The wait before an emission counts, during which the rest of the top
/// may veto it: never shorter than a day.
const int kPyrMinEmitDelayHours = 24;
const int kPyrMaxEmitDelayHours = 24 * 30;

/// After a new head takes the top, the old power key has this long to
/// sign the handover; from then on most of the top cell may sign it
/// instead ([PyrT.handover]).
const int kPyrHandoverWaitMs = 72 * 3600 * 1000;

/// The rules in numbers. Changed by the top, 2 of 3, with a signed
/// record ([PyrT.constitution]) that applies [kPyrParamsDelayMs] later —
/// never past the hard limits in [apply]. The emission limit and its
/// wait are not among them: they change only by [PyrT.emitRule].
final class PyrParams {
  PyrParams({
    this.version = 1,
    this.absenceDays = 60,
    this.immunityDepth = 3,
    this.treasurerDepth = 3,
    this.emitLimit = 100000000,
    this.emitDelayHours = 24,
    this.xferLimit = kPyrDefaultXfers,
    this.electionHours = 72,
    this.reportEscalateHours = 48,
  });

  int version;

  int absenceDays;

  /// Members above this depth need their own cell's consent to be banned.
  int immunityDepth;

  /// Positions up to this depth are the treasurers: 3 → 15 people.
  int treasurerDepth;

  /// Emission allowed per 30 days ([kPyrEmitWindowMs]), in hundredths.
  /// Only [PyrT.emitRule] changes it (and [emitDelayHours]): lower at
  /// once, higher 30 days after it is announced.
  int emitLimit;
  int emitDelayHours;

  /// Payments one member may order per day ([kPyrDayMs]): the private
  /// treasurers' work stays bounded. Changes like the emission limit.
  int xferLimit;
  int electionHours;
  int reportEscalateHours;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'absenceDays': absenceDays,
    'immunityDepth': immunityDepth,
    'treasurerDepth': treasurerDepth,
    'emitLimit': emitLimit,
    'emitDelayHours': emitDelayHours,
    'xferLimit': xferLimit,
    'electionHours': electionHours,
    'reportEscalateHours': reportEscalateHours,
  };

  /// The fields only [PyrT.emitRule] changes (and the genesis sets).
  static const Set<String> emissionFields = <String>{
    'emitLimit',
    'emitDelayHours',
    'xferLimit',
  };

  /// Takes the fields of [json] it knows, each clamped to its hard
  /// limits, whatever the top signs ([version] only counts the changes).
  /// The emission fields only with [emission] (the genesis; the top
  /// changes them by [PyrT.emitRule]).
  void apply(Object? json, {bool emission = false}) {
    if (json is! Map) {
      return;
    }
    int v(String k, int old, int lo, int hi) =>
        json[k] is int ? (json[k] as int).clamp(lo, hi) : old;
    absenceDays = v('absenceDays', absenceDays, 30, 3650);
    immunityDepth = v('immunityDepth', immunityDepth, 1, 30);
    treasurerDepth = v('treasurerDepth', treasurerDepth, 3, 6);
    if (emission) {
      emitLimit = v('emitLimit', emitLimit, 0, kPyrMaxAmount);
      emitDelayHours = v(
        'emitDelayHours',
        emitDelayHours,
        kPyrMinEmitDelayHours,
        kPyrMaxEmitDelayHours,
      );
      xferLimit = v('xferLimit', xferLimit, kPyrMinXfers, kPyrMaxXfers);
    }
    electionHours = v('electionHours', electionHours, 24, 24 * 30);
    reportEscalateHours = v(
      'reportEscalateHours',
      reportEscalateHours,
      24,
      24 * 30,
    );
  }
}

/// Someone in the pyramid, under their pyramid pseudonym.
final class PyrMember {
  PyrMember({
    required this.key,
    required this.name,
    required this.nat,
    required this.birthYear,
    required this.dataCommit,
    required this.joinedAt,
    required this.pq,
    this.admittedBy,
    this.addr = '',
    this.founder = false,
  });

  final String key;

  /// Fingerprint of the ML-DSA half of [key], fixed at entry by the
  /// admission everyone signed: a signature of this member that carries
  /// another ML-DSA key does not count (a forged Ed25519 half).
  final String pq;
  final String name;

  /// Nationality, confirmed at entry by the one who admitted.
  final String nat;

  /// Birth year, confirmed at entry by the one who admitted:
  /// public to the pyramid, so the age shows in the member's profile.
  final int birthYear;

  /// Hash of birth year + gender + salt: the gender itself is not public.
  final String dataCommit;
  final int joinedAt;

  /// Who vouched for them (the sponsor of the admission).
  final String? admittedBy;

  /// The first head, seated by the power key of the genesis: votes
  /// from the start.
  final bool founder;

  /// Device address for pyramid traffic (votes, payments, reports).
  String addr;

  /// The member's public hybrid KEM key ([PyrT.sealKey], base64url):
  /// what private payments, receipts and statements are sealed to.
  String kem = '';

  /// Every device address the member ever had (what they signed): a
  /// verdict shows on the profile at each, so a new address hides nothing.
  final Set<String> addrs = <String>{};
  bool active = true;
}

/// A cell's request cards ([PyrT.roster]): one-time hybrid keys of its
/// voters for one head, nobody's identity; an anonymous request for a vote
/// is signed by one of them.
final class PyrRoster {
  PyrRoster({
    required this.id,
    required this.cell,
    required this.head,
    required this.ring,
    required this.tokens,
  });

  /// The roster record that counted.
  final String id;
  final String cell;
  final String head;

  /// The cell's voters it is for (sorted).
  final List<String> ring;

  /// Card (Ed25519 id) → fingerprint of its ML-DSA key.
  final Map<String, String> tokens;

  /// The scope its cards are made for ([PyramidState.rosterScope]).
  String scope(String pyramid) =>
      PyramidState.rosterScope(pyramid, cell, head, ring);
}

final class PyrElection {
  PyrElection({
    required this.id,
    required this.cell,
    required this.head,
    required this.ring,
    required this.deadline,
    this.start = 0,
  });

  final String id;
  final String cell;
  final String head;

  /// Who votes: the cell as it was when the vote was asked for (someone
  /// who joins the cell during the vote does not vote in it).
  final List<String> ring;
  final int deadline;

  /// When the vote was asked for: no vote may be dated before.
  final int start;

  /// The voting cards ([PyrT.ballot]): one-time key (Ed25519 id) → the
  /// fingerprint of its ML-DSA key; null until the cell signed them.
  Map<String, String>? tokens;

  /// The ballot record that counted.
  String? ballot;

  /// One-time key → the member it voted for (nobody's identity).
  final Map<String, String> votes = <String, String>{};
  bool closed = false;
  String? winner;
}

final class PyrDelegation {
  PyrDelegation({
    required this.id,
    required this.issuer,
    required this.to,
    required this.power,
    required this.scope,
    required this.limit,
    required this.until,
    required this.sub,
    this.parent,
    this.at = 0,
  });

  final String id;
  final List<String> issuer;
  final String to;
  final String power;

  /// Branch root path ('' = whole pyramid).
  final String scope;

  /// Uses per 30 days (0 = no limit). Uses through a delegation passed on
  /// count here too, so passing it on never multiplies it.
  final int limit;
  final int until;

  /// May be delegated further.
  final bool sub;
  final String? parent;

  /// When it was issued.
  final int at;
  bool revoked = false;
  final List<int> uses = <int>[];

  /// Records done with it (id → time), so a revocation can say which of
  /// them it knew about.
  final Map<String, int> acts = <String, int>{};

  /// Once revoked: the acts done with it (or with one passed on from it)
  /// that the revocation listed. Of the acts dated before the revocation
  /// only these count.
  Set<String> knownAtRevocation = const <String>{};
}

final class PyrBan {
  PyrBan({
    required this.id,
    required this.target,
    required this.kind,
    required this.at,
    this.until,
    this.datingKey,
    this.reason = '',
    this.entryId,
    this.rep,
  });

  final String id;
  final String target;

  /// The report whose decision gave it: appealing it appeals that
  /// decision (every ban it gave is lifted with it).
  final String? rep;

  /// perm, pause, content, noadmit, dating.
  final String kind;
  final int at;
  final int? until;
  final String? datingKey;
  final String reason;

  /// Id of the banned entry itself — a signed post, a comment, a message:
  /// the entry is banned whatever its text.
  final String? entryId;
  bool lifted = false;

  bool activeAt(int t) => !lifted && (until == null || t < until!);
}

final class PyrPost {
  PyrPost({
    required this.id,
    required this.author,
    required this.text,
    required this.level,
    required this.at,
    this.nat,
    this.toAll = false,
    this.via,
  });

  final String id;
  final String author;
  final String text;

  /// The author's level when it was written.
  final int level;
  final int at;
  final String? nat;

  /// Written to the whole pyramid: by the head (level 0), or by somebody
  /// the head let do it ([via]: the delegation of power `posts`).
  final bool toAll;
  final String? via;
  final List<PyrComment> comments = <PyrComment>[];

  /// To the whole pyramid (the head's, or with the head's delegation).
  bool get toWhole => nat == null && (level == 0 || toAll);
}

final class PyrComment {
  PyrComment({
    required this.id,
    required this.author,
    required this.text,
    required this.at,
    this.media = const <Map<String, dynamic>>[],
  });

  final String id;
  final String author;
  final String text;
  final int at;

  /// Photos and GIFs in the comment: references of sealed files in the
  /// writer's blob store (`post_media.dart`, `{id, k, n, mime}`), fetched
  /// from the writer's device. At most [kMaxPyrCommentMedia].
  final List<Map<String, dynamic>> media;
}

/// Most pictures in one pyramid comment.
const int kMaxPyrCommentMedia = 4;

/// The picture references of a comment record's `img`: well-formed ones
/// only (an id and a key and nonce as strings, an image type), at most
/// [kMaxPyrCommentMedia].
List<Map<String, dynamic>> pyrCommentMedia(Object? img) =>
    <Map<String, dynamic>>[
      if (img is List)
        for (final Object? m in img.take(kMaxPyrCommentMedia))
          if (m is Map &&
              m['id'] is String &&
              (m['id'] as String).isNotEmpty &&
              (m['id'] as String).length <= 128 &&
              m['k'] is String &&
              (m['k'] as String).length <= 64 &&
              m['n'] is String &&
              (m['n'] as String).length <= 32 &&
              m['mime'] is String &&
              (m['mime'] as String).startsWith('image/') &&
              (m['mime'] as String).length <= 40)
            <String, dynamic>{
              'id': m['id'],
              'k': m['k'],
              'n': m['n'],
              'mime': m['mime'],
            },
    ];

final class PyrReferendum {
  PyrReferendum({
    required this.id,
    required this.question,
    required this.options,
    required this.scopeKind,
    required this.scopePath,
    required this.scopeNat,
    required this.end,
    required this.at,
  });

  final String id;

  /// Any question the top asks; the result only advises the top.
  final String question;
  final List<String> options;

  /// all, branch, nat.
  final String scopeKind;
  final String scopePath;
  final String scopeNat;
  final int end;
  final int at;

  /// Latest tally per publisher.
  final Map<String, PyrTally> tallies = <String, PyrTally>{};
}

final class PyrTally {
  PyrTally({
    required this.id,
    required this.publisher,
    required this.path,
    required this.counts,
    required this.at,
    this.kids = const <String>[],
  });

  final String id;
  final String publisher;
  final String path;
  final List<int> counts;
  final int at;

  /// The sums of the branches below that this one includes.
  final List<String> kids;

  int get total => counts.fold(0, (int a, int b) => a + b);
}

final class PyrEmission {
  PyrEmission({
    required this.id,
    required this.rc,
    required this.amount,
    required this.term,
    required this.at,
    required this.signedAt,
    required this.effectiveAt,
    required this.signers,
    this.vetoers = const <String>[],
  });

  final String id;

  /// Who gets it, only as a commitment ([pyrEmitCommit]): the recipient
  /// and the reason go sealed to the treasurers ([PyrEmitNote]).
  final String rc;
  final int amount;
  final int term;

  /// When it counts from: its own time, or when this phone first saw it
  /// when it came late ([kPyrLateMs]).
  final int at;

  /// The time it is signed with.
  final int signedAt;
  final int effectiveAt;
  final List<String> signers;

  /// The veto time as its own time sets it: a veto dated in it counts on
  /// every phone, also on one that saw the emission late.
  int get signedEnd => signedAt + (effectiveAt - at);

  /// Who may veto it: the rest of the top when it was signed. They
  /// keep the right for the whole wait, even if moved away meanwhile.
  final List<String> vetoers;
  bool vetoed = false;
  bool done = false;
}

/// New rules the top signed ([PyrT.constitution]): public at once,
/// applied at [effectiveAt].
final class PyrParamsChange {
  PyrParamsChange({
    required this.id,
    required this.params,
    required this.at,
    required this.effectiveAt,
  });

  final String id;

  /// The fields that change (the rest stays).
  final Map<String, dynamic> params;
  final int at;
  final int effectiveAt;
  bool done = false;
}

/// Levels of acquaintance a price can depend on, from the receiver's
/// point of view.
Map<String, String> get kPriceLevels => <String, String>{
  'friend': t('Znajomi'),
  'fof': t('Znajomi znajomych'),
  'stranger': t('Obcy'),
};

final class PyrAlarm {
  PyrAlarm({
    required this.id,
    required this.text,
    required this.scopeKind,
    required this.scopePath,
    required this.scopeNat,
    required this.at,
    required this.until,
    required this.by,
  });

  final String id;
  final String text;
  final String scopeKind;
  final String scopePath;
  final String scopeNat;
  final int at;
  final int until;
  final String by;
}

/// One change of somebody's place, as the fold made it: [key] is at
/// [path] from [at] on (null: out of the pyramid), because of record (or
/// vote) [cause]. What every member can work out from the records; the
/// animated history replays them ([PyrTimeline]).
@immutable
final class PyrMove {
  const PyrMove(this.at, this.cause, this.key, this.path);

  final int at;
  final String cause;
  final String key;
  final String? path;
}

/// One structural change, for the public history.
final class PyrHistory {
  PyrHistory(this.at, this.text, this.recordId);

  final int at;
  final String text;
  final String recordId;
}

/// The pyramid as it follows from its records: every client folds
/// the same records into the same state, so nothing has to be trusted but
/// signatures.
final class PyramidState {
  PyramidState._(this.id);

  final String id;
  String name = '';
  final PyrParams params = PyrParams();

  /// Position path → occupant key.
  final Map<String, String> occupant = <String, String>{};

  /// Key → position path.
  final Map<String, String> position = <String, String>{};

  /// Positions without anybody, whose branch below is still there.
  final Set<String> vacant = <String>{};
  final Map<String, PyrMember> members = <String, PyrMember>{};
  final Map<String, int> lastSeen = <String, int>{};

  /// Levels each key had, with since when (posts claim the level their
  /// author saw, which may lag a just-finished swap).
  final Map<String, List<List<int>>> _levels = <String, List<List<int>>>{};
  final Map<String, PyrElection> elections = <String, PyrElection>{};

  /// Anonymous vote requests per cell and request card (harassment
  /// counter: one card is one member, nobody knows whom).
  final Map<String, Map<String, int>> requestCounts =
      <String, Map<String, int>>{};

  /// The request cards of each cell ([PyrT.roster]), for its present head
  /// and voters.
  final Map<String, PyrRoster> rosters = <String, PyrRoster>{};
  final Map<String, PyrDelegation> delegations = <String, PyrDelegation>{};
  final Map<String, PyrBan> bans = <String, PyrBan>{};
  final Map<String, String> decisions = <String, String>{};
  final Map<String, PyrPost> posts = <String, PyrPost>{};
  final Map<String, PyrPost> natPosts = <String, PyrPost>{};

  /// nationality → (key → until): who may post with priority.
  final Map<String, Map<String, int>> natGrants = <String, Map<String, int>>{};

  /// nationality → pinned post → when pinned: the section's lead
  /// pins at most [maxNatPins]; the oldest pin goes first.
  final Map<String, Map<String, int>> natPins = <String, Map<String, int>>{};

  /// Gender badges members show themselves: key → gender,
  /// checked against the data they were admitted with.
  final Map<String, String> badges = <String, String>{};
  final Map<String, PyrReferendum> referenda = <String, PyrReferendum>{};

  /// Changes of the rules, waiting or applied ([PyrParamsChange]).
  final Map<String, PyrParamsChange> paramsChanges =
      <String, PyrParamsChange>{};

  /// Member → the members of their cell who confirmed knowing them
  /// ([PyrT.known]) → when.
  final Map<String, Map<String, int>> knownBy = <String, Map<String, int>>{};

  /// Changes of the emission limit, applied, waiting or cancelled
  /// ([PyrT.emitRule]).
  final Map<String, PyrEmitChange> emitChanges = <String, PyrEmitChange>{};

  /// What can be appealed, by the id of the decision ([PyrMatter]).
  final Map<String, PyrMatter> matters = <String, PyrMatter>{};
  final Map<String, PyrAppeal> appeals = <String, PyrAppeal>{};

  /// Complaints and verdicts of the court.
  final Map<String, PyrCase> cases = <String, PyrCase>{};
  final Map<String, PyrVerdict> verdicts = <String, PyrVerdict>{};

  /// Reports whose decision was overturned on appeal.
  final Set<String> overturnedReports = <String>{};

  /// When each member last moved up a level ([kPyrRiseCooldownMs]).
  final Map<String, int> lastRise = <String, int>{};

  /// The level each former member left from: they come back no higher.
  final Map<String, int> leftLevel = <String, int>{};

  /// The power key now (public), from the genesis on: it certifies that
  /// this is the original pyramid and who its heads were — nothing more.
  String? powerKey;

  /// Fingerprint of the power key's ML-DSA half: from the genesis (`pq`;
  /// the test pyramid's genesis has none) and from each handover (`tpq`).
  String? powerKeyPq;

  /// The head the power key was last given to ([PyrT.found],
  /// [PyrT.handover]); a new head at the top waits for a handover.
  String? powerHead;

  /// Every power key there was (none comes back).
  final Set<String> usedPowerKeys = <String>{};

  /// Since when the head of the pyramid holds the top.
  int headSince = 0;
  String? _headKey;
  int term = 1;
  final Map<int, int> termStart = <int, int>{1: 0};
  final Map<int, int> emittedInTerm = <int, int>{};
  final Map<String, PyrEmission> emissions = <String, PyrEmission>{};

  /// The treasurers through time: from when each set holds (the oldest
  /// first). Payments are private (`pyramid_ledger.dart`): a payment
  /// counts with the signatures of most of the treasurers of its time.
  final List<(int, List<String>)> treasurerEras = <(int, List<String>)>[];
  bool _treasurersDirty = true;
  final List<PyrAlarm> alarms = <PyrAlarm>[];

  /// Member → kind → price (the highest of its levels, when it has
  /// levels: what somebody pays who cannot tell how well they know them).
  final Map<String, Map<String, int>> offers = <String, Map<String, int>>{};

  /// Member → kind → level ([kPriceLevels]) → price, for the kinds priced
  /// by acquaintance.
  final Map<String, Map<String, Map<String, int>>> offerLevels =
      <String, Map<String, Map<String, int>>>{};

  final List<PyrHistory> history = <PyrHistory>[];

  /// Every change of a place, in the order of the fold ([PyrMove]).
  final List<PyrMove> moves = <PyrMove>[];

  /// The record (or vote) whose rule runs now, and its time: what a move
  /// is noted with.
  String _cause = '';
  int _causeAt = 0;

  /// Records that did not count, with the reason (for the curious and the
  /// simulator).
  final Map<String, String> rejected = <String, String>{};
  final Set<String> applied = <String>{};

  /// Delegations revoked in the first pass of [fold] → the acts their
  /// revocation listed. A revocation works from its own time on: what the
  /// delegate did before it stays, but an act dated before it and
  /// not on its list was made up later and does not count (the second
  /// pass runs without it).
  Map<String, Set<String>> _witnessed = const <String, Set<String>>{};

  /// Records refused in this pass as made up after their delegation was
  /// revoked.
  final Set<String> _lateHit = <String>{};

  /// Records refused up front because their rule threw in an earlier round
  /// of the fold (rules 2), and those that threw in this round.
  Set<String> _poison = const <String>{};
  final Set<String> _threw = <String>{};

  /// Who leads each national section, worked out once per shape of the
  /// tree (cleared on every move).
  final Map<String, String?> _natLead = <String, String?>{};

  /// Bumped whenever this state changes in place ([extend], [advanceTo]):
  /// what is worked out from it is worked out again.
  int revision = 0;

  /// The last record applied, and the time it folded at: [extend] takes
  /// only records that come after it.
  PyramidRecord? _lastRecord;
  int _lastAt = 0;

  /// The latest time a change by time (an election's end, an emission,
  /// new rules) happened at: a record dated before it must be folded
  /// from the start.
  int _lastEvent = 0;

  /// Proposals already counted (content without the time): a fresh copy
  /// of one, signed again late, counts once.
  final Set<String> _proposalsDone = <String>{};

  // ---- reading ----

  String? get head => occupant[''];
  List<String> get topCell => <String>[
    for (final String p in <String>['', '0', '1'])
      if (occupant[p] != null) occupant[p]!,
  ];

  /// Who sits at level 2 (the four places under the top cell).
  List<String> get levelTwo => <String>[
    for (final MapEntry<String, String> e in occupant.entries)
      if (e.key.length == 2) e.value,
  ]..sort();

  /// How many of [levelTwo] must agree to remove or ban a member of the
  /// top: most of them (none when nobody sits there).
  int get levelTwoNeed {
    final int n = levelTwo.length;
    return n == 0 ? 0 : n ~/ 2 + 1;
  }

  /// Whether [key] is in the top cell (levels 0–1, the head included):
  /// removed or banned only by 2 of 3 of the top and most of level 2.
  bool inTopCell(String key) {
    final String? p = position[key];
    return p != null && p.length <= 1;
  }

  /// Whether [signers] are enough to remove or ban a member of the top:
  /// 2 of 3 of the top and most of level 2.
  bool _topImmunityHolds(List<String> signers) =>
      _countOf(signers, topCell) >= 2 &&
      _countOf(signers, levelTwo) >= levelTwoNeed;

  bool isMember(String key) => position.containsKey(key);
  String? pathOf(String key) => position[key];
  int? levelOf(String key) => position[key]?.length;

  int get depth =>
      position.values.fold(0, (int a, String p) => max(a, p.length + 1));

  List<String> cellOf(String path) => <String>[
    for (final String p in <String>[path, ...PyrPath.children(path)])
      if (occupant[p] != null) occupant[p]!,
  ];

  /// The cell [key] is a member of (with its head above), for removal and
  /// immunity; for the head of the pyramid, the top cell.
  List<String> ownCellOf(String key) {
    final String? p = position[key];
    if (p == null) {
      return const <String>[];
    }
    if (p.isEmpty) {
      return <String>[
        for (final String c in PyrPath.children(''))
          if (occupant[c] != null) occupant[c]!,
      ];
    }
    return <String>[
      for (final String q in <String>[PyrPath.parent(p), PyrPath.sibling(p)])
        if (occupant[q] != null) occupant[q]!,
    ];
  }

  bool _exists(String path) =>
      occupant.containsKey(path) || vacant.contains(path);

  /// Free child slot under [path] ('0' first), or null.
  String? freeSlot(String path) {
    for (final String c in PyrPath.children(path)) {
      if (!_exists(c)) {
        return c;
      }
    }
    return null;
  }

  /// Free places in the branch of [root] a newcomer can be admitted to
  /// ("Polecenie"): places under somebody, nearest the top first, then
  /// left before right; at most [limit]. Places of a branch whose head is
  /// gone are not among them (somebody below fills those). Walks the tree
  /// level by level, so a huge branch costs only its upper levels.
  List<String> freePlaces(String root, {int limit = 12}) {
    final List<String> out = <String>[];
    if (!_exists(root)) {
      return out;
    }
    List<String> level = <String>[root];
    while (level.isNotEmpty && out.length < limit) {
      final List<String> next = <String>[];
      for (final String p in level) {
        for (final String c in PyrPath.children(p)) {
          if (!_exists(c)) {
            if (occupant[p] != null && out.length < limit) {
              out.add(c);
            }
          } else {
            next.add(c);
          }
        }
      }
      level = next;
    }
    return out;
  }

  /// People in the branch of [path] (with it).
  int branchSize(String path) =>
      position.values.where((String p) => PyrPath.within(p, path)).length;

  int branchNat(String path, String nat) => position.entries
      .where(
        (MapEntry<String, String> e) =>
            PyrPath.within(e.value, path) && members[e.key]?.nat == nat,
      )
      .length;

  /// Keys of the line from [key] up to the top (without [key]).
  List<String> lineUp(String key) {
    final String? p = position[key];
    if (p == null) {
      return const <String>[];
    }
    final List<String> out = <String>[];
    String q = p;
    while (q.isNotEmpty) {
      q = PyrPath.parent(q);
      final String? k = occupant[q];
      if (k != null) {
        out.add(k);
      }
    }
    return out;
  }

  /// The treasurers now.
  List<String> get treasurers => _treasurersNow();

  int get treasurerMajority => treasurers.length ~/ 2 + 1;

  /// The treasurers now: the places down to [PyrParams.treasurerDepth],
  /// walked from the top (a few dozen lookups, however big the pyramid).
  List<String> _treasurersNow() {
    final List<String> out = <String>[];
    List<String> level = <String>[''];
    for (int d = 0; d <= params.treasurerDepth && level.isNotEmpty; d++) {
      final List<String> next = <String>[];
      for (final String p in level) {
        if (!_exists(p)) {
          continue;
        }
        final String? k = occupant[p];
        if (k != null) {
          out.add(k);
        }
        next.addAll(PyrPath.children(p));
      }
      level = next;
    }
    return out..sort();
  }

  /// The treasurers at [at]: those of the era it falls in (the first one
  /// for anything before it).
  List<String> treasurersAt(int at) {
    List<String> out = const <String>[];
    for (final (int from, List<String> set) in treasurerEras) {
      if (from > at && out.isNotEmpty) {
        break;
      }
      out = set;
    }
    return out;
  }

  /// Since when the treasurers now are the treasurers.
  int get treasurerEraStart =>
      treasurerEras.isEmpty ? 0 : treasurerEras.last.$1;

  /// Notes a new era when the tree (or the depth) changed who they are.
  void _noteTreasurers(int at) {
    if (!_treasurersDirty) {
      return;
    }
    _treasurersDirty = false;
    final List<String> now = _treasurersNow();
    if (treasurerEras.isNotEmpty && listEquals(treasurerEras.last.$2, now)) {
      return;
    }
    treasurerEras.add((at, now));
  }

  /// Who leads the national section of [nat], if anybody: the
  /// highest member of [nat] (no minimum number of people anywhere), then
  /// the one with more of [nat] in their branch, then the earlier place.
  /// One pass over the tree (not one per member).
  String? nationalLead(String nat) {
    if (_natLead.containsKey(nat)) {
      return _natLead[nat];
    }
    // How many of [nat] are at or under each place.
    final Map<String, int> counts = <String, int>{};
    for (final MapEntry<String, String> e in position.entries) {
      if (members[e.key]?.nat != nat) {
        continue;
      }
      for (int i = 0; i <= e.value.length; i++) {
        final String q = e.value.substring(0, i);
        counts[q] = (counts[q] ?? 0) + 1;
      }
    }
    String? best;
    String bestPath = '';
    int bestLevel = 1 << 30;
    int bestCount = -1;
    for (final MapEntry<String, String> e in position.entries) {
      if (members[e.key]?.nat != nat) {
        continue;
      }
      final int count = counts[e.value] ?? 0;
      final int level = e.value.length;
      if (level < bestLevel ||
          (level == bestLevel && count > bestCount) ||
          (level == bestLevel &&
              count == bestCount &&
              e.value.compareTo(bestPath) < 0)) {
        best = e.key;
        bestPath = e.value;
        bestLevel = level;
        bestCount = count;
      }
    }
    return _natLead[nat] = best;
  }

  bool bannedAt(String key, String kind, int t) => bans.values.any(
    (PyrBan b) =>
        b.target == key &&
        b.activeAt(t) &&
        (b.kind == kind || b.kind == 'perm'),
  );

  /// Banned from social features (posts, comments) now.
  bool silencedAt(String key, int t) => bans.values.any(
    (PyrBan b) =>
        b.target == key &&
        b.activeAt(t) &&
        (b.kind == 'perm' || b.kind == 'pause'),
  );

  /// Ids of entries (posts, comments, messages) banned now.
  Set<String> bannedEntries(int t) => <String>{
    for (final PyrBan b in bans.values)
      if (b.kind == 'content' && b.entryId != null && b.activeAt(t)) b.entryId!,
  };

  Set<String> bannedDatingKeys(int t) => <String>{
    for (final PyrBan b in bans.values)
      if (b.kind == 'dating' && b.datingKey != null && b.activeAt(t))
        b.datingKey!,
  };

  /// The price [key] asks for [kind] from someone of [level] (null = not
  /// offered, 0 = free). Unknown level → the highest price.
  int? priceFor(String key, String kind, String? level) {
    final Map<String, int>? levels = offerLevels[key]?[kind];
    if (level != null && levels != null && levels[level] != null) {
      return levels[level];
    }
    return offers[key]?[kind];
  }

  /// The newest sum published for the branch at [path] in [r] (by
  /// whoever held that place then).
  PyrTally? latestTally(PyrReferendum r, String path) {
    PyrTally? best;
    for (final PyrTally t in r.tallies.values) {
      if (t.path == path &&
          (best == null ||
              t.at > best.at ||
              (t.at == best.at && t.id.compareTo(best.id) > 0))) {
        best = t;
      }
    }
    return best;
  }

  /// The final count of [refId], once its top has published it. With
  /// [strict], only a count that includes the newest sum of every branch
  /// right under the top (a top that left branches out has not counted).
  List<int>? resultOf(String refId, {bool strict = false}) {
    final PyrReferendum? r = referenda[refId];
    if (r == null) {
      return null;
    }
    final String root = r.scopeKind == 'branch' ? r.scopePath : '';
    final PyrTally? best = latestTally(r, root);
    if (best == null) {
      return null;
    }
    if (strict) {
      // A sum counted by the top once the branches had
      // their time stands; a branch's sum dated after it cannot void it
      // (one slow or stubborn cell would block the count for good).
      final bool timeBound = best.at >= r.end + kPyrTallyGraceMs;
      for (final String c in PyrPath.children(root)) {
        final PyrTally? kid = latestTally(r, c);
        if (kid != null &&
            !best.kids.contains(kid.id) &&
            !(timeBound && kid.at > best.at)) {
          return null;
        }
      }
    }
    return best.counts;
  }

  /// Emission in the [kPyrEmitWindowMs] up to [t] (vetoed ones do not
  /// count).
  int emittedWithin(int t) {
    int sum = 0;
    for (final PyrEmission e in emissions.values) {
      if (!e.vetoed && e.at <= t && e.at > t - kPyrEmitWindowMs) {
        sum = pyrAdd(sum, e.amount);
      }
    }
    return sum;
  }

  /// The applied acts done through delegation [delegationId] or anything
  /// delegated from it: what its revocation lists as known, so they stay.
  Set<String> actsOf(String delegationId) {
    final Set<String> out = <String>{};
    for (final PyrDelegation d in delegations.values) {
      if (_chainOf(d).any((PyrDelegation x) => x.id == delegationId)) {
        out.addAll(d.acts.keys.where(applied.contains));
      }
    }
    return out;
  }

  /// Whether [key] votes — in its cell and in referenda — at [at]: the
  /// founder from the start, anybody else [kPyrVoteAfterMs] after joining
  /// or once somebody of their cell confirmed knowing them ([PyrT.known]).
  /// Fake accounts nobody knows wait two weeks and never outvote a cell
  /// of real people by surprise.
  bool canVote(String key, int at) {
    final PyrMember? m = members[key];
    if (m == null || !position.containsKey(key)) {
      return false;
    }
    if (m.founder || at - m.joinedAt >= kPyrVoteAfterMs) {
      return true;
    }
    return knownBy[key]?.values.any((int t) => t <= at) ?? false;
  }

  /// Who of the pyramid confirmed knowing [key], the earliest first.
  List<String> knownByOf(String key) {
    final Map<String, int> by = knownBy[key] ?? const <String, int>{};
    return by.keys.where(position.containsKey).toList()
      ..sort((String a, String b) => by[a]!.compareTo(by[b]!));
  }

  /// The people [key] shares a cell with: the cell it is a member of (its
  /// head and the other member) and its own cell below.
  List<String> cellmates(String key) {
    final String? p = position[key];
    if (p == null) {
      return const <String>[];
    }
    return <String>{
      ...ownCellOf(key),
      ...cellOf(p),
    }.where((String k) => k != key).toList();
  }

  /// The members of the cell at [cell] who vote at [at] ([canVote]): who
  /// swaps its head and who is in the ring of its vote.
  List<String> cellVoters(String cell, int at) => <String>[
    for (final String k in cellOf(cell))
      if (canVote(k, at)) k,
  ];

  /// Whether the head at the top still waits for the power key.
  bool get handoverDue => head != null && head != powerHead;

  /// Whether [key] votes in [r]: in its scope ([inScope]) and with a vote
  /// at the end of it ([canVote]).
  bool eligible(PyrReferendum r, String key) =>
      inScope(r, key) && canVote(key, r.end);

  /// Whether [r] is for [key] (the whole pyramid, their branch or their
  /// nationality).
  bool inScope(PyrReferendum r, String key) {
    final String? p = position[key];
    if (p == null) {
      return false;
    }
    return switch (r.scopeKind) {
      'branch' => PyrPath.within(p, r.scopePath),
      'nat' => members[key]?.nat == r.scopeNat,
      _ => true,
    };
  }

  // ---- folding ----

  /// Folds [records] (already checked: every listed signer signed).
  /// Payments are not among them: they are private, between the payer,
  /// the one paid and the treasurers (`pyramid_ledger.dart`).
  ///
  /// Records are applied in the order of their own time. Nothing can make
  /// a phone's clock the judge of somebody else's record (that would split
  /// the phones), so the fold adds witnesses where the time matters:
  /// - a revocation works from its time on and lists the acts of the
  ///   delegate it knew about; an act dated before the revocation but not
  ///   on its list was made up later and does not count (a second pass);
  /// - a record of [PyrT.timed] that reached this phone late ([late]: id →
  ///   when this phone first saw it, [kPyrLateMs]) counts from then: new
  ///   rules a day after that, an emission's veto time and its 30-day limit
  ///   from then (a back-dated one skips nothing). A veto of it folds after
  ///   it. A phone that first sees such a record in a full sync (it kept
  ///   nothing newer) takes the record's own time.
  /// A record whose rule throws is skipped, never the whole pyramid; with
  /// rules 2 it leaves no trace either: the fold runs again with it
  /// refused before anything of it was applied.
  static PyramidState fold(
    String pyramidId,
    Iterable<PyramidRecord> records, {
    required int now,
    Map<String, int> late = const <String, int>{},
  }) {
    final List<PyramidRecord> list = <PyramidRecord>[
      for (final PyramidRecord r in records)
        if ((r.id == pyramidId || r.pyramid == pyramidId) &&
            r.at <= now + kPyrMaxSkewMs)
          r,
    ];
    final Map<String, int> times = _foldTimes(list, late);
    list.sort(
      times.isEmpty
          ? _order
          : (PyramidRecord a, PyramidRecord b) =>
                _orderAt(a, times[a.id] ?? a.at, b, times[b.id] ?? b.at),
    );
    PyramidState s = _runClean(
      pyramidId,
      list,
      now,
      const <String, Set<String>>{},
      const <String>{},
      times,
    );
    final Map<String, Set<String>> witnessed = s._witnessIfLate();
    if (witnessed.isNotEmpty) {
      s = _runClean(pyramidId, list, now, witnessed, s._poison, times);
    }
    return s;
  }

  /// The records that fold at another time than their own: those of
  /// [PyrT.timed] seen late ([late]), at when they were seen, and the
  /// vetoes of such an emission, not before it.
  static Map<String, int> _foldTimes(
    List<PyramidRecord> list,
    Map<String, int> late,
  ) {
    if (late.isEmpty) {
      return const <String, int>{};
    }
    final Map<String, int> times = <String, int>{
      for (final PyramidRecord r in list)
        if (late[r.id] case final int seen
            when seen > r.at && PyrT.timed.contains(r.type))
          r.id: seen,
    };
    if (times.isEmpty) {
      return times;
    }
    for (final PyramidRecord r in list) {
      if (r.type == PyrT.veto) {
        final int? of = times[r.str('emit')];
        if (of != null && of > r.at) {
          times[r.id] = of;
        }
      }
    }
    return times;
  }

  /// [_run] until no record throws that was not already refused up front
  /// (rules 2): a record whose rule threw halfway may have changed the
  /// state before throwing, so the fold starts again without it. Every
  /// phone finds the same records, so every phone gets the same state. A
  /// few rounds at most (each round adds at least one record).
  static PyramidState _runClean(
    String pyramidId,
    List<PyramidRecord> list,
    int now,
    Map<String, Set<String>> witnessed,
    Set<String> poison,
    Map<String, int> times,
  ) {
    Set<String> bad = poison;
    int round = 0;
    while (true) {
      final PyramidState s = _run(pyramidId, list, now, witnessed, bad, times);
      if (s._threw.isEmpty || ++round > 8) {
        return s;
      }
      bad = <String>{...bad, ...s._threw};
    }
  }

  /// Tests: runs after each record's rule, inside its guard — throwing
  /// here is a rule that failed halfway, after changing the state.
  @visibleForTesting
  static void Function(PyramidRecord r)? debugAfterApply;

  /// Time, then the genesis, then the founding (an admission made in the
  /// same millisecond needs the founder seated), then the id (ids are
  /// worked out once).
  static int _order(PyramidRecord a, PyramidRecord b) =>
      _orderAt(a, a.at, b, b.at);

  /// [_order] with the times the records fold at ([_foldTimes]); a veto
  /// after anything else of the same time (its emission).
  static int _orderAt(PyramidRecord a, int ta, PyramidRecord b, int tb) {
    final int c = ta.compareTo(tb);
    if (c != 0) {
      return c;
    }
    final int ra = _rank(a.type);
    final int rb = _rank(b.type);
    if (ra != rb) {
      return ra.compareTo(rb);
    }
    return a.id.compareTo(b.id);
  }

  static int _rank(String type) => switch (type) {
    PyrT.genesis => 0,
    PyrT.found => 1,
    PyrT.veto => 3,
    _ => 2,
  };

  static PyramidState _run(
    String pyramidId,
    List<PyramidRecord> list,
    int now,
    Map<String, Set<String>> witnessed,
    Set<String> poison,
    Map<String, int> times,
  ) {
    final PyramidState s = PyramidState._(pyramidId)
      .._witnessed = witnessed
      .._poison = poison
      .._times = times;
    for (final PyramidRecord r in list) {
      s._applyOne(r, times[r.id] ?? r.at);
    }
    s._timedUpTo(now);
    return s;
  }

  /// Applies one record of the fold at [at] (its own time, or when it was
  /// seen late): first what happened by time until then.
  void _applyOne(PyramidRecord r, int at) {
    _clock = at;
    _timedUpTo(at);
    _lastRecord = r;
    _lastAt = at;
    _cause = r.id;
    _causeAt = at;
    final String? proposal = r.body['pn'] is String ? r.contentKey : null;
    if (proposal != null && _proposalsDone.contains(proposal)) {
      rejected[r.id] = 'ta propozycja już weszła (inna kopia)';
      return;
    }
    if (_poison.contains(r.id)) {
      // It threw in an earlier round: refused before anything of it
      // happened.
      rejected[r.id] = 'błędny rekord';
      return;
    }
    String? why;
    try {
      why = _apply(r);
      debugAfterApply?.call(r);
    } on Object {
      // A malformed record never breaks the pyramid: it does not count,
      // the same way on every phone.
      why = 'błędny rekord';
      _threw.add(r.id);
    }
    _noteHead(at);
    _noteTreasurers(at);
    if (why == null) {
      if (proposal != null) {
        _proposalsDone.add(proposal);
      }
      applied.add(r.id);
      for (final String k in r.signers) {
        lastSeen[k] = max(lastSeen[k] ?? 0, r.at);
      }
    } else {
      rejected[r.id] = _lateHit.contains(r.id)
          ? 'akt z cofniętej delegacji, dopisany po jej cofnięciu'
          : why;
    }
  }

  /// Applies [more] — records new to this state — in place, exactly as
  /// [fold] of everything would, and moves time on to [now]: only when
  /// all of them come after the last record applied and after every
  /// change by time already made, none of them folds at another time
  /// ([late]) and none breaks (a rule throwing, an act dated back past a
  /// revocation). False otherwise: the state may then be half changed and
  /// must be folded again from the start. Nothing else is worked out
  /// again: new records are cheap, only an insertion into the past costs
  /// a whole fold.
  bool extend(
    Iterable<PyramidRecord> more, {
    required int now,
    Map<String, int> late = const <String, int>{},
  }) {
    final List<PyramidRecord> list = <PyramidRecord>[
      for (final PyramidRecord r in more)
        if (r.id == id || r.pyramid == id) r,
    ];
    if (list.isEmpty) {
      advanceTo(now);
      return true;
    }
    for (final PyramidRecord r in list) {
      final int? seen = late[r.id];
      if (r.at > now + kPyrMaxSkewMs ||
          applied.contains(r.id) ||
          rejected.containsKey(r.id) ||
          (seen != null && seen > r.at && PyrT.timed.contains(r.type))) {
        return false;
      }
    }
    list.sort(_order);
    final PyramidRecord first = list.first;
    final PyramidRecord? last = _lastRecord;
    if ((last != null && _orderAt(last, _lastAt, first, first.at) >= 0) ||
        first.at < _lastEvent) {
      return false;
    }
    for (final PyramidRecord r in list) {
      _applyOne(r, r.at);
    }
    if (_threw.isNotEmpty || _witnessIfLate().isNotEmpty) {
      return false;
    }
    _timedUpTo(now);
    revision++;
    return true;
  }

  /// Moves time on to [now]: elections end, emissions and new rules take
  /// effect, as a fold at [now] would have it.
  void advanceTo(int now) {
    final int had = _lastEvent;
    final int seen = history.length;
    _timedUpTo(now);
    if (_lastEvent != had || history.length != seen) {
      revision++;
    }
  }

  /// The revoked delegations → the acts their revocation listed, when an
  /// act through one of them (or through one passed on from it) counted
  /// without being on that list: it was dated back past the revocation,
  /// and the second pass of [fold] runs without it. Empty when
  /// every act that counted was listed.
  Map<String, Set<String>> _witnessIfLate() {
    final Map<String, Set<String>> witnessed = <String, Set<String>>{
      for (final PyrDelegation d in delegations.values)
        if (d.revoked) d.id: d.knownAtRevocation,
    };
    if (witnessed.isEmpty) {
      return const <String, Set<String>>{};
    }
    final bool late = delegations.values.any(
      (PyrDelegation x) => x.acts.keys.any(
        (String act) =>
            applied.contains(act) &&
            _chainOf(
              x,
            ).any((PyrDelegation y) => witnessed[y.id]?.contains(act) == false),
      ),
    );
    return late ? witnessed : const <String, Set<String>>{};
  }

  /// Things that happen by time: elections end, emissions and new rules
  /// take effect.
  void _timedUpTo(int upTo) {
    final List<PyrElection> due =
        elections.values
            .where((PyrElection e) => !e.closed && e.deadline <= upTo)
            .toList()
          ..sort(
            (PyrElection a, PyrElection b) => a.deadline.compareTo(b.deadline),
          );
    for (final PyrElection e in due) {
      _closeElection(e, e.deadline);
      _lastEvent = max(_lastEvent, e.deadline);
    }
    final List<PyrEmission> ready =
        emissions.values
            .where(
              (PyrEmission e) => !e.done && !e.vetoed && e.effectiveAt <= upTo,
            )
            .toList()
          ..sort(
            (PyrEmission a, PyrEmission b) =>
                a.effectiveAt.compareTo(b.effectiveAt),
          );
    for (final PyrEmission e in ready) {
      // The treasurers credit it, privately, to whom its note names.
      e.done = true;
      _lastEvent = max(_lastEvent, e.effectiveAt);
      history.add(
        PyrHistory(
          e.effectiveAt,
          t('Emisja {amount}', {'amount': pyrMoney(e.amount)}),
          e.id,
        ),
      );
    }
    final List<PyrParamsChange> rules =
        paramsChanges.values
            .where((PyrParamsChange c) => !c.done && c.effectiveAt <= upTo)
            .toList()
          ..sort(
            (PyrParamsChange a, PyrParamsChange b) =>
                a.effectiveAt != b.effectiveAt
                ? a.effectiveAt.compareTo(b.effectiveAt)
                : a.id.compareTo(b.id),
          );
    for (final PyrParamsChange c in rules) {
      c.done = true;
      _lastEvent = max(_lastEvent, c.effectiveAt);
      params
        ..apply(c.params)
        ..version += 1;
      _natLead.clear();
      _treasurersDirty = true;
      _noteTreasurers(c.effectiveAt);
      history.add(
        PyrHistory(
          c.effectiveAt,
          t('Nowe zasady (wersja {version})', {'version': params.version}),
          c.id,
        ),
      );
    }
    final List<PyrEmitChange> raises =
        emitChanges.values
            .where((PyrEmitChange c) => c.pending && c.effectiveAt <= upTo)
            .toList()
          ..sort(
            (PyrEmitChange a, PyrEmitChange b) =>
                a.effectiveAt.compareTo(b.effectiveAt),
          );
    for (final PyrEmitChange c in raises) {
      c.done = true;
      _lastEvent = max(_lastEvent, c.effectiveAt);
      _setEmission(c.limit, c.delayHours, c.xfers);
      history.add(
        PyrHistory(
          c.effectiveAt,
          t(
            'Limity po 30 dniach: emisja {limit}, czekanie {hours} h, przelewy {xfers} na dzień',
            {
              'limit': pyrMoney(params.emitLimit),
              'hours': params.emitDelayHours,
              'xfers': params.xferLimit,
            },
          ),
          c.id,
        ),
      );
    }
  }

  /// The emission limit and wait from now on (null: unchanged).
  void _setEmission(int? limit, int? delayHours, int? xfers) {
    params
      ..emitLimit = limit ?? params.emitLimit
      ..emitDelayHours = delayHours ?? params.emitDelayHours
      ..xferLimit = xfers ?? params.xferLimit
      ..version += 1;
  }

  /// Changes of the emission limit announced and still waiting.
  List<PyrEmitChange> get pendingEmitChanges =>
      emitChanges.values.where((PyrEmitChange c) => c.pending).toList()..sort(
        (PyrEmitChange a, PyrEmitChange b) =>
            a.effectiveAt.compareTo(b.effectiveAt),
      );

  String _name(String key) =>
      members[key]?.name ?? key.substring(0, min(6, key.length));

  int _countOf(Iterable<String> signers, Iterable<String> allowed) {
    final Set<String> a = allowed.toSet();
    return signers.toSet().where(a.contains).length;
  }

  bool _twoOfTop(PyramidRecord r) => _countOf(r.signers, topCell) >= 2;

  int _clock = 0;

  /// The records that fold at another time than their own ([_foldTimes]).
  Map<String, int> _times = const <String, int>{};

  /// The time [r] counts from here: its own, or when this phone first saw
  /// it late ([PyramidState.fold]).
  int _timeOf(PyramidRecord r) => _times[r.id] ?? r.at;

  /// Notes since when the head of the pyramid holds the top (a handover
  /// of the power key may be signed by the top only 72 h later).
  void _noteHead(int at) {
    final String? h = occupant[''];
    if (h != _headKey) {
      _headKey = h;
      headSince = at;
    }
  }

  void _place(String key, String path, String recordId) {
    occupant[path] = key;
    position[key] = path;
    vacant.remove(path);
    _noteLevel(key);
  }

  void _noteLevel(String key) {
    final String? p = position[key];
    (_levels[key] ??= <List<int>>[]).add(<int>[_clock, p?.length ?? -1]);
    moves.add(PyrMove(_causeAt, _cause, key, p));
    _treasurersDirty = true;
    // The tree changed: national sections are worked out again.
    _natLead.clear();
  }

  /// Whether [key] had level [lvl] at [at] or during the week before.
  bool _hadLevel(String key, int lvl, int at) {
    final List<List<int>> h = _levels[key] ?? const <List<int>>[];
    for (int i = 0; i < h.length; i++) {
      final int from = h[i][0];
      final int to = i + 1 < h.length ? h[i + 1][0] : 1 << 62;
      if (h[i][1] == lvl && from <= at && to >= at - 7 * 24 * 3600 * 1000) {
        return true;
      }
    }
    return false;
  }

  void _vacate(String path) {
    final String? k = occupant.remove(path);
    if (k != null) {
      position.remove(k);
      _noteLevel(k);
    }
    final bool hasBelow = occupant.keys.any(
      (String p) => p.length > path.length && p.startsWith(path),
    );
    if (hasBelow) {
      vacant.add(path);
    } else {
      vacant.remove(path);
      // Empty vacant positions above disappear too.
      String q = path;
      while (q.isNotEmpty) {
        q = PyrPath.parent(q);
        if (vacant.contains(q) &&
            !occupant.keys.any((String p) => p.startsWith(q))) {
          vacant.remove(q);
        } else {
          break;
        }
      }
    }
  }

  /// Moves everything at and under [from] to [to] (same shape below); the
  /// old place disappears, and so do empty free places above it.
  void _moveBranch(String from, String to) {
    final Map<String, String> people = <String, String>{
      for (final MapEntry<String, String> e in occupant.entries)
        if (PyrPath.within(e.key, from)) e.key: e.value,
    };
    final List<String> free = vacant
        .where((String v) => PyrPath.within(v, from))
        .toList();
    for (final String p in people.keys) {
      occupant.remove(p);
    }
    vacant.removeAll(free);
    for (final MapEntry<String, String> e in people.entries) {
      final String np = '$to${e.key.substring(from.length)}';
      occupant[np] = e.value;
      position[e.value] = np;
      _noteLevel(e.value);
    }
    for (final String v in free) {
      vacant.add('$to${v.substring(from.length)}');
    }
    String q = from;
    while (q.isNotEmpty) {
      q = PyrPath.parent(q);
      if (vacant.contains(q) &&
          !occupant.keys.any((String p) => p.startsWith(q))) {
        vacant.remove(q);
      } else {
        break;
      }
    }
  }

  void _termChange(int at) {
    term++;
    termStart[term] = at;
  }

  /// The ML-DSA fingerprint [key] signs with, as the records fixed it.
  String? _pqOf(String key) => key == powerKey ? powerKeyPq : members[key]?.pq;

  /// Why a signature of [r] does not count: it carries another ML-DSA key
  /// than its signer's (a forged Ed25519 half paired with the forger's own
  /// ML-DSA key). Null when every known signer's key matches.
  String? _pqMismatch(PyramidRecord r) {
    for (final String k in r.sigs.keys) {
      final String? want = _pqOf(k);
      if (want != null && r.pqIdOf(k) != want) {
        return 'podpis innym kluczem ML-DSA niż klucz osoby';
      }
    }
    return null;
  }

  /// Whether the signature [key] made on private [r] (as its signer, or
  /// with [treasurer] as a treasurer) carries the ML-DSA key [key] was
  /// admitted with — a forged Ed25519 half with the forger's own ML-DSA
  /// key does not count.
  bool pqHolds(PyramidRecord r, String key, {bool treasurer = false}) {
    final String? want = _pqOf(key);
    return want != null && r.pqIdOf(key, treasurer: treasurer) == want;
  }

  /// Applies one record; returns why it does not count, or null.
  String? _apply(PyramidRecord r) {
    final Map<String, dynamic> b = r.body;
    final List<String> by = r.signers;
    final String? keyMismatch = _pqMismatch(r);
    if (keyMismatch != null) {
      return keyMismatch;
    }
    switch (r.type) {
      case PyrT.genesis:
        // The pinned record itself: its power key signs it, nobody sits
        // in the pyramid yet.
        final String pk = r.str('pk');
        if (r.id != id || powerKey != null) {
          return 'zły początek';
        }
        if (!PyramidRecord.isCanonicalKey(pk) ||
            by.length != 1 ||
            by.first != pk) {
          return 'genesis podpisuje klucz władzy';
        }
        final Object? pq = b['pq'];
        if (pq != null && !PyramidRecord.isCanonicalKey(pq)) {
          return 'zły odcisk klucza władzy';
        }
        name = r.str('name');
        params.apply(b['params'], emission: true);
        powerKey = pk;
        powerKeyPq = pq as String?;
        usedPowerKeys.add(pk);
        termStart[1] = r.at;
        history.add(
          PyrHistory(
            r.at,
            t('Powstała piramida „{name}”', {'name': name}),
            r.id,
          ),
        );
        return null;
      case PyrT.found:
        // The first head, seated by the holder of the power key while the
        // pyramid is empty.
        final PyrMember? m = _memberFrom(b['m'], r.at, null, founder: true);
        final String? pk = powerKey;
        if (pk == null || m == null) {
          return 'zły założyciel';
        }
        if (position.isNotEmpty) {
          return 'piramida ma już szefa';
        }
        if (!by.contains(pk) || !by.contains(m.key)) {
          return 'podpisują klucz władzy i założyciel';
        }
        if (r.pqIdOf(m.key) != m.pq) {
          return 'założyciel podpisuje innym kluczem ML-DSA';
        }
        if (bannedAt(m.key, 'perm', r.at)) {
          return 'ban stały';
        }
        members[m.key] = m;
        knownBy.remove(m.key);
        _place(m.key, '', r.id);
        powerHead = m.key;
        history.add(
          PyrHistory(
            r.at,
            t('{name} zakłada piramidę jako pierwszy szef', {'name': m.name}),
            r.id,
          ),
        );
        return null;
      case PyrT.handover:
        return _handover(r);
      case PyrT.admit:
        // "Polecenie": the sponsor (any member) vouches for the newcomer
        // and picks a free place in their own branch; the head of the cell
        // there co-signs (the sponsor itself for a place right under it).
        final String sponsor = r.str('sp');
        final String headKey = r.str('head');
        final String slot = r.str('slot');
        final String? sponsorPath = position[sponsor];
        final PyrMember? m = _memberFrom(b['m'], r.at, sponsor);
        if (m == null) {
          return 'złe dane przyjmowanego (rok urodzenia)';
        }
        if (sponsorPath == null) {
          return 'polecający nie jest w piramidzie';
        }
        if (!by.contains(sponsor) ||
            !by.contains(headKey) ||
            !by.contains(m.key)) {
          return 'podpisują polecający, nowa osoba i szef komórki';
        }
        if (r.pqIdOf(m.key) != m.pq) {
          return 'nowa osoba podpisuje innym kluczem ML-DSA';
        }
        if (position.containsKey(m.key)) {
          return 'już jest w piramidzie';
        }
        if (bannedAt(m.key, 'perm', r.at)) {
          return 'ban stały';
        }
        if (bannedAt(sponsor, 'noadmit', r.at)) {
          return 'polecający ma zakaz przyjmowania';
        }
        if (slot.isEmpty ||
            !PyrPath.valid(slot) ||
            !PyrPath.within(slot, sponsorPath)) {
          return 'miejsce spoza gałęzi polecającego';
        }
        if (_exists(slot) || occupant[PyrPath.parent(slot)] == null) {
          return 'to miejsce nie jest wolne';
        }
        if (occupant[PyrPath.parent(slot)] != headKey) {
          return 'szef komórki już inny';
        }
        // A former member comes back no higher than they left from: leaving
        // and coming back is no way up.
        if (slot.length < (leftLevel[m.key] ?? 0)) {
          return 'powrót najwyżej na poziom, z którego wyszedł(-ła)';
        }
        members[m.key] = m;
        knownBy.remove(m.key);
        _place(m.key, slot, r.id);
        // Right into the sponsor's own cell: the sponsor knows them (met
        // in person, QR) — that is the cell's confirmation.
        if (headKey == sponsor && canVote(sponsor, r.at)) {
          knownBy[m.key] = <String, int>{sponsor: r.at};
        }
        history.add(
          PyrHistory(
            r.at,
            headKey == sponsor
                ? t('{head} przyjął(-ęła) {name}', {
                    'head': _name(headKey),
                    'name': m.name,
                  })
                : t('{sponsor} polecił(a) {name} do komórki {head}', {
                    'sponsor': _name(sponsor),
                    'name': m.name,
                    'head': _name(headKey),
                  }),
            r.id,
          ),
        );
        return null;
      case PyrT.swap:
        final String cell = r.str('cell');
        final String up = r.str('up');
        if (occupant[cell] != r.str('head') || occupant[cell] == null) {
          return 'szef komórki już inny';
        }
        final String? upPath = position[up];
        if (upPath == null ||
            PyrPath.parent(upPath) != cell ||
            upPath == cell) {
          return 'nowy szef nie jest członkiem tej komórki';
        }
        // Only those with a vote in the cell count ([canVote]).
        if (_countOf(by, cellVoters(cell, r.at)) < 2) {
          return 'potrzeba 2 z 3 w komórce (z prawem głosu)';
        }
        if (!_canRise(up, r.at)) {
          return _riseTooSoon;
        }
        _swap(cell, upPath, r);
        lastRise[up] = r.at;
        return null;
      case PyrT.voteRequest:
        return _voteRequest(r);
      case PyrT.ballot:
        return _ballot(r);
      case PyrT.roster:
        return _roster(r);
      case PyrT.vote:
        return _vote(r);
      case PyrT.leave:
        final String k = r.str('k');
        final String? p = position[k];
        if (p == null || !(by.length == 1 && by.first == k)) {
          return 'nie ma kogo';
        }
        leftLevel[k] = p.length;
        _vacate(p);
        members[k]?.active = false;
        if (p.isEmpty) {
          _termChange(r.at);
        }
        history.add(
          PyrHistory(
            r.at,
            t('{name} wyszedł(-ła) z piramidy', {'name': _name(k)}),
            r.id,
          ),
        );
        return null;
      case PyrT.fill:
        final String cell = r.str('cell');
        final String up = r.str('up');
        if (!vacant.contains(cell)) {
          return 'miejsce nie jest wolne';
        }
        final String? upPath = position[up];
        if (upPath == null ||
            PyrPath.parent(upPath) != cell ||
            upPath == cell) {
          return 'nie jest pod tym miejscem';
        }
        final List<String> kids = <String>[
          for (final String c in PyrPath.children(cell))
            if (occupant[c] != null) occupant[c]!,
        ];
        final List<String> need = kids.length >= 2
            ? kids
            : <String>[
                up,
                if (cell.isNotEmpty && occupant[PyrPath.parent(cell)] != null)
                  occupant[PyrPath.parent(cell)]!,
              ];
        if (!need.every(by.contains)) {
          return 'brak wymaganych podpisów';
        }
        if (!_canRise(up, r.at)) {
          return _riseTooSoon;
        }
        _vacate(upPath);
        _place(up, cell, r.id);
        lastRise[up] = r.at;
        if (cell.isEmpty) {
          _termChange(r.at);
        }
        history.add(
          PyrHistory(
            r.at,
            t('{name} zajął(-ęła) wolne miejsce wyżej', {'name': _name(up)}),
            r.id,
          ),
        );
        return null;
      case PyrT.absent:
        final String k = r.str('k');
        final String? p = position[k];
        if (p == null) {
          return 'nie ma kogo';
        }
        final List<String> around = <String>[
          for (final String q in <String>[
            if (p.isNotEmpty) PyrPath.parent(p),
            if (p.isNotEmpty) PyrPath.sibling(p),
            ...PyrPath.children(p),
          ])
            if (occupant[q] != null && occupant[q] != k) occupant[q]!,
        ];
        // 2 of the neighbours (parent, sibling, children); 1 where only one
        // is left, e.g. a leaf whose sibling place is empty.
        if (around.isEmpty || _countOf(by, around) < min(2, around.length)) {
          return 'potrzeba 2 osób z komórek';
        }
        final int seen = lastSeen[k] ?? members[k]!.joinedAt;
        if (r.at - seen < params.absenceDays * 24 * 3600 * 1000) {
          return 'jeszcze nie minęło ${params.absenceDays} dni';
        }
        leftLevel[k] = p.length;
        _vacate(p);
        members[k]?.active = false;
        if (p.isEmpty) {
          _termChange(r.at);
        }
        history.add(
          PyrHistory(
            r.at,
            t('{name}: miejsce uznane za wolne (nieobecność)', {
              'name': _name(k),
            }),
            r.id,
          ),
        );
        return null;
      case PyrT.remove:
        final String k = r.str('k');
        final String? p = position[k];
        if (p == null) {
          return 'nie ma kogo';
        }
        final List<String> cell = ownCellOf(k);
        if (cell.length < 2 || _countOf(by, cell) < 2) {
          return 'usunąć może tylko własna komórka (2 z 3)';
        }
        if (p.length <= 1 && !_topImmunityHolds(by)) {
          return 'szczyt: potrzebne 2 z 3 szczytu i większość poziomu 2';
        }
        leftLevel[k] = p.length;
        // Appealed above the head who removed them.
        matters[r.id] = PyrMatter(
          id: r.id,
          kind: PyrMatterKind.remove,
          party: k,
          parties: <String>{k},
          decider: p.isEmpty ? '' : PyrPath.parent(p),
          step: -1,
          at: r.at,
          oldPath: p,
        );
        _vacate(p);
        members[k]?.active = false;
        if (p.isEmpty) {
          _termChange(r.at);
        }
        history.add(
          PyrHistory(
            r.at,
            t('{name} usunięty(-a) przez swoją komórkę', {'name': _name(k)}),
            r.id,
          ),
        );
        return null;
      case PyrT.migrate:
        final String k = r.str('k');
        final String to = r.str('to');
        final String? p = position[k];
        final String? toPath = position[to];
        if (p == null ||
            toPath == null ||
            !by.contains(k) ||
            !by.contains(to)) {
          return 'potrzebne podpisy obu osób';
        }
        if (PyrPath.within(toPath, p)) {
          return 'nie można przejść do własnej gałęzi';
        }
        final String? slot = freeSlot(toPath);
        if (slot == null) {
          return 'brak wolnego miejsca';
        }
        final List<String> below = <String>[
          for (final String c in PyrPath.children(p))
            if (occupant[c] != null) occupant[c]!,
        ];
        // Promotion is step by step: a move goes sideways or down, or
        // one level up into the cell of a head who agrees (with the mover,
        // 2 of that cell) — and not again before [kPyrRiseCooldownMs]. A
        // whole branch never moves up: it climbs only by its head's swaps.
        final bool withBranch = b['branch'] == true && below.isNotEmpty;
        if (slot.length < p.length - (withBranch ? 0 : 1)) {
          return withBranch
              ? 'gałąź przechodzi tylko na ten sam poziom albo niżej'
              : 'awans tylko o jeden poziom';
        }
        final bool rises = slot.length < p.length;
        if (rises && !_canRise(k, r.at)) {
          return _riseTooSoon;
        }
        if (withBranch) {
          // With the whole branch: the whole own cell agrees.
          if (!below.every(by.contains)) {
            return 'przejście z gałęzią: zgoda całej komórki';
          }
          _moveBranch(p, slot);
          history.add(
            PyrHistory(
              r.at,
              t('{name} przeszedł(-ła) z całą gałęzią pod {head}', {
                'name': _name(k),
                'head': _name(to),
              }),
              r.id,
            ),
          );
          return null;
        }
        _vacate(p);
        _place(k, slot, r.id);
        if (rises) {
          lastRise[k] = r.at;
        }
        if (p.isEmpty) {
          _termChange(r.at);
        }
        history.add(
          PyrHistory(
            r.at,
            t('{name} przeszedł(-ła) pod {head}', {
              'name': _name(k),
              'head': _name(to),
            }),
            r.id,
          ),
        );
        return null;
      case PyrT.alive:
        if (!position.containsKey(r.str('k')) || by.firstOrNull != r.str('k')) {
          return 'nie członek';
        }
        return null;
      case PyrT.address:
        final PyrMember? m = members[r.str('k')];
        if (m == null || by.firstOrNull != m.key) {
          return 'nie członek';
        }
        final String addr = _clip(r.str('addr'), 300);
        // Every address stays known (a verdict shows at each): never
        // so many that keeping them costs anything.
        if (addr.isEmpty) {
          return 'brak adresu';
        }
        if (!m.addrs.contains(addr) && m.addrs.length >= kPyrMaxAddrs) {
          return 'za dużo adresów';
        }
        m
          ..addr = addr
          ..addrs.add(addr);
        return null;
      case PyrT.delegate:
        return _delegate(r);
      case PyrT.revoke:
        final PyrDelegation? d = delegations[r.str('d')];
        if (d == null) {
          return 'nie ma takiej delegacji';
        }
        if (d.revoked) {
          return 'już cofnięta';
        }
        final Object? known = r.body['acts'];
        if (known is! List) {
          return 'brak listy znanych aktów';
        }
        final bool byIssuer =
            (d.parent != null && by.contains(delegations[d.parent]?.to)) ||
            // The head takes back writing to the whole pyramid alone.
            (d.power == 'posts' &&
                occupant[''] != null &&
                by.contains(occupant['']));
        if (!_twoOfTop(r) && !byIssuer) {
          return 'cofnąć może szczyt albo wystawca';
        }
        // From now on it (and every delegation passed on from it) is worth
        // nothing; the acts done before stay, those it lists.
        d
          ..revoked = true
          ..knownAtRevocation = known.whereType<String>().toSet();
        history.add(
          PyrHistory(
            r.at,
            t('Cofnięto delegację „{power}” dla {name}', {
              'power': d.power,
              'name': _name(d.to),
            }),
            r.id,
          ),
        );
        return null;
      case PyrT.ban:
        return _ban(r);
      case PyrT.unban:
        final PyrBan? ban = bans[r.str('ban')];
        if (ban == null) {
          return 'nie ma takiego bana';
        }
        if (!_twoOfTop(r)) {
          return 'uchylić może szczyt (2 z 3)';
        }
        ban.lifted = true;
        history.add(
          PyrHistory(
            r.at,
            t('Uchylono ban dla {name}', {'name': _name(ban.target)}),
            r.id,
          ),
        );
        return null;
      case PyrT.decision:
        final String? via = b['via'] is String ? b['via'] as String : null;
        if (!_twoOfTop(r)) {
          if (via == null ||
              !_canUse(via, 'reports', delegations[via]?.scope ?? '', r)) {
            return 'decyzję wydaje delegat od zgłoszeń albo szczyt';
          }
          _use(via, r, count: false);
        }
        decisions[r.str('rep')] = _clip(r.str('outcome'), 2000);
        return null;
      case PyrT.post:
        final String k = by.firstOrNull ?? '';
        if (!position.containsKey(k) || !_hadLevel(k, r.integer('lvl'), r.at)) {
          return 'zły poziom autora';
        }
        if (silencedAt(k, r.at)) {
          return 'autor ma przerwę';
        }
        // To the whole pyramid: the head's own post (level 0), or one
        // through the head's delegation of `posts`.
        final bool toAll = b['all'] == true;
        final String? via = b['via'] is String ? b['via'] as String : null;
        if (toAll && r.integer('lvl') != 0) {
          if (via == null ||
              delegations[via]?.to != k ||
              !_canUse(via, 'posts', '', r)) {
            return 'do całej piramidy pisze szef albo osoba z jego delegacją';
          }
          _use(via, r);
        }
        posts[r.id] = PyrPost(
          id: r.id,
          author: k,
          text: _clip(r.str('text'), 5000),
          level: r.integer('lvl'),
          at: r.at,
          toAll: toAll,
          via: toAll && r.integer('lvl') != 0 ? via : null,
        );
        return null;
      case PyrT.comment:
        final String k = by.firstOrNull ?? '';
        final PyrPost? post = posts[r.str('post')] ?? natPosts[r.str('post')];
        if (post == null || !position.containsKey(k) || silencedAt(k, r.at)) {
          return 'nie można skomentować';
        }
        if (post.nat == null) {
          final String? ap = position[post.author];
          if (ap != null &&
              k != post.author &&
              !PyrPath.within(position[k]!, ap)) {
            return 'komentować może tylko gałąź autora';
          }
        } else if (members[k]?.nat != post.nat) {
          return 'komentują członkowie tej narodowości';
        }
        final List<Map<String, dynamic>> media = pyrCommentMedia(b['img']);
        if (r.str('text').trim().isEmpty && media.isEmpty) {
          return 'pusty komentarz';
        }
        post.comments.add(
          PyrComment(
            id: r.id,
            author: k,
            text: _clip(r.str('text'), 2000),
            at: r.at,
            media: media,
          ),
        );
        return null;
      case PyrT.natPost:
        final String k = by.firstOrNull ?? '';
        final String nat = r.str('nat');
        if (!position.containsKey(k) ||
            members[k]?.nat != nat ||
            !_hadLevel(k, r.integer('lvl'), r.at)) {
          return 'nie z tej narodowości';
        }
        if (silencedAt(k, r.at)) {
          return 'autor ma przerwę';
        }
        natPosts[r.id] = PyrPost(
          id: r.id,
          author: k,
          text: _clip(r.str('text'), 5000),
          level: r.integer('lvl'),
          at: r.at,
          nat: nat,
        );
        return null;
      case PyrT.natGrant:
        final String nat = r.str('nat');
        // Cheap checks first: one signer, in the pyramid, of that
        // nationality; only then who leads the section.
        final String k = by.length == 1 ? by.first : '';
        if (nat.isEmpty ||
            !position.containsKey(k) ||
            members[k]?.nat != nat ||
            nationalLead(nat) != k) {
          return 'nadaje tylko osoba prowadząca sekcję';
        }
        (natGrants[nat] ??= <String, int>{})[r.str('to')] = r.integer('until');
        return null;
      case PyrT.referendum:
        return _referendum(r);
      case PyrT.tally:
        return _tally(r);
      case PyrT.constitution:
        // The top changes the rules itself (2 of 3); a referendum before
        // only advises it. They apply a day later, within the hard limits.
        if (!_twoOfTop(r)) {
          return 'zasady zmienia szczyt (2 z 3)';
        }
        final Object? p = b['params'];
        final Map<String, dynamic> changed = <String, dynamic>{
          if (p is Map)
            for (final MapEntry<dynamic, dynamic> e in p.entries)
              if (e.key is String && e.value is int) e.key as String: e.value,
        };
        if (changed.isEmpty) {
          return 'złe zasady';
        }
        // The emission limit has its own rule: lower at once, higher only
        // 30 days after everybody was told ([PyrT.emitRule]).
        if (changed.keys.any(PyrParams.emissionFields.contains)) {
          return 'limit emisji zmienia się osobno (30 dni zapowiedzi)';
        }
        // A day from when it came, when it came late (back-dated past
        // the day's wait, or held back).
        final int since = _timeOf(r);
        paramsChanges[r.id] = PyrParamsChange(
          id: r.id,
          params: changed,
          at: r.at,
          effectiveAt: since + kPyrParamsDelayMs,
        );
        return null;
      case PyrT.emit:
        final int amount = r.integer('amount');
        // Who gets it stays private: only a commitment is public.
        final String rc = r.str('rc');
        if (!_twoOfTop(r) || amount <= 0 || !_isHash(rc)) {
          return 'emisja: 2 z 3 szczytu';
        }
        if (amount > kPyrMaxAmount) {
          return 'za duża kwota';
        }
        // Counted from when it came, when it came late: dated back into
        // old 30-day windows it finds no fresh limit there.
        final int since = _timeOf(r);
        if (amount > params.emitLimit ||
            pyrAdd(emittedWithin(since), amount) > params.emitLimit) {
          // A rolling 30-day limit: a new head (a new term) does not bring
          // a fresh one.
          return 'przekroczony limit emisji (30 dni)';
        }
        emittedInTerm[term] = pyrAdd(emittedInTerm[term] ?? 0, amount);
        final List<String> signers = by.where(topCell.contains).toList();
        emissions[r.id] = PyrEmission(
          id: r.id,
          rc: rc,
          amount: amount,
          term: term,
          at: since,
          signedAt: r.at,
          effectiveAt: since + params.emitDelayHours * 3600 * 1000,
          signers: signers,
          vetoers: <String>[
            for (final String k in topCell)
              if (!signers.contains(k)) k,
          ],
        );
        return null;
      case PyrT.veto:
        final PyrEmission? e = emissions[r.str('emit')];
        if (e == null || e.vetoed || e.done) {
          return 'nie ma czego zawetować';
        }
        // Within the wait as its own time sets it (the same on every
        // phone), or as it runs here from when it came late.
        final bool inSigned = r.at >= e.signedAt && r.at < e.signedEnd;
        final bool inHere = r.at >= e.at && r.at < e.effectiveAt;
        if (!inSigned && !inHere) {
          return 'za późno na weto';
        }
        if (!by.any(e.vetoers.contains)) {
          return 'weto: trzeci członek szczytu';
        }
        e.vetoed = true;
        emittedInTerm[e.term] = max(0, (emittedInTerm[e.term] ?? 0) - e.amount);
        history.add(
          PyrHistory(
            r.at,
            t('Weto wobec emisji {amount}', {'amount': pyrMoney(e.amount)}),
            r.id,
          ),
        );
        return null;
      case PyrT.transfer:
      case PyrT.settle:
        // Payments never go into the public records.
        return 'przelewy są prywatne';
      case PyrT.alarm:
        final Map<dynamic, dynamic> scope = b['scope'] is Map
            ? b['scope'] as Map
            : const <String, dynamic>{};
        final String kind = scope['k'] is String ? scope['k'] as String : 'all';
        final String path = scope['p'] is String ? scope['p'] as String : '';
        final String nat = scope['nat'] is String ? scope['nat'] as String : '';
        final String? via = b['via'] is String ? b['via'] as String : null;
        if (kind == 'branch' && !PyrPath.valid(path)) {
          return 'zły zasięg';
        }
        bool ok =
            _twoOfTop(r) ||
            (kind == 'nat' && nat.isNotEmpty && by.contains(nationalLead(nat)));
        // A delegate reaches only its branch: anything but a branch
        // announcement reaches everybody, so it needs a whole-pyramid
        // delegation.
        if (!ok &&
            via != null &&
            _canUse(via, 'alarm', kind == 'branch' ? path : '', r)) {
          ok = true;
          _use(via, r);
        }
        if (!ok) {
          return 'ogłasza szczyt, delegat albo prowadzący sekcję';
        }
        alarms.add(
          PyrAlarm(
            id: r.id,
            text: _clip(r.str('text'), 1000),
            scopeKind: kind,
            scopePath: path,
            scopeNat: nat,
            at: r.at,
            until: r.integer('until') > r.at
                ? r.integer('until')
                : r.at + 24 * 3600 * 1000,
            by: by.first,
          ),
        );
        return null;
      case PyrT.offer:
        final String k = by.firstOrNull ?? '';
        if (!members.containsKey(k)) {
          return 'nie członek';
        }
        // A kind's price by level of acquaintance, {friend, fof, stranger};
        // [offers] keeps the highest.
        final Map<String, int> flat = <String, int>{};
        final Map<String, Map<String, int>> levels =
            <String, Map<String, int>>{};
        if (b['prices'] is Map) {
          for (final MapEntry<dynamic, dynamic> e
              in (b['prices'] as Map).entries) {
            if (e.key is! String) {
              continue;
            }
            final Object? v = e.value;
            if (v is Map) {
              final Map<String, int> byLevel = <String, int>{
                for (final MapEntry<dynamic, dynamic> l in v.entries)
                  if (kPriceLevels.containsKey(l.key) &&
                      l.value is int &&
                      (l.value as int) >= 0)
                    l.key as String: min(l.value as int, kPyrMaxAmount),
              };
              if (byLevel.isNotEmpty) {
                levels[e.key as String] = byLevel;
                flat[e.key as String] = byLevel.values.reduce(max);
              }
            }
          }
        }
        offers[k] = flat;
        offerLevels[k] = levels;
        return null;
      case PyrT.natPin:
        return _natPin(r);
      case PyrT.badge:
        return _badge(r);
      case PyrT.known:
        return _known(r);
      case PyrT.emitRule:
        return _emitRule(r);
      case PyrT.sealKey:
        // The member's public hybrid KEM key: private payments are sealed
        // to it.
        final PyrMember? m = members[r.str('k')];
        final String kem = r.str('kem');
        if (m == null || by.length != 1 || by.first != m.key) {
          return 'nie członek';
        }
        if (kem.length < 1600 || kem.length > 1700) {
          return 'zły klucz';
        }
        m.kem = kem;
        return null;
      case PyrT.emitCancel:
        return _emitCancel(r);
      case PyrT.suit:
        return _suit(r);
      case PyrT.verdict:
        return _verdict(r);
      case PyrT.appeal:
        return _appeal(r);
      case PyrT.appealAnswer:
        return _appealAnswer(r);
    }
    return 'nieznany rodzaj';
  }

  // ---- the emission limit ----

  /// A new emission limit and/or wait, signed by the top (2 of 3). Only
  /// lower (a smaller limit, a longer wait): at once. Anything that lets
  /// more money out: announced to everybody and in force
  /// [kPyrEmitChangeWaitMs] after (from when this phone saw it, when it
  /// came late), unless the top cancels it before; one waits at a time.
  String? _emitRule(PyramidRecord r) {
    if (!_twoOfTop(r)) {
      return 'limit emisji zmienia szczyt (2 z 3)';
    }
    final Object? l = r.body['limit'];
    final Object? d = r.body['delayH'];
    final Object? x = r.body['xfers'];
    if ((l != null && l is! int) ||
        (d != null && d is! int) ||
        (x != null && x is! int) ||
        (l == null && d == null && x == null)) {
      return 'zła zmiana limitu emisji';
    }
    final int? limit = l is int ? l.clamp(0, kPyrMaxAmount) : null;
    final int? delay = d is int
        ? d.clamp(kPyrMinEmitDelayHours, kPyrMaxEmitDelayHours)
        : null;
    final int? xfers = x is int ? x.clamp(kPyrMinXfers, kPyrMaxXfers) : null;
    final int newLimit = limit ?? params.emitLimit;
    final int newDelay = delay ?? params.emitDelayHours;
    final int newXfers = xfers ?? params.xferLimit;
    if (newLimit == params.emitLimit &&
        newDelay == params.emitDelayHours &&
        newXfers == params.xferLimit) {
      return 'nic się nie zmienia';
    }
    // More money out, or more payments a day for the treasurers to sign.
    final bool raises =
        newLimit > params.emitLimit ||
        newDelay < params.emitDelayHours ||
        newXfers > params.xferLimit;
    if (!raises) {
      _setEmission(limit, delay, xfers);
      history.add(
        PyrHistory(
          r.at,
          t(
            'Obniżono limity: emisja {limit}, czekanie {hours} h, przelewy {xfers} na dzień',
            {
              'limit': pyrMoney(params.emitLimit),
              'hours': params.emitDelayHours,
              'xfers': params.xferLimit,
            },
          ),
          r.id,
        ),
      );
      return null;
    }
    if (emitChanges.values.any((PyrEmitChange c) => c.pending)) {
      return 'już czeka zapowiedziana zmiana limitu emisji';
    }
    final int since = _timeOf(r);
    emitChanges[r.id] = PyrEmitChange(
      id: r.id,
      at: since,
      effectiveAt: since + kPyrEmitChangeWaitMs,
      oldLimit: params.emitLimit,
      oldDelayHours: params.emitDelayHours,
      oldXfers: params.xferLimit,
      limit: limit,
      delayHours: delay,
      xfers: xfers,
    );
    history.add(
      PyrHistory(
        r.at,
        t(
          'Zapowiedziano zmianę limitów: emisja {limit}, czekanie {hours} h, przelewy {xfers} na dzień',
          {'limit': pyrMoney(newLimit), 'hours': newDelay, 'xfers': newXfers},
        ),
        r.id,
      ),
    );
    return null;
  }

  /// The top (2 of 3) cancels a change of the emission limit still
  /// waiting.
  String? _emitCancel(PyramidRecord r) {
    final PyrEmitChange? c = emitChanges[r.str('change')];
    if (c == null || c.cancelled) {
      return 'nie ma czego anulować';
    }
    if (!_twoOfTop(r)) {
      return 'anuluje szczyt (2 z 3)';
    }
    if (c.done || r.at >= c.effectiveAt) {
      return 'za późno: zmiana już obowiązuje';
    }
    c.cancelled = true;
    history.add(
      PyrHistory(r.at, t('Anulowano zapowiedzianą zmianę limitu emisji'), r.id),
    );
    return null;
  }

  // ---- the court and appeals ----

  /// The top cell without [parties]: who judges at the top.
  List<String> topJudges(Set<String> parties) => <String>[
    for (final String k in topCell)
      if (!parties.contains(k)) k,
  ];

  /// The first place from [start] up whose head may judge (not one of
  /// [parties], not empty); '' — the top cell — when nobody below; null
  /// when nobody at all.
  String? _judgeFrom(String start, Set<String> parties) {
    String q = start;
    while (q.isNotEmpty) {
      final String? k = occupant[q];
      if (k != null && !parties.contains(k)) {
        return q;
      }
      q = PyrPath.parent(q);
    }
    return topJudges(parties).isEmpty ? null : '';
  }

  /// Who signs for the judge at [judge] now: the head there, or at the
  /// top 2 of the top cell (all of it when fewer are left), never one of
  /// [parties].
  List<String> judgesAt(String judge, Set<String> parties) {
    if (judge.isEmpty) {
      return topJudges(parties);
    }
    final String? k = occupant[judge];
    return k == null || parties.contains(k) ? const <String>[] : <String>[k];
  }

  /// How many of [judgesAt] must sign.
  static int judgesNeeded(String judge, int judges) =>
      judge.isEmpty ? min(2, judges) : 1;

  bool _judgeSigned(String judge, Set<String> parties, List<String> by) {
    final List<String> j = judgesAt(judge, parties);
    return j.isNotEmpty && _countOf(by, j) >= judgesNeeded(judge, j.length);
  }

  /// The last appeal of [m], if any.
  PyrAppeal? lastAppeal(PyrMatter m) =>
      m.appeals.isEmpty ? null : appeals[m.appeals.last];

  /// Where the next appeal of [m] goes: one level above whoever decided
  /// last (the top reconsiders its own decision once); null when there is
  /// no level left — the top has refused.
  String? nextJudge(PyrMatter m) {
    final PyrAppeal? last = lastAppeal(m);
    final String from = last?.judge ?? m.decider;
    if (from.isEmpty) {
      return last != null || topJudges(m.parties).isEmpty ? null : '';
    }
    return _judgeFrom(PyrPath.parent(from), m.parties);
  }

  /// Why [key] cannot appeal [m] at [at], or null when they can.
  String? appealProblem(PyrMatter m, String key, int at) {
    if (key != m.party) {
      return 'odwołuje się tylko osoba, której to dotyczy';
    }
    if (m.overturned) {
      return 'decyzja już uchylona';
    }
    if (m.kind == PyrMatterKind.ban && (bans[m.id]?.lifted ?? true)) {
      return 'ban już uchylony';
    }
    if (m.kind == PyrMatterKind.verdict && verdicts[m.id] == null) {
      return 'nie ma takiego wyroku';
    }
    if (m.kind == PyrMatterKind.complaint) {
      final PyrCase? c = cases[m.id];
      if (c == null || c.status == PyrCaseStatus.guilty) {
        return 'wyrok zapadł: odwołuje się pozwany';
      }
      if (c.status == PyrCaseStatus.open && at < c.deadline) {
        return 'sprawa czeka jeszcze na pierwszą decyzję';
      }
    }
    final PyrAppeal? last = lastAppeal(m);
    if (last != null && last.openAt(at)) {
      return 'poprzednie odwołanie jeszcze czeka';
    }
    if (nextJudge(m) == null) {
      return 'decyzja jest ostateczna';
    }
    return null;
  }

  /// An appeal by the person a decision is about ([PyrMatter.party]):
  /// once the level before refused or did not answer in time, it goes one
  /// level higher, with twice the time ([pyrStepTimeMs]).
  String? _appeal(PyramidRecord r) {
    final PyrMatter? m = matters[r.str('of')];
    final String k = r.signers.length == 1 ? r.signers.first : '';
    if (m == null) {
      return 'nie ma takiej decyzji';
    }
    final String? problem = appealProblem(m, k, r.at);
    if (problem != null) {
      return problem;
    }
    final String judge = nextJudge(m)!;
    final int step = (lastAppeal(m)?.step ?? m.step) + 1;
    final int since = _timeOf(r);
    appeals[r.id] = PyrAppeal(
      id: r.id,
      matter: m.id,
      by: k,
      why: _clip(r.str('why'), kPyrCourtTextChars),
      at: since,
      signedAt: r.at,
      judge: judge,
      step: step,
      deadline: since + pyrStepTimeMs(step),
    );
    m.appeals.add(r.id);
    history.add(
      PyrHistory(
        r.at,
        judge.isEmpty
            ? t('{name} odwołuje się do szczytu', {'name': _name(k)})
            : t('{name} odwołuje się do {judge}', {
                'name': _name(k),
                'judge': _name(occupant[judge] ?? ''),
              }),
        r.id,
      ),
    );
    return null;
  }

  /// The answer of the level an appeal went to, in its time: accepted, the
  /// decision is overturned; refused, the person may go one level higher.
  /// A dismissed complaint accepted on appeal gets its verdict here.
  String? _appealAnswer(PyramidRecord r) {
    final PyrAppeal? a = appeals[r.str('appeal')];
    if (a == null || a.ok != null) {
      return 'nie ma czego rozpatrzyć';
    }
    final PyrMatter m = matters[a.matter]!;
    if (m.overturned) {
      return 'decyzja już uchylona';
    }
    if (r.at < a.signedAt || r.at >= a.deadline) {
      return 'odpowiedź poza czasem na nią';
    }
    if (!_judgeSigned(a.judge, m.parties, r.signers)) {
      return 'odpowiada szef poziom wyżej (szczyt: 2 z 3)';
    }
    final bool ok = r.body['ok'] == true;
    if (ok && m.kind == PyrMatterKind.complaint) {
      final PyrCase c = cases[m.id]!;
      final String? bad = _addVerdict(r, c, judge: a.judge, step: a.step);
      if (bad != null) {
        return bad;
      }
      c.status = PyrCaseStatus.guilty;
    }
    a
      ..ok = ok
      ..answer = r.id
      ..answerWhy = _clip(r.str('why'), kPyrCourtTextChars);
    if (ok) {
      _overturn(m, r);
    }
    history.add(
      PyrHistory(
        r.at,
        ok
            ? t('Odwołanie {name} przyjęte', {'name': _name(a.by)})
            : t('Odwołanie {name} odrzucone', {'name': _name(a.by)}),
        r.id,
      ),
    );
    return null;
  }

  /// [m] overturned on appeal.
  void _overturn(PyrMatter m, PyramidRecord r) {
    m.overturned = true;
    switch (m.kind) {
      case PyrMatterKind.ban:
        final PyrBan? ban = bans[m.id];
        ban?.lifted = true;
        // A ban a report decision gave: the decision falls with it.
        final String? rep = ban?.rep;
        if (rep != null) {
          overturnedReports.add(rep);
          for (final PyrBan b in bans.values) {
            if (b.rep == rep) {
              b.lifted = true;
            }
          }
        }
      case PyrMatterKind.remove:
        _restore(m.party, m.oldPath ?? '', r);
      case PyrMatterKind.verdict:
        verdicts[m.id]?.overturned = true;
      case PyrMatterKind.complaint:
        // Its verdict was given by the answer itself.
        break;
    }
  }

  /// Brings back a member whose removal was overturned: to their old
  /// place when it is free, else to the first free place under their old
  /// head's branch — never higher than they were.
  void _restore(String key, String oldPath, PyramidRecord r) {
    if (position.containsKey(key) || members[key] == null) {
      return;
    }
    String? spot;
    if (vacant.contains(oldPath) ||
        (!_exists(oldPath) &&
            (oldPath.isEmpty || occupant[PyrPath.parent(oldPath)] != null))) {
      spot = oldPath;
    } else {
      String q = PyrPath.parent(oldPath);
      while (q.isNotEmpty && occupant[q] == null) {
        q = PyrPath.parent(q);
      }
      spot = freePlaces(
        q,
        limit: 64,
      ).where((String x) => x.length >= oldPath.length).firstOrNull;
    }
    if (spot == null) {
      history.add(
        PyrHistory(
          r.at,
          t('{name}: usunięcie uchylone, brak wolnego miejsca', {
            'name': _name(key),
          }),
          r.id,
        ),
      );
      return;
    }
    members[key]?.active = true;
    leftLevel.remove(key);
    _place(key, spot, r.id);
    if (spot.isEmpty) {
      _termChange(r.at);
    }
    history.add(
      PyrHistory(
        r.at,
        t('{name} wraca do piramidy (usunięcie uchylone)', {
          'name': _name(key),
        }),
        r.id,
      ),
    );
  }

  /// A complaint of one member against another ("Sąd"): first to the head
  /// of the accused's cell (or the first one above who is not a party; at
  /// the top, 2 of the top cell), who has [pyrStepTimeMs] (0) to answer.
  String? _suit(PyramidRecord r) {
    final String k = r.signers.length == 1 ? r.signers.first : '';
    final String accused = r.str('k');
    if (!position.containsKey(k)) {
      return 'skargę składa członek piramidy';
    }
    final String? p = position[accused];
    if (p == null || accused == k) {
      return 'pozwać można innego członka piramidy';
    }
    if (!kPyrVerdictKinds.contains(r.str('type'))) {
      return 'zły rodzaj sprawy';
    }
    if (r.str('text').trim().isEmpty) {
      return 'skarga bez opisu';
    }
    final int open = cases.values
        .where(
          (PyrCase c) =>
              c.plaintiff == k &&
              c.status == PyrCaseStatus.open &&
              r.at < c.deadline,
        )
        .length;
    if (open >= kPyrOpenSuits) {
      return 'za dużo otwartych skarg';
    }
    final Set<String> parties = <String>{k, accused};
    final String? judge = _judgeFrom(
      p.isEmpty ? '' : PyrPath.parent(p),
      parties,
    );
    if (judge == null) {
      return 'nie ma kto rozpatrzyć';
    }
    final int since = _timeOf(r);
    cases[r.id] = PyrCase(
      id: r.id,
      plaintiff: k,
      accused: accused,
      kind: r.str('type'),
      text: _clip(r.str('text'), kPyrCourtTextChars),
      at: since,
      signedAt: r.at,
      judge: judge,
      deadline: since + pyrStepTimeMs(0),
    );
    matters[r.id] = PyrMatter(
      id: r.id,
      kind: PyrMatterKind.complaint,
      party: k,
      parties: parties,
      decider: judge,
      step: 0,
      at: since,
    );
    history.add(
      PyrHistory(
        r.at,
        t('Skarga {name} przeciw {other}', {
          'name': _name(k),
          'other': _name(accused),
        }),
        r.id,
      ),
    );
    return null;
  }

  /// The first instance decides a complaint in its time: a verdict
  /// (guilty) or not.
  String? _verdict(PyramidRecord r) {
    final PyrCase? c = cases[r.str('case')];
    if (c == null || c.status != PyrCaseStatus.open) {
      return 'nie ma takiej sprawy';
    }
    if (r.at < c.signedAt || r.at >= c.deadline) {
      return 'decyzja poza czasem na nią';
    }
    if (!_judgeSigned(c.judge, <String>{c.plaintiff, c.accused}, r.signers)) {
      return 'rozstrzyga szef komórki pozwanego';
    }
    if (r.body['guilty'] != true) {
      c
        ..status = PyrCaseStatus.dismissed
        ..why = _clip(r.str('why'), kPyrCourtTextChars);
      history.add(
        PyrHistory(
          r.at,
          t('Skarga przeciw {name} oddalona', {'name': _name(c.accused)}),
          r.id,
        ),
      );
      return null;
    }
    final String? bad = _addVerdict(r, c, judge: c.judge, step: 0);
    if (bad != null) {
      return bad;
    }
    c.status = PyrCaseStatus.guilty;
    return null;
  }

  /// The verdict [r] gives in [c] (its kind, text, end, the accused's
  /// addresses — each of them one the accused had); null when it counts.
  String? _addVerdict(
    PyramidRecord r,
    PyrCase c, {
    required String judge,
    required int step,
  }) {
    final String kind = r.str('type');
    if (!kPyrVerdictKinds.contains(kind) || r.str('k') != c.accused) {
      return 'zły wyrok';
    }
    final Object? until = r.body['until'];
    if (until != null && (until is! int || until <= r.at)) {
      return 'zły termin wyroku';
    }
    final Object? raw = r.body['addrs'];
    final List<String> addrs = raw is List
        ? raw.whereType<String>().toList()
        : const <String>[];
    final Set<String> known = addressesOf(c.accused);
    if ((raw != null && raw is! List) ||
        addrs.length > kPyrVerdictAddrs ||
        !addrs.every(known.contains)) {
      return 'adresy nie należą do tej osoby';
    }
    verdicts[r.id] = PyrVerdict(
      id: r.id,
      caseId: c.id,
      accused: c.accused,
      plaintiff: c.plaintiff,
      kind: kind,
      text: _clip(r.str('text'), kPyrCourtTextChars),
      at: r.at,
      judge: judge,
      addrs: addrs,
      until: until as int?,
    );
    c.verdict = r.id;
    matters[r.id] = PyrMatter(
      id: r.id,
      kind: PyrMatterKind.verdict,
      party: c.accused,
      parties: <String>{c.accused, c.plaintiff},
      decider: judge,
      step: step,
      at: r.at,
    );
    history.add(
      PyrHistory(
        r.at,
        t('Wyrok wobec {name}: {kind}', {
          'name': _name(c.accused),
          'kind': pyrVerdictLabel(kind),
        }),
        r.id,
      ),
    );
    return null;
  }

  /// The verdicts in force against [key] at [now], the newest first.
  List<PyrVerdict> verdictsAgainst(String key, int now) => <PyrVerdict>[
    for (final PyrVerdict v in verdicts.values)
      if (v.accused == key && v.activeAt(now)) v,
  ]..sort((PyrVerdict a, PyrVerdict b) => b.at.compareTo(a.at));

  /// The members who had [address] (normalized by [normalize]).
  List<String> membersAt(String address, String Function(String) normalize) {
    final String a = normalize(address);
    return <String>[
      for (final PyrMember m in members.values)
        if (m.addrs.any((String x) => normalize(x) == a)) m.key,
    ];
  }

  /// The most posts one national section keeps pinned.
  static const int maxNatPins = 3;

  /// The section's lead pins a post of the section ('on' false unpins).
  String? _natPin(PyramidRecord r) {
    final String nat = r.str('nat');
    final String k = r.signers.length == 1 ? r.signers.first : '';
    final String postId = r.str('post');
    if (nat.isEmpty ||
        !position.containsKey(k) ||
        members[k]?.nat != nat ||
        nationalLead(nat) != k) {
      return 'przypina tylko osoba prowadząca sekcję';
    }
    final Map<String, int> pins = natPins[nat] ??= <String, int>{};
    if (r.body['on'] == false) {
      return pins.remove(postId) == null ? 'nie było przypięte' : null;
    }
    if (natPosts[postId]?.nat != nat) {
      return 'nie ma takiego posta w sekcji';
    }
    pins[postId] = r.at;
    while (pins.length > maxNatPins) {
      final String oldest = pins.entries
          .reduce(
            (MapEntry<String, int> a, MapEntry<String, int> b) =>
                b.value < a.value ? b : a,
          )
          .key;
      pins.remove(oldest);
    }
    return null;
  }

  /// A member shows their gender badge: the gender and salt, with
  /// the published birth year, must open the commitment their admission
  /// confirmed; 'off' hides it.
  String? _badge(PyramidRecord r) {
    final String k = r.signers.length == 1 ? r.signers.first : '';
    final PyrMember? m = members[k];
    if (m == null || !position.containsKey(k) || r.str('k') != k) {
      return 'nie członek';
    }
    if (r.body['off'] == true) {
      return badges.remove(k) == null ? 'nie było odznaki' : null;
    }
    final Object? gender = r.body['g'];
    final Object? salt = r.body['salt'];
    if (gender is! String ||
        salt is! String ||
        gender.length > 8 ||
        salt.length > 64 ||
        m.dataCommit.isEmpty ||
        pyrDataCommit(m.birthYear, gender, salt) != m.dataCommit) {
      return 'odznaka nie zgadza się z danymi z przyjęcia';
    }
    badges[k] = gender;
    return null;
  }

  /// [r]'s signer confirms knowing 'k', somebody of their own cell: from
  /// then on 'k' votes ([canVote]). Only a member who votes confirms, so two
  /// newcomers cannot give each other the vote.
  String? _known(PyramidRecord r) {
    final String k = r.signers.length == 1 ? r.signers.first : '';
    final String about = r.str('k');
    if (!position.containsKey(k) ||
        about == k ||
        !position.containsKey(about)) {
      return 'nie członek';
    }
    if (!cellmates(about).contains(k)) {
      return 'potwierdza ktoś z tej samej komórki';
    }
    if (!canVote(k, r.at)) {
      return 'potwierdza ktoś, kto już głosuje';
    }
    final Map<String, int> by = knownBy[about] ??= <String, int>{};
    if (by.containsKey(k)) {
      return 'już potwierdzone';
    }
    by[k] = r.at;
    history.add(
      PyrHistory(
        r.at,
        t('{name} potwierdza: zna {other}', {
          'name': _name(k),
          'other': _name(about),
        }),
        r.id,
      ),
    );
    return null;
  }

  /// The power key passes to the head now at the top. It only certifies the
  /// line of heads: the old key signs (or, [kPyrHandoverWaitMs] after the
  /// head took the top, most of the top cell), and so do the new key and
  /// the new head. A key never comes back, and no member key is one.
  String? _handover(PyramidRecord r) {
    final List<String> by = r.signers;
    final String from = r.str('from');
    final String to = r.str('to');
    final String head = r.str('head');
    final String? pk = powerKey;
    if (pk == null || from != pk) {
      return 'to nie jest obecny klucz władzy';
    }
    if (head.isEmpty || occupant[''] != head) {
      return 'klucz władzy dostaje obecny szef piramidy';
    }
    if (!PyramidRecord.isCanonicalKey(to) ||
        usedPowerKeys.contains(to) ||
        members.containsKey(to)) {
      return 'zły nowy klucz władzy';
    }
    if (!by.contains(to) || !by.contains(head)) {
      return 'podpisują nowy klucz i szef piramidy';
    }
    // The new key's ML-DSA half, named under the old key's (or the top
    // cell's) signatures and carried by its own.
    final String tpq = r.str('tpq');
    if (!PyramidRecord.isCanonicalKey(tpq) || r.pqIdOf(to) != tpq) {
      return 'zły odcisk nowego klucza władzy';
    }
    final List<String> top = topCell;
    final bool byOld = by.contains(from);
    final bool byTop =
        r.at >= headSince + kPyrHandoverWaitMs &&
        _countOf(by, top) >= top.length ~/ 2 + 1;
    if (!byOld && !byTop) {
      return 'podpisuje dawny klucz władzy (po 72 h: większość szczytu)';
    }
    powerKey = to;
    powerKeyPq = tpq;
    powerHead = head;
    usedPowerKeys.add(to);
    history.add(
      PyrHistory(
        r.at,
        byOld
            ? t('Klucz władzy przekazany: {name}', {'name': _name(head)})
            : t('Klucz władzy przekazany przez szczyt: {name}', {
                'name': _name(head),
              }),
        r.id,
      ),
    );
    return null;
  }

  static String _clip(String s, int n) => s.length > n ? s.substring(0, n) : s;

  /// A SHA-256 in hex (a commitment).
  static bool _isHash(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(s);

  /// The most device addresses one member keeps.
  static const int kPyrMaxAddrs = 64;

  static const String _riseTooSoon =
      'kolejny awans najwcześniej 7 dni po poprzednim';

  /// Whether [key] may move up a level at [at]: not within
  /// [kPyrRiseCooldownMs] of their last move up.
  bool _canRise(String key, int at) {
    final int? last = lastRise[key];
    return last == null || at - last >= kPyrRiseCooldownMs;
  }

  /// When [key] may move up again (now, when nothing holds them back).
  int nextRiseAt(String key) => (lastRise[key] ?? 0) + kPyrRiseCooldownMs;

  /// Every device address [key] had in the pyramid.
  Set<String> addressesOf(String key) =>
      members[key]?.addrs ?? const <String>{};

  /// A member from a record: the key in its one canonical spelling (an
  /// alias would make a second identity of the same person, e.g. a banned
  /// one coming back), and the birth year, required and plausible.
  PyrMember? _memberFrom(
    Object? json,
    int at,
    String? admittedBy, {
    bool founder = false,
  }) {
    if (json is! Map ||
        !PyramidRecord.isCanonicalKey(json['k']) ||
        !PyramidRecord.isCanonicalKey(json['pq']) ||
        json['n'] is! String) {
      return null;
    }
    final Object? year = json['yr'];
    if (year is! int || !pyrBirthYearValid(year, at)) {
      return null;
    }
    final PyrMember m = PyrMember(
      key: json['k'] as String,
      pq: json['pq'] as String,
      name: _clip(json['n'] as String, 40),
      nat: json['nat'] is String
          ? _clip(json['nat'] as String, 8).toUpperCase()
          : '',
      birthYear: year,
      dataCommit: json['dc'] is String ? json['dc'] as String : '',
      joinedAt: at,
      admittedBy: admittedBy,
      addr: json['addr'] is String ? _clip(json['addr'] as String, 300) : '',
      founder: founder,
    );
    if (m.addr.isNotEmpty) {
      m.addrs.add(m.addr);
    }
    // Coming back: the addresses known from before stay known.
    m.addrs.addAll(members[m.key]?.addrs ?? const <String>{});
    return m;
  }

  void _swap(String cell, String upPath, PyramidRecord r) {
    final String head = occupant[cell]!;
    final String up = occupant[upPath]!;
    occupant[cell] = up;
    occupant[upPath] = head;
    position[up] = cell;
    position[head] = upPath;
    _noteLevel(up);
    _noteLevel(head);
    if (cell.isEmpty) {
      _termChange(r.at);
    }
    history.add(
      PyrHistory(
        r.at,
        t('{name} zamienił(a) się miejscem z {head}', {
          'name': _name(up),
          'head': _name(head),
        }),
        r.id,
      ),
    );
  }

  /// What a cell's request cards are made for: the pyramid, the cell, its
  /// head and its voters — a new head or a changed cell needs new ones.
  static String rosterScope(
    String pyramid,
    String cell,
    String head,
    List<String> ring,
  ) =>
      'roster:${sha256Hex(utf8.encode('$pyramid|$cell|$head|${(List<String>.of(ring)..sort()).join(',')}')).substring(0, 32)}';

  /// What the ring signature of a voting card's registration is bound to
  /// (PyramidService: cards go to the cell only, never into the records).
  static String tokenContext(String election) => 'vtok|$election';

  /// The voting cards of a ballot ([PyrT.ballot]): one-time hybrid ids
  /// (`<ed>.<fingerprint>`, [parseHybridKeyId]) in strictly ascending
  /// order, as Ed25519 id → fingerprint; null for anything else (a second
  /// spelling, a repeat, an unsorted list could make two ballots of one).
  static Map<String, String>? ballotTokens(Object? value) {
    if (value is! List ||
        value.isEmpty ||
        value.length > RingSignature.maxRing) {
      return null;
    }
    final Map<String, String> out = <String, String>{};
    String? last;
    for (final Object? item in value) {
      final ({String ed, String pq})? id = parseHybridKeyId(item);
      if (id == null ||
          !PyramidRecord.isCanonicalKey(id.ed) ||
          (last != null && (item as String).compareTo(last) <= 0) ||
          out.containsKey(id.ed)) {
        return null;
      }
      last = item as String;
      out[id.ed] = id.pq;
    }
    return out;
  }

  /// The cell's request cards: as a ballot ([_ballot]), for the cell's
  /// voters and head right now. A later roster of the same cell and
  /// voters counts only with more cards (a member who came back); a new
  /// head or other voters need a new one.
  String? _roster(PyramidRecord r) {
    final String cell = r.str('cell');
    final String head = r.str('head');
    final List<String> ring = cellVoters(cell, r.at)..sort();
    final List<String> listed = List<String>.of(r.candidates)..sort();
    if (occupant[cell] != head || ring.length < 2) {
      return 'zła komórka';
    }
    if (listed.join(',') != ring.join(',')) {
      return 'karty podpisuje komórka';
    }
    final Map<String, String>? cards = ballotTokens(r.body['toks']);
    if (cards == null || cards.length < 2 || cards.length > ring.length) {
      return 'złe karty do żądań';
    }
    final List<String> by = r.signers;
    if (!by.every(ring.contains)) {
      return 'karty podpisuje komórka';
    }
    if (by.length < cards.length) {
      return 'za mało podpisów pod kartami';
    }
    final PyrRoster? had = rosters[cell];
    if (had != null &&
        had.head == head &&
        had.ring.join(',') == ring.join(',') &&
        (cards.length <= had.tokens.length ||
            !had.tokens.keys.every(cards.containsKey))) {
      return 'karty komórki już są';
    }
    rosters[cell] = PyrRoster(
      id: r.id,
      cell: cell,
      head: head,
      ring: ring,
      tokens: cards,
    );
    return null;
  }

  /// An anonymous request for a vote: signed by one of the cell's request
  /// cards ([PyrT.roster]) — a member, nobody knows which — while the cell
  /// is still the one the cards were made for. The card counts its
  /// requests ("the same person asks for the 5th time").
  String? _voteRequest(PyramidRecord r) {
    final String cell = r.str('cell');
    final String head = r.str('head');
    final PyrRoster? roster = rosters[cell];
    final List<String> members = cellVoters(cell, r.at)..sort();
    if (roster == null ||
        occupant[cell] != head ||
        roster.head != head ||
        members.length < 2) {
      return 'zła komórka';
    }
    if (members.join(',') != roster.ring.join(',')) {
      return 'skład komórki się zmienił';
    }
    final List<String> by = r.signers;
    final List<String> listed = r.candidates;
    if (by.length != 1 || listed.length != 1 || listed.first != by.first) {
      return 'żądanie podpisuje jedna karta';
    }
    final String card = by.first;
    final String? pq = roster.tokens[card];
    if (pq == null) {
      return 'karta spoza komórki';
    }
    if (r.pqIdOf(card) != pq) {
      return 'karta z innym kluczem ML-DSA';
    }
    final Map<String, int> counter = requestCounts[cell] ??= <String, int>{};
    counter[card] = (counter[card] ?? 0) + 1;
    final bool open = elections.values.any(
      (PyrElection e) => e.cell == cell && !e.closed,
    );
    if (!open) {
      elections[r.id] = PyrElection(
        id: r.id,
        cell: cell,
        head: head,
        ring: roster.ring,
        deadline: r.at + params.electionHours * 3600 * 1000,
        start: r.at,
      );
      history.add(
        PyrHistory(r.at, t('Ktoś z komórki zażądał nowego głosowania'), r.id),
      );
    }
    return null;
  }

  /// The cell's voting cards: every member of the vote's ring is listed
  /// as a signer, and at least as many of them signed as there are cards.
  /// A member signs only cards that hold its own one, and only all the
  /// cards it heard of (PyramidService), so whoever did not sign cannot
  /// have a card among them unless an honest signer gave up its place:
  /// nobody gets two. The hybrid signatures carry this, so it holds
  /// against a quantum computer too. The first ballot that is complete
  /// counts.
  String? _ballot(PyramidRecord r) {
    final PyrElection? e = elections[r.str('elect')];
    if (e == null || e.closed || r.at < e.start) {
      return 'głosowanie zamknięte';
    }
    if (e.tokens != null) {
      return 'karty do głosowania już są';
    }
    final List<String> listed = r.candidates;
    if (!(listed.length == e.ring.length &&
        listed.toSet().containsAll(e.ring))) {
      return 'karty podpisuje komórka';
    }
    final Map<String, String>? cards = ballotTokens(r.body['toks']);
    if (cards == null || cards.length < 2 || cards.length > e.ring.length) {
      return 'złe karty do głosowania';
    }
    final List<String> by = r.signers;
    if (!by.every(e.ring.contains)) {
      return 'karty podpisuje komórka';
    }
    if (by.length < cards.length) {
      return 'za mało podpisów pod kartami';
    }
    e
      ..tokens = cards
      ..ballot = r.id;
    return null;
  }

  /// A vote: signed by one card of the ballot (a one-time hybrid key that
  /// names nobody), once per card.
  String? _vote(PyramidRecord r) {
    final PyrElection? e = elections[r.str('elect')];
    final String choice = r.str('choice');
    if (e == null || e.closed || r.at < e.start) {
      return 'głosowanie zamknięte';
    }
    final Map<String, String>? cards = e.tokens;
    if (cards == null) {
      return 'nie ma jeszcze kart do głosowania';
    }
    final List<String> by = r.signers;
    final List<String> listed = r.candidates;
    if (by.length != 1 || listed.length != 1 || listed.first != by.first) {
      return 'głos podpisuje jedna karta';
    }
    final String card = by.first;
    final String? pq = cards[card];
    if (pq == null) {
      return 'karta spoza głosowania';
    }
    if (r.pqIdOf(card) != pq) {
      return 'karta z innym kluczem ML-DSA';
    }
    if (!e.ring.contains(choice)) {
      return 'można głosować tylko na kogoś z komórki';
    }
    if (e.votes.containsKey(card)) {
      return 'już głosował(a)';
    }
    e.votes[card] = choice;
    if (e.votes.length >= cards.length) {
      _closeElection(e, r.at);
    }
    return null;
  }

  void _closeElection(PyrElection e, int at) {
    _cause = e.id;
    _causeAt = at;
    e.closed = true;
    final Map<String, int> counts = <String, int>{};
    for (final String c in e.votes.values) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    String? winner;
    for (final MapEntry<String, int> c in counts.entries) {
      if (c.value >= 2) {
        winner = c.key;
      }
    }
    e.winner = winner ?? e.head;
    if (winner == null ||
        winner == e.head ||
        occupant[e.cell] != e.head ||
        !_canRise(winner, at)) {
      history.add(
        PyrHistory(at, t('Głosowanie w komórce: szef zostaje'), e.id),
      );
      return;
    }
    final String? up = position[winner];
    if (up == null || PyrPath.parent(up) != e.cell || up == e.cell) {
      return;
    }
    final String head = occupant[e.cell]!;
    occupant[e.cell] = winner;
    occupant[up] = head;
    position[winner] = e.cell;
    position[head] = up;
    lastRise[winner] = at;
    _noteLevel(winner);
    _noteLevel(head);
    if (e.cell.isEmpty) {
      _termChange(at);
    }
    _noteHead(at);
    _noteTreasurers(at);
    history.add(
      PyrHistory(
        at,
        t('Głosowanie w komórce: nowy szef {name}', {'name': _name(winner)}),
        e.id,
      ),
    );
  }

  /// [d] and the delegations above it, up to the top's.
  List<PyrDelegation> _chainOf(PyrDelegation d) {
    final List<PyrDelegation> out = <PyrDelegation>[];
    PyrDelegation? x = d;
    while (x != null && out.length < 50 && !out.contains(x)) {
      out.add(x);
      x = x.parent == null ? null : delegations[x.parent];
    }
    return out;
  }

  /// Whether the signers of [r] can act with [power] on [targetPath]
  /// through delegation [via]: the holder signed, the whole chain
  /// is in force (not revoked, not expired, every holder still in the
  /// pyramid), the target is in scope, and no limit on the way up is used
  /// up. An act dated before a revocation on the way up counts only when
  /// that revocation listed it (otherwise it was made up later).
  /// Records no use; [_use] does once the act counts.
  bool _canUse(String via, String power, String targetPath, PyramidRecord r) {
    final PyrDelegation? d = delegations[via];
    if (d == null ||
        !r.signers.contains(d.to) ||
        d.power != power ||
        !_validChain(d, r.at)) {
      return false;
    }
    if (_chainOf(
      d,
    ).any((PyrDelegation x) => _witnessed[x.id]?.contains(r.id) == false)) {
      _lateHit.add(r.id);
      return false;
    }
    if (!PyrPath.within(targetPath, d.scope)) {
      return false;
    }
    const int month = 30 * 24 * 3600 * 1000;
    for (final PyrDelegation x in _chainOf(d)) {
      if (x.limit > 0 &&
          x.uses.where((int u) => r.at - u < month).length >= x.limit) {
        return false;
      }
    }
    return true;
  }

  /// Notes an act through [via]: one use of every limit on the way up
  /// (unless it does not [count]), and the act itself for revocations.
  void _use(String via, PyramidRecord r, {bool count = true}) {
    final PyrDelegation? d = delegations[via];
    if (d == null) {
      return;
    }
    if (count) {
      for (final PyrDelegation x in _chainOf(d)) {
        x.uses.add(r.at);
      }
    }
    d.acts[r.id] = r.at;
  }

  bool _validChain(PyrDelegation d, int at) {
    PyrDelegation? x = d;
    int guard = 0;
    while (x != null && guard++ < 50) {
      // A holder who left the pyramid (or was removed) cannot use it, nor
      // anything passed on from it.
      if (x.revoked || at > x.until || !isMember(x.to)) {
        return false;
      }
      if (x.parent == null) {
        return true;
      }
      x = delegations[x.parent];
    }
    return false;
  }

  static const Set<String> powers = <String>{
    'ban',
    'pause',
    'content',
    'reports',
    'alarm',
    // Posts to the whole pyramid: only the head gives it ([_delegate]).
    'posts',
  };

  String? _delegate(PyramidRecord r) {
    final String power = r.str('power');
    final String to = r.str('to');
    final String scope = r.str('scope');
    final String? parent = r.body['parent'] is String
        ? r.body['parent'] as String
        : null;
    if (!powers.contains(power) || !isMember(to) || !PyrPath.valid(scope)) {
      return 'złe uprawnienie';
    }
    final int until = r.integer('until');
    final Object? rawLimit = r.body['limit'];
    // 0 = no limit; anything else must be a real count.
    if ((rawLimit != null && rawLimit is! int) ||
        r.integer('limit') < 0 ||
        until <= r.at) {
      return 'zły limit albo termin';
    }
    final int limit = r.integer('limit');
    if (power == 'posts') {
      // Writing to the whole pyramid is the head's: the head alone gives
      // it, to the whole pyramid, never to be passed on.
      final String? chief = occupant[''];
      if (parent != null ||
          scope.isNotEmpty ||
          r.body['sub'] == true ||
          chief == null ||
          !r.signers.contains(chief)) {
        return 'pisanie do całej piramidy deleguje tylko szef';
      }
    } else if (parent == null) {
      if (!_twoOfTop(r)) {
        return 'deleguje szczyt (2 z 3)';
      }
    } else {
      final PyrDelegation? p = delegations[parent];
      if (p == null ||
          !p.sub ||
          !r.signers.contains(p.to) ||
          p.power != power ||
          !_validChain(p, r.at)) {
        return 'nie można delegować dalej';
      }
      // Never wider: inside the scope, no later, and under a limited
      // delegation a limited one (its uses count against the parent's too).
      if (!PyrPath.within(scope, p.scope) ||
          until > p.until ||
          (p.limit > 0 && (limit < 1 || limit > p.limit))) {
        return 'szerzej niż własna delegacja';
      }
    }
    delegations[r.id] = PyrDelegation(
      id: r.id,
      issuer: r.signers,
      to: to,
      power: power,
      scope: scope,
      limit: limit,
      until: until,
      sub: r.body['sub'] == true,
      parent: parent,
      at: r.at,
    );
    history.add(
      PyrHistory(
        r.at,
        t('Delegacja „{power}” dla {name}', {
          'power': power,
          'name': _name(to),
        }),
        r.id,
      ),
    );
    return null;
  }

  String? _ban(PyramidRecord r) {
    final String target = r.str('target');
    final String kind = r.str('kind');
    final String? via = r.body['via'] is String
        ? r.body['via'] as String
        : null;
    const Map<String, List<String>> needs = <String, List<String>>{
      'perm': <String>['ban'],
      'noadmit': <String>['ban'],
      'pause': <String>['pause', 'ban'],
      'content': <String>['content', 'ban'],
      'dating': <String>['content', 'ban'],
    };
    final List<String>? need = needs[kind];
    if (need == null) {
      return 'zły rodzaj bana';
    }
    final String targetPath = position[target] ?? '';
    bool allowed = _twoOfTop(r);
    bool delegated = false;
    if (!allowed && via != null) {
      final PyrDelegation? d = delegations[via];
      if (d != null &&
          need.contains(d.power) &&
          _canUse(via, d.power, targetPath, r)) {
        allowed = true;
        delegated = true;
      }
    }
    if (!allowed) {
      return 'banuje szczyt albo delegat w swoim zakresie';
    }
    // Immunity: the higher levels need their own cell.
    final String? p = position[target];
    if (p != null &&
        p.length < params.immunityDepth &&
        kind != 'content' &&
        kind != 'dating') {
      final List<String> cell = ownCellOf(target);
      if (_countOf(r.signers, cell) < min(2, cell.length)) {
        return 'immunitet: potrzebna zgoda komórki tej osoby';
      }
    }
    // The top itself: 2 of 3 of the top and most of level 2 (a ban of one
    // piece of content is not a ban of the person).
    if (p != null &&
        p.length <= 1 &&
        kind != 'content' &&
        !_topImmunityHolds(r.signers)) {
      return 'szczyt: potrzebne 2 z 3 szczytu i większość poziomu 2';
    }
    if (delegated) {
      // Counted only once the ban counts (a refused one uses nothing up).
      _use(via!, r);
    }
    final String? rep = r.body['rep'] is String && r.str('rep').length <= 64
        ? r.str('rep')
        : null;
    if (target.isNotEmpty && members.containsKey(target)) {
      // Appealed above whoever decided: the top reconsiders its own, a
      // delegate's goes to the head above the delegate.
      final String decider = delegated
          ? position[delegations[via]?.to] ?? ''
          : '';
      matters[r.id] = PyrMatter(
        id: r.id,
        kind: PyrMatterKind.ban,
        party: target,
        parties: <String>{target},
        decider: decider,
        step: -1,
        at: r.at,
      );
    }
    bans[r.id] = PyrBan(
      rep: rep,
      id: r.id,
      target: target,
      kind: kind,
      at: r.at,
      until: r.body['until'] is int ? r.body['until'] as int : null,
      datingKey: r.body['dk'] is String ? r.body['dk'] as String : null,
      reason: _clip(r.str('reason'), 500),
      entryId:
          r.body['eid'] is String && (r.body['eid'] as String).length <= 128
          ? r.body['eid'] as String
          : null,
    );
    history.add(
      PyrHistory(
        r.at,
        target.isEmpty
            ? t('Ban ({kind}) dla treści', {'kind': kind})
            : t('Ban ({kind}) dla {name}', {
                'kind': kind,
                'name': _name(target),
              }),
        r.id,
      ),
    );
    return null;
  }

  /// A referendum on any question, asked only by the top (2 of 3), to the
  /// whole pyramid, a branch or a nationality. It binds nothing: its
  /// result is published and the top decides.
  String? _referendum(PyramidRecord r) {
    final Map<dynamic, dynamic> scope = r.body['scope'] is Map
        ? r.body['scope'] as Map
        : const <String, dynamic>{};
    final String kind = scope['k'] is String ? scope['k'] as String : 'all';
    final String path = scope['p'] is String ? scope['p'] as String : '';
    final String nat = scope['nat'] is String ? scope['nat'] as String : '';
    final List<String> opts = r.body['opts'] is List
        ? (r.body['opts'] as List)
              .whereType<String>()
              .map((String o) => _clip(o, 200))
              .toList()
        : const <String>[];
    if (opts.length < 2 ||
        opts.length > kPyrMaxReferendumOptions ||
        r.integer('end') < r.at + kPyrMinReferendumMs) {
      return 'złe referendum (2–6 opcji, co najmniej 2 min)';
    }
    if (kind == 'branch' && !PyrPath.valid(path)) {
      return 'zły zasięg';
    }
    if (!_twoOfTop(r)) {
      return 'referendum ogłasza szczyt (2 z 3)';
    }
    referenda[r.id] = PyrReferendum(
      id: r.id,
      question: _clip(r.str('q'), 1000),
      options: opts,
      scopeKind: kind,
      scopePath: path,
      scopeNat: nat,
      end: r.integer('end'),
      at: r.at,
    );
    return null;
  }

  /// Whether the cell head at [p] holds the vote of the root of [root]'s
  /// count: the root's first child (the root passes its vote down), or the
  /// root itself when nobody is under it.
  bool _holdsRootVote(String p, String root) {
    final List<String> kids = <String>[
      for (final String c in PyrPath.children(root))
        if (occupant[c] != null) c,
    ];
    return kids.isEmpty ? p == root : p == kids.first;
  }

  /// A cell head's sum of its branch. Checkable against the sums
  /// below: only after the end; whole numbers, none above the branch; the
  /// newest sum of every branch right below (a branch with people under it
  /// may be missing only after [kPyrTallyGraceMs]); each counted once; at
  /// most one vote more per direct member with a vote at the end
  /// ([canVote]), and the root's own vote where it was passed.
  String? _tally(PyramidRecord r) {
    final PyrReferendum? ref = referenda[r.str('ref')];
    final String k = r.signers.length == 1 ? r.signers.first : '';
    final String? p = position[k];
    if (ref == null || p == null) {
      return 'zła suma';
    }
    if (r.at < ref.end || r.at > ref.end + 7 * 24 * 3600 * 1000) {
      return 'suma poza czasem liczenia';
    }
    final String root = ref.scopeKind == 'branch' ? ref.scopePath : '';
    if (!PyrPath.within(p, root)) {
      return 'suma spoza zasięgu referendum';
    }
    final Object? rawCounts = r.body['counts'];
    if (rawCounts is! List || rawCounts.length != ref.options.length) {
      return 'zła liczba opcji';
    }
    final List<String> kidIds = r.body['kids'] is List
        ? (r.body['kids'] as List).whereType<String>().toList()
        : const <String>[];
    if (kidIds.length > 2 || kidIds.toSet().length != kidIds.length) {
      return 'powtórzona suma gałęzi';
    }
    final int cap = branchSize(p) + 1;
    final List<int> counts = <int>[];
    for (final Object? v in rawCounts) {
      if (v is! int || v < 0 || v > cap) {
        return 'zła suma';
      }
      counts.add(v);
    }
    final List<int> sum = List<int>.filled(counts.length, 0);
    final Set<String> kidPaths = <String>{};
    for (final String kid in kidIds) {
      final PyrTally? t = ref.tallies.values
          .where((PyrTally x) => x.id == kid)
          .firstOrNull;
      if (t == null ||
          PyrPath.parent(t.path) != p ||
          t.path == p ||
          !kidPaths.add(t.path) ||
          t.counts.length != sum.length) {
        return 'suma dziecka nie pasuje';
      }
      for (int i = 0; i < sum.length; i++) {
        sum[i] += t.counts[i];
      }
    }
    for (final String c in PyrPath.children(p)) {
      if (occupant[c] == null || kidPaths.contains(c)) {
        continue;
      }
      if (latestTally(ref, c) != null) {
        return 'brak najnowszej sumy gałęzi niżej';
      }
      final bool hasBranch = PyrPath.children(
        c,
      ).any((String g) => occupant[g] != null);
      if (hasBranch && r.at < ref.end + kPyrTallyGraceMs) {
        return 'czeka na sumę gałęzi niżej';
      }
    }
    // Only members met in person by 2 others vote.
    bool votes(String? key) => key != null && canVote(key, ref.end);
    final int directs = PyrPath.children(
      p,
    ).where((String c) => votes(occupant[c])).length;
    final int allowance =
        directs +
        (r.body['extra'] == true &&
                _holdsRootVote(p, root) &&
                votes(occupant[root])
            ? 1
            : 0);
    // Entry by entry, so no sum of huge numbers can wrap around.
    int extra = 0;
    for (int i = 0; i < counts.length; i++) {
      final int d = counts[i] - sum[i];
      if (d < 0) {
        return 'suma mniejsza niż sumy niżej';
      }
      if (d > allowance) {
        return 'zawyżona suma';
      }
      extra += d;
    }
    if (extra > allowance) {
      return 'zawyżona suma';
    }
    ref.tallies[k] = PyrTally(
      id: r.id,
      publisher: k,
      path: p,
      counts: counts,
      at: r.at,
      kids: kidIds,
    );
    return null;
  }

  /// A short, readable summary (simulator and debugging).
  String describe() {
    final List<String> paths = occupant.keys.toList()
      ..sort(
        (String a, String b) => a.length != b.length
            ? a.length.compareTo(b.length)
            : a.compareTo(b),
      );
    return jsonEncode(<String, String>{
      for (final String p in paths) p.isEmpty ? '·' : p: _name(occupant[p]!),
    });
  }
}
