import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_fonts.dart';
import 'package:zen/src/features/pebbles/design/pebble_materials.dart';
import 'package:zen/src/features/pebbles/design/pebble_patterns.dart';
import 'package:zen/src/features/pebbles/design/pebble_ready_designs.dart';
import 'package:zen/src/features/pebbles/design/pebble_shapes.dart';
import 'package:zen/src/features/pebbles/design/pebble_stamps.dart';
import 'package:zen/src/features/pebbles/render/pebble_mesh.dart';
import 'package:zen/src/features/pebbles/render/pebble_renderer.dart';
import 'package:zen/src/features/pebbles/render/pebble_texture.dart';
import 'package:zen/src/features/pebbles/render/pebble_thumbnail.dart';
import 'package:zen/src/features/pebbles/render/pebble_view.dart';

/// What the editor hands back: the design's bytes, the card's look and the
/// card's 176-byte thumbnail.
typedef PebbleEditorResult = (
  Uint8List design,
  PebbleCardLook look,
  Uint8List thumbnail,
);

/// The tools of the editor.
enum PebbleTool {
  rotate,
  brush,
  spray,
  fill,
  eraser,
  stamp,
  text,
  pattern,
  stone,
  ready;

  String get label => switch (this) {
    rotate => t('Obracaj'),
    brush => t('Pędzel'),
    spray => t('Spray'),
    fill => t('Wypełnij'),
    eraser => t('Gumka'),
    stamp => t('Naklejki'),
    text => t('Napis'),
    pattern => t('Wzory'),
    stone => t('Kamień'),
    ready => t('Gotowe wzory'),
  };

  IconData get icon => switch (this) {
    rotate => Icons.threesixty_rounded,
    brush => Icons.brush_rounded,
    spray => Icons.blur_on_rounded,
    fill => Icons.format_color_fill_rounded,
    eraser => Icons.auto_fix_normal_rounded,
    stamp => Icons.emoji_emotions_rounded,
    text => Icons.text_fields_rounded,
    pattern => Icons.texture_rounded,
    stone => Icons.landscape_rounded,
    ready => Icons.auto_awesome_rounded,
  };

  PebbleStageMode get mode => switch (this) {
    brush || spray || eraser => PebbleStageMode.paint,
    fill || stamp || text => PebbleStageMode.tap,
    _ => PebbleStageMode.rotate,
  };
}

/// The quick face buttons: one face, or the four sides together.
enum _FaceChoice {
  top,
  bottom,
  front,
  back,
  sides;

  String get label => switch (this) {
    top => t('Góra'),
    bottom => t('Dół'),
    front => t('Przód'),
    back => t('Tył'),
    sides => t('Boki'),
  };

  List<int> get faces => switch (this) {
    top => <int>[PebbleFace.top.index],
    bottom => <int>[PebbleFace.bottom.index],
    front => <int>[PebbleFace.front.index],
    back => <int>[PebbleFace.back.index],
    sides => <int>[
      PebbleFace.front.index,
      PebbleFace.right.index,
      PebbleFace.back.index,
      PebbleFace.left.index,
    ],
  };
}

/// Brush radii in 1/256 of a face unit.
const List<int> _brushSizes = <int>[4, 8, 14, 22, 34];

/// The pebble editor: a 3D stone to turn and paint on every side (top,
/// bottom and sides), with brushes, spray, fills, an eraser, mirror
/// painting, stamps, text along the surface, patterns per face, stone
/// shapes and materials, ready designs and "Losuj". [open] returns the
/// design, the card's look and its thumbnail, or null when left without
/// finishing.
class PebbleEditorScreen extends StatefulWidget {
  const PebbleEditorScreen({this.startFrom, super.key});

  /// A design to start from (bytes of [PebbleDesign.encode]).
  final Uint8List? startFrom;

  static Future<PebbleEditorResult?> open(
    BuildContext context, {
    Uint8List? startFrom,
  }) => Navigator.of(context).push<PebbleEditorResult>(
    MaterialPageRoute<PebbleEditorResult>(
      builder: (BuildContext context) =>
          PebbleEditorScreen(startFrom: startFrom),
    ),
  );

  @override
  State<PebbleEditorScreen> createState() => PebbleEditorState();
}

class PebbleEditorState extends State<PebbleEditorScreen> {
  static const PebbleAtlas _atlas = PebbleAtlas.large;
  static const int _maxUndo = 80;

  late PebbleDesign _design;
  final List<PebbleDesign> _undo = <PebbleDesign>[];
  final List<PebbleDesign> _redo = <PebbleDesign>[];
  final PebbleStageController _stage = PebbleStageController();
  final TextEditingController _textField = TextEditingController();

  late ui.Image _base;
  late ui.Image _committed;
  ui.Image? _live;

  PebbleTool _tool = PebbleTool.rotate;
  _FaceChoice _faces = _FaceChoice.top;
  int _colour = 0xFF1A1A1A;
  int _colour2 = 0;
  int _size = 2;
  bool _mirror = false;
  bool _wholeFace = false;
  int _stamp = PebbleStampIds.heart;
  bool _natural = true;
  double _stampSize = 0.3;
  double _stampAngle = 0;
  double _textSize = 0.28;
  int _curve = 0;
  int _font = 0;
  int _pattern = 0;
  double _patternScale = 40;
  bool _busy = false;

  // The stroke being painted.
  int _liveFace = -1;
  final List<int> _livePoints = <int>[];
  bool _strokeStarted = false;

  /// The design as it stands (tests).
  @visibleForTesting
  PebbleDesign get design => _design;

  /// The stone's turn (tests).
  @visibleForTesting
  PebbleStageController get stage => _stage;

  @override
  void initState() {
    super.initState();
    _design =
        PebbleDesign.tryDecode(widget.startFrom) ??
        PebbleDesign.stone(
          shape: PebbleShapePreset.river.index,
          material: PebbleMaterial.greyRiver.index,
        );
    _base = PebbleTextures.base(_design, _atlas);
    _committed = PebbleTextures.of(_design, _atlas);
    _textField.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _live?.dispose();
    _committed.dispose();
    _base.dispose();
    _stage.dispose();
    _textField.dispose();
    super.dispose();
  }

  // ---- Changing the design

  void _pushUndo() {
    _undo.add(_design);
    if (_undo.length > _maxUndo) {
      _undo.removeAt(0);
    }
    _redo.clear();
  }

  /// Replaces the whole design (shape, material, ready designs, undo).
  void _replace(PebbleDesign next, {bool undoable = true}) {
    if (undoable) {
      _pushUndo();
    }
    final bool baseChanged =
        next.material != _design.material ||
        next.mainColour != _design.mainColour ||
        next.secondColour != _design.secondColour ||
        next.seed != _design.seed;
    _design = next;
    if (baseChanged) {
      _base.dispose();
      _base = PebbleTextures.base(_design, _atlas);
    }
    _committed.dispose();
    _committed = PebbleTextures.of(_design, _atlas);
    setState(() {});
  }

  /// Adds [ops] as one step (one undo).
  bool _add(List<PebbleOp> ops, {bool undoable = true}) {
    PebbleDesign next = _design;
    for (final PebbleOp op in ops) {
      if (!next.canAdd(op)) {
        _say(t('Kamyczek jest już pełny — cofnij coś albo zacznij od nowa.'));
        return false;
      }
      next = next.withOp(op);
    }
    if (undoable) {
      _pushUndo();
    }
    ui.Image image = _committed;
    PebbleDesign at = _design;
    for (final PebbleOp op in ops) {
      final ui.Image drawn = PebbleTextures.overlay(
        image,
        at,
        op,
        _atlas,
        base: _base,
      );
      if (!identical(image, _committed)) {
        image.dispose();
      }
      image = drawn;
      at = at.withOp(op);
    }
    _committed.dispose();
    _committed = image;
    _design = next;
    setState(() {});
    return true;
  }

  void _undoStep() {
    if (_undo.isEmpty) {
      return;
    }
    _redo.add(_design);
    _replace(_undo.removeLast(), undoable: false);
  }

  void _redoStep() {
    if (_redo.isEmpty) {
      return;
    }
    _undo.add(_design);
    _replace(_redo.removeLast(), undoable: false);
  }

  void _say(String text) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ---- Painting strokes

  PebbleStrokeTool get _strokeTool => switch (_tool) {
    PebbleTool.spray => PebbleStrokeTool.spray,
    PebbleTool.eraser => PebbleStrokeTool.eraser,
    _ => PebbleStrokeTool.brush,
  };

  int get _brushRadius =>
      _brushSizes[_size] * (_tool == PebbleTool.spray ? 3 : 1);

  PebbleStroke? _liveStroke() => _livePoints.length < 2
      ? null
      : PebbleStroke(
          tool: _strokeTool,
          colour: _colour,
          size: _brushRadius.clamp(1, 255),
          face: _liveFace,
          points: Uint16List.fromList(_livePoints),
          mirror: _mirror,
        );

  void _paintStart(PebbleSurfacePoint? p) {
    _livePoints.clear();
    _liveFace = -1;
    _strokeStarted = false;
    if (p != null) {
      _paintMove(p);
    }
  }

  void _paintMove(PebbleSurfacePoint? p) {
    if (p == null) {
      return;
    }
    if (_liveFace < 0) {
      _liveFace = p.face;
      _livePoints
        ..add(PebbleQ.of(p.s))
        ..add(PebbleQ.of(p.t));
      _showLive();
      return;
    }
    double s = p.s, t = p.t;
    if (p.face != _liveFace) {
      // Carry on in the stroke's own face while the finger is just over
      // the seam; further on, finish this part and go on from the new face.
      final bool near = PebbleFaces.neighbours(p.face).contains(_liveFace);
      if (near) {
        (s, t) = PebbleFaces.unfold(p.face, _liveFace).apply(p.s, p.t);
      }
      final bool corner = s.abs() > 1.05 && t.abs() > 1.05;
      if (!near || corner || s.abs() > 1.6 || t.abs() > 1.6) {
        _splitStroke(p, near);
        return;
      }
    }
    final int qs = PebbleQ.of(s), qt = PebbleQ.of(t);
    final int n = _livePoints.length;
    final double minStep = math.max(4.0, _brushRadius * 4 * 0.2);
    final int ds = qs - _livePoints[n - 2], dt = qt - _livePoints[n - 1];
    if (ds * ds + dt * dt < minStep * minStep) {
      return;
    }
    _livePoints
      ..add(qs)
      ..add(qt);
    if (_livePoints.length >= PebbleDesign.maxStrokePoints * 2) {
      _splitStroke(p, true);
      return;
    }
    _showLive();
  }

  void _splitStroke(PebbleSurfacePoint p, bool near) {
    final int lastS = _livePoints[_livePoints.length - 2];
    final int lastT = _livePoints[_livePoints.length - 1];
    final int from = _liveFace;
    _commitStroke();
    _liveFace = p.face;
    _livePoints.clear();
    if (near && from != p.face) {
      final (double s, double t) = PebbleFaces.unfold(
        from,
        p.face,
      ).apply(PebbleQ.value(lastS), PebbleQ.value(lastT));
      _livePoints
        ..add(PebbleQ.of(s))
        ..add(PebbleQ.of(t));
    } else if (from == p.face) {
      _livePoints
        ..add(lastS)
        ..add(lastT);
    }
    _livePoints
      ..add(PebbleQ.of(p.s))
      ..add(PebbleQ.of(p.t));
    _showLive();
  }

  void _showLive() {
    final PebbleStroke? stroke =
        _liveStroke() ??
        (_livePoints.length == 2
            ? PebbleStroke(
                tool: _strokeTool,
                colour: _colour,
                size: _brushRadius.clamp(1, 255),
                face: _liveFace,
                points: Uint16List.fromList(_livePoints),
                mirror: _mirror,
              )
            : null);
    if (stroke == null) {
      return;
    }
    final ui.Image next = PebbleTextures.overlay(
      _committed,
      _design,
      stroke,
      _atlas,
      base: _base,
    );
    _live?.dispose();
    setState(() => _live = next);
  }

  /// Keeps the stroke so far as a design step (the first part of a gesture
  /// opens one undo step for all its parts).
  void _commitStroke() {
    final PebbleStroke? stroke = _livePoints.length >= 2
        ? PebbleStroke(
            tool: _strokeTool,
            colour: _colour,
            size: _brushRadius.clamp(1, 255),
            face: _liveFace,
            points: Uint16List.fromList(_livePoints),
            mirror: _mirror,
          )
        : null;
    final ui.Image? live = _live;
    _live = null;
    if (stroke == null) {
      live?.dispose();
      return;
    }
    if (!_design.canAdd(stroke)) {
      live?.dispose();
      _say(t('Kamyczek jest już pełny — cofnij coś albo zacznij od nowa.'));
      setState(() {});
      return;
    }
    if (!_strokeStarted) {
      _pushUndo();
      _strokeStarted = true;
    }
    _design = _design.withOp(stroke);
    if (live != null) {
      _committed.dispose();
      _committed = live;
    } else {
      final ui.Image drawn = PebbleTextures.overlay(
        _committed,
        _design,
        stroke,
        _atlas,
        base: _base,
      );
      _committed.dispose();
      _committed = drawn;
    }
    setState(() {});
  }

  void _paintEnd() {
    _commitStroke();
    _livePoints.clear();
    _liveFace = -1;
    _strokeStarted = false;
  }

  void _paintCancel() {
    _live?.dispose();
    _live = null;
    _livePoints.clear();
    _liveFace = -1;
    _strokeStarted = false;
    setState(() {});
  }

  // ---- Tapping

  void _tap(PebbleSurfacePoint p) {
    final int qs = PebbleQ.of(p.s), qt = PebbleQ.of(p.t);
    switch (_tool) {
      case PebbleTool.fill:
        _add(<PebbleOp>[
          if (_wholeFace)
            PebbleFaceFill(face: p.face, colour: _colour)
          else
            PebbleRegionFill(face: p.face, s: qs, t: qt, colour: _colour),
        ]);
      case PebbleTool.stamp:
        _add(<PebbleOp>[
          PebbleStampOp(
            stamp: _stamp,
            face: p.face,
            s: qs,
            t: qt,
            size: (_stampSize * 200).round().clamp(1, 255),
            angle: ((_stampAngle / 360) * 256).round() & 0xFF,
            colour: _natural ? 0 : _colour,
            mirror: _mirror,
          ),
        ]);
      case PebbleTool.text:
        final String text = _textField.text.trim();
        if (text.isEmpty) {
          _say(t('Najpierw wpisz napis.'));
          return;
        }
        _add(<PebbleOp>[
          PebbleTextOp(
            face: p.face,
            s: qs,
            t: qt,
            size: (_textSize * 200).round().clamp(1, 255),
            text: text,
            colour: _colour,
            curve: _curve,
            font: _font,
          ),
        ]);
      default:
        break;
    }
  }

  void _pickFaces(_FaceChoice choice) {
    if (choice == _faces && choice == _FaceChoice.sides) {
      // "Boki" again: the next side.
      final List<int> sides = choice.faces;
      final int at = sides.indexOf(_sideShown);
      _sideShown = sides[(at + 1) % sides.length];
    } else if (choice == _FaceChoice.sides) {
      _sideShown = PebbleFace.front.index;
    }
    setState(() => _faces = choice);
    _stage.showFace(
      choice == _FaceChoice.sides ? _sideShown : choice.faces.first,
    );
  }

  int _sideShown = PebbleFace.front.index;

  void _applyPattern() => _add(<PebbleOp>[
    for (final int f in _faces.faces)
      PebblePatternOp(
        face: f,
        pattern: _pattern,
        colour: _colour,
        colour2: _colour2,
        scale: _patternScale.round().clamp(1, 255),
      ),
  ]);

  void _fillFaces() => _add(<PebbleOp>[
    for (final int f in _faces.faces) PebbleFaceFill(face: f, colour: _colour),
  ]);

  void _random() {
    final int seed = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
    _replace(pebbleRandomDesign(seed));
  }

  Future<void> _finish() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final PebbleDesign d = _design;
      final Uint8List bytes = d.encode();
      final Uint8List thumbnail = await pebbleThumbnail(d);
      final (int, int)? colours = thumbnailColours(thumbnail);
      final PebbleCardLook base = d.look;
      final PebbleCardLook look = PebbleCardLook(
        shape: base.shape,
        seed: base.seed,
        material: base.material,
        mainColour: colours?.$1 ?? base.mainColour,
        secondColour: colours?.$2 ?? base.secondColour,
      );
      if (mounted) {
        Navigator.of(context).pop<PebbleEditorResult>((bytes, look, thumbnail));
      }
    } on Object catch (error, stack) {
      logZenError('Finishing the pebble', error, stack);
      _say(t('Nie udało się przygotować kamyczka.'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _confirmLeave() async {
    if (_undo.isEmpty) {
      return true;
    }
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Porzucić kamyczek?')),
        content: Text(t('Malowanie nie zostanie zapisane.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Maluj dalej')),
          ),
          TextButton(
            key: const Key('pebble-leave'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Porzuć')),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  // ---- Sheets

  Future<void> _pickStamp() async {
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (BuildContext context, ScrollController scroll) => ListView(
          key: const Key('pebble-stamps'),
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          children: <Widget>[
            for (final PebbleStampCategory c
                in PebbleStampCategory.values) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                child: Text(
                  c.label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final int id in PebbleStamps.inCategory(c))
                    _StampButton(
                      key: Key('pebble-stamp-$id'),
                      id: id,
                      onTap: () => Navigator.of(context).pop(id),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _stamp = picked);
    }
  }

  // ---- Building

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final double height = MediaQuery.sizeOf(context).height;
    final ui.Image texture = _live ?? _committed;
    return PopScope<PebbleEditorResult>(
      canPop: _undo.isEmpty || _busy,
      onPopInvokedWithResult: (bool didPop, PebbleEditorResult? result) async {
        if (didPop) {
          return;
        }
        final NavigatorState nav = Navigator.of(context);
        if (await _confirmLeave() && mounted) {
          _undo.clear();
          nav.pop();
        }
      },
      child: Scaffold(
        key: const Key('pebble-editor'),
        appBar: AppBar(
          title: Text(t('Kamyczek')),
          actions: <Widget>[
            IconButton(
              key: const Key('pebble-undo'),
              tooltip: t('Cofnij'),
              onPressed: _undo.isEmpty ? null : _undoStep,
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              key: const Key('pebble-redo'),
              tooltip: t('Ponów'),
              onPressed: _redo.isEmpty ? null : _redoStep,
              icon: const Icon(Icons.redo_rounded),
            ),
            IconButton(
              key: const Key('pebble-done'),
              tooltip: t('Gotowe'),
              onPressed: _busy ? null : () => unawaited(_finish()),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  label: t('Kamyczek do malowania'),
                  hint: switch (_tool.mode) {
                    PebbleStageMode.paint => t(
                      'Maluj jednym palcem, obracaj dwoma.',
                    ),
                    PebbleStageMode.tap => t(
                      'Dotknij kamyczka, żeby coś na nim umieścić.',
                    ),
                    PebbleStageMode.rotate => t(
                      'Przeciągnij, żeby obrócić kamyczek',
                    ),
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 120),
                    child: PebbleStage(
                      key: const Key('pebble-stage'),
                      mesh: PebbleMesh.of(PebbleShapeKey.of(_design)),
                      finish: _design.finish,
                      tint: _design.mainColour,
                      texture: texture,
                      atlas: _atlas,
                      controller: _stage,
                      mode: _tool.mode,
                      onPaintStart: _paintStart,
                      onPaintMove: _paintMove,
                      onPaintEnd: _paintEnd,
                      onPaintCancel: _paintCancel,
                      onTap: _tap,
                    ),
                  ),
                ),
              ),
              _strip(<Widget>[
                for (final _FaceChoice f in _FaceChoice.values)
                  ChoiceChip(
                    key: Key('pebble-face-${f.name}'),
                    label: Text(f.label),
                    selected: f == _faces,
                    onSelected: (_) => _pickFaces(f),
                  ),
                if (!still)
                  FilterChip(
                    key: const Key('pebble-turntable'),
                    avatar: const Icon(Icons.threed_rotation_rounded, size: 18),
                    label: Text(t('Podgląd')),
                    selected: _stage.turntable,
                    onSelected: (bool on) =>
                        setState(() => _stage.turntable = on),
                  ),
              ]),
              _strip(<Widget>[
                for (final PebbleTool tool in PebbleTool.values)
                  ChoiceChip(
                    key: Key('pebble-tool-${tool.name}'),
                    avatar: Icon(tool.icon, size: 18),
                    label: Text(tool.label),
                    selected: tool == _tool,
                    onSelected: (_) => setState(() {
                      _tool = tool;
                      _paintCancel();
                    }),
                  ),
                ActionChip(
                  key: const Key('pebble-random'),
                  avatar: const Icon(Icons.casino_rounded, size: 18),
                  label: Text(t('Losuj')),
                  onPressed: _random,
                ),
              ]),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(150, height * 0.34),
                ),
                child: Material(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: SingleChildScrollView(
                    key: const Key('pebble-options'),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: _options(theme),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _strip(List<Widget> children) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      children: <Widget>[
        for (final Widget c in children)
          Padding(padding: const EdgeInsets.only(right: 6), child: c),
      ],
    ),
  );

  Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
    child: Text(text, style: theme.textTheme.labelLarge),
  );

  /// The typefaces, each showing the words typed (or its own name) in
  /// itself, the chosen one larger above them in the chosen colour.
  Widget _fontPicker(ThemeData theme) {
    final String typed = _textField.text.trim();
    final PebbleFont chosen = PebbleFont.byId(_font);
    TextStyle style(PebbleFont f, double size) =>
        TextStyle(fontFamily: f.family, fontWeight: f.weight, fontSize: size);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          key: const Key('pebble-font-preview'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            // A pale stone, so the words show in any colour.
            color: const Color(0xFFE6E0D4),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            typed.isEmpty ? t('Twój napis') : typed,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style(chosen, 30).copyWith(color: Color(_colour)),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          key: const Key('pebble-fonts'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final PebbleFont f in PebbleFont.values)
              ChoiceChip(
                key: Key('pebble-font-${f.index}'),
                tooltip: f.label,
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    typed.isEmpty ? f.label : typed,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(f, 17),
                  ),
                ),
                selected: f.index == _font,
                onSelected: (_) => setState(() => _font = f.index),
              ),
          ],
        ),
      ],
    );
  }

  Widget _colours(
    ThemeData theme,
    int selected,
    ValueChanged<int> pick, {
    bool none = false,
  }) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: <Widget>[
      if (none)
        _Swatch(
          key: const Key('pebble-colour2-none'),
          colour: 0,
          selected: selected == 0,
          label: t('Bez drugiego koloru'),
          onTap: () => pick(0),
        ),
      for (final (int i, int c) in pebblePaintColours.indexed)
        _Swatch(
          key: Key('pebble-${none ? 'colour2' : 'colour'}-$i'),
          colour: c,
          selected: c == selected,
          label: t('Kolor {n}', <String, Object?>{'n': i + 1}),
          onTap: () => pick(c),
        ),
    ],
  );

  Widget _slider(
    String key,
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> changed, {
    ValueChanged<double>? done,
  }) => Row(
    children: <Widget>[
      Flexible(child: Text(label)),
      Expanded(
        flex: 2,
        child: Slider(
          key: Key('pebble-$key'),
          value: value.clamp(min, max),
          min: min,
          max: max,
          label: label,
          onChanged: changed,
          onChangeEnd: done,
        ),
      ),
    ],
  );

  Widget _mirrorSwitch() => SwitchListTile(
    key: const Key('pebble-mirror'),
    contentPadding: EdgeInsets.zero,
    secondary: const Icon(Icons.flip_rounded),
    title: Text(t('Lustro (maluje też drugą stronę)')),
    value: _mirror,
    onChanged: (bool v) => setState(() => _mirror = v),
  );

  Widget _options(ThemeData theme) {
    final List<Widget> rows = switch (_tool) {
      PebbleTool.rotate => <Widget>[
        Text(
          t(
            'Przeciągnij, żeby obrócić kamyczek, dwoma palcami przybliżysz. '
            'Wybierz narzędzie i maluj na górze, dole i bokach.',
          ),
        ),
      ],
      PebbleTool.brush || PebbleTool.spray || PebbleTool.eraser => <Widget>[
        _label(theme, t('Rozmiar')),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (int i = 0; i < _brushSizes.length; i++)
              ChoiceChip(
                key: Key('pebble-size-$i'),
                tooltip: t('Rozmiar {n}', <String, Object?>{'n': i + 1}),
                label: Icon(Icons.circle, size: 6.0 + i * 4),
                selected: i == _size,
                onSelected: (_) => setState(() => _size = i),
              ),
          ],
        ),
        if (_tool != PebbleTool.eraser) ...<Widget>[
          _label(theme, t('Kolor')),
          _colours(theme, _colour, (int c) => setState(() => _colour = c)),
        ],
        _mirrorSwitch(),
      ],
      PebbleTool.fill => <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            ChoiceChip(
              key: const Key('pebble-fill-region'),
              label: Text(t('Obszar')),
              selected: !_wholeFace,
              onSelected: (_) => setState(() => _wholeFace = false),
            ),
            ChoiceChip(
              key: const Key('pebble-fill-face'),
              label: Text(t('Cała ściana')),
              selected: _wholeFace,
              onSelected: (_) => setState(() => _wholeFace = true),
            ),
          ],
        ),
        _label(theme, t('Kolor')),
        _colours(theme, _colour, (int c) => setState(() => _colour = c)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('pebble-fill-faces'),
          onPressed: _fillFaces,
          icon: const Icon(Icons.format_color_fill_rounded),
          label: Text(
            t('Pomaluj: {faces}', <String, Object?>{'faces': _faces.label}),
          ),
        ),
      ],
      PebbleTool.stamp => <Widget>[
        Row(
          children: <Widget>[
            _StampButton(id: _stamp, onTap: () => unawaited(_pickStamp())),
            const SizedBox(width: 8),
            Flexible(
              child: OutlinedButton(
                key: const Key('pebble-stamp-pick'),
                onPressed: () => unawaited(_pickStamp()),
                child: Text(t('Wybierz naklejkę')),
              ),
            ),
          ],
        ),
        _slider(
          'stamp-size',
          t('Wielkość'),
          _stampSize,
          0.06,
          1,
          (double v) => setState(() => _stampSize = v),
        ),
        _slider(
          'stamp-angle',
          t('Obrót'),
          _stampAngle,
          0,
          359,
          (double v) => setState(() => _stampAngle = v),
        ),
        SwitchListTile(
          key: const Key('pebble-natural'),
          contentPadding: EdgeInsets.zero,
          title: Text(t('Własne kolory naklejki')),
          value: _natural,
          onChanged: (bool v) => setState(() => _natural = v),
        ),
        if (!_natural)
          _colours(theme, _colour, (int c) => setState(() => _colour = c)),
        _mirrorSwitch(),
      ],
      PebbleTool.text => <Widget>[
        TextField(
          key: const Key('pebble-text'),
          controller: _textField,
          maxLength: 30,
          inputFormatters: <TextInputFormatter>[
            TextInputFormatter.withFunction(
              (TextEditingValue old, TextEditingValue next) =>
                  utf8.encode(next.text).length > PebbleTextOp.maxBytes
                  ? old
                  : next,
            ),
          ],
          // The typefaces below show what is typed.
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t('Napis'),
            helperText: t('Potem dotknij kamyczka, żeby go umieścić.'),
          ),
        ),
        _slider(
          'text-size',
          t('Wielkość'),
          _textSize,
          0.08,
          0.8,
          (double v) => setState(() => _textSize = v),
        ),
        _slider(
          'text-curve',
          t('Wygięcie'),
          _curve.toDouble(),
          -100,
          100,
          (double v) => setState(() => _curve = v.round()),
        ),
        _label(theme, t('Krój pisma')),
        _fontPicker(theme),
        _label(theme, t('Kolor')),
        _colours(theme, _colour, (int c) => setState(() => _colour = c)),
      ],
      PebbleTool.pattern => <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final PebblePattern p in PebblePattern.values)
              ChoiceChip(
                key: Key('pebble-pattern-${p.name}'),
                label: Text(p.label),
                selected: p.index == _pattern,
                onSelected: (_) => setState(() => _pattern = p.index),
              ),
          ],
        ),
        _slider(
          'pattern-scale',
          t('Wielkość wzoru'),
          _patternScale,
          4,
          160,
          (double v) => setState(() => _patternScale = v),
        ),
        _label(theme, t('Kolor')),
        _colours(theme, _colour, (int c) => setState(() => _colour = c)),
        _label(theme, t('Drugi kolor')),
        _colours(
          theme,
          _colour2,
          (int c) => setState(() => _colour2 = c),
          none: true,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('pebble-pattern-apply'),
          onPressed: _applyPattern,
          icon: const Icon(Icons.texture_rounded),
          label: Text(
            t('Nałóż wzór: {faces}', <String, Object?>{'faces': _faces.label}),
          ),
        ),
      ],
      PebbleTool.stone => _stoneOptions(theme),
      PebbleTool.ready => <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final PebbleReadyDesign r in PebbleReadyDesign.values)
              _Choice(
                key: Key('pebble-ready-${r.name}'),
                label: r.label,
                onTap: () => _replace(r.build()),
                child: _MiniStone(design: r.build()),
              ),
          ],
        ),
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  List<Widget> _stoneOptions(ThemeData theme) => <Widget>[
    _label(theme, t('Kształt')),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final PebbleShapePreset s in PebbleShapePreset.values)
          _Choice(
            key: Key('pebble-shape-${s.name}'),
            label: s.label,
            selected: s.index == _design.shape,
            onTap: () => _replace(_design.copyWith(shape: s.index)),
            child: _MiniStone(
              design: PebbleDesign.stone(
                shape: s.index,
                seed: _design.seed,
                material: _design.material,
              ),
            ),
          ),
      ],
    ),
    const SizedBox(height: 8),
    Align(
      alignment: AlignmentDirectional.centerStart,
      child: OutlinedButton.icon(
        key: const Key('pebble-new-seed'),
        onPressed: () => _replace(
          _design.copyWith(
            seed: (_design.seed * 1103515245 + 12345) & 0xFFFFFFFF,
          ),
        ),
        icon: const Icon(Icons.casino_rounded),
        label: Text(t('Inny kamień tego kształtu')),
      ),
    ),
    _slider(
      'width',
      t('Szerokość'),
      _design.width.toDouble(),
      -100,
      100,
      (_) {},
      done: (double v) => _replace(_design.copyWith(width: v.round())),
    ),
    _slider(
      'height',
      t('Wysokość'),
      _design.height.toDouble(),
      -100,
      100,
      (_) {},
      done: (double v) => _replace(_design.copyWith(height: v.round())),
    ),
    _slider(
      'length',
      t('Długość'),
      _design.length.toDouble(),
      -100,
      100,
      (_) {},
      done: (double v) => _replace(_design.copyWith(length: v.round())),
    ),
    _label(theme, t('Materiał')),
    Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final PebbleMaterial m in PebbleMaterial.values)
          ChoiceChip(
            key: Key('pebble-material-${m.name}'),
            avatar: CircleAvatar(
              backgroundColor: Color(m.main),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(m.second),
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            label: Text(m.label),
            selected: m.index == _design.material,
            onSelected: (_) => _replace(
              _design.copyWith(
                material: m.index,
                mainColour: m.main,
                secondColour: m.second,
              ),
            ),
          ),
      ],
    ),
    _label(theme, t('Kolor kamienia')),
    _colours(
      theme,
      _design.mainColour,
      (int c) => _replace(_design.copyWith(mainColour: c | 0xFF000000)),
    ),
  ];
}

/// A colour to pick.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.colour,
    required this.selected,
    required this.label,
    required this.onTap,
    super.key,
  });

  final int colour;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colour == 0 ? null : Color(colour),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: colour == 0
              ? Icon(Icons.block_rounded, size: 18, color: scheme.outline)
              : null,
        ),
      ),
    );
  }
}

/// A stamp drawn on a button.
class _StampButton extends StatelessWidget {
  const _StampButton({required this.id, required this.onTap, super.key});

  final int id;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: PebbleStamps.label(id),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Ink(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: CustomPaint(painter: _StampPainter(id)),
      ),
    ),
  );
}

class _StampPainter extends CustomPainter {
  const _StampPainter(this.id);

  final int id;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..scale(size.shortestSide * 0.4);
    PebbleStamps.paint(canvas, id);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StampPainter old) => old.id != id;
}

/// A small stone with its name under it, to pick.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.onTap,
    required this.child,
    this.selected = false,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 92,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ExcludeSemantics(
                child: SizedBox.square(dimension: 72, child: child),
              ),
              Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A design drawn small and still.
class _MiniStone extends StatelessWidget {
  const _MiniStone({required this.design});

  final PebbleDesign design;

  @override
  Widget build(BuildContext context) =>
      PebbleView(design: design.encode(), card: design.look, size: 72);
}
