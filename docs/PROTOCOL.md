# Protocol specification

*A draft, from the code of Zen 1.11.0 and later. Written 20.10.2026 by reading the code, revised 21.10.2026, 22.10.2026 and 11.11.2026 (1.16.5). Not a standard; the code is the
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
  dials 4 at once, 1 while it only receives in the background (with two
  it can be the shortest way between them and carry strangers' transit;
  `link_check.go`: on every wake of the app's beat a path lookup for each
  peer's own key, so a link that died silently is ended by the core's 3 s
  peer timeout and replaced while the phone is awake), a TLS-only
  subset first, the rest of the encrypted list
  in reserve for the peers that stop answering, every TLS peer before the
  QUIC (a keepalive of its own every 20 s) and WebSocket ones, also in a
  list the user made; a node with one peer takes QUIC or WebSocket only once
  every TLS peer failed, and a TLS peer again every 15 min until one is up;
  `phone_peers.go`: a link
  that goes down gets two stand-ins dialled in parallel at once, told by
  the core's "Disconnected" log line, a candidate not up within 8 s is
  replaced, the surplus goes once the target is up again, at most twice
  the target are dialled at once, peers the transit guard set aside are
  no candidates; with no peer up, waves of fresh candidates after 5 s,
  then 15 s doubling up to 15 min by the wall clock, each one also
  redialling every kept peer, and the first send after a wake looks at
  once), local links with friends' and own devices without
  internet (1.6; Yggdrasil's own multicast discovery stays off), desktop
  inbound listener `tls://[::]:32913` [V], UPnP / NAT-PMP port mapping and
  "bridge" announcements in the ledger (`lg_bridges`).
- **Every device has an order of its own** over the built-in public peers
  (`public_peers.go`, `peerOrderSeed`): the order comes from the node's
  private key, so it is the same after a restart and cannot be worked out
  from outside from a Zen address, with one pick per operator (`peerGroup`:
  the /24 of an IPv4 address, the /48 of an IPv6 one, else the host name; the
  port plays no part). With one order for all, every locked phone dialled
  the same volunteer's node first, which saw the address and the invitation
  code of nearly every locked phone, and when it went away all moved to the
  same next one. A computer's built-in selection is spread the same way
  (countries first, each country's peers in its own order). The door host
  (`door_node.go`) takes a peer of a different operator than the main
  node's, so no operator links the sticker on a door with the person.
- **Port mapping** (`port_mapper.dart`): the SSDP search is believed only
  from the default gateway (the router that forwards a port to this
  computer is the gateway), its `LOCATION` must name that same address,
  redirects are not followed, and a router is described over plain http at
  an address on the local network, never this computer. The announced
  bridge carries this node's key, and a friend confirms a bridge only when
  the node at the announced address proves that key (`bridge_book.dart`),
  so a device on the same Wi-Fi can no longer pose as the router and have
  the computer announce a stranger's server. Addresses that are not worth
  announcing (6to4, Teredo, the newer documentation range, besides the
  private and loopback ones) are left out.
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
  device nearby when no public peer is up. A hold that began from transit
  between public peers alone leaves the links to people nearby open, and
  keeps the public peer that carried the least (not the first that was
  up), so a public peer can neither close those links nor make itself the
  only peer. Holds double for each further
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
  peer. **Who is known:** the app names the addresses it knows to the bridge
  (`setKnown`, at most 4096, again after every node start): its accepted
  friends and the devices of this account and of friends' accounts that
  proved themselves (`ledger_providers.dart`). Nothing else makes an
  address known: not being answered (the app answers anyone's `rly_ack`),
  not being written to, not a vouched key. KEM work other nodes can cause
  has two budgets: known addresses share 200/s (burst 400; a phone 40/s,
  burst 200); every other address shares 20/s (burst 40; a phone 4/s,
  burst 20), so strangers asking for keys never hold up a friend's session.
  A challenge given from the strangers' budget pays for the first session
  opened with it as well. Peer entries of addresses that are not known have
  room of their own (4096, the one used longest ago making room); a known
  address's entry is never pushed out. A frame of a session from an address
  the node has neither a peer nor a pin for is answered with `N` "want" (at
  most 20/s in all), and no peer is made for it. A receive session opens nothing after 2 hours; a
  challenge starts at most 32 sessions (then the sender is given a new one)
  and remembers their ids for as long as it is kept, so the recorded first
  frame of a session that is gone starts nothing again. A forced pin (or a
  new key record) drops every session made with the old key, both ways; a
  frame carries the fingerprint of the key its session was made with
  (`senderKey`).
- **Pins:** the device key is pinned per address on first sight; a record
  with another key for a pinned address is refused. A pin is of one of
  three kinds:
  - *loose*: only a record backs it. New loose pins come at most 120 a
    minute and have a quarter of the table (4096 of 16384) of their own,
    the one seen longest ago making room; a loose pin unseen for 14 days
    expires (`pqLoosePinTTL`).
  - *firm*: a session with the device opened here (either way), which only
    the holder of the device key can make. A session pins its device even
    with no new pins left, pushing out a loose pin or the firm one seen
    longest ago.
  - *vouched*: the app vouched for it (a hello signed by the device's hybrid
    key came over a session made with that key, 3.3). A vouch pushes out a
    loose pin or the vouched one seen longest ago, never a pin a session
    proved; with no room it is kept as a vouched hint (at most 1024), which
    refuses a record naming another key. With `keep` (the usual vouch) a
    different pin stays and is reported as a conflict; without it (a hello
    the device signed contradicts the session it came over) the key
    replaces the pin and everything made with the old one.

  A record never pushes out a firm or vouched pin, and a known address's
  pin goes only when it is loose and expired. The app keeps the pins with
  their kind, when each was last seen (to the hour) and the known addresses
  (sealed, `runtime/yggdrasil.pins`, version 2), and hands them back after
  a restart (`YggPqPinsJson` / `YggPqSetPinsJson`); a pin is firm or
  vouched after a restart only when it was so before. Pins kept by 1.16.4
  and earlier (all saved as firm, with no time) come back loose and expire
  three days later (`pqLegacyPinGrace`) unless the device confirms them
  with a record or a session of the same key.
- **Hints:** what someone else says about an address is only a hint
  (`importHints`, at most 8192, the one given longest ago making room): the
  keys a friend's friend list names (`friend_list` `k`, at most 2000
  addresses per friend in all, kept across restarts in `meet/vouched`) and
  the keys a friend's device records name (`device` in `acts`, at most 16
  per account). A hint never moves a pin, never ends a session and never
  keeps the device itself out; the first record of the device at that
  address decides (a hint it confirms is pinned at once, one it
  contradicts is dropped). A hint that names another key than the pin is
  only logged, never shown as a warning. Hints are kept per source and go
  when their source does: a friend removed takes back what only that
  friend named (`keepSessionKeyHintsOf`, `dropHints`). Every received signal carries the fingerprint
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
- **Doors:** the flat's doors (door nodes, `door_node.go`) run a session
  layer of their own, with a device key from the door's node key: a door
  takes sealed frames only, like the main node. Door frames are flat frames
  only, and knocks for mailbox doors are sealed once more by the app
  (`flat_seal`, classical X25519). A door keeps no pins across restarts.

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
  mobile data. Where Bluetooth streams are polled (Linux), they are polled
  quickly only while a stream is expected (a friend's device seen nearby
  that is not linked yet and is not being dialled); a stranger's Zen
  device, or a friend's already linked, seen again and again, is no such
  sign.
- **Adverts** carry a Bloom filter with one tag per device the sender links
  with (`HMAC(tagKey, "adv" | 5-minute slot | salt)`, a fresh random salt
  every time, filter size in steps of 16 bytes, seven positions per tag),
  so to anyone without the secret they are random bytes; they reveal only
  that a Zen device with local links is there and roughly how many devices
  it links with. A filter holds only as many tags as keep a false match
  rare (16 bits a device; `localAdvertCapacity`: eight in the 16 bytes of
  a Bluetooth advert): the account's own devices go in first, then those
  linked lately, then the others by turns, a new set each slot. A filter
  with more than 35% of its bits set is made again under a new salt, and
  one a receiver sees with more than 40% set means nothing and is not
  tested on any transport (an advert with every bit set once matched every
  phone). Bluetooth: the advert's service UUID and the L2CAP channel
  number (PSM) in the manufacturer data are not hidden, so a Zen device,
  and the same one while its listener runs, can be recognised by anyone in
  range.
- **LAN beacon**: the advert, then the "people nearby" advert of 2.12 (20
  bytes, only while the person is visible), an info byte (that advert's
  length, 0 or 20, plus `0x80` while the sender looks around) and the TCP
  port (2 bytes, big-endian). A device looking around beacons every 5 s; a
  visible device answers such a beacon with one beacon sent straight back
  (at most every 5 s per address). A device with no devices to link with
  beacons only while it looks around.
- **Handshake** (both ends, any stream, `local_link_handshake.go`, version
  3): each side opens with the version and a fresh random nonce, then sends
  a hello: fresh one-time keys, X25519 and an ML-KEM-768 encapsulation key,
  and a selector `HMAC(selKey, its own mesh address | its one-time keys |
  the other side's nonce)[:8]` per candidate device, shuffled and padded
  with random ones to one of a few fixed counts (so a hello's size does
  not tell how many devices a phone links with). A hello so answers only
  the opening it was made for: one recorded from a phone and played to it
  or to its friends later, anywhere, names nothing they would answer, and
  one sent back to its sender names the wrong address. A device on
  version 2 sends its hello where the opening belongs; either side then
  closes, so the two link only over the internet until both have version
  3. On a network stream the opening must come within two seconds, else
  the slot is freed. Each side then encapsulates a secret to the other's
  ML-KEM key; the stream keys come from HKDF over the X25519 result and both
  ML-KEM secrets (the lower side's first), salt the pair's link key, info
  both hellos and both ciphertexts. So the stream is hybrid post-quantum,
  and the pair's secret is too once the devices paired (above). Then
  AES-256-GCM records. The first record is the sender's Yggdrasil key, which
  must hash to the mesh address the secret was given for. Yggdrasil then
  peers over the stream with that key pinned; what travels over it is
  sealed again by 1.5. The link counts the frames it carries for the device
  at its other end (`local_link_traffic.go`); a stream that names a frame
  longer than a node takes (1 MiB) is no longer counted.
- A LAN beacon is taken only when it comes from the beacon port of an
  address on one of this device's local networks and names the TCP port the
  system gave the listener (never a well-known one), and a beacon is
  answered only on the local network (the socket listens on every
  interface, and a host with a public address would otherwise be answered
  or dialled). An iPhone takes at most two waiting Bluetooth streams from
  one device, as Android and the bridge do.
- Limits: 2048 devices, 16 streams, 8 handshakes at once, 2 per source,
  beacon rate limits per sender and in all.

### 1.7 Local interfaces and the update check [V]

None of these is a frame between Zen devices.

- **Single-instance port** (`single_instance_guard.dart`, computers only):
  the first Zen process binds TCP `127.0.0.1:47821`; a later launch asks
  it to come to the front (and to open the file the launch was given) and
  exits. Both sides prove a session secret: 32 random bytes, new at every
  claim of the port, in `single_instance.key` in the app's data folder
  (private to the user from its first byte, deleted when the port is
  released). The secret never crosses the socket. Lines (UTF-8, `\n`, at
  most 16 KiB, 2 s per step), all starting `ZEN-SINGLE-INSTANCE/3`:
  launch `HELLO <nonce>`; owner `PROOF <nonce> <mac>` with `mac` =
  HMAC-SHA256(secret, `"zen.single-instance.owner <launch nonce> <owner
  nonce>"`); only when that checks out, launch `ACTIVATE <mac> [<file>]`
  with `mac` = HMAC-SHA256(secret, `"zen.single-instance.launcher <launch
  nonce> <owner nonce> <file>"`), `file` the base64url of the path; owner
  `ACK`. Nonces are 16 random bytes in hex. A port held by something that
  cannot prove the secret is not taken for Zen: the launch starts as it
  would beside an unrelated program and hands nothing over. A running Zen
  still answers the request of 1.16.4 and earlier (`ZEN-SINGLE-INSTANCE/2
  ACTIVATE <secret> [<file>]`, the secret in the clear) when it carries
  the right secret, but never sends it; so a new launch beside a running
  1.16.4 starts without the single-instance service.
- **Update check** (`update_notice.dart`, `background_update_check.dart`):
  the app asks GitHub for the latest release once the last answer, whoever
  got it, is older than 15 minutes (`kGithubCheckEvery`: at start, back on
  the screen and while it stays open), the Android background service the
  same way on wakes that come anyway (`kBackgroundGithubCheckEvery`). After a
  failed ask (not reached, no answer, an error answer) the service waits 15
  minutes, then twice as long after each further failure in a row (30, 60,
  120, at most 240 minutes, `kBackgroundUpdateRetryAtMost`), and also any
  wait GitHub asked for (a rate limit). The count of failures in a row
  (`failures`, at most 32) and the time of the last one (`failedAt`) are
  kept in `update_check.json`, so a restarted service keeps the wait; the
  first answer clears both. A last failure dated in the future, or a wait
  longer than the period, is taken for a clock set back and holds nothing
  back; a check the person starts never waits.
- **Android autofill** (`ZenAutofillService.kt`, `password_autofill_bridge.dart`):
  the system's autofill service talks only to the app on the same phone
  over the method channel `zen/autofill`; the password setup
  (`password_setup.dart`, `ZenAutofillSetupBridge.kt`) looks at the
  installed browsers over `zen/autofill_setup`; nothing of it goes on the
  network.

## 2. Frame types

Direction is sender -> recipient unless stated. "Reliable" means the type is in
`kReliablePayloadTypes` (section 3.1).

### 2.1 Presence

| type | Fields | Notes |
|---|---|---|
| `ping` | presence: `state`, `lo`; optional hello: `mf`, `mk`, `ms`; version: `ver`, `build`, `caps`, `minv` | Only while Zen is on the screen: to every target when the app comes to the screen (once more when the node first reaches the mesh, if that round went out before it did), at once to a target just added, then in rounds every 2 min (`kPresencePingInterval`): the first two rounds after the app comes to the screen go to every target; after them a friend online, one not heard from yet in this run, one whose state changed since their last ping and anyone who is no friend get every round, a friend "in the background" and one whose frames carry no `state` (they hide it from this person) every second round (4 min: a locked phone answers one contact at most every 3 min 30 s anyway), and a friend whose last word was `"asleep"` or who was not heard from for longer than 25 min (`kPresenceBackgroundFor`, counted from the start of the run when nothing came from them) every third (6 min; `presencePingEvery`). A friend's own pings are always answered. Targets: accepted friends, plus members of groups with an unconfirmed invitation from this device. Not answered unless the sender is a friend or group member. |
| `pong` | presence: `state`, `lo`; hello fields, version fields | Reply. Hello fields (friends who see presence): `mf` short digest of the friend list sent, `mz` digest of the nearby keys given to that friend, `ms` time the current status was set (0 if none or not visible), `ma` digest of the alarm key. The receiver asks again for what does not match with `meet_req`. A locked Android phone answers one contact at most every 3 min 30 s (`kLockedPongEvery`: the first ping after a quiet while at once, then every other one), with no presence or hello fields; an open Zen answers a weak acquaintance exactly so, and as rarely. |
| `away` | presence: `state`, `lo` | A one-way presence announcement, despite its name for any change of the sender's state: leaving the screen (`"background"`, or `"asleep"` on an iPhone iOS suspends), coming back before the next round (`"foreground"`), quitting Zen on a computer (`"asleep"`), and what was held back while the node had no network, once it has. Sent only to friends who see presence and have Zen open now (their last `ping`, `pong` or `away` in this run, within 5 min, said `"foreground"`), and only when they were last told another state; at most one per state per friend every 30 s (`kPresenceNoticeEvery`), changes within 2 s told as one (`kPresenceNoticeDelay`). One held back goes when its time is over, unless the state is back to what they were told. An iPhone's `"asleep"` goes to every friend who sees presence (their mail should go to the mailboxes now), to one without Zen open at most every 4 min (`kPresenceAwayEvery`). Never mailboxed; ignored by a locked phone (which says `"background"` in its pongs, so it never gets one). A 1.13 Zen applies whatever `state` an `away` names. |
| `typing` | `isTyping` (bool) | Real-time, not reliable. The sender says `false` when the field empties, a message goes or Zen leaves its screen; the receiver shows "pisze…" for 6 s after the last `true` (`typingShownForProvider`), so a `false` that never came does not leave it shown. |

Presence fields ride on the frames above; nothing is polled only for them.
A message counts as a sign that its sender is there only when it was written
at most 2 minutes before it arrived (one that waited in a mailbox or a
queue says nothing of now); writing to a friend never marks them as seen.
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
`away` when it leaves), *in the background* after 25 min
(`kPresenceBackgroundFor`: a locked phone answers every 4 min, as it
answers one contact at most every 3 min 30 s, but a sleeping phone is not
always reachable between its own wakes, so it also pings the friends who
see its status every 10 min itself, `kLockedPresenceRoundEvery`; two
rounds and a bit). After 10 min without a frame (`kPresenceOfflineAfter`)
the friend no longer counts as reachable directly, and what goes to them
waits in their mailboxes. The receiver keeps the last
opening (receive time minus `lo`) and shows it while the friend is not
online. A locked Android phone takes `state` and `lo` for its pongs from a
presence kit the app writes, sealed with the background key, whenever Zen
leaves the screen (`presence-kit.zenbg`: the friends who may see presence
and when Zen was last open).

**Rounds of a locked phone** (`locked_receiver.dart`, `zen_wake.dart`):

- The rounds keep to the ten-minute grid of the wall clock (`kWakeGrid`),
  where the nearby token changes too (2.12), so friends' locked phones,
  whose clocks follow the network's time, wake on the same boundaries and
  a round's ping reaches a phone awake for its own. Where exact alarms are
  allowed (or the phone is shown nearby, whose token alarm is exact) the
  beat's wake is asked for 1 s before the token's alarm and shares its
  wake; under Android's inexact alarm windows a wake is asked for early
  enough that its window ends when it is due, so the rounds and the
  20-minute looks keep their periods. A wall clock set back counts as a
  round due.
- A friend this phone told its status and heard theirs from (a ping and
  its pong, either way) within the round's period is not pinged in that
  round: one exchange counts for both phones, so two locked friends no
  longer wake each other twice a round. A ping or pong lost leaves one side
  without the other's word, and its next round pings again. A friend whose
  word says Zen is on their screen is pinged every round.
- A friend nothing came from for 30 min (`kLockedSilentAfter`) is pinged
  every third round (`kLockedSilentRoundEvery`). The bookkeeping of the
  rounds (who was told, heard and pinged) holds at most 2000 friends.
- A wake with no network at all (flight mode, no signal) does not wait for
  a link.
- **Statuses kept for the app** (`presence.zbox`, sealed with the
  background key): the newest frame of each friend (a friend's other
  device counts as the friend). A change (a first frame, another state,
  another last opening) is written at once; an unchanged status is written
  again once the kept frame is 5 min old (`kKeptPresenceRefreshEvery`; 2 min
  30 s for a friend online), and at once when the kept frame is 15 min
  older than the newest (`kKeptPresenceStaleAfter`); what waits is written
  when the receiver stops. When Zen opens, the app reads the file again
  after the service stopped, shows each kept status as what it is worth by
  now (aged from its frame), and never lets a kept status undo a newer one
  it heard itself (log line `presence-kept`).

Two more states are shown only by the receiver; the last state known is
kept underneath and nothing is sent for them:

- *No connection* ("brak połączenia"): this device has not reached the
  mesh for 30 s (`kPresenceNoNetworkAfter`), so every friend shows it at
  once; it is about this device, not about them. Nothing expires into
  *offline* meanwhile. Back on the mesh, each friend shows the last state
  as it stands now, or *unknown* when it was confirmed more than 30 min
  ago (below); the friends who had Zen open are pinged at once (they hear
  this device and answer).
- *Unknown* ("status nieznany"), for two reasons:
  - *Not checked lately*: the state remembered from before a start (kept
    per friend in the encrypted social snapshot: the state, when it was
    last confirmed, the last opening) is shown as it stands now when it
    was confirmed at most 30 min ago (`kPresenceRememberedFor`; the
    expiry above counts from that confirmation, so *online* from 8 min ago
    shows *offline*); confirmed longer ago, it is *unknown* until the
    friend's next frame, or until 20 s after the second round of pings
    that could arrive (about 2 min after the node reached the mesh,
    `kPresenceSettleAfterResume`), when it shows what that state is worth
    by then. The same after coming back to the screen, or to the mesh, for
    a state that would have expired meanwhile.
  - *Too old*: a friend whose `ping` or `pong` names a `ver` older than
    1.13.0 and no `state` (a newer Zen without `state` hides its presence
    from this person, which shows nothing).

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
| `message` | `msgId`, `senderName`, `text`, `messageType` (`text|image|file|voice|video`), `attachmentData` (base64), `attachmentEncoding`, `fileName`, `mimeType`, `attachmentSizeBytes`, `durationMs`, `mediaWidth` + `mediaHeight` (a photo's or GIF's size in pixels, upright, read from its header when it was attached), `createdAt` (sender clock, ms), `ttl` (seconds), `re` (reply: `{id, s?: sender, t?: start of its text <=200}`), `fwd` (true: forwarded) | Reliable. One of `text`, `attachmentData` required. GIFs travel as ordinary image attachments. The bubble takes its size from `mediaWidth`/`mediaHeight` before the picture is there or decoded, so the chat does not move when it comes; the pair is taken only as whole numbers from 1 to 65536 and the box only in proportions up to 8:1, at most the bubble's width and 320 high (without the pair, from a Zen before 1.17.5, the bubble waits for the picture as before). The mailboxes pass both on with a large file's other fields. Frames up to 48 KB can be mailbox-relayed (section 3.2); the signal limit is 2 MiB. A reply to a disappearing message carries no `t`. |
| `message_placeholder` | as `message` plus `chunkCount`, `chunkIndex`, `attachmentTransferBytes` | Announces a large attachment sent in chunks. |
| `message_chunk` | `msgId`, `chunkIndex`, `chunkCount`, `chunkData` (base64), + placeholder fields | Not reliable; has its own protocol. Never compressed (high-entropy). |
| `message_chunk_ack` | `msgId`, `chunkIndex` | |
| `message_ack` | `msgId` | Delivery acknowledgement of a message (reliable). |
| `message_read` | `msgId` | Read receipt (reliable, latest-only, 3.1). Sent once per opening of the chat, naming the newest message of the friend's that was read: every message of the friend's up to it is read. Taken only when `msgId` names a message the receiver sent; only such a receipt shows "Przeczytano" under the receiver's own messages. |
| `message_transfer_cancel` | `msgId` | Reliable. |
| `transfer_offer` / `transfer_answer` | `transferId`, `description` (WebRTC SDP map), + file fields (`fileSize`, `fileName`, `mimeType`, `messageType`, ...) | File transfer over a WebRTC data channel [P]. |
| `disappear_timer` | `groupId?`, `seconds` (0 = off), `at` | Reliable. Same `ttl` is carried by messages. |
| `msg_react` | `msgId`, `groupId?`, `author?`, `emoji` (<=16 chars; empty = taken back) | Reliable. One reaction per person per message. In a group `author` names the address of the message's author (2.4). |
| `msg_edit` | `msgId`, `groupId?`, `text`, `at` (sender clock, ms) | Reliable. Taken only from the message's author, only for text, and only while `at` is within 25 h of the message (24 h + 1 h clock leeway). The earlier text is not kept. |
| `msg_delete` | `msgId`, `groupId?`, `author?`, `at` | Reliable. Taken from the author, or in a group from its creator as recorded by the receiver. The content and file go (a file still on its way stops: no chunk is sent any more, and a chunk that comes late is acknowledged and dropped); a note stays; replies drop the quoted text; the notification that showed the message, its entry in the notification list and its copy in the background queue go, also while the phone is locked and on the account's other devices. A deletion of a message not here yet makes it gone before it comes: the message, when it comes, is acknowledged and never shown. An edit of a message not here yet waits for it; a reaction to one is dropped. |

**Order in a chat.** `createdAt` is the sender's clock. A friend's message
that came straight from them never goes above a message they are known to
have had (one of theirs already there, or one from here they confirmed): a
clock that runs behind would otherwise put the answer above the question.
The receiver then keeps in memory how far behind that friend's clock runs
and reads their next messages through it. What really was written earlier
(a message that waited while this phone was away, a late copy) still goes
where its time says, and a late copy never puts its older words at the
top of the chat list.

**Confirmation** (`message_ack`): a message is confirmed only when the app
kept it or refused it for good, on every path. A signal that cannot be
decided yet is put off and comes again, not dropped and confirmed: while the
friend list could not be read (a busy start) a message was dropped and still
confirmed (the sender saw "delivered" for a message that was gone); the same
for a message that overtook its sender's acceptance, and an edit that came
before its message was confirmed while it waited in memory only.

**Disappearing timers** carry a stamp: a message carries when its sender's
timer was set (`ttlAt`, beside `ttl`), and `disappear_timer` carries it as
`at`. The later setting wins, the same on every phone of the conversation;
a stamp of a change made after seeing another one is later than it whatever
the clocks say (`laterDisappearStamp`), two at the very same millisecond
leave the shorter one. A setting with no stamp (Zen 1.16.5 and earlier) is
taken only while none is known: it may still switch a timer on, never undo a
stamped change. A message is looked up before its file is written, so a
copy that comes again writes its file once.

`msg_react`, `msg_edit` and `msg_delete` (like `message` and `disappear_timer`)
are mirrored to the sender's other devices, which apply them as their own.
A message that disappears (`ttl`), is edited, is deleted from one device or
whose chat is cleared leaves no words behind either: its notification goes
with it. A disappeared message is remembered with its author, so a late
copy of it (a re-send, a mailbox, another device) does not bring it back.

**Mirroring to the account's own devices** (`account_routing_transport.dart`):
what one device sends of the types `message`, `disappear_timer`,
`msg_react`, `msg_edit`, `msg_delete`, `message_read` and of
`group_message` with `ttl` goes to the account's other devices as
`acct_mirror {to, p}` (`to` the friend's address or `group:<id>`, `p` the
payload), and they apply it as their own. A `message_read` copy marks the
chat read there up to that message, with no unread count or notification
left, and sends nothing to the friend. Groups have no read receipts: a
device that read a group sends its other devices `acct_mirror {to:
"group:<id>", p: {type: "group_read", groupId, msgId, author}}` naming the
newest member's message read, and they mark the group read up to it.
Devices older than 1.16.5 ignore a mirrored type they do not know. The read
mark reaches the account's other devices also when they were off: it waits
in the queue until it is sent (it went as one packet that was never sent
again), and a message that arrives after its mark comes in read. The
call's end sent to the callee's other devices is no longer taken as the
caller hanging up, so a call taken on another device leaves no missed call
(1.17.0; both sides).

**Numbers and nesting from a peer** (`runtime_signal_parser.dart`): a number
that is not finite, or lies beyond ±(2^53 − 1) (`kMaxSignalNumber`), and
anything nested deeper than 16 levels is read as absent (in a list it
becomes `null`, so the other items keep their places). A group file
reference (`media`) is kept only with the fields that name and open the
file, each of its own type and size, so no value a peer sends can
drop a signal or make a message impossible to store.

### 2.4 Groups

Groups are fan-out: the sender sends the frame to **each member** individually
(at most 256 people, the creator included, `kMaxGroupMemberCount`; a phone
keeps no more of a longer list, so creating a group or adding someone past
that is refused with a message on the phone that tries). Every group frame
needs `groupId` (<=256 chars).

| type | Fields | Notes |
|---|---|---|
| `group_invite` | `groupId`, `groupName` (<=100), `description` (<=1000), `memberAddresses`, `memberNames?`, `avatarPreset`, `senderName`, `inviteId`, `added?`, `at?`, `left?` | Reliable. `inviteId` is a nonce: re-sends of the same invitation do not revive a declined group. Also a member-list update: one that adds a person names that address in `added`, stamped `at` (the adder's clock, ms) and lists only the adder and the newcomer, so the others take the newcomer even when the adder's list is a step behind. The members' list sent to someone who just joined carries `left`: who left and when (address → leaver's time, at most 256). Only the creator's list is taken whole; any other member brings in one person per update (from a Zen before 1.16.5, the one unseen address of its list; a list with more is taken from nobody). |
| `group_invite_ack` | `groupId`, `joined?` (`true`: accepted, not only arrived) | Reliable. |
| `group_message` | `groupId`, `groupName`, `msgId`, `text` (<=64k chars), `senderName`, `timestamp`, `ttl`, `re`, `fwd`; for a file also `messageType`, `fileName`, `mimeType`, `attachmentSizeBytes`, `durationMs`, `mediaWidth` + `mediaHeight` (as in `message`) and either `attachmentData` + `attachmentEncoding` (inline, files <=64 KB, or <=1 MB while no block store runs) or `media` (`{id, k, n, mime}`: the reference of `lg_blob_*` blocks, files <=24 MB) | Reliable. A member fetches `media` blocks with `lg_blob_want` from the sender or any other member; a member's device answers such requests from non-friends too. A text longer than members keep (64k characters) is refused on the sender's phone, not cut. Members choose `msgId` themselves: a message whose id another member's message already holds here is kept under a key of the sender's own (`<msgId>#` + the first 16 hex of SHA-256 of the author's address), never dropped as a copy; only the same author's message under the id is a copy. |
| `group_leave` | `groupId`, `at?` (the leaver's clock, ms) | Reliable. Only the leaver's own `group_leave` takes it out of a list. A leave stamped before the leaver was last added by name is an older one and changes nothing. A phone that left or declined a group answers a message of it from someone who still counts it as a member with its leave again (at most every 6 h per member and group, never to a blocked person, only for a group it was in or invited to). Leaving or declining removes the group's chat, files and notifications on the leaver's phone. |
| `group_post` | `groupId`, a board post `{id, a author, n name, x text <=2000, t created, v version, d? removed, m? photo reference {id, k, n, mime}}` | Reliable. A new, edited or removed post; the newest `v` wins. Photos up to 8 MB as `lg_blob_*` blocks. At most 20 new posts per member and group an hour; a board keeps 300. |
| `group_board_have` / `group_board_put` | `groupId`, post ids and versions / up to 50 posts | Real-time sync between members: what I have, and the asker's missing posts written by the one answering. |

**Who is in a group** (`group_profile.dart`, `departedAt`, `addedAt`): each
phone keeps per group who left and when, and who was added by name and
when (each at most 256, the newest). No member's list brings back someone
who left, the creator's neither: a list carries no time, and a member who
was away when the leave went out still lists them. Only an addition by
name stamped later than the leave (a new invitation) does. A time a member
gives for a leave or an addition counts at most one hour past the
receiver's clock. Only the leaves a newcomer's inviter tells of in `left`
are taken from someone other than the leaver. The group's creator speaks
in it as the receiver recorded it, unless the creator left: from then on
no phone takes the creator's messages, calls, timers, edits or deletions,
nor tells of them while locked, until a later invitation makes them a
member again. A phone restored from a copy keeps who left.

**Converging membership** (1.17.0; the fixes need both sides). Two members
adding someone at once no longer split a group: a newcomer used to learn
the member list from its inviter alone and dropped the messages of members
it did not know. Members now pass on the additions a newcomer missed, and a
`group_message` from a member not yet known is put off until it is.
**Invitations are tracked**: a `group_invite` shows as waiting until its
`group_invite_ack` came; one that expired unseen is told as not arrived (it
showed as waiting for ever) and can be sent again; member list updates are
not counted as invitations waiting. A `group_leave` of the person's own
account reaches its other devices, which leave too: the chat and its files go
from all of them.

### 2.5 Calls (signalling) [V]

Not reliable (real-time). `kind` is `"audio"` or `"video"`; most carry `callId`.

| type | Fields |
|---|---|
| `call_invite` | `callId`, `kind` |
| `offer` / `answer` | `callId`, `kind`, `description` (SDP map; the first offer and every answer may carry `e2ee`, 2.5.1) |
| `ringing`, `call_accept` | `callId`, `kind` |
| `call_decline`, `busy`, `hangup` (alias `call_end`), `call_offer_request` | `callId`, `kind` (`callId` mandatory for decline/busy/hangup) |
| `call_mkey` | `callId`, `epoch` (int): the sender's media key moved to `epoch` (2.5.1) |
| `call_missed` | `callId`, `kind`, `at` (when the call was made, caller's clock, ms). Reliable, latest-only (one per caller waits, 3.1), a notice type: the caller sends it once a ring of its 1:1 call ended unanswered, so a callee who was away (offline, phone off) shows the missed call once when back; a callee whose phone rang notes the call id with the ring and shows it once. It never rings. A Zen before 1.16.5 ignores it. |

A call that rings (out or in) is kept when another call comes: the new
caller gets `busy` and sees a missed call, and only the first caller may
replace its ringing call with a new one of theirs; an `offer` or
`call_invite` of a second caller never takes the screen.

Media: WebRTC, relayed through the local bridge relay (1.3). Screen share and
recording are signalled inside the call [?]. **Codecs:** both sides keep
only VP8, then H.264, with their repair formats, VP8 first, for the camera
and a shared screen (`setCodecPreferences` before every offer and answer,
or the local description reordered where the platform refuses;
`call_video_codecs.dart`): the frame encryption of 2.5.1 leaves in the
clear what the packetizer of those two reads, which is not known of H.265,
VP9 or AV1, and two phones listing their hardware codecs first could
otherwise agree on frames the other side could not open (the picture
stayed black while the sound worked). An older Zen on the other side gets
VP8 too: it answers in the order offered, and its own offer is answered
with VP8 first. Since 1.17.0 the side that answers also puts VP8 first in
the other side's description before applying it: it used to send the first
codec of the offer, so an offer with H.264 first still got hardware H.264.
The other side's picture is bound to the renderer by the track once the
platform has registered its stream (it was bound when the track was first
reported, before that, so in some calls it stayed bound to nothing while
frames were decoded), and bound again if decoded frames never reach the
screen; the microphone, loudspeaker and camera controls are shown and work
while the call rings, not only once it is active. A camera switched off
during a call is a new `offer` whose camera section is `recvonly`; the
answer's camera section never asks for more than the offer allows (a side
with its camera on answers `sendonly` then, not `sendrecv`), and since
1.17.5 the offering side also cuts an answer that asks for more (as every
Zen up to 1.17.1 sent) to what its offer allowed before applying it:
WebRTC refuses such an answer, and the call ended.
The technical log names per call the codecs offered, whether
the camera's frames were sealed and opened, the video packets sent and
received and the frames decoded and shown (`call_video_trace.dart`, lines
`Call video`).

**Picture** (since 1.17.5, `call_video_quality.dart`): the camera is asked
for 1280 x 720 at 24 frames in plain numbers (flutter_webrtc on Android
skips `{ideal: …}` maps, so it had opened every camera at its own default).
On Android the camera's auto-exposure frame-rate range is pinned once the
camera runs (`ZenCallCamera.kt`) to the steadiest range the camera offers:
the highest floor from 15 up to 24 frames (24-24 where there is one), else
the lowest floor above 24; WebRTC's own pick was the lowest floor (7-30 on
most phones), and in poor light the camera then sent 5-6 frames, each
smeared by movement. The camera sender keeps between 150 kbit/s and 2.5
Mbit/s at up to 24 frames, and keeps its frames before its resolution when
the path is tight (`MAINTAIN_FRAMERATE`); the estimate of the path starts at
1 Mbit/s (`x-google-start-bitrate` added to the camera's VP8 and H.264
formats of the other side's description before it is applied) instead of
300 kbit/s. What is promised: on a path that carries 1.5 Mbit/s or more
each way, a sharp 1280 x 720 picture at a steady 24 frames (15 at the least
in poor light where the camera has no steady range of 24), also when it
moves; on a worse path the frames keep coming at a lower resolution, and
below 150 kbit/s the path's own losses decide. A camera sends VP8, in
software where the phone's WebRTC has no VP8 encoder (the frame encryption
leaves only VP8 and H.264 readable, and H.264 left pictures black); the
log line `encoder` says which. The `Call stats` lines (4 s, 15 s and a
minute after the media connect and after each offer or answer) give the
camera's size and frames captured, the frames sent with the encoder's aim
(`target`), its average quantizer (`qp`, above about 80 blocky), how often
it changed the resolution and how long the processor or the path held it
back, and for the picture coming in its frames a second and freezes; a
`Call camera` line says what the camera was asked for and which frame-rate
range it offered, ran at and was pinned to.

**The screen during a call** (since 1.17.5, `call_screen_awake.dart`,
`CallScreenKeepOn.kt`): the app's window keeps the screen on
(`FLAG_KEEP_SCREEN_ON`) while a 1:1 or group call is a video call (its kind
or this side's camera) or is heard out loud (loudspeaker, or a headset,
which shows as the loudspeaker), from the first ring of an outgoing call
(and from the answer of an incoming one) to its end. It is decided above
the call screen, the call bar and picture-in-picture, so none of them takes
it away; the flag is kept apart from the incoming ringing's own (whose end
used to clear it) and put back on every new window of the app. A voice call
on the earpiece holds the proximity sensor instead
(`PROXIMITY_SCREEN_OFF_WAKE_LOCK`, where the phone has it,
`ZenCallProximity.kt`): the screen goes dark and ignores touches at the
ear and lights up away from it; released (once nothing is close) when the
call ends, goes to the loudspeaker or a headset, or becomes a video call.
One decision (`callScreenModeFor`) chooses between the two. The technical
log says `Call screen kept on (reason)`, `Call screen keep-on released`,
`Call screen dark at the ear` and `Call screen proximity released`, with
whether the window or the sensor took it. Up to 1.17.1 only a ringing
incoming call kept the screen on, and nothing used the proximity sensor.

**Call tones** (since 1.17.5, `call_tones.dart`, `ZenCallTones.kt`): the
sounds of a call only this side hears go to the call's audio (Android's
voice-call stream, usage `VOICE_COMMUNICATION`, at the call's volume and on
its route) and play whatever the ringer says: the ringback while the other
phone rings (a call made here, not a group's), the busy tone when the call
is declined, finds the other side busy or is not answered, a short signal
when the media drop and the call reconnects, and Zen's chimes when the call
connects and ends (these two still follow "Dźwięki w aplikacji"). The
ringback, busy and reconnecting tones are the phone's own (`ToneGenerator`,
in its country's cadence). The ringing of an incoming call and the message
sounds follow silent mode and the notification settings as before. On a
computer only the chimes play (no ringer to follow); on iOS none (as
before). Each tone leaves a `Call tone` line in the technical log.

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

**Door code and sticker link** (`FlatDoorCode`, `flat_model.dart`): the
code holds the household's key, the door token, the flat door's address,
the name and, when there are any, the doors for sealed knocks (mailbox
doors and the other residents' doors, sorted together, at most 14) with the
sealing key; an invitation shown nearby adds when it stops working. It
comes in two formats:

- **Format 1**, JSON, base64url without padding:
  `{v: 3, k, d, a, n, s, x, u}` (`s` the doors' 16-byte addresses
  concatenated in base64url, `x` the X25519 sealing key, `u` the end in
  milliseconds; `mv` names the oldest reader version when a newer one must
  not be read by older builds). Phones pass codes to each other in this
  form (`zen-flat:<code>`, the household's sync and nearby invitations),
  and the stickers of Zen 1.14 and older carry it, so every build reads it.
- **Format 2**, binary, written as decimal digits: the printed sticker's
  link `https://robertostrowskijagoda.github.io/Zen/m#<digits>`. The digits
  are the bytes as one big-endian number, padded with zeros to the digits of
  256^n − 1 for n bytes (so the length gives n; like the pebble's QR card),
  which a QR code holds in numeric mode at 3.3 bits a digit. Zen 1.14 and
  older do not read it.

| Field (format 2, big-endian) | Size |
|---|---|
| format = 2 (high four bits), number of doors 0–14 (low four bits) | u8 |
| household key (Ed25519 public key) | 32 |
| door token | 12 |
| flat door's address without its first byte (always 0x02) | 15 |
| each door for sealed knocks, the same way | 15 each |
| sealing key (X25519), only with at least one door | 32 |
| name (cut to 150 characters when read) | length in UTF-8 bytes (7 bits a byte, lowest first, high bit set while more follow) + UTF-8 |
| records to the end: tag 1 = until (6 bytes, milliseconds) | u8 tag, u8 length, data |

A reader skips record tags it does not know; a first byte with a format
above 2 makes the app ask to update, anything malformed (a length no
number of bytes has, a field cut short, bytes after the records, more than
1024 bytes, a name that is not UTF-8) is not a door code. A code whose
key, token or addresses are not in the form the app makes (a padded token,
an address outside 200::/8) is printed in format 1 instead. The app reads
both formats from any link form (`…/m#`, `zen://m/<code>`,
`zen-flat:<code>`), and so does the door page (`tool/pages/m/door.js`),
which shows only the name; the code stays after `#` and never reaches the
web server.

The whole link, its QR version at error correction M (as printed) for a
15-byte name, and the module of a plain code 5 cm across with its quiet
zone (with six doors a name of up to 19 bytes keeps version 11):

| Doors | Format 1 | Format 2 |
|---|---|---|
| 0 | 244 characters, version 11, 0.72 mm | 76 bytes = 184 digits (230 characters), version 8, 0.88 mm |
| 6 | 492 characters, version 17, 0.54 mm | 198 bytes = 477 digits (523 characters), version 11, 0.72 mm |
| 14 | 720 characters, version 22, 0.44 mm | 318 bytes = 766 digits (812 characters), version 15, 0.59 mm |

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
| `date_safe`, `date_safe_ok`, `date_loc_req` | "I'm going on a date", "All OK", a one-shot location request. The watcher counts the time left from when `date_safe` arrived (its own clock, not the time the other phone named), so a clock twenty minutes ahead cannot ring the alarm early; a date nobody confirmed and its last place are dropped a week after the alarm, and the watcher can end it by hand once the time has passed. |

Minor reports: a profile is hidden for everyone on a phone only when two of
its owner's own friends (accounts the phone can put the dating keys to)
reported it as a minor; reports from keys that cannot be put to a person only
show a warning, two keys of one person count once, and a report can be
withdrawn. A profile that is switched off, banned or hidden announces no
messages and no matches: one rule decides wherever a match can reach it. The
hide list holds against friends; the sealed match test (`match`, `match_re`)
holds only against apps that follow the rules.

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
mailboxes, for 7 days (the ledger's own sync brings them anyway once both
are online). The receiver takes them like `lg_entries`, with the same checks.

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
emission), `ldig` / `lwant` / `lops` (treasurers' ledger sync every 30 min;
`lops` also carries releases, `rel`). Transfers are never records; members
who are not treasurers or parties receive nothing.

- **Operations.** An order (`xfer`) or a settlement (`settle`) is signed by
  the payer, names the next number of the payer's account (`seq`, at most
  2^40) or the payment it settles, a fresh nonce `nc` (so the id a seal
  lists cannot be worked out from a guess at the payment) and, when it
  follows a release, that release (`rel`); at most 4 KiB. A treasurer
  signs it only against its own copy of the ledger and never two
  operations for one span of a slot (an account's number, or one
  settlement per payment). It counts once most treasurers of its time
  signed it: two majorities of n share 2m − n treasurers (m the majority),
  so a double spend needs that many to sign two operations for one span,
  which is proof against them (two of an even number, one of an odd one).
  A refund of a conditional payment waits until its acceptances are
  closed. Every phone refuses, when it counts, an operation without the
  payer's full signature, from or to a non-member, or over the daily limit
  in force at its time, and a treasurer checks its whole ledger for the
  numbering and the money too; no balance, emission or statement may pass
  2^60 (`kPyrMaxBalance`).
- **Releases** (`xrel {slot, prev?}`, private, `pyramid_ledger.dart`): a
  span of a slot split between operations none of which can reach a
  majority any more (cancelled orders, two devices at once, an acceptance
  and a refund around a payment's time; `PyrLedger.isSplit`) is freed by a
  release most treasurers of the era sign. A treasurer votes once it has
  seen the span split for 1 hour (`kPyrReleaseWaitMs`), once per span on
  every device of the account, and sends its vote to the other treasurers
  at once; the release, once most voted, goes to everyone the slot's
  operations concern, and the order waiting goes out again under it. A
  release leaves every operation of its span behind, and the next span of
  the number starts; a treasurer never moves on to another order alone.
  Two releases of one span need 2m − n treasurers signing both, like two
  operations.
- **What treasurers keep and answer:** a treasurer keeps only operations a
  treasurer of their era signed, at most the 32 newest that do not count
  (orders waiting, or split) per payer (`kPyrMaxEvidencePerPayer`), and
  answers `ldig` / `lwant` only to the treasurer whose member record names
  the sending address.
- **Seals of the eras** (`seal`, public, 3.4): once an era of the
  treasurers ended, most of the next era's treasurers seal it with the
  operations dated in it that counted for them; an operation dated in a
  sealed era that its seal does not list counts nowhere.

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

### 2.13a Key pieces at close friends, and account moves [V]

`account_recovery.dart`, `recovery_service.dart`, `recovery_circle_pick.dart`.
The account key (its 32-byte seed) comes back with the account password and
the pieces of enough of the person's close friends; there is no way back
without the password.

- **The seal.** When the person sets the account password (at least 12
  characters, not the app password, not easy to guess by the password
  manager's estimate; `kMinRecoveryPasswordLength`), the device seals the
  seed under it once: Argon2id (64 MiB, 2 passes, `kRecoveryPasswordCost`)
  gives the password key, `SHA-256("zen.recovery.inner" | key)` the key of
  a ChaCha20-Poly1305 box of the seed (`RecoverySeal`, kept on the device
  that hands the pieces out, `recovery/sealed`).
- **Generations.** For each generation of pieces the device draws a fresh
  32-byte circle secret, seals the seal's box again under
  `SHA-256("zen.recovery.outer" | secret)`, and splits the secret by
  Shamir over GF(256) among the holders, `t` of `n` (`pieceThreshold`: 2
  of at most 4, 3 of 5–9, 4 of 10 or more). A piece's `normal` half is
  `{v: 2, salt, cost, box, share, t, g}`; its `emergency` half keeps the
  old form for helpers on 1.16.4 and earlier and holds only random bytes.
  A share of one generation never combines with a share of another. A new
  generation is made, without the password, whenever the close friends
  change; the bookkeeping (holders, threshold, who confirmed, `recovery/gen`)
  is the same on all the account's devices (account state domain
  `recovery`, 3.3), and only the device whose seal is newest hands pieces
  out.
- **Holders**: every friend at the "close" level, at most 12
  (`kMaxPieceHolders`; with more, an order of their own per account,
  `SHA-256("pieces|" account "|" address)`, stable when one is added).
- **Messages** (over the signal transport; a holder takes them only from a
  friend):
  - `rc_store {piece, a, g, h?, at, cert, sig}`: owner → holder. Signed
    (hybrid, 4.1) by a device of account `a`, with its certificate, over
    the account, the generation `g`, the holder's account `h` and the
    piece's box; the holder keeps it under that account, not under the
    sending address, so a piece follows its holder's account to a new
    phone, to its other devices and into its moves and full copies. Sent
    again every 30 minutes until confirmed, offered again every 7 days.
    Unsigned `{piece}` (1.16.4 and earlier) is kept under the sender's
    address.
  - `rc_ack {account, created}`: holder → owner, the generation kept.
    The account counts as secured ("Konto jest zabezpieczone") only once
    at least `t` holders confirmed the current generation (or a key copy
    exists).
  - `rc_forget {a, g, cert, sig}`: owner → holder, signed (`"zen-recovery-forget|"
    a "|" g`): delete every piece of `a` older than generation `g` (all of
    them, for someone who holds none now). Sent to every holder of an older
    generation (the circle of 1.16.4 too) once the new one reached its
    threshold, again every day for 90 days. `rc_forgot {a, g}`: holder →
    owner, gone. Helpers on 1.16.4 and earlier ignore it and keep their
    pieces.
  - `rc_help {}`: a recovering device tells a holder (whose invitation code
    the person typed there) that it asks for help. A device holding a piece
    of that account stores the request (at most 8, 30 days, once per
    sender) and shows a notification and a card with *Help* (the new
    device's address filled in) and *Decline*. A device holding no piece
    ignores it.
  - `rc_alarm {to, kind, due, o?}`: holder → owner's devices, when the
    holder agreed to release the piece to a new device (`o`: despite a
    stop). `rc_cancel {a?, at?, cert?, sig?}`: owner's device → holder ("to
    nie ja"), signed (`"zen-recovery-cancel|" a "|" at`); it counts only
    from a device the account has not cut off (an unsigned one, from 1.16.4
    and earlier, only for the pieces that address handed out, and not from
    an address its owner unlinked). Seven days after a stop
    (`kOverrideDelay`) the holder may release anyway; a stop then no longer
    counts.
  - `rc_piece {kind, half, more?, account}`: holder → new device, 24 hours
    after the holder agreed (`kNormalDelay`; the `emergency` half after 7
    days). `more` carries the holder's previous generation, kept until the
    new one is complete. The new device takes pieces only while a recovery
    is started on it, only from its friends and the holders the person
    listed there (at most 24), at most two of each kind per sender, 48 in
    all, and only with the Argon2 cost pieces are written with; it tries at
    most 600 combinations of the halves that came.
- **What a holder keeps** (`recovery/pieces`, at most 200 accounts): every
  generation until told to forget it (since 1.17.0; it kept the two newest,
  so two changes in a row dropped the last complete generation, and the
  60-day `kPreviousPieceKept` rule no longer drops one on its own), all of
  them 42 days after the friendship ended (`kPiecesAfterFriendship`; a
  friendship that comes back within it changes nothing). Older generations
  are forgotten only by holders who confirmed the new one (`rc_forget`
  names the generation kept), and a piece forgotten does not come back
  from a device that was away.
- **Fewer holders.** A change that leaves fewer holders (fewer than two
  close friends included, which used to make every holder forget at once,
  with no wait and no password) waits a week (`kReductionDelay`) and tells
  the person; it goes at once only when the person confirms it with the
  account password. A holder not heard from for five weeks does not count
  as having confirmed, so it does not count towards "secured".
- **The account password on every device** (`ledger_identity_store.dart`):
  the account key is kept only wrapped by the account password, on every
  device. The wrapping, signed by the account key and carrying the time it
  was set, travels with the account (a link, a copy, a backup, the paper key)
  and between its devices when the password is set or changed on one of them
  (`takeWrapping`: only one the account key signed, only a newer one; the
  newest password wins); a device that took the account without it offers to
  set one (`offersKeyGuard`). A cut-off device that comes back as a new
  device of the account is not taken by the owner's devices until the person
  says it is theirs; friends cannot tell and accept it (the account key is
  not taken off a cut-off device).
- **Limits.** The delays and the alarm bind honest apps only. Holders of
  one generation who reach the threshold together open the circle box and
  can then guess the account password offline, one Argon2id run per guess.
  People who held pieces of the same generation, kept copies against the
  app and know or guess the password of that time can still open the seed
  together. Pieces handed out before 1.15.4 still hold a working
  `emergency` half (four helpers together, no password); helpers on 1.15.4
  and later never release it, and handing the pieces out again replaces
  them.

**Account moves and links.**

- `al_ver {v: [...], app}` (`account_link.dart`): the answer to a device-link
  hello of another protocol version; both sides show "the other device has
  another version of Zen". Moving an account: the transfer code carries
  `app`; a hello of another version is answered `acx_no {why: "version",
  app}`. Since version 2 of the move (`account_copy.dart`) the new device
  greets with a commitment to its one-time key (`acx_hello {v: 2, c, m,
  n}`), the old device answers the first greeting carrying the code's
  token with a fresh random value (`acx_nonce {r}`), and only then does
  the new device reveal its key (`acx_key {e}`); the 6 digits depend on
  that value, so a device that saw the code cannot pick its key after
  learning what the other screen shows. A code of version 1 (Zen 1.16.x)
  is still read; such a device answers the version 2 greeting with
  `acx_no {why: "version"}`, and 1.16.x finds a version 2 code to be of
  another version: either way the screen says to update first.

### 2.14 The copy with friends (`cbk_*`) [V]

`circle_backup.dart`, `circle_backup_service.dart`, `circle_backup_holder.dart`.
Between the owner's devices and the friends who keep its copy, over the
signal transport:

| type | Direction | Fields |
|---|---|---|
| `cbk_offer` | owner -> holder | `m`: a new manifest |
| `cbk_need` | holder -> owner | `a` account, `mid` manifest id, `ids` chunks it lacks |
| `cbk_chunk` | owner -> holder | `a`, `id`, `c` (one chunk) |
| `cbk_ok` | holder -> owner | `a`, `at`: the copy is complete |
| `cbk_no` | holder -> owner | `a`, `why`: refused (`notInCircle`: neither a key piece of that account nor an accepted friend here, and what a 1.16.4 holder answers anyone outside its circle; `badSignature`; `tooBig`: over one copy's size or no room left; `stale`: older than the copy kept) |
| `cbk_fetch` | recovered device -> holders | `r`: a signed, fresh request |
| `cbk_manifest` | holder -> recovered device | `m`: the copy kept |
| `cbk_get` | recovered device -> holder | `r`, `ids` |
| `cbk_part` | holder -> recovered device | `a`, `id`, `c` |

Every section, and every month of every conversation, is cut into chunks of
at most 192 KB, sealed with ChaCha20-Poly1305 under a key from HKDF of the
account's self key, with a nonce derived from the content (an unchanged
chunk keeps its hash and is not sent again). An encrypted index names the
chunks; the manifest is hybrid-signed by the device, whose certificate the
account key signed. Since the copy is sealed under the self key, every way
back to the account (another device, a key copy on paper or in a file, the
key pieces) opens it.

- **Sections:** `profile`, `contacts`, `levels`, `settings`, `pyramid`,
  `household`, `dating`, `passwords` (the stored vault, `passwords/vault`;
  a switch, "Hasła w kopii u znajomych", on by default and the same on every
  device of the account: off, the friends' copy is replaced at once with one
  without the section)
  and `notes` (the notes to self, `notes/self`), and the conversations' text
  when "with chats" is on (the oldest left out past the cap). `passwords`
  and `notes` are padded with a `z` field to a multiple of 16 KiB, so the
  holders cannot tell how many there are, and are taken back by merging,
  never over what the device has. The `wallet` section is no longer
  written (nothing took it back). The `passwords` section also goes, with
  the key, into a full copy of the account (`.zenbackup`) and into a move
  to another device (`account_archive_collect.dart`).
- **Holders** (`kMaxCopyHolders`, at most 6): chosen accepted friends,
  those who serve as this person's mailboxes first, then close friends,
  others only to reach two (`copyFriendHolders`). A friend who refuses
  (`cbk_no`) is passed over for 7 days and the next is asked. A holder takes the copy of an account whose key piece it
  keeps, or of an accepted friend (friends' copies together at most 60 MB),
  at most 10 MB (+10 %) per account and 100 MB in all; a copy goes when
  neither holds any more (the piece went, the friendship ended). A copy
  whose size is under half of the one kept does not replace it at once: the
  holder keeps the larger previous copy for 30 days. A manifest dated ahead
  of the holder's clock, or signed by a device that was cut off, is refused
  (it used to block every real copy), and the owner is told when friends
  refuse.
- **A phone that is looking for its copy never replaces it with its own.** A
  search that gave up (a copy from a newer Zen, or thirty days without
  finding one) let the new phone make a copy of its nearly empty data, of
  which friends keep only the newest. The search now goes on once a day,
  and a fresh copy from such a phone needs the person's word. An item over
  the size of a part used to fail the whole copy, and a group's item carried
  every name ever seen in it: names are kept for current members only, an
  item still too large is trimmed or left out, the rest is saved, and
  "Dlaczego nie działa?" says how many were cut.
- **Another account never replaces one that holds anything** (a copy, a
  backup file, a link or a key; `account_holdings.dart`): a device with a
  name, notes, passwords, posts, chats or invitations, or an accepted
  friend, a group or a pyramid, is not fresh. The person adds the other
  account beside this one, or wipes this one on purpose after being offered
  a backup; saved passwords go along only when ticked.
- **When:** at most once a day, and after an important change (a friend, a
  group, a password, a note) at most once an hour; only the chunks a
  holder lacks travel. A part that cannot be read now (Zen locked) makes no
  copy, so holders keep the last whole one.
- **Taking it back:** a holder answers `cbk_fetch` only for a device the
  account certified and has not cut off. After a recovery the new device
  asks the holders the recovery named, its friends and the account's other
  devices; a device restored from a key copy alone knows nobody, so the
  person may type one friend's invitation code to reach them. The
  manifests that come within 30 s of the first are compared and the newest
  complete copy is taken; a download that stalls moves to another holder of
  the same copy, or looks again.

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

### 2.16 Pebbles (`pbl_*`) [P]

`lib/src/features/pebbles/` (`pebble_card.dart`, `pebble_hosting.dart`,
`pebble_store.dart`, `pebble_service.dart`). A pebble is a painted stone a
person makes and leaves as a QR sticker; whoever scans it collects it
(collecting takes nothing away). A pebble is immutable: changing it makes a
new one.

**Identity.** `PebbleId` = the first 16 bytes of SHA-256 over
`"zen-pebble/1" || author key (32) || created (u32, big-endian, Unix
seconds) || design bytes`, written in base32 (RFC 4648, lower case, no
padding, 26 characters). The design itself is opaque here (made by the
editor, at most 64 KB); a copy from anyone is checked by recomputing the id
from the card's author and time.

A pebble has two cards: the **full card** (format v1), signed by the
author, which travels with the design, to keepers and in profiles; and the
**QR card** (format v2), only what the web page and the first contact
need, which the sticker's QR code carries, so its modules stay large. The
version byte tells them apart.

**Full card, binary format v1** (all integers big-endian):

| Field | Size |
|---|---|
| version = 1 | u8 |
| PebbleId | 16 |
| author account id (Ed25519 public key) | 32 |
| created (Unix seconds) | u32 |
| shape preset, shape seed, material preset | u8, u32, u8 |
| main colour, second colour (RGB) | 3, 3 |
| name (at most 40 characters) | u8 length + UTF-8 |
| note (at most 100 characters) | u8 length + UTF-8 |
| author's display name (at most 32 characters) | u8 length + UTF-8 |
| thumbnail: 0, or 176 = 16 colours x 3 bytes, then 16 x 16 pixels of 4 bits, rows from the top, the left pixel in the high nibble (index 0 transparent) | u8 length + bytes |
| Ed25519 signature over everything before it, by the author's account key | 64 |

The texts are cut to their limits; the thumbnail is always kept. A card
from elsewhere is taken while it is well formed (at most 852 bytes);
another version, trailing bytes, a text over its limit or not UTF-8, a
thumbnail of another length or base64 with padding is not. The signature
is classical Ed25519 (like an event ticket, §4.1).

**QR card, binary format v2** (not signed):

| Field | Size |
|---|---|
| version = 2 | u8 |
| PebbleId | 16 |
| author account id (Ed25519 public key) | 32 |
| shape preset, shape seed, material preset | u8, u32, u8 |
| main colour, second colour (RGB) | 3, 3 |
| name (at most 24 bytes; cut on a whole letter, ending in "…") | u8 length + UTF-8 |
| author's display name (at most 16 bytes, cut the same way) | u8 length + UTF-8 |

At most 103 bytes. The note, the date, the thumbnail and the signature are
not in it: a finder saves the pebble from the QR card at once (shown with
its look, without a date) and asks for the design; the `pbl_design` answer
carries the full card, which takes the QR card's place only when it has the
same id and author key, holds the author's signature and matches the
design. Until then the pebble is not listed in the finder's profile. The
first test builds put the full card in the QR code; those links are still
read. Shared test vectors of both formats:
`tool/ci/pebble_card_vectors.json`.

**Links.** `https://robertostrowskijagoda.github.io/Zen/k/#<digits>`, the
QR card as one big-endian number in decimal, padded with zeros to the
digits of 256^n - 1 for its n bytes (so the count of digits gives n; a QR
code writes digits in its numeric mode at 3.3 bits each, against 8 bits
per 6 for base64url), and `zen://pebble#<same>`, which opens the collecting
screen in the app. The fragment never reaches the server. Links with the
base64url of a card (either format, no padding) are read too. The longest
QR card makes a QR code of version 8 at error correction M (49 x 49
modules); the printed full card of the first builds needed version 17 to
20. `zen://pebbles` opens the person's pebbles (a keeping request's
notification).

**Signed records** (Ed25519, by the same keys as the card):

- *Keeper list* `{id, v, r?, k, s}`: the author's list of the devices that
  keep the pebble (at most 16 addresses), version `v` (milliseconds, newest
  wins), `r: true` when the author retired the pebble (the list is then
  empty). Signed bytes: `"zen-pebble-keepers/1\n" id "\n" v "\n" (1|0) "\n"`
  followed by the addresses joined by `,`.
- *Found note* `{id, f, at, s}`: the finder's account `f` found the pebble
  at `at` (seconds). Signed bytes: `"zen-pebble-found/1\n" id "\n" f "\n" at`.
  It travels straight from the finder to the author, never through a third
  phone ("Znaleziono", below).

**Frames** (direct, not reliable; an older Zen ignores them, §2.13):

| type | Direction | Fields |
|---|---|---|
| `pbl_get` | finder -> author, keepers, friends | `id`, `a` author account, `h` hops (1 from a finder to its friend, else 0), `o` the asker (set only by a friend passing it on) |
| `pbl_design` | any holder -> asker | `c` full card, `d` design (base64url), `k` newest keeper list known (optional) |
| `pbl_keep_ask` | author -> friend | `c` card, `n` design size in bytes |
| `pbl_keep_yes`, `pbl_keep_no` | friend -> author | `id` |
| `pbl_keep_quit` | keeper -> author | `id` |
| `pbl_keepers` | author -> keepers | `k` a new keeper list (or the retired one) |
| `pbl_found` | finder -> author | `n` a found note |

**Keepers.** A role separate from mailboxes. When a pebble is published,
the author's device draws 6 friends (devices that answer best first,
computers and phones mixed about half and half) and sends each
`pbl_keep_ask`; the person answers a notification ("{author} asks you to
keep their pebble ... It takes n KB."). A friend who agrees answers
`pbl_keep_yes`; the author sends the design and a new signed keeper list to
every keeper. A friend who says no, never answers within 2 days (asked again
every 30 minutes meanwhile), resigns (`pbl_keep_quit`) or is blocked by the
author is replaced by the next draw; the author can also draw again by
hand. The role belongs to the pebble: a keeper keeps serving after the
author removes them as a friend or stops using them as a mailbox. A retired
list makes keepers drop their copy (collectors keep theirs). Only the device
that made the pebble draws and signs; the account's other devices show it
and fetch its design like any copy.

**Serving.** A device hands a design to whoever asks (and is not blocked)
when it is the author, a keeper of a pebble not retired, or a collector who
did not turn off "serve collected pebbles" (on by default).

**Finding a design.** A collected pebble is saved from its card at once and
shown with the card's look; the design is asked for three devices at a
time, 20 seconds apart, in this order: the author's devices (when this
device knows the account: a friend's), the author's device that asked it to
keep the pebble, the keepers of the newest list known, then its friends
with `h: 1`. A friend who cannot serve passes the question on once (`h: 0`,
`o`: the asker) to the author's devices it knows, the keepers it knows and
up to 8 of its own friends, who answer the asker directly. After a full
round the next one waits 1, 5, 15 minutes, then 1, 3 and 6 hours, driven by
the app's wake beat (every 15 minutes). A design is taken only for a pebble
this device wants and only when it matches the full card (for a pebble
collected from its QR card, the full card that comes with it, checked as
above); a keeper list only when the card's author signed it.

**Limits.** At most 30 pebble frames per sender per minute, 60 designs
served per minute, 10 questions passed on per friend per minute (the same
question from the same friend once in 2 minutes); a design is at most
64 KB; `o` is honoured only from a friend; nothing is sent to or taken from
someone blocked. At most 500 pebbles collected, 200 kept for others and 20
keeping requests waiting.

**"Znaleziono".** After collecting, a finder whose account key is at hand
sends a found note to the author's devices when it knows them (best effort,
once); the author counts distinct finder accounts. A note counts only when
the device that sent it is one the author's device knows as belonging to
the account that signed it (a signature alone proves nothing about the
sender: anyone can sign with a key made a moment ago), so a finder is an
account the author knows, in practice a friend's; the author's own account
never counts. Each finder counts once per pebble; one account adds at most
100 new finders a day over all of an author's pebbles
(`kFoundNotesPerDay`); at most 1000 finders per pebble and 20000 in all
are counted (`kPebbleMaxFinders`, `kPebbleMaxFindersTotal`). A note that
changes nothing does not rewrite the index.

**Profile.** The kind `pebbles` in the account's `profile` space, sealed for
all friends (`Audience.all`): `{v: 1, c: [{c: card}], k: [{c: card, f:
found at (ms), n: finder's note}], x: {id: removed at}}` with full cards
only, newest first, at
most 40 KB before sealing (the oldest collected ones are left out first).
Friends see it; followers and friends of friends who hold the entry cannot
open it. A made pebble in it counts only when the account signed it. The
account's other devices take in what it lists, and its removals.

## 3. Layers above the frames

### 3.1 Reliable delivery (`relay_engine.dart`, `reliable_signal_transport.dart`) [V]

- A payload whose `type` is in `kReliablePayloadTypes` (messages and receipts,
  friend lifecycle, groups, profile, meeting features, intro, pyramid, dating
  and neighbours - see the set in the file) gets `_rid` (<=128 chars) and is
  sent directly; the recipient replies `rly_ack {rid}` and de-duplicates by
  `sender|_rid` for 14 days. Types that must go direct only
  (`_directOnlyPayloadTypes`: `friend_request`, `flat_*`) are never mailboxed.
  `_once: true` marks a payload to send once, not queued.
- **Acknowledged once stored:** a chat message (`message`, `group_message`)
  is acknowledged to its sender (`rly_ack`), remembered as seen and taken
  out of the mailboxes only once the app said it has it on its disk
  (`reportReliableKept`). A message the app failed to store (killed in
  between, a full disk, a locked store) is not acknowledged: the sender or
  a mailbox brings it again, and that copy is handed to the app again.
  Further copies wait for the app's word for at most 1 minute
  (`appKeepWait`); after a restart nothing was acknowledged. Every other
  reliable payload is acknowledged as it arrives.
- The payload is written to disk before the first direct attempt. Direct
  retry schedule: 3 s, 10 s, 30 s, 2 min, 10 min, 30 min, 1 h, 2 h, 4 h, then
  every 4 h; any sign of life of the recipient, and a restart or 10 minutes
  of silence, start over. TTL 14 days (`messageTtl`); `lg_push` 7 days and
  `graph_open` 2 days (they come again by other ways).
- **Latest-only kinds** (`relayReplaceKeyOf`): `profile_update`,
  `friend_list`, `nearby_key`, `intent`, `graph_open`, `intro_gate`,
  `zrcpt`, `call_missed` (one per kind and recipient) and `message_read`
  (one per conversation: the receipt names the newest message read). A
  newer one replaces the older one waiting in the queue, and in the
  recipient's mailboxes through the envelope's `rp` tag (3.2).
- **What a person sent and what the app sends by itself**
  (`relayIsPersonalPayload`): the notice types (`message`,
  `group_message`, `message_placeholder`, `friend_request`,
  `friend_accept`, `group_invite`, `call_invite`, `group_call_invite`,
  `call_missed`; `kRelayNoticeTypes`), an attachment, `msg_react`,
  `msg_edit`, `msg_delete`, `disappear_timer` and `profile_update` are what a
  person sent; everything else (posts pushed ahead of the ledger, friend
  lists, nearby keys, statuses, receipts, pyramid records, ...) the app
  sends by itself, and its envelope carries `a: 1` (3.2).
- **Devices taken for gone:** a friend's device not heard from for 7 days
  (`goneDeviceAfter`) while another device of the same friend was is taken
  for gone (a phone they moved away from, one Zen was removed from): what
  the app sends by itself is no longer queued for it, and what waits or is
  held for it of that goes; what a person sent still waits as for any
  device that is away. It is back as soon as it is heard from. A friend who
  is away with all their devices is never affected. Since 1.17.0 **everything
  is personal except the kinds that catch up by themselves**: a group leave,
  a friend removal, a transfer cancel or a board post never reached a
  device that was back after a week, and neither did a voice message, a
  photo or a text over 48 KB, because a blob's manifest was judged by its
  own kind. A mailbox's `zrcpt` is no longer replaced by a newer one, member
  list updates are not counted as invitations waiting, a clock set back no
  longer makes a mailbox refuse newer mail, and a message that can only
  travel directly says so.
- **Receipts for mail** (`zrcpt {ids}`): payloads taken from a mailbox
  while their sender did not answer (its `rly_ack` was likely lost) are
  confirmed by one receipt queued for the sender's mailboxes; a receipt
  still waiting takes new ids in and replaces the older one. The relay
  layer's own, never handed to the app; a Zen before 1.16.5 opens it,
  confirms it and ignores it.
- **Tidied at start:** when the relay engine takes over (an app start, the
  locked service), what lapsed, was replaced by a newer one, waits for a
  device taken for gone or for a friend's device its owner unlinked, or is
  for a former friend goes, the queue of an older version included (log
  line `Relay tidy`).
- **"Czeka na doręczenie"** counts what a person sent (the notice types
  and attachments) that has not reached its recipient yet, once per message
  and person however many devices or parts, and not once one device of
  theirs has it.
- Reactions, edits and deletions (`msg_react`, `msg_edit`, `msg_delete`),
  group board posts (`group_post`), `lg_push`, `lg_mention`, `call_missed`,
  `date_key` and `date_intro*` are reliable too.
- Calls (but `call_missed`), typing, presence and file chunks are not
  reliable.

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
  (ciphertext+tag), k? (1 when the payload deserves a notice on a locked
  phone, `kRelayNoticeTypes`), rp? (replace tag), a? (1 on what the app
  sent by itself)}`, all base64url; sealing in section 4 ("Mailboxes").
  `k`, `rp` and `a` are bits beside the box, not bound into it. `rp` is
  set on the latest-only kinds (3.1): base64url of the first 12 bytes of
  HMAC-SHA256(sender's relay key, `"zen.relay.replace.v1|" + recipient +
  "|" + kind`), the same for every payload of that kind to that recipient,
  a tag only the sender can make; a mailbox that holds an older envelope
  of the same sender with the same tag drops it when the newer one comes
  from the sender itself (a co-relay catching up only ever adds), and does
  not take an older one. A mailbox drops what carries `a` for a device
  taken for gone and keeps the rest. Envelopes from a Zen before 1.16.5
  carry neither.
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
  by the same rules, and writes what it holds back to a file of its own
  (once for a burst of deposits or receipts, within 5 s, not once per
  envelope), which the app merges after unlock (`relay_engine_locked.dart`).
  Attachments (`rly_bput`...) wait for the unlock. A locked iPhone runs the
  same receiver whenever iOS lets Zen run (a background check, a Shortcuts
  run, the keep-alive; docs/IOS_BACKGROUND.md), so it answers the same
  frames then.
- **What a locked phone reads.** It keeps every frame sealed to the inbox
  key (hybrid ML-KEM-768 + X25519, derived from the master key; only its
  public half is with the receiver) and reads a chat message only in
  memory, for a notification of at most 80 characters as the conversation's
  notification level allows (docs/SECURITY_MODEL.md, "The locked phone").
  Whether a chat message or a call makes it ring, show the call card or
  tell of a message is decided by the same functions as in the app
  (`notification_privacy.dart`, `incomingAlertOf`), from the notice kit the
  app leaves it (sealed with the background key): nothing with
  "Połączenia" off; a call only from a friend, a group call only from
  someone who speaks in that joined group; a mention past a mute only from
  a member, at most 5 per sender in 10 minutes; muted conversations; the
  group id as the app reads it. Who speaks in each joined group is in the
  kit as tags (`gt`: the first 32 hex of SHA-256(`group key + "\n" +
  address`), unkeyed), so the kit names no member. What the kit does not
  know counts as "no". A kit written before 1.16.5 has no tags: until the
  app is unlocked once and writes a new one, the background capability's
  friends and group members count, as before.
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
  A holder may prune a log (`pruneBefore`), only at a checkpoint; 1.12.0
  can read both. From 1.16.5 a checkpoint may say in its body how many
  entries right after it carry everything of the log still valid from
  before it (`n`, at most 400, `kMaxRebaseEntries`; written in one run with
  them, so no peer ever sees only some). Every holder moves to such a
  checkpoint, and drops what came before, only once all those entries are
  held here too: a peer handing on the checkpoint alone cannot make a store
  give up the last whole state it holds. A checkpoint without `n` is
  dropped from only by its own writer's devices. Builds before 1.16.5
  ignore `n`. Two logs are started over this way:
  - **The private log** (`private/<acct>`, friends keep a copy): a device
    starts it over when the superseded copies of friends and groups in it
    outweigh what is still valid by more than 64 KiB
    (`kPrivateLogSlackBytes`); after the checkpoint come the current
    backup and the removals made before it (`contact_removals {v, x:
    {address or group:<id>: millis}}`). Friends drop what came before once
    the new start has fully reached them, by that device's signed word
    only.
  - **The state log** (in `own`, a writer of its own per device,
    `ledger/state_writer`), see "Account states" below.

  The public logs (`feed`, `acts`, `profile`) are never started over or
  pruned: other people's entries refer to their ids.
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
  `contacts`, `contacts_part`, `contacts_set`, `contact_removed`,
  `contact_removals`, `chat`, `chat_history`, `acct_state`, `checkpoint`;
  for the Videos
  section `film` (in `feed`, removed by `post_del`), and in `acts`
  `film_react` (the latest per film wins), `film_seen` (`posts`: film ids the
  author counts) and `film_pass` (a public film passed on to friends of
  friends: the signed film with its certificate, like a reshare); in
  `acts` also `post_ann` (notices of posts passed on beyond friends, below).
  An `rx` bundle passes on the reactions a friend saw under posts, with the
  thread's hidden comments and blocked people (`hid`, `blk`) and totals
  (`nl`, `nc`); a bundle is signed only by the friend who wrote it, so a
  reader takes `hid`, `blk`, `nl` and `nc` only from the bundle of the
  post's author, and from anyone else's only the reactions it lists
  (`reaction_relay.dart`, `feed_model.dart`).
- **Friends' copy** [V]: a `contacts` entry (sealed in `private`, for the
  account's own devices) is {`v` 1, `friends` [{`a`, `n`?, `k`? nickname,
  `b`? 1 when blocked}], `groups`, `r`? records}. `r` maps each normalized
  address to `[mark, clock, device]`: mark `f` friend, `b` blocked, `x`
  removed, `n` neither (unblocked); clock a hybrid logical clock
  (`millis << 16 | counter`); device the writing device's address. Devices
  merge `r` address by address, the later record winning (clock, then
  device, then the stronger mark on an exact tie); a record dated more than
  10 minutes ahead is refused. A friend record is only ever made by an
  invitation answered (`FriendshipBook`, `friendship_book.dart`); a device
  that holds a record the newest copy lacks or has older saves its own
  copy. A copy without `r` (Zen 1.14.0) counts its friends as of unknown
  time (older than any record) and its blocks as of the copy's time;
  `contact_removed` {`a`} or {`g`} entries are taken once each as removals at their
  ledger time. A group item (`{id, name, d?, avatar, by, at, m, mn?}`)
  carries `left` (who left and when, the newest that fit a part), so a
  device restored from the copy starts with it (2.4); Zen 1.16.4 ignores
  it.
- **Friends' copy in parts** (`contacts_backup.dart`): up to 40 KiB of
  JSON (`kContactsWholeBytes`, some 240 friends) the copy is one
  `contacts` entry. Above that every friend, group and record is an item,
  and the items run into `contacts_part` entries `{v, i}` (at most 32 KiB
  each, at least 8 KiB; a part ends after an item whose hash says so, so a
  change to one friend rewrites one part), followed by a `contacts_set`
  entry `{v, k: the layout of the top-level keys, s: the other values, p:
  the parts' places in the same log, h: SHA-256 of the whole}` (at most
  256 parts). A new set writes only the parts that changed and names kept
  parts only from after the log's newest checkpoint. A reader takes a set
  only when every part is there and the whole hashes right, so it never
  mixes two copies, and takes the newest copy that came whole. A one-entry
  copy carrying `cut` (only some of the friends and groups, for builds
  before 1.16.5 that read only one entry) is never taken for the whole. A
  copy that cannot be saved at all (an item bigger than a part, more than
  256 parts) is told in "Dlaczego nie działa?".
- **Account states** (`account_state_sync.dart`, `acct_state` entries sealed
  in `own`, so only the account's devices read them): the states kept the
  same on all of an account's devices (the account's settings, the
  hand-picked mailboxes `relay`, the dating profile, the meetings
  `meet/*`, the profile, the key pieces' bookkeeping `recovery`, the notes
  to self `notes/self`, the passwords `passwords/vault`, and copies kept for
  a recovery). Every state is cut into units (a field, a list item by
  `id`, a set element, a map entry); a unit changed gets the next Lamport
  clock of its device and is taken elsewhere when its clock is higher (or
  equal from a device whose id sorts higher); a removed unit leaves a
  tombstone. A change goes in parts of at most 24 KiB of units
  (`kAccountSyncPartBytes`), so a large state is never refused for the
  64 KiB entry limit. Each device writes these into a **state log** of its
  own and starts it over at most every 6 hours (`kAccountSyncRebaseEvery`),
  only when something was overwritten or deleted since: a checkpoint, every
  unit as it is now and the deletions of the last 30 days
  (`kAccountSyncTombstoneLife`) written again after it, and everything
  before it dropped there and, once they take the checkpoint, on the
  account's other devices; so an overwritten or deleted value (an old
  password, a deleted note) leaves the log within about that time. A device
  away longer than 30 days gets the state as it is now; deletion markers
  inside the passwords and notes keep a deleted entry from coming back.
  The dating profile, the profile and the meetings `meet/*` keep no
  markers of their own: their deletions are written again after every
  checkpoint also past those 30 days, the newest (by clock) first, up to
  24 KiB of them per state (`kAccountSyncMarkerBytes`, as much as the
  removed friends and groups carried over a start of the private log), so
  a device away longer takes them instead of keeping, and passing on, what
  was deleted (a dating profile switched off, a photo, a plan). A thing made
  again after its deletion has a higher clock and is never undone by one.
  Changes opened from other devices are forgotten when Zen locks and
  opened again at unlock. A device that never had notes or passwords
  stores an empty set, so the others' arrive there. A Zen of 1.16.4 keeps
  its old log as it was.
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
`acts`: {`address`, `name`, `pq`}) name the key too; they are the
account's word about an address, not the device's, so for the receiver
they are hints only (1.5), held before the first direct contact and
confirmed by the device's own record. Friend lists
(`friend_list` items {`a`, `n`, `k`}) carry the keys friends proved; for
the receiver they are hints too (1.5: the first record of the device
itself decides, and a contradicting hint is only logged); `lg_keys` {`items`} gives audience
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
  `appans`, `bench`, `seal`, `vclose`, `alarm`, `offer`; `xfer`, `settle`
  and `xrel` exist as kinds but the fold refuses them: transfers and
  releases are private (2.11). The genesis names the power key
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
- **The court without names** (`pyramid_court.dart`). Who may judge a
  matter (a complaint's first instance or one appeal) is fixed by the
  rules (`courtRing`): below the top the head at the deciding place, at
  the top the top cell, never the parties. Each judge's phone registers a
  one-time hybrid card for that matter with the others (scope `bench:` +
  SHA-256(pyramid|matter|judges)[:32]); `bench` {`of` the complaint or
  appeal, `toks` the cards} lists them and is signed by the judges like a
  cell's ballot (every judge of the ring listed, at least as many signers
  as cards, at least as many cards as a decision needs; a later bench of
  the same ring counts only with more cards, a changed ring needs a new
  one). A `verdict` or `appans` is signed by the bench's cards only, never
  by a member's key, and carries `by` (the bench's cards), `q` (how many
  it takes: 1 below the top, 2 at the top) and no more signatures than
  `q` (those of the lowest keys), so the record says that the court
  decided, not who or how many agreed. A judge's signed decision goes to
  the other judges, and once it carries `q` cards it is published through
  a friend outside the court; nothing of the court's way passes through
  the parties' phones. The screens and the history name the court of a
  level, never a person. Limit: a court of one person (every level below
  the top) is known by its seat.
- **Seals of the treasurers' eras** (`seal`, `PyrSeal`): an era is a span
  in which the treasurers stayed the same. One hour after an era ended
  (`kPyrSealWaitMs`, and 10 minutes after the treasurer last offered its
  ledger to the others) each treasurer of the next era that keeps the
  whole ledger signs {`n` era number (1: the founder's), `prev` the seal
  before, `from`, `to`, `set` the era's treasurers, `ops` the ids of the
  private operations dated in it that counted, `ch` what changed the
  treasurers at `to`}, dated `to`, `by` the next era's treasurers; equal
  ledgers give equal records, and the signatures meet as it goes round.
  The seal that counts for an era is the first well-formed one (earliest
  end, then id) that follows the seal before, is signed by most of the
  next treasurers and agrees with the tree; a treasurer that signs two
  different seals of one era is shown with both. A sealed era is fixed for
  every phone: its treasurers are the sealed ones, an operation dated in
  it that the seal does not list counts nowhere, a change of the tree that
  would change the treasurers inside it (or at its end, not among `ch`) is
  taken as made after the seal and folds after the last seal, and any
  other record that would change it is refused. Limits: a seal lists at
  most about 30000 operation ids (the 2 MiB record limit) and cannot be
  published with more than 100 next treasurers (`kPyrMaxSigners`); until
  an era is sealed (at least an hour after its end) its past can still
  move; sealing stalls while the treasurers' ledgers disagree.
- **Late records** (`PyrT.foldedLate`, `kPyrLateMs`, 30 min): the timed
  kinds (below), a change of the tree at the treasurers' levels (or right
  below them) and a cell vote's ballot and votes, seen by a phone more than
  30 minutes after their date, fold at the time that phone saw them, so
  they cannot move a past set of treasurers or turn a vote that ended; the
  seals and the closes then fix the same on every phone.
- **Closing a cell vote** (`vclose` {`elect` the vote, `votes` the ids of
  the votes that count}, dated at the vote's end, `by` its ring): once a
  vote ended by time, each ring member's app signs the votes that had come
  to it; equal views give equal records. The first close (by time, then
  id) listing every member of the ring and signed by most of them counts;
  a vote it does not list counts nowhere, whenever it comes. A vote where
  every card voted before the end needs no close.
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
| Recovery | the seed sealed under the account password (Argon2id 64 MiB, ChaCha20-Poly1305), sealed again per generation under a random secret split by Shamir over GF(256) among the close friends (2/3/4 of up to 12, 2.13a); the copy with friends sealed under the self key (2.14) | `core/ledger/shamir.dart`, `account/account_recovery.dart`, `account/recovery_service.dart` |
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
  backup, key pieces at close friends) hold the seed only and restore both halves.
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
   (`ZENACCT2…` or a manifest `v > 1`), the copy with friends and the encrypted
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
   alarm wave `v:6`, BLE hello `v:7`, the door code `v` (3; a code with
   `v >= 3` and unknown fields is read, and its `mv` field names the oldest
   reader, so a newer version can make older ones ask to update) and the
   sticker link's format 2 (its first byte; unknown records are skipped, a
   higher format asks to update, §2.7), dating
   KDF/AAD labels `*.v1`, mailbox and inbox labels `*.v2`, the hybrid
   signature's `zen.sig.v1` and its ML-DSA derivation label
   `zen.sig.mldsa65.v1`, the session layer's `ZPQ1` and key record version 1, blob manifest
   `chunk` size, `profile_update.v` (monotonic counter), relay announcement
   version `v`, recipient keys `v: 1`, the stored pins `v: 2` (1.5), a key
   piece's `normal` half `v: 2` (2.13a), the contacts set and parts `v: 1`
   (3.3), the password vault format 1, and the single-instance handshake's
   `ZEN-SINGLE-INSTANCE/3` (1.7).
14. Fields added in 1.16.5 that older builds ignore: the envelope's `rp`
    and `a`, `group_invite` `added` / `at` / `left`, `group_leave` `at`,
    `msg_react` / `msg_delete` `author`, the checkpoint's `n`, the notice
    kit's `gt`; new types `call_missed`, `zrcpt`, `rc_forget`,
    `rc_forgot`, `contacts_part`, `contacts_set`, `contact_removals` and the
    mirrored `group_read`, and the pyramid's `seal`, `vclose`, `bench` and
    private `xrel` (the pyramid rules version `rv` stayed 1).
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
  is trust on first use (a friend's friend list or device record gives only
  a hint), and the pin it makes stays loose until a session with that
  device opens or a hybrid-signed hello vouches for it.
- Yggdrasil answers `debug_remoteGetPeers/Self/Tree` and NodeInfo to any
  node from `Core.ReadFrom`; Zen's packet loop reads below it
  (`readMeshTraffic`) and drops them unanswered, as the doors do, so a
  node's direct peers (friends linked over Wi-Fi or Bluetooth among them)
  are not listed to strangers.
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
