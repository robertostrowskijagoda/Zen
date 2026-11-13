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
discovery, Bluetooth and Wi-Fi Direct logic, the door node, and real
Yggdrasil nodes on a loopback mesh in `packet_loop_test.go`: a packet loop
held while a friend keeps sending, a node whose core stopped answering, a
first contact, restarts, and a storm of sends with restarts; see
"The Go bridge's mesh" below), translation checks (section 5), GitHub Actions on every
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

### The Go bridge's mesh

`packet_loop_test.go` runs real Yggdrasil cores on a loopback hub, under
the bridge's own nodes, and holds them to what the app needs of them:
a node's packet loop never waits for the mesh (a loop held while the peer
keeps sending must not leave the node deaf for good), what the app asks
of a node answers while its core is stalled, a first contact between
two devices on the mesh arrives within a few milliseconds of the way being
found, a device that restarted reaches its friends and is reached within a
few seconds (also when a friend writes just as it restarts, when it says
nothing, and when a friend writes again a moment after the two talked
again, `TestAMessageSoonAfterARestartIsNotLost`: ironwood can lose that
message, and the mesh writer sends it again), and four devices sending to
each other while one restarts every few seconds keep answering and talking
(`TestNodesUnderLoadKeepAnswering`, half a minute, skipped by
`go test -short`). The mesh writer's own logic
runs against a fake core in `mesh_io_test.go`, the bounded questions to a
core in `node_view_test.go`.

`go test -race` reports three data races, all inside ironwood's Debug API:
`encrypted.Debug.GetSessions` reads the byte counters each session's actor
writes, `network.Debug.GetPeers` the latency each peer's actor writes. They
are in the library (the bridge's traffic meter and the door's link check
call those functions since before), not in the bridge's code; every test
that asks a core for its sessions or peers while traffic flows shows them.

The bridge's local links and peers have tests of their own:
`local_link_handshake_test.go` (handshake version 3: a recorded hello answers
nothing played back later or elsewhere, a version 2 hello makes both sides
close, hellos of one size, a connection that says nothing leaves its slot
after two seconds), `local_link_advert_test.go` (an advert holds only as
many tags as keep a false match rare, a filter too full matches nothing on
any transport, the eight devices go in turns, a forged advert with every bit
set matches no phone), `public_peer_order_test.go` (every node's own order of
the public peers, one pick per operator, the same after a restart, a peer
added or dropped moves no other) and `stranger_signals_test.go` (the budget
that a receive-only node gives senders it does not name before the app is
woken).

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
| `phone.appTransport` | the phone's transport for other services (the recovery service, the ledger): sends through its outbox and mailboxes, receives what its engine hands to the app |
| `phone.appKeeps`, `phone.mirrored` | what the app does with each frame its engine hands over: keeps it (the default), fails to keep it (a write that failed; the relay layer hears so and the frame comes again) or never answers (an app stuck on it); and what a copy from another device of the account does here (the default is the app's own, a test can stand in for an older version) |

Not simulated: Yggdrasil itself (sessions, routing, real delays), presence
pings (the rounds of locked phones have a simulation of their own, below),
the platform (wake locks, alarms, radios) and the screens. With the app
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
| `test/message_keeping_test.dart`, `test/message_presence_test.dart`, `test/message_clock_order_test.dart`, `test/background_signal_queue_test.dart`, `test/typing_indicator_test.dart` | on the simulated friends: a message is confirmed to its sender only once it is in the chat (an app killed after the relay layer took it, a write that failed once, an app that never answers), writing to a friend or mail from a mailbox does not make anyone "just seen", a late copy does not move the chat list, a friend's clock an hour behind does not put the answer above the question (also in a group), the background queue's cap and what it keeps, "pisze…" ending by itself |
| `test/read_receipts_test.dart` | "Przeczytano" only for what the friend opened: one receipt per reading, all messages up to the one read, a receipt naming another chat's message changes nothing; a chat or a group read on one device of the account is read on its others, a device on 1.16.4 left as it was |
| `test/chat_message_removal_test.dart`, `test/chat_history_removal_test.dart` | a message deleted for everyone, disappeared or edited leaves no words in notifications, the notification list or the queue; changes that come before their message; chunks after a deletion or a cleared chat bring nothing back, also from another device of the account; leaving, declining or "Wyczyść historię" in a group removes its chat, files and notifications |
| `test/group_membership_test.dart` | who left a group stays out on every phone, in any order of leaves, lists and invitations; a later invitation brings them back; only the leaver can say they left; a leave from a Zen before 1.16.5 (no time) |
| `test/call_second_caller_test.dart`, `test/call_missed_test.dart`, `test/call_video_codecs_test.dart`, `test/call_video_trace_test.dart` | a second caller hears "busy" and the call already there goes on (ringing out, ringing in, in the background, talking, two calling each other at once, group calls); a ring nobody answered is told to the callee once, through mailboxes, from friends only, never ringing; VP8 first in every offer and answer, also where the platform refuses the preferences; the `Call video` lines of the technical log, with no address, credential or fingerprint |
| `test/call_video_quality_test.dart`, `test/call_camera_off_test.dart` | the camera asked in plain numbers (1280 x 720 at 24 frames), the camera encoder between 150 kbit/s and 2.5 Mbit/s at up to 24 frames with frames kept before resolution, the path's estimate starting at 1 Mbit/s on the camera's VP8 and H.264 only, the steadiest auto-exposure range a camera offers and what the Android side answers, the statistics lines that judge the picture (target, quantizer, resolution changes, time held back, freezes); switching the camera off and on keeps every answer acceptable to the other side |
| `test/relay_backlog_test.dart`, `test/locked_mailbox_kit_writes_test.dart` | two weeks and more of a small circle that barely uses Zen on the real relay engines: what "Czeka na doręczenie" and "Przechowujesz dla znajomych" hold at the end, the kinds where only the newest matters, a friend's device taken for gone, a receipt reaching a sender who was away, mail for a former friend going; a locked phone's mailbox kit written once per burst |
| `test/locked_presence_sim_test.dart`, `test/locked_presence_open_sim_test.dart` | the real `LockedReceiver` of several locked friends on a virtual clock (frames 80 ms on the way, a phone awake 5 s from its own round and 3 s from a frame, phones on 1.16.4 modelled as that version pinged and answered): how often they wake each other (each number with its "before"), lost pings, silent friends, a clock set back, `presence.zbox` writes; and what the first screen shows of friends the moment Zen opens after a lock |
| `test/locked_alert_conformity_test.dart` | each frame ends the same on a locked phone as in the app: rings, call cards and message notices from one shared decision, a flood of mentions from one member |
| `test/account_recovery_friends_test.dart`, `test/password_vault_recovery_test.dart`, `test/account_sync_pruning_test.dart`, `test/account_sync_deletion_markers_test.dart`, `test/ledger_contacts_backup_test.dart` | key pieces at close friends (the account password's rules, the thresholds 2/3/4, recovery end to end with three close friends, pieces sent again until confirmed, former holders, a removed friend, a helper on a new phone, a stop from a device cut off, a helper on 1.16.4); passwords and notes back with every way an account comes back, the newest copy taken, a revoked device given none, a key copy with no friend at all; the state log started over so a deleted password or note leaves it; a dating profile switched off, a photo, a nationality or a plan deleted while another device was away for weeks stays deleted on both, and one made again later is kept; friends and groups saved in parts above some 240 friends and the private log started over within its bound |
| `test/password_vault_test.dart`, `test/password_generator_test.dart`, `test/password_csv_import_test.dart`, `test/password_match_test.dart`, `test/password_screens_test.dart`, `test/password_autofill_test.dart` | "Hasła": the store's limits, earlier versions, edits on two devices, a newer or damaged vault left as it is, no secret in a debug string; the generator (classes, no modulo bias, strength); CSV files of Chrome, Edge, Firefox, Bitwarden, KeePass and KeePassXC, broken files and random bytes; matching by exact host, registrable domain, port and package, look-alike pages getting nothing; the screens behind the app password; the autofill picker (nothing leaves Zen without an unlock and a pick, a lock closes it) with the Android side faked; one question per request (the lock screen's unlock is the question for the request that was waiting, once, within its minute, never after a wrong or an emergency password, an unlock older than the request does not count, a lock forgets it), a login added in the picker (saved under the request's address, used at once, the held request, a form that ended meanwhile, a full or newer vault, a lock while typing), the first page of a login in two steps and a page with the password alone |
| `test/password_manager_setup_test.dart` | the password manager's setup with the device faked: nothing asked where Zen fills nothing, the installed browsers Zen knows in its order with what each needs (a switch of its own, nothing, probably not shown, unverified), Zen's list equal to the autofill's list of browsers and to the manifest's `<queries>`, the Android side's answer read defensively, a browser's name as one short line, the channel's calls and a missing or failing Kotlin side, the screen on Android (Chrome off or on, reading again on return, no known browser, an Android that cannot fill, the import at the end), the honest page elsewhere, the button in "Hasła" also when empty |
| `test/onboarding_first_run_setup_test.dart` | the first-start setup: the steps and their count, the password manager's step (asked first, yes shows the same setup as "Hasła", no changes nothing, the honest page where Zen fills nothing), after an update only the new step for who went through the revision before and every step for anyone further behind, the last step closing the setup opened from Ustawienia |
| `test/secure_clipboard_test.dart` | a copied secret leaves the clipboard at a lock and at the end of its time in the background, without the clipboard being read; a failed marked copy copies nothing and says so; the plain clipboard where the system has no marked one |
| `test/pyramid_era_seal_test.dart`, `test/pyramid_treasury_test.dart`, `test/pyramid_court_anonymity_test.dart` | on the pyramid's simulated world: operations dated into a sealed era count nowhere, late changes of the treasurers undo no payment, two seals of one era; a number split between orders freed by a release, a dishonest treasurer among six, what treasurers keep; the court's one-time cards (two distinct cards decide, one judge counts once, a card of one matter counts in no other, nobody outside the court holds one) |
| `test/profile_photo_gif_test.dart`, `test/diagnostics_go_crash_accounts_test.dart`, `test/ledger_device_record_key_test.dart` | a GIF profile photo keeps moving, HEIC read by the phone's own decoder (faked), animated WebP and PNG made GIFs; the Go crash file given to the bridge only for a listed account; a key named in a friend's device record is a hint from that friend's account, never a pin |
| `test/account_password_devices_test.dart`, `test/device_after_cut_off_test.dart`, `test/account_devices_names_test.dart` | the account password protects the key on every device: the wrapped key travels with the account (a link, a copy, a backup, the paper key) and between devices, the newest password wins, a device without it offers to set one; a device that appears after another was cut off is not taken until the person says it is theirs; device names are translated |
| `test/account_replace_rule_test.dart` | another account never replaces one that holds anything, by a copy, a backup, a link or a key (one rule, the holdings read in `account_holdings.dart`); adding it beside, or wiping on purpose, and passwords only when ticked |
| `test/circle_backup_fresh_copy_test.dart`, `test/circle_backup_restore_guard_test.dart`, `test/contacts_backup_fit_test.dart`, `test/password_circle_backup_switch_test.dart` | the copy with friends: a phone that is still looking never replaces it (the search goes on daily, a fresh copy needs the person's word), a copy under half the kept one waits 30 days, a copy dated ahead or signed by a cut-off device is refused, the owner is told; one large group no longer stops the copy; the passwords are a switch, the same on every device |
| `test/recovery_pieces_kept_test.dart`, `test/recovery_reduction_test.dart`, `test/recovery_forgotten_devices_test.dart` | pieces of the account key: kept until told to forget, a change to fewer holders waits a week unless confirmed with the account password, a holder silent for five weeks does not count, a forgotten piece does not come back from a device that was away |
| `test/friend_level_devices_test.dart` | a friend's level is the same on every device, the newest change wins, taken before the audience keys, back from every copy without undoing a later change |
| `test/block_book_test.dart`, `test/blocked_everywhere_test.dart`, `test/dating_block_everywhere_test.dart`, `test/feed_blocked_people_test.dart` | a block is of the person in every feature and on every device (one list, every address and key, back from every copy, a lifted block stays lifted); the wall, a post's page, the profile, the bell and notifications leave a blocked person out |
| `test/outgoing_media_metadata_test.dart`, `test/picked_file_cap_test.dart`, `test/tappable_icons_named_test.dart`, `test/password_strength_fit_test.dart` | everything sent in a chat leaves without place, time and device data however it was picked (a file that cannot be cleaned goes unchanged and says so); files opened from outside are read up to a bound; icon buttons have names for a screen reader; the strength line of a password |
| `test/call_remote_picture_test.dart`, `test/call_controls_before_answer_test.dart`, `test/call_answered_elsewhere_test.dart` | the remote renderer is bound by the track once the platform has the stream, and again when decoded frames never reach the screen; VP8 first whatever either side lists; microphone, loudspeaker and camera work while it rings; a call taken on another device leaves no missed call |
| `test/chat_scroll_touch_test.dart` | the conversation does not move under a finger: while the list is dragged or flung, a message, a receipt, the typing line or a file shifts nothing and waits on *to newest* |
| `test/message_copy_vault_test.dart`, `test/disappearing_timer_order_test.dart`, `test/friend_invite_delivery_test.dart` | a message copy that comes again writes its file once; a disappearing timer carries a stamp that orders every change, an older message does not switch it back on; an invitation says whether it arrived and can be sent again |
| `test/background_runner_conformity_test.dart` | one test runs the same signals through the app and through every runner (the default account, an additional account receiving in the background, the computer's tray): each rings and notifies by its own account's rules, a runner without a notice kit stays quiet, a muted friend's other devices stay quiet |
| `test/locked_stranger_wake_test.dart`, `test/locked_wake_grid_sim_test.dart` | strangers cannot keep a locked phone awake (the hold only for friends, own devices and mailboxes, sixty an hour for the others, urgent pings only for friends); a model of Android's alarm windows for phones in a star of locked friends, with and without exact alarms (the wakes an hour and the longest gap; the figure "6 an hour" is this model's, not a phone's) |
| `test/ledger_fold_test.dart`, `test/relayed_comment_test.dart`, `test/pebble_found_by_friends_test.dart` | what friends keep of reactions and profile is folded with a bound (a signed start of the log, the author's word, a bound per friend, posts never folded); a relayed comment carries the signed part its id hashes, a copy that proves itself wins; a pebble's "found" count takes only the author's friends |
| `test/dating_minor_report_test.dart`, `test/dating_safe_date_clock_test.dart` | a profile is hidden for everyone only when two of its owner's own friends reported it, two keys of one person count once, a report is withdrawn, a switched-off profile announces no match; the date watcher counts from when the word arrived, an unconfirmed date goes a week after the alarm |
| `test/pyramid_sign_rule_test.dart`, `test/pyramid_order_time_test.dart`, `test/pyramid_outside_verdict_test.dart`, `test/pyramid_wallet_uncounted_test.dart` | a treasurer signs only what its own ledger counts, a payee counts only what the statement lists, a refused order is dated again, a statement fits any number of treasurers; an outside verdict is shown as named friends' word; what a seal left out is shown in the wallet |
| `test/password_public_suffix_test.dart` (with `test/fixtures/public_suffix/test_psl.txt`, the list's own vectors), `test/password_vault_two_devices_test.dart`, `test/password_csv_recovery_test.dart`, `test/account_decoys_vault_size_test.dart` | a login is offered only within one registrable domain of the Public Suffix List, hosts in their ASCII form; two devices editing and importing, each version naming its parent, conflicts never pruned, duplicates merged; a damaged CSV row costs that row; a decoy's password file can be as large as a real one |
| `test/update_notice_signed_versions_test.dart`, `test/net_address_test.dart` | the update notice waits for the signed checksums and forgets a withdrawn version; addresses not worth announcing (6to4, Teredo, the newer documentation range) are left out |
| `test/i18n_labels_test.dart`, `test/i18n_plural_one_test.dart` | a text that quotes a button or a screen uses that label's own translation, and a plural's form for one shows the number in languages where that form also covers 21 or 0 (section 5) |

A new scenario: build a world, perform actions, `await w.net.run()`, check the
state at a **different** person than the one who acted, and finally
`expect(w.views().values.toSet(), hasLength(1))`.

The shared wake of a locked phone (`test/zen_wake_test.dart`, group "a
locked phone, its alarms as Android delivers them") runs the real receiver,
the look around, the update check's work and the link check for hours on a
virtual clock, with its alarms in one of two models: every alarm on time,
or as Android 12 and later delivers them. In the second an inexact alarm
gets a window of three quarters of its delay (from 10 s on) and goes off
at the window's end unless the phone wakes earlier for anything else,
which takes along every alarm whose window has begun; an exact alarm goes
off on time. Other apps' wakes (0, 12 or 60 an hour) and the token change
of a phone shown nearby (an exact alarm just past every 10-minute
boundary) are part of the model. The tests count Zen's own wakes an hour
and the longest gap between rounds, with the numbers before this version
beside them (shown nearby: about 8 wakes an hour and rounds up to 17.5
minutes apart before, 6 now; not shown nearby: rounds up to 17 minutes
apart before, every 10 minutes now). Before 1.16.5 a locked phone's hours
were counted on alarms that all came on time, which hid both gaps. The
model is a model:
how a real phone spaces its alarms in Doze (Android 8 to 11) and whether
one alarm just before the token change really shares its wake are checked
on a phone ([RELEASES.md](RELEASES.md), section 3).

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

### 4.3 The promo films (`tool/promo/make_promo.py`)

```
dart run tool/screenshots.dart                       # the screens, into build/shots/
python tool/promo/make_promo.py --ffmpeg <ffmpeg>    # the films, into tool/pages/promo/
```

A 42-second film in Polish and English, vertical (1080 × 1920) and
horizontal (1920 × 1080), drawn frame by frame from the frames in
`build/shots/` and cut to the beats of a CC0 track. The script also leaves
contact sheets in `build/promo/` (one frame every 2 seconds) to look over,
and reads the end card's QR code back with the app's own decoder
(`tool/promo/qr_test.dart`). How it works, what it writes and how to change
the texts: [tool/promo/README.md](../tool/promo/README.md).

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

Two more checks keep the translations honest. A text that quotes a button
or a screen of the app must use that label's own translation (the empty
"Close friends" filter once told people to mark someone as "Friend", the
middle level; `test/i18n_labels_test.dart`, with the scanner in
`tool/i18n/scanner.dart` and the few allowed exceptions in
`tool/i18n/label_exceptions.dart`), and a plural's form for one must show
the number in the languages where that form also covers 21 or 0
(`test/i18n_plural_one_test.dart`: where 21 takes the form of 1, a text must
not drop the number from it). `tool/i18n.dart` reports both.

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
folder is a few dozen kilobytes. The fixtures are written on Windows, where the
store folds every key to lower case before it hashes it into a hidden file
name; on Linux and macOS the same keys name other files, so the tests that
read them are skipped there and *Start on older data* runs on Windows.

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
| Docs and site | Ubuntu | every run: no broken link in the Markdown files and on the website (`tool/ci/check_links.py`, which runs `tool/ci/check_site.py` too: every page holds its menu and footer without JavaScript, in a `<noscript>` block made from `site.js`'s own list, `--write` makes them; every link, image, script and style names a file or folder that exists, a `#fragment` an id of its page, a repository link a path that exists, a download link a file the release attaches; nothing is loaded from another host; every page has a language, one title and one h1, a description, a canonical address and alt texts), the release contract (`tool/release.dart check`), the Python tests of `tool/ci` and that every screenshot of the website is there (`tool/screenshots.dart --check`); when only documentation changed, also the app's tests that read it (`flat_door_link_test.dart`, `legal_consent_test.dart`, `pages_site_test.dart`, `release_contract_test.dart`, `security_hardening_test.dart`) |
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
internet, and the radios for friends nearby are off. The hub's key is below
any device's, so the hub is the root of the mesh's tree, as a long-standing
node is on the real mesh: a device that comes on or restarts never moves it.
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
| `restart_e2e_test.dart` | a restart keeps the identity, friends, names and chats, a friend's message right after the start and the answer get through within seconds, presence is confirmed again after the start |
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
`kAfterRestartWithin` (5 s: on this computer an invitation shows within
about a tenth of a second once the invited device can be found, a second or
two after it came on the mesh, and the first message to a device that just
restarted takes from a few milliseconds to about two seconds, as ironwood
can lose a packet then and the bridge sends it again; both took about 14 s
before the bridge's mesh writer, R5-F5), `kMessageWithin` (10 s).

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
- `monkey` — the commit's app, then 500 random events inside Zen (seed
  20261028), then no crash and no "not responding" in monkey's output or
  the crash log.

Then the instrumented Kotlin tests (`android/app/src/androidTest`, JUnit
on the real Android): `./gradlew :app:connectedDebugAndroidTest
-Ptarget-platform=android-x64` in `android/`, with the same debug build.
They check what `ZenFileProvider` hands out (only the shared installer and
the QR sticker, readable through their content address) and which of Zen's
components other apps may start (the launcher entries and "Otwórz w Zen";
the file provider never; the autofill service only by the system, and its
picker by nobody else). Gradle installs the app and its test app and
takes both off again.

The start test is built into the app (`flutter build apk -t
integration_test/app_start_test.dart`), installed with adb, opened from the
launcher, and its result read from the log: `flutter test -d` cannot start
Zen, whose launcher entry is an activity-alias (the icon can change), since
flutter's tool looks for the launch activity among plain activities only.

Locally, with an emulator or a phone in debug mode:
`sh tool/ci/android_smoke.sh fresh`, `... monkey 500 1`.

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

## 11. Chaos, fuzzing, coverage and mutations

### 11.1 Protocols on a bad network (`test/protocol_chaos_test.dart`)

The protocols of several steps on the simulated friends of section 1.1,
with a network that loses a quarter of the datagrams, duplicates a fifth
and reorders them by its random delays, on many seeds: an invitation and
its answer make the same friendship on both sides; every member of a group
ends with the same members and gets its messages once; messages through the
mailboxes arrive once, in order, and nothing stays "waiting" in the
sender's outbox once the recipient has everything. The world is built on a
quiet network and made lossy afterwards (its helpers make friends in one
settle). Six seeds in every run (seconds); `ZEN_CHAOS_SEEDS=50` tries more.

### 11.2 Random frames (`test/signal_fuzz_test.dart`, `wire_fuzz_test.go`)

The Dart side: random and broken frames of every signal type go into the
parser (it must never throw) and, from a stranger, into the social
controller (they must never make a friend, change who is one, join a group
or change its members). Frames aimed at a friend's live location and poll,
from a stranger and from another friend in the group, must never change,
delete or move them; the other friend's vote still counts. What the parser
lets through as a poll or a location is one the app can show. Seeded
(`ZEN_FUZZ_SEED`), `ZEN_FUZZ_FRAMES=20000` tries more.

The fuzzer keeps up with the parser by itself:
`test/fuzz_coverage_test.dart` fails while a frame type the parser knows
(`case '…'`) or a field it reads (`payload['…']`, `payload[kPollKey]`) is
missing from `_types` / `_keys` of the fuzzer. A new chat extra also gets
a shape of its own in `_value`, as `_poll` and `_location` have. The Go side: `native/yggdrasil_bridge/wire_fuzz_test.go` has a
fuzz target for every parser of what comes from the network or a nearby
device (relay frames, IPv6 packets, LAN beacons, the local link's hello and
frames, the door's JSON, DNS questions, signal reassembly), with round trips
where there is a builder. `go test` runs their seeds; the CI job *Go
bridge* also fuzzes **every target of every package** for 8 seconds in every
run (`tool/ci/go_fuzz_targets.sh` lists every `func Fuzz` of every
`*_test.go` under `native/`, the ironwood copy included, and fails on an
empty list: the step once read one file, so 14 targets ran as seeds only). A finding is
written to `testdata/fuzz/<target>/`; committed, it becomes a seed.

### 11.3 Coverage

`dart run tool/test.dart --coverage <folder>` writes each run's line
coverage; `python tool/ci/coverage_report.py <folder>` adds the runs up and
names the files of `lib/` no test loads and the least covered of the bigger
ones. Every CI run does it (the six test jobs, summed up in the summary of
*Analyze and test*); it informs and never fails (`--min` would make it).

### 11.4 Mutations (`tool/mutation.dart`, `.github/workflows/mutation.yml`)

The core files of `tool/mutation_targets.json` changed in one small place
at a time, as a slip would change them (`==`/`!=`, `<`/`>=`, `&&`/`||`,
`true`/`false`, a `!` dropped, `+ 1`/`- 1`), each change run against the
file's tests; a change no test notices is named in the summary, a line to
pin down. On every pull request to `main` (eight runners beside CI, about
13 files and 26 minutes each, 10 changes per file; a file takes about two
minutes), weekly and by
hand; each run tries other changes (the seed is the run's number). The
list grows with every release (100 files in 1.17.0, of the 128 that eight
runners hold): `tool/ci/test_ci_checks.py` fails when a runner would get
more than 16 files, and the workflow's matrix then gets another runner. The
limit was 20 before; a runner with 30 files did not end within its 45
minutes and no run of 1.16.5 said anything, and at 20 a runner took about
43 of them. The summary is written file by file, so a runner cut off
by its 45 minutes still says how far it got. On the runners a file's
changes get 90 seconds (`--budget 90`): once they took that long no further
change of that file is started, and the summary says how many were tried.
Without it one runner of eight took over its 45 minutes in 1.17.0 while
another took 15, each with 13 files: a file with slow tests ran them
eleven times. A change that makes a test hang (after `--timeout`, 240 s)
or eat memory (a `flutter_tester` past 2 GB, as an endless loop that writes
on every turn does within seconds) counts as noticed; the test is stopped
before it takes the machine down. Locally:
`dart run tool/mutation.dart [file] --max 40`.

The targets grow with the app. `dart run tool/release.dart prepare` names
every file changed since the last release that is plain logic (no widgets,
nothing under `presentation/`) with a fast test of its own
(`test/<name>_test.dart`, not among the slow ones of `tool/test_times.json`)
and is not in `tool/mutation_targets.json` yet. Each goes in there before
the release, or goes in with `"skip": "<reason>"` (listed, never run), so
the reminder stops naming it. Survivors of a new target are pinned with a
test in the same pull request, unless the change behaves exactly as the
original (an equivalent mutant: `growable: true`, a flag that only makes
something be read again); those are named in the pull request.

### 11.5 Kotlin unit tests (`android/app/src/test`)

JVM tests (JUnit) of the Kotlin code with no Android in it: the
power-button alarm's counting (`PowerPressCounter`), where a link Zen
claims goes instead of back to Zen (`linkTargetWithoutZen`) and which
fields of a login form autofill takes for the login and the password
(`ZenAutofillFieldsTest`: hints first, hints that say nothing, as
`autocomplete="off"`, leave the field to its type, a new password or a
one-time code is no password to fill, two password fields offer nothing,
the first page of a login in two steps fills the login alone, a page's
address counts only in a known browser), which browsers the password
setup looks at and what their provider's answer means
(`ZenAutofillSetupTest`: only package names, each once and at most 40,
only the documented values of the switch, the provider is the browser's
own) and how long a request waits while a new login is typed
(`ZenAutofillTimeoutTest`: five minutes from when it opened, a minute to
pick but never past the same end), whose certificate may vouch for a
page (`ZenAutofillTrustTest`: a browser's word counts only when the
installed package is signed by that browser's maker, the fingerprints are
pinned, a browser without a confirmed one is filled like any other app),
who signs an APK as Android verified it, with its lineage (`ApkSignersTest`),
the window of an inexact alarm that ends on the ten-minute grid
(`InexactAlarmWindowTest`) and a call camera's frame-rate ranges read in
frames a second whatever unit the camera reports in (`CallCameraRangesTest`). The CI job
*Kotlin unit tests* runs them in every run (`ZEN_SKIP_GO_BRIDGE=1
./gradlew :app:testDebugUnitTest` in `android/`).

### 11.6 Race detector (Go)

The CI job *Go bridge* runs the bridge's tests once more under the race
detector (`go test -race -count=1 ./...`, cgo on): two goroutines touching
one variable without a lock or an actor between them fail the run. The few
tests that measure speed skip themselves under it (`raceEnabled`,
`race_on_test.go`). It found ironwood's counters read across actors
(`third_party/ironwood/ZEN.md`).

### 11.7 Leak tracking (Flutter)

`flutter test --dart-define=zen.leaks=true` tracks every object Flutter
can (notifiers, controllers, animations, pictures, overlay entries) that a
test's widgets made: one never disposed fails its test file
(`test/flutter_test_config.dart`). Not counted: what the test helpers make,
objects only not collected yet, process singletons, Flutter's image cache
and the services the tests themselves build (the list in that file). It
runs on demand, not in CI: some test files still report notifiers the
tests leave behind; a new class in its report is worth a look.

## What this does not check

- The simulator does not test Bluetooth, Wi-Fi Direct, Multipeer or real
  Yggdrasil delays; offline links are tested with fake transports and in Go,
  the radios themselves (Kotlin, Swift, C++ runners) only by hand.
- The Android background service has few tests; of the Kotlin code only
  what has no Android in it has JVM unit tests (section 11.5), BLE and
  calls none.
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
- The app has no "corrupted data sends no frame" test (damaged files:
  section 8); random frames from the network are section 11.2.
- Of 1.16.5, only a phone shows: video between two Android phones (the
  VP8 preference is tested on descriptions, not on hardware codecs); the
  autofill service with real apps and browsers (of the Kotlin side only
  the reading of a form's fields, the setup's packages and a request's
  time have unit tests and the manifest an emulator test, section 9; the
  picker is tested with the Android side faked); the phone's own
  decoder for HEIC photos (faked); the clipboard emptied from the
  background; the alarm windows of a real phone (section 1, the model);
  the Android service taking over from a hung app; key pieces and the copy
  with friends end to end between real phones (simulated between
  services only). [RELEASES.md](RELEASES.md), section 3, lists what to
  try before a release.
- The password manager's setup and the autofill row of the release after
  1.16.5 were tried on no phone: Chrome's switch read through its provider
  and its settings page opened, what Brave, Vivaldi, Firefox and its forks
  really need, whether Edge, Samsung Internet and Opera show Zen at all,
  the row in the light and the dark theme, and the suggestion inside a
  real keyboard. The setup is tested with the device faked, the browsers'
  answers as the documentation describes them.
- The harness works only in debug builds.
- Apps on one computer share one link: network splits are tested in the
  simulator.
