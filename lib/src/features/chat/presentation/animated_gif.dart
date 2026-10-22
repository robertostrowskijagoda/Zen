import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/storage/unmetered_network.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

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

/// Whether GIFs start playing on their own with [settings]: the same rule
/// as media downloading on their own ("Media" settings: not when that is
/// off, nor on mobile data when it is limited to Wi-Fi). Otherwise a GIF
/// waits on its first frame until it is tapped.
bool gifAutoplay(AppSettings settings) => settings.allowsAutoDownload(
  onUnmetered: UnmeteredNetwork.instance.onUnmetered,
);

/// A [ZenAnimatedImage] that plays on its own as far as the settings allow
/// ([gifAutoplay]); a tap plays it otherwise.
class ZenGif extends ConsumerWidget {
  const ZenGif({
    this.bytes,
    this.file,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.errorBuilder,
    super.key,
  });

  final Uint8List? bytes;
  final File? file;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ZenAnimatedImage(
    bytes: bytes,
    file: file,
    fit: fit,
    width: width,
    height: height,
    errorBuilder: errorBuilder,
    autoplay: gifAutoplay(ref.watch(appSettingsControllerProvider)),
  );
}

/// An animated image that keeps playing on every platform.
///
/// Plays frames itself from the decoded codec instead of relying on
/// `Image`'s own animation, which stayed on the first frame here. Takes raw
/// [bytes] or a [file] — never a URL: GIFs arrive as attachments that went
/// through `media_guard`.
///
/// With [autoplay] off, or when the system asks for reduced motion, it
/// shows the first frame with a play badge and plays once tapped.
class ZenAnimatedImage extends StatefulWidget {
  const ZenAnimatedImage({
    super.key,
    this.bytes,
    this.file,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.errorBuilder,
    this.autoplay = true,
  });

  final Uint8List? bytes;
  final File? file;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Plays on its own (unless the system asks for reduced motion).
  final bool autoplay;

  @override
  State<ZenAnimatedImage> createState() => _ZenAnimatedImageState();
}

class _ZenAnimatedImageState extends State<ZenAnimatedImage> {
  ui.Codec? _codec;
  ui.Image? _frame;
  Timer? _timer;
  Object? _error;
  int _generation = 0;

  /// Tapped to play (it then plays whatever the settings say).
  bool _started = false;

  /// A frame is being decoded (the chain of frames goes on by itself).
  bool _decoding = false;

  bool get _playing =>
      _started ||
      (widget.autoplay &&
          !(MediaQuery.maybeDisableAnimationsOf(context) ?? false));

  bool get _animated => (_codec?.frameCount ?? 0) > 1;

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
    } else {
      _resumeOrPause();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion may be switched on or off while it is on screen.
    _resumeOrPause();
  }

  /// Starts the frame timer when it should play and is waiting, or stops
  /// it (on the frame shown) when it should not.
  void _resumeOrPause() {
    if (_codec == null || _frame == null || !_animated) {
      return;
    }
    if (_playing) {
      if (_timer == null && !_decoding) {
        final int generation = _generation;
        _timer = Timer(
          const Duration(milliseconds: 100),
          () => unawaited(_showNextFrame(generation)),
        );
      }
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _play() {
    setState(() => _started = true);
    _resumeOrPause();
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
    final ui.FrameInfo info;
    _decoding = true;
    try {
      info = await codec.getNextFrame();
    } finally {
      _decoding = false;
    }
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
    _timer = null;
    if (codec.frameCount > 1 && _playing) {
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
    final Widget picture = RawImage(
      image: frame,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
    );
    if (!_animated || _playing) {
      return picture;
    }
    // Waiting on its first frame: a tap plays it (and does not reach what
    // is behind, like opening the photo).
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = ZenColors.foregroundFor(scheme.scrim);
    return Semantics(
      button: true,
      label: t('Odtwórz GIF'),
      child: GestureDetector(
        key: const Key('gif-play'),
        behavior: HitTestBehavior.opaque,
        onTap: _play,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            picture,
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.scrim.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.play_arrow_rounded, color: ink, size: 26),
                    Text(
                      'GIF',
                      style: TextStyle(
                        color: ink,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
