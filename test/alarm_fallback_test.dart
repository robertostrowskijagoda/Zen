import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/alarm_sms.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/presentation/alarm_screen.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final String _ania = PeerShareCodec.normalizeAddress('200::a1');

final class _Host implements MeetHost {
  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => <String>[_ania];

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => PeerShareCodec.addressesEqual(a, _ania);

  @override
  bool isSelf(String a) => false;

  @override
  String nameOf(String a) => 'Ania';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

/// A scripted location service that remembers what it was asked.
final class _Source implements GeoSource {
  _Source({
    this.permission = LocationPermission.always,
    this.enabled = true,
    this.fresh,
    this.last,
    this.underServiceFails = false,
  });

  LocationPermission permission;
  final bool enabled;
  final GeoFix? fresh;
  final GeoFix? last;
  final bool underServiceFails;
  final List<String> calls = <String>[];

  @override
  Future<LocationPermission> checkPermission() async {
    calls.add('check');
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    calls.add('request');
    return permission = LocationPermission.whileInUse;
  }

  @override
  Future<bool> serviceEnabled() async => enabled;

  @override
  Future<GeoFix> current(Duration timeout) async {
    calls.add('current');
    return fresh!;
  }

  @override
  Future<GeoFix> currentUnderService(Duration timeout) async {
    calls.add('service');
    if (underServiceFails) {
      throw StateError('no foreground service');
    }
    return fresh!;
  }

  @override
  Future<GeoFix?> lastKnown() async {
    calls.add('last');
    return last;
  }
}

void main() {
  final GeoSource realSource = geoSource;
  tearDown(() => geoSource = realSource);

  group('fresh position for an alarm raised in the background', () {
    test('with the permission it is read under the location service', () async {
      final _Source s = _Source(fresh: const GeoFix(54.35, 18.65, 7));
      geoSource = s;
      final GeoFix? fix = await currentFixInBackground();
      expect(fix!.lat, 54.35);
      expect(s.calls, <String>['check', 'service']);
    });

    test(
      'without the permission there is nothing, and nobody is asked',
      () async {
        for (final LocationPermission p in <LocationPermission>[
          LocationPermission.denied,
          LocationPermission.deniedForever,
          LocationPermission.unableToDetermine,
        ]) {
          final _Source s = _Source(
            permission: p,
            fresh: const GeoFix(1, 2, 3),
            last: const GeoFix(4, 5, 6),
          );
          geoSource = s;
          expect(await currentFixInBackground(), isNull);
          expect(s.calls, <String>['check'], reason: 'no prompt in background');
        }
      },
    );

    test('when the service fails or location is off, the last known one '
        'is used', () async {
      final _Source failing = _Source(
        fresh: const GeoFix(1, 2, 3),
        last: const GeoFix(4, 5, 6),
        underServiceFails: true,
      );
      geoSource = failing;
      expect((await currentFixInBackground())!.lat, 4);

      final _Source off = _Source(enabled: false, last: const GeoFix(7, 8, 9));
      geoSource = off;
      expect((await currentFixInBackground())!.lon, 8);
      expect(off.calls, isNot(contains('service')));

      geoSource = _Source(underServiceFails: true);
      expect(await currentFixInBackground(), isNull);
    });

    test('the foreground fix still asks, and can be told not to', () async {
      final _Source asks = _Source(
        permission: LocationPermission.denied,
        fresh: const GeoFix(1, 2, 3),
      );
      geoSource = asks;
      expect((await currentFix())!.accuracy, 3);
      expect(asks.calls, <String>['check', 'request', 'current']);

      final _Source quiet = _Source(
        permission: LocationPermission.denied,
        fresh: const GeoFix(1, 2, 3),
      );
      geoSource = quiet;
      expect(await currentFix(ask: false), isNull);
      expect(quiet.calls, <String>['check']);
    });
  });

  group('backup SMS', () {
    test('numbers are cleaned, checked and limited', () {
      expect(normalizeSmsNumber(' +48 600-123-456 '), '+48600123456');
      expect(normalizeSmsNumber('(58) 301 23 45'), '583012345');
      expect(normalizeSmsNumber('12'), isNull);
      expect(normalizeSmsNumber('abc'), isNull);
      expect(normalizeSmsNumber('1234567890123456'), isNull);
      expect(
        parseSmsNumbers('600 100 200, 600100200\n+48 700 800 900;zzz\n'),
        <String>['600100200', '+48700800900'],
      );
      expect(
        parseSmsNumbers(
          List<String>.generate(9, (int i) => '60010020$i').join('\n'),
        ),
        hasLength(kAlarmSmsMaxNumbers),
      );
    });

    test('the text says who, what, where and that 112 is the call', () {
      final AlarmRecord at = AlarmRecord(
        id: 'x',
        from: 'self',
        at: 1,
        lat: 54.352,
        lon: 18.6466,
        note: 'Ktoś za mną idzie',
      );
      final String text = alarmSmsBody(name: 'Kasia', alarm: at);
      expect(text, contains('Kasia potrzebuje pomocy'));
      expect(text, contains('„Ktoś za mną idzie”'));
      expect(text, contains('openstreetmap.org'));
      expect(text, contains('54.352000'));
      expect(text, contains('112'));
      final String blind = alarmSmsBody(
        name: ' ',
        alarm: const AlarmRecord(id: 'y', from: 'self', at: 1),
      );
      expect(blind, contains('Położenia brak.'));
      expect(blind, startsWith('ALARM (Zen): Ktoś'));
    });

    test('numbers are kept in the book and survive JSON', () async {
      final MeetService meet = MeetService(
        host: _Host(),
        store: MeetStore(MemoryLedgerDisk()),
      );
      await meet.setAlarmSmsNumbers(<String>['600 100 200', 'x', '600100200']);
      expect(meet.book.alarmSmsNumbers, <String>['600100200']);
      final MeetBook back = MeetBook.fromJson(meet.book.toJson());
      expect(back.alarmSmsNumbers, <String>['600100200']);
      // An older book has none.
      expect(MeetBook.fromJson(MeetBook().toJson()).alarmSmsNumbers, isEmpty);
    });

    testWidgets('numbers are set on the arming screen; a running alarm '
        'offers the SMS', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(480, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _Host host = _Host();
      final MeetService meet = MeetService(
        host: host,
        store: MeetStore(MemoryLedgerDisk()),
      );
      await tester.runAsync(() async {
        await meet.setAlarmPin('1234', '4321');
        await meet.setAlarmSmsNumbers(<String>[
          '600 100 200',
          '+48 700 800 900',
        ]);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meetServiceProvider.overrideWithValue(meet),
            eventServiceProvider.overrideWithValue(
              EventService(
                host: MeetEventHost(host, address: () => '', name: () => 'Ja'),
                disk: MemoryLedgerDisk(),
              ),
            ),
          ],
          child: MaterialApp(theme: ZenTheme.dark(), home: const AlarmScreen()),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('alarm-sms-send')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('alarm-sms-setup')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('alarm-sms-setup')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The dialog shows the saved numbers (saving goes through the
      // store, covered above; its futures live outside the fake zone).
      expect(find.text('600100200\n+48700800900'), findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // A running alarm: the SMS button is there (the SMS app opens on a
      // phone; here nothing can, and it says so).
      await tester.runAsync(() => meet.raiseAlarm(note: 'pomocy'));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('alarm-sms-send')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('alarm-sms-send')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.text('Nie udało się otworzyć SMS-ów.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
