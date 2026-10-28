# Offline links

> Friends' devices near each other connect directly, with no internet: over
> the same Wi-Fi, Wi-Fi Direct or Bluetooth. Chats, photos and posts work as
> usual; only friends and your own devices find each other.

## What it is

| Channel | Default | Where | Good for |
|---|---|---|---|
| Same Wi-Fi or cable | on | all systems | everything, calls too |
| Wi-Fi Direct | on | Android 10+, Windows | everything, when there is no Wi-Fi network |
| Bluetooth | on | Android, Linux (BLE); Windows (paired devices) | messages and photos; calls may not work |
| Apple Multipeer | off | iPhone, Mac (while Zen is open) | everything |

Change them in **Settings → Network → Network and service**,
section *Connectivity without the internet*. The
settings show how many devices are linked directly ("Wi-Fi Direct: 1").
The first start asks for what Wi-Fi Direct and Bluetooth need ("Nearby
devices", Bluetooth). To spare the battery they run only while they can
help: while Zen is used (or, on Android, during the first minutes in the
background), once you have a friend or another device of your own to link
with; Wi-Fi Direct also rests while the device is on a Wi-Fi network, and
Bluetooth advertises and scans only in short windows.

## How it works

1. **Finding each other.** Every few seconds a device sends a short advert
   (a UDP broadcast on Wi-Fi, a Wi-Fi Direct service record, a Bluetooth
   advert). It contains only random-looking tags: one per friend, derived
   from a secret only the two of you share, with a fresh salt every time and
   a new window every 5 minutes. A stranger sees random bytes.
2. **Connecting.** When a device recognises a friend's tag, the two connect
   (the lower address dials) and run a handshake: they prove they hold the
   pair secret, then agree on a new link key that mixes X25519 with a one-time
   **ML-KEM-768** from both sides, and encrypt the link with AES-256-GCM.
3. **Using it.** The mesh then runs over that link with the friend's pinned
   key, and Zen's own post-quantum session layer runs inside, as always.
   Up to 16 links at a time.
4. On Wi-Fi Direct, the device with the lower advert creates the group and
   the other joins without a system prompt; the group stays only if a
   friend's handshake succeeds. Phones never use mobile data interfaces for
   this.

Example: Ania and Bartek in a cabin with no signal, both with Wi-Fi Direct
on. Their phones form a group and the chat just works.

## Privacy

- Strangers on the same network or nearby cannot tell who you are: adverts
  carry no address, no name and no stable identifier.
- Recorded link traffic stays unreadable, also for a future quantum
  computer (the link key mixes in ML-KEM-768).

## Limits

- The pair secret that recognises a friend comes from the two devices'
  classical X25519 keys. With a quantum computer and both public keys,
  someone could recognise your adverts or sit in the middle of a *new* link
  (not read an old one). See the [security model](../SECURITY_MODEL.md).
- Wi-Fi Direct on Windows links only with Windows; it works only when the
  phone is not on any Wi-Fi network.
- Bluetooth is slow: calls may not work over it.
- Apple Multipeer works only while Zen is on screen.
- *Nearby* (people around you over Bluetooth) is a different feature: see
  [Meeting people](meeting-people.md#nearby-bluetooth-android).

[Back to the guide](README.md)
