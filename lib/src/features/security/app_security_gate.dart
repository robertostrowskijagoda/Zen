import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_data_reset.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/about/presentation/legal_consent_stage.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/account/presentation/account_import_layer.dart';
import 'package:zen/src/features/account/presentation/account_secure_stage.dart';
import 'package:zen/src/features/account/presentation/accounts_ui.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/permissions/presentation/permissions_screen.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/hold_to_confirm_button.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/presentation/first_run_setup.dart';

/// The wipe behind "Nie pamiętam hasła — zacznij od nowa" and the panic
/// password: the whole device, every account on it (the lock screen is
/// the default account's; the others are not named anywhere on it). A
/// provider so tests can stand in for it.
final Provider<Future<void> Function(WidgetRef ref)> zenLocalDataResetProvider =
    Provider<Future<void> Function(WidgetRef ref)>(
      (Ref ref) => performZenDeviceWipe,
    );

class AppSecurityGate extends ConsumerStatefulWidget {
  const AppSecurityGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppSecurityGate> createState() => _AppSecurityGateState();
}

class _AppSecurityGateState extends ConsumerState<AppSecurityGate>
    with WidgetsBindingObserver {
  DateTime? _pausedAt;

  /// "Po wyjściu z aplikacji": locks the set delay after the app left the
  /// screen, while it is still in the background — the master key and the
  /// drawn screens do not wait in memory for the person to come back.
  /// Where the system suspends the app (iOS) the timer cannot run;
  /// the check on resume covers that.
  Timer? _backgroundLockTimer;

  /// On a computer: locks after the same delay without a key press or the
  /// mouse moving over Zen (the window may stay open on a desk).
  Timer? _idleLockTimer;

  AppSecurityService? _security;

  /// Set while the lock screen erases this device. Erasing makes the app
  /// unlocked half way through; the lock screen stays (and keeps its `ref`
  /// alive for the rest of the wipe) until this is false again.
  final ValueNotifier<bool> _wiping = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _follow(ref.read(appSecurityServiceProvider));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _security?.removeListener(_onSecurityChanged);
    _backgroundLockTimer?.cancel();
    _idleLockTimer?.cancel();
    _wiping.dispose();
    super.dispose();
  }

  void _follow(AppSecurityService security) {
    if (identical(security, _security)) {
      return;
    }
    _security?.removeListener(_onSecurityChanged);
    _security = security;
    security.addListener(_onSecurityChanged);
    _onSecurityChanged();
  }

  /// Whether locking by time means anything now: the "after leaving the
  /// app" mode, a password, and the app open.
  static bool _locksByTime(AppSecurityService security) =>
      security.lockMode == AppLockMode.background &&
      security.hasPassword &&
      !security.isLocked;

  static Duration _delay(AppSecurityService security) =>
      Duration(seconds: security.backgroundLockDelaySeconds);

  static bool get _idleLockPlatform => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  /// Locked, unlocked, a password set or the settings changed.
  void _onSecurityChanged() {
    final AppSecurityService? security = _security;
    if (security == null || !_locksByTime(security)) {
      _backgroundLockTimer?.cancel();
      _backgroundLockTimer = null;
      _idleLockTimer?.cancel();
      _idleLockTimer = null;
      return;
    }
    _restartIdleLock();
  }

  void _restartIdleLock() {
    _idleLockTimer?.cancel();
    _idleLockTimer = null;
    final AppSecurityService? security = _security;
    if (!_idleLockPlatform || security == null || !_locksByTime(security)) {
      return;
    }
    _idleLockTimer = Timer(_delay(security), () {
      _idleLockTimer = null;
      if (ref.read(callSurfaceActiveProvider)) {
        // A call on screen is being watched, not left: the lock would
        // cover it. The count starts again.
        _restartIdleLock();
        return;
      }
      final AppSecurityService? current = _security;
      if (current != null && _locksByTime(current)) {
        current.lock();
      }
    });
  }

  /// Any key press or pointer over Zen counts as the person being there.
  void _noteInput() {
    if (_idleLockTimer != null) {
      _restartIdleLock();
    }
  }

  bool _onKey(KeyEvent event) {
    _noteInput();
    // Only watching: the key goes on to whoever handles it.
    return false;
  }

  void _onPointer(PointerEvent event) => _noteInput();

  void _startBackgroundLock(AppSecurityService security) {
    if (_backgroundLockTimer != null || !_locksByTime(security)) {
      return;
    }
    _backgroundLockTimer = Timer(_delay(security), () {
      _backgroundLockTimer = null;
      final AppSecurityService? current = _security;
      if (current != null && _locksByTime(current)) {
        current.lock();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // From the first of the two (hidden comes before paused).
        final bool leaving = _pausedAt == null;
        _pausedAt ??= DateTime.now();
        _startBackgroundLock(security);
        if (leaving) {
          // "Nie blokuj od razu po zamknięciu aplikacji": should the system
          // close Zen now, a start before the delay is over still opens.
          unawaited(security.keepResumeSession());
        }
        break;
      case AppLifecycleState.detached:
        if (security.lockMode == AppLockMode.appClose) {
          security.lock();
        } else if (_pausedAt == null) {
          // Closed straight from the screen (a computer's window).
          unawaited(security.keepResumeSession());
        }
        break;
      case AppLifecycleState.resumed:
        _backgroundLockTimer?.cancel();
        _backgroundLockTimer = null;
        if (security.lockMode == AppLockMode.background &&
            _pausedAt != null &&
            DateTime.now().difference(_pausedAt!) >
                Duration(seconds: security.backgroundLockDelaySeconds)) {
          security.lock();
        } else {
          // Back in time, the key in memory: nothing waits outside it.
          unawaited(security.dropResumeSession());
        }
        _pausedAt = null;
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings appSettings = ref.watch(appSettingsControllerProvider);
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    _follow(security);
    // After the app password, the setup (once per [kSetupRevision]): the
    // lock, notifications, gates, animations.
    final bool setupStep =
        ref.watch(firstRunSetupRequiredProvider) && appSettings.setupPending;
    // Then, once, the permissions and Bluetooth step (skipped where there
    // is nothing to ask): the setup's last step.
    final bool permissionsStep =
        ref.watch(permissionsSetupRequiredProvider) &&
        !appSettings.permissionsSetupDone &&
        ref.watch(permissionsPlatformProvider).hasAnything;
    // Then, once, the "Zabezpiecz konto" card.
    final bool accountStep =
        ref.watch(accountSecureStepRequiredProvider) &&
        ref.watch(ledgerNodeEnabledProvider) &&
        !appSettings.accountSecureOffered;
    // The whole app, lock screen included: Android keeps its window out of
    // screenshots and the recent apps while the setting is on, and
    // every touch, click or mouse move restarts the idle lock.
    return SecureAppWindow(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointer,
        onPointerMove: _onPointer,
        onPointerHover: _onPointer,
        onPointerSignal: _onPointer,
        child: _gated(security, setupStep, permissionsStep, accountStep),
      ),
    );
  }

  Widget _gated(
    AppSecurityService security,
    bool setupStep,
    bool permissionsStep,
    bool accountStep,
  ) {
    final ValueNotifier<AccountStartPlan> plan = ref.watch(
      accountStartPlanProvider,
    );
    final ValueNotifier<AccountStartAction?> startAction = ref.watch(
      accountStartActionProvider,
    );
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        security,
        _wiping,
        plan,
        startAction,
      ]),
      builder: (BuildContext context, Widget? child) {
        if (!security.isReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (_wiping.value) {
          return _unlockOverlay();
        }
        if (ref.watch(legalConsentPendingProvider) &&
            !(security.encryptionEnabled &&
                security.hasPassword &&
                security.isLocked)) {
          // Before anything is made (the app password, the account): the
          // terms, the privacy policy and the licence notice; asked again
          // when their version changes (after unlocking, if locked).
          return Navigator(
            key: const ValueKey<String>('gate-legal-consent'),
            onGenerateRoute: (RouteSettings route) => MaterialPageRoute<void>(
              settings: route,
              builder: (BuildContext context) => const LegalConsentStage(),
            ),
          );
        }
        // An additional account always has its own password.
        final bool additional = !ref.read(zenAccountProvider).isDefault;
        // "Mam już konto" on the password step: straight to the ways back.
        // The setup and the permissions wait for the account (the restore
        // restarts the app; they come once, then).
        final bool restoring = plan.value == AccountStartPlan.restore;
        // No password yet either: a backup of the whole app brings its own,
        // and another device's copy restarts the app, which asks for one
        // then. The recovery circle waits for friends for a day or more
        // without restarting: the password comes first for it.
        final bool passwordLater =
            restoring && startAction.value != AccountStartAction.circle;
        if (!passwordLater &&
            !security.hasPassword &&
            ((ref.watch(appPasswordRequiredProvider) &&
                    !ref
                        .watch(appSettingsControllerProvider)
                        .allowNoAppPassword) ||
                additional)) {
          // An app password is required by default. Its own Navigator
          // (the gate sits above the root one) so the setup questions can
          // open dialogs; it brings its own Overlay for the text fields.
          // Keyed: the next step's Navigator must not take over this one's
          // state (it would keep showing this screen).
          return Navigator(
            key: const ValueKey<String>('gate-password-setup'),
            onGenerateRoute: (RouteSettings settings) =>
                MaterialPageRoute<void>(
                  settings: settings,
                  builder: (BuildContext context) =>
                      const _PasswordSetupScreen(),
                ),
          );
        }
        if (!security.encryptionEnabled ||
            !security.hasPassword ||
            !security.isLocked) {
          if (setupStep && !restoring) {
            // Its own Navigator, like the password step above.
            return Navigator(
              key: const ValueKey<String>('gate-first-run-setup'),
              onGenerateRoute: (RouteSettings route) => MaterialPageRoute<void>(
                settings: route,
                builder: (BuildContext context) => const FirstRunSetupStage(),
              ),
            );
          }
          if (permissionsStep && !restoring) {
            // The setup said hello already.
            final bool welcome = !ref.read(firstRunSetupRequiredProvider);
            return Navigator(
              key: const ValueKey<String>('gate-permissions'),
              onGenerateRoute: (RouteSettings route) => MaterialPageRoute<void>(
                settings: route,
                builder: (BuildContext context) =>
                    PermissionsSetupStage(welcome: welcome),
              ),
            );
          }
          if (accountStep) {
            return Navigator(
              key: const ValueKey<String>('gate-account-secure'),
              onGenerateRoute: (RouteSettings route) => MaterialPageRoute<void>(
                settings: route,
                builder: (BuildContext context) => const AccountSecureStage(),
              ),
            );
          }
          // A way back was picked on the first start: its screen opens in
          // the app (AccountImportLayer); until it is drawn, the first
          // start's surface stays over the app instead of the app flashing
          // up. Always the same Stack, so the app below keeps its state.
          return Stack(
            fit: StackFit.passthrough,
            children: <Widget>[
              child!,
              if (startAction.value != null)
                const Positioned.fill(
                  child: Scaffold(
                    key: Key('gate-start-cover'),
                    body: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          );
        }
        if (!ref.read(zenAccountProvider).isDefault) {
          // An additional account never shows a lock screen of its own
          // (it would show that the account exists): locked, it goes back
          // to the default account's.
          _returnToDefault();
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return _unlockOverlay();
      },
      child: widget.child,
    );
  }

  bool _returning = false;

  void _returnToDefault() {
    if (_returning || ref.read(zenAccountHostProvider).switching) {
      return;
    }
    _returning = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(returnToDefaultZenAccount(ref));
      }
    });
  }

  /// The gate sits above the root Navigator (MaterialApp.builder), so the
  /// lock screen must provide its own Overlay for text fields.
  Widget _unlockOverlay() {
    return Overlay(
      initialEntries: <OverlayEntry>[
        OverlayEntry(
          builder: (BuildContext context) => _UnlockScreen(wiping: _wiping),
        ),
      ],
    );
  }
}

class _UnlockScreen extends ConsumerStatefulWidget {
  const _UnlockScreen({required this.wiping});

  /// Raised by the gate's owner while this screen erases the device.
  final ValueNotifier<bool> wiping;

  @override
  ConsumerState<_UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<_UnlockScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _passwordController = TextEditingController();
  bool _isSubmitting = false;
  bool _obscureText = true;
  bool _canUseBiometrics = false;
  String? _errorText;

  /// "Nie pamiętam hasła": the page that erases the device is open.
  bool _forgot = false;

  /// "Inne konto": the panel that opens another account is open.
  bool _other = false;
  bool _wipeFailed = false;

  /// How long the password must not be tried, counted down by [_tick].
  Duration _wait = Duration.zero;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBiometricAvailability());
    unawaited(_loadWait());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _passwordController.dispose();
    super.dispose();
  }

  /// The wait left from earlier failures (it survives a restart).
  Future<void> _loadWait() async {
    final Duration left = await ref.read(unlockThrottleProvider).remaining();
    if (mounted && left > Duration.zero) {
      _startWait(left);
    }
  }

  void _startWait(Duration left) {
    _tick?.cancel();
    setState(() {
      _wait = left;
      _errorText = null;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      final Duration next = _wait - const Duration(seconds: 1);
      if (next <= Duration.zero) {
        timer.cancel();
        _tick = null;
      }
      setState(() => _wait = next <= Duration.zero ? Duration.zero : next);
    });
  }

  static String _formatWait(Duration wait) {
    final int seconds =
        wait.inSeconds + (wait.inMilliseconds % 1000 > 0 ? 1 : 0);
    final String rest = (seconds % 60).toString().padLeft(2, '0');
    return '${seconds ~/ 60}:$rest';
  }

  /// Erases this device and lets the gate carry on to a fresh start. The
  /// lock screen stays up until it is done ([_AppSecurityGateState._wiping]).
  Future<bool> _wipe() async {
    widget.wiping.value = true;
    try {
      await ref.read(zenLocalDataResetProvider)(ref);
      return true;
    } on Object catch (error, stackTrace) {
      logZenError(
        'Erasing this device from the lock screen failed',
        error,
        stackTrace,
      );
      return false;
    } finally {
      widget.wiping.value = false;
    }
  }

  Future<void> _startOver() async {
    setState(() => _wipeFailed = false);
    final bool done = await _wipe();
    if (!mounted) {
      return;
    }
    setState(() => _wipeFailed = !done);
  }

  Future<void> _loadBiometricAvailability() async {
    final bool isAvailable = await ref
        .read(appSecurityServiceProvider)
        .canUnlockWithBiometrics();
    if (!mounted) {
      return;
    }
    setState(() => _canUseBiometrics = isAvailable);
    // Set up: the fingerprint / face prompt comes at once, the password
    // stays as the fallback.
    if (isAvailable && !_biometricsAsked) {
      _biometricsAsked = true;
      unawaited(_unlockWithBiometrics());
    }
  }

  bool _biometricsAsked = false;

  Future<void> _unlock() async {
    // Enter in the field submits too: one attempt at a time, or attempts
    // started together would all pass the check before any failure counts.
    if (_isSubmitting ||
        _wait > Duration.zero ||
        !_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    final UnlockThrottle throttle = ref.read(unlockThrottleProvider);
    final Duration left = await throttle.remaining();
    if (!mounted) {
      return;
    }
    if (left > Duration.zero) {
      setState(() => _isSubmitting = false);
      _startWait(left);
      return;
    }
    final String password = _passwordController.text;
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    // The panic password wipes all local data and silently lands on a fresh
    // install state — no feedback that anything was erased.
    if (await security.matchesPanicPassword(password)) {
      if (await security.verifyPassword(password)) {
        // Both the same (set before they were checked against each other):
        // the real password never wipes. The panic password is void.
        await security.clearPanicPassword();
      } else {
        await _wipe();
        if (!mounted) {
          return;
        }
        _passwordController.clear();
        setState(() {
          _isSubmitting = false;
        });
        return;
      }
    }
    final bool unlocked = await security.unlock(password);
    Duration wait = Duration.zero;
    if (unlocked) {
      await throttle.clear();
    } else {
      wait = await throttle.recordFailure();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isSubmitting = false;
      _errorText = unlocked || wait > Duration.zero
          ? null
          : t('Nieprawidłowe hasło.');
    });
    if (wait > Duration.zero) {
      _startWait(wait);
    }
  }

  Future<void> _unlockWithBiometrics() async {
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    // The hardware vault asks for the fingerprint / face / Windows Hello
    // itself and only then releases the key.
    final bool unlocked = await ref
        .read(appSecurityServiceProvider)
        .unlockWithBiometrics();
    if (unlocked) {
      await ref.read(unlockThrottleProvider).clear();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isSubmitting = false;
      _errorText = unlocked
          ? null
          : t('Nie udało się odblokować biometrią. Użyj hasła.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (_other) {
      return _GateScaffold(
        child: OtherAccountPanel(onBack: () => setState(() => _other = false)),
      );
    }
    if (_forgot) {
      return _GateScaffold(
        child: _ForgotPasswordPanel(
          wiping: widget.wiping,
          failed: _wipeFailed,
          onConfirmed: _startOver,
          onBack: () => setState(() {
            _forgot = false;
            _wipeFailed = false;
          }),
        ),
      );
    }
    return _GateScaffold(
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Center(child: _GateLockIcon(icon: Icons.lock_rounded)),
            const SizedBox(height: 18),
            Center(
              child: ZenPill(
                text: t('Blokada aplikacji'),
                tone: zen.accent,
                icon: Icons.shield_outlined,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t('Zen jest zablokowany'),
              textAlign: TextAlign.center,
              style: zen.display(
                color: zen.textPrimary,
                size: 28,
                weight: FontWeight.w600,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              t(
                'Dane na tym urządzeniu są zaszyfrowane. Zen dalej odbiera '
                'wiadomości — zobaczysz je po odblokowaniu.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.textSecondary,
                height: 1.45,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              key: const Key('app-unlock-password-field'),
              controller: _passwordController,
              obscureText: _obscureText,
              autofocus: true,
              enableIMEPersonalizedLearning: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: t('Hasło'),
                hintText: t('Wpisz hasło aplikacji'),
                prefixIcon: const Icon(Icons.key_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscureText ? t('Pokaż hasło') : t('Ukryj hasło'),
                  onPressed: () {
                    setState(() => _obscureText = !_obscureText);
                  },
                  icon: Icon(
                    _obscureText
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
              validator: (String? value) {
                if (value == null || value.isEmpty) {
                  return t('Podaj hasło.');
                }
                return null;
              },
              onFieldSubmitted: (_) => _unlock(),
            ),
            if (_wait > Duration.zero) ...<Widget>[
              const SizedBox(height: 10),
              _GateError(
                key: const Key('app-unlock-wait-message'),
                text: t('Za dużo błędnych prób. Spróbuj ponownie za {time}.', {
                  'time': _formatWait(_wait),
                }),
              ),
            ] else if (_errorText != null) ...<Widget>[
              const SizedBox(height: 10),
              _GateError(text: _errorText!),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('app-unlock-submit-button'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _isSubmitting || _wait > Duration.zero
                  ? null
                  : _unlock,
              icon: _isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_open_rounded, size: 20),
              label: Text(_isSubmitting ? t('Odblokowywanie…') : t('Odblokuj')),
            ),
            if (_canUseBiometrics) ...<Widget>[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('app-unlock-biometric-button'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: _isSubmitting ? null : _unlockWithBiometrics,
                icon: const Icon(Icons.fingerprint_rounded, size: 22),
                label: Text(t('Biometria')),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.timer_outlined, size: 14, color: zen.textMuted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    t(
                      'Kiedy Zen ma się blokować, ustawisz w Ustawieniach → '
                      'Bezpieczeństwo.',
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: zen.textMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                key: const Key('app-unlock-forgot-button'),
                style: TextButton.styleFrom(foregroundColor: zen.textMuted),
                onPressed: _isSubmitting
                    ? null
                    : () => setState(() => _forgot = true),
                child: Text(
                  t('Nie pamiętam hasła — zacznij od nowa'),
                  // The size only: the app's font stays.
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
            // Discreet: the same on every device, accounts or not.
            Center(
              child: TextButton(
                key: const Key('app-unlock-other-account'),
                style: TextButton.styleFrom(foregroundColor: zen.textMuted),
                onPressed: _isSubmitting
                    ? null
                    : () => setState(() => _other = true),
                child: Text(
                  t('Inne konto'),
                  // The size only: the app's font stays.
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Nie pamiętam hasła": says what erasing this device means, then waits
/// for the button to be held. Says nothing of the panic password, so that
/// nobody can tell from here whether there is one.
class _ForgotPasswordPanel extends StatelessWidget {
  const _ForgotPasswordPanel({
    required this.wiping,
    required this.failed,
    required this.onConfirmed,
    required this.onBack,
  });

  final ValueListenable<bool> wiping;
  final bool failed;
  final VoidCallback onConfirmed;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: wiping,
      builder: (BuildContext context, bool busy, Widget? child) {
        return Column(
          key: const Key('app-reset-panel'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Center(
              child: _GateLockIcon(icon: Icons.warning_amber_rounded),
            ),
            const SizedBox(height: 18),
            Text(
              t('Zacząć od nowa?'),
              textAlign: TextAlign.center,
              style: zen.display(
                color: zen.textPrimary,
                size: 28,
                weight: FontWeight.w600,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t(
                'Bez hasła nie otworzysz tych danych. Możesz je usunąć i '
                'zacząć jak na nowym urządzeniu. Z TEGO urządzenia zniknie '
                'wszystko: klucz konta, rozmowy, pliki i ustawienia.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.textSecondary,
                height: 1.45,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              t(
                'Konto wróci z drugiego urządzenia z tym kontem, z pliku '
                'kopii całego konta, z kopii klucza albo z kręgu '
                'odzyskiwania. Tego nie da się cofnąć.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.danger,
                height: 1.45,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (failed && !busy) ...<Widget>[
              const SizedBox(height: 12),
              _GateError(
                text: t(
                  'Nie udało się usunąć wszystkich danych. Spróbuj jeszcze '
                  'raz.',
                ),
              ),
            ],
            const SizedBox(height: 22),
            if (busy) ...<Widget>[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 12),
              Text(
                t('Usuwam dane z tego urządzenia…'),
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textSecondary),
              ),
            ] else ...<Widget>[
              Center(
                child: HoldToConfirmButton(
                  key: const Key('app-reset-hold-button'),
                  autofocus: true,
                  idleLabel: t('Przytrzymaj 10 sekund, aby usunąć wszystko'),
                  holdingLabel: (int seconds) =>
                      t('Trzymaj… jeszcze {n} s', {'n': seconds}),
                  onConfirmed: onConfirmed,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t(
                  'Puść przycisk, żeby przerwać. Na komputerze możesz też '
                  'przytrzymać Enter lub spację.',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              TextButton(
                key: const Key('app-reset-back-button'),
                onPressed: onBack,
                child: Text(t('Wróć')),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The lock screens' frame: a soft glow of the accent behind one centred
/// card that scrolls when the keyboard is up.
class _GateScaffold extends StatelessWidget {
  const _GateScaffold({required this.child, this.scaffoldKey});

  final Widget child;
  final Key? scaffoldKey;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: scaffoldKey,
      backgroundColor: zen.background,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.6, -0.9),
                  radius: 1.1,
                  colors: <Color>[
                    zen.accent.withValues(alpha: 0.22),
                    zen.accent.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.9, 0.9),
                  radius: 1.0,
                  colors: <Color>[
                    zen.accentSecondary.withValues(alpha: 0.16),
                    zen.accentSecondary.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
                    decoration: BoxDecoration(
                      color: zen.surface.withValues(alpha: 0.92),
                      borderRadius: context.zenRadius(30),
                      border: Border.all(color: zen.outlineSoft),
                      boxShadow: ZenLook.of(context).tinted(
                        zen,
                        zen.accent,
                        radius: 40,
                        alpha: 0.14,
                        offset: const Offset(0, 16),
                      ),
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The big lock in a glowing gradient circle.
class _GateLockIcon extends StatelessWidget {
  const _GateLockIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: <Color>[zen.accent, zen.accentSecondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: ZenLook.of(
          context,
        ).tinted(zen, zen.accent, radius: 30, alpha: 0.4),
      ),
      child: Icon(icon, size: 40, color: ZenColors.foregroundFor(zen.accent)),
    );
  }
}

/// A short error under the password field.
class _GateError extends StatelessWidget {
  const _GateError({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: zen.danger.withValues(alpha: 0.10),
        borderRadius: context.zenRadius(14),
        border: Border.all(color: zen.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 18, color: zen.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: zen.danger, fontSize: 13.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Before anything else, an app password. Without it the data key
/// sits in the system's storage and anyone who gets into the phone can use
/// it; with it, the files on disk are useless without the password.
class _PasswordSetupScreen extends ConsumerStatefulWidget {
  const _PasswordSetupScreen();

  @override
  ConsumerState<_PasswordSetupScreen> createState() =>
      _PasswordSetupScreenState();
}

class _PasswordSetupScreenState extends ConsumerState<_PasswordSetupScreen> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _set() async {
    final String password = _password.text;
    if (password.length < kMinAppPasswordLength) {
      setState(
        () => _error = tn(
          kMinAppPasswordLength,
          one: 'Hasło musi mieć co najmniej {n} znak.',
          few: 'Hasło musi mieć co najmniej {n} znaki.',
          many: 'Hasło musi mieć co najmniej {n} znaków.',
        ),
      );
      return;
    }
    if (password != _repeat.text) {
      setState(() => _error = t('Hasła się różnią.'));
      return;
    }
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    setState(() => _error = null);
    // Ask about biometric unlock once, before the password is saved: as soon
    // as it is, the gate swaps this screen for the app. It is off until the
    // person says yes.
    // Not on Windows: there Windows Hello is usually just the PIN, and it
    // does not keep the key in hardware (settings explain it).
    final bool wantsBiometrics =
        defaultTargetPlatform != TargetPlatform.windows &&
        (await security.biometricUnlockStatus()).deviceSupported &&
        mounted &&
        await _askBiometrics();
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await security.setPassword(password);
      if (wantsBiometrics) {
        await security.setBiometricUnlockEnabled(true);
      }
    } on AppPasswordConflictException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = t('Nie udało się ustawić hasła: {error}', {
            'error': error,
          }),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _askBiometrics() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) {
        final ZenColors zen = ZenColors.of(dialog);
        return AlertDialog(
          key: const Key('app-password-biometric-question'),
          icon: Icon(Icons.fingerprint_rounded, color: zen.accent, size: 32),
          title: Text(t('Odblokowywać odciskiem lub twarzą?')),
          content: SingleChildScrollView(
            child: Text(
              t(
                'Wygodniej, ale słabiej niż hasło. {risk}\n\n'
                'Hasło i tak zostaje (przyda się po restarcie), a zmienić to '
                'możesz w Ustawieniach.',
                {'risk': kBiometricRiskText},
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('app-password-biometric-yes'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(t('Włącz mimo to')),
            ),
            FilledButton(
              key: const Key('app-password-biometric-no'),
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(t('Tylko hasło')),
            ),
          ],
        );
      },
    );
    return yes ?? false;
  }

  Future<void> _skip() async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        scrollable: true,
        icon: Icon(
          Icons.no_encryption_outlined,
          color: ZenColors.of(dialog).warning,
          size: 32,
        ),
        title: Text(t('Bez hasła?')),
        content: Text(
          t(
            'Bez hasła każdy, kto dostanie się do tego urządzenia albo '
            'skopiuje jego pliki, może przeczytać Twoje rozmowy. Hasło '
            'możesz ustawić później w Ustawieniach.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Wróć')),
          ),
          TextButton(
            key: const Key('app-password-skip-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Tak, bez hasła')),
          ),
        ],
      ),
    );
    if (sure == true) {
      await ref
          .read(appSettingsControllerProvider.notifier)
          .setAllowNoAppPassword(true);
    }
  }

  /// The first start of this device: the way back to an existing account
  /// is offered here already, not only after the setup.
  bool _offersRestore() =>
      ref.watch(zenAccountProvider).isDefault &&
      ref.watch(accountSecureStepRequiredProvider) &&
      ref.watch(ledgerNodeEnabledProvider) &&
      !ref.watch(
        appSettingsControllerProvider.select(
          (AppSettings s) => s.accountSecureOffered,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return _GateScaffold(
      scaffoldKey: const Key('app-password-setup'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Center(child: _GateLockIcon(icon: Icons.password_rounded)),
          const SizedBox(height: 18),
          Center(
            child: ZenPill(
              text: t('Hasło aplikacji'),
              tone: zen.accent,
              icon: Icons.shield_outlined,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            t('Ustaw hasło'),
            textAlign: TextAlign.center,
            style: zen.display(
              color: zen.textPrimary,
              size: 28,
              weight: FontWeight.w600,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            t(
              'Hasło szyfruje wszystko, co Zen trzyma na tym urządzeniu. '
              'Gdy aplikacja jest zablokowana, na dysku leży tylko '
              'szyfrogram — bez hasła nikt go nie odczyta. Potem możesz '
              'odblokowywać odciskiem palca lub twarzą.',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: zen.textSecondary,
              height: 1.45,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const Key('app-password-new'),
            controller: _password,
            obscureText: true,
            enableIMEPersonalizedLearning: false,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: t('Hasło'),
              hintText: t('Wymyśl hasło'),
              helperText: tn(
                kMinAppPasswordLength,
                one: 'Co najmniej {n} znak',
                few: 'Co najmniej {n} znaki',
                many: 'Co najmniej {n} znaków',
              ),
              prefixIcon: const Icon(Icons.key_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('app-password-repeat'),
            controller: _repeat,
            obscureText: true,
            enableIMEPersonalizedLearning: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: t('Powtórz hasło'),
              hintText: t('To samo hasło jeszcze raz'),
              prefixIcon: const Icon(Icons.key_rounded),
            ),
            onSubmitted: (_) => _set(),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            _GateError(text: _error!),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('app-password-set'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _busy ? null : _set,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.lock_rounded, size: 20),
            label: Text(_busy ? t('Ustawiam…') : t('Ustaw hasło')),
          ),
          if (_offersRestore()) ...<Widget>[
            const SizedBox(height: 10),
            _HaveAccountChoice(busy: _busy),
          ],
          if (ref.watch(zenAccountProvider).isDefault) ...<Widget>[
            const SizedBox(height: 6),
            TextButton(
              key: const Key('app-password-skip'),
              onPressed: _busy ? null : _skip,
              child: Text(t('Bez hasła (niezalecane)')),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Mam już konto" on the password step: straight to the ways back, before
/// any password (a backup of the whole app brings its own; the ways
/// without one ask for it, see the gate). "Nowe konto" there comes back
/// here.
class _HaveAccountChoice extends ConsumerWidget {
  const _HaveAccountChoice({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ValueNotifier<AccountStartPlan> plan = ref.watch(
      accountStartPlanProvider,
    );
    return OutlinedButton.icon(
      key: const Key('app-password-have-account'),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      onPressed: busy ? null : () => plan.value = AccountStartPlan.restore,
      icon: const Icon(Icons.restore_page_outlined, size: 20),
      label: Text(t('Mam już konto — przywróć je')),
    );
  }
}
