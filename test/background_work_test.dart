import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/utils/background_work.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';

/// Set in this isolate only: a fresh isolate sees the initial value.
int _marker = 0;

int _readMarker() => _marker;

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (int i) => i * 31 & 0xFF));

/// Plain JSON signals never reach the compressor.
final class _NoCompressor implements SignalPayloadCompressor {
  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => null;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => null;
}

void main() {
  setUp(() => _marker = 7);
  tearDown(() => debugSetBackgroundWorkEnabled(null));

  test('small work stays here, big work moves to an isolate', () async {
    debugSetBackgroundWorkEnabled(true);
    expect(await runSizedWork<int>(100, _readMarker), 7);
    expect(
      await runSizedWork<int>(kBackgroundWorkThresholdBytes, _readMarker),
      7,
    );
    expect(
      await runSizedWork<int>(kBackgroundWorkThresholdBytes + 1, _readMarker),
      0,
    );
  });

  test('flutter test keeps all work in place unless switched on', () async {
    expect(backgroundWorkEnabled, isFalse);
    expect(await runSizedWork<int>(10 * 1024 * 1024, _readMarker), 7);
  });

  test('errors of offloaded work reach the caller', () async {
    debugSetBackgroundWorkEnabled(true);
    await expectLater(
      runSizedWork<int>(
        kBackgroundWorkThresholdBytes + 1,
        () => throw const FormatException('nope'),
      ),
      throwsFormatException,
    );
  });

  test('AES-GCM is the same in an isolate and in place', () async {
    final Uint8List key = randomSecurityBytes(32);
    final List<int> aad = utf8.encode('zen.store.v2|ledger');
    for (final int size in <int>[0, 1000, 64 * 1024, 300 * 1024]) {
      final Uint8List plain = _bytes(size);

      debugSetBackgroundWorkEnabled(true);
      final Uint8List sealedAway = await encryptSecurityBytes(
        plain,
        key,
        aad: aad,
      );
      debugSetBackgroundWorkEnabled(false);
      final Uint8List sealedHere = await encryptSecurityBytes(
        plain,
        key,
        aad: aad,
      );
      expect(sealedAway.length, size + 28);
      expect(sealedHere.length, size + 28);

      // Each opens either way.
      expect(await decryptSecurityBytes(sealedAway, key, aad: aad), plain);
      debugSetBackgroundWorkEnabled(true);
      expect(await decryptSecurityBytes(sealedHere, key, aad: aad), plain);

      // The context still binds: another aad does not open it.
      await expectLater(
        decryptSecurityBytes(sealedHere, key, aad: utf8.encode('other')),
        throwsA(anything),
      );
    }
    await expectLater(
      decryptSecurityBytes(Uint8List(27), key),
      throwsFormatException,
    );
  });

  test('a big media file seals and opens off the UI thread', () async {
    debugSetBackgroundWorkEnabled(true);
    final BlobStore blobs = BlobStore();
    final Uint8List plain = _bytes(200 * 1024);
    final Map<String, dynamic> stored = await storeMedia(blobs, plain);
    final MediaRef? ref = mediaRefFromJson(stored);
    expect(ref, isNotNull);
    expect(await openMedia(blobs, ref!), plain);

    debugSetBackgroundWorkEnabled(false);
    expect(await openMedia(blobs, ref), plain);
  });

  test('a big signal is parsed the same in an isolate', () async {
    debugSetBackgroundWorkEnabled(true);
    final Map<String, dynamic> payload = <String, dynamic>{
      'type': 'attachment_chunk',
      'chunkData': base64Encode(_bytes(120 * 1024)),
      'index': 3,
    };
    final String raw = jsonEncode(payload);
    expect(raw.length, greaterThan(kBackgroundWorkThresholdBytes));
    final Map<String, dynamic>? decoded = await decodeRuntimeSignalPayload(
      raw,
      _NoCompressor(),
    );
    expect(decoded, payload);
    expect(await decodeRuntimeSignalPayload('[1, 2]', _NoCompressor()), isNull);
  });
}
