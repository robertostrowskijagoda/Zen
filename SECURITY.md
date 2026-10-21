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

Related documents: [privacy policy](docs/PRIVACY.md), [terms](docs/TERMS.md),
[protocol specification](docs/PROTOCOL.md).

## Encryption in short

Zen runs on the Yggdrasil mesh, whose own encryption (X25519, Ed25519, TLS)
is classical. Zen adds layers of its own, so that traffic recorded today
cannot be read, or records forged, later with a quantum computer. Details:
[protocol specification](docs/PROTOCOL.md), sections 1.5, 2.5.1 and 4.

**Post-quantum (hybrid) layers**

- **Signals between devices.** Every signal is sealed once more with a hybrid
  key, ML-KEM-768 + X25519 ("X-Wing", Go's standard library), one session per
  pair of devices, ChaCha20-Poly1305 per frame. There is no plaintext mode.
- **Offline mailboxes and the Android locked inbox** use the same hybrid KEM;
  mailbox attachments are chunked and sealed with a fresh symmetric key.
- **Call media.** Audio, video and screen frames are encrypted end to end
  (WebRTC frame encryption inside DTLS-SRTP) with keys from a hybrid ML-KEM
  exchange in the call's offer and answer, rotated every 5 minutes and when
  somebody joins or leaves a group call. If a device cannot do frame
  encryption the call falls back to DTLS-SRTP and the call screen says so.
- **Signatures.** Everything Zen signs to keep or pass on (account and device
  records, ledger entries, pyramid records, attestations, release manifests,
  `SHA256SUMS.sig`) carries a hybrid signature, Ed25519 + ML-DSA-65 (FIPS 204),
  valid only when both halves verify. The ML-DSA key comes from the same seed
  as the Ed25519 key, so key backups restore both; keys are referenced by
  fingerprint and anchored in the records that introduce them (the pinned
  genesis of the pyramid, device certificates, release maintainers).
- **At rest:** AES-256-GCM, ChaCha20-Poly1305 and Argon2id with 256-bit keys.

**What stays classical, on purpose or for lack of a standard**

- the anonymous ring signatures (LSAG over Ed25519) of cell votes: there is no
  standard post-quantum linkable ring signature;
- event tickets in QR codes (a hybrid signature does not fit one code);
- Bluetooth and LAN greetings and adverts, and the local-link handshake (they
  carry already sealed signals);
- dating boxes, the match test and "Yes" tokens (X25519 boxes between friends'
  phones, inside the sealed signal layer);
- door traffic: knocks for flat doors and mailbox doors and frames between
  doors (X25519), and door nodes that run no session layer;
- the Yggdrasil node key and the key record that binds a device's post-quantum
  key to its mesh address;
- **call frames use AES-128-GCM**, the only mode WebRTC's frame encryption
  offers: against a quantum computer that is about 64-bit strength.

Also true: ordinary frames are not signed by Zen at all (they rely on the
session layer and the mesh source address), a metadata observer still sees who
talks to whom and when, and the self-update checks the maintainers'
signature only once their keys are pinned in the app (until then:
`SHA256SUMS`, and on Android the signing certificate). The Android background
service works without your password, with a separate background key and only
the kits it needs (alarm, nearby, door); everything else waits sealed until
you unlock. Reports about any of this are welcome.

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
