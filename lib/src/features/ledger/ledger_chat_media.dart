import 'dart:async';
import 'dart:typed_data';

import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// [ChatMediaBlocks] in the ledger's blob store: the same sealed, segmented
/// files as photos and films in posts (`post_media.dart`), fetched piece by
/// piece from whoever has them.
final class LedgerChatMediaBlocks implements ChatMediaBlocks {
  LedgerChatMediaBlocks(this.node);

  final LedgerNode node;

  @override
  Future<Map<String, dynamic>> store(
    Uint8List bytes, {
    required String mime,
    int? durationMs,
  }) => storeMedia(node.blobs, bytes, mime: mime, durationMs: durationMs);

  @override
  Future<Uint8List?> fetch(
    Map<String, dynamic> ref,
    List<String> sources, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final MediaRef? media = mediaRefFromJson(ref);
    if (media == null) {
      return null;
    }
    // A chat's file: no removal by other people may drop it from here.
    node.blobs.claim(media.id);
    if (!node.blobs.isComplete(media.id)) {
      final Future<String> done = node.mediaCompleted.firstWhere(
        (String id) => id == media.id,
      );
      node.fetchBlobFrom(media.id, sources);
      try {
        await done.timeout(timeout);
      } on Object {
        return null; // not now: asked again when the chat is opened
      }
    }
    return openMedia(node.blobs, media);
  }
}
