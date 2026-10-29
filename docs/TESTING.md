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
discovery, Bluetooth and Wi-Fi Direct logic and the door node), translation checks (section 5), GitHub Actions on every
push (section 6), real Zen devices with real nodes on one computer
(section 7), every stored file damaged at random (section 8), the app on
an Android emulator (section 9) and one regression test per reported bug
(section 10).

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

CI splits the files into six jobs of about the same length
(`--shard 1/6` … `6/6`, section 6, by `tool/test_times.json` and the file
sizes only, so every job computes the same split);
`dart run tool/test.dart --list --shard 2/6` shows the files of one of them.
Refresh `tool/test_times.json` when the jobs drift apart (one shard several
minutes longer than another): after a full local run, keep the entries of
`build/test_times.json` above 15 seconds, rounded down to the second.

The longest files are the simulated phone worlds (`post_reach_test.dart`,
`neighbors_test.dart`, `dating_test.dart`, `conversation_recovery_sync_test.dart`),
the whole app (`widget_test.dart`, `shell_*_test.dart`), the damaged-file
sweep (`persistence_fuzz_test.dart`) and the text fit checks of every
screen in every language, which are split into
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
| `test/friendship_book_test.dart`, `test/friendship_book_guard_test.dart`, `test/friend_removal_test.dart` | who is a friend: the friendship book's state machine (only an invitation answered admits, a removed friend stays removed until a new one), random histories of actions, frames, replays and syncs on 2–3 own devices that must converge, a guard that reads the code for any way around the book, and the removal end to end (replays, the locked service, own devices) |
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

### 4.2 Screenshots and films of the website (`tool/screenshots.dart`)

```
dart run tool/screenshots.dart                    # everything, then --check
dart run tool/screenshots.dart --lang pl          # one language
dart run tool/screenshots.dart --only dark,phone  # light, dark, phone, desktop, lock
dart run tool/screenshots.dart --check            # what CI runs
```

Renders the real app on the host (no device) with a demo account made up in
`tool/screenshots/demo_account.dart`: invented names, faces and photos drawn
from code, a conversation with a photo, a voice message and reactions, a
group, posts, friends of friends with the dates the friends graph grew by,
people passed nearby. Nobody in it is a real person; never put real names,
photos or messages there. `tool/screenshots/site_screens_test.dart` does the
rendering, once per language (Polish and English; the other 19 languages of
the site show the English pictures), in the light and dark theme: the
screens of `tool/screenshots/shots.dart` at phone size (360 × 780 dp at 3×,
1080 × 2340 pixels) and one computer window (1440 × 900 pixels), and the
frames of two short films (sending a message, the graph's timeline). The
full-size PNG frames go to `build/shots/` with a list of layout problems
per run (`problems-*.txt`); `tool/screenshots/encode.py` (Python with
Pillow) turns them into WebP in `tool/pages/shots/<lang>/`: each picture at
the best quality under 150 KB, each film a looping animated WebP at half
size under 2 MB with a still poster (its last frame) that pages show to
visitors who asked for less motion. Commit `tool/pages/shots/` afterwards.

The app's own fonts are loaded; a colour emoji font of the computer (Segoe
UI Emoji on Windows, Noto Color Emoji on Linux) stands in for the second
fallback font so that reactions show their emoji, as the phone's own font
does on a device. The same frames always give the same files, but the
pictures are not byte-identical from day to day: dates that come from the
clock (the graph's timeline, "today", the time of the message sent in the
film) follow the day of the run. That is why CI does not compare pixels:
`--check` (in the "Docs and site" job) and `test/pages_site_test.dart`
fail when a picture the pages use is missing, too large, of the wrong size
or not used, or an alt text is missing in a language. Run it again after a
visible change to these screens and after the translations are up to date.

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

## 5.1 Upgrade fixtures and the start (`test/start_upgrade_test.dart`)

Every release leaves an account written by its own code in
`test/fixtures/upgrade/<version>/`: friends, a pending request, a group,
messages, a queued signal, notifications, presence, the profile, the relay
state, posts in the ledger, drafts and the settings, sealed under a test
password (`fixture.json` names it) with keys made for the fixture only;
`secure_storage.json` stands in for the system's secure storage. Each
folder is a few dozen kilobytes.

`test/start_upgrade_test.dart` runs the app's real start sequence
(`ZenBootstrapper` with the real file stores, the settings with their
protected copy and the app lock; everything but the node) on a copy of each
folder: it must reach the first screen within a bounded time, unlock with
the fixture's password and find everything (the social hub is hydrated the
way the app does it). Then every file of the newest fixture is damaged in
turn — emptied, cut short, overwritten with garbage, given a format version
from the future, together with its backup — and the app must still start,
never hang and never need its data wiped (a settings file it cannot read is
set aside as `*.damaged-<time>` and the next start is a normal one). The
CI job *Start on older data* runs it with the start trace and slow-start
tests.

After a release, add its fixture from the release's tag, before the next
one is prepared (`dart run tool/release.dart prepare` reminds you when the
version released last has none):

```sh
git worktree add ../zen-fixture v1.14.1
cd ../zen-fixture
flutter pub get
ZEN_FIXTURE_OUT=$PWD/fixture flutter test tool/upgrade_fixture/seed_test.dart
cd -
cp -r ../zen-fixture/fixture test/fixtures/upgrade/1.14.1
git worktree remove ../zen-fixture
flutter test test/start_upgrade_test.dart
```

The seed test writes with the code of the checkout it runs in; envelopes are
stored uncompressed (the test machines have no zstd library), a form the app
reads like any other. A release that stores something new adds it to
`tool/upgrade_fixture/seed_test.dart` and the check of it to
`test/start_upgrade_test.dart`. Fixtures are never edited after they are
committed; for releases before 1.14.1 the seed test was copied into a
checkout of the tag by hand.

Every start writes its steps to `zen-diagnostics-start.log` (read back with
the diagnostics log) before each one begins, and a `TECH  start step=<id>
ms=<n> result=<ok|timeout|failed|skipped>` line when it ends; the next start
logs where the previous one stopped (`The previous start stopped at step
"…"`). `test/start_trace_test.dart` and `test/start_watchdog_test.dart`
cover that and the slow-start screen.

## 6. GitHub Actions

`.github/workflows/ci.yml` — on every push to `main`, pull request and by hand
(Actions → CI → Run workflow):

| Job | Where | What it does |
|---|---|---|
| What to run | Ubuntu | decides whether a pull request changes code or only documentation, and whether the Linux build runs in the prebuilt image (`tool/ci/ci_plan.py`, below) |
| Docs and site | Ubuntu | every run: no broken link in the Markdown files (`tool/ci/check_links.py`), the release contract (`tool/release.dart check`), the Python tests of `tool/ci` and that every screenshot of the website is there (`tool/screenshots.dart --check`); when only documentation changed, also the app's tests that read it (`legal_consent_test.dart`, `pages_site_test.dart`, `release_contract_test.dart`) |
| Format and analyze | Windows | `dart format` (no changes) and `flutter analyze` |
| Tests (1 of 6) … (6 of 6) | Windows | the app's tests (including translations), a sixth of the files each, at the same time (`dart run tool/test.dart --shard N/6`, see "Running the tests") |
| Tests on Linux | Ubuntu | the tests the Windows jobs skip: POSIX file modes (`media_temp_folder_test.dart`) and the app's calls into the real Go bridge, built first (`hybrid_kem_test.dart`, `hybrid_signature_test.dart`) |
| Start on older data | Ubuntu | the app's start on every upgrade fixture and on damaged files, the start trace and the slow-start screen (`start_upgrade_test.dart`, `start_trace_test.dart`, `start_watchdog_test.dart`; section 5.1) |
| Analyze and test | Ubuntu | waits for the jobs above and is green only when all of them are; the check the branch rules require. Writes the report described below |
| End-to-end on Linux | Ubuntu | the real-node tests of section 7 (`dart run tool/e2e.dart`), about 6-8 minutes; its own report; not required by the branch rules until it is green |
| Go bridge | Windows | `go vet` and `go test` of the bridge |
| Go bridge for Android (3 ABIs) | Ubuntu | `build_android.sh` for arm64-v8a, armeabi-v7a and x86_64 (NDK from the runner); checks the `YggStartNode` export in each `.so` |
| Linux build | Ubuntu 22.04 (the image below, or the runner) | `flutter build linux --release` (the bridge builds itself), the `YggStartNode` symbol in `libyggdrasil_bridge.so`, `libgstreamer-1.0` linked into `zen`, packaging (`desktop-file-validate`, `appstreamcli validate`, `build_deb.sh` + `dpkg-deb --info`), the native test of the video codec filter (`linux/runner/test/zen_media_codecs_test.cc`), start under Xvfb — the app must still run after 20 s |
| Windows on ARM build | `windows-11-arm` | llvm-mingw (checked against its SHA-256), `flutter build windows --release`, `yggdrasil_bridge.dll` present in the ARM64 build |
| macOS build | macOS | bridge (`build_macos.sh`), `flutter build macos --release`, the `_YggStartNode` symbol in `Zen.app`, a 20 s start |

All jobs start right after *What to run* (only the `.deb` installs wait for
the Linux build). A new commit of a pull request cancels the run of the
commit before; on `main` every commit gets a complete run.

**Only documentation changed.** When every file a pull request changes is
documentation or the website (`docs/` except `TERMS.md` and `PRIVACY.md`,
which the app carries; `tool/pages/`; the Markdown files at the top except
`THIRD_PARTY_NOTICES.md`; the issue and pull request templates), only
*What to run*, *Docs and site* and *Analyze and test* run, in about two
minutes instead of about fifteen; *Analyze and test* is green when *Docs and
site* passed and the other jobs were skipped. Pushes to `main` always run
everything. `tool/ci/test_ci_checks.py` keeps *Docs and site* running every
app test that reads one of those files.

**Caches.** The Flutter SDK with its pub packages (Windows, Windows on ARM,
macOS, Linux) and Go's modules and build cache are cached; the emulator
workflow also caches Gradle's downloads. Pull requests read the caches the
runs of `main` wrote (GitHub keeps the caches a pull request writes to that
pull request), so a change of `pubspec.lock` is slow once, on its first
run. The repository has 10 GB for caches and each Flutter SDK takes about
2 GB, so a new cache must save real minutes. The release workflow uses no
caches at all ([RELEASES.md](RELEASES.md), section 3).

**The Linux build image.** The Linux build runs in
`ghcr.io/robertostrowskijagoda/zen-ci`, an Ubuntu 22.04 image with the build
tools, Flutter, Go and a head start of pub packages and Go modules
(`.github/images/linux-build/Dockerfile`). `.github/workflows/ci-image.yml`
builds and publishes it when the Dockerfile changes on `main` and once a
month, then opens a pull request that writes its digest into
`.github/images/linux-build/image.txt`; the CI run of that pull request
builds Linux in the new image. *What to run* uses the image only by that
digest, only while the Dockerfile is the one it was built from, and only
when the package is public; otherwise the job installs its tools on the
runner as before, so CI never depends on the image. It saves the job's
minute of `apt-get` and setup, and keeps the glibc 2.35 baseline once
GitHub retires the `ubuntu-22.04` runners (April 2027). The same image
builds Zen for Linux on any computer with Docker:
`docker run --rm -v "$PWD:/src" -w /src ghcr.io/robertostrowskijagoda/zen-ci:latest flutter build linux --release`.
Windows and macOS jobs cannot run in containers on GitHub's runners; their
time goes into the native builds (MSBuild, Xcode), which no cache shortens.

Once, after the first run of *CI image*: on GitHub open your profile →
**Packages** → **zen-ci** → **Package settings**, set **Change visibility →
Public**, and check that **Manage Actions access** lists this repository
with the **Write** role. Then merge the pull request *Use the new Linux
build image*. Updating Flutter or Go means updating
`FLUTTER_VERSION`/`FLUTTER_SHA256` or `GO_VERSION`/`GO_SHA256` in the
Dockerfile too (`tool/ci/test_ci_checks.py` fails until they match; the
SHA-256 values are in Flutter's `releases_linux.json` and
`https://go.dev/dl/?mode=json&include=all`).

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

## 7. End-to-end on real nodes (`test/e2e`)

Several real Zen devices in one `flutter test` process: each runs the app's
own start-up (`ZenBootstrapper`: settings, security, the stores in its own
data folder), its own Yggdrasil node from the Go bridge and all the app's
modules (`ZenCore`); only the screens are missing. The nodes meet through
one more node, the hub, listening on this computer's peering port (32913);
the bridge's public peer list is the hub alone, so nothing reaches the
internet, and the radios for friends nearby are off.
`test/e2e/support/zen_mesh.dart` (`ZenMesh`, `ZenDevice`) does the
plumbing; a scenario reads like what people do:

```dart
final ZenMesh mesh = await ZenMesh.open();
final ZenDevice ala = await mesh.device('Ala');
final ZenDevice ola = await mesh.device('Ola');
await mesh.befriend(ala, ola, within: kInvitationWithin); // QR, accept, names
await ala.send(ola, 'cześć');
await ola.waitForText(ala, 'cześć', within: kMessageWithin);
await ola.setOnScreen(false);          // the app in the background
await ola.restart();                   // stop, start again on the same folder
```

| File | Journeys |
|---|---|
| `friends_e2e_test.dart` | invitation by QR code and acceptance with time limits, both names shown (never "Kontakt Zen"), messages both ways, a friend in the background shown "w tle", one notification per message naming the sender and the text, a removed friend who keeps writing stays removed, also after a restart |
| `mailbox_e2e_test.dart` | a friend's device picks a mailbox; the friend is away, the sender writes and leaves, the friend comes back and gets the message from the mailbox; a post reaches a friend of a friend |
| `restart_e2e_test.dart` | a restart keeps the identity, friends, names and chats, presence is confirmed again after the start, messages flow again |
| `crash_e2e_test.dart` | a device whose folder is copied file by file during a burst of writes (a power cut) starts from that copy, keeps its friend and receives again |

```
dart run tool/e2e.dart                         # builds what it needs, runs every file
dart run tool/e2e.dart test/e2e/restart_e2e_test.dart
dart run tool/e2e.dart --no-build test/e2e/friends_e2e_test.dart
dart run tool/e2e.dart --clean                 # removes the bridge it put into the Flutter SDK
```

`tool/e2e.dart` (Linux and Windows; needs Go and a C compiler) builds the
bridge with the build tag `zene2e` and copies it next to the engine's
`flutter_tester`, where the app looks for it under `flutter test`; builds
zstd (the stores compress with it; its plugin library comes only from a
platform build) from the pub cache's sources; then runs the files one at a
time with `ZEN_E2E=1` (without it the tests skip, so a plain `flutter
test` never starts nodes, and `tool/test.dart` leaves `test/e2e` out unless
named). A Zen running on the same computer holds port 32913: close it
first. About 1-3 minutes per file.

A hang is reported, not waited out: the app calls the bridge on its main
isolate, and a call that never returns freezes every timer, the test's own
timeout included. A watchdog isolate ends the process after 45 s of
silence; the `zene2e` bridge writes the stacks of all goroutines to
`build/e2e/goroutines.txt` every 10 s (`stack_dump_e2e.go`, never in an
app), and both the watchdog and `tool/e2e.dart` print them. Each device
keeps a trace of the frames that reached it (`mesh.describe()`), printed
when a wait fails; `mesh.report()` prints the time each step took.

Time limits (`zen_mesh.dart`): `kInvitationWithin` and
`kAfterRestartWithin` (20 s today: the first contact of two devices, and
the first after a restart, take about 14 s, R5-F5), `kMessageWithin`
(10 s). Lower them as the fixes land.

Not covered here: Android's locked receiver (it runs only on Android; the
simulator covers it, section 1.1), the account's second device (linking),
calls, the radios, the screens.

## 8. Damaged files (`test/persistence_fuzz_test.dart`)

Every file the app keeps, damaged as a phone damages it, must never keep
the app from starting. The files are not listed by hand: a device starts
once with the app's start-up and modules (no node), is used (a name,
settings, a friend, a group, a message) and closed; then each file it
wrote, and sometimes its backup too, is emptied, cut short at a random
point, filled with random bytes, has a byte flipped, gets a newer or older
format number or is made huge, and the app starts again on that folder. It
must start within 30 s, get through the same use without an error, and
leave no error unhandled in the background. A store added later is covered
without a change in the test. The files read outside the start (the node's
config, the public peers, the update notice, the language) get the same
damage through their own loaders.

Seeded (`ZEN_FUZZ_SEED`, default fixed, so CI is reproducible);
`ZEN_FUZZ_CASES=500` tries more cases locally. Part of the normal suite
(about 40 s). What it found and is not fixed yet is listed in
`_knownFindings` with its regression id (printed on every run, not
failing); whoever fixes one removes its line. Anything else fails.

Upgrades from released versions are covered by the stored samples of
every format (`test/fixtures/formats`, `test/fixtures/upgrade`) and the
emulator's install over the previous release (section 9).

## 9. Android emulator (`.github/workflows/android-emulator.yml`)

On pull requests to `main`, for a release tag, once a week on `main` and by
hand (about 25-35 minutes, so not on every push): an x86_64 Android 14
emulator on the Ubuntu runner (KVM), from the runner's own SDK. Gradle's
downloads, Flutter and Go are cached; the weekly run on `main` writes the
caches pull requests read, and the system image downloads while the apps
build.
`tool/ci/android_smoke.sh`:

- `fresh` — a fresh install of the commit runs
  `integration_test/app_start_test.dart`: the real app must get past the
  logo within 60 s and throw nothing in its first seconds;
- `upgrade` — the previous release, built from its tag with the same debug
  key (a release APK cannot be replaced by a debug build), installed and
  started; then the commit installed over it: past the logo on the old
  data, the same node identity (the SHA-256 of its config, handed to the
  test), and no file of the old version lost;
- `monkey` — 2000 random events inside Zen (seed 20261028), then no
  crash and no "not responding" in monkey's output or the crash log.

Locally, with an emulator or a phone in debug mode:
`sh tool/ci/android_smoke.sh fresh`, `... monkey 2000 1`.

## 10. Field report → regression test (`test/regressions`)

Every bug the owner reports gets a test named after its report before it
is fixed, so nothing is forgotten and nothing comes back:

1. A file `test/regressions/r<round>_<nn>_<what>_test.dart` with one test
   named `'R5-#14: <what must hold>'` (bugs the tests found themselves:
   `'R5-F<n>: …'` in `r5_found_by_tests_test.dart`). While the fix is not
   in, the test is skipped with the description and what is known
   (`skip: 'R5-#14 open: …'`); the CI summary lists every skipped test
   ("never run"), so open reports stay visible.
2. Whoever fixes it writes the test that fails on the current code first
   (in that file, or in the feature's own test file with the file here
   pointing to it), then the fix; the skip goes.
3. A bug found again later gets a new id, never a changed old test.

`tool/ci/test_ci_checks.py` checks that every file there names its report.

## What this does not check

- The simulator does not test Bluetooth, Wi-Fi Direct, Multipeer or real
  Yggdrasil delays; offline links are tested with fake transports and in Go,
  the radios themselves (Kotlin, Swift, C++ runners) only by hand.
- The Android background service has few tests, the Kotlin code (BLE, calls)
  none.
- App tests run in CI on Windows, and on Linux only those the Windows jobs
  skip; on macOS and Windows on ARM CI only builds and (Linux, macOS) runs
  the app for 20 s. There is no APK build
  on push (only the Go bridge for the three ABIs); the emulator workflow
  (section 9) runs on pull requests to `main` and tags only; the
  `appStoreOnly` flavor is covered only by the Dart-level `store_build_test.dart`, not
  by a Gradle build in CI.
- The real-node tests (section 7) run every device as a computer in one
  process: Android's locked receiver, the iPhone's suspension and real
  phone networks are not in them.
- The Linux GStreamer player (`zen_media_player.cc`) is not tested beyond
  linking and starting; playback is checked by hand.
- The Go bridge has no random-input tests (`go test -fuzz`), and the app no
  "corrupted data sends no frame" test (damaged files: section 8).
- The harness works only in debug builds.
- Apps on one computer share one link: network splits are tested in the
  simulator.
