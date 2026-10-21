import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/runtime/bluetooth_local_links.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/local_links_controller.dart';
import 'package:zen/src/features/runtime/wifi_direct_local_link.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Whether this device offers the "Wi-Fi Direct" switch (Android, Windows).
final Provider<bool> wifiDirectAvailableProvider = Provider<bool>(
  (Ref ref) => wifiDirectLinksPlatform,
);

/// Whether this device offers the "Bluetooth" switch.
final Provider<bool> bluetoothLinksAvailableProvider = Provider<bool>(
  (Ref ref) => bluetoothLinksPlatform,
);

/// Whether this device offers the "Apple Wi-Fi/Bluetooth" switch.
final Provider<bool> multipeerLinksAvailableProvider = Provider<bool>(
  (Ref ref) => multipeerLinksPlatform,
);

bool _isOn(LocalLinkState? state) =>
    state != null &&
    state.phase != LocalLinkPhase.off &&
    state.phase != LocalLinkPhase.unavailable;

/// The status line: how many devices are linked directly now, and how.
String localLinksStatusText(
  LocalLinksStatus status, {
  required bool lanOn,
  LocalLinkState? wifiDirect,
  LocalLinkState? bluetooth,
  LocalLinkState? multipeer,
}) {
  final List<LocalLinkInfo> up = status.upLinks;
  if (up.isNotEmpty) {
    int over(LocalLinkTransport transport) =>
        up.where((LocalLinkInfo l) => l.transport == transport).length;
    final int lan = over(LocalLinkTransport.lan);
    final int direct = over(LocalLinkTransport.wifiDirect);
    final int blue = over(LocalLinkTransport.bluetooth);
    final int apple = over(LocalLinkTransport.multipeer);
    final int other = up.length - lan - direct - blue - apple;
    final List<String> parts = <String>[
      if (lan > 0) t('Wi-Fi: {n}', <String, Object?>{'n': lan}),
      if (direct > 0) t('Wi-Fi Direct: {n}', <String, Object?>{'n': direct}),
      if (blue > 0) t('Bluetooth: {n}', <String, Object?>{'n': blue}),
      if (apple > 0) t('Apple: {n}', <String, Object?>{'n': apple}),
      if (other > 0) t('inne: {n}', <String, Object?>{'n': other}),
    ];
    return tn(
      up.length,
      one: 'Połączone bezpośrednio: {n} urządzenie ({how})',
      few: 'Połączone bezpośrednio: {n} urządzenia ({how})',
      many: 'Połączone bezpośrednio: {n} urządzeń ({how})',
      args: <String, Object?>{'how': parts.join(', ')},
    );
  }
  if (wifiDirect?.phase == LocalLinkPhase.needsPermission) {
    return t('Wi-Fi Direct czeka na zgodę „Urządzenia w pobliżu”.');
  }
  if (bluetooth?.phase == LocalLinkPhase.needsPermission) {
    return t('Bluetooth czeka na Twoją zgodę.');
  }
  final bool nearbyOn = _isOn(bluetooth) || _isOn(multipeer);
  if (!lanOn && !nearbyOn) {
    return t('Wyłączone: łączysz się ze znajomymi tylko przez internet.');
  }
  if (lanOn && status.lanError != null) {
    return t('Sieć lokalna jest teraz niedostępna.');
  }
  if (wifiDirect?.phase == LocalLinkPhase.searching) {
    return t('Szukam znajomych w pobliżu (Wi-Fi Direct)…');
  }
  if (status.lanOn && status.peerCount == 0) {
    return t('Nie ma jeszcze z kim się łączyć.');
  }
  if (bluetooth?.phase == LocalLinkPhase.searching) {
    return t('Szukam znajomych w pobliżu (Bluetooth)…');
  }
  if (multipeer?.phase == LocalLinkPhase.searching) {
    return t('Szukam znajomych w pobliżu (Apple Wi-Fi/Bluetooth)…');
  }
  if (lanOn && status.lanRunning && status.interfaces.isNotEmpty) {
    return t('Szukam znajomych w tej sieci…');
  }
  if (bluetooth?.phase == LocalLinkPhase.radioOff) {
    return t('Bluetooth jest wyłączony.');
  }
  return t('Brak połączeń lokalnych.');
}

/// Where Bluetooth links work on this platform, for the switch.
String bluetoothLinksNote(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => t(
    'Działa, gdy Zen jest otwarty albo działa w tle. Na Androidzie 9 i '
    'starszym tylko z urządzeniami sparowanymi w ustawieniach Bluetooth.',
  ),
  TargetPlatform.iOS => t(
    'Na iPhonie i iPadzie działa tylko, gdy Zen jest otwarty na ekranie.',
  ),
  TargetPlatform.windows => t(
    'Na Windows z telefonami z Androidem i komputerami z Windows w pobliżu, '
    'a z urządzeniami sparowanymi w ustawieniach Bluetooth systemu także '
    'przez klasyczny Bluetooth (bez iPhone’ów i Maków).',
  ),
  _ => t('Działa, gdy Zen jest otwarty.'),
};

/// The "Wi-Fi Direct" switch's title on this platform.
String wifiDirectTitle(TargetPlatform platform) =>
    platform == TargetPlatform.windows
    ? t('Wi-Fi Direct (Windows)')
    : t('Wi-Fi Direct (Android)');

/// What the "Wi-Fi Direct" switch does on this platform.
String wifiDirectNote(TargetPlatform platform) =>
    platform == TargetPlatform.windows
    ? t(
        'Gdy komputer nie jest połączony z siecią Wi-Fi, łączy się '
        'bezpośrednio z komputerami znajomych z Windows w pobliżu. Nie '
        'przeszkadza w zwykłym Wi-Fi: po połączeniu z siecią przestaje '
        'działać, a na kartach Wi-Fi, które nie umieją obu naraz, jest '
        'wyłączone. Działa, gdy Zen jest otwarty.',
      )
    : t(
        'Gdy w pobliżu nie ma sieci Wi-Fi, telefony znajomych '
        'tworzą między sobą własną sieć. Działa, gdy Zen jest '
        'otwarty albo działa w tle; zużywa trochę więcej '
        'baterii.',
      );

/// "Łączność bez internetu": friends nearby link directly, so
/// chats and calls work without internet. The settings page puts it in a
/// panel.
class OfflineLinksSection extends ConsumerStatefulWidget {
  const OfflineLinksSection({super.key});

  /// How often the status line is read from the bridge.
  static const Duration refresh = Duration(seconds: 3);

  @override
  ConsumerState<OfflineLinksSection> createState() =>
      _OfflineLinksSectionState();
}

class _OfflineLinksSectionState extends ConsumerState<OfflineLinksSection> {
  Timer? _timer;
  LocalLinksStatus _status = LocalLinksStatus.empty;

  @override
  void initState() {
    super.initState();
    _read();
    _timer = Timer.periodic(OfflineLinksSection.refresh, (_) => _read());
  }

  void _read() {
    final LocalLinksStatus next = ref.read(localLinksStatusReaderProvider)();
    if (mounted) {
      setState(() => _status = next);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  LocalLink? _link(LocalLinkTransport transport) {
    for (final LocalLink link
        in ref.read(localLinksControllerProvider).transports) {
      if (link.transport == transport) {
        return link;
      }
    }
    return null;
  }

  Future<void> _setBluetooth(bool value) async {
    final AppSettingsController settings = ref.read(
      appSettingsControllerProvider.notifier,
    );
    if (value) {
      // The system asks once; the link starts when it is given.
      await _link(LocalLinkTransport.bluetooth)?.requestPermissions();
    }
    await settings.setBluetoothLinks(value);
  }

  Future<void> _setMultipeer(bool value) async {
    final AppSettingsController settings = ref.read(
      appSettingsControllerProvider.notifier,
    );
    if (value) {
      await _link(LocalLinkTransport.multipeer)?.requestPermissions();
    }
    await settings.setMultipeerLinks(value);
  }

  Future<void> _setWifiDirect(bool value) async {
    final AppSettingsController settings = ref.read(
      appSettingsControllerProvider.notifier,
    );
    if (value) {
      // The system asks once; the link starts when it is given.
      await _link(LocalLinkTransport.wifiDirect)?.requestPermissions();
    }
    await settings.setWifiDirect(value);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final bool wifiDirectAvailable = ref.watch(wifiDirectAvailableProvider);
    final bool bluetoothAvailable = ref.watch(bluetoothLinksAvailableProvider);
    final bool multipeerAvailable = ref.watch(multipeerLinksAvailableProvider);
    final LocalLink? wifiDirect = wifiDirectAvailable
        ? _link(LocalLinkTransport.wifiDirect)
        : null;
    final LocalLink? bluetooth = bluetoothAvailable
        ? _link(LocalLinkTransport.bluetooth)
        : null;
    final LocalLink? multipeer = multipeerAvailable
        ? _link(LocalLinkTransport.multipeer)
        : null;
    final TextStyle titleStyle = TextStyle(
      color: zen.textPrimary,
      fontSize: 15.5,
      fontWeight: FontWeight.w700,
    );
    final TextStyle bodyStyle = TextStyle(
      color: zen.textSecondary,
      fontSize: 13.5,
      height: 1.4,
    );
    Widget statusLine() => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: <Widget>[
          Icon(
            _status.upLinks.isEmpty
                ? Icons.wifi_tethering_off_rounded
                : Icons.wifi_tethering_rounded,
            size: 18,
            color: _status.upLinks.isEmpty ? zen.textMuted : zen.success,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              localLinksStatusText(
                _status,
                lanOn: settings.lanDiscoveryOn,
                wifiDirect: wifiDirect?.state.value,
                bluetooth: settings.bluetoothLinks
                    ? bluetooth?.state.value
                    : null,
                multipeer: settings.multipeerLinks
                    ? multipeer?.state.value
                    : null,
              ),
              key: const Key('offline-links-status'),
              style: bodyStyle,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t('Łączność bez internetu'), style: titleStyle),
        const SizedBox(height: 4),
        Text(
          t(
            'Znajomi w pobliżu łączą się z Tobą bezpośrednio: wiadomości, '
            'rozmowy i wszystko inne działa też bez internetu.',
          ),
          style: bodyStyle,
        ),
        SwitchListTile.adaptive(
          key: const Key('settings-lan-discovery-switch'),
          contentPadding: EdgeInsets.zero,
          value: settings.lanDiscoveryOn,
          onChanged: (bool value) => unawaited(
            ref
                .read(appSettingsControllerProvider.notifier)
                .setLanDiscovery(value),
          ),
          title: Text(t('Znajomi w tej samej sieci Wi-Fi'), style: titleStyle),
          subtitle: Text(
            t(
              'Twoje urządzenia i znajomi w tej samej sieci (Wi-Fi, kabel, '
              'hotspot) łączą się ze sobą bezpośrednio. Inni w tej sieci '
              'widzą tylko losowe dane: nie wiedzą, kim jesteś, i nie '
              'połączą się z Tobą.',
            ),
            style: bodyStyle,
          ),
        ),
        if (wifiDirectAvailable)
          SwitchListTile.adaptive(
            key: const Key('settings-wifi-direct-switch'),
            contentPadding: EdgeInsets.zero,
            value: settings.wifiDirect && settings.lanDiscoveryOn,
            onChanged: settings.lanDiscoveryOn
                ? (bool value) => unawaited(_setWifiDirect(value))
                : null,
            title: Text(
              wifiDirectTitle(defaultTargetPlatform),
              style: titleStyle,
            ),
            subtitle: Text(
              settings.lanDiscoveryOn
                  ? wifiDirectNote(defaultTargetPlatform)
                  : t('Najpierw włącz „Znajomi w tej samej sieci Wi-Fi”.'),
              style: bodyStyle,
            ),
          ),
        if (bluetoothAvailable)
          SwitchListTile.adaptive(
            key: const Key('settings-bluetooth-links-switch'),
            contentPadding: EdgeInsets.zero,
            value: settings.bluetoothLinks,
            onChanged: (bool value) => unawaited(_setBluetooth(value)),
            title: Text(t('Bluetooth'), style: titleStyle),
            subtitle: Text(
              <String>[
                t(
                  'Gdy w pobliżu nie ma sieci, urządzenia znajomych (do '
                  'kilkunastu metrów) łączą się przez Bluetooth. To wolne '
                  'łącze: wystarczy na wiadomości i zdjęcia, rozmowy mogą '
                  'nie działać. Zużywa trochę więcej baterii.',
                ),
                bluetoothLinksNote(defaultTargetPlatform),
              ].join(' '),
              style: bodyStyle,
            ),
          ),
        if (multipeerAvailable)
          SwitchListTile.adaptive(
            key: const Key('settings-multipeer-links-switch'),
            contentPadding: EdgeInsets.zero,
            value: settings.multipeerLinks,
            onChanged: (bool value) => unawaited(_setMultipeer(value)),
            title: Text(t('Apple Wi-Fi/Bluetooth'), style: titleStyle),
            subtitle: Text(
              t(
                'iPhone’y, iPady i Maki znajomych w pobliżu łączą się '
                'bezpośrednio (Wi-Fi między urządzeniami i Bluetooth), '
                'także bez sieci. Szybsze niż sam Bluetooth. Działa tylko, '
                'gdy Zen jest otwarty na ekranie.',
              ),
              style: bodyStyle,
            ),
          ),
        ListenableBuilder(
          listenable: Listenable.merge(<Listenable?>[
            wifiDirect?.state,
            bluetooth?.state,
            multipeer?.state,
          ]),
          builder: (BuildContext context, _) => statusLine(),
        ),
      ],
    );
  }
}
