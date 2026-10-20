import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/plan/plan_service.dart';
import 'package:zen/src/features/meet/table/table_service.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
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

/// Statuses, alarms and nearby keys (§15–16) in the app.
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
  // Weak acquaintances get no friend list and statuses (§8); after a
  // level change [setFriendLevel] sends both again.
  service.levelOf = (String a) => ref.read(ledgerNodeProvider)?.levelOf(a);
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

/// [MeetHost] for the Android background service (its own container and
/// ledger): a friend's alarm still rings while the app is closed.
final class ContainerMeetHost implements MeetHost {
  ContainerMeetHost({
    required this.container,
    required this.transport,
    required this.ledger,
    required this.ownAddress,
  });

  final ProviderContainer container;
  final SignalTransport transport;
  final LedgerNode? Function() ledger;
  final String Function() ownAddress;

  SocialHubState get _state => container.read(socialHubControllerProvider);

  @override
  Future<void> send(String to, Map<String, dynamic> payload) =>
      transport.send(remoteAddress: to, payload: payload);

  @override
  List<String> friends() => acceptedFriendAddresses(_state);

  @override
  List<String> closeFriends() {
    final LedgerNode? node = ledger();
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
    final String own = ownAddress();
    return own.isNotEmpty && PeerShareCodec.addressesEqual(own, address);
  }

  @override
  String nameOf(String address) {
    final FriendProfile? f = _state.friendByAddress(address);
    return f == null ? t('Ktoś') : _state.nameFor(f);
  }

  @override
  Future<void> notify(RuntimeSystemNotification notification) async {
    await container
        .read(runtimeSystemNotificationServiceProvider)
        .show(notification);
  }

  @override
  Future<void> dismissNotification(String slotKey) => container
      .read(runtimeSystemNotificationServiceProvider)
      .dismissSlot(slotKey);
}

/// People nearby (§15). Starts showing this phone when Bluetooth may be
/// used and the person did not hide it.
final Provider<NearbyService> nearbyServiceProvider = Provider<NearbyService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final SignalTransport transport = ref.read(signalTransportProvider);
  final NearbyService nearby = NearbyService(
    radio: ChannelNearbyRadio(),
    meet: meet,
    ownAddress: () => ref.read(runtimeNodeSnapshotProvider).localAddress,
    sendMesh: (String to, Map<String, dynamic> payload) =>
        transport.send(remoteAddress: to, payload: payload),
    frames: transport.frames,
  );
  void onMeet() => nearby.friendsChanged();
  meet.addListener(onMeet);
  Future<void> showIfAllowed() async {
    final Map<Object?, Object?> state = await nearby.radio.state();
    if (state['permitted'] == true &&
        state['enabled'] == true &&
        meet.book.nearbyVisible) {
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

/// Events "po znajomości" (§17).
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
  name: () => ref.read(userProfileControllerProvider).displayName,
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

/// "Zapytaj sieć" (§17.5).
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

/// Stół na sześć (§17.4).
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

/// Kółko obiadowe (§17.3).
final Provider<CircleService> circleServiceProvider = Provider<CircleService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final CircleService circles = CircleService(
    host: appEventHost(ref, meet),
    disk: ref.read(ledgerDiskProvider),
  );
  unawaitedLogged(circles.load(), context: 'Odczyt kółek');
  listenFrames(ref, circles.handle, 'Kółko obiadowe');
  ref.onDispose(circles.dispose);
  return circles;
});

/// Everything of the meeting features in one place, for the Android
/// background service: frames that arrive while the app is away are
/// handled (and kept) instead of lost.
final class MeetInbox {
  MeetInbox({
    required this.meet,
    required LedgerDisk disk,
    required String Function() address,
  }) : _host = MeetEventHost(meet.host, address: address, name: () => '') {
    events = EventService(host: _host, disk: disk);
    ask = AskService(host: _host, disk: disk);
    table = TableService(
      host: _host,
      events: events,
      disk: disk,
      friendsOf: (String f) => meet.book.friendsOf(f),
    );
    circles = CircleService(host: _host, disk: disk);
    neighbors = NeighborsService(host: _host, disk: disk);
    // Deadlines of "Idę na randkę" are checked here too (§19.4), so this
    // person's alarm can go out while the app is closed.
    dating = DatingService(
      host: _host,
      disk: disk,
      raiseAlarm: (String note) async {
        await meet.raiseAlarm(note: note);
      },
    );
    pyramid = PyramidService(
      host: _host,
      disk: disk,
      friendsOf: (String f) => meet.book.friendsOf(f),
    );
    // Answers are kept; the app turns a full plan into an event (§17.6).
    plans = PlanService(
      host: _host,
      disk: disk,
      events: events,
      closeFriends: () => meet.host.closeFriends(),
      convert: false,
    );
    // Introductions and letters through friends (§24.1); the friend
    // requests they lead to are made when the app opens.
    intro = IntroService(host: _host, disk: disk, meet: () => meet);
  }

  final MeetService meet;
  final EventHost _host;
  late final EventService events;
  late final AskService ask;
  late final TableService table;
  late final CircleService circles;
  late final NeighborsService neighbors;
  late final DatingService dating;
  late final PyramidService pyramid;
  late final PlanService plans;
  late final IntroService intro;

  static bool handles(String type) =>
      MeetTypes.all.contains(type) ||
      IntroTypes.all.contains(type) ||
      EventTypes.all.contains(type) ||
      AskTypes.all.contains(type) ||
      CircleTypes.all.contains(type) ||
      FlatTypes.all.contains(type) ||
      DatingTypes.all.contains(type) ||
      PyramidTypes.all.contains(type) ||
      PlanTypes.all.contains(type) ||
      type == kTableWishType;

  /// Reads the current state from disk, then handles [frame].
  Future<void> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (MeetTypes.all.contains(type)) {
      await meet.handle(frame);
    } else if (IntroTypes.all.contains(type)) {
      // Who may see the friend list is read from the book.
      await meet.reload();
      await intro.load();
      await intro.handle(frame);
    } else if (EventTypes.all.contains(type)) {
      await events.load();
      await events.handle(frame);
    } else if (AskTypes.all.contains(type)) {
      await ask.load();
      await ask.handle(frame);
    } else if (CircleTypes.all.contains(type)) {
      await circles.load();
      await circles.handle(frame);
    } else if (PyramidTypes.all.contains(type)) {
      await pyramid.load();
      await pyramid.handle(frame);
    } else if (DatingTypes.all.contains(type)) {
      await dating.load();
      await dating.handle(frame);
    } else if (FlatTypes.all.contains(type)) {
      await neighbors.load();
      await neighbors.handle(frame);
    } else if (PlanTypes.all.contains(type)) {
      await plans.load();
      await plans.handle(frame);
    } else if (type == kTableWishType) {
      await meet.reload();
      await table.load();
      await table.handle(frame);
    }
  }
}
