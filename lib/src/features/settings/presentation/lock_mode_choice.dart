import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// "Automatyczna blokada": when Zen locks itself, bound to the setting, with
/// what "Nigdy" really means and the delay for "Po wyjściu z aplikacji".
/// Asked in Ustawienia → Bezpieczeństwo and in the first-start setup.
class LockModeSettingChoice extends ConsumerWidget {
  const LockModeSettingChoice({super.key});

  /// With an app password, "Nigdy" keeps the data key in the system's
  /// secret store so Zen opens without the password after a restart: the
  /// password unwraps it once more first, after the warning (also in the
  /// first-start setup, right after the password was set: only the
  /// password proves the person, the key in memory does not). Not for an
  /// additional account — a start always opens the default one, so a copy
  /// would never be used. Any other mode drops the copy (the service).
  Future<void> _chooseLockMode(
    BuildContext context,
    WidgetRef ref,
    AppSecurityService security, {
    required AppLockMode current,
    required AppLockMode mode,
  }) async {
    // Read before any wait: the choice may be gone after the dialog.
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    final bool keepsKey =
        mode == AppLockMode.never &&
        security.hasPassword &&
        !security.keepsNeverLockKey &&
        ref.read(zenAccountProvider).isDefault;
    if (keepsKey) {
      final bool kept =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) =>
                _NeverLockDialog(security: security),
          ) ??
          false;
      if (!kept) {
        return;
      }
    } else if (mode == current) {
      return;
    }
    await controller.setLockMode(mode);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    // The note follows the kept key (locking by hand drops it).
    return ListenableBuilder(
      listenable: security,
      builder: (BuildContext context, Widget? child) =>
          _choice(context, ref, security),
    );
  }

  Widget _choice(
    BuildContext context,
    WidgetRef ref,
    AppSecurityService security,
  ) {
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
                onSelected: (_) => unawaited(
                  _chooseLockMode(
                    context,
                    ref,
                    security,
                    current: settings.lockMode,
                    mode: mode,
                  ),
                ),
              ),
          ],
        ),
        if (settings.lockMode == AppLockMode.never) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            security.hasPassword && !security.keepsNeverLockKey
                // Nothing kept (an additional account, or locked by hand
                // since): a start from scratch still asks for the
                // password, only the locking while Zen runs goes.
                ? t(
                    'Zen nie blokuje się sam, także gdy jest w tle: '
                    'kto weźmie odblokowany telefon, zobaczy Twoje '
                    'rozmowy. Gdy system zamknie aplikację albo '
                    'telefon się zrestartuje, hasło i tak będzie '
                    'potrzebne — to ono odszyfrowuje dane.',
                  )
                : <String>[
                    t(
                      'Zen nie blokuje się sam i otwiera się bez '
                      'hasła, także po restarcie telefonu: kto weźmie '
                      'odblokowany telefon, zobaczy Twoje rozmowy. '
                      'Klucz danych czeka w zabezpieczonym magazynie '
                      'systemu, więc chroni go tylko blokada ekranu '
                      'telefonu.',
                    ),
                    if (security.hasPassword)
                      t(
                        '„Zablokuj teraz” w górnym pasku zamyka Zen '
                        'na hasło, także po restarcie, do '
                        'następnego odblokowania.',
                      ),
                  ].join(' '),
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

/// Before "Nigdy" with an app password: says what it gives away, then takes
/// the password, which unwraps the data key for the system's secret store.
/// Pops `true` once the key is kept.
class _NeverLockDialog extends StatefulWidget {
  const _NeverLockDialog({required this.security});

  final AppSecurityService security;

  @override
  State<_NeverLockDialog> createState() => _NeverLockDialogState();
}

class _NeverLockDialogState extends State<_NeverLockDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _controller.text.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final String password = _controller.text;
    final bool kept = await widget.security.keepMasterKeyForNeverLock(password);
    if (!mounted) {
      return;
    }
    if (kept) {
      Navigator.of(context).pop(true);
      return;
    }
    // Told apart only when it failed: the right password and a secret store
    // that refused the key.
    final bool right = await widget.security.verifyPassword(password);
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _error = right
          ? t('Nie udało się zapisać klucza. Spróbuj ponownie.')
          : t('Nieprawidłowe hasło.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return AlertDialog(
      key: const Key('settings-never-lock-dialog'),
      icon: Icon(Icons.lock_open_rounded, color: zen.warning, size: 32),
      title: Text(t('Otwierać Zen bez hasła?')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t(
                'Z „Nigdy” Zen otworzy się bez hasła, także po restarcie '
                'telefonu: kto weźmie odblokowany telefon, zobaczy Twoje '
                'rozmowy. Klucz danych zostanie w zabezpieczonym magazynie '
                'systemu, więc chroni go już tylko blokada ekranu telefonu.',
              ),
              style: TextStyle(color: zen.warning, height: 1.4),
            ),
            if (widget.security.hasPanicPassword) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                t(
                  'Hasło awaryjne kasujące wpiszesz tylko na ekranie blokady '
                  '— po „Zablokuj teraz” w górnym pasku.',
                ),
                key: const Key('settings-never-lock-panic-note'),
                style: TextStyle(color: zen.textSecondary, height: 1.4),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              t('Wpisz hasło aplikacji, żeby to włączyć.'),
              style: TextStyle(color: zen.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('settings-never-lock-password-field'),
              controller: _controller,
              obscureText: _obscure,
              autofocus: true,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: t('Hasło aplikacji'),
                prefixIcon: const Icon(Icons.key_rounded),
                errorText: _error,
                suffixIcon: IconButton(
                  tooltip: _obscure ? t('Pokaż') : t('Ukryj'),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('settings-never-lock-confirm'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? t('Sprawdzam…') : t('Otwieraj bez hasła')),
        ),
      ],
    );
  }
}
