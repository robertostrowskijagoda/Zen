import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/account/account_link.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Devices wired to each other; every send is also written to [log].
final class _Wire extends MemorySignalTransport {
  _Wire(this.address, this.nodes, this.log);

  final String address;
  final Map<String, _Wire> nodes;
  final List<String> log;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    log.add('$address ${payload['type']}');
    final _Wire? target = nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle([int rounds = 20]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<Uint8List> _publicKey(SimpleKeyPair pair) async =>
    Uint8List.fromList((await pair.extractPublicKey()).bytes);

void main() {
  final Map<String, _Wire> nodes = <String, _Wire>{};
  final List<String> log = <String>[];

  setUp(() {
    nodes.clear();
    log.clear();
  });

  Future<_Wire> wire(String address) async {
    final String normalized = PeerShareCodec.normalizeAddress(address);
    final _Wire t = _Wire(normalized, nodes, log);
    nodes[normalized] = t;
    await t.start();
    return t;
  }

  test('the old device commits to its key and reveals it only after the '
      'new device answered', () async {
    final _Wire old = await wire('200::1');
    final _Wire fresh = await wire('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);
    final AccountLinkSender sender = AccountLinkSender(
      transport: old,
      target: fresh.address,
    );
    addTearDown(sender.dispose);

    final String digits = await sender.start();
    expect(await receiver.digits, digits);
    expect(digits, matches(RegExp(r'^\d{3} \d{3}$')));

    // The order on the wire: commitment, the new key, then the reveal.
    expect(log, <String>[
      '${old.address} $kLinkHelloType',
      '${fresh.address} $kLinkKeyType',
      '${old.address} $kLinkRevealType',
    ]);
    final Map<String, dynamic> hello = old.sentSignals.first.payload;
    expect(hello['v'], kLinkProtocolVersion);
    expect(
      hello.containsKey('e'),
      isFalse,
      reason: 'nothing to grind a matching key against',
    );
    final Uint8List revealed = unb64(
      old.sentSignals[1].payload['e'],
      length: 32,
    )!;
    expect(b64(await linkCommitment(revealed)), hello['c']);

    // The account still travels as before.
    final Uint8List seed = randomBytes(32);
    final Future<void> sent = sender.send(
      seed: seed,
      account: 'konto',
      siblings: <String>[old.address],
    );
    final LinkedAccount got = await receiver.account;
    expect(got.seed, seed);
    expect(got.account, 'konto');
    await receiver.confirm();
    await sent;
  });

  test('a revealed key that is not the promised one shows no digits, and '
      'the real device can link afterwards', () async {
    final _Wire intruder = await wire('200::66');
    final _Wire fresh = await wire('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);
    bool shown = false;
    unawaited(receiver.digits.then((_) => shown = true));

    final Uint8List promised = await _publicKey(await X25519().newKeyPair());
    final Uint8List swapped = await _publicKey(await X25519().newKeyPair());
    await intruder.send(
      remoteAddress: fresh.address,
      payload: <String, dynamic>{
        'type': kLinkHelloType,
        'v': kLinkProtocolVersion,
        'c': b64(await linkCommitment(promised)),
      },
    );
    await _settle();
    expect(fresh.sentSignals.single.payload['type'], kLinkKeyType);
    // A key chosen after seeing the new device's key.
    await intruder.send(
      remoteAddress: fresh.address,
      payload: <String, dynamic>{'type': kLinkRevealType, 'e': b64(swapped)},
    );
    await _settle();
    expect(shown, isFalse);

    final _Wire old = await wire('200::1');
    final AccountLinkSender sender = AccountLinkSender(
      transport: old,
      target: fresh.address,
    );
    addTearDown(sender.dispose);
    final String digits = await sender.start();
    expect(await receiver.digits, digits);
    expect(receiver.offers.single.peer, old.address);
    expect(receiver.offers.single.digits, digits);
  });

  test('a reveal from anyone but the greeting device is ignored', () async {
    final _Wire old = await wire('200::1');
    final _Wire other = await wire('200::7');
    final _Wire fresh = await wire('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);
    bool shown = false;
    unawaited(receiver.digits.then((_) => shown = true));

    final SimpleKeyPair pair = await X25519().newKeyPair();
    final Uint8List key = await _publicKey(pair);
    await old.send(
      remoteAddress: fresh.address,
      payload: <String, dynamic>{
        'type': kLinkHelloType,
        'v': kLinkProtocolVersion,
        'c': b64(await linkCommitment(key)),
      },
    );
    await _settle();
    await other.send(
      remoteAddress: fresh.address,
      payload: <String, dynamic>{'type': kLinkRevealType, 'e': b64(key)},
    );
    await _settle();
    expect(shown, isFalse);
  });

  test('a hello without a commitment gets no answer', () async {
    final _Wire old = await wire('200::1');
    final _Wire fresh = await wire('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);

    // The key itself in the hello, no commitment.
    final Uint8List pub = await _publicKey(await X25519().newKeyPair());
    await old.send(
      remoteAddress: fresh.address,
      payload: <String, dynamic>{'type': kLinkHelloType, 'e': b64(pub)},
    );
    await _settle();
    expect(fresh.sentSignals, isEmpty);
    expect(receiver.peers, isEmpty);
  });

  test('a stranger who greets first does not block the real device', () async {
    final _Wire stranger = await wire('200::66');
    final _Wire old = await wire('200::1');
    final _Wire fresh = await wire('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);

    // The stranger runs the protocol first and shows its digits.
    final AccountLinkSender intruder = AccountLinkSender(
      transport: stranger,
      target: fresh.address,
    );
    addTearDown(intruder.dispose);
    final String strangerDigits = await intruder.start();
    await _settle();

    // The real device still links; both attempts show their own digits.
    final AccountLinkSender sender = AccountLinkSender(
      transport: old,
      target: fresh.address,
    );
    addTearDown(sender.dispose);
    final String digits = await sender.start();
    await _settle();
    expect(receiver.offers.map((AccountLinkOffer o) => o.digits), <String>[
      strangerDigits,
      digits,
    ]);
    final Uint8List seed = randomBytes(32);
    final Future<void> sent = sender.send(
      seed: seed,
      account: 'konto',
      siblings: <String>[old.address],
    );
    await _settle();
    final AccountLinkOffer real = receiver.offers.singleWhere(
      (AccountLinkOffer o) => o.peer == old.address,
    );
    expect(real.digits, digits);
    expect(real.account!.seed, seed);
    expect(real.account!.account, 'konto');
    await receiver.confirm(real.account);
    await sent;
    // The stranger was not told anything was taken.
    expect(
      fresh.sentSignals
          .where((s) => s.payload['type'] == kLinkDoneType)
          .map((s) => s.remoteAddress),
      <String>[old.address],
    );
  });

  test(
    'a new greeting starts the attempt over; attempts are bounded',
    () async {
      final _Wire fresh = await wire('200::2');
      final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
        ..start();
      addTearDown(receiver.dispose);
      Future<void> hello(_Wire from) async {
        await from.send(
          remoteAddress: fresh.address,
          payload: <String, dynamic>{
            'type': kLinkHelloType,
            'v': kLinkProtocolVersion,
            'c': b64(
              await linkCommitment(
                await _publicKey(await X25519().newKeyPair()),
              ),
            ),
          },
        );
        await _settle();
      }

      final List<_Wire> others = <_Wire>[
        for (int i = 1; i <= AccountLinkReceiver.maxSessions + 1; i++)
          await wire('200::7$i'),
      ];
      await hello(others.first);
      await hello(others.first);
      expect(receiver.peers, <String>[others.first.address]);
      expect(
        fresh.sentSignals.where((s) => s.payload['type'] == kLinkKeyType),
        hasLength(2),
        reason: 'each greeting gets a fresh key',
      );
      for (final _Wire o in others.skip(1)) {
        await hello(o);
      }
      expect(receiver.peers, hasLength(AccountLinkReceiver.maxSessions));
      expect(receiver.peers.contains(others.first.address), isFalse);
      expect(receiver.peers.last, others.last.address);

      // The real device greeting now still gets an answer.
      final _Wire old = await wire('200::1');
      final AccountLinkSender sender = AccountLinkSender(
        transport: old,
        target: fresh.address,
      );
      addTearDown(sender.dispose);
      final String digits = await sender.start();
      await _settle();
      expect(receiver.offers.single.digits, digits);
    },
  );

  test('another linking version is answered, and both sides say "update '
      'Zen on both devices"', () async {
    final _Wire old = await wire('200::1');
    final _Wire fresh = await wire('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);

    // A newer build greets this one.
    await old.send(
      remoteAddress: fresh.address,
      payload: <String, dynamic>{
        'type': kLinkHelloType,
        'v': kLinkProtocolVersion + 1,
        'app': '9.0.0',
        'c': b64(randomBytes(32)),
      },
    );
    await _settle();
    expect(receiver.versionMismatch, '9.0.0');
    expect(fresh.sentSignals.single.payload['type'], kLinkVersionType);
    expect(receiver.peers, isEmpty);

    // The sender of this build hears the same from a newer receiver.
    final _Wire newer = await wire('200::3');
    final StreamSubscription<SignalTransportFrame> answer = newer.frames.listen(
      (SignalTransportFrame f) {
        if (f.payload['type'] == kLinkHelloType) {
          unawaited(
            newer.send(
              remoteAddress: f.from,
              payload: <String, dynamic>{
                'type': kLinkVersionType,
                'v': <int>[kLinkProtocolVersion + 1],
                'app': '9.0.0',
              },
            ),
          );
        }
      },
    );
    addTearDown(answer.cancel);
    final AccountLinkSender sender = AccountLinkSender(
      transport: old,
      target: newer.address,
    );
    addTearDown(sender.dispose);
    await expectLater(
      sender.start(),
      throwsA(
        isA<AccountLinkVersionException>().having(
          (AccountLinkVersionException e) => e.otherApp,
          'otherApp',
          '9.0.0',
        ),
      ),
    );
  });
}
