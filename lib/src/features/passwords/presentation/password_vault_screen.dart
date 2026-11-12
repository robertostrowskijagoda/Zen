import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_autofill_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_entry_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_form_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_import.dart';
import 'package:zen/src/features/passwords/presentation/password_setup_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// "Hasła": the account's passwords as a list to search, each with a
/// one-tap copy of its password, and the way to add, import and open them.
///
/// It opens only after the app password (when there is one) is given
/// again, every time ([open]). While it is open, locking Zen closes it and
/// every page and dialog over it, and nothing of the vault stays in memory
/// (the vault forgets on the lock itself). Another account opening builds
/// the whole app anew, this screen with it.
class PasswordVaultScreen extends ConsumerStatefulWidget {
  const PasswordVaultScreen({this.initialSearch = '', super.key});

  /// What the search starts with (a page or an app to find the login of).
  final String initialSearch;

  /// Asks who the person is, then opens the screen with [search] typed.
  static Future<void> open(BuildContext context, {String search = ''}) async {
    // Once per opening: a confirmation for another place a moment ago
    // does not open the passwords.
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sensitiveAccessClockProvider).forget();
    if (!await confirmSensitiveAccess(
          context,
          reason: t('Hasła są chronione. Potwierdź, że to Ty.'),
        ) ||
        !context.mounted) {
      return;
    }
    await pushPasswordPage<void>(
      context,
      PasswordVaultScreen(initialSearch: search),
    );
  }

  @override
  ConsumerState<PasswordVaultScreen> createState() =>
      _PasswordVaultScreenState();
}

class _PasswordVaultScreenState extends ConsumerState<PasswordVaultScreen> {
  late final PasswordVaultService _vault = ref.read(
    passwordVaultServiceProvider,
  );
  late final AppSecurityService _security = ref.read(
    appSecurityServiceProvider,
  );
  late final TextEditingController _search = TextEditingController(
    text: widget.initialSearch,
  );
  NavigatorState? _navigator;
  bool _loadFailed = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _security.addListener(_onSecurity);
    if (!_vault.loaded) {
      unawaited(_load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  @override
  void dispose() {
    _security.removeListener(_onSecurity);
    _search
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    try {
      await _vault.load();
    } on Object {
      // Locked meanwhile (the screen is closing then), or the store did not
      // answer: said on the screen, nothing of the error shown.
      if (mounted) {
        setState(() => _loadFailed = true);
      }
    }
  }

  void _onSecurity() {
    if (!_security.isLocked || _closing) {
      return;
    }
    _closing = true;
    final NavigatorState? navigator = _navigator;
    if (navigator != null && navigator.mounted) {
      closePasswordPages(navigator);
    }
  }

  bool get _readOnly => _vault.damaged || _vault.newerFormat;

  Future<void> _add() async {
    final String? id = await pushPasswordPage<String>(
      context,
      const PasswordFormScreen(),
    );
    if (id != null && mounted) {
      _search.clear();
      unawaited(_openEntry(id));
    }
  }

  Future<void> _openEntry(String id) =>
      pushPasswordPage<void>(context, PasswordEntryScreen(entryId: id));

  void _howItWorks() {
    unawaited(
      showDialog<void>(
        context: context,
        routeSettings: const RouteSettings(name: kPasswordVaultRouteName),
        builder: (BuildContext context) => AlertDialog(
          scrollable: true,
          key: const Key('passwords-help'),
          title: Text(t('Jak to działa')),
          content: Text(
            t(
              'Hasła są zaszyfrowane na Twoich urządzeniach, a kilkoro '
              'Twoich znajomych trzyma ich zamkniętą kopię, której nie '
              'otworzą. Zen przenosi je między Twoimi urządzeniami, '
              'przywraca z kopią konta, a po odzyskaniu konta z samego '
              'klucza — z kopii u znajomych; bez żadnego znajomego wtedy '
              'nie wrócą. Skopiowane hasło znika ze schowka po 30 '
              'sekundach.',
            ),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t('Rozumiem')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(ZenColors zen, PasswordEntry e) {
    final String below = e.login.isNotEmpty
        ? e.login
        : passwordAddressLabel(e.address);
    return ZenCard(
      key: Key('password-row-${e.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 4, 10),
      onTap: () => unawaited(_openEntry(e.id)),
      child: Row(
        children: <Widget>[
          PasswordAvatar(name: e.title),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (e.conflict) ...<Widget>[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: t('Zmienione na dwóch urządzeniach naraz'),
                        child: Icon(
                          Icons.sync_problem_rounded,
                          key: Key('password-conflict-${e.id}'),
                          size: 16,
                          color: zen.warning,
                        ),
                      ),
                    ],
                  ],
                ),
                if (below.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    below,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
          if (e.password.isNotEmpty)
            passwordIconButton(
              key: Key('password-row-copy-${e.id}'),
              tooltip: t('Kopiuj hasło'),
              icon: Icons.copy_rounded,
              color: zen.textSecondary,
              onPressed: () => unawaited(
                copyWithNotice(context, () => _vault.copyPassword(e.id)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty(ZenColors zen) => ListView(
    key: const Key('passwords-empty'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: <Widget>[
      ZenEmpty(
        icon: Icons.key_rounded,
        tone: zen.tone(ZenTone.privacy),
        title: t('Tu zapiszesz swoje hasła'),
        text: t(
          'Zaszyfrowane i tylko na Twoich urządzeniach. Dodaj pierwsze albo '
          'zaimportuj je z przeglądarki.',
        ),
        action: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('passwords-empty-add'),
              onPressed: () => unawaited(_add()),
              icon: const Icon(Icons.add_rounded),
              label: Text(t('Dodaj hasło')),
            ),
            OutlinedButton.icon(
              key: const Key('passwords-empty-import'),
              onPressed: () => unawaited(importPasswordFile(context, ref)),
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(t('Importuj z pliku')),
            ),
            OutlinedButton.icon(
              key: const Key('passwords-empty-setup'),
              onPressed: () => unawaited(
                PasswordSetupScreen.open(context, withImport: true),
              ),
              icon: const Icon(Icons.tune_rounded),
              label: Text(t('Konfiguracja haseł')),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _list(ZenColors zen) {
    final List<PasswordEntry> found = _vault.search(_search.text);
    final bool full = _vault.entries.length >= kMaxPasswordEntries;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            key: const Key('passwords-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            autocorrect: false,
            enableIMEPersonalizedLearning: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t('Szukaj'),
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: t('Wyczyść'),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        Expanded(
          child: found.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: <Widget>[
                    Text(
                      t('Nic nie pasuje do „{query}”.', <String, Object?>{
                        'query': _search.text.trim(),
                      }),
                      key: const Key('passwords-search-empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: zen.textSecondary),
                    ),
                  ],
                )
              : ListView.builder(
                  key: const Key('passwords-list'),
                  // Room under the last row for the "+" button.
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                  itemCount: found.length + (full ? 1 : 0),
                  itemBuilder: (BuildContext context, int i) {
                    if (full && i == 0) {
                      return ZenInfo(
                        key: const Key('passwords-full'),
                        icon: Icons.inventory_2_outlined,
                        tone: zen.warning,
                        text: t(
                          'Brak miejsca na nowe hasła. Usuń te, których nie '
                          'potrzebujesz.',
                        ),
                      );
                    }
                    return _row(zen, found[full ? i - 1 : i]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _readOnlyNotice(ZenColors zen) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
    children: <Widget>[
      if (_vault.damaged)
        ZenInfo(
          key: const Key('passwords-damaged'),
          icon: Icons.report_gmailerrorred_rounded,
          tone: zen.danger,
          title: t('Zapisanych haseł nie da się odczytać'),
          text: t('Zen zostawia je bez zmian i nic do nich nie dopisuje.'),
        )
      else
        ZenInfo(
          key: const Key('passwords-newer'),
          icon: Icons.system_update_rounded,
          tone: zen.warning,
          title: t('Hasła z nowszej wersji Zen'),
          text: t('Zostają bez zmian. Zaktualizuj Zen, żeby z nich korzystać.'),
        ),
    ],
  );

  Widget _body(ZenColors zen) {
    if (_security.isLocked) {
      return const SizedBox.shrink();
    }
    if (_loadFailed) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          Text(
            t('Nie udało się. Spróbuj jeszcze raz.'),
            key: const Key('passwords-load-failed'),
            textAlign: TextAlign.center,
            style: TextStyle(color: zen.textSecondary),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              key: const Key('passwords-retry'),
              onPressed: () => unawaited(_load()),
              child: Text(t('Spróbuj ponownie')),
            ),
          ),
        ],
      );
    }
    if (!_vault.loaded) {
      return Center(
        key: const Key('passwords-loading'),
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 3, color: zen.accent),
        ),
      );
    }
    if (_readOnly) {
      return _readOnlyNotice(zen);
    }
    if (_vault.entries.isEmpty) {
      return _empty(zen);
    }
    return _list(zen);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return SecureScreen(
      child: ListenableBuilder(
        listenable: _vault,
        builder: (BuildContext context, Widget? _) {
          final bool writable =
              _vault.loaded && !_readOnly && !_security.isLocked;
          return Scaffold(
            key: const Key('passwords-screen'),
            appBar: AppBar(
              title: Text(t('Hasła')),
              actions: <Widget>[
                // The setup in sight, not in the menu: on Android the
                // phone and each browser need a switch before Zen fills.
                IconButton(
                  key: const Key('passwords-setup'),
                  tooltip: t('Konfiguracja haseł'),
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () => unawaited(
                    PasswordSetupScreen.open(context, withImport: writable),
                  ),
                ),
                PopupMenuButton<String>(
                  key: const Key('passwords-menu'),
                  tooltip: t('Więcej'),
                  onSelected: (String choice) {
                    if (choice == 'import') {
                      unawaited(importPasswordFile(context, ref));
                    } else if (choice == 'autofill') {
                      unawaited(showPasswordAutofillInfo(context));
                    } else {
                      _howItWorks();
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          key: const Key('passwords-menu-import'),
                          value: 'import',
                          enabled: writable,
                          child: Text(t('Importuj z pliku CSV')),
                        ),
                        // Android only: Zen as the system's autofill.
                        if (ref.read(passwordAutofillBridgeProvider).supported)
                          PopupMenuItem<String>(
                            key: const Key('passwords-menu-autofill'),
                            value: 'autofill',
                            child: Text(t('Wypełnianie w innych aplikacjach')),
                          ),
                        PopupMenuItem<String>(
                          key: const Key('passwords-menu-help'),
                          value: 'help',
                          child: Text(t('Jak to działa')),
                        ),
                      ],
                ),
              ],
            ),
            floatingActionButton: writable && _vault.entries.isNotEmpty
                ? FloatingActionButton(
                    key: const Key('passwords-add'),
                    tooltip: t('Dodaj hasło'),
                    onPressed: () => unawaited(_add()),
                    child: const Icon(Icons.add_rounded),
                  )
                : null,
            body: SafeArea(top: false, child: passwordPageColumn(_body(zen))),
          );
        },
      ),
    );
  }
}
