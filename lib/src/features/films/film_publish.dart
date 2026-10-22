import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_trim.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/media/mp4_probe.dart';
import 'package:zen/src/features/media/video_compressor.dart';

/// A film about to be published: a recording on disk and what goes with it.
@immutable
final class FilmDraft {
  const FilmDraft({
    required this.path,
    required this.durationMs,
    required this.trim,
    this.caption = '',
    this.audience = Audience.all,
    this.replyTo,
  });

  /// The recording or the picked file.
  final String path;

  /// Its whole length.
  final int durationMs;
  final FilmTrim trim;
  final String caption;
  final Audience audience;
  final FilmReplyRef? replyTo;
}

/// Where publishing a film is.
enum FilmPublishStage {
  compressing,

  /// Reported once when the film had to go without sound (no encoder for
  /// it on this computer), so the person can be told.
  silent,
  sealing,
  publishing,
}

typedef FilmPublishProgress =
    void Function(FilmPublishStage stage, double fraction);

/// "Film jest za duży (maks. 20 MB)."
String _tooBig() => t('Film jest za duży (maks. {size}).', {
  'size': '${kFilmMaxBytes ~/ (1024 * 1024)} MB',
});

/// Compresses [draft] (720p, about 2.5 Mb/s, cut to its trim) on the
/// phone's encoder, strips its metadata, puts the index in front, seals it
/// and publishes it with a poster. Without an encoder (Linux) the file goes
/// as it is, when it is short and small enough and is not trimmed.
/// Throws [ArgumentError] with a message for the person when the film
/// cannot go, [VideoCompressionException] when the encoder failed.
Future<LogEntry> publishFilm(
  LedgerNode node,
  FilmDraft draft, {
  required VideoCompressor compressor,
  FilmPublishProgress? onProgress,
  Future<String> Function()? temporaryPath,
}) async {
  final String caption = checkedFilmCaption(draft.caption);
  if (draft.trim.lengthMs < math.min(kFilmMinMs, draft.durationMs) ||
      draft.trim.lengthMs > kFilmHardMaxMs) {
    throw ArgumentError(
      tn(
        kFilmHardMaxMs ~/ 1000,
        one: 'Film jest za długi (maks. {n} sekunda).',
        few: 'Film jest za długi (maks. {n} sekundy).',
        many: 'Film jest za długi (maks. {n} sekund).',
      ),
    );
  }
  onProgress?.call(FilmPublishStage.compressing, 0);
  final Uint8List bytes;
  String frameSource = draft.path;
  int frameAt = draft.trim.startMs;
  String? output;
  int width = 0;
  int height = 0;
  int? durationMs;
  try {
    if (await compressor.available()) {
      output = await (temporaryPath ?? _temporaryFilmPath)();
      final Mp4Info? original = await probeMp4File(File(draft.path));
      final CompressedVideo done = await compressor.compress(
        input: draft.path,
        output: output,
        source: original == null
            ? null
            : (
                width: original.width,
                height: original.height,
                rotation: original.rotation,
              ),
        plan: planVideoCompression(
          durationMs: math.max(1, draft.trim.lengthMs),
        ),
        startMs: draft.trim.startMs,
        endMs: draft.trim.isWhole(draft.durationMs) ? null : draft.trim.endMs,
        onProgress: (double f) =>
            onProgress?.call(FilmPublishStage.compressing, f),
      );
      final Uint8List raw = await File(done.path).readAsBytes();
      // A bridge that leaves the picture as stored says how to turn it.
      bytes = done.rotation == 0 ? raw : setMp4Rotation(raw, done.rotation);
      if (!done.hasAudio) {
        onProgress?.call(FilmPublishStage.silent, 1);
      }
      frameSource = done.path;
      frameAt = 0;
      width = done.width;
      height = done.height;
      durationMs = done.durationMs > 0 ? done.durationMs : null;
    } else {
      if (!draft.trim.isWhole(draft.durationMs)) {
        throw ArgumentError(t('Na tym urządzeniu filmu nie da się przyciąć.'));
      }
      final File file = File(draft.path);
      if (await file.length() > kFilmMaxBytes) {
        throw ArgumentError(_tooBig());
      }
      bytes = await file.readAsBytes();
    }
    if (bytes.length > kFilmMaxBytes) {
      throw ArgumentError(_tooBig());
    }
    final Mp4Info? info = probeMp4(bytes);
    if (info == null || !info.hasVideo) {
      throw ArgumentError(t('To nie jest film.'));
    }
    durationMs ??= info.durationMs;
    if (durationMs > kFilmHardMaxMs + 1000) {
      throw ArgumentError(
        tn(
          kFilmHardMaxMs ~/ 1000,
          one: 'Film jest za długi (maks. {n} sekunda).',
          few: 'Film jest za długi (maks. {n} sekundy).',
          many: 'Film jest za długi (maks. {n} sekund).',
        ),
      );
    }
    if (width <= 0 || height <= 0) {
      width = info.displayWidth;
      height = info.displayHeight;
    }
    onProgress?.call(FilmPublishStage.sealing, 0);
    Map<String, dynamic>? poster;
    final Uint8List? frame = await compressor.thumbnail(
      frameSource,
      atMs: frameAt,
    );
    if (frame != null) {
      try {
        poster = await storeMedia(node.blobs, await sanitizePhoto(frame));
      } on ArgumentError {
        poster = null; // not a picture: the film goes without one
      }
    }
    final Map<String, dynamic> video = await storeMedia(
      node.blobs,
      bytes,
      mime: 'video/mp4',
      durationMs: durationMs,
      stripMetadata: true,
    );
    final Map<String, dynamic> body = newFilmBody(
      video: video,
      caption: caption,
      audience: draft.audience,
      poster: poster,
      replyTo: draft.replyTo,
      width: width,
      height: height,
    );
    onProgress?.call(FilmPublishStage.publishing, 0);
    final LogEntry entry = await node.publish(
      kFilmKind,
      await node.seal(draft.audience, body),
    );
    onProgress?.call(FilmPublishStage.publishing, 1);
    return entry;
  } finally {
    if (output != null) {
      try {
        await File(output).delete();
      } on FileSystemException {
        // Already gone; the temporary folder is emptied at start anyway.
      }
    }
  }
}

Future<String> _temporaryFilmPath() =>
    newTemporaryMediaPath(prefix: 'film-', extension: '.mp4');
