import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_national.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import 'support/pyramid_world.dart';

/// The national section read by everybody whose profile shows the
/// nationality, members of the pyramid or not (§9, §22.2): members pass its
/// posts on to such friends; only members comment.
void main() {
  bool national(Map<String, dynamic> m) => m['type'] == PyramidTypes.national;

  /// A reader outside any pyramid, friend of [friend] only, with [nats] in
  /// its profile (signed records come from a key made up here).
  Future<
    ({
      SimNetwork net,
      SimPhone friend,
      SimPhone stranger,
      PyramidService reader,
    })
  >
  readerAlone({List<String> nats = const <String>['DE']}) async {
    final SimNetwork net = SimNetwork();
    final SimPhone friend = net.phone('F');
    final SimPhone me = net.phone('R');
    final SimPhone stranger = net.phone('X');
    net.befriend(friend, me);
    final PyramidService reader = PyramidService(
      host: me,
      disk: MemoryLedgerDisk(),
      now: () => net.now,
      myNationalities: () => nats,
    );
    me.attach(reader.handle);
    await reader.load();
    return (net: net, friend: friend, stranger: stranger, reader: reader);
  }

  Future<PyramidRecord> natRecord(
    LedgerKeyPair k, {
    required int at,
    String type = PyrT.natPost,
    String nat = 'DE',
    String text = 'Hallo zusammen',
  }) => PyramidRecord(
    body: <String, dynamic>{
      't': type,
      'py': 'py-elsewhere',
      'at': at,
      'by': <String>[k.id],
      'nat': nat,
      'text': text,
      'lvl': 2,
    },
  ).signedBy(k);

  Future<void> pass(
    SimNetwork net,
    SimPhone from,
    SimPhone to,
    List<PyramidRecord> rs,
  ) async {
    await from.send(to.address, <String, dynamic>{
      'type': PyramidTypes.national,
      'ps': <Map<String, dynamic>>[
        for (final PyramidRecord r in rs)
          <String, dynamic>{
            'r': r.toJson(),
            'm': <String, dynamic>{'n': 'Kasia', 'd': 5, 'b': 12, 'l': true},
          },
      ],
    });
    await net.run();
  }

  test('members pass the section on to friends outside the pyramid whose '
      'profile shows that nationality; it is read there, not kept as a '
      'pyramid record', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final LedgerDisk oDisk = MemoryLedgerDisk();
    // O: DE in the profile, friend of B1 (a DE member). P: PL only, friend
    // of B1. Q: DE, friend of A2 (a PL member).
    final SimPhone o = w.add('O', disk: oDisk);
    final SimPhone p = w.add('P');
    final SimPhone q = w.add('Q');
    w.profileNationalities
      ..['O'] = <String>['DE']
      ..['P'] = <String>['PL']
      ..['Q'] = <String>['DE'];
    for (final SimPhone x in <SimPhone>[o, p, q]) {
      await w.pyr(x).load();
    }
    w.net
      ..befriend(w.net['B1'], o)
      ..befriend(w.net['B1'], p)
      ..befriend(w.net['A2'], q);

    final PyramidRecord? np = await w['B1'].natPost('Hallo zusammen');
    await w.net.run();
    expect(np, isNotNull);
    expect(w['S'].state!.natPosts.keys, contains(np!.id));

    final List<PyrNationalPost> seen = w['O'].nationalSection('DE');
    expect(seen.map((PyrNationalPost x) => x.text), <String>['Hallo zusammen']);
    expect(seen.single.name, 'B1');
    expect(seen.single.author, w['B1'].myKey);
    expect(seen.single.level, w['B1'].state!.levelOf(w['B1'].myKey!));
    expect(seen.single.depth, w['B1'].state!.depth);
    expect(w['O'].isMember, isFalse);
    expect(w['O'].keeps(np.id), isFalse, reason: 'read-only: no record');
    expect(w['O'].state, isNull);
    expect(
      w['Q'].nationalSection('DE').map((PyrNationalPost x) => x.id),
      <String>[np.id],
      reason: 'any member passes it on, not only one of that nationality',
    );
    expect(w['P'].nationalSection('DE'), isEmpty);
    expect(
      w.net['B1'].outbox.where(national),
      hasLength(1),
      reason: 'to O only: P shows another nationality, B and A2 are inside',
    );

    // Somebody who comes later gets what is there with the hello, once.
    final SimPhone l = w.add('L');
    w.profileNationalities['L'] = <String>['DE'];
    await w.pyr(l).load();
    w.net.befriend(w.net['B'], l);
    expect(w['L'].nationalSection('DE'), isEmpty);
    await w['L'].greet();
    await w.net.run();
    expect(
      w['L'].nationalSection('DE').map((PyrNationalPost x) => x.id),
      <String>[np.id],
    );
    final int sent = w.net['B'].outbox.where(national).length;
    await w['L'].greet();
    await w.net.run();
    expect(
      w.net['B'].outbox.where(national),
      hasLength(sent),
      reason: 'nothing newer than what L has',
    );

    // Kept over a restart.
    final PyramidService again = PyramidService(
      host: o,
      disk: oDisk,
      identitySeed: w.seedOf(oDisk),
      now: () => w.net.now,
      myNationalities: () => const <String>['DE'],
    );
    await again.load();
    expect(
      again.nationalSection('DE').map((PyrNationalPost x) => x.id),
      <String>[np.id],
    );

    // Once O keeps the pyramid's records (looking at it), the section is
    // read from them: the same post, once.
    await w['B1'].greet(to: <String>[o.address]);
    await w.net.run();
    await w['O'].fetchFriendsPyramids();
    await w.net.run();
    expect(w['O'].keeps(np.id), isTrue);
    final List<PyrNationalPost> fromRecords = w['O'].nationalSection('DE');
    expect(fromRecords.map((PyrNationalPost x) => x.id), <String>[np.id]);
    expect(fromRecords.single.from, '');
    expect(w['O'].isMember, isFalse);
  });

  test('what a friend passes on is checked: a friend, the signature, the '
      'kind, the profile nationality, the size, the time', () async {
    final (
      :SimNetwork net,
      :SimPhone friend,
      :SimPhone stranger,
      :PyramidService reader,
    ) = await readerAlone();
    final LedgerKeyPair k = await LedgerKeyPair.generate();
    final PyramidRecord good = await natRecord(k, at: net.now);
    final PyramidRecord forged = PyramidRecord(
      body: <String, dynamic>{...good.body, 'text': 'Gefälscht'},
      sigs: good.sigs,
    );
    final PyramidRecord politics = await natRecord(
      k,
      at: net.now,
      type: PyrT.post,
    );
    final PyramidRecord polish = await natRecord(k, at: net.now, nat: 'PL');
    final PyramidRecord big = await natRecord(
      k,
      at: net.now,
      text: 'x' * (kPyrNationalPostBytes + 1),
    );
    final PyramidRecord ahead = await natRecord(
      k,
      at: net.now + 2 * kPyrMaxSkewMs,
    );
    final SimPhone me = net['R'];

    await pass(net, stranger, me, <PyramidRecord>[good]);
    expect(reader.nationalSection('DE'), isEmpty, reason: 'not a friend');

    await pass(net, friend, me, <PyramidRecord>[
      forged,
      politics,
      polish,
      big,
      ahead,
      good,
    ]);
    final List<PyrNationalPost> seen = reader.nationalSection('DE');
    expect(seen.map((PyrNationalPost x) => x.id), <String>[good.id]);
    expect(seen.single.author, k.id);
    expect(seen.single.name, 'Kasia');
    expect(seen.single.lead, isTrue);
    expect(seen.single.branch, 12);
    expect(seen.single.from, friend.address);
    expect(reader.nationalSection('PL'), isEmpty);
    expect(reader.keeps(good.id), isFalse);
  });

  test('at most a batch per frame and the newest few per nationality are '
      'kept', () async {
    final (
      :SimNetwork net,
      :SimPhone friend,
      stranger: _,
      :PyramidService reader,
    ) = await readerAlone();
    final LedgerKeyPair k = await LedgerKeyPair.generate();
    final int start = net.now;
    int n = 0;
    Future<List<PyramidRecord>> next(int count) async => <PyramidRecord>[
      for (int i = 0; i < count; i++)
        await natRecord(k, at: start + n, text: 'post ${n++}'),
    ];

    await pass(net, friend, net['R'], await next(kPyrNationalBatch + 5));
    expect(reader.nationalSection('DE'), hasLength(kPyrNationalBatch));

    for (int round = 0; round < 4; round++) {
      await pass(net, friend, net['R'], await next(kPyrNationalBatch));
    }
    final List<PyrNationalPost> kept = reader.nationalSection('DE');
    expect(kept, hasLength(kPyrNationalKept));
    expect(
      kept.map((PyrNationalPost x) => x.text),
      contains('post ${n - 1}'),
      reason: 'the newest stay',
    );
    expect(
      kept.map((PyrNationalPost x) => x.text),
      isNot(contains('post 0')),
      reason: 'the oldest go',
    );
  });

  testWidgets('the join view leads to the section, read-only', (
    WidgetTester tester,
  ) async {
    late PyramidService reader;
    late PyramidRecord good;
    await tester.runAsync(() async {
      final ({
        SimNetwork net,
        SimPhone friend,
        SimPhone stranger,
        PyramidService reader,
      })
      alone = await readerAlone();
      reader = alone.reader;
      final LedgerKeyPair k = await LedgerKeyPair.generate();
      good = await natRecord(k, at: alone.net.now);
      await pass(alone.net, alone.friend, alone.net['R'], <PyramidRecord>[
        good,
      ]);
    });
    expect(reader.nationalSection('DE'), hasLength(1));

    Widget entry(List<String> nats) => MaterialApp(
      theme: ZenTheme.dark(),
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            PyramidNationalEntry(pyr: reader, nationalities: nats),
          ],
        ),
      ),
    );

    await tester.pumpWidget(entry(const <String>[]));
    expect(
      find.byKey(const Key('pyr-national-no-nationality')),
      findsOneWidget,
    );

    await tester.pumpWidget(entry(const <String>['DE']));
    final Finder tile = find.byKey(const Key('pyr-national-read-DE'));
    expect(tile, findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pyr-national-reader')), findsOneWidget);
    expect(find.byKey(Key('pyr-national-post-${good.id}')), findsOneWidget);
    expect(find.text('Hallo zusammen'), findsOneWidget);
    expect(find.text('Kasia'), findsOneWidget);
    expect(find.textContaining('Komentuj'), findsNothing);
  });
}
