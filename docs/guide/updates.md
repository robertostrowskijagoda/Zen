# Updates and releases

> Zen checks GitHub for a new version and can update itself. Friends can
> also pass the app to each other, hand to hand.

## How releases are made

A version tag on GitHub starts the **Release** workflow: it builds every
file (Android, Windows x64 and ARM64, Linux tarballs, `.deb` and Flatpak,
macOS, the unsigned iPhone file), writes `SHA256SUMS` with the checksum of
each, signs that list (`SHA256SUMS.sig`, once the signing key is set up)
and attaches everything to a draft
release, which the maintainer checks and publishes by hand. The Android APK
is signed with the release key, which only a tag run can use, after an
approval. Details: [RELEASES.md](../RELEASES.md).

## How Zen updates itself

- Every build except the store build asks GitHub for the latest release
  20 seconds after it starts and then every 12 hours. GitHub sees your IP
  address and the name "Zen", nothing else.
- When there is a newer version, a bar says so. **Update** downloads the
  file for your system and checks it against the release's `SHA256SUMS`;
  on Android also that it is signed with the same certificate as the
  installed app. Then the system installer asks (Android), or a helper
  swaps the folders after Zen closes (Windows, Linux tarball, macOS). Where
  Zen's folder is not writable (Program Files, `/opt`, Flatpak) the file is
  saved to Downloads. On iPhone there is only the bar.
- Once the maintainers' keys are pinned in the app, an update is installed
  only when `SHA256SUMS.sig` carries their hybrid signature (Ed25519 +
  ML-DSA-65) for this version and file. Until then the update screen says
  that the signature can't be checked yet.
- If github.com cannot be reached at all, Zen tells you, in case someone is
  blocking it.

## Pass it on

**Settings → Invite → Friend doesn't have Zen?** (or *Updates and Pass it
on*) sends the app to a friend's phone over Quick Share, Bluetooth or Wi-Fi,
even without internet. Zen also notices when friends have a newer version
and shows a quiet hint.

## Checking a download yourself

1. Download only from `github.com/robertostrowskijagoda/Zen` or from a friend.
2. Compare the file's SHA-256 with `SHA256SUMS` in the release.
3. On Android, compare the signing certificate fingerprint with the one in
   the [README](../../README.md#isnt-it-a-virus-how-to-check). Android itself
   refuses to install a copy with another key over the real Zen.
4. Optionally upload the file to [virustotal.com](https://www.virustotal.com).

## Limits

- The store build (for Google Play and Galaxy Store) never updates itself.
- `SHA256SUMS` from the same release protects against a damaged download,
  not against a forged release; that is what the signature is for, once it
  is pinned.

[Back to the guide](README.md)
