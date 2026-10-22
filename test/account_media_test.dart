import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/features/account/account_media.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/media/media_vault.dart';

void main() {
  test('a file sealed piece by piece opens like any media file', () async {
    final BlobStore blobs = BlobStore();
    final Uint8List film = Uint8List.fromList(
      List<int>.generate(900 * 1024 + 7, (int i) => (i * 13) % 256),
    );
    final List<int> reads = <int>[];
    final Map<String, dynamic>? ref = await storeMediaStreamed(
      blobs,
      size: film.length,
      range: (int start, int end) async {
        reads.add(end - start);
        return Uint8List.sublistView(film, start, end);
      },
      mime: 'video/mp4',
    );
    expect(ref, isNotNull);
    expect(reads, everyElement(lessThanOrEqualTo(kMediaSegmentBytes)));
    final MediaRef media = mediaRefFromJson(ref)!;
    expect(blobs.isComplete(media.id), isTrue);
    expect(media.mime, 'video/mp4');
    // The usual reader opens it.
    expect(await openMedia(blobs, media), film);
    // And piece by piece.
    final List<int> pieces = <int>[];
    final BytesBuilder out = BytesBuilder();
    await for (final Uint8List part in openMediaStreamed(blobs, media)) {
      pieces.add(part.length);
      out.add(part);
    }
    expect(out.takeBytes(), film);
    expect(pieces, everyElement(lessThanOrEqualTo(kMediaSegmentBytes)));
    expect(mediaPlainLength(blobs, media), film.length);
  });

  test('an empty file and one too big', () async {
    final BlobStore blobs = BlobStore();
    final Map<String, dynamic>? empty = await storeMediaStreamed(
      blobs,
      size: 0,
      range: (int start, int end) async => Uint8List(0),
    );
    expect(await openMedia(blobs, mediaRefFromJson(empty)!), isEmpty);
    expect(
      await storeMediaStreamed(
        blobs,
        size: kMaxStreamedMediaBytes + 1,
        range: (int start, int end) async => Uint8List(end - start),
      ),
      isNull,
    );
  });

  test('a computer counts as Wi-Fi', () async {
    expect(await onUnmeteredNetwork(phone: false), isTrue);
  });

  test('the media vault takes a file piece by piece', () async {
    final Directory dir = Directory.systemTemp.createTempSync('zen-vault-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final MediaVault vault = MediaVault(
      masterKey: () async => Uint8List.fromList(List<int>.filled(32, 5)),
      supportDirectory: () async => dir,
      temporaryDirectory: () async => dir,
    );
    final Uint8List film = Uint8List.fromList(
      List<int>.generate(300 * 1024 + 3, (int i) => i % 199),
    );
    final String path = await vault.putStream(
      film.length,
      Stream<List<int>>.fromIterable(<List<int>>[
        for (int at = 0; at < film.length; at += 70000)
          Uint8List.sublistView(
            film,
            at,
            at + 70000 < film.length ? at + 70000 : film.length,
          ),
      ]),
    );
    expect(isMediaVaultPath(path), isTrue);
    expect(await vault.read(path), film);
    expect(await vault.readRange(path, 100, 200), film.sublist(100, 200));
    await expectLater(
      vault.putStream(10, Stream<List<int>>.value(<int>[1, 2, 3])),
      throwsFormatException,
    );
  });
}
