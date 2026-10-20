import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
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
Future<LogEntry?> _verified(Object? json) async {
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
  final LogEntry? original = await _verified(reshare.body['entry']);
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
  final LogEntry? entry = await _verified(json);
  if (entry == null || entry.account != original.account) {
    return null;
  }
  return profileFromEntry(entry);
}

/// Checked reshares, by reshare entry id (a bad one maps to `null`).
final class ReshareCache {
  final Map<String, LogEntry?> _checked = <String, LogEntry?>{};
  final Map<String, LedgerProfile> _profiles = <String, LedgerProfile>{};

  bool isChecked(String reshareId) => _checked.containsKey(reshareId);

  LogEntry? originalOf(String reshareId) => _checked[reshareId];

  /// The author's profile carried by the reshare, if valid.
  LedgerProfile? profileOf(String reshareId) => _profiles[reshareId];

  /// Checks the reshares not seen yet; true if any new one was valid.
  Future<bool> checkAll(Iterable<LogEntry> entries) async {
    bool added = false;
    for (final LogEntry e in entries.toList()) {
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
  });

  final String id;
  final String authorLabel;
  final String text;
  final int millis;
}

/// Body of a comment on [postId] (validated, trimmed).
Map<String, dynamic> commentBody(String postId, String text) {
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
  return <String, dynamic>{'post': postId, 'text': trimmed};
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
    int? sortMillis,
  }) : sortMillis = sortMillis ?? millis;

  final String id;
  final String account;
  final String authorLabel;
  final String text;
  final int millis;
  final bool isOwn;

  /// Display names of those who like the post (visible to this node).
  final List<String> likers;
  final bool likedByMe;

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
  );
}

/// Body of a like (or, with [on] false, of taking it back).
Map<String, dynamic> likeBody(String postId, {bool on = true}) =>
    <String, dynamic>{'post': postId, 'on': on ? 1 : 0};

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
List<FeedPost> buildFeed(
  LedgerNode node, {
  required String Function(String address) nameOf,
  ReshareCache? reshares,
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
            deleted.contains(original.id)) {
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
  // Post id -> liker account -> name (direct likes win over bundles).
  final Map<String, Map<String, String>> likers =
      <String, Map<String, String>>{};
  final Map<String, List<FeedComment>> comments = <String, List<FeedComment>>{};
  final Set<String> commentIds = <String>{};
  void addComment(String post, FeedComment c) {
    if (commentIds.add(c.id)) {
      (comments[post] ??= <FeedComment>[]).add(c);
    }
  }

  void collect(Iterable<LogEntry> acts, String name, String account) {
    for (final String id in likedPosts(acts)) {
      (likers[id] ??= <String, String>{})[account] = name;
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

    for (final LogEntry e in latestBundles(acts).values) {
      final String post = e.body['post'] as String;
      final ({List<BundleLike> likes, List<BundleComment> comments})? b =
          readBundle(e);
      if (b == null) {
        continue;
      }
      for (final BundleLike l in b.likes) {
        if (friendNames.containsKey(l.account)) {
          continue;
        }
        (likers[post] ??= <String, String>{}).putIfAbsent(
          l.account,
          () => relayedLabel(l.name),
        );
      }
      for (final BundleComment c in b.comments) {
        if (friendNames.containsKey(c.account)) {
          continue;
        }
        addComment(
          post,
          FeedComment(
            id: c.id,
            authorLabel: relayedLabel(c.name),
            text: c.text,
            millis: c.millis,
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
  final List<FeedPost> result = <FeedPost>[
    for (final FeedPost p in posts)
      p.withReactions(
        likers[p.id]?.values.toList() ?? const <String>[],
        likedByMe: mine.contains(p.id),
        comments: comments[p.id] ?? const <FeedComment>[],
      ),
  ];
  result.sort((FeedPost a, FeedPost b) => b.sortMillis.compareTo(a.sortMillis));
  return result;
}
