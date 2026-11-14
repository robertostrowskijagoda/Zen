import 'dart:math';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_record_log.dart';
import 'package:zen/src/features/pyramid/pyramid_root.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Phones with the pyramid service on a simulated network.
final class PyramidWorld {
  PyramidWorld({
    int seed = 1,
    double dropRate = 0,
    this.recordSegmentEntries = kPyrLogSegmentEntries,
    this.root,
  }) : net = SimNetwork(seed: seed, dropRate: dropRate);

  /// The pyramid the phones keep (the test one when null).
  final PyramidRoot? root;

  /// Builds S on top, A and B under S and A2 under A, B1 under B. With
  /// [sealed] the founder then seals its era, so the six are the
  /// treasurers who sign payments ([sealEra]).
  static Future<PyramidWorld> six({
    int seed = 1,
    int recordSegmentEntries = kPyrLogSegmentEntries,
    bool sealed = true,
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
    await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 1980, gender: 'm');
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
    if (sealed) {
      await w.sealEra();
    }
    return w;
  }

  /// The open era of the treasurers is sealed by its treasurers' apps
  /// once the tree changed them: an hour after its start (and the ten
  /// minutes a seal ends before its proposal), after the ledgers were
  /// offered to each other.
  Future<void> sealEra() async {
    await net.advance(const Duration(hours: 1, minutes: 11));
    await duties(rounds: 1);
    await net.advance(const Duration(minutes: 11));
    await duties(rounds: 3);
    await sync();
  }

  final SimNetwork net;

  /// Each phone's pyramid key seed (from its account), by its disk:
  /// a phone started again on the same disk is the same person.
  final Map<LedgerDisk, Uint8List> _seeds = <LedgerDisk, Uint8List>{};
  final Random _seedRandom = Random(7);

  /// The account-derived seed of the phone on [disk].
  Future<Uint8List?> Function() seedOf(LedgerDisk disk) =>
      () async => _seeds[disk] ??= Uint8List.fromList(
        List<int>.generate(32, (_) => _seedRandom.nextInt(256)),
      );

  /// The phone on [linked] is another device of the account on [of]: the
  /// same pyramid key.
  void linkDevice(LedgerDisk of, LedgerDisk linked) {
    _seeds[linked] = _seeds[of] ??= Uint8List.fromList(
      List<int>.generate(32, (_) => _seedRandom.nextInt(256)),
    );
  }

  final Map<String, List<Map<String, dynamic>>> waves =
      <String, List<Map<String, dynamic>>>{};

  /// Posts each phone shared with its friends on order, by name.
  final Map<String, List<Map<String, dynamic>>> reshared =
      <String, List<Map<String, dynamic>>>{};

  /// Records per segment of each phone's record log.
  final int recordSegmentEntries;

  /// The nationalities in each phone's profile, by name: what the
  /// phone itself and its friends see.
  final Map<String, List<String>> profileNationalities =
      <String, List<String>>{};

  /// Each phone's region (a country code), by name.
  final Map<String, String> regions = <String, String>{};

  /// A phone with the pyramid service, its data on [disk] (a fresh one in
  /// memory by default); [friendLevelOf] is its private friend levels.
  ///
  /// With [fromAccount] the pyramid key comes, as in the app, from the
  /// ledger identity (the account key) on [disk].
  SimPhone add(
    String name, {
    LedgerDisk? disk,
    FriendLevel? Function(String address)? friendLevelOf,
    bool fromAccount = false,
  }) {
    final SimPhone p = net.phone(name);
    final LedgerDisk d = disk ?? MemoryLedgerDisk();
    final PyramidService s = PyramidService(
      host: p,
      disk: d,
      root: root,
      identitySeed: fromAccount ? null : seedOf(d),
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
      resharePost: (Map<String, dynamic> post) async {
        (reshared[name] ??= <Map<String, dynamic>>[]).add(post);
        return true;
      },
      nationalitiesOf: (String a) =>
          profileNationalities[net.byAddress[a]?.name] ?? const <String>[],
      myNationalities: () => profileNationalities[name] ?? const <String>[],
      phoneRegion: () => regions[name],
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
    final String? p = pyr(head).state?.pathOf(pyr(head).myKey ?? '');
    final String? slot = p == null ? null : pyr(head).state!.freeSlot(p);
    final String? code = slot == null ? null : pyr(head).inviteCode(slot: slot);
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

  /// "Polecenie": [sponsor] brings [newcomer] (a friend met in person) to
  /// the free place [slot] of its branch (by default the one nearest the
  /// top); the sponsor vouches, then the head of the cell there co-signs.
  Future<void> recommend(
    SimPhone sponsor,
    SimPhone newcomer, {
    String? slot,
    String nat = 'PL',
    int year = 1990,
  }) async {
    net.befriend(sponsor, newcomer);
    final String? code = pyr(sponsor).inviteCode(slot: slot);
    if (code == null) {
      throw StateError('${sponsor.name}: to miejsce nie jest wolne');
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
    await approveAll(sponsor.name, PyrT.admit);
    for (final SimPhone p in net.phones) {
      if (p != sponsor && pyr(p).isMember) {
        await approveAll(p.name, PyrT.admit);
      }
    }
  }

  /// Everybody without a vote yet gets it from somebody of their cell who
  /// has one ("poznaliśmy się"), until nothing changes.
  Future<void> knowAll() async {
    for (int round = 0; round < 4; round++) {
      for (final SimPhone p in net.phones) {
        final PyramidService me = pyr(p);
        final PyramidState? s = me.state;
        final String? k = me.myKey;
        if (s == null || k == null || !s.isMember(k)) {
          continue;
        }
        for (final String other in s.cellmates(k)) {
          await me.confirmKnown(other);
        }
      }
      await net.run();
    }
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

  /// Every member publishes the key private payments are sealed to
  /// ([PyrT.sealKey]), and the records go round.
  Future<void> sealKeys() async {
    for (final SimPhone p in net.phones) {
      if (p.online && pyr(p).isMember) {
        await pyr(p).ledgerDuties();
      }
    }
    await net.run();
    await sync();
  }

  /// New money for [who]: the keys published, S proposes [amount], B
  /// signs, and the emission's wait passes.
  Future<void> fund(String who, int amount, {String why = 'Start'}) async {
    await sealKeys();
    await this['S'].emit(this[who].myKey!, amount, why);
    await net.run();
    await approve('B', PyrT.emit);
    await net.advance(const Duration(hours: 25));
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

  /// What everybody who keeps the pyramid sees (more than its pinned
  /// genesis), to compare.
  Map<String, String> views() => <String, String>{
    for (final SimPhone p in net.phones)
      if (pyr(p).state != null && pyr(p).recordIds.length > 1)
        p.name: _fingerprint(pyr(p).state!),
  };

  /// What one phone sees of [s], to compare.
  static String fingerprint(PyramidState s) => _fingerprint(s);

  static String _fingerprint(PyramidState s) =>
      '${s.describe()}|${s.applied.length}|${s.term}';
}

/// The tree of [FoldWorld.make]: name, who admits them (right under
/// themself), place. Everybody votes at once (admitted by their head).
const List<(String, String?, String)> kFoldTree = <(String, String?, String)>[
  ('S', null, ''),
  ('A', 'S', '0'),
  ('B', 'S', '1'),
  ('A1', 'A', '00'),
  ('A2', 'A', '01'),
  ('B1', 'B', '10'),
  ('X', 'A1', '000'),
  ('Y', 'A1', '001'),
];

/// Signed records folded without any network: the rules alone.
final class FoldWorld {
  FoldWorld._(this.keys, this.records);

  static const int t0 = 1700000000000;
  static const int hour = 3600 * 1000;
  static const int day = 24 * hour;

  final Map<String, LedgerKeyPair> keys;
  final List<PyramidRecord> records;

  String get py => records.first.id;

  LedgerKeyPair operator [](String name) => keys[name]!;

  /// The key of [name].
  String id(String name) => keys[name]!.id;

  /// The device address [name] was admitted with.
  static String addrOf(String name) => 'addr-$name';

  /// [tree] admitted one by one after the founding, a millisecond apart;
  /// [nats] gives some of them another nationality than PL.
  static Future<FoldWorld> make({
    List<(String, String?, String)> tree = kFoldTree,
    Map<String, String> nats = const <String, String>{},
  }) async {
    final Map<String, LedgerKeyPair> keys = <String, LedgerKeyPair>{
      for (final (String name, String? _, String _) in tree)
        name: await LedgerKeyPair.generate(),
    };
    final LedgerKeyPair power = await LedgerKeyPair.generate();
    final PyramidRecord g = await signedRecord(
      PyrT.genesis,
      '',
      t0,
      <LedgerKeyPair>[power],
      <String, dynamic>{'name': 'Test', 'pk': power.id},
    );
    final List<PyramidRecord> records = <PyramidRecord>[g];
    int at = t0;
    for (final (String name, String? head, String slot) in tree) {
      final Map<String, dynamic> m = memberData(
        keys[name]!,
        name,
        nat: nats[name] ?? 'PL',
      );
      records.add(
        head == null
            ? await signedRecord(
                PyrT.found,
                g.id,
                at,
                <LedgerKeyPair>[power, keys[name]!],
                <String, dynamic>{'m': m},
              )
            : await signedRecord(
                PyrT.admit,
                g.id,
                at,
                <LedgerKeyPair>[keys[head]!, keys[name]!],
                <String, dynamic>{
                  'sp': keys[head]!.id,
                  'head': keys[head]!.id,
                  'slot': slot,
                  'm': m,
                },
              ),
      );
      at++;
    }
    return FoldWorld._(keys, records);
  }

  /// A record of [type] at [at] signed by [who] (names).
  Future<PyramidRecord> rec(
    String type,
    int at,
    List<String> who,
    Map<String, dynamic> fields,
  ) => signedRecord(type, py, at, <LedgerKeyPair>[
    for (final String n in who) keys[n]!,
  ], fields);

  /// The seal of the era open in [records] (and [more]) ending at [to],
  /// listing [ops], signed by [who] (names; by default every treasurer of
  /// the era whose key is here): what the treasurers' apps make.
  Future<PyramidRecord> seal(
    int to, {
    Iterable<PyramidRecord> more = const <PyramidRecord>[],
    Iterable<String> ops = const <String>[],
    List<String>? who,
  }) async {
    final PyramidState s = fold(more, now: to + day);
    final PyrEraToSeal e = s.eraToSeal(to)!;
    PyramidRecord r = PyramidRecord(
      body: PyrSeal.body(
        pyramid: py,
        n: e.n,
        prev: e.prev,
        from: e.from,
        to: e.to,
        set: e.set,
        next: e.next,
        ops: ops,
        changes: e.changes,
      ),
    );
    final Map<String, LedgerKeyPair> byId = <String, LedgerKeyPair>{
      for (final LedgerKeyPair k in keys.values) k.id: k,
    };
    for (final String k in who == null
        ? e.set
        : <String>[for (final String n in who) id(n)]) {
      if (byId[k] case final LedgerKeyPair pair) {
        r = await r.signedBy(pair);
      }
    }
    return r;
  }

  /// The founder's seal of its era, an hour after the founding: from then
  /// on the eight of [kFoldTree] down to the treasurers' levels sign
  /// payments (era 2: orders naming one seal, `after` 1).
  Future<PyramidRecord> sealFirst() => seal(t0 + hour);

  /// The pyramid with [more] records, at [now] (by default long after).
  PyramidState fold(
    Iterable<PyramidRecord> more, {
    int now = t0 + 400 * day,
    Map<String, int> late = const <String, int>{},
  }) => PyramidState.fold(
    py,
    <PyramidRecord>[...records, ...more],
    now: now,
    late: late,
  );
}

/// [fields] of [type] in pyramid [py] at [at], signed by [signers].
Future<PyramidRecord> signedRecord(
  String type,
  String py,
  int at,
  List<LedgerKeyPair> signers,
  Map<String, dynamic> fields,
) async {
  PyramidRecord r = PyramidRecord(
    body: <String, dynamic>{
      't': type,
      'py': py,
      'at': at,
      'by': <String>[for (final LedgerKeyPair k in signers) k.id],
      ...fields,
    },
  );
  for (final LedgerKeyPair k in signers) {
    r = await r.signedBy(k);
  }
  return r;
}

/// A member's data as an admission carries it.
Map<String, dynamic> memberData(
  LedgerKeyPair k,
  String name, {
  String nat = 'PL',
}) => <String, dynamic>{
  'k': k.id,
  'pq': k.pqId,
  'n': name,
  'nat': nat,
  'yr': 1990,
  'dc': 'x',
  'addr': FoldWorld.addrOf(name),
};

/// The court of a [FoldWorld]: one-time cards of the judges per matter, the
/// bench records that list them ([PyrT.bench]) and decisions signed by the
/// cards ([PyrT.ruled]), as the judges' phones make them.
final class FoldCourt {
  FoldCourt(this.w);

  final FoldWorld w;

  /// Every bench made so far: fold them with the rest.
  final List<PyramidRecord> benches = <PyramidRecord>[];

  final Map<String, PyramidRecord> _benchOf = <String, PyramidRecord>{};
  final Map<String, LedgerKeyPair> _cards = <String, LedgerKeyPair>{};

  /// [name]'s card in matter [of].
  Future<LedgerKeyPair> card(String of, String name) async =>
      _cards['$of|$name'] ??= await LedgerKeyPair.generate();

  /// The bench of [of] for the judges [ring] (names) dated [at]: the cards
  /// of [withCards] (by default every judge), signed by [signers] (by
  /// default every judge).
  Future<PyramidRecord> bench(
    String of,
    int at,
    List<String> ring, {
    List<String>? signers,
    List<String>? withCards,
  }) async {
    final bool plain = signers == null && withCards == null;
    final String key = '$of|${(List<String>.of(ring)..sort()).join(',')}';
    final PyramidRecord? had = _benchOf[key];
    if (had != null && plain) {
      return had;
    }
    PyramidRecord r = PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.bench,
        'py': w.py,
        'at': at,
        'by': <String>[for (final String n in ring) w.id(n)]..sort(),
        'of': of,
        'toks': <String>[
          for (final String n in withCards ?? ring)
            (await card(of, n)).hybridId,
        ]..sort(),
      },
    );
    for (final String n in signers ?? ring) {
      r = await r.signedBy(w[n]);
    }
    if (plain) {
      _benchOf[key] = r;
    }
    benches.add(r);
    return r;
  }

  /// A decision of [type] in matter [of] (dated [since]; its bench comes a
  /// millisecond later) at [at], signed by the cards of [judges] on the
  /// bench of [ring] (by default the judges), saying it needs [q] of them.
  Future<PyramidRecord> rule(
    String type,
    String of,
    int since,
    int at,
    List<String> judges, {
    List<String>? ring,
    int q = 1,
    Map<String, dynamic> fields = const <String, dynamic>{},
  }) async {
    final List<String> all = ring ?? judges;
    await bench(of, since + 1, all);
    PyramidRecord r = PyramidRecord(
      body: <String, dynamic>{
        't': type,
        'py': w.py,
        'at': at,
        'by': <String>[for (final String n in all) (await card(of, n)).id]
          ..sort(),
        'q': q,
        ...fields,
      },
    );
    for (final String n in judges) {
      r = await r.signedBy(await card(of, n));
    }
    return r;
  }
}
