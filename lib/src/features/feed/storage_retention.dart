import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/profile_gallery.dart';

// The storage limits, enforced: what other people's posts
// may take on this phone. Oldest first, and never anything of your own.
//
//  * Friends' posts are kept 12 months: older ones leave the wall, and their
//    photos and videos are deleted from the phone.
//  * Photos and videos of friends: at most 2 GB per person.
//  * Photos and videos of people who are not friends (followed accounts,
//    posts reshared from afar): a cache of 1 GB.
//
// The signed entries themselves stay in the log (a hash chain cannot lose
// its first links without losing its proof); they are a few hundred bytes
// each. A deleted file is not fetched again.

/// How long friends' posts stay on the wall and their files on the phone.
const Duration kFriendEntriesKept = Duration(days: 365);

/// Most photos and videos kept of one friend.
const int kCircleMediaPerPersonBytes = 2 * 1024 * 1024 * 1024;

/// Most photos and videos kept of everyone who is not a friend.
const int kMediaCacheBytes = 1024 * 1024 * 1024;

/// How often the limits are applied.
const Duration kStorageRetentionInterval = Duration(hours: 1);

/// Whose file it is, for the limit that applies to it.
enum StoredMediaOwner {
  /// A friend's: kept 12 months, 2 GB per person.
  friend,

  /// Anybody else's: a cache of 1 GB.
  cache,
}

/// One file of other people held on this phone.
@immutable
final class StoredMedia {
  const StoredMedia({
    required this.id,
    required this.bytes,
    required this.account,
    required this.millis,
    required this.owner,
  });

  final String id;
  final int bytes;

  /// Whose post brought it ('' when unknown).
  final String account;

  /// When the newest post that uses it was written.
  final int millis;
  final StoredMediaOwner owner;
}

/// What a round of the limits deletes.
@immutable
final class RetentionPlan {
  const RetentionPlan({
    this.expired = const <StoredMedia>[],
    this.overPersonLimit = const <StoredMedia>[],
    this.overCache = const <StoredMedia>[],
  });

  /// Friends' files older than [kFriendEntriesKept].
  final List<StoredMedia> expired;

  /// Friends' files over the 2 GB of one person (oldest first).
  final List<StoredMedia> overPersonLimit;

  /// Other people's files over the 1 GB cache (oldest first).
  final List<StoredMedia> overCache;

  Iterable<StoredMedia> get all sync* {
    yield* expired;
    yield* overPersonLimit;
    yield* overCache;
  }

  bool get isEmpty =>
      expired.isEmpty && overPersonLimit.isEmpty && overCache.isEmpty;

  int get bytes => all.fold<int>(0, (int sum, StoredMedia m) => sum + m.bytes);
}

int _oldestFirst(StoredMedia a, StoredMedia b) {
  final int byTime = a.millis.compareTo(b.millis);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

/// Which of [media] go, at [nowMillis]: friends' files older than [kept]
/// first, then the oldest of what is left until each friend is within
/// [perPersonBytes] and everybody else within [cacheBytes].
RetentionPlan planStorageRetention(
  Iterable<StoredMedia> media, {
  required int nowMillis,
  Duration kept = kFriendEntriesKept,
  int perPersonBytes = kCircleMediaPerPersonBytes,
  int cacheBytes = kMediaCacheBytes,
}) {
  final int cutoff = nowMillis - kept.inMilliseconds;
  final List<StoredMedia> expired = <StoredMedia>[];
  final Map<String, List<StoredMedia>> perFriend =
      <String, List<StoredMedia>>{};
  final List<StoredMedia> cache = <StoredMedia>[];
  for (final StoredMedia m in media) {
    if (m.owner == StoredMediaOwner.cache) {
      cache.add(m);
    } else if (m.millis < cutoff) {
      expired.add(m);
    } else {
      (perFriend[m.account] ??= <StoredMedia>[]).add(m);
    }
  }
  final List<StoredMedia> overPerson = <StoredMedia>[];
  for (final List<StoredMedia> files in perFriend.values) {
    overPerson.addAll(_oldestOver(files, perPersonBytes));
  }
  return RetentionPlan(
    expired: expired..sort(_oldestFirst),
    overPersonLimit: overPerson..sort(_oldestFirst),
    overCache: _oldestOver(cache, cacheBytes),
  );
}

/// The oldest of [files] that must go to bring them within [limit] bytes.
List<StoredMedia> _oldestOver(List<StoredMedia> files, int limit) {
  int total = files.fold<int>(0, (int sum, StoredMedia m) => sum + m.bytes);
  if (total <= limit) {
    return const <StoredMedia>[];
  }
  final List<StoredMedia> sorted = List<StoredMedia>.of(files)
    ..sort(_oldestFirst);
  final List<StoredMedia> out = <StoredMedia>[];
  for (final StoredMedia m in sorted) {
    if (total <= limit) {
      break;
    }
    out.add(m);
    total -= m.bytes;
  }
  return out;
}

/// Entry kinds whose photos and videos the limits may delete: posts, their
/// edits, reshares, gallery items and comments of other people, and the
/// comment pictures bundles pass on. Files of anything else (profile
/// photos, chats, updates) are never touched.
const Set<String> _limitedKinds = <String>{
  kPostKind,
  kPostEditKind,
  kReshareKind,
  kGalleryKind,
  kCommentKind,
  kReactionsKind,
  kReactionsPageKind,
};

/// Entries of this account that only pass on other people's files (the
/// comment pictures in its bundles): those files are not pinned by them.
const Set<String> _passedOnKinds = <String>{kReactionsKind, kReactionsPageKind};

/// Blob ids [e] uses: its own, and those of the post a reshare carries.
Iterable<String> _blobIdsOf(LogEntry e) sync* {
  yield* e.blobs;
  final Object? inner = e.body['entry'];
  final Object? blobs = inner is Map ? inner['blobs'] : null;
  if (blobs is List) {
    for (final Object? b in blobs.take(kMaxBlobsPerEntry)) {
      if (b is String) {
        yield b;
      }
    }
  }
}

/// The complete files of other people on this phone, with the newest post
/// that uses each. A file that anything of this account (or anything the
/// limits do not cover, like a profile) also uses is left out: it stays.
/// So is a file no other writer's entry brought here (one this phone made,
/// or a chat's): an old-dated entry naming it cannot make it expire.
List<StoredMedia> storedMediaOf(LedgerNode node) {
  final Set<String> friends = node.friendAccounts.values.toSet();
  final Set<String> pinned = <String>{};
  final Map<String, ({int millis, String account, bool friend})> used =
      <String, ({int millis, String account, bool friend})>{};
  for (final String space in node.store.spaces.toList()) {
    for (final LogEntry e in node.store.entries(space)) {
      final Iterable<String> ids = _blobIdsOf(e);
      if ((e.account == node.account && !_passedOnKinds.contains(e.kind)) ||
          !_limitedKinds.contains(e.kind)) {
        pinned.addAll(ids);
        continue;
      }
      final bool friend = friends.contains(e.account);
      for (final String id in ids) {
        final ({int millis, String account, bool friend})? had = used[id];
        if (had == null || e.hlc.millis > had.millis) {
          used[id] = (
            millis: e.hlc.millis,
            account: e.account,
            // One friend's use keeps it in the friends' budget.
            friend: friend || (had?.friend ?? false),
          );
        } else if (friend && !had.friend) {
          used[id] = (millis: had.millis, account: e.account, friend: true);
        }
      }
    }
  }
  final List<StoredMedia> out = <StoredMedia>[];
  for (final MapEntry<String, ({int millis, String account, bool friend})> u
      in used.entries) {
    final BlobManifest? manifest = node.blobs.manifest(u.key);
    if (manifest == null ||
        pinned.contains(u.key) ||
        !node.blobs.fetchedFor.containsKey(u.key) ||
        !node.blobs.isComplete(u.key)) {
      continue;
    }
    out.add(
      StoredMedia(
        id: u.key,
        bytes: manifest.size,
        account: u.value.account,
        millis: u.value.millis,
        owner: u.value.friend
            ? StoredMediaOwner.friend
            : StoredMediaOwner.cache,
      ),
    );
  }
  return out;
}

/// How much of the limits is used now (the "Limity przechowywania" page).
@immutable
final class StorageUsage {
  const StorageUsage({
    this.largestFriendBytes = 0,
    this.friendFiles = 0,
    this.cacheBytes = 0,
    this.cacheFiles = 0,
  });

  /// Photos and videos of the friend who has the most on this phone.
  final int largestFriendBytes;
  final int friendFiles;

  /// Photos and videos of everyone who is not a friend.
  final int cacheBytes;
  final int cacheFiles;
}

StorageUsage storageUsageOf(Iterable<StoredMedia> media) {
  final Map<String, int> perFriend = <String, int>{};
  int friendFiles = 0;
  int cacheBytes = 0;
  int cacheFiles = 0;
  for (final StoredMedia m in media) {
    if (m.owner == StoredMediaOwner.friend) {
      perFriend[m.account] = (perFriend[m.account] ?? 0) + m.bytes;
      friendFiles++;
    } else {
      cacheBytes += m.bytes;
      cacheFiles++;
    }
  }
  return StorageUsage(
    largestFriendBytes: perFriend.values.fold<int>(
      0,
      (int most, int bytes) => bytes > most ? bytes : most,
    ),
    friendFiles: friendFiles,
    cacheBytes: cacheBytes,
    cacheFiles: cacheFiles,
  );
}

/// What a round of the limits did.
@immutable
final class RetentionResult {
  const RetentionResult({
    this.expiredFiles = 0,
    this.expiredBytes = 0,
    this.limitFiles = 0,
    this.limitBytes = 0,
  });

  final int expiredFiles;
  final int expiredBytes;
  final int limitFiles;
  final int limitBytes;

  int get files => expiredFiles + limitFiles;
  int get bytes => expiredBytes + limitBytes;
}

/// Applies the limits now: deletes the files [planStorageRetention] picks
/// from the phone (they are not fetched again). Returns what went.
Future<RetentionResult> enforceStorageLimits(
  LedgerNode node, {
  int? nowMillis,
}) async {
  await node.start();
  if (node.isSuspended) {
    // Another process (the background service) owns the files right now.
    return const RetentionResult();
  }
  // Pictures of removed comments go first, whoever wrote them (this
  // account's own too: removed on another of its devices).
  int removedFiles = 0;
  int removedBytes = 0;
  for (final MapEntry<String, String> f in removedCommentFiles(node).entries) {
    final String id = f.key;
    if (node.blobs.refused.contains(id)) {
      continue;
    }
    final int size = node.blobs.manifest(id)?.size ?? 0;
    if (f.value == node.account) {
      await node.blobs.refuse(id);
    } else if (!await node.blobs.dropFor(id, f.value)) {
      continue;
    }
    removedBytes += size;
    removedFiles++;
  }
  final RetentionPlan plan = planStorageRetention(
    storedMediaOf(node),
    nowMillis: nowMillis ?? DateTime.now().millisecondsSinceEpoch,
  );
  if (plan.isEmpty) {
    return RetentionResult(
      expiredFiles: removedFiles,
      expiredBytes: removedBytes,
    );
  }
  int expiredBytes = removedBytes;
  int expiredFiles = 0;
  for (final StoredMedia m in plan.expired) {
    if (await node.blobs.expire(m.id)) {
      expiredFiles++;
      expiredBytes += m.bytes;
    }
  }
  int limitFiles = 0;
  int limitBytes = 0;
  for (final StoredMedia m in <StoredMedia>[
    ...plan.overPersonLimit,
    ...plan.overCache,
  ]) {
    if (await node.blobs.expire(m.id)) {
      limitFiles++;
      limitBytes += m.bytes;
    }
  }
  logZenMessage(
    'Limity miejsca: usunięto '
    '${expiredFiles + limitFiles + removedFiles} plików '
    '(${expiredBytes + limitBytes} B).',
  );
  return RetentionResult(
    expiredFiles: expiredFiles + removedFiles,
    expiredBytes: expiredBytes,
    limitFiles: limitFiles,
    limitBytes: limitBytes,
  );
}

/// Whether [post] is still kept at [nowMillis]: the wall leaves out
/// friends' ([friendAccounts]) posts older than [kFriendEntriesKept].
bool keptOnWall(FeedPost post, int nowMillis, Set<String> friendAccounts) =>
    post.isOwn ||
    !friendAccounts.contains(post.account) ||
    post.sortMillis >= nowMillis - kFriendEntriesKept.inMilliseconds;
