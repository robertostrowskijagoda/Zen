import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_root.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import 'support/pyramid_world.dart';

/// What a phone outside the pyramid shows of a verdict: it holds none of
/// the pyramid's records, so it cannot tell the court's one-time cards
/// from any key. A verdict there is the word of the friends who passed it
/// on, shown as theirs; an overturning a friend passes on takes back only
/// that friend's word.
void main() {
  late SimNetwork net;
  late SimPhone member;
  late SimPhone liar;
  late SimPhone accusedPhone;
  late SimPhone me;
  late PyramidService r;

  setUp(() async {
    net = SimNetwork();
    member = net.phone('M');
    liar = net.phone('L');
    accusedPhone = net.phone('K');
    me = net.phone('R');
    net
      ..befriend(member, me)
      ..befriend(liar, me)
      ..befriend(accusedPhone, me);
    r = PyramidService(host: me, disk: MemoryLedgerDisk(), now: () => net.now);
    me.attach(r.handle);
    await r.load();
  });

  Future<void> pass(
    SimPhone from,
    PyramidRecord v, {
    List<PyramidRecord>? ov,
  }) async {
    await from.send(me.address, <String, dynamic>{
      'type': PyramidTypes.national,
      'vd': <Map<String, dynamic>>[
        <String, dynamic>{
          'r': v.toJson(),
          'n': 'Kasia',
          if (ov != null)
            'ov': <Map<String, dynamic>>[
              for (final PyramidRecord x in ov) x.toJson(),
            ],
          // A frame cannot say who else stands by it.
          'by': <String, int>{member.address: net.now},
        },
      ],
    });
    await net.run();
  }

  Future<PyramidRecord> verdict(LedgerKeyPair accused) async => signedRecord(
    PyrT.verdict,
    zenPyramidRoot!.id,
    net.now,
    <LedgerKeyPair>[await LedgerKeyPair.generate()],
    <String, dynamic>{
      'case': 'c-${accused.id.substring(0, 6)}',
      'guilty': true,
      'k': accused.id,
      'type': 'fraud',
      'text': 'Oszust, nie pożyczać',
      'q': 1,
      'addrs': <String>[accusedPhone.address],
    },
  );

  /// The accused's own appeal, "accepted" by a key made on the spot.
  Future<List<PyramidRecord>> selfOverturn(
    PyramidRecord v,
    LedgerKeyPair accused,
  ) async {
    final PyramidRecord appeal = await signedRecord(
      PyrT.appeal,
      zenPyramidRoot!.id,
      net.now,
      <LedgerKeyPair>[accused],
      <String, dynamic>{'of': v.id, 'why': 'Nie'},
    );
    final PyramidRecord ok = await signedRecord(
      PyrT.appealAnswer,
      zenPyramidRoot!.id,
      net.now + 1,
      <LedgerKeyPair>[await LedgerKeyPair.generate()],
      <String, dynamic>{'appeal': appeal.id, 'ok': true, 'q': 1},
    );
    return <PyramidRecord>[appeal, ok];
  }

  test('a made-up verdict shows only as the word of the friend who made it '
      'up, named, and not once that friend is no longer a friend', () async {
    expect(r.isMember, isFalse);
    final LedgerKeyPair victim = await LedgerKeyPair.generate();
    final PyramidRecord fake = await verdict(victim);
    await pass(liar, fake);
    final List<PyrVerdictView> shown = r.verdictsAt(accusedPhone.address);
    expect(shown, hasLength(1));
    expect(shown.single.by, <String>['L'], reason: 'the frame named M too');

    net.unfriend(liar, me);
    expect(r.verdictsAt(accusedPhone.address), isEmpty);
  });

  test('the accused hides no verdict a member friend passed on: its '
      'self-made overturning takes back no word but its own', () async {
    final LedgerKeyPair accused = await LedgerKeyPair.generate();
    final PyramidRecord v = await verdict(accused);
    await pass(member, v);
    expect(r.verdictsAt(accusedPhone.address).single.by, <String>['M']);

    await pass(accusedPhone, v, ov: await selfOverturn(v, accused));
    final List<PyrVerdictView> after = r.verdictsAt(accusedPhone.address);
    expect(after, hasLength(1));
    expect(after.single.by, <String>['M']);

    // Kept so across a restart.
    final PyramidService again = PyramidService(
      host: me,
      disk: r.disk,
      now: () => net.now,
    );
    await again.load();
    expect(again.verdictsAt(accusedPhone.address).single.by, <String>['M']);

    // The member friend itself passes the overturning on: then nobody
    // stands by it any more.
    await pass(member, v, ov: await selfOverturn(v, accused));
    expect(r.verdictsAt(accusedPhone.address), isEmpty);
  });

  test('two friends pass a verdict on: both are named, and one friend\'s '
      'overturning leaves the other\'s word', () async {
    final LedgerKeyPair accused = await LedgerKeyPair.generate();
    final PyramidRecord v = await verdict(accused);
    await pass(member, v);
    await pass(liar, v);
    expect(r.verdictsAt(accusedPhone.address).single.by, <String>['L', 'M']);
    await pass(liar, v, ov: await selfOverturn(v, accused));
    expect(r.verdictsAt(accusedPhone.address).single.by, <String>['M']);
  });
}
