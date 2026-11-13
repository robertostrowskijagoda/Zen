import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';

/// What a browser needs before Zen can fill its pages.
enum BrowserAutofillNeeds {
  /// A switch of its own: Chrome 135+ hands web forms to the phone's
  /// autofill service only with "Autofill using another service" on
  /// (Android Developers Blog, February 2025). Brave and Vivaldi are said
  /// to have the same switch; not verified here.
  ownSwitch,

  /// Nothing: believed to use Android's autofill service by itself (Firefox
  /// and its forks: Bitwarden's autofill configuration limits Firefox's
  /// compatibility entry to an old version; browsers on the system
  /// WebView). Not verified here.
  nothing,

  /// Probably never asks Zen: Bitwarden's configuration lists it among the
  /// browsers that need Android's accessibility-based "compatibility mode",
  /// which Zen does not declare (res/xml/zen_autofill_service.xml).
  compatibilityMode,

  /// Nothing verified is known.
  unverified,
}

/// A browser Zen knows by its package.
@immutable
final class KnownBrowser {
  const KnownBrowser(this.packageName, this.name, this.needs);

  final String packageName;

  /// Its name when the system gives none.
  final String name;
  final BrowserAutofillNeeds needs;
}

/// The browsers the setup looks for, in the order it lists them. A copy of
/// the names in `autofillBrowsers` (ZenAutofillTrust.kt), the browsers
/// whose pages the autofill matches by address when the installed copy is
/// signed with its maker's certificate; a browser added there belongs here
/// too (and in the manifest's `<queries>`).
const List<KnownBrowser> kKnownBrowsers = <KnownBrowser>[
  KnownBrowser('com.android.chrome', 'Chrome', BrowserAutofillNeeds.ownSwitch),
  KnownBrowser(
    'com.chrome.beta',
    'Chrome Beta',
    BrowserAutofillNeeds.ownSwitch,
  ),
  KnownBrowser('com.chrome.dev', 'Chrome Dev', BrowserAutofillNeeds.ownSwitch),
  KnownBrowser(
    'com.chrome.canary',
    'Chrome Canary',
    BrowserAutofillNeeds.ownSwitch,
  ),
  KnownBrowser(
    'org.chromium.chrome',
    'Chromium',
    BrowserAutofillNeeds.ownSwitch,
  ),
  KnownBrowser('com.brave.browser', 'Brave', BrowserAutofillNeeds.ownSwitch),
  KnownBrowser(
    'com.vivaldi.browser',
    'Vivaldi',
    BrowserAutofillNeeds.ownSwitch,
  ),
  KnownBrowser(
    'com.microsoft.emmx',
    'Edge',
    BrowserAutofillNeeds.compatibilityMode,
  ),
  KnownBrowser(
    'com.sec.android.app.sbrowser',
    'Samsung Internet',
    BrowserAutofillNeeds.compatibilityMode,
  ),
  KnownBrowser(
    'com.opera.browser',
    'Opera',
    BrowserAutofillNeeds.compatibilityMode,
  ),
  KnownBrowser(
    'com.kiwibrowser.browser',
    'Kiwi',
    BrowserAutofillNeeds.unverified,
  ),
  KnownBrowser('org.mozilla.firefox', 'Firefox', BrowserAutofillNeeds.nothing),
  KnownBrowser(
    'org.mozilla.firefox_beta',
    'Firefox Beta',
    BrowserAutofillNeeds.nothing,
  ),
  KnownBrowser(
    'org.mozilla.fenix',
    'Firefox Nightly',
    BrowserAutofillNeeds.nothing,
  ),
  KnownBrowser(
    'org.mozilla.fennec_fdroid',
    'Fennec',
    BrowserAutofillNeeds.nothing,
  ),
  KnownBrowser('us.spotco.fennec_dos', 'Mull', BrowserAutofillNeeds.nothing),
  KnownBrowser(
    'org.ironfoxoss.ironfox',
    'IronFox',
    BrowserAutofillNeeds.nothing,
  ),
  KnownBrowser(
    'org.torproject.torbrowser',
    'Tor Browser',
    BrowserAutofillNeeds.nothing,
  ),
  KnownBrowser(
    'com.duckduckgo.mobile.android',
    'DuckDuckGo',
    BrowserAutofillNeeds.nothing,
  ),
  // Firefox's private browsers on GeckoView, not forks of Firefox itself.
  KnownBrowser(
    'org.mozilla.focus',
    'Firefox Focus',
    BrowserAutofillNeeds.unverified,
  ),
  KnownBrowser(
    'org.mozilla.klar',
    'Firefox Klar',
    BrowserAutofillNeeds.unverified,
  ),
];

/// A browser's own switch, as far as it can be read.
enum BrowserSwitchState { on, off, unknown }

/// Whether an installed browser is the one its package name says
/// (`browserSignature` in ZenAutofillTrust.kt).
enum BrowserSignature {
  /// Signed with its maker's certificate: Zen believes it about the page.
  maker,

  /// Signed by someone else: Zen fills it like any other app.
  other,

  /// Zen has no confirmed certificate of this browser: like any other app.
  unconfirmed,
}

/// What the phone says about one installed browser ([PasswordSetupPlatform]).
@immutable
final class BrowserProbe {
  const BrowserProbe({
    required this.packageName,
    this.label,
    this.state = BrowserSwitchState.unknown,
    this.canOpenSettings = false,
    this.signature = BrowserSignature.maker,
  });

  /// One entry of the Android side's answer; null when it does not look
  /// right. A signature it does not name is taken as unconfirmed.
  static BrowserProbe? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? package = raw['package'];
    if (package is! String || package.isEmpty || package.length > 255) {
      return null;
    }
    final Object? label = raw['label'];
    return BrowserProbe(
      packageName: package,
      label: label is String ? label : null,
      state: switch (raw['state']) {
        1 => BrowserSwitchState.on,
        0 => BrowserSwitchState.off,
        _ => BrowserSwitchState.unknown,
      },
      canOpenSettings: raw['settings'] == true,
      signature: switch (raw['signature']) {
        'maker' => BrowserSignature.maker,
        'other' => BrowserSignature.other,
        _ => BrowserSignature.unconfirmed,
      },
    );
  }

  final String packageName;

  /// Its name as the system shows it.
  final String? label;
  final BrowserSwitchState state;

  /// Its page with the switch opens in that browser itself.
  final bool canOpenSettings;
  final BrowserSignature signature;
}

/// One installed browser as the setup shows it.
@immutable
final class BrowserSetup {
  const BrowserSetup({
    required this.browser,
    required this.name,
    this.state,
    this.canOpenSettings = false,
    this.signature = BrowserSignature.maker,
  });

  final KnownBrowser browser;
  final String name;

  /// Whether this copy is its maker's: only then does Zen match its pages
  /// by their address. Any other copy is filled like an app; one signed by
  /// someone else has nothing to set up for Zen (its switch is not shown),
  /// one Zen has no confirmed certificate of keeps its switch.
  final BrowserSignature signature;

  /// Its own switch; null for a browser without one (or not known to have
  /// one).
  final BrowserSwitchState? state;
  final bool canOpenSettings;

  BrowserAutofillNeeds get needs => browser.needs;

  /// Whether the person still has something to do in it.
  bool get needsAction =>
      signature != BrowserSignature.other &&
      needs == BrowserAutofillNeeds.ownSwitch &&
      state != BrowserSwitchState.on;

  /// One line on where it stands.
  String get line => switch (signature) {
    // One that probably never asks Zen: that is the line that matters.
    BrowserSignature.unconfirmed
        when needs == BrowserAutofillNeeds.compatibilityMode =>
      _makersLine,
    BrowserSignature.other => t(
      'Ta kopia przeglądarki nie jest podpisana przez jej twórcę: Zen '
      'wypełnia ją jak każdą inną aplikację i nie wierzy jej, jaka strona '
      'jest otwarta. Loginy do stron pokaże dopiero po ostrzeżeniu.',
    ),
    BrowserSignature.unconfirmed => t(
      'Zen nie zna potwierdzonego podpisu tej przeglądarki: wypełnia ją jak '
      'każdą inną aplikację i nie wierzy jej, jaka strona jest otwarta. '
      'Loginy do stron pokaże dopiero po ostrzeżeniu.',
    ),
    BrowserSignature.maker => _makersLine,
  };

  String get _makersLine => switch (needs) {
    BrowserAutofillNeeds.nothing => t(
      'Nic nie trzeba ustawiać: ta przeglądarka zwykle sama korzysta z '
      'autouzupełniania Androida.',
    ),
    BrowserAutofillNeeds.compatibilityMode => t(
      'Zen może się tu nie pojawić: ta przeglądarka nie pyta usługi '
      'autouzupełniania wprost. Użyj Chrome’a albo Firefoksa, albo skopiuj '
      'login z wpisu w Hasłach.',
    ),
    BrowserAutofillNeeds.unverified => t(
      'Zen nie zna sprawdzonych kroków dla tej przeglądarki. Jeśli nie '
      'widzisz podpowiedzi Zen, poszukaj w jej ustawieniach '
      'autouzupełniania („Autofill”).',
    ),
    BrowserAutofillNeeds.ownSwitch => switch (state) {
      BrowserSwitchState.on => t(
        'Gotowe: przeglądarka przekazuje formularze usłudze autouzupełniania.',
      ),
      BrowserSwitchState.off => t(
        'Wyłączone: przeglądarka wypełnia formularze sama i nie pyta Zen.',
      ),
      _ => t(
        'Nie udało się odczytać tego ustawienia. Sprawdź je w przeglądarce; '
        'starsza wersja może go nie mieć.',
      ),
    },
  };

  /// Where its switch is; null when there is nothing to look for.
  String? get steps =>
      signature != BrowserSignature.other &&
          needs == BrowserAutofillNeeds.ownSwitch
      ? t(
          'W przeglądarce: Ustawienia → Usługi autouzupełniania („Autofill '
          'services”) → autouzupełnianie przez inną usługę („Autofill using '
          'another service”). Przeglądarka uruchomi się ponownie.',
        )
      : null;
}

/// Where the password manager's setup stands on this device.
@immutable
final class PasswordSetupState {
  const PasswordSetupState({
    required this.fillsOtherApps,
    required this.autofill,
    this.browsers = const <BrowserSetup>[],
  });

  /// A system where Zen fills nothing in other apps (not Android).
  static const PasswordSetupState elsewhere = PasswordSetupState(
    fillsOtherApps: false,
    autofill: PasswordAutofillState.unsupported,
  );

  /// Android: the system where Zen can fill other apps (from 9 on).
  final bool fillsOtherApps;
  final PasswordAutofillState autofill;

  /// The installed browsers Zen knows, in the order of [kKnownBrowsers].
  final List<BrowserSetup> browsers;

  /// Zen fills other apps here once switched on.
  bool get supported =>
      fillsOtherApps && autofill != PasswordAutofillState.unsupported;
}

/// The device's side of the setup (Android's autofill setting and the
/// browsers); tests put their own.
abstract interface class PasswordSetupPlatform {
  /// Android, where Zen can fill other apps at all.
  bool get fillsOtherApps;

  Future<PasswordAutofillState> autofill();

  /// Android's page where the autofill service is picked.
  Future<bool> openAutofillSettings();

  /// Which of [known] are installed. Only for those whose [switches] holds
  /// them is the switch read and its page looked for.
  Future<List<BrowserProbe>> browsers(
    List<String> known, {
    required Set<String> switches,
  });

  /// [packageName]'s own page with its switch.
  Future<bool> openBrowserSettings(String packageName);
}

/// [PasswordAutofillBridge] for Android's setting, `zen/autofill_setup`
/// (ZenAutofillSetupBridge.kt) for the browsers.
final class SystemPasswordSetupPlatform implements PasswordSetupPlatform {
  SystemPasswordSetupPlatform(this.bridge, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'zen/autofill_setup';

  final PasswordAutofillBridge bridge;
  final MethodChannel _channel;

  @override
  bool get fillsOtherApps => bridge.supported;

  @override
  Future<PasswordAutofillState> autofill() => bridge.state();

  @override
  Future<bool> openAutofillSettings() => bridge.openSettings();

  Future<T?> _call<T>(String method, Map<String, Object?> arguments) async {
    if (!fillsOtherApps) {
      return null;
    }
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on Object catch (error) {
      logZenWarning('Autofill setup ($method) failed: ${error.runtimeType}');
      return null;
    }
  }

  @override
  Future<List<BrowserProbe>> browsers(
    List<String> known, {
    required Set<String> switches,
  }) async {
    final List<Object?>? raw = await _call<List<Object?>>(
      'browsers',
      <String, Object?>{'packages': known, 'switches': switches.toList()},
    );
    return <BrowserProbe>[
      for (final Object? item in raw ?? const <Object?>[])
        ?BrowserProbe.fromMap(item),
    ];
  }

  @override
  Future<bool> openBrowserSettings(String packageName) async =>
      await _call<bool>('openBrowserSettings', <String, Object?>{
        'package': packageName,
      }) ??
      false;
}

final Provider<PasswordSetupPlatform> passwordSetupPlatformProvider =
    Provider<PasswordSetupPlatform>(
      (Ref ref) => SystemPasswordSetupPlatform(
        ref.watch(passwordAutofillBridgeProvider),
      ),
    );

/// Where the setup stands: Android's setting, then (where Zen can fill)
/// every installed browser of [kKnownBrowsers] with what it needs.
Future<PasswordSetupState> readPasswordSetup(
  PasswordSetupPlatform platform,
) async {
  if (!platform.fillsOtherApps) {
    return PasswordSetupState.elsewhere;
  }
  final PasswordAutofillState autofill = await platform.autofill();
  if (autofill == PasswordAutofillState.unsupported) {
    return const PasswordSetupState(
      fillsOtherApps: true,
      autofill: PasswordAutofillState.unsupported,
    );
  }
  final List<BrowserProbe> probes = await platform.browsers(
    <String>[for (final KnownBrowser b in kKnownBrowsers) b.packageName],
    switches: <String>{
      for (final KnownBrowser b in kKnownBrowsers)
        if (b.needs == BrowserAutofillNeeds.ownSwitch) b.packageName,
    },
  );
  final Map<String, BrowserProbe> installed = <String, BrowserProbe>{
    for (final BrowserProbe p in probes) p.packageName: p,
  };
  return PasswordSetupState(
    fillsOtherApps: true,
    autofill: autofill,
    browsers: <BrowserSetup>[
      for (final KnownBrowser b in kKnownBrowsers)
        if (installed[b.packageName] case final BrowserProbe p)
          BrowserSetup(
            browser: b,
            name: browserLabel(p.label) ?? b.name,
            // A copy signed by someone else has no switch that matters.
            state:
                b.needs == BrowserAutofillNeeds.ownSwitch &&
                    p.signature != BrowserSignature.other
                ? p.state
                : null,
            canOpenSettings:
                b.needs == BrowserAutofillNeeds.ownSwitch &&
                p.signature != BrowserSignature.other &&
                p.canOpenSettings,
            signature: p.signature,
          ),
    ],
  );
}

/// A browser's name as the system gave it, on one short line; null when
/// there is nothing to show.
@visibleForTesting
String? browserLabel(String? raw) {
  if (raw == null) {
    return null;
  }
  // Control characters and the marks that turn text around become spaces.
  final String line = String.fromCharCodes(<int>[
    for (final int c in raw.runes) _hidden(c) ? 0x20 : c,
  ]).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (line.isEmpty) {
    return null;
  }
  return line.length > 40 ? '${line.substring(0, 40)}…' : line;
}

bool _hidden(int c) =>
    c < 0x20 ||
    (c >= 0x7f && c <= 0x9f) ||
    c == 0x200e ||
    c == 0x200f ||
    (c >= 0x202a && c <= 0x202e) ||
    (c >= 0x2066 && c <= 0x2069);
