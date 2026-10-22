# Getting started

> Install Zen, accept the terms, set a password, add your first friend.
> No phone number, no e-mail, no cloud account.

## Install

The easiest way is the **[install page](https://robertostrowskijagoda.github.io/Zen/install/)**:
it recognises your system and shows only its few steps (English and Polish).
Zen is not in the app stores; everything comes from
[GitHub Releases](https://github.com/robertostrowskijagoda/Zen/releases/latest)
or from a friend.

| System | How | Steps |
|---|---|---|
| Android (arm64, armv7, x86_64) | `Zen.apk`, straight from the page | download, open, **Install** |
| iPhone (iOS 15+) | **SideStore**, with the "Add Zen source" link | 8 short steps, a computer once |
| Windows x64 / ARM64 | `Zen-Windows.zip` / `Zen-Windows-arm64.zip` | unpack, run `zen.exe` |
| macOS 12+ | `Zen-macOS.zip` | drag to Applications, right-click → **Open** |
| Linux x64 / arm64 | `.deb`, Flatpak (x64), `.tar.gz` | one command |

**iPhone in short.** An iPhone app cannot install other apps, so Zen goes
through SideStore. Once, with a computer and a cable: install
**LocalDevVPN** from the App Store, run **iloader** on the computer to put
SideStore on the phone, turn on **Developer Mode** and trust your Apple ID.
Then, on the phone, add the Zen source
(`https://robertostrowskijagoda.github.io/Zen/apps.json`, one tap on the
install page) and tap **Install**. SideStore refreshes Zen every 7 days by
itself. A free Apple ID allows 3 such apps at a time (SideStore counts).
AltStore PAL (EU) takes only apps notarized by Apple, so it can't install
Zen yet.

**Helping a friend.** In Zen: **Settings** (tap the top bar) **→ Invite →
Friend doesn't have Zen?** On
Android it sends the app over Quick Share, Bluetooth or Wi-Fi, even without
internet; **How to install Zen on another phone / computer** shows a QR code
to the install page and the same steps for every system.

## First start

1. **The rules.** The first screen shows the terms of use, the privacy
   policy and the licence. Each opens inside the app, in Polish when your
   app is in Polish (the English licence notice stays binding). You tick
   *I accept…* and tap **I accept and continue**. Without that nothing is
   created on the device. When a document changes later, Zen asks again.
2. **The password.** It encrypts everything Zen keeps on the device. You can
   also unlock with biometrics. *No password* is possible for the default
   account, but not recommended.
3. **Permissions.** Notifications, Bluetooth, location for the alarm: each
   is asked for when it is needed and explained.
4. **Your identity** is created by itself: a key pair that is your address in
   the network. Your QR code is that address.
5. **How do you start?** *New account* goes on to the next step. If you
   already have an account, pick *I have a backup* (a backup file, a paper
   key or a key file), *Recover from another device* or *Recover through
   the trusted circle* (see below).
6. **Secure your account.** Choose a recovery circle or make a paper backup
   (below). Do it early: there is no "forgot password" e-mail.

To add a friend, open **Settings** (tap the bar at the top) → **Invite**,
show your QR code and let your friend scan it, or the other way round.
Computers scan with their camera too; without one, paste the code from the
clipboard.

## Locking

- **Lock now** sits in the top bar once you have a password.
- Zen locks itself after a while in the background (Settings → Privacy and
  security).
- A **panic password** typed on the lock screen quietly erases the data
  instead of opening it.
- While Zen is locked on Android, a small background service still receives
  messages, the alarm and door knocks. It cannot read them: they are kept
  sealed until you unlock.

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

| Way | What you need | Wait |
|---|---|---|
| Another device of the account | that device, switched on | none |
| Backup file | the file (all its parts) and its password | none |
| Recovery circle, with password | your password and 2 of up to 6 trusted friends | 24 hours |
| Recovery circle, no password | 4 of the circle | 7 days |
| Paper backup or key file | the paper (or file) | none |

What comes back (also in the app: Account and recovery → *What can be
recovered and how*):

| Part of the account | Other device | Backup file | Circle | Paper key / key file |
|---|---|---|---|---|
| Account key | yes | yes | yes | yes |
| Friends and groups | yes | if chosen | yes | from the circle copy² |
| Conversations (text) | yes | if chosen | if in the circle copy³ | from the circle copy² |
| Attachments and media | yes | if chosen | no | no |
| Profile and gallery | yes | if chosen | without photos⁴ | from the circle copy² |
| Settings | account settings⁶ | if chosen | yes | from the circle copy² |
| Pyramid and wallet | yes | if chosen | confirmed by the pyramid⁵ | confirmed by the pyramid⁵ |
| Dating | yes | if chosen | without photos⁴ | from the circle copy² |
| Neighbours (household) | yes | if chosen | yes | from the circle copy² |
| Meetings and circles | yes | if chosen | no | no |
| Films | yes | if chosen | no | no |

² if you have a copy at your circle. ³ unless you turned conversation text
off for it. ⁴ the circle copy is small. ⁵ your place and wallet come back
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
meetings, plans, events and circles; the pyramid; and a copy of your
household (the household itself runs on one phone — its door — and the
copy is there for a recovery). Changes travel sealed for the account's
devices only. When two devices change the same thing, the later change
wins on both (each change carries a counter, so the order of arrival does
not matter); different changes are merged. Files travel on Wi-Fi or a
wired network; over mobile data only when *Media only over Wi-Fi* is off —
what waits comes as soon as it may. So any other device of the account
can bring the whole account back.

**From another device.** On the device that has the account: Account and
recovery → **Move to another device**. It shows a QR code. On the new
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
the same steps fill in what it lacks (nothing is deleted).

**Backup file.** Account and recovery → **Create a backup**. Tick what goes
in (the account and its keys are always in it): friends and groups,
conversations (text), attachments and media, profile and gallery,
settings, pyramid and wallet, dating, neighbours, meetings and circles,
films. The screen shows the estimated size. The file is encrypted with the
password you choose (Argon2id and AES-256-GCM); without it nobody can open
it, you included. A copy larger than 1 GB is saved in parts
(`.zenbackup`, `.zenbackup.2`…) — keep them together. To restore, choose
**I have a backup** on the first start or later in Account and recovery.
On the same account the data is merged (nothing is deleted); a copy of a
different account is refused on a device that already has an account with
data.

Each person in the circle holds an encrypted piece of your key. One piece
alone reveals nothing. During the wait your old devices get an alarm and
can stop the recovery. A recovered account also gets its place and wallet
in the pyramid back (from the records friends keep).

**The copy at your circle.** Each person of your recovery circle also keeps
an encrypted copy of your data (Settings → Account and recovery → "Copy at
the circle"): profile, friends and groups, friendship levels, settings,
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

- **Reset data** (Settings) removes the current account from this device.
- **I don't remember the password — start over** on the lock screen and the
  panic password of the default account remove *every* account on the
  device, the keystore entries and the files.

[Back to the guide](README.md)
