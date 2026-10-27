import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// "Automatyczna blokada": when Zen locks itself, bound to the setting, with
/// what "Nigdy" really means and the delay for "Po wyjściu z aplikacji".
/// Asked in Ustawienia → Bezpieczeństwo and in the first-start setup.
class LockModeSettingChoice extends ConsumerWidget {
  const LockModeSettingChoice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          key: const Key('settings-lock-mode-dropdown'),
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final AppLockMode mode in AppLockMode.values)
              ChoiceChip(
                key: Key('settings-lock-mode-${mode.name}'),
                avatar: Icon(switch (mode) {
                  AppLockMode.never => Icons.lock_open_rounded,
                  AppLockMode.background => Icons.timer_outlined,
                  AppLockMode.appClose => Icons.close_rounded,
                  AppLockMode.systemRestart => Icons.restart_alt_rounded,
                }, size: 18),
                showCheckmark: false,
                label: Text(mode.label),
                selected: settings.lockMode == mode,
                onSelected: (_) => unawaited(controller.setLockMode(mode)),
              ),
          ],
        ),
        if (settings.lockMode == AppLockMode.never) ...<Widget>[
          const SizedBox(height: 12),
          // The password is what opens the data key, so a start from
          // scratch (the system closed the app, the phone restarted)
          // still asks for it: only the locking while Zen runs goes.
          Text(
            t(
              'Zen nie blokuje się sam, także gdy jest w tle: kto '
              'weźmie odblokowany telefon, zobaczy Twoje rozmowy. '
              'Gdy system zamknie aplikację albo telefon się '
              'zrestartuje, hasło i tak będzie potrzebne — to ono '
              'odszyfrowuje dane.',
            ),
            key: const Key('settings-lock-never-note'),
            softWrap: true,
            style: TextStyle(color: zen.warning, fontSize: 13, height: 1.35),
          ),
        ],
        if (settings.lockMode == AppLockMode.background) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            t('Zablokuj, gdy aplikacja jest w tle dłużej niż'),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            key: const Key('settings-lock-delay-choices'),
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final (int sec, String label) in <(int, String)>[
                (5, t('{seconds} s', {'seconds': 5})),
                (30, t('{seconds} s', {'seconds': 30})),
                (60, t('{minutes} min', {'minutes': 1})),
                (300, t('{minutes} min', {'minutes': 5})),
                (900, t('{minutes} min', {'minutes': 15})),
                (3600, t('{hours} h', {'hours': 1})),
              ])
                ChoiceChip(
                  key: Key('settings-lock-delay-$sec'),
                  label: Text(label),
                  selected: settings.backgroundLockDelaySeconds == sec,
                  onSelected: (_) =>
                      unawaited(controller.setBackgroundLockDelaySeconds(sec)),
                ),
            ],
          ),
        ],
        // Without a lock for a while in the background the phone
        // only receives anyway (android_background_runtime.dart).
        if (defaultTargetPlatform == TargetPlatform.android &&
            (settings.lockMode != AppLockMode.background ||
                settings.backgroundLockDelaySeconds > 300)) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            t(
              'Po 5 minutach w tle Zen tylko odbiera — tak '
              'oszczędza baterię, także bez blokady.',
            ),
            key: const Key('settings-lock-battery-note'),
            softWrap: true,
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}
