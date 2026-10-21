import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/census/census_providers.dart';
import 'package:zen/src/features/census/network_census.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

CensusSketch _sketchOf(String prefix, int count) {
  final CensusSketch sketch = CensusSketch();
  for (int i = 0; i < count; i++) {
    sketch.add(utf8.encode('$prefix-$i'));
  }
  return sketch;
}

Matcher _near(num value, double share) =>
    closeTo(value.toDouble(), value * share);

/// Two phones that are friends, wired to each other, with one clock.
final class _Pair {
  _Pair() {
    a = _census('200::a', 1);
    b = _census('200::b', 2);
  }

  int now = DateTime.utc(2026, 10, 15).millisecondsSinceEpoch;
  late final NetworkCensus a;
  late final NetworkCensus b;
  final MemoryLedgerDisk diskA = MemoryLedgerDisk();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  NetworkCensus _census(String address, int fill) {
    final String other = address == '200::a' ? '200::b' : '200::a';
    return NetworkCensus(
      disk: fill == 1 ? diskA : MemoryLedgerDisk(),
      send: (String to, Map<String, dynamic> payload) async {
        sent.add(payload);
        final NetworkCensus target = PeerShareCodec.addressesEqual(to, '200::a')
            ? a
            : b;
        await target.onFrame(
          SignalTransportFrame(
            from: address,
            payload: payload,
            receivedAtMillis: now,
          ),
        );
      },
      isFriend: (String x) => PeerShareCodec.addressesEqual(x, other),
      secret: () => Uint8List.fromList(List<int>.filled(32, fill)),
      now: () => now,
    );
  }

  Future<void> ping(NetworkCensus to, String from) => to.onFrame(
    SignalTransportFrame(
      from: from,
      payload: const <String, dynamic>{'type': 'ping'},
      receivedAtMillis: now,
    ),
  );
}

void main() {
  group('CensusSketch', () {
    test('estimates distinct identifiers within a few percent', () {
      expect(_sketchOf('id', 10).estimate().round(), 10);
      expect(_sketchOf('id', 1000).estimate(), _near(1000, 0.05));
      expect(_sketchOf('id', 10000).estimate(), _near(10000, 0.05));
      final CensusSketch twice = _sketchOf('id', 10000)
        ..merge(_sketchOf('id', 10000));
      expect(twice.estimate(), _near(10000, 0.05), reason: 'no double count');
      expect(CensusSketch().estimate(), 0);
    });

    test('merging is the union', () {
      final CensusSketch a = _sketchOf('a', 5000);
      expect(a.merge(_sketchOf('b', 5000)), isTrue);
      expect(a.estimate(), _near(10000, 0.05));
      expect(a.merge(_sketchOf('a', 5000)), isFalse);
    });

    test('encodes in 2048 characters and refuses anything else', () {
      final CensusSketch a = _sketchOf('a', 3000);
      final String encoded = a.encode();
      expect(encoded, hasLength(kCensusRegisters));
      expect(CensusSketch.decode(encoded)!.registers, a.registers);
      expect(CensusSketch.decode('short'), isNull);
      expect(CensusSketch.decode(12), isNull);
      expect(CensusSketch.decode('!' * kCensusRegisters), isNull);
    });

    test('one forged source cannot inflate three or more', () {
      final CensusSketch own = _sketchOf('n', 1000);
      final CensusSketch friend = _sketchOf('n', 1200);
      final CensusSketch forged = CensusSketch();
      forged.registers.fillRange(0, kCensusRegisters, kCensusMaxRank);
      final double robust = CensusSketch.combine(<CensusSketch>[
        own,
        friend,
        forged,
      ]).estimate();
      expect(robust, _near(1200, 0.06));
      // With only two sources the plain maximum is all there is.
      expect(
        CensusSketch.combine(<CensusSketch>[own, friend]).estimate(),
        _near(1200, 0.06),
      );
    });
  });

  test('the month number', () {
    expect(censusEpoch(DateTime.utc(2024)), 0);
    expect(censusEpoch(DateTime.utc(2026, 10, 15)), 33);
  });

  test(
    'friends exchange sketches, at most hourly, and count each other',
    () async {
      final _Pair pair = _Pair();
      await pair.a.load();
      await pair.b.load();
      expect(pair.a.view.estimate, 1);
      expect(pair.a.view.epoch, 33);

      await pair.ping(pair.a, '200::b');
      expect(pair.sent, hasLength(1));
      expect(pair.sent.single['type'], kCensusType);
      expect(pair.sent.single['e'], 33);
      expect(pair.b.view.estimate, 2);
      await pair.ping(pair.b, '200::a');
      expect(pair.a.view.estimate, 2);

      // Within the hour nothing goes again; after it, only when changed.
      final int sentBefore = pair.sent.length;
      await pair.ping(pair.a, '200::b');
      expect(pair.sent.length, sentBefore);
      pair.now += const Duration(hours: 2).inMilliseconds;
      await pair.ping(pair.a, '200::b');
      expect(pair.sent.length, sentBefore + 1, reason: 'A learnt B since');
      await pair.ping(pair.a, '200::b');
      expect(pair.sent.length, sentBefore + 1);

      // Strangers neither get nor give anything.
      await pair.a.onFrame(
        SignalTransportFrame(
          from: '200::e',
          payload: <String, dynamic>{
            'type': kCensusType,
            'e': 33,
            'c': _sketchOf('x', 500).encode(),
          },
          receivedAtMillis: pair.now,
        ),
      );
      expect(pair.a.view.estimate, 2);
    },
  );

  test('a new month starts afresh but shows the larger number', () async {
    final _Pair pair = _Pair();
    await pair.a.load();
    await pair.b.load();
    await pair.ping(pair.a, '200::b');
    await pair.ping(pair.b, '200::a');
    expect(pair.a.view.estimate, 2);

    pair.now = DateTime.utc(2026, 11, 2).millisecondsSinceEpoch;
    final CensusView next = pair.a.view;
    expect(next.epoch, 34);
    expect(next.estimate, 2, reason: 'last month still counts');
    pair.now = DateTime.utc(2027, 1, 2).millisecondsSinceEpoch;
    expect(pair.a.view.estimate, 1, reason: 'two months on, only this account');
  });

  test('the sketches survive a restart', () async {
    final _Pair pair = _Pair();
    await pair.a.load();
    await pair.b.load();
    await pair.ping(pair.b, '200::a');
    expect(pair.a.view.estimate, 2);
    final NetworkCensus again = NetworkCensus(
      disk: pair.diskA,
      send: (String to, Map<String, dynamic> p) async {},
      isFriend: (String x) => false,
      secret: () => Uint8List.fromList(List<int>.filled(32, 1)),
      now: () => pair.now,
    );
    await again.load();
    expect(again.view.estimate, 2);
    expect(again.view.updatedAt, greaterThan(0));
  });

  test('estimates are shown rounded', () {
    expect(roundCensusEstimate(0), 1);
    expect(roundCensusEstimate(57), 57);
    expect(roundCensusEstimate(1234), 1200);
    expect(roundCensusEstimate(98765), 99000);
  });

  test('the census key is derived, never the self key', () {
    final Uint8List self = Uint8List.fromList(List<int>.filled(32, 9));
    final Uint8List key = censusKeyOf(self);
    expect(key, hasLength(32));
    expect(key, isNot(self));
    expect(censusKeyOf(self), key);
  });
}
