# Zen protocol specification (draft, from the code after 1.11.0)

*Written 20.10.2026 by reading the code, revised 21.10.2026 and 22.10.2026. Not a standard; the code is the
reference. Markers: **[V]** read directly in code and consistent; **[P]**
partly verified (shape known, details not all read); **[?]** uncertain or not
read - check the file named. Field names are the JSON keys on the wire.
Constants are quoted with the file that defines them.*

Companion document: [PRIVACY.md](PRIVACY.md).

Zen has no servers. Every device is a node on the **Yggdrasil** mesh and talks
to friends directly. This document describes (1) the transport, (2) the frame
types carried in it, (3) the layers above the frames (reliable delivery and
mailboxes, the signed ledger, pyramid records), (4) cryptography and
(5) versioning rules.

## 1. Transport

### 1.1 Mesh and addresses [V]

- Network: Yggdrasil 0.5.x (Go, `native/yggdrasil_bridge`, loaded over FFI by
  `lib/src/features/runtime/yggdrasil_bridge_ffi.dart`). The mesh gives every
  node an IPv6 address from its Ed25519 key; traffic between two nodes is
  end-to-end encrypted by Yggdrasil (NaCl-box sessions from the node keys),
  and links between peers use TLS / QUIC / WS / TCP as configured. All of
  this is classical cryptography; every signal is additionally sealed by
  Zen's post-quantum session layer (1.5).
- A **Zen address** is the node's Yggdrasil IPv6 address (`200::/7`, first byte
  `0x02`). `PeerShareCodec.normalizeAddress` canonicalises the text form; two
  addresses in the same /64 are the same "network" for rate limits and
  `identityKeyForAddress`.
- The bridge accepts packets **only** from node addresses (first byte `0x02`),
  never from the `0x03` subnet range, so one node cannot act as 2^64 senders.
- Invite code / QR: the address is encoded as a 24-character code in the
  alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` with a checksum
  (`PeerShareCodec.inviteCodeForAddress` / `addressFromInviteCode` [P]). Links:
  `zen://c/CODE` and `https://robertostrowskijagoda.github.io/Zen/#CODE`.
- Peering: a built-in list of public peers (`public_peers.go`; a phone
  dials 4 at once, a TLS-only subset first, the rest of the encrypted list
  in reserve for the peers that stop answering), local links with friends' and own devices without
  internet (1.6; Yggdrasil's own multicast discovery stays off), desktop
  inbound listener `tls://[::]:32913` [V], UPnP / NAT-PMP port mapping and
  "bridge" announcements in the ledger (`lg_bridges`).
- Transit on phones (`transit_guard.go`) [V]: every Yggdrasil node forwards,
  and ironwood weighs links by latency, so a phone on the same Wi-Fi as a
  computer bridge can become the cheapest way for the bridge's strangers'
  traffic to its own public peers. A phone estimates the traffic that only
  passes through it (`traffic_meter.go`, every 10 s over 30-s windows):
  what came in on one peering and went out on another, beyond its own
  packets and what its end-to-end sessions carried, so junk sent to the
  phone and the answers to it do not count. After three windows in a row
  above 64 KiB/s, or with transit while the last hour's is above 32 MiB, it
  keeps a single way to the mesh for 30 minutes: the friends' bridges when
  one is up (they are never set aside), otherwise one public peer, or one
  device nearby when no public peer is up. Holds double for each further
  hold within a day (at most 6 hours) only when the transit crossed between
  a peering nearby and a public one, as a home computer routing through the
  phone does; then transit that comes back holds again after one window.
  When a hold ends the phone takes its other public peers and local links
  back. Its own packets (signals, call media) never count as transit.

### 1.2 Signal datagrams [V]

Application frames ("signals") are UDP-style datagrams inside the mesh,
built and parsed by hand in `bridge_signaling.go` (IPv6 header + UDP header,
UDP checksum computed, hop limit 64).

| Item | Value |
|---|---|
| Signal port | **54321** (`yggSignalPort`) |
| Call-media relay port | **54322** (`yggRelayPort`) |
| Fragment size | 1300 characters of base64 (`signalChunkSize`) |
| Largest signal | **2 MiB** (`maxSignalPayloadBytes`; Dart: `kRuntimeSignalMaxBytes`); sealed (1.5) up to 1166 bytes more |
| Fragment lifetime | 90 s (`signalTTL`) |

**Fragment envelope** (UTF-8 JSON in the UDP payload):

```json
{"id": "<packet id>", "index": 0, "total": 3, "payload": "<base64 piece>"}
```

- The sender builds a *wire string* (the signal JSON text, optionally
  compressed - see below), base64-encodes it **as a whole**, and cuts the
  base64 text into pieces of 1300 characters. `id` is
  `"<unixNano>-<counter>"`; limit 128 characters.
- A single-fragment signal (`total == 1`) is decoded at once without buffering.
- Receivers refuse `total <= 0`, `index` out of range, `total >
  maxSignalChunks`, or a fragment longer than the largest legal base64 text.
  Fragments are keyed by `source|id`; limits: 1024 partial signals in all, 32
  per source, 64 MiB buffered, oldest of the busiest source dropped first.
  One lost fragment loses the whole signal (no retransmission at this layer).
- **Compression** [P]: a wire string may be `"ZSTD:" + base64(zstd(json))`.
  The Go sender compresses when the JSON is at least 8 KiB, does not contain
  `"chunkData"`, `"attachmentData"`, `"_zenEncoding"` or `"_zenPayload"`, and
  the result (plus 64 bytes of slack) is shorter. The Dart layer
  (`runtime_signal_codec.dart`) also compresses JSON of at least 8 KiB (zstd
  level 3) into `{"_zenEncoding":"zstd","_zenPayload":"<base64>"}` under the
  same exclusions; because that wrapper contains `_zenEncoding`, the Go layer
  then skips it. **[?]** which of the two is actually used for a given send
  (the Dart one runs first in `YggdrasilSignalTransport.send`); receivers
  accept both and uncompressed JSON.
- **Decompression limits** [V]: a zstd signal may inflate to at most 64x its
  compressed size (minimum allowance 64 KiB) and never above 2 MiB; the
  decoder streams and stops at the limit.
- **Rate limit** [V]: token bucket per source /64: 2000 datagrams/s, burst 4000
  (`signal_inbox.go`), applied before parsing. Receive queue: 2048 signals,
  32 MiB total, ~2.06 MiB per source, oldest of the heaviest source dropped.
- **Delivery** is best-effort UDP. Reliability is added above (section 3.1).

### 1.3 Call-media relay (port 54322) [V]

WebRTC media for calls is not sent over the signal port. The Go bridge opens a
local UDP relay per call (`openRelay`/`closeRelay`, bound to the device) that
the WebRTC stack uses as a "relay candidate"; packets are forwarded to the peer
as `[1 byte callId length][callId bytes][RTP/DTLS payload]` over port 54322.
The bridge accepts relay packets only from the peer's address that was
registered for that `callId`, and only from local sources on the device side.
On the mesh every relay packet is a media frame (`M`) of the post-quantum
session layer (1.5): the relay frame above is its plaintext, so the call id,
RTP/RTCP headers, ICE and the DTLS handshake are sealed too (ChaCha20-Poly1305,
256-bit key from the hybrid KEM, one AEAD per packet, 46 bytes overhead once
the session is acknowledged, nothing buffered). A packet without a session yet
is dropped, never sent in clear. Inside, media is protected by WebRTC's
DTLS-SRTP and by frame-level end-to-end encryption (2.5.1; AES-128-GCM, the
key size libwebrtc fixes).

### 1.4 Frame model [V]

After reassembly the Dart side parses the JSON object:
`SignalTransportFrame {from, payload (Map), receivedAtMillis}`. The sender's
address (`from`) is the authenticated mesh source, not a field in the payload.
Every frame has a string `type`. Frames from non-friends are mostly ignored
(see per-type notes). Size caps on strings are applied by the parser
(`runtime_signal_parser.dart`).

### 1.5 Post-quantum session layer (`pq_session.go`, `pq_kem.go`) [V]

Yggdrasil's own cryptography (X25519 / NaCl box, Ed25519, link TLS) would
fall to a large quantum computer, and recorded traffic could be read then
("harvest now, decrypt later"). So the bridge seals every signal of the
main node once more, before fragmentation (and after compression), with a
hybrid key: **MLKEM768-X25519 ("X-Wing")** from Go's `crypto/hpke` and
`crypto/mlkem`, used as HPKE base mode, HKDF-SHA256, export only (exported
secret `zen.pq.secret.v1`). The key is safe while either ML-KEM-768 or
X25519 holds. There is no plaintext mode: a node refuses every signal that
is not sealed (no compatibility with older builds).

- **Device key:** the X-Wing seed is `HKDF-SHA256(node Ed25519 seed, info
  "zen.pq.device.v1|1")`, so every process running the node (app, Android
  background service) has it and it never leaves the bridge. Public key
  1216 bytes (ML-KEM encapsulation key, then X25519), ciphertext 1120.
- **Key record** (1320 bytes): `version 1 | suites 0x01 | node key (32) |
  KEM id 0x647a | key version (4) | public key | Ed25519 signature` over
  `"zen.pq.record.v1\0" + body`. A receiver takes it only if the node key
  hashes to the sender's mesh address, so nobody can swap it - the invite
  code / QR (the address) already pins it. `suites` is a bit set (unknown
  bits are refused). The record stays Ed25519 only: the address commits to
  the Yggdrasil node key alone, which is Ed25519 and cannot change, so an
  ML-DSA signature here would anchor nothing. A quantum attacker with the
  node key could sign a record of its own; pins, challenges and the
  `lg_hello` binding (below and 3.3) make that useless against anyone who
  knew the device key before, and who a peer *is* in Zen (account,
  devices, everything they sign) rests on the hybrid signatures of 4.1.
- **Wire** (`"ZPQ1"` and a kind; signals on port 54321 before
  fragmentation, media as the payload of a relay packet on port 54322):
  - `K` flags(bit 0 want, bit 1 challenge) record [chid(16) ct(1120)]: the
    sender's key record; with bit 1 a challenge for the recipient.
  - `D` flags(bit 0 opening) sid(16) counter(8) [chid(16) ct(1120)] AEAD:
    a signal.
  - `M` the same layout: call media (only on the relay port; `D` only on
    the signal port).
  - `A` sid: the session is known here.
  - `N` flags(bit 0 want, bit 1 challenge) sid(16) [chid(16) ct(1120)]:
    the session (or the challenge it was opened with) is not known here.
- **Challenges (sender authentication):** a node answering a key request
  (`K` with "want") gives the asker a challenge: a fresh secret
  encapsulated to the asker's device key with info
  `"zen.pq.challenge.v1" | issuer | holder | chid`. It keeps up to 4 per
  peer for 6 h; the holder starts sessions with a challenge younger than
  4 h and asks for a new one after 2 h, so a rotation never waits.
- **Sessions** are one-way, per ordered pair. The first send to a peer asks
  for its record and a challenge (`K` with "want", our record included) and
  holds the frames (<= 64 per peer, 4 MiB, 20 s; media is never held). Then
  one encapsulation to the peer's device key with info
  `"zen.pq.session.v2" | sender | recipient | sid`; the keys are
  `HKDF-SHA256(kemSecret | challengeSecret, info "zen.pq.keys.v2" | sender |
  recipient | sid | chid)`, 64 bytes: a signal key and a media key, each with
  its own counter and replay window. Only the holder of the recipient's
  device key reads a session; only the holder of the sender's device key
  (who opened the challenge) can start one the recipient takes as coming
  from that address. Frames carry the opening (chid, ciphertext) until the
  peer answers `A`; a receiver that does not know the session or the
  challenge answers `N` with a fresh challenge (or "want" when it lacks
  the sender's record) and the sender starts a new session. Sessions
  rotate after 1 hour or 2^24 frames of either kind; a receiver keeps 4 per
  peer and opens at most 16 new ones (sessions and challenges) a minute per
  peer; KEM work other nodes can cause is capped at 200/s (burst 400). A
  receive session opens nothing after 2 hours; a forced pin (or a new key
  record) drops every session made with the old key, both ways; a frame
  carries the fingerprint of the key its session was made with
  (`senderKey`).
- **Pins:** the device key is pinned per address on first sight; a record
  with another key for a pinned address is refused. New pins come at most
  120 a minute; at 16384 the pin seen longest ago makes room. The app keeps
  the pins (sealed, `runtime/yggdrasil.pins`) and hands them back after a
  restart (`YggPqPinsJson` / `YggPqSetPinsJson`). It also pins keys others
  vouched for before any contact (3.3: hybrid-signed hellos and device
  records, friends' friend lists); with `keep` a different pin stays and is
  reported as a conflict. Every received signal carries the fingerprint
  (SHA-256 of the device public key, hex) of the sender's key
  (`SignalTransportFrame.senderKey`); `YggGetNodeInfo` gives the own one as
  `pqKey`.
- **AEAD:** ChaCha20-Poly1305 under the session key, nonce `0^4 | counter`,
  associated data the frame header plus sender and recipient address.
  Counters are used once; the receiver refuses repeats and anything more
  than 1024 (media: 4096) behind (replay window). The AEAD of a known
  session runs outside the endpoint lock, so a large signal never holds up
  call media.
- **Cost:** KEM operations only at session start, rotation and challenges,
  never per message; per frame one AEAD (~3.5 us for 1 KB seal + open; a
  1200-byte media packet ~4.6 us).
- **Exempt:** the flat's doors (door nodes, `door_node.go`) keep plain
  signals - they never run a session layer; door frames are flat frames
  only, and knocks for mailbox doors are sealed by the app (`flat_seal`,
  classical X25519).

### 1.6 Local links (`local_link*.go`, `lan_discovery.go`, `bluetooth_link*.go`) [P]

Friends' devices and the account's own devices near each other peer Yggdrasil
over any byte stream, with no internet. The app gives the bridge one 32-byte
secret per device it may link with (HKDF over the X25519 form of both ledger
device keys, label `zen.local.v1`); a stranger has none.

- **Post-quantum pair secret:** two devices that may link (friends' or the
  account's own) and reach each other over the mesh exchange `local_pair` signals
  (`{type, d: sender device key, to: recipient device key, c: 32 random
  bytes, h: base64url(SHA-256("zen.local.pair|" + c)[:16]) of the
  contribution last heard}`), so they travel inside the hybrid session layer
  (1.5); the sender's address must be the one a signed hello proved for
  `d`. Once each side has the other's contribution and heard back
  the hash of its own, the pair secret becomes HKDF-SHA256 (salt: the
  classical secret, nonce: the two device keys sorted and joined with `|`,
  info `zen.local.pq.v1`) of SHA-256(`"zen.local.pair.secret|"` + both
  contributions ordered by device key). A new contribution (a reinstall)
  starts a new pairing; until one completes, the classical secret is used.

- **Transports:** the same Wi-Fi, cable or hotspot network (UDP beacons on
  port 39319 every 10 s while the app is used, 30 s otherwise, then TCP);
  a Wi-Fi Direct group (Android, Windows), which is only a network the LAN
  discovery then runs over (the group's name and passphrase sit in the
  service record, so anyone nearby can join the group but cannot link);
  Bluetooth (BLE GATT service `5a454e00-6c69-6e6b-0000-000000000001`,
  manufacturer data of company `0xFFFF` starting `"ZL"`, L2CAP channels or,
  on Windows, GATT streams; classic RFCOMM with paired devices on Android
  and Windows); Apple Multipeer (service type `zen-link`). Wi-Fi discovery,
  Wi-Fi Direct and Bluetooth are on unless turned off, Multipeer is off
  until the person turns it on; a native transport runs only while there
  is a device to link with. Phones use Wi-Fi interfaces only, never
  mobile data.
- **Adverts** carry a Bloom filter with one tag per device the sender links
  with (`HMAC(tagKey, "adv" | 5-minute slot | salt)`, a fresh random salt
  every time, filter size in steps of 16 bytes), so to anyone without the
  secret they are random bytes; they reveal only that a Zen device with
  local links is there and roughly how many devices it links with.
- **LAN beacon**: the advert, then the "people nearby" advert of 2.12 (20
  bytes, only while the person is visible), an info byte (that advert's
  length, 0 or 20, plus `0x80` while the sender looks around) and the TCP
  port (2 bytes, big-endian). A device looking around beacons every 5 s; a
  visible device answers such a beacon with one beacon sent straight back
  (at most every 5 s per address). A device with no devices to link with
  beacons only while it looks around.
- **Handshake** (both ends, any stream): fresh X25519 keys, a selector
  `HMAC(selKey, ephemeral key)[:8]` per candidate device shuffled with random
  padding, session keys from HKDF over the X25519 result with the pair's
  link key; then AES-256-GCM records. The first record is the sender's
  Yggdrasil key, which must hash to the mesh address the secret was given
  for. Yggdrasil then peers over the stream with that key pinned.
  Classical X25519 only; what travels over it is sealed again by 1.5.
- Limits: 2048 devices, 16 streams, 8 handshakes at once, 2 per source,
  beacon rate limits per sender and in all.

## 2. Frame types

Direction is sender -> recipient unless stated. "Reliable" means the type is in
`kReliablePayloadTypes` (section 3.1).

### 2.1 Presence

| type | Fields | Notes |
|---|---|---|
| `ping` | presence: `state`, `lo`; optional hello: `mf`, `mk`, `ms`; version: `ver`, `build`, `caps`, `minv` | Only while Zen is on the screen: to every target when the app comes to the screen (once more when the node first reaches the mesh, if that round went out before it did), at once to a target just added, then every 2 min (`kPresencePingInterval`). Targets: accepted friends, plus members of groups with an unconfirmed invitation from this device. Not answered unless the sender is a friend or group member. |
| `pong` | presence: `state`, `lo`; hello fields, version fields | Reply. Hello fields (friends who see presence): `mf` short digest of the friend list sent, `mz` digest of the nearby keys given to that friend, `ms` time the current status was set (0 if none or not visible), `ma` digest of the alarm key. The receiver asks again for what does not match with `meet_req`. A locked Android phone answers one contact at most every 3 min 30 s (`kLockedPongEvery`: the first ping after a quiet while at once, then every other one), with no presence or hello fields; an open Zen answers a weak acquaintance exactly so, and as rarely. |
| `away` | presence: `state`, `lo` | A one-way presence announcement, despite its name for any change of the sender's state: leaving the screen (`"background"`, or `"asleep"` on an iPhone iOS suspends), coming back before the next round (`"foreground"`), quitting Zen on a computer (`"asleep"`), and what was held back while the node had no network, once it has. Sent only to friends who see presence and have Zen open now (their last `ping`, `pong` or `away` in this run, within 5 min, said `"foreground"`), and only when they were last told another state; at most one per state per friend every 30 s (`kPresenceNoticeEvery`), changes within 2 s told as one (`kPresenceNoticeDelay`). One held back goes when its time is over, unless the state is back to what they were told. An iPhone's `"asleep"` goes to every friend who sees presence (their mail should go to the mailboxes now), to one without Zen open at most every 4 min (`kPresenceAwayEvery`). Never mailboxed; ignored by a locked phone (which says `"background"` in its pongs, so it never gets one). A 1.13 Zen applies whatever `state` an `away` names. |
| `typing` | `isTyping` (bool) | Real-time, not reliable. |

Presence fields ride on the frames above; nothing is polled only for them.
They go only to accepted friends who may see statuses (not to a friend at
the "weak acquaintance" level, and never to group members or strangers); to
anyone else a `ping` or `pong` carries neither field.

- `state`: `"foreground"` (Zen is on the sender's screen), `"background"`
  (off the screen but still receiving: Android's background service, a
  computer's tray, an iPhone with the keep-alive) or `"asleep"` (off the
  screen and about to stop receiving: an iPhone iOS suspends). A frame
  without `state` says nothing about presence; the receiver shows none
  (unknown for a Zen older than 1.13.0, see below).
- `lo`: seconds since Zen was last open on the sender's screen (0 while it
  is open). Left out when the sender turned off "show when I last opened
  the app", or does not know (a computer that started in the tray).

The receiver shows *online* for `"foreground"`, *in the background* for
`"background"`, and *offline* for `"asleep"` or when the state expires:
*online* after 5 min without a new frame (`kPresenceForegroundFor`: a
friend on the screen pings every 2 min and answers at once, and says
`away` when it leaves), *in the background* after 10 min
(`kPresenceOfflineAfter`: a locked phone answers every 4 min, as it
answers one contact at most every 3 min 30 s). The receiver keeps the last
opening (receive time minus `lo`) and shows it while the friend is not
online. A locked Android phone takes `state` and `lo` for its pongs from a
presence kit the app writes, sealed with the background key, whenever Zen
leaves the screen (`presence-kit.zenbg`: the friends who may see presence
and when Zen was last open).

The receiver shows a fourth state, *unknown*, while it cannot tell; the
last state known is kept underneath and nothing is sent for it:

- *No network*: this device has not reached the mesh for 30 s
  (`kPresenceNoNetworkAfter`). Nothing expires into *offline* meanwhile.
  Back on the mesh, the friends who had Zen open are pinged at once (they
  hear this device and answer); the others are settled 20 s after the next
  round (`kPresenceSettleAfterResume`).
- *Not checked*: the state remembered from before a start (kept per friend
  in the encrypted social snapshot: the state, when it was last confirmed,
  the last opening), until the friend's next frame, or until 20 s after the
  second round of pings that could arrive (about 2 min after the node
  reached the mesh), when it shows what that state is worth by then. The
  same after coming back to the screen for a state that would have expired
  meanwhile.
- *Too old*: a friend whose `ping` or `pong` names a `ver` older than
  1.13.0 and no `state` (a newer Zen without `state` hides its presence from
  this person, which shows nothing).

### 2.2 Friends and profile

| type | Fields | Notes |
|---|---|---|
| `friend_request` | `senderName`, `message` (<=1000 chars) | Reliable, direct only (no relay: recipient unknown). |
| `friend_accept` | `senderName` | Reliable. |
| `friend_reject`, `friend_cancel`, `friend_remove` | - | Reliable. |
| `profile_update` | `v` (profile `updatedAtMillis`), `name`, `status`, `bio`, `avatar` | Reliable. `v` is monotonic. Names limited to 60 characters locally, 64 on receipt. |
| `friend_list` | `l`: list of `{a: address, n: name}`, `d`: sha256 hex digest of the list | Reliable. Sent per friend according to the audience for the friend list; an empty list with the empty-list digest means "forget it". |
| `meet_req` | `w`: list of `"l"`, `"k"`, `"s"`, `"a"` | Asks again for the friend list, nearby keys, status or alarm key. |
| `nearby_key` | `z` (`"z2."` + base64url JSON `{v:2, h: mask key, p: pair key for this friend, a: {chain: anchor}}`) | Reliable. Lets the friend recognise this phone's Bluetooth tokens and check its alarm waves (2.12). |
| `intent` | `s`: `{k, at, until, note?<=140, close?, e?}` or absent | Reliable. A "Right now" status; absent `s` clears it. |

### 2.3 Messages

| type | Fields | Notes |
|---|---|---|
| `message` | `msgId`, `senderName`, `text`, `messageType` (`text|image|file|voice|video`), `attachmentData` (base64), `attachmentEncoding`, `fileName`, `mimeType`, `attachmentSizeBytes`, `durationMs`, `createdAt` (sender clock, ms), `ttl` (seconds), `re` (reply: `{id, s?: sender, t?: start of its text <=200}`), `fwd` (true: forwarded) | Reliable. One of `text`, `attachmentData` required. GIFs travel as ordinary image attachments. Frames up to 48 KB can be mailbox-relayed (section 3.2); the signal limit is 2 MiB. A reply to a disappearing message carries no `t`. |
| `message_placeholder` | as `message` plus `chunkCount`, `chunkIndex`, `attachmentTransferBytes` | Announces a large attachment sent in chunks. |
| `message_chunk` | `msgId`, `chunkIndex`, `chunkCount`, `chunkData` (base64), + placeholder fields | Not reliable; has its own protocol. Never compressed (high-entropy). |
| `message_chunk_ack` | `msgId`, `chunkIndex` | |
| `message_ack` | `msgId` | Delivery acknowledgement of a message (reliable). |
| `message_read` | `msgId` | Read receipt (reliable). |
| `message_transfer_cancel` | `msgId` | Reliable. |
| `transfer_offer` / `transfer_answer` | `transferId`, `description` (WebRTC SDP map), + file fields (`fileSize`, `fileName`, `mimeType`, `messageType`, ...) | File transfer over a WebRTC data channel [P]. |
| `disappear_timer` | `groupId?`, `seconds` (0 = off), `at` | Reliable. Same `ttl` is carried by messages. |
| `msg_react` | `msgId`, `groupId?`, `emoji` (<=16 chars; empty = taken back) | Reliable. One reaction per person per message. |
| `msg_edit` | `msgId`, `groupId?`, `text`, `at` (sender clock, ms) | Reliable. Taken only from the message's author, only for text, and only while `at` is within 25 h of the message (24 h + 1 h clock leeway). The earlier text is not kept. |
| `msg_delete` | `msgId`, `groupId?`, `at` | Reliable. Taken from the author, or in a group from its creator as recorded by the receiver. The content and file go; a note stays; replies drop the quoted text. |

`msg_react`, `msg_edit` and `msg_delete` (like `message` and `disappear_timer`)
are mirrored to the sender's other devices, which apply them as their own.

### 2.4 Groups

Groups are fan-out: the sender sends the frame to **each member** individually
(at most 256 members, `kMaxGroupMemberCount`). Every group frame needs `groupId`
(<=256 chars).

| type | Fields | Notes |
|---|---|---|
| `group_invite` | `groupId`, `groupName` (<=100), `description` (<=1000), `memberAddresses`, `avatarPreset`, `senderName`, `inviteId` | Reliable. `inviteId` is a nonce: re-sends of the same invitation do not revive a declined group. |
| `group_invite_ack` | `groupId` | Reliable. |
| `group_message` | `groupId`, `groupName`, `msgId`, `text` (<=64k chars), `senderName`, `timestamp`, `ttl`, `re`, `fwd`; for a file also `messageType`, `fileName`, `mimeType`, `attachmentSizeBytes`, `durationMs` and either `attachmentData` + `attachmentEncoding` (inline, files <=64 KB, or <=1 MB while no block store runs) or `media` (`{id, k, n, mime}`: the reference of `lg_blob_*` blocks, files <=24 MB) | Reliable. A member fetches `media` blocks with `lg_blob_want` from the sender or any other member; a member's device answers such requests from non-friends too. |
| `group_leave` | `groupId` | Reliable. |
| `group_post` | `groupId`, a board post `{id, a author, n name, x text <=2000, t created, v version, d? removed, m? photo reference {id, k, n, mime}}` | Reliable. A new, edited or removed post; the newest `v` wins. Photos up to 8 MB as `lg_blob_*` blocks. At most 20 new posts per member and group an hour; a board keeps 300. |
| `group_board_have` / `group_board_put` | `groupId`, post ids and versions / up to 50 posts | Real-time sync between members: what I have, and the asker's missing posts written by the one answering. |

### 2.5 Calls (signalling) [V]

Not reliable (real-time). `kind` is `"audio"` or `"video"`; most carry `callId`.

| type | Fields |
|---|---|
| `call_invite` | `callId`, `kind` |
| `offer` / `answer` | `callId`, `kind`, `description` (SDP map; the first offer and every answer may carry `e2ee`, 2.5.1) |
| `ringing`, `call_accept` | `callId`, `kind` |
| `call_decline`, `busy`, `hangup` (alias `call_end`), `call_offer_request` | `callId`, `kind` (`callId` mandatory for decline/busy/hangup) |
| `call_mkey` | `callId`, `epoch` (int): the sender's media key moved to `epoch` (2.5.1) |

Media: WebRTC, relayed through the local bridge relay (1.3). Screen share and
recording are signalled inside the call [?].

**Group calls** (`groupId` and `callId` mandatory): `group_call_invite`,
`group_call_join`, `group_call_state`, `group_call_leave`, `group_call_decline`,
`gc_offer`, `gc_answer` with `groupName`, `kind`, `participants` (address list),
`description` (SDP, with `e2ee` as in 1:1 calls), `senderName`, `camera` (bool).
Inside a call: `gc_mkey` {`callId`, `epoch`} per leg, like `call_mkey`.

### 2.5.1 Call media encryption [V]

Every audio and video frame (microphone, camera, shared screen; 1:1 calls and
every leg of a group call) is sealed end to end by WebRTC's frame transformer
(flutter_webrtc `FrameCryptor`, AES-GCM, natively on the media threads; no
Dart code runs per frame), inside DTLS-SRTP.

- **Key agreement:** the offering side puts a fresh hybrid public key in its
  offer: `description.e2ee = {v: 1, pk}` (MLKEM768-X25519, the KEM of 1.5,
  base64url). The answering side encapsulates to it and answers
  `{v: 1, ct}`. KEM `info`: `"zen.call.media.v1|kem|" callId "|" offerer "|"
  answerer`. Participant ids are `offerer` / `answerer` in 1:1 calls and the
  lower-case mesh addresses in group legs (each leg has its own exchange, so
  nobody holds the keys of a leg they are not on). Offer and answer travel in
  the post-quantum session layer (1.5).
- **Keys:** one chain per direction. Epoch 0: HKDF-SHA256(ikm = KEM secret,
  salt = `"zen.call.media.v1"`, info = `"zen.call.media.v1|chain|" callId "|"
  sender "|" receiver`), 32 bytes. Epoch n: HKDF-SHA256(ikm = key n-1, salt =
  `"zen.call.media.v1|ratchet"`, info = callId "|" sender "|" n). The key of
  epoch n sits in ring slot n mod 16; WebRTC turns it into the AES key with
  HKDF (salt `"zen.call.media.v1"`) and each frame names its slot.
- **Rotation:** each side moves its own chain forward every 5 minutes and, in
  group calls, whenever somebody joins or leaves (rotations closer than 2 s
  are merged), then sends `call_mkey` / `gc_mkey`. Receivers always hold the
  next 3 keys of the other side's chain, so the switch needs no round trip
  and drops no frame; a lost notice is covered by that lookahead, and a frame
  naming a slot without a key widens it. The previous key is kept 10 s for
  late frames, then its slot is overwritten with a random key. A notice more
  than 64 epochs ahead is ignored.
- **Fallback:** where the device has no frame encryption, or the other side
  sends no `e2ee` block, the call runs on DTLS-SRTP alone and the call screen
  says "Standard encryption"; with frame encryption it shows "Quantum-resistant
  encryption". A group call shows the weakest leg.
- **Platforms:** flutter_webrtc 1.5.2 or later on Android, iOS, macOS,
  Windows and Linux.

### 2.6 Meeting features (all reliable) [P]

Handled by `meet_service.dart` and the sub-services. Only friends are
accepted (parkable types wait for the friendship to settle).

- **Alarm**: `alarm` {`id`, `at`, `lat`, `lon`, `acc`, `locAt`, `note`, `resp`
  (map friend -> answer), `end`, `duress`, optional `cf` (please confirm)};
  `alarm_resp` {`id`, `r`}; `alarm_ack` {`id`, `k`: `got` or `seen`, ...};
  `alarm_audio` {`id`, `n`, `at`, `ms`, `d` (base64 sound piece)}. Limits:
  sound piece <= 200 KiB, <= 6 pieces per alarm. Alarm key:
  `alarm_key` {`c`: certificate `{a, k, at, d (device cert), s}`, `k` the
  alarm key's hybrid id (4.1), hybrid-signed by the device key}; an `alarm`
  may carry `sg` (hybrid signature over the canonical fields, positions in
  millionths) and `sk` (the alarm key's hybrid id), and `kit: true` for a
  copy sealed in advance; `alarm_own` / `alarm_own_audio` exist
  only in the sealed inbox (from the device's own address).
- **Events**: `event`, `event_rsvp`, `event_plus1`, `event_pass`, `event_photo`,
  `event_thanks` (ticket QR prefix `zen-ticket:`) [?] fields. Tickets carry
  no signatures: the organiser's tag is HMAC-SHA256 under a key from the
  event's secret, and the live code (valid +/-90 s, once) is an HMAC with a
  pin known only to the guest's phone and the organiser (the RSVP carries
  it inside the sealed signal). The organiser's phone checks them offline;
  a ticket QR stays under 400 characters.
- **Questions**: `ask`, `ask_answer`. **Circles**: `circle`, `circle_swap`,
  `circle_guest`. **Food sharing**: `food_offer`, `food_req`, `food_ans` (the
  pickup address sealed for the accepted person's one-time hybrid key).
  **Weekend plan**: `weekend_plan`, `weekend_plan_ans`. [?] fields in the
  respective services.
- **Table for six** (`table_service.dart`): one type, `table_wish`. Without
  `k` it carries a wish `w` (to friends with name and address; a go-between
  passes it to its own friends "blind": first name, city, optional area
  `ar` and days, no address; an empty `city` withdraws it). With `k` it is a
  step of an invitation `{k, e: event id, w: wish id}`: `inv` (host to guest,
  with a one-time hybrid key, directly or through the go-between), `ans`
  (guest: yes with the address sealed for the host's key, or no), `ok` /
  `no` (host's decision; `ok` brings the place and the host's address
  sealed for the guest's key, then the event comes directly from the host).
  The go-between sees only ciphertext. Wishes live 30 days, clock skew
  10 minutes.
- **Introductions and gates** (`intro_*`): `intro_ask` (X asks friend F for an
  introduction to Y, a letter for Y, or F's friend list; for a paid gate `x` =
  the pyramid payment id; someone introduced to F may ask F for the next
  gate), `intro_fwd` (F to Y), `intro_ans` (Y to F), `intro_res` (F to X,
  field `s` = status; `price` with `pr`; Y to X `in` = the introduction
  came), `intro_gate` (F's gate terms for a friend: `p` price, `c` consent,
  optional `r`/`o` terms that may be passed on and `v` passed-on gatekeepers
  with their friend lists), `intro_end` (X to a gatekeeper: how the way
  ended; a gate still waiting is withdrawn and its payment returned, an
  opened gate keeps its payment, settled when it opened), `intro_pay` / `intro_paid` (a paid first message to
  someone who is not a friend: payment id `x`, answer `ok`) [P].

### 2.7 Neighbours (`flat_*`) [?]

`flat_hello`, `flat_nope`, `flat_profile`, `flat_card`, `flat_get`, `flat_msg`,
`flat_signup`, `flat_signup_ok`, `flat_house`, `flat_join`, `flat_leave`,
`flat_moved`, `flat_kick`, `flat_rekey`, `flat_newkey`, `flat_reveal`,
`flat_ack`, and for mailbox doors `flat_seal`, `flat_slot`, `flat_held`
(`neighbors_service.dart`). Between flats they go from door node to
door node (`door_node.go`, `FlatTypes.atDoor`), retried by the sending phone
until the other door answers `flat_ack {id}` (knocks are never answered);
`flat_reveal` comes from the resident's own phone. Between housemates
(`flat_house`, `flat_join`, `flat_leave`, `flat_kick`, `flat_rekey`) they go
phone to phone, reliable but only directly. A door QR gives a "door secret"
that authorises `flat_hello`.

**Joining a household:** the housemate code is a one-time token valid for
10 minutes (no flat key in it). The new phone sends `flat_join {step: ask}`
(name, device, resident key, X25519 and ML-KEM-768 keys); the phone that
showed the code asks its owner and answers `step: ok` or `step: no`; only
after `ok` does the flat key travel, sealed for the new phone's hybrid key,
followed by the usual signed `flat_join`. An invitation shown nearby is a
token of its own valid for 24 hours (shared by the household in
`flat_house`), never the sticker's permanent code. Messages to neighbours
are signed with the writer's name in the flat. In a household of two,
removing the other phone waits for its consent or 7 days.

**Mailbox doors** (`flat_door_mail.dart`): a door runs on a resident's phone
and answers only while that phone is online, so the door sticker also lists up
to 6 "mailbox doors": door nodes run by the friends who keep that phone's
offline mailboxes (`flat_slot` asks a friend to run one, or to stop; a phone
runs at most 8 for friends). A knock for such a door is sealed for the flat
(`flat_seal`, X25519 `FlatSeal`, key derived from the door key that stays on
the residents' phones): the friend keeps only ciphertext (at most 10 per
door, 4 a day, 2 per knocker, 7 days), learns neither who knocked nor which
flat, and hands it to the resident (`flat_held`, through the relay layer) when
the resident shows up; the answer to "Let in" can travel back the same way.
Doors answer no queries; while the app is locked (Android) the background
service keeps the doors from its door kit and stores what arrives sealed.

### 2.8 Dating (`date_*`) [P]

Only between friends (lanterns and what travels back also across opened gates), except the flooded lantern.

| type | Notes |
|---|---|
| `date_lantern` | `{id, hops, path, l, g?}`: a lantern flooded to friends (and across opened gates, `g`) weekly by every phone, dating on or off, `kDatingMaxHops = 3` (`hops` starts at 2). `l` is `{v:5, h: SHA-256 of a one-off hybrid key (X25519 and ML-KEM-768 + X25519), new every lantern}` (`DatingLantern`), about 60 bytes. With `x` (`{by, nt, pk}`) it is a lantern made for an introduction, handed over by the matchmaker, never passed on. |
| `date_back` | `{to, m?, box, ttl, n, g?, oa?}`, travelling back along `path`; `n` counts the phones it passed (the distance is not the asker's word), `oa` is the first phone's tag of the dating key the sender told it (`datingOriginTag`; `-` unknown). `box` is `{lk:1}` (ask a lantern for its keys) or `{lkr:{k,q}}` (the keys, checked against `h`), otherwise a hybrid `DatingBox` `{e, c, n, x}`: `match` `{id, pq}` (no wishes); `match_re` `{id, a, o: 18 offer bits, n: secret}` (the sealed offer, `DatingMatch`); `fetch` `{id, a, s: 18 wish bits, the proof of fit; none for a decoy}`; `prof` (the signed profile core or a cover, exactly 24 KiB, token `t`, `lp` = HMAC of the answer's secret); `part`/`part_re` (a photo or 6 vouches, exactly 64 KiB); `like` (KEM ciphertext + hybrid signature), `msg` (pair-key MAC), `mutual`, `intro_ask`/`intro_re`/`intro_l`. |
| `date_key` | `{k, w?}`: this phone's dating key, to friends, group members and people across gates, dating on or off. |
| `date_intro`, `date_intro_re` | A matchmaker asks a friend for a lantern for an introduction; the friend's phone answers alike with dating on or off. |
| `date_ask`, `date_ask_re` | "What do you think about X?" and the answer, between friends. |
| `date_vouch_req`, `date_vouch` | Ask for / give a few words for a profile. |
| `date_safe`, `date_safe_ok`, `date_loc_req` | "I'm going on a date", "All OK", a one-shot location request. |

### 2.9 Relay mailboxes (`rly_*`)

See 3.2. Types: `rly_ack`, `rly_announce`, `rly_announce_ack`, `rly_deposit`,
`rly_deposit_ack`, `rly_poll`, `rly_here`, `rly_mail`, `rly_mail_ack`,
`rly_purge`, `rly_sync`, `rly_sync_want`. Anything starting with `rly_` is consumed by the
relay engine and never reaches the app layer.

### 2.10 Ledger (`lg_*`)

See 3.3. Types: `lg_hello`, `lg_keys`, `lg_bridges`, `lg_reach`, `lg_reach_ok`,
`lg_sibling`, `lg_heads`, `lg_want`, `lg_entries`, `lg_revoke`, `lg_cert_want`,
`lg_certs`, `lg_blob_want`, `lg_blob_manifest`, `lg_blob_chunk`, `lg_push`,
`lg_post_want`, `lg_post`, `lg_mention`.

`lg_push` {`entries`} is the only reliable ledger frame: a device's new
entries in `feed` and `acts` (not the bundled `rx` reactions) go after 30 s,
in batches of at most 30 KB and 10 an hour per friend, through the reliable
queue to friends who are offline, so they wait in those friends'
mailboxes. The receiver takes them like `lg_entries`, with the same checks.

`lg_mention` {`e`, `p`?} is reliable too: the notice to a person
mentioned in a post, an edit or a comment. `e` is that signed entry and
`p` the post a comment or an edit belongs to, each with its device
certificate. A mention is a token `<@N>` in the
text, N indexing the body's `men` list of {`d` address, `a` account?,
`n` name?} (at most 20). The receiver checks the signatures, that a token
names its address or account, that the post is held or carried and signed
by its author, and that the writer may mention it (its own post, a friend,
it reacted to that post, or the sending address is on a friend list
shared with it); it announces each mention once, at most 10 an hour per
writer, 20 an hour from people who are not friends and 5 an hour from them
under one post, counted on the disk across restarts. It names the writer
only by the name it gave a friend or the name on a friend's shared list;
anyone else is "someone", and the notification then says only that
somebody mentioned it. Group messages
carry `men` the same way; the receiver announces a mention only from a
member of the group.

### 2.11 Pyramid (`pyr_*`)

See 3.4. Types: `pyr_hello`, `pyr_rec`, `pyr_recs`, `pyr_ids`, `pyr_want`,
`pyr_prop`, `pyr_sig`, `pyr_vote`, `pyr_card`, `pyr_priv`, `pyr_report`,
`pyr_anon`, `pyr_dm`, `pyr_sum`, `pyr_nat`, `pyr_who`, `pyr_here`.

**Private money** (`pyramid_treasury.dart`, `pyramid_ledger.dart`):
`pyr_priv {c, b}` is a message sealed for one recipient's pyramid KEM key
(`kemkey` record, 3.4): `c` the hybrid ML-KEM-768 + X25519 ciphertext, `b`
the AES-GCM box, context `zen.pyr.priv.v1`; only from a member's address.
Inside, `k` names the kind: `ord` (an order or settlement for a treasurer to
sign: payer-signed, next account number), `tsig` (a treasurer's signature
back), `fin` (an operation with a majority of treasurers' signatures, to the
treasurers and the parties), `stq` / `st` (a member asks for a balance
statement; a treasurer's signed answer, every 12 h), `note` (who gets an
emission), `ldig` / `lwant` / `lops` (treasurers' ledger sync every 30 min).
Transfers are never records; members who are not treasurers or parties
receive nothing.

### 2.12 Nearby (Bluetooth LE: Android and computers) [V]

Not Yggdrasil. Implementation: `ZenNearbyBridge.kt`, `nearby.dart`,
`nearby_crypto.dart`; on computers the same advertisement through WinRT
(`nearby_radio_bridge.cpp`), BlueZ over D-Bus, and CoreBluetooth on macOS
(scanning only: macOS does not let apps advertise manufacturer data).
Computers run no GATT server: they cannot receive waves.

- **Advertisement**: BLE manufacturer data, company id `0xFFFF`, bytes
  `"ZN"` (`0x5A 0x4E`) + a 16-byte **token** + a 4-byte **hint**, new every
  10-minute slot (advertising, and so the Bluetooth address, restarts with
  each token). The token is the slot's value of a one-way hash chain
  (`c_i = SHA-256("znc" | c_{i+1})[:16]`, 4320 slots = 30 days per chain)
  XOR a mask `HMAC-SHA256(maskKey, "zen-nearby-mask|" + slot)[0..16]`; the hint
  is `HMAC-SHA256(maskKey, "zen-nearby-hint|" + slot)[0..4]`. A friend has the
  mask key and the chain's anchor (`nearby_key`, 2.2): it unmasks the token
  and hashes it forward to the anchor, but cannot make the token of a slot
  not yet shown, so it cannot show "this person is here" to others. A
  stranger sees random bytes that change every slot. The locked Android
  service shows tokens worked out in advance (the nearby kit, 8 days) and
  never holds the private key.
- **Same network**: the same advertisement (token + hint) rides on the LAN
  beacons (1.6) while the Wi-Fi discovery setting is on: from the app while
  it is unlocked, and from the nearby kit's tokens in the locked Android
  service (which has no devices to link with, so it only answers phones
  that look around). The app hands the bridge the adverts of the
  coming slots (a day) and the bridge shows the one of the current slot, so
  a token never stays past its slot (`lan_nearby.go`). Adverts heard there
  are kept only while the app looks around ("Nearby" open, or a short look
  in the background), for at most 2 minutes. Nobody is written to over the
  network (no hello, no alarm wave). The sender's IP address does not change
  with the token, so others on that network can tell that the successive
  pseudonyms are one device while it stays there (never who it is).
- **GATT server**: service `5a454e00-6e65-6172-6279-000000000001`, one
  writable characteristic `5a454e00-6e65-6172-6279-000000000002` ("wave"),
  no pairing. Writes up to 600 bytes (long writes are assembled). A phone may
  send at most 6 waves per minute and the radio accepts 40 per minute; signed
  alarm waves from friends have a separate budget of 60 and are admitted once
  per minute per wave.
- **Wave** = UTF-8 JSON, field `v` selects the kind:
  - `v: 6` alarm wave: `{v:6, id, at, end?, t?, m?}`; `t` = the pair's id at
    `at` (`HMAC-SHA256(pairKey, "zen-nearby-pair-id|" + slot)[0..16]`, hex),
    `m` = `HMAC-SHA256(pairKey, "zen-nearby-alarm|6|" + id + "|" +
    at + "|" + (end?1:0) + "|" + t)[0..16]` (hex). Accepted only if `at` is
    within +/-10 minutes and the MAC verifies for a friend's pair key; an
    unsigned (told to everyone) or unverified wave is only shown as a quiet
    note. Other versions are not read.
  - other `v`: handed to registered handlers (flat invitations, crisis
    announcements) [?] formats.

### 2.13 Frame the app ignores [V]

Unknown `type`, or a type the parser does not map, yields no signal
(`zenSignalFromTransportPayload` returns `null`; relay engine returns `false`).

### 2.13a Recovery circle and account moves [P]

- `rc_help` (`recovery_service.dart`): a recovering device tells a person of
  the circle (whose invitation code it was given) that it asks for help. A
  device holding a piece of that account's key stores the request (at most
  8, 30 days, once per sender) and shows a notification
  and a card with *Help* (the new device's address filled in) and
  *Decline*. A device holding no piece ignores it.
- `al_ver {v: [...], app}` (`account_link.dart`): the answer to a device-link
  hello of another protocol version; both sides show "the other device has
  another version of Zen". Moving an account: the transfer code carries
  `app`; a hello of another version is answered `acx_no {why: "version",
  app}`.

### 2.14 Circle copy (`cbk_*`) [V]

`circle_backup_service.dart`, `circle_backup_holder.dart`. Between the
owner's devices and the people of its recovery circle, over the signal
transport:

| type | Direction | Fields |
|---|---|---|
| `cbk_offer` | owner -> holder | `m`: a new manifest |
| `cbk_need` | holder -> owner | `a` account, `mid` manifest id, `ids` chunks it lacks |
| `cbk_chunk` | owner -> holder | `a`, `id`, `c` (one chunk) |
| `cbk_ok` | holder -> owner | `a`, `at`: the copy is complete |
| `cbk_no` | holder -> owner | `a`, `why`: refused |
| `cbk_fetch` | recovered device -> holders | `r`: a signed, fresh request |
| `cbk_manifest` | holder -> recovered device | `m`: the copy kept |
| `cbk_get` | recovered device -> holder | `r`, `ids` |
| `cbk_part` | holder -> recovered device | `a`, `id`, `c` |

Every section, and every month of every conversation, is cut into chunks of
at most 192 KB, sealed with ChaCha20-Poly1305 under a key from HKDF of the
account's self key, with a nonce derived from the content (an unchanged
chunk keeps its hash and is not sent again). An encrypted index names the
chunks; the manifest is hybrid-signed by the device, whose certificate the
account key signed. A holder takes copies only of accounts whose recovery
key it holds, 10 MB (+10 %) per account and 100 MB in all, and answers
`cbk_fetch` only for a device the account certified.

### 2.15 Network census (`census`) [V]

`census` {`e` month (months since January 2024), `c` sketch of that month,
`p` sketch of the month before (optional)}, friends only, not reliable, at
most once an hour per friend and only when the sketch changed (sent when a
friend shows up: `ping`, `pong`, `lg_hello`); a friend's sketch is taken at
most every 30 minutes (`network_census.dart`). A sketch is a HyperLogLog of
2048 registers (6 bits each, base64url, 2048 characters, ~2.3% error).
Each account adds one identifier a month: `HMAC-SHA256(censusKey,
"zen.census.v1|" + month)`, `censusKey = HMAC-SHA256(selfKey,
"zen.census.key.v1")`; the self key is held by the account's own devices
only, so the identifier is the same on all of them, unlinkable between
months and unknown to anyone else. Register = top 11 bits of SHA-256 of the
identifier, value = leading zeros of the next 53 bits + 1 (at most 40).
Every source (this account, each friend) is kept apart; with three or more
sources each register is the second-largest value among them (one forged
sketch cannot raise it), with fewer the maximum. The number shown is the
larger estimate of the current and the previous month. Limits: two
colluding friends, or a friend of a phone with a single other friend, can
still inflate it; it is a rough guide only.

## 3. Layers above the frames

### 3.1 Reliable delivery (`relay_engine.dart`, `reliable_signal_transport.dart`) [V]

- A payload whose `type` is in `kReliablePayloadTypes` (messages and receipts,
  friend lifecycle, groups, profile, meeting features, intro, pyramid, dating
  and neighbours - see the set in the file) gets `_rid` (<=128 chars) and is
  sent directly; the recipient replies `rly_ack {rid}` and de-duplicates by
  `sender|_rid` for 14 days. Types that must go direct only
  (`_directOnlyPayloadTypes`: `friend_request`, `flat_*`) are never mailboxed.
  `_once: true` marks a payload to send once, not queued.
- The payload is written to disk before the first direct attempt. Direct
  retry schedule: 3 s, 10 s, 30 s, 2 min, 10 min, 30 min, 1 h, 2 h, 4 h, then
  every 4 h; any sign of life of the recipient, and a restart or 10 minutes
  of silence, start over. TTL 14 days (`messageTtl`).
- Reactions, edits and deletions (`msg_react`, `msg_edit`, `msg_delete`),
  group board posts (`group_post`), `lg_push`, `lg_mention`, `date_key` and
  `date_intro*` are reliable too.
- Calls, typing, presence and file chunks are not reliable.

### 3.2 Mailboxes (store and forward) [V]

If a direct send is not acknowledged within 4 s, the payload is **sealed for
the recipient** and deposited with up to 6 friends the recipient chose as
relays.

- `rly_announce` {`pk` (X25519 public key, base64url), `pq` (hybrid
  ML-KEM-768 + X25519 public key, 1216 bytes, base64url), `relays` (<=6
  addresses), `v` (monotonic version), `tk` (deposit token), `dk` (deposit key,
  only to the recipient's relays), `dc` (what kind of device it is:
  `pc` a computer with Zen in the tray, `android` an Android phone with the
  background service, `ios_on` an iPhone with "keep receiving in the
  background" on, `ios` an iPhone without it; absent when unknown)} ->
  `rly_announce_ack {v}`. A change of kind (the iPhone keep-alive switched)
  bumps `v` and is announced like a new relay set; there is no periodic
  traffic of its own. Only accepted from friends, at any device of their
  account, and from group members when sharing is on.
- **How mailboxes answer** (`RelayReach`, per device, never per friend): a
  device counts the asks that want an answer (its own polls of its mailboxes,
  deposits with friends' mailboxes for others) and whether anything at all
  came back from that device. Counted by the hour: an hour in which a device
  was asked is one sample, answered if anything came from it in that hour.
  Samples fade with a half-life of 3 days (`reachHalfLife`). Periodic polls
  carry `p: true`; a mailbox with nothing to hand over answers them with
  `rly_here {}` (the locked Android service too), polls sent on a sign of
  life carry no `p` and get no answer. Kept only for friends' devices.
- **Mailbox quality** of a device: (answered hours + 24 x prior) / (hours +
  24), where the prior comes from `dc`: computer 0.9, Android 0.8, iPhone
  with keep-alive 0.45, iPhone 0.15, unknown 0.35 (`RelayDeviceClass`).
- **Choosing relays** (`RelayEngine.rankRelays`), best first: a device that
  has not gone quiet; not a weak acquaintance; higher quality (in steps of
  0.1); close friends before friends; the most recently seen. One device per
  friend: the best of a friend's devices (their computer rather than their
  iPhone, the phone they moved to). Empty places (a mailbox stopped being a
  friend) are filled at once. Otherwise at most one mailbox is replaced per
  `mailboxChangeSpacing` (1 day) and never several at once:
  - a mailbox has **gone quiet** when it was not heard from for
    `staleRelayAfter` (3 days) while this device kept asking it in vain for
    at least `quietObservedFor` (12 h; a device that was offline itself does
    not make its mailboxes quiet). A device never asked is quiet when it was
    not seen for 3 days (the friend's own presence counts only when the
    device is their only one). A quiet mailbox is replaced by the best
    device that is not quiet if its quality is at least 0.3
    (`kMinMailboxQuality`; an iPhone nobody has seen answer is not);
  - a mailbox that answers now is replaced by a device at least 0.35 better
    (`kMailboxQualityGap`; an iPhone by a computer or an Android phone, a
    phone that is mostly off by one that is mostly on), never by a weak
    acquaintance.
- **Quiet mailboxes the person must replace** (`RelayOverview.quiet`): a quiet
  mailbox with no device good enough to take its place, or any quiet
  mailbox while the mailboxes are chosen by hand. The app shows a card on the
  chats list and, once per quiet spell, a notification entry ("Skrzynka
  {name} nie odpowiada od {time} — wybierz inną", route `zen://mailboxes`)
  that opens the picker. The picker shows each friend's device kind and the
  share of time it answered, and warns about an iPhone without the
  keep-alive.
- **Hand-picked mailboxes** name friends, not devices: each is served by one
  of the friend's devices (the one serving already unless it went quiet).
  The choice is the same on all the account's devices (account state domain
  `relay`: `{auto, manual}`); an automatic choice is each device's own.
- **Outbox:** a queued payload of 4 KB or more is stored in its own file
  (`relay/out/<id>`, written once before the state, removed with the item);
  the queue holds at most 32 MB of payloads (`kRelayOutboxMaxBytes`), beyond
  which a new message is refused as not sent; small frames always pass.
- `rly_deposit` {`env`: envelope, `tk`?} -> `rly_deposit_ack {id, r}`.
  **Envelope**: `{id, s (sender), r (recipient), c (created ms), x (expires
  ms), q (hybrid KEM ciphertext, 1120 bytes), n (12-byte nonce), b
  (ciphertext+tag)}`, all base64url; sealing in section 4 ("Mailboxes").
- `rly_poll {p?}` (recipient asks a relay) -> `rly_mail {items:[envelope...]}`
  (batches up to ~6 KB), or `rly_here {}` when nothing is held and `p` was
  set. Recipient answers `rly_mail_ack {ids}`; it also tells other relays
  with `rly_purge {ids}`.
- **Accounts with several devices** (a second phone, a computer, the phone
  an account moved to). Every device has its own mailbox key, its own
  mailboxes and its own announcement, and mail is sealed for one device: a
  mailbox hands each device only its own envelopes, so a lost or replaced
  phone's key opens nothing for the others. The account routing sends what
  the app sends to a friend to every device of the friend's account, so a
  sender queues one copy per device and deposits each with that device's
  mailboxes; each device collects and confirms its own copy, and the app
  takes the friend's other devices' frames as the friend's. Delivery is
  tracked per person (`RelayTrackedMessage`): a message is delivered to a
  friend once any of their devices confirms it (the copies for their other
  devices still go), and fails only when it expired for every device of
  theirs; group counts ("d of n") count people. A friend's other devices are
  accepted as friends for announcements, deposits and as mailboxes (they
  come from the ledger, `AccountDeviceDirectory`); an unlinked device is
  none of these, and the account's other devices stand in for it, also when
  it is the address the app knows the friend by. When a friend moves to a new
  phone, the new phone announces its own mailboxes to the friends, who
  deposit there from then on; the old phone, once quiet for 3 days, stops
  being anyone's mailbox and the friend's new phone takes its place.
- `rly_sync {r, ids, t (tombstones), all}` and `rly_sync_want {r, ids}` keep
  co-relays in step.
- Limits: payloads up to 48 KB, 300 messages / 100 per sender / 2 MB per
  recipient, unvouched strangers 30 messages / 256 KiB per recipient and 10 per
  /64, clock skew 1 day, 5000 seen and 5000 tombstones. Polls every 5 min,
  relay sync every 10 min.
- **A locked Android phone stays a mailbox.** Once Zen locks (or after 5
  minutes in the background) the background service runs the node without
  the master key. From a mailbox kit the app leaves it (whom the phone
  serves with their relays and deposit keys, the mail held, tombstones;
  sealed with the background key) it goes on answering `rly_deposit`,
  `rly_poll`, `rly_mail_ack`, `rly_purge`, `rly_sync` and `rly_sync_want`
  by the same rules, and writes what it holds back to a file of its own,
  which the app merges after unlock (`relay_engine_locked.dart`).
  Attachments (`rly_bput`...) wait for the unlock. A locked iPhone runs the
  same receiver whenever iOS lets Zen run (a background check, a Shortcuts
  run, the keep-alive; docs/IOS_BACKGROUND.md), so it answers the same
  frames then.
- **What a locked phone reads.** It keeps every frame sealed to the inbox
  key (hybrid ML-KEM-768 + X25519, derived from the master key; only its
  public half is with the receiver) and reads a chat message only in
  memory, for a notification of at most 80 characters as the conversation's
  notification level allows (docs/SECURITY_MODEL.md, "The locked phone").
- **Mail for a locked phone** (`rly_mail` to the locked service) is kept
  envelope by envelope, keyed like the direct payload (`sender|id`): a copy
  that came already, directly or from another mailbox, or that the app
  took before it locked (tags in the mailbox kit), is not kept or announced
  again. The service answers `rly_mail_ack {ids}` once the envelopes are on
  the disk (and `rly_ack` for envelopes handed over by their own sender's
  locked outbox), so they are not handed over again at every poll.
- A deposit is accepted only from the claimed sender or from a co-relay. A
  deposit token (`HMAC-SHA256(depositKey, "zen.relay.deposit-token.v1|recipient|sender")`
  truncated to 16 bytes, where `depositKey = HMAC-SHA256(identityPrivate,
  "zen.relay.deposit-key.v1")`) proves the sender is someone the recipient
  announced to.
- **Parts** (`zpart`): a payload too large for one envelope (up to about
  1.5 MB of JSON, e.g. a photo inside a message) is cut into at most 64
  parts `{p: rid of the whole, i, n, h: SHA-256 of its JSON, x: expiry, d:
  piece}` of about 30 KB, deposited with at most 3 of the recipient's
  mailboxes (the same for every part); the recipient joins them, checks `h`
  and takes the whole as if sent directly. Parts are only deposited, never
  sent directly. A mailbox keeps up to 4 MB per recipient.
- **[?] Not described in full:** large attachments for mailboxes use the
  `rly_bput`, `rly_bput_ack`, `rly_bput_no`, `rly_bget`, `rly_bchunk`,
  `rly_bdone`, `rly_bdrop`, `rly_bnone` frames; `relay_crypto.dart` also contains
  `RelayBlobCipher` (chunk sealing of large attachments for mailboxes, AAD
  `zen.relay.blob.v1|blobId|sender|recipient|index|count`, nonce = chunk index).
  Its frames are not in this document; check `relay_engine.dart` and the
  CHANGELOG.

### 3.3 Ledger (`lib/src/core/ledger`, `ledger_node.dart`) [V]

A signed, append-only, per-device **log** for each **space**.

**Entry** (`LogEntry`, JSON):

```
{ "v":1, "space":"feed/<account>", "writer":"<32 hex>", "seq":1,
  "prev":"<64 hex or empty for seq 1>", "hlc":<int>, "kind":"post",
  "body":{...}, "blobs":["<64 hex>",...], "account":"<b64url ed25519>",
  "device":"<b64url ed25519>", "sig":"<hybrid>" }
```

- `id = sha256hex(canonicalJson(unsigned entry))`; `prev` is the `id` of the
  previous entry of the same log, so the log is a hash chain. Two different
  entries with the same `seq` prove a fork.
- **Canonical JSON**: object keys sorted, no whitespace, integers only
  (floating point is refused), text via standard JSON string escaping.
- `sig` = the entry's only signature: hybrid (4.1) by the **device key** over
  the canonical unsigned bytes (the chain link `prev` included), naming
  exactly the ML-DSA key the device's certificate publishes. About 4.5 KB
  of JSON (a like: 382 B of content + 4549 B; it was 14448 B with the
  certificate inside).
- **Checkpoint:** an entry of kind `checkpoint` (empty body) marks a point
  a writer's log may start from. A receiver accepts a log that starts at a
  checkpoint, moves to the checkpoint when it asked for entries from its own
  head and the sender answered from a checkpoint (never for entries pushed
  unasked), and treats entries before its start as duplicates, not a fork.
  A holder may prune a log (`pruneBefore`), only at a checkpoint. When
  checkpoints are written and when other accounts' logs are pruned is not
  decided yet; 1.12.0 can read both.
- **Device certificate** (the device record) =
  `{t:"dev_cert", account, device, dpk, name (<=60), issued, sig}`: `dpk` is the
  device key's ML-DSA public key (base64url, 1952 bytes), `sig` the **account
  key**'s keyed hybrid signature (it carries the account's ML-DSA key), so a
  certificate checks out on its own; about 9.9 KB. It is **not** part of an
  entry: a store keeps the certificates of the devices whose entries it holds
  (`ledger/certs-<hash>`, one file per account, written only when that
  account's certificates change) and checks every entry of a
  device with its certificate. An entry whose certificate is unknown waits,
  unchecked and outside its log (at most 1024 in all), and the receiver asks
  the peer that sent it (`lg_cert_want`, again in the next sync with that
  peer); it is never taken before the certificate has come and checks out.
  Certificates also come in `lg_hello`. An entry passed on outside the ledger
  (a reshare, a passed-on tombstone, a pyramid report, a post on order, a
  follow notice of another device) carries its certificate as `cert`.
- A `DeviceRevocation` = `{t:"dev_revoke", account, device,
  cutoffs:{"writer@space": lastValidSeq}, issued, sig}` (keyed hybrid, account
  key: it reaches phones that never met the account) cuts a stolen device off
  (later entries are refused). An Ed25519-only signature makes an entry,
  certificate or revocation malformed; so does a certificate or revocation
  signature that does not carry its key.
- `hlc` = hybrid logical clock `(millis << 16) | counter`; entries more than 10
  minutes ahead of the receiver's clock are refused.
- Size: whole entry <= 64 KiB; `space` <= 200 chars; `kind` <= 40; <= 32 blobs.
  Media never goes inside an entry; it is named by blob hash.
- **Spaces** (owner-only write, `AccountSpacePolicy`): `feed/<acct>`,
  `acts/<acct>`, `private/<acct>`, `profile/<acct>`, `own/<acct>`; and `power`
  (closed, nobody may write yet). A space of a kind this build does not know
  (`<kind>/<account>`, written by a newer Zen) is kept for the owner and
  handed on, within bounds (`UnknownAccountSpacePolicy`: 1000 entries per
  device log, 8 logs, 4 MB per space, 8 MB per owner, 64 MB and 256 spaces
  in all); it is served by no rules of its own. Public spaces that
  anyone may read: `feed`, `profile`; `private` and `own` are sealed to the
  account's own devices.
- **Kinds seen** [P]: `post`, `post_edit`, `post_del`, `reshare`, `comment`,
  `like`, `rx`, `thanks`, `gallery`, `gallery_del`, `profile`, `device`,
  `contacts`, `contact_removed`, `chat`, `chat_history`; for the Videos
  section `film` (in `feed`, removed by `post_del`), and in `acts`
  `film_react` (the latest per film wins), `film_seen` (`posts`: film ids the
  author counts) and `film_pass` (a public film passed on to friends of
  friends: the signed film with its certificate, like a reshare); in
  `acts` also `post_ann` (notices of posts passed on beyond friends, below).
- **Post reach** [P]: a public post (`aud` `public`, not sealed) may be
  passed on up to 3 steps of friendship from its author; the post carries no
  reach of its own, and any other audience never goes past friends. Each
  reader picks how far it looks (1, 2 or 3 steps, 2 by default, kept on the
  device) and fetches only posts that near. A friend of the author writes a
  `post_ann` entry whose body {`items`: [{`p` post id, `a` author account,
  `t` post time, `h` steps from the author of the entry's readers (2 or 3),
  `aa`? author address from their public profile, `e`? newest edit time,
  `x`? 1 when removed}]} is sealed (Audience encryption, below) for the
  audience that matches the writer's friend-list setting: everyone → `all`,
  friends at level "Znajomy" and up → `mid`, close friends → `close`; with
  the list shown on request only or to nobody no `post_ann` is written
  (<= 100 items; each post once per audience, again when `e`/`x` change; <=
  10 posts per author and 300 items per day). A reader fetches the post with
  `lg_post_want` {`id`, `a`} from the friends who passed it on or from the
  author, and gets `lg_post` {`id`, `a`, `entry`?, `edit`?, `del`?, `prof`?}
  (each part a signed entry with its certificate; `del` the author's
  tombstone instead of the post). The post is taken only if asked for,
  signed by `a` and public. A reader two steps away that looks at least two
  steps far passes it on (as `h` 3) once it holds the post; nothing goes
  past `h` 3. Friends are served any held public post held fewer than 3
  steps from its author; anyone else only the asked device's own public
  posts (10 asks a minute per address, 200 in all). Notices only about
  posts from the last 30 days.
- **Audience encryption**: bodies for non-public audiences are
  `{aud, kid, n, c}` sealed with ChaCha20-Poly1305 under a 32-byte audience key,
  AAD `"<account>|<kid>"`; keys are handed to friends in `lg_keys` according to
  friend level (weak: `all`; friend: `all`+`mid`; close: all). Private bodies use
  the account's *self key* (`kid="self"`).
- **Blobs**: content-addressed; chunks of 256 KiB, each named by its sha256;
  manifest `{size, mime, chunk:262144, chunks:[hash...]}`, id = hash of the
  manifest.

**Replication** ("compare heads, send the difference"):

| type | Fields |
|---|---|
| `lg_heads` | `spaces`: {space: heads (per writer: last seq/id)} - sent for spaces the receiver may be served. |
| `lg_want` | `space`, `from` (what the sender lacks) |
| `lg_entries` | `entries`: list of entries (<=100 per message, <=256 KiB) |
| `lg_revoke` | `items`: revocations (<= 64 and <= 1 MB per message; taken only for accounts the receiver knows; each with <= 1024 cutoffs) |
| `lg_cert_want` | `items`: [{`a` account, `d` device}] (<=32) whose certificates the sender lacks for entries it got |
| `lg_certs` | `items`: device certificates (<=32): taken only for devices whose entries wait at the receiver; served only for devices whose logs the asker may read; `rev`: revocations of those devices (<= 1 MB), taken before the waiting entries |
| `lg_blob_want` | `id`, `chunks`: list (empty = ask the manifest; <=64 hashes served per message) |
| `lg_blob_manifest` | `id`, `manifest` |
| `lg_blob_chunk` | `h` (chunk hash), `d` (base64) |

Rate limit 3000 messages/min; frames from non-friends are limited to 30/min per
/64 (`kStrangerFramesPerMinute`). Every received entry is checked (structure,
signature, certificate, space policy, revocation, clock) and every blob chunk
against its hash; friends may push, strangers only answer what we asked.

**Account and device frames** (`ledger_node.dart`): `lg_hello` {`cert`, `p`:
{`f` address, `k` device key fingerprint, `s` device signature over
`"zen.hello.v2|" + f + "|" + k`}} introduces an account's device to a friend.
A hello names the certificate (`cd`: {`a` account, `d` device}) only to an
address whose last proven hello said it holds it (`kc`: the device id it
holds for that address); everyone else gets it whole. A stranger's hello
without the whole certificate is dropped unanswered. `nc: 1` asks a friend
for the whole one (at most once a minute); whole hellos sent on request: at
most 3 a minute per address. The proof is signed
once per address and session key. The periodic round (every 10 minutes)
greets only who was heard from in the last 30 minutes, and everyone once an
hour.
The proof binds the address to the post-quantum device key of the session
that carried the hello: a hello whose `k` is not the frame's `senderKey` is
refused, the signed key is pinned (replacing the session's) when the hello
is of the account known at that address, and the chat with that friend
shows "The device key doesn't match." Device records (`device` in
`acts`: {`address`, `name`, `pq`}) name the key too, and friend lists
(`friend_list` items {`a`, `n`, `k`}) carry the keys friends proved, so
friends' other devices and friends of friends are pinned before the first
direct contact (1.5); `lg_keys` {`items`} gives audience
keys; `lg_sibling` {`own`, `levels`} syncs the account's own devices;
`lg_bridges` {`items`: signed bridge announcements} passes known mesh bridges;
`lg_reach` {`id`, `uri`} / `lg_reach_ok` {`id`, `ok`} ask a friend to test that a
computer's address can be reached from outside (4 checks/min).

### 3.4 Pyramid records (`pyramid_record.dart`, `pyramid_service.dart`) [P]

Every change of the pyramid is one **signed record**; the state is the fold
of the records. There is one pyramid: its genesis record is pinned in the app
(`pyramid_root.dart`; its id is the pyramid id), and phones keep and pass on
only records with that `body.py`.

```
record = { "b": body, "s": {signerKey: signature}, "r": ringSignature?, "ts": {treasurerKey: signature}? }
```

- **Rules version:** `body.rv` is the version of the pyramid rules a record
  follows (absent = 1, `kPyramidRulesVersion`). From a record (the genesis
  included) whose `rv` is higher than the build knows, nothing is applied,
  the pyramid's time stops (`PyramidState.rulesTooNew`), the build signs
  nothing and asks the user to update. A future version must write `rv` in
  the record that switches rules and in every later one. `body.wk == true`
  marks a record whose signatures are keyed (for future kinds).
- `body` is canonical JSON (same rules as the ledger); the record `id` is the
  sha256 of the canonical body; signatures (`s`, `ts`) are hybrid (4.1) over
  the canonical body (`ts`: over `"zen-treasurer|" + id`). Signatures on
  `genesis`, `found`, `admit` and `hand` (which introduce keys) and on records
  read outside the pyramid (`natpost`, `alarm`, `post` at level 0) are keyed
  (they carry the ML-DSA key); all others name the key, which a phone keeping
  the pyramid has from those records (it files the keys of the records it
  keeps, also when it reads them back from disk). A record whose signature
  names a key not known yet waits (at most 500) and is checked once the
  record publishing the key has come; a batch is taken key-introducing
  records first. Limits: <= 2 MiB, <= 100 signatures, JSON depth <= 24, no
  fractions, no lone surrogates. `body.t` = kind, `body.py` = pyramid id, `body.at` = time (ms;
  a record dated more than 10 minutes ahead waits).
- Kinds (`PyrT`): `genesis`, `found`, `hand`, `admit`, `swap`, `vreq`, `vote`,
  `roster`, `ballot`, `leave`, `fill`, `absent`, `remove`, `migrate`,
  `alive`, `addr`, `deleg`,
  `revoke`, `ban`, `unban`, `decision`, `post`, `comment`, `natpost`,
  `natgrant`, `natpin`, `badge`, `known`, `ref`, `tally`, `const`, `emit`,
  `emitrule`, `emitcancel`, `veto`, `kemkey`, `suit`, `verdict`, `appeal`,
  `appans`, `alarm`, `offer`; `xfer` and `settle` exist as kinds but the
  fold refuses them: transfers are private (2.11). The genesis names the power key
  (`pk`) and the fingerprint of its ML-DSA half (`pq`; the original pyramid's
  must, the test pyramid's has none) and is signed by it; `found` (power key +
  founder) seats the first head; `hand` passes the power key to the head at
  the top (signed by the old key, or 72 h after that head took the top by most
  of the top cell, plus the new key and the head) and names the new key's
  fingerprint (`tpq`). `admit` carries the sponsor (`sp`), the place
  (`slot`) in the sponsor's branch and the head of that cell (`head`), signed
  by all three. Member data (`m` in `found` / `admit`) carries the member's
  key `k` and its fingerprint `pq`. The fold refuses a record when a
  signature of a member or of the power key carries another ML-DSA key than
  the records fixed for it (`pq`, `tpq`), so the power-key chain and every
  member key are anchored back to the pinned genesis. Cell votes run on
  one-time hybrid keys ("cards"): each member's phone sends its card to the
  other members of the cell only (`pyr_card`, through a friend outside the
  cell; `s` = the scope, `cell` for request cards), with a linkable ring
  signature (LSAG over Ed25519, `ring_signature.dart`) bound to the scope,
  so cellmates see one card per member but not whose; classical (4.1).
  `ballot` lists a vote's cards (`toks`, sorted hybrid ids) and is signed by
  the members (hybrid) — each signs only all cards it heard of, holding its
  own; it counts with at least as many signers as cards. `roster` does the
  same for a cell's request cards (`cell`, `head`, `by` = the voters now;
  scope `roster:` + SHA-256(pyramid|cell|head|voters)[:32]); its cards are
  made when a member first asks, it is signed once all cards are in or,
  after 12 h, with at least two, and a later one for the same head and
  voters counts only with more cards, holding every earlier one. `vreq`
  (asking for a cell vote) is signed by one request card (keyed form, `by` =
  the card) while the cell's head and voters are those of its roster, and
  counted per card; a `vote` is signed by one ballot card and counts once
  per card. Neither names a member; both are published through a friend
  outside the cell.
  `kemkey` publishes a member's hybrid KEM key (from the pyramid key's
  seed, so it survives recovery) that private payments and statements are
  sealed to. `emitrule` changes the emission limit or the daily transfer
  limit (lower at once; higher announced and in force after 30 days unless
  an `emitcancel` comes first). `suit` / `verdict` are the court; `appeal` /
  `appans` go one level above whoever decided, each level twice as long.
- Frames: `pyr_hello` (pyramids kept and fingerprints), `pyr_ids` (ids of a
  differing bucket), `pyr_want`, `pyr_rec` (one new record, passed on),
  `pyr_recs` (bulk), `pyr_prop` / `pyr_sig` (co-signing), `pyr_vote`,
  `pyr_card` (voting cards), `pyr_priv` (private money, 2.11),
  `pyr_report`, `pyr_anon` (an
  anonymous record published on someone's behalf), `pyr_dm` (access-market
  message), `pyr_sum` (anonymous branch sums), `pyr_nat` (national-section
  posts and the top's posts for friends outside; a frame with the top's posts
  carries the power key's line `hc` — `found` and the handovers — and a
  reader outside keeps a level-0 post only from the head that line, checked
  from the pinned genesis, names for its time), `pyr_who` / `pyr_here` (whose
  pyramid key is at this address: the device answers with the nonce signed
  by its key; points are paid to an address only after that answer).
  Records whose time starts a wait (`const`, `emit`) that a phone sees dated
  over 30 min before records it already had count their wait and the 30-day
  emission limit from when that phone saw them. Fields of each [?]: see the
  `PyramidTypes` handlers.
- **Joining and voting.** A member brings somebody to a free place in their
  own branch with a referral (a sponsored `admit`: the sponsor `sp`, the
  place `slot` and the head of that cell `head` sign it, 3.4). A new member
  votes in the cell and in referenda `kPyrVoteAfterMs` (14 days) after
  admission, or from the moment a member of their cell signs `known` ("we
  know each other"). Age is not a condition; the admitting member signs the
  member's birth year.
- **Referenda and rules.** A `ref` (referendum on any question, 2 to 6
  options, at least 2 minutes) is asked only by the top (2 of 3) and only
  advises the top; the count is a `tally` per branch. The rules in numbers
  (`PyrParams`) change only by a `const` record signed by the top (2 of 3);
  it applies 24 h after the record (`kPyrParamsDelayMs`) and never past the
  hard limits written in the fold.
- **Cell chats.** The group chat of a cell is not a frame type of its own:
  every member works out the same group id (`pyrcell-` + the first 24 hex
  characters of `SHA-256(pyramid id | cell place)`) and the same member list
  from the records, and the ordinary group frames (2.4) carry the messages.
- **Pyramid posts outside the pyramid.** `post` at level 0 (the top) and
  `natpost` are readable by friends of members through `pyr_nat`; the
  Feed filters them as "Pyramid" and "Country" in the app only.

## 4. Cryptography summary

| Purpose | Construction | Where |
|---|---|---|
| Mesh transport | Yggdrasil: Ed25519 node identity, X25519 NaCl-box sessions, TLS/link keys per hop (all classical) | bridge (`bridge_types.go` audit comment) |
| Signals (post-quantum) | X-Wing (ML-KEM-768 + X25519) via HPKE per one-way session, ChaCha20-Poly1305 per frame, Ed25519-signed key records bound to the address (1.5) | `pq_session.go`, `pq_kem.go` |
| Data at rest | master key; password key by **Argon2id** (parameters stored as `{a:"argon2id", m, t, p}`); **AES-256-GCM** (`nonce|ciphertext|tag`, AAD binds the storage key); sub-keys `HMAC-SHA256(master, "zen.subkey.<purpose>" + 0x01)`; verifier `sha256("zen.security.verify" + key)` | `app_security_crypto.dart`, `app_security_service.dart` |
| Mailboxes | X-Wing encapsulation `(c, K)` to the recipient's `pq` key (info `zen.relay.kem.v2`; reused by the sender for up to 1000 envelopes / 24 h) + static sender key, `HKDF-SHA256(K || DH(S,R), salt = c || nonce, info = "zen.relay.v2")`, ChaCha20-Poly1305, AAD `zen.relay.env|id|sender|recipient|created|expires`; plaintext is the JSON of the payload | `relay_crypto.dart` |
| Locked inbox (Android) | X-Wing to the inbox key derived from the master key, record key `HKDF-SHA256(K, salt = c, info = "zen.inbox.v2")`, AES-256-GCM; one encapsulation per 256 records / hour | `sealed_inbox.dart` |
| Signatures (post-quantum) | Hybrid Ed25519 + ML-DSA-65 (FIPS 204), both halves must hold, ML-DSA key derived from the same seed (4.1) | `internal/zensig`, `hybrid_signature*.dart` |
| Ledger entries | one hybrid device signature naming the device's ML-DSA key; the account-signed device certificate (kept apart, once per device) publishes it; SHA-256 ids; canonical JSON | `core/ledger` |
| Ledger audiences | ChaCha20-Poly1305, 32-byte keys, nonce 12 bytes random, AAD `account|kid` | `audience_keys.dart` |
| Nearby | masked hash-chain tokens (10-min slots) and alarm MAC (v6) with a per-friend pair key | `nearby_crypto.dart` |
| Local links (offline) | adverts: Bloom filters of HMAC tags; handshake: ephemeral X25519 and ML-KEM-768, selectors, HKDF, AES-256-GCM records; secrets from the two devices' X25519 keys, mixed with contributions exchanged over the session layer once paired (1.6) | `local_link*.go`, `runtime_lan_discovery.dart` |
| Locked Android service | background key (random, in the system key store, AES-256-GCM, AAD `zen.background.v1|<storage key>`) seals the kits (alarm, nearby, door, outbox, mailbox) and the node config; contacts kept as keyed tags; the inbox is sealed to the master key's public hybrid inbox key, so the service cannot read it | `background_keys.dart`, `locked_receiver.dart`, `sealed_inbox.dart` |
| Dating | `DatingBox`: two layers of the classical X25519 box (`zen.relay.v1`) with AAD `zen.date.v1` (inner by the sender's dating key, outer by a one-off key); profile answers are `DatingBox`es padded to 4096-byte buckets; "Yes" token `HMAC-SHA256(DH(me,them), "zen-date-like|" + sorted keys)`; every hop is inside the post-quantum session layer | `dating_crypto.dart` |
| Pyramid | hybrid record and treasurer signatures, ML-DSA keys fixed by the records; one-time hybrid cards for anonymous requests and votes; LSAG ring signatures (classical) only for card registration between cellmates | `pyramid_record.dart`, `pyramid_state.dart`, `ring_signature.dart` |
| Recovery | Shamir secret sharing of the key among the recovery circle (up to 6 friends) [?] details | `core/ledger/shamir.dart`, `account/recovery_service.dart` |
| Releases | hybrid maintainer signatures (maintainers pinned by hybrid id) and APK certificate check ("Pass it on") | `update/release.dart`, `apk_signature.dart` |

**Note on direct messages:** every signal between two devices (messages,
calls' signalling, ledger and pyramid frames, keys) is sealed by Zen's
post-quantum session layer (1.5) inside Yggdrasil's own encryption. Zen's other
seals (mailbox copies, locked inbox, ledger audiences, media keys, dating) apply
to what rests with or passes through other devices.

**Quantum computers.** Confidentiality is hybrid post-quantum wherever data
crosses the network or rests with others: signals (1.5), call media (2.5.1),
mailbox mail and its attachment keys, the locked inbox. Symmetric keys are
256-bit (AES-256-GCM, ChaCha20-Poly1305, HMAC-SHA256), which Grover's algorithm
only halves; the exception is call frames, which WebRTC's frame transformer
seals with AES-128-GCM (128-bit keys, about 64-bit strength against Grover).
Signatures are hybrid post-quantum too (Ed25519 + ML-DSA-65, 4.1), except
the ring signature that registers a card between cellmates and the
handshakes listed in 4.1; event tickets are HMAC-based. Nearby Bluetooth hellos carry a one-time
hybrid KEM key (in parts, one Bluetooth write each), the local link handshake
mixes in ML-KEM-768, every door runs the session layer (1.5) and sealed knocks
carry an inner layer keyed with the sticker's token or a hybrid key. Still
classical, and readable later with a quantum computer by someone who stored
them: dating boxes, PSI and "Yes" tokens (only the friends' phones a box
passes through see them).

### 4.1 Signatures: hybrid Ed25519 + ML-DSA-65

Records Zen keeps for years (ledger, pyramid, releases) must stay
unforgeable after a quantum computer breaks Ed25519. Every signature that is
kept or passed on is therefore **hybrid**: Ed25519 and ML-DSA-65 (FIPS 204)
over the same bytes, valid only when **both** halves verify, so it holds
while either scheme does. Go 1.26 implements ML-DSA but has no public
`crypto/mldsa` yet: the bridge carries a copy of Go's implementation
(`native/yggdrasil_bridge/internal/mldsa`, Go's BSD licence, checked against
the NIST ACVP vectors) and the scheme in `internal/zensig`. The app calls it
through FFI (`YggSigPublicKeyJson`, `YggSigSignJson`, `YggSigVerifyJson`,
`pq_sign_exports.go`) from a worker isolate of its own, never on the UI
thread; the maintainers' tools run `go run ./cmd/zensig`. There is no Dart
ML-DSA.

- **Keys.** A key is still the 32-byte seed the app keeps (account, device,
  pyramid identity, power, alarm, bridge, flat and resident, dating vouch,
  maintainer keys). Its Ed25519 half is the seed's RFC 8032 key, and its
  public key stays the key's id everywhere. The ML-DSA-65 half is
  `ML-DSA.KeyGen_internal(ξ)` with `ξ = HKDF-SHA256(ikm = seed, no salt,
  info = "zen.sig.mldsa65.v1", 32 bytes)`. Backups and recovery (paper
  backup, recovery circle) hold the seed only and restore both halves.
- **Fingerprint and hybrid id.** `F = SHA-256(ML-DSA public key)`
  (base64url, the key's `pq` id); the **hybrid id** is `<Ed25519 key>.<F>`
  (89 characters).
- **Signature** (3405 bytes, 4540 base64url characters):
  `Ed25519(T) (64) | F (32) | ML-DSA-65(T, context "zen.sig.v1") (3309)` with
  `T = "zen.sig.v1" 0x00 | Ed25519 key (32) | F (32) | SHA-512(message)
  (64)`. Both halves sign `T`, which names both keys, the Ed25519 key
  certifying the ML-DSA key and the other way round, so no half can be
  stripped or moved to another key. ML-DSA signs deterministically, as
  Ed25519 does. A 64-byte Ed25519-only signature is refused on every
  persistent record. In JSON a signature is base64url once; nothing encodes
  it twice (no binary format carries one).
- **Key records.** The signature names its ML-DSA key by `F`; the key itself
  (1952 bytes) is published once, in the record that introduces it, and the
  verifier is handed it or looks it up (`HybridKeyBook`: keys by `F`,
  content-addressed, so a key handed over by anyone can only be filed under
  its own hash): the device certificate (`dpk`, 3.3) for everything a device
  signs (entries, `lg_hello`, ask answers, introductions, alarm key
  certificates), the keyed signatures of the pyramid records that introduce
  keys (3.4). A signature whose key is not known is **never** taken: the
  ledger asks the sender for the certificate and keeps the entry aside
  unchecked; the pyramid keeps the record aside until the record that
  publishes the key has come; elsewhere it is refused.
- **Keyed form** (5325 bytes, 7100 characters): `Ed25519(T) (64) | ML-DSA
  public key (1952) | ML-DSA-65(T) (3309)`, the same two halves with the key
  instead of `F`, where no record of the key can be at hand yet: the record
  that introduces the key (device certificates' account signature, the
  pyramid's `genesis`, `found`, `admit`, `hand`), revocations (they reach
  phones that never met the account), whatever is read by people who may
  hold no record of the signer (pyramid `natpost`, `alarm` and level-0
  `post`, bridge announcements, neighbours' profiles, frames, votes and
  reveals, dating vouches, alarm frames resting in mailboxes) and releases,
  vetoes, the canary and `SHA256SUMS.sig` (phones pin a maintainer by `F`
  only). The FFI (`YggSigSignJson` `withKey`, `YggSigVerifyJson` `pqKey`)
  and `cmd/zensig` take both.
- **Which ML-DSA key is a person's.** A quantum attacker could forge the
  Ed25519 half and pair it with an ML-DSA key of its own. Where a record
  names a key, it names the fingerprint too and only that ML-DSA key counts:
  the device certificate (`dpk`), the release maintainers
  (`kReleaseMaintainers` holds hybrid ids), the alarm key certificate (`k`),
  the pyramid's genesis (`pq`), handovers (`tpq`) and member data (`pq`).
  Other keys (accounts, neighbours, bridge announcements, dating vouches)
  are pinned on first sight (`HybridKeyPins`): a later signature with another
  ML-DSA key for the same Ed25519 key is refused; the pins come back from the
  stored device certificates when the app starts. Limit: a key this phone
  meets for the first time after such a computer exists, with no record
  anchoring it, is only as strong as Ed25519.
- **Signed hybrid:** account and device records (certificates,
  revocations), every ledger entry (posts, profiles, met-in-person
  attestations, …), the `lg_hello` device proof, bridge announcements,
  every pyramid record and treasurer signature (genesis, founding,
  admissions, handovers of the power key, decisions, rules (`const`),
  tallies, payments and settlements of gates and the access market), alarm
  key certificates and alarm frames (copies rest in mailboxes), answers in
  "Ask the network" and introduction requests (they prove authorship beyond
  one hop), neighbours' flat profiles, frames, kick votes, key changes and
  reveals, dating vouches, releases, vetoes, the canary and `SHA256SUMS.sig`.
- **Classical on purpose:**
  - the linkable ring signature (LSAG over Ed25519) of the card
    registrations inside a cell (`pyr_card`): there is no standard
    post-quantum linkable ring signature. They travel only between
    cellmates inside the session layer; a cellmate with a quantum computer
    could tell whose card is whose or spoil a list (which then does not
    count). Requests (`vreq`), votes, rosters and ballots are hybrid;
  - event tickets and their live codes are HMACs with keys only the
    organizer's phone and the guest's phone hold (no signature at all);
  - Bluetooth adverts (hash chains and MACs); the pair secret of local
    links until the two devices first meet over the mesh (the device key
    as X25519: until then adverts can be recognised and a new link sat in
    the middle of by a quantum computer with both public keys; a recorded
    link stays shut, ML-KEM-768; afterwards the secret holds the
    contributions exchanged over the session layer, 1.6);
  - the Yggdrasil node key and the session layer's key record (1.5);
  - ordinary frames (messages, calls' signalling, acknowledgements) are not
    signed by Zen at all: they rely on the session layer's AEAD, keyed from
    ML-KEM, and on the mesh source address. Forging one needs a quantum
    computer at that moment, and a frame proves nothing later; whatever has
    to prove authorship to someone else, or later, is signed hybrid.
- **Cost.** On one desktop core (Go benchmark): signing about 1.2 ms,
  verifying about 0.2 ms (0.35 ms for a key not seen recently; the last 32
  parsed public keys are kept, about 70 KB each); several times that on a
  phone, in the worker isolate. A ledger entry carries one signature (about
  4.5 KB of JSON; a like was 14.8 KB with two keyed signatures and the
  certificate inside, now 4.9 KB), its device's certificate (about 9.9 KB)
  travels and is stored once per device; a pyramid record carries one per
  signer (4.5 KB, 7.1 KB keyed); `lg_hello` (certificate and proof, about
  15 KB the first time, about 5 KB later, at most every 10 minutes per
  friend) two: its proof ties an
  address to a device key, which a quantum attacker able to take over the
  address at the mesh level could otherwise claim. Small transport frames
  carry none. The floor is the ML-DSA-65 signature itself (3309 bytes).

## 5. Versioning and compatibility

There is **no global protocol version number** on the wire. Compatibility
comes from additive changes, tolerant parsing and explicit format versions.
From 1.12.0 on, older formats are kept readable (the rules are in
`lib/src/core/storage/format_version.dart`):

1. **Unknown `type` is ignored**, unknown JSON fields are ignored. New frame
   types and optional fields can be added without breaking old peers.
2. **Never reuse or change the meaning of an existing field or `type`.** Prefer a
   new field or type. Old peers keep working because they ignore it.
3. **Stored formats:** a reader reads every version from the oldest known
   to the current one and writes the current one. A new optional field needs
   no new version; stores that rewrite a document carry unknown fields over
   (`unknownFields` / `withCarriedFields`). A version **higher** than the
   current one means "written by a newer Zen": the data is left untouched
   (`NewerFormatException`; the file store holds the key and neither writes
   nor deletes it, nor falls back to a `.bak`), the app runs on defaults and
   asks to update (`ZenFormatGuard`). This covers the friend list, chats,
   the signal queue, transfers, settings and profile, the ledger identity
   and index, the pyramid log, recipient keys, the bridge book, the census,
   the update book, meetings, the relay state, `.zenbackup` files
   (`ZENACCT2…` or a manifest `v > 1`), the circle copy and the encrypted
   envelope (`ZENENC3…` is "newer", not "no data"). Documents without `v`
   (for example `meet/*`) change incompatibly only under a new key.
4. **Enums stored by index:** their order is pinned by a test, new values
   are only appended, and an index out of range reads as a fallback value
   (`enumAt`), never an error.
5. **Samples:** `test/fixtures/formats/1.12.0/` holds a sample of every
   stored and sent format as 1.12.0 wrote it (written once at the release,
   never changed); later builds must read them.
6. Where a format needs a version it has its own: ledger entry `v` (1; entries
   with a higher `v` are still stored and passed on; only this build's own checks
   apply), the pyramid rules version `rv` (3.4), dating lantern `v:5`,
   alarm wave `v:6`, BLE hello `v:7`, the door sticker `v` (3; a sticker with
   `v >= 3` and unknown fields is read, and its `mv` field names the oldest
   reader, so a newer version can make older ones ask to update), dating
   KDF/AAD labels `*.v1`, mailbox and inbox labels `*.v2`, the hybrid
   signature's `zen.sig.v1` and its ML-DSA derivation label
   `zen.sig.mldsa65.v1`, the session layer's `ZPQ1` and key record version 1, blob manifest
   `chunk` size, `profile_update.v` (monotonic counter), relay announcement
   version `v`, recipient keys `v: 1`.
7. **Changing the key exchange (KEM):** always keep opening `ZPQ1`; switch
   on a newer format only after both sides listed it in `caps`, which they
   exchange inside an already sealed session. The key record has a version:
   a future record with another version goes next to the old one, not in
   its place.
8. **Ledger checkpoints** (3.3) let logs start later than entry 1; 1.12.0
   already accepts them, so writing checkpoints and pruning can start later
   without breaking anyone. Note that `UnknownAccountSpacePolicy` counts the
   entry number: a log of an unknown kind that starts at a checkpoint past
   1000 is not passed on by 1.12.0.
9. The compression wire formats are all accepted: plain JSON, `ZSTD:` + base64,
   and the Dart `_zenEncoding` wrapper.
10. Two names for one frame: call end is `hangup` or `call_end`.
11. The app version is `kAppVersion` (equal to `pubspec.yaml`); friends
    exchange it, the build, a short list of capabilities (`caps`) and
    `minv`, the oldest version they still talk to (`kMinPeerVersion`), in
    ping and pong. `minv` is raised only when a change cannot stay
    compatible; a build older than a friend's `minv` (or than the
    `zen-min: X.Y.Z` line of the latest GitHub release, or the `min` field
    of a network release manifest) shows "update". Today that is only a
    message: a newer build decides by `caps` and `minv` what it sends to
    older ones. Nothing security-related depends on these claims.
12. Moving or linking an account between devices of different versions is
    refused with a clear message (`al_ver`, `acx_no`; 2.13a).
13. A release manifest skips bad or unknown file entries (up to 64) and
    needs one valid entry; its signature covers the list as received.

## 6. Security properties and known limits

- Source addresses are authenticated by the mesh and, above it, by the
  post-quantum session layer (1.5: challenges and pinned device keys bound
  to the hybrid identity by the `lg_hello` proof); the app additionally
  gates features by friendship (`ping` is not answered to strangers).
- A broken (Ed25519) node key lets an attacker take traffic for that
  address (denial of service) but neither read it nor speak for the
  address to anyone who pinned its device key; first contact with no pin
  and no vouching friend is trust on first use.
- Yggdrasil answers `debug_remoteGetPeers/Self/Tree` to any node (not
  configurable): the keys of a node's direct peers are public.
- Hostile input bounds: 2 MiB per signal, 64:1 inflate limit, fragment and inbox
  caps, per-/64 rate limits, JSON key and string caps in the parser, strict
  validation of ledger entries, pyramid records and blobs, media re-encoding.
- Not hidden: who talks to whom, when and how much, from mesh observers and
  from the other party; ledger entry metadata (author account, kind, time).
- Bluetooth waves are unauthenticated except alarm waves (MAC); a wave's mesh
  address is a claim.
- Local-link adverts and Bluetooth/Wi-Fi Direct records show that *a* Zen
  device with local links is nearby (and roughly how many devices it links
  with), not whose it is.

## 7. Open items for this document

- Field-level tables for events, ask, circle, table, plan, neighbours, dating
  inner payloads, pyramid frames, `lg_heads` head format and `lg_sibling`.
- Group-call media handshake and file transfer details.
- Field-level description of the mailbox blob frames.
- Check whether Dart or Go compresses first on the real send path (1.2).
