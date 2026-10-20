import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/mark_of_the_web.dart';

void main() {
  test('the zone stream is the standard ZoneTransfer text', () {
    expect(kZoneTransferContent, '[ZoneTransfer]\r\nZoneId=3\r\n');
    expect(
      zoneIdentifierPath(r'C:\Users\a\Downloads\setup.exe'),
      r'C:\Users\a\Downloads\setup.exe:Zone.Identifier',
    );
  });

  test('on Windows a saved file gets the zone of the internet', () async {
    final Directory dir = await Directory.systemTemp.createTemp('zen-motw-');
    addTearDown(() => dir.delete(recursive: true));
    final String path = '${dir.path}${Platform.pathSeparator}plik.exe';
    await File(path).writeAsBytes(<int>[1, 2, 3]);

    await markFileFromInternet(path, windows: true);

    final File zone = File(zoneIdentifierPath(path));
    expect(await zone.readAsString(), '[ZoneTransfer]\r\nZoneId=3\r\n');
    expect(await File(path).readAsBytes(), <int>[1, 2, 3]);
  });

  test('anywhere else nothing is written', () async {
    final Directory dir = await Directory.systemTemp.createTemp('zen-motw-');
    addTearDown(() => dir.delete(recursive: true));
    final String path = '${dir.path}${Platform.pathSeparator}plik.exe';
    await File(path).writeAsBytes(<int>[1]);

    await markFileFromInternet(path, windows: false);

    expect(await File(zoneIdentifierPath(path)).exists(), isFalse);
    expect(dir.listSync().length, 1);
  });

  test('a failure to mark the file is ignored', () async {
    final Directory dir = await Directory.systemTemp.createTemp('zen-motw-');
    addTearDown(() => dir.delete(recursive: true));
    // The folder of the stream does not exist, so writing it fails.
    final String gone =
        '${dir.path}${Platform.pathSeparator}nie-ma'
        '${Platform.pathSeparator}plik.exe';

    await markFileFromInternet(gone, windows: true);
    await markFileFromInternet('', windows: true);

    expect(dir.listSync(), isEmpty);
  });
}
