import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/file_picking.dart';
import 'package:zen/src/features/account/key_file.dart';

// Files Zen reads whole because they were opened or picked from outside (a
// key backup, an update) are read only up to a cap: a huge file named like
// one never fills the memory, and is refused as damaged.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zen-picked-');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('a small file is read whole', () async {
    final File file = File('${dir.path}/klucz.zenkey')
      ..writeAsBytesSync(List<int>.generate(89, (int i) => i));
    final Uint8List bytes = await readPickedFile(
      file.path,
      maxBytes: kMaxKeyFileReadBytes,
    );
    expect(bytes, List<int>.generate(89, (int i) => i));
  });

  test('a huge "key backup" is read only one byte past the cap and refused '
      'as damaged', () async {
    final File file = File('${dir.path}/klucz.zenkey');
    final RandomAccessFile handle = file.openSync(mode: FileMode.write);
    // 64 MB, written sparsely: only its length matters.
    handle
      ..setPositionSync(64 * 1024 * 1024 - 1)
      ..writeByteSync(1)
      ..closeSync();
    final Uint8List bytes = await readPickedFile(
      file.path,
      maxBytes: kMaxKeyFileReadBytes,
    );
    expect(bytes.length, kMaxKeyFileReadBytes + 1);
    expect(
      (await decryptKeyFile(bytes, 'haslo-do-klucza')).error,
      KeyFileError.format,
    );
  });
}
