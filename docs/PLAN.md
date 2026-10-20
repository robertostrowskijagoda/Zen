# Zen — App Plan

Version 13 · 15.10.2026 · chapters in implementation order. Status notes updated 20.10.2026 for 1.11.0.

Chapter numbers (§N.M) are fixed because the code refers to them. New
subsections get the next number at the end of a chapter. Project status,
known bugs, security and work order: `STATUS.md`. Releases and signing:
`RELEASES.md`. Tests: `TESTING.md`. Change history: `../CHANGELOG.md`.

Status for each area: **Done** (works), **Partial** (works, gaps listed),
**To do** (plan only), **Proposal** (awaiting decision). Work size: **S**
(days), **M** (weeks), **L** (a month or more).

> **Purpose.** A network of people who know each other: no feed from
> strangers, no ads, no algorithm, no central control. The only authority is
> a **pyramid** of people who know each other, and changes of leaders go
> bottom-up, cell by cell, to the top. Neighbors get to know each other
> again, dating goes through friends, politics is bottom-up (no parties:
> the people in the pyramid decide).

## Table of contents

**Part 0 — Principles and plan:** 1. Principles · 2. Roadmap (2.5 Before
the first public release)

**Part I — Foundation:** 3. Layer architecture · 4. Journal, spaces, write
policies · 5. Network: bridges, nodes, Yggdrasil updates · 6. Identity, keys,
credentials, recovery, anonymity · 7. Trusted circle, relays, storage

**Part II — Profile and content:** 8. Closeness levels · 9. Main profile ·
10. Feed · 11. Likes and comments · 12. Following · 13. Chats, groups and
calls

**Part III — Security and resilience:** 14. Security, data protection,
ban resistance (14.3 Integrity of official releases and fundraising)

**Part IV — Meetings and surroundings:** 15. People nearby · 16. Graph,
statuses, alarm · 17. Life after meeting (17.6 Weekend plan) · 18. Neighbors section

**Part V — Dating:** 19. Dating through friends (19.5 Browsing cards,
19.6 Reports and dating ban, 19.7 Scale of distribution)

**Part VI — Community:** 20. Pyramid · 21. Authority, delegations, bans,
reports, referendums · 22. Political and national section · 23. Currency ·
24. Access market (24.1 Contact economy)

**Part VII — The whole:** 25. App navigation (25.1 Languages, 25.2 Permissions
screen, 25.3 Appearance) · 26. Gaps and risks (26.3 iPhone, Mac, Linux) ·
27. Law · 28. Ideas for later · 29. AI assistant (removed)

---

# PART 0 — PRINCIPLES AND PLAN

## 1. Principles

1. **No server.** Nothing depends on a machine that no user runs.
   Exceptions: public Yggdrasil nodes as an emergency start (§5.1) and the
   invitation page on GitHub Pages that QR codes point to — the invitation
   code is after the `#`, so the page never receives it (§6.1, §14.2).
   **Status:** the GIF search breaks this rule (§13): queries and the IP
   address go to the commercial klipy.com, with a key embedded in the app
   (`STATUS.md` S29, S37).
2. **Everything is signed.** You check the signature, not the messenger.
3. **Friends first, then the source.** You fetch data from whoever gave it
   to you and from friends; you ask the author last.
4. **Only friends may push.** Exceptions, all with limits: signed authority
   entries (§21), messages and invitations from nearby (§15), paid messages
   (§24), reactions to your post delivered to your circle (§11), transfer
   orders to treasurers (§23).
5. **Local first.** A write lands on your device immediately; the network
   catches up in the background.
6. **Forward compatibility.** An older version stores and forwards what it
   does not understand. An unknown (newer) version of a record is read-only,
   never overwritten (today this is how the state of "Spotkania" (Meetings)
   works; the rest: §2.5).
   **Status:** unknown entries in a known space are stored. Since 1.11.0 a
   journal space `<kind>/<account>` of an unknown kind (short lowercase name)
   is also stored for its owner (limit 1000 entries per device journal) and
   shared only with the account's own devices, since we do not know its read
   rules; spaces without an owner are still rejected (`space_policy.dart`).
   The replicator still fetches only spaces it subscribes to, so relaying
   foreign spaces from friends does not work yet (needs subscriptions based
   on `caps`). Friends now exchange app version, build and a short list of
   capabilities in ping/pong (`peer_version.dart`; a declaration by the
   friend, irrelevant to security) (`STATUS.md` A17); frozen "golden" frame
   samples are in `test/wire/golden_frames_test.dart`.
7. **Transparent authority.** Every act of authority is a public, signed
   entry with a justification; changes of leaders go bottom-up to the top.
8. **Private by default.** Posts go by default to all friends (§10); they
   are public at the author's choice, because they are meant to spread. The
   rest (friend list, statuses, dating, neighbors, location) is restricted
   by default. **Status (1.11.0):** met for the friend list (new default
   audience "Friends and close friends"; a casual contact gets an empty list
   and may ask via "Przedstaw mnie" (Introduce Me)) and for statuses (a casual
   contact sees only "Do not disturb"). Still unmet: "W pobliżu"
   (Nearby) visibility, which is enabled at first start (`STATUS.md` §6
   item 3).

## 2. Roadmap

### 2.1 Ordering rules

1. First what everything else depends on: network, account, engine.
2. Then what attracts and retains people: profile, feed, meetings, dating.
   The pyramid and currency make sense only with thousands of people.
3. Every stage ends with a working version for phone and PC, with tests
   (including network simulation).
4. Shared building blocks are built once, in the first stage that needs them.

### 2.2 Shared building blocks

| Block | Stage | Used by |
|---|---|---|
| Engine: journal, files, replication, archive | 1 | everything |
| Engine connected to the app network (transport and relays) | 2 | everything |
| Account key + device certificates | 2 | everything signed |
| Bridges and the bridge book | 2 | the whole network |
| Recipient keys (closeness levels) | 3 | posts, profile, statuses, events, dating |
| Share tree + tree-computed totals | 3 | likes, comments, political posts, referendums, pyramid counts |
| Credentials (a signed sentence about someone) | 6 | pyramid, "verified", basic data, vouching |
| Bluetooth: advertising + address exchange | 6 | nearby, met in person, neighbors, alarm |
| Reach in hops (forward up to N hops) | 6 | events, Table for Six, Ask the Network, dating |
| Event (invitation, sign-ups, +1, QR ticket) | 6 | parties, dinner circles, Table for Six, neighbors |
| Multi-person signatures + authority space | 9 | cells, swaps, bans, issuance, treasurers |

### 2.3 Stages

| # | Stage | Content | Status |
|---|---|---|---|
| 1 | Engine | journal, files, certificates, write policies, replication, archive, network simulator | Done |
| 2 | Network and account | Yggdrasil v0.5.14, node pool, bridges on computers (§5.1), account key and device certificates (§6) | Done; the identity on the network is still the node key (§6.1) |
| 3 | Profile and feed | levels with keys (§8), profile in the journal (§9), posts, sharing, likes, comments (§10–11), following (§12), gratitude cards | Partial (§8–§12) |
| 3a | Calls+ | screen sharing, explicit recording, call in a window (§13.1–13.3) | Done with gaps (§13.1–13.2; recording: Android, Windows; camera + screen at once not tested on devices) |
| 4 | Account you cannot lose | password, recovery circle, multiple devices (§6.3, §6.5), data protection (§14.1) | Partial (§14.1); paper backup of the account key done |
| 5 | Resilience | Pass It On, installation via USB, HTTPS-like traffic, updates over the network (§14.2) | Partial: updates over the network disabled; §14.3 partly done (signed manifest, canary, tooling) |
| 6 | Meetings | Bluetooth (§15), graph, statuses, alarm (§16), events and the rest of §17 | Done with gaps |
| 6a | AI assistant | — | Removed in V1.9 (§29) |
| 7 | Neighbors | §18 | Done with gaps |
| 8 | Dating | §19 | Done; does not scale (§19.7) |
| 9 | Pyramid and authority | §20–22 | Done in code; use after an audit and with a community |
| 10 | Currency, access market | §23–24 | Done in code; audit and legal opinion before use |
| 11 | Fullness | tree-based referendums, Bluetooth wave (§21.3, §28) | Done in code |

Milestones: after stage 3 — the first version for people; after stage 6 —
the differentiator (meetups through people you already know); we launch the pyramid
when there is a community (e.g. over 1000 people marked "met in person").
Consciously postponed: iPhone (§26.3), transfer privacy, Tor, guest mode in
the browser.

### 2.4 What already exists

Platforms: **Android and Windows** (ready), **iPhone** (SideStore /
AltStore, no background work), **Linux and macOS** — code and CI builds,
unsigned releases, unverified until the first CI run (§26.3). Since 1.11.0
Android is built for arm64-v8a, armeabi-v7a and x86_64 in one universal APK,
plus a "store" flavor (no self-update); Windows ARM64 is experimental;
Linux gets a `.deb`, a `.desktop` entry and GStreamer playback.
Languages: 21, chosen automatically or in Settings (§25.1).

| Area | § | Status | Main gaps |
|---|---|---|---|
| Messenger: chats, groups, audio/video calls, relays | 13 | Partial | messages to strangers; attachments to offline friends now go through mailboxes (blobs), but GIFs go through klipy.com |
| Calls+: screen, recording, window | 13.1–13.3 | Done with gaps | camera and screen at once; recording on macOS/Linux (notifications are hidden while sharing the screen and recording plays a signal tone — done) |
| Network, bridges | 5 | Done | local network (multicast) on iPhone needs Apple's multicast entitlement |
| Account, devices, recovery | 6 | Partial | identity = node key; pyramid traffic through relays |
| Profile, feed, likes, following | 8–12 | Partial | level permissions; profile field visibility, nationality, mini-profile, metadata-free videos, follower list, "N verified" done; mini-profile on likes/comments |
| Data protection on the device | 14.1 | Partial | background service holds the master key |
| Resilience, distribution | 14.2 | Partial | updates over the network disabled; Tor, Wi-Fi Direct |
| Integrity of releases and fundraising | 14.3 | Partial | APK certificate check and signed manifest with fundraising link/author/repository, mirrors and canary exist; pinned fingerprint not yet published; APK key in CI secrets |
| People nearby (Bluetooth) | 15 | Partial | Android only |
| Graph | 16.1 | Done | — |
| Statuses | 16.2 | Done | — |
| Alarm | 16.3 | Done | SMS fallback opens the system SMS app |
| Events, circles, Table for Six, weekend plan, Ask the Network | 17 | Done | — |
| Neighbors | 18 | Done | the door node only while the app runs in the foreground |
| Dating | 19 | Done | scale (§19.7) |
| Pyramid, authority, politics | 20–22 | Done in code | address of the device visible in the pyramid |
| Currency, access market | 23–24 | Done in code | transfer privacy |
| Navigation, appearance, languages | 25 | Partial | accessibility (translations done, §25.1) |
| Law | 27 | Partial | privacy policy, terms and DPIA draft exist (English); legal review pending |

### 2.5 Before the first public release

1. **Feature flags (S).** "Core" release: chats, calls, profile, feed,
   meetings, neighbors, alarm. Pyramid, currency and market (consider
   dating too) behind an "experimental features" switch, until audit and
   legal opinion. **Mechanism done in 1.11.0** (`feature_flags.dart`; pyramid,
   wallet, dating, neighbors; Settings → "Funkcje eksperymentalne"
   (Experimental features); defaults from `--dart-define=ZEN_FEATURE_…`,
   `ZEN_FEATURES_LOCKED=true` blocks the choice); a disabled feature's
   services are not started (`ZenCore`, A15 step 0). Open: the defaults are all
   still **on** — the "core" release needs them off.
2. **Remove migrations and backward-compatibility code (S/M).** **Done in
   1.10.0** (config re-sealing of the node remains). Partly done in 1.11.0:
   `v: 1` on settings, profile and flags. To do: zeroing counters, enums by
   name, capabilities in the greeting (`STATUS.md` §7).
3. **One version numbering (S)** — **done:** 1.10.0 (10).
4. **Signing key, its backup, published fingerprint (S)** — `RELEASES.md`,
   §14.3. Tooling done (`tool/zen_release.dart fingerprint`); the key and
   publication remain.
5. **CI (S)** — **done:** GitHub Actions (`ci.yml`, `release.yml`,
   `ios.yml`, `pages.yml`).
6. **Default settings per §1.8, privacy policy (S)** — §27. No age gate
   (owner's decision); privacy policy, terms and DPIA drafts exist.

---

# PART I — FOUNDATION (stages 1–2)

## 3. Layer architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│ FEATURES: feed · chats · graph · nearby · neighbors · dating ·        │
│           pyramid · politics · currency · access market               │
├───────────────────────────────────────────────────────────────────────┤
│ SPACES with a write policy: account | group | pyramid cell |          │
│ authority | currency ledger                                           │
├───────────────────────────────────────────────────────────────────────┤
│ ENGINE: journal, blobs, certificates, replication, on-disk archive    │
├───────────────────────────────────────────────────────────────────────┤
│ TRANSPORT: Yggdrasil · relays/circle · Bluetooth                      │
└───────────────────────────────────────────────────────────────────────┘
```

Every new feature is a new kind of space with its own "who may write" rule
on the same engine, not a second system next to it.

**Status: Partial.** Besides the journal there are several separate
distribution mechanisms (relay mailboxes, pyramid sync, dating lanterns,
event and question chains, neighbors, a friend's state in "Spotkania"
(Meetings)), each with its own limits and bugs. Direction: new features on
journal spaces, one "friend state" mechanism (`STATUS.md`).

## 4. Journal, spaces, write policies

Engine (stage 1): signed entries in a chain, HLC (a clock resilient to bad
clocks, entries from the future rejected), fork detection, cutting off
devices, difference synchronization, archive.

| Space | Who writes | Who reads |
|---|---|---|
| `feed/<account>` | the account's devices | per entry visibility (§10) |
| `acts/<account>` | the account's devices | per visibility (likes, comments, follows) |
| `private/<account>` | the account's devices | only the account's devices (encrypted) |
| `profile/<account>` | the account's devices | per field visibility |
| `own/<account>` | the account's devices | never leaves the account's devices (§6.5) |
| `hood/<flat key>` | household members | neighbors (§18) |
| `date/<dating key>` | the dating key | up to 3 hops (§19) |
| `cell/<cell id>` | 2 of 3 members | the cell and the branch below |
| `power/<pyramid id>` | the top (2 of 3) + delegates | everyone in the pyramid |
| `treasury/<pyramid id>` | treasurers | treasurers + parties to the transfer |
| `event/<id>` | organizer (+ guests: sign-ups, +1) | guests and invitees within reach (§17) |

Bridge announcements (§5.1) are a separate small book with its own limits.

**Status: Partial.** The engine accepts `feed`, `acts`, `private`, `profile`,
`own` and (closed) a single `power` space (without `<pyramid id>`). `hood`,
`date`, `cell`, `treasury` and `event` — to do (L); these features today
run on their own files and mechanisms. Following is not yet entries in
`acts` (the `ledger/following` list exists only on the device), so an author
does not know who follows them (§12). `profile` is a single public entry,
without field visibility (§9). *(See §9 and §12 for the 1.11.0 status of
profile and following, which now use signed entries and per-field visibility.)*

## 5. Network: bridges, nodes, Yggdrasil update

### 5.1 A network that grows by itself (bridges)

**Goal:** public Yggdrasil nodes are only an emergency start; the network
carries itself through users' bridges.

1. **Every computer that can is a bridge** — on by default, with no prompt
   (decision of 10.2026). The switch "Help others connect" is at the bottom
   of the settings (Advanced → Network and service). Phones usually cannot
   be bridges (mobile networks block incoming connections).
2. **A bridge announcement has its own anonymous bridge key**: `{tls://IP:port,
   bridge key, valid until, proof of work, signature}`, with no account and
   no device address.
3. **Announcements spread by gossip**: when synchronizing with a friend, a
   sample is exchanged (freshest + random).
4. **Bridge book**: up to ~2000 bridges, rating (works, latency),
   connection to a few of the best from different networks.
5. **A new person** starts from public nodes and gets bridges from the
   first friend. The invitation code does not carry bridges (it must be short).
6. **Local network**: on the same Wi-Fi, devices are meant to connect by
   themselves (multicast). **Status: Done** — only the account's own
   devices find each other. Setting "Szukaj znajomych w tej samej sieci
   Wi-Fi" (Advanced → Network and service; on by default on computers, off
   on phones); the node config gets `ZenLanDiscovery` (`Enabled`, `Secret`,
   `OnWiFi`) at every node start, the secret is HKDF(`zen.lan.v1`) of the
   account's self key (itself derived from the account key), and the bridge
   derives an HMAC-SHA256 multicast password from it; phones only on Wi-Fi
   interfaces. Android holds a `WifiManager.MulticastLock` only while it is
   on (`runtime_lan_discovery.dart`, `ZenMulticastLock.kt`). Others on the
   network still see the beacon (the node key). iPhone: needs Apple's
   multicast entitlement, so it does not work there yet.

| Attack | Defense |
|---|---|
| A million fake bridges | proof of work (~a few seconds, valid 7 days), announcement limit per IP and /24 |
| Non-existent addresses | before forwarding, the app connects and waits for a Yggdrasil greeting; failures are not forwarded |
| DDoS amplification (someone else's IP) | the victim will not reply with a greeting; each app tests a few new bridges per minute, public IPs only |
| Flooding the exchange | only when synchronizing with a friend, a sample of ~50 entries |
| Surrounding (eclipse) | bridges from different address blocks, always public nodes too |
| Bridge overload | connection and transfer limit per bridge |

**Cost:** the IP address of every bridge computer is visible on the network.
Whoever collects announcements has a list of IPs of computers running Zen;
the internet provider will map an IP to a subscriber. Also, the bridge
listens with the node key, which is an address in Zen, so it reveals whose
computer it is (§26.1).

**Status: Done.** `BridgeHost` (`lib/src/features/ledger/bridge_host.dart`):
router port (`port_mapper.dart`: UPnP IGD, then NAT-PMP; external 443 first,
then 32913), candidates (the router's external address, the computer's
public addresses), verification by friends (`lg_reach` / `lg_reach_ok`),
announcement, renewal every 30 min, withdrawal when nobody can reach it. The
state is visible in the settings. Countries without a geolocation database:
spread over /16 and /24 blocks. The public node pool was refreshed (233
addresses from 30 countries; a computer connects to 20, a phone starts from
16 stable TLS ones). **Bridge overload limits (1.11.0, S38):** the public
port `tls://[::]:32913` goes through a Go intermediary (TLS is still
end-to-end, the node listens on loopback): up to 4 connections per IPv4 /
per /64, 128 in total, 1 MiB/s per source (burst 4 MiB), 2 GiB per source
and 32 GiB in total per day (`peer_guard.go`). **DNS on Android (S38):** no
more hard-coded 8.8.8.8/1.1.1.1; the Go bridge asks the system resolver
first (including Android "Private DNS") and, when it fails (paused for
30 s), a server list, by default DNS-over-TLS (Quad9, Cloudflare, Google,
port 853, certificate checked), changeable through the
`YggSetDnsServersJson` export (`dns_fallback.go`, `android_net.go`). **Call
UDP relay (S38):** on computers it listens only on 127.0.0.1 (phones: all
IPv4, because Android WebRTC binds sockets to the network); a local socket
is accepted only if its first datagram is an ICE check with this call's
username (random ufrag of both sides, known only from encrypted signaling),
so "first come, first served" no longer works (`relay_admission.go`,
`bridge_relay.go`); compatible with 1.10.0 bridges. A public node sees the IP and the permanent node key,
i.e. the invitation code (`STATUS.md` §6 item 8).

### 5.2 Updating Yggdrasil

- **Now:** yggdrasil-go v0.5.14 (from v0.5.12, September 2026) — the newest
  stable release; Go 1.26. Packet queues up to 1 MB, better routing, faster
  reconnection. Compatible with v0.5.x.
- **Building the bridge (done):** the Go bridge builds itself as part of
  `flutter build` / `flutter run` — Android (Gradle task `buildGoBridge`),
  Windows and Linux (CMake target), iPhone and macOS (Xcode phase) — only
  when the source checksum changed (`*.go`, `go.mod`, `go.sum`, script). No
  prebuilt libraries in the repository (`RELEASES.md` §3.1). Since 1.11.0
  the Android bridge is built for three ABIs (arm64-v8a, armeabi-v7a,
  x86_64), each with its own `.sha256` marker, and the `YggGetBuildInfoJson`
  export reports the Yggdrasil version, Go version, OS and architecture
  (shown under Network and service → technical info). The checksum also
  includes `go version`, so a new Go release rebuilds the bridge.
- **Permanently:** the public node list is refreshed with every release,
  a quarterly review of Yggdrasil and Go releases; the bridge book
  gradually replaces the list.

## 6. Identity, keys, credentials, recovery, anonymity

### 6.1 Keys

| Key | Where | Used for |
|---|---|---|
| **Account key** (Ed25519) | on devices, encrypted with the account password | new device, detaching, changing the circle |
| **Device key** (separate from the Yggdrasil key) | each device has its own | everyday signatures |
| **Flat key** | household members' phones | flat profile (§18) |
| **Pyramid identity key** | the account's devices | pseudonym in the pyramid, treasury account and transfer signature (§6.4, §23.2) |
| **One-time keys** | for a moment | nearby (§15) |

- A phone thief without the password will not take over the account; you
  detach a stolen phone from another device, and its later entries are
  rejected.
- **Invitation code:** 25 characters (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`): the
  full node address (120 bits) + a check character. The QR code is the link
  `https://robertostrowskijagoda.github.io/Zen/#CODE` (no hyphens, code after
  `#`) — a single-file page on GitHub Pages (`tool/pages/index.html`) that
  opens Zen with the code (Android: `intent://`, others: `zen://c/CODE`)
  and, without Zen, shows the download. Zen also accepts `zen://c/CODE` and
  a link to the project page `github.com/…/zen#CODE`. It cannot be shorter
  without a server. Since 1.11.0 the page is in English with the language
  chosen from `navigator.languages` (or `?lang=xx`), including RTL for Arabic.

**Status: Partial.**
- The identity on the network is still the Yggdrasil node key (address =
  key = invitation code, no rotation). Goal: the identity is the account
  key, node keys are replaceable and certified (L).
- The pyramid key is derived from the account key (HKDF, label
  `zen.pyramid.v1`), kept next to the device key: every device of the
  account is one person in the pyramid, and a recovered account gets its
  place and wallet back (**done 21.10.2026**, A7).
- Paper backup of the account key: **done in 1.11.0** (§6.3).

### 6.2 Credentials (general mechanism)

A signed sentence by one person about another: `{who, about whom, what, until when, signature}`.

| Credential | Issued by | Purpose |
|---|---|---|
| **Met in person** | both sides, when adding by QR or Bluetooth | the strongest signal against fake accounts |
| **Pyramid member** | the cell (2 of 3) | "a real human" (§20) |
| **Basic data** (birth year, nationality, gender) | the person admitting to the pyramid | valid as long as you are in the pyramid (§20.2a) |
| **Vouching** | a friend | "this is a real person"; false vouching is penalized (§21.5) |

**Status: Partial.** Pyramid member and basic data work as pyramid records.
There is no common credential type. **"Met in person" (21.10.2026)** is a
signed `met` entry in the attester's `acts` (`{a: other account, d: day}`),
which friends replicate: written after adding by a scanned QR, "Nearby"
and "We met" at an event (with the level question below), and for a
friend seen close by Bluetooth while the app runs (not from the background
service). Each side signs its own; the side that showed the QR signs only if
it also confirms in person, which is not asked yet. When the other account
is not known yet (friend request pending), the attestation waits up to 30
days and is signed on their first hello. It feeds "verified" (§11) and the
`met` pyramid records of §20.6. Since 1.11.0, after
adding by a scanned QR, "Nearby" and "We met" at an event, the app asks
"Jak blisko się znacie?" (How close do you know each other?: casual contact
/ friend / close friend; "Skip" = friend); the level is visible only to you.
Vouching with penalties (§21.5) — to do (M).

### 6.3 Account recovery

A circle of up to 6 people, each gets an encrypted piece of the key (Shamir,
Argon2id). Recovery: password + 2 from the circle after 24 h, with an alarm
on the old devices; without a password: 4 from the circle after 7 days.
After recovery the new device greets the friends who gave pieces; they hold
an encrypted copy of the friend and group list (§6.5), so the account comes
back with them.

**Status: Done.** In 1.11.0: **paper backup** of the account key
(`account/paper_backup.dart`: seed + 3 checksum bytes = 56 base32
characters, 14 groups of 4, QR `zen-key:<code>`) and an **encrypted key
file** (`account/key_file.dart`: `zen-klucz-<date>.zenkey`, versioned header,
Argon2id + AES-GCM, password typed twice); screen `KeyBackupScreen` "Kopia
zapasowa klucza" (asks again for the app password and the account password if
set, secure screen, warnings; option "Zapisz plik kopii" and option "Pokaż
klucz jako kod" with QR on demand and a check of 2 random groups) and
`KeyRestoreScreen` (file + password, or typing/scan; account fingerprint to
confirm, taking over the account on a new device), reachable from "Konto i odzyskiwanie"
(Account and recovery). After the permissions step a card "Zabezpiecz konto"
(Secure your account) offers: circle / paper copy / later (`AccountSecureStage`
in `AppSecurityGate`, remembered in `accountSecureOffered`), and Settings
reminds you until there is a circle (account password) or a copy
(`paperBackupDone`). Still missing: a "What you will recover" screen —
chat history (`own`), wallet and dating profile do not come back (S/M,
`STATUS.md` §6 item 16). Recovery pieces without a password are not bound to
the account (`STATUS.md` S19, fixed in 1.10.0).

### 6.4 Anonymity

**Principle: nobody has to give anything about themselves.** All profile
fields are optional, the name can be a pseudonym.

| Identity | Who knows the link to you |
|---|---|
| main profile | those you show it to |
| pyramid identity | only your cell (and the cell you lead) |
| flat profile | household members |
| dating profile | nobody until you reveal it |
| nearby (BT) | nobody (one-time keys) |

- The rest of the pyramid sees the pseudonym, level, branch size and
  nationality (§22.2). The treasury account (§23) belongs to the pyramid
  identity.
- Linking identities is voluntary (signature of both keys), e.g. to run in
  elections under your name.
- Network: the device address is seen by those you connect to. For anonymous
  roles, traffic is meant to go through relays from the circle.
- Anonymity does not protect against someone who takes over the phone
  (§14.1), nor against members of your own cell.

**Status: Partial.** The pyramid reveals the device address
(`pyramid_service.dart` → `pyramid_state.dart`), and pyramid traffic does
not go through relays — to do (M/L). A voluntary identity link (a record
signed by both keys) does not exist (S/M). A profile requires a non-empty
name (which may be a pseudonym).

### 6.5 One account on several devices (V1.10)

**Status: Done** (`account_link.dart`, `device_chat_sync.dart`,
Settings → Devices).

- **Linking:** the new device shows its ordinary code; both sides make
  one-time X25519 keys (with a commit–reveal commitment) and show the same
  6 digits. After confirmation the account key is sent encrypted; the
  account password is needed if one is set.
- **Recognizing devices:** each device writes its address in `acts` and in
  the greeting shows a certificate signed with the account key plus a
  signature of the device key under the address it came from (without this
  proof someone could impersonate a friend's second device).
- **One person for friends** (`AccountRoutingTransport`): a message goes to
  every device of the friend; one device takes the call, the others go
  quiet; sent messages and files reach your own other devices. The same for
  group members who are not friends.
- **Friends and groups** are stored in `private`, encrypted with a key known
  only to the account's devices; friends hold a copy they cannot read.
  Removals (`contact_removed`), name changes and blocks travel with the copy.
- **Chat history:** the `own` space goes only to the account's devices; a
  new device receives the whole history once (`chat_history`, files up to
  25 MB), imported by identifier without duplicates.
- **Detaching:** signed with the account key, with a cutoff point for each
  space; a detached device stops receiving messages and knows it.

## 7. Trusted circle, relays, storage

- **The circle is up to 6 trusted people**: a mailbox for messages, media
  storage, keepers of like counters, account-recovery guardians. Proposed
  by default from close friends (§8).
- **Limits (plan):** friends' entries 12 months, circle media 2 GB per
  person, cache 1 GB, shared permanently.
- **Media download:** Always / Wi-Fi only / Only on tap.

**Status: Partial.** Relays and the circle work; since 1.11.0 the circle,
recovery guardians and free offline-mailbox slots go first to "close
friends", then "friends", then casual contacts (mailboxes stay "sticky":
current ones are not swapped out). Media is held by all friends (§13.2a),
not only the circle; like counters are written by the author and sharers
(§11). "Only on tap" exists (Settings → "Pobieraj zdjęcia i filmy"
(Download photos and videos), `autoDownloadMedia`). **"Media over Wi-Fi
only"** (`AppSettings.mediaOnlyOnWifi`) is done in 1.11.0, on by default for
new installs (an old file without the field = off), with network detection
without a plugin (`UnmeteredNetwork`); Settings has the switch and a small
read-only "Storage limits" page (with a warning about full files).
**Mailboxes and attachments (1.11.0):** photos, videos, files and longer
voice notes for a friend who is offline wait encrypted at the friend's
mailboxes and arrive when they return, even if the sender is offline by
then (the live WebRTC path stays the fast route when both are online).
A **blob** is an attachment cut into chunks encrypted once with a fresh key
(ChaCha20-Poly1305, `RelayBlobCipher`), the key travels in a small
`blob_manifest`; mailboxes see only ciphertext. Reliable payloads over 48 KB
(inline up to ~2 MB JSON) and chunked transfers (over 1 MB, up to 24 MB)
use this path when WebRTC fails; the sender keeps up to 3 mailbox copies;
the recipient collects from whoever delivered the manifest, then from their
mailboxes, then from the sender; the state survives restarts. A mailbox
holds attachments only for friends who chose it and only from senders it
vouches for, with a per-sender limit per friend (default 20 MB; Settings →
Offline mailboxes → "Załączniki" (Attachments): off/5/10/20/50 MB), 200 MB
in total, and expiry after 14 days (an unreceived message then shows an
error, report `expired`). Compatibility: the `blob1` capability is announced
in `rly_announce`; 1.10.0 devices keep the old "only when both are online"
behavior. Storage limits also warn at 50% of the 20 MB file limit, switch to
stronger zstd compression at 75% and report `full` before refusing a write
(`ZenStorageHealth`). Messages that expire after 14 days no longer vanish
without a trace (`STATUS.md` B12, A18).

---

# PART II — PROFILE AND CONTENT (stage 3)

## 8. Closeness levels

| Level | Who they are | By default sees | By default may |
|---|---|---|---|
| **Casual contact** (Słaby znajomy) | barely known | public posts + "All friends" | write to you |
| **Friend** (Znajomy) | someone you know | + "Friends and close friends", your friend list | invite to groups, see status |
| **Close friend** (Przyjaciel) | a close person | + "Close friends only", full statuses, alarm location | be in the circle, receive the alarm, vouch |

- You assign the level yourself and it is private; each side has its own rating.
- A new contact starts as "Friend"; after meeting in person the app offers
  a choice of level.
- Each level has its own encryption key; lowering a level rotates the key.

**Status: Partial → mostly done in 1.11.0.** Levels, keys and rotation work
(level chosen on the friend's profile). Defaults from the table are now
enforced for most things: a new friend-list audience "Friends and close
friends" (`FriendListAudience.friends`) is the new default — a casual contact
gets an empty list and may ask via "Przedstaw mnie" (consent in the Inbox);
stored in the ledger by name (`la`), old `noList`/`listAsk` flags are still
written; a 1.10 ledger without the flag gets the new default (including for
those who once chose "All friends" — indistinguishable). A casual contact no
longer sees statuses other than "Do not disturb" (§16.2); changing a level on
a friend's profile immediately re-sends them the list and status (or "none").
A setting "Who can invite me to groups" (Settings → Privacy → Group
invitations: Anyone / All friends / Friends and close friends (default) /
Close friends only) immediately rejects an invitation to a NEW group from
below the threshold (`group_leave`; the inviter stops retrying); members of a
group you are already in add people as before, and strangers cannot invite by
default. Pyramid admission checks the level: a leader signs the admission
only of a friend at level "Friend" or higher (§20.2). After adding by a
scanned QR, in "Nearby" and "We met" at an event, the app asks "Jak blisko
się znacie?" (Skip = Friend). Still open: other level permissions are not
fully checked (`STATUS.md` §10).

## 9. Main profile (and the mini-profile derived from it)

- You edit the profile on your own profile ("Edit profile"), not in
  settings. Settings keep the technical part (password, devices, circle).
- You change the status by tapping under the name on the profile.
- Editing: avatar, background photo (3:1, no EXIF), name, bio with formatting.
- A **gallery** separate from posts: `gallery` entries encrypted for a chosen
  audience, deleted with a `gallery_del` entry.
- The **mini-profile** is built from the profile automatically: name,
  thumbnail, badges; signed, attached to likes, comments and messages to
  strangers.
- Look: banner, avatar, name, status, bio, buttons (Add / Follow / Message /
  Level), counts, tabs Posts · Photos · Videos · Thanks · Info.
- **Gratitude cards**: a signed "thank you" with a short description; no
  currency value, a few cards per month from one person.
- Every field has visibility: Public / All friends / Friends and close
  friends / Close friends / Only me.
- **Nationality**: an optional field (several allowed), opens the national
  section (§22.2); in the pyramid the confirmed nationality counts (§20.2a).
- The neighbor (§18) and dating (§19) profiles are separate.

**Status: Partial (largely done in 1.11.0).**
- **Per-field visibility** (`profile_fields.dart`): status, "About me", photo,
  background, nationality, friend count, follower count — Public / All
  friends / Friends and close friends / Close friends / Only me. Defaults as
  before (status, bio, photo, background public; new fields: nationality and
  friend count for friends, followers public). Public fields go in the
  `profile` entry, the rest in encrypted `profile_all` / `profile_mid` /
  `profile_close` entries (recipient key); old versions ignore the new entry
  kinds; `profile_update` to friends carries only what all friends see.
- **Nationality**: up to 3 country codes in "Edit profile", flag + code in
  the "Info" tab and in the mini-profile.
- **Mini-profile** (`presentation/mini_profile.dart`,
  `showMiniProfile(context, address)`): photo, name, status, badges (level,
  "You follow", "Follows you", nationality), counts, buttons Profile /
  Message (friend) or Add / Follow; `showPeerProfileSheet` (conversation
  header) now shows it. Not done: attaching it to likes/comments/messages to
  strangers (would change the `like`/`comment` format).
- **Another person's profile**: "Add" (invitation) / "Invited", "Follow",
  "Message" for a friend. Counts: Posts · Friends · Followers · Thanks (own
  "Followers" opens the list). Tabs: Posts · Photos · Videos · Thanks · Info.
- The friend list default is fixed (§8). The profile in the journal includes
  the device address only when the account has a public post or share (then
  strangers may want to follow); without it the `addr` field is omitted; the
  first public post adds it. Older profile versions with an address remain in
  the journal, and the address is also in device records in `acts` (needed for
  routing).
- **Own avatar and background are encrypted** (§14.1, `own_profile_images.dart`):
  saving the profile moves the photo and background to the media vault
  (`MediaVault`); old plain files are migrated at start.

## 10. Feed, posts, sharing

- Post visibility: Public / **All friends (default)** / Friends and close
  friends / Close friends only. Only public posts can be shared.
- A share carries the whole signed post to the sharer's friends.
- **Chronological feed, no algorithm, it ends** ("You're all caught up").
  You see a stranger's post only if someone you added shared it.
- Photos and videos without EXIF/GPS; a video up to 50 MB (decision from
  1.9) in 256 KB chunks, watchable while downloading; up to 10 photos per post.
- Deletion is a signed tombstone (for public posts only a request); editing
  creates versions marked "edited".

**Status: Partial.** Visibility (default "All friends"), sharing, the feed,
photos without EXIF, editing and tombstones work. Since 1.11.0 metadata is
stripped from MP4/MOV/M4A (`udta`, `meta` and XMP `uuid` boxes replaced with
`free`, same length, so `stco`/`co64` offsets stay valid; recording times in
`mvhd`/`tkhd`/`mdhd` zeroed; WebM/MKV unchanged), and the tombstone of a
deleted post reaches the sharer's friends (`reshare_del` with the author's
signed `post_del`). Missing: watching while downloading (a video is one
encrypted blob) (M).

## 11. Likes, comments, share tree

- A post spreads through the share tree: down go the photos, counter and
  deletions, up go likes and comments in packets.
- A like is a signed entry with a mini-profile. The full list is with the
  author and their circle; others receive a signed snapshot and pull the rest
  in pages.
- Your friends first: "Liked by Bob, Kasia and 1,284 others", next to
  "including 830 verified" (pyramid or "met in person" among your friends).
- The author hides comments and blocks people in their threads. Grouped
  notifications.

**Status: Partial (largely done in 1.11.0).** Likes and comments of friends
are signed entries in `acts`; further they travel in `rx` packets by the
author and sharers, and likes from outside the circle are unsigned ("via X").
Done: "Liked by: you, Bob and 1,284 others" (you and friends first, list with
"…and N others"); the author hides comments (`comment_hide`) and blocks
people in their threads (`thread_block`), the decisions travel in `rx`
packets (`hid`, `blk`) to further sharers; paging: page 0 as before (200
likes / 30 newest comments) + counters `nl`/`nc`/`np`, further pages in `rxp`
entries (up to 10 pages: 2000 likes, 300 comments), older versions read
page 0; grouped notifications in the bell on the Feed ("Cela and 3 others
liked your post…", only what is new since last opened; in-app only, not
system notifications). "N verified" (21.10.2026): next to "Liked by…" the
feed shows "w tym N zweryfikowanych" — likers met in person (a signed
attestation, §6.2) by you or one of your friends; pyramid membership is not
counted.

## 12. Following

- Anyone can follow anyone, without consent; they see only public content.
- Friends follow automatically; the list and count of followers on the profile.
- The author may block a person (their reactions disappear) but cannot
  forbid reading public content.

**Status: Done in 1.11.0** (`follows.dart`). Following is a signed `follow`
entry in `acts` (also between one's own devices). The followed person learns
from the greeting (`lg_hello` carries a field `fw` with the signed entry; old
versions ignore it), checks signature and address, and keeps a follower list
(expires after 60 days without a greeting). Old local follows get an entry at
first start. The list and count of followers (friends + others) exist.
Blocking a follower removes them from the list and their reactions from under
the posts (a `thread_block` entry); public posts they can still read. The
block does not use `store.blockAccount` (it would also reject, e.g., their
entries in groups).

## 13. Chats, groups and calls

- 1:1 chats, groups, audio and video calls (group calls too), relays.
- Messages to all the account's devices (§6.5), chats from nearby (§15).
- Voice notes and audio recordings from a file — in chat and in posts (§10).
- **A friend's name is the name from their profile** (it arrives with the
  invitation, the reply and every profile update; it cannot be changed). Your
  own label is a **nickname**: visible only on this account's devices, in
  small italics under the name.
- A group may have a **group board** (a space with posts) — for pyramid
  cells and ordinary groups.
- **GIFs** (added outside the plan): klipy.com search. The third party sees
  the typed term and the sender's IP address, and for a GIF downloaded by the
  recipient also their IP and time — an exception to §1.1. Direction: a GIF
  is downloaded only after a tap, eventually the sender sends the bytes as an
  ordinary attachment checked by `media_guard` (`STATUS.md` S29, S37).

**Status: Partial.** **Group board done in 1.11.0:** a "Tablica" (Board)
tab in the group screen; a post is an ordinary group message with an id
`grp-board-…` (a flag in the id — no protocol or on-disk format change;
older participants see it as an ordinary message; `sendGroupMessage(board:
true)`). Missing: messages to people who are not friends in ordinary chats
(§24.1) (M). Offline mailboxes now also carry attachments and large
messages (§7); an expired message shows an error instead of staying "sent"
(`STATUS.md` B12, A18).

### 13.1 Screen sharing (stage 3a)

- In every video call, group calls too: the whole screen or one app (on a
  computer a window; on Android 14+ the system "Share one app", on older
  versions the app warns that the whole screen will go out).
- A second video track in the existing WebRTC connection, no server.
- Everyone sees who is sharing; the sharer has a permanent "Stop" bar.
- While sharing, the app hides its own notifications with content and
  reminds you that everything is visible (SMS codes too).

**Status: Partial.** Sharing in 1:1 and group calls, choosing a screen or
window, the "Stop" bar and the notice to everyone work. **Done in 1.11.0:**
while sharing (1:1 and group) system notifications are shown without content
(`screenShareHidesNotifications` in `call_safety_cues.dart`, read by
`PrivacyRedactingNotificationService`), a permanent red bar "You are sharing
the whole screen — everything is visible, notifications too", and a warning
before starting on Android < 14 (`screen_share_guard.dart`). The screen goes
out on a second video track and the camera stays on: in 1:1 calls a second
video transceiver (the second `m=video`, carrying the screen stream's msid)
added on demand and renegotiated through the relay-pinned SDP; in group
calls every leg is negotiated with a camera slot and a screen slot from the
start, so sharing is a track swap. The other side shows the screen large and
the camera small. Not yet tested on devices.

### 13.2 Call recording (stage 3a)

- Every participant can record a 1:1 or group call (audio, and in video the
  picture too). **Recording is always explicit:** a signed signal to everyone
  (also to those joining later), a red bar "Ada is recording", a sound, a
  "Leave the call" button.
- A modified app or a dictaphone next to it will record without notice; the
  promise is that the ordinary app never records silently.
- The recording stays with the recorder, encrypted (§14.1); it leaves only
  through "Export". Law: §27.

**Status: Done.** Android: `MediaRecorder` from flutter_webrtc. Windows:
`windows/runner/call_recorder.cpp` — audio of the Zen process only (WASAPI
process loopback) with the microphone, WAV 48 kHz; from Windows 10 2004.
Group signal `gc_rec`. A recording cut by the end of the call is saved too.
**Sound done in 1.11.0:** two short beeps (WAV + SystemSound + haptics) for
the recorder and for the other participants on the `call_rec` / `gc_rec`
signal (1:1 and group). Missing: a separate "Leave the call" next to the bar
(there is the ordinary "Hang up"), recording on macOS and Linux.

### 13.2a Availability of content without the author (V1.9)

- Every friend holds a copy of the friends' spaces (`feed`, `acts`,
  `profile`) and their files, so an offline author's posts arrive from
  others. Entries are signed, non-public ones encrypted — an intermediary
  can neither forge nor read anything.
- Files: sources are the author and all friends; missing ones resume after
  restart (`_resumeMedia`), a newly seen friend is asked immediately
  (`offerSource`).
- Android: in the background the service starts a second `LedgerNode` copy
  on the same disk; the app suspends it (`suspend`) and catches up after
  returning (`LedgerArchive.catchUp`). Only one copy writes to disk.
- Every 10 min the node greets friends by itself. When nobody with a copy is
  online, there is nowhere to fetch from.

**Status: Done.** Cost: two environments on the same files (`STATUS.md`).

### 13.3 Calling over other apps (V1.9)

- **Android:** picture-in-picture (`setPipCall`; from Android 12 the system
  does it, on older ones `onUserLeaveHint`), no "draw over other apps"
  permission.
- **Computer:** a small always-on-top window (`CallCompactMode`), a "Mini
  window" button, on minimizing and on closing the window during a call.

**Status: Done.**

### 13.4 Background operation and notifications

- **Android:** without a server (and without Firebase) receiving requires a
  foreground service with a minimum-importance notification. Service type
  `specialUse` (Android 14+), because `dataSync` has a 6 h per day limit
  from Android 15; when the system stops it, the notification "Zen is not
  receiving in the background — open it for a moment" appears.
- **iOS:** the system does not allow continuous background operation;
  faking navigation or audio breaks App Store guidelines (2.5.4). The honest
  way: content-free push notifications (APNs) sent via offline mailboxes,
  calls through PushKit + CallKit — requires an Apple Developer account and
  an APNs key on the mailbox side (§26.3).

**Status (Android): Done.** Battery cost: `STATUS.md`. Since 1.11.0 the
permissions screen also covers location, background location (Android 10+),
exact alarms (Android 12+) and manufacturer-specific battery instructions
(Xiaomi, Samsung, Huawei, OnePlus, Oppo/Realme, Vivo + generic;
`vendor_battery_help.dart`), and a "Dlaczego nie działa?" (Why doesn't it
work?) screen (`HealthScreen`: network, node and neighbors, background
work, notifications, battery, clock, free space, with repair buttons and
"Copy report" without addresses) is reachable from Settings and from the
connection bar (`?` icon when disconnected); a clock-skew bar appears under
the connection bar when 2+ friends agree the clock is off by more than
2 min (`ClockSkewTracker`).

---

# PART III — SECURITY AND RESILIENCE (stages 4–5)

## 14. Security, data protection, ban resistance

| Who attacks | What they can do | What stops them |
|---|---|---|
| A stranger | read public content | nothing is pushed to you (principle 4) |
| Account farm | likes, spam, pushing into the pyramid | "verified", meeting in person, vouching, penalties §21.5 |
| A stalker nearby | track via Bluetooth | rotating identifiers, no name for strangers |
| A harasser | write | 1 message, paid mailbox, blocks, reports |
| A phone thief | write as the device | the password protects the account and wallet, detaching the device |
| A circle member | forge counters | like signatures, 6 copies |
| Colluding circle members | recover your account | password + 24 h / 4 people + 7 days, alarm |
| A corrupt leader | abuse power | swap in the cell (§20.3), transparency of acts |
| A corrupt top | print money, ban | public issuance, veto, referendums, bottom-up swaps |
| Colluding treasurers | double spending | majority of 15, public proof, swap |
| A fake pyramid | declare itself the authority | you recognize only your own (§20.5) |
| A modified client | ignore bans, not delete | we cannot force it; it cannot forge signatures or decrypt |
| A counterfeit copy of Zen | spy, swap the fundraising | APK signature, §14.3 |

Additionally: EXIF and GPS are removed, incoming images are decoded and
re-encoded; location only for the alarm and "Idę na randkę" (I'm going on a
date), only to close friends, with an expiry time; a stranger who knows the
account key can ask only for public content. **Status:** videos now lose
their metadata (§10), but GIFs from klipy.com bypass re-encoding (§13);
"verified" and vouching against farms — to do (§6.2, §21.5).

### 14.1 Data protection on the device (Pegasus and company)

Pegasus-class software takes over the whole phone; while the app is
unlocked, it reads the screen, memory and keyboard. Goal: **a locked app is
useless to a spy** (only ciphertext on disk), and an unlocked one reveals as
little and as briefly as possible. All data on disk is encrypted with the
master key (envelope encryption, AES-GCM with AAD). **Exceptions today:** the
diagnostic log (`STATUS.md` S34) and the file with the chosen language (the
own avatar and profile background were moved to the encrypted vault in
1.11.0, §9). File names in `meet/list/` and `ledger/` are now hidden
(HMAC with a storage subkey, `kZenHiddenNamePrefixes`). On Windows data
lives in `%LOCALAPPDATA%` instead of Roaming. Everything
copied to the clipboard (including pyramid codes and post links) is cleared
after 60 s through `copyWithExpiry`.

| # | Mechanism | Status |
|---|---|---|
| 1 | **Master key only in memory, only after unlocking**; erased on lock | Done. Default lock after 5 min in the background (earlier only after a phone restart); "Lock now" on the bar. Exception: the Android background service holds the key because it receives messages — eventually a service without the master key (M). The lock is applied only on return from the background, and the computer does not lock after idling (`STATUS.md` S26) |
| 2 | **Hardware-wrapped key** (Android Keystore/StrongBox with strong biometrics; Windows TPM + Windows Hello; macOS Secure Enclave with Touch ID) | Done. Biometrics off by default; one question when setting the first password. Windows Hello without hardware consent (STATUS.md). Linux: key in GNOME Keyring / KWallet, no biometrics |
| 3 | **Password required by default** (min. 8 characters) + Argon2id | Done. Skipping only consciously ("Allow using the app without a password") |
| 4 | **Re-confirmation** of sensitive places (60 s) | Done: account and recovery, devices, recordings, wallet (before every payment, 1.10.0), and since 1.11.0 dating: `DatingReconfirm` covers the screen and asks for the password/biometrics on entering Dating and on returning from the background (>= 10 s); inner screens (profile, chat, editor) lock only after returning from the background |
| 5 | **Media on disk encrypted**, no thumbnails in the system gallery | Done in 1.10.0: attachments, voice notes and friends' photos in the vault (`media_vault.dart`, random names); since 1.11.0 also the own avatar and background. Names in `meet/list/` and `ledger/log-` are now hidden (`STATUS.md` A20) |
| 6 | **Screenshot block** (Android `FLAG_SECURE`, Windows `WDA_EXCLUDEFROMCAPTURE`, macOS `sharingType = .none`) | Done on chats, groups, recordings, account, devices and in the wallet (on by default), and verified on the Dating tab, profile, chat and editor. The chat list — to do (S, `STATUS.md` S27); iPhone and Linux without protection |
| 7 | **Notifications without content** (default "New message") | Done, dating and pyramid too; titles of some notifications reveal context (`STATUS.md` S30) |
| 8 | **Incognito keyboard** in message fields | Done |
| 9 | **Clipboard cleared** after 60 s | Done in 1.11.0: all copies go through `copyWithExpiry` (pyramid code and post links added), a retry after returning to the app (Android does not allow it in the background), `clearCopiedNow()` |
| 10 | **Disappearing messages** (1 h / 1 day / 7 days) | Done; they do not reach durable account backups |
| 11 | **Panic password** erases the master key and the key in the security layer | Done in 1.10.0: first stops the background service, also erases the cache, temporary files, `Android/data/<package>/files`, Zen folders in Documents and Downloads, and saved copies |
| 12 | **Root detection** (su, Magisk, LSPosed, Frida, test keys) as a warning | Done |

App settings are stored as JSON with named fields (no more ten binary
format versions; an unreadable old file = default settings; `v: 1` since
1.11.0). Names of attachments from others are sanitized on receipt and on
saving (previously "Save a copy" allowed overwriting files in the app
directory). Orphaned `*.tmp` files older than 1 h are cleaned at start.

**Media from others (`media_guard.dart`).** A photo from anyone (chat,
posts, profiles, dating) is decoded in pure Dart and re-encoded (without
metadata), so the system image decoder never sees the original; an image
whose header announces more than 40 Mpx is rejected before decoding. A video
or recording must have a known container whose structure matches (MP4 boxes
fit in the file, the WebM header says "webm"); otherwise it stays an
ordinary file. Type, MIME and name are determined by the content, not the
sender; names lose text-direction characters. Zen does not open files, and
warns before saving an executable (by content or extension). Camera photos
sent in chat lose EXIF and GPS. Videos are still decoded by the system (on a
phone they cannot be re-encoded) — a residual risk.

Storage limits (1.11.0): a warning from 50% of the 20 MB limit (log +
`ZenStorageHealth.instance`: `warnings`, `worst`, `fillOfPrefix`), stronger
zstd compression (level 12, format unchanged) from 75%, an overrun reported
as `full` before a write is refused; Settings has a small read-only "Storage
limits" page.

What we do not promise: when a spy sits in an unlocked phone and watches the
screen, they see what you see.

### 14.2 Resistance to bans, censorship and political pressure

**Goal:** if someone by law, by pressure on Google or Apple, or on the author
tries to block the app, people can keep using it. There is no server, so the
weak points are distribution, the network and people.

| # | Threat | Defense |
|---|---|---|
| 1 | No store / removal from a store | Releases on GitHub (`RELEASES.md`) and **"Podaj dalej" (Pass It On)**: hotspot + QR, the same Wi-Fi network, Quick Share / Bluetooth, also without internet |
| 2 | **Android developer verification** (from 30.09.2026 for installs from stores in Brazil, Indonesia, Singapore, Thailand; in 2027 everywhere, also from a file) | Register `com.roj.zen` as a verified developer by the end of 2026 (`RELEASES.md` §4). Otherwise the "advanced path" remains (developer options, restart, 24 h wait) and ADB; Zen on PC has "Install on phone" over USB. Phones without Google services do not have this |
| 3 | iPhone | The weakest point (§26.3) |
| 4 | Updates without a store | Updates over the network from friend to friend; always human consent (approval: below) |
| 5 | Network blocking | direct connections between friends, HTTPS-like traffic (TLS on 443), bridges from friends without a central list; later Tor and a Bluetooth/Wi-Fi Direct mesh |
| 6 | Blocking of the download page | There is no own page — there is the repository README and the invitation page on GitHub Pages. Repository mirrors (e.g. Codeberg) and "Pass It On" work without them |
| 7 | Pressure on the author | Open code; the license lets anyone build from unchanged code and distribute copies with the same SHA-256; no kill switch (no server); a canary. **Weakness:** one signing key of one person and a ban on forks (`STATUS.md`) |
| 8 | Prosecution of users | Camouflage (another icon and name on Android; entry via PIN not done), panic password, pseudonyms, HTTPS-like traffic. The app makes detection harder, it gives no legal protection |
| 9 | Pressure on pyramid leaders | Pseudonyms, replacing the absent (§20.4), 8 of 15 treasurers |
| 10 | Labeling as "harmful" (Play Protect) | Open code, verifiable sums (§14.3); ADB always works |

**Status: Partial.**
- **"Pass It On"** (Done): the Android local hotspot or the same Wi-Fi + a QR
  code, the file is downloaded by an ordinary browser (one file, random
  address, 20 min); system sharing of the APK (Quick Share, Bluetooth)
  through `FileProvider`. Entry points: Invite ("Friend doesn't have Zen?"),
  About, Updates. The APK certificate is checked before sending (1.10.0);
  only a pinned fingerprint is missing (§14.3). Since 1.11.0 (S13) the
  server listens on one address: the network chosen by the person (a switch
  on the screen when there are several networks) or the best one (hotspot,
  then Wi-Fi, then cable), skipping mobile data (rmnet, ccmni…), VPNs,
  virtual machines and containers (`share_app_server.dart`,
  `share_app_screen.dart`). The "store" Android flavor (no self-update, no
  `REQUEST_INSTALL_PACKAGES`) replaces "Pass It On" with a window with a
  link to Zen in the store.
- **One QR code for everyone** (Done): a link to the invitation page
  `robertostrowskijagoda.github.io/Zen/#CODE` (§6.1) with the code after `#`.
  The page opens Zen, and without Zen shows the download; the Zen scanner
  adds the friend immediately.
- **PC → phone over USB** (Done): `adb` from the Android SDK (the app finds
  it, does not bundle it), with certificate checking. On
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE` it does not advise uninstalling, only
  warns about a counterfeit (1.10.0).
- **HTTPS-like traffic** (Done): bridges ask the router for port 443.
- **Updates over the network** (transfer done, disabled): files as journal
  blobs (substitution detected), 7 days from first seen, hold, always human
  consent. Approval by signatures of 2 of 3 maintainers is in the code, but
  the key list (`kReleaseMaintainers`) is empty. Since 1.11.0 the
  `tool/zen_release.dart maintainers [--write]` command fills it in; steps to
  enable: `RELEASES.md` §8.1. Friends also exchange app versions (§1.6); when
  friends have a newer version, Settings shows a quiet bar "Znajomi mają
  nowszą wersję Zen (X)" (Friends have a newer Zen version) leading to
  "Aktualizacje i Podaj dalej" (Updates and Pass It On). The version is the
  friend's declaration and affects nothing security-related; a signed
  release marker spreading by gossip is not done.
- **Canary and mirrors (done in 1.11.0):** a `zen_canary` statement
  (`{"m": {t, app, at, until, text}, "sigs": [...]}`), signed 2 of 3 like a
  release, is loaded from a file and passed from friend to friend (field
  `can` in `zen_rel`, ignored by 1.10.0); after `until` a warning "not
  renewed" appears (`RELEASES.md` §8.3). The signed release manifest lists
  repository mirrors (`mirrors`), shown in the app.
- **Camouflage (done, Android; not tested on a device):** Settings > Security
  > "Kamuflaż ikony" swaps the launcher icon and name for a neutral "Notatki"
  notepad. `MainActivity` has no LAUNCHER filter; two `activity-alias`es
  (`LauncherDefault` enabled, `LauncherDisguise` disabled) carry it and
  `ZenSystemBridge` `setDisguise` flips them so exactly one is enabled. It
  changes only the launcher look: the real name stays in system settings.
  Entry via PIN is not done.
- **To do:** Tor, Wi-Fi Direct, Bluetooth mesh (L), installation instructions with
  pictures (Android with the 2027 advanced path, Windows SmartScreen, macOS
  "Open anyway") (S), registering as a verified developer (S, organizational).
  Other store requirements (D12: foreground service declarations, 18+,
  names, terms, Data safety…) are not done.
- **Supply-chain weakness:** the APK key sits in GitHub Actions secrets —
  taking over the account, a token or an action gives a signed update that,
  with updates over the network, would spread from friend to friend.
  Direction: CI builds an unsigned, reproducible APK, the author signs
  offline (`STATUS.md` D11, S24).

#### Open decision: who approves new versions

An Android limitation: an installed app is updated only by a version signed
with the same APK key, and the new version takes over all data of the old
one. A key that nobody has means the end of updates; a public key lets
anyone forge an update that takes over the data — therefore **the idea of a
public key in the repository is dropped**. We also do not want maintainers
with separate keys (2 of 3).

**Proposal (for decision):**

1. A single APK signing key of the author, with a **copy split by Shamir
   among 3–5 trusted people** (never public) and rotation through APK
   Signature Scheme v3, should it need to be changed.
2. **An update over the network is accepted** when: the same signing
   certificate as the installed app + a higher `versionCode` + 7 days from
   first seen + human consent. This replaces the empty maintainer list.
3. Later: **vouching** by people who built the version from source
   (reproducible builds), and warnings from the network that hold the
   proposal.
4. Continuity: a license decision, should the author disappear
   (`STATUS.md`).

Windows has no signature protection like Android: Authenticode is needed
(§14.3).

### 14.3 Integrity of official releases and fundraising

**Status: Partial** (S–M). Problem: the license allows handing out copies,
and a modified copy can swap the fundraising link or spy. Zen is meant to
recognize an official release itself. Done: APK certificate checking in
"Pass It On" and ADB (item 3, without comparing the fingerprint between
phones), `SHA256SUMS` in every release (item 4); **in 1.11.0**: the signed
release manifest now covers the fundraising link, author and repository
(`official`) and the mirrors (`mirrors`) next to the APK/ZIP sums (Ed25519,
2 of 3 maintainers); the app remembers the newest signed data (also from a
release equal to its own, e.g. a loaded `release.json`), passes it to
friends, and in "Updates and Pass It On" shows a red warning "This may not
be the official Zen" when its own `kDonationUrl`/author/repository differ
from the signed ones (item 6 done); unknown manifest fields are preserved so
the signature of newer manifests still matches. Reading APK certificates
moved to pure Dart (`apk_signing_block.dart`), shared by the app and the
tool; the tool has `sums` (SHA256SUMS) and `fingerprint APK|--keystore
[--write]` (certificate fingerprint and entry into
`kOfficialApkCertificatesSha256`, S15). The rest — to do; the list of pinned
fingerprints is still empty until the maintainers run it.

1. **Pinned certificate fingerprint** (SHA-256) of the official signing key
   in the app (S).
2. **Self-check** at start and in "About": a matching signature — "Official
   copy" with a mark; a mismatch — the certificate fingerprint and a red
   warning (S).
3. **Everywhere Zen touches an APK file** ("Pass It On", sharing, ADB,
   updates): checking the signature and sum before sending or installing. On
   mismatch a red warning "Signature/checksum does not match — this is not
   the official Zen (the fundraising link may have been swapped)" with an
   "Install anyway" button. For an install from a friend, both phones compare
   the fingerprint. ADB does not advise uninstalling on a signature mismatch
   (S).
4. **Publishing** the certificate fingerprint and the `SHA256SUMS` file in
   the README and in the description of every release (S, `RELEASES.md`).
5. **On demand** comparison of the sum with `SHA256SUMS` downloaded from
   GitHub (only on tap, with no constant connection to a server) (S).
6. **Signed "fundraising manifest"**: the fundraising link signed with the
   author's key, checked before display (S). Done in 1.11.0 (see above).
7. Later: **mutual verification between phones** (Android key attestation:
   a friend's phone confirms the other side runs the official APK) (M).
8. **Windows:** Authenticode signing (e.g. SignPath for open projects or
   Azure Trusted Signing) and sums as above (S/M).

Honestly: a modified copy can cut out the self-check for itself; protection
comes from steps 3 and 7 — someone other than the suspect file always checks.

Release platforms (1.11.0): Android arm64-v8a, armeabi-v7a and x86_64 in one
universal `Zen.apk` (x86 32-bit: none, Flutter has no release engine);
Android "store" flavor (built manually, `flutter build appbundle --release
--flavor store`); iOS `Zen-unsigned.ipa` (iOS 15+); Windows x64
`Zen-Windows.zip` and experimental ARM64 `Zen-Windows-arm64.zip`; Linux x64
and arm64 as `.tar.gz` and `.deb` (GStreamer playback, `.desktop` entry,
AppStream; Flatpak not done); macOS universal `Zen-macOS.zip` (macOS 12+).
Everything outside the Dart UI (invitation page, `Info.plist`, Android
resources) is now English by default and translated into the app's 21
languages where the platform allows.
## 15. People nearby (Bluetooth)

- The phone broadcasts over BLE an **anonymous identifier that rotates about
  every 10 minutes** (derived from a secret that only friends receive).
- The "Nearby" list ("W pobliżu" screen): strangers appear without a name or
  photo, with a random pseudonym, a distance (close / in the room / farther)
  and badges. **Friends** recognise you through the shared secret and see your
  name.
- **Write** to a stranger: a greeting over Bluetooth, then the normal network,
  without revealing your account. One message from a stranger until you reply;
  blocking; at most 3 conversations from one address, 50 in total.
- Uses: "met in person", founding pyramid cells, neighbours (§18), alarm to
  people nearby (§16.3).

**Status: Partial** (Android, BLE with no extra libraries). Works:
broadcasting, the list, pseudonyms, "Write", "Invite as friend" with the "met
in person" stamp, blocking, automatic "met in person" for friends in range,
a new secret after a friend is removed. Visibility (broadcasting,
`ADVERTISE_MODE_LOW_POWER`) is switched on by the permissions screen at first
launch and stays on, including in the background service, and resumes by
itself when Bluetooth is turned back on; scanning happens only while the
"Nearby" screen is open ("background look-around" is off by default). The
alarm wave is signed (§16.3). Button on the bar.

Done on 20.10.2026 (for 1.11.0):
- **Separate keys per friend (S6).** Each phone has a private "Nearby" key
  (`MeetBook.nearbyPrivate`, `np`) that never leaves the phone. A friend
  receives (`nearby_key`, new field `z`) only: the mask key (shared, lets them
  recognise you), the anchors of a one-way hash chain (30 days, current and
  next) and their own pair key. The BLE token is the chain value for the
  current window, masked; a friend verifies it by hashing up to the anchor but
  cannot compute a token for a future window, so cannot impersonate another
  friend's presence. A 4-byte hint (quick filter) is appended to the token.
- **Alarm wave v6:** signed with the pair key (only that friend can verify
  it, no other can forge it). `NearbyService.waveAll` signs separately for each
  recognised friend; `MeetService.alarmWave(alarm, to:)`. The fast check in
  Kotlin (S31) handles pair keys (`p:…`) and version 6.
- **Rotation aligned with the MAC address:** the token changes every 10 min
  (shorter than Android's 15-minute address rotation); a new token restarts
  advertising, and with it the address, so the address never changes in the
  middle of a token.
- **Greeting without an address (S5)** (v7): pseudonym, message, token and a
  one-time X25519 key. The reply travels over Bluetooth (v8), with the address
  encrypted for that one phone; only then does the author write over the
  network (with proof of knowing the key), so addresses are learned only by
  people who replied to each other. Phones that show a token without a hint
  are not listed.
- **Persistent blocks** (`MeetBook.nearbyBlocked`, `nb`), with "Unblock" on the
  screen.
- **"1 message from a stranger until you reply"** is now enforced on the
  recipient side: further network messages and greetings from the same
  address/phone are rejected until a reply.
- **Badges on strangers:** distance, "wrote to you", "waiting for a reply",
  "you are talking", "older Zen version".

Remaining gaps and plan:
- Windows, iPhone, Linux and macOS: no Bluetooth (M). Android 10–11:
  background scanning requires the background-location permission.
  Greetings from strangers arrive only while the app is running. Founding cells
  over Bluetooth (§20).

## 16. Graph, statuses, alarm

### 16.1 Graph

An interactive map of your network: you in the centre, rings of friends,
acquaintances and weak acquaintances, further out smaller dots for friends of
friends (from lists someone shared with you, §9); status colours (§16.2), line
thickness = level. Tapping a person: profile, mutual friends, actions. Graph
data is ordinary entries (friend lists with visibility), with no central
index.

**Status: Done** (1.10.0; zoom and clusters 20.10.2026). Rings, status colours,
mutual friends, lines between friends who know each other; search (also
without Polish diacritics), filters (friends, friends of friends, pyramid,
status, nearby — only those for whom data exists), the shortest path "how I
know X", "Ask for an introduction", "Write a letter", "Ask for an opinion"
(§24.1), the diagnostic "Friend lists: from X, Y friends" with a request for
the list; the graph is first on the bar. Friends-of-friends lists arrive
reliably: frames from not-yet-friends wait, the list digest travels in
ping/pong, and a missing list is requested again. Added on 20.10.2026: zoom by
pinch/drag (InteractiveViewer 1–8x, +/- buttons), clusters (label propagation
over "know each other"; angular sectors + soft outlines), friends-of-friends
labels at zoom >= 2x; the person card has "View profile"
(`ProfileScreen.open`). The page does not scroll while the view is zoomed
(zoom out to return).

Friend lists travel as "Meetings" (Spotkania) frames, not as log entries
(deliberate, `STATUS.md` A4).

### 16.2 Statuses

| Status | Meaning | Visible by default to |
|---|---|---|
| I urgently need help | today, now; louder notification, no location (this is not the alarm) | friends and close friends |
| I need help | moving, advice, shopping | friends and close friends |
| I can help | I have time, a car, tools | friends and close friends |
| I want to chat | I'm free, write to me | friends and close friends |
| I want to go out | who's up for a beer | friends and close friends |
| Going for a walk | join me | friends and close friends |
| I want to eat together | lunch, pizza | friends and close friends |
| I want to play | board games, football | friends and close friends |
| Dating | open to dates (§19) | per dating settings |
| Do not disturb | — | all friends |
| Custom status | own words (up to 40 characters) and one of 12 emoji | friends and close friends |
| **ALARM** | I urgently need help | close friends + people nearby (§16.3) |

A status has an expiry (1 h / until end of day / until cancelled), a note and a
"close friends only" option.

**Status: Done** (reworked in 1.10.0). "Your status" is a highlighted card at
the top with a time-to-expiry bar, "Change" and "Turn off"; friends' statuses
are grouped by kind, with avatar, emoji, text and time remaining. Done on 20.10.2026: the "friends and close friends" threshold — a weak
friend no longer sees statuses other than "Do not disturb"; "close friends
only" is unchanged. Changing a level on a friend's profile immediately resends
them the list and status (or "none").

**Redesign proposal (M):** a single question "What do you feel like?" with
three groups (Help · Meet up · Do not disturb) instead of a long list; a status
with place and time ("Walk — park, 18:00") and a "Joining" button for friends;
friends' active statuses at the top of chats and on the graph; automatic expiry
shown by a time bar.

### 16.3 Alarm

- A large button (hold for 3 s) or a shortcut: 5× the power button.
- Goes immediately to **close friends** (with no close friends: to all
  friends), overrides "do not disturb" and rings like a call, full screen.
- Contains the **location** (refreshed every minute) and optionally an audio
  recording. Optionally a Bluetooth wave to people nearby (anonymous: "someone
  nearby needs help").
- Recipients see who is responding ("On my way / Calling / Can't"). The sender
  sees for each recipient: sent → delivered → seen → reply.
- "I'm safe" requires a PIN. The **panic PIN** dismisses the alarm on screen
  while silently sending "may be under duress". A mistake changes nothing.
- A few false alarms are a matter between people. The alarm does not replace
  112 — there is a "Call 112" button.

**Status: Partial.** Done: button, alarm channel, location, replies, two PINs,
112, background operation (Android service); audio recording (optional, 20 s
chunks, up to 6); alarm to people nearby (optional; the wave carries the
rotating "Nearby" identifier, friends see who, strangers see "someone nearby";
reception also with the app closed; each wave rings once); 5× power shortcut
(optional, requires PINs, vibration long–short–long); **acknowledgements**
`alarm_ack` ("got" immediately, "seen" on opening), accepted only from those
the alarm was sent to; after ~60 s "Not delivered to: …" with "Send again" and
advice to phone them. The Bluetooth wave is signed (v6, HMAC-SHA256 with a
per-friend pair key (§15), ±10 min, no replays): only a verified friend's alarm rings, strangers
produce a quiet "Unverified…" note. The alarm goes out before the "Meetings"
state is saved (B10, 1.10.0). Added on 20.10.2026: a **fresh location for the
background shortcut** (`currentFixInBackground`, no consent prompt, read under
the `location` foreground service of the geolocator; fallback: last known;
manifest: FOREGROUND_SERVICE_LOCATION and service type `location`, declaration
only), and a **fallback SMS**: up to 5 numbers (kept only on this phone), the
"Send SMS with alarm" button opens the system SMS app (no SEND_SMS permission;
Kotlin `ZenSystemBridge` method `sms`).

Gaps:
- The global wave limit can be exhausted by jamming the real alarm
  (`STATUS.md` S31).
- After a phone restart with a passcode, the shortcut and wave reception work
  after the first Zen unlock. The same gesture triggers the system SOS on many
  phones.

## 17. Life through friends

Real-life gatherings of people connected through someone they trust. One
mechanism (**the friend-based event**) handles everything below.

**Status: Done** (events, +1, tickets, album, circles, Table for Six, Ask the
network, Weekend Plan, Shared Cause). Details and gaps below.

### 17.1 Friend-based event (the common mechanism)

- **Reach:** close friends / friends / friends of friends / 2 steps / chosen
  people. The invitation passes on by itself, with a "who brought whom" chain.
- The guest list shows whom you know ("14 people coming, you know 5").
- **Ticket**: a signed invitation checked by QR at the door, offline, once.
  **Pinned to the phone**: "I'll be there" sends the organiser the (Ed25519)
  key of that phone only, and at the door the phone shows a live code (a
  signature with the current time, refreshed every 20 s; the scanner accepts
  ±90 s and only once). A screenshot stops working after ~1.5 min.
- **After the event:** a shared album for participants only (photos without
  EXIF/GPS, disappears with the event after a month), "We met" (an invitation
  + stamp), thank-you cards and a tip for the host (in the pyramid currency,
  when both people are in the same pyramid).

Gaps: pinning does not protect against handing over the phone or showing the
code live over video; a guest's clock may be off by at most ~1 minute. An
invitation is accepted only from a friend (someone who does not know the
organiser gets it through a vouching friend). Recipient safeguards: 30
invitations per day from one friend; photos over 4096 px / 16 Mpx are dropped.

### 17.2 Friend-based parties and "+1 with consent"

- "I want to bring Ola" — the organiser accepts or declines; for trusted
  people they can grant "+N without asking".
- A party "open through friends": a seat limit and a reach, visible only
  within that reach.
- **The person bringing a guest vouches** for them (the organiser's event
  history, no ratings) — done 20.10.2026: `bringGuest` requires a vouch, saved
  as `v` on the guest. Old data without the new fields keeps working.

### 17.3 Dinner circle (rotating shared dinners)

- A circle of 4–8 people or couples; a queue of hosts, "Swap" by consent,
  preferences and allergies, "who brings what".
- **Open circle:** once a month everyone may bring one person from outside the
  circle.
- Dinner at a stranger's home through friends (a few places for friends of
  friends).
- **Shared ingredients fund** — done 20.10.2026 as a local list of
  contributions in the circle (distributed along with the circle; only your own
  entries can be withdrawn).

Status: rotation, "Swap", preferences and items work. Since 20.10.2026 the
4–8 size is enforced in `create` (founder included), and there is a "Couples
circle" (pairs). Old circles without the new fields keep working.

### 17.4 Table for Six (dinner of friends of friends)

Seated at the table are people two steps apart: each knows someone who knows
the host.

1. Once you switch on "I want a Table for Six" with a city and days; the
   information goes to friends and friends of friends.
2. The host sets up a table; their app itself invites 5 people from within
   reach, connected to the host through different friends and knowing each
   other as little as possible.
3. Before dinner everyone sees the "through whom" paths; after dinner, "met in
   person" with one tap.

Technically an ordinary event with automatic invitations. Each dinner produces
new "met in person" links and the seed of future cells.

### 17.5 Ask the network (instead of a recommendations database)

1. A question ("Do you know a dentist in Gdańsk?") goes to friends.
2. Each answers or manually **forwards** it (at most 2 steps).
3. Answers return along the same route, signed, with the path ("Bartek's
   friend: …"). The question expires after 7 days.

One mechanism for recommendations, tradespeople, loans, jobs, rides. Recipient
safeguard: at most 20 questions per day from one friend (forwarded ones
included) and 50 answers per question, 200 answers per question in total. A
currency tip for an answer (§24) — done. **Answer signature — done
20.10.2026:** the answer is signed with the answering device's key (`sg`:
certificate, signature, address); verified by the asker and along the way; a
changed text/name/tip key is rejected; old unsigned answers get an "Unsigned…"
marker.

### 17.6 Weekend Plan

**Status: Done** (1.10.0, "Meetings → Weekend Plan"). A fourth form beside
events, circles and Table for Six, the lightest of them:

- You post a loose plan: "Saturday: bike ride by the Vistula, 10:00, who's
  in?", with a reach (close friends / friends / friends of friends).
- Friends reply "Joining" or "Maybe"; you see who is already in and through
  whom they are connected.
- When a threshold of takers is reached (e.g. 3), the plan turns itself into an
  event (§17.1) with a chat; without a threshold it expires after the deadline.
- Built from ready blocks (status + event + reach in steps).

Variant: **"Shared Cause"** (a neighbourhood collection, courtyard cleaning,
helping a neighbour) — **done 20.10.2026**: a plan with a list of needs
(`needs`), "I'll take it" claims (`c` in the reply, also through an
intermediary friend), a quantity limit enforced on the organiser's side; no
money.

## 18. Neighbourhood section

### 18.1 Flat profile

- The profile belongs to the **family / group currently living** in the flat
  ("the Nowaks · flat 12"), not to the flat itself. Any number of household
  members; new ones join by scanning the household code **inside** the flat.
  Every member can edit and reply.
- **Moving out:** the family takes the profile, the code on the old door stops
  working, neighbours are informed. New tenants create their own profile from
  scratch.
- Separate from main profiles (its own key). A member can themselves "Show my
  profile" to a chosen flat.
- Content: invitations (date, places, sign-ups), "We offer", "We need", "About
  us", one small photo.

### 18.2 QR on the door

- An A6 sticker (PNG, 300 dpi): QR + name + own tagline ("Scan — come over
  for coffee!"). The code contains the flat's address and key, not accounts.
  **Done (`FlatDoorCode`):** flat key + sticker password + name + the address
  of the flat's door, never a resident's. The door is a second, minimal
  Yggdrasil node in the bridge (`door_node.go`, `YggStartDoorNode`) with its
  own random key, kept on that phone only, peered to the main node over
  loopback; it takes only knock frames (`flat_hello`) and hands them to the app
  marked as door traffic; the app answers from its normal identity, and a knock
  with a wrong password gets no answer. The sticker carries the link
  `https://…/Zen/m#<code>` (`toLink()`); Zen reads both forms.
- "New code" invalidates the old one and gives the door a new key, so the old
  sticker's address no longer answers.
- The code has the form `zen-flat:…` and works without a website. The app also
  understands the link `https://<domain>/m#<code>`. There is no site of its
  own; invitations lead to the invitations page on GitHub Pages (§6.1). **Done
  20.10.2026:** the page `tool/pages/m/index.html` (English + Polish in a TEXTS
  object); a script in `index.html` redirects a long door-code hash to `m/`, so
  a door code scanned with an ordinary camera opens Zen or the download.
  `zen://m/<code>` and `/m#` links open the neighbours section and, after a
  confirmation, knock.

### 18.3 My neighbours

- Scanning a door sends our profile and brings theirs; both flats appear in
  each other's list. News from flats we scanned arrives always; from those who
  scanned us — after "Add".
- Messages between flats (any household member replies, you see who), sign-ups
  with seat limits, muting, deleting.
- **Invitation nearby:** over Bluetooth to phones with Zen in range ("Flat 12:
  barbecue on Saturday"), one tap to neighbours.
- Deliberately no "building community" — there is nobody to moderate it.

**Status: Done** ("Neighbours" — "Sąsiedzi" — on the bar). Everything signed
with the flats' keys, direct traffic with retries. **Removing a member who
won't leave:** a majority of the others votes; the flat gets a new key and a
code without that phone. Each member's phone has its own Ed25519 key that
neighbours remember; votes and the new-key notice are signed with it and
checked against keys known for at least a day. Two different new keys are not
resolved by "first wins": a neighbour sees the warning "ask the neighbours in
person", and scanning the new door code settles it. Done on 20.10.2026: the
door code without household addresses (§18.2), the `/m` page, and the
**invitation chat** — `FlatMessage.item` (`it` in JSON/wire, optional; old
phones show it in the ordinary thread), `sendMessage(..., itemId:)`,
`threadAbout`, an "Ask" button on an invitation.

Gaps: "code in clipboard" after installation (S); an event chat attached to the
invitation is done (see above); invitations nearby on desktop (no Bluetooth);
messages when no household phone is online for a long time. Limits: in a
two-person flat both versions of the new key are "valid" (the warning and
door scan remain); a member who pre-plants a profile with invented phones can
outvote the rest in neighbours' eyes.

---

# PART V — DATING (stage 8)

## 19. Dating through friends

**Idea:** you date people within 3 steps of friendship, always with someone in
common you can ask.

**Status: Done** ("Dating" — "Randki" — on the bar); distribution through
lanterns (§19.7).

### 19.1 Dating profile

- Switched on deliberately (off by default); no separate age question (the
  profile's age is needed for matching and must be at least 18); minors can
  be reported (§19.6).
- Separate, built from the main profile with one tap: name, age, gender, "about
  me", "what I'm looking for", up to 4 photos, preferences (gender, age, 1–3
  steps). Matching is mutual.
- **Nobody knows who is dating:** every app has a dating key (X25519) and every
  week sends friends a small lantern (§19.7) — real, or a decoy of the same
  shape. Everyone forwards lanterns on, up to 2 steps, appending themselves to
  the path; a phone without dating keeps nothing. A phone that sees a lantern
  that fits asks for the profile via the return path (the answer is sealed to
  the asker and padded to a multiple of 4 KB, a cover when dating is off); a
  phone with dating off asks for a share of the lanterns too and drops the
  answers — traffic looks the same for everyone.
- **Exclusions:** hiding from chosen friends and whole chat groups (salted
  address hashes in the profile).
- Turning dating off: the profile stops spreading and disappears from others
  after ~2 weeks.
- **Re-confirmation (20.10.2026):** `DatingReconfirm` — on entering Dating and
  after returning from the background (>= 10 s) it covers the screen and asks
  for the passcode/biometrics (`confirmSensitiveAccess`); inner screens
  (profile, chat, editor) lock only after returning from the background.
  SecureScreen checked: covers the Dating tab, profile, chat and editor.

### 19.2 Blind likes (nobody learns about an unreciprocated one)

"Yes" sends a token computed by both sides from their keys (HMAC from X25519);
"No" sends nothing, so it looks like no decision. A pair forms on "Yes" +
"Yes" and both sides know immediately.

### 19.3 Mutual friends — the dating revolution

- On every profile a path: "You know each other through: Bob → Kasia".
- **"Ask for an opinion"** from the friend through whom the profile came (the
  app warns that they will learn you are dating).
- **Matchmaking:** a friend introduces two people with a note (even too far
  apart to see each other); "Thank the matchmaker" in the pyramid currency.
- **Vouches:** a few signed (Ed25519) words from a friend on the profile; the
  signature covers the dating key, name, text and time.
- Return messages (likes, pair conversations, introductions) travel back step
  by step along the lantern's route, in two layers of encryption; phones along
  the way do not even know the sender's key.

### 19.4 Date safety

- **"I'm going on a date":** a chosen friend receives a note and the location
  (every 10 min and on request). After the time, a reminder; 15 min later an
  alarm for the friend and an ordinary alarm (§16.3) for you. "+1 h", "All OK".
  Deadlines are also counted by the background service.
- **Location on request (20.10.2026):** a new frame type `date_loc_req` (added
  to the reliable list in `relay_engine.dart`). The watching friend taps "Ask
  for location"; the phone of the person on the date asks for consent
  (notification + a "Send now / Not now" card) or replies by itself if the
  person agreed earlier (a switch at the start, `SafeDate.autoShare`). The
  reply is an ordinary `date_safe` update. Limit: one request per 2 min until
  answered; only the watching friend of an ongoing date may ask. Backward
  compatible (old phones ignore the new type; the new `as`, `ask`, `req` fields
  in SafeDate are optional).
- Blocking a person; reports (§19.6).

Honestly: the profile goes to anyone in reach who asks — a modified app sees
profiles in reach and one-sided "Yes"es. The answer's size reveals a range. At
most 100 new lanterns per day from a friend (§19.7).

### 19.5 Browsing cards (like Tinder)

**Status: Done** (1.10.0). "Match" uses today's introduction of a dating
profile (only to a known profile), and "Ask for an opinion" asks the friend
through whom the profile came.
- Profiles as a stack of cards: swipe right = "Yes", left = "No" (no change to
  §19.2 — "No" still sends nothing).
- One of the "photos" is a **text card** describing the person (about me, what
  I'm looking for, friendship path, vouches), swiped like the photos.
- On the card, buttons **"Match"** (introduce this person to someone else) and
  **"Ask a friend for an opinion"**.

### 19.6 Reports and dating ban

**Status: Done.** "Report" on a dating profile; in a pyramid the report goes to
the reports delegate or to the top (§21.4), and the app applies the dating ban
in Dating (the profile disappears, packets are not accepted). Without a
pyramid, your own block remains.

**Reporting a minor (20.10.2026):** a separate menu item on the profile. It
immediately disables the profile locally (`reportMinor`: disappears from lists,
pairs, is not accepted, gets no answer to its profile requests), then reports
to the pyramid (reason "minor") and hides it. Signal for others: reports ride
on the profiles a phone sends on request (field `mr` in the sealed answer, covers
too, so it reveals nothing). A phone that opens profiles from >= 2 different reporting
dating keys disables the profile on its side (`kDatingMinorQuorum`). The
pyramid's decision works as before via `isBanned`.  Known limitations: minor reports count distinct
dating keys, which are cheap (a Sybil attack could hide someone's profile from
people who fetch profiles of both fake keys); reports only within 2 steps.

### 19.7 Distribution scale (lanterns)

**Done 21.10.2026.** The weekly 8–52 KB packet flooded 3 steps made traffic
grow as the cube of the number of friends. Now every phone sends a
**lantern** (`date_lantern`, ~100 B: dating key plus 6 bytes — age, gender,
preference range, genders, steps) to **2 steps** (`kDatingMaxHops`; the
distance slider in the profile is 1–2). The profile is fetched **on request,
only when the lantern fits** both ways (age, gender, preferences, distance):
the asker sends a sealed `fetch` back along the way the lantern came, the
sender answers with a sealed `prof` (the profile, or a cover with dating off,
padded to 4 KB buckets; the reports of a minor ride in it, real or cover).
"Nobody knows who is dating" is kept: dating-off phones send decoy lanterns
(random valid values) and ask for a share of the lanterns they see
(`kDatingDecoyFetchShare`), dropping the answers. Limits: a dating key is
answered at most `kDatingFetchesPerKeyPerDay` times a day, 100 new lanterns a
day per friend, blocked, banned and hidden-from keys get no answer. Honestly:
the lantern shows age, gender and preferences of everyone to the phones on its
way, real or decoy, so they cannot tell who dates but can see a plausible
age/gender; anyone in range who asks gets the profile (as before).

---

# PART VI — COMMUNITY (stages 9–11)

Stages 9–11 are implemented ("Pyramid" — "Piramida" — and "Wallet" — "Portfel"
— on the bar); use will begin after the audit, the legal analysis, and once
there is a community. Before release: behind a feature flag (§2.5). Status and
gaps: end of §24.

## 20. The pyramid

### 20.1 Shape

```
                ┌──────── TOP: cell {S, A, B} ───────────────┐
                │ S = head of the pyramid; S, A, B have equal │
                │ power (decisions 2 of 3)                    │
                └──────────────┬──────────────┬──────────────┘
                   cell A: {A, A1, A2}      cell B: {B, B1, B2}
                        /         \
     cell A1: {A1, A11, A12}   cell A2: {A2, A21, A22}
```

- **Cell = triad:** a head + 2 members. Each member founds their own cell
  below and is its head, so everyone (except the top and the bottom) is in two
  cells.
- **Top:** the head of the pyramid S + A, B, equal power, decisions 2 of 3.
- Each level doubles the number of people: 25 levels is about 67 million.

### 20.2 Joining

- Only through a friend with a free seat (fewer than 2 people under them).
- Requirement: meeting in person (the cell head's QR) and a level of at least
  "Friend".
- The new person and the cell head sign the admission; the new person receives
  a member credential (§6.2). **Whoever admits, vouches** (§21.5).
- In the pyramid you appear as a pyramid identity (pseudonym, §6.4).
- **Done 20.10.2026:** the head signs an admission only for a friend at level
  "Friend" or higher (the private level from the node); otherwise the proposal
  waits with a message.

### 20.2a Basic data confirmed at entry

- At entry you give your nationality and gender, and optionally your birth
  year (skippable: without it there is no age badge and no age in the
  statistics, and joining is not blocked); the admitting person (meeting in
  person) signs that it is true and vouches for it.
- The data stays unchanged as long as you are in the pyramid; a correction =
  leaving and re-entering from the bottom. This way nobody, years into a
  promotion, "changes" their nationality to take over another country's
  section.
- Nationality is visible next to the pseudonym (national sections); age and
  gender only in anonymous statistics and as a badge you show yourself. Only a
  salted hash is published.
- **Done 20.10.2026:** a `badge` record — a member shows an age and gender
  badge: opens the year, gender and the salt from admission; checked against
  the `dc` hash. Turning off: `off: true`. Anonymous statistics (gender × age:
  up to 24, 25–39, 40–59, 60+) for your own branch from 5 people; branch sums
  go as a `pyr_sum` message to the head of the cell above (outside records;
  1.10.0 ignores them — its branch is not counted). The cell head sees the sums
  of direct members (a leaf = one person): "read" and the leaf's age/gender
  bucket are visible to them (like a vote in the triad, §21.3).

### 20.3 Changing the head: bottom-up, cell by cell

**In every cell 2 of 3 can swap the head with one of the members; a swap is an
exchange of places between two people.**

Example: in cell A = {A, A1, A2}, A1 and A2 sign "A1 becomes head". A1 takes
A's place in the cell above, A steps down and leads A1's former cell. Nobody
drops out, the branches stay.

The same level by level up to the top, where swapping the head of the pyramid
begins a **new term** (§23). A promotion needs support at every level; the top
cannot close the road upward. No time limits. Every swap is a public, signed
entry.

### 20.3a Anonymous request for a new vote

1. Any cell member can anonymously request a vote — a **ring signature** (LSAG
   on Ed25519) proves it is someone from the cell without saying who. A friend
   sends it.
2. All three vote, also by ring; you can see each voted once, not for whom.
3. The person with at least 2 votes wins (a swap as in §20.3); a 1:1:1 tie or a
   single vote — the head stays. Time: 72 h.

In a triad secrecy is limited; the app publishes only the winner, without the
vote count. The signature is linkable ("the same person is requesting for the
5th time"), so harassment is visible without blocks from above.

### 20.4 Migration and absence

- **Migration** to a cell with a free seat, with its head's consent. The cell
  under you stays, and its members (2 of 3) name who takes your place; with the
  whole cell's consent you move with the entire branch.
- **Absence:** after 60 days without a sign of life the other two declare the
  seat free (if one remains — that one; if none — the head of the cell above).
  "I'm alive" every 7 days from the app.
- **Leaving** at any time. Only a person's own cell can remove them.

### 20.5 Which pyramid is the real one

- There is no key built into the app, so there can be many pyramids. The app
  recognises the one you are in (and without membership, the one with the most
  of your friends). Someone in two sees the one they joined last.
- A pyramid of fake accounts does not contain your people.
- **Merging:** the top of the smaller (2 of 3) and a person with a free seat in
  the larger sign; the whole structure enters as a branch, the old one is
  closed.
- **Money on merging** (1.10.0): the joining top proposes a rate (e.g. 100 →
  80) or "no conversion". Balances at the time of merging are converted at the
  rate; for the receiving pyramid this is new money, so it works like an
  issue: 2 of 3 of its top, 30-day limit, a day's wait, veto. Transfers in the
  old pyramid stop counting after the moment of conversion.
- **Exchange between pyramids ("exchange office"):** a person in both announces
  a rate and a limit; the payer locks money with a key known only to them and
  the recipient, the exchange office pays the recipient out in their pyramid,
  locked with the same key; when the recipient takes it, the key becomes public
  and only then does the exchange office take the payment. Without a payout the
  money returns to the payer after 3 days.
- Only what follows from signatures counts; every client checks the chain from
  its cell to the top.

### 20.6 Why fake accounts will not take over the pyramid

Fake accounts form cells only under whoever introduced them; higher up they
need 2 of 3 in cells of real people. A meeting in person at every admission
costs time. Plus reports and penalties (§21.5), and referenda could be counted
only from members "met in person" by at least 2 people.

**Done (21.10.2026):** a member who signed a "met in person" attestation
(§6.2) about another member's account also signs a `met` pyramid record about
their pyramid key. The fold counts distinct current members per person; only
members met by >= 2 vote (`eligible`), a cell head's sum may add at most one
vote per such direct member (and the root's vote only if the root is one),
and the quorum of binding referenda counts only them. The Votes tab says why
someone cannot vote yet.

## 21. Power, delegations, bans, reports, referenda

### 21.1 Powers of the top (head of the pyramid + 2 members, equal power, decisions 2 of 3)

| Power | Delegable? | Description |
|---|---|---|
| Currency issue | no, top only | §23 |
| Political posts | each cell for its branch | §22 |
| Permanent ban | yes | account not admitted anywhere in the pyramid |
| Timeout (temporary ban) | yes | 24 h / 7 days / 30 days |
| Content ban | yes | hash of a post or file |
| Dating ban, admission ban | yes | §19.6, §21.5 |
| Receiving reports | yes | §21.4 |
| Referendum / poll | yes | whole pyramid or a branch |
| Emergency announcements | yes | crisis notice (§28) |
| Merging pyramids | no | §20.5 |

Done on 20.10.2026: timeouts of 24 h / 7 days / 30 days in a report decision.
A content ban carries the entry id (`eid`, S36).

### 21.1a Immunity in the pyramid

The top cannot ban everyone who approaches it:
- a ban never takes away a seat in the pyramid or a vote in the cell (it
  disables only social functions);
- only a person's own cell can remove them from the pyramid;
- bans of people from the 3 highest levels require their cell's consent.

### 21.2 Delegations

- A delegation: `{to whom, power, scope (pyramid / branch), monthly limit,
  until when, may pass on}`, signed by 2 of 3 of the top. The limit is counted
  across the whole chain; further delegation only narrower; valid while the
  delegate is in the pyramid.
- Every client checks the delegation chain. Revocation (top 2 of 3 or the
  issuer) invalidates the delegation going forward together with further
  delegations. The revocation record lists the acts the revoker knows about:
  those stay in force, and any other act dated before the revocation is
  treated as backdated and void. Delegates' acts are public; the top can
  overturn them (e.g. lift a ban).

### 21.3 Referenda

- Announced by the top, a delegate or the leader of a national section; the
  vote goes to the head of one's own cell.
- **Results counted by the tree:** each cell signs the sum of its branch (sum
  of children + its own cell) and passes it up.
- The vote is secret from everyone except one's own cell.
- **Hard minimum in code:** a constitutional referendum 72 h; an ordinary
  referendum and a poll bind nothing, so 2 min suffices (so they do not close
  before anyone sees them); sums only after the end; the head must include the
  newest sum of each branch (without it, it counts after 6 h), each once;
  numbers bounded by branch size.
- **Rules (20.10.2026):** there is one set of fold rules (no `rules` generation
  in `PyrParams`).
  - **S18:** a record whose rule throws during application leaves no trace —
    the fold is recomputed with that record rejected up front ("bad record"),
    deterministically on every phone (instead of copying the state per record,
    which would be O(n²)).
  - **Quorum from active members (§6 item 11):** a binding referendum
    (constitution, issue) counts turnout from members seen (a signed record,
    "I'm alive" every 7 days) in the last `absenceDays` before the vote ends,
    not from all seats.
  - **Full sum with a time limit:** a branch sum published after the top's sum
    (when the top already counted after the 6 h grace) does not invalidate the
    result.

### 21.4 Reports

- "Report" on a post, comment, profile, message (also in groups), dating
  profile. Reasons: illegal content, fake account, account farm, harassment,
  fraud, spam, other. The reported content can be hidden on your side at once.
- A report contains evidence (signed entries). It goes to the reports delegate
  in the branch; after 48 h without a decision, higher up, all the way to the
  top.
- The decision (ban, timeout, content ban, "no violation") is public; the
  reporter is anonymous to the reported. One appeal.
- Without a pyramid there is no power: what remains is blocking and "Remove
  from my device".

**Status: Partial.** "Report" is on posts, comments, profiles, messages (also
group ones) and the dating profile; reports are accepted only from members and
from those who handle them, with limits (1.10.0). Done on 20.10.2026:
- **Level-by-level escalation:** first the reports delegates of the narrowest
  branch around the reporter, then, after each `reportEscalateHours` without a
  decision, the next ones (a wider branch), finally the top.
- **A comment report names the author** (Board: the author's address in
  `FeedComment`; pyramid: long-press a comment → "Report").
- **S36:** a report carries the entry id and (when the phone has it) the signed
  original `LogEntry`; the recipient keeps it only after verifying the device
  signature and certificate; a content ban by entry id (also hides a modified
  copy).
- Timeouts 24 h / 7 days / 30 days (§21.1); a "Passed up: no decision below."
  marker.

Still missing: "Hide on my side" and the appeal button (`STATUS.md` B13, fixed
in 1.10.0), and "Remove from my device" (§26.1).

### 21.5 Fake accounts and farms

- An "account farm" report points at the person who introduces fake accounts.
  Signals: many accounts in a short time, no mutual friends other than them, no
  meetings, identical behaviour. The app should suggest them to the delegate
  from the graph (to do, M).
- Penalties: banning accounts, a timeout or ban for the introducer, loss of the
  right to vouch and admit, optionally reversal of transfers proven to be fraud
  (an open decision by the treasurers).

### 21.6 Limits of the top's power (summary)

The top **can:** issue currency (openly), ban (with immunity §21.1a),
delegate, write to the whole pyramid, announce referenda. It **cannot:**
remove people from the pyramid, block promotions, choose treasurers, change
past entries, hide an issue.

### 21.7 The constitution in code

The pyramid's rules (2 of 3, immunity, the issue limit, national section
rules) are in one versioned document in the app. Only a **constitutional
referendum** of the whole pyramid changes them: at least 72 h, turnout of more
than half of members, the full sum (every branch), "Yes" more than all other
answers together; then an act of the top, no earlier than 6 h after the end.
The rules themselves do not change these minimums.

## 22. Political section and national section

### 22.1 Political posts

- Every cell head (and the top) writes to their branch, with no post limit.
- Order: the top, then your line upward from the highest, within a level from
  the newest. A post carries the author's signed level at the time of
  publication.
- Under posts, branch comments (aggregated by the tree). Posts do not leave the
  branch unless someone shares them publicly.

### 22.1a Numbers: where each comes from

| Number | Meaning | Source |
|---|---|---|
| Level X of Y | distance from the top / depth of the pyramid | chain of cells (signatures) |
| N levels above you | how far along your line the author is | your chain of cells |
| Branch of N people | how many people are under the author | sums counted by the tree |
| Reached / read | how many in the branch have the post / opened it | anonymous tree sums |
| Your position | "Level 7 · branch of 124 · for 14 months" | as above |

Pyramid map: your line to the top with the numbers. A cell inflating a sum is
exposed by comparison with the signed sums of two cells below and is open
proof. Levels in the interface are counted from 1.

**Done 20.10.2026 ("Reached / read"):** the author of a post sees "Reached: X
of N · read: Y"; branch sums go as `pyr_sum` (see §20.2a).

### 22.1b How political posts arrive

Mainly down the pyramid tree, but also by ordinary synchronisation between
members who know each other (a head offline for long does not cut off the
branch). Everyone checks the signature and the author's right to write to that
branch.

### 22.2 National section

Priority posts are written by the **highest-placed person of a given
nationality (confirmed at entry)**, with no title — only the flag, level and
branch are shown.

- Safeguard: at least ~100 people of that nationality in their branch. Tie on a
  level: the larger number of people of that nationality. With no candidate the
  section works without priority. It changes along with the pyramid.
- Visible to everyone with that nationality in their profile (pyramid members
  comment). Order: the leader, then members by level.
- The leader: priority and pinning, granting the priority-writing right (with a
  deadline), national referenda and announcements. They cannot ban, issue or
  change the pyramid.
- **Pinning — done 20.10.2026:** a `natpin` record — the section leader
  pins/unpins a post (max. 3), pinned posts at the top (1.10.0 rejects the
  record, otherwise it changes nothing; not a "sign of life").

### 22.3 No parties

The app **has no parties** (decision of 14.10.2026): the pyramid itself is a
bottom-up representation, and parties with accounts and boards brought legal
risk (political financing, §27) and split the community into camps. Whoever
wants to found a party does so outside the app.

## 23. Currency (simple version)

**The bank is the top of the pyramid:** one ledger of balances kept by the
highest in the pyramid.

### 23.1 Who is who

| Role | Who | What they do |
|---|---|---|
| Issue | the top (2 of 3) | new money to a named account, with a justification |
| Treasurers | the 3 highest levels = 15 people | approve transfers, keep the ledger |

You are a treasurer by your seat in the pyramid, with no elections.

### 23.2 A transfer step by step

1. Janek signs (with his account passcode) an order `{from, to, amount,
   sequence number}`.
2. Each treasurer checks the balance and the next sequence number, signs and
   records it.
3. The transfer is valid with signatures of a majority of treasurers (8 of 15).
4. Treasurers synchronise the ledger among themselves.

Two different orders with the same number will not both win a majority,
because an honest treasurer signs one. An order with a majority that lacked
funds consumes the number.

### 23.3 Terms

An issue is marked with a term; a balance is split by term, and a transfer
spends the oldest first (FIFO).

### 23.4 Safeguards (only what is necessary)

| Threat | Safeguard |
|---|---|
| Double spending | sequence number + majority of treasurers |
| Phone thief | a transfer requires the account passcode |
| Theft of the top's keys → printing money | an issue is valid after 24 h, public, the third member of the top can veto it; a limit over a rolling 30 days (a larger issue — referendum); a late issue waits at the treasurers another 24 h |
| Some treasurers offline | 8 of 15 is enough |
| DDoS of treasurers | orders only from members, with a limit; addresses behind relays |
| A treasurer cheats | two conflicting signatures are open proof, bottom-up replacement |

Deliberate simplifications: treasurers see transfers (privacy later, L);
without internet there is no transfer; collusion of a majority of the 15 could
cheat. A treasurer signs only orders not older than a week and not from the
future.

**Issue above the limit by referendum (20.10.2026):** a
`kind: 'emit'` referendum of the whole pyramid (min. 72 h, announced by 2 of 3
of the top) on a specific amount for a specific person; after the end + 6 h
the top issues with `ref` — once; the day's wait and the veto still apply; it
does not count toward the 30-day limit. In the interface: "Above the 30-day
limit" and a confirmation that such an issue requires a referendum of the
whole pyramid (at least 72 h, more than half of active members, "Yes" more
than the rest); it waits for the second signature from the top.

### 23.5 What the currency is for

The access market (§24), matchmaking (§19.3), tips, collections, transfers
between people. **Conditional payments:** treasurers book a transfer after the
signature of a condition (e.g. the recipient's acceptance), a refund after the
deadline.

## 24. The access market

Your network has value; you can share it for free or for currency, on your own
terms.

| Service | How it works | Protection |
|---|---|---|
| Introduction | X pays F to be introduced to Y; F may refuse, Y decides | conditional payment after Y's acceptance |
| Paid inbox | Y sets a price for messages from strangers | spam does not pay; Y may refund |
| Reshare on order | X pays F to share a post | F approves the content (preview), payment after sharing |
| Network announcement | X pays for distribution to N steps | acceptance and a share at every step |
| Tip for an answer | in "Ask the network" | voluntary |
| Open access (free) | F gives X the right to their friend list, introductions, writing to friends | revoke at any time |

Price list in the profile: each service separately, price depending on the
level of acquaintance (friends / friends of friends / strangers). **Done
20.10.2026:** a "Pyramid price list" card on the profile (own and others').

**Paid introduction (20.10.2026):** a conditional payment where the decider is
the person being introduced; the intermediary passes on the request and is
paid only after their "yes"; refusal or no answer within a week → the money
returns to the payer.

### 24.1 The economy of contacts

**Status: Done without money** (1.10.0) — consent is the currency:
1. "Who sees my friend list": all friends / on request only / nobody; requests
   are approved in the Inbox, consent is revoked in the Graph;
2. introduction: X asks F, F passes it on with their word (or not), Y decides;
   after "yes" both get an ordinary friend invitation, and X does not see
   refusals;
3. a letter via a mutual friend: one message to a stranger, at most 3 a week
   through one person (the intermediary passes on at most 10 a week); the
   recipient can only invite to friends or ignore;
4. "Ask for an introduction", "Write a letter" and "Ask for an opinion" on the
   graph.

Within one pyramid the intermediary can additionally price an introduction on
its market (§24). There is no currency outside the pyramid — risk: points that
buy access to people may be a payment service / electronic money (financial
regulator, AML, §27) and turn friends into a commodity.

### Implementation status of stages 9–11 (V1.10, updated 20.10.2026)

**Done in code.** The "Pyramid" tab (Me / Politics / Country / Votes / Wallet /
Power / History); the wallet also has its own button on the bar.

- **Signed records, state computed on every phone:** a record signed with
  Ed25519 by those the rule requires; each phone assembles the state itself in
  the same order (time, id); records that break the rules are rejected by
  everyone. Synchronisation only between friends (bucket digests hello / ids /
  want, also after a network split; the digest covers signatures). A phone
  accepts records only of its own pyramids, nothing more than 10 min in the
  future, every signature checked; a bad record does not stop the assembly.
  Records in a log appended in segments; verified ring signatures are
  remembered on disk, the first verification in the background.
- **Record time:** a proposal signed more than 10 min after creation goes as a
  fresh copy; when signing you see the time and the fields that decide the
  effect. Hard safeguards where backdating gave power (closing the pyramid only
  by today's top, revocation of a delegation lists known acts, conditional
  payment settlements signed by treasurers, a late issue waits).
- **Proposals to sign** end when a record satisfies the rule (a trial assembly
  of the state), so complex requirements do not come out half-done.
- The main mechanisms of §20–24 are done as described above (gaps below and in
  `STATUS.md` §10), including: anonymous votes, migration with a branch,
  merging pyramids, delegations with a limit across the chain, immunity to
  depth 3, reports, tree referenda, the constitution, the national section,
  currency with a veto, conditional payments, prices by level, an announcement
  along a chain of up to 5 intermediaries (an equal share at each step, a
  content hash prevents substitution), a tip in "Ask the network".
- **Crisis mode** (§28): an alarm from the top, a delegate or a section with a
  reach, a Bluetooth wave (signed, version 3) also to phones outside the
  pyramid ("unverified"); onward goes only a wave valid in the recipient's
  pyramid.
- **Tests:** ring signatures in `test/ring_signature_test.dart`; the earlier
  comparison with a separate Python implementation left no script in the
  repository, so it cannot be repeated (to add or replace with test vectors)
  (S); over 20 scenarios in the simulator (including chaos), a script for real
  apps (`TESTING.md`).

**New record kinds (20.10.2026):** `natpin`, `badge` (see §22.2, §20.2a); 1.10.0
rejects them, they change nothing else and are not a "sign of life".

**Gaps:** feature flags (S); pyramid traffic through relays and hiding the
device address (M/L); the pyramid key from the account key (S/M); recomputing
from scratch every 60 s on the interface thread and all records at every
member (M–L: checkpoints, incremental background computation, a phone keeps its
own branch); transfer privacy (L); transfers spread to all members, whereas
§23 speaks of treasurers. Smaller (`STATUS.md` §10): reversal of transfers
proven to be fraud. The `report` and `appeal` acceptance from anyone was fixed in 1.10.0
(S1). Done on 20.10.2026 from the earlier list: timeouts of 24 h / 7 days / 30
days, admission with a "Friend" level check, "Reached / read" counters, pinning
in the national section, issues above the limit by referendum, the price list
in the profile, the quorum of the constitution counted from active members
(`STATUS.md` §6 item 11).

**Honestly:** this is code before an audit. The ring cryptography is our own
implementation (BigInt, without repeatable independent verification,
unaudited, slow; a ring is 2–3 keys). A friend who forwards a vote sees that
you sent something. Without a shared clock backdating cannot be proven:
collusion of all required signatures can move a record's date back (visible in
the history); the third member of the top can veto an issue with a late veto;
a late vote can change the result retroactively; when an abandoned order was
signed by exactly half the treasurers, the account waits for completion; the
composition of a joining pyramid is attested by its top. An announcement goes
along a chain, not a tree; the pyramid key in an answer to a question is the
answerer's declaration. Minor-report counting by distinct dating keys is also
open to a Sybil attack (§19.6). Recorded in the cell-head view: the head sees
the sums of direct members (§20.2a).

---

# PART VII — THE WHOLE

## 25. App navigation

A vertical bar on the left: icons only, narrow (56 px) on every screen, also
on desktop (where the whole app is currently phone-width; two panes from ~900
px — `STATUS.md` A24).

**Status: Partial.** The tab order today: **Graph → Profile → Chats → Board
("Tablica") → Meetings ("Spotkania") → Dating ("Randki") → Neighbours
("Sąsiedzi") → Pyramid ("Piramida") → Wallet ("Portfel") → People nearby →
Invite → About → Alarm** (red, at the bottom) and "Lock now" (when a passcode
is set). The app starts on Chats. Buttons narrow themselves, so 13 tabs with
the lock fit on a 360×568 screen. The bar can be hidden (a button or a swipe;
the app remembers it).

**Done on 20.10.2026 (tab grouping):** 6 tabs on the bar (Graph, Profile,
Chats, Board, Meetings, Neighbours) + "More" (a sheet with groups — Meetings:
Dating, People nearby; Community: Pyramid, Wallet; Other: Invite, About) +
Alarm.

- At the top a connection status bar; tapping it opens settings (no separate
  tab). Every section has the same header (`ZenSectionBar`).
- Board: posts from friends and followed people (your own on the profile); the
  "What's new?" card opens a full-screen editor (recipients, up to 10 photos,
  video, voice note, Ctrl+Enter).
- Default system theme; in the light theme the logo is black. 27 accent
  colours.
- "About": first the collection, then what Zen is (also the pyramid and
  bottom-up politics), why, how to use it, privacy (the recovery circle),
  platforms, Yggdrasil, why it is not in stores, how to check it is not a
  virus, the official GitHub link, licences at the end. Also "Pass it on".
  Added on 20.10.2026: two tiles, "Privacy policy" and "Terms" (links to
  GitHub; test in `test/about_screen_test.dart`). Note: the "About" text claims
  Zen adds its own encryption to every message; in code, direct messages are
  protected by Yggdrasil's end-to-end encryption, and the app's own layers
  are in relay inboxes, the ledger, dating, etc. — the text needs correcting.
- **Accessibility (done 20.10.2026):** the alarm button (Semantics,
  long-press), graph nodes (CustomPainterSemantics), tab card labels with an
  unread badge.

### 25.1 Languages and translations

**Status: Done** (1.10.0). Instead of ARB (`flutter_localizations` + `intl`) —
our own simpler layer (`lib/src/app/i18n/zen_i18n.dart`):

1. **Polish is the source language.** Every text in code is a Polish sentence
   in `t('…')`, with named placeholders (`t('Wysłano do {name}', {'name': …})`);
   plurals through `tn(n, one: …, few: …, many: …)`. Other languages look up
   the translation by that text in `assets/i18n/<code>.json`; plurals follow
   the language's CLDR rules (e.g. six Arabic forms). No translation = the
   Polish text.
2. **21 languages:** Polish, Indonesian, Czech, German, English, Spanish,
   French, Italian, Hungarian, Dutch, Portuguese, Romanian, Vietnamese,
   Turkish, Russian, Ukrainian, Arabic (right-to-left layout), Hindi,
   Simplified Chinese, Japanese, Korean.
3. **Selection:** automatic by default — the first system language Zen knows,
   and failing that, English. **Settings → Language:** "Automatically" or a
   specific language; the change is immediate, with no restart (all widgets
   rebuild). The choice lives in a plain `language.txt` file in the data
   folder, because it is needed before unlocking (the lock screen) and in the
   background service (notifications); Material texts and layout direction
   follow Zen's language (`zen_locales.dart`).
4. **Enforcement:** `dart run tool/i18n.dart` checks that `t()` and `tn()` get
   only plain string literals, and for every file lists missing and stale
   texts and mismatched placeholders (exit code 1); `--keys` prints all texts
   as JSON, `--prune` removes stale ones. `test/i18n_test.dart` (in CI) does
   the same checks.
5. We do not translate: logs, keys and identifiers, data stored and sent to
   others, proper names.

**Done on 20.10.2026 (outside the Dart UI):** everything outside the Dart
interface is now English by default and translated into the app's 21 languages
where the platform allows: the invitations page `tool/pages/index.html`
(language from `navigator.languages` or `?lang=xx`, a TEXTS dictionary in one
file, RTL for Arabic, links built from nodes without `innerHTML`; `zen://` /
`intent://` with the code, code copying and download links kept); iOS and
macOS `Info.plist` in English with `InfoPlist.strings` in 21 `<code>.lproj`
folders; Android `res/values/strings.xml` (en) + `values-<lang>` (21 languages;
Kotlin and layouts read `getString` / `@string`); a Linux `.desktop` file with
`Comment[xx]`; draft release notes in English.

Gaps and pitfalls (`STATUS.md` A23): some texts are saved in state already
translated (Inbox entries, "Now", system messages) and stay in the old
language after a language change; a fix to a Polish text loses its
translations, and one Polish string with two meanings has one translation (to
add: `context:` in `t()` and marking "to review"); date, number and amount
formats per language — to verify; the GIF search always queries in Polish.

### 25.2 Permissions screen

**Status: Done** (1.10.0, completed 20.10.2026; on Linux and macOS there is no
screen, macOS asks by itself on first use). One screen at first launch (after
the passcode) and in settings, explaining why and showing the state of each
permission: notifications; Bluetooth / nearby devices; location (for the
alarm, also in the background); camera and microphone; turning off battery
optimisation (with instructions for Xiaomi, Samsung and others); full-screen
notifications; exact alarms. Not granting does not block the app — it says what
will not work.

Added on 20.10.2026: location, background location (Android 10+, active only
after ordinary location), exact alarms (Android 12+, a system page), battery
instructions per manufacturer (Xiaomi, Samsung, Huawei, OnePlus, Oppo/Realme,
Vivo + general) in `vendor_battery_help.dart`, linked from Settings (the
battery card). Kotlin `ZenPermissionsBridge` returns `manufacturer` and
`exactAlarms` and opens the exact-alarms page; manifest:
ACCESS_BACKGROUND_LOCATION, SCHEDULE_EXACT_ALARM. First launch: a short
"Welcome to Zen" card above the permission steps (no separate step before the
passcode).

**"Why doesn't it work?" (A22):** `HealthScreen` — network, node and
neighbours, background work, notifications, battery, clock, free space, with
fix buttons and "Copy report" (no addresses); from Settings (App) and from the
connection bar (a "?" icon when disconnected). **Clock bar (A21):**
`ClockSkewTracker` gathers time from friends' messages (a hook in
`_effectiveSentAt`); a difference of >2 min confirmed by at least 2 friends =>
a bar under the connection bar and a row in the report.

### 25.3 Look and feel — ideas

**Proposals (S–M):**
- The "ZEN" mark from the logo also in the panel header and on the lock screen.
- State animations: soft appearance of cards, a pulse of statuses on the graph,
  send confirmation (haptics).
- Illustrations for empty screens in the logo's style instead of bare icons.
- Photos at the centre: larger avatars, event covers, flat photos.
- Accessibility: screen-reader labels — done for the alarm button, graph and
  tabs (§25); the rest to do.
- Redesign of statuses (§16.2).

## 26. Gaps and risks

### 26.1 Security and political gaps

| # | Gap | Risk | What we do |
|---|---|---|---|
| 1 | The bridges' IP list = the list of PC users; a bridge reveals whose computer it is | a state collects the announcements and identifies subscribers | an anonymous key in the announcement; a switch in settings; to consider: a separate listening key, in countries with a ban a bridge only for friends |
| 2 | Taking over the pyramid through detentions | a detained person knows their 2 cells | minimum of data (faces and pseudonyms), a panic passcode, replacing the absent |
| 3 | The pyramid graph visible inside the pyramid | structure analysis + IP links pseudonyms to people | pyramid traffic through relays, hiding the device address (§6.4) |
| 4 | A forged installer | a copy passed on with spyware or a swapped collection | §14.3; Android blocks an update signed with a different key |
| 5 | Approving releases | a version with a backdoor as an update | §14.2 "Open decision", 7 days before activation |
| 6 | Treasurers see transfers | taking over a treasurer's phone = the financial history of pseudonyms | pseudonyms, deleting old transfers, a panic passcode; transfer privacy later |
| 7 | No moderation before the pyramid | illegal content in shares and at intermediaries | "Remove from device" with a hash block (M); a button with instructions for law enforcement; an optional hash list from a chosen organisation |
| 8 | Minors | a network for < 16 requires parental consent (GDPR) | **no age gate (owner's decision, 21.10.2026)**: Dating and the Wallet do not ask about age; the Pyramid asks for an optional birth year (§20.2a) that is not a condition for joining. Reporting a minor (§19.6) remains. No age verification and no restricted mode for < 16 (S) |
| 9 | A state "big pyramid" | disinformation about the movement's strength | everyone sees the legitimacy of their own pyramid; numbers verifiable in the branch |
| 10 | Infiltration | taking over the structure from within | removal by swapping, public acts, immunity |
| 11 | Delayed Yggdrasil update | known bugs | a quarterly review (§5.2) |
| 12 | One implementation | an app bug = a whole-network bug | an open protocol (§28), an audit before the currency and the pyramid |

### 26.2 Project risks

| Risk | What we do |
|---|---|
| An empty network at the start | start in one environment (a block of flats, a university, a city), a narrow entry wedge (neighbours or meetings), a simple loop: add a friend → write → arrange → meet |
| iPhone | §26.3 |
| Yggdrasil scale (an experimental project) | the engine does not depend on Yggdrasil; a load test before the pyramid |
| Battery and data | the phone is not a bridge, synchronisation in packets, media "Wi-Fi only", BT scanning only with the screen open (§15) |
| Project size, feature creep | a "core" release behind flags (§2.5) |
| One maintainer | open code, this document, the protocol (§28), a key backup (§14.2); a decision on the licence and a foundation (`STATUS.md`) |

### 26.3 iPhone, Mac, Linux — options

**iPhone status: the chosen route is AltStore / SideStore with a free Apple
ID** (1.10.0). GitHub Actions on macOS builds an unsigned `Zen-unsigned.ipa`
with the Go bridge as a static library; the installer signs it. No background
work, Bluetooth or push (§13.4); instructions in the README. Distribution
routes:

| Route | Pros | Cons |
|---|---|---|
| App Store / TestFlight | ordinary install for everyone; TestFlight up to 10,000 testers (a build valid for 90 days) | Apple review (UGC, "pyramid", dating — it may reject or remove), a USD 99/year account, the seller = the author's full name, push via APNs needs a server |
| AltStore PAL (EU, Japan, Brazil) | notarisation instead of content review; from 01.10.2026 no fees for a free app; the source file on GitHub Pages | a USD 99/year account; only Apple accounts from those countries |
| Web Distribution (EU) | install from your own site | organisations only (e.g. a foundation with a fee waiver) |
| AltStore / SideStore with a free Apple ID | no Apple review, works worldwide | signing every 7 days, at most 3 apps, a computer for the first install |

Details and plan: `RELEASES.md` §6, `STATUS.md` §9.

**Linux and macOS status: code and releases from CI** (1.10.0, unverified until
the first CI run). Linux x64 and ARM64 (`Zen-Linux-*.tar.gz`, key in GNOME
Keyring / KWallet, tray via AppIndicator); macOS 12+, universal
(`Zen-macOS.zip`, Go bridge static as on iPhone, Touch ID through the Secure
Enclave, no sandbox, ad hoc signature — from macOS 15 the first launch goes
through "Open anyway"). Linux and macOS computers are bridges like Windows.
Missing: Bluetooth, call recording, camera and QR scanner; on macOS Developer
ID signing and notarisation (the same account as iPhone). Emergency fallback:
a guest mode in a browser through a friend's phone or computer (L) — a
browser version is out (a server could swap the code).

**Platform coverage, wave of 20.10.2026 (for 1.11.0):**

| Platform | Status | Release file | Notes |
|---|---|---|---|
| Android arm64-v8a | works (as before) | `Zen.apk` (universal) | Go bridge as before |
| Android armeabi-v7a | **new** | `Zen.apk` | Go bridge `GOARCH=arm GOARM=7`, NDK `armv7a-linux-androideabi21-clang`; older 32-bit phones |
| Android x86_64 | **new** | `Zen.apk` | ChromeOS, emulators; NDK `x86_64-linux-android21-clang` |
| Android x86 (32-bit) | none | — | Flutter has no release engine for x86 |
| Android "store" (Play, Galaxy Store) | **new**, built manually | `flutter build appbundle --release --flavor store` | no `REQUEST_INSTALL_PACKAGES`, no self-update, "Pass it on" as a link |
| iOS arm64 (+ simulator arm64/x86_64) | unchanged | `Zen-unsigned.ipa` | iOS 15+ |
| Windows x64 | unchanged | `Zen-Windows.zip` | |
| Windows ARM64 | **new, experimental** | `Zen-Windows-arm64.zip` | native build on `windows-11-arm`; Go bridge through llvm-mingw; needs `flutter_webrtc` >= 1.5 (bumped in pubspec); until the first green run the job does not block the release. x64 also runs on Windows 11 ARM under emulation |
| Linux x64 | extended | `Zen-Linux-x64.tar.gz`, **`Zen-Linux-x64.deb`** | audio/video playback (GStreamer), `.desktop` file (menu, `zen://` links, icon on Wayland), AppStream |
| Linux arm64 | extended | `Zen-Linux-arm64.tar.gz`, **`Zen-Linux-arm64.deb`** | as x64 |
| macOS universal (arm64 + x86_64) | unchanged | `Zen-macOS.zip` | macOS 12+ |

- **Android — three ABIs.** The Go bridge is built for arm64-v8a,
  armeabi-v7a and x86_64 (`build_android.sh`/`.ps1`, a shared list in
  `bridge_tools.ps1`), each ABI with its own `.sha256` marker — only changed
  ones rebuild. Gradle takes the ABI from Flutter's `target-platform`:
  `flutter run` builds the bridge only for the device's ABI, `flutter build
  apk` for all three. Self-update and "Pass it on" assume a single file.
- **Android — "store" variant (D12).** The `store` flavor (by default, as
  before, the full app = `direct`): the `src/store` manifest removes
  `REQUEST_INSTALL_PACKAGES`; Dart (`appFlavor == 'store'` or
  `--dart-define=ZEN_STORE=true`) turns off the update service, shows "Updates
  from the store" and replaces "Pass it on" with a window containing a link
  (`--dart-define=ZEN_STORE_URL=…`, by default the project page). Flavors
  engage only with a flavor task (`--flavor store|direct`) or
  `-Pzen.flavors=true`, so plain `flutter build apk` / `flutter run` work
  unchanged. Build: `flutter build appbundle --release --flavor store` (Play),
  `flutter build apk --release --flavor store` (Galaxy Store). The remaining
  D12 points (FGS declarations, 18+, names, terms, Data safety…) — not in this
  wave.
- **Windows ARM64.** `build_windows.ps1 -Arch x64|arm64` (by default the
  computer's architecture), the ARM64 DLL in `bin\windows-arm64\`, x64 as
  before in `bin\`; CMake chooses by `FLUTTER_TARGET_PLATFORM`/the generator
  platform; Dart (debug) looks for the DLL of the right architecture
  (`Abi.current()`). cgo on ARM64 needs llvm-mingw
  (`aarch64-w64-mingw32-clang`; CI downloads version 20251021 and checks the
  SHA-256). New jobs: `windows-arm64` in release.yml (file
  `Zen-Windows-arm64.zip`, `continue-on-error`, SHA256SUMS are computed
  without it if it fails) and in ci.yml (push to main).
- **Linux — playback.** Our own `video_player` backend on GStreamer:
  `linux/runner/zen_media_player.cc` (playbin, RGBA frames to
  `FlPixelBufferTexture`, rotation of phone videos via `videoflip`, tempo at
  1.5×/2× via `scaletempo`) + `lib/src/features/media/linux_video_player.dart`.
  Without GStreamer at build time or on the system — an immediate "cannot
  play" (as before), without hanging. Rejected: `video_player_media_kit`
  (downloads and replaces the whole app's `malloc` with mimalloc, a hard
  dependency on libmpv, plugin code on every platform — earlier removed from
  Windows), `fvp` (adds FFmpeg/mdk to every platform). Codecs: AAC/H.264 from
  `gstreamer1.0-libav` (in the .deb's recommended dependencies).
- **Linux — integration.** `linux/packaging/com.roj.zen.desktop`
  (`MimeType=x-scheme-handler/zen`, `StartupWMClass=com.roj.zen`),
  `com.roj.zen.metainfo.xml` (AppStream, validates), `install-desktop-entry.sh`
  in the tar.gz (menu and links for the current user), `build_deb.sh`
  (`dpkg-deb` only; dependencies from `dpkg-shlibdeps`, with non-`t64`
  alternatives for older Debians; `/opt/zen`, `/usr/bin/zen`). The runner is
  now single-instance via GApplication (an app_links requirement on Linux: a
  link from the browser reaches the running Zen); the test profile
  (`--zen-profile`/`ZEN_PROFILE`) still starts alongside. Flatpak — not done
  (needs Flutter and Go dependencies gathered offline in the manifest;
  separate M). Still missing on Linux: biometrics.

## 27. Law (to be consulted with a lawyer — I am not a lawyer)

- **Currency and the economy of contacts:** funds exchangeable for goods or
  services may fall under rules on electronic money and payment services
  (financial regulator), AML, possibly MiCA. A safe path at the start:
  non-exchangeable "gratitude points" or a version without money (§24.1).
- **Politics:** the app has no parties or party accounts (§22.3), so the
  currency does not finance parties. Foreigners in the pyramid and campaigns —
  to be analysed. The app cannot enforce an election silence.
- **Dating:** 18+ is stated in the terms only (no age question, deliberately);
  terms and a quick way to report minors are needed — the report-a-minor path
  is done (§19.6).
- **Illegal content:** the absence of an operator does not remove the risk;
  rules, reports, "Remove from my device".
- **GDPR:** the author may be deemed a joint controller; the "right to
  erasure" clashes with signed chains and copies at friends. The pyramid
  (political views) and dating (intimate life) are special-category data
  (art. 9): minimisation, encryption, pseudonyms, explicit consent.
  **Drafted on 20.10.2026 (English, in `docs/`):** `PRIVACY.md` (privacy
  policy: minimum age 16, dating 18+, klipy.com, buycoffee.to, Yggdrasil
  nodes; an HTML comment for the maintainer: this is not legal advice),
  `TERMS.md`, `DPIA.md` (a draft impact assessment). **Still to do (S):** a
  lawyer's review, the parental-consent gate under 16.
- **The alarm** does not replace 112 — this must be communicated clearly.
- **"Pyramid" vs the ban on financial pyramid schemes:** entry always free,
  no rewards for bringing people in, the issue independent of branch size.
  Consider a different name in the interface ("Structure", "Community",
  "Council").
- **DSA:** without an operator the obligations are unclear; it is safer to
  have a foundation with terms and a reporting channel for law enforcement.

## 28. Ideas for later

1. **Crisis mode without the internet:** a crisis notice from the top or a
   delegate travels as a Bluetooth wave from phone to phone (done for crisis
   announcements); a full Bluetooth/Wi-Fi Direct mesh for ordinary messages —
   to do (L).
2. **Open protocol:** a published specification of entry and frame formats
   (M), so others can write compatible apps. **Started on 20.10.2026:**
   `docs/PROTOCOL.md`, a protocol specification derived from the code, with
   [V]/[P]/[?] markers.
3. **A trust map for a person** on the graph: how many personal meetings,
   gratitude cards, how long in the pyramid — without stars (S).
4. **Growth through meetings:** "your branch grew by 12 people this week",
   cell invitations only live.
5. **Invitation through an event:** an event link as a way to invite someone
   without Zen.

## 29. On-device AI assistant — removed (V1.9)

V1.8–V1.9 had an "Assistant" tab (an on-device language model, llamadart;
rating messages before sending, warnings, translations, a tamagotchi, a
Notebook). Removed in V1.9 because the model could freeze the system. A
one-off cleanup of leftovers was removed together with the compatibility code
in 1.10.0 (§2.5). It returns only with a plan that does not burden the device.
