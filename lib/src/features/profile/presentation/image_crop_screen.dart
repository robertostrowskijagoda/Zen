import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/media/crop_region.dart';

/// The most a picture can be zoomed in while framing it.
const double kCropMaxZoom = 6;

/// The largest picture (in pixels) the framing screen decodes at all.
const int kCropMaxPixels = 50 * 1000 * 1000;

/// The longest side the framing screen shows a picture at.
const int kCropPreviewSide = 2048;

/// Framing a picture before it becomes one's photo (a circle, 1:1) or the
/// cover (3:1): the picture moves and zooms under a fixed frame (two
/// fingers, the mouse wheel, the slider or the keys + and -), and
/// "Gotowe" gives the part inside it ([CropRegion]). The frame is always
/// filled: the picture cannot be moved or zoomed out past its edges.
class ImageCropScreen extends StatefulWidget {
  const ImageCropScreen({
    super.key,
    required this.bytes,
    required this.aspect,
    required this.title,
    this.round = false,
  });

  /// The picture as picked (any format Flutter shows).
  final Uint8List bytes;

  /// Width / height of the frame.
  final double aspect;

  /// A round frame (a photo shown in circles); the part kept is still the
  /// square around it.
  final bool round;
  final String title;

  /// Opens the framing of [bytes]; the part kept, or `null` when the person
  /// went back. A picture Flutter cannot show is not framed: the whole of
  /// it ([CropRegion.full]), so the usual checks say what is wrong with it.
  static Future<CropRegion?> open(
    BuildContext context, {
    required Uint8List bytes,
    required double aspect,
    required String title,
    bool round = false,
  }) {
    return Navigator.of(context).push<CropRegion>(
      MaterialPageRoute<CropRegion>(
        fullscreenDialog: true,
        builder: (BuildContext context) => ImageCropScreen(
          bytes: bytes,
          aspect: aspect,
          title: title,
          round: round,
        ),
      ),
    );
  }

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  ui.Image? _image;
  bool _failed = false;

  /// Zoom over the smallest scale that fills the frame (1…[kCropMaxZoom]).
  double _zoom = 1;

  /// Where the picture's top left corner is, from the frame's top left, in
  /// logical pixels (always ≤ 0: the frame stays filled). `null` until the
  /// first layout centres it.
  Offset? _offset;

  /// The frame and the scale that fills it, as last laid out.
  Rect _frame = Rect.zero;
  double _fill = 1;

  // A pinch in progress.
  double _startZoom = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  Future<void> _decode() async {
    try {
      // The picture's size is read from its header first: a small file can
      // claim a huge picture (a decompression bomb, from a GIF catalogue
      // or a keyboard as well as a file), which would take all the memory.
      // Over [kCropMaxPixels] it is not shown (the checks after framing say
      // what is wrong); otherwise it is shown at most [kCropPreviewSide] a
      // side, which is all the screen needs: the region is a fraction.
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        widget.bytes,
      );
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
        buffer,
      );
      final int w = descriptor.width;
      final int h = descriptor.height;
      if (w <= 0 || h <= 0 || w * h > kCropMaxPixels) {
        descriptor.dispose();
        buffer.dispose();
        throw const FormatException('Too big to show');
      }
      final ui.Codec codec = await descriptor.instantiateCodec(
        targetWidth: w >= h && w > kCropPreviewSide ? kCropPreviewSide : null,
        targetHeight: h > w && h > kCropPreviewSide ? kCropPreviewSide : null,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } on Object catch (error) {
      logZenWarning('A picture to frame could not be shown: $error');
      if (mounted) {
        // Nothing to frame: taken whole, checked as before.
        setState(() => _failed = true);
        Navigator.of(context).pop(CropRegion.full);
      }
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Size get _imageSize =>
      Size(_image!.width.toDouble(), _image!.height.toDouble());

  double get _scale => _fill * _zoom;

  /// [offset] moved back so the picture at [scale] still covers the frame.
  Offset _clamp(Offset offset, double scale) {
    final Size shown = _imageSize * scale;
    final double minX = _frame.width - shown.width;
    final double minY = _frame.height - shown.height;
    return Offset(
      offset.dx.clamp(math.min(minX, 0.0), 0.0),
      offset.dy.clamp(math.min(minY, 0.0), 0.0),
    );
  }

  /// Zooms to [zoom] keeping the picture's point under [focal] (frame
  /// coordinates; the frame's middle by default) where it is.
  void _zoomTo(double zoom, {Offset? focal}) {
    final Offset? offset = _offset;
    if (_image == null || offset == null) {
      return;
    }
    final double next = zoom.clamp(1.0, kCropMaxZoom);
    final Offset at = focal ?? _frame.size.center(Offset.zero);
    final Offset point = (at - offset) / _scale;
    setState(() {
      _zoom = next;
      _offset = _clamp(at - point * _scale, _scale);
    });
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startZoom = _zoom;
    _startOffset = _offset ?? Offset.zero;
    _startFocal = d.localFocalPoint - _frame.topLeft;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_image == null) {
      return;
    }
    final double zoom = (_startZoom * d.scale).clamp(1.0, kCropMaxZoom);
    final double scale = _fill * zoom;
    // The point of the picture under the fingers when they came down
    // follows them.
    final Offset point = (_startFocal - _startOffset) / (_fill * _startZoom);
    final Offset focal = d.localFocalPoint - _frame.topLeft;
    setState(() {
      _zoom = zoom;
      _offset = _clamp(focal - point * scale, scale);
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _zoomTo(
        _zoom * math.exp(-event.scrollDelta.dy / 400),
        focal: event.localPosition - _frame.topLeft,
      );
    }
  }

  CropRegion _region() {
    final Size shown = _imageSize * _scale;
    final Offset offset = _offset ?? Offset.zero;
    return CropRegion(
      left: (-offset.dx / shown.width).clamp(0.0, 1.0),
      top: (-offset.dy / shown.height).clamp(0.0, 1.0),
      width: (_frame.width / shown.width).clamp(0.0, 1.0),
      height: (_frame.height / shown.height).clamp(0.0, 1.0),
    );
  }

  void _done() {
    if (_image == null || _offset == null) {
      return;
    }
    Navigator.of(context).pop(_region());
  }

  /// Lays the frame out in [area] and, the first time, centres the picture.
  void _layout(Size area) {
    const double margin = 24;
    final double maxW = math.max(40, area.width - 2 * margin);
    final double maxH = math.max(40, area.height - 2 * margin);
    double fw = maxW;
    double fh = fw / widget.aspect;
    if (fh > maxH) {
      fh = maxH;
      fw = fh * widget.aspect;
    }
    final Rect frame = Rect.fromCenter(
      center: area.center(Offset.zero),
      width: fw,
      height: fh,
    );
    final Size image = _imageSize;
    final double fill = math.max(fw / image.width, fh / image.height);
    if (frame == _frame && fill == _fill && _offset != null) {
      return;
    }
    final Offset? old = _offset;
    // The middle of what was in the frame stays in the middle.
    final Offset middle = old == null
        ? image.center(Offset.zero)
        : (_frame.size.center(Offset.zero) - old) / _scale;
    _frame = frame;
    _fill = fill;
    _offset = _clamp(frame.size.center(Offset.zero) - middle * _scale, _scale);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ui.Image? image = _image;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.equal): () =>
            _zoomTo(_zoom * 1.25),
        const SingleActivator(LogicalKeyboardKey.add): () =>
            _zoomTo(_zoom * 1.25),
        const SingleActivator(LogicalKeyboardKey.numpadAdd): () =>
            _zoomTo(_zoom * 1.25),
        const SingleActivator(LogicalKeyboardKey.minus): () =>
            _zoomTo(_zoom / 1.25),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract): () =>
            _zoomTo(_zoom / 1.25),
        const SingleActivator(LogicalKeyboardKey.enter): _done,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('image-crop-screen'),
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(widget.title),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: FilledButton(
                  key: const Key('image-crop-done'),
                  onPressed: image == null ? null : _done,
                  child: Text(t('Gotowe')),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: image == null
                      ? Center(
                          child: _failed
                              ? const SizedBox.shrink()
                              : const CircularProgressIndicator(),
                        )
                      : LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints c) {
                            _layout(c.biggest);
                            final Offset offset = _offset!;
                            final Size shown = _imageSize * _scale;
                            return Listener(
                              onPointerSignal: _onPointerSignal,
                              child: GestureDetector(
                                key: const Key('image-crop-area'),
                                behavior: HitTestBehavior.opaque,
                                onScaleStart: _onScaleStart,
                                onScaleUpdate: _onScaleUpdate,
                                onDoubleTap: () =>
                                    _zoomTo(_zoom > 1.5 ? 1 : 2.5),
                                child: ClipRect(
                                  child: Stack(
                                    children: <Widget>[
                                      Positioned(
                                        left: _frame.left + offset.dx,
                                        top: _frame.top + offset.dy,
                                        width: shown.width,
                                        height: shown.height,
                                        child: RawImage(
                                          image: image,
                                          fit: BoxFit.fill,
                                          filterQuality: FilterQuality.medium,
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: CustomPaint(
                                            painter: _CropShade(
                                              frame: _frame,
                                              round: widget.round,
                                              edge: zen.accent,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.zoom_out_rounded,
                            color: Colors.white70,
                          ),
                          Expanded(
                            child: Slider(
                              key: const Key('image-crop-zoom'),
                              value: _zoom,
                              min: 1,
                              max: kCropMaxZoom,
                              label: t('Przybliżenie'),
                              onChanged: image == null ? null : _zoomTo,
                            ),
                          ),
                          const Icon(
                            Icons.zoom_in_rounded,
                            color: Colors.white70,
                          ),
                        ],
                      ),
                      Text(
                        t(
                          'Przesuń zdjęcie i przybliż je dwoma palcami, '
                          'kółkiem myszy albo suwakiem.',
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Darkens all but the [frame] (a circle in it when [round]) and draws its
/// edge, with thirds over a rectangular one.
class _CropShade extends CustomPainter {
  _CropShade({required this.frame, required this.round, required this.edge});

  final Rect frame;
  final bool round;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    final Path hole = round
        ? (Path()..addOval(frame))
        : (Path()..addRect(frame));
    final Path shade = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      hole,
    );
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: 0.62),
    );
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white;
    canvas.drawPath(hole, line);
    if (!round) {
      final Paint third = Paint()
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.35);
      for (int i = 1; i < 3; i++) {
        final double x = frame.left + frame.width * i / 3;
        final double y = frame.top + frame.height * i / 3;
        canvas
          ..drawLine(Offset(x, frame.top), Offset(x, frame.bottom), third)
          ..drawLine(Offset(frame.left, y), Offset(frame.right, y), third);
      }
    }
    if (round) {
      return;
    }
    // A short accent mark at each corner of the frame.
    final Paint corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = edge;
    final double k = math.min(18, frame.shortestSide / 4);
    for (final (Offset p, double dx, double dy) in <(Offset, double, double)>[
      (frame.topLeft, 1, 1),
      (frame.topRight, -1, 1),
      (frame.bottomLeft, 1, -1),
      (frame.bottomRight, -1, -1),
    ]) {
      canvas
        ..drawLine(p, p + Offset(k * dx, 0), corner)
        ..drawLine(p, p + Offset(0, k * dy), corner);
    }
  }

  @override
  bool shouldRepaint(_CropShade old) =>
      old.frame != frame || old.round != round || old.edge != edge;
}
