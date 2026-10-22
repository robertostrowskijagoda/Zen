# Testing

From fastest to most "real":

1. **Tests and the network simulator** — `flutter test`, dozens of phones in a
   single test, with a virtual clock.
2. **Several apps on one computer** — real apps (separate data, keys and
   nodes), driven by a script.
3. **A phone** connected by cable — the same method through `adb forward`.
4. **Visual audit** — all screens at several sizes.

In addition: Go bridge tests (`go test` in `native/yggdrasil_bridge`,
`test_native.ps1`; among them the post-quantum session layer, local links, LAN
discovery, Bluetooth and Wi-Fi Direct logic and the door node), translation checks (section 5) and GitHub Actions on every
push (section 6).

## 1. Network simulator (`lib/src/dev/sim/sim_network.dart`)

`SimNetwork` is an in-memory network of phones:

- a virtual clock (`advance(Duration(days: 61))` takes milliseconds; services
  get `now: () => net.now`);
- seeded delays (reproducible runs), loss (`dropRate`), phones switched off
  (`setOnline(p, false)`, `holdForOffline`), network splits
  (`partition(a, b)` / `heal()`);
- an acquaintance graph: `befriend`, `chain`, `randomGraph(degree: 3)`;
- `SimPhone` pretends to be an `EventHost`, so real services plug into it
  (pyramid, dating, neighbors…);
- `stats` (delivered / lost / waiting) and `trace`.

A ready-made world: `test/support/pyramid_world.dart` (`PyramidWorld.six()`,
`join`, `approve`, `approveAll`, `sync`, `duties`, `views`).

| File | What it checks |
|---|---|
| `test/pyramid_core_test.dart` | ring signatures, rules, state assembly |
| `test/pyramid_sim_test.dart` | admission, swap and anonymous voting, tree referendum, issuance + transfer + veto, report + crisis notice, chaos (30% loss, phones switched off, split → after healing everyone sees the same), forged records |
| `test/pyramid_scenarios_test.dart` | delegations, immunity, dating ban, migration, absence, removal, advisory referendum and rules changed by the top, national section, paid mailbox, announcement, sponsorship, power key handover, cell chats |
| `test/pyramid_security_test.dart`, `test/pyramid_attack_sim_test.dart` | attacks on the pyramid |
| `test/dating_test.dart`, `test/neighbors_test.dart` | dating and neighbors on several phones |
| `test/wire/golden_frames_test.dart` | protocol golden samples: frozen ping/pong frames (1.10.0 and 1.11), message, group_invite and a signed journal entry (fixed keys, fixed id). Never edit a sample to make a test pass — add a new one for a new format |
| `test/version_exchange_test.dart` | version exchange (`ver` / `build` / `caps` in ping/pong), remembering friends' versions, snapshot compatibility (`peerVersions`), the "friends have a newer version" bar, forward-compatible journal spaces of unknown kinds (owner-only, 1000 entries per device journal) |
| `test/feature_flags_test.dart` | feature flags (pyramid, wallet, dating; neighbors have none): defaults, `--dart-define` values, locking, hiding tabs |
| `test/format_version_test.dart` | `v: 1` format versions of settings, profile and flags; files without `v` read as version 1 |
| `test/release_integrity_test.dart` | signed release manifest: `official` (donation link, author, repository) and `mirrors`, unknown fields preserved, canary (`zen_canary`: signatures, expiry, replay of old or known statements), warning on mismatched data |
| `test/apk_signature_test.dart` | reading APK certificates (`apk_signing_block.dart`) and the pinned fingerprint |
| `test/network_update_test.dart` | update over the network (disabled while `kReleaseMaintainers` is empty), loading from a file |
| `test/store_build_test.dart` | the store build: only `appFlavor == 'appStoreOnly'` or `ZEN_STORE` make a store build, tests run as the direct build, the shared link defaults to the project page |
| `test/about_screen_test.dart` | About, including the Privacy policy and Terms tiles with GitHub links |
| `test/hybrid_kem_test.dart`, `test/hybrid_signature_test.dart`, `test/relay_hybrid_cipher_test.dart`, `test/call_media_e2ee_test.dart`, `test/signature_overhead_test.dart` | post-quantum layers: hybrid KEM, hybrid signatures (both halves must verify, key pinning), mailbox sealing, call media key chains and rotation, size of signed records |
| `test/pyramid_root_test.dart`, `test/pyramid_original_found_test.dart`, `test/pyramid_rules_v2_test.dart`, `test/pyramid_v2_service_test.dart`, `test/pyramid_feed_test.dart`, `test/pyramid_gate_wallet_test.dart` | pinned genesis, founding the original pyramid with the power key, power-key handover, voting after 14 days or `known`, rules changed by the top with the 24 h delay, advisory referenda, cell chats, pyramid posts on the feed, gates paid in points |
| `test/local_links_test.dart`, `test/native_stream_local_link_test.dart`, `test/runtime_lan_discovery_test.dart`, `test/offline_links_section_test.dart` | offline links with fake transports (settings, per-platform transports, secrets, status text) |
| `test/alarm_kit_test.dart`, `test/nearby_background_test.dart`, `test/locked_background_inbox_test.dart`, `test/locked_signal_test.dart`, `test/neighbors_mailbox_door_test.dart` | the locked Android service: background key, alarm / nearby / door kits, sealed inbox, mailbox doors |
| `test/encounters_test.dart`, `test/open_to_meet_test.dart`, `test/food_share_test.dart`, `test/graph_model_test.dart`, `test/dating_test.dart` | "Passed by", "open to meet", food sharing, graph modes and routes, dating intentions and filters |
| `test/github_update_test.dart`, `test/sound_assets_test.dart` | GitHub release check and verified self-update, sound files |

A new scenario: build a world, perform actions, `await w.net.run()`, check the
state at a **different** person than the one who acted, and finally
`expect(w.views().values.toSet(), hasLength(1))`.

## 2. Several apps on one computer

**Profile:** `zen.exe --zen-profile=ala` (or `ZEN_PROFILE=ala`) — a separate
data folder (`…\Zen\profiles\ala`), separate keys, a second instance allowed;
if port 32913 is taken the node runs without listening, in debug builds
without the app password, and the profile name is in the window title. (On
Linux the runner is single-instance via GApplication; a test profile still
starts alongside.)

```
powershell -File tool\multi_client.ps1 -Count 4          # builds and starts 4 (sim1, sim2, …)
powershell -File tool\multi_client.ps1 -Count 4 -NoBuild # without building
powershell -File tool\multi_client.ps1 -Count 4 -Show    # windows visible (minimized by default)
powershell -File tool\multi_client.ps1 -Stop             # closes the test profiles
```

**Harness** (`lib/src/features/runtime/test_harness_server.dart`,
`test_harness_features.dart`): debug builds only, on
`127.0.0.1:48888…48895` (first free port), requires the header
`x-zen-harness: 1`. Besides `/status`, `/friend/request`, `/friend/accept`
and chats:

| Path | What it does |
|---|---|
| `/x/state` | state of the pyramid, proposals, dating, flat |
| `/x/pyramid/create` `{name, me, nat, year, g}`, `/invite`, `/join` `{code, me, …}`, `/approve` `{type?}` | founding and admitting |
| `/x/pyramid/post` `{text}`, `/swap` `{cell, up}` | post, swap within a cell |
| `/x/pyramid/referendum` `{q, opts, minutes}`, `/vote` `{ref?, opt}` | referendum and vote |
| `/x/pyramid/emit` `{to, amount}`, `/pay` `{to, amount, memo}` | currency |
| `/x/pyramid/duties`, `/greet` | duties, synchronization |
| `/x/dating/enable`, `/publish`, `/decide` `{name, yes}` | dating |
| `/x/flat/create`, `/door`, `/scan` `{code}` | neighbors |

**Script** `tool/zen_drive.dart`:

```
dart run tool/zen_drive.dart find                       # who is listening and on which port
dart run tool/zen_drive.dart status 48888 48889         # /x/state of all
dart run tool/zen_drive.dart friends 48888 48889 48890  # friendships in turn
dart run tool/zen_drive.dart pyramid 48888 48889 48890 48891
dart run tool/zen_drive.dart flats 48888 48889
dart run tool/zen_drive.dart call 48888 /x/pyramid/post '{"text":"hello"}'
```

`pyramid` befriends the apps into a tree, founds a pyramid, admits further
people, checks the shared picture of the structure, sends a post, announces a
referendum, votes and waits for the count; every step waits for the result at
the others (`✓` / `✗ did not arrive in time`).

## 3. Phone

1. Enable USB debugging and accept "Allow USB debugging?" on the phone
   (otherwise `adb devices` shows `unauthorized`).
2. `flutter install` (debug) or `flutter run -d <id>` (builds the Go bridge
   only for the device's ABI).
3. `powershell -File tool\multi_client.ps1 -Count 3 -NoBuild -Phone`
   (sets `adb forward tcp:48900 tcp:48888`).
4. `dart run tool/zen_drive.dart pyramid 48900 48888 48889 48890`.

The phone connects to the apps on the computer over the real Yggdrasil
network. Install the APK of the phone's ABI (`Zen-arm64-v8a.apk` on most
phones, `Zen-armeabi-v7a.apk` on older 32-bit ones, `Zen-x86_64.apk` on
Chromebooks and emulators); the 32-bit (armeabi-v7a) and x86_64 builds are checked in CI only for building and
exporting the bridge (section 6), not run — try an older 32-bit phone or an
emulator by hand.

The store variant: `flutter run --flavor appStoreOnly` (or
`--dart-define=ZEN_STORE=true`) — the update service is off, "Pass it on"
shows a link dialog, and the manifest has no `REQUEST_INSTALL_PACKAGES`.

## 4. Visual audit (`tool/ui_tour/ui_audit_test.dart`)

```
flutter test tool/ui_tour/ui_audit_test.dart --update-goldens
AUDIT_ONLY=p320,desk flutter test tool/ui_tour/ui_audit_test.dart --update-goldens
```

The test sets up data (pyramid, event, circle, question, flat, dating, chats)
and walks through all tabs and screens in these configurations: `p360`
(360 dp), `p360big` (text 130%), `p412light` (light theme), `p320`,
`p320big` (text 150%), `p320short` (320 × 568), `split` (411 × 420, a split
screen), `tablet` (800 × 1280), the computer's portrait window `desk_min`
(390 × 720), `desk` (480 × 900) and `desk_max` (920 × 1150), and in other
languages `de320`, `de360big`, `ru320`, `ru360big` (text 130%), `ar360`
and `ar320big` (Arabic, right to left). Every layout error (overflow,
overlap) is collected instead of aborting the test: the list is in
`scratch/audit/<configuration>.txt`, screenshots in
`scratch/audit/<configuration>/` (outside the repository). `AUDIT_ONLY`
narrows the configurations. The test ends "failed" because of the app's
timers — what counts is the list of problems.

Languages: the language is set before start (the app does not switch to
the system's language there). `test/ui_dialogs_fit_test.dart` opens the
main dialogs on 320 × 568 with a 260 dp keyboard in Polish, German and
Arabic at text 100% and 130%, and guards that every `AlertDialog` scrolls
and that feature code uses direction-aware paddings and alignments;
`test/call_compact_test.dart` checks the small call window and
picture-in-picture sizes.

### 4.1 Pictures for the user guide (`tool/ui_tour/docs_screens_test.dart`)

```
flutter test --no-pub tool/ui_tour/docs_screens_test.dart --update-goldens
DOCS_SCREENS_ONLY=dark flutter test --no-pub tool/ui_tour/docs_screens_test.dart --update-goldens
```

Renders the screens shown in `docs/guide` in English, at phone size
(390 × 844 dp, 2×), in the Classic theme light and dark, with sample data
(posts, a conversation with every delivery icon, a pyramid with a history,
a door code, a dating profile). It writes `docs/images/<screen>-light.png`
and `docs/images/<screen>-dark.png` for `shell`, `graph`, `chat`, `feed`,
`films`, `meet`, `neighbours-door`, `dating`, `pyramid`, `pyramid-tree`,
`pyramid-history`, `wallet`, `settings` and `themes`; layout problems go to
`scratch/docs_screens/<mode>.txt`. Run it after the translations are up to
date (an untranslated text shows in Polish) and commit the pictures. The
diagrams next to them (`docs/images/*.svg`) are drawn by hand.

## 5. Translations

Texts in code are in Polish in `t('…')` and `tn(n, one: …, few: …, many: …)`
(`lib/src/app/i18n/zen_i18n.dart`), translations are in
`assets/i18n/<code>.json` (20 files; Polish has no file).

```
dart run tool/i18n.dart            # checks everything; exit code 1 on a problem
dart run tool/i18n.dart --verbose  # full list of missing and stale texts
dart run tool/i18n.dart --keys     # all code texts as JSON (for translating)
dart run tool/i18n.dart --prune    # removes stale texts and sorts the files
```

The check reports: `t()` / `tn()` calls with anything other than a plain
string literal (a variable, concatenation, `$x`), and in each language file
missing texts, texts the code no longer has, and mismatched `{name}`
placeholders. After changing or adding a Polish text: `--keys`, add
translations in all files (under the same Polish key, with the same
placeholders; plural forms per the language's CLDR), finally `--prune` and
once more without options.

`test/i18n_test.dart` (part of `flutter test`, hence of CI) checks the
translation layer (placeholders, missing translation = Polish text, plural
forms in Polish, English, Russian and Arabic, language selection: chosen, then
the first system language, then English, loading files) and the repository the
same way as `tool/i18n.dart`: each file has exactly the texts from `lib/`, and
`assets/i18n` holds only languages Zen knows.

## 6. GitHub Actions

`.github/workflows/ci.yml` — on every push to `main`, pull request and by hand
(Actions → CI → Run workflow):

| Job | Where | What it does |
|---|---|---|
| Analyze and test | Windows | `dart format` (no changes), `flutter analyze`, `flutter test` (including translations) |
| Go bridge | Windows | `go vet` and `go test` of the bridge |
| Go bridge for Android (3 ABIs) | Ubuntu | `build_android.sh` for arm64-v8a, armeabi-v7a and x86_64 (NDK from the runner); checks the `YggStartNode` export in each `.so` |
| Linux build | Ubuntu | `flutter build linux --release` (the bridge builds itself), the `YggStartNode` symbol in `libyggdrasil_bridge.so`, `libgstreamer-1.0` linked into `zen`, packaging (`desktop-file-validate`, `appstreamcli validate`, `build_deb.sh` + `dpkg-deb --info`), start under Xvfb — the app must still run after 20 s |
| Windows on ARM build | `windows-11-arm` | llvm-mingw (checked against its SHA-256), `flutter build windows --release`, `yggdrasil_bridge.dll` present in the ARM64 build; not on pull requests; `continue-on-error` until the first green run |
| macOS build | macOS | bridge (`build_macos.sh`), `flutter build macos --release`, the `_YggStartNode` symbol in `Zen.app`, a 20 s start; not on pull requests (more expensive minutes) |

The *Analyze and test* and *Go bridge* jobs write a short report to the run's
summary page (Actions → the run → Summary): format, analyzer issues, test
counts (passed, failed, skipped) with the failed tests and their first error
lines, and the Go packages and tests. `tool/ci/ci_summary.py` (Python 3,
standard library only) turns `flutter test --file-reporter json:…`,
`flutter analyze --write=…` and `go test -v` output into that Markdown; it
never fails the job itself. The release workflow's *SHA256SUMS* job lists
every release file with its size and checksum the same way.

`release.yml` on a `v*` tag builds all the release files — Android (signed
APKs, one per ABI), Windows x64 and ARM64, Linux x64 and ARM64 as `tar.gz` and
`.deb`, macOS and iPhone (`RELEASES.md` section 3). Linux, macOS and Windows on ARM
have not yet passed their first run — after pushing, check these jobs; if the
Xvfb start proves unstable, building and the symbol check remain. The release
job for Linux additionally checks the bridge and GStreamer linkage and runs
`dpkg-deb --info` on the `.deb`.

## What this does not check

- The simulator does not test Bluetooth, Wi-Fi Direct, Multipeer or real
  Yggdrasil delays; offline links are tested with fake transports and in Go,
  the radios themselves (Kotlin, Swift, C++ runners) only by hand.
- The Android background service has few tests, the Kotlin code (BLE, calls)
  none.
- App tests run in CI only on Windows; on Linux, macOS and Windows on ARM CI
  only builds and (Linux, macOS) runs the app for 20 s. There is no APK build
  on push (only the Go bridge for the three ABIs) and no emulator test; the
  `appStoreOnly` flavor is covered only by the Dart-level `store_build_test.dart`, not
  by a Gradle build in CI.
- The Linux GStreamer player (`zen_media_player.cc`) is not tested beyond
  linking and starting; playback is checked by hand.
- The Go bridge has no random-input tests (`go test -fuzz`), and the app no
  "corrupted data sends no frame" test.
- The harness works only in debug builds.
- Apps on one computer share one link: network splits are tested in the
  simulator.
