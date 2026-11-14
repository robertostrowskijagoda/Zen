import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_state_sync.dart';

Map<String, Object?> _copy(Map<String, Object?> m) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(m)) as Map);

/// A state kept in memory; [drop] are keys its "service" does not keep
/// (they vanish when it is written).
final class _Domain implements AccountSyncDomain {
  _Domain(this.id, this.state, {this.drop = const <String>{}});

  @override
  final String id;
  Map<String, Object?> state;
  final Set<String> drop;
  int writes = 0;
  int reads = 0;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Set<String> get wholeKeys => const <String>{'order'};

  @override
  Future<Map<String, Object?>?> read() async {
    reads++;
    return _copy(state);
  }

  @override
  Future<void> write(Map<String, Object?> next) async {
    writes++;
    state = _copy(next)..removeWhere((String k, Object? _) => drop.contains(k));
  }

  void change(void Function(Map<String, Object?> s) f) {
    f(state);
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;
}

/// A state whose deletions go over every start of the log.
final class _MarkedDomain extends _Domain
    implements AccountSyncMarkedDeletions {
  _MarkedDomain(super.id, super.state);
}

/// One device's log, in memory, that starts over.
final class _LogChannel implements AccountSyncChannel, AccountSyncLog {
  final List<Map<String, dynamic>> log = <Map<String, dynamic>>[];

  @override
  String get device => 'dev-a';

  @override
  bool get hasOtherDevices => true;

  @override
  Iterable<Map<String, dynamic>> existing() => const <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get incoming =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<void> get devicesChanged => const Stream<void>.empty();

  @override
  Future<bool> publish(Map<String, dynamic> body) async {
    log.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
    return true;
  }

  @override
  Future<Object?> startOver() async => log.length;

  @override
  Future<int> dropBefore(Object start) async {
    log.removeRange(0, start as int);
    return start;
  }

  @override
  void close() {}

  @override
  Future<void> reopen() async {}

  /// The deletions in the log of [domain].
  Map<String, Object?> deletions(String domain) => <String, Object?>{
    for (final Map<String, dynamic> body in log)
      if (body['d'] == domain)
        for (final MapEntry<String, dynamic> u
            in (body['u'] as Map<String, dynamic>).entries)
          if ((u.value as Map<String, dynamic>)['x'] == 1) u.key: u.value,
  };
}

/// The account's devices, reaching each other at once.
final class _Net {
  final List<_Channel> devices = <_Channel>[];
  final List<(String, Map<String, dynamic>)> log =
      <(String, Map<String, dynamic>)>[];
}

final class _Channel implements AccountSyncChannel {
  _Channel(this.net, this.device) {
    net.devices.add(this);
  }

  final _Net net;
  @override
  final String device;
  final StreamController<Map<String, dynamic>> _in =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<void> _devices = StreamController<void>.broadcast();

  @override
  bool get hasOtherDevices => net.devices.length > 1;

  @override
  Iterable<Map<String, dynamic>> existing() => <Map<String, dynamic>>[
    for (final (String from, Map<String, dynamic> body) in net.log)
      if (from != device) body,
  ];

  @override
  Stream<Map<String, dynamic>> get incoming => _in.stream;

  @override
  Stream<void> get devicesChanged => _devices.stream;

  @override
  Future<bool> publish(Map<String, dynamic> body) async {
    final Map<String, dynamic> sent =
        jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    net.log.add((device, sent));
    for (final _Channel d in net.devices) {
      if (d != this) {
        scheduleMicrotask(() => d._in.add(sent));
      }
    }
    return true;
  }
}

final class _Device {
  _Device(
    _Net net,
    String id,
    Map<String, Object?> settings, {
    Set<String> drop = const <String>{},
  }) : channel = _Channel(net, id),
       settings = _Domain('settings', settings, drop: drop),
       circles = _Domain('meet/circles', <String, Object?>{'c': <Object?>[]});

  final _Channel channel;
  final _Domain settings;
  final _Domain circles;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late final AccountStateSync sync = AccountStateSync(
    channel: channel,
    disk: disk,
    domains: <AccountSyncDomain>[settings, circles],
    delay: const Duration(milliseconds: 1),
    scanEvery: const Duration(hours: 1),
  );
}

Future<void> _settle(List<_Device> devices) async {
  for (int round = 0; round < 6; round++) {
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final _Device d in devices) {
      await d.sync.flush();
    }
  }
}

void main() {
  test('flatten and back keeps the state and its order', () {
    final Map<String, Object?> state = <String, Object?>{
      'theme': 'dark',
      'tags': <Object?>['b', 'a'],
      'items': <Object?>[
        <String, Object?>{'id': 'x', 'n': 1},
        <String, Object?>{'id': 'y', 'n': 2},
      ],
      'map': <String, Object?>{'k': 1, 'j': 2},
      'order': <Object?>[3, 1, 2],
      'empty': <Object?>[],
    };
    final Map<String, Object?> units = flattenAccountState(
      state,
      whole: <String>{'order'},
    );
    expect(units.length, 1 + 2 + 2 + 2 + 1 + 1);
    expect(unflattenAccountState(units, state), state);
    expect(
      accountStateHash(<String, Object?>{'a': 1, 'b': 2}),
      accountStateHash(<String, Object?>{'b': 2, 'a': 1}),
    );
  });

  test('two devices change different things and end the same', () async {
    final _Net net = _Net();
    final _Device a = _Device(net, 'dev-a', <String, Object?>{
      'theme': 'light',
      'sounds': true,
    });
    final _Device b = _Device(net, 'dev-b', <String, Object?>{
      'theme': 'light',
      'sounds': true,
    });
    await a.sync.start();
    await b.sync.start();
    await _settle(<_Device>[a, b]);

    a.settings.change((Map<String, Object?> s) => s['theme'] = 'dark');
    b.settings.change((Map<String, Object?> s) => s['sounds'] = false);
    b.circles.change(
      (Map<String, Object?> s) => (s['c']! as List<Object?>).add(
        <String, Object?>{'id': 'c1', 'name': 'Obiad'},
      ),
    );
    a.circles.change(
      (Map<String, Object?> s) => (s['c']! as List<Object?>).add(
        <String, Object?>{'id': 'c2', 'name': 'Kolacja'},
      ),
    );
    await _settle(<_Device>[a, b]);

    expect(a.settings.state, <String, Object?>{
      'theme': 'dark',
      'sounds': false,
    });
    expect(b.settings.state, a.settings.state);
    expect(
      (a.circles.state['c']! as List<Object?>)
          .map((Object? c) => (c! as Map<String, Object?>)['id'])
          .toSet(),
      <String>{'c1', 'c2'},
    );
    expect(
      (b.circles.state['c']! as List<Object?>)
          .map((Object? c) => (c! as Map<String, Object?>)['id'])
          .toSet(),
      <String>{'c1', 'c2'},
    );

    // Nothing more goes back and forth once they agree.
    final int sentA = a.sync.published;
    final int sentB = b.sync.published;
    await _settle(<_Device>[a, b]);
    expect(a.sync.published, sentA);
    expect(b.sync.published, sentB);

    // A removed item goes on the other device too.
    a.circles.change(
      (Map<String, Object?> s) => (s['c']! as List<Object?>).removeWhere(
        (Object? c) => (c! as Map<String, Object?>)['id'] == 'c1',
      ),
    );
    await _settle(<_Device>[a, b]);
    expect(
      (b.circles.state['c']! as List<Object?>)
          .map((Object? c) => (c! as Map<String, Object?>)['id'])
          .toList(),
      <String>['c2'],
    );
    await a.sync.stop();
    await b.sync.stop();
  });

  test('the same field changed on both: one value wins everywhere', () async {
    final _Net net = _Net();
    final _Device a = _Device(net, 'dev-a', <String, Object?>{'theme': 'x'});
    final _Device b = _Device(net, 'dev-b', <String, Object?>{'theme': 'x'});
    await a.sync.start();
    await b.sync.start();
    await _settle(<_Device>[a, b]);
    a.settings.state['theme'] = 'dark';
    b.settings.state['theme'] = 'calm';
    // Both look before either hears of the other.
    await a.sync.flush();
    await b.sync.flush();
    await _settle(<_Device>[a, b]);
    expect(a.settings.state['theme'], b.settings.state['theme']);
    await a.sync.stop();
    await b.sync.stop();
  });

  test('a device linked later takes what was sent before', () async {
    final _Net net = _Net();
    final _Device a = _Device(net, 'dev-a', <String, Object?>{'theme': 'x'});
    // Alone first: nothing to send to.
    await a.sync.start();
    a.settings.change((Map<String, Object?> s) => s['theme'] = 'dark');
    await _settle(<_Device>[a]);
    expect(net.log, isEmpty);

    final _Device b = _Device(net, 'dev-b', <String, Object?>{'theme': 'x'});
    a.channel._devices.add(null);
    await _settle(<_Device>[a]);
    expect(net.log, isNotEmpty);
    await b.sync.start();
    await _settle(<_Device>[a, b]);
    expect(b.settings.state['theme'], 'dark');
    await a.sync.stop();
    await b.sync.stop();
  });

  test('what a device does not keep is not sent back (no loop)', () async {
    final _Net net = _Net();
    final _Device a = _Device(net, 'dev-a', <String, Object?>{'theme': 'x'});
    // This device's settings have no "extra".
    final _Device b = _Device(
      net,
      'dev-b',
      <String, Object?>{'theme': 'x'},
      drop: <String>{'extra'},
    );
    await a.sync.start();
    await b.sync.start();
    await _settle(<_Device>[a, b]);
    a.settings.change((Map<String, Object?> s) => s['extra'] = 1);
    await _settle(<_Device>[a, b]);
    expect(a.settings.state['extra'], 1, reason: 'not removed by the other');
    expect(b.settings.state.containsKey('extra'), isFalse);
    final int writes = b.settings.writes;
    final int sentB = b.sync.published;
    await _settle(<_Device>[a, b]);
    expect(b.sync.published, sentB);
    expect(b.settings.writes, writes);
    await a.sync.stop();
    await b.sync.stop();
  });

  test('a field an older build does not keep is held, and after its '
      'update it takes the value instead of sending its default', () async {
    final _Net net = _Net();
    final _Device a = _Device(net, 'dev-a', <String, Object?>{'theme': 'x'});
    final Set<String> unknownToB = <String>{'extra'};
    final _Device b = _Device(net, 'dev-b', <String, Object?>{
      'theme': 'x',
    }, drop: unknownToB);
    await a.sync.start();
    await b.sync.start();
    await _settle(<_Device>[a, b]);
    a.settings.change((Map<String, Object?> s) => s['extra'] = 7);
    await _settle(<_Device>[a, b]);
    expect(b.settings.state.containsKey('extra'), isFalse);
    // Held on disk, not taken for a deletion (by its unit, like every
    // other unit of the saved state).
    final Map<String, dynamic> saved =
        jsonDecode(utf8.decode((await b.disk.read('account/sync/state'))!))
            as Map<String, dynamic>;
    expect(
      (saved['h'] as Map<String, dynamic>)['settings'],
      flattenAccountState(<String, Object?>{'extra': 7}),
    );

    // B is updated: its settings now know the field, at its default.
    await b.sync.stop();
    unknownToB.clear();
    b.settings.state['extra'] = 0;
    final AccountStateSync updated = AccountStateSync(
      channel: b.channel,
      disk: b.disk,
      domains: <AccountSyncDomain>[b.settings, b.circles],
      delay: const Duration(milliseconds: 1),
      scanEvery: const Duration(hours: 1),
    );
    await updated.start();
    await updated.flush();
    await _settle(<_Device>[a]);
    await updated.flush();
    expect(b.settings.state['extra'], 7, reason: 'the held value went in');
    expect(a.settings.state['extra'], 7, reason: 'the default did not win');
    await a.sync.stop();
    await updated.stop();
  });

  test('a flood of deletions: those written again at a start of the log '
      'after their 30 days are the newest within the bound, and only for a '
      'state that keeps no markers of its own', () async {
    int now = 1000000;
    final List<String> ids = <String>[
      for (int i = 0; i < 3000; i++) 'plan-${i.toString().padLeft(5, '0')}',
    ];
    final _MarkedDomain plans = _MarkedDomain('meet/plans', <String, Object?>{
      'plans': <Object?>[
        for (final String id in ids) <String, Object?>{'id': id},
      ],
    });
    final _Domain settings = _Domain('settings', <String, Object?>{
      'old': 1,
      'recent': 2,
      'kept': 3,
    });
    final _LogChannel channel = _LogChannel();
    final AccountStateSync sync = AccountStateSync(
      channel: channel,
      disk: MemoryLedgerDisk(),
      domains: <AccountSyncDomain>[plans, settings],
      delay: const Duration(hours: 1),
      scanEvery: const Duration(hours: 1),
      now: () => now,
    );
    await sync.start();
    await sync.flush();
    // Deleted a hundred at a time, the first ones first; one plan stays.
    settings.state.remove('old');
    while ((plans.state['plans']! as List<Object?>).length > 1) {
      final List<Object?> had = plans.state['plans']! as List<Object?>;
      plans.state = <String, Object?>{
        'plans': had.skip(min(100, had.length - 1)).toList(),
      };
      await sync.flush();
    }
    expect(sync.rebased, 0);

    // Long after, one more deletion, and the log starts over.
    now += const Duration(days: 40).inMilliseconds;
    settings.state.remove('recent');
    await sync.flush();
    expect(sync.rebased, 1);
    final Map<String, Object?> carried = channel.deletions('meet/plans');
    // Counted as the sync counts them: each deletion on its own.
    int bytes = 0;
    carried.forEach((String key, Object? value) {
      bytes += utf8.encode(jsonEncode(<String, Object?>{key: value})).length;
    });
    expect(bytes, lessThanOrEqualTo(kAccountSyncMarkerBytes));
    expect(bytes, greaterThan(kAccountSyncMarkerBytes - 200), reason: 'full');
    expect(carried.length, lessThan(ids.length - 1));
    String unit(String id) => flattenAccountState(<String, Object?>{
      'plans': <Object?>[
        <String, Object?>{'id': id},
      ],
    }).keys.single;
    // The newest deletions go, the oldest do not.
    final List<String> deleted = ids.sublist(0, ids.length - 1);
    final int kept = carried.length;
    for (final String id in deleted.sublist(deleted.length - kept)) {
      expect(carried.containsKey(unit(id)), isTrue, reason: id);
    }
    for (final String id in deleted.sublist(0, deleted.length - kept)) {
      expect(carried.containsKey(unit(id)), isFalse, reason: id);
    }
    // A state with markers of its own: its old deletion is not written
    // again, a recent one is.
    expect(channel.deletions('settings').keys, <String>[
      flattenAccountState(<String, Object?>{'recent': 0}).keys.single,
    ]);
    // What is still there goes as it is.
    expect(jsonEncode(channel.log), contains(ids.last));
    expect(jsonEncode(channel.log), contains('kept'));
    await sync.stop();
  });

  test('the periodic scan waits while the states cannot be read', () async {
    final _Net net = _Net();
    final _Channel channel = _Channel(net, 'dev-a');
    final _Domain settings = _Domain('settings', <String, Object?>{'a': 1});
    bool readable = true;
    final AccountStateSync sync = AccountStateSync(
      channel: channel,
      disk: MemoryLedgerDisk(),
      domains: <AccountSyncDomain>[settings],
      scanEvery: const Duration(milliseconds: 20),
      mayRead: () async => readable,
    );
    await sync.start();
    await sync.idle;
    expect(settings.reads, greaterThan(0), reason: 'a scan runs at start');

    // Locked: the scans that come meanwhile do not touch the stores.
    readable = false;
    await sync.idle;
    final int locked = settings.reads;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await sync.idle;
    expect(settings.reads, locked);

    // Unlocked: the next scan reads again.
    readable = true;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await sync.idle;
    expect(settings.reads, greaterThan(locked));
    await sync.stop();
  });
}
