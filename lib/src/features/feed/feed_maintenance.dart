import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/feed/reaction_notifier.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// What the wall does in the background: system notifications about
/// reactions to your posts and the storage limits.
final class FeedMaintenance {
  FeedMaintenance({required this.node, required this.notifier});

  final LedgerNode node;
  final ReactionSystemNotifier notifier;

  Timer? _first;

  /// Everything the limits deleted since the app started (the page of the
  /// storage limits shows it).
  RetentionResult cleaned = const RetentionResult();
  bool _enforcing = false;
  bool _disposed = false;

  /// Starts watching for reactions and applies the storage limits once,
  /// shortly after the start (the ledger is read from disk by then).
  void start() {
    notifier.start();
    _first ??= Timer(
      const Duration(seconds: 45),
      () => unawaited(enforceLimits()),
    );
  }

  /// Once a minute from the app's clock: the limits are applied every
  /// [kStorageRetentionInterval].
  void minute(int minute) {
    if (minute % kStorageRetentionInterval.inMinutes == 0) {
      unawaited(enforceLimits());
    }
  }

  /// Deletes the files over the storage limits now.
  Future<RetentionResult> enforceLimits() async {
    if (_enforcing || _disposed) {
      return const RetentionResult();
    }
    _enforcing = true;
    try {
      final RetentionResult result = await enforceStorageLimits(node);
      cleaned = RetentionResult(
        expiredFiles: cleaned.expiredFiles + result.expiredFiles,
        expiredBytes: cleaned.expiredBytes + result.expiredBytes,
        limitFiles: cleaned.limitFiles + result.limitFiles,
        limitBytes: cleaned.limitBytes + result.limitBytes,
      );
      return result;
    } on Object catch (error, stackTrace) {
      logZenError('Applying the storage limits failed', error, stackTrace);
      return const RetentionResult();
    } finally {
      _enforcing = false;
    }
  }

  void dispose() {
    _disposed = true;
    _first?.cancel();
    notifier.dispose();
  }
}

/// The wall's background duties, or `null` while the ledger is off.
final Provider<FeedMaintenance?> feedMaintenanceProvider =
    Provider<FeedMaintenance?>((Ref ref) {
      final LedgerNode? node = ref.watch(ledgerNodeProvider);
      if (node == null) {
        return null;
      }
      final FeedMaintenance maintenance = FeedMaintenance(
        node: node,
        notifier: ReactionSystemNotifier(
          node: node,
          nameOf: (String address) {
            final SocialHubState social = ref.read(socialHubControllerProvider);
            final FriendProfile? friend = social.friendByAddress(address);
            return friend == null ? address : social.nameFor(friend);
          },
          notify: (RuntimeSystemNotification notification) async {
            await ref
                .read(runtimeSystemNotificationServiceProvider)
                .show(notification);
          },
          shouldNotify: () =>
              !ref.read(socialHubControllerProvider).lifecycle.isFocused,
        ),
      );
      ref.onDispose(maintenance.dispose);
      return maintenance;
    });

/// How full the limits are, and what they deleted since the app started.
final class StorageReport {
  const StorageReport({required this.usage, required this.cleaned});

  final StorageUsage usage;
  final RetentionResult cleaned;
}

/// The storage report, or `null` while the ledger is off.
final FutureProvider<StorageReport?> storageReportProvider =
    FutureProvider.autoDispose<StorageReport?>((Ref ref) async {
      final FeedMaintenance? maintenance = ref.watch(feedMaintenanceProvider);
      if (maintenance == null) {
        return null;
      }
      await maintenance.node.start();
      return StorageReport(
        usage: storageUsageOf(storedMediaOf(maintenance.node)),
        cleaned: maintenance.cleaned,
      );
    });
