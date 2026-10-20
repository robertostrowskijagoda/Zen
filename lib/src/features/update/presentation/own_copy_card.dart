import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/update/apk_signature.dart';
import 'package:zen/src/features/update/own_copy.dart';

/// What this installed copy of Zen says about itself (§14.3 point 2):
/// "Oficjalna kopia" when its signing certificate is a pinned official one,
/// a red warning with the certificate's fingerprint when it is another, and
/// a neutral "Nie można sprawdzić" while no official fingerprint is pinned.
/// With [onlyWarning] (at start) nothing but the red warning shows.
class OwnCopyCard extends ConsumerWidget {
  const OwnCopyCard({this.onlyWarning = false, super.key});

  final bool onlyWarning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final OwnCopyCheck? check = ref.watch(ownCopyCheckProvider).asData?.value;
    if (check == null ||
        check.state == OwnCopyState.notApplicable ||
        (onlyWarning && check.state != OwnCopyState.differs)) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final String? sha = check.apkSha256;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        switch (check.state) {
          OwnCopyState.official => ZenInfo(
            key: const Key('own-copy-official'),
            icon: Icons.verified_rounded,
            tone: zen.success,
            title: t('Oficjalna kopia'),
            text: t('Ta aplikacja jest podpisana oficjalnym kluczem Zen.'),
          ),
          OwnCopyState.differs => ZenInfo(
            key: const Key('own-copy-differs'),
            icon: Icons.gpp_bad_rounded,
            tone: zen.danger,
            title: t('To nie jest oficjalna kopia Zen'),
            text: t(
              'Podpis tej aplikacji nie zgadza się z oficjalnym kluczem. '
              'Link do zbiórki mógł zostać podmieniony, a aplikacja może '
              'szpiegować. Pobierz Zen od nowa z github.com/'
              'robertostrowskijagoda/Zen.\nOdcisk certyfikatu:\n'
              '{fingerprints}',
              <String, Object?>{
                'fingerprints': check.certificates
                    .map(formatCertificateFingerprint)
                    .join('\n'),
              },
            ),
          ),
          _ => ZenInfo(
            key: const Key('own-copy-unknown'),
            icon: Icons.help_outline_rounded,
            tone: zen.textMuted,
            title: t('Nie można sprawdzić'),
            text: t(
              'Ta wersja nie zna jeszcze odcisku oficjalnego klucza, więc '
              'nie da się potwierdzić, że to oficjalna kopia. To nie jest '
              'ostrzeżenie.',
            ),
          ),
        },
        if (!onlyWarning && sha != null)
          ZenInfo(
            key: const Key('own-copy-code'),
            icon: Icons.fingerprint_rounded,
            tone: zen.accent,
            title: t('Kod tej kopii: {code}', <String, Object?>{
              'code': buildShortCode(sha),
            }),
            text: t(
              'Znajomy, który dał Ci Zen, widzi ten sam kod w „Podaj dalej”. '
              'Porównajcie go na żywo albo przez telefon: jeśli się różni, '
              'to nie jest ten sam plik.',
            ),
          ),
      ],
    );
  }
}
