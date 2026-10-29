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
  <a href="https://github.com/robertostrowskijagoda/Zen/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/robertostrowskijagoda/Zen/release.yml?label=release%20build&event=push&logo=githubactions&logoColor=white" alt="Release build status"></a>
  <a href="https://github.com/robertostrowskijagoda/Zen/releases/latest"><img src="https://img.shields.io/github/v/release/robertostrowskijagoda/Zen?include_prereleases&sort=semver&label=latest%20release" alt="Latest release"></a>
  <a href="https://github.com/robertostrowskijagoda/Zen/releases"><img src="https://img.shields.io/github/downloads/robertostrowskijagoda/Zen/total?label=downloads" alt="Downloads"></a>
  <a href="https://github.com/robertostrowskijagoda/Zen/commits/main"><img src="https://img.shields.io/github/last-commit/robertostrowskijagoda/Zen?label=last%20commit" alt="Last commit"></a>
  <br>
  <a href="docs/SECURITY_MODEL.md"><img src="https://img.shields.io/badge/post--quantum-ML--KEM--768%20%2B%20ML--DSA--65-6d28d9" alt="Post-quantum: ML-KEM-768 and ML-DSA-65"></a>
  <a href="#install"><img src="https://img.shields.io/badge/platforms-Android%20%C2%B7%20iOS%20%C2%B7%20Windows%20%C2%B7%20macOS%20%C2%B7%20Linux-0f766e" alt="Platforms: Android, iOS, Windows, macOS, Linux"></a>
  <a href="docs/BUILDING.md"><img src="https://img.shields.io/badge/Flutter-3.47.1-02569B?logo=flutter&logoColor=white" alt="Flutter 3.47.1"></a>
  <a href="native/yggdrasil_bridge/go.mod"><img src="https://img.shields.io/github/go-mod/go-version/robertostrowskijagoda/Zen?filename=native%2Fyggdrasil_bridge%2Fgo.mod&logo=go&logoColor=white&label=Go" alt="Go version"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-GPL--3.0--only-blue" alt="License: GPL-3.0-only"></a>
</p>

<p align="center">
  <a href="https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-arm64-v8a.apk"><b>⬇ Android</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Windows.zip"><b>⬇ Windows</b></a>
  &nbsp;·&nbsp;
  <a href="https://robertostrowskijagoda.github.io/Zen/install/iphone/"><b>📱 iPhone</b></a>
  &nbsp;·&nbsp;
  <a href="https://robertostrowskijagoda.github.io/Zen/install/macos/"><b>💻 Mac</b></a>
  &nbsp;·&nbsp;
  <a href="https://robertostrowskijagoda.github.io/Zen/install/linux/"><b>🐧 Linux</b></a>
  &nbsp;·&nbsp;
  <a href="docs/guide/README.md"><b>📖 User guide</b></a>
  &nbsp;·&nbsp;
  <a href="https://discord.gg/g4vHvpKV37"><b>💬 Discord</b></a>
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

<p align="center"><a href="https://robertostrowskijagoda.github.io/Zen/features/">More pictures and every feature on the website</a></p>

> **Did someone show you a QR code?** The code opens an invitation page: if you
> have Zen, the page opens it right away with the invitation; if you don't, it
> shows the download buttons. After installing, come back to that page and tap
> **Open in Zen** (or in Zen: **Settings → Invite → I have someone's code**
> and scan the code again).
>
> **Already have Zen on Android?** Turn this on once in Zen: **Settings → Invite
> → Zen codes straight into the app → Open supported links**. From then on a code scanned
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

**Post-quantum.** Traffic recorded today could be decrypted once quantum
computers can break today's public-key cryptography. Zen's key exchanges are
hybrid **ML-KEM-768 + X25519** and its lasting signatures hybrid
**Ed25519 + ML-DSA-65** (NIST FIPS 203 and 204): every signal between two
devices, offline mailboxes, device identity, everything signed and kept, and
the relay layer around calls. A hybrid stays safe as long as either half
holds. A few parts stay classical (the Yggdrasil node key and address, the
ring signature that registers a voting card, local link pair secrets until
two devices first meet over the mesh, the AES key inside call frames); what
is protected how, and why the rest is not:
[security model](docs/SECURITY_MODEL.md).

Using Zen to break the law is forbidden by the [Terms of use](docs/TERMS.md).

## What it can do

- 💬 **[Chats and calls](docs/guide/chats-and-delivery.md):** one-to-one
  and group chats with photos, videos, files, voice notes and GIFs,
  reactions, replies, editing, forwarding and delete for everyone; a board
  for every group; audio and video calls with screen sharing. Messages for
  offline friends wait sealed in their friends' mailboxes, and the icons
  tell you exactly where a message is.
- 🕸️ **[Friends and the graph](docs/guide/friends-and-graph.md):** friendship
  levels that decide who sees what, and a graph of who knows whom with a
  timeline and *who's worth meeting*.
- 📰 **[Feed and videos](docs/guide/feed-and-videos.md):** posts only for the
  people you choose, and a short-video section, ordered on your own phone.
- 🍲 **[Meeting people](docs/guide/meeting-people.md):** *right now*
  statuses, events with offline tickets, dinner circles, sharing food,
  people nearby over Bluetooth, and an **alarm** that works from a locked
  Android phone.
- 🚪 **[Neighbours](docs/guide/neighbours.md):** a QR code on your door; a
  knock rings every phone of the household.
- ❤️ **[Dating](docs/guide/dating.md):** through friends, up to three steps
  away, with a private match test.
- 🔺 **[The pyramid](docs/guide/pyramid.md):** cells of three, anonymous cell
  votes, referendums, a court with appeals and a common wallet.
- 🚦 **[Introductions and gates](docs/guide/introductions-and-gates.md):**
  reach people further away through friends.
- 📡 **[Offline links](docs/guide/offline-links.md):** same Wi-Fi, Wi-Fi
  Direct and Bluetooth: Zen without the internet.
- 🎨 **[Themes](docs/guide/themes.md):** 27 looks, each light and dark.
- 👥 **[Several accounts](docs/guide/getting-started.md#several-accounts-on-one-device)**
  on one device, hidden ones included, and several ways to get an account
  back: a second device, an encrypted account copy, a key copy, or a
  recovery circle of 4 to 6 friends.
- ⚙️ **[Settings, public peers](docs/guide/settings-and-peers.md)**,
  **[self-updates](docs/guide/updates.md)**, *Why isn't it working?*
  diagnostics, and **21 languages**.

## Install

| System | File | Step by step |
|---|---|---|
| Android | [Zen-arm64-v8a.apk](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-arm64-v8a.apk) (most phones; also `armeabi-v7a`, `x86_64`, or [Obtainium](https://obtainium.imranr.dev/)) | [install page](https://robertostrowskijagoda.github.io/Zen/install/android/) |
| iPhone (iOS 15+) | through [SideStore](https://sidestore.io/), source `https://robertostrowskijagoda.github.io/Zen/apps.json` | [install page](https://robertostrowskijagoda.github.io/Zen/install/iphone/) |
| Windows | [Zen-Windows.zip](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Windows.zip) (x64; also ARM64) | [install page](https://robertostrowskijagoda.github.io/Zen/install/windows/) |
| Mac (12+) | [Zen-macOS.zip](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-macOS.zip) (Apple Silicon and Intel) | [install page](https://robertostrowskijagoda.github.io/Zen/install/macos/) |
| Linux | [Zen-Linux-x64.deb](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-x64.deb) (Ubuntu 22.04+, Debian 12+, Mint 21+; also arm64, `.tar.gz`, Flatpak) | [install page](https://robertostrowskijagoda.github.io/Zen/install/linux/) |

**[The install page](https://robertostrowskijagoda.github.io/Zen/install/)**
picks your system by itself (21 languages). Every file, what to click past
the system's warnings, what Zen can and cannot do on each system, battery
use and why Zen is not in the stores: **[Installing Zen](docs/INSTALL.md)**.
Someone already has Zen? **Settings → Invite → Friend doesn't have Zen?**
sends you the app over Quick Share, Bluetooth or Wi-Fi, even without
internet. Everything is on
[GitHub Releases](https://github.com/robertostrowskijagoda/Zen/releases/latest).

## Isn't it a virus? How to check

1. **Download from one place** — only from this page (the address must start with
   `github.com/robertostrowskijagoda/`; in Zen: **Settings → Zen on GitHub**)
   or from a friend who has Zen.
2. **Check the file for free** — before installing, upload it to
   [virustotal.com](https://www.virustotal.com): dozens of antivirus programs
   will check it at once.
3. **The phone checks too** — Android scans the app on installation.
4. **The code is open** — anyone can review what Zen does. Every official release
   is signed with the same key, so the phone won't install a fake "over"
   the real Zen. The key fingerprint (SHA-256):

   ```
   5C:F8:4B:A5:25:AC:80:4C:84:2F:B5:B9:2F:35:C5:49:F6:C0:7A:84:FB:E0:C2:80:49:13:91:91:C1:EE:F5:14
   ```

## Privacy and security

- **No account, no phone number.** Your QR code is your address; nobody in
  the middle keeps your friends, messages or posts.
- **On the device** everything is encrypted with your password (AES-256-GCM,
  Argon2id); an emergency wipe password erases the data, and an account
  kept off the list can't be seen by anyone who picks the device up.
- **You decide who sees what:** friendship levels and per-field profile
  visibility.
- **GIF search goes through an outside company**, KLIPY: it sees what you
  search for, the GIF you pick and your IP address (your friend never
  contacts it). **Settings → Messages and calls → GIFs** turns it off.
- **Updates:** Zen asks GitHub for the newest release (GitHub sees your IP
  address) and checks a download against `SHA256SUMS` and, on Android, Zen's
  signing certificate ([details](docs/guide/updates.md)).
- **What runs it:** devices connect through
  [Yggdrasil](https://yggdrasil-network.github.io/), an open, encrypted mesh
  network; the devices on the way (the public nodes Zen starts from
  included) see your IP address and your network address, never what you
  write. Running a bridge of your own:
  [settings and public peers](docs/guide/settings-and-peers.md#your-own-bridge-for-advanced-users).

The details: [security model](docs/SECURITY_MODEL.md) (threats, encryption,
the locked phone, files from others, honest limits),
[privacy policy](docs/PRIVACY.md) and [terms of use](docs/TERMS.md). Found a
vulnerability? Please report it privately: [SECURITY.md](SECURITY.md).

## Documentation

All of it, in reading order: **[docs/README.md](docs/README.md)**.

| | |
|---|---|
| [User guide](docs/guide/README.md) | how every part of Zen works, with pictures |
| [Installing Zen](docs/INSTALL.md) | every system, every file, the warnings to click past |
| [Privacy policy](docs/PRIVACY.md), [terms of use](docs/TERMS.md) | what Zen does with data, and the rules |
| [Security model](docs/SECURITY_MODEL.md) | threats, encryption, post-quantum and classical parts, limits |
| [Protocol](docs/PROTOCOL.md) | frames and records on the wire |
| [Building from source](docs/BUILDING.md), [testing](docs/TESTING.md), [releases](docs/RELEASES.md) | for developers and packagers |
| [CHANGELOG.md](CHANGELOG.md) | history of changes |

## Contributing

Bug reports, translations and code are welcome: read
[CONTRIBUTING.md](CONTRIBUTING.md) (the checks CI runs, and the contributor
licence grant), then [build Zen from source](docs/BUILDING.md). Bugs and
feature requests go to [GitHub Issues](https://github.com/robertostrowskijagoda/Zen/issues);
vulnerabilities privately, as in [SECURITY.md](SECURITY.md).

## Community

Questions, help with installing, ideas, or just talk with other people who
use Zen: **[Zen on Discord](https://discord.gg/g4vHvpKV37)**.

## Support Zen

Zen is free and ad-free — it is kept going only by voluntary donations.
It is made by one person, with no company and no investors.

**[☕ Buy me a coffee at buycoffee.to/zen](https://buycoffee.to/zen)** — this is the only
official Zen fundraiser; the same link is in the app (About → Support Zen).
Donations are voluntary gifts and buy no rights or features. The license
does not force anyone to keep this link; a modified version must only not
show any other address as a way to support the author ([NOTICE](NOTICE),
section 2).

### About the author

My name is Robert Ostrowski-Jagoda and I'm a programmer. At the moment I'm writing this,
I'm working as a taxi driver, because there was no work for me. I made this app
for free, but I also want to have a house and a Lamborghini — please, throw me at least
$5. There are no ads in the app, it's free, and I don't earn anything from it directly.
If you have a job for me, let me know — you can find me on LinkedIn, among other places.

## Thanks

Thanks to **[Yggdrasil](https://yggdrasil-network.github.io/)**, the open,
encrypted mesh network Zen runs on, and **[SideStore](https://sidestore.io/)**,
which installs Zen on an iPhone and keeps it renewed right on the phone.

## License

Zen is free software under the [GNU General Public License v3.0](LICENSE)
(`SPDX-License-Identifier: GPL-3.0-only`) with additional terms under GPL
section 7 in [NOTICE](NOTICE). Copyright © 2026 Robert Ostrowski-Jagoda; the
copyright stays with the author. In short:

| You may | If you share Zen or a modified version, you must |
|---|---|
| use Zen for any purpose, privately or in a company, on any number of devices | make the source code available, under the same GPL-3.0 terms, to everyone you give a copy or a modified version to |
| read, study, change and build the code | keep the author attribution "Zen by Robert Ostrowski-Jagoda" (in a modified version: "Based on Zen by Robert Ostrowski-Jagoda") among the legal notices in the About screen |
| share copies, also modified ones, also for a fee | mark a modified version as modified and never present it as the original, an official release or endorsed by the author |
| | give a modified version a name and icon that are clearly different from Zen's and another Android application ID (the license grants no trademark rights to the name "Zen" or the logo) |

The additional terms are only of the kinds section 7 of the GPL allows
(author attribution, marking modified versions, no trademark rights). The
donation link is **not** a condition: unmodified copies show it because it
is part of the app, and a modified version may keep, change or remove it,
but must not show any other address as a way to support the author
(NOTICE, section 2). Builds that software repositories and distributions
(F-Droid, IzzyOnDroid, Flathub, Linux distributions) make from the source
of a release, changed only to build, package and meet their policies, may
keep the name and icon (NOTICE, section 5). The full license text is in
[LICENSE](LICENSE); libraries keep their own licenses (in the app: About →
Licenses and thanks → Licenses; list of components in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), what each is used for in
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)). Contributions are accepted
under the contributor licence grant in [CONTRIBUTING.md](CONTRIBUTING.md),
which does not change the license anyone receives Zen under.
