// "Idę na randkę" across two phones whose clocks disagree: the watcher's
// reminder and alarm come when the dater's time is up, not when the
// watcher's clock says so; a word that waited in a mailbox still rings in
// time; a date nobody confirms leaves the watcher's phone, with its last
// place, a week after the alarm, and the watcher can end it by hand.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  final Map<String, Set<String>> friends = <String, Set<String>>{};

  /// The true time; each phone reads it with its own skew.
  int clock = 1000000000;

  void link(_Phone a, _Phone b) {
    (friends[a.address] ??= <String>{}).add(b.address);
    (friends[b.address] ??= <String>{}).add(a.address);
  }
}

final class _Phone implements EventHost {
  _Phone(this.net, this.name)
    : address = PeerShareCodec.normalizeAddress(
        '200::${(0xc0 + net.phones.length).toRadixString(16)}',
      ) {
    net.phones[address] = this;
    service = make();
  }

  final _Net net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late DatingService service;

  /// How far this phone's clock is ahead of the true time.
  int skew = 0;

  /// While set, words to this phone wait (as in a mailbox).
  bool away = false;
  final List<(String, Map<String, dynamic>)> waiting =
      <(String, Map<String, dynamic>)>[];
  final List<String> alarms = <String>[];
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  DatingService make() => DatingService(
    host: this,
    disk: disk,
    now: () => net.clock + skew,
    raiseAlarm: (String note) async => alarms.add(note),
  );

  Future<void> receive(String from, Map<String, dynamic> payload) async {
    if (away) {
      waiting.add((from, payload));
      return;
    }
    await service.handle(
      SignalTransportFrame(
        from: from,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  Future<void> comeBack() async {
    away = false;
    final List<(String, Map<String, dynamic>)> words = waiting.toList();
    waiting.clear();
    for (final (String from, Map<String, dynamic> p) in words) {
      await receive(from, p);
    }
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    await net.phones[to]?.receive(address, payload);
  }

  @override
  List<String> friends() => (net.friends[address] ?? const <String>{}).toList();

  @override
  bool isFriend(String a) => net.friends[address]?.contains(a) ?? false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net.phones[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  bool get rang => shown.any(
    (RuntimeSystemNotification n) =>
        n.category == RuntimeSystemNotificationCategory.alarm,
  );
}

const int _min = 60 * 1000;

Future<(_Net, _Phone, _Phone)> _pair({int watcherSkew = 0}) async {
  final _Net net = _Net();
  final _Phone ania = _Phone(net, 'ania');
  final _Phone bob = _Phone(net, 'bob')..skew = watcherSkew;
  net.link(ania, bob);
  await ania.service.load();
  await bob.service.load();
  return (net, ania, bob);
}

Future<void> _at(_Net net, int trueTime, List<_Phone> phones) async {
  net.clock = trueTime;
  for (final _Phone p in phones) {
    await p.service.tick();
  }
}

void main() {
  for (final int skew in <int>[20 * _min, -20 * _min]) {
    final String way = skew > 0 ? 'ahead' : 'behind';
    test('a watcher whose clock is 20 minutes $way is reminded when the '
        'dater is, and rings 15 minutes later, not before', () async {
      final (_Net net, _Phone ania, _Phone bob) = await _pair(
        watcherSkew: skew,
      );
      final int start = net.clock;
      await ania.service.startSafeDate(
        friend: bob.address,
        length: const Duration(hours: 1),
        lat: 52.2297,
        lon: 21.0122,
      );
      final int end = start + 60 * _min;

      await _at(net, end - _min, <_Phone>[ania, bob]);
      expect(ania.service.mySafeDate!.remindedAt, isNull);
      expect(bob.service.safeDates.single.remindedAt, isNull);
      expect(bob.rang, isFalse);

      await _at(net, end + _min, <_Phone>[ania, bob]);
      expect(ania.service.mySafeDate!.remindedAt, isNotNull);
      expect(bob.service.safeDates.single.remindedAt, isNotNull);
      expect(bob.service.safeDates.single.alarmedAt, isNull);

      await _at(net, end + 14 * _min, <_Phone>[ania, bob]);
      expect(bob.rang, isFalse, reason: 'the grace is not over');

      // The dater never confirms: the real overrun rings in time.
      await _at(net, end + 16 * _min, <_Phone>[ania, bob]);
      expect(bob.rang, isTrue);
      expect(ania.alarms, hasLength(1));
    });
  }

  test('an extension from the dater moves the watcher\'s deadline by the same '
      'time, whatever its clock says', () async {
    final (_Net net, _Phone ania, _Phone bob) = await _pair(
      watcherSkew: 25 * _min,
    );
    final int start = net.clock;
    await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 1),
    );
    await _at(net, start + 50 * _min, <_Phone>[ania, bob]);
    await ania.service.extendSafeDate(const Duration(hours: 1));
    await _at(net, start + 119 * _min, <_Phone>[ania, bob]);
    expect(bob.service.safeDates.single.remindedAt, isNull);
    await _at(net, start + 136 * _min, <_Phone>[ania, bob]);
    expect(bob.rang, isTrue);
  });

  test('a word that waited in a mailbox still rings in time: never later than '
      'the dater\'s deadline plus the margin', () async {
    // Twenty minutes in a mailbox, the clocks agree.
    final (_Net net, _Phone ania, _Phone bob) = await _pair();
    bob.away = true;
    final int start = net.clock;
    await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 1),
    );
    net.clock = start + 20 * _min;
    await bob.comeBack();
    final int end = start + 60 * _min;
    final int latest =
        end +
        SafeDate.grace.inMilliseconds +
        kDatingSafeClockMargin.inMilliseconds;
    await _at(net, latest + _min, <_Phone>[bob]);
    expect(bob.rang, isTrue);

    // Two hours in a mailbox for a one-hour date: the alarm comes at once.
    final (_Net net2, _Phone ania2, _Phone bob2) = await _pair();
    bob2.away = true;
    final int start2 = net2.clock;
    await ania2.service.startSafeDate(
      friend: bob2.address,
      length: const Duration(hours: 1),
    );
    net2.clock = start2 + 120 * _min;
    await bob2.comeBack();
    await _at(net2, net2.clock, <_Phone>[bob2]);
    expect(bob2.rang, isTrue);
  });

  test('a word from a phone that does not send the time left keeps that '
      'phone\'s deadline, as before', () async {
    final (_Net net, _Phone ania, _Phone bob) = await _pair();
    final int until = net.clock + 60 * _min;
    await bob.receive(ania.address, <String, dynamic>{
      'type': DatingTypes.safe,
      'id': 'old-date',
      'until': until,
      'note': '',
    });
    expect(bob.service.safeDates.single.until, until);
  });

  test('a date nobody confirms leaves the watcher\'s phone, with its last '
      'place, a week after the alarm', () async {
    final (_Net net, _Phone ania, _Phone bob) = await _pair(
      watcherSkew: 20 * _min,
    );
    final int start = net.clock;
    await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 1),
      lat: 52.2297,
      lon: 21.0122,
    );
    final int alarm = start + 75 * _min;
    await _at(net, alarm + _min, <_Phone>[bob]);
    expect(bob.rang, isTrue);

    // Ania's phone died: she never confirms.
    await _at(net, alarm + const Duration(days: 6).inMilliseconds, <_Phone>[
      bob,
    ]);
    expect(bob.service.safeDates.single.lat, 52.2297);

    await _at(net, alarm + SafeDate.kept.inMilliseconds + _min, <_Phone>[bob]);
    expect(bob.service.safeDates, isEmpty);
    final String stored = utf8.decode((await bob.disk.read('dating/state'))!);
    expect(stored.contains('52.2297'), isFalse, reason: 'the place is gone');

    // The dater's own phone, back after the week, drops it the same way.
    await _at(net, net.clock, <_Phone>[ania]);
    expect(ania.service.mySafeDate, isNull);
  });

  test('"Zakończ": the watcher ends a date after its deadline, the place '
      'goes at once, and later words do not bring it back', () async {
    final (_Net net, _Phone ania, _Phone bob) = await _pair();
    final int start = net.clock;
    await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 1),
      lat: 52.2297,
      lon: 21.0122,
    );
    final String id = bob.service.safeDates.single.id;
    await _at(net, start + 30 * _min, <_Phone>[bob]);
    expect(
      await bob.service.endWatching(id),
      isFalse,
      reason: 'the dater still counts on the watcher',
    );
    expect(bob.service.safeDates, hasLength(1));

    await _at(net, start + 80 * _min, <_Phone>[bob]);
    expect(bob.rang, isTrue);
    expect(await bob.service.endWatching(id), isTrue);
    expect(bob.service.safeDates, isEmpty);
    final String stored = utf8.decode((await bob.disk.read('dating/state'))!);
    expect(stored.contains('52.2297'), isFalse);

    final int notes = bob.shown.length;
    await ania.service.updateSafeLocation(50.06, 19.94);
    expect(bob.service.safeDates, isEmpty);
    expect(bob.shown, hasLength(notes));
    final String after = utf8.decode((await bob.disk.read('dating/state'))!);
    expect(after.contains('50.06'), isFalse);
  });
}
