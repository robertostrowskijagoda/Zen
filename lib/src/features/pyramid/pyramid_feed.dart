import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Pyramid posts read from outside the pyramid: at most this many of one
/// kind in a frame, this many kept per nationality and of the top (the
/// newest), each record at most this big.
const int kPyrNationalBatch = 20;
const int kPyrNationalKept = 60;
const int kPyrNationalPostBytes = 12 * 1024;

/// A pyramid post counts as new ("Posty piramidy: N nowe") while it is
/// unread and at most this old.
const int kPyrFeedNewMs = 30 * 24 * 3600 * 1000;

/// A pyramid post as a reader outside the pyramid gets it (the
/// `pyr_nat` frame): a national-section post, or the top's post to the
/// whole pyramid. The author's signed record, and what the member friend
/// who passed it on sees of it in the pyramid — pseudonym, depth, branch,
/// lead, pin, number of comments (their word, not signed).
@immutable
final class PyrNationalPost {
  const PyrNationalPost({
    required this.record,
    required this.name,
    required this.depth,
    required this.branch,
    required this.lead,
    required this.pinned,
    required this.comments,
    this.from = '',
  });

  final PyramidRecord record;
  final String name;
  final int depth;

  /// People in the author's branch.
  final int branch;

  /// The author leads the section.
  final bool lead;
  final bool pinned;
  final int comments;

  /// Who passed it on (an address); '' when this phone keeps the pyramid.
  final String from;

  String get id => record.id;
  String get pyramid => record.pyramid;

  /// The section's nationality; '' for a post of the top.
  String get nat => record.str('nat');

  /// The top's post to the whole pyramid (not a national-section one).
  bool get top => record.type == PyrT.post;
  String get author => record.candidates.firstOrNull ?? '';
  int get at => record.at;

  /// The author's level when it was written, signed (0 is the head).
  int get level => record.integer('lvl');

  String get text {
    final String s = record.str('text');
    return s.length > 5000 ? String.fromCharCodes(s.runes.take(5000)) : s;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'r': record.toJson(),
    'm': <String, dynamic>{
      'n': name,
      'd': depth,
      'b': branch,
      'l': lead,
      'p': pinned,
      'c': comments,
    },
    if (from.isNotEmpty) 'f': from,
  };

  /// Parses one: null for anything but a national-section record or a
  /// post of the top (level 0), with one author who signed it, at most
  /// [kPyrNationalPostBytes]. The signature itself is checked by the
  /// service. [from] replaces the stored sender.
  static PyrNationalPost? fromJson(Object? json, {String? from}) {
    if (json is! Map) {
      return null;
    }
    final PyramidRecord? r = PyramidRecord.fromJson(json['r']);
    if (r == null ||
        r.pyramid.isEmpty ||
        r.candidates.length != 1 ||
        r.sigs.length != 1 ||
        !r.sigs.containsKey(r.candidates.first) ||
        r.signedBytes.length > kPyrNationalPostBytes) {
      return null;
    }
    final bool section = r.type == PyrT.natPost && r.str('nat').isNotEmpty;
    final bool ofTop = r.type == PyrT.post && r.integer('lvl') == 0;
    if (!section && !ofTop) {
      return null;
    }
    final Object? m = json['m'];
    final Map<dynamic, dynamic> meta = m is Map ? m : const <String, Object>{};
    int count(Object? v) => v is int && v >= 0 && v < 1 << 30 ? v : 0;
    final Object? n = meta['n'];
    final Object? f = json['f'];
    return PyrNationalPost(
      record: r,
      name: n is String ? String.fromCharCodes(n.runes.take(40)) : '',
      depth: count(meta['d']),
      branch: count(meta['b']),
      lead: section && meta['l'] == true,
      pinned: section && meta['p'] == true,
      comments: count(meta['c']),
      from: from ?? (f is String ? f : ''),
    );
  }
}

/// The most links of the power key's line a frame carries.
const int kPyrPowerLineMax = 64;

/// A head of the pyramid as its power key certified them: from [since]
/// (the founding or the handover); [pq] is the ML-DSA fingerprint the
/// founder was seated with (null for a head seated by a handover, whose
/// admission a reader outside does not have).
@immutable
final class PyrCertifiedHead {
  const PyrCertifiedHead(this.key, this.since, {this.pq});

  final String key;
  final int since;
  final String? pq;
}

/// The heads of the pyramid whose pinned genesis is [genesis], from the
/// power key's line in [chain]: the founding, then the handovers, each
/// signed by the power key of its time (the genesis names the first, with
/// its ML-DSA half for the original pyramid) and by the head it seats; a
/// handover also by the new key. What a reader outside the pyramid can
/// check with nothing but the genesis. A handover signed by the top cell
/// instead of the old key cannot be checked so: the line stops there.
/// Oldest first.
Future<List<PyrCertifiedHead>> certifiedHeads(
  PyramidRecord genesis,
  Iterable<PyramidRecord> chain,
) async {
  String power = genesis.str('pk');
  String? powerPq = genesis.body['pq'] is String ? genesis.str('pq') : null;
  final Set<String> used = <String>{power};
  final List<PyramidRecord> links =
      <PyramidRecord>[
        for (final PyramidRecord r in chain)
          if (r.pyramid == genesis.id &&
              (r.type == PyrT.found || r.type == PyrT.handover))
            r,
      ]..sort(
        (PyramidRecord a, PyramidRecord b) =>
            a.at != b.at ? a.at.compareTo(b.at) : a.id.compareTo(b.id),
      );
  final List<PyrCertifiedHead> heads = <PyrCertifiedHead>[];
  Future<bool> signedBy(PyramidRecord r, List<String> keys) async {
    if (!r.sigs.containsKey(power) ||
        (powerPq != null && r.pqIdOf(power) != powerPq) ||
        !keys.every(r.sigs.containsKey)) {
      return false;
    }
    final Map<String, String> ok = await r.validSigs();
    return ok.containsKey(power) && keys.every(ok.containsKey);
  }

  for (final PyramidRecord r in links) {
    if (power.isEmpty || r.at < (heads.lastOrNull?.since ?? genesis.at)) {
      continue;
    }
    if (r.type == PyrT.found) {
      final Object? m = r.body['m'];
      final Object? k = m is Map ? m['k'] : null;
      final Object? pq = m is Map ? m['pq'] : null;
      if (heads.isNotEmpty ||
          k is! String ||
          pq is! String ||
          r.pqIdOf(k) != pq ||
          !await signedBy(r, <String>[k])) {
        continue;
      }
      heads.add(PyrCertifiedHead(k, r.at, pq: pq));
      continue;
    }
    final String to = r.str('to');
    final String head = r.str('head');
    final String tpq = r.str('tpq');
    if (heads.isEmpty ||
        r.str('from') != power ||
        !PyramidRecord.isCanonicalKey(to) ||
        used.contains(to) ||
        head.isEmpty ||
        r.pqIdOf(to) != tpq ||
        !await signedBy(r, <String>[to, head])) {
      continue;
    }
    power = to;
    powerPq = tpq;
    used.add(to);
    heads.add(PyrCertifiedHead(head, r.at));
  }
  return heads;
}

/// Whether [post] (a post of the top, level 0) was written by the head the
/// power key's line ([certifiedHeads]) names for its time.
bool byCertifiedHead(List<PyrCertifiedHead> heads, PyrNationalPost post) {
  PyrCertifiedHead? then;
  for (final PyrCertifiedHead h in heads) {
    if (h.since > post.at) {
      break;
    }
    then = h;
  }
  return then != null &&
      then.key == post.author &&
      (then.pq == null || post.record.pqIdOf(then.key) == then.pq);
}

/// Where a pyramid post stands for this person.
enum PyrFeedKind {
  /// Written at the top (level 0): to the whole pyramid.
  top,

  /// A cell head of this person's line up, to their branch.
  line,

  /// This person's own post to their branch.
  own,

  /// A post of the national section.
  national,
}

/// One pyramid post as the Tablica shows it. The name is the pyramid
/// pseudonym, never a profile name.
@immutable
final class PyrFeedPost {
  const PyrFeedPost({
    required this.id,
    required this.kind,
    required this.author,
    required this.name,
    required this.text,
    required this.at,
    required this.level,
    this.depth = 0,
    this.branch = 0,
    this.nat = '',
    this.lead = false,
    this.priority = false,
    this.pinnedAt = -1,
    this.comments = const <PyrComment>[],
    this.commentCount = 0,
    this.canComment = false,
  });

  final String id;
  final PyrFeedKind kind;

  /// The author's pyramid key.
  final String author;
  final String name;
  final String text;
  final int at;

  /// The author's signed level when it was written (0 is the top).
  final int level;

  /// The pyramid's depth and the author's branch (0 when unknown).
  final int depth;
  final int branch;

  /// The section's nationality ('' outside the national section).
  final String nat;

  /// The author leads the national section, or has its priority right now.
  final bool lead;
  final bool priority;

  /// When the section's lead pinned it; -1 when not pinned (0: pinned, the
  /// time unknown).
  final int pinnedAt;

  /// The comments (members see them), oldest first.
  final List<PyrComment> comments;

  /// How many comments there are (a reader outside sees only the number).
  final int commentCount;

  /// This person may comment: a member in the author's branch (or of the
  /// section's nationality) — what the composition keeps to.
  final bool canComment;

  bool get pinned => pinnedAt >= 0;

  /// Shown under "Wszystko" too: the top and the line up. Never the
  /// national section nor this person's own posts.
  bool get important => kind == PyrFeedKind.top || kind == PyrFeedKind.line;
}

/// An open referendum this person may vote in: a card on the Tablica that
/// leads to the votes in the Pyramid (one votes only there).
@immutable
final class PyrFeedReferendum {
  const PyrFeedReferendum({
    required this.id,
    required this.question,
    required this.at,
    required this.end,
  });

  final String id;
  final String question;
  final int at;
  final int end;
}

/// An alarm announcement in force for this person: a red bar on top of the
/// Tablica, in every filter, until it ends. With [notice], a notice every
/// member must see instead (a change of the emission limit announced), in
/// the colour of a warning.
@immutable
final class PyrFeedAlarm {
  const PyrFeedAlarm({
    required this.id,
    required this.text,
    required this.until,
    this.notice = false,
  });

  final String id;
  final String text;
  final int until;
  final bool notice;
}

/// A change of the emission limit announced, in words for everybody.
String pyrEmitChangeText(PyrEmitChange c) => t(
  'Zapowiedziana zmiana limitów: emisja {old} → {limit} na 30 dni, czeka {hours} h; przelewy {oldXfers} → {xfers} na osobę dziennie. Obowiązuje od {date}, chyba że szczyt ją anuluje.',
  <String, Object?>{
    'old': ZenFormat.money(c.oldLimit),
    'limit': ZenFormat.money(c.limit ?? c.oldLimit),
    'hours': c.delayHours ?? c.oldDelayHours,
    'oldXfers': c.oldXfers,
    'xfers': c.xfers ?? c.oldXfers,
    'date': ZenFormat.dateTime(
      DateTime.fromMillisecondsSinceEpoch(c.effectiveAt),
    ),
  },
);

/// The order of pyramid posts, the same in "Piramida" and "Kraj": the
/// higher the author stood when writing, the higher the post; within a
/// level those with the section's priority, then the newest.
int pyrPostOrder(PyrFeedPost a, PyrFeedPost b) {
  if (a.level != b.level) {
    return a.level.compareTo(b.level);
  }
  if (a.priority != b.priority) {
    return a.priority ? -1 : 1;
  }
  return b.at.compareTo(a.at);
}

/// What the pyramid puts on the Tablica for one person: one rule of who
/// sees what (§22). Every post is here once.
@immutable
final class PyramidFeed {
  const PyramidFeed({
    this.posts = const <PyrFeedPost>[],
    this.referenda = const <PyrFeedReferendum>[],
    this.alarms = const <PyrFeedAlarm>[],
    this.member = false,
    this.nat = '',
    this.branch = 0,
  });

  static const PyramidFeed empty = PyramidFeed();

  final List<PyrFeedPost> posts;

  /// Soonest end first.
  final List<PyrFeedReferendum> referenda;
  final List<PyrFeedAlarm> alarms;

  /// The person is a member (else they only read what friends pass on).
  final bool member;

  /// A member's nationality (their section) and how many people below
  /// them read what they write to their branch.
  final String nat;
  final int branch;

  /// "Piramida" (§22.1): the top, then the line up from the highest;
  /// within a level the newest first. Own posts at their own level.
  List<PyrFeedPost> get pyramid =>
      posts.where((PyrFeedPost p) => p.kind != PyrFeedKind.national).toList()
        ..sort(pyrPostOrder);

  /// "Kraj": the posts the section's lead pinned (newest pin first), then
  /// like "Piramida": the higher the author, the higher the post
  /// ([pyrPostOrder]).
  List<PyrFeedPost> get national =>
      posts.where((PyrFeedPost p) => p.kind == PyrFeedKind.national).toList()
        ..sort((PyrFeedPost a, PyrFeedPost b) {
          if (a.pinnedAt != b.pinnedAt) {
            return b.pinnedAt.compareTo(a.pinnedAt);
          }
          return pyrPostOrder(a, b);
        });

  /// The posts "Wszystko" shows besides friends' ones.
  List<PyrFeedPost> get important =>
      posts.where((PyrFeedPost p) => p.important).toList();

  /// Whether the "Piramida" and "Kraj" chips show: always for a member,
  /// for anybody else only with such posts.
  bool get showsPyramid =>
      member ||
      referenda.isNotEmpty ||
      posts.any((PyrFeedPost p) => p.kind != PyrFeedKind.national);
  bool get showsNational =>
      (member && nat.isNotEmpty) ||
      posts.any((PyrFeedPost p) => p.kind == PyrFeedKind.national);

  /// Posts of the top and the line not read yet ([wasRead]), at most
  /// [kPyrFeedNewMs] old, newest first.
  List<PyrFeedPost> unread(bool Function(String id) wasRead, int now) =>
      _unread(important, wasRead, now);

  /// The same for the national section.
  List<PyrFeedPost> unreadNational(bool Function(String id) wasRead, int now) =>
      _unread(
        posts.where((PyrFeedPost p) => p.kind == PyrFeedKind.national),
        wasRead,
        now,
      );

  static List<PyrFeedPost> _unread(
    Iterable<PyrFeedPost> from,
    bool Function(String id) wasRead,
    int now,
  ) => <PyrFeedPost>[
    for (final PyrFeedPost p in from)
      if (!wasRead(p.id) && now - p.at <= kPyrFeedNewMs) p,
  ]..sort((PyrFeedPost a, PyrFeedPost b) => b.at.compareTo(a.at));
}

/// The pyramid's part of the Tablica for [me]. A member reads it from
/// [state]: the posts of the top, of their line up and their own, the
/// section of their nationality, the open referenda they may vote in (not
/// those in [voted]) and the alarms for them. Anybody else reads what
/// member friends passed on: the top's posts ([top]) and the sections of
/// their profile ([national]), without commenting.
PyramidFeed pyramidFeedOf({
  required PyramidState? state,
  required String? me,
  required int now,
  List<PyrNationalPost> top = const <PyrNationalPost>[],
  List<PyrNationalPost> national = const <PyrNationalPost>[],
  Set<String> voted = const <String>{},
}) {
  final PyramidState? s = state;
  if (s != null && me != null && s.isMember(me)) {
    return _memberFeed(s, me, now, voted);
  }
  final Map<String, PyrFeedPost> out = <String, PyrFeedPost>{};
  for (final PyrNationalPost p in top) {
    if (p.top) {
      out.putIfAbsent(p.id, () => _readOnly(p, PyrFeedKind.top));
    }
  }
  for (final PyrNationalPost p in national) {
    if (!p.top) {
      out.putIfAbsent(p.id, () => _readOnly(p, PyrFeedKind.national));
    }
  }
  return PyramidFeed(posts: out.values.toList());
}

PyramidFeed _memberFeed(PyramidState s, String me, int now, Set<String> voted) {
  final Set<String> banned = s.bannedEntries(now);
  final Set<String> up = s.lineUp(me).toSet();
  final String nat = s.members[me]?.nat ?? '';
  final String myPath = s.pathOf(me) ?? '';
  final List<PyrFeedPost> posts = <PyrFeedPost>[];
  for (final PyrPost p in s.posts.values) {
    if (banned.contains(p.id)) {
      continue;
    }
    // Being in the author's branch is the author being in the line up;
    // what was written at the top went to the whole pyramid.
    final PyrFeedKind? kind = p.author == me
        ? PyrFeedKind.own
        : p.level == 0
        ? PyrFeedKind.top
        : up.contains(p.author)
        ? PyrFeedKind.line
        : null;
    if (kind != null) {
      posts.add(_ofState(s, p, kind));
    }
  }
  final String? lead = nat.isEmpty ? null : s.nationalLead(nat);
  final Map<String, int> grants = s.natGrants[nat] ?? const <String, int>{};
  final Map<String, int> pins = s.natPins[nat] ?? const <String, int>{};
  for (final PyrPost p in s.natPosts.values) {
    if (nat.isNotEmpty && p.nat == nat && !banned.contains(p.id)) {
      posts.add(
        _ofState(
          s,
          p,
          PyrFeedKind.national,
          lead: p.author == lead,
          priority: (grants[p.author] ?? 0) > now,
          pinnedAt: pins[p.id] ?? -1,
        ),
      );
    }
  }
  return PyramidFeed(
    member: true,
    nat: nat,
    branch: s.branchSize(myPath) - 1,
    posts: posts,
    referenda:
        <PyrFeedReferendum>[
          for (final PyrReferendum r in s.referenda.values)
            if (now < r.end && !voted.contains(r.id) && s.eligible(r, me))
              PyrFeedReferendum(
                id: r.id,
                question: r.question,
                at: r.at,
                end: r.end,
              ),
        ]..sort(
          (PyrFeedReferendum a, PyrFeedReferendum b) => a.end.compareTo(b.end),
        ),
    alarms: <PyrFeedAlarm>[
      // Pinned for every member while it waits: the money may change.
      for (final PyrEmitChange c in s.pendingEmitChanges)
        PyrFeedAlarm(
          id: 'emit-${c.id}',
          text: pyrEmitChangeText(c),
          until: c.effectiveAt,
          notice: true,
        ),
      for (final PyrAlarm a in s.alarms)
        if (now < a.until &&
            switch (a.scopeKind) {
              'branch' => PyrPath.within(myPath, a.scopePath),
              'nat' => nat == a.scopeNat,
              _ => true,
            })
          PyrFeedAlarm(id: a.id, text: a.text, until: a.until),
    ],
  );
}

PyrFeedPost _ofState(
  PyramidState s,
  PyrPost p,
  PyrFeedKind kind, {
  bool lead = false,
  bool priority = false,
  int pinnedAt = -1,
}) {
  final String? path = s.pathOf(p.author);
  return PyrFeedPost(
    id: p.id,
    kind: kind,
    author: p.author,
    name: s.members[p.author]?.name ?? '?',
    text: p.text,
    at: p.at,
    level: p.level,
    depth: s.depth,
    branch: path == null ? 0 : s.branchSize(path),
    nat: p.nat ?? '',
    lead: lead,
    priority: priority,
    pinnedAt: pinnedAt,
    comments: List<PyrComment>.unmodifiable(p.comments),
    commentCount: p.comments.length,
    // A member, and the composition keeps to the author's branch (or the
    // section's nationality), as the records' rules do.
    canComment: true,
  );
}

PyrFeedPost _readOnly(PyrNationalPost p, PyrFeedKind kind) => PyrFeedPost(
  id: p.id,
  kind: kind,
  author: p.author,
  name: p.name.isEmpty ? '?' : p.name,
  text: p.text,
  at: p.at,
  level: p.level,
  depth: p.depth,
  branch: p.branch,
  nat: p.nat,
  lead: p.lead,
  // A pinned post read from outside: its pin time is not known.
  pinnedAt: p.pinned ? 0 : -1,
  commentCount: p.comments,
);
