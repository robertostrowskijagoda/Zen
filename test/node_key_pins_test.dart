import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/runtime/node_key_pins.dart';

final String _fp = 'ab' * 32;
final String _other = 'cd' * 32;

/// Seals by prefixing the storage key (enough to see sealing happens).
final class _TagProtector implements KeyedBinaryPayloadProtector {
  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async =>
      Uint8List.fromList(<int>[...utf8.encode('$storageKey|'), ...payload]);

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async {
    final List<int> tag = utf8.encode('$storageKey|');
    if (payload.length < tag.length ||
        utf8.decode(payload.sublist(0, tag.length)) != '$storageKey|') {
      throw StateError('not sealed for $storageKey');
    }
    return Uint8List.sublistView(payload, tag.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('nodeKeyPinsFrom keeps well-formed mesh pins only', () {
    expect(nodeKeyPinsFrom(null), isNull);
    expect(nodeKeyPinsFrom(<String, Object?>{'pins': 'x'}), isNull);
    expect(
      nodeKeyPinsFrom(<String, Object?>{
        'pins': <String, Object?>{
          '200:1111::1': _fp,
          '201:2222::2': 'short',
          '8.8.8.8': _fp,
          'not an address': _fp,
          '202:3333::3': _other.toUpperCase(),
        },
      }),
      <String, String>{'200:1111::1': _fp},
    );
  });

  test('pins go to the node on start and are kept when they change', () async {
    final Directory dir = await Directory.systemTemp.createTemp('pins');
    addTearDown(() => dir.delete(recursive: true));
    final File file = await nodeKeyPinsFile(dir);
    Map<String, dynamic> nodePins = <String, dynamic>{
      'pins': <String, dynamic>{'200:1111::1': _fp},
    };
    final List<String> written = <String>[];
    NodeKeyPinKeeper keeper() => NodeKeyPinKeeper(
      readPins: () => nodePins,
      writePins: written.add,
      file: () async => file,
      protector: _TagProtector(),
    );

    final NodeKeyPinKeeper first = keeper();
    await first.restore();
    expect(written, isEmpty, reason: 'nothing kept yet');
    await first.save();
    final Uint8List sealed = file.readAsBytesSync();
    expect(
      utf8.decode(sealed).startsWith('$kNodeKeyPinsStorageKey|'),
      isTrue,
      reason: 'the pins name who this device talks to: sealed',
    );
    final DateTime saved = file.lastModifiedSync();
    await first.save();
    expect(file.lastModifiedSync(), saved, reason: 'unchanged: not rewritten');

    nodePins = <String, dynamic>{
      'pins': <String, dynamic>{'200:1111::1': _fp, '200:4444::4': _other},
    };
    await first.stop();

    // The next run hands them back to the node.
    final NodeKeyPinKeeper second = keeper();
    await second.restore();
    expect(written, hasLength(1));
    expect(jsonDecode(written.single), <String, Object?>{
      'pins': <String, Object?>{'200:1111::1': _fp, '200:4444::4': _other},
    });
  });

  test('an unreadable pin file is left alone', () async {
    final Directory dir = await Directory.systemTemp.createTemp('pins');
    addTearDown(() => dir.delete(recursive: true));
    final File file = await nodeKeyPinsFile(dir);
    await file.writeAsString('plain text, not sealed');
    final List<String> written = <String>[];
    await NodeKeyPinKeeper(
      readPins: () => <String, dynamic>{},
      writePins: written.add,
      file: () async => file,
      protector: _TagProtector(),
    ).restore();
    expect(written, isEmpty);
  });
}
