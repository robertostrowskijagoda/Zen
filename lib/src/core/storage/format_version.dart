import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Every JSON document this app stores names its format in `v`, so a later
/// build can tell one format from another instead of guessing from the
/// fields. Readers ignore keys they do not know.
///
/// The rules every reader of a stored or received format follows (from
/// 1.12.0 on, when formats became promises to builds already out there):
///
/// * it reads every version from its oldest one up to the one it writes
///   (one branch per version), and writes only the current one;
/// * a new optional field is added without raising the version: older
///   readers skip keys they do not know (and stores that rewrite a document
///   carry those keys along, [unknownFields]);
/// * a version above the current one was written by a newer build: the
///   data is kept exactly as it is ([NewerFormatException],
///   `FileBinaryStore.holdNewer`), never read as empty and saved over, and
///   the user is told to update ([ZenFormatGuard]);
/// * enums are stored by name, or by index with their order pinned by a
///   test (test/format_enums_test.dart);
/// * a sample of every format as 1.12.0 wrote it stays readable
///   (test/fixtures/formats/1.12.0, never edited).
const String kFormatVersionKey = 'v';

/// The first (and so far only) format version.
const int kFirstFormatVersion = 1;

/// [json] with `v` set to [version] (an existing `v` in [json] wins).
Map<String, Object?> withFormatVersion(
  Map<String, Object?> json, {
  int version = kFirstFormatVersion,
}) => <String, Object?>{kFormatVersionKey: version, ...json};

/// How a stored or received format version compares with what this build
/// reads.
enum FormatAge {
  /// A version this build reads (the current one or an older one it still
  /// knows).
  readable,

  /// Written by a newer build: kept as it is, never read as empty and
  /// saved over.
  newer,

  /// No version, or one below the oldest this build reads: damaged or not
  /// this format at all.
  invalid,
}

/// The age of format [version] for a reader that writes [current] and
/// still reads everything down to [oldest].
FormatAge formatAgeOf(
  Object? version, {
  required int current,
  int oldest = kFirstFormatVersion,
}) {
  if (version is! int) {
    return FormatAge.invalid;
  }
  if (version > current) {
    return FormatAge.newer;
  }
  return version < oldest ? FormatAge.invalid : FormatAge.readable;
}

/// The age of the JSON document [json] by its `v` ([FormatAge.invalid] for
/// anything but a map).
FormatAge jsonFormatAge(
  Object? json, {
  required int current,
  int oldest = kFirstFormatVersion,
}) => json is Map
    ? formatAgeOf(json[kFormatVersionKey], current: current, oldest: oldest)
    : FormatAge.invalid;

/// Whether [json] is a map whose `v` this build reads.
bool isReadableFormat(
  Object? json, {
  required int current,
  int oldest = kFirstFormatVersion,
}) =>
    jsonFormatAge(json, current: current, oldest: oldest) == FormatAge.readable;

/// The fields of [stored] that [known] (the same document as this build
/// writes it) does not have, without `v`: what a newer build added. A store
/// that rewrites the document carries them along ([withCarriedFields]), so
/// an older build never erases what a newer one saved.
Map<String, Object?> unknownFields(
  Map<dynamic, dynamic> stored,
  Map<String, Object?> known,
) => <String, Object?>{
  for (final MapEntry<dynamic, dynamic> e in stored.entries)
    if (e.key is String &&
        e.key != kFormatVersionKey &&
        !known.containsKey(e.key))
      e.key as String: e.value,
};

/// [json] with the [carried] fields of a newer build added (the fields of
/// [json] win).
Map<String, Object?> withCarriedFields(
  Map<String, Object?> json,
  Map<String, Object?> carried,
) => carried.isEmpty ? json : <String, Object?>{...carried, ...json};

/// A stored or received document in a format newer than this build reads.
///
/// A [FormatException], so code that treats unreadable data as damaged
/// keeps doing so; stores also hold such a file untouched
/// (`FileBinaryStore.holdNewer`).
final class NewerFormatException extends FormatException {
  NewerFormatException(
    this.what, {
    required this.found,
    required this.supported,
  }) : super('$what: format $found is newer than $supported.');

  /// Which document (a store key or a short name; never personal data).
  final String what;
  final Object? found;
  final int supported;
}

/// What this build learned about data written by a newer Zen: the store
/// areas (the first part of a store key) whose files it keeps untouched
/// because it cannot read them. The shell shows "update Zen" while this is
/// not empty.
final class ZenFormatGuard extends ChangeNotifier {
  ZenFormatGuard();

  /// The one the app's stores report to.
  static final ZenFormatGuard instance = ZenFormatGuard();

  final Set<String> _areas = <String>{};

  /// Areas with data from a newer build.
  Set<String> get newerAreas => Set<String>.unmodifiable(_areas);

  bool get hasNewerData => _areas.isNotEmpty;

  /// Notes that [storeKey] holds data a newer build wrote. Only the first
  /// part of the key is kept (the rest may name a friend).
  void noteNewer(String storeKey) {
    final String trimmed = storeKey.trim().replaceAll('\\', '/');
    final int slash = trimmed.indexOf('/');
    final String area = slash <= 0 ? trimmed : trimmed.substring(0, slash);
    if (area.isEmpty || !_areas.add(area)) {
      return;
    }
    logZenWarning('Data "$area" was written by a newer Zen; left as it is.');
    notifyListeners();
  }

  /// Forgets everything noted (tests).
  @visibleForTesting
  void reset() {
    if (_areas.isEmpty) {
      return;
    }
    _areas.clear();
    notifyListeners();
  }
}

/// The value at [index] of [values] (an enum stored by its index), or
/// [fallback] for an index this build does not know: a value a newer build
/// added at the end. Never throws, so one such value does not make a whole
/// file unreadable.
T enumAt<T>(List<T> values, int index, T fallback) =>
    index >= 0 && index < values.length ? values[index] : fallback;

/// Sets a plain file the app keeps outside its stores aside when it cannot
/// be read (not text, not JSON): renamed `<name>.damaged-<time>`, kept for
/// a look by hand and never read again, so the defaults take over once and
/// the next start does not stumble over it again. Never throws.
Future<void> setAsideDamagedFile(File file, Object error) async {
  logZenWarning('${_nameOf(file)} is damaged ($error); set aside.');
  try {
    if (await file.exists()) {
      await file.rename(
        '${file.path}.damaged-${DateTime.now().millisecondsSinceEpoch}',
      );
    }
  } on FileSystemException catch (failure) {
    logZenWarning('Setting a damaged file aside failed: $failure');
  }
}

String _nameOf(File file) {
  final String path = file.path.replaceAll('\\', '/');
  return path.substring(path.lastIndexOf('/') + 1);
}
