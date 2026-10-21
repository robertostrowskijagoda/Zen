# Releases, signing and publishing

How to release Zen on GitHub, what to sign with, how to check that a file is
official, which channels to distribute it through (section 4, section 6: Android developer
verification, stores, iPhone, costs and plan) and what to do about updates
over the network.

UI strings quoted below are the app's Polish labels (e.g. "Podaj dalej" =
"Pass it on", the in-app way of handing Zen to a friend; "O aplikacji" =
"About").

- **Repository:** https://github.com/robertostrowskijagoda/Zen
- **Website:** the human-facing page is the repository `README.md`. The only
  file on GitHub Pages is the invitation page (`tool/pages/index.html`,
  workflow `pages.yml`); it opens Zen with the code from a QR code or shows
  the download links.
- **Android package:** `com.roj.zen` (formerly `com.HuraganKodu.zen`).
- **License:** `LICENSE` — GPL-3.0-only (the unmodified GNU text), with
  additional terms under GPL section 7 in `NOTICE`: copies keep "Zen by Robert
  Ostrowski-Jagoda" and the donation link in the About screen; modified
  versions are marked as changed and use another name and icon. Every release
  ships `LICENSE` and `NOTICE`.

## 1. Repository

1. Before pushing, check `git status` and the history: `android/key.properties`,
   `*.jks` / `*.keystore` files, `maintainer.key` and `scratch/` must not be
   there (they are in `.gitignore`; also check
   `git log --all -- android/key.properties`).
2. **Invitation QR codes** lead to
   `https://robertostrowskijagoda.github.io/Zen/#CODE` (the code without
   dashes, after the `#`; the browser does not send that part to the server,
   so nobody knows who invites whom). The page opens Zen with the code, and
   whoever does not have Zen sees download buttons. The address is in
   `PeerShareCodec.invitePageUrl`
   (`lib/src/features/social/peer_share_codec.dart`); renaming the repository
   or the account breaks printed codes.

   **Publishing the page:** the workflow `.github/workflows/pages.yml`
   publishes `tool/pages/` on every change to `main`. Once in GitHub:
   **Settings → Pages → Source: GitHub Actions**. On the free plan GitHub
   Pages works only for **public** repositories.
3. Enable Issues in the repository settings; description: "A network of people
   who know each other — a messenger without servers, ads or an algorithm"
   (the repository description is in Polish).

## 2. Signing key (once and for all)

1. Create the key **outside the repository**:
   ```
   keytool -genkeypair -v -keystore zen-release.jks -keyalg RSA -keysize 4096 -validity 10000 -alias zen
   ```
2. `android/key.properties` (in `.gitignore`); without it the release is built
   with the debug key, with a warning:
   ```
   storeFile=C:/path/to/zen-release.jks
   storePassword=…
   keyAlias=zen
   keyPassword=…
   ```
3. **Backup:** a lost key means no more updates for anyone. Split the key file
   and password with Shamir (e.g. 3 of 5) among trusted people; never publicly,
   never in the repository. If the key ever has to change — rotation through
   APK Signature Scheme v3 (the old key signs the new one).
4. **Certificate fingerprint** (paste it into the README section "Czy to nie
   wirus?" ("Isn't it a virus?") and into the description of every release):
   ```
   keytool -list -v -keystore zen-release.jks -alias zen | findstr SHA256
   ```
   The same fingerprint goes into the app as the pinned one (`kOfficialApkCertificatesSha256`). Easiest from a signed APK — the tool
   prints the fingerprint and writes it straight into
   `lib/src/features/update/apk_signature.dart`:
   ```
   dart run tool/zen_release.dart fingerprint build/app/outputs/flutter-apk/app-release.apk --write
   ```
   or from the keystore (password in the `ZEN_STOREPASS` variable, otherwise
   keytool asks for it): `fingerprint --keystore zen-release.jks --alias zen
   --write`. Without `--write` it only prints the line ready to paste. (Reading
   APK certificates is pure Dart, `apk_signing_block.dart`, shared by the app
   and the tool.)

Earlier builds were signed with the debug key; Android does not let an app be
overwritten by one signed with a different key. Changing the package to
`com.roj.zen` creates a new app anyway (item 3.8).

## 3. Release step by step

1. **Version number:** `version:` in `pubspec.yaml` and `kAppVersion`
   / `kAppBuild` in `lib/src/app/app_version.dart` (a test checks that they
   match); the same number in the CHANGELOG heading and in the tag. The build
   number (`versionCode`) must increase.
2. **Go bridge** builds itself (section 3.1): `flutter build apk`, `windows`,
   `linux`, `macos` and `ios` rebuild it only when its sources changed. After
   changing `go.mod` (e.g. a new Yggdrasil version) refresh the licenses:
   `dart run tool/go_licenses.dart` (the test `go_licenses_test.dart` reminds
   you).
3. **Building:** pushing a tag `v<version>` runs
   `.github/workflows/release.yml`: Android (a separate job) and Windows x64
   on `windows-latest`, Windows ARM64 on `windows-11-arm`, Linux x64 on
   `ubuntu-latest`, Linux ARM64 on `ubuntu-24.04-arm`, macOS on
   `macos-latest` and iPhone (`ios.yml`, called from `release.yml`). Each job
   stores its files as an artifact; the second-to-last job gathers them and
   computes `SHA256SUMS`, and the last one attaches everything to the draft
   release. The APK signing key is in the secrets of the **`release`
   environment** (Settings → Environments; not the repository secrets):
   `ANDROID_KEYSTORE_BASE64` (the `.jks` file in base64),
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`
   — without them the workflow skips `Zen.apk` — and
   `ZEN_RELEASE_SIGNING_KEY`, the release signing key that signs
   `SHA256SUMS` (section 8.6; without it `SHA256SUMS.sig` is left out with a
   warning). The environment requires an
   approver (the maintainer) and has a rule for `v*` tags only; the key goes
   only to a run of a `v*` tag after approval (described at the top
   of `release.yml`). A manual run from a branch builds the other files as
   artifacts, without `Zen.apk` and without a release. **Windows ARM64 is
   experimental:** the `windows-arm64` job has `continue-on-error`, and until
   its first green run a failure leaves out only `Zen-Windows-arm64.zip`;
   `SHA256SUMS` is computed without it. Locally:
   `flutter build apk|windows|linux|macos --release` (requirements: README,
   "Budowanie ze źródeł" ("Building from source")).
4. **Files under exactly these names** (what `release.yml` produces):
   - `Zen.apk` — `build/app/outputs/flutter-apk/app-release.apk`; one
     universal APK with three ABIs: arm64-v8a, armeabi-v7a (32-bit) and
     x86_64 (ChromeOS, emulators); no x86 (Flutter has no x86 release
     engine);
   - `Zen-Windows.zip` — the zipped folder
     `build/windows/x64/runner/Release`;
   - `Zen-Windows-arm64.zip` — the zipped folder
     `build/windows/arm64/runner/Release` (experimental, see item 3);
   - `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz` — the folder
     `build/linux/<x64|arm64>/release/bundle` as `Zen/` (started with
     `Zen/zen`; includes `install-desktop-entry.sh`, which adds the menu entry
     and `zen://` links for the current user);
   - `Zen-Linux-x64.deb`, `Zen-Linux-arm64.deb` — the same bundle packaged by
     `linux/packaging/build_deb.sh` (`/opt/zen`, `/usr/bin/zen`, `.desktop`
     file, AppStream; dependencies from `dpkg-shlibdeps`; AAC/H.264 playback
     needs `gstreamer1.0-libav`, a recommended dependency);
   - `Zen-Linux-x64.flatpak` — the x64 bundle above packaged by the `flatpak`
     job with `linux/packaging/com.roj.zen.yml` (a repackaging of the built
     `Zen-Linux-x64.tar.gz`, not a build from source; runtime
     `org.gnome.Platform` 48, which is based on `org.freedesktop.Platform`
     and adds GTK 3; `libayatana-appindicator3` and its libraries are copied
     from the runner into the package). Sandbox: network, Wayland/X11,
     PulseAudio, all devices (camera), secret service, notifications, tray.
     Install: `flatpak install --user ./Zen-Linux-x64.flatpak`. Not on Flathub
     (that needs a from-source build); ARM64 is not built;
   - `Zen-macOS.zip` — `build/macos/Build/Products/Release/Zen.app` packed with
     `ditto -c -k --keepParent` (universal: Apple Silicon and Intel;
     ad hoc signature, no notarization — on first launch use "Open Anyway"
     in System Settings → Privacy & Security);
   - `Zen-unsigned.ipa` — from the "iOS" workflow;
   - `LICENSES-GO.txt` — `native/yggdrasil_bridge/LICENSES-GO.txt` (licenses
     of the Go modules in the bridge; they are also in the app: "O aplikacji
     → Licencje", next to `zen.exe` in the ZIPs and next to `zen` in the Linux
     archives);
   - `LICENSE` and `NOTICE` — the GPL-3.0 text and the author's additional
     terms (GPL section 4 asks for a copy of the licence with every copy);
   - `THIRD_PARTY_NOTICES.md` — the licences of the libraries, fonts, icons
     and services (also next to `zen.exe` and `zen`; the texts are in the
     app). Before a release, `dart run tool/check_licenses.dart` checks the
     Dart packages' licences;
   - `SHA256SUMS` — checksums of all the files above (item 5);
   - `SHA256SUMS.sig` — `SHA256SUMS` and the version signed with the release
     signing key (section 8.6); the app checks it before updating itself.

   **Store variant** (Google Play, Galaxy Store) is **not** a release file; it
   is built by hand with the `appStoreOnly` flavor (section 6.2):
   `flutter build appbundle --release --flavor appStoreOnly` (Play AAB),
   `flutter build apk --release --flavor appStoreOnly` (Galaxy Store). The
   copies named `Zen-APP-STORE-ONLY-do-not-install-manually.aab|apk` appear in
   `build/app/outputs/app-store-only/`; the app is called "Zen" as everywhere
   (only the About screen says "Wersja ze sklepu"; no icon camouflage). Never
   attach them to a GitHub release or hand them to people to sideload.

   The README links to `…/releases/latest/download/Zen.apk`,
   `…/releases/latest/download/Zen-Windows.zip`
   and `…/releases/latest/download/Zen-unsigned.ipa`, so fixed names always
   give the newest version in one click (likewise `Zen-Windows-arm64.zip`,
   `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz`, the `.deb` files, `Zen-Linux-x64.flatpak` and
   `Zen-macOS.zip`).
5. **Checksums:** `SHA256SUMS` is computed by the last-but-one job of
   `release.yml` over all release files (`sha256sum` format; check with
   `sha256sum -c SHA256SUMS`, on Windows
   `Get-FileHash -Algorithm SHA256 Zen.apk`). Anyone may redistribute copies, and the
   sums let people check that a copy is the official one, so they must accompany
   every release — also after replacing a file by hand they must be computed
   and signed again (section 8.6). The job runs only when the required builds
   succeeded (Windows, Linux, macOS, iOS; Android unless it was skipped).
   The attach job never replaces a file already attached (no `--clobber`)
   and stops if the release is already published; to redo a file, delete it
   from the draft by hand and re-run the job.
6. **GitHub → Releases:** tag `v<kAppVersion>` (e.g. `v1.11.0`). Pushing the
   tag creates a draft with all files from item 4. In the description: what's
   new (from the CHANGELOG), the certificate fingerprint, the SHA-256 sums.
   Publish it by hand after checking.
7. **Verification:** download from `releases/latest/download/`, compare the
   sum, `apksigner verify --print-certs Zen.apk` (fingerprint as in the
   README), install on a clean phone and run on Windows, Linux and Mac.
8. **First release with `com.roj.zen`:** state in the description that it is a
   new app — the old one (`com.HuraganKodu.zen`) stays alongside with its
   data. The account moves via "Podłącz nowe urządzenie" ("Connect a new
   device", section 6.5) or recovery; then the old one can be uninstalled.

### 3.1. Go bridge (native/yggdrasil_bridge)

- **Automatic:** Android — the Gradle task `buildGoBridge` (before
  `preBuild`), Windows — the CMake target `yggdrasil_bridge`. Both call
  `build_if_changed.ps1 -Target android|windows`, which computes a SHA-256 of
  the sources (`*.go` and `internal/*/*.go` without tests, `go.mod`,
  `go.sum`, the build script)
  and `go version`, and
  builds only when it differs from the one stored next to the library
  (`libyggdrasil_bridge.so.sha256`, `bin/yggdrasil_bridge.dll.sha256`; when
  the library is in the repository, its sum goes there together with it).
- **Android ABIs:** the bridge is built for arm64-v8a, armeabi-v7a
  (`GOARCH=arm GOARM=7`, NDK `armv7a-linux-androideabi21-clang`) and x86_64
  (NDK `x86_64-linux-android21-clang`) by `build_android.sh`/`.ps1` (shared
  list in `bridge_tools.ps1`); each ABI has its own `.sha256` marker, so only
  changed ones are rebuilt. Gradle takes the ABIs from Flutter's
  `target-platform`: `flutter run` builds the bridge only for the device's ABI,
  `flutter build apk` for all three (`abiFilters`; the script reads
  `ZEN_ANDROID_ABIS`). The APK stays a single universal file; its native
  libraries are compressed (`useLegacyPackaging`) so that three ABIs do not
  make it ~2.5 times bigger. `--split-per-abi` works (then without
  `abiFilters`) — an option if the APK gets too big, but self-update and
  "Podaj dalej" assume a single file. CI (`android-bridge` in `ci.yml`) builds
  all three ABIs and checks the `YggStartNode` export.
- **Without Go** (or without NDK / a C compiler) the existing library is used
  with a warning; without it the build aborts, saying what is missing.
  `ZEN_SKIP_GO_BRIDGE=1` skips the check. Automatic rebuilding of the `.so`
  works only on Windows (the script uses the Windows NDK); `build_android.sh`
  does it on Linux (as in CI).
- **Windows ARM64:** `build_windows.ps1 -Arch x64|arm64` (default: the
  computer's architecture); the ARM64 DLL goes to `bin\windows-arm64\`, x64
  stays in `bin\`; CMake picks by `FLUTTER_TARGET_PLATFORM` / the generator
  platform; Dart (debug) looks for the DLL of the right architecture
  (`Abi.current()`). cgo on ARM64 needs llvm-mingw
  (`aarch64-w64-mingw32-clang`; CI downloads version 20251021 and checks its
  SHA-256). Flutter builds `windows-arm64` only on an ARM64 computer. Needs
  `flutter_webrtc` ≥ 1.5 (bumped in `pubspec.yaml`).
- **Manually**, as before: `build_android.ps1`, `build_windows.ps1`
  (portable Go from `%LOCALAPPDATA%\Programs\GoPortable` or from `PATH`; NDK
  from `ANDROID_NDK_HOME`, `ANDROID_HOME` or the default SDK).
- **iPhone:** `sh native/yggdrasil_bridge/build_ios.sh [iphonesimulator]`
  (macOS, Go + Xcode) produces the static library
  `ios/GoBridge/<platform>/libyggdrasil_bridge.a` (outside the repository).
  Xcode links it into the app (`ios/Flutter/GoBridge.xcconfig`), and the "Go
  bridge" phase in the project rebuilds it when the sources change. A new
  `//export` function in Go needs an `-Wl,-u,_Name` entry in
  `GoBridge.xcconfig` (the script checks this).
- **Linux:** the CMake target `yggdrasil_bridge` (`linux/CMakeLists.txt`)
  calls `build_linux.sh --if-changed <linux-x64|linux-arm64>`; the library
  `native/yggdrasil_bridge/bin/<platform>/libyggdrasil_bridge.so`
  (+ `.sha256`) goes to `lib/` in the package. Needs Go and a C compiler (gcc
  or clang); an architecture other than the computer's needs a cross compiler
  in `CC`.
- **macOS:** the "Go bridge" phase in `macos/Runner.xcodeproj` calls
  `build_macos.sh --if-changed`, which makes a universal (arm64 + x86_64)
  static library `macos/GoBridge/libyggdrasil_bridge.a` (outside the
  repository). Xcode links it into the app
  (`macos/Runner/Configs/GoBridge.xcconfig`) as on iPhone, so a new `//export`
  function needs an `-Wl,-u,_Name` entry there too.

### 3.2. Linux: playback and desktop integration

- **Playback:** a custom `video_player` backend on GStreamer:
  `linux/runner/zen_media_player.cc` (playbin, RGBA frames into
  `FlPixelBufferTexture`, rotation of phone videos via `videoflip`, 1.5×/2×
  tempo via `scaletempo`) + `lib/src/features/media/linux_video_player.dart`.
  Without GStreamer at build time or on the system the app immediately says
  playback is impossible, without hanging. Rejected: `video_player_media_kit`
  (downloads and replaces the whole app's `malloc` with mimalloc, hard
  libmpv dependency, plugin code on every platform) and `fvp` (adds FFmpeg/mdk
  to every platform). The release job checks that `zen` links
  `libgstreamer-1.0`.
- **Integration:** `linux/packaging/com.roj.zen.desktop`
  (`MimeType=x-scheme-handler/zen`, `StartupWMClass=com.roj.zen`),
  `com.roj.zen.metainfo.xml` (AppStream, validated in CI),
  `install-desktop-entry.sh` in the tar.gz, `build_deb.sh` (only `dpkg-deb`;
  dependencies from `dpkg-shlibdeps`, with non-`t64` alternatives for older
  Debians). The runner is single-instance via GApplication (required by
  app_links on Linux: a link from the browser reaches the running Zen); the
  test profile (`--zen-profile` / `ZEN_PROFILE`) still starts alongside.
- **Flatpak:** only repackaged from the built bundle (section 3 item 4, the file list);
  a from-source Flatpak for Flathub (Flutter and Go dependencies collected
  offline in the manifest) is not done.

### 3.3. iPhone (GitHub Actions)

`.github/workflows/ios.yml` (macOS, Flutter 3.47.1, Go from `go.mod`): Go
bridge → `flutter build ios --release --no-codesign` → `Zen-unsigned.ipa`
(a `Payload/Runner.app` folder in a ZIP). It runs manually (Actions → iOS →
Run workflow; the file is in the run's artifacts) or as part of `release.yml`
for a `v*` tag, which attaches it to the release. The package is unsigned —
SideStore or AltStore sign it with the user's free Apple ID (README, section
"iPhone"). App identifier: `com.roj.zen`. iOS 15+. Locally on a Mac:
`build_ios.sh`, then `flutter build ios --release --no-codesign`.

## 4. Android: developer verification (2026–2027)

State as of 15.10.2026 (sources: section 6.6):

- On **certified** phones (with Google services) only apps whose package and
  signing key were registered by a verified developer will be installable and
  updatable — regardless of where the file comes from (store, browser, "Podaj
  dalej", self-update).
- **From 30.09.2026** this applies only to installs from "participating
  stores" (Google Play, Galaxy Store, HONOR, OPPO, Xiaomi GetApps, vivo, Palm
  Store) in Brazil, Indonesia, Singapore and Thailand. Installing from a file
  — there too — has not changed for now. **In Poland and the EU nothing has
  changed yet.**
- **2027:** all apps on certified devices worldwide; the month is not
  announced, no European Commission decision (DMA).
- Without registration there remains the **advanced flow** (Developer options →
  "Apps from unverified developers", confirmation, restart, **24 h wait**,
  then for 7 days or permanently; a warning at every install; turning the flow
  off stops updates) or **ADB** (exempt). Does not apply to phones without
  Google (GrapheneOS, LineageOS without GMS, Huawei) or to corporate devices.
- Installing a little-known app without internet may fail — Google admitted
  that "in the worst case" verification needs a network (uncertain; matters
  for "Podaj dalej" offline).

**To do by the end of 2026 (~PLN 100):**

1. **Key backup first** (section 2 item 3): without the key the package cannot be
   registered, and a lost key means no more updates.
2. **Account for USD 25 once:** Play Console as a personal account (both the
   verification account and the route to Google Play, section 6.2) or Android
   Developer Console (outside Play only). Needed: a Google account with 2FA,
   a payment profile, an ID card, a document with an address (bill,
   statement), e-mail and phone.
3. **Register `com.roj.zen`** with the SHA-256 fingerprint of the release key
   and proof of owning the key. Play version: upload the **same** key to Play
   App Signing (one package for both channels) or register both keys.
4. The free "limited distribution" account (no document, up to 20 devices,
   each must accept an invitation) is only good for tests.
5. When verification covers the EU: on a phone with verification active, check
   installing through "Podaj dalej" without internet; if it needs a network,
   say so on the "Podaj dalej" screen.

## 5. How to check that a file is official

- **Certificate fingerprint** and **`SHA256SUMS`** with every release and in
  the README.
- User: downloads only from the repository (the address starts with
  `github.com/robertostrowskijagoda/`) or from a friend via "Podaj dalej"; may
  upload the file to virustotal.com; Android scans the app on install; the
  same signing key means a fake will not install "over" the real Zen.
- In the app: pinned fingerprint, "Oficjalna kopia" ("Official copy")
  in "O aplikacji", a red warning for every APK with a mismatching signature
  or sum, and a **signed manifest** with the donation link, author and
  repository (section 8.2) and a canary (section 8.3).
- **Windows:** no Authenticode signature today, so SmartScreen shows "Windows
  protected your PC" (the README says what to click). Zen-Windows-arm64.zip is
  the same. To do: SignPath (free for open-source projects; Zen is
  GPL-3.0) or Azure Trusted Signing.
- **macOS:** ad hoc signature, no notarization — since macOS 15 the first
  launch only via "Open Anyway" in System Settings (or
  `xattr -dr com.apple.quarantine`). Eventually Developer ID and notarization
  (Apple account, section 6.3). **Linux:** unsigned (`.tar.gz`, `.deb` and `.flatpak`); sums in
  `SHA256SUMS`.

## 6. Distribution: channels and plan

Research on channels, stores and law from 14–15.10.2026 — this is neither
legal nor tax advice; uncertain places are marked.

### 6.1 Channels

| Channel | State | Notes |
|---|---|---|
| GitHub Releases | main channel | signed APK (arm64-v8a, armeabi-v7a, x86_64), desktop packages, `SHA256SUMS`; from 2027 only with a registered package (section 4) |
| "Podaj dalej" in the app | works | hotspot, Wi-Fi, Quick Share, USB from a computer; from 2027 as above, possibly only once online |
| Obtainium | works, nothing to do | installs and updates straight from GitHub Releases; not a store — no review or license requirements. To do: a "Get it on Obtainium" button in the README and the key fingerprint to check (e.g. AppVerifier) |
| Own F-Droid repository | possible | `fdroidserver` → static files on GitHub Pages; an address or QR to add in F-Droid, Droid-ify, Neo Store; no review |
| F-Droid (main) and IzzyOnDroid | possible, not set up | the GPL-3.0 license meets their rule (OSI- or FSF-approved). F-Droid builds from source: it needs a build recipe (Flutter + the Go bridge) and the built-in updater off in that build; the GIF search (klipy.com) may get the "NonFreeNet" anti-feature. Such builds may keep the name and icon (`NOTICE`, 3.3) |
| Google Play | possible, separate variant (section 6.2) | personal account USD 25; new personal account: closed test with at least 12 testers for 14 days, then a production application (~7 days); name, surname and country public; targetSdk 36 for new apps and updates |
| Samsung Galaxy Store | possible, same variant | no fees, manual review; from 30.09.2026 a store participating in Google verification |
| Huawei AppGallery | optional | Huawei phones without Google (Google verification does not apply); Zen uses no Google services — check on one phone |
| Accrescent | not now | console for invited developers only, no self-update, package ID must match the author's domain (uncertain — the page may be outdated) |
| Amazon, Aptoide, RuStore, Chinese stores | no | Amazon Appstore on Android closed since 20.08.2025; Aptoide — annual fee and a "piracy store" reputation; RuStore requires a VK ID, and VK is on the EU sanctions list (07.2026); China — ICP registration and a Chinese entity |
| iPhone: SideStore / AltStore with a free Apple ID | works | `Zen-unsigned.ipa`; signing every 7 days, at most 3 apps, no background work |
| iPhone: TestFlight, AltStore PAL, App Store | needs a USD 99/year account | section 6.3 |
| Windows | x64 ZIP and experimental ARM64 ZIP, no Authenticode | later MSIX and winget (section 5) |
| Linux | `tar.gz` and `.deb`, x64 and ARM64; Flatpak (x64, repackaged bundle, attached to the release; not on Flathub) | AppImage and Snap optional |
| macOS | ZIP with an ad hoc signature | Developer ID + notarization with the same account as iPhone (section 6.3); official Homebrew only after notarization |
| Repository mirror (e.g. Codeberg) | optional | in case GitHub is blocked; mirror addresses can be published in the signed manifest (section 8.2) |

"Open straight in the app" (Android App Links) requires a file
`/.well-known/assetlinks.json` at the domain root — the invitation page is in
the subdirectory `robertostrowskijagoda.github.io/Zen/`, and there is
deliberately no own domain. So the QR code opens the invitation page (section 1,
item 2), which launches Zen through `intent://` or `zen://`; Zen recognizes
the same code in the scanner, and after enabling "Open supported links" also
links from the camera.

### 6.2 Store variant of Android (Google Play, Galaxy Store)

Model: Signal — **the same package `com.roj.zen` and the same key**, two
flavors: `full` (the default; the full app with self-update, what GitHub
ships) and `appStoreOnly` without it (named so that nobody sideloads it by
accident: the files are called
`Zen-APP-STORE-ONLY-do-not-install-manually.*`); users move between channels without losing
data. Yggdrasil runs in Zen as a library, without `VpnService` (VPN would
require an organization account).

**Done (the `appStoreOnly` flavor):**

- the manifest in `src/appStoreOnly` removes `REQUEST_INSTALL_PACKAGES` and
  removes the camouflage alias; the launcher label stays "Zen" (only the About
  screen says "Wersja ze sklepu");
- Dart (`appFlavor == 'appStoreOnly'` or `--dart-define=ZEN_STORE=true`) turns off
  the update service, shows "Aktualizacje ze sklepu" ("Updates from the
  store") and replaces "Podaj dalej" with a dialog containing a link
  (`--dart-define=ZEN_STORE_URL=…`, default: the project page);
- flavors are active only for a task with a flavor (`--flavor appStoreOnly|full`)
  or with `-Pzen.flavors=true`, so a plain `flutter build apk` / `flutter run`
  works unchanged;
- built by hand, not by `release.yml` (section 3 item 4).

**Still to do** for the `appStoreOnly` variant:

1. ~~no self-update, no `REQUEST_INSTALL_PACKAGES`~~ (done; self-update from
   outside Play is a hard violation of the Device and Network Abuse policy);
2. ~~"Podaj dalej" as a link or QR to the store and the page, without sending
   the APK~~ (done as a link);
3. background service: a declared type (`connectedDevice`; `phoneCall`,
   `camera`, `microphone` only during a call) instead of `specialUse`, a video
   for reviewers, an "always online" switch;
4. `USE_FULL_SCREEN_INTENT`: a "calls" declaration; the alarm asks for special
   access and has a fallback (a loud notification);
5. location only in the foreground or one background feature (alarm), with a
   clear disclosure; Bluetooth with `neverForLocation`, if true;
6. dating: the whole app 18+ ("Restrict Minor Access") or dating hidden — an
   easily bypassed age gate is not enough;
7. names: "Samorząd" / "Rada" (Council) instead of "pyramid", "points" instead
   of "currency" and "wallet", with the note "no monetary value"; a "no
   financial features" declaration (the rejection risk is an assessment, not a
   rule);
8. no link to buycoffee.to in the app (or a tip via Play Billing);
9. user content: terms before the first post, reports to the author (e-mail),
   a child safety (CSAE) page with a contact person, a moderation description;
10. targetSdk 36, AAB, privacy policy, Data safety (klipy.com too: queries and
    IP), IARC rating, instructions and a second account for the reviewer
    (Briar disappeared from Play in 2022 partly for lack of test data);
11. countries: Poland, the EU and English-speaking countries; without China,
    Russia, Belarus and sanctioned countries (the GitHub APK stays everywhere).

New UI texts of the variant (to translate): the "Podaj dalej" dialog in the
store build, "Aktualizacje ze sklepu" (card title) and its body ("This version
of Zen is updated by the store you got it from"), and the "Podaj dalej"
section description in the store build.

### 6.3 iPhone and Mac

- **No account** — as today: SideStore / AltStore with a free Apple ID.
- **Individual Apple Developer account — USD 99/year** (seller: the author's
  name). It gives:
  - **TestFlight** — public link, up to 10,000 testers, the first build gets a
    light review, a build is valid for 90 days; replaces the unsigned IPA;
  - **AltStore PAL** (EU, Japan, Brazil; iOS 17.4+) — for a developer from any
    country, no EU company needed; instead of App Review, **notarization**
    (description, bugs, security, privacy, no downloading code — without
    guidelines on user content, "saturated categories" and names). From
    **01.10.2026** a 5% commission on sales replaced the per-install fee, so
    a free app pays nothing (uncertain in details). Package and source file
    (JSON) on GitHub Pages; installed by people with an Apple account from
    those countries;
  - **App Store** — full review: user content (filter before publishing,
    reports with a response, blocking, contact), no impression of an
    "anonymous chat", dating as a side feature, names as in section 6.2, the donation
    link only in the US store, in-app account deletion, an encryption
    declaration (in France a separate declaration or a switch to CryptoKit);
  - **macOS** — Developer ID signature and notarization in CI (no content
    review): "Open Anyway" and keychain prompts after updates go away.
- **Web Distribution in the EU** (installing from your own site) — only for
  organizations meeting the criterion (e.g. a fee waiver for non-profits);
  practically unavailable to an individual.
- **Japan** (from iOS 26.2) and **Brazil** (from iOS 26.5) allow alternative
  stores; AltStore PAL works in both with the same package.
- **In every iOS channel:** no persistent background connection; notifications
  about messages and calls would need a server sending APNs (PushKit +
  CallKit) — owner's decision: none, so Zen on iPhone receives only while it is
  open; self-update and "Podaj dalej" are impossible. The Enterprise program
  and "signers" using corporate certificates — no.

### 6.4 Costs and entity

| What | Cost |
|---|---|
| Android: Play Console / Android Developer Console | USD 25 once |
| Apple Developer Program (iPhone and macOS) | USD 99/year |
| Obtainium, own F-Droid repository, Galaxy Store, AppGallery | 0 |
| Foundation (if the project grows) | setup ~PLN 1.5–3k, upkeep ~PLN 5–15k/year (mostly accounting) |

- **A private person is enough to start** (Google: personal account; Apple:
  individual account).
- **A sole proprietorship (JDG)** gives nothing at Apple (individual account),
  at Google at most an organization account (no 12 × 14 test), and costs
  social security (ZUS). A **limited company (sp. z o.o.)** is ~PLN 40k/year in
  fixed costs. An Estonian OÜ and a US LLC — no (taxes in Poland, formal
  penalties).
- **Foundation** (one person can found it; the KRS court register is free for
  NGOs, 2–4 months): an organization account (D-U-N-S) at Google and Apple,
  the foundation's name instead of a personal name, a registered office
  address instead of a home one, a possible **Apple fee waiver** (uncertain
  for Poland — the country list is not published; ask via the form) and then
  Web Distribution in the EU, grants (NLnet, OTF), 1.5% of income tax once
  public benefit organization (OPP) status is obtained. Requires transferring
  the economic copyrights of the code to the foundation or an exclusive
  license. A registered association: at least 7 founders.
- **DSA, trader status** in EU stores: a private person with a free app
  without ads has strong arguments for not being a "trader" (then no
  publication of address and phone); donations are a grey area — the author's
  decision (uncertain).

### 6.5 Plan

Now (October–December 2026):

1. Stay with GitHub Releases; in the README an Obtainium button and the key
   fingerprint with checking instructions (section 2 item 4). Cost 0.
2. Release key backup with Shamir (section 2 item 3) — before registration.
3. Google account USD 25 and registration of `com.roj.zen` with the release
   key (section 4).
4. The `appStoreOnly` variant (section 6.2: built; the remaining items open) with the same
   package and key; closed test with 12 testers × 14 days; publication in
   Poland and the EU (+ English-speaking countries); then Galaxy Store with the
   same variant. About 3–6 weeks in total.
5. Apple Developer Program USD 99/year: TestFlight instead of the unsigned
   IPA, AltStore PAL for the EU in parallel; Developer ID and macOS
   notarization in CI.
6. App Store once the TestFlight version stabilizes (Poland, EU, UK, USA).
7. Linux: Flathub (a from-source Flatpak; `.deb`, audio/video playback and a release-file Flatpak are done, section 3.2).
8. Privacy policy and terms — required by the stores; with klipy.com and
   public Yggdrasil nodes. Drafts exist in `docs/PRIVACY.md` and
   `docs/TERMS.md` (not legal advice; to be reviewed by the maintainer),
   with `docs/PROTOCOL.md` (protocol specification from the code); "O aplikacji" links to the privacy
   policy and terms on GitHub.

In 2027:

- check installing without internet (hotspot, Bluetooth) on a phone with
  active verification; unregistered test builds — the advanced flow or ADB;
- watch: the date verification covers the EU, a possible European Commission
  decision, Google's "Registered App Stores" program outside the USA, the US
  Supreme Court ruling in Epic v. Apple (about 06.2027);
- a foundation, if the project grows (organization account, fee waiver → Web
  Distribution in the EU);
- F-Droid and IzzyOnDroid: possible since the GPL-3.0 license (section 6.1).

### 6.6 Sources

- Android developer verification:
  [guide](https://developer.android.com/developer-verification/guides),
  [FAQ](https://developer.android.com/developer-verification/guides/faq),
  [full distribution](https://developer.android.com/developer-verification/guides/full-distribution),
  [Android Authority 01.10.2026 — first wave](https://www.androidauthority.com/android-sideloading-developer-verification-first-wave-rollout-3717921/),
  [Android Authority 18.08.2026 — advanced flow](https://www.androidauthority.com/google-android-advanced-flow-sideloading-rollout-begins-3700073/).
- [F-Droid Inclusion Policy](https://f-droid.org/docs/Inclusion_Policy/),
  [IzzyOnDroid Inclusion Policy](https://izzyondroid.org/docs/general/AppInclusionPolicy/),
  [own F-Droid repository](https://f-droid.org/docs/Setup_an_F-Droid_App_Repo/),
  [Obtainium](https://github.com/ImranR98/Obtainium).
- Google Play: [test for new personal accounts](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en),
  [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379?hl=en),
  [REQUEST_INSTALL_PACKAGES](https://support.google.com/googleplay/android-developer/answer/12085295?hl=en),
  [foreground services and full screen](https://support.google.com/googleplay/android-developer/answer/13392821),
  [Signal: flavors](https://github.com/signalapp/Signal-Android/blob/main/app/build.gradle.kts).
- Apple: [apps in the EU](https://developer.apple.com/support/apps-in-the-eu/),
  [AltStore PAL for developers](https://faq.altstore.io/developers/distribute-with-altstore-pal),
  [Web Distribution](https://developer.apple.com/support/web-distribution-eu),
  [fee waiver](https://developer.apple.com/help/account/membership/fee-waivers),
  [Japan](https://developer.apple.com/support/app-distribution-in-japan),
  [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## 7. Donations

- The link is in `kDonationUrl` (`lib/src/features/about/presentation/about_screen.dart`)
  and in the README: **https://buycoffee.to/zen** (since 14.10.2026). Change
  it only in these two places — and in the signed manifest (section 8.2): a copy whose
  `kDonationUrl` differs from the signed link shows a red warning.
- Where to collect: buycoffee.to, Patronite, zrzutka.pl (BLIK, bank
  transfers); GitHub Sponsors, Liberapay, Ko-fi (abroad); Open Collective
  (open finances); later a foundation (grants from NLnet, Prototype Fund, EU
  funds; 1.5% of income tax once OPP status is obtained).
- Taxes (approximate, to be confirmed with an adviser or in the KIS tax
  rulings): according to the interpretation of 09.09.2025 (after the NSA
  judgment of 27.03.2025) payments from **identified** supporters are group III
  gifts (in 2026 the tax-free amount is PLN 5,733 from one person within 5
  years, above that tax of 12–20% and an SD-3 return within a month), and
  **anonymous** payments are not gifts — their qualification in PIT is
  disputed. Unregistered activity in 2026: up to PLN 10,813.50 of revenue per
  quarter. A collection for one's own work is usually not a "public
  collection" within the meaning of the act. In store versions the donation
  link has to be removed (section 6.2, section 6.3).
- In the app the donation appears only in "O aplikacji" (at the top), with no
  nagging elsewhere. Good practices: a clear goal, short reports.

## 8. Updates over the network (disabled)

The mechanism from V1.10 is in the code but **disabled**: the maintainer key
list `kReleaseMaintainers` in `lib/src/features/update/release.dart` is empty,
so the app accepts no updates from the network. We do not want maintainers
with separate keys; a proposed replacement (the same signing certificate +
a higher `versionCode` + 7 days + a human's consent) is still to be decided.

How it works today (if the list were not empty): a release is accepted when at
least 2 of 3 maintainers signed it (hybrid Ed25519 + ML-DSA-65, both halves
must hold), 7 days passed since it was first
seen (any maintainer can hold it back in that time) and the human presses
"Zainstaluj" ("Install") themselves. Files travel over the network like any
other file (256 KB chunks), so a swapped copy is rejected.

The tool `tool/zen_release.dart` (pure Dart; `keygen`, `pubkey`, `sign`,
`verify` and `revoke` also need **Go**, the one that builds the bridge:
signatures are made by `native/yggdrasil_bridge/cmd/zensig`, run with
`go run`). A maintainer's public key is its **hybrid id**
`<Ed25519 key>.<SHA-256 of the ML-DSA-65 key>` (89 characters), derived from
the one seed in the key file:

```
dart run tool/zen_release.dart keygen ~/zen-maintainer.key      # maintainer key
dart run tool/zen_release.dart create --version 1.11.0 --build 11 \
    --notes "What's new" --out release.json \
    android=build/app/outputs/flutter-apk/app-release.apk windows=dist/zen-setup.exe
dart run tool/zen_release.dart sign release.json ~/zen-maintainer.key
dart run tool/zen_release.dart verify release.json
dart run tool/zen_release.dart bundle release.json zen-1.11.0.zenupdate \
    android=… windows=…
dart run tool/zen_release.dart revoke --build 11 --why "Reason" \
    ~/zen-maintainer.key revoke-11.json                         # hold back
dart run tool/zen_release.dart maintainers [--write] ID1 ID2 ID3      # section 8.1
dart run tool/zen_release.dart sums …                           # SHA256SUMS
dart run tool/zen_release.dart canary …                         # section 8.3
dart run tool/zen_release.dart fingerprint APK|--keystore … [--write]   # section 2 item 4
```

A `.zenupdate` (or just `release.json` or a hold-back file) is loaded in
**Settings → Aktualizacje i Podaj dalej → Wczytaj aktualizację z pliku**
("Updates and Pass it on → Load an update from a file"); the app checks the
signatures and tells friends about the new version. Argument parsing
distinguishes option values containing "=" from file names.

### 8.1 Enabling (once there are maintainer keys)

1. Each of the 3 maintainers, on their own offline computer:
   `dart run tool/zen_release.dart keygen ~/zen-maintainer.key` — sends the
   others **only** the printed hybrid id.
2. `dart run tool/zen_release.dart maintainers --write ID1 ID2 ID3` writes
   them into `kReleaseMaintainers` (without `--write` it only prints). From
   that build the app accepts releases with 2 of 3 signatures.
3. At every release: `create` → `sign` with two keys → `verify` →
   `sums > SHA256SUMS` → `bundle`; attach the `.zenupdate` and `release.json`
   to the GitHub release.

### 8.2 Signed donation link, author and mirrors

`create` adds to the manifest `official` (the donation link, author and
repository — by default the same as in the app; change with `--donation`,
`--author`, `--repo`, disable with `--no-official`) and `mirrors`
(`--mirror URL`, repeatable; only `https://`). The
signature covers these together with the APK/ZIP sums. Unknown manifest fields
are preserved, so the signature of newer manifests still verifies. The app
remembers the latest signed data (also from a release equal to its own, e.g. a
loaded `release.json`), passes it on to friends and in "Aktualizacje i Podaj
dalej" shows a red warning ("To może nie być oficjalny Zen" — "This may not be
the official Zen") when its own donation link, author or repository differ
from the signed ones, plus the list of mirrors. It fetches nothing from the
network: mirrors are just addresses.

### 8.3 Canary

```
dart run tool/zen_release.dart canary --text "Until today nobody has forced us to change Zen or to hand over keys." \
    --days 90 --out canary.json
dart run tool/zen_release.dart sign canary.json ~/zen-maintainer.key   # 2 of 3
dart run tool/zen_release.dart verify canary.json
```

Format: `{"m": {"t": "zen_canary", "app": "zen", "at", "until", "text"},
"sigs": [{"k", "s"}]}` (`k` the maintainer's hybrid id, `s` its hybrid
signature of the canonical JSON of `m`, as in a release). It is loaded like an update and passes from friend to friend
(the `can` field in `zen_rel`); the app shows the text and,
after `until`, a warning that the statement was not renewed. A new canary must
be signed before `until` passes.

### 8.4 Versions of friends

Ping and pong to accepted friends carry `ver`, `build` and `caps`
(`lib/src/app/peer_version.dart`). When friends have a newer version, Settings
shows a quiet bar "Znajomi mają nowszą wersję Zen (X)" ("Friends have a newer
version of Zen") leading to "Aktualizacje i Podaj dalej". The version is the
friend's own claim and affects nothing security-related. A signed release
marker spreading by gossip is not done.

### 8.5 Updates from GitHub (on)

Independent of section 8: every build except the store one asks
`api.github.com/repos/robertostrowskijagoda/Zen/releases/latest` 20 s after
start and every 12 h (one GET, only the User-Agent `Zen`;
`lib/src/features/update/github_update_service.dart`). A newer `v<version>`
tag shows the bar "Jest nowa wersja X — warto zaktualizować" with
"Aktualizuj": the platform's file from section 3 (`Zen.apk`, `Zen-Windows.zip`,
`Zen-Windows-arm64.zip`, `Zen-Linux-<arch>.tar.gz` / `.deb` / `.flatpak`,
`Zen-macOS.zip`) is downloaded and must match the release's `SHA256SUMS` by
name and sum. Android: the APK must also be signed with the installed app's
certificate, then the system installer asks. Windows / Linux tar.gz / macOS:
unpacked next to the app's folder, a helper script swaps the folders after
Zen exits and starts the new version; where the folder is not writable
(Program Files, `/opt/zen`, Flatpak) the file is saved to Downloads and
shown. iOS: only the bar. When github.com cannot be reached (network error,
TLS, timeout — not an HTTP error answer), "Updates" says "Nie mogę sprawdzić
aktualizacji, strona github jest niedostępna. Możliwe, że ktoś zwalcza tę
aplikację."; the closable bar shows it only after a second failed attempt
(2 min later) while the mesh node has peers. Downloads follow redirects
only to `github.com`, `objects.githubusercontent.com` and
`release-assets.githubusercontent.com` (HTTPS). `SHA256SUMS` comes from the
same release as the file, so it protects against damage, not against a
forged release; that is what the signature of section 8.6 is for.

### 8.6 Signed SHA256SUMS (GitHub updates)

Once `kReleaseMaintainers` holds at least one key, the GitHub update (all
platforms; on Android in addition to the certificate check) installs a file
only when the release also has `SHA256SUMS.sig`, signed with one of those
keys, naming this version and this file with its SHA-256. Without that file,
with a bad signature or another version, nothing is installed. While the
list is empty (today) the app behaves as in section 8.5 and "Aktualizacje i Podaj
dalej" says that this build cannot check the author's signature yet.

`SHA256SUMS.sig` has the format of a signed release, like the canary (section 8.3):
`{"m": {"t": "zen_sums", "app": "zen", "version", "files": {name: sha256}},
"sigs": [{"k", "s"}]}` (hybrid id and hybrid signature, as in section 8). The
`sign` job of `release.yml` (with Go for the signature) makes it on every
`v*` tag with the environment secret **`ZEN_RELEASE_SIGNING_KEY`** (in the
`release` environment, so it waits for the same approval as the Android
job); without the secret it is skipped with a warning. By hand:

```
dart run tool/zen_release.dart sums-manifest --version 1.12.0 \
    --out SHA256SUMS.sig SHA256SUMS
dart run tool/zen_release.dart sign SHA256SUMS.sig ~/zen-release.key
dart run tool/zen_release.dart verify SHA256SUMS.sig
```

One-time steps for the owner:

1. `dart run tool/zen_release.dart keygen ~/zen-release.key` on your own
   computer (outside the repository, with Go installed); it prints the
   key's hybrid id. Back the file up like the APK key (section 2 item 3): the one
   seed in it is both the Ed25519 and the ML-DSA-65 key.
2. `dart run tool/zen_release.dart maintainers --write <hybrid id>` puts the
   hybrid id into `kReleaseMaintainers`; commit it. Builds from then on
   require the signature. One key does not turn on network updates (section 8:
   they need 2 signatures from a list of at least 3).
3. Settings → Environments → `release` → Environment secrets → add
   `ZEN_RELEASE_SIGNING_KEY` with the contents of `~/zen-release.key` (one
   line of base64).
4. Recommended: Settings → General → Releases → enable immutable releases,
   so a published release's files cannot be replaced.

Push the first tag only after step 3: a release without `SHA256SUMS.sig`
cannot update the builds that know the key.
