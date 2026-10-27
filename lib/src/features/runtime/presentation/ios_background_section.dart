import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
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
    _ => t('Zen nie mógł sprawdzić skrzynek'),
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

/// The line about the last run of "Sprawdź wiadomości Zen" from Shortcuts.
String iosShortcutRunText(
  IosBackgroundStatus status, {
  String Function(DateTime at) at = ZenFormat.dayMonthTime,
}) {
  if (status.shortcutRuns <= 0 || status.lastShortcutAtMillis <= 0) {
    return t('Skróty jeszcze nie uruchomiły Zen.');
  }
  final String last = t(
    'Ostatnio Skróty uruchomiły Zen: {when}.',
    <String, Object?>{
      'when': at(
        DateTime.fromMillisecondsSinceEpoch(status.lastShortcutAtMillis),
      ),
    },
  );
  final String count = tn(
    status.shortcutRuns,
    one: 'Od instalacji: {n} raz.',
    few: 'Od instalacji: {n} razy.',
    many: 'Od instalacji: {n} razy.',
  );
  return '$last $count';
}

/// The line about notifications on this iPhone.
String iosNotificationsText(IosNotifications notifications) =>
    switch (notifications) {
      IosNotifications.allowed => t('Powiadomienia są włączone.'),
      IosNotifications.denied => t(
        'Powiadomienia są wyłączone: Zen odbierze w tle, ale nic nie pokaże. '
        'Włącz je w Ustawieniach Zen.',
      ),
      IosNotifications.notDetermined => t(
        'Zen jeszcze nie pytał o powiadomienia; zapyta przy następnym '
        'otwarciu.',
      ),
      IosNotifications.unknown => t(
        'Nie wiadomo, czy Zen może pokazywać powiadomienia.',
      ),
    };

/// What happens in the Shortcuts app, step by step, for the hourly check.
List<String> iosShortcutSteps() => <String>[
  t('Otwórz aplikację Skróty i kartę Automatyzacja.'),
  t('Nowa automatyzacja → Pora dnia: wybierz godzinę i „Codziennie”.'),
  t('Wybierz „Uruchom natychmiast” i wyłącz „Powiadamiaj o uruchomieniu”.'),
  t('Jako czynność wyszukaj „Sprawdź wiadomości Zen” i zatwierdź.'),
  t(
    'Powtórz dla kolejnych godzin (na przykład co godzinę od 7 do 23): '
    'każda godzina to osobna automatyzacja.',
  ),
];

/// Follows the iPhone's background status: read at once and again
/// whenever Zen comes back (from the iPhone's settings, the Shortcuts app
/// or the background).
abstract class _IosStatusState<W extends ConsumerStatefulWidget>
    extends ConsumerState<W>
    with WidgetsBindingObserver {
  IosBackgroundStatus? status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshStatus());
    }
  }

  Future<void> refreshStatus() async {
    final IosBackgroundStatus? next = await ref.read(
      iosBackgroundStatusReaderProvider,
    )();
    if (!mounted) {
      return;
    }
    setState(() => status = next);
  }
}

TextStyle _titleStyle(ZenColors zen) => TextStyle(
  color: zen.textPrimary,
  fontSize: 15.5,
  fontWeight: FontWeight.w700,
);

TextStyle _bodyStyle(ZenColors zen) =>
    TextStyle(color: zen.textSecondary, fontSize: 13.5, height: 1.4);

Widget _line(
  ZenColors zen,
  IconData icon,
  Color color,
  String text, {
  Key? key,
}) => Padding(
  padding: const EdgeInsets.only(top: 8),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text, key: key, style: _bodyStyle(zen)),
      ),
    ],
  ),
);

/// The ways an iPhone wakes Zen, each to choose on its own: iOS's own
/// background refresh (always on unless iOS says no), an hourly Shortcuts
/// automation, and the silent sound that keeps Zen running. Each says how
/// often it wakes Zen and what it costs.
class IosWakeOptions extends ConsumerStatefulWidget {
  const IosWakeOptions({super.key});

  @override
  ConsumerState<IosWakeOptions> createState() => _IosWakeOptionsState();
}

class _IosWakeOptionsState extends _IosStatusState<IosWakeOptions> {
  bool _stepsOpen = false;

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

  Widget _option(
    ZenColors zen, {
    required Key key,
    required IconData icon,
    required String title,
    required String text,
    required bool on,
    List<Widget> children = const <Widget>[],
    Widget? trailing,
  }) {
    return ZenCard(
      key: key,
      tone: on ? zen.success : null,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ZenIconBadge(
                icon: icon,
                tone: on ? zen.success : zen.accent,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: _titleStyle(zen)),
                    const SizedBox(height: 3),
                    Text(text, style: _bodyStyle(zen)),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool keepAlive = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings settings) => settings.keepReceivingInBackground,
      ),
    );
    final IosBackgroundStatus? s = status;
    final ButtonStyle buttonStyle = FilledButton.styleFrom(
      minimumSize: const Size(0, 38),
      padding: const EdgeInsets.symmetric(horizontal: 14),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _option(
          zen,
          key: const Key('ios-wake-refresh'),
          icon: Icons.autorenew_rounded,
          title: t('Automatyczne budzenie przez iOS'),
          text: t(
            'Kilka razy dziennie, kiedy iOS uzna za stosowne (częściej, gdy '
            'często używasz Zen). Prawie nie zużywa baterii. Zawsze włączone, '
            'jeśli iOS na to pozwala.',
          ),
          on: s?.canRefresh ?? false,
          children: <Widget>[
            if (s != null) ...<Widget>[
              _line(
                zen,
                s.canRefresh
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                s.canRefresh ? zen.success : zen.warning,
                iosBackgroundRefreshText(s),
                key: const Key('ios-background-refresh-status'),
              ),
              _line(
                zen,
                Icons.schedule_rounded,
                zen.textMuted,
                iosLastCheckText(s),
                key: const Key('ios-background-last-check'),
              ),
              if (!s.canRefresh)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.tonal(
                      key: const Key('ios-wake-open-settings'),
                      style: buttonStyle,
                      onPressed: () =>
                          unawaited(ref.read(iosOpenZenSettingsProvider)()),
                      child: Text(t('Ustawienia Zen w iOS')),
                    ),
                  ),
                ),
            ],
          ],
        ),
        _option(
          zen,
          key: const Key('ios-wake-shortcut'),
          icon: Icons.alarm_rounded,
          title: t('Automatyzacja w Skrótach co godzinę'),
          text: t(
            'O stałych porach, które ustawisz w aplikacji Skróty — dużo '
            'pewniej niż samo iOS. Każde uruchomienie to około 20 sekund '
            'pracy: niewielkie zużycie baterii. iOS może przy tym pokazać '
            'krótki baner.',
          ),
          on: (s?.shortcutRuns ?? 0) > 0,
          children: <Widget>[
            if (s != null)
              _line(
                zen,
                Icons.history_rounded,
                zen.textMuted,
                iosShortcutRunText(s),
                key: const Key('ios-wake-shortcut-last'),
              ),
            if (_stepsOpen)
              Padding(
                key: const Key('ios-wake-shortcut-steps'),
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final (int i, String step)
                        in iosShortcutSteps().indexed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${i + 1}. $step', style: _bodyStyle(zen)),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (!_stepsOpen)
                    TextButton(
                      key: const Key('ios-wake-shortcut-how'),
                      onPressed: () => setState(() => _stepsOpen = true),
                      child: Text(t('Jak to ustawić?')),
                    ),
                  FilledButton.tonal(
                    key: const Key('ios-wake-open-shortcuts'),
                    style: buttonStyle,
                    onPressed: () =>
                        unawaited(ref.read(iosOpenShortcutsProvider)()),
                    child: Text(t('Otwórz Skróty')),
                  ),
                ],
              ),
            ),
          ],
        ),
        _option(
          zen,
          key: const Key('ios-wake-keep-alive'),
          icon: Icons.graphic_eq_rounded,
          title: t('Cichy dźwięk — odbiór na bieżąco'),
          text: t(
            'Zen odtwarza cichy dźwięk, żeby iOS go nie usypiał: wiadomości i '
            'połączenia przychodzą od razu, także gdy Zen jest zablokowany. '
            'Wyraźnie szybciej wyczerpuje baterię.',
          ),
          on: keepAlive,
          trailing: Switch.adaptive(
            key: const Key('settings-ios-keep-alive-switch'),
            value: keepAlive,
            onChanged: (bool value) => unawaited(_setKeepAlive(value)),
          ),
        ),
      ],
    );
  }
}

/// What has to be set in the iPhone's own Settings for Zen to be woken at
/// all, each with what iOS says now: background refresh, Low Power Mode,
/// notifications, and not swiping Zen away.
class IosSettingsChecklist extends ConsumerStatefulWidget {
  const IosSettingsChecklist({super.key});

  @override
  ConsumerState<IosSettingsChecklist> createState() =>
      _IosSettingsChecklistState();
}

class _IosSettingsChecklistState extends _IosStatusState<IosSettingsChecklist> {
  Widget _row(
    ZenColors zen, {
    required Key key,
    required IconData icon,
    required String title,
    required String text,
    required bool? ok,
  }) {
    final Color tone = switch (ok) {
      true => zen.success,
      false => zen.warning,
      null => zen.textMuted,
    };
    return Padding(
      key: key,
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ZenIconBadge(icon: icon, tone: tone, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: Text(title, style: _titleStyle(zen))),
                    if (ok != null)
                      ZenPill(
                        text: ok ? t('Gotowe') : t('Do zmiany'),
                        tone: tone,
                        icon: ok ? Icons.check_rounded : Icons.priority_high,
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(text, style: _bodyStyle(zen)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final IosBackgroundStatus? s = status;
    return Column(
      key: const Key('ios-settings-checklist'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t('Ustawienia iPhone’a dla Zen'), style: _titleStyle(zen)),
        const SizedBox(height: 4),
        Text(
          t(
            'Żeby iOS budził Zen jak najczęściej. Co da się sprawdzić, Zen '
            'sprawdza sam.',
          ),
          style: _bodyStyle(zen),
        ),
        _row(
          zen,
          key: const Key('ios-check-refresh'),
          icon: Icons.autorenew_rounded,
          title: t('Odświeżanie w tle'),
          text: s == null
              ? t('Sprawdzam…')
              : s.refresh == IosBackgroundRefresh.available
              ? t('Włączone dla Zen.')
              : iosBackgroundRefreshText(
                  IosBackgroundStatus(refresh: s.refresh),
                ),
          ok: s == null || s.refresh == IosBackgroundRefresh.unknown
              ? null
              : s.refresh == IosBackgroundRefresh.available,
        ),
        _row(
          zen,
          key: const Key('ios-check-low-power'),
          icon: Icons.battery_saver_rounded,
          title: t('Tryb niskiego zużycia energii wyłączony'),
          text: s != null && s.lowPower
              ? t(
                  'Jest włączony: iOS nie budzi wtedy żadnej aplikacji w tle. '
                  'Wyłączysz go w Centrum sterowania albo w Ustawieniach → '
                  'Bateria.',
                )
              : t('iOS nie budzi aplikacji w tle, gdy ten tryb jest włączony.'),
          ok: s == null ? null : !s.lowPower,
        ),
        _row(
          zen,
          key: const Key('ios-check-notifications'),
          icon: Icons.notifications_active_outlined,
          title: t('Powiadomienia'),
          text: s == null
              ? t('Sprawdzam…')
              : iosNotificationsText(s.notifications),
          ok: s == null
              ? null
              : switch (s.notifications) {
                  IosNotifications.allowed => true,
                  IosNotifications.denied => false,
                  _ => null,
                },
        ),
        _row(
          zen,
          key: const Key('ios-check-app-switcher'),
          icon: Icons.swipe_up_alt_rounded,
          title: t('Nie zamykaj Zen w przełączniku aplikacji'),
          text: t(
            'Zen zamknięty przesunięciem w górę nie jest budzony, dopóki go '
            'nie otworzysz. Wystarczy wyjść z aplikacji.',
          ),
          ok: null,
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          key: const Key('ios-check-open-settings'),
          onPressed: () => unawaited(ref.read(iosOpenZenSettingsProvider)()),
          child: Text(t('Otwórz ustawienia Zen w iOS')),
        ),
      ],
    );
  }
}

/// "Praca w tle" on an iPhone: the ways to wake Zen, what the iPhone's
/// settings say, and that a locked Zen receives too. The settings page puts
/// it in a panel.
class IosBackgroundSection extends StatelessWidget {
  const IosBackgroundSection({super.key});

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t('Praca w tle na iPhonie'), style: _titleStyle(zen)),
        const SizedBox(height: 4),
        Text(
          t(
            'iOS usypia Zen kilka sekund po wyjściu z aplikacji, a Zen nie '
            'korzysta z żadnego serwera, który mógłby go budzić. Kiedy Zen '
            'się obudzi, pyta skrzynki u Twoich znajomych o wiadomości i '
            'pokazuje powiadomienia. Wybierz, jak ma być budzony — możesz '
            'łączyć sposoby.',
          ),
          style: _bodyStyle(zen),
        ),
        const SizedBox(height: 6),
        const IosWakeOptions(),
        _line(
          zen,
          Icons.lock_outline_rounded,
          zen.textMuted,
          t(
            'Zablokowany Zen też odbiera: wiadomości czekają zaszyfrowane do '
            'odblokowania, a powiadomienie pokazuje najwyżej początek '
            'wiadomości.',
          ),
          key: const Key('ios-background-locked-note'),
        ),
        const SizedBox(height: 16),
        const IosSettingsChecklist(),
      ],
    );
  }
}
