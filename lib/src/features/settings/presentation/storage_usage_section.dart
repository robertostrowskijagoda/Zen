import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/presentation/storage_limits_section.dart';
import 'package:zen/src/features/settings/storage_breakdown.dart';
import 'package:zen/src/features/settings/storage_limit_warning.dart';

/// A slider over [AppSettings.storageLimitStepsMb]: [valueMb] snaps to the
/// nearest step and [onChanged] gets the step in MB.
class StorageLimitSlider extends StatelessWidget {
  const StorageLimitSlider({
    super.key,
    required this.valueMb,
    required this.onChanged,
  });

  final int valueMb;
  final ValueChanged<int> onChanged;

  /// Index of the step nearest to [mb].
  static int indexOf(int mb) {
    final List<int> steps = AppSettings.storageLimitStepsMb;
    int best = 0;
    for (int i = 1; i < steps.length; i++) {
      if ((steps[i] - mb).abs() < (steps[best] - mb).abs()) {
        best = i;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final List<int> steps = AppSettings.storageLimitStepsMb;
    return Slider(
      min: 0,
      max: (steps.length - 1).toDouble(),
      divisions: steps.length - 1,
      value: indexOf(valueMb).toDouble(),
      label: AppSettings.storageLimitLabel(valueMb),
      onChanged: (double value) => onChanged(steps[value.round()]),
    );
  }
}

/// The color of a bar that is [ratio] full: calm below half, then as the
/// store warns (from 50 %) and compresses harder (from 75 %).
Color storageFillColor(ZenColors zen, double ratio) {
  if (ratio >= 0.75) {
    return zen.danger;
  }
  return ratio >= 0.5 ? zen.warning : zen.accent;
}

/// Ustawienia → Dane i pamięć: how much room Zen takes now (a bar against
/// the limit) and by what, with the limit for other people's posts. Over
/// the limit (or when friends' photos and videos had to go for it) a
/// warning on top offers to raise the limit.
class StorageUsageSection extends ConsumerWidget {
  const StorageUsageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    final AsyncValue<StorageBreakdown?> measured = ref.watch(
      storageBreakdownProvider,
    );
    final StorageBreakdown? usage = measured.value;
    final StorageLimitWarning? warning = ref.watch(storageLimitWarningProvider);
    final Widget body;
    if (usage == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          measured.isLoading
              ? t('Liczę zajęte miejsce…')
              : t('Nie da się teraz zmierzyć zajętego miejsca.'),
          key: const Key('storage-usage-unknown'),
          style: TextStyle(color: zen.textSecondary, height: 1.35),
        ),
      );
    } else {
      final int limitBytes = settings.inboxLimitMb * 1024 * 1024;
      final double ratio = settings.inboxUnlimited || limitBytes == 0
          ? 0
          : usage.totalBytes / limitBytes;
      // What the last round told, while the limit is still the one it saw;
      // what is measured here now decides whether Zen is still over it.
      final StorageLimitWarning? told =
          warning != null && warning.limitMb == settings.inboxLimitMb
          ? warning
          : null;
      final bool over = !settings.inboxUnlimited && ratio > 1;
      final bool trimmed = told != null && told.deletedFiles > 0;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!settings.inboxUnlimited && (over || trimmed))
            _LimitWarning(
              warning: over
                  ? (told != null && told.stillOver ? told : null)
                  : StorageLimitWarning(
                      limitMb: told!.limitMb,
                      deletedFiles: told.deletedFiles,
                      deletedBytes: told.deletedBytes,
                    ),
              limitMb: settings.inboxLimitMb,
              raiseToMb: raisedStorageLimitMb(
                usage.totalBytes,
                currentMb: settings.inboxLimitMb,
              ),
              onRaise: controller.setInboxLimitMb,
            ),
          Text(
            settings.inboxUnlimited
                ? t('Zen zajmuje {used}', {
                    'used': formatStorageSize(usage.totalBytes),
                  })
                : t('Zen zajmuje {used} z {limit}', {
                    'used': formatStorageSize(usage.totalBytes),
                    'limit': settings.inboxLimitLabel,
                  }),
            key: const Key('storage-usage-total'),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (!settings.inboxUnlimited) ...<Widget>[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                key: const Key('storage-usage-bar'),
                value: ratio.clamp(0, 1).toDouble(),
                minHeight: 10,
                color: storageFillColor(zen, ratio),
                backgroundColor: zen.surfaceSunk,
              ),
            ),
          ],
          const SizedBox(height: 10),
          _UsageRow(
            key: const Key('storage-usage-feed'),
            label: t('Posty znajomych: zdjęcia i filmy'),
            bytes: usage.feedBytes,
          ),
          _UsageRow(
            key: const Key('storage-usage-media'),
            label: t('Zdjęcia, filmy i nagrania z rozmów'),
            bytes: usage.mediaBytes,
          ),
          _UsageRow(
            key: const Key('storage-usage-backups'),
            label: t('Kopie i eksporty'),
            bytes: usage.backupsBytes,
          ),
          _UsageRow(
            key: const Key('storage-usage-other'),
            label: t('Wiadomości i pozostałe dane'),
            bytes: usage.otherBytes,
          ),
        ],
      );
    }
    final bool ownLimit = settings.feedLimitMb > 0;
    return Column(
      key: const Key('storage-usage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        body,
        SwitchListTile.adaptive(
          key: const Key('storage-feed-limit-switch'),
          value: ownLimit,
          contentPadding: EdgeInsets.zero,
          title: Text(t('Osobny limit dla postów znajomych')),
          subtitle: Text(
            ownLimit
                ? t('Najstarsze zdjęcia i filmy znikają, gdy przekroczą limit.')
                : t(
                    'Bez osobnego limitu zdjęcia i filmy znajomych znikają '
                    'dopiero, gdy Zen przekroczy cały limit.',
                  ),
            style: TextStyle(color: zen.textSecondary, height: 1.35),
          ),
          onChanged: (bool on) => controller.setFeedLimitMb(
            on ? (settings.inboxUnlimited ? 1024 : settings.inboxLimitMb) : 0,
          ),
        ),
        if (ownLimit)
          Column(
            key: const Key('storage-feed-limit-editor'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                t('Limit postów znajomych: {limit}', {
                  'limit': AppSettings.storageLimitLabel(settings.feedLimitMb),
                }),
                key: const Key('storage-feed-limit-label'),
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              StorageLimitSlider(
                key: const Key('storage-feed-limit-slider'),
                valueMb: settings.feedLimitMb,
                onChanged: controller.setFeedLimitMb,
              ),
            ],
          ),
        const SizedBox(height: 4),
        Text(
          t(
            'Gdy Zen przekroczy limit, najstarsze zdjęcia i filmy z postów '
            'znajomych znikają same, aż Zen się w nim zmieści. Wiadomości, '
            'rozmowy, Twoje posty, kopie i eksporty nigdy nie są usuwane '
            'same. Rozmów i wiadomości nie da się policzyć osobno, bo ich '
            'pliki są zaszyfrowane razem z resztą danych.',
          ),
          key: const Key('storage-usage-note'),
          style: TextStyle(color: zen.textSecondary, height: 1.35),
        ),
      ],
    );
  }
}

/// The warning on top of the usage: what the limit did (or that Zen is over
/// it) and a button that raises it to [raiseToMb] (none when no step is
/// above the limit).
class _LimitWarning extends StatelessWidget {
  const _LimitWarning({
    required this.warning,
    required this.limitMb,
    required this.raiseToMb,
    required this.onRaise,
  });

  final StorageLimitWarning? warning;
  final int limitMb;
  final int? raiseToMb;
  final ValueChanged<int> onRaise;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final int? raiseTo = raiseToMb;
    return Padding(
      key: const Key('storage-limit-warning'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ZenInfo(
            icon: Icons.storage_outlined,
            tone: zen.warning,
            title: storageLimitWarningTitle(warning, limitMb),
            text: storageLimitWarningBody(warning, limitMb),
          ),
          if (raiseTo != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const Key('storage-limit-raise'),
                onPressed: () => onRaise(raiseTo),
                child: Text(
                  t('Zwiększ limit do {limit}', {
                    'limit': AppSettings.storageLimitLabel(raiseTo),
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({super.key, required this.label, required this.bytes});

  final String label;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: TextStyle(color: zen.textPrimary)),
          ),
          Text(
            formatStorageSize(bytes),
            style: TextStyle(
              color: zen.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
