import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// Bytes of one part of a backup file: a larger copy goes on in
/// `name.2`, `name.3`… (memory cards and some disks take at most 4 GB in
/// one file).
const int kAccountBackupPartBytes = 1024 * 1024 * 1024;

/// The path of part [part] (from 1) of the backup whose first part is
/// [first].
String accountBackupPartPath(String first, int part) =>
    part <= 1 ? first : '$first.$part';

/// A name for a new backup file.
String accountBackupFileName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'zen-konto-${at.year}-${two(at.month)}-${two(at.day)}'
      '.$kAccountBackupExtension';
}

/// Writes [build] for [password] into [first] (and its next parts when
/// it is larger than [partBytes]), file by file as they are read, never
/// all in memory. Returns the paths written. [remember]: the panic
/// password deletes them too.
Future<List<String>> writeAccountBackup({
  required AccountArchiveBuild build,
  required String password,
  required String first,
  int partBytes = kAccountBackupPartBytes,
  PasswordCost cost = kRecoveryPasswordCost,
  void Function(int done, int total)? progress,
  bool remember = true,
}) async {
  final List<String> paths = <String>[];
  late IOSink sink;
  int inPart = 0;
  Future<void> next() async {
    if (paths.isNotEmpty) {
      await sink.flush();
      await sink.close();
    }
    final String path = accountBackupPartPath(first, paths.length + 1);
    paths.add(path);
    sink = File(path).openWrite();
    inPart = 0;
  }

  await next();
  try {
    await AccountBackupFile.write(
      archive: build.archive,
      blobs: build.blobs,
      password: password,
      cost: cost,
      progress: progress,
      out: (Uint8List bytes) async {
        int at = 0;
        while (at < bytes.length) {
          if (inPart >= partBytes) {
            await next();
          }
          final int n = math.min(bytes.length - at, partBytes - inPart);
          sink.add(Uint8List.sublistView(bytes, at, at + n));
          inPart += n;
          at += n;
        }
        await sink.flush();
      },
    );
    await sink.close();
  } on Object {
    try {
      await sink.close();
    } on Object {
      // Already closed.
    }
    for (final String p in paths) {
      try {
        await File(p).delete();
      } on FileSystemException {
        // Gone already.
      }
    }
    rethrow;
  }
  // Parts of an older backup under the same name would be read after
  // this one.
  for (int i = paths.length + 1; ; i++) {
    final File stale = File(accountBackupPartPath(first, i));
    if (!await stale.exists()) {
      break;
    }
    await stale.delete();
  }
  if (remember) {
    for (final String p in paths) {
      await rememberExportedFile(p);
    }
  }
  return paths;
}

/// The parts of the backup that [path] (any of its parts) belongs to, in
/// order.
Future<List<String>> accountBackupParts(String path) async {
  String first = path;
  final RegExpMatch? m = RegExp(r'^(.*)\.(\d+)$').firstMatch(path);
  if (m != null &&
      int.parse(m.group(2)!) >= 2 &&
      await File(m.group(1)!).exists()) {
    first = m.group(1)!;
  }
  final List<String> parts = <String>[first];
  for (int i = 2; await File(accountBackupPartPath(first, i)).exists(); i++) {
    parts.add(accountBackupPartPath(first, i));
  }
  return parts;
}

/// The bytes of [paths], one after another.
Stream<List<int>> readAccountBackupParts(List<String> paths) async* {
  for (final String p in paths) {
    yield* File(p).openRead();
  }
}

/// How restoring a backup file went: the reason it did not open, or what
/// taking it in did.
typedef AccountBackupRestore = ({
  AccountBackupError? error,
  AccountImportOutcome? outcome,
});

/// Reads the backup in [paths] for [password] and takes it in through
/// [importer]: the manifest is checked first (another account's copy is
/// refused before its files are read), then its files wait in the
/// importer's staging until they are taken in.
Future<AccountBackupRestore> restoreAccountBackup({
  required List<String> paths,
  required String password,
  required AccountArchiveImporter importer,
  List<PasswordCost> acceptedCosts = kAcceptedRecoveryCosts,
}) async {
  AccountImportOutcome? refused;
  AccountArchive? seen;
  final ({AccountArchive? archive, AccountBackupError? error}) read =
      await AccountBackupFile.read(
        chunks: readAccountBackupParts(paths),
        password: password,
        acceptedCosts: acceptedCosts,
        // Each file goes to the staging block by block as it is read.
        file: (String id, int size) async => importer.staging.writer(id),
        accept: (AccountArchive archive) async {
          seen = archive;
          refused = await importer.check(
            archive.account,
            withKey: archive.seed != null,
          );
          return refused == null;
        },
      );
  final AccountArchive? archive = read.archive;
  if (read.error != null || archive == null) {
    // What came before the damage.
    await importer.staging.clear(seen);
    return (error: read.error ?? AccountBackupError.format, outcome: null);
  }
  if (refused != null) {
    return (error: null, outcome: refused);
  }
  return (error: null, outcome: await importer.take(archive));
}
