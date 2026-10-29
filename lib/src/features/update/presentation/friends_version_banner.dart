import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/update/newer_versions.dart';
import 'package:zen/src/features/update/presentation/own_copy_card.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';
import 'package:zen/src/features/update/version_gate.dart';

/// "Nowa oficjalna wersja 1.11.0 (podpisana)" when the maintainers' signature
/// verified, else the soft hint "Znajomi mają nowszą wersję Zen (1.11.0)": a
/// quiet tile that leads to "Aktualizacje i Podaj dalej". Nothing shows
/// while neither is the case.
class FriendsNewerVersionBanner extends ConsumerWidget {
  const FriendsNewerVersionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? signed = ref.watch(signedNewerVersionProvider);
    final String? version = signed ?? ref.watch(friendsNewerVersionProvider);
    final UpdateRequired? mustUpdate = ref.watch(updateRequiredProvider);
    // At start: a red warning when this copy is signed with another key.
    // Then: this build is no longer supported, or a newer one's data is
    // kept here untouched.
    final Widget copyWarning = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const OwnCopyCard(onlyWarning: true),
        if (mustUpdate != null)
          UpdateWarningTile(
            key: const Key('update-required-banner'),
            title: mustUpdate.byRelease
                ? t('Ta wersja Zen nie jest już obsługiwana')
                : t('Znajomi mają Zen, który nie rozmawia już z tą wersją'),
            body: t('Zaktualizuj Zen do wersji {version} lub nowszej.', {
              'version': mustUpdate.minimum,
            }),
          ),
        ListenableBuilder(
          listenable: ZenFormatGuard.instance,
          builder: (BuildContext context, Widget? _) =>
              ZenFormatGuard.instance.hasNewerData
              ? UpdateWarningTile(
                  key: const Key('newer-data-banner'),
                  title: t('Część danych zapisała nowsza wersja Zen'),
                  body: t(
                    'Zostają bez zmian. Zaktualizuj Zen, żeby z nich '
                    'korzystać.',
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
    if (version == null) {
      return copyWarning;
    }
    final ZenColors zen = ZenColors.of(context);
    final BorderRadius radius = context.zenRadius(18);
    final Widget tile = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: zen.accent.withValues(alpha: 0.09),
        borderRadius: radius,
        child: InkWell(
          key: const Key('friends-newer-version-banner'),
          borderRadius: radius,
          onTap: () => unawaited(UpdatesScreen.open(context)),
          child: Container(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 10, 12),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: zen.accent.withValues(alpha: 0.24)),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.new_releases_outlined, color: zen.accent, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        signed != null
                            ? t('Nowa oficjalna wersja {version} (podpisana)', {
                                'version': version,
                              })
                            : t('Znajomi mają nowszą wersję Zen ({version})', {
                                'version': version,
                              }),
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t('Zobacz, jak zaktualizować'),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: zen.textSecondary,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[copyWarning, tile],
    );
  }
}

/// A warning that this build must be updated: in the error colours, leads
/// to "Aktualizacje i Podaj dalej" (or wherever [onTap] leads, with
/// [icon]).
class UpdateWarningTile extends StatelessWidget {
  const UpdateWarningTile({
    required this.title,
    required this.body,
    this.icon = Icons.system_update_outlined,
    this.onTap,
    super.key,
  });

  final String title;
  final String body;
  final IconData icon;
  final void Function(BuildContext context)? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius radius = context.zenRadius(18);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => onTap != null
              ? onTap!(context)
              : unawaited(UpdatesScreen.open(context)),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 10, 12),
            child: Row(
              children: <Widget>[
                Icon(icon, color: scheme.onErrorContainer, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onErrorContainer,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
