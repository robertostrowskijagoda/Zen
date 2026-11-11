import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/passwords/password_csv_import.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';

// "Hasła": entries kept as versions in the account's encrypted store, so
// the account's sync takes edits made on two devices at once from both,
// nothing of it is read while Zen is locked, and nothing of it shows in a
// log or a debug string.

const PasswordFields _bank = PasswordFields(
  name: 'Bank',
  login: 'ania',
  password: 'tajne-haslo-1',
  address: 'https://bank.example.com/login',
  note: 'PIN w sejfie',
);

const PasswordFields _mail = PasswordFields(
  name: 'poczta',
  login: 'ania@example.com',
  password: 'inne-haslo',
  address: 'https://mail.example.org',
);

PasswordVaultService _vault(
  LedgerDisk disk, {
  int Function()? now,
  bool Function()? isLocked,
  Future<bool> Function(String)? copy,
  int seed = 1,
}) {
  int t = 1000;
  return PasswordVaultService(
    disk: disk,
    now: now ?? () => t += 10,
    random: Random(seed),
    isLocked: isLocked,
    copy: copy,
  );
}

Map<String, Object?> _stored(MemoryLedgerDisk disk) =>
    Map<String, Object?>.from(
      jsonDecode(utf8.decode(disk.files[kPasswordVaultKey]!)) as Map,
    );

/// What the account's sync does with the stored vaults of two devices:
/// every version either has, the ones one of them removed gone on both.
Future<void> _syncBoth(
  MemoryLedgerDisk a,
  MemoryLedgerDisk b,
  Set<String> removedOnA,
  Set<String> removedOnB,
) async {
  Map<String, Object?> versions(MemoryLedgerDisk d) =>
      d.files[kPasswordVaultKey] == null
      ? <String, Object?>{}
      : Map<String, Object?>.from(
          (_stored(d)['e'] as Map?) ?? <String, Object?>{},
        );
  final Map<String, Object?> merged =
      <String, Object?>{...versions(a), ...versions(b)}..removeWhere(
        (String k, Object? _) =>
            removedOnA.contains(k) || removedOnB.contains(k),
      );
  final Uint8List bytes = Uint8List.fromList(
    utf8.encode(jsonEncode(<String, Object?>{'v': 1, 'e': merged})),
  );
  await a.write(kPasswordVaultKey, bytes);
  await b.write(kPasswordVaultKey, bytes);
}

Set<String> _keys(MemoryLedgerDisk d) =>
    Set<String>.from((_stored(d)['e'] as Map? ?? <String, Object?>{}).keys);

void main() {
  test('entries are added, listed by name, searched and read back', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PasswordVaultService vault = _vault(disk);
    await vault.add(_mail);
    final PasswordEntry bank = await vault.add(_bank);
    expect(vault.entries.map((PasswordEntry e) => e.name), <String>[
      'Bank',
      'poczta',
    ]);
    expect(bank.password, 'tajne-haslo-1');
    expect(bank.createdAtMillis, bank.changedAtMillis);

    expect(vault.search('BANK').single.id, bank.id);
    expect(vault.search('ania@').single.name, 'poczta');
    expect(vault.search('example.org').single.name, 'poczta');
    // Never by the password or the note.
    expect(vault.search('tajne'), isEmpty);
    expect(vault.search('sejf'), isEmpty);
    expect(vault.search('  '), hasLength(2));

    final PasswordVaultService again = _vault(disk);
    await again.load();
    expect(again.entries.map((PasswordEntry e) => e.password), <String>[
      'tajne-haslo-1',
      'inne-haslo',
    ]);
  });

  test('fields are checked: a password too long is refused, never cut '
      'short', () async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    Future<PasswordFieldsProblem?> problem(PasswordFields f) async {
      try {
        await vault.add(f);
        return null;
      } on PasswordVaultException catch (e) {
        expect(e.error, PasswordVaultError.invalid);
        return e.problem;
      }
    }

    expect(
      await problem(PasswordFields(name: 'x', password: 'a' * 513)),
      PasswordFieldsProblem.tooLong,
    );
    expect(
      await problem(const PasswordFields(password: 'x')),
      PasswordFieldsProblem.noName,
    );
    expect(
      await problem(const PasswordFields(name: 'x', login: 'y')),
      PasswordFieldsProblem.noPassword,
    );
    // Spaces around a password are part of it.
    final PasswordEntry e = await vault.add(
      const PasswordFields(name: ' Sklep ', password: ' z spacjami '),
    );
    expect(e.name, 'Sklep');
    expect(e.password, ' z spacjami ');
    expect(vault.entries, hasLength(1));
  });

  test('an edit keeps the earlier version; it can be taken back, and the '
      'history is bounded and can be forgotten', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PasswordVaultService vault = _vault(disk);
    final PasswordEntry first = await vault.add(_bank);
    PasswordEntry e = first;
    for (int i = 2; i <= 9; i++) {
      e = await vault.edit(
        e.id,
        PasswordFields(
          name: 'Bank',
          login: 'ania',
          password: 'haslo-$i',
          address: _bank.address,
        ),
      );
    }
    expect(e.password, 'haslo-9');
    expect(e.conflict, isFalse);
    expect(e.history, hasLength(kMaxPasswordHistory));
    expect(e.history.first.password, 'haslo-8');
    expect(e.history.last.password, 'haslo-4');
    // The pruned ones are gone from the store too.
    expect(_keys(disk), hasLength(kMaxPasswordHistory + 1));
    expect(e.createdAtMillis, first.createdAtMillis);

    // An unchanged edit writes nothing.
    final int before = _keys(disk).length;
    await vault.edit(e.id, e.fields);
    expect(_keys(disk).length, before);

    final PasswordEntry back = await vault.restorePrevious(
      e.id,
      e.history[2].versionKey,
    );
    expect(back.password, 'haslo-6');
    expect(back.history.first.password, 'haslo-9');

    final Map<String, Object?> beforeClear = _stored(disk);
    final PasswordEntry clean = await vault.clearHistory(e.id);
    expect(clean.history, isEmpty);
    expect(clean.password, 'haslo-6');
    expect(clean.keptOverDeletion, isFalse);
    // The current version and a marker naming the forgotten ones (no
    // password in it).
    expect(_keys(disk), hasLength(2));
    expect(_keys(disk), contains(clean.versionKey));
    expect(jsonEncode(_stored(disk)), isNot(contains('haslo-9')));
    // A copy (or a device that was away) made before brings none of them
    // back: the marker saw them.
    expect(await vault.mergeCopy(beforeClear), 0);
    expect(vault.entry(e.id)!.history, isEmpty);
    expect(jsonEncode(_stored(disk)), isNot(contains('haslo-9')));
    // Nor does the sync's taking of such a state.
    await vault.takeSyncState(<String, Object?>{
      ..._stored(disk),
      'e': <String, Object?>{
        ...(_stored(disk)['e']! as Map).cast<String, Object?>(),
        ...(beforeClear['e']! as Map).cast<String, Object?>(),
      },
    });
    expect(vault.entry(e.id)!.history, isEmpty);
    expect(jsonEncode(_stored(disk)), isNot(contains('haslo-9')));
    // Cleared again later: the markers fold into one.
    await vault.edit(
      e.id,
      PasswordFields(
        name: 'Bank',
        login: 'ania',
        password: 'haslo-10',
        address: _bank.address,
      ),
    );
    await vault.clearHistory(e.id);
    expect(_keys(disk), hasLength(2));
    expect(vault.entry(e.id)!.password, 'haslo-10');
  });

  test('a deletion removes the entry and its old passwords from the store, '
      'leaving a marker', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PasswordVaultService vault = _vault(disk);
    final PasswordEntry e = await vault.add(_bank);
    await vault.edit(
      e.id,
      const PasswordFields(name: 'Bank', password: 'nowe-haslo'),
    );
    await vault.add(_mail);
    expect(await vault.delete(e.id), isTrue);
    expect(await vault.delete(e.id), isFalse);
    expect(vault.entries.single.name, 'poczta');
    final String stored = jsonEncode(_stored(disk));
    expect(stored, isNot(contains('tajne-haslo-1')));
    expect(stored, isNot(contains('nowe-haslo')));
    final PasswordVaultService again = _vault(disk);
    await again.load();
    expect(again.entries.single.name, 'poczta');
  });

  test(
    'two devices change one entry at once: the newer wins, the other '
    'password stays in its history, marked, until the person picks one',
    () async {
      final MemoryLedgerDisk phone = MemoryLedgerDisk();
      final MemoryLedgerDisk laptop = MemoryLedgerDisk();
      int t = 1000;
      final PasswordVaultService a = _vault(phone, now: () => t, seed: 1);
      final PasswordVaultService b = _vault(laptop, now: () => t, seed: 2);
      final PasswordEntry e = await a.add(_bank);
      await _syncBoth(phone, laptop, <String>{}, <String>{});
      await b.load();

      t = 2000;
      await a.edit(
        e.id,
        const PasswordFields(
          name: 'Bank',
          login: 'ania',
          password: 'z-telefonu',
        ),
      );
      t = 3000;
      await b.edit(
        e.id,
        const PasswordFields(
          name: 'Bank',
          login: 'ania',
          password: 'z-laptopa',
        ),
      );
      await _syncBoth(phone, laptop, <String>{}, <String>{});
      await a.load();
      await b.load();
      for (final PasswordVaultService v in <PasswordVaultService>[a, b]) {
        final PasswordEntry got = v.entry(e.id)!;
        expect(got.password, 'z-laptopa');
        expect(got.conflict, isTrue);
        final PasswordHistoryItem other = got.history.firstWhere(
          (PasswordHistoryItem h) => h.concurrent,
        );
        expect(other.password, 'z-telefonu');
        // The first password is history, not a conflict.
        expect(
          got.history
              .where((PasswordHistoryItem h) => !h.concurrent)
              .single
              .password,
          'tajne-haslo-1',
        );
      }

      // Taking the phone's one back settles it, on both.
      t = 4000;
      final PasswordEntry got = a.entry(e.id)!;
      await a.restorePrevious(
        e.id,
        got.history
            .firstWhere((PasswordHistoryItem h) => h.concurrent)
            .versionKey,
      );
      await _syncBoth(phone, laptop, <String>{}, <String>{});
      await b.load();
      expect(b.entry(e.id)!.password, 'z-telefonu');
      expect(b.entry(e.id)!.conflict, isFalse);
      expect(
        b.entry(e.id)!.history.map((PasswordHistoryItem h) => h.password),
        containsAll(<String>['z-laptopa', 'tajne-haslo-1']),
      );
    },
  );

  test('deleted on one device while changed on another: the change keeps '
      'the entry (a password never vanishes unseen)', () async {
    final MemoryLedgerDisk phone = MemoryLedgerDisk();
    final MemoryLedgerDisk laptop = MemoryLedgerDisk();
    int t = 1000;
    final PasswordVaultService a = _vault(phone, now: () => t, seed: 3);
    final PasswordVaultService b = _vault(laptop, now: () => t, seed: 4);
    final PasswordEntry e = await a.add(_bank);
    await _syncBoth(phone, laptop, <String>{}, <String>{});
    await b.load();
    final Set<String> beforeDelete = _keys(phone);

    t = 3000;
    await a.delete(e.id);
    final Set<String> removedOnA = beforeDelete.difference(_keys(phone));
    // The laptop's clock is behind: its edit looks older than the deletion.
    t = 2000;
    await b.edit(
      e.id,
      const PasswordFields(name: 'Bank', password: 'zmienione-na-stronie'),
    );
    await _syncBoth(phone, laptop, removedOnA, <String>{});
    await a.load();
    await b.load();
    for (final PasswordVaultService v in <PasswordVaultService>[a, b]) {
      final PasswordEntry got = v.entry(e.id)!;
      expect(got.password, 'zmienione-na-stronie');
      expect(got.keptOverDeletion, isTrue);
    }
    // Deleted again, now seen: gone everywhere.
    t = 5000;
    final Set<String> before = _keys(laptop);
    await b.delete(e.id);
    await _syncBoth(
      phone,
      laptop,
      <String>{},
      before.difference(_keys(laptop)),
    );
    await a.load();
    expect(a.entries, isEmpty);
  });

  test(
    'while Zen is locked nothing is read, written or kept in memory',
    () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      bool locked = false;
      final PasswordVaultService vault = _vault(disk, isLocked: () => locked);
      final PasswordEntry e = await vault.add(_bank);
      final Uint8List stored = disk.files[kPasswordVaultKey]!;

      locked = true;
      vault.forget();
      expect(vault.entries, isEmpty);
      expect(vault.entry(e.id), isNull);
      expect(vault.loaded, isFalse);
      for (final Future<Object?> Function() call
          in <Future<Object?> Function()>[
            vault.load,
            () => vault.add(_mail),
            () => vault.edit(e.id, _mail),
            () => vault.delete(e.id),
            vault.exportForCopy,
            () => vault.mergeCopy(<String, Object?>{}),
            () => vault.takeSyncState(<String, Object?>{}),
          ]) {
        await expectLater(
          call(),
          throwsA(
            isA<PasswordVaultException>().having(
              (PasswordVaultException x) => x.error,
              'error',
              PasswordVaultError.locked,
            ),
          ),
        );
      }
      expect(await vault.syncState(), isNull);
      expect(await vault.copyPassword(e.id), isFalse);
      expect(disk.files[kPasswordVaultKey], stored);

      locked = false;
      await vault.load();
      expect(vault.entry(e.id)!.password, 'tajne-haslo-1');
    },
  );

  test('passwords and logins reach the clipboard only through the expiring '
      'copy', () async {
    final List<String> copied = <String>[];
    final PasswordVaultService vault = _vault(
      MemoryLedgerDisk(),
      copy: (String text) async {
        copied.add(text);
        return true;
      },
    );
    final PasswordEntry e = await vault.add(_bank);
    expect(await vault.copyPassword(e.id), isTrue);
    expect(await vault.copyLogin(e.id), isTrue);
    expect(await vault.copyPassword('missing00'), isFalse);
    expect(copied, <String>['tajne-haslo-1', 'ania']);
    expect(
      kPasswordClipboardTtl,
      lessThanOrEqualTo(const Duration(minutes: 1)),
    );
  });

  test('no secret in any debug string', () async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    final PasswordEntry e = await vault.add(_bank);
    final PasswordEntry edited = await vault.edit(
      e.id,
      const PasswordFields(name: 'Bank', password: 'drugie-haslo'),
    );
    final PasswordImportReport report = await vault.importCsv(
      Uint8List.fromList(
        utf8.encode(
          'name,url,username,password\nSklep,https://s.pl,jan,hasloX\n',
        ),
      ),
    );
    final PasswordCsvParse parse = parsePasswordCsvText(
      'name,url,username,password\nSklep,https://s.pl,jan,hasloX\n',
    );
    final List<Object> all = <Object>[
      e,
      edited,
      edited.fields,
      edited.history.single,
      PasswordVersion.fromJson(edited.versionKey, <String, Object?>{
        'i': e.id,
        'a': 1,
        'p': 'drugie-haslo',
      })!,
      report,
      parse,
      parse.rows.single,
      const PasswordVaultException(PasswordVaultError.invalid),
    ];
    for (final Object o in all) {
      final String text = o.toString();
      for (final String secret in <String>[
        'tajne-haslo-1',
        'drugie-haslo',
        'hasloX',
        'ania',
        'jan',
        'Bank',
        'Sklep',
        'sejf',
        'bank.example',
      ]) {
        expect(text, isNot(contains(secret)), reason: '${o.runtimeType}');
      }
    }
  });

  test('a vault from a newer Zen is kept as it is and read-only', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final Uint8List newer = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'v': 2,
          'x': <int>[1],
        }),
      ),
    );
    await disk.write(kPasswordVaultKey, newer);
    final PasswordVaultService vault = _vault(disk);
    await vault.load();
    expect(vault.newerFormat, isTrue);
    expect(vault.entries, isEmpty);
    await expectLater(vault.add(_bank), throwsA(isA<PasswordVaultException>()));
    expect(await vault.syncState(), isNull);
    expect(disk.files[kPasswordVaultKey], newer);
    // A copy of the account still carries it as it is.
    expect(await vault.exportForCopy(), <String, Object?>{
      'v': 2,
      'x': <int>[1],
    });
  });

  test('a damaged vault is neither read as empty nor written over', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final Uint8List damaged = Uint8List.fromList(
      utf8.encode('{"v":1,"e":{"abc'),
    );
    await disk.write(kPasswordVaultKey, damaged);
    final PasswordVaultService vault = _vault(disk);
    await vault.load();
    expect(vault.damaged, isTrue);
    await expectLater(
      vault.add(_bank),
      throwsA(
        isA<PasswordVaultException>().having(
          (PasswordVaultException x) => x.error,
          'error',
          PasswordVaultError.damaged,
        ),
      ),
    );
    // The sync sends nothing from it (an empty vault would delete every
    // password on the other devices).
    expect(await vault.syncState(), isNull);
    expect(disk.files[kPasswordVaultKey], damaged);
  });

  test('the reader takes typed fields only, cuts them to their limits, and '
      'keeps what a newer build added', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      kPasswordVaultKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'v': 1,
            'later': <String, Object?>{'k': 1},
            'e': <String, Object?>{
              'aaaaaaaa1': <String, Object?>{
                'i': 'entry0001',
                'a': 10,
                'n': 'Stary',
                'p': 'x' * 600,
                'u': 7,
                'later': 'kept',
              },
              // Not versions: a bad key, a bad entry id, no time.
              'BAD KEY!': <String, Object?>{'i': 'entry0002', 'a': 1},
              'aaaaaaaa2': <String, Object?>{'i': 'x', 'a': 1},
              'aaaaaaaa3': <String, Object?>{'i': 'entry0003'},
              'aaaaaaaa4': 'nie mapa',
            },
          }),
        ),
      ),
    );
    final PasswordVaultService vault = _vault(disk);
    await vault.load();
    final PasswordEntry e = vault.entries.single;
    expect(e.name, 'Stary');
    expect(e.password.length, kMaxPasswordChars);
    expect(e.address, '');
    await vault.add(_mail);
    final Map<String, Object?> stored = _stored(disk);
    expect(stored['later'], <String, Object?>{'k': 1});
    expect(
      ((stored['e']! as Map)['aaaaaaaa1'] as Map)['later'],
      'kept',
      reason: 'a version is written back exactly as it came',
    );
  });

  test('the stored format as 1.16.5 writes it stays readable, and the sync '
      'cuts it into whole versions, never into fields', () async {
    // Never edit this sample: a later build that cannot read it has broken
    // what phones and backups keep.
    const String stored =
        '{"v":1,"e":{'
        '"k0000000001":{"i":"e000000001","a":100,"c":100,"pa":0,"n":"Bank",'
        '"l":"ania","p":"stare","u":"https://bank.example.com"},'
        '"k0000000002":{"i":"e000000001","a":200,"c":100,"pa":100,'
        '"n":"Bank","l":"ania","p":"nowe","u":"https://bank.example.com",'
        '"o":"notatka"},'
        '"k0000000003":{"i":"e000000002","a":150,"c":150,"pa":0,"n":"Gone",'
        '"p":"x"},'
        '"k0000000004":{"i":"e000000002","a":300,"d":1,"s":["k0000000003"]},'
        '"k0000000005":{"i":"e000000003","a":400,"d":1,"s":[]}'
        '}}';
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      kPasswordVaultKey,
      Uint8List.fromList(utf8.encode(stored)),
    );
    final PasswordVaultService vault = _vault(disk);
    await vault.load();
    final PasswordEntry e = vault.entries.single;
    expect(e.id, 'e000000001');
    expect(e.password, 'nowe');
    expect(e.note, 'notatka');
    expect(e.createdAtMillis, 100);
    expect(e.history.single.password, 'stare');
    expect(e.conflict, isFalse);

    final Map<String, Object?> state = (await vault.syncState())!;
    final Map<String, Object?> units = flattenAccountState(state);
    expect(
      units.keys.where((String k) => k.startsWith('m\u001fe\u001f')),
      hasLength(5),
    );
    expect(
      units['m\u001fe\u001fk0000000002'],
      containsPair('p', 'nowe'),
      reason: 'a version travels whole',
    );
  });

  test('the vault is bounded: entries and bytes', () async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    final PasswordImportReport report = await vault.importRows(
      PasswordCsvParse(
        layout: PasswordCsvLayout.generic,
        read: kMaxPasswordEntries + 3,
        rows: <PasswordCsvRow>[
          for (int i = 0; i < kMaxPasswordEntries + 3; i++)
            PasswordCsvRow(
              i + 2,
              PasswordFields(name: 'konto $i', password: 'haslo $i'),
            ),
        ],
      ),
    );
    expect(report.imported, kMaxPasswordEntries);
    expect(report.skipped[PasswordImportSkip.full], 3);
    await expectLater(
      vault.add(_bank),
      throwsA(
        isA<PasswordVaultException>().having(
          (PasswordVaultException x) => x.error,
          'error',
          PasswordVaultError.full,
        ),
      ),
    );

    // Bytes: large notes fill it before the count does.
    final PasswordVaultService big = _vault(MemoryLedgerDisk());
    final PasswordImportReport heavy = await big.importRows(
      PasswordCsvParse(
        layout: PasswordCsvLayout.generic,
        read: 1500,
        rows: <PasswordCsvRow>[
          for (int i = 0; i < 1500; i++)
            PasswordCsvRow(
              i + 2,
              PasswordFields(
                name: 'n$i',
                password: 'p$i',
                note: 'ż' * kMaxPasswordNoteChars,
              ),
            ),
        ],
      ),
    );
    expect(heavy.imported, lessThan(1500));
    expect(heavy.skipped[PasswordImportSkip.full], 1500 - heavy.imported);
    expect(
      (await big.disk.read(kPasswordVaultKey))!.length,
      lessThanOrEqualTo(kMaxPasswordVaultBytes),
    );
  });

  test('a copy merges in: missing versions come, a deletion here stays, '
      'nothing here is written over', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PasswordVaultService old = _vault(disk, seed: 5);
    final PasswordEntry bank = await old.add(_bank);
    final PasswordEntry mail = await old.add(_mail);
    final Map<String, Object?> copy = (await old.exportForCopy())!;

    await old.delete(mail.id);
    await old.edit(
      bank.id,
      const PasswordFields(name: 'Bank', password: 'nowsze'),
    );
    await old.add(const PasswordFields(name: 'Tylko tu', password: 'x'));
    expect(await old.mergeCopy(copy), 0);
    expect(old.entries.map((PasswordEntry e) => e.name), <String>[
      'Bank',
      'Tylko tu',
    ]);
    expect(old.entry(bank.id)!.password, 'nowsze');

    final PasswordVaultService fresh = _vault(MemoryLedgerDisk(), seed: 6);
    await fresh.add(const PasswordFields(name: 'Nowe', password: 'y'));
    expect(await fresh.mergeCopy(padPasswordSection(copy)), 2);
    expect(fresh.entries.map((PasswordEntry e) => e.name), <String>[
      'Bank',
      'Nowe',
      'poczta',
    ]);
    // Garbage changes nothing.
    expect(await fresh.mergeCopy('nie'), 0);
    expect(await fresh.mergeCopy(<String, Object?>{'v': 9}), 0);
    expect(fresh.entries, hasLength(3));
  });

  test('the padded section hides the count to 16 KiB', () async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await vault.add(_bank);
    final int one = utf8
        .encode(jsonEncode(padPasswordSection((await vault.exportForCopy())!)))
        .length;
    for (int i = 0; i < 20; i++) {
      await vault.add(PasswordFields(name: 'k$i', password: 'p$i'));
    }
    final int many = utf8
        .encode(jsonEncode(padPasswordSection((await vault.exportForCopy())!)))
        .length;
    expect(one, kPasswordSectionPadBytes);
    expect(many, one);
  });

  test('damaged stores never throw anything but a refusal', () async {
    final Random random = Random(20261110);
    final List<Uint8List> cases = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList(<int>[0xFF, 0xFE, 0x00]),
      for (final Object? json in <Object?>[
        null,
        1,
        'tekst',
        <Object?>[],
        <String, Object?>{'v': 'jeden'},
        <String, Object?>{'v': 1, 'e': <Object?>[]},
        <String, Object?>{
          'v': 1,
          'e': <String, Object?>{
            'aaaaaaaa1': <String, Object?>{
              'i': 'entry0001',
              'a': 1,
              'd': 1,
              's': 5,
            },
            'aaaaaaaa2': <String, Object?>{
              'i': 'entry0001',
              'a': 2,
              'pa': 'x',
              'c': <int>[],
              'n': <String>['x'],
            },
          },
        },
      ])
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
      for (int i = 0; i < 40; i++)
        Uint8List.fromList(
          List<int>.generate(random.nextInt(300), (_) => random.nextInt(256)),
        ),
    ];
    for (final Uint8List bytes in cases) {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await disk.write(kPasswordVaultKey, bytes);
      final PasswordVaultService vault = _vault(disk);
      await vault.load();
      await vault.syncState();
      await vault.exportForCopy();
      try {
        await vault.add(_bank);
      } on PasswordVaultException {
        // Refused: read-only.
      }
    }
  });

  test('nothing of the vault reaches the background, the locked receivers '
      'or the clipboard by another way', () {
    for (final String path in <String>[
      'lib/src/features/runtime/locked_receiver.dart',
      'lib/src/features/runtime/ios_locked_receiver.dart',
      'lib/src/features/runtime/android_background_runtime.dart',
      'lib/src/features/runtime/locked_handoff.dart',
      'lib/src/features/runtime/locked_presence.dart',
      'lib/src/features/relay/locked_outbox_writer.dart',
      'lib/src/features/relay/locked_mailbox_writer.dart',
      'lib/src/features/relay/relay_engine_locked.dart',
      'lib/src/features/account/multi/background_accounts.dart',
      'lib/src/features/account/multi/desktop_background.dart',
      'lib/src/features/security/background_keys.dart',
      'lib/src/features/runtime/notification_privacy.dart',
    ]) {
      final String text = File(path).readAsStringSync();
      expect(text, isNot(contains('features/passwords/')), reason: path);
      expect(text, isNot(contains(kPasswordVaultKey)), reason: path);
    }
    // The screens too: a password leaves them only through the vault.
    for (final File f in Directory(
      'lib/src/features/passwords',
    ).listSync(recursive: true).whereType<File>()) {
      final String text = f.readAsStringSync();
      expect(text, isNot(contains('Clipboard.setData')), reason: f.path);
      expect(text, isNot(contains('print(')), reason: f.path);
      // Text selected on a screen is copied with the plain clipboard,
      // which is never cleared.
      expect(text, isNot(contains('SelectionArea(')), reason: f.path);
      expect(text, isNot(contains('SelectableText')), reason: f.path);
    }
    // The store key is written only by the vault (sync and copies go
    // through it).
    for (final FileSystemEntity f in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) {
        continue;
      }
      final String text = f.readAsStringSync();
      if (RegExp(r'write\(\s*kPasswordVaultKey').hasMatch(text)) {
        expect(
          f.path.replaceAll('\\', '/'),
          endsWith('passwords/password_vault_service.dart'),
        );
      }
    }
  });
}
