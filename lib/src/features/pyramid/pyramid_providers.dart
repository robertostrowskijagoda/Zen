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
import 'package:zen/src/features/pyramid/pyramid_device_sync.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// The pyramid, its power and money (§20–24), and crisis mode (§28.1).
final Provider<PyramidService> pyramidServiceProvider =
    Provider<PyramidService>((Ref ref) {
      final MeetService meet = ref.watch(meetServiceProvider);
      final NearbyService nearby = ref.watch(nearbyServiceProvider);
      final PyramidService pyramid = PyramidService(
        host: appEventHost(ref, meet),
        disk: ref.read(ledgerDiskProvider),
        // Crisis announcements hop from phone to phone over Bluetooth.
        crisisBroadcast: nearby.waveAll,
        // Friends of friends get their own market prices (§24).
        friendsOf: (String f) => meet.book.friendsOf(f),
        // Admission needs the level "Znajomy" or above (§20.2); without
        // the ledger the level is unknown and only friendship counts.
        friendLevelOf: (String a) =>
            ref.read(ledgerNodeProvider)?.levelOf(a) ?? FriendLevel.friend,
        // Signed "met in person" attestations (§6.2) count for referenda
        // (§20.6).
        metInPerson: () =>
            ref.read(ledgerNodeProvider)?.metAddresses() ?? const <String>[],
        // The account's other devices share the pyramid key (§6.1).
        otherDevices: () {
          final LedgerNode? node = ref.read(ledgerNodeProvider);
          return node != null && node.isReady
              ? node.siblingAddresses
              : const <String>[];
        },
        // A reshare on order (§24) goes out as this person's own reshare.
        resharePost: (Map<String, dynamic> post) =>
            reshareOrderedPost(ref.read(ledgerNodeProvider), post),
        ownPublicPosts: () =>
            ownPublicPostEntries(ref.read(ledgerNodeProvider)),
      );
      // The same pyramid on every device of the account (§6.3).
      final LedgerNode? node = ref.read(ledgerNodeProvider);
      final PyramidDeviceSync? devices = node == null
          ? null
          : PyramidDeviceSync(node: node, pyramid: pyramid);
      unawaitedLogged(
        pyramid.load().then((_) async {
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

/// Shares [post] (a signed public post, ordered on the market, §24) with
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
        p.entry!.toJson(),
  ];
}
