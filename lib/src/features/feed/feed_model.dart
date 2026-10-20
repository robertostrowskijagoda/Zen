import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/feed/thread_moderation.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

/// Longest post text accepted (longer ones from others are cut).
const int kMaxPostChars = 5000;

/// Entry kind of a post in a `feed/<account>` space.
const String kPostKind = 'post';

/// Entry kind of a post's removal (a signed tombstone in the same feed).
/// For public posts already copied elsewhere it is a request, not a guarantee.
const String kPostDeleteKind = 'post_del';

/// Entry kind of a new version of a post ("edytowano"): its text and, when
/// the body has `img`, its photos and videos too.
const String kPostEditKind = 'post_edit';

Map<String, dynamic> deletePostBody(String postId) => <String, dynamic>{
  'post': postId,
};

/// Body of an edit of [postId] (validated like a new post). With [images]
/// the post's photos and videos are replaced too (`img`, even when empty);
/// without, they stay as they were.
Map<String, dynamic> editPostBody(
  String postId,
  String text, {
  Audience audience = Audience.public,
  List<Map<String, dynamic>>? images,
}) => <String, dynamic>{
  ...newPostBody(
    text,
    audience: audience,
    images: images ?? const <Map<String, dynamic>>[],
  ),
  'img': ?images,
  'post': postId,
};

/// Entry kind of a like / unlike in an `acts/<account>` space. The latest
/// entry per post wins, so likes can be taken back.
const String kLikeKind = 'like';

/// Entry kind of a reshare in the resharer's `feed/<account>` space. The
/// body carries the whole signed original, so friends of the resharer can
/// check it came from its author without following them.
const String kReshareKind = 'reshare';

/// Body of a reshare of [original] (a post, never a reshare). With
/// [authorProfile] (the author's newest signed profile entry) friends of the
/// resharer also learn the author's name and address, to follow them.
Map<String, dynamic> reshareBody(LogEntry original, {LogEntry? authorProfile}) {
  if (original.kind != kPostKind) {
    throw ArgumentError(t('Udostępnić można tylko post.'));
  }
  if (isSealed(original.body) || original.body['aud'] != Audience.public.name) {
    throw ArgumentError(t('Udostępnić można tylko post publiczny.'));
  }
  return <String, dynamic>{
    'entry': original.toJson(),
    if (authorProfile != null &&
        authorProfile.kind == kProfileKind &&
        authorProfile.account == original.account)
      'profile': authorProfile.toJson(),
  };
}

/// Parses [json] as an entry and checks its certificate and signature.
Future<LogEntry?> verifiedEntry(Object? json) async {
  final LogEntry? entry = LogEntry.fromJson(json);
  if (entry == null ||
      entry.certificate.account != entry.account ||
      entry.certificate.device != entry.device) {
    return null;
  }
  if (!await entry.certificate.verify() || !await entry.verifySignature()) {
    return null;
  }
  return entry;
}

/// The verified original inside [reshare], or `null` if anything is off.
Future<LogEntry?> unpackReshare(LogEntry reshare) async {
  if (reshare.kind != kReshareKind) {
    return null;
  }
  final LogEntry? original = await verifiedEntry(reshare.body['entry']);
  if (original == null ||
      original.kind != kPostKind ||
      isSealed(original.body) ||
      original.space != accountSpace('feed', original.account)) {
    return null;
  }
  return original;
}

/// The author's verified profile carried by [reshare] (see [reshareBody]).
Future<LedgerProfile?> unpackReshareProfile(
  LogEntry reshare,
  LogEntry original,
) async {
  final Object? json = reshare.body['profile'];
  if (json == null) {
    return null;
  }
  final LogEntry? entry = await verifiedEntry(json);
  if (entry == null || entry.account != original.account) {
    return null;
  }
  return profileFromEntry(entry);
}

/// Entry kind of a passed-on tombstone in a resharer's feed (§10): the
/// author removed a post this account reshared, and friends of this
/// account (who may not follow the author) should hide it too. The body
/// carries the author's signed `post_del`; older versions ignore it.
const String kReshareDeleteKind = 'reshare_del';

/// Body passing on the author's signed [tombstone].
Map<String, dynamic> reshareDeleteBody(LogEntry tombstone) {
  if (tombstone.kind != kPostDeleteKind || tombstone.body['post'] is! String) {
    throw ArgumentError.value(tombstone.kind, 'tombstone');
  }
  return <String, dynamic>{
    'post': tombstone.body['post'],
    'entry': tombstone.toJson(),
  };
}

/// The author's verified tombstone inside [e], or `null`.
Future<LogEntry?> unpackTombstone(LogEntry e) async {
  if (e.kind != kReshareDeleteKind) {
    return null;
  }
  final LogEntry? tomb = await verifiedEntry(e.body['entry']);
  final Object? post = tomb?.body['post'];
  if (tomb == null ||
      tomb.kind != kPostDeleteKind ||
      tomb.space != accountSpace('feed', tomb.account) ||
      post is! String ||
      post != e.body['post']) {
    return null;
  }
  return tomb;
}

/// Checked reshares, by reshare entry id (a bad one maps to `null`), and
/// the tombstones resharers passed on.
final class ReshareCache {
  final Map<String, LogEntry?> _checked = <String, LogEntry?>{};
  final Map<String, LedgerProfile> _profiles = <String, LedgerProfile>{};

  /// Removed post id → its author (from passed-on tombstones).
  final Map<String, String> _removed = <String, String>{};

  bool isChecked(String reshareId) => _checked.containsKey(reshareId);

  LogEntry? originalOf(String reshareId) => _checked[reshareId];

  /// The author's profile carried by the reshare, if valid.
  LedgerProfile? profileOf(String reshareId) => _profiles[reshareId];

  /// Whether the author of [original] removed it (a tombstone signed by
  /// them reached this device through a resharer).
  bool isRemoved(LogEntry original) =>
      _removed[original.id] == original.account;

  /// Checks the reshares and passed-on tombstones not seen yet; true if any
  /// new one was valid.
  Future<bool> checkAll(Iterable<LogEntry> entries) async {
    bool added = false;
    for (final LogEntry e in entries.toList()) {
      if (e.kind == kReshareDeleteKind && !_checked.containsKey(e.id)) {
        _checked[e.id] = null;
        final LogEntry? tomb = await unpackTombstone(e);
        if (tomb != null) {
          _removed[tomb.body['post'] as String] = tomb.account;
          added = true;
        }
        continue;
      }
      if (e.kind != kReshareKind || _checked.containsKey(e.id)) {
        continue;
      }
      final LogEntry? original = await unpackReshare(e);
      _checked[e.id] = original;
      if (original != null) {
        final LedgerProfile? profile = await unpackReshareProfile(e, original);
        if (profile != null) {
          _profiles[e.id] = profile;
        }
      }
      added = added || original != null;
    }
    return added;
  }
}

/// Entry kind of a comment in the commenter's `acts/<account>` space.
const String kCommentKind = 'comment';

/// Longest comment text accepted.
const int kMaxCommentChars = 1000;

@immutable
final class FeedComment {
  const FeedComment({
    required this.id,
    required this.authorLabel,
    required this.text,
    required this.millis,
    this.authorAddress = '',
    this.account = '',
    this.hiddenByAuthor = false,
    this.avatar,
  });

  final String id;
  final String authorLabel;
  final String text;
  final int millis;

  /// The author's device address when they are a friend ('' otherwise):
  /// a report of the comment names its author (§21.4).
  final String authorAddress;

  /// Who wrote it ('' when unknown).
  final String account;

  /// Hidden by the post's author (§11): only the author still sees it, to
  /// show it again.
  final bool hiddenByAuthor;

  /// The writer's profile photo from their mini-profile (§9), when the
  /// comment came with one.
  final MediaRef? avatar;

  FeedComment hidden() => FeedComment(
    id: id,
    authorLabel: authorLabel,
    text: text,
    millis: millis,
    authorAddress: authorAddress,
    account: account,
    hiddenByAuthor: true,
    avatar: avatar,
  );
}

/// Someone who likes a post.
@immutable
final class FeedLiker {
  const FeedLiker({
    required this.account,
    required this.name,
    this.friend = false,
    this.verified = false,
    this.avatar,
  });

  final String account;
  final String name;

  /// The liker's profile photo from their mini-profile (§9), when known.
  final MediaRef? avatar;

  /// This account or a friend (shown first: "Lubią to: Bob, Kasia…").
  final bool friend;

  /// In the pyramid, or met in person by this account or one of its
  /// friends (a signed attestation, §6.2): "w tym N zweryfikowanych"
  /// (§11).
  final bool verified;

  FeedLiker withVerified(bool on) => on == verified
      ? this
      : FeedLiker(
          account: account,
          name: name,
          friend: friend,
          verified: on,
          avatar: avatar,
        );
}

/// "w tym 830 zweryfikowanych" (§11): how many of those who like [post]
/// are in the pyramid or were met in person by this account or its
/// friends; `null` for none.
String? verifiedSummary(FeedPost post) {
  final int n = post.verifiedLikes;
  if (n <= 0) {
    return null;
  }
  return tn(
    n,
    one: 'w tym {n} zweryfikowana',
    few: 'w tym {n} zweryfikowane',
    many: 'w tym {n} zweryfikowanych',
  );
}

/// "Lubią to: Ty, Bob i 1 284 inne osoby" (§11): up to two names of
/// friends first, then how many others; `null` when nobody likes [post].
String? likeSummary(FeedPost post) {
  final int total = post.likeTotal;
  if (total <= 0) {
    return null;
  }
  final List<String> named = <String>[
    for (final FeedLiker l in post.likes)
      if (l.friend) l.name,
  ].take(2).toList();
  final int others = total - named.length;
  if (named.isEmpty) {
    return tn(
      others,
      one: 'Lubi to {n} osoba',
      few: 'Lubią to {n} osoby',
      many: 'Lubi to {n} osób',
    );
  }
  final String names = named.join(', ');
  if (others <= 0) {
    return t('Lubią to: {names}', {'names': names});
  }
  return tn(
    others,
    one: 'Lubią to: {names} i {n} inna osoba',
    few: 'Lubią to: {names} i {n} inne osoby',
    many: 'Lubią to: {names} i {n} innych osób',
    args: <String, Object?>{'names': names},
  );
}

/// Body of a comment on [postId] (validated, trimmed). With [mini] the
/// writer's mini-profile goes along, signed with the comment (§9).
Map<String, dynamic> commentBody(
  String postId,
  String text, {
  MiniProfileTag? mini,
}) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError(t('Pusty komentarz.'));
  }
  if (trimmed.length > kMaxCommentChars) {
    throw ArgumentError(
      tn(
        kMaxCommentChars,
        one: 'Komentarz jest za długi (maks. {n} znak).',
        few: 'Komentarz jest za długi (maks. {n} znaki).',
        many: 'Komentarz jest za długi (maks. {n} znaków).',
      ),
    );
  }
  return withMiniProfile(<String, dynamic>{
    'post': postId,
    'text': trimmed,
  }, mini);
}

@immutable
final class FeedPost {
  const FeedPost({
    required this.id,
    required this.account,
    required this.authorLabel,
    required this.text,
    required this.millis,
    required this.isOwn,
    this.likers = const <String>[],
    this.likedByMe = false,
    this.comments = const <FeedComment>[],
    this.resharedBy = const <String>[],
    this.entry,
    this.edited = false,
    this.authorAddress = '',
    this.audience = Audience.public,
    this.images = const <MediaRef>[],
    this.likes = const <FeedLiker>[],
    int? likeTotal,
    int? commentTotal,
    int? sortMillis,
  }) : sortMillis = sortMillis ?? millis,
       _likeTotal = likeTotal,
       _commentTotal = commentTotal;

  final String id;
  final String account;
  final String authorLabel;
  final String text;
  final int millis;
  final bool isOwn;

  /// Display names of those who like the post (visible to this node):
  /// this account and friends first.
  final List<String> likers;
  final bool likedByMe;

  /// Who likes the post, in the order of [likers].
  final List<FeedLiker> likes;

  final int? _likeTotal;
  final int? _commentTotal;

  /// How many like it in all: at least [likers], more when a bundle said
  /// there are more than it carried (§11).
  int get likeTotal => _likeTotal ?? likers.length;

  /// How many of [likes] are verified ([FeedLiker.verified]).
  int get verifiedLikes => likes.where((FeedLiker l) => l.verified).length;

  /// How many comments in all (the same way).
  int get commentTotal => _commentTotal ?? comments.length;

  /// Oldest first.
  final List<FeedComment> comments;

  /// Who brought this post to the wall (empty for own and friends' posts).
  final List<String> resharedBy;

  /// Author's mesh address when known from a profile ('' otherwise), for
  /// following a friend of a friend.
  final String authorAddress;

  /// Photos (encrypted blobs, fetched in the background).
  final List<MediaRef> images;

  /// Who may read it (only public posts can be reshared).
  final Audience audience;

  /// Shown with "edytowano": the text is a later version.
  final bool edited;

  /// The signed post itself (what a reshare carries).
  final LogEntry? entry;

  /// Position on the wall: the post time, or the latest reshare.
  final int sortMillis;

  FeedPost withReactions(
    List<String> likers, {
    required bool likedByMe,
    required List<FeedComment> comments,
    List<FeedLiker> likes = const <FeedLiker>[],
    int? likeTotal,
    int? commentTotal,
  }) => FeedPost(
    id: id,
    account: account,
    authorLabel: authorLabel,
    text: text,
    millis: millis,
    isOwn: isOwn,
    likers: likers,
    likedByMe: likedByMe,
    comments: comments,
    resharedBy: resharedBy,
    entry: entry,
    edited: edited,
    authorAddress: authorAddress,
    audience: audience,
    images: images,
    sortMillis: sortMillis,
    likes: likes,
    likeTotal: likeTotal,
    commentTotal: commentTotal,
  );
}

/// Body of a like (or, with [on] false, of taking it back). With [mini] the
/// liker's mini-profile goes along, signed with the like (§9).
Map<String, dynamic> likeBody(
  String postId, {
  bool on = true,
  MiniProfileTag? mini,
}) =>
    withMiniProfile(<String, dynamic>{'post': postId, 'on': on ? 1 : 0}, mini);

/// Post ids liked in one account's acts, latest entry per post winning.
Set<String> likedPosts(Iterable<LogEntry> acts) {
  final Map<String, (int, bool)> latest = <String, (int, bool)>{};
  for (final LogEntry e in acts) {
    if (e.kind != kLikeKind) {
      continue;
    }
    final Object? post = e.body['post'];
    if (post is! String) {
      continue;
    }
    final int at = e.hlc.toInt();
    final (int, bool)? seen = latest[post];
    if (seen == null || at >= seen.$1) {
      latest[post] = (at, e.body['on'] == 1);
    }
  }
  return <String>{
    for (final MapEntry<String, (int, bool)> m in latest.entries)
      if (m.value.$2) m.key,
  };
}

/// Body of a new post (validated, trimmed). Anything but a public post is
/// then sealed with [LedgerNode.seal] before it is written.
///
/// [images] are references from [storeMedia]; a post with photos may have
/// no text.
Map<String, dynamic> newPostBody(
  String text, {
  Audience audience = Audience.public,
  List<Map<String, dynamic>> images = const <Map<String, dynamic>>[],
}) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty && images.isEmpty) {
    throw ArgumentError(t('Pusty post.'));
  }
  if (trimmed.length > kMaxPostChars) {
    throw ArgumentError(
      tn(
        kMaxPostChars,
        one: 'Post jest za długi (maks. {n} znak).',
        few: 'Post jest za długi (maks. {n} znaki).',
        many: 'Post jest za długi (maks. {n} znaków).',
      ),
    );
  }
  if (images.length > kMaxPostImages) {
    throw ArgumentError(
      tn(
        kMaxPostImages,
        one: 'Najwyżej {n} zdjęcie lub film w poście.',
        few: 'Najwyżej {n} zdjęcia i filmy w poście.',
        many: 'Najwyżej {n} zdjęć i filmów w poście.',
      ),
    );
  }
  return <String, dynamic>{
    'text': trimmed,
    'aud': audience.name,
    if (images.isNotEmpty) 'img': images,
  };
}

/// Blob ids of [images], for [LedgerNode.publish]'s `blobs`.
List<String> mediaIds(List<Map<String, dynamic>> images) => <String>[
  for (final Map<String, dynamic> m in images)
    if (m['id'] is String) m['id'] as String,
];

FeedPost? _postFrom(
  LogEntry entry, {
  required bool isOwn,
  required String authorLabel,
  Map<String, dynamic>? body,
}) {
  final Map<String, dynamic> b = body ?? entry.body;
  if (entry.kind != kPostKind) {
    return null;
  }
  final Object? text = b['text'];
  final Object? img = b['img'];
  final List<MediaRef> images = <MediaRef>[
    if (img is List)
      for (final Object? m in img.take(kMaxPostImages)) ?mediaRefFromJson(m),
  ];
  if (text is! String || (text.trim().isEmpty && images.isEmpty)) {
    return null;
  }
  return FeedPost(
    id: entry.id,
    account: entry.account,
    authorLabel: authorLabel,
    text: text.length > kMaxPostChars ? text.substring(0, kMaxPostChars) : text,
    millis: entry.hlc.millis,
    isOwn: isOwn,
    entry: entry,
    audience: audienceByName(b['aud']) ?? Audience.public,
    images: images,
  );
}

/// Posts of one feed with edits applied and removed ones left out; ids of
/// removed posts go to [deleted] (so their reshares are hidden too).
List<FeedPost> _postsOf(
  Iterable<LogEntry> feed, {
  required bool isOwn,
  required String authorLabel,
  required Set<String> deleted,
  required Map<String, dynamic>? Function(LogEntry entry) bodyOf,
}) {
  final List<FeedPost> posts = <FeedPost>[];
  final Map<String, LogEntry> lastEdit = <String, LogEntry>{};
  // A tombstone only counts for a post of the same feed (same author).
  final Set<String> removed = <String>{};
  for (final LogEntry e in feed) {
    final Map<String, dynamic>? body = bodyOf(e);
    if (body == null) {
      continue; // sealed and no key: not for us
    }
    final Object? target = body['post'];
    if (e.kind == kPostDeleteKind && target is String) {
      removed.add(target);
    } else if (e.kind == kPostEditKind && target is String) {
      final LogEntry? had = lastEdit[target];
      if (had == null || e.hlc > had.hlc) {
        lastEdit[target] = e;
      }
    } else {
      final FeedPost? post = _postFrom(
        e,
        isOwn: isOwn,
        authorLabel: authorLabel,
        body: body,
      );
      if (post != null) {
        posts.add(post);
      }
    }
  }
  final List<FeedPost> kept = <FeedPost>[];
  for (final FeedPost p in posts) {
    if (removed.contains(p.id)) {
      deleted.add(p.id);
    } else {
      final LogEntry? edit = lastEdit[p.id];
      kept.add(_edited(p, edit == null ? null : bodyOf(edit)));
    }
  }
  return kept;
}

FeedPost _edited(FeedPost post, Map<String, dynamic>? edit) {
  final Object? text = edit?['text'];
  final Object? img = edit?['img'];
  final List<MediaRef> images = img is List
      ? <MediaRef>[
          for (final Object? m in img.take(kMaxPostImages))
            ?mediaRefFromJson(m),
        ]
      : post.images;
  if (edit == null ||
      text is! String ||
      (text.trim().isEmpty && images.isEmpty)) {
    return post;
  }
  return FeedPost(
    id: post.id,
    account: post.account,
    authorLabel: post.authorLabel,
    text: text.length > kMaxPostChars ? text.substring(0, kMaxPostChars) : text,
    millis: post.millis,
    isOwn: post.isOwn,
    entry: post.entry,
    audience: post.audience,
    images: images,
    edited: true,
  );
}

/// This account's posts and those of friends and followed accounts whose
/// keys are known (plus, with [reshares], posts reshared by friends),
/// newest first. [nameOf] turns a friend's mesh address into a display name.
/// [pyramidAddresses] are the device addresses of the pyramid's members:
/// their accounts count as verified (§11).
List<FeedPost> buildFeed(
  LedgerNode node, {
  required String Function(String address) nameOf,
  ReshareCache? reshares,
  Set<String> pyramidAddresses = const <String>{},
}) {
  final Set<String> deleted = <String>{};
  final List<FeedPost> posts = _postsOf(
    node.entriesOf(),
    isOwn: true,
    authorLabel: t('Ty'),
    deleted: deleted,
    bodyOf: node.bodyOf,
  );
  final Map<String, String> accountNames = <String, String>{};
  void addFeed(String address, String account, {bool friend = true}) {
    if (accountNames.containsKey(account) || account == node.account) {
      return;
    }
    final String own = friend ? '' : latestProfile(node, account)?.name ?? '';
    final String name = own.isNotEmpty ? own : nameOf(address);
    accountNames[account] = name;
    posts.addAll(
      _postsOf(
        node.entriesOf(ofAccount: account),
        isOwn: false,
        authorLabel: name,
        deleted: deleted,
        bodyOf: node.bodyOf,
      ),
    );
  }

  node.friendAccounts.forEach(addFeed);
  node.followedAccounts.forEach(
    (String address, String account) =>
        addFeed(address, account, friend: false),
  );
  if (reshares != null) {
    final Set<String> shown = <String>{for (final FeedPost p in posts) p.id};
    final Map<String, (LogEntry, List<String>, int, LedgerProfile?)> brought =
        <String, (LogEntry, List<String>, int, LedgerProfile?)>{};
    void addReshares(Iterable<LogEntry> feed, String name) {
      for (final LogEntry e in feed) {
        final LogEntry? original = reshares.originalOf(e.id);
        if (original == null ||
            shown.contains(original.id) ||
            deleted.contains(original.id) ||
            reshares.isRemoved(original)) {
          continue;
        }
        final (LogEntry, List<String>, int, LedgerProfile?)? had =
            brought[original.id];
        final List<String> who = had?.$2 ?? <String>[];
        if (!who.contains(name)) {
          who.add(name);
        }
        final int at = e.hlc.millis;
        brought[original.id] = (
          original,
          who,
          had == null || at > had.$3 ? at : had.$3,
          had?.$4 ?? reshares.profileOf(e.id),
        );
      }
    }

    addReshares(node.entriesOf(), t('Ty'));
    node.friendAccounts.forEach((String address, String account) {
      addReshares(node.entriesOf(ofAccount: account), nameOf(address));
    });
    for (final (LogEntry, List<String>, int, LedgerProfile?) b
        in brought.values) {
      final LedgerProfile? profile = b.$4;
      final String carried = profile?.name ?? '';
      final String author =
          accountNames[b.$1.account] ??
          (b.$1.account == node.account
              ? t('Ty')
              : (carried.isNotEmpty ? carried : t('Znajomy znajomego')));
      final FeedPost? post = _postFrom(
        b.$1,
        isOwn: b.$1.account == node.account,
        authorLabel: author,
      );
      if (post != null) {
        posts.add(
          FeedPost(
            id: post.id,
            account: post.account,
            authorLabel: post.authorLabel,
            text: post.text,
            millis: post.millis,
            isOwn: post.isOwn,
            resharedBy: b.$2,
            entry: b.$1,
            authorAddress: profile?.address ?? '',
            images: post.images,
            sortMillis: b.$3,
          ),
        );
      }
    }
  }

  final List<LogEntry> myActs = node.entriesOf(spaceKind: 'acts');
  final Set<String> mine = likedPosts(myActs);
  // Post id -> liker account -> liker (direct likes win over bundles).
  final Map<String, Map<String, FeedLiker>> likers =
      <String, Map<String, FeedLiker>>{};
  final Map<String, List<FeedComment>> comments = <String, List<FeedComment>>{};
  final Set<String> commentIds = <String>{};
  // What came in bundles: the author's decisions passed on in bundles
  // apply to these only (people in the circle speak for themselves).
  final Set<String> relayedComments = <String>{};
  final Set<String> relayedLikes = <String>{};
  final Map<String, ThreadModeration> passedOn = <String, ThreadModeration>{};
  final Map<String, int> likeTotals = <String, int>{};
  final Map<String, int> commentTotals = <String, int>{};
  void addComment(String post, FeedComment c) {
    if (commentIds.add(c.id)) {
      (comments[post] ??= <FeedComment>[]).add(c);
    }
  }

  void collect(
    Iterable<LogEntry> acts,
    String name,
    String account, [
    String address = '',
  ]) {
    for (final String id in likedPosts(acts)) {
      (likers[id] ??= <String, FeedLiker>{})[account] = FeedLiker(
        account: account,
        name: name,
        friend: true,
      );
    }
    for (final LogEntry e in acts) {
      final Object? post = e.body['post'];
      final Object? text = e.body['text'];
      if (e.kind != kCommentKind ||
          post is! String ||
          text is! String ||
          text.trim().isEmpty) {
        continue;
      }
      addComment(
        post,
        FeedComment(
          id: e.id,
          authorLabel: name,
          text: text.length > kMaxCommentChars
              ? text.substring(0, kMaxCommentChars)
              : text,
          millis: e.hlc.millis,
          authorAddress: address,
          account: account,
        ),
      );
    }
  }

  final String you = t('Ty');
  final Map<String, String> friendNames = <String, String>{node.account: you};
  collect(myActs, you, node.account);
  node.friendAccounts.forEach((String address, String account) {
    final String name = nameOf(address);
    friendNames[account] = name;
    collect(
      node.entriesOf(spaceKind: 'acts', ofAccount: account),
      name,
      account,
      address,
    );
  });
  // Reactions from outside the circle, relayed along the reshare tree.
  //
  // A bundle is only the relaying friend's word for who reacted: it can
  // name any account and any name. So an entry claiming someone in the
  // circle is ignored (they speak for themselves, through their own acts
  // collected above), and everyone else is shown as relayed by the friend
  // whose bundle it was - never as if they were a friend themselves.
  void mergeBundles(Iterable<LogEntry> acts, {String? relayedBy}) {
    String relayedLabel(String name) {
      final String shown = name.trim().isEmpty
          ? t('Znajomy znajomego')
          : name.trim();
      return relayedBy == null
          ? t('{name} (znajomy znajomego)', {'name': shown})
          : t('{name} (przez {via})', {'name': shown, 'via': relayedBy});
    }

    for (final MapEntry<String, PostReactions> b in readBundles(acts).entries) {
      final String post = b.key;
      final PostReactions r = b.value;
      passedOn[post] = (passedOn[post] ?? ThreadModeration.none).merge(
        r.moderation,
      );
      likeTotals[post] = math.max(likeTotals[post] ?? 0, r.likeTotal);
      commentTotals[post] = math.max(commentTotals[post] ?? 0, r.commentTotal);
      for (final BundleLike l in r.likes) {
        if (friendNames.containsKey(l.account)) {
          continue;
        }
        final Map<String, FeedLiker> those = likers[post] ??=
            <String, FeedLiker>{};
        if (!those.containsKey(l.account)) {
          those[l.account] = FeedLiker(
            account: l.account,
            name: relayedLabel(l.name),
            avatar: l.avatar,
          );
          relayedLikes.add('$post\n${l.account}');
        }
      }
      for (final BundleComment c in r.comments) {
        if (friendNames.containsKey(c.account) || commentIds.contains(c.id)) {
          continue;
        }
        relayedComments.add(c.id);
        addComment(
          post,
          FeedComment(
            id: c.id,
            authorLabel: relayedLabel(c.name),
            text: c.text,
            millis: c.millis,
            account: c.account,
            avatar: c.avatar,
          ),
        );
      }
    }
  }

  for (final String account in node.friendAccounts.values) {
    mergeBundles(
      node.entriesOf(spaceKind: 'acts', ofAccount: account),
      relayedBy: friendNames[account],
    );
  }
  // This account's own bundles pass on what other people's bundles said;
  // who said it to us first is no longer known.
  mergeBundles(myActs);
  for (final List<FeedComment> list in comments.values) {
    list.sort((FeedComment a, FeedComment b) => a.millis.compareTo(b.millis));
  }
  // The author's say over the thread (§11): their signed entries (when
  // this device reads their acts) and what their bundles passed on.
  final Map<String, ThreadModeration> signed = <String, ThreadModeration>{};
  // In the pyramid, or met in person by this account or a friend (§6.2):
  // "verified" (§11).
  final Set<String> verified = <String>{
    ...node.metByCircle(),
    for (final String address in pyramidAddresses)
      ?node.accountOfAddress(address),
  };
  final List<FeedPost> result = <FeedPost>[];
  for (final FeedPost p in posts) {
    final ThreadModeration own = signed[p.account] ??= authorModeration(
      node,
      p.account,
    );
    final ThreadModeration bundled = passedOn[p.id] ?? ThreadModeration.none;
    bool blocked(String account, {required bool relayed}) =>
        account.isNotEmpty &&
        (own.blocks(account) || (relayed && bundled.blocks(account)));
    final List<FeedLiker> kept = <FeedLiker>[
      for (final FeedLiker l in likers[p.id]?.values ?? const <FeedLiker>[])
        if (!blocked(
          l.account,
          relayed: relayedLikes.contains('${p.id}\n${l.account}'),
        ))
          l.withVerified(verified.contains(l.account)),
    ];
    // This account first, then friends, then everyone else.
    final List<FeedLiker> ordered = <FeedLiker>[
      for (final FeedLiker l in kept)
        if (l.account == node.account) l,
      for (final FeedLiker l in kept)
        if (l.account != node.account && l.friend) l,
      for (final FeedLiker l in kept)
        if (!l.friend) l,
    ];
    final List<FeedComment> shown = <FeedComment>[];
    for (final FeedComment c in comments[p.id] ?? const <FeedComment>[]) {
      final bool relayed = relayedComments.contains(c.id);
      if (blocked(c.account, relayed: relayed)) {
        continue;
      }
      final bool hidden =
          own.hidesComment(p.id, c.id) ||
          (relayed && bundled.hidesComment(p.id, c.id));
      if (!hidden) {
        shown.add(c);
      } else if (p.account == node.account) {
        // The author still sees it, marked, to show it again.
        shown.add(c.hidden());
      }
    }
    final int visible = shown
        .where((FeedComment c) => !c.hiddenByAuthor)
        .length;
    result.add(
      p.withReactions(
        <String>[for (final FeedLiker l in ordered) l.name],
        likedByMe: mine.contains(p.id),
        comments: shown,
        likes: ordered,
        likeTotal: math.max(ordered.length, likeTotals[p.id] ?? 0),
        commentTotal: math.max(visible, commentTotals[p.id] ?? 0),
      ),
    );
  }
  result.sort((FeedPost a, FeedPost b) => b.sortMillis.compareTo(a.sortMillis));
  return result;
}
