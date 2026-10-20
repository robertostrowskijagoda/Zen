import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/video_metadata.dart';
import 'package:zen/src/features/media/media_guard.dart';

List<int> _u32(int v) => <int>[
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _box(List<int> type, List<int> payload) => <int>[
  ..._u32(8 + payload.length),
  ...type,
  ...payload,
];

List<int> _t(String type) => ascii.encode(type);

/// ©xyz, the way Android writes the place of recording.
const List<int> _xyz = <int>[0xA9, 0x78, 0x79, 0x7A];

const String _place = '+52.2297+021.0122/';
const String _applePlace = 'com.apple.quicktime.location.ISO6709';
const String _xmp = '<x:xmpmeta><exif:GPSLatitude>52,13N';

const List<int> _xmpUuid = <int>[
  0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, //
  0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
];

/// A small but complete-looking MP4: where and when it was recorded in all
/// the usual places, one chunk of "frames" pointed at by `stco`.
({Uint8List bytes, int mdatPayload, int stcoAt}) _film({
  bool withMetadata = true,
}) {
  final List<int> ftyp = _box(_t('ftyp'), <int>[
    ..._t('isom'),
    ..._u32(512),
    ..._t('isommp41'),
  ]);
  final List<int> mvhd = _box(_t('mvhd'), <int>[
    0, 0, 0, 0, // version 0, flags
    ..._u32(withMetadata ? 0x11111111 : 0), // created
    ..._u32(withMetadata ? 0x22222222 : 0), // modified
    ..._u32(1000), // timescale
    ..._u32(5000), // duration
    ...List<int>.filled(80, 0),
  ]);
  final List<int> tkhd = _box(_t('tkhd'), <int>[
    1, 0, 0, 3, // version 1
    ...<int>[0, 0, 0, 0], ..._u32(withMetadata ? 0x33333333 : 0),
    ...<int>[0, 0, 0, 0], ..._u32(withMetadata ? 0x44444444 : 0),
    ..._u32(1), // track id
    ...List<int>.filled(60, 0),
  ]);
  final List<int> mdhd = _box(_t('mdhd'), <int>[
    0,
    0,
    0,
    0,
    ..._u32(withMetadata ? 0x55555555 : 0),
    ..._u32(withMetadata ? 0x66666666 : 0),
    ..._u32(90000),
    ..._u32(450000),
    0,
    0,
    0,
    0,
  ]);
  // The chunk offset is filled in once the layout is known.
  List<int> stco(int offset) =>
      _box(_t('stco'), <int>[0, 0, 0, 0, ..._u32(1), ..._u32(offset)]);
  List<int> trak(int offset) => _box(_t('trak'), <int>[
    ...tkhd,
    ..._box(_t('mdia'), <int>[
      ...mdhd,
      ..._box(_t('minf'), <int>[..._box(_t('stbl'), stco(offset))]),
    ]),
    if (withMetadata) ..._box(_t('udta'), _box(_xyz, ascii.encode(_place))),
  ]);
  List<int> moov(int offset) => _box(_t('moov'), <int>[
    ...mvhd,
    ...trak(offset),
    if (withMetadata) ...<int>[
      ..._box(_t('udta'), <int>[
        ..._box(_xyz, ascii.encode(_place)),
        ..._box(_t('loci'), ascii.encode('Warszawa')),
      ]),
      ..._box(_t('meta'), <int>[
        0,
        0,
        0,
        0,
        ..._box(_t('keys'), ascii.encode(_applePlace)),
      ]),
    ],
  ]);
  final List<int> uuid = withMetadata
      ? _box(_t('uuid'), <int>[..._xmpUuid, ...ascii.encode(_xmp)])
      : const <int>[];
  final List<int> frames = ascii.encode('FRAMEDATA-FRAMEDATA');
  final int moovLength = moov(0).length;
  final int mdatPayload = ftyp.length + moovLength + uuid.length + 8;
  final List<int> all = <int>[
    ...ftyp,
    ...moov(mdatPayload),
    ...uuid,
    ..._box(_t('mdat'), frames),
  ];
  final Uint8List bytes = Uint8List.fromList(all);
  return (
    bytes: bytes,
    mdatPayload: mdatPayload,
    stcoAt: _indexOf(bytes, _t('stco')) + 4 + 4 + 4,
  );
}

int _indexOf(List<int> haystack, List<int> needle, [int from = 0]) {
  outer:
  for (int i = from; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        continue outer;
      }
    }
    return i;
  }
  return -1;
}

int _count(List<int> haystack, List<int> needle) {
  int n = 0;
  int at = _indexOf(haystack, needle);
  while (at >= 0) {
    n++;
    at = _indexOf(haystack, needle, at + 1);
  }
  return n;
}

int _readU32(Uint8List b, int at) => ByteData.sublistView(b).getUint32(at);

void main() {
  test('the place, the dates and XMP are gone; the film is intact', () {
    final ({Uint8List bytes, int mdatPayload, int stcoAt}) film = _film();
    expect(looksLikeSafeContainer(film.bytes), isTrue);
    expect(_indexOf(film.bytes, ascii.encode(_place)), greaterThan(0));

    final Uint8List out = stripVideoMetadata(film.bytes);

    // Nothing moved: same length, the frames and their offset as they were.
    expect(out.length, film.bytes.length);
    expect(
      out.sublist(film.mdatPayload, film.mdatPayload + 19),
      ascii.encode('FRAMEDATA-FRAMEDATA'),
    );
    expect(_readU32(out, film.stcoAt), film.mdatPayload);
    // The metadata is not there any more, in any form.
    for (final String secret in <String>[
      _place,
      _applePlace,
      _xmp,
      'Warszawa',
    ]) {
      expect(_indexOf(out, ascii.encode(secret)), -1, reason: secret);
    }
    expect(_indexOf(out, _xyz), -1);
    expect(_indexOf(out, _t('udta')), -1);
    expect(_indexOf(out, _t('meta')), -1);
    // moov/udta, trak/udta, moov/meta and the XMP uuid became free space.
    expect(_count(out, _t('free')), 4);
    // Recording times are "unknown" now; the rest of the headers stays.
    final int mvhd = _indexOf(out, _t('mvhd')) + 4;
    expect(_readU32(out, mvhd + 4), 0);
    expect(_readU32(out, mvhd + 8), 0);
    expect(_readU32(out, mvhd + 12), 1000);
    final int tkhd = _indexOf(out, _t('tkhd')) + 4;
    expect(out.sublist(tkhd + 4, tkhd + 20), List<int>.filled(16, 0));
    expect(_readU32(out, tkhd + 20), 1);
    final int mdhd = _indexOf(out, _t('mdhd')) + 4;
    expect(_readU32(out, mdhd + 4), 0);
    expect(_readU32(out, mdhd + 12), 90000);
    // Still a film the guard lets through.
    expect(looksLikeSafeContainer(out), isTrue);
    expect(sniffMediaKind(out), MediaKind.video);
    // The input was not touched.
    expect(_indexOf(film.bytes, ascii.encode(_place)), greaterThan(0));
  });

  test('a film without metadata comes back as it is', () {
    final Uint8List clean = _film(withMetadata: false).bytes;
    expect(identical(stripVideoMetadata(clean), clean), isTrue);
  });

  test('anything that is not MP4 / MOV is left alone', () {
    final Uint8List webm = Uint8List.fromList(<int>[
      0x1A,
      0x45,
      0xDF,
      0xA3,
      ...ascii.encode('webm and more bytes'),
    ]);
    expect(isIsoMediaFile(webm), isFalse);
    expect(identical(stripVideoMetadata(webm), webm), isTrue);
    final Uint8List tiny = Uint8List.fromList(<int>[1, 2, 3]);
    expect(identical(stripVideoMetadata(tiny), tiny), isTrue);
  });

  test('a broken file does not throw', () {
    final Uint8List film = _film().bytes;
    // Cut in the middle of moov: the rest is left as it is.
    final Uint8List cut = Uint8List.sublistView(film, 0, film.length ~/ 2);
    expect(() => stripVideoMetadata(cut), returnsNormally);
    // A box claiming to be huge.
    final Uint8List liar = Uint8List.fromList(film);
    ByteData.sublistView(liar).setUint32(film.length - 27, 0x7FFFFFFF);
    expect(() => stripVideoMetadata(liar), returnsNormally);
    // A 64-bit box size.
    final Uint8List big = Uint8List.fromList(<int>[
      ..._box(_t('ftyp'), _t('isom')),
      ..._u32(1),
      ..._t('udta'),
      ..._u32(0),
      ..._u32(16 + 5),
      ...ascii.encode('Paris'),
    ]);
    final Uint8List out = stripVideoMetadata(big);
    expect(_indexOf(out, ascii.encode('Paris')), -1);
    expect(_indexOf(out, _t('free')), greaterThan(0));
  });

  test('posts store films without metadata, photos as they are', () async {
    final BlobStore blobs = BlobStore();
    final Uint8List film = _film().bytes;
    final MediaRef? video = mediaRefFromJson(
      await storeMedia(blobs, film, mime: 'video/mp4', stripMetadata: true),
    );
    final Uint8List? stored = await openMedia(blobs, video!);
    expect(stored!.length, film.length);
    expect(_indexOf(stored, ascii.encode(_place)), -1);

    // Without asking (chat copies between own devices) nothing changes.
    final MediaRef? kept = mediaRefFromJson(
      await storeMedia(blobs, film, mime: 'video/mp4'),
    );
    expect(await openMedia(blobs, kept!), film);
  });
}
