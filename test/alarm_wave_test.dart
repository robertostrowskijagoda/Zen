import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// A disk that can stop reading or writing (a locked or broken store).
final class _FlakyDisk implements LedgerDisk {
  final MemoryLedgerDisk inner = MemoryLedgerDisk();
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<Uint8List?> read(String key) async {
    if (failReads) {
      throw StateError('cannot read $key');
    }
    return inner.read(key);
  }

  @override
  Future<void> write(String key, Uint8List data) async {
    if (failWrites) {
      throw StateError('cannot write $key');
    }
    await inner.write(key, data);
  }

  @override
  Future<void> delete(String key) => inner.delete(key);
}

final class _Net {
  final Map<String, _Host> hosts = <String, _Host>{};
}

final class _Host implements MeetHost {
  _Host(
    this.net,
    this.address,
    this.friendList, {
    this.close = const <String>[],
    LedgerDisk? disk,
  }) {
    net.hosts[address] = this;
    service = MeetService(
      host: this,
      store: MeetStore(disk ?? MemoryLedgerDisk()),
      now: () => clock,
    );
  }

  final _Net net;
  final String address;
  final List<String> friendList;
  final List<String> close;
  late final MeetService service;
  int clock = 1000000;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<String> dismissed = <String>[];

  int get ringing =>
      shown.where((RuntimeSystemNotification n) => n.isRingingCall).length;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    await net.hosts[to]?.service.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => close;

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  bool isSelf(String a) => a == address;

  @override
  String nameOf(String a) => a.toUpperCase();

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  @override
  Future<void> dismissNotification(String slotKey) async =>
      dismissed.add(slotKey);
}

void main() {
  test(
    'only a fresh wave signed by a friend rings; a recorded token with a '
    'made-up signature, a changed wave or an unsigned one never does',
    () async {
      final _Net net = _Net();
      final _Host ania = _Host(net, 'ania', <String>['bob']);
      final _Host bob = _Host(net, 'bob', <String>['ania']);
      await ania.service.shareNearbySecret('bob');
      final String secret = ania.service.book.nearbySecret!;
      const AlarmRecord alarm = AlarmRecord(id: 'abc123', from: 'self', at: 1);

      // Someone who saw Ania's beacon knows her token, not her secret.
      final String token = nearbyHex(
        nearbyToken(secret, nearbyEpoch(ania.clock)),
      );
      await bob.service.onAlarmWave(
        <String, dynamic>{
          'v': kAlarmWaveVersion,
          'id': 'fake1',
          'at': bob.clock,
          't': token,
          'm': '0' * 32,
        },
        friend: 'ania',
        source: 'mac-evil',
      );
      expect(bob.service.book.alarms, isEmpty);
      expect(bob.ringing, 0);
      expect(bob.shown.single.title, startsWith('Niesprawdzone'));
      expect(
        bob.shown.single.category,
        isNot(RuntimeSystemNotificationCategory.alarm),
      );

      // Unsigned, with her token: the same (another phone, so it shows).
      await bob.service.onAlarmWave(
        <String, dynamic>{
          'v': kAlarmWaveVersion,
          'id': 'fake2',
          'at': bob.clock,
          't': token,
        },
        friend: 'ania',
        source: 'mac-evil-2',
      );
      expect(bob.service.book.alarms, isEmpty);
      expect(bob.ringing, 0);

      // A changed field breaks the signature. Bob has Ania's keys for him
      // alone (S6): her wave to him is signed for this pair.
      final Map<String, dynamic> wave = ania.service.alarmWave(
        alarm,
        to: 'bob',
      );
      expect(wave['v'], kAlarmPairWaveVersion);
      await bob.service.onAlarmWave(<String, dynamic>{
        ...wave,
        'id': 'abc124',
      }, friend: 'ania');
      expect(bob.service.book.alarm('abc124'), isNull);
      expect(bob.ringing, 0);

      // The real one rings, and only once.
      await bob.service.onAlarmWave(wave, friend: 'ania', source: 'mac-ania');
      expect(bob.service.book.alarm('abc123')!.nearby, isTrue);
      expect(bob.ringing, 1);
      await bob.service.onAlarmWave(wave, friend: 'ania', source: 'mac-ania');
      expect(bob.ringing, 1);

      // An old version is not read at all.
      await bob.service.onAlarmWave(<String, dynamic>{
        ...wave,
        'v': 4,
        'id': 'stara',
      }, friend: 'ania');
      expect(bob.service.book.alarm('stara'), isNull);
    },
  );

  test('a wave too old or from the future is dropped: a recording cannot be '
      'played back later', () async {
    final _Net net = _Net();
    final _Host ania = _Host(net, 'ania', <String>['bob']);
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    await ania.service.shareNearbySecret('bob');
    final Map<String, dynamic> wave = ania.service.alarmWave(
      const AlarmRecord(id: 'x1', from: 'self', at: 1),
      to: 'bob',
    );
    final int at = ania.clock;

    bob.clock = at + kAlarmWaveFreshFor.inMilliseconds + 1;
    await bob.service.onAlarmWave(wave, friend: 'ania');
    bob.clock = at - kAlarmWaveFreshFor.inMilliseconds - 1;
    await bob.service.onAlarmWave(wave, friend: 'ania');
    expect(bob.shown, isEmpty);
    expect(bob.service.book.alarms, isEmpty);

    bob.clock = at + 60 * 1000;
    await bob.service.onAlarmWave(wave, friend: 'ania');
    expect(bob.ringing, 1);
  });

  test('unchecked waves: a quiet note at most once per phone in 10 minutes '
      'and a few in all; it goes when the wave ends', () async {
    final _Net net = _Net();
    final _Host bob = _Host(net, 'bob', <String>[]);
    Map<String, dynamic> wave(String id, {bool ended = false}) =>
        AlarmWave.build(id: id, at: bob.clock, ended: ended);

    await bob.service.onAlarmWave(wave('a1'), source: 'mac-1');
    await bob.service.onAlarmWave(wave('a2'), source: 'mac-1');
    expect(bob.shown, hasLength(1), reason: 'the same phone');
    await bob.service.onAlarmWave(wave('a3'), source: 'mac-2');
    await bob.service.onAlarmWave(wave('a4'), source: 'mac-3');
    await bob.service.onAlarmWave(wave('a5'), source: 'mac-4');
    expect(bob.shown, hasLength(MeetService.maxUnverifiedWaves));
    expect(bob.ringing, 0);
    expect(
      bob.shown.every(
        (RuntimeSystemNotification n) =>
            n.slotKey == MeetService.unverifiedWaveSlot &&
            n.category != RuntimeSystemNotificationCategory.alarm,
      ),
      isTrue,
    );
    expect(bob.service.book.alarms, isEmpty);

    bob.clock += MeetService.unverifiedWaveEvery.inMilliseconds;
    await bob.service.onAlarmWave(wave('a6'), source: 'mac-1');
    expect(bob.shown, hasLength(MeetService.maxUnverifiedWaves + 1));

    await bob.service.onAlarmWave(wave('a6', ended: true), source: 'mac-1');
    expect(bob.dismissed, contains(MeetService.unverifiedWaveSlot));
  });

  test('a friend\'s alarm heard only over Bluetooth ends by itself after an '
      'hour; the network copy still rings', () async {
    final _Net net = _Net();
    final _Host ania = _Host(net, 'ania', <String>['bob']);
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    await ania.service.shareNearbySecret('bob');
    await bob.service.onAlarmWave(
      ania.service.alarmWave(
        const AlarmRecord(id: 'bt1', from: 'self', at: 1),
        to: 'bob',
      ),
      friend: 'ania',
    );
    expect(bob.service.book.alarm('bt1')!.isActive, isTrue);

    bob.clock += kNearbyAlarmLife.inMilliseconds - 1;
    await bob.service.expireNearbyAlarms();
    expect(bob.service.book.alarm('bt1')!.isActive, isTrue);
    bob.clock += 1;
    await bob.service.expireNearbyAlarms();
    final AlarmRecord expired = bob.service.book.alarm('bt1')!;
    expect(expired.isActive, isFalse);
    expect(expired.expiredNearby, isTrue);
    expect(bob.dismissed, contains(MeetService.alarmSlot('bt1')));

    // The network copy comes after all: a real alarm, ringing again.
    await ania.send('bob', <String, dynamic>{
      'type': MeetTypes.alarm,
      'id': 'bt1',
      'at': 1000,
    });
    final AlarmRecord real = bob.service.book.alarm('bt1')!;
    expect(real.isActive, isTrue);
    expect(real.nearby, isFalse);
    expect(bob.ringing, 2);
  });

  test('B10: an alarm goes out even when the store cannot be read or '
      'written, and is saved with the next change', () async {
    final _Net net = _Net();
    final _FlakyDisk disk = _FlakyDisk();
    final _Host ania = _Host(
      net,
      'ania',
      <String>['bob'],
      close: <String>['bob'],
      disk: disk,
    );
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    final List<Map<String, dynamic>> waves = <Map<String, dynamic>>[];
    ania.service.nearbyBroadcast = (Map<String, dynamic> wave) async {
      waves.add(wave);
      return 1;
    };
    await ania.service.setAlarmNearby(true);

    disk.failReads = true;
    final AlarmRecord alarm = await ania.service.raiseAlarm(note: 'pomocy');
    await ania.service.pendingNearbyWave;
    expect(bob.service.book.alarm(alarm.id)!.isActive, isTrue);
    expect(bob.ringing, 1);
    expect(waves.single['id'], alarm.id);
    expect(ania.service.book.ownActiveAlarm!.id, alarm.id);

    // The store works again: the next change saves the alarm too.
    disk.failReads = false;
    await ania.service.setAlarmRecordAudio(true);
    expect((await MeetStore(disk).load()).ownActiveAlarm!.id, alarm.id);

    // Ending it while nothing can be written: friends still hear it.
    disk.failWrites = true;
    expect(await ania.service.endAlarm(''), AlarmEndResult.ended);
    expect(ania.service.book.ownActiveAlarm, isNull);
    expect(bob.service.book.alarm(alarm.id)!.isActive, isFalse);
    disk.failWrites = false;
    await ania.service.setAlarmRecordAudio(false);
    expect((await MeetStore(disk).load()).alarm(alarm.id)!.isActive, isFalse);
  });

  test(
    'limits on what an alarm frame may carry and on stored alarms',
    () async {
      final AlarmRecord big = AlarmRecord.fromJson(<String, dynamic>{
        'id': 'x1',
        'from': 'ania',
        'at': 1,
        'resp': <String, String>{
          'a' * 500: 'coming',
          for (int i = 0; i < 5000; i++) 'f$i': 'coming',
        },
        'lat': 500.0,
        'lon': 21.0,
        'acc': -3,
      })!;
      expect(big.responses.length, lessThanOrEqualTo(AlarmRecord.maxResponses));
      expect(
        big.responses.keys.every(
          (String k) => k.length <= AlarmRecord.maxResponseKey,
        ),
        isTrue,
      );
      expect(big.hasLocation, isFalse, reason: 'no such latitude');
      expect(big.accuracy, isNull);
      for (final String id in <String>['x' * 41, 'zły id', '']) {
        expect(
          AlarmRecord.fromJson(<String, dynamic>{
            'id': id,
            'from': 'a',
            'at': 1,
          }),
          isNull,
        );
      }

      // Over the network: a friend's copy with too many answers is cut.
      final _Net net = _Net();
      final _Host ania = _Host(net, 'ania', <String>['bob']);
      final _Host bob = _Host(net, 'bob', <String>['ania']);
      await ania.send('bob', <String, dynamic>{
        'type': MeetTypes.alarm,
        'id': 'duzy',
        'at': 1,
        'resp': <String, String>{
          for (int i = 0; i < 3000; i++) 'f$i': 'coming',
        },
      });
      expect(
        bob.service.book.alarm('duzy')!.responses.length,
        lessThanOrEqualTo(AlarmRecord.maxResponses),
      );

      // Even when every alarm still goes on, the list has an end; this
      // person's own alarm is always kept.
      final MeetBook book = MeetBook();
      for (int i = 0; i < MeetBook.maxAlarmsHard; i++) {
        expect(
          book.putAlarm(AlarmRecord(id: 'a$i', from: 'f$i', at: 1)),
          isTrue,
        );
      }
      expect(
        book.putAlarm(const AlarmRecord(id: 'za-duzo', from: 'g', at: 1)),
        isFalse,
      );
      expect(
        book.putAlarm(const AlarmRecord(id: 'moj', from: 'self', at: 1)),
        isTrue,
      );
    },
  );

  test('the wave codec: signed with the secret, checked against it', () {
    final String secret = base64Url.encode(List<int>.filled(32, 7));
    final Map<String, dynamic> wave = AlarmWave.build(
      id: 'abc',
      at: 5000,
      ended: true,
      secret: secret,
    );
    final AlarmWave parsed = AlarmWave.parse(
      jsonDecode(jsonEncode(wave)) as Map<String, dynamic>,
    )!;
    expect(parsed.ended, isTrue);
    expect(parsed.signed, isTrue);
    expect(parsed.verify(secret), isTrue);
    expect(parsed.verify(base64Url.encode(List<int>.filled(32, 8))), isFalse);
    expect(parsed.verify('to nie jest klucz'), isFalse);
    expect(parsed.isFreshAt(5000 + kAlarmWaveFreshFor.inMilliseconds), isTrue);
    expect(
      parsed.isFreshAt(5000 + kAlarmWaveFreshFor.inMilliseconds + 1),
      isFalse,
    );
    // A damaged secret: unsigned, never a crash.
    expect(
      AlarmWave.build(id: 'abc', at: 1, ended: false, secret: '%%%'),
      isNot(contains('m')),
    );
    // Junk is not a wave.
    expect(
      AlarmWave.parse(<String, dynamic>{
        'v': kAlarmWaveVersion,
        'id': 'abc',
        'at': 1,
        'm': 'xyz',
      }),
      isNull,
    );
  });
}
