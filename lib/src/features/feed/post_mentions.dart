import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/rich_text.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// Mentions in posts and their comments (`mentions.dart`).
//
// Who may be mentioned under a post: its author, the writer's friends and
// the friends of those friends as far as the friend lists shared with the
// writer show them, and the people who commented on or liked that post (a
// person this phone has an address for). A post for an audience (not
// public) is sealed for the author's friends, so there only its author,
// those who reacted to it and the author's friends (the author's own, or
// those on the author's shared list) can be mentioned: nobody else could
// read it.
//
// How the mentioned person learns of it: the writer's device sends each
// one a small notice through the reliable queue (`lg_mention`): the signed
// post, edit or comment with its device certificate, the post a comment or
// an edit belongs to, and the writer's profile. A friend also learns of it
// from the ledger, when the post or comment arrives by the usual sync.
// Either way the receiver checks it before saying anything: the signature,
// that the text really names this person, that the post is there (held,
// or carried and signed by its author), and that the writer may mention
// them at all: this is their post, the writer is their friend, they
// reacted to that post themselves, or the device that sent the notice is a
// friend of one of their friends (on a list shared with them). Each
// mention is told of once (by post, or by comment); one writer's notices,
// and those of everyone who is not a friend (all together and under one
// post), are limited per hour, on the disk so a restart does not reset the
// count. Somebody who is neither a friend nor on a friend's list is never
// named: only "Ktoś", and the notification tells only that it came.

/// Payload type of the notice about a mention.
const String kMentionNoticeType = 'lg_mention';

/// Id prefix of the notifications and inbox entries about mentions.
const String kMentionNoticeIdPrefix = 'mention-';

/// What was already told of.
const String kNotifiedMentionsKey = 'feed/notified_mentions';

/// A mention older than this is never told of.
const Duration kMentionNoticeMaxAge = Duration(days: 3);

/// Mentions one writer may get told of per hour.
const int kMentionNoticesPerSenderHour = 10;

/// Mentions by people who are not friends told of per hour, all together.
const int kMentionNoticesStrangersHour = 20;

/// Mentions by people who are not friends told of per hour under one post
/// (its comments together).
const int kMentionNoticesPerPostHour = 5;

/// Where the hourly limits are counted.
const String kMentionBudgetKey = 'feed/mention_budget';

/// Mentions remembered as told of at most.
const int _maxKnownMentions = 500;

/// Entries kept waiting for their key (a friends-only post) at most.
const int _maxWaiting = 100;

// ---- who may be mentioned ---------------------------------------------------

/// A name without what the wall adds to people known through a friend
/// ("Ada (przez Bob)").
String _bareName(String label) {
  final int cut = label.indexOf(' (');
  return (cut > 0 ? label.substring(0, cut) : label).trim();
}

/// An address [node] knows for [account] ('' when none).
String _addressOf(LedgerNode node, String account) {
  final List<String> known = node.anyAddressesOf(account);
  if (known.isNotEmpty) {
    return known.first;
  }
  return latestProfile(node, account)?.address ?? '';
}

/// Who this account may mention in [post] or under it, the most likely
/// first: the post's author, those who reacted to it, the writer's friends
/// and their friends ([friendLists]: friend address → (address → name), as
/// shared with this phone). With [post] `null`: a new post of this
/// account, for [audience]. [nameOf] gives a friend's name by address.
List<MentionCandidate> postMentionCandidates(
  LedgerNode node, {
  FeedPost? post,
  Audience audience = Audience.public,
  required String Function(String address) nameOf,
  Map<String, Map<String, String>> friendLists =
      const <String, Map<String, String>>{},
}) {
  final String self = PeerShareCodec.normalizeAddress(node.ownAddress);
  final Set<String> seen = <String>{if (self.isNotEmpty) self};
  final Set<String> accounts = <String>{node.account};
  final List<MentionCandidate> out = <MentionCandidate>[];
  void add(
    String address,
    String name,
    MentionReach reach, {
    String account = '',
  }) {
    final String a = PeerShareCodec.normalizeAddress(address);
    if (a.isEmpty ||
        name.trim().isEmpty ||
        !seen.add(a) ||
        (account.isNotEmpty && !accounts.add(account))) {
      return;
    }
    out.add(
      MentionCandidate(
        mention: Mention(address: a, account: account, name: name.trim()),
        reach: reach,
      ),
    );
  }

  final Audience shownTo = post?.audience ?? audience;
  final bool open = shownTo == Audience.public;
  final String author = post?.account ?? node.account;
  final Map<String, String> friendAccounts = node.friendAccounts;
  if (post != null && post.account != node.account) {
    final String address = post.authorAddress.isNotEmpty
        ? post.authorAddress
        : _addressOf(node, post.account);
    final String? friendAddress = friendAccounts.entries
        .where((MapEntry<String, String> e) => e.value == post.account)
        .map((MapEntry<String, String> e) => e.key)
        .firstOrNull;
    add(
      friendAddress ?? address,
      friendAddress != null
          ? nameOf(friendAddress)
          : _bareName(post.authorLabel),
      MentionReach.author,
      account: post.account,
    );
  }
  if (post != null) {
    for (final FeedComment c in post.comments) {
      if (c.account.isEmpty || c.account == node.account) {
        continue;
      }
      final String address = c.authorAddress.isNotEmpty
          ? c.authorAddress
          : _addressOf(node, c.account);
      final String known = nameOf(address);
      add(
        address,
        known.isNotEmpty
            ? known
            : (latestProfile(node, c.account)?.name ??
                  _bareName(c.authorLabel)),
        MentionReach.interacted,
        account: c.account,
      );
    }
    for (final FeedLiker l in post.likes) {
      if (l.account.isEmpty || l.account == node.account) {
        continue;
      }
      add(
        _addressOf(node, l.account),
        latestProfile(node, l.account)?.name ?? _bareName(l.name),
        MentionReach.interacted,
        account: l.account,
      );
    }
  }
  // Friends of the author, as far as this phone can tell: who can read a
  // post for an audience.
  final String authorAddress =
      <String>[
        for (final MapEntry<String, String> e in friendAccounts.entries)
          if (e.value == author) e.key,
      ].firstOrNull ??
      '';
  final Map<String, String> authorsFriends = authorAddress.isEmpty
      ? const <String, String>{}
      : (friendLists[authorAddress] ?? const <String, String>{});
  friendAccounts.forEach((String address, String account) {
    if (account == node.account) {
      return;
    }
    final bool reads =
        open ||
        (author == node.account
            ? audiencesFor(node.levelOf(address)).contains(shownTo)
            : authorsFriends.containsKey(address));
    if (reads) {
      add(address, nameOf(address), MentionReach.friend, account: account);
    }
  });
  friendLists.forEach((String friend, Map<String, String> list) {
    list.forEach((String address, String name) {
      if (open || authorsFriends.containsKey(address)) {
        add(
          address,
          name,
          MentionReach.friendOfFriend,
          account: node.accountOfAnyAddress(address) ?? '',
        );
      }
    });
  });
  return out;
}

/// [text] with only the mentions [allowed] keeps; the others become plain
/// names (and leave the list).
({String text, List<Mention> mentions}) keepMentions(
  String text,
  List<Mention> mentions,
  bool Function(Mention mention) allowed,
) {
  final ({String text, List<MentionSpan> spans}) shown = decodeMentions(
    text,
    mentions,
  );
  return encodeMentions(shown.text, <MentionSpan>[
    for (final MentionSpan s in shown.spans)
      if (allowed(s.mention)) s,
  ]);
}

/// [text] and its [mentions] as a post for [audience] may carry them: a
/// post for an audience mentions only friends that audience reaches (the
/// others become plain names); a public post anyone it named.
({String text, List<Mention> mentions}) mentionsForAudience(
  LedgerNode node,
  String text,
  List<Mention> mentions,
  Audience audience,
) {
  if (audience == Audience.public || mentions.isEmpty) {
    return (
      text: text,
      mentions: usedMentions(text, mentions).isEmpty
          ? const <Mention>[]
          : mentions,
    );
  }
  return keepMentions(
    text,
    mentions,
    (Mention m) =>
        node.friendAccounts.containsKey(m.address) &&
        audiencesFor(node.levelOf(m.address)).contains(audience),
  );
}

// ---- the notice ---------------------------------------------------------------

/// The notice to one mentioned person about [entry] (a post, an edit or a
/// comment of this account): the entry and [post] (what a comment or an
/// edit belongs to), each with its certificate. No name comes with it: the
/// receiver names only people it knows.
Map<String, dynamic>? mentionNoticeFrame(
  LedgerNode node,
  LogEntry entry, {
  LogEntry? post,
}) {
  final LogEntry? e = certifiedEntry(node, entry);
  if (e == null) {
    return null;
  }
  return <String, dynamic>{
    'type': kMentionNoticeType,
    'e': e.toCertifiedJson(),
    'p': ?certifiedEntry(node, post)?.toCertifiedJson(),
  };
}

/// A mention of this person, checked.
@immutable
final class MentionNotice {
  const MentionNotice({
    required this.id,
    required this.postId,
    required this.writer,
    required this.writerAddress,
    required this.writerName,
    required this.text,
    required this.mentions,
    required this.millis,
    this.inComment = false,
  });

  /// What it is told of once by: `p:<post>` or `c:<comment>`.
  final String id;
  final String postId;

  /// The writer's account and the address it came from ('' when unknown).
  final String writer;
  final String writerAddress;

  /// The writer's name as this phone knows it.
  final String writerName;

  /// What they wrote (tokens of [mentions] in it).
  final String text;
  final List<Mention> mentions;
  final int millis;
  final bool inComment;

  /// What a notification shows of [text].
  String get preview => shortNoticePreview(
    plainText(text, mentions: mentions).replaceAll(RegExp(r'\s+'), ' '),
  );
}

/// The system notification about [n] at [level] (`mentionNoticeText`).
RuntimeSystemNotification mentionNotification(
  MentionNotice n, {
  required NotificationPrivacy level,
  required int createdAtMillis,
}) {
  final NoticeText said = mentionNoticeText(
    level: level,
    sender: n.writerName,
    preview: n.preview,
    genericBody: PrivacyRedactingNotificationService.genericBodyFor(
      RuntimeSystemNotificationCategory.social,
    ),
  );
  return RuntimeSystemNotification(
    id: '$kMentionNoticeIdPrefix${n.id}',
    title: said.title,
    body: said.body,
    createdAtMillis: createdAtMillis,
    category: RuntimeSystemNotificationCategory.social,
    slotKey: '$kMentionNoticeIdPrefix${n.id}',
    routeKey: buildFeedRouteKey(FeedFilter.all.name, postId: n.postId),
    // The level is applied here.
    contentRedacted: true,
  );
}

/// The entry in the in-app list about [n] (the app is unlocked when it is
/// read: who and what).
InboxEntry mentionInboxEntry(
  MentionNotice n, {
  required int createdAtMillis,
  String? friendAddress,
}) => InboxEntry(
  id: '$kMentionNoticeIdPrefix${n.id}',
  type: InboxEntryType.mention,
  title: t('{name} wspomniał(a) o Tobie', {'name': n.writerName}),
  body: n.preview.isNotEmpty
      ? n.preview
      : (n.inComment ? t('W komentarzu') : t('W poście')),
  createdAtMillis: createdAtMillis,
  routeKey: buildFeedRouteKey(FeedFilter.all.name, postId: n.postId),
  peerAddress: friendAddress,
);

// ---- the service ----------------------------------------------------------------

/// Sends the notices about this account's mentions and tells this person
/// of the mentions of them: an entry in the in-app list ([addToInbox]) and,
/// while the app is not in front ([shouldNotify]), a system notification.
final class PostMentionService {
  PostMentionService({
    required this.node,
    required this.nameOf,
    required this.notify,
    required this.addToInbox,
    required this.shouldNotify,
    required this.privacyOf,
    required this.privacy,
    this.friendOfFriend,
    this.held,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerNode node;

  /// A friend's name by address.
  final String Function(String address) nameOf;
  final Future<void> Function(RuntimeSystemNotification notification) notify;
  final Future<void> Function(InboxEntry entry) addToInbox;

  /// False while the app is in front.
  final bool Function() shouldNotify;

  /// How much a notification about the friend at this address may tell.
  final NotificationPrivacy Function(String address) privacyOf;

  /// The global level, for people who are not friends.
  final NotificationPrivacy Function() privacy;

  /// The name of the device at this address when it is on a friend list
  /// shared with this phone (a friend of a friend), else `null`.
  final String? Function(String address)? friendOfFriend;

  /// Posts fetched from beyond friends (`post_reach.dart`).
  final HeldPosts? held;
  final int Function() _now;

  StreamSubscription<LogEntry>? _added;
  StreamSubscription<SignalTransportFrame>? _frames;
  StreamSubscription<void>? _opened;
  int _since = 0;
  bool _disposed = false;

  /// Friends' sealed entries waiting for their key.
  final List<LogEntry> _waiting = <LogEntry>[];

  /// Checks one at a time (the record of what was told of is shared).
  Future<void> _queue = Future<void>.value();

  void start() {
    if (_added != null) {
      return;
    }
    // Entries read back from the disk at start are old news to send.
    _since = _now() - 5000;
    _added = node.store.added.listen(_onAdded);
    _frames = node.transport.frames.listen((SignalTransportFrame f) {
      if (f.payload['type'] == kMentionNoticeType) {
        _enqueue(() => handleNotice(f));
      }
    });
    _opened = node.openedChanges.listen((_) {
      final List<LogEntry> again = List<LogEntry>.of(_waiting);
      _waiting.clear();
      for (final LogEntry e in again) {
        _enqueue(() => _fromLedger(e));
      }
    });
  }

  void dispose() {
    _disposed = true;
    unawaited(_added?.cancel());
    unawaited(_frames?.cancel());
    unawaited(_opened?.cancel());
    _added = null;
    _frames = null;
    _opened = null;
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      if (_disposed) {
        return;
      }
      try {
        await work();
      } on Object catch (error, stackTrace) {
        logZenError('A mention could not be handled', error, stackTrace);
      }
    });
  }

  /// Everything queued so far is done (tests).
  Future<void> get idle => _queue;

  void _onAdded(LogEntry e) {
    if (!node.isReady ||
        (e.kind != kPostKind &&
            e.kind != kPostEditKind &&
            e.kind != kCommentKind)) {
      return;
    }
    if (e.account == node.account) {
      if (e.writer == node.author.writer && e.hlc.millis >= _since) {
        _enqueue(() => sendNotices(e));
      }
      return;
    }
    _enqueue(() => _fromLedger(e));
  }

  // ---- sending ----

  /// Sends the notices about the mentions in this account's [entry]: one
  /// to each person it names (for an edit, only those the earlier version
  /// did not). Returns to how many.
  Future<int> sendNotices(LogEntry entry) async {
    final Map<String, dynamic>? body = node.bodyOf(entry);
    final Object? text = body?['text'];
    if (body == null || text is! String) {
      return 0;
    }
    final List<Mention> named = usedMentions(
      text,
      mentionsFromJson(body[kMentionsKey]),
    );
    if (named.isEmpty) {
      return 0;
    }
    LogEntry? post;
    Set<String> before = const <String>{};
    final Object? target = body['post'];
    if (entry.kind == kCommentKind && target is String) {
      post = _findPost(target);
    } else if (entry.kind == kPostEditKind && target is String) {
      post = node.store.entryById(accountSpace('feed', node.account), target);
      before = _mentionedBefore(entry, target, post);
    }
    final Map<String, dynamic>? frame = mentionNoticeFrame(
      node,
      entry,
      post: post,
    );
    if (frame == null) {
      return 0;
    }
    int sent = 0;
    final Set<String> done = <String>{};
    for (final Mention m in named) {
      final String to = PeerShareCodec.normalizeAddress(m.address);
      if (to.isEmpty ||
          m.names(
            addresses: <String>[node.ownAddress],
            account: node.account,
          ) ||
          before.contains(to) ||
          !done.add(to)) {
        continue;
      }
      unawaitedLogged(
        node.transport.send(remoteAddress: to, payload: frame),
        context: 'A mention notice was not sent',
      );
      sent++;
    }
    return sent;
  }

  /// The addresses the version of post [postId] before [edit] mentioned.
  Set<String> _mentionedBefore(LogEntry edit, String postId, LogEntry? post) {
    LogEntry? previous = post;
    for (final LogEntry e in node.entriesOf()) {
      if (e.kind == kPostEditKind &&
          e.id != edit.id &&
          e.hlc < edit.hlc &&
          node.bodyOf(e)?['post'] == postId &&
          (previous == null ||
              previous.kind != kPostEditKind ||
              e.hlc > previous.hlc)) {
        previous = e;
      }
    }
    final Map<String, dynamic>? body = previous == null
        ? null
        : node.bodyOf(previous);
    final Object? text = body?['text'];
    if (body == null || text is! String) {
      return const <String>{};
    }
    return <String>{
      for (final Mention m in usedMentions(
        text,
        mentionsFromJson(body[kMentionsKey]),
      ))
        PeerShareCodec.normalizeAddress(m.address),
    };
  }

  /// The post [id] wherever this phone has it.
  LogEntry? _findPost(String id) {
    final Set<String> accounts = <String>{
      node.account,
      ...node.friendAccounts.values,
      ...node.followedAccounts.values,
    };
    for (final String account in accounts) {
      final LogEntry? e = node.store.entryById(
        accountSpace('feed', account),
        id,
      );
      if (e != null && e.kind == kPostKind) {
        return e;
      }
    }
    final LogEntry? h = held?.heldPost(id)?.post;
    return h != null && h.kind == kPostKind && h.id == id ? h : null;
  }

  // ---- receiving ----

  /// Handles a notice about a mention; returns whether it was told of.
  Future<bool> handleNotice(SignalTransportFrame frame) async {
    if (_disposed || !node.isReady || node.isSuspended) {
      return false;
    }
    final Map<String, dynamic> p = frame.payload;
    final LogEntry? entry = await verifiedEntry(p['e']);
    if (entry == null || entry.account == node.account) {
      return false;
    }
    // A sealed entry opens only with a key this phone has (it then also
    // comes with the ledger).
    final Map<String, dynamic>? body = isSealed(entry.body)
        ? _storedBody(entry)
        : entry.body;
    if (body == null) {
      return false;
    }
    LogEntry? carried;
    if (p['p'] != null) {
      carried = await verifiedEntry(p['p']);
    }
    return _consider(
      entry,
      body,
      from: PeerShareCodec.normalizeAddress(frame.from),
      carriedPost: carried,
    );
  }

  Map<String, dynamic>? _storedBody(LogEntry entry) {
    final LogEntry? stored = node.store.entryById(entry.space, entry.id);
    return stored == null ? null : node.bodyOf(stored);
  }

  Future<void> _fromLedger(LogEntry e) async {
    final Map<String, dynamic>? body = node.bodyOf(e);
    if (body == null) {
      if (isSealed(e.body) && _waiting.length < _maxWaiting) {
        _waiting.add(e);
      }
      return;
    }
    final String? address = node.friendAccounts.entries
        .where((MapEntry<String, String> f) => f.value == e.account)
        .map((MapEntry<String, String> f) => f.key)
        .firstOrNull;
    await _consider(e, body, from: address ?? '');
  }

  Future<bool> _consider(
    LogEntry entry,
    Map<String, dynamic> body, {
    required String from,
    LogEntry? carriedPost,
  }) async {
    final int now = _now();
    final Object? text = body['text'];
    if (text is! String ||
        entry.hlc.millis < now - kMentionNoticeMaxAge.inMilliseconds) {
      return false;
    }
    final List<Mention> mentions = mentionsFromJson(body[kMentionsKey]);
    if (!mentionsAnyOf(
      text,
      mentions,
      addresses: <String>[node.ownAddress],
      account: node.account,
    )) {
      return false;
    }
    // Which post, and whose: the entry itself, or a post this phone holds
    // or that came with the notice, signed by its author.
    final String postId;
    final String postAuthor;
    final bool inComment = entry.kind == kCommentKind;
    final Object? target = body['post'];
    switch (entry.kind) {
      case kPostKind:
        if (entry.space != accountSpace('feed', entry.account)) {
          return false;
        }
        postId = entry.id;
        postAuthor = entry.account;
      case kPostEditKind || kCommentKind:
        if (target is! String || target.isEmpty) {
          return false;
        }
        final LogEntry? post =
            _findPost(target) ??
            (carriedPost != null &&
                    carriedPost.id == target &&
                    carriedPost.kind == kPostKind &&
                    carriedPost.space ==
                        accountSpace('feed', carriedPost.account)
                ? carriedPost
                : null);
        if (post == null ||
            (entry.kind == kPostEditKind && post.account != entry.account) ||
            (inComment && entry.space != accountSpace('acts', entry.account))) {
          return false;
        }
        postId = post.id;
        postAuthor = post.account;
      default:
        return false;
    }
    final String friendAddress =
        node.friendAccounts.entries
            .where((MapEntry<String, String> f) => f.value == entry.account)
            .map((MapEntry<String, String> f) => f.key)
            .firstOrNull ??
        '';
    final bool isFriend = friendAddress.isNotEmpty;
    final String? listedName = from.isEmpty ? null : friendOfFriend?.call(from);
    final String? sentBy = from.isEmpty ? null : node.accountOfAnyAddress(from);
    final bool listed =
        listedName != null && (sentBy == null || sentBy == entry.account);
    final bool allowed =
        postAuthor == node.account || isFriend || _reactedTo(postId) || listed;
    if (!allowed) {
      return false;
    }
    final String id = inComment ? 'c:${entry.id}' : 'p:$postId';
    final _Told told = await _Told.load(node);
    if (told.ids.containsKey(id) ||
        !await _withinBudget(from, entry.account, postId, isFriend)) {
      return false;
    }
    told.ids[id] = entry.hlc.millis;
    // Saved first: told of once even if what follows fails.
    await told.save(node, nowMillis: now);
    // Only a name this person gave, or one a friend's list shows: whatever
    // anybody else calls themselves could pretend to be someone known.
    final String listedAs = listed ? listedName.trim() : '';
    final String name = isFriend
        ? nameOf(friendAddress)
        : listedAs.isNotEmpty
        ? listedAs
        : t('Ktoś');
    final MentionNotice notice = MentionNotice(
      id: id,
      postId: postId,
      writer: entry.account,
      writerAddress: isFriend ? friendAddress : from,
      writerName: name,
      text: text,
      mentions: mentions,
      millis: entry.hlc.millis,
      inComment: inComment,
    );
    await addToInbox(
      mentionInboxEntry(
        notice,
        createdAtMillis: now,
        friendAddress: isFriend ? friendAddress : null,
      ),
    );
    if (shouldNotify()) {
      await notify(
        mentionNotification(
          notice,
          level: isFriend
              ? privacyOf(friendAddress)
              : listedAs.isNotEmpty
              ? privacy()
              : NotificationPrivacy.generic,
          createdAtMillis: now,
        ),
      );
    }
    return true;
  }

  /// Whether this account commented on or liked post [postId].
  bool _reactedTo(String postId) => node
      .entriesOf(spaceKind: 'acts')
      .any(
        (LogEntry e) =>
            (e.kind == kCommentKind || e.kind == kLikeKind) &&
            e.body['post'] == postId,
      );

  /// Whether one more mention by the writer at [from] (or [account]) under
  /// post [postId] may be told of this hour; counts it when so.
  Future<bool> _withinBudget(
    String from,
    String account,
    String postId,
    bool friend,
  ) async {
    final _Budget budget = await _Budget.load(node, hour: _now() ~/ 3600000);
    final String writer = from.isNotEmpty ? from : account;
    final int byWriter = budget.writers[writer] ?? 0;
    final int underPost = budget.posts[postId] ?? 0;
    if (byWriter >= kMentionNoticesPerSenderHour ||
        (!friend &&
            (budget.strangers >= kMentionNoticesStrangersHour ||
                underPost >= kMentionNoticesPerPostHour)) ||
        (budget.writers.length >= _maxBudgetKeys &&
            !budget.writers.containsKey(writer))) {
      return false;
    }
    budget.writers[writer] = byWriter + 1;
    if (!friend) {
      budget.strangers += 1;
      if (budget.posts.length < _maxBudgetKeys ||
          budget.posts.containsKey(postId)) {
        budget.posts[postId] = underPost + 1;
      }
    }
    await budget.save(node);
    return true;
  }
}

/// Writers and posts counted per hour at most.
const int _maxBudgetKeys = 1000;

/// What was told of this hour ([hour]): by writer, by people who are not
/// friends ([strangers]) and by those under each post.
final class _Budget {
  _Budget(
    this.hour, {
    this.strangers = 0,
    Map<String, int>? writers,
    Map<String, int>? posts,
  }) : writers = writers ?? <String, int>{},
       posts = posts ?? <String, int>{};

  final int hour;
  int strangers;
  final Map<String, int> writers;
  final Map<String, int> posts;

  /// The count for [hour]; another hour's starts again at nothing.
  static Future<_Budget> load(LedgerNode node, {required int hour}) async {
    final Uint8List? raw = await node.disk.read(kMentionBudgetKey);
    if (raw == null) {
      return _Budget(hour);
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map || json['h'] != hour) {
        return _Budget(hour);
      }
      Map<String, int> counts(Object? map) => <String, int>{
        if (map is Map)
          for (final MapEntry<dynamic, dynamic> e in map.entries)
            if (e.key is String && e.value is int)
              e.key as String: e.value as int,
      };
      final Object? s = json['s'];
      return _Budget(
        hour,
        strangers: s is int ? s : 0,
        writers: counts(json['w']),
        posts: counts(json['p']),
      );
    } on FormatException {
      return _Budget(hour);
    }
  }

  Future<void> save(LedgerNode node) => node.disk.write(
    kMentionBudgetKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object>{
          'h': hour,
          's': strangers,
          'w': writers,
          'p': posts,
        }),
      ),
    ),
  );
}

/// What was told of: `p:<post>` / `c:<comment>` → when it was written.
final class _Told {
  _Told(this.ids);

  final Map<String, int> ids;

  static Future<_Told> load(LedgerNode node) async {
    final Uint8List? raw = await node.disk.read(kNotifiedMentionsKey);
    if (raw == null) {
      return _Told(<String, int>{});
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      return _Told(<String, int>{
        if (json is Map)
          for (final MapEntry<dynamic, dynamic> e in json.entries)
            if (e.key is String && e.value is int)
              e.key as String: e.value as int,
      });
    } on FormatException {
      return _Told(<String, int>{});
    }
  }

  Future<void> save(LedgerNode node, {required int nowMillis}) {
    final int oldest = nowMillis - kMentionNoticeMaxAge.inMilliseconds;
    ids.removeWhere((String _, int millis) => millis < oldest);
    if (ids.length > _maxKnownMentions) {
      final List<MapEntry<String, int>> newest = ids.entries.toList()
        ..sort(
          (MapEntry<String, int> a, MapEntry<String, int> b) =>
              b.value.compareTo(a.value),
        );
      ids
        ..clear()
        ..addEntries(newest.take(_maxKnownMentions));
    }
    return node.disk.write(
      kNotifiedMentionsKey,
      Uint8List.fromList(utf8.encode(jsonEncode(ids))),
    );
  }
}
