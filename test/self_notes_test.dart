import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/chat/self_notes.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/security/app_security_service.dart';

// "Notatki dla siebie": notes kept as a map note by note, so the account's
// sync (which merges a stored state key by key) takes notes written on two
// devices at once from both, and a deletion does not come back: not at the
// limit either, where a new note is refused instead of an older one going.
void main() {
  test('notes are added, read back in order and deleted', () async {
    int now = 1000;
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final SelfNotesService notes = SelfNotesService(
      disk: disk,
      now: () => now++,
    );
    await notes.add('mleko');
    await notes.add('  ');
    final SelfNote? second = await notes.add('chleb');
    expect(notes.notes.map((SelfNote n) => n.text), <String>['mleko', 'chleb']);

    await notes.delete(second!.id);
    expect(notes.notes.map((SelfNote n) => n.text), <String>['mleko']);

    final SelfNotesService again = SelfNotesService(disk: disk);
    await again.load();
    expect(again.notes.map((SelfNote n) => n.text), <String>['mleko']);
  });

  test('two devices: their maps merged key by key keep every note and the '
      'deletion', () async {
    final MemoryLedgerDisk phone = MemoryLedgerDisk();
    final MemoryLedgerDisk laptop = MemoryLedgerDisk();
    final SelfNotesService a = SelfNotesService(disk: phone, now: () => 10);
    final SelfNotesService b = SelfNotesService(disk: laptop, now: () => 20);
    final SelfNote shared = (await a.add('wspólna'))!;
    // The laptop has it too (synced earlier), then deletes it, while the
    // phone writes another one.
    await laptop.write(kSelfNotesKey, (await phone.read(kSelfNotesKey))!);
    await b.load();
    await b.delete(shared.id);
    await a.add('z telefonu');

    // What the sync does with a stored state: key by key, the newer wins.
    Map<String, Object?> read(MemoryLedgerDisk d) => Map<String, Object?>.from(
      jsonDecode(utf8.decode(d.files[kSelfNotesKey]!)) as Map,
    );
    final Map<String, Object?> merged = <String, Object?>{...read(phone)};
    read(laptop).forEach((String id, Object? note) {
      final Object? mine = merged[id];
      if (mine is! Map || ((note! as Map)['a'] as int) > (mine['a'] as int)) {
        merged[id] = note;
      }
    });
    await phone.write(kSelfNotesKey, utf8.encode(jsonEncode(merged)));
    await a.load();
    expect(a.notes.map((SelfNote n) => n.text), <String>['z telefonu']);
  });
  test('a note written before the stored ones were read keeps them', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final SelfNotesService first = SelfNotesService(disk: disk, now: () => 1);
    await first.add('stara');
    final SelfNotesService second = SelfNotesService(disk: disk, now: () => 2);
    await second.add('nowa');
    expect(second.notes.map((SelfNote n) => n.text), <String>['stara', 'nowa']);
    final SelfNotesService read = SelfNotesService(disk: disk);
    await read.load();
    expect(read.notes, hasLength(2));
  });

  test('at the limit a new note is refused and said so; nothing older goes '
      'for it, and a deletion marker is never dropped to make room', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      kSelfNotesKey,
      utf8.encode(
        jsonEncode(<String, Object?>{
          for (int i = 0; i < kMaxSelfNotes - 1; i++)
            'n$i': <String, Object?>{'t': 'n$i', 'a': 10 + i},
          // A note deleted here: another device may still have it.
          'gone': <String, Object?>{'t': '', 'a': 99999, 'd': true},
        }),
      ),
    );
    final SelfNotesService notes = SelfNotesService(
      disk: disk,
      now: () => 100000,
    );
    await notes.add('jeszcze jedna');
    Map<String, Object?> stored() => Map<String, Object?>.from(
      jsonDecode(utf8.decode(disk.files[kSelfNotesKey]!)) as Map,
    );
    expect(stored(), hasLength(kMaxSelfNotes + 1));
    expect(stored().containsKey('gone'), isTrue);
    expect(notes.notes, hasLength(kMaxSelfNotes));

    // One more is refused, with words for the person; nothing went.
    await expectLater(
      notes.add('i jeszcze'),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          selfNotesFullText(),
        ),
      ),
    );
    expect(notes.notes.first.text, 'n0');
    expect(notes.notes, hasLength(kMaxSelfNotes));

    // A note deleted makes room.
    await notes.delete('n0');
    expect(await notes.add('i jeszcze'), isNotNull);
    expect(stored().containsKey('gone'), isTrue);

    // The deleted one does not come back from a device that still has it.
    await notes.mergeCopy(<String, Object?>{
      'gone': <String, Object?>{'t': 'stara', 'a': 50},
      'n0': <String, Object?>{'t': 'n0', 'a': 10},
    });
    expect(notes.notes.map((SelfNote n) => n.text), isNot(contains('stara')));
    expect(notes.notes.map((SelfNote n) => n.text), isNot(contains('n0')));
  });

  test('deletion markers past their own bound go oldest first', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      kSelfNotesKey,
      utf8.encode(
        jsonEncode(<String, Object?>{
          for (int i = 0; i < kMaxSelfNoteMarkers; i++)
            'd$i': <String, Object?>{'t': '', 'a': 10 + i, 'd': true},
          'keep': <String, Object?>{'t': 'zostaje', 'a': 5},
        }),
      ),
    );
    int now = 100000;
    final SelfNotesService notes = SelfNotesService(
      disk: disk,
      now: () => now++,
    );
    await notes.delete('keep');
    final Map<String, Object?> kept = Map<String, Object?>.from(
      jsonDecode(utf8.decode(disk.files[kSelfNotesKey]!)) as Map,
    );
    expect(kept, hasLength(kMaxSelfNoteMarkers));
    expect(kept.containsKey('d0'), isFalse, reason: 'deleted longest ago');
    expect(kept.containsKey('keep'), isTrue);
  });

  test('a device that never had a note keeps an empty set of them once its '
      'store is open, so the account\'s sync can take the others\' notes '
      'in', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final MemoryAppSecurityService security = MemoryAppSecurityService();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        ledgerDiskProvider.overrideWithValue(disk),
        appSecurityServiceProvider.overrideWithValue(security),
      ],
    );
    addTearDown(container.dispose);
    final StoredStateSyncDomain domain = StoredStateSyncDomain(
      kSelfNotesKey,
      disk,
      container.read(selfNotesServiceProvider).load,
    );
    await pumpEventQueue();
    expect(await domain.read(), isNotNull, reason: 'readable: none yet');
    expect(await domain.read(), isEmpty);

    // What the sync then writes in comes into the notes.
    await domain.write(<String, Object?>{
      'z-laptopa': <String, Object?>{'t': 'z laptopa', 'a': 7},
    });
    expect(
      container
          .read(selfNotesServiceProvider)
          .notes
          .map((SelfNote n) => n.text),
      <String>['z laptopa'],
    );
  });

  test('the stored notes are read once, not again for every note', () async {
    final _CountingDisk disk = _CountingDisk();
    final SelfNotesService notes = SelfNotesService(disk: disk);
    await notes.add('mleko');
    await notes.add('chleb');
    final SelfNote? third = await notes.add('masło');
    await notes.delete(third!.id);
    expect(disk.reads, 1);
    expect(notes.notes.map((SelfNote n) => n.text), <String>['mleko', 'chleb']);
  });
}

/// A disk that counts its reads.
final class _CountingDisk implements LedgerDisk {
  final MemoryLedgerDisk _inner = MemoryLedgerDisk();
  int reads = 0;

  @override
  Future<Uint8List?> read(String key) {
    reads++;
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, Uint8List data) => _inner.write(key, data);

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
