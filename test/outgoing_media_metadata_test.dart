import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_transfer.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/media/outgoing_media.dart';

import 'support/friends_world.dart';

// What a person sends leaves without the place, the device and the time it
// was made, whatever way it was picked: every chat path ends in
// prepareOutgoing (camera, gallery, files, a drop, the clipboard) and in the
// chat's send, which strips what is left before anything goes out.

const String _place = '+52.2297+021.0122/';
const String _gps = 'GPSLatitude 52.2297';
const String _model = 'Model Pixel 9';

Uint8List _box(String type, List<int> body) {
  final ByteData head = ByteData(8)..setUint32(0, 8 + body.length);
  return Uint8List.fromList(<int>[
    ...head.buffer.asUint8List(0, 4),
    ...latin1.encode(type),
    ...body,
  ]);
}

/// A tiny MP4 as an Android camera writes it: ftyp, moov with mvhd (the
/// time it was made) and udta/©xyz (where), mdat.
Uint8List _phoneFilm({String brand = 'isom'}) => Uint8List.fromList(<int>[
  ..._box('ftyp', <int>[
    ...latin1.encode(brand),
    0,
    0,
    2,
    0,
    ...latin1.encode('isomiso2mp41'),
  ]),
  ..._box('moov', <int>[
    ..._box('mvhd', <int>[
      0,
      0,
      0,
      0,
      0x11,
      0x22,
      0x33,
      0x44,
      ...List<int>.filled(96, 1),
    ]),
    ..._box('udta', <int>[
      ..._box('©xyz', <int>[0, 18, 0x15, 0xc7, ...latin1.encode(_place)]),
      ..._box('©mod', latin1.encode(_model)),
    ]),
  ]),
  ..._box('mdat', List<int>.filled(64, 7)),
]);

/// The start of a HEIC photo with an EXIF item carrying GPS.
Uint8List _heicPhoto() => Uint8List.fromList(<int>[
  ..._box('ftyp', <int>[
    ...latin1.encode('heic'),
    0,
    0,
    0,
    0,
    ...latin1.encode('mif1heic'),
  ]),
  ..._box('meta', <int>[0, 0, 0, 0, ...latin1.encode('Exif $_gps $_model')]),
  ..._box('mdat', List<int>.filled(64, 9)),
]);

/// An EXIF APP1 segment: IFD0 with the Orientation [orientation], then the
/// camera's model and GPS written after it.
List<int> _exifSegment(int orientation) {
  final List<int> payload = <int>[
    ...latin1.encode('Exif'), 0, 0, //
    ...latin1.encode('MM'), 0, 42, 0, 0, 0, 8,
    0, 1, // one entry
    0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0,
    0, 0, 0, 0,
    ...latin1.encode('$_model $_gps'),
  ];
  return <int>[
    0xFF,
    0xE1,
    (payload.length + 2) >> 8,
    (payload.length + 2) & 0xFF,
    ...payload,
  ];
}

/// A phone's JPEG: SOI, EXIF with GPS, the picture, and a trailer after its
/// end (where phones keep a second picture with its own EXIF).
Uint8List _phoneJpeg({int orientation = 6}) {
  final Uint8List plain = img.encodeJpg(
    img.Image(width: 8, height: 4)..clear(img.ColorRgb8(200, 30, 30)),
  );
  return Uint8List.fromList(<int>[
    0xFF, 0xD8, //
    ..._exifSegment(orientation),
    0xFF, 0xFE, 0, 2 + 9, ...latin1.encode('Pixel 9 !'), // a comment
    ...plain.sublist(2),
    ...latin1.encode('SEFH $_gps'),
  ]);
}

List<int> _pngChunk(String type, List<int> data) {
  final ByteData length = ByteData(4)..setUint32(0, data.length);
  return <int>[
    ...length.buffer.asUint8List(),
    ...latin1.encode(type),
    ...data,
    0, 0, 0, 0, // the CRC is not checked here
  ];
}

Uint8List _png() {
  final Uint8List plain = img.encodePng(img.Image(width: 4, height: 4));
  // After the signature and IHDR (8 + 25 bytes).
  return Uint8List.fromList(<int>[
    ...plain.sublist(0, 33),
    ..._pngChunk('tEXt', latin1.encode('Comment\u0000$_model $_gps')),
    ..._pngChunk('tIME', <int>[7, 234, 11, 10, 12, 0, 0]),
    ...plain.sublist(33),
  ]);
}

List<int> _riffChunk(String id, List<int> data) {
  final ByteData size = ByteData(4)..setUint32(0, data.length, Endian.little);
  return <int>[
    ...latin1.encode(id),
    ...size.buffer.asUint8List(),
    ...data,
    if (data.length.isOdd) 0,
  ];
}

Uint8List _riff(String form, List<int> chunks) {
  final ByteData size = ByteData(4)
    ..setUint32(0, 4 + chunks.length, Endian.little);
  return Uint8List.fromList(<int>[
    ...latin1.encode('RIFF'),
    ...size.buffer.asUint8List(),
    ...latin1.encode(form),
    ...chunks,
  ]);
}

Uint8List _webp() => _riff('WEBP', <int>[
  ..._riffChunk('VP8X', <int>[0x08, 0, 0, 0, 3, 0, 0, 3, 0, 0]),
  ..._riffChunk('VP8L', List<int>.filled(20, 5)),
  ..._riffChunk('EXIF', latin1.encode('MM $_model $_gps')),
]);

Uint8List _wav() => _riff('WAVE', <int>[
  ..._riffChunk('fmt ', List<int>.filled(16, 1)),
  ..._riffChunk('LIST', latin1.encode('INFOICMT $_model $_gps')),
  ..._riffChunk('bext', latin1.encode('Pixel 9 2026-11-10 12:00')),
  ..._riffChunk('data', List<int>.filled(32, 0)),
]);

Uint8List _mp3() {
  final List<int> frames = latin1.encode('TIT2 $_model $_gps');
  return Uint8List.fromList(<int>[
    ...latin1.encode('ID3'), 3, 0, 0, //
    0, 0, 0, frames.length,
    ...frames,
    0xFF, 0xFB, 0x90, 0x64, ...List<int>.filled(60, 0),
    ...latin1.encode('TAG'), ...List<int>.filled(125, 0x41),
  ]);
}

Uint8List _flac() {
  final List<int> comment = latin1.encode('LOCATION=$_gps');
  return Uint8List.fromList(<int>[
    ...latin1.encode('fLaC'),
    0x00, 0, 0, 34, ...List<int>.filled(34, 2), // STREAMINFO
    0x84, 0, 0, comment.length, ...comment, // VORBIS_COMMENT, last
    0xFF, 0xF8, ...List<int>.filled(20, 3), // frames
  ]);
}

bool _has(Uint8List bytes, String text) =>
    latin1.decode(bytes, allowInvalid: true).contains(text);

/// The phone's decoder in a test: any picture becomes a small red PNG.
Future<Uint8List?> _phoneDecoder(
  Uint8List bytes, {
  required int maxSide,
}) async => img.encodePng(
  img.Image(width: 6, height: 4)..clear(img.ColorRgb8(9, 9, 9)),
);

Future<Uint8List?> _noDecoder(Uint8List bytes, {required int maxSide}) async =>
    null;

void main() {
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('zen-outgoing-');
  });

  tearDownAll(() {
    dir.deleteSync(recursive: true);
  });

  File write(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  group('stripOutgoingMetadata', () {
    test('a film loses where, when and on what it was made', () {
      final Uint8List film = _phoneFilm();
      final Uint8List clean = stripOutgoingMetadata(film);
      expect(_has(clean, _place), isFalse);
      expect(_has(clean, _model), isFalse);
      expect(clean.length, film.length, reason: 'nothing moves');
      expect(clean.sublist(48, 52), <int>[0, 0, 0, 0], reason: 'mvhd time');
    });

    test('a JPEG loses EXIF, comments and its trailer, keeps its turn', () {
      final Uint8List clean = stripOutgoingMetadata(_phoneJpeg());
      expect(_has(clean, _gps), isFalse);
      expect(_has(clean, 'Pixel 9'), isFalse);
      expect(_has(clean, 'SEFH'), isFalse);
      expect(clean.sublist(clean.length - 2), <int>[0xFF, 0xD9]);
      expect(img.decodeJpg(clean), isNotNull);
      // Only the turn is left of the EXIF.
      expect(
        _has(clean, latin1.decode(<int>[0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6])),
        isTrue,
      );
    });

    test('PNG, WebP, GIF-less pictures and recordings lose their tags', () {
      for (final (String name, Uint8List bytes) in <(String, Uint8List)>[
        ('png', _png()),
        ('webp', _webp()),
        ('wav', _wav()),
        ('mp3', _mp3()),
        ('flac', _flac()),
        ('m4a', _phoneFilm(brand: 'M4A ')),
      ]) {
        expect(canStripMetadata(bytes), isTrue, reason: name);
        final Uint8List clean = stripOutgoingMetadata(bytes);
        expect(_has(clean, _gps) || _has(clean, _place), isFalse, reason: name);
        expect(sniffMediaKind(clean), sniffMediaKind(bytes), reason: name);
      }
      final Uint8List webp = stripOutgoingMetadata(_webp());
      expect(webp[20] & 0x0C, 0, reason: 'no EXIF flag left');
      expect(
        ByteData.sublistView(webp).getUint32(4, Endian.little),
        webp.length - 8,
      );
      expect(img.decodePng(stripOutgoingMetadata(_png())), isNotNull);
    });

    test('a HEIC photo and a document are not touched (and say so)', () {
      final Uint8List heic = _heicPhoto();
      expect(canStripMetadata(heic), isFalse);
      expect(identical(stripOutgoingMetadata(heic), heic), isTrue);
      final Uint8List pdf = Uint8List.fromList(
        latin1.encode('%PDF-1.7 /Author (Ala Kowalska)'),
      );
      expect(canStripMetadata(pdf), isFalse);
      expect(identical(stripOutgoingMetadata(pdf), pdf), isTrue);
    });

    test('what has nothing to remove stays the same object', () {
      final Uint8List clean = stripOutgoingMetadata(_phoneFilm());
      expect(identical(stripOutgoingMetadata(clean), clean), isTrue);
    });
  });

  group('prepareOutgoing (camera, gallery, files, drop, clipboard)', () {
    test(
      'a film goes without its place, from memory and from a file',
      () async {
        final OutgoingAttachment fromCamera = (await prepareOutgoing(
          TransferItem(name: 'VID_20261110.mp4', bytes: _phoneFilm()),
        ))!;
        expect(fromCamera.kind, OutgoingKind.video);
        expect(_has(fromCamera.bytes!, _place), isFalse);
        expect(fromCamera.unchanged, isFalse);

        final File film = write('VID_1.mp4', _phoneFilm());
        final OutgoingAttachment fromFiles = (await prepareOutgoing(
          TransferItem(name: 'VID_1.mp4', path: film.path),
        ))!;
        expect(fromFiles.kind, OutgoingKind.video);
        expect(fromFiles.path, isNull, reason: 'the cleaned copy goes');
        expect(_has(fromFiles.bytes!, _place), isFalse);
      },
    );

    test(
      'a HEIC photo goes as a fresh JPEG once the phone decoded it',
      () async {
        final OutgoingAttachment out = (await prepareOutgoing(
          TransferItem(name: 'IMG_0001.HEIC', bytes: _heicPhoto()),
          decode: _phoneDecoder,
        ))!;
        expect(out.kind, OutgoingKind.photo);
        expect(out.fileName, 'IMG_0001.jpg');
        expect(out.bytes!.sublist(0, 3), <int>[0xFF, 0xD8, 0xFF]);
        expect(_has(out.bytes!, _gps), isFalse);
      },
    );

    test('a HEIC photo the phone cannot decode goes as a file, marked '
        'unchanged', () async {
      final OutgoingAttachment out = (await prepareOutgoing(
        TransferItem(name: 'IMG_0002.HEIC', bytes: _heicPhoto()),
        decode: _noDecoder,
      ))!;
      expect(out.kind, OutgoingKind.file);
      expect(out.unchanged, isTrue);
      expect(out.mimeType, 'image/heic');
    });

    test('a phone JPEG goes re-encoded, recordings and pictures as files '
        'without tags, documents unchanged', () async {
      final OutgoingAttachment photo = (await prepareOutgoing(
        TransferItem(name: 'IMG_1.jpg', bytes: _phoneJpeg()),
      ))!;
      expect(photo.kind, OutgoingKind.photo);
      expect(_has(photo.bytes!, _gps), isFalse);

      final File song = write('nagranie.mp3', _mp3());
      final OutgoingAttachment audio = (await prepareOutgoing(
        TransferItem(name: 'nagranie.mp3', path: song.path),
      ))!;
      expect(audio.kind, OutgoingKind.file);
      expect(audio.unchanged, isFalse);
      expect(_has(audio.bytes!, _gps), isFalse);

      final File pdf = write('umowa.pdf', latin1.encode('%PDF-1.7 /Author'));
      final OutgoingAttachment document = (await prepareOutgoing(
        TransferItem(name: 'umowa.pdf', path: pdf.path),
      ))!;
      expect(document.kind, OutgoingKind.file);
      expect(document.unchanged, isTrue);
      expect(document.path, pdf.path);
    });

    testWidgets('a file that goes unchanged is said once', (
      WidgetTester tester,
    ) async {
      debugResetToldFilesGoUnchanged();
      addTearDown(debugResetToldFilesGoUnchanged);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      const OutgoingAttachment document = OutgoingAttachment(
        kind: OutgoingKind.file,
        fileName: 'umowa.pdf',
        mimeType: 'application/pdf',
        unchanged: true,
      );
      tellFilesGoUnchanged(context, document);
      await tester.pump();
      expect(find.byKey(const Key('file-goes-unchanged')), findsOneWidget);
      ScaffoldMessenger.of(context).clearSnackBars();
      await tester.pumpAndSettle();
      tellFilesGoUnchanged(context, document);
      await tester.pump();
      expect(find.byKey(const Key('file-goes-unchanged')), findsNothing);
    });
  });

  group('the chat send', () {
    test('a film reaches the friend without its place, sent from memory '
        'or from a file (a voice message, a forward)', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      await w['A'].hub.sendLocalAttachment(
        peerAddress: w['B'].address,
        bytes: _phoneFilm(),
        fileName: 'film.mp4',
        mimeType: 'video/mp4',
        type: ChatMessageType.video,
        sentAtMillis: w.now,
      );
      final File m4a = write('glos.m4a', _phoneFilm(brand: 'M4A '));
      await w['A'].hub.sendLocalAttachment(
        peerAddress: w['B'].address,
        attachmentPath: m4a.path,
        fileName: 'glos.m4a',
        mimeType: 'audio/mp4',
        type: ChatMessageType.voice,
        sentAtMillis: w.now + 1,
      );
      await w.settle();
      final List<ChatMessage> got = <ChatMessage>[
        for (final ChatMessage m in await w['B'].thread(w['A']))
          if (m.direction == ChatMessageDirection.incoming) m,
      ];
      expect(got, hasLength(2));
      final MediaVault vault = w['B'].container.read(mediaVaultProvider);
      for (final ChatMessage m in got) {
        final Uint8List bytes = m.attachmentBytes?.isNotEmpty == true
            ? m.attachmentBytes!
            : await vault.read(m.attachmentPath!);
        expect(_has(bytes, _place), isFalse, reason: m.fileName);
        expect(_has(bytes, _model), isFalse, reason: m.fileName);
      }
      // What A keeps of its own message is the cleaned copy too.
      final MediaVault own = w['A'].container.read(mediaVaultProvider);
      int checked = 0;
      for (final ChatMessage m in await w['A'].thread(w['B'])) {
        if (m.attachmentPath == null && (m.attachmentBytes?.isEmpty ?? true)) {
          continue;
        }
        checked++;
        final Uint8List bytes = m.attachmentBytes?.isNotEmpty == true
            ? m.attachmentBytes!
            : await own.read(m.attachmentPath!);
        expect(_has(bytes, _place), isFalse, reason: m.fileName);
      }
      expect(checked, 2);
    });

    test('a recording in a post loses its tags too (storeMedia)', () async {
      final BlobStore blobs = BlobStore();
      final MediaRef ref = mediaRefFromJson(
        await storeMedia(
          blobs,
          _mp3(),
          mime: 'audio/mpeg',
          stripMetadata: true,
        ),
      )!;
      final Uint8List stored = (await openMedia(blobs, ref))!;
      expect(_has(stored, _gps), isFalse);
      expect(sniffMediaKind(stored), MediaKind.audio);
    });
  });

  group('pictureDisplaySize (the size a message carries)', () {
    test('a GIF by its canvas, a PNG by its header', () {
      expect(
        pictureDisplaySize(img.encodeGif(img.Image(width: 30, height: 20))),
        (width: 30, height: 20),
      );
      expect(
        pictureDisplaySize(img.encodePng(img.Image(width: 12, height: 5))),
        (width: 12, height: 5),
      );
      expect(pictureDisplaySize(_png()), (width: 4, height: 4));
    });

    test('a JPEG turned a quarter by its EXIF is as tall as it is shown', () {
      for (final int orientation in <int>[1, 2, 3, 4]) {
        expect(pictureDisplaySize(_phoneJpeg(orientation: orientation)), (
          width: 8,
          height: 4,
        ), reason: 'orientation $orientation');
      }
      for (final int orientation in <int>[5, 6, 7, 8]) {
        expect(pictureDisplaySize(_phoneJpeg(orientation: orientation)), (
          width: 4,
          height: 8,
        ), reason: 'orientation $orientation');
      }
      // Cleaned for sending, the turn stays and so does the size.
      expect(pictureDisplaySize(stripOutgoingMetadata(_phoneJpeg())), (
        width: 4,
        height: 8,
      ));
      // A JPEG with no EXIF at all.
      expect(
        pictureDisplaySize(img.encodeJpg(img.Image(width: 9, height: 3))),
        (width: 9, height: 3),
      );
    });

    test('the start of a picture is enough', () {
      final Uint8List jpeg = _phoneJpeg();
      expect(
        pictureDisplaySize(Uint8List.sublistView(jpeg, 0, jpeg.length - 20)),
        (width: 4, height: 8),
      );
    });

    test('anything that is not a readable picture has no size', () {
      expect(pictureDisplaySize(_phoneFilm()), isNull);
      expect(
        pictureDisplaySize(Uint8List.fromList(utf8.encode('zdjęcie'))),
        isNull,
      );
      expect(pictureDisplaySize(Uint8List(0)), isNull);
      // A GIF cut before its size, and one whose canvas is empty.
      expect(
        pictureDisplaySize(Uint8List.fromList(latin1.encode('GIF89a'))),
        isNull,
      );
      expect(
        pictureDisplaySize(
          Uint8List.fromList(<int>[...latin1.encode('GIF89a'), 0, 0, 5, 0]),
        ),
        isNull,
      );
      expect(
        pictureDisplaySize(
          Uint8List.fromList(<int>[...latin1.encode('GIF89a'), 5, 0, 0, 0]),
        ),
        isNull,
      );
      // A JPEG whose segments do not add up is read as unturned or not at
      // all, never as something else.
      expect(
        pictureDisplaySize(
          Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF]),
        ),
        isNull,
      );
    });
  });
}
