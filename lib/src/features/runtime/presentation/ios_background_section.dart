import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The line about iOS waking Zen in the background at all.
String iosBackgroundRefreshText(IosBackgroundStatus status) {
  if (status.lowPower) {
    return t(
      'Tryb niskiego zużycia energii jest włączony: iOS nie budzi wtedy '
      'Zen w tle.',
    );
  }
  return switch (status.refresh) {
    IosBackgroundRefresh.available => t(
      'Odświeżanie w tle jest włączone: iOS co jakiś czas budzi Zen.',
    ),
    IosBackgroundRefresh.denied => t(
      'Odświeżanie w tle jest wyłączone. Włącz je w Ustawieniach iPhone’a: '
      'Ogólne → Odświeżanie w tle.',
    ),
    IosBackgroundRefresh.restricted => t(
      'Odświeżanie w tle jest zablokowane na tym iPhonie (na przykład przez '
      'Czas przed ekranem).',
    ),
    IosBackgroundRefresh.unknown => t(
      'Nie wiadomo, czy iOS pozwala Zen działać w tle.',
    ),
  };
}

/// The line about the last time iOS woke Zen ([at] formats the time).
String iosLastCheckText(
  IosBackgroundStatus status, {
  String Function(DateTime at) at = ZenFormat.dayMonthTime,
}) {
  if (status.runs <= 0 || status.lastRunAtMillis <= 0) {
    return t('iOS jeszcze nie obudził Zen w tle.');
  }
  final String result = switch (status.lastRunResult) {
    'done' => t('skrzynki sprawdzone'),
    'expired' => t('zabrakło czasu'),
    _ => t('Zen był zablokowany albo zamknięty'),
  };
  final String last =
      t('Ostatnio iOS obudził Zen w tle: {when} ({result}).', <String, Object?>{
        'when': at(DateTime.fromMillisecondsSinceEpoch(status.lastRunAtMillis)),
        'result': result,
      });
  final String count = tn(
    status.runs,
    one: 'Od instalacji: {n} raz.',
    few: 'Od instalacji: {n} razy.',
    many: 'Od instalacji: {n} razy.',
  );
  return '$last $count';
}

/// Whether the app lock ends the background work soon after Zen leaves the
/// screen ("Po wyjściu z aplikacji" with a password).
bool iosLockEndsBackground(AppSecurityService security) =>
    security.hasPassword && security.lockMode == AppLockMode.background;

/// "Praca w tle" on an iPhone: what iOS allows, when it last woke Zen, and
/// the opt-in keep-alive. The settings page puts it in a panel.
class IosBackgroundSection extends ConsumerStatefulWidget {
  const IosBackgroundSection({super.key});

  @override
  ConsumerState<IosBackgroundSection> createState() =>
      _IosBackgroundSectionState();
}

class _IosBackgroundSectionState extends ConsumerState<IosBackgroundSection>
    with WidgetsBindingObserver {
  IosBackgroundStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the iPhone's settings, or from the background.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final IosBackgroundStatus? status = await ref.read(
      iosBackgroundStatusReaderProvider,
    )();
    if (!mounted) {
      return;
    }
    setState(() => _status = status);
  }

  Future<void> _setKeepAlive(bool value) async {
    if (value && !await _confirmKeepAlive()) {
      return;
    }
    await ref
        .read(appSettingsControllerProvider.notifier)
        .setKeepReceivingInBackground(value);
  }

  Future<bool> _confirmKeepAlive() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ZenColors zen = ZenColors.of(dialogContext);
        return AlertDialog(
          scrollable: true,
          key: const Key('ios-keep-alive-confirm'),
          icon: Icon(Icons.battery_alert_rounded, color: zen.warning, size: 30),
          title: Text(t('Odbierać w tle kosztem baterii?')),
          content: Text(
            t(
              'Zen będzie bez przerwy odtwarzać cichy dźwięk, żeby iOS go nie '
              'usypiał. Bateria wyczerpie się wyraźnie szybciej, nawet gdy nic '
              'nie przychodzi. Rozmowa telefoniczna może to przerwać, a iOS i '
              'tak zamknie Zen, gdy zabraknie pamięci albo gdy zamkniesz go w '
              'przełączniku aplikacji. Możesz to wyłączyć w każdej chwili.',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('ios-keep-alive-confirm-ok'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(t('Włącz')),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final IosBackgroundStatus? status = _status;
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
    Widget line(IconData icon, Color color, String text, Key key) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, key: key, style: bodyStyle),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t('Praca w tle na iPhonie'), style: titleStyle),
        const SizedBox(height: 4),
        Text(
          t(
            'iOS usypia Zen kilka sekund po wyjściu z aplikacji, a Zen nie '
            'korzysta z żadnego serwera, który mógłby go budzić. Co jakiś czas '
            'iOS sam budzi Zen na kilkanaście sekund — wtedy Zen pyta '
            'skrzynki u Twoich znajomych o wiadomości i pokazuje '
            'powiadomienia. Kiedy i jak często, decyduje system: zwykle kilka '
            'razy dziennie, częściej, gdy często używasz Zen, nigdy po '
            'zamknięciu Zen w przełączniku aplikacji.',
          ),
          style: bodyStyle,
        ),
        if (status != null) ...<Widget>[
          line(
            status.canRefresh
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            status.canRefresh ? zen.success : zen.warning,
            iosBackgroundRefreshText(status),
            const Key('ios-background-refresh-status'),
          ),
          line(
            Icons.schedule_rounded,
            zen.textMuted,
            iosLastCheckText(status),
            const Key('ios-background-last-check'),
          ),
        ],
        ListenableBuilder(
          listenable: security,
          builder: (BuildContext context, Widget? child) =>
              iosLockEndsBackground(security)
              ? line(
                  Icons.lock_clock_outlined,
                  zen.warning,
                  t(
                    'Zablokowany Zen nie odbiera w tle. Przy blokadzie „Po '
                    'wyjściu z aplikacji” odbieranie w tle kończy się razem z '
                    'blokadą. Żeby odbierać dłużej, wybierz w zabezpieczeniach '
                    '„Przy zamknięciu aplikacji”.',
                  ),
                  const Key('ios-background-lock-note'),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 4),
        SwitchListTile.adaptive(
          key: const Key('settings-ios-keep-alive-switch'),
          contentPadding: EdgeInsets.zero,
          value: settings.keepReceivingInBackground,
          onChanged: (bool value) => unawaited(_setKeepAlive(value)),
          title: Text(t('Odbieraj w tle cały czas'), style: titleStyle),
          subtitle: Text(
            t(
              'Zen odtwarza cichy dźwięk, żeby iOS go nie usypiał: wiadomości '
              'i połączenia przychodzą na bieżąco także poza aplikacją. '
              'Zużywa wyraźnie więcej baterii.',
            ),
            style: bodyStyle,
          ),
        ),
      ],
    );
  }
}
