import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';
import 'package:zen/src/features/passwords/password_setup.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_setup_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_screen.dart';
import 'package:zen/src/features/security/app_security_service.dart';

// The password manager's setup: on Android whether Zen is the phone's
// autofill service and what each installed browser needs; elsewhere an
// honest page without buttons that do nothing.

/// The device as the setup sees it, and every call it got.
final class FakeSetupPlatform implements PasswordSetupPlatform {
  FakeSetupPlatform({
    this.fillsOtherApps = true,
    this.state = PasswordAutofillState.off,
    List<BrowserProbe>? installed,
  }) : installed = installed ?? <BrowserProbe>[];

  @override
  bool fillsOtherApps;
  PasswordAutofillState state;
  List<BrowserProbe> installed;

  int reads = 0;
  int systemOpened = 0;
  final List<String> browsersOpened = <String>[];
  List<String>? askedKnown;
  Set<String>? askedSwitches;

  @override
  Future<PasswordAutofillState> autofill() async {
    reads++;
    return state;
  }

  @override
  Future<bool> openAutofillSettings() async {
    systemOpened++;
    return true;
  }

  @override
  Future<List<BrowserProbe>> browsers(
    List<String> known, {
    required Set<String> switches,
  }) async {
    askedKnown = known;
    askedSwitches = switches;
    return installed;
  }

  @override
  Future<bool> openBrowserSettings(String packageName) async {
    browsersOpened.add(packageName);
    return true;
  }
}

const BrowserProbe _chromeOff = BrowserProbe(
  packageName: 'com.android.chrome',
  label: 'Chrome',
  state: BrowserSwitchState.off,
  canOpenSettings: true,
);

/// A mark that turns text around (a name may hide one).
final String _turn = String.fromCharCode(0x202e);

List<BrowserProbe> _several() => <BrowserProbe>[
  // Unknown to Zen: left out.
  const BrowserProbe(packageName: 'com.example.browser', label: 'Inna'),
  const BrowserProbe(
    packageName: 'org.mozilla.firefox',
    label: 'Firefox',
    // A browser without a switch never shows one, whatever is said.
    state: BrowserSwitchState.on,
    canOpenSettings: true,
  ),
  BrowserProbe(packageName: 'com.vivaldi.browser', label: ' Vivaldi$_turn\n'),
  const BrowserProbe(
    packageName: 'com.brave.browser',
    state: BrowserSwitchState.on,
    canOpenSettings: true,
  ),
  _chromeOff,
  const BrowserProbe(packageName: 'com.microsoft.emmx', label: 'Edge'),
  const BrowserProbe(packageName: 'com.kiwibrowser.browser', label: 'Kiwi'),
];

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _pumpSetup(
  WidgetTester tester,
  FakeSetupPlatform platform, {
  bool withImport = false,
}) async {
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        passwordSetupPlatformProvider.overrideWithValue(platform),
        passwordVaultServiceProvider.overrideWithValue(
          PasswordVaultService(disk: MemoryLedgerDisk()),
        ),
      ],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        home: PasswordSetupScreen(withImport: withImport),
      ),
    ),
  );
  await _frames(tester);
}

Finder _line(String id) => find.byKey(Key('password-setup-browser-line-$id'));

String _text(WidgetTester tester, Finder f) => tester.widget<Text>(f).data!;

void main() {
  group('the state', () {
    test('where Zen fills nothing, nothing is asked of the device', () async {
      final FakeSetupPlatform platform = FakeSetupPlatform(
        fillsOtherApps: false,
        installed: <BrowserProbe>[_chromeOff],
      );
      final PasswordSetupState state = await readPasswordSetup(platform);
      expect(state.fillsOtherApps, isFalse);
      expect(state.supported, isFalse);
      expect(state.browsers, isEmpty);
      expect(platform.reads, 0);
      expect(platform.askedKnown, isNull);
    });

    test('an Android that cannot fill: no browsers are looked at', () async {
      final FakeSetupPlatform platform = FakeSetupPlatform(
        state: PasswordAutofillState.unsupported,
        installed: <BrowserProbe>[_chromeOff],
      );
      final PasswordSetupState state = await readPasswordSetup(platform);
      expect(state.fillsOtherApps, isTrue);
      expect(state.supported, isFalse);
      expect(state.browsers, isEmpty);
      expect(platform.askedKnown, isNull);
    });

    test('the installed browsers Zen knows, in its order, each with what it '
        'needs, its state and its line', () async {
      final FakeSetupPlatform platform = FakeSetupPlatform(
        installed: _several(),
      );
      final PasswordSetupState state = await readPasswordSetup(platform);
      expect(state.supported, isTrue);
      expect(state.autofill, PasswordAutofillState.off);
      // Every known browser is asked about; only those with a switch get it
      // read.
      expect(platform.askedKnown, <String>[
        for (final KnownBrowser b in kKnownBrowsers) b.packageName,
      ]);
      expect(platform.askedSwitches, <String>{
        'com.android.chrome',
        'com.chrome.beta',
        'com.chrome.dev',
        'com.chrome.canary',
        'org.chromium.chrome',
        'com.brave.browser',
        'com.vivaldi.browser',
      });

      final Map<String, BrowserSetup> by = <String, BrowserSetup>{
        for (final BrowserSetup b in state.browsers) b.browser.packageName: b,
      };
      expect(
        state.browsers.map((BrowserSetup b) => b.browser.packageName),
        <String>[
          'com.android.chrome',
          'com.brave.browser',
          'com.vivaldi.browser',
          'com.microsoft.emmx',
          'com.kiwibrowser.browser',
          'org.mozilla.firefox',
        ],
      );

      final BrowserSetup chrome = by['com.android.chrome']!;
      expect(chrome.name, 'Chrome');
      expect(chrome.state, BrowserSwitchState.off);
      expect(chrome.needsAction, isTrue);
      expect(chrome.canOpenSettings, isTrue);
      expect(chrome.line, startsWith('Wyłączone'));
      expect(chrome.steps, contains('„Autofill using another service”'));
      expect(chrome.steps, contains('„Autofill services”'));

      final BrowserSetup brave = by['com.brave.browser']!;
      // No name from the system: Zen's own.
      expect(brave.name, 'Brave');
      expect(brave.state, BrowserSwitchState.on);
      expect(brave.needsAction, isFalse);
      expect(brave.line, startsWith('Gotowe'));

      final BrowserSetup vivaldi = by['com.vivaldi.browser']!;
      expect(vivaldi.name, 'Vivaldi');
      expect(vivaldi.state, BrowserSwitchState.unknown);
      expect(vivaldi.needsAction, isTrue);
      expect(vivaldi.canOpenSettings, isFalse);
      expect(vivaldi.line, startsWith('Nie udało się odczytać'));

      final BrowserSetup edge = by['com.microsoft.emmx']!;
      // Edge: needs Android's compatibility mode, which Zen does not take:
      // said honestly, no switch to look for.
      expect(edge.needs, BrowserAutofillNeeds.compatibilityMode);
      expect(edge.state, isNull);
      expect(edge.steps, isNull);
      expect(edge.needsAction, isFalse);
      expect(edge.line, startsWith('Zen może się tu nie pojawić'));
      expect(edge.line, contains('skopiuj login'));
      for (final String package in <String>[
        'com.microsoft.emmx',
        'com.sec.android.app.sbrowser',
        'com.opera.browser',
      ]) {
        expect(
          kKnownBrowsers
              .singleWhere((KnownBrowser b) => b.packageName == package)
              .needs,
          BrowserAutofillNeeds.compatibilityMode,
          reason: package,
        );
      }

      final BrowserSetup kiwi = by['com.kiwibrowser.browser']!;
      expect(kiwi.needs, BrowserAutofillNeeds.unverified);
      expect(kiwi.state, isNull);
      expect(kiwi.steps, isNull);
      expect(kiwi.line, contains('nie zna sprawdzonych kroków'));

      final BrowserSetup firefox = by['org.mozilla.firefox']!;
      expect(firefox.needs, BrowserAutofillNeeds.nothing);
      expect(firefox.state, isNull);
      expect(firefox.canOpenSettings, isFalse);
      expect(firefox.steps, isNull);
      expect(firefox.line, startsWith('Nic nie trzeba ustawiać'));
    });

    test('Zen\'s list is the autofill\'s list of browsers, and Android lets '
        'Zen see each of them', () {
      final String trust = File(
        'android/app/src/main/kotlin/com/roj/zen/ZenAutofillTrust.kt',
      ).readAsStringSync();
      final int start = trust.indexOf(
        'val autofillBrowsers: Map<String, List<String>> = mapOf(',
      );
      expect(start, greaterThanOrEqualTo(0));
      final String list = trust.substring(start, trust.indexOf('\n)\n', start));
      final Set<String> autofill = RegExp(
        r'"([A-Za-z0-9_.]+)" to listOf\(',
      ).allMatches(list).map((RegExpMatch m) => m.group(1)!).toSet();
      expect(autofill, isNotEmpty);
      final Set<String> known = <String>{
        for (final KnownBrowser b in kKnownBrowsers) b.packageName,
      };
      expect(known, autofill);
      expect(known.length, kKnownBrowsers.length, reason: 'each once');

      final String manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      for (final String package in known) {
        expect(
          manifest,
          contains('<package android:name="$package" />'),
          reason: package,
        );
      }
    });

    test('a copy of a browser that is not its maker\'s says so, and has '
        'nothing to set up', () async {
      final FakeSetupPlatform platform = FakeSetupPlatform(
        installed: <BrowserProbe>[
          const BrowserProbe(
            packageName: 'com.android.chrome',
            label: 'Chrome',
            state: BrowserSwitchState.off,
            canOpenSettings: true,
            signature: BrowserSignature.other,
          ),
          const BrowserProbe(
            packageName: 'org.mozilla.fennec_fdroid',
            label: 'Fennec',
            signature: BrowserSignature.other,
          ),
          const BrowserProbe(
            packageName: 'com.kiwibrowser.browser',
            label: 'Kiwi',
            signature: BrowserSignature.unconfirmed,
          ),
          const BrowserProbe(
            packageName: 'org.chromium.chrome',
            label: 'Chromium',
            state: BrowserSwitchState.off,
            signature: BrowserSignature.unconfirmed,
          ),
          const BrowserProbe(
            packageName: 'com.sec.android.app.sbrowser',
            label: 'Samsung Internet',
            signature: BrowserSignature.unconfirmed,
          ),
        ],
      );
      final PasswordSetupState state = await readPasswordSetup(platform);
      final Map<String, BrowserSetup> by = <String, BrowserSetup>{
        for (final BrowserSetup b in state.browsers) b.browser.packageName: b,
      };
      final BrowserSetup chrome = by['com.android.chrome']!;
      expect(chrome.signature, BrowserSignature.other);
      expect(chrome.line, startsWith('Ta kopia przeglądarki nie jest '));
      expect(chrome.line, contains('jak każdą inną aplikację'));
      expect(chrome.state, isNull);
      expect(chrome.canOpenSettings, isFalse);
      expect(chrome.steps, isNull);
      expect(chrome.needsAction, isFalse);
      expect(
        by['org.mozilla.fennec_fdroid']!.line,
        startsWith('Ta kopia przeglądarki nie jest podpisana przez jej twórcę'),
      );
      expect(
        by['com.kiwibrowser.browser']!.line,
        startsWith('Zen nie zna potwierdzonego podpisu'),
      );
      // Without a confirmed certificate: filled as an app, but its own
      // switch still decides whether it asks Zen at all.
      final BrowserSetup chromium = by['org.chromium.chrome']!;
      expect(chromium.line, startsWith('Zen nie zna potwierdzonego podpisu'));
      expect(chromium.state, BrowserSwitchState.off);
      expect(chromium.steps, isNotNull);
      // One that probably never asks Zen keeps the line on that.
      expect(
        by['com.sec.android.app.sbrowser']!.line,
        startsWith('Zen może się tu nie pojawić'),
      );
    });

    test('the Android side\'s answer is read defensively', () {
      expect(BrowserProbe.fromMap(null), isNull);
      expect(BrowserProbe.fromMap('com.android.chrome'), isNull);
      expect(BrowserProbe.fromMap(<String, Object?>{'label': 'x'}), isNull);
      expect(BrowserProbe.fromMap(<String, Object?>{'package': ''}), isNull);
      final BrowserProbe odd = BrowserProbe.fromMap(<String, Object?>{
        'package': 'com.android.chrome',
        'label': 7,
        'state': 2,
        'settings': 'yes',
      })!;
      expect(odd.label, isNull);
      expect(odd.state, BrowserSwitchState.unknown);
      expect(odd.canOpenSettings, isFalse);
      // No word on the signature: not taken for the maker's.
      expect(odd.signature, BrowserSignature.unconfirmed);
      for (final (Object? raw, BrowserSignature want)
          in <(Object?, BrowserSignature)>[
            ('maker', BrowserSignature.maker),
            ('other', BrowserSignature.other),
            ('unconfirmed', BrowserSignature.unconfirmed),
            ('MAKER', BrowserSignature.unconfirmed),
            (1, BrowserSignature.unconfirmed),
          ]) {
        expect(
          BrowserProbe.fromMap(<String, Object?>{
            'package': 'com.android.chrome',
            'signature': raw,
          })!.signature,
          want,
          reason: '$raw',
        );
      }
      expect(
        BrowserProbe.fromMap(<String, Object?>{
          'package': 'com.android.chrome',
          'state': 1,
          'settings': true,
        })!.state,
        BrowserSwitchState.on,
      );
      expect(
        BrowserProbe.fromMap(<String, Object?>{
          'package': 'com.android.chrome',
          'state': 0,
        })!.state,
        BrowserSwitchState.off,
      );
    });

    test('a browser\'s name is one short line', () {
      expect(browserLabel(null), isNull);
      expect(browserLabel(' \n$_turn '), isNull);
      expect(browserLabel(' Chrome$_turn\nBeta '), 'Chrome Beta');
      expect(browserLabel('x' * 60), '${'x' * 40}…');
    });

    testWidgets('the channel names the browsers and reads the answer; '
        'nothing is asked where Zen fills nothing', (
      WidgetTester tester,
    ) async {
      const MethodChannel channel = MethodChannel(
        SystemPasswordSetupPlatform.channelName,
      );
      final List<MethodCall> calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        MethodCall call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'browsers' => <Object?>[
            <String, Object?>{
              'package': 'com.android.chrome',
              'label': 'Chrome',
              'state': 1,
              'settings': true,
              'signature': 'maker',
            },
            'junk',
          ],
          'openBrowserSettings' => true,
          _ => null,
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final SystemPasswordSetupPlatform android = SystemPasswordSetupPlatform(
        PasswordAutofillBridge(supported: true),
      );
      final List<BrowserProbe> probes = await android.browsers(
        <String>['com.android.chrome', 'org.mozilla.firefox'],
        switches: <String>{'com.android.chrome'},
      );
      expect(probes, hasLength(1));
      expect(probes.single.state, BrowserSwitchState.on);
      expect(calls.single.arguments, <String, Object?>{
        'packages': <String>['com.android.chrome', 'org.mozilla.firefox'],
        'switches': <String>['com.android.chrome'],
      });
      expect(await android.openBrowserSettings('com.android.chrome'), isTrue);
      expect(calls.last.arguments, <String, Object?>{
        'package': 'com.android.chrome',
      });

      calls.clear();
      final SystemPasswordSetupPlatform desktop = SystemPasswordSetupPlatform(
        PasswordAutofillBridge(supported: false),
      );
      expect(desktop.fillsOtherApps, isFalse);
      expect(
        await desktop.browsers(<String>['com.android.chrome'], switches: {}),
        isEmpty,
      );
      expect(await desktop.openBrowserSettings('com.android.chrome'), isFalse);
      expect(calls, isEmpty);
    });

    testWidgets('an Android without the Kotlin side, or one that fails, '
        'answers nothing', (WidgetTester tester) async {
      const MethodChannel channel = MethodChannel(
        SystemPasswordSetupPlatform.channelName,
      );
      bool missing = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        MethodCall call,
      ) async {
        if (missing) {
          throw MissingPluginException();
        }
        throw PlatformException(code: 'boom');
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final SystemPasswordSetupPlatform android = SystemPasswordSetupPlatform(
        PasswordAutofillBridge(supported: true),
      );
      expect(
        await android.browsers(<String>['com.android.chrome'], switches: {}),
        isEmpty,
      );
      expect(await android.openBrowserSettings('com.android.chrome'), isFalse);
      missing = false;
      expect(
        await android.browsers(<String>['com.android.chrome'], switches: {}),
        isEmpty,
      );
      expect(await android.openBrowserSettings('com.android.chrome'), isFalse);
    });
  });

  group('the screen on Android', () {
    testWidgets('Zen not chosen yet, Chrome off: each says so, with the '
        'switch\'s words and a button to the right page', (
      WidgetTester tester,
    ) async {
      final FakeSetupPlatform platform = FakeSetupPlatform(
        installed: _several(),
      );
      await _pumpSetup(tester, platform);

      expect(
        find.byKey(const Key('password-setup-system-off')),
        findsOneWidget,
      );
      expect(
        _text(tester, find.byKey(const Key('password-setup-system-line'))),
        startsWith('Wybierz Zen jako usługę autouzupełniania'),
      );
      await tester.tap(find.byKey(const Key('password-setup-system-open')));
      await tester.pump();
      expect(platform.systemOpened, 1);

      // Chrome: off, the steps, its page.
      expect(
        find.byKey(
          const Key('password-setup-browser-state-com.android.chrome-off'),
        ),
        findsOneWidget,
      );
      expect(find.text('Wyłączone'), findsNWidgets(2));
      expect(
        _text(
          tester,
          find.byKey(
            const Key('password-setup-browser-steps-com.android.chrome'),
          ),
        ),
        contains('„Autofill using another service”'),
      );
      await tester.tap(
        find.byKey(const Key('password-setup-browser-open-com.android.chrome')),
      );
      await tester.pump();
      expect(platform.browsersOpened, <String>['com.android.chrome']);

      // Brave: on, nothing more to do there.
      expect(
        find.byKey(
          const Key('password-setup-browser-state-com.brave.browser-on'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('password-setup-browser-steps-com.brave.browser')),
        findsNothing,
      );

      // Vivaldi: unknown, the steps, no page that would not open.
      expect(
        find.byKey(
          const Key('password-setup-browser-state-com.vivaldi.browser-unknown'),
        ),
        findsOneWidget,
      );
      expect(find.text('Nie wiadomo'), findsOneWidget);
      expect(
        find.byKey(
          const Key('password-setup-browser-steps-com.vivaldi.browser'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('password-setup-browser-open-com.vivaldi.browser'),
        ),
        findsNothing,
      );

      // Firefox: one line, no state, no button.
      expect(
        _text(tester, _line('org.mozilla.firefox')),
        startsWith('Nic nie trzeba ustawiać'),
      );
      expect(
        find.byKey(
          const Key('password-setup-browser-state-org.mozilla.firefox-on'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('password-setup-browser-open-org.mozilla.firefox'),
        ),
        findsNothing,
      );
      // Edge: an honest line.
      expect(
        _text(tester, _line('com.microsoft.emmx')),
        startsWith('Zen może się tu nie pojawić'),
      );
      // Kiwi: nothing verified, where to look.
      expect(
        _text(tester, _line('com.kiwibrowser.browser')),
        contains('poszukaj w jej ustawieniach'),
      );
      // Unknown to Zen: not shown.
      expect(
        find.byKey(const Key('password-setup-browser-com.example.browser')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('password-setup-english-note')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('password-setup-how')), findsOneWidget);
      expect(find.byKey(const Key('password-setup-import')), findsNothing);
      expect(find.byKey(const Key('password-setup-elsewhere')), findsNothing);
    });

    testWidgets('a copy that is not its maker\'s: the honest line, no '
        'switch, no button', (WidgetTester tester) async {
      await _pumpSetup(
        tester,
        FakeSetupPlatform(
          installed: <BrowserProbe>[
            const BrowserProbe(
              packageName: 'com.android.chrome',
              label: 'Chrome',
              state: BrowserSwitchState.off,
              canOpenSettings: true,
              signature: BrowserSignature.other,
            ),
          ],
        ),
      );
      expect(
        _text(tester, _line('com.android.chrome')),
        startsWith('Ta kopia przeglądarki nie jest podpisana przez jej twórcę'),
      );
      expect(
        find.byKey(
          const Key('password-setup-browser-state-com.android.chrome-off'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('password-setup-browser-open-com.android.chrome')),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('password-setup-browser-steps-com.android.chrome'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('password-setup-english-note')),
        findsNothing,
      );
    });

    testWidgets('coming back to Zen reads everything again', (
      WidgetTester tester,
    ) async {
      final FakeSetupPlatform platform = FakeSetupPlatform(
        installed: <BrowserProbe>[_chromeOff],
      );
      await _pumpSetup(tester, platform);
      expect(
        find.byKey(const Key('password-setup-system-off')),
        findsOneWidget,
      );

      // Set in Android's and Chrome's settings meanwhile.
      platform
        ..state = PasswordAutofillState.on
        ..installed = <BrowserProbe>[
          const BrowserProbe(
            packageName: 'com.android.chrome',
            label: 'Chrome',
            state: BrowserSwitchState.on,
            canOpenSettings: true,
          ),
        ];
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(tester);

      expect(find.byKey(const Key('password-setup-system-on')), findsOneWidget);
      expect(
        _text(tester, find.byKey(const Key('password-setup-system-line'))),
        'Zen jest usługą autouzupełniania na tym telefonie.',
      );
      expect(
        find.byKey(
          const Key('password-setup-browser-state-com.android.chrome-on'),
        ),
        findsOneWidget,
      );
      expect(_text(tester, _line('com.android.chrome')), startsWith('Gotowe'));
      expect(
        find.byKey(
          const Key('password-setup-browser-steps-com.android.chrome'),
        ),
        findsNothing,
      );
      // Nothing left that needs English words.
      expect(
        find.byKey(const Key('password-setup-english-note')),
        findsNothing,
      );
      // The way to Android's setting stays (to switch it off).
      expect(
        find.byKey(const Key('password-setup-system-open')),
        findsOneWidget,
      );
    });

    testWidgets('no browser Zen knows: one line on where to look', (
      WidgetTester tester,
    ) async {
      await _pumpSetup(tester, FakeSetupPlatform());
      expect(
        find.byKey(const Key('password-setup-no-browsers')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('password-setup-how')), findsOneWidget);
    });

    testWidgets('an Android that cannot fill gets the honest page', (
      WidgetTester tester,
    ) async {
      await _pumpSetup(
        tester,
        FakeSetupPlatform(
          state: PasswordAutofillState.unsupported,
          installed: <BrowserProbe>[_chromeOff],
        ),
      );
      expect(find.byKey(const Key('password-setup-elsewhere')), findsOneWidget);
      expect(find.textContaining('Android 9 lub nowszy'), findsWidgets);
      expect(find.byKey(const Key('password-setup-system')), findsNothing);
      expect(
        find.byKey(const Key('password-setup-browser-com.android.chrome')),
        findsNothing,
      );
    });

    testWidgets('opened from "Hasła", it ends with the import from a file', (
      WidgetTester tester,
    ) async {
      await _pumpSetup(tester, FakeSetupPlatform(), withImport: true);
      expect(find.byKey(const Key('password-setup-import')), findsOneWidget);
      await tester.tap(find.byKey(const Key('password-setup-import-button')));
      await _frames(tester);
      expect(find.byKey(const Key('password-import-warning')), findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await _frames(tester);
      expect(find.byKey(const Key('password-import-warning')), findsNothing);
    });
  });

  testWidgets('elsewhere: Zen fills nothing there, says how the passwords '
      'are used, and has no button that does nothing', (
    WidgetTester tester,
  ) async {
    final FakeSetupPlatform platform = FakeSetupPlatform(
      fillsOtherApps: false,
      installed: <BrowserProbe>[_chromeOff],
    );
    await _pumpSetup(tester, platform);
    expect(find.byKey(const Key('password-setup-elsewhere')), findsOneWidget);
    expect(
      find.text(
        'Na tym urządzeniu Zen nie wypełnia formularzy w innych aplikacjach '
        'ani w przeglądarkach.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('po 30 sekundach'), findsOneWidget);
    expect(find.textContaining('wszystkich urządzeniach'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('password-setup')),
        matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('password-setup-system')), findsNothing);
    expect(find.byKey(const Key('password-setup-how')), findsNothing);
    expect(platform.reads, 0);
  });

  testWidgets('"Hasła" has the setup in sight, also when empty', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          passwordSetupPlatformProvider.overrideWithValue(
            FakeSetupPlatform(installed: <BrowserProbe>[_chromeOff]),
          ),
          passwordVaultServiceProvider.overrideWithValue(
            PasswordVaultService(disk: MemoryLedgerDisk()),
          ),
          appSecurityServiceProvider.overrideWithValue(
            MemoryAppSecurityService(passwordIterations: 10),
          ),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const PasswordVaultScreen(),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await _frames(tester);
    expect(find.byKey(const Key('passwords-empty-setup')), findsOneWidget);
    await tester.tap(find.byKey(const Key('passwords-setup')));
    await _frames(tester);
    expect(find.byKey(const Key('password-setup-screen')), findsOneWidget);
    expect(
      find.byKey(const Key('password-setup-browser-com.android.chrome')),
      findsOneWidget,
    );
    // The passwords are open: the import is offered at the end.
    expect(find.byKey(const Key('password-setup-import')), findsOneWidget);
  });
}
