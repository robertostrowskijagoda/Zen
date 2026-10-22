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
file (Android, Windows x64 and ARM64, Linux tarballs, `.deb` and Flatpak,
macOS, the unsigned iPhone file), writes `SHA256SUMS` with the checksum of
each, signs that list (`SHA256SUMS.sig`, once the signing key is set up)
and attaches everything to a draft
release, which the maintainer checks and publishes by hand. The Android APK
is signed with the release key, which only a tag run can use, after the
maintainer approves it. Every build uses exactly the locked package
versions, the Linux files are checked to run on Ubuntu 22.04 and newer, the
Windows ZIPs carry the Visual C++ runtime, and the Android libraries are
aligned for phones with 16 KB memory pages. Details:
[RELEASES.md](../RELEASES.md).

## How Zen updates itself

- Every build except the store build asks GitHub for the latest release
  20 seconds after it starts and then every 12 hours. GitHub sees your IP
  address and the name "Zen", nothing else.
- When there is a newer version, a bar says so. **Update** downloads the
  file for your system and checks it against the release's `SHA256SUMS`;
  on Android also that it is signed with the same certificate as the
  installed app. Then the system installer asks (Android), or a helper
  swaps the folders after Zen closes (Windows, Linux tarball, macOS). Where
  Zen's folder is not writable (Program Files, `/opt`) the file is saved to
  Downloads. On iPhone there is only the bar; SideStore installs the update
  from the Zen source (below).
- **Flatpak** updates outside the app: the card shows the command
  (`flatpak install --user ./Zen-Linux-x64.flatpak`) and **Open release
  page**; nothing is downloaded inside the sandbox.
- **When GitHub limits requests** (it allows only so many an hour from one
  address), Zen says so and shows when it tries again: as late as GitHub
  asks, otherwise after 15 minutes, then 30, 60 and longer, up to 12 hours.
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
fingerprint) and **`apps.json`**, a SideStore / AltStore source. Both are
rebuilt by the *Pages* workflow every time a release is published (and once
a day): the source names the latest release's `Zen-unsigned.ipa`, its
version, date, size and checksum, and the permissions read from that very
file. SideStore checks the source, offers the update, and signs the file
with the person's own Apple ID. With a free Apple ID that signature expires
after 7 days: once a week turn on LocalDevVPN, open SideStore and tap
**Refresh**. Zen shows a reminder in Chats 2 days before the date.

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
- On iPhone Zen updates through SideStore (the source above), not by itself.
- The Flatpak is updated by hand (above).
- `SHA256SUMS` from the same release protects against a damaged download,
  not against a forged release; that is what the signature is for, once it
  is pinned.

[Back to the guide](README.md)
