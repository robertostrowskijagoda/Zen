import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/account/presentation/account_copy_common.dart';
import 'package:zen/src/features/account/presentation/account_copy_screen.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/account/presentation/account_restore_info.dart';

/// A way back to an existing account picked on the first start.
enum AccountStartAction { backup, device, circle }

/// The way back picked on the first start, opened once the app runs.
final Provider<ValueNotifier<AccountStartAction?>> accountStartActionProvider =
    Provider<ValueNotifier<AccountStartAction?>>((Ref ref) {
      final ValueNotifier<AccountStartAction?> action =
          ValueNotifier<AccountStartAction?>(null);
      ref.onDispose(action.dispose);
      return action;
    });

/// Over the app after it started again on a copy of the account: how far
/// taking the rest in is, then what came back. Also opens the way back
/// picked on the first start.
class AccountImportLayer extends ConsumerStatefulWidget {
  const AccountImportLayer({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AccountImportLayer> createState() => _AccountImportLayerState();
}

class _AccountImportLayerState extends ConsumerState<AccountImportLayer> {
  late final ValueNotifier<AccountStartAction?> _start;

  @override
  void initState() {
    super.initState();
    _start = ref.read(accountStartActionProvider)..addListener(_open);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _start.removeListener(_open);
    super.dispose();
  }

  /// The way back chosen on the first start, once the app runs (the
  /// network is up only then).
  void _open() {
    final AccountStartAction? action = _start.value;
    if (action == null || !mounted) {
      return;
    }
    _start.value = null;
    unawaited(switch (action) {
      AccountStartAction.backup => AccountBackupRestoreScreen.open(context),
      AccountStartAction.device => AccountCopyReceiveScreen.open(context),
      AccountStartAction.circle => AccountRecoveryScreen.open(context),
    });
  }

  @override
  Widget build(BuildContext context) {
    final AccountImportController c = ref.watch(
      accountImportControllerProvider,
    );
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? child) {
        final AccountImportSummary? summary = c.summary;
        final bool show = c.running || summary != null || c.failed;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            child!,
            if (show)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: SafeArea(child: _Card(controller: c)),
              ),
          ],
        );
      },
      child: widget.child,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.controller});

  final AccountImportController controller;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AccountImportSummary? summary = controller.summary;
    return Material(
      key: const Key('account-import-layer'),
      color: Colors.transparent,
      child: ZenCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (controller.running)
              AccountCopyProgress(
                done: controller.done,
                total: controller.total,
                bytes: false,
                label: t('Przywracam dane konta…'),
              )
            else ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      controller.failed
                          ? t('Części danych nie udało się przywrócić.')
                          : t('Konto przywrócone'),
                      style: TextStyle(
                        color: controller.failed ? zen.danger : zen.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('account-import-close'),
                    tooltip: t('Zamknij'),
                    onPressed: controller.dismiss,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              if (summary != null) AccountImportSummaryView(summary),
            ],
          ],
        ),
      ),
    );
  }
}

/// The ways to keep and bring back the whole account, for "Konto i
/// odzyskiwanie" and the first start: a backup file, another device, the
/// recovery circle, and what each brings back.
class AccountCopyActions extends StatelessWidget {
  const AccountCopyActions({
    this.circle,
    this.backup = true,
    this.onRestore,
    super.key,
  });

  /// "Odzyskaj z pomocą kręgu" (hidden when null).
  final VoidCallback? circle;

  /// Instead of opening a way back here (the first start: it opens once
  /// the app runs).
  final void Function(AccountStartAction action)? onRestore;

  /// Also the actions of an account in use: making a backup, sending the
  /// account to another device.
  final bool backup;

  @override
  Widget build(BuildContext context) {
    Widget button(
      String key,
      IconData icon,
      String label,
      VoidCallback onPressed, {
      bool filled = false,
    }) {
      final ButtonStyle style = filled
          ? FilledButton.styleFrom(minimumSize: const Size.fromHeight(48))
          : OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48));
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: filled
            ? FilledButton.icon(
                key: Key(key),
                style: style,
                onPressed: onPressed,
                icon: Icon(icon),
                label: Text(label),
              )
            : OutlinedButton.icon(
                key: Key(key),
                style: style,
                onPressed: onPressed,
                icon: Icon(icon),
                label: Text(label),
              ),
      );
    }

    return ZenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (backup) ...<Widget>[
            button(
              'account-backup-open',
              Icons.save_alt_rounded,
              t('Utwórz kopię całego konta'),
              () => unawaited(AccountBackupScreen.open(context)),
              filled: true,
            ),
            button(
              'account-copy-send-open',
              Icons.send_to_mobile_rounded,
              t('Dodaj drugie urządzenie lub przenieś konto'),
              () => unawaited(AccountCopySendScreen.open(context)),
            ),
          ],
          button(
            'account-restore-backup-open',
            Icons.restore_page_outlined,
            t('Mam kopię'),
            () => onRestore != null
                ? onRestore!(AccountStartAction.backup)
                : unawaited(AccountBackupRestoreScreen.open(context)),
          ),
          button(
            'account-copy-receive-open',
            Icons.devices_rounded,
            t('Odzyskaj z innego urządzenia'),
            () => onRestore != null
                ? onRestore!(AccountStartAction.device)
                : unawaited(AccountCopyReceiveScreen.open(context)),
          ),
          if (circle != null)
            button(
              'account-restore-circle-open',
              Icons.groups_2_outlined,
              t('Odzyskaj z pomocą kręgu'),
              circle!,
            ),
          const SizedBox(height: 4),
          TextButton.icon(
            key: const Key('account-restore-info-link'),
            onPressed: () => unawaited(AccountRestoreInfoScreen.open(context)),
            icon: const Icon(Icons.help_outline_rounded),
            label: Text(t('Co da się odzyskać i jak')),
          ),
        ],
      ),
    );
  }
}
