import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_root.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import '../tool/zen_pyramid.dart' as pyramid_tool;
import '../tool/zen_sig.dart' as sig_tool;
import 'support/pyramid_world.dart';

/// The original pyramid as the founder starts it: a genesis made by
/// `tool/zen_pyramid.dart genesis` (its power key anchored with its ML-DSA
/// half), founded in the app by pasting the key's seed.
void main() {
  setUpAll(() => sig_tool.useToolSigner(hybridSigner));
  tearDownAll(() => sig_tool.useToolSigner(null));

  Future<({PyramidRoot root, Uint8List seed})> original() async {
    final Uint8List seed = Uint8List.fromList(
      List<int>.generate(32, (int i) => (i * 7 + 3) & 0xff),
    );
    final ({Map<String, dynamic> record, String id, String pk}) g =
        await pyramid_tool.makeGenesis(
          seed,
          name: 'Zen',
          at: 1700000000000 - 60000,
        );
    final String json = jsonEncode(g.record);
    // What `zen_pyramid.dart check` says of the pin.
    expect(await pyramid_tool.verifyGenesis(json), g.id);
    final PyramidRoot root = PyramidRoot.parse(json)!;
    expect(root.id, g.id);
    expect(root.powerKey, g.pk);
    expect(root.powerSeed, isNull);
    return (root: root, seed: seed);
  }

  test('the founder founds it with the power key, others join', () async {
    final ({PyramidRoot root, Uint8List seed}) o = await original();
    final PyramidWorld w = PyramidWorld(root: o.root);
    final SimPhone s = w.add('S');
    final SimPhone a = w.add('A');
    final SimPhone b = w.add('B');
    final PyramidService founder = w.pyr(s);
    await founder.load();
    expect(founder.canFound, isTrue);
    expect(founder.foundNeedsKey, isTrue);

    // Without the key, or with another one, nobody founds it.
    expect(
      await founder.found(myName: 'S', nat: 'PL', birthYear: 1980, gender: 'm'),
      isNull,
    );
    expect(
      await founder.found(
        myName: 'S',
        nat: 'PL',
        birthYear: 1980,
        gender: 'm',
        powerSecret: b64(Uint8List(32)),
      ),
      isNull,
    );
    expect(founder.isMember, isFalse);

    // The last line of the key file the tool wrote.
    expect(
      await founder.found(
        myName: 'S',
        nat: 'PL',
        birthYear: 1980,
        gender: 'm',
        powerSecret: '${b64(o.seed)}\n',
      ),
      o.root.id,
    );
    expect(founder.isMember, isTrue);
    expect(founder.holdsPowerKey, isTrue);
    expect(founder.state!.head, founder.myKey);
    expect(founder.state!.powerKey, o.root.powerKey);
    expect(founder.canFound, isFalse);

    await w.join(s, a);
    await w.join(s, b, nat: 'DE');
    await w.sync();
    for (final SimPhone p in <SimPhone>[a, b]) {
      final PyramidService m = w.pyr(p);
      expect(m.isMember, isTrue, reason: p.name);
      expect(m.root!.id, o.root.id);
      expect(m.state!.head, founder.myKey);
      expect(m.state!.powerKey, o.root.powerKey);
      expect(m.state!.members, hasLength(3));
    }
  });

  test('a phone keeps only the pinned pyramid', () async {
    final ({PyramidRoot root, Uint8List seed}) o = await original();
    // The test pyramid's founding does not count in the original one.
    final PyramidWorld test = PyramidWorld();
    final SimPhone t = test.add('T');
    await test.pyr(t).load();
    await test
        .pyr(t)
        .found(myName: 'T', nat: 'PL', birthYear: 1980, gender: 'm');
    expect(test.pyr(t).isMember, isTrue);
    expect(test.pyr(t).root!.id, isNot(o.root.id));

    final PyramidWorld w = PyramidWorld(root: o.root);
    final SimPhone s = w.add('S');
    await w.pyr(s).load();
    expect(w.pyr(s).isMember, isFalse);
    expect(w.pyr(s).canFound, isTrue);
  });
}
