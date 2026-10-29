# Zen documentation

In reading order: first for everyone who uses Zen, then how it protects
you, then how it works inside, then for the people who build and release it.

## 1. Using Zen

- [User guide](guide/README.md): what each part of Zen does and how it
  works, with pictures; start with [Getting started](guide/getting-started.md).
- [Installing Zen](INSTALL.md): every system, every file, the warnings to
  click past, battery use, and why Zen is not in the stores.
- [Updates and releases](guide/updates.md): how Zen updates itself and how
  it checks what it downloads.
- [iPhone: receiving in the background](IOS_BACKGROUND.md): what iOS allows
  without a server, what Zen does, and how to test it.

The same in 21 languages, with pictures for every step, on the website
([robertostrowskijagoda.github.io/Zen](https://robertostrowskijagoda.github.io/Zen/)):
[install](https://robertostrowskijagoda.github.io/Zen/install/),
[how to use Zen](https://robertostrowskijagoda.github.io/Zen/guide/),
[features](https://robertostrowskijagoda.github.io/Zen/features/),
[support](https://robertostrowskijagoda.github.io/Zen/support/) (how to
report a bug and what to attach) and
[about](https://robertostrowskijagoda.github.io/Zen/about/). Questions and
help: [Zen on Discord](https://discord.gg/g4vHvpKV37).

## 2. Privacy and security

- [Privacy policy](PRIVACY.md) and [terms of use](TERMS.md), the texts the
  app shows and asks you to accept. Using Zen to break the law is forbidden
  by the terms of use.
- [Security model](SECURITY_MODEL.md): threats, encryption, what is
  post-quantum and what is still classical, device hardening, honest
  limits.
- [Reporting a vulnerability](../SECURITY.md), privately.
- [How to check that a file is official](../README.md#isnt-it-a-virus-how-to-check).

## 3. How it works

- [Protocol specification](PROTOCOL.md): frames, records and cryptography
  on the wire.
- [Dependencies](DEPENDENCIES.md): libraries, platform APIs and their
  licences.

## 4. Building, testing and releasing

- [Building from source](BUILDING.md): what each system needs and the build
  commands.
- [Testing](TESTING.md): fast local runs, the network simulator, several
  apps on one computer, real-node and emulator tests, the visual tours,
  translations, and CI (GitHub Actions).
- [Releases](RELEASES.md): signing, publishing, distribution, updates, the
  website (`tool/pages`, deployed by `.github/workflows/pages.yml`).

## 5. Contributing

- [Contributing](../CONTRIBUTING.md): the checks before a pull request and
  the contributor licence grant.
- [Changelog](../CHANGELOG.md).
- [Licence](../LICENSE) (GPL-3.0-only) with the additional terms in
  [NOTICE](../NOTICE); the components and their licences in
  [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

`python3 tool/ci/check_links.py` checks every link of these files (CI runs
it in the job "Docs and site").
