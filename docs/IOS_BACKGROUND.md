# iPhone: receiving in the background

Zen has no servers, so it cannot use push notifications: Apple delivers
pushes only from a server that holds an APNs key. Everything in this document
is what an app can do on its own, on an iPhone that installed Zen by
sideloading (SideStore / AltStore, the unsigned IPA re-signed with a free
Apple ID).

Short version:

| Mechanism | In Zen | When it runs | For how long | Cost |
|---|---|---|---|---|
| Zen open on the screen | always | while open | as long as it is open | normal |
| Finishing after leaving the app (`beginBackgroundTask`) | **yes** | every time Zen leaves the screen | about 30 s, usually less | negligible |
| Background refresh (`BGAppRefreshTask`) | **yes** | when iOS decides: at the earliest 15 min after leaving, in practice a few times a day for an app used daily, rarely or never for an app used rarely | about 30 s (Zen uses at most 25 s and stops earlier when it is done) | small |
| Charging catch-up (`BGProcessingTask`) | **yes** | when iOS decides: the phone is charging, idle and online, typically at night | minutes (Zen uses at most 3 min) | none on battery |
| Keep-alive with a silent sound (`audio` mode) | **yes, opt-in, off by default** | all the time while Zen is in the background and unlocked | until something stops it (see below) | high |
| VoIP push (PushKit) | no | needs APNs, so a server | — | — |
| Silent remote notifications | no | needs APNs, so a server | — | — |
| Local Push Connectivity (`NEAppPushProvider`) | no | managed entitlement, specific Wi-Fi networks only, not available to free Apple IDs | — | — |
| Significant location changes | no | see below | — | — |
| Bluetooth LE background modes | not yet | see below | — | — |
| Friends' mailboxes | always | the baseline: mail waits with up to 6 friends until the iPhone asks | 14 days | none |

So: an iPhone still receives **reliably only while Zen is open**, and
otherwise **now and then, when iOS chooses**. Messages are never lost
because of this: they wait in the friends' mailboxes and arrive at the next
check or the next time Zen is opened. The only way to receive continuously
is the opt-in keep-alive, at a clear battery cost.

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
entitlement. The task identifiers do not have to start with the bundle id,
which a re-signing tool may change.

## What Zen does

Native side: `ios/Runner/ZenBackgroundBridge.swift`. Dart side:
`lib/src/features/runtime/ios_background.dart`. Settings page: Settings →
Praca w tle (`lib/src/features/runtime/presentation/ios_background_section.dart`).

### Only while Zen is unlocked

Zen encrypts everything it stores with a key that exists only while the app
is unlocked. A locked Zen on an iPhone cannot store what comes in, and unlike
Android it has no separate receiver for the locked state. So the Dart side
tells the native side whether Zen may run in the background ("ready": the
core runs and the app is unlocked), and nothing below runs otherwise:

- when Zen locks while in the background, the native side ends the finishing
  time and stops the keep-alive at once, and iOS suspends the app;
- a background check that finds Zen locked does nothing and says so.

This matters with the default lock setting, "Po wyjściu z aplikacji" after
5 minutes: background work ends with the lock. To receive in the background
for longer, the lock has to be "Przy zamknięciu aplikacji" (or Zen has no
password). The settings page says this when it applies. Whether Zen should
get a locked receiver on iOS like the Android one is an open question (see
the end).

### Finishing after leaving the app

When Zen leaves the screen it asks iOS for its usual extra time (up to about
30 seconds). A message sent just before leaving still gets its copies into
the recipient's mailboxes (that happens a few seconds after sending when the
recipient does not answer), and answers in flight still arrive. The time ends
early when Zen locks or comes back to the screen.

### Background checks

Each time Zen leaves the screen, and after each check, it asks iOS for:

- a background refresh (`com.roj.zen.refresh`), at the earliest 15 minutes
  later;
- a charging catch-up (`com.roj.zen.catchup`), which needs a network and
  external power.

When iOS wakes Zen for one of them and Zen is unlocked, the Dart side:

1. asks each of its mailboxes (`rly_poll`) for what they hold and lets
   whatever waits to be sent be tried again (the relay engine's `activate`,
   what a fresh start of the node does);
2. asks again every 8 seconds while nothing at all came in (the node's links
   may need a moment after the app was frozen), and once more when the
   first frame shows the links are back but no mailbox has answered yet;
3. ends when nothing has come for 5 seconds (not before 8 seconds), or at
   the end of its budget (25 seconds for a refresh, 3 minutes for a
   catch-up).

What comes in is handled exactly as it is whenever Zen is in the
background: stored, and shown as a notification that tells as much as the
notification content level of its chat allows.

If iOS starts Zen from scratch for a task (Zen had been terminated, or the
phone restarted and Zen was not opened since), Zen is not "ready" when the
task begins (no Flutter engine yet, or still locked) and the task ends at
once, recorded as "Zen był zablokowany albo zamknięty". The next opening of
Zen catches up as usual. So in practice the background checks help only
while Zen stays in memory, suspended, after it was used.

The settings page shows whether iOS allows background refresh, Low Power
Mode, when iOS last woke Zen and how that went ("skrzynki sprawdzone", "Zen
był zablokowany albo zamknięty", "zabrakło czasu"), and how many times it did
since installation. These come from the app's preferences and hold only times
and a word. The diagnostics log has a line for each check:
`Background check (iOS): N frames in S s.`

### Keep-alive ("Odbieraj w tle cały czas")

Off by default; turning it on asks for confirmation with a battery warning.
While Zen is in the background, unlocked and the switch is on, it plays a
looping, silent sound in an audio session that mixes with other apps
(`.playback` with `.mixWithOthers`). An app that plays sound keeps running in
the background, so Zen's node stays connected and messages and call
invitations arrive within seconds, with notifications.

It stops when Zen comes back to the screen, when Zen locks, and when the
switch is turned off; the audio session is then given back as it was.

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
  Zen call shows as a notification, not as the system call screen.
- **Other audio.** Music and podcasts in other apps keep playing; the
  ring/silent switch behaviour of Zen's own sounds is unchanged, because the
  session is restored when Zen is on the screen.
- **App Store.** Apple rejects apps that play silence to stay alive. This is
  why it exists only because Zen is sideloaded, and why it is a choice and
  not the default.

## What was considered and left out

- **PushKit / VoIP pushes and silent pushes** would be the real solution
  (iOS wakes the app for each message, even after a restart), but both need
  an APNs server, which Zen does not have and will not have.
- **Local Push Connectivity (`NEAppPushProvider`)** keeps a connection to a
  server on chosen Wi-Fi networks. It needs a managed entitlement Apple
  grants on request, a Network Extension (not available to free Apple IDs)
  and still a server to connect to.
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
Android phone, which stay online and keep the mail.

## Open questions

- **A locked receiver on iOS.** Android receives while Zen is locked with a
  separate receiver that holds no master key and stores what comes in sealed
  until the unlock. The same could run on an iPhone after the lock, so
  background checks and the keep-alive would work with the default lock
  setting. That is a design decision (and a sizeable piece of work).
- **CallKit.** While the keep-alive runs, an incoming Zen call could show the
  system call screen instead of a notification.
- **Telling senders.** A sender could be told that the recipient is an iPhone
  that receives with delay; that would mean sharing the platform with friends.

## What to test on an iPhone

None of the native code can be built or run on Windows. The iOS workflow
(Actions → iOS → Run workflow) builds the unsigned IPA and is the first
check that the Swift compiles.

1. **Build and install.** Run the iOS workflow, install the IPA with
   SideStore, open Zen and unlock it. Nothing should look different.
2. **Settings page.** Settings → Praca w tle. The first line should say that
   background refresh is on and "iOS jeszcze nie obudził Zen w tle". Turn
   off Settings → General → Background App Refresh → Zen, come back: the line
   should say it is off. Turn on Low Power Mode, come back: the line should
   say that. Undo both.
3. **Finishing after leaving.** With a friend's device offline, send them a
   message and go to the home screen at once. On another friend's device (one
   of the recipient's mailboxes), or in the message's delivery line once you open
   Zen again, the copy should be in the mailboxes within about 10 seconds.
4. **Background refresh.** Set the lock to "Przy zamknięciu aplikacji" (or
   use Zen without a password). Leave Zen in the background (do not swipe it
   away), keep the phone on Wi-Fi, charged and out of Low Power Mode, and use
   it normally for a day. Have a friend send a few messages at different
   times. Expected: some arrive as notifications without opening Zen, with
   a delay of minutes to hours; the settings page shows the last wake-up with
   "skrzynki sprawdzone" and a growing count; the diagnostics log has
   `Background check (iOS)` lines. Note how many wake-ups a day you get.
5. **Default lock.** Set the lock back to "Po wyjściu z aplikacji" (5 min)
   and repeat for some hours. Expected: wake-ups are recorded as "Zen był
   zablokowany albo zamknięty", no messages arrive until Zen is opened, and
   then all of them arrive.
6. **Charging catch-up.** Leave the phone charging overnight with Zen in the
   background (unlocked, as in 4). Expected: the count grows overnight and
   messages sent in the evening are there in the morning without opening.
7. **Swiped away.** Swipe Zen away in the app switcher and wait some hours.
   Expected: the count does not grow until Zen is opened again.
8. **Keep-alive.** Turn on "Odbieraj w tle cały czas" (confirm the dialog),
   lock "Przy zamknięciu aplikacji", go to the home screen. From another
   device send messages and start a call. Expected: notifications within
   seconds; the call notification opens Zen and the call works (microphone
   too).
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
     messages should stop arriving until Zen is opened.
9. **Lock with keep-alive.** Set "Po wyjściu z aplikacji" with 1 minute,
   keep-alive on, go to the background. Expected: messages stop arriving
   about a minute later; after unlocking, the waiting messages arrive and
   nothing is lost or duplicated.
10. **Restart.** Restart the phone and do not open Zen. Expected: nothing
    arrives until Zen is opened (a wake-up may be recorded as "Zen był
    zablokowany albo zamknięty"), and the app starts normally when opened.
11. **Nothing else broke.** The app switcher still shows the cover instead of
    Zen's screen; calls, voice messages and films play as before.

If you have a Mac with Xcode and can run a debug build on the phone, a
background task can be forced from the debugger instead of waiting (pause
the app in Xcode with Zen in the background, then resume):

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.roj.zen.refresh"]
```
