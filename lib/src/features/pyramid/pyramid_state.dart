import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
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

/// After a new head takes the top, the old power key has this long to
/// sign the handover; from then on most of the top cell may sign it
/// instead ([PyrT.handover]).
const int kPyrHandoverWaitMs = 72 * 3600 * 1000;

/// The rules in numbers. Changed by the top, 2 of 3, with a signed
/// record ([PyrT.constitution]) that applies [kPyrParamsDelayMs] later —
/// never past the hard limits in [apply].
final class PyrParams {
  PyrParams({
    this.version = 1,
    this.absenceDays = 60,
    this.immunityDepth = 3,
    this.treasurerDepth = 3,
    this.emitLimit = 100000000,
    this.emitDelayHours = 24,
    this.nationalMin = 100,
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
  /// Once per term before: a swap at the top started a new term
  /// and with it a fresh limit.
  int emitLimit;
  int emitDelayHours;

  /// People of a nationality needed in a branch to lead its section.
  int nationalMin;
  int electionHours;
  int reportEscalateHours;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'absenceDays': absenceDays,
    'immunityDepth': immunityDepth,
    'treasurerDepth': treasurerDepth,
    'emitLimit': emitLimit,
    'emitDelayHours': emitDelayHours,
    'nationalMin': nationalMin,
    'electionHours': electionHours,
    'reportEscalateHours': reportEscalateHours,
  };

  /// Takes the fields of [json] it knows, each clamped to its hard
  /// limits, whatever the top signs ([version] only counts the changes).
  void apply(Object? json) {
    if (json is! Map) {
      return;
    }
    int v(String k, int old, int lo, int hi) =>
        json[k] is int ? (json[k] as int).clamp(lo, hi) : old;
    absenceDays = v('absenceDays', absenceDays, 7, 3650);
    immunityDepth = v('immunityDepth', immunityDepth, 0, 30);
    treasurerDepth = v('treasurerDepth', treasurerDepth, 1, 6);
    emitLimit = v('emitLimit', emitLimit, 0, kPyrMaxAmount);
    emitDelayHours = v('emitDelayHours', emitDelayHours, 1, 24 * 30);
    nationalMin = v('nationalMin', nationalMin, 1, 1 << 30);
    electionHours = v('electionHours', electionHours, 1, 24 * 30);
    reportEscalateHours = v(
      'reportEscalateHours',
      reportEscalateHours,
      1,
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
  bool active = true;
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
  });

  final String id;
  final String target;

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
  });

  final String id;
  final String author;
  final String text;

  /// The author's level when it was written.
  final int level;
  final int at;
  final String? nat;
  final List<PyrComment> comments = <PyrComment>[];
}

final class PyrComment {
  PyrComment({
    required this.id,
    required this.author,
    required this.text,
    required this.at,
  });

  final String id;
  final String author;
  final String text;
  final int at;
}

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
    required this.to,
    required this.amount,
    required this.why,
    required this.term,
    required this.at,
    required this.signedAt,
    required this.effectiveAt,
    required this.signers,
    this.vetoers = const <String>[],
  });

  final String id;
  final String to;
  final int amount;
  final String why;
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

/// Money of one account, by term: spent oldest first.
final class PyrAccount {
  final List<List<int>> buckets = <List<int>>[];
  int seq = 0;

  int get balance => buckets.fold(0, (int a, List<int> b) => pyrAdd(a, b[1]));

  void credit(int term, int amount) {
    if (amount <= 0) {
      return;
    }
    for (final List<int> b in buckets) {
      if (b[0] == term) {
        b[1] = pyrAdd(b[1], amount);
        return;
      }
    }
    buckets
      ..add(<int>[term, min(amount, kPyrMaxBalance)])
      ..sort((List<int> a, List<int> b) => a[0].compareTo(b[0]));
  }

  void creditAll(List<List<int>> parts) {
    for (final List<int> p in parts) {
      credit(p[0], p[1]);
    }
  }

  /// Takes [amount], oldest term first; returns the parts taken.
  List<List<int>> debit(int amount) {
    int left = amount;
    final List<List<int>> taken = <List<int>>[];
    for (final List<int> b in buckets) {
      if (left == 0) {
        break;
      }
      final int t = min(b[1], left);
      if (t > 0) {
        b[1] -= t;
        left -= t;
        taken.add(<int>[b[0], t]);
      }
    }
    buckets.removeWhere((List<int> b) => b[1] == 0);
    return taken;
  }
}

final class PyrEscrow {
  PyrEscrow({
    required this.id,
    required this.from,
    required this.to,
    required this.amount,
    required this.parts,
    required this.condBy,
    required this.until,
    this.memo = '',
    this.share = 0,
    this.hops = 0,
    this.hash,
    this.parent,
    this.at = 0,
  });

  final String id;

  /// When the money was put aside (no settlement may be dated before).
  final int at;

  /// Who paid (also for every later hop of an announcement: the money is
  /// still theirs until somebody keeps it, and comes back to them).
  final String from;
  final String to;
  final int amount;
  final List<List<int>> parts;
  final String condBy;
  final int until;
  final String memo;

  /// An announcement passed on through intermediaries: each one who
  /// accepts keeps [share] and may pass the rest on to one next person
  /// while [hops] > 0; 0 = an ordinary conditional payment.
  final int share;
  final int hops;

  /// Hash of the announcement's text, so nobody on the way can change it.
  final String? hash;

  /// The escrow of the hop before (announcements).
  final String? parent;
  bool? settled;

  /// What happened to the rest at settling (announcements): the escrow of
  /// the next hop, or null when it went back to the payer.
  String? next;

  bool get isChain => share > 0;
}

final class PyrTransferInfo {
  PyrTransferInfo({
    required this.id,
    required this.from,
    required this.to,
    required this.amount,
    required this.at,
    this.memo = '',
    this.conditional = false,
  });

  final String id;
  final String from;
  final String to;
  final int amount;
  final int at;
  final String memo;
  final bool conditional;
}

/// At most this many intermediaries pass one announcement on.
const int kMaxAdHops = 5;

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

  /// Anonymous vote requests per cell and key image (harassment counter).
  final Map<String, Map<String, int>> requestCounts =
      <String, Map<String, int>>{};
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
  final Map<String, PyrAccount> accounts = <String, PyrAccount>{};
  final Map<String, PyrEscrow> escrows = <String, PyrEscrow>{};
  final List<PyrTransferInfo> transfers = <PyrTransferInfo>[];

  /// "from|seq" → transfer id → treasurers who signed it.
  final Map<String, Map<String, Set<String>>> _ordersSigned =
      <String, Map<String, Set<String>>>{};

  /// Treasurers caught signing two orders with the same number.
  final Map<String, List<String>> cheaters = <String, List<String>>{};
  final List<PyrAlarm> alarms = <PyrAlarm>[];

  /// Member → kind → price (the highest of its levels, when it has
  /// levels: what somebody pays who cannot tell how well they know them).
  final Map<String, Map<String, int>> offers = <String, Map<String, int>>{};

  /// Member → kind → level ([kPriceLevels]) → price, for the kinds priced
  /// by acquaintance.
  final Map<String, Map<String, Map<String, int>>> offerLevels =
      <String, Map<String, Map<String, int>>>{};

  final List<PyrHistory> history = <PyrHistory>[];

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

  // ---- reading ----

  String? get head => occupant[''];
  List<String> get topCell => <String>[
    for (final String p in <String>['', '0', '1'])
      if (occupant[p] != null) occupant[p]!,
  ];

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
  List<String> get treasurers => <String>[
    for (final MapEntry<String, String> e in occupant.entries)
      if (e.key.length <= params.treasurerDepth) e.value,
  ]..sort();

  int get treasurerMajority => treasurers.length ~/ 2 + 1;

  /// Who leads the national section of [nat], if anybody: the
  /// highest member of [nat] whose branch has at least
  /// [PyrParams.nationalMin] of them, then the bigger branch, then the
  /// earlier place. One pass over the tree (not one per member).
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
      if (count < params.nationalMin) {
        continue;
      }
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

  PyrAccount account(String key) => accounts[key] ??= PyrAccount();

  int balanceOf(String key) => accounts[key]?.balance ?? 0;

  /// The price [key] asks for [kind] from someone of [level] (null = not
  /// offered, 0 = free). Unknown level → the highest price.
  int? priceFor(String key, String kind, String? level) {
    final Map<String, int>? levels = offerLevels[key]?[kind];
    if (level != null && levels != null && levels[level] != null) {
      return levels[level];
    }
    return offers[key]?[kind];
  }

  /// Only the owner of [account] spends from it.
  bool canSpend(String account, Iterable<String> signers) =>
      account.isNotEmpty && signers.contains(account);

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

  /// Folds [records] (already checked: every listed signer signed, and
  /// [treasurerSigs] holds the treasurer signatures that verified).
  ///
  /// Records are applied in the order of their own time. Nothing can make
  /// a phone's clock the judge of somebody else's record (that would split
  /// the phones), so the fold adds witnesses where the time matters:
  /// - a revocation works from its time on and lists the acts of the
  ///   delegate it knew about; an act dated before the revocation but not
  ///   on its list was made up later and does not count (a second pass);
  /// - money waits for most treasurers, who sign only fresh orders and one
  ///   settlement per payment;
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
    Map<String, Set<String>> treasurerSigs = const <String, Set<String>>{},
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
      treasurerSigs,
      const <String, Set<String>>{},
      const <String>{},
      times,
    );
    final Map<String, Set<String>> witnessed = s._witnessIfLate();
    if (witnessed.isNotEmpty) {
      s = _runClean(
        pyramidId,
        list,
        now,
        treasurerSigs,
        witnessed,
        s._poison,
        times,
      );
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
    Map<String, Set<String>> treasurerSigs,
    Map<String, Set<String>> witnessed,
    Set<String> poison,
    Map<String, int> times,
  ) {
    Set<String> bad = poison;
    int round = 0;
    while (true) {
      final PyramidState s = _run(
        pyramidId,
        list,
        now,
        treasurerSigs,
        witnessed,
        bad,
        times,
      );
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
    Map<String, Set<String>> treasurerSigs,
    Map<String, Set<String>> witnessed,
    Set<String> poison,
    Map<String, int> times,
  ) {
    final PyramidState s = PyramidState._(pyramidId)
      .._witnessed = witnessed
      .._poison = poison
      .._times = times;
    // Proposals already counted (content without the time): a fresh copy
    // of one, signed again late, counts once.
    final Set<String> proposalsDone = <String>{};
    for (final PyramidRecord r in list) {
      final int at = times[r.id] ?? r.at;
      s._clock = at;
      s._timedUpTo(at);
      final String? proposal = r.body['pn'] is String ? r.contentKey : null;
      if (proposal != null && proposalsDone.contains(proposal)) {
        s.rejected[r.id] = 'ta propozycja już weszła (inna kopia)';
        continue;
      }
      if (poison.contains(r.id)) {
        // It threw in an earlier round: refused before anything
        // of it happened.
        s.rejected[r.id] = 'błędny rekord';
        continue;
      }
      String? why;
      try {
        why = s._apply(r, treasurerSigs[r.id] ?? const <String>{});
        debugAfterApply?.call(r);
      } on Object {
        // A malformed record never breaks the pyramid: it does not count,
        // the same way on every phone.
        why = 'błędny rekord';
        s._threw.add(r.id);
      }
      s._noteHead(at);
      if (why == null) {
        if (proposal != null) {
          proposalsDone.add(proposal);
        }
        s.applied.add(r.id);
        for (final String k in r.signers) {
          s.lastSeen[k] = max(s.lastSeen[k] ?? 0, r.at);
        }
      } else {
        s.rejected[r.id] = s._lateHit.contains(r.id)
            ? 'akt z cofniętej delegacji, dopisany po jej cofnięciu'
            : why;
      }
    }
    s._timedUpTo(now);
    return s;
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
      e.done = true;
      account(e.to).credit(e.term, e.amount);
      history.add(
        PyrHistory(
          e.effectiveAt,
          t('Emisja {amount} dla {name}', {
            'amount': pyrMoney(e.amount),
            'name': _name(e.to),
          }),
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
      params
        ..apply(c.params)
        ..version += 1;
      _natLead.clear();
      history.add(
        PyrHistory(
          c.effectiveAt,
          t('Nowe zasady (wersja {version})', {'version': params.version}),
          c.id,
        ),
      );
    }
  }

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
  String? _pqMismatch(PyramidRecord r, Set<String> tsigs) {
    for (final String k in r.sigs.keys) {
      final String? want = _pqOf(k);
      if (want != null && r.pqIdOf(k) != want) {
        return 'podpis innym kluczem ML-DSA niż klucz osoby';
      }
    }
    for (final String k in tsigs) {
      final String? want = _pqOf(k);
      if (want != null && r.pqIdOf(k, treasurer: true) != want) {
        return 'podpis skarbnika innym kluczem ML-DSA';
      }
    }
    return null;
  }

  /// Applies one record; returns why it does not count, or null.
  String? _apply(PyramidRecord r, Set<String> tsigs) {
    final Map<String, dynamic> b = r.body;
    final List<String> by = r.signers;
    final String? keyMismatch = _pqMismatch(r, tsigs);
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
        params.apply(b['params']);
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
        _swap(cell, upPath, r);
        return null;
      case PyrT.voteRequest:
        return _voteRequest(r);
      case PyrT.vote:
        return _vote(r);
      case PyrT.leave:
        final String k = r.str('k');
        final String? p = position[k];
        if (p == null || !(by.length == 1 && by.first == k)) {
          return 'nie ma kogo';
        }
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
        _vacate(upPath);
        _place(up, cell, r.id);
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
        if (b['branch'] == true && below.isNotEmpty) {
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
        m.addr = _clip(r.str('addr'), 300);
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
            d.parent != null && by.contains(delegations[d.parent]?.to);
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
        posts[r.id] = PyrPost(
          id: r.id,
          author: k,
          text: _clip(r.str('text'), 5000),
          level: r.integer('lvl'),
          at: r.at,
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
        post.comments.add(
          PyrComment(
            id: r.id,
            author: k,
            text: _clip(r.str('text'), 2000),
            at: r.at,
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
        final String to = r.str('to');
        if (!_twoOfTop(r) || amount <= 0 || to.isEmpty) {
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
          to: to,
          amount: amount,
          why: _clip(r.str('why'), 500),
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
        return _transfer(r, tsigs);
      case PyrT.settle:
        final PyrEscrow? e = escrows[r.str('x')];
        if (e == null || e.settled != null) {
          return 'nie ma czego rozliczyć';
        }
        if (r.at < e.at) {
          return 'rozliczenie sprzed płatności';
        }
        final bool ok = b['ok'] == true;
        final bool byCond = by.contains(e.condBy);
        final bool refundByPayer =
            !ok && canSpend(e.from, by) && r.at >= e.until;
        if (!byCond && !refundByPayer) {
          return 'rozlicza odbiorca warunku albo płacący po terminie';
        }
        // Like a transfer: most treasurers sign it, and an honest one signs
        // one settlement per payment — so a late acceptance dated before a
        // refund (or the other way round) cannot get in.
        _evidence('x|${e.id}', r.id, tsigs);
        final int validT = tsigs.where(treasurers.contains).length;
        if (validT < treasurerMajority) {
          return 'za mało podpisów skarbników ($validT z ${treasurers.length})';
        }
        e.settled = ok;
        if (!ok) {
          account(e.from).creditAll(e.parts);
          return null;
        }
        if (!e.isChain) {
          account(e.to).creditAll(e.parts);
          return null;
        }
        _settleHop(e, r);
        return null;
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
    }
    return 'nieznany rodzaj';
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

  /// One intermediary of an announcement accepted: it keeps its
  /// share; the rest waits for the next person it names (who accepts or
  /// returns it), or goes back to the payer when there is nobody next.
  void _settleHop(PyrEscrow e, PyramidRecord r) {
    final int keep = min(e.share, e.amount);
    final List<List<int>> kept = <List<int>>[];
    final List<List<int>> rest = <List<int>>[];
    int left = keep;
    for (final List<int> p in e.parts) {
      final int t = min(left, p[1]);
      left -= t;
      if (t > 0) {
        kept.add(<int>[p[0], t]);
      }
      if (p[1] - t > 0) {
        rest.add(<int>[p[0], p[1] - t]);
      }
    }
    account(e.to).creditAll(kept);
    final int restAmount = e.amount - keep;
    if (restAmount <= 0) {
      return;
    }
    final String next = r.str('next');
    // Never back to anybody already on the way (no loops through the same
    // people collecting a share twice).
    if (e.hops > 0 &&
        next.isNotEmpty &&
        isMember(next) &&
        !_onChain(e, next) &&
        !escrows.containsKey(r.id)) {
      escrows[r.id] = PyrEscrow(
        id: r.id,
        at: r.at,
        from: e.from,
        to: next,
        amount: restAmount,
        parts: rest,
        condBy: next,
        until: r.at + 7 * 24 * 3600 * 1000,
        memo: e.memo,
        share: e.share,
        hops: e.hops - 1,
        hash: e.hash,
        parent: e.id,
      );
      e.next = r.id;
      return;
    }
    account(e.from).creditAll(rest);
  }

  /// Whether [key] paid for or already got a hop of the announcement [e].
  bool _onChain(PyrEscrow e, String key) {
    PyrEscrow? x = e;
    int guard = 0;
    while (x != null && guard++ < kMaxAdHops + 2) {
      if (x.to == key || x.from == key) {
        return true;
      }
      x = x.parent == null ? null : escrows[x.parent];
    }
    return false;
  }

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
    return PyrMember(
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

  static String voteRequestContext(String pyramid, String cell, String head) =>
      'vreq|$pyramid|$cell|$head';

  static String voteContext(String election) => 'vote|$election';

  static Uint8List _key(String b64key) =>
      unb64(b64key, length: 32) ?? Uint8List(32);

  String? _voteRequest(PyramidRecord r) {
    final String cell = r.str('cell');
    final String head = r.str('head');
    final RingSignature? ring = r.ring;
    // The ring is the cell's members who vote ([canVote]).
    final List<String> members = cellVoters(cell, r.at);
    final List<String> claimed = r.body['ring'] is List
        ? (r.body['ring'] as List).whereType<String>().toList()
        : const <String>[];
    if (ring == null || occupant[cell] != head || members.length < 2) {
      return 'zła komórka';
    }
    if (!(claimed.length == members.length &&
        claimed.toSet().containsAll(members))) {
      return 'pierścień to nie głosujący tej komórki';
    }
    if (!ring.verify(
      ring: claimed.map(_key).toList(),
      context: voteRequestContext(id, cell, head),
      message: r.signedBytes,
    )) {
      return 'zły podpis pierścieniowy';
    }
    // Key images are canonical (checked on parsing), so one person is one
    // entry here, whatever spelling they try.
    final Map<String, int> counter = requestCounts[cell] ??= <String, int>{};
    counter[ring.keyImage] = (counter[ring.keyImage] ?? 0) + 1;
    final bool open = elections.values.any(
      (PyrElection e) => e.cell == cell && !e.closed,
    );
    if (!open) {
      elections[r.id] = PyrElection(
        id: r.id,
        cell: cell,
        head: head,
        ring: claimed,
        deadline: r.at + params.electionHours * 3600 * 1000,
        start: r.at,
      );
      history.add(
        PyrHistory(r.at, t('Ktoś z komórki zażądał nowego głosowania'), r.id),
      );
    }
    return null;
  }

  String? _vote(PyramidRecord r) {
    final PyrElection? e = elections[r.str('elect')];
    final RingSignature? ring = r.ring;
    final String choice = r.str('choice');
    if (e == null || e.closed || ring == null || r.at < e.start) {
      return 'głosowanie zamknięte';
    }
    if (!e.ring.contains(choice)) {
      return 'można głosować tylko na kogoś z komórki';
    }
    // One vote per key image (canonical, so no second spelling of it).
    if (e.votes.containsKey(ring.keyImage)) {
      return 'już głosował(a)';
    }
    if (!ring.verify(
      ring: e.ring.map(_key).toList(),
      context: voteContext(e.id),
      message: r.signedBytes,
    )) {
      return 'zły podpis pierścieniowy';
    }
    e.votes[ring.keyImage] = choice;
    if (e.votes.length >= e.ring.length) {
      _closeElection(e, r.at);
    }
    return null;
  }

  void _closeElection(PyrElection e, int at) {
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
    if (winner == null || winner == e.head || occupant[e.cell] != e.head) {
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
    _noteLevel(winner);
    _noteLevel(head);
    if (e.cell.isEmpty) {
      _termChange(at);
    }
    _noteHead(at);
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
    if (parent == null) {
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
    if (delegated) {
      // Counted only once the ban counts (a refused one uses nothing up).
      _use(via!, r);
    }
    bans[r.id] = PyrBan(
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

  /// Evidence of a treasurer signing two orders for one [slot].
  void _evidence(String slot, String recordId, Set<String> tsigs) {
    final Map<String, Set<String>> signed = _ordersSigned[slot] ??=
        <String, Set<String>>{};
    signed[recordId] = tsigs;
    for (final MapEntry<String, Set<String>> other in signed.entries) {
      if (other.key == recordId) {
        continue;
      }
      for (final String t in tsigs.intersection(other.value)) {
        (cheaters[t] ??= <String>[]).addAll(<String>[other.key, recordId]);
      }
    }
  }

  String? _transfer(PyramidRecord r, Set<String> tsigs) {
    final String from = r.str('from');
    final String to = r.str('to');
    final int amount = r.integer('amount');
    final int seq = r.integer('seq');
    if (amount <= 0 ||
        amount > kPyrMaxAmount ||
        seq <= 0 ||
        from.isEmpty ||
        to.isEmpty ||
        from == to) {
      return 'zły przelew';
    }
    if (!r.signers.contains(from)) {
      return 'brak podpisu płacącego';
    }
    // Evidence of a treasurer signing two orders with one number.
    _evidence('$from|$seq', r.id, tsigs);
    final List<String> current = treasurers;
    final int valid = tsigs.where(current.contains).length;
    if (valid < treasurerMajority) {
      return 'za mało podpisów skarbników ($valid z ${current.length})';
    }
    final PyrAccount acc = account(from);
    if (seq != acc.seq + 1) {
      return 'zły numer kolejny';
    }
    if (acc.balance < amount) {
      // Signed by most treasurers, but the money is no longer there (e.g.
      // an emission vetoed later): the number is used up all the same, so
      // the account is not stuck on an order nobody will sign again.
      acc.seq = seq;
      return 'za mało środków';
    }
    acc.seq = seq;
    final List<List<int>> parts = acc.debit(amount);
    final Object? cond = r.body['cond'];
    if (cond is Map && cond['by'] is String) {
      // An announcement through intermediaries: the share must fit.
      final int share = cond['share'] is int
          ? (cond['share'] as int).clamp(0, amount)
          : 0;
      final int hops = cond['hops'] is int
          ? (cond['hops'] as int).clamp(0, kMaxAdHops - 1)
          : 0;
      escrows[r.id] = PyrEscrow(
        id: r.id,
        at: r.at,
        from: from,
        to: to,
        amount: amount,
        parts: parts,
        condBy: cond['by'] as String,
        until: cond['until'] is int
            ? cond['until'] as int
            : r.at + 7 * 24 * 3600 * 1000,
        memo: _clip(r.str('memo'), 300),
        share: share,
        hops: share > 0 ? hops : 0,
        hash: cond['h'] is String ? cond['h'] as String : null,
      );
    } else {
      account(to).creditAll(parts);
    }
    transfers.add(
      PyrTransferInfo(
        id: r.id,
        from: from,
        to: to,
        amount: amount,
        at: r.at,
        memo: _clip(r.str('memo'), 300),
        conditional: cond is Map,
      ),
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
