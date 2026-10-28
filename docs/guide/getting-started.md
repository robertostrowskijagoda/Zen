# Getting started

> Install Zen, accept the terms, set a password, add your first friend.
> No phone number, no e-mail, no cloud account.

## Install

The easiest way is the **[install page](https://robertostrowskijagoda.github.io/Zen/install/)**:
it recognises your system and links one page per system with the few steps, pictures and the download (21 languages).
Zen is not in the app stores; everything comes from
[GitHub Releases](https://github.com/robertostrowskijagoda/Zen/releases/latest)
or from a friend.

| System | How | Steps |
|---|---|---|
| Android | `Zen-arm64-v8a.apk` for most phones (`Zen-armeabi-v7a.apk` for older 32-bit phones, `Zen-x86_64.apk` for Chromebooks and emulators), straight from the page | download, open, **Install** |
| iPhone (iOS 15+) | **SideStore** with your own Apple Account, from Zen's source (`apps.json`, `Zen-unsigned.ipa`) | a computer once, then it renews on the phone; about 15 minutes |
| Windows x64 / ARM64 | `Zen-Windows.zip` / `Zen-Windows-arm64.zip` | unpack (a folder `Zen`), run `Zen\zen.exe` (the Visual C++ runtime is inside) |
| macOS 12+ | `Zen-macOS.zip` | drag to Applications; first launch: **Privacy & Security → Open Anyway** |
| Linux x64 / arm64 | `.deb`, Flatpak (x64), `.tar.gz` | one command; Ubuntu 22.04, Debian 12, Mint 21 or newer (glibc 2.35+), elsewhere the Flatpak |

**Windows 11 with Smart App Control** blocks unsigned apps with no *Run
anyway*. Zen is not code-signed yet, so either use it on another device or
turn Smart App Control off (Windows Security → App & browser control →
Smart App Control settings → Off), which lowers protection for the whole
computer.

**iPhone in short.** An iPhone app cannot install other apps, so Zen goes
through **[SideStore](https://sidestore.io/)**, which signs it with your own
Apple Account (a free one is enough). Once, with a computer and a cable:
**LocalDevVPN** from the App Store on the iPhone (**Connect**), **iloader** on
the computer (**Install SideStore (Stable)**), then on the iPhone trust your
Apple Account in **Settings → General → VPN & Device Management** and, on
iOS 16 and later, turn on **Settings → Privacy & Security → Developer Mode**.
In SideStore sign in, tap the **7 DAYS** counter in **My Apps**, add Zen's
source (**Add Zen to SideStore** on the install page, or **Sources → +** with
`https://robertostrowskijagoda.github.io/Zen/apps.json`) and install Zen.
An app signed with a free Apple Account opens for 7 days; SideStore renews it
on the phone whenever LocalDevVPN is connected, and a daily Shortcuts
automation (**Set VPN** to connect LocalDevVPN, then SideStore's **Refresh
All Apps**) does it by itself. A free Apple Account runs at most 3 such apps
at a time, SideStore included. If the 7 days run out, Zen only stops opening
until it is renewed; its data stays. **AltStore Classic** (the same source,
renewed through AltServer on a computer) and Sideloadly (from a computer)
work too. On iPhone Zen receives and sends at once only while it is open (see
[Chats](chats-and-delivery.md#iphone)). AltStore PAL (EU) takes only apps
notarized by Apple, so it can't install Zen yet.

**Helping a friend.** In Zen: **Settings** (tap the top bar) **→ Invite →
Friend doesn't have Zen?** On
Android it sends the app over Quick Share, Bluetooth or Wi-Fi, even without
internet; **How to install Zen on another phone / computer** shows a QR code
to the install page and the same steps for every system.

## First start

1. **The rules.** The first screen shows the terms of use, the privacy
   policy and the licence. Each opens inside the app. Using Zen to break the
   law is forbidden by the terms of use. You tick
   *I accept…* and tap **I accept and continue**. Without that nothing is
   created on the device. When a document changes later, Zen asks again.
2. **The app password.** It encrypts everything Zen keeps on this device and
   unlocks Zen here. You can also unlock with biometrics. *No password* is
   possible for the default account, but not recommended. Already have an
   account? **I already have an account — restore it** goes straight to the
   ways back (step 5), before any password: a full account copy brings its
   own. Restored from another device, Zen asks for a new password
   afterwards; with the circle's help, right away.
3. **Setup.** A few questions, each with a sensible default, that you can
   skip: when Zen locks itself (with what *Never* really means; choosing it
   asks for the password you have just set once more), what
   notifications say (*Sender and content*, *Sender only* or *Notice
   only*), whether your gates are open for free or need your consent, and
   the animations. *Settings → Run the setup again* asks them all again.
   **Permissions** come last. On top: notifications, Bluetooth (on, and visible
   nearby), full-screen alerts and not being put to sleep. Microphone,
   camera, location and exact alarms sit folded under *More permissions
   (optional)*: Zen asks for them the first time a feature needs them.
   Location in the background is only in Settings.
4. **Your identity** is created by itself: a key pair that is your address in
   the network. Your QR code is that address.
5. **How do you start?** *New account* goes on to the next step. If you
   already have an account, pick *I have a copy* (a full account copy, a
   paper key or a key file), *Recover from another device* or *Recover with
   the circle's help* (see below).
6. **Your name.** *How should friends see you?* The name goes to the people
   you invite and to your groups; you can change it later in your profile.
   *Skip* is possible, but friends then see your code ("Zen 1A2B-3C4D-5E6F")
   instead of a name.
7. **Secure your account.** Make a **key copy** first (paper or a file; below).
   The recovery circle is available from 4 friends: once you have them,
   Zen reminds you once in Chats (*Set up circle* / *Not now*) and in
   Settings, also when you already have a key copy. Do it early: there is
   no "forgot password" e-mail.

To add a friend, open **Settings** (tap the bar at the top) → **Invite**,
show your QR code and let your friend scan it, or the other way round.
Computers scan with their camera too; without one, paste the code from the
clipboard. **Copy invitation** copies a ready message with your link ("Add
me in Zen: … No Zen yet? This link shows how to install it."), **Copy code
only** just the code; a pasted whole message works in *I have someone's
code* too. Your invitation code is your public address, not a secret, so
it stays in the clipboard (secrets such as the key or a transfer code are
cleared after 60 seconds).

## Locking

- **Lock now** sits in the top bar once you have a password.
- Zen locks itself after a while in the background (Settings → Privacy and
  security).
- With *Auto-lock* set to *Never* (it takes your password once), Zen opens
  without the password even after a restart: anyone holding your unlocked
  phone sees your chats. **Lock now** still locks it, restarts included:
  from then on every start asks for the password until you choose *Never*
  again (it takes your password once more). The emergency wipe password
  works only on that lock screen.
- An **emergency wipe password** typed on the lock screen quietly erases
  the data instead of opening it (Settings → Security). It is not the
  alarm's *duress PIN*, which erases nothing.
- While Zen is locked on Android, a small background service still receives
  messages, the alarm and door knocks. It cannot read them: they are kept
  sealed until you unlock.
- **Battery (Android).** After 5 minutes in the background Zen only
  receives, with or without the lock: no presence pings, scans or sync
  until you come back. With *Auto-lock* set to *Never*, on close, on
  restart or longer than 5 minutes, the settings page says so.

## Several accounts on one device

Each account is a separate person in Zen: its own keys, its own address in
the network, its own password, chats, settings and notifications.

- **Add account** (the avatar menu in the top bar) creates one. It starts
  like a fresh install.
- Every account has an **account ID** (16 characters, like
  `7K3Q-M9XA-2FHD-W8TZ`), shown once when it is made and later only in that
  account's own settings.
- **Show in the account list** (off by default): the account appears on
  the lock screen and in the avatar menu. Off: nobody who picks up the
  device can see that it exists. You open it with **Other account** on the
  lock screen, its ID and its password.
- A wrong ID and a wrong password give the same message, and failed
  attempts count against the same lock-out.

**How the hiding works.** Account folders are named with a keyed hash of
the ID, and every device has a few decoy folders with random content from
the start, so the number of folders says nothing. Keystore entries of extra
accounts have hashed names too. There is no list of hidden accounts
anywhere.

**Limits.** In the background (phone in your pocket, computer in the tray)
by default only the default account receives; *Receive in the background*
in **Accounts on this device** changes that for each account (more battery,
and an extra account is then less hidden from someone with full access to
the device). An account without it receives while it is open; what arrives
meanwhile waits with friends' mailboxes or in the sender's outbox and comes
in when you open it. Close forensic analysis can tell a real account folder
from a decoy (it holds more files), but not read it.

## Getting your account back

The account comes back in several ways. A second device or a full account
copy brings the most; the recovery circle and the key copy help when you
have neither.

| Way | What you need | Wait |
|---|---|---|
| Another device of the account | that device, switched on | none |
| Full account copy (file) | the file (all its parts) and its password | none |
| Recovery circle, with password | your account password and 2 of the 4 to 6 friends in your circle | 24 hours |
| Recovery circle, no password | 4 of the circle | 7 days |
| Key copy (paper or file) | the paper (or the file and its password) | none |

What comes back (also in the app: Account and recovery → *What can be
recovered and how*):

| Part of the account | Other device | Full account copy | Circle | Key copy |
|---|---|---|---|---|
| Account key | yes | yes | yes | yes |
| Friends and groups | yes | if chosen | yes | from the copy with friends² |
| Conversations (text) | yes | if chosen | if in the copy with friends³ | from the copy with friends² |
| Attachments and media | yes | if chosen | no | no |
| Profile and gallery | yes | if chosen | without photos⁴ | from the copy with friends² |
| Settings | account settings⁶ | if chosen | yes | from the copy with friends² |
| Pyramid and wallet | yes | if chosen | confirmed by the pyramid⁵ | confirmed by the pyramid⁵ |
| Dating | yes | if chosen | without photos⁴ | from the copy with friends² |
| Neighbours (household) | yes | if chosen | yes | from the copy with friends² |
| Meetings and dinner circles | yes | if chosen | no | no |
| Films | yes | if chosen | no | no |

² if you have a copy with friends. ³ unless you turned conversation text
off for it. ⁴ the copy with friends is small. ⁵ your place and wallet come back
when people of the pyramid confirm them. ⁶ the account's settings (look,
sounds, privacy of notifications and screens, GIFs, cleanup, who may
invite you to groups); each device keeps its own lock, connections,
notifications permissions, storage and media-over-mobile-data settings.
Disappearing messages never come back.

**Your devices hold the same account, all the time.** While two or more
devices of an account run, they keep each other up to date without you
doing anything: conversations with their photos, videos, files and voice
messages; friends and groups; your profile with its photos; posts, the
gallery and the films you published, with all their files (not only the
ones opened on that device); the account's settings; your dating profile;
meetings, plans, events and circles; the pyramid; the offline mailboxes
you chose by hand; and a copy of your household (the household itself runs
on one phone — its door — and the copy is there for a recovery). Changes travel sealed for the account's
devices only. When two devices change the same thing, the later change
wins on both (each change carries a counter, so the order of arrival does
not matter); different changes are merged. Files travel on Wi-Fi or a
wired network; over mobile data only when *Media only over Wi-Fi* is off —
what waits comes as soon as it may. So any other device of the account
can bring the whole account back.

**From another device.** On the device that has the account: Account and
recovery → **Add a second device or move the account** (the screen is
called *Second device*). This device stays on the account: afterwards
both have Zen and both get messages. It shows a QR code. On the new
device choose **Recover from another device** and scan it (or paste it).
Both screens show the same six digits; check them and tap **Allow** on the
old device. Everything moves — the key, friends and groups, conversations
with their photos, videos and files, profile and gallery, settings,
pyramid and wallet, dating, household, meetings and films — block by block,
the way messages travel (a direct link or the same Wi-Fi when Zen has one,
otherwise the network), so keep both devices on the same Wi-Fi if you can.
Files of any size are read and written piece by piece. You see the
progress on both devices and a summary at the end; if
it stops, start again and it goes on from where it stopped. The code only
works once, only for someone who sees your screen, and everything after it
is end-to-end encrypted. On a device that already has the same account
the same steps fill in what it lacks (nothing is deleted). Both devices
need the same version of Zen; otherwise both screens say so. Giving the
old device away? Remove the account from it (Settings → *Delete this
account from this device*) or unlink it in **Devices** on the new one;
otherwise it keeps receiving your messages.

**Full account copy (file).** Account and recovery → **Create a full
account copy**. Tick what goes
in (the account and its keys are always in it): friends and groups,
conversations (text), attachments and media, profile and gallery,
settings, pyramid and wallet, dating, neighbours, meetings and circles,
films. The screen shows the estimated size. The file is encrypted with the
password you choose (Argon2id and AES-256-GCM); without it nobody can open
it, you included. A copy larger than 1 GB is saved in parts
(`.zenbackup`, `.zenbackup.2`…) — keep them together. To restore, choose
**I have a copy** on the first start or later in Account and recovery.
On the same account the data is merged (nothing is deleted); a copy of a
different account is refused on a device that already has an account with
data. A copy made by a newer Zen asks you to update first.
With *Settings* ticked the copy restores the whole app on a new device:
every setting as it was (the lock, connections, the setup — which shows
once more only when the copy comes from an older setup) and the app
password. Zen asks once for the app password of the old device and checks
it against the copy; from then on it opens Zen on the new device too (a
panic password comes along). The copy holds only what checks that
password, never the password or the key it opens. Biometric unlock and
*Never* belong to the old device: turn them on again on the new one.
Don't remember the old password? Choose **I don't remember**: the account
comes back without it, the new device keeps its own settings and asks for
a new password.

**Opening Zen's files directly.** Tapping a full account copy
(`.zenbackup`), a key file (`.zenkey`) or an update file (`.zenupdate`) in
Files, a mail or a chat opens it in Zen, on the right screen with the file
already chosen — after you unlock Zen, and on the first start once the
setup is done. On Android Zen is offered for other unnamed files too; it
then only tells you the file is not one of its own. On Windows choose
**Open with** → Zen (`zen.exe`) once; on Linux the `.deb`, the Flatpak and
`install-desktop-entry.sh` register the file types. A copy saved in parts
opens this way only on a computer (the other parts lie next to it); on a
phone choose it with **I have a copy** → **Choose file**.

**Key copy (paper or file).** Account and recovery → **Key copy**: a paper
with a code (56 characters, also as a QR code) or a key file with a
password. It brings the account back on a new phone even when nobody of
the circle can help. Friends, groups and conversation texts then come from
the copy with friends, if you have one; photos and files from chats do
not. Whoever has the paper, or the file and its password, has your
account: never give them to anyone.

**The recovery circle.** Account and recovery → recovery circle:

1. **Choose 4 to 6 people** you trust and can meet or call. Your close
   friends and friends are ticked by default (casual friends are not); you
   can tick anyone. With fewer than 4 friends the button stays off and Zen
   reminds you once you have them.
2. Set your **account password** (it may be the same as your app
   password). Each chosen person gets an encrypted piece of your key; one
   piece alone reveals nothing.
3. **Who holds the keys** lists the names, with a tick for those whose
   device confirmed. **Save the list to print** writes a short text file
   with their names, their invitation codes, your account fingerprint and
   what to do; keep it with your key copy.
4. **On a new phone:** *Recover with the circle's help*. The screen shows
   **this device's code** (a code and a QR code, not a secret). Type or scan
   the codes of two people of your circle: their devices get a
   notification and a card *Someone asks for help recovering an account*.
5. **A helper** checks, ideally in person or on the phone (compare the
   account fingerprint), that it is really you, and taps **Help**; the new
   device's code is already filled in (they can also scan its QR code under
   *Help recover*). A wrong code is refused at once.
6. After 24 hours type your account password. Without the password four
   people are needed and 7 days.

During the wait your old devices get an alarm and a notification and can
stop the recovery. A recovered account also gets its place and wallet in
the pyramid back (from the records friends keep).

**The copy with friends.** Each person of your recovery circle also keeps
an encrypted copy of your data (Settings → Account and recovery → *Copy
with friends*): profile, friends and groups, friendship levels, settings,
pyramid and wallet, your household (flat key, your resident key, its
profile, household members' names; not the door key or the neighbours),
your dating profile and its settings, and — unless you turn it off — the
text of your one-to-one and group conversations, with edits, deletions,
reactions and replies (no photos, videos, files or disappearing
messages). It is refreshed at most once a day, and soon after a new
friend or a group change; only changed parts travel. It is at most 10 MB per
person; the oldest messages go first. Holders cannot read it. After you get
your account back in any way, Zen fetches the newest copy from the circle and
your friends, checks it and restores it — you see the progress there.
Photos are not in the copy. A restored household waits until a household
member's phone accepts your new phone; a dating profile comes back only
into an empty one.

**Limits.** The wait is kept by the helpers' honest apps; helpers who
collude and modify their apps could skip it. Two helpers together still
need your password, so choose a long one.

## Removing data

- **Delete this account from this device** (Settings → Advanced) removes the
  open account's chats, invitations, settings and keys from this device and
  restarts Zen clean. Other accounts on the device stay, and the account
  keeps working on its other devices. When the account has neither a key
  copy nor a recovery circle, the confirmation says in red that it could
  not be recovered and offers **Make a copy first**.
- **I don't remember the password — start over** on the lock screen and the
  emergency wipe password of the default account remove *every* account on
  the device, the keystore entries and the files. The account comes back
  only from a second device, a full account copy, a key copy or the
  recovery circle.

[Back to the guide](README.md)
