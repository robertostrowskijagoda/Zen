import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/permissions/presentation/vendor_battery_help.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/presentation/ios_background_section.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// "Uprawnienia i Bluetooth" from the settings.
class PermissionsScreen extends StatelessWidget {
  const PermissionsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const PermissionsScreen(),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('permissions-screen'),
    appBar: AppBar(title: Text(t('Uprawnienia i Bluetooth'))),
    body: const SafeArea(top: false, child: PermissionsPanel()),
  );
}

/// The first start, right after the app password: the same steps
/// once; this phone is shown nearby only if the person turns that on.
class PermissionsSetupStage extends StatelessWidget {
  const PermissionsSetupStage({this.welcome = true, super.key});

  /// The welcome above the steps (not when the first-start setup came
  /// first and said it).
  final bool welcome;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('permissions-setup'),
    body: SafeArea(child: PermissionsPanel(firstStart: true, welcome: welcome)),
  );
}

/// The steps, one button each; what is allowed already says so.
class PermissionsPanel extends ConsumerStatefulWidget {
  const PermissionsPanel({
    this.firstStart = false,
    this.welcome = true,
    super.key,
  });

  /// The first start: a "Gotowe" button at the end, visibility applied
  /// only then.
  final bool firstStart;

  /// On the first start: the welcome above the steps.
  final bool welcome;

  @override
  ConsumerState<PermissionsPanel> createState() => _PermissionsPanelState();
}

class _PermissionsPanelState extends ConsumerState<PermissionsPanel>
    with WidgetsBindingObserver {
  late final PermissionsPlatform _platform = ref.read(
    permissionsPlatformProvider,
  );
  PermissionsSnapshot? _snapshot;

  /// Asked once already: Android stops showing its dialog after a "no",
  /// so the next tap opens the system settings instead.
  final Set<ZenPermission> _asked = <ZenPermission>{};
  ZenPermission? _busy;

  /// Shown to people nearby (on by default; the person can turn it off).
  bool _visible = true;
  bool _finishing = false;
  StreamSubscription<bool>? _bluetooth;
  Timer? _later;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bluetooth = _platform.bluetoothChanges.listen((bool _) {
      unawaited(_refresh());
    });
    if (!widget.firstStart && _platform.hasBluetooth) {
      _visible = ref.read(meetServiceProvider).book.nearbyVisible;
    }
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_bluetooth?.cancel());
    _later?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from a system dialog or the system settings.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final PermissionsSnapshot snapshot = await _platform.check();
    if (!mounted) {
      return;
    }
    setState(() => _snapshot = snapshot);
  }

  /// Runtime permissions: after a "no" only the settings can change them.
  static bool _settingsAfterNo(ZenPermission p) => switch (p) {
    ZenPermission.notifications ||
    ZenPermission.bluetooth ||
    ZenPermission.location ||
    ZenPermission.backgroundLocation ||
    ZenPermission.microphone ||
    ZenPermission.camera => true,
    ZenPermission.bluetoothOn ||
    ZenPermission.fullScreen ||
    ZenPermission.exactAlarms ||
    ZenPermission.battery => false,
  };

  bool _toSettings(PermissionsSnapshot s, ZenPermission p) =>
      _asked.contains(p) && s[p] == false && _settingsAfterNo(p);

  Future<void> _ask(ZenPermission p) async {
    final PermissionsSnapshot? s = _snapshot;
    if (_busy != null || s == null) {
      return;
    }
    final bool settings = _toSettings(s, p);
    setState(() => _busy = p);
    try {
      if (settings) {
        await _platform.openSettings(p);
      } else {
        await _platform.request(p);
      }
    } on Object catch (error) {
      logZenWarning('Uprawnienia (${p.name}): $error');
    }
    _asked.add(p);
    if (!mounted) {
      return;
    }
    setState(() => _busy = null);
    await _refresh();
    // A system dialog may answer a moment later.
    _later?.cancel();
    _later = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_refresh());
    });
  }

  /// Bluetooth can be switched on only once it may be used.
  static bool _enabled(PermissionsSnapshot s, ZenPermission p) => switch (p) {
    ZenPermission.bluetoothOn => s[ZenPermission.bluetooth] == true,
    // "All the time" is a second step on top of the first.
    ZenPermission.backgroundLocation => s[ZenPermission.location] == true,
    _ => true,
  };

  Future<void> _setVisible(bool on) async {
    setState(() => _visible = on);
    if (!widget.firstStart) {
      await _applyVisible(on);
    }
  }

  /// Saves the choice and starts (or stops) showing this phone nearby.
  /// (low-power advertising).
  Future<void> _applyVisible(bool on) async {
    try {
      final MeetService meet = ref.read(meetServiceProvider);
      await meet.setNearbyVisible(on);
      final NearbyService nearby = ref.read(nearbyServiceProvider);
      if (!on) {
        await nearby.setVisible(false);
        return;
      }
      final Map<Object?, Object?> state = await nearby.radio.state();
      if (state['permitted'] == true && state['enabled'] == true) {
        await nearby.setVisible(true);
      }
    } on Object catch (error, stack) {
      logZenError('Widoczność w pobliżu', error, stack);
    }
  }

  Future<void> _finish() async {
    if (_finishing) {
      return;
    }
    setState(() => _finishing = true);
    if (_platform.hasBluetooth) {
      await _applyVisible(_visible);
    }
    try {
      // The gate shows the app as soon as this is set.
      await ref
          .read(appSettingsControllerProvider.notifier)
          .setPermissionsSetupDone(true);
    } on Object catch (error, stack) {
      logZenError('Zapis ustawień', error, stack);
      if (mounted) {
        setState(() => _finishing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PermissionsSnapshot? s = _snapshot;
    // An iPhone: what its own Settings must allow for Zen to be woken.
    final bool iphone = ref.watch(iosBackgroundBridgeEnabledProvider);
    final List<Widget> children = <Widget>[
      if (widget.firstStart && widget.welcome) _welcome(zen),
      ZenHero(
        title: t('Uprawnienia i Bluetooth'),
        icon: Icons.verified_user_outlined,
        text: widget.firstStart
            ? t(
                'Kilka zgód, żeby wiadomości, połączenia i alarm docierały '
                'zawsze, a znajomi obok mogli Cię rozpoznać. Każdą włączysz '
                'jednym przyciskiem. Bez nich Zen też działa — tylko '
                'słabiej.',
              )
            : t(
                'Co Zen może na tym urządzeniu. Brak zgody niczego nie '
                'blokuje — mówi tylko, co nie zadziała.',
              ),
      ),
    ];
    if (s == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else if (s.applicable.isEmpty && iphone) {
      children.add(
        const ZenCard(
          key: Key('permissions-row-iphone'),
          child: IosSettingsChecklist(),
        ),
      );
    } else if (s.applicable.isEmpty) {
      children.add(
        ZenEmpty(
          icon: Icons.check_circle_outline_rounded,
          tone: zen.success,
          title: t('Nic do ustawienia'),
          text: t('Na tym urządzeniu Zen nie potrzebuje dodatkowych zgód.'),
        ),
      );
    } else {
      final List<ZenPermission> needed = <ZenPermission>[
        for (final ZenPermission p in s.applicable)
          if (!p.optional) p,
      ];
      final List<ZenPermission> optional = <ZenPermission>[
        for (final ZenPermission p in s.applicable)
          if (p.optional) p,
      ];
      // The next thing to do stands out.
      final ZenPermission? next = needed
          .where((ZenPermission p) => s[p] == false && _enabled(s, p))
          .firstOrNull;
      for (final ZenPermission p in needed) {
        children.add(_step(zen, s, p, highlighted: p == next));
      }
      if (_platform.hasBluetooth) {
        children.add(_visibility(zen, s));
      }
      if (widget.firstStart && optional.isNotEmpty) {
        // The first start stays short: what is asked when first needed
        // waits behind one line; "in the background" only in Settings.
        children.add(
          ExpansionTile(
            key: const Key('permissions-more'),
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            childrenPadding: EdgeInsets.zero,
            title: Text(t('Więcej zgód (opcjonalnie)')),
            subtitle: Text(
              t(
                'Mikrofon, aparat, położenie, dokładne alarmy. Zen zapyta '
                'o nie przy pierwszym użyciu — możesz to pominąć.',
              ),
            ),
            children: <Widget>[
              for (final ZenPermission p in optional)
                if (p != ZenPermission.backgroundLocation) _step(zen, s, p),
            ],
          ),
        );
      } else if (optional.isNotEmpty) {
        children
          ..add(ZenSection(t('Opcjonalnie')))
          ..add(
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Text(
                t(
                  'Możesz zezwolić później — wiele z tego Zen zapyta przy '
                  'pierwszym użyciu albo włączysz tu w Ustawieniach.',
                ),
                style: TextStyle(color: zen.textMuted, fontSize: 13),
              ),
            ),
          );
        for (final ZenPermission p in optional) {
          children.add(_step(zen, s, p));
        }
      }
      if (s.applicable.contains(ZenPermission.battery)) {
        children
          ..add(ZenSection(t('Telefony z własnym oszczędzaniem baterii')))
          ..add(
            VendorBatteryHelp(
              manufacturer: s.manufacturer,
              onOpenSettings: () => unawaited(openAndroidAppSettings()),
            ),
          );
      }
    }
    if (widget.firstStart) {
      final bool ready =
          s != null &&
          s.applicable.every((ZenPermission p) => p.optional || s[p] != false);
      children.addAll(<Widget>[
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('permissions-setup-done'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _finishing ? null : () => unawaited(_finish()),
          child: Text(ready ? t('Gotowe') : t('Dalej')),
        ),
        const SizedBox(height: 10),
        Text(
          t(
            'Wszystko zmienisz później w Ustawieniach → Uprawnienia i '
            'Bluetooth.',
          ),
          textAlign: TextAlign.center,
          style: TextStyle(color: zen.textMuted, fontSize: 12),
        ),
      ]);
    }
    return ListView(
      key: const Key('permissions-body'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: children,
    );
  }

  /// First start only: a minimal welcome above the steps.
  Widget _welcome(ZenColors zen) => ZenCard(
    key: const Key('permissions-welcome'),
    tone: zen.accent,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t('Witaj w Zen'),
          style: TextStyle(
            color: zen.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t(
            'Sieć ludzi, którzy się znają — bez serwerów, reklam i '
            'algorytmu. Wiadomości idą prosto między telefonami '
            'znajomych.',
          ),
          style: TextStyle(color: zen.textSecondary, fontSize: 14, height: 1.4),
        ),
      ],
    ),
  );

  Widget _visibility(ZenColors zen, PermissionsSnapshot s) => ZenCard(
    key: const Key('permissions-row-visible'),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: SwitchListTile(
      key: const Key('permissions-nearby-visible'),
      value: _visible,
      onChanged: (bool v) => unawaited(_setVisible(v)),
      secondary: ZenIconBadge(
        icon: Icons.radar_rounded,
        tone: _visible && s.bluetoothReady ? zen.success : zen.accent,
        size: 40,
      ),
      title: Text(t('Widoczny(-a) w pobliżu')),
      subtitle: Text(
        s.bluetoothReady
            ? t(
                'Telefon cały czas oszczędnie nadaje zmienny znak. Znajomi '
                'obok Cię rozpoznają (spotkani osobiście, alarm), inni '
                'widzą tylko pseudonim.',
              )
            : t('Zacznie działać, gdy Bluetooth będzie włączony i dozwolony.'),
      ),
    ),
  );

  Widget _step(
    ZenColors zen,
    PermissionsSnapshot s,
    ZenPermission p, {
    bool highlighted = false,
  }) {
    final bool? granted = s[p];
    final bool enabled = _enabled(s, p);
    final (IconData icon, String title, String text) = _describe(s, p);
    final Widget trailing;
    if (granted == true) {
      trailing = ZenPill(
        text: t('Gotowe'),
        tone: zen.success,
        icon: Icons.check_rounded,
      );
    } else {
      final String label = granted == null || _toSettings(s, p)
          ? t('Ustawienia')
          : p == ZenPermission.bluetoothOn
          ? t('Włącz')
          : t('Zezwól');
      final VoidCallback? onPressed = !enabled || _busy != null
          ? null
          : () => unawaited(_ask(p));
      final ButtonStyle style = FilledButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      );
      final Key key = Key('permissions-step-${_kebab(p)}');
      trailing = highlighted
          ? FilledButton(
              key: key,
              style: style,
              onPressed: onPressed,
              child: Text(label),
            )
          : FilledButton.tonal(
              key: key,
              style: style,
              onPressed: onPressed,
              child: Text(label),
            );
    }
    return ZenCard(
      key: Key('permissions-row-${_kebab(p)}'),
      tone: highlighted ? zen.accent : null,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 12, 14),
      child: Row(
        children: <Widget>[
          ZenIconBadge(
            icon: icon,
            tone: granted == true ? zen.success : zenTone(zen, p.index),
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  enabled
                      ? text
                      : p == ZenPermission.backgroundLocation
                      ? t('Najpierw zezwól na położenie.')
                      : t('Najpierw zezwól na Bluetooth.'),
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  /// Icon, title and why, for [p].
  (IconData, String, String) _describe(PermissionsSnapshot s, ZenPermission p) {
    // Windows: the system's own settings decide.
    final bool system = !_platform.hasBluetooth;
    return switch (p) {
      ZenPermission.notifications => (
        Icons.notifications_active_outlined,
        t('Powiadomienia'),
        system
            ? t('Sprawdź w ustawieniach Windows, czy Zen może je pokazywać.')
            : t(
                'Wiadomości, połączenia i alarm przyjaciela, także gdy Zen '
                'jest zamknięty.',
              ),
      ),
      ZenPermission.bluetooth => (
        Icons.bluetooth_rounded,
        s.bluetoothNeedsLocation ? t('Bluetooth i lokalizacja') : 'Bluetooth',
        s.bluetoothNeedsLocation
            ? t(
                'Na tym Androidzie Bluetooth wymaga zgody na lokalizację '
                '(i włączonej lokalizacji). Zen nie zapisuje, gdzie '
                'jesteś.',
              )
            : t(
                'Znajomi obok i alarm do pobliża. Zen nie ustala z tego, '
                'gdzie jesteś.',
              ),
      ),
      ZenPermission.bluetoothOn => (
        Icons.bluetooth_connected_rounded,
        t('Włączony Bluetooth'),
        t('Telefon pokazuje się znajomym obok i słyszy ich alarm.'),
      ),
      ZenPermission.location => (
        Icons.my_location_rounded,
        t('Położenie'),
        t(
          'Alarm wysyła znajomym miejsce, w którym jesteś, a sąsiedzi '
          'widzą, kto jest obok. Zen pyta o położenie tylko wtedy, gdy '
          'jest potrzebne. Nie zapisuje trasy, ale przy spotkaniu na liście '
          '„Mijani” może zapamiętać przybliżone miejsce (do około 100 m).',
        ),
      ),
      ZenPermission.backgroundLocation => (
        Icons.share_location_rounded,
        t('Położenie także w tle'),
        t(
          'Żeby alarm z zablokowanego ekranu lub z działającej w tle '
          'usługi niósł miejsce. W oknie systemu wybierz „Zawsze” albo '
          '„Zezwalaj przez cały czas”.',
        ),
      ),
      ZenPermission.exactAlarms => (
        Icons.alarm_on_rounded,
        t('Dokładne alarmy'),
        t(
          'Przypomnienia o spotkaniach i wydarzeniach o właściwej '
          'minucie, bez opóźnień od oszczędzania baterii. Włączysz je na '
          'stronie systemu.',
        ),
      ),
      ZenPermission.fullScreen => (
        Icons.phone_locked_outlined,
        t('Alarm na pełnym ekranie'),
        t(
          'Alarm przyjaciela i połączenia pojawią się też na zablokowanym '
          'ekranie.',
        ),
      ),
      ZenPermission.battery => (
        Icons.battery_charging_full_rounded,
        t('Bez usypiania'),
        t(
          'Android nie usypia Zen, więc alarm i wiadomości dochodzą przy '
          'zgaszonym ekranie.',
        ),
      ),
      ZenPermission.microphone => (
        Icons.mic_none_rounded,
        t('Mikrofon'),
        system
            ? t('Do rozmów. Windows zapyta przy pierwszym użyciu.')
            : t('Rozmowy, wiadomości głosowe i nagranie podczas alarmu.'),
      ),
      ZenPermission.camera => (
        Icons.photo_camera_outlined,
        t('Aparat'),
        system
            ? t('Do rozmów wideo. Windows zapyta przy pierwszym użyciu.')
            : t('Rozmowy wideo, zdjęcia i kody QR.'),
      ),
    };
  }

  static String _kebab(ZenPermission p) => switch (p) {
    ZenPermission.notifications => 'notifications',
    ZenPermission.bluetooth => 'bluetooth',
    ZenPermission.bluetoothOn => 'bluetooth-on',
    ZenPermission.location => 'location',
    ZenPermission.backgroundLocation => 'background-location',
    ZenPermission.exactAlarms => 'exact-alarms',
    ZenPermission.fullScreen => 'full-screen',
    ZenPermission.battery => 'battery',
    ZenPermission.microphone => 'microphone',
    ZenPermission.camera => 'camera',
  };
}
