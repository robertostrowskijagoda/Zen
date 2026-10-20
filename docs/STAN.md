# Stan projektu

Stan na 15.10.2026. Co działa, znane błędy, otwarte problemy (bezpieczeństwo,
architektura, koncepcja, dystrybucja) i kolejność prac. Plan i opis
rozwiązań: `PROJEKT_APLIKACJI.md` (odnośniki §N.M). Wydania i kanały
dystrybucji: `WYDANIA.md`. Zastępuje dawne `KIERUNKI.md`
i `AUDYT_BEZPIECZENSTWA.md`.

Priorytet: **P1** — przed szerszym udostępnieniem, **P2** — wkrótce,
**P3** — później. Rozmiar: **S** (dni), **M** (tygodnie), **L** (miesiąc
i więcej).

Odwołania `plik:linia` pochodzą z przeglądów sprzed sformatowania całego
kodu (`dart format`) i owinięcia tekstów w `t()`, więc numery linii mogą być
przesunięte o kilka. Przeglądy z 14.10.2026: drugi audyt bezpieczeństwa
(§4.2), przegląd architektury i produktu (§5, §6), zgodność kodu z planem
(§10), badanie dystrybucji (§9), Linux i macOS (§1).

---

## 1. Co działa dziś

- **Platformy:** Android (pakiet `com.roj.zen`), Windows i iPhone
  (SideStore / AltStore z darmowym Apple ID, bez pracy w tle; plik
  `Zen-unsigned.ipa` buduje GitHub Actions). **Linux** (x64 i ARM64)
  i **macOS** (Apple Silicon i Intel, od macOS 12): kod, budowanie w CI
  i pliki wydania (`Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz`,
  `Zen-macOS.zip`), bez podpisu — **niesprawdzone, dopóki nie przejdzie
  pierwszy przebieg CI** (nic nie zbudowano jeszcze naprawdę). Na obu: bez
  Bluetooth, nagrywania rozmów i aparatu; na Linuksie także bez odtwarzania
  głosówek i filmów (`video_player` nie ma tam implementacji), biometrii
  i linków `zen://`; klucz w GNOME Keyring / KWallet. macOS: Touch ID przez
  Secure Enclave, bez piaskownicy (§2).
- **Języki:** 21 — polski (język źródłowy), angielski, niemiecki,
  francuski, hiszpański, włoski, portugalski, niderlandzki, czeski,
  węgierski, rumuński, turecki, rosyjski, ukraiński, arabski (od prawej do
  lewej), hindi, indonezyjski, wietnamski, chiński uproszczony, japoński,
  koreański. Domyślnie automatycznie według języka systemu (gdy Zen go nie
  zna — angielski); zmiana w **Ustawienia → Język**, od razu, bez restartu.
  Ten sam język ma ekran blokady i usługa w tle (powiadomienia). Teksty
  w kodzie po polsku w `t()` / `tn()`, tłumaczenia w `assets/i18n/<kod>.json`
  (`lib/src/app/i18n/zen_i18n.dart`); zgodność pilnują
  `dart run tool/i18n.dart` i `test/i18n_test.dart`.
- **Komunikator:** czaty, grupy, połączenia audio i wideo (także grupowe),
  skrzynki offline u znajomych (tylko wiadomości do 48 KB — zdjęcia, filmy
  i dłuższe głosówki dochodzą, gdy oba urządzenia są online; B12),
  znikające wiadomości, udostępnianie ekranu, jawne nagrywanie, rozmowa
  w okienku. GIF-y z wyszukiwarki **klipy.com** (strona trzecia; S29, S37).
- **Konto:** hasło, krąg odzyskiwania (do 6 osób: hasło + 2 po 24 h albo
  4 bez hasła po 7 dniach), wiele urządzeń jednego konta, historia rozmów na
  nowym urządzeniu.
- **Profil i tablica:** profil z galerią i kartami wdzięczności, posty
  z widocznością (domyślnie „Wszyscy znajomi”), udostępnianie, lajki,
  komentarze, obserwowanie (bez listy obserwujących), „Zgłoś”.
- **Spotkania:** statusy „na teraz” (10 rodzajów + własny), alarm
  z położeniem, nagraniem, potwierdzeniami doręczenia i falą Bluetooth,
  osoby w pobliżu (Android), wydarzenia z biletami przypiętymi do telefonu,
  Stół na sześć, kółka obiadowe, plan na weekend, Zapytaj sieć, graf
  (wyszukiwanie, filtry, droga do osoby), przedstawienia i listy przez
  wspólnego znajomego.
- **Sąsiedzi, randki** (§18, §19) — pełne mechanizmy.
- **Piramida, władza, waluta, rynek dostępu** (§20–24) — zrobione w kodzie,
  widoczne w aplikacji, bez flagi funkcji; bez partii; łączenie piramid
  z przeliczeniem sald i wymiana przez „kantor”.
- **Odporność:** mosty na komputerach (UPnP/NAT-PMP, port 443), „Podaj
  dalej” (hotspot, Wi-Fi, Quick Share, USB z komputera, ze sprawdzeniem
  podpisu APK), jeden kod QR prowadzący do strony zaproszeń.
- **Ochrona danych:** szyfrowanie kluczem głównym (także załączników,
  głosówek i zdjęć znajomych; jawne zostają tylko własny awatar i tło
  profilu, §10), klucz w Keystore/TPM/Secure Enclave, blokada po 5 min
  w tle, blokada zrzutów, hasło paniki, ostrzeżenie o roocie.
- **Pierwsze uruchomienie:** hasło, potem ekran uprawnień i Bluetooth
  (§25.2), ten sam w Ustawieniach.
- **Licencja** (14.10.2026): każdy, także firmy i urzędy, może używać Zen
  do każdego celu; nie wolno go sprzedawać ani publikować forków (§2).

Zmiany ostatniej rundy: `CHANGELOG.md`, 1.10.0.

## 2. Podjęte decyzje

| Decyzja | Skutek / ryzyko |
|---|---|
| **Most na komputerze domyślnie włączony, bez komunikatu**; wyłącznik „Pomagaj innym się łączyć” na dole ustawień (Zaawansowane → Sieć i usługa) | Świadome ryzyko: UPnP i port 443 bez pytania, IP komputera widoczne w ogłoszeniach, nasłuch `tls://[::]:32913` kluczem węzła zdradza, czyj to komputer (§5.1, §26.1) |
| **Nie ma strony WWW**; stroną jest README repozytorium, a jedynym plikiem na GitHub Pages jest strona zaproszeń (`tool/pages/index.html`, publikowana przez `.github/workflows/pages.yml`) | Kody QR prowadzą do `robertostrowskijagoda.github.io/Zen/#KOD`: strona otwiera Zen (Android `intent://` z powrotem na stronę, gdy Zen brak; inne `zen://c/KOD`) albo pokazuje pobieranie; README ma przycisk „Otwórz w aplikacji” prowadzący na tę stronę (GitHub wycina linki `zen://` i `intent://` z README). Pages w darmowym planie wymaga publicznego repozytorium. Zen obsługuje oba linki bez weryfikacji domeny („Otwieraj obsługiwane linki”) |
| **Nazwa znajomego z jego profilu, nieedytowalna; lokalny pseudonim pod nią** | dwie osoby mogą mieć tę samą nazwę — odróżnia je pseudonim i zdjęcie |
| Kod zaproszenia bez mostów (8.10.2026) | nowa osoba startuje z publicznych węzłów |
| Pakiet Androida `com.roj.zen` (był `com.HuraganKodu.zen`) | to nowa aplikacja: stara instalacja zostaje obok z danymi; konto przenosi się podłączeniem urządzenia (§6.5), potem starą można odinstalować |
| Licencja (14.10.2026): PolyForm Strict 1.0.0 z dodatkowymi zezwoleniami — każdy, także firmy i urzędy, może używać Zen do każdego celu; wolno czytać kod, wysyłać pull requesty, budować z niezmienionego kodu i rozdawać niezmienione wydania (ta sama suma SHA-256); nie wolno sprzedawać Zen, brać opłat za udostępnianie ani dołączać go do płatnych produktów i usług; autor i zbiórka muszą zostać; forki i zmienione wersje zakazane | ciągłość projektu zależy od autora (§6 pkt 4); licencja nie jest wolna (OSI/FSF), więc F-Droid i IzzyOnDroid odpadają (§9); sklepy z aplikacjami wymagają publikacji przez samego autora |
| Tłumaczenia (14.10.2026): własne `t()` z polskim tekstem jako kluczem i plikami JSON zamiast ARB z §25.1; 21 języków; wybór zapisany zwykłym plikiem `language.txt` w folderze danych (potrzebny przed odblokowaniem i w usłudze w tle) | poprawka polskiego tekstu gubi jego tłumaczenia, dwa znaczenia tego samego napisu dostają jedno tłumaczenie (A23); wybrany język widać bez hasła |
| Linux i macOS w wydaniach (14.10.2026): archiwa z CI, bez podpisu; macOS **bez App Sandbox**, podpis ad hoc | Zen uruchamia `route`, `adb`, `open` (powód w `macos/Runner/Release.entitlements`); dane bez kontenera piaskownicy; po każdej aktualizacji macOS pyta o dostęp do pęku kluczy; od macOS 15 pierwsze uruchomienie tylko przez „Otwórz mimo to” (D10) |
| Biometria domyślnie wyłączona; blokada domyślnie po 5 min w tle | — |
| Asystent AI usunięty (V1.9) | — |
| Piramida bez partii (14.10.2026) | polityka to głosowania i delegowanie, bez list wyborczych |
| Ekonomia kontaktów bez piramidy: walutą jest zgoda (lista znajomych na prośbę, przedstawienia, list przez wspólnego znajomego); ceny tylko na rynku piramidy | brak waluty poza piramidą — mniej ryzyka prawnego (§24.1, §27) |
| Widoczność w pobliżu (rozgłaszanie BLE) włączana na ekranie uprawnień; rozglądanie się w tle domyślnie wyłączone | znajomi rozpoznają telefon obok; skanowanie tylko na ekranie „W pobliżu” |
| Gotowych bibliotek mostu Go nie ma w repozytorium — buduje je każdy build ze źródeł | do budowania potrzebne Go, NDK i kompilator C (README) |
| Zbiórka: `buycoffee.to/zen` (14.10.2026) | w wersjach do sklepów link trzeba usunąć albo zastąpić (§9) |

## 3. Znane błędy

| # | Błąd | Przyczyna / gdzie | Naprawa | P, rozmiar |
|---|---|---|---|---|
| B4 | Burza przy starcie (częściowo) | lista znajomych i klucze „W pobliżu” idą już raz, tylko po zmianie; paczki randkowe nadal naraz | rozłożyć paczki w czasie | P3, S |
| B6 | Wygrywa ostatni zapis | aplikacja i usługa w tle mają osobne kolejki zapisu tych samych plików (`meet_book.dart:708`) | jeden właściciel danych (A3, A15) | P2, L |
| B7 | Alarm ze skrótu przy zamkniętej aplikacji bez nagrania i zwykle bez świeżego położenia | brak usługi typu `location` i zgody na położenie w tle | §16.3 | P2, M |
| B8 | Android 10–11: skanowanie w tle nic nie znajduje | system wymaga zgody na położenie w tle | ekran uprawnień (§25.2) | P3, S |
| B11 | **Nieczytelne dane usuwają znajomych:** po nieudanym odczycie migawki (reset Keystore/TPM, uszkodzony plik i `.bak`, skopiowany profil Windows) aplikacja uznaje pusty stan za wczytany, każdy ping znajomego dostaje odruchowe `friend_remove` i w ~45 s wszyscy znajomi usuwają Cię u siebie | `social_hub_controller_lifecycle_signal.dart:194-197`, `runtime_signal_bridge.dart:174-232`, `android_background_runtime.dart:1662-1706` | tryb „uszkodzone dane, tylko odczyt”, bez odruchów (A14) — **naprawione w 1.10.0 (runda 2)** | P1, S |
| B12 | Wiadomość, która wygasła w kolejce skrzynek (14 dni), zostaje w czacie „wysłana”; zdjęcia, filmy i dłuższe głosówki (> 48 KB) nie idą przez skrzynki | `relay_engine.dart:47,65,166-247,1505-1513` | uczciwy stan dostarczenia, potem załączniki przez skrzynki (A18) — **częściowo w 1.10.0 (runda 2):** wiadomość wygasła w kolejce dostaje w czacie znak błędu, zbyt duża dla skrzynek wraca do „wysyłanej” (`takeDeliveryReports` → `SocialHubController`); zostają załączniki przez skrzynki | P1, S |
| B13 | „Zgłoś”: zgłoszonej treści nie da się ukryć u siebie, a odwołania nie ma w interfejsie (jest tylko `PyramidService.appeal`); okno zgłoszenia obiecuje „Usuń z mojego urządzenia”, którego nie ma; CHANGELOG twierdził, że to jest | `report_sheet.dart:23`, `pyramid_power.dart` | „Ukryj u siebie”, przycisk „Odwołaj się”, prawdziwy tekst — **naprawione w 1.10.0 (runda 2)** | P1, S |

Naprawione w 1.10.0: znajomi znajomych (B1, B2: listy osobno, odkładanie
ramek, skróty w powitaniu), zapis stanu przy każdym pong (B3), graf
rysowany bez przerwy (B5), rada „odinstaluj” w ADB (B9), alarm zablokowany
przez duży stan „Spotkań” (B10).

Wydajność na słabszym telefonie (A32): największy koszt to kryptografia
i składanie piramidy (A5), szyfrowanie w czystym Darcie i odpytywanie mostu
(A19). Mierzyć w `flutter run --profile`.

## 4. Bezpieczeństwo

To nie jest zewnętrzny audyt. Przed uruchomieniem piramidy i waluty
potrzebny jest niezależny przegląd, zwłaszcza kryptografii pierścieniowej
(§24, „Uczciwie”).

### 4.1 Otwarte

| # | Waga | Problem | Gdzie | Naprawa | P, rozmiar |
|---|---|---|---|---|---|
| S5 | Średnie | Przywitanie „W pobliżu” ujawnia stały adres, a UI mówi „nie Twoje konto” | `nearby.dart:487`, `nearby_screen.dart:87` | jednorazowy adres albo poprawny tekst | P2, M |
| S6 | Średnie | Jeden sekret „W pobliżu” dla wszystkich znajomych: znajomy może udawać przed innymi Twoją obecność, a także podpisać fałszywą falę alarmu w Twoim imieniu (S2 zamyka obcych, nie znajomych); zmiana tokenu niezsynchronizowana z rotacją MAC | `meet_book.dart`, `nearby_keeper.dart` | osobny sekret na znajomego, synchronizacja z MAC (§15) | P2, M |
| S10 | Średnie | Usługa w tle trzyma klucz główny, póki działa | §14.1 pkt 1 | usługa bez klucza głównego (osobne klucze dla odbioru) | P2, M |
| S11 | Średnie (decyzja) | Komputer jest mostem bez pytania (UPnP, `tls://[::]:32913`, port 443) i zdradza tożsamość | §5.1 | świadoma decyzja (§2); docelowo osobny klucz nasłuchu | P3, M |
| S13 | Niskie | „Podaj dalej” słucha na każdym prywatnym IPv4, HTTP w tej samej sieci | `share_app_server.dart:201–222` | tylko wybrany interfejs; integralność i tak sprawdza §14.3 | P3, S |
| S15 | Niskie | Odcisk certyfikatu nieopublikowany (`kOfficialApkCertificatesSha256` w `apk_signature.dart` pusty, więc komputer pokazuje tylko odcisk z werdyktem „nieznany”); Windows bez Authenticode | — | wpisać odcisk przy pierwszym podpisanym wydaniu (`WYDANIA.md` §2 pkt 4), §14.3 | P1, S |
| S16 | Niskie | Windows Hello bez sprzętowej zgody: program tego samego użytkownika może odpieczętować klucz, gdy włączone jest odblokowanie Hello (brak polityki UI w TPM); opisane w ustawieniach | — | brak prostego rozwiązania | P3 |
| S17 | Niskie | Token odebrania połączenia związany tylko z adresem, nie z numerem połączenia | — | wiązać z identyfikatorem połączenia | P3, S |
| S18 | Niskie | Rekord piramidy odrzucony w trakcie stosowania może zostawić część zmian (tak samo u wszystkich, bez rozjazdu) | — | stosowanie na kopii | P3, S |

Linki głębokie: żaden nie wykonuje akcji sam.

### 4.2 Drugi audyt (14.10.2026, runda 2)

Przegląd kodu tylko do odczytu (bez uruchamiania), stan 1.10.0+10. Własna
numeracja audytu S-1…S-20 odpowiada S19–S38 (kolumna „audyt 2”). Stan
naprawy w ostatniej kolumnie; testy przechodzą (`flutter test`, `go test`).

| # | audyt 2 | Waga | Problem | Gdzie | Naprawa | P, rozmiar | Stan |
|---|---|---|---|---|---|---|---|
| S19 | S-1 | Wysokie | Odzyskiwanie bez hasła nie jest związane z kontem: kawałki `rc_piece` przyjmowane od każdego, bez identyfikatora konta, więc nowe urządzenie może przyjąć cudze konto (a potem synchronizuje mu korespondencję i kontakty); obcy może zapełnić limit 24 połówek i podać drogie parametry Argon2 | `recovery_service.dart:255-358`, `account_recovery.dart:417-442`, `account_recovery_screen.dart:165-193` | pole `account` w kawałku, jedna połówka na nadawcę, przyjmowanie tylko przy otwartym ekranie, koszt równy `kRecoveryPasswordCost`; po odtworzeniu `fromSeed(seed).id == account`; przed przyjęciem odcisk konta i liczba pomocników | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S20 | S-2 | Wysokie | Most Go: kolejka 2048 sygnałów bez budżetu bajtów i rozpakowywanie zstd do 8 MiB od każdego węzła, zanim aplikacja sprawdzi nadawcę; w Darcie brak limitu przed `jsonDecode` — każdy, kto zna kod zaproszenia, może zawiesić aplikację i usługę w tle | `bridge_types.go:142-176`, `signal_reassembly.go:61-63,211-246`, `bridge_signaling.go:75-81`, `yggdrasil_signal_transport.dart:206-246` | niski limit wyniku i współczynnika kompresji, budżet bajtów kolejki (łącznie i na /64), limit szybkości na źródło, limit długości przed `jsonDecode` | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S21 | S-3 | Średnie | Rekord urządzenia w `acts` znajomego przyjmowany bez dowodu adresu: znajomy może przypisać sobie cudzy adres (ruch „na każde urządzenie konta”, cudzy poziom znajomości) | `ledger_node.dart:1049-1090` | rekord tylko jako wskazówka „przywitaj się tam”; adres dopiero po dowodzie z powitania | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S22 | S-4 | Średnie | Ostrzeżenie o plikach uruchamialnych do obejścia (`faktura.exe.`, spacja na końcu — Windows); brak ostrzeżenia dla plików z własnych urządzeń; zapisane pliki bez Mark-of-the-Web | `media_guard.dart:369-393`, `safe_file_name.dart:5-23`, `conversation_screen_media.dart:1952-2037` | obcinać końcowe kropki i spacje, podwójne rozszerzenia jako ryzykowne, ostrzeżenie też dla plików z synchronizacji, `Zone.Identifier` na Windows | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S23 | S-5 | Średnie | Adresy skrzynek (do 6 znajomych) ogłaszane domyślnie wszystkim członkom grup, także obcym; każdy członek grupy może po cichu dopisać adresy do listy członków | `relay_models.dart:289,417`, `relay_engine.dart:637-648,1720-1733`, `social_hub_controller_lifecycle_signal.dart:454-489` | skrzynki ogłaszane tylko znajomym; rozszerzanie listy członków tylko od twórcy grupy | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S24 | S-6 | Średnie | GitHub Actions: akcje przypięte ruchomym tagiem (także zewnętrzna `subosito/flutter-action`) w jobie z kluczem APK i `contents: write`; `workflow_dispatch` podpisuje kod z dowolnej gałęzi; brak środowiska z zatwierdzeniem | `.github/workflows/release.yml` (też `ci.yml`, `ios.yml`, `pages.yml`) | akcje przypięte pełnym SHA; klucz tylko dla tagów `v*`; podpis w osobnym jobie w `environment:` z zatwierdzeniem (D11) | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S25 | S-7 | Średnie (częściowo niepewne) | iOS: pliki trafiają do kopii iCloud/iTunes, wpisy Keychain z domyślną dostępnością (też macOS), `UIFileSharingEnabled`; brak ochrony zrzutów i zasłony w przełączniku aplikacji | `app_security_service.dart:142-160`, `secure_screen.dart:24-25`, `ios/Runner/Info.plist` | `isExcludedFromBackup`, `…ThisDeviceOnly`, `UIFileSharingEnabled=false`, zasłona przy przejściu w tło | P2, S | częściowo naprawione w 1.10.0 (runda 2): Keychain `…ThisDeviceOnly`, wykluczenie z kopii, zasłona w przełączniku; `UIFileSharingEnabled` zostaje (zapisy do Files) |
| S26 | S-8 | Niskie | Blokada „po 5 min w tle” zakłada się dopiero przy powrocie — klucz główny i interfejs zostają w pamięci przez cały czas w tle; na komputerze brak blokady po bezczynności | `app_security_gate.dart:42-68` | zegar blokady od przejścia w tło; blokada po bezczynności na komputerze (por. S10) | P2, S | **naprawione w 1.10.0 (runda 2)** |
| S27 | S-9 | Niskie | Ochrona ekranu i pusta miniatura w „Ostatnich” tylko na wybranych ekranach: lista czatów z podglądem treści, graf, profile i randki niechronione (także macOS) | `ZenSecurityBridge.kt:58-77`, `secure_screen.dart` | brak miniatury przez cały czas, gdy blokada zrzutów jest włączona; lista czatów i randki pod ochroną | P2, S | **naprawione w 1.10.0 (runda 2)** |
| S28 | S-10 | Niskie (niepewne) | Gdy przypięte SDP zostanie odrzucone, stosowany jest oryginał rozmówcy — ICE może połączyć się poza Yggdrasil (ujawnienie IP) | `call_media_session.dart:1949-1960`, `group_call_media_webrtc.dart:736-741` | przerwać rozmowę albo usunąć `a=candidate` z oryginału | P2, S | **naprawione w 1.10.0 (runda 2)** |
| S29 | S-11 | Niskie | GIF od rozmówcy pobierany automatycznie z klipy.com: IP odbiorcy u strony trzeciej, znajomy wie, kiedy otwarto czat; bajty idą do systemowego dekodera z pominięciem `media_guard` | `animated_gif.dart:43-177`, `remote_media_guard.dart` | pobieranie po dotknięciu; docelowo nadawca wysyła bajty jako załącznik przez `media_guard`, bez `gifUrl` | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S30 | S-12 | Niskie | „Powiadomienia bez treści” ukrywają treść, ale nie tytuł („X idzie na randkę”, „Odpowiedź: {pytanie}”, „Zaproszenie: {wydarzenie}”) | `runtime_system_notifications.dart:217-225`, `dating_service.dart`, `ask_service.dart:523`, `event_service.dart:1141` | ogólny tytuł dla kategorii wrażliwych; jawne zostają alarmy i połączenia | P2, S | **naprawione w 1.10.0 (runda 2)** |
| S31 | S-13 | Niskie | Fale alarmu BLE: globalny limit 40/min liczony przed sprawdzeniem podpisu — zmieniając MAC, można zagłuszyć prawdziwy alarm | `ZenNearbyBridge.kt:107-109,598-620` | osobna pula dla fal ze sprawdzonym podpisem znajomego | P2, S | **naprawione w 1.10.0 (runda 2)** |
| S32 | S-14 | Niskie | Podłączanie urządzenia: pierwszy `al_hello` zajmuje sesję — obcy znający adres może zablokować podłączanie (przejęcia nie ma: chroni commit–reveal i 6 cyfr) | `account_link.dart:286-311` | kilka równoległych prób albo reset sesji przy niezgodnych cyfrach | P3, S | **naprawione w 1.10.0 (runda 2)** |
| S33 | S-15 | Niskie | Windows: narzędzia systemu po samej nazwie (`route`, `taskkill`, `explorer`, `adb`); `taskkill /IM zen.exe` ubija każdy proces o tej nazwie, gdy obcy program zajmie port blokady 47821; IPC aktywacji bez uwierzytelnienia | `single_instance_guard.dart:80-113,270-283`, `port_mapper.dart:502,513` | pełne ścieżki; zabijać tylko własne procesy | P3, S | **naprawione w 1.10.0 (runda 2)** |
| S34 | S-16 | Info | Dziennik diagnostyczny jawnym tekstem obok danych (adresy mostów, opis routera, nazwy plików) | `zen_log.dart:28-79` | dziennik w sejfie albo czyszczony przy blokadzie; szersza redakcja | P3, S | **naprawione w 1.10.0 (runda 2)** |
| S35 | S-17 | Info | List i przedstawienie przez wspólnego znajomego bez podpisu autora — pośrednik może zmienić tekst, adres i nazwę | `intro_service.dart:938-992` | autor podpisuje treść, odbiorca sprawdza | P3, S | **naprawione w 1.10.0 (runda 2)** |
| S36 | S-18 | Info | Zgłoszenie: dowód to tekst zgłaszającego; ban treści po skrócie całego tekstu (dopisana spacja go omija) | `content_moderation.dart:28-54` | podpisany oryginał wpisu; ban po identyfikatorze wpisu | P3, S | otwarte |
| S37 | S-19 | Info | Wbudowany wspólny klucz API Klipy (komentarz twierdzi, że go nie ma); wyszukiwane hasła i IP idą do klipy.com, `locale=pl_PL` na sztywno; nigdzie nieopisane | `chat_gif_catalog.dart:7-96` | prawdziwy komentarz; w UI, README i polityce prywatności, że wyszukiwanie łączy się z klipy.com; rozważyć wyłączenie domyślnie | P1, S | **naprawione w 1.10.0 (runda 2)** |
| S38 | S-20 | Info | Drobne: DNS na sztywno 8.8.8.8 / 1.1.1.1 (Android); `FLUTTER_TEST` w środowisku wyłącza wymóg hasła; przekaźnik UDP rozmów przyjmuje pierwszy proces lokalny; odpowiedź obcemu zdradza, że urządzenie jest online; DLL mostu szukana też w katalogu bieżącym (Windows) | `android_net.go`, `app_bootstrap.dart:140-149`, `bridge_relay.go`, `yggdrasil_bridge_ffi.dart:133-137` | DoH/DoT albo własne serwery; `kDebugMode` zamiast zmiennej; DLL tylko obok `zen.exe` | P3, S | częściowo naprawione w 1.10.0 (runda 2): `FLUTTER_TEST` tylko poza wydaniem, DLL tylko obok `zen.exe`, brak odpowiedzi obcym; otwarte: DNS, przekaźnik UDP |

Poza audytem: **brak kanału zgłaszania podatności** (przegląd architektury
K9) — `SECURITY.md` i prywatne zgłaszanie podatności na GitHubie (włącza się
w ustawieniach repozytorium); naprawione w 1.10.0 (runda 2): `SECURITY.md`.

**Sprawdzone i w porządku:**
- koperta ZENENC2 (AES-256-GCM z AAD, podklucze HKDF, porównania w stałym
  czasie, odrzucanie ZENENC1 i jawnego tekstu, ukryte nazwy plików);
- Argon2id: 19 MiB dla hasła aplikacji (raczej nisko — do rozważenia),
  64 MiB dla kręgu, odrzucanie absurdalnych kosztów; sejf mediów (segmenty
  AES-GCM z AAD, losowe nazwy);
- ścieżki w magazynie (`_sanitizeKeySegments`) i `safeFileName` (poza S22);
- kryptografia skrzynek i randek (X25519 + HKDF + ChaCha20-Poly1305 z AAD,
  dwuwarstwowe pudełko); podpis pierścieniowy (kanoniczny obraz klucza,
  odrzucanie torsji, brak wyjątków przy złym wejściu);
- `media_guard` (poza GIF-ami, S29, i filmami — świadome ryzyko); limity
  ramek przychodzących (załączniki, bloby, wpisy 64 KiB, budżet obcych na
  /64, parser sygnałów, składanie w Go — poza zstd, S20);
- token odebrania rozmowy; pilot testowy tylko w wersji debug z kontrolą
  Host; manifest Androida; weryfikacja podpisu APK (brakuje tylko odcisku,
  S15); serwer „Podaj dalej”; aktualizacje przez sieć (wyłączone, 2 z 3,
  7 dni); FFI (klucz węzła nie przechodzi); most Go (ramki spoza adresów
  węzłów odrzucane, `AdminListen=none`);
- Linux i macOS: bez nowych błędów wysokiej i średniej wagi. macOS: klucz
  w Secure Enclave z `.biometryCurrentSet` i `…ThisDeviceOnly`, ochrona
  ekranu jak na Windows (dotyczy go S27); brak piaskownicy to decyzja (§2).
  Linux: biblioteka mostu ładowana ścieżką bezwzględną (bez katalogu
  bieżącego, lepiej niż Windows w S38).

### 4.3 Naprawione w 1.10.0 (pierwsza runda)

- **S1 (wysokie):** `report` i `appeal` piramidy tylko od członków (adres
  urządzenia powiązany z kluczem) i tylko do tych, którzy je rozpatrują;
  limity długości, na nadawcę i łącznie; osobny zapis `pyramid/reports`.
  Limity także dla propozycji do podpisu i wiadomości rynku.
- **S2 (wysokie):** fala alarmu przez Bluetooth podpisana HMAC-SHA256
  sekretem „W pobliżu”, ważna ±10 min, powtórki odrzucane; dzwoni tylko
  sprawdzony alarm znajomego, obcy — cicha notka, najwyżej raz na 10 min;
  limity fal w Kotlinie.
- **S3 (wysokie):** załączniki, głosówki i zdjęcia znajomych w sejfie
  (`media_vault.dart`, AES-GCM w segmentach, losowe nazwy), zdjęcia tylko
  w pamięci, nagrania i filmy w krótkotrwałej kopii; ukryte nazwy
  `transfers/`.
- **S4 (średnie):** magazyny otwierają tylko kopertę ZENENC2 związaną
  z miejscem zapisu; konfiguracja węzła zapieczętowana dla swojego klucza;
  pamięć `ring-ok` z HMAC.
- **S7 (średnie):** hasło paniki zatrzymuje usługę i kasuje cache, pliki
  tymczasowe, `Android/data/…/files`, foldery Zen w Dokumentach i Pobranych
  oraz zapisane kopie (lista eksportów).
- **S8/B10 (średnie):** alarm wychodzi przed zapisem; limity pól, liczby
  odpowiedzi i alarmów.
- **S9/B9 (średnie):** sprawdzanie certyfikatu APK w „Podaj dalej” i ADB;
  bez rady „odinstaluj”, z ostrzeżeniem o podróbce.
- **S12 (niskie):** podpisy skarbników scalane, nie zastępowane.
- **S14 (niskie):** stare formaty zaproszeń usunięte.
- **Waluta:** limity kwot i sald (bez przekręcenia 64 bitów), ponowne
  potwierdzenie przed każdą płatnością, blokada zrzutów w portfelu.

Wcześniej w tej samej wersji:

- **Złośliwe media** (wysokie): zdjęcia od innych trafiały wprost do
  systemowego dekodera obrazów (Skia/libwebp), a typ załącznika brano od
  nadawcy. Teraz `media_guard.dart`: zdjęcia kodowane od nowa czystym
  Dartem (czat, posty, profile, randki), limit pikseli przed dekodowaniem,
  filmy/nagrania tylko z poprawnym kontenerem, typ i nazwa z zawartości,
  ostrzeżenie przed zapisem plików wykonywalnych. Zostaje: filmy nadal
  dekoduje system (nie da się ich przekodować na telefonie).
- **Podszywanie się nazwą** (średnie): nazwa znajomego była dowolnym
  tekstem nadanym lokalnie albo przez link. Teraz pochodzi z profilu tej
  osoby, oczyszczona ze znaków sterujących i kierunku tekstu; własne
  oznaczenie to osobny pseudonim.
- **Path traversal w „Zapisz kopię”** (wysokie): nazwa pliku od innej osoby
  mogła nadpisać pliki w katalogu aplikacji
  (`conversation_screen_media.dart`, `runtime_signal_parser.dart`). Teraz
  `safeFileName` przy odbiorze i zapisie.
- **Blokada działała inaczej, niż obiecywał interfejs** (średnie): domyślnie
  blokada po 5 min w tle (wcześniej tylko po restarcie telefonu), teksty
  ekranu blokady zgodne z prawdą (usługa w tle dalej odbiera wiadomości).

### 4.4 Naprawione wcześniej (audyt V1.10)

- `friend_accept` od obcego robił z niego znajomego — teraz nieproszona
  akceptacja to zwykłe zaproszenie; wzajemne zaproszenia w tej samej chwili
  dają znajomość od razu.
- Zablokowana aplikacja zrywała znajomości (sygnały na pustym stanie,
  także pingi) — sygnały czekają na odczyt danych po odblokowaniu, w tej
  samej kolejce. (Ten sam odruch przy nieczytelnych danych: B11.)
- Piramida: zły podpis pierścieniowy nie wysypuje liczenia, kanoniczne
  obrazy kluczy (bez podwójnych głosów), rekordy z przyszłości odrzucane,
  świeży czas przy podpisie, świadkowie przy zamknięciu i odwołaniu
  delegacji, opóźnione emisje czekają 24 h, konstytucja z kworum, limit
  emisji na 30 dni, synchronizacja tylko ze znajomymi.
- Limit dekompresji zstd przed rozpakowaniem; składanie fragmentów w Go
  z limitami na źródło; ramki spoza adresów węzłów (/64) odrzucane.
- Limity na: prośby o znajomość, zaproszenia do grup i wydarzeń (podszywanie
  w polu `by`), załączniki, obrazy (bomby JPEG/PNG), paczki randkowe,
  skrzynki offline (osobna „podłoga” na nadawcę, budżet dla obcych),
  odpowiedzi na pytania, alarmy, sesje „W pobliżu”.
- Odebranie połączenia przez link wymaga jednorazowego tokenu; link nie
  ustawi fałszywego imienia.
- Android: komponenty nieeksportowane, `FileProvider` tylko `cache/shared_apk`,
  kopie zapasowe wyłączone, pusta miniatura w „Ostatnich”, brak logów
  w wydaniu; pilot testowy tylko w wersji debug z kontrolą nagłówka Host.
- `threads/` i `relay/mail/` z ukrytymi nazwami; ZENENC2 z AAD; panic
  najpierw niszczy klucze; Keystore z silną biometrią; Windows: klucz
  pieczętowany tylko po włączeniu Windows Hello.
- Łączenie urządzeń z zobowiązaniem (commit–reveal); dowód adresu
  w powitaniu urządzeń.
- Zmiana hasła i hasła paniki wymaga potwierdzenia, oba nie mogą być takie
  same; treść powiadomień ukryta także dla randek i piramidy.
- Aktualizacje 2 z N (wyłączone); `key.properties` i `*.jks`
  w `.gitignore`; potwierdzenia alarmu tylko od tych, do których poszedł.

Testy regresyjne: `test/inbound_limits_test.dart`,
`test/pyramid_security_test.dart`, `test/pyramid_attack_sim_test.dart`,
`test/ring_signature_test.dart`, `test/relay_engine_test.dart` (grupa
`hardening`), `test/account_link_test.dart`, `test/app_data_reset_test.dart`,
`test/hidden_store_names_test.dart`, `test/ledger_stranger_flood_test.dart`,
`test/share_app_server_test.dart`, `test/mutual_request_test.dart`, testy Go
w `native/yggdrasil_bridge`.

### 4.5 Świadome ograniczenia

- Odzyskiwanie: dwóch zmówionych pomocników może zgadywać hasło offline
  (Argon2id 64 MiB); opóźnienia pilnują tylko uczciwe aplikacje.
- Randki: przerobiona aplikacja dostanie klucz paczki nowym kluczem
  randkowym i widzi jednostronne „Tak”.
- Piramida: zmowa wszystkich wymaganych podpisów może cofnąć datę
  rekordu; scalenie piramid opiera się na podpisie szczytu źródła.
- Mieszane wersje: wersje sprzed 1.10.0 nie są obsługiwane (kod zgodności
  usunięty przed pierwszym wydaniem).

## 5. Architektura

| # | Problem | Gdzie | Kierunek | P, rozmiar |
|---|---|---|---|---|
| A1 | Potwierdzenie przed obsługą ramki (B2) | `relay_engine.dart:462`, `meet_service.dart:173-176` | ack po obsłużeniu / odkładanie; skrót wersji „stanu” w powitaniu | P1, M |
| A2 | Stan ulotny zapisywany całym plikiem w wątku UI (B3); docelowo brak bazy | `social_hub_controller_social.dart:1417-1446` | teraz debounce i obecność w pamięci (S); docelowo szyfrowany SQLite (L) | P1 S / P3 L |
| A3 | **Dwa środowiska na tych samych plikach** (aplikacja i usługa w tle), część obsługi skopiowana, logika w warstwie UI | `android_background_runtime.dart:1393-1408` tworzy drugi komplet serwisów; `AlarmWatcher` (`alarm_screen.dart:1257`) działa równolegle z `_datingTimer` usługi (`:1471`); osobne kolejki zapisu (`meet_book.dart:708`) | jeden właściciel danych i usług (usługa), interfejs jako klient; krok 0: A15 | P2, L |
| A4 | Osobne mechanizmy rozsyłania zamiast przestrzeni dziennika (skrzynki, piramida, randki, łańcuchy wydarzeń i pytań, sąsiedzi); relay trzyma ręczną listę ~90 typów ze wszystkich funkcji (`kReliablePayloadTypes`, `_directOnlyPayloadTypes`) obok typowanego `ZenSignal` | `space_policy.dart:35-53`, `relay_engine.dart:166-268`, `zen_signal.dart:5-47` | nowe funkcje na przestrzeniach dziennika; jeden mechanizm „stan znajomego”; każdy moduł rejestruje swoje typy z polityką (`reliable`, `directOnly`, `maxBytes`, `ttl`) | P3, M–L |
| A5 | **Kryptografia w czystym Darcie w wątku UI**; piramida składana od zera co 60 s; każdy członek trzyma wszystkie rekordy | `ledger_identity.dart:50`, `ledger_store.dart:176`, `pyramid_record.dart:155,181`, `pyramid_service.dart:1576,1604`, fold `:457-471` | krypto w Go przez FFI albo osobny izolat; fold przyrostowy; podpisane punkty kontrolne; telefon trzyma swoją gałąź | P2, M |
| A6 | Piramida ujawnia adres urządzenia (łamie §6.4) | `pyramid_service.dart:3534-3537` → `pyramid_state.dart:1320-1325` | ruch przez relaye, bez adresu w stanie | P2, M/L |
| A7 | Klucz piramidy losowy na każdym urządzeniu: zgubiony telefon = utrata portfela; telefon i PC to dwie osoby | `pyramid_service.dart:820-829` | HKDF z klucza konta | P1, S/M |
| A8 | Brak wspólnego schematu i wersji: enumy po numerze, protokół bez wersji, dziesiątki gałęzi „starsza wersja” | `social_snapshot_store.dart:51,67,92,117,520`; `attachment_transfer_store.dart:522` | przed wydaniem wyzerować formaty, enumy po nazwie, możliwości (caps) w powitaniu (§7); wersja w sieci: A17 | P1, S/M |
| A9 | Bateria: stała blokada uśpienia i Wi-Fi, ping co 45 s także w tle, brak trybu „tylko Wi-Fi” | `android_background_runtime.dart:589-590`, `:1800-1830` | obecność zdarzeniowa, tryb oszczędny, media tylko Wi-Fi; odpytywanie mostu: A19 | P2, M |
| A10 | Tożsamość = klucz węzła Yggdrasil (adres = kod zaproszenia, bez rotacji) | — | tożsamością klucz konta, węzły wymienne (§6.1) | P3, L |
| A11 | Cały ruch, także wideo, przez Yggdrasil, bez ścieżek bezpośrednich | — | bezpośrednie połączenia, gdy się da; most jako serwer rozmów grupowych | P3, M |
| A12 | Wielkie obiekty: `PyramidService` to jedna klasa ~4,7 tys. linii (84 metody `Future`), `PyramidState` ~2,2 tys., kontroler czatów ~11,9 tys. linii w 11 częściach `part` ze wspólnym prywatnym stanem, `app_shell_screen_views.dart` ~4 tys. linii (~40 klas), jeden pakiet | `pyramid_service.dart`, `pyramid_state.dart`, `features/social/*`, `app_shell_screen_views.dart` | `PyramidSync` / `PyramidFold` / `PyramidProposals` / `Wallet` / `Market` / `Reports`; `CallCoordinator`, `TransferCoordinator`, `PresenceService`, `FriendshipService`, `DeviceSync` jako osobne `Notifier`; ustawienia w `settings/` po pliku na sekcję; potem pakiety (`zen_core`, `zen_transport`, `zen_pyramid`…) | P3, L |
| A13 | Testy i proces: CI jest (§8), ale testy idą tylko na Windows, bez APK przy pushu i bez emulatora; usługa w tle (~2,3 tys. linii) ma 5 testów, kod Kotlin (BLE, rozmowy) żadnego; brak fuzzingu wejść sieciowych w Go, testu uszkodzonych danych (B11), testów `group_call_media_webrtc.dart`, złotych próbek protokołu; `sim_network.dart` leży w `lib/` | `.github/workflows/ci.yml`, `native/yggdrasil_bridge`, `lib/src/dev/sim/` | `go test -fuzz` dla `parseYggPacket`, składania i zstd; test „uszkodzona migawka nie wysyła ani jednej ramki”; `flutter test` także na Linuksie; symulator do `test/support`; mniejsze wydania | P2, S |
| A14 | **Odruchy niszczące** (przegląd A1, K12): automatyczne odpowiedzi usuwają coś u drugiej strony — `friend_remove` na ping „obcego” (B11); to samo może zrobić nowo podłączone urządzenie przed synchronizacją (`AccountRoutingTransport` przepisuje nadawcę na konto — do sprawdzenia w symulatorze) | `runtime_signal_bridge.dart:174-232`, `social_hub_controller_helpers.dart:131-142`, `account_routing_transport.dart:91-130` | tryb tylko do odczytu przy nieczytelnych danych (jak usługa w tle); zamiast odruchu nieniszczący `peer_unknown`; `friend_remove` tylko z akcji człowieka, podpisany kluczem konta, z 7-dniowym miękkim usunięciem; testy regresyjne | P1, S |
| A15 | **Korzeń kompozycji w widżetach** (przegląd A2, A5): 8 zagnieżdżonych „mostów” w `app.dart`, `RuntimeSignalBridge` tworzy 14 usług, `AlarmWatcher` prowadzi zegary randek i piramidy i po powrocie przeładowuje 8 usług, usługa w tle składa inny zestaw ręcznie; providery robią IO i sieć w ciele; `ZenPersistentStores` po cichu podstawia magazyny w pamięci | `app.dart:65-79`, `runtime_signal_bridge.dart:86-108`, `alarm_screen.dart:1392-1471`, `pyramid_providers.dart:10-36`, `persistent_stores.dart:28-31` | `ZenCore` (czysty Dart, `start`/`stop`) z rejestrem `FeatureModule` — ten sam w interfejsie i w usłudze; flagi funkcji jako lista modułów; usługi bez efektów w konstruktorze; wymagane magazyny zamiast cichych `Memory*` | P1, M |
| A16 | Cykliczne zależności między funkcjami (przegląd A3): piramidę importują tablica, spotkania, randki i moderacja; `runtime` ↔ `shell`; `domain/` importuje `social` — wydanie „rdzeń” wymaga `ref.exists(pyramidServiceProvider)` w wielu miejscach | `report_content.dart:40-52`, `friend_profile.dart:3` | porty w `domain/` (`ContentBanPolicy`, `PaymentPort`, `FriendDirectory`, `ClockPort`); reguły importów w CI | P2, M |
| A17 | **Sieć bez świadomości wersji** (przegląd K6, A10): wersja aplikacji nie idzie w ping/pong ani powitaniu, nieznane przestrzenie są odrzucane (wbrew §1.6), aktualizacje przez sieć wyłączone — sieć po cichu rozjedzie się na wersje bez łatek | `app_version.dart`, `space_policy.dart:55-71` | `ver`/`build`/`caps` w ping/pong; podpisany znacznik wydania rozchodzący się plotką, z belką „Jest Zen 1.11 — u 4 znajomych”; nieznane przestrzenie „przechowaj i przekaż” z limitem; złote próbki ramek (`test/wire/`) i test mieszanych wersji | P1, S |
| A18 | **Skrzynki offline obiecują więcej, niż robią** (przegląd K3, A8): do skrzynek trafiają tylko typy niezawodne do 48 KB; po 14 dniach wiadomość znika z kolejki bez śladu (B12); pliki idą trzema osobnymi mechanizmami (kanał WebRTC — cały plik w pamięci; kawałki po sygnałach; bloby dziennika) | `relay_engine.dart:47,65,166-247,1505-1513`, `realtime_attachment_transfer.dart`, `attachment_transfer_store.dart`, `blob_store.dart` | (S) stan w bańce: „czeka u znajomych” / „czeka, aż oboje będziecie online” / `failed` z „Wyślij ponownie”; (M) załączniki jako zaszyfrowane bloby dziennika, relaye odbiorcy jako źródła — jedna warstwa blobów | P1 S / P2 M |
| A19 | **Gorące ścieżki** (przegląd A6, rozszerza A5): odpytywanie mostu FFI co ≤400 ms (w usłudze w tle co ≤2 s — budzenie przez całą dobę, dzwonek do 2 s później); ramka JSON → zstd → base64 → kawałki 1300 B w JSON (~40% narzutu, zgubiony kawałek = cała wiadomość); AES-GCM w czystym Darcie przy każdym zapisie (brak `cryptography_flutter`); tablica liczona od zera w `build()`, 68× `ListView(` wobec 5 builderów; start czyta cały dziennik wszystkich znajomych i niczego nie usuwa | `yggdrasil_signal_transport.dart:124-246`, `bridge_signaling.go:100-172`, `app_security_crypto.dart:66-93`, `feed_screen.dart:615-654`, `ledger_archive.dart:126-200` | (S) `cryptography_flutter` i kopiowanie bez spreadów; (M) `NativePort` z Go zamiast odpytywania; (S/M) tablica przyrostowo i listy leniwe; (M) leniwe segmenty, okno 12 mies. dla cudzych logów; (P3, M) binarna koperta i powtarzanie pojedynczych kawałków | P2, M |
| A20 | **Trwałość** (przegląd A7): twardy limit 20 MB na plik przy stanach w jednym JSON (`dating/state` ze zdjęciami, `meet/state`) — po przekroczeniu zapis po cichu przestaje działać; nazwy `meet/list/<sha256(adres)>` i `ledger/log-<sha256>` to niekluczowane skróty (zajęty telefon + lista kodów = „ma tę osobę w znajomych”); Windows: dane w Roaming AppData (kopia profilu = drugi komputer z tym samym kluczem → rozwidlony log bez słowa w UI); osierocone `*.tmp` | `binary_store.dart:55,91,346-349,487-492`, `meet_book.dart:801`, `ledger_archive.dart:117`, `zen_instance.dart:36` | ostrzeżenie przy 50% limitu, zdjęcia jako bloby; `meet/list/` i `ledger/` w ukrytych nazwach (HMAC); `%LOCALAPPDATA%` i wykrywanie własnego rozwidlenia z nowym kluczem urządzenia | P2, S |
| A21 | Zegar jako cichy filtr (przegląd K11): tolerancje w każdym podsystemie inne (relay 1 doba, dziennik 10 min, stół i kółka 10 min, bilety ±90 s); telefon spieszący się 15 min jest wszędzie po cichu odrzucany | `hlc.dart:42`, `relay_engine.dart:73`, `table_service.dart:22` | czas w pong; belka „Twój zegar spieszy się o 14 min”; tolerancje w jednym miejscu | P2, S |
| A22 | Porażki niewidoczne dla człowieka (przegląd A11): 636 `unawaited`, 53 `catch (_)` (17 pustych); błąd zapisu, odrzucony rekord, rozwidlony log, wygaśnięcie i przepełnienie kolejki w Go kończą jako linijka w dzienniku | — | `HealthReport` (ostatni udany zapis, odrzucone ramki wg powodu, rozmiary plików, zegar, wersje znajomych) na ekranie diagnostyki i belka „Coś jest nie tak — pokaż”; raport do wysłania ręcznie | P2, S |
| A23 | Tłumaczenia — pułapki (przegląd A12): teksty zlokalizowane zapisywane w stanie (`InboxEntry.title/body`, „Teraz”, wiadomości systemowe) zostają w starym języku; klucz = polski tekst (poprawka gubi tłumaczenia, „Zapisz” jako save i sign up ma jedno tłumaczenie, brak rodzaju gramatycznego); GIF-y z `locale=pl_PL` | `social_hub_controller_helpers.dart:38,105,642-664`, `social_hub_controller_messages.dart:762`, `chat_gif_catalog.dart` | zapisywać kod zdarzenia i argumenty, tekst budować przy wyświetlaniu; opcjonalny `context:` w `t()`; narzędzie oznacza tłumaczenia „do przejrzenia” zamiast je gubić | P1, S |
| A24 | Platformy (przegląd A14, U6): 85× `Platform.isAndroid`, 49× Windows, 26× macOS/Linux w 39 plikach; komputer dostaje kolumnę telefonu 430 px | `app.dart:84-124` | `PlatformCapabilities` (BLE, praca w tle, nagrywanie, most, okienko); od 900 px dwa panele (lista czatów + rozmowa), skróty klawiszowe | P3, S/M |

Propozycje: wydanie „rdzeń” za flagami funkcji (krok 0: A15); jeden
mechanizm „stan znajomego”; most Go jako silnik kryptografii i bazy (FFI,
SQLite); ekran diagnostyki (połączenia, skrzynki, listy znajomych, kolejki,
A22); próba obciążenia przed szerszym wydaniem (150 znajomych, 2 lata
historii, randki: czas startu, pamięć, rozmiary plików, ruch na dobę).

## 6. Koncepcja

1. **Randki rosną jak trzecia potęga liczby znajomych**
   (`dating_service.dart:67,76,83,578-584`): paczka 8–52 KB od każdego co
   tydzień, do 3 kroków; przy ~150 znajomych dziesiątki tysięcy paczek
   tygodniowo. Naprawa: latarnie ~100 B na żądanie, 2 kroki (§19.7). P2, L.
2. **Ekonomia kontaktów oparta na walucie**: towarowość znajomości, ryzyko
   KNF/AML, nazwa „Piramida” kojarzy się z piramidą finansową (także
   recenzentom sklepów, §9). Najpierw wersja bez pieniędzy (§24.1); piramida
   i waluta za flagą. P1, S.
3. **„Prywatność domyślnie” niespełniona**: lista znajomych domyślnie
   włączona i idzie do wszystkich, także słabych znajomych
   (`meet_book.dart:481`, `meet_service.dart:992`), wbrew §8; statusy też
   widzą słabi znajomi, zaproszenia do grup bez progu poziomu; profil
   w dzienniku publiczny z adresem (`ledger_profile.dart:57-70`); publiczne
   posty może obserwować każdy, kto zna adres (wycieka kodem na drzwiach,
   pkt 15, i przywitaniem Bluetooth, S5); brak bramki wieku. P1, S.
4. **„Bez kluczy do wydań” to fikcja**: klucz APK to jeden klucz jednej
   osoby, a do tego leży w sekretach GitHub Actions (D11); licencja zabrania
   forków, więc po zniknięciu autora nikt legalnie nie kontynuuje; jawny
   klucz APK byłby groźny. Naprawa: rotacja v3, depozyt Shamira, podpis poza
   CI, decyzja o licencji (np. zgoda na kontynuację, gdy autor zniknie)
   i ewentualnie fundacja. P1, S/M.
5. **Mosty bez zgody** (UPnP, port 443) — świadoma decyzja (§2).
6. **Każdy telefon przechowuje i oddaje dalej media znajomych** (domyślnie
   pobiera wszystko): bateria, dane, nieświadome przechowywanie cudzych
   treści. Domyślnie tylko Wi-Fi, limity. P2, M.
7. **Zimny start.** Komunikator ma wartość, gdy są w nim znajomi; bez
   iPhone'a jedna osoba z iOS wyklucza grupę. Potrzebny wąski klin wejścia
   (sąsiedzi w jednym bloku albo spotkania w jednym mieście) i prosta pętla:
   dodaj znajomego → napisz → umówcie się → spotkajcie się.
8. **„Bez serwerów” jest częściowo prawdą**: sieć stoi na publicznych
   węzłach wolontariuszy Yggdrasil (projekt eksperymentalny), komputerach-
   mostach i skarbnikach online. Publiczny węzeł widzi IP i stały klucz
   węzła, czyli kod zaproszenia — kto dopisze węzeł do listy, może zbierać
   mapę „IP ↔ osoba w Zen” (przegląd K7; docelowo rotowane klucze węzła,
   A10). Wyszukiwarka GIF-ów idzie do komercyjnego klipy.com z wbudowanym
   kluczem (S29, S37) — wbrew „bez reklam” i „nie ma serwera, który
   wszystko widzi”. Uczciwiej: „sieć prowadzona przez użytkowników”, zdanie
   o metadanych w README. P2, S.
9. **Niezawodność bez push**: wszystko zależy od usługi w tle, którą
   zabijają producenci (Xiaomi, Samsung) i tryb uśpienia. Alarm działa,
   gdy telefony przyjaciół mają węzeł — stąd potwierdzenia doręczenia
   (zrobione) i zapasowy SMS (do zrobienia).
10. **Moderacja**: przed piramidą jej nie ma; moderacja przez hierarchię
    polityczną to konflikt interesów.
11. **Piramida**: drzewo binarne to wąskie gardło wzrostu, szczyt jest
    okopany, te same ~15 osób ma emisję, skarb i bany, anonimowość głosu
    w trójce jest znikoma; sekcje narodowościowe to prawo wyborcze (partii
    już nie ma). **Żywotność władzy** (przegląd K5): kworum konstytucji
    liczone od wszystkich miejsc (także martwych i fałszywych) i wymóg pełnej
    sumy każdej gałęzi — wydmuszki albo jedna komórka offline blokują zmianę
    konstytucji; próg sekcji krajowej (~100 osób) przejdą te same wydmuszki;
    przelew potrzebuje 8 z 15 skarbników online. Kierunek: kworum od
    aktywnych (60 dni), suma z limitem czasu, scenariusz „paraliż przez
    nieobecność” w symulatorze. P2, S/M.
12. **RODO**: dane szczególne (art. 9), autor jako możliwy
    współadministrator, „prawo do usunięcia” a podpisane łańcuchy; brak
    polityki prywatności i regulaminu (§27).
13. **Rozrost funkcji**: 13 zakładek, hasło od pierwszego uruchomienia,
    25-znakowe kody, pojęcia krąg, mosty, poziomy, piramida — za dużo dla
    osoby nietechnicznej. Odpowiedź: rdzeń za flagami, grupowanie zakładek
    (§25), proste powitanie (imię → zdjęcie → dodaj znajomego → krąg).
14. **Jedna osoba**: projekt, klucz i zbiórka stoją na jednym człowieku.
15. **Kod QR na drzwiach publikuje stałe adresy domowników** (przegląd K1):
    `FlatDoorCode.encode()` wkłada do kodu do 3 adresów, zaczynając od
    własnego (`flat_model.dart:317-328`, `neighbors_service.dart:200-208`),
    a §18.2 obiecuje „klucz mieszkania, nie konta”. Adres to tożsamość i kod
    zaproszenia: kto przejdzie klatką, ma łańcuch dom → osoba → publiczny
    profil i posty → obecność online. Naprawa: kod niesie tylko klucz
    mieszkania i osobny adres skrzynki mieszkania (drugi węzeł albo relaye),
    adres osoby dopiero po „Pokaż mój profil”; do tego czasu uczciwy opis na
    ekranie naklejki albo sąsiedzi za flagą. P1, S/M.
16. **Zgubiony telefon** (przegląd K4): bez kręgu przepada konto i wszyscy
    znajomi; z kręgiem wracają znajomi i grupy, ale nie historia czatów
    i plików (`own`), portfel (A7) ani profil randkowy. Krąg jest schowany
    w ustawieniach, bez przypomnienia. Naprawa: krąg jako krok powitania
    i przypomnienie po trzecim znajomym, ekran „Co odzyskasz, jeśli zgubisz
    telefon” (S); eksport zaszyfrowanej kopii do pliku (S); kopia `own`
    u kręgu z limitem (M). P1, S/M.

Propozycje: ekonomia kontaktów bez pieniędzy; kopia klucza konta na papierze
+ klucz piramidy z konta; wzajemna weryfikacja oficjalnej wersji (§14.3);
obecność zdarzeniowa i tryb oszczędny; zaproszenie przez wydarzenie;
randki na żądanie, 2 kroki. Z przeglądu architektury (bez serwerów):
„Wszyscy cali?” jednym dotknięciem po burzy czy awarii (alarm, potwierdzenia
i fale już są; P2, S); jeden QR zapraszający całą grupę naraz — znajomy
organizatora i od razu w czacie grupy (P1, S/M); synchronizacja skrzynek
przy spotkaniu dwóch telefonów (P2, M); tryb prosty dla seniora i dziecka
(P2, S/M); kod bezpieczeństwa rozmowy do porównania na żywo (P2, S);
kanał ogłoszeń rodziny lub kamienicy (P3, S). UX: stan wiadomości mówi
prawdę (A18), jeden ekran „Dlaczego nie działa?” (internet, sieć Zen, usługa
w tle, zegar, wersja), dostępność (w całej aplikacji 5× `Semantics`,
427 dosłownych `fontSize`; skala typografii, etykiety alarmu i grafu, test
czytnika i powiększenia 200%), komputer jako komputer (A24).

## 7. Migracje i kod zgodności

Kod zgodności usunięty przed pierwszym wydaniem (1.10.0). Zostaje
świadomie: jednorazowe przepieczętowanie konfiguracji węzła ZENENC1 →
ZENENC2 (`runtime_native_signal_transport.dart`, `isUnboundSeal` /
`unsealUnbound`) — bez niego zmieniłby się adres istniejącej instalacji;
usunąć, gdy żadna instalacja nie ma już starej koperty.

Do zrobienia przy „wszystko od wersji 1” (S, zmiana formatów naraz):
- wyzerować numery: koperta `BinaryCodec` v2, łączenie urządzeń v2
  (`zen.link.v2`), paczki randkowe v2, zaproszenie mieszkania v2, fala
  alarmu v5, wiadomości v7, migawka v8, kolejka sygnałów v3, transfery v3;
- enumy po nazwie (migawka, wiadomości, kolejka i transfery zapisują
  indeksy);
- zarezerwowany bajt w indeksie wątku (dawny znacznik starego pliku);
- zdjęcia profilu randkowego jedną listą zamiast `ph` + `phx`; odbiorcy
  listy znajomych jednym polem zamiast flag `noList` / `listAsk`;
- możliwości (caps) i wersja w powitaniu oraz ping/pong (A17); to ostatnia
  zmiana formatu, którą da się zrobić bez bólu;
- nieznana wersja = tylko odczyt: dziś tylko stan „Spotkań”; migawka
  nieczytelna dla tej wersji jest odkładana obok (`.unreadable`), zanim
  cokolwiek ją nadpisze (ale patrz B11).

## 8. Wersje i proces

- **Jedna numeracja:** `1.10.0+10` w `pubspec.yaml` i `app_version.dart`
  (test pilnuje zgodności), sekcja CHANGELOG `1.10.0`, tag `v1.10.0`. Numer
  kompilacji musi rosnąć.
- **GitHub Actions:** `ci.yml` (formatowanie, analiza, testy aplikacji
  — w tym `test/i18n_test.dart`: tłumaczenia zgodne z tekstami kodu — i mostu
  przy każdym pushu i pull requeście, na Windows; budowanie i krótki start
  na Linuksie przy każdym pushu i PR, na macOS przy pushu na `main`
  i ręcznie), `release.yml` (tag `v*`: `Zen.apk` podpisany kluczem
  z sekretów, `Zen-Windows.zip`, `Zen-Linux-x64.tar.gz`,
  `Zen-Linux-arm64.tar.gz`, `Zen-macOS.zip`, `Zen-unsigned.ipa` z `ios.yml`
  wołanego jako workflow wielokrotnego użytku, `LICENSES-GO.txt`,
  `SHA256SUMS` ze wszystkich plików, w wersji roboczej wydania), `ios.yml`
  (ręcznie albo z `release.yml`), `pages.yml` (strona zaproszeń).
  Zabezpieczenie CI: S24, D11.
- **Linux i macOS nie zostały jeszcze zbudowane naprawdę** — największe
  ryzyka do pierwszego przebiegu: Swift (`SecurityBridge.swift`), linkowanie
  mostu Go na macOS, start pod Xvfb, Linux ARM64, nieaktualny
  `pubspec.lock` (`flutter pub get` i zatwierdzić).
- Pakiet Darta nazywa się `zen`; kod sformatowany `dart format`.
- Dalej: mniejsze wydania zamiast wielu etapów naraz; zamknięta beta
  20–50 osób z jednego środowiska ze znacznikiem wydania jako kanałem (A17).

### Licencje zależności

Sprawdzone 14.10.2026 (`pubspec.lock`, `native/yggdrasil_bridge/go.mod`):
pakiety Darta/Fluttera są na licencjach MIT, BSD i Apache 2.0, kilka
linuksowych (`dbus`, `geoclue`, `gsettings`, `gtk`) na MPL-2.0. W moście Go:
**Yggdrasil v0.5.14 — LGPL-3 z wyjątkiem pozwalającym rozpowszechniać
programy z nim połączone** (statycznie lub dynamicznie), `ironwood` i
`phony` — MPL-2.0, reszta MIT/BSD/ISC. Wszystkie pozwalają na użycie,
także odpłatne czy ze zbiórką; MPL i LGPL wymagają tylko, by ich własne
pliki (bez naszych zmian) pozostały dostępne — są publiczne u źródła.
Licencje modułów Go (`assets/licenses/go/`, `dart run
tool/go_licenses.dart`) i fontów (SIL OFL, `assets/licenses/fonts/`) są
w ekranie „Licencje”; `LICENSES-GO.txt` jest w wydaniach, obok `zen.exe`
i obok `zen` w archiwach Linuksa. Yggdrasil 0.5.14 to najnowsze wydanie
stabilne na dziś.

## 9. Dystrybucja

Badanie kanałów, sklepów i prawa: 14–15.10.2026 (to nie porada prawna ani
podatkowa). Plan krok po kroku: `WYDANIA.md` §6.

**Fakty na dziś:**
- **Weryfikacja twórców Androida:** od 30.09.2026 działa tylko przy
  instalacji ze sklepów uczestniczących (Google Play, Galaxy Store, HONOR,
  OPPO, Xiaomi GetApps, vivo, Palm Store) w Brazylii, Indonezji, Singapurze
  i Tajlandii; instalacja z pliku, także tam, na razie bez zmian. W Polsce
  i UE nic się nie zmieniło. Globalnie „w 2027”, bez miesiąca. Potem pakiet
  bez rejestracji zainstaluje się tylko „zaawansowaną ścieżką” (Opcje
  programisty, restart, 24 h, ostrzeżenie przy każdej instalacji) albo przez
  ADB — dotyczy też aktualizacji i „Podaj dalej”. Rejestracja: konto za
  25 USD (Play Console albo Android Developer Console), dowód osobisty
  i dokument z adresem, pakiet + odcisk klucza. Utrata klucza = brak
  rejestracji pakietu. Instalacja offline może wymagać chwili internetu
  (niepewne). Bez weryfikacji zostają telefony bez Google (GrapheneOS,
  LineageOS bez GMS, Huawei).
- **F-Droid i IzzyOnDroid odpadają**: oba wymagają licencji zatwierdzonej
  przez OSI albo FSF, a licencja Zen zakazuje forków i sprzedaży. Działają:
  GitHub Releases, Obtainium (bez recenzji i wymogów licencyjnych), własne
  repozytorium F-Droid na GitHub Pages.
- **Google Play**: konto osobiste 25 USD; nowe konto osobiste wymaga testu
  zamkniętego z co najmniej 12 testerami przez 14 dni; publicznie widać imię,
  nazwisko i kraj. Wersja do sklepu musi być osobnym wariantem (bez
  samoaktualizacji, bez `REQUEST_INSTALL_PACKAGES`, bez linku do zbiórki,
  z deklaracjami usługi w tle i alarmu na pełnym ekranie, 18+ albo bez
  randek, inne nazwy dla „piramidy” i „waluty”, regulamin i zgłoszenia UGC,
  strona o bezpieczeństwie dzieci, targetSdk 36, Data safety z klipy.com).
  Ten sam pakiet i klucz (wgrany do Play App Signing) pozwala przechodzić
  między kanałami jak w Signalu. Galaxy Store — bez opłat, ten sam wariant.
  Amazon Appstore na Androidzie zamknięty (20.08.2025).
- **iOS:** jedyną drogą bez konta jest SideStore / AltStore z darmowym
  Apple ID (7 dni, 3 aplikacje). Konto indywidualne 99 USD/rok daje
  TestFlight (do 10 000 testerów, build ważny 90 dni), App Store, **AltStore
  PAL** (UE, Japonia, Brazylia; notaryzacja zamiast pełnej recenzji, od
  01.10.2026 bez opłaty od instalacji dla darmowej aplikacji) i podpis
  Developer ID z notaryzacją dla macOS. Web Distribution w UE tylko dla
  organizacji (np. fundacji z fee waiver). Bez serwera push iOS nie dostarczy
  wiadomości w tle.
- **Podmiot:** na start wystarczy osoba prywatna. JDG i spółka nic nie dają
  przy darmowej aplikacji (sp. z o.o. ~40 tys. zł/rok). Fundacja (KRS
  bezpłatny, ~5–15 tys. zł/rok, głównie księgowość) daje konto organizacji,
  adres siedziby zamiast domowego, możliwy Apple fee waiver (niepewne dla
  Polski) i Web Distribution w UE, granty — wymaga przeniesienia praw do
  kodu. Darowizny przez buycoffee.to: wpłaty anonimowe nie są darowiznami
  w rozumieniu interpretacji z 09.2025 — do doradcy podatkowego.

**Rekomendacja i koszty:** zostać przy APK z GitHuba + Obtainium i do końca
2026 zarejestrować `com.roj.zen` z kluczem wydań (25 USD jednorazowo);
równolegle wariant sklepowy i test 12 × 14 dni (3–6 tygodni). iOS: konto
99 USD/rok → TestFlight + AltStore PAL, potem App Store; tym samym kontem
podpisywać i notaryzować macOS. Fundacja dopiero, gdy projekt urośnie.

Źródła: [weryfikacja twórców — przewodnik](https://developer.android.com/developer-verification/guides),
[FAQ](https://developer.android.com/developer-verification/guides/faq),
[Android Authority 01.10.2026](https://www.androidauthority.com/android-sideloading-developer-verification-first-wave-rollout-3717921/),
[F-Droid Inclusion Policy](https://f-droid.org/docs/Inclusion_Policy/),
[IzzyOnDroid](https://izzyondroid.org/docs/general/AppInclusionPolicy/),
[Play: test 12 testerów](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en),
[Play: Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379?hl=en),
[Apple: aplikacje w UE](https://developer.apple.com/support/apps-in-the-eu/),
[AltStore PAL dla twórców](https://faq.altstore.io/developers/distribute-with-altstore-pal),
[Apple fee waiver](https://developer.apple.com/help/account/membership/fee-waivers).

| # | Problem | Co zrobić | P, rozmiar |
|---|---|---|---|
| D1 | **Weryfikacja twórców Androida w 2027** (dziś tylko sklepy w 4 krajach) | do końca 2026 konto 25 USD i rejestracja `com.roj.zen` z kluczem wydań (`WYDANIA.md` §4); sprawdzić instalację offline przez „Podaj dalej” | P1, S (organizacyjnie) |
| D2 | **Klucz podpisu**: jeden klucz jednej osoby, bez kopii; odcisk nieopublikowany | kopia Shamira u 3–5 osób (nigdy publicznie), rotacja v3, odcisk w README i opisach wydań | P1, S |
| D3 | Nowy pakiet `com.roj.zen` | ostrzec w opisie wydania: stara aplikacja zostaje z danymi; przenieść konto podłączeniem urządzenia | P1, S |
| D4 | Integralność częściowa: „Podaj dalej” i ADB sprawdzają certyfikat APK, ale odcisk oficjalnego klucza nie jest jeszcze wpisany, a kopia może podmienić zbiórkę | odcisk w `apk_signature.dart`, podpisany manifest (§14.3) | P1, S |
| D5 | Windows bez Authenticode — SmartScreen straszy | SignPath (darmowy dla projektów otwartych — sprawdzić przy licencji Zen) albo Azure Trusted Signing; później MSIX i winget | P2, S/M |
| D6 | Link do zbiórki (`buycoffee.to/zen`) nie jest jeszcze w podpisanym manifeście — kopia może go podmienić; w sklepach link do zewnętrznej płatności zakazany (poza USA w App Store) | podpisany manifest (§14.3); w wariantach sklepowych bez linku | P2, S |
| D7 | Brak instrukcji instalacji z obrazkami | Android (z zaawansowaną ścieżką 2027), Windows SmartScreen, macOS „Otwórz mimo to” | P2, S |
| D8 | Aktualizacje przez sieć wyłączone (pusta lista opiekunów) | ten sam certyfikat + wyższy `versionCode` + 7 dni + zgoda człowieka (§14.2) | P3, S/M |
| D9 | Licencja zakazuje forków: F-Droid **i IzzyOnDroid** niemożliwe, ciągłość zależy od autora | Obtainium (przycisk w README), ewentualnie własne repozytorium F-Droid; decyzja o licencji (wolna licencja otwiera oba) | P3, S |
| D10 | iPhone tylko przez SideStore/AltStore (7 dni, bez pracy w tle); Linux i macOS bez podpisu (macOS od wersji 15: tylko „Otwórz mimo to” albo `xattr`) | konto Apple 99 USD/rok: TestFlight, AltStore PAL, App Store, Developer ID + notaryzacja macOS w CI; Linux: `.deb` i Flatpak | P2, M |
| D11 | **Klucz APK w sekretach GitHub Actions** (przegląd K8): przejęcie konta, tokenu albo akcji wystarcza do podpisanej „oficjalnej” aktualizacji, która rozejdzie się też przez sieć (§14.2) | CI buduje niepodpisany, powtarzalny APK i publikuje sumę; autor podpisuje offline, CI sprawdza, że różnica to tylko blok podpisu; do tego czasu S24 (SHA akcji, `environment` z zatwierdzeniem, klucz tylko dla tagów); docelowo podpis z progiem i poręczenia powtarzalnych kompilacji | P1, S/M |
| D12 | Wariant sklepowy (Play, Galaxy Store) | flavor bez samoaktualizacji i instalacji APK, „Podaj dalej” jako link; deklaracje FGS (`connectedDevice`, wideo), alarmu na pełnym ekranie i położenia; 18+ albo bez randek; „Samorząd”/„punkty” zamiast „piramidy”/„waluty”; bez linku do zbiórki; regulamin, zgłoszenia do autora, strona CSAE; Data safety (klipy.com); test 12 × 14 dni; bez Chin, Rosji, Białorusi i krajów pod sankcjami | P2, M |
| D13 | Podmiot prawny i podatki | na start osoba prywatna; fundacja, gdy projekt urośnie (konto organizacji, fee waiver, Web Distribution w UE); kwalifikacja darowizn — doradca podatkowy | P3, — |

## 10. Niezrobione z planu

Uzgodnione z przeglądem zgodności kodu z planem (14.10.2026). Zrobione
i usunięte z listy: media „tylko po kliknięciu” (`autoDownloadMedia`),
tłumaczenia i wybór języka (§25.1), CI (§2.5), budowanie Linuksa i macOS.

| Co | § | Rozmiar |
|---|---|---|
| Flagi funkcji (wydanie „rdzeń”) | 2.5 | S |
| Formaty od wersji 1, enumy po nazwie, możliwości w powitaniu | 2.5, `STAN` §7 | S |
| GIF-y z klipy.com: zewnętrzny serwer z wbudowanym kluczem, poza wyjątkami §1.1 (S29, S37) | 1.1, 13 | S |
| Przestrzenie `hood`, `date`, `cell`, `treasury`, `event` w silniku; nieznane przestrzenie odrzucane zamiast przechowywane (A17) | 1.6, 4 | L |
| Sieć lokalna (multicast) wyłączona wszędzie: telefony nigdy, komputery wymagają hasła, którego aplikacja nie ustawia | 5.1 | S/M |
| Limit połączeń i transferu na most; znacznik budowania mostu bez wersji Go | 5.1, 5.2 | S |
| Tożsamość na kluczu konta | 6.1 | L |
| Klucz piramidy z klucza konta | 6.1 | S/M |
| Kopia klucza konta na papierze; krąg proponowany przy powitaniu | 6.1, 6.3 | S |
| Ogólne poświadczenia: „spotkani osobiście” to lokalny, niepodpisany znacznik — nie przy dodaniu przez QR, nie wymieniany ze znajomymi (podstawa „zweryfikowanych” i §20.6) | 6.2 | M |
| Dobrowolne połączenie tożsamości (podpis obu kluczy) | 6.4 | S/M |
| Ruch piramidy przez relaye | 6.4 | M |
| Krąg i strażnicy wybierani bez preferencji „Przyjaciel” | 7 | S |
| Media „tylko Wi-Fi” (docelowo domyślnie), limity przechowywania | 7 | S |
| Uprawnienia poziomów: słaby znajomy dostaje listę znajomych i statusy, zaproszenia do grup bez progu, brak propozycji poziomu przy spotkaniu | 8, 16.2 | S |
| Lista znajomych domyślnie do wszystkich; profil w dzienniku publiczny z adresem | 1.8, 9 | S |
| Widoczność pól profilu, narodowość | 9 | M |
| Mini-profil; przyciski „Dodaj” i „Wiadomość”; liczby znajomych i obserwujących; zakładki (plan: 5, kod: Posty · Galeria · Podziękowania) | 9 | M |
| Filmy bez metadanych i GPS; oglądanie w trakcie pobierania; nagrobek nie dociera do znajomych udostępniającego | 10 | S; M |
| Podpisana migawka liczników i stronicowanie (dziś paczki do 200 lajków / 30 komentarzy); „Lubią to: …” najpierw znajomi; ukrywanie komentarzy i blokowanie w wątkach przez autora; powiadomienia zbiorcze | 11 | M |
| „N zweryfikowanych” przy polubieniach | 11 | S/M |
| Lista i liczba obserwujących (obserwowanie nie jest wpisem w `acts`); blokada obserwujących | 4, 12 | M |
| Tablica grupy | 13 | M |
| Wiadomości do obcych (poza listem przez wspólnego znajomego) | 13, 24.1 | M |
| Udostępnianie ekranu: ukrycie powiadomień i przypomnienie „widać wszystko”, uprzedzenie na Androidzie < 14; ekran zastępuje kamerę zamiast drugiej ścieżki | 13.1 | S |
| Dźwięk przy rozpoczęciu nagrywania | 13.2 | S |
| Własny awatar i tło profilu zapisane jawnie; kilka kopiowań do schowka bez wygasania | 14.1 | S |
| Ponowne potwierdzenie i blokada zrzutów dla randek | 14.1 | S |
| Instrukcje instalacji z obrazkami; rejestracja zweryfikowanego twórcy; Authenticode (D1, D5, D7) | 14.2 | S |
| Tor, Wi-Fi Direct, siatka Bluetooth | 14.2, 28 | L |
| Kamuflaż, kanarek, lustra | 14.2 | S–M |
| Zatwierdzanie wersji do aktualizacji przez sieć | 14.2 | S/M |
| Integralność wydań i zbiórki | 14.3 | S–M |
| „W pobliżu”: osobny sekret na znajomego, rotacja z MAC, przywitanie bez stałego adresu (S5, S6) | 15 | M |
| „W pobliżu”: odznaki przy obcych; blokady tylko w pamięci (giną po restarcie); limit „1 wiadomość od nieznajomego” pilnowany tylko u nadawcy | 15 | S |
| Bluetooth na Windows, iPhonie, Linuksie i macOS; zakładanie komórek piramidy przez Bluetooth | 15, 20 | M |
| Graf: przybliżanie i klastry; dotknięcie osoby nie otwiera profilu | 16.1 | S/M |
| Alarm: położenie w tle, zapasowy SMS | 16.3 | M |
| „Przyprowadzający ręczy”, wspólna kasa kółka; kółko 4–8 osób niewymuszone, brak par | 17.2–17.3 | S |
| Odpowiedzi „Zapytaj sieć” niepodpisane | 17.5 | S |
| „Wspólna sprawa” | 17.6 | S/M |
| Sąsiedzi: strona `/m`, czat zaproszenia; kod na drzwiach bez adresów domowników (§6 pkt 15) | 18 | S/M |
| Randki: położenie „na żądanie” przy „Idę na randkę”; zgłoszenie osoby niepełnoletniej nie wyłącza profilu samo (bez piramidy wcale) | 19.4, 19.6 | S |
| Randki: latarnie na żądanie | 19.7 | L |
| Piramida: przyjęcie bez sprawdzenia poziomu „co najmniej Znajomy”; odznaka wieku i płci, anonimowe statystyki; referenda tylko z członków „spotkanych osobiście” przez ≥ 2 osoby | 20.2, 20.2a, 20.6 | S–M |
| Przerwa tylko 7 dni (brak 24 h i 30 dni) | 21.1 | S |
| Zgłoszenia: dowód jako podpisane wpisy (S36), eskalacja poziom po poziomie (dziś po 48 h od razu do szczytu), zgłoszenie komentarza bez autora; „Ukryj u siebie” i „Odwołaj się” (B13, naprawione w 1.10.0, runda 2) | 21.4 | S |
| Sygnały farm kont, poręczenia z karami, cofanie przelewów udowodnionych jako oszustwo | 21.5 | M |
| Liczniki „Dotarło / przeczytało”; przypinanie w sekcji krajowej | 22.1a, 22.2 | M; S |
| Emisja ponad limit przez referendum (dziś tylko zmianą konstytucji) | 23.4 | S |
| Prywatność przelewów | 23.4 | L |
| Cennik w profilu (jest w Portfelu); płatne przedstawienie rozliczane po akceptacji pośrednika zamiast adresata | 24 | S |
| Ekonomia kontaktów: ceny poza piramidą (jeśli w ogóle) | 24.1 | M |
| Grupowanie zakładek | 25 | S |
| Ekran uprawnień: położenie (zwykłe i w tle), dokładne alarmy, instrukcja dla producentów (dziś tylko w Ustawieniach) | 25.2 | S |
| Etykiety dla czytnika ekranu (alarm, graf) | 25.3 | S |
| „Usuń z urządzenia” z blokadą skrótu; kasowanie starych przelewów; przycisk z instrukcją dla organów ścigania, lista skrótów od organizacji | 26.1 | S–M |
| Bramka wieku | 26.1, 27 | S |
| Linux i macOS: pierwszy zielony CI, Bluetooth, nagrywanie rozmów, aparat i skaner QR; Linux: odtwarzanie audio i wideo, linki `zen://`, `.deb` / Flatpak; macOS: Developer ID i notaryzacja; iPhone bez ograniczeń (płatne konto) | 26.3 | M / L |
| Polityka prywatności, regulamin, DPIA | 27 | S |
| Specyfikacja protokołu, mapa zaufania; „Twoja gałąź urosła”, zaproszenie przez wydarzenie | 28 | M, S |

## 11. Kolejność prac

### Teraz (P1, przed szerszym udostępnieniem)

| Co | Rozmiar |
|---|---|
| Odzyskiwanie konta związane z kontem (S19); limity pamięci mostu Go (S20) — naprawione w 1.10.0 (runda 2) | S |
| Uszkodzone dane nie usuwają znajomych: tryb tylko do odczytu, koniec odruchowego `friend_remove` (B11, A14) | S |
| Kod na drzwiach bez adresów domowników (§6 pkt 15) — albo sąsiedzi za flagą | S/M |
| GIF-y: strona trzecia jawnie opisana, pobieranie po dotknięciu, bez mylącego komentarza; docelowo GIF jako załącznik przez `media_guard` (S29, S37) | S |
| Wymiana wersji: `ver`/`caps` w ping/pong, podpisany znacznik wydania z belką, złote próbki protokołu (A17) | S |
| Zaufanie do wydań: akcje przypięte SHA, klucz tylko dla tagów, `environment` z zatwierdzeniem (S24), docelowo podpis poza CI (D11); `SECURITY.md` | S/M |
| Pozostałe średnie z drugiego audytu: dowód adresu urządzeń (S21), ostrzeżenia o plikach (S22), skrzynki tylko dla znajomych (S23) | S |
| Uczciwy stan dostarczenia wiadomości i `failed` po wygaśnięciu (B12, A18) | S |
| „Zgłoś”: ukryj u siebie, odwołanie, prawdziwe teksty (B13) | S |
| Tłumaczenia: zdarzenia zamiast zapisanych napisów, `context:` dla dwuznacznych tekstów (A23) | S |
| Krąg odzyskiwania i kopia jako część powitania (§6 pkt 16) | S/M |
| Flagi funkcji: wydanie „rdzeń” (piramida i waluta za flagą); krok 0: `ZenCore` (A15) | S + M |
| Domyślna prywatność: lista znajomych i statusy nie dla słabych znajomych; bramka wieku | S |
| Klucz piramidy z klucza konta | S/M |
| Klucz podpisu z kopią Shamira; odcisk w README, w wydaniach i w `apk_signature.dart`; rejestracja `com.roj.zen` jako zweryfikowany twórca Androida do końca 2026 (D1) | S |
| Integralność §14.3 (podpisany manifest, w tym zbiórki) | S/M |
| Polityka prywatności (z klipy.com i publicznymi węzłami), regulamin | S |
| Formaty od wersji 1 (§7) | S |
| Pierwszy zielony przebieg CI dla Linuksa i macOS | S |

### Wkrótce (P2)

| Co | Rozmiar |
|---|---|
| Drugi audyt, niskie: iOS (S25), blokada w tle i po bezczynności (S26), ochrona ekranu i miniatury (S27), SDP (S28), tytuły powiadomień (S30), zagłuszanie fali (S31) | S |
| Bluetooth: osobne sekrety na znajomego, rotacja z MAC (S5, S6) | M |
| Bateria: bez stałych blokad, obecność zdarzeniowa, media tylko Wi-Fi (A9); `NativePort` zamiast odpytywania mostu (A19) | M |
| Kryptografia poza wątkiem UI (`cryptography_flutter`), fold piramidy przyrostowo, tablica przyrostowo i listy leniwe (A5, A19) | M |
| Trwałość: ukryte nazwy `meet/list/` i `ledger/`, `%LOCALAPPDATA%`, ostrzeżenie przed limitem 20 MB (A20) | S |
| Belka zegara (A21); raport zdrowia i ekran „Dlaczego nie działa?” (A22) | S |
| Cykle zależności: porty w `domain/`, reguły importów (A16) | M |
| Załączniki przez skrzynki — jedna warstwa blobów (A18) | M |
| Testy: fuzzing Go, uszkodzone dane, rozmowy grupowe, `flutter test` na Linuksie (A13) | S |
| Kworum piramidy od aktywnych, suma z limitem czasu (§6 pkt 11) | S/M |
| Graf: przybliżanie i klastry | S/M |
| Randki: latarnie na żądanie, 2 kroki (§19.7) | L |
| Alarm: położenie (także w tle) na ekranie uprawnień, zapasowy SMS | M |
| Instrukcje instalacji z obrazkami; Authenticode na Windows (D5, D7) | S; S/M |
| Konto Apple: TestFlight + AltStore PAL, Developer ID i notaryzacja macOS (D10) | M |
| Wariant sklepowy Androida: Google Play i Galaxy Store (D12) | M |
| Linux: odtwarzanie audio i wideo, `.deb` i Flatpak z plikiem `.desktop` | M |
| Ponowne potwierdzenie i blokada zrzutów dla randek | S |
| Dostępność: etykiety dla czytnika ekranu, skala typografii | S/M |
| Grupowanie zakładek, proste powitanie | S |

### Później (P3)

| Co | Rozmiar |
|---|---|
| Drugi audyt, pozostałe: S32–S38 | S |
| Jeden właściciel danych (usługa), UI jako klient; szyfrowany SQLite | L |
| Tożsamość na kluczu konta; przestrzenie `hood`/`date`/`cell`/`treasury`/`event` | L |
| Ruch piramidy przez relaye, bez adresu urządzenia | M/L |
| Linux i macOS: Bluetooth, nagrywanie rozmów; komputer z dwoma panelami (A24) | M |
| iPhone: praca w tle, Bluetooth, push (wymaga płatnego konta i serwera push, §26.3) | L |
| Aktualizacje przez sieć wg §14.2 | S/M |
| Wzajemna weryfikacja oficjalnej wersji (key attestation) | M |
| Tor, Wi-Fi Direct, siatka Bluetooth; kamuflaż, kanarek, lustra | L; S–M |
| Specyfikacja protokołu; mapa zaufania | M; S |
| Prywatność przelewów | L |
| Podział kodu na pakiety (A12) | L |
| Decyzje organizacyjne: licencja na wypadek zniknięcia autora (wolna licencja otworzyłaby F-Droid), fundacja (konto organizacji, fee waiver, Web Distribution w UE), zmiana nazwy „Piramida” | — |
