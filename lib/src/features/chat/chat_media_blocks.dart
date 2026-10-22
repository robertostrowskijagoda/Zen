import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Files shared in a group as content-addressed blocks (the ledger's blob
/// store): sealed once under a fresh key, the blocks can come from anyone
/// who already has them, so the sender does not upload a copy per member.
/// Only the small reference (`{id, k, n, mime}`, with the key) travels in
/// the group message itself.
abstract interface class ChatMediaBlocks {
  /// Seals [bytes] and keeps them as blocks; returns the reference.
  Future<Map<String, dynamic>> store(
    Uint8List bytes, {
    required String mime,
    int? durationMs,
  });

  /// The file [ref] names, fetched from [sources] (the sender and the other
  /// members); `null` when it did not arrive within [timeout] or does not
  /// open.
  Future<Uint8List?> fetch(
    Map<String, dynamic> ref,
    List<String> sources, {
    Duration timeout = const Duration(minutes: 10),
  });
}

/// Filled in by whoever keeps the blocks (the ledger) once it runs; `null`
/// until then, and in tests: group files then travel inline.
final class ChatMediaBlocksHolder {
  ChatMediaBlocks? blocks;
}

final Provider<ChatMediaBlocksHolder> chatMediaBlocksHolderProvider =
    Provider<ChatMediaBlocksHolder>((Ref ref) => ChatMediaBlocksHolder());
