import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';
import 'package:zen/src/features/passwords/password_setup.dart';
import 'package:zen/src/features/passwords/presentation/password_import.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';

/// "Konfiguracja haseł" (a button in "Hasła"): the setup of the password
/// manager as a page of "Hasła", closed with them when Zen locks.
class PasswordSetupScreen extends ConsumerWidget {
  const PasswordSetupScreen({this.withImport = false, super.key});

  /// The import from a browser's file is offered at the end ("Hasła" is
  /// open and can take it).
  final bool withImport;

  static Future<void> open(BuildContext context, {bool withImport = false}) =>
      pushPasswordPage<void>(
        context,
        PasswordSetupScreen(withImport: withImport),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool android = ref
        .watch(passwordSetupPlatformProvider)
        .fillsOtherApps;
    return Scaffold(
      key: const Key('password-setup-screen'),
      appBar: AppBar(title: Text(t('Konfiguracja haseł'))),
      body: SafeArea(
        top: false,
        child: passwordPageColumn(
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenHero(
                title: t('Menedżer haseł'),
                icon: Icons.key_rounded,
                text: android
                    ? t(
                        'Ustaw raz, a Zen będzie podpowiadał loginy w innych '
                        'aplikacjach i w przeglądarkach.',
                      )
                    : t('Jak korzystać z haseł Zen na tym urządzeniu.'),
              ),
              PasswordSetupPanel(
                onImport: withImport
                    ? () => unawaited(importPasswordFile(context, ref))
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The setup itself, the same in "Hasła" and in the first-start setup: on
/// Android whether Zen is the phone's autofill service and what each
/// installed browser needs, read again whenever the person comes back to
/// Zen (from the settings it opened); elsewhere, honestly, how the
/// passwords are used there. [onImport], when given, ends it with the
/// import from a browser's file.
class PasswordSetupPanel extends ConsumerStatefulWidget {
  const PasswordSetupPanel({this.onImport, super.key});

  final VoidCallback? onImport;

  @override
  ConsumerState<PasswordSetupPanel> createState() => _PasswordSetupPanelState();
}

class _PasswordSetupPanelState extends ConsumerState<PasswordSetupPanel>
    with WidgetsBindingObserver {
  late final PasswordSetupPlatform _platform = ref.read(
    passwordSetupPlatformProvider,
  );
  PasswordSetupState? _state;

  /// Only the newest read is shown (an older one may answer later).
  int _reads = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Android's or a browser's settings: what changed there.
    if (state == AppLifecycleState.resumed) {
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    final int read = ++_reads;
    final PasswordSetupState next = await readPasswordSetup(_platform);
    if (mounted && read == _reads) {
      setState(() => _state = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PasswordSetupState? state = _state;
    return Column(
      key: const Key('password-setup'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (state == null)
          Padding(
            key: const Key('password-setup-loading'),
            padding: const EdgeInsets.all(24),
            child: Center(
              child: SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: zen.accent,
                ),
              ),
            ),
          )
        else
          ..._section(zen, state),
        if (widget.onImport case final VoidCallback onImport)
          _import(zen, onImport),
      ],
    );
  }

  /// The section of this system. Each system has its own: one that comes
  /// to fill other apps gets a section of its own here in place of
  /// [_elsewhere].
  List<Widget> _section(ZenColors zen, PasswordSetupState state) =>
      state.supported ? _android(zen, state) : <Widget>[_elsewhere(zen, state)];

  /// Android 9+: the system's setting, the browsers, and what a fill looks
  /// like.
  List<Widget> _android(ZenColors zen, PasswordSetupState state) => <Widget>[
    _system(zen, state),
    ..._browsers(zen, state),
    const SizedBox(height: 4),
    ZenInfo(
      key: const Key('password-setup-how'),
      icon: Icons.touch_app_outlined,
      title: t('Jak to wygląda'),
      text: t(
        'Przy polu logowania pojawi się podpowiedź Zen. Dotknij jej, '
        'odblokuj Zen i wybierz login — Zen wpisze go w formularz.',
      ),
    ),
  ];

  /// Not Android, or an Android where Zen cannot fill other apps.
  Widget _elsewhere(ZenColors zen, PasswordSetupState state) => ZenCard(
    key: const Key('password-setup-elsewhere'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          state.fillsOtherApps
              ? t(
                  'Ten telefon tego nie obsługuje. Potrzebny jest Android 9 lub '
                  'nowszy.',
                )
              : t(
                  'Na tym urządzeniu Zen nie wypełnia formularzy w innych '
                  'aplikacjach ani w przeglądarkach.',
                ),
          style: TextStyle(
            color: zen.textPrimary,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 8),
        _paragraph(
          zen,
          t(
            'Otwórz wpis w Hasłach i skopiuj login albo hasło. Skopiowane '
            'znikają ze schowka po 30 sekundach i gdy Zen się zablokuje.',
          ),
        ),
        const SizedBox(height: 6),
        _paragraph(
          zen,
          t(
            'Hasła są takie same na wszystkich urządzeniach Twojego konta: na '
            'telefonie z Androidem 9 lub nowszym Zen podpowie je w '
            'formularzach.',
          ),
        ),
      ],
    ),
  );

  Widget _paragraph(ZenColors zen, String text, {Key? key}) => Text(
    text,
    key: key,
    style: TextStyle(color: zen.textSecondary, fontSize: 13.5, height: 1.35),
  );

  Widget _title(ZenColors zen, String text, {Widget? state}) => Row(
    children: <Widget>[
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: zen.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
      ?state,
    ],
  );

  /// Android's own setting: is Zen the autofill service.
  Widget _system(ZenColors zen, PasswordSetupState state) {
    final bool on = state.autofill == PasswordAutofillState.on;
    return ZenCard(
      key: const Key('password-setup-system'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _title(
            zen,
            t('Usługa autouzupełniania Androida'),
            state: _StateBadge(
              key: Key('password-setup-system-${on ? 'on' : 'off'}'),
              state: on ? BrowserSwitchState.on : BrowserSwitchState.off,
            ),
          ),
          const SizedBox(height: 6),
          _paragraph(
            zen,
            on
                ? t('Zen jest usługą autouzupełniania na tym telefonie.')
                : t(
                    'Wybierz Zen jako usługę autouzupełniania w ustawieniach '
                    'Androida. Bez tego żadna aplikacja ani przeglądarka nie '
                    'zapyta Zen o login.',
                  ),
            key: const Key('password-setup-system-line'),
          ),
          const SizedBox(height: 8),
          on
              ? OutlinedButton.icon(
                  key: const Key('password-setup-system-open'),
                  onPressed: () => unawaited(_platform.openAutofillSettings()),
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(t('Otwórz ustawienia Androida')),
                )
              : FilledButton.icon(
                  key: const Key('password-setup-system-open'),
                  onPressed: () => unawaited(_platform.openAutofillSettings()),
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(t('Otwórz ustawienia Androida')),
                ),
        ],
      ),
    );
  }

  List<Widget> _browsers(ZenColors zen, PasswordSetupState state) {
    final bool englishWords = state.browsers.any(
      (BrowserSetup b) =>
          b.needsAction || b.needs == BrowserAutofillNeeds.unverified,
    );
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
        child: Text(t('Przeglądarki'), style: zen.label(color: zen.textMuted)),
      ),
      if (state.browsers.isEmpty)
        ZenCard(
          key: const Key('password-setup-no-browsers'),
          child: _paragraph(
            zen,
            t(
              'Nie znaleziono przeglądarki, którą Zen zna. W innej poszukaj w '
              'ustawieniach autouzupełniania („Autofill”).',
            ),
          ),
        ),
      for (final BrowserSetup b in state.browsers) _browser(zen, b),
      if (englishWords)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
          child: Text(
            t(
              'W cudzysłowie: słowa z angielskiej wersji przeglądarki. Po '
              'polsku brzmią podobnie.',
            ),
            key: const Key('password-setup-english-note'),
            style: TextStyle(color: zen.textMuted, fontSize: 12),
          ),
        ),
    ];
  }

  Widget _browser(ZenColors zen, BrowserSetup b) {
    final String id = b.browser.packageName;
    final BrowserSwitchState? state = b.state;
    final String? steps = b.needsAction ? b.steps : null;
    return ZenCard(
      key: Key('password-setup-browser-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _title(
            zen,
            b.name,
            state: state == null
                ? null
                : _StateBadge(
                    key: Key('password-setup-browser-state-$id-${state.name}'),
                    state: state,
                  ),
          ),
          const SizedBox(height: 6),
          _paragraph(zen, b.line, key: Key('password-setup-browser-line-$id')),
          if (steps != null) ...<Widget>[
            const SizedBox(height: 6),
            _paragraph(
              zen,
              steps,
              key: Key('password-setup-browser-steps-$id'),
            ),
          ],
          if (b.canOpenSettings) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: Key('password-setup-browser-open-$id'),
              onPressed: () => unawaited(_platform.openBrowserSettings(id)),
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(t('Otwórz ustawienia przeglądarki')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _import(ZenColors zen, VoidCallback onImport) => ZenCard(
    key: const Key('password-setup-import'),
    margin: const EdgeInsets.only(top: 14, bottom: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _title(zen, t('Masz hasła w przeglądarce?')),
        const SizedBox(height: 6),
        _paragraph(
          zen,
          t(
            'Wyeksportuj je z przeglądarki do pliku CSV i zaimportuj do Zen. '
            'Ten krok jest dobrowolny.',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('password-setup-import-button'),
          onPressed: onImport,
          icon: const Icon(Icons.upload_file_rounded),
          label: Text(t('Importuj z pliku CSV')),
        ),
      ],
    ),
  );
}

/// "Włączone", "Wyłączone" or "Nie wiadomo", told by the word, not by
/// colour alone.
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state, super.key});

  final BrowserSwitchState state;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final (String text, Color tone) = switch (state) {
      BrowserSwitchState.on => (t('Włączone'), zen.success),
      BrowserSwitchState.off => (t('Wyłączone'), zen.warning),
      BrowserSwitchState.unknown => (t('Nie wiadomo'), zen.textMuted),
    };
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: zen.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
