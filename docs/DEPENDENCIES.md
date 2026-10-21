# Dependencies

What Zen is built on, what each part is used for, and under which licence.
Zen itself is GPL-3.0-only with additional terms ([LICENSE](../LICENSE),
[NOTICE](../NOTICE)); every component below allows distribution as part of
it. The full licence texts: [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md),
`assets/licenses/` and, in the app, **About → Licenses and thanks**.

Versions: Flutter **3.47.1** (Dart 3.11), Go from
[`native/yggdrasil_bridge/go.mod`](../native/yggdrasil_bridge/go.mod)
(**1.26**), Yggdrasil **0.5.14**. Exact package versions are in
`pubspec.lock` and `go.sum`.

## How the parts fit

| Part | Language | Role |
|---|---|---|
| The app (`lib/`) | Dart, Flutter | everything you see, the features, storage, most of the protocol |
| The network bridge (`native/yggdrasil_bridge`) | Go, built as a native library | the Yggdrasil node, the post-quantum session layer, ML-KEM and ML-DSA, the call relay, doors, local links, public peer checks |
| Platform code (`android/`, `ios/`, `macos/`, `windows/`, `linux/`) | Kotlin, Swift, C++ | what only the system can do: Bluetooth, Wi-Fi Direct, keystores, video compression, location, call screens |

The app calls the bridge through `dart:ffi` (a C interface). All
post-quantum cryptography lives in the bridge, from Go's standard library,
so every platform uses the same code.

## Flutter and Dart packages

| Package | Used for | Licence |
|---|---|---|
| Flutter SDK, `flutter_localizations`, `intl` | the interface; 21 languages, dates and numbers | BSD-3-Clause |
| `flutter_riverpod` | app state | MIT |
| `ffi` | calling the Go bridge | BSD-3-Clause |
| `cryptography` | X25519, Ed25519, AES-GCM, ChaCha20-Poly1305, HKDF, HMAC, Argon2id in Dart | Apache-2.0 |
| `crypto` | SHA-256 and HMAC | BSD-3-Clause |
| `flutter_secure_storage` | the system keystore (Keychain, Android Keystore, libsecret, Windows credentials) | BSD-3-Clause |
| `local_auth` | the biometric prompt | BSD-3-Clause |
| `flutter_webrtc` (1.6.2) | audio and video calls, screen sharing, frame encryption | MIT (libwebrtc: BSD-3-Clause) |
| `flutter_local_notifications` | notifications | BSD-3-Clause |
| `flutter_foreground_task` | the Android background service | MIT |
| `app_links` | `zen://` and invitation links | Apache-2.0 |
| `path_provider` | app folders | BSD-3-Clause |
| `file_picker`, `image_picker` | choosing files and photos | MIT, BSD-3-Clause |
| `camera`, `camera_windows` | recording in the Videos section (Android, iOS, Windows; macOS and Linux use Zen's own bridges) | BSD-3-Clause |
| `image` | decoding and re-saving every received photo | MIT |
| `video_player`, `video_player_platform_interface`, `video_player_win` | playing videos (Linux has Zen's own GStreamer backend) | BSD-3-Clause |
| `record` | voice notes, alarm clips | BSD-3-Clause |
| `qr_flutter` | drawing QR codes | BSD-3-Clause |
| `qr_code_dart_scan`, `zxing_lib` | scanning QR codes (phones: its camera view; computers: the films' camera with the same decoder) | MIT, Apache-2.0 |
| `zstandard` | compressing signals and attachments | BSD-3-Clause (libzstd) |
| `mime` | recognising file types | BSD-3-Clause |
| `dbus` | BlueZ on Linux, for Bluetooth links | MPL-2.0 |
| `system_tray`, `window_manager` | the tray icon and the window on computers (full screen graph) | MIT |

Development only: `flutter_test`, `integration_test`, `flutter_lints`.
`dart run tool/check_licenses.dart` checks the licence of every package in
`pubspec.lock`.

## Go modules (the network bridge)

| Module | Used for | Licence |
|---|---|---|
| Go standard library | HPKE with ML-KEM-768 + X25519 (`crypto/hpke`, `crypto/mlkem`), Ed25519, TLS 1.3 with X25519MLKEM768, HKDF, SHA-2/3 | BSD-3-Clause |
| `internal/mldsa` | ML-DSA-65 (FIPS 204), Go's own implementation copied unchanged until Go publishes `crypto/mldsa` | BSD-3-Clause |
| `github.com/yggdrasil-network/yggdrasil-go` | the mesh node | LGPL-3.0 with a static-linking exception |
| `github.com/Arceliar/ironwood`, `github.com/Arceliar/phony` | Yggdrasil's routing and actor libraries | MPL-2.0 |
| `golang.org/x/crypto` | ChaCha20-Poly1305 of the session layer | BSD-3-Clause |
| `golang.org/x/sys` | Bluetooth and Wi-Fi Direct system calls on Linux and Windows | BSD-3-Clause |
| `golang.org/x/net`, `golang.org/x/text` | networking helpers (indirect) | BSD-3-Clause |
| `github.com/quic-go/quic-go` | QUIC links and checking QUIC peers | MIT |
| `github.com/coder/websocket` | `ws://` and `wss://` links (indirect) | ISC |
| `github.com/klauspost/compress` | zstd for signals | BSD-3-Clause |
| `github.com/wlynxg/anet` | network interfaces on Android | BSD-3-Clause |
| `github.com/gologme/log` | Yggdrasil's logger | BSD-3-Clause |
| `github.com/hjson/hjson-go/v4` | Yggdrasil's configuration format (indirect) | MIT |
| `github.com/bits-and-blooms/bitset`, `bloom/v3` | used by Yggdrasil (indirect) | BSD-2/3-Clause |

`dart run tool/go_licenses.dart` regenerates `LICENSES-GO.txt` and
`assets/licenses/go/`.

## Native platform APIs

| Platform | What Zen uses |
|---|---|
| Android | Bluetooth LE advertising, scanning and GATT (Nearby, alarm wave, links); Wi-Fi Direct; Android Keystore and StrongBox; MediaCodec and MediaMuxer (video compression); the system location service (no Google Play services); a foreground service; `FLAG_SECURE`; the package installer (self-update); AndroidX Biometric; Tink (via `flutter_secure_storage`); AudioSwitch (via `flutter_webrtc`) |
| iOS | Multipeer Connectivity (offline links); Keychain; LocalAuthentication; AVAssetExportSession; Core Location; process integrity checks |
| macOS | Multipeer Connectivity; the Secure Enclave with Touch ID; Keychain; AVAssetExportSession; AVCaptureSession (the films' camera); Core Location; window capture protection |
| Windows | Media Foundation (video); WinRT Wi-Fi Direct and Bluetooth (RFCOMM); the TPM (Platform Crypto Provider) with Windows Hello; `WDA_EXCLUDEFROMCAPTURE`; the location API; heap and DLL-loading hardening |
| Linux | BlueZ over D-Bus; GStreamer (playback; decoding films, the camera and the microphone for the Videos section; a system AAC encoder when one is installed); OpenH264 and vo-aacenc (Zen's own H.264 and AAC encoders, built from source with the app); ffmpeg when installed (a fallback decoder); libsecret (GNOME Keyring or KWallet); libayatana-appindicator (tray); GTK |

System libraries keep their own licences (LGPL-2.1+ for GTK, GLib,
GStreamer and libsecret; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)).

OpenH264 (BSD-2-Clause) and vo-aacenc (Apache-2.0) are the native libraries
Zen builds from source for Linux (`linux/runner/CMakeLists.txt`): the release
tarballs of `ZEN_OPENH264_VERSION` and `ZEN_VOAAC_VERSION`, compiled without
assembly and linked statically. Their SHA-256 is checked when
`ZEN_OPENH264_SHA256` / `ZEN_VOAAC_SHA256` are set (CMake cache entries, or
environment variables of those names for `flutter build`); record them once
with `curl -sL <url> | sha256sum` (the URLs are in the CMake file).
Films on Linux are written by Zen's own MP4 writer (`zen_film_codec.cc`);
sound is copied when it is AAC and otherwise encoded by vo-aacenc (ffmpeg's
own encoder on the ffmpeg path), so it is lost only when it cannot even be
decoded (the app says so).

## Fonts, icons and sounds

- Fredoka, Hanken Grotesk, JetBrains Mono, Space Mono, DM Sans: SIL Open Font
  License 1.1.
- Material Icons: Apache-2.0.
- Zen's sounds are synthesised from scratch by `tool/sounds/generate_sounds.py`
  (no recorded samples); the logo and screenshots are Zen's own.

## Services used at run time

Zen has no servers. These outside services are used, and their terms apply:

| Service | When |
|---|---|
| Public Yggdrasil peers | joining the mesh ([editable](guide/settings-and-peers.md#public-peers)) |
| GitHub | checking for and downloading updates |
| KLIPY | GIF search, only when you use it |
| Quad9, Cloudflare, Google Public DNS over TLS | name lookups, only when the system resolver does not work |
| OpenStreetMap | opening a shared location in the browser |
