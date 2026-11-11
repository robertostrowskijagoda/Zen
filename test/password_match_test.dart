import 'package:flutter_test/flutter_test.dart';
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
}) => <String>[
  for (final PasswordMatch m in matchPasswordEntries(
    entries,
    webDomain: domain,
    webScheme: scheme,
    packageName: package,
  ))
    m.entry.address,
];

void main() {
  test('addresses are read as pages or apps', () {
    PasswordAddress? p(String a) => PasswordAddress.parse(a);
    expect(p('https://Example.COM./login')!.host, 'example.com');
    expect(p('example.com/login')!.scheme, 'https');
    expect(p('http://example.com:8080')!.port, 8080);
    expect(p('android-app://com.example.app')!.package, 'com.example.app');
    expect(p('androidapp://com.example.app')!.package, 'com.example.app');
    expect(
      p('android://AbC_hash==@com.example.app/')!.package,
      'com.example.app',
    );
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
      _entry('android://h@com.bank.app.evil/'),
      _entry('https://bank.app'),
      _entry('https://com.bank.app'),
    ];
    expect(_offered(entries, package: 'com.bank.app'), <String>[
      'android-app://com.bank.app',
    ]);
    expect(_offered(entries, package: 'com.bank'), isEmpty);
    expect(_offered(entries, package: 'com.bank.app.evil'), <String>[
      'android://h@com.bank.app.evil/',
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
}
