import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/meet/locked_nearby.dart';
import 'package:zen/src/features/meet/locked_reminders.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_look_policy.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// A radio that does nothing (no Bluetooth needed for reminders).
final class _Radio implements NearbyRadio {
  @override
  Stream<Map<Object?, Object?>> get events =>
      const Stream<Map<Object?, Object?>>.empty();

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
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async => true;

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<bool> startScan({bool lowPower = false}) async => true;

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> wave(String device, Uint8List data) async => true;
}

void main() {
  test('how often and how long: offered choices only, remembered, 5 min and '
      '8 s by default', () {
    final MeetBook book = MeetBook();
    expect(book.nearbyLookMinutes, 5);
    expect(book.nearbyLookSeconds, 8);
    book
      ..nearbyLookMinutes = 30
      ..nearbyLookSeconds = 15;
    final MeetBook back = MeetBook.fromJson(
      jsonDecode(jsonEncode(book.toJson())),
    );
    expect(back.nearbyLookMinutes, 30);
    expect(back.nearbyLookSeconds, 15);
    final MeetBook odd = MeetBook.fromJson(<String, dynamic>{
      'v': 1,
      'lkm': 1,
      'lks': 600,
    });
    expect(odd.nearbyLookMinutes, 5);
    expect(odd.nearbyLookSeconds, 8);
    expect(kNearbyLookEveryChoices, <int>[2, 5, 10, 15, 30]);
  });

  test('the battery estimate falls as the looks get rarer and shorter', () {
    double cost(int m, int s) => nearbyLookMilliampHoursPerDay(
      every: Duration(minutes: m),
      window: Duration(seconds: s),
    );
    for (int i = 1; i < kNearbyLookEveryChoices.length; i++) {
      expect(
        cost(kNearbyLookEveryChoices[i], 8),
        lessThan(cost(kNearbyLookEveryChoices[i - 1], 8)),
      );
    }
    expect(cost(5, 4), lessThan(cost(5, 15)));
    // Honest numbers: the most often and longest costs a few per cent of a
    // battery a day (the phone is woken 720 times), the rarest a fraction.
    expect(
      nearbyLookBatteryPercentPerDay(
        every: const Duration(minutes: 2),
        window: const Duration(seconds: 15),
      ),
      inInclusiveRange(3, 10),
    );
    expect(
      nearbyLookBatteryPercentPerDay(
        every: const Duration(minutes: 30),
        window: const Duration(seconds: 4),
      ),
      lessThan(0.5),
    );
  });

  test('the kit carries the choice and the reminders; the locked service '
      'looks as chosen and shows each reminder once, on time', () async {
    int clock = DateTime(2026, 9, 30, 18).millisecondsSinceEpoch;
    final int remindAt = DateTime(2026, 9, 30, 19).millisecondsSinceEpoch;
    final int howAt = DateTime(2026, 10, 1, 22).millisecondsSinceEpoch;
    final NearbyKit kit = NearbyKit.fromJson(
      jsonDecode(
        jsonEncode(
          NearbyKit(
            createdAt: clock,
            self: 'bob',
            look: true,
            lookMinutes: 10,
            lookSeconds: 4,
            reminders: <LockedReminder>[
              LockedReminder(
                id: 'circle-remind-x-2026-10-01',
                at: remindAt,
                title: 'Jutro obiad: Czwartki',
                body: 'O 19:00 gotuje a1.',
                slot: 'circle:x',
              ),
              LockedReminder(
                id: 'circle-how-x-2026-10-01',
                at: howAt,
                title: 'Jak było? Czwartki',
                body: '…',
                slot: 'circle:x',
              ),
            ],
          ).toJson(),
        ),
      ),
    )!;
    expect(kit.lookMinutes, 10);
    expect(kit.reminders, hasLength(2));
    final MemoryRuntimeSystemNotificationService notices =
        MemoryRuntimeSystemNotificationService();
    final LockedNearby locked = LockedNearby(
      kit: kit,
      radio: _Radio(),
      keep: (SignalTransportFrame _) async => true,
      notices: notices,
      now: () => clock,
    );
    expect(locked.lookEvery, const Duration(minutes: 10));
    expect(locked.lookFor, const Duration(seconds: 4));
    await locked.start();
    expect(notices.activeNotifications, isEmpty, reason: 'not yet');
    clock = remindAt + 60 * 1000;
    expect(await locked.remindIfDue(), 1);
    expect(notices.activeNotifications.single.title, contains('Jutro obiad'));
    expect(await locked.remindIfDue(), 0, reason: 'once');
    // Too late (the phone slept for hours): not any more.
    clock = howAt + kLockedReminderLate.inMilliseconds + 1;
    expect(await locked.remindIfDue(), 0);
    await locked.stop();
  });
}
