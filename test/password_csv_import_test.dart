import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/passwords/password_csv_import.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';

// Importing passwords from the CSV exports of browsers and password
// managers: the layout is told from the header; every row read is either
// taken or counted with its reason.

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  test('Chrome and Edge', () {
    final PasswordCsvParse p = parsePasswordCsvText(
      'name,url,username,password,note\r\n'
      'Bank,https://bank.example.com/,ania,"p,a""ss",\r\n'
      'Edge bez notatki,https://e.example.com,,secret,"dwie\r\nlinie"\r\n',
    );
    expect(p.layout, PasswordCsvLayout.chrome);
    expect(p.read, 2);
    expect(p.rows, hasLength(2));
    expect(p.rows[0].fields.password, 'p,a"ss');
    expect(p.rows[0].fields.address, 'https://bank.example.com/');
    expect(p.rows[0].fields.login, 'ania');
    expect(p.rows[1].fields.note, 'dwie\nlinie');
    expect(p.rows[1].line, 3);
  });

  test('Firefox: no name column, the address names the entry', () {
    final PasswordCsvParse p = parsePasswordCsvText(
      '"url","username","password","httpRealm","formActionOrigin","guid",'
      '"timeCreated","timeLastUsed","timePasswordChanged"\n'
      '"https://www.example.com","jan","hunter2",,"https://www.example.com",'
      '"{abc}","1","2","3"\n',
    );
    expect(p.layout, PasswordCsvLayout.firefox);
    expect(p.rows.single.fields.name, '');
    expect(p.rows.single.fields.address, 'https://www.example.com');
    expect(p.rows.single.fields.password, 'hunter2');
  });

  test('Bitwarden: only logins; several addresses give the first', () {
    final PasswordCsvParse p = parsePasswordCsvText(
      'folder,favorite,type,name,notes,fields,reprompt,login_uri,'
      'login_username,login_password,login_totp\n'
      ',1,login,Poczta,uwaga,,0,"https://a.example.com,https://b.example.com",'
      'ola,haslo1,\n'
      ',,note,Notatka,tylko tekst,,0,,,,\n'
      ',,card,Karta,,,0,,,,\n',
    );
    expect(p.layout, PasswordCsvLayout.bitwarden);
    expect(p.read, 3);
    expect(p.rows.single.fields.address, 'https://a.example.com');
    expect(p.rows.single.fields.note, 'uwaga');
    expect(p.skipped[PasswordImportSkip.notLogin], 2);
  });

  test('KeePassXC (the recycle bin left out) and KeePass', () {
    final PasswordCsvParse xc = parsePasswordCsvText(
      '"Group","Title","Username","Password","URL","Notes","TOTP","Icon",'
      '"Last Modified","Created"\n'
      '"Root","Forum","kasia","k-pass","https://forum.example","","","0",'
      '"2026-01-01","2026-01-01"\n'
      '"Root/Recycle Bin","Stare","kasia","old","","","","0","",""\n',
    );
    expect(xc.layout, PasswordCsvLayout.keepassxc);
    expect(xc.rows.single.fields.name, 'Forum');
    expect(xc.skipped[PasswordImportSkip.deleted], 1);

    final PasswordCsvParse kp = parsePasswordCsvText(
      '"Account","Login Name","Password","Web Site","Comments"\n'
      '"Sklep","tom","t0m","https://sklep.example.pl","kupony"\n',
    );
    expect(kp.layout, PasswordCsvLayout.keepass);
    expect(kp.rows.single.fields.note, 'kupony');
    expect(kp.rows.single.fields.login, 'tom');
  });

  test('semicolons, tabs, a BOM, UTF-16, and a header in any case', () {
    final PasswordCsvParse semi = parsePasswordCsvText(
      '﻿Name;URL;Username;Password\nA;https://a.pl;x;"1;2"\n',
    );
    expect(semi.layout, PasswordCsvLayout.chrome);
    expect(semi.rows.single.fields.password, '1;2');
    final PasswordCsvParse tab = parsePasswordCsvText(
      'title\tpassword\nZ\tzz\n',
    );
    expect(tab.layout, PasswordCsvLayout.generic);
    expect(tab.rows.single.fields.password, 'zz');

    const String text = 'name,url,username,password\nŻółw,https://ż.pl,ę,ą\n';
    final List<int> le = <int>[0xFF, 0xFE];
    for (final int u in text.codeUnits) {
      le
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    final PasswordCsvParse utf16 = parsePasswordCsv(Uint8List.fromList(le));
    expect(utf16.rows.single.fields.name, 'Żółw');
    final PasswordCsvParse bom = parsePasswordCsv(
      Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)]),
    );
    expect(bom.rows.single.fields.password, 'ą');
  });

  test('every row read is taken or counted with its reason', () {
    final PasswordCsvParse p = parsePasswordCsvText(
      'name,url,username,password\n'
      'ok,https://a.pl,u,p\n'
      '\n'
      'bez hasla,https://b.pl,u,\n'
      ',,u,p\n'
      'za duzo,https://c.pl,u,p,extra\n'
      'dlugie,https://d.pl,u,${'x' * (kMaxPasswordChars + 1)}\n'
      '"niedomkniety,https://e.pl,u,p\n',
    );
    expect(p.read, 6);
    expect(p.rows.single.fields.name, 'ok');
    expect(p.skipped, <PasswordImportSkip, int>{
      PasswordImportSkip.noPassword: 1,
      PasswordImportSkip.noName: 1,
      PasswordImportSkip.malformed: 2,
      PasswordImportSkip.tooLong: 1,
    });
  });

  test('what is not an export is refused whole', () {
    expect(
      parsePasswordCsvText('a,b,c\n1,2,3\n').error,
      PasswordCsvError.unknownLayout,
    );
    expect(parsePasswordCsvText('').error, PasswordCsvError.unknownLayout);
    expect(
      parsePasswordCsvText('password\nx\n').error,
      PasswordCsvError.unknownLayout,
    );
    expect(
      parsePasswordCsv(Uint8List.fromList(<int>[0x6E, 0xC3, 0x28])).error,
      PasswordCsvError.encoding,
    );
    expect(
      parsePasswordCsv(Uint8List(kMaxPasswordCsvBytes + 1)).error,
      PasswordCsvError.tooLarge,
    );
  });

  test('rows past the limit are counted, not kept', () {
    final StringBuffer b = StringBuffer('name,password\n');
    for (int i = 0; i < kMaxPasswordCsvRows + 5; i++) {
      b.write('n$i,p$i\n');
    }
    final PasswordCsvParse p = parsePasswordCsvText(b.toString());
    expect(p.rows, hasLength(kMaxPasswordCsvRows));
    expect(p.read, kMaxPasswordCsvRows + 5);
    expect(p.skipped[PasswordImportSkip.tooMany], 5);
  });

  test('random bytes never throw', () {
    final Random random = Random(4180);
    const String alphabet = 'ab,;"\r\n\t ';
    for (int i = 0; i < 300; i++) {
      parsePasswordCsv(
        Uint8List.fromList(
          List<int>.generate(random.nextInt(400), (_) => random.nextInt(256)),
        ),
      );
      parsePasswordCsvText(
        'name,password\n${List<String>.generate(random.nextInt(200), (_) => alphabet[random.nextInt(alphabet.length)]).join()}',
      );
    }
  });

  test('the vault takes an export, skips what it has already, reports, and '
      'wipes the bytes it was given', () async {
    final PasswordVaultService vault = PasswordVaultService(
      disk: MemoryLedgerDisk(),
      random: Random(1),
    );
    await vault.add(
      const PasswordFields(
        name: 'Bank',
        login: 'ania',
        password: 'p1',
        address: 'https://bank.example.com',
      ),
    );
    final Uint8List file = _utf8(
      'name,url,username,password\n'
      'Bank,https://bank.example.com,ania,p1\n'
      'Bank,https://bank.example.com,ania,p2\n'
      'Sklep,https://sklep.pl,ania,p3\n'
      'Sklep,https://sklep.pl,ania,p3\n'
      'bez hasla,https://x.pl,ania,\n',
    );
    final PasswordImportReport report = await vault.importCsv(file);
    expect(file.every((int b) => b == 0), isTrue);
    expect(report.layout, PasswordCsvLayout.chrome);
    expect(report.read, 5);
    expect(report.imported, 2);
    expect(report.skipped, <PasswordImportSkip, int>{
      PasswordImportSkip.noPassword: 1,
      PasswordImportSkip.duplicate: 2,
    });
    expect(report.imported + report.skippedCount, report.read);
    // Another password for the same login comes in beside the old one.
    expect(
      vault.entries
          .where((PasswordEntry e) => e.name == 'Bank')
          .map((PasswordEntry e) => e.password)
          .toSet(),
      <String>{'p1', 'p2'},
    );
    final PasswordImportReport bad = await vault.importCsv(_utf8('x,y\n1,2\n'));
    expect(bad.error, PasswordCsvError.unknownLayout);
    expect(bad.imported, 0);
  });
}
