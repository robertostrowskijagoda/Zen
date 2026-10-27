import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/account_backup_io.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
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
  AccountBackupSaved? _saved;
  bool _obscure = true;

  /// Where the backup goes: [_default] until the person chooses another.
  AccountBackupFolder? _default;
  AccountBackupFolder? _chosen;
  bool _choosing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
    unawaited(_loadDefaultFolder());
  }

  Future<void> _loadDefaultFolder() async {
    try {
      final AccountBackupFolder folder = await ref
          .read(accountBackupPlacesProvider)
          .defaultFolder();
      if (mounted) {
        setState(() => _default = folder);
      }
    } on Object catch (error) {
      logZenWarning('Finding the default backup folder failed: $error');
    }
  }

  /// "Wybierz folder": a cancelled chooser keeps what was there.
  Future<void> _chooseFolder() async {
    setState(() => _choosing = true);
    try {
      final AccountBackupFolder? folder = await ref
          .read(accountBackupPlacesProvider)
          .chooseFolder();
      if (folder != null && mounted) {
        setState(() => _chosen = folder);
      }
    } on Object catch (error, stackTrace) {
      logZenError('Choosing the backup folder failed', error, stackTrace);
      if (mounted) {
        setState(() => _message = t('Nie udało się wybrać folderu.'));
      }
    } finally {
      if (mounted) {
        setState(() => _choosing = false);
      }
    }
  }

  Future<void> _openFolder(AccountBackupSaved saved) async {
    final bool opened = await ref.read(accountBackupPlacesProvider).open(saved);
    if (!opened && mounted) {
      setState(() => _message = t('Nie udało się otworzyć folderu.'));
    }
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
    final AccountBackupPlaces places = ref.read(accountBackupPlacesProvider);
    final AccountBackupFolder folder;
    try {
      folder = _chosen ?? _default ?? await places.defaultFolder();
    } on Object catch (error, stackTrace) {
      logZenError('Finding the backup folder failed', error, stackTrace);
      node.identity.lock();
      if (mounted) {
        setState(() => _message = t('Nie udało się znaleźć folderu na kopię.'));
      }
      return;
    }
    if (!mounted) {
      node.identity.lock();
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _saved = null;
      _done = 0;
      _total = 0;
    });
    try {
      final AccountArchiveBuild build = await collect(<AccountScope>{
        ..._scope,
        AccountScope.keys,
      });
      _saved = await saveAccountBackup(
        places: places,
        folder: folder,
        name: accountBackupFileName(DateTime.now()),
        build: build,
        password: password,
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

  /// "Pokaż" / "Ukryj" for the password fields.
  Widget _visibilityToggle() => IconButton(
    tooltip: _obscure ? t('Pokaż') : t('Ukryj'),
    onPressed: () => setState(() => _obscure = !_obscure),
    icon: Icon(
      _obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AccountBackupSaved? saved = _saved;
    final AccountBackupFolder? folder = _chosen ?? _default;
    return Scaffold(
      key: const Key('account-backup-screen'),
      appBar: ZenSectionBar(title: t('Kopia całego konta (plik)')),
      body: SafeArea(
        top: false,
        child: SelectionArea(
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
              ZenSection(t('Gdzie zapisać')),
              ZenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      folder == null
                          ? t('Szukam folderu…')
                          : _chosen == null
                          ? t('{folder} (domyślnie)', <String, Object?>{
                              'folder': folder.label,
                            })
                          : folder.label,
                      key: const Key('account-backup-folder'),
                      style: const TextStyle(height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      key: const Key('account-backup-folder-choose'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _busy || _choosing
                          ? null
                          : () => unawaited(_chooseFolder()),
                      icon: const Icon(Icons.folder_open_rounded),
                      label: Text(t('Wybierz folder')),
                    ),
                    if (_chosen != null)
                      TextButton(
                        key: const Key('account-backup-folder-default'),
                        onPressed: _busy
                            ? null
                            : () => setState(() => _chosen = null),
                        child: Text(t('Użyj domyślnego folderu')),
                      ),
                  ],
                ),
              ),
              ZenSection(t('Hasło kopii')),
              TextField(
                key: const Key('account-backup-password'),
                controller: _password,
                obscureText: _obscure,
                enableIMEPersonalizedLearning: false,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: t('Hasło'),
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: _visibilityToggle(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('account-backup-repeat'),
                controller: _repeat,
                obscureText: _obscure,
                enableIMEPersonalizedLearning: false,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: t('Powtórz hasło'),
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: _visibilityToggle(),
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
                _BackupMessage(
                  _message!,
                  key: const Key('account-backup-message'),
                  color: zen.danger,
                ),
              ],
              if (saved != null) ...<Widget>[
                const SizedBox(height: 12),
                ZenInfo(
                  key: const Key('account-backup-done'),
                  icon: Icons.check_circle_outline_rounded,
                  tone: zen.success,
                  title: t('Kopia gotowa'),
                  text: saved.shown.length == 1
                      ? t(
                          'Zapisana w: {path}. Skopiuj ją w bezpieczne miejsce '
                          '(komputer, pendrive).',
                          <String, Object?>{'path': saved.shown.single},
                        )
                      : t(
                          'Zapisana w częściach: {paths}. Trzymaj je razem — '
                          'do przywrócenia potrzebne są wszystkie.',
                          <String, Object?>{'paths': saved.shown.join(', ')},
                        ),
                ),
                if (saved.canOpen) ...<Widget>[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('account-backup-open-folder'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => unawaited(_openFolder(saved)),
                    icon: const Icon(Icons.folder_open_rounded),
                    label: Text(t('Otwórz folder')),
                  ),
                ],
              ],
            ],
          ),
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
  bool _obscure = true;

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

  /// "Pokaż" / "Ukryj" for the password fields.
  Widget _visibilityToggle() => IconButton(
    tooltip: _obscure ? t('Pokaż') : t('Ukryj'),
    onPressed: () => setState(() => _obscure = !_obscure),
    icon: Icon(
      _obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<String>? parts = _parts;
    return Scaffold(
      key: const Key('account-backup-restore-screen'),
      appBar: ZenSectionBar(title: t('Mam kopię')),
      body: SafeArea(
        top: false,
        child: SelectionArea(
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
                        obscureText: _obscure,
                        enableIMEPersonalizedLearning: false,
                        enabled: !_busy,
                        decoration: InputDecoration(
                          labelText: t('Hasło kopii'),
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: _visibilityToggle(),
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
                      _BackupMessage(
                        _message!,
                        key: const Key('account-restore-message'),
                        color: _good ? zen.success : zen.danger,
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
                      onPressed: () =>
                          unawaited(KeyRestoreScreen.open(context)),
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
      ),
    );
  }
}

/// A result line under a button: read out when it appears (a live region)
/// and scrolled into view, so an error is not left below the screen.
class _BackupMessage extends StatefulWidget {
  const _BackupMessage(this.text, {required this.color, super.key});

  final String text;
  final Color color;

  @override
  State<_BackupMessage> createState() => _BackupMessageState();
}

class _BackupMessageState extends State<_BackupMessage> {
  @override
  void initState() {
    super.initState();
    _show();
  }

  @override
  void didUpdateWidget(_BackupMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _show();
    }
  }

  void _show() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 150),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Text(
        widget.text,
        style: TextStyle(color: widget.color, height: 1.4),
      ),
    );
  }
}
