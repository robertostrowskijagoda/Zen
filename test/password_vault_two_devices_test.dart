import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/passwords/password_csv_import.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/password_vault_sync.dart';

// The passwords on two devices of the account. Whether two edits of one
// entry clashed is told by what each version was made from, never by the
// devices' clocks, so a password changed on one device stays (marked)
// however many edits the other makes before they hear of each other; the
// same export imported on both before they synced ends as one entry each.
// Two devices run the real account sync; the laptop is offline (its
// changes wait in its log) while both edit.

int _t = 1000;

final class _Net {
  final List<_Channel> devices = <_Channel>[];
  final List<(String, Map<String, dynamic>)> log =
      <(String, Map<String, dynamic>)>[];

  /// Hands every device that is online what the others published and it
  /// has not had yet (a device offline gets it when it comes back).
  void deliver() {
    for (final _Channel d in devices) {
      if (!d.online) {
        continue;
      }
      for (int i = d.delivered; i < log.length; i++) {
        final (String from, Map<String, dynamic> body) = log[i];
        if (from != d.device) {
          d.inbox.add(body);
        }
      }
      d.delivered = log.length;
    }
  }
}

final class _Channel implements AccountSyncChannel {
  _Channel(this.net, this.device) {
    net.devices.add(this);
  }

  final _Net net;
  @override
  final String device;
  bool online = true;
  int delivered = 0;
  final StreamController<Map<String, dynamic>> inbox =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get hasOtherDevices => net.devices.length > 1;

  @override
  Iterable<Map<String, dynamic>> existing() => const <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get incoming => inbox.stream;

  @override
  Stream<void> get devicesChanged => const Stream<void>.empty();

  @override
  Future<bool> publish(Map<String, dynamic> body) async {
    net.log.add((device, jsonDecode(jsonEncode(body)) as Map<String, dynamic>));
    return true;
  }
}

final class _Device {
  _Device(_Net net, String id, int seed, {MemoryLedgerDisk? disk})
    : this._(net, id, seed, disk ?? MemoryLedgerDisk());

  _Device._(_Net net, String id, int seed, this.disk)
    : channel = _Channel(net, id),
      vault = PasswordVaultService(
        disk: disk,
        random: Random(seed),
        now: () => _t,
      );

  final _Channel channel;
  final MemoryLedgerDisk disk;
  final PasswordVaultService vault;
  late final PasswordVaultSyncDomain domain = PasswordVaultSyncDomain(vault);
  late final AccountStateSync sync = AccountStateSync(
    channel: channel,
    disk: MemoryLedgerDisk(),
    domains: <AccountSyncDomain>[domain],
    delay: const Duration(milliseconds: 1),
    scanEvery: const Duration(hours: 1),
  );
}

Future<void> _settle(_Net net, List<_Device> devices) async {
  for (int round = 0; round < 8; round++) {
    net.deliver();
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final _Device d in devices) {
      await d.sync.flush();
    }
  }
}

PasswordFields _f(String password, {String login = 'ania', String note = ''}) =>
    PasswordFields(
      name: 'Bank',
      login: login,
      password: password,
      address: 'https://bank.example.com',
      note: note,
    );

Future<(_Device, _Device, _Net, String)> _twoDevices() async {
  _t = 1000;
  final _Net net = _Net();
  final _Device phone = _Device(net, 'phone', 1);
  final _Device laptop = _Device(net, 'laptop', 2);
  await phone.sync.start();
  await laptop.sync.start();
  final PasswordEntry e = await phone.vault.add(_f('stare-haslo'));
  await _settle(net, <_Device>[phone, laptop]);
  await laptop.vault.load();
  expect(laptop.vault.entry(e.id)!.password, 'stare-haslo');
  return (phone, laptop, net, e.id);
}

Future<void> _bothOnline(_Device phone, _Device laptop, _Net net) async {
  await _settle(net, <_Device>[phone, laptop]);
  laptop.channel.online = true;
  await _settle(net, <_Device>[phone, laptop]);
}

Map<String, Object?> _stored(MemoryLedgerDisk disk) =>
    Map<String, Object?>.from(
      jsonDecode(utf8.decode(disk.files[kPasswordVaultKey]!)) as Map,
    );

void main() {
  test('one edit on each side is shown as a conflict on both', () async {
    final (_Device phone, _Device laptop, _Net net, String id) =
        await _twoDevices();
    laptop.channel.online = false;
    _t = 2000;
    await phone.vault.edit(id, _f('stare-haslo', login: 'ania.k'));
    _t = 2500;
    await laptop.vault.edit(id, _f('zmienione-na-laptopie'));
    await _bothOnline(phone, laptop, net);
    for (final _Device d in <_Device>[phone, laptop]) {
      expect(d.vault.entry(id)!.conflict, isTrue);
    }
  });

  test('a password changed on the laptop, then two later edits on the phone '
      'that did not know of it: both devices keep it, marked as a '
      'conflict', () async {
    final (_Device phone, _Device laptop, _Net net, String id) =
        await _twoDevices();
    laptop.channel.online = false;
    _t = 2500;
    await laptop.vault.edit(id, _f('zmienione-na-laptopie'));
    _t = 3000;
    await phone.vault.edit(id, _f('stare-haslo', login: 'ania.k'));
    _t = 4000;
    await phone.vault.edit(
      id,
      _f('stare-haslo', login: 'ania.k', note: 'PIN w sejfie'),
    );
    await _bothOnline(phone, laptop, net);
    for (final _Device d in <_Device>[phone, laptop]) {
      final PasswordEntry got = d.vault.entry(id)!;
      expect(got.conflict, isTrue, reason: d.channel.device);
      final PasswordHistoryItem laptops = got.history.firstWhere(
        (PasswordHistoryItem h) => h.password == 'zmienione-na-laptopie',
      );
      expect(laptops.concurrent, isTrue, reason: d.channel.device);
      // The phone's own earlier versions are history, not a conflict.
      expect(
        got.history.where((PasswordHistoryItem h) => h.concurrent),
        hasLength(1),
      );
    }
    // Taking the laptop's back settles it on both.
    _t = 5000;
    final PasswordEntry onPhone = phone.vault.entry(id)!;
    await phone.vault.restorePrevious(
      id,
      onPhone.history
          .firstWhere((PasswordHistoryItem h) => h.concurrent)
          .versionKey,
    );
    await _settle(net, <_Device>[phone, laptop]);
    for (final _Device d in <_Device>[phone, laptop]) {
      final PasswordEntry got = d.vault.entry(id)!;
      expect(got.password, 'zmienione-na-laptopie');
      expect(got.conflict, isFalse);
    }
  });

  test('six edits on the phone after the laptop\'s change: the laptop\'s '
      'password is never forgotten as old history', () async {
    final (_Device phone, _Device laptop, _Net net, String id) =
        await _twoDevices();
    laptop.channel.online = false;
    _t = 2000;
    await phone.vault.edit(id, _f('stare-haslo', note: 'n1'));
    _t = 2500;
    await laptop.vault.edit(id, _f('zmienione-na-laptopie'));
    for (int i = 2; i <= 7; i++) {
      _t = 1000 * (i + 1);
      await phone.vault.edit(id, _f('stare-haslo', note: 'n$i'));
    }
    await _bothOnline(phone, laptop, net);
    for (final _Device d in <_Device>[phone, laptop]) {
      final PasswordEntry got = d.vault.entry(id)!;
      final Map<String, Object?>? stored = await d.vault.syncState();
      expect(got.conflict, isTrue, reason: d.channel.device);
      expect(
        got.history
            .where((PasswordHistoryItem h) => h.concurrent)
            .map((PasswordHistoryItem h) => h.password),
        <String>['zmienione-na-laptopie'],
      );
      expect(jsonEncode(stored), contains('zmienione-na-laptopie'));
      // The phone's history is still bounded.
      expect(
        got.history.where((PasswordHistoryItem h) => !h.concurrent),
        hasLength(kMaxPasswordHistory),
      );
    }
  });

  test('"kept over a deletion" is settled by "Zostaw" (saved unchanged), '
      'on both devices', () async {
    final (_Device phone, _Device laptop, _Net net, String id) =
        await _twoDevices();
    laptop.channel.online = false;
    _t = 2000;
    await phone.vault.delete(id);
    _t = 2100;
    await laptop.vault.edit(id, _f('zmienione-na-laptopie'));
    await _bothOnline(phone, laptop, net);
    final PasswordEntry kept = phone.vault.entry(id)!;
    expect(kept.keptOverDeletion, isTrue);
    expect(laptop.vault.entry(id)!.keptOverDeletion, isTrue);
    _t = 3000;
    await phone.vault.edit(id, kept.fields);
    await _settle(net, <_Device>[phone, laptop]);
    for (final _Device d in <_Device>[phone, laptop]) {
      final PasswordEntry got = d.vault.entry(id)!;
      expect(got.keptOverDeletion, isFalse, reason: d.channel.device);
      expect(got.password, 'zmienione-na-laptopie');
    }
    // Saved unchanged once more, nothing is written.
    final Map<String, Object?> before = _stored(phone.disk);
    await phone.vault.edit(id, kept.fields);
    expect(_stored(phone.disk), before);
  });

  test('a deletion the laptop did not know of is shown even when its clock '
      'is ahead of the phone\'s', () async {
    final (_Device phone, _Device laptop, _Net net, String id) =
        await _twoDevices();
    laptop.channel.online = false;
    _t = 9000;
    await laptop.vault.edit(id, _f('a'));
    _t = 9500;
    await laptop.vault.edit(id, _f('b'));
    _t = 3000;
    await phone.vault.delete(id);
    await _bothOnline(phone, laptop, net);
    for (final _Device d in <_Device>[phone, laptop]) {
      final PasswordEntry got = d.vault.entry(id)!;
      expect(got.password, 'b');
      expect(got.keptOverDeletion, isTrue, reason: d.channel.device);
    }
  });

  test('a forgotten old password does not come back from an older copy, '
      'neither as history nor as a conflict', () async {
    _t = 1000;
    final PasswordVaultService vault = PasswordVaultService(
      disk: MemoryLedgerDisk(),
      random: Random(9),
      now: () => _t += 10,
    );
    PasswordEntry e = await vault.add(_f('haslo-0'));
    e = await vault.edit(e.id, _f('haslo-1'));
    final Map<String, Object?> old = (await vault.exportForCopy())!;
    for (int i = 2; i <= 12; i++) {
      e = await vault.edit(e.id, _f('haslo-$i'));
    }
    expect(await vault.mergeCopy(old), 0);
    final PasswordEntry got = vault.entry(e.id)!;
    expect(got.conflict, isFalse);
    expect(got.history, hasLength(kMaxPasswordHistory));
    expect(
      got.history.map((PasswordHistoryItem h) => h.password),
      isNot(contains('haslo-1')),
    );
  });

  test('deletions past the old cap of 2000 markers stay: an older copy brings '
      'no deleted entry back', () async {
    _t = 1000;
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PasswordVaultService vault = PasswordVaultService(
      disk: disk,
      random: Random(11),
      now: () => _t += 1,
    );
    Future<Map<String, Object?>> importDeleted(int n, String tag) async {
      await vault.importRows(
        PasswordCsvParse(
          layout: PasswordCsvLayout.generic,
          read: n,
          rows: <PasswordCsvRow>[
            for (int i = 0; i < n; i++)
              PasswordCsvRow(
                i + 2,
                PasswordFields(name: '$tag $i', password: 'p$i'),
              ),
          ],
        ),
      );
      final Map<String, Object?> copy = (await vault.exportForCopy())!;
      expect(
        await vault.deleteMany(vault.entries.map((PasswordEntry e) => e.id)),
        n,
      );
      return copy;
    }

    final Map<String, Object?> first = await importDeleted(1500, 'a');
    final Map<String, Object?> second = await importDeleted(1000, 'b');
    expect(await vault.mergeCopy(first), 0);
    expect(await vault.mergeCopy(second), 0);
    expect(vault.entries, isEmpty);
  });

  test('a deletion of an entry edited hundreds of times names every version '
      'it ever had', () async {
    _t = 1000;
    final PasswordVaultService vault = PasswordVaultService(
      disk: MemoryLedgerDisk(),
      random: Random(12),
      now: () => _t += 10,
    );
    PasswordEntry e = await vault.add(_f('haslo-0'));
    final Map<String, Object?> first = (await vault.exportForCopy())!;
    for (int i = 1; i <= 300; i++) {
      e = await vault.edit(e.id, _f('haslo-$i'));
    }
    await vault.delete(e.id);
    expect(await vault.mergeCopy(first), 0);
    expect(vault.entries, isEmpty);
  });

  test('a kind of version this build does not read survives every save, the '
      'sync and a copy', () async {
    final Map<String, Object?> later = <String, Object?>{
      'i': 'e000000009',
      'a': 50,
      'd': 2,
      'x': <String, Object?>{'k': 'z nowszej wersji'},
    };
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      kPasswordVaultKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'v': 1,
            'e': <String, Object?>{
              'k0000000001': <String, Object?>{
                'i': 'e000000001',
                'a': 100,
                'c': 100,
                'pa': 0,
                'n': 'Bank',
                'p': 'stare',
              },
              'k0000000009': later,
            },
          }),
        ),
      ),
    );
    _t = 1000;
    final PasswordVaultService vault = PasswordVaultService(
      disk: disk,
      random: Random(13),
      now: () => _t += 10,
    );
    await vault.load();
    expect(vault.entries.single.name, 'Bank');
    final PasswordEntry e = await vault.add(_f('nowe'));
    await vault.edit(e.id, _f('nowsze'));
    await vault.delete(vault.entries.first.id);
    expect((_stored(disk)['e']! as Map)['k0000000009'], later);
    await vault.takeSyncState((await vault.syncState())!);
    expect((_stored(disk)['e']! as Map)['k0000000009'], later);
    final Map<String, Object?> copy = (await vault.exportForCopy())!;
    final PasswordVaultService fresh = PasswordVaultService(
      disk: MemoryLedgerDisk(),
      random: Random(14),
    );
    expect(await fresh.mergeCopy(copy), greaterThan(0));
    expect(
      ((jsonDecode(utf8.decode((await fresh.disk.read(kPasswordVaultKey))!))
              as Map)['e']
          as Map)['k0000000009'],
      later,
    );
  });

  test('the same browser export imported on the phone and on the laptop '
      'before they synced: every login once on both, and a third import '
      'adds nothing', () async {
    final (_Device phone, _Device laptop, _Net net, String _) =
        await _twoDevices();
    const String csv =
        'name,url,username,password,note\n'
        'Poczta,https://mail.example.org,ania,p1,\n'
        'Sklep,https://shop.example.net,ania,p2,\n'
        'Forum,https://forum.example.com,ania,p3,\n';
    laptop.channel.online = false;
    _t = 2000;
    final PasswordImportReport onPhone = await phone.vault.importCsv(
      Uint8List.fromList(utf8.encode(csv)),
    );
    _t = 2100;
    final PasswordImportReport onLaptop = await laptop.vault.importCsv(
      Uint8List.fromList(utf8.encode(csv)),
    );
    expect(onPhone.imported, 3);
    expect(onLaptop.imported, 3);
    await _bothOnline(phone, laptop, net);
    // Bank and the three logins, the same entries on both.
    for (final _Device d in <_Device>[phone, laptop]) {
      expect(d.vault.entries, hasLength(4), reason: d.channel.device);
    }
    expect(
      phone.vault.entries.map((PasswordEntry e) => e.id),
      laptop.vault.entries.map((PasswordEntry e) => e.id),
    );
    final PasswordImportReport again = await phone.vault.importCsv(
      Uint8List.fromList(utf8.encode(csv)),
    );
    expect(again.imported, 0);
    expect(again.skipped[PasswordImportSkip.duplicate], 3);
    await _settle(net, <_Device>[phone, laptop]);
    expect(laptop.vault.entries, hasLength(4));
  });

  test('copies made before: removed at once, one of each stays, never one '
      'with history or waiting on the person', () async {
    _t = 1000;
    final PasswordVaultService vault = PasswordVaultService(
      disk: MemoryLedgerDisk(),
      random: Random(31),
      now: () => _t += 10,
    );
    final PasswordEntry first = await vault.add(_f('p1'));
    await vault.add(_f('p1'));
    await vault.add(_f('p1'));
    // A copy with history stays (its old password would go with it), and
    // so does the one it is a copy of when that has none.
    final PasswordEntry edited = await vault.add(_f('stare'));
    await vault.edit(edited.id, _f('p1'));
    // Same password, another login: not a copy.
    await vault.add(_f('p1', login: 'jan'));
    expect(vault.duplicateCount, 3);
    expect(await vault.removeDuplicates(), 3);
    expect(vault.entries, hasLength(2));
    expect(vault.entry(edited.id)!.history.single.password, 'stare');
    expect(vault.entry(first.id), isNull);
    expect(vault.duplicateCount, 0);
    expect(await vault.removeDuplicates(), 0);
  });

  test('a vault as 1.16.5 wrote it opens and syncs with a device on this '
      'build, and versions 1.16.5 writes later are read as it meant '
      'them', () async {
    // Never edit this sample: it is the 1.16.5 store of password_vault_test.
    const String stored =
        '{"v":1,"e":{'
        '"k0000000001":{"i":"e000000001","a":100,"c":100,"pa":0,"n":"Bank",'
        '"l":"ania","p":"stare","u":"https://bank.example.com"},'
        '"k0000000002":{"i":"e000000001","a":200,"c":100,"pa":100,'
        '"n":"Bank","l":"ania","p":"nowe","u":"https://bank.example.com",'
        '"o":"notatka"},'
        '"k0000000003":{"i":"e000000002","a":150,"c":150,"pa":0,"n":"Gone",'
        '"p":"x"},'
        '"k0000000004":{"i":"e000000002","a":300,"d":1,"s":["k0000000003"]},'
        '"k0000000005":{"i":"e000000003","a":400,"d":1,"s":[]}'
        '}}';
    _t = 1000;
    final _Net net = _Net();
    final MemoryLedgerDisk oldDisk = MemoryLedgerDisk();
    await oldDisk.write(
      kPasswordVaultKey,
      Uint8List.fromList(utf8.encode(stored)),
    );
    final _Device phone = _Device(net, 'phone', 21, disk: oldDisk);
    final _Device laptop = _Device(net, 'laptop', 22);
    await phone.vault.load();
    await phone.sync.start();
    await laptop.sync.start();
    await _settle(net, <_Device>[phone, laptop]);
    await laptop.vault.load();
    for (final _Device d in <_Device>[phone, laptop]) {
      final PasswordEntry e = d.vault.entries.single;
      expect(e.password, 'nowe');
      expect(e.history.single.password, 'stare');
      expect(e.conflict, isFalse);
      expect(e.keptOverDeletion, isFalse);
    }

    // An edit here is made from the old versions: no conflict.
    _t = 2000;
    await laptop.vault.edit('e000000001', _f('z-laptopa'));
    await _settle(net, <_Device>[phone, laptop]);
    final PasswordEntry edited = phone.vault.entry('e000000001')!;
    expect(edited.password, 'z-laptopa');
    expect(edited.conflict, isFalse);

    // A 1.16.5 device writes a version after it (no parents, its base the
    // newest it knew): read by time, as 1.16.5 meant it.
    final Map<String, Object?> state = (await phone.vault.syncState())!;
    final Map<String, Object?> versions = Map<String, Object?>.from(
      state['e']! as Map,
    );
    versions['k0000000010'] = <String, Object?>{
      'i': 'e000000001',
      'a': 3000,
      'c': 100,
      'pa': 2000,
      'n': 'Bank',
      'p': 'z-1-16-5',
    };
    await phone.vault.takeSyncState(<String, Object?>{...state, 'e': versions});
    PasswordEntry got = phone.vault.entry('e000000001')!;
    expect(got.password, 'z-1-16-5');
    expect(got.conflict, isFalse);
    // And one it wrote without having seen this build's edit: a conflict.
    versions['k0000000011'] = <String, Object?>{
      'i': 'e000000001',
      'a': 3500,
      'c': 100,
      'pa': 200,
      'n': 'Bank',
      'p': 'rownolegle',
    };
    await phone.vault.takeSyncState(<String, Object?>{...state, 'e': versions});
    got = phone.vault.entry('e000000001')!;
    expect(got.password, 'rownolegle');
    expect(got.conflict, isTrue);
    // What this build writes, 1.16.5 reads: the same keys it knows, `b`
    // and `h` beside them.
    final Map<String, Object?> written = _stored(phone.disk);
    for (final Object? v in (written['e']! as Map).values) {
      final Map<Object?, Object?> m = v! as Map<Object?, Object?>;
      expect(m['i'], isA<String>());
      expect(m['a'], isA<int>());
      if (m['d'] == null) {
        expect(m['pa'], isA<int>());
      }
    }
  });
}
