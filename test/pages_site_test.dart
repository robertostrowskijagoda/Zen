import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/screenshots/shots.dart';

// The website (tool/pages): what its pages must keep, read from the files.
// The addresses people were given stay; every page can be read on a phone,
// is drawn in the shared look, has the app icon and the language picker; the
// downloads are links that follow each release by themselves and the iPhone
// page installs with SideStore, step by step with drawn pictures, the other
// ways only as other ways. The home page leads with the promise, one
// download and the reasons to try Zen, most tempting first; the about page
// tells the idea behind it; the promo page offers the poster, the film, a
// text to share and the QR codes, all made by tool/ci/promo_materials.py.

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
  'promo/index.html',
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

/// Width and height of a WebP file: the canvas of an extended (animated)
/// file, or the frame of a simple lossy or lossless one.
(int, int) _webpSize(String path) {
  final List<int> b = File(path).readAsBytesSync();
  expect(ascii.decode(b.sublist(0, 4)), 'RIFF', reason: path);
  expect(ascii.decode(b.sublist(8, 12)), 'WEBP', reason: path);
  int le(int at, int n) {
    int v = 0;
    for (int i = n - 1; i >= 0; i--) {
      v = (v << 8) | b[at + i];
    }
    return v;
  }

  switch (ascii.decode(b.sublist(12, 16))) {
    case 'VP8X':
      return (le(24, 3) + 1, le(27, 3) + 1);
    case 'VP8 ':
      return (le(26, 2) & 0x3fff, le(28, 2) & 0x3fff);
    case 'VP8L':
      final int bits = le(21, 4);
      return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
  }
  fail('$path: not a WebP picture');
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

/// The about page, where every printed QR code leads.
const String _aboutUrl = '${_base}about/';

/// The reasons on the home page, most tempting first: what nobody does with
/// your conversations, who is in your network, the price, the encryption,
/// what you can do, where, and last the pyramid.
const List<String> _reasons = <String>[
  'adv-private',
  'adv-known',
  'adv-free',
  'adv-quantum',
  'adv-together',
  'adv-devices',
  'adv-pyramid',
];

/// The files of the promo page made by tool/ci/promo_materials.py, with the
/// largest size each may have.
const Map<String, int> _promoFiles = <String, int>{
  'promo/zen-poster-pl.png': 2560 * 1024,
  'promo/zen-poster-en.png': 2560 * 1024,
  'promo/zen-poster-pl.pdf': 3 * 1024 * 1024,
  'promo/zen-poster-en.pdf': 3 * 1024 * 1024,
  'promo/zen-poster-pl-preview.webp': 150 * 1024,
  'promo/zen-poster-en-preview.webp': 150 * 1024,
  'promo/zen-qr-about.png': 100 * 1024,
  'promo/zen-qr-about.svg': 50 * 1024,
  'promo/zen-qr-about-pl.pdf': 300 * 1024,
  'promo/zen-qr-about-en.pdf': 300 * 1024,
};

/// The promo film, made apart from the site: checked once it is there.
const Map<String, int> _filmFiles = <String, int>{
  'promo/zen-promo.mp4': 20 * 1024 * 1024,
  'promo/zen-promo.webm': 20 * 1024 * 1024,
  'promo/zen-promo-poster.jpg': 600 * 1024,
};

/// The dark modules of a QR code drawn as an SVG path of runs
/// (`M{x} {y}h{w}v1h-{w}z`, promo_materials.py), quiet zone included.
List<List<bool>> _svgModules(String svg) {
  final RegExpMatch box = RegExp(r'viewBox="0 0 (\d+) (\d+)"').firstMatch(svg)!;
  final int n = int.parse(box[1]!);
  expect(int.parse(box[2]!), n);
  final List<List<bool>> m = <List<bool>>[
    for (int y = 0; y < n; y++) List<bool>.filled(n, false),
  ];
  for (final RegExpMatch run in RegExp(
    r'M(\d+) (\d+)h(\d+)v1h-\3z',
  ).allMatches(svg)) {
    final int x = int.parse(run[1]!), y = int.parse(run[2]!);
    for (int i = 0; i < int.parse(run[3]!); i++) {
      m[y][x + i] = true;
    }
  }
  return m;
}

/// Reads a QR code (byte mode, versions 1 to 6) the way a scanner does:
/// the finder and timing patterns, the format information (both copies,
/// checked against their BCH code), the data under its mask, the blocks
/// put back in order. Returns the text and the error correction level.
(String, String) _readQr(List<List<bool>> withQuiet, int quiet) {
  final int size = withQuiet.length - 2 * quiet;
  bool at(int x, int y) => withQuiet[y + quiet][x + quiet];
  final int version = (size - 17) ~/ 4;
  expect(size, version * 4 + 17, reason: 'a QR code size');
  expect(version, inInclusiveRange(1, 6));
  // The quiet zone is light.
  for (int i = 0; i < withQuiet.length; i++) {
    for (int q = 0; q < quiet; q++) {
      expect(withQuiet[i][q] || withQuiet[q][i], isFalse);
    }
  }
  // Finder patterns in three corners, timing patterns between them.
  for (final (int, int) c in <(int, int)>[
    (3, 3),
    (size - 4, 3),
    (3, size - 4),
  ]) {
    for (int dy = -3; dy <= 3; dy++) {
      for (int dx = -3; dx <= 3; dx++) {
        final int d = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        expect(at(c.$1 + dx, c.$2 + dy), d != 2, reason: 'finder $c');
      }
    }
  }
  for (int i = 8; i < size - 8; i++) {
    expect(at(i, 6), i.isEven, reason: 'timing row');
    expect(at(6, i), i.isEven, reason: 'timing column');
  }
  // Format information: both copies alike and a valid BCH(15, 5) word.
  int bits(List<(int, int)> cells) {
    int v = 0;
    for (int i = 0; i < cells.length; i++) {
      if (at(cells[i].$1, cells[i].$2)) {
        v |= 1 << i;
      }
    }
    return v;
  }

  final int first = bits(<(int, int)>[
    for (int i = 0; i < 6; i++) (8, i),
    (8, 7),
    (8, 8),
    (7, 8),
    for (int i = 9; i < 15; i++) (14 - i, 8),
  ]);
  final int second = bits(<(int, int)>[
    for (int i = 0; i < 8; i++) (size - 1 - i, 8),
    for (int i = 8; i < 15; i++) (8, size - 15 + i),
  ]);
  expect(second, first, reason: 'the two copies of the format');
  expect(at(8, size - 8), isTrue, reason: 'the dark module');
  final int format = first ^ 0x5412;
  int rem = format >> 10;
  for (int i = 0; i < 10; i++) {
    rem = (rem << 1) ^ ((rem >> 9) * 0x537);
  }
  expect(format & 0x3ff, rem, reason: 'the BCH code of the format');
  final String level = const <int, String>{
    1: 'L',
    0: 'M',
    3: 'Q',
    2: 'H',
  }[format >> 13]!;
  final int mask = (format >> 10) & 7;
  // The cells that carry data: all but the patterns and the format.
  final List<List<bool>> fixed = <List<bool>>[
    for (int y = 0; y < size; y++) List<bool>.filled(size, false),
  ];
  void block(int x0, int y0, int x1, int y1) {
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        if (x >= 0 && y >= 0 && x < size && y < size) {
          fixed[y][x] = true;
        }
      }
    }
  }

  block(0, 0, 8, 8);
  block(size - 8, 0, size - 1, 8);
  block(0, size - 8, 8, size - 1);
  block(6, 0, 6, size - 1);
  block(0, 6, size - 1, 6);
  if (version > 1) {
    final int a = size - 7;
    block(a - 2, a - 2, a + 2, a + 2);
  }
  bool masked(int x, int y) => switch (mask) {
    0 => (x + y) % 2 == 0,
    1 => y % 2 == 0,
    2 => x % 3 == 0,
    3 => (x + y) % 3 == 0,
    4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
    5 => x * y % 2 + x * y % 3 == 0,
    6 => (x * y % 2 + x * y % 3) % 2 == 0,
    _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
  };
  final List<int> stream = <int>[];
  for (int right = size - 1; right >= 1; right -= 2) {
    if (right == 6) {
      right = 5;
    }
    final bool upward = ((right + 1) & 2) == 0;
    for (int vert = 0; vert < size; vert++) {
      final int y = upward ? size - 1 - vert : vert;
      for (int j = 0; j < 2; j++) {
        final int x = right - j;
        if (!fixed[y][x]) {
          stream.add(at(x, y) != masked(x, y) ? 1 : 0);
        }
      }
    }
  }
  final List<int> words = <int>[
    for (int i = 0; i + 8 <= stream.length; i += 8)
      stream.sublist(i, i + 8).fold(0, (int v, int b) => v << 1 | b),
  ];
  // The blocks of each version and level (ISO/IEC 18004, table 9).
  const Map<String, List<int>> blocks = <String, List<int>>{
    '1L': <int>[19],
    '1M': <int>[16],
    '1Q': <int>[13],
    '1H': <int>[9],
    '2L': <int>[34],
    '2M': <int>[28],
    '2Q': <int>[22],
    '2H': <int>[16],
    '3L': <int>[55],
    '3M': <int>[44],
    '3Q': <int>[17, 17],
    '3H': <int>[13, 13],
    '4L': <int>[80],
    '4M': <int>[32, 32],
    '4Q': <int>[24, 24],
    '4H': <int>[9, 9, 9, 9],
    '5L': <int>[108],
    '5M': <int>[43, 43],
    '5Q': <int>[15, 15, 16, 16],
    '5H': <int>[11, 11, 12, 12],
    '6L': <int>[68, 68],
    '6M': <int>[27, 27, 27, 27],
    '6Q': <int>[19, 19, 19, 19],
    '6H': <int>[15, 15, 15, 15],
  };
  final List<int> sizes = blocks['$version$level']!;
  final List<List<int>> data = <List<int>>[for (final int _ in sizes) <int>[]];
  int k = 0;
  for (int i = 0; i < sizes.reduce((int a, int b) => a > b ? a : b); i++) {
    for (int b = 0; b < sizes.length; b++) {
      if (i < sizes[b]) {
        data[b].add(words[k++]);
      }
    }
  }
  final List<int> all = <int>[for (final List<int> b in data) ...b];
  expect(all[0] >> 4, 4, reason: 'byte mode');
  final int length = (all[0] & 15) << 4 | all[1] >> 4;
  final List<int> bytes = <int>[
    for (int i = 0; i < length; i++) (all[1 + i] & 15) << 4 | all[2 + i] >> 4,
  ];
  return (utf8.decode(bytes), level);
}

/// The relative addresses (href, src, srcset, poster) of a page.
List<String> _relativeLinks(String html) => <String>[
  for (final RegExpMatch m in RegExp(
    r'''\s(?:href|src|srcset|poster)="([^"]+)"''',
  ).allMatches(html))
    if (!RegExp(r'^(?:[a-z][a-z0-9+.-]*:|#|/)').hasMatch(m[1]!)) m[1]!,
];

/// The ids of a page (the targets of `#fragment` links).
Set<String> _ids(String html) => <String>{
  for (final RegExpMatch m in RegExp(r'\sid="([^"]+)"').allMatches(html)) m[1]!,
};

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
        if (f is! File ||
            RegExp(r'\.(png|webp|jpg|pdf|mp4|webm)$').hasMatch(f.path)) {
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

  group('screenshots of the app', () {
    test('every picture and film the pages show is in shots/, small enough, '
        'and nothing else is there', () {
      final Map<String, int> expected = expectedShotFiles();
      expect(expected, isNotEmpty);
      expected.forEach((String path, int limit) {
        final File file = File('$_site/$path');
        expect(
          file.existsSync(),
          isTrue,
          reason: '$path is missing: run `dart run tool/screenshots.dart`',
        );
        expect(file.lengthSync(), lessThanOrEqualTo(limit), reason: path);
      });
      final List<String> kept = <String>[
        for (final FileSystemEntity e in Directory(
          kShotsDir,
        ).listSync(recursive: true))
          if (e is File)
            e.path.replaceAll(r'\', '/').substring('$_site/'.length),
      ];
      expect(kept.toSet(), expected.keys.toSet());
    });

    test('the pictures are WebP of the phone and computer sizes, the films '
        "at half the phone's", () {
      final (int, int) filmSize = (
        (ShotSize.phone.pixelWidth * kFilmScale).round(),
        (ShotSize.phone.pixelHeight * kFilmScale).round(),
      );
      for (final String lang in kShotLanguages) {
        for (final String theme in kShotThemes) {
          for (final SiteShot shot in kSiteShots) {
            expect(_webpSize('$_site/${shotPath(lang, shot.id, theme)}'), (
              shot.size.pixelWidth,
              shot.size.pixelHeight,
            ), reason: '$lang ${shot.id} $theme');
          }
          for (final SiteFilm film in kSiteFilms) {
            expect(
              _webpSize('$_site/${filmPath(lang, film.id, theme)}'),
              filmSize,
            );
            expect(
              _webpSize('$_site/${posterPath(lang, film.id, theme)}'),
              filmSize,
            );
          }
        }
      }
    });

    test('every screenshot loads lazily, keeps its size, has a dark variant '
        'and an alt text in every language', () {
      final Map<String, Map<String, String>> common = _texts('site.js');
      int count = 0;
      for (final String page in _pages) {
        final String html = _read(page);
        for (final RegExpMatch m in RegExp(
          r'<picture>(.*?)</picture>',
          dotAll: true,
        ).allMatches(html)) {
          final String picture = m[1]!;
          if (!picture.contains('shots/')) {
            continue;
          }
          count++;
          final String img = RegExp(r'<img [^>]*>').firstMatch(picture)![0]!;
          expect(img, contains('loading="lazy"'), reason: '$page $img');
          expect(img, contains('decoding="async"'), reason: '$page $img');
          expect(img, matches(RegExp(r'width="\d+" height="\d+"')));
          final String src = RegExp(r'src="([^"]+)"').firstMatch(img)![1]!;
          expect(src, startsWith('${_up(page)}shots/$kShotFallbackLanguage/'));
          final String file = src.substring(_up(page).length);
          expect(File('$_site/$file').existsSync(), isTrue, reason: file);
          expect(
            picture,
            contains(
              '<source media="(prefers-color-scheme: dark)" srcset="'
              '${src.replaceFirst('-light.webp', '-dark.webp')}">',
            ),
            reason: '$page $src',
          );
          final String key = RegExp(r'data-ia="(\w+)"').firstMatch(img)![1]!;
          final String alt = RegExp(r'alt="([^"]+)"').firstMatch(img)![1]!;
          expect(_unescape(alt), common['en']![key], reason: '$page $key');
          for (final MapEntry<String, Map<String, String>> lang
              in common.entries) {
            expect(
              lang.value[key]?.length ?? 0,
              greaterThan(8),
              reason: '${lang.key} $key',
            );
          }
        }
      }
      expect(count, greaterThanOrEqualTo(kSiteShots.length + 10));
    });

    test('the features page shows every screen and both films; the home and '
        'about pages a gallery of their own', () {
      final String features = _read('features/index.html');
      for (final SiteShot shot in kSiteShots) {
        final String path = shotPath(kShotFallbackLanguage, shot.id, 'light');
        expect(features, contains('src="../$path"'), reason: shot.id);
      }
      for (final SiteFilm film in kSiteFilms) {
        final String path = filmPath(kShotFallbackLanguage, film.id, 'light');
        expect(features, contains('src="../$path"'), reason: film.id);
      }
      for (final String page in <String>[
        'index.html',
        'about/index.html',
        'features/index.html',
      ]) {
        final String html = _read(page);
        expect(html, contains('<div class="gallery">'), reason: page);
        expect(
          html,
          contains(
            '<div class="gallery-track" tabindex="0" role="region" '
            'data-ial="galleryLabel"',
          ),
          reason: 'a keyboard reaches the row: $page',
        );
        for (final String button in <String>['Prev', 'Next']) {
          expect(
            html,
            contains(
              'class="gallery-${button.toLowerCase()}" type="button" '
              'data-ial="gallery$button"',
            ),
            reason: '$page $button',
          );
        }
        expect(html, contains('data-i="shotsTitle"'), reason: page);
      }
      // On the about page the section is in the table of contents too.
      expect(_read('about/index.html'), contains('href="#shots"'));
    });

    test("a visitor who asked for less motion sees the films' still "
        'posters', () {
      final String features = _read('features/index.html');
      final List<String> films = <String>[
        for (final RegExpMatch m in RegExp(
          r'<figure class="film">(.*?)</figure>',
          dotAll: true,
        ).allMatches(features))
          m[1]!,
      ];
      expect(films, hasLength(kSiteFilms.length));
      for (final String film in films) {
        final int still = film.indexOf(
          'media="(prefers-reduced-motion: reduce) and '
          '(prefers-color-scheme: dark)"',
        );
        final int stillLight = film.indexOf(
          'media="(prefers-reduced-motion: reduce)"',
        );
        final int moving = film.indexOf('media="(prefers-color-scheme: dark)"');
        // The first source that fits wins: the posters come first.
        expect(still, greaterThan(0));
        expect(stillLight, greaterThan(still));
        expect(moving, greaterThan(stillLight));
        expect(film, contains('-poster.webp'));
      }
    });

    test('the pictures follow the language shown (English where there are '
        'none), and the row scrolls by itself, never the page', () {
      final String js = _read('site.js');
      final RegExpMatch langs = RegExp(
        r'var SHOT_LANGS = \[([^\]]*)\];',
      ).firstMatch(js)!;
      expect(
        RegExp(r'"(\w+)"').allMatches(langs[1]!).map((RegExpMatch m) => m[1]),
        kShotLanguages,
      );
      expect(js, contains('function showShots()'));
      expect(js, contains('function galleries()'));
      expect(js, contains('prefers-reduced-motion: reduce'));
      for (final String key in <String>['ArrowLeft', 'ArrowRight', 'Home']) {
        expect(js, contains('"$key"'), reason: key);
      }
      final String css = _read('site.css');
      final int at = css.indexOf('.gallery-track {');
      final String track = css.substring(at, css.indexOf('}', at));
      expect(track, contains('overflow-x: auto'));
      expect(track, contains('scroll-snap-type: x mandatory'));
    });

    test('they are made by tool/screenshots.dart, which CI runs to check '
        'that none is missing', () {
      for (final String file in <String>[
        'tool/screenshots.dart',
        'tool/screenshots/site_screens_test.dart',
        'tool/screenshots/encode.py',
      ]) {
        expect(File(file).existsSync(), isTrue, reason: file);
      }
      expect(
        File('.github/workflows/ci.yml').readAsStringSync(),
        contains('dart run tool/screenshots.dart --check'),
      );
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

  group('telling people about Zen', () {
    test('the home page leads with the promise, one big download for the '
        "visitor's system and how it works, then the reasons", () {
      final String home = _read('index.html');
      final Map<String, Map<String, String>> texts = _texts('index.html');
      int at(String part) {
        final int i = home.indexOf(part);
        expect(i, greaterThan(0), reason: part);
        return i;
      }

      // In this order: the promise, the download, the reasons, the
      // screenshots, how it works, the idea, questions, the last call.
      final List<int> order = <int>[
        at('data-i="heroTitle"'),
        at('data-i="lead"'),
        at('id="android" class="btn primary big block"'),
        at('href="#how"'),
        at('<section class="sec" id="why"'),
        at('<section class="sec" id="shots"'),
        at('<section class="sec" id="how"'),
        at('<section class="sec" id="idea"'),
        at('<section class="sec" id="faq"'),
        at('<section class="sec final" id="start"'),
      ];
      for (int i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]), reason: 'part $i');
      }
      // Every system keeps its big button; the script shows the visitor's.
      for (final String os in <String>[
        'android',
        'windows',
        'linux',
        'iphone',
        'macos',
      ]) {
        expect(home, contains('id="$os" class="btn primary big block"'));
      }
      expect(home, contains('Zen.systemButtons()'));
      // An invitation still opens the app first; the home page only offers
      // it to those who have the app, and stays a page to read.
      expect(home, contains('Zen.t(code ? "invTitle" : "heroTitle")'));
      expect(home, contains('if (android && code && !noApp)'));
      expect(home, contains('id="openApp"'));
      for (final MapEntry<String, Map<String, String>> lang in texts.entries) {
        expect(lang.value['heroTitle'], isNotEmpty, reason: lang.key);
        expect(
          lang.value['heroTitle'],
          isNot(lang.value['invTitle']),
          reason: lang.key,
        );
      }
      expect(texts['en']!['heroTitle'], 'Your people. No company in between.');
      expect(texts['pl']!['heroTitle'], 'Twoi ludzie. Bez firmy pośrodku.');
    });

    test('the reasons go from the most tempting, in a stable order, each '
        'with an icon and a text in every language', () {
      final String home = _read('index.html');
      final String list = home.substring(
        home.indexOf('<ol class="adv">'),
        home.indexOf('</ol>', home.indexOf('<ol class="adv">')),
      );
      final List<String> ids = <String>[
        for (final RegExpMatch m in RegExp(
          r'<li id="(adv-[a-z]+)" class="feat"><div class="fi"><svg class="ico"',
        ).allMatches(list))
          m[1]!,
      ];
      expect(ids, _reasons);
      for (int i = 0; i < _reasons.length; i++) {
        final String item = list.substring(
          list.indexOf('id="${_reasons[i]}"'),
          i + 1 < _reasons.length
              ? list.indexOf('id="${_reasons[i + 1]}"')
              : list.length,
        );
        expect(item, contains('data-i="a${i + 1}t"'), reason: _reasons[i]);
        expect(item, contains('data-i="a${i + 1}d"'), reason: _reasons[i]);
      }
      final Map<String, Map<String, String>> texts = _texts('index.html');
      for (final MapEntry<String, Map<String, String>> lang in texts.entries) {
        for (int i = 1; i <= _reasons.length; i++) {
          expect(lang.value['a${i}t'], isNotEmpty, reason: '${lang.key} $i');
          expect(
            lang.value['a${i}d']!.length,
            greaterThan(30),
            reason: '${lang.key} $i',
          );
        }
      }
      // The first reason is privacy, the last the pyramid.
      expect(texts['en']!['a1t'], 'Nobody reads your conversations');
      expect(texts['pl']!['a1t'], 'Nikt nie czyta Twoich rozmów');
      expect(texts['en']!['a7d'], contains('pyramid'));
      expect(texts['pl']!['a7d'], contains('Piramida'));
    });

    test('what invites people never sells the offline links: not the '
        'promise, the reasons, the poster nor the text to share', () {
      final List<String> selling = <String>[
        for (final String key in <String>['heroTitle', 'lead', 'desc'])
          for (final String lang in <String>['en', 'pl'])
            _texts('index.html')[lang]![key]!,
        for (int i = 1; i <= _reasons.length; i++)
          for (final String lang in <String>['en', 'pl'])
            _texts('index.html')[lang]!['a${i}d']!,
        for (final Map<String, String> t in _texts('promo/index.html').values)
          ...t.values,
        _read('promo/index.html'),
        File('tool/ci/promo_materials.py').readAsStringSync(),
      ];
      for (final String text in selling) {
        final String lower = text.toLowerCase();
        for (final String word in <String>[
          'internet',
          'offline',
          'bluetooth',
          'wi-fi',
          'wifi',
        ]) {
          expect(lower, isNot(contains(word)), reason: word);
        }
      }
    });

    test('the idea behind Zen is told on the about page in the author\'s '
        'words, with a teaser on the home page', () {
      final String about = _read('about/index.html');
      final Map<String, Map<String, String>> texts = _texts('about/index.html');
      final int toc = about.indexOf('href="#story"');
      expect(toc, greaterThan(0));
      expect(toc, lessThan(about.indexOf('href="#shots"')));
      final int story = about.indexOf('<section id="story"');
      expect(story, greaterThan(about.indexOf('<section id="what"')));
      expect(story, lessThan(about.indexOf('<section id="shots"')));
      for (final MapEntry<String, Map<String, String>> lang in texts.entries) {
        for (int i = 1; i <= 6; i++) {
          expect(
            lang.value['story_$i']!.length,
            greaterThan(40),
            reason: '${lang.key} story_$i',
          );
        }
        expect(
          lang.value['storySig'],
          contains('Robert Ostrowski-Jagoda'),
          reason: lang.key,
        );
      }
      // Openly about politics, and a social network first.
      final String en = <String>[
        for (int i = 1; i <= 6; i++) texts['en']!['story_$i']!,
      ].join(' ');
      final String pl = <String>[
        for (int i = 1; i <= 6; i++) texts['pl']!['story_$i']!,
      ].join(' ');
      for (final String part in <String>[
        'purely political app',
        'social network first',
        'pyramid',
        'no headquarters',
        'democracy',
      ]) {
        expect(en, contains(part), reason: part);
      }
      for (final String part in <String>[
        'czysto politycznej aplikacji',
        'najpierw zbudowałem sieć społecznościową',
        'piramida',
        'centrali',
        'demokracja',
      ]) {
        expect(pl, contains(part), reason: part);
      }
      expect(texts['pl']!['story_t'], 'Co stoi za pomysłem');
      // The home page's teaser leads there.
      final String home = _read('index.html');
      expect(home, contains('href="about/#story"'));
      expect(_texts('index.html')['pl']!['story_t'], 'Co stoi za pomysłem');
    });

    test('the questions answer safety, the stores and a lost phone as the '
        'guide does', () {
      final String home = _read('index.html');
      for (final String id in <String>[
        'faq-safe',
        'faq-store',
        'faq-lost',
        'faq-friends',
      ]) {
        expect(home, contains('<details class="acc" id="$id">'), reason: id);
      }
      final Map<String, Map<String, String>> texts = _texts('index.html');
      for (final String way in <String>[
        'another device',
        'full account copy',
        'key copy',
        'recovery circle',
        'forgot password',
      ]) {
        expect(texts['en']!['r3'], contains(way), reason: way);
      }
      for (final String way in <String>[
        'drugiego urządzenia',
        'kopii całego konta',
        'kopii klucza',
        'kręgu odzyskiwania',
        'zapomniałem hasła',
      ]) {
        expect(texts['pl']!['r3'], contains(way), reason: way);
      }
      expect(texts['pl']!['q1'], 'Czy to bezpieczne?');
      expect(texts['pl']!['q2'], 'Czemu nie ma go w sklepie?');
      expect(texts['pl']!['q3'], 'Co jeśli zgubię telefon?');
      for (final Map<String, String> t in texts.values) {
        expect(t['r1'], contains('docs/SECURITY_MODEL.md]'));
        expect(t['r2'], contains('|about/#stores]'));
      }
    });

    test('the promo page offers the poster, the film, a text to share, the '
        'QR codes and the app\'s own sticker, and is one tap away', () {
      final String promo = _read('promo/index.html');
      for (final String file in <String>[
        ..._promoFiles.keys,
        ..._filmFiles.keys,
      ]) {
        if (file.endsWith('-preview.webp')) {
          expect(promo, contains('src="${file.substring(6)}"'), reason: file);
        } else {
          expect(promo, contains('"${file.substring(6)}"'), reason: file);
        }
      }
      for (final String section in <String>[
        'poster',
        'film',
        'share',
        'qr',
        'sticker',
      ]) {
        expect(promo, contains('<section class="sec" id="$section"'));
      }
      // The film never plays by itself and shows only once its files are
      // published; until then a short note.
      final String video = promo.substring(
        promo.indexOf('<video'),
        promo.indexOf('</video>'),
      );
      expect(video, contains('preload="none"'));
      expect(video, contains('controls'));
      expect(video, contains('poster="zen-promo-poster.jpg"'));
      expect(video, isNot(contains('autoplay')));
      expect(
        promo,
        contains('<figure id="promoFilm" class="promo-film hidden">'),
      );
      expect(promo, contains('method: "HEAD"'));
      expect(promo, contains('data-i="filmSoon"'));
      // Both texts to share name the about page, in their own language.
      for (final String lang in <String>['pl', 'en']) {
        final RegExpMatch share = RegExp(
          '<div class="card share" lang="$lang">.*?<p id="share\\w+">([^<]+)</p>',
          dotAll: true,
        ).firstMatch(promo)!;
        expect(share[1], endsWith(_aboutUrl), reason: lang);
        expect(share[1], contains('Zen'), reason: lang);
      }
      expect(
        _texts('promo/index.html')['en']!['sticker_d'],
        allOf(contains('About'), contains('invitation')),
      );
      // In the footer of every page and on the about page.
      final String js = _read('site.js');
      expect(js, contains("ROOT + 'promo/\" data-i=\"footPromo\""));
      for (final Map<String, String> t in _texts('site.js').values) {
        expect(t['footPromo'], isNotEmpty);
      }
      expect(_read('about/index.html'), contains('href="../promo/"'));
    });

    test('the poster and the QR codes are there, in the A series\' '
        'proportions and within their sizes; the film once it is there', () {
      _promoFiles.forEach((String path, int limit) {
        final File file = File('$_site/$path');
        expect(
          file.existsSync(),
          isTrue,
          reason: '$path: run `python tool/ci/promo_materials.py`',
        );
        expect(file.lengthSync(), lessThanOrEqualTo(limit), reason: path);
        if (path.endsWith('.pdf')) {
          final List<int> head = file.openSync().readSync(8);
          expect(ascii.decode(head.sublist(0, 5)), '%PDF-', reason: path);
          expect(
            file.readAsStringSync(encoding: latin1),
            contains('/MediaBox [0 0 595.28 841.89]'),
          );
        }
      });
      for (final String lang in <String>['pl', 'en']) {
        // A4 at 300 dpi.
        expect(_pngSize('$_site/promo/zen-poster-$lang.png'), (2480, 3508));
        final (int w, int h) = _webpSize(
          '$_site/promo/zen-poster-$lang-preview.webp',
        );
        expect((h / w * 1000).round(), (3508 / 2480 * 1000).round());
      }
      final (int qw, int qh) = _pngSize('$_site/promo/zen-qr-about.png');
      expect(qw, qh);
      expect(qw, greaterThanOrEqualTo(1000));
      _filmFiles.forEach((String path, int limit) {
        final File file = File('$_site/$path');
        if (file.existsSync()) {
          expect(file.lengthSync(), lessThanOrEqualTo(limit), reason: path);
        }
      });
      for (final String file in <String>[
        'tool/ci/promo_materials.py',
        'tool/ci/qr.py',
      ]) {
        expect(File(file).existsSync(), isTrue, reason: file);
      }
    });

    test('the QR code reads as the about page, at a level that survives '
        'a worn print', () {
      final String svg = _read('promo/zen-qr-about.svg');
      final (String text, String level) = _readQr(_svgModules(svg), 4);
      expect(text, _aboutUrl);
      expect(level, 'Q');
      expect(svg, contains('<title>QR: $_aboutUrl</title>'));
      expect(
        File('tool/ci/promo_materials.py').readAsStringSync(),
        contains('ABOUT = "$_aboutUrl"'),
      );
    });

    test('every relative link, picture and #fragment of the site leads to '
        'something that is there', () {
      final String js = _read('site.js');
      final Set<String> icons = <String>{
        for (final RegExpMatch m in RegExp(
          r"^    (\w+): (?:'|\[)",
          multiLine: true,
        ).allMatches(js.substring(js.indexOf('var ICONS = {'))))
          m[1]!,
      };
      expect(icons, containsAll(<String>['eyeoff', 'gift', 'printer']));
      final List<String> missing = <String>[];
      for (final String page in <String>[..._pages, '404.html']) {
        // Comments are notes for whoever edits the page, not links.
        final String html = _read(
          page,
        ).replaceAll(RegExp('<!--.*?-->', dotAll: true), '');
        final String dir = page.contains('/')
            ? page.substring(0, page.lastIndexOf('/') + 1)
            : '';
        final List<String> links = <String>[
          ..._relativeLinks(html),
          // Links inside the texts: [label|path].
          for (final String text in _texts(page)['en']!.values)
            for (final RegExpMatch m in RegExp(
              r'\[[^|\]]+\|([^\]]+)\]',
            ).allMatches(text))
              if (m[1]!.contains('/') && !m[1]!.startsWith('http')) m[1]!,
        ];
        for (final String link in links) {
          final String clean = link.split(' ').first;
          final String fragment = clean.contains('#')
              ? clean.substring(clean.indexOf('#') + 1)
              : '';
          String path = clean.replaceFirst(RegExp(r'[?#].*$'), '');
          path = Uri.parse('x:/$dir').resolve(path).path.substring(1);
          if (path.isEmpty || path.endsWith('/')) {
            path = '${path}index.html';
          }
          if (_filmFiles.containsKey(path)) {
            continue;
          }
          final File file = File('$_site/$path');
          if (!file.existsSync()) {
            missing.add('$page -> $link');
          } else if (fragment.isNotEmpty &&
              !_ids(file.readAsStringSync()).contains(fragment)) {
            missing.add('$page -> $link (#$fragment)');
          }
        }
        // "#id" on the page itself; "#i-name" is an icon of the shared
        // script's sprite.
        final Set<String> ids = _ids(html);
        for (final RegExpMatch m in RegExp(
          r'\shref="#([^"]+)"',
        ).allMatches(html)) {
          final String id = m[1]!;
          final bool there = id.startsWith('i-')
              ? icons.contains(id.substring(2))
              : ids.contains(id);
          if (!there) {
            missing.add('$page -> #$id');
          }
        }
      }
      expect(missing, isEmpty);
    });

    test('only the rows meant to scroll sideways do, and no box is wider '
        'than a phone', () {
      final String css = _read('site.css');
      final List<String> scrolling = <String>[];
      for (final RegExpMatch m in RegExp(
        r'([^{}]+)\{[^}]*overflow-x:\s*(auto|scroll)',
      ).allMatches(css)) {
        scrolling.add(m[1]!.trim().split('\n').last.trim());
      }
      expect(scrolling, <String>['pre', '.files-wrap', '.gallery-track']);
      for (final RegExpMatch m in RegExp(
        r'(?<![-\w])width:\s*(\d+)px',
      ).allMatches(css)) {
        expect(int.parse(m[1]!), lessThanOrEqualTo(340), reason: m[0]);
      }
      for (final String page in _pages) {
        expect(_read(page), isNot(contains('100vw')), reason: page);
      }
    });
  });
}
