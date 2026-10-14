import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

final class _Net {
  final Map<String, _Host> hosts = <String, _Host>{};
}

final class _Host implements MeetHost {
  _Host(
    this.net,
    this.address,
    this.friendList, {
    this.close = const <String>[],
  }) {
    net.hosts[address] = this;
    service = MeetService(
      host: this,
      store: MeetStore(MemoryLedgerDisk()),
      now: () => clock,
    );
  }

  final _Net net;
  final String address;
  final List<String> friendList;
  final List<String> close;
  late final MeetService service;
  int clock = 1000;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<String> dismissed = <String>[];
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add((to, payload));
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
    'statuses reach friends, "przyjaciele only" reaches only them',
    () async {
      final _Net net = _Net();
      final _Host ania = _Host(
        net,
        'ania',
        <String>['bob', 'cyryl'],
        close: <String>['bob'],
      );
      final _Host bob = _Host(net, 'bob', <String>['ania']);
      final _Host cyryl = _Host(net, 'cyryl', <String>['ania']);

      await ania.service.setMyIntent(
        const IntentStatus(kind: IntentKind.talk, setAt: 1000, until: 5000),
      );
      expect(bob.service.friendsWith(IntentKind.talk).single.$1, 'ania');
      expect(cyryl.service.friendsWith(IntentKind.talk).single.$1, 'ania');

      await ania.service.setMyIntent(
        const IntentStatus(
          kind: IntentKind.out,
          setAt: 2000,
          note: 'piwo o 20',
          onlyClose: true,
        ),
      );
      expect(
        bob.service.friendsWith(IntentKind.out).single.$2.note,
        'piwo o 20',
      );
      expect(cyryl.service.friendsWith(IntentKind.out), isEmpty);
      expect(
        cyryl.service.friendsWith(IntentKind.talk),
        isEmpty,
        reason: 'the old one was replaced',
      );

      // It goes out by itself.
      await ania.service.setMyIntent(
        const IntentStatus(kind: IntentKind.talk, setAt: 3000, until: 4000),
      );
      bob.clock = 4001;
      expect(bob.service.friendsWith(IntentKind.talk), isEmpty);

      // Asking for help raises a notification once.
      await ania.service.setMyIntent(
        const IntentStatus(kind: IntentKind.help, setAt: 5000, note: 'pralka'),
      );
      expect(bob.shown.last.title, 'ANIA potrzebuje pomocy');
      expect(bob.shown.last.body, 'pralka');

      // Strangers' statuses are ignored.
      final _Host eve = _Host(net, 'eve', <String>['bob']);
      await eve.send('bob', <String, dynamic>{
        'type': MeetTypes.intent,
        's': const IntentStatus(kind: IntentKind.talk, setAt: 1).toJson(),
      });
      expect(bob.service.book.friendIntents.containsKey('eve'), isFalse);
    },
  );

  test('an alarm rings at the closest friends, answers come back, the panic '
      'PIN warns them, a typo changes nothing', () async {
    final _Net net = _Net();
    final _Host ania = _Host(
      net,
      'ania',
      <String>['bob', 'cyryl', 'dora'],
      close: <String>['bob', 'cyryl'],
    );
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    final _Host cyryl = _Host(net, 'cyryl', <String>['ania']);
    final _Host dora = _Host(net, 'dora', <String>['ania']);

    expect(await ania.service.setAlarmPin('2468', '2468'), isFalse);
    expect(ania.service.hasAlarmPin, isFalse);
    expect(await ania.service.setAlarmPin('2468', '9753'), isTrue);
    expect(ania.service.checkAlarmPin('2468'), AlarmPinKind.normal);
    expect(ania.service.checkAlarmPin('9753'), AlarmPinKind.panic);
    expect(ania.service.checkAlarmPin('1111'), AlarmPinKind.wrong);

    final AlarmRecord alarm = await ania.service.raiseAlarm(note: 'pomocy');
    expect(bob.shown.single.category, RuntimeSystemNotificationCategory.alarm);
    expect(bob.shown.single.isRingingCall, isTrue);
    expect(cyryl.service.book.activeAlarmsFromFriends().single.note, 'pomocy');
    expect(dora.shown, isEmpty, reason: 'only "przyjaciele" get it');

    await ania.service.updateAlarmLocation(52.23, 21.01, accuracy: 15);
    expect(bob.service.book.alarm(alarm.id)!.lat, 52.23);

    await bob.service.respond(alarm.id, AlarmResponse.coming);
    expect(
      ania.service.book.ownActiveAlarm!.responses['bob'],
      AlarmResponse.coming,
    );
    expect(bob.dismissed, contains(MeetService.alarmSlot(alarm.id)));
    // Cyryl sees that Bob is coming (relayed by Ania), Bob keeps his own.
    expect(
      cyryl.service.book.alarm(alarm.id)!.responses['bob'],
      AlarmResponse.coming,
    );
    expect(
      bob.service.book.alarm(alarm.id)!.responses['self'],
      AlarmResponse.coming,
    );
    expect(
      bob.service.book.alarm(alarm.id)!.responses.containsKey('bob'),
      isFalse,
    );

    // A typo: nothing ends, nobody is warned.
    final int before = cyryl.shown.length;
    expect(await ania.service.endAlarm('2469'), AlarmEndResult.wrongPin);
    expect(ania.service.book.ownActiveAlarm, isNotNull);
    expect(cyryl.service.book.alarm(alarm.id)!.isActive, isTrue);
    expect(cyryl.shown.length, before);

    // A forced "I'm safe": looks normal here, friends are warned.
    expect(await ania.service.endAlarm('9753'), AlarmEndResult.ended);
    expect(ania.service.book.ownActiveAlarm, isNull);
    final AlarmRecord seen = cyryl.service.book.alarm(alarm.id)!;
    expect(seen.isActive, isFalse);
    expect(seen.duress, isTrue);
    expect(cyryl.shown.last.title, contains('PIN-em panicznym'));
    expect(cyryl.shown.last.category, RuntimeSystemNotificationCategory.alarm);

    // A real one.
    final AlarmRecord second = await ania.service.raiseAlarm();
    await ania.service.endAlarm('2468');
    expect(bob.service.book.alarm(second.id)!.duress, isFalse);
    expect(bob.shown.last.title, 'ANIA jest bezpieczny(-a)');
  });

  test('without "przyjaciele" an alarm goes to every friend', () async {
    final _Net net = _Net();
    final _Host ania = _Host(net, 'ania', <String>['bob', 'cyryl']);
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    _Host(net, 'cyryl', <String>['ania']);
    await ania.service.raiseAlarm();
    expect(ania.service.alarmRecipients(), <String>['bob', 'cyryl']);
    expect(bob.shown.single.title, startsWith('🚨'));
  });

  test('nearby secrets are shared, and renewed when a friend leaves', () async {
    final _Net net = _Net();
    final _Host ania = _Host(net, 'ania', <String>['bob']);
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    await ania.service.shareNearbySecret('bob');
    final String first = ania.service.book.nearbySecret!;
    expect(bob.service.book.friendNearbySecrets['ania'], first);
    expect(ania.service.book.nearbyGivenTo, contains('bob'));
    await ania.service.rotateNearbySecret();
    expect(ania.service.book.nearbySecret, isNot(first));
    expect(
      bob.service.book.friendNearbySecrets['ania'],
      ania.service.book.nearbySecret,
    );

    await ania.service.markMet('bob');
    expect(ania.service.book.metAt('bob'), 1000);

    // The book survives a round trip.
    final MeetBook again = MeetBook.fromJson(
      jsonDecode(jsonEncode(ania.service.book.toJson())),
    );
    expect(again.nearbySecret, ania.service.book.nearbySecret);
    expect(again.metAt('bob'), 1000);
  });

  test('sound recorded during an alarm goes to the friends who got it and '
      'stays with the alarm', () async {
    final _Net net = _Net();
    final _Host ania = _Host(
      net,
      'ania',
      <String>['bob', 'cyryl'],
      close: <String>['bob'],
    );
    final _Host bob = _Host(net, 'bob', <String>['ania', 'cyryl']);
    final _Host cyryl = _Host(net, 'cyryl', <String>['ania', 'bob']);
    final Uint8List sound = Uint8List.fromList(
      List<int>.generate(1000, (int i) => i % 256),
    );

    expect(await ania.service.addAlarmAudio(sound), isNull, reason: 'no alarm');
    final AlarmRecord alarm = await ania.service.raiseAlarm(note: 'pomocy');
    final AlarmClip clip = (await ania.service.addAlarmAudio(
      sound,
      durationMs: 20000,
    ))!;
    expect(clip.n, 0);
    expect(ania.service.book.ownActiveAlarm!.clips.single.ms, 20000);
    expect(await ania.service.alarmAudio(alarm.id, 0), sound);

    final AlarmRecord got = bob.service.book.alarm(alarm.id)!;
    expect(got.clips.single.ms, 20000);
    expect(await bob.service.alarmAudio(alarm.id, 0), sound);
    expect(bob.shown.last.title, contains('Nagranie z alarmu'));
    expect(
      cyryl.service.book.alarm(alarm.id),
      isNull,
      reason: 'only those who got the alarm',
    );

    // The next copy of the alarm (a new position) keeps the sound.
    await ania.service.updateAlarmLocation(52.23, 21.01);
    expect(bob.service.book.alarm(alarm.id)!.clips, hasLength(1));
    expect(bob.service.book.alarm(alarm.id)!.hasLocation, isTrue);

    // Too big; and nobody but the one in danger adds sound to it.
    expect(
      await ania.service.addAlarmAudio(Uint8List(kAlarmClipMaxBytes + 1)),
      isNull,
    );
    await cyryl.send('bob', <String, dynamic>{
      'type': MeetTypes.alarmAudio,
      'id': alarm.id,
      'n': 1,
      'at': 1,
      'd': base64Encode(<int>[1, 2, 3]),
    });
    expect(bob.service.book.alarm(alarm.id)!.clips, hasLength(1));
    expect(await bob.service.alarmAudio(alarm.id, 1), isNull);

    // The second piece.
    await ania.service.addAlarmAudio(Uint8List.fromList(<int>[9, 9]));
    expect(
      bob.service.book.alarm(alarm.id)!.clips.map((AlarmClip c) => c.n),
      <int>[0, 1],
    );

    // Not after it ended.
    await ania.service.endAlarm('');
    expect(await ania.service.addAlarmAudio(sound), isNull);

    // The book keeps the clips across a round trip.
    final MeetBook again = MeetBook.fromJson(
      jsonDecode(jsonEncode(bob.service.book.toJson())),
    );
    expect(again.alarm(alarm.id)!.clips, hasLength(2));
  });

  test('an alarm over Bluetooth: friends nearby get it ringing, strangers '
      'only a quiet unchecked note', () async {
    final _Net net = _Net();
    final _Host ania = _Host(
      net,
      'ania',
      <String>['bob', 'kasia'],
      close: <String>['bob'],
    );
    _Host(net, 'bob', <String>['ania']);
    final _Host kasia = _Host(net, 'kasia', <String>['ania']);
    final _Host dan = _Host(net, 'dan', <String>[]);
    final List<Map<String, dynamic>> waves = <Map<String, dynamic>>[];
    ania.service.nearbyBroadcast = (Map<String, dynamic> wave) async {
      waves.add(jsonDecode(jsonEncode(wave)) as Map<String, dynamic>);
      return 1;
    };

    // Off by default.
    final AlarmRecord quiet = await ania.service.raiseAlarm();
    expect(waves, isEmpty);
    await ania.service.endAlarm('');
    expect(waves, isEmpty);
    expect(ania.service.book.alarmNearby, isFalse);

    await ania.service.setAlarmNearby(true);
    // Kasia has Ania's nearby secret: she can check Ania's waves.
    await ania.service.shareNearbySecret('kasia');
    final AlarmRecord alarm = await ania.service.raiseAlarm();
    await ania.service.pendingNearbyWave;
    expect(alarm.id, isNot(quiet.id));
    final Map<String, dynamic> wave = waves.single;
    expect(wave['v'], kAlarmWaveVersion);
    expect(wave['id'], alarm.id);
    expect(wave['at'], ania.clock);
    expect(wave['m'], hasLength(32));
    expect(wave.containsKey('end'), isFalse);
    expect(utf8.encode(jsonEncode(wave)).length, lessThan(200));

    // Kasia is a friend but not "przyjaciel": she hears it nearby, and it
    // rings like one from the network.
    expect(kasia.service.book.alarm(alarm.id), isNull);
    await kasia.service.onAlarmWave(wave, friend: 'ania');
    final AlarmRecord heard = kasia.service.book.alarm(alarm.id)!;
    expect(heard.from, 'ania');
    expect(heard.nearby, isTrue);
    expect(heard.isActive, isTrue);
    expect(kasia.shown.single.isRingingCall, isTrue);
    expect(kasia.shown.single.title, contains('ANIA'));
    // Heard twice: rings once.
    await kasia.service.onAlarmWave(wave, friend: 'ania');
    expect(kasia.shown, hasLength(1));

    // Someone who does not know her: no name, no ringing, clearly marked
    // as unchecked.
    await dan.service.onAlarmWave(wave, friend: 'ania');
    expect(dan.service.book.alarms, isEmpty);
    expect(dan.shown.single.title, startsWith('Niesprawdzone'));
    expect(dan.shown.single.isRingingCall, isFalse);
    expect(
      dan.shown.single.category,
      isNot(RuntimeSystemNotificationCategory.alarm),
    );
    await dan.service.onAlarmWave(<String, dynamic>{'v': 1, 'id': 'x'});
    expect(dan.shown, hasLength(1));

    // It ends: the stranger's note goes away; a friend's alarm ends only
    // through the network (Bluetooth cannot tell "safe" from "forced").
    await ania.service.endAlarm('');
    await ania.service.pendingNearbyWave;
    final Map<String, dynamic> end = waves.last;
    expect(end['end'], isTrue);
    await dan.service.onAlarmWave(end);
    expect(dan.dismissed, contains(MeetService.unverifiedWaveSlot));
    await kasia.service.onAlarmWave(end, friend: 'ania');
    expect(kasia.service.book.alarm(alarm.id)!.isActive, isTrue);
  });

  test('a flood of alarms from one friend rings only a few times and never '
      "pushes out this person's own alarm or alarms still going on", () async {
    final _Net net = _Net();
    final _Host ania = _Host(net, 'ania', <String>['bob', 'eve']);
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    final _Host eve = _Host(net, 'eve', <String>['ania']);
    final AlarmRecord own = await ania.service.raiseAlarm(note: 'pomocy');
    final AlarmRecord bobs = await bob.service.raiseAlarm();
    final int rang = ania.shown.length;

    Future<void> flood(int from, int count) async {
      for (int i = from; i < from + count; i++) {
        await eve.send('ania', <String, dynamic>{
          'type': MeetTypes.alarm,
          'id': 'fala$i',
          'at': 1,
          'note': 'x' * 5000,
        });
      }
    }

    await flood(0, 40);
    expect(
      ania.shown.length - rang,
      MeetService.maxNewAlarmsPerFriendPerHour,
      reason: 'a few ring, the rest are dropped',
    );
    // Hours later, still never more than her share, all of them going on.
    for (int hour = 1; hour <= 4; hour++) {
      ania.clock += 3600 * 1000 + 1;
      await flood(hour * 100, 40);
    }
    final MeetBook book = ania.service.book;
    expect(
      book.alarms.where((AlarmRecord a) => a.from == 'eve'),
      hasLength(MeetBook.maxAlarmsPerFriend),
    );
    expect(book.ownActiveAlarm!.id, own.id);
    expect(book.alarm(bobs.id)!.isActive, isTrue);
    expect(
      book.alarms.every(
        (AlarmRecord a) => a.note.length <= AlarmRecord.maxNoteChars,
      ),
      isTrue,
    );
  });

  test('a custom status keeps its own words and emoji, and friends see '
      'it', () async {
    const IntentStatus mine = IntentStatus(
      kind: IntentKind.custom,
      setAt: 1000,
      until: 5000,
      note: 'Na siłowni',
      emoji: '💪',
    );
    final IntentStatus back = IntentStatus.fromJson(
      jsonDecode(jsonEncode(mine.toJson())),
    )!;
    expect(back.kind, IntentKind.custom);
    expect(back.note, 'Na siłowni');
    expect(back.emoji, '💪');
    expect(back.until, 5000);
    expect(back.shownEmoji, '💪');
    expect(back.shownLabel, 'Na siłowni');
    expect(back.shownNote, isEmpty, reason: 'its words are its name');

    // Without words it is no status; long words are cut, odd emoji dropped.
    expect(
      IntentStatus.fromJson(<String, dynamic>{
        'k': 'custom',
        'at': 1,
        'until': 0,
        'note': '   ',
      }),
      isNull,
    );
    final IntentStatus odd = IntentStatus.fromJson(<String, dynamic>{
      'k': 'custom',
      'at': 1,
      'until': 0,
      'note': 'x' * 100,
      'e': '🙂' * 10,
    })!;
    expect(odd.note.length, IntentStatus.maxCustomChars);
    expect(odd.emoji, isEmpty);
    expect(odd.shownEmoji, IntentKind.custom.emoji);
    expect(
      IntentStatus.cutCustom('${'a' * 39}🙂'),
      'a' * 39,
      reason: 'never half an emoji',
    );
    // Other statuses keep their own emoji and label.
    final IntentStatus talk = IntentStatus.fromJson(<String, dynamic>{
      'k': 'talk',
      'at': 1,
      'until': 0,
      'note': 'kawa?',
      'e': '💪',
    })!;
    expect(talk.emoji, isEmpty);
    expect(talk.shownLabel, IntentKind.talk.label);
    expect(talk.shownNote, 'kawa?');

    final _Net net = _Net();
    final _Host ania = _Host(net, 'ania', <String>['bob']);
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    await ania.service.setMyIntent(mine);
    final (String who, IntentStatus s) = bob.service
        .friendsWith(IntentKind.custom)
        .single;
    expect(who, 'ania');
    expect(s.shownLabel, 'Na siłowni');
    expect(s.shownEmoji, '💪');
    expect(bob.service.friendsWith(IntentKind.talk), isEmpty);
    expect(bob.shown, isEmpty, reason: 'only asking for help notifies');
    final MeetBook again = MeetBook.fromJson(
      jsonDecode(jsonEncode(bob.service.book.toJson())),
    );
    expect(again.intentOf('ania', 1000)!.emoji, '💪');

    // It goes out by itself like any other.
    bob.clock = 5001;
    expect(bob.service.friendsWith(IntentKind.custom), isEmpty);
  });

  test('an alarm tells its owner whose phone got it, who opened it and who '
      'answered; only friends it went to can confirm it', () async {
    final _Net net = _Net();
    final _Host ania = _Host(
      net,
      'ania',
      <String>['bob', 'cyryl', 'dora', 'eve'],
      close: <String>['bob', 'cyryl', 'dora'],
    );
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    final _Host cyryl = _Host(net, 'cyryl', <String>['ania']);
    final _Host eve = _Host(net, 'eve', <String>['ania']);
    // Dora's phone is off: not on the network yet.
    int acks(_Host h) => h.sent
        .where(
          ((String, Map<String, dynamic>) s) =>
              s.$2['type'] == MeetTypes.alarmAck,
        )
        .length;
    int alarmsTo(String who) => ania.sent
        .where(
          ((String, Map<String, dynamic>) s) =>
              s.$1 == who && s.$2['type'] == MeetTypes.alarm,
        )
        .length;

    final AlarmRecord alarm = await ania.service.raiseAlarm(note: 'pomocy');
    AlarmRecord own = ania.service.book.ownActiveAlarm!;
    expect(own.sentTo, <String>['bob', 'cyryl', 'dora']);
    expect(own.reachOf('bob'), AlarmReach.delivered);
    expect(own.deliveries['bob']!.got, 1000);
    expect(own.reachOf('dora'), AlarmReach.sent);
    expect(own.deliveredCount, 2);
    expect(own.unconfirmed, <String>['dora']);
    expect(acks(bob), 1);
    // Friends never learn whom else it went to.
    expect(
      ania.sent.every(
        ((String, Map<String, dynamic>) s) =>
            !s.$2.containsKey('to') && !s.$2.containsKey('dlv'),
      ),
      isTrue,
    );
    expect(bob.service.book.alarm(alarm.id)!.sentTo, isEmpty);
    expect(bob.service.book.alarm(alarm.id)!.deliveries, isEmpty);

    // A new position: no new confirmation needed, the old ones stay.
    await ania.service.updateAlarmLocation(52.23, 21.01);
    expect(acks(bob), 1);
    own = ania.service.book.ownActiveAlarm!;
    expect(own.hasLocation, isTrue);
    expect(own.reachOf('bob'), AlarmReach.delivered);

    // Bob opens it (once is enough); his time counts when it makes sense.
    ania.clock = 5000;
    bob.clock = 3000;
    await bob.service.markAlarmSeen(alarm.id);
    await bob.service.markAlarmSeen(alarm.id);
    expect(acks(bob), 2);
    own = ania.service.book.ownActiveAlarm!;
    expect(own.reachOf('bob'), AlarmReach.seen);
    expect(own.deliveries['bob']!.seen, 3000);
    expect(own.deliveries['bob']!.got, 1000);

    // Cyryl answers.
    await cyryl.service.respond(alarm.id, AlarmResponse.coming);
    expect(
      ania.service.book.ownActiveAlarm!.reachOf('cyryl'),
      AlarmReach.answered,
    );

    // Eve did not get it; a stranger is no friend; junk changes nothing;
    // and nobody confirms an alarm that is not the receiver's own.
    await eve.send('ania', <String, dynamic>{
      'type': MeetTypes.alarmAck,
      'id': alarm.id,
      'k': 'got',
    });
    final _Host mallory = _Host(net, 'mallory', <String>['ania']);
    await mallory.send('ania', <String, dynamic>{
      'type': MeetTypes.alarmAck,
      'id': alarm.id,
      'k': 'seen',
    });
    await bob.send('ania', <String, dynamic>{
      'type': MeetTypes.alarmAck,
      'id': alarm.id,
      'k': 'zzz',
      't': 1,
    });
    await ania.send('bob', <String, dynamic>{
      'type': MeetTypes.alarmAck,
      'id': alarm.id,
      'k': 'got',
    });
    own = ania.service.book.ownActiveAlarm!;
    expect(own.deliveries.keys.toList(), <String>['bob', 'cyryl']);
    expect(own.deliveries['bob']!.seen, 3000);
    expect(bob.service.book.alarm(alarm.id)!.deliveries, isEmpty);

    // Sent again only to those who did not confirm (Eve never had it),
    // and they are asked to confirm.
    final _Host dora = _Host(net, 'dora', <String>['ania']);
    final int toBob = alarmsTo('bob');
    final int toDora = alarmsTo('dora');
    await ania.service.resendOwnAlarm(to: <String>[...own.unconfirmed, 'eve']);
    expect(alarmsTo('bob'), toBob);
    expect(alarmsTo('eve'), 0);
    expect(alarmsTo('dora'), toDora + 1);
    expect(ania.sent.last.$2['cf'], isTrue);
    expect(dora.shown.single.isRingingCall, isTrue);
    expect(acks(dora), 1);
    own = ania.service.book.ownActiveAlarm!;
    expect(own.reachOf('dora'), AlarmReach.delivered);
    expect(own.deliveredCount, 3);
    expect(own.unconfirmed, isEmpty);

    // Kept in the book; an alarm from before confirmations has none.
    final MeetBook again = MeetBook.fromJson(
      jsonDecode(jsonEncode(ania.service.book.toJson())),
    );
    final AlarmRecord kept = again.alarm(alarm.id)!;
    expect(kept.sentTo, <String>['bob', 'cyryl', 'dora']);
    expect(kept.reachOf('bob'), AlarmReach.seen);
    expect(kept.deliveries['bob']!.seen, 3000);
    final AlarmRecord older = AlarmRecord.fromJson(<String, dynamic>{
      'id': 'stary',
      'from': 'self',
      'at': 1,
    })!;
    expect(older.sentTo, isEmpty);
    expect(older.deliveries, isEmpty);
    expect(older.deliveredCount, 0);
  });

  test('alarm confirmations reach the owner while the app is away: the '
      'background service sends and keeps them', () async {
    // Handled by the Android background service and retried until they
    // arrive.
    expect(MeetInbox.handles(MeetTypes.alarmAck), isTrue);
    expect(kReliablePayloadTypes, contains(MeetTypes.alarmAck));

    final _Net net = _Net();
    final _Host ania = _Host(
      net,
      'ania',
      <String>['bob'],
      close: <String>['bob'],
    );
    final _Host bob = _Host(net, 'bob', <String>['ania']);
    // Ania's phone is away from the network while she raises it.
    net.hosts.remove('bob');
    final AlarmRecord alarm = await ania.service.raiseAlarm();
    final Map<String, dynamic> copy = ania.sent.last.$2;
    expect(copy['cf'], isTrue);
    net.hosts['bob'] = bob;

    // Bob's background service (its own service over the same store, never
    // read before) gets the alarm and confirms it.
    final MeetService bobAway = MeetService(
      host: bob,
      store: MeetStore(bob.service.store.disk),
      now: () => bob.clock,
    );
    // Ania's background service holds an old copy of her book: the
    // confirmation is checked against the store.
    final MeetService aniaAway = MeetService(
      host: ania,
      store: MeetStore(ania.service.store.disk),
      now: () => ania.clock,
    );
    net.hosts.remove('ania');
    await bobAway.handle(
      SignalTransportFrame(
        from: 'ania',
        payload: jsonDecode(jsonEncode(copy)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
    final (String to, Map<String, dynamic> ack) = bob.sent.last;
    expect(to, 'ania');
    expect(ack['type'], MeetTypes.alarmAck);
    expect(ack['k'], 'got');
    await aniaAway.handle(
      SignalTransportFrame(
        from: 'bob',
        payload: jsonDecode(jsonEncode(ack)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
    await ania.service.reload();
    expect(
      ania.service.book.ownActiveAlarm!.reachOf('bob'),
      AlarmReach.delivered,
    );
    expect(alarm.id, ania.service.book.ownActiveAlarm!.id);
  });

  test('a full list of alarms drops the oldest ended alarm of a friend, '
      "never this person's own or one still going on", () {
    final MeetBook book = MeetBook()
      ..putAlarm(const AlarmRecord(id: 'moj', from: 'self', at: 1));
    for (int i = 0; i < MeetBook.maxAlarms - 1; i++) {
      book.putAlarm(AlarmRecord(id: 'stary$i', from: 'f$i', at: 2, endedAt: 3));
    }
    expect(book.alarms, hasLength(MeetBook.maxAlarms));
    book.putAlarm(const AlarmRecord(id: 'nowy', from: 'g', at: 4));
    expect(book.alarms, hasLength(MeetBook.maxAlarms));
    expect(book.alarm('stary0'), isNull, reason: 'the oldest ended one');
    expect(book.alarm('moj'), isNotNull);

    // Only alarms going on: none is pushed out, the list grows instead.
    final MeetBook busy = MeetBook()
      ..putAlarm(const AlarmRecord(id: 'moj', from: 'self', at: 1, endedAt: 2));
    for (int i = 0; i < MeetBook.maxAlarms + 5; i++) {
      busy.putAlarm(AlarmRecord(id: 'trwa$i', from: 'f$i', at: 2));
    }
    expect(busy.alarms, hasLength(MeetBook.maxAlarms + 6));
    expect(busy.alarm('moj'), isNotNull);
  });
}
