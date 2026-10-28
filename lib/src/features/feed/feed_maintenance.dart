import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/calls/call_safety_cues.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_mentions.dart';
import 'package:zen/src/features/feed/post_notifier.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
import 'package:zen/src/features/feed/reaction_notifier.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/settings/storage_breakdown.dart';
import 'package:zen/src/features/settings/storage_limit_warning.dart';
import 'package:zen/src/features/shell/shell_location.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// What the wall does in the background: notifications about reactions to
/// your posts, about friends' new posts and about mentions, posts passed on
/// beyond friends and the storage limits.
final class FeedMaintenance {
  FeedMaintenance({
    required this.node,
    required this.notifier,
    this.posts,
    this.reach,
    this.mentions,
    this.feedLimitBytes,
    this.zenLimitMb,
    this.zenBytesOf,
    this.onZenLimit,
  });

  final LedgerNode node;
  final ReactionSystemNotifier notifier;

  /// Announces friends' new posts.
  final FriendPostNotifier? posts;

  /// Passes posts on beyond friends and fetches those passed on to us.
  final PostReachService? reach;

  /// Tells people of their mentions in this account's posts and comments,
  /// and this person of theirs.
  final PostMentionService? mentions;

  /// What other people's posts may take together (the limit the person
  /// set for them); `null` or `0` = no limit of their own.
  final int Function()? feedLimitBytes;

  /// The limit the person set for all of Zen, in MB; `0` = no limit.
  final int Function()? zenLimitMb;

  /// Measures all of Zen ([usage]: what other people's posts take of it);
  /// `null` when it cannot be measured.
  final Future<int?> Function(StorageUsage usage)? zenBytesOf;

  /// Told after each round what it found for the limit of all of Zen
  /// (`null`: Zen fits it, or there is no limit).
  final void Function(StorageLimitWarning? warning)? onZenLimit;

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
    posts?.start();
    mentions?.start();
    unawaitedLogged(
      reach?.start() ?? Future<void>.value(),
      context: 'Posty dalszych znajomych',
    );
    _first ??= Timer(
      const Duration(seconds: 45),
      () => unawaited(enforceLimits()),
    );
  }

  /// Once a minute from the app's clock: the limits are applied every
  /// [kStorageRetentionInterval].
  void minute(int minute) {
    reach?.minute(minute);
    posts?.minute();
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
      final int limitMb = zenLimitMb?.call() ?? 0;
      final RetentionResult result = await enforceStorageLimits(
        node,
        held: reach?.heldEntries ?? const <LogEntry>[],
        feedLimitBytes: _feedLimit(),
        zenLimitBytes: limitMb > 0 ? limitMb * 1024 * 1024 : null,
        zenBytesOf: zenBytesOf,
      );
      cleaned = RetentionResult(
        expiredFiles: cleaned.expiredFiles + result.expiredFiles,
        expiredBytes: cleaned.expiredBytes + result.expiredBytes,
        limitFiles: cleaned.limitFiles + result.limitFiles,
        limitBytes: cleaned.limitBytes + result.limitBytes,
        totalFiles: cleaned.totalFiles + result.totalFiles,
        totalBytes: cleaned.totalBytes + result.totalBytes,
      );
      if (result.zenBytes != null) {
        onZenLimit?.call(
          StorageLimitWarning(
            limitMb: limitMb,
            deletedFiles: result.totalFiles,
            deletedBytes: result.totalBytes,
            stillOverBytes: result.stillOverTotalBytes,
          ),
        );
      } else if (limitMb <= 0) {
        onZenLimit?.call(null);
      }
      return result;
    } on Object catch (error, stackTrace) {
      logZenError('Applying the storage limits failed', error, stackTrace);
      return const RetentionResult();
    } finally {
      _enforcing = false;
    }
  }

  int? _feedLimit() {
    final int bytes = feedLimitBytes?.call() ?? 0;
    return bytes > 0 ? bytes : null;
  }

  void dispose() {
    _disposed = true;
    _first?.cancel();
    notifier.dispose();
    posts?.dispose();
    mentions?.dispose();
  }
}

/// The wall's background duties, or `null` while the ledger is off.
final Provider<FeedMaintenance?>
feedMaintenanceProvider = Provider<FeedMaintenance?>((Ref ref) {
  final LedgerNode? node = ref.watch(ledgerNodeProvider);
  if (node == null) {
    return null;
  }
  String nameOf(String address) {
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final FriendProfile? friend = social.friendByAddress(address);
    return friend == null ? address : social.nameFor(friend);
  }

  Future<void> notify(RuntimeSystemNotification notification) async {
    await ref.read(runtimeSystemNotificationServiceProvider).show(notification);
  }

  bool focused() => ref.read(socialHubControllerProvider).lifecycle.isFocused;

  // While this device shares its screen in a call, never more than who
  // wrote (as for messages).
  NotificationPrivacy shared(NotificationPrivacy level) =>
      screenShareHidesNotifications.value
      ? level.atLeast(NotificationPrivacy.senderOnly)
      : level;

  NotificationPrivacy friendPrivacy(String address) => shared(
    ref
        .read(socialHubControllerProvider)
        .notificationPrivacyFor(
          address,
          global: ref.read(appSettingsControllerProvider).notificationPrivacy,
        ),
  );
  final PostReachService? reach = ref.watch(postReachProvider);

  // Whether Zen fit its limit since it was last told of it: then the same
  // news counts as new.
  bool fitSince = false;
  void zenLimit(StorageLimitWarning? warning) {
    ref.read(storageLimitWarningProvider.notifier).report(warning);
    if (warning == null || !warning.matters) {
      fitSince = true;
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!storageLimitNoticeDue(
      ref.read(socialHubControllerProvider).inbox,
      warning,
      nowMillis: now,
      fitSince: fitSince,
    )) {
      return;
    }
    fitSince = false;
    unawaitedLogged(
      ref
          .read(socialHubControllerProvider.notifier)
          .putInboxEntry(storageLimitInboxEntry(warning, nowMillis: now)),
      context: 'Powiadomienie o limicie miejsca',
    );
  }

  final FeedMaintenance maintenance = FeedMaintenance(
    node: node,
    reach: reach,
    feedLimitBytes: () =>
        ref.read(appSettingsControllerProvider).feedLimitMb * 1024 * 1024,
    zenLimitMb: () => ref.read(appSettingsControllerProvider).inboxLimitMb,
    zenBytesOf: (StorageUsage usage) async {
      try {
        final StorageBreakdown measured = await measureAccountStorage(
          support: await ref.read(supportDirectoryResolverProvider)(),
          usage: usage,
        );
        return measured.totalBytes;
      } on Object catch (error) {
        logZenWarning('Measuring the storage failed: $error');
        return null;
      }
    },
    onZenLimit: zenLimit,
    mentions: PostMentionService(
      node: node,
      nameOf: nameOf,
      notify: notify,
      addToInbox: (InboxEntry entry) =>
          ref.read(socialHubControllerProvider.notifier).putInboxEntry(entry),
      shouldNotify: () => !focused(),
      privacyOf: friendPrivacy,
      privacy: () =>
          shared(ref.read(appSettingsControllerProvider).notificationPrivacy),
      // On a friend list shared with this phone: a friend of a friend.
      friendOfFriend: (String address) {
        final String a = PeerShareCodec.normalizeAddress(address);
        for (final Map<String, String> list
            in ref.read(meetServiceProvider).book.friendLists.values) {
          final String? name = list[a];
          if (name != null) {
            return name;
          }
        }
        return null;
      },
      held: reach,
    ),
    notifier: ReactionSystemNotifier(
      node: node,
      nameOf: nameOf,
      notify: notify,
      shouldNotify: () => !focused(),
    ),
    posts: FriendPostNotifier(
      node: node,
      nameOf: nameOf,
      notify: notify,
      dismissSlot: (String slot) =>
          ref.read(runtimeSystemNotificationServiceProvider).dismissSlot(slot),
      addToInbox: (InboxEntry entry) =>
          ref.read(socialHubControllerProvider.notifier).putInboxEntry(entry),
      shouldNotify: () => !focused(),
      lookingAtFeed: () {
        final ShellLocation at = ref.read(shellLocationProvider).current;
        return focused() && at.tab == 'feed' && at.place == null;
      },
      announces: (String address) =>
          ref.read(appSettingsControllerProvider).announcesPostsOf(address),
      announcesFar: () =>
          !ref.read(appSettingsControllerProvider).mutes(NoticeKind.farPost),
      // Passed on from friends of friends, as far as the Tablica looks.
      farPosts: () => <FeedPost>[
        for (final FeedPost p in buildFeed(node, nameOf: nameOf, held: reach))
          if (!p.isOwn &&
              p.degree > 1 &&
              p.degree <= (reach?.depth ?? kDefaultFeedDepth))
            p,
      ],
      privacyOf: friendPrivacy,
      privacy: () =>
          shared(ref.read(appSettingsControllerProvider).notificationPrivacy),
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
      // Measured again when a round deleted for the limit of all of Zen.
      ref.watch(storageLimitWarningProvider);
      await maintenance.node.start();
      return StorageReport(
        usage: storageUsageOf(
          storedMediaOf(
            maintenance.node,
            held: maintenance.reach?.heldEntries ?? const <LogEntry>[],
          ),
        ),
        cleaned: maintenance.cleaned,
      );
    });
