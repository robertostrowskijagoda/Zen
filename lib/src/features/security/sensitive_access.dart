import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';

/// How long one confirmation opens the sensitive places.
const Duration kSensitiveAccessGrace = Duration(seconds: 60);

/// Remembers the last time the person proved who they are,
/// so moving between two sensitive screens does not ask twice in a row.
/// Locking the app forgets it.
final class SensitiveAccessClock {
  SensitiveAccessClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _confirmedAt;

  bool get isFresh {
    final DateTime? at = _confirmedAt;
    if (at == null) {
      return false;
    }
    final Duration age = _now().difference(at);
    return !age.isNegative && age < kSensitiveAccessGrace;
  }

  void confirmed() => _confirmedAt = _now();

  void forget() => _confirmedAt = null;
}

final Provider<SensitiveAccessClock> sensitiveAccessClockProvider =
    Provider<SensitiveAccessClock>((Ref ref) {
      final SensitiveAccessClock clock = SensitiveAccessClock();
      final AppSecurityService security = ref.watch(appSecurityServiceProvider);
      void onChange() {
        if (security.isLocked) {
          clock.forget();
        }
      }

      security.addListener(onChange);
      ref.onDispose(() => security.removeListener(onChange));
      return clock;
    });

/// The lock screen's words for the wait after too many wrong passwords.
String passwordWaitText(Duration wait) => t(
  'Za dużo błędnych prób. Spróbuj ponownie za {time}.',
  {'time': formatUnlockWait(wait)},
);

/// The words under a password field after [outcome] of [tryPassword]: the
/// wait when one is on, otherwise [wrong].
String passwordTryError(PasswordTry outcome, String wrong) =>
    outcome.wait > Duration.zero ? passwordWaitText(outcome.wait) : wrong;

/// Another password of the account (the one of the account key) tried by
/// [unlock], counted with the lock screen's attempts; a right one clears
/// nothing. Null when it was right, otherwise the words for the field:
/// the wait, or [wrong] (by default "Złe hasło konta.").
Future<String?> tryAccountPassword(
  BuildContext context,
  Future<bool> Function() unlock, {
  String? wrong,
}) async {
  final UnlockThrottle throttle = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(unlockThrottleProvider);
  final PasswordTry outcome = await tryPassword(
    throttle,
    unlock,
    clears: false,
  );
  return outcome.right
      ? null
      : passwordTryError(outcome, wrong ?? t('Złe hasło konta.'));
}

/// Asks again before a sensitive place opens (account and recovery, devices,
/// call recordings): biometrics when the key is sealed in hardware, the app
/// password otherwise, counted with the lock screen's attempts
/// ([tryPassword]). Without an app password there is nothing to ask for.
Future<bool> confirmSensitiveAccess(
  BuildContext context, {
  required String reason,
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final AppSecurityService security = container.read(
    appSecurityServiceProvider,
  );
  if (!security.hasPassword) {
    return true;
  }
  final SensitiveAccessClock clock = container.read(
    sensitiveAccessClockProvider,
  );
  if (clock.isFresh) {
    return true;
  }
  if (await security.canUnlockWithBiometrics() &&
      await security.confirmWithBiometrics(reason: reason)) {
    clock.confirmed();
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  final bool ok =
      await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => _ConfirmPasswordDialog(
          security: security,
          throttle: container.read(unlockThrottleProvider),
          reason: reason,
        ),
      ) ??
      false;
  if (ok) {
    clock.confirmed();
  }
  return ok;
}

class _ConfirmPasswordDialog extends StatefulWidget {
  const _ConfirmPasswordDialog({
    required this.security,
    required this.throttle,
    required this.reason,
  });

  final AppSecurityService security;
  final UnlockThrottle throttle;
  final String reason;

  @override
  State<_ConfirmPasswordDialog> createState() => _ConfirmPasswordDialogState();
}

class _ConfirmPasswordDialogState extends State<_ConfirmPasswordDialog> {
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
    final PasswordTry outcome = await tryPassword(
      widget.throttle,
      () => widget.security.verifyPassword(password),
    );
    if (!mounted) {
      return;
    }
    if (outcome.right) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = passwordTryError(outcome, t('Nieprawidłowe hasło.'));
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      key: const Key('sensitive-access-dialog'),
      title: Text(t('Potwierdź, że to Ty')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.reason),
          const SizedBox(height: 12),
          TextField(
            key: const Key('sensitive-access-password'),
            controller: _controller,
            obscureText: _obscure,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
            enableIMEPersonalizedLearning: false,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: t('Hasło aplikacji'),
              errorText: _error,
              suffixIcon: IconButton(
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
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('sensitive-access-confirm'),
          onPressed: _busy ? null : _submit,
          child: Text(t('Potwierdź')),
        ),
      ],
    );
  }
}
