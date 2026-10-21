import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';

/// Paper copy of the account key.
///
/// The 32-byte seed of the account key plus a 3-byte checksum is 35 bytes,
/// exactly 56 base32 characters (RFC 4648 alphabet, no padding), written as
/// 14 groups of 4 (`ABCD-EFGH-…`). The same text, with [kPaperBackupPrefix],
/// goes into the QR code. Anyone who has it owns the account.
const String kPaperBackupPrefix = 'zen-key:';

/// Characters in one written group.
const int kPaperBackupGroupLength = 4;

/// Written groups in a whole copy.
const int kPaperBackupGroups = 14;

/// Characters in a whole copy (without dashes).
const int kPaperBackupLength = kPaperBackupGroupLength * kPaperBackupGroups;

const int _seedLength = 32;
const int _checksumLength = 3;
const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Why a typed or scanned copy was refused.
enum PaperBackupError {
  /// Nothing, or not 56 characters after removing spaces and dashes.
  length,

  /// A character outside the base32 alphabet.
  characters,

  /// The checksum does not fit: a typo (or a different kind of code).
  checksum,
}

/// The seed of a copy that read correctly, or the reason it did not.
final class PaperBackupDecoded {
  const PaperBackupDecoded.ok(Uint8List this.seed) : error = null;
  const PaperBackupDecoded.failed(PaperBackupError this.error) : seed = null;

  final Uint8List? seed;
  final PaperBackupError? error;

  bool get isOk => seed != null;
}

Uint8List _checksum(Uint8List seed) => Uint8List.fromList(
  crypto.sha256
      .convert(<int>[...utf8.encode('zen.paper.backup.v1'), ...seed])
      .bytes
      .sublist(0, _checksumLength),
);

String _base32(List<int> bytes) {
  final StringBuffer out = StringBuffer();
  int buffer = 0;
  int bits = 0;
  for (final int b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) {
    out.write(_alphabet[(buffer << (5 - bits)) & 31]);
  }
  return out.toString();
}

/// The 56-character copy of [seed] (no dashes).
String encodePaperBackup(Uint8List seed) {
  if (seed.length != _seedLength) {
    throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
  }
  return _base32(<int>[...seed, ..._checksum(seed)]);
}

/// [code] in groups of four, joined by [separator].
String formatPaperBackup(String code, {String separator = '-'}) =>
    paperBackupGroups(code).join(separator);

/// The groups of four of a 56-character [code].
List<String> paperBackupGroups(String code) => <String>[
  for (int i = 0; i + kPaperBackupGroupLength <= code.length; i += 4)
    code.substring(i, i + kPaperBackupGroupLength),
];

/// The text of the QR code of [code].
String paperBackupQrData(String code) => '$kPaperBackupPrefix$code';

/// Upper case, no spaces, dashes or the QR prefix; the look-alike digits
/// 0, 1 and 8 read as O, I and B (the alphabet has no digits but 2–7).
String normalizePaperBackup(String input) {
  String s = input.trim();
  if (s.toLowerCase().startsWith(kPaperBackupPrefix)) {
    s = s.substring(kPaperBackupPrefix.length);
  }
  final StringBuffer out = StringBuffer();
  for (final int rune in s.toUpperCase().runes) {
    final String ch = String.fromCharCode(rune);
    if (ch.trim().isEmpty || ch == '-' || ch == '_') {
      continue;
    }
    out.write(switch (ch) {
      '0' => 'O',
      '1' => 'I',
      '8' => 'B',
      _ => ch,
    });
  }
  return out.toString();
}

/// Reads a typed or scanned copy.
PaperBackupDecoded decodePaperBackup(String input) {
  final String code = normalizePaperBackup(input);
  if (code.length != kPaperBackupLength) {
    return const PaperBackupDecoded.failed(PaperBackupError.length);
  }
  final List<int> bytes = <int>[];
  int buffer = 0;
  int bits = 0;
  for (int i = 0; i < code.length; i++) {
    final int v = _alphabet.indexOf(code[i]);
    if (v < 0) {
      return const PaperBackupDecoded.failed(PaperBackupError.characters);
    }
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bytes.add((buffer >> (bits - 8)) & 255);
      bits -= 8;
      buffer &= (1 << bits) - 1;
    }
  }
  final Uint8List seed = Uint8List.fromList(bytes.sublist(0, _seedLength));
  final Uint8List expected = _checksum(seed);
  int diff = 0;
  for (int i = 0; i < _checksumLength; i++) {
    diff |= expected[i] ^ bytes[_seedLength + i];
  }
  if (diff != 0) {
    return const PaperBackupDecoded.failed(PaperBackupError.checksum);
  }
  return PaperBackupDecoded.ok(seed);
}

/// Two different group positions (sorted) for the "I wrote it down" check.
List<int> pickCheckGroups(Random random, {int count = 2}) {
  final List<int> all = List<int>.generate(kPaperBackupGroups, (int i) => i)
    ..shuffle(random);
  return all.take(count).toList()..sort();
}

/// Whether [typed] is group [index] of [code] (case, spaces and look-alike
/// digits do not matter).
bool paperBackupGroupMatches(String code, int index, String typed) {
  final List<String> groups = paperBackupGroups(code);
  return index >= 0 &&
      index < groups.length &&
      normalizePaperBackup(typed) == groups[index];
}

/// The account a read copy opens, to confirm by its fingerprint before it
/// is taken (the same confirmation the circle recovery uses).
final class PaperBackupAccount {
  const PaperBackupAccount({required this.seed, required this.account});

  /// Reads [seed] into the account it is the key of.
  static Future<PaperBackupAccount> fromSeed(Uint8List seed) async =>
      PaperBackupAccount(
        seed: seed,
        account: (await LedgerKeyPair.fromSeed(seed)).id,
      );

  final Uint8List seed;
  final String account;

  String get fingerprint => accountFingerprint(account);
}

/// Makes this installation a new device of the account in [backup]
/// (replaces the identity on [disk]; the ledger restarts afterwards).
/// Refuses a seed that is not the key of the confirmed account.
Future<LedgerIdentity> adoptPaperBackup(
  LedgerDisk disk,
  PaperBackupAccount backup, {
  String deviceName = 'Urządzenie',
}) async {
  if ((await LedgerKeyPair.fromSeed(backup.seed)).id != backup.account) {
    throw StateError('The key does not belong to the confirmed account.');
  }
  return LedgerIdentity.adoptAccount(disk, backup.seed, deviceName: deviceName);
}
