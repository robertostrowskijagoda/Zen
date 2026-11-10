import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

// Not IPv6: kept as they are by the address normalization.
const String _self = 'me.ygg';
const String _co = 'co.ygg';
const String _sender = 'sender.ygg';

String _friend(int i) => 'friend$i.ygg';

Map<String, dynamic> _envelope(
  String id, {
  required String to,
  required int now,
}) => <String, dynamic>{
  'id': id,
  's': _sender,
  'r': to,
  'c': now,
  'x': now + const Duration(days: 1).inMilliseconds,
  'q': base64Url.encode(List<int>.filled(kHybridCiphertextBytes, 1)),
  'n': base64Url.encode(List<int>.filled(12, 1)),
  'b': base64Url.encode(List<int>.filled(1200, 1)),
};

/// A transport whose every send moves the test's clock on, as frames
/// being answered take time.
class _SlowTransport extends MemorySignalTransport {
  _SlowTransport(this._advance);

  final void Function() _advance;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) {
    _advance();
    return super.send(remoteAddress: remoteAddress, payload: payload);
  }
}

void main() {
  late int clock;
  late MemorySignalTransport transport;
  late List<LockedMailboxKit> writes;
  late LockedMailbox mailbox;
  int failNextWrites = 0;

  /// A mailbox serving [friends] friends, its kit written to [writes].
  void build({int friends = 10, MemorySignalTransport? over}) {
    clock = 1000000;
    writes = <LockedMailboxKit>[];
    failNextWrites = 0;
    transport = over ?? MemorySignalTransport();
    mailbox = LockedMailbox(
      transport: transport,
      kit: LockedMailboxKit(
        self: _self,
        served: <String, LockedMailboxPeer>{
          for (int i = 0; i < friends; i++)
            _friend(i): LockedMailboxPeer(
              relays: <String>[
                _self,
                _co,
                'a$i.ygg',
                'b$i.ygg',
                'c$i.ygg',
                'd$i.ygg',
              ],
            ),
        },
      ),
      isFriend: (String address) => true,
      isContact: (String address) => true,
      save: (LockedMailboxKit kit) async {
        if (failNextWrites > 0) {
          failNextWrites--;
          throw StateError('disk full');
        }
        // As the service's file does it: through JSON.
        writes.add(
          LockedMailboxKit.fromJson(jsonDecode(jsonEncode(kit.toJson())))!,
        );
      },
      now: () => clock,
    );
  }

  Future<void> frame(String from, Map<String, dynamic> payload) =>
      mailbox.handle(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: clock,
        ),
      );

  Future<void> deposit(String id, {required String to}) =>
      frame(_sender, <String, dynamic>{
        'type': 'rly_deposit',
        'env': _envelope(id, to: to, now: clock),
      });

  /// What the stored kit holds, as ids.
  Set<String> storedIds() => <String>{
    for (final Map<String, Map<String, dynamic>> m in writes.last.held.values)
      ...m.keys,
  };

  for (final int friends in <int>[10, 100]) {
    test('an hour of frames that change nothing writes the kit not at all '
        'with $friends friends', () async {
      build(friends: friends);
      await deposit('first', to: _friend(0));
      expect(writes, hasLength(1));

      // A simulated hour: friends polling their mailbox, the sender
      // retrying a deposit that was stored, receipts for mail not held,
      // fellow mailboxes comparing what they hold.
      for (int second = 0; second < 3600; second += 10) {
        clock += 10 * 1000;
        final String friend = _friend((second ~/ 10) % friends);
        await frame(friend, <String, dynamic>{'type': 'rly_poll'});
        await frame(friend, <String, dynamic>{
          'type': 'rly_poll',
          kRelayProbeKey: true,
        });
        await frame(_friend(0), <String, dynamic>{
          'type': 'rly_mail_ack',
          'ids': <String>['unknown-$second'],
        });
        await frame(_co, <String, dynamic>{
          'type': 'rly_purge',
          'ids': <String>['unknown-$second'],
        });
        await frame(_co, <String, dynamic>{
          'type': 'rly_sync',
          'r': _friend(0),
          'ids': <String>['first'],
          't': <String>[],
        });
        await deposit('first', to: _friend(0));
      }

      expect(writes, hasLength(1));
      expect(mailbox.heldFor(_friend(0)), <String>['first']);
    });
  }

  test('a deposit of mail already delivered changes nothing and writes '
      'nothing', () async {
    build();
    await deposit('gone', to: _friend(0));
    await frame(_friend(0), <String, dynamic>{
      'type': 'rly_mail_ack',
      'ids': <String>['gone'],
    });
    expect(writes, hasLength(2));
    for (int i = 0; i < 5; i++) {
      clock += 60 * 1000;
      await deposit('gone', to: _friend(0));
    }
    expect(writes, hasLength(2));
    expect(mailbox.heldFor(_friend(0)), isEmpty);
  });

  test('frames that come one after another are each written at once', () async {
    build();
    for (int i = 0; i < 5; i++) {
      await deposit('m$i', to: _friend(i));
      expect(writes, hasLength(i + 1));
      expect(storedIds(), contains('m$i'));
    }
  });

  test('a burst of deposits waiting behind each other is written once, '
      'complete, when the last is handled', () async {
    build(friends: 100);
    final List<Future<void>> done = <Future<void>>[
      for (int i = 0; i < 40; i++) deposit('b$i', to: _friend(i)),
    ];
    await Future.wait(done);

    expect(writes, hasLength(1));
    expect(storedIds(), <String>{for (int i = 0; i < 40; i++) 'b$i'});
    expect(writes.last.signature, mailbox.kit.signature);
    // Every deposit was answered all the same.
    expect(
      transport.sentSignals
          .where((s) => s.payload['type'] == 'rly_deposit_ack')
          .length,
      40,
    );
  });

  test('a burst of receipts is written once and a burst that changes '
      'nothing not at all', () async {
    build();
    await Future.wait(<Future<void>>[
      for (int i = 0; i < 20; i++) deposit('r$i', to: _friend(0)),
    ]);
    expect(writes, hasLength(1));

    await Future.wait(<Future<void>>[
      for (int i = 0; i < 20; i++)
        frame(_friend(0), <String, dynamic>{
          'type': 'rly_mail_ack',
          'ids': <String>['r$i'],
        }),
    ]);
    expect(writes, hasLength(2));
    expect(storedIds(), isEmpty);
    expect(writes.last.tombstones, hasLength(20));

    await Future.wait(<Future<void>>[
      for (int i = 0; i < 20; i++)
        frame(_friend(0), <String, dynamic>{'type': 'rly_poll'}),
    ]);
    expect(writes, hasLength(2));
  });

  test('a stream that never lets the queue drain is still written every '
      'few seconds', () async {
    build(over: _SlowTransport(() => clock += 2000));
    final List<Future<void>> done = <Future<void>>[
      for (int i = 0; i < 30; i++) deposit('s$i', to: _friend(i % 10)),
    ];
    await Future.wait(done);

    // 30 frames of 2 s each: a write about every 5 s on the way, and the
    // last one when the queue was empty.
    expect(writes.length, greaterThan(5));
    expect(writes.length, lessThan(30));
    expect(storedIds(), <String>{for (int i = 0; i < 30; i++) 's$i'});
    expect(writes.last.signature, mailbox.kit.signature);
    // Each stored kit is complete up to the frames handled before it.
    for (int i = 1; i < writes.length; i++) {
      expect(
        storedIds().length,
        greaterThanOrEqualTo(
          writes[i - 1].held.values.fold<int>(
            0,
            (int sum, Map<String, Map<String, dynamic>> m) => sum + m.length,
          ),
        ),
      );
    }
  });

  test('a write that failed is tried again with the next frame', () async {
    build();
    failNextWrites = 1;
    await deposit('lost', to: _friend(0));
    expect(writes, isEmpty);

    // Nothing changes with this frame, but the stored kit still lacks mail.
    await frame(_friend(1), <String, dynamic>{'type': 'rly_poll'});
    expect(writes, hasLength(1));
    expect(storedIds(), <String>{'lost'});

    await frame(_friend(1), <String, dynamic>{'type': 'rly_poll'});
    expect(writes, hasLength(1));
  });
}
