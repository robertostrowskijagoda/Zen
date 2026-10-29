import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/qr_sticker/qr_matrix.dart';
import 'package:zen/src/features/qr_sticker/zen_qr_code.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/qr_frame_decoder.dart';

/// [code] drawn as a camera would see it on a screen or a sticker: dark
/// modules of [module] pixels on white, a quiet zone of four modules.
LumaFrame _frame(QrImage code, {int module = 4}) {
  final int side = (code.moduleCount + 8) * module;
  final Uint8List bytes = Uint8List(side * side)
    ..fillRange(0, side * side, 255);
  for (int r = 0; r < code.moduleCount; r++) {
    for (int c = 0; c < code.moduleCount; c++) {
      if (!code.isDark(r, c)) {
        continue;
      }
      for (int y = 0; y < module; y++) {
        final int row = (r + 4) * module + y;
        bytes.fillRange(
          row * side + (c + 4) * module,
          row * side + (c + 5) * module,
          0,
        );
      }
    }
  }
  return LumaFrame(width: side, height: side, bytes: bytes);
}

String? _read(String data, {ZenQrMedium medium = ZenQrMedium.print}) =>
    decodeQrLuma(_frame(QrImage(zenQrCode(data, medium: medium))));

const String _ada = '200:1234:5678:9abc:def0:1234:5678:9abc';

void main() {
  test('the capacity table is the standard one the qr package uses', () {
    for (final int level in <int>[
      QrErrorCorrectLevel.L,
      QrErrorCorrectLevel.M,
      QrErrorCorrectLevel.Q,
      QrErrorCorrectLevel.H,
    ]) {
      for (int version = 1; version <= 40; version++) {
        if (!zenQrVersionWorks(version, level)) {
          continue;
        }
        final int count = version <= 9 ? 8 : 16;
        // The most bytes of byte mode that fit, and one more.
        final int fits = (zenQrCapacity(version, level) * 8 - 4 - count) ~/ 8;
        expect(
          // ignore: invalid_use_of_internal_member
          () => (QrCode(version, level)..addData('a' * fits)).dataCache,
          returnsNormally,
          reason: 'v$version level $level',
        );
        expect(
          // ignore: invalid_use_of_internal_member
          () => (QrCode(version, level)..addData('a' * (fits + 1))).dataCache,
          throwsA(isA<InputTooLongException>()),
          reason: 'v$version level $level',
        );
      }
    }
  });

  test('digits go in numeric mode, upper-case codes in alphanumeric, the '
      'rest in bytes; every reader gets the same text back', () {
    final String digits =
        'https://robertostrowskijagoda.github.io/Zen/k/#'
        '${'0123456789' * 19}';
    final List<ZenQrSegment> segments = zenQrSegments(digits, 8);
    expect(segments.map((ZenQrSegment s) => s.mode), <ZenQrMode>[
      ZenQrMode.byte,
      ZenQrMode.numeric,
    ]);
    expect(segments.map((ZenQrSegment s) => s.text).join(), digits);
    for (final String data in <String>[
      digits,
      PeerShareCodec.buildLocalProfile(address: _ada)!.qrData,
      'zen-flat:eyJ2IjozLCJrIjoiQUFBQSJ9',
      'Zażółć gęślą jaźń 123456789012 ABC/DEF',
      'https://robertostrowskijagoda.github.io/Zen/about/',
      '7',
    ]) {
      for (final ZenQrMedium medium in ZenQrMedium.values) {
        expect(_read(data, medium: medium), data, reason: '$medium $data');
      }
      // The sticker matrix is the same code.
      final QrMatrix matrix = QrMatrix.encode(data);
      expect(
        matrix.version,
        zenQrVersion(data, QrErrorCorrectLevel.M),
        reason: data,
      );
    }
  });

  test('the segments never take more bits than plain bytes', () {
    for (final String data in <String>[
      'a',
      '12',
      'A1',
      'https://robertostrowskijagoda.github.io/Zen/#ABCDE12345FGHJK67890MNPQR',
      'zen-home:${'x' * 80}',
    ]) {
      for (final int version in <int>[1, 10, 27]) {
        final int plain = ZenQrSegment(ZenQrMode.byte, data).bits(version);
        expect(zenQrBits(data, version), lessThanOrEqualTo(plain));
      }
    }
  });

  test('on screen L only when it makes the code smaller', () {
    final String invite = PeerShareCodec.buildLocalProfile(
      address: _ada,
    )!.qrData;
    // The invitation link: version 5 printed at M, version 4 on screen.
    expect(zenQrCode(invite).typeNumber, 5);
    final QrCode screen = zenQrCode(invite, medium: ZenQrMedium.screen);
    expect(screen.typeNumber, 4);
    expect(screen.errorCorrectLevel, QrErrorCorrectLevel.L);
    // Where L would not make it smaller: M, at no cost.
    for (final String data in <String>['7', 'https://example.org/']) {
      expect(
        zenQrCode(data, medium: ZenQrMedium.screen).errorCorrectLevel,
        QrErrorCorrectLevel.M,
      );
    }
  });

  test('version 15 at H, which the qr package writes broken, is skipped', () {
    // Just over version 14 at H in bytes.
    final String data = 'a' * 196;
    expect(zenQrVersion(data, QrErrorCorrectLevel.H), 16);
    expect(_read(data, medium: ZenQrMedium.printWithLogo), data);
  });
}
