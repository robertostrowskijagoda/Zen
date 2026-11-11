import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/presentation/linked_text.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_form_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';
import 'package:zen/src/features/security/secure_screen.dart';

/// One entry of "Hasła": its name, login, password (hidden until shown),
/// address and note, a copy button by the login and the password, "Edytuj"
/// and "Usuń", and its earlier passwords to show, copy or take back. When
/// another device changed it at the same time, it says so and lets the
/// person keep one of the two.
class PasswordEntryScreen extends ConsumerStatefulWidget {
  const PasswordEntryScreen({required this.entryId, super.key});

  final String entryId;

  @override
  ConsumerState<PasswordEntryScreen> createState() =>
      _PasswordEntryScreenState();
}

class _PasswordEntryScreenState extends ConsumerState<PasswordEntryScreen> {
  late final PasswordVaultService _vault = ref.read(
    passwordVaultServiceProvider,
  );
  bool _shown = false;

  /// The earlier versions shown, by their key.
  final Set<String> _shownHistory = <String>{};

  String get _id => widget.entryId;

  Future<void> _edit() async {
    // A new version is a new password to hide again.
    setState(() => _shown = false);
    await pushPasswordPage<String>(context, PasswordFormScreen(entryId: _id));
  }

  Future<void> _delete(PasswordEntry entry) async {
    final NavigatorState navigator = Navigator.of(context);
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        key: const Key('password-delete-dialog'),
        title: Text(
          t('Usunąć „{name}”?', <String, Object?>{'name': entry.title}),
        ),
        content: Text(t('Hasło zniknie ze wszystkich Twoich urządzeń.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('password-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: ZenColors.of(context).danger,
              foregroundColor: ZenColors.foregroundFor(
                ZenColors.of(context).danger,
              ),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Usuń')),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) {
      return;
    }
    if (await runPasswordAction(context, () => _vault.delete(_id))) {
      navigator.pop();
    }
  }

  Future<void> _clearHistory() async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        key: const Key('password-history-clear-dialog'),
        title: Text(t('Usunąć poprzednie hasła?')),
        content: Text(t('Znikną ze wszystkich Twoich urządzeń.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('password-history-clear-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Usuń')),
          ),
        ],
      ),
    );
    if (sure == true && mounted) {
      await runPasswordAction(context, () => _vault.clearHistory(_id));
    }
  }

  Widget _label(ZenColors zen, String text) => Text(
    text,
    style: TextStyle(
      color: zen.textMuted,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    ),
  );

  /// One field of the card: its label, its value, its buttons.
  Widget _row(
    ZenColors zen, {
    required String label,
    required Widget value,
    List<Widget> actions = const <Widget>[],
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _label(zen, label),
              const SizedBox(height: 2),
              value,
            ],
          ),
        ),
        ...actions,
      ],
    ),
  );

  Widget _fields(ZenColors zen, PasswordEntry e) {
    final TextStyle valueStyle = TextStyle(
      color: zen.textPrimary,
      fontSize: 15,
      height: 1.35,
    );
    final String? web = passwordWebAddress(e.address);
    return ZenCard(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (e.login.isNotEmpty)
            _row(
              zen,
              label: t('Login'),
              value: Text(
                e.login,
                key: const Key('password-login'),
                style: valueStyle,
              ),
              actions: <Widget>[
                passwordIconButton(
                  key: const Key('password-copy-login'),
                  tooltip: t('Kopiuj login'),
                  icon: Icons.copy_rounded,
                  onPressed: () => unawaited(
                    copyWithNotice(context, () => _vault.copyLogin(_id)),
                  ),
                ),
              ],
            ),
          if (e.password.isNotEmpty)
            _row(
              zen,
              label: t('Hasło'),
              value: PasswordSecretText(
                key: const Key('password-value'),
                password: e.password,
                shown: _shown,
              ),
              actions: <Widget>[
                passwordIconButton(
                  key: const Key('password-reveal'),
                  tooltip: _shown ? t('Ukryj hasło') : t('Pokaż hasło'),
                  icon: _shown
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  onPressed: () => setState(() => _shown = !_shown),
                ),
                passwordIconButton(
                  key: const Key('password-copy'),
                  tooltip: t('Kopiuj hasło'),
                  icon: Icons.copy_rounded,
                  onPressed: () => unawaited(
                    copyWithNotice(context, () => _vault.copyPassword(_id)),
                  ),
                ),
              ],
            ),
          if (e.address.isNotEmpty)
            _row(
              zen,
              label: t('Adres'),
              value: web == null
                  ? Text(e.address, style: valueStyle)
                  : InkWell(
                      key: const Key('password-address'),
                      onTap: () => unawaited(openTextLink(context, web)),
                      child: Text(
                        e.address,
                        style: valueStyle.copyWith(
                          color: zen.accent,
                          decoration: TextDecoration.underline,
                          decorationColor: zen.accent,
                        ),
                      ),
                    ),
            ),
          if (e.note.isNotEmpty)
            _row(
              zen,
              label: t('Notatka'),
              value: Text(
                e.note,
                key: const Key('password-note'),
                style: valueStyle,
              ),
            ),
        ],
      ),
    );
  }

  /// When [item] stopped being the entry's password: the time of the
  /// version written after it.
  int _replacedAt(PasswordEntry e, PasswordHistoryItem item) {
    int at = e.changedAtMillis;
    for (final PasswordHistoryItem h in e.history) {
      if (!h.concurrent &&
          h.changedAtMillis > item.changedAtMillis &&
          h.changedAtMillis < at) {
        at = h.changedAtMillis;
      }
    }
    return at;
  }

  Widget _historyItem(ZenColors zen, PasswordEntry e, PasswordHistoryItem h) {
    final String vk = h.versionKey;
    final bool shown = _shownHistory.contains(vk);
    final String when = ZenFormat.dateTime(
      DateTime.fromMillisecondsSinceEpoch(
        h.concurrent ? h.changedAtMillis : _replacedAt(e, h),
      ),
    );
    return ZenCard(
      key: Key('password-history-$vk'),
      tone: h.concurrent ? zen.warning : null,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _label(
            zen,
            h.concurrent
                ? t('Z innego urządzenia, {date}', <String, Object?>{
                    'date': when,
                  })
                : t('Zastąpione {date}', <String, Object?>{'date': when}),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: h.password.isEmpty
                    ? Text('—', style: TextStyle(color: zen.textMuted))
                    : PasswordSecretText(password: h.password, shown: shown),
              ),
              if (h.password.isNotEmpty) ...<Widget>[
                passwordIconButton(
                  key: Key('password-history-reveal-$vk'),
                  tooltip: shown ? t('Ukryj hasło') : t('Pokaż hasło'),
                  icon: shown
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  onPressed: () => setState(
                    () => shown
                        ? _shownHistory.remove(vk)
                        : _shownHistory.add(vk),
                  ),
                ),
                passwordIconButton(
                  key: Key('password-history-copy-$vk'),
                  tooltip: t('Kopiuj hasło'),
                  icon: Icons.copy_rounded,
                  onPressed: () => unawaited(
                    copyWithNotice(
                      context,
                      () => _vault.copyPreviousPassword(_id, vk),
                    ),
                  ),
                ),
              ],
            ],
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              key: Key('password-history-restore-$vk'),
              onPressed: () => unawaited(
                runPasswordAction(
                  context,
                  () => _vault.restorePrevious(_id, vk),
                ),
              ),
              icon: const Icon(Icons.restore_rounded, size: 18),
              label: Text(t('Przywróć')),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _body(ZenColors zen, PasswordEntry e) => <Widget>[
    Row(
      children: <Widget>[
        PasswordAvatar(name: e.title, size: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                e.title,
                key: const Key('password-title'),
                style: zen.display(
                  color: zen.textPrimary,
                  size: 22,
                  weight: FontWeight.w700,
                ),
              ),
              if (e.name.isNotEmpty && e.address.isNotEmpty)
                Text(
                  passwordAddressLabel(e.address),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
                ),
            ],
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
    if (e.conflict)
      ZenCard(
        key: const Key('password-conflict-info'),
        tone: zen.warning,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.sync_problem_rounded, color: zen.warning, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t(
                      'W tym samym czasie zmieniono je na innym urządzeniu. '
                      'Wybierz wersję, która ma zostać.',
                    ),
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const Key('password-keep-current'),
                // Saved again as it is, it builds on both: settled.
                onPressed: () => unawaited(
                  runPasswordAction(context, () => _vault.edit(_id, e.fields)),
                ),
                child: Text(t('Zostaw obecną')),
              ),
            ),
          ],
        ),
      ),
    if (e.keptOverDeletion)
      ZenInfo(
        key: const Key('password-kept-info'),
        icon: Icons.info_outline_rounded,
        text: t(
          'Na innym urządzeniu usunięto je, gdy tu było zmieniane, więc '
          'zostało.',
        ),
      ),
    _fields(zen, e),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        FilledButton.tonalIcon(
          key: const Key('password-edit'),
          onPressed: () => unawaited(_edit()),
          icon: const Icon(Icons.edit_rounded),
          label: Text(t('Edytuj')),
        ),
        OutlinedButton.icon(
          key: const Key('password-delete'),
          style: OutlinedButton.styleFrom(foregroundColor: zen.danger),
          onPressed: () => unawaited(_delete(e)),
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(t('Usuń')),
        ),
      ],
    ),
    if (e.history.isNotEmpty) ...<Widget>[
      ZenSection(t('Poprzednie hasła'), key: const Key('password-history')),
      for (final PasswordHistoryItem h in e.history) _historyItem(zen, e, h),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          key: const Key('password-history-clear'),
          style: TextButton.styleFrom(foregroundColor: zen.danger),
          onPressed: () => unawaited(_clearHistory()),
          child: Text(t('Usuń poprzednie hasła')),
        ),
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return SecureScreen(
      child: ListenableBuilder(
        listenable: _vault,
        builder: (BuildContext context, Widget? _) {
          final PasswordEntry? e = _vault.entry(_id);
          return Scaffold(
            key: const Key('password-entry-screen'),
            appBar: AppBar(title: Text(e?.title ?? t('Hasła'))),
            body: SafeArea(
              top: false,
              child: passwordPageColumn(
                e == null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          t('Tego hasła już nie ma.'),
                          key: const Key('password-entry-gone'),
                          style: TextStyle(color: zen.textSecondary),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                        children: _body(zen, e),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}
