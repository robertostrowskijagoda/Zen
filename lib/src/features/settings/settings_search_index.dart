import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/runtime/presentation/offline_links_section.dart'
    show wifiDirectTitle;
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/settings/notice_kind.dart';

/// The settings search looks past the rows of the settings list into the
/// pages they open: every setting there by its name, what is written under
/// it and a few other words people look for it by ("motyw", "zrzuty",
/// "theme"). Like every search in Zen it runs on this device only and
/// compares folded text ([foldForSearch]): "zrzuty" finds "Zrzuty",
/// "dzwiek" finds "Dźwięk".
///
/// The names here are the ones the pages show (the same texts); the map of
/// the settings test checks that every setting of the map is here and that
/// each name is really on its page.

/// One setting on a settings page.
@immutable
final class SettingsSearchEntry {
  SettingsSearchEntry({
    required this.key,
    required this.row,
    required this.page,
    required this.title,
    this.subtitle = '',
    this.keywords = const <String>[],
  }) : folded = foldForSearch('$page $title $subtitle ${keywords.join(' ')}');

  /// The key of the setting's widget on its page (what is scrolled to and
  /// marked).
  final String key;

  /// The key of the row of the settings list that opens the page.
  final String row;

  /// The page's title.
  final String page;

  /// The setting's name, as the page shows it.
  final String title;

  /// What is written under it.
  final String subtitle;

  /// Other words it is looked for by (not shown).
  final List<String> keywords;

  /// Everything above, folded once.
  final String folded;
}

/// What this device shows of the settings: some are only on one system,
/// some only in one state.
@immutable
final class SettingsSearchDevice {
  const SettingsSearchDevice({
    this.android = false,
    this.ios = false,
    this.inAppSounds = true,
    this.platform = TargetPlatform.android,
    this.disguise = false,
    this.hasPassword = false,
    this.gifSearch = true,
    this.classicPalette = true,
    this.wifiDirect = false,
    this.bluetoothLinks = false,
    this.multipeerLinks = false,
  });

  /// Every setting there is (the tests).
  const SettingsSearchDevice.everything()
    : android = true,
      ios = true,
      inAppSounds = true,
      platform = TargetPlatform.android,
      disguise = true,
      hasPassword = false,
      gifSearch = true,
      classicPalette = true,
      wifiDirect = true,
      bluetoothLinks = true,
      multipeerLinks = true;

  final bool android;
  final bool ios;

  /// Zen's own sounds can be switched (not on iOS, which gives no way to
  /// tell a silenced phone).
  final bool inAppSounds;
  final TargetPlatform platform;

  /// The icon's disguise can be switched (Android, not a store build).
  final bool disguise;

  /// The app password is set (then using it without one is not offered).
  final bool hasPassword;

  /// The GIF search is on (then its own key can be given).
  final bool gifSearch;

  /// The classic palette is chosen (the only one with an accent colour).
  final bool classicPalette;

  final bool wifiDirect;
  final bool bluetoothLinks;
  final bool multipeerLinks;
}

/// Words the rows of the settings list are also found by, by the row's key
/// (their own title and subtitle count as well).
const Map<String, List<String>> kSettingsRowKeywords = <String, List<String>>{
  'settings-nav-account': <String>[
    'konto',
    'kopia klucza',
    'kopia zapasowa',
    'odzyskiwanie',
    'account',
    'backup',
    'recovery',
  ],
  'settings-nav-accounts': <String>['konto', 'konta', 'account'],
  'settings-nav-devices': <String>['telefon', 'komputer', 'device'],
  'settings-nav-security': <String>[
    'hasło',
    'blokada',
    'pin',
    'zrzuty ekranu',
    'biometria',
    'password',
    'lock',
    'security',
  ],
  'settings-nav-contact': <String>[
    'prywatność',
    'status',
    'privacy',
    'visibility',
  ],
  'settings-blocked-button': <String>['blokada', 'blocked'],
  'settings-nav-notifications': <String>[
    'powiadomienia',
    'dźwięk',
    'wibracje',
    'notifications',
    'sound',
  ],
  'settings-nav-recordings': <String>['nagrywanie', 'recordings'],
  'settings-nav-gifs': <String>['gif', 'klipy'],
  'settings-relay-button': <String>[
    'skrzynki',
    'skrzynka',
    'offline',
    'mailbox',
  ],
  'settings-nav-network': <String>[
    'sieć',
    'internet',
    'Wi-Fi',
    'wifi',
    'Wi-Fi Direct',
    'Bluetooth',
    'Yggdrasil',
    'network',
  ],
  'settings-nav-public-peers': <String>[
    'węzły',
    'serwery',
    'Yggdrasil',
    'peers',
    'servers',
  ],
  'settings-nav-nearby-look': <String>['Bluetooth', 'bateria', 'battery'],
  'settings-nav-appearance': <String>[
    'motyw',
    'kolor',
    'ciemny',
    'jasny',
    'theme',
    'appearance',
    'dark mode',
  ],
  'settings-language-tile': <String>['język', 'tłumaczenie', 'language'],
  'settings-nav-data': <String>[
    'pamięć',
    'miejsce',
    'kopie',
    'eksport',
    'czyszczenie',
    'storage',
    'data',
  ],
  'settings-nav-permissions': <String>[
    'uprawnienia',
    'Bluetooth',
    'mikrofon',
    'kamera',
    'permissions',
  ],
  'settings-nav-updates': <String>['aktualizacja', 'wersja', 'update'],
  'settings-nav-health': <String>['problem', 'nie działa', 'help'],
  'settings-nav-diagnostics': <String>['dziennik', 'logi', 'logs'],
  'settings-nav-reset': <String>['reset', 'usuń dane', 'wyczyść'],
};

/// Every setting on the settings pages this [device] shows.
List<SettingsSearchEntry> settingsSearchIndex(SettingsSearchDevice device) {
  final String security = t('Bezpieczeństwo');
  final String contact = t('Kontakt i widoczność');
  final String notifications = t('Powiadomienia i dźwięki');
  final String gifs = t('GIF-y');
  final String network = t('Sieć i usługa');
  final String nearby = t('Rozglądanie w tle');
  final String appearance = t('Wygląd');
  final String data = t('Dane i pamięć');
  final String reset = t('Usuń konto z urządzenia');
  const String securityRow = 'settings-nav-security';
  const String contactRow = 'settings-nav-contact';
  const String notificationsRow = 'settings-nav-notifications';
  const String networkRow = 'settings-nav-network';
  const String appearanceRow = 'settings-nav-appearance';
  const String dataRow = 'settings-nav-data';
  return <SettingsSearchEntry>[
    // Bezpieczeństwo
    SettingsSearchEntry(
      key: 'settings-change-password-button',
      row: securityRow,
      page: security,
      title: t('Hasło aplikacji'),
      subtitle: t('Odblokowuje aplikację i Twoje dane'),
      keywords: const <String>['hasło', 'zmień hasło', 'password'],
    ),
    SettingsSearchEntry(
      key: 'settings-panic-password-button',
      row: securityRow,
      page: security,
      title: t('Hasło awaryjne kasujące'),
      subtitle: t('Wpisane na blokadzie kasuje wszystko'),
      keywords: const <String>['panic', 'kasowanie'],
    ),
    SettingsSearchEntry(
      key: 'settings-biometric-unlock-switch',
      row: securityRow,
      page: security,
      title: device.platform == TargetPlatform.windows
          ? t('Odblokowanie Windows Hello')
          : t('Odblokowanie biometrią'),
      keywords: const <String>[
        'odcisk palca',
        'twarz',
        'biometria',
        'fingerprint',
        'face',
      ],
    ),
    SettingsSearchEntry(
      key: 'settings-lock-mode-dropdown',
      row: securityRow,
      page: security,
      title: t('Automatyczna blokada'),
      keywords: const <String>['blokada', 'zablokuj', 'lock'],
    ),
    SettingsSearchEntry(
      key: 'settings-secure-screens-switch',
      row: securityRow,
      page: security,
      title: t('Blokuj zrzuty i nagrywanie ekranu'),
      subtitle: t(
        'Rozmowy, nagrania, konto i urządzenia nie trafią na '
        'zrzut, nagranie ekranu ani podgląd ostatnich aplikacji.',
      ),
      keywords: const <String>[
        'zrzut ekranu',
        'prywatność ekranu',
        'screenshot',
        'screen recording',
      ],
    ),
    if (!device.hasPassword)
      SettingsSearchEntry(
        key: 'settings-allow-no-password-switch',
        row: securityRow,
        page: security,
        title: t('Pozwól używać aplikacji bez hasła'),
        keywords: const <String>['hasło', 'password'],
      ),
    if (device.disguise)
      SettingsSearchEntry(
        key: 'settings-disguise-icon-switch',
        row: securityRow,
        page: security,
        title: t('Kamuflaż ikony'),
        keywords: const <String>['ikona', 'notatki', 'ukryj', 'disguise'],
      ),
    // Kontakt i widoczność
    SettingsSearchEntry(
      key: 'settings-show-last-opened',
      row: contactRow,
      page: contact,
      title: t('Pokazuj, kiedy ostatnio otwierałem aplikację'),
      keywords: const <String>['status', 'online', 'last seen'],
    ),
    SettingsSearchEntry(
      key: 'stranger-messages-from',
      row: contactRow,
      page: contact,
      title: t('Kto może napisać do mnie spoza znajomych'),
      keywords: const <String>['nieznajomi', 'obcy', 'wiadomości', 'strangers'],
    ),
    SettingsSearchEntry(
      key: 'group-invite-from',
      row: contactRow,
      page: contact,
      title: t('Kto może zapraszać mnie do grup'),
      keywords: const <String>['grupy', 'zaproszenia', 'groups', 'invites'],
    ),
    // Powiadomienia i dźwięki
    SettingsSearchEntry(
      key: 'settings-notification-privacy',
      row: notificationsRow,
      page: notifications,
      title: t('Co mówi powiadomienie'),
      keywords: const <String>[
        'treść',
        'podgląd',
        'ekran blokady',
        'preview',
        'privacy',
      ],
    ),
    if (device.inAppSounds)
      SettingsSearchEntry(
        key: 'settings-in-app-sounds',
        row: notificationsRow,
        page: notifications,
        title: t('Dźwięki w aplikacji'),
        keywords: const <String>['dźwięk', 'sound'],
      ),
    SettingsSearchEntry(
      key: 'settings-notification-sounds',
      row: notificationsRow,
      page: notifications,
      title: t('Dźwięk powiadomień'),
      keywords: const <String>['dźwięk', 'wibracje', 'sound', 'vibration'],
    ),
    for (final NoticeKind kind in NoticeKind.values)
      SettingsSearchEntry(
        key: kind == NoticeKind.friendPost
            ? 'settings-post-notifications'
            : 'settings-notice-${kind.name}',
        row: notificationsRow,
        page: notifications,
        title: kind.label,
        subtitle: kind.description,
        keywords: const <String>['powiadomienia', 'notifications'],
      ),
    SettingsSearchEntry(
      key: 'settings-nav-muted-post-authors',
      row: notificationsRow,
      page: notifications,
      title: t('Wyciszone osoby'),
      keywords: const <String>['wycisz', 'posty', 'mute'],
    ),
    if (device.android)
      SettingsSearchEntry(
        key: 'settings-nav-delivery',
        row: notificationsRow,
        page: notifications,
        title: t('Powiadomienia i praca w tle'),
        subtitle: t('Uprawnienia, dostarczanie w tle, ekran połączeń'),
        keywords: const <String>['bateria', 'tło', 'battery', 'background'],
      ),
    if (device.ios)
      SettingsSearchEntry(
        key: 'settings-nav-ios-background',
        row: notificationsRow,
        page: notifications,
        title: t('Praca w tle'),
        subtitle: t('Sprawdzanie skrzynek w tle, odbieranie cały czas'),
        keywords: const <String>['tło', 'background'],
      ),
    // GIF-y
    SettingsSearchEntry(
      key: 'settings-gif-search',
      row: 'settings-nav-gifs',
      page: gifs,
      title: t('Wyszukiwarka GIF-ów'),
      keywords: const <String>['gif', 'klipy'],
    ),
    if (device.gifSearch)
      SettingsSearchEntry(
        key: 'settings-gif-key-field',
        row: 'settings-nav-gifs',
        page: gifs,
        title: t('Własny klucz Klipy'),
        keywords: const <String>['klucz', 'API key'],
      ),
    // Sieć i usługa
    SettingsSearchEntry(
      key: 'settings-tech-info-tile',
      row: networkRow,
      page: network,
      title: t('Info techniczne'),
      keywords: const <String>['adres', 'ping', 'trasy', 'Yggdrasil', 'IP'],
    ),
    SettingsSearchEntry(
      key: 'settings-lan-discovery-switch',
      row: networkRow,
      page: network,
      title: t('Znajomi w tej samej sieci Wi-Fi'),
      keywords: const <String>[
        'Wi-Fi',
        'wifi',
        'LAN',
        'sieć lokalna',
        'bez internetu',
      ],
    ),
    if (device.wifiDirect)
      SettingsSearchEntry(
        key: 'settings-wifi-direct-switch',
        row: networkRow,
        page: network,
        title: wifiDirectTitle(device.platform),
        keywords: const <String>['Wi-Fi Direct', 'wifi', 'w pobliżu', 'nearby'],
      ),
    if (device.bluetoothLinks)
      SettingsSearchEntry(
        key: 'settings-bluetooth-links-switch',
        row: networkRow,
        page: network,
        title: t('Bluetooth'),
        keywords: const <String>['w pobliżu', 'bez internetu', 'nearby'],
      ),
    if (device.multipeerLinks)
      SettingsSearchEntry(
        key: 'settings-multipeer-links-switch',
        row: networkRow,
        page: network,
        title: t('Apple Wi-Fi/Bluetooth'),
        keywords: const <String>['w pobliżu', 'nearby'],
      ),
    SettingsSearchEntry(
      key: 'settings-serve-pebbles-switch',
      row: networkRow,
      page: network,
      title: t('Udostępniaj zebrane kamyczki'),
      keywords: const <String>['kamyczki', 'kamyki', 'pebbles'],
    ),
    // Rozglądanie w tle
    if (device.android)
      SettingsSearchEntry(
        key: 'settings-nearby-look',
        row: 'settings-nav-nearby-look',
        page: nearby,
        title: t('Rozglądaj się też w tle'),
        keywords: const <String>['Bluetooth', 'bateria', 'battery'],
      ),
    // Wygląd
    SettingsSearchEntry(
      key: 'settings-palette-picker',
      row: appearanceRow,
      page: appearance,
      title: t('Motyw'),
      subtitle: t('Kolory, kształty i ruch całej aplikacji.'),
      keywords: const <String>['paleta', 'styl', 'theme', 'palette'],
    ),
    SettingsSearchEntry(
      key: 'settings-theme-mode-segmented',
      row: appearanceRow,
      page: appearance,
      title: t('Tryb'),
      keywords: const <String>[
        'ciemny',
        'jasny',
        'tryb nocny',
        'motyw',
        'dark mode',
        'light',
      ],
    ),
    SettingsSearchEntry(
      key: 'settings-animations-choice',
      row: appearanceRow,
      page: appearance,
      title: t('Animacje'),
      subtitle: t('Ruch teł motywów i drobnych efektów.'),
      keywords: const <String>['ruch', 'animations', 'motion'],
    ),
    if (device.classicPalette)
      SettingsSearchEntry(
        key: 'settings-accent-picker',
        row: appearanceRow,
        page: appearance,
        title: t('Kolor'),
        keywords: const <String>['akcent', 'accent', 'colour', 'color'],
      ),
    // Dane i pamięć
    SettingsSearchEntry(
      key: 'storage-feed-limit-switch',
      row: dataRow,
      page: data,
      title: t('Osobny limit dla postów znajomych'),
      keywords: const <String>['pamięć', 'miejsce', 'zdjęcia', 'storage'],
    ),
    SettingsSearchEntry(
      key: 'settings-inbox-unlimited-switch',
      row: dataRow,
      page: data,
      title: t('Bez limitu miejsca'),
      keywords: const <String>['pamięć', 'limit', 'storage'],
    ),
    SettingsSearchEntry(
      key: 'settings-auto-cleanup-field',
      row: dataRow,
      page: data,
      title: t('Auto-czyszczenie po ilu dniach'),
      keywords: const <String>['czyszczenie', 'usuwanie', 'cleanup'],
    ),
    SettingsSearchEntry(
      key: 'settings-auto-media',
      row: dataRow,
      page: data,
      title: t('Pobieraj zdjęcia i filmy'),
      keywords: const <String>['pobieranie', 'transfer', 'download', 'media'],
    ),
    SettingsSearchEntry(
      key: 'settings-media-wifi-only',
      row: dataRow,
      page: data,
      title: t('Media tylko przez Wi-Fi'),
      keywords: const <String>[
        'dane komórkowe',
        'mobile data',
        'Wi-Fi',
        'wifi',
      ],
    ),
    SettingsSearchEntry(
      key: 'storage-limits',
      row: dataRow,
      page: data,
      title: t('Limity przechowywania'),
      subtitle: t('Największe dozwolone rozmiary w każdej kategorii'),
      keywords: const <String>['pamięć', 'miejsce', 'kopie', 'storage'],
    ),
    // Usuń konto z urządzenia
    SettingsSearchEntry(
      key: 'desktop-reset-data-button',
      row: 'settings-nav-reset',
      page: reset,
      title: t('Usuń to konto z tego urządzenia'),
      keywords: const <String>['reset', 'usuń dane', 'wyczyść'],
    ),
  ];
}

/// The settings in [index] that [query] finds, in the order of the pages.
List<SettingsSearchEntry> searchSettings(
  SearchQuery query,
  List<SettingsSearchEntry> index,
) => <SettingsSearchEntry>[
  for (final SettingsSearchEntry e in index)
    if (query.matchesFolded(e.folded)) e,
];
