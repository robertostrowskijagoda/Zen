# Building from source

You always need [Flutter](https://docs.flutter.dev/get-started/install)
3.47.1 and [Go](https://go.dev/dl/) in the version from `native/yggdrasil_bridge/go.mod`
(its `toolchain` line; any Go from 1.21 on downloads that version by itself).
The Go network bridge builds itself on `flutter build` and `flutter run` — only
when its sources changed (details: [RELEASES.md](RELEASES.md), point 3.1).

| System | You need | Command |
|---|---|---|
| Android (one APK per ABI: arm64-v8a, armeabi-v7a, x86_64) | Android Studio (SDK and NDK), JDK 17 | `flutter build apk --release --split-per-abi` |
| Android for a store only (Google Play, Galaxy Store; the same app without self-update, APK handing and launcher disguise; the build writes `Zen-APP-STORE-ONLY-do-not-install-manually.aab` and `.apk` to `build/app/outputs/app-store-only/`; never install this build by hand) | as above | `flutter build appbundle --release --flavor appStoreOnly` |
| Windows | Visual Studio 2022 ("Desktop development with C++"), gcc for Go (e.g. Strawberry Perl) | `flutter build windows --release` |
| Windows on ARM (on an ARM64 computer) | as above, with ARM64 tools; for Go [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) instead of gcc | `flutter build windows --release` |
| Linux | packages below | `flutter build linux --release` |
| macOS | Xcode with command line tools, CocoaPods | `flutter build macos --release` |
| iPhone (on a Mac) | Xcode, CocoaPods | `flutter build ios --release --no-codesign` |

**Linux** (Ubuntu, Debian):

```
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev libsecret-1-dev libayatana-appindicator3-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libpulse-dev
```

The finished Zen is in `build/linux/x64/release/bundle/` (the `zen` file with the folders
`lib/` and `data/`; on ARM64 `build/linux/arm64/…`). The `.deb` package is made by
`linux/packaging/build_deb.sh`, the Flatpak by `linux/packaging/com.roj.zen.yml`
(see [RELEASES.md](RELEASES.md)). To work it needs a key service (GNOME Keyring or
KWallet — the encryption key lives there), for the tray icon
`libayatana-appindicator3-1` (in GNOME also the AppIndicator extensions) and for
playback GStreamer with plugins.

**macOS:** the app is `build/macos/Build/Products/Release/Zen.app` (Apple
Silicon and Intel, macOS 12 or newer). It is not sandboxed (App Sandbox) —
it runs system tools, e.g. `route` and `adb`; the reason is described
in `macos/Runner/Release.entitlements`.

The Linux build of CI runs in an Ubuntu 22.04 image with all of the above
(`ghcr.io/robertostrowskijagoda/zen-ci`, [TESTING.md](TESTING.md#6-github-actions));
with Docker it builds Zen for Linux on any computer:

```
docker run --rm -v "$PWD:/src" -w /src ghcr.io/robertostrowskijagoda/zen-ci:latest \
  sh -c 'flutter pub get --enforce-lockfile && flutter build linux --release'
```

Tests: `dart run tool/test.dart` runs all of them in parallel; the network
simulator, several apps on one computer, the end-to-end tests and CI are
described in [TESTING.md](TESTING.md). Signing and publishing a release:
[RELEASES.md](RELEASES.md). Before a pull request: [CONTRIBUTING.md](../CONTRIBUTING.md).
