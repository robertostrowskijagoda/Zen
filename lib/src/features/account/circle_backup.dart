import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';

/// The copy of an account's data kept by the people of its recovery
/// circle ("Kopia u kręgu").
///
/// What is in it: the profile (without photos), friends and groups with
/// their levels, the settings, the pyramid state this person keeps (votes,
/// private data, the power key of the head), a wallet statement, and —
/// unless turned off — the text of the conversations (no photos, videos or
/// files: ids, times, authors, text).
///
/// How it is kept: every piece of it (a section, one month of one
/// conversation) is split into chunks of at most [kCircleBackupChunkBytes],
/// each sealed with ChaCha20-Poly1305 under a key derived from the account
/// key (via the self key, so a recovered account — paper copy, key file or
/// circle — opens it, and nobody else). The nonce is derived from the chunk
/// itself: an unchanged piece gives the same chunk, so a refresh sends
/// only what changed. A chunk is named by its hash. Which chunk is which
/// piece is in a sealed index; the holders see only hashes and sizes. The
/// list of chunks (the manifest) is signed with the device key (hybrid
/// Ed25519 + ML-DSA-65) and carries the device's certificate, signed by
/// the account key.
const String kCircleBackupType = 'zen_cbk';

/// Most bytes one copy takes at a holder.
const int kCircleBackupMaxBytes = 10 * 1024 * 1024;

/// Largest chunk (plain), well under a signal's 2 MiB.
const int kCircleBackupChunkBytes = 192 * 1024;

/// Section names.
abstract final class CircleBackupSections {
  static const String profile = 'profile';
  static const String contacts = 'contacts';
  static const String levels = 'levels';
  static const String settings = 'settings';
  static const String pyramid = 'pyramid';
  static const String wallet = 'wallet';

  /// The household (neighbours): its key, this resident's key, profile.
  static const String household = 'household';

  /// The dating profile and its settings, without photos.
  static const String dating = 'dating';
}

/// What a copy holds, in plain JSON.
@immutable
final class CircleBackupContent {
  const CircleBackupContent({
    this.sections = const <String, Object?>{},
    this.chats = const <String, List<Map<String, dynamic>>>{},
  });

  /// [CircleBackupSections] → value.
  final Map<String, Object?> sections;

  /// Conversation key → its messages (`chatMessageToSync`), oldest first.
  final Map<String, List<Map<String, dynamic>>> chats;

  int get messageCount => chats.values.fold(
    0,
    (int sum, List<Map<String, dynamic>> m) => sum + m.length,
  );
}

/// A built copy: the signed manifest and the chunks it names.
@immutable
final class CircleBackupBuild {
  const CircleBackupBuild({
    required this.manifest,
    required this.chunks,
    required this.droppedMessages,
  });

  final CircleBackupManifest manifest;

  /// Chunk id → sealed bytes.
  final Map<String, Uint8List> chunks;

  /// Chat messages left out to stay under the size cap (the oldest).
  final int droppedMessages;
}

/// The signed list of a copy's chunks: all a holder sees.
@immutable
final class CircleBackupManifest {
  const CircleBackupManifest._(this.json);

  /// As sent and stored.
  final Map<String, dynamic> json;

  String get account => json['a'] as String;
  int get createdAt => json['at'] as int;

  /// Chunk id → size.
  Map<String, int> get chunks => <String, int>{
    for (final Object? c in json['ch'] as List)
      (c as List)[0] as String: c[1] as int,
  };

  /// The chunks of the sealed index, in order.
  List<String> get index => (json['ix'] as List).cast<String>();

  int get totalBytes => chunks.values.fold(0, (int a, int b) => a + b);

  /// Its own id (the hash of its signed body).
  String get id => sha256Hex(utf8.encode(jsonEncode(json))).substring(0, 32);

  /// [json] as a manifest, if it is well-formed (not yet verified).
  static CircleBackupManifest? parse(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['t'] != kCircleBackupType ||
        json['v'] != 1 ||
        json['a'] is! String ||
        json['at'] is! int ||
        json['ch'] is! List ||
        json['ix'] is! List ||
        json['cert'] is! Map ||
        json['sig'] is! String) {
      return null;
    }
    final Set<String> ids = <String>{};
    for (final Object? c in json['ch'] as List) {
      if (c is! List ||
          c.length != 2 ||
          c[0] is! String ||
          !_isChunkId(c[0] as String) ||
          c[1] is! int ||
          (c[1] as int) <= 0 ||
          (c[1] as int) > kCircleBackupChunkBytes + 64 ||
          !ids.add(c[0] as String)) {
        return null;
      }
    }
    final List<Object?> index = json['ix'] as List;
    if (index.isEmpty ||
        index.any((Object? i) => i is! String || !ids.contains(i))) {
      return null;
    }
    return CircleBackupManifest._(json);
  }

  /// Whether it is signed by a device the account [account] certified
  /// (hybrid signatures: the certificate by the account key, the manifest
  /// by the device key).
  Future<bool> verify({String? account}) async {
    final DeviceCertificate? cert = DeviceCertificate.fromJson(json['cert']);
    if (cert == null ||
        cert.account != this.account ||
        (account != null && account != this.account)) {
      return false;
    }
    if (!await cert.verify()) {
      return false;
    }
    return cert.verifyByDevice(_signedBytes(json), json['sig'] as String);
  }
}

bool _isChunkId(String id) => RegExp(r'^[0-9a-f]{40}$').hasMatch(id);

/// The id of [chunk]: 40 hex digits of its SHA-256.
String circleBackupChunkId(List<int> chunk) =>
    crypto.sha256.convert(chunk).toString().substring(0, 40);

List<int> _signedBytes(Map<String, dynamic> json) => utf8.encode(
  jsonEncode(<String, dynamic>{
    for (final MapEntry<String, dynamic> e in json.entries)
      if (e.key != 'sig') e.key: e.value,
  }),
);

/// The keys of an account's copy, from its self key (itself from the
/// account key: the same after any recovery).
@immutable
final class CircleBackupKeys {
  const CircleBackupKeys._(this.seal, this.nonce);

  final Uint8List seal;
  final Uint8List nonce;

  static Future<CircleBackupKeys> of(Uint8List selfKey) async {
    Future<Uint8List> derive(String info) async {
      final SecretKey key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
            secretKey: SecretKey(selfKey),
            info: utf8.encode(info),
            nonce: const <int>[],
          );
      return Uint8List.fromList(await key.extractBytes());
    }

    return CircleBackupKeys._(
      await derive('zen.circle-backup.seal.v1'),
      await derive('zen.circle-backup.nonce.v1'),
    );
  }
}

final Chacha20 _aead = Chacha20.poly1305Aead();

/// [plain] sealed as the chunk [label] (part [part]) of [account]'s copy:
/// nonce (12) ‖ ciphertext ‖ tag (16). The same input gives the same chunk.
Future<Uint8List> _seal(
  CircleBackupKeys keys,
  String account,
  String label,
  int part,
  List<int> plain,
) async {
  final List<int> aad = utf8.encode('$account|$label|$part');
  final Uint8List nonce = Uint8List.fromList(
    crypto.Hmac(
      crypto.sha256,
      keys.nonce,
    ).convert(<int>[...aad, 0, ...plain]).bytes.sublist(0, 12),
  );
  final SecretBox box = await _aead.encrypt(
    plain,
    secretKey: SecretKey(keys.seal),
    nonce: nonce,
    aad: aad,
  );
  return Uint8List.fromList(<int>[
    ...nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

/// Opens a chunk sealed by [_seal]; null when it does not open as
/// [label] part [part] of [account]'s copy.
Future<Uint8List?> _open(
  CircleBackupKeys keys,
  String account,
  String label,
  int part,
  Uint8List chunk,
) async {
  if (chunk.length < 28) {
    return null;
  }
  try {
    final List<int> plain = await _aead.decrypt(
      SecretBox(
        chunk.sublist(12, chunk.length - 16),
        nonce: chunk.sublist(0, 12),
        mac: Mac(chunk.sublist(chunk.length - 16)),
      ),
      secretKey: SecretKey(keys.seal),
      aad: utf8.encode('$account|$label|$part'),
    );
    return Uint8List.fromList(plain);
  } on Object {
    return null;
  }
}

/// A piece of the copy before sealing: its label and its plain bytes.
final class _Piece {
  _Piece(this.label, this.bytes, {this.month, this.messages = 0});

  final String label;
  final Uint8List bytes;

  /// For a month of a conversation: `yyyymm` (trimming goes oldest first).
  final int? month;
  final int messages;
}

int _monthOf(int millis) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  return d.year * 100 + d.month;
}

Uint8List _jsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// Builds [content] into a signed copy for [account] at [at], at most
/// [maxBytes] in all: when it does not fit, whole months of conversation
/// text go, oldest first (everything else always stays).
Future<CircleBackupBuild> buildCircleBackup({
  required CircleBackupContent content,
  required String account,
  required Uint8List selfKey,
  required LedgerKeyPair deviceKey,
  required DeviceCertificate certificate,
  required int at,
  int maxBytes = kCircleBackupMaxBytes,
}) async {
  final CircleBackupKeys keys = await CircleBackupKeys.of(selfKey);
  final List<_Piece> pieces = <_Piece>[
    for (final String name in content.sections.keys.toList()..sort())
      _Piece('s|$name', _jsonBytes(content.sections[name])),
  ];
  final List<_Piece> months = <_Piece>[];
  for (final String conversation in content.chats.keys.toList()..sort()) {
    final Map<int, List<Map<String, dynamic>>> byMonth =
        <int, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> m in content.chats[conversation]!) {
      final Object? when = m['at'];
      (byMonth[_monthOf(when is int ? when : 0)] ??= <Map<String, dynamic>>[])
          .add(m);
    }
    for (final int month in byMonth.keys.toList()..sort()) {
      final List<Map<String, dynamic>> list = byMonth[month]!
        ..sort(
          (Map<String, dynamic> a, Map<String, dynamic> b) =>
              ((a['at'] as int?) ?? 0).compareTo((b['at'] as int?) ?? 0),
        );
      months.add(
        _Piece(
          'c|$conversation|$month',
          _jsonBytes(list),
          month: month,
          messages: list.length,
        ),
      );
    }
  }
  // Oldest months first out.
  months.sort((_Piece a, _Piece b) {
    final int byMonth = a.month!.compareTo(b.month!);
    return byMonth != 0 ? byMonth : a.label.compareTo(b.label);
  });
  int sealedSize(_Piece p) {
    final int parts = (p.bytes.length / kCircleBackupChunkBytes).ceil();
    return p.bytes.length + 28 * (parts == 0 ? 1 : parts);
  }

  // Room for the index: about 64 bytes a chunk.
  int estimate(List<_Piece> all) => all.fold(
    4096,
    (int sum, _Piece p) =>
        sum +
        sealedSize(p) +
        64 * (1 + sealedSize(p) ~/ kCircleBackupChunkBytes),
  );
  int dropped = 0;
  int start = 0;
  while (start < months.length &&
      estimate(<_Piece>[...pieces, ...months.sublist(start)]) > maxBytes) {
    dropped += months[start].messages;
    start++;
  }
  pieces.addAll(months.sublist(start));

  final Map<String, Uint8List> chunks = <String, Uint8List>{};
  final List<List<Object>> order = <List<Object>>[];
  final Map<String, List<String>> labels = <String, List<String>>{};
  Future<List<String>> sealPiece(String label, Uint8List bytes) async {
    final List<String> ids = <String>[];
    int part = 0;
    int offset = 0;
    do {
      final int end = (offset + kCircleBackupChunkBytes).clamp(0, bytes.length);
      final Uint8List chunk = await _seal(
        keys,
        account,
        label,
        part,
        bytes.sublist(offset, end),
      );
      final String id = circleBackupChunkId(chunk);
      if (!chunks.containsKey(id)) {
        chunks[id] = chunk;
        order.add(<Object>[id, chunk.length]);
      }
      ids.add(id);
      part++;
      offset = end;
    } while (offset < bytes.length);
    return ids;
  }

  for (final _Piece p in pieces) {
    labels[p.label] = await sealPiece(p.label, p.bytes);
  }
  final List<String> index = await sealPiece(
    'index',
    _jsonBytes(<String, dynamic>{'a': account, 'at': at, 'l': labels}),
  );
  final Map<String, dynamic> body = <String, dynamic>{
    't': kCircleBackupType,
    'v': 1,
    'a': account,
    'at': at,
    'ch': order,
    'ix': index,
    'cert': certificate.toJson(),
  };
  final Uint8List signature = await deviceKey.sign(_signedBytes(body));
  final CircleBackupManifest manifest = CircleBackupManifest.parse(
    jsonDecode(jsonEncode(<String, dynamic>{...body, 'sig': b64(signature)})),
  )!;
  return CircleBackupBuild(
    manifest: manifest,
    chunks: chunks,
    droppedMessages: dropped,
  );
}

/// Why a copy did not open.
enum CircleBackupError {
  /// Not signed by a device of the account, or not for it.
  signature,

  /// A chunk is missing or not what its id says.
  chunks,

  /// A chunk does not open with this account's key (changed, swapped).
  sealing,
}

/// The content of a copy, or why it did not open.
@immutable
final class CircleBackupOpened {
  const CircleBackupOpened.ok(CircleBackupContent this.content) : error = null;
  const CircleBackupOpened.failed(CircleBackupError this.error)
    : content = null;

  final CircleBackupContent? content;
  final CircleBackupError? error;
}

/// Checks and opens [manifest] with [chunks] for [account] (after a
/// recovery: its self key from the recovered account key).
Future<CircleBackupOpened> openCircleBackup({
  required CircleBackupManifest manifest,
  required Map<String, Uint8List> chunks,
  required String account,
  required Uint8List selfKey,
}) async {
  if (!await manifest.verify(account: account)) {
    return const CircleBackupOpened.failed(CircleBackupError.signature);
  }
  final Map<String, int> sizes = manifest.chunks;
  for (final MapEntry<String, int> e in sizes.entries) {
    final Uint8List? chunk = chunks[e.key];
    if (chunk == null ||
        chunk.length != e.value ||
        circleBackupChunkId(chunk) != e.key) {
      return const CircleBackupOpened.failed(CircleBackupError.chunks);
    }
  }
  final CircleBackupKeys keys = await CircleBackupKeys.of(selfKey);
  Future<Uint8List?> join(String label, List<String> ids) async {
    final BytesBuilder out = BytesBuilder(copy: false);
    for (int part = 0; part < ids.length; part++) {
      final Uint8List? chunk = chunks[ids[part]];
      if (chunk == null) {
        return null;
      }
      final Uint8List? plain = await _open(keys, account, label, part, chunk);
      if (plain == null) {
        return null;
      }
      out.add(plain);
    }
    return out.takeBytes();
  }

  Object? decode(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on Object {
      return null;
    }
  }

  final Uint8List? indexBytes = await join('index', manifest.index);
  final Object? index = indexBytes == null ? null : decode(indexBytes);
  if (index is! Map ||
      index['a'] != account ||
      index['at'] != manifest.createdAt ||
      index['l'] is! Map) {
    return const CircleBackupOpened.failed(CircleBackupError.sealing);
  }
  final Map<String, Object?> sections = <String, Object?>{};
  final Map<String, List<Map<String, dynamic>>> chats =
      <String, List<Map<String, dynamic>>>{};
  for (final MapEntry<dynamic, dynamic> e in (index['l'] as Map).entries) {
    final Object? label = e.key;
    final Object? ids = e.value;
    if (label is! String ||
        ids is! List ||
        ids.any((Object? i) => i is! String)) {
      return const CircleBackupOpened.failed(CircleBackupError.sealing);
    }
    final Uint8List? bytes = await join(label, ids.cast<String>());
    if (bytes == null) {
      return const CircleBackupOpened.failed(CircleBackupError.sealing);
    }
    final Object? value = decode(bytes);
    if (label.startsWith('s|')) {
      sections[label.substring(2)] = value;
    } else if (label.startsWith('c|') && value is List) {
      final int cut = label.lastIndexOf('|');
      final String conversation = label.substring(2, cut);
      (chats[conversation] ??= <Map<String, dynamic>>[]).addAll(
        value.whereType<Map<String, dynamic>>(),
      );
    }
  }
  for (final List<Map<String, dynamic>> list in chats.values) {
    list.sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          ((a['at'] as int?) ?? 0).compareTo((b['at'] as int?) ?? 0),
    );
  }
  return CircleBackupOpened.ok(
    CircleBackupContent(sections: sections, chats: chats),
  );
}
