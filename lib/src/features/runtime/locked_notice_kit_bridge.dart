import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
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
      'f:${friend.status.name}:${friend.address}:${friend.displayLabel}',
    for (final GroupProfile group in state.groups.values)
      'g:${group.id}:${group.isInvitePending}:${group.name}:'
          '${group.memberAddresses.join(',')}',
    for (final MapEntry<String, NotificationPrivacy> e
        in state.notificationPrivacy.entries)
      'n:${e.key}:${e.value.name}',
  ]..sort();
  return parts.join('|');
}

/// Keeps the [LockedNoticeKit] in step on Android and on an iPhone while
/// the app is unlocked: the notification privacy level, the conversations'
/// own levels and the names the locked background receiver may show in a
/// message's notice. Written again whenever any of it changes; only once the friends
/// were read, so a kit without them never replaces the stored one.
class LockedNoticeKitBridge extends ConsumerStatefulWidget {
  const LockedNoticeKitBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LockedNoticeKitBridge> createState() =>
      _LockedNoticeKitBridgeState();
}

class _LockedNoticeKitBridgeState extends ConsumerState<LockedNoticeKitBridge> {
  String? _written;
  Future<void> _writing = Future<void>.value();

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(androidBackgroundRuntimeBridgeEnabledProvider) &&
        !ref.watch(iosBackgroundBridgeEnabledProvider)) {
      return widget.child;
    }
    ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings settings) => settings.notificationPrivacy,
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
    final LockedNoticeKit kit = lockedNoticeKitOf(
      state,
      privacy: ref.read(appSettingsControllerProvider).notificationPrivacy,
      directory: ref.read(accountDirectoryHolderProvider).directory,
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
