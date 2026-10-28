# Updates and releases

> Zen checks GitHub for a new version and can update itself. Friends can
> also pass the app to each other, hand to hand.

## How releases are made

The maintainer prepares a version with `dart run tool/release.dart prepare
<version>`: it checks that the release files still match what the app's
updater expects, sets the version in every place, moves the *Unreleased*
notes in the CHANGELOG under the new version, commits and tags. Pushing the
tag starts the **Release** workflow, which first checks that the tag equals
the version in the build: it builds every
file (Android APKs, one per processor type: arm64-v8a, armeabi-v7a and
x86_64; Windows x64 and ARM64, Linux tarballs, `.deb` and Flatpak,
macOS, the unsigned iPhone file), writes `SHA256SUMS` with the checksum of
each, signs that list (`SHA256SUMS.sig`, once the signing key is set up)
and attaches everything to a draft
release, which the maintainer checks and publishes by hand. The Android APKs
are signed with the release key, which only a tag run can use, after the
maintainer approves it. Every build uses exactly the locked package
versions, the Linux files are checked to run on Ubuntu 22.04 and newer, the
Windows ZIPs carry the Visual C++ runtime, and the Android libraries are
aligned for phones with 16 KB memory pages. Details:
[RELEASES.md](../RELEASES.md).

## How Zen updates itself

- Every build except the store build asks GitHub for the latest release
  20 seconds after it starts, when you come back to it and every hour while
  it is open, whenever an hour has passed since the last look. On Android,
  while Zen receives in the background, it also looks every few hours while
  the app is closed. When a friend's Zen is newer than yours, Zen looks at
  once. GitHub sees your IP address and the name "Zen", nothing else.
- When there is a newer version, a quiet notification (once per version)
  and a bar say so, with a few lines about what is new in it. A version
  published after that takes the old notice's place, also when you closed
  the bar of the older one; once you have installed it, the notification
  goes away. What **Update** does depends on the system, and the updates
  card says it before you tap:
  - **Android, Windows, Mac, Linux:** Zen downloads the file for your
    system (on Android the APK for your phone's processor type, on Windows
    the x64 or ARM64 ZIP Zen runs as, on the Mac the universal ZIP for Apple
    Silicon and Intel) and checks it against the release's `SHA256SUMS` and
    the maintainers' signature; on Android also that it is signed with the
    same certificate as the installed app. Then the system installer asks
    (Android; the first time Android asks you to let Zen install apps), or
    a helper swaps the folders after Zen closes and starts the new version
    (Windows, Linux tarball, Mac). Where Zen's folder is not writable
    (Program Files, a Mac app opened straight from Downloads) the file is
    saved to Downloads with the next step: unpack it over the `Zen` folder
    (Windows, Linux), drag Zen to Applications (Mac).
  - **Linux `.deb`:** `/opt/zen` belongs to the package manager, so the
    checked `.deb` is saved to Downloads; open it with the package
    installer or run the `sudo apt install …` line Zen shows.
  - **iPhone and iPad:** an iOS app can't install another, so Zen downloads
    nothing itself; SideStore installs the update. The card shows the
    steps, numbered, in the words of the iPhone install page:
    1. Open LocalDevVPN and tap **Connect**.
    2. Tap **Update in SideStore**: SideStore downloads that version's
       `Zen-unsigned.ipa` (pinned to the announced release) and installs it.
       This is SideStore's documented link `sidestore://install?url=…`.
    3. Don't delete the current Zen first: the new version replaces it.

    Below the steps: with Zen's source in SideStore, **My Apps → Update**
    next to Zen does the same; without SideStore at hand, **Download Zen
    1.x.y** saves the IPA to Files through Safari, and in SideStore **My
    Apps → +** picks it. When SideStore doesn't open, Zen says so and points
    to the download; when the release has no IPA, or no browser opens it,
    the iPhone install page opens instead (its address is copied when that
    fails too); **Open install page** is always there. SideStore (or Safari)
    downloads the file, so Zen's checksum and signature check doesn't apply
    to it.

    Under the steps on the updates screen (and in the iPhone steps of "How
    to install Zen" on an iPhone): **Add Zen source to SideStore**
    (`sidestore://source?url=…`, SideStore's documented link), so SideStore
    itself shows new versions in **My Apps**. **Copy source address** and
    the step by hand are always there: in SideStore open **Sources**, tap
    **+** and paste `https://robertostrowskijagoda.github.io/Zen/apps.json`.
    When SideStore doesn't open, the address is copied.

    An app signed with a free Apple Account opens for 7 days. From two days
    before, a card in Chats says so: turn on LocalDevVPN and tap the day
    counter next to Zen in SideStore's **My Apps** (or **Refresh All**), or
    let a daily Shortcuts automation do it (the iPhone install page, step 6).
- **Flatpak** updates outside the app: the card shows the command
  (`flatpak install --user ./Zen-Linux-x64.flatpak`) and **Open release
  page**; nothing is downloaded inside the sandbox.
- **A release without your system's file** (for example the optional
  Windows ARM64 ZIP) shows **Open release page** instead of **Update**.
- **When GitHub limits requests** (it allows only so many an hour from one
  address), Zen says so and shows when it tries again: as late as GitHub
  asks, otherwise after 15 minutes, then 30, then an hour.
  An unchanged answer costs nothing (Zen sends what it saw last time). If
  the repository has no published release (deleted or blocked), the card
  says so instead of "up to date"; a newer version can still come from a
  friend.
- **A version too old.** Each release can name the oldest Zen it still
  works with, and friends' apps say the same in their hello. When your Zen
  is below that, a red tile above the "new version" bar asks you to update
  to that version or newer. Data written by a newer Zen (for example after
  you went back to an older build) is left untouched, and a bar asks you to
  update to use it.
- Once the maintainers' keys are pinned in the app, an update is installed
  only when `SHA256SUMS.sig` carries their hybrid signature (Ed25519 +
  ML-DSA-65) for this version and file. Until then the update screen says
  that the signature can't be checked yet.
- If github.com cannot be reached at all, Zen tells you, in case someone is
  blocking it.

## The install page and the iPhone source

GitHub Pages serves the **[install page](https://robertostrowskijagoda.github.io/Zen/install/)**
(steps for every system, the downloads, the Android signing certificate
fingerprint; one recommended way and its own page for each system) and
**`apps.json`**, a SideStore / AltStore source (the iPhone page adds it in
step 5, with the address to paste in SideStore's **Sources → +**). Both are
rebuilt by the *Pages* workflow every time a release is published (and once
a day): the source names the latest release's `Zen-unsigned.ipa`, its
version, date, size and checksum, and the permissions read from that very
file. SideStore checks the source, offers the update, and signs the file
with the person's own Apple Account. With a free Apple Account that
signature expires after 7 days: SideStore renews it on the phone whenever
LocalDevVPN is connected (tap the counter in **My Apps**, or a daily
Shortcuts automation with **Set VPN** and **Refresh All Apps**, step 6 of
the iPhone page). Zen shows a reminder in Chats 2 days before the date.

## Pass it on

**Settings → Invite → Friend doesn't have Zen?** (or *Updates and Pass it
on*) sends the app to a friend's phone over Quick Share, Bluetooth or Wi-Fi,
even without internet. **How to install Zen on another phone / computer**
on the same screen shows a QR code to the install page and the steps for
every system, with the SideStore source for an iPhone. Zen also notices when
friends have a newer version and shows a quiet hint.

**Updates from friends** over the network (a friend's device passing a new
version on, with no GitHub) switch on once the maintainers' keys are
published in the app: such an update needs two of three maintainer
signatures. Until then the card in *Updates* says so; GitHub updates work
already.

## Checking a download yourself

1. Download only from `github.com/robertostrowskijagoda/Zen` or from a friend.
2. Compare the file's SHA-256 with `SHA256SUMS` in the release.
3. On Android, compare the signing certificate fingerprint with the one in
   the [README](../../README.md#isnt-it-a-virus-how-to-check). Android itself
   refuses to install a copy with another key over the real Zen.
4. Optionally upload the file to [virustotal.com](https://www.virustotal.com).

## Limits

- The store build (for Google Play and Galaxy Store) is the same app with
  three differences the stores require: it never updates itself, passes Zen
  on only as a link (never as an APK) and has no launcher disguise. Because
  the store signs it, it also skips the check of its own signing
  certificate.
- On iPhone and iPad Zen updates through SideStore (**Update in SideStore**,
  or the source above), not by itself; with AltStore Classic, update it
  there.
- The Flatpak is updated by hand (above).
- `SHA256SUMS` from the same release protects against a damaged download,
  not against a forged release; that is what the signature is for, once it
  is pinned.

[Back to the guide](README.md)
