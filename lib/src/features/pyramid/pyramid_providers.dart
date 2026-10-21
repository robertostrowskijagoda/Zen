import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/pyramid/pyramid_cell_chat.dart';
import 'package:zen/src/features/pyramid/pyramid_device_sync.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// The pyramid, its power and money, and crisis mode.
final Provider<PyramidService> pyramidServiceProvider =
    Provider<PyramidService>((Ref ref) {
      final MeetService meet = ref.watch(meetServiceProvider);
      final NearbyService nearby = ref.watch(nearbyServiceProvider);
      final PyramidService pyramid = PyramidService(
        host: appEventHost(ref, meet),
        disk: ref.read(ledgerDiskProvider),
        // Crisis announcements hop from phone to phone over Bluetooth.
        crisisBroadcast: nearby.waveAll,
        // Friends of friends get their own market prices.
        friendsOf: (String f) => meet.book.friendsOf(f),
        // Admission needs the level "Znajomy" or above; without
        // the ledger the level is unknown and only friendship counts.
        friendLevelOf: (String a) =>
            ref.read(ledgerNodeProvider)?.levelOf(a) ?? FriendLevel.friend,
        // The account's other devices share the pyramid key.
        otherDevices: () {
          final LedgerNode? node = ref.read(ledgerNodeProvider);
          return node != null && node.isReady
              ? node.siblingAddresses
              : const <String>[];
        },
        // A reshare on order goes out as this person's own reshare.
        resharePost: (Map<String, dynamic> post) =>
            reshareOrderedPost(ref.read(ledgerNodeProvider), post),
        ownPublicPosts: () =>
            ownPublicPostEntries(ref.read(ledgerNodeProvider)),
        // National sections: read by everyone whose profile shows
        // the nationality, so members pass them on to such friends.
        nationalitiesOf: (String address) {
          final LedgerNode? node = ref.read(ledgerNodeProvider);
          if (node == null || !node.isReady) {
            return const <String>[];
          }
          final String? account = node.knownAccountOf(address);
          return account == null
              ? const <String>[]
              : readProfile(node, account)?.nationalities ?? const <String>[];
        },
        myNationalities: () =>
            ref.read(userProfileControllerProvider).nationalities,
        // "Kraj" outside the pyramid without a nationality in the profile.
        phoneRegion: () => PlatformDispatcher.instance.locale.countryCode,
      );
      // The same pyramid on every device of the account.
      final LedgerNode? node = ref.read(ledgerNodeProvider);
      final PyramidDeviceSync? devices = node == null
          ? null
          : PyramidDeviceSync(node: node, pyramid: pyramid);
      // A group chat in Chats for each of this person's cells.
      final PyramidCellChats cellChats = PyramidCellChats(
        pyramid: pyramid,
        apply: (Map<String, PyrCellChat> chats) async {
          if (!ref.exists(socialHubControllerProvider)) {
            return false;
          }
          await ref
              .read(socialHubControllerProvider.notifier)
              .syncManagedGroups(kPyrCellGroupPrefix, chats);
          return true;
        },
      );
      unawaitedLogged(
        pyramid.load().then((_) async {
          cellChats.start();
          await pyramid.greet();
          await devices?.start();
        }),
        context: 'Odczyt piramidy',
      );
      listenFrames(ref, pyramid.handle, 'Piramida');
      void onWave(Map<dynamic, dynamic> json) => unawaitedLogged(
        pyramid.onCrisisWave(json),
        context: 'Komunikat kryzysowy',
      );
      nearby.otherWaveHandlers.add(onWave);
      ref.onDispose(() {
        cellChats.stop();
        nearby.otherWaveHandlers.remove(onWave);
        unawaitedLogged(
          devices?.stop(),
          context: 'Piramida na urządzeniach konta',
        );
        pyramid.dispose();
      });
      return pyramid;
    });

/// The pyramid's minute (`ZenCore`'s minute, while the app runs): duties
/// every 5 minutes, hello to friends every 3 hours.
void pyramidMinute(PyramidService pyramid, int minute) {
  if (minute % 5 == 0) {
    unawaitedLogged(pyramid.duties(), context: 'Piramida: obowiązki');
  }
  if (minute % 180 == 0) {
    unawaitedLogged(pyramid.greet(), context: 'Piramida: powitanie');
  }
}

/// Shares [post] (a signed public post, ordered on the market) with
/// the friends of the account of [node], as its own reshare. True when it
/// went out.
Future<bool> reshareOrderedPost(
  LedgerNode? node,
  Map<String, dynamic> post,
) async {
  if (node == null || !node.isReady || await marketPostText(post) == null) {
    return false;
  }
  final LogEntry? entry = await verifiedEntry(post);
  if (entry == null) {
    return false;
  }
  try {
    await node.publish(
      kReshareKind,
      reshareBody(
        entry,
        authorProfile: latestProfileEntry(node, entry.account),
      ),
    );
    return true;
  } on Object catch (error, stack) {
    logZenError('Udostępnienie na zamówienie', error, stack);
    return false;
  }
}

/// The public posts of the account of [node], newest first, as signed
/// entries (what a reshare can be ordered for).
List<Map<String, dynamic>> ownPublicPostEntries(LedgerNode? node) {
  if (node == null || !node.isReady) {
    return const <Map<String, dynamic>>[];
  }
  return <Map<String, dynamic>>[
    for (final FeedPost p in buildFeed(node, nameOf: (String _) => ''))
      if (p.isOwn && p.audience == Audience.public && p.entry != null)
        p.entry!.toCertifiedJson(),
  ];
}
