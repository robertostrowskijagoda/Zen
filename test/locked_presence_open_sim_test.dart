import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// What a phone shows of its friends the moment Zen opens on it, after it
// was locked (or in the background) for a while: the real LockedReceiver of
// this phone and of its friends on a virtual clock (as in
// locked_presence_sim_test.dart), then the real app reading what the
// receiver kept (presence.zbox) and its own stored state, as it does when
// it opens.
//
// Friends 1-4 have their phones locked with the service running all the
// time: each answers, and each is "w tle". Friend 5's phone was switched off
// 50 minutes before the opening. Before the time this phone spends locked
// it was locked for two hours (an earlier run of its receiver, whose
// presence.zbox may still be there), then Zen was on its screen for 20
// minutes, pinging the friends.
//
// The order of what happens as Zen opens, as on Android:
//  1. the stored friends are read (their statuses aged as they stand now);
//  2. the core starts and takes what the service kept, before the service
//     is parked (on unlock the security gate starts the core first; when
//     the app comes back from the background after the service took the
//     node, the core starts only once it is parked);
//  3. the service is parked (its receiver writes what it heard last) and
//     the app takes the node back: it reads its stored state again, and
//     what the service kept;
//  4. nothing answers yet: the first state must already show friends 1-4
//     "w tle", and stay so for the next 10 seconds; friend 5 must never
//     show as present.

const int _sec = 1000;
const int _min = 60 * _sec;

String _address(int i) => PeerShareCodec.normalizeAddress(
  '200:1111:2222:3333:4444:5555:${(0x3000 + i).toRadixString(16)}:1',
);

/// Friend 4's other phone (the same account): the one that is locked.
final String _friend4Second = PeerShareCodec.normalizeAddress(
  '201:aaaa:2222:3333:4444:5555:6666:4',
);

final Uint8List _masterKey = Uint8List.fromList(
  List<int>.generate(32, (int i) => i + 11),
);

/// How the opening came about.
enum _Open {
  /// Unlocked after this long locked (the service ran the node).
  locked,

  /// Back from the background before the service took the node (5 min).
  backgroundShort,

  /// Back from the background after the service took the node.
  backgroundLong,

  /// The app's process was started again while the phone was locked.
  restart,
}

final class _Case {
  const _Case(this.name, this.open, this.away, {this.loseRound = false});

  final String name;
  final _Open open;
  final Duration away;

  /// Every frame between this phone and friend 2 in the round before the
  /// last one is lost (one round without a word, which "w tle" outlasts).
  final bool loseRound;
}

/// What the run gives the app: its stored state at the moment it left the
/// screen, and presence.zbox before and after the receiver's last write.
final class _Opening {
  _Opening({
    required this.openAt,
    required this.stored,
    required this.keptBeforeStop,
    required this.keptAfterStop,
  });

  final int openAt;
  final Map<int, ({int at, PeerPresence state})> stored;
  final List<SignalTransportFrame> keptBeforeStop;
  final List<SignalTransportFrame> keptAfterStop;
}

final class _Ev {
  _Ev(this.at, this.seq, this.run);

  final int at;
  final int seq;
  final Future<void> Function() run;
}

/// Zen on this phone's screen (or in the background, unlocked): it answers
/// friends' pings, and pings them itself while on the screen ("w tle"
/// friends every 4 minutes).
final class _App {
  final Map<int, ({int at, PeerPresence state})> heard =
      <int, ({int at, PeerPresence state})>{};
  bool onScreen = false;
}

final class _Sim {
  _Sim(this.c, this.seed);

  final _Case c;
  final int seed;

  static const int friends = 5;
  static const int offFriend = 5;

  int clock = 0;
  int _seq = 0;
  final List<_Ev> _queue = <_Ev>[];
  late final Map<String, int> _index = <String, int>{
    for (int i = 0; i <= friends; i++) _address(i): i,
  };

  final List<LockedReceiver?> phones = List<LockedReceiver?>.filled(
    friends + 1,
    null,
  );
  final _App app = _App();

  /// When friend 5's phone went off.
  late int offAt;

  void at(int t, Future<void> Function() run) =>
      _queue.add(_Ev(t, _seq++, run));

  /// The rounds keep to a 10-minute grid that has its last round before
  /// the opening this long before it.
  static const int lastRoundBeforeOpen = 8 * _min;

  /// Frames between this phone and friend 2 sent around then are lost
  /// ([_Case.loseRound]).
  late int lostAround;

  void send(int from, String to, Map<String, dynamic> payload) {
    final int? j = _index[to];
    if (j == null || (from == offFriend && clock >= offAt)) {
      return;
    }
    if (c.loseRound &&
        ((from == 0 && j == 2) || (from == 2 && j == 0)) &&
        (clock - lostAround).abs() < _min) {
      return;
    }
    final SignalTransportFrame frame = SignalTransportFrame(
      from: _address(from),
      payload: Map<String, dynamic>.from(payload),
      receivedAtMillis: clock + 80,
    );
    at(clock + 80, () => _deliver(j, frame));
  }

  Future<void> _deliver(int to, SignalTransportFrame frame) async {
    if (to == offFriend && clock >= offAt) {
      return;
    }
    final LockedReceiver? receiver = phones[to];
    if (receiver != null) {
      await receiver.handleFrame(frame);
      return;
    }
    if (to != 0) {
      return;
    }
    // The app itself.
    final int from = _index[frame.from]!;
    final String type = '${frame.payload['type']}';
    if (type == 'ping' || type == 'pong') {
      app.heard[from] = (
        at: frame.receivedAtMillis,
        state: PresenceReport.fromPayload(frame.payload).presence,
      );
    }
    if (type == 'ping') {
      send(0, frame.from, <String, dynamic>{
        'type': 'pong',
        'state': app.onScreen ? 'foreground' : 'background',
        'sq': clock,
      });
    }
  }

  LockedReceiver _receiver(int i, Directory dir, Uint8List inboxKey) {
    final Set<String> others = <String>{
      for (int j = 0; j <= friends; j++)
        if (j != i) _address(j),
    };
    return LockedReceiver(
      transport: _Air(i, this),
      capability: BackgroundCapability.fromDraft(
        BackgroundCapabilityDraft(
          inboxPublicKey: Uint8List(32),
          friends: others,
        ),
        backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
      inbox: SealedInboxWriter(
        file: File('${dir.path}/i$i.zbox'),
        recipientPublicKey: Uint8List(32),
      ),
      notices: MemoryRuntimeSystemNotificationService(),
      presence: LockedPresenceKit(shownTo: others),
      presenceSnapshot: SealedSnapshotWriter(
        file: File('${dir.path}/presence$i.zbox'),
        recipientPublicKey: inboxKey,
      ),
      mailboxPollInterval: Duration.zero,
      presenceRoundEvery: kLockedPresenceRoundEvery,
      now: () => clock,
    );
  }

  Future<List<SignalTransportFrame>> _kept(
    Directory dir,
  ) async => <SignalTransportFrame>[
    for (final Uint8List record in await readSealedInbox(
      File('${dir.path}/presence0.zbox'),
      await inboxKeyPairFor(_masterKey),
    ))
      if (decodeInboxFrame(record) case final SignalTransportFrame frame) frame,
  ];

  Future<_Opening> run(int openAt) async {
    final math.Random random = math.Random(seed);
    final Directory dir = await Directory.systemTemp.createTemp('zen-open-');
    final Uint8List inboxKey = await inboxPublicKeyFor(_masterKey);
    const Duration session = Duration(minutes: 20);
    const Duration earlierLock = Duration(hours: 2);
    // This phone: locked until [screenAt], Zen on the screen until
    // [leftAt], then away (locked or in the background) until [openAt].
    final int leftAt = openAt - c.away.inMilliseconds;
    final int screenAt = leftAt - session.inMilliseconds;
    final int start = screenAt - earlierLock.inMilliseconds;
    // The friends' receivers run from half an hour before.
    final int begin = start - 30 * _min;
    offAt = openAt - 50 * _min;
    clock = begin;
    for (int i = 1; i <= friends; i++) {
      phones[i] = _receiver(i, dir, inboxKey);
      await phones[i]!.start();
    }
    // Rounds on the 10-minute grid of the wall clock, clocks up to 2 s
    // apart; the last one 8 minutes before the opening.
    final int lastRound = openAt - lastRoundBeforeOpen;
    lostAround = lastRound - 10 * _min;
    final int firstRound =
        lastRound - ((lastRound - begin) ~/ (10 * _min)) * 10 * _min;
    for (int i = 0; i <= friends; i++) {
      final int phase = random.nextInt(2 * _sec) - _sec;
      for (int t = firstRound + phase; t < openAt; t += 10 * _min) {
        at(t, () async {
          if (i == offFriend && clock >= offAt) {
            return;
          }
          await phones[i]?.presenceRoundForTest();
        });
      }
    }
    // This phone's earlier lock: its receiver's first run.
    at(start, () async {
      phones[0] = _receiver(0, dir, inboxKey);
      await phones[0]!.start();
    });
    // Zen on the screen: "I am here" to everyone, then every 4 minutes.
    at(screenAt, () async {
      await phones[0]!.stop();
      phones[0] = null;
      app.onScreen = true;
    });
    for (int t = screenAt + 100; t < leftAt; t += 4 * _min) {
      final bool first = t == screenAt + 100;
      at(t, () async {
        for (int f = 1; f <= friends; f++) {
          send(0, _address(f), <String, dynamic>{
            'type': 'ping',
            'state': 'foreground',
            'lo': 0,
            'sq': clock,
            if (first) 'fs': true,
          });
        }
      });
    }
    late Map<int, ({int at, PeerPresence state})> stored;
    at(leftAt, () async {
      app.onScreen = false;
      if (c.open == _Open.locked || c.open == _Open.restart) {
        stored = Map<int, ({int at, PeerPresence state})>.of(app.heard);
        phones[0] = _receiver(0, dir, inboxKey);
        await phones[0]!.start();
      }
    });
    if (c.open == _Open.backgroundLong) {
      // Five minutes in the background: the node goes to the service.
      at(leftAt + 5 * _min, () async {
        stored = Map<int, ({int at, PeerPresence state})>.of(app.heard);
        phones[0] = _receiver(0, dir, inboxKey);
        await phones[0]!.start();
      });
    }
    while (_queue.isNotEmpty) {
      _queue.sort(
        (_Ev a, _Ev b) =>
            a.at != b.at ? a.at.compareTo(b.at) : a.seq.compareTo(b.seq),
      );
      final _Ev e = _queue.removeAt(0);
      if (e.at >= openAt) {
        continue;
      }
      clock = e.at;
      await e.run();
      for (final LockedReceiver? r in phones) {
        await r?.presenceKept;
      }
    }
    clock = openAt;
    if (c.open == _Open.backgroundShort) {
      stored = Map<int, ({int at, PeerPresence state})>.of(app.heard);
    }
    final List<SignalTransportFrame> before = await _kept(dir);
    await phones[0]?.stop();
    final List<SignalTransportFrame> after = await _kept(dir);
    for (int i = 1; i <= friends; i++) {
      await phones[i]?.stop();
    }
    await dir.delete(recursive: true);
    return _Opening(
      openAt: openAt,
      stored: stored,
      keptBeforeStop: before,
      keptAfterStop: after,
    );
  }
}

final class _Air extends MemorySignalTransport {
  _Air(this.self, this.sim);

  final int self;
  final _Sim sim;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    sim.send(self, remoteAddress, payload);
  }
}

/// Friend 4's account, with the phone at [_friend4Second].
final class _Directory implements AccountDeviceDirectory {
  @override
  String get ownAccount => 'me';

  @override
  String? accountOf(String address) =>
      PeerShareCodec.addressesEqual(address, _address(4)) ||
          PeerShareCodec.addressesEqual(address, _friend4Second)
      ? 'four'
      : null;

  @override
  List<String> addressesOf(String account) =>
      account == 'four' ? <String>[_address(4), _friend4Second] : <String>[];

  @override
  String? contactAddressOf(String account) =>
      account == 'four' ? _address(4) : null;

  @override
  String? unlinkedAccountOf(String address) => null;
}

/// The app opening on [opening] (as described at the top), with what each
/// friend shows from the first state on: the first state, and every
/// state after it for 10 seconds without an answer from anyone.
Future<Map<int, List<PeerPresence>>> _open(
  WidgetTester tester,
  _Case c,
  _Opening opening, {
  AccountDeviceDirectory? directory,
}) async {
  PeerPresence aged(({int at, PeerPresence state}) h) => presenceAt(
    presence: h.state,
    presenceAtMillis: h.at,
    nowMillis: opening.openAt - c.away.inMilliseconds,
    foregroundFor: kPresenceForegroundFor,
    backgroundFor: kPresenceBackgroundFor,
  );
  final Map<String, FriendProfile> profiles = <String, FriendProfile>{
    for (int i = 1; i <= _Sim.friends; i++)
      _address(i): switch (opening.stored[i]) {
        null => FriendProfile(
          address: _address(i),
          displayName: 'Friend $i',
          status: FriendRelationshipStatus.accepted,
        ),
        final ({int at, PeerPresence state}) h =>
          FriendProfile(
            address: _address(i),
            displayName: 'Friend $i',
            status: FriendRelationshipStatus.accepted,
          ).copyWith(
            presence: aged(h),
            presenceAtMillis: h.at,
            isOnline: aged(h) != PeerPresence.offline,
            lastPresenceAtMillis: h.at,
          ),
      },
  };
  // Friend 5 last showed "w tle" well before their phone went off.
  profiles[_address(5)] = profiles[_address(5)]!.copyWith(
    presence: PeerPresence.offline,
    presenceAtMillis: opening.openAt - 52 * _min,
  );
  final MemorySocialSnapshotStore store = MemorySocialSnapshotStore(
    SocialHubState.empty().copyWith(
      book: FriendshipBook.restore(profiles: profiles),
    ),
  );
  // On unlock (and a restart) the core starts while the service still runs
  // the node: it reads presence.zbox as the service last wrote it; coming
  // back from the background after the service took the node, the core
  // starts once the service is parked. Short in the background, the core
  // never stopped: nothing is read.
  List<SignalTransportFrame> kept = switch (c.open) {
    _Open.locked || _Open.restart => opening.keptBeforeStop,
    _Open.backgroundLong => opening.keptAfterStop,
    _Open.backgroundShort => const <SignalTransportFrame>[],
  };
  final ValueNotifier<bool> reachable = ValueNotifier<bool>(true);
  addTearDown(reachable.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        appSettingsStoreProvider.overrideWithValue(
          MemoryAppSettingsStore(const AppSettings()),
        ),
        presenceAsleepOffScreenProvider.overrideWithValue(false),
        meshReachableProvider.overrideWithValue(reachable),
        socialSnapshotStoreProvider.overrideWithValue(store),
        keptPresenceReaderProvider.overrideWithValue(() async => kept),
        if (directory != null)
          accountDirectoryHolderProvider.overrideWithValue(
            AccountDirectoryHolder()..directory = directory,
          ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(profiles: profiles),
          ),
        ),
      ],
      child: const ZenRewriteApp(),
    ),
  );
  await tester.pumpAndSettle();
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(ZenRewriteApp)),
  );
  final Map<int, List<PeerPresence>> shown = <int, List<PeerPresence>>{
    for (int i = 1; i <= _Sim.friends; i++) i: <PeerPresence>[],
  };
  void note(SocialHubState state) {
    for (int i = 1; i <= _Sim.friends; i++) {
      final PeerPresence now = state.friends[_address(i)]!.shownPresence;
      if (shown[i]!.isEmpty || shown[i]!.last != now) {
        shown[i]!.add(now);
      }
    }
  }

  note(container.read(socialHubControllerProvider));
  final ProviderSubscription<SocialHubState> watch = container
      .listen<SocialHubState>(
        socialHubControllerProvider,
        (SocialHubState? _, SocialHubState next) => note(next),
      );
  addTearDown(watch.close);
  if (c.open == _Open.locked || c.open == _Open.restart) {
    // The service parked, with its last write: the app takes the node back
    // and reads its state again, and what the service kept.
    kept = opening.keptAfterStop;
    final SocialHubController hub = container.read(
      socialHubControllerProvider.notifier,
    );
    await hub.hydrateFromStore();
    await tester.pump();
    final RuntimeSignalModule module = container
        .read(zenCoreProvider)
        .modules
        .whereType<RuntimeSignalModule>()
        .single;
    await module.takeKeptPresence();
    await tester.pump();
  }
  // Nobody answers: 10 seconds.
  for (int s = 0; s < 10; s++) {
    await tester.pump(const Duration(seconds: 1));
  }
  return shown;
}

void main() {
  const List<_Case> cases = <_Case>[
    _Case('locked 2 min', _Open.locked, Duration(minutes: 2)),
    _Case('locked 12 min', _Open.locked, Duration(minutes: 12)),
    _Case('locked 1 h', _Open.locked, Duration(hours: 1)),
    _Case('locked 8 h', _Open.locked, Duration(hours: 8)),
    _Case(
      'locked 1 h, the round before the last one with friend 2 lost',
      _Open.locked,
      Duration(hours: 1),
      loseRound: true,
    ),
    _Case(
      'in the background 1 min (the app kept the node)',
      _Open.backgroundShort,
      Duration(minutes: 1),
    ),
    _Case(
      'in the background 10 min (the service took the node)',
      _Open.backgroundLong,
      Duration(minutes: 10),
    ),
    _Case(
      'the app process started again, locked 1 h',
      _Open.restart,
      Duration(hours: 1),
    ),
  ];
  final Map<(int, int), _Opening> openings = <(int, int), _Opening>{};

  setUpAll(() async {
    // Opened a moment from now: the app reads the real clock.
    final int openAt = DateTime.now().millisecondsSinceEpoch + 30 * _sec;
    for (int k = 0; k < cases.length; k++) {
      for (int seed = 1; seed <= 2; seed++) {
        openings[(k, seed)] = await _Sim(cases[k], seed).run(openAt);
      }
    }
  });

  for (int k = 0; k < cases.length; k++) {
    for (int seed = 1; seed <= 2; seed++) {
      testWidgets('${cases[k].name} (seed $seed): the first state shows the '
          'four friends "w tle" and stays so; the friend whose phone is off '
          'never shows present', (WidgetTester tester) async {
        final Map<int, List<PeerPresence>> shown = await _open(
          tester,
          cases[k],
          openings[(k, seed)]!,
        );
        String ages(List<SignalTransportFrame> kept) => <String>[
          for (final SignalTransportFrame f in kept)
            '${(openings[(k, seed)]!.openAt - f.receivedAtMillis) ~/ _min}',
        ].join('/');
        // ignore: avoid_print
        print(
          '${cases[k].name} (seed $seed): presence.zbox ages (min) '
          '${ages(openings[(k, seed)]!.keptBeforeStop)} before the receiver '
          'stops, ${ages(openings[(k, seed)]!.keptAfterStop)} after; $shown',
        );
        for (int i = 1; i <= 4; i++) {
          expect(shown[i], <PeerPresence>[
            PeerPresence.background,
          ], reason: 'friend $i');
        }
        expect(shown[5], isNot(contains(PeerPresence.background)));
        expect(shown[5], isNot(contains(PeerPresence.online)));
      });
    }
  }

  testWidgets('a friend whose locked phone is their second device shows "w '
      'tle" from what the service kept', (WidgetTester tester) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<int, List<PeerPresence>> shown = await _open(
      tester,
      const _Case('second device', _Open.backgroundLong, Duration(minutes: 30)),
      _Opening(
        openAt: now,
        stored: <int, ({int at, PeerPresence state})>{
          for (int i = 1; i <= 4; i++)
            i: (at: now - 33 * _min, state: PeerPresence.background),
        },
        keptBeforeStop: <SignalTransportFrame>[],
        keptAfterStop: <SignalTransportFrame>[
          for (int i = 1; i <= 4; i++)
            SignalTransportFrame(
              from: i == 4 ? _friend4Second : _address(i),
              payload: <String, dynamic>{
                'type': 'pong',
                'state': 'background',
                'sq': now - 4 * _min,
              },
              receivedAtMillis: now - 4 * _min,
            ),
        ],
      ),
      directory: _Directory(),
    );
    for (int i = 1; i <= 4; i++) {
      expect(shown[i], <PeerPresence>[
        PeerPresence.background,
      ], reason: 'friend $i');
    }
  });

  testWidgets('what an earlier run of the service kept shows as what it is '
      'worth now, and never over a newer status', (WidgetTester tester) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    SignalTransportFrame word(int i, String type, String state, int at) =>
        SignalTransportFrame(
          from: _address(i),
          payload: <String, dynamic>{'type': type, 'state': state, 'sq': at},
          receivedAtMillis: at,
        );
    final Map<int, List<PeerPresence>> shown = await _open(
      tester,
      const _Case('an old file', _Open.backgroundLong, Duration(minutes: 3)),
      _Opening(
        openAt: now,
        // Zen was on the screen 3 minutes ago: friends 1-4 answered then.
        stored: <int, ({int at, PeerPresence state})>{
          for (int i = 1; i <= 4; i++)
            i: (at: now - 4 * _min, state: PeerPresence.background),
        },
        keptBeforeStop: <SignalTransportFrame>[],
        // A file from before that: friend 1 had Zen open 20 minutes ago,
        // friend 2 was "w tle" 15 minutes ago, and friend 5, whose phone
        // has been off since, was "w tle" 40 minutes ago.
        keptAfterStop: <SignalTransportFrame>[
          word(1, 'ping', 'foreground', now - 20 * _min),
          word(2, 'pong', 'background', now - 15 * _min),
          word(5, 'pong', 'background', now - 40 * _min),
        ],
      ),
    );
    for (int i = 1; i <= 4; i++) {
      expect(shown[i], <PeerPresence>[
        PeerPresence.background,
      ], reason: 'friend $i');
    }
    expect(shown[5], <PeerPresence>[PeerPresence.offline]);
  });
}
