import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';

/// Across the top of the app: "Jest nowa wersja … — warto zaktualizować"
/// with "Aktualizuj", and, when github.com cannot be reached while the rest
/// of the internet works, the warning that someone may be blocking Zen.
/// Both can be closed. Nothing shows otherwise (and never in the store
/// build, which has no GitHub check).
class GithubUpdateBanner extends ConsumerWidget {
  const GithubUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GithubUpdateService? service = ref.watch(githubUpdateServiceProvider);
    if (service == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? _) {
        final GithubRelease? newer = service.newer;
        final bool showNewer =
            newer != null && (service.showNewerBanner || service.installing);
        final bool showUnreachable = service.showUnreachableBanner;
        if (!showNewer && !showUnreachable) {
          return const SizedBox.shrink();
        }
        final ZenColors zen = ZenColors.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (showNewer)
                _BannerTile(
                  key: const Key('github-newer-banner'),
                  tone: zen.accent,
                  icon: Icons.new_releases_outlined,
                  text: t('Jest nowa wersja {version} — warto zaktualizować', {
                    'version': newer.version,
                  }),
                  onClose: service.installing ? null : service.dismissNewer,
                  child: _UpdateProgress(service: service, compact: true),
                ),
              if (showUnreachable)
                _BannerTile(
                  key: const Key('github-unreachable-banner'),
                  tone: zen.warning,
                  icon: Icons.cloud_off_rounded,
                  text: githubUnreachableMessage,
                  onClose: service.dismissUnreachable,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _BannerTile extends StatelessWidget {
  const _BannerTile({
    required this.tone,
    required this.icon,
    required this.text,
    this.onClose,
    this.child,
    super.key,
  });

  final Color tone;
  final IconData icon;
  final String text;
  final VoidCallback? onClose;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.09),
        borderRadius: context.zenRadius(18),
        border: Border.all(color: tone.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: tone, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
              if (onClose != null)
                IconButton(
                  tooltip: t('Zamknij'),
                  onPressed: onClose,
                  icon: Icon(
                    Icons.close_rounded,
                    color: zen.textSecondary,
                    size: 20,
                  ),
                ),
            ],
          ),
          ?child,
        ],
      ),
    );
  }
}

/// "Aktualizuj" (or "Szczegóły"), the download's progress and the result.
class _UpdateProgress extends StatelessWidget {
  const _UpdateProgress({required this.service, this.compact = false});

  final GithubUpdateService service;

  /// In the banner: "Szczegóły" leads to the updates screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final GithubInstallState state = service.installState;
    final String? message = service.installMessage;
    final String? step = switch (state) {
      GithubInstallState.downloading => t('Pobieram… {percent}%', {
        'percent': (service.progress * 100).round(),
      }),
      GithubInstallState.verifying => t('Sprawdzam sumę kontrolną…'),
      GithubInstallState.installing => t('Instaluję…'),
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (step != null) ...<Widget>[
            ClipRRect(
              borderRadius: context.zenRadius(99),
              child: LinearProgressIndicator(
                value: state == GithubInstallState.downloading
                    ? service.progress
                    : null,
                minHeight: 5,
                color: zen.accent,
                backgroundColor: zen.accent.withValues(alpha: 0.14),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              step,
              key: const Key('github-update-step'),
              style: TextStyle(color: zen.textSecondary, fontSize: 13),
            ),
          ] else if (message != null)
            Text(
              message,
              key: const Key('github-update-message'),
              style: TextStyle(
                color: state == GithubInstallState.failed
                    ? zen.danger
                    : zen.textSecondary,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          if (!service.canInstall)
            Text(
              t(
                'Na tym urządzeniu zaktualizuj Zen tak, jak go '
                'instalowano.',
              ),
              style: TextStyle(color: zen.textSecondary, fontSize: 13),
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              if (service.canInstall)
                FilledButton.icon(
                  key: const Key('github-update-install'),
                  onPressed: service.installing
                      ? null
                      : () => unawaited(service.update()),
                  icon: const Icon(Icons.system_update_rounded, size: 18),
                  label: Text(t('Aktualizuj')),
                ),
              if (compact)
                TextButton(
                  key: const Key('github-update-details'),
                  onPressed: () => unawaited(UpdatesScreen.open(context)),
                  child: Text(t('Szczegóły')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The GitHub part of "Aktualizacje i Podaj dalej": what the last check
/// found, "Sprawdź teraz" and "Aktualizuj". Nothing where the app does not
/// look at GitHub (the store build).
class GithubUpdateCard extends ConsumerWidget {
  const GithubUpdateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GithubUpdateService? service = ref.watch(githubUpdateServiceProvider);
    if (service == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? _) {
        final ZenColors zen = ZenColors.of(context);
        final GithubRelease? newer = service.newer;
        final DateTime? at = service.checkedAt;
        final (
          IconData icon,
          Color tone,
          String title,
          String? subtitle,
        ) = newer != null
            ? (
                Icons.new_releases_outlined,
                zen.accent,
                t('Jest nowa wersja {version} — warto zaktualizować', {
                  'version': newer.version,
                }),
                null,
              )
            : switch (service.state) {
                GithubCheckState.unknown => (
                  Icons.travel_explore_rounded,
                  zen.textMuted,
                  service.checking
                      ? t('Sprawdzam GitHuba…')
                      : t('Jeszcze nie sprawdzono'),
                  null,
                ),
                GithubCheckState.upToDate || GithubCheckState.newer => (
                  Icons.check_circle_outline_rounded,
                  zen.success,
                  t('Masz najnowszą wersję z GitHuba'),
                  at == null
                      ? null
                      : t('Sprawdzono {date} o {time}', {
                          'date': ZenFormat.date(at),
                          'time': ZenFormat.time(at),
                        }),
                ),
                GithubCheckState.unreachable => (
                  Icons.cloud_off_rounded,
                  zen.warning,
                  githubUnreachableMessage,
                  null,
                ),
                GithubCheckState.failed => (
                  Icons.error_outline_rounded,
                  zen.textMuted,
                  t('GitHub odpowiedział błędem: {error}', {
                    'error': service.error ?? '—',
                  }),
                  null,
                ),
              };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenSection(t('Nowa wersja z GitHuba'), top: 16),
            ZenCard(
              key: Key('github-state-${service.state.name}'),
              tone: newer != null ? zen.accent : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ZenIconBadge(icon: icon, tone: tone),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              title,
                              key: const Key('github-state-title'),
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                            ),
                            if (subtitle != null) ...<Widget>[
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 13.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (newer != null) _UpdateProgress(service: service),
                  if (newer != null &&
                      service.state == GithubCheckState.unreachable)
                    ZenInfo(
                      key: const Key('github-unreachable'),
                      icon: Icons.cloud_off_rounded,
                      tone: zen.warning,
                      text: githubUnreachableMessage,
                    )
                  else if (newer == null && service.installMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        service.installMessage!,
                        style: TextStyle(color: zen.textSecondary),
                      ),
                    ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    key: const Key('github-check-now'),
                    onPressed: service.checking || service.installing
                        ? null
                        : () => unawaited(service.check()),
                    icon: service.checking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: Text(t('Sprawdź teraz')),
                  ),
                  if (!service.verifiesAuthorSignature)
                    ZenInfo(
                      key: const Key('github-no-author-signature'),
                      icon: Icons.gpp_maybe_outlined,
                      tone: zen.warning,
                      text: t(
                        'Ta wersja Zen nie potrafi jeszcze sprawdzić podpisu '
                        'autora wydania. Pobrany plik porównuje tylko z '
                        'SHA256SUMS z tego samego wydania na GitHubie: to '
                        'chroni przed uszkodzonym plikiem, ale nie przed '
                        'wydaniem podrobionym przez kogoś, kto przejął '
                        'konto lub repozytorium.',
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      service.verifiesAuthorSignature
                          ? t(
                              'Zen sprawdza najnowsze wydanie na github.com '
                              'przy starcie i co 12 godzin. Pobrany plik '
                              'instaluje dopiero po sprawdzeniu podpisu '
                              'autora i zgodności z SHA256SUMS wydania.',
                            )
                          : t(
                              'Zen sprawdza najnowsze wydanie na github.com '
                              'przy starcie i co 12 godzin. Pobrany plik '
                              'instaluje dopiero po zgodności z SHA256SUMS '
                              'wydania.',
                            ),
                      style: TextStyle(
                        color: zen.textMuted,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
