import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_link.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The whole account from one device to another: the key and everything
/// else ([AccountArchive]), block by block over whatever connects them
/// (the same Wi-Fi or a direct link first, the mesh otherwise).
///
/// The device that has the account shows a code (QR): its address, a
/// one-time public key and a secret token. The other device reads it and
/// greets with its own one-time key, authenticated by the token, so only
/// a device that saw the screen can ask; both show the same 6 digits and
/// nothing is sent until the person allows it on the first device. Every
/// message after the greeting is sealed (ChaCha20-Poly1305) with the key
/// both one-time keys make.
///
/// Messages:
/// * `acx_hello {v, e, m, n}`: new → old, its key, the token's tag, its
///   name;
/// * `acx_offer {c}`: old → new (sealed), the account, its key, the
///   devices to greet, and the manifest's id and size;
/// * `acx_no {}`: old → new, refused there;
/// * `acx_get {c}`: new → old (sealed), blocks of a file it lacks;
/// * `acx_block {c}`: old → new (sealed), one block;
/// * `acx_done {c}`: new → old (sealed), everything came.
abstract final class AccountCopyMessages {
  static const String hello = 'acx_hello';
  static const String offer = 'acx_offer';
  static const String no = 'acx_no';
  static const String get = 'acx_get';
  static const String block = 'acx_block';
  static const String done = 'acx_done';
}

/// The protocol this app speaks.
const int kAccountCopyVersion = 1;

/// Prefix of the code the first device shows.
const String kAccountCopyTicketPrefix = 'zen-copy:';

/// Blocks asked for at once.
const int kAccountCopyWindow = 8;

final X25519 _x25519 = X25519();
final Chacha20 _aead = Chacha20.poly1305Aead();

/// What the device with the account shows (as a QR code or text).
@immutable
final class AccountCopyTicket {
  const AccountCopyTicket({
    required this.address,
    required this.key,
    required this.token,
  });

  /// Mesh address of the device with the account.
  final String address;

  /// Its one-time public key (X25519).
  final Uint8List key;

  /// The secret only a device that read the code knows.
  final Uint8List token;

  String encode() {
    final String json = jsonEncode(<String, dynamic>{
      'v': kAccountCopyVersion,
      'a': address,
      'k': b64(key),
      't': b64(token),
    });
    return '$kAccountCopyTicketPrefix${base64Url.encode(utf8.encode(json))}';
  }

  /// The ticket in [text] (with or without its prefix), or null.
  static AccountCopyTicket? parse(String text) {
    String body = text.trim();
    if (body.startsWith(kAccountCopyTicketPrefix)) {
      body = body.substring(kAccountCopyTicketPrefix.length);
    }
    try {
      final Object? json = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(body))),
      );
      if (json is! Map || json['v'] != kAccountCopyVersion) {
        return null;
      }
      final Object? address = json['a'];
      final Uint8List? key = unb64(json['k'], length: 32);
      final Uint8List? token = unb64(json['t'], length: 16);
      if (address is! String || address.isEmpty || key == null) {
        return null;
      }
      if (token == null) {
        return null;
      }
      return AccountCopyTicket(address: address, key: key, token: token);
    } on FormatException {
      return null;
    }
  }
}

Future<Uint8List> _tag(Uint8List token, List<int> key) async {
  final Mac mac = await Hmac.sha256().calculateMac(<int>[
    ...utf8.encode('zen.copy.hello'),
    ...key,
  ], secretKey: SecretKey(token));
  return Uint8List.fromList(mac.bytes.sublist(0, 16));
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Future<SecretKey> _sessionKey({
  required SimpleKeyPair mine,
  required List<int> theirs,
  required List<int> oldKey,
  required List<int> newKey,
  required List<int> token,
}) async {
  final SecretKey shared = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
  );
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    info: utf8.encode('zen.copy.v1'),
    nonce: <int>[...token, ...oldKey, ...newKey],
  );
}

Future<Map<String, dynamic>> _seal(
  SecretKey key,
  String type,
  Map<String, dynamic> body,
) async {
  final Uint8List nonce = randomBytes(12);
  final SecretBox box = await _aead.encrypt(
    utf8.encode(jsonEncode(body)),
    secretKey: key,
    nonce: nonce,
    aad: utf8.encode(type),
  );
  return <String, dynamic>{
    'type': type,
    'c': b64(<int>[...nonce, ...box.cipherText, ...box.mac.bytes]),
  };
}

Future<Map<String, dynamic>?> _open(
  SecretKey key,
  String type,
  Map<String, dynamic> payload,
) async {
  final Uint8List? sealed = unb64(payload['c']);
  if (sealed == null || sealed.length < 28) {
    return null;
  }
  try {
    final List<int> plain = await _aead.decrypt(
      SecretBox(
        sealed.sublist(12, sealed.length - 16),
        nonce: sealed.sublist(0, 12),
        mac: Mac(sealed.sublist(sealed.length - 16)),
      ),
      secretKey: key,
      aad: utf8.encode(type),
    );
    final Object? json = jsonDecode(utf8.decode(plain));
    return json is Map ? Map<String, dynamic>.from(json) : null;
  } on Object {
    return null;
  }
}

/// A device that asked for the account, waiting for the person to allow
/// it on this one.
@immutable
final class AccountCopyRequest {
  const AccountCopyRequest({
    required this.peer,
    required this.name,
    required this.digits,
  });

  final String peer;

  /// The name it gave itself.
  final String name;

  /// The 6 digits its screen shows too.
  final String digits;
}

/// What the device with the account sends: the account, its key, the
/// devices to greet and the copy.
@immutable
final class AccountCopyContent {
  const AccountCopyContent({required this.build, required this.siblings});

  final AccountArchiveBuild build;
  final List<String> siblings;
}

/// Where a copy to another device stands, on the device that sends it.
enum AccountCopySendState { waiting, asked, sending, done, failed }

/// The device with the account: shows its ticket, waits for the other
/// device, and after the person allows it, sends everything it asks for.
final class AccountCopySource extends ChangeNotifier {
  AccountCopySource({
    required this.transport,
    required this.address,
    required this.prepare,
  });

  final SignalTransport transport;

  /// This device's mesh address (in the ticket).
  final String address;

  /// Collects the copy once the person allowed it (with the key: it is
  /// unlocked by then).
  final Future<AccountCopyContent> Function() prepare;

  SimpleKeyPair? _mine;
  Uint8List? _myKey;
  Uint8List? _token;
  StreamSubscription<SignalTransportFrame>? _sub;

  AccountCopyTicket? ticket;
  AccountCopyRequest? request;
  AccountCopySendState state = AccountCopySendState.waiting;
  SecretKey? _key;
  String? _peer;

  Uint8List? _manifest;
  String? _manifestId;
  Map<String, AccountArchiveBlob> _blobs = <String, AccountArchiveBlob>{};
  bool _disposed = false;

  /// Bytes sent and all of them (for the progress).
  int sent = 0;
  int total = 0;

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Makes the ticket to show and starts listening.
  Future<AccountCopyTicket> open() async {
    final SimpleKeyPair mine = await _x25519.newKeyPair();
    final Uint8List pub = Uint8List.fromList(
      (await mine.extractPublicKey()).bytes,
    );
    _mine = mine;
    _myKey = pub;
    _token = randomBytes(16);
    _sub = transport.frames.listen((SignalTransportFrame f) {
      unawaited(_onFrame(f));
    });
    return ticket = AccountCopyTicket(
      address: address,
      key: pub,
      token: _token!,
    );
  }

  bool _fromPeer(SignalTransportFrame f) =>
      _peer != null && PeerShareCodec.addressesEqual(f.from, _peer!);

  Future<void> _onFrame(SignalTransportFrame f) async {
    final Object? type = f.payload['type'];
    if (type == AccountCopyMessages.hello) {
      await _onHello(f);
      return;
    }
    final SecretKey? key = _key;
    if (key == null || !_fromPeer(f)) {
      return;
    }
    if (type == AccountCopyMessages.get &&
        (state == AccountCopySendState.sending ||
            state == AccountCopySendState.done)) {
      final Map<String, dynamic>? body = await _open(
        key,
        AccountCopyMessages.get,
        f.payload,
      );
      if (body != null) {
        await _serve(key, body);
      }
    } else if (type == AccountCopyMessages.done) {
      final Map<String, dynamic>? body = await _open(
        key,
        AccountCopyMessages.done,
        f.payload,
      );
      if (body != null) {
        state = AccountCopySendState.done;
        sent = total;
        _changed();
      }
    }
  }

  Future<void> _onHello(SignalTransportFrame f) async {
    final SimpleKeyPair? mine = _mine;
    final Uint8List? myKey = _myKey;
    final Uint8List? token = _token;
    // One device per ticket: a second greeting waits for a new code.
    if (mine == null ||
        myKey == null ||
        token == null ||
        _peer != null ||
        f.payload['v'] != kAccountCopyVersion) {
      return;
    }
    final Uint8List? theirs = unb64(f.payload['e'], length: 32);
    final Uint8List? tag = unb64(f.payload['m'], length: 16);
    if (theirs == null ||
        tag == null ||
        !_same(await _tag(token, theirs), tag)) {
      return;
    }
    final Object? name = f.payload['n'];
    final String given = name is String ? name.trim() : '';
    final SecretKey key = await _sessionKey(
      mine: mine,
      theirs: theirs,
      oldKey: myKey,
      newKey: theirs,
      token: token,
    );
    if (_peer != null) {
      return;
    }
    _peer = f.from;
    _key = key;
    request = AccountCopyRequest(
      peer: f.from,
      name: given.isEmpty
          ? t('Nowe urządzenie')
          : (given.length > 40 ? given.substring(0, 40) : given),
      digits: await linkCheckDigits(key),
    );
    state = AccountCopySendState.asked;
    _changed();
  }

  /// The person allowed it (the digits match): collects the copy and
  /// sends the offer; then serves the blocks asked for.
  Future<void> allow() async {
    final SecretKey? key = _key;
    final String? peer = _peer;
    if (key == null || peer == null || state != AccountCopySendState.asked) {
      return;
    }
    state = AccountCopySendState.sending;
    _changed();
    try {
      final AccountCopyContent content = await prepare();
      final AccountArchive archive = content.build.archive;
      final Uint8List manifest = Uint8List.fromList(
        utf8.encode(jsonEncode(archive.withoutSeed().toJson())),
      );
      _manifest = manifest;
      _manifestId = accountBlobId(manifest);
      _blobs = content.build.blobs;
      total = manifest.length + archive.totalBytes;
      await transport.send(
        remoteAddress: peer,
        payload: await _seal(key, AccountCopyMessages.offer, <String, dynamic>{
          'a': archive.account,
          if (archive.seed != null) 'seed': b64(archive.seed!),
          'sib': content.siblings.take(16).toList(),
          'mid': _manifestId,
          'ms': manifest.length,
          'by': total,
        }),
      );
      _changed();
    } on Object {
      state = AccountCopySendState.failed;
      _changed();
      rethrow;
    }
  }

  /// The person said no.
  Future<void> deny() async {
    final String? peer = _peer;
    if (peer != null) {
      await transport.send(
        remoteAddress: peer,
        payload: const <String, dynamic>{'type': AccountCopyMessages.no},
      );
    }
    state = AccountCopySendState.failed;
    _changed();
  }

  /// File [id] of the copy (the manifest, or one of its files), read
  /// block by block when it is asked for.
  AccountArchiveBlob? _file(String id) {
    final Uint8List? manifest = _manifest;
    if (id == _manifestId && manifest != null) {
      return AccountArchiveBlob.bytes(manifest);
    }
    return _blobs[id];
  }

  Future<void> _serve(SecretKey key, Map<String, dynamic> body) async {
    final Object? id = body['id'];
    final Object? blocks = body['i'];
    if (id is! String || blocks is! List) {
      return;
    }
    final AccountArchiveBlob? file = _file(id);
    if (file == null) {
      return;
    }
    for (final Object? i in blocks.take(kAccountCopyWindow)) {
      if (i is! int || i < 0 || i >= accountBlockCount(file.size)) {
        continue;
      }
      final int at = i * kAccountCopyBlockBytes;
      final int end = math.min(at + kAccountCopyBlockBytes, file.size);
      // Only this block is read: a file of any size, block by block.
      final Uint8List? data = await file.range(at, end);
      if (data == null || data.length != end - at) {
        continue;
      }
      await transport.send(
        remoteAddress: _peer!,
        payload: await _seal(key, AccountCopyMessages.block, <String, dynamic>{
          'id': id,
          'i': i,
          'd': b64(data),
        }),
      );
      sent = math.min(sent + end - at, total);
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    super.dispose();
  }
}

/// What the device with the account offered (after the person allowed
/// it there).
@immutable
final class AccountCopyOffer {
  const AccountCopyOffer({
    required this.account,
    required this.seed,
    required this.siblings,
    required this.manifestId,
    required this.manifestSize,
    required this.totalBytes,
  });

  final String account;
  final Uint8List? seed;
  final List<String> siblings;
  final String manifestId;
  final int manifestSize;
  final int totalBytes;
}

/// The device that takes the account: greets the one in the ticket,
/// shows the digits, waits for the offer and downloads the copy into
/// [staging] (what is there already is not asked again).
final class AccountCopyTarget {
  AccountCopyTarget({
    required this.transport,
    required this.ticket,
    required this.staging,
    required this.deviceName,
    this.answerTimeout = const Duration(minutes: 3),
    this.blockTimeout = const Duration(seconds: 20),
    this.retries = 6,
  });

  final SignalTransport transport;
  final AccountCopyTicket ticket;
  final AccountImportStaging staging;
  final String deviceName;

  /// How long the person on the other device has to allow it.
  final Duration answerTimeout;
  final Duration blockTimeout;

  /// Times a block is asked again before giving up.
  final int retries;

  SecretKey? _key;
  StreamSubscription<SignalTransportFrame>? _sub;
  final Completer<AccountCopyOffer?> _offer = Completer<AccountCopyOffer?>();
  final Map<String, Completer<Uint8List>> _waiting =
      <String, Completer<Uint8List>>{};

  bool _from(SignalTransportFrame f) =>
      PeerShareCodec.addressesEqual(f.from, ticket.address);

  /// Greets the device in the ticket; returns the digits to compare.
  Future<String> hello() async {
    final SimpleKeyPair mine = await _x25519.newKeyPair();
    final Uint8List pub = Uint8List.fromList(
      (await mine.extractPublicKey()).bytes,
    );
    final SecretKey key = await _sessionKey(
      mine: mine,
      theirs: ticket.key,
      oldKey: ticket.key,
      newKey: pub,
      token: ticket.token,
    );
    _key = key;
    _sub = transport.frames.listen((SignalTransportFrame f) {
      if (_from(f)) {
        unawaited(_onFrame(key, f));
      }
    });
    await transport.send(
      remoteAddress: ticket.address,
      payload: <String, dynamic>{
        'type': AccountCopyMessages.hello,
        'v': kAccountCopyVersion,
        'e': b64(pub),
        'm': b64(await _tag(ticket.token, pub)),
        'n': deviceName,
      },
    );
    return linkCheckDigits(key);
  }

  Future<void> _onFrame(SecretKey key, SignalTransportFrame f) async {
    final Object? type = f.payload['type'];
    if (type == AccountCopyMessages.no && !_offer.isCompleted) {
      _offer.complete(null);
    } else if (type == AccountCopyMessages.offer && !_offer.isCompleted) {
      final Map<String, dynamic>? body = await _open(
        key,
        AccountCopyMessages.offer,
        f.payload,
      );
      final Object? account = body?['a'];
      final Object? mid = body?['mid'];
      final Object? ms = body?['ms'];
      if (body == null || account is! String || mid is! String || ms is! int) {
        return;
      }
      final Object? sib = body['sib'];
      final Object? by = body['by'];
      if (!_offer.isCompleted) {
        _offer.complete(
          AccountCopyOffer(
            account: account,
            seed: unb64(body['seed'], length: 32),
            siblings: sib is List
                ? sib.whereType<String>().take(16).toList()
                : const <String>[],
            manifestId: mid,
            manifestSize: ms,
            totalBytes: by is int ? by : ms,
          ),
        );
      }
    } else if (type == AccountCopyMessages.block) {
      final Map<String, dynamic>? body = await _open(
        key,
        AccountCopyMessages.block,
        f.payload,
      );
      final Object? id = body?['id'];
      final Object? i = body?['i'];
      final Uint8List? data = unb64(body?['d']);
      if (id is String && i is int && data != null) {
        final Completer<Uint8List>? waiting = _waiting.remove('$id/$i');
        if (waiting != null && !waiting.isCompleted) {
          waiting.complete(data);
        }
      }
    }
  }

  /// The offer, once the person allowed it on the other device; null
  /// when they refused.
  Future<AccountCopyOffer?> offer() => _offer.future.timeout(
    answerTimeout,
    onTimeout: () => throw TimeoutException(
      t('Drugie urządzenie nie odpowiada. Czy pokazuje kod?'),
    ),
  );

  /// Downloads the copy of [offer]: the manifest, then every file not
  /// here yet. [progress] counts bytes. Returns the copy (with the key
  /// when it came).
  Future<AccountArchive> download(
    AccountCopyOffer offer, {
    void Function(int done, int total)? progress,
  }) async {
    final SecretKey? key = _key;
    if (key == null) {
      throw StateError('Greet the other device first.');
    }
    int done = 0;
    final int total = offer.totalBytes;
    void moved(int n) {
      done += n;
      progress?.call(done.clamp(0, total), total);
    }

    await _fetch(key, offer.manifestId, offer.manifestSize, moved);
    final Uint8List? raw = await staging.read(
      offer.manifestId,
      offer.manifestSize,
    );
    AccountArchive? archive;
    try {
      archive = raw == null
          ? null
          : AccountArchive.fromJson(jsonDecode(utf8.decode(raw)));
    } on FormatException {
      archive = null;
    }
    if (archive == null || archive.account != offer.account) {
      throw StateError(t('Kopia z drugiego urządzenia jest uszkodzona.'));
    }
    for (final MapEntry<String, int> f in archive.files.entries) {
      await _fetch(key, f.key, f.value, moved);
    }
    await staging.dropFile(offer.manifestId, offer.manifestSize);
    await transport.send(
      remoteAddress: ticket.address,
      payload: await _seal(key, AccountCopyMessages.done, <String, dynamic>{
        'ok': true,
      }),
    );
    final Uint8List? seed = offer.seed;
    return seed == null ? archive : archive.withSeed(seed);
  }

  /// One file, block by block; blocks already staged are skipped.
  Future<void> _fetch(
    SecretKey key,
    String id,
    int size,
    void Function(int n) moved,
  ) async {
    for (int round = 0; round < 2; round++) {
      final List<int> missing = <int>[];
      for (int i = 0; i < accountBlockCount(size); i++) {
        if (await staging.hasBlock(id, i)) {
          moved(_blockSize(size, i));
        } else {
          missing.add(i);
        }
      }
      for (int at = 0; at < missing.length; at += kAccountCopyWindow) {
        final List<int> batch = missing.sublist(
          at,
          (at + kAccountCopyWindow).clamp(0, missing.length),
        );
        await _fetchBatch(key, id, size, batch, moved);
      }
      if (await staging.has(id, size)) {
        return;
      }
      // Damaged on the way or on disk: once more from the start.
      await staging.dropFile(id, size);
    }
    throw StateError(t('Kopia z drugiego urządzenia jest uszkodzona.'));
  }

  static int _blockSize(int size, int i) {
    final int at = i * kAccountCopyBlockBytes;
    return (size - at).clamp(0, kAccountCopyBlockBytes);
  }

  Future<void> _fetchBatch(
    SecretKey key,
    String id,
    int size,
    List<int> batch,
    void Function(int n) moved,
  ) async {
    List<int> left = batch;
    for (int attempt = 0; left.isNotEmpty; attempt++) {
      if (attempt > retries) {
        throw TimeoutException(
          t(
            'Drugie urządzenie przestało odpowiadać. Spróbuj jeszcze raz — '
            'to, co już przyszło, zostanie.',
          ),
        );
      }
      final Map<int, Future<Uint8List>> asked = <int, Future<Uint8List>>{
        for (final int i in left)
          i: (_waiting['$id/$i'] ??= Completer<Uint8List>()).future,
      };
      await transport.send(
        remoteAddress: ticket.address,
        payload: await _seal(key, AccountCopyMessages.get, <String, dynamic>{
          'id': id,
          'i': left,
        }),
      );
      final List<int> still = <int>[];
      for (final MapEntry<int, Future<Uint8List>> e in asked.entries) {
        try {
          final Uint8List data = await e.value.timeout(blockTimeout);
          if (data.length != _blockSize(size, e.key)) {
            still.add(e.key);
            continue;
          }
          await staging.putBlock(id, e.key, data);
          moved(data.length);
        } on TimeoutException {
          still.add(e.key);
        }
      }
      left = still;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _waiting.clear();
  }
}
