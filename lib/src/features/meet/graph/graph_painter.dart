import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/graph/graph_insights.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';

/// How one person is drawn in the current mode.
@immutable
final class NodeLook {
  const NodeLook({
    required this.fill,
    this.radius = 9,
    this.ring,
    this.dot,
    this.tag,
    this.tagTone,
    this.label = false,
    this.hollow = false,
    this.unknown = false,
  });

  /// The dot (a dimmed person has a see-through colour).
  final Color fill;
  final double radius;

  /// An outline (met in person, the pyramid line, picked, found).
  final Color? ring;

  /// A small dot at the top right (online).
  final Color? dot;

  /// A short badge next to the person ("randki", "poz. 3").
  final String? tag;
  final Color? tagTone;

  /// Always named, whatever the zoom (picked, found, on the route).
  final bool label;

  /// Drawn as an empty ring in [fill] only (offline).
  final bool hollow;

  /// Drawn as a faint disc in [fill] with a ring and a question mark
  /// (presence not known now).
  final bool unknown;
}

/// How one line is drawn in the current mode.
@immutable
final class EdgeLook {
  const EdgeLook({
    required this.color,
    this.width = 1,
    this.dashed = false,
    this.tag,
  });

  final Color color;
  final double width;
  final bool dashed;

  /// A label in the middle of the line (a gate price).
  final String? tag;
}

/// A community drawn as a soft blob, with its name.
@immutable
final class GraphHalo {
  const GraphHalo({
    required this.center,
    required this.radius,
    required this.color,
    required this.name,
  });

  final Offset center;
  final double radius;
  final Color color;
  final String name;
}

/// What the picture is made of: the layout, where everyone was before (for
/// the animation between modes) and the lines, as indexes into the layout.
/// Built once per change of the data, the filters or the mode; never per
/// frame.
final class GraphScene {
  GraphScene({
    required this.layout,
    required this.from,
    required this.edgeFrom,
    required this.edgeTo,
    required this.links,
    this.halos = const <GraphHalo>[],
  });

  final GraphLayout layout;

  /// Positions before (same order as the layout).
  final Float32List from;

  /// Lines: [edgeFrom] -1 is "Ty", else a node index.
  final Int32List edgeFrom;
  final Int32List edgeTo;

  /// Friends who know each other (pairs of node indexes).
  final Int32List links;
  final List<GraphHalo> halos;

  int get edgeCount => edgeTo.length;
}

/// The looks of a mode, aligned with a [GraphScene].
final class GraphLook {
  GraphLook({
    required this.nodes,
    required this.edges,
    required this.link,
    this.route = const <int>[],
    this.showHalos = true,
  });

  final List<NodeLook> nodes;
  final List<EdgeLook> edges;
  final Color link;

  /// The route from "Ty" (node indexes in order).
  final List<int> route;
  final bool showHalos;
}

/// Text painters by text and colour, so labels are laid out once and not
/// on every repaint.
final class GraphLabelCache {
  final Map<String, TextPainter> _cache = <String, TextPainter>{};

  static const int _max = 1500;

  TextDirection _direction = TextDirection.ltr;

  /// The direction of the app's language: used for a label with no letter
  /// of its own direction (digits, emoji); set from the screen's
  /// `Directionality`.
  TextDirection get direction => _direction;
  set direction(TextDirection value) {
    if (value != _direction) {
      _direction = value;
      clear();
    }
  }

  TextPainter get(String text, Color color, {bool bold = false}) {
    final String key = '${color.toARGB32()}|$bold|$text';
    final TextPainter? had = _cache[key];
    if (had != null) {
      return had;
    }
    if (_cache.length >= _max) {
      clear();
    }
    return _cache[key] = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontFamily: ZenText.sansFamily,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      // An Arabic name keeps its "…" at its own end, in any language.
      textDirection: labelDirection(text, _direction),
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 96);
  }

  void clear() {
    for (final TextPainter tp in _cache.values) {
      tp.dispose();
    }
    _cache.clear();
  }
}

/// The direction of [text] by its first letter with a direction of its own
/// (Hebrew, Arabic and the like: right to left); [fallback] when it has none.
TextDirection labelDirection(String text, TextDirection fallback) {
  for (final int r in text.runes) {
    if ((r >= 0x0590 && r <= 0x08FF) ||
        (r >= 0xFB1D && r <= 0xFDFF) ||
        (r >= 0xFE70 && r <= 0xFEFF) ||
        (r >= 0x10800 && r <= 0x10FFF) ||
        (r >= 0x1E800 && r <= 0x1EFFF)) {
      return TextDirection.rtl;
    }
    if ((r >= 0x41 && r <= 0x5A) ||
        (r >= 0x61 && r <= 0x7A) ||
        (r >= 0xC0 && r < 0x0590 && r != 0xD7 && r != 0xF7) ||
        (r >= 0x0900 && r < 0x2000) ||
        (r >= 0x3040 && r < 0xFB1D)) {
      return TextDirection.ltr;
    }
  }
  return fallback;
}

/// Labels drawn at most in one paint.
const int _maxLabels = 220;

/// Line labels drawn at most in one paint.
const int _maxEdgeTags = 200;

/// Share of the timeline over which someone new grows to full size.
const double _growSpan = 0.05;

/// The graph. Level of detail: many people are dots drawn in a few batched
/// calls, names show by zoom and only inside [visible]; positions move
/// only while [progress] runs (a mode change), never otherwise. With a
/// [timeline], people appear as [clock] (0…1 of its span) passes the day
/// they came, and a ring in [metTone] marks a meeting in person once its
/// day has passed — the layout stays, so playing it is only repainting.
class GraphPainter extends CustomPainter {
  GraphPainter({
    required this.scene,
    required this.look,
    required this.progress,
    required this.labels,
    required this.me,
    required this.meText,
    required this.text,
    required this.labelBg,
    required this.guide,
    this.scale = 1,
    this.visible,
    this.timeline,
    this.clock,
    this.metTone,
    this.labelRadius = 8,
  }) : super(
         repaint: clock == null
             ? progress
             : Listenable.merge(<Listenable>[progress, clock]),
       );

  final GraphScene scene;
  final GraphLook look;
  final Animation<double> progress;
  final GraphLabelCache labels;
  final Color me;
  final Color meText;
  final Color text;
  final Color labelBg;
  final Color guide;

  /// The zoom of the picture (labels and badges by level of detail).
  final double scale;

  /// The part of the picture on screen (`null`: all of it).
  final Rect? visible;

  /// When each person came and was met (aligned with the layout).
  final GraphTimeline? timeline;

  /// Where on the [timeline] the picture is (0…1).
  final Animation<double>? clock;
  final Color? metTone;

  /// The corner of a name label (the theme's corner, see `ZenLook.radius`).
  final double labelRadius;

  /// Whether person [i] was met in person by [at].
  bool _metBy(int i, double at) {
    final GraphTimeline? tl = timeline;
    return tl != null && i >= 0 && i < tl.met.length && tl.met[i] <= at;
  }

  /// How grown person [i] is now (0: not there yet, 1: fully).
  double _grown(int i, double at) {
    final GraphTimeline? tl = timeline;
    if (tl == null || i < 0 || i >= tl.born.length) {
      return 1;
    }
    final double b = tl.born[i];
    if (b < 0) {
      return 1;
    }
    if (b > at) {
      return 0;
    }
    return ((at - b) / _growSpan).clamp(0.0, 1.0);
  }

  Float32List _positions(double phase) {
    final Float32List to = scene.layout.xy;
    if (phase >= 1) {
      return to;
    }
    final Float32List from = scene.from;
    final Float32List out = Float32List(to.length);
    for (int i = 0; i < to.length; i++) {
      out[i] = from[i] + (to[i] - from[i]) * phase;
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double phase = Curves.easeInOutCubic.transform(
      progress.value.clamp(0.0, 1.0),
    );
    final Float32List xy = _positions(phase);
    final Offset c = scene.layout.center;
    final int n = scene.layout.nodes.length;
    Offset at(int i) => i < 0 ? c : Offset(xy[2 * i], xy[2 * i + 1]);
    bool shown(Offset p) => visible == null || visible!.inflate(40).contains(p);
    final double now = clock?.value ?? 1;
    final bool timed = timeline != null;
    bool there(int i) => !timed || i < 0 || _grown(i, now) > 0;

    // Faint rings where the people are.
    final Paint ringPaint = Paint()
      ..color = guide
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final List<double> radii = scene.layout.radii;
    if (radii.length <= 40) {
      for (final double r in radii) {
        canvas.drawCircle(c, r, ringPaint);
      }
    }

    if (look.showHalos) {
      _halos(canvas, phase);
    }

    // Lines. Plain ones are batched by colour and width (one call each).
    final Map<(int, double), List<double>> batches =
        <(int, double), List<double>>{};
    final int edges = scene.edgeCount;
    for (int e = 0; e < edges; e++) {
      final EdgeLook l = look.edges[e];
      if (l.color.a == 0 ||
          (timed && (!there(scene.edgeFrom[e]) || !there(scene.edgeTo[e])))) {
        continue;
      }
      final Offset a = at(scene.edgeFrom[e]);
      final Offset b = at(scene.edgeTo[e]);
      if (l.dashed) {
        _dashed(canvas, a, b, l);
        continue;
      }
      batches
          .putIfAbsent((l.color.toARGB32(), l.width), () => <double>[])
          .addAll(<double>[a.dx, a.dy, b.dx, b.dy]);
    }
    final Paint edge = Paint()..strokeCap = StrokeCap.round;
    batches.forEach(((int, double) k, List<double> pts) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.fromList(pts),
        edge
          ..color = Color(k.$1)
          ..strokeWidth = k.$2,
      );
    });

    // Friends who know each other: bent away from the middle, so the line
    // does not run over "Ty" (straight when there are very many).
    final Int32List links = scene.links;
    final int linkCount = links.length ~/ 2;
    if (linkCount > 0 && look.link.a > 0) {
      final Paint link = Paint()
        ..color = look.link
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9;
      if (linkCount > 600) {
        final Float32List pts = Float32List(linkCount * 4);
        for (int i = 0; i < linkCount; i++) {
          // Not there yet: a point under "Ty" (drawn over it).
          final bool hide =
              timed && (!there(links[2 * i]) || !there(links[2 * i + 1]));
          final Offset x = hide ? c : at(links[2 * i]);
          final Offset y = hide ? c : at(links[2 * i + 1]);
          pts
            ..[4 * i] = x.dx
            ..[4 * i + 1] = x.dy
            ..[4 * i + 2] = y.dx
            ..[4 * i + 3] = y.dy;
        }
        canvas.drawRawPoints(ui.PointMode.lines, pts, link);
      } else {
        final Path curves = Path();
        for (int i = 0; i < linkCount; i++) {
          if (timed && (!there(links[2 * i]) || !there(links[2 * i + 1]))) {
            continue;
          }
          final Offset x = at(links[2 * i]);
          final Offset y = at(links[2 * i + 1]);
          final Offset mid = (x + y) / 2;
          final Offset away = mid - c;
          final Offset control = away.distance < 1
              ? mid + const Offset(0, -40)
              : mid + away * 0.35;
          curves
            ..moveTo(x.dx, x.dy)
            ..quadraticBezierTo(control.dx, control.dy, y.dx, y.dy);
        }
        canvas.drawPath(curves, link);
      }
    }

    // The route.
    if (look.route.isNotEmpty) {
      final Paint way = Paint()
        ..color = me
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final Path p = Path()..moveTo(c.dx, c.dy);
      for (final int i in look.route) {
        final Offset q = at(i);
        p.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(p, way);
    }

    // Line labels (gate prices): by zoom, on screen only, capped.
    _edgeTags(canvas, at, shown);

    // "Ty".
    canvas
      ..drawCircle(c, 26, Paint()..color = me.withValues(alpha: 0.16))
      ..drawCircle(c, 17, Paint()..color = me);
    final TextPainter you = labels.get(t('Ty'), meText, bold: true);
    you.paint(canvas, c - Offset(you.width / 2, you.height / 2));

    // People: small dots batched by colour, bigger ones one by one.
    final Map<int, (double, List<double>)> dots =
        <int, (double, List<double>)>{};
    final Paint fill = Paint();
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final Paint metRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = metTone ?? me;
    for (int i = 0; i < n; i++) {
      final NodeLook l = look.nodes[i];
      final Offset p = at(i);
      if (timed) {
        final double g = _grown(i, now);
        if (g <= 0) {
          continue;
        }
        final bool metBy = _metBy(i, now);
        if (g < 1 || metBy) {
          // Growing, or met by now: drawn on its own.
          final double r = l.radius * (0.4 + 0.6 * g);
          canvas.drawCircle(p, r, fill..color = l.fill);
          if (metBy) {
            canvas.drawCircle(p, r + 3.5, metRing);
          }
          continue;
        }
      }
      if (l.hollow) {
        canvas.drawCircle(p, l.radius - 0.8, stroke..color = l.fill);
        continue;
      }
      if (l.unknown) {
        canvas
          ..drawCircle(
            p,
            l.radius - 0.8,
            fill..color = l.fill.withValues(alpha: 0.3),
          )
          ..drawCircle(p, l.radius - 0.8, stroke..color = l.fill);
        final TextPainter mark = labels.get('?', l.fill, bold: true);
        mark.paint(canvas, p - Offset(mark.width / 2, mark.height / 2));
        continue;
      }
      if (l.radius <= 5 && l.ring == null && l.dot == null) {
        final (double, List<double>) b = dots.putIfAbsent(
          l.fill.toARGB32(),
          () => (l.radius, <double>[]),
        );
        b.$2.addAll(<double>[p.dx, p.dy]);
        continue;
      }
      if (l.radius > 5 && l.fill.a > 0.5) {
        canvas.drawCircle(
          p,
          l.radius + 5,
          fill..color = l.fill.withValues(alpha: 0.18),
        );
      }
      canvas.drawCircle(p, l.radius, fill..color = l.fill);
      if (l.ring != null) {
        canvas.drawCircle(p, l.radius + 3.5, stroke..color = l.ring!);
      }
      if (l.dot != null) {
        final Offset d = p + Offset(l.radius * 0.75, -l.radius * 0.75);
        canvas
          ..drawCircle(d, 3.6, fill..color = labelBg)
          ..drawCircle(d, 2.6, fill..color = l.dot!);
      }
    }
    final Paint dot = Paint()..strokeCap = StrokeCap.round;
    dots.forEach((int color, (double, List<double>) b) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(b.$2),
        dot
          ..color = Color(color)
          ..strokeWidth = b.$1 * 2,
      );
    });

    _nodeText(canvas, at, shown);
  }

  /// Names and badges: friends' names when there are few of them or the
  /// picture is zoomed in, friends of friends only close up; picked and
  /// found people always. On screen only, capped.
  void _nodeText(
    Canvas canvas,
    Offset Function(int) at,
    bool Function(Offset) shown,
  ) {
    final List<GraphNode> nodes = scene.layout.nodes;
    int friends = 0;
    for (final GraphNode g in nodes) {
      if (g.isFriend) {
        friends++;
      }
    }
    final bool friendNames = friends <= 60 || scale >= 1.6;
    final bool farNames = scale >= 2.5 || nodes.length <= 40;
    final bool tags = nodes.length <= 300 || scale >= 1.8;
    int drawn = 0;
    // Forced labels first, so the cap never drops them.
    for (final bool forced in <bool>[true, false]) {
      for (int i = 0; i < nodes.length && drawn < _maxLabels; i++) {
        final NodeLook l = look.nodes[i];
        if (l.label != forced) {
          continue;
        }
        final GraphNode g = nodes[i];
        final Offset p = at(i);
        if (!forced && (!shown(p) || !(g.isFriend ? friendNames : farNames))) {
          continue;
        }
        if (timeline != null && _grown(i, clock?.value ?? 1) < 1) {
          continue;
        }
        final TextPainter tp = labels.get(g.name, text, bold: true);
        final Offset topLeft = p + Offset(-tp.width / 2, l.radius + 6);
        _pill(canvas, topLeft, tp, labelBg.withValues(alpha: 0.88));
        drawn++;
        if (l.tag != null && (tags || forced)) {
          final TextPainter tag = labels.get(l.tag!, l.tagTone ?? text);
          _pill(
            canvas,
            p + Offset(l.radius + 4, -l.radius - tag.height),
            tag,
            labelBg.withValues(alpha: 0.94),
            border: l.tagTone,
          );
        }
      }
    }
    // Badges of people whose name is not drawn (zoomed out).
    if (!tags) {
      return;
    }
    for (int i = 0; i < nodes.length && drawn < _maxLabels; i++) {
      final NodeLook l = look.nodes[i];
      final GraphNode g = nodes[i];
      if (l.tag == null ||
          l.label ||
          (g.isFriend ? friendNames : farNames) ||
          !shown(at(i)) ||
          (timeline != null && _grown(i, clock?.value ?? 1) < 1)) {
        continue;
      }
      final TextPainter tag = labels.get(l.tag!, l.tagTone ?? text);
      final Offset p = at(i);
      _pill(
        canvas,
        p + Offset(l.radius + 4, -l.radius - tag.height),
        tag,
        labelBg.withValues(alpha: 0.94),
        border: l.tagTone,
      );
      drawn++;
    }
  }

  void _edgeTags(
    Canvas canvas,
    Offset Function(int) at,
    bool Function(Offset) shown,
  ) {
    int tagged = 0;
    for (final EdgeLook l in look.edges) {
      if (l.tag != null) {
        tagged++;
      }
    }
    if (tagged == 0) {
      return;
    }
    final bool far = tagged <= 120 || scale >= 1.8;
    int drawn = 0;
    for (int e = 0; e < scene.edgeCount && drawn < _maxEdgeTags; e++) {
      final EdgeLook l = look.edges[e];
      final int from = scene.edgeFrom[e];
      if (l.tag == null || (from >= 0 && !far)) {
        continue;
      }
      final Offset mid = (at(from) + at(scene.edgeTo[e])) / 2;
      if (!shown(mid)) {
        continue;
      }
      final TextPainter tp = labels.get(l.tag!, l.color.withValues(alpha: 1));
      _pill(
        canvas,
        mid - Offset(tp.width / 2, tp.height / 2),
        tp,
        labelBg.withValues(alpha: 0.94),
        border: l.color,
      );
      drawn++;
    }
  }

  void _pill(
    Canvas canvas,
    Offset topLeft,
    TextPainter tp,
    Color bg, {
    Color? border,
  }) {
    final RRect r = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        topLeft.dx - 5,
        topLeft.dy - 1.5,
        tp.width + 10,
        tp.height + 3,
      ),
      Radius.circular(labelRadius),
    );
    canvas.drawRRect(r, Paint()..color = bg);
    if (border != null) {
      canvas.drawRRect(
        r,
        Paint()
          ..color = border.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    tp.paint(canvas, topLeft);
  }

  void _halos(Canvas canvas, double phase) {
    if (scene.halos.length < 2) {
      return;
    }
    for (final GraphHalo h in scene.halos) {
      canvas
        ..drawCircle(
          h.center,
          h.radius,
          Paint()..color = h.color.withValues(alpha: 0.08 * phase),
        )
        ..drawCircle(
          h.center,
          h.radius,
          Paint()
            ..color = h.color.withValues(alpha: 0.28 * phase)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      if (phase > 0.6 && h.name.isNotEmpty) {
        final TextPainter tp = labels.get(h.name, h.color, bold: true);
        final Offset top = h.center - Offset(tp.width / 2, h.radius + 2);
        _pill(
          canvas,
          top - Offset(0, tp.height),
          tp,
          labelBg.withValues(alpha: 0.9),
        );
      }
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, EdgeLook l) {
    final Paint p = Paint()
      ..color = l.color
      ..strokeWidth = l.width
      ..strokeCap = StrokeCap.round;
    final Offset d = b - a;
    final double len = d.distance;
    if (len < 1) {
      return;
    }
    final Offset u = d / len;
    const double on = 5;
    const double off = 4;
    final int parts = min(400, (len / (on + off)).ceil());
    final Float32List pts = Float32List(parts * 4);
    int k = 0;
    for (int i = 0; i < parts; i++) {
      final double s = i * (on + off);
      final double e = min(len, s + on);
      final Offset x = a + u * s;
      final Offset y = a + u * e;
      pts
        ..[k++] = x.dx
        ..[k++] = x.dy
        ..[k++] = y.dx
        ..[k++] = y.dy;
    }
    canvas.drawRawPoints(ui.PointMode.lines, pts, p);
  }

  @override
  bool shouldRepaint(GraphPainter old) =>
      !identical(old.scene, scene) ||
      !identical(old.look, look) ||
      !identical(old.timeline, timeline) ||
      old.scale != scale ||
      old.visible != visible ||
      old.me != me ||
      old.text != text ||
      old.labelBg != labelBg ||
      old.labelRadius != labelRadius;
}
