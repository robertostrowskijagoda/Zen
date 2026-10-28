import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/feed_maintenance.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/social/social_hub_controller.dart'
    show supportDirectoryResolverProvider;

/// Folder of the attachment transfers inside the data folder (not hidden:
/// `AttachmentTransferStore` lists it).
const String kTransfersFolder = 'transfers';

/// How much room Zen takes now, by what it is. Only what the storage layer
/// can tell apart without opening anything: the encrypted data files hide
/// their names, so messages, posts' entries, accounts and logs cannot be
/// told from each other and stay together in [otherBytes].
@immutable
final class StorageBreakdown {
  const StorageBreakdown({
    this.feedBytes = 0,
    this.mediaBytes = 0,
    this.backupsBytes = 0,
    this.otherBytes = 0,
  });

  /// Photos and videos of other people's posts (friends, followed accounts,
  /// posts passed on): the part the limit for the wall applies to.
  final int feedBytes;

  /// Encrypted media of chats and calls (attachments, voice messages,
  /// recordings) and attachments being transferred.
  final int mediaBytes;

  /// Files Zen exported on purpose (saved copies, backups, recordings).
  final int backupsBytes;

  /// Everything else: messages, the entries of posts, settings, logs.
  final int otherBytes;

  int get totalBytes => feedBytes + mediaBytes + backupsBytes + otherBytes;
}

/// The size of everything under [directory] (0 when it is not there).
/// Folders named in [skip] directly under it are left out.
Future<int> folderBytes(
  Directory directory, {
  Set<String> skip = const <String>{},
}) async {
  if (!await directory.exists()) {
    return 0;
  }
  final String root = directory.absolute.path;
  int total = 0;
  try {
    await for (final FileSystemEntity entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      if (skip.isNotEmpty) {
        final String relative = entity.absolute.path.substring(root.length);
        final List<String> parts = relative
            .split(Platform.pathSeparator)
            .where((String p) => p.isNotEmpty)
            .toList();
        if (parts.length > 1 && skip.contains(parts.first)) {
          continue;
        }
      }
      try {
        total += await entity.length();
      } on FileSystemException {
        // Gone while counting.
      }
    }
  } on FileSystemException catch (error) {
    logZenWarning('Counting a folder failed: $error');
  }
  return total;
}

/// Measures the account's folder [support] ([usage] says how much of it is
/// other people's posts) and the files it exported ([exportedPaths]; a
/// content address of Android is not a file to measure).
Future<StorageBreakdown> measureStorage({
  required Directory support,
  required StorageUsage usage,
  Iterable<String> exportedPaths = const <String>[],
}) async {
  final String separator = Platform.pathSeparator;
  final int all = await folderBytes(
    support,
    skip: const <String>{
      ZenInstance.accountsFolder,
      ZenInstance.profilesFolder,
    },
  );
  final int media =
      await folderBytes(
        Directory('${support.path}$separator$kMediaVaultFolder'),
      ) +
      await folderBytes(
        Directory('${support.path}${separator}data$separator$kTransfersFolder'),
      );
  int backups = 0;
  for (final String path in exportedPaths) {
    if (path.startsWith('content://')) {
      continue;
    }
    try {
      final File file = File(path);
      if (await file.exists()) {
        backups += await file.length();
      }
    } on FileSystemException {
      // Moved or deleted by the person.
    }
  }
  // The posts' files sit inside the data files: counted once, as theirs.
  final int feed = usage.feedBytes;
  final int rest = all - media - feed;
  return StorageBreakdown(
    feedBytes: feed,
    mediaBytes: media,
    backupsBytes: backups,
    otherBytes: rest < 0 ? 0 : rest,
  );
}

/// What Zen takes now, or `null` when it cannot be measured here.
final FutureProvider<StorageBreakdown?>
storageBreakdownProvider = FutureProvider.autoDispose<StorageBreakdown?>((
  Ref ref,
) async {
  try {
    final Directory support = await ref.watch(
      supportDirectoryResolverProvider,
    )();
    final StorageUsage usage =
        (await ref.watch(storageReportProvider.future))?.usage ??
        const StorageUsage();
    List<String> exported = const <String>[];
    try {
      exported = await const ExportedFilesIndex().paths();
    } on Object {
      // No secure storage: the exports are not counted.
    }
    return await measureStorage(
      support: support,
      usage: usage,
      exportedPaths: exported,
    );
  } on Object catch (error) {
    logZenWarning('Measuring the storage failed: $error');
    return null;
  }
});
