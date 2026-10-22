import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/core/utils/system_actions.dart';

/// The install page on GitHub Pages (`tool/pages/install`): the steps for
/// every system, the downloads and, for iPhone, the one-tap SideStore
/// source.
const String kInstallPageUrl = '${kZenPagesBase}install/';

/// The AltStore / SideStore source of the latest release (`apps.json`,
/// made by `.github/workflows/pages.yml`).
const String kSideStoreSourceUrl = '${kZenPagesBase}apps.json';

/// The systems Zen is installed on, each with its own steps.
enum InstallSystem {
  android('Android', Icons.android_rounded),
  iphone('iPhone', Icons.phone_iphone_rounded),
  windows('Windows', Icons.desktop_windows_rounded),
  macos('Mac', Icons.laptop_mac_rounded),
  linux('Linux', Icons.computer_rounded);

  const InstallSystem(this.label, this.icon);

  /// The system's own name (the same in every language).
  final String label;
  final IconData icon;

  /// This device's system (the guide opens on it).
  static InstallSystem get current {
    if (kIsWeb) {
      return InstallSystem.android;
    }
    if (Platform.isIOS) {
      return InstallSystem.iphone;
    }
    if (Platform.isWindows) {
      return InstallSystem.windows;
    }
    if (Platform.isMacOS) {
      return InstallSystem.macos;
    }
    if (Platform.isLinux) {
      return InstallSystem.linux;
    }
    return InstallSystem.android;
  }
}

/// One step of the guide: what to do and, for a terminal, the command.
@immutable
final class InstallStep {
  const InstallStep(this.text, {this.command});

  final String text;
  final String? command;
}

/// The steps for [system], as short as they can be (the same as on the
/// install page).
List<InstallStep> installStepsFor(InstallSystem system) => switch (system) {
  InstallSystem.android => <InstallStep>[
    InstallStep(
      t('Na stronie instalacji (kod QR wyżej) stuknij „Pobierz Zen”.'),
    ),
    InstallStep(
      t(
        'Otwórz pobrany plik. Jeśli telefon zapyta, pozwól przeglądarce '
        'instalować aplikacje i wróć.',
      ),
    ),
    InstallStep(
      t(
        'Stuknij „Zainstaluj”. Przy ostrzeżeniu Play Protect: „Więcej '
        'szczegółów → Zainstaluj mimo to”.',
      ),
    ),
  ],
  InstallSystem.iphone => <InstallStep>[
    InstallStep(
      t('Na iPhonie zainstaluj z App Store darmową aplikację LocalDevVPN.'),
    ),
    InstallStep(
      t(
        'Na komputerze (Windows, Mac albo Linux) pobierz iloader z instrukcji '
        'SideStore i podłącz iPhone’a kablem.',
      ),
    ),
    InstallStep(
      t('W iloader zaloguj się swoim Apple ID i wybierz „Install SideStore”.'),
    ),
    InstallStep(
      t(
        'Na iPhonie: Ustawienia → Prywatność i ochrona → Tryb dewelopera → '
        'włącz i potwierdź po ponownym uruchomieniu.',
      ),
    ),
    InstallStep(
      t(
        'Ustawienia → Ogólne → VPN i zarządzanie urządzeniem → Twoje '
        'Apple ID → Ufaj.',
      ),
    ),
    InstallStep(
      t('Połącz LocalDevVPN, otwórz SideStore i zaloguj się Apple ID.'),
    ),
    InstallStep(
      t(
        'Dodaj źródło Zen: przycisk na stronie instalacji albo w SideStore '
        'Sources → + i adres niżej.',
      ),
    ),
    InstallStep(t('W SideStore otwórz Zen i stuknij „Install”.')),
  ],
  InstallSystem.windows => <InstallStep>[
    InstallStep(
      t(
        'Pobierz Zen-Windows.zip ze strony instalacji (komputery ARM: '
        'Zen-Windows-arm64.zip) i rozpakuj.',
      ),
    ),
    InstallStep(
      t(
        'Uruchom zen.exe. Jeśli SmartScreen ostrzega: „Więcej informacji → '
        'Uruchom mimo to”.',
      ),
    ),
  ],
  InstallSystem.macos => <InstallStep>[
    InstallStep(
      t(
        'Pobierz Zen-macOS.zip ze strony instalacji, otwórz i przeciągnij Zen '
        'do Aplikacji.',
      ),
    ),
    InstallStep(
      t('Pierwsze uruchomienie: prawy klik na Zen → Otwórz → Otwórz.'),
    ),
  ],
  InstallSystem.linux => <InstallStep>[
    InstallStep(
      t('Debian, Ubuntu, Mint: pobierz Zen-Linux-x64.deb i wpisz:'),
      command: 'sudo apt install ./Zen-Linux-x64.deb',
    ),
    InstallStep(
      t('Inne dystrybucje: pobierz Zen-Linux-x64.flatpak i wpisz:'),
      command: 'flatpak install --user ./Zen-Linux-x64.flatpak',
    ),
  ],
};

/// What is good to know about [system], after the steps.
List<String> installNotesFor(InstallSystem system) => switch (system) {
  InstallSystem.android => <String>[
    t(
      'Aktualizacje same: w darmowej aplikacji Obtainium dodaj '
      'github.com/robertostrowskijagoda/Zen (przycisk na stronie '
      'instalacji). Telefon obok możesz też poczęstować Zen stąd, przez '
      'Wi-Fi albo Quick Share.',
    ),
  ],
  InstallSystem.iphone => <String>[
    t(
      'iPhone nie pozwala aplikacji instalować innych aplikacji, dlatego '
      'potrzebny jest SideStore i raz komputer. Podpis Zen wygasa po 7 '
      'dniach: raz w tygodniu włącz LocalDevVPN, otwórz SideStore i stuknij '
      '„Odśwież”. Zen przypomni o tym 2 dni wcześniej.',
    ),
    t(
      'Darmowe Apple ID: 3 takie aplikacje naraz (SideStore się liczy). '
      'W UE AltStore PAL przyjmuje tylko aplikacje poświadczone przez '
      'Apple — Zena tam jeszcze nie ma.',
    ),
  ],
  InstallSystem.windows => <String>[
    t('Zen aktualizuje się sam: sprawdza GitHuba i pyta przed aktualizacją.'),
  ],
  InstallSystem.macos => <String>[
    t('Zen aktualizuje się sam: sprawdza GitHuba i pyta przed aktualizacją.'),
  ],
  InstallSystem.linux => <String>[
    t(
      'Albo plik .tar.gz: rozpakuj i uruchom Zen/zen. Potrzebny jest GNOME '
      'Keyring albo KWallet.',
    ),
  ],
};

/// "Jak zainstalować Zen": the steps for another phone or computer, with
/// a QR code to the install page (where the downloads and the one-tap
/// SideStore source are) and a picker of systems.
class InstallGuideScreen extends StatefulWidget {
  const InstallGuideScreen({this.initial, super.key});

  /// The system shown first (this device's when `null`).
  final InstallSystem? initial;

  static Future<void> open(BuildContext context, {InstallSystem? initial}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              InstallGuideScreen(initial: initial),
        ),
      );

  @override
  State<InstallGuideScreen> createState() => _InstallGuideScreenState();
}

class _InstallGuideScreenState extends State<InstallGuideScreen> {
  late InstallSystem _system = widget.initial ?? InstallSystem.current;
  String? _message;

  Future<void> _copy(String text) async {
    await copyWithExpiry(text);
    if (mounted) {
      setState(() => _message = t('Skopiowano: {text}', {'text': text}));
    }
  }

  Future<void> _openPage() async {
    final bool opened = await openWebLink(kInstallPageUrl);
    if (!opened) {
      await _copy(kInstallPageUrl);
    }
  }

  Widget _link(ZenColors zen, String url, Key key) => Row(
    children: <Widget>[
      Expanded(
        child: SelectableText(
          url,
          style: TextStyle(
            fontFamily: 'JetBrains Mono',
            fontSize: 13,
            color: zen.textSecondary,
          ),
        ),
      ),
      IconButton(
        key: key,
        tooltip: t('Kopiuj'),
        onPressed: () => unawaited(_copy(url)),
        icon: const Icon(Icons.copy_rounded),
      ),
    ],
  );

  Widget _step(ZenColors zen, int number, InstallStep step) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CircleAvatar(
          radius: 14,
          backgroundColor: zen.accent.withValues(alpha: 0.16),
          child: Text(
            '$number',
            style: TextStyle(color: zen.accent, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  step.text,
                  style: TextStyle(color: zen.textPrimary, height: 1.4),
                ),
              ),
              if (step.command != null)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsetsDirectional.only(start: 10),
                  decoration: BoxDecoration(
                    color: zen.surfaceSunk,
                    borderRadius: context.zenRadius(12),
                  ),
                  child: _link(
                    zen,
                    step.command!,
                    Key('install-copy-command-$number'),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zen.tone(ZenTone.people);
    final List<InstallStep> steps = installStepsFor(_system);
    return Scaffold(
      key: const Key('install-guide-screen'),
      appBar: AppBar(title: Text(t('Jak zainstalować Zen'))),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenHero(
              title: t('Zen na innym telefonie albo komputerze'),
              icon: Icons.install_mobile_rounded,
              tone: tone,
              text: t(
                'Znajomy skanuje ten kod aparatem: otworzy się strona z '
                'instrukcją dla jego systemu i plikami do pobrania. Możesz '
                'też przeprowadzić go krok po kroku niżej.',
              ),
            ),
            const SizedBox(height: 12),
            ZenCard(
              child: Column(
                children: <Widget>[
                  Center(
                    // QR codes stay black on white, so every camera reads
                    // them.
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ZenFixed.qrPaper,
                        borderRadius: context.zenRadius(20),
                      ),
                      child: QrImageView(
                        key: const Key('install-page-qr'),
                        data: kInstallPageUrl,
                        size: 180,
                        backgroundColor: ZenFixed.qrPaper,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _link(zen, kInstallPageUrl, const Key('install-copy-page')),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const Key('install-open-page'),
                      onPressed: () => unawaited(_openPage()),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: Text(t('Otwórz stronę instalacji')),
                    ),
                  ),
                ],
              ),
            ),
            ZenSection(t('Na jakim systemie?'), top: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final InstallSystem s in InstallSystem.values)
                  ChoiceChip(
                    key: Key('install-system-${s.name}'),
                    avatar: Icon(s.icon, size: 18),
                    label: Text(s.label),
                    selected: s == _system,
                    onSelected: (_) => setState(() => _system = s),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ZenCard(
              key: Key('install-steps-${_system.name}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < steps.length; i++)
                    _step(zen, i + 1, steps[i]),
                ],
              ),
            ),
            if (_system == InstallSystem.iphone) ...<Widget>[
              ZenSection(t('Źródło Zen dla SideStore'), top: 16),
              ZenCard(
                child: _link(
                  zen,
                  kSideStoreSourceUrl,
                  const Key('install-copy-source'),
                ),
              ),
            ],
            for (final String note in installNotesFor(_system))
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ZenInfo(tone: tone, text: note),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _message!,
                  key: const Key('install-message'),
                  style: TextStyle(color: zen.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
