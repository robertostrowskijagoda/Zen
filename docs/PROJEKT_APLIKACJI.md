# Zen — projekt aplikacji

Wersja 12 · 14.10.2026 · rozdziały w kolejności implementacji.

Numery rozdziałów (§N.M) są stałe, bo odwołuje się do nich kod. Nowe
podrozdziały dostają kolejne numery na końcu rozdziału. Stan projektu,
znane błędy, bezpieczeństwo i kolejność prac: `STAN.md`. Wydania i podpisy:
`WYDANIA.md`. Testy: `TESTOWANIE.md`. Historia zmian: `../CHANGELOG.md`.

Stan przy każdym obszarze: **Zrobione** (działa), **Częściowo** (działa,
braki wypisane), **Do zrobienia** (sam plan), **Propozycja** (do decyzji).
Rozmiar pracy: **S** (dni), **M** (tygodnie), **L** (miesiąc i więcej).

> **Po co to jest.** Sieć ludzi, którzy się znają: bez feedu od obcych,
> reklam i algorytmu, bez centralnej kontroli. Jedyna władza to **piramida**
> ludzi, którzy się znają, a zmiany szefów idą oddolnie, komórka po
> komórce, aż do szczytu. Sąsiedzi znów się poznają, randki są przez
> znajomych, polityka jest oddolna (bez partii: decydują ludzie w piramidzie).

## Spis treści

**Część 0 — Zasady i plan:** 1. Zasady · 2. Mapa drogowa (2.5 Przed
pierwszym publicznym wydaniem)

**Część I — Fundament:** 3. Architektura warstw · 4. Dziennik, przestrzenie,
polityki zapisu · 5. Sieć: mosty, węzły, aktualizacja Yggdrasil · 6.
Tożsamość, klucze, poświadczenia, odzyskiwanie, anonimowość · 7. Krąg
zaufanych, relaye, przechowywanie

**Część II — Profil i treści:** 8. Poziomy znajomości · 9. Profil główny ·
10. Tablica · 11. Polubienia i komentarze · 12. Obserwowanie · 13. Czaty,
grupy i rozmowy

**Część III — Bezpieczeństwo i odporność:** 14. Bezpieczeństwo, ochrona
danych, odporność na zakazy (14.3 Integralność oficjalnych wydań i zbiórki)

**Część IV — Spotkania i okolica:** 15. Osoby w pobliżu · 16. Graf, statusy,
alarm · 17. Życie po znajomości (17.6 Plan na weekend) · 18. Sekcja sąsiedzka

**Część V — Randki:** 19. Randki przez znajomych (19.5 Przeglądanie kart,
19.6 Zgłoszenia i ban randkowy, 19.7 Skala rozsyłania)

**Część VI — Wspólnota:** 20. Piramida · 21. Władza, delegacje, bany,
zgłoszenia, referenda · 22. Sekcja polityczna i krajowa · 23. Waluta ·
24. Rynek dostępu (24.1 Ekonomia kontaktów)

**Część VII — Całość:** 25. Nawigacja aplikacji (25.1 Języki, 25.2 Ekran
uprawnień, 25.3 Wygląd) · 26. Luki i ryzyka (26.3 iPhone, Mac, Linux) ·
27. Prawo · 28. Pomysły na później · 29. Asystent AI (usunięty)

---

# CZĘŚĆ 0 — ZASADY I PLAN

## 1. Zasady

1. **Brak serwera.** Nic nie zależy od maszyny, której nie ma żaden
   użytkownik. Wyjątki: publiczne węzły Yggdrasil jako awaryjny start
   (§5.1) i strona repozytorium na GitHubie, na którą prowadzą kody QR —
   kod zaproszenia jest po `#`, więc strona go nie dostaje (§14.2).
2. **Wszystko jest podpisane.** Sprawdzasz podpis, nie posłańca.
3. **Najpierw znajomi, potem źródło.** Dane pobierasz od tego, od kogo je
   dostałeś, i od znajomych; autora pytasz na końcu.
4. **Wypychać mogą tylko znajomi.** Wyjątki, wszystkie z limitami:
   podpisane wpisy władzy (§21), wiadomości i zaproszenia z pobliża (§15),
   płatne wiadomości (§24), reakcje na twój post dostarczane do twojego
   kręgu (§11), zlecenia przelewów do skarbników (§23).
5. **Lokalnie najpierw.** Zapis od razu u siebie, sieć dogania w tle.
6. **Zgodność w przód.** Starsza wersja przechowuje i przekazuje dalej to,
   czego nie rozumie. Nieznana (nowsza) wersja zapisu ma być tylko do
   odczytu, nigdy nadpisywana (dziś tak działa stan „Spotkań”; reszta: §2.5).
7. **Przejrzysta władza.** Każdy akt władzy to publiczny, podpisany wpis
   z uzasadnieniem; zmiany szefów idą oddolnie aż do szczytu.
8. **Prywatność domyślnie, poza postami.** Posty są domyślnie publiczne,
   bo mają się rozchodzić. Reszta (lista znajomych, statusy, randki,
   sąsiedzi, lokalizacja) jest domyślnie ograniczona. **Stan:** niespełnione
   dla listy znajomych i widoczności „W pobliżu” — obie są domyślnie
   włączone (`STAN.md`).

## 2. Mapa drogowa

### 2.1 Zasady kolejności

1. Najpierw to, od czego zależy reszta: sieć, konto, silnik.
2. Potem to, co przyciąga i zatrzymuje ludzi: profil, tablica, spotkania,
   randki. Piramida i waluta mają sens dopiero przy tysiącach osób.
3. Każdy etap kończy się działającą wersją na telefon i PC, z testami
   (także symulacją sieci).
4. Wspólne klocki budujemy raz, w pierwszym etapie, który ich potrzebuje.

### 2.2 Wspólne klocki

| Klocek | Etap | Używają go |
|---|---|---|
| Silnik: dziennik, pliki, replikacja, archiwum | 1 | wszystko |
| Silnik podłączony do sieci aplikacji (transport i relaye) | 2 | wszystko |
| Klucz konta + certyfikaty urządzeń | 2 | wszystko, co podpisane |
| Mosty i książka mostów | 2 | cała sieć |
| Klucze odbiorców (poziomy znajomości) | 3 | posty, profil, statusy, wydarzenia, randki |
| Drzewo udostępnień + sumy liczone drzewem | 3 | lajki, komentarze, posty polityczne, referenda, liczby piramidy |
| Poświadczenia (podpisane zdanie o kimś) | 6 | piramida, „zweryfikowani”, dane podstawowe, poręczenia |
| Bluetooth: rozgłaszanie + wymiana adresów | 6 | pobliże, spotkani osobiście, sąsiedzi, alarm |
| Zasięg w krokach (przekaż dalej do N kroków) | 6 | wydarzenia, Stół na sześć, Zapytaj sieć, randki |
| Wydarzenie (zaproszenie, zapisy, +1, bilet QR) | 6 | imprezy, kółka obiadowe, Stół na sześć, sąsiedzi |
| Podpisy wielu osób + przestrzeń władzy | 9 | komórki, zamiany, bany, emisja, skarbnicy |

### 2.3 Etapy

| # | Etap | Zawartość | Stan |
|---|---|---|---|
| 1 | Silnik | dziennik, pliki, certyfikaty, polityki zapisu, replikacja, archiwum, symulator sieci | Zrobione |
| 2 | Sieć i konto | Yggdrasil v0.5.14, pula węzłów, mosty na komputerach (§5.1), klucz konta i certyfikaty urządzeń (§6) | Zrobione; tożsamością w sieci jest nadal klucz węzła (§6.1) |
| 3 | Profil i tablica | poziomy z kluczami (§8), profil w dzienniku (§9), posty, udostępnianie, lajki, komentarze (§10–11), obserwowanie (§12), karty wdzięczności | Częściowo (§9, §11) |
| 3a | Rozmowy+ | udostępnianie ekranu, jawne nagrywanie, rozmowa w okienku (§13.1–13.3) | Zrobione (nagrywanie: Android, Windows) |
| 4 | Konto nie do stracenia | hasło, krąg odzyskiwania, wiele urządzeń (§6.3, §6.5), ochrona danych (§14.1) | Częściowo (§14.1) |
| 5 | Odporność | Podaj dalej, instalacja przez USB, ruch jak HTTPS, aktualizacje siecią (§14.2) | Częściowo: aktualizacje siecią wyłączone, §14.3 do zrobienia |
| 6 | Spotkania | Bluetooth (§15), graf, statusy, alarm (§16), wydarzenia i reszta §17 | Zrobione z brakami |
| 6a | Asystent AI | — | Usunięty w V1.9 (§29) |
| 7 | Sąsiedzi | §18 | Zrobione z brakami |
| 8 | Randki | §19 | Zrobione; nie skaluje się (§19.7) |
| 9 | Piramida i władza | §20–22 | Zrobione w kodzie; używanie po audycie i przy społeczności |
| 10 | Waluta, rynek dostępu | §23–24 | Zrobione w kodzie; przed użyciem audyt i opinia prawna |
| 11 | Pełnia | referenda drzewem, fala Bluetooth (§21.3, §28) | Zrobione w kodzie |

Kamienie milowe: po etapie 3 — pierwsza wersja dla ludzi; po etapie 6 —
wyróżnik (spotkania po znajomości); piramidę uruchamiamy, gdy jest
społeczność (np. ponad 1000 osób ze „spotkani osobiście”). Świadomie
odłożone: iPhone (§26.3), prywatność przelewów, Tor, tryb gościa
w przeglądarce.

### 2.4 Co już jest

Platformy: **Android i Windows** (gotowe), **iPhone** (SideStore /
AltStore, bez pracy w tle), macOS i Linux — w planie (§26.3).

| Obszar | § | Stan | Najważniejsze braki |
|---|---|---|---|
| Komunikator: czaty, grupy, rozmowy audio/wideo, relaye | 13 | Zrobione | wiadomości do obcych, tablica grupy |
| Rozmowy+: ekran, nagrywanie, okienko | 13.1–13.3 | Zrobione | nagrywanie na macOS/Linux |
| Sieć, mosty | 5 | Zrobione | — (Yggdrasil 0.5.14, most Go budowany automatycznie) |
| Konto, urządzenia, odzyskiwanie | 6 | Częściowo | tożsamość = klucz węzła; klucz piramidy losowy na każdym urządzeniu; ruch piramidy przez relaye |
| Profil, tablica, lajki, obserwowanie | 9–12 | Częściowo | widoczność pól profilu, narodowość, „N zweryfikowanych”, media „tylko Wi-Fi” |
| Ochrona danych na urządzeniu | 14.1 | Częściowo | ponowne potwierdzenie i blokada zrzutów dla randek; usługa w tle trzyma klucz główny |
| Odporność, dystrybucja | 14.2 | Częściowo | aktualizacje siecią wyłączone; kamuflaż, kanarek, Tor, Wi-Fi Direct |
| Integralność wydań i zbiórki | 14.3 | Częściowo | sprawdzanie certyfikatu APK jest; brak przypiętego odcisku i podpisanego manifestu |
| Osoby w pobliżu (Bluetooth) | 15 | Częściowo | tylko Android; wspólny sekret |
| Graf | 16.1 | Zrobione | przybliżanie i klastry |
| Statusy | 16.2 | Zrobione | — |
| Alarm | 16.3 | Częściowo | położenie w tle, zapasowy SMS |
| Wydarzenia, kółka, Stół na sześć, plan na weekend, Zapytaj sieć | 17 | Zrobione | „przyprowadzający ręczy”, wspólna kasa kółka |
| Sąsiedzi | 18 | Zrobione | strona `/m`, czat zaproszenia |
| Randki | 19 | Zrobione | skala (§19.7) |
| Piramida, władza, polityka | 20–22 | Zrobione w kodzie | flagi funkcji, adres urządzenia widoczny w piramidzie |
| Waluta, rynek dostępu | 23–24 | Zrobione w kodzie | prywatność przelewów |
| Nawigacja, wygląd | 25 | Częściowo | tłumaczenia (§25.1) |
| Prawo | 27 | Do zrobienia | polityka prywatności, regulamin, DPIA, bramka wieku |

### 2.5 Przed pierwszym publicznym wydaniem

1. **Flagi funkcji (S).** Wydanie „rdzeń”: czaty, rozmowy, profil, tablica,
   spotkania, sąsiedzi, alarm. Piramida, waluta i rynek (rozważyć
   też randki) za przełącznikiem „funkcje eksperymentalne”, do audytu
   i opinii prawnej.
2. **Usunąć migracje i kod zgodności wstecz (S/M).** **Zrobione w 1.10.0**
   (zostaje przepieczętowanie konfiguracji węzła). Do zrobienia: formaty od
   wersji 1, enumy po nazwie, możliwości w powitaniu (`STAN.md` §7).
3. **Jedna numeracja wersji (S)** — **zrobione:** 1.10.0 (10).
4. **Klucz podpisu, jego kopia, opublikowany odcisk (S)** — `WYDANIA.md`,
   §14.3.
5. **CI (S)** — **zrobione:** GitHub Actions (`ci.yml`, `release.yml`,
   `ios.yml`, `pages.yml`).
6. **Domyślne ustawienia zgodne z §1.8, bramka wieku, polityka prywatności
   (S)** — §27.

---

# CZĘŚĆ I — FUNDAMENT (etapy 1–2)

## 3. Architektura warstw

```
┌───────────────────────────────────────────────────────────────────────┐
│ FUNKCJE: tablica · czaty · graf · pobliże · sąsiedzi · randki ·       │
│          piramida · polityka · waluta · rynek dostępu                 │
├───────────────────────────────────────────────────────────────────────┤
│ PRZESTRZENIE z polityką zapisu: konto | grupa | komórka piramidy |    │
│ władza | księga waluty                                                │
├───────────────────────────────────────────────────────────────────────┤
│ SILNIK: dziennik, bloby, certyfikaty, replikacja, archiwum na dysku   │
├───────────────────────────────────────────────────────────────────────┤
│ TRANSPORT: Yggdrasil · relaye/krąg · Bluetooth                        │
└───────────────────────────────────────────────────────────────────────┘
```

Każda nowa funkcja to nowy rodzaj przestrzeni z własną regułą „kto może
pisać” na tym samym silniku, a nie drugi system obok.

**Stan: Częściowo.** Obok dziennika działa kilka osobnych mechanizmów
rozsyłania (skrzynki relayów, synchronizacja piramidy, paczki randkowe,
łańcuchy wydarzeń i pytań, sąsiedzi, stan znajomego w „Spotkaniach”), każdy
z własnymi limitami i błędami. Kierunek: nowe funkcje na przestrzeniach
dziennika, jeden mechanizm „stan znajomego” (`STAN.md`).

## 4. Dziennik, przestrzenie, polityki zapisu

Silnik (etap 1): podpisane wpisy w łańcuchu, HLC (zegar odporny na złe
zegary, wpisy z przyszłości odrzucane), wykrywanie rozwidleń, odcinanie
urządzeń, synchronizacja różnic, archiwum.

| Przestrzeń | Kto pisze | Kto czyta |
|---|---|---|
| `feed/<konto>` | urządzenia konta | wg widoczności wpisu (§10) |
| `acts/<konto>` | urządzenia konta | wg widoczności (lajki, komentarze, obserwowania) |
| `private/<konto>` | urządzenia konta | tylko urządzenia konta (szyfrowane) |
| `profile/<konto>` | urządzenia konta | wg widoczności pola |
| `own/<konto>` | urządzenia konta | nie wychodzi poza urządzenia konta (§6.5) |
| `hood/<klucz mieszkania>` | domownicy | sąsiedzi (§18) |
| `date/<klucz randkowy>` | klucz randkowy | do 3 kroków (§19) |
| `cell/<id komórki>` | 2 z 3 członków | komórka i gałąź w dół |
| `power/<id piramidy>` | szczyt (2 z 3) + delegaci | wszyscy w piramidzie |
| `treasury/<id piramidy>` | skarbnicy | skarbnicy + strony przelewu |
| `event/<id>` | organizator (+ goście: zapisy, +1) | goście i zaproszeni w zasięgu (§17) |

Ogłoszenia mostów (§5.1) to osobna, mała książka z własnymi limitami.

**Stan: Częściowo.** Silnik przyjmuje `feed`, `acts`, `private`, `profile`,
`own` i (zamkniętą) `power`. `hood`, `date`, `cell`, `treasury` i `event`
— do zrobienia (L); te funkcje działają dziś na własnych plikach
i mechanizmach.

## 5. Sieć: mosty, węzły, aktualizacja Yggdrasil

### 5.1 Sieć, która sama się rozrasta (mosty)

**Cel:** publiczne węzły Yggdrasil są tylko awaryjnym startem; sieć niesie
się sama przez mosty użytkowników.

1. **Każdy komputer, który może, jest mostem** — domyślnie włączone, bez
   komunikatu (decyzja z 10.2026). Wyłącznik „Pomagaj innym się łączyć”
   jest na dole ustawień (Zaawansowane → Sieć i usługa). Telefony zwykle
   nie mogą być mostami (sieć komórkowa blokuje połączenia przychodzące).
2. **Ogłoszenie mostu ma osobny, anonimowy klucz mostu**: `{tls://IP:port,
   klucz mostu, ważny do, dowód pracy, podpis}`, bez konta i adresu
   urządzenia.
3. **Ogłoszenia rozchodzą się plotką**: przy synchronizacji ze znajomym
   wymiana próbki (najświeższe + losowe).
4. **Książka mostów**: do ~2000 mostów, ocena (działa, opóźnienie),
   połączenie z kilkoma najlepszymi z różnych sieci.
5. **Nowa osoba** startuje z publicznych węzłów, mosty dostaje od pierwszego
   znajomego. Kod zaproszenia nie niesie mostów (ma być krótki).
6. **Sieć lokalna**: w tym samym Wi-Fi urządzenia łączą się same
   (multicast; na komputerach wyłączony, §26.1).

| Atak | Obrona |
|---|---|
| Milion fałszywych mostów | dowód pracy (~kilka sekund, ważny 7 dni), limit ogłoszeń na IP i /24 |
| Nieistniejące adresy | przed przekazaniem dalej aplikacja łączy się i czeka na powitanie Yggdrasil; nieudane nie idą dalej |
| Wzmocnienie DDoS (cudze IP) | ofiara nie odpowie powitaniem; każda aplikacja sprawdza kilka nowych mostów na minutę, tylko publiczne IP |
| Zalewanie wymianą | tylko przy synchronizacji ze znajomym, próbka ~50 wpisów |
| Otoczenie (eclipse) | mosty z różnych bloków adresów, zawsze też publiczne węzły |
| Przeciążenie mostu | limit połączeń i transferu na most |

**Cena:** adres IP każdego komputera-mostu jest widoczny w sieci. Kto zbiera
ogłoszenia, ma listę IP komputerów z Zen; dostawca internetu przypisze IP do
abonenta. Do tego most nasłuchuje kluczem węzła, który jest adresem w Zen,
więc zdradza, czyj to komputer (§26.1).

**Stan: Zrobione.** `BridgeHost` (`lib/src/features/ledger/bridge_host.dart`):
port w routerze (`port_mapper.dart`: UPnP IGD, potem NAT-PMP; najpierw
zewnętrzny 443, potem 32913), kandydaci (adres zewnętrzny routera, publiczne
adresy komputera), sprawdzenie przez znajomych (`lg_reach` / `lg_reach_ok`),
ogłoszenie, odnawianie co 30 min, wycofanie, gdy nikt się nie dostaje. Stan
widać w ustawieniach. Kraje bez bazy geolokalizacji: rozkład na bloki /16
i /24. Pula publicznych węzłów odświeżona (233 adresy z 30 krajów; komputer
łączy się z 20, telefon startuje od 16 stabilnych TLS).

### 5.2 Aktualizacja Yggdrasil

- **Teraz:** yggdrasil-go v0.5.14 (z v0.5.12, wrzesień 2026): kolejki
  pakietów do 1 MB, lepsze trasowanie, szybsze ponowne łączenie. Zgodny
  z v0.5.x.
- **Na stałe:** przy każdym wydaniu odświeżona lista publicznych węzłów, co
  kwartał przegląd wydań Yggdrasil; książka mostów z czasem zastępuje listę.
- **Do zrobienia:**
  - przejść na najnowsze wydanie Yggdrasil i Go (S);
  - **automatyczne budowanie mostu Go** (i innych zależności natywnych)
    w ramach `flutter build` dla Androida (zadanie Gradle przed pakowaniem
    `jniLibs`) i Windows (krok CMake), tylko gdy zmieniły się źródła albo
    wersje: znacznik ze skrótem `native/yggdrasil_bridge/*.go`, `go.mod`,
    `go.sum` i wersji Go. Dziś ręcznie `build_android.ps1`
    / `build_windows.ps1`, a gotowe biblioteki leżą w repozytorium (M).

## 6. Tożsamość, klucze, poświadczenia, odzyskiwanie, anonimowość

### 6.1 Klucze

| Klucz | Gdzie | Do czego |
|---|---|---|
| **Klucz konta** (Ed25519) | na urządzeniach, zaszyfrowany hasłem konta | nowe urządzenie, odłączenie, zmiana kręgu, przelewy (§23) |
| **Klucz urządzenia** (osobny od klucza Yggdrasil) | każde urządzenie swój | codzienne podpisy |
| **Klucz mieszkania** | telefony domowników | profil mieszkania (§18) |
| **Klucz tożsamości w piramidzie** | urządzenia konta | pseudonim w piramidzie i konto w skarbie (§6.4) |
| **Klucze jednorazowe** | na chwilę | pobliże (§15) |

- Złodziej telefonu bez hasła nie przejmie konta; skradziony telefon
  odłączasz z innego urządzenia, jego późniejsze wpisy są odrzucane.
- **Kod zaproszenia:** 25 znaków (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`): pełny
  adres węzła (120 bitów) + znak kontrolny. Kod QR to link
  `https://robertostrowskijagoda.github.io/Zen/#KOD` (bez myślników, kod po
  `#`) — jednoplikowa strona na GitHub Pages (`tool/pages/index.html`),
  która otwiera Zen z kodem (Android: `intent://`, inne: `zen://c/KOD`), a
  bez Zen pokazuje pobieranie. Zen przyjmuje też `zen://c/KOD` i link do
  strony projektu `github.com/…/zen#KOD`. Krócej się nie da bez serwera.

**Stan: Częściowo.**
- Tożsamością w sieci jest nadal klucz węzła Yggdrasil (adres = klucz =
  kod zaproszenia, bez rotacji). Cel: tożsamością jest klucz konta, klucze
  węzłów wymienne i poświadczane (L).
- Klucz piramidy jest losowy na każdym urządzeniu: zgubiony telefon to
  utrata portfela i miejsca w piramidzie, a telefon i komputer to dla
  piramidy dwie osoby. Naprawa: klucz pochodny od klucza konta (HKDF) (S/M).
- Brak kopii klucza konta na papierze (S).

### 6.2 Poświadczenia (ogólny mechanizm)

Podpisane zdanie jednej osoby o drugiej: `{kto, o kim, co, do kiedy, podpis}`.

| Poświadczenie | Kto wystawia | Po co |
|---|---|---|
| **Spotkani osobiście** | obie strony, przy dodaniu przez QR lub Bluetooth | najsilniejszy sygnał przeciw fałszywym kontom |
| **Członek piramidy** | komórka (2 z 3) | „prawdziwy człowiek” (§20) |
| **Dane podstawowe** (rok urodzenia, narodowość, płeć) | przyjmujący do piramidy | obowiązują, dopóki jesteś w piramidzie (§20.2a) |
| **Poręczenie** | znajomy | „to prawdziwa osoba”; za fałszywe grozi kara (§21.5) |

**Stan: Częściowo.** Spotkani osobiście, członek piramidy i dane podstawowe
działają; ogólne poręczenia z karami (§21.5) — do zrobienia (M).

### 6.3 Odzyskiwanie konta

Krąg do 6 osób, każda dostaje zaszyfrowany kawałek klucza (Shamir,
Argon2id). Odzyskanie: hasło + 2 z kręgu po 24 h, z alarmem na starych
urządzeniach; bez hasła: 4 z kręgu po 7 dniach. Po odzyskaniu nowe
urządzenie wita znajomych, którzy oddali kawałki; trzymają oni
zaszyfrowaną kopię listy znajomych i grup (§6.5), więc konto wraca z nimi.

**Stan: Zrobione.** Brakuje: propozycji kręgu przy powitaniu (dziś schowany
w ustawieniach) (S).

### 6.4 Anonimowość

**Zasada: nikt nie musi podawać o sobie niczego.** Wszystkie pola profilu są
opcjonalne, imię może być pseudonimem.

| Tożsamość | Kto zna powiązanie z tobą |
|---|---|
| profil główny | ci, którym go pokażesz |
| tożsamość w piramidzie | tylko twoja komórka (i komórka, którą prowadzisz) |
| profil mieszkania | domownicy |
| profil randkowy | nikt, dopóki go nie odsłonisz |
| pobliże (BT) | nikt (klucze jednorazowe) |

- Reszta piramidy widzi pseudonim, poziom, wielkość gałęzi i narodowość
  (§22.2). Konto w skarbie (§23) należy do tożsamości w piramidzie.
- Połączenie tożsamości jest dobrowolne (podpis obu kluczy), np. żeby
  startować w wyborach pod nazwiskiem.
- Sieć: adres urządzenia widzą ci, z którymi się łączysz. Dla ról
  anonimowych ruch ma iść przez relaye z kręgu.
- Anonimowość nie chroni przed kimś, kto przejmie telefon (§14.1), ani przed
  członkami własnej komórki.

**Stan: Częściowo.** Piramida ujawnia adres urządzenia
(`pyramid_service.dart` → `pyramid_state.dart`), a ruch piramidy nie idzie
przez relaye — do zrobienia (M/L).

### 6.5 Konto na kilku urządzeniach (V1.10)

**Stan: Zrobione** (`account_link.dart`, `device_chat_sync.dart`,
Ustawienia → Urządzenia).

- **Podłączanie:** nowe urządzenie pokazuje swój zwykły kod; obie strony
  robią jednorazowe klucze X25519 (z zobowiązaniem commit–reveal)
  i pokazują te same 6 cyfr. Po potwierdzeniu klucz konta idzie
  zaszyfrowany; hasło konta jest potrzebne, jeśli jest ustawione.
- **Rozpoznawanie urządzeń:** każde urządzenie zapisuje w `acts` swój adres
  i w powitaniu pokazuje certyfikat podpisany kluczem konta oraz podpis
  klucza urządzenia pod adresem, z którego przyszło (bez tego dowodu ktoś
  mógłby udawać drugie urządzenie znajomego).
- **Jedna osoba dla znajomych** (`AccountRoutingTransport`): wiadomość idzie
  na każde urządzenie znajomego; rozmowę odbiera jedno, pozostałe milkną;
  wysłane wiadomości i pliki trafiają na własne pozostałe urządzenia. Tak
  samo dla członków grup, którzy nie są znajomymi.
- **Znajomi i grupy** zapisane w `private`, zaszyfrowane kluczem znanym
  tylko urządzeniom konta; znajomi trzymają kopię, której nie przeczytają.
  Usunięcia (`contact_removed`), zmiany nazw i blokady idą z kopią.
- **Historia rozmów:** przestrzeń `own` trafia tylko do urządzeń konta;
  nowe urządzenie dostaje jednorazowo całą historię (`chat_history`, pliki
  do 25 MB), import po identyfikatorze bez dublowania.
- **Odłączanie:** podpisane kluczem konta, z punktem odcięcia dla każdej
  przestrzeni; odłączone urządzenie przestaje dostawać wiadomości i wie
  o tym.

## 7. Krąg zaufanych, relaye, przechowywanie

- **Krąg to do 6 zaufanych osób**: skrzynka dla wiadomości, przechowalnia
  mediów, prowadzący liczniki lajków, strażnicy odzyskiwania konta.
  Proponowany domyślnie z przyjaciół (§8).
- **Limity (plan):** wpisy znajomych 12 mies., media kręgu 2 GB na osobę,
  cache 1 GB, udostępnione na stałe.
- **Pobieranie mediów:** Zawsze / Tylko Wi-Fi / Tylko po kliknięciu.

**Stan: Częściowo.** Relaye i krąg działają. Każdy telefon domyślnie pobiera
i oddaje dalej wszystkie media znajomych; „Tylko Wi-Fi / po kliknięciu”
i limity — do zrobienia (S–M), docelowo domyślnie „Tylko Wi-Fi”.

---

# CZĘŚĆ II — PROFIL I TREŚCI (etap 3)

## 8. Poziomy znajomości

| Poziom | Kim jest | Domyślnie widzi | Domyślnie może |
|---|---|---|---|
| **Słaby znajomy** | ledwo znany | posty publiczne + „Wszyscy znajomi” | pisać do ciebie |
| **Znajomy** | ktoś, kogo znasz | + „Znajomi i przyjaciele”, twoja lista znajomych | zapraszać do grup, widzieć status |
| **Przyjaciel** | bliska osoba | + „Tylko przyjaciele”, pełne statusy, lokalizacja alarmu | być w kręgu, dostać alarm, poręczyć |

- Poziom nadajesz sam i jest prywatny; każda strona ma swoją ocenę.
- Nowa znajomość zaczyna jako „Znajomy”; przy spotkaniu osobiście aplikacja
  proponuje wybór poziomu.
- Każdy poziom ma własny klucz szyfrowania; obniżenie poziomu rotuje klucz.

**Stan: Zrobione.**

## 9. Profil główny (i mini-profil, który z niego wynika)

- Profil edytujesz na swoim profilu („Edytuj profil”), nie w ustawieniach.
  W ustawieniach zostaje część techniczna (hasło, urządzenia, krąg).
- Status zmieniasz dotknięciem pod imieniem na profilu.
- Edycja: avatar, zdjęcie tła (3:1, bez EXIF), imię, bio z formatowaniem.
- **Galeria** oddzielna od postów: wpisy `gallery` szyfrowane dla wybranej
  widowni, usuwanie wpisem `gallery_del`.
- **Mini-profil** powstaje sam z profilu: imię, miniatura, odznaki;
  podpisany, dołączany do lajków, komentarzy i wiadomości do obcych.
- Wygląd: baner, avatar, imię, status, bio, przyciski (Dodaj / Obserwuj /
  Wiadomość / Poziom), liczby, zakładki Posty · Zdjęcia · Filmy ·
  Podziękowania · Informacje.
- **Karty wdzięczności**: podpisane „dziękuję” z krótkim opisem; bez
  wartości w walucie, kilka kart miesięcznie od jednej osoby.
- Każde pole ma widoczność: Publiczne / Wszyscy znajomi / Znajomi
  i przyjaciele / Przyjaciele / Tylko ja.
- **Narodowość**: opcjonalne pole (można kilka), otwiera sekcję krajową
  (§22.2); w piramidzie liczy się narodowość potwierdzona (§20.2a).
- Profile sąsiedzki (§18) i randkowy (§19) są oddzielne.

**Stan: Częściowo.** Brakuje widoczności dla każdego pola i narodowości (M).
Lista znajomych jest domyślnie pokazywana znajomym i idzie do wszystkich,
także słabych znajomych — wbrew §1.8 (S). Profil w dzienniku jest publiczny
razem z adresem (`ledger_profile.dart`).

## 10. Tablica, posty, udostępnianie

- Widoczność posta: Publiczny / **Wszyscy znajomi (domyślnie)** / Znajomi
  i przyjaciele / Tylko przyjaciele. Udostępniać można tylko publiczne.
- Udostępnienie niesie cały podpisany post do znajomych udostępniającego.
- **Tablica chronologiczna, bez algorytmu, kończy się** („Jesteś na
  bieżąco”). Obcy post widzisz tylko, gdy udostępnił go ktoś, kogo dodałeś.
- Zdjęcia i filmy bez EXIF/GPS; film do 200 MB w kawałkach, oglądany
  w trakcie pobierania.
- Usuwanie to podpisany nagrobek (przy postach publicznych tylko prośba);
  edycja tworzy wersje z oznaczeniem „edytowano”.

**Stan: Zrobione.**

## 11. Polubienia, komentarze, drzewo udostępnień

- Post rozchodzi się drzewem udostępnień: w dół zdjęcia, licznik
  i usunięcia, w górę paczkami lajki i komentarze.
- Lajk to podpisany wpis z mini-profilem. Pełna lista jest u autora i jego
  kręgu; inni dostają podpisaną migawkę i dociągają resztę stronami.
- Najpierw twoi znajomi: „Lubią to: Bob, Kasia i 1 284 inne osoby”, obok
  „w tym 830 zweryfikowanych” (piramida albo „spotkani osobiście” u twoich
  znajomych).
- Autor ukrywa komentarze i blokuje osoby w swoich wątkach. Powiadomienia
  zbiorcze.

**Stan: Częściowo.** „N zweryfikowanych” — do zrobienia (S/M).

## 12. Obserwowanie

- Każdy może obserwować każdego, bez zgody; widzi tylko treści publiczne.
- Znajomi obserwują automatycznie; lista i liczba obserwujących na profilu.
- Autor może zablokować osobę (jej reakcje znikają), ale nie zabroni czytania
  treści publicznych.

**Stan: Zrobione.**

## 13. Czaty, grupy i rozmowy

- Czaty 1:1, grupy, połączenia audio i wideo (także grupowe), relaye.
- Wiadomości na wszystkie urządzenia konta (§6.5), czaty z pobliża (§15).
- Głosówki i nagrania audio z pliku — w czacie i w postach (§10).
- **Nazwa znajomego to nazwa z jego profilu** (przychodzi z zaproszeniem,
  odpowiedzią i każdą aktualizacją profilu; nie da się jej zmienić). Własne
  oznaczenie to **pseudonim**: widoczny tylko na urządzeniach tego konta,
  małą kursywą pod nazwą.
- Grupa może mieć **tablicę grupy** (przestrzeń z postami) — dla komórek
  piramidy i zwykłych grup.

**Stan: Częściowo.** Brakuje: tablicy grupy (M) i wiadomości do osób spoza
znajomych w zwykłych czatach (§24.1) (M).

### 13.1 Udostępnianie ekranu (etap 3a)

- W każdej rozmowie wideo, także grupowej: cały ekran albo jedna aplikacja
  (na komputerze okno; na Androidzie 14+ systemowe „Udostępnij jedną
  aplikację”, na starszym aplikacja uprzedza, że pójdzie cały ekran).
- Druga ścieżka wideo w istniejącym połączeniu WebRTC, bez serwera.
- Wszyscy widzą, kto udostępnia; udostępniający ma stały pasek „Zatrzymaj”.
- Na czas udostępniania aplikacja ukrywa własne powiadomienia z treścią
  i przypomina, że widać wszystko (także kody SMS).

**Stan: Zrobione.**

### 13.2 Nagrywanie rozmów (etap 3a)

- Każdy uczestnik może nagrać rozmowę 1:1 i grupową (dźwięk, w wideo też
  obraz). **Nagrywanie zawsze jawne:** podpisany sygnał do wszystkich
  (także dołączających później), czerwony pasek „Ada nagrywa”, dźwięk,
  przycisk „Wyjdź z rozmowy”.
- Zmodyfikowana aplikacja albo dyktafon obok nagra bez informacji; obietnica
  dotyczy tego, że zwykła aplikacja nigdy nie nagrywa po cichu.
- Nagranie zostaje u nagrywającego, zaszyfrowane (§14.1); wychodzi tylko
  przez „Eksportuj”. Prawo: §27.

**Stan: Zrobione.** Android: `MediaRecorder` z flutter_webrtc. Windows:
`windows/runner/call_recorder.cpp` — dźwięk tylko procesu Zen (WASAPI
process loopback) z mikrofonem, WAV 48 kHz; od Windows 10 2004. W grupie
sygnał `gc_rec`. Nagranie przerwane końcem rozmowy też jest zapisywane.
Brakuje macOS/Linux (razem z tymi wersjami).

### 13.2a Dostępność treści bez autora (V1.9)

- Każdy znajomy trzyma kopię przestrzeni znajomych (`feed`, `acts`,
  `profile`) i ich pliki, więc posty autora offline przychodzą od innych.
  Wpisy są podpisane, niepubliczne zaszyfrowane — pośrednik nic nie podrobi
  ani nie przeczyta.
- Pliki: źródła to autor i wszyscy znajomi; brakujące są wznawiane po
  restarcie (`_resumeMedia`), nowo widziany znajomy pytany od razu
  (`offerSource`).
- Android: w tle usługa uruchamia drugą kopię `LedgerNode` na tym samym
  dysku; aplikacja ją zawiesza (`suspend`) i po powrocie doczytuje
  (`LedgerArchive.catchUp`). Na dysk pisze jedna kopia.
- Co 10 min węzeł sam wita znajomych. Gdy nikt z kopią nie jest online, nie
  ma skąd pobrać.

**Stan: Zrobione.** Koszt: dwa środowiska na tych samych plikach (`STAN.md`).

### 13.3 Rozmowa nad innymi aplikacjami (V1.9)

- **Android:** obraz w obrazie (`setPipCall`; od Androida 12 system sam,
  na starszych `onUserLeaveHint`), bez uprawnienia „nad aplikacjami”.
- **Komputer:** małe okno zawsze na wierzchu (`CallCompactMode`), przycisk
  „Mini okno”, przy minimalizacji i zamknięciu okna w trakcie rozmowy.

**Stan: Zrobione.**

### 13.4 Działanie w tle a powiadomienia

- **Android:** bez serwera (i bez Firebase) odbiór wymaga usługi
  pierwszoplanowej z powiadomieniem o minimalnej ważności. Typ usługi
  `specialUse` (Android 14+), bo `dataSync` ma od Androida 15 limit 6 h na
  dobę; gdy system ją
  zatrzyma, przychodzi powiadomienie „Zen nie odbiera w tle — otwórz na
  chwilę”.
- **iOS:** system nie pozwala działać w tle bez przerwy; udawanie
  nawigacji czy dźwięku łamie wytyczne App Store (2.5.4). Uczciwa droga:
  powiadomienia push (APNs) bez treści wysyłane przez skrzynki offline,
  połączenia przez PushKit + CallKit — wymaga konta Apple Developer
  i klucza APNs po stronie skrzynek (§26.3).

**Stan (Android): Zrobione.** Koszt baterii: `STAN.md`.

---

# CZĘŚĆ III — BEZPIECZEŃSTWO I ODPORNOŚĆ (etapy 4–5)

## 14. Bezpieczeństwo, ochrona danych, odporność na zakazy

| Kto atakuje | Co może | Co go zatrzymuje |
|---|---|---|
| Obcy | czytać publiczne | nic ci nie wypchnie (zasada 4) |
| Farma kont | lajki, spam, pchanie się do piramidy | „zweryfikowani”, spotkania osobiste, poręczenia, kary §21.5 |
| Stalker w pobliżu | śledzić po Bluetooth | zmienne identyfikatory, brak imienia dla obcych |
| Nękający | pisać | 1 wiadomość, płatna skrzynka, blokady, zgłoszenia |
| Złodziej telefonu | pisać jako urządzenie | hasło chroni konto i portfel, odłączenie urządzenia |
| Członek kręgu | fałszować liczniki | podpisy lajków, 6 kopii |
| Zmówieni z kręgu | odzyskać twoje konto | hasło + 24 h / 4 osoby + 7 dni, alarm |
| Skorumpowany szef | nadużywać władzy | zamiana w komórce (§20.3), jawność aktów |
| Skorumpowany szczyt | drukować pieniądze, banować | jawna emisja, weto, referenda, oddolne zamiany |
| Zmowa skarbników | podwójne wydanie | większość z 15, jawny dowód, zamiana |
| Fałszywa piramida | ogłosić się władzą | uznajesz tylko swoją (§20.5) |
| Zmodyfikowany klient | ignorować bany, nie kasować | nie wymusimy; nie podrobi podpisów ani nie odszyfruje |
| Podrobiona kopia Zen | szpiegować, podmienić zbiórkę | podpis APK, §14.3 |

Dodatkowo: EXIF i GPS usuwane, obrazy przychodzące dekodowane i kodowane od
nowa; lokalizacja tylko przy alarmie i „Idę na randkę”, tylko do
przyjaciół, z czasem ważności; obcy, który zna klucz konta, może pytać tylko
o treści publiczne.

### 14.1 Ochrona danych na urządzeniu (Pegasus i spółka)

Oprogramowanie klasy Pegasus przejmuje cały telefon; gdy aplikacja jest
odblokowana, czyta ekran, pamięć i klawiaturę. Cel: **zablokowana aplikacja
jest dla szpiega bezużyteczna** (na dysku tylko szyfrogram), a odblokowana
ujawnia jak najmniej i jak najkrócej. Wszystkie dane na dysku są szyfrowane
kluczem głównym (szyfrowanie kopertowe, AES-GCM z AAD).

| # | Mechanizm | Stan |
|---|---|---|
| 1 | **Klucz główny tylko w pamięci, tylko po odblokowaniu**; kasowany przy blokadzie | Zrobione. Domyślnie blokada po 5 min w tle (wcześniej tylko po restarcie telefonu); „Zablokuj teraz” na belce. Wyjątek: usługa w tle na Androidzie trzyma klucz, bo odbiera wiadomości — docelowo usługa bez klucza głównego (M) |
| 2 | **Klucz zawinięty sprzętowo** (Android Keystore/StrongBox z silną biometrią; Windows TPM + Windows Hello) | Zrobione. Biometria domyślnie wyłączona; jedno pytanie przy ustawianiu pierwszego hasła. Windows Hello bez sprzętowej zgody (STAN.md) |
| 3 | **Hasło domyślnie wymagane** (min. 8 znaków) + Argon2id | Zrobione. Pominięcie tylko świadome („Pozwól używać aplikacji bez hasła”) |
| 4 | **Ponowne potwierdzenie** wrażliwych miejsc (60 s) | Częściowo: konto i odzyskiwanie, urządzenia, nagrania. Portfel i randki — do zrobienia (S) |
| 5 | **Media na dysku zaszyfrowane**, bez miniatur w galerii systemu | Częściowo: załączniki, głosówki i zdjęcia znajomych leżą jawnie, a nazwy katalogów zdradzają kontakty — do zrobienia (M) |
| 6 | **Blokada zrzutów** (Android `FLAG_SECURE`, Windows `WDA_EXCLUDEFROMCAPTURE`) | Zrobione na czatach, grupach, nagraniach, koncie, urządzeniach (domyślnie włączona); portfel i randki — do zrobienia (S) |
| 7 | **Powiadomienia bez treści** (domyślnie „Nowa wiadomość”) | Zrobione, także randki i piramida |
| 8 | **Klawiatura incognito** w polach wiadomości | Zrobione |
| 9 | **Schowek czyszczony** po 60 s | Zrobione |
| 10 | **Znikające wiadomości** (1 h / 1 dzień / 7 dni) | Zrobione; nie trafiają do trwałych kopii konta |
| 11 | **Hasło paniki** kasuje klucz główny i klucz w układzie bezpieczeństwa | Częściowo: zostają cache/temp, `Android/data/<pakiet>/files/Zen`, pliki w Dokumentach/Pobranych na Windows (S) |
| 12 | **Wykrywanie roota** (su, Magisk, LSPosed, Frida, klucze testowe) jako ostrzeżenie | Zrobione |

Ustawienia aplikacji są zapisywane jako JSON z nazwanymi polami (koniec
dziesięciu binarnych wersji formatu; nieczytelny stary plik = ustawienia
domyślne). Nazwy plików załączników od innych są oczyszczane przy odbiorze
i zapisie (wcześniej „Zapisz kopię” pozwalało nadpisać pliki w katalogu
aplikacji).

**Media od innych (`media_guard.dart`).** Zdjęcie od kogokolwiek (czat,
posty, profile, randki) jest dekodowane czystym Dartem i kodowane od nowa
(bez metadanych), więc systemowy dekoder obrazów nigdy nie widzi oryginału;
obraz, którego nagłówek zapowiada więcej niż 40 Mpx, jest odrzucany przed
dekodowaniem. Film i nagranie muszą mieć znany kontener, którego struktura
się zgadza (pudełka MP4 mieszczą się w pliku, nagłówek WebM mówi „webm”);
inaczej zostają zwykłym plikiem. Typ, MIME i nazwę ustala zawartość, nie
nadawca; nazwy tracą znaki kierunku tekstu. Zen nie otwiera plików, a przed
zapisem programu (po zawartości albo rozszerzeniu) ostrzega. Zdjęcia
z aparatu wysyłane w czacie tracą EXIF i GPS. Filmy nadal dekoduje system
(na telefonie nie da się ich przekodować) — to ryzyko szczątkowe.

Czego nie obiecujemy: gdy szpieg siedzi w odblokowanym telefonie i patrzy
na ekran, widzi to, co ty.

### 14.2 Odporność na zakazy, cenzurę i naciski polityczne

**Cel:** jeśli ktoś ustawą, naciskiem na Google lub Apple albo na autora
spróbuje zablokować aplikację, ludzie mają jej dalej używać. Serwera nie ma,
więc słabe punkty to dystrybucja, sieć i ludzie.

| # | Zagrożenie | Obrona |
|---|---|---|
| 1 | Brak sklepu / usunięcie ze sklepu | Wydania na GitHubie (`WYDANIA.md`) i **„Podaj dalej”**: hotspot + QR, ta sama sieć Wi-Fi, Quick Share / Bluetooth, także bez internetu |
| 2 | **Weryfikacja twórców Androida** (od 30.09.2026 w Brazylii, Indonezji, Singapurze, Tajlandii; od 2027 wszędzie) | Rejestracja jako zweryfikowany twórca przed 2027. Inaczej zostaje „zaawansowana ścieżka” (opcje programisty, restart, 24 h czekania) i ADB; Zen na PC ma „Zainstaluj na telefonie” przez USB. Telefony bez usług Google tego nie mają |
| 3 | iPhone | Najsłabszy punkt (§26.3) |
| 4 | Aktualizacje bez sklepu | Aktualizacje przez sieć od znajomego do znajomego; zawsze zgoda człowieka (zatwierdzanie: niżej) |
| 5 | Blokada sieci | połączenia wprost między znajomymi, ruch jak HTTPS (TLS na 443), mosty od znajomych bez centralnej listy; później Tor i siatka Bluetooth/Wi-Fi Direct |
| 6 | Blokada strony z pobraniem | Strony nie ma — jest README repozytorium. Lustra repozytorium (np. Codeberg) i „Podaj dalej” działają bez niego |
| 7 | Nacisk na autora | Jawny kod; licencja pozwala każdemu budować z niezmienionego kodu i rozpowszechniać kopie z tym samym SHA-256; brak wyłącznika (brak serwera); kanarek (plan). **Słabość:** jeden klucz podpisu jednej osoby i zakaz forków (`STAN.md`) |
| 8 | Ściganie użytkowników | Kamuflaż (plan: inna ikona i nazwa, wejście przez PIN), hasło paniki, pseudonimy, ruch jak HTTPS. Aplikacja utrudnia wykrycie, nie daje ochrony prawnej |
| 9 | Nacisk na liderów piramidy | Pseudonimy, zastępowanie nieobecnych (§20.4), 8 z 15 skarbników |
| 10 | Oznaczenie jako „szkodliwa” (Play Protect) | Jawny kod, sprawdzalne sumy (§14.3); ADB zawsze działa |

**Stan: Częściowo.**
- **„Podaj dalej”** (Zrobione): lokalny hotspot Androida albo ta sama sieć
  Wi-Fi + kod QR, plik pobiera zwykła przeglądarka (jeden plik, losowy
  adres, 20 min); systemowe udostępnianie APK (Quick Share, Bluetooth) przez
  `FileProvider`. Wejścia: Zaproś („Znajomy nie ma Zen?”), O aplikacji,
  Aktualizacje. Brak porównania podpisu instalatora (§14.3).
- **Jeden kod QR dla wszystkich** (Zrobione): link do README repozytorium
  z kodem po `#`. Bez Zen trafia się na README („zainstaluj, potem zeskanuj
  ten sam kod w aplikacji”); skaner Zen dodaje znajomego od razu.
- **PC → telefon przez USB** (Zrobione): `adb` z Android SDK (aplikacja go
  znajduje, nie dołącza). Przy `INSTALL_FAILED_UPDATE_INCOMPATIBLE` radzi
  dziś odinstalowanie — do zmiany (§14.3).
- **Ruch jak HTTPS** (Zrobione): mosty proszą router o port 443.
- **Aktualizacje przez sieć** (przesyłanie zrobione, wyłączone): pliki jako
  bloby dziennika (podmiana wykrywana), 7 dni od pierwszego zobaczenia,
  wstrzymanie, zawsze zgoda człowieka. Zatwierdzanie podpisami 2 z 3
  opiekunów jest w kodzie, ale lista kluczy jest pusta.
- **Do zrobienia:** kamuflaż i kanarek (S–M), lustra (S), Tor, Wi-Fi
  Direct, siatka Bluetooth (L), instrukcje instalacji z obrazkami (Android
  z zaawansowaną ścieżką 2027, Windows SmartScreen) (S).

#### Otwarta decyzja: kto zatwierdza nowe wersje

Ograniczenie Androida: zainstalowaną aplikację aktualizuje tylko wersja
podpisana tym samym kluczem APK, a nowa wersja przejmuje wszystkie dane
starej. Klucz, którego nikt nie ma, to koniec aktualizacji; klucz jawny
pozwala każdemu podrobić aktualizację, która przejmie dane — dlatego
**pomysł jawnego klucza w repozytorium odpada**. Opiekunów z osobnymi
kluczami (2 z 3) też nie chcemy.

**Propozycja (do decyzji):**

1. Jeden klucz podpisu APK autora, z **kopią podzieloną Shamirem między
   3–5 zaufanych osób** (nigdy publicznie) i rotacją przez APK Signature
   Scheme v3, gdyby trzeba go było zmienić.
2. **Aktualizacja przez sieć przyjmowana**, gdy: ten sam certyfikat podpisu
   co zainstalowana aplikacja + wyższy `versionCode` + 7 dni od pierwszego
   zobaczenia + zgoda człowieka. To zastępuje pustą listę opiekunów.
3. Później: **poręczenia** ludzi, którzy zbudowali wersję ze źródeł
   (powtarzalne kompilacje), i ostrzeżenia z sieci, które wstrzymują
   propozycję.
4. Ciągłość: decyzja o licencji, gdyby autor zniknął (`STAN.md`).

Windows nie ma ochrony podpisem jak Android: potrzebny Authenticode
(§14.3).

### 14.3 Integralność oficjalnych wydań i zbiórki

**Stan: Do zrobienia** (S–M). Problem: licencja pozwala rozdawać kopie, a
przerobiona kopia może podmienić link do zbiórki albo szpiegować. Zen ma
sam rozpoznawać oficjalne wydanie.

1. **Przypięty odcisk certyfikatu** (SHA-256) oficjalnego klucza podpisu
   w aplikacji (S).
2. **Samosprawdzenie** przy starcie i w „O aplikacji”: zgodny podpis —
   „Oficjalna kopia” z zaznaczeniem; niezgodny — odcisk certyfikatu i
   czerwone ostrzeżenie (S).
3. **Wszędzie, gdzie Zen dotyka pliku APK** („Podaj dalej”, udostępnianie,
   ADB, aktualizacje): sprawdzenie podpisu i sumy przed wysłaniem albo
   instalacją. Przy niezgodności czerwone ostrzeżenie „Podpis/suma
   kontrolna się nie zgadza — to nie jest oficjalny Zen (link do zbiórki
   mógł zostać podmieniony)” z przyciskiem „Zainstaluj mimo to”. Przy
   instalacji od znajomego oba telefony porównują odcisk. ADB nie radzi
   odinstalowania przy niezgodnym podpisie (S).
4. **Publikacja** odcisku certyfikatu i pliku `SHA256SUMS` w README i w opisie
   każdego wydania (S, `WYDANIA.md`).
5. **Na żądanie** porównanie sumy z `SHA256SUMS` pobranym z GitHuba (tylko
   po kliknięciu, bez stałego łączenia z serwerem) (S).
6. **Podpisany „manifest zbiórki”**: link do zbiórki podpisany kluczem
   autora, sprawdzany przed pokazaniem (S).
7. Później: **wzajemna weryfikacja między telefonami** (Android key
   attestation: telefon znajomego potwierdza, że druga strona działa na
   oficjalnym APK) (M).
8. **Windows:** podpis Authenticode (np. SignPath dla projektów otwartych
   albo Azure Trusted Signing) i sumy jak wyżej (S/M).

Uczciwie: przerobiona kopia może wyciąć samosprawdzenie u siebie; ochronę
dają kroki 3 i 7 — sprawdza zawsze ktoś inny niż podejrzany plik.

---

# CZĘŚĆ IV — SPOTKANIA I OKOLICA (etapy 6–7)

## 15. Osoby w pobliżu (Bluetooth)

- Telefon rozgłasza przez BLE **anonimowy identyfikator zmieniający się co
  ~15 min** (HMAC sekretu, który dostają tylko znajomi).
- Lista „Osoby w pobliżu”: obcy bez imienia i zdjęcia, z losowym
  pseudonimem, odległością (blisko / w pokoju / dalej) i odznakami.
  **Znajomi** rozpoznają cię wspólnym sekretem i widzą imię.
- **Napisz** do obcego: przywitanie przez Bluetooth, dalej zwykła sieć,
  bez zdradzania konta. 1 wiadomość od nieznajomego, dopóki nie odpiszesz;
  blokady; od jednego adresu najwyżej 3 rozmowy, w sumie 50.
- Zastosowania: „spotkani osobiście”, zakładanie komórek piramidy,
  sąsiedzi (§18), alarm do pobliża (§16.3).

**Stan: Częściowo** (Android, BLE bez dodatkowych bibliotek). Działa:
rozgłaszanie, lista, pseudonimy, „Napisz”, „Zaproś do znajomych” z pieczątką
„spotkani osobiście”, blokowanie, automatyczne „spotkani osobiście” dla
znajomych w zasięgu, nowy sekret po usunięciu znajomego. Widoczność
(rozgłaszanie, `ADVERTISE_MODE_LOW_POWER`) włącza ekran uprawnień przy
pierwszym starcie i działa stale, także w usłudze w tle, i wraca sama po
ponownym włączeniu Bluetooth; skanowanie tylko przy otwartym ekranie
„W pobliżu” („rozglądanie w tle” domyślnie wyłączone). Fala alarmu jest
podpisana (§16.3). Przycisk na belce.

Braki i plan:
- **Bezpieczeństwo (M):** osobny sekret dla każdego znajomego zamiast
  jednego wspólnego (dziś znajomy może udawać przed innymi twoją obecność
  i podpisać falę alarmu w twoim imieniu); zmiana tokenu zsynchronizowana
  z rotacją adresu MAC; przywitanie nie powinno ujawniać stałego adresu.
- Windows i iPhone: brak Bluetooth (M). Android 10–11: skanowanie w tle
  wymaga zgody na położenie w tle. Przywitania od obcych docierają tylko
  przy działającej aplikacji. Zakładanie komórek przez Bluetooth (§20).

## 16. Graf, statusy, alarm

### 16.1 Graf

Interaktywna mapa twojej sieci: ty w środku, pierścienie przyjaciół,
znajomych i słabych znajomych, dalej mniejsze kropki znajomych znajomych
(z list, które ktoś ci udostępnił, §9); kolory statusów (§16.2), grubość
linii = poziom. Dotknięcie osoby: profil, wspólni znajomi, akcje. Dane grafu
to zwykłe wpisy (listy znajomych z widocznością), bez centralnego indeksu.

**Stan: Zrobione** (1.10.0). Pierścienie, kolory statusów, wspólni
znajomi, linie między znajomymi, którzy się znają; wyszukiwanie (także bez
polskich znaków), filtry (znajomi, znajomi znajomych, piramida, status,
w pobliżu — tylko te, dla których są dane), najkrótsza droga „skąd znam X”,
„Poproś o przedstawienie”, „Napisz list”, „Zapytaj o opinię” (§24.1),
diagnostyka „Listy znajomych: od X z Y znajomych” z prośbą o listę; graf
jest pierwszy na belce. Listy znajomych znajomych dochodzą pewnie: ramki od
jeszcze-nie-znajomych czekają, skrót listy jedzie w ping/pong, a brakująca
lista jest zamawiana ponownie.

**Do zrobienia:** przybliżanie i klastry przy dużych sieciach (M).

### 16.2 Statusy

| Status | Znaczenie | Domyślnie widzą |
|---|---|---|
| Pilnie potrzebuję pomocy | dziś, teraz; głośniejsze powiadomienie, bez położenia (to nie alarm) | znajomi i przyjaciele |
| Potrzebuję pomocy | przeprowadzka, rada, zakupy | znajomi i przyjaciele |
| Mogę pomóc | mam czas, auto, narzędzia | znajomi i przyjaciele |
| Chcę pogadać | jestem wolny, napisz | znajomi i przyjaciele |
| Chcę wyjść | kto idzie na piwo | znajomi i przyjaciele |
| Idę na spacer | dołącz | znajomi i przyjaciele |
| Chcę coś zjeść razem | obiad, pizza | znajomi i przyjaciele |
| Chcę pograć | planszówki, piłka | znajomi i przyjaciele |
| Randkuję | otwarty na randki (§19) | wg ustawień randek |
| Nie przeszkadzać | — | wszyscy znajomi |
| Własny status | własne słowa (do 40 znaków) i emoji z 12 | znajomi i przyjaciele |
| **ALARM** | pilnie potrzebuję pomocy | przyjaciele + pobliże (§16.3) |

Status ma ważność (1 h / do końca dnia / do odwołania), dopisek i opcję
„tylko przyjaciele”.

**Stan: Zrobione** (przebudowa w 1.10.0). „Twój status” to wyróżniona
karta na górze z paskiem czasu do zgaśnięcia, „Zmień” i „Wyłącz”; statusy
znajomych pogrupowane według rodzaju, z awatarem, emoji, tekstem i czasem
do końca.

**Propozycja przebudowy (M):** jedno pytanie „Na co masz ochotę?” z trzema
grupami (Pomoc · Spotkanie · Nie przeszkadzać) zamiast długiej listy; status
z miejscem i godziną („Spacer — park, 18:00”) i przyciskiem „Dołączam” u
znajomych; aktywne statusy znajomych na górze czatów i na grafie;
automatyczne zgaśnięcie pokazane paskiem czasu.

### 16.3 Alarm

- Duży przycisk (przytrzymanie 3 s) albo skrót 5× przycisk zasilania.
- Idzie od razu do **przyjaciół** (bez przyjaciół: do wszystkich znajomych),
  przebija „nie przeszkadzać” i dzwoni jak połączenie, na pełnym ekranie.
- Zawiera **położenie** (odświeżane co minutę) i opcjonalnie nagranie
  dźwięku. Opcjonalnie fala Bluetooth do pobliża (anonimowo: „ktoś obok
  potrzebuje pomocy”).
- Odbiorcy widzą, kto reaguje („Jadę / Dzwonię / Nie mogę”). Nadawca widzi
  przy każdym odbiorcy: wysłany → doręczony → zobaczył → odpowiedź.
- „Jestem bezpieczny” wymaga PIN-u. **PIN paniczny** gasi alarm na ekranie,
  a w tle wysyła „może być zmuszony”. Pomyłka niczego nie zmienia.
- Kilka fałszywych alarmów to sprawa między ludźmi. Alarm nie zastępuje
  112 — jest przycisk „Zadzwoń na 112”.

**Stan: Częściowo.** Zrobione: przycisk, kanał alarmowy, położenie,
odpowiedzi, dwa PIN-y, 112, działanie w tle (usługa Androida); nagranie
dźwięku (opcja, kawałki po 20 s, do 6); alarm do pobliża (opcja; fala niesie
zmienny identyfikator „W pobliżu”, znajomi widzą kto, obcy — „ktoś w
pobliżu”; odbiór też przy zamkniętej aplikacji; każda fala dzwoni raz);
skrót 5× zasilanie (opcja, wymaga PIN-ów, wibracja długo–krótko–długo);
**potwierdzenia** `alarm_ack` („got” od razu, „seen” po otwarciu), przyjmowane
tylko od tych, do których alarm poszedł; po ~60 s „Nie dotarło do: …”
z „Wyślij jeszcze raz” i radą, by zadzwonić.

Braki:
- Fala Bluetooth jest podpisana (wersja 5, HMAC-SHA256 sekretem
  „W pobliżu”, ±10 min, bez powtórek; 1.10.0): dzwoni tylko sprawdzony
  alarm znajomego, obcy dają cichą notkę „Niesprawdzone…”. Zostaje: wspólny
  sekret dla wszystkich znajomych (§15).
- Położenie w tle (usługa typu `location` i zgoda) — dziś alarm ze skrótu
  przy zamkniętej aplikacji idzie bez nagrania i zwykle bez świeżego
  położenia (M).
- Zapasowy SMS przez systemowe okno, bez uprawnień SMS (S).
- Po restarcie telefonu z hasłem skrót i odbiór fal działają po pierwszym
  odblokowaniu Zen. Ten sam gest włącza na wielu telefonach systemowe SOS.
- Alarm nie powinien zależeć od zapisu dużego stanu „Spotkań” (`STAN.md`).

## 17. Życie po znajomości

Prawdziwe spotkania ludzi połączonych przez kogoś, komu ufają. Jeden
mechanizm (**wydarzenie po znajomości**) obsługuje wszystko poniżej.

**Stan: Zrobione** (wydarzenia, +1, bilety, album, kółka, Stół na sześć,
Zapytaj sieć). Szczegóły i braki niżej.

### 17.1 Wydarzenie po znajomości (mechanizm wspólny)

- **Zasięg:** przyjaciele / znajomi / znajomi znajomych / 2 kroki / wybrane
  osoby. Zaproszenie przechodzi dalej samo, z łańcuchem „kto kogo
  przyprowadził”.
- Lista gości pokazuje, kogo znasz („Będzie 14 osób, znasz 5”).
- **Bilet**: podpisane zaproszenie sprawdzane QR-em przy drzwiach, bez
  internetu, raz. **Przypięty do telefonu**: „Będę” wysyła organizatorowi
  klucz (Ed25519) tylko tego telefonu, a przy drzwiach telefon pokazuje żywy
  kod (podpis z bieżącym czasem, odświeżany co 20 s; skaner przyjmuje ±90 s
  i raz). Zrzut ekranu przestaje działać po ~1,5 min.
- **Po wydarzeniu:** wspólny album tylko dla uczestników (zdjęcia bez
  EXIF/GPS, znika z wydarzeniem po miesiącu), „Poznaliśmy się” (zaproszenie
  + pieczątka), karty wdzięczności i napiwek dla gospodarza (walutą
  piramidy, gdy obie osoby są w tej samej).

Braki: przypięcie nie chroni przed oddaniem telefonu ani pokazywaniem kodu
na żywo przez wideo; zegar gościa może się mylić najwyżej o ~minutę.
Zaproszenie bierze się tylko od znajomego (kto nie zna organizatora,
dostaje je przez ręczącego znajomego). Bezpieczniki odbiorcy: od jednego
znajomego 30 zaproszeń na dobę; zdjęcia ponad 4096 px / 16 Mpx odpadają.

### 17.2 Imprezy po znajomości i „+1 za zgodą”

- „Chcę przyprowadzić Olę” — organizator akceptuje albo odrzuca; zaufanym
  może dać „+N bez pytania”.
- Impreza „otwarta po znajomości”: limit miejsc i zasięg, widoczna tylko
  w zasięgu.
- **Przyprowadzający ręczy** za swoją osobę (historia wydarzeń organizatora,
  bez ocen) — do zrobienia (S).

### 17.3 Kółko obiadowe (rotacyjne wspólne obiady)

- Kółko 4–8 osób albo par; kolejka gospodarzy, „Zamień się” za zgodą,
  preferencje i alergie, „kto co przynosi”.
- **Kółko otwarte:** raz w miesiącu każdy może przyprowadzić jedną osobę
  spoza kółka.
- Obiad u nieznajomego po znajomości (kilka miejsc dla znajomych znajomych).
- **Wspólna kasa na składniki** — do zrobienia (S).

### 17.4 Stół na sześć (kolacja znajomych znajomych)

Przy stole siedzą ludzie oddaleni o 2 kroki znajomości: każdy zna kogoś,
kto zna gospodarza.

1. Raz włączasz „Chcę na Stół na sześć” z miastem i dniami; informacja idzie
   do znajomych i znajomych znajomych.
2. Gospodarz zakłada stół; jego aplikacja sama zaprasza 5 osób z zasięgu,
   połączonych z nim przez różnych znajomych i jak najmniej znających się
   nawzajem.
3. Przed kolacją każdy widzi ścieżki „przez kogo”, po kolacji „spotkani
   osobiście” jednym dotknięciem.

Technicznie zwykłe wydarzenie z automatycznym zapraszaniem. Każda kolacja
to nowe „spotkani osobiście” i zaczyn przyszłych komórek.

### 17.5 Zapytaj sieć (zamiast bazy poleceń)

1. Pytanie („Znacie dentystę w Gdańsku?”) do znajomych.
2. Każdy odpowiada albo ręcznie **przekazuje dalej** (najwyżej 2 kroki).
3. Odpowiedzi wracają tą samą drogą, podpisane, ze ścieżką („znajomy
   Bartka: …”). Pytanie gaśnie po 7 dniach.

Jeden mechanizm na polecenia, fachowców, pożyczki, pracę, podwózki.
Bezpiecznik odbiorcy: od jednego znajomego najwyżej 20 pytań na dobę (z
przekazanymi), 50 odpowiedzi na pytanie. Napiwek walutą za odpowiedź (§24)
— zrobione.

### 17.6 Plan na weekend

**Stan: Zrobione** (1.10.0, „Spotkania → Plan na weekend”). Czwarta forma
obok wydarzeń, kółek i Stołu na sześć, najlżejsza z nich:

- Wrzucasz luźny plan: „Sobota: rower nad Wisłą, 10:00, kto chętny?”, z
  zasięgiem (przyjaciele / znajomi / znajomi znajomych).
- Znajomi odpowiadają „Dołączam” albo „Może”; widać, kto już jest i przez
  kogo jest połączony.
- Gdy zbierze się próg chętnych (np. 3), plan sam zamienia się w wydarzenie
  (§17.1) z czatem; bez progu gaśnie po terminie.
- Działa na gotowych klockach (status + wydarzenie + zasięg w krokach).

Wariant: **„Wspólna sprawa”** (zbiórka sąsiedzka, sprzątanie podwórka,
pomoc sąsiadowi): lista tego, co potrzebne (ludzie, terminy, rzeczy), i kto
co deklaruje; bez pieniędzy.

## 18. Sekcja sąsiedzka

### 18.1 Profil mieszkania

- Profil należy do **rodziny / grupy, która teraz mieszka** w mieszkaniu
  („Nowakowie · m. 12”), nie do samego mieszkania. Dowolnie wielu
  domowników; kolejni dołączają, skanując kod domownika **w środku**
  mieszkania. Każdy domownik może edytować i odpisywać.
- **Przeprowadzka:** rodzina zabiera profil, kod na starych drzwiach
  przestaje działać, sąsiedzi dostają informację. Nowi lokatorzy zakładają
  własny profil od zera.
- Oddzielny od profili głównych (własny klucz). Domownik może sam „Pokaż mój
  profil” wybranemu mieszkaniu.
- Zawartość: zaproszenia (data, miejsca, zapisy), „Oferujemy”,
  „Potrzebujemy”, „O nas”, jedno małe zdjęcie.

### 18.2 QR na drzwiach

- Naklejka A6 (PNG 300 dpi): QR + nazwa + własne hasło („Zeskanuj —
  zapraszamy na kawę!”). Kod zawiera adres i klucz mieszkania, nie konta.
- „Nowy kod” unieważnia stary (kto zeskanuje stary, widzi „nieważny”).
- Kod ma postać `zen-flat:…` i działa bez strony. Aplikacja rozumie też
  link `https://<domena>/m#<kod>`. Strony nie ma (jedyną stroną jest README
  repozytorium); do decyzji, czy kod na drzwiach ma prowadzić do README jak
  zaproszenia (§14.2) (S).

### 18.3 Moi sąsiedzi

- Zeskanowanie drzwi wysyła nasz profil i przynosi ich; oba mieszkania mają
  się na liście. Nowości od mieszkań, które sami zeskanowaliśmy, przychodzą
  zawsze; od tych, które zeskanowały nas — po „Dodaj”.
- Wiadomości między mieszkaniami (odpisuje dowolny domownik, widać kto),
  zapisy z pilnowaniem miejsc, wyciszanie, usuwanie.
- **Zaproszenie w pobliżu:** przez Bluetooth do telefonów z Zen w zasięgu
  („Mieszkanie 12: grill w sobotę”), jednym dotknięciem do sąsiadów.
- Świadomie bez „wspólnoty budynku” — nie ma kto moderować.

**Stan: Zrobione** („Sąsiedzi” na belce). Wszystko podpisane kluczami
mieszkań, ruch bezpośredni z ponawianiem. **Usunięcie domownika, który nie
chce odejść:** głosuje większość pozostałych; mieszkanie dostaje nowy klucz
i kod bez tego telefonu. Każdy telefon domownika ma własny klucz Ed25519,
który sąsiedzi zapamiętują; głosy i komunikat o nowym kluczu są nim
podpisane i sprawdzane kluczami znanymi od co najmniej doby. Dwa różne nowe
klucze nie rozstrzygają się „kto pierwszy”: sąsiad widzi ostrzeżenie
„zapytaj sąsiadów osobiście”, a skan nowego kodu z drzwi rozstrzyga.

Braki: strona `/m` i „kod w schowku” po instalacji (S); czat wydarzenia przy
zaproszeniu (S/M); zaproszenia w pobliżu na komputerze (brak Bluetooth);
wiadomości, gdy żaden telefon domownika długo nie jest w sieci. Granice: w
mieszkaniu dwóch osób obie wersje nowego klucza są „poprawne” (zostaje
ostrzeżenie i skan drzwi); domownik, który z wyprzedzeniem podsunie profil
z wymyślonymi telefonami, może przegłosować resztę w oczach sąsiadów.

---

# CZĘŚĆ V — RANDKI (etap 8)

## 19. Randki przez znajomych

**Idea:** randkujesz z ludźmi w odległości do 3 kroków znajomości, zawsze
z kimś wspólnym, kogo można zapytać.

**Stan: Zrobione** („Randki” na belce), ale rozsyłanie nie skaluje się
(§19.7).

### 19.1 Profil randkowy

- Włączany świadomie (domyślnie wyłączony), deklaracja wieku 18+ bez
  dokumentów; niepełnoletnich można zgłosić (§19.6).
- Oddzielny, budowany z profilu głównego jednym dotknięciem: imię, wiek,
  płeć, „o mnie”, „czego szukam”, do 4 zdjęć, preferencje (płeć, wiek, 1–3
  kroki). Dopasowanie obustronne.
- **Nikt nie wie, kto randkuje:** każda aplikacja ma klucz randkowy
  (X25519) i co tydzień wysyła znajomym paczkę — profil albo przykrywkę
  podobnej wielkości (dopełnienie do wielokrotności 4 KB). Każdy przekazuje paczki dalej,
  do 3 kroków, dopisując się do ścieżki; telefon bez randek ich nie otwiera
  i nie zapisuje. Paczka jest zaszyfrowana kluczem tej paczki, który każdy
  dostaje na prośbę drogą powrotną — ruch wygląda u wszystkich tak samo.
- **Wykluczenia:** ukrywanie przed wybranymi znajomymi i całymi grupami
  czatu (solone skróty adresów w profilu).
- Wyłączenie randek: profil przestaje się rozchodzić i znika u innych po
  ~2 tygodniach.

### 19.2 Ślepe polubienia (nikt nie dowie się o nieodwzajemnionym)

„Tak” wysyła żeton liczony przez obie strony z ich kluczy (HMAC z X25519);
„Nie” nie wysyła nic, więc wygląda jak brak decyzji. Para powstaje przy
„Tak” + „Tak” i obie strony wiedzą to od razu.

### 19.3 Wspólni znajomi — rewolucja randek

- Na każdym profilu ścieżka: „Znacie się przez: Bob → Kasia”.
- **„Zapytaj o opinię”** znajomego, od którego przyszedł profil (aplikacja
  uprzedza, że dowie się, że randkujesz).
- **Swatanie:** znajomy przedstawia dwie osoby z notatką (także zbyt daleko,
  by się widziały); „Podziękuj swatowi” walutą piramidy.
- **Poręczenia:** podpisane (Ed25519) kilka słów od znajomego na profilu;
  podpis obejmuje klucz randkowy, imię, tekst i czas.
- Wiadomości zwrotne (polubienia, rozmowy par, przedstawienia) wracają
  krok po kroku drogą paczki, w dwóch warstwach szyfrowania; telefony po
  drodze nie znają nawet klucza nadawcy.

### 19.4 Bezpieczeństwo randki

- **„Idę na randkę”:** wybrany przyjaciel dostaje notatkę i położenie (co 10
  min i na żądanie). Po czasie przypomnienie, 15 min później alarm
  u przyjaciela i zwykły alarm (§16.3) u ciebie. „+1 h”, „Wszystko OK”.
  Terminy liczy też usługa w tle.
- Blokowanie osoby; zgłoszenia (§19.6).

Uczciwie: klucz paczki dostaje każdy w zasięgu, kto poprosi — przerobiona
aplikacja widzi profile w zasięgu i jednostronne „Tak”. Rozmiar paczki
zdradza przedział. Od znajomego najwyżej 100 nowych paczek na dobę, ponad
512 KB nie idą dalej.

### 19.5 Przeglądanie kart (jak w Tinderze)

**Stan: Zrobione** (1.10.0). „Swatuj” korzysta z dzisiejszego
przedstawienia profilu randkowego (tylko do znanego profilu), a „Zapytaj
o opinię” pyta znajomego, od którego profil przyszedł.
- Profile jako stos kart: przesunięcie w prawo = „Tak”, w lewo = „Nie”
  (bez zmian w §19.2 — „Nie” dalej nic nie wysyła).
- Jedna z „fotek” to **karta tekstowa** opisująca osobę (o mnie, czego
  szukam, ścieżka znajomości, poręczenia), przesuwana jak zdjęcia.
- Na karcie przyciski **„Swataj”** (przedstaw tę osobę komuś innemu)
  i **„Zapytaj znajomego o opinię”**.

### 19.6 Zgłoszenia i ban randkowy

**Stan: Zrobione.** „Zgłoś” przy profilu randkowym; w piramidzie zgłoszenie
trafia do delegata od zgłoszeń albo na szczyt (§21.4), a ban randkowy
aplikacja stosuje w Randkach (profil znika, paczki nie są przyjmowane). Bez
piramidy zostaje własna blokada. Zgłoszenie osoby niepełnoletniej wyłącza
jej profil randkowy.

### 19.7 Skala rozsyłania

**Do zrobienia (L).** Ruch rośnie jak trzecia potęga liczby znajomych
(`dating_service.dart`): co tydzień paczka 8–52 KB od każdego, przekazywana
do 3 kroków; przy ~150 znajomych to dziesiątki tysięcy paczek tygodniowo na
telefon. Plan: małe **latarnie** (~100 B: klucz randkowy, przedział
preferencji, ścieżka) rozsyłane do **2 kroków**, a profil pobierany tylko
na żądanie, gdy latarnia pasuje. Zachować „nikt nie wie, kto randkuje”
(latarnie-przykrywki).

---

# CZĘŚĆ VI — WSPÓLNOTA (etapy 9–11)

Etapy 9–11 są zaimplementowane („Piramida” i „Portfel” na belce); używanie
zacznie się po audycie, analizie prawnej i gdy będzie społeczność. Do
wydania: za flagą funkcji (§2.5). Stan i braki: koniec §24.

## 20. Piramida

### 20.1 Kształt

```
                ┌──────── SZCZYT: komórka {S, A, B} ────────┐
                │ S = szef piramidy; S, A, B mają równą     │
                │ władzę (decyzje 2 z 3)                     │
                └──────────────┬──────────────┬──────────────┘
                   komórka A: {A, A1, A2}   komórka B: {B, B1, B2}
                        /         \
     komórka A1: {A1, A11, A12}   komórka A2: {A2, A21, A22}
```

- **Komórka = trójka:** szef + 2 członków. Każdy z członków zakłada swoją
  komórkę niżej i jest w niej szefem, więc każdy (poza szczytem i dołem)
  jest w dwóch komórkach.
- **Szczyt:** szef piramidy S + A, B, równa władza, decyzje 2 z 3.
- Każdy poziom podwaja liczbę ludzi: 25 poziomów to ok. 67 mln osób.

### 20.2 Dołączenie

- Tylko przez znajomego z wolnym miejscem (mniej niż 2 osoby pod nim).
- Wymóg: spotkanie osobiście (QR szefa komórki) i poziom co najmniej
  „Znajomy”.
- Nowa osoba i szef komórki podpisują przyjęcie; nowa osoba dostaje
  poświadczenie członka (§6.2). **Kto przyjmuje, ten poręcza** (§21.5).
- W piramidzie występujesz jako tożsamość piramidowa (pseudonim, §6.4).

### 20.2a Dane podstawowe potwierdzone przy wejściu

- Przy wejściu podajesz rok urodzenia, narodowość i płeć; przyjmujący
  (spotkanie osobiście) podpisuje, że to prawda, i za to ręczy.
- Dane obowiązują bez zmian, dopóki jesteś w piramidzie; poprawka = wyjście
  i wejście od dołu. Dzięki temu nikt po latach awansu nie „zmieni”
  narodowości, żeby przejąć sekcję innego kraju.
- Narodowość widoczna przy pseudonimie (sekcje krajowe); wiek i płeć tylko
  w anonimowych statystykach i jako odznaka, którą pokazujesz sam.
  Publikowany jest tylko skrót z solą.

### 20.3 Zmiana szefa: oddolnie, komórka po komórce

**W każdej komórce 2 z 3 mogą zamienić szefa z jednym z członków; zamiana
to wymiana miejsc dwóch osób.**

Przykład: w komórce A = {A, A1, A2} A1 i A2 podpisują „A1 zostaje szefem”.
A1 wchodzi na miejsce A w komórce wyżej, A schodzi i prowadzi dawną komórkę
A1. Nikt nie wypada, gałęzie zostają.

Tak samo poziom po poziomie aż do szczytu, gdzie zamiana szefa piramidy
zaczyna **nową kadencję** (§23). Awans wymaga poparcia na każdym poziomie;
szczyt nie zamknie drogi na górę. Bez limitów czasowych. Każda zamiana to
publiczny, podpisany wpis.

### 20.3a Anonimowe żądanie nowego głosowania

1. Każdy członek komórki może anonimowo zażądać głosowania — **podpis
   pierścieniowy** (LSAG na Ed25519) dowodzi, że to ktoś z komórki, nie
   mówi kto. Wysyła go znajomy.
2. Głosują wszyscy trzej, też pierścieniowo; widać, że każdy zagłosował raz,
   nie widać na kogo.
3. Wygrywa osoba z co najmniej 2 głosami (zamiana jak w §20.3); remis 1:1:1
   albo jeden głos — szef zostaje. Czas: 72 h.

W trójce tajność jest ograniczona; aplikacja publikuje tylko zwycięzcę, bez
liczby głosów. Podpis jest łączliwy („ta sama osoba żąda już 5. raz”), więc
nękanie widać bez blokad z góry.

### 20.4 Migracja i nieobecność

- **Migracja** do komórki z wolnym miejscem, za zgodą jej szefa. Komórka pod
  tobą zostaje, a jej członkowie (2 z 3) wskazują, kto zajmie twoje miejsce;
  za zgodą całej komórki przenosisz się z całą gałęzią.
- **Nieobecność:** po 60 dniach bez znaku życia dwoje pozostałych uznaje
  miejsce za wolne (gdy został jeden — on; gdy nikt — szef komórki wyżej).
  „Żyję” co 7 dni z aplikacji.
- **Wystąpienie** w każdej chwili. Usunąć kogoś może tylko jego komórka.

### 20.5 Która piramida jest prawdziwa

- Nie ma klucza wbudowanego w aplikację, więc piramid może być wiele.
  Aplikacja uznaje tę, w której jesteś (a bez członkostwa — tę z największą
  liczbą twoich znajomych). Kto jest w dwóch, widzi tę, do której dołączył
  ostatnio.
- Piramida z fałszywych kont nie zawiera twoich ludzi.
- **Łączenie:** szczyt mniejszej (2 z 3) i osoba z wolnym miejscem
  w większej podpisują; cała struktura wchodzi jako gałąź, stara jest
  zamykana.
- **Pieniądze przy łączeniu** (1.10.0): szczyt dołączającej proponuje kurs
  (np. 100 → 80) albo „bez przeliczania”. Salda w chwili połączenia są
  przeliczane po kursie; dla przyjmującej to nowe pieniądze, więc działa
  jak emisja: 2 z 3 jej szczytu, limit 30 dni, doba czekania, weto.
  Przelewy w starej piramidzie po chwili przeliczenia przestają się liczyć.
- **Wymiana między piramidami („kantor”):** osoba będąca w obu ogłasza kurs
  i limit; płacący blokuje pieniądze kluczem znanym tylko jemu i odbiorcy,
  kantor wypłaca odbiorcy w jego piramidzie zablokowane tym samym kluczem;
  gdy odbiorca je bierze, klucz staje się jawny i dopiero wtedy kantor bierze
  zapłatę. Bez wypłaty pieniądze wracają do płacącego po 3 dniach.
- Liczy się tylko to, co wynika z podpisów; każdy klient sprawdza łańcuch
  od swojej komórki do szczytu.

### 20.6 Dlaczego fałszywe konta nie przejmą piramidy

Fałszywe konta tworzą komórki tylko pod tym, kto je wprowadził; wyżej
potrzebują 2 z 3 w komórkach prawdziwych ludzi. Spotkanie osobiste przy
każdym przyjęciu kosztuje czas. Do tego zgłoszenia i kary (§21.5), a
referenda można liczyć tylko z członków ze „spotkani osobiście” od co
najmniej 2 osób.

## 21. Władza, delegacje, bany, zgłoszenia, referenda

### 21.1 Uprawnienia szczytu (szef piramidy + 2 członków, równa władza, decyzje 2 z 3)

| Uprawnienie | Delegowalne? | Opis |
|---|---|---|
| Emisja waluty | nie, tylko szczyt | §23 |
| Posty polityczne | każda komórka dla swojej gałęzi | §22 |
| Ban stały | tak | konto nieprzyjmowane nigdzie w piramidzie |
| Przerwa (ban czasowy) | tak | 24 h / 7 dni / 30 dni |
| Ban treści | tak | skrót posta lub pliku |
| Ban randkowy, zakaz przyjmowania | tak | §19.6, §21.5 |
| Przyjmowanie zgłoszeń | tak | §21.4 |
| Referendum / ankieta | tak | cała piramida lub gałąź |
| Ogłoszenia alarmowe | tak | komunikat kryzysowy (§28) |
| Łączenie piramid | nie | §20.5 |

### 21.1a Immunitet w piramidzie

Szczyt nie może banować każdego, kto się do niego zbliża:
- ban nigdy nie odbiera miejsca w piramidzie ani głosu w komórce (wyłącza
  tylko funkcje społeczne);
- usunąć z piramidy może tylko własna komórka;
- bany osób z 3 najwyższych poziomów wymagają zgody ich komórki.

### 21.2 Delegacje

- Delegacja: `{komu, uprawnienie, zakres (piramida / gałąź), limit na
  miesiąc, do kiedy, czy dalej}`, podpisana 2 z 3 szczytu. Limit liczony
  w całym łańcuchu; dalsze delegowanie tylko węższe; ważna, póki delegat jest
  w piramidzie.
- Każdy klient sprawdza łańcuch delegacji. Cofnięcie unieważnia wszystko,
  co z niej wynikało. Akty delegatów są publiczne; szczyt może je uchylić.

### 21.3 Referenda

- Ogłasza szczyt, delegat albo prowadzący sekcję krajową; głos idzie do
  szefa własnej komórki.
- **Wyniki liczone drzewem:** każda komórka podpisuje sumę swojej gałęzi
  (suma dzieci + własna komórka) i przekazuje w górę.
- Głos tajny wobec wszystkich poza własną komórką.
- **Twarde minimum w kodzie:** referendum co najmniej 1 h, konstytucyjne
  72 h; sumy dopiero po końcu; szef musi włączyć najnowszą sumę każdej gałęzi
  (bez niej liczy po 6 h), każdą raz; liczby ograniczone wielkością gałęzi.

### 21.4 Zgłoszenia

- „Zgłoś” przy poście, komentarzu, profilu, wiadomości (także w grupach),
  profilu randkowym. Powody: nielegalna treść, fałszywe konto, farma kont,
  nękanie, oszustwo, spam, inne. Zgłoszoną treść można od razu ukryć u siebie.
- Zgłoszenie zawiera dowód (podpisane wpisy). Trafia do delegata od
  zgłoszeń w gałęzi, po 48 h bez decyzji wyżej, aż do szczytu.
- Decyzja (ban, przerwa, ban treści, „bez naruszenia”) jest publiczna,
  zgłaszający anonimowy dla zgłoszonego. Odwołanie raz.
- Bez piramidy nie ma władzy: zostaje blokada i „Usuń z mojego urządzenia”.

### 21.5 Fałszywe konta i farmy

- Zgłoszenie „farma kont” wskazuje osobę, która wprowadza fałszywe konta.
  Sygnały: wiele kont w krótkim czasie, brak wspólnych znajomych poza nią,
  brak spotkań, identyczne zachowanie. Aplikacja ma je podpowiadać
  delegatowi z grafu (do zrobienia, M).
- Kary: ban kont, przerwa lub ban dla wprowadzającego, utrata prawa
  poręczania i przyjmowania, opcjonalnie cofnięcie przelewów udowodnionych
  jako oszustwo (jawna decyzja skarbników).

### 21.6 Granice władzy szczytu (podsumowanie)

Szczyt **może:** emitować walutę (jawnie), banować (z immunitetem §21.1a),
delegować, pisać do całej piramidy, ogłaszać referenda. **Nie może:**
usuwać ludzi z piramidy, blokować awansów, wybierać skarbników, zmieniać
przeszłych wpisów, ukryć emisji.

### 21.7 Konstytucja w kodzie

Zasady piramidy (2 z 3, immunitet, limit emisji, reguły sekcji krajowych)
są w jednym, wersjonowanym dokumencie w aplikacji. Zmienia je tylko
**referendum konstytucyjne** całej piramidy: co najmniej 72 h, frekwencja
ponad połowy członków, pełna suma (każda gałąź), „Tak” więcej niż wszystkie
inne odpowiedzi razem; potem akt szczytu, nie wcześniej niż 6 h po końcu.
Tych minimów nie zmieniają same zasady.

## 22. Sekcja polityczna i sekcja krajowa

### 22.1 Posty polityczne

- Każdy szef komórki (i szczyt) pisze do swojej gałęzi, bez limitu postów.
- Kolejność: szczyt, potem twoja linia w górę od najwyższego, w obrębie
  poziomu od najnowszych. Post niesie podpisany poziom autora z chwili
  publikacji.
- Pod postami komentarze gałęzi (zagregowane drzewem). Posty nie wychodzą
  poza gałąź, chyba że ktoś je udostępni publicznie.

### 22.1a Liczby: skąd co pochodzi

| Liczba | Znaczenie | Skąd |
|---|---|---|
| Poziom X z Y | odległość od szczytu / głębokość piramidy | łańcuch komórek (podpisy) |
| N poziomów nad tobą | jak daleko w twojej linii jest autor | twój łańcuch komórek |
| Gałąź N osób | ilu ludzi jest pod autorem | sumy liczone drzewem |
| Dotarło / przeczytało | ilu w gałęzi ma post / otworzyło | anonimowe sumy drzewem |
| Twoja pozycja | „Poziom 7 · gałąź 124 os. · od 14 mies.” | jw. |

Mapa piramidy: twoja linia do szczytu z liczbami. Zawyżenie sumy przez
komórkę wychodzi przy porównaniu z podpisanymi sumami dwóch komórek niżej
i jest jawnym dowodem. Poziomy w interfejsie liczone od 1.

### 22.1b Jak posty polityczne docierają

Głównie drzewem piramidy, ale też zwykłą synchronizacją między członkami,
którzy się znają (szef długo offline nie odcina gałęzi). Każdy sprawdza
podpis i prawo autora do pisania do jego gałęzi.

### 22.2 Sekcja krajowa

Posty z priorytetem pisze **najwyżej postawiona osoba danej (potwierdzonej
przy wejściu) narodowości**, bez tytułu — widać tylko flagę, poziom i gałąź.

- Bezpiecznik: w jej gałęzi co najmniej ~100 osób tej narodowości. Remis na
  poziomie: większa liczba osób tej narodowości. Bez kandydata sekcja działa
  bez priorytetu. Zmienia się razem z piramidą.
- Widzą ją wszyscy z tą narodowością w profilu (komentują członkowie
  piramidy). Kolejność: prowadzący, potem członkowie wg poziomu.
- Prowadzący: priorytet i przypinanie, nadawanie prawa priorytetowego
  pisania (z terminem), referenda i ogłoszenia krajowe. Nie może banować,
  emitować ani zmieniać piramidy.

### 22.3 Bez partii

Aplikacja **nie ma partii** (decyzja 14.10.2026): piramida sama jest
oddolną reprezentacją, a partie z kontami i zarządami wnosiły ryzyko prawne
(finansowanie polityki, §27) i rozbijały wspólnotę na obozy. Kto chce
założyć partię, robi to poza aplikacją.

## 23. Waluta (wersja prosta)

**Bankiem jest góra piramidy:** jedna księga sald prowadzona przez
najwyższych w piramidzie.

### 23.1 Kto jest kim

| Rola | Kto | Co robi |
|---|---|---|
| Emisja | szczyt (2 z 3) | nowe pieniądze na wskazane konto, z uzasadnieniem |
| Skarbnicy | 3 najwyższe poziomy = 15 osób | zatwierdzają przelewy, prowadzą księgę |

Skarbnikiem jest się z miejsca w piramidzie, bez wyborów.

### 23.2 Przelew krok po kroku

1. Janek podpisuje (hasłem konta) zlecenie `{od, do, kwota, numer kolejny}`.
2. Każdy skarbnik sprawdza saldo i kolejny numer, podpisuje i zapisuje.
3. Przelew ważny przy podpisach większości skarbników (8 z 15).
4. Skarbnicy synchronizują księgę między sobą.

Dwa różne zlecenia z tym samym numerem nie zdobędą obu większości, bo
uczciwy skarbnik podpisuje jedno. Zlecenie z większością, któremu zabrakło
środków, zużywa numer.

### 23.3 Kadencje

Emisja jest oznaczona kadencją; saldo rozbite na kadencje, przelew wydaje
najpierw najstarsze (FIFO).

### 23.4 Zabezpieczenia (tylko to, co konieczne)

| Zagrożenie | Blokada |
|---|---|
| Podwójne wydanie | numer kolejny + większość skarbników |
| Złodziej telefonu | przelew wymaga hasła konta |
| Kradzież kluczy szczytu → dodruk | emisja ważna po 24 h, jawna, trzeci członek szczytu może zawetować; limit na kroczące 30 dni (większa emisja — referendum); spóźniona emisja czeka u skarbników jeszcze 24 h |
| Część skarbników offline | 8 z 15 wystarcza |
| DDoS skarbników | zlecenia tylko od członków, z limitem; adresy za relayami |
| Skarbnik oszukuje | dwa sprzeczne podpisy to jawny dowód, oddolna zamiana |

Świadome uproszczenia: skarbnicy widzą przelewy (prywatność później, L);
bez internetu nie ma przelewu; zmowa większości z 15 mogłaby oszukiwać.
Skarbnik podpisuje tylko zlecenia nie starsze niż tydzień i nie
z przyszłości.

### 23.5 Na co waluta

Rynek dostępu (§24), swatanie (§19.3), napiwki, zbiórki, przelewy między
ludźmi. **Płatności warunkowe:** skarbnicy księgują przelew po podpisie
warunku (np. akceptacji odbiorcy), zwrot po terminie.

## 24. Rynek dostępu

Twoja sieć ma wartość; możesz ją udostępniać za darmo albo za walutę, na
swoich warunkach.

| Usługa | Jak działa | Ochrona |
|---|---|---|
| Przedstawienie | X płaci F, żeby przedstawił go Y; F może odrzucić, Y decyduje | płatność warunkowa po akceptacji Y |
| Płatna skrzynka | Y ustala cenę wiadomości od nieznajomych | spam się nie opłaca; Y może zwrócić |
| Reshare na zamówienie | X płaci F za udostępnienie posta | F akceptuje treść (podgląd), płatność po udostępnieniu |
| Ogłoszenie w sieci | X płaci za rozesłanie do N kroków | akceptacja i udział na każdym kroku |
| Napiwek za odpowiedź | w „Zapytaj sieć” | dobrowolny |
| Otwarty dostęp (za darmo) | F daje X prawo do swojej listy znajomych, przedstawień, pisania do znajomych | cofasz w każdej chwili |

Cennik w profilu: każda usługa osobno, cena zależna od poziomu znajomości
(znajomi / znajomi znajomych / obcy).

### 24.1 Ekonomia kontaktów

**Stan: Zrobione bez pieniędzy** (1.10.0) — walutą jest zgoda:
1. „Kto widzi moją listę znajomych”: wszyscy znajomi / tylko na prośbę /
   nikt; prośby zatwierdza się w Skrzynce, zgodę cofa w Grafie;
2. przedstawienie: X prosi F, F przekazuje ze swoim słowem (albo nie),
   Y decyduje; po „tak” oboje dostają zwykłe zaproszenie do znajomych,
   a odmowy X nie widzi;
3. list przez wspólnego znajomego: jedna wiadomość do nieznajomego,
   najwyżej 3 tygodniowo przez jedną osobę (pośrednik przekazuje najwyżej
   10 tygodniowo); odbiorca może tylko zaprosić do znajomych albo
   zignorować;
4. „Poproś o przedstawienie”, „Napisz list” i „Zapytaj o opinię” na
   grafie.

W jednej piramidzie pośrednik może dodatkowo wycenić przedstawienie na jej
rynku (§24). Waluty poza piramidą nie ma — ryzyko: punkty, za które kupuje
się dostęp do ludzi, mogą być usługą płatniczą / pieniądzem elektronicznym
(KNF, AML, §27) i zamieniają znajomych w towar.

### Stan wdrożenia etapów 9–11 (V1.10)

**Zrobione w kodzie.** Zakładka „Piramida” (Ja / Polityka / Kraj /
Głosowania / Portfel / Władza / Historia), portfel ma też własny przycisk
na belce.

- **Rekordy podpisane, stan liczony u każdego:** rekord podpisany Ed25519
  przez tych, których wymaga zasada; każdy telefon składa stan sam w tej
  samej kolejności (czas, id); rekordy łamiące zasady odrzucają wszyscy.
  Synchronizacja tylko między znajomymi (skróty kubełków hello / ids / want,
  także po rozcięciu sieci; skrót obejmuje podpisy). Telefon przyjmuje
  rekordy tylko swoich piramid, nic więcej niż 10 min w przyszłość, każdy
  podpis sprawdzony; zły rekord nie zatrzymuje składania. Rekordy w
  dzienniku dopisywanym segmentami; sprawdzone podpisy pierścieniowe
  zapamiętywane na dysku, pierwsze sprawdzenie w tle.
- **Czas rekordu:** propozycja podpisana później niż 10 min po utworzeniu
  idzie jako świeża kopia; przy podpisywaniu widać czas i pola decydujące
  o skutku. Twarde zabezpieczenia tam, gdzie antydatowanie dawało władzę
  (zamknięcie piramidy tylko przez dzisiejszy szczyt, cofnięcie delegacji
  wymienia znane akty, rozliczenia płatności warunkowych podpisują
  skarbnicy, spóźniona emisja czeka).
- **Propozycje do podpisania** kończą się, gdy rekord spełnia zasadę
  (próbne złożenie stanu), więc złożone wymagania nie wychodzą w połowie.
- Zrobione wszystkie mechanizmy §20–24 opisane wyżej, w tym: anonimowe
  głosowania, migracja z gałęzią, łączenie piramid, delegacje z limitem
  w łańcuchu, immunitet do głębokości 3, zgłoszenia, referenda drzewem,
  konstytucja, sekcja krajowa, waluta z wetem,
  płatności warunkowe, ceny wg poziomu, ogłoszenie łańcuchem do 5
  pośredników (udział równy na każdym kroku, skrót treści blokuje podmianę),
  napiwek w „Zapytaj sieć”.
- **Tryb kryzysowy** (§28): alarm szczytu, delegata albo sekcji z zasięgiem,
  fala Bluetooth (podpisana, wersja 3) także do telefonów spoza piramidy
  („niesprawdzony”); dalej idzie tylko fala ważna w piramidzie odbiorcy.
- **Testy:** podpisy pierścieniowe sprawdzone niezależnie (Python), ponad 20
  scenariuszy w symulatorze (także chaos), skrypt do prawdziwych aplikacji
  (`TESTOWANIE.md`).

**Braki:** flagi funkcji (S); ruch piramidy przez relaye i ukrycie adresu
urządzenia (M/L); klucz piramidy z klucza konta (S/M); przyjmowanie
`report` i `appeal` od każdego bez limitów i podpisu (wysokie, `STAN.md`);
liczenie od zera co 60 s w wątku interfejsu i wszystkie rekordy u każdego
członka (M–L: punkty kontrolne, liczenie przyrostowe w tle, telefon trzyma
swoją gałąź); prywatność przelewów (L); przelewy rozchodzą się do wszystkich
członków, a §23 mówi o skarbnikach.

**Uczciwie:** to kod przed audytem. Kryptografia pierścieniowa jest własną
implementacją (BigInt, sprawdzona niezależnie, nieaudytowana, wolna;
pierścień to 2–3 klucze). Znajomy, który przekazuje głos, widzi, że coś
wysłałeś. Bez wspólnego zegara nie da się udowodnić antydatowania: zmowa
wszystkich wymaganych podpisów może cofnąć datę rekordu (widać to
w historii); trzeci członek szczytu może zawetować emisję spóźnionym wetem;
spóźniony głos może zmienić wynik wstecz; gdy porzucone zlecenie podpisała
dokładnie połowa skarbników, konto czeka na dokończenie; skład dołączanej
piramidy poświadcza jej szczyt. Ogłoszenie idzie łańcuchem, nie drzewem;
klucz piramidy w odpowiedzi na pytanie to deklaracja odpowiadającego.

---

# CZĘŚĆ VII — CAŁOŚĆ

## 25. Nawigacja aplikacji

Pionowa belka po lewej (same ikony na telefonie, szersza na komputerze).

**Stan: Częściowo.** Kolejność dziś: **Graf → Profil → Czaty → Tablica →
Spotkania → Randki → Sąsiedzi → Piramida → Portfel → Osoby w pobliżu →
Zaproś → O aplikacji → Alarm** (czerwony, na dole) oraz „Zablokuj teraz”
(gdy jest hasło). Aplikacja startuje na Czatach. Przyciski same się zwężają,
więc 13 zakładek z blokadą mieści się na ekranie 360×568. Belkę można
schować (przycisk albo przesunięcie; aplikacja to pamięta).

- U góry pasek stanu połączenia; dotknięcie otwiera ustawienia (bez
  osobnej zakładki). Każda sekcja ma ten sam nagłówek (`ZenSectionBar`).
- Tablica: posty znajomych i obserwowanych (własne na profilu); karta „Co
  słychać?” otwiera pełnoekranowy edytor (odbiorcy, do 4 zdjęć, Ctrl+Enter).
- Domyślny motyw systemowy; w jasnym motywie logo jest czarne. 27 kolorów
  akcentu.
- „O aplikacji”: najpierw zbiórka, potem czym jest Zen (także piramida
  i oddolna polityka), po co, jak używać, prywatność (krąg odzyskiwania),
  platformy, Yggdrasil, dlaczego nie ma w sklepach, jak sprawdzić, że to nie
  wirus, oficjalny link do GitHuba, na końcu licencje. Tam też „Podaj dalej”.

**Do zrobienia (S):** pogrupować 13 zakładek (np. Ludzie: graf, czaty,
tablica, profil · Spotkania: na teraz, w pobliżu, wydarzenia, randki ·
Okolica: sąsiedzi · Wspólnota: piramida, portfel), żeby belka nie wyglądała
jak kokpit.

### 25.1 Języki i tłumaczenia

**Do zrobienia (M, potem S na każdy język).** Dziś wszystkie teksty są po
polsku, wpisane w kod.
1. Wyciągnąć teksty do plików ARB (`flutter_localizations`, `intl`), także
   teksty usługi w tle, powiadomień i kanałów Androida.
2. Pierwszy język: **angielski**.
3. **Wybór języka w ustawieniach** (Wygląd): „Jak w systemie” (domyślnie)
   albo konkretny język; zmiana bez restartu.
4. Formaty dat, liczb i kwot wg języka; teksty bez sklejania słów (liczba
   mnoga przez ICU).
5. Test, że każdy klucz ma tłumaczenie w każdym języku.

### 25.2 Ekran uprawnień

**Stan: Zrobione** (1.10.0; brakuje położenia w tle dla alarmu i dokładnych
alarmów). Jeden ekran przy pierwszym uruchomieniu (po haśle) i w
ustawieniach, z wyjaśnieniem po co i stanem każdego uprawnienia:
powiadomienia; Bluetooth / urządzenia w pobliżu; położenie (dla alarmu,
także w tle); aparat i mikrofon; wyłączenie optymalizacji baterii (z
instrukcją dla Xiaomi, Samsunga i innych); powiadomienia pełnoekranowe;
dokładne alarmy. Brak zgody nie blokuje aplikacji — mówi, co nie zadziała.

### 25.3 Wygląd — pomysły

**Propozycje (S–M):**
- Znak „ZEN” z logo też w nagłówku panelu i na ekranie blokady.
- Animacje stanów: miękkie pojawianie się kart, puls statusów na grafie,
  potwierdzenie wysłania (haptyka).
- Ilustracje pustych ekranów w stylu logo zamiast samych ikon.
- Zdjęcia w centrum: większe awatary, okładki wydarzeń, zdjęcia mieszkań.
- Dostępność: etykiety dla czytnika ekranu (przycisk alarmu i graf nie mają
  opisu).
- Przebudowa statusów (§16.2).

## 26. Luki i ryzyka

### 26.1 Luki bezpieczeństwa i polityczne

| # | Luka | Ryzyko | Co robimy |
|---|---|---|---|
| 1 | Lista IP mostów = lista użytkowników PC; most zdradza, czyj to komputer | państwo zbiera ogłoszenia i ustala abonentów | anonimowy klucz w ogłoszeniu; wyłącznik w ustawieniach; do rozważenia: osobny klucz nasłuchu, w krajach z zakazem most tylko dla znajomych |
| 2 | Przejmowanie piramidy przez zatrzymania | zatrzymany zna swoje 2 komórki | minimum danych (twarze i pseudonimy), hasło paniki, wymiana nieobecnych |
| 3 | Graf piramidy widoczny w piramidzie | analiza struktury + IP łączy pseudonimy z ludźmi | ruch piramidy przez relaye, ukrycie adresu urządzenia (§6.4) |
| 4 | Podrobiony instalator | podana dalej kopia ze szpiegiem albo podmienioną zbiórką | §14.3; Android blokuje aktualizację innym kluczem |
| 5 | Zatwierdzanie wydań | wersja z furtką jako aktualizacja | §14.2 „Otwarta decyzja”, 7 dni przed aktywacją |
| 6 | Skarbnicy widzą przelewy | przejęcie telefonu skarbnika = historia finansowa pseudonimów | pseudonimy, kasowanie starych przelewów, hasło paniki; prywatność przelewów później |
| 7 | Brak moderacji przed piramidą | nielegalne treści w udostępnieniach i u pośredników | „Usuń z urządzenia” z blokadą skrótu (M); przycisk z instrukcją dla organów ścigania; opcjonalna lista skrótów od wybranej organizacji |
| 8 | Nieletni | sieć dla < 16 lat wymaga zgody rodzica (RODO) | bramka wieku przy pierwszym uruchomieniu; poniżej 16 tryb ograniczony (S) |
| 9 | Państwowa „wielka piramida” | dezinformacja o sile ruchu | każdy widzi prawomocność swojej piramidy; liczby sprawdzalne w gałęzi |
| 10 | Infiltracja | przejęcie struktury od środka | odwołanie zamianą, jawność aktów, immunitet |
| 11 | Opóźniona aktualizacja Yggdrasil | znane błędy | przegląd co kwartał (§5.2) |
| 12 | Jedna implementacja | błąd aplikacji = błąd całej sieci | otwarty protokół (§28), audyt przed walutą i piramidą |

### 26.2 Ryzyka projektu

| Ryzyko | Co robimy |
|---|---|
| Pusta sieć na starcie | start w jednym środowisku (blok, uczelnia, miasto), wąski klin wejścia (sąsiedzi albo spotkania), prosta pętla: dodaj znajomego → napisz → umówcie się → spotkajcie się |
| iPhone | §26.3 |
| Skala Yggdrasil (projekt eksperymentalny) | silnik nie zależy od Yggdrasil; test obciążeniowy przed piramidą |
| Bateria i transfer | telefon nie jest mostem, synchronizacja paczkami, media „tylko Wi-Fi”, skanowanie BT tylko przy otwartym ekranie (§15) |
| Rozmiar projektu, rozrost funkcji | wydanie „rdzeń” za flagami (§2.5) |
| Jeden opiekun | jawny kod, ten dokument, protokół (§28), kopia klucza (§14.2); decyzja o licencji i fundacji (`STAN.md`) |

### 26.3 iPhone, Mac, Linux — opcje

**Stan iPhone'a: wybrana droga AltStore / SideStore z darmowym Apple ID**
(1.10.0). GitHub Actions z macOS buduje niepodpisany `Zen-unsigned.ipa`
z mostem Go jako biblioteką statyczną; podpisuje go instalator. Bez pracy
w tle, Bluetooth i push (§13.4); instrukcja w README. Drogi dystrybucji:

| Droga | Zalety | Wady |
|---|---|---|
| App Store / TestFlight | zwykła instalacja dla wszystkich | przegląd Apple (może odrzucić lub usunąć), konto deweloperskie, push przez APNs |
| Alternatywne sklepy w UE (np. AltStore PAL) | bez przeglądu treści App Store | notaryzacja Apple i konto deweloperskie, tylko UE |
| AltStore / SideStore z darmowym Apple ID | bez przeglądu Apple, działa na całym świecie | podpis co 7 dni, najwyżej 3 aplikacje, komputer do pierwszej instalacji |

Wcześniej (taniej): **macOS i Linux** (M) — Flutter i most Go już to
umożliwiają; brakuje budowania, Bluetooth i nagrywania rozmów. Awaryjnie:
tryb gościa w przeglądarce przez telefon lub komputer znajomego (L).

## 27. Prawo (do konsultacji z prawnikiem — nie jestem prawnikiem)

- **Waluta i ekonomia kontaktów:** środki wymienialne na towary lub usługi
  mogą podlegać przepisom o pieniądzu elektronicznym i usługach płatniczych
  (KNF), AML, ewentualnie MiCA. Bezpieczna ścieżka na start: niewymienialne
  „punkty wdzięczności” albo wersja bez pieniędzy (§24.1).
- **Polityka:** aplikacja nie ma partii ani kont partyjnych (§22.3), więc
  waluta nie finansuje partii. Obcokrajowcy w piramidzie a kampanie — do
  analizy. Ciszy wyborczej aplikacja nie wymusi.
- **Randki:** 18+ to deklaracja (świadomie); potrzebny regulamin i szybkie
  zgłaszanie niepełnoletnich.
- **Nielegalne treści:** brak operatora nie zwalnia z ryzyka; zasady,
  zgłoszenia, „Usuń z mojego urządzenia”.
- **RODO:** autor może być uznany za współadministratora; „prawo do
  usunięcia” kłóci się z podpisanymi łańcuchami i kopiami u znajomych.
  Piramida (poglądy polityczne) i randki (życie intymne) to dane szczególne
  (art. 9): minimalizacja, szyfrowanie, pseudonimy, wyraźna zgoda.
  **Do zrobienia (S):** polityka prywatności, regulamin, ocena skutków
  (DPIA), bramka wieku (zgoda rodzica poniżej 16 lat).
- **Alarm** nie zastępuje 112 — trzeba to jasno komunikować.
- **„Piramida” a zakaz piramid finansowych:** wejście zawsze za darmo,
  żadnych nagród za wprowadzanie ludzi, emisja niezależna od wielkości
  gałęzi. Rozważyć inną nazwę w interfejsie („Struktura”, „Wspólnota”,
  „Rada”).
- **DSA:** bez operatora obowiązki są niejasne; bezpieczniej mieć fundację
  z regulaminem i kanałem zgłoszeń dla organów ścigania.

## 28. Pomysły na później

1. **Tryb kryzysowy bez internetu:** komunikat kryzysowy szczytu lub
   delegata idzie falą Bluetooth od telefonu do telefonu (zrobione dla
   ogłoszeń kryzysowych); pełna siatka Bluetooth/Wi-Fi Direct dla zwykłych
   wiadomości — do zrobienia (L).
2. **Otwarty protokół:** opublikowana specyfikacja formatów wpisów i ramek
   (M), żeby inni mogli pisać zgodne aplikacje.
3. **Mapa zaufania do osoby** na grafie: ile spotkań osobistych, kart
   wdzięczności, jak długo w piramidzie — bez gwiazdek (S).
4. **Wzrost przez spotkania:** „twoja gałąź urosła o 12 osób w tym
   tygodniu”, zaproszenia do komórki tylko na żywo.
5. **Zaproszenie przez wydarzenie:** link do wydarzenia jako sposób na
   zaproszenie kogoś bez Zen.

## 29. Asystent AI na urządzeniu — usunięty (V1.9)

W V1.8–V1.9 była zakładka „Asystent” (model językowy na urządzeniu,
llamadart; ocena wiadomości przed wysłaniem, ostrzeżenia, tłumaczenia,
tamagotchi, Notatnik). Usunięta w V1.9, bo model potrafił zawiesić system.
Przy starcie aplikacja kasuje pozostałości (`assistant_leftovers.dart`;
do usunięcia przed wydaniem, §2.5). Powrót tylko z planem, który nie
obciąża urządzenia.
