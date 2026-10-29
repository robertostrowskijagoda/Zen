import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/features/calls/call_media_e2ee.dart';
import 'package:zen/src/features/calls/presentation/call_security_badge.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

final class _FakeCryptor implements MediaFrameCryptor {
  int? keyIndex;
  bool enabled = false;
  bool disposed = false;

  @override
  Future<void> setKeyIndex(int index) async => keyIndex = index;

  @override
  Future<void> setEnabled(bool value) async => enabled = value;

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeRing implements MediaKeyRing {
  _FakeRing({this.senderFails = false});

  final bool senderFails;
  final Map<String, Map<int, String>> keys = <String, Map<int, String>>{};
  bool disposed = false;

  /// The senders and receivers a transformer was asked for, by id.
  final List<String> sealed = <String>[];

  String? key(String participantId, int index) => keys[participantId]?[index];

  @override
  Future<void> setKey(String participantId, int index, Uint8List key) async {
    (keys[participantId] ??= <int, String>{})[index] = _hex(key);
  }

  @override
  Future<MediaFrameCryptor> attachSender(
    RTCRtpSender sender,
    String participantId,
  ) async {
    if (senderFails) {
      throw StateError('no transformer');
    }
    sealed.add(sender.senderId);
    return _FakeCryptor();
  }

  @override
  Future<MediaFrameCryptor> attachReceiver(
    RTCRtpReceiver receiver,
    String participantId, {
    void Function()? onMissingKey,
  }) async {
    sealed.add(receiver.receiverId);
    return _FakeCryptor();
  }

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeBackend implements MediaFrameCryptoBackend {
  _FakeBackend({this.available = true, this.senderFails = false});

  final bool available;
  final bool senderFails;
  final List<_FakeRing> rings = <_FakeRing>[];

  @override
  Future<MediaKeyRing?> openKeyRing() async {
    if (!available) {
      return null;
    }
    final _FakeRing ring = _FakeRing(senderFails: senderFails);
    rings.add(ring);
    return ring;
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.due, this.callback, this.period);

  DateTime due;
  final void Function() callback;
  final Duration? period;
  bool active = true;
  int ticks = 0;

  @override
  void cancel() => active = false;

  @override
  bool get isActive => active;

  @override
  int get tick => ticks;
}

final class _FakeClock implements MediaKeyClock {
  DateTime _now = DateTime.utc(2026, 10, 21);
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  @override
  DateTime now() => _now;

  @override
  Timer after(Duration delay, void Function() callback) {
    final _FakeTimer timer = _FakeTimer(_now.add(delay), callback, null);
    _timers.add(timer);
    return timer;
  }

  @override
  Timer every(Duration period, void Function() callback) {
    final _FakeTimer timer = _FakeTimer(_now.add(period), callback, period);
    _timers.add(timer);
    return timer;
  }

  /// Moves time on, firing what falls due in order; [settle] runs after
  /// each firing so the queued key steps complete.
  Future<void> advance(
    Duration by, {
    required Future<void> Function() settle,
  }) async {
    final DateTime end = _now.add(by);
    while (true) {
      final List<_FakeTimer> due =
          _timers
              .where((_FakeTimer t) => t.active && !t.due.isAfter(end))
              .toList()
            ..sort((_FakeTimer a, _FakeTimer b) => a.due.compareTo(b.due));
      if (due.isEmpty) {
        break;
      }
      final _FakeTimer next = due.first;
      _now = next.due;
      next.ticks += 1;
      final Duration? period = next.period;
      if (period == null) {
        next.active = false;
      } else {
        next.due = next.due.add(period);
      }
      next.callback();
      await settle();
    }
    _now = end;
  }
}

final class _Sender implements RTCRtpSender {
  _Sender([this.senderId = 's1', this.hasTrack = true]);

  @override
  final String senderId;

  final bool hasTrack;

  @override
  MediaStreamTrack? get track => hasTrack ? _Track() : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Track implements MediaStreamTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Receiver implements RTCRtpReceiver {
  _Receiver([this.receiverId = 'r1']);

  @override
  final String receiverId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transceiver implements RTCRtpTransceiver {
  _Transceiver([RTCRtpSender? sender, RTCRtpReceiver? receiver])
    : sender = sender ?? _Sender(),
      receiver = receiver ?? _Receiver();

  @override
  final RTCRtpSender sender;

  @override
  final RTCRtpReceiver receiver;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Connection implements RTCPeerConnection {
  _Connection({
    List<RTCRtpTransceiver>? transceivers,
    List<RTCRtpSender>? senders,
    List<RTCRtpReceiver>? receivers,
  }) : _transceivers = transceivers ?? <RTCRtpTransceiver>[_Transceiver()],
       _senders = senders,
       _receivers = receivers;

  final List<RTCRtpTransceiver> _transceivers;

  /// What getSenders / getReceivers answer (default: the transceivers').
  final List<RTCRtpSender>? _senders;
  final List<RTCRtpReceiver>? _receivers;

  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => _transceivers;

  @override
  Future<List<RTCRtpSender>> getSenders() async =>
      _senders ?? <RTCRtpSender>[for (final t in _transceivers) t.sender];

  @override
  Future<List<RTCRtpReceiver>> getReceivers() async =>
      _receivers ?? <RTCRtpReceiver>[for (final t in _transceivers) t.receiver];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Two ends of one connection, `a` sending to `b` and back.
final class _Pair {
  _Pair({bool deliver = true}) : _deliver = deliver {
    a = MediaKeyLink(
      ring: ringA,
      callId: 'call-1',
      localId: 'a',
      remoteId: 'b',
      clock: clock,
      onRotated: (int epoch) {
        if (_deliver) {
          unawaited(b.remoteAdvanced(epoch));
        }
      },
    );
    b = MediaKeyLink(
      ring: ringB,
      callId: 'call-1',
      localId: 'b',
      remoteId: 'a',
      clock: clock,
    );
  }

  final bool _deliver;
  final _FakeClock clock = _FakeClock();
  final _FakeRing ringA = _FakeRing();
  final _FakeRing ringB = _FakeRing();
  final _FakeCryptor senderA = _FakeCryptor();
  late final MediaKeyLink a;
  late final MediaKeyLink b;

  Future<void> settle() async {
    for (int i = 0; i < 4; i++) {
      await a.idle;
      await b.idle;
    }
  }

  Future<void> start() async {
    await a.addSender(senderA);
    final Uint8List secret = Uint8List.fromList(
      List<int>.generate(32, (int i) => i),
    );
    await a.install(secret);
    await b.install(secret);
    await settle();
  }

  /// What `a` seals with right now is in `b`'s ring: no frame is lost.
  void expectNoGap() {
    final int index = senderA.keyIndex!;
    expect(ringA.key('a', index), isNotNull);
    expect(
      ringB.key('a', index),
      ringA.key('a', index),
      reason: 'b must hold the key a seals with (slot $index)',
    );
  }

  Future<void> advance(Duration by) => clock.advance(by, settle: settle);
}

Future<(MediaE2eeChannel, MediaE2eeChannel)> _handshake({
  required String callId,
  required String offerer,
  required String answerer,
  _FakeBackend? offererBackend,
  _FakeBackend? answererBackend,
  _FakeClock? clock,
}) async {
  final MediaE2eeChannel? offering = await MediaE2eeChannel.open(
    backend: offererBackend ?? _FakeBackend(),
    callId: callId,
    localId: offerer,
    remoteId: answerer,
    kem: kClassicalStandInHybridKem,
    clock: clock ?? _FakeClock(),
  );
  final MediaE2eeChannel? answering = await MediaE2eeChannel.open(
    backend: answererBackend ?? _FakeBackend(),
    callId: callId,
    localId: answerer,
    remoteId: offerer,
    kem: kClassicalStandInHybridKem,
    clock: clock ?? _FakeClock(),
  );
  final Map<String, dynamic> offer = await offering!.offerBlock();
  final Map<String, dynamic>? answer = await answering!.answerOffer(
    offer,
    offererId: offerer,
    answererId: answerer,
  );
  await offering.acceptAnswer(answer, offererId: offerer, answererId: answerer);
  await offering.link.idle;
  await answering.link.idle;
  return (offering, answering);
}

void main() {
  group('key derivation', () {
    final Uint8List secret = Uint8List.fromList(
      List<int>.generate(32, (int i) => i),
    );

    test('chain keys follow the HKDF-SHA256 vectors', () async {
      expect(
        _hex(
          await deriveMediaChainKey(
            secret: secret,
            callId: 'call-1',
            senderId: kMediaOffererId,
            receiverId: kMediaAnswererId,
          ),
        ),
        '0786f9add47cf2fba4a72c56c424d3ffcee8c876f5daba777d3e9a7dcbfc46be',
      );
      expect(
        _hex(
          await deriveMediaChainKey(
            secret: secret,
            callId: 'call-1',
            senderId: kMediaAnswererId,
            receiverId: kMediaOffererId,
          ),
        ),
        '4d1deda428e8e235c98dee4265512a3d49328b6bf669c1ecc14f84655ccfc3a0',
      );
    });

    test('the ratchet follows the vectors and is bound to the epoch', () async {
      final Uint8List chain = await deriveMediaChainKey(
        secret: secret,
        callId: 'call-1',
        senderId: kMediaOffererId,
        receiverId: kMediaAnswererId,
      );
      final Uint8List first = await ratchetMediaKey(
        chain,
        callId: 'call-1',
        senderId: kMediaOffererId,
        epoch: 1,
      );
      expect(
        _hex(first),
        'd0a6045428a2e87ac009f7d722b4ffb4aeb415fb9c0f419ba0db49a7075825d3',
      );
      expect(
        _hex(
          await ratchetMediaKey(
            first,
            callId: 'call-1',
            senderId: kMediaOffererId,
            epoch: 2,
          ),
        ),
        'db490d6f5d95683c1f692953e47d3b76c4d4ff8c94ebfccfa2f7f22868586b49',
      );
      expect(
        _hex(
          await ratchetMediaKey(
            chain,
            callId: 'call-2',
            senderId: kMediaOffererId,
            epoch: 1,
          ),
        ),
        isNot(_hex(first)),
      );
    });

    test('the KEM info names the call and both ends', () {
      expect(
        utf8.decode(mediaKemInfo(callId: 'c', offererId: 'x', answererId: 'y')),
        'zen.call.media.v1|kem|c|x|y',
      );
      expect(mediaKeyIndex(0), 0);
      expect(mediaKeyIndex(17), 1);
      expect(mediaParticipantId(' 200::AB '), '200::ab');
    });
  });

  group('rotation', () {
    test('installs the current key and the lookahead on both ends', () async {
      final _Pair pair = _Pair();
      await pair.start();
      expect(pair.senderA.enabled, isTrue);
      expect(pair.senderA.keyIndex, 0);
      expect(pair.a.sendEpochs, <int>{0, 1, 2, 3});
      expect(pair.b.receiveEpochs, <int>{0, 1, 2, 3});
      for (int epoch = 0; epoch <= kMediaKeyLookahead; epoch++) {
        expect(pair.ringB.key('a', epoch), pair.ringA.key('a', epoch));
      }
      // The other direction has a chain of its own.
      expect(pair.ringA.key('b', 0), isNot(pair.ringA.key('a', 0)));
      expect(pair.ringA.key('b', 0), pair.ringB.key('b', 0));
      pair.expectNoGap();
    });

    test(
      'every interval the key moves on with no gap and an overlap',
      () async {
        final _Pair pair = _Pair();
        await pair.start();
        final String? first = pair.ringB.key('a', 0);
        await pair.advance(kMediaKeyRotationInterval);
        expect(pair.a.sendEpoch, 1);
        expect(pair.senderA.keyIndex, 1);
        expect(pair.b.receiveEpoch, 1);
        pair.expectNoGap();
        // The old key stays for late frames...
        expect(pair.ringB.key('a', 0), first);
        expect(pair.b.receiveEpochs, contains(0));
        // ...and is gone after the overlap.
        await pair.advance(kMediaKeyOverlap);
        expect(pair.b.receiveEpochs, isNot(contains(0)));
        expect(pair.ringB.key('a', 0), isNot(first));
        expect(pair.b.receiveEpochs, <int>{1, 2, 3, 4});
        pair.expectNoGap();
        for (int i = 0; i < 20; i++) {
          await pair.advance(kMediaKeyRotationInterval);
          pair.expectNoGap();
        }
        expect(pair.a.sendEpoch, 21);
        expect(pair.senderA.keyIndex, mediaKeyIndex(21));
      },
    );

    test('the switch never waits for the notice', () async {
      final _Pair pair = _Pair(deliver: false);
      await pair.start();
      for (int i = 0; i < kMediaKeyLookahead; i++) {
        await pair.advance(kMediaKeyRotationInterval);
        // Lost notices: b still decrypts from its lookahead.
        pair.expectNoGap();
      }
      expect(pair.b.receiveEpoch, 0);
    });

    test('a missing key widens the lookahead; a notice catches up', () async {
      final _Pair pair = _Pair(deliver: false);
      await pair.start();
      for (int i = 0; i <= kMediaKeyLookahead; i++) {
        await pair.advance(kMediaKeyRotationInterval);
      }
      expect(pair.a.sendEpoch, kMediaKeyLookahead + 1);
      expect(
        pair.ringB.key('a', pair.senderA.keyIndex!),
        isNot(pair.ringA.key('a', pair.senderA.keyIndex!)),
      );
      // The receiver reports a frame with a key it does not have.
      await pair.b.missingKey();
      pair.expectNoGap();
      await pair.b.remoteAdvanced(pair.a.sendEpoch);
      expect(pair.b.receiveEpoch, pair.a.sendEpoch);
      pair.expectNoGap();
    });

    test('a far jump is followed, an absurd one ignored', () async {
      final _Pair pair = _Pair(deliver: false);
      await pair.start();
      for (int i = 0; i < 10; i++) {
        await pair.advance(kMediaKeyRotationInterval);
      }
      await pair.b.remoteAdvanced(pair.a.sendEpoch);
      await pair.settle();
      pair.expectNoGap();
      await pair.b.remoteAdvanced(pair.a.sendEpoch + kMediaKeyMaxEpochJump + 1);
      expect(pair.b.receiveEpoch, pair.a.sendEpoch);
      await pair.b.remoteAdvanced(1);
      expect(pair.b.receiveEpoch, pair.a.sendEpoch);
    });

    test('rotations in a burst are spaced out', () async {
      final _Pair pair = _Pair();
      await pair.start();
      await pair.a.rotate();
      await pair.a.rotate();
      await pair.a.rotate();
      await pair.settle();
      expect(pair.a.sendEpoch, 1);
      pair.expectNoGap();
      await pair.advance(kMediaKeyMinRotationSpacing);
      expect(pair.a.sendEpoch, 2);
      expect(pair.b.receiveEpoch, 2);
      pair.expectNoGap();
    });

    test('disposing releases every transformer', () async {
      final _Pair pair = _Pair();
      await pair.start();
      await pair.a.dispose();
      expect(pair.senderA.disposed, isTrue);
      await pair.a.rotate();
      expect(pair.a.sendEpoch, 0);
    });
  });

  group('key agreement', () {
    test('both ends of a call derive the same keys from the KEM', () async {
      final _FakeBackend caller = _FakeBackend();
      final _FakeBackend callee = _FakeBackend();
      final (
        MediaE2eeChannel offering,
        MediaE2eeChannel answering,
      ) = await _handshake(
        callId: 'call-9',
        offerer: kMediaOffererId,
        answerer: kMediaAnswererId,
        offererBackend: caller,
        answererBackend: callee,
      );
      expect(offering.security, CallMediaSecurity.postQuantum);
      expect(answering.security, CallMediaSecurity.postQuantum);
      for (final String id in <String>[kMediaOffererId, kMediaAnswererId]) {
        expect(caller.rings.single.key(id, 0), isNotNull);
        expect(caller.rings.single.key(id, 0), callee.rings.single.key(id, 0));
      }
      expect(
        caller.rings.single.key(kMediaOffererId, 0),
        isNot(caller.rings.single.key(kMediaAnswererId, 0)),
      );
      // A repeated offer gets the same answer, never a second secret.
      final Map<String, dynamic>? again = await answering.answerOffer(
        await offering.offerBlock(),
        offererId: kMediaOffererId,
        answererId: kMediaAnswererId,
      );
      expect(again?['ct'], isNotNull);
      expect(
        caller.rings.single.key(kMediaOffererId, 0),
        callee.rings.single.key(kMediaOffererId, 0),
      );
    });

    test('a fresh exchange gives every call new keys', () async {
      final _FakeBackend first = _FakeBackend();
      final _FakeBackend second = _FakeBackend();
      await _handshake(
        callId: 'call-1',
        offerer: 'a',
        answerer: 'b',
        offererBackend: first,
      );
      await _handshake(
        callId: 'call-1',
        offerer: 'a',
        answerer: 'b',
        offererBackend: second,
      );
      expect(
        first.rings.single.key('a', 0),
        isNot(second.rings.single.key('a', 0)),
      );
    });

    test('without frame encryption on the other side: standard', () async {
      final MediaE2eeChannel? missing = await MediaE2eeChannel.open(
        backend: _FakeBackend(available: false),
        callId: 'call-3',
        localId: kMediaAnswererId,
        remoteId: kMediaOffererId,
      );
      expect(missing, isNull);
      final MediaE2eeChannel offering = (await MediaE2eeChannel.open(
        backend: _FakeBackend(),
        callId: 'call-3',
        localId: kMediaOffererId,
        remoteId: kMediaAnswererId,
        kem: kClassicalStandInHybridKem,
        clock: _FakeClock(),
      ))!;
      final _FakeCryptor sender = _FakeCryptor();
      await offering.link.addSender(sender);
      expect(sender.enabled, isTrue);
      await offering.offerBlock();
      // The answer comes back without a block.
      await offering.acceptAnswer(
        null,
        offererId: kMediaOffererId,
        answererId: kMediaAnswererId,
      );
      expect(offering.security, CallMediaSecurity.standard);
      expect(sender.enabled, isFalse);
      expect(offering.link.installed, isFalse);
    });

    test('a sender that could not be sealed: the call is not shown as '
        'post-quantum, the keys stay', () async {
      final (MediaE2eeChannel offering, MediaE2eeChannel _) = await _handshake(
        callId: 'call-4',
        offerer: kMediaOffererId,
        answerer: kMediaAnswererId,
        offererBackend: _FakeBackend(senderFails: true),
      );
      expect(offering.security, CallMediaSecurity.postQuantum);
      int changes = 0;
      offering.onChanged = () => changes++;
      await offering.attachAll(_Connection());
      expect(offering.security, CallMediaSecurity.standard);
      expect(offering.negotiated, CallMediaSecurity.postQuantum);
      expect(changes, 1);
      expect(offering.link.installed, isTrue);
    });

    test(
      'only senders and receivers the connection has are sealed: a '
      'missing one crashed the app natively (flutter_webrtc hands it on '
      'as null); a sender without a track is sealed once it has one',
      () async {
        final _FakeBackend backend = _FakeBackend();
        final (
          MediaE2eeChannel offering,
          MediaE2eeChannel _,
        ) = await _handshake(
          callId: 'call-5',
          offerer: kMediaOffererId,
          answerer: kMediaAnswererId,
          offererBackend: backend,
        );
        final _FakeRing ring = backend.rings.first;
        final _Sender audio = _Sender('audio');
        final _Sender video = _Sender('video', false);
        final _Sender gone = _Sender('gone');
        await offering.attachAll(
          _Connection(
            transceivers: <RTCRtpTransceiver>[
              _Transceiver(audio, _Receiver('ra')),
              _Transceiver(video, _Receiver('rv')),
              // Stopped: no longer among the connection's senders/receivers.
              _Transceiver(gone, _Receiver('rg')),
            ],
            senders: <RTCRtpSender>[audio, video],
            receivers: <RTCRtpReceiver>[_Receiver('ra'), _Receiver('rv')],
          ),
        );
        expect(ring.sealed, <String>['audio', 'ra', 'rv']);
        // The camera comes on: its sender is sealed now.
        final _Sender camera = _Sender('video');
        await offering.attachAll(
          _Connection(
            transceivers: <RTCRtpTransceiver>[
              _Transceiver(audio, _Receiver('ra')),
              _Transceiver(camera, _Receiver('rv')),
            ],
          ),
        );
        expect(ring.sealed, <String>['audio', 'ra', 'rv', 'video']);
      },
    );

    test('an offer without a block is answered without one', () async {
      final MediaE2eeChannel answering = (await MediaE2eeChannel.open(
        backend: _FakeBackend(),
        callId: 'call-4',
        localId: kMediaAnswererId,
        remoteId: kMediaOffererId,
        kem: kClassicalStandInHybridKem,
      ))!;
      expect(
        await answering.answerOffer(
          null,
          offererId: kMediaOffererId,
          answererId: kMediaAnswererId,
        ),
        isNull,
      );
      expect(
        await answering.answerOffer(
          <String, dynamic>{'v': 99, 'pk': 'x'},
          offererId: kMediaOffererId,
          answererId: kMediaAnswererId,
        ),
        isNull,
      );
      expect(answering.security, CallMediaSecurity.negotiating);
    });

    test('the security of a group call is its weakest leg', () {
      expect(
        combineMediaSecurity(const <CallMediaSecurity>[]),
        CallMediaSecurity.negotiating,
      );
      expect(
        combineMediaSecurity(const <CallMediaSecurity>[
          CallMediaSecurity.postQuantum,
          CallMediaSecurity.postQuantum,
        ]),
        CallMediaSecurity.postQuantum,
      );
      expect(
        combineMediaSecurity(const <CallMediaSecurity>[
          CallMediaSecurity.postQuantum,
          CallMediaSecurity.negotiating,
        ]),
        CallMediaSecurity.negotiating,
      );
      expect(
        combineMediaSecurity(const <CallMediaSecurity>[
          CallMediaSecurity.postQuantum,
          CallMediaSecurity.standard,
          CallMediaSecurity.negotiating,
        ]),
        CallMediaSecurity.standard,
      );
    });
  });

  group('group calls', () {
    test('a join and a leave move every other leg on; legs never share '
        'keys', () async {
      const String alice = '200::a1';
      const String bob = '200::b2';
      const String cyd = '200::c3';
      final _FakeClock clock = _FakeClock();
      final _FakeBackend aliceToBob = _FakeBackend();
      final _FakeBackend bobToAlice = _FakeBackend();
      final (MediaE2eeChannel ab, MediaE2eeChannel ba) = await _handshake(
        callId: 'gcall',
        offerer: alice,
        answerer: bob,
        offererBackend: aliceToBob,
        answererBackend: bobToAlice,
        clock: clock,
      );
      ab.link.onRotated = (int epoch) => unawaited(ba.remoteAdvanced(epoch));
      final _FakeCryptor sealing = _FakeCryptor();
      await ab.link.addSender(sealing);
      final String? beforeJoin = aliceToBob.rings.single.key(alice, 0);

      Future<void> settle() async {
        for (int i = 0; i < 4; i++) {
          await ab.link.idle;
          await ba.link.idle;
        }
      }

      // Cyd joins: a leg of its own, with its own KEM exchange.
      final _FakeBackend aliceToCyd = _FakeBackend();
      final _FakeBackend cydToAlice = _FakeBackend();
      final (MediaE2eeChannel ca, MediaE2eeChannel ac) = await _handshake(
        callId: 'gcall',
        offerer: cyd,
        answerer: alice,
        offererBackend: cydToAlice,
        answererBackend: aliceToCyd,
        clock: clock,
      );
      expect(ac.security, CallMediaSecurity.postQuantum);
      expect(ca.security, CallMediaSecurity.postQuantum);
      await rekeyMediaChannels(<MediaE2eeChannel?>[ab, null]);
      await settle();
      expect(ab.link.sendEpoch, 1);
      expect(ba.link.receiveEpoch, 1);
      expect(sealing.keyIndex, 1);
      final String? afterJoin = aliceToBob.rings.single.key(alice, 1);
      expect(afterJoin, isNotNull);
      expect(bobToAlice.rings.single.key(alice, 1), afterJoin);
      // Cyd never holds a key of the Alice-Bob leg.
      final Set<String> cydKeys = <String>{
        for (final Map<int, String> slots
            in cydToAlice.rings.single.keys.values)
          ...slots.values,
      };
      expect(cydKeys, isNot(contains(beforeJoin)));
      expect(cydKeys, isNot(contains(afterJoin)));

      // Cyd leaves: its leg goes, the others move on again.
      await ac.dispose();
      expect(aliceToCyd.rings.single.disposed, isTrue);
      await clock.advance(kMediaKeyMinRotationSpacing, settle: settle);
      await rekeyMediaChannels(<MediaE2eeChannel?>[ab]);
      await settle();
      expect(ab.link.sendEpoch, 2);
      expect(ba.link.receiveEpoch, 2);
      expect(sealing.keyIndex, 2);
      expect(
        bobToAlice.rings.single.key(alice, 2),
        aliceToBob.rings.single.key(alice, 2),
      );
      await ca.dispose();
      await ab.dispose();
      await ba.dispose();
    });
  });

  group('indicator', () {
    Future<void> pumpBadge(WidgetTester tester, CallMediaSecurity level) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(child: CallSecurityBadge(security: level)),
            ),
          ),
        );

    testWidgets('shows a lock for post-quantum media', (
      WidgetTester tester,
    ) async {
      await pumpBadge(tester, CallMediaSecurity.postQuantum);
      expect(
        find.byKey(const Key('call-security-postQuantum')),
        findsOneWidget,
      );
      expect(
        find.text('Szyfrowanie odporne na komputery kwantowe'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    });

    testWidgets('says standard encryption on the fallback', (
      WidgetTester tester,
    ) async {
      await pumpBadge(tester, CallMediaSecurity.standard);
      expect(find.byKey(const Key('call-security-standard')), findsOneWidget);
      expect(find.text('Szyfrowanie standardowe'), findsOneWidget);
    });

    testWidgets('shows the negotiation', (WidgetTester tester) async {
      await pumpBadge(tester, CallMediaSecurity.negotiating);
      expect(find.text('Ustalanie szyfrowania…'), findsOneWidget);
    });
  });
}
