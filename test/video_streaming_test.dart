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

void main() {
  test('fast start: moov goes before the frames, offsets follow', () {
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
