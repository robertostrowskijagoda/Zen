<p align="center">
  <img src="assets/branding/logo.jpg" width="128" alt="Zen">
</p>

<h1 align="center">Zen</h1>

<p align="center">
  <b>A network of people who know each other.</b><br>
  A messenger and social network with no servers, no ads and no algorithm,
  encrypted end to end and resistant to quantum computers.
</p>

<p align="center">
  <a href="https://github.com/robertostrowskijagoda/Zen/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/robertostrowskijagoda/Zen/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white" alt="CI status"></a>
  <a href="https://github.com/robertostrowskijagoda/Zen/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/robertostrowskijagoda/Zen/release.yml?label=release%20build&logo=githubactions&logoColor=white" alt="Release build status"></a>
  <a href="https://github.com/robertostrowskijagoda/Zen/releases/latest"><img src="https://img.shields.io/github/v/release/robertostrowskijagoda/Zen?include_prereleases&sort=semver&label=latest%20release" alt="Latest release"></a>
  <a href="https://github.com/robertostrowskijagoda/Zen/commits/main"><img src="https://img.shields.io/github/last-commit/robertostrowskijagoda/Zen?label=last%20commit" alt="Last commit"></a>
  <br>
  <a href="docs/SECURITY_MODEL.md"><img src="https://img.shields.io/badge/post--quantum-ML--KEM--768%20%2B%20ML--DSA--65-6d28d9" alt="Post-quantum: ML-KEM-768 and ML-DSA-65"></a>
  <a href="#platforms"><img src="https://img.shields.io/badge/platforms-Android%20%C2%B7%20iOS%20%C2%B7%20Windows%20%C2%B7%20macOS%20%C2%B7%20Linux-0f766e" alt="Platforms: Android, iOS, Windows, macOS, Linux"></a>
  <a href="#building-from-source"><img src="https://img.shields.io/badge/Flutter-3.47.1-02569B?logo=flutter&logoColor=white" alt="Flutter 3.47.1"></a>
  <a href="native/yggdrasil_bridge/go.mod"><img src="https://img.shields.io/github/go-mod/go-version/robertostrowskijagoda/Zen?filename=native%2Fyggdrasil_bridge%2Fgo.mod&logo=go&logoColor=white&label=Go" alt="Go version"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-GPL--3.0--only-blue" alt="License: GPL-3.0-only"></a>
</p>

<p align="center">
  <a href="https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen.apk"><b>⬇ Android</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Windows.zip"><b>⬇ Windows</b></a>
  &nbsp;·&nbsp;
  <a href="#iphone"><b>📱 iPhone</b></a>
  &nbsp;·&nbsp;
  <a href="#mac-linux"><b>💻 Mac, Linux</b></a>
  &nbsp;·&nbsp;
  <a href="docs/guide/README.md"><b>📖 User guide</b></a>
  &nbsp;·&nbsp;
  <a href="#support-zen"><b>💜 Support</b></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/graph-dark.png">
    <img src="docs/images/graph-light.png" width="200" alt="The friend graph">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/chat-dark.png">
    <img src="docs/images/chat-light.png" width="200" alt="A conversation with delivery icons">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/pyramid-tree-dark.png">
    <img src="docs/images/pyramid-tree-light.png" width="200" alt="The pyramid">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/themes-dark.png">
    <img src="docs/images/themes-light.png" width="200" alt="Themes">
  </picture>
</p>

> **Did someone show you a QR code?** The code opens an invitation page: if you
> have Zen, the page opens it right away with the invitation; if you don't, it
> shows the download buttons. After installing, come back to that page and tap
> **Open in Zen** (or in Zen: **Invite → I have someone's code** and scan the
> code again).
>
> **Already have Zen on Android?** Turn this on once in Zen: **Invite → Zen codes
> straight into the app → Open supported links**. From then on a code scanned
> with the ordinary camera opens straight in Zen.

## What it is

Zen is a messenger and network for people who know each other, without a
company in the middle. There is no server that sees everything, no ads and no
algorithm deciding what you see. Messages, photos and posts go straight
between your friends' phones and computers, encrypted, and your data stays on
your device.

Zen also tries a new way of deciding shared matters: the **pyramid**, built
from small cells of people who know each other in person, where votes, trust
and a common purse flow from the bottom up, with no headquarters that could be
bribed or shut down.

## Post-quantum

A quantum computer able to break today's public-key cryptography does not
exist yet, but traffic recorded today could be decrypted once it does. Zen is
built for that: **its key exchanges are hybrid ML-KEM-768 + X25519 and its
lasting signatures hybrid Ed25519 + ML-DSA-65** (NIST FIPS 203 and 204), with
the few exceptions listed below. A hybrid stays safe as long as either half
holds.

| Protected | How |
|---|---|
| Every signal between two devices: messages, sync, call set-up | a session per device pair, ML-KEM-768 + X25519, ChaCha20-Poly1305, no plaintext mode |
| Offline mailboxes and the locked phone's inbox | sealed once more for the recipient's hybrid key |
| Device identity | device keys pinned per address and bound to it by a hybrid signature |
| Everything signed and kept: posts, profiles, devices, pyramid records, ballots, anonymous vote requests and votes, releases | Ed25519 + ML-DSA-65, valid only when both verify |
| Calls | AES-128-GCM frames with per-call hybrid keys, inside a 256-bit ChaCha20-Poly1305 post-quantum relay layer |
| Neighbours' doors, Bluetooth hellos, local link handshakes and pair secrets, dating boxes, food pickup addresses | ML-KEM-768 + X25519 |
| Event tickets | hash-based (HMAC-SHA256), no signatures needed |
| Links to public peers | TLS 1.3 with X25519MLKEM768 |
| Data on your device | AES-256-GCM, a key from your password (Argon2id) |

**Still classical, honestly:** the Yggdrasil node key and address (Ed25519,
the mesh protocol itself; it routes, but no longer proves who you are), the
ring signature that registers a voting card between cellmates (requests and
votes themselves are signed post-quantum by those cards), the pair secret
that lets devices recognise each other on local links until they first meet
over the mesh, and the 128-bit AES key inside call frames (wrapped in the 256-bit layer).
Why, and what an attacker could do: [Security model](docs/SECURITY_MODEL.md).

## What it can do

- 💬 **[Chats and calls](docs/guide/chats-and-delivery.md):** chats, groups
  with a board, voice notes, audio and video calls, screen sharing. Messages
  for offline friends wait sealed with their trusted friends, and the icons
  tell you exactly where a message is.
- 🕸️ **[Friends and the graph](docs/guide/friends-and-graph.md):** friendship
  levels that decide who sees what; a graph of who knows whom with a
  timeline, bridges between your circles, *who's worth meeting*, full screen.
- 📰 **[Feed and videos](docs/guide/feed-and-videos.md):** posts only for the
  people you choose, and a short-video section, ordered on your own phone.
- 🍲 **[Meeting people](docs/guide/meeting-people.md):** *right now*
  statuses, events through friends with offline tickets, dinner circles,
  sharing food, people nearby over Bluetooth, and an **alarm** that works
  from a locked Android phone.
- 🚪 **[Neighbours](docs/guide/neighbours.md):** a QR code on your door; a
  knock rings every phone of the household, and waits with friends when
  nobody is home.
- ❤️ **[Dating](docs/guide/dating.md):** through friends, up to three steps
  away, with a private match test that tells nobody else anything.
- 🔺 **[The pyramid](docs/guide/pyramid.md):** cells of three, promotion one
  level at a time, anonymous cell votes, referendums, a court with appeals, a
  common wallet with a hard issuance limit, and an animated history.
- 🚦 **[Introductions and gates](docs/guide/introductions-and-gates.md):**
  reach people further away through friends, free or for points, with a route
  planner.
- 📡 **[Offline links](docs/guide/offline-links.md):** same Wi-Fi, Wi-Fi
  Direct and Bluetooth: Zen without the internet.
- 🎨 **[Themes](docs/guide/themes.md):** fourteen looks, from Classic to
  Digital rain, light and dark.
- 👥 **[Several accounts](docs/guide/getting-started.md#several-accounts-on-one-device)**
  on one device, hidden ones included, and account recovery through trusted
  friends or a paper backup.
- ⚙️ **[Settings, public peers](docs/guide/settings-and-peers.md)** and
  **[self-updates](docs/guide/updates.md)**, *Why isn't it working?*
  diagnostics, and **21 languages**.

## Platforms

| System | Builds | Notes |
|---|---|---|
| Android | `Zen.apk` (arm64-v8a, armeabi-v7a, x86_64) | full feature set, background receiving while locked |
| iPhone | `Zen-unsigned.ipa` (iOS 15+) | sideloaded; receives only while open |
| Windows | `Zen-Windows.zip` (x64), `Zen-Windows-arm64.zip` | |
| Linux | `.tar.gz`, `.deb` (x64, arm64), `.flatpak` (x64) | |
| macOS | `Zen-macOS.zip` (12+, Apple Silicon and Intel) | |

One account can run on several devices. Everything is on
[GitHub Releases](https://github.com/robertostrowskijagoda/Zen/releases/latest).

## How to install

### Android

1. On your phone open this page and tap **Download for Android**.
2. When the file has downloaded, tap it (or open **Downloads**).
3. The phone will ask whether to allow the browser to install apps — tap
   **Settings**, turn on **Allow from this source** and go back.
4. Tap **Install**. If a warning about an unknown app appears,
   choose **More details → Install anyway** (this is normal outside a store).
5. Open Zen and set a password.

One universal `Zen.apk` covers 64-bit phones (arm64-v8a), older 32-bit phones
(armeabi-v7a) and x86_64 devices (Chromebooks, emulators).

**From 2027** Google requires apps from outside the store to come from verified
developers. If your phone says the developer is not verified:

1. **Settings → About phone** → tap **Build number** 7 times
   (this turns on Developer options).
2. **Settings → System → Developer options** → turn on **Apps from
   unverified developers** and confirm with your screen lock.
3. Restart the phone and **wait 24 hours** (this is Google's protection
   against scammers who push people into a quick installation).
4. Go back to the same option, choose **permanently** and install Zen as above.

Option names may differ a little depending on the phone. You do this once.

### Windows

Download **Zen-Windows.zip**, unpack it and run `zen.exe`. If Windows shows
"Windows protected your PC", click **More info → Run anyway**.

On a Windows ARM computer (Surface Pro X, Copilot+ PCs) you can also use the
experimental native build
[Zen-Windows-arm64.zip](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Windows-arm64.zip);
the x64 build runs there too, under emulation.

### iPhone

Zen also runs on iPhone. It isn't in the App Store (that needs a paid Apple account), so you install it yourself — for free, with your own Apple ID.

**1. Download** [Zen-unsigned.ipa](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-unsigned.ipa) from [Releases](https://github.com/robertostrowskijagoda/Zen/releases/latest). The file is not signed — the installer signs it.

**2. Install in one of these ways:**

- **SideStore (recommended)** — with a free Apple ID, then everything on the phone.
  1. Once, on a Windows computer: connect the iPhone with a cable and install SideStore with **iloader** (you sign in with your Apple ID).
  2. On the iPhone install **LocalDevVPN** from the App Store and turn it on — SideStore needs it to install and refresh.
  3. In SideStore: **My Apps → +** and choose `Zen-unsigned.ipa`.
  4. If the iPhone asks: **Settings → General → VPN & Device Management** → trust your Apple ID, and from iOS 16 turn on **Developer Mode** (Settings → Privacy & Security).
- **AltStore Classic** — with a computer: install **AltServer** on Windows (with iTunes and iCloud from Apple's site, not the Microsoft Store), use it to put AltStore on the iPhone, and then in AltStore: **My Apps → +** → `Zen-unsigned.ipa`.

**Remember:**
- Apps from a free Apple ID work for **7 days** — once a week refresh Zen in SideStore/AltStore (**Refresh All**). Your data stays.
- A free account allows at most **3** such apps at a time (SideStore or AltStore counts too).
- New version: download the new `Zen-unsigned.ipa` and install it the same way — your data stays.

**What Zen can't do on iPhone** (iOS doesn't allow it):
- it doesn't run in the background — messages and calls arrive only while Zen is open; there are no push notifications,
- "People nearby" (Bluetooth presence) is Android-only; offline links with friends use Apple's Multipeer while Zen is open,
- it has to be refreshed every 7 days.

**Won't work or not recommended:**
- **TrollStore** — only iOS up to 17.0,
- **AltStore PAL** and installing from a web page — they require a developer with a paid account,
- "signers" using enterprise certificates — Apple revokes them regularly, and you hand your app to strangers. **Don't use them.**

### Mac, Linux

New — the Linux and Mac builds are made by GitHub Actions together with the
other release files; they are not signed and have not yet been checked on many
real computers, so they may have bugs.

**Linux:** download [Zen-Linux-x64.tar.gz](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-x64.tar.gz)
(or [Zen-Linux-arm64.tar.gz](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-arm64.tar.gz)
for Raspberry Pi 4/5 and other ARM computers with a 64-bit system), unpack it
and run `Zen/zen`; `Zen/install-desktop-entry.sh` adds Zen to the menu
and makes it open `zen://` links. On Debian, Ubuntu and Mint it is simpler:
[Zen-Linux-x64.deb](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-x64.deb)
(or `Zen-Linux-arm64.deb`) and `sudo apt install ./Zen-Linux-x64.deb`. For x64
there is also a Flatpak,
[Zen-Linux-x64.flatpak](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-x64.flatpak)
(`flatpak install --user ./Zen-Linux-x64.flatpak`; not on Flathub).
Needed: GNOME Keyring or KWallet (the encryption key lives there), for the tray
icon `libayatana-appindicator3-1`, and for voice notes and videos GStreamer
with plugins (`gstreamer1.0-plugins-good`, `gstreamer1.0-libav`).

**Mac** (macOS 12 or newer, Apple Silicon and Intel): download
[Zen-macOS.zip](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-macOS.zip),
unpack it and move `Zen.app` to Applications. On first launch macOS will say it
can't verify the developer: **System Settings → Privacy & Security → Open
Anyway** (or in Terminal
`xattr -dr com.apple.quarantine /Applications/Zen.app`). After an update macOS
may ask for keychain access — choose **Always Allow**.

On a computer there is no "People nearby" (Bluetooth presence), call
recording or camera. Offline links (Wi-Fi Direct on Windows, Bluetooth) work.

### From a friend

Someone already has Zen? In the app: **Invite → Friend doesn't have Zen?** — it will send you the app
over Quick Share, Bluetooth or Wi-Fi, even without internet.

## Isn't it a virus? How to check

1. **Download from one place** — only from this page (the address must start with
   `github.com/robertostrowskijagoda/`) or from a friend who has Zen.
2. **Check the file for free** — before installing, upload it to
   [virustotal.com](https://www.virustotal.com): dozens of antivirus programs
   will check it at once.
3. **The phone checks too** — Android scans the app on installation.
4. **The code is open** — anyone can review what Zen does. Every official release
   is signed with the same key, so the phone won't install a fake "over"
   the real Zen. The key fingerprint (SHA-256):

   ```
   (will appear with the first signed release)
   ```

## Why Zen is not on Google Play or the App Store

- **Independence.** A store can remove an app or demand changes at any time.
  Zen is meant to be independent — also of big companies and of politics.
- **No fees, no rework.** Stores demand fees (the App Store — every year),
  agreement to their rules and a separate version of the app (without "Pass it on"
  and updates from friends), while Zen is made by one person, for free. A version
  for the stores is planned (`docs/RELEASES.md`, point 6); the `appStoreOnly` flavor
  for Google Play and Galaxy Store can already be built.
- **Privacy.** Nobody, not even a store, knows you have Zen.

## Privacy and security

- **No account, no phone number.** Your QR code is your address. Several
  accounts can live on one device, and an account you keep off the list
  can't be seen by anyone who picks the device up.
- **Encryption, honestly:** see [Post-quantum](#post-quantum) above and the
  [security model](docs/SECURITY_MODEL.md) for the threat model, the
  classical exceptions and the limits.
- **On the device** everything is encrypted with your password (AES-256-GCM,
  Argon2id), biometric unlock uses keys held by the security hardware, and
  sensitive screens (like the wallet) are protected from screenshots. Zen
  detects debuggers and hooking tools and then refuses to move money.
- **Locked phone.** On Android the background service works without your
  password: it holds a separate background key and only small kits (alarm,
  Nearby, doors); what arrives while locked is stored sealed until you
  unlock.
- **You decide who sees what:** friendship levels and per-field profile
  visibility control who sees your friend list, statuses and posts, and who
  may invite you to groups.
- **Files from others are checked:** every photo is unpacked and saved again
  before it is shown; a video or recording must really be one; Zen never
  opens files by itself and warns before saving a program.
- **GIFs go through an outside company**, KLIPY: it sees what you search for
  and your IP address (also when you open a GIF a friend sent). Don't use
  GIFs if you mind that.
- **Location** comes from the system's own service (never Google Play
  services) and goes only where a feature says (an alarm, a date-safety
  request).
- **Updates:** Zen asks GitHub for the newest release 20 seconds after start
  and every 12 hours (GitHub sees your IP address), and checks a download
  against `SHA256SUMS` and, on Android, Zen's signing certificate
  ([details](docs/guide/updates.md)).
- The legal texts: [privacy policy](docs/PRIVACY.md) and
  [terms of use](docs/TERMS.md). Zen asks no one for their age, except the
  pyramid, which asks for the birth year at entry.

Found a vulnerability? Please report it privately: [SECURITY.md](SECURITY.md).

## What it runs on

Zen has no servers of its own. Devices connect through
[**Yggdrasil**](https://yggdrasil-network.github.io/) — an open, encrypted mesh network
in which every device has its own address and traffic goes directly or through other
devices that don't see the content. Zen adds its own (post-quantum) encryption on top.
Those devices (including the public nodes Zen starts from) do see
your IP address and your address in the network, that is, your invitation code — they
don't see what you write. On top of that, the GIF search uses an outside company,
KLIPY (above). The libraries Zen is built on: [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).
The app is written in Flutter (Android, iPhone, Windows, Linux, macOS),
and the network bridge in Go. The texts come in 21 languages; the language is chosen
automatically or in Settings → Language.

### Your own bridge (for advanced users)

Zen on a computer helps others connect by itself when the router allows it. You can
also set up a permanent bridge without Zen — an ordinary Yggdrasil node that runs
around the clock and helps everyone (it can't see the content of messages):

1. A computer that is always on and has a public IP address: a VPS server or a home
   computer / Raspberry Pi with a port forwarded in the router.
2. Install Yggdrasil following the
   [instructions on the project's site](https://yggdrasil-network.github.io/installation.html)
   (Linux, Windows, macOS, routers). The config file is created by `yggdrasil -genconf`.
3. In the [configuration](https://yggdrasil-network.github.io/configuration.html)
   put e.g. `tls://0.0.0.0:443` in `Listen`, and a few public nodes in `Peers`.
   Restart the service and open that port in the firewall.
4. Add your node to the
   [list of public nodes](https://github.com/yggdrasil-network/public-peers)
   (pull request). Zen takes its nodes from that list, so later versions of Zen will
   connect through your bridge too.

### Building from source

You always need [Flutter](https://docs.flutter.dev/get-started/install)
3.47.1 and [Go](https://go.dev/dl/) in the version from `native/yggdrasil_bridge/go.mod`.
The Go network bridge builds itself on `flutter build` and `flutter run` — only
when its sources changed (details: `docs/RELEASES.md`, point 3.1).

| System | You need | Command |
|---|---|---|
| Android (one APK: arm64-v8a, armeabi-v7a, x86_64) | Android Studio (SDK and NDK), JDK 17 | `flutter build apk --release` |
| Android for a store only (Google Play, Galaxy Store; no self-update; app name "Zen", only About says "Wersja ze sklepu"; the build writes `Zen-APP-STORE-ONLY-do-not-install-manually.aab` and `.apk` to `build/app/outputs/app-store-only/`; never install this build by hand) | as above | `flutter build appbundle --release --flavor appStoreOnly` |
| Windows | Visual Studio 2022 ("Desktop development with C++"), gcc for Go (e.g. Strawberry Perl) | `flutter build windows --release` |
| Windows on ARM (on an ARM64 computer) | as above, with ARM64 tools; for Go [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) instead of gcc | `flutter build windows --release` |
| Linux | packages below | `flutter build linux --release` |
| macOS | Xcode with command line tools, CocoaPods | `flutter build macos --release` |
| iPhone (on a Mac) | Xcode, CocoaPods | `flutter build ios --release --no-codesign` |

**Linux** (Ubuntu, Debian):

```
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev libsecret-1-dev libayatana-appindicator3-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

The finished Zen is in `build/linux/x64/release/bundle/` (the `zen` file with the folders
`lib/` and `data/`; on ARM64 `build/linux/arm64/…`). The `.deb` package is made by
`linux/packaging/build_deb.sh`, the Flatpak by `linux/packaging/com.roj.zen.yml`
(see `docs/RELEASES.md`). To work it needs a key service (GNOME Keyring or
KWallet — the encryption key lives there), for the tray icon
`libayatana-appindicator3-1` (in GNOME also the AppIndicator extensions) and for
playback GStreamer with plugins.

**macOS:** the app is `build/macos/Build/Products/Release/Zen.app` (Apple
Silicon and Intel, macOS 12 or newer). It is not sandboxed (App Sandbox) —
it runs system tools, e.g. `route` and `adb`; the reason is described
in `macos/Runner/Release.entitlements`.

## Documentation

| | |
|---|---|
| [User guide](docs/guide/README.md) | how every part of Zen works, with pictures |
| [Security model](docs/SECURITY_MODEL.md) | threats, encryption, post-quantum and classical parts, hardening, limits |
| [Dependencies](docs/DEPENDENCIES.md) | libraries, platform APIs and their licences |
| [Protocol](docs/PROTOCOL.md) | frames and records on the wire |
| [Releases](docs/RELEASES.md) | signing, publishing, distribution |
| [Testing](docs/TESTING.md) | the simulator, several clients, visual tours, CI |
| [SECURITY.md](SECURITY.md) | reporting a vulnerability |
| [CHANGELOG.md](CHANGELOG.md) | history of changes |

## Support Zen

Zen is free and ad-free — it is kept going only by voluntary donations.
It is made by one person, with no company and no investors.

**[☕ Buy me a coffee at buycoffee.to/zen](https://buycoffee.to/zen)** — this is the only
official Zen fundraiser; the same link is in the app (About → Support Zen).
Donations are voluntary gifts and buy no rights or features. Copies of Zen
must keep this link with the author's name ([NOTICE](NOTICE), section 1).

### About the author

My name is Robert Ostrowski-Jagoda and I'm a programmer. At the moment I'm writing this,
I'm working as a taxi driver, because there was no work for me. I made this app
for free, but I also want to have a house and a Lamborghini — please, throw me at least
$5. There are no ads in the app, it's free, and I don't earn anything from it directly.
If you have a job for me, let me know — you can find me on LinkedIn, among other places.

## License

Zen is free software under the [GNU General Public License v3.0](LICENSE)
(`SPDX-License-Identifier: GPL-3.0-only`) with additional terms under GPL
section 7 in [NOTICE](NOTICE). Copyright © 2026 Robert Ostrowski-Jagoda; the
copyright stays with the author. In short:

| You may | If you share Zen or a modified version, you must |
|---|---|
| use Zen for any purpose, privately or in a company, on any number of devices | make the source code available, under the same GPL-3.0 terms, to everyone you give a copy or a modified version to |
| read, study, change and build the code | keep "Zen by Robert Ostrowski-Jagoda" and the donation link [buycoffee.to/zen](https://buycoffee.to/zen) in the About screen (a modified version may replace the link only with a marked note pointing to the original author's page) |
| share copies, also modified ones, also for a fee | mark a modified version as changed and never present it as the original or an official release |
| | give a modified version a different name and icon ("Zen" and the logo are not licensed) |

Because the license is approved by both the FSF and the OSI, Zen can also be
distributed through F-Droid and IzzyOnDroid (not set up yet;
[docs/RELEASES.md](docs/RELEASES.md), section 6.1). Builds that such
repositories make from the unchanged source of a release may keep the name and
icon (NOTICE, 3.3). The full license text is in [LICENSE](LICENSE); libraries
keep their own licenses (in the app: About → Licenses; list of components in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), what each is used for in
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)).

**F-Droid readiness:** the license fits, Zen uses no Google Play services and no
tracker, and the Go bridge builds from source. Still missing: a build recipe
(Flutter + Go) and a build with the GitHub self-update switched off.
