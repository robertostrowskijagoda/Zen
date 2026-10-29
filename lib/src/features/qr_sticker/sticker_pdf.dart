import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// A one-page PDF: a page of [widthPt] × [heightPt] points (1/72 inch)
/// with one RGB picture ([rgb], [pixelsWide] × [pixelsHigh], 3 bytes a
/// pixel, rows from the top) placed at [imageLeftPt], [imageTopPt] (from
/// the page's top left), [imageSidePt] square, and thin grey [lines]
/// (pairs of points, also from the top left) for cutting.
///
/// Only what a printer needs: a catalog, the page, its drawing and the
/// picture (Flate-compressed, so the QR code stays sharp), and the cross
/// reference table every reader starts from.
Uint8List buildStickerPdf({
  required double widthPt,
  required double heightPt,
  required Uint8List rgb,
  required int pixelsWide,
  required int pixelsHigh,
  required double imageLeftPt,
  required double imageTopPt,
  required double imageSidePt,
  List<(double, double, double, double)> lines =
      const <(double, double, double, double)>[],
  double lineWidthPt = 0.6,
}) {
  if (rgb.length != pixelsWide * pixelsHigh * 3) {
    throw ArgumentError('The picture is not $pixelsWide × $pixelsHigh RGB');
  }
  final BytesBuilder out = BytesBuilder(copy: false);
  final List<int> offsets = <int>[];
  void raw(String s) => out.add(latin1.encode(s));
  void object(int number, String body, [List<int>? stream]) {
    offsets.add(out.length);
    raw('$number 0 obj\n$body\n');
    if (stream != null) {
      raw('stream\n');
      out.add(stream);
      raw('\nendstream\n');
    }
    raw('endobj\n');
  }

  final String n = _n(widthPt);
  final String h = _n(heightPt);
  final StringBuffer draw = StringBuffer()
    ..write('q\n')
    ..write(
      '${_n(imageSidePt)} 0 0 ${_n(imageSidePt)} ${_n(imageLeftPt)} '
      '${_n(heightPt - imageTopPt - imageSidePt)} cm\n',
    )
    ..write('/Im0 Do\nQ\n');
  if (lines.isNotEmpty) {
    draw.write('q\n0.55 G\n${_n(lineWidthPt)} w\n');
    for (final (double x1, double y1, double x2, double y2) in lines) {
      draw.write(
        '${_n(x1)} ${_n(heightPt - y1)} m ${_n(x2)} ${_n(heightPt - y2)} l S\n',
      );
    }
    draw.write('Q\n');
  }
  final List<int> content = latin1.encode(draw.toString());
  final List<int> picture = ZLibEncoder(level: 6).convert(rgb);

  // The header's second line marks the file as binary for old tools.
  raw('%PDF-1.4\n');
  out.add(<int>[0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $n $h] '
    '/Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>',
  );
  object(4, '<< /Length ${content.length} >>', content);
  object(
    5,
    '<< /Type /XObject /Subtype /Image /Width $pixelsWide '
    '/Height $pixelsHigh /ColorSpace /DeviceRGB /BitsPerComponent 8 '
    '/Interpolate false /Filter /FlateDecode /Length ${picture.length} >>',
    picture,
  );
  object(6, '<< /Title (Zen) /Producer (Zen) >>');
  final int xref = out.length;
  final StringBuffer table = StringBuffer('xref\n0 ${offsets.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (final int offset in offsets) {
    table.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  table
    ..write('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R ')
    ..write('/Info 6 0 R >>\nstartxref\n$xref\n%%EOF\n');
  raw(table.toString());
  return out.takeBytes();
}

/// A PDF number: at most two decimals, no trailing zeros.
String _n(double v) {
  final String s = v.toStringAsFixed(2);
  if (!s.contains('.')) {
    return s;
  }
  final String trimmed = s.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}
