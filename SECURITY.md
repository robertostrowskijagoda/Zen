# Security

## How to report a vulnerability

Report **privately**, through GitHub:

**https://github.com/robertostrowskijagoda/Zen/security/advisories/new**

(or the **Security → Report a vulnerability** tab in this repository).
Only you and the project maintainer see the report. Please do **not** open a
public issue or pull request describing the vulnerability before a fix exists.
If you cannot use this route, open an issue asking for contact — with no
details.

What to include (in English or Polish):

- the Zen version and system (Android, Windows, Linux, macOS, iPhone);
- steps to reproduce, and what happens instead of what should happen;
- the impact: what the attacker gains and what conditions are needed;
- a proof of concept, if you have one — without real data of other people.

## Scope

- **The Zen app** on all systems (`lib/`, `android/`, `ios/`, `windows/`,
  `linux/`, `macos/`).
- **The Go bridge** (`native/yggdrasil_bridge`): the Yggdrasil node,
  signalling, relay.
- **The offline links** (`local_link*.go`, `bluetooth_link*`, Wi-Fi Direct and
  Multipeer bridges in the platform folders) and the **self-update** (GitHub
  release check, download, verification, installer helpers).
- **The release process**: GitHub Actions workflows (`.github/workflows`),
  APK signing, `SHA256SUMS`, files in Releases (including the Linux `.deb`
  packages).
- **The invite page** (`tool/pages`,
  https://robertostrowskijagoda.github.io/Zen/).

Only the **latest release** receives fixes. Report bugs in Yggdrasil, Flutter
or other libraries to their authors — but let us know here too if they affect
Zen. A copy of Zen signed with a different key is not the official Zen; if
someone distributes a fake as Zen, report it the same way.

**Official copy:** the APK certificate fingerprint (SHA-256) is in the
[README](README.md), in the section "Isn't it a virus? How to check", and in
every release description; next to the release files there is `SHA256SUMS`.

Related documents: [security model](docs/SECURITY_MODEL.md),
[privacy policy](docs/PRIVACY.md), [terms](docs/TERMS.md),
[protocol specification](docs/PROTOCOL.md),
[dependencies](docs/DEPENDENCIES.md).

## Encryption in short

The full picture, with the threat model and the limits, is in the
[security model](docs/SECURITY_MODEL.md); the wire format in the
[protocol specification](docs/PROTOCOL.md), sections 1.5, 2.5.1 and 4.

Zen runs on the Yggdrasil mesh, whose own encryption (X25519, Ed25519) is
classical. Zen adds layers of its own, so that traffic recorded today cannot
be read, or records forged, later with a quantum computer:

- **Key exchange:** hybrid ML-KEM-768 + X25519 (X-Wing through HPKE, Go's
  standard library) for every signal between devices (a session per device
  pair, ChaCha20-Poly1305, no plaintext mode), offline mailboxes, the Android
  locked inbox, neighbours' doors, Bluetooth hellos, local link handshakes,
  call keys, dating boxes and food pickup addresses.
- **Signatures:** hybrid Ed25519 + ML-DSA-65 (FIPS 204), valid only when both
  halves verify, on everything Zen signs to keep or pass on: account and
  device records, ledger entries, pyramid records and ballots, the ledger
  hello that binds a device's post-quantum key to its address, dating
  profiles, release manifests, `SHA256SUMS.sig`.
- **Device keys** are pinned per address; a record with another key for a
  known address is rejected and the chat shows a warning.
- **Calls:** AES-128-GCM frame encryption with per-call hybrid keys, inside
  DTLS-SRTP, inside a 256-bit ChaCha20-Poly1305 relay layer of the two
  devices' post-quantum session.
- **Event tickets** are HMAC-based; **cell votes** use one-time hybrid cards.
- **At rest:** AES-256-GCM under a key from your password (Argon2id) and the
  system's security hardware.

**Still classical:** the Yggdrasil node key and address; the anonymous
*request* for a cell vote (a linkable ring signature, LSAG over Ed25519: there
is no standard post-quantum one); the pair secrets of local links (X25519 of
the two devices' keys); the dating lantern, first match question and lantern
proof; the 128-bit AES key of call frames (libwebrtc offers no other). What an
attacker with a quantum computer could do with each is described in the
[security model](docs/SECURITY_MODEL.md#what-stays-classical-and-why).

Also true: a metadata observer still sees who talks to whom and when, and the
self-update checks the maintainers' signature only once their keys are
pinned in the app (until then: `SHA256SUMS`, and on Android the signing
certificate). Reports about any of this are welcome.

## What to expect

Zen is made by **one person**, in spare time. I answer as fast as I can
(best effort), but with no guaranteed deadlines. Usually: acknowledgement of
the report, assessment, a fix in the next release, and then a public advisory
— with credit, if you want to be named. Please allow time for a fix before
publishing details; we will agree on the disclosure date together.

**There is no bug bounty** — Zen is free and there is no company behind it,
so there are no cash rewards.

## Testing rules

- Test **only on your own devices, accounts and networks** (e.g. several of
  your own phones or computers, your own Yggdrasil node or bridge).
- **Do not test on other people's phones, computers or networks**, and do not
  send anything harmful to people who have not agreed to it.
- Do not overload public Yggdrasil nodes and do not try to reach other
  people's data.
- Describe weaknesses of the release process in the report; do not try to
  exploit them against this repository (pull requests, tags, attempts to
  reach secrets).
