# Changelog

## 1.11.0 — 20.10.2026

### Platforms
- **Android: three ABIs in one universal APK** — arm64-v8a, **armeabi-v7a** (older 32-bit phones) and **x86_64** (ChromeOS, emulators). The Go bridge is built per ABI and rebuilt only when it changed; native libraries are stored compressed so the APK stays about the same size. (x86 32-bit is not available: Flutter has no release engine for it.)
- **Android "store" flavor** (`flutter build appbundle --release --flavor store`; for Google Play and Galaxy Store, built manually): no `REQUEST_INSTALL_PACKAGES`, no self-update (the screen says "Updates come from the store"), and "Pass it on" becomes a dialog with a link.
- **Windows ARM64** (`Zen-Windows-arm64.zip`, experimental): native build on `windows-11-arm`, Go bridge through llvm-mingw. It does not block a release until its first green run; the x64 build also runs on Windows 11 ARM under emulation.
- **Linux x64 and arm64: `.tar.gz` plus new `.deb`** (`Zen-Linux-x64.deb`, `Zen-Linux-arm64.deb`; Debian, Ubuntu, Mint). Audio and video playback through GStreamer (own `video_player` backend), a `.desktop` file (menu, `zen://` links, Wayland icon), AppStream metadata, `install-desktop-entry.sh` in the tarball, single-instance runner so a link from the browser reaches the running Zen. Flatpak: not done.
- iOS (`Zen-unsigned.ipa`, iOS 15+), Windows x64 and universal macOS (12+, `Zen-macOS.zip`) unchanged.

### Translations
- **21 languages everywhere**, not only in the Dart UI: the invite page (`tool/pages`, language from the browser or `?lang=xx`, right-to-left for Arabic), iOS and macOS `Info.plist` strings (21 `<code>.lproj` folders), Android resources (`values-<lang>`; incoming-call screen, notifications, PiP, biometrics, installer, share), Linux `.desktop` comments. Everything outside the app UI now defaults to English.
- The new `docs/PRIVACY.md`, `docs/TERMS.md`, `docs/DPIA.md` and `docs/PROTOCOL.md` are in English; the About screen links to the privacy policy and the terms.

### Security
- **Network:** no more hard-coded 8.8.8.8 / 1.1.1.1 on Android — the bridge asks the system resolver (including Private DNS) first and falls back to a DNS-over-TLS list (S38). The call UDP relay accepts a local socket only if its first datagram is an ICE check with the call's own username (desktop: listens on 127.0.0.1 only). The public bridge port goes through a Go limiter (4 connections per IPv4 or /64, 128 total, 1 MiB/s and 2 GiB per source per day, 32 GiB total). "Pass it on" serves on one chosen or best network and skips cellular, VPN and virtual interfaces (S13). The "Answer" route is tied to one call number (S17). Optional local-network (multicast) discovery exists in the bridge, off by default and without a Dart side yet.
- **Nearby (S5, S6):** a private per-phone key that never leaves the phone; friends get only a mask key, one-way hash-chain anchors and their own pair key, so nobody can forge another friend's presence. Alarm waves are signed with the pair key. The BLE token rotates every 10 minutes together with the MAC address. Greeting to a stranger carries no address — the reply goes over Bluetooth, and addresses are exchanged only between people who answered each other. Temporary compatibility with 1.10.0 phones.
- **Releases (S15):** the signed release manifest now covers the donation link, author and repository, plus mirrors; the app warns in red when its own values differ. New signed **canary** statement, 2-of-3 like a release; `tool/zen_release.dart` gets `maintainers`, `canary`, `sums` and `fingerprint`. Network updates stay off until maintainers are configured.
- **Pyramid rules generation 2** (`rules = 2` for new pyramids; old ones switch by constitutional referendum): a record that throws is rejected deterministically (S18), quorum counted from active members, over-limit issuance by whole-pyramid referendum, content bans by entry id with the signed original attached (S36). New record types `natpin` and `badge`.
- **Storage:** hidden file names for `meet/list/` and `ledger/` as well (old files migrate); Windows data moved from Roaming to `%LOCALAPPDATA%` with a one-time safe move; 20 MB limit warns from 50% and compresses harder from 75%; stale `*.tmp` files are cleaned up; clipboard copies expire after 60 s everywhere.
- **Mailbox attachments** are chunked and encrypted with a fresh key (ChaCha20-Poly1305); mailboxes see only ciphertext (see Features).
- **Profile images** (avatar, background) are moved into the encrypted media vault.
- **Forward compatibility:** unknown log spaces are kept for the owner (max 1000 entries per device log); golden protocol frames pinned in `test/wire/golden_frames_test.dart`.

### Privacy
- **Friendship levels have teeth:** a weak friend sees neither the friend list (they can ask via "Introduce me") nor statuses other than "Do not disturb"; the new default list audience is "Friends and close friends". Changing a level resends the list and status right away. People met in person are asked "How close are you?".
- **Group invites:** "Who can invite me to groups" (Anyone / All friends / Friends and close friends (default) / Close friends only); an invite below the threshold is rejected immediately.
- **Per-field profile visibility:** status, About me, photo, background, nationality, friend count, follower count — each Public / All friends / Friends and close / Close / Only me. Public fields go in the public entry, the rest in encrypted per-audience entries.
- Your device address goes into the public profile only when you have a public post or share.
- **Age gate:** before Dating, Pyramid and Wallet the app asks for a date of birth or "I am 18 or older"; the answer stays on the device, and under-18s see the sections closed.
- **Dating:** "I'm going on a date" can request your location on demand (the friend asks, your phone asks you or answers automatically if you agreed); "Report a minor" disables a profile locally at once and reports it to the pyramid, and a phone that receives reports from 2+ different reporters disables it too; re-confirmation with password or biometrics when entering Dating and after returning from the background.
- **Screen sharing:** system notifications are shown without content, a permanent red banner says the whole screen is visible, and Android older than 14 gets a warning first.
- Offline mailbox attachments use per-sender quotas and ciphertext only; recorded calls beep for all participants.
- "Media over Wi-Fi only" (default for new installs).

### Features
- **Calls:** a "Board" tab in groups (a board post is an ordinary group message with a `grp-board-` id, so older versions show it as a message); an audible signal for everyone when recording starts. Camera and screen at the same time: not done, the screen still replaces the camera.
- **Mailboxes and attachments:** photos, videos, files and longer voice notes for an offline friend wait at their mailboxes and arrive when they return, even if the sender is offline too. Per-sender limit 20 MB by default (Settings → Offline mailboxes → Attachments: off/5/10/20/50 MB), 200 MB total, 14-day expiry; live WebRTC stays the fast path. Compatible with 1.10.0 devices.
- **Profile and feed:** per-field visibility, nationality (up to 3 country codes), mini-profile card, other-person profile with Add / Follow / Message and tabs Posts · Photos · Videos · Thanks · Info; signed follows with a followers list and blocking; "Liked by you, Bob and 1,284 others"; the author can hide comments and block people in their threads; paged reaction bundles (up to 2000 likes, 300 comments); grouped bell notifications; metadata stripped from MP4/MOV/M4A; a deleted post's tombstone reaches resharers.
- **Meetings:** the friend graph zooms (1–8x), groups into clusters and shows friends-of-friends labels; Alarm gets a fresh location from the background and a backup SMS to up to 5 numbers; dinner circles of 4–8 people, "vouching" for guests, shared pot; "Ask the network" answers are signed by the answering device; a "shared cause" plan with "I'll take it" claims.
- **Neighbours:** door code v2 with exactly one door-inbox address (old stickers still read), a link `https://…/Zen/m#<code>` and a web page `/m`; "Ask" about an invitation.
- **Pyramid:** pinned posts in the national section, age and gender badge, anonymous branch statistics (from 5 people), "Delivered / read" counts, price card in the profile, paid introduction (the broker is paid only after the introduced person agrees), escalation of reports level by level, 24 h / 7 d / 30 d breaks, only a friend of at least level "Friend" can be admitted.
- **Onboarding and recovery:** paper backup of the account key (56 characters in 14 groups, QR `zen-key:<code>`, with a check of two random groups) and restore from paper; a "Secure your account" card after the permission step and a reminder in Settings.
- **Permissions and diagnostics:** location, background location, exact alarms and vendor-specific battery instructions (Xiaomi, Samsung, Huawei, OnePlus, Oppo/Realme, Vivo); a "Welcome to Zen" card; **"Why is it not working?"** screen (network, background, notifications, battery, clock, free space, "Copy report"); clock-skew bar; six tabs plus "More"; accessibility labels.
- **Versions:** friends exchange app versions, and Settings shows a quiet "Friends have a newer Zen" bar; feature flags ("Experimental features": Pyramid, Wallet, Dating, Neighbours); `v: 1` format versions for settings and profile.
- **Performance:** heavy encryption of data over 64 KB runs in a short-lived isolate (byte-identical output), the feed is recomputed only when the log changes and is built lazily.
- **Android bridge/Linux notes:** Go build info export (`YggGetBuildInfoJson`).

### Docs
- New in English: `docs/PRIVACY.md`, `docs/TERMS.md`, `docs/DPIA.md` (draft impact assessment), `docs/PROTOCOL.md` (protocol specification derived from the code, with [V]/[P]/[?] markers).
- Renamed: `STATUS.md` → `docs/STATUS.md`, `PLAN.md` → `docs/PLAN.md`, `RELEASES.md` → `docs/RELEASES.md`, `TESTING.md` → `docs/TESTING.md`.
- README and CHANGELOG are now in English (README also in Polish: `README.pl.md`); `SECURITY.md` is English-first.

## 1.10.0 — 14.10.2026 (first public release)

### Round 2: languages, Linux and macOS, second audit
- **21 languages:** Polish, English, German, French, Spanish, Italian, Portuguese, Dutch, Czech, Hungarian, Romanian, Turkish, Russian, Ukrainian, Arabic (right to left), Hindi, Indonesian, Vietnamese, Chinese, Japanese, Korean. Zen picks the system language (English if unknown); **Settings → Language** changes it instantly. Source strings are Polish in `t()` / `tn()`, translations in `assets/i18n/<code>.json`, checked by `dart run tool/i18n.dart` and `test/i18n_test.dart`.
- **Linux and macOS:** new release files `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz`, `Zen-macOS.zip` (Apple Silicon and Intel, macOS 12+), unsigned, built by GitHub Actions; `SHA256SUMS` covers all release files. macOS: Touch ID through the Secure Enclave, screen protection, no sandbox. Linux: key in GNOME Keyring / KWallet, tray through AppIndicator. No Bluetooth, call recording or camera on either; no voice-note or video playback on Linux. Untested before the first CI run.
- **Second security audit fixes** (`docs/STATUS.md` §4.2): account recovery bound to the account (S19), bridge memory limits (S20), proof of device address (S21), file warnings (S22), mailboxes only for friends (S23), corrupted data no longer removes friends (B11), notification and screen privacy (S27, S30), GIFs on tap (S29), pinned CI actions and APK key only for approved tags (S24), `SECURITY.md`.
- **"Report":** reported content can be hidden locally, decisions can be appealed, the dialog no longer promises "Remove from my device" (B13).
- **Docs:** `docs/STATUS.md` with the second audit and architecture review, plan `docs/PLAN.md` (version 13) matching the code, `docs/RELEASES.md` (channels, store requirements, Android developer verification, iPhone, costs); README with languages, Linux, macOS and an honest note about GIFs from klipy.com.

### Before release: security, currency, iPhone
- **First launch:** after the password, a "Permissions and Bluetooth" screen (notifications, Bluetooth, full-screen alarm, background work, optional microphone and camera), also available in Settings. No more series of system dialogs.
- **Bluetooth:** steady, frugal advertising while visible (also from the background service), restored after Bluetooth toggles; scanning only on the "Nearby" screen (background scanning off by default).
- **Friends of friends (B1, B2):** friend lists in separate files with limits; frames from non-friends wait for approval; ping/pong carry digests and missing data is re-requested.
- **Graph:** search (diacritics-insensitive), filters, shortest path to a person, lines between friends who know each other, "Friend lists: from X of Y friends" with "Ask".
- **Consent as currency:** "Who sees my friend list" (all / on request / nobody), "Ask for an introduction" (a mutual friend passes it on, the other person decides), "Write a letter" through a mutual friend (max 3 per week per person), "Ask for an opinion". Within a pyramid a broker can price an introduction.
- **Pyramid:** no parties (party founding and primaries removed). Reports and appeals only from members, with limits (S1); the treasurer signature cannot be replaced or removed (S12); limits for proposals and market messages.
- **Currency:** hard limits (10^15 hundredths per amount, 2^60 per balance), saturating sums, re-confirmation (password or biometrics) before sending money, screenshot block in the wallet, all amounts in hundredths.
- **Money across pyramids:** merging converts balances at an agreed rate (like issuance: 2 of 3 of the top, 30-day limit, 24 h wait, veto); exchange through an "exchange agent" in both pyramids with both payments locked by one key and refunded on failure.
- **Signed Bluetooth alarm (S2):** HMAC-SHA256 with the Nearby secret, valid ±10 min, replays rejected; only a verified friend alarm rings. Sent before state is saved (B10).
- **Friends' attachments, voice notes and photos encrypted on disk (S3)** under random names; photos decrypted only in memory.
- **Stores only in the current envelope (S4)**, node configuration and verified-signature memory protected.
- **Panic password wipes everything (S7):** stops the background service, then clears cache, temporary files, `Android/data/…/files`, Zen folders in Documents and Downloads, and saved copies.
- **APK signature (S9):** "Pass it on" and ADB check the certificate before sending and installing.
- Old invite formats removed (S14); a code, a link with the code after `#` and `zen://c/CODE` work. All older-format and protocol-version compatibility code removed before release (one exception: re-sealing the node configuration so the address does not change).
- **Smoothness (B3, B5):** in-memory presence, delayed writes, screens watch only what they show.
- A friend's name always comes from their latest profile.
- **Dating like Tinder:** card stack, right "Yes", left "No"; "Match-make" and "Ask for an opinion" on the card.
- **Statuses redone:** highlighted "Your status" card with a countdown; friends' statuses grouped by kind.
- **Weekend plan:** a fourth form in Meetings — a loose plan with a reach, "Joining" / "Maybe"; once enough people join it becomes an event with a chat.
- **iPhone:** Zen runs on iOS (SideStore / AltStore, free Apple ID); `Zen-unsigned.ipa` built by GitHub Actions. Features iOS forbids (background work, background Bluetooth, button alarm) are marked unavailable.
- **Building:** the Go bridge builds itself on `flutter build apk` / `windows` (only when sources changed). GitHub Actions: tests on every push, release files on tag, invite page on Pages.
- **Licenses** of Go modules and fonts in "About → Licenses".
- **Invite page** `robertostrowskijagoda.github.io/Zen/#CODE` opens Zen or shows downloads; donations: **buycoffee.to/zen**; a few words from the author in "About".
- **First-launch password fix:** the screen did not close after setting a password (the permissions step took over its navigation). Fixed, with a test.
- **Honest biometrics:** the first-password question says any fingerprint stored on the phone will unlock Zen; the default is "Password only". Windows: "Windows Hello unlock" with a warning in Settings.
- **Icons:** Feed as a newspaper, Wallet as a dollar sign; one pyramid drawing everywhere.
- **License:** PolyForm Strict 1.0.0 with additional permissions — anyone, including companies, may use Zen for any purpose; it may not be sold or bundled into paid products; the author and donation link must stay; pull requests welcome, forks and modified versions forbidden.
- Dart package `zen`, version **1.10.0 (10)**.

### Names from profiles, safe media, recordings in posts
- **A friend's name comes from their profile** and cannot be changed (newer wins). Instead of "Rename" there is a **nickname** visible only to you, shown in small italics under the name and shared across your devices. Names from others are stripped of control and direction-changing characters and trimmed to 60.
- **Virus protection for photos and videos** (`media_guard.dart`): every incoming photo is decoded in pure Dart and re-encoded, so the system image decoder never sees the original (the class of WebP-2023 attacks); oversized "photos" are rejected before decoding. Videos and recordings must have a valid container (MP4/MOV/M4A/WebM/Ogg/MP3/WAV), otherwise they become a plain file Zen will not play. Type, MIME and file name come from the content. Files that could run a program (EXE, APK, scripts, shortcuts, macros) get a warning before "Save a copy"; Zen never opens files itself. Camera photos sent in chat lose GPS.
- **Voice notes and audio recordings in posts:** "Record a voice note" and "Insert a recording from file" (up to 25 MB); in chat, "Audio recording from file". Playback only on tap.
- **The repository is named `Zen`:** invite links `https://github.com/robertostrowskijagoda/zen#CODE`.
- **Zen codes straight into the app (Android):** with "Open supported links" enabled (Invite → "Zen codes straight into the app"), a code scanned with the ordinary camera opens in Zen. Flutter's built-in deep links disabled.
- **About → Your own Yggdrasil bridge:** how to run a permanent node without Zen.

### Last round: convenience, security, release
- **Biometrics off by default;** asked once when setting the first password. Fixed: the first-password screen could not open any dialog. Four broken tests fixed.
- **Default lock after 5 minutes in the background.** Lock-screen texts say the background service still receives messages.
- **Security fix:** attachment file names from others are sanitized — previously "Save a copy" could overwrite files in the app directory (path traversal).
- **Settings stored as JSON with named fields** instead of ten binary format versions; an unreadable old file means defaults.
- **Default theme: system.** Black logo in the light theme.
- **Left panel:** friend graph first; Wallet before Bluetooth; Bluetooth before Invite; new pyramid and feed icons; "Lock now" on the panel. Buttons shrink to fit (checked at 360×568: 13 tabs and lock).
- **Windows tray icon** really rounded now; Windows release rebuilt.
- **"Pass it on"** easier to find: Invite ("Friend has no Zen?") and About.
- **"About" rewritten:** donations first, then what Zen is (including the pyramid and grassroots politics), "Why", how to use, privacy with the recovery circle (up to 6 friends: password + 2 of them after 24 h, or 4 of them without a password after 7 days), platforms, Yggdrasil, why not in stores, how to check it is not a virus, official GitHub link, licenses.
- **Own status clearly marked** ("YOUR OWN STATUS", "Own" pill).
- **Desktop bridge** stays on by default, silently; the "Help others connect" switch is at the bottom of Settings (Advanced → Network and service).
- **One QR code for everyone:** an invite is a link `https://github.com/robertostrowskijagoda/zen#CODE`; the code is after `#`, so it never reaches the server. A camera without Zen opens the README, the Zen scanner adds the friend at once. Old `zen://` codes still work.
- **Android package `com.roj.zen`** (was `com.HuraganKodu.zen`) — a new app to the system; the old install stays beside it with its data.
- **License** (`LICENSE`): builds from unmodified code may be redistributed if SHA-256 matches the published one; your own build may be given to others but not published as "Zen".
- **README for ordinary people:** download, what to do after scanning a code, installation (including the 2027 path for unverified developers with a 24 h wait), Windows SmartScreen, virus checking, why not in stores, privacy, Yggdrasil, donations, license summary, developer part.
- **Cleanup:** removed `zen-site/` and the Pages workflow, `screenshots/shots_test.dart`, `tool/ui_tour/ui_tour_test.dart` with `run.ps1` and the unused `logo_rounded.png`; all code `dart format`-ed.
- **Docs:** plan (`docs/PLAN.md`) updated and shortened; new `docs/STATUS.md` (state, known bugs, security, work order) replaces `KIERUNKI.md` and `AUDYT_BEZPIECZENSTWA.md`; `PUBLIKACJA.md` merged into `docs/RELEASES.md`.

### After the phone test
- **More "right now" statuses:** Need help urgently (louder notification, separate red button), Can help, Going for a walk, Want to eat together, Want to play — and a **custom status** (own words and emoji). Compact pills instead of big tiles. Older versions do not show the new statuses.
- **"People nearby" has its own button** in the left panel. Full Bluetooth scanning with the screen open; otherwise a short look-around every 5 minutes.
- **Alarm with confirmations:** the friend's phone replies "arrived" and "seen"; the alarm screen shows who got it, who saw it and who responded, with retry.
- **No whole-file rewrites:** conversations in segments of 200 messages, pyramid records in an append-only log (old format migrated automatically).
- **Fewer freezes:** verified pyramid ring signatures cached on disk, first verification in the background.
- **Android no longer kills the service after 6 hours** (Android 14+: `specialUse` service type); if the system stops it anyway, a "Zen is not receiving in the background — open it for a moment" notification appears.
- **App sharing through Quick Share / Bluetooth** (new button in "Pass it on").
- **Same colors in light and dark themes;** the "ZEN" mark on the start screen.
- Someone in two pyramids sees the one they joined most recently.
- **Network identity survives a corrupted file:** node configuration written atomically with a backup (previously a corrupted file meant a new address and losing contact with friends).
- "Meetings" state from an unknown (newer) version is no longer overwritten with an empty one.

### The network carries itself: computers are bridges (stage 2 finished)
- **Every computer is a bridge** (§5.1; on by default). The PC app opens a router port itself (UPnP, else NAT-PMP), asks friends to verify from outside that it is reachable, and only then announces the bridge. Port and announcement are renewed every half hour, withdrawn when unreachable, closed on exit.
- A computer with a public address (no router, or IPv6) is a bridge too. The PC node listens on IPv4 and IPv6 (`tls://[::]:32913`), also on Linux and macOS.
- **Bridge status in Settings → Network and service:** working / router did not open the port / router refused (UPnP off) / no public address (CGNAT) / firewall blocks / waiting for a friend online, with "Check now" and hints. A manually forwarded port works too.
- **Bridge checks:** the app waits for the Yggdrasil handshake instead of a bare TCP connection; bridges must have a public IP (no names, no home networks), so nobody can send the app "knocking" on devices in your network. A friend checks at most 4 addresses per minute for others.
- **Bridge choice by speed and networks:** fastest working bridges spread across address blocks; rechecked every 6 h, dead ones get a second chance after a day and are dropped after three failures.

### Security audit (`docs/STATUS.md`)
- A stranger can no longer become your friend with one packet (`friend_accept` without your invite goes to confirmations).
- A locked app no longer breaks friendships or loses invites: signals wait until state is loaded after unlocking.
- Two people who invite each other at the same moment become friends at once.
- Flood and "bomb" protection: zstd, signal fragments, photos and images, attachments, friend requests, group invites, events, dating bundles, offline mailboxes, alarms, questions.
- Pyramid: resilience to bad ring signatures, double votes, date rollback, veto and issuance-limit bypass, constitutional change without quorum; sync only with friends.
- Windows: data key sealed only when Windows Hello is enabled.
- Passwords: changing needs confirmation, password and panic password cannot match; panic destroys keys first.
- Device linking with a commitment; conversation file names do not reveal contacts; writes bound to the file key.
- A link can no longer answer a call or replace the caller's name; notification content hidden for dating and pyramid too.
- Android: no data backups, call screen unavailable to other apps, own release signing key prepared (`android/key.properties`). "Pass it on" shows the file's SHA-256.
- Test pilot only in debug builds; no logcat logs in release.

### Polished look (reviewed at 320–412 dp, text up to 150%, light/dark, desktop)
- Friend graph scrolls with its legend and no longer overlaps at small sizes; friends do not cover "You".
- "Meetings" tiles and "What do you feel like" statuses collapse to one column instead of breaking words.
- On desktop every screen keeps the same narrow layout.
- Amounts with thousands separators, pyramid levels from 1, no "§" in texts, and other small fixes.

### Gaps from the plan filled in
- **"Report" everywhere:** posts, messages (also in groups) and profiles; reported content can be hidden at once; in the pyramid it goes to the reports delegate or the top.
- **Dating:** bundles encrypted with a separate key (ChaCha20-Poly1305), key given on request; vouches signed with a vouching key; several photos; "Dating" status 💘; "Thank the matchmaker"; "I'm going on a date" deadlines watched in the background.
- **Events:** shared album (photos from attendees, from 15 min before start), thank-you cards, organizer tips in pyramid currency.
- **Alarm:** audio recording for close friends and an optional Bluetooth wave to nearby phones.
- **Alarm shortcut: 5× power button** (Android, off by default): five quick presses (~4 s), also with the screen off and Zen closed, raise the ordinary alarm; only the PIN cancels it, the panic PIN works as always; vibration confirms. Warning about the system "Emergency SOS" that reacts to the same gesture.
- **Nearby alarm with the app closed:** with the option on, the Android background service shows nearby phones and receives alarm waves; each wave rings only once.
- **"Also look around in the background"** (off by default): every 5 minutes 10 s of frugal scanning, only to mark friends in range as "met in person".
- **Neighbours:** flat photo, removing a neighbour with a new key for the rest, revealing yourself to neighbours.
- **Event ticket pinned to the phone:** "I'll come" sends the organizer a key held only by that phone; at the door the phone shows a live code (refreshed every 20 s), accepted once within ±90 s. Guests on older versions get an ordinary ticket, and the organizer sees "unpinned ticket".
- **Neighbours: a removed household member cannot forge a new flat key.** Each member phone has its own key known from the profile; removal votes and the new-key notice are signed by it; neighbours accept a new key only with the signature of a remaining member and a majority. Two competing new keys produce a warning, and scanning the new door code settles it.
- Fix: a shared event album disappears from disk with the event even if the app never loaded it.
- **Currency:** tip for an answer in "Ask the network", prices by friendship level, announcements through broker chains, moving a whole pyramid as a branch into a larger one.

### New look for the whole app
- **New palette:** deep dark (or light) base tinted with the accent and a gradient accent. **Color choice is back** (Settings → Appearance: 27 colors + light/dark/system); the default is "Zen" purple.
- **Readable typography:** sans-serif everywhere, sentences instead of ALL CAPS.
- **Every screen redone:** Inbox and chats (gradient bubbles, new composer), profile (cover, avatar in a gradient ring), Feed, Meetings, events, Table for Six, dinner circles, Ask the network, nearby, alarm, dating, neighbours, graph, pyramid, Invite, settings, lock screen, calls, start screen.
- **Own buttons in the left panel** for Dating, Neighbours, Friend graph and Alarm (red, at the bottom).
- Elements no longer overlap and fit narrow phones (checked with phone-size screenshots: `tool/ui_tour`).

### Fixes
- **Lock after leaving the app** is configurable: Settings → Security → "After leaving the app": 5 s, 30 s, 1 min, 5 min, 15 min, 1 h (default 5 min).
- Events: "Meal" instead of "Dinner / supper", "Friends of friends of friends" instead of "2 steps away"; explanation of Table for Six when creating an event.
- Neighbours: an "Add" button next to a flat that scanned your code replaces the toggle.
- Dating: no "I am 18" field (age is enough). "Thanks" tab fits the screen. Creating a pyramid (and other dialogs with text fields) no longer crashes.
- **Important:** data loaded while the app is locked no longer overwrites friends and conversations with an empty state (the write waits for unlock); same for meetings, dating, neighbours, pyramid. The background service starts again (dependency error at startup).

### Pyramid, power, currency (stages 9–11, §20–24, §28) — new "Pyramid" tab
Everything is implemented; **use will start later** (after the audit, once there is a community).
- **Joining in person:** the cell leader's QR code, year of birth and gender confirmed at entry (only a hash is public).
- **Cells:** leader swap 2 of 3, **anonymous vote request and anonymous vote** (ring signature — nobody knows who voted how), leaving, taking a free seat, absence after 60 days, removal only by one's own cell, moving under another leader, **merging pyramids** (the smaller one joins as a branch).
- **Power:** top decisions 2 of 3, delegations (scope, limit, deadline, sub-delegation, revoking), bans with **immunity** of higher levels, **"Report"** in dating and the pyramid (delegate or top, open decision, appeal).
- **Referenda counted by tree** (votes go only to the cell leader, verifiable sums upward), **constitution** changed by referendum, **national section** with a lead, political and national posts.
- **Currency:** issuance with a 24 h veto window and term limit, 15 treasurers (transfer valid with majority signatures, no double spend), conditional payments; **access market** — paid mailbox, introductions, sharing, announcements.
- **Crisis mode:** alarm with reach and a Bluetooth wave to nearby phones, also without internet.

### Multi-client testing (`docs/TESTING.md`)
- **Network simulator** (`SimNetwork`): virtual clock, delays, loss, offline phones, partitions; 20+ pyramid, dating and neighbours scenarios in `flutter test`, including chaos with repair.
- **Several apps on one computer:** `zen.exe --zen-profile=NAME` (separate data and keys), `tool\multi_client.ps1 -Count 4`.
- **Pilot** `/x/…` and `dart run tool/zen_drive.dart pyramid 48888 48889 48890 48891`; phone through `adb forward`.
- Fixes found by tests: proposals with mixed requirements (top + cell) no longer go out half-signed; absence can be declared for a person with a single neighbour.

### Dating through friends (stage 8, §19) — "Meetings → Dating"
- **Only up to 3 steps**, always with someone in common: "You know each other through: Bob → Kasia".
- **Nobody knows you are dating:** every phone weekly sends and forwards identical bundles — with a profile or an empty decoy.
- **Dating profile** built in one tap from the main profile, with preferences (gender, age, 1–3 steps) and hiding from chosen friends or whole groups.
- **"Yes / No":** a pair forms only on "Yes" + "Yes"; "No" sends nothing.
- **Pair chats, introductions and likes are encrypted** and travel through friends who do not even know whom they are from.
- **Ask for an opinion** from a mutual friend, **matchmaking**, **vouches** on the profile.
- **"I'm going on a date":** a friend sees where you are; if you do not confirm "All OK", they get a reminder, then an alarm.

### Neighbours (stage 7, §18) — "Meetings → Neighbours"
- **Neighbour profile of a family / flat group:** "Novaks · flat 12", "About us", invitations (date, seats), "We offer", "We need". Neighbours do not see your accounts.
- **Household members** (no limit): another phone joins by scanning the member code. Anyone can edit the profile and reply; everything syncs.
- **Moving out:** the old door code stops working, neighbours are informed, new tenants start from scratch.
- **Door code:** printable A6 sticker (PNG) with its own password; "New code" invalidates the old one.
- **My neighbours:** scan a neighbour's door — both flats are on each other's list. Messages between flats, sign-ups with seat limits, muting, removing.
- **Nearby invitation:** send an invitation over Bluetooth to Zen users in range; they add you as neighbours with one tap.
- Fix: after returning to the app, events, questions, Table for Six and dinner circles load what the background service received.

### Meetings (stage 6, §15–17) — new "Meetings" tab
- **Right now:** "Want to talk", "Want to go out", "Need help", "Do not disturb" — for an hour, until end of day or until cancelled, with a note, for all friends or only close ones.
- **Alarm:** hold for 3 seconds — close friends get it at once, full screen, with sound and your location (refreshed every minute); you see who is coming. Cancel with the ordinary PIN; a separate panic PIN cancels it on screen but friends are warned you may be coerced. A wrong PIN cancels nothing. "Call 112" button. Works with the app closed.
- **People nearby** (Android, Bluetooth): friends with names, strangers as a pseudonym rotating every 15 minutes, distance, "Write" to a stranger without revealing your account, "Invite as friend" with the "met in person" stamp.
- **Events through friends:** party, meal, meeting — for chosen people, friends, friends of friends or further. Guest list shows how many you know and who brought whom. Seat limit, "+1" with consent, QR tickets checked offline at the door, "We met" after the event.
- **Table for Six:** a dinner with people two steps away — Zen picks 5 guests who know each other the least.
- **Dinner circles:** cooking rota, swaps with consent, allergies, "who brings what".
- **Ask the network:** a question to friends (further only manually), answers come back with "friend of Bartek".
- **Friend graph:** you in the centre, close friends, friends and friends of friends, status colors, mutual friends. New setting "Show my friend list to friends".
- Android: new Bluetooth permissions (no location) and location (alarm only); geolocator 14 (with `dependency_overrides: uuid ^4`).

### Resilience: network updates and "Pass it on" (stage 5, §14.2)
- **Updates from friends, without a store or server** — transfer ready, **approval to be decided**. A new version travels as an ordinary file from friend to friend, waits **7 days** after first seen and **never installs itself** (Android opens the system installer; on a computer the installer lands in Downloads). Approval is currently done with maintainer signatures, but we do not want people holding publishing keys, so network updates are **off** until another method is decided (§14.2).
- **Settings → Updates and Pass it on:** version, state of a new version, "Load update from file" (`.zenupdate`).
- `tool/zen_release.dart` and `docs/RELEASES.md` describe the current (disabled) mechanism.
- **Pass it on:** the phone hands Zen to someone nearby without internet — own hotspot (Wi-Fi QR) plus a second QR with a download page. Also works on the same Wi-Fi. Only that one file is served, at a random address, for at most 20 minutes.
- **From a computer by USB:** "Install" with a connected phone (via `adb`), including a newer signed version.
- **HTTPS-looking traffic:** a computer bridge asks the router for external port 443 first.
- Android: new permissions — installing apps (updates) and Wi-Fi / nearby devices (hotspot).

### On-device data protection (stage 4 finished, §14.1)
- **App password required by default** (at least 8 characters); skipping is a conscious choice with a Settings switch.
- **Argon2id** for password and panic password; old passwords upgrade at the next unlock.
- **Hardware-backed biometric unlock:** the key lives in Android Keystore (StrongBox if present) or a Windows TPM (DPAPI without), opened by fingerprint / face / Windows Hello. A new fingerprint invalidates the key — you type the password once.
- **Account key leaves memory** together with the data key when the app locks.
- **Re-confirmation** (biometrics or password) before Account and recovery, Devices and Call recordings; valid for a minute.
- **Screenshot and screen-recording block** in chats, groups, recordings, account and devices (Android and Windows); can be turned off.
- **Disappearing messages** in chat and group menus: 1 hour, 1 day or 7 days; the same setting reaches the other side and your other devices; messages vanish everywhere together with files and never enter durable account backups.
- **Panic password** also deletes the key in the security chip.
- **Rooted-phone warning** in Settings → Security (su, Magisk, LSPosed, Frida, test keys), without blocking.
- Android: the app now runs on `FlutterFragmentActivity` (needed for the system biometric prompt).

### Account on several devices (stage 4)
- **Settings → Devices:** list, "Link a new device", "This is the new device: join the account", "Unlink".
- **Safe linking:** the new device shows its code (QR or typed); both screens show the same 6 digits; only after confirmation the account key travels, encrypted with one-time keys.
- **Friends see one person:** messages and calls reach every device; answering a call on one silences the others; what you write on one device appears on the rest.
- **Friends and groups are the same everywhere:** stored in the account, encrypted so only your devices read them. Friends keep an encrypted copy, so a **recovered account comes back with friends and groups**.
- **Unlinking a lost or stolen device:** from then on nothing from it is accepted and it gets no messages; the device itself shows it was unlinked.
- Engine fix: the device cut-off point is counted per space.
- **Chat history on a new device:** all conversations so far (files up to 25 MB each), encrypted for your devices only.
- **Sent photos, files and voice notes** (also in groups) appear on other devices, not just text.
- **Removing a friend, leaving a group, renaming and blocking** on one device happen on all.
- **A group member with several devices** is one person.
- **Security:** the greeting between devices carries an address-proving signature, so nobody can impersonate a friend's second device.

### One invite code
- There is only one code: 25 characters (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`). The QR carries the same code (today in a link to the README), so it is smaller and easier to scan. The name comes with the invite. QR codes from older versions still work.

## 1.9.0

### AI assistant removed
- **The whole "Assistant" section is gone:** the on-device language model (with the llamadart package), the assistant chat, "Are you sure you want to send this?", scam warnings under messages, translations (chat, groups, comments, posts, "About me", the translate button), "Zenek is watching", daily summary, the tamagotchi pet and the Notebook (reminders and memory about friends). The model strained the device so much it could freeze the system.
- **Cleanup after the update:** at startup the app deletes assistant data and downloaded models (up to 2.6 GB).
- Messages and comments can still be copied: long-press or right-click → "Copy".

### Calls in a floating window
- **Android:** leaving the app during a call shrinks it into a picture-in-picture window: the other person's video, or name and time for audio, with "Hang up". Works in group calls too.
- **Desktop:** a "Mini window" button, and minimizing or closing the window during a call turns Zen into a small always-on-top window in the bottom-right corner (mute, back to full window, hang up; draggable).

### Background work without a status-bar icon (Android)
- The notification Android requires for the background service has a new channel "Zen — background" of **minimal importance**: no status-bar icon, collapsed at the bottom, hidden on the lock screen. The old channel is removed. On Android 13+ the notification can be swiped away.

### Call recording — finished (stage 3a)
- **Group calls:** a "Record" button; everyone gets a signal before the start and sees a red bar "● Ada is recording"; late joiners see it at once.
- **Windows:** recording the app's own audio (the other people's voices) mixed with the microphone, saved as WAV (`windows/runner/call_recorder.cpp`, WASAPI process loopback), so music, videos and other apps do not get in. Needs Windows 10 2004+; older versions refuse. Tested on a real computer. With speakers the microphone may pick up room sound; headphones are cleanest.
- **A recording is not lost when the call ends:** it is saved encrypted to "Call recordings" after hang-up too.
- The recordings list shows video or audio only; export uses the right extension (`.mp4` / `.wav`).

### Editing and deleting posts
- On your profile every post has **⋯ → Edit / Delete**.
- **Editing covers photos and videos:** remove, reorder text around them, add new. Recipients stay unchanged; the new version reaches friends as any entry ("edited").
- Deleting asks for confirmation; the post disappears from your profile and friends' feeds.

### Content available when the author is offline
- **Friends pass posts, photos and videos to each other:** whoever has a copy (signed; non-public encrypted as at the author) serves it. When the author is offline, posts and photos come from mutual friends. Tested with three devices.
- **A background phone serves too (Android):** the background service takes over the log, answers friends with posts and files and stores what arrives.
- **Photo and video downloads do not stop halfway:** after a restart the app asks for missing files from the author and all friends; a friend who just appeared is asked at once; chunks come from responders, not from someone offline.
- Every 10 minutes the app checks friends for news.
- Honestly: if nobody who has a copy is online, there is nobody to download from — Zen has no server. The more friends (and computers with Zen in the tray), the better.

### Post editor like Discord
- Formatting from the toolbar or shortcuts: **bold** (Ctrl+B), *italic* (Ctrl+I), underline (Ctrl+U), strikethrough (Ctrl+Shift+X), `code` (Ctrl+E), spoiler, headings, quotes, lists, code blocks; visible while typing.
- **Photos and videos anywhere in a post** (up to 10 per post; video up to 50 MB, from the camera on a phone).
- **Preview** before publishing.
- Posts show formatting, photos and videos where the author put them — for friends, followers and on the profile. Links copy on tap, spoilers reveal on tap.
- **Videos autoplay** (muted), one after another; a tap enables sound.

### Profile
- **Background photo** (3:1, cropped and shrunk on the device, no EXIF) — seen by friends and followers.
- **About me** with post-style formatting, up to 1000 characters.
- **Status** set on your profile: 19 ready statuses in three groups — "Can I write to you" (available, at work, back soon, do not disturb, rarely here, sleeping), "What I'm doing" (on the way, travelling, on holiday, studying, training, cooking, watching a film, gaming), "How I am" (resting, happy to chat, celebrating, ill, need a moment) — or custom.
- **Gallery:** separate profile photos and videos, **independent of posts**. "Add photo or video" with visibility, default **all friends**; **"Everyone (also followers)"** shows them to followers too. Long-press → change visibility (re-encrypts with new keys) or delete. New feed posts also default to friends, not public.
- Round profile pictures everywhere; an own avatar without a photo shows the first letter of the name.

### Look and cleanup
- **Invite** — a new left-panel item: your QR code, invite code, requests from people who just scanned it, and adding a friend by code. The "MY CODE" button left the messages screen.
- Settings without the profile card. The hidden-bar handle floats over content.
- Fixed descriptions ("on phones and computers"), missing Polish diacritics.
- Left panel: **Profile → Chats → Feed → Invite** (no Assistant).
- **The Feed no longer shows your own posts** — they are on your profile; after publishing "Published" with a "Show" button.
- **Uniform section headers.** Rounded "About me" field. Formatting toolbar wraps to a second row.
- A group invite always has its card with "Join / Decline", even if it arrived in the background; the device sends no presence signals to a group you have not joined.

### Fixes
- New Feed icon (newspaper). Fixed encoding of "§" in `call_recordings.dart`.

## 1.8.0

### New
- **On-device assistant (§29)** — a new "Assistant" tab:
  - a drawn pet, Zenek (breathes, blinks, jumps when stroked, sleeps at night); mood without streaks or guilt, renamable;
  - "Are you sure you want to send this?" before sending in chat, group and feed, with a gentler rewrite in one tap (sensitivity: off / insults / also shouting);
  - automatic replies by your own rules (optionally in set hours), marked 🤖, at most once per 3 h per person.
  For now a built-in rule model judges; a real language model comes in the next version.
- **Screen sharing in calls**, 1:1 and group (on Android also a single app, Android 14+), with a marker for the others.
- **Call recording** 1:1 (Android) informing the other side who records; recordings encrypted in the app (Settings → Call recordings).
