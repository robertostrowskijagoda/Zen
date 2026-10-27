# iPhone: receiving in the background

Zen has no servers, so it cannot use push notifications: Apple delivers
pushes only from a server that holds an APNs key. Everything in this document
is what an app can do on its own, on an iPhone that installed Zen by
sideloading (Scarlet, SideStore or AltStore: the unsigned IPA re-signed with a
certificate of the signer).

Short version:

| Mechanism | In Zen | When it runs | For how long | Cost |
|---|---|---|---|---|
| Zen open on the screen | always | while open | as long as it is open | normal |
| Finishing after leaving the app (`beginBackgroundTask`) | **yes** | every time Zen leaves the screen | about 30 s, usually less | negligible |
| Background refresh (`BGAppRefreshTask`) | **yes** | when iOS decides: at the earliest 15 min after leaving, in practice a few times a day for an app used daily, rarely or never for an app used rarely | about 30 s (Zen uses at most 25 s and stops earlier when it is done) | small |
| Charging catch-up (`BGProcessingTask`) | **yes** | when iOS decides: the phone is charging, idle and online, typically at night | minutes (Zen uses at most 3 min) | none on battery |
| Shortcuts action "Sprawdź wiadomości Zen" (App Intent) | **yes, set up by the person** | at the times of the person's Shortcuts automations (for example every hour) | about 20 s | small |
| Keep-alive with a silent sound (`audio` mode) | **yes, opt-in, off by default** | all the time while Zen is in the background | until something stops it (see below) | high |
| VoIP push (PushKit) | no | needs APNs, so a server | — | — |
| Silent remote notifications | no | needs APNs, so a server | — | — |
| Local Push Connectivity (`NEAppPushProvider`) | no | managed entitlement, specific Wi-Fi networks only, not available to free Apple IDs | — | — |
| Network Extension ("VPN" mode) | no | not available to free Apple IDs (see below) | — | — |
| Significant location changes | no | see below | — | — |
| Bluetooth LE background modes | not yet | see below | — | — |
| Friends' mailboxes | always | the baseline: mail waits with up to 6 friends until the iPhone asks | 14 days | none |

All of it works whether Zen is unlocked or locked: a locked Zen keeps
receiving like a locked Android phone (see "A locked Zen receives too").

So: an iPhone still receives **reliably only while Zen is open**, and
otherwise **now and then**: when iOS chooses, and at the times of the
person's Shortcuts automations. Messages are never lost because of this:
they wait in the friends' mailboxes and arrive at the next check or the next
time Zen is opened. The only way to receive continuously is the opt-in
keep-alive, at a clear battery cost.

## What Apple enforces no matter how the app is installed

Sideloading removes App Review, nothing else. The system's rules for apps in
the background are the same for every app:

- An app is suspended a few seconds after it leaves the screen. A suspended
  app runs no code at all: no network, no timers.
- Background refresh and processing tasks are scheduled by iOS from its own
  model of how the person uses the app, the battery, the network and the
  time of day. `earliestBeginDate` is a lower bound only; there is no way to
  ask for a fixed interval.
- No background task runs when:
  - the person swiped the app away in the app switcher (until they open it
    again),
  - Low Power Mode is on,
  - Settings → General → Background App Refresh is off (for all apps or for
    Zen),
  - the signature expired (7 days with a free Apple ID): iOS does not start
    the app at all.
- iOS can terminate an app in the background at any time when it needs
  memory, including one that plays sound.

What a free Apple ID changes is the set of **entitlements**: personal teams
cannot use push notifications or Network Extensions. Background modes are
plain `Info.plist` keys, not entitlements, so `audio`, `fetch` and
`processing` work with free signing, and `BGTaskScheduler` needs no
entitlement. App Intents need no entitlement either. The task identifiers do
not have to start with the bundle id, which a re-signing tool may change.

## What Zen does

Native side: `ios/Runner/ZenBackgroundBridge.swift` and
`ios/Runner/ZenCheckIntent.swift`. Dart side:
`lib/src/features/runtime/ios_background.dart` (the host that answers iOS,
the unlocked app's part) and `lib/src/features/runtime/ios_locked_receiver.dart`
(the locked receiver on an iPhone, the engine without a screen). Settings
page: Settings → Praca w tle
(`lib/src/features/runtime/presentation/ios_background_section.dart`); the
same choices are a step of the first-run setup, and the iPhone's own
settings are checked on the permissions screen.

### A locked Zen receives too

Zen encrypts everything it stores with a master key that exists only while
the app is unlocked. A locked Zen therefore runs the same **locked
receiver** as a locked Android phone (`LockedReceiverSession` in
`android_background_runtime.dart`, `LockedReceiver`, `LockedOutbox`,
`LockedMailbox`), which holds no master key, only a separate background key:

- the node's identity (the node config) is sealed with the background key,
  so the receiver can run the node without the password;
- what arrives is kept sealed in the inbox for a key the receiver cannot
  open, and handed to the app after the unlock
  (docs/SECURITY_MODEL.md, "The locked phone");
- notifications say as much as the conversation's notification level
  allows, at most the first 80 characters of a message;
- the receiver acknowledges what it kept, answers friends' presence pings,
  asks its mailboxes for held mail, keeps sending this device's queue (the
  outbox kit, sealed for each recipient) and stays a mailbox for friends who
  chose this iPhone (the mailbox kit).

The background key is in the keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, like every Zen keychain
item: readable while the screen is locked once the phone was unlocked after
a restart, never synced or restored to another device. The receiver's files
use iOS's default file protection (readable after the first unlock), so it
can write the inbox with the screen locked.

While unlocked, the app keeps what the receiver reads in step: whom to take
mail from (the background capability), the names and levels for
notifications (the notice kit), this device's queue (the outbox kit) and the
mail it holds for friends (the mailbox kit). Only the default account
receives while locked. The doors, people nearby and the power-button alarm
are not part of an iPhone's locked receiver.

Where the receiver runs:

- **Zen is in memory** (it was used and then left, or the person locked it):
  in the app's own Flutter isolate. When Zen locks, the app writes the kits,
  its own node goes down and the receiver starts its node (one node per
  identity: the app's node config is read only once the receiver let go,
  `IosNodeGate`). On unlock the receiver stops, the app's node starts and
  the kept frames are handed to the app.
- **iOS starts Zen from scratch** for a background task or a Shortcuts run
  (Zen had been terminated, or the phone restarted and Zen was not opened
  since): there is no scene and so no Flutter engine. The native side then
  starts a Flutter engine without a screen
  (`FlutterEngine(allowHeadlessExecution:)`) that runs the Dart entry point
  `zenIosBackgroundMain`: the locked receiver for the task's budget, then
  `done`, and the engine is let go. This is how Android's background service
  runs too: an engine without an Activity that reads only what the
  background key opens. If Zen comes to the screen meanwhile, the engine is
  told to stop; it answers `done` only once its node stopped, and the app's
  node waits for that before it starts. The bridge also refuses to start a
  second node with a key that already runs in the process, so a hand-over
  that slips leaves the app retrying instead of two nodes with one identity;
  only a node nobody has called on for a minute (its engine went away
  without stopping it) is stopped to make room.

With the keep-alive on and Zen locked, the receiver keeps running, so
messages arrive within seconds with notifications also while Zen is locked.

### Finishing after leaving the app

When Zen leaves the screen it asks iOS for its usual extra time (up to about
30 seconds). A message sent just before leaving still gets its copies into
the recipient's mailboxes (that happens a few seconds after sending when the
recipient does not answer), and answers in flight still arrive. The time ends
early when Zen comes back to the screen, or when it locks and no locked
receiver can run (no background capability yet).

### Background checks

Each time Zen leaves the screen, and after each check, it asks iOS for:

- a background refresh (`com.roj.zen.refresh`), at the earliest 15 minutes
  later;
- a charging catch-up (`com.roj.zen.catchup`), which needs a network and
  external power.

When iOS wakes Zen for one of them:

1. the mailboxes are asked (`rly_poll`) for what they hold and whatever
   waits to be sent is tried again — by the relay engine's `activate` when
   Zen is unlocked, by the locked receiver (and its outbox) when it is
   locked;
2. they are asked again every 8 seconds while nothing at all came in (the
   node's links may need a moment after the app was frozen), and once more
   when the first frame shows the links are back but no mailbox has answered
   yet;
3. the check ends when nothing has come for 5 seconds (not before 8
   seconds), at the end of its budget (25 seconds for a refresh, 3 minutes
   for a catch-up), or at once when iOS takes the time back.

What comes in is handled as it is whenever Zen is in the background: stored
(sealed, while locked), and shown as a notification.

The settings page shows whether iOS allows background refresh, Low Power
Mode, when iOS last woke Zen and how that went ("skrzynki sprawdzone",
"Zen nie mógł sprawdzić skrzynek", "zabrakło czasu"), and how many times it
did since installation. These come from the app's preferences and hold only
times and a word. The diagnostics log has a line for each check:
`Background check (iOS): N frames in S s.` (`(iOS, locked)` from the locked
receiver in the app, `(iOS, no app)` from the engine without a screen).

### The Shortcuts action ("Sprawdź wiadomości Zen")

Zen offers an App Intent, "Sprawdź wiadomości Zen", with
`openAppWhenRun = false`: it runs the same background check (in the app's
engine when Zen is in memory, otherwise in the engine without a screen) with
a budget of about 20 seconds, without opening Zen. It is listed in Shortcuts
as soon as Zen is installed (`AppShortcutsProvider`), so nothing has to be
set up in Zen.

Its value is an automation: Shortcuts → Automatyzacja → Nowa automatyzacja →
Pora dnia, a time and "Codziennie", "Uruchom natychmiast", the action
"Sprawdź wiadomości Zen". A Time of Day automation repeats daily at most, so
"every hour" means one automation per hour (for example from 7 to 23). iOS
runs these at the chosen minute, which is far more predictable than
background refresh. iOS may show a short banner each time an automation runs
(it can be switched off with "Powiadamiaj o uruchomieniu" where iOS offers
that option). The settings page shows when Shortcuts last ran Zen and how
many times it did; the steps and a button to open Shortcuts are in Settings
→ Praca w tle and in the first-run setup.

The action needs iOS 16 (App Intents); Zen supports iOS 15, so the framework
is weak-linked and the action simply does not appear on iOS 15.

### Keep-alive ("Cichy dźwięk — odbiór na bieżąco")

Off by default; turning it on asks for confirmation with a battery warning.
While Zen is in the background, the switch is on and either the unlocked
app or the locked receiver runs, it plays a looping, silent sound in an
audio session that mixes with other apps (`.playback` with
`.mixWithOthers`). An app that plays sound keeps running in the background,
so Zen's node stays connected and messages and call invitations arrive
within seconds, with notifications.

It stops when Zen comes back to the screen and when the switch is turned off;
the audio session is then given back as it was. A lock no longer stops it:
the locked receiver takes over the node.

Trade-offs, honestly:

- **Battery.** The audio hardware stays awake and, more importantly, so do
  the CPU and the radio for the node's traffic (its peers, friends' presence
  pings, mailbox duty). Expect a clearly faster drain even when nothing
  arrives; how much depends on the phone and the network and has to be
  measured (see the test list).
- **Fragile.** A phone call, Siri or an alarm interrupts the sound; Zen
  starts it again when the interruption ends, but iOS may suspend Zen in
  between. iOS may terminate Zen when it needs memory (the Go node and the
  Flutter engine are not small). Swiping Zen away ends it. After a restart it
  starts only when Zen is opened.
- **Calls.** A Zen call holds the audio session itself; the keep-alive leaves
  the session alone then (changing it would cut the microphone). An incoming
  Zen call shows as a notification, not as the system call screen; while
  Zen is locked, the notice says only that someone is calling.
- **Other audio.** Music and podcasts in other apps keep playing; the
  ring/silent switch behaviour of Zen's own sounds is unchanged, because the
  session is restored when Zen is on the screen.
- **App Store.** Apple rejects apps that play silence to stay alive. This is
  why it exists only because Zen is sideloaded, and why it is a choice and
  not the default.

### Choosing how Zen is woken

Settings → Praca w tle and the first-run setup (iPhone only) show the three
ways as separate choices, each with how often it wakes Zen and what it
costs:

1. **Automatyczne budzenie przez iOS** — background refresh and the
   charging catch-up; always on unless iOS says no, with the live status of
   Background App Refresh and Low Power Mode and a button to Zen's page in
   the iPhone's Settings.
2. **Automatyzacja w Skrótach co godzinę** — the Shortcuts action with the
   steps, a button to open Shortcuts and when it last ran.
3. **Cichy dźwięk — odbiór na bieżąco** — the keep-alive switch.

Below them, and on the permissions screen, a check of what the iPhone's own
Settings must allow: Background App Refresh for Zen, Low Power Mode off,
notifications allowed (each with what iOS says now), and the advice not to
swipe Zen away in the app switcher.

## What was considered and left out

- **PushKit / VoIP pushes and silent pushes** would be the real solution
  (iOS wakes the app for each message, even after a restart), but both need
  an APNs server, which Zen does not have and will not have.
- **Local Push Connectivity (`NEAppPushProvider`)** keeps a connection to a
  server on chosen Wi-Fi networks. It needs a managed entitlement Apple
  grants on request, a Network Extension (not available to free Apple IDs)
  and still a server to connect to.
- **A Network Extension in "VPN" mode** (a packet tunnel provider that would
  keep the node running as a system extension) is impossible with a free
  Apple ID: personal teams do not get the Network Extensions capability, and
  SideStore / AltStore drop entitlements the signing team does not have.
- **Significant location changes** relaunch an app after the phone moved
  about 500 m or more, for about 10 seconds. It would need the "Always"
  location permission for a messaging app, which is a poor trade for
  privacy, and it never fires for a phone that stays at home or at work.
  Not implemented.
- **Bluetooth LE background modes** (`bluetooth-central`,
  `bluetooth-peripheral`) let iOS wake Zen for a friend's device nearby and
  keep Bluetooth links going in the background. It would help only for
  friends within Bluetooth range, and Zen's Bluetooth code scans for every
  device and stops when Zen leaves the screen; background scanning works only
  for a specific service UUID, without duplicates, and background advertising
  is visible only to other iPhones scanning for it. A possible later step,
  not a quick one.
- **The old background fetch API** (`setMinimumBackgroundFetchInterval`) is
  deprecated and uses the same scheduler as the background refresh.

## The mailbox model

The baseline does not change: when an iPhone does not answer, the sender's
device leaves an encrypted copy with up to 6 of the iPhone's friends, who
hold it for 14 days. The iPhone collects it at the next background check or
when Zen is opened. Senders already see this in each message's delivery line ("Czeka
w skrzynkach u znajomych odbiorcy (n)"), and the iPhone itself shows a
one-time card and a line in "Dlaczego nie działa?" explaining when it
receives. It works best when at least one friend runs Zen on a computer or an
Android phone, which stay online and keep the mail. An iPhone is a mailbox
for its friends whenever it runs (open, during a check, with the keep-alive),
locked or not.

## Open questions

- **CallKit.** While the keep-alive runs, an incoming Zen call could show the
  system call screen instead of a notification.
- **Telling senders.** A sender could be told that the recipient is an iPhone
  that receives with delay; that would mean sharing the platform with friends.

## What to test on an iPhone

None of the native code can be built or run on Windows. The iOS workflow
(Actions → iOS → Run workflow) builds the unsigned IPA and is the first
check that the Swift compiles.

1. **Build and install.** Run the iOS workflow, install the IPA with
   SideStore, open Zen and unlock it. Nothing should look different. Zen
   starts with a new node identity if this iPhone ran an earlier build (the
   node config is now sealed with the background key).
2. **First-run setup.** On a fresh install (or Settings → Ponownie
   przeprowadź konfigurację), step 3 is "Jak iPhone ma budzić Zen?" with the
   three choices and the settings check.
3. **Settings page.** Settings → Praca w tle. Option 1 should say background
   refresh is on and "iOS jeszcze nie obudził Zen w tle". Turn off Settings
   → General → Background App Refresh → Zen, come back: the line and the
   check below say it is off, with the button to Zen's Settings page. Turn
   on Low Power Mode, come back: same. Turn off notifications for Zen: the
   notifications row says so. Undo all. Settings → Uprawnienia i Bluetooth
   shows the same check.
4. **Finishing after leaving.** With a friend's device offline, send them a
   message and go to the home screen at once. On another friend's device (one
   of the recipient's mailboxes), or in the message's delivery line once you open
   Zen again, the copy should be in the mailboxes within about 10 seconds.
5. **Locked receiver in memory.** Lock "Po wyjściu z aplikacji" with 1
   minute, keep-alive off. Leave Zen in the background, wait 2 minutes (Zen
   locks), and have a friend send messages over the next hours. Expected:
   some arrive as notifications without opening Zen, showing at most the
   start of a long message (or less, per the conversation's level); the
   settings page shows "skrzynki sprawdzone"; the log has `Background check
   (iOS, locked)` lines. Unlock: every message is in its chat once, the
   notifications go.
6. **Background refresh, unlocked.** Lock "Przy zamknięciu aplikacji" (or no
   password) and repeat 5. Note how many wake-ups a day you get.
7. **Cold start.** Restart the phone, unlock the phone (not Zen) and do not
   open Zen. Wait for a wake-up, or run the Shortcuts action (9). Expected:
   messages arrive as notifications; the log has `Background check (iOS, no
   app)`. Open Zen while such a check runs: Zen opens normally, its node
   comes up (Settings → Sieć) and nothing is lost or duplicated after the
   unlock.
8. **Before the first unlock after a restart.** Restart and do not unlock
   the phone; send messages. Nothing can arrive (the keychain is closed);
   after unlocking the phone they arrive at the next check or opening.
9. **Shortcuts action.** In Shortcuts, find "Sprawdź wiadomości Zen", run it
   by hand with Zen in the background (unlocked, then locked, then after a
   restart): messages arrive, Zen does not open, the settings page counts
   the run. Create Time of Day automations for the next hours ("Uruchom
   natychmiast"): note whether a banner shows and whether each run delivers.
10. **Charging catch-up.** Leave the phone charging overnight with Zen in the
    background (locked). Expected: the count grows overnight and messages
    sent in the evening are there in the morning.
11. **Swiped away.** Swipe Zen away in the app switcher and wait some hours.
    Expected: the count does not grow until Zen is opened again (a Shortcuts
    run still works: it starts Zen without a screen).
12. **Keep-alive.** Turn on "Cichy dźwięk — odbiór na bieżąco" (confirm the
    dialog), go to the home screen. From another device send messages and
    start a call. Expected: notifications within seconds; the call
    notification opens Zen and the call works (microphone too). Let Zen lock
    (1-minute lock): messages still arrive within seconds, with locked
    notices; after unlocking they are all in the chats once.
    - Battery: note the battery level, leave the phone idle for 1 hour with
      Zen in the background, note it again; repeat with the switch off.
      Settings → Battery shows Zen's share.
    - Play music in another app: it must keep playing at normal volume.
    - Receive a phone call, hang up, wait 2 minutes, send a message from
      another device: it should still arrive at once.
    - Use Siri once, same check.
    - After a Zen call ends with Zen in the background, check that messages
      still arrive at once.
    - Open Zen: play and record a voice message; the ring/silent switch must
      behave as before.
    - Turn the switch off, go to the background: after about 30 seconds
      messages should stop arriving until the next check or opening.
13. **Mailbox for friends.** A friend who chose this iPhone as a mailbox
    sends to someone offline while this iPhone's Zen is locked with the
    keep-alive on: the deposit is kept and handed over when the recipient
    comes online; after unlocking, the iPhone's mailbox still holds what it
    did not hand over.
14. **Nothing else broke.** The app switcher still shows the cover instead of
    Zen's screen; calls, voice messages and films play as before.

If you have a Mac with Xcode and can run a debug build on the phone, a
background task can be forced from the debugger instead of waiting (pause
the app in Xcode with Zen in the background, then resume):

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.roj.zen.refresh"]
```
