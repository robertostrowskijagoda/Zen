# Third-party notices

Zen is licensed under GPL-3.0-only with additional terms ([LICENSE](LICENSE),
[NOTICE](NOTICE)). It is built with the components below, which keep their own
licences. All of them allow distribution as part of a GPL-3.0 program. Zen
uses no Google Play services: the location comes from each system's own
location service.

Where the full texts are:

| What | In the source code | In the app ("About → Licenses and thanks → Licenses") | Next to the desktop builds |
|---|---|---|---|
| Dart and Flutter packages, the Flutter engine | each package's `LICENSE` (pub cache) | yes, collected by Flutter | — |
| Go modules of the network bridge | `assets/licenses/go/`, `native/yggdrasil_bridge/LICENSES-GO.txt` (`tool/go_licenses.dart`) | yes | `LICENSES-GO.txt` |
| Fonts | `assets/licenses/fonts/OFL.txt` | yes | — |
| Native libraries, Material Icons, Zen's own sounds and images | `assets/licenses/native/` | yes | this file |

`dart run tool/check_licenses.dart` (after `flutter pub get`) checks the licence
of every Dart package; `dart run tool/go_licenses.dart` regenerates the Go texts.

## Dart and Flutter packages

The licence texts of every package in `pubspec.lock` are shown in the app by
Flutter itself. The direct dependencies:

| Package | Licence |
|---|---|
| Flutter SDK, flutter_localizations, intl, ffi, crypto, mime, path_provider, video_player, video_player_platform_interface, image_picker, local_auth, flutter_secure_storage, camera (camera_android_camerax, camera_avfoundation, camera_platform_interface), camera_windows | BSD-3-Clause |
| flutter_local_notifications, qr_flutter, video_player_win | BSD-3-Clause |
| record | BSD-3-Clause |
| flutter_riverpod (riverpod), file_picker, flutter_foreground_task, system_tray, window_manager (screen_retriever), flutter_webrtc (dart_webrtc, webrtc_interface), image, qr_code_dart_scan | MIT |
| cryptography, app_links, zxing_lib (also via qr_code_dart_scan) | Apache-2.0 |
| dbus, gtk (Linux) | MPL-2.0 |
| zstandard | to be confirmed by `tool/check_licenses.dart` |

Transitive packages are BSD-3-Clause (dart.dev and flutter.dev packages), MIT,
Apache-2.0, MPL-2.0 or Zlib (vector_math).

## Go modules (network bridge, `native/yggdrasil_bridge`)

| Module | Licence |
|---|---|
| Go standard library, golang.org/x/crypto, net, sys, text | BSD-3-Clause + Google patent grant |
| github.com/yggdrasil-network/yggdrasil-go | LGPL-3.0 with a static-linking exception |
| github.com/Arceliar/ironwood, github.com/Arceliar/phony | MPL-2.0 |
| github.com/quic-go/quic-go, github.com/hjson/hjson-go/v4 | MIT |
| github.com/coder/websocket | ISC |
| github.com/klauspost/compress, github.com/gologme/log, github.com/wlynxg/anet, github.com/bits-and-blooms/bitset, github.com/bits-and-blooms/bloom/v3 | BSD-3-Clause / BSD-2-Clause |

## Native libraries

| Component | Where | Licence |
|---|---|---|
| WebRTC (libwebrtc, via flutter_webrtc) | all platforms | BSD-3-Clause + patent grant; contains third-party code (BoringSSL, libsrtp, libvpx, libaom, dav1d, Opus, libyuv, Abseil, …) under BSD, ISC, Apache-2.0 and similar licences |
| Zstandard (libzstd, via zstandard) | all platforms | BSD-3-Clause (dual-licensed BSD / GPLv2) |
| AndroidX, Kotlin, kotlinx.coroutines, Tink, AudioSwitch, Apache Tika core | Android | Apache-2.0 |
| Protocol Buffers (protobuf-javalite, via Tink) | Android | BSD-3-Clause |
| desugar_jdk_libs | Android | GPL-2.0 with the Classpath Exception; source: https://github.com/google/desugar_jdk_libs |
| DKImagePickerController, DKPhotoGallery, SDWebImage, SwiftyGif (via file_picker) | iOS | MIT |
| Microsoft Visual C++ Redistributable (msvcp140.dll, msvcp140_1.dll, msvcp140_2.dll, vcruntime140.dll, vcruntime140_1.dll) | Windows (`Zen-Windows.zip`, `Zen-Windows-arm64.zip`) | Copyright © Microsoft Corporation. Redistributed unchanged, only as part of Zen, under the Visual Studio licence terms for "Distributable Code" (the REDIST list) |
| GTK, GLib, GStreamer, libsecret (system libraries) | Linux | LGPL-2.1+ |
| OpenH264 2.4.1 (Zen's H.264 encoder for films, built from source into the app) | Linux | BSD-2-Clause (`assets/licenses/native/openh264.txt`); Cisco's H.264 patent licence covers only Cisco's own binaries, not this build (on the other systems Zen uses the system's codecs; see `docs/RELEASES.md`, section 6.1.1) |
| vo-aacenc 0.1.3 (VisualOn; Zen's AAC encoder for films' sound, built from source into the app) | Linux | Apache-2.0 (`assets/licenses/native/vo_aacenc.txt`) |
| ffmpeg (not shipped: run as a separate program when the computer has it, to decode a film GStreamer cannot) | Linux | LGPL-2.1+ / GPL-2.0+ (the system's copy) |
| libayatana-appindicator3, libdbusmenu (copied into the Flatpak) | Linux Flatpak | LGPL-2.1 / LGPL-3.0; source: the Ubuntu packages of the same version |
| libayatana-indicator3 (copied into the Flatpak) | Linux Flatpak | GPL-3.0; source: the Ubuntu package of the same version |

## Fonts and icons

| Asset | Licence |
|---|---|
| Fredoka, Hanken Grotesk, JetBrains Mono, Space Mono, DM Sans (`assets/fonts`) | SIL Open Font License 1.1 |
| Material Icons (the icon font of the user interface; `ic_stat_call.xml` and `ic_pip_hang_up.xml` in `android/app/src/main/res/drawable`) | Apache-2.0, Copyright Google LLC |

## Zen's own sounds and images

- **Sounds** (`assets/sounds`, `android/app/src/main/res/raw`,
  `ios/Runner/Sounds`, `macos/Runner/Sounds`): synthesised from scratch by
  `tool/sounds/generate_sounds.py`, which rebuilds the WAV files bit for bit.
  No recorded or third-party samples.
- **Logo, wordmark and icons** (`assets/branding`, the Android, iOS, macOS,
  Windows and Linux icon files) and **screenshots** (`docs/img`): made for
  Zen. GPL-3.0-only like the code; NOTICE section 4 keeps the name "Zen" and
  the logo out of the licence as marks.

## Network services

Zen has no servers of its own. These services are used at run time; they are
not part of Zen and their terms of use apply:

| Service | What for |
|---|---|
| KLIPY (api.klipy.com) | GIF search in the chat, a proprietary service (can be turned off in Settings → GIFs; users can enter their own API key) — KLIPY API terms |
| Public Yggdrasil peers (publicpeers.neilalexander.dev and the peers listed there) | joining the Yggdrasil network |
| Quad9, Cloudflare, Google Public DNS (DNS-over-TLS) | name resolution only when the system resolver does not work |
| GitHub (api.github.com, github.com) | checking for and downloading updates (not in the store variant, which repositories such as F-Droid build) |
| OpenStreetMap (openstreetmap.org) | a shared location opens there in the browser; no map data is shown in the app |
| buycoffee.to | the voluntary donation link opens there in the browser; nothing is sent from the app |
