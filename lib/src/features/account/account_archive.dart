import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/account/account_recovery.dart';

/// What a copy of the account holds (the person picks it for a backup
/// file; a transfer to another device takes everything).
enum AccountScope {
  /// The account key: always (without it nothing else opens).
  keys,
  contacts,
  chats,
  media,
  profile,
  settings,
  pyramid,
  dating,
  neighbors,
  meet,
  films,
}

/// Everything.
const Set<AccountScope> kAllAccountScopes = <AccountScope>{
  ...AccountScope.values,
};

/// [scope] as the backup screen names it.
String accountScopeLabel(AccountScope scope) => switch (scope) {
  AccountScope.keys => t('Konto i klucze'),
  AccountScope.contacts => t('Znajomi i grupy'),
  AccountScope.chats => t('Rozmowy (teksty)'),
  AccountScope.media => t('Załączniki i media'),
  AccountScope.profile => t('Profil i galeria'),
  AccountScope.settings => t('Ustawienia'),
  AccountScope.pyramid => t('Piramida i portfel'),
  AccountScope.dating => t('Randki'),
  AccountScope.neighbors => t('Sąsiedzi'),
  AccountScope.meet => t('Spotkania i kółka'),
  AccountScope.films => t('Filmy'),
};

/// Plain stored states of each scope (keys of the account's encrypted
/// store) that go into a copy as they are.
const Map<AccountScope, List<String>> kAccountRawKeys =
    <AccountScope, List<String>>{
      AccountScope.chats: <String>['chat/strangers'],
      AccountScope.pyramid: <String>['pyramid/ledger'],
      AccountScope.meet: <String>[
        'meet/questions',
        'meet/plans',
        'meet/events',
        'meet/intros',
        'meet/table',
        'meet/food',
        'meet/circles',
      ],
      AccountScope.films: <String>['films/state'],
    };

/// The account's log (posts, gallery, films, the public profile, copies for
/// its devices): stored under these keys, which never merge into another
/// device's own log — taken whole only by a new device.
bool isLedgerRawKey(String key) => key.startsWith('ledger/');

/// Bytes read or written at once when a file of a copy is streamed: a
/// file of any size goes through in pieces of at most this many bytes.
const int kAccountStreamChunk = 256 * 1024;

/// One file of a copy, read piece by piece when it is written or sent
/// (never all at once).
@immutable
final class AccountArchiveBlob {
  const AccountArchiveBlob(this.size, this.range);

  /// A small file kept in memory (a stored state, the manifest).
  factory AccountArchiveBlob.bytes(Uint8List bytes) => AccountArchiveBlob(
    bytes.length,
    (int start, int end) async => Uint8List.sublistView(bytes, start, end),
  );

  final int size;

  /// Bytes [start] (inclusive) to [end] (exclusive), or null when the file
  /// cannot be read (any more).
  final Future<Uint8List?> Function(int start, int end) range;

  /// The file in pieces of at most [chunk] bytes; throws when a part of
  /// it cannot be read.
  Stream<Uint8List> chunks({int chunk = kAccountStreamChunk}) async* {
    for (int at = 0; at < size; at += chunk) {
      final int end = math.min(at + chunk, size);
      final Uint8List? part = await range(at, end);
      if (part == null || part.length != end - at) {
        throw StateError('A file of the copy could not be read.');
      }
      yield part;
    }
  }
}

/// The id of [bytes] in a copy: 64 hex digits of SHA-256.
String accountBlobId(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

/// SHA-256 of a file fed piece by piece (the id of a streamed file).
final class AccountHasher {
  factory AccountHasher() {
    final _DigestSink out = _DigestSink();
    return AccountHasher._(out, crypto.sha256.startChunkedConversion(out));
  }

  AccountHasher._(this._out, this._input);

  final _DigestSink _out;
  final ByteConversionSink _input;

  /// Bytes added so far.
  int length = 0;

  void add(List<int> bytes) {
    length += bytes.length;
    _input.add(bytes);
  }

  /// The id of everything added.
  String close() {
    _input.close();
    return _out.digest!.toString();
  }
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? digest;

  @override
  void add(crypto.Digest data) => digest = data;

  @override
  void close() {}
}

/// The id of the file [blob], read piece by piece.
Future<String> accountBlobIdOf(AccountArchiveBlob blob) async {
  final AccountHasher hasher = AccountHasher();
  await for (final Uint8List part in blob.chunks()) {
    hasher.add(part);
  }
  return hasher.close();
}

/// A copy of an account: what is in it ([manifest]) and its files.
///
/// The manifest names the account, the scope, the account key's seed (in
/// a copy that carries the key), the sections (profile, friends and groups,
/// settings, pyramid, dating, household…), the conversations as their
/// devices sync them (a message with a file names it: `af`), the stored
/// states taken as they are (key → file) and every file by its content
/// hash.
@immutable
final class AccountArchive {
  const AccountArchive({
    required this.account,
    required this.createdAt,
    required this.scope,
    this.seed,
    this.sections = const <String, Object?>{},
    this.chats = const <String, List<Map<String, dynamic>>>{},
    this.raw = const <String, String>{},
    this.files = const <String, int>{},
  });

  static const String type = 'zen_account_archive';

  final String account;
  final int createdAt;
  final Set<AccountScope> scope;
  final Uint8List? seed;
  final Map<String, Object?> sections;
  final Map<String, List<Map<String, dynamic>>> chats;

  /// Stored state key → file id.
  final Map<String, String> raw;

  /// File id → size.
  final Map<String, int> files;

  int get totalBytes => files.values.fold(0, (int a, int b) => a + b);

  int get messageCount => chats.values.fold(
    0,
    (int sum, List<Map<String, dynamic>> m) => sum + m.length,
  );

  /// With the account key's [key] (sent apart from the manifest).
  AccountArchive withSeed(Uint8List key) => AccountArchive(
    account: account,
    createdAt: createdAt,
    scope: <AccountScope>{...scope, AccountScope.keys},
    seed: key,
    sections: sections,
    chats: chats,
    raw: raw,
    files: files,
  );

  /// Without the key (what another device of the account syncs).
  AccountArchive withoutSeed() => AccountArchive(
    account: account,
    createdAt: createdAt,
    scope: scope.difference(<AccountScope>{AccountScope.keys}),
    sections: sections,
    chats: chats,
    raw: raw,
    files: files,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': type,
    'v': 1,
    'a': account,
    'at': createdAt,
    'sc': <String>[for (final AccountScope s in scope) s.name],
    if (seed != null) 'seed': b64(seed!),
    's': sections,
    'c': chats,
    'r': raw,
    'f': files,
  };

  static AccountArchive? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != type ||
        json['v'] != 1 ||
        json['a'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final Object? sc = json['sc'];
    final Object? s = json['s'];
    final Object? c = json['c'];
    final Object? r = json['r'];
    final Object? f = json['f'];
    final Uint8List? seed = json['seed'] == null
        ? null
        : unb64(json['seed'], length: 32);
    if (json['seed'] != null && seed == null) {
      return null;
    }
    return AccountArchive(
      account: json['a'] as String,
      createdAt: json['at'] as int,
      scope: <AccountScope>{
        if (sc is List)
          for (final AccountScope x in AccountScope.values)
            if (sc.contains(x.name)) x,
      },
      seed: seed,
      sections: s is Map ? Map<String, Object?>.from(s) : <String, Object?>{},
      chats: <String, List<Map<String, dynamic>>>{
        if (c is Map)
          for (final MapEntry<dynamic, dynamic> e in c.entries)
            if (e.key is String && e.value is List)
              e.key as String: <Map<String, dynamic>>[
                for (final Object? m in e.value as List)
                  if (m is Map) Map<String, dynamic>.from(m),
              ],
      },
      raw: <String, String>{
        if (r is Map)
          for (final MapEntry<dynamic, dynamic> e in r.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
      },
      files: <String, int>{
        if (f is Map)
          for (final MapEntry<dynamic, dynamic> e in f.entries)
            if (e.key is String && e.value is int)
              e.key as String: e.value as int,
      },
    );
  }
}

/// A collected copy: its manifest and how to read each of its files.
typedef AccountArchiveBuild = ({
  AccountArchive archive,
  Map<String, AccountArchiveBlob> blobs,
});

/// Collects a copy: the manifest's parts and its files by content.
final class AccountArchiveBuilder {
  AccountArchiveBuilder({
    required this.account,
    required this.scope,
    this.measureOnly = false,
  });

  final String account;
  final Set<AccountScope> scope;

  /// Only sizes (for the estimate on the backup screen): files are not
  /// read, their ids are made up.
  final bool measureOnly;
  final Map<String, AccountArchiveBlob> blobs = <String, AccountArchiveBlob>{};
  final Map<String, Object?> sections = <String, Object?>{};
  final Map<String, List<Map<String, dynamic>>> chats =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, String> raw = <String, String>{};
  Uint8List? seed;

  bool has(AccountScope s) => scope.contains(s);

  /// Adds a file of [size] bytes found under [name] (measuring only).
  String addMeasured(String name, int size) {
    final String id = accountBlobId(utf8.encode('measure|$name'));
    blobs[id] = AccountArchiveBlob(size, (int start, int end) async => null);
    return id;
  }

  /// Adds [bytes] (kept in memory: small states).
  String addBytes(Uint8List bytes) {
    final String id = accountBlobId(bytes);
    blobs[id] = AccountArchiveBlob.bytes(bytes);
    return id;
  }

  /// Adds a file of [size] bytes read by [range] (piece by piece: now for
  /// its hash, again when it is written or sent); null when it cannot be
  /// read.
  Future<String?> addFile(
    int size,
    Future<Uint8List?> Function(int start, int end) range,
  ) async {
    final AccountArchiveBlob blob = AccountArchiveBlob(size, range);
    final String id;
    try {
      id = await accountBlobIdOf(blob);
    } on StateError {
      return null;
    }
    blobs[id] = blob;
    return id;
  }

  AccountArchive build({required int at}) => AccountArchive(
    account: account,
    createdAt: at,
    scope: scope,
    seed: has(AccountScope.keys) ? seed : null,
    sections: sections,
    chats: chats,
    raw: raw,
    files: <String, int>{
      for (final MapEntry<String, AccountArchiveBlob> e in blobs.entries)
        e.key: e.value.size,
    },
  );
}

// ---- the backup file ----

/// Magic of a backup file (`.zenbackup`).
const String kAccountBackupMagic = 'ZENACCT1';

/// Extension of a backup file.
const String kAccountBackupExtension = 'zenbackup';

/// Plain bytes per sealed frame.
const int kAccountBackupFrameBytes = 1024 * 1024;

/// Why a backup file did not open.
enum AccountBackupError {
  /// Not a backup file, damaged or cut short.
  format,

  /// The password is wrong (or the file was changed).
  password,
}

/// A copy written into a backup file, or read from one.
///
/// Layout: `ZENACCT1`, Argon2id memory (KiB, 4 bytes), passes (1),
/// parallelism (1), salt (16), a check of the key (16: HMAC-SHA256 of the
/// header, so a wrong password is told apart from a damaged file); then
/// frames: length (4) ‖ AES-256-GCM of up to [kAccountBackupFrameBytes]
/// plain bytes (nonce = frame number, the header and "last frame" bound as
/// data), so nothing can be cut, swapped or added. The plain stream is
/// records: type (1: manifest, 2: file), id length (1), id, length (8),
/// bytes. The key is Argon2id of the password (post-quantum safe:
/// symmetric only). Files are written and read piece by piece: memory
/// stays at about one frame whatever their size.
final class AccountBackupFile {
  AccountBackupFile._();

  static final AesGcm _aes = AesGcm.with256bits();

  /// Largest manifest accepted when reading.
  static const int maxManifestBytes = 256 * 1024 * 1024;

  static Uint8List _header(PasswordCost cost, Uint8List salt) {
    final ByteData d = ByteData(8 + 4 + 1 + 1 + 16);
    final Uint8List out = d.buffer.asUint8List();
    out.setRange(0, 8, ascii.encode(kAccountBackupMagic));
    d.setUint32(8, cost.memoryKiB);
    d.setUint8(12, cost.iterations);
    d.setUint8(13, cost.parallelism);
    out.setRange(14, 30, salt);
    return out;
  }

  static Future<List<int>> _check(SecretKey key, Uint8List header) async {
    final Mac mac = await Hmac.sha256().calculateMac(<int>[
      ...utf8.encode('zen.backup.check'),
      ...header,
    ], secretKey: key);
    return mac.bytes.sublist(0, 16);
  }

  static List<int> _nonce(int frame) {
    final ByteData d = ByteData(12)..setUint32(8, frame);
    return d.buffer.asUint8List();
  }

  static List<int> _aad(Uint8List header, int frame, bool last) => <int>[
    ...header,
    ...utf8.encode('|$frame|${last ? 1 : 0}'),
  ];

  static Uint8List _recordHead(int type, String id, int length) {
    final List<int> idBytes = ascii.encode(id);
    final ByteData head = ByteData(1 + 1 + idBytes.length + 8)
      ..setUint8(0, type)
      ..setUint8(1, idBytes.length);
    head.buffer.asUint8List().setRange(2, 2 + idBytes.length, idBytes);
    head.setUint64(2 + idBytes.length, length);
    return head.buffer.asUint8List();
  }

  /// Writes [archive] with its [blobs] for [password] into [out] (bytes as
  /// they are made; the caller splits them into parts if it wants), every
  /// file piece by piece. [progress] counts the file bytes written.
  static Future<void> write({
    required AccountArchive archive,
    required Map<String, AccountArchiveBlob> blobs,
    required String password,
    required Future<void> Function(Uint8List bytes) out,
    PasswordCost cost = kRecoveryPasswordCost,
    Uint8List? salt,
    void Function(int done, int total)? progress,
  }) async {
    final Uint8List s = salt ?? randomBytes(16);
    final Uint8List header = _header(cost, s);
    final SecretKey key = SecretKey(
      await derivePasswordKey(password, s, cost: cost),
    );
    await out(header);
    await out(Uint8List.fromList(await _check(key, header)));
    final BytesBuilder pending = BytesBuilder(copy: false);
    int frame = 0;

    /// Seals one frame of what is pending ([last]: everything, the final
    /// frame marked as such).
    Future<void> sealOne({required bool last}) async {
      final Uint8List all = pending.takeBytes();
      final int n = math.min(all.length, kAccountBackupFrameBytes);
      final bool isLast = last && n == all.length;
      final SecretBox box = await _aes.encrypt(
        Uint8List.sublistView(all, 0, n),
        secretKey: key,
        nonce: _nonce(frame),
        aad: _aad(header, frame, isLast),
      );
      final ByteData len = ByteData(4)
        ..setUint32(0, box.cipherText.length + 16);
      await out(len.buffer.asUint8List());
      await out(Uint8List.fromList(box.cipherText));
      await out(Uint8List.fromList(box.mac.bytes));
      frame++;
      if (n < all.length) {
        pending.add(Uint8List.sublistView(all, n));
      }
      if (last && !isLast) {
        await sealOne(last: true);
      }
    }

    Future<void> push(Uint8List bytes) async {
      pending.add(bytes);
      while (pending.length >= kAccountBackupFrameBytes) {
        await sealOne(last: false);
      }
    }

    final Uint8List manifest = Uint8List.fromList(
      utf8.encode(jsonEncode(archive.toJson())),
    );
    await push(_recordHead(1, '', manifest.length));
    await push(manifest);
    final int total = archive.totalBytes;
    int done = 0;
    for (final MapEntry<String, int> f in archive.files.entries) {
      final AccountArchiveBlob? blob = blobs[f.key];
      if (blob == null || blob.size != f.value) {
        throw StateError('A file of the copy is missing.');
      }
      await push(_recordHead(2, f.key, f.value));
      final AccountHasher hasher = AccountHasher();
      await for (final Uint8List part in blob.chunks()) {
        hasher.add(part);
        await push(part);
        done += part.length;
        progress?.call(done, total);
      }
      if (hasher.length != f.value || hasher.close() != f.key) {
        throw StateError('A file of the copy changed while it was written.');
      }
    }
    await sealOne(last: true);
  }

  /// Reads a backup file from [chunks] (its bytes in order, parts one
  /// after another): the manifest, then each file handed piece by piece to
  /// the writer [file] opens for it (and checked by its hash). Returns the
  /// manifest, or the reason it did not open. When [accept] says no to the
  /// manifest, reading stops there.
  static Future<({AccountArchive? archive, AccountBackupError? error})> read({
    required Stream<List<int>> chunks,
    required String password,
    required AccountFileOpener file,
    Future<bool> Function(AccountArchive archive)? accept,
    List<PasswordCost> acceptedCosts = kAcceptedRecoveryCosts,
  }) async {
    final _Reader reader = _Reader(chunks);
    try {
      return await _readFrom(
        reader,
        password: password,
        file: file,
        accept: accept,
        acceptedCosts: acceptedCosts,
      );
    } on _Fault catch (fault) {
      return (archive: null, error: fault.error);
    } finally {
      // Stopped early (a wrong password, a refused copy, damage) or done:
      // the files under the stream are closed either way.
      await reader.close();
    }
  }

  static Future<({AccountArchive? archive, AccountBackupError? error})>
  _readFrom(
    _Reader reader, {
    required String password,
    required AccountFileOpener file,
    required Future<bool> Function(AccountArchive archive)? accept,
    required List<PasswordCost> acceptedCosts,
  }) async {
    final Uint8List? header = await reader.take(30);
    if (header == null ||
        ascii.decode(header.sublist(0, 8), allowInvalid: true) !=
            kAccountBackupMagic) {
      return (archive: null, error: AccountBackupError.format);
    }
    final ByteData h = ByteData.sublistView(header);
    final PasswordCost cost = PasswordCost(
      memoryKiB: h.getUint32(8),
      iterations: h.getUint8(12),
      parallelism: h.getUint8(13),
    );
    if (!acceptedCosts.contains(cost)) {
      return (archive: null, error: AccountBackupError.format);
    }
    final SecretKey key = SecretKey(
      await derivePasswordKey(password, header.sublist(14, 30), cost: cost),
    );
    final Uint8List? check = await reader.take(16);
    if (check == null) {
      return (archive: null, error: AccountBackupError.format);
    }
    final List<int> expected = await _check(key, header);
    int diff = 0;
    for (int i = 0; i < 16; i++) {
      diff |= expected[i] ^ check[i];
    }
    if (diff != 0) {
      return (archive: null, error: AccountBackupError.password);
    }
    int frame = 0;
    bool ended = false;

    // The next frame's plain bytes; null after the last one.
    Future<Uint8List?> nextFrame() async {
      if (ended) {
        return null;
      }
      final Uint8List? len = await reader.take(4);
      if (len == null) {
        throw const _Fault(AccountBackupError.format);
      }
      final int n = ByteData.sublistView(len).getUint32(0);
      if (n < 16 || n > kAccountBackupFrameBytes + 16) {
        throw const _Fault(AccountBackupError.format);
      }
      final Uint8List? sealed = await reader.take(n);
      if (sealed == null) {
        throw const _Fault(AccountBackupError.format);
      }
      for (final bool last in <bool>[false, true]) {
        try {
          final List<int> bytes = await _aes.decrypt(
            SecretBox(
              Uint8List.sublistView(sealed, 0, n - 16),
              nonce: _nonce(frame),
              mac: Mac(Uint8List.sublistView(sealed, n - 16)),
            ),
            secretKey: key,
            aad: _aad(header, frame, last),
          );
          ended = last;
          frame++;
          return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
        } on SecretBoxAuthenticationError {
          continue;
        }
      }
      throw const _Fault(AccountBackupError.format);
    }

    final _PlainQueue plain = _PlainQueue(nextFrame);
    AccountArchive? archive;
    while (true) {
      final Uint8List? type = await plain.take(1);
      if (type == null) {
        break;
      }
      final Uint8List? idLength = await plain.take(1);
      final Uint8List? idBytes = idLength == null
          ? null
          : await plain.take(idLength[0]);
      final Uint8List? lengthBytes = await plain.take(8);
      if (idBytes == null || lengthBytes == null) {
        throw const _Fault(AccountBackupError.format);
      }
      final String id = ascii.decode(idBytes, allowInvalid: true);
      final int length = ByteData.sublistView(lengthBytes).getUint64(0);
      if (type[0] == 1) {
        if (archive != null || length < 0 || length > maxManifestBytes) {
          throw const _Fault(AccountBackupError.format);
        }
        final Uint8List? bytes = await plain.take(length);
        if (bytes == null) {
          throw const _Fault(AccountBackupError.format);
        }
        try {
          archive = AccountArchive.fromJson(jsonDecode(utf8.decode(bytes)));
        } on FormatException {
          archive = null;
        }
        if (archive == null) {
          throw const _Fault(AccountBackupError.format);
        }
        if (accept != null && !await accept(archive)) {
          return (archive: archive, error: null);
        }
      } else if (type[0] == 2) {
        if (archive == null || archive.files[id] != length) {
          throw const _Fault(AccountBackupError.format);
        }
        final AccountFileWriter writer = await file(id, length);
        final AccountHasher hasher = AccountHasher();
        int left = length;
        while (left > 0) {
          final Uint8List? part = await plain.takeSome(
            math.min(left, kAccountStreamChunk),
          );
          if (part == null) {
            throw const _Fault(AccountBackupError.format);
          }
          hasher.add(part);
          await writer.add(part);
          left -= part.length;
        }
        if (hasher.close() != id) {
          throw const _Fault(AccountBackupError.format);
        }
        await writer.close();
      } else {
        throw const _Fault(AccountBackupError.format);
      }
    }
    if (archive == null || !ended) {
      return (archive: null, error: AccountBackupError.format);
    }
    return (archive: archive, error: null);
  }
}

/// Where the pieces of one file of a copy go as they are read.
abstract interface class AccountFileWriter {
  Future<void> add(Uint8List chunk);

  /// All of it came (and matched its hash).
  Future<void> close();
}

/// Opens the writer for file [id] of [size] bytes.
typedef AccountFileOpener =
    Future<AccountFileWriter> Function(String id, int size);

final class _Fault implements Exception {
  const _Fault(this.error);

  final AccountBackupError error;
}

/// The plain bytes of the frames, taken in exact amounts or as they come.
final class _PlainQueue {
  _PlainQueue(this._next);

  final Future<Uint8List?> Function() _next;
  Uint8List _head = Uint8List(0);
  int _offset = 0;
  bool _done = false;

  int get _left => _head.length - _offset;

  /// Whether there is more; pulls the next frame when this one is used up.
  Future<bool> _fill() async {
    while (_left == 0) {
      if (_done) {
        return false;
      }
      final Uint8List? next = await _next();
      if (next == null) {
        _done = true;
        return false;
      }
      _head = next;
      _offset = 0;
    }
    return true;
  }

  /// Exactly [n] bytes, or null when the stream ended cleanly before any
  /// of them (ending in the middle is damage).
  Future<Uint8List?> take(int n) async {
    if (n == 0) {
      return Uint8List(0);
    }
    final BytesBuilder out = BytesBuilder(copy: false);
    while (out.length < n) {
      if (!await _fill()) {
        if (out.length > 0) {
          throw const _Fault(AccountBackupError.format);
        }
        return null;
      }
      final int k = math.min(n - out.length, _left);
      out.add(Uint8List.sublistView(_head, _offset, _offset + k));
      _offset += k;
    }
    return out.takeBytes();
  }

  /// Between 1 and [max] bytes as they come; null at the end.
  Future<Uint8List?> takeSome(int max) async {
    if (!await _fill()) {
      return null;
    }
    final int k = math.min(max, _left);
    final Uint8List out = Uint8List.sublistView(_head, _offset, _offset + k);
    _offset += k;
    return out;
  }
}

/// Takes exact amounts of bytes from a stream of chunks.
final class _Reader {
  _Reader(Stream<List<int>> chunks)
    : _iterator = StreamIterator<List<int>>(chunks);

  final StreamIterator<List<int>> _iterator;
  Uint8List _head = Uint8List(0);
  int _offset = 0;

  Future<Uint8List?> take(int n) async {
    final BytesBuilder out = BytesBuilder(copy: false);
    while (out.length < n) {
      if (_offset >= _head.length) {
        if (!await _iterator.moveNext()) {
          return null;
        }
        final List<int> next = _iterator.current;
        _head = next is Uint8List ? next : Uint8List.fromList(next);
        _offset = 0;
        continue;
      }
      final int k = math.min(n - out.length, _head.length - _offset);
      out.add(Uint8List.sublistView(_head, _offset, _offset + k));
      _offset += k;
    }
    return out.takeBytes();
  }

  /// Stops reading (the stream's source is let go).
  Future<void> close() => _iterator.cancel();
}

// ---- staging and taking a copy in ----

/// Bytes of one block of a file in a copy: what one message between two
/// devices carries, and one piece where it waits on disk.
const int kAccountCopyBlockBytes = 192 * 1024;

/// The blocks of a file of [size] bytes (an empty file is one empty block).
int accountBlockCount(int size) => size <= 0
    ? 1
    : (size + kAccountCopyBlockBytes - 1) ~/ kAccountCopyBlockBytes;

/// Where the files of a copy wait until they are taken in (the account's
/// encrypted store, block by block), so a transfer cut short goes on
/// where it stopped.
final class AccountImportStaging {
  AccountImportStaging(this.disk);

  final LedgerDisk disk;

  static const String _manifestKey = 'account/import/manifest';

  static String _key(String id, int i) => 'account/import/b/$id/$i';

  Future<void> put(String id, Uint8List bytes) async {
    for (int i = 0; i < accountBlockCount(bytes.length); i++) {
      final int at = i * kAccountCopyBlockBytes;
      final int end = math.min(at + kAccountCopyBlockBytes, bytes.length);
      await disk.write(_key(id, i), Uint8List.sublistView(bytes, at, end));
    }
  }

  /// Takes file [id] piece by piece, block by block as they fill up.
  AccountFileWriter writer(String id) => _StagingWriter(this, id);

  Future<void> putBlock(String id, int i, Uint8List bytes) =>
      disk.write(_key(id, i), bytes);

  Future<bool> hasBlock(String id, int i) async =>
      await disk.read(_key(id, i)) != null;

  Future<void> dropFile(String id, int size) async {
    for (int i = 0; i < accountBlockCount(size); i++) {
      await disk.delete(_key(id, i));
    }
  }

  /// The blocks of file [id] of [size] bytes in order; throws when one is
  /// missing.
  Stream<Uint8List> open(String id, int size) async* {
    if (size <= 0) {
      return;
    }
    for (int i = 0; i < accountBlockCount(size); i++) {
      final Uint8List? part = await disk.read(_key(id, i));
      if (part == null) {
        throw StateError('A block of a staged file is missing.');
      }
      yield part;
    }
  }

  /// File [id] of [size] bytes as a blob read block by block.
  AccountArchiveBlob blob(String id, int size) => AccountArchiveBlob(size, (
    int start,
    int end,
  ) async {
    if (start < 0 || end > size || start > end) {
      return null;
    }
    final BytesBuilder out = BytesBuilder(copy: false);
    for (int at = start; at < end;) {
      final int i = at ~/ kAccountCopyBlockBytes;
      final Uint8List? part = await disk.read(_key(id, i));
      if (part == null) {
        return null;
      }
      final int from = at - i * kAccountCopyBlockBytes;
      final int to = math.min(part.length, end - i * kAccountCopyBlockBytes);
      if (to <= from) {
        return null;
      }
      out.add(Uint8List.sublistView(part, from, to));
      at += to - from;
    }
    return out.takeBytes();
  });

  /// A small file (a stored state, the manifest), whole, when all of it is
  /// here and matches its id. Files are read with [open] or [blob].
  Future<Uint8List?> read(String id, int size) async {
    if (size < 0) {
      return null;
    }
    final BytesBuilder out = BytesBuilder(copy: false);
    for (int i = 0; i < accountBlockCount(size); i++) {
      final Uint8List? part = await disk.read(_key(id, i));
      if (part == null) {
        return null;
      }
      out.add(part);
    }
    final Uint8List bytes = out.takeBytes();
    return bytes.length == size && accountBlobId(bytes) == id ? bytes : null;
  }

  /// Whether all of file [id] is here and matches its id (checked block by
  /// block, never all of it in memory).
  Future<bool> has(String id, int size) async {
    if (size < 0) {
      return false;
    }
    final AccountHasher hasher = AccountHasher();
    for (int i = 0; i < accountBlockCount(size); i++) {
      final Uint8List? part = await disk.read(_key(id, i));
      if (part == null) {
        return false;
      }
      hasher.add(part);
    }
    return hasher.length == size && hasher.close() == id;
  }

  /// Keeps [archive] (without the key: it is the account's key by now)
  /// until the rest is taken in.
  Future<void> saveManifest(AccountArchive archive) => disk.write(
    _manifestKey,
    Uint8List.fromList(
      utf8.encode(jsonEncode(archive.toJson()..remove('seed'))),
    ),
  );

  Future<AccountArchive?> manifest() async {
    final Uint8List? raw = await disk.read(_manifestKey);
    if (raw == null) {
      return null;
    }
    try {
      return AccountArchive.fromJson(jsonDecode(utf8.decode(raw)));
    } on FormatException {
      return null;
    }
  }

  static const String _summaryKey = 'account/import/summary';

  /// Keeps what came back, to show once the app is up again.
  Future<void> saveSummary(AccountImportSummary summary) => disk.write(
    _summaryKey,
    Uint8List.fromList(utf8.encode(jsonEncode(summary.toJson()))),
  );

  /// What came back, once (null when nothing waits to be shown).
  Future<AccountImportSummary?> takeSummary() async {
    final Uint8List? raw = await disk.read(_summaryKey);
    if (raw == null) {
      return null;
    }
    await disk.delete(_summaryKey);
    try {
      return AccountImportSummary.fromJson(jsonDecode(utf8.decode(raw)));
    } on FormatException {
      return null;
    }
  }

  /// Deletes the staged files of [archive] and the manifest.
  Future<void> clear(AccountArchive? archive) async {
    for (final MapEntry<String, int> f
        in archive?.files.entries ?? const <MapEntry<String, int>>[]) {
      await dropFile(f.key, f.value);
    }
    await disk.delete(_manifestKey);
  }
}

/// Fills the blocks of one staged file as its pieces come.
final class _StagingWriter implements AccountFileWriter {
  _StagingWriter(this.staging, this.id);

  final AccountImportStaging staging;
  final String id;
  final BytesBuilder _block = BytesBuilder(copy: false);
  int _next = 0;

  @override
  Future<void> add(Uint8List chunk) async {
    int at = 0;
    while (at < chunk.length) {
      final int k = math.min(
        kAccountCopyBlockBytes - _block.length,
        chunk.length - at,
      );
      _block.add(Uint8List.sublistView(chunk, at, at + k));
      at += k;
      if (_block.length == kAccountCopyBlockBytes) {
        await staging.putBlock(id, _next++, _block.takeBytes());
      }
    }
  }

  @override
  Future<void> close() async {
    if (_block.length > 0 || _next == 0) {
      await staging.putBlock(id, _next++, _block.takeBytes());
    }
  }
}

/// What a copy is taken into: the app (or a test's memory).
abstract interface class AccountArchiveSink {
  /// The account on this device, if it has one yet.
  Future<String?> currentAccount();

  /// Whether this device holds nothing worth keeping yet (a new install):
  /// only then may another account's copy replace its account.
  Future<bool> isFresh();

  /// Makes this device a new device of [archive]'s account (its key is
  /// in it).
  Future<void> adoptAccount(AccountArchive archive);

  /// Writes a stored state as it was ([onlyIfAbsent]: keeps one here).
  Future<void> writeRaw(
    String key,
    Uint8List value, {
    required bool onlyIfAbsent,
  });

  /// Takes in the sections and conversations of [archive], with its files
  /// from [file] (read piece by piece); [progress] counts steps. [merge]:
  /// into a device that has the account already (its own settings and
  /// profile stay).
  Future<AccountImportSummary> apply(
    AccountArchive archive,
    AccountArchiveBlob? Function(String id) file,
    void Function(int done, int total) progress, {
    required bool merge,
  });

  /// Stops the app's services, runs [whileStopped] (stored states written
  /// then are not overwritten by a running service) and starts the app
  /// again on what is stored.
  Future<void> restart({Future<void> Function()? whileStopped});
}

/// What came back, for the final summary.
@immutable
final class AccountImportSummary {
  const AccountImportSummary({
    this.friends = 0,
    this.groups = 0,
    this.conversations = 0,
    this.messages = 0,
    this.files = 0,
    this.bytes = 0,
    this.parts = const <AccountScope>{},
  });

  final int friends;
  final int groups;
  final int conversations;
  final int messages;
  final int files;
  final int bytes;
  final Set<AccountScope> parts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'fr': friends,
    'gr': groups,
    'cv': conversations,
    'ms': messages,
    'fi': files,
    'by': bytes,
    'sc': <String>[for (final AccountScope s in parts) s.name],
  };

  static AccountImportSummary? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    int n(String key) => json[key] is int ? json[key] as int : 0;
    final Object? sc = json['sc'];
    return AccountImportSummary(
      friends: n('fr'),
      groups: n('gr'),
      conversations: n('cv'),
      messages: n('ms'),
      files: n('fi'),
      bytes: n('by'),
      parts: <AccountScope>{
        if (sc is List)
          for (final AccountScope s in AccountScope.values)
            if (sc.contains(s.name)) s,
      },
    );
  }
}

/// How taking a copy in went.
enum AccountImportOutcome {
  /// Taken in (merged into this account).
  done,

  /// The account key is taken; the app starts again and takes the rest in
  /// ([AccountArchiveImporter.resume]).
  restarting,

  /// A copy of another account, and this device has an account of its own
  /// with data: refused.
  otherAccount,

  /// A copy without the account key, for a device without that account.
  noKey,
}

/// Takes copies in: from a backup file, another device of the account, or
/// a sync with one.
final class AccountArchiveImporter {
  AccountArchiveImporter({required this.sink, required this.staging});

  final AccountArchiveSink sink;
  final AccountImportStaging staging;

  /// What the last merge brought ([take] of the same account).
  AccountImportSummary? lastSummary;

  /// What [take] would do with a copy of [account] ([withKey]: the copy
  /// carries its key), before anything is downloaded: null when it would
  /// be taken.
  Future<AccountImportOutcome?> check(
    String account, {
    required bool withKey,
  }) async {
    final String? current = await sink.currentAccount();
    if (current == account) {
      return null;
    }
    if (!withKey) {
      return AccountImportOutcome.noKey;
    }
    if (current != null && !await sink.isFresh()) {
      return AccountImportOutcome.otherAccount;
    }
    return null;
  }

  /// Takes [archive] (its files staged already). Another account's copy
  /// with its key makes this device that account's new device (only on a
  /// fresh device); the same account's copy merges in.
  Future<AccountImportOutcome> take(AccountArchive archive) async {
    final AccountImportOutcome? refused = await check(
      archive.account,
      withKey: archive.seed != null,
    );
    if (refused != null) {
      return refused;
    }
    if (await sink.currentAccount() == archive.account) {
      final AccountImportSummary summary = await _apply(archive, merge: true);
      lastSummary = summary;
      await sink.restart(
        whileStopped: () async {
          await _writeRaw(archive, merge: true);
          await staging.clear(archive);
          await staging.saveSummary(summary);
        },
      );
      return AccountImportOutcome.done;
    }
    await sink.restart(
      whileStopped: () async {
        await sink.adoptAccount(archive);
        await _writeRaw(archive, merge: false);
        await staging.saveManifest(archive);
      },
    );
    return AccountImportOutcome.restarting;
  }

  /// After the restart: takes in what [take] left (sections,
  /// conversations, files). Null when nothing waits.
  Future<AccountImportSummary?> resume({
    void Function(int done, int total)? progress,
  }) async {
    final AccountArchive? archive = await staging.manifest();
    if (archive == null || await sink.currentAccount() != archive.account) {
      return null;
    }
    final AccountImportSummary summary = await _apply(
      archive,
      merge: false,
      progress: progress,
    );
    await staging.clear(archive);
    return summary;
  }

  Future<void> _writeRaw(AccountArchive archive, {required bool merge}) async {
    for (final MapEntry<String, String> e in archive.raw.entries) {
      // The log of another device never merges file by file.
      if (merge && isLedgerRawKey(e.key)) {
        continue;
      }
      final Uint8List? value = await staging.read(
        e.value,
        archive.files[e.value] ?? -1,
      );
      if (value != null) {
        await sink.writeRaw(e.key, value, onlyIfAbsent: merge);
      }
    }
  }

  Future<AccountImportSummary> _apply(
    AccountArchive archive, {
    required bool merge,
    void Function(int done, int total)? progress,
  }) => sink.apply(
    archive,
    (String id) => switch (archive.files[id]) {
      final int size => staging.blob(id, size),
      null => null,
    },
    progress ?? (int _, int _) {},
    merge: merge,
  );
}
