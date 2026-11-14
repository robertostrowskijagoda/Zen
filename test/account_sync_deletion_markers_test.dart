import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// The dating profile, the profile and the meetings keep no deletion
// markers of their own (the passwords and the notes do): a deletion there
// is the sync's own tombstone, and a device's log of states, starting over,
// carried tombstones for 30 days only. A device away for longer came back
// with what was deleted and kept it (and sent it on to a device linked
// later). Their deletions now travel over every start of the log, the
// newest first, within a bound. A virtual clock moves time.

final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null && nodes[address] == this) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<void> _settle([int rounds = 120]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The test's clock (the states' times; the ledger keeps its own).
int _now = DateTime.now().millisecondsSinceEpoch;

/// Dating needs no one to talk to here.
final class _Host implements EventHost {
  _Host(this.address);

  final String address;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => const <String>[];

  @override
  bool isFriend(String address) => false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => 'Ala';

  @override
  String nameOf(String address) => address;

  @override
  Future<void> notify(RuntimeSystemNotification notification) async {}
}

const String _plansKey = 'meet/plans';

/// One device of the account: its node, and the dating profile, the
/// profile and the meetings' plans, each through the domain the app uses.
final class _Device {
  _Device(this.address)
    : disk = MemoryLedgerDisk(),
      appDisk = MemoryLedgerDisk(),
      transport = _Linked(_a(address)) {
    _Linked.nodes[_a(address)] = transport;
    dating = DatingService(
      host: _Host(address),
      disk: appDisk,
      now: () => _now,
    );
    container = ProviderContainer(
      overrides: [datingServiceProvider.overrideWithValue(dating)],
    );
    addTearDown(container.dispose);
  }

  final String address;
  final MemoryLedgerDisk disk;

  /// The app's own stores (dating, meetings).
  final MemoryLedgerDisk appDisk;
  final _Linked transport;
  late final DatingService dating;
  late final ProviderContainer container;
  late final LedgerNode node;
  late final AccountStateSync sync;
  late final DatingSyncDomain datingDomain;
  late final ProfileSyncDomain profileDomain;
  late final StoredStateSyncDomain plansDomain;

  Future<void> start() async {
    await transport.start();
    node = LedgerNode(
      transport: transport,
      disk: disk,
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => transport.address,
      syncInterval: Duration.zero,
    );
    addTearDown(node.stop);
    await node.start();
  }

  Future<void> startSync() async {
    await dating.load();
    await dating.saveMine((MyDating me) => me.name = 'Ala');
    await container
        .read(userProfileControllerProvider.notifier)
        .updateProfile(displayName: 'Ala');
    await appDisk.write(_plansKey, _json(<String, Object?>{'plans': []}));
    datingDomain = container.read(
      Provider<DatingSyncDomain>((Ref ref) => DatingSyncDomain(ref, appDisk)),
    );
    profileDomain = container.read(
      Provider<ProfileSyncDomain>((Ref ref) => ProfileSyncDomain(ref, node)),
    );
    plansDomain = MeetStateSyncDomain(_plansKey, appDisk, () async {});
    sync = AccountStateSync(
      channel: LedgerAccountSyncChannel(node),
      disk: MemoryLedgerDisk(),
      domains: <AccountSyncDomain>[datingDomain, profileDomain, plansDomain],
      delay: const Duration(milliseconds: 1),
      scanEvery: const Duration(hours: 1),
      now: () => _now,
    );
    await sync.start();
    addTearDown(() async {
      await sync.stop();
      await datingDomain.close();
      await profileDomain.close();
      await plansDomain.close();
    });
  }

  // ---- the meetings' plans, as stored ----

  Future<List<String>> plans() async {
    final Map<String, dynamic> state =
        jsonDecode(utf8.decode((await appDisk.read(_plansKey))!))
            as Map<String, dynamic>;
    return <String>[
      for (final Object? p in state['plans'] as List<dynamic>)
        (p! as Map<String, dynamic>)['id'] as String,
    ];
  }

  Future<void> setPlans(List<String> ids) => appDisk.write(
    _plansKey,
    _json(<String, Object?>{
      'plans': <Object?>[
        for (final String id in ids) <String, Object?>{'id': id, 't': 'P $id'},
      ],
    }),
  );

  // ---- the dating profile ----

  /// The dating profile as the service keeps it (read from its store, as
  /// a restart would).
  Future<MyDating> datingSaved() async {
    final DatingService again = DatingService(
      host: _Host(address),
      disk: appDisk,
      now: () => _now,
    );
    await again.load();
    return again.me;
  }

  // ---- the profile ----

  UserProfile get profile => container.read(userProfileControllerProvider);

  Future<void> setNationalities(List<String> codes) => container
      .read(userProfileControllerProvider.notifier)
      .updateProfile(nationalities: codes);

  void goOffline() => _Linked.nodes.remove(_a(address));

  Future<void> comeBack() async {
    _Linked.nodes[_a(address)] = transport;
    for (final String other in _Linked.nodes.keys.toList()) {
      if (other != _a(address)) {
        node.greet(other);
      }
    }
  }
}

Uint8List _json(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Future<(_Device, _Device)> _twoDevices() async {
  _Linked.nodes.clear();
  final _Device first = _Device('200::b1');
  await first.start();
  final _Device second = _Device('200::b2');
  await LedgerIdentity.adoptAccount(
    second.disk,
    (await LedgerIdentity.loadOrCreate(first.disk)).accountKey!.seed,
  );
  await second.start();
  await second.node.rememberDeviceAddresses(<String>[_a('200::b1')]);
  await _settle(200);
  await first.startSync();
  await second.startSync();
  await _settle();
  return (first, second);
}

Future<void> _exchange(List<_Device> devices) async {
  for (int round = 0; round < 4; round++) {
    for (final _Device d in devices) {
      await d.sync.flush();
    }
    await _settle(60);
  }
}

/// Weeks pass for [devices], each alone: their logs start over several times
/// (something is overwritten each week), so a deletion is no longer
/// written into them again for its own 30 days.
Future<void> _weeksPass(List<_Device> devices) async {
  for (int i = 0; i < 6; i++) {
    _now += const Duration(days: 7).inMilliseconds;
    for (final _Device d in devices) {
      await d.dating.saveMine((MyDating me) => me.about = '${d.address} $i');
    }
    await _exchange(devices);
  }
  for (final _Device d in devices) {
    expect(d.sync.rebased, greaterThan(1), reason: d.address);
  }
}

void main() {
  setUp(() {
    LedgerNode.stateLogDropDelay = Duration.zero;
    _now = DateTime.now().millisecondsSinceEpoch;
  });
  tearDown(() {
    LedgerNode.stateLogDropDelay = const Duration(seconds: 30);
  });

  test('deleted on one device while another was away for weeks: it stays '
      'deleted on both (dating, profile, meetings)', () async {
    final (_Device first, _Device second) = await _twoDevices();
    await first.dating.saveMine((MyDating me) {
      me.enabled = true;
      me.photos.add('cGhvdG8=');
    });
    await first.setNationalities(<String>['PL', 'DE']);
    await first.setPlans(<String>['p1', 'p2']);
    await _exchange(<_Device>[first, second]);
    expect((await second.datingSaved()).enabled, isTrue);
    expect((await second.datingSaved()).photos, <String>['cGhvdG8=']);
    expect(second.profile.nationalities.toSet(), <String>{'PL', 'DE'});
    expect(await second.plans(), <String>['p1', 'p2']);

    second.goOffline();
    await first.dating.saveMine((MyDating me) {
      me.enabled = false;
      me.photos.clear();
    });
    await first.setNationalities(<String>['PL']);
    await first.setPlans(<String>['p2']);
    await _exchange(<_Device>[first]);
    await _weeksPass(<_Device>[first]);

    await second.comeBack();
    await _settle(200);
    await _exchange(<_Device>[first, second]);
    // Every domain at once: what came back, where.
    final List<String> back = <String>[];
    for (final _Device d in <_Device>[first, second]) {
      final MyDating dating = await d.datingSaved();
      if (dating.enabled) {
        back.add('dating switched on, on ${d.address}');
      }
      if (dating.photos.isNotEmpty) {
        back.add('dating photo on ${d.address}');
      }
      if (d.profile.nationalities.contains('DE')) {
        back.add('profile nationality on ${d.address}');
      }
      final List<String> plans = await d.plans();
      if (plans.contains('p1')) {
        back.add('meetings plan on ${d.address}');
      }
      expect(d.profile.nationalities, contains('PL'), reason: d.address);
      expect(plans, contains('p2'), reason: d.address);
    }
    expect(back, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a deletion older than a newer re-creation does not delete it',
    () async {
      final (_Device first, _Device second) = await _twoDevices();
      await first.dating.saveMine((MyDating me) => me.enabled = true);
      await first.setNationalities(<String>['PL', 'DE']);
      await first.setPlans(<String>['p1', 'p2']);
      await _exchange(<_Device>[first, second]);

      // Deleted on the first, and the second takes the deletion.
      await first.dating.saveMine((MyDating me) => me.enabled = false);
      await first.setNationalities(<String>['PL']);
      await first.setPlans(<String>['p2']);
      await _exchange(<_Device>[first, second]);
      expect((await second.datingSaved()).enabled, isFalse);
      expect(await second.plans(), <String>['p2']);

      // The first goes away still holding its deletions; the second makes
      // the same things again afterwards.
      first.goOffline();
      await second.dating.saveMine((MyDating me) => me.enabled = true);
      await second.setNationalities(<String>['PL', 'DE']);
      await second.setPlans(<String>[...await second.plans(), 'p1']);
      await _exchange(<_Device>[second]);
      // Apart (the first cannot reach the second, nor it the first).
      await _weeksPass(<_Device>[first, second]);

      await first.comeBack();
      await _settle(200);
      await _exchange(<_Device>[first, second]);
      for (final _Device d in <_Device>[first, second]) {
        expect((await d.datingSaved()).enabled, isTrue, reason: d.address);
        expect(d.profile.nationalities.toSet(), <String>{
          'PL',
          'DE',
        }, reason: d.address);
        expect(await d.plans(), contains('p1'), reason: d.address);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
