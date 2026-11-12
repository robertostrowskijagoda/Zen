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
import 'package:zen/src/features/passwords/presentation/password_form_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/secure_screen.dart';

/// What the picker's host (password_autofill_host.dart) and the picker
/// know of one request between them.
final class PasswordAutofillSession {
  /// A new login for the request is being typed: when the request ends
  /// meanwhile, the form stays open, so what was typed can still be saved.
  bool editing = false;

  /// The request ended on the Android side while [editing].
  bool ended = false;

  /// The entry the picker closed with was made for this request just now.
  String? addedId;
}

/// A new login was saved, but the form it was for could no longer be
/// filled.
String passwordAutofillSavedNotFilledText() => t(
  'Login zapisany w Hasłach, ale czas na wypełnienie minął. Spróbuj jeszcze '
  'raz w tamtej aplikacji.',
);

/// The autofill's picker: which login goes into the form of another app or
/// a browser ([request]). It closes with the entry the person tapped, or
/// with null (back, Zen locked).
///
/// Who asked is at the top: the page's host in a browser, or the app's
/// package (with the name it gives itself). The list holds only the entries
/// saved for that app or page ([PasswordVaultService.matchesFor]) that have
/// something the form takes ([PasswordAutofillRequest.canFillWith]). Every
/// other entry is shown only after "Szukaj w hasłach" and a warning: a
/// password given to an app or page it was not saved for is how phishing
/// works. A new login for that app or page is made right here, saved under
/// its address ([PasswordAutofillRequest.newEntryAddress]) and used at once.
/// Like every page of "Hasła", locking Zen closes it.
class PasswordAutofillScreen extends ConsumerStatefulWidget {
  const PasswordAutofillScreen({
    required this.request,
    this.session,
    super.key,
  });

  final PasswordAutofillRequest request;
  final PasswordAutofillSession? session;

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

  /// Whether [e] has anything this form can take. Entries that have not
  /// are left out of the lists: tapping one would fill nothing.
  bool _fills(PasswordEntry e) =>
      widget.request.canFillWith(login: e.login, password: e.password);

  bool get _readOnly => _vault.damaged || _vault.newerFormat;

  /// A new login for this page or app: the entry form, with the name and
  /// the address the request gives; saved, it is used for the request at
  /// once.
  Future<void> _add() async {
    final PasswordAutofillRequest r = widget.request;
    final String? address = r.newEntryAddress;
    final PasswordAutofillSession session =
        widget.session ?? PasswordAutofillSession();
    if (address == null || session.editing) {
      return;
    }
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    session.editing = true;
    unawaited(_bridge.hold(r, on: true));
    final String? id = await pushPasswordPage<String>(
      context,
      PasswordFormScreen(
        initial: PasswordFields(name: r.newEntryName, address: address),
        fixedAddress: true,
        saveLabel: t('Zapisz i użyj'),
      ),
    );
    session.editing = false;
    if (!mounted || _security.isLocked || _closing) {
      return;
    }
    final PasswordEntry? entry = id == null ? null : _vault.entry(id);
    if (session.ended) {
      // The request ended while the login was typed: it is saved all the
      // same, and the person is told the form was not filled.
      if (entry != null) {
        messenger?.showSnackBar(
          SnackBar(content: Text(passwordAutofillSavedNotFilledText())),
        );
      }
      _closeEnded();
      return;
    }
    if (entry != null && _fills(entry)) {
      session.addedId = entry.id;
      Navigator.of(context).pop(entry);
      return;
    }
    unawaited(_bridge.hold(r, on: false));
    if (entry != null) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Login zapisany w Hasłach, ale nie ma w nim nic do wpisania '
              'w tym formularzu.',
            ),
          ),
        ),
      );
    }
  }

  /// The picker of a request that ended: it goes, even under a page that
  /// opened over it meanwhile (a newer request's).
  void _closeEnded() {
    _closing = true;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    final NavigatorState? navigator = _navigator;
    if (route == null || navigator == null || !route.isActive) {
      return;
    }
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Widget _addButton({required bool main}) {
    final bool web = widget.request.isWeb;
    final String label = web
        ? t('Nowy login dla tej strony')
        : t('Nowy login dla tej aplikacji');
    const Icon icon = Icon(Icons.add_rounded);
    void onPressed() => unawaited(_add());
    return Center(
      child: main
          ? FilledButton.icon(
              key: const Key('autofill-add'),
              onPressed: onPressed,
              icon: icon,
              label: Text(label),
            )
          : OutlinedButton.icon(
              key: const Key('autofill-add'),
              onPressed: onPressed,
              icon: icon,
              label: Text(label),
            ),
    );
  }

  /// Under the requester: what only a login form gets, and why nothing new
  /// can be saved in a store that is read-only.
  List<Widget> _notices(ZenColors zen) {
    final PasswordAutofillRequest r = widget.request;
    return <Widget>[
      if (r.hasUsernameField && !r.hasPasswordField)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ZenInfo(
            key: const Key('autofill-login-only'),
            icon: Icons.person_outline_rounded,
            text: t('Tu jest tylko pole loginu: Zen wpisze sam login.'),
          ),
        ),
      if (_vault.damaged)
        ZenInfo(
          key: const Key('autofill-damaged'),
          icon: Icons.report_gmailerrorred_rounded,
          tone: zen.danger,
          title: t('Zapisanych haseł nie da się odczytać'),
          text: t('Zen zostawia je bez zmian i nic do nich nie dopisuje.'),
        )
      else if (_vault.newerFormat)
        ZenInfo(
          key: const Key('autofill-newer'),
          icon: Icons.system_update_rounded,
          tone: zen.warning,
          title: t('Hasła z nowszej wersji Zen'),
          text: t('Zostają bez zmian. Zaktualizuj Zen, żeby z nich korzystać.'),
        ),
    ];
  }

  /// Whether a new login can be made here: the store takes it and the
  /// request has an address to save it under.
  bool get _canAdd => !_readOnly && widget.request.newEntryAddress != null;

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
    final bool none = !found.any((PasswordMatch m) => _fills(m.entry));
    return <Widget>[
      for (final PasswordMatch m in found)
        if (_fills(m.entry))
          _row(zen, m.entry, showAddress: m.kind == PasswordMatchKind.sameSite),
      if (none)
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
      // Nothing saved for it: a new login is what the person most likely
      // came for.
      if (_canAdd) ...<Widget>[
        _addButton(main: none),
        const SizedBox(height: 8),
      ],
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

  List<Widget> _everything(ZenColors zen) {
    final List<PasswordEntry> found = <PasswordEntry>[
      for (final PasswordEntry e in _vault.search(_search.text))
        if (_fills(e)) e,
    ];
    final String query = _search.text.trim();
    return <Widget>[
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
      for (final PasswordEntry e in found) _row(zen, e, showAddress: true),
      if (found.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            query.isEmpty
                ? t('Brak wyników')
                : t('Nic nie pasuje do „{query}”.', <String, Object?>{
                    'query': query,
                  }),
            key: const Key('autofill-search-empty'),
            textAlign: TextAlign.center,
            style: TextStyle(color: zen.textSecondary),
          ),
        ),
      if (_canAdd) ...<Widget>[
        const SizedBox(height: 8),
        _addButton(main: false),
      ],
    ];
  }

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
        ..._notices(zen),
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
      builder: (BuildContext context, AsyncSnapshot<PasswordAutofillState> snap) {
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
                  'najpierw odblokowujesz Zen albo potwierdzasz, że to '
                  'Ty, a potem sam wybierasz login. Zen pokazuje tylko loginy '
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
