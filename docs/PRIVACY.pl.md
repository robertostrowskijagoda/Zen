# Zen - Polityka prywatności

*Wersja dla Zen 1.11.0 - ostatnia zmiana 22 października 2026.*
*To tłumaczenie angielskiego dokumentu [PRIVACY.md](PRIVACY.md). Jeśli coś się
w nich różni, zapytaj na GitHubie.*

Ta polityka wyjaśnia, co dzieje się z Twoimi danymi, gdy korzystasz z Zen.
Została napisana tak, by uczciwie opisywać, jak aplikacja naprawdę działa, w
tym miejsca, w których prywatność jest słabsza, niż ludzie mogliby się
spodziewać.

## 1. W skrócie

- **Autor nie prowadzi żadnych serwerów dla Zen.** Nie ma konta Zen, chmury,
  numeru telefonu, adresu e-mail ani logowania. Autor nie otrzymuje, nie
  przechowuje i nie widzi Twoich wiadomości, kontaktów, postów, lokalizacji ani
  profilu.
- **Twoje dane są na Twoich urządzeniach.** Są zaszyfrowane na urządzeniu
  kluczem chronionym Twoim hasłem oraz, jeśli system je ma, sprzętowym
  magazynem kluczy (Android Keystore, Windows TPM, Secure Enclave).
- **Urządzenia innych osób dostają to, co im wysyłasz.** Znajomi, grupy i
  piramida, do której dołączysz, otrzymują treści, które im udostępniasz, a ich
  kopie są poza Twoją kontrolą i poza kontrolą autora.
- **Pośrednicy w sieci widzą adresy, nie treść.** Zen działa w sieci Yggdrasil.
  Węzły, które przenoszą Twój ruch, mogą widzieć Twój adres IP i Twój adres
  sieciowy, ale nie to, co piszesz.
- **Sama aplikacja łączy się z dwiema zewnętrznymi usługami:** wyszukiwarka
  GIF-ów korzysta z klipy.com (sekcja 6), a poza wersją ze sklepu Zen pyta
  GitHub o najnowsze wydanie (sekcja 7).
- **Żadnej analityki, reklam ani trackerów.** Dzienniki awarii i diagnostyki
  zostają na Twoim urządzeniu.

## 2. Kto odpowiada

Zen tworzy **Robert Ostrowski-Jagoda**, programista działający jako osoba
prywatna (zob. plik `NOTICE`; strona projektu:
https://github.com/robertostrowskijagoda/Zen).

Ponieważ autor nigdy nie otrzymuje Twoich danych, w praktyce **nie ma
możliwości uzyskania do nich dostępu, ich poprawienia ani usunięcia**. W
zakresie, w jakim prawo traktuje autora jako "administratora" czegokolwiek (na
przykład informacji opublikowanych na stronie projektu na GitHubie lub
rozwiązań przyjętych w aplikacji), autor jest tą osobą. Każdy użytkownik,
który udostępnia znajomym dane innych osób (na przykład przesyłając czyjeś
zdjęcie), sam odpowiada za to, by robić to zgodnie z prawem.

Kontakt: zob. sekcję 13.

## 3. Jakie dane istnieją i gdzie

### 3.1 Na Twoim urządzeniu (nigdy nie są wysyłane do autora)

- **Klucze tożsamości.** Przy pierwszym uruchomieniu Zen tworzy klucze
  kryptograficzne: klucz sieci mesh (z niego pochodzi Twój adres Zen), klucz
  konta w dzienniku (ledger) i klucze urządzeń oraz klucze do zapieczętowanej
  poczty i randek. Twój "kod zaproszenia" i kod QR zawierają Twój adres
  sieciowy.
- **Profil:** wyświetlana nazwa, opis, własny status, awatar, tło profilu,
  galeria, "kartki z podziękowaniami".
- **Kontakty i rozmowy:** znajomi i ich poziomy, grupy, wiadomości, notatki
  głosowe, zdjęcia, filmy i pliki, Twoje posty, polubienia i komentarze.
- **Dane funkcji:** statusy ("na teraz"), wydarzenia, alarmy (w tym lokalizacja
  i nagrany dźwięk, jeśli z nich korzystasz), sąsiedzi (mieszkania), profil i
  decyzje randkowe, wpisy i salda piramidy oraz dziennik podpisanych wpisów.
- **"Mijani" (dziennik spotkań):** znajomi, których mijałeś, i ile innych
  telefonów z Zen było w pobliżu, zbudowany wyłącznie z tego, co słyszy
  funkcja "Osoby w pobliżu", gdy skanuje (nic nie skanuje specjalnie dla
  niego), z czasem i, jeśli telefon miał niedawną pozycję, miejscem
  zaokrąglonym do około 100 m. Tokeny nieznajomych są trzymane w pamięci przez
  jeden 10-minutowy przedział i zachowywana jest tylko największa liczba z
  godziny; adresy Bluetooth nigdy nie są zachowywane. Dziennik zostaje na
  telefonie, znika po 30 dniach i można go w każdej chwili wyczyścić.
- **Ustawienia, parametry skrótu hasła blokady, hasło awaryjne** i podobne.
- **Dziennik diagnostyczny:** rotowany plik tekstowy (`zen-diagnostics.log`,
  przycinany do około 128 KB) z komunikatami technicznymi. Ścieżki folderów są
  w nim skracane. Możesz go przeczytać w Ustawieniach. **Nigdy nie jest nigdzie
  wysyłany automatycznie.** Jeśli go skopiujesz lub komuś wyślesz (na przykład
  zgłaszając błąd), to Twój wybór - najpierw go sprawdź.

Prawie wszystko powyżej jest przechowywane w postaci zaszyfrowanej
(AES-256-GCM, z kluczem głównym chronionym kluczem wyprowadzonym z Twojego
hasła za pomocą Argon2id oraz, jeśli to możliwe, magazynem sprzętowym).
**Wyjątki:** multimedia, które celowo eksportujesz lub zapisujesz, są
zapisywane jako zwykły plik, a wybrany język jest trzymany w zwykłym pliku
(jest potrzebny przed odblokowaniem). Na Androidzie, aby telefon mógł dalej
odbierać, gdy Zen jest zablokowany, tożsamość sieciowa tego urządzenia, lista
kluczowanych znaczników Twoich kontaktów oraz to, czego alarm, "osoby w
pobliżu" i drzwi Twojego mieszkania potrzebują, gdy Zen jest zablokowany
(odbiorcy alarmu i własny klucz alarmu, Twoje tokeny Bluetooth na najbliższe
dni, klucze, które dali Ci znajomi, by rozpoznawać ich w pobliżu, klucze do
drzwi), są zapieczętowane osobnym **kluczem tła** w bezpiecznym magazynie
systemu, który otwiera się bez Twojego hasła; to, co przychodzi, gdy Zen jest
zablokowany, jest zapisywane w postaci zapieczętowanej tak, że może to
odczytać tylko Twoja odblokowana aplikacja. To świadomy kompromis: ktoś, kto
może wydobyć zarówno dane aplikacji, jak i ten klucz (na przykład na
zrootowanym lub przejętym telefonie), może odczytać te małe "zestawy" - do kogo
idzie alarm, klucz alarmu (podpisuje tylko ramki alarmu), Twoje tokeny
Bluetooth na najbliższe dni (nie Twój prywatny klucz "w pobliżu"), klucze do
drzwi mieszkania - ale nie Twoje wiadomości, posty ani nazwy kontaktów, które
pozostają chronione hasłem.

### 3.2 Co otrzymują inne osoby

Gdy korzystasz z jakiejś funkcji, zaangażowane osoby otrzymują dane, których ta
funkcja potrzebuje. Wszystko poniżej jest wysyłane z urządzenia na urządzenie
przez sieć Yggdrasil.

| Robisz to | Kto co otrzymuje |
|---|---|
| Wysyłasz zaproszenie do znajomych | Druga osoba: Twój adres Zen, wyświetlaną nazwę i notkę, którą napisałeś. |
| Jesteś czyimś znajomym | Znajomi widzą Twój profil (nazwę, status, opis, awatar), kiedy jesteś online / masz aplikację na ekranie (sygnały obecności co ~45 s, gdy aplikacja działa), Twój bieżący status ("na teraz"), jeśli pozwalają na to jego odbiorcy, oraz - zależnie od ustawienia - Twoją listę znajomych. Twój "poziom bliskości" dla znajomego jest prywatny; on nigdy go nie poznaje. |
| Lajkujesz, komentujesz lub piszesz do kogoś, kto nie jest Twoim znajomym | Autor postu i znajomi, którzy go przekazali, dostają Twoje podpisane polubienie lub komentarz razem z małą podpisaną kopią Twojego profilu (nazwa i zdjęcie). Pierwsza wiadomość do osoby spoza znajomych (tylko jeśli jej ustawienia na to pozwalają) zawiera to samo. |
| Czat | Odbiorca: treść wiadomości, załączniki, znaczniki czasu, wskaźnik pisania, potwierdzenia doręczenia i odczytu, liczniki znikających wiadomości. |
| Grupy | Każdy członek (do 256) dostaje każdą wiadomość. Członkowie znają listę członków grupy. |
| Rozmowy głosowe i wideo | Pozostali uczestnicy: sygnalizację połączenia i strumień multimediów (WebRTC). Uczestnicy poznają Twój adres sieciowy oraz, przez WebRTC, dane sieciowe potrzebne do połączenia. |
| Post na Twojej tablicy | Dziennik powiela Twój post na urządzenia wybranych odbiorców. Posty z odbiorcami "Wszyscy znajomi", "Znajomi i przyjaciele" lub "Tylko przyjaciele" są szyfrowane, więc mogą je odczytać tylko znajomi o odpowiednio wysokim poziomie; **publiczne posty i publiczne pola profilu może przeczytać każdy, kto je zdobędzie**, w tym osoby, które Cię obserwują, i każdy, komu zostały przekazane. Istnienie, czas i rozmiar wpisów oraz klucz Twojego konta są widoczne dla każdego, kto ma wpis, nawet przy zaszyfrowanych postach. |
| Skrzynki offline | Do sześciu znajomych wybranych przez Ciebie (lub przez aplikację) przechowuje **zaszyfrowane** kopie poczty zaadresowanej do Ciebie przez maksymalnie 14 dni, w tym załączniki (do 24 MB każdy, w ramach limitu na nadawcę). Widzą, od kogo i do kogo jest, rozmiar i czas, ale nie treść. |
| Alarm | Znajomi wybrani do alarmów: Twoja lokalizacja (jeśli na to pozwolisz), notka, nagrany dźwięk i potwierdzenia doręczenia. Telefony w pobliżu mogą odebrać podpisane "machnięcie" przez Bluetooth (identyfikator alarmu i czas; tylko znajomi mogą rozpoznać, czyj to alarm). Lokalizacja pochodzi z własnej usługi lokalizacji telefonu (nigdy z usług Google Play) i jest wysyłana tylko z alarmem lub prośbą o ochronę na randce, którą uruchomiłeś Ty lub znajomy. Dotknięcie linku do mapy otwiera openstreetmap.org w przeglądarce ze współrzędnymi. |
| "Osoby w pobliżu" (Android) | Jeśli to włączysz, Twój telefon rozgłasza przez Bluetooth token, który zmienia się co 10 minut (razem z adresem Bluetooth); tylko znajomi mogą rozpoznać, że to Ty, i nie mogą pokazać go innym w Twoim imieniu. Każdy w pobliżu może zobaczyć, że jest tu *jakiś* telefon z Zen, i przybliżoną siłę sygnału. Jeśli "machniesz", osoba dostaje Twój pseudonim, Twój krótki tekst i Twój adres mesh - nie Twoje konto. Telefony znajomych, które Cię usłyszą, mogą to zapisać we własnym prywatnym dzienniku "Mijani" (sekcja 3.1). |
| Łączność bez internetu | Jeśli zostawisz włączone wykrywanie w Wi-Fi (domyślnie jest włączone) albo włączysz Wi-Fi Direct, Bluetooth lub Apple Multipeer, Twoje urządzenie rozgłasza ogłoszenia, aby urządzenia znajomych i Twoje własne w pobliżu mogły się z nim połączyć bez internetu: w sieci lokalnej sygnał UDP co 10-30 sekund, przez Bluetooth ogłoszenie ze stałym identyfikatorem usługi Zen, przez Wi-Fi Direct rekord usługi (a na telefonie, który prowadzi grupę, nazwę grupy i hasło). Ogłoszenie to filtr Blooma ze znaczników, które mogą sprawdzić tylko właściwe urządzenia, za każdym razem z nową losową solą, więc obcy widzą losowe bajty; mogą stwierdzić, że jest tu *jakieś* urządzenie z Zen z łącznością lokalną i mniej więcej z iloma urządzeniami się łączy, ale nie kim jesteś. Obcy, którzy dołączą do tej samej sieci Wi-Fi lub grupy, nie dostają połączenia ani danych; uzgadnianie połączenia najpierw dowodzi wspólnego sekretu. |
| "Otwarty na poznanie" | Domyślnie wyłączone. Jeśli to włączysz (pytanie w profilu randkowym), Twoi znajomi otrzymują tylko Twój zamiar (randki, nowi znajomi lub jedno i drugie) i przekazują go swoim znajomym, więc znajomi Twoich znajomych mogą zobaczyć znaczek na grafie. Osoby, które wykluczysz, są zapisane jako solone skróty, więc znajomi przekazujący tę informację mogą je pominąć, nie wiedząc, kim są. Nic więcej z profilu randkowego nie idzie razem z nią. |
| Kółka kolacyjne: dzielenie się jedzeniem | Oferta jedzenia członka (danie, porcje, przedział czasu, zdjęcie, cena lub "za darmo") trafia do kółka oraz, jeśli kucharz tak wybrał, do znajomych lub znajomych znajomych. Miejsce poznają tylko osoby przyjęte przez kucharza; znajomy, który przekazuje prośbę między znajomym znajomego a kucharzem, też widzi miejsce w odpowiedzi. Kto kogo nakarmił, zapisuje się tylko na telefonach kucharza i proszącego. |
| Sąsiedzi | Członkowie mieszkania lub budynku, do którego dołączysz: to, co zdecydujesz się ujawnić w tej funkcji. Pukanie do drzwi mieszkania, gdy żaden mieszkaniec nie jest online, przechowuje do sześciu znajomych mieszkańca, zapieczętowane tak, że znajomy nie wie ani kto pukał, ani do którego mieszkania; jeśli pozwolisz znajomym korzystać ze "skrzynek przy drzwiach", Twój telefon robi to dla nich (przechowuje szyfrogram do 7 dni). |
| Randki | Twój zamiar (randki, nowi znajomi lub jedno i drugie) jest częścią zapieczętowanego testu dopasowania i Twojego profilu, a zainteresowania są częścią profilu; ustawione filtry zostają na Twoim telefonie. Małe "lampiony" (jednorazowy klucz i nic więcej: bez wieku, imienia, płci czy preferencji; ten sam kształt niezależnie od tego, czy korzystasz z randek) są przekazywane do dwóch kroków przez telefony znajomych. Telefon, który widzi lampion, wykonuje zapieczętowany test dopasowania; tylko jeśli do siebie pasujecie, prosi o profil, który jest wysyłany zapieczętowany, więc telefony po drodze nie mogą go odczytać. Randki nigdy nie pytają o wiek. Osoby, które mogą odczytać Twój profil, widzą to, co w nim umieścisz. Twoje "Tak" jest wysyłane tylko jako niepowiązywalny token; "Nie" nie wysyła niczego. |
| Piramida | Dołączając, podajesz rok urodzenia, narodowość i płeć; osoba, która Cię przyjmuje, podpisuje, że to prawda. Członkowie piramidy widzą Twój pseudonim, narodowość i **wiek** w Twoim profilu piramidy (płeć tylko, jeśli zdecydujesz się ją pokazać). Członkowie otrzymują też tworzone przez Ciebie podpisane wpisy (głosy, propozycje, posty, płatności, zgłoszenia) i dzielą czat grupowy z członkami swojej komórki i komórki poniżej (bez zaproszeń; wszyscy widzą wiadomości). Osoby spoza piramidy mogą czytać posty szczytu i sekcji krajowej, które przekazują im znajomi z piramidy (pseudonim autora i podpisany post). Głosy w Twojej komórce są podpisywane anonimowo w obrębie pierścienia członków; ten podpis jest klasyczny, więc przyszły komputer kwantowy mógłby w zasadzie powiązać zapisany głos z jego autorem. |
| Przedstawienia | Znajomy, który Cię przedstawia, i osoba, której jesteś przedstawiany. Twoje warunki bramy (za darmo lub cena, zgoda) trafiają do Twoich znajomych; jeśli włączysz "Pokazuj moje bramy dalej", Twoi znajomi przekazują te warunki i Twoją listę znajomych swoim znajomym, do dwóch kroków. Cena za pierwszą wiadomość spoza Twoich znajomych jest publikowana w Twoim cenniku piramidy (tylko dla członków). Płatne bramy i pierwsze wiadomości są płatnościami piramidy: członkowie piramidy, którzy mają ten wpis, widzą pseudonimy płacącego i otrzymującego, kwotę, czas i oznaczenie, że chodziło o bramę lub pierwszą wiadomość (nie samą wiadomość). Płatność jest wstrzymana, dopóki otrzymujący jej nie zatrzyma lub nie zwróci (albo płacący nie odbierze jej po terminie). |

Wszystko, co wysyłasz, odbiorca może skopiować, zrobić zrzut ekranu, przekazać
dalej lub zachować. Wpisy w dzienniku są **podpisane i można do nich tylko
dopisywać**: inne urządzenia mogą zachować kopię postu lub wpisu nawet po
usunięciu go po Twojej stronie (sekcja 10).

### 3.3 Dane, które może zobaczyć obcy, nie będąc Twoim znajomym

- Twój **adres sieciowy** (widoczny dla każdego, z kim się łączysz lub kto
  kieruje ruch do Ciebie w Yggdrasil) i wszystko, co upubliczniłeś.
- Obcy mogą wysyłać Ci dane (zaproszenia do znajomych, powitania sąsiedzkie,
  sygnały); Zen ogranicza ich częstotliwość i większość ignoruje, i nie
  odpowiada na pingi osób, które nie są znajomymi ani członkami grup.

## 4. Publiczne węzły Yggdrasil i mosty

Zen nie ma własnych serwerów. Aby dostać się do sieci mesh, aplikacja łączy się
z **publicznymi węzłami Yggdrasil** (lista dołączona do aplikacji, pochodząca
ze społecznościowej listy github.com/yggdrasil-network/public-peers), z
urządzeniami znalezionymi przez łączność lokalną (sekcja 3.2, "Łączność bez
internetu": domyślnie w tej samej sieci Wi-Fi, łączone są tylko urządzenia
znajomych i Twoje własne) oraz z "mostami" prowadzonymi przez użytkowników Zen.
Wersje na komputer mogą przyjmować połączenia przychodzące (UPnP / NAT-PMP) i
w ten sposób działać jako most dla innych.

Co mogą zobaczyć operatorzy tych węzłów:

- **Twój adres IP i adres Twojego węzła Yggdrasil** (a więc Twój adres Zen),
  gdy Twoje urządzenie łączy się z nimi bezpośrednio.
- Do jakich innych adresów węzłów idzie Twój ruch, ile go jest i kiedy - ale
  nie treść, która jest szyfrowana end-to-end przez Yggdrasil między Twoim
  węzłem a węzłem docelowym.
- Ruch, który przekazujesz dla innych, też przechodzi przez *Twoje* urządzenie,
  jeśli prowadzisz most na komputerze (zaszyfrowany; nie możesz go odczytać).

Ci operatorzy są niezależni, mogą być w dowolnym miejscu na świecie i nie są
kontrolowani przez autora. To nieunikniona cecha korzystania z publicznej
sieci nakładkowej. Nie korzystaj z Zen, jeśli nie możesz zaakceptować, że Twój
adres IP jest dla nich widoczny. (VPN nie zmienia tego dla operatorów
Yggdrasil, ale ukrywa przed nimi Twój prawdziwy adres IP.)

## 5. Szyfrowanie - co robi, a czego nie

- Ruch między dwoma urządzeniami z Zen jest szyfrowany end-to-end przez
  Yggdrasil (klucze sesji wyprowadzone z kluczy węzłów), a każdy odcinek jest
  dodatkowo chroniony. Tożsamość drugiej strony jest sprawdzana: pakiet jest
  przyjmowany tylko wtedy, gdy naprawdę pochodzi z adresu węzła nadawcy.
  Kryptografia samego Yggdrasil jest klasyczna, więc Zen dodatkowo pieczętuje
  każdy sygnał hybrydowym kluczem postkwantowym (ML-KEM-768 + X25519), który
  ma sprawić, że zapisany ruch pozostanie nieczytelny dla przyszłego komputera
  kwantowego.
- Poczta przechowywana przez znajomego-skrzynkę i skrzynka zablokowanego
  telefonu są pieczętowane tym samym rodzajem klucza hybrydowego, więc
  skrzynka nie może odczytać poczty ani zmienić jej nadawcy. Ramki dźwięku i
  obrazu w rozmowach są szyfrowane end-to-end dodatkowo ponad WebRTC (klucze z
  wymiany hybrydowej); używają AES-128-GCM, który jest słabszy wobec komputera
  kwantowego niż reszta.
- To, co Zen podpisuje i przechowuje (posty, wpisy, wydania), ma hybrydowy
  podpis Ed25519 + ML-DSA-65. Nadal klasyczne są: podpisy pierścieniowe
  anonimowych głosów, bilety QR na wydarzenia, powitania przez Bluetooth i
  Wi-Fi oraz uzgadnianie łączności lokalnej, skrzynki randkowe, pukanie do
  drzwi i klucz węzła Yggdrasil. Zob. SECURITY.md.
- Posty dla ograniczonych odbiorców, pakiety randkowe i niektóre inne dane mają
  własne warstwy szyfrowania.
- Metadane nie są ukryte przed drugą stroną ani przed uczestnikami sieci, którzy
  widzą adresy i czas (zob. sekcję 4).
- Zen nie ochroni Cię przed kimś, kto ma Twoje odblokowane urządzenie, Twoje
  hasło albo kto nakłoni Cię do zainstalowania zmienionej aplikacji.

## 6. Strona trzecia: klipy.com (wyszukiwarka GIF-ów)

Wyszukiwarka GIF-ów to **jedyna funkcja, która łączy się z serwerem firmy**
zamiast z innym użytkownikiem Zen.

- Gdy otwierasz wybór GIF-ów lub szukasz, Twoje urządzenie wysyła żądanie HTTPS
  do `api.klipy.com` zawierające: **wpisany tekst wyszukiwania** (lub prośbę o
  "polecane"), **język aplikacji** (jako ustawienie regionalne, np. `pl_PL`),
  wspólny klucz aplikacji wbudowany w Zen (lub Twój własny klucz, jeśli ustawisz
  go w Ustawieniach), nazwę klienta (`zen_messenger`) oraz, jak przy każdym
  żądaniu w sieci, **Twój adres IP** i zwykłe nagłówki techniczne. Nic z Twoich
  rozmów, kontaktów ani konta nie jest wysyłane.
- Podglądy GIF-ów i wybrany GIF są pobierane z klipy.com przez **Twoje**
  urządzenie, więc klipy.com widzi Twój adres IP i to, który GIF wybrałeś. Zen
  wysyła następnie wybrany GIF znajomemu jako zwykły załącznik ze zdjęciem
  (szyfrowany end-to-end jak każdy inny). **Znajomy, który otrzymuje GIF,
  nigdy nie łączy się z klipy.com**: na jego urządzeniu nic nie jest pobierane,
  a GIF przechodzi te same kontrole co inne obrazy (musi być poprawnym GIF-em w
  granicach rozmiaru, liczby klatek i wymiarów; nie jest przekodowywany, więc
  dalej się rusza).
- Do tego, co Klipy robi z tymi danymi, stosują się regulamin i polityka
  prywatności Klipy. Autor nie ma na to wpływu.
- **Wyszukiwarkę GIF-ów można wyłączyć** w Ustawieniach -> *GIF-y*. Gdy jest
  wyłączona, Zen nie wysyła nic do klipy.com, a przycisk GIF znika. GIF-y z
  klawiatury telefonu nadal działają: większość klawiatur wstawia je jako
  zwykłe obrazki, które Zen wysyła jak każde inne zdjęcie.

## 7. Inne strony trzecie

- **buycoffee.to (wpłaty).** Zen pokazuje link do dobrowolnej zbiórki na
  https://buycoffee.to/zen. Jego otwarcie przenosi Cię z aplikacji do
  przeglądarki; płatności, dane wpłacających i pliki cookie obsługuje
  buycoffee.to i jego partnerzy płatniczy na własnych zasadach. Zen nie
  przetwarza płatności i żadne dane płatnicze nie przechodzą przez aplikację.
  Wpłaty nie są wymagane.
- **GitHub.** Aplikacja jest rozpowszechniana przez GitHub Releases, a strona z
  zaproszeniem (https://robertostrowskijagoda.github.io/Zen/) jest
  hostowana na GitHub Pages. GitHub widzi zwykłe dane z odwiedzin strony (adres
  IP, identyfikator przeglądarki), gdy pobierasz Zen lub otwierasz tę stronę,
  zgodnie z własną polityką GitHuba. Kod zaproszenia w linku jest umieszczony
  po `#`, więc przeglądarka nie wysyła go do serwera. Sam Zen (poza wersją ze
  sklepu) pyta API GitHuba o najnowsze wydanie około 20 sekund po starcie i co
  12 godzin, a plik wydania (i jego `SHA256SUMS`) pobiera, gdy naciśniesz
  "Aktualizuj"; GitHub widzi wtedy Twój adres IP, identyfikator klienta "Zen"
  i to, który plik wydania pobrałeś, nic więcej (żadnego konta, tokenu ani
  identyfikatora urządzenia). Jeśli GitHub jest nieosiągalny, aplikacja o tym
  mówi. Zen sprawdza pobrany plik z sumami kontrolnymi wydania (a na Androidzie
  także z własnym certyfikatem podpisu) przed instalacją.
- **Linki, które dotkniesz** (strona Yggdrasil, lista publicznych węzłów, mapy),
  otwierają się w przeglądarce i podlegają zasadom tych stron.
- **System operacyjny i sklepy.** Producent telefonu, twórca Androida / iOS /
  Windows / macOS oraz, w przypadku iPhone'a, SideStore / AltStore i Apple mogą
  zbierać dane o instalowaniu i działaniu aplikacji. To jest poza Zen.
- **Uprawnienia telefonu.** Zen prosi o lokalizację (alarmy, ochrona na
  randce, miejsce w "Mijani"; opcjonalnie, także w tle, jeśli na to pozwolisz),
  Bluetooth i urządzenia Wi-Fi w pobliżu (osoby w pobliżu i łączność bez
  internetu, opcjonalnie), aparat i mikrofon (rozmowy, skanowanie QR,
  nagrania), powiadomienia oraz kilka uprawnień systemowych (usługa na
  pierwszym planie, alarm na pełnym ekranie, optymalizacja baterii, instalowanie
  aktualizacji z "Podaj dalej" i samoaktualizacja). Dane są używane na
  urządzeniu i wysyłane tylko tak, jak opisano powyżej. Starsze wersje
  Androida wymagają uprawnienia lokalizacji dla Wi-Fi Direct (zasada systemu).

## 8. Czego Zen *nie* robi

- Żadnej analityki, telemetrii, identyfikatorów reklamowych, usług raportowania
  awarii ani testów A/B. Nie ma kodu, który raportowałby autorowi korzystanie z
  aplikacji.
- Autor nie sprzedaje, nie wynajmuje ani nie udostępnia danych - nie ma żadnych.
- Żadnego profilowania ani algorytmu rekomendacji.
- Żadnego czytania książki adresowej, zdjęć ani plików poza tym, co wybierzesz.

## 9. Podstawy prawne i szczególne kategorie danych (RODO UE / UK GDPR)

Ponieważ autor nie przetwarza Twoich danych na żadnym serwerze, większość
przetwarzania odbywa się przez **Ciebie i Twoje urządzenia** (na przykład w
ramach czynności czysto osobistych lub domowych). W zakresie, w jakim RODO
dotyczy działalności autora, zamierzonymi podstawami są: wykonanie usługi, o
którą prosisz (art. 6 ust. 1 lit. b), oraz prawnie uzasadniony interes w
udostępnianiu bezpiecznego narzędzia do komunikacji (art. 6 ust. 1 lit. f).

Dwie części Zen dotyczą **szczególnych kategorii danych** (art. 9):

- **Piramida** (opinie, głosy, komu powierzasz zaufanie) może ujawniać poglądy
  polityczne.
- **Randki** (płeć, kim jesteś zainteresowany, zdjęcia, preferencje) mogą
  ujawniać życie seksualne lub orientację.

Obie są **wyłączone, dopóki nie zdecydujesz się z nich skorzystać**, a na każdą
wyrażasz **wyraźną zgodę**, tworząc profil randkowy lub dołączając do
piramidy. Możesz w każdej chwili wycofać zgodę, opuszczając piramidę albo
wyłączając randki i usuwając profil (kopie, które inni już otrzymali, i
podpisane wpisy piramidy mogą pozostać - zob. sekcję 10). Nie umieszczaj w tych
funkcjach danych szczególnych kategorii innych osób bez ich zgody.

## 10. Twoje prawa, przechowywanie i usuwanie danych

Ponieważ dane są na urządzeniach, **to Ty kontrolujesz kopię na swoim
urządzeniu** i większość praw możesz wykonać sam:

- **Dostęp / kopia:** dane są na Twoim urządzeniu; funkcje pozwalają
  eksportować pliki.
- **Sprostowanie:** edytuj swój profil i posty; zmiany profilu są wysyłane
  znajomym jako aktualizacje. Edycje postów są nowymi podpisanymi wpisami.
- **Usunięcie na Twoim urządzeniu:** Ustawienia -> *Usuń wszystkie dane*
  najpierw kasuje klucze, potem pliki, ustawienia, pamięć podręczną i pliki
  wyeksportowane przez Zen, i uruchamia aplikację od nowa. **Hasło awaryjne**
  robi to samo na żądanie. Odinstalowanie aplikacji usuwa jej dane w
  większości systemów (kopiami zapasowymi platformy zarządza Twój system). "Usuń
  z mojego urządzenia" usuwa zgłoszone multimedia z Twojego telefonu.
- **Usuwanie tego, co mają inni:** Zen wysyła znajomym sygnał usunięcia tam,
  gdzie funkcja go ma (na przykład usunięcie znajomości, znikające wiadomości z
  licznikiem, usunięcie postu lub zdjęcia z galerii), a poprawnie działające
  aplikacje go respektują. **Nikt - także autor - nie może zmusić urządzenia
  innej osoby do usunięcia kopii.** Podpisane wpisy dziennika, wpisy piramidy
  i kopie przechowywane przez znajomych lub znajomych-skrzynki mogą pozostać
  (kopie w skrzynkach wygasają najpóźniej po 14 dniach).
- **Ograniczenie / sprzeciw / przenoszenie:** użyj opcji w aplikacji
  (widoczność, ukrywanie, blokowanie, opuszczanie grup i piramid, wyłączanie
  funkcji).
- **Skargi:** jeśli jesteś w UE / EOG, możesz złożyć skargę do swojego organu
  ochrony danych (w Polsce: Prezes Urzędu Ochrony Danych Osobowych, UODO). W
  Wielkiej Brytanii: ICO.

Okres przechowywania ustalasz Ty i liczniki poszczególnych funkcji. Autor nie
przechowuje żadnych danych osobowych użytkowników Zen. Repozytorium na
GitHubie przechowuje wszystko, co tam opublikujesz (zgłoszenia, komentarze),
na zasadach GitHuba - **nie publikuj prywatnych danych w publicznych
zgłoszeniach.**

Jeśli chcesz zapytać autora o coś w sprawie tej polityki lub danych osobowych
na stronie GitHuba, skorzystaj z sekcji 13. Autor nie może wyszukać "Twojego"
konta, bo takie nie istnieje.

## 11. Dzieci i ograniczenia wiekowe

- **Zen nie ma ograniczenia wiekowego.** Nie sprawdza niczyjego wieku i o niego
  nie pyta, z jednym wyjątkiem: **Piramida** pyta o rok urodzenia przy
  dołączaniu, przyjmuje członków w każdym wieku i pokazuje wiek w Twoim
  profilu piramidy pozostałym członkom, potwierdzony przez osobę, która Cię
  przyjęła (sekcja 3.2). To, co wpiszesz, nie jest sprawdzane z żadnym
  dokumentem, a autor nie może zweryfikować wieku ani zgody rodzica; to
  odpowiedzialność użytkowników i rodziców.
- **Randki i portfel nigdy nie pytają o wiek**, a lampiony randkowe nie
  zawierają wieku. Regulamin mówi, że randki są przeznaczone dla dorosłych, ale
  aplikacja tego nie sprawdza. Jeśli w randkach zobaczysz kogoś, kto jest
  wyraźnie niepełnoletni, użyj "zgłoś osobę niepełnoletnią" (od razu ukrywa
  profil na Twoim telefonie), zablokuj go i powiedz zaufanemu dorosłemu;
  nielegalne treści możesz zgłosić tak, jak opisano w docs/TERMS.md.
- Zen nie jest przeznaczony dla dzieci ani do nich kierowany. Jeśli uważasz,
  że dziecko korzysta z aplikacji w szkodliwy sposób, powiedz o tym jego
  rodzicom lub odpowiednim organom; autor nie ma możliwości zidentyfikowania
  użytkowników ani skontaktowania się z nimi.

## 12. Bezpieczeństwo i incydenty

Zen korzysta z nowoczesnej kryptografii, a projekt jest otwarty do wglądu (w
SECURITY.md opisano, jak prywatnie zgłosić podatność). Żadne oprogramowanie
nie jest w pełni bezpieczne. Ponieważ autor nie przechowuje danych
użytkowników, autor nie ma czego ujawnić, ale błąd w aplikacji mógłby narazić
dane na Twoim urządzeniu lub w trakcie przesyłania. Jeśli zostanie znaleziony
poważny problem z bezpieczeństwem, autor opublikuje poprawkę i informację w
GitHub Releases / repozytorium.

## 13. Kontakt

- Pytania o prywatność i ogólne prośby: utwórz zgłoszenie na
  https://github.com/robertostrowskijagoda/Zen/issues (nie podawaj prywatnych
  danych) i w razie potrzeby poproś o sposób dalszego kontaktu prywatnie.
- Podatności bezpieczeństwa: **nie** twórz publicznego zgłoszenia; użyj
  prywatnego formularza opisanego w `SECURITY.md`
  (https://github.com/robertostrowskijagoda/Zen/security/advisories/new).

## 14. Zmiany

Ta polityka może się zmienić, gdy zmieni się Zen. Aktualna wersja jest w
repozytorium w docs/PRIVACY.md (po polsku: docs/PRIVACY.pl.md) i jest dostępna
z ekranu "O aplikacji"; historia zmian jest w dzienniku zmian repozytorium.
Nowa wersja obowiązuje od wydania Zen, które do niej prowadzi.
