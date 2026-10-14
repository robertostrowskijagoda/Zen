// Steruje kilkoma uruchomionymi aplikacjami Zen naraz (testy na wielu
// klientach): instancjami na tym komputerze (--zen-profile) i telefonem
// przez `adb forward`. Każda aplikacja w wersji debug ma pilota na
// 127.0.0.1:48888…48895 (TestHarnessServer).
//
//   dart run tool/zen_drive.dart find
//   dart run tool/zen_drive.dart status 48888 48889
//   dart run tool/zen_drive.dart friends 48888 48889 48890
//   dart run tool/zen_drive.dart pyramid 48888 48889 48890 48891
//   dart run tool/zen_drive.dart flats 48888 48889
//   dart run tool/zen_drive.dart call 48888 /x/state
//
// Telefon: `adb forward tcp:48900 tcp:48888`, potem port 48900.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String _header = 'x-zen-harness';

Future<Map<String, dynamic>> call(
  int port,
  String path, [
  Map<String, dynamic>? body,
]) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  try {
    final HttpClientRequest req =
        body == null && (path == '/status' || path == '/health')
        ? await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'))
        : await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set(_header, '1');
    if (body != null || req.method == 'POST') {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body ?? <String, dynamic>{}));
    }
    final HttpClientResponse res = await req.close().timeout(
      const Duration(seconds: 30),
    );
    final String text = await utf8.decodeStream(res);
    final Object? json = jsonDecode(text);
    return json is Map<String, dynamic>
        ? json
        : <String, dynamic>{'ok': false, 'raw': text};
  } finally {
    client.close(force: true);
  }
}

/// GET with a query (the message list).
Future<Map<String, dynamic>> getJson(int port, String pathAndQuery) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  try {
    final HttpClientRequest req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$pathAndQuery'),
    );
    req.headers.set(_header, '1');
    final HttpClientResponse res = await req.close().timeout(
      const Duration(seconds: 30),
    );
    final Object? json = jsonDecode(await utf8.decodeStream(res));
    return json is Map<String, dynamic> ? json : <String, dynamic>{'ok': false};
  } finally {
    client.close(force: true);
  }
}

/// Two friends write to each other; each message must arrive.
Future<void> chatScenario(List<int> ports) async {
  final Map<int, Map<String, dynamic>> st = await statuses(ports);
  final int a = ports[0];
  final int b = ports[1];
  final String addrA = st[a]!['localAddress'] as String;
  final String addrB = st[b]!['localAddress'] as String;
  print('Wiadomości ${nameOf(st[a]!, a)} ↔ ${nameOf(st[b]!, b)}');
  for (final (int from, String to, int at, String fromAddr)
      in <(int, String, int, String)>[
        (a, addrB, b, addrA),
        (b, addrA, a, addrB),
      ]) {
    final String text = 'test ${DateTime.now().millisecondsSinceEpoch}';
    await call(from, '/chat/send', <String, dynamic>{
      'peerAddress': to,
      'text': text,
    });
    await until('$at dostał(a) „$text”', <int>[at], (int p) async {
      final Map<String, dynamic> m = await getJson(
        p,
        '/chat/messages?peerAddress=${Uri.encodeQueryComponent(fromAddr)}',
      );
      return '${m['messages']}'.contains(text);
    }, seconds: 60);
  }
}

Future<void> pause([int seconds = 3]) =>
    Future<void>.delayed(Duration(seconds: seconds));

/// Waits until [check] is true for every port (or gives up).
Future<bool> until(
  String what,
  List<int> ports,
  Future<bool> Function(int port) check, {
  int seconds = 90,
}) async {
  final DateTime end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    bool all = true;
    for (final int p in ports) {
      if (!await check(p)) {
        all = false;
        break;
      }
    }
    if (all) {
      print('  ✓ $what');
      return true;
    }
    await pause(2);
  }
  print('  ✗ $what — nie doczekałem się');
  return false;
}

Future<Map<int, Map<String, dynamic>>> statuses(List<int> ports) async =>
    <int, Map<String, dynamic>>{
      for (final int p in ports) p: await call(p, '/status'),
    };

String nameOf(Map<String, dynamic> st, int port) {
  final Object? n = st['profile'] ?? st['displayName'];
  return n is String && n.isNotEmpty ? n : 'p$port';
}

/// Makes every pair in [pairs] friends (request + accept).
Future<void> befriend(List<int> ports, List<List<int>> pairs) async {
  final Map<int, Map<String, dynamic>> st = await statuses(ports);
  for (final List<int> pair in pairs) {
    final int a = pair[0];
    final int b = pair[1];
    final String target =
        (st[b]!['shareUri'] ?? st[b]!['localAddress']) as String;
    await call(a, '/friend/request', <String, dynamic>{
      'target': target,
      'displayName': nameOf(st[b]!, b),
    });
    await pause(4);
    await call(b, '/friend/accept', <String, dynamic>{
      'peerAddress': st[a]!['localAddress'],
      'displayName': nameOf(st[a]!, a),
    });
    print('  ${nameOf(st[a]!, a)} ↔ ${nameOf(st[b]!, b)}');
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print(
      'Użycie: find | status P… | friends P… | pyramid P… | flats P… | call P ŚCIEŻKA [JSON]',
    );
    exit(64);
  }
  final List<int> ports = args
      .skip(1)
      .map(int.tryParse)
      .whereType<int>()
      .toList();
  switch (args.first) {
    case 'find':
      for (int p = 48888; p <= 48910; p++) {
        try {
          final Map<String, dynamic> st = await call(p, '/status');
          print(
            '$p: ${nameOf(st, p)} · ${st['platform']} · ${st['localAddress']} · online=${st['isOnline']} peers=${st['peers']}',
          );
        } on Object {
          // nobody there
        }
      }
    case 'status':
      for (final int p in ports) {
        print('$p: ${jsonEncode(await call(p, '/x/state'))}');
      }
    case 'call':
      final Map<String, dynamic>? body = args.length > 3
          ? jsonDecode(args[3]) as Map<String, dynamic>
          : null;
      print(jsonEncode(await call(int.parse(args[1]), args[2], body)));
    case 'friends':
      print('Znajomości po kolei:');
      await befriend(ports, <List<int>>[
        for (int i = 0; i + 1 < ports.length; i++)
          <int>[ports[i], ports[i + 1]],
      ]);
    case 'pyramid':
      await pyramidScenario(ports);
    case 'flats':
      await flatsScenario(ports);
    case 'chat':
      await chatScenario(ports);
    default:
      print('Nieznane polecenie ${args.first}');
      exit(64);
  }
}

/// A pyramid over real apps: the first is the top, the rest join one by
/// one under the first free head (in person: QR replaced by the code),
/// then a post, a referendum and the count up the tree.
Future<void> pyramidScenario(List<int> ports) async {
  if (ports.length < 3) {
    print('Potrzeba co najmniej 3 aplikacji.');
    exit(64);
  }
  final Map<int, Map<String, dynamic>> st = await statuses(ports);
  print('1. Znajomości (rodzic ↔ dziecko w drzewie)');
  final List<List<int>> pairs = <List<int>>[
    for (int i = 1; i < ports.length; i++) <int>[ports[(i - 1) ~/ 2], ports[i]],
  ];
  await befriend(ports, pairs);
  await pause(5);
  print('2. Piramida');
  await call(ports.first, '/x/pyramid/create', <String, dynamic>{
    'name': 'Test',
    'me': nameOf(st[ports.first]!, ports.first),
  });
  for (int i = 1; i < ports.length; i++) {
    final int head = ports[(i - 1) ~/ 2];
    final Map<String, dynamic> inv = await call(head, '/x/pyramid/invite');
    await call(ports[i], '/x/pyramid/join', <String, dynamic>{
      'code': inv['code'],
      'me': nameOf(st[ports[i]]!, ports[i]),
    });
    await until('${nameOf(st[head]!, head)} dostał(a) prośbę', <int>[head], (
      int p,
    ) async {
      final List<dynamic> props =
          (await call(p, '/x/state'))['proposals'] as List<dynamic>;
      return props.contains('admit');
    });
    await call(head, '/x/pyramid/approve', <String, dynamic>{'type': 'admit'});
    await until(
      '${nameOf(st[ports[i]]!, ports[i])} jest w piramidzie',
      <int>[ports[i]],
      (int p) async {
        final Map<String, dynamic>? pyr =
            (await call(p, '/x/state'))['pyramid'] as Map<String, dynamic>?;
        return pyr != null && pyr['member'] == true;
      },
    );
  }
  for (final int p in ports) {
    await call(p, '/x/pyramid/greet');
  }
  await until('wszyscy widzą tę samą piramidę', ports, (int p) async {
    final Set<String> views = <String>{};
    for (final int q in ports) {
      final Map<String, dynamic>? pyr =
          (await call(q, '/x/state'))['pyramid'] as Map<String, dynamic>?;
      views.add('${pyr?['structure']}');
    }
    return views.length == 1;
  });
  print('3. Post szczytu dociera do wszystkich');
  await call(ports.first, '/x/pyramid/post', <String, dynamic>{
    'text': 'Witajcie z testu',
  });
  await until(
    'post jest u wszystkich',
    ports,
    (int p) async =>
        ((await call(p, '/x/state'))['pyramid']
            as Map<String, dynamic>)['posts'] ==
        1,
  );
  print('4. Referendum (2 z 3 szczytu), głosy, liczenie drzewem');
  await call(ports.first, '/x/pyramid/referendum', <String, dynamic>{
    'q': 'Test?',
    'minutes': 2,
  });
  await until(
    'druga osoba ze szczytu dostała propozycję',
    <int>[ports[1]],
    (int p) async => ((await call(p, '/x/state'))['proposals'] as List<dynamic>)
        .contains('ref'),
  );
  await call(ports[1], '/x/pyramid/approve', <String, dynamic>{'type': 'ref'});
  await pause(5);
  for (int i = 0; i < ports.length; i++) {
    await call(ports[i], '/x/pyramid/vote', <String, dynamic>{
      'opt': i.isEven ? 0 : 1,
    });
  }
  print('  czekam na koniec głosowania (2 min)…');
  await pause(125);
  // Sums go up the tree as each head does its duties: a few rounds.
  Map<String, dynamic> top = const <String, dynamic>{};
  for (int round = 0; round < 12; round++) {
    for (final int p in ports) {
      await call(p, '/x/pyramid/duties');
    }
    await pause(5);
    top =
        (await call(ports.first, '/x/state'))['pyramid']
            as Map<String, dynamic>;
    final Object? refs = top['referenda'];
    if (refs is Map &&
        refs.values.any((Object? r) => r is Map && r['result'] != null)) {
      break;
    }
  }
  final Object? refs = top['referenda'];
  final bool counted =
      refs is Map &&
      refs.values.any((Object? r) => r is Map && r['result'] != null);
  print(
    counted
        ? '  ✓ wynik: ${jsonEncode(refs)}'
        : '  ✗ brak wyniku referendum: ${jsonEncode(refs)}',
  );
  if (!counted) {
    for (final int p in ports) {
      final Map<String, dynamic>? py =
          (await call(p, '/x/state'))['pyramid'] as Map<String, dynamic>?;
      print(
        '    $p: ${jsonEncode(py?['referenda'])} odrzucone: ${jsonEncode(py?['whyRejected'])}',
      );
    }
  }
  print('Gotowe.');
}

/// Two flats become neighbours by scanning the door code.
Future<void> flatsScenario(List<int> ports) async {
  final Map<int, Map<String, dynamic>> st = await statuses(ports);
  for (final int p in ports) {
    await call(p, '/x/flat/create', <String, dynamic>{
      'name': nameOf(st[p]!, p),
      'place': 'm. $p',
    });
  }
  final Map<String, dynamic> door = await call(ports.first, '/x/flat/door');
  for (final int p in ports.skip(1)) {
    await call(p, '/x/flat/scan', <String, dynamic>{'code': door['code']});
  }
  await until(
    'wszyscy są sąsiadami pierwszego',
    ports.skip(1).toList(),
    (int p) async =>
        (((await call(p, '/x/state'))['flat']
                    as Map<String, dynamic>)['neighbors']
                as List<dynamic>)
            .isNotEmpty,
  );
}
