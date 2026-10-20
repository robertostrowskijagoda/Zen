import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/storage_health.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/feed/feed_maintenance.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// One line of the storage limits list: what it limits and how much.
final class StorageLimitRow {
  const StorageLimitRow(this.label, this.limit);

  final String label;
  final String limit;
}

/// `2 GB` / `12 MB` / `240 KB` for a size in bytes.
String formatStorageSize(int bytes) {
  const int mb = 1024 * 1024;
  const int gb = 1024 * mb;
  if (bytes >= gb) {
    final double size = bytes / gb;
    return t('{size} GB', <String, Object?>{
      'size': size == size.roundToDouble()
          ? size.round()
          : size.toStringAsFixed(1),
    });
  }
  if (bytes >= mb) {
    return t('{size} MB', <String, Object?>{'size': (bytes / mb).round()});
  }
  return t('{size} KB', <String, Object?>{'size': (bytes / 1024).round()});
}

/// The limits that apply per category of stored data. The last three are
/// enforced by the app (`storage_retention.dart`): oldest first, and never
/// anything of your own.
List<StorageLimitRow> storageLimitRows(AppSettings settings) =>
    <StorageLimitRow>[
      StorageLimitRow(t('Zdarzenia w skrzynce'), settings.inboxLimitLabel),
      StorageLimitRow(
        t('Jeden plik danych (stan, wiadomości)'),
        formatStorageSize(BinaryCodec.defaultMaxPayloadBytes),
      ),
      StorageLimitRow(
        t('Załącznik w rozmowie'),
        formatStorageSize(kMaxIncomingAttachmentBytes),
      ),
      StorageLimitRow(t('Film w poście'), formatStorageSize(kMaxVideoBytes)),
      StorageLimitRow(
        t('Jedno zdjęcie lub film w dzienniku'),
        formatStorageSize(kMaxBlobBytes),
      ),
      StorageLimitRow(
        t('Posty znajomych'),
        t('{months} miesięcy', <String, Object?>{
          'months': kFriendEntriesKept.inDays ~/ 30,
        }),
      ),
      StorageLimitRow(
        t('Zdjęcia i filmy jednego znajomego'),
        formatStorageSize(kCircleMediaPerPersonBytes),
      ),
      StorageLimitRow(
        t('Zdjęcia i filmy pozostałych osób (pamięć podręczna)'),
        formatStorageSize(kMediaCacheBytes),
      ),
    ];

/// Ustawienia → Limity przechowywania: the limits per category, how full the
/// enforced ones are, what they deleted, and a note when a stored file is
/// close to its size limit.
class StorageLimitsSection extends ConsumerWidget {
  const StorageLimitsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final StorageReport? report = ref.watch(storageReportProvider).value;
    return ListenableBuilder(
      listenable: ZenStorageHealth.instance,
      builder: (BuildContext context, Widget? _) {
        final StorageFill worst = ZenStorageHealth.instance.worst;
        return Column(
          key: const Key('storage-limits'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final StorageLimitRow row in storageLimitRows(settings))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        row.label,
                        style: TextStyle(color: zen.textPrimary),
                      ),
                    ),
                    Text(
                      row.limit,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            if (report != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                t(
                  'Zdjęcia i filmy znajomych zajmują teraz: najwięcej '
                  '{most} u jednej osoby ({files} plików). Pozostałych osób: '
                  '{cache} ({cacheFiles} plików).',
                  <String, Object?>{
                    'most': formatStorageSize(report.usage.largestFriendBytes),
                    'files': report.usage.friendFiles,
                    'cache': formatStorageSize(report.usage.cacheBytes),
                    'cacheFiles': report.usage.cacheFiles,
                  },
                ),
                key: const Key('storage-limits-usage'),
                style: TextStyle(color: zen.textSecondary, height: 1.35),
              ),
              const SizedBox(height: 6),
              Text(
                report.cleaned.files == 0
                    ? t(
                        'Najstarsze zdjęcia i filmy znikają same, gdy limit '
                        'zostanie przekroczony; Twoje własne nigdy. Posty '
                        'znajomych starsze niż rok znikają z tablicy.',
                      )
                    : t(
                        'Od uruchomienia usunięto {files} plików ({size}): '
                        'najstarsze zdjęcia i filmy znajomych. Twoje własne '
                        'zostają zawsze.',
                        <String, Object?>{
                          'files': report.cleaned.files,
                          'size': formatStorageSize(report.cleaned.bytes),
                        },
                      ),
                key: const Key('storage-limits-cleaned'),
                style: TextStyle(color: zen.textSecondary, height: 1.35),
              ),
            ],
            if (worst != StorageFill.ok)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  worst == StorageFill.full
                      ? t(
                          'Jeden z plików z danymi przekroczył limit i nie '
                          'da się go już zapisać. Usuń stare zdjęcia lub '
                          'rozmowy.',
                        )
                      : t(
                          'Jeden z plików z danymi zbliża się do limitu '
                          'rozmiaru. Warto usunąć stare zdjęcia lub rozmowy.',
                        ),
                  key: const Key('storage-limits-warning'),
                  style: TextStyle(color: zen.textSecondary, height: 1.35),
                ),
              ),
          ],
        );
      },
    );
  }
}
