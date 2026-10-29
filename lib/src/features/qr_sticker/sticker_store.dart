import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';

/// The last design of each kind of sticker, in the encrypted store (the
/// texts can name the household).
final class StickerStore {
  StickerStore(this.disk);

  /// Where it is kept.
  static const String diskKey = 'qr/stickers';

  final LedgerDisk disk;

  Map<String, Object?>? _all;

  Future<Map<String, Object?>> _read() async {
    final Map<String, Object?>? cached = _all;
    if (cached != null) {
      return cached;
    }
    Map<String, Object?> all = <String, Object?>{};
    try {
      final Uint8List? raw = await disk.read(diskKey);
      if (raw != null && raw.isNotEmpty) {
        final Object? json = jsonDecode(utf8.decode(raw));
        if (json is Map<String, Object?>) {
          all = json;
        }
      }
    } on Object {
      // Unreadable: the designs start again from their defaults.
    }
    return _all = all;
  }

  /// The last design of [kind], or null when it was never changed.
  Future<StickerDesign?> load(StickerKind kind) async {
    final Object? json = (await _read())[kind.name];
    return json is Map ? StickerDesign.fromJson(json) : null;
  }

  Future<void> save(StickerKind kind, StickerDesign design) async {
    final Map<String, Object?> all = await _read();
    all[kind.name] = design.toJson();
    await disk.write(diskKey, Uint8List.fromList(utf8.encode(jsonEncode(all))));
  }
}

final Provider<StickerStore> stickerStoreProvider = Provider<StickerStore>(
  (Ref ref) => StickerStore(ref.watch(ledgerDiskProvider)),
);
