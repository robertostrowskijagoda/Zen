import 'dart:math';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/pyramid/pyramid_record_log.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Phones with the pyramid service on a simulated network.
final class PyramidWorld {
  PyramidWorld({
    int seed = 1,
    double dropRate = 0,
    this.recordSegmentEntries = kPyrLogSegmentEntries,
  }) : net = SimNetwork(seed: seed, dropRate: dropRate);

  /// Builds S on top, A and B under S, A1 and A2 under A, B1 under B.
  static Future<PyramidWorld> six({
    int seed = 1,
    int recordSegmentEntries = kPyrLogSegmentEntries,
  }) async {
    final PyramidWorld w = PyramidWorld(
      seed: seed,
      recordSegmentEntries: recordSegmentEntries,
    );
    final SimPhone s = w.add('S');
    final SimPhone a = w.add('A');
    final SimPhone b = w.add('B');
    final SimPhone a1 = w.add('A1');
    final SimPhone a2 = w.add('A2');
    final SimPhone b1 = w.add('B1');
    await w.pyr(s).load();
    await w
        .pyr(s)
        .createPyramid(
          name: 'Ruch',
          myName: 'S',
          nat: 'PL',
          birthYear: 1980,
          gender: 'm',
        );
    await w.join(s, a);
    await w.join(s, b);
    await w.join(a, a1);
    await w.join(a, a2);
    await w.join(b, b1, nat: 'DE');
    // A few more friendships, as in life.
    w.net
      ..befriend(a2, b1)
      ..befriend(a1, b);
    await w.sync();
    return w;
  }

  final SimNetwork net;

  /// Each phone's pyramid key seed (from its account, §6.1), by its disk:
  /// a phone started again on the same disk is the same person.
  final Map<LedgerDisk, Uint8List> _seeds = <LedgerDisk, Uint8List>{};
  final Random _seedRandom = Random(7);

  /// The account-derived seed of the phone on [disk].
  Future<Uint8List?> Function() seedOf(LedgerDisk disk) =>
      () async => _seeds[disk] ??= Uint8List.fromList(
        List<int>.generate(32, (_) => _seedRandom.nextInt(256)),
      );
  final Map<String, List<Map<String, dynamic>>> waves =
      <String, List<Map<String, dynamic>>>{};

  /// Records per segment of each phone's record log.
  final int recordSegmentEntries;

  /// A phone with the pyramid service, its data on [disk] (a fresh one in
  /// memory by default); [friendLevelOf] is its private friend levels.
  SimPhone add(
    String name, {
    LedgerDisk? disk,
    FriendLevel? Function(String address)? friendLevelOf,
  }) {
    final SimPhone p = net.phone(name);
    final LedgerDisk d = disk ?? MemoryLedgerDisk();
    final PyramidService s = PyramidService(
      host: p,
      disk: d,
      identitySeed: seedOf(d),
      now: () => net.now,
      tallyWait: const Duration(minutes: 30),
      recordSegmentEntries: recordSegmentEntries,
      friendLevelOf: friendLevelOf,
      // Friends' friend lists, as the app's address book shares them.
      friendsOf: (String f) => <String, String>{
        for (final String a in net.byAddress[f]?.friendSet ?? const <String>{})
          a: net.byAddress[a]?.name ?? '',
      },
      crisisBroadcast: (Map<String, dynamic> wave) async {
        (waves[name] ??= <Map<String, dynamic>>[]).add(wave);
        return 1;
      },
    );
    p.services['pyr'] = s;
    p.attach(s.handle);
    // "Zapytaj sieć" on the same phone (tips in the pyramid's money).
    final AskService ask = AskService(
      host: p,
      disk: MemoryLedgerDisk(),
      now: () => net.now,
    );
    p.services['ask'] = ask;
    p.attach(ask.handle);
    return p;
  }

  PyramidService pyr(SimPhone p) => p.service<PyramidService>('pyr');

  AskService ask(String name) => net[name].service<AskService>('ask');

  PyramidService operator [](String name) => pyr(net[name]);

  /// [newcomer] joins under [head], in person (QR), head confirms.
  Future<void> join(
    SimPhone head,
    SimPhone newcomer, {
    String nat = 'PL',
    int year = 1990,
  }) async {
    net.befriend(head, newcomer);
    final String? code = pyr(head).inviteCode();
    if (code == null) {
      throw StateError('${head.name} nie ma wolnego miejsca');
    }
    await pyr(newcomer).load();
    await pyr(newcomer).askToJoin(
      invite: code,
      myName: newcomer.name,
      nat: nat,
      birthYear: year,
      gender: 'k',
    );
    await net.run();
    final PyramidService h = pyr(head);
    final String id = h.proposals.keys.single;
    await h.approve(id);
    await net.run();
  }

  /// Every member met every other in person (§6.2): each says so in the
  /// pyramid, so all may vote in referenda (§20.6).
  Future<void> meetAll() async {
    for (final SimPhone p in net.phones) {
      for (final SimPhone q in net.phones) {
        if (p != q && pyr(p).isMember) {
          await pyr(p).attestMet(q.address);
        }
      }
    }
    await net.run();
  }

  /// [who] signs the proposal of kind [type] waiting for them.
  Future<void> approve(String who, String type) async {
    final PyramidService s = this[who];
    final String id = s.proposals.values
        .firstWhere((PyrProposal p) => p.record.type == type)
        .record
        .id;
    await s.approve(id);
    await net.run();
  }

  /// [who] signs everything waiting for them (of [type], if given).
  Future<int> approveAll(String who, [String? type]) async {
    final PyramidService s = this[who];
    int n = 0;
    for (final PyrProposal p in s.proposals.values.toList()) {
      if (type == null || p.record.type == type) {
        await s.approve(p.record.id);
        n++;
      }
    }
    await net.run();
    return n;
  }

  /// Everybody says hello to their friends until nothing changes.
  Future<void> sync({int rounds = 3}) async {
    for (int i = 0; i < rounds; i++) {
      for (final SimPhone p in net.phones) {
        if (p.online) {
          await pyr(p).greet();
        }
      }
      await net.run();
    }
  }

  Future<void> duties({int rounds = 4}) async {
    for (int i = 0; i < rounds; i++) {
      for (final SimPhone p in net.phones) {
        if (p.online) {
          await pyr(p).duties();
        }
      }
      await net.run();
    }
  }

  /// What everybody in the pyramid sees, to compare.
  Map<String, String> views() => <String, String>{
    for (final SimPhone p in net.phones)
      if (pyr(p).state != null) p.name: _fingerprint(pyr(p).state!),
  };

  /// What one phone sees of [s], to compare.
  static String fingerprint(PyramidState s) => _fingerprint(s);

  static String _fingerprint(PyramidState s) =>
      '${s.describe()}|${s.applied.length}|${s.term}|${s.transfers.length}';
}
