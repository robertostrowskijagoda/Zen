# Testowanie

Od najszybszego do najbardziej „prawdziwego”:

1. **Testy i symulator sieci** — `flutter test`, dziesiątki telefonów
   w jednym teście, z wirtualnym zegarem.
2. **Kilka aplikacji na jednym komputerze** — prawdziwe aplikacje (osobne
   dane, klucze i węzły), sterowane skryptem.
3. **Telefon** podłączony kablem — ta sama metoda przez `adb forward`.
4. **Przegląd wyglądu** — wszystkie ekrany w kilku rozmiarach.

Do tego testy mostu Go (`go test` w `native/yggdrasil_bridge`,
`test_native.ps1`), sprawdzanie tłumaczeń (punkt 5) i GitHub Actions przy
każdym pushu (punkt 6).

## 1. Symulator sieci (`lib/src/dev/sim/sim_network.dart`)

`SimNetwork` to sieć telefonów w pamięci:

- wirtualny zegar (`advance(Duration(days: 61))` trwa milisekundy; usługi
  dostają `now: () => net.now`);
- opóźnienia z ziarna (przebieg powtarzalny), gubienie (`dropRate`),
  wyłączone telefony (`setOnline(p, false)`, `holdForOffline`), rozcięcie
  sieci (`partition(a, b)` / `heal()`);
- graf znajomości: `befriend`, `chain`, `randomGraph(degree: 3)`;
- `SimPhone` udaje `EventHost`, więc podłącza się do niego prawdziwe usługi
  (piramida, randki, sąsiedzi…);
- `stats` (dostarczone / zgubione / czekające) i `trace`.

Gotowy świat: `test/support/pyramid_world.dart` (`PyramidWorld.six()`,
`join`, `approve`, `approveAll`, `sync`, `duties`, `views`).

| Plik | Co sprawdza |
|---|---|
| `test/pyramid_core_test.dart` | podpisy pierścieniowe, zasady, składanie stanu |
| `test/pyramid_sim_test.dart` | przyjmowanie, zamiana i anonimowe głosowanie, referendum drzewem, emisja + przelew + weto, zgłoszenie + komunikat kryzysowy, chaos (30% strat, wyłączone telefony, rozcięcie → po naprawie wszyscy widzą to samo), sfałszowane rekordy |
| `test/pyramid_scenarios_test.dart` | delegacje, immunitet, ban randkowy, migracja, nieobecność, usunięcie, konstytucja, sekcja krajowa, płatna skrzynka, ogłoszenie, łączenie piramid |
| `test/pyramid_security_test.dart`, `test/pyramid_attack_sim_test.dart` | ataki na piramidę |
| `test/dating_test.dart`, `test/neighbors_test.dart` | randki i sąsiedzi na kilku telefonach |

Testy regresyjne bezpieczeństwa: `STAN.md` §4.4.

Nowy scenariusz: zbuduj świat, wykonaj akcje, `await w.net.run()`, sprawdź
stan u **innej** osoby niż ta, która działała, na końcu
`expect(w.views().values.toSet(), hasLength(1))`.

## 2. Kilka aplikacji na jednym komputerze

**Profil:** `zen.exe --zen-profile=ala` (albo `ZEN_PROFILE=ala`) — osobny
folder danych (`…\Zen\profiles\ala`), osobne klucze, druga instancja
dozwolona, przy zajętym porcie 32913 węzeł bez nasłuchu, w wersji debug bez
hasła aplikacji, nazwa profilu w tytule okna.

```
powershell -File tool\multi_client.ps1 -Count 4          # buduje i startuje 4 (sim1, sim2, …)
powershell -File tool\multi_client.ps1 -Count 4 -NoBuild # bez budowania
powershell -File tool\multi_client.ps1 -Count 4 -Show    # okna widoczne (domyślnie zminimalizowane)
powershell -File tool\multi_client.ps1 -Stop             # zamyka profile testowe
```

**Pilot** (`lib/src/features/runtime/test_harness_server.dart`,
`test_harness_features.dart`): tylko w wersji debug, na
`127.0.0.1:48888…48895` (pierwszy wolny port), wymaga nagłówka
`x-zen-harness: 1`. Oprócz `/status`, `/friend/request`, `/friend/accept`
i czatów:

| Ścieżka | Co robi |
|---|---|
| `/x/state` | stan piramidy, propozycje, randki, mieszkanie |
| `/x/pyramid/create` `{name, me, nat, year, g}`, `/invite`, `/join` `{code, me, …}`, `/approve` `{type?}` | zakładanie i przyjmowanie |
| `/x/pyramid/post` `{text}`, `/swap` `{cell, up}` | post, zamiana w komórce |
| `/x/pyramid/referendum` `{q, opts, minutes}`, `/vote` `{ref?, opt}` | referendum i głos |
| `/x/pyramid/emit` `{to, amount}`, `/pay` `{to, amount, memo}` | waluta |
| `/x/pyramid/duties`, `/greet` | obowiązki, synchronizacja |
| `/x/dating/enable`, `/publish`, `/decide` `{name, yes}` | randki |
| `/x/flat/create`, `/door`, `/scan` `{code}` | sąsiedzi |

**Skrypt** `tool/zen_drive.dart`:

```
dart run tool/zen_drive.dart find                       # kto słucha i na jakim porcie
dart run tool/zen_drive.dart status 48888 48889         # /x/state wszystkich
dart run tool/zen_drive.dart friends 48888 48889 48890  # znajomości po kolei
dart run tool/zen_drive.dart pyramid 48888 48889 48890 48891
dart run tool/zen_drive.dart flats 48888 48889
dart run tool/zen_drive.dart call 48888 /x/pyramid/post '{"text":"hej"}'
```

`pyramid` zaprzyjaźnia aplikacje w drzewo, zakłada piramidę, przyjmuje
kolejne osoby, sprawdza wspólny obraz struktury, wysyła post, ogłasza
referendum, głosuje i czeka na policzenie; każdy krok czeka na wynik
u innych (`✓` / `✗ nie doczekałem się`).

## 3. Telefon

1. Włącz debugowanie USB i zaakceptuj na telefonie „Zezwolić na
   debugowanie USB?” (inaczej `adb devices` pokazuje `unauthorized`).
2. `flutter install` (debug) albo `flutter run -d <id>`.
3. `powershell -File tool\multi_client.ps1 -Count 3 -NoBuild -Phone`
   (ustawia `adb forward tcp:48900 tcp:48888`).
4. `dart run tool/zen_drive.dart pyramid 48900 48888 48889 48890`.

Telefon łączy się z aplikacjami na komputerze prawdziwą siecią Yggdrasil.

## 4. Przegląd wyglądu (`tool/ui_tour/ui_audit_test.dart`)

```
flutter test tool/ui_tour/ui_audit_test.dart --update-goldens
AUDIT_ONLY=p320,desk flutter test tool/ui_tour/ui_audit_test.dart --update-goldens
```

Test zakłada dane (piramida, wydarzenie, kółko, pytanie, mieszkanie,
randki, czaty) i przechodzi przez wszystkie zakładki i ekrany w sześciu
konfiguracjach: `p360` (360 dp), `p360big` (tekst 130%), `p412light`
(jasny), `p320`, `p320big` (tekst 150%) i `desk` (1280 × 800, układ
Windows). Każdy błąd układu (przepełnienie, nachodzenie) jest zbierany
zamiast przerywać test: lista w `scratch/audit/<konfiguracja>.txt`, zrzuty
w `scratch/audit/<konfiguracja>/` (poza repozytorium). `AUDIT_ONLY`
zawęża konfiguracje. Test kończy się „niezaliczony” z powodu timerów
aplikacji — liczy się lista problemów.

Języki: przegląd idzie po polsku (testy nie wczytują tłumaczeń). Długość
tekstów w innych językach (niemiecki, rosyjski) i układ od prawej do lewej
(arabski) trzeba dziś obejrzeć ręcznie: Ustawienia → Język.

## 5. Tłumaczenia

Teksty w kodzie są po polsku w `t('…')` i `tn(n, one: …, few: …, many: …)`
(`lib/src/app/i18n/zen_i18n.dart`), tłumaczenia — w
`assets/i18n/<kod>.json` (20 plików; polski nie ma pliku).

```
dart run tool/i18n.dart            # sprawdza wszystko; kod wyjścia 1 przy problemie
dart run tool/i18n.dart --verbose  # pełna lista brakujących i nieaktualnych tekstów
dart run tool/i18n.dart --keys     # wszystkie teksty kodu jako JSON (do tłumaczenia)
dart run tool/i18n.dart --prune    # usuwa nieaktualne teksty i sortuje pliki
```

Sprawdzenie zgłasza: wywołania `t()` / `tn()` z czymś innym niż zwykły
napis (zmienna, sklejanie, `$x`), a w każdym pliku języka brakujące teksty,
teksty, których kod już nie ma, i niezgodne wstawki `{name}`. Po zmianie
albo dodaniu polskiego tekstu: `--keys`, dopisać tłumaczenia we wszystkich
plikach (pod tym samym polskim kluczem, z tymi samymi wstawkami; formy
liczby mnogiej według CLDR danego języka), na koniec `--prune` i ponownie
bez opcji.

`test/i18n_test.dart` (część `flutter test`, więc i CI) sprawdza warstwę
tłumaczeń (wstawki, brak tłumaczenia = tekst polski, formy liczby mnogiej
po polsku, angielsku, rosyjsku i arabsku, wybór języka: wybrany, potem
pierwszy język systemu, potem angielski, wczytywanie plików) i repozytorium
tak samo jak `tool/i18n.dart`: każdy plik ma dokładnie teksty z `lib/`,
a `assets/i18n` tylko języki, które Zen zna.

## 6. GitHub Actions

`.github/workflows/ci.yml` — przy każdym pushu na `main`, pull requeście
i ręcznie (Actions → CI → Run workflow):

| Zadanie | Gdzie | Co robi |
|---|---|---|
| Analyze and test | Windows | `dart format` (bez zmian), `flutter analyze`, `flutter test` (w tym tłumaczenia) |
| Go bridge | Windows | `go vet` i `go test` mostu |
| Linux build | Ubuntu | `flutter build linux --release` (most buduje się sam), symbol `YggStartNode` w `libyggdrasil_bridge.so`, start pod Xvfb — aplikacja ma działać po 20 s |
| macOS build | macOS | most (`build_macos.sh`), `flutter build macos --release`, symbol `_YggStartNode` w `Zen.app`, start na 20 s; bez pull requestów (droższe minuty) |

`release.yml` przy tagu `v*` buduje wszystkie pliki wydania, także Linux
ARM64 i iPhone (`WYDANIA.md` §3). Linux i macOS nie przeszły jeszcze
pierwszego przebiegu — po wypchnięciu sprawdzić oba zadania; gdyby start
pod Xvfb był niestabilny, zostaje budowanie i sprawdzenie symbolu.

## Czego to nie sprawdza

- Symulator nie testuje Bluetooth ani prawdziwych opóźnień Yggdrasil.
- Usługa w tle Androida ma mało testów, kod Kotlin (BLE, rozmowy) — żadnych.
- Testy aplikacji idą w CI tylko na Windows; na Linuksie i macOS CI tylko
  buduje i uruchamia aplikację na 20 s. Nie ma budowania APK przy pushu
  ani testu na emulatorze.
- Most Go nie ma testów z losowym wejściem (`go test -fuzz`), a aplikacja
  — testu „uszkodzone dane nie wysyłają żadnej ramki” (`STAN.md` A13).
- Pilot działa tylko w wersji debug.
- Aplikacje na jednym komputerze dzielą jedno łącze: rozcięcie sieci
  testuje się w symulatorze.
