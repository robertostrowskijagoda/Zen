# Zen protocol specification (draft, from the code of 1.10.0)

*Written 20.10.2026 by reading the code. Not a standard; the code is the
reference. Markers: **[V]** read directly in code and consistent; **[P]**
partly verified (shape known, details not all read); **[?]** uncertain or not
read - check the file named. Field names are the JSON keys on the wire.
Constants are quoted with the file that defines them.*

Companion documents: [PRIVACY.md](PRIVACY.md), [DPIA.md](DPIA.md). Plan:
`PLAN.md` (Polish).

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
  and links between peers use TLS / QUIC / WS / TCP as configured.
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
- Peering: a built-in list of public peers (`public_peers.go`; Android starts
  with a TLS-only subset), optional LAN multicast (off by default), desktop
  inbound listener `tls://[::]:32913` [V], UPnP / NAT-PMP port mapping and
  "bridge" announcements in the ledger (`lg_bridges`).

### 1.2 Signal datagrams [V]

Application frames ("signals") are UDP-style datagrams inside the mesh,
built and parsed by hand in `bridge_signaling.go` (IPv6 header + UDP header,
UDP checksum computed, hop limit 64).

| Item | Value |
|---|---|
| Signal port | **54321** (`yggSignalPort`) |
| Call-media relay port | **54322** (`yggRelayPort`) |
| Fragment size | 1300 characters of base64 (`signalChunkSize`) |
| Largest signal | **2 MiB** (`maxSignalPayloadBytes`; Dart: `kRuntimeSignalMaxBytes`) |
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
Media keeps WebRTC's own DTLS-SRTP.

### 1.4 Frame model [V]

After reassembly the Dart side parses the JSON object:
`SignalTransportFrame {from, payload (Map), receivedAtMillis}`. The sender's
address (`from`) is the authenticated mesh source, not a field in the payload.
Every frame has a string `type`. Frames from non-friends are mostly ignored
(see per-type notes). Size caps on strings are applied by the parser
(`runtime_signal_parser.dart`).

## 2. Frame types

Direction is sender -> recipient unless stated. "Reliable" means the type is in
`kReliablePayloadTypes` (section 3.1).

### 2.1 Presence

| type | Fields | Notes |
|---|---|---|
| `ping` | optional hello: `mf`, `mk`, `ms` | Every 45 s (default) to each accepted friend and group member. Not answered unless the sender is a friend or group member. |
| `pong` | `state` (`"foreground"` or other), hello fields | Reply. Hello fields (friends only): `mf` short digest of the friend list sent, `mk` digest of the nearby secret, `ms` time the current status was set (0 if none or not visible). The receiver asks again for what does not match with `meet_req`. |
| `typing` | `isTyping` (bool) | Real-time, not reliable. |

### 2.2 Friends and profile

| type | Fields | Notes |
|---|---|---|
| `friend_request` | `senderName`, `message` (<=1000 chars) | Reliable, direct only (no relay: recipient unknown). |
| `friend_accept` | `senderName` | Reliable. |
| `friend_reject`, `friend_cancel`, `friend_remove` | - | Reliable. A `friend_remove` without a user decision (old peers' automatic reply) is recognised by `isUnconfirmedFriendRemovePayload` and does not end a friendship. |
| `profile_update` | `v` (profile `updatedAtMillis`), `name`, `status`, `bio`, `avatar` | Reliable. `v` is monotonic. Names limited to 60 characters locally, 64 on receipt. |
| `friend_list` | `l`: list of `{a: address, n: name}`, `d`: sha256 hex digest of the list | Reliable. Sent per friend according to the audience for the friend list; an empty list with the empty-list digest means "forget it". |
| `meet_req` | `w`: list of `"l"`, `"k"`, `"s"` | Asks again for the friend list, nearby key or status. |
| `nearby_key` | `k` (base64url secret) | Reliable. Lets the friend recognise this phone's Bluetooth tokens. |
| `intent` | `s`: `{k, at, until, note?<=140, close?, e?}` or absent | Reliable. A "na teraz" status; absent `s` clears it. |

### 2.3 Messages

| type | Fields | Notes |
|---|---|---|
| `message` | `msgId`, `senderName`, `text`, `messageType` (`text|image|file|voice|video`), `attachmentData` (base64), `attachmentEncoding`, `fileName`, `mimeType`, `attachmentSizeBytes`, `durationMs`, `createdAt` (sender clock, ms), `ttl` (seconds) | Reliable. One of `text`, `attachmentData` required. GIFs travel as ordinary image attachments. Frames up to 48 KB can be mailbox-relayed (section 3.2); the signal limit is 2 MiB. |
| `message_placeholder` | as `message` plus `chunkCount`, `chunkIndex`, `attachmentTransferBytes` | Announces a large attachment sent in chunks. |
| `message_chunk` | `msgId`, `chunkIndex`, `chunkCount`, `chunkData` (base64), + placeholder fields | Not reliable; has its own protocol. Never compressed (high-entropy). |
| `message_chunk_ack` | `msgId`, `chunkIndex` | |
| `message_ack` | `msgId` | Delivery acknowledgement of a message (reliable). |
| `message_read` | `msgId` | Read receipt (reliable). |
| `message_transfer_cancel` | `msgId` | Reliable. |
| `transfer_offer` / `transfer_answer` | `transferId`, `description` (WebRTC SDP map), + file fields (`fileSize`, `fileName`, `mimeType`, `messageType`, ...) | File transfer over a WebRTC data channel [P]. |
| `disappear_timer` | `groupId?`, `seconds` (0 = off), `at` | Reliable. Same `ttl` is carried by messages. |

### 2.4 Groups

Groups are fan-out: the sender sends the frame to **each member** individually
(at most 256 members, `kMaxGroupMemberCount`). Every group frame needs `groupId`
(<=256 chars).

| type | Fields | Notes |
|---|---|---|
| `group_invite` | `groupId`, `groupName` (<=100), `description` (<=1000), `memberAddresses`, `avatarPreset`, `senderName`, `inviteId` | Reliable. `inviteId` is a nonce: re-sends of the same invitation do not revive a declined group. |
| `group_invite_ack` | `groupId` | Reliable. |
| `group_message` | `groupId`, `groupName`, `msgId`, `text` (<=64k chars), `senderName`, `timestamp`, `ttl` | Reliable. |
| `group_leave` | `groupId` | Reliable. |

### 2.5 Calls (signalling) [V]

Not reliable (real-time). `kind` is `"audio"` or `"video"`; most carry `callId`.

| type | Fields |
|---|---|
| `call_invite` | `callId`, `kind` |
| `offer` / `answer` | `callId`, `kind`, `description` (SDP map) |
| `ringing`, `call_accept` | `callId`, `kind` |
| `call_decline`, `busy`, `hangup` (alias `call_end`), `call_offer_request` | `callId`, `kind` (`callId` mandatory for decline/busy/hangup) |

Media: WebRTC, relayed through the local bridge relay (1.3). Screen share and
recording are signalled inside the call [?].

**Group calls** (`groupId` and `callId` mandatory): `group_call_invite`,
`group_call_join`, `group_call_state`, `group_call_leave`, `group_call_decline`,
`gc_offer`, `gc_answer` with `groupName`, `kind`, `participants` (address list),
`description` (SDP), `senderName`, `camera` (bool).

### 2.6 Meeting features (all reliable) [P]

Handled by `meet_service.dart` and the sub-services. Only friends are
accepted (parkable types wait for the friendship to settle).

- **Alarm**: `alarm` {`id`, `at`, `lat`, `lon`, `acc`, `locAt`, `note`, `resp`
  (map friend -> answer), `end`, `duress`, optional `cf` (please confirm)};
  `alarm_resp` {`id`, `r`}; `alarm_ack` {`id`, `k`: `got` or `seen`, ...};
  `alarm_audio` {`id`, `n`, `at`, `ms`, `d` (base64 sound piece)}. Limits:
  sound piece <= 200 KiB, <= 6 pieces per alarm.
- **Events**: `event`, `event_rsvp`, `event_plus1`, `event_pass`, `event_photo`,
  `event_thanks` (ticket QR prefix `zen-ticket:`) [?] fields.
- **Questions**: `ask`, `ask_answer`. **Table / circles**: `table_wish`,
  `circle`, `circle_swap`, `circle_guest`. **Weekend plan**: `weekend_plan`,
  `weekend_plan_ans`. [?] fields in the respective services.
- **Introductions** (`intro_*`): `intro_ask` (X asks friend F for an
  introduction to Y, a letter for Y, or F's friend list), `intro_fwd` (F to Y),
  `intro_ans` (Y to F), `intro_res` (F to X, field `s` = status) [P].

### 2.7 Neighbours (`flat_*`) [?]

`flat_hello`, `flat_nope`, `flat_profile`, `flat_get`, `flat_msg`,
`flat_signup`, `flat_signup_ok`, `flat_house`, `flat_join`, `flat_leave`,
`flat_moved`, `flat_kick`, `flat_rekey`, `flat_newkey`, `flat_reveal`
(`neighbors_service.dart`). They are reliable but sent only directly (flats are
usually not friends): a door QR gives a "door secret" that authorises
`flat_hello`.

### 2.8 Dating (`date_*`) [P]

Only between friends, except the flooded lantern.

| type | Notes |
|---|---|
| `date_lantern` | `{id, hops, path, l}`: a lantern (a decoy when dating is off) flooded to friends, `kDatingMaxHops = 2` (`hops` starts at 1). `l` is `{v:3, k: dating key, h: base64url of 6 bytes: age, gender, min age, max age, gender mask, steps}` (`DatingLantern`), about 100 bytes. |
| `date_back` | A `DatingBox`-sealed message travelling back along `path` (profile request `fetch` / answer `prof`, replies, "Yes" token). The `prof` answer carries the profile or a cover, padded to 4096-byte buckets. |
| `date_ask`, `date_ask_re` | "What do you think about X?" and the answer, between friends. |
| `date_vouch_req`, `date_vouch` | Ask for / give a few words for a profile. |
| `date_safe`, `date_safe_ok`, `date_loc_req` | "I'm going on a date", "All OK", a one-shot location request. |

### 2.9 Relay mailboxes (`rly_*`)

See 3.2. Types: `rly_ack`, `rly_announce`, `rly_announce_ack`, `rly_deposit`,
`rly_deposit_ack`, `rly_poll`, `rly_mail`, `rly_mail_ack`, `rly_purge`,
`rly_sync`, `rly_sync_want`. Anything starting with `rly_` is consumed by the
relay engine and never reaches the app layer.

### 2.10 Ledger (`lg_*`)

See 3.3. Types: `lg_hello`, `lg_keys`, `lg_bridges`, `lg_reach`, `lg_reach_ok`,
`lg_sibling`, `lg_heads`, `lg_want`, `lg_entries`, `lg_revoke`,
`lg_blob_want`, `lg_blob_manifest`, `lg_blob_chunk`.

### 2.11 Pyramid (`pyr_*`)

See 3.4. Types: `pyr_hello`, `pyr_rec`, `pyr_recs`, `pyr_ids`, `pyr_want`,
`pyr_wantall`, `pyr_prop`, `pyr_sig`, `pyr_vote`, `pyr_pay`, `pyr_paysig`,
`pyr_report`, `pyr_appeal`, `pyr_anon`, `pyr_dm`, `pyr_fx`.

### 2.12 Nearby (Bluetooth LE, Android) [V]

Not Yggdrasil. Implementation: `ZenNearbyBridge.kt`, `nearby.dart`,
`nearby_crypto.dart`.

- **Advertisement**: BLE manufacturer data, company id `0xFFFF`, bytes
  `"ZN"` (`0x5A 0x4E`) + a **16-byte token**.
  `token = HMAC-SHA256(secret, "zen-nearby|" + epoch)[0..16]`, `epoch =
  unixMillis / 15 min`. The `secret` is the 32-byte nearby secret given to friends
  in `nearby_key`; only friends can link a token to a person; it changes every
  15 minutes.
- **GATT server**: service `5a454e00-6e65-6172-6279-000000000001`, one
  writable characteristic `5a454e00-6e65-6172-6279-000000000002` ("wave"),
  no pairing. Writes up to 600 bytes (long writes are assembled). A phone may
  send at most 6 waves per minute and the radio accepts 40 per minute; signed
  alarm waves from friends have a separate budget of 60 and are admitted once
  per minute per wave.
- **Wave** = UTF-8 JSON, field `v` selects the kind:
  - `v: 6` alarm wave: `{v:6, id, at, end?, t?, m?}`; `t` = the pair's id at
    `at` (hex), `m` = `HMAC-SHA256(pairKey, "zen-nearby-alarm|6|" + id + "|" +
    at + "|" + (end?1:0) + "|" + t)[0..16]` (hex). Accepted only if `at` is
    within +/-10 minutes and the MAC verifies for a friend's pair key; an
    unsigned (told to everyone) or unverified wave is only shown as a quiet
    note. Other versions are not read.
  - other `v`: handed to registered handlers (flat invitations, crisis
    announcements) [?] formats.

### 2.13 Frame the app ignores [V]

Unknown `type`, or a type the parser does not map, yields no signal
(`zenSignalFromTransportPayload` returns `null`; relay engine returns `false`).

## 3. Layers above the frames

### 3.1 Reliable delivery (`relay_engine.dart`, `reliable_signal_transport.dart`) [V]

- A payload whose `type` is in `kReliablePayloadTypes` (messages and receipts,
  friend lifecycle, groups, profile, meeting features, intro, pyramid, dating
  and neighbours - see the set in the file) gets `_rid` (<=128 chars) and is
  sent directly; the recipient replies `rly_ack {rid}` and de-duplicates by
  `sender|_rid` for 14 days. Types that must go direct only
  (`_directOnlyPayloadTypes`: `friend_request`, `flat_*`) are never mailboxed.
  `_once: true` marks a payload to send once, not queued.
- Direct retry schedule: 3 s, 10 s, 30 s, 2 min, 10 min, 30 min. TTL 14 days
  (`messageTtl`).
- Calls, typing, presence and file chunks are not reliable.

### 3.2 Mailboxes (store and forward) [V]

If a direct send is not acknowledged within 4 s, the payload is **sealed for
the recipient** and deposited with up to 6 friends the recipient chose as
relays.

- `rly_announce` {`pk` (X25519 public key, base64url), `relays` (<=6
  addresses), `v` (monotonic version), `tk` (deposit token), `dk` (deposit key,
  only to the recipient's relays)} -> `rly_announce_ack {v}`. Only accepted
  from friends (and group members when sharing is on).
- `rly_deposit` {`env`: envelope, `tk`?} -> `rly_deposit_ack {id, r}`.
  **Envelope**: `{id, s (sender), r (recipient), c (created ms), x (expires
  ms), e (ephemeral pubkey), n (12-byte nonce), b (ciphertext+tag)}`, all
  base64url.
- `rly_poll` (recipient asks a relay) -> `rly_mail {items:[envelope...]}`
  (batches up to ~6 KB). Recipient answers `rly_mail_ack {ids}`; it also tells
  other relays with `rly_purge {ids}`.
- `rly_sync {r, ids, t (tombstones), all}` and `rly_sync_want {r, ids}` keep
  co-relays in step.
- Limits: payloads up to 48 KB, 300 messages / 100 per sender / 2 MB per
  recipient, unvouched strangers 30 messages / 256 KiB per recipient and 10 per
  /64, clock skew 1 day, 5000 seen and 5000 tombstones. Polls every 5 min,
  relay sync every 10 min.
- A deposit is accepted only from the claimed sender or from a co-relay. A
  deposit token (`HMAC-SHA256(depositKey, "zen.relay.deposit-token.v1|recipient|sender")`
  truncated to 16 bytes, where `depositKey = HMAC-SHA256(identityPrivate,
  "zen.relay.deposit-key.v1")`) proves the sender is someone the recipient
  announced to.
- **[?] Work in progress:** `relay_crypto.dart` now also contains
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
  "device":"<b64url ed25519>", "cert":{DeviceCertificate}, "sig":"<b64url>" }
```

- `id = sha256hex(canonicalJson(unsigned entry))`; `prev` is the `id` of the
  previous entry of the same log, so the log is a hash chain. Two different
  entries with the same `seq` prove a fork.
- **Canonical JSON**: object keys sorted, no whitespace, integers only
  (floating point is refused), text via standard JSON string escaping.
- `sig` = Ed25519 by the **device key** over the canonical unsigned bytes.
  `cert` = `{t:"dev_cert", account, device, name (<=60), issued, sig}` signed
  by the **account key**. A `DeviceRevocation` = `{t:"dev_revoke", account,
  device, cutoffs:{"writer@space": lastValidSeq}, issued, sig}` cuts a stolen
  device off (later entries are refused).
- `hlc` = hybrid logical clock `(millis << 16) | counter`; entries more than 10
  minutes ahead of the receiver's clock are refused.
- Size: whole entry <= 64 KiB; `space` <= 200 chars; `kind` <= 40; <= 32 blobs.
  Media never goes inside an entry; it is named by blob hash.
- **Spaces** (owner-only write, `AccountSpacePolicy`): `feed/<acct>`,
  `acts/<acct>`, `private/<acct>`, `profile/<acct>`, `own/<acct>`; and `power`
  (closed, nobody may write yet). Unknown spaces are refused. Public spaces that
  anyone may read: `feed`, `profile`; `private` and `own` are sealed to the
  account's own devices.
- **Kinds seen** [P]: `post`, `post_edit`, `post_del`, `reshare`, `comment`,
  `like`, `rx`, `thanks`, `gallery`, `gallery_del`, `profile`, `device`,
  `contacts`, `contact_removed`, `chat`, `chat_history`.
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
| `lg_revoke` | `items`: list of revocations |
| `lg_blob_want` | `id`, `chunks`: list (empty = ask the manifest; <=64 hashes served per message) |
| `lg_blob_manifest` | `id`, `manifest` |
| `lg_blob_chunk` | `h` (chunk hash), `d` (base64) |

Rate limit 3000 messages/min; frames from non-friends are limited to 30/min per
/64 (`kStrangerFramesPerMinute`). Every received entry is checked (structure,
signature, certificate, space policy, revocation, clock) and every blob chunk
against its hash; friends may push, strangers only answer what we asked.

**Account and device frames** (`ledger_node.dart`): `lg_hello` {`cert`}
introduces an account's device to a friend; `lg_keys` {`items`} gives audience
keys; `lg_sibling` {`own`, `levels`} syncs the account's own devices;
`lg_bridges` {`items`: signed bridge announcements} passes known mesh bridges;
`lg_reach` {`id`, `uri`} / `lg_reach_ok` {`id`, `ok`} ask a friend to test that a
computer's address can be reached from outside (4 checks/min).

### 3.4 Pyramid records (`pyramid_record.dart`, `pyramid_service.dart`) [P]

Every change of a pyramid is one **signed record**; the state is the fold of
the records.

```
record = { "b": body, "s": {signerKey: signature}, "r": ringSignature?, "ts": {treasurerKey: signature}? }
```

- `body` is canonical JSON (same rules as the ledger); the record `id` is the
  sha256 of the canonical body; signatures are Ed25519 over the canonical body.
  Limits: <= 2 MiB, <= 100 signatures, JSON depth <= 24, no fractions, no
  lone surrogates. `body.t` = kind, `body.py` = pyramid id, `body.at` = time (ms;
  a record dated more than 10 minutes ahead waits).
- Kinds (`PyrT`): `genesis`, `admit`, `swap`, `vreq`, `vote`, `leave`, `fill`,
  `absent`, `remove`, `migrate`, `alive`, `addr`, `deleg`, `revoke`, `ban`,
  `unban`, `decision`, `post`, `comment`, `natpost`, `natgrant`, `ref`, `tally`,
  `const`, `emit`, `veto`, `xfer`, `settle`, `alarm`, `merge`, `merged`, `offer`,
  `fx`. `vreq` and `vote` are signed **anonymously** with a linkable ring
  signature (LSAG over Ed25519, `ring_signature.dart`): proves one of the ring
  signed; the same signer in the same context gives the same key image.
  `xfer` and `settle` need treasurer signatures (`ts`).
- Frames: `pyr_hello` (pyramids kept and fingerprints), `pyr_ids` (ids of a
  differing bucket), `pyr_want`, `pyr_rec` (one new record, passed on),
  `pyr_recs` (bulk), `pyr_wantall`, `pyr_prop` / `pyr_sig` (co-signing),
  `pyr_vote`, `pyr_pay` / `pyr_paysig`, `pyr_report`, `pyr_appeal`, `pyr_anon`
  (an anonymous record published on someone's behalf), `pyr_dm` (access-market
  message), `pyr_fx` (exchange payment key). Fields of each [?]: see the
  `PyramidTypes` handlers.

## 4. Cryptography summary

| Purpose | Construction | Where |
|---|---|---|
| Mesh transport | Yggdrasil: Ed25519 node identity, X25519 NaCl-box sessions, TLS/link keys per hop | bridge (`bridge_types.go` audit comment) |
| Data at rest | master key; password key by **Argon2id** (parameters stored as `{a:"argon2id", m, t, p}`); **AES-256-GCM** (`nonce|ciphertext|tag`, AAD binds the storage key); sub-keys `HMAC-SHA256(master, "zen.subkey.<purpose>" + 0x01)`; verifier `sha256("zen.security.verify" + key)` | `app_security_crypto.dart`, `app_security_service.dart` |
| Mailboxes | X25519 ephemeral + static sender key, `HKDF-SHA256(DH(e,R) || DH(S,R), salt = ephemeral public key, info = "zen.relay.v1")`, ChaCha20-Poly1305, AAD `zen.relay.env|id|sender|recipient|created|expires`; plaintext is the JSON of the payload | `relay_crypto.dart` |
| Ledger entries | Ed25519 device signature; Ed25519 account-signed certificate; SHA-256 ids; canonical JSON | `core/ledger` |
| Ledger audiences | ChaCha20-Poly1305, 32-byte keys, nonce 12 bytes random, AAD `account|kid` | `audience_keys.dart` |
| Nearby | hash-chain tokens (10-min slots) and alarm MAC (v6) | `nearby_crypto.dart` |
| Dating | `DatingBox`: two layers of the mailbox construction with AAD `zen.date.v1` (inner by the sender's dating key, outer by a one-off key); profile answers are `DatingBox`es padded to 4096-byte buckets; "Yes" token `HMAC-SHA256(DH(me,them), "zen-date-like|" + sorted keys)` | `dating_crypto.dart` |
| Pyramid | Ed25519 record signatures; LSAG ring signatures; treasurer co-signatures | `pyramid_record.dart`, `ring_signature.dart` |
| Recovery | Shamir secret sharing of the key among the recovery circle (up to 6 friends) [?] details | `core/ledger/shamir.dart`, `account/recovery_service.dart` |
| Releases | Ed25519 maintainer signatures and APK certificate check ("Podaj dalej") | `update/release.dart`, `apk_signature.dart` |

**Note on direct messages:** a plain direct `message`/`group_message` between two
online devices is protected by Yggdrasil's end-to-end session encryption, not by a
second Zen-specific layer. Zen's own sealing applies to mailbox copies, ledger
audiences, dating, and the other items above. **[?]** the About screen text says
Zen adds its own encryption to every message; that should be checked against
this.

## 5. Versioning and compatibility

There is **no global protocol version number** on the wire. Compatibility
comes from additive changes and tolerant parsing:

1. **Unknown `type` is ignored**, unknown JSON fields are ignored. New frame
   types and optional fields can be added without breaking old peers.
2. **Never reuse or change the meaning of an existing field or `type`.** Prefer a
   new field or type. Old peers keep working because they ignore it.
3. Where a format needs a version it has its own: ledger entry `v` (1; entries
   with a higher `v` are still stored and passed on; only this build's own checks
   apply), dating lantern `v:3`, alarm wave `v:6`,
   BLE hello `v:7`, relay and dating KDF/AAD labels `*.v1`, blob manifest
   `chunk` size, `profile_update.v` (monotonic counter), relay announcement
   version `v`.
4. The compression wire formats are all accepted: plain JSON, `ZSTD:` + base64,
   and the Dart `_zenEncoding` wrapper.
5. Legacy names: call end is `hangup` or `call_end`; old peers' automatic
   `friend_remove` reply is treated as "unconfirmed" and ignored.
6. Persisted indices (for example the order of `ZenSignalType` in the signal
   queue) must only be appended to.
7. Changes to disk or wire formats must stay backward compatible with 1.10.0
   (project rule).
8. The app version is `kAppVersion` (1.10.0, equal to `pubspec.yaml`); it is not
   sent in frames.

## 6. Security properties and known limits

- Source addresses are authenticated by the mesh; the app additionally gates
  features by friendship (`ping` is not answered to strangers).
- Hostile input bounds: 2 MiB per signal, 64:1 inflate limit, fragment and inbox
  caps, per-/64 rate limits, JSON key and string caps in the parser, strict
  validation of ledger entries, pyramid records and blobs, media re-encoding.
- Not hidden: who talks to whom, when and how much, from mesh observers and
  from the other party; ledger entry metadata (author account, kind, time).
- Bluetooth waves are unauthenticated except alarm waves (MAC); a wave's mesh
  address is a claim.

## 7. Open items for this document

- Field-level tables for events, ask, circle, table, plan, neighbours, dating
  inner payloads, pyramid frames, `lg_heads` head format and `lg_sibling`.
- Group-call media handshake and file transfer details.
- Final form of mailbox blob frames (work in progress).
- Check whether Dart or Go compresses first on the real send path (1.2).
