import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_materials.dart';
import 'package:zen/src/features/pebbles/design/pebble_shapes.dart';
import 'package:zen/src/features/pebbles/render/pebble_mesh.dart';
import 'package:zen/src/features/pebbles/render/pebble_renderer.dart';
import 'package:zen/src/features/pebbles/render/pebble_texture.dart';

/// How a stone on screen turns: dragged (with inertia), zoomed, turned to
/// show a face, or spun slowly on a turntable.
final class PebbleStageController extends ChangeNotifier {
  PebbleStageController({PebbleRotation? rotation})
    : _rotation = rotation ?? PebbleRotation.resting;

  PebbleRotation _rotation;
  double _zoom = 1;
  double _side = 300;

  // Inertia: the axis (view space) and speed in radians per second.
  double _ax = 0, _ay = 0, _speed = 0;
  PebbleRotation? _target;
  bool _turntable = false;

  /// No inertia, turntable or animated turns (the system asks for less
  /// motion).
  bool reduceMotion = false;

  PebbleRotation get rotation => _rotation;
  double get zoom => _zoom;
  bool get turntable => _turntable;

  /// Something moves on its own and needs frames.
  bool get animating => _speed > 0 || _target != null || _turntable;

  set rotation(PebbleRotation r) {
    _rotation = r;
    _speed = 0;
    _target = null;
    notifyListeners();
  }

  set turntable(bool on) {
    _turntable = on && !reduceMotion;
    notifyListeners();
  }

  set zoom(double z) {
    _zoom = z.clamp(0.6, 2.4);
    notifyListeners();
  }

  /// Turns the stone as if the finger moved it by [delta] (pixels).
  void rotateBy(Offset delta) {
    final double len = delta.distance;
    if (len == 0) {
      return;
    }
    _speed = 0;
    _target = null;
    _rotation = PebbleRotation.axisAngle(
      delta.dy,
      delta.dx,
      0,
      len / (_side * 0.43 * _zoom),
    ).times(_rotation);
    notifyListeners();
  }

  /// Lets the stone keep turning after a drag released at [velocity].
  void fling(Offset velocity) {
    final double v = velocity.distance;
    if (reduceMotion || v < 60) {
      return;
    }
    _ax = velocity.dy / v;
    _ay = velocity.dx / v;
    _speed = math.min(v / (_side * 0.43 * _zoom), 14);
    notifyListeners();
  }

  /// Stops any turning on its own.
  void stop() {
    _speed = 0;
    _target = null;
  }

  /// Turns to look straight at [face].
  void showFace(int face) {
    final PebbleRotation to = PebbleRotation.facing(face);
    _speed = 0;
    if (reduceMotion) {
      _target = null;
      _rotation = to;
    } else {
      _target = to;
    }
    notifyListeners();
  }

  void _setSide(double side) => _side = side;

  /// Moves [dt] seconds on. Returns whether anything is still moving.
  bool tick(double dt) {
    bool moved = false;
    if (_speed > 0) {
      _rotation = PebbleRotation.axisAngle(
        _ax,
        _ay,
        0,
        _speed * dt,
      ).times(_rotation);
      _speed *= math.exp(-dt * 3.2);
      if (_speed < 0.08) {
        _speed = 0;
      }
      moved = true;
    }
    final PebbleRotation? target = _target;
    if (target != null) {
      _rotation = _rotation.slerp(target, 1 - math.exp(-dt * 11));
      if (_rotation.distance(target) < 0.004) {
        _rotation = target;
        _target = null;
      }
      moved = true;
    }
    if (_turntable && _target == null && _speed == 0) {
      _rotation = _rotation.times(PebbleRotation.axisAngle(0, 1, 0, dt * 0.9));
      moved = true;
    }
    if (moved) {
      notifyListeners();
    }
    return animating;
  }
}

/// What a finger on the stone does.
enum PebbleStageMode {
  /// Drag turns, pinch zooms.
  rotate,

  /// One finger paints (the callbacks get the surface point under it, or
  /// null off the stone); two fingers turn and zoom.
  paint,

  /// A tap puts something on the stone; drag turns.
  tap,
}

/// A stone mesh with its texture on screen, turned by [controller].
class PebbleStage extends StatefulWidget {
  const PebbleStage({
    required this.mesh,
    required this.finish,
    required this.tint,
    required this.texture,
    required this.atlas,
    required this.controller,
    this.mode = PebbleStageMode.rotate,
    this.interactive = true,
    this.shadow = true,
    this.onPaintStart,
    this.onPaintMove,
    this.onPaintEnd,
    this.onPaintCancel,
    this.onTap,
    super.key,
  });

  final PebbleMesh mesh;
  final PebbleFinish finish;
  final int tint;
  final ui.Image texture;
  final PebbleAtlas atlas;
  final PebbleStageController controller;
  final PebbleStageMode mode;
  final bool interactive;
  final bool shadow;
  final ValueChanged<PebbleSurfacePoint?>? onPaintStart;
  final ValueChanged<PebbleSurfacePoint?>? onPaintMove;
  final VoidCallback? onPaintEnd;
  final VoidCallback? onPaintCancel;
  final ValueChanged<PebbleSurfacePoint>? onTap;

  @override
  State<PebbleStage> createState() => PebbleStageState();
}

class PebbleStageState extends State<PebbleStage>
    with SingleTickerProviderStateMixin {
  late PebbleRenderer _renderer = _make();
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  bool _painting = false;
  double _lastScale = 1;

  PebbleRenderer _make() => PebbleRenderer(
    widget.mesh,
    widget.finish,
    widget.atlas,
    tint: widget.tint,
  );

  /// The renderer drawing this stone (tests pick through it).
  PebbleRenderer get renderer => _renderer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.controller.reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.controller.reduceMotion) {
      widget.controller.turntable = false;
    }
  }

  @override
  void didUpdateWidget(PebbleStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final PebbleStage old = oldWidget;
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (!identical(old.mesh, widget.mesh) ||
        old.finish != widget.finish ||
        old.tint != widget.tint ||
        old.atlas != widget.atlas) {
      _renderer = _make();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _ticker.dispose();
    super.dispose();
  }

  void _changed() {
    if (widget.controller.animating && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final double dt = _last == Duration.zero
        ? 1 / 60
        : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (!widget.controller.tick(dt.clamp(0.0, 0.1))) {
      _ticker.stop();
    }
  }

  PebbleSurfacePoint? _pick(Offset local) => _renderer.pick(local);

  void _scaleStart(ScaleStartDetails d) {
    widget.controller.stop();
    _lastScale = 1;
    if (widget.mode == PebbleStageMode.paint && d.pointerCount == 1) {
      _painting = true;
      widget.onPaintStart?.call(_pick(d.localFocalPoint));
    }
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    if (_painting) {
      if (d.pointerCount == 1) {
        widget.onPaintMove?.call(_pick(d.localFocalPoint));
        return;
      }
      _painting = false;
      widget.onPaintCancel?.call();
    }
    widget.controller.rotateBy(d.focalPointDelta);
    if (d.pointerCount > 1 && d.scale > 0) {
      widget.controller.zoom = widget.controller.zoom * d.scale / _lastScale;
      _lastScale = d.scale;
    }
  }

  void _scaleEnd(ScaleEndDetails d) {
    if (_painting) {
      _painting = false;
      widget.onPaintEnd?.call();
      return;
    }
    widget.controller.fling(d.velocity.pixelsPerSecond);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      widget.controller._setSide(box.biggest.shortestSide);
      final Widget paint = CustomPaint(
        painter: _StagePainter(
          renderer: _renderer,
          texture: widget.texture,
          controller: widget.controller,
          shadow: widget.shadow,
        ),
        child: const SizedBox.expand(),
      );
      if (!widget.interactive) {
        return paint;
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onScaleStart: _scaleStart,
        onScaleUpdate: _scaleUpdate,
        onScaleEnd: _scaleEnd,
        onTapUp: widget.mode == PebbleStageMode.tap
            ? (TapUpDetails d) {
                final PebbleSurfacePoint? p = _pick(d.localPosition);
                if (p != null) {
                  widget.onTap?.call(p);
                }
              }
            : null,
        child: paint,
      );
    },
  );
}

class _StagePainter extends CustomPainter {
  _StagePainter({
    required this.renderer,
    required this.texture,
    required this.controller,
    required this.shadow,
  }) : super(repaint: controller);

  final PebbleRenderer renderer;
  final ui.Image texture;
  final PebbleStageController controller;
  final bool shadow;

  @override
  void paint(Canvas canvas, Size size) {
    renderer.paint(
      canvas,
      Offset.zero & size,
      controller.rotation,
      texture,
      zoom: controller.zoom,
      shadow: shadow,
    );
  }

  @override
  bool shouldRepaint(_StagePainter old) =>
      !identical(old.renderer, renderer) ||
      !identical(old.texture, texture) ||
      old.shadow != shadow;
}

/// A pebble drawn as a 3D stone: from its full [design] when there is one,
/// otherwise from the card's look and thumbnail. [interactive] lets the
/// viewer turn it (with inertia) and pinch to zoom.
class PebbleView extends StatefulWidget {
  const PebbleView({
    required this.design,
    required this.card,
    this.size = 120,
    this.interactive = false,
    super.key,
  });

  final Uint8List? design;
  final PebbleLookSource card;
  final double size;
  final bool interactive;

  @override
  State<PebbleView> createState() => _PebbleViewState();
}

class _PebbleViewState extends State<PebbleView> {
  final PebbleStageController _controller = PebbleStageController();
  late PebbleDesign _design;
  ui.Image? _texture;
  PebbleAtlas _atlas = PebbleAtlas.small;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PebbleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final PebbleView old = oldWidget;
    if (!listEquals(old.design, widget.design) ||
        old.card.look != widget.card.look ||
        !listEquals(old.card.thumbnail, widget.card.thumbnail) ||
        (old.size > 200) != (widget.size > 200)) {
      _load();
    }
  }

  void _load() {
    _atlas = widget.size > 200 ? PebbleAtlas.large : PebbleAtlas.small;
    final PebbleDesign? full = PebbleDesign.tryDecode(widget.design);
    final PebbleCardLook look = widget.card.look;
    _design =
        full ??
        PebbleDesign.stone(
          shape: look.shape < PebbleShapePreset.values.length ? look.shape : 0,
          seed: look.seed,
          material: look.material,
        ).copyWith(
          mainColour: look.mainColour | 0xFF000000,
          secondColour: look.secondColour | 0xFF000000,
        );
    final ui.Image? old = _texture;
    _texture = PebbleTextures.of(
      _design,
      _atlas,
      thumbnail: full == null
          ? PebbleThumbnail.decode(widget.card.thumbnail)
          : null,
    );
    old?.dispose();
  }

  @override
  void dispose() {
    _texture?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    hint: widget.interactive ? t('Przeciągnij, żeby obrócić kamyczek') : null,
    child: SizedBox.square(
      dimension: widget.size,
      child: PebbleStage(
        mesh: PebbleMesh.of(PebbleShapeKey.of(_design)),
        finish: _design.finish,
        tint: _design.mainColour,
        texture: _texture!,
        atlas: _atlas,
        controller: _controller,
        interactive: widget.interactive,
      ),
    ),
  );
}
