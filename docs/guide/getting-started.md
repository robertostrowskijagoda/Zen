# Getting started

> Install Zen, accept the terms, set a password, add your first friend.
> No phone number, no e-mail, no cloud account.

## Install

Zen is not in the app stores. Download it from
[GitHub Releases](https://github.com/robertostrowskijagoda/Zen/releases/latest)
or get it from a friend who has it (**Invite → Friend doesn't have Zen?**
sends the app over Quick Share, Bluetooth or Wi-Fi, even without internet).
Step-by-step instructions for every system are in the
[README](../../README.md#how-to-install).

| System | File |
|---|---|
| Android (arm64, armv7, x86_64) | `Zen.apk` |
| iPhone (iOS 15+, sideloaded) | `Zen-unsigned.ipa` |
| Windows x64 / ARM64 | `Zen-Windows.zip` / `Zen-Windows-arm64.zip` |
| Linux x64 / arm64 | `.tar.gz`, `.deb`, `.flatpak` (x64) |
| macOS 12+ | `Zen-macOS.zip` |

## First start

1. **The rules.** The first screen shows the terms of use, the privacy
   policy and the licence. Each opens inside the app. You tick
   *I accept…* and tap **I accept and continue**. Without that nothing is
   created on the device. When a document changes later, Zen asks again.
2. **The password.** It encrypts everything Zen keeps on the device. You can
   also unlock with biometrics. *No password* is possible for the default
   account, but not recommended.
3. **Permissions.** Notifications, Bluetooth, location for the alarm: each
   is asked for when it is needed and explained.
4. **Your identity** is created by itself: a key pair that is your address in
   the network. Your QR code is that address.
5. **Secure your account.** Choose a recovery circle or make a paper backup
   (below). Do it early: there is no "forgot password" e-mail.

To add a friend, open **Settings** (tap the bar at the top) → **Invite**,
show your QR code and let your friend scan it, or the other way round.

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

**Limits.** In the background (phone in your pocket) only the default
account receives. An extra account receives while it is open; what arrives
meanwhile waits with friends' mailboxes or in the sender's outbox and comes
in when you open it. Close forensic analysis can tell a real account folder
from a decoy (it holds more files), but not read it.

## Getting your account back

| Way | What you need | Wait |
|---|---|---|
| Recovery circle, with password | your password and 2 of up to 6 trusted friends | 24 hours |
| Recovery circle, no password | 4 of the circle | 7 days |
| Paper backup or key file | the paper (or file) | none |

Each person in the circle holds an encrypted piece of your key. One piece
alone reveals nothing. During the wait your old devices get an alarm and
can stop the recovery. A recovered account also gets its place and wallet
in the pyramid back (from the records friends keep).

**Limits.** The wait is kept by the helpers' honest apps; helpers who
collude and modify their apps could skip it. Two helpers together still
need your password, so choose a long one.

## Removing data

- **Reset data** (Settings) removes the current account from this device.
- **I don't remember the password — start over** on the lock screen and the
  panic password of the default account remove *every* account on the
  device, the keystore entries and the files.

[Back to the guide](README.md)
