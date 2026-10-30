# Contributing to Zen

Thank you for wanting to help. Bug reports, translations and code are all
welcome. Security problems: please do not open a public issue, see
[SECURITY.md](SECURITY.md).

Questions, ideas or want to talk a change over before you start? Join
[Zen on Discord](https://discord.gg/g4vHvpKV37).

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Before you send a pull request

- One change per pull request, with a short description of what it changes
  and why.
- The checks CI runs ([docs/TESTING.md](docs/TESTING.md), section 6; how
  to build: [docs/BUILDING.md](docs/BUILDING.md)):
  - `dart format lib test tool`, `flutter analyze` and the tests
    (`dart run tool/test.dart` runs all of them in parallel; or
    `flutter test test/<file>_test.dart` for one file);
  - `go vet ./...` and `go test ./...` in `native/yggdrasil_bridge`;
  - for changes to the documentation: `python3 tool/ci/check_links.py` (no
    broken links). A pull request that changes only documentation runs
    only these checks and the tests that read the documentation;
  - for changes to the workflows, the release or the website:
    `dart run tool/release.dart check`, `python3 tool/ci/test_release_source.py`,
    `python3 tool/ci/test_ci_checks.py` and `python3 tool/ci/test_check_libwebrtc.py`;
  - `flutter pub get --enforce-lockfile`: a change to `pubspec.yaml` comes
    with its `pubspec.lock`.
- Tests for what you change, in the style of the existing ones.
- Every text a person sees goes through `t('…')` (Polish source text; the
  translations live in `assets/i18n/`).
- Comments and identifiers in English.
- Stored and sent formats: follow the rules in
  `lib/src/core/storage/format_version.dart` (read every older version,
  never overwrite a newer one, append-only enums) and never change the
  samples in `test/fixtures/formats/`.
- Layouts: direction-aware paddings and alignments (`EdgeInsetsDirectional`,
  `AlignmentDirectional`), dialogs that scroll, no fixed heights for text.

## Contributor licence grant

Zen is released under the GNU General Public License version 3 with the
additional terms in [NOTICE](NOTICE). Some ways of getting Zen to people
(Apple's App Store, TestFlight, AltStore PAL, Google Play, the Microsoft
Store and similar stores) impose terms of their own that may not be
compatible with the GPL. So that Zen can be offered there without asking
every contributor again, each contribution is accepted under these terms.

By submitting a contribution (a pull request, a patch, a translation or any
other material meant to be included in Zen), you agree that:

1. **Licence to everyone.** Your contribution is licensed under the same
   licence as Zen: GPL-3.0-only with the additional terms in NOTICE.
2. **Additional licence to the maintainer.** You also grant Robert
   Ostrowski-Jagoda, the author and maintainer of Zen, and any successor
   he names as maintainer of the project, a perpetual, worldwide,
   non-exclusive, royalty-free, irrevocable licence to use, copy, modify,
   publish and distribute your contribution as part of Zen or of works
   based on Zen, and to sublicense these rights, under the GPL or under
   other terms, in particular the terms required to distribute Zen through
   app stores and similar distribution services.
3. **Zen stays free.** Every version of Zen distributed under such other
   terms is also published as source code under the GPL (with the
   additional terms in NOTICE); this grant does not allow making Zen, or
   your contribution in it, available only under non-free terms.
4. **Your copyright stays yours.** This is a licence, not a transfer of
   copyright. You may use your own contribution in any other way you like.
5. **You may grant it.** The contribution is your own work, or you have
   the right to submit it under these terms (for example, your employer
   agrees, or it is under a licence that allows this). Third-party code is
   marked as such, with its licence, and is subject to its own licence
   rather than to point 2.

This grant is a condition only for having a contribution merged into the
official repository. It does not change the licence under which anyone
receives, uses, modifies or redistributes Zen: that stays GPL-3.0-only with
the additional terms in NOTICE, and every version published as source code
stays available under it.

You confirm this by ticking the box in the pull request template, or, for
contributions sent another way, by writing that you agree to the
"Contributor licence grant" of CONTRIBUTING.md. Contributions without that
confirmation cannot be merged.
