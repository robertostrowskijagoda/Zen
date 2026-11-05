import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/chat/self_notes.dart';

// "Notatki dla siebie": notes kept as a map note by note, so the account's
// sync (which merges a stored state key by key) takes notes written on two
// devices at once from both, and a deletion does not come back.
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
}
