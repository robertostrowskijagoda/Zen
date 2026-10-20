import 'package:flutter/foundation.dart';

/// How full one stored file is against its size limit.
enum StorageFill {
  /// Comfortably below the warning level (or nothing recorded).
  ok,

  /// Past the warning level (half of the limit by default).
  warn,

  /// Past three quarters of the limit: the next big write may not fit.
  critical,

  /// Over the limit: writes of this file are being refused.
  full,
}

/// One stored file that is near (or over) its limit.
@immutable
final class StorageHealthEntry {
  const StorageHealthEntry({
    required this.category,
    required this.bytes,
    required this.limit,
    required this.fill,
  });

  /// The first part of the store key (`dating`, `meet`, `ledger`...). Never
  /// the rest of the key, which may contain a friend's address.
  final String category;
  final int bytes;
  final int limit;
  final StorageFill fill;

  double get ratio => limit <= 0 ? 0 : bytes / limit;
}

/// What the binary store learned about file sizes: files that approach the
/// 20 MB cap are recorded here (and logged) before a write starts failing,
/// so other screens can say so. Read [warnings] / [worst]; listen to react.
final class ZenStorageHealth extends ChangeNotifier {
  ZenStorageHealth();

  /// The one the app's stores report to.
  static final ZenStorageHealth instance = ZenStorageHealth();

  static const double criticalFraction = 0.75;

  final Map<String, StorageHealthEntry> _byKey = <String, StorageHealthEntry>{};

  /// The part of [storeKey] before the first `/`.
  static String categoryOf(String storeKey) {
    final int slash = storeKey.indexOf('/');
    return slash <= 0 ? storeKey : storeKey.substring(0, slash);
  }

  /// Records that [storeKey] now takes [bytes] of [limit]. Returns its
  /// level; a file below [warnFraction] is forgotten.
  StorageFill record(
    String storeKey, {
    required int bytes,
    required int limit,
    double warnFraction = 0.5,
  }) {
    final StorageFill fill = _fillOf(bytes, limit, warnFraction);
    final StorageHealthEntry? previous = _byKey[storeKey];
    if (fill == StorageFill.ok) {
      if (_byKey.remove(storeKey) != null) {
        notifyListeners();
      }
      return fill;
    }
    _byKey[storeKey] = StorageHealthEntry(
      category: categoryOf(storeKey),
      bytes: bytes,
      limit: limit,
      fill: fill,
    );
    if (previous == null || previous.fill != fill) {
      notifyListeners();
    }
    return fill;
  }

  /// The level last recorded for [storeKey].
  StorageFill fillOf(String storeKey) =>
      _byKey[storeKey]?.fill ?? StorageFill.ok;

  /// The files that are near the limit, fullest first.
  List<StorageHealthEntry> get warnings {
    final List<StorageHealthEntry> all = _byKey.values.toList()
      ..sort(
        (StorageHealthEntry a, StorageHealthEntry b) =>
            b.ratio.compareTo(a.ratio),
      );
    return List<StorageHealthEntry>.unmodifiable(all);
  }

  /// True while any file is near its limit.
  bool get hasWarning => _byKey.isNotEmpty;

  /// The fullest file's level ([StorageFill.ok] when none).
  StorageFill get worst => _byKey.values.fold<StorageFill>(
    StorageFill.ok,
    (StorageFill w, StorageHealthEntry e) =>
        e.fill.index > w.index ? e.fill : w,
  );

  /// The level of the fullest file whose store key starts with [prefix]
  /// (`dating/`): for a feature to decide to move bulk data (photos) out
  /// of its state file.
  StorageFill fillOfPrefix(String prefix) {
    StorageFill result = StorageFill.ok;
    for (final MapEntry<String, StorageHealthEntry> e in _byKey.entries) {
      if (e.key.startsWith(prefix) && e.value.fill.index > result.index) {
        result = e.value.fill;
      }
    }
    return result;
  }

  /// Forgets everything (tests; after the data was erased).
  void clear() {
    if (_byKey.isEmpty) {
      return;
    }
    _byKey.clear();
    notifyListeners();
  }

  static StorageFill _fillOf(int bytes, int limit, double warnFraction) {
    if (limit <= 0) {
      return StorageFill.ok;
    }
    if (bytes > limit) {
      return StorageFill.full;
    }
    if (bytes >= limit * criticalFraction) {
      return StorageFill.critical;
    }
    return bytes >= limit * warnFraction ? StorageFill.warn : StorageFill.ok;
  }
}
