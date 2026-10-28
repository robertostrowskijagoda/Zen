import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The revision of the first-start setup. Bump it when a release adds or
/// changes a setting the person should confirm: the setup then shows once
/// more on the next start, filled in with the current values and with a note
/// that it follows an update. This stands in for migrations — nothing is
/// rewritten behind the person's back.
const int kSetupRevision = 1;

/// Settings of this device rather than of the account: a copy of the
/// account that does not bring the app's lock along (the recovery circle,
/// another device, a backup file without it) never replaces them
/// ([AppSettings.takingCopy]); a backup of the whole app does
/// ([AppSettings.restoringWhole]). The first-start steps (gone through
/// here, they are not asked again because of an older copy and the
/// restarts a restore makes), the lock, the disguised icon (this device's
/// launcher), offering this device as a bridge, and the radios and
/// background reception (this device's permissions and battery).
const Set<String> kDeviceSettingKeys = <String>{
  'setupRevision',
  'permissionsSetupDone',
  'accountSecureOffered',
  'legalAcceptedVersion',
  'legalAcceptedAtMillis',
  'lockMode',
  'backgroundLockDelaySeconds',
  'keepUnlockedAfterClose',
  'allowNoAppPassword',
  'disguiseIcon',
  'bridgeEnabled',
  'lanDiscovery',
  'wifiDirect',
  'bluetoothLinks',
  'multipeerLinks',
  'keepReceivingInBackground',
};

enum AppLockMode {
  never,
  background,
  appClose,
  systemRestart;

  String get label => switch (this) {
    AppLockMode.never => t('Nigdy (bez hasła)'),
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
    AppThemeMode.system => t('Jak w systemie'),
    AppThemeMode.light => t('Jasny'),
    AppThemeMode.dark => t('Ciemny'),
  };

  ThemeMode get materialThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };
}

/// Whether the decorative animations (moving theme backgrounds, pulsing
/// dots, animated avatars) play (Ustawienia → Wygląd → Animacje).
enum AppAnimations {
  /// Always, whatever the system's "remove animations" says. They still
  /// rest while the app or the screen is not shown.
  always,

  /// As the system asks: still when it has "remove animations" (reduced
  /// motion) on.
  system,

  /// Never.
  off;

  String get label => switch (this) {
    AppAnimations.always => t('Włączone'),
    AppAnimations.system => t('Zgodnie z systemem'),
    AppAnimations.off => t('Wyłączone'),
  };

  /// One line under the choice: what it does.
  String get description => switch (this) {
    AppAnimations.always => t(
      'Tła i efekty ruszają się zawsze, także gdy system wyłącza animacje. '
      'Gdy aplikacja jest schowana, stoją.',
    ),
    AppAnimations.system => t(
      'Tła i efekty stoją, gdy system ogranicza ruch albo wyłącza animacje.',
    ),
    AppAnimations.off => t('Żadnych ruchomych teł ani efektów.'),
  };
}

/// How much a notification about a conversation tells: on the lock screen,
/// in the shade and in the system's notification history (Ustawienia →
/// Powiadomienia i dźwięki, and per conversation). Calls and alarms always say who it
/// is: without that they could not be answered.
enum NotificationPrivacy {
  /// Who wrote and a short preview of what (the default).
  senderAndContent,

  /// Who wrote, never what.
  senderOnly,

  /// Only that something came ("Nowa wiadomość").
  generic;

  String get label => switch (this) {
    NotificationPrivacy.senderAndContent => t('Nadawca i treść'),
    NotificationPrivacy.senderOnly => t('Tylko nadawca'),
    NotificationPrivacy.generic => t('Bez nadawcy i treści'),
  };

  /// One line under the choice: what a notification shows.
  String get description => switch (this) {
    NotificationPrivacy.senderAndContent => t(
      'Kto napisał i początek wiadomości.',
    ),
    NotificationPrivacy.senderOnly => t(
      'Kto napisał, bez treści — treść nie trafia do historii powiadomień '
      'systemu.',
    ),
    NotificationPrivacy.generic => t(
      'Tylko „Nowa wiadomość”, bez nadawcy i treści. Połączenia i alarmy '
      'nadal mówią, kto dzwoni.',
    ),
  };

  /// The more private of this and [other].
  NotificationPrivacy atLeast(NotificationPrivacy other) =>
      other.index > index ? other : this;
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

/// The look of the whole app (Ustawienia → Wygląd). [classic] is the
/// accent-driven default ([AppAccentTheme] picks its colour); the others
/// are fixed palettes, each with its own component character (shapes,
/// borders, surfaces, motion, sometimes a backdrop), grouped in the picker
/// by `ZenThemeCategory`. The mode is
/// chosen separately ([AppThemeMode]): every palette has a light and a dark
/// variant. The last group ("Odjechane") are the wild looks with strong
/// effects.
enum AppPalette {
  classic,
  ink,
  graphite,
  calm,
  forest,
  mist,
  neon,
  grid,
  rain,
  player,
  phosphor,
  dusk,
  onyx,
  pearl,
  cipher,
  lightcycle,
  fairy,
  synthwave,
  neonCity,
  arcade,
  space,
  vapor,
  deepSea,
  comic,
  steam,
  holo,
  volcano,
  herbarium,
  sweets,
  cinema,
  blueprint,
  leather;

  String get label => switch (this) {
    AppPalette.classic => t('Klasyczny'),
    AppPalette.ink => t('Atrament'),
    AppPalette.graphite => t('Grafit'),
    AppPalette.calm => t('Cisza'),
    AppPalette.forest => t('Las'),
    AppPalette.mist => t('Mgła'),
    AppPalette.neon => t('Neon'),
    AppPalette.grid => t('Neonowa siatka'),
    AppPalette.rain => t('Cyfrowy deszcz'),
    AppPalette.player => t('Odtwarzacz'),
    AppPalette.phosphor => t('Fosfor'),
    AppPalette.dusk => t('Zmierzch'),
    AppPalette.onyx => t('Onyks'),
    AppPalette.pearl => t('Perła'),
    AppPalette.cipher => t('Zielony szyfr'),
    AppPalette.lightcycle => t('Świetlny tor'),
    AppPalette.fairy => t('Zaczarowana noc'),
    AppPalette.synthwave => t('Retrozachód'),
    AppPalette.neonCity => t('Neonowe miasto'),
    AppPalette.arcade => t('Ośmiobitowiec'),
    AppPalette.space => t('Głęboki kosmos'),
    AppPalette.vapor => t('Pastelowa fala'),
    AppPalette.deepSea => t('Głębina'),
    AppPalette.comic => t('Komiks'),
    AppPalette.steam => t('Mosiądz i para'),
    AppPalette.holo => t('Hologram'),
    AppPalette.volcano => t('Wulkan'),
    AppPalette.herbarium => t('Zielnik'),
    AppPalette.sweets => t('Cukiernia'),
    AppPalette.cinema => t('Kino'),
    AppPalette.blueprint => t('Rysunek techniczny'),
    AppPalette.leather => t('Skóra i nić'),
  };

  String get tagline => switch (this) {
    AppPalette.classic => t('akcent do wyboru'),
    AppPalette.ink => t('papier / granat, ostre rogi'),
    AppPalette.graphite => t('grafit / cyjan / magenta'),
    AppPalette.calm => t('kamień / piasek / łupek'),
    AppPalette.forest => t('mech / papier'),
    AppPalette.mist => t('mgła / błękit, bez ramek'),
    AppPalette.neon => t('czerń / cyjan / magenta, świecące linie'),
    AppPalette.grid => t('cyjan / pomarańcz, siatka po horyzont'),
    AppPalette.rain => t('zielone znaki spływające po czerni'),
    AppPalette.player => t('stary odtwarzacz: LCD / zieleń / chrom'),
    AppPalette.phosphor => t('bursztynowy monitor, linie obrazu'),
    AppPalette.dusk => t('indygo / fiolet'),
    AppPalette.onyx => t('czerń / złoto, podwójne linie'),
    AppPalette.pearl => t('perła / róż, matowe szkło'),
    AppPalette.cipher => t('gęsty deszcz znaków, terminal, zakłócenia'),
    AppPalette.lightcycle => t(
      'cyjan i pomarańcz, ścięte rogi, świetlne smugi',
    ),
    AppPalette.fairy => t('nocne niebo, gwiazdy, złote ornamenty'),
    AppPalette.synthwave => t('pasiaste słońce, fioletowa siatka, chrom'),
    AppPalette.neonCity => t('magenta i żółć, deszcz nad miastem, zakłócenia'),
    AppPalette.arcade => t('piksele, twarde cienie, migające gwiazdki'),
    AppPalette.space => t('gwiazdy, mgławice, szkło kokpitu'),
    AppPalette.vapor => t('pastele, stare okienka, słońce nad siatką'),
    AppPalette.deepSea => t('ciemna toń, świecące drobiny, bąble'),
    AppPalette.comic => t('gruby tusz, raster, twarde cienie'),
    AppPalette.steam => t('nity, sepia, obracające się zębatki'),
    AppPalette.holo => t('tęczowy połysk, matowe szkło'),
    AppPalette.volcano => t('żar, pęknięcia, unoszące się iskry'),
    AppPalette.herbarium => t('szałwia i papier, listki w kształcie ramek'),
    AppPalette.sweets => t('róż i mięta, faliste brzegi, bąbelki'),
    AppPalette.cinema => t('czerwony aksamit, złoto, bilety z wycięciem'),
    AppPalette.blueprint => t(
      'błękit i biel, siatka kreślarska, znaczniki w rogach',
    ),
    AppPalette.leather => t('brąz i krem, szwy zamiast ramek'),
  };
}

/// Who may invite this person to a new group. Members of a group the
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
    this.feedLimitMb = 0,
    this.autoCleanupDays = defaultAutoCleanupDays,
    this.lockMode = defaultLockMode,
    this.backgroundLockDelaySeconds = defaultBackgroundLockDelaySeconds,
    this.keepUnlockedAfterClose = false,
    this.themeMode = defaultThemeMode,
    this.accentTheme = defaultAccentTheme,
    this.palette = defaultPalette,
    this.animations = defaultAnimations,
    this.gifApiKey = '',
    this.gifSearch = true,
    this.autoDownloadMedia = true,
    this.mediaOnlyOnWifi = false,
    this.notificationPrivacy = defaultNotificationPrivacy,
    this.postNotifications = true,
    this.mutedPostAuthors = const <String>{},
    this.inAppSounds = true,
    this.notificationSounds = true,
    this.mutedNotices = NoticeKind.defaultMuted,
    this.secureScreens = true,
    this.allowNoAppPassword = false,
    this.disguiseIcon = false,
    this.bridgeEnabled = true,
    this.setupRevision = 0,
    this.permissionsSetupDone = false,
    this.accountSecureOffered = false,
    this.paperBackupDone = false,
    this.legalAcceptedVersion = '',
    this.legalAcceptedAtMillis = 0,
    this.groupInviteFrom = GroupInviteFrom.friends,
    this.lanDiscovery,
    this.wifiDirect = true,
    this.bluetoothLinks = true,
    this.multipeerLinks = false,
    this.keepReceivingInBackground = false,
    this.showLastOpened = true,
    this.seenTips = const <String>{},
    this.notificationsSeenMillis = 0,
  });

  static const int defaultInboxLimitMb = 1024;
  static const int minimumInboxLimitMb = 5;
  static const int defaultAutoCleanupDays = 0;

  /// Locks when Zen has been in the background for a while (5 min), so a
  /// phone left unlocked on a table does not show the conversations.
  static const AppLockMode defaultLockMode = AppLockMode.background;
  static const int defaultBackgroundLockDelaySeconds = 300;
  static const int minimumBackgroundLockDelaySeconds = 1;
  static const int maximumBackgroundLockDelaySeconds = 3600;
  static const AppThemeMode defaultThemeMode = AppThemeMode.system;
  static const AppAccentTheme defaultAccentTheme = AppAccentTheme.graphite;
  static const AppPalette defaultPalette = AppPalette.classic;
  static const AppAnimations defaultAnimations = AppAnimations.always;
  static const NotificationPrivacy defaultNotificationPrivacy =
      NotificationPrivacy.senderAndContent;

  final int inboxLimitMb;

  /// What other people's posts (their photos and videos) may take on this
  /// phone; 0 = no limit of their own, they share the whole [inboxLimitMb].
  final int feedLimitMb;
  final int autoCleanupDays;
  final AppLockMode lockMode;
  final int backgroundLockDelaySeconds;

  /// "Nie blokuj od razu po zamknięciu aplikacji" (with "Po wyjściu z
  /// aplikacji"): Zen closed by the person or the system opens without the
  /// password until [backgroundLockDelaySeconds] after it left the screen,
  /// as it would have stayed open in the background. Off by default: who
  /// takes the unlocked phone meanwhile opens Zen too.
  final bool keepUnlockedAfterClose;
  final AppThemeMode themeMode;

  /// The accent of the [AppPalette.classic] palette.
  final AppAccentTheme accentTheme;
  final AppPalette palette;

  /// Whether the decorative animations play (on by default, whatever the
  /// system's "remove animations" says).
  final AppAnimations animations;

  /// The user's own Klipy key; empty means the app's shared key is used.
  final String gifApiKey;

  bool get usesOwnGifKey => gifApiKey.isNotEmpty;

  /// GIF search in the chats (the GIF button). It is the one feature that
  /// talks to an outside service (klipy.com); turned off, nothing is ever
  /// sent there and the button is gone. On by default.
  final bool gifSearch;

  /// Photos and videos in posts download on their own (default: yes).
  final bool autoDownloadMedia;

  /// Automatic downloads (above) happen only on Wi-Fi or a wired network,
  /// not on mobile data. Off by default: everything downloads on mobile
  /// data too, unless the person restricts it.
  final bool mediaOnlyOnWifi;

  /// Whether media may download on their own right now, given whether the
  /// network in use is unmetered ([onUnmetered]).
  bool allowsAutoDownload({required bool onUnmetered}) =>
      autoDownloadMedia && (!mediaOnlyOnWifi || onUnmetered);

  /// How much notifications tell (who wrote and what, by default). A
  /// conversation may have its own level
  /// (`SocialHubState.notificationPrivacy`).
  final NotificationPrivacy notificationPrivacy;

  /// "Powiadomienia o nowych postach": a friend's new post is announced
  /// (as told by [notificationPrivacy]) and goes to the in-app list. On by
  /// default; posts from friends of friends never are.
  final bool postNotifications;

  /// Friends whose new posts are not announced ("Wycisz posty tej osoby"),
  /// by normalized address.
  final Set<String> mutedPostAuthors;

  /// Whether new posts of the friend at [address] are announced.
  bool announcesPostsOf(String address) =>
      postNotifications &&
      !mutedPostAuthors.contains(PeerShareCodec.normalizeAddress(address));

  /// "Dźwięki w aplikacji": short sounds inside the app (a message sent or
  /// received in the open chat, a like, a post published, a new entry in
  /// the list of notifications, a call that connects or ends). Never
  /// silences a ringing call or an alarm. On by default.
  final bool inAppSounds;

  /// "Dźwięk powiadomień": the system notifications make their sound (and
  /// vibrate); off, they arrive quietly. A ringing call and an alarm
  /// always do. On by default.
  final bool notificationSounds;

  /// The kinds of news switched off ([NoticeKind]), except the friends'
  /// posts, which [postNotifications] switches. Far friends' posts are off
  /// until the person switches them on.
  final Set<NoticeKind> mutedNotices;

  /// Whether the news of [kind] is switched off: no system notification and
  /// no notification sound (the in-app list still has it).
  bool mutes(NoticeKind kind) => kind == NoticeKind.friendPost
      ? !postNotifications
      : mutedNotices.contains(kind);

  /// Screenshots and screen recording are blocked on conversations and
  /// account screens, and their content is hidden in the recent-apps view.
  /// On by default.
  final bool secureScreens;

  /// Android: the launcher shows a neutral "Notatki" icon and name instead
  /// of Zen's (camouflage). Off by default.
  final bool disguiseIcon;

  /// The user chose to run without an app password (it is required
  /// by default). Off by default.
  final bool allowNoAppPassword;

  /// A computer helps others connect (a mesh bridge). On by default
  /// and not advertised; it can be switched off at the bottom of the
  /// settings (Sieć i usługa).
  final bool bridgeEnabled;

  /// The [kSetupRevision] of the setup (the lock, notifications, gates,
  /// animations) this person last went through or skipped; 0: never. The
  /// setup shows again while it is lower than [kSetupRevision] (Ustawienia
  /// opens it any time).
  final int setupRevision;

  /// The setup is due: never shown, or a release asked for it again.
  bool get setupPending => setupRevision < kSetupRevision;

  /// The first-start step "Uprawnienia i Bluetooth" was gone
  /// through: it is not shown again (it stays under Ustawienia).
  final bool permissionsSetupDone;

  /// The first-start card "Zabezpiecz konto" was answered.
  final bool accountSecureOffered;

  /// The paper copy of the account key was written down and checked.
  final bool paperBackupDone;

  /// The version of the terms, the privacy policy and the licence notice
  /// the person accepted on the first start ('' = not yet). A newer version
  /// of the documents asks again.
  final String legalAcceptedVersion;

  /// When they were accepted (milliseconds since the epoch, 0 = never).
  final int legalAcceptedAtMillis;

  /// Who may invite this person to a new group.
  final GroupInviteFrom groupInviteFrom;

  /// "Znajomi w tej samej sieci Wi-Fi": friends' and the
  /// account's own devices on one network connect directly, also without
  /// internet. `null` until the person chooses.
  final bool? lanDiscovery;

  /// Whether LAN discovery runs on this device: on unless the person turned
  /// it off. Its beacons tell strangers nothing about who is there
  /// (native/yggdrasil_bridge/local_link.go).
  bool get lanDiscoveryOn => lanDiscovery ?? true;

  /// "Wi-Fi Direct (Android)": with no Wi-Fi network around, nearby
  /// friends' phones form a Wi-Fi Direct group and link over it. On by
  /// default: its permission is asked on the first start, and it runs only
  /// while it can help — Zen used (or its background service running), no
  /// Wi-Fi network, and friends' devices to link with.
  final bool wifiDirect;

  /// "Bluetooth": nearby friends' devices link over Bluetooth when there is
  /// no network (slow: text and photos; calls may not work). On by default:
  /// its permission is asked on the first start, and it runs only while Zen
  /// is used (or its background service runs) and there are friends'
  /// devices to link with, advertising and scanning in short windows.
  final bool bluetoothLinks;

  /// "Apple Wi-Fi/Bluetooth" (iPhone, iPad, Mac): Apple's Multipeer
  /// Connectivity between nearby Apple devices. Off by default.
  final bool multipeerLinks;

  /// iPhone: "Odbieraj w tle cały czas" — a silent sound keeps Zen running
  /// off the screen, so messages and calls come at once. Off by default: it
  /// costs a lot of battery (docs/IOS_BACKGROUND.md).
  final bool keepReceivingInBackground;

  /// "Pokazuj, kiedy ostatnio otwierałem aplikację": friends who see this
  /// person's presence also see when Zen was last open here. On by default.
  final bool showLastOpened;

  /// One-time cards and reminders already shown or dismissed, by id (see
  /// `ZenTips`): a card shows until its id is here.
  final Set<String> seenTips;

  /// The newest entry of the in-app notification list that was on screen the
  /// last time it was opened; newer ones count on the bell.
  final int notificationsSeenMillis;

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

  /// How long the signal transport waits for the next signal in one go
  /// (a technical constant, not a setting). Signals end the wait as they
  /// come and stopping the node ends it at once, so a long wait only means
  /// fewer pointless wake-ups.
  Duration get signalWaitTimeout => const Duration(seconds: 30);

  String get inboxLimitLabel =>
      inboxUnlimited ? t('Bez limitu') : storageLimitLabel(inboxLimitMb);

  /// `512 MB` / `1 GB` / `1.5 GB` for a limit in MB.
  static String storageLimitLabel(int mb) {
    if (mb < 1024) {
      return t('{size} MB', <String, Object?>{'size': mb});
    }
    final double gb = mb / 1024;
    return t('{size} GB', <String, Object?>{
      'size': gb == gb.roundToDouble() ? gb.round() : gb.toStringAsFixed(1),
    });
  }

  /// The values of the storage limit sliders, in MB.
  static const List<int> storageLimitStepsMb = <int>[
    10,
    25,
    50,
    100,
    250,
    500,
    1024,
    2048,
    5120,
    10240,
  ];

  AppSettings copyWith({
    int? inboxLimitMb,
    int? feedLimitMb,
    int? autoCleanupDays,
    AppLockMode? lockMode,
    int? backgroundLockDelaySeconds,
    bool? keepUnlockedAfterClose,
    AppThemeMode? themeMode,
    AppAccentTheme? accentTheme,
    AppPalette? palette,
    AppAnimations? animations,
    String? gifApiKey,
    bool? gifSearch,
    bool? autoDownloadMedia,
    bool? mediaOnlyOnWifi,
    NotificationPrivacy? notificationPrivacy,
    bool? postNotifications,
    Set<String>? mutedPostAuthors,
    bool? inAppSounds,
    bool? notificationSounds,
    Set<NoticeKind>? mutedNotices,
    bool? secureScreens,
    bool? allowNoAppPassword,
    bool? disguiseIcon,
    bool? bridgeEnabled,
    int? setupRevision,
    bool? permissionsSetupDone,
    bool? accountSecureOffered,
    bool? paperBackupDone,
    String? legalAcceptedVersion,
    int? legalAcceptedAtMillis,
    GroupInviteFrom? groupInviteFrom,
    bool? lanDiscovery,
    bool? wifiDirect,
    bool? bluetoothLinks,
    bool? multipeerLinks,
    bool? keepReceivingInBackground,
    bool? showLastOpened,
    Set<String>? seenTips,
    int? notificationsSeenMillis,
  }) {
    return AppSettings(
      inboxLimitMb: normalizeInboxLimitMb(inboxLimitMb ?? this.inboxLimitMb),
      feedLimitMb: normalizeInboxLimitMb(feedLimitMb ?? this.feedLimitMb),
      autoCleanupDays: normalizeAutoCleanupDays(
        autoCleanupDays ?? this.autoCleanupDays,
      ),
      lockMode: lockMode ?? this.lockMode,
      backgroundLockDelaySeconds: normalizeBackgroundLockDelaySeconds(
        backgroundLockDelaySeconds ?? this.backgroundLockDelaySeconds,
      ),
      keepUnlockedAfterClose:
          keepUnlockedAfterClose ?? this.keepUnlockedAfterClose,
      themeMode: themeMode ?? this.themeMode,
      accentTheme: accentTheme ?? this.accentTheme,
      palette: palette ?? this.palette,
      animations: animations ?? this.animations,
      gifApiKey: normalizeGifApiKey(gifApiKey ?? this.gifApiKey),
      gifSearch: gifSearch ?? this.gifSearch,
      autoDownloadMedia: autoDownloadMedia ?? this.autoDownloadMedia,
      mediaOnlyOnWifi: mediaOnlyOnWifi ?? this.mediaOnlyOnWifi,
      notificationPrivacy: notificationPrivacy ?? this.notificationPrivacy,
      postNotifications: postNotifications ?? this.postNotifications,
      mutedPostAuthors: mutedPostAuthors ?? this.mutedPostAuthors,
      inAppSounds: inAppSounds ?? this.inAppSounds,
      notificationSounds: notificationSounds ?? this.notificationSounds,
      mutedNotices: mutedNotices ?? this.mutedNotices,
      secureScreens: secureScreens ?? this.secureScreens,
      allowNoAppPassword: allowNoAppPassword ?? this.allowNoAppPassword,
      disguiseIcon: disguiseIcon ?? this.disguiseIcon,
      bridgeEnabled: bridgeEnabled ?? this.bridgeEnabled,
      setupRevision: setupRevision ?? this.setupRevision,
      permissionsSetupDone: permissionsSetupDone ?? this.permissionsSetupDone,
      accountSecureOffered: accountSecureOffered ?? this.accountSecureOffered,
      paperBackupDone: paperBackupDone ?? this.paperBackupDone,
      legalAcceptedVersion: legalAcceptedVersion ?? this.legalAcceptedVersion,
      legalAcceptedAtMillis:
          legalAcceptedAtMillis ?? this.legalAcceptedAtMillis,
      groupInviteFrom: groupInviteFrom ?? this.groupInviteFrom,
      lanDiscovery: lanDiscovery ?? this.lanDiscovery,
      wifiDirect: wifiDirect ?? this.wifiDirect,
      bluetoothLinks: bluetoothLinks ?? this.bluetoothLinks,
      multipeerLinks: multipeerLinks ?? this.multipeerLinks,
      keepReceivingInBackground:
          keepReceivingInBackground ?? this.keepReceivingInBackground,
      showLastOpened: showLastOpened ?? this.showLastOpened,
      seenTips: seenTips ?? this.seenTips,
      notificationsSeenMillis:
          notificationsSeenMillis ?? this.notificationsSeenMillis,
    );
  }

  /// [copy] (the settings in a copy of the account) as this device takes
  /// it: the account's choices from [copy], this device's own
  /// ([kDeviceSettingKeys]) as they are here. The setup counts as gone
  /// through when it was on either side; terms accepted here stay (the
  /// copy's only when none were accepted here yet).
  AppSettings takingCopy(AppSettings copy) {
    final Map<String, Object> here = toJson();
    final Map<String, Object> merged = copy.toJson();
    for (final String key in kDeviceSettingKeys) {
      merged.remove(key);
      final Object? value = here[key];
      if (value != null) {
        merged[key] = value;
      }
    }
    if (legalAcceptedVersion.isEmpty) {
      merged['legalAcceptedVersion'] = copy.legalAcceptedVersion;
      merged['legalAcceptedAtMillis'] = copy.legalAcceptedAtMillis;
    }
    merged['setupRevision'] = setupRevision > copy.setupRevision
        ? setupRevision
        : copy.setupRevision;
    return AppSettings.fromJson(merged);
  }

  /// [copy] (the settings in a backup of the whole app, which brings the
  /// app password along) as this device takes it: as they were — the lock,
  /// the first-start steps and the setup's revision (the setup shows once
  /// only when the backup's is older than this app's), the radios, the
  /// disguised icon. Only the terms keep the latest acceptance, here or in
  /// the backup: accepted on either side, they count.
  AppSettings restoringWhole(AppSettings copy) {
    // The system's permissions belong to this phone, not to the copy: the
    // permissions step stays as it is here.
    final AppSettings whole = copy.copyWith(
      permissionsSetupDone: permissionsSetupDone,
    );
    return legalAcceptedAtMillis > copy.legalAcceptedAtMillis
        ? whole.copyWith(
            legalAcceptedVersion: legalAcceptedVersion,
            legalAcceptedAtMillis: legalAcceptedAtMillis,
          )
        : whole;
  }

  /// Named fields: an unknown field is ignored and a missing one keeps its
  /// default, so a new setting needs no format version.
  Map<String, Object> toJson() => <String, Object>{
    'inboxLimitMb': inboxLimitMb,
    'feedLimitMb': feedLimitMb,
    'autoCleanupDays': autoCleanupDays,
    'lockMode': lockMode.name,
    'backgroundLockDelaySeconds': backgroundLockDelaySeconds,
    'keepUnlockedAfterClose': keepUnlockedAfterClose,
    'themeMode': themeMode.name,
    'accentTheme': accentTheme.name,
    'palette': palette.name,
    'animations': animations.name,
    'gifApiKey': gifApiKey,
    'gifSearch': gifSearch,
    'autoDownloadMedia': autoDownloadMedia,
    'mediaOnlyOnWifi': mediaOnlyOnWifi,
    'notificationPrivacy': notificationPrivacy.name,
    'postNotifications': postNotifications,
    if (mutedPostAuthors.isNotEmpty)
      'mutedPostAuthors': mutedPostAuthors.toList(growable: false),
    'inAppSounds': inAppSounds,
    'notificationSounds': notificationSounds,
    'mutedNotices': <String>[for (final NoticeKind k in mutedNotices) k.name],
    'secureScreens': secureScreens,
    'allowNoAppPassword': allowNoAppPassword,
    'disguiseIcon': disguiseIcon,
    'bridgeEnabled': bridgeEnabled,
    'setupRevision': setupRevision,
    'permissionsSetupDone': permissionsSetupDone,
    'accountSecureOffered': accountSecureOffered,
    'paperBackupDone': paperBackupDone,
    'legalAcceptedVersion': legalAcceptedVersion,
    'legalAcceptedAtMillis': legalAcceptedAtMillis,
    'groupInviteFrom': groupInviteFrom.name,
    'lanDiscovery': ?lanDiscovery,
    'wifiDirect': wifiDirect,
    'bluetoothLinks': bluetoothLinks,
    'multipeerLinks': multipeerLinks,
    'keepReceivingInBackground': keepReceivingInBackground,
    'showLastOpened': showLastOpened,
    if (seenTips.isNotEmpty) 'seenTips': seenTips.toList(growable: false),
    if (notificationsSeenMillis > 0)
      'notificationsSeenMillis': notificationsSeenMillis,
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
      feedLimitMb: pick<int>('feedLimitMb'),
      autoCleanupDays: pick<int>('autoCleanupDays'),
      lockMode: byName(AppLockMode.values, 'lockMode'),
      backgroundLockDelaySeconds: pick<int>('backgroundLockDelaySeconds'),
      keepUnlockedAfterClose: pick<bool>('keepUnlockedAfterClose'),
      themeMode: byName(AppThemeMode.values, 'themeMode'),
      accentTheme: byName(AppAccentTheme.values, 'accentTheme'),
      palette: byName(AppPalette.values, 'palette'),
      animations: byName(AppAnimations.values, 'animations'),
      gifApiKey: pick<String>('gifApiKey'),
      gifSearch: pick<bool>('gifSearch'),
      autoDownloadMedia: pick<bool>('autoDownloadMedia'),
      mediaOnlyOnWifi: pick<bool>('mediaOnlyOnWifi'),
      notificationPrivacy: byName(
        NotificationPrivacy.values,
        'notificationPrivacy',
      ),
      postNotifications: pick<bool>('postNotifications'),
      mutedPostAuthors: switch (json['mutedPostAuthors']) {
        final List<dynamic> addresses =>
          addresses
              .whereType<String>()
              .map(PeerShareCodec.normalizeAddress)
              .toSet(),
        _ => null,
      },
      inAppSounds: pick<bool>('inAppSounds'),
      notificationSounds: pick<bool>('notificationSounds'),
      mutedNotices: switch (json['mutedNotices']) {
        final List<dynamic> names => <NoticeKind>{
          for (final Object? name in names)
            if (NoticeKind.byName(name) case final NoticeKind kind) kind,
        },
        _ => null,
      },
      secureScreens: pick<bool>('secureScreens'),
      allowNoAppPassword: pick<bool>('allowNoAppPassword'),
      disguiseIcon: pick<bool>('disguiseIcon'),
      bridgeEnabled: pick<bool>('bridgeEnabled'),
      setupRevision: pick<int>('setupRevision'),
      permissionsSetupDone: pick<bool>('permissionsSetupDone'),
      accountSecureOffered: pick<bool>('accountSecureOffered'),
      paperBackupDone: pick<bool>('paperBackupDone'),
      legalAcceptedVersion: pick<String>('legalAcceptedVersion'),
      legalAcceptedAtMillis: pick<int>('legalAcceptedAtMillis'),
      groupInviteFrom: byName(GroupInviteFrom.values, 'groupInviteFrom'),
      lanDiscovery: pick<bool>('lanDiscovery'),
      wifiDirect: pick<bool>('wifiDirect'),
      bluetoothLinks: pick<bool>('bluetoothLinks'),
      multipeerLinks: pick<bool>('multipeerLinks'),
      keepReceivingInBackground: pick<bool>('keepReceivingInBackground'),
      showLastOpened: pick<bool>('showLastOpened'),
      seenTips: switch (json['seenTips']) {
        final List<dynamic> ids => ids.whereType<String>().toSet(),
        _ => null,
      },
      notificationsSeenMillis: pick<int>('notificationsSeenMillis'),
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
