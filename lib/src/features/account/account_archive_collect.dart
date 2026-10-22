import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';

/// The profile photos in a copy (keys of the profile section naming their
/// files).
const String kAccountAvatarFile = 'avatar_file';
const String kAccountCoverFile = 'cover_file';

/// Entries per segment of the account's log on disk ([LedgerArchive]).
const int kAccountLogSegment = 200;

/// What a copy of the account is collected from: the app's services (or a
/// test's data).
abstract interface class AccountArchiveSource {
  String get account;

  /// The account key's seed while it is unlocked.
  Uint8List? get seed;

  /// The account's encrypted store (stored states, its log).
  LedgerDisk get disk;

  /// Friends and groups ([CircleBackupSections.contacts]).
  Map<String, dynamic> contacts();

  /// Friend address → friendship level.
  Map<String, String> levels();

  /// The conversations (friends' addresses, `group:<id>`).
  List<String> conversationKeys();
  Future<List<ChatMessage>> messages(String key);

  /// The profile without its photos' paths, and those paths.
  Map<String, dynamic> profile();
  String? get avatarPath;
  String? get coverPath;

  Map<String, dynamic> settings();

  /// The pyramid's state and the wallet, if a member.
  Map<String, dynamic>? pyramid();

  /// The dating profile with its photos and settings.
  Map<String, dynamic> dating();

  /// The household (flat key, resident key, profile), if any — here, or
  /// the copy another device of the account keeps in sync.
  Future<Map<String, dynamic>?> household();

  /// A stored state (raw bytes under [key]) — here, or the copy another
  /// device of the account keeps in sync.
  Future<Uint8List?> readState(String key);

  /// Bytes [start] to [end] of a file the app keeps (in the media vault
  /// or plain): files are read piece by piece, never whole.
  Future<Uint8List?> readFileRange(String path, int start, int end);

  /// Its size (plain bytes), or null when it is not there.
  Future<int?> fileSize(String path);
}

/// Collects a copy of the account from [source]: the parts in [scope],
/// with the account key's seed when [AccountScope.keys] is in it (the key
/// must be unlocked then). [measureOnly]: sizes only, for the estimate.
Future<AccountArchiveBuild> buildAccountArchive(
  AccountArchiveSource source,
  Set<AccountScope> scope, {
  bool measureOnly = false,
  int? at,
}) async {
  final AccountArchiveBuilder b = AccountArchiveBuilder(
    account: source.account,
    scope: scope,
    measureOnly: measureOnly,
  )..seed = source.seed;
  if (b.has(AccountScope.keys) && b.seed == null && !measureOnly) {
    throw StateError('The account key is locked.');
  }
  Future<String?> addPath(String? path) async {
    final String? p = path?.trim();
    if (p == null || p.isEmpty) {
      return null;
    }
    final int? size = await source.fileSize(p);
    if (size == null) {
      return null;
    }
    if (measureOnly) {
      return b.addMeasured(p, size);
    }
    return b.addFile(
      size,
      (int start, int end) => source.readFileRange(p, start, end),
    );
  }

  if (b.has(AccountScope.contacts)) {
    b.sections[CircleBackupSections.contacts] = source.contacts();
    b.sections[CircleBackupSections.levels] = source.levels();
  }
  if (b.has(AccountScope.chats)) {
    for (final String key in source.conversationKeys()) {
      final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];
      for (final ChatMessage m in await source.messages(key)) {
        if (m.disappears) {
          continue;
        }
        final Map<String, dynamic> json = chatMessageToSync(m);
        if (b.has(AccountScope.media) && m.type != ChatMessageType.text) {
          final Uint8List? inMemory = m.attachmentBytes;
          final String? id = inMemory != null && inMemory.isNotEmpty
              ? b.addBytes(inMemory)
              : await addPath(m.attachmentPath);
          if (id != null) {
            json['af'] = id;
          }
        }
        messages.add(json);
      }
      if (messages.isNotEmpty) {
        b.chats[key] = messages;
      }
    }
  }
  if (b.has(AccountScope.profile)) {
    final String? avatar = await addPath(source.avatarPath);
    final String? cover = await addPath(source.coverPath);
    b.sections[CircleBackupSections.profile] = <String, dynamic>{
      ...source.profile(),
      kAccountAvatarFile: ?avatar,
      kAccountCoverFile: ?cover,
    };
  }
  if (b.has(AccountScope.settings)) {
    b.sections[CircleBackupSections.settings] = source.settings();
  }
  if (b.has(AccountScope.pyramid)) {
    final Map<String, dynamic>? pyramid = source.pyramid();
    if (pyramid != null) {
      b.sections[CircleBackupSections.pyramid] = pyramid;
    }
  }
  if (b.has(AccountScope.dating)) {
    b.sections[CircleBackupSections.dating] = source.dating();
  }
  if (b.has(AccountScope.neighbors)) {
    final Map<String, dynamic>? household = await source.household();
    if (household != null) {
      b.sections[CircleBackupSections.household] = household;
    }
  }
  for (final MapEntry<AccountScope, List<String>> e
      in kAccountRawKeys.entries) {
    if (!b.has(e.key)) {
      continue;
    }
    for (final String key in e.value) {
      final Uint8List? value = await source.readState(key);
      if (value != null) {
        b.raw[key] = b.addBytes(value);
      }
    }
  }
  if (b.has(AccountScope.profile) || b.has(AccountScope.films)) {
    await _collectLedger(source.disk, b);
  }
  return (
    archive: b.build(at: at ?? DateTime.now().millisecondsSinceEpoch),
    blobs: b.blobs,
  );
}

/// The key of segment [segment] of the log of [writer] in [space].
String accountLogKey(String space, String writer, int segment) =>
    LedgerArchive.logKeyOf(space, writer, segment);

/// The account's log (posts, gallery, films, public profile): its index
/// (only the logs of the parts chosen), certificates, segments, file lists
/// and — with media — the pieces of its files ([LedgerArchive.exportFiles]).
Future<void> _collectLedger(LedgerDisk disk, AccountArchiveBuilder b) async {
  bool allowed(String space) => switch (space.split('/').first) {
    // Copies of this account's chats for its own devices.
    'own' => b.has(AccountScope.chats),
    // Friends, groups and settings sealed for its own devices.
    'private' => b.has(AccountScope.contacts),
    _ => true,
  };
  final Map<String, Uint8List> files = await LedgerArchive.exportFiles(
    disk,
    keepSpace: allowed,
    withPieces: b.has(AccountScope.media),
    segmentSize: kAccountLogSegment,
  );
  files.forEach((String key, Uint8List data) {
    b.raw[key] = b.addBytes(data);
  });
}
