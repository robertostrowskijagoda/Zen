import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';

/// Format version written by this build. Entries with a higher `v` are
/// still stored and passed on (a newer app may understand them); only this
/// build's own checks are applied.
const int kLedgerFormatVersion = 1;

/// Largest entry accepted, whole JSON. Media never goes inside an entry:
/// entries only name blobs by hash.
const int kMaxEntryBytes = 64 * 1024;

const int kMaxSpaceLength = 200;
const int kMaxKindLength = 40;
const int kMaxBlobsPerEntry = 32;

/// One signed record in one device's log for one space.
///
/// The log is a hash chain: entry `seq` names entry `seq - 1` in [prev], so
/// nothing can be cut out or slipped in unnoticed, and two different entries
/// with the same [seq] prove the device misbehaved (a fork).
@immutable
final class LogEntry {
  const LogEntry._({
    required this.version,
    required this.space,
    required this.writer,
    required this.seq,
    required this.prev,
    required this.hlc,
    required this.kind,
    required this.body,
    required this.blobs,
    required this.account,
    required this.device,
    required this.certificate,
    required this.signature,
    required this.id,
    required this.encodedLength,
  });

  final int version;
  final String space;

  /// Random id of the log (one per installation and space).
  final String writer;
  final int seq;

  /// Id of the previous entry of this log; empty for the first one.
  final String prev;
  final Hlc hlc;
  final String kind;
  final Map<String, dynamic> body;

  /// Hashes (blob ids) of media this entry refers to.
  final List<String> blobs;
  final String account;
  final String device;
  final DeviceCertificate certificate;
  final String signature;

  /// Hash of the signed part: the entry's identity everywhere.
  final String id;
  final int encodedLength;

  static Map<String, dynamic> _unsigned({
    required int version,
    required String space,
    required String writer,
    required int seq,
    required String prev,
    required Hlc hlc,
    required String kind,
    required Map<String, dynamic> body,
    required List<String> blobs,
    required String account,
    required String device,
  }) => <String, dynamic>{
    'v': version,
    'space': space,
    'writer': writer,
    'seq': seq,
    'prev': prev,
    'hlc': hlc.toInt(),
    'kind': kind,
    'body': body,
    'blobs': blobs,
    'account': account,
    'device': device,
  };

  Map<String, dynamic> get unsigned => _unsigned(
    version: version,
    space: space,
    writer: writer,
    seq: seq,
    prev: prev,
    hlc: hlc,
    kind: kind,
    body: body,
    blobs: blobs,
    account: account,
    device: device,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...unsigned,
    'cert': certificate.toJson(),
    'sig': signature,
  };

  /// Signs a new entry with [deviceKey].
  static Future<LogEntry> create({
    required LedgerKeyPair deviceKey,
    required DeviceCertificate certificate,
    required String space,
    required String writer,
    required int seq,
    required String prev,
    required Hlc hlc,
    required String kind,
    required Map<String, dynamic> body,
    List<String> blobs = const <String>[],
  }) async {
    final Map<String, dynamic> unsigned = _unsigned(
      version: kLedgerFormatVersion,
      space: space,
      writer: writer,
      seq: seq,
      prev: prev,
      hlc: hlc,
      kind: kind,
      body: body,
      blobs: blobs,
      account: certificate.account,
      device: deviceKey.id,
    );
    final Uint8List bytes = canonicalJsonBytes(unsigned);
    final Uint8List sig = await deviceKey.sign(bytes);
    final LogEntry? entry = fromJson(<String, dynamic>{
      ...unsigned,
      'cert': certificate.toJson(),
      'sig': b64(sig),
    });
    if (entry == null) {
      throw ArgumentError(t('Nieprawidłowy wpis (za duży lub błędne pola).'));
    }
    return entry;
  }

  /// Parses and structurally validates an entry. Does not check signatures
  /// (see [verifySignature]); returns `null` for anything malformed.
  static LogEntry? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? v = json['v'];
    final Object? space = json['space'];
    final Object? writer = json['writer'];
    final Object? seq = json['seq'];
    final Object? prev = json['prev'];
    final Object? hlc = json['hlc'];
    final Object? kind = json['kind'];
    final Object? body = json['body'];
    final Object? blobs = json['blobs'];
    final Object? account = json['account'];
    final Object? device = json['device'];
    final DeviceCertificate? cert = DeviceCertificate.fromJson(json['cert']);
    final Object? sig = json['sig'];
    if (v is! int ||
        v < 1 ||
        space is! String ||
        space.isEmpty ||
        space.length > kMaxSpaceLength ||
        !isHex(writer, 32) ||
        seq is! int ||
        seq < 1 ||
        prev is! String ||
        (seq == 1 ? prev.isNotEmpty : !isHex(prev, 64)) ||
        hlc is! int ||
        hlc < 0 ||
        kind is! String ||
        kind.isEmpty ||
        kind.length > kMaxKindLength ||
        body is! Map ||
        blobs is! List ||
        blobs.length > kMaxBlobsPerEntry ||
        !blobs.every((Object? b) => isHex(b, 64)) ||
        unb64(account, length: 32) == null ||
        unb64(device, length: 32) == null ||
        cert == null ||
        cert.account != account ||
        cert.device != device ||
        unb64(sig, length: 64) == null) {
      return null;
    }
    final Map<String, dynamic> typedBody;
    try {
      typedBody = Map<String, dynamic>.from(body);
    } catch (_) {
      return null;
    }
    final Map<String, dynamic> unsigned = _unsigned(
      version: v,
      space: space,
      writer: writer as String,
      seq: seq,
      prev: prev,
      hlc: Hlc.fromInt(hlc),
      kind: kind,
      body: typedBody,
      blobs: List<String>.from(blobs),
      account: account as String,
      device: device as String,
    );
    final int length;
    final String id;
    try {
      final Uint8List unsignedBytes = canonicalJsonBytes(unsigned);
      id = sha256Hex(unsignedBytes);
      // Whole entry size: signed part + certificate + signature.
      length =
          unsignedBytes.length +
          canonicalJsonBytes(cert.toJson()).length +
          (sig as String).length +
          32;
    } on ArgumentError {
      return null;
    }
    if (length > kMaxEntryBytes) {
      return null;
    }
    return LogEntry._(
      version: v,
      space: space,
      writer: writer,
      seq: seq,
      prev: prev,
      hlc: Hlc.fromInt(hlc),
      kind: kind,
      body: Map<String, dynamic>.unmodifiable(typedBody),
      blobs: List<String>.unmodifiable(blobs),
      account: account,
      device: device,
      certificate: cert,
      signature: sig,
      id: id,
      encodedLength: length,
    );
  }

  Future<bool> verifySignature() => verifyLedgerSignature(
    publicKey: device,
    message: canonicalJsonBytes(unsigned),
    signature: signature,
  );

  @override
  bool operator ==(Object other) => other is LogEntry && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LogEntry($space/$writer#$seq $kind)';
}
