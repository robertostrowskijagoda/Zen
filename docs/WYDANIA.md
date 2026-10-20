# Wydania, podpisy i publikacja

Jak wydać Zen na GitHubie, czym podpisywać, jak sprawdzić, że plik jest
oficjalny, którymi kanałami go rozprowadzać (§4, §6: weryfikacja twórców
Androida, sklepy, iPhone, koszty i plan) i co z aktualizacjami przez sieć.
Plan integralności: §14.3 w `PROJEKT_APLIKACJI.md`; otwarte problemy
dystrybucji: `STAN.md` §9.

- **Repozytorium:** https://github.com/robertostrowskijagoda/Zen
- **Strona:** stroną dla ludzi jest `README.md` repozytorium. Jedyny plik na
  GitHub Pages to strona zaproszeń (`tool/pages/index.html`, workflow
  `pages.yml`) — otwiera Zen z kodem z QR albo pokazuje pobieranie.
- **Pakiet Androida:** `com.roj.zen` (był `com.HuraganKodu.zen`).
- **Licencja:** `LICENSE` — PolyForm Strict 1.0.0 z dodatkowymi zezwoleniami:
  każdy (także firmy) może używać Zen do każdego celu, czytać kod, wysyłać pull
  requesty, budować z niezmienionego kodu i rozdawać niezmienione wydania; nie
  wolno sprzedawać Zen, brać opłat za udostępnianie, dołączać go do płatnych
  produktów ani publikować forków.

## 1. Repozytorium

1. Przed wypchnięciem sprawdź `git status` i historię: nie mogą tam być
   `android/key.properties`, pliki `*.jks` / `*.keystore`, `maintainer.key`
   ani `scratch/` (są w `.gitignore`; sprawdź też
   `git log --all -- android/key.properties`).
2. **Kody QR z zaproszeniami** prowadzą do
   `https://robertostrowskijagoda.github.io/Zen/#KOD` (kod bez myślników, po
   `#`; przeglądarka nie wysyła tej części do serwera, więc nikt nie wie, kto
   kogo zaprasza). Strona otwiera Zen z kodem, a kto nie ma Zen, widzi
   przyciski pobierania. Adres jest w `PeerShareCodec.invitePageUrl`
   (`lib/src/features/social/peer_share_codec.dart`); zmiana nazwy
   repozytorium albo konta psuje wydrukowane kody.

   **Publikacja strony:** workflow `.github/workflows/pages.yml` publikuje
   `tool/pages/` przy każdej zmianie na `main`. Raz w GitHubie:
   **Settings → Pages → Source: GitHub Actions**. GitHub Pages działa
   w darmowym planie tylko dla **publicznych** repozytoriów.
3. W ustawieniach repozytorium włącz Issues; opis: „Sieć ludzi, którzy się
   znają — komunikator bez serwerów, reklam i algorytmu”.

## 2. Klucz podpisu (raz na zawsze)

1. Utwórz klucz **poza repozytorium**:
   ```
   keytool -genkeypair -v -keystore zen-release.jks -keyalg RSA -keysize 4096 -validity 10000 -alias zen
   ```
2. `android/key.properties` (w `.gitignore`); bez niego wydanie buduje się
   kluczem debug, z ostrzeżeniem:
   ```
   storeFile=C:/ścieżka/do/zen-release.jks
   storePassword=…
   keyAlias=zen
   keyPassword=…
   ```
3. **Kopia:** zgubiony klucz = koniec aktualizacji dla wszystkich. Podziel
   plik klucza i hasło Shamirem (np. 3 z 5) między zaufane osoby; nigdy
   publicznie, nigdy w repozytorium. Gdyby trzeba było zmienić klucz —
   rotacja przez APK Signature Scheme v3 (stary klucz podpisuje nowy).
4. **Odcisk certyfikatu** (wklej do README w sekcji „Czy to nie wirus?”
   i do opisu każdego wydania):
   ```
   keytool -list -v -keystore zen-release.jks -alias zen | findstr SHA256
   ```
   Ten sam odcisk ma trafić do aplikacji jako przypięty (§14.3).

Wcześniejsze kompilacje były podpisane kluczem debug; Android nie pozwala
nadpisać aplikacji podpisanej innym kluczem. Przy zmianie pakietu na
`com.roj.zen` i tak powstaje nowa aplikacja (punkt 3.8).

## 3. Wydanie krok po kroku

1. **Numer wersji:** `version:` w `pubspec.yaml` oraz `kAppVersion`
   / `kAppBuild` w `lib/src/app/app_version.dart` (test pilnuje, żeby się
   zgadzały); ten sam numer w nagłówku CHANGELOG i w tagu. Numer kompilacji
   (`versionCode`) musi rosnąć.
2. **Most Go** buduje się sam (§3.1): `flutter build apk`, `windows`,
   `linux`, `macos` i `ios` przebudowują go tylko wtedy, gdy zmieniły się
   jego źródła. Po zmianie `go.mod` (np. nowa wersja Yggdrasil) odśwież
   licencje: `dart run tool/go_licenses.dart` (test
   `go_licenses_test.dart` przypomina).
3. **Budowanie:** wypchnięcie tagu `v<wersja>` uruchamia
   `.github/workflows/release.yml`: Android (osobne zadanie) i Windows na
   `windows-latest`, Linux x64 na `ubuntu-latest`, Linux ARM64 na
   `ubuntu-24.04-arm`, macOS na `macos-latest` i iPhone (`ios.yml`, wołany
   z `release.yml`). Każde zadanie odkłada pliki jako artefakt, przedostatnie
   zbiera je i liczy `SHA256SUMS`, a ostatnie dołącza wszystko do wersji
   roboczej wydania (draft). Klucz podpisu APK w sekretach **środowiska
   `release`** (Settings → Environments; nie w sekretach repozytorium):
   `ANDROID_KEYSTORE_BASE64` (plik `.jks` w base64),
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`
   — bez nich workflow pomija `Zen.apk`. Środowisko: wymagany zatwierdzający
   (opiekun) i reguła tylko dla tagów `v*`; klucz dostaje wyłącznie przebieg
   z tagu `v*` po zatwierdzeniu (audyt S-6, opis na początku
   `release.yml`). Ręczne uruchomienie z gałęzi buduje pozostałe pliki jako
   artefakty, bez `Zen.apk` i bez wydania. Lokalnie:
   `flutter build apk|windows|linux|macos --release` (wymagania: README,
   „Budowanie ze źródeł”).
4. **Pliki dokładnie pod tymi nazwami:**
   - `Zen.apk` — `build/app/outputs/flutter-apk/app-release.apk`;
   - `Zen-Windows.zip` — spakowany folder `build/windows/x64/runner/Release`;
   - `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz` — folder
     `build/linux/<x64|arm64>/release/bundle` jako `Zen/` (uruchamia się
     `Zen/zen`);
   - `Zen-macOS.zip` — `build/macos/Build/Products/Release/Zen.app`
     spakowany `ditto -c -k --keepParent` (uniwersalny: Apple Silicon
     i Intel; podpis ad hoc, bez notaryzacji — pierwsze uruchomienie przez
     „Otwórz mimo to” w Ustawieniach systemowych → Prywatność i ochrona);
   - `Zen-unsigned.ipa` — z workflow „iOS”;
   - `LICENSES-GO.txt` — `native/yggdrasil_bridge/LICENSES-GO.txt`
     (licencje modułów Go w moście; są też w aplikacji: „O aplikacji →
     Licencje”, obok `zen.exe` w ZIP-ie i obok `zen` w archiwach Linuksa);
   - `SHA256SUMS` — sumy wszystkich plików powyżej (punkt 5).

   README prowadzi do `…/releases/latest/download/Zen.apk`,
   `…/releases/latest/download/Zen-Windows.zip`
   i `…/releases/latest/download/Zen-unsigned.ipa`, więc stałe nazwy dają
   zawsze najnowszą wersję jednym kliknięciem (tak samo
   `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz` i `Zen-macOS.zip`).
5. **Sumy kontrolne:** `SHA256SUMS` liczy ostatnie zadanie `release.yml`
   ze wszystkich plików wydania (format `sha256sum`; sprawdzenie:
   `sha256sum -c SHA256SUMS`, na Windows
   `Get-FileHash -Algorithm SHA256 Zen.apk`). Licencja pozwala
   rozpowszechniać kopie, których SHA-256 zgadza się z opublikowanym, więc
   sumy muszą być przy każdym wydaniu — także po ręcznej podmianie pliku
   trzeba je policzyć od nowa.
6. **GitHub → Releases:** tag `v<kAppVersion>` (np. `v1.10.0`). Wypchnięcie
   tagu tworzy wersję roboczą (draft) z kompletem plików z punktu 4. W
   opisie: co nowego (z CHANGELOG), odcisk certyfikatu, sumy SHA-256.
   Opublikuj ręcznie po sprawdzeniu.
7. **Sprawdzenie:** pobierz z `releases/latest/download/`, porównaj sumę,
   `apksigner verify --print-certs Zen.apk` (odcisk jak w README),
   instalacja na czystym telefonie i uruchomienie na Windows, Linuksie
   i Macu.
8. **Pierwsze wydanie z `com.roj.zen`:** w opisie napisz, że to nowa
   aplikacja — stara (`com.HuraganKodu.zen`) zostaje obok z danymi. Konto
   przenosi się przez „Podłącz nowe urządzenie” (§6.5) albo odzyskiwanie;
   potem starą można odinstalować.

### 3.1. Most Go (native/yggdrasil_bridge)

- **Automatycznie:** Android — zadanie Gradle `buildGoBridge` (przed
  `preBuild`), Windows — cel CMake `yggdrasil_bridge`. Oba wołają
  `build_if_changed.ps1 -Target android|windows`, który liczy SHA-256
  źródeł (`*.go` bez testów, `go.mod`, `go.sum`, skrypt budowania) i buduje
  tylko, gdy suma różni się od zapisanej obok biblioteki
  (`libyggdrasil_bridge.so.sha256`, `bin/yggdrasil_bridge.dll.sha256`;
  gdy biblioteka jest w repozytorium, jej suma trafia tam razem z nią).
- **Bez Go** (albo bez NDK / kompilatora C) używana jest istniejąca
  biblioteka z ostrzeżeniem; bez niej budowanie się przerywa z opisem, czego
  brakuje. `ZEN_SKIP_GO_BRIDGE=1` pomija sprawdzanie. Automatyczna
  przebudowa `.so` działa tylko na Windows (skrypt używa NDK dla Windows).
- **Ręcznie**, jak dawniej: `build_android.ps1`, `build_windows.ps1`
  (Go przenośne z `%LOCALAPPDATA%\Programs\GoPortable` albo z `PATH`; NDK
  z `ANDROID_NDK_HOME`, `ANDROID_HOME` lub domyślnego SDK).
- **iPhone:** `sh native/yggdrasil_bridge/build_ios.sh [iphonesimulator]`
  (macOS, Go + Xcode) robi bibliotekę statyczną
  `ios/GoBridge/<platforma>/libyggdrasil_bridge.a` (poza repozytorium).
  Xcode łączy ją z aplikacją (`ios/Flutter/GoBridge.xcconfig`), a faza
  „Go bridge” w projekcie przebudowuje ją, gdy zmienią się źródła. Nowa
  funkcja `//export` w Go wymaga wpisu `-Wl,-u,_Nazwa` w
  `GoBridge.xcconfig` (skrypt to sprawdza).
- **Linux:** cel CMake `yggdrasil_bridge` (`linux/CMakeLists.txt`) woła
  `build_linux.sh --if-changed <linux-x64|linux-arm64>`; biblioteka
  `native/yggdrasil_bridge/bin/<platforma>/libyggdrasil_bridge.so`
  (+ `.sha256`) trafia do `lib/` w paczce. Potrzebne Go i kompilator C
  (gcc albo clang); inna architektura niż komputera wymaga kompilatora
  skrośnego w `CC`.
- **macOS:** faza „Go bridge” w `macos/Runner.xcodeproj` woła
  `build_macos.sh --if-changed`, który robi uniwersalną (arm64 + x86_64)
  bibliotekę statyczną `macos/GoBridge/libyggdrasil_bridge.a` (poza
  repozytorium). Xcode łączy ją z aplikacją
  (`macos/Runner/Configs/GoBridge.xcconfig`) jak na iPhonie, więc nowa
  funkcja `//export` wymaga wpisu `-Wl,-u,_Nazwa` także tam.

### 3.2. iPhone (GitHub Actions)

`.github/workflows/ios.yml` (macOS, Flutter 3.47.1, Go z `go.mod`): most
Go → `flutter build ios --release --no-codesign` → `Zen-unsigned.ipa`
(folder `Payload/Runner.app` w ZIP-ie). Uruchamia się ręcznie (Actions →
iOS → Run workflow; plik jest w artefaktach przebiegu) albo jako część
`release.yml` przy tagu `v*`, który dołącza go do wydania.
Paczka nie jest podpisana — podpisuje ją SideStore albo AltStore
darmowym Apple ID użytkownika (README, sekcja „iPhone”). Identyfikator
aplikacji: `com.roj.zen`. Lokalnie na Macu: `build_ios.sh`, potem
`flutter build ios --release --no-codesign`.

## 4. Android: weryfikacja twórców (2026–2027)

Stan na 15.10.2026 (źródła: §6.6):

- Na **certyfikowanych** telefonach (z usługami Google) instalować
  i aktualizować będzie można tylko aplikacje, których pakiet i klucz
  podpisu zarejestrował zweryfikowany twórca — bez względu na to, skąd jest
  plik (sklep, przeglądarka, „Podaj dalej”, samoaktualizacja).
- **Od 30.09.2026** obowiązuje to tylko przy instalacji ze „sklepów
  uczestniczących” (Google Play, Galaxy Store, HONOR, OPPO, Xiaomi GetApps,
  vivo, Palm Store) w Brazylii, Indonezji, Singapurze i Tajlandii.
  Instalacja z pliku — także tam — na razie się nie zmieniła. **W Polsce
  i UE nic się jeszcze nie zmieniło.**
- **2027:** wszystkie aplikacje na certyfikowanych urządzeniach na całym
  świecie; miesiąc nieogłoszony, brak decyzji Komisji Europejskiej (DMA).
- Bez rejestracji zostaje **zaawansowana ścieżka** (Opcje programisty →
  „Aplikacje od niezweryfikowanych twórców”, potwierdzenie, restart,
  **24 h czekania**, potem na 7 dni albo na stałe; przy każdej instalacji
  ostrzeżenie; wyłączenie ścieżki zatrzymuje aktualizacje) albo **ADB**
  (zwolnione). Nie dotyczy telefonów bez Google (GrapheneOS, LineageOS bez
  GMS, Huawei) ani urządzeń firmowych.
- Instalacja mało popularnej aplikacji bez internetu może się nie udać —
  Google przyznał, że „w najgorszym przypadku” weryfikacja potrzebuje sieci
  (niepewne; ważne dla „Podaj dalej” bez internetu).

**Do zrobienia do końca 2026 (~100 zł):**

1. **Najpierw kopia klucza** (§2 pkt 3): bez klucza nie da się zarejestrować
   pakietu, a zgubiony klucz to koniec aktualizacji.
2. **Konto za 25 USD jednorazowo:** Play Console jako konto osobiste
   (jednocześnie konto weryfikacji i droga do Google Play, §6.2) albo
   Android Developer Console (tylko poza Play). Potrzebne: konto Google
   z 2FA, profil płatności, dowód osobisty, dokument z adresem (rachunek,
   wyciąg), e-mail i telefon.
3. **Rejestracja `com.roj.zen`** z odciskiem SHA-256 klucza wydań i dowodem
   posiadania klucza. Wersja w Play: wgrać do Play App Signing **ten sam**
   klucz (jeden pakiet dla obu kanałów) albo zarejestrować oba klucze.
4. Darmowe konto „ograniczonej dystrybucji” (bez dokumentu, do 20
   urządzeń, każde musi przyjąć zaproszenie) nadaje się tylko do testów.
5. Gdy weryfikacja obejmie UE: sprawdzić na telefonie z aktywną
   weryfikacją instalację przez „Podaj dalej” bez internetu; jeśli wymaga
   sieci, napisać o tym na ekranie „Podaj dalej”.

## 5. Jak sprawdzić, że plik jest oficjalny

- **Odcisk certyfikatu** i **`SHA256SUMS`** przy każdym wydaniu i w README.
- Użytkownik: pobiera tylko z repozytorium (adres zaczyna się od
  `github.com/robertostrowskijagoda/`) albo od znajomego przez „Podaj
  dalej”; może wrzucić plik na virustotal.com; Android skanuje aplikację
  przy instalacji; ten sam klucz podpisu sprawia, że podróbka nie
  zainstaluje się „na” prawdziwy Zen.
- W aplikacji (plan, §14.3): przypięty odcisk, „Oficjalna kopia” w „O
  aplikacji”, czerwone ostrzeżenie przy każdym APK z niezgodnym podpisem lub
  sumą, podpisany manifest zbiórki.
- **Windows:** dziś bez podpisu Authenticode, więc SmartScreen pokazuje
  „System Windows ochronił ten komputer” (README mówi, co kliknąć). Do
  zrobienia: SignPath (darmowy dla projektów otwartych — sprawdzić, czy
  przyjmie licencję Zen) albo Azure Trusted Signing.
- **macOS:** podpis ad hoc, bez notaryzacji — od macOS 15 pierwsze
  uruchomienie tylko przez „Otwórz mimo to” w Ustawieniach systemowych
  (albo `xattr -dr com.apple.quarantine`). Docelowo Developer ID
  i notaryzacja (konto Apple, §6.3). **Linux:** bez podpisu; sumy
  w `SHA256SUMS`.

## 6. Dystrybucja: kanały i plan

Badanie kanałów, sklepów i prawa z 14–15.10.2026 — to nie porada prawna
ani podatkowa; miejsca niepewne są oznaczone. Skrót i priorytety:
`STAN.md` §9.

### 6.1 Kanały

| Kanał | Stan | Uwagi |
|---|---|---|
| GitHub Releases | główny kanał | podpisane APK, archiwa dla komputerów, `SHA256SUMS`; od 2027 tylko z zarejestrowanym pakietem (§4) |
| „Podaj dalej” w aplikacji | działa | hotspot, Wi-Fi, Quick Share, USB z komputera; od 2027 jak wyżej, możliwe, że z chwilą internetu |
| Obtainium | działa, nic nie trzeba | instaluje i aktualizuje wprost z GitHub Releases; nie jest sklepem — bez recenzji i wymogów licencyjnych. Do zrobienia: przycisk „Get it on Obtainium” w README i odcisk klucza do sprawdzenia (np. AppVerifier) |
| Własne repozytorium F-Droid | możliwe | `fdroidserver` → statyczne pliki na GitHub Pages; adres albo QR do dodania w F-Droid, Droid-ify, Neo Store; bez recenzji |
| F-Droid (główne) i IzzyOnDroid | **nie** | oba wymagają licencji zatwierdzonej przez OSI albo FSF; licencja Zen zakazuje forków i sprzedaży. Otworzyłaby je tylko wolna licencja (np. GPL-3.0, AGPL-3.0) — decyzja autora |
| Google Play | możliwe, osobny wariant (§6.2) | konto osobiste 25 USD; nowe konto osobiste: test zamknięty z co najmniej 12 testerami przez 14 dni, potem wniosek o produkcję (~7 dni); publicznie imię, nazwisko i kraj; targetSdk 36 dla nowych aplikacji i aktualizacji |
| Samsung Galaxy Store | możliwe, ten sam wariant | bez opłat, recenzja ręczna; od 30.09.2026 sklep uczestniczący w weryfikacji Google |
| Huawei AppGallery | opcjonalnie | telefony Huawei bez Google (weryfikacja Google ich nie dotyczy); Zen nie używa usług Google — sprawdzić na jednym telefonie |
| Accrescent | nie teraz | konsola tylko dla zaproszonych, zakaz samoaktualizacji, ID pakietu musi pasować do domeny autora (niepewne — strona może być nieaktualna) |
| Amazon, Aptoide, RuStore, sklepy chińskie | nie | Amazon Appstore na Androidzie zamknięty od 20.08.2025; Aptoide — roczna opłata i opinia „sklepu z piractwem”; RuStore wymaga VK ID, a VK jest na liście sankcji UE (07.2026); Chiny — rejestracja ICP i chiński podmiot |
| iPhone: SideStore / AltStore z darmowym Apple ID | działa | `Zen-unsigned.ipa`; podpis co 7 dni, najwyżej 3 aplikacje, bez pracy w tle |
| iPhone: TestFlight, AltStore PAL, App Store | wymaga konta 99 USD/rok | §6.3 |
| Windows | ZIP bez Authenticode | później MSIX i winget (§5) |
| Linux | `tar.gz` x64 i ARM64 | do zrobienia: `.deb` i Flatpak z plikiem `.desktop` (ikona na Waylandzie, linki `zen://`, Steam Deck); AppImage i Snap opcjonalnie |
| macOS | ZIP z podpisem ad hoc | Developer ID + notaryzacja tym samym kontem co iPhone (§6.3); oficjalny Homebrew dopiero po notaryzacji |
| Lustro repozytorium (np. Codeberg) | opcjonalne | na wypadek blokady GitHuba |

„Otwórz od razu w aplikacji” (Android App Links) wymaga pliku
`/.well-known/assetlinks.json` w korzeniu domeny — strona zaproszeń jest
w podkatalogu `robertostrowskijagoda.github.io/Zen/`, a własnej domeny
świadomie nie ma. Kod QR otwiera więc stronę zaproszeń (§1 pkt 2), która
uruchamia Zen przez `intent://` albo `zen://`; Zen rozpoznaje ten sam kod
w skanerze, a po włączeniu „Otwieraj obsługiwane linki” także linki
z aparatu.

### 6.2 Wariant sklepowy Androida (Google Play, Galaxy Store)

Wzór: Signal — **ten sam pakiet `com.roj.zen` i ten sam klucz**, dwa
warianty (flavory): `github` z samoaktualizacją i `play` bez niej;
użytkownik przechodzi między kanałami bez utraty danych. Yggdrasil działa
w Zen jako biblioteka, bez `VpnService` (VPN wymagałby konta organizacji).
Wariant `play`:

1. bez samoaktualizacji i bez `REQUEST_INSTALL_PACKAGES` (uprawnienie tylko
   w manifeście wariantu `github`) — samoaktualizacja spoza Play to twarde
   naruszenie zasad (Device and Network Abuse);
2. „Podaj dalej” jako link albo QR do sklepu i strony, bez przesyłania APK;
3. usługa w tle: zadeklarowany typ (`connectedDevice`; `phoneCall`,
   `camera`, `microphone` tylko w rozmowie) zamiast `specialUse`, wideo dla
   recenzentów, przełącznik „zawsze online”;
4. `USE_FULL_SCREEN_INTENT`: deklaracja „połączenia”; alarm prosi
   o specjalny dostęp i ma tryb zapasowy (głośne powiadomienie);
5. położenie tylko na pierwszym planie albo jedna funkcja w tle (alarm),
   z wyraźnym ujawnieniem; Bluetooth z `neverForLocation`, jeśli prawda;
6. randki: cała aplikacja 18+ („Restrict Minor Access”) albo randki ukryte
   — łatwa do obejścia bramka wieku nie wystarczy;
7. nazwy: „Samorząd” / „Rada” zamiast „piramidy”, „punkty” zamiast
   „waluty” i „portfela”, z dopiskiem „bez wartości pieniężnej”; deklaracja
   „brak funkcji finansowych” (ryzyko odrzucenia to ocena, nie przepis);
8. bez linku do buycoffee.to w aplikacji (albo napiwek przez Play Billing);
9. treści użytkowników: regulamin przed pierwszym postem, zgłoszenia do
   autora (e-mail), strona o bezpieczeństwie dzieci (CSAE) z osobą
   kontaktową, opis moderacji;
10. targetSdk 36, AAB, polityka prywatności, Data safety (także klipy.com:
    zapytania i IP), klasyfikacja IARC, instrukcja i drugie konto dla
    recenzenta (Briar zniknął z Play w 2022 m.in. przez brak danych
    testowych);
11. kraje: Polska, UE i kraje anglojęzyczne; bez Chin, Rosji, Białorusi
    i krajów objętych sankcjami (APK z GitHuba zostaje wszędzie).

### 6.3 iPhone i Mac

- **Bez konta** — jak dziś: SideStore / AltStore z darmowym Apple ID.
- **Konto indywidualne Apple Developer — 99 USD/rok** (sprzedawca: imię
  i nazwisko autora). Daje:
  - **TestFlight** — publiczny link, do 10 000 testerów, pierwszy build
    przechodzi lekką recenzję, build ważny 90 dni; zastępuje niepodpisany
    IPA;
  - **AltStore PAL** (UE, Japonia, Brazylia; iOS 17.4+) — dla twórcy
    z dowolnego kraju, bez firmy w UE; zamiast App Review **notaryzacja**
    (opis, błędy, bezpieczeństwo, prywatność, zakaz pobierania kodu — bez
    wytycznych o treściach użytkowników, „kategoriach nasyconych”
    i nazwach). Od **01.10.2026** opłatę za instalację zastąpiła prowizja
    5% od sprzedaży, więc darmowa aplikacja nie płaci (niepewne
    w szczegółach). Paczka i plik źródła (JSON) na GitHub Pages; instalują
    osoby z kontem Apple z tych krajów;
  - **App Store** — pełna recenzja: treści użytkowników (filtr przed
    publikacją, zgłoszenia z odpowiedzią, blokowanie, kontakt), żadnego
    wrażenia „anonimowego czatu”, randki jako funkcja poboczna, nazwy jak
    w §6.2, link do zbiórki tylko w sklepie USA, usuwanie konta
    w aplikacji, deklaracja szyfrowania (we Francji osobna deklaracja albo
    przejście na CryptoKit);
  - **macOS** — podpis Developer ID i notaryzacja w CI (bez recenzji
    treści): znika „Otwórz mimo to” i pytania pęku kluczy po aktualizacji.
- **Web Distribution w UE** (instalacja z własnej strony) — tylko
  organizacje spełniające kryterium (np. fee waiver dla non-profit); dla
  osoby prywatnej praktycznie niedostępne.
- **Japonia** (od iOS 26.2) i **Brazylia** (od iOS 26.5) dopuszczają
  alternatywne sklepy; AltStore PAL działa w obu z tą samą paczką.
- **W każdym kanale iOS:** bez stałego połączenia w tle; powiadomienia
  o wiadomościach i połączeniach wymagają serwera wysyłającego APNs
  (PushKit + CallKit) — decyzja: bez powiadomień w tle albo opcjonalny
  „push relay” bez treści; samoaktualizacja i „Podaj dalej” niemożliwe.
  Program Enterprise i „podpisywacze” na certyfikatach firmowych — nie.

### 6.4 Koszty i podmiot

| Co | Koszt |
|---|---|
| Android: Play Console / Android Developer Console | 25 USD jednorazowo |
| Apple Developer Program (iPhone i macOS) | 99 USD/rok |
| Obtainium, własne repozytorium F-Droid, Galaxy Store, AppGallery | 0 |
| Fundacja (gdy projekt urośnie) | założenie ~1,5–3 tys. zł, utrzymanie ~5–15 tys. zł/rok (głównie księgowość) |

- **Na start wystarczy osoba prywatna** (Google: konto osobiste; Apple:
  konto indywidualne).
- **JDG** u Apple nic nie daje (konto indywidualne), u Google najwyżej
  konto organizacji (bez testu 12 × 14), a kosztuje ZUS. **Sp. z o.o.** to
  ~40 tys. zł/rok stałych kosztów. Estońska OÜ i US LLC — nie (podatki
  w Polsce, kary formalne).
- **Fundacja** (może ją założyć jedna osoba; KRS dla NGO bezpłatny,
  2–4 mies.): konto organizacji (D-U-N-S) w Google i Apple, nazwa fundacji
  zamiast imienia i nazwiska, adres siedziby zamiast domowego, możliwy
  **Apple fee waiver** (niepewne dla Polski — lista krajów nie jest
  publikowana; zapytać przez formularz) i wtedy Web Distribution w UE,
  granty (NLnet, OTF), 1,5% podatku po uzyskaniu statusu OPP. Wymaga
  przeniesienia praw majątkowych do kodu na fundację albo licencji
  wyłącznej. Stowarzyszenie rejestrowe: co najmniej 7 założycieli.
- **DSA, status przedsiębiorcy** w sklepach UE: osoba prywatna z darmową
  aplikacją bez reklam ma mocne argumenty, by nie być „przedsiębiorcą”
  (wtedy bez publikacji adresu i telefonu); darowizny to szara strefa —
  decyzja autora (niepewne).

### 6.5 Plan

Teraz (październik–grudzień 2026):

1. Zostać przy GitHub Releases; w README przycisk Obtainium i odcisk klucza
   z instrukcją sprawdzenia (§2 pkt 4). Koszt 0.
2. Kopia klucza wydań Shamirem (§2 pkt 3) — przed rejestracją.
3. Konto Google 25 USD i rejestracja `com.roj.zen` z kluczem wydań (§4).
4. Wariant `play` (§6.2) z tym samym pakietem i kluczem; test zamknięty
   12 testerów × 14 dni; publikacja w Polsce i UE (+ kraje anglojęzyczne);
   potem Galaxy Store z tym samym wariantem. Razem ~3–6 tygodni.
5. Apple Developer Program 99 USD/rok: TestFlight zamiast niepodpisanego
   IPA, równolegle AltStore PAL dla UE; Developer ID i notaryzacja macOS
   w CI.
6. App Store po ustabilizowaniu wersji z TestFlight (Polska, UE, UK, USA).
7. Linux: `.deb` i Flatpak, potem odtwarzanie audio i wideo.
8. Polityka prywatności i regulamin — wymagane przez sklepy; z klipy.com
   i publicznymi węzłami Yggdrasil.

W 2027:

- sprawdzić instalację bez internetu (hotspot, Bluetooth) na telefonie
  z aktywną weryfikacją; nierejestrowane kompilacje testowe — zaawansowana
  ścieżka albo ADB;
- obserwować: datę objęcia UE, ewentualną decyzję Komisji Europejskiej,
  program „Registered App Stores” Google poza USA, wyrok Sądu Najwyższego
  USA w Epic v. Apple (ok. 06.2027);
- fundacja, jeśli projekt urośnie (konto organizacji, fee waiver → Web
  Distribution w UE);
- F-Droid i IzzyOnDroid tylko po zmianie licencji na wolną.

### 6.6 Źródła

- Weryfikacja twórców Androida:
  [przewodnik](https://developer.android.com/developer-verification/guides),
  [FAQ](https://developer.android.com/developer-verification/guides/faq),
  [pełna dystrybucja](https://developer.android.com/developer-verification/guides/full-distribution),
  [Android Authority 01.10.2026 — pierwsza fala](https://www.androidauthority.com/android-sideloading-developer-verification-first-wave-rollout-3717921/),
  [Android Authority 18.08.2026 — zaawansowana ścieżka](https://www.androidauthority.com/google-android-advanced-flow-sideloading-rollout-begins-3700073/).
- [F-Droid Inclusion Policy](https://f-droid.org/docs/Inclusion_Policy/),
  [IzzyOnDroid Inclusion Policy](https://izzyondroid.org/docs/general/AppInclusionPolicy/),
  [własne repozytorium F-Droid](https://f-droid.org/docs/Setup_an_F-Droid_App_Repo/),
  [Obtainium](https://github.com/ImranR98/Obtainium).
- Google Play: [test dla nowych kont osobistych](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en),
  [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379?hl=en),
  [REQUEST_INSTALL_PACKAGES](https://support.google.com/googleplay/android-developer/answer/12085295?hl=en),
  [usługi pierwszoplanowe i pełny ekran](https://support.google.com/googleplay/android-developer/answer/13392821),
  [Signal: warianty](https://github.com/signalapp/Signal-Android/blob/main/app/build.gradle.kts).
- Apple: [aplikacje w UE](https://developer.apple.com/support/apps-in-the-eu/),
  [AltStore PAL dla twórców](https://faq.altstore.io/developers/distribute-with-altstore-pal),
  [Web Distribution](https://developer.apple.com/support/web-distribution-eu),
  [fee waiver](https://developer.apple.com/help/account/membership/fee-waivers),
  [Japonia](https://developer.apple.com/support/app-distribution-in-japan),
  [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## 7. Zbiórka

- Link jest w `kDonationUrl` (`lib/src/features/about/presentation/about_screen.dart`)
  i w README: **https://buycoffee.to/zen** (od 14.10.2026). Zmiana tylko
  w tych dwóch miejscach; docelowo podpisany manifest (§14.3).
- Gdzie zbierać: buycoffee.to, Patronite, zrzutka.pl (BLIK, przelewy);
  GitHub Sponsors, Liberapay, Ko-fi (zagranica); Open Collective (jawne
  finanse); później fundacja (granty NLnet, Prototype Fund, fundusze UE;
  1,5% podatku po uzyskaniu statusu OPP).
- Podatki (orientacyjnie, do potwierdzenia u doradcy lub w KIS): według
  interpretacji z 09.09.2025 (po wyroku NSA z 27.03.2025) wpłaty od
  **zidentyfikowanych** wspierających to darowizny III grupy (w 2026 kwota
  wolna 5 733 zł od jednej osoby w ciągu 5 lat, powyżej podatek 12–20%
  i SD-3 w ciągu miesiąca), a wpłaty **anonimowe** darowiznami nie są — ich
  kwalifikacja w PIT jest sporna. Działalność nierejestrowana w 2026: do
  10 813,50 zł przychodu kwartalnie. Zbiórka na własną pracę zwykle nie
  jest „zbiórką publiczną” w rozumieniu ustawy. W wersjach do sklepów link
  do zbiórki trzeba usunąć (§6.2, §6.3).
- W aplikacji zbiórka jest tylko w „O aplikacji” (na początku), bez
  nagabywania gdzie indziej. Dobre praktyki: jasny cel, krótkie raporty.

## 8. Aktualizacje przez sieć (wyłączone)

Mechanizm z V1.10 jest w kodzie, ale **wyłączony**: lista kluczy opiekunów
`kReleaseMaintainers` w `lib/src/features/update/release.dart` jest pusta,
więc aplikacja nie przyjmuje aktualizacji z sieci. Nie chcemy opiekunów
z osobnymi kluczami; propozycja zastępstwa (ten sam certyfikat podpisu
+ wyższy `versionCode` + 7 dni + zgoda człowieka) jest w §14.2, „Otwarta
decyzja”.

Jak działa dziś (gdyby lista nie była pusta): wydanie przyjmowane, gdy
podpisało je co najmniej 2 z 3 opiekunów (Ed25519), minęło 7 dni od
pierwszego zobaczenia (każdy opiekun może je w tym czasie wstrzymać)
i człowiek sam naciśnie „Zainstaluj”. Pliki idą siecią jak każdy inny
plik (kawałki po 256 KB), więc podmieniona kopia jest odrzucana.

Narzędzie `tool/zen_release.dart` (czysty Dart):

```
dart run tool/zen_release.dart keygen ~/zen-opiekun.key        # klucz opiekuna
dart run tool/zen_release.dart create --version 1.10.0 --build 10 \
    --notes "Co nowego" --out release.json \
    android=build/app/outputs/flutter-apk/app-release.apk windows=dist/zen-setup.exe
dart run tool/zen_release.dart sign release.json ~/zen-opiekun.key
dart run tool/zen_release.dart verify release.json
dart run tool/zen_release.dart bundle release.json zen-1.10.0.zenupdate \
    android=… windows=…
dart run tool/zen_release.dart revoke --build 10 --why "Powód" \
    ~/zen-opiekun.key revoke-10.json                            # wstrzymanie
```

`.zenupdate` (albo sam `release.json` czy plik wstrzymania) wczytuje się
w **Ustawienia → Aktualizacje i Podaj dalej → Wczytaj aktualizację
z pliku**; aplikacja sprawdza podpisy i mówi o nowej wersji znajomym.
Narzędzie zostanie przerobione po decyzji z §14.2.
