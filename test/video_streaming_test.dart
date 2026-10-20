import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_stream_server.dart';
import 'package:zen/src/features/media/video_faststart.dart';

List<int> _u32(int v) => <int>[
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _box(String type, List<int> payload) => <int>[
  ..._u32(8 + payload.length),
  ...ascii.encode(type),
  ...payload,
];

const String _frames = 'FRAMEDATA-FRAMEDATA';

/// An MP4 the way phones write it: the frames first, `moov` (with one
/// chunk offset pointing at them) at the end.
Uint8List _slowFilm({int padding = 0}) {
  final List<int> ftyp = _box('ftyp', <int>[
    ...ascii.encode('isom'),
    ..._u32(512),
    ...ascii.encode('isommp41'),
  ]);
  final List<int> mdat = _box('mdat', <int>[
    ...ascii.encode(_frames),
    ...List<int>.filled(padding, 7),
  ]);
  final int framesAt = ftyp.length + 8;
  final List<int> moov = _box('moov', <int>[
    ..._box('mvhd', List<int>.filled(100, 0)),
    ..._box('trak', <int>[
      ..._box('mdia', <int>[
        ..._box('minf', <int>[
          ..._box('stbl', <int>[
            ..._box('stco', <int>[0, 0, 0, 0, ..._u32(1), ..._u32(framesAt)]),
          ]),
        ]),
      ]),
    ]),
  ]);
  return Uint8List.fromList(<int>[...ftyp, ...mdat, ...moov]);
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        continue outer;
      }
    }
    return i;
  }
  return -1;
}

/// A film held in memory, served as it is.
final class _MemoryFilm implements StreamedMedia {
  _MemoryFilm(this.bytes);

  final Uint8List bytes;

  @override
  int? get length => bytes.length;

  @override
  int get segmentBytes => 64;

  @override
  String get contentType => 'video/mp4';

  @override
  Future<Uint8List?> segment(int index) async {
    final int from = index * segmentBytes;
    return Uint8List.sublistView(
      bytes,
      from,
      from + segmentBytes > bytes.length ? bytes.length : from + segmentBytes,
    );
  }
}

void main() {
  test(
    'fast start: a crafted file with deeply nested boxes is left as it is',
    () {
      List<int> nest(int depth) => depth == 0
          ? _box('stco', <int>[0, 0, 0, 0, ..._u32(1), ..._u32(40)])
          : _box('trak', nest(depth - 1));
      final List<int> ftyp = _box('ftyp', <int>[
        ...ascii.encode('isom'),
        ..._u32(512),
      ]);
      final List<int> mdat = _box('mdat', <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final List<int> moov = _box('moov', nest(2000));
      final Uint8List deep = Uint8List.fromList(<int>[
        ...ftyp,
        ...mdat,
        ...moov,
      ]);
      expect(identical(moveMoovToFront(deep), deep), isTrue);

      // The same shape at a real depth is moved.
      final Uint8List shallow = Uint8List.fromList(<int>[
        ...ftyp,
        ...mdat,
        ..._box('moov', nest(3)),
      ]);
      expect(identical(moveMoovToFront(shallow), shallow), isFalse);
    },
  );

  test('fast start: moov goes goes before the frames, offsets follow', () {
    final Uint8List slow = _slowFilm();
    final Uint8List fast = moveMoovToFront(slow);
    expect(fast.length, slow.length);
    final int moovAt = _indexOf(fast, ascii.encode('moov'));
    final int mdatAt = _indexOf(fast, ascii.encode('mdat'));
    expect(moovAt, lessThan(mdatAt));
    final int stco = _indexOf(fast, ascii.encode('stco'));
    final int offset = ByteData.sublistView(fast).getUint32(stco + 4 + 8);
    expect(
      ascii.decode(fast.sublist(offset, offset + _frames.length)),
      _frames,
    );
    expect(looksLikeSafeContainer(fast), isTrue);
    // Already fast, or not a film: left as it is.
    expect(identical(moveMoovToFront(fast), fast), isTrue);
    final Uint8List other = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    expect(identical(moveMoovToFront(other), other), isTrue);
  });

  test('a film is sealed piece by piece; each piece opens by itself', () async {
    final BlobStore sender = BlobStore();
    final Uint8List film = moveMoovToFront(
      _slowFilm(padding: kBlobChunkSize * 2 + 1000),
    );
    final MediaRef ref = mediaRefFromJson(
      await storeMedia(sender, film, mime: 'video/mp4', stripMetadata: true),
    )!;
    expect(await openMedia(sender, ref), film);
    expect(mediaPlainLength(sender, ref), film.length);
    expect(sender.manifest(ref.id)!.chunks, hasLength(3));

    // Another phone with only the manifest and the first piece so far.
    final BlobStore receiver = BlobStore()..want(ref.id);
    expect(await openStreamableStart(receiver, ref), isNull);
    expect(
      receiver.acceptManifest(ref.id, sender.manifest(ref.id)!.toJson()),
      isTrue,
    );
    final String first = sender.manifest(ref.id)!.chunks.first;
    expect(
      await receiver.acceptChunk(first, (await sender.chunk(first))!),
      isTrue,
    );
    expect(await openMedia(receiver, ref), isNull, reason: 'not complete');
    final Uint8List head = (await openStreamableStart(receiver, ref))!;
    expect(head, film.sublist(0, kMediaSegmentBytes));
    expect(await openMediaSegment(receiver, ref, 1), isNull);

    // A wrong key never plays.
    final MediaRef wrong = MediaRef(
      id: ref.id,
      key: randomBytes(32),
      nonce: ref.nonce,
      mime: ref.mime,
    );
    await expectLater(
      openStreamableStart(receiver, wrong),
      throwsA(isA<UnsafeMediaException>()),
    );
  });

  test('the stream start check', () {
    final Uint8List fast = moveMoovToFront(_slowFilm(padding: 5000));
    final Uint8List head = fast.sublist(0, 400);
    expect(looksLikeSafeStreamStart(head, fast.length), isTrue);
    expect(looksLikeSafeStreamStart(head, 300), isFalse);
    expect(looksLikeSafeStreamStart(randomBytes(400), 5000), isFalse);
  });

  test(
    'every segment of a streamed film is checked, not only the first',
    () async {
      final BlobStore sender = BlobStore();
      // `free` runs on into the second segment, where a box with an
      // unprintable name starts.
      final List<int> ftyp = _box('ftyp', <int>[
        ...ascii.encode('isom'),
        ..._u32(512),
        0,
        0,
        0,
        0,
      ]);
      final int freeSize = kMediaSegmentBytes + 10 - ftyp.length;
      final List<int> film = <int>[
        ...ftyp,
        ..._box('free', List<int>.filled(freeSize - 8, 0)),
        ..._u32(1000),
        1,
        2,
        3,
        4,
        ...List<int>.filled(kMediaSegmentBytes - 10 - 8, 9),
      ];
      expect(film.length, 2 * kMediaSegmentBytes);
      final MediaRef ref = mediaRefFromJson(
        await storeMedia(sender, Uint8List.fromList(film), mime: 'video/mp4'),
      )!;
      bool reported = false;
      final BlobMediaStream stream = BlobMediaStream(
        sender,
        ref,
        onUnsafe: () => reported = true,
      );
      expect(await stream.segment(0), isNotNull);
      expect(reported, isFalse);
      await expectLater(
        stream.segment(1),
        throwsA(isA<UnsafeMediaException>()),
      );
      expect(reported, isTrue);
      // Once bad, always bad.
      await expectLater(
        stream.segment(0),
        throwsA(isA<UnsafeMediaException>()),
      );

      // A good film passes segment after segment.
      final Uint8List good = moveMoovToFront(
        _slowFilm(padding: kBlobChunkSize + 500),
      );
      final MediaRef goodRef = mediaRefFromJson(
        await storeMedia(sender, good, mime: 'video/mp4'),
      )!;
      final BlobMediaStream fine = BlobMediaStream(sender, goodRef);
      expect(await fine.segment(1), isNotNull);
      expect(await fine.segment(0), isNotNull);
    },
  );

  test('a segment that does not open stops the film on the server', () async {
    final BlobStore sender = BlobStore();
    final Uint8List good = moveMoovToFront(
      _slowFilm(padding: kBlobChunkSize + 500),
    );
    final MediaRef ref = mediaRefFromJson(
      await storeMedia(sender, good, mime: 'video/mp4'),
    )!;
    final MediaRef wrong = MediaRef(
      id: ref.id,
      key: randomBytes(32),
      nonce: ref.nonce,
      mime: ref.mime,
    );
    final MediaStreamServer server = MediaStreamServer(
      waitFor: const Duration(seconds: 2),
      pollEvery: const Duration(milliseconds: 20),
    );
    final Uri uri = await server.publish(BlobMediaStream(sender, wrong));
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    try {
      final HttpClientResponse first = await (await client.getUrl(uri)).close();
      await first.drain<void>();
    } on Object {
      // The response ends short: the player sees an error, that is the point.
    }
    expect(server.serving, 0, reason: 'not served any more');
    final HttpClientResponse again = await (await client.getUrl(uri)).close();
    expect(again.statusCode, HttpStatus.notFound);
    await again.drain<void>();
    await server.withdraw(uri);
  });

  test('withdrawing the last film while another is published keeps the '
      'server open', () async {
    final MediaStreamServer server = MediaStreamServer();
    final Uri first = await server.publish(
      _MemoryFilm(Uint8List.fromList(List<int>.generate(200, (int i) => i))),
    );
    final Future<Uri> second = server.publish(
      _MemoryFilm(Uint8List.fromList(List<int>.generate(100, (int i) => i))),
    );
    await server.withdraw(first);
    final Uri uri = await second;
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientResponse response = await (await client.getUrl(
      uri,
    )).close();
    expect(response.statusCode, HttpStatus.ok);
    expect(<int>[
      for (final List<int> part in await response.toList()) ...part,
    ], List<int>.generate(100, (int i) => i));
    await server.withdraw(uri);
    expect(server.serving, 0);
  });

  test('byte ranges', () {
    expect(parseByteRange(null, 10), (start: 0, end: 9));
    expect(parseByteRange('bytes=2-5', 10), (start: 2, end: 5));
    expect(parseByteRange('bytes=4-', 10), (start: 4, end: 9));
    expect(parseByteRange('bytes=-3', 10), (start: 7, end: 9));
    expect(parseByteRange('bytes=8-100', 10), (start: 8, end: 9));
    expect(parseByteRange('bytes=10-', 10), isNull);
    expect(parseByteRange('bytes=5-2', 10), isNull);
    expect(parseByteRange('items=1-2', 10), isNull);
  });

  test('the loopback server plays a film while it downloads', () async {
    final BlobStore sender = BlobStore();
    final Uint8List film = moveMoovToFront(
      _slowFilm(padding: kBlobChunkSize + 500),
    );
    final MediaRef ref = mediaRefFromJson(
      await storeMedia(sender, film, mime: 'video/mp4'),
    )!;
    final BlobStore receiver = BlobStore()
      ..want(ref.id)
      ..acceptManifest(ref.id, sender.manifest(ref.id)!.toJson());
    final List<String> pieces = sender.manifest(ref.id)!.chunks;
    await receiver.acceptChunk(pieces[0], (await sender.chunk(pieces[0]))!);

    final MediaStreamServer server = MediaStreamServer(
      waitFor: const Duration(seconds: 5),
      pollEvery: const Duration(milliseconds: 20),
    );
    final Uri uri = await server.publish(BlobMediaStream(receiver, ref));
    expect(uri.host, '127.0.0.1');
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));

    Future<(int, List<int>)> fetch(String range) async {
      final HttpClientRequest request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, range);
      final HttpClientResponse response = await request.close();
      final List<int> body = <int>[
        for (final List<int> part in await response.toList()) ...part,
      ];
      return (response.statusCode, body);
    }

    final (int status, List<int> start) = await fetch('bytes=0-99');
    expect(status, HttpStatus.partialContent);
    expect(start, film.sublist(0, 100));

    // Across the two pieces: the second arrives while the player waits.
    final int from = kMediaSegmentBytes - 50;
    final Future<(int, List<int>)> across = fetch('bytes=$from-${from + 99}');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await receiver.acceptChunk(pieces[1], (await sender.chunk(pieces[1]))!);
    expect((await across).$2, film.sublist(from, from + 100));

    // Unknown paths are not served.
    final HttpClientResponse missing = await (await client.getUrl(
      uri.replace(path: '/nothing'),
    )).close();
    expect(missing.statusCode, HttpStatus.notFound);
    await missing.drain<void>();

    await server.withdraw(uri);
    expect(server.serving, 0);
  });
}
