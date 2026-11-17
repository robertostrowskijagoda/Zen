import 'dart:io';

/// A vault file younger than this is never swept: whatever holds it (a
/// message being received, by the background service too) records it long
/// before.
const Duration kMediaVaultSweepMinAge = Duration(days: 2);

/// Entries of the vault folder looked at in one sweep.
const int kMediaVaultSweepMaxListed = 20000;

/// Files removed in one sweep; the rest waits for the next one.
const int kMediaVaultSweepMaxRemoved = 200;

/// Past this many unused files, more than half of the old enough ones
/// unused tells of a list of files in use that missed something rather
/// than of leftovers: nothing is removed then.
const int kMediaVaultSweepPlausibleOrphans = 20;

/// A vault file (`<32 hex>.zmedia`) or one being written (`.tmp` after
/// it), as `media_vault.dart` names them.
final RegExp _vaultName = RegExp(r'^([0-9a-f]{32}\.zmedia)(\.tmp)?$');

/// How a sweep ended.
enum MediaVaultSweepOutcome {
  /// Nothing old enough and unused.
  nothing,

  /// Unused files were removed ([MediaVaultSweepResult.removed]).
  swept,

  /// The list of files in use could not be read: nothing was removed.
  unreadable,

  /// Too many files looked unused to be believed: nothing was removed.
  implausible,
}

/// What a sweep did: counts and bytes only, never names.
final class MediaVaultSweepResult {
  const MediaVaultSweepResult(
    this.outcome, {
    this.removed = 0,
    this.bytes = 0,
    this.unused = 0,
  });

  final MediaVaultSweepOutcome outcome;

  /// Files removed and their size together.
  final int removed;
  final int bytes;

  /// Old enough files found unused (removed or left for the next sweep).
  final int unused;
}

/// Removes the files of the media vault [folder] that nothing refers to:
/// encrypted media whose message, chat or photo is gone, and `.tmp` files
/// of writes that never finished.
///
/// A file is removed only when all of these hold:
/// * its name is a vault file's (anything else is left alone);
/// * it was last written at least [minAge] before [now] (a time in the
///   future counts as young);
/// * [inFlight] does not claim it (written or being written in this run);
/// * for a finished file, its name is not in [referenced], which is read
///   after the folder is listed. When [referenced] throws, nothing is
///   removed.
///
/// At most [maxListed] entries are looked at and [maxRemoved] files
/// removed. The folder itself is never made nor removed.
Future<MediaVaultSweepResult> sweepMediaVault({
  required Directory folder,
  required Future<Set<String>> Function() referenced,
  required bool Function(String name) inFlight,
  DateTime Function() now = DateTime.now,
  Duration minAge = kMediaVaultSweepMinAge,
  int maxListed = kMediaVaultSweepMaxListed,
  int maxRemoved = kMediaVaultSweepMaxRemoved,
}) async {
  if (!await folder.exists()) {
    return const MediaVaultSweepResult(MediaVaultSweepOutcome.nothing);
  }
  final DateTime cutoff = now().subtract(minAge);
  final List<({File file, String name, bool partial})> old =
      <({File file, String name, bool partial})>[];
  int listed = 0;
  try {
    await for (final FileSystemEntity entity in folder.list(
      followLinks: false,
    )) {
      if (++listed > maxListed) {
        break;
      }
      if (entity is! File) {
        continue;
      }
      final String base = entity.uri.pathSegments.last.toLowerCase();
      final RegExpMatch? match = _vaultName.firstMatch(base);
      if (match == null) {
        continue;
      }
      final String name = match.group(1)!;
      if (inFlight(name)) {
        continue;
      }
      try {
        if (!(await entity.lastModified()).isBefore(cutoff)) {
          continue;
        }
      } on FileSystemException {
        continue;
      }
      old.add((file: entity, name: name, partial: match.group(2) != null));
    }
  } on FileSystemException {
    // The folder changed while it was listed: what was seen is enough.
  }
  if (old.isEmpty) {
    return const MediaVaultSweepResult(MediaVaultSweepOutcome.nothing);
  }
  final Set<String> inUse;
  try {
    inUse = <String>{
      for (final String name in await referenced()) name.toLowerCase(),
    };
  } on Object {
    return const MediaVaultSweepResult(MediaVaultSweepOutcome.unreadable);
  }
  final List<({File file, String name, bool partial})> unused =
      <({File file, String name, bool partial})>[
        for (final ({File file, String name, bool partial}) f in old)
          if (f.partial || !inUse.contains(f.name)) f,
      ];
  final int finished = old.where((f) => !f.partial).length;
  final int unusedFinished = unused.where((f) => !f.partial).length;
  if (unusedFinished > kMediaVaultSweepPlausibleOrphans &&
      unusedFinished * 2 > finished) {
    return MediaVaultSweepResult(
      MediaVaultSweepOutcome.implausible,
      unused: unused.length,
    );
  }
  int removed = 0;
  int bytes = 0;
  for (final ({File file, String name, bool partial}) f in unused) {
    if (removed >= maxRemoved) {
      break;
    }
    try {
      final int size = await f.file.length();
      await f.file.delete();
      removed++;
      bytes += size;
    } on FileSystemException {
      // Gone already or held open: the next sweep tries again.
    }
  }
  return MediaVaultSweepResult(
    removed > 0 ? MediaVaultSweepOutcome.swept : MediaVaultSweepOutcome.nothing,
    removed: removed,
    bytes: bytes,
    unused: unused.length,
  );
}
