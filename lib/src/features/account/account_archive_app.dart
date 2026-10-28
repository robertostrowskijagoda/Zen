import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_collect.dart';
import 'package:zen/src/features/account/account_media.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// A copy of the account is collected from the app's services.
final class AppAccountArchiveSource implements AccountArchiveSource {
  AppAccountArchiveSource(this.ref, this.node);

  final Ref ref;
  final LedgerNode node;

  SocialHubState get _social => ref.read(socialHubControllerProvider);
  SocialHubController get _hub =>
      ref.read(socialHubControllerProvider.notifier);
  UserProfile get _me => ref.read(userProfileControllerProvider);

  @override
  String get account => node.identity.account;

  @override
  Uint8List? get seed => node.identity.accountKey?.seed;

  @override
  LedgerDisk get disk => node.disk;

  @override
  Map<String, dynamic> contacts() => _hub.contactsBackup();

  @override
  Map<String, String> levels() => <String, String>{
    for (final FriendProfile f in _social.friends.values)
      if (f.status == FriendRelationshipStatus.accepted)
        PeerShareCodec.normalizeAddress(f.address): node
            .levelOf(f.address)
            .name,
  };

  @override
  List<String> conversationKeys() => _hub.conversationKeys();

  @override
  Future<List<ChatMessage>> messages(String key) =>
      _hub.conversationMessages(key);

  @override
  Map<String, dynamic> profile() => _me.toJson()
    ..remove('avatarPath')
    ..remove('coverPath');

  @override
  String? get avatarPath => _me.avatarPath;

  @override
  String? get coverPath => _me.coverPath;

  @override
  Map<String, dynamic> settings() =>
      ref.read(appSettingsControllerProvider).toJson();

  @override
  Map<String, dynamic>? pyramid() =>
      ref.read(pyramidServiceProvider).sharedState();

  @override
  Map<String, dynamic> dating() => ref.read(datingServiceProvider).me.toJson();

  /// The household here, or the copy this device keeps of it.
  @override
  Future<Map<String, dynamic>?> household() async =>
      ref.read(neighborsServiceProvider).backupState();

  @override
  Future<Uint8List?> readState(String key) async {
    final Uint8List? here = await node.disk.read(key);
    if (here != null || key != 'chat/strangers') {
      return here;
    }
    final Map<String, Object?>? held = await heldAccountState(
      node.disk,
      kHeldStrangers,
    );
    return held == null
        ? null
        : Uint8List.fromList(utf8.encode(jsonEncode(held)));
  }

  AccountFileReader get _files =>
      AccountFileReader(MediaVault.current ?? ref.read(mediaVaultProvider));

  @override
  Future<Uint8List?> readFileRange(String path, int start, int end) =>
      _files.range(path, start, end);

  @override
  Future<int?> fileSize(String path) => _files.size(path);
}

/// Where a copy goes on this device: the app's services and stores.
final class AppAccountArchiveSink implements AccountArchiveSink {
  AppAccountArchiveSink(this.ref, this.node);

  final Ref ref;
  final LedgerNode node;

  SocialHubController get _hub =>
      ref.read(socialHubControllerProvider.notifier);

  @override
  Future<String?> currentAccount() async =>
      node.isReady ? node.identity.account : null;

  @override
  Future<bool> isFresh() async {
    final SocialHubState state = ref.read(socialHubControllerProvider);
    final bool friends = state.friends.values.any(
      (FriendProfile f) => f.status == FriendRelationshipStatus.accepted,
    );
    return !friends &&
        state.groups.isEmpty &&
        !ref.read(pyramidServiceProvider).isMember;
  }

  @override
  Future<void> adoptAccount(AccountArchive archive) async {
    final Uint8List? seed = archive.seed;
    if (seed == null) {
      throw StateError('A copy without the account key.');
    }
    await LedgerIdentity.adoptAccount(
      node.disk,
      seed,
      deviceName: thisDeviceName,
    );
    if (!archive.scope.contains(AccountScope.pyramid)) {
      // Its place and wallet come back from the pyramid's people.
      await PyramidService.markRecovered(node.disk);
    }
    // Not "Zabezpiecz konto" again: the account was there before.
    await ref
        .read(appSettingsControllerProvider.notifier)
        .setAccountSecureOffered(true);
  }

  @override
  Future<void> writeRaw(
    String key,
    Uint8List value, {
    required bool onlyIfAbsent,
  }) async {
    if (onlyIfAbsent && await node.disk.read(key) != null) {
      return;
    }
    await node.disk.write(key, value);
  }

  @override
  Future<AccountImportSummary> apply(
    AccountArchive archive,
    AccountArchiveBlob? Function(String id) file,
    void Function(int done, int total) progress, {
    required bool merge,
  }) async {
    // Conversations and friends go into what is already loaded.
    await _hub.whenHydrated;
    final int total = 8 + archive.messageCount;
    int done = 0;
    void step() => progress(++done, total);
    final Map<String, Object?> s = archive.sections;
    int files = 0;
    int bytes = 0;

    final Object? settings = s[CircleBackupSections.settings];
    if (settings is Map<String, dynamic> && !merge) {
      final AppSettingsController controller = ref.read(
        appSettingsControllerProvider.notifier,
      );
      // This device's own settings (its setup, lock, permissions) stay:
      // a setup gone through here is not asked again because of the copy.
      await controller.restoreFromCopy(AppSettings.fromJson(settings));
      // The first start of this device is over either way.
      await controller.setAccountSecureOffered(true);
    }
    step();
    final Object? profile = s[CircleBackupSections.profile];
    if (profile is Map<String, dynamic> && !merge) {
      final UserProfile p = UserProfile.fromJson(profile);
      Future<String?> photo(Object? id, {required bool cover}) async {
        final AccountArchiveBlob? blob = id is String ? file(id) : null;
        if (blob == null) {
          return null;
        }
        // Piece by piece straight into the vault: no plain copy outlives
        // this (not even in the computer's temporary folder).
        final String path;
        try {
          path = await sealIncomingProfileImage(
            MediaVault.current ?? ref.read(mediaVaultProvider),
            blob.chunks(),
            cover: cover,
          );
        } on Object catch (error) {
          logZenWarning('A profile photo of the copy was not taken: $error');
          return null;
        }
        files++;
        bytes += blob.size;
        return path;
      }

      await ref
          .read(userProfileControllerProvider.notifier)
          .updateProfile(
            displayName: profile['displayName'] as String?,
            avatarPreset: p.avatarPreset,
            customStatus: profile['customStatus'] as String?,
            bio: profile['bio'] as String?,
            visibility: p.visibility,
            nationalities: p.nationalities,
            avatarPath: await photo(profile[kAccountAvatarFile], cover: false),
            coverPath: await photo(profile[kAccountCoverFile], cover: true),
          );
    }
    step();
    int friends = 0;
    int groups = 0;
    final Object? contacts = s[CircleBackupSections.contacts];
    if (contacts is Map<String, dynamic>) {
      await _hub.importContactsBackup(contacts);
      friends = (contacts['friends'] as List?)?.length ?? 0;
      groups = (contacts['groups'] as List?)?.length ?? 0;
    }
    step();
    final Object? levels = s[CircleBackupSections.levels];
    if (levels is Map) {
      for (final MapEntry<dynamic, dynamic> e in levels.entries) {
        final FriendLevel? level = FriendLevel.values
            .where((FriendLevel l) => l.name == e.value)
            .firstOrNull;
        if (e.key is String && level != null) {
          await node.setLevel(e.key as String, level);
        }
      }
    }
    step();
    final Object? pyramid = s[CircleBackupSections.pyramid];
    if (pyramid is Map<String, dynamic>) {
      await ref.read(pyramidServiceProvider).mergeFromOwnDevice(pyramid);
    }
    step();
    final Object? household = s[CircleBackupSections.household];
    if (household is Map<String, dynamic>) {
      await ref.read(neighborsServiceProvider).restoreFromBackup(household);
    }
    step();
    final Object? dating = s[CircleBackupSections.dating];
    if (dating is Map<String, dynamic>) {
      final DatingService service = ref.read(datingServiceProvider);
      if (!service.me.complete) {
        final MyDating from = MyDating.fromJson(dating);
        await service.saveMine((MyDating me) {
          restoreDatingProfile(me, from);
          me.photos
            ..clear()
            ..addAll(from.photos);
        });
      }
    }
    step();
    for (final MapEntry<String, List<Map<String, dynamic>>> c
        in archive.chats.entries) {
      for (final Map<String, dynamic> json in c.value) {
        final ChatMessage? m = chatMessageFromSync(json);
        if (m != null) {
          final Object? id = json['af'];
          final AccountArchiveBlob? blob = id is String ? file(id) : null;
          String? stored;
          if (blob != null) {
            try {
              // Into the media vault piece by piece.
              stored = await ref
                  .read(mediaVaultProvider)
                  .putStream(blob.size, blob.chunks());
              files++;
              bytes += blob.size;
            } on Object catch (error) {
              logZenWarning('A file of the copy was not taken: $error');
            }
          }
          await _hub.importSyncedMessage(
            c.key,
            stored == null ? chatMessageWithoutFile(m) : m,
            storedPath: stored,
          );
        }
        step();
      }
    }
    step();
    return AccountImportSummary(
      friends: friends,
      groups: groups,
      conversations: archive.chats.length,
      messages: archive.messageCount,
      files: files,
      bytes: bytes,
      parts: archive.scope,
    );
  }

  @override
  Future<void> restart({Future<void> Function()? whileStopped}) async {
    // The same account again, on the states now on disk: it stays open
    // (no second lock screen).
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final ZenCore core = ref.read(zenCoreProvider);
    final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
    final ZenAccountHost host = ref.read(zenAccountHostProvider);
    host.begin();
    try {
      await core.stop();
      await runtime.stop();
      // Its log is written on change and once more when it closes.
      await node.stop();
    } on Object catch (error, stackTrace) {
      logZenError('Stopping before a restart failed', error, stackTrace);
    }
    try {
      await whileStopped?.call();
    } finally {
      host.request(
        ZenAccountOpening(
          scope: ZenAccounts.current,
          security: security.isUnlocked ? security : null,
        ),
      );
    }
  }
}

/// Builds a copy of the account on this device ([buildAccountArchive]).
typedef AccountArchiveCollector =
    Future<AccountArchiveBuild> Function(
      Set<AccountScope> scope, {
      bool measureOnly,
    });

/// The collector of this account's copies; null while there is no account.
final Provider<AccountArchiveCollector?> accountArchiveCollectorProvider =
    Provider<AccountArchiveCollector?>((Ref ref) {
      final LedgerNode? node = ref.watch(ledgerNodeProvider);
      if (node == null) {
        return null;
      }
      return (Set<AccountScope> scope, {bool measureOnly = false}) async {
        await node.start();
        return buildAccountArchive(
          AppAccountArchiveSource(ref, node),
          scope,
          measureOnly: measureOnly,
        );
      };
    });

/// Takes copies into this account; null while there is no account.
final Provider<AccountArchiveImporter?> accountArchiveImporterProvider =
    Provider<AccountArchiveImporter?>((Ref ref) {
      final LedgerNode? node = ref.watch(ledgerNodeProvider);
      if (node == null) {
        return null;
      }
      return AccountArchiveImporter(
        sink: AppAccountArchiveSink(ref, node),
        staging: AccountImportStaging(node.disk),
      );
    });

/// After the app started again on a copy: takes in the rest (with its
/// progress) and keeps what came back to show it. Started with the
/// account's services ([start]).
final class AccountImportController extends ChangeNotifier {
  AccountImportController(this._importer, {required this.ready});

  /// The importer, once the account runs (not before: reading it starts
  /// the account's node).
  final AccountArchiveImporter? Function() _importer;

  /// Waits until the account is up (its node started).
  final Future<void> Function() ready;
  bool _started = false;
  bool _disposed = false;

  bool running = false;
  int done = 0;
  int total = 0;
  AccountImportSummary? summary;
  bool failed = false;

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Once per start of the app.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final AccountArchiveImporter? importer = _importer();
    if (importer == null) {
      return;
    }
    try {
      await ready();
      final AccountImportSummary? saved = await importer.staging.takeSummary();
      if (saved != null) {
        summary = saved;
        _changed();
      }
      if (await importer.staging.manifest() == null) {
        return;
      }
      running = true;
      _changed();
      final AccountImportSummary? got = await importer.resume(
        progress: (int d, int t) {
          done = d;
          total = t;
          _changed();
        },
      );
      if (got != null) {
        summary = got;
      }
    } on Object catch (error, stackTrace) {
      logZenError(
        'Taking in the copy of the account failed',
        error,
        stackTrace,
      );
      failed = true;
    } finally {
      running = false;
      _changed();
    }
  }

  void dismiss() {
    summary = null;
    failed = false;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final Provider<AccountImportController> accountImportControllerProvider =
    Provider<AccountImportController>((Ref ref) {
      final AccountImportController controller = AccountImportController(
        () => ref.read(accountArchiveImporterProvider),
        ready: () async => ref.read(ledgerNodeProvider)?.start(),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
