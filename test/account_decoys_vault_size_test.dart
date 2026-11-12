import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/multi/account_decoys.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_generator.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';

// A hidden account's passwords file is not told from a decoy's by its size:
// the decoys' file reaches what a real vault can (an import of a browser's
// 2000 logins is far past the 60 000 bytes decoys once stopped at). The
// store compresses (zstd) and seals; gzip stands in for the compression
// here (random passwords do not compress either way).

void main() {
  test('a decoy\'s passwords file is as large as a real vault gets', () async {
    final (int smallest, int largest) = ZenAccountDecoys.debugSizesOf(
      'data/$kPasswordVaultKey.zenbin',
    );
    expect(smallest, lessThanOrEqualTo(200));
    // Every vault the app stores fits: the store compresses, never grows
    // it by more than its envelope.
    expect(largest, greaterThanOrEqualTo(kMaxPasswordVaultBytes));

    final Random r = Random(7);
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PasswordVaultService vault = PasswordVaultService(
      disk: disk,
      random: Random(1),
    );
    final StringBuffer csv = StringBuffer('name,url,username,password,note\n');
    for (int i = 0; i < kMaxPasswordEntries; i++) {
      csv.writeln(
        'site$i.example.com,https://site$i.example.com/login,'
        'ania.kowalska$i@poczta.example.pl,'
        '${generatePassword(const PasswordGeneratorOptions(symbols: false), r)},',
      );
    }
    await vault.importCsv(Uint8List.fromList(utf8.encode(csv.toString())));
    final int compressed = gzip.encode(disk.files[kPasswordVaultKey]!).length;
    expect(compressed, greaterThan(60000));
    expect(compressed, lessThan(largest));
  });
}
