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

## Running the tests

`flutter test` runs every test, but it runs only half as many files at
once as the computer has cores (its default `--concurrency`), it starts
them in alphabetical order, and the tests of one file always run one after
another, so a long file that starts late keeps everything waiting. The
fastest ways:

| Command | What it does |
|---|---|
| `dart run tool/test.dart` | every test: several `flutter test` runs at once (one per four cores), together using every core, the longest files first; at the end the counts and the failed tests |
| `dart run tool/test.dart test/chat_test.dart test/wire` | only these files and folders, the same way |
| `dart run tool/test.dart -- --plain-name "mailbox"` | everything after `--` goes to each `flutter test` |
| `flutter test test/chat_test.dart` | one file with its whole output (the quickest for one file) |
| `flutter test -j 16` | the plain run, with all 16 cores |

On a 16-core Windows computer the whole suite takes about 5 minutes with
`tool/test.dart` and about 10 with a plain `flutter test`.
`tool/test.dart` remembers how long each file took
(`build/test_times.json`, written by every full run) to start the longest
files first and to give each run the same amount of work; before the first
run it takes the times of the longest files from `tool/test_times.json`
(kept in the repository, refreshed from `build/test_times.json` now and
then) and guesses the rest from their size. `--groups N` (parallel runs) and `--concurrency N`
(files at once in each) change the split; the defaults keep every core
busy. It fetches the packages only when they were never fetched: after
changing `pubspec.yaml`, run `flutter pub get` yourself.

CI splits the files into four jobs of about the same length
(`--shard 1/4` … `4/4`, section 6, by `tool/test_times.json` and the file
sizes only, so every job computes the same split);
`dart run tool/test.dart --list --shard 2/4` shows the files of one of them.

The longest files are the simulated phone worlds (`post_reach_test.dart`,
`neighbors_test.dart`, `dating_test.dart`, `conversation_recovery_sync_test.dart`),
the whole app (`widget_test.dart`, `shell_*_test.dart`) and the text fit
checks of every screen in every language, which are split into
`test/ui_text_fit_1_test.dart` … `_4_test.dart` so that the four parts run
side by side. Split a new long file the same way rather than letting it
grow past a minute or two.

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

Ready-made worlds:

- `test/support/pyramid_world.dart` (`PyramidWorld.six()`, `join`, `approve`,
  `approveAll`, `sync`, `duties`, `views`) for the pyramid;
- `test/support/friends_world.dart` (`FriendsWorld`) for messaging, see
  section 1.1.

### 1.1 Simulated friends (`test/support/friends_world.dart`)

`FriendsWorld` is a set of friends whose phones run the app's real
messaging stack on a `SimNetwork`: each `FriendsPhone` has its own relay
engine, social controller (`SocialHubController` over memory stores), reliable
transport, notification service and files folder. A message goes the way it
does in the app (controller, outbox, direct try, deposit in the recipient's
mailboxes, acknowledgements), and what the network does to the datagrams
(delay, loss, a split, a phone that is off) is the simulator's. There are no
real timers: `advance(Duration(days: 1))` runs the engines' ticks on the
virtual clock in about a second of real time, and the same `seed` gives the
same run. A test of a dozen phones and a day of virtual time takes seconds.

```dart
final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'M1', 'M2']);
await w.chooseMailboxes(w['B'], <FriendsPhone>[w['M1'], w['M2']]);

await w.setOnline(w['B'], false);                 // B's phone is off
await w.send(w['A'], w['B'], 'hello');            // as the send button does
await w.advance(const Duration(seconds: 10));     // past the deposit delay
await w.setOnline(w['A'], false);                 // the sender leaves too
await w.setOnline(w['B'], true);                  // B returns, asks its mailboxes
await w.assertDelivered(w['B'], 'hello', from: w['A'], within: const Duration(minutes: 1));
expect(w['B'].messageNotices, hasLength(1));      // one notification
```

| Call | What it does |
|---|---|
| `FriendsWorld.create(names, devices:, allFriends:, seed:, dropRate:)` | phones (`SimDevice.android`, `desktop`, `iphone`: whether they announce that they stay online, as mailboxes of choice), friends with everyone by the real invitation and acceptance, mailbox announcements settled; torn down when the test ends |
| `add(name)`, `befriend(a, b)`, `befriendAll`, `befriendChain` | more phones, a friend graph |
| `chooseMailboxes(owner, [friends])`, `mailboxesOf(owner)` | the friends that hold the owner's mail (otherwise the engine picks up to six by itself) |
| `setOnline(phone, on)` | switches a phone off (it sends and receives nothing; its engine stops) or on (the engine starts and asks its mailboxes) |
| `lock(phone)`, `unlock(phone)` | the Android phone is locked: only the background service runs (`LockedReceiver` with a sealed inbox, `LockedMailbox` for friends' mail, one generic notice); unlock hands over the held mail and the inbox to the app |
| `partition(a, b)`, `heal()`, `dropRate = 0.3` | a network split, loss |
| `send(from, to, text)`, `createGroup`, `sendGroup` | what the user does; the network settles afterwards |
| `settle()`, `advance(duration)`, `deliver()` | land what is in flight, move the virtual clock (engines tick every 5 s while something waits, 30 s otherwise) |
| `assertDelivered(to, text, from:, within:)`, `assertNotDelivered`, `until(condition, within:)` | wait on the virtual clock; a failure prints what is still waiting where (`describe()`) |
| `phone.textsFrom(x)`, `thread(x)`, `deliveryOf(x, text)`, `groupTexts` | what is in a phone's chats and the sender's delivery mark |
| `phone.messageNotices`, `phone.shownMessageNotices` | every notification a phone posted for a message (the app's and the locked service's), and those still in the shade |
| `phone.appTransport` | the phone's transport for other services (the recovery circle, the ledger): sends through its outbox and mailboxes, receives what its engine hands to the app |

Not simulated: Yggdrasil itself (sessions, routing, real delays), presence
pings, the platform (wake locks, alarms, radios) and the screens. With the app
on the screen the social controller leaves messages for the chat screen, which
this world has none of, so phones stay in the background. The frames a phone
receives reach its engine and controller one at a time and are awaited
(`SimNetwork` handlers are not nested), so the order inside a phone is the
real order, but concurrency between the app and its background service is not
tested here.

`test/friends_world_test.dart` is the suite on top of it: a message to a
friend who is offline held by phone mailboxes and delivered on return (also
with the sender gone, with the sender gone before any mailbox had a copy,
with one mailbox offline, with a late mailbox); group messages to online and
offline members; exactly one notification per message across the direct and
mailbox paths and in a burst; a locked phone (sealed inbox, one generic
notice, locked mailboxes); a split and its healing; 30% loss; order in a
conversation; an iPhone left out of the mailbox choice; files that come only
from a holder that still has them; the conversations back from a friend after
an account recovery; the same seed, the same run.
`test/test_harness_gate_test.dart` reads the source to guard that the remote
control of section 2 is started only in debug builds, on loopback, behind its
header, and that nothing else brings it in.

| File | What it checks |
|---|---|
| `test/pyramid_core_test.dart` | ring signatures, rules, state assembly |
| `test/pyramid_sim_test.dart` | admission, swap and anonymous voting, tree referendum, issuance + transfer + veto, report + crisis notice, chaos (30% loss, phones switched off, split → after healing everyone sees the same), forged records |
| `test/pyramid_scenarios_test.dart` | delegations, immunity, dating ban, migration, absence, removal, advisory referendum and rules changed by the top, national section, paid mailbox, announcement, sponsorship, power key handover, cell chats |
| `test/pyramid_security_test.dart`, `test/pyramid_attack_sim_test.dart` | attacks on the pyramid |
| `test/dating_test.dart`, `test/neighbors_test.dart` | dating and neighbors on several phones |
| `test/friends_world_test.dart` | messaging between simulated friends (section 1.1): mailboxes, offline and locked phones, groups, notifications, splits, loss, order, files, recovery |
| `test/test_harness_gate_test.dart` | the remote control (section 2) starts only in debug builds, on loopback, behind its header |
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
| `test/relay_engine_test.dart` (group "phones as mailboxes while locked"), `test/locked_background_inbox_test.dart` (group "one notice per message"), `test/runtime_route_bridge_test.dart` | locked phones as friends' mailboxes (mail for an offline friend held and handed over with the sender gone, taken over by the app after unlock), one notice per message on a locked phone, where a tapped notification leads |
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

### 3.1 The technical log after an incident

Logcat keeps only an hour or two, and a release build writes almost nothing
there. Zen keeps its own log on the phone: errors and warnings, and `TECH`
lines with every wake of the background work (`beat` with each job's time,
`wake`), mode changes (`app`, `background`, `receive-only`, `parked`),
handovers between the app and the service, service start and stop, how
Android ended earlier runs (`exit`, Android 11 on: low memory, ANR, crash
and so on) and the node's numbers every 5 minutes while it runs (`node`: Go
heap and goroutines, peers by count, traffic rates, public and local bytes,
transit and the transit guard's holds). Nothing in it names a person, a
message, an address or a file. Each isolate (`ui`, `svc`) writes its own
`zen-diagnostics-<isolate>.log` in the account's data folder and sets it
aside as `.log.1` at 512 KB, so the log covers several days.

Right after an incident (an ANR, a killed service, a night of traffic):

1. **Any build:** Settings → Advanced → Diagnostics → save (the arrow
   icon). The whole log, both isolates in time order, is written to
   `Android/data/com.roj.zen/files/Zen/zen-dziennik-<date>-<time>.txt`;
   copy it over USB or
   `adb pull /sdcard/Android/data/com.roj.zen/files/Zen/`.
2. **Debug builds only**, without touching the phone (each isolate's
   older file first; for an account other than the first, the files are in
   `files/accounts/<id>/`):

   ```
   adb exec-out run-as com.roj.zen sh -c "cd files; cat zen-diagnostics-svc.log.1 zen-diagnostics-svc.log 2>/dev/null" > zen-svc.txt
   adb exec-out run-as com.roj.zen sh -c "cd files; cat zen-diagnostics-ui.log.1 zen-diagnostics-ui.log 2>/dev/null" > zen-ui.txt
   ```
3. Take a bug report at once as well (`adb bugreport`): it has the ANR
   traces and the exit records the log only names.

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
| Format and analyze | Windows | `dart format` (no changes), `flutter analyze`, the release contract (`tool/release.dart check`) and the Python tests of `tool/ci` |
| Tests (1 of 4) … (4 of 4) | Windows | the app's tests (including translations), a quarter of the files each, at the same time (`dart run tool/test.dart --shard N/4`, see "Running the tests") |
| Tests on Linux | Ubuntu | the tests the Windows jobs skip: POSIX file modes (`media_temp_folder_test.dart`) and the app's calls into the real Go bridge, built first (`hybrid_kem_test.dart`, `hybrid_signature_test.dart`) |
| Analyze and test | Ubuntu | waits for the four jobs above and is green only when all of them are; the check the branch rules require. Writes the report described below |
| Go bridge | Windows | `go vet` and `go test` of the bridge |
| Go bridge for Android (3 ABIs) | Ubuntu | `build_android.sh` for arm64-v8a, armeabi-v7a and x86_64 (NDK from the runner); checks the `YggStartNode` export in each `.so` |
| Linux build | Ubuntu | `flutter build linux --release` (the bridge builds itself), the `YggStartNode` symbol in `libyggdrasil_bridge.so`, `libgstreamer-1.0` linked into `zen`, packaging (`desktop-file-validate`, `appstreamcli validate`, `build_deb.sh` + `dpkg-deb --info`), the native test of the video codec filter (`linux/runner/test/zen_media_codecs_test.cc`), start under Xvfb — the app must still run after 20 s |
| Windows on ARM build | `windows-11-arm` | llvm-mingw (checked against its SHA-256), `flutter build windows --release`, `yggdrasil_bridge.dll` present in the ARM64 build |
| macOS build | macOS | bridge (`build_macos.sh`), `flutter build macos --release`, the `_YggStartNode` symbol in `Zen.app`, a 20 s start |

All jobs start at once (only the `.deb` installs wait for the Linux build).
The Flutter SDK with its pub packages and Go's modules and build cache are
cached between CI runs; the release workflow uses no caches at all.

The *Analyze and test* and *Go bridge* jobs write a short report to the run's
summary page (Actions → the run → Summary): format, analyzer issues, test
counts of all test jobs added up (passed, failed, skipped) with the failed
tests and their first error lines, the tests that no job ran (skipped on
Windows and not run on Linux either; there should be none), and the Go
packages and tests. `tool/ci/ci_summary.py` (Python 3,
standard library only; tested with the other CI scripts in
`tool/ci/test_ci_checks.py`) turns `flutter test --file-reporter json:…`,
`flutter analyze` and `go test -v` output into that Markdown; it
never fails the job itself. The release workflow's *Sign* job (and, for a
run from a branch, its *SHA256SUMS* job) lists every release file with its
size and checksum the same way.

`release.yml` on a `v*` tag builds all the release files — Android (one APK
per ABI, each in its own job, signed afterwards by the one job that has the
keys), Windows x64 and ARM64, Linux x64 and ARM64 as `tar.gz` and
`.deb`, macOS and iPhone (`RELEASES.md` section 3). If the Xvfb start proves unstable, building and the symbol check remain. The release
job for Linux additionally checks the bridge and GStreamer linkage and runs
`dpkg-deb --info` on the `.deb`.

## What this does not check

- The simulator does not test Bluetooth, Wi-Fi Direct, Multipeer or real
  Yggdrasil delays; offline links are tested with fake transports and in Go,
  the radios themselves (Kotlin, Swift, C++ runners) only by hand.
- The Android background service has few tests, the Kotlin code (BLE, calls)
  none.
- App tests run in CI on Windows, and on Linux only those the Windows jobs
  skip; on macOS and Windows on ARM CI only builds and (Linux, macOS) runs
  the app for 20 s. There is no APK build
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
