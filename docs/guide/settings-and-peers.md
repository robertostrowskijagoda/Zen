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

The open tab shows its name under the icon. The **top bar** shows the
connection state (with *Why isn't it working?* when there is no network),
**Lock now**, the account menu (your avatar) and opens **Settings** when
tapped. The first button hides or shows the rail.

## Settings

| Section | What's inside |
|---|---|
| Invite | your QR code, scanning someone's code, sending Zen to a friend |
| About | version, what Zen is, security and privacy, licences, documents (with the date you accepted them), contact, support |
| Privacy and security | password and app lock, notifications without content (on by default), account and recovery, accounts on this device, devices, blocked people, group invitations, messages from non-friends, call recordings, GIFs |
| Messages and calls | downloading photos and videos (also over mobile data by default; *Media over Wi-Fi only* turns that off), in-app sounds, storage limits |
| App | notifications and background operation, permissions and Bluetooth, *Why isn't it working?*, appearance, language, data and storage, updates and Pass it on |
| Advanced | network and service (offline mailboxes, [offline links](offline-links.md)), public peers, diagnostics, delete all data |

Text on these pages can be selected and copied. *Why isn't it working?*
checks the network, background work, notifications, battery, the clock and
free space. **Diagnostics** keeps an event log (without message content) to
attach to a bug report.

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
- A phone uses up to 16 enabled peers, a computer up to 32.
- **Settings → Advanced → Public peers:** see the list (the default one or
  your own), add a peer (the address is checked strictly), remove one,
  switch one off, **Check peers** (reachable? latency in ms, does the key
  match?), **Pin key** (adds the `?key=` seen during the check, so a peer
  can't be swapped), **Restore defaults**. Changes apply at once. At least
  one peer must stay on.
- Your own node answers no "who are you" questions (operating system,
  version) and has no admin socket.

**Your own bridge.** Zen on a computer helps others connect when the router
allows it. You can also run a permanent Yggdrasil node yourself; see the
[README](../../README.md#your-own-bridge-for-advanced-users).

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
