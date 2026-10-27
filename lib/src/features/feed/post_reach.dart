import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

// How far a post goes.
//
// The author picks a reach for a public post: friends, friends of friends
// (the default) or one step further. Friends read the post itself, as
// always (they keep the author's feed). Beyond them only a small notice
// travels: a friend of the author writes a `post_ann` entry in their own
// `acts` (which only their friends read) naming the post, its author, when
// it was written, its reach and how many steps from the author its readers
// are. No text, no photos. Whoever reads such a notice fetches the post
// itself (`lg_post_want` → `lg_post`) from the friend who passed it on (who
// holds it) or from the author, and checks the author's signature and that
// the author really gave the post that reach. A friend of a friend passes
// the notice one step further only for a post of reach 3, and only once
// the post is on their own device, so their friends can fetch it from
// them. A post for any other audience is sealed for the author's friends
// and never goes further, whatever its reach.
//
// What a reader learns: the post, its author (who chose to be seen that
// far), and which of their own friends passed it on ("przez …"). A notice
// carries no path, only the number of steps.
//
// Bounds: notices only about posts from the last [kReachWindow]; each post
// passed on once (again only when it was edited or removed); at most
// [kMaxAnnouncedPerAuthorDay] posts of one author and [kMaxAnnouncedPerDay]
// in all a day, [kMaxAnnouncedPerEntry] in one entry; readers apply the
// same caps to what each friend passes on. Reshares are not affected: a
// reshare carries the whole post as before and goes as far as people
// reshare it.

/// How far a post travels, in steps of friendship from its author.
enum PostReach {
  /// Friends only (and followers of a public post).
  friends(1),

  /// Also friends of friends.
  friendsOfFriends(2),

  /// One step further: friends of friends of friends.
  third(3);

  const PostReach(this.hops);

  /// Steps of friendship from the author.
  final int hops;

  /// The reach of [hops] steps, or `null`.
  static PostReach? byHops(Object? hops) =>
      PostReach.values.where((PostReach r) => r.hops == hops).firstOrNull;

  String get label => switch (this) {
    PostReach.friends => t('Znajomi'),
    PostReach.friendsOfFriends => t('Znajomi znajomych'),
    PostReach.third => t('3. stopień'),
  };

  String get hint => switch (this) {
    PostReach.friends => t('Tylko Twoi znajomi i obserwujący.'),
    PostReach.friendsOfFriends => t('Także znajomi Twoich znajomych.'),
    PostReach.third => t(
      'Jeszcze krok dalej: znajomi znajomych Twoich znajomych.',
    ),
  };
}

/// The reach a new public post starts with.
const PostReach kDefaultPostReach = PostReach.friendsOfFriends;

/// Key of the reach in a public post's body (1–3 steps).
const String kPostReachKey = 'reach';

/// The reach of a post [body]: only a public post goes further than
/// friends (anything else is sealed for the author's friends).
PostReach reachOfBody(Map<String, dynamic>? body) {
  if (body == null || isSealed(body) || body['aud'] != Audience.public.name) {
    return PostReach.friends;
  }
  return PostReach.byHops(body[kPostReachKey]) ?? PostReach.friends;
}

/// Entry kind of passed-on notices in the writer's `acts/<account>` space:
/// `{items: [notice…]}` ([PostAnnouncement]).
const String kPostAnnounceKind = 'post_ann';

/// Asks whoever holds a post for it: `{type, id, a}` (post id, author).
const String kPostWantType = 'lg_post_want';

/// The answer: `{type, id, a, entry?, edit?, del?, prof?}` – the signed post,
/// its newest edit, the author's tombstone instead of both once it was
/// removed, and the author's public profile, each with its device
/// certificate.
const String kPostAnswerType = 'lg_post';

/// Notices in one entry at most.
const int kMaxAnnouncedPerEntry = 100;

/// Posts of one author passed on (or taken from one friend) per day.
const int kMaxAnnouncedPerAuthorDay = 10;

/// Notices one account passes on per day.
const int kMaxAnnouncedPerDay = 300;

/// Posts taken from one friend's notices at most (within the window).
const int kMaxAnnouncedPerFriend = 1000;

/// Only posts this recent are passed on and shown.
const Duration kReachWindow = Duration(days: 30);

const int _day = 24 * 3600 * 1000;

final RegExp _entryId = RegExp(r'^[0-9a-f]{64}$');

/// One notice: [post] of [author] written at [millis] with [reach], read
/// [hops] steps from the author. [authorAddress] is the address the author
/// shows in their public profile (to fetch the post from them);
/// [editMillis] when it was last edited and [removed] tell readers who
/// hold an older version to fetch it again.
@immutable
final class PostAnnouncement {
  const PostAnnouncement({
    required this.post,
    required this.author,
    required this.millis,
    required this.reach,
    required this.hops,
    this.authorAddress = '',
    this.editMillis = 0,
    this.removed = false,
  });

  final String post;
  final String author;
  final int millis;
  final PostReach reach;
  final int hops;
  final String authorAddress;
  final int editMillis;
  final bool removed;

  /// What a notice says about the post: passed on again when it changes.
  String get state => '$post|$editMillis|${removed ? 1 : 0}';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': post,
    'a': author,
    't': millis,
    'r': reach.hops,
    'h': hops,
    if (authorAddress.isNotEmpty) 'aa': authorAddress,
    if (editMillis > 0) 'e': editMillis,
    if (removed) 'x': 1,
  };

  /// A notice, or `null` when anything is off: a reach of friends only, a
  /// step count outside 2…reach.
  static PostAnnouncement? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? p = json['p'];
    final Object? a = json['a'];
    final Object? at = json['t'];
    final PostReach? reach = PostReach.byHops(json['r']);
    final Object? h = json['h'];
    final Object? aa = json['aa'];
    final Object? e = json['e'];
    if (p is! String ||
        !_entryId.hasMatch(p) ||
        a is! String ||
        a.isEmpty ||
        a.length > 100 ||
        at is! int ||
        at <= 0 ||
        reach == null ||
        reach == PostReach.friends ||
        h is! int ||
        h < 2 ||
        h > reach.hops) {
      return null;
    }
    return PostAnnouncement(
      post: p,
      author: a,
      millis: at,
      reach: reach,
      hops: h,
      authorAddress: aa is String && aa.length <= kMaxProfileAddress ? aa : '',
      editMillis: e is int && e > 0 ? e : 0,
      removed: json['x'] == 1,
    );
  }
}

/// Body of a `post_ann` entry passing on [items].
Map<String, dynamic> announceBody(List<PostAnnouncement> items) =>
    <String, dynamic>{
      'items': <Map<String, dynamic>>[
        for (final PostAnnouncement a in items.take(kMaxAnnouncedPerEntry))
          a.toJson(),
      ],
    };

/// The valid notices of a `post_ann` entry [e].
List<PostAnnouncement> announcementsIn(LogEntry e) {
  final Object? items = e.body['items'];
  if (e.kind != kPostAnnounceKind || items is! List) {
    return const <PostAnnouncement>[];
  }
  return <PostAnnouncement>[
    for (final Object? item in items.take(kMaxAnnouncedPerEntry))
      ?PostAnnouncement.fromJson(item),
  ];
}

/// A post that reached this account through its friends' notices: [hops]
/// steps from its author, passed on by the friends in [via] (accounts, the
/// ones at the fewest steps).
@immutable
final class AnnouncedPost {
  const AnnouncedPost({
    required this.post,
    required this.author,
    required this.millis,
    required this.reach,
    required this.hops,
    required this.via,
    this.authorAddress = '',
    this.editMillis = 0,
    this.removed = false,
  });

  final String post;
  final String author;
  final int millis;
  final PostReach reach;
  final int hops;
  final List<String> via;
  final String authorAddress;
  final int editMillis;
  final bool removed;

  AnnouncedPost _with(PostAnnouncement a, String friend) {
    final bool closer = a.hops < hops;
    return AnnouncedPost(
      post: post,
      author: author,
      millis: millis,
      reach: a.reach.hops > reach.hops ? a.reach : reach,
      hops: closer ? a.hops : hops,
      via: closer
          ? <String>[friend]
          : (a.hops == hops && !via.contains(friend)
                ? <String>[...via, friend]
                : via),
      authorAddress: authorAddress.isNotEmpty ? authorAddress : a.authorAddress,
      editMillis: math.max(editMillis, a.editMillis),
      removed: removed || a.removed,
    );
  }
}

/// What one friend's [acts] pass on: the newest notice per post (with the
/// fewest steps any of them named), within the window and the caps.
Map<String, PostAnnouncement> _passedOnBy(
  Iterable<LogEntry> acts, {
  required int since,
  required int now,
}) {
  final List<LogEntry> entries = <LogEntry>[
    for (final LogEntry e in acts)
      if (e.kind == kPostAnnounceKind) e,
  ]..sort((LogEntry a, LogEntry b) => a.hlc.compareTo(b.hlc));
  final Map<String, PostAnnouncement> out = <String, PostAnnouncement>{};
  final Map<String, int> perAuthorDay = <String, int>{};
  for (final LogEntry e in entries) {
    for (final PostAnnouncement a in announcementsIn(e)) {
      if (a.millis < since || a.millis > now + _day) {
        continue;
      }
      final PostAnnouncement? had = out[a.post];
      if (had == null) {
        final String key = '${a.author}|${a.millis ~/ _day}';
        final int count = perAuthorDay[key] ?? 0;
        if (count >= kMaxAnnouncedPerAuthorDay ||
            out.length >= kMaxAnnouncedPerFriend) {
          continue;
        }
        perAuthorDay[key] = count + 1;
        out[a.post] = a;
      } else if (had.author == a.author) {
        out[a.post] = PostAnnouncement(
          post: a.post,
          author: a.author,
          millis: had.millis,
          reach: a.reach,
          hops: math.min(had.hops, a.hops),
          authorAddress: a.authorAddress.isNotEmpty
              ? a.authorAddress
              : had.authorAddress,
          editMillis: math.max(had.editMillis, a.editMillis),
          removed: had.removed || a.removed,
        );
      }
    }
  }
  return out;
}

/// Posts that reached this account only through friends' notices, by post
/// id: never this account's own nor a friend's (those it reads itself).
Map<String, AnnouncedPost> announcedPosts(LedgerNode node, {int? nowMillis}) {
  final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final int since = now - kReachWindow.inMilliseconds;
  final Set<String> friends = node.friendAccounts.values.toSet();
  final Set<String> circle = <String>{node.account, ...friends};
  final Map<String, AnnouncedPost> out = <String, AnnouncedPost>{};
  for (final String friend in friends) {
    final Map<String, PostAnnouncement> passed = _passedOnBy(
      node.entriesOf(spaceKind: 'acts', ofAccount: friend),
      since: since,
      now: now,
    );
    for (final PostAnnouncement a in passed.values) {
      if (circle.contains(a.author)) {
        continue;
      }
      final AnnouncedPost? had = out[a.post];
      if (had == null) {
        out[a.post] = AnnouncedPost(
          post: a.post,
          author: a.author,
          millis: a.millis,
          reach: a.reach,
          hops: a.hops,
          via: <String>[friend],
          authorAddress: a.authorAddress,
          editMillis: a.editMillis,
          removed: a.removed,
        );
      } else if (had.author == a.author) {
        out[a.post] = had._with(a, friend);
      }
    }
  }
  return out;
}

/// A post this device fetched (or was told was removed), as its author
/// signed it, with what came along: its newest edit and the author's
/// public profile. [hops] is how many steps from the author it reached
/// this account. Once removed only the tombstone is kept.
@immutable
final class HeldPost {
  const HeldPost({
    required this.id,
    required this.author,
    required this.hops,
    this.post,
    this.edit,
    this.tombstone,
    this.profile,
  });

  final String id;
  final String author;
  final int hops;
  final LogEntry? post;
  final LogEntry? edit;
  final LogEntry? tombstone;
  final LogEntry? profile;

  bool get removed => tombstone != null;

  int get editMillis => edit?.hlc.millis ?? 0;

  /// When the post was written (or removed, when that is all there is).
  int get millis => post?.hlc.millis ?? tombstone?.hlc.millis ?? 0;

  LedgerProfile? get authorProfile =>
      profile == null ? null : profileFromEntry(profile!);

  /// The post's reach as its author signed it.
  PostReach get reach => reachOfBody(post?.body);

  /// This held post brought up to date with [newer] (an answer for the
  /// same post): a removal wins, the newest edit and profile stay.
  HeldPost updatedWith(HeldPost newer) {
    if (removed || newer.removed) {
      return HeldPost(
        id: id,
        author: author,
        hops: math.min(hops, newer.hops),
        tombstone: tombstone ?? newer.tombstone,
      );
    }
    LogEntry? newest(LogEntry? a, LogEntry? b) =>
        a == null || (b != null && b.hlc > a.hlc) ? b : a;
    return HeldPost(
      id: id,
      author: author,
      hops: math.min(hops, newer.hops),
      post: post ?? newer.post,
      edit: newest(edit, newer.edit),
      profile: newest(profile, newer.profile),
    );
  }

  /// Whether [other] says the same as this one.
  bool sameAs(HeldPost other) =>
      other.hops == hops &&
      other.post?.id == post?.id &&
      other.edit?.id == edit?.id &&
      other.tombstone?.id == tombstone?.id &&
      other.profile?.id == profile?.id;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'a': author,
    'h': hops,
    if (post != null) 'e': post!.toCertifiedJson(),
    if (edit != null) 'ed': edit!.toCertifiedJson(),
    if (tombstone != null) 'd': tombstone!.toCertifiedJson(),
    if (profile != null) 'p': profile!.toCertifiedJson(),
  };

  /// A held post as [toJson] stored it (checked when it came, not again).
  static HeldPost? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? a = json['a'];
    final Object? h = json['h'];
    if (id is! String || a is! String || h is! int || h < 2 || h > 3) {
      return null;
    }
    LogEntry? read(Object? j) {
      final LogEntry? e = LogEntry.fromJson(j);
      return e == null || e.account != a || e.certificate == null ? null : e;
    }

    final HeldPost held = HeldPost(
      id: id,
      author: a,
      hops: h,
      post: read(json['e']),
      edit: read(json['ed']),
      tombstone: read(json['d']),
      profile: read(json['p']),
    );
    if ((held.post == null && held.tombstone == null) ||
        (held.post != null && held.post!.id != id)) {
      return null;
    }
    return held;
  }
}

/// Where the feed looks up posts fetched from beyond friends.
abstract interface class HeldPosts {
  HeldPost? heldPost(String id);
}

/// `lg_post_want` for [id] by [author].
Map<String, dynamic> postWantFrame(String id, String author) =>
    <String, dynamic>{'type': kPostWantType, 'id': id, 'a': author};

/// What an `lg_post_want` asks for, or `null`.
({String id, String author})? readPostWant(Map<String, dynamic> payload) {
  final Object? id = payload['id'];
  final Object? a = payload['a'];
  if (payload['type'] != kPostWantType ||
      id is! String ||
      !_entryId.hasMatch(id) ||
      a is! String ||
      a.isEmpty ||
      a.length > 100) {
    return null;
  }
  return (id: id, author: a);
}

/// `lg_post` answering for [id] of [author] (each part with its device
/// certificate).
Map<String, dynamic> postAnswerFrame(
  String id,
  String author, {
  Map<String, dynamic>? entry,
  Map<String, dynamic>? edit,
  Map<String, dynamic>? tombstone,
  Map<String, dynamic>? profile,
}) => <String, dynamic>{
  'type': kPostAnswerType,
  'id': id,
  'a': author,
  'entry': ?entry,
  'edit': ?edit,
  'del': ?tombstone,
  'prof': ?profile,
};

/// The post an `lg_post` [answer] carries, checked: signed by [author],
/// the very post [id] of their feed, public and with a reach of at least
/// [hops]; or the author's tombstone for it. `null` if anything is off.
Future<HeldPost?> checkPostAnswer(
  Map<String, dynamic> answer, {
  required String id,
  required String author,
  required int hops,
}) async {
  if (answer['type'] != kPostAnswerType ||
      answer['id'] != id ||
      answer['a'] != author) {
    return null;
  }
  final String space = accountSpace('feed', author);
  final LogEntry? tomb = answer['del'] == null
      ? null
      : await verifiedEntry(answer['del']);
  if (tomb != null &&
      tomb.kind == kPostDeleteKind &&
      tomb.account == author &&
      tomb.space == space &&
      tomb.body['post'] == id) {
    return HeldPost(id: id, author: author, hops: hops, tombstone: tomb);
  }
  final LogEntry? post = answer['entry'] == null
      ? null
      : await verifiedEntry(answer['entry']);
  if (post == null ||
      post.id != id ||
      post.kind != kPostKind ||
      post.account != author ||
      post.space != space ||
      reachOfBody(post.body).hops < hops) {
    return null;
  }
  LogEntry? edit = answer['edit'] == null
      ? null
      : await verifiedEntry(answer['edit']);
  if (edit != null &&
      (edit.kind != kPostEditKind ||
          edit.account != author ||
          edit.space != space ||
          edit.body['post'] != id ||
          isSealed(edit.body))) {
    edit = null;
  }
  LogEntry? profile = answer['prof'] == null
      ? null
      : await verifiedEntry(answer['prof']);
  if (profile != null &&
      (profile.account != author ||
          isSealed(profile.body) ||
          profileFromEntry(profile) == null)) {
    profile = null;
  }
  return HeldPost(
    id: id,
    author: author,
    hops: hops,
    post: post,
    edit: edit,
    profile: profile,
  );
}

/// The newest public profile entry of [account] held by [node] (what the
/// account shows anyone).
LogEntry? latestPublicProfileEntry(LedgerNode node, String account) {
  LogEntry? best;
  for (final LogEntry e in node.entriesOf(
    spaceKind: 'profile',
    ofAccount: account,
  )) {
    if (e.kind == kProfileKind &&
        !isSealed(e.body) &&
        (best == null || e.hlc > best.hlc)) {
      best = e;
    }
  }
  return best;
}

/// [e] with its device certificate attached when [node] has it (entries
/// read back from disk may come without).
LogEntry? certifiedEntry(LedgerNode node, LogEntry? e) {
  if (e == null || e.certificate != null) {
    return e;
  }
  final DeviceCertificate? cert = node.store.directory.certificateOf(
    e.account,
    e.device,
  );
  return cert == null ? null : e.withCertificate(cert);
}

/// What this account passes on to its friends now: its friends' public
/// posts whose reach goes past friends (their friends are two steps from
/// the author), and posts of reach 3 that reached it two steps from their
/// authors and are held here ([held]). Only what is new or changed since
/// it last passed them on, newest first, within the caps.
List<PostAnnouncement> announcementsToPass(
  LedgerNode node, {
  required HeldPost? Function(String id) held,
  int? nowMillis,
}) {
  final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final int since = now - kReachWindow.inMilliseconds;
  // What this account passed on before, and how much of it in the last day.
  final Map<String, String> passed = <String, String>{};
  final Map<String, int> perAuthor = <String, int>{};
  int today = 0;
  for (final LogEntry e in node.entriesOf(spaceKind: 'acts')) {
    if (e.kind != kPostAnnounceKind || e.account != node.account) {
      continue;
    }
    final bool recent = e.hlc.millis >= now - _day;
    for (final PostAnnouncement a in announcementsIn(e)) {
      passed[a.post] = a.state;
      if (recent) {
        today++;
        perAuthor[a.author] = (perAuthor[a.author] ?? 0) + 1;
      }
    }
  }
  final List<PostAnnouncement> candidates = <PostAnnouncement>[];
  for (final String friend in node.friendAccounts.values.toSet()) {
    final List<LogEntry> feed = node.entriesOf(ofAccount: friend);
    final Map<String, int> edits = <String, int>{};
    final Set<String> removed = <String>{};
    for (final LogEntry e in feed) {
      final Object? target = e.body['post'];
      if (e.account != friend || target is! String) {
        continue;
      }
      if (e.kind == kPostEditKind && !isSealed(e.body)) {
        edits[target] = math.max(edits[target] ?? 0, e.hlc.millis);
      } else if (e.kind == kPostDeleteKind) {
        removed.add(target);
      }
    }
    final LogEntry? profile = latestPublicProfileEntry(node, friend);
    final String address = profile == null
        ? ''
        : profileFromEntry(profile)?.address ?? '';
    for (final LogEntry e in feed) {
      if (e.kind != kPostKind ||
          e.account != friend ||
          e.hlc.millis < since ||
          e.hlc.millis > now + _day) {
        continue;
      }
      final PostReach reach = reachOfBody(e.body);
      if (reach.hops < 2) {
        continue;
      }
      candidates.add(
        PostAnnouncement(
          post: e.id,
          author: friend,
          millis: e.hlc.millis,
          reach: reach,
          hops: 2,
          authorAddress: address,
          editMillis: edits[e.id] ?? 0,
          removed: removed.contains(e.id),
        ),
      );
    }
  }
  for (final AnnouncedPost a in announcedPosts(node, nowMillis: now).values) {
    if (a.hops != 2) {
      continue;
    }
    final HeldPost? h = held(a.post);
    if (h == null || h.author != a.author || h.hops != 2) {
      continue;
    }
    if (!h.removed && h.reach.hops < 3) {
      continue;
    }
    candidates.add(
      PostAnnouncement(
        post: a.post,
        author: a.author,
        millis: h.post?.hlc.millis ?? a.millis,
        reach: PostReach.third,
        hops: 3,
        authorAddress: h.authorProfile?.address ?? a.authorAddress,
        editMillis: h.editMillis,
        removed: h.removed,
      ),
    );
  }
  candidates.sort(
    (PostAnnouncement x, PostAnnouncement y) => y.millis.compareTo(x.millis),
  );
  final List<PostAnnouncement> out = <PostAnnouncement>[];
  for (final PostAnnouncement c in candidates) {
    final String? before = passed[c.post];
    // Unchanged, or removed before it was ever passed on: nothing to say.
    if (before == c.state || (before == null && c.removed)) {
      continue;
    }
    if (out.length >= kMaxAnnouncedPerEntry || today >= kMaxAnnouncedPerDay) {
      break;
    }
    if ((perAuthor[c.author] ?? 0) >= kMaxAnnouncedPerAuthorDay) {
      continue;
    }
    out.add(c);
    today++;
    perAuthor[c.author] = (perAuthor[c.author] ?? 0) + 1;
  }
  return out;
}
