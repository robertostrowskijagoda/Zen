# Security model

How Zen protects what you say and keep, against whom, and where the honest
limits are. For reporting a vulnerability see [SECURITY.md](../SECURITY.md);
for the exact frames and records, the [protocol specification](PROTOCOL.md)
(sections 1.5, 2.5.1 and 4).

## In one paragraph

Zen has no servers. Devices talk over the Yggdrasil mesh, whose own
encryption is classical, and Zen puts its **own post-quantum layer** on top:
every signal between two devices, every mailbox message, the locked inbox,
door traffic, Bluetooth hellos and local link handshakes are sealed with a
**hybrid ML-KEM-768 + X25519** key exchange, and everything Zen signs to keep
or pass on carries a **hybrid Ed25519 + ML-DSA-65** signature that is valid
only when both halves verify. Call media sits inside a 256-bit post-quantum
relay layer. On the device, data is encrypted with AES-256-GCM under a key
protected by your password (Argon2id) and the system keystore. A few pieces
stay classical, for reasons explained below.

## Threat model

**Zen is built to protect you from:**

| Who | What they could try | What stops them |
|---|---|---|
| Someone watching the network (operator, Wi-Fi, a state) | read messages, record them for later | end-to-end encryption; the post-quantum layer defeats "record now, decrypt later" |
| Public peers and relaying nodes | read or change traffic they pass | the session layer (AEAD, authenticated) |
| Friends who keep your mail (mailboxes, mailbox doors) | read what they hold | sealed boxes; they see ciphertext and counters |
| Someone impersonating a friend's address | inject or read messages | device keys pinned per address and bound to the hybrid identity |
| A future quantum computer | break X25519 / Ed25519 | ML-KEM-768 and ML-DSA-65 in every hybrid; the secret holds while either half holds |
| A thief with your device, locked | read your data | AES-256-GCM, password via Argon2id, hardware-held keys, throttled attempts |
| Someone who picks up your unlocked device or forces you to open it | find other accounts | hidden accounts and decoy folders, the panic password |
| A forged update | install malware as "Zen" | `SHA256SUMS`, Android signing certificate, the hybrid signature once maintainer keys are pinned |
| A modified Zen of another person | forge pyramid or ledger records, money | every phone checks every signed record by the same rules |
| Tools inside Zen's own process (debugger, Frida, hooks) | sign what you never asked for | detection; money and the pyramid power key are blocked while detected |

**Out of scope, honestly:**

- An attacker who controls your operating system (root you allowed, a
  compromised OS, a keylogger). Zen detects and warns, it cannot win.
- **Metadata**: who talks to whom and when is visible to observers of the
  mesh routing, and to the friends who relay or keep mail for you.
- What friends do with what you show them (screenshots, retelling).
- Denial of service: anyone on the path can drop traffic.
- Outside services you choose to use: GIF search (KLIPY), GitHub for
  updates, OpenStreetMap when you open a shared location.

## The layers

<p align="center">
  <img src="images/pq-layers.svg" width="760" alt="The layers of encryption around a message, a call and the data on the device">
</p>

### Key exchange: hybrid ML-KEM-768 + X25519

Zen uses **MLKEM768-X25519** ("X-Wing") through HPKE (RFC 9180), from Go's
standard library (`crypto/hpke`, `crypto/mlkem`) in the network bridge,
on every platform. The shared secret stays safe as long as either ML-KEM-768
or X25519 holds. It protects:

| What | How |
|---|---|
| Every signal between two devices (messages, calls set-up, sync, everything) | a session per pair of devices: the KEM secret and a challenge encapsulated to the sender's device key give the keys (HKDF); ChaCha20-Poly1305 per frame, replay window; there is no plaintext mode |
| Mailbox mail and the Android locked inbox | sealed again for the recipient's hybrid key (plus ephemeral and static X25519 for sender authentication); one encapsulation per recipient key per day, a fresh key for every envelope |
| Neighbours' doors | every door runs the same session layer; a sealed knock also has a second layer from the sticker's token (knock) or the knocker's hybrid key (answer) |
| Nearby (Bluetooth) hellos and answers | a one-time ML-KEM-768 + X25519 key per hello, sent in chunks over GATT |
| Local link handshakes (Wi-Fi, Wi-Fi Direct, Bluetooth) | both sides add a one-time ML-KEM-768 to the link key |
| Call keys | a fresh exchange in every call's offer and answer |
| Dating boxes (answers, profiles, "Yes", messages, matchmaking) | a fresh encapsulation for every box, so boxes cannot be linked |
| Food sharing pickup address | sealed for the accepted person's one-time hybrid key |

### Signatures: hybrid Ed25519 + ML-DSA-65

Everything Zen signs to keep or pass on carries both signatures and is valid
only when **both** verify: account and device records, posts and other
ledger entries, pyramid records, the ledger hello, attestations, dating
profiles and recommendations, release manifests and `SHA256SUMS.sig`.
ML-DSA-65 (FIPS 204) is Go's own implementation (copied unchanged until Go
publishes `crypto/mldsa`). The ML-DSA key is derived from the same 32-byte
seed as the Ed25519 key, so backups and recovery restore both.

### Device keys and pinning

The Yggdrasil address of a device is an Ed25519 key, which a quantum
computer could break. So Zen does not rely on it for identity:

- Each device has a post-quantum **device key**, derived from its Ed25519
  seed (which a quantum computer cannot recover from the public key).
- A session counts as "from this address" only if the sender proves it holds
  that device key.
- The device key is **pinned** to the address at first contact and kept
  across restarts. A record signed with another key for the same address is
  rejected.
- The ledger hello signs the address **together with** the device key's
  fingerprint (hybrid signature), so an address is bound to the hybrid
  identity. Device entries in your log and friends' friend lists carry the
  keys too, so a friend's other devices and friends of friends are pinned
  before the first contact. A mismatch shows a warning in the chat.

### Call media

1. **Frame encryption**: every audio and video frame is sealed by WebRTC's
   frame encryptor with **AES-128-GCM**, keys from the call's hybrid exchange,
   per participant, rotated every 5 minutes and when someone joins or leaves.
2. **DTLS-SRTP**: WebRTC's standard transport encryption.
3. **The relay layer**: every packet (RTP, RTCP, ICE, DTLS) goes through the
   bridge's relay over the mesh and is sealed with **ChaCha20-Poly1305 under a
   256-bit key** from the two devices' hybrid session. Nothing goes unsealed.

The call screen says which protection a call has. A device without frame
encryption falls back to DTLS-SRTP inside the relay layer.

### QR tickets and cell votes

- **Event tickets** use no signatures at all: the organiser's tag and the
  live code are HMAC-SHA256 values from secrets only the guest's phone and
  the organiser share (hash-based, so post-quantum). The organiser's phone
  checks them offline; a code is valid for 90 seconds, once.
- **Cell votes** in the pyramid: the request to hold a vote is a ring
  signature (anonymous among the cell). Each member's phone then registers a
  **one-time hybrid key (a card)**; the ballot (the list of cards) is signed
  by the members' hybrid keys and counts only with at least as many
  signatures as cards; each vote is signed by a card, once. The decision is
  post-quantum; only the anonymous request is classical.

## What stays classical, and why

| What | Why | What a quantum attacker could do |
|---|---|---|
| The Yggdrasil node key and address (Ed25519) | it is the mesh protocol itself | hijack or analyse routing (denial of service, traffic analysis); not read content, not pass the device key check |
| The anonymous request for a cell vote (LSAG ring signature over Ed25519), and card registration inside the cell | there is no standard post-quantum linkable ring signature; unaudited lattice schemes were not used | forge a vote request (a nuisance, not a result); later tell who asked; in a cell of 2 to 3, a cellmate could tell whose card is whose |
| The pair secret of local links (X25519 of the two devices' keys) | a post-quantum one would need an exchange over the network first | recognise two devices' adverts, or sit in the middle of a *new* link; recorded links stay unreadable |
| The dating lantern, the first match question and the lantern proof | the private set intersection is built on X25519 | learn from a recorded test whether two keys matched |
| Call frames (AES-128-GCM) | libwebrtc always derives a 128-bit key; changing it needs a fork of WebRTC on five platforms | about 64-bit strength against Grover's algorithm; still inside the 256-bit relay layer |
| The link to a public peer over `tcp://` or `ws://` | the peer offers nothing better | see which mesh keys you talk to (Zen picks only `tls://`, `quic://`, `wss://` itself; their TLS 1.3 uses X25519MLKEM768) |

First contact with a stranger after a large quantum computer exists, with no
friend vouching for their key, is trust on first use.

## On the device

- **Storage encryption.** A random 256-bit master key encrypts data and files
  (AES-256-GCM; per-purpose keys derived with HMAC-SHA256). It is wrapped by
  a key from your password: **Argon2id**, 19 MiB, 2 passes. Failed attempts
  are throttled and remembered across restarts. File names are hidden.
- **Biometric unlock** keeps a copy of the master key wrapped by a key that
  never leaves the security hardware: Android Keystore (StrongBox when
  present), the TPM on Windows (with Windows Hello), the Secure Enclave on
  macOS (Touch ID). A copy of the app's files is useless elsewhere.
- **The locked phone (Android).** The background service holds a separate
  background key and only small kits (alarm, Nearby, doors), never the
  master key. What arrives is stored sealed until you unlock.
- **Screens.** The wallet and other sensitive screens are protected from
  screenshots and screen recording (Android, Windows, macOS). Clipboard
  copies of secrets expire after 60 seconds. Notifications show no content
  by default.
- **Several accounts.** Each account has its own keys, mesh node, folder,
  keystore entries and password. Folders are named by a keyed hash of the
  account ID; every device has 2 to 5 decoy folders from the first start,
  and a deleted account is replaced by a decoy, so the number of folders
  stays the same. Keystore entries of extra accounts have hashed names. There
  is no list of hidden accounts. A panic password erases its account
  silently.

## Memory hardening and tamper detection

- **Wiping secrets.** The Go bridge zeroes seeds and secrets after use (KEM,
  signatures, device key, link secrets), clears every answer to the app
  before freeing it, and keeps link keys in locked memory (`mlock`,
  `VirtualLock`). The app zeroes its native copies of seeds, one-time
  Bluetooth keys, KEM secrets and door seal keys.
- **Linux:** the process is not dumpable (`PR_SET_DUMPABLE=0`): no core dump,
  and another process of the same user cannot attach a debugger or read its
  memory.
- **Windows:** the heap terminates on corruption; DLLs are not loaded from
  the current directory, network shares or low-integrity files.
- **Detection:** Android (TracerPid, the Dart VM debugger, Frida in the memory
  maps and on its port, Xposed/LSPosed, emulator hints, a debuggable or
  re-signed copy), iOS and macOS (being traced, injected libraries, Frida,
  Substrate, libhooker, ElleKit, jailbreak), Windows (debuggers, Frida),
  Linux (TracerPid).
- **The response is proportionate.** Root, jailbreak or an emulator: a
  warning only, it is your device. Someone inside Zen's process (a debugger,
  Frida, hooks, an injected library, a re-signed copy): a warning, and Zen
  refuses to send transfers or use the pyramid power key, checked at least
  every minute. Even then a modified phone cannot create money: balances come
  from signed records that every member's phone checks.

## Honest limits

- Nothing protects against the owner of the device with root or a debugger
  the system allows; Zen detects and limits.
- iOS offers no public way to deny debuggers (`PT_DENY_ATTACH` is private);
  on Android, non-dumpable processes come from the system for release builds.
- Metadata is not hidden: the mesh and your relaying friends see who talks to
  whom and when; mailboxes count what they hold.
- Any Yggdrasil node answers debug questions about its direct neighbours
  (this needs a change in Yggdrasil itself).
- libwebrtc logs key material at its info log level; release builds keep
  WebRTC logging off, and it must stay off.
- Pyramid transfers are public to members (amounts and parties).
- Self-update checks the maintainers' signature only once their keys are
  pinned in the app; until then it relies on `SHA256SUMS` and, on Android,
  the signing certificate.
- The recovery circle's waiting time is kept by the helpers' honest apps.

Found something? Please report it privately: [SECURITY.md](../SECURITY.md).
