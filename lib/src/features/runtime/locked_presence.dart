import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/friend_level_lookup.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// What the locked background receiver may tell a friend in a `pong`
/// about this phone: that Zen is in the background ("w tle"), and when it
/// was last open on the screen ([lastOpenedAtMillis], 0 when the person
/// keeps it to themselves) — only to the friends who may see presence
/// ([shownTo]: normalized addresses, a friend's other devices included).
/// To anyone else a pong says only that the phone answers. Sealed with the
/// background key, like the other kits; the app writes it whenever Zen
/// leaves the screen ([writeLockedPresenceKit]).
@immutable
final class LockedPresenceKit {
  const LockedPresenceKit({
    this.shownTo = const <String>{},
    this.lastOpenedAtMillis = 0,
  });

  final Set<String> shownTo;
  final int lastOpenedAtMillis;

  /// The most addresses a kit holds.
  static const int maxEntries = 2000;

  /// The presence fields of a pong to [from] at [nowMillis]; empty when
  /// [from] may not see them.
  Map<String, dynamic> pongFields(String from, int nowMillis) {
    if (!shownTo.contains(PeerShareCodec.normalizeAddress(from))) {
      return const <String, dynamic>{};
    }
    return presenceFields(
      own: PeerPresence.background,
      openedAgo: lastOpenedAtMillis <= 0
          ? null
          : Duration(
              milliseconds: nowMillis > lastOpenedAtMillis
                  ? nowMillis - lastOpenedAtMillis
                  : 0,
            ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    if (lastOpenedAtMillis > 0) 'o': lastOpenedAtMillis,
    'to': (shownTo.toList()..sort()),
  };

  static LockedPresenceKit? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) {
      return null;
    }
    final Object? o = json['o'];
    final Object? to = json['to'];
    return LockedPresenceKit(
      lastOpenedAtMillis: o is int && o > 0 ? o : 0,
      shownTo: <String>{
        if (to is List)
          for (final Object? a in to.take(maxEntries))
            if (a is String && a.isNotEmpty && a.length <= 300) a,
      },
    );
  }
}

/// The kit for [state]: every accepted friend [levelOf] lets see presence
/// ([presenceVisibleTo]), with their other devices ([directory]), and
/// [lastOpenedAt] unless the person keeps it to themselves
/// ([showLastOpened]).
LockedPresenceKit lockedPresenceKitOf(
  SocialHubState state, {
  required FriendLevel? Function(String address) levelOf,
  required bool showLastOpened,
  required DateTime lastOpenedAt,
  AccountDeviceDirectory? directory,
}) {
  String normal(String address) => PeerShareCodec.normalizeAddress(address);
  final Set<String> shownTo = <String>{};
  for (final FriendProfile friend in state.acceptedFriends) {
    if (!presenceVisibleTo(levelOf(friend.address))) {
      continue;
    }
    final String? account = directory?.accountOf(friend.address);
    shownTo.addAll(
      <String>[
        normal(friend.address),
        if (directory != null && account != null)
          ...directory.addressesOf(account).map(normal),
      ]..removeWhere((String a) => a.isEmpty),
    );
  }
  return LockedPresenceKit(
    shownTo: shownTo.length > LockedPresenceKit.maxEntries
        ? shownTo.take(LockedPresenceKit.maxEntries).toSet()
        : shownTo,
    lastOpenedAtMillis: showLastOpened
        ? lastOpenedAt.millisecondsSinceEpoch
        : 0,
  );
}

/// Where the presence kit is kept.
BackgroundKitFile lockedPresenceKitFile({
  required Future<Directory> Function() supportDirectory,
  required AppSecurityCredentialsStore credentials,
  bool createKey = false,
}) => BackgroundKitFile(
  supportDirectory: supportDirectory,
  credentials: credentials,
  storageKey: 'background/presence-kit',
  fileName: 'presence-kit.zenbg',
  createKey: createKey,
);

/// Writes one after another (the service reads the last one whole).
Future<void> _writing = Future<void>.value();

/// Android: writes the [LockedPresenceKit] as of now, Zen having left the
/// screen at [lastOpenedAt] — only once the friends were read, so a kit
/// without them never replaces the stored one. The service hands friends
/// this in its pongs once it receives in the app's place.
Future<void> writeLockedPresenceKit(Ref ref, {required DateTime lastOpenedAt}) {
  if (!ref.read(androidBackgroundRuntimeBridgeEnabledProvider)) {
    return Future<void>.value();
  }
  final SocialHubController hub = ref.read(
    socialHubControllerProvider.notifier,
  );
  final AppSecurityService security = ref.read(appSecurityServiceProvider);
  final SocialHubState state = ref.read(socialHubControllerProvider);
  // Also as the app locks: the friends stay read, and the kit is sealed
  // with the background key, not the master key.
  if (!hub.isHydrated || state.snapshotUnreadable) {
    return Future<void>.value();
  }
  final FriendLevelLookup levels = ref.read(friendLevelLookupProvider);
  final LockedPresenceKit kit = lockedPresenceKitOf(
    state,
    levelOf: levels.of,
    showLastOpened: ref.read(appSettingsControllerProvider).showLastOpened,
    lastOpenedAt: lastOpenedAt,
    directory: ref.read(accountDirectoryHolderProvider).directory,
  );
  final Map<String, dynamic> json = kit.toJson();
  final SupportDirectoryResolver support = ref.read(
    supportDirectoryResolverProvider,
  );
  final AppSecurityCredentialsStore credentials = security.credentialsStore;
  final Future<void> written = _writing.then(
    (_) => lockedPresenceKitFile(
      supportDirectory: support,
      credentials: credentials,
      createKey: true,
    ).write(json),
  );
  // A failed write does not hold up the next one.
  _writing = written.catchError((Object _) {});
  return written;
}
