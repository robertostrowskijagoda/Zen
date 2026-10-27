import 'dart:isolate';
import 'dart:typed_data';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/gif_shrink.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/social/mentions.dart';

// Pictures in comments (under posts and films): photos and GIFs, up to
// [kMaxCommentImages] in one comment. They travel exactly like a post's
// photos: each is a sealed file in the writer's blob store
// (`storeMedia`), named by the signed comment entry, so friends fetch it
// with the comment, the account's other devices keep it
// (`OwnMediaKeeper`) and the full account copy holds it with the rest of
// the ledger's files. Friends of friends get them through the bundles that
// pass comments on (`reaction_relay.dart`). Removing a comment
// ([kCommentDeleteKind]) deletes its files here at once and on every other
// phone at the next round of the storage limits.

/// The largest picture in a comment, in bytes. A bigger GIF is made
/// smaller ([shrinkGif]) and still plays.
const int kMaxCommentImageBytes = 3 * 1024 * 1024;

/// The longest side of a GIF that had to be made smaller for a comment.
const int kCommentGifSide = 480;

/// One picture ready to go into a comment.
typedef CommentPicture = ({Uint8List bytes, String mime});

/// [bytes] (a picked, pasted or inserted picture) made ready for a
/// comment: a GIF stays an animated GIF, without its metadata and within
/// [kMaxCommentImageBytes] (made smaller when it has to be); anything else
/// becomes a fresh JPEG ([sanitizePhoto]). Throws [ArgumentError] with the
/// reason to show when it cannot go.
Future<CommentPicture> commentPicture(Uint8List bytes) async {
  if (looksLikeGif(bytes)) {
    final PickedGif gif = preparePickedGif(bytes);
    if (gif.status == PickedGifStatus.ready &&
        gif.bytes!.length <= kMaxCommentImageBytes) {
      return (bytes: gif.bytes!, mime: 'image/gif');
    }
    if (gif.status == PickedGifStatus.broken) {
      throw ArgumentError(t('Ten GIF jest uszkodzony albo niepełny.'));
    }
    final Uint8List? small = bytes.length > kMaxSentGifBytes
        ? null
        : await _shrinkForComment(bytes);
    if (small == null) {
      throw ArgumentError(
        t(
          'Ten GIF jest za duży (maks. {size}, {side} px na bok, {frames} '
          'klatek).',
          <String, Object>{
            'size': '${kMaxSentGifBytes ~/ (1024 * 1024)} MB',
            'side': kMaxGifSide,
            'frames': kMaxGifFrames,
          },
        ),
      );
    }
    return (bytes: small, mime: 'image/gif');
  }
  Uint8List? photo;
  try {
    photo = await sanitizePhoto(bytes);
  } on ArgumentError {
    photo = null;
  }
  if (photo == null || photo.length > kMaxCommentImageBytes) {
    throw ArgumentError(t('Ten plik nie jest zdjęciem.'));
  }
  return (bytes: photo, mime: 'image/jpeg');
}

// Not async on purpose: a closure made in an async function may drag its
// suspended frame along, which cannot be sent to another isolate.
Future<Uint8List?> _shrinkForComment(Uint8List bytes) => Isolate.run(
  () => shrinkGif(
    bytes,
    maxSide: kCommentGifSide,
    maxBytes: kMaxCommentImageBytes,
  ),
);

/// Throws [ArgumentError] when [pictures] cannot go into one comment.
void checkCommentPictures(List<CommentPicture> pictures) {
  if (pictures.length > kMaxCommentImages) {
    throw ArgumentError(
      tn(
        kMaxCommentImages,
        one: 'Komentarz może mieć najwyżej {n} obrazek.',
        few: 'Komentarz może mieć najwyżej {n} obrazki.',
        many: 'Komentarz może mieć najwyżej {n} obrazków.',
      ),
    );
  }
  for (final CommentPicture p in pictures) {
    if (!isPhotoMime(p.mime) ||
        p.bytes.isEmpty ||
        p.bytes.length > kMaxCommentImageBytes) {
      throw ArgumentError(t('Ten plik nie jest zdjęciem.'));
    }
  }
}

/// Writes a comment on [postId] (a post or a film) with [text] and
/// [pictures] (made ready with [commentPicture]): the pictures are stored
/// sealed first and named by the entry. The `<@N>` tokens of [text] name
/// [mentions]. Throws [ArgumentError] for an empty or too long comment, or
/// too many pictures (nothing is stored then).
Future<LogEntry> publishComment(
  LedgerNode node,
  String postId,
  String text, {
  List<CommentPicture> pictures = const <CommentPicture>[],
  List<Mention> mentions = const <Mention>[],
}) async {
  checkCommentPictures(pictures);
  // The text is checked before any file is stored.
  commentBody(
    postId,
    text,
    images: <Map<String, dynamic>>[
      for (int i = 0; i < pictures.length; i++) const <String, dynamic>{},
    ],
  );
  final List<Map<String, dynamic>> refs = <Map<String, dynamic>>[];
  try {
    for (final CommentPicture p in pictures) {
      refs.add(await storeMedia(node.blobs, p.bytes, mime: p.mime));
    }
    return await node.publish(
      kCommentKind,
      commentBody(
        postId,
        text,
        mini: ownMiniProfile(node),
        images: refs,
        mentions: mentions,
      ),
      spaceKind: 'acts',
      blobs: mediaIds(refs),
    );
  } on Object {
    // Nothing names them: they go.
    for (final String id in mediaIds(refs)) {
      await node.blobs.refuse(id);
    }
    rethrow;
  }
}

/// Whether [comment] is this account's own (it may remove it).
bool canDeleteComment(LedgerNode node, FeedComment comment) =>
    comment.account.isNotEmpty && comment.account == node.account;

/// Removes this account's own [comment] under [postId]: a signed
/// [kCommentDeleteKind], and its pictures are deleted from this device at
/// once (from the others at their next round of the storage limits).
Future<void> deleteComment(
  LedgerNode node,
  String postId,
  FeedComment comment,
) async {
  if (!canDeleteComment(node, comment)) {
    throw ArgumentError(t('Usunąć można tylko swój komentarz.'));
  }
  await node.publish(
    kCommentDeleteKind,
    commentDeleteBody(postId, comment.id),
    spaceKind: 'acts',
  );
  for (final MediaRef m in comment.images) {
    await node.blobs.refuse(m.id);
  }
}

/// Files of comments their writers removed, in every `acts` space this
/// node holds (this account's own too), and pictures only older bundles
/// still name (a comment passed on before it was removed): they are
/// deleted by the storage limits and never fetched again. A file anything
/// else still names (a comment that stays, a newest bundle) is left out.
Set<String> removedCommentMedia(LedgerNode node) =>
    removedCommentFiles(node).keys.toSet();

/// [removedCommentMedia] with the writer whose removal frees each file.
///
/// Another writer's removal frees only a file that writer's own entry
/// brought to this device (`BlobStore.fetchedFor`) and that the removed
/// comment really shows (its `img`): naming the id of somebody else's
/// file (a film sent in a group, a picture under the pyramid, a photo
/// this phone made) in a comment and removing it does nothing. This
/// account's own removals (made on another of its devices) are trusted.
/// An older bundle frees only files some writer's entry brought here.
Map<String, String> removedCommentFiles(LedgerNode node) {
  final Map<String, String> gone = <String, String>{};
  final Set<String> live = <String>{};
  final Map<String, String> fetchedFor = node.blobs.fetchedFor;
  for (final String space in node.store.spaces.toList()) {
    final List<LogEntry> entries = node.store.entries(space);
    if (!space.startsWith('acts/')) {
      for (final LogEntry e in entries) {
        live.addAll(e.blobs);
      }
      continue;
    }
    final Set<String> removed = deletedCommentIds(entries);
    // The newest bundle page per post and page number.
    final Map<String, LogEntry> newest = <String, LogEntry>{};
    for (final LogEntry e in entries) {
      if (e.kind != kReactionsKind && e.kind != kReactionsPageKind) {
        continue;
      }
      final String key = '${e.kind}|${e.body['post']}|${e.body['pg']}';
      final LogEntry? had = newest[key];
      if (had == null || e.hlc > had.hlc) {
        newest[key] = e;
      }
    }
    final Set<String> current = <String>{
      for (final LogEntry e in newest.values) e.id,
    };
    for (final LogEntry e in entries) {
      final bool bundle =
          e.kind == kReactionsKind || e.kind == kReactionsPageKind;
      if (removed.contains(e.id)) {
        final Set<String> shown = <String>{
          for (final MediaRef m in commentImagesOf(e.body['img'])) m.id,
        };
        for (final String id in e.blobs) {
          if (!shown.contains(id)) {
            continue;
          }
          if (e.account == node.account || fetchedFor[id] == e.account) {
            gone[id] = e.account;
          }
        }
      } else if (bundle && !current.contains(e.id)) {
        for (final String id in e.blobs) {
          final String? by = fetchedFor[id];
          if (by != null && (by == e.account || e.account == node.account)) {
            gone[id] = by;
          }
        }
      } else {
        live.addAll(e.blobs);
      }
    }
  }
  gone.removeWhere((String id, String _) => live.contains(id));
  return gone;
}
