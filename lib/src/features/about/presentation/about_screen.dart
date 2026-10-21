import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/about/presentation/legal_document_screen.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/presentation/page_title.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/update/presentation/own_copy_card.dart';
import 'package:zen/src/features/update/presentation/share_app_screen.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';
import 'package:zen/src/features/update/store_build.dart';

/// Where donations for Zen go (the only official collection).
const String kDonationUrl = 'https://buycoffee.to/zen';

/// The privacy policy and the terms of use (English, in the repository).
const String kPrivacyPolicyUrl =
    'https://github.com/robertostrowskijagoda/Zen/blob/main/docs/PRIVACY.md';
const String kTermsOfUseUrl =
    'https://github.com/robertostrowskijagoda/Zen/blob/main/docs/TERMS.md';

/// The Yggdrasil project (the network Zen runs on).
const String kYggdrasilUrl = 'https://yggdrasil-network.github.io/';

/// Where public Yggdrasil nodes are listed (Zen's builds take theirs from
/// here).
const String kYggdrasilPublicPeersUrl =
    'https://github.com/yggdrasil-network/public-peers';

/// Where bugs are reported.
const String kIssuesUrl = 'https://github.com/robertostrowskijagoda/Zen/issues';

/// "O aplikacji": a header (name, version, build, the author's notice), one
/// short description, and the sections, each on its own page.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, this.storeBuild});

  /// Whether to say this is the store build (default: [isStoreBuild]).
  /// This screen is the only place that says it (the launcher and the rest
  /// of the app just say "Zen").
  final bool? storeBuild;

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const AboutScreen(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('about-screen'),
      appBar: ZenSectionBar(title: t('O aplikacji')),
      body: SelectionArea(
        child: ListView(
          key: const Key('about-list'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            _LogoCard(storeBuild: storeBuild ?? isStoreBuild),
            const SizedBox(height: 14),
            Text(
              t(
                'Komunikator i sieć dla ludzi, którzy się znają — bez '
                'serwerów, reklam i algorytmu. Wiadomości, zdjęcia i posty '
                'idą wprost między urządzeniami znajomych, zaszyfrowane.',
              ),
              key: const Key('about-description'),
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 14.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ZenPill(
                  text: t('Bez serwerów'),
                  tone: zenTone(zen, 0),
                  icon: Icons.hub_rounded,
                ),
                ZenPill(
                  text: t('Bez reklam'),
                  tone: zenTone(zen, 1),
                  icon: Icons.block_rounded,
                ),
                ZenPill(
                  text: t('Bez algorytmu'),
                  tone: zenTone(zen, 2),
                  icon: Icons.timeline_rounded,
                ),
                ZenPill(
                  text: t('Szyfrowane'),
                  tone: zen.success,
                  icon: Icons.lock_rounded,
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final AboutSection section in AboutSection.values)
              _SectionTile(section: section),
          ],
        ),
      ),
    );
  }
}

/// The sections of "O aplikacji", in their order; each opens its page.
enum AboutSection {
  intro,
  updates,
  security,
  licences,
  documents,
  contact,
  support;

  String get title => switch (this) {
    AboutSection.intro => t('Czym jest Zen'),
    AboutSection.updates => t('Wersja i aktualizacje'),
    AboutSection.security => t('Bezpieczeństwo i prywatność'),
    AboutSection.licences => t('Licencje i podziękowania'),
    AboutSection.documents => t('Dokumenty'),
    AboutSection.contact => t('Kontakt i zgłaszanie błędów'),
    AboutSection.support => t('Wesprzyj Zen'),
  };

  String get subtitle => switch (this) {
    AboutSection.intro => t('Po co, jak używać, na czym działa, kto to robi'),
    AboutSection.updates => t(
      'Nowe wersje, Podaj dalej, platformy, dlaczego nie ma Zen w sklepach',
    ),
    AboutSection.security => t(
      'Szyfrowanie, odzyskiwanie konta, jak sprawdzić, że to nie wirus',
    ),
    AboutSection.licences => t(
      'GPL-3.0, biblioteki i projekty, na których stoi Zen',
    ),
    AboutSection.documents => t('Regulamin, polityka prywatności, licencja'),
    AboutSection.contact => t('Błędy, pytania, kod źródłowy'),
    AboutSection.support => t('Zen jest za darmo i bez reklam'),
  };

  IconData get icon => switch (this) {
    AboutSection.intro => Icons.auto_awesome_rounded,
    AboutSection.updates => Icons.system_update_alt_rounded,
    AboutSection.security => Icons.shield_outlined,
    AboutSection.licences => Icons.description_outlined,
    AboutSection.documents => Icons.gavel_rounded,
    AboutSection.contact => Icons.bug_report_outlined,
    AboutSection.support => Icons.volunteer_activism_rounded,
  };

  Widget page() => switch (this) {
    AboutSection.intro => const _IntroPage(),
    AboutSection.updates => const _UpdatesPage(),
    AboutSection.security => const _SecurityPage(),
    AboutSection.licences => const _LicencesPage(),
    AboutSection.documents => const _DocumentsPage(),
    AboutSection.contact => const _ContactPage(),
    AboutSection.support => const _SupportPage(),
  };
}

/// One row of the main page: icon, title and what is inside, wrapping in
/// every language (nothing is cut).
class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section});

  final AboutSection section;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      key: Key('about-section-${section.name}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      onTap: () => unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                _AboutPage(title: section.title, child: section.page()),
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          ZenIconBadge(
            icon: section.icon,
            tone: zenTone(zen, section.index),
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  section.title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  section.subtitle,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: zen.textMuted),
        ],
      ),
    );
  }
}

/// A section's own page: its title and its content, selectable.
class _AboutPage extends StatelessWidget {
  const _AboutPage({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('about-page'),
      appBar: AppBar(title: PageTitle(title)),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            key: const Key('about-page-body'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: <Widget>[child],
          ),
        ),
      ),
    );
  }
}

/// A paragraph of one of the pages.
class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      child: Text(
        text,
        style: TextStyle(color: zen.textSecondary, fontSize: 14.5, height: 1.5),
      ),
    );
  }
}

/// A link row: what it is and where it goes; opens the browser (or copies
/// the address).
class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tone,
    this.url,
    this.onTap,
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color tone;
  final String? url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String? link = url;
    return ZenCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      onTap:
          onTap ??
          (link == null
              ? null
              : () => unawaited(openOrCopyLink(context, link))),
      child: Row(
        children: <Widget>[
          ZenIconBadge(icon: icon, tone: tone, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
          Icon(
            link != null && onTap == null
                ? Icons.open_in_new_rounded
                : Icons.chevron_right_rounded,
            color: zen.textMuted,
            size: link != null && onTap == null ? 20 : 24,
          ),
        ],
      ),
    );
  }
}

/// "Czym jest Zen": what, why, how to use it, what it runs on, who makes it.
class _IntroPage extends StatelessWidget {
  const _IntroPage();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Paragraph(
          t(
            'Zen to komunikator i sieć dla ludzi, którzy się znają — ale bez '
            'firmy pośrodku. Nie ma serwera, który wszystko widzi, nie ma '
            'reklam ani algorytmu, który decyduje, co zobaczysz. Wiadomości, '
            'zdjęcia i posty idą wprost między telefonami i komputerami '
            'znajomych, zaszyfrowane, a dane zostają na Twoim urządzeniu.\n\n'
            'Poza czatami i połączeniami Zen pomaga spotykać się naprawdę: '
            'status „na teraz”, wydarzenia i kolacje przez znajomych, sąsiedzi '
            'z bloku, randki przez wspólnych znajomych, pomoc od najbliższych '
            'i alarm. A „piramida” pozwala ludziom samym organizować się i '
            'decydować — oddolnie, bez partii i instytucji z góry.',
          ),
        ),
        ZenSection(t('Jak używać')),
        ZenCard(
          key: const Key('about-how-to'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Step(
                n: 1,
                tone: zenTone(zen, 0),
                title: t('Dodaj znajomego'),
                text: t(
                  'W Ustawieniach (pasek u góry) wybierz „Zaproś”, pokaż swój '
                  'kod QR, a znajomy niech go zeskanuje (albo odwrotnie). Nie '
                  'trzeba numeru telefonu ani e-maila.',
                ),
              ),
              _Step(
                n: 2,
                tone: zenTone(zen, 2),
                title: t('Pisz i dzwoń'),
                text: t(
                  'Czaty, grupy, połączenia audio i wideo — wszystko zaszyfrowane, prosto między Wami.',
                ),
              ),
              _Step(
                n: 3,
                tone: zenTone(zen, 5),
                title: t('Umawiaj się'),
                text: t(
                  'Ustaw status „na teraz” (np. Idę na spacer), zrób wydarzenie albo zajrzyj, kto z Twoich znajomych jest wolny.',
                ),
              ),
              _Step(
                n: 4,
                tone: zenTone(zen, 4),
                title: t('Poznawaj przez znajomych'),
                text: t(
                  'Znajomi znajomych pojawiają się sami na grafie i w wydarzeniach — a przez „Sąsiadów” i „Randki” poznajesz nowych ludzi bezpiecznie.',
                ),
                last: true,
              ),
            ],
          ),
        ),
        ZenSection(t('Po co to jest')),
        ZenInfo(
          icon: Icons.public_rounded,
          tone: zenTone(zen, 0),
          title: t('Oddać ludziom ich sieć'),
          text: t(
            'Dzisiejsze sieci należą do firm, które zarabiają na Twojej uwadze i '
            'danych, i podsuwają to, co je dłużej zatrzyma przy ekranie. Zen jest '
            'odwrotnością: żadnego właściciela, żadnego algorytmu, który Tobą '
            'steruje. Technologia ma robić jedno — pomagać ludziom, którzy się '
            'znają, trzymać się razem i spotykać naprawdę.',
          ),
        ),
        ZenInfo(
          icon: Icons.how_to_vote_rounded,
          tone: zenTone(zen, 3),
          title: t('Także nowa polityka'),
          text: t(
            'Zen ma zmienić nie tylko media społecznościowe, ale i sposób, w jaki '
            'ludzie podejmują wspólne decyzje. „Piramida” buduje się z komórek po '
            'kilka osób, które znają się osobiście; głosy, delegowanie zaufania i '
            'wspólna kasa płyną oddolnie, anonimowo wobec reszty, bez centrali, '
            'którą dałoby się przekupić albo wyłączyć. To próba demokracji, która '
            'naprawdę należy do ludzi.',
          ),
        ),
        ZenSection(t('Na czym to zbudowane')),
        ZenInfo(
          icon: Icons.lan_rounded,
          tone: zenTone(zen, 0),
          title: t('Sieć Yggdrasil'),
          text: t(
            'Zen nie ma własnych serwerów. Telefony i komputery łączą się '
            'przez Yggdrasil — otwartą, szyfrowaną sieć, w której każde '
            'urządzenie ma swój adres, a ruch idzie wprost albo przez inne '
            'urządzenia, które nie widzą treści. Bezpośrednie wiadomości są '
            'szyfrowane end-to-end przez samą sieć Yggdrasil. Własne '
            'szyfrowanie Zen dokłada tam, gdzie treść leży poza tym '
            'połączeniem: w kopiach u znajomych (skrzynka), we wpisach '
            'dla wybranych odbiorców, w randkach i podobnych miejscach.',
          ),
        ),
        ZenSection(t('Własny most Yggdrasil')),
        ZenCard(
          key: const Key('about-own-bridge'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                t(
                  'Dla zaawansowanych. Zen na komputerze sam pomaga innym się '
                  'łączyć, gdy router na to pozwala. Możesz też postawić stały '
                  'most bez Zen: zwykły węzeł Yggdrasil, który działa całą '
                  'dobę. Pomaga wszystkim, nie tylko Twoim znajomym, i nie '
                  'widzi treści wiadomości.',
                ),
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 14.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              _Step(
                n: 1,
                tone: zenTone(zen, 0),
                title: t('Komputer, który stale działa'),
                text: t(
                  'Serwer VPS albo domowy komputer czy Raspberry Pi. Musi '
                  'mieć publiczny adres IP — w domu przekieruj port w '
                  'routerze.',
                ),
              ),
              _Step(
                n: 2,
                tone: zenTone(zen, 0),
                title: t('Zainstaluj Yggdrasil'),
                text: t(
                  'Paczki i instrukcje dla Linuksa, Windows, macOS i '
                  'routerów są na stronie projektu (link niżej). Plik '
                  'ustawień tworzy polecenie yggdrasil -genconf.',
                ),
              ),
              _Step(
                n: 3,
                tone: zenTone(zen, 0),
                title: t('Otwórz nasłuch'),
                text: t(
                  'W pliku yggdrasil.conf wpisz w Listen np. '
                  'tls://0.0.0.0:443, a w Peers kilka publicznych węzłów. '
                  'Uruchom usługę ponownie i otwórz ten port w zaporze.',
                ),
              ),
              _Step(
                n: 4,
                tone: zenTone(zen, 0),
                title: t('Zgłoś go jako publiczny'),
                text: t(
                  'Dopisz jego adres do listy publicznych węzłów '
                  '(github.com/yggdrasil-network/public-peers). Zen bierze '
                  'węzły z tej listy, więc kolejne wersje Zen połączą się '
                  'także przez Twój most.',
                ),
                last: true,
              ),
            ],
          ),
        ),
        _LinkTile(
          key: const Key('about-yggdrasil-site'),
          icon: Icons.open_in_new_rounded,
          tone: zenTone(zen, 0),
          title: t('Strona Yggdrasil'),
          subtitle: t('yggdrasil-network.github.io — instalacja i ustawienia'),
          url: kYggdrasilUrl,
        ),
        _LinkTile(
          key: const Key('about-public-peers'),
          icon: Icons.public_rounded,
          tone: zenTone(zen, 0),
          title: t('Lista publicznych węzłów'),
          subtitle: 'github.com/yggdrasil-network/public-peers',
          url: kYggdrasilPublicPeersUrl,
        ),
        ZenSection(t('Kto to robi')),
        const _AuthorCard(),
      ],
    );
  }
}

/// "Wersja i aktualizacje": this copy, new versions, passing Zen on, the
/// platforms and why there is no store.
class _UpdatesPage extends StatelessWidget {
  const _UpdatesPage();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenCard(
          key: const Key('about-version'),
          child: Text(
            t('Wersja {version} · kompilacja {build}', {
              'version': kAppVersion,
              'build': kAppBuild,
            }),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _LinkTile(
          key: const Key('about-updates'),
          icon: Icons.system_update_alt_rounded,
          tone: zenTone(zen, 5),
          title: t('Aktualizacje'),
          subtitle: t('Nowe wersje z GitHuba i od znajomych'),
          onTap: () => unawaited(UpdatesScreen.open(context)),
        ),
        _LinkTile(
          key: const Key('about-share-app'),
          icon: Icons.install_mobile_rounded,
          tone: zen.success,
          title: t('Podaj Zen dalej'),
          subtitle: t('Wyślij aplikację znajomemu z ręki do ręki, bez sklepu'),
          onTap: () => unawaited(ShareAppScreen.open(context)),
        ),
        _LinkTile(
          key: const Key('about-repository'),
          icon: Icons.code_rounded,
          tone: zenTone(zen, 6),
          title: t('Oficjalna strona projektu'),
          subtitle: 'github.com/robertostrowskijagoda/Zen',
          url: PeerShareCodec.repositoryUrl,
        ),
        ZenSection(t('Na czym działa')),
        ZenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Platform(
                icon: Icons.android_rounded,
                tone: zen.success,
                name: 'Android',
                note: t('Gotowe — telefon i tablet.'),
              ),
              _Platform(
                icon: Icons.desktop_windows_rounded,
                tone: zenTone(zen, 0),
                name: 'Windows',
                note: t('Gotowe — pełna wersja na komputer.'),
              ),
              _Platform(
                icon: Icons.laptop_mac_rounded,
                tone: zenTone(zen, 5),
                name: t('macOS i Linux'),
                note: t('W planie — ten sam rdzeń, co na Windows.'),
              ),
              _Platform(
                icon: Icons.phone_iphone_rounded,
                tone: zenTone(zen, 3),
                name: t('iPhone i iPad'),
                note: t(
                  'Przez SideStore albo AltStore, z darmowym Apple ID '
                  '(instrukcja na GitHubie). iOS nie pozwala na pracę w '
                  'tle, więc wiadomości dochodzą przy otwartym Zen.',
                ),
                last: true,
              ),
            ],
          ),
        ),
        ZenSection(t('Dlaczego nie ma Zen w sklepach')),
        _Paragraph(
          t(
            'Zen celowo nie jest w Google Play ani w App Store. Sklep może w '
            'każdej chwili usunąć aplikację albo zażądać zmian — a Zen ma być '
            'niezależny, także od wielkich firm i od polityki. Sklepy wymagają '
            'też firmy, opłat i zgody na swoje zasady, a Zen tworzy jedna '
            'osoba, za darmo. Przy okazji nikt, nawet sklep, nie wie, że '
            'masz Zen.\n\n'
            'Dlatego Zen pobierasz z oficjalnej strony projektu na GitHubie '
            'albo dostajesz od znajomego („Podaj dalej”).',
          ),
        ),
      ],
    );
  }
}

/// "Bezpieczeństwo i prywatność": how the data is protected, recovering the
/// account, and how to check this copy is genuine.
class _SecurityPage extends StatelessWidget {
  const _SecurityPage();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Paragraph(
          t(
            'Zen nie ma konta w chmurze. Twój telefon łączy się wprost z telefonami '
            'znajomych przez sieć mesh. Wiadomości są szyfrowane end-to-end, a wszystko '
            'na urządzeniu jest zaszyfrowane hasłem. Nikt — ani autor, ani żadna firma — '
            'nie może odczytać Twoich rozmów. Zgubienie telefonu nie wystarczy, żeby ktoś '
            'dostał się do danych bez Twojego hasła.',
          ),
        ),
        ZenInfo(
          icon: Icons.group_rounded,
          tone: zen.success,
          title: t('Odzyskiwanie przez 6 zaufanych osób'),
          text: t(
            'Skoro nie ma serwera, nie ma też „zapomniałem hasła” przez e-mail. '
            'Zamiast tego wybierasz krąg do 6 zaufanych znajomych i każdy dostaje '
            'zaszyfrowany kawałek klucza. Po zgubieniu telefonu odzyskujesz konto '
            'hasłem i pomocą 2 z nich (po 24 godzinach), a gdy nie pamiętasz '
            'hasła — pomocą 4 z nich (po 7 dniach; stare urządzenia dostają '
            'ostrzeżenie). Jedna osoba sama nic nie zobaczy.',
          ),
        ),
        ZenSection(t('Jak sprawdzić, że to nie wirus')),
        const OwnCopyCard(),
        ZenCard(
          key: const Key('about-safety'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Step(
                n: 1,
                tone: zen.success,
                title: t('Pobieraj z jednego miejsca'),
                text: t(
                  'Tylko z oficjalnej strony na GitHubie (link niżej) albo '
                  'od znajomego, który ma Zen. Nie z innych stron.',
                ),
              ),
              _Step(
                n: 2,
                tone: zen.success,
                title: t('Sprawdź plik za darmo'),
                text: t(
                  'Przed instalacją wrzuć plik na virustotal.com — '
                  'kilkadziesiąt programów antywirusowych sprawdzi go naraz.',
                ),
              ),
              _Step(
                n: 3,
                tone: zen.success,
                title: t('Telefon też sprawdza'),
                text: t(
                  'Android skanuje aplikację przy instalacji. Może '
                  'ostrzec, że jest „nieznana” — to normalne dla aplikacji '
                  'spoza sklepu.',
                ),
              ),
              _Step(
                n: 4,
                tone: zen.success,
                title: t('Kod jest jawny'),
                text: t(
                  'Każdy może przejrzeć, co Zen robi. Każda oficjalna wersja '
                  'jest podpisana tym samym kluczem, więc telefon nie '
                  'zainstaluje podróbki „na” prawdziwy Zen.',
                ),
                last: true,
              ),
            ],
          ),
        ),
        _LinkTile(
          icon: Icons.code_rounded,
          tone: zenTone(zen, 6),
          title: t('Oficjalna strona projektu'),
          subtitle: 'github.com/robertostrowskijagoda/Zen',
          url: PeerShareCodec.repositoryUrl,
        ),
        _LinkTile(
          icon: Icons.privacy_tip_rounded,
          tone: zen.success,
          title: t('Polityka prywatności'),
          subtitle: t('Co dzieje się z Twoimi danymi'),
          onTap: () => unawaited(
            LegalDocumentScreen.open(context, LegalDocument.privacy),
          ),
        ),
      ],
    );
  }
}

/// "Licencje i podziękowania": Zen's licence, the libraries' licences and
/// thanks to the projects it stands on.
class _LicencesPage extends StatelessWidget {
  const _LicencesPage();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Paragraph(
          t(
            'Zen jest wolnym oprogramowaniem na licencji GNU GPL w '
            'wersji 3 (GPL-3.0-only) z dodatkowymi warunkami z jej '
            'sekcji 7 (plik NOTICE). Zen jest dostarczany BEZ ŻADNEJ '
            'GWARANCJI. Pełny tekst licencji: plik LICENSE w kodzie '
            'źródłowym i https://www.gnu.org/licenses/gpl-3.0.html',
          ),
        ),
        _LinkTile(
          key: const Key('about-licenses'),
          icon: Icons.description_outlined,
          tone: zenTone(zen, 6),
          title: t('Licencje'),
          subtitle: t('Licencja GPL-3.0 i biblioteki, z których korzysta Zen'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Zen',
            applicationVersion: '$kAppVersion ($kAppBuild)',
            // Appropriate Legal Notices (GPL-3.0 section 0) with the
            // author attribution notice required by NOTICE (section 7(b)).
            applicationLegalese: <String>[
              'Zen by Robert Ostrowski-Jagoda',
              'Support the author: $kDonationUrl',
              'Copyright (C) 2026 Robert Ostrowski-Jagoda',
              '',
              t(
                'Zen jest wolnym oprogramowaniem na licencji GNU GPL w '
                'wersji 3 (GPL-3.0-only) z dodatkowymi warunkami z jej '
                'sekcji 7 (plik NOTICE). Zen jest dostarczany BEZ ŻADNEJ '
                'GWARANCJI. Pełny tekst licencji: plik LICENSE w kodzie '
                'źródłowym i https://www.gnu.org/licenses/gpl-3.0.html',
              ),
              PeerShareCodec.repositoryUrl,
            ].join('\n'),
          ),
        ),
        _LinkTile(
          key: const Key('about-licence-notice'),
          icon: Icons.gavel_rounded,
          tone: zenTone(zen, 3),
          title: LegalDocument.licence.title,
          subtitle: LegalDocument.licence.subtitle,
          onTap: () => unawaited(
            LegalDocumentScreen.open(context, LegalDocument.licence),
          ),
        ),
        ZenSection(t('Podziękowania')),
        _Paragraph(
          t(
            'Zen stoi na pracy wielu ludzi, którzy dzielą się kodem za darmo: '
            'sieci Yggdrasil, Flutter i Dart, Go, WebRTC, biblioteki '
            'szyfrujące, czcionki i ikony. Dziękuję im wszystkim — ich '
            'licencje są na liście „Licencje”. Dziękuję też każdemu, kto '
            'zgłasza błędy, tłumaczy i podaje Zen dalej.',
          ),
        ),
        _LinkTile(
          icon: Icons.lan_rounded,
          tone: zenTone(zen, 0),
          title: t('Sieć Yggdrasil'),
          subtitle: 'yggdrasil-network.github.io',
          url: kYggdrasilUrl,
        ),
      ],
    );
  }
}

/// "Dokumenty": the terms, the privacy policy and the licence notice, read
/// in the app, and when they were accepted.
class _DocumentsPage extends ConsumerWidget {
  const _DocumentsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final int acceptedAt = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.legalAcceptedAtMillis,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final LegalDocument doc in LegalDocument.values)
          _LinkTile(
            key: Key(switch (doc) {
              LegalDocument.terms => 'about-terms',
              LegalDocument.privacy => 'about-privacy-policy',
              LegalDocument.licence => 'about-licence',
            }),
            icon: switch (doc) {
              LegalDocument.terms => Icons.gavel_rounded,
              LegalDocument.privacy => Icons.privacy_tip_rounded,
              LegalDocument.licence => Icons.description_outlined,
            },
            tone: zenTone(zen, doc.index + 1),
            title: doc.title,
            subtitle: doc.subtitle,
            onTap: () => unawaited(LegalDocumentScreen.open(context, doc)),
          ),
        if (acceptedAt > 0)
          ZenInfo(
            key: const Key('about-documents-accepted'),
            icon: Icons.task_alt_rounded,
            tone: zen.success,
            text: t('Zaakceptowane na tym urządzeniu: {date}', {
              'date': _isoDate(DateTime.fromMillisecondsSinceEpoch(acceptedAt)),
            }),
          ),
      ],
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// "Kontakt i zgłaszanie błędów".
class _ContactPage extends StatelessWidget {
  const _ContactPage();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Paragraph(
          t(
            'Błąd, pomysł albo pytanie? Napisz na GitHubie w zakładce Issues. '
            'Przy błędzie dołącz dziennik zdarzeń: Ustawienia → Diagnostyka '
            '(bez treści wiadomości). Zen nie ma serwera, więc nikt nie '
            'zobaczy problemu, dopóki go nie zgłosisz.',
          ),
        ),
        _LinkTile(
          key: const Key('about-issues'),
          icon: Icons.bug_report_outlined,
          tone: zen.warning,
          title: t('Zgłoś błąd'),
          subtitle: 'github.com/robertostrowskijagoda/Zen/issues',
          url: kIssuesUrl,
        ),
        _LinkTile(
          icon: Icons.code_rounded,
          tone: zenTone(zen, 6),
          title: t('Oficjalna strona projektu'),
          subtitle: 'github.com/robertostrowskijagoda/Zen',
          url: PeerShareCodec.repositoryUrl,
        ),
        ZenSection(t('Kto to robi')),
        const _AuthorCard(),
      ],
    );
  }
}

/// "Wesprzyj Zen": the collection, with the author's note.
class _SupportPage extends StatelessWidget {
  const _SupportPage();

  @override
  Widget build(BuildContext context) {
    return _DonateCard(
      onOpen: () => unawaited(openOrCopyLink(context, kDonationUrl)),
      onCopy: () => unawaited(_copyDonationLink(context)),
    );
  }
}

Future<void> _copyDonationLink(BuildContext context) async {
  await Clipboard.setData(const ClipboardData(text: kDonationUrl));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t('Link do zbiórki skopiowany.'))));
  }
}

/// Who makes Zen.
class _AuthorCard extends StatelessWidget {
  const _AuthorCard();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      key: const Key('about-author-card'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ZenIconBadge(
            icon: Icons.person_rounded,
            tone: zenTone(zen, 5),
            size: 44,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Robert Ostrowski-Jagoda',
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  t(
                    'Cześć! Zen tworzę sam, bez inwestorów i bez firmy, która '
                    'zarabiałaby na Twoich danych. Chcę, żeby ludzie mogli się '
                    'poznawać, spotykać i pomagać sobie przez tych, którym ufają '
                    '— a nie przez platformę, która na tym zarabia.',
                  ),
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One numbered step in "Jak używać".
class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.tone,
    required this.title,
    required this.text,
    this.last = false,
  });

  final int n;
  final Color tone;
  final String title;
  final String text;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$n',
              style: TextStyle(
                color: tone,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the "Na czym działa" card: a platform and its state.
class _Platform extends StatelessWidget {
  const _Platform({
    required this.icon,
    required this.tone,
    required this.name,
    required this.note,
    this.last = false,
  });

  final IconData icon;
  final Color tone;
  final String name;
  final String note;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: Row(
        children: <Widget>[
          ZenIconBadge(icon: icon, tone: tone, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  note,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The logo (white letters on graphite as on the icon; black on light in the
/// light theme) with the version.
class _LogoCard extends StatelessWidget {
  const _LogoCard({required this.storeBuild});

  final bool storeBuild;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool light = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: context.zenRadius(26),
        gradient: zen.panelGradient(tone: zen.accent, alpha: 0.12),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Row(
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              borderRadius: context.zenRadius(21),
              border: Border.all(color: zen.outlineStrong),
            ),
            child: ClipRRect(
              borderRadius: context.zenRadius(20),
              child: Image.asset(
                // Black on light in the light theme, as on paper.
                light
                    ? 'assets/branding/logo_light.jpg'
                    : 'assets/branding/logo.jpg',
                key: Key(light ? 'about-logo-light' : 'about-logo-dark'),
                width: 84,
                height: 84,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        Container(
                          width: 84,
                          height: 84,
                          color: zen.surfaceRaised,
                          alignment: Alignment.center,
                          child: Text(
                            'ZEN',
                            style: zen.display(
                              color: zen.textPrimary,
                              size: 24,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Zen',
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 34,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t('Wersja {version} · kompilacja {build}', {
                    'version': kAppVersion,
                    'build': kAppBuild,
                  }),
                  style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
                ),
                if (storeBuild)
                  Text(
                    t('Wersja ze sklepu'),
                    key: const Key('about-store-build'),
                    style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
                  ),
                const SizedBox(height: 6),
                Text(
                  t('Sieć ludzi, którzy się znają.'),
                  style: TextStyle(color: zen.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 8),
                // The Author Attribution Notice (NOTICE, section 1),
                // legibly on the About screen itself.
                Text(
                  'Zen by Robert Ostrowski-Jagoda\n'
                  'Support the author: $kDonationUrl',
                  key: const Key('about-attribution'),
                  style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Who makes Zen, in the author's own words (shown with the collection).
String get kAuthorNote => t(
  'Nazywam się Robert Ostrowski-Jagoda, jestem programistą. W chwili, gdy '
  'to piszę, pracuję na taksówce, ponieważ zabrakło dla mnie pracy. '
  'Stworzyłem tę aplikację za darmo, ale też chcę mieć dom i lamborghini — '
  'proszę, rzuć mi chociaż te 5 \$. W aplikacji nie ma reklam, jest za '
  'darmo, nie zarabiam na niej bezpośrednio. Jeżeli masz dla mnie pracę, '
  'daj znać — znajdziesz mnie między innymi na LinkedInie.',
);

/// Why and how to give, the link, and its QR code for another phone.
class _DonateCard extends StatelessWidget {
  const _DonateCard({required this.onOpen, required this.onCopy});

  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 1);
    return Container(
      key: const Key('about-donate'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: context.zenRadius(24),
        gradient: zen.panelGradient(tone: tone, alpha: 0.14),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenIconBadge(
                icon: Icons.volunteer_activism_rounded,
                tone: tone,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t('Zen jest za darmo i bez reklam'),
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 18,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            t(
              'Utrzymuje się wyłącznie z dobrowolnych wpłat. Jeśli Zen Ci się '
              'przydaje, możesz dorzucić się do dalszej pracy — każda kwota '
              'pomaga, a aplikacja zawsze zostanie darmowa dla wszystkich.',
            ),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            key: const Key('about-author'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: context.zenRadius(16),
              color: tone.withValues(alpha: 0.08),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t('O autorze'),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  kAuthorNote,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: context.zenRadius(18),
              ),
              child: QrImageView(
                key: const Key('about-donate-qr'),
                data: kDonationUrl,
                size: 150,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t('Zeskanuj aparatem innego telefonu albo skopiuj link.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: zen.textMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          SelectableText(
            kDonationUrl,
            textAlign: TextAlign.center,
            style: zen.mono(color: tone, size: 13),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('about-donate-open'),
            onPressed: onOpen,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.coffee_rounded, size: 18),
            label: Text(t('Postaw kawę na buycoffee.to')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('about-donate-copy'),
            onPressed: onCopy,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(t('Skopiuj link do zbiórki')),
          ),
        ],
      ),
    );
  }
}
