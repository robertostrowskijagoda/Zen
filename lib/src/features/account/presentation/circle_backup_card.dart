import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/account/recovery_providers.dart';

/// [bytes] as people read it (KB / MB).
String circleBackupSize(int bytes) {
  if (bytes < 1024 * 1024) {
    return '${ZenFormat.number((bytes / 1024).ceil())} KB';
  }
  return '${ZenFormat.number(bytes / (1024 * 1024), decimals: 1)} MB';
}

/// "Kopia u kręgu" in "Konto i odzyskiwanie": when the circle last
/// confirmed a copy and how big it is, whether conversation text goes in,
/// the restore after a recovery, and the copies this device keeps for
/// others.
class CircleBackupCard extends ConsumerWidget {
  const CircleBackupCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CircleBackupService? service = ref.watch(circleBackupServiceProvider);
    if (service == null) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        service.status,
        service.restore,
      ]),
      builder: (BuildContext context, Widget? child) {
        final CircleBackupStatus status = service.status.value;
        final CircleBackupRestore restore = service.restore.value;
        final int? lastAt = status.lastAt;
        return ZenCard(
          key: const Key('circle-backup-card'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.cloud_sync_outlined, color: zen.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t('Kopia u kręgu'),
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                lastAt == null
                    ? t('Kopia u kręgu: jeszcze żadna')
                    : t('Kopia u kręgu: ostatnio {date}, {size}', {
                        'date': ZenFormat.dateTime(
                          DateTime.fromMillisecondsSinceEpoch(lastAt),
                        ),
                        'size': circleBackupSize(status.bytes),
                      }),
                key: const Key('circle-backup-status'),
                style: TextStyle(color: zen.textSecondary, height: 1.4),
              ),
              if (status.droppedMessages > 0) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  t('Najstarsze wiadomości nie zmieściły się w kopii.'),
                  style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                ),
              ],
              const SizedBox(height: 8),
              ZenInfo(
                icon: Icons.lock_outline_rounded,
                text: t(
                  'Osoby z kręgu odzyskiwania przechowują zaszyfrowaną kopię: '
                  'profil, znajomych, grupy, ustawienia, piramidę i portfel, '
                  'a także teksty rozmów. Nie mogą jej odczytać. Po '
                  'odzyskaniu konta Zen sam ją pobierze.',
                ),
              ),
              SwitchListTile(
                key: const Key('circle-backup-chats'),
                contentPadding: EdgeInsets.zero,
                value: status.includeChats,
                onChanged: (bool value) =>
                    unawaited(service.setIncludeChats(value)),
                title: Text(t('Teksty rozmów w kopii')),
                subtitle: Text(
                  t(
                    'Bez zdjęć, filmów i plików. Najstarsze wiadomości '
                    'wypadają, gdy kopia przekroczy 10 MB.',
                  ),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const Key('circle-backup-now'),
                  onPressed: () => unawaited(service.refresh(force: true)),
                  icon: const Icon(Icons.sync_rounded),
                  label: Text(t('Zrób kopię teraz')),
                ),
              ),
              if (restore.phase != CircleBackupRestorePhase.idle)
                _RestoreProgress(restore: restore),
              ..._held(context, service),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _held(BuildContext context, CircleBackupService service) {
    final ZenColors zen = ZenColors.of(context);
    final Map<String, int> kept = service.holder.kept;
    if (kept.isEmpty) {
      return const <Widget>[];
    }
    final int total = kept.values.fold(0, (int a, int b) => a + b);
    return <Widget>[
      const SizedBox(height: 10),
      Text(
        t('Przechowujesz kopie innych: {n}, razem {size}', {
          'n': kept.length,
          'size': circleBackupSize(total),
        }),
        style: TextStyle(color: zen.textSecondary),
      ),
      for (final MapEntry<String, int> e in kept.entries)
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t('Odcisk konta: {fingerprint}', {
                  'fingerprint': accountFingerprint(e.key),
                }),
                style: TextStyle(color: zen.textMuted, fontSize: 12.5),
              ),
            ),
            TextButton(
              onPressed: () => unawaited(service.holder.drop(e.key)),
              child: Text(t('Usuń kopię')),
            ),
          ],
        ),
    ];
  }
}

class _RestoreProgress extends StatelessWidget {
  const _RestoreProgress({required this.restore});

  final CircleBackupRestore restore;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String label = switch (restore.phase) {
      CircleBackupRestorePhase.searching => t('Szukam kopii u kręgu…'),
      CircleBackupRestorePhase.downloading => t(
        'Pobieram kopię: {done} z {total}',
        {'done': restore.done, 'total': restore.total},
      ),
      CircleBackupRestorePhase.applying => t(
        'Przywracam dane: {done} z {total}',
        {'done': restore.done, 'total': restore.total},
      ),
      CircleBackupRestorePhase.done => t('Dane z kopii przywrócone.'),
      CircleBackupRestorePhase.failed => t('Nie znaleziono kopii u kręgu.'),
      CircleBackupRestorePhase.idle => '',
    };
    final bool working =
        restore.phase == CircleBackupRestorePhase.searching ||
        restore.phase == CircleBackupRestorePhase.downloading ||
        restore.phase == CircleBackupRestorePhase.applying;
    return Padding(
      key: const Key('circle-backup-restore'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(label, style: TextStyle(color: zen.textPrimary)),
          if (working) ...<Widget>[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: restore.total > 0 ? restore.done / restore.total : null,
            ),
          ],
        ],
      ),
    );
  }
}
