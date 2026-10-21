import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/feed/thread_moderation.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_pass.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

/// Everything [buildFilms] reads, so it can be built without a node in
/// tests: feeds and acts per account, bodies (opened for sealed films).
abstract interface class FilmLedgerView {
  String get account;

  /// Friends: normalised address → account.
  Map<String, String> get friendAccounts;

  /// Followed accounts that are not friends: address → account.
  Map<String, String> get followedAccounts;

  /// Entries of [spaceKind] of [ofAccount] (default: this account).
  List<LogEntry> entriesOf({String spaceKind = 'feed', String? ofAccount});

  /// What [entry] says (decrypted for a sealed one), `null` without a key.
  Map<String, dynamic>? bodyOf(LogEntry entry);

  /// Whether friend [address] is a close friend.
  bool isClose(String address);

  /// The newest profile name of [account] ('' when unknown).
  String profileNameOf(String account);

  /// The author's say over comments under their films.
  ThreadModeration moderationOf(String account);
}

/// [FilmLedgerView] of a [LedgerNode].
final class NodeFilmLedgerView implements FilmLedgerView {
  NodeFilmLedgerView(this.node);

  final LedgerNode node;

  @override
  String get account => node.account;

  @override
  Map<String, String> get friendAccounts => node.friendAccounts;

  @override
  Map<String, String> get followedAccounts => node.followedAccounts;

  @override
  List<LogEntry> entriesOf({String spaceKind = 'feed', String? ofAccount}) =>
      node.entriesOf(spaceKind: spaceKind, ofAccount: ofAccount);

  @override
  Map<String, dynamic>? bodyOf(LogEntry entry) => node.bodyOf(entry);

  @override
  bool isClose(String address) => node.levelOf(address) == FriendLevel.close;

  @override
  String profileNameOf(String account) =>
      latestProfile(node, account)?.name ?? '';

  @override
  ThreadModeration moderationOf(String account) =>
      authorModeration(node, account);
}

/// The films this account can watch, with their reactions: its own, its
/// friends' and followed people's, and with [friendsOfFriends] the public
/// films friends passed on ([passes] must have checked them). Unordered;
/// `orderFilms` puts them in the order they play. [nameOf] turns a
/// friend's address into a display name.
List<FilmPost> buildFilms(
  FilmLedgerView view, {
  required String Function(String address) nameOf,
  FilmPassCache? passes,
  bool friendsOfFriends = false,
}) {
  final String me = view.account;
  final Map<String, FilmPost> films = <String, FilmPost>{};
  // Removed films: a tombstone only counts in its author's own feed.
  final Set<String> removed = <String>{};

  void addFeed(
    String account, {
    required String label,
    String address = '',
    bool close = false,
  }) {
    for (final LogEntry e in view.entriesOf(ofAccount: account)) {
      if (e.account != account) {
        continue;
      }
      if (e.kind == kPostDeleteKind) {
        final Object? target = view.bodyOf(e)?['post'];
        if (target is String) {
          removed.add(target);
        }
        continue;
      }
      if (e.kind != kFilmKind) {
        continue;
      }
      final Map<String, dynamic>? body = view.bodyOf(e);
      if (body == null) {
        continue; // sealed for an audience this account is not in
      }
      final FilmPost? film = filmFromEntry(
        e,
        body,
        isOwn: account == me,
        authorLabel: label,
        authorAddress: address,
        close: close,
      );
      if (film != null) {
        films[film.id] = film;
      }
    }
  }

  addFeed(me, label: t('Ty'));
  final Map<String, String> friendNames = <String, String>{me: t('Ty')};
  view.friendAccounts.forEach((String address, String account) {
    if (account == me || friendNames.containsKey(account)) {
      return;
    }
    final String name = nameOf(address);
    friendNames[account] = name;
    addFeed(
      account,
      label: name,
      address: address,
      close: view.isClose(address),
    );
  });
  final Set<String> followed = <String>{};
  view.followedAccounts.forEach((String address, String account) {
    if (account == me || friendNames.containsKey(account)) {
      return;
    }
    final String own = view.profileNameOf(account);
    followed.add(account);
    addFeed(
      account,
      label: own.isNotEmpty ? own : nameOf(address),
      address: address,
    );
  });
  films.removeWhere((String id, FilmPost f) => removed.contains(id));

  if (friendsOfFriends && passes != null) {
    // Film id -> (film, passer names, passer addresses, hint).
    final Map<String, (LogEntry, List<String>, List<String>, FilmPassHint?)>
    passed = <String, (LogEntry, List<String>, List<String>, FilmPassHint?)>{};
    view.friendAccounts.forEach((String address, String account) {
      final String passer = friendNames[account] ?? nameOf(address);
      for (final LogEntry e in view.entriesOf(
        spaceKind: 'acts',
        ofAccount: account,
      )) {
        if (e.kind != kFilmPassKind || e.account != account) {
          continue;
        }
        final LogEntry? film = passes.originalOf(e.id);
        if (film == null ||
            films.containsKey(film.id) ||
            removed.contains(film.id) ||
            film.account == me ||
            friendNames.containsKey(film.account) ||
            followed.contains(film.account)) {
          continue;
        }
        final (LogEntry, List<String>, List<String>, FilmPassHint?)? had =
            passed[film.id];
        final List<String> who = had?.$2 ?? <String>[];
        final List<String> where = had?.$3 ?? <String>[];
        if (!who.contains(passer)) {
          who.add(passer);
          where.add(address);
        }
        passed[film.id] = (film, who, where, had?.$4 ?? passes.hintOf(e.id));
      }
    });
    for (final (LogEntry, List<String>, List<String>, FilmPassHint?) p
        in passed.values) {
      final String hinted = p.$4?.name.trim() ?? '';
      final FilmPost? film = filmFromEntry(
        p.$1,
        p.$1.body,
        isOwn: false,
        authorLabel: hinted.isNotEmpty ? hinted : t('Znajomy znajomego'),
        authorAddress: p.$4?.address ?? '',
      );
      if (film != null) {
        films[film.id] = film.copyWith(passedBy: p.$2, passerAddresses: p.$3);
      }
    }
  }

  // Reactions of this account and its friends.
  final Map<String, Map<String, FeedLiker>> likers =
      <String, Map<String, FeedLiker>>{};
  final Map<String, List<FeedComment>> comments = <String, List<FeedComment>>{};
  final Map<String, Map<String, String>> reactions =
      <String, Map<String, String>>{};
  final Map<String, Set<String>> viewers = <String, Set<String>>{};
  void collect(String account, String name, String address) {
    final List<LogEntry> acts = view.entriesOf(
      spaceKind: 'acts',
      ofAccount: account,
    );
    for (final String id in likedPosts(acts)) {
      if (films.containsKey(id)) {
        (likers[id] ??= <String, FeedLiker>{})[account] = FeedLiker(
          account: account,
          name: name,
          friend: true,
        );
      }
    }
    filmReactionsOf(acts).forEach((String id, String emoji) {
      if (films.containsKey(id)) {
        (reactions[id] ??= <String, String>{})[account] = emoji;
      }
    });
    if (account != me) {
      for (final String id in seenFilms(acts)) {
        if (films[id]?.isOwn ?? false) {
          (viewers[id] ??= <String>{}).add(account);
        }
      }
    }
    for (final LogEntry e in acts) {
      final Object? post = e.body['post'];
      final Object? text = e.body['text'];
      if (e.kind != kCommentKind ||
          e.account != account ||
          post is! String ||
          text is! String ||
          text.trim().isEmpty ||
          !films.containsKey(post)) {
        continue;
      }
      (comments[post] ??= <FeedComment>[]).add(
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

  collect(me, t('Ty'), '');
  view.friendAccounts.forEach((String address, String account) {
    if (account != me) {
      collect(account, friendNames[account] ?? nameOf(address), address);
    }
  });

  // Likes and comments from outside the circle, passed on in bundles by a
  // friend (the friend who passed a film on, or its author): a bundle is
  // only that friend's word, so they show as relayed by them, and people
  // in the circle speak only for themselves.
  final Set<String> commentIds = <String>{
    for (final List<FeedComment> list in comments.values)
      for (final FeedComment c in list) c.id,
  };
  view.friendAccounts.forEach((String address, String account) {
    if (account == me) {
      return;
    }
    final String via = friendNames[account] ?? nameOf(address);
    String relayed(String name) => t('{name} (przez {via})', {
      'name': name.trim().isEmpty ? t('Znajomy znajomego') : name.trim(),
      'via': via,
    });
    readBundles(view.entriesOf(spaceKind: 'acts', ofAccount: account)).forEach((
      String id,
      PostReactions r,
    ) {
      if (!films.containsKey(id)) {
        return;
      }
      for (final BundleLike l in r.likes) {
        if (!friendNames.containsKey(l.account)) {
          (likers[id] ??= <String, FeedLiker>{}).putIfAbsent(
            l.account,
            () => FeedLiker(
              account: l.account,
              name: relayed(l.name),
              avatar: l.avatar,
            ),
          );
        }
      }
      for (final BundleComment c in r.comments) {
        if (friendNames.containsKey(c.account) || !commentIds.add(c.id)) {
          continue;
        }
        (comments[id] ??= <FeedComment>[]).add(
          FeedComment(
            id: c.id,
            authorLabel: relayed(c.name),
            text: c.text,
            millis: c.millis,
            account: c.account,
            avatar: c.avatar,
          ),
        );
      }
    });
  });

  final Map<String, List<String>> replies = <String, List<String>>{};
  for (final FilmPost f in films.values) {
    final FilmReplyRef? to = f.replyTo;
    if (to != null && films[to.id]?.account == to.account) {
      (replies[to.id] ??= <String>[]).add(f.id);
    }
  }
  final Map<String, ThreadModeration> moderation = <String, ThreadModeration>{};
  final List<FilmPost> out = <FilmPost>[];
  for (final FilmPost f in films.values) {
    final ThreadModeration rules = moderation[f.account] ??= view.moderationOf(
      f.account,
    );
    final List<FeedLiker> kept = <FeedLiker>[
      for (final FeedLiker l in likers[f.id]?.values ?? const <FeedLiker>[])
        if (!rules.blocks(l.account)) l,
    ];
    // This account first, then friends.
    final List<FeedLiker> likes = <FeedLiker>[
      for (final FeedLiker l in kept)
        if (l.account == me) l,
      for (final FeedLiker l in kept)
        if (l.account != me) l,
    ];
    final List<FeedComment> shown = <FeedComment>[];
    for (final FeedComment c in comments[f.id] ?? const <FeedComment>[]) {
      if (rules.blocks(c.account)) {
        continue;
      }
      if (!rules.hidesComment(f.id, c.id)) {
        shown.add(c);
      } else if (f.isOwn) {
        shown.add(c.hidden());
      }
    }
    shown.sort((FeedComment a, FeedComment b) => a.millis.compareTo(b.millis));
    final Map<String, int> counts = <String, int>{};
    final Map<String, String> byAccount =
        reactions[f.id] ?? const <String, String>{};
    for (final MapEntry<String, String> r in byAccount.entries) {
      if (!rules.blocks(r.key)) {
        counts[r.value] = (counts[r.value] ?? 0) + 1;
      }
    }
    final List<String> answers = replies[f.id] ?? const <String>[];
    out.add(
      f.copyWith(
        likes: likes,
        likedByMe: likers[f.id]?.containsKey(me) ?? false,
        comments: shown,
        reactions: counts,
        myReaction: byAccount[me] ?? '',
        views: f.isOwn ? (viewers[f.id]?.length ?? 0) : 0,
        replies: List<String>.of(answers)
          ..sort(
            (String a, String b) =>
                films[a]!.millis.compareTo(films[b]!.millis),
          ),
      ),
    );
  }
  return out;
}
