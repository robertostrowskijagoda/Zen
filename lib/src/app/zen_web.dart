/// The project's web addresses, in one place.
///
/// Links the app makes (invitation QR codes, door stickers, the install
/// page, the SideStore source, the link a store build passes on) start with
/// [kZenPagesBase]. Links are taken from every base in [kZenPageBases], so
/// once the pages move to an own domain the stickers and posters already
/// printed keep working.
///
/// Moving to an own domain: set [kZenOwnDomain] (the pages must already be
/// served there, with the GitHub Pages address still answering), and add
/// the host to the invitation link filter in
/// android/app/src/main/AndroidManifest.xml. New links then use the own
/// domain; builds from before keep reading both.
library;

/// The own domain of the project's pages (for example `zen.example`), or
/// empty while there is none.
const String kZenOwnDomain = '';

/// The project's pages on GitHub Pages (`tool/pages`).
const String kZenGithubPagesBase =
    'https://robertostrowskijagoda.github.io/Zen/';

/// The project's page on GitHub (downloads, instructions, the code).
const String kZenRepositoryUrl = 'https://github.com/robertostrowskijagoda/Zen';

/// Where new links point: the own domain once there is one.
const String kZenPagesBase = kZenOwnDomain == ''
    ? kZenGithubPagesBase
    : 'https://$kZenOwnDomain/';

/// Every base links are taken from (new links use [kZenPagesBase]).
const List<String> kZenPageBases = <String>[
  kZenGithubPagesBase,
  if (kZenOwnDomain != '') 'https://$kZenOwnDomain/',
];

/// The page at [path] (no leading `/`) of the project's pages.
String zenPageUrl(String path) => '$kZenPagesBase$path';

/// Whether [uri] is the page [path] (empty: the main page) under one of
/// [kZenPageBases], or — for the main page — the project's GitHub page.
bool isZenPage(Uri uri, {String path = ''}) {
  String page(Uri u) =>
      '${u.host.toLowerCase()}'
      '${u.path.toLowerCase().replaceFirst(RegExp(r'/+$'), '')}';
  final String target = page(uri);
  for (final String base in kZenPageBases) {
    if (target == page(Uri.parse('$base$path'))) {
      return true;
    }
  }
  return path.isEmpty && target == page(Uri.parse(kZenRepositoryUrl));
}
