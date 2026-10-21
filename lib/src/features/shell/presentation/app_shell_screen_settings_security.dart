part of 'app_shell_screen.dart';

class _SettingsSecuritySection extends ConsumerWidget {
  const _SettingsSecuritySection();

  Future<void> _setDisguise(
    BuildContext context,
    AppSettingsController controller,
    bool value,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (!await controller.setDisguiseIcon(value)) {
      messenger.showSnackBar(
        SnackBar(content: Text(t('Nie udało się zmienić ikony.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    return AnimatedBuilder(
      animation: security,
      builder: (BuildContext context, Widget? child) {
        return Column(
          key: const Key('settings-security-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenHero(
              title: security.hasPassword
                  ? t('Twoje dane są pod kluczem')
                  : t('Dane są szyfrowane'),
              text: t(
                'Dane na dysku są zawsze szyfrowane. Hasło dodatkowo blokuje '
                'dostęp do aplikacji.',
              ),
              icon: Icons.shield_rounded,
              tone: security.hasPassword ? zen.success : zen.warning,
            ),
            ZenSection(t('Hasła'), top: 16),
            ZenGroup(
              children: <Widget>[
                _SecurityStatusRow(
                  icon: Icons.password_rounded,
                  tone: zen.tone(ZenTone.privacy),
                  title: t('Hasło lokalne'),
                  subtitle: t('Odblokowuje aplikację i Twoje dane'),
                  isSet: security.hasPassword,
                ),
                _SecurityStatusRow(
                  icon: Icons.emergency_outlined,
                  tone: zen.danger,
                  title: t('Hasło panic'),
                  subtitle: t('Wpisane na blokadzie kasuje wszystko'),
                  isSet: security.hasPanicPassword,
                ),
                _BiometricUnlockTile(
                  security: security,
                  hasPassword: security.hasPassword,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const Key('settings-change-password-button'),
                  onPressed: () => _changePassword(context, security),
                  icon: const Icon(Icons.password_rounded, size: 18),
                  label: Text(
                    security.hasPassword ? t('Zmień hasło') : t('Ustaw hasło'),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('settings-panic-password-button'),
                  onPressed: () => _configurePanicPassword(context, security),
                  icon: const Icon(Icons.emergency_outlined, size: 18),
                  label: Text(
                    security.hasPanicPassword
                        ? t('Hasło panic')
                        : t('Ustaw hasło panic'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ZenInfo(
              icon: Icons.emergency_outlined,
              tone: zen.danger,
              title: t('Hasło panic'),
              text: t(
                'Hasło panic wpisane na ekranie blokady bezpowrotnie kasuje '
                'wszystkie dane i otwiera świeżą aplikację.',
              ),
            ),
            ZenSection(t('Automatyczna blokada'), top: 16),
            ZenCard(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
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
                            AppLockMode.systemRestart =>
                              Icons.restart_alt_rounded,
                          }, size: 18),
                          showCheckmark: false,
                          label: Text(mode.label),
                          selected: settings.lockMode == mode,
                          onSelected: (_) =>
                              unawaited(controller.setLockMode(mode)),
                        ),
                    ],
                  ),
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
                            selected:
                                settings.backgroundLockDelaySeconds == sec,
                            onSelected: (_) => unawaited(
                              controller.setBackgroundLockDelaySeconds(sec),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            ZenSection(t('Prywatność ekranu'), top: 16),
            ZenGroup(
              children: <Widget>[
                SwitchListTile.adaptive(
                  key: const Key('settings-secure-screens-switch'),
                  secondary: ZenIconBadge(
                    icon: Icons.screenshot_monitor_outlined,
                    tone: zen.tone(ZenTone.media),
                    size: 40,
                  ),
                  value: settings.secureScreens,
                  title: Text(t('Blokuj zrzuty i nagrywanie ekranu')),
                  subtitle: Text(
                    t(
                      'Rozmowy, nagrania, konto i urządzenia nie trafią na '
                      'zrzut, nagranie ekranu ani podgląd ostatnich aplikacji.',
                    ),
                    style: TextStyle(color: zen.textSecondary, height: 1.35),
                  ),
                  onChanged: controller.setSecureScreens,
                ),
                if (!security.hasPassword)
                  SwitchListTile.adaptive(
                    key: const Key('settings-allow-no-password-switch'),
                    secondary: ZenIconBadge(
                      icon: Icons.no_encryption_outlined,
                      tone: zen.danger,
                      size: 40,
                    ),
                    value: settings.allowNoAppPassword,
                    title: Text(t('Pozwól używać aplikacji bez hasła')),
                    subtitle: Text(
                      t(
                        'Niezalecane: bez hasła każdy, kto weźmie urządzenie, '
                        'zobaczy Twoje rozmowy.',
                      ),
                      style: TextStyle(color: zen.danger, height: 1.35),
                    ),
                    onChanged: controller.setAllowNoAppPassword,
                  ),
              ],
            ),
            if (!kIsWeb && Platform.isAndroid && !isStoreBuild) ...<Widget>[
              ZenSection(t('Kamuflaż'), top: 16),
              ZenGroup(
                children: <Widget>[
                  SwitchListTile.adaptive(
                    key: const Key('settings-disguise-icon-switch'),
                    secondary: ZenIconBadge(
                      icon: Icons.sticky_note_2_outlined,
                      tone: zen.tone(ZenTone.appearance),
                      size: 40,
                    ),
                    value: settings.disguiseIcon,
                    title: Text(t('Kamuflaż ikony')),
                    subtitle: Text(
                      t(
                        'Na liście aplikacji telefon pokaże neutralną ikonę '
                        '„Notatki” zamiast Zen. To tylko inny wygląd: '
                        'aplikacja nadal ma te same uprawnienia, a w '
                        'ustawieniach systemu zobaczysz jej prawdziwą nazwę. '
                        'Niektóre ekrany startowe odświeżą ikonę dopiero po '
                        'chwili.',
                      ),
                      style: TextStyle(color: zen.textSecondary, height: 1.35),
                    ),
                    onChanged: (bool value) =>
                        unawaited(_setDisguise(context, controller, value)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            ZenInfo(
              icon: Icons.memory_rounded,
              title: t('Jak chronimy klucz'),
              text: t(
                'Klucz danych jest tylko w pamięci, gdy aplikacja jest '
                'odblokowana. Do odblokowania biometrią jest zamknięty w '
                'sprzęcie urządzenia, a hasło chroni go algorytmem Argon2id.',
              ),
            ),
            const _DeviceIntegrityWarning(),
          ],
        );
      },
    );
  }

  Future<void> _changePassword(
    BuildContext context,
    AppSecurityService security,
  ) async {
    final bool replacing = security.hasPassword;
    // Whoever holds the unlocked phone must not be able to change it.
    if (replacing &&
        !await _confirmPasswordOwner(
          context,
          security,
          reason: t('Potwierdź obecne hasło, zanim je zmienisz.'),
        )) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    final String? password = await _showPasswordDialog(
      context,
      title: replacing
          ? t('Zmień hasło szyfrowania')
          : t('Ustaw hasło szyfrowania'),
      actionLabel: replacing ? t('Zapisz hasło') : t('Ustaw hasło'),
    );
    if (password == null || !context.mounted) {
      return;
    }
    await _runPasswordChange(context, () => security.setPassword(password));
  }

  Future<void> _configurePanicPassword(
    BuildContext context,
    AppSecurityService security,
  ) async {
    final bool? replace = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ZenColors zen = ZenColors.of(dialogContext);
        return AlertDialog(
          key: const Key('settings-panic-intro-dialog'),
          icon: Icon(Icons.emergency_outlined, color: zen.danger, size: 32),
          title: Text(t('Hasło panic')),
          content: Text(
            t(
              'To drugie, tajne hasło. Wpisane na ekranie blokady natychmiast '
              'i bezpowrotnie kasuje wszystkie dane aplikacji, a potem '
              'otwiera ją jak po świeżej instalacji — bez żadnego komunikatu.',
            ),
          ),
          actionsOverflowButtonSpacing: 4,
          actions: <Widget>[
            if (security.hasPanicPassword)
              TextButton(
                key: const Key('settings-panic-clear-button'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(
                  t('Usuń hasło panic'),
                  style: TextStyle(color: zen.danger),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('settings-panic-continue-button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(security.hasPanicPassword ? t('Zmień') : t('Ustaw')),
            ),
          ],
        );
      },
    );
    if (replace == null || !context.mounted) {
      return;
    }
    // Setting, changing or removing the panic password asks who is there
    // first, every time.
    if (!await _confirmPasswordOwner(
      context,
      security,
      reason: replace
          ? t('Potwierdź hasło aplikacji, zanim ustawisz hasło panic.')
          : t('Potwierdź hasło aplikacji, zanim usuniesz hasło panic.'),
    )) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    if (!replace) {
      await security.clearPanicPassword();
      return;
    }
    final String? password = await _showPasswordDialog(
      context,
      title: t('Ustaw hasło panic'),
      actionLabel: t('Zapisz hasło panic'),
      fieldKey: const Key('settings-panic-password-field'),
      confirmKey: const Key('settings-panic-password-confirm-field'),
      submitKey: const Key('settings-panic-password-submit-button'),
    );
    if (password == null || !context.mounted) {
      return;
    }
    // The service refuses the main password (it would never unlock again:
    // the lock screen would wipe everything instead).
    await _runPasswordChange(
      context,
      () => security.setPanicPassword(password),
    );
  }
}

/// Runs a password change and says why it was refused (the main and the
/// panic password must differ).
Future<void> _runPasswordChange(
  BuildContext context,
  Future<void> Function() change,
) async {
  String? problem;
  try {
    await change();
  } on AppPasswordConflictException catch (error) {
    problem = error.message;
  } on Object catch (error, stackTrace) {
    logZenError('Changing a password failed', error, stackTrace);
    problem = t('Nie udało się zapisać hasła. Spróbuj ponownie.');
  }
  if (problem == null || !context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
}

/// Before a password is changed or removed: is this the owner? Biometrics
/// when the key is sealed in hardware, otherwise the current app password
/// — every time, with no grace period. Without an app password there is
/// nothing to ask for.
Future<bool> _confirmPasswordOwner(
  BuildContext context,
  AppSecurityService security, {
  required String reason,
}) async {
  if (!security.hasPassword) {
    return true;
  }
  if (await security.canUnlockWithBiometrics() &&
      await security.confirmWithBiometrics(reason: reason)) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  return await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) =>
            _CurrentPasswordDialog(security: security, reason: reason),
      ) ??
      false;
}

/// Asks for the current app password (checked without touching the lock).
class _CurrentPasswordDialog extends StatefulWidget {
  const _CurrentPasswordDialog({required this.security, required this.reason});

  final AppSecurityService security;
  final String reason;

  @override
  State<_CurrentPasswordDialog> createState() => _CurrentPasswordDialogState();
}

class _CurrentPasswordDialogState extends State<_CurrentPasswordDialog> {
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
    final bool ok = await widget.security.verifyPassword(_controller.text);
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = t('Nieprawidłowe hasło.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return AlertDialog(
      key: const Key('settings-current-password-dialog'),
      icon: Icon(Icons.verified_user_outlined, color: zen.accent, size: 32),
      title: Text(t('Potwierdź, że to Ty')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.reason,
              style: TextStyle(color: zen.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('settings-current-password-field'),
              controller: _controller,
              obscureText: _obscure,
              autofocus: true,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: t('Obecne hasło aplikacji'),
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
          key: const Key('settings-current-password-confirm'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? t('Sprawdzam…') : t('Potwierdź')),
        ),
      ],
    );
  }
}

/// Biometric unlock (fingerprint / face, Windows Hello): on or off. Turning
/// it on asks for the app password first; on Windows it is off until the
/// person turns it on, because there only the app — not the TPM — asks
/// Windows Hello before releasing the key.
class _BiometricUnlockTile extends StatefulWidget {
  const _BiometricUnlockTile({
    required this.security,
    required this.hasPassword,
  });

  final AppSecurityService security;

  /// Rebuilt with the security state: a new password changes what can be
  /// offered.
  final bool hasPassword;

  @override
  State<_BiometricUnlockTile> createState() => _BiometricUnlockTileState();
}

class _BiometricUnlockTileState extends State<_BiometricUnlockTile> {
  BiometricUnlockStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _BiometricUnlockTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hasPassword != widget.hasPassword ||
        !identical(oldWidget.security, widget.security)) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final BiometricUnlockStatus status = await widget.security
          .biometricUnlockStatus();
      if (mounted) {
        setState(() => _status = status);
      }
    } on Object catch (error, stackTrace) {
      logZenError(
        'Reading the biometric unlock state failed',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _toggle(bool on) async {
    final AppSecurityService security = widget.security;
    setState(() => _busy = true);
    String? problem;
    try {
      if (on) {
        if (await _confirmPasswordOwner(
          context,
          security,
          reason: t(
            'Potwierdź hasło aplikacji, aby włączyć odblokowanie '
            'biometrią.',
          ),
        )) {
          if (!await security.setBiometricUnlockEnabled(true)) {
            problem = t(
              'Nie udało się włączyć odblokowania biometrią na tym '
              'urządzeniu.',
            );
          }
        }
      } else {
        await security.setBiometricUnlockEnabled(false);
      }
    } on Object catch (error, stackTrace) {
      logZenError('Changing biometric unlock failed', error, stackTrace);
      problem = t('Nie udało się zmienić odblokowania biometrią.');
    }
    await _load();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final BiometricUnlockStatus? status = _status;
    final bool available = status?.available ?? false;
    final bool on = available && (status?.enabled ?? false);
    final String protection = status?.protection ?? '…';
    final String subtitle;
    if (status == null) {
      subtitle = '…';
    } else if (!widget.hasPassword) {
      subtitle = t('Najpierw ustaw hasło aplikacji.');
    } else if (!available) {
      subtitle = t('Niedostępne na tym urządzeniu — tylko hasło.');
    } else if (!status.hardwareEnforced) {
      subtitle = t(
        'Klucz: {protection}. Windows Hello to zwykle PIN tego komputera '
        'i pyta o niego aplikacja, nie sam TPM: gdy to jest włączone, '
        'program uruchomiony na Twoim koncie Windows mógłby odczytać '
        'klucz. Włączaj tylko na zaufanym komputerze.',
        {'protection': protection},
      );
    } else {
      subtitle = t(
        'Klucz: {protection}. Sprzęt wydaje go dopiero po '
        'odcisku palca lub twarzy. {risk}',
        {'protection': protection, 'risk': kBiometricRiskText},
      );
    }
    return SwitchListTile.adaptive(
      key: const Key('settings-biometric-unlock-switch'),
      secondary: ZenIconBadge(
        icon: Icons.fingerprint_rounded,
        tone: zen.tone(ZenTone.privacy),
        size: 40,
      ),
      value: on,
      title: Text(
        defaultTargetPlatform == TargetPlatform.windows
            ? t('Odblokowanie Windows Hello')
            : t('Odblokowanie biometrią'),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: available && status?.hardwareEnforced == false
              ? zen.warning
              : zen.textSecondary,
          height: 1.35,
        ),
      ),
      onChanged: !available || _busy
          ? null
          : (bool value) => unawaited(_toggle(value)),
    );
  }
}

/// A password's state in the security list: set or missing.
class _SecurityStatusRow extends StatelessWidget {
  const _SecurityStatusRow({
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.isSet,
  });

  final IconData icon;
  final Color tone;
  final String title;
  final String subtitle;
  final bool isSet;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ListTile(
      leading: ZenIconBadge(icon: icon, tone: tone, size: 40),
      title: Text(title),
      subtitle: Text(subtitle, style: TextStyle(color: zen.textSecondary)),
      trailing: ZenPill(
        text: isSet ? t('Ustawione') : t('Brak'),
        tone: isSet ? zen.success : zen.textMuted,
        icon: isSet ? Icons.check_rounded : null,
      ),
    );
  }
}

class _DeviceIntegrityWarning extends ConsumerWidget {
  const _DeviceIntegrityWarning();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DeviceIntegrity integrity =
        ref.watch(deviceIntegrityProvider).value ?? DeviceIntegrity.clean;
    if (!integrity.hasWarning) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Container(
      key: const Key('settings-integrity-warning'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: zen.danger.withValues(alpha: 0.09),
        borderRadius: context.zenRadius(18),
        border: Border.all(color: zen.danger.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenIconBadge(
                icon: Icons.warning_amber_rounded,
                tone: zen.danger,
                size: 36,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t('To urządzenie wygląda na zmodyfikowane'),
                  style: TextStyle(
                    color: zen.danger,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            t(
              'Na telefonie z rootem inne aplikacje mogą odczytać pamięć i '
              'pliki Zen, więc szyfrowanie chroni słabiej. Zen działa dalej — '
              'to Twój telefon — ale weź to pod uwagę.',
            ),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          if (integrity.tampered)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                t(
                  'Dopóki tak jest, Zen nie wyśle przelewu ani nie użyje '
                  'klucza władzy piramidy: zmieniona pamięć aplikacji '
                  'mogłaby podpisać coś, czego nie chcesz.',
                ),
                style: TextStyle(color: zen.danger, fontSize: 13, height: 1.4),
              ),
            ),
          for (final String line in integrity.describe())
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '• $line',
                style: TextStyle(color: zen.textMuted, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}

Future<String?> _showPasswordDialog(
  BuildContext context, {
  required String title,
  required String actionLabel,
  Key fieldKey = const Key('settings-password-field'),
  Key confirmKey = const Key('settings-password-confirm-field'),
  Key submitKey = const Key('settings-password-submit-button'),
}) async {
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmController = TextEditingController();
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  bool obscurePassword = true;
  bool obscureConfirm = true;
  try {
    return await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ZenColors zen = ZenColors.of(dialogContext);
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              icon: Icon(
                Icons.lock_outline_rounded,
                color: zen.accent,
                size: 32,
              ),
              title: Text(title),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TextFormField(
                        key: fieldKey,
                        controller: passwordController,
                        obscureText: obscurePassword,
                        autofocus: true,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: t('Hasło'),
                          helperText: tn(
                            kMinAppPasswordLength,
                            one: 'Co najmniej {n} znak',
                            few: 'Co najmniej {n} znaki',
                            many: 'Co najmniej {n} znaków',
                          ),
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                            tooltip: obscurePassword ? t('Pokaż') : t('Ukryj'),
                            onPressed: () {
                              setDialogState(
                                () => obscurePassword = !obscurePassword,
                              );
                            },
                            icon: Icon(
                              obscurePassword
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                          ),
                        ),
                        validator: (String? value) {
                          if (value == null || value.isEmpty) {
                            return t('Podaj hasło.');
                          }
                          if (value.length < kMinAppPasswordLength) {
                            return tn(
                              kMinAppPasswordLength,
                              one: 'Hasło musi mieć co najmniej {n} znak.',
                              few: 'Hasło musi mieć co najmniej {n} znaki.',
                              many: 'Hasło musi mieć co najmniej {n} znaków.',
                            );
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: confirmKey,
                        controller: confirmController,
                        obscureText: obscureConfirm,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: t('Potwierdź hasło'),
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                            tooltip: obscureConfirm ? t('Pokaż') : t('Ukryj'),
                            onPressed: () {
                              setDialogState(
                                () => obscureConfirm = !obscureConfirm,
                              );
                            },
                            icon: Icon(
                              obscureConfirm
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                          ),
                        ),
                        validator: (String? value) {
                          if (value != passwordController.text) {
                            return t('Hasła nie są takie same.');
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(t('Anuluj')),
                ),
                FilledButton(
                  key: submitKey,
                  onPressed: () {
                    if (!formKey.currentState!.validate()) {
                      return;
                    }
                    Navigator.of(dialogContext).pop(passwordController.text);
                  },
                  child: Text(actionLabel),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    // The dialog is still animating out: dispose the fields once it is gone.
    disposeLater(<TextEditingController>[
      passwordController,
      confirmController,
    ]);
  }
}
