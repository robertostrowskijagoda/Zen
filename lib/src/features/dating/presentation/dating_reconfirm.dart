import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Keeps [child] (a dating screen) shut while the app itself is locked:
/// then [child] is not even built, so nothing of the dating life shows
/// behind the lock screen (the window is protected against screenshots by
/// the `SecureScreen` around it). Unlocking the app opens it again at once.
///
/// Opening Dating in an unlocked app asks for nothing more: the app's own
/// lock (after leaving the app, on closing it, or by hand) is what guards
/// it, so the person is not asked for the password twice.
class DatingReconfirm extends ConsumerWidget {
  const DatingReconfirm({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    return ListenableBuilder(
      listenable: security,
      builder: (BuildContext context, Widget? _) {
        if (!security.isLocked) {
          return child;
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
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('Odblokuj aplikację, a Randki otworzą się same.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: zen.textSecondary, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
