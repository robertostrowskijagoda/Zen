# Changelog

## Unreleased

## 1.12.1 — 24.10.2026
- Sending a GIF from the keyboard no longer crashes the app; GIFs show without a bubble or caption.
- Unlocking asks for the fingerprint or face at once when biometric unlock is on.

## 1.12.0 — 23.10.2026

### Installing and releasing
- **Install page** on GitHub Pages (`/install/`, English and Polish): recognises the visitor's system and shows only its steps: Android (APK, signing certificate fingerprint, one-tap Obtainium), iPhone (SideStore in 8 short steps with a one-tap "Add Zen source"), Windows, macOS and Linux.
- **SideStore / AltStore source** (`apps.json`), rebuilt from the latest published release by the Pages workflow (version, date, size, `Zen-unsigned.ipa`, permissions from `Info.plist`). The release run fails without the iPhone file.
- In the app: **Settings → Invite → Friend doesn't have Zen? → How to install Zen on another phone / computer**: a QR code to the install page and the steps per system.
- **`tool/release.dart`** (`check`, `prepare <version>`, `verify <folder>`): checks that the release workflow still produces every file the in-app updater expects, sets the version everywhere, moves these notes under the new version, commits and tags (it never pushes), and verifies downloaded release files against `SHA256SUMS` and its signature. CI runs `check` on every push; the release run fails when the tag differs from the version in the build.
- **Linux files run on Ubuntu 22.04, Debian 12, Mint 21 and newer** (glibc 2.35+): built on Ubuntu 22.04 with a check of every library, and the `.deb` is test-installed on Ubuntu 22.04–26.04 and Debian 12–13 in CI. The Flatpak moves to GNOME 51 and shows how to update instead of downloading.
- **Windows ZIPs carry the Visual C++ runtime**, checked file by file; the README explains Smart App Control and false antivirus alarms.
- **Safer release builds:** signing keys only in an approved, tag-only environment (the run stops if they leak into repository secrets); locked Dart packages, a pinned Go toolchain and `govulncheck`; pinned libwebrtc checksums; 16 KB page alignment of the Android libraries; reproducible Linux archives; the iPhone source is built from the release's own IPA and checksum.
- **Android: one APK per processor type** instead of one large universal APK: `Zen-arm64-v8a.apk` (most phones), `Zen-armeabi-v7a.apk` (older 32-bit phones) and `Zen-x86_64.apk` (Chromebooks, emulators). The self-update fetches the file for the phone's own type.
- **`CONTRIBUTING.md`** with a contributor licence grant and a pull request template.

### Documentation and GitHub
- **User guide** (`docs/guide`): one short page per area with diagrams and light and dark screenshots made from the app by `tool/ui_tour/docs_screens_test.dart`.
- **`docs/SECURITY_MODEL.md`** (threats, what is post-quantum, what stays classical and why, hardening, limits) and **`docs/DEPENDENCIES.md`** (what every library and platform API is for, and its licence).
- **README** rewritten: badges, a Post-quantum section, a feature list linking to the guide, platforms.
- **CI summaries:** format, analyzer, test counts, failed tests and Go tests on the run's summary page; the release run lists every file with its size and SHA-256.
- **Zen on Discord** (https://discord.gg/g4vHvpKV37), linked from the README and the GitHub issue page.

### License and legal texts
- **GPL-3.0-only** (`LICENSE`, the unmodified GNU text) with additional terms under GPL section 7 in `NOTICE` (author attribution in About, modified versions marked and renamed, no trademark rights; the donation link is not a licence condition; repository builds such as F-Droid may keep the name). `LICENSE` and `NOTICE` ship with the release files, the `.deb` and the Flatpak. `THIRD_PARTY_NOTICES.md` covers every component, including camera_windows, OpenH264, vo-aacenc, fonts, ZXing and KLIPY; the licences are also in the app (About → Licenses).
- **Consent at the first start:** terms, privacy policy and licence, each readable in the app; asked again when a document changes.
- **Terms of use:** a clear section at the top: Zen may be used only lawfully; using it to break the law is forbidden and is the user's sole responsibility.
- **No age gate:** the privacy policy and terms set no minimum age; only the pyramid asks for the birth year (below).

### Security and post-quantum
- **Hybrid ML-KEM-768 + X25519** for every signal between devices (no plaintext mode), offline mailbox mail, the locked phone's inbox, Bluetooth hellos, local link handshakes, neighbours' doors, dating boxes, food pickup and Table for six addresses, and private transfers.
- **Hybrid signatures (Ed25519 + ML-DSA-65)** on account and device records, posts, pyramid records, ballots, voting cards and releases. **Device identity** is post-quantum: device keys are pinned per address, and a key mismatch shows a warning in the chat.
- **Call recordings** of any length are encrypted into Zen's storage in pieces; the plain file is deleted only after that, "saved" appears only then, and a failed save offers *Retry*. Profile photos from another device or a backup go straight into encrypted storage.
- **Release checks:** a tag build stops at once while the app pins no release key or APK certificate, `SHA256SUMS.sig` must be signed by a pinned key and the APKs by the pinned certificate; commented-out pins do not count. The iOS and macOS WebRTC framework is checked against a pinned hash, and JitPack serves only the one library that needs it.
- **Windows:** Zen comes in its own `Zen` folder with a list of its files; an update replaces only that folder, never a folder Zen was merely unpacked into.
- **Lost or stolen devices:** once a device is cut off, friends stop sending it anything and their chat shows a warning; revocations are bounded and reach offline friends. A stranger can no longer probe whom you know through ledger hellos.
- **Linux video player** decodes only the formats Zen itself sends.
- **Calls:** frame encryption (AES-128-GCM, per-call hybrid keys rotated every 5 minutes and on every join or leave) inside DTLS-SRTP, and every packet sealed again in Zen's relay with a 256-bit ChaCha20-Poly1305 key of the two devices.
- **Cell votes** with one-time hybrid voting cards; only the card registration stays a ring signature. **Event tickets** are HMAC-based. **Dating lanterns** commit to a one-time hybrid key, and the match test is a sealed offer.
- **Yggdrasil:** no NodeInfo answers, no admin socket, only encrypted peer links (TLS 1.3 with X25519MLKEM768), strict peer address checks.
- **Memory and tampering:** secrets are wiped after use and link keys kept in locked memory; debuggers, Frida, hooking frameworks, injected libraries and re-signed copies are detected on every platform, and then transfers and the pyramid power key are blocked.
- Still classical: the Yggdrasil node key, the voting card registration, the pair secret of local links before devices first meet over the mesh, and the 128-bit AES key inside call frames (see `docs/SECURITY_MODEL.md`).
- **Private temporary media:** plain media files that must exist for a moment go to a folder only you can open (0700, files 0600, random names) in the app's own cache instead of a shared `/tmp`, and are cleared at start and exit.
- **Comments can no longer delete other files:** Zen remembers which author's entry brought each file, so deleting a comment removes only its own pictures, and storage limits touch only post and comment pictures.
- **Huge pictures are refused before decoding** (128 MiB of memory or 40 megapixels, read from the header), and big ones decode off the main thread.
- **Lock screen:** "I don't remember the password" (erasing this device) needs a **10-second hold**; failed password attempts are **throttled** (free for 5, then the wait doubles from 30 s up to 30 min, kept across restarts).
- **Official copy:** the app **checks itself** (Official copy / red warning at start and in About; "Cannot check" while no fingerprint is pinned) and can compare an installed or received file with the release's **`SHA256SUMS`** on demand; a short build code helps compare two phones.
- **Privacy defaults:** Nearby (Bluetooth) visibility is off until you turn it on, and the profile status line is visible to friends only.
- **Storage limits are enforced** for other people's media (friends 12 months, 2 GB per friend, 1 GB cache, oldest first; own data never), and a conversation can be auto-cleaned by age or size.

### Accounts and recovery
- **Several accounts on one device**, each a separate person (keys, mesh address, password, data, notifications). Accounts kept off the list open with their ID and password; decoy folders and hashed keystore names hide how many there are. Switching from the avatar menu; removing one account or all of them.
- **Receive in the background** per account (Android, and computers in the tray), with a battery and hiding warning; notifications of extra accounts are generic.
- **Copy with friends:** each person of the recovery circle keeps an encrypted copy (up to 10 MB) of the profile, friends, groups, levels, settings, pyramid, wallet, household, dating profile and, by default, the text of conversations. After recovery Zen fetches and restores it by itself.
- A recovered account gets its **pyramid place, wallet and power key** back.
- **Recovery circle you choose:** 4 to 6 friends (casual friends not suggested), a list of who holds the keys with confirmations and a printable list with their codes; a new phone shows a code and QR instead of an address, and helpers get a notification with **Help** already filled in.
- **First start:** a step for your name (friends no longer see "Me"), a key copy first and a reminder to set up the circle once you have 4 friends; optional permissions folded away.
- **Clear names:** *App password*, *Account password*, *Emergency wipe password*, the alarm's *Duress PIN*; *Key copy*, *Full account copy*, *Copy with friends*, *Add a second device or move the account*; *Delete this account from this device* warns when the account has no copy.
- **iPhone:** a reminder 2 days before the 7-day signature expires.

### Chats and delivery
- **Full chats, also in groups and pyramid cell chats:** photos, videos, files, voice notes and GIFs; **reactions, replies, editing (24 h), forwarding and delete for everyone**. Group files up to 64 KB travel in the message; larger ones, up to 24 MB, are sealed once and fetched from the sender or other members. A photo on the group **Board**.
- **GIF files** from the gallery or disk stay animated (metadata removed, up to 8 MB); Android keyboard GIFs arrive animated; a GIF that won't play can go as a file.
- **Drag and drop and paste** (Ctrl/⌘+V) of photos, GIFs, videos and files into chats, the post editor and the gallery on Windows, macOS and Linux; on iPhone, **Paste image from clipboard** for keyboard GIFs.
- **Outbox:** every reliable message is written to disk before the first attempt and retried on a battery-friendly schedule for up to 14 days, also after a restart; mailbox copies after 4 seconds; large payloads split across mailboxes; new posts and comments reach offline friends through their mailboxes. On a locked Android phone a sealed copy of the queue keeps sending.
- **Delivery icons** under every message (sending, waiting on your phone, waiting in the recipient's mailboxes, sent, delivered, read, failed) with details and **Retry**; groups show *Delivered d of n*.
- **GIF search switch** (Settings → Messages and calls → GIFs): off, Zen sends nothing to KLIPY and hides the GIF button.
- **Mailboxes prefer devices that stay online** (computers in the tray, Android) and replace ones silent for 3 days; the outbox is capped at 32 MB.
- **Honest iPhone delivery:** labels, a one-time card and *Why isn't it working?* say that an iPhone sends and receives only while Zen is open. **Copy invitation** copies a message with your link; the invitation code no longer vanishes from the clipboard.
- **GIFs always play:** event, food, flat, avatar and cover pictures keep a GIF animated (made smaller when needed, never flattened to one frame); on iPhone, **Paste image** in the text menu takes a keyboard GIF in chats, comments and posts.
- **Mini-profiles** (signed name and photo) travel with likes, comments and messages to people who are not friends; **messages to non-friends** are allowed in ordinary chats (text only, 3 messages until they answer; chosen in Settings).
- **Aggregated notifications** ("Cela and 3 others liked your post") are also system notifications, one per post, with the title hidden by "notifications without content".
- **Group board** is the group's own space of posts; **video plays while it downloads** (media sealed in independent 256 KB segments).
- **Call recording on every system:** iPhone, iPad and Mac (`.m4a`, the call and the microphone through flutter_webrtc's audio hooks) and Linux (`.wav`, only Zen's own sound and the microphone through PulseAudio / PipeWire) join Android and Windows.

### Feed and videos
- A new **Videos** section: a vertical full-screen player, recording and trimming, compression to about 720p and 20 MB on the device, an order worked out on the phone, block-by-block download from friends and mailboxes, views only for the author, videos from friends of friends (opt-in).
- **Cameras on computers:** Windows (camera_windows, Media Foundation compression and covers), macOS (own capture and export) and Linux (GStreamer, with OpenH264 and vo-aacenc built into Zen). QR codes can be scanned with a computer's camera too.
- Feed filters **All · Friends · Close friends · Pyramid · Country**, always shown.
- **Pictures in comments:** up to 4 photos or GIFs in a comment under posts, videos and pyramid posts, from the camera, gallery, files, GIF search, keyboard or drag and drop; they sync to your other devices like post photos. Your own comment can now be deleted, with its pictures.

### Pyramid and wallet
- **Birth year at entry:** the pyramid asks for the birth year (minors are admitted; age is never a condition) and shows the age in the member's pyramid profile, confirmed by the signature of the person who admitted them. Dating and the wallet never ask about age.
- **Your devices share the pyramid state** (entry data, own records and votes), so one member key never votes twice.
- **Private transfers:** orders go sealed to the treasurers only; a transfer counts when a majority of them sign it; signed statements, a dispute button and a court complaint for a wrong balance. A **daily transfer limit** (5 to 200, 30 by default).
- **Issuance limit as a hard rule:** lowering applies at once (hold to confirm), raising is announced and applies after 30 days unless cancelled; the same for the transfer limit.
- **Court and appeals:** verdicts visible on the person's profile; appeals one level above whoever decided, the time doubling per level.
- **Promotion one level at a time**, at most every 7 days. **Top immunity:** removing or banning a member of the top cell needs 2 of 3 of the top and a majority of level 2.
- **Posts to the whole pyramid** by the head, who can delegate them; the **Country** chip for everyone, with countries from the profile or the phone's region (several at once).
- National sections without a size threshold, ordered like the pyramid; referral joining, voting after 14 days or a confirmed acquaintance; advisory referenda; rule changes by the top (2 of 3) within hard limits; a group chat for every cell.
- **Places over time:** an animated history of the tree. The wallet has its own rail icon and opens from your profile too.

### Graph, introductions and gates
- **Gates with three prices** (close friends, friends, further away; each may be free) and an **Open for free** list; routes through any number of gates, the cheapest first.
- Graph **timeline**, **trust map**, **who's worth meeting**, **bridges and lonely islands**, **long ago**, private names for groups of friends, the answer path of *Ask the network*, a snapshot without personal data, **full screen**; **add friends of friends** without a code.

### Meeting people and Nearby
- **Nearby** visible by default; a cheap look around in the background every 5 minutes (adjustable in **Settings → App → Looking around in the background**, Android), also with Zen locked. **Nearby on computers** with Bluetooth LE (Windows and Linux broadcast and look; a Mac only looks). The Nearby icon shows only where it works.
- **Met?** from *Passed by* for up to 7 days; **New at the table** after a dinner.
- **Met in person** is signed by **both sides**: after a scanned or shown QR, Nearby or an event, each phone asks "Did we meet in person?" and only "Yes" signs.
- Dinner circles with invitations, *Leave circle*, *Who's coming* with diets, a chat per dinner, *Who owes whom*, *How was it?* and reminders even with Zen locked; **Cooking today, join me**; food sharing (eat in or take away; free, swap, points or money) with the pickup address sealed for the accepted person; **Table for six through a go-between**, who never sees the address; event guest lists without addresses for far circles.

### Neighbours
- A knock on the door waits up to 10 minutes for a resident to **accept** ("Let in" / "Refuse") before anything is answered; the door takes only knock frames and answers no Yggdrasil queries.
- A knock rings every household phone, also on a locked Android phone; *Leave* changes the household key; *What a knocker sees*.
- **Move the flat to this device:** when the phone that runs the flat is lost or replaced, another device of the account takes it over with a new door key; housemates and neighbours follow, the old door is refused from then on, and Zen offers a new sticker. Offered also right after cutting off a lost device.
- A **one-time housemate code** (10 minutes, confirmed on the phone that showed it), a **24-hour code** for inviting people nearby, messages signed with **your name in the flat**, and removing a housemate of a two-person flat only with their consent or after 7 days.

### Dating
- **Private lanterns:** a lantern carries only a one-off key (no age, name, gender or preferences) and goes 2 steps; a phone that sees one runs a sealed match test and asks for the profile only on a fit.
- Up to 3 steps and through open gates, *How far you want to see*, a distance nobody can fake, hiding *from them and their circle*, fixed-size answers, matchmaking, opinions only from people who know the person, free interests, meeting without romantic intent, filters, no extra password.

### Offline links and the locked phone
- Direct links over the **same Wi-Fi** (on by default), **Wi-Fi Direct** (Android, Windows), **Bluetooth** (all platforms) and **Apple Multipeer** (iPhone, Mac); strangers see only random-looking adverts.
- The Android background service runs the same code as the app and wakes on signals instead of polling. It works **without the master key**: a separate background key and small kits let it send the alarm, show you nearby, take knocks and send queued messages while Zen is locked.

### Look, navigation and settings
- **Portrait only** on phones and tablets; on computers the window stays a portrait column too (maximizing makes it a tall column, the floating call window is portrait as well).
- **27 themes in five groups** (Classic, Wild, Muted, Cool, Elegant), every one in a light and a dark version, each with its own shapes, borders, surfaces, buttons, backgrounds, transitions and motion; colours with fixed meanings; contrast checked everywhere. The default stays **Classic**; *Retro* is now *Player*.
- A **rail** with every section one tap away (no *More*); lock and rail toggle in the top bar; Invite and About at the top of Settings; a **Close friends** filter in chats.
- A new **About** with its own pages and **network census**: about how many people use Zen (an anonymous estimate) and the exact number in the pyramid.
- **Public peers editor** (add, remove, switch off, check, pin key, restore defaults); selectable text across the app; settings rows that wrap instead of cutting text.
- Media download over mobile data is on by default; the *Experimental features* screen and the unused notification delay setting are gone.
- **Nothing cut off:** every dialog and sheet scrolls above the keyboard, on small and split screens and with large text; tested in German, Russian and Arabic at 320 dp.
- **Right-to-left layouts** (Arabic): paddings, alignments, bubbles and badges follow the reading direction; graph labels too.
- **Zen on GitHub** in Settings and at the top of About.
- **Pyramid and Wallet for non-members** explain how to join through a friend who is a member and list friends who are.

### Updates and store build
- **GitHub release check and self-update:** at start and every 12 hours; the download is checked against `SHA256SUMS` (and Zen's signing certificate on Android), and against the maintainers' signature once their keys are pinned. Updates from friends over the network stay off until then, and the Updates screen says so.
- **The store build** (`appStoreOnly`, Google Play and Galaxy Store) is the same app with three forced differences: no self-update, no handing on of the APK (a link instead) and no launcher disguise. It also skips the check of its own signing certificate, since the store signs it.
- Tor `.onion` mirror links are no longer accepted.
- Built-in location (system service, no Google Play services) and Zen's own sounds.

### Battery
- **No permanent wake lock:** the Android background service wakes the phone only for short, timed moments (Nearby looks, mailbox polls, reminders, calls), and after 5 minutes in the background Zen only receives.
- **Fewer connections and pings:** a phone keeps 4 public peers instead of 16 (swapped when one fails); presence pings go only to friends, only while Zen is on screen, every 2.5 minutes.
- **Calmer screens:** status dots and neon effects pulse briefly on a change instead of all the time, animations run at a low frame rate and stop when hidden; videos pause off screen.
- **Computers on battery** stop bridging for others and keep 4 public peers; the battery estimate for looking around now counts the phone's wake-up time.
- **Shorter wake-ups:** an incoming signal keeps the phone awake for about 3 seconds (a message, knock or call until its work is done); mailbox polls and Nearby looks share one wake-up; a look is not scheduled while Bluetooth is off; each alarm releases its wake lock as soon as its work ends.
- **Lighter hellos:** a friend gets the device certificate once per run, later hellos only name it and are signed once; the 10-minute round greets only who was heard from lately (everyone once an hour); "I'm here" is not repeated within 2.5 minutes.
- **Only computers serve as always-on mailboxes** (a locked phone takes only its own mail); friends' bridges that are no longer chosen are disconnected (a phone keeps 1, a computer 5, a laptop on battery 1).
- **GIFs** play only while they can be seen (not in a hidden tab, under another page, in the background or in the tray) and are decoded at their on-screen size.

### Compatibility between versions
- **Data from a newer Zen is never overwritten:** every stored format has a version and is kept as is when it is newer; unknown fields survive a rewrite; a bar asks to update. Samples of all 1.12.0 formats are kept as tests.
- **Oldest supported version** (`minv` in hellos, `zen-min:` in a release) shows "update" instead of silently missing messages; moving an account between different versions says so; pyramid records of newer rules stop the pyramid with an update notice.
- **Ledger checkpoints** prepared, so logs can be shortened later without breaking 1.12.0; certificates and file lists are stored in smaller files.

## 1.11.0 — 20.10.2026

### Platforms
- **Android: three ABIs in one universal APK** — arm64-v8a, **armeabi-v7a** (older 32-bit phones) and **x86_64** (ChromeOS, emulators). The Go bridge is built per ABI and rebuilt only when it changed; native libraries are stored compressed so the APK stays about the same size. (x86 32-bit is not available: Flutter has no release engine for it.)
- **Android `appStoreOnly` flavor** (`flutter build appbundle --release --flavor appStoreOnly`; for Google Play and Galaxy Store, built manually; the files are named `Zen-APP-STORE-ONLY-do-not-install-manually.*` and are never installed by hand): no `REQUEST_INSTALL_PACKAGES`, no self-update (the screen says "Updates come from the store"), and "Pass it on" becomes a dialog with a link.
- **Windows ARM64** (`Zen-Windows-arm64.zip`, experimental): native build on `windows-11-arm`, Go bridge through llvm-mingw. The x64 build also runs on Windows 11 ARM under emulation.
- **Linux x64 and arm64: `.tar.gz` plus new `.deb`** (`Zen-Linux-x64.deb`, `Zen-Linux-arm64.deb`; Debian, Ubuntu, Mint). Audio and video playback through GStreamer (own `video_player` backend), a `.desktop` file (menu, `zen://` links, Wayland icon), AppStream metadata, `install-desktop-entry.sh` in the tarball, single-instance runner so a link from the browser reaches the running Zen. A Flatpak of the x64 bundle (`Zen-Linux-x64.flatpak`) is attached to the release.
- iOS (`Zen-unsigned.ipa`, iOS 15+), Windows x64 and universal macOS (12+, `Zen-macOS.zip`) unchanged.

### Translations
- **21 languages everywhere**, not only in the Dart UI: the invite page (`tool/pages`, language from the browser or `?lang=xx`, right-to-left for Arabic), iOS and macOS `Info.plist` strings (21 `<code>.lproj` folders), Android resources (`values-<lang>`; incoming-call screen, notifications, PiP, biometrics, installer, share), Linux `.desktop` comments. Everything outside the app UI now defaults to English.
- The new `docs/PRIVACY.md`, `docs/TERMS.md` and `docs/PROTOCOL.md` are in English; the About screen links to the privacy policy and the terms.

### Security
- **Network:** no more hard-coded 8.8.8.8 / 1.1.1.1 on Android — the bridge asks the system resolver (including Private DNS) first and falls back to a DNS-over-TLS list. The call UDP relay accepts a local socket only if its first datagram is an ICE check with the call's own username (desktop: listens on 127.0.0.1 only). The public bridge port goes through a Go limiter (4 connections per IPv4 or /64, 128 total, 1 MiB/s and 2 GiB per source per day, 32 GiB total). "Pass it on" serves on one chosen or best network and skips cellular, VPN and virtual interfaces. The "Answer" route is tied to one call number. Local-network discovery (see "Offline links" under Unreleased); at first only the account's own devices found each other.
- **Nearby:** a private per-phone key that never leaves the phone; friends get only a mask key, one-way hash-chain anchors and their own pair key, so nobody can forge another friend's presence. Alarm waves are signed with the pair key. The BLE token rotates every 10 minutes together with the MAC address. Greeting to a stranger carries no address — the reply goes over Bluetooth, and addresses are exchanged only between people who answered each other.
- **Releases:** the signed release manifest now covers the donation link, author and repository, plus mirrors; the app warns in red when its own values differ. New signed **canary** statement, 2-of-3 like a release; `tool/zen_release.dart` gets `maintainers`, `canary`, `sums` and `fingerprint`. Network updates stay off until maintainers are configured.
- **Pyramid rules:** a record that throws is rejected deterministically, quorum counted from active members, over-limit issuance by whole-pyramid referendum, content bans by entry id with the signed original attached. New record types `natpin` and `badge`.
- **Storage:** hidden file names for `meet/list/` and `ledger/` as well; Windows data lives in `%LOCALAPPDATA%` instead of Roaming; 20 MB limit warns from 50% and compresses harder from 75%; stale `*.tmp` files are cleaned up; clipboard copies expire after 60 s everywhere.
- **Mailbox attachments** are chunked and encrypted with a fresh key (ChaCha20-Poly1305); mailboxes see only ciphertext (see Features).
- **Profile images** (avatar, background) are moved into the encrypted media vault.
- **Forward compatibility:** unknown log spaces are kept for the owner (max 1000 entries per device log); golden protocol frames pinned in `test/wire/golden_frames_test.dart`.

### Privacy
- **Friendship levels have teeth:** a weak friend sees neither the friend list (they can ask via "Introduce me") nor statuses other than "Do not disturb"; the new default list audience is "Friends and close friends". Changing a level resends the list and status right away. People met in person are asked "How close are you?".
- **Group invites:** "Who can invite me to groups" (Anyone / All friends / Friends and close friends (default) / Close friends only); an invite below the threshold is rejected immediately.
- **Per-field profile visibility:** status, About me, photo, background, nationality, friend count, follower count — each Public / All friends / Friends and close / Close / Only me. Public fields go in the public entry, the rest in encrypted per-audience entries.
- Your device address goes into the public profile only when you have a public post or share.
- **Dating:** "I'm going on a date" can request your location on demand (the friend asks, your phone asks you or answers automatically if you agreed); "Report a minor" disables a profile locally at once and reports it to the pyramid, and a phone that receives reports from 2+ different reporters disables it too; re-confirmation with password or biometrics when entering Dating and after returning from the background.
- **Screen sharing:** system notifications are shown without content, a permanent red banner says the whole screen is visible, and Android older than 14 gets a warning first.
- Offline mailbox attachments use per-sender quotas and ciphertext only; recorded calls beep for all participants.
- "Media over Wi-Fi only" (default for new installs).

### Features
- **Calls:** a "Board" tab in groups (the group's own space of posts); an audible signal for everyone when recording starts. Camera and screen at the same time (a second video track) is built but not yet tested on devices.
- **Mailboxes and attachments:** photos, videos, files and longer voice notes for an offline friend wait at their mailboxes and arrive when they return, even if the sender is offline too. Per-sender limit 20 MB by default (Settings → Offline mailboxes → Attachments: off/5/10/20/50 MB), 200 MB total, 14-day expiry; live WebRTC stays the fast path.
- **Profile and feed:** per-field visibility, nationality (up to 3 country codes), mini-profile card, other-person profile with Add / Follow / Message and tabs Posts · Photos · Videos · Thanks · Info; signed follows with a followers list and blocking; "Liked by you, Bob and 1,284 others"; the author can hide comments and block people in their threads; paged reaction bundles (up to 2000 likes, 300 comments); grouped bell notifications; metadata stripped from MP4/MOV/M4A; a deleted post's tombstone reaches resharers.
- **Meetings:** the friend graph zooms (1–8x), groups into clusters and shows friends-of-friends labels; Alarm gets a fresh location from the background and a backup SMS to up to 5 numbers; dinner circles of 4–8 people, "vouching" for guests, shared pot; "Ask the network" answers are signed by the answering device; a "shared cause" plan with "I'll take it" claims.
- **Neighbours:** door code with exactly one door-inbox address, a link `https://…/Zen/m#<code>` and a web page `/m`; "Ask" about an invitation.
- **Pyramid:** pinned posts in the national section, age and gender badge, anonymous branch statistics (from 5 people), "Delivered / read" counts, price card in the profile, paid introduction (the broker is paid only after the introduced person agrees), escalation of reports level by level, 24 h / 7 d / 30 d breaks, only a friend of at least level "Friend" can be admitted.
- **Onboarding and recovery:** paper backup of the account key (56 characters in 14 groups, QR `zen-key:<code>`, with a check of two random groups) and restore from paper; a "Secure your account" card after the permission step and a reminder in Settings.
- **Permissions and diagnostics:** location, background location, exact alarms and vendor-specific battery instructions (Xiaomi, Samsung, Huawei, OnePlus, Oppo/Realme, Vivo); a "Welcome to Zen" card; **"Why is it not working?"** screen (network, background, notifications, battery, clock, free space, "Copy report"); clock-skew bar; six tabs plus "More"; accessibility labels.
- **Versions:** friends exchange app versions, and Settings shows a quiet "Friends have a newer Zen" bar; feature flags ("Experimental features": Pyramid, Wallet, Dating; all three are on by default and can be switched off, Neighbours is core); `v: 1` format versions for settings and profile.
- **Performance:** heavy encryption of data over 64 KB runs in a short-lived isolate (byte-identical output), the feed is recomputed only when the log changes and is built lazily.

## 1.10.0 — 14.10.2026

### Languages, Linux and macOS, security audit
- **21 languages:** Polish, English, German, French, Spanish, Italian, Portuguese, Dutch, Czech, Hungarian, Romanian, Turkish, Russian, Ukrainian, Arabic (right to left), Hindi, Indonesian, Vietnamese, Chinese, Japanese, Korean. Zen picks the system language (English if unknown); **Settings → Language** changes it instantly. Source strings are Polish in `t()` / `tn()`, translations in `assets/i18n/<code>.json`, checked by `dart run tool/i18n.dart` and `test/i18n_test.dart`.
- **Linux and macOS:** new release files `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz`, `Zen-macOS.zip` (Apple Silicon and Intel, macOS 12+), unsigned, built by GitHub Actions; `SHA256SUMS` covers all release files. macOS: Touch ID through the Secure Enclave, screen protection, no sandbox. Linux: key in GNOME Keyring / KWallet, tray through AppIndicator. No Bluetooth, call recording or camera on either; no voice-note or video playback on Linux.
- **Security audit fixes**: account recovery bound to the account, bridge memory limits, proof of device address, file warnings, mailboxes only for friends, corrupted data no longer removes friends, notification and screen privacy, GIFs on tap, pinned CI actions and APK key only for approved tags, `SECURITY.md`.
- **"Report":** reported content can be hidden locally, decisions can be appealed, the dialog no longer promises "Remove from my device".
- **Docs:** `docs/RELEASES.md` (channels, store requirements, Android developer verification, iPhone, costs); README with languages, Linux, macOS and an honest note about GIFs from klipy.com.

### Security, currency, iPhone
- **First launch:** after the password, a "Permissions and Bluetooth" screen (notifications, Bluetooth, full-screen alarm, background work, optional microphone and camera), also available in Settings. No more series of system dialogs.
- **Bluetooth:** steady, frugal advertising while visible (also from the background service), restored after Bluetooth toggles; scanning only on the "Nearby" screen (background scanning off by default).
- **Friends of friends:** friend lists in separate files with limits; frames from non-friends wait for approval; ping/pong carry digests and missing data is re-requested.
- **Graph:** search (diacritics-insensitive), filters, shortest path to a person, lines between friends who know each other, "Friend lists: from X of Y friends" with "Ask".
- **Consent as currency:** "Who sees my friend list" (all / on request / nobody), "Ask for an introduction" (a mutual friend passes it on, the other person decides), "Write a letter" through a mutual friend (max 3 per week per person), "Ask for an opinion". Within a pyramid a broker can price an introduction.
- **Pyramid:** no parties (party founding and primaries removed). Reports and appeals only from members, with limits; the treasurer signature cannot be replaced or removed; limits for proposals and market messages.
- **Currency:** hard limits (10^15 hundredths per amount, 2^60 per balance), saturating sums, re-confirmation (password or biometrics) before sending money, screenshot block in the wallet, all amounts in hundredths.
- **Signed Bluetooth alarm:** HMAC-SHA256 with the Nearby secret, valid ±10 min, replays rejected; only a verified friend alarm rings. Sent before state is saved.
- **Friends' attachments, voice notes and photos encrypted on disk** under random names; photos decrypted only in memory.
- **Stores only in the current envelope**, node configuration and verified-signature memory protected.
- **Panic password wipes everything:** stops the background service, then clears cache, temporary files, `Android/data/…/files`, Zen folders in Documents and Downloads, and saved copies.
- **APK signature:** "Pass it on" and ADB check the certificate before sending and installing.
- **Invitations:** a code, a link with the code after `#` and `zen://c/CODE` work.
- **Smoothness:** in-memory presence, delayed writes, screens watch only what they show.
- A friend's name always comes from their latest profile.
- **Dating like Tinder:** card stack, right "Yes", left "No"; "Match-make" and "Ask for an opinion" on the card.
- **Statuses redone:** highlighted "Your status" card with a countdown; friends' statuses grouped by kind.
- **Weekend plan:** a fourth form in Meetings — a loose plan with a reach, "Joining" / "Maybe"; once enough people join it becomes an event with a chat.
- **iPhone:** Zen runs on iOS (SideStore / AltStore, free Apple ID); `Zen-unsigned.ipa` built by GitHub Actions. Features iOS forbids (background work, background Bluetooth, button alarm) are marked unavailable.
- **Building:** the Go bridge builds itself on `flutter build apk` / `windows` (only when sources changed). GitHub Actions: tests on every push, release files on tag, invite page on Pages.
- **Licenses** of Go modules and fonts in "About → Licenses".
- **Invite page** `robertostrowskijagoda.github.io/Zen/#CODE` opens Zen or shows downloads; donations: **buycoffee.to/zen**; a few words from the author in "About".
- **Honest biometrics:** the first-password question says any fingerprint stored on the phone will unlock Zen; the default is "Password only". Windows: "Windows Hello unlock" with a warning in Settings.
- **Icons:** Feed as a newspaper, Wallet as a dollar sign; one pyramid drawing everywhere.
- **License:** a source-available license with the author's permissions (later replaced by GPL-3.0-only) — anyone, including companies, may use Zen for any purpose; it may not be sold or bundled into paid products; the author and donation link must stay; pull requests welcome, forks and modified versions forbidden.

### Names from profiles, safe media, recordings in posts
- **A friend's name comes from their profile** and cannot be changed (newer wins). Instead of "Rename" there is a **nickname** visible only to you, shown in small italics under the name and shared across your devices. Names from others are stripped of control and direction-changing characters and trimmed to 60.
- **Virus protection for photos and videos** (`media_guard.dart`): every incoming photo is decoded in pure Dart and re-encoded, so the system image decoder never sees the original (the class of WebP-2023 attacks); oversized "photos" are rejected before decoding. Videos and recordings must have a valid container (MP4/MOV/M4A/WebM/Ogg/MP3/WAV), otherwise they become a plain file Zen will not play. Type, MIME and file name come from the content. Files that could run a program (EXE, APK, scripts, shortcuts, macros) get a warning before "Save a copy"; Zen never opens files itself. Camera photos sent in chat lose GPS.
- **Voice notes and audio recordings in posts:** "Record a voice note" and "Insert a recording from file" (up to 25 MB); in chat, "Audio recording from file". Playback only on tap.
- **Zen codes straight into the app (Android):** with "Open supported links" enabled (Invite → "Zen codes straight into the app"), a code scanned with the ordinary camera opens in Zen. Flutter's built-in deep links disabled.
- **About → Your own Yggdrasil bridge:** how to run a permanent node without Zen.

### Convenience, security, release
- **Biometrics off by default;** asked once when setting the first password.
- **Default lock after 5 minutes in the background.** Lock-screen texts say the background service still receives messages.
- **Security fix:** attachment file names from others are sanitized — previously "Save a copy" could overwrite files in the app directory (path traversal).
- **Default theme: system.** Black logo in the light theme.
- **Left panel:** friend graph first; Wallet before Bluetooth; Bluetooth before Invite; new pyramid and feed icons; "Lock now" on the panel. Buttons shrink to fit (checked at 360×568: 13 tabs and lock).
- **Windows tray icon** rounded.
- **"Pass it on"** easier to find: Invite ("Friend has no Zen?") and About.
- **"About" rewritten:** donations first, then what Zen is (including the pyramid and grassroots politics), "Why", how to use, privacy with the recovery circle (up to 6 friends: password + 2 of them after 24 h, or 4 of them without a password after 7 days), platforms, Yggdrasil, why not in stores, how to check it is not a virus, official GitHub link, licenses.
- **Own status clearly marked** ("YOUR OWN STATUS", "Own" pill).
- **Desktop bridge** stays on by default, silently; the "Help others connect" switch is at the bottom of Settings (Advanced → Network and service).
- **One QR code for everyone:** an invite is a link with the code after `#`, so it never reaches the server; the Zen scanner adds the friend at once.
- **README for ordinary people:** download, what to do after scanning a code, installation (including the 2027 path for unverified developers with a 24 h wait), Windows SmartScreen, virus checking, why not in stores, privacy, Yggdrasil, donations, license summary, developer part.

### Statuses, nearby, alarm and reliability
- **More "right now" statuses:** Need help urgently (louder notification, separate red button), Can help, Going for a walk, Want to eat together, Want to play — and a **custom status** (own words and emoji). Compact pills instead of big tiles.
- **"People nearby" has its own button** in the left panel. Full Bluetooth scanning with the screen open; otherwise a short look-around every 5 minutes.
- **Alarm with confirmations:** the friend's phone replies "arrived" and "seen"; the alarm screen shows who got it, who saw it and who responded, with retry.
- **No whole-file rewrites:** conversations in segments of 200 messages, pyramid records in an append-only log.
- **Fewer freezes:** verified pyramid ring signatures cached on disk, first verification in the background.
- **Android no longer kills the service after 6 hours** (Android 14+: `specialUse` service type); if the system stops it anyway, a "Zen is not receiving in the background — open it for a moment" notification appears.
- **App sharing through Quick Share / Bluetooth** (new button in "Pass it on").
- **Same colors in light and dark themes;** the "ZEN" mark on the start screen.
- Someone in two pyramids sees the one they joined most recently.
- **Network identity survives a corrupted file:** node configuration written atomically with a backup (previously a corrupted file meant a new address and losing contact with friends).
- "Meetings" state from an unknown (newer) version is no longer overwritten with an empty one.

### The network carries itself: computers are bridges
- **Every computer is a bridge** (on by default). The PC app opens a router port itself (UPnP, else NAT-PMP), asks friends to verify from outside that it is reachable, and only then announces the bridge. Port and announcement are renewed every half hour, withdrawn when unreachable, closed on exit.
- A computer with a public address (no router, or IPv6) is a bridge too. The PC node listens on IPv4 and IPv6 (`tls://[::]:32913`), also on Linux and macOS.
- **Bridge status in Settings → Network and service:** working / router did not open the port / router refused (UPnP off) / no public address (CGNAT) / firewall blocks / waiting for a friend online, with "Check now" and hints. A manually forwarded port works too.
- **Bridge checks:** the app waits for the Yggdrasil handshake instead of a bare TCP connection; bridges must have a public IP (no names, no home networks), so nobody can send the app "knocking" on devices in your network. A friend checks at most 4 addresses per minute for others.
- **Bridge choice by speed and networks:** fastest working bridges spread across address blocks; rechecked every 6 h, dead ones get a second chance after a day and are dropped after three failures.

### Security audit
- A stranger can no longer become your friend with one packet (`friend_accept` without your invite goes to confirmations).
- A locked app no longer breaks friendships or loses invites: signals wait until state is loaded after unlocking.
- Two people who invite each other at the same moment become friends at once.
- Flood and "bomb" protection: zstd, signal fragments, photos and images, attachments, friend requests, group invites, events, dating bundles, offline mailboxes, alarms, questions.
- Pyramid: resilience to bad ring signatures, double votes, date rollback, veto and issuance-limit bypass, constitutional change without quorum; sync only with friends.
- Windows: data key sealed only when Windows Hello is enabled.
- Passwords: changing needs confirmation, password and panic password cannot match; panic destroys keys first.
- Device linking with a commitment; conversation file names do not reveal contacts; writes bound to the file key.
- A link can no longer answer a call or replace the caller's name; notification content hidden for dating and pyramid too.
- Android: no data backups, call screen unavailable to other apps. "Pass it on" shows the file's SHA-256.
- Test pilot only in debug builds; no logcat logs in release.

### Polished look
- Friend graph scrolls with its legend and no longer overlaps at small sizes; friends do not cover "You".
- "Meetings" tiles and "What do you feel like" statuses collapse to one column instead of breaking words.
- On desktop every screen keeps the same narrow layout.
- Amounts with thousands separators, pyramid levels from 1 and other small fixes.

### Reports, events, alarm and neighbours
- **"Report" everywhere:** posts, messages (also in groups) and profiles; reported content can be hidden at once; in the pyramid it goes to the reports delegate or the top.
- **Dating:** bundles encrypted with a separate key (ChaCha20-Poly1305), key given on request; vouches signed with a vouching key; several photos; "Dating" status 💘; "Thank the matchmaker"; "I'm going on a date" deadlines watched in the background.
- **Events:** shared album (photos from attendees, from 15 min before start), thank-you cards, organizer tips in pyramid currency.
- **Alarm:** audio recording for close friends and an optional Bluetooth wave to nearby phones.
- **Alarm shortcut: 5× power button** (Android, off by default): five quick presses (~4 s), also with the screen off and Zen closed, raise the ordinary alarm; only the PIN cancels it, the panic PIN works as always; vibration confirms. Warning about the system "Emergency SOS" that reacts to the same gesture.
- **Nearby alarm with the app closed:** with the option on, the Android background service shows nearby phones and receives alarm waves; each wave rings only once.
- **"Also look around in the background"** (off by default): every 5 minutes 10 s of frugal scanning, only to mark friends in range as "met in person".
- **Neighbours:** flat photo, removing a neighbour with a new key for the rest, revealing yourself to neighbours.
- **Event ticket pinned to the phone:** "I'll come" sends the organizer a key held only by that phone; at the door the phone shows a live code (refreshed every 20 s), accepted once within ±90 s.
- **Neighbours: a removed household member cannot forge a new flat key.** Each member phone has its own key known from the profile; removal votes and the new-key notice are signed by it; neighbours accept a new key only with the signature of a remaining member and a majority. Two competing new keys produce a warning, and scanning the new door code settles it.
- Fix: a shared event album disappears from disk with the event even if the app never loaded it.
- **Currency:** tip for an answer in "Ask the network", prices by friendship level, announcements through broker chains, moving a whole pyramid as a branch into a larger one.

### New look for the whole app
- **New palette:** deep dark (or light) base tinted with the accent and a gradient accent. **Color choice is back** (Settings → Appearance: 27 colors + light/dark/system); the default is "Zen" purple.
- **Readable typography:** sans-serif everywhere, sentences instead of ALL CAPS.
- **Every screen redone:** Inbox and chats (gradient bubbles, new composer), profile (cover, avatar in a gradient ring), Feed, Meetings, events, Table for Six, dinner circles, Ask the network, nearby, alarm, dating, neighbours, graph, pyramid, Invite, settings, lock screen, calls, start screen.
- **Own buttons in the left panel** for Dating, Neighbours, Friend graph and Alarm (red, at the bottom).
- Elements no longer overlap and fit narrow phones (checked with phone-size screenshots: `tool/ui_tour`).

### Smaller changes
- **Lock after leaving the app** is configurable: Settings → Security → "After leaving the app": 5 s, 30 s, 1 min, 5 min, 15 min, 1 h (default 5 min).
- Events: "Meal" instead of "Dinner / supper", "Friends of friends of friends" instead of "2 steps away"; explanation of Table for Six when creating an event.
- Neighbours: an "Add" button next to a flat that scanned your code replaces the toggle.
- Dating: the "Thanks" tab fits the screen.

### Pyramid, power, currency — new "Pyramid" tab
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

### Dating through friends — "Meetings → Dating"
- **Only up to 3 steps**, always with someone in common: "You know each other through: Bob → Kasia".
- **Nobody knows you are dating:** every phone weekly sends and forwards identical bundles — with a profile or an empty decoy.
- **Dating profile** built in one tap from the main profile, with preferences (gender, age, 1–3 steps) and hiding from chosen friends or whole groups.
- **"Yes / No":** a pair forms only on "Yes" + "Yes"; "No" sends nothing.
- **Pair chats, introductions and likes are encrypted** and travel through friends who do not even know whom they are from.
- **Ask for an opinion** from a mutual friend, **matchmaking**, **vouches** on the profile.
- **"I'm going on a date":** a friend sees where you are; if you do not confirm "All OK", they get a reminder, then an alarm.

### Neighbours — "Meetings → Neighbours"
- **Neighbour profile of a family / flat group:** "Novaks · flat 12", "About us", invitations (date, seats), "We offer", "We need". Neighbours do not see your accounts.
- **Household members** (no limit): another phone joins by scanning the member code. Anyone can edit the profile and reply; everything syncs.
- **Moving out:** the old door code stops working, neighbours are informed, new tenants start from scratch.
- **Door code:** printable A6 sticker (PNG) with its own password; "New code" invalidates the old one.
- **My neighbours:** scan a neighbour's door — both flats are on each other's list. Messages between flats, sign-ups with seat limits, muting, removing.
- **Nearby invitation:** send an invitation over Bluetooth to Zen users in range; they add you as neighbours with one tap.

### Meetings — new "Meetings" tab
- **Right now:** "Want to talk", "Want to go out", "Need help", "Do not disturb" — for an hour, until end of day or until cancelled, with a note, for all friends or only close ones.
- **Alarm:** hold for 3 seconds — close friends get it at once, full screen, with sound and your location (refreshed every minute); you see who is coming. Cancel with the ordinary PIN; a separate panic PIN cancels it on screen but friends are warned you may be coerced. A wrong PIN cancels nothing. "Call 112" button. Works with the app closed.
- **People nearby** (Android, Bluetooth): friends with names, strangers as a pseudonym rotating every 15 minutes, distance, "Write" to a stranger without revealing your account, "Invite as friend" with the "met in person" stamp.
- **Events through friends:** party, meal, meeting — for chosen people, friends, friends of friends or further. Guest list shows how many you know and who brought whom. Seat limit, "+1" with consent, QR tickets checked offline at the door, "We met" after the event.
- **Table for Six:** a dinner with people two steps away — Zen picks 5 guests who know each other the least.
- **Dinner circles:** cooking rota, swaps with consent, allergies, "who brings what".
- **Ask the network:** a question to friends (further only manually), answers come back with "friend of Bartek".
- **Friend graph:** you in the centre, close friends, friends and friends of friends, status colors, mutual friends. New setting "Show my friend list to friends".
- Android: new Bluetooth permissions (no location) and location (alarm only).

### Resilience: network updates and "Pass it on"
- **Updates from friends, without a store or server** (**off** for now): a new version travels as an ordinary file from friend to friend, waits **7 days** after first seen and **never installs itself** (Android opens the system installer; on a computer the installer lands in Downloads).
- **Settings → Updates and Pass it on:** version, state of a new version, "Load update from file" (`.zenupdate`).
- `tool/zen_release.dart` and `docs/RELEASES.md` describe the current (disabled) mechanism.
- **Pass it on:** the phone hands Zen to someone nearby without internet — own hotspot (Wi-Fi QR) plus a second QR with a download page. Also works on the same Wi-Fi. Only that one file is served, at a random address, for at most 20 minutes.
- **From a computer by USB:** "Install" with a connected phone (via `adb`), including a newer signed version.
- **HTTPS-looking traffic:** a computer bridge asks the router for external port 443 first.
- Android: new permissions — installing apps (updates) and Wi-Fi / nearby devices (hotspot).

### On-device data protection
- **App password required by default** (at least 8 characters); skipping is a conscious choice with a Settings switch.
- **Argon2id** for password and panic password.
- **Hardware-backed biometric unlock:** the key lives in Android Keystore (StrongBox if present) or a Windows TPM (DPAPI without), opened by fingerprint / face / Windows Hello. A new fingerprint invalidates the key — you type the password once.
- **Account key leaves memory** together with the data key when the app locks.
- **Re-confirmation** (biometrics or password) before Account and recovery, Devices and Call recordings; valid for a minute.
- **Screenshot and screen-recording block** in chats, groups, recordings, account and devices (Android and Windows); can be turned off.
- **Disappearing messages** in chat and group menus: 1 hour, 1 day or 7 days; the same setting reaches the other side and your other devices; messages vanish everywhere together with files and never enter durable account backups.
- **Panic password** also deletes the key in the security chip.
- **Rooted-phone warning** in Settings → Security (su, Magisk, LSPosed, Frida, test keys), without blocking.
- Android: the app now runs on `FlutterFragmentActivity` (needed for the system biometric prompt).

### Account on several devices
- **Settings → Devices:** list, "Link a new device", "This is the new device: join the account", "Unlink".
- **Safe linking:** the new device shows its code (QR or typed); both screens show the same 6 digits; only after confirmation the account key travels, encrypted with one-time keys.
- **Friends see one person:** messages and calls reach every device; answering a call on one silences the others; what you write on one device appears on the rest.
- **Friends and groups are the same everywhere:** stored in the account, encrypted so only your devices read them. Friends keep an encrypted copy, so a **recovered account comes back with friends and groups**.
- **Unlinking a lost or stolen device:** from then on nothing from it is accepted and it gets no messages; the device itself shows it was unlinked.
- **Chat history on a new device:** all conversations so far (files up to 25 MB each), encrypted for your devices only.
- **Sent photos, files and voice notes** (also in groups) appear on other devices, not just text.
- **Removing a friend, leaving a group, renaming and blocking** on one device happen on all.
- **A group member with several devices** is one person.
- **Security:** the greeting between devices carries an address-proving signature, so nobody can impersonate a friend's second device.

### One invite code
- There is only one code: 25 characters (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`). The QR carries the same code, so it is smaller and easier to scan. The name comes with the invite.

