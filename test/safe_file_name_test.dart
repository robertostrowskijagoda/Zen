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

  test('ordinary names stay as they are', () {
    expect(safeFileName('Wakacje 2026 (1).jpg'), 'Wakacje 2026 (1).jpg');
    expect(safeFileName('zażółć.txt'), 'zażółć.txt');
  });
}
