import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// "12 KB", "3,4 MB", "1,2 GB".
String accountCopySize(int bytes) {
  const int mb = 1024 * 1024;
  if (bytes < mb) {
    return '${ZenFormat.number((bytes / 1024).ceil())} KB';
  }
  if (bytes < 1024 * mb) {
    return '${ZenFormat.number(bytes / mb, decimals: 1)} MB';
  }
  return '${ZenFormat.number(bytes / (1024 * mb), decimals: 1)} GB';
}

/// The account key, unlocked (asking for the account password when it has
/// one). Null when it stays locked; [wrong] hears a wrong password.
Future<bool> unlockAccountKey(
  BuildContext context,
  LedgerNode node,
  String why, {
  void Function()? wrong,
}) async {
  if (node.identity.accountKey != null) {
    return true;
  }
  final String? password = await askAccountPassword(context, why);
  if (password == null) {
    return false;
  }
  final bool ok = await node.identity.unlock(password);
  if (!ok) {
    wrong?.call();
  }
  return ok;
}

/// Why a copy was not taken in, in words; null when it was.
String? accountImportRefusal(AccountImportOutcome? outcome) =>
    switch (outcome) {
      AccountImportOutcome.otherAccount => t(
        'To kopia innego konta, a na tym urządzeniu jest już konto z '
        'danymi. Dodaj ją jako osobne konto albo przywróć na nowym '
        'urządzeniu.',
      ),
      AccountImportOutcome.noKey => t(
        'W tej kopii nie ma klucza konta, a to urządzenie nie ma tego konta.',
      ),
      _ => null,
    };

/// Why a backup file did not open, in words.
String accountBackupErrorText(AccountBackupError error) => switch (error) {
  AccountBackupError.password => t('Złe hasło albo plik został zmieniony.'),
  AccountBackupError.format => t(
    'To nie jest kopia zapasowa Zen albo plik jest uszkodzony lub '
    'niekompletny (brakuje części?).',
  ),
};

/// The 6 digits both screens show, large.
class AccountCopyDigits extends StatelessWidget {
  const AccountCopyDigits(this.digits, {super.key});

  final String digits;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          zen.accent.withValues(alpha: 0.14),
          zen.surface,
        ),
        borderRadius: context.zenRadius(22),
        border: Border.all(color: zen.accent.withValues(alpha: 0.35)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SelectableText(
          digits,
          key: const Key('account-copy-digits'),
          textAlign: TextAlign.center,
          style: zen.display(
            color: zen.textPrimary,
            size: 38,
            weight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}

/// A bar with "{done} z {total}".
class AccountCopyProgress extends StatelessWidget {
  const AccountCopyProgress({
    required this.done,
    required this.total,
    required this.label,
    this.bytes = true,
    super.key,
  });

  final int done;
  final int total;
  final String label;

  /// Counts bytes (shown as sizes) rather than steps.
  final bool bytes;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final double? value = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
    String amount(int n) => bytes ? accountCopySize(n) : ZenFormat.number(n);
    return Column(
      key: const Key('account-copy-progress'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: TextStyle(color: zen.textPrimary, fontSize: 14)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: context.zenRadius(8),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 8,
            color: zen.accent,
            backgroundColor: zen.surfaceSunk,
          ),
        ),
        if (total > 0) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            t('{done} z {total}', <String, Object?>{
              'done': amount(done),
              'total': amount(total),
            }),
            style: TextStyle(color: zen.textMuted, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// What came back with a copy.
class AccountImportSummaryView extends StatelessWidget {
  const AccountImportSummaryView(this.summary, {super.key});

  final AccountImportSummary summary;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: TextStyle(color: zen.textSecondary)),
          ),
          Text(
            value,
            style: TextStyle(
              color: zen.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    final List<AccountScope> parts = <AccountScope>[
      for (final AccountScope s in AccountScope.values)
        if (summary.parts.contains(s)) s,
    ];
    return SelectionArea(
      child: Column(
        key: const Key('account-import-summary'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          line(t('Znajomi'), ZenFormat.number(summary.friends)),
          line(t('Grupy'), ZenFormat.number(summary.groups)),
          line(t('Rozmowy'), ZenFormat.number(summary.conversations)),
          line(t('Wiadomości'), ZenFormat.number(summary.messages)),
          line(
            t('Pliki'),
            '${ZenFormat.number(summary.files)} · '
            '${accountCopySize(summary.bytes)}',
          ),
          if (parts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              t('W kopii: {parts}', <String, Object?>{
                'parts': parts.map(accountScopeLabel).join(', '),
              }),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}
