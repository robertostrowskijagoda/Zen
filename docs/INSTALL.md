# Installing Zen

The **[install page](https://robertostrowskijagoda.github.io/Zen/install/)**
picks your system by itself and walks through it with pictures, in 21
languages. This page has the same steps in one place, which file is for
which device, and what to expect on each system. Before installing, you can
check a download: [Isn't it a virus? How to check](../README.md#isnt-it-a-virus-how-to-check).

## Platforms

| System | Builds | Notes |
|---|---|---|
| Android | `Zen-arm64-v8a.apk` (most phones), `Zen-armeabi-v7a.apk` (older 32-bit phones), `Zen-x86_64.apk` (Chromebooks, emulators) | full feature set, background receiving while locked |
| iPhone | `Zen-unsigned.ipa` (iOS 15+) | sideloaded; receives while open, in the background only now and then |
| Windows | `Zen-Windows.zip` (x64), `Zen-Windows-arm64.zip` | the Visual C++ runtime is inside the ZIP |
| Linux | `.tar.gz`, `.deb` (x64, arm64), `.flatpak` (x64) | Ubuntu 22.04+, Debian 12+, Mint 21+ (glibc 2.35+); other systems: Flatpak |
| macOS | `Zen-macOS.zip` (12+, Apple Silicon and Intel) | |

One account can run on several devices. Everything is on
[GitHub Releases](https://github.com/robertostrowskijagoda/Zen/releases/latest)
(in Zen: **Settings → Zen on GitHub**).

**Battery.** There is no push server, so a phone keeps its own few links to
the network. To keep that cheap, an Android phone keeps 4 links to public
peers (swapped when one stops answering), sends presence pings only to
friends and only while Zen is on the screen, and **after 5 minutes in the
background only receives** (no pings, scans or sync), with or without the
lock, though it still holds friends' mail as one of their mailboxes; it
wakes for short, timed moments instead of holding the processor or
Wi-Fi awake. While the phone sleeps (Doze), mail from mailboxes can come a
few minutes late. A computer on battery stops being a bridge for others and
keeps only 4 public peers; plugged in, everything comes back. Animations
run at a low frame rate and stop when the window is not visible; a setting
(Appearance → Animations) can also make them follow the system's reduce-motion
flag or turn them off.

## How to install

One recommended way for each system, with its own page that has numbered
steps, pictures, the download and what to do when something goes wrong (in 21
languages): **[the install page](https://robertostrowskijagoda.github.io/Zen/install/)** picks your system by itself.
In Zen: **Settings → Invite → Friend doesn't have Zen? → How to install Zen
on another phone / computer** shows a QR code to that page. Every download
link uses `releases/latest/download/<file>`, so it follows each new release.

### Android

**[Step by step](https://robertostrowskijagoda.github.io/Zen/install/android/)**: download
[Zen-arm64-v8a.apk](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-arm64-v8a.apk) (the file for almost every phone),
open it, allow your browser to install apps once (**Allow from this source**)
and tap **Install**; if Play Protect warns about an unknown app, choose **More
details → Install anyway**. Zen then updates itself.

Other ways: [Zen-armeabi-v7a.apk](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-armeabi-v7a.apk) for older 32-bit
phones (also the one to try when the first file says "App not installed"),
[Zen-x86_64.apk](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-x86_64.apk) for Chromebooks and emulators, or
[Obtainium](https://obtainium.imranr.dev/) (add
`https://github.com/robertostrowskijagoda/Zen`; one tap on the install page).

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

### iPhone

**[Step by step, with pictures](https://robertostrowskijagoda.github.io/Zen/install/iphone/)**:
**[SideStore](https://sidestore.io/)** installs Zen with your own Apple
Account (a free one is enough). You need a computer and a cable once, Wi-Fi,
a passcode on the iPhone and iOS 15 or later; about 15 minutes.

1. On the iPhone install **LocalDevVPN** from the App Store, open it and tap
   **Connect**. SideStore needs this VPN on whenever it installs or renews apps.
2. On the computer install **iloader**
   ([SideStore's guide](https://docs.sidestore.io/docs/installation/prerequisites)),
   connect the iPhone by cable, sign in with your Apple Account and choose
   **Install SideStore (Stable)**.
3. On the iPhone: **Settings → General → VPN & Device Management** → your
   Apple Account → trust it; on iOS 16 and later also **Settings → Privacy &
   Security → Developer Mode**.
4. Open SideStore (LocalDevVPN connected), sign in with the same Apple Account
   and tap the **7 DAYS** counter next to SideStore in **My Apps**.
5. Add Zen's source (**Add Zen to SideStore** on the install page, or in
   SideStore **Sources → +**:
   `https://robertostrowskijagoda.github.io/Zen/apps.json`) and install Zen
   from it.
6. Let it renew by itself: in the Shortcuts app make a daily **Time of Day**
   automation that runs immediately, with **Set VPN** (connect LocalDevVPN)
   and SideStore's **Refresh All Apps**. An app signed with a free Apple
   Account opens for 7 days; SideStore renews it on the phone, no computer
   needed.
7. New versions: Zen tells you, and its update button hands the new version
   to SideStore (or **My Apps → Update** next to Zen).

With a free Apple Account at most 3 apps from SideStore run at a time,
SideStore included. If the 7 days run out, Zen only stops opening until it is
renewed (LocalDevVPN on, tap the counter in SideStore); its data stays. After
an iOS update SideStore may need a new pairing file
([guide](https://docs.sidestore.io/docs/advanced/pairing-file)). The source
always points to the latest release's
[Zen-unsigned.ipa](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-unsigned.ipa).
Other ways: **AltStore Classic** (the same source; it renews through AltServer
on a computer) and Sideloadly (from a computer).

**What Zen can't do on iPhone** (iOS doesn't allow it): it doesn't run in
the background for long. Messages and calls arrive while Zen is open, and
otherwise only when iOS wakes Zen for a short check now and then (no push
notifications); until then they wait with the sender or in the mailboxes
your friends' devices keep for you. Settings → Notifications and sounds →
Background work can keep Zen
receiving all the time, at a clear battery cost; see
[iPhone: receiving in the background](IOS_BACKGROUND.md). It works best when one friend has Zen on a computer (in
the tray) or on Android: that device keeps the mail for the whole group of
friends while the iPhones sleep. There is no Nearby (offline links with
friends use Apple's Multipeer while Zen is open).

**Won't work:** AltStore PAL (EU) installs only apps notarized by Apple
(Zen isn't there yet); TrollStore works only up to iOS 17.0; "signers" with
enterprise certificates get revoked and hand your app to strangers —
**don't use them** (use only the install page's link).

### Windows

**[Step by step](https://robertostrowskijagoda.github.io/Zen/install/windows/)**: download [Zen-Windows.zip](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Windows.zip),
unpack the whole ZIP (it holds a folder `Zen`) and run `Zen\zen.exe`. Keep that
folder whole and put nothing else in it: Zen updates itself in place only
there. Nothing else needs installing: the Microsoft Visual C++ runtime Zen
needs is in the folder. If Windows shows "Windows protected your PC", click
**More info → Run anyway**.

If Windows 11 says *Smart App Control blocked an app that may be unsafe*,
there is no *Run anyway*: Zen is not code-signed yet. Either use Zen on
another device, or turn Smart App Control off (**Windows Security → App &
browser control → Smart App Control settings → Off**). That lowers
protection for the whole computer; on Windows 11 before the April 2026
update it can only be turned on again by reinstalling Windows.

An antivirus program may also flag an unsigned new file by mistake: compare
the file's SHA-256 with `SHA256SUMS` of the release (below) and report the
false alarm to the antivirus maker.

On a Windows ARM computer (Surface Pro X, Copilot+ PCs) you can also use the
experimental native build
[Zen-Windows-arm64.zip](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Windows-arm64.zip);
the x64 build runs there too, under emulation.

### Mac

**[Step by step](https://robertostrowskijagoda.github.io/Zen/install/macos/)**: macOS 12 or newer, Apple Silicon and
Intel. Download [Zen-macOS.zip](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-macOS.zip), unpack it and move `Zen.app`
to Applications. On first launch macOS will say it can't verify the developer:
choose **Done**, then **System Settings → Privacy & Security → Open Anyway**,
your password, **Open Anyway** (right-click → Open no longer works since macOS
15; or in Terminal `xattr -dr com.apple.quarantine /Applications/Zen.app`).
After an update macOS may ask for keychain access — choose **Always Allow**.

### Linux

**[Step by step](https://robertostrowskijagoda.github.io/Zen/install/linux/)**: on Debian, Ubuntu and Mint download
[Zen-Linux-x64.deb](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-x64.deb) and run
`sudo apt install ./Zen-Linux-x64.deb` (ARM:
[Zen-Linux-arm64.deb](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-arm64.deb)).

Other ways: for x64 a Flatpak,
[Zen-Linux-x64.flatpak](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-x64.flatpak)
(`flatpak install --user ./Zen-Linux-x64.flatpak`; not on Flathub; it does not
update itself: install the new file the same way when Zen tells you), or
[Zen-Linux-x64.tar.gz](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-x64.tar.gz)
([arm64](https://github.com/robertostrowskijagoda/Zen/releases/latest/download/Zen-Linux-arm64.tar.gz), for Raspberry Pi 4/5 and other 64-bit ARM
computers): unpack it and run `Zen/zen`; `Zen/install-desktop-entry.sh` adds
Zen to the menu and makes it open `zen://` links and Zen's own files.
**Which systems:** the `.tar.gz` and `.deb` run on Ubuntu 22.04, Debian 12,
Linux Mint 21 or newer, and on other distributions with glibc 2.35 or newer
(the builds are made on Ubuntu 22.04 and checked for that); on older
systems use the Flatpak (x64).
Needed: GNOME Keyring or KWallet (the encryption key lives there), for the tray
icon `libayatana-appindicator3-1`, and for voice notes and videos GStreamer
with plugins (`gstreamer1.0-plugins-good`, `gstreamer1.0-libav`).

The Linux and Mac builds are made by GitHub Actions together with the
other release files; they are not signed and have not yet been checked on many
real computers, so they may have bugs.

On a computer the camera works (videos and QR codes), and so does Nearby when
the computer has Bluetooth LE (a Mac only looks around, it cannot be seen).
Calls can be recorded on every system (after everyone in the call is told).
Offline links (Wi-Fi Direct on
Windows, Bluetooth) work. Linux records and shrinks videos with GStreamer and
encoders built into Zen.

### From a friend

Someone already has Zen? In the app: **Settings → Invite → Friend doesn't have
Zen?** — it will send you the app
over Quick Share, Bluetooth or Wi-Fi, even without internet.

## Why Zen is not on Google Play or the App Store

The main reason is the stores' legal rules and policies, which Zen by design
does not meet:

- **Moderation.** Stores require the developer to review reports and remove
  content and accounts (Apple guideline 1.2, Google Play's user-generated
  content policy). Zen has no server and nobody in the middle who could.
- **The pyramid's currency and wallet.** Financial and crypto rules call for a
  company and financial licences.
- **Paid gates.** In-app payments for digital services must go through the
  store's billing, with a 15–30% commission.
- **Dating.** Stores require age verification and a moderation team.
- **Self-updating and background work.** Google Play forbids apps that update
  themselves outside the store, and the App Store heavily restricts
  background execution.
- **Developer identity and paperwork.** Stores publish the developer's
  details and require formalities such as encryption export declarations.

**The cost:** the App Store charges 99 USD a year, Google Play 25 USD once,
and the licences and legal work run into thousands. Zen is made by one person,
for free.

A store can also remove an app or demand changes at any time (independence),
and nobody, not even a store, needs to know you have Zen (privacy).

A store build exists anyway: the `appStoreOnly` flavor for Google Play and
Galaxy Store can already be built. It is the same app with three differences
the stores force: it does not update itself, does not hand its APK to others
(it shares a link instead) and has no launcher disguise. It is not published
yet ([RELEASES.md](RELEASES.md), point 6).

### F-Droid and IzzyOnDroid

Not set up yet ([RELEASES.md](RELEASES.md), section 6.1). The license fits
their rules, and Zen uses no Google Play services, Firebase or other proprietary
libraries and no tracker. Still to do: an F-Droid build recipe (Flutter +
the Go bridge, built as the store variant without the GitHub self-update),
and F-Droid will probably mark the optional GIF search (KLIPY, a
proprietary service) with the "NonFreeNet" anti-feature.
