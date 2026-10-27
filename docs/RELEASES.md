# Releases, signing and publishing

How to release Zen on GitHub, what to sign with, how to check that a file is
official, which channels to distribute it through (section 4, section 6: Android developer
verification, stores, iPhone, costs and plan) and what to do about updates
over the network.

UI strings quoted below are the app's English labels ("Pass it on" is the
in-app way of handing Zen to a friend).

- **Repository:** https://github.com/robertostrowskijagoda/Zen
- **Website:** the human-facing page is the repository `README.md`. The only
  file on GitHub Pages is the invitation page (`tool/pages/index.html`,
  workflow `pages.yml`); it opens Zen with the code from a QR code or shows
  the download links.
- **Android package:** `com.roj.zen`.
- **License:** `LICENSE` — GPL-3.0-only (the unmodified GNU text), with
  additional terms under GPL section 7 in `NOTICE`: copies keep the author
  attribution "Zen by Robert Ostrowski-Jagoda" ("Based on Zen by …" in a
  modified version) among the legal notices in the About screen; modified
  versions are marked as modified, use a clearly different name, icon and
  application ID, and are never passed off as official; no trademark rights.
  The donation link is not a licence condition (NOTICE, section 2).
  Repository and distribution builds of a release may keep the name (NOTICE,
  section 5). Every release ships `LICENSE` and `NOTICE`.

## 1. Repository

1. Before pushing, check `git status` and the history: `android/key.properties`,
   `*.jks` / `*.keystore` files, `maintainer.key` and `scratch/` must not be
   there (they are in `.gitignore`; also check
   `git log --all -- android/key.properties`).
2. **Invitation QR codes** lead to
   `https://robertostrowskijagoda.github.io/Zen/#CODE` (the code without
   dashes, after the `#`; the browser does not send that part to the server,
   so nobody knows who invites whom). The page opens Zen with the code, and
   whoever does not have Zen sees download buttons. Every web address of the
   project is in one place, `lib/src/app/zen_web.dart`; renaming the
   repository or the account breaks printed codes. **An own domain** is
   prepared there: set `kZenOwnDomain` (the pages must already be served
   there and the GitHub Pages address must keep answering) and add the host
   to the invitation link filter in `android/app/src/main/AndroidManifest.xml`,
   **before** the first public invitation or door sticker. New links then
   use the domain, and every build reads both addresses.

   **Publishing the page:** the workflow `.github/workflows/pages.yml`
   publishes `tool/pages/` on every change to `main`. Once in GitHub:
   **Settings → Pages → Source: GitHub Actions**. On the free plan GitHub
   Pages works only for **public** repositories.
3. Enable Issues in the repository settings; description: "A network of people
   who know each other — a messenger without servers, ads or an algorithm".
4. **Contributions:** `CONTRIBUTING.md` (checks to run, and the contributor
   licence grant: GPL-3.0-only for everyone plus an additional licence to
   the maintainer that allows store distribution, with the promise that
   every such version is also published as GPL source) and
   `.github/pull_request_template.md` with a required consent box. The
   grant is to be reviewed by a lawyer before the first outside
   contribution is merged.

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
4. **Certificate fingerprint** (paste it into the README section "Isn't it a
   virus? How to check" and into the description of every release):
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
   --write`. Without `--write` it only prints the line ready to paste. With
   `--pinned` it fails unless the APKs are signed with a certificate in
   `kOfficialApkCertificatesSha256`; the tag build runs it on all three APKs.
   The pinned lists are read without comments, and an entry that is not a
   plain string literal is an error. (Reading
   APK certificates is pure Dart, `apk_signing_block.dart`, shared by the app
   and the tool.)

Android does not let an app be overwritten by one signed with a different
key, so every release must be signed with this key.

## 3. Release step by step

> **Don't forget "What's new".** Before you cut a release, open
> `CHANGELOG.md` and write the `### What's new` block under
> `## Unreleased`: one to three short lines in English and the same in
> Polish, saying what people will notice in this version. The app shows
> them with the update notice. If the block is missing, `release.dart
> prepare` stops and tells you. Section 3.5 has the details.

**In short** (the details follow in items 1–7):

1. Make sure `main` is green in CI and the "Unreleased" part of
   `CHANGELOG.md` says what is new, with the short `### What's new` block
   in English and Polish that the app shows with the update notice
   (section 3.5). For **1.12.0 only**: run
   `flutter test test/format_fixtures_test.dart` once outside CI (or with
   `ZEN_WRITE_FORMAT_FIXTURES=1`) and commit `test/fixtures/formats/1.12.0/`
   — the samples of every stored and sent format that later versions must
   still read. Never change those files afterwards; in CI a missing sample
   fails the test.
2. `git switch -c release-1.12.0` (from a clean, up-to-date `main`), then
   `dart run tool/release.dart prepare 1.12.0`. It runs
   `dart format`, `flutter analyze`, `flutter test` and `go test`
   (`--skip-checks` skips them when CI already ran them on this commit),
   checks that `release.yml` makes every file the app updates from under
   exactly the names the app asks for (`tool/release_contract.dart`; also
   `dart run tool/release.dart check`, which CI runs), writes the version
   and the next build number into `pubspec.yaml`,
   `lib/src/app/app_version.dart` and the Linux AppStream metadata (Android,
   iOS, macOS and Windows take them from `pubspec.yaml`), turns "Unreleased"
   into "1.12.0 — <date>", commits, and makes the annotated tag `v1.12.0`.
   It never pushes. `--build N` picks the build number, `--no-tag` stops
   before the commit. It refuses while `kReleaseMaintainers` or
   `kOfficialApkCertificatesSha256` is empty; `--allow-unpinned-keys` is
   only for a test release (with a loud warning) and does not get past CI:
   a tag run stops at once while either list is empty
   (`dart run tool/release.dart pinned`).
3. `git push origin HEAD`, open a pull request to `main` (changes reach
   `main` only through pull requests), wait for green CI and merge it with
   a merge commit (not squash or rebase: the tag must stay on a commit of
   `main`). Then `git push origin v1.12.0`. Approve the `release`
   environment when GitHub asks (the APK key and the signing key).
   `release.yml` refuses a tag that differs from the version in
   `pubspec.yaml` / `app_version.dart` (otherwise every build would keep
   offering the release as an update).
4. When the draft release is complete, download its files into one folder
   and check them as the app will:
   `dart run tool/release.dart verify <folder> --version 1.12.0
   --require-signature` (names, `SHA256SUMS` against every file, the format
   and the signatures of `SHA256SUMS.sig`; signatures need Go). The GitHub
   JSON of the draft can be checked too: `--github-json release.json`.
5. Before publishing, upload `Zen-Windows.zip`, `Zen-Windows-arm64.zip` and
   `yggdrasil_bridge.dll` to VirusTotal. Report every Microsoft detection at
   https://www.microsoft.com/wdsi/filesubmission (Software developer →
   Incorrectly detected) and other vendors' through their forms; publish
   only when Defender no longer flags the files.
6. A release that breaks compatibility with older builds: raise
   `kMinPeerVersion` (`lib/src/app/peer_version.dart`, sent as `minv` in
   ping and pong) and/or put a line `zen-min: X.Y.Z` in the release
   description; older builds then show "update to X.Y.Z or newer".
7. Publish the draft as a full release: not a pre-release, with "Set as
   the latest release" ticked (the app asks only for `releases/latest`,
   which never shows a draft or a pre-release). This starts `pages.yml`,
   which refreshes the install page data and the SideStore / AltStore
   source (`apps.json`) for the new `Zen-unsigned.ipa`. A running app
   finds the release within an hour, and at once when it starts or comes
   back to the screen an hour or more after its last check; an Android
   phone that receives in the background finds it within about 4 to 5
   hours also while Zen is closed (Doze can put that off to its next
   window). A phone whose friend already runs the new version asks GitHub
   as soon as that friend's version reaches it (section 8.5).

The checks behind it: `test/release_contract_test.dart` (the app's file
names, the workflow, the version) and `test/github_release_e2e_test.dart`
(a release built like `release.yml`, served as GitHub serves it, updates
every platform; a changed file, a changed `SHA256SUMS`, a foreign key or an
older signed version installs nothing); `tool/ci/test_release_source.py`
(the source and the install page links).

1. **Version number:** `version:` in `pubspec.yaml` and `kAppVersion`
   / `kAppBuild` in `lib/src/app/app_version.dart` (a test checks that they
   match); the same number in the CHANGELOG heading and in the tag. The build
   number (`versionCode`) must increase. `tool/release.dart prepare` writes
   all of them.
2. **Go bridge** builds itself (section 3.1): `flutter build apk`, `windows`,
   `linux`, `macos` and `ios` rebuild it only when its sources changed. After
   changing `go.mod` (e.g. a new Yggdrasil version) refresh the licenses:
   `dart run tool/go_licenses.dart` (the test `go_licenses_test.dart` reminds
   you).
3. **Building:** pushing a tag `v<version>` runs
   `.github/workflows/release.yml`: Android (a separate job) and Windows x64
   on `windows-latest`, Windows ARM64 on `windows-11-arm`, Linux x64 on
   `ubuntu-22.04`, Linux ARM64 on `ubuntu-22.04-arm` (section 3.4), the
   Flatpak, checksums, signing and attaching on `ubuntu-24.04`, macOS on
   `macos-latest` and iPhone (`ios.yml`, called from `release.yml`). No
   Linux job uses the moving `ubuntu-latest` label. Each job
   stores its files as an artifact; the second-to-last job gathers them and
   computes `SHA256SUMS`, and the last one attaches everything to the draft
   release. The APK signing key is in the secrets of the **`release`
   environment** (Settings → Environments; not the repository secrets):
   `ANDROID_KEYSTORE_BASE64` (the `.jks` file in base64),
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`
   — without them the workflow skips the APKs — and
   `ZEN_RELEASE_SIGNING_KEY`, the release signing key that signs
   `SHA256SUMS` (section 8.6; without it `SHA256SUMS.sig` is left out with a
   warning). Only the `android` and `sign` jobs use the environment. It
   requires an approver (the maintainer) and has a rule for `v*` tags
   only; the keys go only to a run of a `v*` tag after approval (described
   at the top of `release.yml`). The workflow's token is read-only
   (`permissions: {}` at the top, `contents: read` per job); only the
   `attach` job, for tags, may write. The `checksums` job, which has no
   environment, fails the run when any signing secret
   (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
   `ANDROID_KEY_PASSWORD`, `ZEN_RELEASE_SIGNING_KEY`) is also visible as a
   repository or organization secret: the keys must live only in the
   environment. Environments with required reviewers are free for public
   repositories. A manual run from a branch builds the other files as
   artifacts, without the APKs and without a release. **Windows ARM64 is
   experimental:** the `windows-arm64` job has `continue-on-error`, and until
   its first green run a failure leaves out only `Zen-Windows-arm64.zip`;
   `SHA256SUMS` is computed without it. Locally:
   `flutter build apk|windows|linux|macos --release` (requirements: README,
   "Building from source").
4. **Files under exactly these names** (what `release.yml` produces):
   - `Zen-arm64-v8a.apk`, `Zen-armeabi-v7a.apk`, `Zen-x86_64.apk` — one APK
     per ABI (`flutter build apk --release --split-per-abi`, from
     `build/app/outputs/flutter-apk/app-<abi>-release.apk`): arm64-v8a for
     most phones, armeabi-v7a for older 32-bit phones, x86_64 for
     Chromebooks and emulators; no universal APK and no x86 (Flutter has no
     x86 release engine);
   - `Zen-Windows.zip` — the folder `build/windows/x64/runner/Release`
     zipped as `Zen\` with a `zen-app.marker` (`zen-app 1`, then the name of
     every file in the folder; the in-place update swaps a folder only when
     it matches its marker, otherwise it saves the archive to Downloads),
     with the Microsoft Visual C++
     runtime (`msvcp140*.dll`, `vcruntime140*.dll`) copied next to
     `zen.exe` by `tool/ci/copy_vc_runtime.ps1` from the Visual Studio
     redistributable folder; `tool/ci/check_windows_bundle.py` reads the
     import tables of every `.exe`/`.dll` and fails when one needs a runtime
     library that is not in the folder;
   - `Zen-Windows-arm64.zip` — the folder
     `build/windows/arm64/runner/Release` as `Zen\` with its marker
     (experimental, see item 3);
   - `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz` — the folder
     `build/linux/<x64|arm64>/release/bundle` as `Zen/` with its
     `zen-app.marker` (started with
     `Zen/zen`; includes `install-desktop-entry.sh`, which adds the menu entry
     and `zen://` links for the current user);
   - `Zen-Linux-x64.deb`, `Zen-Linux-arm64.deb` — the same bundle packaged by
     `linux/packaging/build_deb.sh` (`/opt/zen`, `/usr/bin/zen`, `.desktop`
     file, AppStream; dependencies from `dpkg-shlibdeps`; AAC/H.264 playback
     needs `gstreamer1.0-libav`, a recommended dependency);
   - `Zen-Linux-x64.flatpak` — the x64 bundle above packaged by the `flatpak`
     job with `linux/packaging/com.roj.zen.yml` (a repackaging of the built
     `Zen-Linux-x64.tar.gz`, not a build from source; runtime
     `org.gnome.Platform` 51, which is based on `org.freedesktop.Platform`
     and adds GTK 3 — raise it with every GNOME release, March and
     September; `libayatana-appindicator3` and its libraries are copied
     from the runner into the package; the bundle names the Flathub
     repository for the runtime). Sandbox: network, Wayland/X11,
     PulseAudio, all devices (camera), secret service, notifications, tray.
     Install and update: `flatpak install --user ./Zen-Linux-x64.flatpak`
     (inside the Flatpak the app does not download updates, it shows this
     command and the release page). Not on Flathub (that needs a
     from-source build); ARM64 is not built;
   - `Zen-macOS.zip` — `build/macos/Build/Products/Release/Zen.app` packed with
     `ditto -c -k --keepParent` (universal: Apple Silicon and Intel;
     ad hoc signature, no notarization — on first launch use "Open Anyway"
     in System Settings → Privacy & Security);
   - `Zen-unsigned.ipa` — from the "iOS" workflow;
   - `LICENSES-GO.txt` — `native/yggdrasil_bridge/LICENSES-GO.txt` (licenses
     of the Go modules in the bridge; they are also in the app: "About →
     Licenses", next to `zen.exe` in the ZIPs and next to `zen` in the Linux
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
   `build/app/outputs/app-store-only/`; the app is the same as everywhere
   (no self-update, no APK handing, no icon camouflage). Never
   attach them to a GitHub release or hand them to people to sideload.

   The README links to `…/releases/latest/download/Zen-arm64-v8a.apk`,
   `…/releases/latest/download/Zen-Windows.zip`
   and `…/releases/latest/download/Zen-unsigned.ipa`, so fixed names always
   give the newest version in one click (likewise the other two APKs,
   `Zen-Windows-arm64.zip`,
   `Zen-Linux-x64.tar.gz`, `Zen-Linux-arm64.tar.gz`, the `.deb` files, `Zen-Linux-x64.flatpak` and
   `Zen-macOS.zip`).
5. **Checksums:** `SHA256SUMS` is computed by the last-but-one job of
   `release.yml` over all release files (`sha256sum` format; check with
   `sha256sum -c SHA256SUMS`, on Windows
   `Get-FileHash -Algorithm SHA256 Zen-arm64-v8a.apk`). Anyone may redistribute copies, and the
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
7. **Verification:** `dart run tool/release.dart verify` on the downloaded
   files (step 4 above), then download from `releases/latest/download/`,
   compare the sum, `apksigner verify --print-certs Zen-<abi>.apk` for each
   APK (fingerprint as in the README), install on a clean phone and run on
   Windows, Linux and Mac.

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
  `flutter build apk` for all three (the script reads `ZEN_ANDROID_ABIS`).
  Releases are split per ABI (`--split-per-abi`), so each APK carries the
  libraries of one ABI only; there is no universal APK. The self-update
  downloads the APK of the phone's own ABI, and "Pass it on" hands over the
  APK installed on the phone. CI (`android-bridge` in `ci.yml`) builds
  all three ABIs and checks the `YggStartNode` export.
- **16 KB memory pages:** the build scripts link every ABI with
  `-Wl,-z,max-page-size=16384`, and `tool/ci/check_page_alignment.py` checks
  that every 64-bit `.so` has all its `PT_LOAD` segments aligned to at least
  16 KB and that in the APK each uncompressed `.so` starts on a 16 KB
  boundary (as `zipalign -P 16`). CI runs it on the bridge, the release job
  on every finished APK. `bridge_tools.ps1` picks the newest NDK by
  version number, not by name.
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
Scarlet, SideStore or AltStore sign it on the phone (README, section
"iPhone"; the install page links `releases/latest/download/Zen-unsigned.ipa`,
which follows every release). App identifier: `com.roj.zen`. iOS 15+. Locally on a Mac:
`build_ios.sh`, then `flutter build ios --release --no-codesign`.

### 3.4. Build checks, pins and reproducibility

- **Linux baseline.** Linux is built on Ubuntu 22.04 (glibc 2.35, libstdc++
  3.4.30), so the files run on Ubuntu 22.04+, Debian 12+ and Linux Mint 21+.
  `tool/ci/check_linux_abi.sh <bundle> 2.35 3.4.30` reads every ELF file
  with `objdump -T` and fails when one needs a newer `GLIBC_` or
  `GLIBCXX_` symbol (release, both architectures, and CI). The CI job
  `deb-install` installs the CI `.deb` (`--no-install-recommends`) in
  `ubuntu:22.04`, `ubuntu:24.04`, `ubuntu:26.04`, `debian:12` and
  `debian:13` containers and checks `ldd` for missing libraries, which also
  proves that the `t64` library names of newer systems satisfy the
  dependencies. The `.desktop` and AppStream checks run in the `packaging`
  job (Ubuntu 24.04). **GitHub retires the `ubuntu-22.04` images in April
  2027** (with brownouts before): by then move the Linux jobs into an
  `ubuntu:22.04` / `debian:12` container, or raise the baseline together
  with the README.
- **libwebrtc.** `flutter_webrtc` downloads the prebuilt libwebrtc for
  Windows and Linux (`libwebrtc.m150.7871.03`) without a checksum of its
  own. `tool/ci/check_libwebrtc.py <platform> <bundle>` hashes the library
  in the finished bundle and the downloaded ZIP and compares them with
  `tool/ci/libwebrtc.sha256` (`<sha256>  <version>/<platform>/<file>`): a
  difference fails the build. In CI a missing pin only warns and prints the
  line to paste; `release.yml` runs it with `--strict`, so a release fails
  without pins. After every `flutter_webrtc` bump that changes the
  libwebrtc version, add the new lines (compare the ZIP's sum with one
  downloaded independently from the webrtc-sdk/libwebrtc release). Tests: `tool/ci/test_check_libwebrtc.py`.
- **WebRTC-SDK (iOS, macOS).** CocoaPods downloads `WebRTC-SDK`
  (150.7871.01) as a prebuilt `WebRTC.xcframework`.
  `tool/ci/check_webrtc_sdk.py` hashes the framework tree and compares it
  with `tool/ci/webrtc_sdk.sha256`; a normal build only warns, a tag build
  (`--strict`) fails without a pin. The pin is taken from the official zip
  named in the podspec (`--hash WebRTC.xcframework`). The builds also check
  that the pods match the committed `ios/Podfile.lock` / `macos/Podfile.lock`
  and upload the lock they made (artifacts `podfile-lock-ios`,
  `podfile-lock-macos`). Add a new line after every `flutter_webrtc` bump.
  `release.dart prepare` refuses while native pins are missing
  (`--allow-unpinned-native` only for a test release). Tests:
  `tool/ci/test_check_webrtc_sdk.py`.
- **Go.** `go.mod` has a `toolchain` line (go1.26.10, the latest 1.26
  security fix); `actions/setup-go` with `go-version-file` takes it, and
  `ios.yml` reads it too. Dependabot does not raise `toolchain`: bump it by
  hand with every Go 1.26.x release. The CI job `govulncheck`
  (`golang.org/x/vuln/cmd/govulncheck`, pinned version) reports known
  vulnerabilities in the bridge's modules and in Go itself; it turns CI red
  until the module or toolchain is raised.
- **Dependencies locked.** Every `flutter pub get` in `ci.yml`,
  `release.yml` and `ios.yml` uses `--enforce-lockfile`: exactly the
  packages and hashes of `pubspec.lock`.
- **Reproducible:** the Linux `.tar.gz` and `.deb` (`SOURCE_DATE_EPOCH` =
  the commit's time, sorted names, no owners, `gzip -n`), the Dart
  dependencies (lockfile with hashes) and Go (`-trimpath`, the toolchain
  from `go.mod`). **Not reproducible:** the Windows and macOS ZIPs (file
  times), the macOS ad hoc signature and the APK (signature). Check: build
  the same tag twice and compare with `sha256sum`. Full reproducibility
  (F-Droid) would also need reproducible Flutter and Go builds.
- Python tests of these tools run in CI: `tool/ci/test_ci_checks.py` (ELF and
  APK alignment, PE imports, glibc, pinned runners, the environment),
  `tool/ci/test_release_source.py`, `tool/ci/test_check_libwebrtc.py`.

### 3.5. What's new (the note in the update notice)

The update notification, the banner across the top of the app and the card
in "Updates and Pass it on" show a short note about the new version under
"New version X is available". It is not the changelog: it is written for
people who use Zen, in a few words, in English and Polish.

Write it in `CHANGELOG.md` under `## Unreleased`, as its own block:

```
## Unreleased

### What's new
- [en] Messages reach you even when Zen is closed or locked.
- [en] See whether a friend has Zen open, in the background or offline.
- [pl] Wiadomości docierają nawet przy zamkniętym lub zablokowanym Zen.
- [pl] Widzisz, czy znajomy ma Zen otwarty, w tle czy offline.

### Messages
- (the usual, detailed changelog entries)
```

Rules (`tool/release.dart` checks them):

- Every line of the block is `- [xx] Text`, where `xx` is a two-letter
  language code of the app (`en`, `pl`, `de`, …). Blank lines are allowed;
  the block ends at the next heading.
- **English is required** (1 to 3 lines). Every other language is
  optional, also up to 3 lines. The app shows the lines of its own
  language and falls back to the English ones, so write Polish too; other
  languages only when someone translated them.
- Each line is at most 160 characters of **plain text**: no links (`http`,
  `://`, `www.`) or anything that looks like a domain (`example.org`: put
  a space after every full stop), no invisible format marks (such as the
  ones that turn text right to left), no Markdown or HTML (`*`, `` ` ``,
  `<`, `>`, `[`, `]`).
  The app shows each line as one bullet, cut after two rows, and never
  makes anything in it clickable.
- Say what a person notices ("Messages reach you even when Zen is
  closed"), not how it was done. One change per line, the biggest first.

How it travels:

1. `dart run tool/release.dart prepare X.Y.Z` refuses while the block is
   missing or breaks a rule, prints the lines it found and moves them with
   the rest of "Unreleased" under `## X.Y.Z — <date>`.
   `dart run tool/release.dart check` (CI, every push) checks a block
   already written under "Unreleased"; `dart run tool/release.dart
   whats-new` prints the file it would make.
2. On the tag, the `checksums` job of `release.yml` runs
   `dart run tool/release.dart whats-new --version X.Y.Z --out
   dist/whats-new.json` before it computes `SHA256SUMS`: the note is one of
   the release files, listed in `SHA256SUMS` and so signed in
   `SHA256SUMS.sig` with all the others. The draft release's description
   starts with the English lines.
3. `whats-new.json` is
   `{"t": "zen_whats_new", "app": "zen", "version": "X.Y.Z", "lines":
   {"en": ["…"], "pl": ["…"]}}` (`lib/src/features/update/whats_new.dart`).
   When a check finds the new version, the app fetches the note (from
   `github.com/…/releases/download/`, not the API, so it costs nothing of
   GitHub's rate limit) and shows it only when it is this version's note
   and `SHA256SUMS.sig` signs it with a key in `kReleaseMaintainers` (with
   no key pinned: when the release's `SHA256SUMS` lists it). A missing or
   refused note only leaves the notice without it.

It is a file of its own, not a field of `SHA256SUMS.sig`: builds up to
1.12.1 read that file strictly (exactly four fields), and a new field there
would stop them from updating themselves.

## 4. Android: developer verification (2026–2027)

State as of 15.10.2026 (sources: section 6.6):

- On **certified** phones (with Google services) only apps whose package and
  signing key were registered by a verified developer will be installable and
  updatable — regardless of where the file comes from (store, browser, "Pass
  it on", self-update).
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
  for "Pass it on" offline).

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
   installing through "Pass it on" without internet; if it needs a network,
   say so on the "Pass it on" screen.

## 5. How to check that a file is official

- **Certificate fingerprint** and **`SHA256SUMS`** with every release and in
  the README.
- User: downloads only from the repository (the address starts with
  `github.com/robertostrowskijagoda/`) or from a friend via "Pass it on"; may
  upload the file to virustotal.com; Android scans the app on install; the
  same signing key means a fake will not install "over" the real Zen.
- In the app: pinned fingerprint, "Official copy"
  in About, a red warning for every APK with a mismatching signature
  or sum, and a **signed manifest** with the donation link, author and
  repository (section 8.2) and a canary (section 8.3).
- **Windows:** no Authenticode signature today, so SmartScreen shows "Windows
  protected your PC" (the README says what to click), and **Smart App
  Control** on Windows 11 blocks Zen with no "Run anyway" (the README and
  the install page explain turning it off, with its cost). Antivirus
  programs may flag new unsigned files (section 3, step 5).
  Zen-Windows-arm64.zip is the same. The lasting fix is code signing:
  SignPath Foundation (free for open-source projects; Zen is GPL-3.0) or
  Azure Trusted Signing.
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
| GitHub Releases | main channel | signed APKs, one per ABI (arm64-v8a, armeabi-v7a, x86_64), desktop packages, `SHA256SUMS`; from 2027 only with a registered package (section 4) |
| "Pass it on" in the app | works | hotspot, Wi-Fi, Quick Share, USB from a computer; from 2027 as above, possibly only once online |
| Obtainium | works, nothing to do | installs and updates straight from GitHub Releases; not a store — no review or license requirements. To do: a "Get it on Obtainium" button in the README and the key fingerprint to check (e.g. AppVerifier) |
| Own F-Droid repository | possible | `fdroidserver` → static files on GitHub Pages; an address or QR to add in F-Droid, Droid-ify, Neo Store; no review |
| F-Droid (main) and IzzyOnDroid | possible, not set up | the license meets their rule (FSF- or OSI-approved; the NOTICE terms stay within GPL section 7). What is needed, and what may slow F-Droid down: section 6.1.2. Such builds may keep the name and icon (`NOTICE`, section 5) |
| Google Play | possible, separate variant (section 6.2) | personal account USD 25; new personal account: closed test with at least 12 testers for 14 days, then a production application (~7 days); name, surname and country public; targetSdk 36 for new apps and updates |
| Samsung Galaxy Store | possible, same variant | no fees, manual review; from 30.09.2026 a store participating in Google verification |
| Huawei AppGallery | optional | Huawei phones without Google (Google verification does not apply); Zen uses no Google services — check on one phone |
| Accrescent | not now | console for invited developers only, no self-update, package ID must match the author's domain (uncertain — the page may be outdated) |
| Amazon, Aptoide, RuStore, Chinese stores | no | Amazon Appstore on Android closed since 20.08.2025; Aptoide — annual fee and a "piracy store" reputation; RuStore requires a VK ID, and VK is on the EU sanctions list (07.2026); China — ICP registration and a Chinese entity |
| iPhone: Scarlet (install page), SideStore / AltStore with a free Apple ID | works | `Zen-unsigned.ipa`; signing every 7 days, at most 3 apps, no background work |
| iPhone: TestFlight, AltStore PAL, App Store | needs a USD 99/year account | section 6.3 |
| Windows | x64 ZIP and experimental ARM64 ZIP, no Authenticode | later MSIX and winget (section 5) |
| Linux | `tar.gz` and `.deb`, x64 and ARM64 (Ubuntu 22.04+, Debian 12+, Mint 21+; glibc 2.35+); Flatpak (x64, repackaged bundle, attached to the release; not on Flathub) | AppImage and Snap optional; Flathub and Fedora would refuse the from-source OpenH264 (section 6.1.1) |
| macOS | ZIP with an ad hoc signature | Developer ID + notarization with the same account as iPhone (section 6.3); official Homebrew only after notarization |
| Repository mirror (e.g. Codeberg) | optional | in case GitHub is blocked; mirror addresses can be published in the signed manifest (section 8.2) |

"Open straight in the app" (Android App Links) requires a file
`/.well-known/assetlinks.json` at the domain root — the invitation page is in
the subdirectory `robertostrowskijagoda.github.io/Zen/`. So the QR code opens
the invitation page (section 1, item 2), which launches Zen through
`intent://` or `zen://`; Zen recognizes the same code in the scanner, and
after enabling "Open supported links" also links from the camera. An own
domain (section 1, item 2) would allow App Links later; it has to be set
before the first public invitations, because printed codes keep their
address.

#### 6.1.1 Video codec patents

On Linux Zen contains the H.264 encoder OpenH264, built from source; Cisco's
patent licence covers only the binaries Cisco itself distributes, so this
build is not covered by it. On Windows, macOS, iOS and Android Zen uses the
system's codecs. The practical risk is small (a free app; the AVC pool
charges no royalties up to 100,000 units a year; some patents have
expired), but Flathub and Fedora would not accept such a package: a Flathub
variant would have to download Cisco's binary on first use (as Firefox
does) or use the system's GStreamer encoder. AAC-LC (vo-aacenc): negligible
risk.

#### 6.1.2 F-Droid and IzzyOnDroid

State as of 22.10.2026; sources: section 6.6.

**License.** Both accept licenses approved by the FSF or the OSI.
GPL-3.0-only qualifies, and the `NOTICE` terms are only of the kinds GPL
section 7 permits: keeping the author's name among the legal notices (7(b)),
marking modified versions and not passing them off as the original (7(c)),
no trademark rights (7(e)), plus a permission for repository builds. The
donation link is deliberately **not** a condition: the FSF reads 7(b) as
covering the identification of authors and legal notices, not links to
other material, so a required donation link would be a "further
restriction" that anyone may remove — and a license with such a term looks
non-free to reviewers. Requiring a different name for modified versions is
allowed by the Debian Free Software Guidelines (item 4), and F-Droid itself
requires forks to change the application ID, name and icon. In F-Droid
metadata: `License: GPL-3.0-only`. The contributor licence grant in
`CONTRIBUTING.md` binds only contributors and does not change the license
anyone receives Zen under. To be reviewed by a lawyer before the first
submission, together with the grant.

**What the code already meets:** no Google Play services, Firebase,
Crashlytics, ML Kit or other proprietary library (QR codes: zxing in pure
Dart; location: Android's own `LocationManager`; biometrics: AndroidX); no
tracker or analytics; no prebuilt binaries in the repository (the Go bridge
and `jniLibs` are built from source); fonts under the SIL OFL, Material
Icons under Apache-2.0, sounds generated by a script, logo and icons under
GPL-3.0 — so no "NonFreeAssets".

**F-Droid (builds from source and signs with its own key):**

| Item | What to do | Effort |
|---|---|---|
| Build recipe | a merge request to `fdroiddata` with `metadata/com.roj.zen.yml`: Flutter from the `flutter` srclib at the version in `pubspec.yaml`, Go 1.26 downloaded with a pinned SHA-256 (Debian's is older), the NDK; one build per ABI (`--split-per-abi --target-platform android-arm64`, `android-arm`, `android-x64`, each with its own `VercodeOperation`) | 1–2 days, including a local `fdroid build` run |
| Self-update | build the store variant: `flutter build apk --release --flavor appStoreOnly` (or `--dart-define=ZEN_STORE=true`). It has no GitHub update check, no APK sharing, no `REQUEST_INSTALL_PACKAGES`, and it skips the "re-signed copy" check, which would otherwise flag F-Droid's signature and block wallet transfers. The app then says it is updated by the store it came from. This is a build option Zen provides, so the build counts as unmodified (NOTICE, section 5) | none (optional: a separate `ZEN_DISTRIBUTION=fdroid` define so About can say "F-Droid build", about half a day) |
| WebRTC | `flutter_webrtc` pulls the prebuilt `io.github.webrtc-sdk:android` from Maven Central (BSD-3-Clause) and `com.github.davidliu:audioswitch` from JitPack (the build takes only
the `com.github.davidliu` group from JitPack). F-Droid accepts free libraries from trusted Maven repositories, but reviewers may ask for WebRTC to be built from source (F-Droid has discussed hosting its own WebRTC build) | none to days, depending on review; the slowest item |
| GIF search (KLIPY) | a proprietary network service, on by default (turned off in Settings → GIFs) — expect the `NonFreeNet` anti-feature in the metadata. Optional: a build define that turns GIF search off by default in the F-Droid build | metadata only (define: about 2 hours) |
| DNS fallback | only when the system resolver fails, the Go bridge asks Quad9, Cloudflare and Google Public DNS over TLS; say so in the description (not an anti-feature by itself) | none |
| Store listing | `fastlane/metadata/android/en-US/` (title, short and full description, screenshots, changelogs per `versionCode`) — F-Droid and IzzyOnDroid read it | 1–2 hours |
| Name and ID | F-Droid asks for an application ID based on a domain the developer controls (`roj.com` is not the author's) and for no trademark conflicts ("Zen" is a common word; other apps use it). Low risk: the ID is unique | — |

**IzzyOnDroid** (ships the APK from GitHub Releases, signed by the author):
APKs of **up to about 30 MB** each — the per-ABI APKs must fit, or ask for
an exception; the full (GitHub) build keeps its updater because the APK is
the author's own, but IzzyOnDroid requires that nothing executable is
downloaded without explicit, opt-in consent: Zen downloads an update only
after "Update" is pressed, and the automatic check against
api.github.com could be made a setting (about half a day) if the review
asks. No `android:debuggable`/`testOnly`. The request is an issue in
IzzyOnDroid's repository with the GitHub link.

**Debian, Flathub, other distributions:** the license fits (DFSG items 3, 4
and 8: modified versions may be required to carry a different name; NOTICE
section 5 gives the same permission to every distribution and to anyone
redistributing their builds). Practical blockers are not legal: Debian
does not package Flutter; Flathub would refuse the from-source OpenH264
(section 6.1.1). Inside a Flatpak Zen already downloads no updates.

### 6.2 Store variant of Android (Google Play, Galaxy Store)

Model: Signal — **the same package `com.roj.zen` and the same key**, two
flavors: `full` (the default; the full app with self-update, what GitHub
ships) and `appStoreOnly` without it (named so that nobody sideloads it by
accident: the files are called
`Zen-APP-STORE-ONLY-do-not-install-manually.*`); users move between channels without losing
data. Yggdrasil runs in Zen as a library, without `VpnService` (VPN would
require an organization account).

**The rule:** the store build is the same app as the GitHub build. It differs
only where the stores force it, in three places, and nothing else changes
(name, pyramid, wallet, dating, donation link and About are identical):

1. no self-update and no `REQUEST_INSTALL_PACKAGES` (self-update from
   outside Play is a hard violation of the Device and Network Abuse policy);
   the Updates screen says "Store updates";
2. "Pass it on" passes Zen on as a link (`--dart-define=ZEN_STORE_URL=…`,
   default: the project page), never as an APK;
3. no launcher disguise (the manifest in `src/appStoreOnly` removes the
   alias).

Because a store may sign the app with its own key (Play App Signing), the
store build also skips the check of its own signing certificate (`device_integrity.dart`); the other tamper
checks stay.

**How it is built:** `appFlavor == 'appStoreOnly'` or
`--dart-define=ZEN_STORE=true` (`lib/src/features/update/store_build.dart`).
Flavors are active only for a task with a flavor (`--flavor appStoreOnly|full`)
or with `-Pzen.flavors=true`, so a plain `flutter build apk` / `flutter run`
works unchanged. It is built by hand, not by `release.yml` (section 3 item 4):
`flutter build appbundle --release --flavor appStoreOnly`; the files land in
`build/app/outputs/app-store-only/`.

**Still to do** before publishing in a store (declarations and store
listing, not app changes):

1. background service: a declared type (`connectedDevice`; `phoneCall`,
   `camera`, `microphone` only during a call) instead of `specialUse`, and a
   video for reviewers. This is an explicit exception to "no store-only
   changes": a separate override in
   `android/app/src/appStoreOnly/AndroidManifest.xml`
   (`tools:replace="android:foregroundServiceType"`). Declarations also
   for the `mediaProjection` service type (screen sharing in a call; FGS
   declaration and a video) and `location` (foreground/background location
   declaration and a video);
1a. `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: Play allows it only for listed
   cases; justify it as a peer-to-peer messenger without a push server and
   fill in the form (risk of rejection). `SYSTEM_ALERT_WINDOW`: a
   declaration, or remove it in the store manifest with
   `tools:node="remove"`;
2. `USE_FULL_SCREEN_INTENT`: a "calls" declaration; the alarm asks for special
   access and has a fallback (a loud notification);
3. location only in the foreground or one background feature (alarm), with a
   clear disclosure; Bluetooth with `neverForLocation`, if true;
4. dating: declare the app 18+ ("Restrict Minor Access") in the Play Console;
5. the store listing explains that pyramid points have no monetary value,
   with a "no financial features" declaration (the rejection risk is an
   assessment, not a rule);
6. user content: terms before the first post (already the consent screen),
   a report contact (e-mail), a child safety (CSAE) page with a contact
   person, a moderation description;
7. targetSdk 36, AAB, privacy policy, Data safety (klipy.com too: queries and
   IP), IARC rating, instructions and a second account for the reviewer
   (Briar disappeared from Play in 2022 partly for lack of test data);
8. countries: Poland, the EU and English-speaking countries; without China,
   Russia, Belarus and sanctioned countries (the GitHub APK stays everywhere).

If a store rejects the identical app, the owner decides then; no store-only
changes are planned.

### 6.3 iPhone and Mac

- **No account** — as today: Scarlet (the install page's one recommended way:
  the install page links the stable `releases/latest/download/Zen-unsigned.ipa`,
  so it follows every release without editing the site), or SideStore /
  AltStore with a free Apple ID.
  `pages.yml` publishes the source `https://robertostrowskijagoda.github.io/Zen/apps.json`
  (`tool/ci/release_source.py`) for the latest published release's
  `Zen-unsigned.ipa`, and the install page `/install/`; publishing a release
  refreshes both (the release event starts a run on `main`, since the
  `github-pages` environment deploys only from it). The source is built from
  that release's own IPA: downloaded only from GitHub hosts, checked against
  the release's `SHA256SUMS` and size, and its permission texts, version and
  build number read from the IPA's `Info.plist` (fallback: `Info.plist` at
  the release tag; without either, a source with no app). A checksum
  mismatch stops the deployment. The install page data (`release.json`)
  carries the APK certificate fingerprint pinned in `apk_signature.dart` at
  the tag; the fingerprint of every released APK (from `apksigner`) must
  match it, or Pages is not deployed.
  The free Apple ID signature lasts 7 days; Zen reads its expiry date from
  the installed profile and reminds the user in Chats 2 days before.
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
    "anonymous chat", dating as a side feature, the donation link (allowed
    without restrictions only in the US store), in-app account deletion, an encryption
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
  CallKit) — Zen has none by design, so on iPhone it receives at once only
  while it is open (otherwise at short background checks iOS allows, or with
  an opt-in keep-alive: [IOS_BACKGROUND.md](IOS_BACKGROUND.md)); self-update and "Pass it on" are impossible. The Enterprise program
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
4. The `appStoreOnly` variant (section 6.2: built; the store declarations open) with the same
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
   with `docs/PROTOCOL.md` (protocol specification from the code); About links to the privacy
   policy and terms on GitHub.

In 2027:

- check installing without internet (hotspot, Bluetooth) on a phone with
  active verification; unregistered test builds — the advanced flow or ADB;
- watch: the date verification covers the EU, a possible European Commission
  decision, Google's "Registered App Stores" program outside the USA, the US
  Supreme Court ruling in Epic v. Apple (about 06.2027);
- a foundation, if the project grows (organization account, fee waiver → Web
  Distribution in the EU);
- F-Droid and IzzyOnDroid: possible since the GPL-3.0 license (section 6.1.2).

### 6.6 Sources

- Android developer verification:
  [guide](https://developer.android.com/developer-verification/guides),
  [FAQ](https://developer.android.com/developer-verification/guides/faq),
  [full distribution](https://developer.android.com/developer-verification/guides/full-distribution),
  [Android Authority 01.10.2026 — first wave](https://www.androidauthority.com/android-sideloading-developer-verification-first-wave-rollout-3717921/),
  [Android Authority 18.08.2026 — advanced flow](https://www.androidauthority.com/google-android-advanced-flow-sideloading-rollout-begins-3700073/).
- [F-Droid Inclusion Policy](https://f-droid.org/docs/Inclusion_Policy/),
  [F-Droid Anti-Features](https://f-droid.org/docs/Anti-Features/),
  [F-Droid: building WebRTC for apps](https://gitlab.com/fdroid/admin/-/issues/364),
  [IzzyOnDroid Inclusion Policy](https://izzyondroid.org/docs/general/AppInclusionPolicy/),
  [own F-Droid repository](https://f-droid.org/docs/Setup_an_F-Droid_App_Repo/),
  [Obtainium](https://github.com/ImranR98/Obtainium).
- License: [GPL-3.0 section 7](https://www.gnu.org/licenses/gpl-3.0.html#section7),
  [FSF: GPL-compliant reasonable legal notices and author attributions](https://www.fsf.org/blogs/community/gpl-compliant-legal-notices-author-attributions),
  [FSF: AGPL is not a tool for taking freedom away](https://www.fsf.org/blogs/licensing/agpl-is-not-a-tool-for-taking-freedom-away),
  [Debian Free Software Guidelines](https://www.debian.org/social_contract#guidelines).
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
  collection" within the meaning of the act. The store build keeps the
  donation link like every other build (section 6.2); if a store's review
  objects to it, the maintainer decides then.
- In the app the donation appears only in About (at the top), with no
  nagging elsewhere. Good practices: a clear goal, short reports.

## 8. Updates over the network (disabled)

The mechanism from V1.10 is in the code but **disabled**: the maintainer key
list `kReleaseMaintainers` in `lib/src/features/update/release.dart` holds
one key (the release signing key of section 8.6), fewer than the
`kReleaseThreshold` of 2 a network release needs, so the app accepts no
updates from the network: no releases, holds, canaries or signed donation
details from friends (`UpdateBook.enabled` is false). That one key is
enough for the GitHub update (section 8.6). We do not want maintainers
with separate keys; a proposed replacement (the same signing certificate +
a higher `versionCode` + 7 days + a human's consent) is still to be decided.
Even once enabled, a signed release starts to spread only from a device
that loaded it by hand (the app does not fetch `release.json` from GitHub
by itself).

How it works today (if the list were not empty): a release is accepted when at
least 2 of 3 maintainers signed it (hybrid Ed25519 + ML-DSA-65, both halves
must hold), 7 days passed since it was first
seen (any maintainer can hold it back in that time) and the human presses
"Install" themselves. Files travel over the network like any
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
**Settings → Updates and Pass it on → Load an update from a file**; the app checks the
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
loaded `release.json`), passes it on to friends and in "Updates and Pass it
on" shows a red warning ("This may not be the official Zen") when its own donation link, author or repository differ
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

Ping and pong to accepted friends carry `ver`, `build`, `caps` and `minv`,
the oldest version the sender still talks to (`kMinPeerVersion` in
`lib/src/app/peer_version.dart`). A build older than a friend's `minv` (or
than `zen-min` of the latest GitHub release) shows a red tile "This
version of Zen is no longer supported" above the bar below. When friends have a newer version, Settings
shows a quiet bar "Friends have a newer version of Zen (X)" leading to
"Updates and Pass it on", and the app asks GitHub at once whether that
version is published (section 8.5). The version is the
friend's own claim and affects nothing security-related. A signed release
marker spreading by gossip is not done.

### 8.5 Updates from GitHub (on)

Independent of section 8: every build except the store one asks
`api.github.com/repos/robertostrowskijagoda/Zen/releases/latest` (one GET,
only the User-Agent `Zen`;
`lib/src/features/update/github_update_service.dart`) whenever GitHub's
last answer is an hour old or older (`kGithubCheckEvery`): 20 s after
start, when the app comes back to the screen and every hour while it
stays open. On Android the background service
(`background_update_check.dart`, started in every mode of the service,
also while the app is locked) asks while Zen is closed once the last
answer is 4 h old (`kBackgroundGithubCheckEvery`): it rides the service's
shared wake as work that does not wake the phone in Doze, looks every hour
whether a check is due (one small file, `update_check.json`, which the app
and the service share, so whoever asked last counts) and asks at most once
in those 4 h. A friend whose ping or pong names a newer version than any
known here makes the app ask at once (once per version, not within 2
minutes of the last attempt): the friend's claim is unsigned, GitHub's
answer decides. A release that 2 maintainers signed, coming from friends
(section 8, off today), is announced at once. It sends `If-None-Match`
with the last `ETag`, so an unchanged answer (304) costs no rate limit.
At one request an hour per device, about 60 devices behind one address
(a mobile operator's shared IP) may meet GitHub's limit of 60 requests an
hour; the app then waits as GitHub asks. On an error it retries after
GitHub's `Retry-After` (or the `x-ratelimit-reset` time when
`x-ratelimit-remaining` is 0) plus a minute, otherwise after 15 min, 30,
60 (never later than the next regular check), and shows when; a good
answer clears the backoff. A 404 is its own state ("no published release
of Zen on GitHub"), not "up to date". A line `zen-min: X.Y.Z` in the
release description is the oldest version still supported (section 3,
step 6). A newer version is announced once with a quiet notification,
whichever of the app and the service finds it first, with the release's
short note (section 3.5) as its expanded text.
Inside a Flatpak nothing is downloaded: the card shows the
`flatpak install` command and opens the release page. A newer `v<version>`
tag shows the bar "New version X is available — worth updating" with
"Update": the platform's file from section 3 (`Zen-<abi>.apk` for the phone's
own ABI, `Zen-Windows.zip`,
`Zen-Windows-arm64.zip`, `Zen-Linux-<arch>.tar.gz` / `.deb` / `.flatpak`,
`Zen-macOS.zip`) is downloaded and must match the release's `SHA256SUMS` by
name and sum. Android: the APK must also be signed with the installed app's
certificate, then the system installer asks. Windows / Linux tar.gz / macOS:
unpacked next to the app's folder, a helper script swaps the folders after
Zen exits and starts the new version; where the folder is not writable
(Program Files, `/opt/zen`) the file is saved to Downloads and shown. iOS: only the bar. When github.com cannot be reached (network error,
TLS, timeout — not an HTTP error answer), "Updates" says "I can't check
for updates, GitHub is unavailable. Someone may be trying to block this
app."; the closable bar shows it only after a second failed attempt
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
with a bad signature or another version, nothing is installed. Builds since
1.12.0 pin one key, so every release needs `SHA256SUMS.sig` made with it
(the `ZEN_RELEASE_SIGNING_KEY` secret). A build with an empty list behaves
as in section 8.5 and "Updates and Pass it on" says that it cannot check
the author's signature yet. The notice itself never waits for the
signature: a newer tag is announced from the API's answer alone; only
installing (and showing the note of section 3.5) checks it.

`SHA256SUMS.sig` has the format of a signed release, like the canary (section 8.3):
`{"m": {"t": "zen_sums", "app": "zen", "version", "files": {name: sha256}},
"sigs": [{"k", "s"}]}` (hybrid id and hybrid signature, as in section 8). The
`sign` job of `release.yml` (with Go for the signature) makes it on every
`v*` tag with the environment secret **`ZEN_RELEASE_SIGNING_KEY`** (in the
`release` environment, so it waits for the same approval as the Android
job); without the secret it is skipped with a warning. The job then runs
`zen_release.dart verify --pinned`: a signature by a key that is not in
`kReleaseMaintainers` of the tagged app stops the run (every installed
computer would refuse such a release). By hand:

```
dart run tool/zen_release.dart sums-manifest --version 1.12.0 \
    --out SHA256SUMS.sig SHA256SUMS
dart run tool/zen_release.dart sign SHA256SUMS.sig ~/zen-release.key
dart run tool/zen_release.dart verify --pinned SHA256SUMS.sig
```

One-time steps for the maintainer:

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
