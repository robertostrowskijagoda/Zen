// The QR code of the promo film's end card, and a check that the end card
// as rendered really reads back as that address. Run by make_promo.py:
//
//   flutter test tool/promo/qr_test.dart
//
// The first test writes the code's modules to tool/promo/qr-about.txt
// (one line per row, '#' dark, '.' light, no quiet zone), drawn by
// make_promo.py. The second reads every picture in build/promo/check/
// (the end card frames make_promo.py leaves there) with the same decoder
// the app uses for camera pictures, and fails if one doesn't give the
// address.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// Where the code on the end card leads: the About page of the website.
const String kPromoQrUrl = 'https://robertostrowskijagoda.github.io/Zen/about/';

const String _modulesFile = 'tool/promo/qr-about.txt';
const String _checkDir = 'build/promo/check';

String? _decode(img.Image picture) {
  final img.Image gray = img.grayscale(picture);
  final Int32List pixels = Int32List(gray.width * gray.height);
  int i = 0;
  for (final img.Pixel p in gray) {
    final int g = p.r.toInt();
    pixels[i++] = 0xFF000000 | (g << 16) | (g << 8) | g;
  }
  final LuminanceSource source = RGBLuminanceSource(
    gray.width,
    gray.height,
    pixels,
  );
  for (final Binarizer binarizer in <Binarizer>[
    HybridBinarizer(source),
    GlobalHistogramBinarizer(source),
  ]) {
    try {
      return QRCodeReader().decode(BinaryBitmap(binarizer)).text;
    } on ReaderException {
      // Not readable this way: the next one.
    }
  }
  return null;
}

void main() {
  test('writes the modules of the end card code', () {
    final BitMatrix code = QRCodeWriter().encode(
      kPromoQrUrl,
      BarcodeFormat.qrCode,
      0,
      0,
      const EncodeHint(errorCorrectionLevel: ErrorCorrectionLevel.Q, margin: 0),
    );
    final StringBuffer out = StringBuffer();
    for (int y = 0; y < code.height; y++) {
      for (int x = 0; x < code.width; x++) {
        out.write(code.get(x, y) ? '#' : '.');
      }
      out.writeln();
    }
    File(_modulesFile).writeAsStringSync(out.toString());
    expect(code.width, code.height);
  });

  test('the rendered end cards read back as the address', () {
    final Directory dir = Directory(_checkDir);
    if (!dir.existsSync()) {
      markTestSkipped('nothing rendered in $_checkDir');
      return;
    }
    final List<File> pictures =
        dir
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.png'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    expect(pictures, isNotEmpty);
    for (final File f in pictures) {
      final img.Image? picture = img.decodePng(f.readAsBytesSync());
      expect(picture, isNotNull, reason: f.path);
      expect(_decode(picture!), kPromoQrUrl, reason: f.path);
    }
  });
}
