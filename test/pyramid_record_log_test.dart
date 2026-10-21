import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_record_log.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import 'support/pyramid_world.dart';

Map<String, Object?> _e(int i, [String v = 'a']) => <String, Object?>{
  'id': 'r$i',
  'v': v,
};

Uint8List _me(PyramidService s) =>
    (s.disk as MemoryLedgerDisk).files['pyramid/me']!;

PyramidService _restart(
  PyramidWorld w,
  String name,
  LedgerDisk disk, {
  int recordSegmentEntries = 4,
}) => PyramidService(
  host: w.net[name],
  disk: disk,
  identitySeed: w.seedOf(disk),
  now: () => w.net.now,
  recordSegmentEntries: recordSegmentEntries,
);

void main() {
  group('the record log', () {
    test('an append writes the last segment, and the index when a segment '
        'starts', () async {
      final _CountingDisk disk = _CountingDisk();
      final PyramidRecordLog log = PyramidRecordLog(disk, segmentEntries: 3);
      expect(await log.readAll(), isNull);

      await log.append(<Object?>[_e(1), _e(2)]);
      expect(disk.writes, <String>['pyramid/records/0', 'pyramid/records/idx']);

      disk.reset();
      await log.append(<Object?>[_e(3)]);
      expect(disk.writes, <String>['pyramid/records/0']);
      expect(disk.reads, <String>['pyramid/records/idx', 'pyramid/records/0']);

      disk.reset();
      await log.append(<Object?>[_e(4), _e(5), _e(6), _e(7)]);
      expect(disk.writes, <String>[
        'pyramid/records/1',
        'pyramid/records/2',
        'pyramid/records/idx',
      ], reason: 'the full segment 0 is not written again');
      expect(log.entryCount, 7);

      final PyramidRecordLog again = PyramidRecordLog(disk, segmentEntries: 3);
      expect(await again.readAll(), <Object?>[
        for (int i = 1; i <= 7; i++) _e(i),
      ]);
      expect(again.entryCount, 7);
    });

    test('a changed record is appended again; a rewrite keeps the last of '
        'each under new numbers', () async {
      final _CountingDisk disk = _CountingDisk();
      final PyramidRecordLog log = PyramidRecordLog(disk, segmentEntries: 2);
      await log.append(<Object?>[_e(1), _e(2), _e(3)]);
      await log.append(<Object?>[_e(1, 'b')]);
      expect(await log.readAll(), <Object?>[_e(1), _e(2), _e(3), _e(1, 'b')]);

      disk.reset();
      await log.rewrite(<Object?>[_e(1, 'b'), _e(2), _e(3)]);
      expect(disk.writes, <String>[
        'pyramid/records/2',
        'pyramid/records/3',
        'pyramid/records/idx',
        'pyramid/records/idx',
      ]);
      expect(disk.deletes, <String>['pyramid/records/0', 'pyramid/records/1']);
      expect(disk.files.keys.toSet(), <String>{
        'pyramid/records/2',
        'pyramid/records/3',
        'pyramid/records/idx',
      });
      expect(log.entryCount, 3);
      expect(
        await PyramidRecordLog(disk, segmentEntries: 2).readAll(),
        <Object?>[_e(1, 'b'), _e(2), _e(3)],
      );
      // Appends go on after it.
      await log.append(<Object?>[_e(4)]);
      expect(
        await PyramidRecordLog(disk, segmentEntries: 2).readAll(),
        <Object?>[_e(1, 'b'), _e(2), _e(3), _e(4)],
      );
    });

    test('a rewrite cut short before its index leaves the old log in '
        'charge', () async {
      final _CountingDisk disk = _CountingDisk();
      final PyramidRecordLog log = PyramidRecordLog(disk, segmentEntries: 2);
      await log.append(<Object?>[_e(1), _e(2), _e(3)]);
      disk.failWrite = (String k) => k == 'pyramid/records/idx';
      await expectLater(log.rewrite(<Object?>[_e(9)]), throwsA(anything));
      disk.failWrite = null;
      expect(
        await PyramidRecordLog(disk, segmentEntries: 2).readAll(),
        <Object?>[_e(1), _e(2), _e(3)],
      );
      // The next one writes over what the cut-short one left.
      await log.rewrite(<Object?>[_e(9)]);
      expect(
        await PyramidRecordLog(disk, segmentEntries: 2).readAll(),
        <Object?>[_e(9)],
      );
      expect(disk.files.keys.toSet(), <String>{
        'pyramid/records/2',
        'pyramid/records/idx',
      });
    });

    test('what a rewrite could not delete goes on the next read', () async {
      final _CountingDisk disk = _CountingDisk();
      final PyramidRecordLog log = PyramidRecordLog(disk, segmentEntries: 2);
      await log.append(<Object?>[_e(1), _e(2), _e(3)]);
      disk.failDelete = (String _) => true;
      await log.rewrite(<Object?>[_e(1), _e(2)]);
      expect(disk.files.containsKey('pyramid/records/0'), isTrue);

      disk.failDelete = null;
      expect(
        await PyramidRecordLog(disk, segmentEntries: 2).readAll(),
        <Object?>[_e(1), _e(2)],
      );
      expect(disk.files.keys.toSet(), <String>{
        'pyramid/records/2',
        'pyramid/records/idx',
      });
    });

    test('an index of a newer version is not read', () async {
      final _CountingDisk disk = _CountingDisk();
      disk.files['pyramid/records/idx'] = utf8.encode('{"v":2}');
      await expectLater(
        PyramidRecordLog(disk).readAll(),
        throwsFormatException,
      );
    });
  });

  group('the pyramid service', () {
    test(
      'records survive a restart: the log reads back what was kept',
      () async {
        final PyramidWorld w = await PyramidWorld.six(recordSegmentEntries: 4);
        await w['S'].alarm('Ćwiczenia', length: const Duration(hours: 1));
        await w.net.run();
        await w.approve('B', PyrT.alarm);
        await w.sync();
        for (final SimPhone p in w.net.phones) {
          final PyramidService s = w.pyr(p);
          final PyramidService back = _restart(w, p.name, s.disk);
          await back.load();
          expect(back.recordIds.toSet(), s.recordIds.toSet(), reason: p.name);
          for (final String id in s.recordIds) {
            expect(
              jsonEncode(back.recordOf(id)!.toJson()),
              jsonEncode(s.recordOf(id)!.toJson()),
              reason: '${p.name} $id',
            );
          }
          expect(
            PyramidWorld.fingerprint(back.state!),
            PyramidWorld.fingerprint(s.state!),
            reason: p.name,
          );
          // Changes pile up as entries, but never past twice the records
          // (then the log is written afresh).
          expect(
            back.recordLogEntries,
            lessThanOrEqualTo(max(2 * s.recordIds.length, 4)),
            reason: p.name,
          );
          expect(
            (s.disk as MemoryLedgerDisk).files.containsKey('pyramid/records'),
            isFalse,
            reason: 'only the log',
          );
        }
      },
    );

    test('a newcomer gets the whole pyramid: no segment is written more '
        'often than it has records', () async {
      final PyramidWorld w = await PyramidWorld.six(recordSegmentEntries: 4);
      final _CountingDisk disk = _CountingDisk();
      final SimPhone n = w.add('N', disk: disk);
      await w.join(w.net['B'], n);
      await w.sync();
      final PyramidService s = w.pyr(n);
      expect(s.isMember, isTrue);
      final Map<String, int> perSegment = <String, int>{};
      for (final String k in disk.writes) {
        if (k.startsWith('pyramid/records/') && k != 'pyramid/records/idx') {
          perSegment[k] = (perSegment[k] ?? 0) + 1;
        }
      }
      expect(perSegment, isNotEmpty);
      for (final MapEntry<String, int> e in perSegment.entries) {
        expect(e.value, lessThanOrEqualTo(4), reason: e.key);
      }
      expect(disk.writes, isNot(contains('pyramid/records')));

      final PyramidService back = _restart(w, 'N', disk);
      await back.load();
      expect(back.recordIds.toSet(), s.recordIds.toSet());
      expect(
        PyramidWorld.fingerprint(back.state!),
        PyramidWorld.fingerprint(s.state!),
      );
    });

    test('the last entry of a record is the one that counts, and the record '
        'keeps its place', () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService s = w['S'];
      final List<String> ids = s.recordIds;
      final String x = ids.firstWhere(
        (String id) => s.recordOf(id)!.sigs.length >= 2,
      );
      final PyramidRecord full = s.recordOf(x)!;
      final MapEntry<String, String> one = full.sigs.entries.first;
      final PyramidRecord fewer = PyramidRecord(
        body: full.body,
        sigs: <String, String>{one.key: one.value},
      );

      Future<PyramidService> loadWith(
        PyramidRecord first,
        PyramidRecord last,
      ) async {
        final MemoryLedgerDisk disk = MemoryLedgerDisk();
        disk.files['pyramid/me'] = _me(s);
        await PyramidRecordLog(disk, segmentEntries: 3).append(<Object?>[
          for (final String id in ids)
            <String, dynamic>{
              'r': (id == x ? first : s.recordOf(id)!).toJson(),
            },
          <String, dynamic>{'r': last.toJson()},
        ]);
        final PyramidService back = _restart(w, 'S', disk);
        await back.load();
        return back;
      }

      final PyramidService grown = await loadWith(fewer, full);
      expect(grown.recordOf(x)!.sigs, full.sigs);
      expect(grown.recordIds, ids);
      final PyramidService shrunk = await loadWith(full, fewer);
      expect(shrunk.recordOf(x)!.sigs, hasLength(1));
      expect(shrunk.recordIds, ids);
    });

    test('a log grown past twice its records is written afresh', () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService s = w['S'];
      final List<String> ids = s.recordIds;
      final String y = ids.lastWhere(
        (String id) => s.recordOf(id)!.type == PyrT.admit,
      );
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      disk.files['pyramid/me'] = _me(s);
      final PyramidRecordLog log = PyramidRecordLog(disk, segmentEntries: 4);
      for (int round = 0; round < 3; round++) {
        await log.append(<Object?>[
          for (final String id in ids)
            if (id != y) <String, dynamic>{'r': s.recordOf(id)!.toJson()},
        ]);
      }
      final PyramidService back = _restart(w, 'S', disk);
      await back.load();
      expect(back.recordLogEntries, 3 * (ids.length - 1));
      expect(back.recordIds, hasLength(ids.length - 1));

      expect(await back.ingest(s.recordOf(y)!, spread: false), isTrue);
      expect(back.recordLogEntries, ids.length);
      final Iterable<String> segments = disk.files.keys.where(
        (String k) =>
            k.startsWith('pyramid/records/') && k != 'pyramid/records/idx',
      );
      expect(
        segments,
        hasLength((ids.length + 3) ~/ 4),
        reason: 'old segments deleted',
      );

      final PyramidService again = _restart(w, 'S', disk);
      await again.load();
      expect(again.recordIds.toSet(), ids.toSet());
      expect(again.recordLogEntries, ids.length);
    });

    test('nothing is written while the log cannot be read', () async {
      final PyramidWorld w = PyramidWorld();
      final _CountingDisk disk = _CountingDisk()
        ..failRead = (String k) => k == 'pyramid/records/idx';
      final SimPhone x = w.add('X', disk: disk);
      final PyramidService s = w.pyr(x);
      await s.load();
      await s.found(myName: 'X', nat: 'PL', birthYear: 1990, gender: 'k');
      expect(s.isMember, isTrue, reason: 'kept in memory');
      expect(disk.writes, isEmpty);
    });
  });
}

/// A disk in memory that tells what was read, written and deleted, and can
/// fail on purpose.
final class _CountingDisk implements LedgerDisk {
  final MemoryLedgerDisk _inner = MemoryLedgerDisk();
  final List<String> reads = <String>[];
  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];
  bool Function(String key)? failRead;
  bool Function(String key)? failWrite;
  bool Function(String key)? failDelete;

  Map<String, Uint8List> get files => _inner.files;

  void reset() {
    reads.clear();
    writes.clear();
    deletes.clear();
  }

  @override
  Future<Uint8List?> read(String key) async {
    if (failRead?.call(key) ?? false) {
      throw StateError('Locked.');
    }
    reads.add(key);
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, Uint8List data) async {
    if (failWrite?.call(key) ?? false) {
      throw const FileSystemException('Disk full.');
    }
    writes.add(key);
    await _inner.write(key, data);
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete?.call(key) ?? false) {
      throw const FileSystemException('Busy.');
    }
    deletes.add(key);
    await _inner.delete(key);
  }
}
