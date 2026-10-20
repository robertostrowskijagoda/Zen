import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/storage_health.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// One line of the storage limits list: what it limits and how much.
final class StorageLimitRow {
  const StorageLimitRow(this.label, this.limit);

  final String label;
  final String limit;
}

/// `12 MB` / `240 KB` for a size in bytes.
String formatStorageSize(int bytes) {
  const int mb = 1024 * 1024;
  if (bytes >= mb) {
    return t('{size} MB', <String, Object?>{'size': (bytes / mb).round()});
  }
  return t('{size} KB', <String, Object?>{'size': (bytes / 1024).round()});
}

/// The limits that apply per category of stored data (small, read-only).
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
    ];

/// Ustawienia → Limity przechowywania: the limits per category, and a note
/// when a stored file is close to its size limit.
class StorageLimitsSection extends ConsumerWidget {
  const StorageLimitsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
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
