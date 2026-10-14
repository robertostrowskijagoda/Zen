import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

enum AppLockMode {
  never,
  background,
  appClose,
  systemRestart;

  String get label => switch (this) {
    AppLockMode.never => 'Nigdy',
    AppLockMode.background => 'Po wyjściu z aplikacji',
    AppLockMode.appClose => 'Przy zamknięciu aplikacji',
    AppLockMode.systemRestart => 'Przy restarcie telefonu',
  };
}

enum AppThemeMode {
  system,
  light,
  dark;

  String get label => switch (this) {
    AppThemeMode.system => 'Systemowy',
    AppThemeMode.light => 'Jasny',
    AppThemeMode.dark => 'Ciemny',
  };

  ThemeMode get materialThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };
}

/// Groups the accent themes into the sections the picker lists them under.
enum AppThemeFamily {
  neutral('Neutralne'),
  green('Zielenie'),
  teal('Turkusy'),
  blue('Blekity'),
  violet('Fiolety'),
  pink('Roze'),
  warm('Cieple'),
  gold('Zlota'),
  night('Nocne');

  const AppThemeFamily(this.label);

  final String label;
}

/// Selectable accent themes. Each one is a full palette (dark and light tone
/// sets plus a three-hue accent triplet) paired with its own typeface - see
/// `_presets` in `zen_theme.dart`. There are enough of them that the settings
/// screen lists them in a searchable picker rather than a grid.
enum AppAccentTheme {
  // [storageId] is what gets persisted. It is deliberately decoupled from the
  // declaration order so themes can be reskinned, reordered or removed without
  // silently reassigning everyone's saved choice to a different palette. Ids
  // 0-8 are inherited from the previous palette generation, each mapped to the
  // closest hue in this one; new themes take ids from 9 up.
  //
  // The declaration order below is the reading order of the picker.
  graphite(0, AppThemeFamily.neutral),
  paper(9, AppThemeFamily.neutral),
  carbon(10, AppThemeFamily.neutral),

  terminal(5, AppThemeFamily.green),
  jade(11, AppThemeFamily.green),
  moss(12, AppThemeFamily.green),

  aurora(1, AppThemeFamily.teal),
  arctic(3, AppThemeFamily.teal),
  lagoon(13, AppThemeFamily.teal),

  cobalt(7, AppThemeFamily.blue),
  abyss(14, AppThemeFamily.blue),
  denim(15, AppThemeFamily.blue),

  amethyst(8, AppThemeFamily.violet),
  nebula(16, AppThemeFamily.violet),
  plum(17, AppThemeFamily.violet),

  synthwave(4, AppThemeFamily.pink),
  sakura(18, AppThemeFamily.pink),
  ruby(19, AppThemeFamily.pink),

  magma(2, AppThemeFamily.warm),
  rust(20, AppThemeFamily.warm),
  coral(21, AppThemeFamily.warm),

  solaris(6, AppThemeFamily.gold),
  honey(22, AppThemeFamily.gold),
  voltage(23, AppThemeFamily.gold),

  amberCrt(24, AppThemeFamily.night),
  nocturne(25, AppThemeFamily.night),
  fjord(26, AppThemeFamily.night);

  const AppAccentTheme(this.storageId, this.family);

  final int storageId;

  /// Section this theme is listed under in the picker.
  final AppThemeFamily family;

  String get label => switch (this) {
    AppAccentTheme.graphite => 'Zen',
    AppAccentTheme.paper => 'Papier',
    AppAccentTheme.carbon => 'Karbon',
    AppAccentTheme.terminal => 'Terminal',
    AppAccentTheme.jade => 'Jadeit',
    AppAccentTheme.moss => 'Mech',
    AppAccentTheme.aurora => 'Zorza',
    AppAccentTheme.arctic => 'Arktyka',
    AppAccentTheme.lagoon => 'Laguna',
    AppAccentTheme.cobalt => 'Kobalt',
    AppAccentTheme.abyss => 'Otchłań',
    AppAccentTheme.denim => 'Denim',
    AppAccentTheme.amethyst => 'Ametyst',
    AppAccentTheme.nebula => 'Mgławica',
    AppAccentTheme.plum => 'Śliwka',
    AppAccentTheme.synthwave => 'Synthwave',
    AppAccentTheme.sakura => 'Sakura',
    AppAccentTheme.ruby => 'Rubin',
    AppAccentTheme.magma => 'Magma',
    AppAccentTheme.rust => 'Rdza',
    AppAccentTheme.coral => 'Koral',
    AppAccentTheme.solaris => 'Solaris',
    AppAccentTheme.honey => 'Miód',
    AppAccentTheme.voltage => 'Napięcie',
    AppAccentTheme.amberCrt => 'Bursztyn',
    AppAccentTheme.nocturne => 'Nokturn',
    AppAccentTheme.fjord => 'Fiord',
  };

  /// One-line character sketch shown under the name in the picker.
  String get tagline => switch (this) {
    AppAccentTheme.graphite => 'stal / tusz',
    AppAccentTheme.paper => 'sepia / atrament',
    AppAccentTheme.carbon => 'czern / biel',
    AppAccentTheme.terminal => 'fosfor / bursztyn',
    AppAccentTheme.jade => 'jadeit / mieta',
    AppAccentTheme.moss => 'oliwka / mech',
    AppAccentTheme.aurora => 'turkus / fiolet',
    AppAccentTheme.arctic => 'lod / blekit',
    AppAccentTheme.lagoon => 'laguna / piasek',
    AppAccentTheme.cobalt => 'blekit / indygo',
    AppAccentTheme.abyss => 'glebia / stal',
    AppAccentTheme.denim => 'denim / tan',
    AppAccentTheme.amethyst => 'ametyst / fuksja',
    AppAccentTheme.nebula => 'fiolet / roz / cyjan',
    AppAccentTheme.plum => 'sliwka / mauve',
    AppAccentTheme.synthwave => 'magenta / cyjan',
    AppAccentTheme.sakura => 'kwiat wisni',
    AppAccentTheme.ruby => 'rubin / zloto',
    AppAccentTheme.magma => 'lawa / rubin',
    AppAccentTheme.rust => 'rdza / miedz',
    AppAccentTheme.coral => 'koral / brzoskwinia',
    AppAccentTheme.solaris => 'zloto / niebo',
    AppAccentTheme.honey => 'miod / krem',
    AppAccentTheme.voltage => 'kwas / limonka',
    AppAccentTheme.amberCrt => 'bursztynowy CRT',
    AppAccentTheme.nocturne => 'noc / neon',
    AppAccentTheme.fjord => 'fiord / szron',
  };

  static AppAccentTheme fromStorageId(int value) {
    for (final AppAccentTheme theme in AppAccentTheme.values) {
      if (theme.storageId == value) {
        return theme;
      }
    }
    return AppSettings.defaultAccentTheme;
  }
}

@immutable
final class AppSettings {
  const AppSettings({
    this.inboxLimitMb = defaultInboxLimitMb,
    this.autoCleanupDays = defaultAutoCleanupDays,
    this.notificationDelaySeconds = defaultNotificationDelaySeconds,
    this.encryptionEnabled = defaultEncryptionEnabled,
    this.lockMode = defaultLockMode,
    this.backgroundLockDelaySeconds = defaultBackgroundLockDelaySeconds,
    this.themeMode = defaultThemeMode,
    this.accentTheme = defaultAccentTheme,
    this.gifApiKey = '',
    this.autoDownloadMedia = true,
    this.hideNotificationContent = true,
    this.secureScreens = true,
    this.allowNoAppPassword = false,
    this.bridgeEnabled = true,
    this.permissionsSetupDone = false,
  });

  static const int defaultInboxLimitMb = 100;
  static const int minimumInboxLimitMb = 5;
  static const int defaultAutoCleanupDays = 0;
  static const int defaultNotificationDelaySeconds = 5;
  static const int minimumNotificationDelaySeconds = 2;
  static const int maximumNotificationDelaySeconds = 10;

  /// Local encryption is always on; the flag survives only for storage
  /// compatibility and is forced true everywhere it matters.
  static const bool defaultEncryptionEnabled = true;

  /// Locks when Zen has been in the background for a while (5 min), so a
  /// phone left unlocked on a table does not show the conversations.
  static const AppLockMode defaultLockMode = AppLockMode.background;
  static const int defaultBackgroundLockDelaySeconds = 300;
  static const int minimumBackgroundLockDelaySeconds = 1;
  static const int maximumBackgroundLockDelaySeconds = 3600;
  static const AppThemeMode defaultThemeMode = AppThemeMode.system;
  static const AppAccentTheme defaultAccentTheme = AppAccentTheme.graphite;

  final int inboxLimitMb;
  final int autoCleanupDays;
  final int notificationDelaySeconds;
  final bool encryptionEnabled;
  final AppLockMode lockMode;
  final int backgroundLockDelaySeconds;
  final AppThemeMode themeMode;
  final AppAccentTheme accentTheme;

  /// The user's own Klipy key; empty means the app's shared key is used.
  final String gifApiKey;

  bool get usesOwnGifKey => gifApiKey.isNotEmpty;

  /// Photos and videos in posts download on their own (default: yes).
  final bool autoDownloadMedia;

  /// Notifications say only "Nowa wiadomość", so message text never lands
  /// in the system's notification history (§14.1). On by default.
  final bool hideNotificationContent;

  /// Screenshots and screen recording are blocked on conversations and
  /// account screens, and their content is hidden in the recent-apps view
  /// (§14.1). On by default.
  final bool secureScreens;

  /// The user chose to run without an app password (§14.1: it is required
  /// by default). Off by default.
  final bool allowNoAppPassword;

  /// A computer helps others connect (a mesh bridge, §5.1). On by default
  /// and not advertised; it can be switched off at the bottom of the
  /// settings (Sieć i usługa).
  final bool bridgeEnabled;

  /// The first-start step "Uprawnienia i Bluetooth" (§25.2) was gone
  /// through: it is not shown again (it stays under Ustawienia).
  final bool permissionsSetupDone;

  /// Longest key accepted; real keys are ~64 characters.
  static const int maximumGifApiKeyLength = 200;

  /// Trims [value] and drops anything that cannot be a key (spaces inside,
  /// control characters, URL syntax), so it is always safe to put in a URL.
  static String normalizeGifApiKey(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > maximumGifApiKeyLength ||
        !RegExp(r'^[A-Za-z0-9_\-.]+$').hasMatch(trimmed)) {
      return '';
    }
    return trimmed;
  }

  bool get inboxUnlimited => inboxLimitMb <= 0;

  Duration get signalWaitTimeout => Duration(
    seconds: normalizeNotificationDelaySeconds(notificationDelaySeconds),
  );

  String get inboxLimitLabel =>
      inboxUnlimited ? 'Bez limitu' : '$inboxLimitMb MB';

  AppSettings copyWith({
    int? inboxLimitMb,
    int? autoCleanupDays,
    int? notificationDelaySeconds,
    bool? encryptionEnabled,
    AppLockMode? lockMode,
    int? backgroundLockDelaySeconds,
    AppThemeMode? themeMode,
    AppAccentTheme? accentTheme,
    String? gifApiKey,
    bool? autoDownloadMedia,
    bool? hideNotificationContent,
    bool? secureScreens,
    bool? allowNoAppPassword,
    bool? bridgeEnabled,
    bool? permissionsSetupDone,
  }) {
    return AppSettings(
      inboxLimitMb: normalizeInboxLimitMb(inboxLimitMb ?? this.inboxLimitMb),
      autoCleanupDays: normalizeAutoCleanupDays(
        autoCleanupDays ?? this.autoCleanupDays,
      ),
      notificationDelaySeconds: normalizeNotificationDelaySeconds(
        notificationDelaySeconds ?? this.notificationDelaySeconds,
      ),
      encryptionEnabled: encryptionEnabled ?? this.encryptionEnabled,
      lockMode: lockMode ?? this.lockMode,
      backgroundLockDelaySeconds: normalizeBackgroundLockDelaySeconds(
        backgroundLockDelaySeconds ?? this.backgroundLockDelaySeconds,
      ),
      themeMode: themeMode ?? this.themeMode,
      accentTheme: accentTheme ?? this.accentTheme,
      gifApiKey: normalizeGifApiKey(gifApiKey ?? this.gifApiKey),
      autoDownloadMedia: autoDownloadMedia ?? this.autoDownloadMedia,
      hideNotificationContent:
          hideNotificationContent ?? this.hideNotificationContent,
      secureScreens: secureScreens ?? this.secureScreens,
      allowNoAppPassword: allowNoAppPassword ?? this.allowNoAppPassword,
      bridgeEnabled: bridgeEnabled ?? this.bridgeEnabled,
      permissionsSetupDone: permissionsSetupDone ?? this.permissionsSetupDone,
    );
  }

  /// Named fields: an unknown field is ignored and a missing one keeps its
  /// default, so a new setting needs no format version.
  Map<String, Object> toJson() => <String, Object>{
    'inboxLimitMb': inboxLimitMb,
    'autoCleanupDays': autoCleanupDays,
    'notificationDelaySeconds': notificationDelaySeconds,
    'lockMode': lockMode.name,
    'backgroundLockDelaySeconds': backgroundLockDelaySeconds,
    'themeMode': themeMode.name,
    'accentTheme': accentTheme.name,
    'gifApiKey': gifApiKey,
    'autoDownloadMedia': autoDownloadMedia,
    'hideNotificationContent': hideNotificationContent,
    'secureScreens': secureScreens,
    'allowNoAppPassword': allowNoAppPassword,
    'bridgeEnabled': bridgeEnabled,
    'permissionsSetupDone': permissionsSetupDone,
  };

  static AppSettings fromJson(Map<String, dynamic> json) {
    T? pick<T>(String key) {
      final Object? value = json[key];
      return value is T ? value : null;
    }

    E? byName<E extends Enum>(List<E> values, String key) {
      final Object? name = json[key];
      for (final E value in values) {
        if (value.name == name) {
          return value;
        }
      }
      return null;
    }

    return const AppSettings().copyWith(
      inboxLimitMb: pick<int>('inboxLimitMb'),
      autoCleanupDays: pick<int>('autoCleanupDays'),
      notificationDelaySeconds: pick<int>('notificationDelaySeconds'),
      lockMode: byName(AppLockMode.values, 'lockMode'),
      backgroundLockDelaySeconds: pick<int>('backgroundLockDelaySeconds'),
      themeMode: byName(AppThemeMode.values, 'themeMode'),
      accentTheme: byName(AppAccentTheme.values, 'accentTheme'),
      gifApiKey: pick<String>('gifApiKey'),
      autoDownloadMedia: pick<bool>('autoDownloadMedia'),
      hideNotificationContent: pick<bool>('hideNotificationContent'),
      secureScreens: pick<bool>('secureScreens'),
      allowNoAppPassword: pick<bool>('allowNoAppPassword'),
      bridgeEnabled: pick<bool>('bridgeEnabled'),
      permissionsSetupDone: pick<bool>('permissionsSetupDone'),
    );
  }

  static int normalizeInboxLimitMb(int value) {
    if (value <= 0) {
      return 0;
    }
    return value < minimumInboxLimitMb ? minimumInboxLimitMb : value;
  }

  static int normalizeAutoCleanupDays(int value) {
    return value < 0 ? 0 : value;
  }

  static int normalizeNotificationDelaySeconds(int value) {
    if (value < minimumNotificationDelaySeconds) {
      return minimumNotificationDelaySeconds;
    }
    if (value > maximumNotificationDelaySeconds) {
      return maximumNotificationDelaySeconds;
    }
    return value;
  }

  static int normalizeBackgroundLockDelaySeconds(int value) {
    if (value < minimumBackgroundLockDelaySeconds) {
      return minimumBackgroundLockDelaySeconds;
    }
    if (value > maximumBackgroundLockDelaySeconds) {
      return maximumBackgroundLockDelaySeconds;
    }
    return value;
  }

  static AppLockMode lockModeFromStorage(int value) {
    if (value < 0 || value >= AppLockMode.values.length) {
      return defaultLockMode;
    }
    return AppLockMode.values[value];
  }
}
