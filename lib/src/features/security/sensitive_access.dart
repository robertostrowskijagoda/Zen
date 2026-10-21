import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/security/app_security_service.dart';

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

/// Asks again before a sensitive place opens (account and recovery, devices,
/// call recordings): biometrics when the key is sealed in hardware, the app
/// password otherwise. Without an app password there is nothing to ask for.
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
        builder: (BuildContext context) =>
            _ConfirmPasswordDialog(security: security, reason: reason),
      ) ??
      false;
  if (ok) {
    clock.confirmed();
  }
  return ok;
}

class _ConfirmPasswordDialog extends StatefulWidget {
  const _ConfirmPasswordDialog({required this.security, required this.reason});

  final AppSecurityService security;
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
    return AlertDialog(
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
