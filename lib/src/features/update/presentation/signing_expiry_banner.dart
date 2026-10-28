import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/update/signing_expiry.dart';

/// On a sideloaded iPhone build, from two days before its signature runs
/// out: iOS will stop opening Zen then, and this is how to refresh it in
/// SideStore. Closed per expiry date (a refreshed build warns again later).
class SigningExpiryBanner extends ConsumerWidget {
  const SigningExpiryBanner({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime? expiry = ref.watch(signingExpiryProvider).value;
    if (expiry == null) {
      return const SizedBox.shrink();
    }
    final int? days = signingDaysLeftToWarn(expiry, DateTime.now());
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final String tip = signingTipId(expiry);
    if (days == null || settings.seenTips.contains(tip)) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: padding,
      child: ZenCard(
        key: const Key('signing-expiry-banner'),
        tone: zen.warning,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenInfo(
              icon: Icons.event_busy_rounded,
              tone: zen.warning,
              title: days <= 0
                  ? t('Dziś iPhone zablokuje Zen')
                  : tn(
                      days,
                      one: 'Za {n} dzień iPhone zablokuje Zen',
                      few: 'Za {n} dni iPhone zablokuje Zen',
                      many: 'Za {n} dni iPhone zablokuje Zen',
                    ),
              text: t(
                'Podpis tej kopii Zen wygasa {date}. Włącz LocalDevVPN, '
                'otwórz SideStore → „My Apps” i stuknij licznik dni przy Zen '
                '(albo „Refresh All”). Twoje dane zostają. Żeby działo się to '
                'samo, ustaw automatyzację w Skrótach (strona instalacji na '
                'iPhone’a, krok 6).',
                <String, Object?>{'date': ZenFormat.dayMonthTime(expiry)},
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const Key('signing-expiry-ok'),
                onPressed: () => unawaited(
                  ref
                      .read(appSettingsControllerProvider.notifier)
                      .markTipSeen(tip),
                ),
                child: Text(t('Rozumiem')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
