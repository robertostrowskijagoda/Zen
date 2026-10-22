import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/presentation/animated_gif.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';

final Map<int, Uint8List?> _decoded = <int, Uint8List?>{};
final Map<int, Future<Uint8List?>> _decoding = <int, Future<Uint8List?>>{};

/// The bytes of a base64 photo, re-encoded first in an isolate when it
/// came from someone else as it was ([clean]), so odd bytes never reach the
/// image decoder. Such a photo must be small (as phones of this app send
/// it): anything bigger, by bytes or by the size its header claims, is not
/// shown at all. Cached.
Future<Uint8List?> safePhotoBytes(String data, {bool clean = false}) {
  final int key = Object.hash(data.length, data.hashCode, clean);
  if (_decoded.containsKey(key)) {
    return SynchronousFuture<Uint8List?>(_decoded[key]);
  }
  return _decoding[key] ??= () async {
    Uint8List? out;
    try {
      if (clean && data.length > kMaxRemotePhotoInputBytes * 4 ~/ 3 + 4) {
        throw const FormatException('za duże zdjęcie');
      }
      final Uint8List raw = base64Decode(data);
      out = clean ? await compute(compressRemoteFlatPhoto, raw) : raw;
    } on Object {
      out = null;
    }
    _decoding.remove(key);
    _decoded[key] = out;
    if (_decoded.length > 120) {
      _decoded.remove(_decoded.keys.first);
    }
    return out;
  }();
}

/// A photo given as base64 (an event album photo, a flat's photo); a GIF
/// plays.
class SafePhoto extends StatefulWidget {
  const SafePhoto({
    required this.data,
    this.clean = false,
    this.fit = BoxFit.cover,
    this.icon = Icons.image_rounded,
    super.key,
  });

  final String data;

  /// Re-encode before showing (a photo nobody on this phone cleaned yet).
  final bool clean;
  final BoxFit fit;

  /// Shown while loading or when the photo cannot be shown.
  final IconData icon;

  @override
  State<SafePhoto> createState() => _SafePhotoState();
}

class _SafePhotoState extends State<SafePhoto> {
  late Future<Uint8List?> _bytes = safePhotoBytes(
    widget.data,
    clean: widget.clean,
  );

  @override
  void didUpdateWidget(SafePhoto old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data || old.clean != widget.clean) {
      _bytes = safePhotoBytes(widget.data, clean: widget.clean);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Widget placeholder = ColoredBox(
      color: zen.surfaceMuted,
      child: Center(child: Icon(widget.icon, color: zen.textMuted)),
    );
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snap) {
        final Uint8List? bytes = snap.data;
        if (bytes == null) {
          return placeholder;
        }
        if (looksLikeGif(bytes)) {
          // A GIF plays (a still first frame would hide what it is).
          return ZenAnimatedImage(
            bytes: bytes,
            fit: widget.fit,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (BuildContext context, Object error, StackTrace? _) =>
                placeholder,
          );
        }
        return Image.memory(
          bytes,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (BuildContext context, Object error, StackTrace? _) =>
              placeholder,
        );
      },
    );
  }
}
