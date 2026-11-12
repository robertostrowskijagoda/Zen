import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/passwords/password_csv_import.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_match.dart';

// What the autofill may offer: an entry matches a page by its exact host or
// its registrable domain, never by a part of a name, never an https entry
// on a plain-http page; an app only by its exact package.

int _n = 0;

PasswordEntry _entry(String address, {String name = ''}) => PasswordEntry(
  id: 'entry${(_n++).toString().padLeft(4, '0')}',
  versionKey: 'version${_n.toString().padLeft(4, '0')}',
  fields: PasswordFields(
    name: name.isEmpty ? address : name,
    password: 'p',
    address: address,
  ),
  createdAtMillis: 1,
  changedAtMillis: 1,
);

List<String> _offered(
  List<PasswordEntry> entries, {
  String? domain,
  String? scheme = 'https',
  String? package,
  List<String> certificates = const <String>[],
}) => <String>[
  for (final PasswordMatch m in matchPasswordEntries(
    entries,
    webDomain: domain,
    webScheme: scheme,
    packageName: package,
    appCertificates: certificates,
  ))
    m.entry.address,
];

/// A certificate's SHA-512 (64 bytes) and SHA-256 (32 bytes), in hex and
/// as Chrome names them in `android://<hash>@package/`.
final List<int> _bankSha512 = List<int>.generate(64, (int i) => 255 - i * 3);
final String _bankSha512Hex = _hex(_bankSha512);
final String _bankHash = base64Url.encode(_bankSha512);
final List<int> _bankSha256 = List<int>.generate(32, (int i) => 255 - i);
final String _bankSha256Hex = _hex(_bankSha256);
final String _otherHex = _hex(List<int>.filled(64, 7));

String _hex(List<int> bytes) => <String>[
  for (final int b in bytes) b.toRadixString(16).padLeft(2, '0'),
].join();

void main() {
  test('addresses are read as pages or apps', () {
    PasswordAddress? p(String a) => PasswordAddress.parse(a);
    expect(p('https://Example.COM./login')!.host, 'example.com');
    expect(p('example.com/login')!.scheme, 'https');
    expect(p('http://example.com:8080')!.port, 8080);
    expect(p('android-app://com.example.app')!.package, 'com.example.app');
    expect(p('androidapp://com.example.app')!.package, 'com.example.app');
    expect(
      p('android://$_bankHash@com.example.app/')!.package,
      'com.example.app',
    );
    expect(p('android-app://com.example.app')!.certificate, isNull);
    // `user@host` is the host after the @.
    expect(p('https://example.com@evil.com/')!.host, 'evil.com');
    for (final String bad in <String>[
      '',
      'ftp://example.com',
      'javascript:alert(1)',
      'android-app://not a package',
      'https://exa mple.com',
    ]) {
      expect(p(bad), isNull, reason: bad);
    }
  });

  test('registrable domains know public suffixes', () {
    expect(registrablePasswordDomain('login.example.com'), 'example.com');
    expect(registrablePasswordDomain('www.bank.com.pl'), 'bank.com.pl');
    expect(registrablePasswordDomain('a.b.example.co.uk'), 'example.co.uk');
    expect(registrablePasswordDomain('alice.github.io'), 'alice.github.io');
    expect(registrablePasswordDomain('x.alice.github.io'), 'alice.github.io');
    expect(registrablePasswordDomain('sklep.waw.pl'), 'sklep.waw.pl');
    expect(registrablePasswordDomain('co.uk'), isNull);
    expect(registrablePasswordDomain('github.io'), isNull);
    expect(registrablePasswordDomain('localhost'), isNull);
    expect(registrablePasswordDomain('192.168.1.10'), isNull);
  });

  test('look-alike pages get nothing', () {
    final List<PasswordEntry> entries = <PasswordEntry>[
      _entry('https://example.com'),
    ];
    for (final String page in <String>[
      'evil-example.com',
      'example.com.evil.net',
      'notexample.com',
      'example.co',
      'example.com-login.net',
      'exаmple.com', // a Cyrillic "а"
      'xn--exmple-cua.com',
      'example.org',
      'com',
      '',
    ]) {
      expect(_offered(entries, domain: page), isEmpty, reason: page);
    }
    expect(_offered(entries, domain: 'example.com'), hasLength(1));
    expect(_offered(entries, domain: 'EXAMPLE.com.'), hasLength(1));
    // A host in another alphabet matches itself only.
    final List<PasswordEntry> local = <PasswordEntry>[
      _entry('https://żabka.pl'),
    ];
    expect(_offered(local, domain: 'żabka.pl'), hasLength(1));
    expect(_offered(local, domain: 'zabka.pl'), isEmpty);
    expect(_offered(entries, domain: 'login.example.com'), hasLength(1));
  });

  test('pages under a public suffix match only their own name', () {
    final List<PasswordEntry> entries = <PasswordEntry>[
      _entry('https://alice.github.io'),
      _entry('https://shop.co.uk'),
      _entry('https://bank.com.pl'),
    ];
    expect(_offered(entries, domain: 'mallory.github.io'), isEmpty);
    expect(_offered(entries, domain: 'evil.co.uk'), isEmpty);
    expect(_offered(entries, domain: 'evil.com.pl'), isEmpty);
    expect(_offered(entries, domain: 'github.io'), isEmpty);
    expect(_offered(entries, domain: 'www.alice.github.io'), hasLength(1));
    expect(_offered(entries, domain: 'www.bank.com.pl'), hasLength(1));
  });

  test('a plain-http page never gets an https entry; one that says http '
      'it does', () {
    final List<PasswordEntry> entries = <PasswordEntry>[
      _entry('https://example.com'),
      _entry('example.com/bare'),
      _entry('http://router.example.net'),
    ];
    expect(_offered(entries, domain: 'example.com', scheme: 'http'), isEmpty);
    expect(_offered(entries, domain: 'example.com', scheme: null), isEmpty);
    expect(
      _offered(entries, domain: 'router.example.net', scheme: 'http'),
      <String>['http://router.example.net'],
    );
    // An https page may use an http entry (the site moved to https).
    expect(
      _offered(entries, domain: 'router.example.net', scheme: 'https'),
      <String>['http://router.example.net'],
    );
    expect(
      _offered(entries, domain: 'example.com', scheme: 'https'),
      hasLength(2),
    );
    expect(_offered(entries, domain: 'example.com', scheme: 'ftp'), isEmpty);
  });

  test('ports must agree when one is named', () {
    final List<PasswordEntry> entries = <PasswordEntry>[
      _entry('https://example.com:8443'),
      _entry('https://example.com'),
    ];
    expect(_offered(entries, domain: 'example.com:8443'), <String>[
      'https://example.com:8443',
    ]);
    expect(_offered(entries, domain: 'example.com'), <String>[
      'https://example.com',
    ]);
    expect(_offered(entries, domain: 'example.com:443'), <String>[
      'https://example.com',
    ]);
  });

  test('exact hosts first, then the rest of the site', () {
    final List<PasswordEntry> entries = <PasswordEntry>[
      _entry('https://example.com', name: 'A'),
      _entry('https://login.example.com', name: 'B'),
    ];
    final List<PasswordMatch> got = matchPasswordEntries(
      entries,
      webDomain: 'login.example.com',
      webScheme: 'https',
    );
    expect(got.map((PasswordMatch m) => m.entry.name), <String>['B', 'A']);
    expect(got.first.kind, PasswordMatchKind.exact);
    expect(got.last.kind, PasswordMatchKind.sameSite);
    expect(got.first.toString(), isNot(contains('example')));
  });

  test('apps match only their exact package; pages and apps never mix', () {
    final List<PasswordEntry> entries = <PasswordEntry>[
      _entry('android-app://com.bank.app'),
      _entry('android://@com.bank.app.evil/'),
      _entry('https://bank.app'),
      _entry('https://com.bank.app'),
    ];
    expect(_offered(entries, package: 'com.bank.app'), <String>[
      'android-app://com.bank.app',
    ]);
    expect(_offered(entries, package: 'com.bank'), isEmpty);
    expect(_offered(entries, package: 'com.bank.app.evil'), <String>[
      'android://@com.bank.app.evil/',
    ]);
    expect(_offered(entries, package: 'not a package'), isEmpty);
    // A page (a browser's form) is matched by the page, not the browser.
    final List<String> page = _offered(
      entries,
      domain: 'bank.app',
      package: 'com.bank.app',
    );
    expect(page.first, 'https://bank.app');
    expect(page.where((String a) => a.startsWith('android')), isEmpty);
  });

  group('an app entry that names its certificate', () {
    test('the hash is kept: Chrome\'s base64url with padding, the standard '
        'alphabet, without padding, a SHA-256', () {
      PasswordAddress? p(String a) => PasswordAddress.parse(a);
      expect(
        p('android://$_bankHash@com.bank.app/')!.certificate,
        _bankSha512Hex,
      );
      final String standard = base64.encode(_bankSha512);
      expect(standard, isNot(_bankHash), reason: 'the two alphabets differ');
      expect(
        p('android://$standard@com.bank.app/')!.certificate,
        _bankSha512Hex,
      );
      expect(
        p(
          'android://${_bankHash.replaceAll('=', '')}@com.bank.app',
        )!.certificate,
        _bankSha512Hex,
      );
      expect(
        p(
          'android://${base64Url.encode(_bankSha256)}@com.bank.app/',
        )!.certificate,
        _bankSha256Hex,
      );
      expect(passwordCertificateDigest(_bankHash), _bankSha512Hex);
      // A hash that is no digest: no app, so it never matches one.
      for (final String bad in <String>[
        'android://h@com.bank.app/',
        'android://AbC_hash==@com.bank.app/',
        'android://${base64Url.encode(List<int>.filled(20, 1))}@com.bank.app/',
        'android://a b@com.bank.app/',
      ]) {
        expect(p(bad), isNull, reason: bad);
      }
    });

    test('imported from Chrome, it matches only the app signed with that '
        'certificate', () {
      final List<PasswordEntry> entries = <PasswordEntry>[
        _entry('android://$_bankHash@com.bank.app/'),
      ];
      expect(
        _offered(
          entries,
          package: 'com.bank.app',
          certificates: <String>[_otherHex, _bankSha512Hex.toUpperCase()],
        ),
        hasLength(1),
      );
      // The same name, another key: a look-alike installed from elsewhere.
      expect(
        _offered(
          entries,
          package: 'com.bank.app',
          certificates: <String>[_otherHex],
        ),
        isEmpty,
      );
      // Android told nothing about the app: not offered either.
      expect(_offered(entries, package: 'com.bank.app'), isEmpty);
      // The right key under another name still is another app.
      expect(
        _offered(
          entries,
          package: 'com.bank.app2',
          certificates: <String>[_bankSha512Hex],
        ),
        isEmpty,
      );
      // An entry with a SHA-256 matches the app's SHA-256.
      expect(
        _offered(
          <PasswordEntry>[
            _entry('android://${base64.encode(_bankSha256)}@com.bank.app/'),
          ],
          package: 'com.bank.app',
          certificates: <String>[_bankSha256Hex],
        ),
        hasLength(1),
      );
    });

    test('a Chrome export keeps the hash through the import, and the entry '
        'it makes matches the signed app only', () {
      final PasswordCsvParse csv = parsePasswordCsvText(
        'name,url,username,password,note\r\n'
        'Bank,android://$_bankHash@com.bank.app/,ania,haslo,\r\n',
      );
      final PasswordFields fields = csv.rows.single.fields;
      expect(fields.address, 'android://$_bankHash@com.bank.app/');
      final PasswordEntry entry = PasswordEntry(
        id: 'imported1',
        versionKey: 'version01',
        fields: fields,
        createdAtMillis: 1,
        changedAtMillis: 1,
      );
      expect(
        _offered(
          <PasswordEntry>[entry],
          package: 'com.bank.app',
          certificates: <String>[_bankSha512Hex],
        ),
        hasLength(1),
      );
      expect(
        _offered(
          <PasswordEntry>[entry],
          package: 'com.bank.app',
          certificates: <String>[_otherHex],
        ),
        isEmpty,
      );
    });

    test('an entry without a hash matches by package, as before', () {
      expect(
        _offered(
          <PasswordEntry>[_entry('android-app://com.bank.app')],
          package: 'com.bank.app',
          certificates: <String>[_otherHex],
        ),
        hasLength(1),
      );
    });

    test('a new entry for an app names its current certificate as Chrome '
        'does, and finds it again', () {
      final String address = passwordAppAddress(
        'com.bank.app',
        sha512: _bankSha512Hex,
      );
      expect(address, 'android://$_bankHash@com.bank.app/');
      expect(
        _offered(
          <PasswordEntry>[_entry(address)],
          package: 'com.bank.app',
          certificates: <String>[_bankSha512Hex],
        ),
        <String>[address],
      );
      expect(passwordAppAddress('com.bank.app'), 'android-app://com.bank.app');
      expect(
        passwordAppAddress('com.bank.app', sha512: 'abc'),
        'android-app://com.bank.app',
      );
    });
  });
}
