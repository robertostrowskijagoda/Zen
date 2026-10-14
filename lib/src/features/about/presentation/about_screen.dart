import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/update/presentation/share_app_screen.dart';

/// Where donations for Zen go (the only official collection).
const String kDonationUrl = 'https://buycoffee.to/zen';

/// The Yggdrasil project (the network Zen runs on).
const String kYggdrasilUrl = 'https://yggdrasil-network.github.io/';

/// Where public Yggdrasil nodes are listed (Zen's builds take theirs from
/// here).
const String kYggdrasilPublicPeersUrl =
    'https://github.com/yggdrasil-network/public-peers';

/// "O aplikacji": what Zen is, who makes it, and how to support it.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  /// Opens [url] in the browser; where that is not possible (or it fails),
  /// copies it instead.
  Future<void> _openLink(BuildContext context, String url) async {
    if (await openWebLink(url)) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link skopiowany — otwórz go w przeglądarce.'),
        ),
      );
    }
  }

  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: kDonationUrl));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link do zbiórki skopiowany.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('about-screen'),
      appBar: const ZenSectionBar(title: 'O aplikacji'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          const _LogoCard(),

          // §21: the collection comes first.
          const ZenSection('Wesprzyj Zen'),
          _DonateCard(
            onOpen: () => _openLink(context, kDonationUrl),
            onCopy: () => _copyLink(context),
          ),

          const ZenSection('Czym jest Zen'),
          ZenCard(
            child: Text(
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
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 14.5,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ZenPill(
                text: 'Bez serwerów',
                tone: zenTone(zen, 0),
                icon: Icons.hub_rounded,
              ),
              ZenPill(
                text: 'Bez reklam',
                tone: zenTone(zen, 1),
                icon: Icons.block_rounded,
              ),
              ZenPill(
                text: 'Bez algorytmu',
                tone: zenTone(zen, 2),
                icon: Icons.timeline_rounded,
              ),
              ZenPill(
                text: 'Szyfrowane',
                tone: zen.success,
                icon: Icons.lock_rounded,
              ),
            ],
          ),
          const ZenSection('Jak używać'),
          ZenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Step(
                  n: 1,
                  tone: zenTone(zen, 0),
                  title: 'Dodaj znajomego',
                  text:
                      'W zakładce „Zaproś” pokaż swój kod QR, a znajomy niech go zeskanuje (albo odwrotnie). Nie trzeba numeru telefonu ani e-maila.',
                ),
                _Step(
                  n: 2,
                  tone: zenTone(zen, 2),
                  title: 'Pisz i dzwoń',
                  text:
                      'Czaty, grupy, połączenia audio i wideo — wszystko zaszyfrowane, prosto między Wami.',
                ),
                _Step(
                  n: 3,
                  tone: zenTone(zen, 5),
                  title: 'Umawiaj się',
                  text:
                      'Ustaw status „na teraz” (np. Idę na spacer), zrób wydarzenie albo zajrzyj, kto z Twoich znajomych jest wolny.',
                ),
                _Step(
                  n: 4,
                  tone: zenTone(zen, 4),
                  title: 'Poznawaj przez znajomych',
                  text:
                      'Znajomi znajomych pojawiają się sami na grafie i w wydarzeniach — a przez „Sąsiadów” i „Randki” poznajesz nowych ludzi bezpiecznie.',
                  last: true,
                ),
              ],
            ),
          ),
          const ZenSection('Po co to jest'),
          ZenInfo(
            icon: Icons.public_rounded,
            tone: zenTone(zen, 0),
            title: 'Oddać ludziom ich sieć',
            text:
                'Dzisiejsze sieci należą do firm, które zarabiają na Twojej uwadze i '
                'danych, i podsuwają to, co je dłużej zatrzyma przy ekranie. Zen jest '
                'odwrotnością: żadnego właściciela, żadnego algorytmu, który Tobą '
                'steruje. Technologia ma robić jedno — pomagać ludziom, którzy się '
                'znają, trzymać się razem i spotykać naprawdę.',
          ),
          ZenInfo(
            icon: Icons.how_to_vote_rounded,
            tone: zenTone(zen, 3),
            title: 'Także nowa polityka',
            text:
                'Zen ma zmienić nie tylko media społecznościowe, ale i sposób, w jaki '
                'ludzie podejmują wspólne decyzje. „Piramida” buduje się z komórek po '
                'kilka osób, które znają się osobiście; głosy, delegowanie zaufania i '
                'wspólna kasa płyną oddolnie, anonimowo wobec reszty, bez centrali, '
                'którą dałoby się przekupić albo wyłączyć. To próba demokracji, która '
                'naprawdę należy do ludzi.',
          ),
          const ZenSection('Prywatność'),
          ZenCard(
            child: Text(
              'Zen nie ma konta w chmurze. Twój telefon łączy się wprost z telefonami '
              'znajomych przez sieć mesh. Wiadomości są szyfrowane end-to-end, a wszystko '
              'na urządzeniu jest zaszyfrowane hasłem. Nikt — ani autor, ani żadna firma — '
              'nie może odczytać Twoich rozmów. Zgubienie telefonu nie wystarczy, żeby ktoś '
              'dostał się do danych bez Twojego hasła.',
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 14.5,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ZenInfo(
            icon: Icons.group_rounded,
            tone: zen.success,
            title: 'Odzyskiwanie przez 6 zaufanych osób',
            text:
                'Skoro nie ma serwera, nie ma też „zapomniałem hasła” przez e-mail. '
                'Zamiast tego wybierasz krąg do 6 zaufanych znajomych i każdy dostaje '
                'zaszyfrowany kawałek klucza. Po zgubieniu telefonu odzyskujesz konto '
                'hasłem i pomocą 2 z nich (po 24 godzinach), a gdy nie pamiętasz '
                'hasła — pomocą 4 z nich (po 7 dniach; stare urządzenia dostają '
                'ostrzeżenie). Jedna osoba sama nic nie zobaczy.',
          ),
          const ZenSection('Na czym to zbudowane'),
          ZenInfo(
            icon: Icons.lan_rounded,
            tone: zenTone(zen, 0),
            title: 'Sieć Yggdrasil',
            text:
                'Zen nie ma własnych serwerów. Telefony i komputery łączą się '
                'przez Yggdrasil — otwartą, szyfrowaną sieć, w której każde '
                'urządzenie ma swój adres, a ruch idzie wprost albo przez inne '
                'urządzenia, które nie widzą treści. Zen dokłada do tego własne '
                'szyfrowanie każdej wiadomości.',
          ),
          const ZenSection('Własny most Yggdrasil'),
          ZenCard(
            key: const Key('about-own-bridge'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Dla zaawansowanych. Zen na komputerze sam pomaga innym się '
                  'łączyć, gdy router na to pozwala. Możesz też postawić stały '
                  'most bez Zen: zwykły węzeł Yggdrasil, który działa całą '
                  'dobę. Pomaga wszystkim, nie tylko Twoim znajomym, i nie '
                  'widzi treści wiadomości.',
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
                  title: 'Komputer, który stale działa',
                  text:
                      'Serwer VPS albo domowy komputer czy Raspberry Pi. Musi '
                      'mieć publiczny adres IP — w domu przekieruj port w '
                      'routerze.',
                ),
                _Step(
                  n: 2,
                  tone: zenTone(zen, 0),
                  title: 'Zainstaluj Yggdrasil',
                  text:
                      'Paczki i instrukcje dla Linuksa, Windows, macOS i '
                      'routerów są na stronie projektu (link niżej). Plik '
                      'ustawień tworzy polecenie yggdrasil -genconf.',
                ),
                _Step(
                  n: 3,
                  tone: zenTone(zen, 0),
                  title: 'Otwórz nasłuch',
                  text:
                      'W pliku yggdrasil.conf wpisz w Listen np. '
                      'tls://0.0.0.0:443, a w Peers kilka publicznych węzłów. '
                      'Uruchom usługę ponownie i otwórz ten port w zaporze.',
                ),
                _Step(
                  n: 4,
                  tone: zenTone(zen, 0),
                  title: 'Zgłoś go jako publiczny',
                  text:
                      'Dopisz jego adres do listy publicznych węzłów '
                      '(github.com/yggdrasil-network/public-peers). Zen bierze '
                      'węzły z tej listy, więc kolejne wersje Zen połączą się '
                      'także przez Twój most.',
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ZenTile(
            key: const Key('about-yggdrasil-site'),
            icon: Icons.open_in_new_rounded,
            tone: zenTone(zen, 0),
            title: 'Strona Yggdrasil',
            subtitle: 'yggdrasil-network.github.io — instalacja i ustawienia',
            onTap: () => _openLink(context, kYggdrasilUrl),
          ),
          ZenTile(
            key: const Key('about-public-peers'),
            icon: Icons.public_rounded,
            tone: zenTone(zen, 0),
            title: 'Lista publicznych węzłów',
            subtitle: 'github.com/yggdrasil-network/public-peers',
            onTap: () => _openLink(context, kYggdrasilPublicPeersUrl),
          ),
          const ZenSection('Dlaczego nie ma Zen w sklepach'),
          ZenCard(
            child: Text(
              'Zen celowo nie jest w Google Play ani w App Store. Sklep może w '
              'każdej chwili usunąć aplikację albo zażądać zmian — a Zen ma być '
              'niezależny, także od wielkich firm i od polityki. Sklepy wymagają '
              'też firmy, opłat i zgody na swoje zasady, a Zen tworzy jedna '
              'osoba, za darmo. Przy okazji nikt, nawet sklep, nie wie, że '
              'masz Zen.\n\n'
              'Dlatego Zen pobierasz z oficjalnej strony projektu na GitHubie '
              'albo dostajesz od znajomego („Podaj dalej”).',
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 14.5,
                height: 1.5,
              ),
            ),
          ),
          const ZenSection('Jak sprawdzić, że to nie wirus'),
          ZenCard(
            key: const Key('about-safety'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Step(
                  n: 1,
                  tone: zen.success,
                  title: 'Pobieraj z jednego miejsca',
                  text:
                      'Tylko z oficjalnej strony na GitHubie (link niżej) albo '
                      'od znajomego, który ma Zen. Nie z innych stron.',
                ),
                _Step(
                  n: 2,
                  tone: zen.success,
                  title: 'Sprawdź plik za darmo',
                  text:
                      'Przed instalacją wrzuć plik na virustotal.com — '
                      'kilkadziesiąt programów antywirusowych sprawdzi go naraz.',
                ),
                _Step(
                  n: 3,
                  tone: zen.success,
                  title: 'Telefon też sprawdza',
                  text:
                      'Android skanuje aplikację przy instalacji. Może '
                      'ostrzec, że jest „nieznana” — to normalne dla aplikacji '
                      'spoza sklepu.',
                ),
                _Step(
                  n: 4,
                  tone: zen.success,
                  title: 'Kod jest jawny',
                  text:
                      'Każdy może przejrzeć, co Zen robi. Każda oficjalna wersja '
                      'jest podpisana tym samym kluczem, więc telefon nie '
                      'zainstaluje podróbki „na” prawdziwy Zen.',
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ZenTile(
            key: const Key('about-repository'),
            icon: Icons.code_rounded,
            tone: zenTone(zen, 6),
            title: 'Oficjalna strona projektu',
            subtitle: 'github.com/robertostrowskijagoda/Zen',
            onTap: () => _openLink(context, PeerShareCodec.repositoryUrl),
          ),
          const ZenSection('Na czym działa'),
          ZenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Platform(
                  icon: Icons.android_rounded,
                  tone: zen.success,
                  name: 'Android',
                  note: 'Gotowe — telefon i tablet.',
                ),
                _Platform(
                  icon: Icons.desktop_windows_rounded,
                  tone: zenTone(zen, 0),
                  name: 'Windows',
                  note: 'Gotowe — pełna wersja na komputer.',
                ),
                _Platform(
                  icon: Icons.laptop_mac_rounded,
                  tone: zenTone(zen, 5),
                  name: 'macOS i Linux',
                  note: 'W planie — ten sam rdzeń, co na Windows.',
                ),
                _Platform(
                  icon: Icons.phone_iphone_rounded,
                  tone: zenTone(zen, 3),
                  name: 'iPhone i iPad',
                  note:
                      'Przez SideStore albo AltStore, z darmowym Apple ID '
                      '(instrukcja na GitHubie). iOS nie pozwala na pracę w '
                      'tle, więc wiadomości dochodzą przy otwartym Zen.',
                  last: true,
                ),
              ],
            ),
          ),
          const ZenSection('Kto to robi'),
          ZenCard(
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
                        'Cześć! Zen tworzę sam, bez inwestorów i bez firmy, która '
                        'zarabiałaby na Twoich danych. Chcę, żeby ludzie mogli się '
                        'poznawać, spotykać i pomagać sobie przez tych, którym ufają '
                        '— a nie przez platformę, która na tym zarabia.',
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
          ),
          const ZenSection('Więcej'),
          ZenTile(
            key: const Key('about-share-app'),
            icon: Icons.install_mobile_rounded,
            tone: zen.success,
            title: 'Podaj Zen dalej',
            subtitle: 'Wyślij aplikację znajomemu z ręki do ręki, bez sklepu',
            onTap: () => unawaited(ShareAppScreen.open(context)),
          ),
          ZenTile(
            key: const Key('about-licenses'),
            icon: Icons.description_outlined,
            tone: zenTone(zen, 6),
            title: 'Licencje',
            subtitle: 'Biblioteki, z których korzysta Zen',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Zen',
              applicationVersion: '$kAppVersion ($kAppBuild)',
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
  const _LogoCard();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool light = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: zen.panelGradient(tone: zen.accent, alpha: 0.12),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Row(
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(21),
              border: Border.all(color: zen.outlineStrong),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
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
                          color: light
                              ? const Color(0xFFFAFAFA)
                              : const Color(0xFF181818),
                          alignment: Alignment.center,
                          child: Text(
                            'ZEN',
                            style: zen.display(
                              color: light ? Colors.black : Colors.white,
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
                  'Wersja $kAppVersion · kompilacja $kAppBuild',
                  style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
                ),
                const SizedBox(height: 6),
                Text(
                  'Sieć ludzi, którzy się znają.',
                  style: TextStyle(color: zen.textMuted, fontSize: 13),
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
const String kAuthorNote =
    'Nazywam się Robert Ostrowski-Jagoda, jestem programistą. W chwili, gdy '
    'to piszę, pracuję na taksówce, ponieważ zabrakło dla mnie pracy. '
    'Stworzyłem tę aplikację za darmo, ale też chcę mieć dom i lamborghini — '
    'proszę, rzuć mi chociaż te 5 \$. W aplikacji nie ma reklam, jest za '
    'darmo, nie zarabiam na niej bezpośrednio. Jeżeli masz dla mnie pracę, '
    'daj znać — znajdziesz mnie między innymi na LinkedInie.';

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
        borderRadius: BorderRadius.circular(24),
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
                  'Zen jest za darmo i bez reklam',
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
            'Utrzymuje się wyłącznie z dobrowolnych wpłat. Jeśli Zen Ci się '
            'przydaje, możesz dorzucić się do dalszej pracy — każda kwota '
            'pomaga, a aplikacja zawsze zostanie darmowa dla wszystkich.',
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
              borderRadius: BorderRadius.circular(16),
              color: tone.withValues(alpha: 0.08),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'O autorze',
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
                borderRadius: BorderRadius.circular(18),
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
            'Zeskanuj aparatem innego telefonu albo skopiuj link.',
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
            label: const Text('Postaw kawę na buycoffee.to'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('about-donate-copy'),
            onPressed: onCopy,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Skopiuj link do zbiórki'),
          ),
        ],
      ),
    );
  }
}
