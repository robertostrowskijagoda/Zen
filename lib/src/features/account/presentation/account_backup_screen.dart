import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/account_backup_io.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/presentation/account_copy_common.dart';
import 'package:zen/src/features/account/presentation/account_restore_info.dart';
import 'package:zen/src/features/account/presentation/key_restore_screen.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// Argon2id cost of new backup files (lighter in tests).
final Provider<PasswordCost> accountBackupCostProvider = Provider<PasswordCost>(
  (Ref ref) => kRecoveryPasswordCost,
);

/// The costs a backup file may ask for when it is read.
final Provider<List<PasswordCost>> accountBackupAcceptedCostsProvider =
    Provider<List<PasswordCost>>((Ref ref) => kAcceptedRecoveryCosts);

/// "Kopia zapasowa konta": the parts to keep, the size, a password, and
/// the file (in parts when it is very large).
class AccountBackupScreen extends ConsumerStatefulWidget {
  const AccountBackupScreen({super.key});

  /// Opens after the person confirms who they are.
  static Future<void> open(BuildContext context) async {
    if (!await confirmSensitiveAccess(
          context,
          reason: t('Kopia konta zawiera wszystko. Potwierdź, że to Ty.'),
        ) ||
        !context.mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AccountBackupScreen(),
      ),
    );
  }

  @override
  ConsumerState<AccountBackupScreen> createState() =>
      _AccountBackupScreenState();
}

class _AccountBackupScreenState extends ConsumerState<AccountBackupScreen> {
  final Set<AccountScope> _scope = <AccountScope>{...kAllAccountScopes};
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  int? _estimate;
  int _measuring = 0;
  bool _busy = false;
  int _done = 0;
  int _total = 0;
  String? _message;
  List<String>? _written;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _measure() async {
    final int run = ++_measuring;
    setState(() => _estimate = null);
    final AccountArchiveCollector? collect = ref.read(
      accountArchiveCollectorProvider,
    );
    if (collect == null) {
      return;
    }
    try {
      final AccountArchiveBuild build = await collect(
        _scope,
        measureOnly: true,
      );
      if (mounted && run == _measuring) {
        setState(() => _estimate = build.archive.totalBytes);
      }
    } on Object catch (error) {
      logZenWarning('Measuring the account copy failed: $error');
    }
  }

  void _toggle(AccountScope s, bool on) {
    setState(() {
      if (on) {
        _scope.add(s);
      } else {
        _scope.remove(s);
      }
    });
    unawaited(_measure());
  }

  Future<void> _create() async {
    final String password = _password.text;
    if (password.length < kMinAccountPasswordLength) {
      setState(
        () => _message = tn(
          kMinAccountPasswordLength,
          one: 'Hasło musi mieć co najmniej {n} znak.',
          few: 'Hasło musi mieć co najmniej {n} znaki.',
          many: 'Hasło musi mieć co najmniej {n} znaków.',
        ),
      );
      return;
    }
    if (password != _repeat.text) {
      setState(() => _message = t('Hasła się różnią.'));
      return;
    }
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    final AccountArchiveCollector? collect = ref.read(
      accountArchiveCollectorProvider,
    );
    if (node == null || collect == null) {
      setState(() => _message = t('Konto nie jest jeszcze gotowe.'));
      return;
    }
    await node.start();
    if (!mounted) {
      return;
    }
    if (!await unlockAccountKey(
      context,
      node,
      t('Kopia całego konta (plik)'),
      wrong: () => setState(() => _message = t('Złe hasło konta.')),
    )) {
      return;
    }
    final String? first = await ref
        .read(accountBackupPlacesProvider)
        .target(accountBackupFileName(DateTime.now()));
    if (first == null || !mounted) {
      node.identity.lock();
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _done = 0;
      _total = 0;
    });
    try {
      final AccountArchiveBuild build = await collect(<AccountScope>{
        ..._scope,
        AccountScope.keys,
      });
      final List<String> paths = await writeAccountBackup(
        build: build,
        password: password,
        first: first,
        cost: ref.read(accountBackupCostProvider),
        progress: (int done, int total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      _written = paths;
    } on Object catch (error, stackTrace) {
      logZenError('Writing the account backup failed', error, stackTrace);
      _message = t('Nie udało się zapisać kopii. Sprawdź miejsce na dysku.');
    } finally {
      node.identity.lock();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<String>? written = _written;
    return Scaffold(
      key: const Key('account-backup-screen'),
      appBar: AppBar(title: Text(t('Kopia całego konta (plik)'))),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            Text(
              t(
                'Jeden plik z całym kontem albo jego częścią, zaszyfrowany '
                'Twoim hasłem. Przywrócisz go na tym lub nowym urządzeniu '
                'przez „Mam kopię”.',
              ),
              style: TextStyle(color: zen.textSecondary, height: 1.4),
            ),
            ZenSection(t('Co ma być w kopii')),
            ZenCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: <Widget>[
                  for (final AccountScope s in AccountScope.values)
                    CheckboxListTile(
                      key: Key('account-backup-scope-${s.name}'),
                      dense: true,
                      value: s == AccountScope.keys || _scope.contains(s),
                      onChanged: s == AccountScope.keys || _busy
                          ? null
                          : (bool? on) => _toggle(s, on ?? false),
                      title: Text(accountScopeLabel(s)),
                      subtitle: s == AccountScope.keys
                          ? Text(t('zawsze'))
                          : null,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _estimate == null
                  ? t('Liczę rozmiar…')
                  : t('Około {size}', <String, Object?>{
                      'size': accountCopySize(_estimate!),
                    }),
              key: const Key('account-backup-size'),
              style: TextStyle(color: zen.textMuted, fontSize: 13),
            ),
            ZenSection(t('Hasło kopii')),
            TextField(
              key: const Key('account-backup-password'),
              controller: _password,
              obscureText: true,
              enableIMEPersonalizedLearning: false,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: t('Hasło'),
                prefixIcon: const Icon(Icons.lock_outline_rounded),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('account-backup-repeat'),
              controller: _repeat,
              obscureText: true,
              enableIMEPersonalizedLearning: false,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: t('Powtórz hasło'),
                prefixIcon: const Icon(Icons.lock_outline_rounded),
              ),
            ),
            const SizedBox(height: 8),
            ZenInfo(
              icon: Icons.warning_amber_rounded,
              tone: zen.warning,
              text: t(
                'Bez tego hasła nikt nie otworzy kopii — także Ty. Kto ma '
                'plik i hasło, ma konto.',
              ),
            ),
            const SizedBox(height: 12),
            if (_busy)
              AccountCopyProgress(
                done: _done,
                total: _total,
                label: t('Zapisuję kopię…'),
              )
            else
              FilledButton.icon(
                key: const Key('account-backup-create'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: () => unawaited(_create()),
                icon: const Icon(Icons.save_alt_rounded),
                label: Text(t('Utwórz kopię całego konta')),
              ),
            if (_message != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _message!,
                key: const Key('account-backup-message'),
                style: TextStyle(color: zen.danger),
              ),
            ],
            if (written != null) ...<Widget>[
              const SizedBox(height: 12),
              ZenInfo(
                key: const Key('account-backup-done'),
                icon: Icons.check_circle_outline_rounded,
                tone: zen.success,
                title: t('Kopia gotowa'),
                text: written.length == 1
                    ? t(
                        'Zapisana w: {path}. Przenieś ją w bezpieczne miejsce '
                        '(komputer, pendrive) — usunięcie aplikacji może '
                        'usunąć jej folder.',
                        <String, Object?>{'path': written.single},
                      )
                    : t(
                        'Zapisana w częściach: {paths}. Trzymaj je razem — '
                        'do przywrócenia potrzebne są wszystkie.',
                        <String, Object?>{'paths': written.join(', ')},
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Mam kopię": the backup file of the account, or the key alone (a
/// paper key or a key file).
class AccountBackupRestoreScreen extends ConsumerStatefulWidget {
  const AccountBackupRestoreScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const AccountBackupRestoreScreen(),
    ),
  );

  @override
  ConsumerState<AccountBackupRestoreScreen> createState() =>
      _AccountBackupRestoreScreenState();
}

class _AccountBackupRestoreScreenState
    extends ConsumerState<AccountBackupRestoreScreen> {
  final TextEditingController _password = TextEditingController();
  List<String>? _parts;
  bool _busy = false;
  String? _message;
  bool _good = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final String? path = await ref.read(accountBackupPlacesProvider).pick();
    if (path == null) {
      return;
    }
    final List<String> parts = await accountBackupParts(path);
    if (!mounted) {
      return;
    }
    setState(() {
      _parts = parts;
      _message = null;
    });
  }

  Future<void> _restore() async {
    final List<String>? parts = _parts;
    final AccountArchiveImporter? importer = ref.read(
      accountArchiveImporterProvider,
    );
    if (parts == null) {
      return;
    }
    if (importer == null) {
      setState(() => _message = t('Konto nie jest jeszcze gotowe.'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final AccountBackupRestore result = await restoreAccountBackup(
        paths: parts,
        password: _password.text,
        importer: importer,
        acceptedCosts: ref.read(accountBackupAcceptedCostsProvider),
      );
      final AccountBackupError? error = result.error;
      final String? refused = accountImportRefusal(result.outcome);
      if (!mounted) {
        return;
      }
      setState(() {
        _good = error == null && refused == null;
        _message = error != null
            ? accountBackupErrorText(error)
            : refused ??
                  t(
                    'Kopia przyjęta. Aplikacja uruchamia się ponownie i '
                    'pokaże, co wróciło.',
                  );
      });
    } on Object catch (error, stackTrace) {
      logZenError('Restoring the account backup failed', error, stackTrace);
      if (mounted) {
        setState(() {
          _good = false;
          _message = t('Nie udało się przywrócić kopii.');
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<String>? parts = _parts;
    return Scaffold(
      key: const Key('account-backup-restore-screen'),
      appBar: AppBar(title: Text(t('Mam kopię'))),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenSection(t('Kopia całego konta (plik)'), top: 4),
            ZenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t(
                      'Plik .zenbackup z „Utwórz kopię całego konta”. Wraca to, '
                      'co w nim jest; na tym samym koncie dane się łączą.',
                    ),
                    style: TextStyle(color: zen.textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    key: const Key('account-restore-pick'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _busy ? null : () => unawaited(_pick()),
                    icon: const Icon(Icons.file_open_outlined),
                    label: Text(t('Wybierz plik')),
                  ),
                  if (parts != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      parts.length == 1
                          ? parts.single
                          : t('{n} części: {paths}', <String, Object?>{
                              'n': parts.length,
                              'paths': parts.join(', '),
                            }),
                      key: const Key('account-restore-parts'),
                      style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('account-restore-password'),
                      controller: _password,
                      obscureText: true,
                      enableIMEPersonalizedLearning: false,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: t('Hasło kopii'),
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                      ),
                      onSubmitted: (_) => unawaited(_restore()),
                    ),
                    const SizedBox(height: 10),
                    if (_busy)
                      AccountCopyProgress(
                        done: 0,
                        total: 0,
                        label: t('Czytam kopię…'),
                      )
                    else
                      FilledButton.icon(
                        key: const Key('account-restore-run'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: () => unawaited(_restore()),
                        icon: const Icon(Icons.restore_rounded),
                        label: Text(t('Przywróć')),
                      ),
                  ],
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      _message!,
                      key: const Key('account-restore-message'),
                      style: TextStyle(
                        color: _good ? zen.success : zen.danger,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ZenSection(t('Sam klucz')),
            ZenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t(
                      'Kartka z kluczem albo plik klucza: wraca konto, a '
                      'reszta z kopii u znajomych, jeśli ją masz.',
                    ),
                    style: TextStyle(color: zen.textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    key: const Key('account-restore-key'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => unawaited(KeyRestoreScreen.open(context)),
                    icon: const Icon(Icons.history_edu_rounded),
                    label: Text(t('Kartka lub plik klucza')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('account-restore-info-open'),
              onPressed: () =>
                  unawaited(AccountRestoreInfoScreen.open(context)),
              icon: const Icon(Icons.help_outline_rounded),
              label: Text(t('Co da się odzyskać i jak')),
            ),
          ],
        ),
      ),
    );
  }
}
