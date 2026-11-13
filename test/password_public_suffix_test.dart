import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_match.dart';
import 'package:zen/src/features/passwords/public_suffix.dart';
import 'package:zen/src/features/passwords/public_suffix_rules.dart';

// "Same site" for the autofill: a login saved for one host is offered on
// another host only when both have the same registrable domain by the
// Public Suffix List (its ICANN and private parts, wildcards and
// exceptions), so a subdomain under a public suffix (`gdynia.pl`,
// `trycloudflare.com`, `s3.amazonaws.com`) is somebody else's. Hosts are
// compared in their ASCII form, as browsers report them.

PasswordEntry _entry(String address) => PasswordEntry(
  id: 'e0000000001',
  versionKey: 'v0000000001',
  fields: PasswordFields(name: 'x', password: 'p', address: address),
  createdAtMillis: 1,
  changedAtMillis: 1,
);

List<PasswordMatchKind> _kinds(String saved, String page) =>
    <PasswordMatchKind>[
      for (final PasswordMatch m in matchPasswordEntries(
        <PasswordEntry>[_entry(saved)],
        webDomain: page,
        webScheme: 'https',
      ))
        m.kind,
    ];

void main() {
  test('the list\'s own test vectors', () {
    // test/fixtures/public_suffix/test_psl.txt, refreshed with the list by
    // tool/public_suffix_list.dart: `checkPublicSuffix(host, registrable)`.
    final RegExp check = RegExp(
      r"^checkPublicSuffix\((null|'([^']*)'), (null|'([^']*)')\);",
    );
    int checked = 0;
    for (final String line in File(
      'test/fixtures/public_suffix/test_psl.txt',
    ).readAsLinesSync()) {
      final RegExpMatch? m = check.firstMatch(line.trim());
      if (m == null) {
        continue;
      }
      final String? host = m.group(2);
      final String? expected = m.group(4);
      final String? got = host == null
          ? null
          : publicSuffixList.registrableDomain(host);
      expect(
        got,
        expected == null ? isNull : asciiHost(expected),
        reason: line,
      );
      checked++;
    }
    expect(checked, greaterThan(70));
  });

  test('the list is the whole list: both parts, wildcards and exceptions', () {
    expect(publicSuffixList.length, greaterThan(9000));
    for (final String suffix in <String>[
      'com',
      'co.uk',
      'gdynia.pl',
      'sopot.pl',
      'med.pl',
      'tokyo.jp',
      'github.io',
      'trycloudflare.com',
      's3.amazonaws.com',
      'blob.core.windows.net',
      'up.railway.app',
    ]) {
      expect(publicSuffixList.publicSuffix('a.$suffix'), suffix);
    }
    // `*.ck`, `!www.ck`.
    expect(publicSuffixList.registrableDomain('a.b.ck'), 'a.b.ck');
    expect(publicSuffixList.registrableDomain('www.ck'), 'www.ck');
    expect(
      DateTime.tryParse(kPublicSuffixListVersion.split('_').first),
      isNotNull,
    );
  });

  // Each pair: the page the entry was saved for, someone else's page under
  // the same public suffix.
  const List<(String, String)> pairs = <(String, String)>[
    ('https://sklep.gdynia.pl', 'evil.gdynia.pl'),
    ('https://sklep.sopot.pl', 'evil.sopot.pl'),
    ('https://pensjonat.zakopane.pl', 'evil.zakopane.pl'),
    ('https://galeria.art.pl', 'evil.art.pl'),
    ('https://gabinet.med.pl', 'evil.med.pl'),
    ('https://firma.bielsko.pl', 'evil.bielsko.pl'),
    ('https://victim.trycloudflare.com', 'evil.trycloudflare.com'),
    ('https://victim.ngrok.app', 'evil.ngrok.app'),
    ('https://victim.s3.amazonaws.com', 'evil.s3.amazonaws.com'),
    ('https://victim.blob.core.windows.net', 'evil.blob.core.windows.net'),
    ('https://victim.azurestaticapps.net', 'evil.azurestaticapps.net'),
    ('https://victim.codeberg.page', 'evil.codeberg.page'),
    ('https://victim.up.railway.app', 'evil.up.railway.app'),
    ('https://victim.tokyo.jp', 'evil.tokyo.jp'),
    ('https://victim.github.io/login', 'evil.github.io'),
  ];
  for (final (String saved, String page) in pairs) {
    test('a login saved for $saved is not offered on $page', () {
      expect(_kinds(saved, page), isEmpty);
      // Its own host and its own subdomains still match.
      final String host = Uri.parse(saved).host;
      expect(_kinds(saved, host), <PasswordMatchKind>[PasswordMatchKind.exact]);
      expect(_kinds(saved, 'login.$host'), <PasswordMatchKind>[
        PasswordMatchKind.sameSite,
      ]);
    });
  }

  test('one registrable domain is still one site', () {
    expect(
      _kinds('https://example.com', 'login.example.com'),
      <PasswordMatchKind>[PasswordMatchKind.sameSite],
    );
    expect(
      _kinds('https://www.bank.com.pl', 'bank.com.pl'),
      <PasswordMatchKind>[PasswordMatchKind.sameSite],
    );
    expect(_kinds('https://example.co.uk', 'evil.co.uk'), isEmpty);
    expect(_kinds('https://example.com', 'example.com.evil.net'), isEmpty);
  });

  test('an address with letters of another alphabet matches the page as '
      'browsers report it (punycode), and the other way round', () {
    expect(_kinds('https://bücher.de', 'xn--bcher-kva.de'), <PasswordMatchKind>[
      PasswordMatchKind.exact,
    ]);
    expect(
      _kinds('https://BÜCHER.de/konto', 'XN--BCHER-KVA.DE'),
      <PasswordMatchKind>[PasswordMatchKind.exact],
    );
    expect(_kinds('https://xn--bcher-kva.de', 'bücher.de'), <PasswordMatchKind>[
      PasswordMatchKind.exact,
    ]);
    expect(
      _kinds('https://sklep.bücher.de', 'xn--bcher-kva.de'),
      <PasswordMatchKind>[PasswordMatchKind.sameSite],
    );
    expect(_kinds('https://żabka.pl', 'xn--abka-99a.pl'), <PasswordMatchKind>[
      PasswordMatchKind.exact,
    ]);
    expect(normalizePasswordHost('食狮.中国'), 'xn--85x722f.xn--fiqs8s');
    expect(normalizePasswordHost('ｅｘａｍｐｌｅ。com'), 'example.com');
  });

  test('a look-alike letter of another alphabet is never folded into the '
      'Latin one', () {
    // The `а` here is Cyrillic.
    const String cyrillic = 'exаmple.com';
    expect(normalizePasswordHost(cyrillic), isNot('example.com'));
    expect(normalizePasswordHost(cyrillic), startsWith('xn--'));
    expect(_kinds('https://example.com', cyrillic), isEmpty);
    expect(_kinds('https://$cyrillic', 'example.com'), isEmpty);
    expect(_kinds('https://login.example.com', 'login.$cyrillic'), isEmpty);
  });

  test('punycode as RFC 3492 gives it', () {
    expect(punycodeEncode('bücher'), 'bcher-kva');
    expect(punycodeEncode('食狮'), '85x722f');
    expect(punycodeEncode('公司'), '55qx5d');
    expect(punycodeEncode('中国'), 'fiqs8s');
    expect(punycodeEncode('münchen'), 'mnchen-3ya');
    // RFC 3492, 7.1 (L): Japanese.
    expect(punycodeEncode('3年B組金八先生'), '3B-ww4c5e180e575a65lsy2b');
  });
}
