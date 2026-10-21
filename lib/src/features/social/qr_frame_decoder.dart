import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

// Reading QR codes from camera pictures on computers, where the scanner of
// qr_code_dart_scan has no camera: the picture comes from the recorder's
// camera (camera_windows, ZenCameraBridge on macOS, GStreamer on Linux) in
// shades of grey and ZXing (the same decoder qr_code_dart_scan uses) reads
// it here.

/// The text of the QR code in [frame], or null when there is none (or it
/// cannot be read yet: out of focus, too far).
String? decodeQrLuma(LumaFrame frame) {
  if (!frame.isComplete) {
    return null;
  }
  final int count = frame.width * frame.height;
  final Int32List pixels = Int32List(count);
  for (int i = 0; i < count; i++) {
    final int g = frame.bytes[i];
    pixels[i] = 0xFF000000 | (g << 16) | (g << 8) | g;
  }
  final LuminanceSource source = RGBLuminanceSource(
    frame.width,
    frame.height,
    pixels,
  );
  for (final Binarizer binarizer in <Binarizer>[
    HybridBinarizer(source),
    GlobalHistogramBinarizer(source),
  ]) {
    try {
      final String text = QRCodeReader()
          .decode(BinaryBitmap(binarizer))
          .text
          .trim();
      if (text.isNotEmpty) {
        return text;
      }
    } on ReaderException {
      // Not found here (or not readable): the next way, or the next picture.
    }
  }
  return null;
}

/// [decodeQrLuma] off the UI thread.
Future<String?> decodeQrLumaInBackground(LumaFrame frame) =>
    Isolate.run(() => decodeQrLuma(frame));

/// [encoded] (a JPEG or PNG photo) in shades of grey, at most [maxWidth]
/// pixels wide; null when it is not a JPEG or PNG picture (or a broken
/// one).
LumaFrame? lumaFromImage(Uint8List encoded, {int maxWidth = 800}) {
  img.Image? image;
  try {
    // Only the two formats a camera gives: no guessing among every format
    // the image package knows (some of its decoders throw on junk).
    if (_startsWith(encoded, const <int>[0xFF, 0xD8, 0xFF])) {
      image = img.decodeJpg(encoded);
    } else if (_startsWith(encoded, const <int>[0x89, 0x50, 0x4E, 0x47])) {
      image = img.decodePng(encoded);
    }
  } on Object {
    image = null;
  }
  if (image == null) {
    return null;
  }
  if (image.width > maxWidth) {
    image = img.copyResize(image, width: maxWidth);
  }
  final Uint8List rgb = image.getBytes(order: img.ChannelOrder.rgb);
  final int count = image.width * image.height;
  final Uint8List gray = Uint8List(count);
  for (int i = 0; i < count; i++) {
    gray[i] =
        (rgb[3 * i] * 77 + rgb[3 * i + 1] * 150 + rgb[3 * i + 2] * 29) >> 8;
  }
  return LumaFrame(width: image.width, height: image.height, bytes: gray);
}

bool _startsWith(Uint8List bytes, List<int> magic) {
  if (bytes.length < magic.length) {
    return false;
  }
  for (int i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) {
      return false;
    }
  }
  return true;
}
