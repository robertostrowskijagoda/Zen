import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The id of the one-time iPhone card in `AppSettings.seenTips`.
const String kIPhoneDeliveryTip = 'iphone-delivery';

/// Whether the one-time iPhone card should show: on an iPhone ([iPhone], by
/// default this device) until it was dismissed.
bool showIPhoneDeliveryNotice(AppSettings settings, {bool? iPhone}) {
  final bool ios =
      iPhone ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  return ios && !settings.seenTips.contains(kIPhoneDeliveryTip);
}

/// A one-time card on an iPhone: iOS does not let Zen receive in the
/// background, so messages arrive while Zen is open or wait with friends'
/// devices that stay online (a computer, Android).
class IPhoneDeliveryNotice extends ConsumerWidget {
  const IPhoneDeliveryNotice({
    super.key,
    this.padding = EdgeInsets.zero,
    this.iPhone,
  });

  final EdgeInsetsGeometry padding;

  /// Overrides the platform check (tests).
  final bool? iPhone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    if (!showIPhoneDeliveryNotice(settings, iPhone: iPhone)) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: padding,
      child: ZenCard(
        key: const Key('iphone-delivery-notice'),
        tone: zen.accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenInfo(
              icon: Icons.phone_iphone_rounded,
              title: t('iPhone odbiera tylko przy otwartym Zen'),
              text: t(
                'iOS nie pozwala Zen działać w tle. Wiadomości dochodzą, gdy '
                'Zen jest otwarty, a do tego czasu czekają u nadawcy albo w '
                'skrzynkach u Twoich znajomych. Najlepiej działa, gdy ktoś z '
                'Twoich znajomych ma Zen na komputerze albo na Androidzie — '
                'jego urządzenie przechowa wiadomości dla Ciebie.',
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const Key('iphone-delivery-notice-ok'),
                onPressed: () => unawaited(
                  ref
                      .read(appSettingsControllerProvider.notifier)
                      .markTipSeen(kIPhoneDeliveryTip),
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
