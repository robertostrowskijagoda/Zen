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
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// [bytes] as people read it (KB / MB).
String circleBackupSize(int bytes) {
  if (bytes < 1024 * 1024) {
    return '${ZenFormat.number((bytes / 1024).ceil())} KB';
  }
  return '${ZenFormat.number(bytes / (1024 * 1024), decimals: 1)} MB';
}

/// "Kopia u znajomych" in "Konto i odzyskiwanie": when friends (or the
/// circle) last confirmed a copy and how big it is, that nobody can keep
/// it while there is no friend, whether the passwords and conversation text
/// go in, the restore after a recovery, and the copies this device keeps
/// for others.
class CircleBackupCard extends ConsumerWidget {
  const CircleBackupCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CircleBackupService? service = ref.watch(circleBackupServiceProvider);
    if (service == null) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final bool passwords = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.passwordsInCircleBackup,
      ),
    );
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
                      t('Kopia u znajomych'),
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
                    ? t('Kopia u znajomych: jeszcze żadna')
                    : t('Kopia u znajomych: ostatnio {date}, {size}', {
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
              if (status.candidates == 0) ...<Widget>[
                const SizedBox(height: 8),
                ZenInfo(
                  key: const Key('circle-backup-nobody'),
                  icon: Icons.person_off_outlined,
                  tone: zen.warning,
                  text: t(
                    'Nikt nie może jej teraz przechować: nie masz jeszcze '
                    'znajomych.',
                  ),
                ),
              ],
              const SizedBox(height: 8),
              ZenInfo(
                key: const Key('circle-backup-contents'),
                icon: Icons.lock_outline_rounded,
                text: passwords
                    ? t(
                        'Zaszyfrowaną kopię przechowują wybrani znajomi (ci, '
                        'którzy są Twoimi skrzynkami, i bliscy znajomi) oraz '
                        'osoby z kręgu odzyskiwania, jeśli go masz: profil, '
                        'znajomych, grupy, ustawienia, piramidę, hasła, '
                        'notatki, a także teksty rozmów. Nie mogą jej '
                        'odczytać. Po odzyskaniu konta Zen sam ją pobierze.',
                      )
                    : t(
                        'Zaszyfrowaną kopię przechowują wybrani znajomi (ci, '
                        'którzy są Twoimi skrzynkami, i bliscy znajomi) oraz '
                        'osoby z kręgu odzyskiwania, jeśli go masz: profil, '
                        'znajomych, grupy, ustawienia, piramidę, notatki, a '
                        'także teksty rozmów — bez haseł. Nie mogą jej '
                        'odczytać. Po odzyskaniu konta Zen sam ją pobierze.',
                      ),
              ),
              SwitchListTile(
                key: const Key('circle-backup-passwords'),
                contentPadding: EdgeInsets.zero,
                value: passwords,
                onChanged: (bool value) => unawaited(
                  ref
                      .read(appSettingsControllerProvider.notifier)
                      .setPasswordsInCircleBackup(value),
                ),
                title: Text(t('Hasła w kopii u znajomych')),
                subtitle: Text(
                  passwords
                      ? t(
                          'Zamknięte. Otworzy je tylko ten, kto ma klucz '
                          'Twojego konta: kartkę z kluczem albo kawałki '
                          'klucza od bliskich znajomych i hasło konta. Dzięki '
                          'temu hasła wrócą po odzyskaniu konta z samego '
                          'klucza. Ustawienie jest takie samo na wszystkich '
                          'Twoich urządzeniach.',
                        )
                      : t(
                          'Wyłączone: nowa kopia bez haseł od razu zastępuje '
                          'tę u znajomych, którzy są w sieci (u pozostałych, '
                          'gdy się połączą). Po odzyskaniu konta z samego '
                          'klucza hasła nie wrócą; z innego urządzenia albo '
                          'z pliku kopii — tak. Ustawienie jest takie samo na '
                          'wszystkich Twoich urządzeniach.',
                        ),
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
              if (status.blocked > 0) ...<Widget>[
                ZenInfo(
                  key: const Key('circle-backup-blocked'),
                  icon: Icons.schedule_rounded,
                  tone: zen.warning,
                  text: tn(
                    status.blocked,
                    one:
                        '{n} osoba od kilku dni nie przyjmuje nowych kopii: '
                        'ma kopię Twojego konta z późniejszą datą. Sprawdź '
                        'datę i godzinę na swoich urządzeniach.',
                    few:
                        '{n} osoby od kilku dni nie przyjmują nowych kopii: '
                        'mają kopię Twojego konta z późniejszą datą. Sprawdź '
                        'datę i godzinę na swoich urządzeniach.',
                    many:
                        '{n} osób od kilku dni nie przyjmuje nowych kopii: '
                        'mają kopię Twojego konta z późniejszą datą. Sprawdź '
                        'datę i godzinę na swoich urządzeniach.',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (!service.restoring || restore.freshCopy)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('circle-backup-now'),
                    onPressed: () => unawaited(service.refresh(force: true)),
                    icon: const Icon(Icons.sync_rounded),
                    label: Text(t('Zrób kopię teraz')),
                  ),
                )
              else
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('circle-backup-fresh'),
                    onPressed: () =>
                        unawaited(_confirmFreshCopy(context, service)),
                    icon: const Icon(Icons.sync_problem_rounded),
                    label: Text(t('Zrób nową kopię z tego urządzenia')),
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

  /// While the old copy is still looked for after a recovery, this device
  /// makes none of its own unless the person says so here, knowing that
  /// it replaces the copy at the friends.
  Future<void> _confirmFreshCopy(
    BuildContext context,
    CircleBackupService service,
  ) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Zastąpić kopię u znajomych?')),
        content: Text(
          t(
            'Zen wciąż szuka kopii z Twojego poprzedniego urządzenia. Nowa '
            'kopia z tego telefonu zastąpi ją u znajomych, którzy ją mają: '
            'hasła, notatki i rozmowy, których tu nie ma, przepadną, gdy '
            'nikt nie odda starej kopii w ciągu 30 dni. Zen nadal będzie '
            'jej szukać.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('circle-backup-fresh-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Wiem, że stara kopia zostanie zastąpiona')),
          ),
        ],
      ),
    );
    if (yes == true) {
      await service.allowFreshCopy();
    }
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
      CircleBackupRestorePhase.searching => t('Szukam kopii u znajomych…'),
      CircleBackupRestorePhase.downloading => t(
        'Pobieram kopię: {done} z {total}',
        {'done': restore.done, 'total': restore.total},
      ),
      CircleBackupRestorePhase.applying => t(
        'Przywracam dane: {done} z {total}',
        {'done': restore.done, 'total': restore.total},
      ),
      CircleBackupRestorePhase.done => t('Dane z kopii przywrócone.'),
      CircleBackupRestorePhase.failed => t(
        'Nie znaleziono jeszcze kopii u znajomych. Zen szuka dalej, raz '
        'dziennie: osoby, które ją mają, mogą być długo poza siecią.',
      ),
      CircleBackupRestorePhase.newer => t(
        'Kopię zrobiła nowsza wersja Zen. Zaktualizuj aplikację: kopia '
        'czeka u znajomych i wróci po aktualizacji.',
      ),
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
