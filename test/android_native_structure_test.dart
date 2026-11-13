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
        'ZenAutofillBridge',
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

  test('a secret copied from Zen is marked sensitive on the clipboard', () {
    final String system = _source('ZenSystemBridge.kt');
    expect(system, contains('"copySensitive" ->'));
    final String copy = _function(system, 'private fun copySensitive');
    expect(copy, contains('ClipDescription.EXTRA_IS_SENSITIVE'));
    expect(copy, contains('Build.VERSION_CODES.TIRAMISU'));
    expect(copy, contains('"android.content.extra.IS_SENSITIVE"'));
    expect(
      copy.indexOf('description.extras'),
      lessThan(copy.indexOf('setPrimaryClip(clip)')),
      reason: 'the mark is on the clip before it goes to the clipboard',
    );
  });

  test('the clipboard is emptied without reading it first, so it works '
      'from the background', () {
    final String system = _source('ZenSystemBridge.kt');
    expect(system, contains('"clearSensitive" ->'));
    final String clear = _function(system, 'private fun clearSensitive');
    expect(clear, contains('Build.VERSION_CODES.P'));
    expect(
      clear.indexOf('Build.VERSION_CODES.P'),
      lessThan(clear.indexOf('clearPrimaryClip()')),
      reason: 'clearPrimaryClip exists from Android 9 on',
    );
    expect(clear, contains('setPrimaryClip(ClipData.newPlainText("", ""))'));
    expect(clear, isNot(contains('getPrimaryClip')));
    expect(clear, isNot(contains('primaryClip ')));
  });
  group('the autofill gives nothing away and fails closed', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    String element(String name) {
      final int at = manifest.indexOf('android:name="$name"');
      expect(at, greaterThanOrEqualTo(0), reason: name);
      final int start = manifest.lastIndexOf('<', at);
      final String rest = manifest.substring(start);
      final int end = rest.startsWith('<service')
          ? rest.indexOf('</service>')
          : rest.indexOf('/>');
      return rest.substring(0, end);
    }

    test('the service is bound only by the system, through Android\'s '
        'autofill action and its own minimal configuration', () {
      final String service = element('.ZenAutofillService');
      expect(
        service,
        contains(
          'android:permission="android.permission.BIND_AUTOFILL_SERVICE"',
        ),
      );
      expect(service, contains('android.service.autofill.AutofillService'));
      expect(service, contains('android:resource="@xml/zen_autofill_service"'));
      final String config = File(
        'android/app/src/main/res/xml/zen_autofill_service.xml',
      ).readAsStringSync();
      expect(config, contains('<autofill-service'));
      // No accessibility-based compatibility mode for browsers.
      expect(config, isNot(contains('compatibility-package')));
    });

    test('the picker\'s activity is not open to other apps and has no '
        'history of its own', () {
      final String activity = element('.ZenAutofillActivity');
      expect(activity, contains('android:exported="false"'));
      expect(activity, isNot(contains('intent-filter')));
      expect(activity, isNot(contains('noHistory="true"')));
      expect(activity, contains('Theme.Translucent'));
    });

    test('a suggestion carries no value, only the authentication, in an '
        'immutable intent the requesting app cannot change', () {
      final String service = _source('ZenAutofillService.kt');
      // The fields the entry will fill, each named without a value, on
      // both ways of building a suggestion (Android 13+ and before).
      expect(service, contains('ids.forEach { setField(it, null) }'));
      expect(service, contains('ids.forEach { setValue(it, null) }'));
      expect(RegExp(r'setField\(').allMatches(service), hasLength(1));
      expect(RegExp(r'setValue\(').allMatches(service), hasLength(1));
      expect(service, isNot(contains('AutofillValue')));
      expect(service, isNot(contains('Field.Builder')));
      expect(service, contains('setAuthentication(sender)'));
      expect(
        service,
        contains(
          'PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE',
        ),
      );
      expect(service, isNot(contains('FLAG_MUTABLE')));
      // Saving is not offered: no SaveInfo declared.
      expect(service, isNot(contains('setSaveInfo')));
      expect(service, isNot(contains('SaveInfo.Builder')));
      // Nothing is read from disk on this side.
      for (final String read in <String>[
        'SharedPreferences',
        'openFileInput',
        'File(',
        'FlutterEngine',
      ]) {
        expect(service, isNot(contains(read)), reason: read);
      }
      // The page's address only from a known browser; Zen's own forms never.
      expect(service, contains(RegExp(r'trustedWebOrigin\(\s*client,')));
      expect(service, contains('if (client == packageName)'));
      expect(
        service,
        contains('Build.VERSION.SDK_INT < Build.VERSION_CODES.P'),
      );
    });

    test('every way out of the request but a picked entry is '
        'RESULT_CANCELED', () {
      final String activity = _source('ZenAutofillActivity.kt');
      final String create = _function(activity, 'override fun onCreate');
      expect(create, contains('setResult(Activity.RESULT_CANCELED)'));
      expect(
        create.indexOf('setResult(Activity.RESULT_CANCELED)'),
        lessThan(create.indexOf('ZenAutofillBridge.open(')),
        reason: 'the answer is "nothing" until an entry comes',
      );
      expect(create, contains('savedInstanceState != null'));
      expect(create, contains('ZenAutofillBridge.cancel(this)'));
      expect(
        _function(activity, 'override fun onRestart'),
        contains('ZenAutofillBridge.cancel(this)'),
      );
      final String complete = _function(activity, 'fun complete');
      expect(complete, contains('if (dataset != null)'));
      expect(complete, contains('setResult(Activity.RESULT_CANCELED)'));
      expect('RESULT_OK'.allMatches(activity), hasLength(1));

      final String bridge = _source('ZenAutofillBridge.kt');
      expect(bridge, contains('TIMEOUT_MS = 60_000L'));
      expect(bridge, contains('Runnable { end(null) }'));
      // A fill for a request no longer open fills nothing.
      expect(bridge, contains('open.id != id'));
      expect(bridge, contains('end(null)'));
      expect(bridge, contains('filterTouchesWhenObscured = on'));
    });

    test('the log says nothing of the app, the page or the entry', () {
      int logged = 0;
      for (final String name in <String>[
        'ZenAutofillService.kt',
        'ZenAutofillActivity.kt',
        'ZenAutofillBridge.kt',
      ]) {
        for (final RegExpMatch m in RegExp(
          r'Log\.\w\((.*)\)',
        ).allMatches(_source(name))) {
          logged++;
          final String line = m.group(1)!;
          for (final String word in <String>[
            'package',
            'webDomain',
            'domain',
            'login',
            'password',
            'label',
            'request',
            'id)',
            'error)',
          ]) {
            expect(line, isNot(contains(word)), reason: '$name: $line');
          }
        }
      }
      expect(logged, greaterThanOrEqualTo(3));
    });
  });
}
