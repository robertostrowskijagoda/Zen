import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// How long the app may be out of sight before the dating screens ask
/// again (point 4: re-confirmation for dating).
const Duration kDatingReconfirmAfter = Duration(seconds: 10);

/// Keeps [child] (a dating screen) shut until the person proves who they
/// are with biometrics or the app password ([confirmSensitiveAccess]) — when
/// the screen opens, and again after the app was in the background for
/// [away] or longer. While it is shut, [child] is not even built, so
/// nothing of the dating life shows (the window is protected against
/// screenshots by the `SecureScreen` around it).
///
/// Without an app password there is nothing to ask for and the screen
/// opens at once.
class DatingReconfirm extends ConsumerStatefulWidget {
  const DatingReconfirm({
    required this.child,
    this.away = kDatingReconfirmAfter,
    this.askOnOpen = true,
    super.key,
  });

  final Widget child;

  /// How long the app has to stay away to be asked again.
  final Duration away;

  /// Asks when the screen opens. Screens opened from inside the dating
  /// screen (a profile, a chat, the editor) pass false: the person has just
  /// proved who they are, they only lock after the app was away.
  final bool askOnOpen;

  @override
  ConsumerState<DatingReconfirm> createState() => _DatingReconfirmState();
}

class _DatingReconfirmState extends ConsumerState<DatingReconfirm>
    with WidgetsBindingObserver {
  late bool _open = !widget.askOnOpen;
  bool _asking = false;
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.askOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_confirm());
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Not `inactive`: system dialogs and the biometric prompt cause it.
    if (_asking) {
      return;
    }
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _leftAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final DateTime? left = _leftAt;
        _leftAt = null;
        if (left != null && DateTime.now().difference(left) >= widget.away) {
          _shut();
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _shut() {
    // The confirmation is forgotten too, so the grace period of an earlier
    // question does not let the screen open without one.
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sensitiveAccessClockProvider).forget();
    if (_open) {
      setState(() => _open = false);
    }
    // Asked at once only where the screen is in front; the others show the
    // lock until the person gets to them.
    if ((ModalRoute.of(context)?.isCurrent ?? true) &&
        TickerMode.getValuesNotifier(context).value.enabled) {
      unawaited(_confirm());
    }
  }

  Future<void> _confirm() async {
    if (_asking || _open) {
      return;
    }
    _asking = true;
    bool ok = false;
    try {
      ok = await confirmSensitiveAccess(
        context,
        reason: t('Randki są chronione — potwierdź, że to Ty.'),
      );
    } finally {
      _asking = false;
    }
    if (mounted && ok) {
      setState(() => _open = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_open) {
      return widget.child;
    }
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('dating-locked'),
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.lock_rounded, size: 48, color: zen.textMuted),
              const SizedBox(height: 16),
              Text(
                t('Randki są zablokowane'),
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t(
                  'Po powrocie do aplikacji trzeba je odblokować hasłem albo '
                  'biometrią.',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('dating-unlock'),
                onPressed: () => unawaited(_confirm()),
                icon: const Icon(Icons.lock_open_rounded),
                label: Text(t('Odblokuj')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
