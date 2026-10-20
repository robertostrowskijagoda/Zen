import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/safe_file_name.dart';

void main() {
  test('a name from a peer never leaves the folder', () {
    expect(
      safeFileName(
        '../../../../data/user/0/x/files/runtime/yggdrasil.config.json',
      ),
      'yggdrasil.config.json',
    );
    expect(safeFileName(r'..\..\Windows\evil.dll'), 'evil.dll');
    expect(safeFileName('C:\\Users\\a\\photo.jpg'), 'photo.jpg');
    expect(safeFileName('..'), isNull);
    expect(safeFileName('/'), isNull);
    expect(safeFileName('  .hidden '), 'hidden');
    expect(safeFileName('a<b>c:d"e|f?g*h.txt'), 'abcdefgh.txt');
    expect(safeFileName('tab\tname.pdf'), 'tabname.pdf');
    expect(safeFileName(null), isNull);
  });

  test('a long name is cut but keeps its extension', () {
    final String name = safeFileName('${'a' * 300}.jpeg')!;
    expect(name.length, 120);
    expect(name, endsWith('.jpeg'));
  });

  test('dots and spaces at the end are dropped, as Windows does', () {
    expect(safeFileName('faktura.exe.'), 'faktura.exe');
    expect(safeFileName('faktura.exe...'), 'faktura.exe');
    expect(safeFileName('skrypt.ps1 '), 'skrypt.ps1');
    expect(safeFileName('skrypt.ps1 . '), 'skrypt.ps1');
    expect(safeFileName('zdjecie.jpg. .'), 'zdjecie.jpg');
    expect(safeFileName('plik.exe\u200B'), 'plik.exe');
    expect(safeFileName('plik.exe\u00A0.'), 'plik.exe');
    expect(safeFileName('a.b.'), 'a.b');
    // Nothing usable is left.
    expect(safeFileName('...'), isNull);
    expect(safeFileName('. . .'), isNull);
    expect(safeFileName(r'..\..\ .'), isNull);
    // Dots inside stay.
    expect(safeFileName('archiwum.tar.gz'), 'archiwum.tar.gz');
    expect(safeFileName('Wakacje 2026.'), 'Wakacje 2026');
  });

  test('a cut name does not end in a dot or a space either', () {
    final String spaced = safeFileName('${'a' * 118}  ${'b' * 20}')!;
    expect(spaced.length, lessThanOrEqualTo(120));
    expect(spaced, isNot(endsWith(' ')));
    expect(spaced, isNot(endsWith('.')));
    final String dotted = safeFileName('${'a' * 119}.${'b' * 50}')!;
    expect(dotted, isNot(endsWith('.')));
    // The extension is kept; the stem it is glued to is cleaned.
    final String withExt = safeFileName('${'a' * 115} ${'b' * 25}.exe')!;
    expect(withExt, '${'a' * 115}.exe');
  });

  test('a very long run of dots and spaces is handled quickly', () {
    final String junk = '${' ' * 200000}x${' .' * 100000}';
    expect(safeFileName(junk), 'x');
  });

  test('ordinary names stay as they are', () {
    expect(safeFileName('Wakacje 2026 (1).jpg'), 'Wakacje 2026 (1).jpg');
    expect(safeFileName('zażółć.txt'), 'zażółć.txt');
  });
}
