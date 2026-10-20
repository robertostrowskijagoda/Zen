import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/health/clock_skew_tracker.dart';
import 'package:zen/src/features/health/health_report.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/shell/presentation/health_screen.dart';

const int _minute = 60 * 1000;

HealthInputs _healthy({
  HealthNetState net = HealthNetState.active,
  int peers = 5,
  bool android = true,
  bool? background = true,
  Map<ZenPermission, bool>? granted,
  Duration? skew = Duration.zero,
  StorageInfo? storage = const StorageInfo(
    freeBytes: 20 * 1024 * 1024 * 1024,
    totalBytes: 64 * 1024 * 1024 * 1024,
  ),
}) => HealthInputs(
  net: net,
  peers: peers,
  localAddress: '200:abcd::1',
  isAndroid: android,
  backgroundRunning: background,
  permissions: PermissionsSnapshot(
    granted:
        granted ??
        <ZenPermission, bool>{
          ZenPermission.notifications: true,
          ZenPermission.battery: true,
        },
  ),
  clockSkew: skew,
  storage: storage,
);

/// Two friends, two messages each, all 14 minutes behind this phone.
void _feed(ClockSkewTracker t) {
  const int now = 1700000000000;
  for (final String peer in <String>['a', 'b']) {
    for (int k = 0; k < 2; k++) {
      t.observe(peer, now + k - 14 * _minute, now + k);
    }
  }
}

ClockSkewTracker _skewedTracker() {
  final ClockSkewTracker t = ClockSkewTracker();
  _feed(t);
  return t;
}

final class _Platform implements PermissionsPlatform {
  _Platform(this.granted);

  final Map<ZenPermission, bool> granted;

  @override
  bool get hasAnything => true;

  @override
  bool get hasBluetooth => false;

  @override
  Future<PermissionsSnapshot> check() async => PermissionsSnapshot(
    applicable: granted.keys.toList(),
    granted: Map<ZenPermission, bool>.of(granted),
  );

  @override
  Future<void> request(ZenPermission permission) async {}

  @override
  Future<void> openSettings(ZenPermission permission) async {}

  @override
  Stream<bool> get bluetoothChanges => const Stream<bool>.empty();
}

final class _Probe implements HealthProbe {
  _Probe({this.free});

  final StorageInfo? free;

  @override
  Future<StorageInfo?> storage() async => free;

  @override
  Future<bool?> backgroundServiceRunning() async => true;
}

void main() {
  group('health report', () {
    test('a healthy phone has no problems', () {
      final HealthReport r = buildHealthReport(_healthy());
      expect(r.worst, HealthLevel.ok);
      expect(r.problems, 0);
      expect(r.items.map((HealthItem i) => i.id), <String>[
        'network',
        'peers',
        'background',
        'notifications',
        'battery',
        'clock',
        'storage',
      ]);
    });

    test('Android-only lines are left out elsewhere', () {
      final HealthReport r = buildHealthReport(_healthy(android: false));
      expect(r.item('background'), isNull);
      expect(r.item('battery'), isNull);
      expect(r.item('network'), isNotNull);
    });

    test('a stopped or failed node is a problem; no neighbours a warning', () {
      expect(
        buildHealthReport(
          _healthy(net: HealthNetState.stopped),
        ).item('network')!.level,
        HealthLevel.bad,
      );
      expect(
        buildHealthReport(
          _healthy(net: HealthNetState.failed),
        ).item('network')!.level,
        HealthLevel.bad,
      );
      final HealthReport lonely = buildHealthReport(_healthy(peers: 0));
      expect(lonely.item('peers')!.level, HealthLevel.warn);
      expect(lonely.worst, HealthLevel.warn);
    });

    test('notifications off is a problem with a way to fix it', () {
      final HealthItem n = buildHealthReport(
        _healthy(
          granted: <ZenPermission, bool>{
            ZenPermission.notifications: false,
            ZenPermission.battery: false,
          },
        ),
      ).item('notifications')!;
      expect(n.level, HealthLevel.bad);
      expect(n.fix, HealthFix.permissions);
      final HealthItem b = buildHealthReport(
        _healthy(
          granted: <ZenPermission, bool>{
            ZenPermission.notifications: true,
            ZenPermission.battery: false,
          },
        ),
      ).item('battery')!;
      expect(b.level, HealthLevel.warn);
    });

    test('the background service not running is a warning', () {
      final HealthReport r = buildHealthReport(_healthy(background: false));
      expect(r.item('background')!.level, HealthLevel.warn);
      expect(r.item('background')!.fix, HealthFix.appSettings);
      expect(
        buildHealthReport(_healthy(background: null)).item('background')!.level,
        HealthLevel.unknown,
      );
    });

    test('the clock: fine inside two minutes, warned beyond', () {
      expect(
        buildHealthReport(
          _healthy(skew: const Duration(seconds: 100)),
        ).item('clock')!.level,
        HealthLevel.ok,
      );
      final HealthItem fast = buildHealthReport(
        _healthy(skew: const Duration(minutes: -14)),
      ).item('clock')!;
      expect(fast.level, HealthLevel.bad);
      expect(fast.detail, contains('spieszy się o 14 min'));
      final HealthItem slow = buildHealthReport(
        _healthy(skew: const Duration(minutes: 3)),
      ).item('clock')!;
      expect(slow.level, HealthLevel.warn);
      expect(slow.detail, contains('spóźnia o 3 min'));
      expect(
        buildHealthReport(_healthy(skew: null)).item('clock')!.level,
        HealthLevel.unknown,
      );
    });

    test('storage near its limits', () {
      HealthLevel level(int bytes, int total) => buildHealthReport(
        _healthy(
          storage: StorageInfo(freeBytes: bytes, totalBytes: total),
        ),
      ).item('storage')!.level;
      const int mb = 1024 * 1024;
      expect(level(30 * mb, 64 * 1024 * mb), HealthLevel.bad);
      expect(level(200 * mb, 64 * 1024 * mb), HealthLevel.warn);
      expect(level(2 * 1024 * mb, 64 * 1024 * mb), HealthLevel.warn);
      expect(level(10 * 1024 * mb, 64 * 1024 * mb), HealthLevel.ok);
      expect(
        buildHealthReport(_healthy(storage: null)).item('storage')!.level,
        HealthLevel.unknown,
      );
    });

    test('df output is read', () {
      final StorageInfo? s = parseDfOutput(
        'Filesystem 1K-blocks Used Available Use% Mounted on\n'
        '/dev/block/dm-5 112000000 80000000 32000000 72% /data\n',
      );
      expect(s, isNotNull);
      expect(s!.freeBytes, 32000000 * 1024);
      expect(s.totalBytes, 112000000 * 1024);
      expect(parseDfOutput('nonsense'), isNull);
      expect(formatBytes(1536 * 1024 * 1024), '1.5 GB');
      expect(formatBytes(230 * 1024 * 1024), '230 MB');
    });
  });

  group('clock skew tracker', () {
    const int now = 1700000000000;

    test('a phone running 14 minutes fast is noticed from two friends', () {
      final ClockSkewTracker t = ClockSkewTracker();
      // Friends' messages arrive a second after they were written, by the
      // phone's clock that is 14 minutes ahead (two each: one may be late).
      t.observe('a', now - 14 * _minute - 1000, now);
      t.observe('a', now - 14 * _minute - 800, now + 60000);
      expect(t.estimate, isNull, reason: 'one friend is not enough');
      t.observe('b', now - 14 * _minute - 2000, now + 5000);
      t.observe('b', now - 14 * _minute - 900, now + 65000);
      expect(t.skewed, isTrue);
      expect(t.phoneAhead, isTrue);
      expect(t.estimate!.inMinutes, -14);
    });

    test('a phone running behind: one message of a friend is enough', () {
      final ClockSkewTracker t = ClockSkewTracker();
      t.observe('a', now + 15 * _minute, now);
      t.observe('b', now + 15 * _minute + 3000, now);
      expect(t.skewed, isTrue);
      expect(t.phoneAhead, isFalse);
    });

    test('a correct clock stays quiet, a late relayed message too', () {
      final ClockSkewTracker t = ClockSkewTracker();
      t.observe('a', now - 800, now);
      t.observe('b', now - 1500, now);
      // A message that waited 3 hours on a relay says nothing about the
      // clock: the same friend's live message wins.
      t.observe('a', now - 3 * 60 * _minute, now);
      expect(t.skewed, isFalse);
    });

    test('a flush of late mail with different delays is not a verdict', () {
      final ClockSkewTracker t = ClockSkewTracker();
      t.observe('a', now - 5 * 60 * _minute, now);
      t.observe('a', now - 5 * 60 * _minute - 1000, now);
      t.observe('b', now - 2 * 60 * _minute, now);
      t.observe('b', now - 2 * 60 * _minute - 1000, now);
      expect(t.skewed, isFalse);
      expect(t.estimate, isNull, reason: 'the friends do not agree');
    });

    test('listeners hear a change of the verdict', () {
      final ClockSkewTracker t = ClockSkewTracker(minPeers: 1);
      int calls = 0;
      t.addListener(() => calls++);
      t.observe('a', now + 10 * _minute, now);
      expect(calls, 1);
      t.clear();
      expect(t.estimate, isNull);
      expect(calls, 2);
    });
  });

  group('screens', () {
    Widget app(List<Override> overrides, Widget home) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: ZenTheme.dark(), home: home),
    );

    ClockSkewTracker skewed() {
      return _skewedTracker();
    }

    testWidgets('"Dlaczego nie działa?" lists the problems with their fixes', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(<Override>[
          permissionsPlatformProvider.overrideWithValue(
            _Platform(<ZenPermission, bool>{
              ZenPermission.notifications: false,
              ZenPermission.battery: false,
            }),
          ),
          healthProbeProvider.overrideWithValue(
            _Probe(
              free: const StorageInfo(
                freeBytes: 10 * 1024 * 1024,
                totalBytes: 64 * 1024 * 1024 * 1024,
              ),
            ),
          ),
          clockSkewTrackerProvider.overrideWithValue(skewed()),
        ], const HealthScreen(isAndroid: true)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('health-screen')), findsOneWidget);
      for (final String id in <String>[
        'network', 'peers', 'background', 'notifications', 'battery', //
        'clock', 'storage',
      ]) {
        expect(find.byKey(Key('health-row-$id')), findsOneWidget, reason: id);
      }
      expect(find.textContaining('spieszy się o 14 min'), findsOneWidget);
      expect(find.byKey(const Key('health-fix-notifications')), findsOneWidget);
      expect(find.byKey(const Key('health-summary')), findsOneWidget);

      await tester.tap(find.byKey(const Key('health-fix-notifications')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('permissions-screen')), findsOneWidget);
    });

    testWidgets('the report stays readable at 1.3x text', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            permissionsPlatformProvider.overrideWithValue(
              _Platform(<ZenPermission, bool>{
                ZenPermission.notifications: false,
              }),
            ),
            healthProbeProvider.overrideWithValue(_Probe()),
            clockSkewTrackerProvider.overrideWithValue(skewed()),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: const HealthScreen(isAndroid: true),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      // No overflow exception was thrown while laying out.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the clock banner shows only when skewed and opens the '
        'report', (WidgetTester tester) async {
      final ClockSkewTracker tracker = ClockSkewTracker();
      await tester.pumpWidget(
        app(<Override>[
          clockSkewTrackerProvider.overrideWithValue(tracker),
          permissionsPlatformProvider.overrideWithValue(
            _Platform(<ZenPermission, bool>{}),
          ),
          healthProbeProvider.overrideWithValue(_Probe()),
        ], const Scaffold(body: ClockSkewBanner())),
      );
      expect(find.byKey(const Key('clock-skew-banner')), findsNothing);

      _feed(tracker);
      await tester.pump();
      expect(find.byKey(const Key('clock-skew-banner')), findsOneWidget);
      expect(
        find.textContaining('Twój zegar spieszy się o 14 min'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('clock-skew-banner')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('health-screen')), findsOneWidget);
    });
  });
}
