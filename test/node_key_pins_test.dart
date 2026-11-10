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
      'firm': <Object?>[],
      'vouched': <Object?>[],
      'seen': <String, dynamic>{'200:1111::1': 7200},
      'known': <Object?>[],
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

    // Only seen again within the hour: not worth a write.
    nodePins = <String, dynamic>{
      ...nodePins,
      'seen': <String, dynamic>{'200:1111::1': 7300},
    };
    await first.save();
    expect(file.lastModifiedSync(), saved);

    nodePins = <String, dynamic>{
      'pins': <String, dynamic>{'200:1111::1': _fp, '200:4444::4': _other},
      'firm': <Object?>['200:4444::4'],
      'vouched': <Object?>['200:1111::1', '8.8.8.8'],
      'seen': <String, dynamic>{'200:1111::1': 7200, '200:4444::4': 10800},
      'known': <Object?>['200:4444::4', 'nonsense'],
    };
    await first.stop();

    // The next run hands them back to the node, each of its kind, and who
    // is known.
    final NodeKeyPinKeeper second = keeper();
    await second.restore();
    expect(written, hasLength(1));
    expect(jsonDecode(written.single), <String, Object?>{
      'restore': true,
      'pins': <String, Object?>{'200:1111::1': _fp, '200:4444::4': _other},
      'firm': <Object?>['200:4444::4'],
      'vouched': <Object?>['200:1111::1'],
      'seen': <String, Object?>{'200:1111::1': 7200, '200:4444::4': 10800},
      'known': <Object?>['200:4444::4'],
    });
  });

  test('pins kept before their kinds were come back without kinds: the '
      'node takes them as loose', () async {
    final Directory dir = await Directory.systemTemp.createTemp('pins');
    addTearDown(() => dir.delete(recursive: true));
    final File file = await nodeKeyPinsFile(dir);
    await file.writeAsBytes(
      await _TagProtector().sealFor(
        kNodeKeyPinsStorageKey,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'v': 1,
              'pins': <String, Object?>{'200:1111::1': _fp},
            }),
          ),
        ),
      ),
    );
    final List<String> written = <String>[];
    await NodeKeyPinKeeper(
      readPins: () => <String, dynamic>{},
      writePins: written.add,
      file: () async => file,
      protector: _TagProtector(),
    ).restore();
    expect(jsonDecode(written.single), <String, Object?>{
      'restore': true,
      'pins': <String, Object?>{'200:1111::1': _fp},
    });
  });

  test('records the node refused against a vouched key are reported', () async {
    final Directory dir = await Directory.systemTemp.createTemp('pins');
    addTearDown(() => dir.delete(recursive: true));
    final File file = await nodeKeyPinsFile(dir);
    final List<Map<String, String>> reported = <Map<String, String>>[];
    await NodeKeyPinKeeper(
      readPins: () => <String, dynamic>{
        'pins': <String, dynamic>{},
        'conflicts': <String, dynamic>{'200:1111::1': _fp, 'x': _fp},
      },
      writePins: (String _) {},
      file: () async => file,
      onConflicts: reported.add,
    ).save();
    expect(reported, <Map<String, String>>[
      <String, String>{'200:1111::1': _fp},
    ]);
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
