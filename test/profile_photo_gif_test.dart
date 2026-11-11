import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/media/crop_region.dart';
import 'package:zen/src/features/media/gif_shrink.dart';
import 'package:zen/src/features/media/media_transfer.dart';
import 'package:zen/src/features/media/platform_picture.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/presentation/profile_edit_dialog.dart';
import 'package:zen/src/features/profile/presentation/profile_photo_viewer.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/profile/profile_cover.dart';

// An animated GIF picked as one's profile photo keeps moving: the gallery
// hands it over as it is, framing keeps every frame, the staged copy, the
// thumbnail friends get and the copy a friend keeps are animated GIFs, and
// the avatar and the photo viewer show frame after frame. An animated WebP
// or PNG is made a GIF wherever a picture is picked, not a still.

/// [frames] frames of [w] x [h], each a different colour, 60 ms apiece.
img.Image _animation(int w, int h, {int frames = 3}) {
  const List<List<int>> colours = <List<int>>[
    <int>[255, 0, 0],
    <int>[0, 0, 255],
    <int>[0, 200, 0],
    <int>[250, 250, 0],
  ];
  img.Image? first;
  for (int i = 0; i < frames; i++) {
    final List<int> c = colours[i % colours.length];
    final img.Image frame = img.Image(width: w, height: h, numChannels: 4)
      ..frameDuration = 60;
    img.fill(frame, color: img.ColorRgba8(c[0], c[1], c[2], 255));
    if (first == null) {
      first = frame;
    } else {
      first.addFrame(frame);
    }
  }
  return first!;
}

Uint8List _gif(int w, int h) => img.encodeGif(_animation(w, h));

/// An animated PNG (APNG) of three frames.
Uint8List _apng(int w, int h) => img.encodePng(_animation(w, h));

/// An animated WebP of two 1 x 1 frames: the smallest animated WebP (the
/// one browsers are probed with) with its frame given twice.
Uint8List _animatedWebP() {
  final Uint8List one = base64Decode(
    'UklGRlIAAABXRUJQVlA4WAoAAAASAAAAAAAAAAAAQU5JTQYAAAD/////AABBTk1GJgAAAAAA'
    'AAAAAAAAAAAAAGQAAABWUDhMDQAAAC8AAAAQBxAREYiI/gcA',
  );
  // The ANMF chunk is the last one.
  int at = 12;
  int anmf = -1;
  while (at + 8 <= one.length) {
    final String type = String.fromCharCodes(one, at, at + 4);
    final int size = ByteData.sublistView(
      one,
      at + 4,
      at + 8,
    ).getUint32(0, Endian.little);
    if (type == 'ANMF') {
      anmf = at;
    }
    at += 8 + size + (size & 1);
  }
  final Uint8List frame = Uint8List.sublistView(one, anmf, at);
  final Uint8List out = Uint8List.fromList(<int>[...one, ...frame]);
  ByteData.sublistView(out).setUint32(4, out.length - 8, Endian.little);
  return out;
}

int _frames(Uint8List gif) => gifShape(gif)?.frames ?? 0;

bool _isGif(Uint8List b) =>
    b.length > 4 && String.fromCharCodes(b.sublist(0, 4)) == 'GIF8';

/// Frames seen on screen while time goes on for about 0.7 s.
Future<int> _framesShown(WidgetTester tester) async {
  final Set<int> seen = <int>{};
  for (int i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 70));
    final Finder raw = find.byType(RawImage);
    if (raw.evaluate().isEmpty) {
      continue;
    }
    final ui.Image? frame = tester.widget<RawImage>(raw.first).image;
    if (frame != null) {
      seen.add(identityHashCode(frame));
    }
  }
  return seen.length;
}

void main() {
  late Directory dir;
  final List<Map<String, Object?>> asked = <Map<String, Object?>>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zen-profile-gif-');
    asked.clear();
    // The phone's picker as Android's image_picker behaves: given a size or
    // a quality below 100 it decodes the picture to one bitmap and writes
    // it again as a JPEG; without them it hands over the file as it is.
    final File picked = File('${dir.path}${Platform.pathSeparator}cat.gif')
      ..writeAsBytesSync(_gif(300, 200));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/image_picker'),
          (MethodCall call) async {
            final Map<String, Object?> args = Map<String, Object?>.from(
              call.arguments as Map<Object?, Object?>,
            );
            asked.add(args);
            final int quality = (args['imageQuality'] as int?) ?? 100;
            if (args['maxWidth'] != null ||
                args['maxHeight'] != null ||
                quality < 100) {
              final img.Image still = img.decodeImage(
                picked.readAsBytesSync(),
              )!;
              final File scaled = File(
                '${dir.path}${Platform.pathSeparator}scaled_cat.gif',
              )..writeAsBytesSync(img.encodeJpg(still, quality: quality));
              return scaled.path;
            }
            return picked.path;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/image_picker'),
          null,
        );
    dir.deleteSync(recursive: true);
  });

  test(
    'a GIF picked from the gallery as the profile photo stays an '
    'animated GIF: picked, framed, staged, sent and kept by a friend',
    () async {
      final String? path = await pickProfilePicturePath(camera: false);
      final Uint8List picked = File(path!).readAsBytesSync();
      // The gallery is asked for the file as it is.
      expect(asked.single['maxWidth'], isNull);
      expect(asked.single['maxHeight'], isNull);
      expect(asked.single['imageQuality'], isNull);
      expect(_isGif(picked), isTrue, reason: 'not re-encoded by the picker');
      expect(_frames(picked), 3);

      // Framed as the person chose: the left square.
      final Uint8List framed = makeAvatarImage((
        picked,
        const CropRegion(left: 0, top: 0, width: 2 / 3, height: 1),
      ))!;
      expect(_isGif(framed), isTrue);
      expect(_frames(framed), 3);

      final String staged = await AvatarSanitizer.validateAndStoreAvatarBytes(
        rawBytes: framed,
        folder: () async => dir,
      );
      expect(staged, endsWith('.gif'));
      final Uint8List kept = File(staged).readAsBytesSync();
      expect(_frames(kept), 3);

      // What friends get in `profile_update`, and what a friend keeps.
      final Uint8List sent = makeAvatarThumbnail(kept)!;
      expect(_isGif(sent), isTrue);
      expect(_frames(sent), greaterThan(1));
      final Uint8List atFriend = sanitizeIncomingAvatar(sent)!;
      expect(_frames(atFriend), greaterThan(1));

      // The same GIF as the cover.
      final Uint8List cover = makeCoverImage(picked)!;
      expect(_frames(cover), 3);
    },
  );

  test('a camera shot may still be made smaller by the picker: a camera '
      'never makes a GIF', () async {
    await pickProfilePicturePath(camera: true);
    expect(asked.single['source'], 0);
    expect(asked.single['maxWidth'], 1600.0);
  });

  testWidgets('the GIF profile photo moves: in the round avatar of the own '
      'profile and on a friend\'s phone, and on the whole screen', (
    WidgetTester tester,
  ) async {
    final Uint8List framed = (await tester.runAsync<Uint8List?>(() async {
      final String? path = await pickProfilePicturePath(camera: false);
      return makeAvatarImage((File(path!).readAsBytesSync(), null));
    }))!;
    final String staged = (await tester.runAsync(
      () => AvatarSanitizer.validateAndStoreAvatarBytes(
        rawBytes: framed,
        folder: () async => dir,
      ),
    ))!;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ZenBlobAvatar(
            name: 'Ada',
            size: 96,
            image: peerAvatarImage(staged),
          ),
        ),
      ),
    );
    expect(await _framesShown(tester), greaterThan(1));

    final Uint8List atFriend = sanitizeIncomingAvatar(
      makeAvatarThumbnail(framed)!,
    )!;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ZenBlobAvatar(
            name: 'Ada',
            size: 96,
            image: MemoryImage(atFriend),
          ),
        ),
      ),
    );
    expect(await _framesShown(tester), greaterThan(1));

    await tester.pumpWidget(
      MaterialApp(home: ProfilePhotoViewer(image: peerAvatarImage(staged)!)),
    );
    expect(await _framesShown(tester), greaterThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  group('a photo the app cannot read itself (HEIC from the gallery) is read '
      'by the phone\'s decoder', () {
    // The start of a HEIC photo: an ISO box `ftyp` of brand `heic`.
    final Uint8List heic = Uint8List.fromList(<int>[
      0, 0, 0, 24, ...'ftypheic'.codeUnits, 0, 0, 0, 0, //
      ...'mif1heic'.codeUnits, ...List<int>.filled(64, 7),
    ]);
    final Uint8List png = img.encodePng(
      img.fill(
        img.Image(width: 3000, height: 1500),
        color: img.ColorRgb8(200, 30, 30),
      ),
    );

    test('it becomes a valid profile photo and cover', () async {
      int asked = 0;
      final Uint8List ready = await checkPickedPicture(
        heic,
        decode: (Uint8List bytes, {required int maxSide}) async {
          asked++;
          expect(bytes, heic);
          expect(maxSide, 1600);
          return png;
        },
      );
      expect(asked, 1);
      final Uint8List photo = makeAvatarImage((ready, CropRegion.full))!;
      expect(photo.sublist(0, 2), <int>[0xFF, 0xD8]);
      final String staged = await AvatarSanitizer.validateAndStoreAvatarBytes(
        rawBytes: photo,
        folder: () async => dir,
      );
      expect(staged, endsWith('.jpg'));
      expect(img.decodeJpg(File(staged).readAsBytesSync())!.width, kAvatarSide);
      expect(makeCoverImage(ready), isNotNull);
    });

    test('when the phone cannot read it either, the usual message', () async {
      await expectLater(
        checkPickedPicture(
          heic,
          decode: (Uint8List bytes, {required int maxSide}) async => null,
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            t(
              'Nieobsługiwany format pliku. Wybierz obraz JPG, PNG, WEBP lub GIF.',
            ),
          ),
        ),
      );
      // A program is refused before any decoder sees it.
      await expectLater(
        checkPickedPicture(
          Uint8List.fromList(<int>[0x4D, 0x5A, 1, 2, 3, 4]),
          decode: (Uint8List bytes, {required int maxSide}) async =>
              fail('not decoded'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'a GIF, JPEG, PNG or WebP never goes to the phone\'s decoder',
      () async {
        Future<Uint8List?> never(Uint8List b, {required int maxSide}) async =>
            fail('not decoded');
        final Uint8List gif = _gif(20, 10);
        expect(await checkPickedPicture(gif, decode: never), gif);
        final Uint8List apng = _apng(20, 10);
        expect(await checkPickedPicture(apng, decode: never), apng);
      },
    );

    testWidgets('the real decoder of the engine: a picture the app does not '
        'read itself (BMP) comes back a PNG, made smaller', (
      WidgetTester tester,
    ) async {
      final Uint8List bmp = img.encodeBmp(img.Image(width: 400, height: 200));
      final Uint8List? out = await tester.runAsync<Uint8List?>(
        () => decodeWithPlatform(bmp, maxSide: 100),
      );
      final img.Image decoded = img.decodePng(out!)!;
      expect((decoded.width, decoded.height), (100, 50));
      expect(
        await tester.runAsync<Uint8List?>(
          () => decodeWithPlatform(heic, maxSide: 100),
        ),
        isNull,
      );
    });

    test('what posts and comments read it with: the PNG the phone made, '
        'or nothing when that is not a picture either', () async {
      expect(
        await readablePicture(
          heic,
          maxSide: 2048,
          decode: (Uint8List b, {required int maxSide}) async => png,
        ),
        png,
      );
      expect(
        await readablePicture(
          heic,
          decode: (Uint8List b, {required int maxSide}) async => heic,
        ),
        isNull,
      );
      expect(
        await readablePicture(
          heic,
          decode: (Uint8List b, {required int maxSide}) async =>
              throw StateError('no decoder'),
        ),
        isNull,
      );
    });

    testWidgets('a post refuses what no decoder reads with the usual message, '
        'and takes what the phone reads as a fresh JPEG', (
      WidgetTester tester,
    ) async {
      final Object? error = await tester.runAsync<Object?>(() async {
        try {
          await pictureForPost(heic);
          return null;
        } on ArgumentError catch (e) {
          return e;
        }
      });
      expect(error, isA<ArgumentError>());
      final DraftMedia? post = await tester.runAsync(
        () => pictureForPost(img.encodeBmp(img.Image(width: 40, height: 20))),
      );
      expect(post!.mime, 'image/jpeg');
    });
  });

  group('an animated WebP or PNG is made a GIF, not a still', () {
    test('it is told apart from a still picture by its header', () {
      expect(looksLikeAnimatedPicture(_apng(20, 10)), isTrue);
      expect(looksLikeAnimatedPicture(_animatedWebP()), isTrue);
      expect(
        looksLikeAnimatedPicture(img.encodePng(img.Image(width: 4, height: 4))),
        isFalse,
      );
      expect(looksLikeAnimatedPicture(_gif(4, 4)), isFalse);
      expect(
        animatedPictureAsGif(img.encodePng(img.Image(width: 4, height: 4))),
        isNull,
      );
    });

    test('every frame is kept, scaled down', () {
      final Uint8List fromPng = animatedPictureAsGif(_apng(800, 400))!;
      final ({int width, int height, int frames}) shape = gifShape(fromPng)!;
      expect(shape.frames, 3);
      expect(shape.width, kAnimatedPictureGifSide);
      expect(shape.height, kAnimatedPictureGifSide ~/ 2);
      final img.Image decoded = img.decodeGif(fromPng)!;
      expect(decoded.frames[1].getPixel(5, 5).b, greaterThan(200));

      expect(_frames(animatedPictureAsGif(_animatedWebP())!), 2);
    });

    test('one too big to decode safely is refused before decoding', () {
      // 3000 px a side: over the side any GIF may have.
      expect(animatedPictureAsGif(_apng(3000, 4)), isNull);
    });

    test('as the profile photo, the cover and a dating photo', () {
      final Uint8List apng = _apng(300, 200);
      expect(_frames(makeAvatarImage((apng, CropRegion.full))!), 3);
      expect(_frames(makeCoverImage(apng)!), 3);
      expect(_frames(makeAvatarThumbnail(apng)!), greaterThan(1));
    });

    test('in a post, a comment, a dropped or pasted file, an event, a flat '
        'and a food offer', () async {
      final Uint8List apng = _apng(200, 200);
      final DraftMedia post = await pictureForPost(apng);
      expect(post.mime, 'image/gif');
      expect(_frames(post.bytes), 3);

      final CommentPicture comment = await commentPicture(apng);
      expect(comment.mime, 'image/gif');
      expect(_frames(comment.bytes), 3);

      final OutgoingAttachment dropped = (await prepareOutgoing(
        TransferItem(name: 'sticker.png', bytes: apng),
      ))!;
      expect(dropped.kind, OutgoingKind.gif);
      expect(dropped.fileName, 'sticker.gif');
      expect(_frames(dropped.bytes!), 3);

      expect(_frames(compressEventPhoto(apng)!), 3);
      expect(_frames(compressFlatPhoto(apng)!), greaterThan(1));
      // One from another phone is never converted there.
      expect(compressRemoteEventPhoto(apng), isNull);

      // A still PNG is still a fresh JPEG.
      final DraftMedia still = await pictureForPost(
        img.encodePng(img.Image(width: 8, height: 8)),
      );
      expect(still.mime, 'image/jpeg');
    });
  });
}
