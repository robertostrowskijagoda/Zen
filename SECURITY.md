# Bezpieczeństwo

*English below.*

## Jak zgłosić podatność

Zgłaszaj **prywatnie**, przez GitHuba:

**https://github.com/robertostrowskijagoda/Zen/security/advisories/new**

(albo zakładka **Security → Report a vulnerability** w tym repozytorium).
Zgłoszenie widzisz tylko Ty i opiekun projektu. Proszę **nie** zakładać
publicznego Issue ani pull requesta z opisem podatności, zanim nie będzie
poprawki. Jeśli nie możesz użyć tej drogi, załóż Issue z prośbą o kontakt —
bez żadnych szczegółów.

Co napisać (po polsku albo po angielsku):

- wersja Zen i system (Android, Windows, Linux, macOS, iPhone);
- kroki do odtworzenia i co się dzieje zamiast tego, co powinno;
- skutek: co zyskuje atakujący i jakie warunki są potrzebne;
- dowód (PoC), jeśli jest — bez prawdziwych danych innych osób.

## Zakres

- **Aplikacja Zen** na wszystkie systemy (`lib/`, `android/`, `ios/`,
  `windows/`, `linux/`, `macos/`).
- **Most Go** (`native/yggdrasil_bridge`): węzeł Yggdrasil, sygnalizacja,
  przekaźnik.
- **Proces wydań**: workflowy GitHub Actions (`.github/workflows`), podpis
  APK, `SHA256SUMS`, pliki w Releases.
- **Strona zaproszeń** (`tool/pages`,
  https://robertostrowskijagoda.github.io/Zen/).

Poprawki dostaje tylko **najnowsze wydanie**. Błędy w Yggdrasil, Flutterze
czy bibliotekach zgłaszaj ich autorom — ale daj znać i tutaj, jeśli
dotykają Zen. Kopia Zen z innym kluczem podpisu nie jest oficjalnym Zen;
jeśli ktoś rozpowszechnia podróbkę jako Zen, zgłoś to tą samą drogą.

**Oficjalna kopia:** odcisk certyfikatu APK (SHA-256) jest w
[README](README.md), w sekcji „Czy to nie wirus? Jak sprawdzić”, i w opisie
każdego wydania; obok plików wydania jest `SHA256SUMS`.

## Czego się spodziewać

Zen tworzy **jedna osoba**, po godzinach. Odpowiadam najszybciej, jak mogę
(best effort), ale bez gwarantowanych terminów. Zwykle: potwierdzenie
zgłoszenia, ocena, poprawka w kolejnym wydaniu, a potem publiczne advisory
— z podziękowaniem, jeśli chcesz być wymieniony. Proszę o czas na poprawkę
przed publikacją szczegółów; datę ujawnienia ustalimy razem.

**Nie ma programu bug bounty** — Zen jest darmowy i nie ma za nim firmy,
więc nie ma nagród pieniężnych.

## Zasady testowania

- Testuj **tylko na własnych urządzeniach, kontach i sieciach** (np. kilka
  własnych telefonów albo komputerów, własny węzeł lub most Yggdrasil).
- **Nie testuj na cudzych telefonach, komputerach ani sieciach** i nie
  wysyłaj niczego szkodliwego ludziom, którzy się na to nie zgodzili.
- Nie przeciążaj publicznych węzłów Yggdrasil i nie próbuj sięgać po
  cudze dane.
- Słabości procesu wydań opisz w zgłoszeniu; nie próbuj ich wykorzystać na
  tym repozytorium (pull requesty, tagi, próby dostania się do sekretów).

---

## English

**Report vulnerabilities privately** via GitHub private vulnerability
reporting:
https://github.com/robertostrowskijagoda/Zen/security/advisories/new
(Security tab → *Report a vulnerability*). Please do not open public issues
or pull requests about a vulnerability before a fix is released. Reports in
Polish or English are welcome.

**In scope:** the Zen app (all platforms), the Go bridge
(`native/yggdrasil_bridge`), the release pipeline (GitHub Actions, APK
signing, `SHA256SUMS`, release files) and the invite page
(`tool/pages`, robertostrowskijagoda.github.io/Zen). Only the latest release
is supported. The official APK certificate fingerprint (SHA-256) is in the
[README](README.md) (section “Czy to nie wirus? Jak sprawdzić”) and in every
release description.

**Expectations:** Zen is maintained by one person; responses are best
effort, with no guaranteed timelines. Please allow time for a fix before
disclosure. **There is no bug bounty.**

**Testing:** only on your own devices, accounts and networks — never on
other people's devices or networks, never against public Yggdrasil nodes,
and do not try to exploit the release pipeline of this repository.
