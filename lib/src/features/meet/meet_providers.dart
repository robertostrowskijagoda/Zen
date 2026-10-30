import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/desktop_nearby_radio.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/table/table_service.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/local_links_controller.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// [MeetHost] over the app's providers.
final class AppMeetHost implements MeetHost {
  AppMeetHost(this.ref);

  final Ref ref;

  SocialHubState get _state => ref.read(socialHubControllerProvider);

  @override
  Future<void> send(String to, Map<String, dynamic> payload) => ref
      .read(signalTransportProvider)
      .send(remoteAddress: to, payload: payload);

  @override
  List<String> friends() => acceptedFriendAddresses(_state);

  @override
  List<String> closeFriends() {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (node == null) {
      return const <String>[];
    }
    return <String>[
      for (final String a in friends())
        if (node.levelOf(a) == FriendLevel.close) a,
    ];
  }

  @override
  bool isFriend(String address) =>
      _state.friendByAddress(address)?.status ==
      FriendRelationshipStatus.accepted;

  @override
  bool isSelf(String address) {
    final String own = ref.read(runtimeNodeSnapshotProvider).localAddress;
    return own.isNotEmpty && PeerShareCodec.addressesEqual(own, address);
  }

  @override
  String nameOf(String address) {
    final FriendProfile? f = _state.friendByAddress(address);
    return f == null ? t('Ktoś') : _state.nameFor(f);
  }

  @override
  Future<void> notify(RuntimeSystemNotification notification) async {
    await ref.read(runtimeSystemNotificationServiceProvider).show(notification);
  }

  @override
  Future<void> dismissNotification(String slotKey) =>
      ref.read(runtimeSystemNotificationServiceProvider).dismissSlot(slotKey);
}

/// Statuses, alarms and nearby keys in the app.
final Provider<MeetService> meetServiceProvider = Provider<MeetService>((
  Ref ref,
) {
  final MeetService service = MeetService(
    host: AppMeetHost(ref),
    store: MeetStore(ref.read(ledgerDiskProvider)),
  );
  Map<String, String> names() {
    final SocialHubState s = ref.read(socialHubControllerProvider);
    return <String, String>{
      for (final FriendProfile f in s.acceptedFriends) f.address: s.nameFor(f),
    };
  }

  service.friendNames = names;
  // An open gate shows the friend list too (read when asked, so the
  // statuses alone do not start the introductions).
  service.gateOpenTo = (String friend) =>
      ref.read(introServiceProvider).gateOpenTo(friend);
  // Weak acquaintances get no friend list and statuses; after a
  // level change [setFriendLevel] sends both again.
  service.levelOf = (String a) => ref.read(ledgerNodeProvider)?.levelOf(a);
  // The alarm key's certificate names this device; a friend's must come
  // from the account the ledger knows for them.
  service.ownAddress = () => ref.read(runtimeNodeSnapshotProvider).localAddress;
  service.accountOf = (String a) {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    return node != null && node.isReady ? node.accountOf(a) : null;
  };
  // Friends' device keys travel in the friend list; those of friends'
  // friends are pinned before the first contact.
  service.sessionKeyOf = (String a) =>
      ref.read(ledgerNodeProvider)?.sessionKeyOf(a);
  service.onVouchedKeys = (Map<String, String> keys) =>
      ref.read(runtimeNodeRuntimeProvider).vouchSessionKeys(keys);
  unawaitedLogged(
    service.reload().then((_) async {
      // Before the friends are read there is nothing to send (and an empty
      // list must not be remembered as sent).
      if (names().isEmpty) {
        return;
      }
      await syncNearbySecrets(service);
      await service.shareFriendList(names());
    }),
    context: 'Odczyt spotkań',
  );
  final StreamSubscription<SignalTransportFrame> sub = ref
      .read(signalTransportProvider)
      .frames
      .listen(
        (SignalTransportFrame f) =>
            unawaitedLogged(service.handle(f), context: 'Spotkania'),
      );
  // New friends get the nearby secret (and the current status); a removed
  // friend means a new secret, so they can no longer recognise this phone.
  ref.listen<String>(
    socialHubControllerProvider.select(
      (SocialHubState s) => (acceptedFriendAddresses(s)..sort()).join(','),
    ),
    (String? previous, String next) {
      final Set<String> before = (previous ?? '')
          .split(',')
          .where((String a) => a.isNotEmpty)
          .toSet();
      final Set<String> now = next
          .split(',')
          .where((String a) => a.isNotEmpty)
          .toSet();
      // The friends were just read from disk: nothing changed, it only
      // looks like everybody was added. One digest-checked send, and what
      // came from them before (parked) is handled now (B4).
      final bool firstRead = before.isEmpty;
      final Set<String> added = now.difference(before);
      for (final String a in added) {
        unawaitedLogged(service.replayParked(a), context: 'Ramki od znajomego');
        if (!firstRead) {
          unawaitedLogged(service.shareAlarmKey(a), context: 'Klucz alarmu');
        }
      }
      if (before.difference(now).isNotEmpty) {
        unawaitedLogged(
          service.rotateNearbySecret(),
          context: 'Nowy klucz w pobliżu',
        );
      } else {
        unawaitedLogged(syncNearbySecrets(service), context: 'Klucz w pobliżu');
      }
      // Sent to everybody only when the list changed (the digest), so a new
      // friend gets it once.
      unawaitedLogged(
        service.shareFriendList(names()),
        context: 'Lista znajomych dla znajomych',
      );
      final IntentStatus? mine = service.book.myIntent;
      if (!firstRead && mine != null && mine.activeAt(service.now)) {
        for (final String friend in added) {
          if (service.statusVisibleTo(mine, friend)) {
            unawaitedLogged(
              service.host.send(friend, <String, dynamic>{
                'type': MeetTypes.intent,
                's': mine.toJson(),
              }),
              context: 'Status dla nowego znajomego',
            );
          }
        }
      }
    },
  );
  ref.onDispose(() {
    unawaited(sub.cancel());
    service.dispose();
  });
  return service;
});

final Expando<Future<void>> _keysBeingGiven = Expando<Future<void>>();

/// Gives the nearby secret to friends who do not have it yet (one run at a
/// time: two at once would send it twice).
Future<void> syncNearbySecrets(MeetService service) {
  final Future<void>? running = _keysBeingGiven[service];
  if (running != null) {
    return running;
  }
  final Future<void> run = _syncNearbySecrets(
    service,
  ).whenComplete(() => _keysBeingGiven[service] = null);
  _keysBeingGiven[service] = run;
  return run;
}

Future<void> _syncNearbySecrets(MeetService service) async {
  final Set<String> given = service.book.nearbyGivenTo;
  final List<String> missing = <String>[
    for (final String f in service.host.friends())
      if (!given.contains(PeerShareCodec.normalizeAddress(f))) f,
  ];
  for (final String f in missing) {
    await service.shareNearbySecret(f);
  }
}

/// "W pobliżu" on the shared local network: the node's LAN beacons carry
/// the adverts ([localNearbyProvider]), and what they heard comes with the
/// local links' status.
final class LocalLinksNearbyNetwork implements NearbyNetwork {
  LocalLinksNearbyNetwork({
    required this.nearby,
    required LocalLinksStatus Function() status,
  }) : _status = status;

  final ValueNotifier<LocalNearbyAdverts?> nearby;
  final LocalLinksStatus Function() _status;

  @override
  void update({
    required int firstSlot,
    required Uint8List? adverts,
    required bool looking,
  }) {
    nearby.value = adverts == null && !looking
        ? null
        : LocalNearbyAdverts(
            firstSlot: firstSlot,
            adverts: adverts,
            looking: looking,
          );
  }

  @override
  List<(Uint8List, int)> heard() => <(Uint8List, int)>[
    for (final LocalNearbyHeard h in _status().nearby) (h.advert, h.at),
  ];
}

/// People nearby. Shows this phone (over Bluetooth once it may be used,
/// and on the shared network) unless the person hid it.
final Provider<NearbyService> nearbyServiceProvider = Provider<NearbyService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final SignalTransport transport = ref.read(signalTransportProvider);
  final NearbyService nearby = NearbyService(
    // The phone's own radio, or the computer's Bluetooth.
    radio: platformNearbyRadio(),
    // And the same Wi-Fi.
    network: LocalLinksNearbyNetwork(
      nearby: ref.read(localNearbyProvider),
      status: () => ref.read(localLinksStatusReaderProvider)(),
    ),
    meet: meet,
    ownAddress: () => ref.read(runtimeNodeSnapshotProvider).localAddress,
    sendMesh: (String to, Map<String, dynamic> payload) =>
        transport.send(remoteAddress: to, payload: payload),
    frames: transport.frames,
  )..encounters = ref.watch(encounterLogProvider);
  void onMeet() => nearby.friendsChanged();
  meet.addListener(onMeet);
  // Also while Bluetooth is off or not allowed yet: the network shows the
  // phone at once, the radio once it may (Bluetooth coming on shows it
  // again, see below).
  Future<void> showIfAllowed() async {
    if (meet.book.nearbyVisible) {
      await nearby.setVisible(true);
    }
  }

  // Bluetooth switched back on: this phone is shown again.
  void onBluetooth(bool on) {
    if (on) {
      unawaitedLogged(showIfAllowed(), context: 'W pobliżu: Bluetooth');
    }
  }

  nearby.bluetoothHandlers.add(onBluetooth);
  unawaitedLogged(() async {
    await meet.reload();
    await showIfAllowed();
  }(), context: 'W pobliżu: start');
  ref.onDispose(() {
    meet.removeListener(onMeet);
    nearby.bluetoothHandlers.remove(onBluetooth);
    unawaited(nearby.close());
    nearby.dispose();
  });
  return nearby;
});

/// Whether "W pobliżu" works here: always offered on Android (its screen
/// walks through permissions and Bluetooth), on a computer only with a
/// Bluetooth LE adapter Zen can use.
final FutureProvider<bool> nearbySupportedProvider = FutureProvider<bool>((
  Ref ref,
) async {
  if (!kIsWeb && Platform.isAndroid) {
    return true;
  }
  final Map<Object?, Object?> state = await ref
      .read(nearbyServiceProvider)
      .radio
      .state();
  return state['supported'] == true;
});

/// [EventHost] on top of a [MeetHost] (the app and the background
/// service alike).
final class MeetEventHost implements EventHost {
  MeetEventHost(this.meet, {required this.address, required this.name});

  final MeetHost meet;
  final String Function() address;
  final String Function() name;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) =>
      meet.send(to, payload);

  @override
  List<String> friends() => meet.friends();

  @override
  bool isFriend(String a) => meet.isFriend(a);

  @override
  String ownAddress() => address();

  @override
  String ownName() {
    final String n = name().trim();
    return n.isEmpty ? t('Ktoś') : n;
  }

  @override
  String nameOf(String a) => meet.nameOf(a);

  @override
  Future<void> notify(RuntimeSystemNotification notification) =>
      meet.notify(notification);
}

/// Events "po znajomości".
final Provider<EventService> eventServiceProvider = Provider<EventService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final EventService events = EventService(
    host: appEventHost(ref, meet),
    disk: ref.read(ledgerDiskProvider),
  );
  unawaitedLogged(events.load(), context: 'Odczyt wydarzeń');
  final StreamSubscription<SignalTransportFrame> sub = ref
      .read(signalTransportProvider)
      .frames
      .listen(
        (SignalTransportFrame f) =>
            unawaitedLogged(events.handle(f), context: 'Wydarzenia'),
      );
  ref.onDispose(() {
    unawaited(sub.cancel());
    events.dispose();
  });
  return events;
});

/// The app's [EventHost] (also used by the neighbours section).
EventHost appEventHost(Ref ref, MeetService meet) => MeetEventHost(
  meet.host,
  address: () => ref.read(runtimeNodeSnapshotProvider).localAddress,
  name: () => ref.read(userProfileControllerProvider).publicName,
);

/// Subscribes [handle] to the app's incoming frames until [ref] goes.
void listenFrames(
  Ref ref,
  Future<bool> Function(SignalTransportFrame) handle,
  String what,
) {
  final StreamSubscription<SignalTransportFrame> sub = ref
      .read(signalTransportProvider)
      .frames
      .listen(
        (SignalTransportFrame f) => unawaitedLogged(handle(f), context: what),
      );
  ref.onDispose(() => unawaited(sub.cancel()));
}

/// "Zapytaj sieć".
final Provider<AskService> askServiceProvider = Provider<AskService>((Ref ref) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final AskService ask = AskService(
    host: appEventHost(ref, meet),
    disk: ref.read(ledgerDiskProvider),
  );
  unawaitedLogged(ask.load(), context: 'Odczyt pytań');
  listenFrames(ref, ask.handle, 'Zapytaj sieć');
  ref.onDispose(ask.dispose);
  return ask;
});

/// Stół na sześć.
final Provider<TableService> tableServiceProvider = Provider<TableService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final TableService table = TableService(
    host: appEventHost(ref, meet),
    events: ref.watch(eventServiceProvider),
    disk: ref.read(ledgerDiskProvider),
    friendsOf: (String f) => meet.book.friendsOf(f),
  );
  unawaitedLogged(table.load(), context: 'Odczyt Stołu na sześć');
  listenFrames(ref, table.handle, 'Stół na sześć');
  ref.onDispose(table.dispose);
  return table;
});

/// Kółko obiadowe.
final Provider<CircleService> circleServiceProvider = Provider<CircleService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final CircleService circles = CircleService(
    host: appEventHost(ref, meet),
    disk: ref.read(ledgerDiskProvider),
  );
  unawaitedLogged(
    circles.load().then((_) => circles.tick()),
    context: 'Odczyt kółek',
  );
  listenFrames(ref, circles.handle, 'Kółko obiadowe');
  // The reminder the day before a dinner and "Jak było?" after it.
  final Timer reminders = Timer.periodic(
    const Duration(minutes: 15),
    (_) => unawaitedLogged(circles.tick(), context: 'Kółko: przypomnienia'),
  );
  ref.onDispose(() {
    reminders.cancel();
    circles.dispose();
  });
  return circles;
});
