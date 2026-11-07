import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Zooming the graph spreads the people apart; the dots, rings and names
// keep their size on the screen.

/// The circles a paint draws (centre and radius), nothing else.
final class _Circles implements Canvas {
  final List<(Offset, double)> drawn = <(Offset, double)>[];
  double _scale = 1;
  final List<double> _saved = <double>[];

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      drawn.add((c, radius * _scale));

  @override
  void save() => _saved.add(_scale);

  @override
  void restore() => _scale = _saved.removeLast();

  @override
  void scale(double sx, [double? sy]) => _scale *= sx;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('the zoom the people are drawn for goes in small steps', () {
    expect(graphZoomStep(0.5), 1);
    expect(graphZoomStep(1), 1);
    expect(graphZoomStep(2), closeTo(2, 0.1));
    expect(graphZoomStep(4.4), closeTo(4.4, 0.25));
    expect(graphZoomStep(1.02), 1);
  });

  test('zoomed in four times, the people are drawn a quarter as big on the '
      'picture, so on the screen they stay as they were', () {
    String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');
    final List<GraphNode> nodes = <GraphNode>[
      for (int i = 0; i < 6; i++)
        GraphNode(address: addr('a$i'), name: 'P$i', ring: 1),
    ];
    final GraphLayout layout = graphLayout(nodes, const Size(600, 600));
    final GraphScene scene = GraphScene(
      layout: layout,
      from: Float32List.fromList(layout.xy),
      edgeFrom: Int32List.fromList(<int>[for (final GraphNode _ in nodes) -1]),
      edgeTo: Int32List.fromList(<int>[for (int i = 0; i < 6; i++) i]),
      links: Int32List(0),
    );
    final ZenColors zen = ZenTheme.dark().extension<ZenColors>()!;
    final GraphLook look = graphLook(
      scene: scene,
      mode: GraphMode.presence,
      facts: GraphFacts(),
      zen: zen,
    );
    List<(Offset, double)> paint(double zoom) {
      final GraphLabelCache labels = GraphLabelCache();
      final _Circles canvas = _Circles();
      GraphPainter(
        scene: scene,
        look: look,
        progress: const AlwaysStoppedAnimation<double>(1),
        labels: labels,
        me: zen.accent,
        meText: zen.onAccent,
        text: zen.textPrimary,
        labelBg: zen.surfaceRaised,
        guide: zen.outlineSoft,
        zoom: zoom,
      ).paint(canvas, const Size(600, 600));
      labels.clear();
      return canvas.drawn;
    }

    final List<(Offset, double)> plain = paint(1);
    final List<(Offset, double)> zoomed = paint(4);
    expect(plain, isNotEmpty);
    expect(zoomed.length, plain.length);
    for (int i = 0; i < plain.length; i++) {
      // Same places on the picture (the zoom spreads them on the screen)…
      expect(zoomed[i].$1, plain[i].$1);
      // …a quarter of the size, unless it is a ring around everybody.
      if (plain[i].$2 < 60) {
        expect(zoomed[i].$2, closeTo(plain[i].$2 / 4, 0.001));
      }
    }
    // A painter repaints for another zoom.
    final GraphLabelCache labels = GraphLabelCache();
    GraphPainter at(double zoom) => GraphPainter(
      scene: scene,
      look: look,
      progress: const AlwaysStoppedAnimation<double>(1),
      labels: labels,
      me: zen.accent,
      meText: zen.onAccent,
      text: zen.textPrimary,
      labelBg: zen.surfaceRaised,
      guide: zen.outlineSoft,
      zoom: zoom,
    );
    expect(at(2).shouldRepaint(at(1)), isTrue);
    expect(at(2).shouldRepaint(at(2)), isFalse);
  });
}
