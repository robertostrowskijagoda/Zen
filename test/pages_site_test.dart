import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The website (tool/pages): what its pages must keep, read from the files.
// The addresses people were given stay; every page can be read on a phone,
// is drawn in the shared look, has the app icon and the language picker; the
// downloads are links that follow each release by themselves and the iPhone
// page installs with Scarlet, the other ways only as other ways.

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

String _read(String page) => File('$_site/$page').readAsStringSync();

/// The way up from [page] to the root of the site: "", "../", "../../".
String _up(String page) => '../' * (page.split('/').length - 1);

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

    test('the iPhone sources are made from the release, not kept here', () {
      expect(File('$_site/apps.json').existsSync(), isFalse);
      expect(File('$_site/scarlet.json').existsSync(), isFalse);
      final String workflow = File(
        '.github/workflows/pages.yml',
      ).readAsStringSync();
      expect(workflow, contains('apps.json'));
      expect(workflow, contains('scarlet.json'));
      expect(workflow, contains('release_source.py'));
      expect(
        File('tool/ci/release_source.py').readAsStringSync(),
        contains('"scarlet.json"'),
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

    test('iPhone: Scarlet is the way, at its own address, and the other '
        'stores are other ways', () {
      final String iphone = _read('install/iphone/index.html');
      expect(iphone, contains('https://usescarlet.com/'));
      expect(iphone.indexOf('Scarlet'), lessThan(iphone.indexOf('SideStore')));
      expect(iphone, contains('Zen-unsigned.ipa'));
      // The page warns that a certificate can be revoked.
      expect(iphone, contains('revoke'));
      // The about page thanks Yggdrasil and Scarlet.
      expect(_read('site.js'), contains('https://usescarlet.com/'));
    });

    test('iPhone: the Scarlet source is only another way, after the steps, '
        'with the address to paste', () {
      final String iphone = _read('install/iphone/index.html');
      const String source =
          'https://robertostrowskijagoda.github.io/Zen/scarlet.json';
      expect(iphone, contains('href="scarlet://source=$source"'));
      // The four steps stay as they are; the source comes under "Other
      // ways", never as a step.
      final int steps = iphone.indexOf('</ol>');
      expect(iphone.indexOf('scarlet://'), greaterThan(steps));
      expect(
        iphone.indexOf('scarlet://'),
        greaterThan(iphone.indexOf('data-i="otherWays"')),
      );
      expect('<li>'.allMatches(iphone.substring(0, steps)), hasLength(4));
      // Every language says how to add it by hand, with the address.
      final String texts = iphone.substring(iphone.indexOf('var TEXTS'));
      expect('"scarletSource": '.allMatches(texts), hasLength(21));
      expect('"addScarlet": '.allMatches(texts), hasLength(21));
      expect('**Add Repo**'.allMatches(texts), hasLength(21));
      expect('`$source`'.allMatches(texts), hasLength(21));
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
