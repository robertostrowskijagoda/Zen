# Wydania, podpisy i publikacja

Jak wydać Zen na GitHubie, czym podpisywać, jak sprawdzić, że plik jest
oficjalny, i co z aktualizacjami przez sieć. Plan integralności: §14.3
w `PROJEKT_APLIKACJI.md`; otwarte problemy dystrybucji: `STAN.md` §9.

- **Repozytorium:** https://github.com/robertostrowskijagoda/Zen
- **Strona:** stroną dla ludzi jest `README.md` repozytorium. Jedyny plik na
  GitHub Pages to strona zaproszeń (`tool/pages/index.html`, workflow
  `pages.yml`) — otwiera Zen z kodem z QR albo pokazuje pobieranie.
- **Pakiet Androida:** `com.roj.zen` (był `com.HuraganKodu.zen`).
- **Licencja:** `LICENSE` (Zen Source-Available License 1.0).

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
2. **Most Go** buduje się sam (§3.1): `flutter build apk` i
   `flutter build windows` przebudowują go tylko wtedy, gdy zmieniły się
   jego źródła. Po zmianie `go.mod` (np. nowa wersja Yggdrasil) odśwież
   licencje: `dart run tool/go_licenses.dart` (test
   `go_licenses_test.dart` przypomina).
3. **Budowanie:** wypchnięcie tagu `v<wersja>` uruchamia
   `.github/workflows/release.yml` (Android i Windows na `windows-latest`)
   i `ios.yml`; pliki trafiają do wersji roboczej wydania. Klucz podpisu
   APK w sekretach repozytorium: `ANDROID_KEYSTORE_BASE64` (plik `.jks`
   w base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
   `ANDROID_KEY_PASSWORD` — bez nich workflow pomija `Zen.apk`. Lokalnie:
   `flutter build apk --release` i `flutter build windows --release`.
4. **Pliki dokładnie pod tymi nazwami:**
   - `Zen.apk` — `build/app/outputs/flutter-apk/app-release.apk`;
   - `Zen-Windows.zip` — spakowany folder `build/windows/x64/runner/Release`;
   - `Zen-unsigned.ipa` — z workflow „iOS” (dołącza się sam do wydania);
   - `LICENSES-GO.txt` — `native/yggdrasil_bridge/LICENSES-GO.txt`
     (licencje modułów Go w moście; są też w aplikacji: „O aplikacji →
     Licencje” i obok `zen.exe` w ZIP-ie).

   README prowadzi do `…/releases/latest/download/Zen.apk`,
   `…/releases/latest/download/Zen-Windows.zip`
   i `…/releases/latest/download/Zen-unsigned.ipa`, więc stałe nazwy dają
   zawsze najnowszą wersję jednym kliknięciem.
5. **Sumy kontrolne:** plik `SHA256SUMS`, np.
   `sha256sum Zen.apk Zen-Windows.zip Zen-unsigned.ipa > SHA256SUMS`
   (Windows: `Get-FileHash -Algorithm SHA256 Zen.apk`; suma `.ipa` jest też
   w artefakcie workflow). Licencja pozwala
   rozpowszechniać kopie, których SHA-256 zgadza się z opublikowanym, więc
   sumy muszą być przy każdym wydaniu.
6. **GitHub → Releases:** tag `v<kAppVersion>` (np. `v1.10.0`). Wypchnięcie
   tagu uruchamia workflow „iOS”, który dołącza `Zen-unsigned.ipa` do
   wydania z tym tagiem, a gdy go jeszcze nie ma — tworzy wersję roboczą
   (draft). Do tego samego wydania dodaj `Zen.apk`, `Zen-Windows.zip`,
   `LICENSES-GO.txt`, `SHA256SUMS`. W opisie:
   co nowego (z CHANGELOG), odcisk certyfikatu, sumy SHA-256.
7. **Sprawdzenie:** pobierz z `releases/latest/download/`, porównaj sumę,
   `apksigner verify --print-certs Zen.apk` (odcisk jak w README),
   instalacja na czystym telefonie i uruchomienie na Windows.
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

### 3.2. iPhone (GitHub Actions)

`.github/workflows/ios.yml` (macOS, Flutter 3.47.1, Go z `go.mod`): most
Go → `flutter build ios --release --no-codesign` → `Zen-unsigned.ipa`
(folder `Payload/Runner.app` w ZIP-ie). Uruchamia się przy tagu `v*` albo
ręcznie (Actions → iOS → Run workflow); plik jest w artefaktach przebiegu.
Paczka nie jest podpisana — podpisuje ją SideStore albo AltStore
darmowym Apple ID użytkownika (README, sekcja „iPhone”). Identyfikator
aplikacji: `com.roj.zen`. Lokalnie na Macu: `build_ios.sh`, potem
`flutter build ios --release --no-codesign`.

## 4. Android od 2027: weryfikacja twórcy

Google wprowadza obowiązkową weryfikację twórców także dla aplikacji spoza
Google Play: od 30 września 2026 w Brazylii, Indonezji, Singapurze
i Tajlandii, od 2027 na całym świecie. Aplikację od niezweryfikowanego
twórcy da się wtedy zainstalować tylko „zaawansowaną ścieżką” (opcje
programisty, restart, 24 godziny czekania — opisane w README) albo kablem
przez ADB. Dla zwykłych ludzi to bariera.

**Do zrobienia przed 2027:** konto w Android Developer Console
(weryfikacja tożsamości), rejestracja pakietu **`com.roj.zen`** i klucza
podpisu. Google Play nie jest potrzebny — APK dalej wychodzi na GitHubie.
Darmowe konto „ograniczonej dystrybucji” (do 20 urządzeń, bez dokumentu)
nadaje się tylko do testów.

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
  zrobienia: SignPath (darmowy dla projektów otwartych) albo Azure Trusted
  Signing.

## 6. Kanały

| Kanał | Stan |
|---|---|
| GitHub Releases | główny kanał |
| „Podaj dalej” w aplikacji | hotspot, Wi-Fi, Quick Share, USB z komputera |
| Obtainium | użytkownik wkleja adres repozytorium i dostaje aktualizacje z Releases; nic nie trzeba robić |
| IzzyOnDroid | przyjmuje gotowe APK z Releases; przed zgłoszeniem sprawdzić zasady licencyjne |
| F-Droid (główne repozytorium) | nie — wymaga wolnej licencji, a licencja Zen zakazuje modyfikacji (świadomy wybór) |
| Google Play | ewentualnie później, bez aktualizacji przez sieć i z uzasadnieniem usługi w tle |
| Windows | ZIP; później MSIX i winget |
| iPhone | `Zen-unsigned.ipa` z Releases przez SideStore / AltStore (darmowe Apple ID, odnawianie co 7 dni); App Store wymaga płatnego konta |
| Lustro repozytorium (np. Codeberg) | opcjonalne, na wypadek blokady GitHuba |

„Otwórz od razu w aplikacji” (Android App Links) wymaga pliku
`/.well-known/assetlinks.json` w korzeniu własnej domeny — na github.com się
nie da, a własnej strony świadomie nie ma. Kod QR otwiera README, a Zen
rozpoznaje ten sam kod w skanerze.

## 7. Zbiórka

- Link jest w `kDonationUrl` (`lib/src/features/about/presentation/about_screen.dart`)
  i w README: **https://buycoffee.to/zen** (od 14.10.2026). Zmiana tylko
  w tych dwóch miejscach; docelowo podpisany manifest (§14.3).
- Gdzie zbierać: buycoffee.to, Patronite, zrzutka.pl (BLIK, przelewy);
  GitHub Sponsors, Liberapay, Ko-fi (zagranica); Open Collective (jawne
  finanse); później fundacja (granty NLnet, Prototype Fund, fundusze UE;
  1,5% podatku po uzyskaniu statusu OPP).
- Podatki (orientacyjnie, do potwierdzenia u doradcy lub w KIS): wpłaty od
  nieznanych osób to zwykle darowizny III grupy; w 2026 kwota wolna to
  5 733 zł od jednej osoby w ciągu 5 lat, powyżej podatek 12–20% i SD-3
  w ciągu miesiąca. Zbiórka na własną pracę zwykle nie jest „zbiórką
  publiczną” w rozumieniu ustawy.
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
