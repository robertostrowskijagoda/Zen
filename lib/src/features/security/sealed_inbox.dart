import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

/// The append-only inbox the Android background service writes while the
/// app is locked (§14.1).
///
/// Every record is sealed to the inbox's hybrid public key (ML-KEM-768 +
/// X25519, hybrid_kem.dart): `(c, K)` is an encapsulation to it, the record
/// key `HKDF-SHA256(K, salt = c, info = "zen.inbox.v2")`, then AES-256-GCM
/// with the record header as associated data. The service holds only the
/// public key, so nothing it wrote can be read back without the master key
/// (from which the private key is derived) — not by the service, not by
/// whoever copies the files, not later with a quantum computer. A writer
/// encapsulates once for up to [kSealedInboxRecordsPerKem] records or
/// [kSealedInboxKemLifetime] ([InboxSealKey]); each record still carries
/// `c`, and a reader decapsulates each `c` once.
///
/// File: `u32 little-endian length ‖ record`, repeated; record:
/// `version ‖ KEM ciphertext (1120) ‖ nonce (12) ‖ ciphertext ‖ tag (16)`.
/// A record cut short by a killed write is ignored by the reader and cut off
/// by the next writer.
const int kSealedInboxVersion = 2;

/// Largest plaintext one record takes; a bigger frame is not kept (and so
/// not acknowledged: its sender keeps it).
const int kSealedInboxMaxRecordBytes = 256 * 1024;

/// Largest inbox file; past it nothing more is kept until the app drains.
const int kSealedInboxMaxFileBytes = 32 * 1024 * 1024;

/// How many records, and for how long, one encapsulation seals.
const int kSealedInboxRecordsPerKem = 256;
const Duration kSealedInboxKemLifetime = Duration(hours: 1);

const String _context = 'zen.inbox.v2';
const int _lengthBytes = 4;
const int _headerBytes = 1 + kHybridCiphertextBytes;

/// Header, nonce and tag.
const int _overheadBytes = _headerBytes + 12 + 16;
const int _maxStoredRecordBytes = kSealedInboxMaxRecordBytes + _overheadBytes;

final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

List<int> get _kemInfo => utf8.encode(_context);

Future<Uint8List> _recordKey(Uint8List secret, Uint8List kemCiphertext) async {
  final SecretKey key = await _hkdf.deriveKey(
    secretKey: SecretKey(secret),
    nonce: kemCiphertext,
    info: utf8.encode(_context),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// One encapsulation to the inbox key and the record key it gives, used
/// for a number of records.
final class InboxSealKey {
  InboxSealKey._(this.kemCiphertext, this._key, this.createdAt);

  /// A fresh encapsulation to [recipientPublicKey].
  static Future<InboxSealKey> make(Uint8List recipientPublicKey) async {
    final HybridEncapsulation kem = await hybridKem.encapsulate(
      recipientPublicKey,
      info: _kemInfo,
    );
    return InboxSealKey._(
      kem.ciphertext,
      await _recordKey(kem.secret, kem.ciphertext),
      DateTime.now(),
    );
  }

  final Uint8List kemCiphertext;
  final Uint8List _key;
  final DateTime createdAt;
  int _records = 0;

  /// Whether it sealed its share of records or is too old.
  bool get spent =>
      _records >= kSealedInboxRecordsPerKem ||
      DateTime.now().difference(createdAt) >= kSealedInboxKemLifetime;
}

/// [plaintext] sealed for [recipientPublicKey] (see the file comment),
/// with [key] when given (a writer's current one), else a fresh one.
Future<Uint8List> sealInboxRecord(
  Uint8List plaintext,
  Uint8List recipientPublicKey, {
  InboxSealKey? key,
}) async {
  final InboxSealKey sealKey =
      key ?? await InboxSealKey.make(recipientPublicKey);
  sealKey._records += 1;
  final Uint8List header = Uint8List(_headerBytes)
    ..[0] = kSealedInboxVersion
    ..setRange(1, _headerBytes, sealKey.kemCiphertext);
  final Uint8List sealed = await encryptSecurityBytes(
    plaintext,
    sealKey._key,
    aad: header,
  );
  final Uint8List record = Uint8List(_headerBytes + sealed.length);
  record
    ..setRange(0, _headerBytes, header)
    ..setRange(_headerBytes, record.length, sealed);
  return record;
}

/// The plaintext of [record], or `null` when it does not open with
/// [recipient] (another key, damage, not a record). [keys] keeps the record
/// keys already derived (by KEM ciphertext), so one reading decapsulates
/// each ciphertext once.
Future<Uint8List?> openInboxRecord(
  Uint8List record,
  HybridKeyPair recipient, {
  Map<String, Uint8List>? keys,
}) async {
  if (record.length < _overheadBytes || record[0] != kSealedInboxVersion) {
    return null;
  }
  try {
    final Uint8List header = Uint8List.fromList(
      record.sublist(0, _headerBytes),
    );
    final Uint8List kemCiphertext = Uint8List.fromList(
      header.sublist(1, _headerBytes),
    );
    final String id = base64Url.encode(kemCiphertext);
    final Uint8List key =
        keys?[id] ??
        await _recordKey(
          await hybridKem.decapsulate(
            recipient.seed,
            kemCiphertext,
            info: _kemInfo,
          ),
          kemCiphertext,
        );
    final Uint8List plain = await decryptSecurityBytes(
      Uint8List.fromList(record.sublist(_headerBytes)),
      key,
      aad: header,
    );
    keys?[id] = key;
    return plain;
  } on Object {
    return null;
  }
}

/// How many leading bytes of [bytes] are complete records.
int completeSealedInboxLength(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);
  int offset = 0;
  while (offset + _lengthBytes <= bytes.length) {
    final int length = view.getUint32(offset, Endian.little);
    if (length < _overheadBytes ||
        length > _maxStoredRecordBytes ||
        offset + _lengthBytes + length > bytes.length) {
      break;
    }
    offset += _lengthBytes + length;
  }
  return offset;
}

/// Every record of [file] that opens with [recipient], oldest first; one
/// that does not open (sealed for an earlier key, damaged) is skipped.
Future<List<Uint8List>> readSealedInbox(
  File file,
  HybridKeyPair recipient,
) async {
  if (!await file.exists()) {
    return const <Uint8List>[];
  }
  final Uint8List bytes = await file.readAsBytes();
  final ByteData view = ByteData.sublistView(bytes);
  final int end = completeSealedInboxLength(bytes);
  final List<Uint8List> out = <Uint8List>[];
  final Map<String, Uint8List> keys = <String, Uint8List>{};
  int skipped = 0;
  int offset = 0;
  while (offset < end) {
    final int length = view.getUint32(offset, Endian.little);
    final Uint8List record = Uint8List.fromList(
      bytes.sublist(offset + _lengthBytes, offset + _lengthBytes + length),
    );
    offset += _lengthBytes + length;
    final Uint8List? plain = await openInboxRecord(
      record,
      recipient,
      keys: keys,
    );
    if (plain == null) {
      skipped += 1;
    } else {
      out.add(plain);
    }
  }
  if (skipped > 0) {
    logZenWarning('$skipped inbox record(s) did not open and were skipped.');
  }
  return out;
}

/// Appends sealed records to the inbox [file]; only ever holds the public
/// key.
final class SealedInboxWriter {
  SealedInboxWriter({
    required this.file,
    required Uint8List recipientPublicKey,
    this.maxFileBytes = kSealedInboxMaxFileBytes,
    int? maxBytesPerSender,
    int? maxStrangerBytes,
  }) : maxBytesPerSender = maxBytesPerSender ?? maxFileBytes ~/ 4,
       maxStrangerBytes = maxStrangerBytes ?? maxFileBytes ~/ 16,
       _recipient = Uint8List.fromList(recipientPublicKey);

  final File file;
  final int maxFileBytes;

  /// The most one sender's records may take until the app drains the
  /// inbox, so that one friend (or one key) cannot fill it for the others.
  final int maxBytesPerSender;

  /// The most strangers' records may take together until then.
  final int maxStrangerBytes;
  final Uint8List _recipient;

  /// The encapsulation the records are sealed with now; renewed when spent.
  InboxSealKey? _sealKey;

  /// Appends one after another, never two at once.
  Future<void> _queue = Future<void>.value();

  /// Length of the complete records in [file], once it was checked.
  int? _length;

  /// What each sender's and all strangers' records take since the inbox
  /// was last found drained.
  final Map<String, int> _bySender = <String, int>{};
  int _strangerBytes = 0;

  /// Seals [plaintext] and appends it. `true` once it is on the disk
  /// (flushed); `false` when it is too big, the inbox is full, [sender]
  /// (a normalized address; null for this device's own records) used its
  /// share or, for a [stranger], strangers used theirs, or the write
  /// failed — the caller must then not tell the sender it arrived.
  Future<bool> append(
    Uint8List plaintext, {
    String? sender,
    bool stranger = false,
  }) {
    final Completer<bool> done = Completer<bool>();
    _queue = _queue.then((_) async {
      try {
        done.complete(
          await _append(plaintext, sender: sender, stranger: stranger),
        );
      } on Object catch (error, stackTrace) {
        logZenError('Keeping a frame in the inbox failed', error, stackTrace);
        // Measured again before the next write.
        _length = null;
        done.complete(false);
      }
    });
    return done.future;
  }

  Future<bool> _append(
    Uint8List plaintext, {
    required String? sender,
    required bool stranger,
  }) async {
    if (plaintext.length > kSealedInboxMaxRecordBytes) {
      return false;
    }
    final int length = await _currentLength();
    InboxSealKey? sealKey = _sealKey;
    if (sealKey == null || sealKey.spent) {
      sealKey = _sealKey = await InboxSealKey.make(_recipient);
    }
    final Uint8List record = await sealInboxRecord(
      plaintext,
      _recipient,
      key: sealKey,
    );
    final int size = _lengthBytes + record.length;
    final int grown = length + size;
    final int senderBytes = sender == null ? 0 : _bySender[sender] ?? 0;
    if (grown > maxFileBytes ||
        (sender != null && senderBytes + size > maxBytesPerSender) ||
        (stranger && _strangerBytes + size > maxStrangerBytes)) {
      return false;
    }
    final Uint8List framed = Uint8List(_lengthBytes + record.length);
    ByteData.sublistView(framed).setUint32(0, record.length, Endian.little);
    framed.setRange(_lengthBytes, framed.length, record);
    await file.parent.create(recursive: true);
    final RandomAccessFile out = await file.open(mode: FileMode.append);
    try {
      await out.writeFrom(framed);
      await out.flush();
    } finally {
      await out.close();
    }
    _length = grown;
    if (sender != null) {
      _bySender[sender] = senderBytes + size;
    }
    if (stranger) {
      _strangerBytes += size;
    }
    return true;
  }

  /// The length of [file]'s complete records. Measured again when the file
  /// is gone or shorter than when last written (the app drained it); what
  /// the senders had left then went with it.
  Future<int> _currentLength() async {
    final int? known = _length;
    if (known != null) {
      final int now = await file.exists() ? await file.length() : 0;
      if (now >= known) {
        return known;
      }
    }
    _bySender.clear();
    _strangerBytes = 0;
    return _length = await _completeLength();
  }

  /// The complete records' length; a record a killed write cut short is
  /// cut off, so the next one starts where a reader looks for it. The file
  /// may also have been taken away by a drain meanwhile.
  Future<int> _completeLength() async {
    if (!await file.exists()) {
      return 0;
    }
    final RandomAccessFile handle = await file.open(mode: FileMode.append);
    try {
      final int total = await handle.length();
      int offset = 0;
      while (offset + _lengthBytes <= total) {
        await handle.setPosition(offset);
        final Uint8List head = await handle.read(_lengthBytes);
        if (head.length < _lengthBytes) {
          break;
        }
        final int length = ByteData.sublistView(
          head,
        ).getUint32(0, Endian.little);
        if (length < _overheadBytes ||
            length > _maxStoredRecordBytes ||
            offset + _lengthBytes + length > total) {
          break;
        }
        offset += _lengthBytes + length;
      }
      if (offset < total) {
        logZenWarning('The inbox ended in a cut-short record; cut off.');
        await handle.truncate(offset);
      }
      return offset;
    } finally {
      await handle.close();
    }
  }
}
