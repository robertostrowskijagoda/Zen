# Settings and public peers

> Where things are, and how Zen reaches the network.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/settings-dark.png">
    <img src="../images/settings-light.png" width="280" alt="Settings">
  </picture>
</p>

## Finding your way

The **rail** on the left holds every section, one tap each, in four groups:

- you and your people: **Graph · Chats · Profile**
- content: **Feed · Videos**
- meeting people: **Meet · Nearby · Neighbors · Dating**
- community: **Pyramid · Wallet**
- and, apart at the bottom, the red **Alarm**.

**Nearby** is on the rail only where it works: not on iPhone, iPad or a
computer without Bluetooth LE. The wallet also opens from your own profile
(the wallet icon in its title bar).

The open tab shows its name under the icon. The **top bar** shows the
connection state (with *Why isn't it working?* when there is no network),
**Lock now**, the account menu (your avatar) and opens **Settings** when
tapped. The first button hides or shows the rail.

## Settings

Every setting is in one place only. The list, top to bottom:

| Section | What's inside |
|---|---|
| *Run the setup again* | the first-start steps again, each with what is set now |
| (top) | **Invite** (your QR code, *Copy invitation* and *Copy code only*, scanning someone's code, sending Zen to a friend), **About** (version, about how many people use Zen and how many are in the pyramid, what Zen is, security and privacy, licences, documents with the date you accepted them, contact, support), **Zen on GitHub**, **Zen on Discord** |
| Account and recovery | **Account and recovery** (key copy, recovery circle, copy with friends, full account copy, second device), **Accounts on this device** (with *Receive in the background*), **Devices** |
| Privacy and security | **Security** (app password, emergency wipe password, fingerprint or face, auto-lock, blocking screenshots, use without a password, the disguised icon on Android), **Contact and visibility** (*Show when I last opened the app*, on by default; who may write to you without being a friend and what a first message costs; who may invite you to groups), **Blocked** |
| Messages and calls | **Notifications and sounds** (everything about notifications, see below), **Call recordings**, **GIFs** (the *GIF search* switch and your own KLIPY key) |
| Network | **Offline mailboxes**, **Network and service** (technical info, [offline links](offline-links.md), the bridge on a computer), **Public peers**, **Looking around in the background** (Android) |
| App | **Appearance** (theme, mode, animations, colour), **Language**, **Data and storage** (room taken, limits, auto-cleaning, *Download photos and videos* and *Media over Wi-Fi only*), **Permissions and Bluetooth**, **Updates and Pass it on** |
| Advanced | *Why isn't it working?*, **Diagnostics**, **Delete this account from this device** |

**Notifications and sounds** holds everything about notifications, top to
bottom: **notification content** (*Sender and content* by default, *Sender
only* or *Notice only*; a chat can have its own level in its menu →
*Notification content*), the **sounds** (sounds in the app and the sound of
system notifications), a switch for **each kind of news** (messages, group
messages, calls, mentions, reactions to your posts, friends' posts, posts of
further friends (off by default), invitations, updates; a switched-off kind
posts no notification and plays no sound but stays in the in-app list,
except for posts), the **muted people** (whose posts never notify), and the
**background work** that lets notifications arrive at all (Android:
permissions, background delivery, battery, the full-screen call screen;
iPhone: how Zen is woken and *Keep receiving in the background*).

### What moved in 1.15

Nothing was removed; rows that only opened a single setting were merged
into the page of their topic.

| Before (1.14) | Now (1.15) |
|---|---|
| Privacy and security → Notification content | Messages and calls → Notifications and sounds (at the top) |
| Messages and calls → Muted people | Messages and calls → Notifications and sounds → Muted people |
| Messages and calls → Notifications and background operation (Android) | Messages and calls → Notifications and sounds → Notifications and background operation |
| Messages and calls → Background work (iPhone) | Messages and calls → Notifications and sounds → Background work |
| Privacy and security → *Show when I last opened the app* | Privacy and security → Contact and visibility |
| Privacy and security → Messages from non-friends | Privacy and security → Contact and visibility |
| Privacy and security → Group invitations | Privacy and security → Contact and visibility |
| Privacy and security → Account and recovery, Accounts on this device, Devices | Account and recovery (its own section) |
| Messages and calls → *Download photos and videos*, *Media over Wi-Fi only* | App → Data and storage |
| Messages and calls → Offline mailboxes | Network → Offline mailboxes |
| Advanced → Network and service, Public peers | Network |
| App → Looking around in the background (Android) | Network → Looking around in the background |
| App → *Why isn't it working?* | Advanced → *Why isn't it working?* (also in the top bar when there is no network) |

**Looking around in the background** (Android) lets Bluetooth look for
people nearby without the Nearby screen open: by default for 8 seconds
every 5 minutes (choices: every 2, 5, 10, 15 or 30 minutes, for 4, 8 or 15
seconds, or off). The page shows an estimate of what it costs the battery
a day, counting that every look wakes the phone for a few seconds: about
42 mAh (1.4 %) by default, about 174 mAh every 2 minutes for 15 seconds,
about 4 mAh every 30 minutes for 4 seconds, plus about 2.4 mAh for being
visible nearby. These are estimates for a typical phone, and the most it
costs: while Zen is locked and the looks find nobody new, they come less
often (up to three times the chosen gap, at most 30 minutes apart) and go
back to the chosen gap once someone new is seen or the screen is on. It
skips its turn below 15 % battery, in battery saver and while the phone
sleeps, unless it is charging.

**Battery.** After 5 minutes in the background an Android phone only
receives (no presence pings, scans or sync), lock or no lock; *Auto-lock*
says so when it is set to *Never*, on close, on restart or longer than 5
minutes. Presence pings go only to friends and only while Zen is on the
screen. A computer on battery stops being a bridge for others and keeps
only 4 public peers; plugged in, it goes back to normal.

**GIFs.** The GIF button in chats searches KLIPY, an outside company (the
only chat feature that talks to one). Switch off *GIF search* and the GIF button disappears and Zen
sends nothing to KLIPY. GIFs from your phone's keyboard and GIF files keep
working. The same page takes your own KLIPY API key, in case the app's
default key runs out.

Text on these pages can be selected and copied. *Why isn't it working?*
checks the network, background work, notifications, battery, the clock and
free space; on an iPhone it also says that Zen receives at once only while
it is open. **Diagnostics** keeps a technical log (without message content,
names or addresses) to attach to a bug report: it shows the latest entries,
and the save button writes the whole log to a file.

## Public peers

**What they are.** Zen runs on the [Yggdrasil](https://yggdrasil-network.github.io/)
mesh. To join it, a device connects to a few public peers: ordinary
Yggdrasil nodes run by volunteers. They pass encrypted traffic on; they
cannot read it.

**How it works.**

- Zen picks only encrypted links by itself (`tls://`, `quic://`, `wss://`).
  Their TLS 1.3 uses the hybrid post-quantum key exchange X25519MLKEM768.
  On unencrypted `tcp://` and `ws://` links, anyone on the line could see
  which mesh keys your node talks to.
- A phone keeps links to 4 peers at a time (2 while Zen only receives in
  the background): its 16 first picks, then the rest of the list in
  reserve. When a link goes down the phone dials the next two of the list
  at once and keeps whichever comes up first; a peer that does not
  connect within 8 seconds is replaced by the next one. So the links are
  back within seconds, also when the next peer in line is down too. With
  no network at all the phone tries again in waves, less and less often
  (up to every 15 minutes), so a phone whose first picks went quiet moves
  on to peers that still answer without dialling round and round. A
  computer uses about 20, and only 4 while it runs on battery. Computers
  check which peer answers fastest every 6 hours, never on battery.
- Every peer of the built-in list is switched on; most of them simply wait
  in reserve. Each one says what the device does with it now: *In use*,
  *Connecting…*, *Not connecting* (a phone soon tries another one), *In
  reserve*, or *Paused for a while* (a phone keeps a single link for a
  while after too much of other people's mesh traffic passed through it).
- **Settings → Network → Public peers:** see the list (the default one or
  your own), add a peer (the address is checked strictly), remove one,
  switch one off (it is then never used), **Check peers** (reachable? latency in ms, does the key
  match?), **Pin key** (adds the `?key=` seen during the check, so a peer
  can't be swapped), **Restore defaults**. Changes apply at once. At least
  one peer must stay on.
- Your own node answers no "who are you" questions (operating system,
  version) and has no admin socket.

### Your own bridge (for advanced users)

Zen on a computer helps others connect by itself when the router allows it. You can
also set up a permanent bridge without Zen — an ordinary Yggdrasil node that runs
around the clock and helps everyone (it can't see the content of messages):

1. A computer that is always on and has a public IP address: a VPS server or a home
   computer / Raspberry Pi with a port forwarded in the router.
2. Install Yggdrasil following the
   [instructions on the project's site](https://yggdrasil-network.github.io/installation.html)
   (Linux, Windows, macOS, routers). The config file is created by `yggdrasil -genconf`.
3. In the [configuration](https://yggdrasil-network.github.io/configuration.html)
   put e.g. `tls://0.0.0.0:443` in `Listen`, and a few public nodes in `Peers`.
   Restart the service and open that port in the firewall.
4. Add your node to the
   [list of public nodes](https://github.com/yggdrasil-network/public-peers)
   (pull request). Zen takes its nodes from that list, so later versions of Zen will
   connect through your bridge too.

## How many people use Zen

**About** shows *About N people in the Zen network (estimate)* and, when
you keep a pyramid, the exact number of its members. Nobody counts people
centrally: every account adds one anonymous number a month to a small
sketch (1.5 KB), friends swap sketches at most once an hour and merge
them, and after a while every phone sees about the same total (give or
take a few percent). The number cannot be traced back to anyone, last
month's count still shows at the start of a month, and people who stopped
using Zen drop out after two months. One friend alone cannot blow the
number up once you have two or more friends; it is still only a rough
guide.

## Privacy

- Public peers see your IP address and your mesh address (that is, your
  invitation code), not what you send.
- Settings, public peers and the language are per account.

## Limits

- Any Yggdrasil node answers debug questions about its direct neighbours.
  This cannot be switched off without a change in Yggdrasil itself; for a
  computer bridge it reveals the keys of friends' phones connected to it.
- Yggdrasil's own local discovery (multicast) stays off, because its beacon
  would carry your identity; Zen's [offline links](offline-links.md) do that
  job privately instead.

[Back to the guide](README.md)
