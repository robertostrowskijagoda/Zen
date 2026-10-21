import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The phone makers whose battery managers close apps in the background on
/// their own, whatever the system's battery optimisation says.
enum PhoneVendor {
  xiaomi,
  samsung,
  huawei,
  oneplus,
  oppo,
  vivo,
  other;

  /// The vendor behind `Build.MANUFACTURER` (any case); [other] when it is
  /// not one of the troublesome ones or unknown.
  static PhoneVendor fromManufacturer(String manufacturer) {
    final String m = manufacturer.toLowerCase();
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return PhoneVendor.xiaomi;
    }
    if (m.contains('samsung')) {
      return PhoneVendor.samsung;
    }
    if (m.contains('huawei') || m.contains('honor')) {
      return PhoneVendor.huawei;
    }
    if (m.contains('oneplus')) {
      return PhoneVendor.oneplus;
    }
    if (m.contains('oppo') || m.contains('realme')) {
      return PhoneVendor.oppo;
    }
    if (m.contains('vivo')) {
      return PhoneVendor.vivo;
    }
    return PhoneVendor.other;
  }

  String get label => switch (this) {
    PhoneVendor.xiaomi => 'Xiaomi / Redmi / POCO',
    PhoneVendor.samsung => 'Samsung',
    PhoneVendor.huawei => 'Huawei / Honor',
    PhoneVendor.oneplus => 'OnePlus',
    PhoneVendor.oppo => 'Oppo / Realme',
    PhoneVendor.vivo => 'Vivo',
    PhoneVendor.other => t('Inne telefony'),
  };

  /// What to switch off, step by step, for this vendor.
  String get steps => switch (this) {
    PhoneVendor.xiaomi => t(
      'Ustawienia → Aplikacje → Zen → włącz „Autostart”. Potem '
      '„Oszczędzanie baterii” → „Bez ograniczeń”. W ekranie ostatnich '
      'aplikacji przytrzymaj kartę Zen i wybierz kłódkę.',
    ),
    PhoneVendor.samsung => t(
      'Ustawienia → Bateria → Limity użycia w tle: Zen nie może być na '
      'liście „Uśpione aplikacje” ani „Głęboko uśpione aplikacje”. Wyłącz '
      '„Usypiaj nieużywane aplikacje” dla Zen.',
    ),
    PhoneVendor.huawei => t(
      'Ustawienia → Aplikacje → Uruchamianie aplikacji → Zen → wyłącz '
      '„Zarządzaj automatycznie” i włącz uruchamianie automatyczne, '
      'uruchamianie pośrednie i działanie w tle.',
    ),
    PhoneVendor.oneplus => t(
      'Ustawienia → Bateria → Optymalizacja baterii → Zen → „Nie '
      'optymalizuj”. W ustawieniach aplikacji włącz „Zezwalaj na '
      'aktywność w tle”.',
    ),
    PhoneVendor.oppo => t(
      'Ustawienia → Bateria → Zen → włącz „Zezwalaj na aktywność w tle” '
      'i „Autostart”. W ekranie ostatnich aplikacji zablokuj kartę Zen.',
    ),
    PhoneVendor.vivo => t(
      'Ustawienia → Bateria → Aktywność w tle → Zen → „Zezwalaj”. W '
      'ustawieniach aplikacji włącz autostart.',
    ),
    PhoneVendor.other => t(
      'Poszukaj w ustawieniach telefonu (Bateria, Aplikacje) opcji w '
      'rodzaju „Autostart”, „Uśpione aplikacje”, „Aktywność w tle” lub '
      '„Oszczędzanie baterii” i ustaw dla Zen „Bez ograniczeń”.',
    ),
  };
}

/// "Telefony mają też własne «zabójce baterii»": instructions for the
/// maker of this phone, the others folded away.
class VendorBatteryHelp extends StatelessWidget {
  const VendorBatteryHelp({
    required this.manufacturer,
    required this.onOpenSettings,
    super.key,
  });

  /// `Build.MANUFACTURER`, or empty when unknown.
  final String manufacturer;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PhoneVendor mine = PhoneVendor.fromManufacturer(manufacturer);
    final bool known = mine != PhoneVendor.other;
    return Column(
      key: const Key('vendor-battery-help'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenInfo(
          icon: Icons.phone_android_rounded,
          tone: zen.warning,
          title: known
              ? t('Twój telefon ({vendor}) ma własne ograniczenia', {
                  'vendor': mine.label,
                })
              : t('Telefony mają też własne „zabójce baterii”'),
          text: known
              ? mine.steps
              : t(
                  'Xiaomi, Samsung, Huawei czy OnePlus potrafią zamknąć Zen '
                  'mimo ustawienia powyżej. Wybierz swojego producenta '
                  'poniżej.',
                ),
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('vendor-battery-others'),
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              known ? t('Instrukcje dla innych telefonów') : t('Producenci'),
              style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
            ),
            children: <Widget>[
              for (final PhoneVendor v in PhoneVendor.values)
                if (v != mine)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          v.label,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          v.steps,
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('vendor-battery-open-settings'),
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: Text(t('Otwórz ustawienia aplikacji')),
          ),
        ),
      ],
    );
  }
}
