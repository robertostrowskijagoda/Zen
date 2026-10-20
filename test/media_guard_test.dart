import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/media/media_guard.dart';

/// An ISO media box: size, name, payload.
List<int> _box(String type, List<int> payload) {
  final int size = 8 + payload.length;
  return <int>[
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ];
}

/// A tiny MP4/M4A: ftyp with [brand], moov, mdat.
Uint8List _iso(String brand) => Uint8List.fromList(<int>[
  ..._box('ftyp', <int>[...brand.codeUnits, 0, 0, 0, 0, ...'isom'.codeUnits]),
  ..._box('moov', List<int>.filled(16, 0)),
  ..._box('mdat', List<int>.filled(32, 7)),
]);

Uint8List _jpegWithGps() {
  final img.Image picture = img.Image(width: 40, height: 30);
  img.fill(picture, color: img.ColorRgb8(200, 30, 30));
  picture.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(52, 1);
  return img.encodeJpg(picture);
}

Uint8List _twoFrameGif() {
  final img.Image first = img.Image(width: 8, height: 8, numChannels: 4)
    ..frameDuration = 40;
  img.fill(first, color: img.ColorRgba8(255, 0, 0, 255));
  final img.Image second = img.Image(width: 8, height: 8, numChannels: 4)
    ..frameDuration = 40;
  img.fill(second, color: img.ColorRgba8(0, 0, 255, 255));
  first.addFrame(second);
  return img.encodeGif(first);
}

void main() {
  group('animated GIFs', () {
    test('a well-formed GIF is kept as it is, with all its frames', () async {
      final Uint8List gif = _twoFrameGif();
      expect(isAcceptableGif(gif), isTrue);
      final GuardedMedia g = await guardIncomingMedia(
        gif,
        declared: MediaKind.image,
        fileName: 'kot.gif',
      );
      expect(g.kind, MediaKind.image);
      expect(g.mimeType, 'image/gif');
      expect(g.fileName, 'kot.gif');
      expect(g.bytes, gif, reason: 're-encoding would flatten it');
      expect(img.decodeGif(g.bytes)!.numFrames, 2);
    });

    test('a truncated GIF becomes a plain file', () async {
      final Uint8List gif = _twoFrameGif();
      final Uint8List cut = Uint8List.sublistView(gif, 0, gif.length - 5);
      expect(isAcceptableGif(cut), isFalse);
      final GuardedMedia g = await guardIncomingMedia(
        cut,
        declared: MediaKind.image,
        fileName: 'kot.gif',
      );
      expect(g.kind, MediaKind.file);
    });

    test('a GIF with trailing bytes or an oversized canvas is refused', () {
      final Uint8List gif = _twoFrameGif();
      expect(isAcceptableGif(Uint8List.fromList(<int>[...gif, 0, 0])), isFalse);
      final Uint8List huge = Uint8List.fromList(gif);
      huge[6] = 0xB8; // 3000 px wide
      huge[7] = 0x0B;
      expect(isAcceptableGif(huge), isFalse);
    });

    test('not a GIF, or a GIF with a bad block, is refused', () {
      expect(isAcceptableGif(Uint8List.fromList(<int>[1, 2, 3])), isFalse);
      final Uint8List gif = _twoFrameGif();
      final Uint8List broken = Uint8List.fromList(gif);
      broken[broken.length - 1] = 0x01; // no trailer
      expect(isAcceptableGif(broken), isFalse);
    });

    test('a PNG named .gif is still re-encoded as a picture', () async {
      final Uint8List png = img.encodePng(
        img.Image(width: 8, height: 8, numChannels: 4),
      );
      final GuardedMedia g = await guardIncomingMedia(
        png,
        declared: MediaKind.image,
        fileName: 'kot.gif',
      );
      expect(g.mimeType, 'image/png');
      expect(g.fileName, 'kot.png');
    });
  });

  group('photos', () {
    test('a photo is decoded and made again, without its location', () async {
      final Uint8List original = _jpegWithGps();
      expect(img.decodeJpg(original)!.exif.gpsIfd.isEmpty, isFalse);

      final GuardedMedia g = await guardIncomingMedia(
        original,
        declared: MediaKind.image,
        fileName: 'wakacje.png',
      );
      expect(g.kind, MediaKind.image);
      expect(g.mimeType, 'image/jpeg');
      expect(g.fileName, 'wakacje.jpg', reason: 'the name follows the file');
      expect(g.bytes, isNot(original));
      expect(img.decodeJpg(g.bytes)!.exif.gpsIfd.isEmpty, isTrue);
    });

    test('a picture with transparency stays a PNG', () async {
      final Uint8List png = img.encodePng(
        img.Image(width: 8, height: 8, numChannels: 4),
      );
      final GuardedMedia g = await guardIncomingMedia(
        png,
        declared: MediaKind.image,
      );
      expect(g.kind, MediaKind.image);
      expect(g.mimeType, 'image/png');
    });

    test('a program sent as a "photo" becomes a risky file', () async {
      final Uint8List exe = Uint8List.fromList(<int>[
        0x4D, 0x5A, 0x90, 0x00, ...List<int>.filled(60, 0), //
      ]);
      final GuardedMedia g = await guardIncomingMedia(
        exe,
        declared: MediaKind.image,
        mimeType: 'image/jpeg',
        fileName: 'kotek.jpg',
      );
      expect(g.kind, MediaKind.file);
      expect(g.risky, isTrue);
      expect(g.mimeType, 'application/octet-stream');
      expect(g.note, isNotNull);
    });

    test('a picture claiming a giant size is refused before decoding', () {
      // A PNG header that says 100 000 × 100 000 pixels.
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      final ByteData data = ByteData.sublistView(png);
      data.setUint32(16, 100000);
      data.setUint32(20, 100000);
      expect(reencodeIncomingImage(png), isNull);
    });

    test('a HEIC picture cannot be made safe, so it is a file', () {
      expect(sniffMediaKind(_iso('heic')), MediaKind.file);
    });
  });

  group('films and recordings', () {
    test('a well-formed MP4 is a film', () async {
      final GuardedMedia g = await guardIncomingMedia(
        _iso('isom'),
        declared: MediaKind.video,
        fileName: 'film.mp4',
      );
      expect(g.kind, MediaKind.video);
      expect(g.mimeType, 'video/mp4');
    });

    test('a box reaching past the end of the file is refused', () async {
      final Uint8List broken = Uint8List.fromList(<int>[
        ..._box('ftyp', 'isom'.codeUnits),
        0x7F, 0xFF, 0xFF, 0xFF, ...'mdat'.codeUnits, 1, 2, 3, //
      ]);
      expect(looksLikeSafeContainer(broken), isFalse);
      final GuardedMedia g = await guardIncomingMedia(
        broken,
        declared: MediaKind.video,
      );
      expect(g.kind, MediaKind.file);
    });

    test('a WebM film says so in its header', () {
      final Uint8List webm = Uint8List.fromList(<int>[
        0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x84, //
        ...'webm'.codeUnits, ...List<int>.filled(20, 0),
      ]);
      expect(sniffMediaKind(webm), MediaKind.video);
      expect(looksLikeSafeContainer(webm), isTrue);
    });

    test('voice messages and audio files pass, random bytes do not', () async {
      final GuardedMedia m4a = await guardIncomingMedia(
        _iso('M4A '),
        declared: MediaKind.audio,
        fileName: 'glos.m4a',
      );
      expect(m4a.kind, MediaKind.audio);
      expect(m4a.mimeType, 'audio/mp4');

      final Uint8List ogg = Uint8List.fromList(<int>[
        ...'OggS'.codeUnits, 0, 2, ...List<int>.filled(30, 0), //
      ]);
      expect(sniffMediaKind(ogg), MediaKind.audio);

      final GuardedMedia junk = await guardIncomingMedia(
        Uint8List.fromList(List<int>.generate(64, (int i) => i * 7)),
        declared: MediaKind.audio,
      );
      expect(junk.kind, MediaKind.file);
    });
  });

  group('files', () {
    test('names that run something are risky, documents are not', () {
      expect(hasRiskyExtension('faktura.pdf'), isFalse);
      expect(hasRiskyExtension('zdjecie.jpg.exe'), isTrue);
      expect(hasRiskyExtension('aplikacja.APK'), isTrue);
      expect(hasRiskyExtension('skrot.lnk'), isTrue);
      expect(hasRiskyExtension('makro.docm'), isTrue);
      expect(hasRiskyExtension('bez-rozszerzenia'), isFalse);
    });

    test('dots and spaces at the end do not hide a program', () {
      // Windows drops them: these open as .exe, .ps1 and .bat.
      expect(hasRiskyExtension('faktura.exe.'), isTrue);
      expect(hasRiskyExtension('faktura.exe...'), isTrue);
      expect(hasRiskyExtension('skrypt.ps1 '), isTrue);
      expect(hasRiskyExtension('skrypt.ps1  .  '), isTrue);
      expect(hasRiskyExtension('plik.bat. .'), isTrue);
      expect(hasRiskyExtension('plik.EXE.'), isTrue);
      expect(hasRiskyExtension('plik.exe\u00A0'), isTrue);
      // Invisible characters never count, at the end or inside.
      expect(hasRiskyExtension('plik.exe\u200B'), isTrue);
      expect(hasRiskyExtension('plik.e\u200Bxe'), isTrue);
      expect(hasRiskyExtension('plik.exe\u202E'), isTrue);
      // The same dots after a harmless extension stay harmless.
      expect(hasRiskyExtension('faktura.pdf.'), isFalse);
      expect(hasRiskyExtension('faktura.pdf '), isFalse);
      expect(hasRiskyExtension('...'), isFalse);
      expect(hasRiskyExtension(''), isFalse);
    });

    test('only the last extension decides, a double one is no disguise', () {
      expect(hasRiskyExtension('zdjecie.jpg.exe'), isTrue);
      expect(hasRiskyExtension('faktura.pdf.exe.'), isTrue);
      expect(hasRiskyExtension('film.mp4.scr'), isTrue);
      expect(hasRiskyExtension('raport.docx.js'), isTrue);
      expect(hasRiskyExtension('program.exe.txt'), isFalse);
      expect(hasRiskyExtension('archiwum.tar.gz'), isFalse);
    });

    test('an alternate data stream is taken for its file', () {
      expect(hasRiskyExtension('plik.exe:strumien'), isTrue);
      expect(hasRiskyExtension('plik.exe::\$DATA'), isTrue);
      expect(hasRiskyExtension('plik.txt:strumien'), isFalse);
      expect(hasRiskyExtension('Notatki: spotkanie.txt'), isFalse);
    });

    test('the list of risky extensions covers what the system runs', () {
      for (final String ext in <String>[
        'jnlp',
        'appref-ms',
        'settingcontent-ms',
        'library-ms',
        'url',
        'desktop',
        'command',
        'app',
        'pkg',
        'dmg',
        'deb',
        'rpm',
        'AppImage',
        'sh',
        'msi',
        'lnk',
        'vbs',
        'ps1',
        'hta',
        'jar',
      ]) {
        expect(hasRiskyExtension('plik.$ext'), isTrue, reason: ext);
      }
      for (final String ext in <String>[
        'pdf',
        'jpg',
        'png',
        'txt',
        'docx',
        'xlsx',
        'zip',
        'mp4',
        'mp3',
        'csv',
      ]) {
        expect(hasRiskyExtension('plik.$ext'), isFalse, reason: ext);
      }
    });

    test('a file named with trailing dots is stored without them', () async {
      final GuardedMedia g = await guardIncomingMedia(
        Uint8List.fromList('MZ'.codeUnits),
        declared: MediaKind.file,
        fileName: 'faktura.exe. .',
      );
      expect(g.fileName, 'faktura.exe');
      expect(g.risky, isTrue);

      // Without a program inside, the name alone gives it away.
      final GuardedMedia byName = await guardIncomingMedia(
        Uint8List.fromList('echo'.codeUnits),
        declared: MediaKind.file,
        fileName: 'skrypt.cmd ',
      );
      expect(byName.risky, isTrue);
      expect(byName.mimeType, 'application/octet-stream');
    });

    test('a direction mark cannot dress a program up as a photo', () async {
      // Shown as "zdjecieexe.jpg", really "zdjecie\u202Egpj.exe".
      final GuardedMedia g = await guardIncomingMedia(
        Uint8List.fromList('MZ'.codeUnits),
        declared: MediaKind.file,
        fileName: 'zdjecie\u202Egpj.exe',
      );
      expect(g.fileName, isNot(contains('\u202E')));
      expect(g.fileName, endsWith('.exe'));
      expect(g.risky, isTrue);
    });

    test('a path in the name cannot leave the folder', () async {
      final GuardedMedia g = await guardIncomingMedia(
        Uint8List.fromList('hej'.codeUnits),
        declared: MediaKind.file,
        fileName: '../../.ssh/authorized_keys',
      );
      expect(g.fileName, isNot(contains('/')));
      expect(g.fileName, isNot(startsWith('.')));
    });
  });

  group('recordings in posts', () {
    test('only a real recording becomes a post recording', () {
      final DraftMedia m = audioDraft(_iso('M4A '), name: 'Głosówka');
      expect(m.isAudio, isTrue);
      expect(isAudioMime(m.mime), isTrue);
      expect(isPhotoMime(m.mime), isFalse);
      // A recording in an MP4 box is still a recording.
      expect(audioDraft(_iso('mp42')).mime, 'audio/mp4');
      expect(
        () => audioDraft(Uint8List.fromList('MZ to nie dźwięk'.codeUnits)),
        throwsArgumentError,
      );
    });

    testWidgets('a recording is put into a post and published with it', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      PostDraft? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: PostEditorScreen(
            pickAudio: () async => <DraftMedia>[
              audioDraft(_iso('M4A '), name: 'Koncert', durationMs: 61000),
            ],
            onSubmit: (PostDraft d) async {
              saved = d;
              return null;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('post-text')),
        'Posłuchajcie',
      );
      await tester.tap(find.byKey(const Key('post-tool-audio')));
      await tester.pump();
      expect(find.byKey(const Key('audio-clip')), findsOneWidget);
      expect(find.text('Koncert'), findsOneWidget);
      expect(find.textContaining('1:01'), findsOneWidget);
      expect(find.byKey(const Key('post-tool-voice')), findsOneWidget);

      await tester.tap(find.byKey(const Key('post-publish')));
      await tester.pump();
      expect(saved!.media.single.isAudio, isTrue);
      expect(saved!.media.single.durationMs, 61000);
      expect(saved!.text, contains('{{media:0}}'));
    });
  });
}
