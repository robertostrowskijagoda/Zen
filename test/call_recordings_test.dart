import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/calls/call_recordings.dart';

void main() {
  test('recordings are kept, listed newest first and deleted', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final CallRecordingStore store = CallRecordingStore(disk);
    expect(await store.list(), isEmpty);

    await store.add(
      peer: 'Ada',
      data: Uint8List.fromList(<int>[1, 2, 3]),
      millis: 1000,
    );
    final CallRecording second = await store.add(
      peer: 'Bob',
      data: Uint8List.fromList(<int>[4, 5]),
      millis: 2000,
    );
    final List<CallRecording> all = await store.list();
    expect(all.map((CallRecording r) => r.peer), <String>['Bob', 'Ada']);
    expect(all.first.bytes, 2);
    expect(await store.read(second.id), <int>[4, 5]);

    await store.delete(second.id);
    expect((await store.list()).single.peer, 'Ada');
    expect(await store.read(second.id), isNull);
  });
}
