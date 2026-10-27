import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_data_reset.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/multi/account_id.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/account/multi/desktop_background.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/hold_to_confirm_button.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// What kind of account this is, in a few words.
String zenAccountKindLabel(ZenAccountScope account) =>
    account.isDefault ? t('Konto domyślne') : t('Konto dodatkowe');

/// The listed accounts, read again whenever asked for.
final FutureProvider<List<ZenListedAccount>> zenListedAccountsProvider =
    FutureProvider<List<ZenListedAccount>>(
      (Ref ref) => ref.read(zenAccountRegistryProvider).listed(),
    );

/// Your avatar in the top bar: the account menu (switching, adding). Locking
/// is the lock button next to it.
class AccountMenuButton extends ConsumerWidget {
  const AccountMenuButton({super.key, this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final UserProfile profile = ref.watch(userProfileControllerProvider);
    return Semantics(
      button: true,
      label: t('Konta'),
      child: InkResponse(
        key: const Key('account-menu-button'),
        radius: size * 0.75,
        onTap: () => unawaited(showZenAccountMenu(context)),
        child: ZenBlobAvatar(
          name: profile.displayName,
          size: size,
          showStatus: false,
          image: peerAvatarImage(profile.avatarPath),
        ),
      ),
    );
  }
}

/// The account menu, as a sheet from the bottom.
Future<void> showZenAccountMenu(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheet) => const _AccountMenuSheet(),
  );
}

class _AccountMenuSheet extends ConsumerStatefulWidget {
  const _AccountMenuSheet();

  @override
  ConsumerState<_AccountMenuSheet> createState() => _AccountMenuSheetState();
}

class _AccountMenuSheetState extends ConsumerState<_AccountMenuSheet> {
  @override
  void initState() {
    super.initState();
    // A listed account shows under its current profile name.
    final ZenAccountScope account = ref.read(zenAccountProvider);
    final String name = ref.read(userProfileControllerProvider).displayName;
    if (!account.isDefault) {
      unawaited(
        ref
            .read(zenAccountRegistryProvider)
            .rename(account, name)
            .then((_) => ref.invalidate(zenListedAccountsProvider))
            .catchError((Object _) {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenAccountScope account = ref.watch(zenAccountProvider);
    final UserProfile profile = ref.watch(userProfileControllerProvider);
    final List<ZenListedAccount> listed =
        ref.watch(zenListedAccountsProvider).value ??
        const <ZenListedAccount>[];
    final List<ZenListedAccount> others = <ZenListedAccount>[
      for (final ZenListedAccount a in listed)
        if (a.id != account.id) a,
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          key: const Key('account-menu'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                ZenBlobAvatar(
                  name: profile.displayName,
                  size: 48,
                  showStatus: false,
                  image: peerAvatarImage(profile.avatarPath),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        profile.displayName,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        zenAccountKindLabel(account),
                        style: TextStyle(color: zen.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (!account.isDefault || others.isNotEmpty) ...<Widget>[
              ZenSection(t('Konta'), top: 0),
              const SizedBox(height: 6),
              if (!account.isDefault)
                _AccountRow(
                  key: const Key('account-menu-default'),
                  name: t('Konto domyślne'),
                  detail: t('Otwiera się hasłem z ekranu blokady'),
                  icon: Icons.home_outlined,
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(returnToDefaultZenAccount(ref));
                  },
                ),
              for (final ZenListedAccount other in others)
                _AccountRow(
                  key: Key('account-menu-listed-${other.id}'),
                  name: other.name.isEmpty ? t('Konto dodatkowe') : other.name,
                  detail: maskAccountId(other.id),
                  icon: Icons.person_outline_rounded,
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(OpenAccountScreen.open(context, listed: other));
                  },
                ),
              const SizedBox(height: 10),
            ],
            ZenTile(
              key: const Key('account-menu-switch'),
              icon: Icons.swap_horiz_rounded,
              title: t('Przełącz…'),
              subtitle: t('Inne konto: podaj jego ID i hasło'),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(OpenAccountScreen.open(context));
              },
            ),
            const SizedBox(height: 8),
            ZenTile(
              key: const Key('account-menu-add'),
              icon: Icons.person_add_alt_1_rounded,
              title: t('Dodaj konto'),
              subtitle: t('Osobna osoba z własnymi kluczami i hasłem'),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(AddAccountScreen.open(context));
              },
            ),
            const SizedBox(height: 8),
            ZenTile(
              key: const Key('account-menu-manage'),
              icon: Icons.manage_accounts_outlined,
              title: t('Konta na tym urządzeniu'),
              subtitle: t('ID konta, lista kont, usuwanie'),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(AccountsScreen.open(context));
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// One account in a list: a name, a short detail, an arrow.
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.name,
    required this.detail,
    required this.icon,
    required this.onTap,
    super.key,
  });

  final String name;
  final String detail;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: context.zenRadius(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: <Widget>[
            ZenBlobAvatar(name: name, size: 36, showStatus: false),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    detail,
                    style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            Icon(icon, color: zen.textMuted, size: 20),
          ],
        ),
      ),
    );
  }
}

/// "Inne konto": opens another account with its ID (or from the list)
/// and its password. Inline, with no dialogs: the lock screen has no
/// Navigator of its own.
class OtherAccountPanel extends ConsumerStatefulWidget {
  const OtherAccountPanel({required this.onBack, this.listed, super.key});

  final VoidCallback onBack;

  /// A listed account picked already (only its password is asked).
  final ZenListedAccount? listed;

  @override
  ConsumerState<OtherAccountPanel> createState() => _OtherAccountPanelState();
}

class _OtherAccountPanelState extends ConsumerState<OtherAccountPanel> {
  final TextEditingController _id = TextEditingController();
  final TextEditingController _password = TextEditingController();
  late ZenListedAccount? _picked = widget.listed;
  List<ZenListedAccount> _listed = const <ZenListedAccount>[];
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadListed());
  }

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadListed() async {
    try {
      final List<ZenListedAccount> listed = await ref
          .read(zenAccountRegistryProvider)
          .listed();
      final String? own = ref.read(zenAccountProvider).id;
      if (mounted) {
        setState(
          () => _listed = <ZenListedAccount>[
            for (final ZenListedAccount a in listed)
              if (a.id != own) a,
          ],
        );
      }
    } on Object {
      // No list: the ID is typed.
    }
  }

  Future<void> _open() async {
    if (_busy) {
      return;
    }
    final String password = _password.text;
    if (password.isEmpty || (_picked == null && _id.text.trim().isEmpty)) {
      setState(() => _error = t('Podaj ID konta i hasło.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final UnlockThrottle throttle = ref.read(unlockThrottleProvider);
    final Duration wait = await throttle.remaining();
    if (wait > Duration.zero) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = t('Za dużo błędnych prób. Spróbuj ponownie później.');
        });
      }
      return;
    }
    final ZenAccountRegistry registry = ref.read(zenAccountRegistryProvider);
    final ZenListedAccount? picked = _picked;
    final ZenAccountScope? scope = picked != null
        ? await registry.scopeOf(picked)
        : await registry.find(_id.text);
    ZenAccountUnlockResult result = const ZenAccountUnlockResult(
      ZenAccountUnlock.refused,
    );
    if (scope != null && scope != ref.read(zenAccountProvider)) {
      result = await unlockZenAccount(
        scope,
        password,
        registry: registry,
        security: ref.read(zenAccountSecurityFactoryProvider),
      );
    }
    if (!mounted) {
      return;
    }
    final AppSecurityService? security = result.security;
    if (result.outcome == ZenAccountUnlock.opened && scope != null) {
      await throttle.clear();
      if (!mounted) {
        return;
      }
      _password.clear();
      await switchZenAccount(
        ref,
        ZenAccountOpening(scope: scope, security: security),
      );
      return;
    }
    // A wrong ID, a wrong password and a panic password read the same.
    await throttle.recordFailure();
    if (result.outcome == ZenAccountUnlock.wiped) {
      ref.invalidate(zenListedAccountsProvider);
      await _loadListed();
    }
    if (!mounted) {
      return;
    }
    _password.clear();
    setState(() {
      _busy = false;
      _error = t('Nieprawidłowe ID konta lub hasło.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenListedAccount? picked = _picked;
    return Column(
      key: const Key('other-account-panel'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          t('Inne konto'),
          textAlign: TextAlign.center,
          style: zen.display(
            color: zen.textPrimary,
            size: 26,
            weight: FontWeight.w600,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          picked == null
              ? t('Podaj ID konta i jego hasło.')
              : t('Podaj hasło tego konta.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: zen.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (picked == null && _listed.isNotEmpty) ...<Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final ZenListedAccount a in _listed)
                ActionChip(
                  key: Key('other-account-listed-${a.id}'),
                  avatar: const Icon(Icons.person_outline_rounded, size: 18),
                  label: Text(
                    a.name.isEmpty
                        ? maskAccountId(a.id)
                        : '${a.name} · ${maskAccountId(a.id)}',
                  ),
                  onPressed: _busy ? null : () => setState(() => _picked = a),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (picked == null)
          TextField(
            key: const Key('other-account-id'),
            controller: _id,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: t('ID konta'),
              hintText: 'XXXX-XXXX-XXXX-XXXX',
              prefixIcon: const Icon(Icons.badge_outlined),
            ),
          )
        else
          InputChip(
            key: const Key('other-account-picked'),
            avatar: const Icon(Icons.person_outline_rounded, size: 18),
            label: Text(
              picked.name.isEmpty
                  ? maskAccountId(picked.id)
                  : '${picked.name} · ${maskAccountId(picked.id)}',
            ),
            onDeleted: _busy || widget.listed != null
                ? null
                : () => setState(() => _picked = null),
          ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('other-account-password'),
          controller: _password,
          obscureText: _obscure,
          enableIMEPersonalizedLearning: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: t('Hasło'),
            prefixIcon: const Icon(Icons.key_rounded),
            suffixIcon: IconButton(
              tooltip: _obscure ? t('Pokaż hasło') : t('Ukryj hasło'),
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
            ),
          ),
          onSubmitted: (_) => unawaited(_open()),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          ZenInfo(
            key: const Key('other-account-error'),
            icon: Icons.error_outline_rounded,
            tone: zen.danger,
            text: _error!,
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('other-account-open'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: _busy ? null : () => unawaited(_open()),
          icon: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login_rounded, size: 20),
          label: Text(t('Otwórz konto')),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('other-account-back'),
          onPressed: _busy ? null : widget.onBack,
          child: Text(t('Wróć')),
        ),
      ],
    );
  }
}

/// [OtherAccountPanel] on a page of its own (from the account menu).
class OpenAccountScreen extends StatelessWidget {
  const OpenAccountScreen({this.listed, super.key});

  final ZenListedAccount? listed;

  static Future<void> open(BuildContext context, {ZenListedAccount? listed}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => OpenAccountScreen(listed: listed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ZenSectionBar(title: t('Przełącz konto')),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: OtherAccountPanel(
                listed: listed,
                onBack: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Dodaj konto": a new, separate person on this device. Its ID is shown
/// once; it then starts like a new install (terms, its own password, its
/// own keys and mesh address).
class AddAccountScreen extends ConsumerStatefulWidget {
  const AddAccountScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AddAccountScreen(),
      ),
    );
  }

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  bool _listed = false;
  bool _busy = false;
  bool _saved = false;
  ZenAccountScope? _created;
  String? _error;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ZenAccountScope scope = await ref
          .read(zenAccountRegistryProvider)
          .create(listed: _listed);
      ref.invalidate(zenListedAccountsProvider);
      if (mounted) {
        setState(() => _created = scope);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = t('Nie udało się utworzyć konta: {error}', {
            'error': error,
          }),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _go() async {
    final ZenAccountScope? scope = _created;
    if (scope == null) {
      return;
    }
    setState(() => _busy = true);
    Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
    await switchZenAccount(ref, ZenAccountOpening(scope: scope));
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenAccountScope? created = _created;
    return Scaffold(
      appBar: ZenSectionBar(title: t('Dodaj konto')),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            key: const Key('add-account-page'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              if (created == null) ...<Widget>[
                ZenInfo(
                  icon: Icons.person_add_alt_1_rounded,
                  text: t(
                    'Nowe konto to osobna osoba w Zen: własne klucze, własny '
                    'adres w sieci, własne hasło, rozmowy i powiadomienia. '
                    'Zaczyna jak nowa instalacja.',
                  ),
                ),
                const SizedBox(height: 10),
                ZenInfo(
                  icon: Icons.visibility_off_outlined,
                  tone: zen.warning,
                  text: t(
                    'Konto spoza listy otworzysz tylko, podając jego ID '
                    '(pokażemy je raz) i hasło. Nikt, kto weźmie to '
                    'urządzenie, nie zobaczy, że ono istnieje.',
                  ),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  key: const Key('add-account-listed'),
                  contentPadding: EdgeInsets.zero,
                  value: _listed,
                  onChanged: _busy
                      ? null
                      : (bool value) => setState(() => _listed = value),
                  title: Text(t('Pokazuj na liście kont')),
                  subtitle: Text(t('Otworzysz je z listy, bez wpisywania ID.')),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  ZenInfo(
                    icon: Icons.error_outline_rounded,
                    tone: zen.danger,
                    text: _error!,
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('add-account-create'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: _busy ? null : () => unawaited(_create()),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t('Utwórz konto')),
                ),
              ] else ...<Widget>[
                Text(
                  t('ID nowego konta'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: zen.textSecondary),
                ),
                const SizedBox(height: 8),
                _AccountIdCard(id: created.id!),
                const SizedBox(height: 12),
                ZenInfo(
                  icon: Icons.warning_amber_rounded,
                  tone: zen.warning,
                  text: _listed
                      ? t(
                          'Zapisz to ID. Zobaczysz je też w ustawieniach '
                          'tego konta.',
                        )
                      : t(
                          'Zapisz to ID w bezpiecznym miejscu. Bez niego nie '
                          'otworzysz tego konta — Zen nigdzie go nie '
                          'pokazuje poza ustawieniami samego konta.',
                        ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('add-account-saved'),
                  contentPadding: EdgeInsets.zero,
                  value: _saved,
                  onChanged: (bool? value) =>
                      setState(() => _saved = value ?? false),
                  title: Text(t('Zapisałem ID tego konta')),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('add-account-go'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: _saved && !_busy ? () => unawaited(_go()) : null,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(t('Przejdź do nowego konta')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An account ID, large, with a copy button.
class _AccountIdCard extends StatelessWidget {
  const _AccountIdCard({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: SelectableText(
              formatAccountId(id),
              key: const Key('account-id-text'),
              style: zen.mono(
                color: zen.textPrimary,
                size: 19,
                letterSpacing: 1.2,
              ),
            ),
          ),
          IconButton(
            key: const Key('account-id-copy'),
            tooltip: t('Kopiuj'),
            icon: const Icon(Icons.copy_rounded),
            onPressed: () {
              unawaited(copyWithExpiry(formatAccountId(id)));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text(t('Skopiowano ID konta.'))),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// "Konta na tym urządzeniu": this account's ID and list setting, how
/// the accounts work, and wiping one account or all of them.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AccountsScreen(),
      ),
    );
  }

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  bool? _listed;
  bool? _background;
  bool _wiping = false;

  /// The Android background service, or a computer's tray, receives for
  /// accounts that are not open.
  static bool get _backgroundSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      zenDesktopBackgroundPlatform;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ZenAccountScope account = ref.read(zenAccountProvider);
    if (_backgroundSupported) {
      try {
        final bool on = await ref
            .read(zenBackgroundAccountsProvider)
            .isOn(account);
        if (mounted) {
          setState(() => _background = on);
        }
      } on Object {
        // Not readable: the switch stays off.
      }
    }
    if (account.isDefault) {
      return;
    }
    final bool listed = await ref
        .read(zenAccountRegistryProvider)
        .isListed(account);
    if (mounted) {
      setState(() => _listed = listed);
    }
  }

  Future<void> _setListed(bool value) async {
    final ZenAccountScope account = ref.read(zenAccountProvider);
    setState(() => _listed = value);
    await ref
        .read(zenAccountRegistryProvider)
        .setListed(
          account,
          listed: value,
          name: ref.read(userProfileControllerProvider).displayName,
        );
    ref.invalidate(zenListedAccountsProvider);
  }

  /// "Odbieraj w tle": on only after the warning (the battery, and for an
  /// additional account what it gives up of being hidden).
  Future<void> _setBackground(bool value) async {
    final ZenAccountScope account = ref.read(zenAccountProvider);
    final ZenBackgroundAccounts settings = ref.read(
      zenBackgroundAccountsProvider,
    );
    if (value && !await _confirmBackground(account)) {
      return;
    }
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final Future<Directory> Function() support = ref.read(
      supportDirectoryResolverProvider,
    );
    // A computer seals the node again: with the background key (the tray
    // runs it without the password), or back with the master key.
    if (zenDesktopBackgroundPlatform && value) {
      await applyDesktopBackgroundSetting(
        account: account,
        on: true,
        security: security,
        support: await support(),
      );
    }
    final bool done = await settings.setOn(account, value);
    if (zenDesktopBackgroundPlatform && !value) {
      await applyDesktopBackgroundSetting(
        account: account,
        on: false,
        security: security,
        support: await support(),
      );
    }
    if (!mounted) {
      return;
    }
    if (!done) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            t('Najwyżej {n} kont dodatkowych może odbierać w tle.', {
              'n': ZenBackgroundAccounts.slots,
            }),
          ),
        ),
      );
      return;
    }
    setState(() => _background = value);
  }

  Future<bool> _confirmBackground(ZenAccountScope account) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) {
        final ZenColors zen = ZenColors.of(dialog);
        return AlertDialog(
          key: const Key('accounts-background-warning'),
          icon: Icon(Icons.battery_alert_rounded, color: zen.warning, size: 32),
          title: Text(t('Odbierać w tle?')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  zenDesktopBackgroundPlatform
                      ? t(
                          'Każde konto odbierające w tle to osobny węzeł '
                          'sieci, który działa cały czas, gdy Zen jest '
                          'zablokowany albo schowany w zasobniku. Komputer '
                          'zużyje więcej prądu i danych.',
                        )
                      : t(
                          'Każde konto odbierające w tle to osobny węzeł sieci, '
                          'który działa cały czas, gdy Zen jest zablokowany albo '
                          'zamknięty. Telefon zużyje więcej baterii i danych.',
                        ),
                ),
                if (!account.isDefault) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    zenDesktopBackgroundPlatform
                        ? t(
                            'To konto przestaje być w pełni ukryte: każdy '
                            'program działający na tym komputerze jako Ty może '
                            'ustalić, że istnieje, i odczytać jego adres w '
                            'sieci oraz listę osób, od których przyjmuje '
                            'wiadomości. Rozmowy i reszta danych zostają '
                            'zaszyfrowane hasłem. Powiadomienia tego konta są '
                            'ogólne: bez nazw, treści i nazwy konta.',
                          )
                        : t(
                            'To konto przestaje być w pełni ukryte: ktoś z pełnym '
                            'dostępem do tego telefonu (np. z uprawnieniami roota) '
                            'może ustalić, że istnieje, i odczytać jego adres w '
                            'sieci oraz listę osób, od których przyjmuje '
                            'wiadomości. Rozmowy i reszta danych zostają '
                            'zaszyfrowane hasłem. Powiadomienia tego konta są '
                            'ogólne: bez nazw, treści i nazwy konta.',
                          ),
                    style: TextStyle(color: zen.warning),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('accounts-background-confirm'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(t('Włącz')),
            ),
          ],
        );
      },
    );
    return yes ?? false;
  }

  Future<void> _wipe(Future<void> Function(WidgetRef ref) wipe) async {
    setState(() => _wiping = true);
    try {
      await wipe(ref);
    } finally {
      // The default account starts over in place; after any other wipe
      // the app has opened another account already.
      if (mounted) {
        setState(() => _wiping = false);
        Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenAccountScope account = ref.watch(zenAccountProvider);
    final String? id = account.id;
    return Scaffold(
      appBar: ZenSectionBar(title: t('Konta na tym urządzeniu')),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            key: const Key('accounts-page'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenSection(t('To konto'), top: 0),
              const SizedBox(height: 8),
              Text(
                zenAccountKindLabel(account),
                style: TextStyle(
                  color: zen.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 6),
              if (id == null)
                Text(
                  t(
                    'Otwiera się po starcie aplikacji, hasłem z ekranu '
                    'blokady.',
                  ),
                  style: TextStyle(color: zen.textSecondary, height: 1.4),
                )
              else ...<Widget>[
                Text(
                  t('ID tego konta (podasz je przy „Inne konto”):'),
                  style: TextStyle(color: zen.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 8),
                _AccountIdCard(id: id),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const Key('accounts-listed-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _listed ?? false,
                  onChanged: _listed == null
                      ? null
                      : (bool value) => unawaited(_setListed(value)),
                  title: Text(t('Pokazuj na liście kont')),
                  subtitle: Text(
                    t(
                      'Na liście widać nazwę konta i koniec ID; otwiera się '
                      'bez wpisywania ID. Wyłączone: nikt nie zobaczy, że '
                      'to konto istnieje.',
                    ),
                  ),
                ),
              ],
              if (_backgroundSupported) ...<Widget>[
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const Key('accounts-background-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _background ?? false,
                  onChanged: _background == null
                      ? null
                      : (bool value) => unawaited(_setBackground(value)),
                  title: Text(t('Odbieraj w tle')),
                  subtitle: Text(switch ((
                    zenDesktopBackgroundPlatform,
                    account.isDefault,
                  )) {
                    (true, true) => t(
                      'Gdy Zen jest zablokowany albo w zasobniku. Każde '
                      'konto w tle zużywa więcej prądu.',
                    ),
                    (true, false) => t(
                      'Gdy Zen jest zablokowany albo w zasobniku. Zużywa '
                      'więcej prądu, a programy na tym komputerze mogłyby '
                      'ustalić, że to konto istnieje.',
                    ),
                    (false, true) => t(
                      'Gdy Zen jest zablokowany albo zamknięty. Każde '
                      'konto w tle zużywa więcej baterii.',
                    ),
                    (false, false) => t(
                      'Gdy Zen jest zablokowany albo zamknięty. Zużywa '
                      'więcej baterii, a ktoś z pełnym dostępem do '
                      'telefonu mógłby ustalić, że to konto istnieje.',
                    ),
                  }),
                ),
              ],
              const SizedBox(height: 12),
              ZenTile(
                key: const Key('accounts-add'),
                icon: Icons.person_add_alt_1_rounded,
                title: t('Dodaj konto'),
                onTap: () => unawaited(AddAccountScreen.open(context)),
              ),
              const SizedBox(height: 8),
              ZenTile(
                key: const Key('accounts-switch'),
                icon: Icons.swap_horiz_rounded,
                title: t('Przełącz…'),
                onTap: () => unawaited(OpenAccountScreen.open(context)),
              ),
              ZenSection(t('Jak to działa')),
              const SizedBox(height: 8),
              ZenInfo(
                icon: Icons.notifications_paused_outlined,
                text: t(
                  'W tle (zablokowana aplikacja, telefon w kieszeni) '
                  'domyślnie odbiera tylko konto domyślne; każde konto może '
                  'to zmienić przełącznikiem „Odbieraj w tle”. Konto bez '
                  'niego odbiera, gdy jest otwarte; to, co przyszło pod jego '
                  'nieobecność, czeka u zaufanych znajomych albo u nadawcy i '
                  'dochodzi po otwarciu.',
                ),
              ),
              const SizedBox(height: 8),
              ZenInfo(
                icon: Icons.lock_outline_rounded,
                text: t(
                  'Zablokowanie konta dodatkowego wraca do ekranu blokady '
                  'konta domyślnego. Powiadomienia innego konta znikają '
                  'przy przełączeniu.',
                ),
              ),
              ZenSection(t('Usuwanie')),
              const SizedBox(height: 8),
              if (_wiping)
                const Center(child: CircularProgressIndicator())
              else ...<Widget>[
                Text(
                  account.isDefault
                      ? t(
                          'Usuwa z tego urządzenia wszystko z konta '
                          'domyślnego. Inne konta zostają.',
                        )
                      : t(
                          'Usuwa z tego urządzenia to konto: klucze, rozmowy, '
                          'pliki i ustawienia. Inne konta zostają.',
                        ),
                  style: TextStyle(color: zen.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 10),
                Center(
                  child: HoldToConfirmButton(
                    key: const Key('accounts-wipe-this'),
                    idleLabel: t('Przytrzymaj, aby usunąć to konto'),
                    holdingLabel: (int seconds) =>
                        t('Trzymaj… jeszcze {n} s', {'n': seconds}),
                    onConfirmed: () =>
                        unawaited(_wipe(performZenLocalDataReset)),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  t(
                    'Usuwa z tego urządzenia wszystkie konta — także te spoza '
                    'listy — i wszystkie ich klucze. Zen zacznie jak nowo '
                    'zainstalowany.',
                  ),
                  style: TextStyle(color: zen.danger, height: 1.4),
                ),
                const SizedBox(height: 10),
                Center(
                  child: HoldToConfirmButton(
                    key: const Key('accounts-wipe-all'),
                    idleLabel: t('Przytrzymaj, aby usunąć wszystkie konta'),
                    holdingLabel: (int seconds) =>
                        t('Trzymaj… jeszcze {n} s', {'n': seconds}),
                    onConfirmed: () => unawaited(_wipe(performZenDeviceWipe)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
