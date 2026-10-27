import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';

/// The diagnostics log's files (one per isolate, set aside past a size)
/// and the technical lines in it: wakes, modes, the node's numbers and how
/// Android ended the app, with numbers and fixed words only.
void main() {
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('zen-tech-log');
    ZenTechLog.resetForTest();
  });

  tearDown(() async {
    ZenDiagnosticsLog.fileLimitBytes = 512 * 1024;
    ZenWake.resetForTest();
    ZenWake.platform = const TimerWakePlatform();
    ZenWake.nowMillis = () => DateTime.now().millisecondsSinceEpoch;
    await ZenDiagnosticsLog.settled;
    await folder.delete(recursive: true);
  });

  Future<List<String>> attachedLines(void Function() write) async {
    await ZenDiagnosticsLog.attach(folder, source: 'ui');
    write();
    await ZenDiagnosticsLog.settled;
    return (await ZenDiagnosticsLog.entries())
        .map((String entry) => entry.substring(entry.indexOf('] ') + 2))
        .toList(growable: false);
  }

  group('files', () {
    test(
      'a file past its limit is set aside, the one before dropped',
      () async {
        ZenDiagnosticsLog.fileLimitBytes = 4096;
        await ZenDiagnosticsLog.attach(folder, source: 'ui');
        for (int i = 0; i < 400; i++) {
          ZenDiagnosticsLog.write('INFO  line ${i.toString().padLeft(4, '0')}');
        }
        await ZenDiagnosticsLog.settled;

        final List<String> names =
            folder
                .listSync()
                .map(
                  (FileSystemEntity e) => e.path.split(RegExp(r'[/\\]')).last,
                )
                .toList()
              ..sort();
        expect(names, <String>[
          'zen-diagnostics-ui.log',
          'zen-diagnostics-ui.log.1',
        ]);
        for (final FileSystemEntity file in folder.listSync()) {
          // At most one line past the limit.
          expect((file as File).lengthSync(), lessThan(4096 + 200));
        }
        final List<String> entries = await ZenDiagnosticsLog.entries();
        expect(entries.last, endsWith('line 0399'));
        expect(entries.any((String e) => e.endsWith('line 0000')), isFalse);
        final List<int> order = <int>[
          for (final String e in entries)
            if (e.contains('INFO  line ')) int.parse(e.substring(e.length - 4)),
        ];
        expect(
          order,
          List<int>.generate(order.length, (int i) => order.first + i),
        );
      },
    );

    test(
      'both isolates write their own files and read back as one log',
      () async {
        await ZenDiagnosticsLog.attach(folder, source: 'ui');
        final String path = folder.path;
        final Future<void> service = Isolate.run(() async {
          await ZenDiagnosticsLog.attach(Directory(path), source: 'svc');
          for (int i = 0; i < 300; i++) {
            ZenDiagnosticsLog.write('INFO  svc $i');
            if (i % 50 == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
          }
          await ZenDiagnosticsLog.settled;
        });
        for (int i = 0; i < 300; i++) {
          ZenDiagnosticsLog.write('INFO  ui $i');
          if (i % 50 == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        }
        await service;
        await ZenDiagnosticsLog.settled;

        expect(File('$path/zen-diagnostics-ui.log').existsSync(), isTrue);
        expect(File('$path/zen-diagnostics-svc.log').existsSync(), isTrue);
        final List<String> entries = await ZenDiagnosticsLog.entries();
        for (final String side in <String>['ui', 'svc']) {
          final List<int> seen = <int>[
            for (final String e in entries)
              if (e.contains('[$side] INFO  $side '))
                int.parse(e.substring(e.lastIndexOf(' ') + 1)),
          ];
          expect(seen, List<int>.generate(300, (int i) => i), reason: side);
        }
        // In time order across the two.
        final List<String> times = <String>[
          for (final String e in entries)
            if (!e.contains('attached')) e.substring(0, e.indexOf(' ')),
        ];
        expect(times, List<String>.of(times)..sort());

        await ZenDiagnosticsLog.clear();
        expect(
          folder.listSync().where(
            (FileSystemEntity e) => e.path.contains('zen-diagnostics'),
          ),
          isEmpty,
          reason: 'clearing takes both isolates\' files',
        );
      },
    );

    test('logs are merged by time, each keeping its own order', () {
      expect(
        mergeDiagnosticsLogs(<String>[
          '2026-10-27T01:00:00.000 [ui] a\n'
              '    frame\n'
              '2026-10-27T01:00:02.000 [ui] c\n',
          '2026-10-27T01:00:01.000 [svc] b\n'
              '2026-10-27T01:00:03.000 [svc] d\n',
        ]),
        <String>[
          '2026-10-27T01:00:00.000 [ui] a\n    frame',
          '2026-10-27T01:00:01.000 [svc] b',
          '2026-10-27T01:00:02.000 [ui] c',
          '2026-10-27T01:00:03.000 [svc] d',
        ],
      );
    });
  });

  group('samples', () {
    test('a node sample has counts and sizes, by name', () {
      expect(
        nodeSampleLine(_nodeInfo),
        'TECH  node h=3 peers=3 up=2 inbound=1 pool=12 routes=40 '
        'heapKb=8192 goalKb=16384 retainedKb=20480 limitKb=0 goroutines=210 '
        'gc=55 rxBps=1500 txBps=1400 transitBps=900 transitKb=4096 '
        'pubRxKb=10240 pubTxKb=9216 locRxKb=512 locTxKb=256 sigRxKb=64 '
        'sigTxKb=32 relayRxKb=128 relayTxKb=96 holding=true holds=2 '
        'holdLeftS=540 heldS=1200 hourKb=2048 setAside=1 doorPubRxKb=300 '
        'doorPubTxKb=200',
      );
      expect(
        nodeSampleLine(const <String, dynamic>{'handle': 1}),
        startsWith('TECH  node h=1 peers=0 up=0 inbound=0 pool=0'),
      );
    });

    test(
      'the node is written at once, then at most every few minutes',
      () async {
        final DateTime start = DateTime(2026, 10, 27, 1);
        final List<String> lines = await attachedLines(() {
          ZenTechLog.node(_nodeInfo, now: start);
          ZenTechLog.node(
            _nodeInfo,
            now: start.add(const Duration(minutes: 1)),
          );
          ZenTechLog.node(
            _nodeInfo,
            now: start.add(const Duration(minutes: 4)),
          );
          ZenTechLog.node(
            _nodeInfo,
            now: start.add(const Duration(minutes: 5)),
          );
          ZenTechLog.nodeStopped(3);
          ZenTechLog.node(
            _nodeInfo,
            now: start.add(const Duration(minutes: 6)),
          );
        });
        expect(
          lines
              .where((String l) => l.startsWith('TECH'))
              .map((String l) => l.split(' ').take(4).join(' ')),
          <String>[
            'TECH  node-start h=3',
            'TECH  node h=3',
            'TECH  node h=3',
            'TECH  node-stop h=3',
            'TECH  node-start h=3',
            'TECH  node h=3',
          ],
        );
      },
    );

    test('a mode is written when it changes, with the one before', () async {
      final List<String> lines = await attachedLines(() {
        ZenTechLog.mode('app');
        ZenTechLog.mode('app');
        ZenTechLog.mode('background');
        ZenTechLog.handover(
          'service',
          ok: true,
          took: const Duration(milliseconds: 820),
        );
      });
      expect(lines.where((String l) => l.startsWith('TECH')), <String>[
        'TECH  mode to=app from=-',
        'TECH  mode to=background from=app',
        'TECH  handover to=service ok=true ms=820',
        'TECH  mode to=receive-only from=background',
      ]);
    });

    test('a wake writes its works and how long they took', () async {
      final _Platform platform = _Platform();
      int now = 0;
      ZenWake.platform = platform;
      ZenWake.nowMillis = () => now;
      await ZenDiagnosticsLog.attach(folder, source: 'ui');
      final Completer<void> slow = Completer<void>();
      ZenWake.beat(
        'mailbox-poll',
        const Duration(minutes: 5),
        () => slow.future,
      );
      ZenWake.beat('watchdog', const Duration(minutes: 5), () async {});
      now = 5 * 60 * 1000;
      // The beat's alarm: the latest one planned.
      final Future<void> wake = platform.fires.last() as Future<void>;
      slow.complete();
      await wake;
      ZenWake.after('reminder', Duration.zero, () {});
      platform.fires.last();
      await ZenDiagnosticsLog.settled;
      final List<String> tech = (await ZenDiagnosticsLog.entries())
          .map((String e) => e.substring(e.indexOf('] ') + 2))
          .where((String l) => l.startsWith('TECH'))
          .toList();
      expect(tech, hasLength(2));
      expect(
        tech.first,
        matches(
          RegExp(
            r'^TECH  beat ms=\d+ jobs=(mailbox-poll:\d+,watchdog:\d+|watchdog:\d+,mailbox-poll:\d+)$',
          ),
        ),
      );
      expect(tech.last, matches(RegExp(r'^TECH  wake job=reminder ms=\d+$')));
    });

    test('exit records: oldest first, only new ones, by name', () {
      final int at = DateTime(2026, 10, 27, 1, 30).millisecondsSinceEpoch;
      final List<String> lines = exitLines(<Object?>[
        <Object?, Object?>{
          'at': at + 60000,
          'reason': 6,
          'importance': 125,
          'status': 0,
          'pssKb': 180000,
          'rssKb': 240000,
        },
        <Object?, Object?>{
          'at': at,
          'reason': 3,
          'importance': 400,
          'status': 9,
          'pssKb': 1,
          'rssKb': 2,
        },
        <Object?, Object?>{'at': at - 1, 'reason': 10},
      ], since: at - 1);
      expect(lines, <String>[
        'TECH  exit at=2026-10-27T01:30:00 reason=low-memory '
            'importance=cached status=9 pssKb=1 rssKb=2',
        'TECH  exit at=2026-10-27T01:31:00 reason=anr '
            'importance=foreground-service status=0 pssKb=180000 rssKb=240000',
      ]);
    });
  });

  group('privacy', () {
    test('no technical line holds text, names, addresses, keys or paths', () {
      const String name = 'Ala Kowalska';
      final List<String> lines = <String>[
        nodeSampleLine(_nodeInfo),
        formatTechLine('wake', <String, Object?>{
          'job': 'tls://203.0.113.5:443',
          'peer': '200:1111:2222:3333:4444:5555:6666:7777',
          'name': name,
          'file': r'C:\Users\Robert\Zen\zdjęcie.jpg',
          'key': 'a' * 64,
          'text': 'Cześć, jak się masz?',
          'jobs': <String, Object?>{
            name: 1,
            'ok': 'tls://x',
            'mailbox-poll': 5,
          },
          'list': <Object?>['ok', 'a b', '/data/user/0/com.roj.zen/files'],
          'Bad Key': 1,
        }),
        formatTechLine('Tekst wiadomości', const <String, Object?>{}),
        ...exitLines(<Object?>[
          <Object?, Object?>{
            'at': 1,
            'reason': 6,
            'description': 'Input dispatching timed out ($name)',
          },
        ]),
      ];
      final RegExp value = RegExp(
        r'^(-|\?|-?\d+(\.\d)?|true|false|\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d'
        r'|[a-z?][a-z0-9-]*(:(\d+|\?))?(,[a-z?][a-z0-9-]*(:(\d+|\?))?)*)$',
      );
      final List<RegExp> forbidden = <RegExp>[
        RegExp('://'),
        RegExp(r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}'),
        RegExp(r'[23][0-9a-f]{2}:[0-9a-f]{1,4}:'),
        RegExp(r'[0-9a-fA-F]{16}'),
        RegExp(r'[/\\]'),
        RegExp(r'[^\x20-\x7e]'),
        RegExp('Ala|Kowalska|Robert|zdj|Cze|masz|Input'),
      ];
      for (final String line in lines) {
        expect(line, startsWith('TECH  '));
        final List<String> parts = line.substring(6).split(' ');
        expect(parts.first, matches(RegExp(r'^([a-z][a-z0-9-]*|\?)$')));
        for (final String field in parts.skip(1)) {
          final int eq = field.indexOf('=');
          expect(eq, greaterThan(0), reason: line);
          expect(
            field.substring(0, eq),
            matches(RegExp(r'^([a-z][A-Za-z0-9]*|\?)$')),
          );
          expect(field.substring(eq + 1), matches(value), reason: line);
        }
        for (final RegExp pattern in forbidden) {
          expect(pattern.hasMatch(line), isFalse, reason: '$pattern in $line');
        }
      }
      expect(lines[1], contains('jobs=?:1,ok:?,mailbox-poll:5'));
      expect(lines[1], contains('list=ok,?,?'));
    });
  });
}

/// A node's info as the bridge gives it: everything a log must not keep
/// (keys, addresses, peer URIs, errors with addresses) beside the numbers.
final Map<String, dynamic> _nodeInfo = <String, dynamic>{
  'handle': 3,
  'publicKey': 'f' * 64,
  'address': '200:1111:2222:3333:4444:5555:6666:7777',
  'subnet': '300:1111:2222:3333::/64',
  'routingEntries': 40,
  'listen': <String>['tls://0.0.0.0:0'],
  'peers': <Map<String, dynamic>>[
    <String, dynamic>{
      'uri': 'tls://203.0.113.5:443?key=abcd',
      'up': true,
      'inbound': false,
      'ip': '201:aaaa:bbbb::1',
      'latency': '40ms',
    },
    <String, dynamic>{
      'uri': 'tcp://[fe80::1%wlan0]:9001',
      'up': true,
      'inbound': true,
    },
    <String, dynamic>{
      'uri': 'quic://198.51.100.7:9001',
      'up': false,
      'inbound': false,
      'lastError': 'dial 198.51.100.7: refused',
    },
  ],
  'config': <String, dynamic>{
    'Peers': <String>['tls://203.0.113.5:443'],
  },
  'peerPoolCount': 12,
  'selectedPeer': 'tls://203.0.113.5:443',
  'selectedPeerLatency': '40ms',
  'pqKey': 'e' * 64,
  'goMemory': <String, dynamic>{
    'heapBytes': 8 * 1024 * 1024,
    'heapGoalBytes': 16 * 1024 * 1024,
    'mappedBytes': 30 * 1024 * 1024,
    'releasedBytes': 10 * 1024 * 1024,
    'retainedBytes': 20 * 1024 * 1024,
    'memoryLimitBytes': 0,
    'goroutines': 210,
    'gcCycles': 55,
  },
  'traffic': <String, dynamic>{
    'publicRxBytes': 10 * 1024 * 1024,
    'publicTxBytes': 9 * 1024 * 1024,
    'localRxBytes': 512 * 1024,
    'localTxBytes': 256 * 1024,
    'transitBytes': 4 * 1024 * 1024,
    'transitRate': 900,
    'transitWindowSeconds': 60,
    'rxRate': 1500,
    'txRate': 1400,
    'ownSignalRxBytes': 64 * 1024,
    'ownSignalTxBytes': 32 * 1024,
    'ownRelayRxBytes': 128 * 1024,
    'ownRelayTxBytes': 96 * 1024,
    'ownOtherRxBytes': 0,
    'transitGuard': <String, dynamic>{
      'hourBytes': 2 * 1024 * 1024,
      'guardedBytes': 5,
      'holds': 2,
      'holdSecondsLeft': 540,
      'lastHoldRate': 3000,
      'heldSecondsTotal': 1200,
      'holding': true,
      'setAside': 1,
      'keepsLink': true,
    },
    'doorHost': <String, dynamic>{
      'publicRxBytes': 300 * 1024,
      'publicTxBytes': 200 * 1024,
      'doorRxBytes': 1,
      'doorTxBytes': 1,
    },
  },
};

/// Wakes that run when the test says.
final class _Platform implements ZenWakePlatform {
  final List<FutureOr<void> Function()> fires = <FutureOr<void> Function()>[];

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) {
    fires.add(fire);
    return _Timer();
  }

  @override
  Future<void> hold(String tag, Duration duration) async {}

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {}

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();
}

final class _Timer implements WakeTimer {
  @override
  bool get isActive => true;

  @override
  void cancel() {}
}
