import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart' show Hkdf, Hmac, SecretKey;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

// End-to-end encryption of call media, on top of WebRTC's DTLS-SRTP.
//
// Every audio and video frame (camera, microphone, shared screen) is
// sealed with AES-GCM by WebRTC's own frame transformer (flutter_webrtc's
// `FrameCryptor`), natively, on the media threads: Dart never touches a
// frame. The keys come from a fresh hybrid ML-KEM-768 + X25519 exchange
// carried in the call's offer and answer (which already travel over the
// post-quantum signal channel), stretched with HKDF over the call id and
// both participant ids. Each direction has its own key chain; a chain
// moves forward (HKDF ratchet) every [kMediaKeyRotationInterval] and, in
// group calls, whenever somebody joins or leaves.
//
// No gap on rotation: a receiver always holds the next
// [kMediaKeyLookahead] keys of the sender's chain before the sender uses
// them (frames name their key index), and keeps the previous key for
// [kMediaKeyOverlap] after the sender moved on, for late frames.
//
// Key size. The frame transformer of libwebrtc (flutter_webrtc 1.6.2,
// webrtc-sdk m137-m150, frame_crypto_transformer.h) always derives a
// 128-bit AES key from the key material it is given
// (`DeriveKeys(material, ratchetSalt, 128)`, HKDF-SHA256 or PBKDF2), so
// the frames are AES-128-GCM whatever the material: the 32 bytes set here
// carry the full 256-bit entropy of the chain, the cipher does not. The
// strongest options it offers are used: AES-GCM (the other choice, CBC,
// has no integrity), HKDF (PBKDF2 adds nothing to a random 256-bit key and
// stalls the media thread), per-participant keys, no automatic ratchet on
// decryption failures (an attacker could drive it), and no frame ever
// passes unencrypted before the keys are in. Nothing else in the API sets
// the key size, the cipher or the IV.
//
// 256 bits end to end come from the layer around it: every packet of a
// call (RTP, RTCP, ICE, DTLS) travels through the bridge's call relay over
// Yggdrasil and is sealed there per packet with ChaCha20-Poly1305 under a
// 256-bit key from the hybrid ML-KEM-768 + X25519 session of the two
// devices (native/yggdrasil_bridge/pq_session.go, media frames). So a
// call's media has three layers: this frame encryption (keys from the
// call's own KEM exchange, rotated every few minutes), WebRTC's DTLS-SRTP,
// and the post-quantum relay layer, which also hides RTP headers, RTCP
// and the DTLS handshake.

/// How well the media of a call (or of one group-call leg) is protected.
enum CallMediaSecurity {
  /// Keys are still being agreed.
  negotiating,

  /// Frames sealed end to end with keys from the hybrid post-quantum KEM
  /// (and every packet sealed again by the relay's 256-bit session).
  postQuantum,

  /// DTLS-SRTP only: this device or the other one has no frame encryption.
  standard,
}

/// The weakest of [levels]: a group call is post-quantum only when every
/// leg is. No legs at all reads as [CallMediaSecurity.negotiating].
CallMediaSecurity combineMediaSecurity(Iterable<CallMediaSecurity> levels) {
  bool any = false;
  bool negotiating = false;
  for (final CallMediaSecurity level in levels) {
    any = true;
    if (level == CallMediaSecurity.standard) {
      return CallMediaSecurity.standard;
    }
    if (level == CallMediaSecurity.negotiating) {
      negotiating = true;
    }
  }
  if (!any || negotiating) {
    return CallMediaSecurity.negotiating;
  }
  return CallMediaSecurity.postQuantum;
}

/// 1:1 calls: `{type, callId, epoch}` — the sender's media key moved to
/// [epoch]. Group calls use [kGroupMediaKeySignal] the same way, per leg.
const String kCallMediaKeySignal = 'call_mkey';
const String kGroupMediaKeySignal = 'gc_mkey';

/// The key-exchange block inside an offer/answer description.
const String kMediaE2eeField = 'e2ee';
const int kMediaE2eeVersion = 1;

/// Key slots per participant in WebRTC's key ring (frames carry the slot).
const int kMediaKeyRingSize = 16;

/// Keys of the other side's chain installed ahead of the one in use.
const int kMediaKeyLookahead = 3;

/// How long an old key stays after the sender has moved on.
const Duration kMediaKeyOverlap = Duration(seconds: 10);

/// Every chain moves forward this often.
const Duration kMediaKeyRotationInterval = Duration(minutes: 5);

/// Rotations closer together than this are merged into one, so the
/// receiver's lookahead is never outrun (people joining in a burst).
const Duration kMediaKeyMinRotationSpacing = Duration(seconds: 2);

/// A peer announcing a jump further than this is ignored.
const int kMediaKeyMaxEpochJump = 64;

/// The ids of the two ends of a 1:1 call (neither side needs to know its
/// own mesh address): whoever sent the first offer, and whoever answered.
const String kMediaOffererId = 'offerer';
const String kMediaAnswererId = 'answerer';

/// A participant id as both ends write it.
String mediaParticipantId(String address) => address.trim().toLowerCase();

const String _label = 'zen.call.media.v1';
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

Future<Uint8List> _derive(List<int> ikm, String salt, String info) async {
  final SecretKey key = await _hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: utf8.encode(salt),
    info: utf8.encode(info),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// The `info` the hybrid KEM binds the call's shared secret to.
List<int> mediaKemInfo({
  required String callId,
  required String offererId,
  required String answererId,
}) => utf8.encode('$_label|kem|$callId|$offererId|$answererId');

/// The first key (epoch 0) of the chain [senderId] sends to [receiverId]
/// with: HKDF-SHA256(ikm: secret, salt: "zen.call.media.v1",
/// info: `zen.call.media.v1|chain|<callId>|<sender>|<receiver>`).
Future<Uint8List> deriveMediaChainKey({
  required Uint8List secret,
  required String callId,
  required String senderId,
  required String receiverId,
}) => _derive(secret, _label, '$_label|chain|$callId|$senderId|$receiverId');

/// The key of [epoch] from the key of `epoch - 1`: HKDF-SHA256(ikm: key,
/// salt: "zen.call.media.v1|ratchet", info: `<callId>|<sender>|<epoch>`).
/// One way: an old key never follows from a newer one.
Future<Uint8List> ratchetMediaKey(
  Uint8List previous, {
  required String callId,
  required String senderId,
  required int epoch,
}) => _derive(previous, '$_label|ratchet', '$callId|$senderId|$epoch');

/// The ring slot of [epoch].
int mediaKeyIndex(int epoch) => epoch % kMediaKeyRingSize;

/// One end's frame transformer on a sender or receiver.
abstract interface class MediaFrameCryptor {
  Future<void> setKeyIndex(int index);
  Future<void> setEnabled(bool enabled);
  Future<void> dispose();
}

/// The key ring of one peer connection, keyed by participant id.
abstract interface class MediaKeyRing {
  Future<void> setKey(String participantId, int index, Uint8List key);

  Future<MediaFrameCryptor> attachSender(
    RTCRtpSender sender,
    String participantId,
  );

  /// [onMissingKey] runs when a frame names a slot the ring has no key in.
  Future<MediaFrameCryptor> attachReceiver(
    RTCRtpReceiver receiver,
    String participantId, {
    void Function()? onMissingKey,
  });

  Future<void> dispose();
}

/// Opens key rings; `null` where this device has no frame encryption (the
/// call then stays on DTLS-SRTP alone).
abstract interface class MediaFrameCryptoBackend {
  Future<MediaKeyRing?> openKeyRing();
}

/// Time for the key schedule (replaced in tests).
abstract interface class MediaKeyClock {
  DateTime now();
  Timer after(Duration delay, void Function() callback);
  Timer every(Duration period, void Function() callback);
}

final class _SystemMediaKeyClock implements MediaKeyClock {
  const _SystemMediaKeyClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Timer after(Duration delay, void Function() callback) =>
      Timer(delay, callback);

  @override
  Timer every(Duration period, void Function() callback) =>
      Timer.periodic(period, (_) => callback());
}

const MediaKeyClock kSystemMediaKeyClock = _SystemMediaKeyClock();

Uint8List _randomKey() {
  final Random random = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
}

/// One direction's key chain: the keys still installed, by epoch.
final class _Chain {
  _Chain(this.participantId);

  final String participantId;
  final Map<int, Uint8List> keys = <int, Uint8List>{};

  /// The epoch frames use now.
  int current = 0;
  int highest = -1;
}

/// The key schedule of one peer connection: this side's sending chain and
/// the other side's, both kept in the connection's [MediaKeyRing].
///
/// Everything here runs at setup and on rotation only: a few HKDF calls
/// and `setKey` / `setKeyIndex` calls into WebRTC. Calls are serialised.
final class MediaKeyLink {
  MediaKeyLink({
    required this.ring,
    required this.callId,
    required this.localId,
    required this.remoteId,
    MediaKeyClock clock = kSystemMediaKeyClock,
    this.onRotated,
    this.rotationInterval = kMediaKeyRotationInterval,
  }) : _clock = clock,
       _send = _Chain(localId),
       _receive = _Chain(remoteId);

  final MediaKeyRing ring;
  final String callId;
  final String localId;
  final String remoteId;
  final Duration rotationInterval;

  /// Called with the new epoch after this side's chain moved forward; the
  /// owner tells the other side ([kCallMediaKeySignal]).
  void Function(int epoch)? onRotated;

  final MediaKeyClock _clock;
  final _Chain _send;
  final _Chain _receive;
  final List<MediaFrameCryptor> _senders = <MediaFrameCryptor>[];
  final List<MediaFrameCryptor> _receivers = <MediaFrameCryptor>[];
  final List<Timer> _retirements = <Timer>[];
  Timer? _periodic;
  Timer? _pendingRotation;
  DateTime? _lastRotation;
  Future<void> _queue = Future<void>.value();
  bool _installed = false;
  bool _disposed = false;

  bool get installed => _installed;
  int get sendEpoch => _send.current;
  int get receiveEpoch => _receive.current;

  /// Epochs of the other side's chain the ring holds right now.
  @visibleForTesting
  Set<int> get receiveEpochs => _receive.keys.keys.toSet();

  @visibleForTesting
  Set<int> get sendEpochs => _send.keys.keys.toSet();

  /// Completes once every step queued so far has run.
  @visibleForTesting
  Future<void> get idle => _queue;

  Future<void> _serial(Future<void> Function() operation) {
    final Future<void> next = _queue.then((_) {
      if (_disposed) {
        return null;
      }
      return operation();
    });
    _queue = next.catchError((Object error, StackTrace stackTrace) {
      logZenError('Media key schedule step failed', error, stackTrace);
    });
    return next;
  }

  /// Both chains from the call's shared [secret]; frames can flow after.
  Future<void> install(Uint8List secret) => _serial(() async {
    if (_installed) {
      return;
    }
    final Uint8List send = await deriveMediaChainKey(
      secret: secret,
      callId: callId,
      senderId: localId,
      receiverId: remoteId,
    );
    final Uint8List receive = await deriveMediaChainKey(
      secret: secret,
      callId: callId,
      senderId: remoteId,
      receiverId: localId,
    );
    await _put(_send, 0, send);
    await _put(_receive, 0, receive);
    await _extend(_send, kMediaKeyLookahead);
    await _extend(_receive, kMediaKeyLookahead);
    _installed = true;
    for (final MediaFrameCryptor cryptor in _senders) {
      await cryptor.setKeyIndex(mediaKeyIndex(_send.current));
    }
    _periodic = _clock.every(rotationInterval, () => unawaited(rotate()));
  });

  /// Installs [key] for [epoch]; an epoch that shared its slot is gone.
  Future<void> _put(_Chain chain, int epoch, Uint8List key) async {
    await ring.setKey(chain.participantId, mediaKeyIndex(epoch), key);
    chain.keys.removeWhere(
      (int other, Uint8List _) =>
          other != epoch && mediaKeyIndex(other) == mediaKeyIndex(epoch),
    );
    chain.keys[epoch] = key;
    if (epoch > chain.highest) {
      chain.highest = epoch;
    }
  }

  /// The key of [epoch] (above the highest installed one), ratcheted in
  /// memory: the epochs in between are never installed.
  Future<Uint8List> _ratchetTo(_Chain chain, int epoch) async {
    int at = chain.highest;
    Uint8List key = chain.keys[at]!;
    while (at < epoch) {
      at += 1;
      key = await ratchetMediaKey(
        key,
        callId: callId,
        senderId: chain.participantId,
        epoch: at,
      );
    }
    return key;
  }

  /// Installs [chain] up to `current + ahead` (at most a ring's worth, so
  /// the slot in use is never overwritten).
  Future<void> _extend(_Chain chain, int ahead) async {
    final int limit = chain.current + min(ahead, kMediaKeyRingSize - 2);
    while (chain.highest < limit) {
      final int epoch = chain.highest + 1;
      await _put(chain, epoch, await _ratchetTo(chain, epoch));
    }
  }

  /// Drops every key of [chain] below its current epoch after
  /// [kMediaKeyOverlap]: the slot gets a random key, so nothing older can
  /// be opened any more.
  void _retireOld(_Chain chain) {
    final int below = chain.current;
    _retirements.removeWhere((Timer timer) => !timer.isActive);
    _retirements.add(
      _clock.after(kMediaKeyOverlap, () {
        unawaited(
          _serial(() async {
            for (final int epoch in chain.keys.keys.toList()) {
              if (epoch < below) {
                chain.keys.remove(epoch);
                await ring.setKey(
                  chain.participantId,
                  mediaKeyIndex(epoch),
                  _randomKey(),
                );
              }
            }
          }),
        );
      }),
    );
  }

  /// A sender transformer of this connection: it seals with the current
  /// key; before [install] it drops frames (never sends them in clear).
  Future<void> addSender(MediaFrameCryptor cryptor) => _serial(() async {
    _senders.add(cryptor);
    await cryptor.setKeyIndex(mediaKeyIndex(_send.current));
    await cryptor.setEnabled(true);
  });

  Future<void> addReceiver(MediaFrameCryptor cryptor) => _serial(() async {
    _receivers.add(cryptor);
    await cryptor.setEnabled(true);
  });

  /// Moves this side's chain forward: the next key is already in the other
  /// side's ring, so the switch is immediate; [onRotated] tells it to
  /// prepare the one after. Rotations in quick succession are merged.
  Future<void> rotate() {
    if (_disposed || !_installed) {
      return Future<void>.value();
    }
    final DateTime now = _clock.now();
    final DateTime? last = _lastRotation;
    if (last != null) {
      final Duration since = now.difference(last);
      if (since < kMediaKeyMinRotationSpacing) {
        _pendingRotation ??= _clock.after(
          kMediaKeyMinRotationSpacing - since,
          () {
            _pendingRotation = null;
            unawaited(rotate());
          },
        );
        return Future<void>.value();
      }
    }
    _lastRotation = now;
    return _serial(() async {
      _send.current += 1;
      await _extend(_send, kMediaKeyLookahead);
      for (final MediaFrameCryptor cryptor in _senders) {
        await cryptor.setKeyIndex(mediaKeyIndex(_send.current));
      }
      _retireOld(_send);
      onRotated?.call(_send.current);
    });
  }

  /// The other side moved its chain to [epoch].
  Future<void> remoteAdvanced(int epoch) => _serial(() async {
    if (!_installed ||
        epoch <= _receive.current ||
        epoch > _receive.current + kMediaKeyMaxEpochJump) {
      return;
    }
    if (epoch > _receive.highest) {
      // Notices were lost and the sender is past every key installed.
      await _put(_receive, epoch, await _ratchetTo(_receive, epoch));
    }
    _receive.current = epoch;
    await _extend(_receive, kMediaKeyLookahead);
    _retireOld(_receive);
  });

  /// A frame named a slot without a key (a rotation notice was lost):
  /// installs more of the other side's chain.
  Future<void> missingKey() => _serial(() async {
    if (_installed) {
      await _extend(_receive, _receive.highest - _receive.current + 2);
    }
  });

  /// Frames go out and come in as they are (DTLS-SRTP only).
  Future<void> disableAll() => _serial(() async {
    for (final MediaFrameCryptor cryptor in <MediaFrameCryptor>[
      ..._senders,
      ..._receivers,
    ]) {
      await cryptor.setEnabled(false);
    }
  });

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _periodic?.cancel();
    _pendingRotation?.cancel();
    for (final Timer timer in _retirements) {
      timer.cancel();
    }
    _retirements.clear();
    _disposed = true;
    await _queue;
    for (final MediaFrameCryptor cryptor in <MediaFrameCryptor>[
      ..._senders,
      ..._receivers,
    ]) {
      try {
        await cryptor.dispose();
      } on Object catch (error) {
        logZenWarning('Releasing a frame cryptor failed: $error');
      }
    }
    _senders.clear();
    _receivers.clear();
    _send.keys.clear();
    _receive.keys.clear();
  }
}

/// Media encryption of one peer connection: the hybrid KEM exchange in the
/// offer/answer, the key schedule, and a transformer on every sender and
/// receiver of the connection.
final class MediaE2eeChannel {
  MediaE2eeChannel({
    required MediaKeyRing ring,
    required String callId,
    required this.localId,
    required this.remoteId,
    HybridKem? kem,
    MediaKeyClock clock = kSystemMediaKeyClock,
    void Function(int epoch)? onRotated,
    this.onChanged,
  }) : _ring = ring,
       _kem = kem,
       link = MediaKeyLink(
         ring: ring,
         callId: callId,
         localId: localId,
         remoteId: remoteId,
         clock: clock,
         onRotated: onRotated,
       );

  /// A channel, or `null` when this device cannot encrypt frames.
  static Future<MediaE2eeChannel?> open({
    required MediaFrameCryptoBackend backend,
    required String callId,
    required String localId,
    required String remoteId,
    HybridKem? kem,
    MediaKeyClock clock = kSystemMediaKeyClock,
    void Function(int epoch)? onRotated,
    VoidCallback? onChanged,
  }) async {
    final MediaKeyRing? ring = await backend.openKeyRing();
    if (ring == null) {
      return null;
    }
    return MediaE2eeChannel(
      ring: ring,
      callId: callId,
      localId: localId,
      remoteId: remoteId,
      kem: kem,
      clock: clock,
      onRotated: onRotated,
      onChanged: onChanged,
    );
  }

  final MediaKeyRing _ring;
  final HybridKem? _kem;
  final String localId;
  final String remoteId;
  final MediaKeyLink link;
  VoidCallback? onChanged;

  final Set<String> _attachedSenders = <String>{};
  final Set<String> _attachedReceivers = <String>{};
  Uint8List? _seed;
  Map<String, dynamic>? _answer;
  CallMediaSecurity _security = CallMediaSecurity.negotiating;
  bool _disposed = false;

  HybridKem get _hybrid => _kem ?? hybridKem;
  String get callId => link.callId;

  /// A sender went out without its transformer (sealing it failed): its
  /// frames carry only the transport's encryption, so the call is not
  /// shown as post-quantum any more.
  bool _plainSender = false;

  /// What the call shows.
  CallMediaSecurity get security =>
      _plainSender && _security == CallMediaSecurity.postQuantum
      ? CallMediaSecurity.standard
      : _security;

  /// What the key agreement gave (standard: the other side cannot encrypt
  /// frames, so neither side does).
  CallMediaSecurity get negotiated => _security;

  void _setSecurity(CallMediaSecurity value) {
    if (_security == value) {
      return;
    }
    _security = value;
    onChanged?.call();
  }

  /// The offering side's block: a fresh hybrid public key for this call.
  Future<Map<String, dynamic>> offerBlock() async {
    final Uint8List seed = _seed ??= randomHybridSeed();
    final Uint8List publicKey = await _hybrid.publicKeyOf(seed);
    return <String, dynamic>{
      'v': kMediaE2eeVersion,
      'pk': base64Url.encode(publicKey),
    };
  }

  /// The answering side: encapsulates a secret to the offer's key and
  /// installs the keys. Returns the block for the answer, or `null` when
  /// the offer carries none (the call then stays [CallMediaSecurity.standard]
  /// and the caller must [fallBack]).
  Future<Map<String, dynamic>?> answerOffer(
    Object? block, {
    required String offererId,
    required String answererId,
  }) async {
    final Map<String, dynamic>? earlier = _answer;
    if (earlier != null) {
      // The same offer again: the secret is already in use.
      return earlier;
    }
    final Uint8List? publicKey = block is Map && block['v'] == kMediaE2eeVersion
        ? decodeHybridPublicKey(block['pk'])
        : null;
    if (publicKey == null) {
      return null;
    }
    final HybridEncapsulation sealed = await _hybrid.encapsulate(
      publicKey,
      info: mediaKemInfo(
        callId: callId,
        offererId: offererId,
        answererId: answererId,
      ),
    );
    await link.install(sealed.secret);
    _setSecurity(CallMediaSecurity.postQuantum);
    return _answer = <String, dynamic>{
      'v': kMediaE2eeVersion,
      'ct': base64Url.encode(sealed.ciphertext),
    };
  }

  /// The offering side, once the answer is in: installs the keys, or falls
  /// back to DTLS-SRTP alone when the answer carries no block.
  Future<void> acceptAnswer(
    Object? block, {
    required String offererId,
    required String answererId,
  }) async {
    if (link.installed) {
      return;
    }
    final Uint8List? seed = _seed;
    final Uint8List? ciphertext =
        block is Map && block['v'] == kMediaE2eeVersion
        ? _decodeCiphertext(block['ct'])
        : null;
    if (seed == null || ciphertext == null) {
      await fallBack();
      return;
    }
    final Uint8List secret = await _hybrid.decapsulate(
      seed,
      ciphertext,
      info: mediaKemInfo(
        callId: callId,
        offererId: offererId,
        answererId: answererId,
      ),
    );
    _seed = null;
    await link.install(secret);
    _setSecurity(CallMediaSecurity.postQuantum);
  }

  static Uint8List? _decodeCiphertext(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    try {
      final Uint8List bytes = base64Url.decode(base64Url.normalize(value));
      return bytes.length == kHybridCiphertextBytes ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  /// The other side cannot encrypt frames: everything passes as it is.
  Future<void> fallBack() async {
    await link.disableAll();
    _setSecurity(CallMediaSecurity.standard);
  }

  /// Puts a transformer on every sender and receiver of [connection] that
  /// has none yet. Runs after each local/remote description, so tracks
  /// added later (camera, shared screen) are covered before they carry
  /// anything. Nothing here is per frame. One at a time, and [dispose]
  /// waits for the one running: the call's connection is closed only after
  /// [dispose], and a sender looked up on a connection already closed
  /// reaches native code as null and crashes the app (a call to a friend
  /// who is offline ends while its offer is still being made).
  Future<void> attachAll(RTCPeerConnection connection) {
    final Future<void> run = _attaching.then((_) => _attachAll(connection));
    _attaching = run.catchError((Object _) {});
    return run;
  }

  Future<void> _attaching = Future<void>.value();

  Future<void> _attachAll(RTCPeerConnection connection) async {
    if (_disposed || _security == CallMediaSecurity.standard) {
      return;
    }
    final List<RTCRtpTransceiver> transceivers;
    final Set<String> senders;
    final Set<String> receivers;
    try {
      transceivers = await connection.getTransceivers();
      // Only what the connection really has: flutter_webrtc looks a sender
      // or receiver up by its id and hands a missing one to native code as
      // null, which crashes the whole app (SIGSEGV in
      // FrameCryptorFactory.nativeCreateFrameCryptorForRtpSender) — a
      // stopped transceiver has none there. A sender without a track yet
      // (the camera before its first frame) is there and is sealed now, so
      // its frames are encrypted from the first one, as the other side
      // expects.
      senders = <String>{
        for (final RTCRtpSender s in await connection.getSenders()) s.senderId,
      };
      receivers = <String>{
        for (final RTCRtpReceiver r in await connection.getReceivers())
          r.receiverId,
      };
    } on Object catch (error) {
      logZenWarning('Reading transceivers for media keys failed: $error');
      return;
    }
    for (final RTCRtpTransceiver transceiver in transceivers) {
      if (_disposed) {
        return;
      }
      final RTCRtpSender sender = transceiver.sender;
      if (senders.contains(sender.senderId) &&
          _attachedSenders.add(sender.senderId)) {
        try {
          await link.addSender(await _ring.attachSender(sender, localId));
        } on Object catch (error, stackTrace) {
          logZenError('Sealing a media sender failed', error, stackTrace);
          if (!_plainSender) {
            _plainSender = true;
            onChanged?.call();
          }
        }
      }
      final RTCRtpReceiver receiver = transceiver.receiver;
      if (_disposed) {
        return;
      }
      if (receivers.contains(receiver.receiverId) &&
          _attachedReceivers.add(receiver.receiverId)) {
        try {
          await link.addReceiver(
            await _ring.attachReceiver(
              receiver,
              remoteId,
              onMissingKey: () => unawaited(link.missingKey()),
            ),
          );
        } on Object catch (error, stackTrace) {
          logZenError('Opening a media receiver failed', error, stackTrace);
        }
      }
    }
  }

  /// The other side's [kCallMediaKeySignal] / [kGroupMediaKeySignal].
  Future<void> remoteAdvanced(Object? epoch) async {
    if (epoch is int) {
      await link.remoteAdvanced(epoch);
    }
  }

  Future<void> rotate() => link.rotate();

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    onChanged = null;
    // A transformer being put on now goes on before the connection closes.
    await _attaching;
    await link.dispose();
    try {
      await _ring.dispose();
    } on Object catch (error) {
      logZenWarning('Releasing the media key ring failed: $error');
    }
  }
}

/// Somebody joined or left a group call: the keys of every other leg move
/// forward (each leg already has its own KEM secret, so nobody ever holds
/// the keys of a leg they are not on; this also retires the old keys).
Future<void> rekeyMediaChannels(Iterable<MediaE2eeChannel?> others) =>
    Future.wait(<Future<void>>[
      for (final MediaE2eeChannel? channel in others)
        if (channel != null) channel.rotate(),
    ]);

/// [MediaFrameCryptoBackend] over flutter_webrtc's FrameCryptor (Android,
/// iOS, macOS, Windows, Linux). AES-GCM per frame (AES-128: libwebrtc
/// fixes the key size, see the top of this file), keys derived in the ring
/// with HKDF (PBKDF2 would stall the media thread on every `setKey`).
final class WebRtcFrameCryptoBackend implements MediaFrameCryptoBackend {
  const WebRtcFrameCryptoBackend();

  @override
  Future<MediaKeyRing?> openKeyRing() async {
    try {
      final KeyProvider provider = await frameCryptorFactory
          .createDefaultKeyProvider(
            KeyProviderOptions(
              sharedKey: false,
              ratchetSalt: Uint8List.fromList(utf8.encode(_label)),
              ratchetWindowSize: 0,
              keyRingSize: kMediaKeyRingSize,
              discardFrameWhenCryptorNotReady: true,
              keyDerivationAlgorithm: KeyDerivationAlgorithm.kHKDF,
            ),
          );
      return _WebRtcKeyRing(provider);
    } on Object catch (error) {
      logZenWarning(
        'No frame encryption on this device, calls use DTLS-SRTP: $error',
      );
      return null;
    }
  }
}

final class _WebRtcKeyRing implements MediaKeyRing {
  _WebRtcKeyRing(this._provider);

  final KeyProvider _provider;

  @override
  Future<void> setKey(String participantId, int index, Uint8List key) async {
    await _provider.setKey(
      participantId: participantId,
      index: index,
      key: key,
    );
  }

  @override
  Future<MediaFrameCryptor> attachSender(
    RTCRtpSender sender,
    String participantId,
  ) async => _WebRtcFrameCryptor(
    await frameCryptorFactory.createFrameCryptorForRtpSender(
      participantId: participantId,
      sender: sender,
      algorithm: Algorithm.kAesGcm,
      keyProvider: _provider,
    ),
  );

  @override
  Future<MediaFrameCryptor> attachReceiver(
    RTCRtpReceiver receiver,
    String participantId, {
    void Function()? onMissingKey,
  }) async {
    final FrameCryptor cryptor = await frameCryptorFactory
        .createFrameCryptorForRtpReceiver(
          participantId: participantId,
          receiver: receiver,
          algorithm: Algorithm.kAesGcm,
          keyProvider: _provider,
        );
    cryptor.onFrameCryptorStateChanged = (String _, FrameCryptorState state) {
      if (state == FrameCryptorState.FrameCryptorStateMissingKey) {
        onMissingKey?.call();
      }
    };
    return _WebRtcFrameCryptor(cryptor);
  }

  @override
  Future<void> dispose() => _provider.dispose();
}

final class _WebRtcFrameCryptor implements MediaFrameCryptor {
  _WebRtcFrameCryptor(this._cryptor);

  final FrameCryptor _cryptor;

  @override
  Future<void> setKeyIndex(int index) async {
    await _cryptor.setKeyIndex(index);
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    await _cryptor.setEnabled(enabled);
  }

  @override
  Future<void> dispose() async {
    _cryptor.onFrameCryptorStateChanged = null;
    await _cryptor.dispose();
  }
}
