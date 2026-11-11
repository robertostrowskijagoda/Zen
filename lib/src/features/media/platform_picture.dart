import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

// A photo picked on this phone in a format the pure-Dart decoder does not
// know (HEIC/HEIF, the default of iPhones and of many Android cameras set
// to "high efficiency"; AVIF) is read by the phone's own decoder instead,
// once, and continues as a PNG of its first frame: from there it is
// re-encoded like any photo, so nothing but pixels is kept. The phone's
// decoder sees only what the person picked on their own phone; pictures
// from other phones never come here (`media_guard.dart` keeps them away
// from it).

/// Decodes a picture with the platform and returns a PNG of its first
/// frame at most `maxSide` px a side, or `null` when it cannot.
typedef PlatformPictureDecoder =
    Future<Uint8List?> Function(Uint8List bytes, {required int maxSide});

/// The longest side of a picture the phone's decoder hands over (what the
/// photo picker made of a picture before).
const int kPlatformPictureSide = 1600;

/// The most pixels the header of a picture may claim to be decoded by the
/// phone (it is decoded at the smaller size straight away).
const int _maxPlatformPicturePixels = 200 * 1000 * 1000;

/// Whether [b] starts like a picture this app decodes itself: JPEG, PNG
/// (an animated one too), GIF or WebP.
bool isOwnDecodablePicture(Uint8List b) =>
    (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ||
    (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) ||
    (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) ||
    (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50);

/// [bytes] as they are when this app decodes them itself
/// ([isOwnDecodablePicture]: an animated GIF, WebP or PNG stays animated);
/// otherwise a PNG of the first frame made by [decode] (the phone's own
/// decoder), at most [maxSide] a side; `null` when neither can read it.
Future<Uint8List?> readablePicture(
  Uint8List bytes, {
  int maxSide = kPlatformPictureSide,
  PlatformPictureDecoder decode = decodeWithPlatform,
}) async {
  if (isOwnDecodablePicture(bytes)) {
    return bytes;
  }
  try {
    final Uint8List? png = await decode(bytes, maxSide: maxSide);
    return png != null && isOwnDecodablePicture(png) ? png : null;
  } on Object {
    return null;
  }
}

/// The first frame of [bytes] decoded by the engine's image decoder (which
/// uses the platform's: HEIF on Android 9+, iOS and macOS), scaled to at
/// most [maxSide] a side while it is decoded, as a PNG; `null` when the
/// platform cannot read it. The decoding and the PNG run on the engine's
/// own threads, not the UI thread.
Future<Uint8List?> decodeWithPlatform(
  Uint8List bytes, {
  required int maxSide,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final int w = descriptor.width;
    final int h = descriptor.height;
    if (w <= 0 || h <= 0 || w * h > _maxPlatformPicturePixels) {
      return null;
    }
    final double scale = math.min(1, maxSide / math.max(w, h));
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (w * scale).round()),
      targetHeight: math.max(1, (h * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } on Object {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
