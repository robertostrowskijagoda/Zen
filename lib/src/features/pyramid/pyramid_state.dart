import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';

/// A constitutional referendum lasts at least this long (§21.7), whatever
/// the rules say: the rules cannot shorten the vote that changes them.
const int kPyrMinConstitutionMs = 72 * 3600 * 1000;

/// Any other referendum or poll binds nothing (§21.3), so it may be short —
/// but never so short that it closes before anyone could see it.
const int kPyrMinReferendumMs = 2 * 60 * 1000;

/// After a referendum ends, a cell head waits this long for the sum of a
/// branch below before counting without it; new rules are applied no
/// sooner either (§21.3).
const int kPyrTallyGraceMs = 6 * 3600 * 1000;

/// The emission limit counts the emissions of this rolling window (§23.4),
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

/// 12345 → "123,45": money for people (Polish style, thousands grouped
/// with a non-breaking space).
String pyrMoney(int hundredths) {
  final bool neg = hundredths < 0;
  final int v = hundredths.abs();
  final String whole = (v ~/ 100).toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (Match m) => '\u00a0',
  );
  final String s = '$whole,${(v % 100).toString().padLeft(2, '0')}';
  return neg ? '-$s' : s;
}

/// The largest numerator or denominator of an exchange rate.
const int kPyrMaxRate = 1000000000;

/// [amount] at the rate [numer]/[denom], rounded down, at most
/// [kPyrMaxAmount] (worked out in big integers, so nothing wraps).
int pyrConvert(int amount, int numer, int denom) {
  if (amount <= 0 || numer <= 0 || denom <= 0) {
    return 0;
  }
  final BigInt v =
      BigInt.from(amount) * BigInt.from(numer) ~/ BigInt.from(denom);
  return v > BigInt.from(kPyrMaxAmount) ? kPyrMaxAmount : v.toInt();
}

/// What has to be paid at the rate [numer]/[denom] so that [pyrConvert]
/// gives at least [target] (rounded up, at most [kPyrMaxAmount]).
int pyrConvertUp(int target, int numer, int denom) {
  if (target <= 0 || numer <= 0 || denom <= 0) {
    return 0;
  }
  final BigInt v =
      (BigInt.from(target) * BigInt.from(denom) + BigInt.from(numer - 1)) ~/
      BigInt.from(numer);
  return v > BigInt.from(kPyrMaxAmount) ? kPyrMaxAmount : v.toInt();
}

/// Whether [pre] opens the lock [lock] of an exchange payment: the lock is
/// the SHA-256 (hex) of the key's UTF-8 bytes.
bool pyrUnlocks(String lock, String pre) =>
    pre.isNotEmpty && pre.length <= 128 && sha256Hex(utf8.encode(pre)) == lock;

/// A lock as the payments carry it: 64 lowercase hex digits.
bool pyrIsLock(Object? v) =>
    v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v);

/// Why the condition [cond] of a payment is malformed, or null. A lock
/// ('hl') makes it an exchange payment (§23.5): it is never passed on
/// through intermediaries, and its 'fx' part says what the exchanger pays
/// out in the other pyramid.
String? pyrCondProblem(Object? cond) {
  if (cond is! Map) {
    return null;
  }
  final Object? lock = cond['hl'];
  if (lock == null) {
    return null;
  }
  if (!pyrIsLock(lock) || cond['by'] is! String) {
    return 'zła blokada wymiany';
  }
  if (cond['share'] is int && (cond['share'] as int) > 0) {
    return 'wymiana nie idzie przez pośredników';
  }
  final Object? fx = cond['fx'];
  if (fx != null &&
      (fx is! Map ||
          fx['py'] is! String ||
          (fx['py'] as String).length > 100 ||
          !PyramidRecord.isCanonicalKey(fx['to']) ||
          fx['a'] is! int ||
          (fx['a'] as int) <= 0 ||
          (fx['a'] as int) > kPyrMaxAmount)) {
    return 'zła wymiana';
  }
  return null;
}

/// The rules in numbers (§21.7). Changed only by a referendum of the whole
/// pyramid ([PyrT.constitution]).
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

  /// Members above this depth need their own cell's consent to be banned
  /// (§21.1a).
  int immunityDepth;

  /// Positions up to this depth are the treasurers (§23.1): 3 → 15 people.
  int treasurerDepth;

  /// Emission allowed per 30 days ([kPyrEmitWindowMs]), in hundredths
  /// (§23.4). Once per term before: a swap at the top started a new term
  /// and with it a fresh limit.
  int emitLimit;
  int emitDelayHours;

  /// People of a nationality needed in a branch to lead its section (§22.2).
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

  void apply(Object? json) {
    if (json is! Map) {
      return;
    }
    int v(String k, int old, int lo, int hi) =>
        json[k] is int ? (json[k] as int).clamp(lo, hi) : old;
    version = v('version', version, 1, 1 << 30);
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

/// Someone in the pyramid, under their pyramid pseudonym (§6.4).
final class PyrMember {
  PyrMember({
    required this.key,
    required this.name,
    required this.nat,
    required this.dataCommit,
    required this.joinedAt,
    this.admittedBy,
    this.addr = '',
  });

  final String key;
  final String name;

  /// Nationality, confirmed at entry by the one who admitted (§20.2a).
  final String nat;

  /// Hash of birth year + gender + salt: public, the data itself is not.
  final String dataCommit;
  final int joinedAt;
  final String? admittedBy;

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
  /// them it knew about (§21.2).
  final Map<String, int> acts = <String, int>{};
}

final class PyrBan {
  PyrBan({
    required this.id,
    required this.target,
    required this.kind,
    required this.at,
    this.until,
    this.hash,
    this.datingKey,
    this.reason = '',
  });

  final String id;
  final String target;

  /// perm, pause, content, noadmit, dating.
  final String kind;
  final int at;
  final int? until;
  final String? hash;
  final String? datingKey;
  final String reason;
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

  /// The author's level when it was written (§22.1).
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
    required this.kind,
    required this.at,
    this.params,
  });

  final String id;
  final String question;

  /// New rules a constitution referendum votes on (§21.7).
  final Map<String, dynamic>? params;
  final List<String> options;

  /// all, branch, nat.
  final String scopeKind;
  final String scopePath;
  final String scopeNat;
  final int end;

  /// normal or constitution.
  final String kind;
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
    required this.effectiveAt,
    required this.signers,
    this.vetoers = const <String>[],
    this.group,
  });

  final String id;
  final String to;
  final int amount;
  final String why;
  final int term;
  final int at;
  final int effectiveAt;
  final List<String> signers;

  /// Who may veto it: the rest of the top when it was signed (§23.4). They
  /// keep the right for the whole wait, even if moved away meanwhile.
  final List<String> vetoers;

  /// The merge record this is a part of: money of a joining pyramid,
  /// converted (§20.5). One veto stops every part.
  final String? group;
  bool vetoed = false;
  bool done = false;
}

/// Money of one account, by term (§23.3): spent oldest first.
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
    this.lock,
    this.fxPy,
    this.fxTo,
    this.fxAmount = 0,
  });

  final String id;

  /// When the money was put aside (no settlement may be dated before).
  final int at;

  /// An exchange payment (§23.5): accepted only with the key whose hash
  /// this is. The same lock holds the payout in the other pyramid, so
  /// whoever takes that one shows the key that opens this one.
  final String? lock;

  /// What the exchanger is asked to pay out: in pyramid [fxPy], to
  /// [fxTo], [fxAmount] hundredths.
  final String? fxPy;
  final String? fxTo;
  final int fxAmount;

  /// The key that opened [lock] (once accepted).
  String? pre;

  /// Who paid (also for every later hop of an announcement: the money is
  /// still theirs until somebody keeps it, and comes back to them).
  final String from;
  final String to;
  final int amount;
  final List<List<int>> parts;
  final String condBy;
  final int until;
  final String memo;

  /// An announcement passed on through intermediaries (§24): each one who
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

/// A member's standing offer to exchange money of another pyramid: for
/// every [denom] hundredths received there, [numer] hundredths paid out
/// here, at most [max] per exchange (0 = no limit).
final class PyrFxRate {
  PyrFxRate({
    required this.numer,
    required this.denom,
    required this.max,
    required this.at,
  });

  final int numer;
  final int denom;
  final int max;
  final int at;

  /// What is paid out here for [amount] received there.
  int payout(int amount) => pyrConvert(amount, numer, denom);
}

/// At most this many intermediaries pass one announcement on (§24).
const int kMaxAdHops = 5;

/// Levels of acquaintance a price can depend on (§24), from the receiver's
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

/// One structural change, for the public history (§20.3).
final class PyrHistory {
  PyrHistory(this.at, this.text, this.recordId);

  final int at;
  final String text;
  final String recordId;
}

/// The pyramid as it follows from its records (§20.5): every client folds
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
  final Map<String, PyrReferendum> referenda = <String, PyrReferendum>{};
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

  /// Treasurers caught signing two orders with the same number (§23.4).
  final Map<String, List<String>> cheaters = <String, List<String>>{};
  final List<PyrAlarm> alarms = <PyrAlarm>[];

  /// Member → kind → price (the highest of its levels, when it has
  /// levels: what somebody pays who cannot tell how well they know them).
  final Map<String, Map<String, int>> offers = <String, Map<String, int>>{};

  /// Member → kind → level ([kPriceLevels]) → price, for the kinds priced
  /// by acquaintance (§24).
  final Map<String, Map<String, Map<String, int>>> offerLevels =
      <String, Map<String, Map<String, int>>>{};

  /// Member → other pyramid → the rate it pays out here for that
  /// pyramid's money ([PyrT.fxRate]).
  final Map<String, Map<String, PyrFxRate>> fxRates =
      <String, Map<String, PyrFxRate>>{};
  final List<PyrHistory> history = <PyrHistory>[];
  String? mergedInto;

  /// When this pyramid's money was counted for the pyramid it joined
  /// (§20.5): money records dated later do not count.
  int? mergeCut;

  /// Records that did not count, with the reason (for the curious and the
  /// simulator).
  final Map<String, String> rejected = <String, String>{};
  final Set<String> applied = <String>{};

  /// Revocations that said which acts they knew of: delegation id → when,
  /// and the acts (§21.2).
  final Map<String, ({int at, Set<String> acts})> _revokeLists =
      <String, ({int at, Set<String> acts})>{};

  /// Acts of delegates that do not count: dated before a revocation that
  /// did not know them, i.e. made up afterwards (second pass of [fold]).
  Set<String> _void = const <String>{};

  /// The top as it stands with every record but the closing ones: a
  /// pyramid is closed ([PyrT.merged]) only by 2 of that top, so a top
  /// already replaced cannot close it with a back-dated record.
  Set<String>? _finalTop;

  /// Who leads each national section, worked out once per shape of the
  /// tree (cleared on every move).
  final Map<String, String?> _natLead = <String, String?>{};

  /// Kinds of records that move money.
  static const Set<String> moneyKinds = <String>{
    PyrT.transfer,
    PyrT.settle,
    PyrT.emit,
  };

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
  /// immunity (§21.1a); for the head of the pyramid, the top cell.
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

  /// The treasurers now (§23.1).
  List<String> get treasurers => <String>[
    for (final MapEntry<String, String> e in occupant.entries)
      if (e.key.length <= params.treasurerDepth) e.value,
  ]..sort();

  int get treasurerMajority => treasurers.length ~/ 2 + 1;

  /// Who leads the national section of [nat] (§22.2), if anybody: the
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

  /// Banned from social features (posts, comments) now (§21.1a).
  bool silencedAt(String key, int t) => bans.values.any(
    (PyrBan b) =>
        b.target == key &&
        b.activeAt(t) &&
        (b.kind == 'perm' || b.kind == 'pause'),
  );

  Set<String> bannedContent(int t) => <String>{
    for (final PyrBan b in bans.values)
      if (b.kind == 'content' && b.hash != null && b.activeAt(t)) b.hash!,
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
      for (final String c in PyrPath.children(root)) {
        final PyrTally? kid = latestTally(r, c);
        if (kid != null && !best.kids.contains(kid.id)) {
          return null;
        }
      }
    }
    return best.counts;
  }

  /// Whether the constitutional referendum [refId] passed (§21.7): a full
  /// count, more than half of the members voted, and the first option
  /// ("Tak") got more than all the others together.
  bool constitutionPasses(String refId) {
    final List<int>? res = resultOf(refId, strict: true);
    if (res == null || res.length < 2) {
      return false;
    }
    final int total = res.fold(0, (int a, int b) => a + b);
    return total * 2 > position.length && res[0] * 2 > total;
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
  /// delegated from it (what a revocation lists as known, §21.2).
  Set<String> actsOf(String delegationId) {
    final Set<String> out = <String>{};
    for (final PyrDelegation d in delegations.values) {
      if (_chainOf(d).any((PyrDelegation x) => x.id == delegationId)) {
        out.addAll(d.acts.keys.where(applied.contains));
      }
    }
    return out;
  }

  /// Whether [key] votes in [r].
  bool eligible(PyrReferendum r, String key) {
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
  /// - a closing record ([PyrT.merged]) counts only when signed by 2 of the
  ///   top as it stands with every other record (a top already replaced
  ///   cannot close the pyramid by dating the closing before its fall);
  /// - a revocation lists the acts of the delegate it knew about; an act
  ///   dated before the revocation but not on its list was made up later
  ///   and does not count (a second pass);
  /// - money waits for most treasurers, who sign only fresh orders and one
  ///   settlement per payment (§23.2, §23.5);
  /// - a pyramid that joined another with its money closes with the time
  ///   its money was counted: money records dated later do not count, so
  ///   nothing is spent twice, here and converted there (a second pass).
  /// A record whose rule throws is skipped, never the whole pyramid.
  static PyramidState fold(
    String pyramidId,
    Iterable<PyramidRecord> records, {
    required int now,
    Map<String, Set<String>> treasurerSigs = const <String, Set<String>>{},
  }) {
    final List<PyramidRecord> list = <PyramidRecord>[
      for (final PyramidRecord r in records)
        if ((r.id == pyramidId || r.pyramid == pyramidId) &&
            r.at <= now + kPyrMaxSkewMs)
          r,
    ]..sort(_order);
    Set<String>? finalTop;
    if (list.any((PyramidRecord r) => r.type == PyrT.merged)) {
      finalTop = _run(
        pyramidId,
        <PyramidRecord>[
          for (final PyramidRecord r in list)
            if (r.type != PyrT.merged) r,
        ],
        now,
        treasurerSigs,
        const <String>{},
        null,
        const <String>{},
      ).topCell.toSet();
    }
    PyramidState s = _run(
      pyramidId,
      list,
      now,
      treasurerSigs,
      const <String>{},
      finalTop,
      const <String>{},
    );
    final Set<String> late = s._lateActs();
    final int? cut = s.mergedInto == null ? null : s.mergeCut;
    final Set<String> cutOff = <String>{
      if (cut != null)
        for (final PyramidRecord r in list)
          if (moneyKinds.contains(r.type) && r.at > cut) r.id,
    };
    if (late.isNotEmpty || cutOff.isNotEmpty) {
      s = _run(pyramidId, list, now, treasurerSigs, late, finalTop, cutOff);
    }
    return s;
  }

  /// Time, then the genesis, then the id (ids are worked out once).
  static int _order(PyramidRecord a, PyramidRecord b) {
    final int c = a.at.compareTo(b.at);
    if (c != 0) {
      return c;
    }
    final bool ga = a.type == PyrT.genesis;
    final bool gb = b.type == PyrT.genesis;
    if (ga != gb) {
      return ga ? -1 : 1;
    }
    return a.id.compareTo(b.id);
  }

  static PyramidState _run(
    String pyramidId,
    List<PyramidRecord> list,
    int now,
    Map<String, Set<String>> treasurerSigs,
    Set<String> voids,
    Set<String>? finalTop,
    Set<String> cutOff,
  ) {
    final PyramidState s = PyramidState._(pyramidId)
      .._void = voids
      .._finalTop = finalTop;
    // Proposals already counted (content without the time): a fresh copy
    // of one, signed again late (§20.5), counts once.
    final Set<String> proposalsDone = <String>{};
    for (final PyramidRecord r in list) {
      s._clock = r.at;
      s._timedUpTo(r.at);
      if (s.mergedInto != null) {
        s.rejected[r.id] = 'piramida połączona z inną';
        continue;
      }
      if (cutOff.contains(r.id)) {
        s.rejected[r.id] = 'po przeliczeniu pieniędzy przy połączeniu';
        continue;
      }
      final String? proposal = r.body['pn'] is String ? r.contentKey : null;
      if (proposal != null && proposalsDone.contains(proposal)) {
        s.rejected[r.id] = 'ta propozycja już weszła (inna kopia)';
        continue;
      }
      String? why;
      try {
        why = s._apply(r, treasurerSigs[r.id] ?? const <String>{});
      } on Object {
        // A malformed record never breaks the pyramid: it does not count,
        // the same way on every phone.
        why = 'błędny rekord';
      }
      if (why == null) {
        if (proposal != null) {
          proposalsDone.add(proposal);
        }
        s.applied.add(r.id);
        for (final String k in r.signers) {
          s.lastSeen[k] = max(s.lastSeen[k] ?? 0, r.at);
        }
      } else {
        s.rejected[r.id] = voids.contains(r.id)
            ? 'akt delegata spoza listy z cofnięcia (dopisany później)'
            : why;
      }
    }
    s._timedUpTo(now);
    return s;
  }

  /// Applied acts dated before a revocation of their delegation (or of one
  /// above it) that did not list them.
  Set<String> _lateActs() {
    final Set<String> out = <String>{};
    if (_revokeLists.isEmpty) {
      return out;
    }
    for (final PyrDelegation x in delegations.values) {
      final List<PyrDelegation> chain = _chainOf(x);
      for (final MapEntry<String, int> act in x.acts.entries) {
        if (!applied.contains(act.key)) {
          continue;
        }
        for (final PyrDelegation y in chain) {
          final ({int at, Set<String> acts})? list = _revokeLists[y.id];
          if (list != null &&
              act.value < list.at &&
              !list.acts.contains(act.key)) {
            out.add(act.key);
            break;
          }
        }
      }
    }
    return out;
  }

  /// Things that happen by time: elections end, emissions take effect.
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
          e.group == null
              ? t('Emisja {amount} dla {name}', {
                  'amount': pyrMoney(e.amount),
                  'name': _name(e.to),
                })
              : t('Przeliczenie po połączeniu: {amount} dla {name}', {
                  'amount': pyrMoney(e.amount),
                  'name': _name(e.to),
                }),
          e.id,
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

  /// Applies one record; returns why it does not count, or null.
  String? _apply(PyramidRecord r, Set<String> tsigs) {
    final Map<String, dynamic> b = r.body;
    final List<String> by = r.signers;
    switch (r.type) {
      case PyrT.genesis:
        if (r.id != id || occupant.isNotEmpty) {
          return 'zły początek';
        }
        final PyrMember? m = _memberFrom(b['founder'], r.at, null);
        if (m == null || by.length != 1 || by.first != m.key) {
          return 'zły założyciel';
        }
        name = r.str('name');
        params.apply(b['params']);
        members[m.key] = m;
        _place(m.key, '', r.id);
        termStart[1] = r.at;
        history.add(
          PyrHistory(
            r.at,
            t('Powstała piramida „{name}”', {'name': name}),
            r.id,
          ),
        );
        return null;
      case PyrT.admit:
        final String headKey = r.str('head');
        final String? headPath = position[headKey];
        final PyrMember? m = _memberFrom(b['m'], r.at, headKey);
        if (headPath == null || m == null) {
          return 'przyjmujący nie jest w piramidzie';
        }
        if (!(by.length == 2 && by.contains(headKey) && by.contains(m.key))) {
          return 'potrzebne podpisy obu osób';
        }
        if (position.containsKey(m.key)) {
          return 'już jest w piramidzie';
        }
        if (bannedAt(m.key, 'perm', r.at)) {
          return 'ban stały';
        }
        if (bannedAt(headKey, 'noadmit', r.at)) {
          return 'przyjmujący ma zakaz przyjmowania';
        }
        final String? slot = freeSlot(headPath);
        if (slot == null) {
          return 'brak wolnego miejsca';
        }
        members[m.key] = m;
        _place(m.key, slot, r.id);
        history.add(
          PyrHistory(
            r.at,
            t('{head} przyjął(-ęła) {name}', {
              'head': _name(headKey),
              'name': m.name,
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
        if (_countOf(by, cellOf(cell)) < 2) {
          return 'potrzeba 2 z 3 w komórce';
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
          // With the whole branch (§20.4): the whole own cell agrees.
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
        final bool byIssuer =
            d.parent != null && by.contains(delegations[d.parent]?.to);
        if (!_twoOfTop(r) && !byIssuer) {
          return 'cofnąć może szczyt albo wystawca';
        }
        // The acts the revokers knew of (§21.2): any other act dated before
        // now appeared later — back-dated by the delegate — and does not
        // count.
        final Object? acts = b['acts'];
        if (acts is! List) {
          return 'cofnięcie bez listy aktów';
        }
        d.revoked = true;
        _revokeLists[d.id] = (at: r.at, acts: acts.whereType<String>().toSet());
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
        final PyrReferendum? ref = referenda[r.str('ref')];
        if (ref == null || ref.kind != 'constitution' || !_twoOfTop(r)) {
          return 'zmiana zasad tylko po referendum';
        }
        // Not before the sums of the branches had their time to come up.
        if (r.at < ref.end + kPyrTallyGraceMs) {
          return 'za wcześnie: sumy gałęzi jeszcze spływają';
        }
        if (!constitutionPasses(ref.id)) {
          return 'referendum nie przeszło';
        }
        params.apply(ref.params);
        _natLead.clear();
        history.add(
          PyrHistory(
            r.at,
            t('Nowe zasady (wersja {version})', {'version': params.version}),
            r.id,
          ),
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
        // A rolling 30-day limit: a new head (a new term) does not bring a
        // fresh one.
        if (amount > params.emitLimit ||
            pyrAdd(emittedWithin(r.at), amount) > params.emitLimit) {
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
          at: r.at,
          effectiveAt: r.at + params.emitDelayHours * 3600 * 1000,
          signers: signers,
          vetoers: <String>[
            for (final String k in topCell)
              if (!signers.contains(k)) k,
          ],
        );
        return null;
      case PyrT.veto:
        final String target = r.str('emit');
        // An emission, or (by any part or the merge itself) the money a
        // merge converted: one veto stops all of it.
        final PyrEmission? e =
            emissions[target] ??
            emissions.values
                .where((PyrEmission x) => x.group == target)
                .firstOrNull;
        if (e == null || e.vetoed || e.done) {
          return 'nie ma czego zawetować';
        }
        if (r.at < e.at || r.at >= e.effectiveAt) {
          return 'za późno na weto';
        }
        if (!by.any(e.vetoers.contains)) {
          return 'weto: trzeci członek szczytu';
        }
        final List<PyrEmission> parts = e.group == null
            ? <PyrEmission>[e]
            : emissions.values
                  .where((PyrEmission x) => x.group == e.group && !x.done)
                  .toList();
        int stopped = 0;
        for (final PyrEmission x in parts) {
          x.vetoed = true;
          stopped = pyrAdd(stopped, x.amount);
          emittedInTerm[x.term] = max(
            0,
            (emittedInTerm[x.term] ?? 0) - x.amount,
          );
        }
        history.add(
          PyrHistory(
            r.at,
            e.group == null
                ? t('Weto wobec emisji {amount}', {
                    'amount': pyrMoney(e.amount),
                  })
                : t('Weto wobec przeliczenia po połączeniu ({amount})', {
                    'amount': pyrMoney(stopped),
                  }),
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
        // An exchange payment is taken only with the key of its lock.
        final String? lock = e.lock;
        if (ok && lock != null && !pyrUnlocks(lock, r.str('pre'))) {
          return 'zły klucz wymiany';
        }
        // Like a transfer: most treasurers sign it, and an honest one signs
        // one settlement per payment — so a late acceptance dated before a
        // refund (or the other way round) cannot get in (§23.5).
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
        if (lock != null) {
          e.pre = r.str('pre');
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
      case PyrT.merge:
        return _merge(r);
      case PyrT.merged:
        if (!_twoOfTop(r) || r.str('into').isEmpty) {
          return 'połączyć może szczyt (2 z 3)';
        }
        // Also 2 of the top as it stands today (without closing records):
        // a top replaced since cannot close the pyramid by back-dating.
        final Set<String>? today = _finalTop;
        if (today != null && _countOf(by, today) < 2) {
          return 'zamknąć może tylko obecny szczyt';
        }
        mergedInto = r.str('into');
        // Its money went over as counted at the cut (§20.5); later money
        // records do not count here (second pass of [fold]).
        if (b['cut'] is int) {
          mergeCut = min(b['cut'] as int, r.at);
        }
        history.add(
          PyrHistory(r.at, t('Piramida dołączona jako gałąź innej'), r.id),
        );
        return null;
      case PyrT.offer:
        final String k = by.firstOrNull ?? '';
        if (!members.containsKey(k)) {
          return 'nie członek';
        }
        // A kind's price by level of acquaintance, {friend, fof, stranger}
        // (§24); [offers] keeps the highest.
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
      case PyrT.fxRate:
        return _fxRate(r);
    }
    return 'nieznany rodzaj';
  }

  /// The most other pyramids one member exchanges with.
  static const int maxFxRates = 20;

  /// A member's exchange rate for money of pyramid 'from' (paid out here;
  /// 'n' = 0 withdraws it).
  String? _fxRate(PyramidRecord r) {
    final String k = r.signers.length == 1 ? r.signers.first : '';
    final String from = r.str('from');
    if (!isMember(k) || r.str('k') != k) {
      return 'nie członek';
    }
    if (from.isEmpty || from.length > 100 || from == id) {
      return 'zła piramida';
    }
    final int numer = r.integer('n');
    final int denom = r.integer('d');
    final int most = r.integer('max');
    if (numer < 0 ||
        numer > kPyrMaxRate ||
        denom < 1 ||
        denom > kPyrMaxRate ||
        most < 0 ||
        most > kPyrMaxAmount) {
      return 'zły kurs';
    }
    final Map<String, PyrFxRate> mine = fxRates[k] ??= <String, PyrFxRate>{};
    if (numer == 0) {
      mine.remove(from);
      return null;
    }
    if (!mine.containsKey(from) && mine.length >= maxFxRates) {
      return 'za dużo kursów';
    }
    mine[from] = PyrFxRate(numer: numer, denom: denom, max: most, at: r.at);
    return null;
  }

  static String _clip(String s, int n) => s.length > n ? s.substring(0, n) : s;

  /// One intermediary of an announcement accepted (§24): it keeps its
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
  /// one coming back).
  PyrMember? _memberFrom(Object? json, int at, String? admittedBy) {
    if (json is! Map ||
        !PyramidRecord.isCanonicalKey(json['k']) ||
        json['n'] is! String) {
      return null;
    }
    return PyrMember(
      key: json['k'] as String,
      name: _clip(json['n'] as String, 40),
      nat: json['nat'] is String
          ? _clip(json['nat'] as String, 8).toUpperCase()
          : '',
      dataCommit: json['dc'] is String ? json['dc'] as String : '',
      joinedAt: at,
      admittedBy: admittedBy,
      addr: json['addr'] is String ? _clip(json['addr'] as String, 300) : '',
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
    final List<String> members = cellOf(cell);
    final List<String> claimed = r.body['ring'] is List
        ? (r.body['ring'] as List).whereType<String>().toList()
        : const <String>[];
    if (ring == null || occupant[cell] != head || members.length < 2) {
      return 'zła komórka';
    }
    if (!(claimed.length == members.length &&
        claimed.toSet().containsAll(members))) {
      return 'pierścień to nie ta komórka';
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
  /// through delegation [via] (§21.2): the holder signed, the whole chain
  /// is in force (not revoked, not expired, every holder still in the
  /// pyramid), the target is in scope, and no limit on the way up is used
  /// up. Records nothing; [_use] does once the act counts.
  bool _canUse(String via, String power, String targetPath, PyramidRecord r) {
    final PyrDelegation? d = delegations[via];
    if (d == null ||
        !r.signers.contains(d.to) ||
        d.power != power ||
        !_validChain(d, r.at)) {
      return false;
    }
    if (_void.contains(r.id) || !PyrPath.within(targetPath, d.scope)) {
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
    'referendum',
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
    // Immunity: the higher levels need their own cell (§21.1a).
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
      hash: r.body['hash'] is String ? r.body['hash'] as String : null,
      datingKey: r.body['dk'] is String ? r.body['dk'] as String : null,
      reason: _clip(r.str('reason'), 500),
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

  String? _referendum(PyramidRecord r) {
    final Map<dynamic, dynamic> scope = r.body['scope'] is Map
        ? r.body['scope'] as Map
        : const <String, dynamic>{};
    final String kind = scope['k'] is String ? scope['k'] as String : 'all';
    final String path = scope['p'] is String ? scope['p'] as String : '';
    final String nat = scope['nat'] is String ? scope['nat'] as String : '';
    final String refKind = r.str('kind').isEmpty ? 'normal' : r.str('kind');
    final List<String> opts = r.body['opts'] is List
        ? (r.body['opts'] as List)
              .whereType<String>()
              .map((String o) => _clip(o, 200))
              .take(20)
              .toList()
        : const <String>[];
    // A minimum length nobody can lower (not even by new rules): new rules
    // need 72 h of voting, anything else two minutes.
    final int minLength = refKind == 'constitution'
        ? kPyrMinConstitutionMs
        : kPyrMinReferendumMs;
    if (opts.length < 2 || r.integer('end') < r.at + minLength) {
      return 'złe referendum (za mało opcji albo za krótkie)';
    }
    if (kind == 'branch' && !PyrPath.valid(path)) {
      return 'zły zasięg';
    }
    final String? via = r.body['via'] is String
        ? r.body['via'] as String
        : null;
    bool ok;
    if (refKind == 'constitution') {
      ok = _twoOfTop(r) && kind == 'all';
    } else {
      ok =
          _twoOfTop(r) ||
          (kind == 'nat' &&
              nat.isNotEmpty &&
              r.signers.contains(nationalLead(nat)));
      // A delegate asks only its branch: a question to everybody (or to a
      // nationality) needs a whole-pyramid delegation.
      if (!ok &&
          via != null &&
          _canUse(via, 'referendum', kind == 'branch' ? path : '', r)) {
        ok = true;
        _use(via, r);
      }
    }
    if (!ok) {
      return 'referendum ogłasza szczyt, delegat albo prowadzący sekcję';
    }
    referenda[r.id] = PyrReferendum(
      id: r.id,
      question: _clip(r.str('q'), 1000),
      options: opts,
      scopeKind: kind,
      scopePath: path,
      scopeNat: nat,
      end: r.integer('end'),
      kind: refKind,
      at: r.at,
      params: r.body['params'] is Map
          ? Map<String, dynamic>.from(r.body['params'] as Map)
          : null,
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

  /// A cell head's sum of its branch (§21.3). Checkable against the sums
  /// below: only after the end; whole numbers, none above the branch; the
  /// newest sum of every branch right below (a branch with people under it
  /// may be missing only after [kPyrTallyGraceMs]); each counted once; at
  /// most one vote more per direct member (and the root's own vote where
  /// it was passed).
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
    final int directs = PyrPath.children(
      p,
    ).where((String c) => occupant[c] != null).length;
    final int allowance =
        directs + (r.body['extra'] == true && _holdsRootVote(p, root) ? 1 : 0);
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

  /// Evidence of a treasurer signing two orders for one [slot] (§23.4).
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
    final String? condProblem = pyrCondProblem(r.body['cond']);
    if (condProblem != null) {
      return condProblem;
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
      // An exchange: what the exchanger is asked to pay out elsewhere.
      final Map<dynamic, dynamic>? fx =
          cond['hl'] is String && cond['fx'] is Map ? cond['fx'] as Map : null;
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
        lock: cond['hl'] is String ? cond['hl'] as String : null,
        fxPy: fx?['py'] as String?,
        fxTo: fx?['to'] as String?,
        fxAmount: fx?['a'] as int? ?? 0,
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

  /// The most people one merge may bring (a big branch; the record size
  /// limit is the real bound).
  static const int maxMergeSize = 20000;

  String? _merge(PyramidRecord r) {
    final String under = r.str('under');
    final String? underPath = position[under];
    final List<Map<dynamic, dynamic>> snap = r.body['snap'] is List
        ? (r.body['snap'] as List).whereType<Map<dynamic, dynamic>>().toList()
        : const <Map<dynamic, dynamic>>[];
    if (underPath == null || !r.signers.contains(under) || snap.isEmpty) {
      return 'złe połączenie';
    }
    if (snap.length > maxMergeSize) {
      return 'połączenie za duże';
    }
    if (bannedAt(under, 'noadmit', r.at)) {
      return 'przyjmujący ma zakaz przyjmowania';
    }
    // Every entry well formed, each place and each person once, nobody
    // banned for good and nobody already here.
    final Map<String, Map<dynamic, dynamic>> byRel =
        <String, Map<dynamic, dynamic>>{};
    final Set<String> keys = <String>{};
    for (final Map<dynamic, dynamic> e in snap) {
      final Object? rel = e['p'];
      final Object? k = e['k'];
      final Object? bal = e['bal'];
      if (rel is! String ||
          k is! String ||
          rel.length > 48 ||
          !PyrPath.valid(rel) ||
          !PyramidRecord.isCanonicalKey(k) ||
          e['n'] is! String ||
          (bal != null && (bal is! int || bal < 0 || bal > kPyrMaxBalance))) {
        return 'zły wpis połączenia';
      }
      if (byRel.containsKey(rel) || !keys.add(k)) {
        return 'powtórzony wpis połączenia';
      }
      if (position.containsKey(k)) {
        return 'ktoś już jest w tej piramidzie';
      }
      if (bannedAt(k, 'perm', r.at)) {
        return 'ban stały';
      }
      byRel[rel] = e;
    }
    final List<String> theirTop = <String>[
      for (final String p in <String>['', '0', '1'])
        if (byRel[p] != null) byRel[p]!['k'] as String,
    ];
    if (byRel[''] == null ||
        _countOf(r.signers, theirTop) < min(2, theirTop.length)) {
      return 'połączenie: 2 z 3 szczytu dołączanej piramidy';
    }
    for (final String rel in byRel.keys) {
      if (rel.isNotEmpty && !byRel.containsKey(PyrPath.parent(rel))) {
        return 'dziura w strukturze';
      }
    }
    final String? slot = freeSlot(underPath);
    if (slot == null) {
      return 'brak wolnego miejsca';
    }
    // Their money, converted into this pyramid's at the agreed rate
    // (§20.5). New money here, so like an emission: 2 of this top agree,
    // it fits the 30-day limit, waits and can be vetoed.
    final ({int numer, int denom})? rate = _mergeRate(r.body['rate']);
    if (rate == null) {
      return 'zły kurs';
    }
    final Map<String, int> converted = <String, int>{};
    int total = 0;
    for (final Map<dynamic, dynamic> e in byRel.values) {
      final Object? bal = e['bal'];
      final int c = bal is int ? pyrConvert(bal, rate.numer, rate.denom) : 0;
      if (c > 0) {
        converted[e['k'] as String] = c;
        total = pyrAdd(total, c);
      }
    }
    final List<String> ourSigners = r.signers.where(topCell.contains).toList();
    if (converted.isNotEmpty) {
      if (!_twoOfTop(r)) {
        return 'przeliczenie pieniędzy: zgoda 2 z 3 szczytu tej piramidy';
      }
      if (total > params.emitLimit ||
          pyrAdd(emittedWithin(r.at), total) > params.emitLimit) {
        return 'przeliczenie przekracza limit emisji (30 dni)';
      }
    }
    final List<String> vetoers = <String>[
      for (final String k in topCell)
        if (!ourSigners.contains(k)) k,
    ];
    for (final MapEntry<String, Map<dynamic, dynamic>> e in byRel.entries) {
      final PyrMember? m = _memberFrom(e.value, r.at, under);
      if (m == null) {
        continue;
      }
      members[m.key] = m;
      _place(m.key, '$slot${e.key}', r.id);
    }
    for (final MapEntry<String, int> c in converted.entries) {
      final String partId = '${r.id}|${c.key}';
      emissions[partId] = PyrEmission(
        id: partId,
        to: c.key,
        amount: c.value,
        why: t('Przeliczenie po połączeniu (kurs {numer}:{denom})', {
          'numer': rate.numer,
          'denom': rate.denom,
        }),
        term: term,
        at: r.at,
        effectiveAt: r.at + params.emitDelayHours * 3600 * 1000,
        signers: ourSigners,
        vetoers: vetoers,
        group: r.id,
      );
    }
    if (total > 0) {
      emittedInTerm[term] = pyrAdd(emittedInTerm[term] ?? 0, total);
    }
    history.add(
      PyrHistory(
        r.at,
        t('Dołączono piramidę jako gałąź pod {name}', {'name': _name(under)}),
        r.id,
      ),
    );
    return null;
  }

  /// The rate of a merge: 1:1 when the record has none, null when it is
  /// malformed.
  static ({int numer, int denom})? _mergeRate(Object? json) {
    if (json == null) {
      return (numer: 1, denom: 1);
    }
    if (json is! Map || json['n'] is! int || json['d'] is! int) {
      return null;
    }
    final int numer = json['n'] as int;
    final int denom = json['d'] as int;
    if (numer < 1 || numer > kPyrMaxRate || denom < 1 || denom > kPyrMaxRate) {
      return null;
    }
    return (numer: numer, denom: denom);
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
