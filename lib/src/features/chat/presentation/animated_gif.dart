import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:zen/src/features/media/media_vault.dart';

/// Longest side, in pixels, an animated image is decoded at. Every frame is
/// decoded at this size; a GIF declaring huge dimensions would otherwise
/// cost gigabytes per frame.
const int _maxDecodePx = 1024;

ui.TargetImageSize _boundedDecodeSize(int width, int height) {
  if (width <= _maxDecodePx && height <= _maxDecodePx) {
    return const ui.TargetImageSize();
  }
  final int longest = width >= height ? width : height;
  final double scale = _maxDecodePx / longest;
  final int targetWidth = (width * scale).round();
  final int targetHeight = (height * scale).round();
  return ui.TargetImageSize(
    width: targetWidth < 1 ? 1 : targetWidth,
    height: targetHeight < 1 ? 1 : targetHeight,
  );
}

/// An animated image that keeps playing on every platform.
///
/// Plays frames itself from the decoded codec instead of relying on
/// `Image`'s own animation, which stayed on the first frame here. Takes raw
/// [bytes] or a [file] — never a URL: GIFs arrive as attachments that went
/// through `media_guard`.
class ZenAnimatedImage extends StatefulWidget {
  const ZenAnimatedImage({
    super.key,
    this.bytes,
    this.file,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.errorBuilder,
  });

  final Uint8List? bytes;
  final File? file;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<ZenAnimatedImage> createState() => _ZenAnimatedImageState();
}

class _ZenAnimatedImageState extends State<ZenAnimatedImage> {
  ui.Codec? _codec;
  ui.Image? _frame;
  Timer? _timer;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ZenAnimatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.file?.path != widget.file?.path) {
      _stop();
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    try {
      Uint8List? bytes = widget.bytes;
      if (bytes == null && widget.file != null) {
        // An encrypted file is opened in memory, never in plain form.
        bytes = await readMediaFile(widget.file!.path);
      }
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Brak obrazu.');
      }
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        bytes,
      );
      final ui.Codec codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: _boundedDecodeSize,
      );
      if (!mounted || generation != _generation) {
        codec.dispose();
        return;
      }
      _codec = codec;
      await _showNextFrame(generation);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _showNextFrame(int generation) async {
    final ui.Codec? codec = _codec;
    if (codec == null || !mounted || generation != _generation) {
      return;
    }
    final ui.FrameInfo info = await codec.getNextFrame();
    if (!mounted || generation != _generation) {
      info.image.dispose();
      return;
    }
    final ui.Image? previous = _frame;
    setState(() => _frame = info.image);
    if (previous != null) {
      // Still on screen until the next frame is painted.
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    if (codec.frameCount > 1) {
      final Duration delay = info.duration < const Duration(milliseconds: 20)
          ? const Duration(milliseconds: 100)
          : info.duration;
      _timer = Timer(delay, () => unawaited(_showNextFrame(generation)));
    }
  }

  void _stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _codec?.dispose();
    _codec = null;
    _error = null;
  }

  @override
  void dispose() {
    _stop();
    final ui.Image? frame = _frame;
    _frame = null;
    frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Object? error = _error;
    if (error != null) {
      return widget.errorBuilder?.call(context, error, null) ??
          SizedBox(width: widget.width, height: widget.height);
    }
    final ui.Image? frame = _frame;
    if (frame == null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return RawImage(
      image: frame,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
    );
  }
}
