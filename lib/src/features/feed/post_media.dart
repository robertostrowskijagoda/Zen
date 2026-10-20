import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/utils/background_work.dart';
import 'package:zen/src/features/feed/video_metadata.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_stream_server.dart';
import 'package:zen/src/features/media/video_faststart.dart';

/// Photos per post and their longest side after sanitising.
const int kMaxPostImages = 10;
const int kMaxImageSide = 2048;

/// Re-encodes a photo as JPEG without EXIF/GPS (§10), turned upright and
/// scaled down. Throws [ArgumentError] for anything that is not an image.
Future<Uint8List> sanitizePhoto(Uint8List bytes) =>
    Isolate.run(() => _sanitize(bytes));

Uint8List _sanitize(Uint8List bytes) {
  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw ArgumentError('To nie jest obraz.');
  }
  img.Image image = img.bakeOrientation(decoded);
  final int longest = math.max(image.width, image.height);
  if (longest > kMaxImageSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: kMaxImageSide)
        : img.copyResize(image, height: kMaxImageSide);
  }
  image.exif = img.ExifData();
  return img.encodeJpg(image, quality: 85);
}

final Chacha20 _aead = Chacha20.poly1305Aead();

/// Plain bytes in one sealed segment of a media file. With its 16-byte tag
/// a segment fills exactly one piece of the blob (`kBlobChunkSize`), so
/// every piece opens by itself as soon as it arrives: a film plays while
/// it downloads (§10).
const int kMediaSegmentBytes = kBlobChunkSize - 16;

/// Stores [media] encrypted with a fresh key and returns the reference that
/// goes into the post body: `{id, k, n, mime}`. The blob itself is useless
/// without the key, so it may be served to anyone who asks; the key travels
/// only inside the post (sealed for non-public posts). It is sealed in
/// segments of [kMediaSegmentBytes], each with its own nonce (`n` with the
/// segment's number in its last 4 bytes).
///
/// With [stripMetadata], films and recordings in MP4 / MOV / M4A lose
/// their metadata first (place, dates, device: see `video_metadata.dart`),
/// like photos lose EXIF, and get their index in front so they can play
/// while they download (`video_faststart.dart`). Posts and the gallery
/// always ask for it.
Future<Map<String, dynamic>> storeMedia(
  BlobStore blobs,
  Uint8List media, {
  String mime = 'image/jpeg',
  int? durationMs,
  bool stripMetadata = false,
}) async {
  final Uint8List plain = stripMetadata && !isPhotoMime(mime)
      ? moveMoovToFront(stripVideoMetadata(media))
      : media;
  final Uint8List key = randomBytes(32);
  final Uint8List nonce = randomBytes(12);
  // ChaCha20-Poly1305 runs in pure Dart: a film or a big photo is sealed
  // off the UI thread.
  final Uint8List sealed = await _sealMediaSized(plain, key, nonce);
  final String id = await blobs.put(sealed, mime: 'application/octet-stream');
  return <String, dynamic>{
    'id': id,
    'k': b64(key),
    'n': b64(nonce),
    'mime': mime,
    if (durationMs != null && durationMs > 0) 'ms': durationMs,
  };
}

/// A film in a post.
bool isVideoMime(String mime) => mime.startsWith('video/');

/// A recording in a post (a voice message or an audio file).
bool isAudioMime(String mime) => mime.startsWith('audio/');

/// A photo in a post (anything that is neither a film nor a recording).
bool isPhotoMime(String mime) => !isVideoMime(mime) && !isAudioMime(mime);

/// A media reference from a post body, or `null` if malformed.
MediaRef? mediaRefFromJson(Object? json) {
  if (json is! Map) {
    return null;
  }
  final Object? id = json['id'];
  final Uint8List? key = unb64(json['k'], length: 32);
  final Uint8List? nonce = unb64(json['n'], length: 12);
  final Object? mime = json['mime'];
  final Object? ms = json['ms'];
  if (id is! String || id.isEmpty || key == null || nonce == null) {
    return null;
  }
  return MediaRef(
    id: id,
    key: key,
    nonce: nonce,
    mime: mime is String ? mime : 'image/jpeg',
    durationMs: ms is int && ms > 0 && ms < 24 * 3600 * 1000 ? ms : null,
  );
}

/// [ref] as it goes into a post body again (an edit keeping the file).
Map<String, dynamic> mediaRefToJson(MediaRef ref) => <String, dynamic>{
  'id': ref.id,
  'k': b64(ref.key),
  'n': b64(ref.nonce),
  'mime': ref.mime,
  'ms': ?ref.durationMs,
};

@immutable
final class MediaRef {
  const MediaRef({
    required this.id,
    required this.key,
    required this.nonce,
    required this.mime,
    this.durationMs,
  });

  final String id;
  final Uint8List key;
  final Uint8List nonce;
  final String mime;

  /// How long a recording or film is (as its author's phone measured it).
  final int? durationMs;
}

/// The nonce of segment [index] of a media file sealed with [nonce].
Uint8List _segmentNonce(Uint8List nonce, int index) {
  final Uint8List out = Uint8List.fromList(nonce);
  for (int i = 0; i < 4; i++) {
    out[11 - i] ^= (index >> (8 * i)) & 0xFF;
  }
  return out;
}

/// The decrypted media, or `null` while it is not downloaded yet (or if it
/// does not decrypt).
Future<Uint8List?> openMedia(BlobStore blobs, MediaRef ref) async {
  final Uint8List? sealed = await blobs.read(ref.id);
  if (sealed == null || sealed.length < 16) {
    return null;
  }
  try {
    return await _openMediaSized(sealed, ref.key, ref.nonce);
  } on Object {
    return null;
  }
}

// Not async on purpose: a closure made in an async function may drag its
// suspended frame along, which cannot be sent to another isolate.
Future<Uint8List> _sealMediaSized(
  Uint8List plain,
  Uint8List key,
  Uint8List nonce,
) => runSizedWork<Uint8List>(plain.length, () => _sealMedia(plain, key, nonce));

Future<Uint8List> _openMediaSized(
  Uint8List sealed,
  Uint8List key,
  Uint8List nonce,
) => runSizedWork<Uint8List>(
  sealed.length - 16,
  () => _openMedia(sealed, key, nonce),
);

/// [plain] sealed in segments: `ciphertext | tag` of every
/// [kMediaSegmentBytes] (ChaCha20-Poly1305), one after another.
Future<Uint8List> _sealMedia(
  Uint8List plain,
  Uint8List key,
  Uint8List nonce,
) async {
  final int segments = plain.isEmpty
      ? 1
      : (plain.length + kMediaSegmentBytes - 1) ~/ kMediaSegmentBytes;
  final Uint8List out = Uint8List(plain.length + 16 * segments);
  final SecretKey secret = SecretKey(key);
  for (int i = 0; i < segments; i++) {
    final int from = i * kMediaSegmentBytes;
    final int to = math.min(from + kMediaSegmentBytes, plain.length);
    final SecretBox box = await _aead.encrypt(
      Uint8List.sublistView(plain, from, to),
      secretKey: secret,
      nonce: _segmentNonce(nonce, i),
    );
    final int at = i * kBlobChunkSize;
    out
      ..setRange(at, at + box.cipherText.length, box.cipherText)
      ..setRange(
        at + box.cipherText.length,
        at + box.cipherText.length + 16,
        box.mac.bytes,
      );
  }
  return out;
}

/// The plain bytes of segment [index] (`ciphertext | tag` [sealed]);
/// throws when it does not open.
Future<Uint8List> _openSegment(
  Uint8List sealed,
  Uint8List key,
  Uint8List nonce,
  int index,
) async {
  final List<int> plain = await _aead.decrypt(
    SecretBox(
      Uint8List.sublistView(sealed, 0, sealed.length - 16),
      nonce: _segmentNonce(nonce, index),
      mac: Mac(Uint8List.sublistView(sealed, sealed.length - 16)),
    ),
    secretKey: SecretKey(key),
  );
  return plain is Uint8List ? plain : Uint8List.fromList(plain);
}

/// The plain bytes of a whole media file sealed by [_sealMedia]; throws
/// when any segment does not open.
Future<Uint8List> _openMedia(
  Uint8List sealed,
  Uint8List key,
  Uint8List nonce,
) async {
  final BytesBuilder out = BytesBuilder(copy: false);
  for (int at = 0, i = 0; at < sealed.length; at += kBlobChunkSize, i++) {
    final int end = math.min(at + kBlobChunkSize, sealed.length);
    if (end - at < 16) {
      throw const FormatException('A media segment is cut short.');
    }
    out.add(
      await _openSegment(Uint8List.sublistView(sealed, at, end), key, nonce, i),
    );
  }
  return out.takeBytes();
}

/// Segment [index] of the media [ref] in plain bytes, or `null` while its
/// piece has not arrived. Throws when it is there but does not open.
Future<Uint8List?> openMediaSegment(
  BlobStore blobs,
  MediaRef ref,
  int index,
) async {
  final Uint8List? piece = await blobs.chunkAt(ref.id, index);
  if (piece == null) {
    return null;
  }
  if (piece.length < 16) {
    throw const FormatException('A media segment is cut short.');
  }
  return _openSegmentSized(piece, ref.key, ref.nonce, index);
}

Future<Uint8List> _openSegmentSized(
  Uint8List piece,
  Uint8List key,
  Uint8List nonce,
  int index,
) => runSizedWork<Uint8List>(
  piece.length,
  () => _openSegment(piece, key, nonce, index),
);

/// How many plain bytes the media [ref] has, once its manifest is here
/// (`null` before).
int? mediaPlainLength(BlobStore blobs, MediaRef ref) {
  final BlobManifest? manifest = blobs.manifest(ref.id);
  if (manifest == null || manifest.chunks.isEmpty) {
    return null;
  }
  return manifest.size - 16 * manifest.chunks.length;
}

/// A film [ref] for the [MediaStreamServer]: played segment by segment as
/// its pieces arrive.
final class BlobMediaStream implements StreamedMedia {
  BlobMediaStream(this.blobs, this.ref);

  final BlobStore blobs;
  final MediaRef ref;

  @override
  int? get length => mediaPlainLength(blobs, ref);

  @override
  int get segmentBytes => kMediaSegmentBytes;

  @override
  String get contentType => isVideoMime(ref.mime) ? ref.mime : 'video/mp4';

  @override
  Future<Uint8List?> segment(int index) => openMediaSegment(blobs, ref, index);
}

/// The beginning of the film [ref] when it may be streamed to the player
/// while the rest downloads ([looksLikeSafeStreamStart]): `null` while its
/// first piece (or its manifest) has not arrived. Throws
/// [UnsafeMediaException] for a first piece that is not a film.
Future<Uint8List?> openStreamableStart(BlobStore blobs, MediaRef ref) async {
  final int? length = mediaPlainLength(blobs, ref);
  if (length == null) {
    return null;
  }
  final Uint8List? head;
  try {
    head = await openMediaSegment(blobs, ref, 0);
  } on Object {
    throw const UnsafeMediaException();
  }
  if (head == null) {
    return null;
  }
  if (!looksLikeSafeStreamStart(head, length)) {
    throw const UnsafeMediaException();
  }
  return head;
}

/// A picture from someone's post or profile that could not be made safe to
/// show (not a picture, or too large to be one): it is never handed to the
/// phone's image decoder.
final class UnsafeMediaException implements Exception {
  const UnsafeMediaException();
}

final Map<String, Uint8List> _safeImages = <String, Uint8List>{};
int _safeImageBytes = 0;
const int _safeImageCacheBytes = 48 * 1024 * 1024;

/// The picture [ref] made safe to show (see `media_guard.dart`): decoded
/// and encoded again here, so the image decoder of the phone never sees
/// the file as it came. Remembered for the session (the newest 48 MB).
/// Null while it is not downloaded yet; throws [UnsafeMediaException] for
/// something that is not a picture.
Future<Uint8List?> openSafeImage(BlobStore blobs, MediaRef ref) async {
  final Uint8List? known = _safeImages.remove(ref.id);
  if (known != null) {
    _safeImages[ref.id] = known; // most recently used goes last
    return known;
  }
  final Uint8List? plain = await openMedia(blobs, ref);
  if (plain == null) {
    return null;
  }
  final GuardedMedia guarded = await guardIncomingMedia(
    plain,
    declared: MediaKind.image,
  );
  if (guarded.kind != MediaKind.image) {
    throw const UnsafeMediaException();
  }
  _safeImages[ref.id] = guarded.bytes;
  _safeImageBytes += guarded.bytes.length;
  while (_safeImageBytes > _safeImageCacheBytes && _safeImages.length > 1) {
    final String oldest = _safeImages.keys.first;
    _safeImageBytes -= _safeImages.remove(oldest)!.length;
  }
  return guarded.bytes;
}

/// The film or recording [ref], or null while it is not downloaded yet.
/// Throws [UnsafeMediaException] when its container does not add up (it is
/// then never handed to the player).
Future<Uint8List?> openSafePlayable(BlobStore blobs, MediaRef ref) async {
  final Uint8List? plain = await openMedia(blobs, ref);
  if (plain == null) {
    return null;
  }
  final MediaKind kind = sniffMediaKind(plain);
  if ((kind != MediaKind.video && kind != MediaKind.audio) ||
      !looksLikeSafeContainer(plain)) {
    throw const UnsafeMediaException();
  }
  return plain;
}
