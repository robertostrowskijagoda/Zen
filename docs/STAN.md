# Stan projektu

Stan na 14.10.2026. Co działa, znane błędy, otwarte problemy (bezpieczeństwo,
architektura, koncepcja, dystrybucja) i kolejność prac. Plan i opis
rozwiązań: `PROJEKT_APLIKACJI.md` (odnośniki §N.M). Wydania: `WYDANIA.md`.
Zastępuje dawne `KIERUNKI.md` i `AUDYT_BEZPIECZENSTWA.md`.

Priorytet: **P1** — przed szerszym udostępnieniem, **P2** — wkrótce,
**P3** — później. Rozmiar: **S** (dni), **M** (tygodnie), **L** (miesiąc
i więcej).

Odwołania `plik:linia` pochodzą z przeglądu sprzed sformatowania całego
kodu (`dart format`), więc numery linii mogą być przesunięte o kilka.

---

## 1. Co działa dziś

- **Platformy:** Android (pakiet `com.roj.zen`), Windows i iPhone
  (SideStore / AltStore z darmowym Apple ID, bez pracy w tle; plik
  `Zen-unsigned.ipa` buduje GitHub Actions). macOS i Linux — w planie
  (§26.3).
- **Komunikator:** czaty, grupy, połączenia audio i wideo (także grupowe),
  skrzynki offline u znajomych, znikające wiadomości, udostępnianie ekranu,
  jawne nagrywanie, rozmowa w okienku.
- **Konto:** hasło, krąg odzyskiwania (do 6 osób: hasło + 2 po 24 h albo
  4 bez hasła po 7 dniach), wiele urządzeń jednego konta, historia rozmów na
  nowym urządzeniu.
- **Profil i tablica:** profil z galerią i kartami wdzięczności, posty
  z widocznością, udostępnianie, lajki, komentarze, obserwowanie,
  „Zgłoś”.
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
- **Ochrona danych:** szyfrowanie wszystkiego kluczem głównym (także
  załączników, głosówek i zdjęć znajomych), klucz w Keystore/TPM, blokada
  po 5 min w tle, blokada zrzutów, hasło paniki, ostrzeżenie o roocie.
- **Pierwsze uruchomienie:** hasło, potem ekran uprawnień i Bluetooth
  (§25.2), ten sam w Ustawieniach.

Zmiany ostatniej rundy: `CHANGELOG.md`, 1.10.0.

## 2. Podjęte decyzje

| Decyzja | Skutek / ryzyko |
|---|---|
| **Most na komputerze domyślnie włączony, bez komunikatu**; wyłącznik „Pomagaj innym się łączyć” na dole ustawień (Zaawansowane → Sieć i usługa) | Świadome ryzyko: UPnP i port 443 bez pytania, IP komputera widoczne w ogłoszeniach, nasłuch `tls://[::]:32913` kluczem węzła zdradza, czyj to komputer (§5.1, §26.1) |
| **Nie ma strony WWW**; stroną jest README repozytorium, a jedynym plikiem na GitHub Pages jest strona zaproszeń (`tool/pages/index.html`, publikowana przez `.github/workflows/pages.yml`) | Kody QR prowadzą do `robertostrowskijagoda.github.io/Zen/#KOD`: strona otwiera Zen (Android `intent://` z powrotem na stronę, gdy Zen brak; inne `zen://c/KOD`) albo pokazuje pobieranie; README ma przycisk „Otwórz w aplikacji” prowadzący na tę stronę (GitHub wycina linki `zen://` i `intent://` z README). Pages w darmowym planie wymaga publicznego repozytorium. Zen obsługuje oba linki bez weryfikacji domeny („Otwieraj obsługiwane linki”) |
| **Nazwa znajomego z jego profilu, nieedytowalna; lokalny pseudonim pod nią** | dwie osoby mogą mieć tę samą nazwę — odróżnia je pseudonim i zdjęcie |
| Kod zaproszenia bez mostów (8.10.2026) | nowa osoba startuje z publicznych węzłów |
| Pakiet Androida `com.roj.zen` (był `com.HuraganKodu.zen`) | to nowa aplikacja: stara instalacja zostaje obok z danymi; konto przenosi się podłączeniem urządzenia (§6.5), potem starą można odinstalować |
| Licencja (14.10.2026): PolyForm Strict 1.0.0 z dodatkowymi zezwoleniami — tylko użycie niekomercyjne; wolno czytać kod, wysyłać pull requesty, budować dla siebie i przekazywać niezmienione wydania (ta sama suma SHA-256); autor i zbiórka muszą zostać; forki i zmienione wersje zakazane | ciągłość projektu zależy od autora (§6 pkt 4); firmy nie mogą używać Zen bez zgody autora |
| Biometria domyślnie wyłączona; blokada domyślnie po 5 min w tle | — |
| Asystent AI usunięty (V1.9) | — |
| Piramida bez partii (14.10.2026) | polityka to głosowania i delegowanie, bez list wyborczych |
| Ekonomia kontaktów bez piramidy: walutą jest zgoda (lista znajomych na prośbę, przedstawienia, list przez wspólnego znajomego); ceny tylko na rynku piramidy | brak waluty poza piramidą — mniej ryzyka prawnego (§24.1, §27) |
| Widoczność w pobliżu (rozgłaszanie BLE) włączana na ekranie uprawnień; rozglądanie się w tle domyślnie wyłączone | znajomi rozpoznają telefon obok; skanowanie tylko na ekranie „W pobliżu” |
| Gotowych bibliotek mostu Go nie ma w repozytorium — buduje je każdy build ze źródeł | do budowania potrzebne Go, NDK i kompilator C (README) |
| Zbiórka: `buycoffee.to/zen` (14.10.2026) | — |

## 3. Znane błędy

| # | Błąd | Przyczyna / gdzie | Naprawa | P, rozmiar |
|---|---|---|---|---|
| B4 | Burza przy starcie (częściowo) | lista znajomych i klucze „W pobliżu” idą już raz, tylko po zmianie; paczki randkowe nadal naraz | rozłożyć paczki w czasie | P3, S |
| B6 | Wygrywa ostatni zapis | aplikacja i usługa w tle mają osobne kolejki zapisu tych samych plików (`meet_book.dart:708`) | jeden właściciel danych (A3) | P2, L |
| B7 | Alarm ze skrótu przy zamkniętej aplikacji bez nagrania i zwykle bez świeżego położenia | brak usługi typu `location` i zgody na położenie w tle | §16.3 | P2, M |
| B8 | Android 10–11: skanowanie w tle nic nie znajduje | system wymaga zgody na położenie w tle | ekran uprawnień (§25.2) | P3, S |

Naprawione w 1.10.0: znajomi znajomych (B1, B2: listy osobno, odkładanie
ramek, skróty w powitaniu), zapis stanu przy każdym pong (B3), graf
rysowany bez przerwy (B5), rada „odinstaluj” w ADB (B9), alarm zablokowany
przez duży stan „Spotkań” (B10).

Wydajność na słabszym telefonie (A32): największy koszt to kryptografia
i składanie piramidy (A5) oraz szyfrowanie mediów w czystym Darcie.
Mierzyć w `flutter run --profile`.

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

### 4.2 Naprawione w tej rundzie (1.10.0)

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

### 4.3 Naprawione wcześniej (audyt V1.10)

- `friend_accept` od obcego robił z niego znajomego — teraz nieproszona
  akceptacja to zwykłe zaproszenie; wzajemne zaproszenia w tej samej chwili
  dają znajomość od razu.
- Zablokowana aplikacja zrywała znajomości (sygnały na pustym stanie,
  także pingi) — sygnały czekają na odczyt danych po odblokowaniu, w tej
  samej kolejce.
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

### 4.4 Świadome ograniczenia

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
| A3 | **Dwa środowiska na tych samych plikach** (aplikacja i usługa w tle), część obsługi skopiowana, logika w warstwie UI | `android_background_runtime.dart:1393-1408` tworzy drugi komplet serwisów; `AlarmWatcher` (`alarm_screen.dart:1257`) działa równolegle z `_datingTimer` usługi (`:1471`); osobne kolejki zapisu (`meet_book.dart:708`) | jeden właściciel danych i usług (usługa), interfejs jako klient | P2, L |
| A4 | Osobne mechanizmy rozsyłania zamiast przestrzeni dziennika (skrzynki, piramida, randki, łańcuchy wydarzeń i pytań, sąsiedzi) | `space_policy.dart:35-53` | nowe funkcje na przestrzeniach dziennika; jeden mechanizm „stan znajomego” | P3, M–L |
| A5 | **Kryptografia w czystym Darcie w wątku UI**; piramida składana od zera co 60 s; każdy członek trzyma wszystkie rekordy | `ledger_identity.dart:50`, `ledger_store.dart:176`, `pyramid_record.dart:155,181`, `pyramid_service.dart:1576,1604`, fold `:457-471` | krypto w Go przez FFI albo osobny izolat; fold przyrostowy; podpisane punkty kontrolne; telefon trzyma swoją gałąź | P2, M |
| A6 | Piramida ujawnia adres urządzenia (łamie §6.4) | `pyramid_service.dart:3534-3537` → `pyramid_state.dart:1320-1325` | ruch przez relaye, bez adresu w stanie | P2, M/L |
| A7 | Klucz piramidy losowy na każdym urządzeniu: zgubiony telefon = utrata portfela; telefon i PC to dwie osoby | `pyramid_service.dart:820-829` | HKDF z klucza konta | P1, S/M |
| A8 | Brak wspólnego schematu i wersji: enumy po numerze, protokół bez wersji, dziesiątki gałęzi „starsza wersja” | `social_snapshot_store.dart:51,67,92,117,520`; `attachment_transfer_store.dart:522` | przed wydaniem wyzerować formaty, enumy po nazwie, możliwości (caps) w powitaniu (§7) | P1, S/M |
| A9 | Bateria: stała blokada uśpienia i Wi-Fi, ping co 45 s także w tle, brak trybu „tylko Wi-Fi” | `android_background_runtime.dart:589-590`, `:1800-1830` | obecność zdarzeniowa, tryb oszczędny, media tylko Wi-Fi | P2, M |
| A10 | Tożsamość = klucz węzła Yggdrasil (adres = kod zaproszenia, bez rotacji) | — | tożsamością klucz konta, węzły wymienne (§6.1) | P3, L |
| A11 | Cały ruch, także wideo, przez Yggdrasil, bez ścieżek bezpośrednich | — | bezpośrednie połączenia, gdy się da; most jako serwer rozmów grupowych | P3, M |
| A12 | Wielkie obiekty: kontroler czatów ~10 tys. linii w 11 częściach, ekran ustawień ~3,8 tys. linii, jeden pakiet | — | osobne kontrolery, pakiety (`zen_core`, `zen_transport`, `zen_pyramid`…) | P3, L |
| A13 | Proces: brak CI, dużo niezacommitowanych plików, wersje niespójne (§8); usługa w tle (~2,1 tys. linii) ma 5 testów, kod Kotlin (BLE, rozmowy) żadnego | — | CI, mniejsze wydania, testy usługi | P1, S |

Propozycje: wydanie „rdzeń” za flagami funkcji; jeden mechanizm „stan
znajomego”; most Go jako silnik kryptografii i bazy (FFI, SQLite); ekran
diagnostyki (połączenia, skrzynki, listy znajomych, kolejki).

## 6. Koncepcja

1. **Randki rosną jak trzecia potęga liczby znajomych**
   (`dating_service.dart:67,76,83,578-584`): paczka 8–52 KB od każdego co
   tydzień, do 3 kroków; przy ~150 znajomych dziesiątki tysięcy paczek
   tygodniowo. Naprawa: latarnie ~100 B na żądanie, 2 kroki (§19.7). P2, L.
2. **Ekonomia kontaktów oparta na walucie**: towarowość znajomości, ryzyko
   KNF/AML, nazwa „Piramida” kojarzy się z piramidą finansową. Najpierw
   wersja bez pieniędzy (§24.1); piramida i waluta za flagą. P1, S.
3. **„Prywatność domyślnie” niespełniona**: lista znajomych domyślnie
   włączona i idzie do wszystkich, także słabych znajomych
   (`meet_book.dart:481`, `meet_service.dart:992`), wbrew §8; profil
   w dzienniku publiczny z adresem (`ledger_profile.dart:57-70`); widoczność
   „W pobliżu” w tle domyślnie włączona; brak bramki wieku. P1, S.
4. **„Bez kluczy do wydań” to fikcja**: klucz APK to jeden klucz jednej
   osoby; licencja zabrania forków, więc po zniknięciu autora nikt legalnie
   nie kontynuuje; jawny klucz APK byłby groźny. Naprawa: rotacja v3,
   depozyt Shamira, decyzja o licencji (np. zgoda na kontynuację, gdy autor
   zniknie) i ewentualnie fundacja. P1, S/M.
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
   mostach i skarbnikach online. Uczciwiej: „sieć prowadzona przez
   użytkowników”.
9. **Niezawodność bez push**: wszystko zależy od usługi w tle, którą
   zabijają producenci (Xiaomi, Samsung) i tryb uśpienia. Alarm działa,
   gdy telefony przyjaciół mają węzeł — stąd potwierdzenia doręczenia
   (zrobione) i zapasowy SMS (do zrobienia).
10. **Moderacja**: przed piramidą jej nie ma; moderacja przez hierarchię
    polityczną to konflikt interesów.
11. **Piramida**: drzewo binarne to wąskie gardło wzrostu, szczyt jest
    okopany, te same ~15 osób ma emisję, skarb i bany, anonimowość głosu
    w trójce jest znikoma; sekcje narodowościowe to prawo wyborcze (partii
    już nie ma).
12. **RODO**: dane szczególne (art. 9), autor jako możliwy
    współadministrator, „prawo do usunięcia” a podpisane łańcuchy; brak
    polityki prywatności i regulaminu (§27).
13. **Rozrost funkcji**: 13 zakładek, hasło od pierwszego uruchomienia,
    25-znakowe kody, pojęcia krąg, mosty, poziomy, piramida — za dużo dla
    osoby nietechnicznej. Odpowiedź: rdzeń za flagami, grupowanie zakładek
    (§25), proste powitanie (imię → zdjęcie → dodaj znajomego).
14. **Jedna osoba**: projekt, klucz i zbiórka stoją na jednym człowieku.

Propozycje: ekonomia kontaktów bez pieniędzy; kopia klucza konta na papierze
+ klucz piramidy z konta; wzajemna weryfikacja oficjalnej wersji (§14.3);
obecność zdarzeniowa i tryb oszczędny; zaproszenie przez wydarzenie;
randki na żądanie, 2 kroki.

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
- możliwości (caps) w powitaniu;
- nieznana wersja = tylko odczyt: dziś tylko stan „Spotkań”; migawka
  nieczytelna dla tej wersji jest odkładana obok (`.unreadable`), zanim
  cokolwiek ją nadpisze.

## 8. Wersje i proces

- **Jedna numeracja:** `1.10.0+10` w `pubspec.yaml` i `app_version.dart`
  (test pilnuje zgodności), sekcja CHANGELOG `1.10.0`, tag `v1.10.0`. Numer
  kompilacji musi rosnąć.
- **GitHub Actions:** `ci.yml` (formatowanie, analiza, testy aplikacji
  i mostu przy każdym pushu i pull requeście), `release.yml` (tag `v*`:
  `Zen.apk` podpisany kluczem z sekretów, `Zen-Windows.zip`,
  `LICENSES-GO.txt`, `SHA256SUMS` w wersji roboczej wydania), `ios.yml`
  (`Zen-unsigned.ipa`), `pages.yml` (strona zaproszeń).
- Pakiet Darta nazywa się `zen`; kod sformatowany `dart format`.
- Dalej: mniejsze wydania zamiast wielu etapów naraz.

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
w ekranie „Licencje”; `LICENSES-GO.txt` jest w wydaniach i obok `zen.exe`.
Yggdrasil 0.5.14 to najnowsze wydanie stabilne na dziś.

## 9. Dystrybucja

| # | Problem | Co zrobić | P, rozmiar |
|---|---|---|---|
| D1 | **Weryfikacja twórców Androida od 2027** (od 30.09.2026 w Brazylii, Indonezji, Singapurze, Tajlandii) | zarejestrować się jako zweryfikowany twórca, z pakietem `com.roj.zen` i kluczem podpisu (`WYDANIA.md`); inaczej użytkownicy potrzebują zaawansowanej ścieżki z 24 h czekania albo ADB | P1, S (organizacyjnie) |
| D2 | **Klucz podpisu**: jeden klucz jednej osoby, bez kopii; odcisk nieopublikowany | kopia Shamira u 3–5 osób (nigdy publicznie), rotacja v3, odcisk w README i opisach wydań | P1, S |
| D3 | Nowy pakiet `com.roj.zen` | ostrzec w opisie wydania: stara aplikacja zostaje z danymi; przenieść konto podłączeniem urządzenia | P1, S |
| D4 | Integralność częściowa: „Podaj dalej” i ADB sprawdzają certyfikat APK, ale odcisk oficjalnego klucza nie jest jeszcze wpisany, a kopia może podmienić zbiórkę | odcisk w `apk_signature.dart`, podpisany manifest (§14.3) | P1, S |
| D5 | Windows bez Authenticode — SmartScreen straszy | SignPath (darmowy dla projektów otwartych) albo Azure Trusted Signing; później MSIX i winget | P2, S/M |
| D6 | Link do zbiórki (`buycoffee.to/zen`) nie jest jeszcze w podpisanym manifeście — kopia może go podmienić | podpisany manifest (§14.3) | P2, S |
| D7 | Brak instrukcji instalacji z obrazkami | Android (z zaawansowaną ścieżką 2027), Windows SmartScreen | P2, S |
| D8 | Aktualizacje przez sieć wyłączone (pusta lista opiekunów) | ten sam certyfikat + wyższy `versionCode` + 7 dni + zgoda człowieka (§14.2) | P3, S/M |
| D9 | Licencja zakazuje forków: F-Droid niemożliwy, ciągłość zależy od autora | decyzja o licencji; IzzyOnDroid i Obtainium działają z wydaniami z GitHuba | P3, S |
| D10 | iPhone tylko przez SideStore/AltStore (7 dni, bez pracy w tle); brak Maca i Linuksa | §26.3 | P3, M–L |

## 10. Niezrobione z planu

| Co | § | Rozmiar |
|---|---|---|
| Przestrzenie `hood`, `date`, `cell`, `treasury`, `event` w silniku | 4 | L |
| Tożsamość na kluczu konta | 6.1 | L |
| Klucz piramidy z klucza konta | 6.1 | S/M |
| Ruch piramidy przez relaye | 6.4 | M |
| Media „tylko Wi-Fi / po kliknięciu”, limity przechowywania | 7 | S |
| Widoczność pól profilu, narodowość | 9 | M |
| „N zweryfikowanych” przy polubieniach | 11 | S/M |
| Tablica grupy | 13 | M |
| Wiadomości do obcych (poza listem przez wspólnego znajomego) | 13, 24.1 | M |
| Ponowne potwierdzenie i blokada zrzutów dla randek | 14.1 | S |
| Tor, Wi-Fi Direct, siatka Bluetooth | 14.2, 28 | L |
| Kamuflaż, kanarek, lustra | 14.2 | S–M |
| Zatwierdzanie wersji do aktualizacji przez sieć | 14.2 | S/M |
| Integralność wydań i zbiórki | 14.3 | S–M |
| Bluetooth na Windows i iPhonie | 15 | M |
| Graf: przybliżanie i klastry dla dużych sieci | 16.1 | S/M |
| Alarm: położenie w tle, zapasowy SMS | 16.3 | M |
| „Przyprowadzający ręczy”, wspólna kasa kółka | 17.2–17.3 | S |
| Sąsiedzi: strona `/m`, czat zaproszenia | 18 | S/M |
| Randki: latarnie na żądanie | 19.7 | L |
| Sygnały farm kont, poręczenia z karami | 21.5 | M |
| Prywatność przelewów | 23.4 | L |
| Ekonomia kontaktów: ceny poza piramidą (jeśli w ogóle) | 24.1 | M |
| Grupowanie zakładek | 25 | S |
| Tłumaczenia i wybór języka | 25.1 | M |
| „Usuń z urządzenia” z blokadą skrótu | 26.1 | M |
| Bramka wieku | 26.1, 27 | S |
| macOS, Linux; iPhone bez ograniczeń (płatne konto) | 26.3 | M / L |
| Polityka prywatności, regulamin, DPIA | 27 | S |
| Specyfikacja protokołu, mapa zaufania | 28 | M, S |
| Flagi funkcji | 2.5 | S |

## 11. Kolejność prac

### Teraz (P1, przed szerszym udostępnieniem)

| Co | Rozmiar |
|---|---|
| Flagi funkcji: wydanie „rdzeń” (piramida i waluta za flagą) | S |
| Domyślna prywatność: bramka wieku | S |
| Klucz piramidy z klucza konta | S/M |
| Klucz podpisu z kopią Shamira; odcisk w README, w wydaniach i w `apk_signature.dart`; rejestracja jako zweryfikowany twórca Androida | S |
| Integralność §14.3 (podpisany manifest, w tym zbiórki) | S/M |
| Polityka prywatności, regulamin | S |
| Formaty od wersji 1 (§7) | S |

### Wkrótce (P2)

| Co | Rozmiar |
|---|---|
| Tłumaczenia: angielski i wybór języka (także „jak w systemie”) | M |
| Bluetooth: osobne sekrety na znajomego, rotacja z MAC (S5, S6) | M |
| Bateria: bez stałych blokad, obecność zdarzeniowa, media tylko Wi-Fi (A9) | M |
| Kryptografia poza wątkiem UI, fold piramidy przyrostowo (A5) | M |
| Graf: przybliżanie i klastry | S/M |
| Randki: latarnie na żądanie, 2 kroki (§19.7) | L |
| Alarm: położenie w tle, zapasowy SMS | M |
| Instrukcje instalacji z obrazkami; Authenticode na Windows | S; S/M |
| Kopia klucza konta na papierze; krąg proponowany przy powitaniu | S |
| Ponowne potwierdzenie i blokada zrzutów dla randek | S |
| Dostępność: etykiety dla czytnika ekranu | S |
| Grupowanie zakładek, proste powitanie | S |

### Później (P3)

| Co | Rozmiar |
|---|---|
| Jeden właściciel danych (usługa), UI jako klient; szyfrowany SQLite | L |
| Tożsamość na kluczu konta; przestrzenie `hood`/`date`/`cell`/`treasury`/`event` | L |
| Ruch piramidy przez relaye, bez adresu urządzenia | M/L |
| macOS i Linux | M |
| iPhone: praca w tle, Bluetooth, push (wymaga płatnego konta, §26.3) | L |
| Aktualizacje przez sieć wg §14.2 | S/M |
| Wzajemna weryfikacja oficjalnej wersji (key attestation) | M |
| Tor, Wi-Fi Direct, siatka Bluetooth; kamuflaż, kanarek, lustra | L; S–M |
| Specyfikacja protokołu; mapa zaufania | M; S |
| Prywatność przelewów | L |
| Podział kodu na pakiety | L |
| Decyzje organizacyjne: licencja na wypadek zniknięcia autora, fundacja, zmiana nazwy „Piramida” | — |
