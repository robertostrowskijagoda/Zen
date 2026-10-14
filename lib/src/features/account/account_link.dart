import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Linking a new device to the account (§6, several devices).
///
/// The new device shows its invitation code (the same one friends use).
/// The device that already has the account sends the account key to that
/// address, end to end encrypted with a one-time key pair on each side.
/// Both screens show the same 6 digits computed from both one-time keys;
/// the user checks they match before anything is sent and before the new
/// device takes the key, so nobody in between (a relay, a forged answer)
/// can slip in their own key.
///
/// Six digits are only safe if nobody in between can choose their key
/// after seeing the other one: otherwise they try a million keys in a few
/// seconds until the digits fit. So the old device first sends only a
/// commitment to its key (a hash), the new device answers with its key,
/// and only then does the old device reveal its own. Every key is fixed
/// before the other side's is known; a man in the middle gets one blind
/// guess (1 in 1 000 000), and a mismatch shows.
///
/// Messages (version 2): `al_hello {v: 2, c}` (old → new, commitment),
/// `al_key {v: 2, e}` (new → old), `al_reveal {e}` (old → new),
/// `al_seed {n, c}` (old → new), `al_done` (new → old). A hello without a
/// commitment or with another version is ignored.
const String kLinkHelloType = 'al_hello';
const String kLinkKeyType = 'al_key';
const String kLinkRevealType = 'al_reveal';
const String kLinkSeedType = 'al_seed';
const String kLinkDoneType = 'al_done';

/// The linking protocol this app speaks (commit, then reveal).
const int kLinkProtocolVersion = 2;

/// What the new device receives.
@immutable
final class LinkedAccount {
  const LinkedAccount({
    required this.seed,
    required this.account,
    required this.siblings,
    required this.from,
  });

  /// The account key's seed.
  final Uint8List seed;

  /// The account (public key).
  final String account;

  /// Addresses of the account's devices (to greet first).
  final List<String> siblings;

  /// Address of the device that sent it.
  final String from;
}

final X25519 _x25519 = X25519();
final Chacha20 _aead = Chacha20.poly1305Aead();

/// The session key of one linking.
@visibleForTesting
Future<SecretKey> linkSessionKey({
  required SimpleKeyPair mine,
  required List<int> theirs,
  required List<int> helloKey,
  required List<int> answerKey,
}) async {
  final SecretKey shared = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
  );
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    info: utf8.encode('zen.link.v2'),
    nonce: <int>[...helloKey, ...answerKey],
  );
}

/// The commitment the old device sends instead of its one-time key.
Future<Uint8List> linkCommitment(List<int> helloKey) async {
  final Hash h = await Sha256().hash(<int>[
    ...utf8.encode('zen.link.commit.v2'),
    ...helloKey,
  ]);
  return Uint8List.fromList(h.bytes);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// The 6 digits both screens show (from both one-time keys).
Future<String> linkCheckDigits(SecretKey key) async {
  final Hash h = await Sha256().hash(<int>[
    ...await key.extractBytes(),
    ...utf8.encode('zen.link.sas'),
  ]);
  final int n =
      ((h.bytes[0] << 24) |
          (h.bytes[1] << 16) |
          (h.bytes[2] << 8) |
          h.bytes[3]) &
      0x7FFFFFFF;
  final String digits = (n % 1000000).toString().padLeft(6, '0');
  return '${digits.substring(0, 3)} ${digits.substring(3)}';
}

Uint8List? _key32(Object? value) => unb64(value, length: 32);

/// The device that already has the account: sends it to a new device.
final class AccountLinkSender {
  AccountLinkSender({
    required this.transport,
    required this.target,
    this.timeout = const Duration(seconds: 60),
  });

  final SignalTransport transport;

  /// The new device's mesh address.
  final String target;
  final Duration timeout;

  SimpleKeyPair? _mine;
  Uint8List? _helloKey;
  SecretKey? _key;
  StreamSubscription<SignalTransportFrame>? _sub;
  Completer<void>? _done;

  bool _from(SignalTransportFrame f) =>
      PeerShareCodec.addressesEqual(f.from, target);

  /// Greets the new device with a commitment to this device's one-time
  /// key, waits for its key, then reveals this one. Returns the 6 digits to
  /// compare with its screen.
  Future<String> start() async {
    final SimpleKeyPair mine = await _x25519.newKeyPair();
    final Uint8List pub = Uint8List.fromList(
      (await mine.extractPublicKey()).bytes,
    );
    _mine = mine;
    _helloKey = pub;
    final Completer<Uint8List> answer = Completer<Uint8List>();
    final Completer<void> done = Completer<void>();
    _done = done;
    _sub = transport.frames.listen((SignalTransportFrame f) {
      if (!_from(f)) {
        return;
      }
      final Object? type = f.payload['type'];
      if (type == kLinkKeyType && !answer.isCompleted) {
        final Uint8List? theirs = _key32(f.payload['e']);
        if (theirs != null) {
          answer.complete(theirs);
        }
      } else if (type == kLinkDoneType && !done.isCompleted) {
        done.complete();
      }
    });
    // Only the commitment: the key itself stays back until the new
    // device's key is fixed.
    await transport.send(
      remoteAddress: target,
      payload: <String, dynamic>{
        'type': kLinkHelloType,
        'v': kLinkProtocolVersion,
        'c': b64(await linkCommitment(pub)),
      },
    );
    final Uint8List theirs = await answer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Nowe urządzenie nie odpowiada. Czy pokazuje kod do podłączenia? '
        'Oba urządzenia muszą mieć aktualną wersję Zen.',
      ),
    );
    await transport.send(
      remoteAddress: target,
      payload: <String, dynamic>{'type': kLinkRevealType, 'e': b64(pub)},
    );
    _key = await linkSessionKey(
      mine: mine,
      theirs: theirs,
      helloKey: pub,
      answerKey: theirs,
    );
    return linkCheckDigits(_key!);
  }

  /// After the user saw the same digits on both screens: sends the account
  /// key. Waits until the new device confirms it took it.
  Future<void> send({
    required Uint8List seed,
    required String account,
    required List<String> siblings,
  }) async {
    final SecretKey? key = _key;
    if (key == null || _mine == null || _helloKey == null) {
      throw StateError('Najpierw połącz się z nowym urządzeniem.');
    }
    final Uint8List nonce = randomBytes(12);
    final SecretBox box = await _aead.encrypt(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'seed': b64(seed),
          'account': account,
          'siblings': siblings,
        }),
      ),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(kLinkSeedType),
    );
    await transport.send(
      remoteAddress: target,
      payload: <String, dynamic>{
        'type': kLinkSeedType,
        'n': b64(nonce),
        'c': b64(<int>[...box.cipherText, ...box.mac.bytes]),
      },
    );
    await _done!.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Nowe urządzenie nie potwierdziło. Sprawdź, czy cyfry się zgadzały.',
      ),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}

/// The new device: waits for the account from a device that has it.
final class AccountLinkReceiver {
  AccountLinkReceiver({required this.transport});

  final SignalTransport transport;

  StreamSubscription<SignalTransportFrame>? _sub;
  String? _peer;
  SecretKey? _key;

  /// What the old device promised, and this side's key pair, until its key
  /// is revealed.
  Uint8List? _commitment;
  SimpleKeyPair? _mine;
  Uint8List? _myKey;
  final Completer<String> _digits = Completer<String>();
  final Completer<LinkedAccount> _account = Completer<LinkedAccount>();

  /// The 6 digits, once a device greeted this one.
  Future<String> get digits => _digits.future;

  /// The account, once sent (only take it after the user confirmed the
  /// digits match; then call [confirm]).
  Future<LinkedAccount> get account => _account.future;

  /// Who is linking (the first device that greets wins).
  String? get peer => _peer;

  void start() {
    _sub = transport.frames.listen((SignalTransportFrame f) {
      unawaited(_onFrame(f));
    });
  }

  Future<void> _onFrame(SignalTransportFrame f) async {
    final Object? type = f.payload['type'];
    if (type == kLinkHelloType && _peer == null) {
      final Uint8List? commitment = _key32(f.payload['c']);
      if (commitment == null || f.payload['v'] != kLinkProtocolVersion) {
        return;
      }
      _peer = f.from;
      final SimpleKeyPair mine = await _x25519.newKeyPair();
      final Uint8List pub = Uint8List.fromList(
        (await mine.extractPublicKey()).bytes,
      );
      // Answer with this key; the digits come once the old device reveals
      // the key it committed to.
      _commitment = commitment;
      _mine = mine;
      _myKey = pub;
      await transport.send(
        remoteAddress: f.from,
        payload: <String, dynamic>{
          'type': kLinkKeyType,
          'v': kLinkProtocolVersion,
          'e': b64(pub),
        },
      );
      return;
    }
    if (type == kLinkRevealType &&
        _peer != null &&
        PeerShareCodec.addressesEqual(f.from, _peer!) &&
        _key == null) {
      await _onReveal(f);
      return;
    }
    if (type == kLinkSeedType &&
        _peer != null &&
        PeerShareCodec.addressesEqual(f.from, _peer!) &&
        !_account.isCompleted) {
      final LinkedAccount? got = await _open(f);
      if (got != null) {
        _account.complete(got);
      }
    }
  }

  Future<void> _onReveal(SignalTransportFrame f) async {
    final Uint8List? commitment = _commitment;
    final SimpleKeyPair? mine = _mine;
    final Uint8List? myKey = _myKey;
    final Uint8List? theirs = _key32(f.payload['e']);
    if (commitment == null || mine == null || myKey == null || theirs == null) {
      return;
    }
    if (!_sameBytes(await linkCommitment(theirs), commitment)) {
      // Not the key that was promised: someone in between. Nothing is
      // shown; the linking can start again.
      _peer = null;
      _commitment = null;
      _mine = null;
      _myKey = null;
      return;
    }
    _commitment = null;
    _mine = null;
    _myKey = null;
    _key = await linkSessionKey(
      mine: mine,
      theirs: theirs,
      helloKey: theirs,
      answerKey: myKey,
    );
    if (!_digits.isCompleted) {
      _digits.complete(await linkCheckDigits(_key!));
    }
  }

  Future<LinkedAccount?> _open(SignalTransportFrame f) async {
    final SecretKey? key = _key;
    final Uint8List? nonce = unb64(f.payload['n'], length: 12);
    final Uint8List? sealed = unb64(f.payload['c']);
    if (key == null || nonce == null || sealed == null || sealed.length < 16) {
      return null;
    }
    try {
      final List<int> plain = await _aead.decrypt(
        SecretBox(
          sealed.sublist(0, sealed.length - 16),
          nonce: nonce,
          mac: Mac(sealed.sublist(sealed.length - 16)),
        ),
        secretKey: key,
        aad: utf8.encode(kLinkSeedType),
      );
      final Object? json = jsonDecode(utf8.decode(plain));
      if (json is! Map) {
        return null;
      }
      final Uint8List? seed = unb64(json['seed'], length: 32);
      final Object? account = json['account'];
      final Object? siblings = json['siblings'];
      if (seed == null || account is! String) {
        return null;
      }
      return LinkedAccount(
        seed: seed,
        account: account,
        siblings: siblings is List
            ? siblings.whereType<String>().take(16).toList()
            : const <String>[],
        from: f.from,
      );
    } on Object {
      return null;
    }
  }

  /// Tells the sending device the account was taken.
  Future<void> confirm() async {
    final String? peer = _peer;
    if (peer != null) {
      await transport.send(
        remoteAddress: peer,
        payload: const <String, dynamic>{'type': kLinkDoneType},
      );
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}
