import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';

import 'support/friends_world.dart';

/// Messaging under a random life (`FriendsWorld`): five friends' phones
/// send to each other while they go off the network and back, get locked
/// and unlocked, are split from each other and healed, on a network that
/// loses and repeats datagrams at changing rates. Each seed is another
/// life, and the same seed always the same one. Whatever happened, once
/// the phones are back (online, unlocked, the network whole), every
/// message reaches its friend exactly once and in the order it was sent,
/// and its sender sees it delivered.
///
/// `ZEN_SOAK_SEEDS=1-200 flutter test test/communication_soak_test.dart`
/// runs more lives (the default is a few, for every CI run).

const List<String> _names = <String>['A', 'B', 'C', 'D', 'E'];

/// The seeds to run: ZEN_SOAK_SEEDS ("1-200" or "3,17,42"), or 1-6.
List<int> _seeds() {
  final String spec = Platform.environment['ZEN_SOAK_SEEDS'] ?? '1-6';
  final List<int> out = <int>[];
  for (final String part in spec.split(',')) {
    final List<String> range = part.trim().split('-');
    final int from = int.parse(range.first);
    final int to = range.length > 1 ? int.parse(range.last) : from;
    for (int s = from; s <= to; s++) {
      out.add(s);
    }
  }
  return out;
}

/// One random life of [seed]; returns what happened, for a failure's
/// message.
Future<void> _live(int seed) async {
  final Random r = Random(seed);
  // D a computer in the tray (never locked), E an iPhone (it receives
  // only while Zen is open: closing it takes it off the mesh), the rest
  // Android phones.
  final FriendsWorld w = await FriendsWorld.create(
    _names,
    seed: seed,
    duplicateRate: r.nextBool() ? 0.05 : 0,
    devices: const <String, SimDevice>{
      'D': SimDevice.desktop,
      'E': SimDevice.iphone,
    },
  );
  final String group = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
    for (final String n in _names.skip(1)) w[n],
  ]);
  // B's second phone: mail for B reaches both, and what it sends is B's.
  await w.addDevice(w['B'], 'B2');
  const List<String> devices = <String>[..._names, 'B2'];
  // What each member wrote to the group, in order.
  final Map<String, List<String>> toGroup = <String, List<String>>{};
  final List<String> log = <String>[];
  // What each sender sent each friend, in order.
  final Map<(String, String), List<String>> sent =
      <(String, String), List<String>>{};
  int counter = 0;
  bool split = false;

  for (int step = 0; step < 60; step++) {
    final int roll = r.nextInt(100);
    final FriendsPhone p = w[devices[r.nextInt(devices.length)]];
    if (roll < 12) {
      if (p.locked || p.name == 'B2') {
        continue;
      }
      final String text = 's$seed-g${counter++} ${p.name}>grupa';
      log.add('group $text');
      (toGroup[p.name] ??= <String>[]).add(text);
      await w.sendGroup(p, group, text);
    } else if (roll < 45) {
      // A message, from an unlocked phone (a locked one has no app to
      // write in), online or not.
      if (p.locked) {
        continue;
      }
      FriendsPhone to;
      do {
        to = w[_names[r.nextInt(_names.length)]];
      } while (to.name == _accountOf(p.name));
      final String text = 's$seed-m${counter++} ${p.name}>${to.name}';
      log.add('send $text');
      (sent[(p.name, to.name)] ??= <String>[]).add(text);
      await w.send(p, to, text);
    } else if (roll < 60) {
      final bool on = !p.online;
      log.add('${p.name} ${on ? 'online' : 'offline'}');
      await w.setOnline(p, on);
    } else if (roll < 72) {
      if (p.device == SimDevice.desktop) {
        continue;
      }
      if (p.device == SimDevice.iphone) {
        final bool on = !p.online;
        log.add('${p.name} ${on ? 'opened' : 'closed'}');
        await w.setOnline(p, on);
        continue;
      }
      log.add('${p.name} ${p.locked ? 'unlock' : 'lock'}');
      if (p.locked) {
        await w.unlock(p);
      } else {
        await w.lock(p);
      }
    } else if (roll < 78) {
      if (split) {
        log.add('heal');
        w.heal();
      } else {
        final List<FriendsPhone> phones = w.phones..shuffle(r);
        final int cut = 1 + r.nextInt(phones.length - 1);
        log.add(
          'split ${phones.take(cut).map((FriendsPhone x) => x.name)} | '
          '${phones.skip(cut).map((FriendsPhone x) => x.name)}',
        );
        w.partition(phones.take(cut).toList(), phones.skip(cut).toList());
      }
      split = !split;
    } else if (roll < 84) {
      final double rate = <double>[0, 0, 0.1, 0.3][r.nextInt(4)];
      log.add('loss $rate');
      w.dropRate = rate;
    } else {
      final Duration wait = Duration(seconds: 5 + r.nextInt(600));
      log.add('wait ${wait.inSeconds}s');
      await w.advance(wait);
    }
  }

  // Everyone back: online, unlocked, the network whole and clean.
  log.add('-- back');
  w.heal();
  w.dropRate = 0;
  for (final FriendsPhone p in w.phones) {
    await w.setOnline(p, true);
    if (p.locked) {
      await w.unlock(p);
    }
  }

  Future<bool> allThere() async {
    for (final MapEntry<(String, String), List<String>> e in sent.entries) {
      for (final String device in _devicesOf(e.key.$2)) {
        final List<String> got = await w[device].textsFrom(
          w[_accountOf(e.key.$1)],
        );
        if (!e.value.every(got.contains)) {
          return false;
        }
      }
    }
    final int groupCount = toGroup.values.fold(
      0,
      (int n, List<String> l) => n + l.length,
    );
    for (final String n in _names) {
      if ((await w.groupTexts(w[n], group)).length < groupCount) {
        return false;
      }
    }
    return true;
  }

  String story() => 'seed $seed:\n  ${log.join('\n  ')}';
  try {
    await w.until(
      allThere,
      within: const Duration(hours: 3),
      reason: 'every message of the life',
    );
  } on TestFailure catch (e) {
    final StringBuffer missing = StringBuffer();
    for (final MapEntry<(String, String), List<String>> en in sent.entries) {
      for (final String device in _devicesOf(en.key.$2)) {
        final List<String> got = await w[device].textsFrom(
          w[_accountOf(en.key.$1)],
        );
        for (final String text in en.value) {
          if (!got.contains(text)) {
            final ChatMessageDeliveryState? state = await w[en.key.$1]
                .deliveryOf(w[en.key.$2], text);
            missing.writeln(
              '  missing "$text" on $device (sender sees $state)',
            );
          }
        }
      }
    }
    for (final String n in _names) {
      final List<String> got = await w.groupTexts(w[n], group);
      for (final List<String> texts in toGroup.values) {
        for (final String text in texts) {
          if (!got.contains(text)) {
            missing.writeln('  missing "$text" in the group on $n');
          }
        }
      }
    }
    fail('${e.message}\n$missing${story()}');
  }
  // Time for repeats and late copies to show up, if any would.
  await w.advance(const Duration(minutes: 20));

  for (final MapEntry<(String, String), List<String>> e in sent.entries) {
    final FriendsPhone from = w[e.key.$1];
    final FriendsPhone to = w[e.key.$2];
    for (final String device in _devicesOf(to.name)) {
      _expectOnceInOrder(
        await w[device].textsFrom(w[_accountOf(from.name)]),
        e.value,
        '${from.name} to ${to.name}, on $device\n${story()}',
      );
    }
    for (final String text in e.value) {
      final ChatMessageDeliveryState? state = await from.deliveryOf(to, text);
      expect(
        state,
        ChatMessageDeliveryState.delivered,
        reason: '"$text" delivered for its sender\n${story()}',
      );
    }
  }
  for (final String n in _names) {
    final List<String> got = await w.groupTexts(w[n], group);
    for (final MapEntry<String, List<String>> e in toGroup.entries) {
      _expectOnceInOrder(
        got,
        e.value,
        '${e.key} to the group, on $n\n${story()}',
      );
    }
  }
}

/// The account a device belongs to (B2 is B's second phone).
String _accountOf(String device) => device == 'B2' ? 'B' : device;

/// The devices mail for [account] reaches.
List<String> _devicesOf(String account) =>
    account == 'B' ? const <String>['B', 'B2'] : <String>[account];

/// [all] holds each of [texts] once, in their order (other senders' texts
/// may come between them).
void _expectOnceInOrder(List<String> all, List<String> texts, String reason) {
  for (final String text in texts) {
    expect(
      all.where((String t) => t == text),
      hasLength(1),
      reason: '"$text" once: $reason',
    );
  }
  expect(
    <String>[
      for (final String t in all)
        if (texts.contains(t)) t,
    ],
    texts,
    reason: 'in order: $reason',
  );
}

void main() {
  group('found by these lives', () {
    test('two messages sent within one millisecond (here: while offline) '
        'both arrive; the second no longer takes the first one\'s id and '
        'place while its sender sees both delivered', () async {
      final FriendsWorld w = await FriendsWorld.create(_names, seed: 4);
      await w.setOnline(w['B'], false);
      // The world's clock stands still while B is offline: one stamp.
      await w.send(w['B'], w['C'], 'pierwsza');
      await w.send(w['B'], w['C'], 'druga');
      await w.setOnline(w['B'], true);
      await w.advance(const Duration(minutes: 10));
      expect(await w['C'].textsFrom(w['B']), <String>['pierwsza', 'druga']);
      final List<ChatMessage> mine = await w['B'].thread(w['C']);
      expect(
        <String>{
          for (final ChatMessage m in mine)
            if (m.direction == ChatMessageDirection.outgoing) m.id,
        },
        hasLength(2),
        reason: 'an id of its own each',
      );
    });

    test('two members writing to a group within the same millisecond each '
        'reach everyone; neither phone takes the other\'s message for a '
        'copy of its own', () async {
      final FriendsWorld w = await FriendsWorld.create(_names, seed: 5);
      final String group = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
        for (final String n in _names.skip(1)) w[n],
      ]);
      await w.sendGroup(w['D'], group, 'od D', settleAfter: false);
      await w.sendGroup(w['A'], group, 'od A', settleAfter: false);
      await w.advance(const Duration(minutes: 5));
      for (final String n in _names) {
        expect((await w.groupTexts(w[n], group)).toSet(), <String>{
          'od D',
          'od A',
        }, reason: 'on $n');
      }
    });
  });

  for (final int seed in _seeds()) {
    test(
      'life $seed: every message once, in order, and delivered',
      () => _live(seed),
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
