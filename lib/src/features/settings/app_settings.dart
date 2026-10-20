import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:zen/src/app/i18n/zen_i18n.dart';

enum AppLockMode {
  never,
  background,
  appClose,
  systemRestart;

  String get label => switch (this) {
    AppLockMode.never => t('Nigdy'),
    AppLockMode.background => t('Po wyjściu z aplikacji'),
    AppLockMode.appClose => t('Przy zamknięciu aplikacji'),
    AppLockMode.systemRestart => t('Przy restarcie telefonu'),
  };
}

enum AppThemeMode {
  system,
  light,
  dark;

  String get label => switch (this) {
    AppThemeMode.system => t('Systemowy'),
    AppThemeMode.light => t('Jasny'),
    AppThemeMode.dark => t('Ciemny'),
  };

  ThemeMode get materialThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };
}

/// Groups the accent themes into the sections the picker lists them under.
enum AppThemeFamily {
  neutral,
  green,
  teal,
  blue,
  violet,
  pink,
  warm,
  gold,
  night;

  String get label => switch (this) {
    AppThemeFamily.neutral => t('Neutralne'),
    AppThemeFamily.green => t('Zielenie'),
    AppThemeFamily.teal => t('Turkusy'),
    AppThemeFamily.blue => t('Błękity'),
    AppThemeFamily.violet => t('Fiolety'),
    AppThemeFamily.pink => t('Róże'),
    AppThemeFamily.warm => t('Ciepłe'),
    AppThemeFamily.gold => t('Złota'),
    AppThemeFamily.night => t('Nocne'),
  };
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
    AppAccentTheme.paper => t('Papier'),
    AppAccentTheme.carbon => t('Karbon'),
    AppAccentTheme.terminal => t('Terminal'),
    AppAccentTheme.jade => t('Jadeit'),
    AppAccentTheme.moss => t('Mech'),
    AppAccentTheme.aurora => t('Zorza'),
    AppAccentTheme.arctic => t('Arktyka'),
    AppAccentTheme.lagoon => t('Laguna'),
    AppAccentTheme.cobalt => t('Kobalt'),
    AppAccentTheme.abyss => t('Otchłań'),
    AppAccentTheme.denim => t('Denim'),
    AppAccentTheme.amethyst => t('Ametyst'),
    AppAccentTheme.nebula => t('Mgławica'),
    AppAccentTheme.plum => t('Śliwka'),
    AppAccentTheme.synthwave => t('Synthwave'),
    AppAccentTheme.sakura => t('Sakura'),
    AppAccentTheme.ruby => t('Rubin'),
    AppAccentTheme.magma => t('Magma'),
    AppAccentTheme.rust => t('Rdza'),
    AppAccentTheme.coral => t('Koral'),
    AppAccentTheme.solaris => t('Solaris'),
    AppAccentTheme.honey => t('Miód'),
    AppAccentTheme.voltage => t('Napięcie'),
    AppAccentTheme.amberCrt => t('Bursztyn'),
    AppAccentTheme.nocturne => t('Nokturn'),
    AppAccentTheme.fjord => t('Fiord'),
  };

  /// One-line character sketch shown under the name in the picker.
  String get tagline => switch (this) {
    AppAccentTheme.graphite => t('stal / tusz'),
    AppAccentTheme.paper => t('sepia / atrament'),
    AppAccentTheme.carbon => t('czerń / biel'),
    AppAccentTheme.terminal => t('fosfor / bursztyn'),
    AppAccentTheme.jade => t('jadeit / mięta'),
    AppAccentTheme.moss => t('oliwka / mech'),
    AppAccentTheme.aurora => t('turkus / fiolet'),
    AppAccentTheme.arctic => t('lód / błękit'),
    AppAccentTheme.lagoon => t('laguna / piasek'),
    AppAccentTheme.cobalt => t('błękit / indygo'),
    AppAccentTheme.abyss => t('głębia / stal'),
    AppAccentTheme.denim => t('denim / tan'),
    AppAccentTheme.amethyst => t('ametyst / fuksja'),
    AppAccentTheme.nebula => t('fiolet / róż / cyjan'),
    AppAccentTheme.plum => t('śliwka / mauve'),
    AppAccentTheme.synthwave => t('magenta / cyjan'),
    AppAccentTheme.sakura => t('kwiat wiśni'),
    AppAccentTheme.ruby => t('rubin / złoto'),
    AppAccentTheme.magma => t('lawa / rubin'),
    AppAccentTheme.rust => t('rdza / miedź'),
    AppAccentTheme.coral => t('koral / brzoskwinia'),
    AppAccentTheme.solaris => t('złoto / niebo'),
    AppAccentTheme.honey => t('miód / krem'),
    AppAccentTheme.voltage => t('kwas / limonka'),
    AppAccentTheme.amberCrt => t('bursztynowy CRT'),
    AppAccentTheme.nocturne => t('noc / neon'),
    AppAccentTheme.fjord => t('fiord / szron'),
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

/// Who may invite this person to a new group (§8). Members of a group the
/// person is in may always add people to it.
enum GroupInviteFrom {
  /// Anyone, people who are not friends too (the behaviour before 1.11).
  everyone,

  /// Every friend, weak acquaintances too.
  allFriends,

  /// Friends at level "Znajomy" and up (the default).
  friends,

  /// Only "Przyjaciel".
  closeFriends;

  String get label => switch (this) {
    GroupInviteFrom.everyone => t('Każdy'),
    GroupInviteFrom.allFriends => t('Wszyscy znajomi'),
    GroupInviteFrom.friends => t('Znajomi i przyjaciele'),
    GroupInviteFrom.closeFriends => t('Tylko przyjaciele'),
  };
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
    this.mediaOnlyOnWifi = true,
    this.hideNotificationContent = true,
    this.secureScreens = true,
    this.allowNoAppPassword = false,
    this.bridgeEnabled = true,
    this.permissionsSetupDone = false,
    this.accountSecureOffered = false,
    this.paperBackupDone = false,
    this.groupInviteFrom = GroupInviteFrom.friends,
    this.birthDateMillis = 0,
    this.adultConfirmed = false,
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

  /// Automatic downloads (above) happen only on Wi-Fi or a wired network,
  /// not on mobile data. On for new installs; a settings file written
  /// before this setting existed keeps its behaviour (off).
  final bool mediaOnlyOnWifi;

  /// Whether media may download on their own right now, given whether the
  /// network in use is unmetered ([onUnmetered]).
  bool allowsAutoDownload({required bool onUnmetered}) =>
      autoDownloadMedia && (!mediaOnlyOnWifi || onUnmetered);

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

  /// The first-start card "Zabezpiecz konto" was answered (§6.1, §6.3).
  final bool accountSecureOffered;

  /// The paper copy of the account key was written down and checked.
  final bool paperBackupDone;

  /// Who may invite this person to a new group (§8).
  final GroupInviteFrom groupInviteFrom;

  /// Date of birth from the age gate (§26.1, §27), local midnight in
  /// milliseconds; 0 when not given. Never leaves the device.
  final int birthDateMillis;

  /// The person confirmed being 18 or older instead of giving the date.
  final bool adultConfirmed;

  /// The age gate was answered (a date or the 18+ confirmation).
  bool get ageAnswered => adultConfirmed || birthDateMillis != 0;

  /// Whether the person is 18 or older on [now] (Dating and the adult
  /// sections, §19, §20, §27).
  bool isAdultAt(DateTime now) {
    if (adultConfirmed) {
      return true;
    }
    if (birthDateMillis == 0) {
      return false;
    }
    return ageOn(DateTime.fromMillisecondsSinceEpoch(birthDateMillis), now) >=
        18;
  }

  /// Full years between [birth] and [now].
  static int ageOn(DateTime birth, DateTime now) {
    int years = now.year - birth.year;
    if (now.month < birth.month ||
        (now.month == birth.month && now.day < birth.day)) {
      years--;
    }
    return years;
  }

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

  String get inboxLimitLabel => inboxUnlimited
      ? t('Bez limitu')
      : t('{size} MB', <String, Object?>{'size': inboxLimitMb});

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
    bool? mediaOnlyOnWifi,
    bool? hideNotificationContent,
    bool? secureScreens,
    bool? allowNoAppPassword,
    bool? bridgeEnabled,
    bool? permissionsSetupDone,
    bool? accountSecureOffered,
    bool? paperBackupDone,
    GroupInviteFrom? groupInviteFrom,
    int? birthDateMillis,
    bool? adultConfirmed,
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
      mediaOnlyOnWifi: mediaOnlyOnWifi ?? this.mediaOnlyOnWifi,
      hideNotificationContent:
          hideNotificationContent ?? this.hideNotificationContent,
      secureScreens: secureScreens ?? this.secureScreens,
      allowNoAppPassword: allowNoAppPassword ?? this.allowNoAppPassword,
      bridgeEnabled: bridgeEnabled ?? this.bridgeEnabled,
      permissionsSetupDone: permissionsSetupDone ?? this.permissionsSetupDone,
      accountSecureOffered: accountSecureOffered ?? this.accountSecureOffered,
      paperBackupDone: paperBackupDone ?? this.paperBackupDone,
      groupInviteFrom: groupInviteFrom ?? this.groupInviteFrom,
      birthDateMillis: birthDateMillis ?? this.birthDateMillis,
      adultConfirmed: adultConfirmed ?? this.adultConfirmed,
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
    'mediaOnlyOnWifi': mediaOnlyOnWifi,
    'hideNotificationContent': hideNotificationContent,
    'secureScreens': secureScreens,
    'allowNoAppPassword': allowNoAppPassword,
    'bridgeEnabled': bridgeEnabled,
    'permissionsSetupDone': permissionsSetupDone,
    'accountSecureOffered': accountSecureOffered,
    'paperBackupDone': paperBackupDone,
    'groupInviteFrom': groupInviteFrom.name,
    'birthDateMillis': birthDateMillis,
    'adultConfirmed': adultConfirmed,
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
      // A file from before this setting: downloads keep working on mobile
      // data as they did.
      mediaOnlyOnWifi: pick<bool>('mediaOnlyOnWifi') ?? false,
      hideNotificationContent: pick<bool>('hideNotificationContent'),
      secureScreens: pick<bool>('secureScreens'),
      allowNoAppPassword: pick<bool>('allowNoAppPassword'),
      bridgeEnabled: pick<bool>('bridgeEnabled'),
      permissionsSetupDone: pick<bool>('permissionsSetupDone'),
      accountSecureOffered: pick<bool>('accountSecureOffered'),
      paperBackupDone: pick<bool>('paperBackupDone'),
      groupInviteFrom: byName(GroupInviteFrom.values, 'groupInviteFrom'),
      birthDateMillis: pick<int>('birthDateMillis'),
      adultConfirmed: pick<bool>('adultConfirmed'),
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
