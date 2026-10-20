import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/encounters_section.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

const int _minute = 60 * 1000;
const int _day = 24 * 60 * _minute;

/// A Tuesday afternoon (local time).
final int _t0 = DateTime(2026, 10, 20, 15).millisecondsSinceEpoch;

String _stored(MemoryLedgerDisk disk) {
  final Uint8List? raw = disk.files[kEncountersKey];
  return raw == null ? '' : utf8.decode(raw);
}

final class _Radio implements NearbyRadio {
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  void see(Uint8List advert, String device) => _events.add(<Object?, Object?>{
    'type': 'seen',
    'token': advert,
    'rssi': -60,
    'device': device,
  });

  @override
  Future<Map<Object?, Object?>> state() async => <Object?, Object?>{
    'supported': true,
    'enabled': true,
    'permitted': true,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> requestEnable() async => true;

  @override
  Future<bool> startAdvertising(Uint8List token) async => true;

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<bool> startScan({bool lowPower = false}) async => true;

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> wave(String device, Uint8List data) async => false;
}

final class _Host implements MeetHost {
  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => const <String>['ania'];

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => a == 'ania';

  @override
  bool isSelf(String a) => a == 'bob';

  @override
  String nameOf(String a) => a == 'ania' ? 'Ania' : 'Ktoś';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('merging sightings', () {
    test('sightings close in time are one encounter', () {
      List<Encounter> list = <Encounter>[];
      for (final int m in <int>[0, 5, 10, 22]) {
        list = mergeEncounter(
          list,
          Encounter(
            friend: 'ania',
            start: _t0 + m * _minute,
            end: _t0 + m * _minute,
          ),
        );
      }
      expect(list, hasLength(1));
      expect(list.single.start, _t0);
      expect(list.single.end, _t0 + 22 * _minute);
    });

    test('a long gap or another friend makes a new one; a bridge joins', () {
      List<Encounter> list = <Encounter>[
        Encounter(friend: 'ania', start: _t0, end: _t0),
      ];
      list = mergeEncounter(
        list,
        Encounter(
          friend: 'ania',
          start: _t0 + 40 * _minute,
          end: _t0 + 40 * _minute,
        ),
      );
      list = mergeEncounter(
        list,
        Encounter(friend: 'ola', start: _t0 + _minute, end: _t0 + _minute),
      );
      expect(list, hasLength(3));
      expect(list.first.end, _t0 + 40 * _minute, reason: 'newest first');
      // Seen in between: the two encounters of Ania become one.
      list = mergeEncounter(
        list,
        Encounter(
          friend: 'ania',
          start: _t0 + 12 * _minute,
          end: _t0 + 28 * _minute,
        ),
      );
      final List<Encounter> ania = list
          .where((Encounter e) => e.friend == 'ania')
          .toList();
      expect(ania, hasLength(1));
      expect(ania.single.start, _t0);
      expect(ania.single.end, _t0 + 40 * _minute);
    });
  });

  group('the log', () {
    test(
      'records a friend with from–to and an approximate place only',
      () async {
        final MemoryLedgerDisk disk = MemoryLedgerDisk();
        int now = _t0;
        final EncounterLog log = EncounterLog(
          disk: disk,
          now: () => now,
          place: () async => EncounterPlace.approximate(52.2297123, 21.0122456),
        );
        addTearDown(log.dispose);
        await log.load();
        log
          ..saw(token: 'aa' * 16, at: now, friend: 'ania')
          ..saw(token: 'bb' * 16, at: now + 5 * _minute, friend: 'ania');
        expect(log.encounters, hasLength(1), reason: 'shown before written');
        await log.flush();
        now += 10 * _minute;

        final Encounter e = log.encounters.single;
        expect(e.friend, 'ania');
        expect(e.start, _t0);
        expect(e.end, _t0 + 5 * _minute);
        expect(e.place!.lat, 52.23);
        expect(e.place!.lon, 21.012);
        final String saved = _stored(disk);
        expect(saved, contains('ania'));
        expect(saved, isNot(contains('aa' * 16)), reason: 'no tokens kept');
        expect(saved, isNot(contains('52.2297')), reason: 'only approximate');

        // A new reader (the other engine, a restart) sees the same.
        final EncounterLog again = EncounterLog(disk: disk, now: () => now);
        addTearDown(again.dispose);
        await again.load();
        expect(again.encounters.single.end, _t0 + 5 * _minute);
      },
    );

    test('without a place (no location permission) there is none', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final EncounterLog log = EncounterLog(disk: disk, now: () => _t0);
      addTearDown(log.dispose);
      log.saw(token: 'aa' * 16, at: _t0, friend: 'ania');
      await log.flush();
      expect(log.encounters.single.place, isNull);
      expect(_stored(disk), isNot(contains('"la"')));
    });

    test('strangers are only a count per hour, never who', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final EncounterLog log = EncounterLog(disk: disk, now: () => _t0);
      addTearDown(log.dispose);
      final int slot = nearbySlot(_t0) * kNearbySlot.inMilliseconds;
      // Three phones in one slot, one of them seen again.
      for (final String token in <String>['01', '02', '03', '01']) {
        log.saw(token: token * 16, at: slot + _minute);
      }
      // The next slot: the same three people under new tokens, minus one.
      for (final String token in <String>['04', '05']) {
        log.saw(token: token * 16, at: slot + 11 * _minute);
      }
      await log.flush();

      expect(log.encounters, isEmpty);
      final EncounterCrowd crowd = log.crowds.single;
      expect(crowd.count, 3, reason: 'most at once, not every token');
      expect(crowd.windowStart, encounterWindowOf(slot + _minute));
      final String saved = _stored(disk);
      for (final String token in <String>['01', '02', '03', '04', '05']) {
        expect(saved, isNot(contains(token * 16)));
      }
    });

    test('nothing older than 30 days is kept', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final int old = _t0 - 31 * _day;
      final int recent = _t0 - 29 * _day;
      await disk.write(
        kEncountersKey,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'v': 1,
              'on': true,
              'e': <Map<String, dynamic>>[
                Encounter(friend: 'ania', start: recent, end: recent).toJson(),
                Encounter(friend: 'ola', start: old, end: old).toJson(),
              ],
              'c': <List<int>>[
                <int>[encounterWindowOf(old), 4],
                <int>[encounterWindowOf(recent), 2],
              ],
            }),
          ),
        ),
      );
      final EncounterLog log = EncounterLog(disk: disk, now: () => _t0);
      addTearDown(log.dispose);
      await log.load();
      expect(log.encounters.single.friend, 'ania');
      expect(log.crowds.single.count, 2);
      // Deleted from the phone, not only hidden.
      expect(_stored(disk), isNot(contains('ola')));
    });

    test('the off switch and "Wyczyść"', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      int now = _t0;
      final EncounterLog app = EncounterLog(disk: disk, now: () => now);
      final EncounterLog service = EncounterLog(disk: disk, now: () => now);
      addTearDown(app.dispose);
      addTearDown(service.dispose);
      await app.load();
      await service.load();

      // Both engines write; neither loses what the other wrote.
      app.saw(token: 'aa' * 16, at: now, friend: 'ania');
      service.saw(token: 'bb' * 16, at: now, friend: 'ola');
      await app.flush();
      await service.flush();
      await app.load();
      expect(app.encounters, hasLength(2));

      // Cleared in the app while the service still holds a sighting.
      service.saw(token: 'cc' * 16, at: now, friend: 'ola');
      now += _minute;
      await app.clear();
      await service.flush();
      await app.load();
      expect(app.isEmpty, isTrue, reason: 'nothing from before comes back');
      expect(_stored(disk), isNot(contains('ola')));

      await app.setRecording(false);
      expect(app.recording, isFalse);
      app.saw(token: 'dd' * 16, at: now, friend: 'ania');
      app.saw(token: 'ee' * 16, at: now);
      expect(app.isEmpty, isTrue);
      // The service learns it at its next write and drops what it heard.
      service.saw(token: 'ff' * 16, at: now, friend: 'ania');
      await service.flush();
      await app.load();
      expect(app.isEmpty, isTrue);
      expect(service.recording, isFalse);
    });
  });

  test('the radio feeds the log: friends by name, others counted', () async {
    final int clock = _t0;
    final String aniaKey = base64Url.encode(List<int>.filled(32, 7));
    final String strangerKey = base64Url.encode(List<int>.filled(32, 9));
    final NearbyOwnKeys ania = NearbyOwnKeys(aniaKey);
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await disk.write(
      MeetStore.key,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'v': 1,
            'fns': <String, String>{'ania': ania.materialFor('bob', clock)},
          }),
        ),
      ),
    );
    final MeetService meet = MeetService(
      host: _Host(),
      store: MeetStore(disk),
      now: () => clock,
    );
    await meet.reload();
    final _Radio radio = _Radio();
    final EncounterLog log = EncounterLog(disk: disk, now: () => clock);
    final NearbyService nearby = NearbyService(
      radio: radio,
      meet: meet,
      ownAddress: () => 'bob',
      sendMesh: (String to, Map<String, dynamic> payload) async {},
      frames: const Stream<SignalTransportFrame>.empty(),
      now: () => clock,
    )..encounters = log;
    addTearDown(() async {
      await nearby.close();
      log.dispose();
    });
    await nearby.startScanning(lowPower: true);

    final int slot = nearbySlot(clock);
    radio
      ..see(ania.advert(slot), 'AA:BB:CC:DD:EE:01')
      ..see(NearbyOwnKeys(strangerKey).advert(slot), 'AA:BB:CC:DD:EE:02');
    await _settle();
    await log.flush();

    expect(log.encounters.single.friend, 'ania');
    expect(log.crowds.single.count, 1);
    final String saved = _stored(disk);
    expect(saved, isNot(contains('AA:BB')), reason: 'no Bluetooth addresses');
    expect(saved, isNot(contains(nearbyHex(ania.token(slot)))));
  });

  test('days: today, yesterday, older', () {
    final DateTime now = DateTime(2026, 10, 20, 9);
    expect(
      encounterDayOf(DateTime(2026, 10, 20, 0, 5).millisecondsSinceEpoch, now),
      EncounterDay.today,
    );
    expect(
      encounterDayOf(DateTime(2026, 10, 19, 23).millisecondsSinceEpoch, now),
      EncounterDay.yesterday,
    );
    expect(
      encounterDayOf(DateTime(2026, 10, 18, 12).millisecondsSinceEpoch, now),
      EncounterDay.older,
    );
    expect(
      encounterSpan(
        DateTime(2026, 10, 18, 8, 5).millisecondsSinceEpoch,
        DateTime(2026, 10, 18, 8, 40).millisecondsSinceEpoch,
        withDate: true,
      ),
      '18.10, 08:05–08:40',
    );
  });

  testWidgets('"Mijani" lists friends and counts, asks before clearing', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final int now = DateTime(2026, 10, 20, 15, 30).millisecondsSinceEpoch;
    final EncounterLog log = EncounterLog(disk: disk, now: () => now);
    addTearDown(log.dispose);
    log
      ..saw(token: 'aa' * 16, at: now - 20 * _minute, friend: 'ania')
      ..saw(token: 'bb' * 16, at: now - 10 * _minute, friend: 'ania')
      ..saw(token: '01' * 16, at: now - 10 * _minute)
      ..saw(token: '02' * 16, at: now - 10 * _minute)
      ..saw(token: '03' * 16, at: now - 10 * _minute)
      ..saw(token: 'cc' * 16, at: now - _day, friend: 'ola');
    await log.flush();
    final List<String> met = <String>[];
    final List<String> opened = <String>[];

    tester.view.physicalSize = const Size(720, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              EncountersSection(
                log: log,
                now: () => DateTime.fromMillisecondsSinceEpoch(now),
                nameOf: (String f) => f == 'ania' ? 'Ania' : 'Ola',
                hasMet: (String f) => f == 'ola',
                onOpen: opened.add,
                onMet: met.add,
                onPlace: (EncounterPlace _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Dziś'), findsOneWidget);
    expect(find.text('Wczoraj'), findsOneWidget);
    expect(find.text('Ania'), findsOneWidget);
    expect(find.text('Ola'), findsOneWidget);
    expect(find.text('3 inne osoby z Zen'), findsOneWidget);
    expect(find.byKey(const Key('encounters-privacy')), findsOneWidget);

    await tester.tap(find.text('Spotkani?'));
    expect(met, <String>['ania']);
    await tester.tap(find.text('Ania'));
    expect(opened, <String>['ania']);

    await tester.tap(find.text('Wyczyść'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('encounters-clear-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Ania'), findsNothing);
    expect(find.byKey(const Key('encounters-empty')), findsOneWidget);
    expect(_stored(disk), isNot(contains('ania')));
  });
}
