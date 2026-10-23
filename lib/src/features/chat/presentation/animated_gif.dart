import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/storage/unmetered_network.dart';
import 'package:zen/src/features/feed/presentation/video_autoplay.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Longest side, in pixels, a still image is decoded at. (The engine
/// decodes the frames of an animated one at full size whatever is asked;
/// media_guard keeps GIFs within kMaxGifSide.)
const int _maxDecodePx = 1024;

/// Frames decoded by every animated image so far (for tests: a GIF that is
/// not seen must not decode frames).
@visibleForTesting
int debugGifFramesDecoded = 0;

/// The size, in device pixels, a [width] x [height] image is asked to be
/// decoded at to fill a box of [box] device pixels with [fit] (a still
/// image is; an animated one's frames come at full size): never larger
/// than the image itself, nor than [_maxDecodePx] on its longest side. An
/// unknown box ([Size.infinite] or a side that is not finite) only bounds
/// by what is known.
@visibleForTesting
ui.TargetImageSize gifDecodeSize(
  int width,
  int height, {
  Size box = Size.infinite,
  BoxFit fit = BoxFit.cover,
}) {
  if (width <= 0 || height <= 0) {
    return const ui.TargetImageSize();
  }
  final bool wide = box.width.isFinite && box.width > 0;
  final bool tall = box.height.isFinite && box.height > 0;
  double scale = 1;
  if (wide && tall) {
    final double sx = box.width / width;
    final double sy = box.height / height;
    // Covering a box needs the larger scale; fitting into it the smaller.
    scale = fit == BoxFit.cover || fit == BoxFit.fill
        ? (sx > sy ? sx : sy)
        : (sx < sy ? sx : sy);
  } else if (wide) {
    scale = box.width / width;
  } else if (tall) {
    scale = box.height / height;
  }
  if (scale > 1) {
    scale = 1;
  }
  final int longest = width >= height ? width : height;
  if (longest * scale > _maxDecodePx) {
    scale = _maxDecodePx / longest;
  }
  if (scale >= 1) {
    return const ui.TargetImageSize();
  }
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

class _ZenAnimatedImageState extends State<ZenAnimatedImage>
    with WidgetsBindingObserver {
  ui.Codec? _codec;
  ui.Image? _frame;
  Timer? _timer;
  Object? _error;
  int _generation = 0;

  /// Tapped to play (it then plays whatever the settings say).
  bool _started = false;

  /// A frame is being decoded (the chain of frames goes on by itself).
  bool _decoding = false;

  /// The system asks for reduced motion.
  bool _reducedMotion = false;

  /// Not in a hidden tab nor on a page under another one.
  bool _onScreen = true;

  /// The box it is shown in, in device pixels: frames are decoded for it.
  /// Known after the first layout; loading starts then.
  Size? _box;

  /// The image's own width (what the codec reported before decoding).
  int _sourceWidth = 0;

  /// Decoded width over the image's own width (below 1 when decoded
  /// smaller): keeps its natural size on screen the same. Taken from the
  /// frames themselves: the engine decodes the frames of an animated image
  /// at full size whatever size is asked for (only a still one is decoded
  /// smaller).
  double _decodeScale = 1;

  /// It should move (autoplay or a tap), wherever it is.
  bool get _wantsPlay => _started || (widget.autoplay && !_reducedMotion);

  /// The app is in front (a window hidden in the tray, behind others or the
  /// app in the background shows nothing).
  static bool get _appShown {
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Frames are decoded now: it should move and can be seen.
  bool get _advancing => _wantsPlay && _onScreen && _appShown;

  bool get _animated => (_codec?.frameCount ?? 0) > 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(ZenAnimatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.file?.path != widget.file?.path) {
      _stop();
      if (_box != null) {
        unawaited(_load());
      }
    } else {
      _resumeOrPause();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion may be switched on or off while it is on screen; the
    // tab or page it is on may be hidden or shown again.
    _reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _onScreen = mayAutoplayAt(context);
    _resumeOrPause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _resumeOrPause();

  /// Starts the frame timer when it should advance and is waiting, or
  /// stops it (on the frame shown) when it should not.
  void _resumeOrPause() {
    if (_codec == null || _frame == null || !_animated) {
      return;
    }
    if (_advancing) {
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

  /// Notes the box of the first layout (and loads for it), or a much larger
  /// one later (decodes again, sharper).
  void _noteBox(BuildContext context, BoxConstraints constraints) {
    final double ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    double side(double? wanted, double max) {
      final double logical = wanted != null && wanted.isFinite
          ? math.min(wanted, max)
          : max;
      return logical * ratio;
    }

    final Size box = Size(
      side(widget.width, constraints.maxWidth),
      side(widget.height, constraints.maxHeight),
    );
    final Size? old = _box;
    if (old != null && !_muchLarger(box, old)) {
      return;
    }
    _box = box;
    if (old != null) {
      _stop();
    }
    unawaited(_load());
  }

  static bool _muchLarger(Size box, Size old) {
    bool larger(double now, double before) =>
        now.isFinite && before.isFinite && now > before * 1.5;
    return larger(box.width, old.width) || larger(box.height, old.height);
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    final Size box = _box ?? Size.infinite;
    final BoxFit fit = widget.fit;
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
      int sourceWidth = 0;
      final ui.Codec codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (int width, int height) {
          sourceWidth = width;
          return gifDecodeSize(width, height, box: box, fit: fit);
        },
      );
      if (!mounted || generation != _generation) {
        codec.dispose();
        return;
      }
      _codec = codec;
      _sourceWidth = sourceWidth;
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
      debugGifFramesDecoded++;
      info = await codec.getNextFrame();
    } finally {
      _decoding = false;
      // Stopped while this frame was decoding: the codec is freed only now
      // (freeing it under a running decode crashes the engine).
      if (!identical(codec, _codec)) {
        codec.dispose();
      }
    }
    if (!mounted || generation != _generation) {
      info.image.dispose();
      return;
    }
    final ui.Image? previous = _frame;
    setState(() {
      _frame = info.image;
      _decodeScale = _sourceWidth > 0 && info.image.width < _sourceWidth
          ? info.image.width / _sourceWidth
          : 1;
    });
    if (previous != null) {
      // Still on screen until the next frame is painted.
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    _timer = null;
    // Hidden (another tab, a page above, the app in the background or the
    // window in the tray): it stays on this frame and decodes nothing until
    // it is seen again.
    if (codec.frameCount > 1 && _advancing) {
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
    final ui.Codec? codec = _codec;
    _codec = null;
    // A frame still decoding frees it when it is done (_showNextFrame).
    if (!_decoding) {
      codec?.dispose();
    }
    _error = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    final ui.Image? frame = _frame;
    _frame = null;
    frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      _noteBox(context, constraints);
      return _content(context);
    },
  );

  Widget _content(BuildContext context) {
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
      scale: _decodeScale,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
    );
    if (!_animated || _wantsPlay) {
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
