import 'dart:async';
import 'dart:io';

import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/groups/group_store.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/guarded_settings_store.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

final class ZenPersistentStores {
  ZenPersistentStores({
    required this.signalQueueStore,
    required this.socialSnapshotStore,
    required this.messageTimelineStore,
    required this.attachmentTransferStore,
    required this.appSettingsStore,
    UserProfileStore? userProfileStore,
    GroupStore? groupStore,
    RelayStateStore? relayStateStore,
    LedgerDisk? ledgerDisk,
  }) : userProfileStore = userProfileStore ?? MemoryUserProfileStore(),
       groupStore = groupStore ?? MemoryGroupStore(),
       relayStateStore = relayStateStore ?? MemoryRelayStateStore(),
       ledgerDisk = ledgerDisk ?? MemoryLedgerDisk();

  final SignalQueueStore signalQueueStore;
  final SocialSnapshotStore socialSnapshotStore;
  final MessageTimelineStore messageTimelineStore;
  final AttachmentTransferStore attachmentTransferStore;
  final AppSettingsStore appSettingsStore;
  final UserProfileStore userProfileStore;
  final GroupStore groupStore;

  /// Outbox, relay directory and mail held for friends.
  final RelayStateStore relayStateStore;

  /// Files of the ledger (posts, profiles, media), in the encrypted store.
  final LedgerDisk ledgerDisk;
}

Future<ZenPersistentStores> buildDefaultZenPersistentStores() async {
  final Directory supportDirectory = await ZenInstance.supportDirectory();
  return buildZenPersistentStoresForDirectory(supportDirectory);
}

/// The settings file, read before the app is unlocked (so it is not
/// sealed with the data key). With [secrets] (the default: the system's
/// secure storage) the security-relevant settings and the user's GIF key
/// are kept out of the file's reach ([GuardedAppSettingsStore]); `null`
/// gives the bare file (tests, previews).
AppSettingsStore buildZenAppSettingsStoreForDirectory(
  Directory supportDirectory, {
  BinaryCodec? codec,
  AppSecurityCredentialsStore? secrets = const SecureStorageCredentialsStore(),
}) {
  final Directory settingsDirectory = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}settings',
  );
  final FileAppSettingsStore file = FileAppSettingsStore(
    store: FileBinaryStore(settingsDirectory, codec: codec),
  );
  return secrets == null
      ? file
      : GuardedAppSettingsStore(inner: file, secrets: secrets);
}

ZenPersistentStores buildZenPersistentStoresForDirectory(
  Directory supportDirectory, {
  BinaryCodec? codec,
  BinaryPayloadProtector? dataProtector,
  AppSettingsStore? appSettingsStore,
}) {
  final Directory dataDirectory = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}data',
  );
  final FileBinaryStore binaryStore = FileBinaryStore(
    dataDirectory,
    codec: codec,
    protector: dataProtector,
  );
  // Leftovers of writes that were killed halfway (A20); best effort.
  unawaited(binaryStore.sweepOrphanTemporaries().catchError((Object _) => 0));
  return ZenPersistentStores(
    signalQueueStore: FileSignalQueueStore(store: binaryStore),
    socialSnapshotStore: FileSocialSnapshotStore(store: binaryStore),
    messageTimelineStore: FileMessageTimelineStore(store: binaryStore),
    attachmentTransferStore: FileAttachmentTransferStore(store: binaryStore),
    // Production passes the bootstrap's (guarded) settings store; this
    // fallback serves tests and previews.
    appSettingsStore:
        appSettingsStore ??
        buildZenAppSettingsStoreForDirectory(
          supportDirectory,
          codec: codec,
          secrets: null,
        ),
    userProfileStore: FileUserProfileStore(store: binaryStore),
    groupStore: FileGroupStore(store: binaryStore),
    relayStateStore: FileRelayStateStore(store: binaryStore),
    ledgerDisk: FileLedgerDisk(binaryStore),
  );
}
