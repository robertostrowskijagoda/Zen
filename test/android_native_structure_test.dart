import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The Kotlin side has no test run of its own, so what the phone logs of an
// earlier release showed (a wake broadcast that did its work on the main
// thread, an Activity kept alive by a bridge, a heavy check at start) is held
// by reading the source: each guard names the thread or the cleanup that a
// change must not lose. They say nothing of how the code behaves; a phone
// still has to confirm that.

const String _kotlin = 'android/app/src/main/kotlin/com/roj/zen';

String _source(String name) => File('$_kotlin/$name').readAsStringSync();

/// The text of the function that starts at [signature], up to the next
/// function of the same indentation.
String _function(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: signature);
  final RegExp next = RegExp(r'\n    (override |private |internal )?fun ');
  final Match? end = next.firstMatch(
    source.substring(start + signature.length),
  );
  return end == null
      ? source.substring(start)
      : source.substring(start, start + signature.length + end.start);
}

void main() {
  group('the engine of the app lets go of every bridge', () {
    String configure() => _function(
      _source('MainActivity.kt'),
      'override fun configureFlutterEngine',
    );
    String cleanUp() => _function(
      _source('MainActivity.kt'),
      'override fun cleanUpFlutterEngine',
    );

    test('every bridge registered on the engine is unregistered from it', () {
      final List<String> registered = <String>[
        for (final RegExpMatch m in RegExp(
          r'(\w+)\.register\(flutterEngine',
        ).allMatches(configure()))
          m.group(1)!,
      ];
      expect(registered, hasLength(greaterThanOrEqualTo(13)));
      for (final String bridge in registered) {
        expect(
          cleanUp(),
          contains('$bridge.unregister(flutterEngine)'),
          reason: '$bridge keeps the Activity once the engine is gone',
        );
      }
    });

    test('the background service takes the node over when the engine goes', () {
      expect(cleanUp(), contains('ZenPower.appEngineGone(this)'));
    });

    test('every bridge object really has an unregister', () {
      for (final String name in <String>[
        'ZenCallBridge',
        'ZenSecurityBridge',
        'ZenUpdateBridge',
        'ZenSystemBridge',
        'ZenMulticastLock',
        'ZenNearbyBridge',
        'ZenWifiDirectBridge',
        'ZenBluetoothLinkBridge',
        'ZenPermissionsBridge',
        'ZenLocationBridge',
        'ZenAlarmShortcut',
        'ZenVideoBridge',
        'ZenPower',
      ]) {
        expect(
          _source('$name.kt'),
          contains(RegExp(r'fun unregister\(\w+: FlutterEngine\)')),
          reason: name,
        );
      }
    });
  });

  group('work that can take long stays off the main thread', () {
    test('a wake alarm arrives on a thread of its own and is answered '
        'asynchronously', () {
      final String power = _source('ZenPower.kt');
      expect(power, contains('HandlerThread("zen-wake")'));
      final String registration = power.substring(
        power.indexOf('ContextCompat.registerReceiver('),
      );
      expect(
        registration.substring(
          0,
          registration.indexOf('RECEIVER_NOT_EXPORTED'),
        ),
        contains('wakeHandler'),
        reason: 'the receiver is given the wake thread, not the main one',
      );
      expect(power, contains('goAsync()'));
    });

    test('the task of a wake (the radio rotation too) runs on an executor', () {
      final String power = _source('ZenPower.kt');
      expect(power, contains('Executors.newSingleThreadExecutor'));
      expect(power, contains('taskExecutor.execute {'));
      expect(power, contains('native()'));
      // The rotation of the nearby token is such a task, not inline work.
      final String nearby = _source('ZenNearbyBridge.kt');
      expect(nearby, contains('ZenPower.scheduleNative('));
      expect(nearby, contains('ROTATION_ALARM'));
    });

    test('the integrity check reads /proc on a worker, not the platform '
        'thread', () {
      final String security = _source('ZenSecurityBridge.kt');
      expect(security, contains('Thread(it, "zen-integrity")'));
      final String check = security.substring(
        security.indexOf('INTEGRITY_CHANNEL).setMethodCallHandler'),
      );
      expect(
        check.indexOf('checks.execute'),
        lessThan(check.indexOf('integrity(app, mainStack)')),
        reason: 'integrity() runs inside the worker',
      );
      expect(check, contains('main.post {'));
    });

    test('an update is copied into the installer off the main thread', () {
      final String update = _source('ZenUpdateBridge.kt');
      expect(update, contains('Thread(it, "zen-update")'));
      expect(update, contains('io.execute {'));
      // The "install" call goes through the helper that runs on [io] ...
      final String call = update.substring(update.indexOf('"install" -> {'));
      expect(
        call.indexOf('offMain(call.method, result) {'),
        lessThan(call.indexOf('install(app, File(path))')),
        reason: 'install() is called from offMain',
      );
      // ... and the copy into the installer session is where it was.
      expect(update, contains('input.copyTo(out)'));
    });
  });
}
