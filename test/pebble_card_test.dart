import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_link.dart';

const PebbleCardLook _look = PebbleCardLook(
  shape: 7,
  seed: 0xDEADBEEF,
  material: 3,
  mainColour: 0x3366CC,
  secondColour: 0xFFCC00,
);

Uint8List _design([int n = 2048]) =>
    Uint8List.fromList(List<int>.generate(n, (int i) => (i * 31) & 0xFF));

Uint8List _thumbnail() => Uint8List.fromList(
  List<int>.generate(kPebbleThumbnailBytes, (int i) => (i * 7) & 0xFF),
);

Future<PebbleCard> _card(
  LedgerKeyPair key, {
  String name = 'Biedronka',
  String note = 'niedaleko Wisły w Warszawie',
  String author = 'Kasia',
  Uint8List? thumbnail,
  Uint8List? design,
}) => PebbleCard.sign(
  key: key,
  design: design ?? _design(),
  createdSeconds: 1767225600,
  look: _look,
  name: name,
  note: note,
  authorName: author,
  thumbnail: thumbnail,
);

void main() {
  late LedgerKeyPair kasia;
  late LedgerKeyPair other;

  setUpAll(() async {
    kasia = await LedgerKeyPair.generate();
    other = await LedgerKeyPair.generate();
  });

  group('PebbleCard', () {
    test('round trips every field and verifies', () async {
      final PebbleCard card = await _card(kasia, thumbnail: _thumbnail());
      final PebbleCard back = PebbleCard.decode(card.bytes)!;
      expect(back, card);
      expect(back.name, 'Biedronka');
      expect(back.note, 'niedaleko Wisły w Warszawie');
      expect(back.authorName, 'Kasia');
      expect(back.look, _look);
      expect(back.createdSeconds, 1767225600);
      expect(back.thumbnail, _thumbnail());
      expect(back.authorAccount, kasia.id);
      expect(back.bytes.first, kPebbleCardVersion);
      expect(await back.verify(), isTrue);
      expect(back.matchesDesign(_design()), isTrue);
      expect(back.matchesDesign(_design(2047)), isFalse);
    });

    test('the binary layout is format v1', () async {
      final PebbleCard card = await _card(
        kasia,
        name: 'A',
        note: '',
        author: 'K',
      );
      final Uint8List b = card.bytes;
      expect(b[0], 1);
      expect(b.sublist(1, 17), card.id.bytes);
      expect(b.sublist(17, 49), kasia.publicKey);
      expect(b.sublist(49, 53), <int>[0x69, 0x55, 0xB9, 0x00]);
      expect(b[53], 7);
      expect(b.sublist(54, 58), <int>[0xDE, 0xAD, 0xBE, 0xEF]);
      expect(b[58], 3);
      expect(b.sublist(59, 65), <int>[0x33, 0x66, 0xCC, 0xFF, 0xCC, 0x00]);
      expect(b.sublist(65, 71), <int>[1, 0x41, 0, 1, 0x4B, 0]);
      expect(b.length, 71 + 64);
      expect(
        card.id,
        PebbleId.of(
          author: kasia.publicKey,
          createdSeconds: 1767225600,
          design: _design(),
        ),
      );
    });

    test('a changed byte anywhere is rejected', () async {
      final PebbleCard card = await _card(kasia, thumbnail: _thumbnail());
      for (final int at in <int>[
        1,
        20,
        50,
        60,
        70,
        card.bytes.length - 70,
        card.bytes.length - 1,
      ]) {
        final Uint8List bad = Uint8List.fromList(card.bytes);
        bad[at] ^= 0x01;
        final PebbleCard? tampered = PebbleCard.decode(bad);
        if (tampered != null) {
          expect(await tampered.verify(), isFalse, reason: 'byte $at');
        }
      }
    });

    test(
      'a card signed by another key under the author id is rejected',
      () async {
        final PebbleCard byOther = await _card(other);
        // The other key's signature, with Kasia named as the author.
        final Uint8List forged = Uint8List.fromList(byOther.bytes)
          ..setRange(17, 49, kasia.publicKey);
        expect(await PebbleCard.decode(forged)!.verify(), isFalse);
        final PebbleCard honest = await _card(kasia);
        expect(honest.authorAccount, isNot(byOther.authorAccount));
      },
    );

    test('malformed cards are not taken', () async {
      final PebbleCard card = await _card(kasia);
      expect(PebbleCard.decode(Uint8List(0)), isNull);
      expect(
        PebbleCard.decode(card.bytes.sublist(0, card.bytes.length - 1)),
        isNull,
      );
      expect(
        PebbleCard.decode(Uint8List.fromList(<int>[...card.bytes, 0])),
        isNull,
      );
      final Uint8List v2 = Uint8List.fromList(card.bytes)..[0] = 2;
      expect(PebbleCard.decode(v2), isNull);
      expect(
        PebbleCard.decode(Uint8List(kPebbleCardFormatMaxBytes + 1)),
        isNull,
      );
      expect(PebbleCard.fromText('${card.text}=='), isNull, reason: 'padded');
      expect(PebbleCard.fromText('${card.text}!'), isNull);
    });

    test(
      'maximal fields are cut to their limits, the thumbnail stays',
      () async {
        final PebbleCard ascii = await _card(
          kasia,
          name: 'N' * 60,
          note: 'o' * 150,
          author: 'A' * 50,
          thumbnail: _thumbnail(),
        );
        expect(ascii.bytes.length, lessThanOrEqualTo(kPebbleCardMaxBytes));
        expect(ascii.name.length, kPebbleNameMaxChars);
        expect(ascii.note.length, kPebbleNoteMaxChars);
        expect(ascii.authorName.length, kPebbleAuthorNameMaxChars);
        // The full card never goes into a QR code: the preview stays.
        expect(ascii.thumbnail, _thumbnail());
        expect(await ascii.verify(), isTrue);

        final PebbleCard wide = await _card(
          kasia,
          name: '🐞' * 40,
          note: '🌊' * 100,
          author: '😀' * 32,
          thumbnail: _thumbnail(),
        );
        expect(wide.bytes.length, lessThanOrEqualTo(kPebbleCardMaxBytes));
        expect(wide.name.runes.length, lessThanOrEqualTo(kPebbleNameMaxChars));
        expect(await wide.verify(), isTrue);
        expect(PebbleCard.decode(wide.bytes), wide);
      },
    );

    test(
      'the QR card keeps only what the page and the first contact need',
      () async {
        final PebbleCard full = await _card(kasia, thumbnail: _thumbnail());
        final PebbleCard qr = full.qrCard;
        expect(qr.version, kPebbleQrCardVersion);
        expect(qr.isFull, isFalse);
        expect(qr.id, full.id);
        expect(qr.author, full.author);
        expect(qr.look, full.look);
        expect(qr.name, 'Biedronka');
        expect(qr.authorName, 'Kasia');
        // The note, the date, the preview and the signature come with the
        // design.
        expect(qr.note, isEmpty);
        expect(qr.created, isNull);
        expect(qr.thumbnail, isNull);
        expect(qr.signature, isEmpty);
        expect(qr.bytes.length, 1 + 16 + 32 + 12 + 1 + 9 + 1 + 5);
        expect(PebbleCard.decode(qr.bytes), qr);
        expect(qr.qrCard, qr);
        // Not signed: never taken as the author's, never matched to a design.
        expect(await qr.verify(), isFalse);
        expect(qr.matchesDesign(_design()), isFalse);
        expect(qr.isSamePebble(full), isTrue);
        expect(qr.isSamePebble(await _card(other)), isFalse);

        // Long names are cut on a whole letter, with "…".
        final PebbleCard wide = await _card(
          kasia,
          name: 'Żółć gęślą jaźń ąę Ź',
          author: 'Małgorzata Łęcka',
        );
        final PebbleCard cut = wide.qrCard;
        expect(utf8.encode(cut.name).length, lessThanOrEqualTo(24));
        expect(utf8.encode(cut.authorName).length, lessThanOrEqualTo(16));
        expect(cut.name, endsWith('…'));
        expect(cut.authorName, endsWith('…'));
        expect(
          'Żółć gęślą jaźń ąę Ź',
          startsWith(cut.name.replaceAll('…', '')),
        );
        expect(cut.bytes.length, lessThanOrEqualTo(kPebbleQrCardMaxBytes));
        expect(clipPebbleTextBytes('Ala', 24), 'Ala');
      },
    );

    test('the QR card goes into the link as digits, both ways', () async {
      final PebbleCard full = await _card(kasia);
      final String digits = full.linkText;
      expect(RegExp(r'^[0-9]+$').hasMatch(digits), isTrue);
      expect(pebbleBytesFromDigits(digits), full.qrCard.bytes);
      expect(PebbleCard.fromLinkText(digits), full.qrCard);
      // The length says how many bytes: one digit less is no card.
      expect(pebbleBytesFromDigits(digits.substring(1)), isNull);
      expect(pebbleBytesFromDigits('9' * digits.length), isNull);
      expect(pebbleDigits(<int>[0, 0, 1]), '00000001');
      expect(pebbleBytesFromDigits('00000001'), <int>[0, 0, 1]);
      // The base64url of any card is read too (the first test builds).
      expect(PebbleCard.fromLinkText(full.text), full);
      expect(PebbleCard.fromLinkText(full.qrCard.text), full.qrCard);
    });

    test('the thumbnail decodes into a palette and 256 pixels', () {
      final ({List<int> palette, List<int> pixels})? t = decodePebbleThumbnail(
        _thumbnail(),
      );
      expect(t!.palette, hasLength(16));
      expect(t.pixels, hasLength(256));
      expect(t.pixels.every((int p) => p >= 0 && p < 16), isTrue);
      expect(decodePebbleThumbnail(Uint8List(10)), isNull);
    });
  });

  group('PebbleId', () {
    test('base32 round trip', () async {
      final PebbleCard card = await _card(kasia);
      final String text = card.id.text;
      expect(text, hasLength(26));
      expect(RegExp(r'^[a-z2-7]+$').hasMatch(text), isTrue);
      expect(PebbleId.parse(text), card.id);
      expect(PebbleId.parse(text.toUpperCase()), card.id);
      expect(PebbleId.parse('x'), isNull);
      expect(PebbleId.parse('${text.substring(0, 25)}1'), isNull);
    });
  });

  group('links', () {
    test('web and app links carry the card both ways', () async {
      final PebbleCard card = await _card(kasia, thumbnail: _thumbnail());
      final String web = pebbleWebLink(card);
      expect(
        web,
        'https://robertostrowskijagoda.github.io/Zen/k/#${card.linkText}',
      );
      // The link carries the QR card.
      expect(pebbleCardFromLink(web), card.qrCard);
      final String app = pebbleAppLink(card);
      expect(app, 'zen://pebble#${card.linkText}');
      expect(pebbleCardFromLink(app), card.qrCard);
      expect(pebbleCardFromLink('  $web  '), card.qrCard);
      expect(
        pebbleCardFromLink(web.replaceFirst('/k/#', '/k#')),
        card.qrCard,
        reason: 'without the trailing slash',
      );
      // The first test builds' links: the whole signed card in base64url.
      expect(
        pebbleCardFromLink(
          'https://robertostrowskijagoda.github.io/Zen/k/#${card.text}',
        ),
        card,
      );
      expect(pebbleCardFromLink('zen://pebble#${card.text}'), card);
    });

    test('other links are not pebbles', () async {
      final PebbleCard card = await _card(kasia);
      expect(pebbleCardFromLink(null), isNull);
      expect(pebbleCardFromLink(''), isNull);
      expect(
        pebbleCardFromLink('https://example.com/Zen/k/#${card.text}'),
        isNull,
      );
      expect(
        pebbleCardFromLink(
          'https://robertostrowskijagoda.github.io/Zen/m/#${card.text}',
        ),
        isNull,
      );
      expect(pebbleCardFromLink('zen://c/ABCDE'), isNull);
      expect(isPebbleLink('zen://pebble#notacard'), isFalse);
    });
  });

  group('signed records', () {
    test('a keeper list is checked against the card author', () async {
      final PebbleCard card = await _card(kasia);
      final PebbleKeeperList list = await PebbleKeeperList.sign(
        key: kasia,
        id: card.id,
        version: 5,
        keepers: <String>['200:aaaa::1', '200:bbbb::2'],
      );
      final PebbleKeeperList back = PebbleKeeperList.fromJson(list.toJson())!;
      expect(await back.verifyFor(card), isTrue);
      expect(back.keepers, <String>['200:aaaa::1', '200:bbbb::2']);
      final PebbleKeeperList forged = await PebbleKeeperList.sign(
        key: other,
        id: card.id,
        version: 6,
        keepers: <String>['200:evil::1'],
      );
      expect(await forged.verifyFor(card), isFalse);
      final Map<String, dynamic> changed = list.toJson()
        ..['k'] = <String>['200:evil::1'];
      expect(
        await PebbleKeeperList.fromJson(changed)!.verifyFor(card),
        isFalse,
      );
      final PebbleKeeperList retired = await PebbleKeeperList.sign(
        key: kasia,
        id: card.id,
        version: 7,
        keepers: <String>['200:aaaa::1'],
        retired: true,
      );
      expect(retired.keepers, isEmpty);
      expect(
        await PebbleKeeperList.fromJson(retired.toJson())!.verifyFor(card),
        isTrue,
      );
    });

    test('a found note is signed by the finder', () async {
      final PebbleCard card = await _card(kasia);
      final PebbleFoundNote note = await PebbleFoundNote.sign(
        key: other,
        id: card.id,
        atSeconds: 1767300000,
      );
      final PebbleFoundNote back = PebbleFoundNote.fromJson(note.toJson())!;
      expect(back.finder, other.id);
      expect(await back.verify(), isTrue);
      final Map<String, dynamic> moved = note.toJson()..['at'] = 1767300001;
      expect(await PebbleFoundNote.fromJson(moved)!.verify(), isFalse);
    });
  });

  group('the shared test vectors (tool/ci/pebble_card_vectors.json)', () {
    final Map<String, dynamic> file =
        jsonDecode(File('tool/ci/pebble_card_vectors.json').readAsStringSync())
            as Map<String, dynamic>;

    Uint8List hex(String h) => Uint8List.fromList(<int>[
      for (int i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16),
    ]);

    String hexOf(List<int> b) =>
        b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

    int colour(String c) => int.parse(c.substring(1), radix: 16);

    test('RFC 8032 signatures check out', () async {
      for (final Object? v in file['rfc8032'] as List<Object?>) {
        final Map<String, dynamic> m = v! as Map<String, dynamic>;
        expect(
          await verifyClassicalSignature(
            publicKey: b64(hex(m['key'] as String)),
            message: hex(m['message'] as String),
            signature: b64(hex(m['signature'] as String)),
          ),
          isTrue,
        );
      }
    });

    for (final Object? v in file['vectors'] as List<Object?>) {
      final Map<String, dynamic> vector = v! as Map<String, dynamic>;
      test(vector['name'], () async {
        final PebbleCard? card = PebbleCard.fromLinkText(
          vector['card'] as String,
        );
        final Map<String, dynamic>? want =
            vector['expect'] as Map<String, dynamic>?;
        if (want == null) {
          expect(card, isNull);
          return;
        }
        expect(card, isNotNull);
        expect(card!.bytes.first, want['version']);
        expect(hexOf(card.id.bytes), want['id']);
        expect(hexOf(card.author), want['authorKey']);
        expect(card.look.shape, want['shape']);
        expect(card.name, want['name']);
        expect(card.authorName, want['author']);
        expect(pebbleCardFromLink('${file['link']}${vector['card']}'), card);
        if (want['version'] == kPebbleQrCardVersion) {
          // Dart writes the same digits as the script.
          expect(card.linkText, vector['card']);
          expect(card.isFull, isFalse);
          expect(card.note, isEmpty);
          expect(card.thumbnail, isNull);
          expect(want['signature'], 'unsigned');
          expect(await card.verify(), isFalse);
          return;
        }
        expect(card.createdSeconds, want['created']);
        expect(card.look.shape, want['shape']);
        expect(card.look.seed, want['seed']);
        expect(card.look.material, want['material']);
        expect(card.look.mainColour, colour(want['main'] as String));
        expect(card.look.secondColour, colour(want['second'] as String));
        expect(card.name, want['name']);
        expect(card.note, want['note']);
        expect(card.authorName, want['author']);
        final Map<String, dynamic>? thumb =
            want['thumbnail'] as Map<String, dynamic>?;
        final ({List<int> palette, List<int> pixels})? t =
            decodePebbleThumbnail(card.thumbnail);
        if (thumb == null) {
          expect(t, isNull);
        } else {
          expect(t!.palette, <int>[
            for (final Object? c in thumb['palette'] as List<Object?>)
              colour(c! as String),
          ]);
          expect(t.pixels, thumb['pixels']);
        }
        expect(await card.verify(), want['signature'] == 'valid');
        expect(pebbleCardFromLink('${file['link']}${vector['card']}'), card);
      });
    }
  });
}
