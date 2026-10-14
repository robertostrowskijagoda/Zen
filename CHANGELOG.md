# Zmiany

## 1.10.0 — 14.10.2026 (pierwsze publiczne wydanie)

### Przed wydaniem: bezpieczeństwo, waluta, iPhone
- **Pierwsze uruchomienie:** po haśle ekran „Uprawnienia i Bluetooth” —
  po kolei powiadomienia, Bluetooth (na Androidzie 11 i starszym
  z lokalizacją), włączenie Bluetooth, alarm na pełnym ekranie, praca
  w tle, opcjonalnie mikrofon i aparat; na koniec telefon staje się
  widoczny w pobliżu. Ten sam ekran jest w Ustawieniach. Koniec z serią
  okienek systemowych przy każdym starcie.
- **Bluetooth:** przy włączonej widoczności telefon nadaje stale
  i oszczędnie (także z usługi w tle) i wraca sam po wyłączeniu i włączeniu
  Bluetooth. Szukanie tylko na ekranie „W pobliżu” (rozglądanie się w tle
  domyślnie wyłączone); naprawiony skan z „Sąsiadów”, który się nie
  wyłączał.
- **Znajomi znajomych (B1, B2):** listy znajomych w osobnych plikach,
  z limitami; ramki od kogoś, kto jeszcze nie jest znajomym, czekają na
  akceptację; ping/pong niosą skróty listy, klucza „W pobliżu” i statusu,
  a to, co zginęło po drodze, jest zamawiane ponownie; lista idzie raz,
  tylko po zmianie.
- **Graf:** wyszukiwanie (także bez polskich znaków), filtry (znajomi,
  znajomi znajomych, piramida, status, w pobliżu), najkrótsza droga do
  osoby, linie między znajomymi, którzy się znają, i „Listy znajomych: od
  X z Y znajomych” z przyciskiem „Poproś”.
- **Ekonomia kontaktów bez piramidy — walutą jest zgoda:** „Kto widzi moją
  listę znajomych” (wszyscy znajomi / tylko na prośbę / nikt, zgoda
  w Skrzynce, cofana w Grafie); „Poproś o przedstawienie” (wspólny znajomy
  przekazuje albo odmawia, druga osoba decyduje, po „tak” oboje dostajecie
  zwykłe zaproszenie); „Napisz list” przez wspólnego znajomego (najwyżej
  3 tygodniowo przez jedną osobę); „Zapytaj o opinię”. W jednej piramidzie
  pośrednik może dodatkowo wycenić przedstawienie na jej rynku.
- **Piramida:** bez partii (usunięte zakładanie partii i prawybory).
  Zgłoszenia i odwołania tylko od członków, z limitami i w osobnym zapisie
  (S1); podpisu skarbnika nie da się zastąpić ani usunąć (S12); limity dla
  propozycji i wiadomości rynku.
- **Waluta:** kwoty i salda z twardymi limitami (10^15 setnych na kwotę,
  2^60 na saldo), sumy nasycają się zamiast przekręcać 64 bity; ponowne
  potwierdzenie (hasło albo biometria) przed każdym wysłaniem pieniędzy;
  blokada zrzutów ekranu w portfelu; uczciwy opis pustego portfela;
  wszystkie pola kwot w setnych (także napiwek i podziękowanie swatowi).
- **Pieniądze z różnych piramid:** przy łączeniu salda przechodzą po
  uzgodnionym kursie (jak emisja: 2 z 3 szczytu, limit 30 dni, doba
  czekania, weto); wymiana przez „kantor” — osobę z obu piramid — z obiema
  płatnościami zablokowanymi tym samym kluczem i zwrotem, gdy wymiana się
  nie uda.
- **Alarm przez Bluetooth podpisany (S2):** HMAC-SHA256 sekretem
  „W pobliżu”, ważny ±10 min, powtórki odrzucane; dzwoni tylko sprawdzony
  alarm znajomego, reszta to cicha notka „Niesprawdzone…”. Alarm wychodzi
  przed zapisem stanu (B10), z limitami pól i liczby alarmów.
- **Załączniki, głosówki i zdjęcia znajomych zaszyfrowane na dysku (S3)**,
  pod losowymi nazwami; zdjęcia odszyfrowywane tylko w pamięci, nagrania
  i filmy w krótkotrwałej kopii.
- **Magazyny tylko w aktualnej kopercie (S4):** jawnego pliku nie da się
  podłożyć; konfiguracja węzła i pamięć sprawdzonych podpisów chronione.
- **Hasło paniki kasuje wszystko (S7):** najpierw zatrzymuje usługę w tle,
  potem cache, pliki tymczasowe, `Android/data/…/files`, foldery Zen
  w Dokumentach i Pobranych oraz zapisane kopie.
- **Podpis APK (S9):** „Podaj dalej” i ADB sprawdzają certyfikat przed
  wysłaniem i instalacją; ADB nie radzi już odinstalowania przy innym
  podpisie, tylko ostrzega przed podróbką.
- **Stare formaty zaproszeń usunięte (S14);** działa kod, link z kodem po
  `#` i `zen://c/KOD`.
- **Bez kodu zgodności:** przed wydaniem usunięto obsługę starszych formatów
  i wersji protokołu (łączenie urządzeń tylko z zobowiązaniem, randki tylko
  z zapieczętowanymi paczkami i podpisanymi poręczeniami, bilety zawsze
  przypięte, podpisane głosy w „Sąsiadach”, stara koperta magazynu, stare
  hasło PBKDF2, jednorazowe porządki). Zostaje jedno: przepieczętowanie
  konfiguracji węzła, żeby nie zmienił się adres.
- **Płynność (B3, B5):** obecność w pamięci, zapis z opóźnieniem, ekrany
  obserwują tylko to, co pokazują, graf przerysowuje się tylko po zmianie.
- **Nazwa znajomego zawsze z jego najnowszego profilu.**
- **Randki jak w Tinderze:** stos kart, w prawo „Tak”, w lewo „Nie”;
  pierwsza „fotka” to opis osoby; „Swatuj” i „Zapytaj o opinię” na karcie.
- **Statusy od nowa:** wyróżniona karta „Twój status” z czasem do
  zgaśnięcia; statusy znajomych pogrupowane według rodzaju.
- **Plan na weekend** — czwarta forma w Spotkaniach: luźny plan z zasięgiem,
  „Dołączam” / „Może”, po zebraniu progu chętnych sam staje się
  wydarzeniem z czatem.
- **iPhone:** Zen działa na iOS (SideStore / AltStore z darmowym Apple ID);
  plik `Zen-unsigned.ipa` buduje GitHub Actions. Funkcje, na które iOS nie
  pozwala (praca w tle, Bluetooth w tle, alarm z przycisku), są oznaczone
  jako niedostępne.
- **Budowanie:** most Go buduje się sam przy `flutter build apk`
  / `flutter build windows` (tylko gdy zmieniły się źródła); gotowych
  bibliotek nie ma w repozytorium. GitHub Actions: testy przy każdym
  pushu, pliki wydania przy tagu, strona zaproszeń na Pages.
- **Licencje** modułów Go i fontów w „O aplikacji → Licencje”.
- **Strona zaproszeń** `robertostrowskijagoda.github.io/Zen/#KOD` otwiera
  Zen albo pokazuje pobieranie; zbiórka: **buycoffee.to/zen**; w „O
  aplikacji” kilka słów od autora.
- Pakiet Dart nazywa się `zen`, wersja **1.10.0 (10)**.


### Nazwy z profilu, bezpieczne media, nagrania w postach
- **Nazwa znajomego pochodzi z jego profilu** i nie da się jej zmienić
  (przychodzi z zaproszeniem, odpowiedzią i każdą zmianą profilu; nowsza
  wygrywa). Zamiast „Zmień nazwę” jest **pseudonim**: widoczny tylko u
  Ciebie, małą kursywą pod nazwą (lista rozmów, nagłówek rozmowy, profil),
  wspólny dla Twoich urządzeń. Przy dodawaniu znajomego nie ma już pola
  nazwy (jest opcjonalny pseudonim), akceptacja to jedno stuknięcie. Nazwy
  od innych są czyszczone ze znaków sterujących i zmieniających kierunek
  tekstu (podszywanie się) i przycinane do 60 znaków.
- **Ochrona przed wirusami w zdjęciach i filmach** (`media_guard.dart`):
  każde przychodzące zdjęcie (czat, posty, profile, randki) jest dekodowane
  czystym kodem Dart i kodowane od nowa, więc systemowy dekoder obrazów
  nigdy nie widzi oryginału (tak działały ataki w rodzaju dziury w WebP
  z 2023); zdjęcia „za duże, by były zdjęciem” są odrzucane przed
  dekodowaniem. Filmy i nagrania muszą mieć poprawny kontener (MP4/MOV/
  M4A/WebM/Ogg/MP3/WAV — pudełka nie wychodzą poza plik), inaczej stają się
  zwykłym plikiem, którego Zen nie odtwarza. Typ, MIME i nazwa pliku są
  ustalane z zawartości, nie z tego, co twierdzi nadawca. Plik, który
  mógłby uruchomić program (EXE, APK, skrypty, skróty, makra), dostaje
  ostrzeżenie przed „Zapisz kopię”; Zen nigdy nie otwiera plików sam.
  Zdjęcie z aparatu wysyłane w czacie traci położenie GPS (nowy JPEG).
- **Głosówki i nagrania audio w postach:** w edytorze „Nagraj głosówkę”
  i „Wstaw nagranie z pliku” (do 25 MB); w czacie nowa opcja „Nagranie
  audio z pliku”. Odtwarzanie dopiero po stuknięciu.
- **Repozytorium nazywa się `Zen`:** linki zaproszeń
  `https://github.com/robertostrowskijagoda/zen#KOD`.
- **Kody Zen prosto do aplikacji (Android):** Zen obsługuje linki do swojej
  strony na GitHubie; po włączeniu „Otwieraj obsługiwane linki” (Zaproś →
  „Kody Zen prosto do aplikacji”) kod zeskanowany zwykłym aparatem otwiera
  się od razu w Zen. Wyłączone wbudowane linki Fluttera (próbowały otwierać
  ścieżkę jako stronę aplikacji).
- **„O aplikacji” → Własny most Yggdrasil:** jak postawić stały węzeł bez
  Zen (komputer z publicznym IP, instalacja, `Listen`, zgłoszenie na listę
  publicznych węzłów), z linkami otwieranymi w przeglądarce.

### Ostatnia runda: wygoda, bezpieczeństwo, wydanie
- **Biometria domyślnie wyłączona.** Przy ustawianiu pierwszego hasła Zen
  raz pyta „Odblokowywać odciskiem lub twarzą?”; później włącza się ją
  w Ustawieniach → Bezpieczeństwo. Naprawione przy okazji: ekran pierwszego
  hasła nie mógł otworzyć żadnego okienka (ani tego pytania, ani „Bez
  hasła?”), bo stał nad nawigacją aplikacji. Naprawione 4 zepsute testy,
  dopisane nowe.
- **Domyślna blokada po 5 minutach w tle** (wcześniej tylko po restarcie
  telefonu). Teksty ekranu blokady mówią prawdę: usługa w tle dalej odbiera
  wiadomości.
- **Poprawka bezpieczeństwa:** nazwy plików załączników od innych są
  oczyszczane przy odbiorze i zapisie — wcześniej „Zapisz kopię” mogło
  nadpisać pliki w katalogu aplikacji (path traversal).
- **Ustawienia aplikacji zapisywane jako JSON z nazwanymi polami** zamiast
  dziesięciu wersji formatu binarnego; nieczytelny stary plik oznacza
  ustawienia domyślne.
- **Domyślny motyw: systemowy.** W jasnym motywie logo jest czarne (ekran
  startowy i „O aplikacji”).
- **Panel po lewej:** graf znajomych pierwszy; nowa zakładka „Portfel”
  przed Bluetooth; Bluetooth tuż przed „Zaproś”; nowa rysowana ikona
  piramidy (trójkąt z kółkami w rogach) i nowa ikona tablicy; „Zablokuj
  teraz” przeniesione z ustawień na panel (widoczne, gdy jest hasło).
  Przyciski same się zwężają, więc nawet mały telefon mieści wszystko
  (sprawdzone na 360×568: 13 zakładek i blokada).
- **Zaokrąglona ikona w zasobniku Windows** naprawdę używana (wcześniej
  zmieniona była tylko nieużywana ikona zapasowa); wydanie Windows
  przebudowane.
- **„Podaj dalej” łatwiej znaleźć:** w zakładce Zaproś („Znajomy nie ma
  Zen?”) i w „O aplikacji”.
- **„O aplikacji” od nowa:** najpierw zbiórka, potem czym jest Zen (także
  piramida i oddolna polityka), „Po co to jest” (z „Także nowa polityka”),
  jak używać, prywatność z kręgiem odzyskiwania (do 6 znajomych: hasło + 2
  z nich po 24 h albo 4 z nich bez hasła po 7 dniach), platformy (Android
  i Windows gotowe; macOS, Linux, iPhone w planie), Yggdrasil, dlaczego nie
  ma w sklepach, jak sprawdzić, że to nie wirus (jedno źródło,
  virustotal.com, skan Androida, jawny kod i ten sam klucz podpisu),
  oficjalny link do GitHuba, na końcu licencje.
- **Własny status wyraźnie oznaczony** („TWÓJ WŁASNY STATUS”, pigułka
  „Własny”).
- **Most na komputerze** zostaje domyślnie włączony, bez komunikatu dla
  użytkownika; przełącznik „Pomagaj innym się łączyć” na dole ustawień (Zaawansowane →
  Sieć i usługa).
- **Jeden kod QR dla wszystkich:** zaproszenie to link
  `https://github.com/robertostrowskijagoda/zen#KOD`. Kod
  jest po `#`, więc nie trafia na serwer. Aparat bez Zen otwiera README
  („zainstaluj, potem zeskanuj ten sam kod w aplikacji”), skaner w Zen
  dodaje znajomego od razu. Stare kody `zen://` dalej działają.
- **Pakiet Androida `com.roj.zen`** (był `com.HuraganKodu.zen`). To nowa
  aplikacja dla systemu: stara instalacja zostaje obok ze swoimi danymi.
- **Licencja** (`LICENSE`, Zen Source-Available License 1.0): wolno budować
  z niezmienionego kodu także dla innych osób i rozpowszechniać każdą kopię,
  której SHA-256 zgadza się z opublikowaną (z dowolnego źródła); własną
  kompilację można dać innym, ale nie publikować jako „Zen”.
- **README dla zwykłych ludzi** (strona repozytorium na GitHubie):
  pobieranie, co zrobić po zeskanowaniu kodu, instalacja (także ścieżka
  2027 dla niezweryfikowanego twórcy z 24 h czekania), Windows SmartScreen,
  sprawdzanie wirusów, dlaczego nie w sklepach, prywatność, Yggdrasil,
  zbiórka, licencja w skrócie, część dla programistów.
- **Porządki:** usunięte `zen-site/` i workflow GitHub Pages (nie ma
  osobnej strony), `screenshots/shots_test.dart`,
  `tool/ui_tour/ui_tour_test.dart` z `run.ps1` i nieużywane
  `assets/branding/logo_rounded.png`; cały kod sformatowany `dart format`.
- **Dokumentacja:** plan (`docs/PROJEKT_APLIKACJI.md`) zaktualizowany
  i skrócony; nowy `docs/STAN.md` (stan, znane błędy, bezpieczeństwo,
  kolejność prac) zamiast `KIERUNKI.md` i `AUDYT_BEZPIECZENSTWA.md`;
  `PUBLIKACJA.md` włączona do `docs/WYDANIA.md`.

### Po teście z telefonem
- **Więcej statusów „na teraz”:** Pilnie potrzebuję pomocy (głośniejsze
  powiadomienie u znajomych, osobny czerwony przycisk), Mogę pomóc, Idę na
  spacer, Chcę coś zjeść razem, Chcę pograć — oraz **własny status**
  (własne słowa i emoji). Statusy to zwarte „pigułki”, a nie duże kafle.
  Starsze wersje nowych statusów nie pokazują.
- **„Osoby w pobliżu” mają własny przycisk w panelu po lewej** (zniknęły ze
  Spotkań). Pełne skanowanie Bluetooth działa przy otwartym ekranie; poza
  nim krótkie rozejrzenie się co 5 minut (niżej: „Rozglądaj się też w tle”).
- **Alarm z potwierdzeniami:** telefon znajomego odsyła „dotarło”
  i „zobaczone”; na ekranie alarmu widać, do kogo dotarł, kto zobaczył i kto
  odpowiedział, z możliwością ponowienia.
- **Bez przepisywania całych plików:** rozmowy w segmentach po 200
  wiadomości, rekordy piramidy w dzienniku dopisywanym na końcu (stary zapis
  przenoszony automatycznie).
- **Mniej zawieszeń:** sprawdzone podpisy pierścieniowe piramidy są
  zapamiętywane na dysku, a pierwsze sprawdzenie idzie w tle.
- **Android nie ubija usługi po 6 godzinach** (Android 14+: typ usługi
  „specialUse” bez limitu czasu); gdy system ją jednak zatrzyma, przychodzi
  powiadomienie „Zen nie odbiera w tle — otwórz na chwilę”.
- **Udostępnianie aplikacji przez Quick Share / Bluetooth** (nowy przycisk
  w „Podaj dalej”).
- **Te same kolory w jasnym i ciemnym motywie** (wcześniej jasny miał
  ciemnoniebieski akcent zamiast fioletu); znak „ZEN” z logo na ekranie
  startowym.
- Kto należy do dwóch piramid, widzi tę, do której dołączył ostatnio
  (wcześniej telefon zostawał przy starej).
- **Tożsamość w sieci nie przepada przy uszkodzonym pliku**: konfiguracja
  węzła zapisywana atomowo i z kopią; wcześniej uszkodzony plik oznaczał
  nowy adres i utratę kontaktu ze znajomymi.
- Stan „Spotkań” z nieznanej (nowszej) wersji nie jest już nadpisywany
  pustym.

### Sieć niesie się sama: komputery są mostami (etap 2 dokończony)
- **Każdy komputer jest mostem** (§5.1; domyślnie włączone, wyłącznik
  w ustawieniach). Aplikacja na PC
  sama otwiera port w routerze (UPnP, a gdy go nie ma — NAT-PMP), prosi
  znajomych o sprawdzenie z zewnątrz, że naprawdę da się połączyć, i
  dopiero wtedy ogłasza most. Port i ogłoszenie są odnawiane co pół
  godziny; gdy komputer przestaje być osiągalny, ogłoszenie jest wycofywane,
  a port zamykany przy wyjściu z aplikacji.
- Komputer z publicznym adresem (bez routera albo z IPv6) też jest mostem.
  Węzeł na PC nasłuchuje teraz na IPv4 i IPv6 (`tls://[::]:32913`), także na
  Linuksie i macOS.
- **Stan mostu w Ustawieniach → Sieć i usługa**: działa / router nie
  otworzył portu / router odmówił (UPnP wyłączone) / brak publicznego
  adresu (CGNAT) / zapora blokuje / czekam na znajomego online, z
  przyciskiem „Sprawdź teraz” i podpowiedzią, co zrobić.
- Port przekierowany w routerze ręcznie też działa: gdy router nie otwiera
  portu, ale podaje swój adres, aplikacja i tak prosi znajomych o
  sprawdzenie `adres:32913`.
- **Sprawdzanie mostów**: zamiast samego połączenia TCP aplikacja czeka na
  powitanie węzła Yggdrasil, więc ogłoszenie wskazujące cudzy serwer odpada
  od razu. Mosty muszą mieć publiczny adres IP (żadnych nazw, żadnych sieci
  domowych), więc nikt nie wyśle aplikacji „do pukania” w urządzenia
  w Twojej sieci. Znajomy sprawdza za innych najwyżej 4 adresy na minutę.
- **Wybór mostów po szybkości i sieciach**: najszybsze działające mosty,
  rozłożone na różne bloki adresów (różni dostawcy). Działające są
  sprawdzane ponownie co 6 h, martwe dostają drugą szansę po dobie i znikają
  po trzech porażkach.

### Audyt bezpieczeństwa (`docs/STAN.md`)
- **Obcy nie zostanie już Twoim znajomym jednym pakietem** (`friend_accept`
  bez zaproszenia z Twojej strony trafia do zaproszeń do potwierdzenia).
- **Zablokowana aplikacja nie zrywa znajomości** i nie gubi zaproszeń:
  sygnał, który przyszedł przy zablokowanym Zen, trafiał na pusty jeszcze
  stan, więc znajomy wyglądał jak obcy i dostawał „usuń znajomość”. Teraz
  sygnały czekają, aż zapis zostanie odczytany po odblokowaniu.
- Dwie osoby, które zaprosiły się nawzajem w tej samej chwili, od razu
  zostają znajomymi (wcześniej akceptacja jednej strony przepadała).
- Ochrona przed zalewaniem i „bombami”: kompresja zstd, fragmenty sygnałów,
  zdjęcia i obrazy, załączniki, prośby o znajomość, zaproszenia do grup,
  wydarzenia, paczki randkowe, skrzynki offline, alarmy, pytania.
- Piramida: odporność na zły podpis pierścieniowy, podwójne głosy,
  cofanie dat, obejście weta i limitu emisji, zmianę konstytucji bez
  kworum; synchronizacja tylko ze znajomymi.
- Windows: klucz danych pieczętowany tylko po włączeniu Windows Hello.
- Hasła: zmiana wymaga potwierdzenia, hasło i hasło panic nie mogą być
  takie same; panic najpierw niszczy klucze.
- Łączenie urządzeń z zobowiązaniem (kod nie do „wygrindowania”); nazwy
  plików rozmów nie zdradzają kontaktów; zapis wiązany z kluczem pliku.
- Link nie odbierze już połączenia ani nie podmieni imienia rozmówcy;
  treść powiadomień ukryta też dla randek i piramidy.
- Android: brak kopii zapasowych danych, ekran połączenia niedostępny dla
  innych aplikacji, przygotowany własny klucz podpisu wydań
  (`android/key.properties`). „Podaj dalej” pokazuje SHA-256 pliku.
- Pilot testowy tylko w wersji debug; brak logów w logcat w wydaniu.

### Dopracowany wygląd (przegląd na 320–412 dp, tekst do 150%, jasny/ciemny, komputer)
- Graf znajomych przewija się razem z legendą i nie nachodzi na nic na
  małym ekranie; znajomi nie zasłaniają już środka („Ty”).
- Kafelki „Spotkań” i statusy „Na co masz ochotę” przechodzą w jedną
  kolumnę, zamiast łamać słowa w połowie.
- Na komputerze każdy ekran (także otwierane z menu i okna) trzyma ten
  sam wąski układ, zamiast rozciągać się na całe okno.
- Kwoty z odstępami tysięcy (1 000 000,00), poziomy piramidy liczone od 1,
  bez odnośników „§” w tekstach, dni tygodnia w „Stole na sześć” w jednym
  rzędzie, pusty ekran kodu na drzwi zastąpiony podpowiedzią, spójne
  „gotuje Ty”, krótsze „Zamień” w kółku.

### Uzupełnione braki z planu
- **„Zgłoś” wszędzie**: przy postach tablicy, wiadomościach (także w grupach)
  i profilach. Zgłoszoną treść można od razu ukryć u siebie; w piramidzie
  zgłoszenie trafia do delegata od zgłoszeń albo na szczyt.
- **Randki**: paczki profilu szyfrowane osobnym kluczem (ChaCha20-Poly1305),
  klucz dostaje się na prośbę; poręczenia podpisane kluczem poręczeń;
  kilka zdjęć w profilu; status „Randkuję” 💘; „Podziękuj swatowi”;
  terminy „Idę na randkę” pilnowane też w tle.
- **Wydarzenia**: wspólny album (zdjęcia od tych, którzy przyszli, od 15 min
  przed startem), karty wdzięczności dla organizatora, napiwek dla
  organizatora w walucie piramidy.
- **Alarm**: nagranie dźwięku dla przyjaciół i opcjonalna fala Bluetooth do
  telefonów w pobliżu (znajomi widzą kto, obcy — „ktoś w pobliżu”).
- **Alarm: skrót 5× przycisk zasilania** (Android, opcja na ekranie alarmu,
  domyślnie wyłączona). Pięć szybkich naciśnięć (ok. 4 s) — także przy
  wygaszonym ekranie i zamkniętym Zen — podnosi zwykły alarm, ten sam co
  przycisk: odwołuje go tylko PIN, PIN paniczny działa jak zawsze. Telefon
  potwierdza wibracją (długo–krótko–długo). Ostrzeżenie o systemowym
  „Alarmowym SOS”, które na wielu telefonach reaguje na ten sam gest.
- **Alarm do pobliża przy zamkniętej aplikacji**: z włączoną opcją usługa
  Androida w tle pokazuje telefon w pobliżu i odbiera fale alarmu —
  powiadomienie jest to samo co przy alarmie z sieci (u znajomych dzwoni),
  a każda fala dzwoni tylko raz, także gdy aplikacja działa w tle. Alarm
  podniesiony w tle (skrót, termin randki) też idzie falą.
- **„Rozglądaj się też w tle”** (ekran „W pobliżu”, domyślnie włączone):
  co 5 minut 10 sekund oszczędnego skanowania, tylko po to, żeby zaznaczyć
  znajomych w zasięgu jako „spotkanych osobiście” — w aplikacji i w usłudze
  w tle. Skanowanie z ekranu „W pobliżu” ma pierwszeństwo.
- **Sąsiedzi**: zdjęcie mieszkania, usuwanie sąsiada z nowym kluczem dla
  reszty, odsłanianie się sąsiadom.
- **Bilet na wydarzenie przypięty do telefonu**: „Będę” wysyła
  organizatorowi klucz, który ma tylko ten telefon; przy wejściu telefon
  pokazuje żywy kod (odświeżany co 20 s), a skaner przyjmuje go tylko
  z bieżącym czasem (±90 s) i tylko raz — zrzut ekranu przekazany komuś
  innemu przestaje działać po ok. półtorej minuty. Goście ze starszą
  wersją mają dalej zwykły bilet, a organizator widzi „bilet bez
  przypięcia” (przycisk „Przypnij do tego telefonu” to naprawia).
- **Sąsiedzi: usunięty domownik nie podrobi nowego klucza mieszkania.**
  Każdy telefon domownika ma własny klucz, który sąsiedzi znają z profilu;
  głosy za usunięciem i komunikat o nowym kluczu są nim podpisane, a sąsiad
  przyjmuje nowy klucz tylko z podpisem domownika, który zostaje, i głosami
  większości. Dwa różne nowe klucze nie są już rozstrzygane „kto pierwszy”:
  sąsiad widzi ostrzeżenie „Dwa różne nowe klucze mieszkania — zapytaj
  sąsiadów osobiście”, a skan ich nowego kodu z drzwi rozstrzyga spór.
- Poprawka: wspólny album wydarzenia znika z dysku razem z wydarzeniem
  także wtedy, gdy aplikacja nigdy go nie wczytała (np. zapisała go usługa
  w tle).
- **Waluta**: napiwek za odpowiedź w „Zapytaj sieć”; ceny wg poziomu znajomości;
  ogłoszenia przez łańcuch pośredników; przejście całej piramidy jako gałęzi
  do większej.

### Nowy wygląd całej aplikacji
- **Nowa paleta**: głęboka ciemna (albo jasna) baza lekko zabarwiona kolorem
  akcentu i akcent z gradientem. **Wybór koloru wrócił** (Ustawienia →
  Wygląd: 27 kolorów + tryb jasny/ciemny/systemowy); domyślny to fiolet „Zen”.
- **Czytelna typografia**: koniec z szeroko rozstrzelonym drukiem
  maszynowym, który nie mieścił się na telefonie — przyciski, etykiety
  i nagłówki w kroju bezszeryfowym, zdania zamiast WIELKICH LITER.
- **Każdy ekran przerobiony**: Skrzynka i rozmowy (dymki z gradientem,
  nowy pasek pisania), profil (okładka, avatar w gradientowym pierścieniu,
  liczniki), Tablica, Spotkania (kafelki w kolorach, karta alarmu), wydarzenia,
  Stół na sześć, kółka obiadowe, Zapytaj sieć, osoby w pobliżu, alarm, randki
  (karty profili z dużymi „Tak/Nie”), sąsiedzi, graf, piramida (portfel,
  głosowania z wynikami na paskach, historia jako oś czasu), Zaproś,
  ustawienia, ekran blokady, połączenia, ekran startowy.
- **Własne przyciski na pasku po lewej** mają Randki, Sąsiedzi, Graf znajomych
  i Alarm (na dole, na czerwono). „Spotkania” są przez to krótsze, a przełącznik
  „Pokazuj znajomym moją listę znajomych” i „Zapytaj sieć” są teraz
  na ekranie grafu.
- Elementy nie nachodzą już na siebie i mieszczą się na wąskich telefonach
  (sprawdzane zrzutami ekranu w rozmiarze telefonu: `tool/ui_tour`).

### Poprawki
- **Blokada po wyjściu z aplikacji** do ustawienia: Ustawienia →
  Bezpieczeństwo → „Po wyjściu z aplikacji” i czas: 5 s, 30 s, 1 min, 5 min,
  15 min, 1 h (domyślnie 5 min).
- Wydarzenia: „Posiłek” zamiast „Obiad / kolacja”, „Znajomi znajomych
  znajomych” zamiast „2 kroki dalej”; przy tworzeniu wydarzenia wyjaśnienie,
  czym jest Stół na sześć (i skrót do niego).
- Sąsiedzi: zamiast przełącznika „zaproszenia także dla tych, którzy
  zeskanowali nasz kod” — przycisk „Dodaj” przy mieszkaniu, które
  zeskanowało Wasz kod.
- Randki: bez pola „Mam ukończone 18 lat” (wystarcza wiek).
- Zakładka „Podziękowania” w profilu mieści się na ekranie.
- Zakładanie piramidy (i inne okna z polami tekstowymi) już się nie wysypuje.
- **Ważne:** dane wczytane przy zablokowanej aplikacji nie nadpisują już
  znajomych i rozmów pustym stanem (zapis czeka na odblokowanie); to samo
  dla spotkań, randek, sąsiadów i piramidy. Usługa w tle znów startuje
  (błąd zależności przy uruchamianiu).

### Piramida, władza, waluta (etapy 9–11, §20–24, §28) — nowa zakładka „Piramida”
Wszystko zaimplementowane; **używanie zacznie się później** (po audycie
i gdy będzie społeczność).
- **Dołączenie osobiście**: kod QR szefa komórki, rok urodzenia i płeć
  potwierdzone przy wejściu (publicznie tylko skrót).
- **Komórki**: zamiana szefa 2 z 3, **anonimowe żądanie głosowania i
  anonimowy głos** (podpis pierścieniowy — nikt nie wie, kto głosował jak),
  wyjście, zajęcie wolnego miejsca, nieobecność po 60 dniach, usunięcie
  tylko przez własną komórkę, przejście pod innego szefa, **łączenie
  piramid** (mniejsza wchodzi jako gałąź, stara się zamyka).
- **Władza**: decyzje szczytu 2 z 3, delegacje (zakres, limit, termin,
  dalsze delegowanie, cofanie), bany z **immunitetem** wyższych poziomów,
  **„Zgłoś”** w randkach i piramidzie (delegat albo szczyt, jawna decyzja,
  odwołanie, ban randkowy działa w Randkach).
- **Referenda liczone drzewem** (głos tylko do szefa komórki, w górę
  sprawdzalne sumy), **konstytucja** zmieniana referendum, **sekcja
  krajowa** z prowadzącym, posty polityczne i krajowe.
- **Waluta**: emisja z 24 h na weto i limitem kadencji, 15 skarbników
  (przelew ważny z podpisami większości, bez podwójnego wydania),
  płatności warunkowe; **rynek dostępu** — płatna skrzynka,
  przedstawienia, udostępnienie, ogłoszenia.
- **Tryb kryzysowy**: alarm z zasięgiem i fala Bluetooth do telefonów
  w pobliżu, także bez internetu.

### Testowanie na wielu klientach (`docs/TESTOWANIE.md`)
- **Symulator sieci** (`SimNetwork`): wirtualny zegar, opóźnienia, straty,
  wyłączone telefony, rozcięcie sieci; 20+ scenariuszy piramidy, randek
  i sąsiadów w `flutter test`, w tym chaos z naprawą.
- **Kilka aplikacji na jednym komputerze**: `zen.exe --zen-profile=NAZWA`
  (osobne dane i klucze), `tool\multi_client.ps1 -Count 4`.
- **Pilot** `/x/…` (piramida, randki, sąsiedzi) i skrypt
  `dart run tool/zen_drive.dart pyramid 48888 48889 48890 48891`;
  telefon przez `adb forward` (`-Phone`).
- Poprawki znalezione testami: propozycje z mieszanymi wymaganiami
  (szczyt + komórka) nie wychodzą już w połowie podpisane; nieobecność da
  się stwierdzić także u osoby z jednym sąsiadem.

### Randki przez znajomych (etap 8, §19) — „Spotkania → Randki”
- **Tylko do 3 kroków znajomości**, zawsze z kimś wspólnym: „Znacie się
  przez: Bob → Kasia”.
- **Nikt nie wie, że randkujesz**: każdy telefon co tydzień wysyła i
  przekazuje dalej takie same paczki — z profilem albo pustą przykrywkę.
  Telefon bez randek przekazuje je, nie otwierając.
- **Profil randkowy** zbudowany jednym dotknięciem z profilu głównego, z
  preferencjami (płeć, wiek, 1–3 kroki) i ukrywaniem przed wybranymi
  znajomymi albo całymi grupami (np. rodzina, praca).
- **„Tak / Nie”**: para powstaje tylko przy „Tak” + „Tak”. „Nie” nie
  wysyła niczego — nikt się o nim nie dowie.
- **Rozmowy par, przedstawienia i polubienia są zaszyfrowane** i idą przez
  znajomych; telefony po drodze nie wiedzą nawet, od kogo są.
- **Zapytaj o opinię** wspólnego znajomego, **swatanie** (przedstaw sobie
  dwie osoby), **poręczenia** znajomych na profilu.
- **„Idę na randkę”**: przyjaciel widzi, gdzie jesteś; jeśli nie potwierdzisz
  „Wszystko OK”, dostaje przypomnienie, a potem alarm.

### Sąsiedzi (etap 7, §18) — „Spotkania → Sąsiedzi”
- **Profil sąsiedzki rodziny / grupy w mieszkaniu**: „Nowakowie · m. 12”,
  „O nas”, zaproszenia (termin, miejsca), „Oferujemy”, „Potrzebujemy”.
  Sąsiedzi nie widzą Waszych kont.
- **Domownicy** (bez limitu): kolejny telefon dołącza, skanując kod
  domownika (pokazuj go tylko w mieszkaniu). Każdy domownik może zmieniać
  profil i odpisywać; wszystko synchronizuje się między Wami.
- **Przeprowadzka**: stary kod na drzwiach przestaje działać, sąsiedzi
  dostają informację, a Wy zaczynacie od nowa w nowym miejscu. Nowi
  lokatorzy zakładają własny profil od zera.
- **Kod na drzwi**: naklejka A6 do wydrukowania (PNG), z własnym hasłem.
  „Nowy kod” unieważnia stary.
- **Moi sąsiedzi**: zeskanuj drzwi sąsiada — oba mieszkania mają się na
  liście. Wiadomości między mieszkaniami, zapisy na zaproszenia z
  pilnowaniem liczby miejsc, wyciszanie, usuwanie.
- **Zaproszenie w pobliżu**: wyślij zaproszenie przez Bluetooth do ludzi
  z Zen w zasięgu (klatka, podwórko); oni jednym dotknięciem dodają Was do
  sąsiadów.
- Poprawka: po powrocie do aplikacji wydarzenia, pytania, Stół na sześć
  i kółka obiadowe wczytują to, co w tym czasie odebrała usługa w tle.

### Spotkania (etap 6, §15–17) — nowa zakładka „Spotkania”
- **Na teraz**: „Chcę pogadać”, „Chcę wyjść”, „Potrzebuję pomocy”, „Nie
  przeszkadzać” — na godzinę, do końca dnia albo do odwołania, z
  dopiskiem, dla wszystkich znajomych albo tylko przyjaciół. Widzisz, kto
  ze znajomych ma teraz na co ochotę, i jednym dotknięciem do niego piszesz.
- **Alarm**: przytrzymaj 3 sekundy — przyjaciele dostają go od razu, na
  pełnym ekranie, z dźwiękiem alarmu i Twoim położeniem (odświeżanym co
  minutę). Widać, kto jedzie. Odwołanie zwykłym PIN-em; osobny PIN
  paniczny odwołuje alarm na ekranie, ale przyjaciele dostają ostrzeżenie,
  że możesz być zmuszony(-a). Pomyłka w PIN-ie niczego nie odwołuje.
  Przycisk „Zadzwoń na 112”. Działa także przy zamkniętej aplikacji.
- **Osoby w pobliżu** (Android, Bluetooth): znajomi obok z imieniem, obcy
  jako pseudonim zmieniający się co 15 minut, odległość, „Napisz” do obcego
  bez zdradzania konta, „Zaproś do znajomych” z pieczątką „spotkani
  osobiście”. Znajomi spotkani na żywo dostają ją sami.
- **Wydarzenia po znajomości**: impreza, obiad, spotkanie — dla wybranych,
  znajomych, znajomych znajomych albo 2 kroki dalej. Lista gości pokazuje,
  ilu znasz i kto kogo przyprowadził. Limit miejsc, „+1” za zgodą, bilety
  QR sprawdzane przy wejściu bez internetu, „Poznaliśmy się” po wydarzeniu.
- **Stół na sześć**: kolacja z ludźmi oddalonymi o 2 kroki znajomości —
  Zen sam dobiera 5 gości, którzy jak najmniej się znają.
- **Kółka obiadowe**: kolejka gotujących, zamiany za zgodą, alergie,
  lista „kto co przynosi”.
- **Zapytaj sieć**: pytanie do znajomych (i dalej, ale tylko ręcznie),
  odpowiedzi wracają z informacją „znajomy(-a) Bartka”.
- **Graf znajomych**: Ty w środku, przyjaciele, znajomi i znajomi znajomych,
  kolory statusów, wspólni znajomi. Nowe ustawienie „Pokazuj znajomym moją
  listę znajomych”.
- Android: nowe uprawnienia Bluetooth (bez lokalizacji) i lokalizacji
  (tylko dla alarmu); nowa biblioteka geolocator 14 (z `dependency_overrides: uuid ^4`,
  bo system_tray 2.0.3 trzyma uuid 3).

### Odporność: aktualizacje przez sieć i „Podaj dalej” (etap 5, §14.2)
- **Aktualizacje od znajomych, bez sklepu i serwera** — przesyłanie
  gotowe, **zatwierdzanie do ustalenia**. Nowa wersja rozchodzi się jak
  zwykły plik od znajomego do znajomego, czeka **7 dni** od pierwszego
  zobaczenia i **nigdy nie instaluje się sama** — na Androidzie otwiera się
  systemowy instalator, na komputerze instalator trafia do Pobranych.
  Zatwierdzanie jest na razie zrobione podpisami opiekunów, ale nie chcemy
  osób z kluczami do publikacji, więc aktualizacje przez sieć są
  **wyłączone**, dopóki nie ustalimy innego sposobu (§14.2).
- **Ustawienia → Aktualizacje i Podaj dalej**: wersja, stan nowej wersji
  (pobieranie, czas ochronny, gotowa), „Wczytaj aktualizację z pliku”
  (`.zenupdate` ze strony albo pendrive'a, także samo wstrzymanie).
- Narzędzie `tool/zen_release.dart` i opis `docs/WYDANIA.md` — dla
  obecnego (wyłączonego) mechanizmu; zostaną przerobione po decyzji.
- **Podaj dalej**: telefon daje Zen komuś obok bez internetu — włącza
  własny hotspot (kod QR do połączenia z Wi-Fi), a drugi kod QR otwiera
  stronę z plikiem do pobrania. Działa też w tej samej sieci Wi-Fi.
  Udostępniany jest tylko ten jeden plik, pod losowym adresem, najwyżej
  20 minut.
- **Z komputera kablem USB**: „Zainstaluj” przy podłączonym telefonie
  (przez narzędzie adb z Android SDK), także nowszą, podpisaną wersję
  z aktualizacji.
- **Ruch wyglądający jak HTTPS**: komputer-most prosi router najpierw
  o zewnętrzny port 443.
- Android: nowe uprawnienia — instalowanie aplikacji (aktualizacje) oraz
  Wi-Fi / urządzenia w pobliżu (hotspot do „Podaj dalej”).

### Ochrona danych na urządzeniu (etap 4 dokończony, §14.1)
- **Hasło aplikacji domyślnie wymagane**: przy pierwszym uruchomieniu Zen
  prosi o hasło (co najmniej 8 znaków). Pominąć można tylko świadomie,
  a w Ustawieniach jest przełącznik „Pozwól używać aplikacji bez hasła”.
- **Argon2id** dla hasła i hasła paniki; stare hasła przechodzą na nie same
  przy najbliższym odblokowaniu.
- **Odblokowanie biometrią przez sprzęt**: klucz jest zamknięty w Android
  Keystore (StrongBox, gdy jest) albo w TPM na Windows (bez TPM: DPAPI),
  otwiera go dopiero odcisk palca / twarz / Windows Hello. Nowy odcisk
  w telefonie unieważnia klucz — wtedy raz wpisujesz hasło. Ustawienia
  pokazują, co chroni klucz.
- **Klucz konta znika z pamięci** razem z kluczem danych, gdy aplikacja się
  blokuje.
- **Ponowne potwierdzenie** (biometria albo hasło) przed wejściem w Konto
  i odzyskiwanie, Urządzenia i Nagrania rozmów; ważne minutę.
- **Blokada zrzutów i nagrywania ekranu** na czatach, grupach, nagraniach,
  koncie i urządzeniach (Android i Windows); można wyłączyć w Ustawieniach.
- **Znikające wiadomości** w menu czatu i grupy: 1 godzina, 1 dzień albo
  7 dni. Rozmówcy i Twoje inne urządzenia dostają to samo ustawienie;
  wiadomości znikają u wszystkich razem z plikami i nie trafiają do trwałych
  kopii konta.
- **Hasło paniki** kasuje też klucz w układzie bezpieczeństwa.
- **Ostrzeżenie o zrootowanym telefonie** w Ustawieniach → Bezpieczeństwo
  (su, Magisk, LSPosed, Frida, klucze testowe) — bez blokowania.
- Android: aplikacja działa teraz na `FlutterFragmentActivity` (potrzebne
  do systemowego okna biometrii).

### Konto na kilku urządzeniach (etap 4)
- **Ustawienia → Urządzenia**: lista urządzeń konta, „Podłącz nowe
  urządzenie”, „To nowe urządzenie: dołącz do konta” i „Odłącz” przy
  każdym urządzeniu.
- **Podłączanie bezpieczne**: nowe urządzenie pokazuje swój kod (QR albo
  do przepisania), na obu ekranach pojawia się te same 6 cyfr — dopiero po
  ich potwierdzeniu klucz konta idzie, zaszyfrowany jednorazowymi kluczami.
- **Znajomi widzą jedną osobę**: wiadomości i połączenia trafiają na każde
  Twoje urządzenie; odebranie rozmowy na jednym wycisza pozostałe; to, co
  napiszesz na jednym urządzeniu, pojawia się w rozmowie na pozostałych.
- **Znajomi i grupy są wszędzie te same**: zapisane w koncie,
  zaszyfrowane tak, że czytają je tylko Twoje urządzenia. Znajomi trzymają
  zaszyfrowaną kopię, więc **odzyskane konto wraca ze znajomymi i
  grupami** (wcześniej przepadały).
- **Odłączenie zgubionego lub skradzionego urządzenia**: od tej chwili
  nic z niego nie jest przyjmowane i nie dostaje wiadomości; samo
  urządzenie pokazuje, że zostało odłączone.
- Poprawka w silniku: punkt odcięcia urządzenia liczony osobno dla każdej
  przestrzeni (wcześniej długi dziennik jednej przestrzeni mógł zostawić
  furtkę w innej).
- **Historia czatów na nowym urządzeniu**: po podłączeniu dostaje ono
  wszystkie dotychczasowe rozmowy (z plikami do 25 MB każdy),
  zaszyfrowane tak, że czytają je tylko Twoje urządzenia.
- **Wysłane zdjęcia, pliki i wiadomości głosowe** (także w grupach)
  pojawiają się na pozostałych urządzeniach, nie tylko tekst.
- **Usunięcie znajomego, wyjście z grupy, zmiana nazwy i blokada** na
  jednym urządzeniu dzieją się na wszystkich.
- **Członek grupy z kilkoma urządzeniami** (także ktoś, kto nie jest
  Twoim znajomym) jest jedną osobą: jego wiadomości z każdego urządzenia
  są od niego, a Twoje trafiają na wszystkie jego urządzenia.
- **Bezpieczeństwo**: powitanie między urządzeniami ma teraz podpis
  potwierdzający adres, więc nikt nie podszyje się pod drugie urządzenie
  znajomego, żeby czytać jego wiadomości.

### Jeden kod zaproszenia
- Jest już tylko jeden kod: 25 znaków (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`).
  Kod QR niesie ten sam kod (dziś w linku do README, patrz wyżej; wcześniej
  osobny, dłuższy zapis z adresem i nazwą), więc QR jest mniejszy i łatwiej
  się skanuje.
  Nazwę przynosi samo zaproszenie. Kody QR ze starszych wersji nadal
  działają.

## 1.9.0

### Usunięty asystent AI
- **Cała sekcja „Asystent” znika z aplikacji**: model językowy na
  urządzeniu (razem z pakietem llamadart), rozmowa z asystentem,
  „Na pewno chcesz to wysłać?” przed wysłaniem wiadomości i posta,
  ostrzeżenia przed oszustwami pod wiadomościami, tłumaczenia (w czacie,
  grupach, komentarzach, postach i w „O mnie”, także przycisk tłumaczenia
  w polu pisania), „Zenek czuwa”, podsumowanie dnia, stworek
  (tamagotchi) i Notatnik (przypomnienia i pamięć o znajomych). Model
  obciążał urządzenie tak bardzo, że potrafił zawiesić system.
- **Sprzątanie po aktualizacji**: przy starcie aplikacja kasuje dane
  asystenta (rozmowę, stworka, Notatnik, ustawienia, ostrzeżenia) i
  pobrane modele (do 2,6 GB).
- Wiadomości w czacie i w grupach oraz komentarze nadal można skopiować:
  przytrzymanie albo prawy klik → „Kopiuj”.

### Rozmowy w pływającym okienku
- **Android**: wyjście z aplikacji w trakcie rozmowy (gest „do domu”,
  przejście do innej aplikacji) zmniejsza ją do okienka obraz w obrazie
  nad innymi aplikacjami: obraz rozmówcy przy wideo, imię i czas przy
  audio, przycisk „Rozłącz”. Działa też w rozmowach grupowych.
- **Komputer**: przycisk „Mini okno” na ekranie rozmowy, a także
  zminimalizowanie albo zamknięcie okna w trakcie rozmowy zmienia Zen
  w małe okienko w prawym dolnym rogu, zawsze na wierzchu (wycisz,
  wróć do pełnego okna, rozłącz; okienko można przeciągać). Po
  rozmowie okno wraca do zwykłego rozmiaru.

### Działanie w tle bez ikony na pasku stanu (Android)
- Powiadomienie, którego Android wymaga od usługi w tle, ma nowy kanał
  „Zen — działanie w tle” o **minimalnej ważności**: bez ikony na górnym
  pasku, zwinięte na dole listy powiadomień, niewidoczne na ekranie
  blokady. Stary kanał (z V1.2, który Android zostawiał jako „niski”, z
  ikoną) jest usuwany. Na Androidzie 13+ powiadomienie można przesunąć
  albo wyłączyć kanał w ustawieniach — Zen działa dalej.

### Nagrywanie rozmów — dokończone (etap 3a)
- **Rozmowy grupowe**: przycisk „Nagrywaj” w rozmowie grupowej. Wszyscy
  dostają sygnał przed startem i widzą czerwony pasek „● Ada nagrywa”
  (z imionami); ktoś, kto dołączy w trakcie, też go od razu widzi.
- **Windows**: nagrywanie działa także na komputerze — dźwięk samej
  aplikacji Zen (głos rozmówców) zmiksowany z mikrofonem, zapisany jako WAV
  (`windows/runner/call_recorder.cpp`, WASAPI). Sprawdzone testem na
  prawdziwym komputerze (`integration_test/call_recorder_test.dart`).
  Nagrywa tylko rozmowę: przechwytuje dźwięk procesu Zen (WASAPI process
  loopback), więc muzyka, filmy, inne aplikacje i dźwięki systemu nie trafiają
  do nagrania. Wymaga Windows 10 2004 lub nowszego — na starszym nagrywanie
  odmawia zamiast nagrywać cały komputer. Przy głośnikach mikrofon może
  złapać dźwięki z pokoju; najczyściej nagrywa się na słuchawkach.
- **Nagranie nie ginie, gdy rozmowa się skończy**: wcześniej zapisywało
  się tylko po ręcznym „Zatrzymaj”; teraz także po rozłączeniu trafia
  zaszyfrowane do „Nagrania rozmów”.
- Lista nagrań pokazuje, czy to obraz, czy sam dźwięk; eksport zapisuje
  właściwe rozszerzenie (`.mp4` / `.wav`).

### Edycja i usuwanie postów
- Na swoim profilu przy każdym poście jest menu **⋯ → Edytuj / Usuń**
  (własne posty nie są już na Tablicy, więc wcześniej nie było jak ich
  zmienić).
- **Edycja obejmuje też zdjęcia i filmy**: w edytorze widać obecne
  zdjęcia na swoich miejscach, można je usuwać, przestawiać tekst wokół
  nich i dodawać nowe. Odbiorcy posta zostają bez zmian. Nowa wersja
  dociera do znajomych jak każdy wpis („edytowano”).
- Usunięcie pyta o potwierdzenie; post znika z profilu i z tablic
  znajomych.

### Treści dostępne, gdy autor jest offline
- **Znajomi przekazują sobie posty, zdjęcia i filmy**: kto ma kopię
  (podpisaną, a nie-publiczną zaszyfrowaną jak u autora), ten ją podaje
  dalej. Gdy autor jest offline, jego posty i zdjęcia przychodzą od
  wspólnych znajomych. Sprawdzone testem trzech urządzeń
  (`test/offline_content_test.dart`).
- **Telefon w tle też podaje dalej (Android)**: usługa w tle przejmuje na
  ten czas dziennik — odpowiada znajomym postami i plikami i zapisuje to,
  co przyszło. Po powrocie do aplikacji wszystko jest od razu na miejscu.
  Wcześniej telefon z aplikacją w tle nikomu nic nie podawał.
- **Pobieranie zdjęć i filmów nie urywa się**: po ponownym uruchomieniu
  aplikacja dopytuje o brakujące pliki autora i wszystkich znajomych;
  znajomy, który właśnie się pojawił, od razu jest pytany o to, czego
  brakuje; kawałki plików idą od tych, którzy odpowiadają, a nie od
  kogoś offline.
- Co 10 minut aplikacja sama sprawdza u znajomych nowości (wcześniej
  tylko przy starcie albo przy wiadomości od znajomego).
- Uczciwie: gdy nikt z osób, które mają kopię, nie jest online, nie ma od
  kogo pobrać — Zen nie ma serwera. Im więcej znajomych (i komputerów z
  Zen w zasobniku), tym pewniej.

### Edytor postów jak w Discordzie
- Formatowanie z paska albo skrótami: **pogrubienie** (Ctrl+B), *kursywa*
  (Ctrl+I), podkreślenie (Ctrl+U), przekreślenie (Ctrl+Shift+X), `kod`
  (Ctrl+E), spoiler, nagłówki, cytaty, listy, bloki kodu. Formatowanie
  widać już w trakcie pisania (znaczniki są przygaszone).
- **Zdjęcia i filmy w dowolnym miejscu posta**: wstawiają się tam, gdzie
  stoi kursor (do 10 na post; film do 50 MB, na telefonie także z aparatu).
- **Podgląd** posta przed publikacją.
- Posty wyświetlają formatowanie, zdjęcia i filmy w miejscach wybranych
  przez autora — także u znajomych i obserwujących (sprawdzone testem
  dwóch węzłów) oraz na profilu. Linki kopiują się po dotknięciu, spoiler
  odsłania się po dotknięciu.
- **Filmy odtwarzają się same** (bez dźwięku), po kolei: gra pierwszy
  widoczny, następny startuje po jego końcu. Dotknięcie włącza dźwięk.

### Profil
- **Zdjęcie w tle** (3:1, przycinane i zmniejszane na urządzeniu, bez
  EXIF) — widzą je znajomi i obserwujący.
- **O mnie** z formatowaniem jak w postach (pogrubienie, kursywa,
  nagłówek, cytat, listy) widocznym od razu w polu; do 1000 znaków. U znajomych bio
  wyświetla się sformatowane.
- **Status** ustawia się na swoim profilu (dotknij statusu pod imieniem):
  19 gotowych statusów w trzech grupach — „Czy można do mnie pisać”
  (dostępny, w pracy, zaraz wracam, nie przeszkadzać, rzadko zaglądam,
  śpię), „Co robię” (w drodze, w podróży, na urlopie, uczę się, na
  treningu, gotuję, oglądam film, gram) i „Jak się mam” (odpoczywam,
  chętnie pogadam, świętuję, choruję, potrzebuję chwili dla siebie) —
  albo własny. Nie ma go już w edycji profilu; górna belka
  wygląda jak wcześniej.
- **Galeria** to osobne zdjęcia i filmy profilu, **niezależne od
  postów** (zdjęcia z postów do niej nie trafiają, a galeria nie pojawia
  się na tablicy). „Dodaj zdjęcie lub film” → wybór plików i widoczności,
  domyślnie **dla wszystkich znajomych**; opcja **„Wszyscy (także
  obserwujący)”** pokazuje je też obserwującym. Przytrzymanie zdjęcia w
  galerii → zmiana widoczności (pliki szyfrują się na nowo nowymi
  kluczami) albo usunięcie. Nowe posty na
  tablicy też domyślnie idą do znajomych, nie publicznie.
- Okrągłe zdjęcia profilowe wszędzie (wcześniej w środku ramki widać było
  rogi kwadratu); własny awatar bez zdjęcia pokazuje pierwszą literę
  imienia zamiast ikonki.

### Wygląd i porządki
- **Zaproś** — nowa pozycja w pasku po lewej: Twój kod QR, kod
  zaproszenia, prośby od osób, które go właśnie zeskanowały, i dodanie
  znajomego po jego kodzie. Z ekranu wiadomości zniknął przycisk „MÓJ
  KOD”.
- Ustawienia bez karty profilu (profil edytuje się w zakładce Profil).
- Przycisk wysuwania ukrytego paska leży na treści (nie zabiera
  szerokości ekranu) i jest półprzezroczysty.
- Poprawione opisy: zamiast „Windows i Android” — „na telefonach i
  komputerach”; brakujące polskie znaki w kilku komunikatach.
- Pasek po lewej: **Profil → Czaty → Tablica → Zaproś** (bez Asystenta).
- **Tablica nie pokazuje własnych postów** — są na Twoim profilu. Po
  publikacji pojawia się „Opublikowano” z przyciskiem „Pokaż”.
- **Jednakowe nagłówki sekcji**: Profil, Skrzynka, Tablica, Zaproś i
  Ustawienia mają ten sam pasek tytułu (krój, rozmiar, miejsce na
  przyciski).
- Pole „O mnie” ma delikatnie zaokrąglone rogi.
- Pasek formatowania w edytorze postów zawija się do drugiego rzędu
  zamiast chować przyciski za krawędzią.
- Zaproszenie do grupy zawsze ma swoją kartę z „Dołącz / Odrzuć”, nawet
  gdy przyszło, kiedy aplikacja była w tle; urządzenie nie wysyła sygnałów
  obecności członkom grupy, do której jeszcze nie dołączyłeś.

### Poprawki
- Nowa ikona Tablicy (gazeta).
- Poprawione kodowanie znaku § w `call_recordings.dart`.

## 1.8.0

### Nowe
- **Asystent na urządzeniu (§29)** – nowa zakładka „Asystent” w belce:
  - stworek Zenek (rysowany, oddycha, mruga, podskakuje przy głaskaniu,
    śpi w nocy); nastrój bez serii i bez obwiniania, imię do zmiany;
  - „Na pewno chcesz to wysłać?” przed wysłaniem w czacie, w grupie i na
    tablicy, z łagodniejszą wersją do wstawienia jednym dotknięciem
    (czułość: wył. / obelgi / też krzyk);
  - odpowiedzi automatyczne według własnych reguł (opcjonalnie w
    godzinach), oznaczone 🤖, najwyżej raz na 3 h na osobę.
  Na razie ocenia wbudowany model regułowy; prawdziwy model językowy
  dojdzie w kolejnej wersji.
- **Udostępnianie ekranu w rozmowach** 1:1 i grupowych (na Androidzie także
  pojedynczej aplikacji, Android 14+), z oznaczeniem u pozostałych.
- **Nagrywanie rozmów** 1:1 (Android) z informacją dla rozmówcy, kto
  nagrywa; nagrania zaszyfrowane w aplikacji (Ustawienia → Nagrania rozmów).
- **Tablica i profil** (sieć społeczna na ledgerze): posty ze zdjęciami,
  odbiorcy według poziomu znajomości, polubienia, komentarze,
  udostępnienia, edycja i usuwanie, obserwowanie, karty wdzięczności.
- **Konto i odzyskiwanie**: hasło konta, krąg odzyskiwania (2 z n + hasło,
  awaryjnie 4 z n), opóźnienia i alarm.
- Prywatność: domyślnie powiadomienia bez treści, schowek czyszczony po
  60 s przy kopiowaniu poufnych danych.

### Wygląd i wygoda
- **Edytor posta** na pełnym ekranie: duże pole tekstu z licznikiem znaków,
  wybór odbiorców z opisem („kto zobaczy ten post?”), do 4 zdjęć z
  podglądem, usuwaniem i wskaźnikiem przetwarzania (galeria; na telefonie
  także aparat), pytanie przed porzuceniem szkicu, Ctrl+Enter publikuje.
  Ten sam edytor służy do poprawiania posta.
- Dodawanie zdjęć: gdy okno wyboru plików zwraca tylko ścieżkę, zdjęcie
  wczytuje się z dysku (wcześniej mogło zostać pominięte bez słowa),
  a błędy są pokazywane. Zdjęcia
  w postach układają się w siatkę i otwierają na pełnym ekranie
  (przesuwanie, przybliżanie). Posty na profilu pokazują zdjęcia,
  datę, polubienia i komentarze.
- Na szerokim oknie posty i asystent mają czytelną szerokość kolumny.
- Belka: kolejność **Profil → Czaty → Tablica → Asystent**. Usunięte
  dublujące się skróty (Ustawienia otwiera pasek stanu, „Mój kod” jest
  w Skrzynce, profil we własnej zakładce).
- Pionowa belka z zakładkami: wąska (same ikony), da się ją **całkiem
  schować**; przycisk chowania i pokazywania jest **u góry**, w zasięgu
  kciuka; działa też przesunięcie palcem. Belka pamięta, czy była schowana.
- Pasek stanu połączenia zostaje na górze ekranu, na całej szerokości;
  dotknięcie otwiera ustawienia.
- Skrzynka: filtry w jednym przewijanym rzędzie, krótsze przyciski
  „Znajomy” / „Grupa” (nie łamią się na telefonie).
- Spójne nagłówki (Skrzynka, Tablica, Mój profil, Asystent).

### Techniczne
- Yggdrasil v0.5.14 w mostku natywnym.
- `screenshots/shots_test.dart` – zrzuty głównych ekranów do podglądu
  (`flutter test screenshots/shots_test.dart --update-goldens`).
