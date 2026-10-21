import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/social/desktop_qr_scanner.dart';
import 'package:zen/src/features/social/qr_frame_decoder.dart';
import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/qrcode.dart';
import 'package:zxing_lib/zxing.dart';

/// A camera picture with [text] as a QR code (dark on light, with margin).
LumaFrame _qrFrame(String text, {int size = 240}) {
  final BitMatrix code = QRCodeWriter().encode(
    text,
    BarcodeFormat.qrCode,
    size,
    size,
  );
  final Uint8List gray = Uint8List(size * size);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      gray[y * size + x] = code.get(x, y) ? 20 : 235;
    }
  }
  return LumaFrame(width: size, height: size, bytes: gray);
}

/// A camera that shows [frame] (or nothing).
final class _FrameCamera implements FilmCamera {
  _FrameCamera(this.frame, {this.hasLens = true});

  final LumaFrame? frame;
  final bool hasLens;
  final List<String> calls = <String>[];

  @override
  Future<List<FilmLens>> lenses() async =>
      hasLens ? <FilmLens>[FilmLens.front] : <FilmLens>[];

  @override
  Future<void> open(FilmLens lens) async => calls.add('open ${lens.name}');

  @override
  bool get hasTorch => false;

  @override
  Future<void> setTorch(bool on) async {}

  @override
  Widget preview() => const SizedBox.expand(key: Key('qr-preview'));

  @override
  Future<void> startRecording() async {}

  @override
  Future<String> stopRecording() async => '';

  @override
  Future<LumaFrame?> lumaFrame() async {
    calls.add('frame');
    return calls.where((String c) => c == 'frame').length < 3 ? null : frame;
  }

  @override
  Future<void> close() async => calls.add('close');
}

Future<List<String?>> _open(WidgetTester tester, FilmCamera camera) async {
  final List<String?> got = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async {
            got.add(
              await Navigator.of(context).push<String>(
                MaterialPageRoute<String>(
                  builder: (_) => DesktopQrScannerPage(
                    camera: camera,
                    decode: (LumaFrame f) async => decodeQrLuma(f),
                    interval: const Duration(milliseconds: 10),
                  ),
                ),
              ),
            );
          },
          child: const Text('scan'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('scan'));
  await tester.pump();
  await tester.pump();
  return got;
}

void main() {
  test('a QR code in a grey camera picture is read', () {
    expect(decodeQrLuma(_qrFrame('zen:invite/abc123')), 'zen:invite/abc123');
    final LumaFrame blank = LumaFrame(
      width: 64,
      height: 64,
      bytes: Uint8List(64 * 64)..fillRange(0, 64 * 64, 200),
    );
    expect(decodeQrLuma(blank), isNull);
    expect(
      decodeQrLuma(LumaFrame(width: 10, height: 10, bytes: Uint8List(5))),
      isNull,
    );
  });

  test('a photo (JPEG or PNG) becomes a grey picture to read', () {
    final LumaFrame frame = _qrFrame('zen-flat:door-7', size: 300);
    final img.Image picture = img.Image(width: 300, height: 300);
    for (int y = 0; y < 300; y++) {
      for (int x = 0; x < 300; x++) {
        final int g = frame.bytes[y * 300 + x];
        picture.setPixelRgb(x, y, g, g, g);
      }
    }
    final LumaFrame back = lumaFromImage(
      Uint8List.fromList(img.encodePng(picture)),
      maxWidth: 250,
    )!;
    expect(back.width, 250);
    expect(decodeQrLuma(back), 'zen-flat:door-7');
    expect(lumaFromImage(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    // A broken JPEG or PNG (only the start of one) is not a picture either.
    expect(
      lumaFromImage(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0])),
      isNull,
    );
    expect(
      lumaFromImage(Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1])),
      isNull,
    );
  });

  testWidgets('the computer scanner reads the camera until a code is found', (
    WidgetTester tester,
  ) async {
    final _FrameCamera camera = _FrameCamera(_qrFrame('zen:ticket/42'));
    final List<String?> got = await _open(tester, camera);
    expect(find.byKey(const Key('qr-preview')), findsOneWidget);
    for (int i = 0; i < 20 && got.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(got, <String?>['zen:ticket/42']);
    expect(camera.calls.first, 'open front');
    expect(camera.calls.last, 'close');
  });

  testWidgets('without a camera a copied code can be pasted', (
    WidgetTester tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': '  zen-home:xyz  '}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final List<String?> got = await _open(
      tester,
      _FrameCamera(null, hasLens: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qr-desktop-no-camera')), findsOneWidget);
    await tester.tap(find.byKey(const Key('qr-desktop-paste-empty')));
    await tester.pumpAndSettle();
    expect(got, <String?>['zen-home:xyz']);
  });
}
