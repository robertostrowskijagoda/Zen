import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The household and the dating profile in the circle copy: a recovered
/// resident is back in the household once a housemate confirms it (and
/// housemates see the new phone); a key the household changed meanwhile is
/// never undone.
void main() {
  test(
    'a recovered resident is back in the household on a new phone',
    () async {
      final Map<String, _Phone> net = <String, _Phone>{};
      final _Phone ania = _Phone(net, 'Ania');
      final _Phone ola = _Phone(net, 'Ola');
      await ania.service.createFlat('Nowakowie', place: 'm. 12');
      expect(await _join(ola, ania), isTrue);
      final Map<String, dynamic> copy =
          jsonDecode(jsonEncode(ola.service.backupState()))
              as Map<String, dynamic>;
      // No door key in the copy: one phone runs one door.
      expect(copy.containsKey('dk'), isFalse);

      // Ola's phone is lost; her account comes back on a new one.
      ola.online = false;
      final _Phone again = _Phone(net, 'Ola (nowy)');
      expect(await again.service.restoreFromBackup(copy), isTrue);
      expect(again.service.residentKey, ola.service.residentKey);
      await _settle();

      // Ania took the new phone as Ola's and sent the household's state.
      expect(again.service.restoredUnconfirmed, isFalse);
      expect(again.service.profile!.key, ania.service.profile!.key);
      expect(again.heardFrom, contains(ania.address));
      // Twice is nothing new.
      expect(await again.service.restoreFromBackup(copy), isFalse);
    },
  );

  test('a household that changed its key meanwhile is not undone', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'Ania');
    final _Phone ola = _Phone(net, 'Ola');
    final _Phone piotr = _Phone(net, 'Piotr');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    expect(await _join(ola, ania), isTrue);
    expect(await _join(piotr, ania), isTrue);
    final Map<String, dynamic> copy =
        jsonDecode(jsonEncode(ola.service.backupState()))
            as Map<String, dynamic>;
    final String oldKey = ania.service.profile!.key;

    // Piotr leaves: the household gets a new key.
    await piotr.service.leaveFlat();
    await _settle();
    final String newKey = ola.service.profile?.key ?? '';
    expect(newKey, isNot(oldKey));
    ola.online = false;

    final _Phone again = _Phone(net, 'Ola (nowy)');
    expect(await again.service.restoreFromBackup(copy), isTrue);
    await _settle();
    // Nobody answers under the old key: the household stays held back.
    expect(again.service.restoredUnconfirmed, isTrue);

    // Two weeks later the old key is dropped, not put back.
    again.clock += const Duration(days: 15).inMilliseconds;
    again.service = again.restarted();
    await again.service.load();
    expect(again.service.restoredUnconfirmed, isFalse);
    expect(again.service.hasFlat, isFalse);
  });

  test('the dating profile comes back without its photos', () {
    final MyDating mine = MyDating(
      enabled: true,
      name: 'Ola',
      about: 'Lubię góry',
      lookingFor: 'Kogoś do wędrówek',
      photos: <String>['zdjecie'],
      hiddenFriends: <String>['200::1'],
      hiddenGroups: <String>['g1'],
    );
    final Map<String, dynamic> copy =
        jsonDecode(jsonEncode(mine.toJson()..remove('ph')))
            as Map<String, dynamic>;
    final MyDating restored = MyDating(photos: <String>['nowe']);
    restoreDatingProfile(restored, MyDating.fromJson(copy));
    expect(restored.enabled, isTrue);
    expect(restored.name, 'Ola');
    expect(restored.about, 'Lubię góry');
    expect(restored.lookingFor, 'Kogoś do wędrówek');
    expect(restored.hiddenFriends, <String>['200::1']);
    expect(restored.hiddenGroups, <String>['g1']);
    expect(restored.photos, <String>['nowe']);
  });
}

String _addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

Future<void> _settle() async {
  for (int i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<bool> _join(_Phone newcomer, _Phone housemate) async {
  final FlatHomeCode code = housemate.service.inviteHousemate()!;
  if (!await newcomer.service.joinFlat(code)) {
    return false;
  }
  await _settle();
  final String? me = newcomer.service.residentKey;
  final FlatJoinRequest request = housemate.service.joinRequests.firstWhere(
    (FlatJoinRequest r) => r.resident == me,
  );
  if (!await housemate.service.approveJoin(request.id)) {
    return false;
  }
  await _settle();
  return true;
}

/// A phone on a small mesh, as in the neighbours' tests.
final class _Phone implements EventHost {
  _Phone(this.net, this.name)
    : address = _addr((0xa0 + net.length).toRadixString(16)) {
    net[address] = this;
    service = restarted();
  }

  final Map<String, _Phone> net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late NeighborsService service;
  int clock = 1000;
  bool online = true;
  final Set<String> heardFrom = <String>{};

  String? get inbox {
    final String? key = service.doorKey;
    return key != null ? _addr('d0:${key.substring(0, 4)}') : null;
  }

  NeighborsService restarted() => NeighborsService(
    host: this,
    disk: disk,
    now: () => clock,
    doorInbox: () => inbox,
    doorSend: doorSend,
    deviceName: () => 'Telefon testowy',
  );

  Future<void> _deliver(
    String from,
    String to,
    Map<String, dynamic> payload,
  ) async {
    _Phone? other = net[to];
    bool door = false;
    for (final _Phone p in net.values) {
      if (other == null && p.inbox == to) {
        other = p;
        door = true;
      }
    }
    if (other == null || !other.online) {
      return;
    }
    if (door && !kFlatDoorTypes.contains(payload['type'])) {
      return;
    }
    other.heardFrom.add(from);
    await other.service.handle(
      SignalTransportFrame(
        from: from,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
        door: door,
      ),
    );
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    if (online) {
      await _deliver(address, to, payload);
    }
  }

  Future<bool> doorSend(String to, Map<String, dynamic> payload) async {
    final String? from = inbox;
    if (!online || from == null) {
      return false;
    }
    await _deliver(from, to, payload);
    return true;
  }

  @override
  List<String> friends() => const <String>[];

  @override
  bool isFriend(String a) => false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}
}
