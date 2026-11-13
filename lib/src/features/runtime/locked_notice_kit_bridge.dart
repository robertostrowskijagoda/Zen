import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/multi/desktop_background.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// What in [state] goes into the [LockedNoticeKit] (to write it again only
/// when that changes).
String lockedNoticeKitSignature(SocialHubState state) {
  final List<String> parts = <String>[
    for (final FriendProfile friend in state.friends.values)
      'f:${friend.status.name}:${friend.address}:${state.nameFor(friend)}',
    for (final MapEntry<String, String> e in state.peerAppVersions.entries)
      'v:${e.key}:${e.value}',
    for (final String address in state.book.removedAddresses) 'x:$address',
    for (final GroupProfile group in state.groups.values)
      'g:${group.id}:${group.isInvitePending}:${group.name}:'
          '${group.createdById}:${speaksInGroup(group, group.createdById)}:'
          '${group.memberAddresses.join(',')}',
    for (final MapEntry<String, NotificationPrivacy> e
        in state.notificationPrivacy.entries)
      'n:${e.key}:${e.value.name}',
    for (final MapEntry<String, int> e in state.mutedUntil.entries)
      'm:${e.key}:${e.value}',
    for (final MapEntry<String, bool> e in state.groupNotifyAll.entries)
      'a:${e.key}:${e.value}',
  ]..sort();
  return parts.join('|');
}

/// Keeps the [LockedNoticeKit] of the account open in the app in step,
/// wherever a background runner reads it: on Android (the service runs the
/// default account and the additional ones, each from the kit in its own
/// folder), on an iPhone, and on a computer while this account receives in
/// the background (its tray node). It holds the notification privacy
/// level, the conversations' own levels and the names the locked
/// background receiver may show in a message's notice, the notification
/// switches (the kinds of news that are off, the notification sounds) and
/// who speaks in which group. Written again whenever any of it changes,
/// when the app leaves the screen, and every [_refreshEvery] (a friend's
/// devices come from the ledger, which says nothing when it learns one);
/// only while unlocked and once the friends were read, so a kit without
/// them never replaces the stored one. An additional account's kit goes
/// into that account's folder, sealed with its background key: nothing of
/// it is written where the default account's files are.
class LockedNoticeKitBridge extends ConsumerStatefulWidget {
  const LockedNoticeKitBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LockedNoticeKitBridge> createState() =>
      _LockedNoticeKitBridgeState();
}

class _LockedNoticeKitBridgeState extends ConsumerState<LockedNoticeKitBridge> {
  static const Duration _refreshEvery = Duration(minutes: 15);

  String? _written;
  Future<void> _writing = Future<void>.value();
  Timer? _refresh;

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(androidBackgroundRuntimeBridgeEnabledProvider) &&
        !ref.watch(iosBackgroundBridgeEnabledProvider) &&
        !ref.watch(desktopReceivesInBackgroundProvider)) {
      _refresh?.cancel();
      _refresh = null;
      // Turned on again later: written then, whatever was written before.
      _written = null;
      return widget.child;
    }
    _refresh ??= Timer.periodic(_refreshEvery, (_) {
      if (mounted) {
        _write();
      }
    });
    ref.watch(
      runtimeNodeSnapshotProvider.select(
        (RuntimeTransportSnapshot snapshot) => snapshot.localAddress,
      ),
    );
    ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.lifecycle.visibility,
      ),
    );
    ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings settings) => settings.notificationPrivacy,
      ),
    );
    ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings settings) => (
          settings.notificationSounds,
          settings.mutedNotices,
          settings.postNotifications,
          settings.inviteToken,
          settings.noticePrivacy,
          settings.groupMentionsOnly,
        ),
      ),
    );
    ref.watch(socialHubControllerProvider.select(lockedNoticeKitSignature));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _write();
      }
    });
    return widget.child;
  }

  void _write() {
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final SocialHubState state = ref.read(socialHubControllerProvider);
    if (isSecurityBlockingUi(security) ||
        !hub.isHydrated ||
        state.snapshotUnreadable) {
      return;
    }
    final LockedNoticeKit kit = lockedNoticeKitFor(
      state,
      settings: ref.read(appSettingsControllerProvider),
      directory: ref.read(accountDirectoryHolderProvider).directory,
      self: ref.read(runtimeNodeSnapshotProvider).localAddress,
    );
    final Map<String, dynamic> json = kit.toJson();
    final String signature = jsonEncode(json);
    if (signature == _written) {
      return;
    }
    _written = signature;
    final SupportDirectoryResolver support = ref.read(
      supportDirectoryResolverProvider,
    );
    final AppSecurityCredentialsStore credentials = security.credentialsStore;
    _writing = _writing.then((_) async {
      try {
        await lockedNoticeKitFile(
          supportDirectory: support,
          credentials: credentials,
          createKey: true,
        ).write(json);
      } on Object catch (error, stackTrace) {
        _written = null;
        logZenError('Writing the notice kit failed', error, stackTrace);
      }
    });
  }
}
