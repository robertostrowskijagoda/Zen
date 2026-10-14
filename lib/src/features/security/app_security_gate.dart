import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_data_reset.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/permissions/presentation/permissions_screen.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

class AppSecurityGate extends ConsumerStatefulWidget {
  const AppSecurityGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppSecurityGate> createState() => _AppSecurityGateState();
}

class _AppSecurityGateState extends ConsumerState<AppSecurityGate>
    with WidgetsBindingObserver {
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    switch (state) {
      case AppLifecycleState.paused:
        _pausedAt = DateTime.now();
        break;
      case AppLifecycleState.hidden:
        _pausedAt = DateTime.now();
        break;
      case AppLifecycleState.detached:
        if (security.lockMode == AppLockMode.appClose) {
          security.lock();
        }
        break;
      case AppLifecycleState.resumed:
        if (security.lockMode == AppLockMode.background &&
            _pausedAt != null &&
            DateTime.now().difference(_pausedAt!) >
                Duration(seconds: security.backgroundLockDelaySeconds)) {
          security.lock();
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
    // §25.2: once, after the app password, the permissions and Bluetooth
    // step (skipped where there is nothing to ask).
    final bool permissionsStep =
        ref.watch(permissionsSetupRequiredProvider) &&
        !appSettings.permissionsSetupDone &&
        ref.watch(permissionsPlatformProvider).hasAnything;
    return AnimatedBuilder(
      animation: security,
      builder: (BuildContext context, Widget? child) {
        if (!security.isReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (!security.hasPassword &&
            ref.watch(appPasswordRequiredProvider) &&
            !ref.watch(appSettingsControllerProvider).allowNoAppPassword) {
          // §14.1: an app password is required by default. Its own Navigator
          // (the gate sits above the root one) so the setup questions can
          // open dialogs; it brings its own Overlay for the text fields.
          return Navigator(
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
          if (permissionsStep) {
            // Its own Navigator, like the password step above.
            return Navigator(
              onGenerateRoute: (RouteSettings route) => MaterialPageRoute<void>(
                settings: route,
                builder: (BuildContext context) =>
                    const PermissionsSetupStage(),
              ),
            );
          }
          return child!;
        }
        // The gate sits above the root Navigator (MaterialApp.builder), so
        // the lock screen must provide its own Overlay for text fields.
        return Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (BuildContext context) => const _UnlockScreen(),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}

class _UnlockScreen extends ConsumerStatefulWidget {
  const _UnlockScreen();

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

  @override
  void initState() {
    super.initState();
    unawaited(_loadBiometricAvailability());
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadBiometricAvailability() async {
    final bool isAvailable = await ref
        .read(appSecurityServiceProvider)
        .canUnlockWithBiometrics();
    if (!mounted) {
      return;
    }
    setState(() => _canUseBiometrics = isAvailable);
  }

  Future<void> _unlock() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
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
        await performZenLocalDataReset(ref);
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
    if (!mounted) {
      return;
    }
    setState(() {
      _isSubmitting = false;
      _errorText = unlocked ? null : 'Nieprawidłowe hasło.';
    });
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
    if (!mounted) {
      return;
    }
    setState(() {
      _isSubmitting = false;
      _errorText = unlocked
          ? null
          : 'Nie udało się odblokować biometrią. Użyj hasła.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
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
                text: 'Blokada aplikacji',
                tone: zen.accent,
                icon: Icons.shield_outlined,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Zen jest zablokowany',
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
              'Dane na tym urządzeniu są zaszyfrowane. Zen dalej odbiera '
              'wiadomości — zobaczysz je po odblokowaniu.',
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
                labelText: 'Hasło',
                hintText: 'Wpisz hasło aplikacji',
                prefixIcon: const Icon(Icons.key_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscureText ? 'Pokaż hasło' : 'Ukryj hasło',
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
                  return 'Podaj hasło.';
                }
                return null;
              },
              onFieldSubmitted: (_) => _unlock(),
            ),
            if (_errorText != null) ...<Widget>[
              const SizedBox(height: 10),
              _GateError(text: _errorText!),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('app-unlock-submit-button'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _isSubmitting ? null : _unlock,
              icon: _isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_open_rounded, size: 20),
              label: Text(_isSubmitting ? 'Odblokowywanie…' : 'Odblokuj'),
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
                label: const Text('Biometria'),
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
                    'Kiedy Zen ma się blokować, ustawisz w Ustawieniach → '
                    'Bezpieczeństwo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: zen.textMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: zen.outlineSoft),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: zen.accent.withValues(alpha: 0.14),
                          blurRadius: 40,
                          spreadRadius: -8,
                          offset: const Offset(0, 16),
                        ),
                      ],
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
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: zen.accent.withValues(alpha: 0.4),
            blurRadius: 30,
            spreadRadius: -4,
          ),
        ],
      ),
      child: Icon(icon, size: 40, color: ZenColors.foregroundFor(zen.accent)),
    );
  }
}

/// A short error under the password field.
class _GateError extends StatelessWidget {
  const _GateError({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: zen.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
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

/// §14.1: before anything else, an app password. Without it the data key
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
        () => _error =
            'Hasło musi mieć co najmniej $kMinAppPasswordLength '
            'znaków.',
      );
      return;
    }
    if (password != _repeat.text) {
      setState(() => _error = 'Hasła się różnią.');
      return;
    }
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    setState(() => _error = null);
    // Ask about biometric unlock once, before the password is saved: as soon
    // as it is, the gate swaps this screen for the app. It is off until the
    // person says yes.
    final bool wantsBiometrics =
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
        setState(() => _error = 'Nie udało się ustawić hasła: $error');
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
          title: const Text('Odblokowywać odciskiem lub twarzą?'),
          content: const Text(
            'Zamiast wpisywać hasło za każdym razem, możesz odblokowywać Zen '
            'biometrią tego telefonu. Hasło i tak zostaje — przyda się po '
            'restarcie. Możesz to później zmienić w Ustawieniach.',
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('app-password-biometric-no'),
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Nie teraz'),
            ),
            FilledButton(
              key: const Key('app-password-biometric-yes'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Włącz biometrię'),
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
        icon: Icon(
          Icons.no_encryption_outlined,
          color: ZenColors.of(dialog).warning,
          size: 32,
        ),
        title: const Text('Bez hasła?'),
        content: const Text(
          'Bez hasła każdy, kto dostanie się do tego urządzenia albo '
          'skopiuje jego pliki, może przeczytać Twoje rozmowy. Hasło '
          'możesz ustawić później w Ustawieniach.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Wróć'),
          ),
          TextButton(
            key: const Key('app-password-skip-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Tak, bez hasła'),
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
              text: 'Hasło aplikacji',
              tone: zen.accent,
              icon: Icons.shield_outlined,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Ustaw hasło',
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
            'Hasło szyfruje wszystko, co Zen trzyma na tym urządzeniu. '
            'Gdy aplikacja jest zablokowana, na dysku leży tylko '
            'szyfrogram — bez hasła nikt go nie odczyta. Potem możesz '
            'odblokowywać odciskiem palca lub twarzą.',
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
              labelText: 'Hasło',
              hintText: 'Wymyśl hasło',
              helperText: 'Co najmniej $kMinAppPasswordLength znaków',
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
            decoration: const InputDecoration(
              labelText: 'Powtórz hasło',
              hintText: 'To samo hasło jeszcze raz',
              prefixIcon: Icon(Icons.key_rounded),
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
            label: Text(_busy ? 'Ustawiam…' : 'Ustaw hasło'),
          ),
          const SizedBox(height: 6),
          TextButton(
            key: const Key('app-password-skip'),
            onPressed: _busy ? null : _skip,
            child: const Text('Bez hasła (niezalecane)'),
          ),
        ],
      ),
    );
  }
}
