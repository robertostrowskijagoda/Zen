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
[protocol specification](docs/PROTOCOL.md), [security status and audits](docs/STATUS.md).

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
