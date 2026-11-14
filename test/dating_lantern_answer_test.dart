import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/dating/dating_crypto.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Answers to a lantern: one is answered per lantern for a friend asking
// from one step away, and every answer was given once. An answer lost on
// the way (or the lantern's keys lost) left the two people unmatched for
// the week, since the question was never asked again, and a question
// asked again got nothing. Now an unanswered question goes again (twice
// at most), and the same question gets the same answer again (twice at
// most): nothing new for anyone, and only the asker can open it. Several
// people asking through one friend and an account's second device were
// never limited to one answer; that stays so.

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  final Map<String, Set<String>> friends = <String, Set<String>>{};
  int clock = 1000000;

  /// Messages that never arrive: true drops one.
  bool Function(_Phone from, _Phone to, Map<String, dynamic> payload)? lose;

  void link(_Phone a, _Phone b) {
    (friends[a.address] ??= <String>{}).add(b.address);
    (friends[b.address] ??= <String>{}).add(a.address);
  }
}

final class _Phone implements EventHost {
  _Phone(this.net, this.name)
    : address = PeerShareCodec.normalizeAddress(
        '200::${(0xc0 + net.phones.length).toRadixString(16)}',
      ) {
    net.phones[address] = this;
    service = DatingService(
      host: this,
      disk: disk,
      now: () => net.clock,
      decoyFetchShare: 0,
    );
  }

  final _Net net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late DatingService service;
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final _Phone? other = net.phones[to];
    if (other == null || (net.lose?.call(this, other, payload) ?? false)) {
      return;
    }
    other.received.add(payload);
    await other.service.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  List<String> friends() => (net.friends[address] ?? const <String>{}).toList();

  @override
  bool isFriend(String a) => net.friends[address]?.contains(a) ?? false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net.phones[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  Future<void> date(
    String name,
    DatingGender gender,
    Set<DatingGender> wants,
  ) async {
    await service.load();
    await service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = name
        ..gender = gender
        ..wants = DatingWants(genders: wants);
    });
    await service.maybePublish(force: true);
  }

  /// Names of the profiles waiting for a decision here.
  Set<String> names() => <String>{
    for (final SeenProfile s in service.toDecide) s.profile.name,
  };
}

/// A back message carrying a sealed box (an answer, a profile…), not the
/// lantern's keys.
bool _sealed(Map<String, dynamic> p) =>
    p['type'] == DatingTypes.back && (p['box'] as Map)['lkr'] == null;

bool _keys(Map<String, dynamic> p) =>
    p['type'] == DatingTypes.back && (p['box'] as Map)['lkr'] != null;

void main() {
  test('an answer lost on the way: the question goes again later and the '
      'same answer comes, so the two still meet', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    net.link(ania, darek);
    await darek.date('Darek', DatingGender.man, <DatingGender>{
      DatingGender.woman,
    });
    // Ania's first answer to Darek's question never arrives.
    int lost = 0;
    net.lose = (_Phone from, _Phone to, Map<String, dynamic> p) =>
        from == ania && to == darek && _sealed(p) && lost++ == 0;
    await ania.date('Ania', DatingGender.woman, <DatingGender>{
      DatingGender.man,
    });
    expect(lost, greaterThan(0));
    expect(darek.names(), isEmpty);

    // Not at once: an answer may still be on its way.
    net.clock += const Duration(hours: 1).inMilliseconds;
    await darek.service.maybePublish();
    expect(darek.names(), isEmpty);

    net.clock += kDatingAskAgainAfter.inMilliseconds;
    await darek.service.maybePublish();
    expect(darek.names(), <String>{'Ania'});
  });

  test(
    'the lantern\'s keys lost on the way: they are asked for again',
    () async {
      final _Net net = _Net();
      final _Phone ania = _Phone(net, 'ania');
      final _Phone darek = _Phone(net, 'darek');
      net.link(ania, darek);
      await darek.date('Darek', DatingGender.man, <DatingGender>{
        DatingGender.woman,
      });
      int lost = 0;
      net.lose = (_Phone from, _Phone to, Map<String, dynamic> p) =>
          from == ania && to == darek && _keys(p) && lost++ == 0;
      await ania.date('Ania', DatingGender.woman, <DatingGender>{
        DatingGender.man,
      });
      expect(darek.names(), isEmpty);
      net.clock += kDatingAskAgainAfter.inMilliseconds + 1;
      await darek.service.maybePublish();
      expect(darek.names(), <String>{'Ania'});
    },
  );

  test('a question nobody answers goes again at most twice, and not after '
      'an answer came', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    net.link(ania, darek);
    await darek.date('Darek', DatingGender.man, <DatingGender>{
      DatingGender.woman,
    });
    // Ania's phone answers nothing at all.
    net.lose = (_Phone from, _Phone to, Map<String, dynamic> p) =>
        from == ania && to == darek && p['type'] == DatingTypes.back;
    await ania.date('Ania', DatingGender.woman, <DatingGender>{
      DatingGender.man,
    });
    int questions() => ania.received
        .where((Map<String, dynamic> p) => p['type'] == DatingTypes.back)
        .length;
    expect(questions(), 1);
    for (int i = 0; i < 6; i++) {
      net.clock += kDatingAskAgainAfter.inMilliseconds + 1;
      await darek.service.maybePublish();
    }
    expect(questions(), kDatingAskTries);

    // Answered: never asked again.
    final _Net net2 = _Net();
    final _Phone ola = _Phone(net2, 'ola');
    final _Phone emil = _Phone(net2, 'emil');
    net2.link(ola, emil);
    await emil.date('Emil', DatingGender.man, <DatingGender>{
      DatingGender.woman,
    });
    await ola.date('Ola', DatingGender.woman, <DatingGender>{DatingGender.man});
    expect(emil.names(), <String>{'Ola'});
    final int before = ola.received.length;
    for (int i = 0; i < 4; i++) {
      net2.clock += kDatingAskAgainAfter.inMilliseconds + 1;
      await emil.service.maybePublish();
    }
    expect(
      ola.received
          .sublist(before)
          .where((Map<String, dynamic> p) => p['type'] == DatingTypes.back),
      isEmpty,
    );
  });

  test('the same question again gets the same answer, a few times at most; '
      'another key from the same friend gets none; a copy replayed by '
      'someone else opens for nobody but the asker', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone eve = _Phone(net, 'eve');
    final _Phone ola = _Phone(net, 'ola');
    net
      ..link(ania, eve)
      ..link(ania, ola);
    // Eve's and Ola's phones run no dating service of their own here: the
    // questions are made by hand, as a modified app would.
    await ania.date('Ania', DatingGender.woman, <DatingGender>{
      DatingGender.man,
    });
    final String lanternId =
        eve.received.lastWhere(
              (Map<String, dynamic> p) => p['type'] == DatingTypes.lantern,
            )['id']
            as String;
    // Eve's app asks for the lantern's keys, then asks with its key.
    int marks = 0;
    Future<List<Map<String, dynamic>>> sendBack(
      _Phone by,
      Map<String, dynamic> box,
    ) async {
      final int before = by.received.length;
      await by.send(ania.address, <String, dynamic>{
        'type': DatingTypes.back,
        'to': lanternId,
        'm': 'mark-${marks++}',
        'box': box,
        'ttl': 7,
        'n': 0,
      });
      return <Map<String, dynamic>>[
        for (final Map<String, dynamic> m in by.received.sublist(before))
          if (m['type'] == DatingTypes.back) m,
      ];
    }

    final Map<dynamic, dynamic> keys =
        ((await sendBack(eve, const <String, dynamic>{'lk': 1})).single['box']
                as Map)['lkr']
            as Map<dynamic, dynamic>;
    final Uint8List x = decodeRelayKey(keys['k'])!;
    final Uint8List pq = decodeHybridPublicKey(keys['q'])!;
    final RelayIdentity mine = await RelayIdentity.generateHybrid();
    final Map<String, String> question = await DatingBox.seal(
      me: mine,
      recipient: x,
      recipientPq: pq,
      payload: <String, dynamic>{
        'k': 'match',
        'id': lanternId,
        'pq': base64Url.encode(mine.pqPublicKey!),
      },
    );
    final List<Map<String, dynamic>> answers = <Map<String, dynamic>>[];
    for (int i = 0; i < 6; i++) {
      for (final Map<String, dynamic> b in await sendBack(eve, question)) {
        answers.add((await DatingBox.open(me: mine, box: b['box'] as Map))!.$2);
      }
    }
    expect(answers, hasLength(1 + kDatingMatchRepeats));
    for (final Map<String, dynamic> a in answers) {
      expect(a['a'], answers.first['a']);
      expect(a['n'], answers.first['n']);
      expect(a['o'], answers.first['o']);
    }

    // Another key from Eve: nothing (one question per lantern for a friend
    // one step away, whatever key).
    final RelayIdentity other = await RelayIdentity.generateHybrid();
    expect(
      await sendBack(
        eve,
        await DatingBox.seal(
          me: other,
          recipient: x,
          recipientPq: pq,
          payload: <String, dynamic>{
            'k': 'match',
            'id': lanternId,
            'pq': base64Url.encode(other.pqPublicKey!),
          },
        ),
      ),
      isEmpty,
    );

    // Eve's recorded question replayed by Ola: what comes back is sealed for
    // Eve's key, Ola's phone cannot open it.
    final RelayIdentity olaKey = await RelayIdentity.generateHybrid();
    for (final Map<String, dynamic> b in await sendBack(ola, question)) {
      expect(await DatingBox.open(me: olaKey, box: b['box'] as Map), isNull);
    }
  });

  test('several people answering one lantern through one friend all get an '
      'answer, and an account\'s second device too', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone darek2 = _Phone(net, 'darek (laptop)');
    final List<_Phone> men = <_Phone>[
      for (int i = 0; i < 5; i++) _Phone(net, 'man $i'),
    ];
    net
      ..link(ania, bob)
      // Darek's phone is Ania's friend; his laptop, another device of the
      // same account, gets her lantern only through Bob.
      ..link(ania, darek)
      ..link(bob, darek2);
    for (final _Phone m in men) {
      net.link(bob, m);
    }
    await bob.service.load();
    for (final _Phone m in <_Phone>[darek, darek2, ...men]) {
      await m.date('Darek', DatingGender.man, <DatingGender>{
        DatingGender.woman,
      });
    }
    await ania.date('Ania', DatingGender.woman, <DatingGender>{
      DatingGender.man,
    });
    for (final _Phone m in <_Phone>[darek, darek2, ...men]) {
      expect(m.names(), <String>{'Ania'}, reason: m.name);
    }
  });
}
