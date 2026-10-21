import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// "Usuń z mojego urządzenia" for a reported post: the photos,
/// films and recordings of it go from this phone and are never fetched or
/// passed on again. The entries of the ledger are signed and append-only
/// (nobody's log can be rewritten on another phone), so the text of the
/// post stays where it is; it stays hidden instead (see `HiddenByMe`).
Future<void> deletePostMediaLocally(
  LedgerNode node,
  Iterable<MediaRef> media,
) async {
  for (final MediaRef m in media) {
    await node.blobs.refuse(m.id);
  }
}
