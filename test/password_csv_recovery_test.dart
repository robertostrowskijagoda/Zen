import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/passwords/password_csv_import.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_import.dart';

// A damaged row of a password export costs that row, not the rest of the
// file: a quote that was not meant as one (a password starting with `"`)
// no longer swallows every row after it, and the report says where the
// damaged rows are and from which line on a file could not be read.

PasswordCsvParse _p(String text) =>
    parsePasswordCsv(Uint8List.fromList(utf8.encode(text)));

String _file(String damagedRow, {int after = 200}) {
  final StringBuffer csv = StringBuffer('name,url,username,password\n')
    ..writeln('A,https://a.example.com,ania,p1')
    ..writeln(damagedRow);
  for (int i = 0; i < after; i++) {
    csv.writeln('R$i,https://r$i.example.com,ania,q$i');
  }
  return csv.toString();
}

void main() {
  test('a stray quote at the start of a password: that row alone is '
      'damaged, the 200 after it are read', () {
    final PasswordCsvParse p = _p(_file('B,https://b.example.com,ania,"p2'));
    expect(p.read, 202);
    expect(p.rows, hasLength(201));
    expect(p.skipped, <PasswordImportSkip, int>{
      PasswordImportSkip.malformed: 1,
    });
    expect(p.damaged, <PasswordCsvDamage>[const PasswordCsvDamage(3, 3)]);
    expect(p.rows.last.fields.password, 'q199');
    expect(p.rows[1].line, 4);
  });

  test('a stray quote that a later quoted cell seems to close: read on from '
      'the line after it', () {
    final StringBuffer csv = StringBuffer('name,url,username,password\n')
      ..writeln('A,https://a.example.com,ania,p1')
      ..writeln('B,https://b.example.com,ania,"p2')
      ..writeln('C,https://c.example.com,ania,q1')
      ..writeln('D,https://d.example.com,ania,"x,y"')
      ..writeln('E,https://e.example.com,ania,q3');
    final PasswordCsvParse p = _p(csv.toString());
    expect(p.rows.map((PasswordCsvRow r) => r.fields.name), <String>[
      'A',
      'C',
      'D',
      'E',
    ]);
    expect(p.rows[2].fields.password, 'x,y');
    expect(p.damaged, <PasswordCsvDamage>[const PasswordCsvDamage(3, 3)]);
  });

  test('a note over several lines is still one row', () {
    final PasswordCsvParse p = _p(
      'Title,Url,Username,Password,Notes\n'
      'Bank,https://bank.example.com,ania,p1,"two\nlines, and ""quotes"""\n'
      'Mail,https://mail.example.com,ania,p2,\n',
    );
    expect(p.rows, hasLength(2));
    expect(p.rows.first.fields.note, 'two\nlines, and "quotes"');
    expect(p.damaged, isEmpty);
  });

  test('when no whole row follows, the file could not be read from the '
      'damaged row on, and the report says so', () {
    final PasswordCsvParse p = _p(
      'name,url,username,password\n'
      'A,https://a.example.com,ania,p1\n'
      'B,https://b.example.com,ania,"p2\n'
      'just text\n'
      'more text\n',
    );
    expect(p.rows, hasLength(1));
    expect(p.damaged, <PasswordCsvDamage>[const PasswordCsvDamage(3, null)]);
  });

  testWidgets('the report names the damaged lines', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: const Scaffold(
          body: PasswordImportReportDialog(
            report: PasswordImportReport(
              layout: PasswordCsvLayout.chrome,
              read: 210,
              imported: 200,
              skipped: <PasswordImportSkip, int>{
                PasswordImportSkip.malformed: 3,
              },
              damaged: <PasswordCsvDamage>[
                PasswordCsvDamage(3, 3),
                PasswordCsvDamage(7, 9),
                PasswordCsvDamage(40, null),
              ],
            ),
          ),
        ),
      ),
    );
    final String text = tester
        .widget<Text>(find.byKey(const Key('password-import-damaged')))
        .data!;
    expect(text, contains('3, 7–9'));
    expect(text, contains('40'));
  });

  test('1Password\'s archived rows and the rows of a KeePassXC recycle bin '
      'named in another language are left out', () {
    final PasswordCsvParse onePassword = _p(
      'Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\n'
      'Bank,https://bank.example.com,ania,p1,,false,false,,\n'
      'Old,https://old.example.com,ania,p2,,false,true,,\n',
    );
    expect(onePassword.rows.single.fields.name, 'Bank');
    expect(onePassword.skipped[PasswordImportSkip.archived], 1);

    final PasswordCsvParse keepass = _p(
      '"Group","Title","Username","Password","URL","Notes"\n'
      '"Główna/Bank","Bank","ania","p1","https://bank.example.com",""\n'
      '"Główna/Kosz","Stary","ania","p2","https://old.example.com",""\n'
      '"Root/Papierkorb/Alt","Alt","ania","p3","https://alt.example.com",""\n'
      '"Root/Recycle Bin","Gone","ania","p4","https://gone.example.com",""\n'
      '"Root/Praca/Kosz","Zostaje","ania","p5","https://kosz.example.com",""\n',
    );
    expect(keepass.rows.map((PasswordCsvRow r) => r.fields.name), <String>[
      'Bank',
      'Zostaje',
    ]);
    expect(keepass.skipped[PasswordImportSkip.deleted], 3);
  });
}
