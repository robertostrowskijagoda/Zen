# Project status

Status as of 20 Oct 2026 (version 1.11.0). What works, known bugs, open
problems (security, architecture, concept, distribution) and the order of
work. Plan and description of solutions: `PLAN.md` (references §N.M).
Releases and distribution channels: `RELEASES.md`. Testing: `TESTING.md`.
Replaces the former `KIERUNKI.md` and `AUDYT_BEZPIECZENSTWA.md`.

Priority: **P1** — before wider release, **P2** — soon, **P3** — later.
Size: **S** (days), **M** (weeks), **L** (a month or more).

`file:line` references come from reviews done before the whole code base
was formatted (`dart format`) and texts were wrapped in `t()`, so line
numbers may be off by a few. Reviews of 14 Oct 2026: second security audit
(§4.2), architecture and product review (§5, §6), code-vs-plan conformance
(§10), distribution research (§9), Linux and macOS (§1). Round of
20 Oct 2026: version 1.11.0 (summaries of the individual areas; details in
`CHANGELOG.md`).

---

## 1. What works today (1.11.0)

- **Platforms:**
  - **Android** (package `com.roj.zen`): one universal `Zen.apk` with three
    ABIs — arm64-v8a, armeabi-v7a (older 32-bit phones) and x86_64
    (ChromeOS, emulators); native libraries are stored compressed so three
    ABIs do not make the file ~2.5x bigger. 32-bit x86 is not supported
    (Flutter has no release engine for it). An **`appStoreOnly` flavor** (Play,
    Galaxy Store) exists, built by hand: no `REQUEST_INSTALL_PACKAGES`, no
    self-update, "Pass it on" becomes a link (D12).
  - **Windows** x64 (`Zen-Windows.zip`); **Windows ARM64** is new and
    experimental (`Zen-Windows-arm64.zip`, native build on `windows-11-arm`;
    the x64 build also runs on Windows 11 ARM under emulation).
  - **iPhone** (SideStore / AltStore with a free Apple ID, no background
    work; GitHub Actions builds `Zen-unsigned.ipa`).
  - **Linux** (x64 and ARM64): `Zen-Linux-x64.tar.gz`,
    `Zen-Linux-arm64.tar.gz` and new `.deb` packages; audio/video playback
    through GStreamer (own `video_player` backend; AAC/H.264 need
    `gstreamer1.0-libav`; without GStreamer playback simply reports "cannot
    play"), a `.desktop` file (menu, `zen://` links, icon on Wayland),
    AppStream, single-instance runner; key in GNOME Keyring / KWallet.
  - **macOS** (Apple Silicon and Intel, from macOS 12): `Zen-macOS.zip`,
    Touch ID through the Secure Enclave, no sandbox (§2).
  - Linux, macOS and Windows ARM64 are built in CI without signing and are
    **unverified until the first CI run passes** (nothing has actually been
    built yet). On desktops: no Bluetooth, call recording or camera.
- **Languages:** 21 — Polish (source language), English, German, French,
  Spanish, Italian, Portuguese, Dutch, Czech, Hungarian, Romanian, Turkish,
  Russian, Ukrainian, Arabic (right to left), Hindi, Indonesian, Vietnamese,
  Simplified Chinese, Japanese, Korean. Default: automatic, from the system
  language (English when Zen does not know it); change in **Settings →
  Language**, instantly, no restart. The lock screen and the background
  service (notifications) use the same language. Texts in code are Polish
  inside `t()` / `tn()`, translations in `assets/i18n/<code>.json`
  (`lib/src/app/i18n/zen_i18n.dart`); consistency is checked by
  `dart run tool/i18n.dart` and `test/i18n_test.dart`. New in 1.11.0:
  everything outside the Dart UI is English by default and translated into
  the 21 languages where the platform allows — the invitation page
  (language from `navigator.languages` or `?lang=xx`, RTL for Arabic),
  iOS/macOS `Info.plist` and `InfoPlist.strings`, Android `strings.xml` plus
  `values-<lang>` (incl. the incoming-call screen, notification, PiP,
  biometrics, installer), Linux `.desktop` `Comment[xx]`, release notes.
- **Messenger:** chats, groups, audio and video calls (also group),
  offline mailboxes at friends, disappearing messages, screen sharing,
  explicit recording, call in a floating window. **Photos, videos, files
  and longer voice notes now also wait in the recipient's mailboxes when
  they are offline** (encrypted blobs, up to 24 MB; sender's quota
  per friend 20 MB by default, Settings → Offline mailboxes →
  "Attachments"; the live WebRTC path stays the fast route; B12, A18; falls
  back to "only when both are online" for friends on 1.10.0). Message
  status is honest: delivered after `message_ack`, error after 14 days
  without pickup. Screen sharing: system notifications are shown without
  content for its duration (1:1 and group), a permanent red bar "You are
  sharing your whole screen — everything is visible, including
  notifications", a warning before start on Android < 14. A sound (two beeps +
  haptics) when recording starts, for the recorder and the other
  participants. Group **Board** tab (a post is a normal group message with
  an id `grp-board-…`; older participants see it as an ordinary message). GIFs
  from the **klipy.com** search (third party, contacted by the sender's device
  only; the chosen GIF is downloaded by the sender and sent as an ordinary image
  attachment, so the recipient never contacts klipy.com; S29, S37).
- **Account:** password, recovery circle (up to 6 people: password + 2 after
  24 h or 4 without a password after 7 days), several devices on one
  account, chat history on a new device. New: **paper backup of the
  account key** (56 base32 characters in 14 groups of 4, QR `zen-key:<code>`;
  screen requires the app password, shows warnings, checks 2 random groups;
  restore by typing or scanning, with the account fingerprint to confirm), a
  "Secure your account" card after the permissions step (circle / paper
  backup / later) and a reminder in Settings until one of them is done.
- **Profile and feed:** profile with gallery and gratitude cards, posts with
  visibility (default "All friends"), sharing, likes, comments, following,
  "Report". New: **per-field visibility** (status, About me, photo, cover,
  nationality, friend count, follower count — Public / All friends /
  Friends and close friends / Close friends / Only me), nationality (up to 3
  country codes), **mini-profile** (photo, name, status, badges, counts,
  Profile / Message or Add / Follow buttons), other people's profiles with
  tabs Posts · Photos · Videos · Thanks · Info; **follower list and count**
  and blocking a follower; "Liked by: You, Bob and 1,284 others" (you and
  friends first); the author can hide comments and block people in their
  threads; like/comment bundles are paged (up to 2000 likes / 300 comments);
  aggregated notifications in the bell on the Feed (in-app only); videos
  stripped of metadata (MP4/MOV/M4A); a deleted post's tombstone reaches the
  resharer's friends. Own avatar and cover are now encrypted in the media
  vault (§14.1).
- **Meetings:** "right now" statuses (10 kinds + custom), alarm with
  location, recording, delivery confirmations and a Bluetooth wave, people
  nearby (Android), events with tickets pinned to the phone, Table for
  Six, dinner circles, weekend plan, Ask the network, graph, introductions
  and letters through a mutual friend. New: **graph** zoom (pinch/drag, 1–8x,
  +/− buttons), clusters (label propagation over "know each other"), labels
  of friends of friends at ≥ 2x, "See profile" on the person card; **alarm**
  from the shortcut with the app in the background takes a fresh location
  (foreground service of type `location`, falls back to last known) and a
  **fallback SMS** (up to 5 numbers stored on this phone only; the button
  opens the system SMS app, the app has no `SEND_SMS`); **dinner circles** of
  4–8 people enforced, "pairs circle", "the one who brings a guest vouches",
  shared kitty (a local list of contributions inside the circle); **Ask the
  network** answers are signed with the answering device's key (changed
  content/name/tip key is rejected; old unsigned ones get an "Unsigned…" mark);
  **Common cause** (a plan with a list of needs, "I'll take it" claims, quantity
  limit at the organizer, no money).
- **Nearby (§15):** per-friend keys (S6) and a greeting without a stable
  address (S5), rotation every 10 min in sync with the Android MAC, persistent
  blocks with "Unblock", "1 message from a stranger until you reply"
  enforced at the receiver, badges next to strangers (distance, "wrote to you",
  "waiting for reply", "you are chatting", "older Zen version").
- **Neighbors (§18):** door code (flat key + sticker password + name + the
  address of the flat's **door**: a second, minimal Yggdrasil node with its own
  random key that the phone runs next to its own node, peered over loopback,
  taking only knocks; "New code" gives it a new key; never a resident's
  address), link `https://…/Zen/m#<code>` and `zen://m/<code>` open the knock in
  Zen, a `/m` page (English + Polish), invitation chat ("Ask" button on an
  invitation).
- **Dating (§19):** full mechanisms plus: **location on demand** for "I'm
  going on a date" (the watching friend taps "Ask for location"; the date's
  phone asks consent or answers by itself if the person allowed it at start;
  one request per 2 min), **"Report an underage person"** (disables the profile
  locally at once, files a pyramid report, and a phone that opens date packets
  from ≥ 2 different reporters' dating keys disables the profile too), **re-
  confirmation** (password/biometrics on entering Dating and after ≥ 10 s in
  the background) on top of the screenshot block.
- **Pyramid, power, currency, access market** (§20–24) — done in code, visible
  in the app, can now be hidden by feature flags; no parties; merging pyramids
  with balance conversion and exchange through the "exchange office". **Rules
  generation 2** (`kPyrRules = 2`, new pyramids): turnout of binding referenda
  counted from active members, full branch sum with a time limit, a record whose
  rule throws leaves no trace (S18), **issuing above the limit by referendum**,
  national-section pinning (max 3), age/gender badge and anonymous branch
  statistics (from 5 people), "reached / read" counters, escalation of
  reports level by level, 24 h / 7 d / 30 d pauses, price list on the profile,
  **paid introduction** (the broker is paid only after the introduced person says
  "yes", otherwise refund), admission of a friend only at level "Acquaintance"
  or higher, reports with the signed original entry (S36).
- **Resilience:** bridges on desktops (UPnP/NAT-PMP, port 443) now behind a
  Go intermediary with limits (4 connections per IPv4 / per /64, 128 total,
  1 MiB/s per source, 2 GiB per source and 32 GiB total per day), "Pass it on"
  (hotspot, Wi-Fi, Quick Share, USB from a computer, with APK signature check;
  listens on one chosen interface), one QR code leading to the invitation page.
  DNS on Android: the system resolver first (incl. Private DNS), fallback list
  over DNS-over-TLS. The call UDP relay on desktops listens only on loopback
  and accepts a local socket only after a matching ICE check.
- **Data protection:** encryption with the master key (also attachments, voice
  notes and friends' photos; own avatar and cover included), key in
  Keystore/TPM/Secure Enclave, lock after 5 min in the background, screenshot
  block, panic password, root warning. Offline-mailbox attachments are stored
  encrypted in `relay/blob/…`. File names of `meet/list/` and `ledger/` are
  hidden (HMAC); Windows data in `%LOCALAPPDATA%`; "Media only over Wi-Fi"
  (default on for new installs); all clipboard copies expire after 60 s.
- **Privacy defaults (§8, §9):** friend list shown to "Friends and close
  friends" (a weak friend gets an empty list and can ask via "Introduce me"),
  a weak friend sees no statuses except "Do not disturb", group invites from
  below the chosen level are rejected at once (Settings → Privacy → Group
  invites, default "Friends and close friends"), a public ledger profile
  carries the device address only after the first public post or share. After
  meeting in person (QR, Nearby, "We met" at an event) the app asks "How close
  do you know each other?". The recovery circle and mailbox slots go to close
  friends first. There is no age gate: Dating, the Pyramid and the Wallet do not
  ask for age. Dating asks only for the age on the dating profile (needed for
  matching); the Pyramid asks for an optional birth year when joining, for the
  badge and statistics (§20.2a), and skipping it blocks nothing.
- **First run:** a short "Welcome to Zen" card, password, then the permissions
  screen — location, background location (Android 10+), exact alarms
  (Android 12+), Bluetooth, battery instructions per manufacturer (Xiaomi,
  Samsung, Huawei, OnePlus, Oppo/Realme, Vivo + generic) — the same in
  Settings (§25.2).
- **Diagnostics and UX:** **"Why isn't it working?"** screen (network, node and
  neighbors, background work, notifications, battery, clock, free space, with fix
  buttons and "Copy report" without addresses; from Settings and from the "?" in
  the connection bar), a clock-skew bar ("Your clock is 14 min fast" — needs ≥ 2
  friends and > 2 min difference), tab bar with 6 tabs (Graph, Profile, Chats,
  Feed, Meetings, Neighbors) + "More" (Meetings: Dating, People nearby;
  Community: Pyramid, Wallet; Other: Invite, About) + Alarm; semantics for the
  alarm button, graph nodes and tab cards.
- **Versions and flags:** ping/pong carry `ver`, `build` and `caps`; a quiet bar
  in Settings "Friends have a newer Zen version (X)" (the version is only the
  friend's declaration, nothing security-related depends on it); unknown ledger
  spaces `<kind>/<account>` are stored for the owner (limit 1000 entries per
  device log); **feature flags** (Pyramid, Wallet, Dating, Neighbors; default on;
  Settings → Experimental features; `--dart-define=ZEN_FEATURE_*`,
  `ZEN_FEATURES_LOCKED=true`) hide the tabs and `ZenCore` does not start the
  feature's services (the data stays); formats
  with `v: 1` for settings, profile and flags; golden protocol frames
  (`test/wire/golden_frames_test.dart`).
- **Performance:** AES-GCM of stores and ChaCha20 of post media above 64 KB and
  parsing of big signals run in a short-lived isolate (same bytes on disk and on
  the wire); the Feed is recomputed only when the ledger, friends, names or language
  change (`FeedMemo`) and is a lazy `ListView.builder`; the 20 MB file
  limit: warning from 50 %, stronger zstd from 75 %, orphaned `*.tmp` swept at start.
- **Release integrity (§14.2, §14.3):** the signed release manifest now also
  covers the donation link, author, repository and mirrors; the app remembers the
  newest signed data, passes it on and shows a red warning if its own
  `kDonationUrl`/author/repository differ; **canary** statement (`zen_canary`, 2
  of 3 signatures, passed friend to friend, warning after `until`); tool
  `tool/zen_release.dart` (`maintainers`, `canary`, `sums`, `fingerprint`,
  `create`, `sign`, `verify`). Updates over the network are still off (empty
  `kReleaseMaintainers`).
- **Legal and documentation:** `docs/PRIVACY.md` (privacy policy: age min. 16,
  dating 18+, klipy.com, buycoffee.to, Yggdrasil nodes), `docs/TERMS.md`,
  `docs/DPIA.md` (draft impact assessment), `docs/PROTOCOL.md` (protocol
  specification derived from the code, marks [V]/[P]/[?]) — all in English,
  drafts, not legal advice; two tiles in About (Privacy policy, Terms).
  `SECURITY.md` and private vulnerability reporting.
- **License** (14 Oct 2026): anyone, including companies and public offices,
  may use Zen for any purpose; it may not be sold and forks may not be
  published (§2).

Changes of the latest round: `CHANGELOG.md`, 1.11.0.

## 2. Decisions taken

| Decision | Consequence / risk |
|---|---|
| **Bridge on a computer enabled by default, no prompt**; switch "Help others connect" at the bottom of settings (Advanced → Network and service) | Conscious risk: UPnP and port 443 without asking, the computer's IP visible in announcements, the listener `tls://[::]:32913` with the node key reveals whose computer it is (§5.1, §26.1). Since 1.11.0 the public port goes through a Go intermediary with limits (TLS still end to end) |
| **No website**; the website is the repository README, and the only file on GitHub Pages is the invitation page (`tool/pages/index.html`, published by `.github/workflows/pages.yml`; `tool/pages/m/index.html` is the neighbors page) | QR codes lead to `robertostrowskijagoda.github.io/Zen/#CODE`: the page opens Zen (Android `intent://` back to the page when Zen is missing; others `zen://c/CODE`) or shows the download; the README has an "Open in app" button pointing to that page (GitHub strips `zen://` and `intent://` links from READMEs). Pages on the free plan require a public repository. Zen handles both links without domain verification ("Open supported links"). The page is English, language from the browser |
| **A friend's name comes from their profile, not editable; a local nickname under it** | two people may have the same name — told apart by nickname and photo |
| Invitation code without bridges (8 Oct 2026) | a new person starts from public nodes |
| Android package `com.roj.zen` (was `com.HuraganKodu.zen`) | it is a new app: the old installation stays next to it with its data; the account moves by linking a device (§6.5), then the old one can be uninstalled |
| License (14 Oct 2026): PolyForm Strict 1.0.0 with additional permissions — anyone, including companies and public offices, may use Zen for any purpose; reading the code, sending pull requests, building from unchanged code and handing out unchanged releases (same SHA-256) are allowed; selling Zen, charging for access to it or bundling it into paid products and services is not; the author and the fundraiser must stay; forks and modified versions are forbidden | project continuity depends on the author (§6 pt 4); the license is not free (OSI/FSF), so F-Droid and IzzyOnDroid are out (§9); app stores require publication by the author |
| Translations (14 Oct 2026): own `t()` with Polish text as the key and JSON files instead of the ARB from §25.1; 21 languages; the choice is saved in a plain `language.txt` in the data folder (needed before unlock and in the background service) | fixing a Polish text loses its translations, two meanings of the same string get one translation (A23); the chosen language is visible without the password |
| Linux and macOS in releases (14 Oct 2026): archives from CI, unsigned; macOS **without App Sandbox**, ad hoc signature | Zen runs `route`, `adb`, `open` (reason in `macos/Runner/Release.entitlements`); data without a sandbox container; after every update macOS asks for keychain access; since macOS 15 the first launch only through "Open Anyway" (D10) |
| Android store flavor (20 Oct 2026): a separate `appStoreOnly` flavor (label "Zen (sklep)", files `Zen-APP-STORE-ONLY-do-not-install-manually.*`; default stays the full `full`), enabled only by a flavored task (`--flavor appStoreOnly\|full`) or `-Pzen.flavors=true` | ordinary `flutter build apk` / `flutter run` are unchanged; the store build is made by hand (`flutter build appbundle --release --flavor appStoreOnly`), the rest of D12 is not done |
| Android ABIs (20 Oct 2026): one universal APK with three ABIs, compressed native libraries (`useLegacyPackaging`) | the APK is larger; `--split-per-abi` works, but self-update and "Pass it on" assume a single file |
| Linux playback (20 Oct 2026): own GStreamer backend rather than `video_player_media_kit` or `fvp` | media_kit swaps `malloc` of the whole app for mimalloc and hard-depends on libmpv; fvp adds FFmpeg/mdk to every platform; the `.deb` recommends `gstreamer1.0-libav` |
| Heavy work off the UI thread (20 Oct 2026): short-lived isolates (`runSizedWork`, data > 64 KB), disabled under `flutter test`; `cryptography_flutter` **not** adopted | it would replace `Cryptography.instance` app-wide (also Ed25519, which is non-deterministic on Apple CryptoKit, X25519, HKDF…); to do with a device and `--profile` measurement (A19, A32) |
| Alarm fallback SMS opens the system SMS app | no `SEND_SMS` permission, so the user presses send |
| Group board post = a normal group message with a flag in the id (`grp-board-…`) | no protocol or disk-format change; older participants see an ordinary message |
| No age gate anywhere (owner's decision, 21 Oct 2026); the birth year in the Pyramid is optional | no age verification and no restricted mode under 16 (§27) |
| Biometrics off by default; lock after 5 min in the background by default | — |
| AI assistant removed (V1.9) | — |
| Pyramid without parties (14 Oct 2026) | politics is votes and delegation, no electoral lists |
| Contact economy without the pyramid: the currency is consent (friend list on request, introductions, a letter through a mutual friend); prices only on the pyramid market | no currency outside the pyramid — less legal risk (§24.1, §27) |
| Nearby visibility (BLE advertising) enabled on the permissions screen; looking around in the background off by default | friends recognize the phone next to them; scanning only on the "Nearby" screen |
| Prebuilt Go bridge libraries are not in the repository — every build compiles them from source | building needs Go, the NDK and a C compiler (README); Windows ARM64 needs llvm-mingw |
| Fundraiser: `buycoffee.to/zen` (14 Oct 2026) | the link must be removed or replaced in store versions (§9) |

## 3. Known bugs

| # | Bug | Cause / where | Fix | P, size |
|---|---|---|---|---|
| B4 | Storm at startup (partly) | the friend list and "Nearby" keys already go once, only on change; dating packets still all at once | spread packets over time | P3, S |
| B6 | Last write wins | the app and the background service have separate write queues for the same files (`meet_book.dart:708`) | one data owner (A3, A15) | P2, L |
| B7 | Alarm from the shortcut with the app closed: **location now fresh** (1.11.0, foreground service of type `location`, last known as fallback); still **no recording** | — | recording from the background service (§16.3) | P2, M |
| B8 | Android 10–11: background scanning finds nothing — **fixed in 1.11.0**: the permissions screen asks for background location (active only after ordinary location) | system requires background-location consent | (done, §25.2) | — |
| B11 | **Unreadable data deletes friends:** after a failed snapshot read (Keystore/TPM reset, corrupt file and `.bak`, copied Windows profile) the app treats the empty state as loaded, every friend ping gets a reflex `friend_remove` and within ~45 s all friends remove you at their end | `social_hub_controller_lifecycle_signal.dart:194-197`, `runtime_signal_bridge.dart:174-232`, `android_background_runtime.dart:1662-1706` | "corrupt data, read-only" mode, no reflexes (A14) — **fixed in 1.10.0 (round 2)** | P1, S |
| B12 | A message that expired in the mailbox queue (14 days) stayed "sent" in the chat; photos, videos and longer voice notes (> 48 KB) did not go through mailboxes | `relay_engine.dart:47,65,166-247,1505-1513` | honest delivery state, then attachments through mailboxes (A18) — **fixed**: 1.10.0 (round 2) the error mark on expiry and the too-large message returning to "sending"; **1.11.0 attachments through mailboxes** (blobs, `rly_b*` frames, per-sender quota). Remaining: for friends on 1.10.0 (no `cap: blob1`) large messages stay "only when both are online" | — |
| B13 | "Report": reported content cannot be hidden locally and there is no appeal in the UI (only `PyramidService.appeal`); the report window promised "Remove from my device", which did not exist; CHANGELOG claimed it did | `report_sheet.dart:23`, `pyramid_power.dart` | "Hide for me", an "Appeal" button, a truthful text — **fixed in 1.10.0 (round 2)** | P1, S |

Fixed in 1.10.0: friends of friends (B1, B2: lists separately, deferring
frames, shortcuts in the greeting), state saved on every pong (B3), graph
redrawn without pause (B5), "uninstall" advice in ADB (B9), alarm blocked by a
big "Meetings" state (B10).

Performance on a weaker phone (A32): the biggest cost is cryptography and
folding the pyramid (A5) and encryption in pure Dart (A19).
Measure with `flutter run --profile`. 1.11.0 moved large AES-GCM/ChaCha work and
big JSON parsing into isolates and made the Feed lazy and memoized; not
measured on a device.

## 4. Security

This is not an external audit. Before launching the pyramid and currency an
independent review is needed, especially of the ring cryptography (§24,
"Honestly").

### 4.1 Open

| # | Severity | Problem | Where | Fix | P, size | Status |
|---|---|---|---|---|---|---|
| S5 | Medium | The "Nearby" greeting reveals the stable address while the UI says "not your account" | `nearby.dart:487`, `nearby_screen.dart:87` | one-time address or correct text | P2, M | **done in 1.11.0:** greeting v7 (nickname, message, token, one-time X25519 key), reply over Bluetooth (v8) with the address encrypted to that one phone; only people who replied learn addresses. |
| S6 | Medium | One "Nearby" secret for all friends: a friend can fake your presence to others and sign a false alarm wave in your name (S2 closes strangers, not friends); the token change was not synced with MAC rotation | `meet_book.dart`, `nearby_keeper.dart` | a separate secret per friend, sync with the MAC (§15) | P2, M | **done in 1.11.0:** private "Nearby" key never leaves the phone; a friend gets the mask key, anchors of a one-way hash chain (30 days) and a pair key; BLE token = chain value of the window masked (4-byte hint); alarm wave v6 signed with the pair key; token rotates every 10 min (< Android's 15 min MAC rotation). |
| S10 | Medium | The background service holds the master key while it runs | §14.1 pt 1 | service without the master key (separate keys for receiving) | P2, M | open |
| S11 | Medium (decision) | A computer is a bridge without asking (UPnP, `tls://[::]:32913`, port 443) and reveals identity | §5.1 | conscious decision (§2); eventually a separate listener key | P3, M | open (limits added, see §2) |
| S13 | Low | "Pass it on" listens on every private IPv4, HTTP in the same network | `share_app_server.dart:201–222` | only the chosen interface; integrity is checked by §14.3 anyway | P3, S | **done in 1.11.0:** listens on one address — the network chosen by the person (switch on the screen when there are several) or the best one (hotspot, then Wi-Fi, then cable); skips cellular (rmnet, ccmni…), VPN, VMs and containers |
| S15 | Low | Certificate fingerprint not published (`kOfficialApkCertificatesSha256` in `apk_signature.dart` is empty, so the computer shows only the fingerprint with verdict "unknown"); Windows without Authenticode | — | enter the fingerprint at the first signed release (`RELEASES.md` §2 pt 4), §14.3 | P1, S | open; tooling ready: `tool/zen_release.dart fingerprint APK\|--keystore --write` |
| S16 | Low | Windows Hello without hardware consent: a program of the same user can unseal the key when Hello unlock is on (no UI policy in the TPM); described in settings | — | no simple solution | P3 | open |
| S17 | Low | The call-answer token is bound only to the address, not to the call number | — | bind to the call identifier | P3, S | **done in 1.11.0:** the "Answer" route carries the call number (`call=`), the token issued in the isolate is bound to it; routes without a number work as before |
| S18 | Low | A pyramid record rejected during application may leave part of its changes (same at everyone, no divergence) | — | apply on a copy | P3, S | **done in 1.11.0:** a record whose rule throws is rejected up front ("bad record"), the fold is recomputed deterministically |

Deep links: none performs an action by itself.

### 4.2 Second audit (14 Oct 2026, round 2)

Read-only code review (no running), state 1.10.0+10. The audit's own
numbering S-1…S-20 corresponds to S19–S38 (column "audit 2"). Fix status in the
last column; tests pass (`flutter test`, `go test`).

| # | audit 2 | Severity | Problem | Where | Fix | P, size | Status |
|---|---|---|---|---|---|---|---|
| S19 | S-1 | High | Recovery without a password is not bound to the account: `rc_piece` pieces accepted from anyone, with no account identifier, so a new device can accept someone else's account (and then synchronizes its correspondence and contacts); a stranger can fill the limit of 24 halves and supply expensive Argon2 parameters | `recovery_service.dart:255-358`, `account_recovery.dart:417-442`, `account_recovery_screen.dart:165-193` | `account` field in the piece, one half per sender, accepting only with the screen open, cost equal to `kRecoveryPasswordCost`; after reconstruction `fromSeed(seed).id == account`; before accepting show the account fingerprint and number of helpers | P1, S | **fixed in 1.10.0 (round 2)** |
| S20 | S-2 | High | Go bridge: a queue of 2048 signals with no byte budget and zstd decompression up to 8 MiB from any node before the app checks the sender; in Dart no limit before `jsonDecode` — anyone who knows the invitation code can hang the app and the background service | `bridge_types.go:142-176`, `signal_reassembly.go:61-63,211-246`, `bridge_signaling.go:75-81`, `yggdrasil_signal_transport.dart:206-246` | low result and compression-ratio limit, byte budget of the queue (total and per /64), rate limit per source, length limit before `jsonDecode` | P1, S | **fixed in 1.10.0 (round 2)** |
| S21 | S-3 | Medium | A device record in a friend's `acts` accepted without proof of address: a friend can assign themselves someone else's address (traffic "to every device of the account", someone else's friendship level) | `ledger_node.dart:1049-1090` | record only as a hint "say hello there"; the address only after proof from a greeting | P1, S | **fixed in 1.10.0 (round 2)** |
| S22 | S-4 | Medium | Warning about executable files can be bypassed (`invoice.exe.`, trailing space — Windows); no warning for files from own devices; saved files without Mark-of-the-Web | `media_guard.dart:369-393`, `safe_file_name.dart:5-23`, `conversation_screen_media.dart:1952-2037` | trim trailing dots and spaces, double extensions as risky, warning also for synced files, `Zone.Identifier` on Windows | P1, S | **fixed in 1.10.0 (round 2)** |
| S23 | S-5 | Medium | Mailbox addresses (up to 6 friends) announced by default to all group members, also strangers; any group member can silently append addresses to the member list | `relay_models.dart:289,417`, `relay_engine.dart:637-648,1720-1733`, `social_hub_controller_lifecycle_signal.dart:454-489` | mailboxes announced only to friends; extending the member list only from the group's creator | P1, S | **fixed in 1.10.0 (round 2)** |
| S24 | S-6 | Medium | GitHub Actions: actions pinned by a moving tag (also the external `subosito/flutter-action`) in a job with the APK key and `contents: write`; `workflow_dispatch` signs code from any branch; no environment with approval | `.github/workflows/release.yml` (also `ci.yml`, `ios.yml`, `pages.yml`) | actions pinned by full SHA; key only for `v*` tags; signing in a separate job in an `environment:` with approval (D11) | P1, S | **fixed in 1.10.0 (round 2)** |
| S25 | S-7 | Medium (partly uncertain) | iOS: files end up in iCloud/iTunes backups, Keychain entries with default accessibility (also macOS), `UIFileSharingEnabled`; no screenshot protection and no cover in the app switcher | `app_security_service.dart:142-160`, `secure_screen.dart:24-25`, `ios/Runner/Info.plist` | `isExcludedFromBackup`, `…ThisDeviceOnly`, `UIFileSharingEnabled=false`, a cover when going to the background | P2, S | partly fixed in 1.10.0 (round 2): Keychain `…ThisDeviceOnly`, exclusion from backup, cover in the switcher; `UIFileSharingEnabled` stays (writes to Files) |
| S26 | S-8 | Low | The "after 5 min in the background" lock engages only on return — the master key and UI stay in memory the whole time in the background; no idle lock on desktop | `app_security_gate.dart:42-68` | lock timer from going to the background; idle lock on desktop (cf. S10) | P2, S | **fixed in 1.10.0 (round 2)** |
| S27 | S-9 | Low | Screen protection and blank thumbnail in "Recents" only on selected screens: the chat list with content preview, graph, profiles and dating unprotected (also macOS) | `ZenSecurityBridge.kt:58-77`, `secure_screen.dart` | no thumbnail at all times when the screenshot block is on; chat list and dating under protection | P2, S | **fixed in 1.10.0 (round 2)** |
| S28 | S-10 | Low (uncertain) | When the pinned SDP is rejected, the peer's original is used — ICE may connect outside Yggdrasil (IP disclosure) | `call_media_session.dart:1949-1960`, `group_call_media_webrtc.dart:736-741` | abort the call or strip `a=candidate` from the original | P2, S | **fixed in 1.10.0 (round 2)** |
| S29 | S-11 | Low | A GIF from the peer is fetched automatically from klipy.com: the recipient's IP at a third party, the friend knows when the chat was opened; bytes go to the system decoder bypassing `media_guard` | `animated_gif.dart:43-177`, `remote_media_guard.dart` | fetch on tap; eventually the sender sends bytes as an attachment through `media_guard`, no `gifUrl` | P1, S | **fixed in 1.10.0 (round 2); the sender now downloads the GIF and sends it as an attachment through `media_guard` (animation kept: structure, size, frame count and canvas validated), no recipient-side fetch** |
| S30 | S-12 | Low | "Notifications without content" hide the content but not the title ("X is going on a date", "Answer: {question}", "Invitation: {event}") | `runtime_system_notifications.dart:217-225`, `dating_service.dart`, `ask_service.dart:523`, `event_service.dart:1141` | a generic title for sensitive categories; alarms and calls stay explicit | P2, S | **fixed in 1.10.0 (round 2)** |
| S31 | S-13 | Low | BLE alarm waves: global limit 40/min counted before the signature check — changing MAC can drown out a real alarm | `ZenNearbyBridge.kt:107-109,598-620` | a separate pool for waves with a verified friend signature | P2, S | **fixed in 1.10.0 (round 2)** |
| S32 | S-14 | Low | Device linking: the first `al_hello` takes the session — a stranger who knows the address can block linking (no takeover: commit–reveal and 6 digits protect) | `account_link.dart:286-311` | several parallel attempts or reset the session on mismatched digits | P3, S | **fixed in 1.10.0 (round 2)** |
| S33 | S-15 | Low | Windows: system tools by bare name (`route`, `taskkill`, `explorer`, `adb`); `taskkill /IM zen.exe` kills any process of that name when a stranger program takes the lock port 47821; activation IPC unauthenticated | `single_instance_guard.dart:80-113,270-283`, `port_mapper.dart:502,513` | full paths; kill only own processes | P3, S | **fixed in 1.10.0 (round 2)** |
| S34 | S-16 | Info | Diagnostic log in plain text next to the data (bridge addresses, router description, file names) | `zen_log.dart:28-79` | log in the vault or cleared on lock; broader redaction | P3, S | **fixed in 1.10.0 (round 2)** |
| S35 | S-17 | Info | A letter and an introduction through a mutual friend without the author's signature — the broker can change text, address and name | `intro_service.dart:938-992` | the author signs the content, the recipient verifies | P3, S | **fixed in 1.10.0 (round 2)** |
| S36 | S-18 | Info | Report: the evidence is the reporter's text; content ban by hash of the whole text (an added space bypasses it) | `content_moderation.dart:28-54` | signed original of the entry; ban by entry identifier | P3, S | **fixed in 1.11.0:** a report carries the entry id and (when the phone has it) the signed original `LogEntry`; the receiver keeps it only after verifying the device signature and certificate; the content ban is by entry id (hides a modified copy too, field `eid`); the text hash was dropped |
| S37 | S-19 | Info | Embedded shared Klipy API key (a comment claimed there is none); searched terms and IP go to klipy.com, `locale=pl_PL` hard-coded; documented nowhere | `chat_gif_catalog.dart:7-96` | a truthful comment; in the UI, README and privacy policy that search contacts klipy.com; consider off by default | P1, S | **fixed in 1.10.0 (round 2)** |
| S38 | S-20 | Info | Minor: hard-coded DNS 8.8.8.8 / 1.1.1.1 (Android); `FLUTTER_TEST` in the environment disables the password requirement; the call UDP relay accepts the first local process; replying to a stranger reveals the device is online; bridge DLL also searched in the current directory (Windows) | `android_net.go`, `app_bootstrap.dart:140-149`, `bridge_relay.go`, `yggdrasil_bridge_ffi.dart:133-137` | DoH/DoT or own servers; `kDebugMode` instead of the variable; DLL only next to `zen.exe` | P3, S | **done:** 1.10.0 (round 2) `FLUTTER_TEST` only outside release, DLL only next to `zen.exe`, no reply to strangers; **1.11.0** DNS — system resolver first (incl. Private DNS), then a list (default DNS-over-TLS: Quad9, Cloudflare, Google, port 853, certificate checked; changed by exporting `YggSetDnsServersJson`), UDP relay — on desktops only on 127.0.0.1, a local socket accepted only when its first datagram is an ICE check with this call's username, before the relay has learned the name it forwards local checks (up to 40/s) but accepts no sender. Remaining: on phones the relay still listens on all IPv4 (Android WebRTC binds sockets to the network) |

Outside the audit: **no channel for reporting vulnerabilities** (architecture
review K9) — `SECURITY.md` and private vulnerability reporting on GitHub
(enabled in the repository settings); fixed in 1.10.0 (round 2): `SECURITY.md`.

**Checked and fine:**
- the ZENENC2 envelope (AES-256-GCM with AAD, HKDF subkeys, constant-time
  comparisons, rejection of ZENENC1 and plaintext, hidden file names);
- Argon2id: 19 MiB for the app password (rather low — to consider), 64 MiB
  for the circle, rejection of absurd costs; the media vault (AES-GCM segments
  with AAD, random names);
- store paths (`_sanitizeKeySegments`) and `safeFileName` (apart from S22);
- cryptography of mailboxes and dating (X25519 + HKDF + ChaCha20-Poly1305 with
  AAD, two-layer box); the ring signature (canonical key image, torsion
  rejection, no exceptions on bad input);
- `media_guard` (apart from videos — a conscious risk; GIFs are validated, not re-encoded); limits
  of incoming frames (attachments, blobs, entries of 64 KiB, budget of strangers per /64,
  signal parser, reassembly in Go — apart from zstd, S20);
- the call-answer token; the test remote only in debug with a Host check; the
  Android manifest; APK signature verification (only the fingerprint is
  missing, S15); the "Pass it on" server; updates over the network (off, 2 of 3,
  7 days); FFI (the node key does not pass); the Go bridge (frames from outside
  the node addresses rejected, `AdminListen=none`);
- Linux and macOS: no new high or medium findings. macOS: key in the
  Secure Enclave with `.biometryCurrentSet` and `…ThisDeviceOnly`, screen
  protection as on Windows (S27 applies to it); no sandbox is a decision (§2).
  Linux: the bridge library loaded by absolute path (not the current
  directory, better than Windows in S38).

### 4.3 Fixed in 1.10.0 (first round)

- **S1 (high):** pyramid `report` and `appeal` only from members (device
  address bound to a key) and only to those who handle them; length limits,
  per sender and total; a separate store `pyramid/reports`. Limits also for
  proposals to sign and market messages.
- **S2 (high):** the alarm wave over Bluetooth signed with HMAC-SHA256 with the
  "Nearby" secret, valid ±10 min, replays rejected; only a verified friend's
  alarm rings, a stranger's gives a silent note at most once per 10 min; wave
  limits in Kotlin. (In 1.11.0 replaced by per-friend pair keys, S6.)
- **S3 (high):** attachments, voice notes and friends' photos in the vault
  (`media_vault.dart`, AES-GCM segments, random names), photos only in memory,
  recordings and videos in a short-lived copy; hidden `transfers/` names.
- **S4 (medium):** stores open only the ZENENC2 envelope bound to the write
  location; node configuration sealed for its key; `ring-ok` memory with HMAC.
- **S7 (medium):** the panic password stops the service and wipes cache, temp
  files, `Android/data/…/files`, Zen folders in Documents and Downloads, and
  saved copies (export list).
- **S8/B10 (medium):** the alarm goes out before the write; limits on fields,
  number of answers and alarms.
- **S9/B9 (medium):** APK certificate check in "Pass it on" and ADB; no
  "uninstall" advice, with a counterfeit warning.
- **S12 (low):** treasurer signatures merged, not replaced.
- **S14 (low):** old invitation formats removed.
- **Currency:** limits of amounts and balances (no 64-bit wraparound),
  re-confirmation before every payment, screenshot block in the wallet.

Earlier in the same version:

- **Malicious media** (high): photos from others went straight to the system
  image decoder (Skia/libwebp), and the attachment type was taken from the
  sender. Now `media_guard.dart`: photos re-encoded in pure Dart (chat, posts,
  profiles, dating), pixel limit before decoding, videos/recordings only with a
  valid container, type and name from the content, a warning before saving
  executables. Remains: videos are still decoded by the system (they cannot be
  re-encoded on a phone).
- **Impersonation by name** (medium): a friend's name was arbitrary text set
  locally or via a link. Now it comes from that person's profile, stripped of
  control and text-direction characters; the own label is a separate nickname.
- **Path traversal in "Save copy"** (high): a file name from another person
  could overwrite files in the app directory
  (`conversation_screen_media.dart`, `runtime_signal_parser.dart`). Now
  `safeFileName` on receive and save.
- **The lock behaved differently than the UI promised** (medium): lock after 5
  min in the background by default (earlier only after a phone restart), lock
  screen texts truthful (the background service keeps receiving messages).

### 4.4 Fixed earlier (audit V1.10)

- `friend_accept` from a stranger made them a friend — now an unsolicited
  acceptance is an ordinary invitation; mutual invitations at the same moment
  give friendship at once.
- A locked app broke friendships (signals on an empty state, pings too) —
  signals wait for the data to be read after unlock, in the same queue. (The
  same reflex with unreadable data: B11.)
- Pyramid: a bad ring signature does not crash the count, canonical key images
  (no double votes), records from the future rejected, fresh time at signing,
  witnesses at closing and revoking a delegation, delayed issues wait 24 h,
  constitution with a quorum, a 30-day issue limit, sync only with friends.
- zstd decompression limit before unpacking; reassembly of fragments in Go
  with per-source limits; frames from outside node addresses (/64) rejected.
- Limits on: friendship requests, group and event invitations (impersonation
  in the `by` field), attachments, images (JPEG/PNG bombs), dating packets,
  offline mailboxes (a separate per-sender "floor", budget for strangers),
  answers to questions, alarms, "Nearby" sessions.
- Answering a call through a link requires a one-time token; a link will not
  set a fake name.
- Android: non-exported components, `FileProvider` only `cache/shared_apk`,
  backups off, blank "Recents" thumbnail, no logs in release; test remote only
  in debug with a Host header check.
- `threads/` and `relay/mail/` with hidden names; ZENENC2 with AAD; panic
  destroys keys first; Keystore with strong biometrics; Windows: key sealed
  only after Windows Hello is enabled.
- Device linking with a commitment (commit–reveal); proof of address in the
  device greeting.
- Changing the password and the panic password requires confirmation, the two
  cannot be equal; notification content hidden also for dating and the pyramid.
- Updates 2 of N (off); `key.properties` and `*.jks` in `.gitignore`; alarm
  confirmations only from those it was sent to.

Regression tests: `test/inbound_limits_test.dart`,
`test/pyramid_security_test.dart`, `test/pyramid_attack_sim_test.dart`,
`test/ring_signature_test.dart`, `test/relay_engine_test.dart` (group
`hardening`), `test/account_link_test.dart`, `test/app_data_reset_test.dart`,
`test/hidden_store_names_test.dart`, `test/ledger_stranger_flood_test.dart`,
`test/share_app_server_test.dart`, `test/mutual_request_test.dart`, Go tests
in `native/yggdrasil_bridge`. Added in 1.11.0: `test/relay_blob_test.dart`,
`test/offline_attachment_delivery_test.dart`, `test/wire/golden_frames_test.dart`,
`test/background_work_test.dart`, `test/feed_memo_test.dart`,
`test/about_screen_test.dart`.

### 4.5 Conscious limitations

- Recovery: two colluding helpers can guess the password offline (Argon2id
  64 MiB); delays are enforced only by honest apps.
- Dating: a modified app will get the packet key with a new dating key and sees
  a one-sided "Yes".
- Pyramid: collusion of all required signatures can move a record's date
  back; merging pyramids rests on the signature of the source's top.
- Mixed versions: versions before 1.10.0 are not supported (compatibility code
  removed before the first release). 1.11.0 keeps transitional paths for 1.10.0
  only for large messages without mailbox blobs. To be removed once 1.10.0
  dies out.
- Pyramid: a cell's boss sees the sums of direct members (a leaf is one
  person): "read" and the leaf's age/gender bucket are visible to them (like a
  vote in a triple, §21.3).
- There is no age verification; a blocked follower can still read public
  posts; the version a friend reports is their own declaration.

### 4.6 New in 1.11.0 (limitations and risks)

| # | Severity | Problem | Where | Fix | P, size |
|---|---|---|---|---|---|
| S39 | Low | Underage reports in Dating count different dating keys, which are cheap: a Sybil attack can hide someone else's profile for people who get packets of both fake keys (quorum `kDatingMinorQuorum` = 2); reports travel only within 3 steps | `dating_service.dart` | tie the quorum to something expensive (accounts known by friends / pyramid members) | P3, M |
| S40 | Info | The "About" text claims Zen adds its own encryption to every message; in code direct messages are protected by Yggdrasil end-to-end encryption, and Zen's own layers are mailboxes, the ledger, dating, etc. (noticed while writing the privacy documents) | About screen | correct the text (and keep `PRIVACY.md` consistent) | P1, S |
| S41 | Info | The door node peers only with the resident's main node, so someone with a view of mesh paths who already suspects a resident can link the door to that phone (its path is one hop below it); the door answers only while that phone runs Zen in the foreground (not from the Android background service) | `door_node.go`, `neighbors_providers.dart` | peer the door through another public peer; run it in the background service | P2, M |
| S42 | Info | Mailbox hosts store friends' attachments (ciphertext only) up to a quota — storage and traffic cost on their phone, they see sizes and timing | `relay/blob/…` | quota exists (20 MB per sender by default, 200 MB total); "Wi-Fi only" for blobs not checked | P3, S |

## 5. Architecture

| # | Problem | Where | Direction | P, size |
|---|---|---|---|---|
| A1 | Acknowledgement before handling the frame (B2) | `relay_engine.dart:462`, `meet_service.dart:173-176` | ack after handling / deferral; a "state" version digest in the greeting | P1, M |
| A2 | Volatile state written as a whole file on the UI thread (B3); eventually no database | `social_hub_controller_social.dart:1417-1446` | now debounce and in-memory presence (S); eventually encrypted SQLite (L) | P1 S / P3 L |
| A3 | **Two environments on the same files** (the app and the background service), part of the handling copied, logic in the UI layer | `android_background_runtime.dart:1393-1408` creates a second set of services; `AlarmWatcher` (`alarm_screen.dart:1257`) runs in parallel with the service's `_datingTimer` (`:1471`); separate write queues (`meet_book.dart:708`) | one owner of data and services (the service), the UI as a client; step 0: A15 | P2, L |
| A4 | Separate distribution mechanisms instead of ledger spaces (mailboxes, pyramid, dating, event and question chains, neighbors); the relay keeps a manual list of ~90 types from all features (`kReliablePayloadTypes`, `_directOnlyPayloadTypes`) next to the typed `ZenSignal` | `space_policy.dart:35-53`, `relay_engine.dart:166-268`, `zen_signal.dart:5-47` | new features on ledger spaces; one "friend state" mechanism; each module registers its types with a policy (`reliable`, `directOnly`, `maxBytes`, `ttl`) | P3, M–L |
| A5 | **Cryptography in pure Dart on the UI thread**; the pyramid folded from scratch every 60 s; every member holds all records | `ledger_identity.dart:50`, `ledger_store.dart:176`, `pyramid_record.dart:155,181`, `pyramid_service.dart:1576,1604`, fold `:457-471` | crypto in Go over FFI or a separate isolate; incremental fold; signed checkpoints; the phone holds its own branch | P2, M. **Partly (1.11.0):** big AES-GCM/ChaCha work runs in isolates; remaining: signature/ring crypto, incremental fold, checkpoints |
| A6 | The pyramid reveals the device address (breaks §6.4) | `pyramid_service.dart:3534-3537` → `pyramid_state.dart:1320-1325` | traffic through relays, no address in the state | P2, M/L |
| A7 | The pyramid key is random on each device: a lost phone = loss of the wallet; a phone and a PC are two people | `pyramid_service.dart:820-829` | HKDF from the account key | P1, S/M. **Done (21.10.2026):** HKDF from the account seed (`zen.pyramid.v1`), kept in the ledger identity; no separate key. Per-device pyramid state (proposals, own votes, entry data) is still not shared between devices |
| A8 | No common schema and version: enums by number, protocol without a version, dozens of "older version" branches | `social_snapshot_store.dart:51,67,92,117,520`; `attachment_transfer_store.dart:522` | before release reset the formats, enums by name, capabilities (caps) in the greeting (§7); version on the wire: A17 | P1, S/M. **Partly (1.11.0):** `v: 1` for settings, profile, flags; `ver`/`build`/`caps` in ping/pong; remaining: reset of numbers, enums by name (§7), caps in the greeting |
| A9 | Battery: a constant wake lock and Wi-Fi lock, ping every 45 s also in the background, no "Wi-Fi only" mode | `android_background_runtime.dart:589-590`, `:1800-1830` | event-driven presence, a saving mode, media only on Wi-Fi; bridge polling: A19 | P2, M. **Partly (1.11.0):** "Media only over Wi-Fi" done (default for new installs); remaining: the locks and event-driven presence |
| A10 | Identity = the Yggdrasil node key (address = invitation code, no rotation) | — | identity = the account key, replaceable nodes (§6.1) | P3, L |
| A11 | All traffic, video included, through Yggdrasil, no direct paths | — | direct connections where possible; the bridge as a group-call server | P3, M |
| A12 | Huge objects: `PyramidService` is one class of ~4.7k lines (84 `Future` methods), `PyramidState` ~2.2k, the chat controller ~11.9k lines in 11 `part`s with shared private state, `app_shell_screen_views.dart` ~4k lines (~40 classes), a single package | `pyramid_service.dart`, `pyramid_state.dart`, `features/social/*`, `app_shell_screen_views.dart` | `PyramidSync` / `PyramidFold` / `PyramidProposals` / `Wallet` / `Market` / `Reports`; `CallCoordinator`, `TransferCoordinator`, `PresenceService`, `FriendshipService`, `DeviceSync` as separate `Notifier`s; settings in `settings/` one file per section; then packages (`zen_core`, `zen_transport`, `zen_pyramid`…) | P3, L |
| A13 | Tests and process: CI exists (§8), but tests run only on Windows, no APK on push and no emulator; the background service (~2.3k lines) has 5 tests, Kotlin code (BLE, calls) none; no fuzzing of network inputs in Go, no corrupt-data test (B11), no tests of `group_call_media_webrtc.dart`; `sim_network.dart` sits in `lib/` | `.github/workflows/ci.yml`, `native/yggdrasil_bridge`, `lib/src/dev/sim/` | `go test -fuzz` for `parseYggPacket`, reassembly and zstd; a test "a corrupt snapshot sends not a single frame"; `flutter test` also on Linux; simulator to `test/support`; smaller releases | P2, S. **Partly (1.11.0):** golden protocol frames (`test/wire/`) added; the rest open |
| A14 | **Destructive reflexes** (review A1, K12): automatic replies delete something at the other side — `friend_remove` on a ping from a "stranger" (B11); a newly linked device can do the same before synchronization (`AccountRoutingTransport` rewrites the sender to the account — to check in the simulator) | `runtime_signal_bridge.dart:174-232`, `social_hub_controller_helpers.dart:131-142`, `account_routing_transport.dart:91-130` | read-only mode on unreadable data (like the background service); instead of the reflex a non-destructive `peer_unknown`; `friend_remove` only from a human action, signed with the account key, with a 7-day soft delete; regression tests | P1, S |
| A15 | **Composition root in widgets** (review A2, A5): 8 nested "bridges" in `app.dart`, `RuntimeSignalBridge` creates 14 services, `AlarmWatcher` runs the dating and pyramid timers and reloads 8 services on return, the background service assembles a different set by hand; providers do IO and network in the body; `ZenPersistentStores` silently substitutes in-memory stores | `app.dart:65-79`, `runtime_signal_bridge.dart:86-108`, `alarm_screen.dart:1392-1471`, `pyramid_providers.dart:10-36`, `persistent_stores.dart:28-31` | `ZenCore` (pure Dart, `start`/`stop`) with a `FeatureModule` registry — the same in the UI and in the service; feature flags as a list of modules; services without side effects in constructors; required stores instead of silent `Memory*` | P1, M. **Partly:** feature flags (1.11.0, `feature_flags.dart`: Pyramid, Wallet, Dating, Neighbors); **step 0 done 21.10.2026:** `ZenCore` (`app/zen_core.dart`, plain Dart) with a `ZenModule` registry (`app/zen_app_modules.dart`: signal → ledger → meet → neighbors → dating → pyramid → plan), driven by `zenCoreProvider` (started by `RuntimeSignalBridge` once the security gate opens, stopped when it closes; `ZenRewriteApp` forwards `resumed` and flag changes), starts the modules in order, stops them in reverse, runs the minute duties (dating, pyramid) and resume reloads; modules of disabled features do not start (turned on/off while running: started/stopped). `RuntimeSignalBridge` otherwise only forwards visibility, `AlarmWatcher` only the alarm duties. Remaining: the background service still assembles its own set (`HeadlessBackgroundRuntimeCoordinator`, not on the registry), the Android handoff bridge, some screens still create pyramid/dating services lazily via `ref.read` (A3), constructors without effects, required stores |
| A16 | Cyclic dependencies between features (review A3): the pyramid is imported by the feed, meetings, dating and moderation; `runtime` ↔ `shell`; `domain/` imports `social` — a "core" release needs `ref.exists(pyramidServiceProvider)` in many places | `report_content.dart:40-52`, `friend_profile.dart:3` | ports in `domain/` (`ContentBanPolicy`, `PaymentPort`, `FriendDirectory`, `ClockPort`); import rules in CI | P2, M |
| A17 | **A network unaware of versions** (review K6, A10): the app version does not go in ping/pong or the greeting, unknown spaces are rejected (against §1.6), updates over the network are off — the network will quietly drift into versions without patches | `app_version.dart`, `space_policy.dart:55-71` | `ver`/`build`/`caps` in ping/pong; a signed release marker spread by gossip, with a bar "Zen 1.11 is out — at 4 friends"; unknown spaces "store and forward" with a limit; golden frame samples (`test/wire/`) and a mixed-version test | P1, S. **Partly (1.11.0):** `ver`/`build`/`caps` in ping/pong, remembered per friend, a quiet bar in Settings "Friends have a newer Zen version (X)" (a declaration, nothing security-related depends on it); unknown spaces of a recognizable kind (`<kind>/<account>`) stored for the owner (1000 entries per device log; ownerless spaces still rejected; shared only with the account's own devices); golden frames incl. 1.10.0 and 1.11 ping/pong. Also done: the signed release (existing update gossip, `zen_rel`) shows the bar "nowa oficjalna wersja X (podpisana)" only once its maintainer signatures verify here (friends' bare `ver` stays a soft hint); unknown `<kind>/<account>` spaces are forwarded between friends that advertise `spaces1` in `caps` (carried in `lg_hello`; 1000 entries per log, 256 such spaces per device). Remaining: the mixed-version test |
| A18 | **Offline mailboxes promise more than they do** (review K3, A8): only reliable types up to 48 KB go to mailboxes; after 14 days a message vanished from the queue without a trace (B12); files go through three separate mechanisms (WebRTC channel — the whole file in memory; chunks over signals; ledger blobs) | `relay_engine.dart:47,65,166-247,1505-1513`, `realtime_attachment_transfer.dart`, `attachment_transfer_store.dart`, `blob_store.dart` | (S) state in the bubble: "waiting at friends" / "waiting until you are both online" / `failed` with "Send again"; (M) attachments as encrypted ledger blobs, recipient's relays as sources — one blob layer | P1 S / P2 M. **Done in 1.11.0** (as a separate mailbox blob layer): a *blob* = the attachment cut into chunks encrypted once with a fresh key (ChaCha20-Poly1305, nonce = chunk number, AAD = blob id, sender, recipient, number, count), the key in a small `blob_manifest` (direct or sealed by `RelayCipher` in mailboxes); two kinds: `p` (reliable payload > 48 KB, inline ≤ 1 MB) and `a` (attachment from chunked transfer, > 1 MB up to 24 MB, when WebRTC fails — the recipient gets ordinary `message_placeholder` + `message_chunk`, so reassembly and `media_guard` work as before; "delivered" after `message_ack`, error after 14 days); frames `rly_bput/bput_ack/bput_no`, `rly_bget/bchunk/bnone`, `rly_bdrop`, `rly_bdone` sent only to devices that announced `cap: ["blob1"]`; the sender stores copies at up to 3 mailboxes (`maxBlobCopies`); recipient collects from the manifest's deliverer, then own mailboxes, then the sender; collecting survives restart. Mailbox limits: only for friends who chose it, only from senders it vouches for, per sender per friend 20 MB (off/5/10/20/50 MB), 200 MB total, whole size reserved up front, expiry like messages (14 days) and when the friend leaves. Remaining: the three older file mechanisms are not unified into the blob layer |
| A19 | **Hot paths** (review A6, extends A5): FFI bridge polling every ≤ 400 ms (in the background service every ≤ 2 s — waking around the clock, the ring up to 2 s late); JSON frame → zstd → base64 → 1300-byte chunks in JSON (~40% overhead, a lost chunk = the whole message); AES-GCM in pure Dart on every write (no `cryptography_flutter`); the Feed computed from scratch in `build()`, 68× `ListView(` against 5 builders; startup reads the whole ledger of all friends and removes nothing | `yggdrasil_signal_transport.dart:124-246`, `bridge_signaling.go:100-172`, `app_security_crypto.dart:66-93`, `feed_screen.dart:615-654`, `ledger_archive.dart:126-200` | (S) `cryptography_flutter` and copying without spreads; (M) a `NativePort` from Go instead of polling; (S/M) the Feed incrementally and lazy lists; (M) lazy segments, a 12-month window for others' logs; (P3, M) a binary envelope and repeating single chunks | P2, M. **Partly (1.11.0):** AES-GCM/ChaCha of large data and big JSON in isolates (> 64 KB, `runSizedWork`), assembly without spreads (`setRange`), the Feed memoized (`FeedMemo`) and a `ListView.builder`, adaptive polling (40 ms → 500 ms / 2 s in the background); **21.10.2026:** signals are event-driven — an isolate of its own blocks in `YggWaitSignal` and wakes the app or the background service per signal (`yggdrasil_signal_waiter.dart`; `YggStopNode` wakes it at once), polling only if that wait fails. **Not done:** `cryptography_flutter` (global `Cryptography.instance` replacement is too risky without device builds), other lists (chats in `Column` inside `AnimatedSwitcher`, graph, circle), lazy ledger segments, binary envelope |
| A20 | **Persistence** (review A7): a hard 20 MB limit per file with state in one JSON (`dating/state` with photos, `meet/state`) — after exceeding it writing silently stops; names `meet/list/<sha256(address)>` and `ledger/log-<sha256>` are unkeyed hashes (a seized phone + a list of codes = "has this person as a friend"); Windows: data in Roaming AppData (a profile copy = a second computer with the same key → a forked log without a word in the UI); orphaned `*.tmp` | `binary_store.dart:55,91,346-349,487-492`, `meet_book.dart:801`, `ledger_archive.dart:117`, `zen_instance.dart:36` | warning at 50% of the limit, photos as blobs; `meet/list/` and `ledger/` in hidden names (HMAC); `%LOCALAPPDATA%` and detection of an own fork with a new device key | P2, S. **Mostly done (1.11.0):** hidden names, `%LOCALAPPDATA%`, warning from 50% (`ZenStorageHealth`), stronger zstd from 75%, `full` reported before a write is refused, orphaned `*.tmp` older than 1 h swept. Remaining: photos as blobs, detection of an own fork |
| A21 | The clock as a silent filter (review K11): tolerances differ in every subsystem (relay 1 day, ledger 10 min, table and circles 10 min, tickets ±90 s); a phone running 15 min fast is quietly rejected everywhere | `hlc.dart:42`, `relay_engine.dart:73`, `table_service.dart:22` | time in pong; a bar "Your clock is 14 min fast"; tolerances in one place | P2, S. **Done in 1.11.0:** `ClockSkewTracker` collects time from friends' messages (needs ≥ 2 friends and > 2 min), a bar under the connection bar and a line in the report. Remaining: tolerances in one place |
| A22 | Failures invisible to a human (review A11): 636 `unawaited`, 53 `catch (_)` (17 empty); a write error, a rejected record, a forked log, queue expiry and overflow in Go end as a log line | — | `HealthReport` (last successful write, rejected frames by reason, file sizes, clock, friends' versions) on a diagnostics screen and a bar "Something is wrong — show"; a report to send by hand | P2, S. **Mostly done in 1.11.0:** the "Why isn't it working?" screen (`HealthScreen`, `health_report.dart`: network, node and neighbors, background work, notifications, battery, clock, free space, fix buttons, "Copy report" without addresses; from Settings and the connection bar). Remaining: last successful write, rejected frames by reason, file sizes and friends' versions in the report; the global bar; handling the silent `unawaited`/`catch (_)` |
| A23 | Translations — traps (review A12): localized texts saved in state (`InboxEntry.title/body`, "Now", system messages) stay in the old language; key = Polish text (a fix loses translations, "Save" as save and sign up has one translation, no grammatical gender); GIFs with `locale=pl_PL` | `social_hub_controller_helpers.dart:38,105,642-664`, `social_hub_controller_messages.dart:762`, `chat_gif_catalog.dart` | save an event code and arguments, build the text on display; an optional `context:` in `t()`; the tool marks translations "to review" instead of losing them | P1, S. **Partly (1.11.0):** all texts outside the Dart UI are English-first and translated into 21 languages (see §1). Remaining: the traps above |
| A24 | Platforms (review A14, U6): 85× `Platform.isAndroid`, 49× Windows, 26× macOS/Linux in 39 files; a computer gets a 430 px phone column | `app.dart:84-124` | `PlatformCapabilities` (BLE, background work, recording, bridge, window); from 900 px two panels (chat list + conversation), keyboard shortcuts | P3, S/M |
| A25 | **Screen sharing on a second video track** (new): camera + screen at once — 1:1 adds a second video transceiver and renegotiates, group legs carry a screen slot from the start; the other side shows the screen large, the camera small | `call_media_session.dart`, `group_call_media_webrtc.dart` | test on devices | P3, S. **Done in code**; not tested on devices |
| A26 | **Local-network discovery is not wired from Dart** (**done 21.10.2026**: setting, secret from the account key, `MulticastLock`; see `PLAN.md` §5.1 item 6): Go supports multicast (key `ZenLanDiscovery`: `Enabled`, `Secret` — shared by the account's devices, the bridge derives an HMAC-SHA256 password from it —, `OnWiFi`; phones only `OnWiFi` and only on Wi-Fi interfaces wlan/swlan/ap, iPhone en0), off by default; missing: the Dart side — a setting, the account secret, `MulticastLock` on Android | `native/yggdrasil_bridge`, node configuration | add the setting and secret | P3, S/M |

Proposals: a "core" release behind feature flags (done at the flag level; step
0 of A15, `ZenCore`, done); one "friend state" mechanism; the Go bridge as the engine for
cryptography and the database (FFI, SQLite); a diagnostics screen (done,
A22; connections, mailboxes, friend lists and queues remain); a load test
before a wider release (150 friends, 2 years of history, dating: startup time,
memory, file sizes, daily traffic).

## 6. Concept

1. **Dating grew as the third power of the number of friends** (an 8–52 KB
   packet from everyone every week, up to 3 steps). **Fixed (21 Oct 2026,
   §19.7):** lanterns of ~100 B to 2 steps; the profile is fetched only when
   a lantern fits. Open: a load test with ~150 friends (§5).
2. **A contact economy based on currency**: commodification of acquaintance,
   KNF/AML risk (Polish financial supervision), the name "Pyramid" evokes a
   financial pyramid (also for store reviewers, §9). First a version without
   money (§24.1); the pyramid and currency behind a flag. **Flags are done in
   1.11.0** (Settings → Experimental features; defaults on; build-time
   defaults and a lock), what remains is the decision about the default and
   the release variant. P1, S.
3. **"Private by default" not met** (largely fixed in 1.11.0): the friend list
   and statuses are now hidden from weak friends, group invites have a level
   threshold, the ledger profile carries the address only after a public
   post/share. Remaining: older profile versions with the
   address stay in the ledger; the address is also in device records in `acts`
   (needed for routing); public posts can be followed by anyone who knows the
   address (it leaks only through a Bluetooth reply, S5); no real age verification. P1, S.
4. **"No release keys" is fiction**: the APK key is one key of one person, and it
   sits in GitHub Actions secrets (D11); the license forbids forks, so after the
   author disappears nobody can legally continue; a public APK key would be
   dangerous. Fix: rotation v3, Shamir deposit, signing outside CI, a decision
   about the license (e.g. consent to continuation if the author disappears)
   and possibly a foundation. 1.11.0 added tooling (release manifest signs the
   donation link, canary), but `kReleaseMaintainers` is empty and no fingerprint
   is published. P1, S/M.
5. **Bridges without consent** (UPnP, port 443) — a conscious decision (§2).
6. **Every phone stores and passes on friends' media** (downloads everything by
   default): battery, data, unwitting storage of others' content. By default
   Wi-Fi only, with limits. P2, M. **Partly (1.11.0):** "Media only over Wi-Fi"
   (on for new installs), "Storage limits" shown read-only; mailbox attachments
   have their own per-sender quota.
7. **Cold start.** A messenger is valuable when friends are in it; without an
   iPhone one person on iOS excludes a group. A narrow wedge is needed
   (neighbors in one block or meetings in one city) and a simple loop: add a
   friend → write → arrange → meet.
8. **"No servers" is partly true**: the network stands on public nodes of
   Yggdrasil volunteers (an experimental project), bridge computers and online
   treasurers. A public node sees the IP and the stable node key, that is the
   invitation code — whoever adds a node to the list can collect a map "IP ↔
   person in Zen" (review K7; eventually rotated node keys, A10). The GIF
   search (sender's device only) goes to the commercial klipy.com with an embedded key (S29, S37) —
   against "no ads" and "no server that sees everything". More honestly:
   "a network run by its users", a sentence about metadata in the README
   (and `PRIVACY.md`, now drafted, names klipy.com and public nodes). P2, S.
9. **Reliability without push**: everything depends on the background service,
   which manufacturers (Xiaomi, Samsung) and doze mode kill. The alarm works
   when friends' phones have a node — hence delivery confirmations (done), a
   fallback SMS (done in 1.11.0, opened in the system app so the user presses
   send), fresh location in the background (done) and per-manufacturer battery
   instructions (done).
10. **Moderation**: before the pyramid there is none; moderation through a
    political hierarchy is a conflict of interest.
11. **Pyramid**: a binary tree is a growth bottleneck, the top is entrenched,
    the same ~15 people hold issuance, treasury and bans, vote anonymity in a
    triple is negligible; national sections are an electoral law (parties are
    gone). **Viability of power** (review K5): the constitution quorum counted
    from all seats (also dead and fake ones) and the requirement of the full sum of
    every branch — shells or one offline cell block changing the constitution;
    the national-section threshold (~100 people) is passed by the same shells;
    a transfer needs 8 of 15 treasurers online. **Done in 1.11.0:** the quorum
    of binding referenda counts members seen (signed record, "I'm alive" every 7
    days) within the last `absenceDays`, the branch sum published after the top's
    sum (after 6 h of grace) does not invalidate the result. Remaining: the
    "paralysis by absence" scenario in the simulator; shells still pass the
    section threshold; the treasurers' 8-of-15 online requirement. P2, S/M.
12. **GDPR**: special-category data (art. 9), the author as a possible joint
    controller, "right to erasure" versus signed chains. Draft `PRIVACY.md`,
    `TERMS.md`, `DPIA.md` now exist (English, not legal advice, needs a lawyer's
    review; §27).
13. **Feature sprawl**: 13 tabs, a password from the first launch, 25-character
    codes, the concepts circle, bridges, levels, pyramid — too much for a
    non-technical person. Response: the core behind flags (done), grouping of tabs
    (done in 1.11.0: 6 tabs + "More"), a simple welcome (a "Welcome to Zen" card
    exists; the flow name → photo → add a friend → circle remains) (§25).
14. **One person**: the project, the key and the fundraiser rest on one human.
15. **The QR code on the door publishes the residents' stable addresses**
    (review K1): `FlatDoorCode.encode()` put up to 3 addresses into the code,
    starting with the own one, while §18.2 promised "the flat's key, not the
    account's". An address is an identity and an invitation code: whoever walks
    through the stairwell gets the chain home → person → public profile and posts →
    online presence. **Fixed:** the code carries the flat key and the address of
    the flat's door, a separate node with its own random key (`door_node.go`,
    S41 for what remains); `zen://m/<code>` and `/m#` links open the knock.
    Remaining: the person's address only after "Show my profile". P1, S.
16. **A lost phone** (review K4): without a circle the account and all friends
    are lost; with a circle friends and groups come back, but not the chat and
    file history (`own`), the wallet (A7) or the dating profile. The circle was
    hidden in settings with no reminder. **Done in 1.11.0:** paper backup of the
    account key, a "Secure your account" card after the permissions step, a
    reminder in Settings until a circle or a paper copy exists. Remaining: a
    "What you will recover if you lose your phone" screen (S); export of an
    encrypted backup to a file (S); a copy of `own` at the circle with a limit
    (M); the wallet key now comes from the account key (A7, done). P1, S/M.

Proposals: contact economy without money; paper copy of the account key (done) +
the pyramid key from the account (done); mutual verification of the official version
(§14.3); event-driven presence and a saving mode; invitation through an event;
dating on demand, 2 steps. From the architecture review (no servers): "Is
everyone OK?" with one tap after a storm or outage (alarm, confirmations and
waves already exist; P2, S); one QR inviting a whole group at once — a friend of
the organizer and at once in the group chat (P1, S/M); mailbox synchronization
when two phones meet (P2, M); a simple mode for a senior and a child (P2, S/M);
a call security code to compare live (P2, S); a family or tenement announcement
channel (P3, S). UX: message status tells the truth (A18, done), one "Why isn't
it working?" screen (done, A22), accessibility (alarm button, graph nodes and tab
cards now have semantics; in the whole app still 5× `Semantics` before this
round and 427 literal `fontSize`s; remaining: typography scale, a screen reader
and 200% zoom test), the computer as a computer (A24).

## 7. Migrations and compatibility code

There are none. The app has not been released, so no data migrations and no
readers for older file formats or older peers are kept: a stored document is
read in the current format only (`v: 1` where the format names a version,
`lib/src/core/storage/format_version.dart`), and a file this build cannot read
falls back to the defaults (a social snapshot is set aside as `.unreadable`
first). The Windows data folder is `%LOCALAPPDATA%\<company>\<app>` directly;
`flutter_secure_storage` keeps its own file in `%APPDATA%` and is left alone.

## 8. Versions and process

- **One numbering:** `1.11.0` in `pubspec.yaml` and `app_version.dart` (a test
  checks agreement; the build number must rise), a `1.11.0` CHANGELOG section,
  tag `v1.11.0`.
- **GitHub Actions:** `ci.yml` (formatting, analysis, app tests — including
  `test/i18n_test.dart`: translations consistent with texts in code — and
  bridge tests on every push and pull request, on Windows; building and a
  short start on Linux on every push and PR, on macOS on push to `main` and by
  hand; a `windows-arm64` job on push to main), `release.yml` (tag `v*`:
  `Zen.apk` signed with the key from secrets, `Zen-Windows.zip`,
  `Zen-Windows-arm64.zip` (`continue-on-error`; `SHA256SUMS` is computed
  without it if it fails), `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz`,
  `Zen-Linux-x64.deb`, `Zen-Linux-arm64.deb`, `Zen-macOS.zip`,
  `Zen-unsigned.ipa` from `ios.yml` called as a reusable workflow,
  `LICENSES-GO.txt`, `SHA256SUMS` of all files, in a draft release; release
  notes in English), `ios.yml` (by hand or from `release.yml`), `pages.yml`
  (invitation page). The store flavor is not built in CI. CI hardening: S24,
  D11.
- **Linux, macOS and Windows ARM64 have not really been built yet** — the
  biggest risks until the first run: Swift (`SecurityBridge.swift`), linking
  the Go bridge on macOS, startup under Xvfb, Linux ARM64, an outdated
  `pubspec.lock` (`flutter pub get` and commit), the GStreamer backend and
  `.deb` dependencies (`dpkg-shlibdeps`), llvm-mingw 20251021 (checked by
  SHA-256) for cgo on Windows ARM64 and `flutter_webrtc` ≥ 1.5 (raised in
  `pubspec`).
- The Dart package is called `zen`; code formatted with `dart format`.
- Next: smaller releases instead of many stages at once; a closed beta of
  20–50 people from one community with the release marker as the channel (A17).

### Dependency licenses

Checked 14 Oct 2026 (`pubspec.lock`, `native/yggdrasil_bridge/go.mod`): Dart/
Flutter packages are under MIT, BSD and Apache 2.0, a few Linux ones (`dbus`,
`geoclue`, `gsettings`, `gtk`) under MPL-2.0. In the Go bridge: **Yggdrasil
v0.5.14 — LGPL-3 with an exception allowing distribution of programs linked
with it** (statically or dynamically), `ironwood` and `phony` — MPL-2.0, the
rest MIT/BSD/ISC. All allow use, also paid or with a fundraiser; MPL and LGPL
only require that their own files (without our changes) remain available — they
are public at the source. The licenses of Go modules (`assets/licenses/go/`,
`dart run tool/go_licenses.dart`) and fonts (SIL OFL, `assets/licenses/fonts/`)
are in the "Licenses" screen; `LICENSES-GO.txt` is in the releases, next to
`zen.exe` and next to `zen` in the Linux archives. Yggdrasil 0.5.14 is the
newest stable release today. Not rechecked for 1.11.0's new build dependencies
(llvm-mingw, GStreamer is a system library).

## 9. Distribution

Research on channels, stores and law: 14–15 Oct 2026 (not legal or tax
advice). Step-by-step plan: `RELEASES.md` §6.

**Facts as of today:**
- **Android developer verification:** since 30 Sep 2026 it applies only to
  installs from participating stores (Google Play, Galaxy Store, HONOR, OPPO,
  Xiaomi GetApps, vivo, Palm Store) in Brazil, Indonesia, Singapore and
  Thailand; installing from a file, also there, is unchanged for now. Nothing
  has changed in Poland and the EU. Globally "in 2027", no month. After that a
  package without registration will install only through an "advanced flow"
  (Developer options, restart, 24 h, a warning at every install) or through ADB
  — this covers updates and "Pass it on" too. Registration: a USD 25 account
  (Play Console or Android Developer Console), an ID and a document with an
  address, package + key fingerprint. Losing the key = no package registration.
  An offline install may need a moment of internet (uncertain). Without
  verification remain phones without Google (GrapheneOS, LineageOS without
  GMS, Huawei).
- **F-Droid and IzzyOnDroid are out**: both require a license approved by OSI
  or FSF, and Zen's license forbids forks and selling. What works: GitHub
  Releases, Obtainium (no review and no license requirements), an own F-Droid
  repository on GitHub Pages.
- **Google Play**: a personal account USD 25; a new personal account needs a
  closed test with at least 12 testers for 14 days; first name, surname and
  country are shown publicly. The store version must be a separate variant (no
  self-update, no `REQUEST_INSTALL_PACKAGES`, no fundraiser link, with
  declarations for the background service and the full-screen alarm, 18+ or
  without dating, other names for "pyramid" and "currency", terms and UGC
  reporting, a child-safety page, targetSdk 36, Data safety with klipy.com).
  The same package and key (uploaded to Play App Signing) lets people move
  between channels as in Signal. Galaxy Store — no fees, the same variant.
  Amazon Appstore on Android was closed (20 Aug 2025). **The `store` flavor
  now exists** (see D12 for what is still missing).
- **iOS:** the only way without an account is SideStore / AltStore with a free
  Apple ID (7 days, 3 apps). An individual USD 99/year account gives TestFlight
  (up to 10,000 testers, a build valid 90 days), the App Store, **AltStore PAL**
  (EU, Japan, Brazil; notarization instead of full review, from 1 Oct 2026 no
  per-install fee for a free app) and Developer ID signing with notarization
  for macOS. Web Distribution in the EU only for organizations (e.g. a
  foundation with a fee waiver). Without a push server iOS will not deliver
  messages in the background.
- **Entity:** to start, a private person is enough. A sole proprietorship and a
  company add nothing for a free app (a limited company ~PLN 40k/year). A
  foundation (KRS free, ~PLN 5–15k/year, mostly accounting) gives an
  organization account, a registered-office address instead of a home one, a
  possible Apple fee waiver (uncertain for Poland) and Web Distribution in the
  EU, grants — it requires transferring the rights to the code. Donations via
  buycoffee.to: anonymous payments are not donations in the sense of the 09.2025
  interpretation — to a tax adviser.

**Recommendation and costs:** stay with the APK from GitHub + Obtainium and by
the end of 2026 register `com.roj.zen` with the release key (USD 25 once); in
parallel a store variant and the 12 × 14 days test (3–6 weeks). iOS: a USD
99/year account → TestFlight + AltStore PAL, then the App Store; sign and
notarize macOS with the same account. A foundation only when the project grows.

Sources: [developer verification — guide](https://developer.android.com/developer-verification/guides),
[FAQ](https://developer.android.com/developer-verification/guides/faq),
[Android Authority 01.10.2026](https://www.androidauthority.com/android-sideloading-developer-verification-first-wave-rollout-3717921/),
[F-Droid Inclusion Policy](https://f-droid.org/docs/Inclusion_Policy/),
[IzzyOnDroid](https://izzyondroid.org/docs/general/AppInclusionPolicy/),
[Play: 12-tester test](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en),
[Play: Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379?hl=en),
[Apple: apps in the EU](https://developer.apple.com/support/apps-in-the-eu/),
[AltStore PAL for developers](https://faq.altstore.io/developers/distribute-with-altstore-pal),
[Apple fee waiver](https://developer.apple.com/help/account/membership/fee-waivers).

| # | Problem | What to do | P, size |
|---|---|---|---|
| D1 | **Android developer verification in 2027** (today only stores in 4 countries) | by the end of 2026 a USD 25 account and registration of `com.roj.zen` with the release key (`RELEASES.md` §4); check offline install through "Pass it on" | P1, S (organizational) |
| D2 | **Signing key**: one key of one person, no copy; fingerprint unpublished | a Shamir copy with 3–5 people (never public), rotation v3, the fingerprint in the README and release notes | P1, S |
| D3 | New package `com.roj.zen` | warn in the release description: the old app stays with its data; move the account by linking a device | P1, S |
| D4 | Partial integrity: "Pass it on" and ADB check the APK certificate, but the official key's fingerprint is not yet entered. **Manifest side done in 1.11.0:** the signed manifest covers the donation link, author, repository and mirrors, the app warns on a mismatch | fingerprint in `apk_signature.dart` (`tool/zen_release.dart fingerprint --write`); set `kReleaseMaintainers` (`tool/zen_release.dart maintainers --write`) so manifests are actually signed (§14.3) | P1, S |
| D5 | Windows without Authenticode — SmartScreen scares | SignPath (free for open-source projects — check against Zen's license) or Azure Trusted Signing; later MSIX and winget | P2, S/M |
| D6 | The fundraiser link (`buycoffee.to/zen`) — **now covered by the signed manifest in code (1.11.0)**, but until maintainers are set and a manifest signed, a copy can still replace it; in stores a link to external payment is forbidden (except the US in the App Store) | enable signing (D4); no link in store variants | P2, S |
| D7 | No installation instructions with pictures | Android (with the 2027 advanced flow), Windows SmartScreen, macOS "Open Anyway" | P2, S |
| D8 | Updates over the network off (empty list of maintainers) | the same certificate + higher `versionCode` + 7 days + human consent (§14.2); the steps to enable are in `RELEASES.md` §8.1, the canary §8.3 | P3, S/M |
| D9 | The license forbids forks: F-Droid **and IzzyOnDroid** impossible, continuity depends on the author | Obtainium (a README button), possibly an own F-Droid repository; a decision about the license (a free license opens both) | P3, S |
| D10 | iPhone only through SideStore/AltStore (7 days, no background work); Linux and macOS unsigned (macOS from version 15: only "Open Anyway" or `xattr`) | an Apple account USD 99/year: TestFlight, AltStore PAL, App Store, Developer ID + macOS notarization in CI; Linux: **`.deb` done in 1.11.0**, Flatpak remains (needs Flutter and Go dependencies collected offline in the manifest — a separate M) | P2, M |
| D11 | **APK key in GitHub Actions secrets** (review K8): taking over an account, token or action is enough for a signed "official" update that will also spread through the network (§14.2) | CI builds an unsigned, reproducible APK and publishes the sum; the author signs offline, CI checks that the difference is only the signature block; until then S24 (SHA-pinned actions, `environment` with approval, key only for tags — done); eventually threshold signing and endorsement of reproducible builds | P1, S/M |
| D12 | Store variant (Play, Galaxy Store) | **flavor `store` done in 1.11.0** (no self-update and no APK install, "Pass it on" as a link, "Updates from the store" card; `ZEN_STORE`/`ZEN_STORE_URL`; built by hand). Remaining: FGS declarations (`connectedDevice`, video), full-screen alarm and location; 18+ or without dating; "Self-government"/"points" instead of "pyramid"/"currency"; no fundraiser link; terms (`TERMS.md` draft exists), reports to the author, CSAE page; Data safety (klipy.com); the 12 × 14 days test; no China, Russia, Belarus and sanctioned countries | P2, M |
| D13 | Legal entity and taxes | a private person to start; a foundation when the project grows (organization account, fee waiver, Web Distribution in the EU); classification of donations — a tax adviser | P3, — |
| D14 | **Android APK size and ABIs** (new): three ABIs in one universal APK (compressed native libraries); `--split-per-abi` possible but self-update and "Pass it on" assume one file; no 32-bit x86 | measure the APK size; decide on split APKs only if too large | P3, S |
| D15 | **Windows ARM64 is untested** (new): built natively on `windows-11-arm` with llvm-mingw, the CI job does not block the release until its first green run | first CI run, then a test on a real device; x64 under emulation is the fallback | P2, S |

## 10. Not done from the plan

Aligned with the code-vs-plan conformance review (14 Oct 2026), updated for
1.11.0. Done and removed from the list: media "only on tap" (`autoDownloadMedia`),
translations and language choice (§25.1), CI (§2.5), building Linux and macOS;
**in 1.11.0:** feature flags, mailbox attachments (A18), limits of connections
and transfer per bridge, paper backup and circle at the welcome, circle and
guardians chosen with the "Close friend" preference, "Media Wi-Fi only"
(limits shown read-only), level permissions and the friend-list/status/group-
invite defaults, the friend list default and the ledger profile without an address,
profile field visibility and nationality, mini-profile and profile tabs, video
metadata stripping and the reshare tombstone, likes/comments paging, hiding and
blocking in threads, aggregated notifications (in-app), follower list/count and
blocking, group board, recording sound, own avatar/cover in the vault and
clipboard expiry, dating re-confirmation and screenshot block, the canary and
mirrors, Nearby S5/S6/blocks/badges/"1 message", graph zoom and clusters, alarm
location in the background and fallback SMS, dinner circle rules and shared
kitty, signed Ask-the-network answers, Common cause, `/m` page and invitation
chat, dating location on demand and the underage report, the pyramid admission
level check, age/gender badge and anonymous statistics, 24 h / 30 d pauses,
level-by-level escalation, comment author in reports, signed evidence (S36),
hiding and appeals (B13), "reached/read" counters, national-section pinning,
issuing above the limit by referendum, price list and paid introduction, tab
grouping, the permissions screen, Linux playback / `zen://` links /
`.deb`, privacy policy / terms / DPIA drafts, the protocol specification draft.

| What | § | Size |
|---|---|---|
| Feature flags — leftovers: the wallet link in the "Introduce me" window and the "From my pyramid" graph filter are not hidden | 2.5 | S |
| Formats from version 1 (reset of numbers, enums by name; ping/pong caps done, the greeting not covered; `v: 1` for settings/profile/flags done) | 2.5, `STATUS` §7 | S |
| GIFs from klipy.com: an external server with an embedded key, outside the exceptions of §1.1 (sender's device only; recipients never contact it; S29, S37 fixed, the design exception remains) | 1.1, 13 | S |
| Spaces `hood`, `date`, `cell`, `treasury`, `event` in the engine; unknown spaces are now **stored for the owner** (limit 1000/log) and forwarded to friends that advertise `spaces1`, and the spaces themselves do not exist (A17) | 1.6, 4 | L |
| Identity on the account key | 6.1 | L |
| A recovery screen "What you will recover if you lose your phone", an encrypted backup export, a copy of `own` at the circle (§6 pt 16) | 6.1, 6.3 | S–M |
| General credentials: no common credential type; "met in person" is a signed `met` entry in `acts` (21.10.2026), but the side that showed the QR is not asked to confirm, and the background service does not sign Bluetooth meetings | 6.2 | S/M |
| Voluntary identity linking (signature of both keys) | 6.4 | S/M |
| Pyramid traffic through relays | 6.4 | M |
| Storage limits: shown read-only, not editable or enforced beyond file limits | 7 | S |
| Mini-profile attached to likes/comments/messages to strangers (a change of the `like`/`comment` format); the graph and "Nearby" calling `showMiniProfile` | 9 | S/M |
| Watching a video while it downloads | 10 | M |
| Signed snapshot of counters; system (not only in-app) aggregated notifications; the blocked follower does not use `store.blockAccount` (it would reject his group entries too) | 11, 12 | M |
| Messages to strangers (apart from a letter through a mutual friend) | 13, 24.1 | M |
| Screen sharing on a second video track (camera + screen at once; A25): test on devices | 13.1 | S |
| Installation instructions with pictures; registration as a verified developer; Authenticode (D1, D5, D7) | 14.2 | S |
| Tor, Wi-Fi Direct, a Bluetooth mesh | 14.2, 28 | L |
| Camouflage: Android icon/name switch done (`activity-alias`es, Settings > Security; not tested on a device, and moving LAUNCHER to an alias may drop the home-screen shortcut on update on some launchers); entry via PIN and iOS/desktop not done. Mirrors of the own screen. Canary and mirrors of the repository done | 14.2 | S–M |
| Approving versions for updates over the network (`kReleaseMaintainers` is empty) | 14.2 | S/M |
| Integrity of releases and fundraiser: code ready (signed manifest with link, author, repository, mirrors); still to do — publish the fingerprint and set the maintainers (S15, D4) | 14.3 | S |
| Bluetooth on Windows, iPhone, Linux and macOS; creating pyramid cells through Bluetooth | 15, 20 | M |
| Alarm: recording from the background (B7) | 16.3 | M |
| Neighbors: the person's address only after "Show my profile" (§6 pt 15); the door in the Android background service (S41) | 18 | S/M |
| Dating: a stronger quorum for underage reports against Sybil (S39) | 19.6 | M |
| Reports: farm-account signals, vouching with penalties, reversing transfers proven as fraud | 21.5 | M |
| Pyramid: scenario "paralysis by absence" in the simulator | 21 | S |
| Privacy of transfers | 23.4 | L |
| Contact economy: prices outside the pyramid (if at all) | 24.1 | M |
| Screen reader labels: the alarm button, graph nodes and tab cards done; remaining the type-scale and a full screen-reader / 200% zoom test | 25.3 | S |
| "Delete from device" with the shortcut lock; wiping old transfers; a button with instructions for law enforcement; a list of hashes from organizations | 26.1 | S–M |
| Linux and macOS: first green CI, Bluetooth, call recording, camera and QR scanner; Linux: Flatpak; macOS: Developer ID and notarization; iPhone without limits (a paid account) | 26.3 | M / L |
| Privacy policy, terms, DPIA: drafts exist in `docs/` — a lawyer's review, correction of the About text (S40), age policy; an actual legal entity (D13) | 27 | S |
| Protocol: the specification draft exists (`docs/PROTOCOL.md`); the trust map, "Your branch has grown" and invitation through an event remain | 28 | M, S |
| Store variant: the rest of D12 (declarations, naming, terms, Data safety, 12 × 14 days test) | 26.3 | M |
| Windows ARM64: first green CI and a device test (D15) | 26.3 | S |

## 11. Order of work

### Done in 1.11.0 (removed from the lists below)

S5, S6, S13, S17, S36, S38 and S18 (for new pyramids); B8, B12 (mailbox
attachments), A18, A20 (mostly), A21, A22 (mostly), feature flags (part of A15),
`ver`/`caps` exchange and golden frames (part of A17), `v: 1` formats (part of
§7), crypto in isolates and the memoized Feed (part of A5/A19), media only over
Wi-Fi (part of A9), kworum from active members (§6 pt 11), the privacy defaults,
paper backup and the "Secure your account" card, graph zoom,
alarm in the background with SMS, issuing above the limit by referendum,
reports with escalation and signed evidence, the signed manifest with link/
author/repository/mirrors and the canary, the Android store flavor and ABIs,
Windows ARM64 (experimental), Linux playback and `.deb`, privacy/terms/DPIA
and protocol drafts. Earlier (1.10.0, round 2): S19–S24, S26–S35, S37, B11,
B13, `SECURITY.md`.

### Now (P1, before wider release)

| What | Size |
|---|---|
| Unreadable data does not delete friends: B11 fixed; the rest of A14 — a non-destructive `peer_unknown`, `friend_remove` only from a human action signed with the account key, a 7-day soft delete | S |
| Door code: the person's address only after "Show my profile" (§6 pt 15) — or Neighbors behind the flag | S |
| Version exchange (A17): done except the mixed-version test | S |
| Trust in releases: signing outside CI (D11); entering the fingerprint and setting maintainers so the signed manifest works (S15, D4) | S/M |
| Translations: events instead of saved strings, `context:` for ambiguous texts (A23) | S |
| About-screen claim about "own encryption of every message" (S40) | S |
| Feature flags: the `ZenCore` composition root (A15 step 0) — **done 21.10.2026**; the background service on the same registry remains | M |
| Recovery: the "What you will recover" screen, an encrypted backup export (§6 pt 16) | S |
| Signing key with a Shamir copy; the fingerprint in the README, releases and `apk_signature.dart`; registration of `com.roj.zen` as a verified Android developer by the end of 2026 (D1) | S |
| Privacy policy and terms: a lawyer's review of the drafts | S |
| Formats from version 1 (§7): reset of numbers, enums by name, caps in the greeting | S |
| First green CI run for Linux, macOS and Windows ARM64 (including `.deb`) | S |

### Soon (P2)

| What | Size |
|---|---|
| Second audit, low: iOS (S25 — `UIFileSharingEnabled` stays) | S |
| Battery: no constant locks, event-driven presence (A9) | M |
| Cryptography off the UI thread: signatures/ring crypto, incremental pyramid fold (A5); other lists lazy, lazy ledger segments (A19) | M |
| Persistence: photos as blobs, own-fork detection (A20) | S |
| Clock tolerances in one place (A21); the rest of the health report: last successful write, rejected frames, file sizes, the global bar (A22) | S |
| Dependency cycles: ports in `domain/`, import rules (A16) | M |
| Unify the three older file mechanisms with the blob layer (A18) | M |
| Tests: Go fuzzing, corrupt data, group calls, `flutter test` on Linux (A13) | S |
| Pyramid: scenario "paralysis by absence" in the simulator (§6 pt 11) | S/M |
| Alarm: recording from the background (B7) | M |
| Installation instructions with pictures; Authenticode on Windows (D5, D7) | S; S/M |
| Apple account: TestFlight + AltStore PAL, Developer ID and macOS notarization (D10) | M |
| Android store variant: the rest of D12 (Google Play and Galaxy Store) | M |
| Linux: Flatpak | M |
| Windows ARM64: device test (D15) | S |
| Accessibility: type scale, a full screen-reader test | S/M |
| A simple welcome (name → photo → add a friend → circle) | S |
| Wi-Fi-only handling for mailbox blobs (S42) | S |

### Later (P3)

| What | Size |
|---|---|
| Second audit, remaining: S38 (phone UDP relay on all IPv4), S39 (Sybil quorum) | S/M |
| One data owner (the service), the UI as a client; encrypted SQLite | L |
| Identity on the account key; spaces `hood`/`date`/`cell`/`treasury`/`event` | L |
| Pyramid traffic through relays, no device address | M/L |
| Linux and macOS: Bluetooth, call recording; a desktop with two panels (A24) | M |
| iPhone: background work, Bluetooth, push (needs a paid account and a push server, §26.3) | L |
| Updates over the network per §14.2 | S/M |
| Mutual verification of the official version (key attestation) | M |
| A second video track (A25) | M |
| Tor, Wi-Fi Direct, a Bluetooth mesh; mirrors | L; S–M |
| Protocol trust map | S |
| Privacy of transfers | L |
| Splitting the code into packages (A12) | L |
| Organizational decisions: a license for the case of the author's disappearance (a free license would open F-Droid), a foundation (organization account, fee waiver, Web Distribution in the EU), renaming "Pyramid" | — |
