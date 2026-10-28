import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The website (tool/pages): what its pages must keep, read from the files.
// The addresses people were given stay; every page can be read on a phone,
// is drawn in the shared look, has the app icon and the language picker; the
// downloads are links that follow each release by themselves and the iPhone
// page installs with SideStore, step by step with drawn pictures, the other
// ways only as other ways.

const String _site = 'tool/pages';

/// The pages: the invitation, the door page, and one page per topic.
const List<String> _pages = <String>[
  'index.html',
  'm/index.html',
  'about/index.html',
  'features/index.html',
  'guide/index.html',
  'support/index.html',
  'install/index.html',
  'install/android/index.html',
  'install/iphone/index.html',
  'install/linux/index.html',
  'install/macos/index.html',
  'install/windows/index.html',
];

/// Where the site is published (release_source.PAGES).
const String _base = 'https://robertostrowskijagoda.github.io/Zen/';

/// The pages that describe the app in structured data.
const List<String> _appPages = <String>[
  'index.html',
  'about/index.html',
  'install/index.html',
];

String _read(String page) => File('$_site/$page').readAsStringSync();

/// The published address of [page]: its folder, with the trailing "/".
String _url(String page) =>
    _base + page.substring(0, page.length - 'index.html'.length);

/// The language codes of the shared script (its picker), in its order.
List<String> _codes() {
  final String js = _read('site.js');
  final String names = js.substring(
    js.indexOf('var NAMES = {'),
    js.indexOf('};', js.indexOf('var NAMES = {')),
  );
  return <String>[
    for (final RegExpMatch m in RegExp(r'(\w+): "').allMatches(names)) m[1]!,
  ];
}

/// The Open Graph locale of each language (LOCALES of the shared script).
Map<String, String> _locales() {
  final String js = _read('site.js');
  final int at = js.indexOf('var LOCALES = {');
  return <String, String>{
    for (final RegExpMatch m in RegExp(
      r'(\w+): "(\w+)"',
    ).allMatches(js.substring(at, js.indexOf('};', at))))
      m[1]!: m[2]!,
  };
}

/// The head of a page (what comes before `</head>`).
String _head(String page) {
  final String html = _read(page);
  return html.substring(0, html.indexOf('</head>'));
}

/// The content of every `<meta [attribute]="[name]" content="...">`.
List<String> _meta(String head, String attribute, String name) => <String>[
  for (final RegExpMatch m in RegExp(
    '<meta $attribute="${RegExp.escape(name)}" content="([^"]*)"',
  ).allMatches(head))
    _unescape(m[1]!),
];

String _unescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// The structured data (JSON-LD) blocks of a page.
List<Object?> _jsonLd(String page) => <Object?>[
  for (final RegExpMatch m in RegExp(
    r'<script type="application/ld\+json">(.*?)</script>',
    dotAll: true,
  ).allMatches(_read(page)))
    jsonDecode(m[1]!),
];

/// Width and height of a PNG file, from its IHDR chunk.
(int, int) _pngSize(String path) {
  final List<int> bytes = File(path).readAsBytesSync();
  expect(bytes.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  expect(ascii.decode(bytes.sublist(12, 16)), 'IHDR');
  int word(int at) =>
      (bytes[at] << 24) |
      (bytes[at + 1] << 16) |
      (bytes[at + 2] << 8) |
      bytes[at + 3];
  return (word(16), word(20));
}

/// The way up from [page] to the root of the site: "", "../", "../../".
String _up(String page) => '../' * (page.split('/').length - 1);

/// One line per language, `"pl": {...}`, in a page's TEXTS and in the
/// shared script's COMMON.
final RegExp _languageLine = RegExp(
  r'^\s*"([a-z]{2})": (\{.*\}),?\s*$',
  multiLine: true,
);

/// The texts of [file] (a page or site.js): language → key → text.
Map<String, Map<String, String>> _texts(String file) =>
    <String, Map<String, String>>{
      for (final RegExpMatch m in _languageLine.allMatches(_read(file)))
        m.group(1)!: (jsonDecode(m.group(2)!) as Map<String, dynamic>).map(
          (String k, dynamic v) => MapEntry<String, String>(k, v as String),
        ),
    };

/// What a translation must keep of the English text: placeholders, bold,
/// code and link targets.
List<String> _markup(String text) => <String>[
  for (final RegExpMatch m in RegExp(
    r'\{[a-z]+\}|\*\*|`|\[[^|\]]+\|([^\]]+)\]',
  ).allMatches(text))
    m.group(1) ?? m.group(0)!,
]..sort();

void main() {
  group('the addresses stay', () {
    test('every page of the site is there', () {
      for (final String page in _pages) {
        expect(File('$_site/$page').existsSync(), isTrue, reason: page);
      }
      for (final String asset in <String>[
        'site.css',
        'site.js',
        'zen-icon.png',
      ]) {
        expect(File('$_site/$asset').existsSync(), isTrue, reason: asset);
      }
    });

    test('the invitation opens the app without sending anyone on', () {
      final String home = _read('index.html');
      // "/Zen/" with no code is the mailbox in the app: a page of its own,
      // not a redirect.
      expect(home, isNot(contains('http-equiv="refresh"')));
      expect(home, isNot(contains('location.replace')));
      expect(home, contains('id="open"'));
      expect(home, contains('zen-icon.png'));
    });

    test('the iPhone source is made from the release, not kept here', () {
      expect(File('$_site/apps.json').existsSync(), isFalse);
      final String workflow = File(
        '.github/workflows/pages.yml',
      ).readAsStringSync();
      expect(workflow, contains('apps.json'));
      expect(workflow, contains('release_source.py'));
      final String script = File(
        'tool/ci/release_source.py',
      ).readAsStringSync();
      expect(script, contains('"apps.json"'));
      // SideStore's source is the only one published.
      expect(
        <String?>{
          for (final RegExpMatch m in RegExp(r'"\w+\.json"').allMatches(script))
            m[0],
        },
        <String>{'"apps.json"', '"release.json"'},
      );
    });
  });

  group('every page', () {
    for (final String page in _pages) {
      test('$page: a phone screen, the shared look, the app icon, the '
          'picker', () {
        final String html = _read(page);
        final String up = _up(page);
        expect(html, startsWith('<!doctype html>'));
        expect(html, contains('<html lang="en">'));
        expect(
          html,
          contains('<meta name="viewport" content="width=device-width'),
        );
        expect(html, contains('<link rel="stylesheet" href="${up}site.css">'));
        expect(html, contains('<script src="${up}site.js"></script>'));
        expect(
          html,
          contains(
            '<link rel="icon" type="image/png" href="${up}zen-icon.png">',
          ),
          reason: 'the app icon, not a letter',
        );
        // The header (with the language picker) is drawn by the shared
        // script into this element, and the footer too.
        expect(html, contains('<header class="top" id="zenTop">'));
        expect(html, contains('<footer class="foot" id="zenFoot"'));
        expect(html, contains('Zen.init('));
      });
    }

    test('the shared script offers 21 languages, each named in its own '
        'language, and a picker the visitor sees', () {
      final String js = _read('site.js');
      final String names = js.substring(
        js.indexOf('var NAMES = {'),
        js.indexOf('var RTL'),
      );
      final int count = RegExp(r'\w+: "').allMatches(names).length;
      expect(count, 21);
      expect(names, contains('en: "English"'));
      expect(names, contains('pl: "Polski"'));
      expect(js, contains('"zen-lang"'), reason: 'the choice is remembered');
      expect(js, contains('?lang='));
      // The picker is labelled with a name, not drawn as a bare word.
      expect(js, contains('langLabel'));
    });

    test('the English text is the fallback of every page', () {
      for (final String page in _pages) {
        expect(_read(page), contains('"en": {'), reason: page);
      }
    });

    test('every text table is valid JSON in 21 languages with the English '
        'keys, placeholders, bold and links', () {
      for (final String file in <String>[..._pages, '404.html', 'site.js']) {
        final Map<String, Map<String, String>> texts = _texts(file);
        expect(texts, hasLength(21), reason: file);
        final Map<String, String> en = texts['en']!;
        for (final MapEntry<String, Map<String, String>> lang
            in texts.entries) {
          expect(
            lang.value.keys.toSet(),
            en.keys.toSet(),
            reason: '$file ${lang.key}',
          );
          for (final MapEntry<String, String> text in lang.value.entries) {
            expect(
              _markup(text.value),
              _markup(en[text.key]!),
              reason: '$file ${lang.key} ${text.key}',
            );
          }
        }
      }
    });
  });

  group('found by search engines and shown well in links', () {
    for (final String page in _pages) {
      test('$page: the canonical address, every language, the link '
          'preview, the manifest and the bar colours', () {
        final String head = _head(page);
        final String url = _url(page);
        final Map<String, String> en = _texts(page)['en']!;
        // The English page has no "?lang".
        expect(head, contains('<link rel="canonical" href="$url">'));
        expect(RegExp('<link rel="canonical"').allMatches(head), hasLength(1));
        final List<String> codes = _codes();
        expect(codes, hasLength(21));
        final Map<String, String> alternates = <String, String>{
          for (final RegExpMatch m in RegExp(
            r'<link rel="alternate" hreflang="([\w-]+)" href="([^"]+)">',
          ).allMatches(head))
            m[1]!: m[2]!,
        };
        expect(alternates, <String, String>{
          for (final String code in codes)
            code: code == 'en' ? url : '$url?lang=$code',
          'x-default': url,
        });

        expect(head, contains('<title>${en['title']}</title>'));
        expect(_meta(head, 'name', 'description'), <String>[en['desc']!]);
        expect(_meta(head, 'property', 'og:type'), <String>['website']);
        expect(_meta(head, 'property', 'og:site_name'), <String>['Zen']);
        expect(_meta(head, 'property', 'og:title'), <String>[en['title']!]);
        expect(_meta(head, 'property', 'og:description'), <String>[
          en['desc']!,
        ]);
        expect(_meta(head, 'property', 'og:url'), <String>[url]);
        expect(_meta(head, 'property', 'og:image'), <String>[
          '${_base}og-image.png',
        ]);
        expect(_meta(head, 'property', 'og:image:width'), <String>['1200']);
        expect(_meta(head, 'property', 'og:image:height'), <String>['630']);
        expect(_meta(head, 'property', 'og:image:alt').single, isNotEmpty);
        final Map<String, String> locales = _locales();
        expect(locales.keys.toList(), codes);
        expect(_meta(head, 'property', 'og:locale'), <String>[locales['en']!]);
        expect(_meta(head, 'property', 'og:locale:alternate'), <String>[
          for (final String code in codes.skip(1)) locales[code]!,
        ]);
        expect(_meta(head, 'name', 'twitter:card'), <String>[
          'summary_large_image',
        ]);
        expect(_meta(head, 'name', 'twitter:title'), <String>[en['title']!]);
        expect(_meta(head, 'name', 'twitter:description'), <String>[
          en['desc']!,
        ]);
        expect(_meta(head, 'name', 'twitter:image'), <String>[
          '${_base}og-image.png',
        ]);
        expect(_meta(head, 'name', 'twitter:image:alt').single, isNotEmpty);

        expect(
          head,
          contains(
            '<link rel="manifest" href="${_up(page)}manifest.webmanifest">',
          ),
        );
        expect(
          head,
          contains(
            '<meta name="theme-color" content="#f6f4fb" '
            'media="(prefers-color-scheme: light)">',
          ),
        );
        expect(
          head,
          contains(
            '<meta name="theme-color" content="#0b0a10" '
            'media="(prefers-color-scheme: dark)">',
          ),
        );
      });
    }

    test('every page has its own title and description, naming Zen, in '
        'every language', () {
      for (final String lang in _codes()) {
        final Set<String> titles = <String>{};
        final Set<String> descriptions = <String>{};
        for (final String page in <String>[..._pages, '404.html']) {
          final Map<String, String> t = _texts(page)[lang]!;
          expect(t['title'], contains('Zen'), reason: '$page $lang');
          expect(t['desc']!.length, greaterThan(20), reason: '$page $lang');
          expect(titles.add(t['title']!), isTrue, reason: '$page $lang');
          expect(descriptions.add(t['desc']!), isTrue, reason: '$page $lang');
        }
      }
    });

    test('the shared script turns the link preview and the canonical '
        'address to the language shown', () {
      final String js = _read('site.js');
      for (final String part in <String>[
        'meta[property="og:title"], meta[name="twitter:title"]',
        'meta[property="og:description"]',
        'meta[property="og:locale"]',
        'meta[property="og:locale:alternate"]',
        'link[rel="canonical"]',
        'meta[property="og:url"]',
      ]) {
        expect(js, contains(part), reason: part);
      }
    });

    test('the home, about and install pages describe the app in structured '
        'data, without made-up ratings', () {
      for (final String page in _appPages) {
        final List<Object?> blocks = _jsonLd(page);
        expect(blocks, hasLength(1), reason: page);
        final Map<String, dynamic> data =
            blocks.single! as Map<String, dynamic>;
        expect(data['@context'], 'https://schema.org', reason: page);
        final List<Map<String, dynamic>> nodes = <Map<String, dynamic>>[
          if (data['@graph'] case final List<dynamic> graph)
            for (final dynamic node in graph) node as Map<String, dynamic>
          else
            data,
        ];
        final Map<String, dynamic> app = nodes.singleWhere(
          (Map<String, dynamic> n) => n['@type'] == 'SoftwareApplication',
        );
        expect(app['name'], 'Zen');
        expect(app['applicationCategory'], 'CommunicationApplication');
        expect(app['operatingSystem'], 'Android, iOS, Windows, macOS, Linux');
        expect(app['offers'], <String, dynamic>{
          '@type': 'Offer',
          'price': '0',
          'priceCurrency': 'USD',
        });
        expect(app['license'], 'https://www.gnu.org/licenses/gpl-3.0.html');
        expect(
          (app['author'] as Map<String, dynamic>)['name'],
          'Robert Ostrowski-Jagoda',
        );
        expect(app['downloadUrl'], '${_base}install/');
        expect(app['url'], '${_base}about/');
        expect(app['image'], '${_base}og-image.png');
        // The version is the latest release's, put in at deployment.
        expect(app.containsKey('softwareVersion'), isFalse, reason: page);
        final String text = jsonEncode(data);
        for (final String made in <String>[
          'aggregateRating',
          'review',
          'ratingValue',
        ]) {
          expect(text, isNot(contains(made)), reason: '$page $made');
        }
      }
      final Map<String, dynamic> home =
          _jsonLd('index.html').single! as Map<String, dynamic>;
      final Map<String, dynamic> site =
          (home['@graph'] as List<dynamic>).firstWhere(
                (dynamic n) =>
                    (n as Map<String, dynamic>)['@type'] == 'WebSite',
              )
              as Map<String, dynamic>;
      expect(site['url'], _base);
      expect(site['inLanguage'], _codes());
      // No organisation behind Zen: its author is a person.
      for (final String page in _pages) {
        expect(_read(page), isNot(contains('"Organization"')), reason: page);
      }
    });

    test('the link picture is 1200 x 630 and small, the manifest is a '
        'bookmark (not an installed app) with its icons', () {
      expect(_pngSize('$_site/og-image.png'), (1200, 630));
      expect(File('$_site/og-image.png').lengthSync(), lessThan(200 * 1024));
      final Map<String, dynamic> manifest =
          jsonDecode(_read('manifest.webmanifest')) as Map<String, dynamic>;
      expect(manifest['name'], 'Zen');
      expect(manifest['short_name'], 'Zen');
      expect(manifest['start_url'], './');
      expect(manifest['display'], 'browser');
      expect(manifest['theme_color'], '#f6f4fb');
      expect(manifest['background_color'], '#f6f4fb');
      final List<dynamic> icons = manifest['icons'] as List<dynamic>;
      expect(
        icons.map((dynamic i) => (i as Map<String, dynamic>)['sizes']),
        <String>['192x192', '512x512'],
      );
      for (final dynamic icon in icons) {
        final Map<String, dynamic> i = icon as Map<String, dynamic>;
        final int size = int.parse((i['sizes'] as String).split('x').first);
        expect(_pngSize('$_site/${i['src']}'), (size, size));
        expect(i['type'], 'image/png');
      }
      // The pictures can be drawn again.
      expect(File('tool/ci/site_images.py').existsSync(), isTrue);
    });

    test('a missing address shows a page in the site\'s look, with every '
        'link from the root of the site', () {
      final String html = _read('404.html');
      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('<meta name="robots" content="noindex">'));
      expect(html, contains('<link rel="stylesheet" href="/Zen/site.css">'));
      expect(html, contains('<script src="/Zen/site.js"></script>'));
      expect(
        html,
        contains('<link rel="manifest" href="/Zen/manifest.webmanifest">'),
      );
      expect(html, contains('<header class="top" id="zenTop">'));
      expect(html, contains('<footer class="foot" id="zenFoot"'));
      expect(html, contains('Zen.init('));
      expect(html, isNot(contains('rel="canonical"')));
      // Served at any depth: no relative address.
      final List<String> links = <String>[
        for (final RegExpMatch m in RegExp(
          r'(?:href|src)="([^"#]+)"',
        ).allMatches(html))
          m[1]!,
      ];
      expect(links, isNotEmpty);
      for (final String link in links) {
        expect(link, startsWith('/Zen/'), reason: link);
      }
      for (final String target in <String>[
        '/Zen/',
        '/Zen/install/',
        '/Zen/guide/',
        '/Zen/features/',
        '/Zen/support/',
        '/Zen/about/',
      ]) {
        expect(html, contains('href="$target"'), reason: target);
      }
    });

    test('the sitemap, security.txt and the version are made at deployment, '
        'with the hidden .well-known folder', () {
      final String workflow = File(
        '.github/workflows/pages.yml',
      ).readAsStringSync();
      expect(
        workflow,
        contains(
          'python3 tool/ci/site_files.py --site _site --source tool/pages',
        ),
      );
      expect(workflow, contains('include-hidden-files: true'));
      expect(workflow, contains('fetch-depth: 0'));
      expect(
        workflow.indexOf('site_files.py --site'),
        greaterThan(workflow.indexOf('release_source.py\n')),
        reason: 'after release.json is written',
      );
      // Not kept in the site, where they would go stale, and no robots.txt
      // (crawlers read only the one at the root of the host).
      for (final String file in <String>[
        'sitemap.xml',
        'robots.txt',
        '.well-known/security.txt',
      ]) {
        expect(File('$_site/$file').existsSync(), isFalse, reason: file);
      }
    });
  });

  group('honest and reassuring', () {
    test('the guide says how to get the account back, with friends, next to '
        'the missing "forgot password" e-mail', () {
      final Map<String, Map<String, String>> guide = _texts('guide/index.html');
      final Map<String, List<String>> words = <String, List<String>>{
        'en': <String>[
          'forgot password',
          'key copy',
          'recovery circle',
          'friends',
        ],
        'pl': <String>[
          'zapomniałem hasła',
          'kopię klucza',
          'krąg odzyskiwania',
          'znajom',
        ],
      };
      for (final MapEntry<String, List<String>> lang in words.entries) {
        final String start = guide[lang.key]!['start_3']!;
        for (final String word in lang.value) {
          expect(start, contains(word), reason: '${lang.key}: $word');
        }
      }
      // All the ways back, the circle's friends among them, before the
      // caveat.
      final String backEn = guide['en']!['lock_3']!;
      final String backPl = guide['pl']!['lock_3']!;
      for (final String way in <String>[
        'another device',
        'full account copy',
        'key copy',
        'recovery circle',
        'friends',
      ]) {
        expect(backEn, contains(way), reason: way);
      }
      for (final String way in <String>[
        'drugiego urządzenia',
        'kopii całego konta',
        'kopii klucza',
        'kręgu odzyskiwania',
        'znajomych',
      ]) {
        expect(backPl, contains(way), reason: way);
      }
      expect(
        backEn.indexOf('recovery circle'),
        lessThan(backEn.indexOf('cannot')),
      );
      expect(backPl.indexOf('kręgu'), lessThan(backPl.indexOf('nie da się')));
    });

    test('Zen runs no servers of its own, but never claims no server at '
        'all: public mesh nodes exist', () {
      for (final String page in <String>['index.html', 'about/index.html']) {
        final Map<String, Map<String, String>> texts = _texts(page);
        for (final String key in <String>['lead', 'desc']) {
          final String en = texts['en']![key]!.toLowerCase();
          final String pl = texts['pl']![key]!.toLowerCase();
          expect(en, contains('no servers of its own'), reason: '$page $key');
          expect(pl, contains('bez własnych serwerów'), reason: '$page $key');
        }
      }
      expect(
        _texts('about/index.html')['en']!['what_1'],
        contains('public nodes run by volunteers'),
      );
    });

    test('the iPhone page tells how to receive all the time, not only while '
        'Zen is open', () {
      final Map<String, Map<String, String>> iphone = _texts(
        'install/iphone/index.html',
      );
      expect(iphone['en']!['limit'], contains('Settings → Background work'));
      expect(iphone['pl']!['limit'], contains('Ustawienia → Praca w tle'));
    });
  });

  group('installing', () {
    test('downloads are the latest release, never a pinned version', () {
      final RegExp pinned = RegExp(r'releases/download/');
      final RegExp latest = RegExp(r'releases/latest/download/[\w.-]+');
      int latestLinks = 0;
      for (final String page in _pages) {
        final String html = _read(page);
        expect(pinned.hasMatch(html), isFalse, reason: page);
        latestLinks += latest.allMatches(html).length;
      }
      expect(latestLinks, greaterThanOrEqualTo(8));
      final String home = _read('index.html');
      for (final String file in <String>[
        'Zen-arm64-v8a.apk',
        'Zen-Windows.zip',
        'Zen-Linux-x64.deb',
      ]) {
        expect(home, contains('releases/latest/download/$file'), reason: file);
      }
    });

    test('the home page lets a visitor pick any other system', () {
      final String home = _read('index.html');
      final String pick = home.substring(home.indexOf('id="osPick"'));
      for (final String os in <String>[
        'android',
        'iphone',
        'windows',
        'macos',
        'linux',
      ]) {
        expect(
          pick.substring(0, pick.indexOf('</select>')),
          contains('value="$os"'),
          reason: os,
        );
      }
    });

    test('iPhone: SideStore is the way, in seven steps after what is needed, '
        'the other stores only as other ways', () {
      final String iphone = _read('install/iphone/index.html');
      final int need = iphone.indexOf('id="need"');
      final int steps = iphone.indexOf('<ol class="how"');
      final int stepsEnd = iphone.indexOf('\n  </ol>', steps);
      expect(need, greaterThan(0));
      expect(need, lessThan(steps));
      for (final String n in <String>['need1', 'need2', 'need3', 'need4']) {
        final int at = iphone.indexOf('data-i="$n"');
        expect(at, inInclusiveRange(need, steps), reason: n);
      }
      // The steps, in this order, each with its own words.
      final List<(String, List<String>)> order = <(String, List<String>)>[
        ('step-vpn', <String>['LocalDevVPN', 'Connect']),
        ('step-computer', <String>['iloader', 'Install SideStore (Stable)']),
        (
          'step-trust',
          <String>['VPN &amp; Device Management', 'Developer Mode'],
        ),
        ('step-refresh', <String>['My Apps', '7 DAYS', 'Refresh Now']),
        (
          'step-source',
          <String>[
            'href="sidestore://source?url=https%3A%2F%2Frobertostrowskijagoda'
                '.github.io%2FZen%2Fapps.json"',
            'id="copySource"',
          ],
        ),
        ('step-auto', <String>['Set VPN', 'Refresh All Apps']),
        ('step-updates', <String>['Update']),
      ];
      int last = steps;
      for (int i = 0; i < order.length; i++) {
        final (String id, List<String> words) = order[i];
        final int at = iphone.indexOf('<li id="$id">');
        expect(at, greaterThan(last), reason: id);
        final int end = i + 1 < order.length
            ? iphone.indexOf('<li id="${order[i + 1].$1}">')
            : stepsEnd;
        final String step = iphone.substring(at, end);
        for (final String word in words) {
          expect(step, contains(word), reason: '$id: $word');
        }
        last = at;
      }
      expect(
        RegExp(r'<li id="step-').allMatches(iphone.substring(steps, stepsEnd)),
        hasLength(7),
      );
      // AltStore and the bare file only under "Other ways", after the steps.
      final int other = iphone.indexOf('data-i="otherWays"');
      expect(other, greaterThan(stepsEnd));
      expect(iphone.indexOf('altstore://'), greaterThan(other));
      expect(
        iphone.indexOf('releases/latest/download/Zen-unsigned.ipa'),
        greaterThan(other),
      );
      // Help for what goes wrong: the pairing file, at SideStore's own page.
      expect(
        iphone,
        contains('https://docs.sidestore.io/docs/advanced/pairing-file'),
      );
    });

    test('iPhone: every language adds the source by hand, sets up the '
        'automatic refresh and names the limit of a free account', () {
      final Map<String, Map<String, String>> texts = _texts(
        'install/iphone/index.html',
      );
      const String source =
          '`https://robertostrowskijagoda.github.io/Zen/apps.json`';
      for (final MapEntry<String, Map<String, String>> lang in texts.entries) {
        final Map<String, String> t = lang.value;
        expect(t['s5d'], allOf(contains(source), contains('**Sources**')));
        expect(
          t['s5d'],
          contains('**${t['addSideStore']}**'),
          reason: lang.key,
        );
        expect(t['s4d'], contains('**7 DAYS**'), reason: lang.key);
        expect(
          t['a2'],
          allOf(contains('**Set VPN**'), contains('**LocalDevVPN**')),
          reason: lang.key,
        );
        expect(t['a3'], contains('**Refresh All Apps**'), reason: lang.key);
        expect(t['freeLimit'], allOf(contains('3'), contains('10')));
        expect(t['s6d'], contains('7'), reason: lang.key);
      }
      expect(texts['en']!['s6d'], contains('no computer'));
      expect(texts['pl']!['s6d'], contains('bez komputera'));
      expect(texts['pl']!['s3d'], contains('VPN i zarządzanie urządzeniem'));
      expect(texts['pl']!['s3d'], contains('Tryb dewelopera'));
    });

    test('iPhone: the pictures are drawn on the page, hidden from screen '
        'readers, one per step', () {
      final String iphone = _read('install/iphone/index.html');
      final String steps = iphone.substring(
        iphone.indexOf('<ol class="how"'),
        iphone.indexOf('\n  </ol>'),
      );
      final List<String> figures = <String>[
        for (final RegExpMatch m in RegExp(
          r'<figure class="fig"[^>]*>(.*?)</figure>',
        ).allMatches(steps))
          m[0]!,
      ];
      expect(figures, hasLength(7));
      for (final String figure in figures) {
        expect(figure, contains('aria-hidden="true"'));
        expect(figure, contains('<svg viewBox='));
        // Drawn in the site's colours (light and dark), no picture files.
        expect(figure, isNot(contains('<img')));
        expect(figure, isNot(contains('href="http')));
        expect(figure, isNot(matches(RegExp(r'fill="#|stroke="#'))));
      }
      // The only image of the page is the app icon.
      expect(
        RegExp(r'<img ').allMatches(iphone).length,
        1,
        reason: 'the hero icon',
      );
      final String css = _read('site.css');
      for (final String token in <String>[
        '.fig .crd',
        '.fig .pillo',
        '.need',
      ]) {
        expect(css, contains(token), reason: token);
      }
    });

    test('Scarlet is gone from the website, and SideStore is thanked', () {
      for (final FileSystemEntity f in Directory(
        _site,
      ).listSync(recursive: true)) {
        if (f is! File || f.path.endsWith('.png')) {
          continue;
        }
        final String text = f.readAsStringSync().toLowerCase();
        expect(text, isNot(contains('scarlet')), reason: f.path);
        expect(text, isNot(contains('usescarlet')), reason: f.path);
      }
      final Map<String, Map<String, String>> common = _texts('site.js');
      for (final MapEntry<String, Map<String, String>> lang in common.entries) {
        expect(
          lang.value['thanks_1'],
          allOf(
            contains('|https://yggdrasil-network.github.io/]'),
            // Declined in some languages ("SideStoru").
            contains('[SideStor'),
            contains('|https://sidestore.io/]'),
          ),
          reason: lang.key,
        );
      }
      for (final String page in <String>[
        'about/index.html',
        'features/index.html',
      ]) {
        expect(
          _read(page),
          contains(
            '<a href="https://sidestore.io/" rel="noopener">SideStore</a>',
          ),
          reason: page,
        );
      }
    });

    test('every system page has a download or the steps, and a way on', () {
      for (final String os in <String>[
        'android',
        'iphone',
        'linux',
        'macos',
        'windows',
      ]) {
        final String html = _read('install/$os/index.html');
        expect(html, contains('class="btn'), reason: os);
        expect(html, contains('data-i='), reason: os);
      }
    });
  });

  group('help', () {
    test('Discord, issues and the docs are one tap from the support page', () {
      final String support = _read('support/index.html');
      final String shared = _read('site.js');
      expect(shared, contains('https://discord.gg/'));
      expect(shared, contains('/issues/new'));
      expect(shared, contains('docs/'));
      expect(support, contains('data-i='));
    });

    test('the about page has a table of contents and links to the docs', () {
      final String about = _read('about/index.html');
      expect(about, contains('tocLabel'));
      expect(about, contains('releases/latest'));
    });
  });
}
