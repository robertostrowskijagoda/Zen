import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Posts asked for in one round at most.
const int kMaxPostAsksPerRound = 20;

/// Posts fetched from beyond friends kept on this device at most.
const int kMaxHeldPosts = 300;

/// Asks one friend may send per minute.
const int kPostAsksPerMinuteFriend = 60;

/// Asks someone who is not a friend may send per minute (for the author's
/// own posts), and all of them together.
const int kPostAsksPerMinuteStranger = 10;
const int kPostAsksPerMinuteStrangers = 200;

/// Passes posts on beyond friends (`post_reach.dart`): writes this
/// account's notices, fetches the posts friends' notices name, and hands
/// out the posts it holds to those who ask.
///
/// The fetched posts stay on this device (at most [kMaxHeldPosts], for
/// [kReachWindow]), so its friends can fetch them from it while their
/// author is offline.
final class PostReachService implements HeldPosts {
  PostReachService({
    required this.node,
    this.delay = const Duration(seconds: 20),
    this.minGap = const Duration(minutes: 10),
    this.retryAfter = const Duration(minutes: 10),
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerNode node;

  /// Quiet time after news before a round.
  final Duration delay;

  /// Shortest time between two notice entries of this device.
  final Duration minGap;

  /// How long an unanswered ask waits before it is asked again.
  final Duration retryAfter;
  final int Function() _now;

  static const String _storeKey = 'feed/reach';

  final Map<String, HeldPost> _held = <String, HeldPost>{};

  /// Post id → what was asked: when, for how many steps, of whom.
  final Map<String, ({int at, int hops, String author})> _asked =
      <String, ({int at, int hops, String author})>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Map<String, (int, int)> _budget = <String, (int, int)>{};
  (int, int) _strangers = (0, 0);
  StreamSubscription<SignalTransportFrame>? _frames;
  StreamSubscription<LogEntry>? _added;
  StreamSubscription<String>? _greeted;
  Timer? _timer;
  Future<void>? _started;
  bool _stopped = false;
  bool _running = false;

  /// Something came while a round ran: another one follows.
  bool _again = false;

  /// Fires when a fetched post came or changed.
  Stream<void> get changes => _changes.stream;

  @override
  HeldPost? heldPost(String id) => _held[id];

  /// Entries of the posts held here (their files count in the storage
  /// limits like any other).
  Iterable<LogEntry> get heldEntries => <LogEntry>[
    for (final HeldPost h in _held.values) ...<LogEntry>[?h.post, ?h.edit],
  ];

  /// Reads what was fetched before and starts listening. Safe to call more
  /// than once.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    await node.start();
    if (_stopped) {
      return;
    }
    await _load();
    _frames = node.transport.frames.listen(
      (SignalTransportFrame f) =>
          unawaitedLogged(handle(f), context: 'Posty dalszych znajomych'),
    );
    _added = node.store.added.listen(_onAdded);
    // A friend back online may hold what nobody answered for so far.
    _greeted = node.peerGreeted.listen((String _) {
      final int now = _now();
      _asked.removeWhere(
        (String id, ({int at, int hops, String author}) a) =>
            now - a.at >= 60000,
      );
      schedule();
    });
    unawaitedLogged(round(), context: 'Posty dalszych znajomych');
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _frames?.cancel();
    await _added?.cancel();
    await _greeted?.cancel();
    await _changes.close();
  }

  void _onAdded(LogEntry e) {
    if (e.account == node.account) {
      return;
    }
    if (e.kind == kPostAnnounceKind ||
        e.kind == kPostKind ||
        e.kind == kPostEditKind ||
        e.kind == kPostDeleteKind) {
      schedule();
    }
  }

  /// A round after [delay] (one at a time).
  void schedule([Duration? after]) {
    if (_stopped || _timer != null) {
      return;
    }
    _timer = Timer(after ?? delay, () {
      _timer = null;
      unawaitedLogged(round(), context: 'Posty dalszych znajomych');
    });
  }

  /// Once a minute from the app's clock: a round every ten minutes.
  void minute(int minute) {
    if (minute % 10 == 0) {
      schedule(Duration.zero);
    }
  }

  /// Asks for what friends' notices name and is not here, then passes on
  /// what may go further.
  Future<void> round() async {
    if (_running) {
      _again = true;
      return;
    }
    if (_stopped || !node.isReady || node.isSuspended) {
      return;
    }
    _running = true;
    try {
      askMissing();
      await passOn();
    } finally {
      _running = false;
    }
    if (_again) {
      _again = false;
      schedule();
    }
  }

  /// Asks the friends who passed a post on, and its author, for the posts
  /// friends' notices name that are not here (or changed since).
  void askMissing() {
    final int now = _now();
    int asked = 0;
    for (final AnnouncedPost a in announcedPosts(node, nowMillis: now).values) {
      final HeldPost? h = _held[a.post];
      if (h != null &&
          (h.author != a.author ||
              h.removed ||
              (!a.removed && a.editMillis <= h.editMillis))) {
        continue;
      }
      final ({int at, int hops, String author})? before = _asked[a.post];
      if (before != null && now - before.at < retryAfter.inMilliseconds) {
        continue;
      }
      if (asked++ >= kMaxPostAsksPerRound) {
        break;
      }
      _asked.remove(a.post);
      _asked[a.post] = (at: now, hops: a.hops, author: a.author);
      final Map<String, dynamic> want = postWantFrame(a.post, a.author);
      for (final String to in _sourcesOf(a, h)) {
        _send(to, want);
      }
    }
    while (_asked.length > 500) {
      _asked.remove(_asked.keys.first);
    }
  }

  /// The friends who passed [a] on (two devices each), then the author at
  /// the address of their public profile.
  List<String> _sourcesOf(AnnouncedPost a, HeldPost? h) {
    final String own = PeerShareCodec.normalizeAddress(node.ownAddress);
    final List<String> out = <String>[];
    void add(String address) {
      final String n = PeerShareCodec.normalizeAddress(address);
      if (n.isNotEmpty && n != own && !out.contains(n)) {
        out.add(n);
      }
    }

    for (final String friend in a.via) {
      node.addressesOfAccount(friend).take(2).forEach(add);
    }
    final String author = h?.authorProfile?.address ?? '';
    add(author.isNotEmpty ? author : a.authorAddress);
    return out.take(6).toList();
  }

  /// Writes a notice entry with what is new to pass on (at most one entry
  /// every [minGap]). Returns how many posts it named.
  Future<int> passOn() async {
    if (_stopped || !node.isReady || node.isSuspended) {
      return 0;
    }
    final int now = _now();
    final List<PostAnnouncement> items = announcementsToPass(
      node,
      held: heldPost,
      nowMillis: now,
    );
    if (items.isEmpty) {
      return 0;
    }
    int last = 0;
    for (final LogEntry e in node.entriesOf(spaceKind: 'acts')) {
      if (e.kind == kPostAnnounceKind &&
          e.writer == node.author.writer &&
          e.hlc.millis > last) {
        last = e.hlc.millis;
      }
    }
    final int wait = last + minGap.inMilliseconds - now;
    if (wait > 0) {
      schedule(Duration(milliseconds: wait));
      return 0;
    }
    await node.publish(
      kPostAnnounceKind,
      announceBody(items),
      spaceKind: 'acts',
    );
    return items.length;
  }

  /// Handles `lg_post_want` and `lg_post`; true if [frame] was one.
  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type != kPostWantType && type != kPostAnswerType) {
      return false;
    }
    if (_stopped || !node.isReady || node.isSuspended) {
      return true;
    }
    if (type == kPostWantType) {
      _onWant(frame.from, frame.payload);
    } else {
      await _onAnswer(frame.from, frame.payload);
    }
    return true;
  }

  /// Someone asks for a post: friends get any post this device holds that
  /// may go one step past it; anyone else only this account's own posts
  /// whose reach goes past friends.
  void _onWant(String from, Map<String, dynamic> payload) {
    final ({String id, String author})? want = readPostWant(payload);
    if (want == null) {
      return;
    }
    final bool friend = node.isFriendAddress(from);
    if ((!friend && want.author != node.account) ||
        !_allowed(from, friend: friend)) {
      return;
    }
    final Map<String, dynamic>? answer = _answerFor(want.id, want.author);
    if (answer != null) {
      _send(from, answer);
    }
  }

  Map<String, dynamic>? _answerFor(String id, String author) {
    Map<String, dynamic>? certified(LogEntry? e) =>
        certifiedEntry(node, e)?.toCertifiedJson();
    if (author == node.account || node.friendAccounts.containsValue(author)) {
      // The author's feed is here: the post, its newest edit, a tombstone.
      LogEntry? post;
      LogEntry? edit;
      LogEntry? tomb;
      for (final LogEntry e in node.entriesOf(
        ofAccount: author == node.account ? null : author,
      )) {
        if (e.account != author) {
          continue;
        }
        if (e.kind == kPostKind && e.id == id) {
          post = e;
        } else if (e.body['post'] == id) {
          if (e.kind == kPostDeleteKind) {
            tomb = e;
          } else if (e.kind == kPostEditKind &&
              (edit == null || e.hlc > edit.hlc)) {
            edit = e;
          }
        }
      }
      if (tomb != null) {
        final Map<String, dynamic>? del = certified(tomb);
        return del == null ? null : postAnswerFrame(id, author, tombstone: del);
      }
      if (post == null || reachOfBody(post.body).hops < 2) {
        return null;
      }
      final Map<String, dynamic>? entry = certified(post);
      return entry == null
          ? null
          : postAnswerFrame(
              id,
              author,
              entry: entry,
              edit: certified(edit),
              profile: certified(latestPublicProfileEntry(node, author)),
            );
    }
    final HeldPost? h = _held[id];
    if (h == null || h.author != author) {
      return null;
    }
    if (h.removed) {
      return postAnswerFrame(
        id,
        author,
        tombstone: h.tombstone!.toCertifiedJson(),
      );
    }
    // Only one step past this account, as far as the author let it go.
    if (h.hops + 1 > h.reach.hops) {
      return null;
    }
    return postAnswerFrame(
      id,
      author,
      entry: h.post!.toCertifiedJson(),
      edit: h.edit?.toCertifiedJson(),
      profile: h.profile?.toCertifiedJson(),
    );
  }

  /// A post asked for came: checked, kept, its files fetched.
  Future<void> _onAnswer(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final ({int at, int hops, String author})? asked = id is String
        ? _asked[id]
        : null;
    if (id is! String || asked == null) {
      // Only what this device asked for is taken.
      return;
    }
    final HeldPost? checked = await checkPostAnswer(
      payload,
      id: id,
      author: asked.author,
      hops: asked.hops,
    );
    if (checked == null || _stopped) {
      return;
    }
    _asked.remove(id);
    final HeldPost? had = _held[id];
    final HeldPost now = had == null ? checked : had.updatedWith(checked);
    if (had != null && now.sameAs(had)) {
      return;
    }
    _held[id] = now;
    if (now.removed) {
      await _dropFiles(had);
    } else {
      _fetchFiles(now, from);
    }
    _trim();
    await _save();
    if (!_stopped) {
      _changes.add(null);
      schedule();
    }
  }

  /// Fetches the photos and videos of [h] (when automatic download is on)
  /// from [from] and whoever else may have them.
  void _fetchFiles(HeldPost h, String from) {
    if (!node.autoDownloadMedia()) {
      return;
    }
    final List<String> ids = <String>[...?h.post?.blobs, ...?h.edit?.blobs];
    if (ids.isEmpty) {
      return;
    }
    final List<String> sources = <String>[
      from,
      for (final String address in node.friendAccounts.keys) address,
      if (h.authorProfile?.address case final String a when a.isNotEmpty) a,
    ];
    for (final String id in ids) {
      node.blobs
        ..allowFor(id, h.author)
        ..noteFetchFor(id, h.author);
      node.fetchBlobFrom(id, sources);
    }
  }

  /// The author removed the post: its files go too.
  Future<void> _dropFiles(HeldPost? h) async {
    for (final String id in <String>[...?h?.post?.blobs, ...?h?.edit?.blobs]) {
      await node.blobs.dropFor(id, h!.author);
    }
  }

  /// Forgets posts older than the window, and the oldest over the cap.
  void _trim() {
    final int since = _now() - kReachWindow.inMilliseconds;
    _held.removeWhere((String _, HeldPost h) => h.millis < since);
    if (_held.length <= kMaxHeldPosts) {
      return;
    }
    final List<HeldPost> newest = _held.values.toList()
      ..sort((HeldPost a, HeldPost b) => b.millis.compareTo(a.millis));
    _held
      ..clear()
      ..addEntries(
        newest
            .take(kMaxHeldPosts)
            .map((HeldPost h) => MapEntry<String, HeldPost>(h.id, h)),
      );
  }

  bool _allowed(String from, {required bool friend}) {
    final int minute = _now() ~/ 60000;
    final String key = PeerShareCodec.normalizeAddress(from);
    if (!friend) {
      final int all = _strangers.$1 == minute ? _strangers.$2 : 0;
      if (all >= kPostAsksPerMinuteStrangers) {
        return false;
      }
      _strangers = (minute, all + 1);
    }
    final (int, int)? had = _budget[key];
    final int used = had == null || had.$1 != minute ? 0 : had.$2;
    if (used >=
        (friend ? kPostAsksPerMinuteFriend : kPostAsksPerMinuteStranger)) {
      return false;
    }
    if (had == null && _budget.length >= 1000) {
      _budget.removeWhere((String _, (int, int) b) => b.$1 != minute);
      if (_budget.length >= 1000) {
        return false;
      }
    }
    _budget[key] = (minute, used + 1);
    return true;
  }

  void _send(String to, Map<String, dynamic> payload) => unawaitedLogged(
    node.transport.send(remoteAddress: to, payload: payload),
    context: 'Posty dalszych znajomych',
  );

  Future<void> _load() async {
    try {
      final Uint8List? raw = await node.disk.read(_storeKey);
      if (raw == null || raw.isEmpty) {
        return;
      }
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map ||
          formatAgeOf(json[kFormatVersionKey], current: kFirstFormatVersion) !=
              FormatAge.readable) {
        return;
      }
      final Object? posts = json['posts'];
      if (posts is! List) {
        return;
      }
      for (final Object? p in posts.take(kMaxHeldPosts)) {
        if (HeldPost.fromJson(p) case final HeldPost h) {
          _held[h.id] = h;
        }
      }
      _trim();
    } on Object catch (error) {
      logZenWarning('Odczyt postów dalszych znajomych nie udał się: $error');
    }
  }

  Future<void> _save() => node.disk.write(
    _storeKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(
          withFormatVersion(<String, Object?>{
            'posts': <Map<String, dynamic>>[
              for (final HeldPost h in _held.values) h.toJson(),
            ],
          }),
        ),
      ),
    ),
  );
}

/// Posts beyond friends, or `null` while the ledger is off.
final Provider<PostReachService?> postReachProvider =
    Provider<PostReachService?>((Ref ref) {
      final LedgerNode? node = ref.watch(ledgerNodeProvider);
      if (node == null) {
        return null;
      }
      final PostReachService reach = PostReachService(node: node);
      ref.onDispose(
        () =>
            unawaitedLogged(reach.stop(), context: 'Posty dalszych znajomych'),
      );
      return reach;
    });
