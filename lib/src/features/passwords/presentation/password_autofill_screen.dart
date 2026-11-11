import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_match.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/secure_screen.dart';

/// The autofill's picker: which login goes into the form of another app or
/// a browser ([request]). It closes with the entry the person tapped, or
/// with null (back, Zen locked).
///
/// Who asked is at the top: the page's host in a browser, or the app's
/// package (with the name it gives itself). The list holds only the entries
/// saved for that app or page ([PasswordVaultService.matchesFor]). Every
/// other entry is shown only after "Szukaj w hasłach" and a warning: a
/// password given to an app or page it was not saved for is how phishing
/// works. Like every page of "Hasła", locking Zen closes it.
class PasswordAutofillScreen extends ConsumerStatefulWidget {
  const PasswordAutofillScreen({required this.request, super.key});

  final PasswordAutofillRequest request;

  @override
  ConsumerState<PasswordAutofillScreen> createState() =>
      _PasswordAutofillScreenState();
}

class _PasswordAutofillScreenState
    extends ConsumerState<PasswordAutofillScreen> {
  late final PasswordVaultService _vault = ref.read(
    passwordVaultServiceProvider,
  );
  late final AppSecurityService _security = ref.read(
    appSecurityServiceProvider,
  );
  late final PasswordAutofillBridge _bridge = ref.read(
    passwordAutofillBridgeProvider,
  );
  final TextEditingController _search = TextEditingController();
  NavigatorState? _navigator;
  bool _loadFailed = false;
  bool _closing = false;

  /// Past the warning: every entry, to search.
  bool _all = false;

  @override
  void initState() {
    super.initState();
    _security.addListener(_onSecurity);
    // Another app's window drawn over the picker gets no tap through.
    unawaited(_bridge.guard(on: true));
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
    unawaited(_bridge.guard(on: false));
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

  /// Whether [e] has anything this form can take.
  bool _fills(PasswordEntry e) =>
      e.password.isNotEmpty ||
      (widget.request.hasUsernameField && e.login.isNotEmpty);

  Future<void> _showAll() async {
    final bool go =
        await showDialog<bool>(
          context: context,
          routeSettings: const RouteSettings(name: kPasswordVaultRouteName),
          builder: (BuildContext context) => AlertDialog(
            key: const Key('autofill-warning'),
            scrollable: true,
            icon: const Icon(Icons.gpp_maybe_rounded),
            title: Text(
              t('To nie jest login zapisany dla tej aplikacji ani strony'),
            ),
            content: Text(
              t(
                'Wpisanie hasła tam, gdzie go nie zapisano, to sposób '
                'działania oszustw: fałszywa aplikacja albo strona udaje '
                'prawdziwą. Wybierz login tylko wtedy, gdy wiesz, dlaczego '
                'adres jest inny.',
              ),
            ),
            actions: <Widget>[
              TextButton(
                key: const Key('autofill-warning-cancel'),
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(t('Anuluj')),
              ),
              FilledButton(
                key: const Key('autofill-warning-continue'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(t('Pokaż wszystkie hasła')),
              ),
            ],
          ),
        ) ??
        false;
    if (go && mounted && !_security.isLocked) {
      setState(() => _all = true);
    }
  }

  Widget _requester(ZenColors zen) {
    final PasswordAutofillRequest r = widget.request;
    final String main = r.isWeb ? r.webDomain! : (r.appLabel ?? r.packageName);
    final String? below = r.isWeb
        ? (r.appLabel == null
              ? r.packageName
              : '${r.appLabel} · ${r.packageName}')
        : (r.appLabel == null ? null : r.packageName);
    return ZenCard(
      key: const Key('autofill-requester'),
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Icon(
            r.isWeb ? Icons.language_rounded : Icons.apps_rounded,
            color: zen.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  r.isWeb ? t('Strona w przeglądarce') : t('Aplikacja'),
                  style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 2),
                Text(
                  main,
                  key: const Key('autofill-requester-name'),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (below != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    below,
                    key: const Key('autofill-requester-package'),
                    style: zen.mono(color: zen.textSecondary, size: 12.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ZenColors zen, PasswordEntry e, {required bool showAddress}) {
    final String address = passwordAddressLabel(e.address);
    final String below = <String>[
      if (e.login.isNotEmpty) e.login,
      if (showAddress && address.isNotEmpty) address,
    ].join(' · ');
    return ZenCard(
      key: Key('${_all ? 'autofill-any-row' : 'autofill-row'}-${e.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      onTap: () => Navigator.of(context).pop(e),
      child: Row(
        children: <Widget>[
          PasswordAvatar(name: e.title),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
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
        ],
      ),
    );
  }

  List<Widget> _matching(ZenColors zen) {
    final PasswordAutofillRequest r = widget.request;
    final List<PasswordMatch> found = r.isWeb
        ? _vault.matchesFor(webDomain: r.webDomain, webScheme: r.webScheme)
        : _vault.matchesFor(packageName: r.packageName);
    return <Widget>[
      for (final PasswordMatch m in found)
        if (_fills(m.entry))
          _row(zen, m.entry, showAddress: m.kind == PasswordMatchKind.sameSite),
      if (!found.any((PasswordMatch m) => _fills(m.entry)))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            r.isWeb
                ? t('Nie masz loginu zapisanego dla tej strony.')
                : t('Nie masz loginu zapisanego dla tej aplikacji.'),
            key: const Key('autofill-none'),
            textAlign: TextAlign.center,
            style: TextStyle(color: zen.textSecondary),
          ),
        ),
      const SizedBox(height: 8),
      Center(
        child: OutlinedButton.icon(
          key: const Key('autofill-search-all'),
          onPressed: () => unawaited(_showAll()),
          icon: const Icon(Icons.search_rounded),
          label: Text(t('Szukaj w hasłach')),
        ),
      ),
    ];
  }

  List<Widget> _everything(ZenColors zen) => <Widget>[
    ZenInfo(
      key: const Key('autofill-all-notice'),
      icon: Icons.gpp_maybe_rounded,
      tone: zen.warning,
      text: t('To nie jest login zapisany dla tej aplikacji ani strony'),
    ),
    const SizedBox(height: 8),
    TextField(
      key: const Key('autofill-search'),
      controller: _search,
      onChanged: (_) => setState(() {}),
      autocorrect: false,
      enableIMEPersonalizedLearning: false,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: t('Szukaj'),
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
      ),
    ),
    const SizedBox(height: 4),
    for (final PasswordEntry e in _vault.search(_search.text))
      if (_fills(e)) _row(zen, e, showAddress: true),
  ];

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
            key: const Key('autofill-load-failed'),
            textAlign: TextAlign.center,
            style: TextStyle(color: zen.textSecondary),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              onPressed: () => unawaited(_load()),
              child: Text(t('Spróbuj ponownie')),
            ),
          ),
        ],
      );
    }
    if (!_vault.loaded) {
      return Center(
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 3, color: zen.accent),
        ),
      );
    }
    return ListView(
      key: const Key('autofill-list'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: <Widget>[
        _requester(zen),
        ...(_all ? _everything(zen) : _matching(zen)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return SecureScreen(
      child: ListenableBuilder(
        listenable: _vault,
        builder: (BuildContext context, Widget? _) => Scaffold(
          key: const Key('autofill-screen'),
          appBar: AppBar(title: Text(t('Wybierz login'))),
          body: SafeArea(top: false, child: passwordPageColumn(_body(zen))),
        ),
      ),
    );
  }
}

/// "Wypełnianie w innych aplikacjach" (the menu of "Hasła", Android): what
/// it does, whether it is on, and the way to Android's setting.
Future<void> showPasswordAutofillInfo(BuildContext context) {
  final PasswordAutofillBridge bridge = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(passwordAutofillBridgeProvider);
  final Future<PasswordAutofillState> state = bridge.state();
  return showDialog<void>(
    context: context,
    routeSettings: const RouteSettings(name: kPasswordVaultRouteName),
    builder: (BuildContext context) => FutureBuilder<PasswordAutofillState>(
      future: state,
      builder:
          (BuildContext context, AsyncSnapshot<PasswordAutofillState> snap) {
            final PasswordAutofillState? state = snap.data;
            return AlertDialog(
              key: const Key('autofill-info'),
              scrollable: true,
              title: Text(t('Wypełnianie w innych aplikacjach')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t(
                      'Zen może podpowiadać loginy zapisane w Hasłach w innych '
                      'aplikacjach i w przeglądarkach. Nic nie wypełnia sam: '
                      'najpierw odblokowujesz Zen i potwierdzasz, że to Ty, a '
                      'potem sam wybierasz login. Zen pokazuje tylko loginy '
                      'zapisane dla tej aplikacji albo strony; inne dopiero po '
                      'ostrzeżeniu.',
                    ),
                  ),
                  if (state != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      switch (state) {
                        PasswordAutofillState.unsupported => t(
                          'Ten telefon tego nie obsługuje. Potrzebny jest '
                          'Android 9 lub nowszy.',
                        ),
                        PasswordAutofillState.off => t(
                          'Włączysz to w ustawieniach Androida: wybierz Zen '
                          'jako usługę autouzupełniania.',
                        ),
                        PasswordAutofillState.on => t(
                          'Zen jest usługą autouzupełniania na tym telefonie. '
                          'Wyłączysz to w ustawieniach Androida.',
                        ),
                      },
                      key: Key('autofill-status-${state.name}'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t('Zamknij')),
                ),
                if (state != null && state != PasswordAutofillState.unsupported)
                  FilledButton(
                    key: const Key('autofill-open-settings'),
                    onPressed: () {
                      unawaited(bridge.openSettings());
                      Navigator.of(context).pop();
                    },
                    child: Text(t('Otwórz ustawienia Androida')),
                  ),
              ],
            );
          },
    ),
  );
}
