import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/qr_sticker/qr_digits.dart';
import 'package:zen/src/features/qr_sticker/zen_qr_code.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// The door sticker's link: link format 2 (the code's bytes as decimal
// digits, which a QR code holds in numeric mode) keeps the printed code
// small; the JSON of format 1, which older stickers carry, is still read,
// in the app and on the door page (tool/pages/m/door.js, run with node).

const String _base = 'https://robertostrowskijagoda.github.io/Zen/';

/// A door code as the app makes it, with [doors] mailbox doors.
FlatDoorCode _code(
  int doors, {
  String name = 'Kowalscy, m. 12',
  int? until,
  int seed = 1,
}) => FlatDoorCode(
  key: base64Url.encode(List<int>.generate(32, (int i) => i * 7 + seed)),
  door: base64Url
      .encode(List<int>.generate(12, (int i) => i * 3 + seed))
      .replaceAll('=', ''),
  inbox: addressFromBytes(<int>[
    0x02,
    for (int i = 1; i < 16; i++) (i * 17 + seed) & 0xff,
  ]),
  name: name,
  mail: doors == 0
      ? null
      : FlatMailDoor(
          slots: <String>[
            for (int d = 0; d < doors; d++)
              addressFromBytes(<int>[
                0x02,
                for (int i = 1; i < 16; i++) (i * 31 + d * 7 + seed) & 0xff,
              ]),
          ],
          seal: base64Url.encode(List<int>.generate(32, (int i) => 255 - i)),
        ),
  until: until,
);

/// The bytes of [code]'s link code.
Uint8List _bytes(FlatDoorCode code) =>
    qrBytesFromDigits(code.linkCode!, maxBytes: FlatDoorCode.maxLinkBytes)!;

/// [bytes] as a sticker link.
String _link(List<int> bytes) => '${_base}m#${qrDigits(bytes)}';

void main() {
  group('link format 2', () {
    test('the sticker link carries digits and reads back the same code', () {
      for (final FlatDoorCode code in <FlatDoorCode>[
        _code(0),
        _code(6),
        _code(kStickerSealDoors),
        _code(3, name: 'Żółć · ul. Długa 5/12 🏠', seed: 9),
        _code(1, name: ''),
        _code(2, name: 'x' * 300),
        _code(6, until: 1790000000123),
      ]) {
        final String link = code.toLink();
        expect(link, startsWith('${_base}m#'));
        final String digits = link.substring('${_base}m#'.length);
        expect(RegExp(r'^[0-9]+$').hasMatch(digits), isTrue, reason: link);
        expect(digits, code.linkCode);
        final FlatDoorCode? back = FlatDoorCode.parse(link);
        expect(back, isNotNull, reason: link);
        // The JSON holds every field: the same JSON is the same code.
        final FlatDoorCode want = code.name.length > 150
            ? FlatDoorCode(
                key: code.key,
                door: code.door,
                inbox: code.inbox,
                name: code.name.substring(0, 150),
                mail: code.mail,
                until: code.until,
              )
            : code;
        expect(back!.encode(), want.encode(), reason: link);
        expect(back.mail?.slots, code.mail?.slots);
        // The in-app form, the page's "Copy code", reads the same.
        expect(FlatDoorCode.parse('zen-flat:$digits')!.encode(), want.encode());
        expect(FlatDoorCode.isNewer(link), isFalse);
      }
    });

    test('its first byte holds the format and the number of mailbox doors; '
        'the layout adds up', () {
      for (final int doors in <int>[0, 1, 6, kStickerSealDoors]) {
        final Uint8List b = _bytes(_code(doors));
        expect(b.first, 0x20 | doors);
        expect(
          b.length,
          1 + 32 + 12 + 15 + 15 * doors + (doors == 0 ? 0 : 32) + 1 + 15,
        );
      }
      final Uint8List b = _bytes(_code(0));
      expect(b.sublist(1, 33), base64Url.decode(_code(0).key));
      // The name's length, then the name.
      expect(b[60], 15);
      expect(utf8.decode(b.sublist(61)), 'Kowalscy, m. 12');
      // A name of 200 bytes takes two bytes of length, the lowest first.
      final Uint8List long = _bytes(_code(0, name: 'y' * 200));
      expect(long.sublist(60, 62), <int>[200 & 0x7f | 0x80, 200 >> 7]);
    });

    test('a code not in the form the app makes stays in the JSON link', () {
      final FlatDoorCode base = _code(2);
      for (final FlatDoorCode code in <FlatDoorCode>[
        // A token of another length, or with padding.
        FlatDoorCode(
          key: base.key,
          door: base64Url.encode(List<int>.filled(16, 3)),
          inbox: base.inbox,
          name: base.name,
          mail: base.mail,
        ),
        FlatDoorCode(
          key: base.key,
          door: 'abc',
          inbox: base.inbox,
          name: base.name,
        ),
        // The household key without its padding.
        FlatDoorCode(
          key: base.key.replaceAll('=', ''),
          door: base.door,
          inbox: base.inbox,
          name: base.name,
        ),
        // A door outside 200::/8.
        FlatDoorCode(
          key: base.key,
          door: base.door,
          inbox: PeerShareCodec.normalizeAddress('300::1'),
          name: base.name,
        ),
      ]) {
        expect(code.linkCode, isNull);
        expect(code.toLink(), '${_base}m#${code.encode()}');
        expect(FlatDoorCode.parse(code.toLink())!.encode(), code.encode());
      }
    });

    test('broken or foreign digits are no door code; a newer format asks '
        'to update', () {
      final Uint8List good = _bytes(_code(2));
      final String digits = qrDigits(good);
      expect(FlatDoorCode.parse(_link(good)), isNotNull);
      for (final String bad in <String>[
        // One digit less, or a number too large for its bytes.
        '${_base}m#${digits.substring(1)}',
        '${_base}m#${'9' * digits.length}',
        // Cut short, or a byte too many that is no record.
        _link(good.sublist(0, good.length - 1)),
        _link(<int>[...good, 1]),
        _link(<int>[...good, 1, 7, 0]),
        // Format 1 is the JSON; 15 mailbox doors are more than a sticker
        // lists.
        _link(<int>[0x12, ...good.sublist(1)]),
        _link(<int>[0x2F, ...good.sublist(1)]),
        // A name that is not UTF-8.
        _link(<int>[...good.sublist(0, good.length - 16), 2, 0xC3, 0x28]),
        '${_base}m#0',
        '${_base}m#',
      ]) {
        expect(FlatDoorCode.parse(bad), isNull, reason: bad);
        expect(FlatDoorCode.isNewer(bad), isFalse, reason: bad);
      }
      // A record this build does not know is skipped.
      final FlatDoorCode? skipped = FlatDoorCode.parse(
        _link(<int>[...good, 9, 2, 0xAB, 0xCD]),
      );
      expect(skipped?.encode(), _code(2).encode());
      // Format 3 is a newer Zen's.
      final String newer = _link(<int>[0x32, ...good.sublist(1)]);
      expect(FlatDoorCode.parse(newer), isNull);
      expect(FlatDoorCode.isNewer(newer), isTrue);
    });

    test('the code is small enough for large printed modules', () {
      // Error correction M, as stickers are printed; the plain code 5 cm
      // across with its quiet zone.
      double module(int version) => 50 / (version * 4 + 17 + 8);
      final Map<int, int> versions = <int, int>{0: 8, 6: 11, 14: 15};
      for (final MapEntry<int, int> e in versions.entries) {
        final FlatDoorCode code = _code(e.key);
        final int now = zenQrVersion(code.toLink(), QrErrorCorrectLevel.M);
        final String old = '${_base}m#${code.encode()}';
        final int before = zenQrVersion(old, QrErrorCorrectLevel.M);
        expect(now, lessThanOrEqualTo(e.value), reason: '${e.key} doors');
        expect(before - now, greaterThanOrEqualTo(3), reason: '${e.key} doors');
      }
      expect(module(11), greaterThan(0.6));
    });
  });

  group('format 1 (older stickers)', () {
    test('the JSON link and code are still read', () {
      final Map<String, dynamic> sample =
          jsonDecode(
                File(
                  'test/fixtures/formats/1.12.0/sticker.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final String text in <String>[
        sample['link'] as String,
        sample['qr'] as String,
      ]) {
        final FlatDoorCode? code = FlatDoorCode.parse(text);
        expect(code?.name, 'Nowakowie, m. 12', reason: text);
        expect(code?.door, 'abc');
      }
      // A 1.14 sticker with mailbox doors.
      final FlatDoorCode six = _code(6);
      final FlatDoorCode? back = FlatDoorCode.parse(
        '${_base}m#${six.encode()}',
      );
      expect(back?.encode(), six.encode());
      // Phones pass codes to each other in the JSON, which every Zen reads.
      expect(six.toQr(), 'zen-flat:${six.encode()}');
    });
  });

  test('the door page reads the code with door.js and sends it nowhere', () {
    final String html = File('tool/pages/m/index.html').readAsStringSync();
    expect(html, contains('<script src="door.js"></script>'));
    expect(html, contains('ZenDoor.decode(code)'));
    final String reader = File('tool/pages/m/door.js').readAsStringSync();
    for (final String call in <String>[
      'fetch(',
      'XMLHttpRequest',
      'sendBeacon',
      'WebSocket',
    ]) {
      expect(reader, isNot(contains(call)));
    }
  });

  test("node reads the app's codes with the door page's reader", () async {
    // Every CI runner has node; so must a machine that runs this test.
    final String? node = _tool('node');
    if (node == null) {
      fail("node runs the door page's reader here: install Node.js");
    }
    final List<FlatDoorCode> codes = <FlatDoorCode>[
      _code(0),
      _code(6),
      _code(kStickerSealDoors, seed: 5),
      _code(3, name: 'Żółć · ul. Długa 5/12 🏠', until: 1790000000123),
      _code(2, name: 'z' * 200),
    ];
    String cut(String name) =>
        name.length > 150 ? name.substring(0, 150) : name;
    String hexOf(String address) => addressBytes(
      address,
    )!.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    final Uint8List good = _bytes(_code(2));
    final List<Map<String, dynamic>> vectors = <Map<String, dynamic>>[
      for (final FlatDoorCode c in codes) ...<Map<String, dynamic>>[
        <String, dynamic>{
          'link': c.linkCode,
          'expect': <String, dynamic>{
            'format': 2,
            'key': c.key,
            'door': c.door,
            'inbox': hexOf(c.inbox),
            'slots': <String>[
              for (final String s in c.mail?.slots ?? const <String>[])
                hexOf(s),
            ],
            'seal': c.mail?.seal,
            'name': cut(c.name),
            'until': c.until,
          },
        },
        <String, dynamic>{
          'link': c.encode(),
          'expect': <String, dynamic>{
            'format': 1,
            'key': c.key,
            'door': c.door,
            'inbox': c.inbox,
            'name': cut(c.name),
          },
        },
        <String, dynamic>{
          'link': c.toQr(),
          'expect': <String, dynamic>{
            'format': 1,
            'key': c.key,
            'door': c.door,
            'inbox': c.inbox,
            'name': cut(c.name),
          },
        },
      ],
      for (final String bad in <String>[
        qrDigits(good).substring(1),
        qrDigits(good.sublist(0, good.length - 1)),
        qrDigits(<int>[...good, 1]),
        qrDigits(<int>[0x32, ...good.sublist(1)]),
        qrDigits(<int>[0x2F, ...good.sublist(1)]),
        qrDigits(<int>[...good.sublist(0, good.length - 16), 2, 0xC3, 0x28]),
        '9' * qrDigits(good).length,
        '',
        'nonsense',
        base64Url.encode(utf8.encode('{"k":"a"}')),
      ])
        <String, dynamic>{'link': bad, 'expect': null},
    ];
    // A record the reader does not know is skipped.
    final FlatDoorCode two = _code(2);
    vectors.add(<String, dynamic>{
      'link': qrDigits(<int>[...good, 9, 2, 0xAB, 0xCD]),
      'expect': <String, dynamic>{
        'format': 2,
        'key': two.key,
        'door': two.door,
        'inbox': hexOf(two.inbox),
        'slots': <String>[for (final String s in two.mail!.slots) hexOf(s)],
        'seal': two.mail!.seal,
        'name': two.name,
        'until': null,
      },
    });
    final Directory dir = Directory.systemTemp.createTempSync('zen-door');
    try {
      final File file = File('${dir.path}/vectors.json')
        ..writeAsStringSync(jsonEncode(vectors));
      final ProcessResult run = await Process.run(node, <String>[
        '-e',
        _harness,
        File('tool/pages/m/door.js').absolute.path,
        file.absolute.path,
      ], stdoutEncoding: utf8);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      final List<dynamic> got = jsonDecode(run.stdout as String) as List;
      expect(got, hasLength(vectors.length));
      for (int i = 0; i < vectors.length; i++) {
        expect(got[i], vectors[i]['expect'], reason: '${vectors[i]['link']}');
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

/// What node reads from each vector with the door page's reader.
const String _harness = r"""
const reader = require(process.argv[1]);
const vectors = require(process.argv[2]);
process.stdout.write(JSON.stringify(vectors.map((v) => reader.decode(v.link))));
""";

/// [name] when it runs here (`[name] --version`), or null.
String? _tool(String name) {
  try {
    return Process.runSync(name, <String>['--version']).exitCode == 0
        ? name
        : null;
  } on ProcessException {
    return null;
  }
}
