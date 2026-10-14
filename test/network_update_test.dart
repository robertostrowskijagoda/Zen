import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/update/adb_installer.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/share_app_server.dart';
import 'package:zen/src/features/update/update_book.dart';
import 'package:zen/src/features/update/update_service.dart';

import '../tool/zen_release.dart' as tool;

const int _day = 24 * 3600 * 1000;

Uint8List _bytes(int n, [int seed = 7]) => Uint8List.fromList(
  List<int>.generate(n, (int i) => (i * 31 + seed) & 0xFF),
);

final class _Net {
  final Map<String, _Host> hosts = <String, _Host>{};
}

final class _Host implements UpdateHost {
  _Host(this.net, this.address, this.friendList) {
    net.hosts[address] = this;
  }

  final _Net net;
  final String address;
  final List<String> friendList;

  @override
  final LedgerDisk disk = MemoryLedgerDisk();

  @override
  final BlobStore blobs = BlobStore();

  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();
  final StreamController<String> _greeted =
      StreamController<String>.broadcast();
  final StreamController<String> _done = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Stream<String> get greeted => _greeted.stream;

  @override
  Stream<String> get blobCompleted => _done.stream;

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  Iterable<String> friends() => friendList;

  @override
  void fetchBlob(String id, List<String> sources) {
    // Like the replicator: keeps asking until a source has it.
    unawaited(() async {
      for (int round = 0; round < 40 && !blobs.isComplete(id); round++) {
        for (final String s in sources) {
          final _Host? other = net.hosts[s];
          final Uint8List? bytes = await other?.blobs.read(id);
          if (bytes != null) {
            await blobs.put(bytes, mime: other!.blobs.manifest(id)!.mime);
            _done.add(id);
            return;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }());
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    net.hosts[to]?._frames.add(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  void greet(String peer) => _greeted.add(peer);
}

Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late List<SimpleKeyPair> toolKeys;
  late List<LedgerKeyPair> keys;
  late List<String> maintainers;

  setUpAll(() async {
    keys = <LedgerKeyPair>[
      for (int i = 0; i < 3; i++)
        await LedgerKeyPair.fromSeed(
          Uint8List.fromList(List<int>.filled(32, i + 1)),
        ),
    ];
    toolKeys = <SimpleKeyPair>[
      for (int i = 0; i < 3; i++)
        await tool.keyFromSeed(List<int>.filled(32, i + 1)),
    ];
    maintainers = <String>[for (final LedgerKeyPair k in keys) k.id];
  });

  Future<Map<String, dynamic>> toolRelease(
    Uint8List apk, {
    int build = kAppBuild + 1,
    int signers = 2,
    int at = 1000,
  }) async {
    Map<String, dynamic> r = tool.createRelease(
      version: '9.9.$build',
      build: build,
      publishedAt: at,
      notes: 'Nowości',
      files: <Map<String, dynamic>>[
        tool.describeFile(apk, platform: 'android', name: 'zen-$build.apk'),
      ],
    );
    for (int i = 0; i < signers; i++) {
      r = await tool.signRelease(r, toolKeys[i]);
    }
    return r;
  }

  group('releases', () {
    test(
      'the tool and the app agree on keys, blob ids and signatures',
      () async {
        expect(await tool.publicKeyOf(toolKeys[0]), keys[0].id);
        final Uint8List apk = _bytes(600 * 1024);
        final ReleaseFile file = ReleaseFile.describe(
          apk,
          platform: 'android',
          name: 'zen.apk',
        );
        expect(file.blob, tool.blobId(apk, releaseMime('zen.apk')));
        expect(
          file.blob,
          BlobManifest.describe(apk, releaseMime('zen.apk')).id,
        );

        final SignedRelease two = SignedRelease.fromJson(
          await toolRelease(apk),
        )!;
        expect(await two.validSignatures(maintainers), 2);
        expect(await two.isTrusted(maintainers: maintainers), isTrue);

        final SignedRelease one = SignedRelease.fromJson(
          await toolRelease(apk, signers: 1),
        )!;
        expect(await one.isTrusted(maintainers: maintainers), isFalse);

        // Signed with the app too: three different maintainers.
        final SignedRelease three = await one
            .signedBy(keys[1])
            .then((SignedRelease r) => r.signedBy(keys[2]));
        expect(await three.validSignatures(maintainers), 3);

        // Changing anything breaks the signatures.
        final Map<String, dynamic> json = two.toJson();
        (json['m'] as Map<String, dynamic>)['build'] = kAppBuild + 50;
        expect(
          await SignedRelease.fromJson(
            json,
          )!.isTrusted(maintainers: maintainers),
          isFalse,
        );
        // Strangers' signatures do not count.
        final LedgerKeyPair eve = await LedgerKeyPair.generate();
        final SignedRelease eves = await (await one.signedBy(
          eve,
        )).signedBy(eve);
        expect(await eves.isTrusted(maintainers: maintainers), isFalse);
        // No maintainers: never trusted.
        expect(await three.isTrusted(maintainers: const <String>[]), isFalse);
      },
    );

    test('bundles keep only files that match the release', () async {
      final Uint8List apk = _bytes(300 * 1024);
      final Map<String, dynamic> release = await toolRelease(apk);
      final Uint8List bundle = tool.encodeBundle(release, <String, Uint8List>{
        'zen-${kAppBuild + 1}.apk': apk,
      });
      final ReleaseBundle decoded = ReleaseBundle.decode(bundle)!;
      expect(decoded.files.values.single, apk);
      expect(decoded.release.manifest.version, '9.9.${kAppBuild + 1}');

      final Uint8List bad = Uint8List.fromList(apk)..[5] ^= 1;
      final ReleaseBundle tampered = ReleaseBundle.decode(
        tool.encodeBundle(release, <String, Uint8List>{
          'zen-${kAppBuild + 1}.apk': bad,
        }),
      )!;
      expect(tampered.files, isEmpty);
      expect(ReleaseBundle.decode(Uint8List.fromList(<int>[1, 2, 3])), isNull);
      expect(
        ReleaseBundle.decode(Uint8List.sublistView(bundle, 0, 40)),
        isNull,
      );
      // The app's own encoder reads back too.
      expect(
        ReleaseBundle.decode(decoded.encode())!.files.keys,
        decoded.files.keys,
      );
    });

    test('file names and sizes are checked', () {
      expect(
        ReleaseFile.fromJson(<String, dynamic>{
          'p': 'android',
          'name': '../zen.apk',
          'size': 1,
          'blob': 'a' * 64,
          'sha256': 'b' * 64,
        }),
        isNull,
      );
      expect(
        ReleaseFile.fromJson(<String, dynamic>{
          'p': 'android',
          'name': 'zen.apk',
          'size': 1,
          'blob': 'a' * 64,
          'sha256': 'b' * 64,
        }),
        isNotNull,
      );
    });
  });

  group('UpdateBook', () {
    test('waits seven days from first sight and honours vetoes', () async {
      final UpdateBook book = UpdateBook(
        currentBuild: 5,
        maintainers: maintainers,
      );
      final Uint8List apk = _bytes(1000);
      Future<SignedRelease> rel(int build, {int at = 0}) async =>
          SignedRelease.fromJson(await toolRelease(apk, build: build, at: at))!;

      expect(await book.offerRelease(await rel(5), now: 0), isFalse);
      expect(
        await book.offerRelease(await rel(6, at: 0), now: 10 * _day),
        isTrue,
      );
      expect(await book.offerRelease(await rel(6), now: 11 * _day), isFalse);
      expect(book.readyAt(6), 17 * _day, reason: 'from when it was first seen');
      // A future "published at" is not shortened either.
      expect(
        await book.offerRelease(await rel(7, at: 20 * _day), now: _day),
        isTrue,
      );
      expect(book.readyAt(7), 27 * _day);
      expect(book.candidate!.manifest.build, 7);

      final ReleaseRevocation veto = await ReleaseRevocation.create(
        build: 7,
        reason: 'Wymuszone wydanie',
        maintainer: keys[2],
      );
      expect(await book.offerRevocation(veto), isTrue);
      expect(await book.offerRevocation(veto), isFalse);
      expect(book.candidate!.manifest.build, 6);
      expect(book.newest!.manifest.build, 7);

      final LedgerKeyPair eve = await LedgerKeyPair.generate();
      final ReleaseRevocation fake = await ReleaseRevocation.create(
        build: 6,
        reason: 'x',
        maintainer: eve,
      );
      expect(await book.offerRevocation(fake), isFalse);

      final UpdateBook again = UpdateBook(
        currentBuild: 5,
        maintainers: maintainers,
      )..restore(jsonDecode(jsonEncode(book.toJson())));
      expect(again.candidate!.manifest.build, 6);
      expect(again.readyAt(6), 17 * _day);
      expect(again.isRevoked(7), isTrue);
    });

    test('without maintainer keys nothing is taken', () async {
      final UpdateBook book = UpdateBook(currentBuild: 1);
      expect(book.enabled, kReleaseMaintainers.length >= kReleaseThreshold);
      final UpdateBook none = UpdateBook(
        currentBuild: 1,
        maintainers: const <String>[],
      );
      expect(
        await none.offerRelease(
          SignedRelease.fromJson(await toolRelease(_bytes(10), build: 2))!,
          now: 0,
        ),
        isFalse,
      );
    });
  });

  group('UpdateService', () {
    test(
      'a release spreads from friend to friend and waits for the person',
      () async {
        int now = 0;
        final _Net net = _Net();
        final _Host a = _Host(net, 'a', <String>['b']);
        final _Host b = _Host(net, 'b', <String>['a', 'c']);
        final _Host c = _Host(net, 'c', <String>['b']);
        UpdateService service(_Host h) => UpdateService(
          host: h,
          book: UpdateBook(currentBuild: kAppBuild, maintainers: maintainers),
          platform: 'android',
          now: () => now,
        );
        final UpdateService sa = service(a);
        final UpdateService sb = service(b);
        final UpdateService sc = service(c);
        await sa.start();
        await sb.start();
        await sc.start();
        addTearDown(() async {
          await sa.stop();
          await sb.stop();
          await sc.stop();
        });

        final Uint8List apk = _bytes(700 * 1024, 3);
        final Map<String, dynamic> release = await toolRelease(apk);
        final String result = await sa.importBundle(
          tool.encodeBundle(release, <String, Uint8List>{
            'zen-${kAppBuild + 1}.apk': apk,
          }),
        );
        expect(result, contains('Wczytano'));
        await sa.idle;
        await _settle();
        await sb.idle;
        await _settle();
        await sc.idle;
        await _settle();

        expect(sa.status.phase, UpdatePhase.waiting);
        expect(sb.status.phase, UpdatePhase.waiting, reason: 'b got it from a');
        expect(sc.status.phase, UpdatePhase.waiting, reason: 'c got it from b');
        expect(await sc.fileBytes(), apk);
        expect(await sc.install(), contains('nie jest jeszcze gotowa'));

        now = 8 * _day;
        expect(sc.status.phase, UpdatePhase.ready);
        expect(sc.status.release!.manifest.notes, 'Nowości');

        // A maintainer vetoes it: it stops everywhere.
        final ReleaseRevocation veto = await ReleaseRevocation.create(
          build: kAppBuild + 1,
          reason: 'Błąd w wydaniu',
          maintainer: keys[0],
        );
        expect(
          await sa.importBundle(
            Uint8List.fromList(utf8.encode(jsonEncode(veto.toJson()))),
          ),
          contains('wstrzymanie'),
        );
        await sa.idle;
        await _settle();
        await sb.idle;
        await _settle();
        await sc.idle;
        await _settle();
        expect(sc.status.phase, UpdatePhase.upToDate);
        expect(sc.status.vetoed!.reason, 'Błąd w wydaniu');
      },
    );

    test(
      'strangers cannot push releases, and one signature is not enough',
      () async {
        final _Net net = _Net();
        final _Host me = _Host(net, 'me', <String>['friend']);
        final _Host stranger = _Host(net, 'eve', <String>['me']);
        final _Host friend = _Host(net, 'friend', <String>['me']);
        final UpdateService s = UpdateService(
          host: me,
          book: UpdateBook(currentBuild: kAppBuild, maintainers: maintainers),
          platform: 'android',
        );
        await s.start();
        addTearDown(s.stop);
        final Map<String, dynamic> good = await toolRelease(_bytes(100));
        await stranger.send('me', <String, dynamic>{
          'type': kReleaseOfferType,
          'rel': good,
        });
        await friend.send('me', <String, dynamic>{
          'type': kReleaseOfferType,
          'rel': await toolRelease(
            _bytes(100),
            build: kAppBuild + 2,
            signers: 1,
          ),
        });
        await _settle();
        await s.idle;
        expect(s.status.phase, UpdatePhase.upToDate);

        await friend.send('me', <String, dynamic>{
          'type': kReleaseOfferType,
          'rel': good,
        });
        await _settle();
        await s.idle;
        expect(s.status.phase, UpdatePhase.downloading);
      },
    );

    test(
      'meeting a friend who is behind tells them, once in a while',
      () async {
        int now = 0;
        final _Net net = _Net();
        final _Host me = _Host(net, 'me', <String>['old']);
        _Host(net, 'old', <String>['me']);
        final UpdateService s = UpdateService(
          host: me,
          book: UpdateBook(currentBuild: kAppBuild, maintainers: maintainers),
          platform: 'android',
          now: () => now,
        );
        await s.start();
        addTearDown(s.stop);
        await s.importBundle(
          Uint8List.fromList(
            utf8.encode(jsonEncode(await toolRelease(_bytes(50)))),
          ),
        );
        await s.idle;
        me.sent.clear();
        me.greet('old');
        await _settle();
        await s.idle;
        me.greet('old');
        await _settle();
        await s.idle;
        expect(me.sent, isEmpty, reason: 'already told when it was imported');
        now = 7 * 3600 * 1000;
        me.greet('old');
        await _settle();
        await s.idle;
        expect(me.sent.single['type'], kReleaseOfferType);
      },
    );
  });

  group('Podaj dalej', () {
    test('serves the one file under a random path', () async {
      final Directory dir = await Directory.systemTemp.createTemp('zen-share');
      addTearDown(() => dir.delete(recursive: true));
      final File apk = File('${dir.path}/zen.apk')
        ..writeAsBytesSync(_bytes(5000));
      final ShareAppServer server = ShareAppServer(
        file: apk,
        fileName: 'zen-1.apk',
      );
      await server.start();
      addTearDown(server.dispose);
      final InternetAddress local = InternetAddress.loopbackIPv4;
      final HttpClient client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<(int, List<int>)> get(Uri uri) async {
        final HttpClientResponse r = await (await client.getUrl(uri)).close();
        final List<int> body = await r.fold<List<int>>(
          <int>[],
          (List<int> a, List<int> b) => a..addAll(b),
        );
        return (r.statusCode, body);
      }

      final (int pageStatus, List<int> page) = await get(server.pageUri(local));
      expect(pageStatus, 200);
      expect(utf8.decode(page), contains('href="zen-1.apk"'));
      final (int fileStatus, List<int> file) = await get(server.fileUri(local));
      expect(fileStatus, 200);
      expect(file, apk.readAsBytesSync());
      for (int i = 0; i < 50 && server.downloads == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(server.downloads, 1);

      final (int guessed, _) = await get(
        Uri.parse('http://127.0.0.1:${server.port}/zen-1.apk'),
      );
      expect(guessed, 404);
      final (int other, _) = await get(
        server.pageUri(local).resolve('../../etc/passwd'),
      );
      expect(other, 404);
      await server.stop();
      expect(server.isRunning, isFalse);
    });

    test('wifi codes escape special characters', () {
      expect(
        wifiQrText(ssid: 'Zen;1', password: r'a:b\c'),
        r'WIFI:T:WPA;S:Zen\;1;P:a\:b\\c;;',
      );
      expect(isPrivateIPv4(InternetAddress('192.168.43.1')), isTrue);
      expect(isPrivateIPv4(InternetAddress('8.8.8.8')), isFalse);
    });

    test('adb devices are read', () {
      final List<AdbDevice> d = parseAdbDevices(
        'List of devices attached\n'
        'R58M123 device usb:1-1 product:x model:Galaxy_S10 device:beyond1\n'
        'emulator-5554 unauthorized\n'
        '* daemon started successfully\n',
      );
      expect(d, hasLength(2));
      expect(d.first.ready, isTrue);
      expect(d.first.label, 'Galaxy S10');
      expect(d.last.state, 'unauthorized');
    });

    test('adb is found in the Android SDK', () async {
      final Directory sdk = await Directory.systemTemp.createTemp('zen-sdk');
      addTearDown(() => sdk.delete(recursive: true));
      final String exe = Platform.isWindows ? 'adb.exe' : 'adb';
      File(
        '${sdk.path}${Platform.pathSeparator}platform-tools'
        '${Platform.pathSeparator}$exe',
      ).createSync(recursive: true);
      final AdbInstaller adb = await AdbInstaller.find(
        environment: <String, String>{'ANDROID_HOME': sdk.path, 'PATH': ''},
      );
      expect(adb.available, isTrue);
      final AdbInstaller none = await AdbInstaller.find(
        environment: const <String, String>{'PATH': ''},
      );
      expect(
        none.executable == null || !none.executable!.contains(sdk.path),
        isTrue,
      );
    });
  });

  test('the version constant matches pubspec.yaml', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch m = RegExp(
      r'^version:\s*([0-9.]+)\+([0-9]+)',
      multiLine: true,
    ).firstMatch(pubspec)!;
    expect(m.group(1), kAppVersion);
    expect(int.parse(m.group(2)!), kAppBuild);
  });
}
