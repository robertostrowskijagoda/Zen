import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/media/heif_metadata.dart';
import 'package:zen/src/features/media/outgoing_media.dart';

// A HEIC/AVIF photo the phone cannot decode (Windows, Linux, Android before
// 9) leaves without its EXIF and XMP: their bytes are blanked in place, the
// picture's own bytes and every offset stay. A picture whose boxes are not
// understood is not cleaned (null), and nothing a hostile file holds makes
// the walk throw or hang. Seeded (ZEN_FUZZ_SEED), ZEN_FUZZ_FRAMES=20000
// tries more.

final int _seed =
    int.tryParse(Platform.environment['ZEN_FUZZ_SEED'] ?? '') ?? 20261117;
final int _frames =
    int.tryParse(Platform.environment['ZEN_FUZZ_FRAMES'] ?? '') ?? 1500;

/// A 16 × 16 HEIC written by libheif (x265), with an EXIF item (make,
/// model, date and GPS 52°13'47"N 21°0'44"E, made up for the test) and an
/// XMP item with the same place. Its items (`iloc`): the picture at 555
/// (90 bytes), the EXIF at 645 (226), the XMP at 871 (314), to the end.
Uint8List _sample() =>
    File('test/fixtures/media/gps_photo.heic').readAsBytesSync();

const String _gps = 'GPSLatitude 52.2297';
const String _model = 'Pixel 9';

bool _has(Uint8List bytes, String text) =>
    latin1.decode(bytes, allowInvalid: true).contains(text);

List<int> _u16(int v) => <int>[(v >> 8) & 0xFF, v & 0xFF];

List<int> _u32(int v) => <int>[
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _box(String type, List<int> body) => <int>[
  ..._u32(8 + body.length),
  ...latin1.encode(type),
  ...body,
];

List<int> _full(int version, List<int> body) => <int>[
  version,
  0,
  0,
  0,
  ...body,
];

/// A still picture built by hand: ftyp, meta (hdlr, iinf, iloc, idat when
/// the EXIF is kept there), mdat with the coded picture, the EXIF and the
/// XMP. The arguments make it into what a reader must not trust.
Uint8List _heif({
  String brand = 'heic',
  String handler = 'pict',
  int infeVersion = 2,
  int ilocVersion = 1,
  bool exifInIdat = false,
  int exifReference = 0,
  int? exifMethod,
  int? exifLength,
  int? exifOffset,
  int exifExtents = 1,
  List<int> extraMeta = const <int>[],
  List<int> extraTop = const <int>[],
}) {
  final List<int> picture = List<int>.filled(32, 0x5A);
  final List<int> exif = <int>[
    0, 0, 0, 6, ...latin1.encode('Exif'), 0, 0, //
    ...latin1.encode('MM'), 0, 42, 0, 0, 0, 8,
    ...latin1.encode('$_model $_gps'),
  ];
  final List<int> xmp = latin1.encode(
    '<x:xmpmeta><rdf:Description exif:$_gps/></x:xmpmeta>',
  );
  List<int> id(int v) => infeVersion == 3 ? _u32(v) : _u16(v);
  List<int> infe(int item, String type, [List<int> rest = const <int>[]]) =>
      _box(
        'infe',
        _full(infeVersion, <int>[
          ...id(item),
          0, 0, //
          ...latin1.encode(type),
          0, // no name
          ...rest,
        ]),
      );
  List<int> meta(int mdatBody) {
    final int exifAt = exifOffset ?? mdatBody + picture.length;
    final int xmpAt =
        mdatBody + picture.length + (exifInIdat ? 0 : exif.length);
    List<int> entry(
      int item,
      int method,
      int reference,
      int at,
      int length, [
      int extents = 1,
    ]) => <int>[
      ...(ilocVersion == 2 ? _u32(item) : _u16(item)),
      if (ilocVersion != 0) ..._u16(method),
      ..._u16(reference),
      ..._u32(0), // base offset
      ..._u16(extents),
      for (int e = 0; e < extents; e++) ...<int>[..._u32(at), ..._u32(length)],
    ];
    return _box(
      'meta',
      _full(0, <int>[
        ..._box(
          'hdlr',
          _full(0, <int>[
            0,
            0,
            0,
            0,
            ...latin1.encode(handler),
            ...List<int>.filled(12, 0),
            0,
          ]),
        ),
        ..._box('pitm', _full(0, _u16(1))),
        ..._box(
          'iinf',
          _full(0, <int>[
            ..._u16(3),
            ...infe(1, brand == 'avif' ? 'av01' : 'hvc1'),
            ...infe(2, 'Exif'),
            ...infe(3, 'mime', latin1.encode('application/rdf+xml\u0000')),
          ]),
        ),
        ..._box(
          'iloc',
          _full(ilocVersion, <int>[
            0x44, 0x40, //
            ...(ilocVersion == 2 ? _u32(3) : _u16(3)),
            ...entry(1, 0, 0, mdatBody, picture.length),
            ...entry(
              2,
              exifMethod ?? (exifInIdat ? 1 : 0),
              exifReference,
              exifInIdat ? 0 : exifAt,
              exifLength ?? exif.length,
              exifExtents,
            ),
            ...entry(3, 0, 0, xmpAt, xmp.length),
          ]),
        ),
        if (exifInIdat) ..._box('idat', exif),
        ...extraMeta,
      ]),
    );
  }

  final List<int> ftyp = _box('ftyp', <int>[
    ...latin1.encode(brand),
    0, 0, 0, 0, //
    ...latin1.encode('mif1$brand'),
  ]);
  final int mdatBody = ftyp.length + meta(0).length + extraTop.length + 8;
  return Uint8List.fromList(<int>[
    ...ftyp,
    ...meta(mdatBody),
    ...extraTop,
    ..._box('mdat', <int>[...picture, if (!exifInIdat) ...exif, ...xmp]),
  ]);
}

/// [clean] is [original] overwritten in place: as long, and its boxes
/// still read (a second pass does not give up on them).
void _inPlace(Uint8List original, Uint8List clean, {String? reason}) {
  expect(clean.length, original.length, reason: reason);
  expect(stripHeifMetadata(clean), isNotNull, reason: reason);
}

/// The coded picture of [_heif], which must come out as it went in.
final String _picture = 'Z' * 32;

void main() {
  group('a real HEIC with GPS', () {
    test('comes out without its EXIF and XMP, the picture untouched', () {
      final Uint8List heic = _sample();
      expect(_has(heic, 'ZenFixtureModel'), isTrue);
      expect(_has(heic, 'GPSLatitude'), isTrue);
      expect(_has(heic, 'MM\u0000*'), isTrue, reason: 'the EXIF TIFF header');

      final Uint8List clean = stripHeifMetadata(heic)!;
      expect(_has(clean, 'ZenFixture'), isFalse);
      expect(_has(clean, 'GPS'), isFalse);
      expect(clean.length, heic.length, reason: 'nothing moves');
      // Everything up to the end of the coded picture is as it was. The
      // EXIF item is now one with no entries, then zeros; the XMP an empty
      // packet, then spaces.
      expect(clean.sublist(0, 645), heic.sublist(0, 645));
      expect(
        latin1.decode(clean.sublist(645, 669)),
        '\u0000\u0000\u0000\u0006Exif\u0000\u0000'
        'MM\u0000*\u0000\u0000\u0000\u0008'
        '\u0000\u0000\u0000\u0000\u0000\u0000',
      );
      expect(clean.sublist(669, 871).every((int b) => b == 0), isTrue);
      expect(
        latin1.decode(clean.sublist(871)).trimRight(),
        '<x:xmpmeta xmlns:x="adobe:ns:meta/"/>',
      );
    });

    test('still parses: a second pass finds nothing left to overwrite', () {
      final Uint8List clean = stripHeifMetadata(_sample())!;
      expect(identical(stripHeifMetadata(clean), clean), isTrue);
    });

    test('the send path cleans it too (stripOutgoingMetadata)', () {
      final Uint8List heic = _sample();
      expect(canStripMetadata(heic), isTrue);
      final Uint8List clean = stripOutgoingMetadata(heic);
      expect(_has(clean, 'GPS'), isFalse);
      expect(clean.sublist(0, 645), heic.sublist(0, 645));
    });
  });

  group('built pictures', () {
    test('EXIF in mdat and XMP, every iloc and infe version', () {
      for (final int iloc in <int>[0, 1, 2]) {
        for (final int infe in <int>[2, 3]) {
          final Uint8List heif = _heif(ilocVersion: iloc, infeVersion: infe);
          final Uint8List clean = stripHeifMetadata(heif)!;
          final String reason = 'iloc $iloc, infe $infe';
          expect(_has(clean, _gps), isFalse, reason: reason);
          expect(_has(clean, _model), isFalse, reason: reason);
          expect(_has(clean, _picture), isTrue, reason: reason);
          _inPlace(heif, clean, reason: reason);
          expect(identical(stripHeifMetadata(clean), clean), isTrue);
        }
      }
    });

    test('an AVIF with its EXIF in idat and XML in the meta box', () {
      final Uint8List avif = _heif(
        brand: 'avif',
        exifInIdat: true,
        extraMeta: _box('xml ', _full(0, latin1.encode('<x>$_gps</x>\u0000'))),
      );
      final Uint8List clean = stripHeifMetadata(avif)!;
      expect(_has(clean, _gps), isFalse);
      expect(_has(clean, _model), isFalse);
      expect(_has(clean, 'idat'), isTrue, reason: 'boxes stay');
      _inPlace(avif, clean);
      expect(identical(stripHeifMetadata(clean), clean), isTrue);
    });

    test('a picture without metadata is the same object', () {
      final Uint8List heif = stripHeifMetadata(_heif())!;
      expect(identical(stripHeifMetadata(heif), heif), isTrue);
    });

    test('what is not understood is not cleaned (null)', () {
      final Map<String, Uint8List> odd = <String, Uint8List>{
        'a moov (a sequence)': _heif(extraTop: _box('moov', <int>[])),
        'a uuid at the top': _heif(
          extraTop: _box('uuid', List<int>.filled(16, 1)),
        ),
        'a second meta': _heif(extraTop: _box('meta', _full(0, <int>[]))),
        'not a picture handler': _heif(handler: 'vide'),
        'infe of the old form': _heif(infeVersion: 1),
        'EXIF from another item': _heif(exifMethod: 2),
        'EXIF in another file': _heif(exifReference: 1),
        'EXIF in idat with no idat': _heif(exifMethod: 1),
        'EXIF to an unknown end': _heif(exifLength: 0),
        'EXIF past the end': _heif(exifLength: 1 << 20),
        'EXIF over the ftyp': _heif(exifOffset: 0),
        'EXIF over the meta box': _heif(exifOffset: 40),
        'EXIF listed twice the file': _heif(exifExtents: 60),
        'no ftyp': Uint8List.fromList(_box('meta', _full(0, <int>[]))),
        'empty': Uint8List(0),
      };
      for (final MapEntry<String, Uint8List> e in odd.entries) {
        expect(stripHeifMetadata(e.value), isNull, reason: e.key);
        // The send path then keeps it as it is (the attach flow warns).
        expect(identical(stripOutgoingMetadata(e.value), e.value), isTrue);
      }
    });
  });

  group('hostile boxes', () {
    test('every cut of the real picture reads without throwing', () {
      final Uint8List heic = _sample();
      for (int length = 0; length < heic.length; length++) {
        final Uint8List cut = Uint8List.sublistView(heic, 0, length);
        final Uint8List? clean = stripHeifMetadata(cut);
        if (clean != null) {
          _inPlace(cut, clean, reason: 'cut at $length');
        }
      }
    });

    test('huge counts and sizes end at once', () {
      final Stopwatch watch = Stopwatch()..start();
      // The EXIF listed 65535 times over (far more than the file), an
      // iloc whose extents take no bytes at all, and one that claims more
      // items than it holds.
      expect(stripHeifMetadata(_heif(exifExtents: 65535)), isNull);
      final Uint8List base = _heif();
      final int iloc = _find(base, 'iloc') + 4;
      final Uint8List noSizes = Uint8List.fromList(base);
      noSizes[iloc + 4] = 0x00; // offset and length sizes 0
      final Uint8List? clean = stripHeifMetadata(noSizes);
      if (clean != null) {
        _inPlace(noSizes, clean);
      }
      final Uint8List manyItems = Uint8List.fromList(base);
      manyItems.setRange(iloc + 6, iloc + 8, <int>[0xFF, 0xFF]);
      expect(stripHeifMetadata(manyItems), isNull);
      // A box of 64-bit size beyond any file, one of size 0 at the top,
      // 70 000 boxes of nothing.
      expect(
        stripHeifMetadata(
          Uint8List.fromList(<int>[
            ..._box('ftyp', latin1.encode('heicmif1')),
            ..._u32(1),
            ...latin1.encode('mdat'),
            ..._u32(1),
            ..._u32(0),
          ]),
        ),
        isNull,
      );
      expect(
        stripHeifMetadata(
          Uint8List.fromList(<int>[
            ..._box('ftyp', latin1.encode('heicmif1')),
            ..._u32(0),
            ...latin1.encode('mdat'),
          ]),
        ),
        isNull,
        reason: 'no meta box',
      );
      expect(
        stripHeifMetadata(
          Uint8List.fromList(<int>[
            ..._box('ftyp', latin1.encode('heicmif1')),
            for (int i = 0; i < 70000; i++) ..._box('free', <int>[]),
          ]),
        ),
        isNull,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('random damage never throws, and only ever blanks', () {
      final Random random = Random(_seed);
      final List<Uint8List> seeds = <Uint8List>[
        _sample(),
        _heif(),
        _heif(brand: 'avif', exifInIdat: true, ilocVersion: 2),
        _heif(infeVersion: 3, ilocVersion: 0),
      ];
      const List<int> sharp = <int>[0, 1, 2, 4, 8, 0x7F, 0x80, 0xFF];
      for (int frame = 0; frame < _frames; frame++) {
        final Uint8List bytes = Uint8List.fromList(
          seeds[random.nextInt(seeds.length)],
        );
        final int changes = 1 + random.nextInt(6);
        for (int c = 0; c < changes; c++) {
          final int at = random.nextInt(bytes.length);
          bytes[at] = random.nextBool()
              ? sharp[random.nextInt(sharp.length)]
              : random.nextInt(256);
        }
        final Uint8List input = random.nextInt(5) == 0
            ? Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length))
            : bytes;
        final Uint8List? clean = stripHeifMetadata(input);
        if (clean != null) {
          _inPlace(input, clean, reason: 'seed $_seed frame $frame');
        }
      }
    });
  });
}

int _find(Uint8List bytes, String type) {
  final List<int> want = latin1.encode(type);
  for (int i = 0; i + want.length <= bytes.length; i++) {
    bool same = true;
    for (int j = 0; j < want.length && same; j++) {
      same = bytes[i + j] == want[j];
    }
    if (same) {
      return i;
    }
  }
  throw StateError('no $type');
}
