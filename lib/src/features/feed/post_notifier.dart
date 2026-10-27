import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// Notifications about friends' new posts: one system notification for
// everything new since the user last looked at the Tablica ("Nowy post od
// Ady", "3 nowe posty"), updated in place, and the same news in the in-app
// list. Only direct friends' own posts count: no own posts, no edits, no
// reshares, nothing passed on from friends of friends (post_reach.dart),
// nothing older than the last look at the Tablica. Each post is announced
// at most once: what was announced is kept in the ledger's store, so a
// restart or a post that arrives twice (from two of the friend's devices,
// from a mailbox) changes nothing.

/// Id prefix of the system notification and of the inbox entries about new
/// posts.
const String kPostNoticeIdPrefix = 'post-';

/// The one slot the notification about new posts takes: a later post
/// updates it ("3 nowe posty"), never adds a second one.
const String kPostNoticeSlot = 'feed-posts';

/// What was already announced (and when the Tablica was last looked at).
const String kNotifiedPostsKey = 'feed/notified_posts';

/// A post older than this is never announced (a new friend's old posts, a
/// phone that was off for a week).
const Duration kPostNoticeMaxAge = Duration(days: 3);

/// Posts remembered as announced at most (the newest ones).
const int _maxKnownPosts = 500;

/// Lines of a notification about several posts.
const int _maxLines = 6;

/// One friend's new post as a notification tells of it.
@immutable
final class NewPostNotice {
  const NewPostNotice({
    required this.postId,
    required this.author,
    required this.address,
    required this.preview,
    required this.millis,
    this.privacy = NotificationPrivacy.senderAndContent,
  });

  final String postId;

  /// The friend's name.
  final String author;

  /// The friend's device address.
  final String address;

  /// The beginning of the post, or the label of its first photo or film.
  final String preview;

  /// When it was written (newest first).
  final int millis;

  /// How much a notification about this friend may tell.
  final NotificationPrivacy privacy;
}

/// What a notification says of [post]: its beginning, or for a post with
/// photos or films only the label of the first one ("📷 Zdjęcie").
String postNoticePreview(FeedPost post) {
  final String text = mentionsAsPlainText(
    post.text,
    post.mentions,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isNotEmpty) {
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }
  if (post.images.isEmpty) {
    return '';
  }
  final String mime = post.images.first.mime;
  return chatMessageLabelForType(
    isVideoMime(mime)
        ? ChatMessageType.video
        : isAudioMime(mime)
        ? ChatMessageType.voice
        : ChatMessageType.image,
    mimeType: mime,
  );
}

/// "3 nowe posty".
String _postCount(int n) => tn(
  n,
  one: '{n} nowy post',
  few: '{n} nowe posty',
  many: '{n} nowych postów',
);

/// "Od: Ada, Bob".
String _fromNames(List<NewPostNotice> posts) {
  final List<String> names = <String>{
    for (final NewPostNotice p in posts) p.author,
  }.toList();
  final String shown = names.length > 3
      ? '${names.take(3).join(', ')}…'
      : names.join(', ');
  return t('Od: {names}', {'names': shown});
}

/// The system notification for [posts] (newest first, at least one) at the
/// most private level any of them asks for, the global one included.
///
/// * [NotificationPrivacy.senderAndContent]: "Nowy post od Ady" / its
///   beginning; for several "3 nowe posty" / "Od: Ada, Bob" and a line per
///   post.
/// * [NotificationPrivacy.senderOnly]: who, never what ("Nowy post od Ady";
///   "3 nowe posty" / "Od: Ada, Bob").
/// * [NotificationPrivacy.generic]: "Nowy post" (or "3 nowe posty"), nobody
///   named.
RuntimeSystemNotification newPostsNotification(
  List<NewPostNotice> posts, {
  required NotificationPrivacy level,
  required int createdAtMillis,
}) {
  final NotificationPrivacy said = posts.fold(
    level,
    (NotificationPrivacy l, NewPostNotice p) => l.atLeast(p.privacy),
  );
  final NewPostNotice newest = posts.first;
  final String generic = PrivacyRedactingNotificationService.genericBodyFor(
    RuntimeSystemNotificationCategory.social,
  );
  final bool one = posts.length == 1;
  final String title = switch (said) {
    _ when !one => _postCount(posts.length),
    NotificationPrivacy.generic => t('Nowy post'),
    _ => t('Nowy post od {name}', {'name': newest.author}),
  };
  final String body = switch (said) {
    NotificationPrivacy.generic => generic,
    _ when !one => _fromNames(posts),
    NotificationPrivacy.senderOnly => generic,
    NotificationPrivacy.senderAndContent =>
      newest.preview.isNotEmpty ? newest.preview : t('Nowy post'),
  };
  return RuntimeSystemNotification(
    id: '$kPostNoticeIdPrefix${newest.postId}',
    title: title,
    body: body,
    createdAtMillis: createdAtMillis,
    category: RuntimeSystemNotificationCategory.social,
    slotKey: kPostNoticeSlot,
    // A tap opens the Tablica at the newest of them.
    routeKey: buildFeedRouteKey(FeedFilter.all.name, postId: newest.postId),
    lines: !one && said == NotificationPrivacy.senderAndContent
        ? <String>[
            for (final NewPostNotice p in posts.take(_maxLines))
              p.preview.isEmpty ? p.author : '${p.author}: ${p.preview}',
          ]
        : const <String>[],
    stackCount: posts.length,
    // The level is applied here, per friend.
    contentRedacted: true,
  );
}

/// The entry in the in-app list for [posts] (newest first, at least one).
/// The app is unlocked when it is read, so it tells who and what, like
/// the entries about messages.
InboxEntry newPostsInboxEntry(
  List<NewPostNotice> posts, {
  required String id,
  required int createdAtMillis,
}) {
  final NewPostNotice newest = posts.first;
  final bool one = posts.length == 1;
  return InboxEntry(
    id: id,
    type: InboxEntryType.post,
    title: one
        ? t('Nowy post od {name}', {'name': newest.author})
        : _postCount(posts.length),
    body: one
        ? (newest.preview.isNotEmpty ? newest.preview : t('Nowy post'))
        : _fromNames(posts),
    createdAtMillis: createdAtMillis,
    routeKey: buildFeedRouteKey(FeedFilter.all.name, postId: newest.postId),
    peerAddress: one ? newest.address : null,
  );
}

/// What was announced: the post ids (with when each was written, to forget
/// the old ones), when the Tablica was last looked at, and the posts told
/// of since then ([pending], one notification and one inbox entry).
final class _NoticedPosts {
  _NoticedPosts({
    required this.lookedAt,
    required this.known,
    required this.pending,
    this.entry,
  });

  int lookedAt;
  final Map<String, int> known;
  final List<String> pending;

  /// The inbox entry standing for [pending].
  String? entry;

  static Future<_NoticedPosts?> load(LedgerDisk disk) async {
    final Uint8List? raw = await disk.read(kNotifiedPostsKey);
    if (raw == null) {
      return null;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return null;
      }
      final Object? at = json['at'];
      final Object? ids = json['ids'];
      final Object? pending = json['pending'];
      final Object? entry = json['entry'];
      return _NoticedPosts(
        lookedAt: at is int ? at : 0,
        known: <String, int>{
          if (ids is Map)
            for (final MapEntry<dynamic, dynamic> e in ids.entries)
              if (e.key is String && e.value is int)
                e.key as String: e.value as int,
        },
        pending: <String>[
          if (pending is List)
            for (final Object? id in pending)
              if (id is String) id,
        ],
        entry: entry is String ? entry : null,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> save(LedgerDisk disk, {required int nowMillis}) {
    // Only what could still be announced is worth remembering.
    final int oldest = nowMillis - kPostNoticeMaxAge.inMilliseconds;
    known.removeWhere((String _, int millis) => millis < oldest);
    if (known.length > _maxKnownPosts) {
      final List<MapEntry<String, int>> newest = known.entries.toList()
        ..sort(
          (MapEntry<String, int> a, MapEntry<String, int> b) =>
              b.value.compareTo(a.value),
        );
      known
        ..clear()
        ..addEntries(newest.take(_maxKnownPosts));
    }
    pending.removeWhere((String id) => !known.containsKey(id));
    return disk.write(
      kNotifiedPostsKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'at': lookedAt,
            'ids': known,
            'pending': pending,
            'entry': ?entry,
          }),
        ),
      ),
    );
  }
}

/// Announces friends' new posts: a system notification while the app is
/// not in front ([shouldNotify]), and an entry in the in-app list
/// ([addToInbox]) unless the user is looking at the Tablica
/// ([lookingAtFeed]), where everything counts as seen.
final class FriendPostNotifier {
  FriendPostNotifier({
    required this.node,
    required this.nameOf,
    required this.notify,
    required this.dismissSlot,
    required this.addToInbox,
    required this.shouldNotify,
    required this.lookingAtFeed,
    required this.announces,
    required this.privacyOf,
    required this.privacy,
    this.quiet = const Duration(seconds: 10),
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerNode node;
  final String Function(String address) nameOf;
  final Future<void> Function(RuntimeSystemNotification notification) notify;
  final Future<void> Function(String slotKey) dismissSlot;
  final Future<void> Function(InboxEntry entry) addToInbox;

  /// False while the app is in front.
  final bool Function() shouldNotify;

  /// True while the Tablica is on screen, the app in front.
  final bool Function() lookingAtFeed;

  /// Whether new posts of the friend at this address are announced (the
  /// global switch and "Wycisz posty tej osoby").
  final bool Function(String address) announces;

  /// How much a notification about the friend at this address may tell
  /// (their conversation's own level, else the global one).
  final NotificationPrivacy Function(String address) privacyOf;

  /// The global level (and the screen-share rule), for what tells of
  /// several friends at once.
  final NotificationPrivacy Function() privacy;

  /// Quiet time before a burst of posts is announced, so a friend's
  /// catching up comes as one notification.
  final Duration quiet;
  final int Function() _now;

  StreamSubscription<LogEntry>? _added;
  StreamSubscription<void>? _opened;
  Timer? _timer;

  /// The check under way: the next one waits for it, never runs beside it.
  Future<int>? _running;
  bool _disposed = false;

  void start() {
    _added ??= node.store.added.listen((LogEntry e) {
      if (e.kind == kPostKind) {
        _schedule();
      }
    });
    // A friends-only post becomes readable once its key arrives.
    _opened ??= node.openedChanges.listen((_) => _schedule());
    _schedule();
  }

  void _schedule() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      quiet,
      () => unawaitedLogged(
        check(),
        context: 'Powiadomienia o postach nie powiodły się',
      ),
    );
  }

  /// Once a minute from the app's clock: a look at the Tablica since the
  /// last check counts as seeing what was announced.
  void minute() {
    if (!_disposed && lookingAtFeed()) {
      unawaitedLogged(
        check(),
        context: 'Powiadomienia o postach nie powiodły się',
      );
    }
  }

  /// Announces friends' posts new since the last time; returns how many
  /// new posts were announced (in the list, and in the shade when the app
  /// is away).
  Future<int> check() async {
    if (_disposed) {
      return 0;
    }
    for (Future<int>? running = _running; running != null; running = _running) {
      await running;
    }
    if (_disposed) {
      return 0;
    }
    final Future<int> run = _check();
    _running = run;
    try {
      return await run;
    } finally {
      if (identical(_running, run)) {
        _running = null;
      }
    }
  }

  Future<int> _check() async {
    await node.start();
    if (!node.isReady || node.isSuspended) {
      return 0;
    }
    final int now = _now();
    final _NoticedPosts? had = await _NoticedPosts.load(node.disk);
    final Map<String, List<String>> addresses = <String, List<String>>{};
    node.friendAccounts.forEach((String address, String account) {
      (addresses[account] ??= <String>[]).add(address);
    });
    final int oldest = now - kPostNoticeMaxAge.inMilliseconds;
    final List<FeedPost> posts = <FeedPost>[
      for (final FeedPost p in friendPosts(node, nameOf: nameOf))
        if (p.millis >= oldest) p,
    ];
    final bool looking = lookingAtFeed();
    if (had == null || looking) {
      // The first run only learns what is there; on the Tablica the user
      // sees it.
      final bool wasPending = had?.pending.isNotEmpty ?? false;
      await _NoticedPosts(
        lookedAt: now,
        known: <String, int>{
          ...?had?.known,
          for (final FeedPost p in posts) p.id: p.millis,
        },
        pending: <String>[],
      ).save(node.disk, nowMillis: now);
      if (wasPending) {
        await dismissSlot(kPostNoticeSlot);
      }
      return 0;
    }
    final List<FeedPost> fresh = <FeedPost>[];
    for (final FeedPost p in posts) {
      if (had.known.containsKey(p.id)) {
        continue;
      }
      // Seen or not, it is not news any more after this round.
      had.known[p.id] = p.millis;
      final List<String> of = addresses[p.account] ?? const <String>[];
      // What was there at the last look is known already, so a post of the
      // very millisecond of the look is one that came after it.
      if (p.millis >= had.lookedAt && of.isNotEmpty && of.every(announces)) {
        fresh.add(p);
      }
    }
    if (fresh.isEmpty) {
      await had.save(node.disk, nowMillis: now);
      return 0;
    }
    had.pending.addAll(<String>[
      for (final FeedPost p in fresh)
        if (!had.pending.contains(p.id)) p.id,
    ]);
    final Map<String, FeedPost> byId = <String, FeedPost>{
      for (final FeedPost p in posts) p.id: p,
    };
    final List<NewPostNotice> told = <NewPostNotice>[
      for (final String id in had.pending)
        if (byId[id] case final FeedPost p) _noticeOf(p, addresses[p.account]!),
    ]..sort((NewPostNotice a, NewPostNotice b) => b.millis.compareTo(a.millis));
    if (told.isEmpty) {
      await had.save(node.disk, nowMillis: now);
      return 0;
    }
    final String entryId =
        had.entry ?? '$kPostNoticeIdPrefix${told.first.postId}';
    had.entry = entryId;
    // Saved first: a post is told of once even if what follows fails.
    await had.save(node.disk, nowMillis: now);
    await addToInbox(
      newPostsInboxEntry(told, id: entryId, createdAtMillis: now),
    );
    if (shouldNotify()) {
      await notify(
        newPostsNotification(told, level: privacy(), createdAtMillis: now),
      );
    }
    return fresh.length;
  }

  NewPostNotice _noticeOf(FeedPost post, List<String> addresses) {
    return NewPostNotice(
      postId: post.id,
      author: post.authorLabel,
      address: addresses.first,
      preview: postNoticePreview(post),
      millis: post.millis,
      privacy: addresses
          .map(privacyOf)
          .fold(
            NotificationPrivacy.senderAndContent,
            (NotificationPrivacy a, NotificationPrivacy b) => a.atLeast(b),
          ),
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_added?.cancel());
    unawaited(_opened?.cancel());
    _added = null;
    _opened = null;
  }
}
